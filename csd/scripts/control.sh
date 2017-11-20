#!/bin/sh
#
#    Licensed to the Apache Software Foundation (ASF) under one or more
#    contributor license agreements.  See the NOTICE file distributed with
#    this work for additional information regarding copyright ownership.
#    The ASF licenses this file to You under the Apache License, Version 2.0
#    (the "License"); you may not use this file except in compliance with
#    the License.  You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

# Script structure inspired from Apache Karaf and other Apache projects with similar startup approaches

set -efu -o pipefail

. ${COMMON_SCRIPT}

warn() {
    echo "${PROGNAME}: $*"
}

die() {
    warn "$*"
    exit 1
}

unlimitFD() {
    # Use the maximum available, or set MAX_FD != -1 to use that
    MAX_FD=${MAX_FD:="maximum"}

    # Increase the maximum file descriptors if we can
    MAX_FD_LIMIT=$(ulimit -H -n)
    if [ "${MAX_FD_LIMIT}" != 'unlimited' ]; then
        if [ $? -eq 0 ]; then
            if [ "${MAX_FD}" = "maximum" -o "${MAX_FD}" = "max" ]; then
                # use the system max
                MAX_FD="${MAX_FD_LIMIT}"
            fi

            ulimit -n ${MAX_FD} > /dev/null
            # echo "ulimit -n" `ulimit -n`
            if [ $? -ne 0 ]; then
                warn "Could not set maximum file descriptor limit: ${MAX_FD}"
            fi
        else
            warn "Could not query system maximum file descriptor limit: ${MAX_FD_LIMIT}"
        fi
    fi
}

locate_java8_home() {
    if [ -z "${JAVA_HOME}" ]; then
        BIGTOP_JAVA_MAJOR=8
        locate_java_home
    fi

    JAVA="${JAVA_HOME}/bin/java"
    TOOLS_JAR=""

    # if command is env, attempt to add more to the classpath
    if [ "$1" = "env" ]; then
        [ "x${TOOLS_JAR}" =  "x" ] && [ -n "${JAVA_HOME}" ] && TOOLS_JAR=$(find -H "${JAVA_HOME}" -name "tools.jar")
        [ "x${TOOLS_JAR}" =  "x" ] && [ -n "${JAVA_HOME}" ] && TOOLS_JAR=$(find -H "${JAVA_HOME}" -name "classes.jar")
        if [ "x${TOOLS_JAR}" =  "x" ]; then
             warn "Could not locate tools.jar or classes.jar. Please set manually to avail all command features."
        fi
    fi
}

get_property() {
    local file=$1
    local key=$2
    grep "$key=" ${file}.properties | tail -1 | cut -d '=' -f 2
}

#TODO: replace with sed
insert_if_not_exists() {
    LINE=$1
    FILE=$2
    if ! grep -c "${LINE}" ${FILE} > /dev/null; then
        echo "${LINE}" >> ${FILE}
    fi
}

close_xml_file() {
    XML_TAG=$1
    FILE=$2

    if [ ! -e $FILE ]; then
        return 0
    elif ! tail ${FILE} | grep -c "^</${XML_TAG}>$" > /dev/null; then
        echo "</${XML_TAG}>" >> ${FILE}
    fi
}

close_prefix_safety_valve_xml() {
    local prefix=$1
    local xml_tag=$2

    # close all safety-valve files
    for sv_xml in `find . -type f -name "${prefix}-*safety-valve.xml"`; do
        close_xml_file "${xml_tag}" ${sv_xml}
    done
}

convert_prefix_hadoop_xml() {
    local prefix=$1
    local xslt=${2:-aux/${prefix}.xslt}

    local basename=$(basename $prefix)
    local dirname=$(dirname $prefix)

    for h_xml in `find ${dirname} -type f -name "${basename}-*.hadoop_xml"`; do
        xsltproc -o ${h_xml//hadoop_xml/xml} ${xslt} ${h_xml}
        rm -f ${h_xml}
    done
}

tls_client_init() {
    prefix=tls-conf/tls

    convert_prefix_hadoop_xml ${prefix} ${CDH_NIFI_XSLT}/hadoop2element-value.xslt

    caHostname=`grep port ${prefix}-service.properties | head -1 | cut -f 1 -d ':'`
    caPort=`grep port ${prefix}-service.properties | head -1 | cut -f 2 -d '='`

    sed -i "s/@@HOSTNAME@@/$(hostname -f)/" ${prefix}-service.xml
    sed -i "s/@@CA_HOSTNAME@@/${caHostname}/" ${prefix}-service.xml
    sed -i "s/@@CA_PORT@@/${caPort}/" ${prefix}-service.xml

    # Merge TLS configuration
    merge=${CDH_NIFI_XSLT}/merge.xslt
    in_a=${prefix}-client.xml
    in_b=$(basename ${prefix}-service.xml) # relative paths only
    out=${prefix}.xml
    xsltproc -o ${out} \
             --param with "'${in_b}'" \
             ${merge} ${in_a}
    rm -f ${in_a} ${in_b}


    xsltproc ${CDH_NIFI_XSLT}/xml2json.xslt $out | ${CDH_NIFI_JQ} '
      .configuration |
      .port=(.port| tonumber) |
      .days=(.days | tonumber) |
      .keySize=(.keySize | tonumber) |
      .reorderDn=(.reorderDn == "true")' > ${prefix}.json

    CLASSPATH=".:${CDH_NIFI_TOOLKIT_HOME}/lib/*"

    "${JAVA}" -cp "${CLASSPATH}" \
                ${JAVA_OPTS:--Xms12m -Xmx24m} \
                ${CSD_JAVA_OPTS} \
                org.apache.nifi.toolkit.tls.TlsToolkitMain \
                client -F \
                --configJson ${prefix}.json

}

nifi_init() {
    # Unlimit the number of file descriptors if possible
    unlimitFD

    # NiFi 1.4.0 was compiled with 1.8.0
    locate_java8_home $1

    # TLS Client Init
    [ $NIFI_SSL_ENABLED == "false" ] || [ -e tls-conf/tls.json ] || tls_client_init

    # Simulate NIFI_HOME
    [ -d conf ] || mkdir conf
    [ -e lib ] || ln -s ${CDH_NIFI_HOME}/lib .
    [ -e docs ] || ln -s ${CDH_NIFI_HOME}/docs .

    # Update bootstrap files
    update_bootstrap_conf
    close_xml_file "services" bootstrap-notification-services.xml

    # Update jaas.conf
    update_jaas_conf


    [ -e 'login-identity-providers.xml' ] || create_login_identity_providers_xml
    [ -e 'state-management.xml' ] || create_state_management_xml
    [ -e 'authorizers.xml' ] || create_authorizers_xml

    update_logback_xml
    update_nifi_properties

    find ${CONF_DIR} -maxdepth 1 -type f -name '*.conf' -exec ln -sf {} ${CONF_DIR}/conf \;
    find ${CONF_DIR} -maxdepth 1 -type f -name '*.xml' -exec ln -sf {} ${CONF_DIR}/conf \;
    find ${CONF_DIR} -maxdepth 1 -type f -name '*.properties' -exec ln -sf {} ${CONF_DIR}/conf \;
}

create_login_identity_providers_xml() {
    prefix=login-identity-providers

    convert_prefix_hadoop_xml ${prefix}

    close_prefix_safety_valve_xml ${prefix} "loginIdentityProviders"

    # Merge Providers
    merge=${CDH_NIFI_XSLT}/merge.xslt
    in_a=${prefix}-kerberos.xml
    in_b=${prefix}-safety-valve.xml
    out=${prefix}.xml
    xsltproc -o ${out} \
             --param with "'${in_b}'" \
             --param dontmerge "'provider'" \
             ${merge} ${in_a}
    rm -f ${in_a} ${in_b}
}

create_node_identities_hadoop_xml() {
    local prefix=$1
    local property_prefix=$2
    local out=$prefix-node-identities.hadoop_xml
    local dnPrefix=$(cat tls-conf/tls.json | ${CDH_NIFI_JQ} -r .dnPrefix)
    local dnSuffix=$(cat tls-conf/tls.json | ${CDH_NIFI_JQ} -r .dnSuffix)

    echo '<?xml version="1.0" encoding="UTF-8"?>' > $out
    echo '<configuration>' >> $out

    arr=($(cut -d ':' -f 1 nifi-nodes.properties | sort | uniq ))
    for ix in ${!arr[*]}; do
      echo '  <property>' >> $out
      echo "    <name>${property_prefix}${ix}</name>" >> $out
      echo "    <value>${dnPrefix}${arr[$ix]}${dnSuffix}</value>" >> $out
      echo '  </property>' >> $out
    done

    echo '</configuration>' >> $out
}

create_authorizers_access_policy_provider_with_nodes_hadoop_xml() {
    local prefix=authorizers-access-policy-provider
    create_node_identities_hadoop_xml ${prefix} 'Node Identity '

    # Merge node identities
    merge=${CDH_NIFI_XSLT}/merge.xslt
    in_a=${prefix}-file.hadoop_xml
    in_b=${prefix}-node-identities.hadoop_xml
    out=${prefix}-with-nodes.hadoop_xml
    xsltproc -o ${out} \
             --param with "'${in_b}'" \
             --param dontmerge "'property'" \
             ${merge} ${in_a}
    rm -f ${in_a} ${in_b}
}

create_authorizers_user_group_provider_with_nodes_hadoop_xml() {
    local prefix=authorizers-user-group-provider
    create_node_identities_hadoop_xml ${prefix} 'Initial User Identity 10'

    # Merge node identities
    merge=${CDH_NIFI_XSLT}/merge.xslt
    in_a=${prefix}-file.hadoop_xml
    in_b=${prefix}-node-identities.hadoop_xml
    out=${prefix}-with-nodes.hadoop_xml
    xsltproc -o ${out} \
             --param with "'${in_b}'" \
             --param dontmerge "'property'" \
             ${merge} ${in_a}
    rm -f ${in_a} ${in_b}
}


create_authorizers_xml() {
    create_authorizers_access_policy_provider_with_nodes_hadoop_xml
    create_authorizers_user_group_provider_with_nodes_hadoop_xml

    local prefix=authorizers

    convert_prefix_hadoop_xml ${prefix}
    close_prefix_safety_valve_xml ${prefix} "authorizers"
     
    # Merge with User Group Providers
    merge=${CDH_NIFI_XSLT}/merge.xslt
    prefix=authorizers-user-group-provider
    in_a=${prefix}-with-nodes.xml
    in_b=${prefix}-safety-valve.xml
    out=${prefix}.xml
    xsltproc -o ${out} \
             --param with "'${in_b}'" \
             --param dontmerge "'userGroupProvider'" \
             ${merge} ${in_a}
    rm -f ${in_a} ${in_b}

    # Merge with Access Policy Providers
    prefix=authorizers-access-policy-provider
    in_a=${out}
    in_b=${prefix}-with-nodes.xml
    out=${prefix}-1.xml
    xsltproc -o ${out} \
             --param with "'${in_b}'" \
             ${merge} ${in_a}
    rm -f ${in_a} ${in_b}

    in_a=${out}
    in_b=${prefix}-safety-valve.xml
    out=${prefix}.xml
    xsltproc -o ${out} \
             --param with "'${in_b}'" \
             --param dontmerge "'accessPolicyProvider'" \
             ${merge} ${in_a}
    rm -f ${in_a} ${in_b}

    # Merge with Authorizers
    prefix=authorizers-authorizer
    in_a=${out}
    in_b=${prefix}-managed.xml
    out=${prefix}-1.xml
    xsltproc -o ${out} \
             --param with "'${in_b}'" \
             ${merge} ${in_a}
    rm -f ${in_a} ${in_b}
 
    in_a=${out}
    in_b=${prefix}-safety-valve.xml
    out=authorizers-with-initial.xml
    xsltproc -o ${out} \
             --param with "'${in_b}'" \
             --param dontmerge "'authorizer'" \
             ${merge} ${in_a}
    rm -f ${in_a} ${in_b}

    in_a=${out}
    out=authorizers.xml
    if [ $NIFI_JOIN_CLUSTER == 'true' ]; then
      xmllint --format $in_a | grep -v -E '(Initial (User|Admin)|Node) Identity' > $out
    else
      xmllint --format $in_a > $out
    fi
    rm -f ${in_a}
}

create_state_management_xml() {
    local principal=$(grep 'nifi.kerberos.service.principal=' nifi.properties | tail -1 | cut -d '=' -f 2 | cut -d '/' -f 1)

    prefix=state-management
    convert_prefix_hadoop_xml ${prefix}

    close_prefix_safety_valve_xml ${prefix} "stateManagement"

    # Merge
    merge=${CDH_NIFI_XSLT}/merge.xslt
    in_a=${prefix}-local-provider.xml
    in_b=${prefix}-zk-provider.xml
    out=${prefix}-1.xml
    xsltproc -o ${out} \
             --param with "'${in_b}'" \
             ${merge} ${in_a}
    rm -f ${in_a} ${in_b}

    in_a=${out}
    in_b=${prefix}-safety-valve.xml
    out=${prefix}.xml
    xsltproc -o ${out} \
             --param with "'${in_b}'" \
             ${merge} ${in_a}
    rm -f ${in_a} ${in_b}

    sed -i \
        -e "s|@@ZK_QUORUM@@|${ZK_QUORUM}|g" \
        -e "s|@@ZK_ROOT@@|/${principal}|g" \
        $out
}

update_nifi_properties() {
    local num_of_nodes=$(cut -d ':' -f 1 nifi-nodes.properties | sort | uniq | wc -l)
    local principal=$(grep 'nifi.kerberos.service.principal=' nifi.properties | tail -1 | cut -d '=' -f 2 | cut -d '/' -f 1)

    sed -i \
        -e "s|@@CDH_NIFI_HOME@@|${CDH_NIFI_HOME}|g" \
        -e "s|@@ZK_QUORUM@@|${ZK_QUORUM}|g" \
        -e "s|@@ZK_ROOT@@|/${principal}|g" \
        -e "s|@@NIFI_CLUSTER_FLOW_ELECTION_MAX_CANDIDATES@@|${num_of_nodes}|g" \
        nifi.properties

    if [ $NIFI_SSL_ENABLED == "true" ]; then
        sed -i \
            -e 's/nifi\.web\.http\./nifi.web.https./' \
            nifi.properties
    fi

    NIFI_JAVA_OPTS="${NIFI_JAVA_OPTS} -Dnifi.properties.file.path=${CONF_DIR}/conf/nifi.properties"
}

update_bootstrap_conf() {
    BOOTSTRAP_CONF="${CONF_DIR}/bootstrap.conf";
    # Update bootstrap.conf
    insert_if_not_exists "lib.dir=${CONF_DIR}/lib" ${BOOTSTRAP_CONF}
    insert_if_not_exists "conf.dir=${CONF_DIR}/conf" ${BOOTSTRAP_CONF}

    # Enable Remote Debugging
    #java.arg.debug=-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=8000
}

update_logback_xml() {
    sed -i 's/<configuration>/<configuration scan="true" scanPeriod="30 seconds">/' logback.xml
}

update_jaas_conf() {
    local nifi_principal=$(grep 'nifi.kerberos.service.principal=' nifi.properties | tail -1 | cut -d '=' -f 2)

    sed -i \
        -e "s|@@CONF_DIR@@|${CONF_DIR}|" \
        -e "s|@@NIFI_PRINCIPAL@@|${nifi_principal}|" \
        jaas.conf

    NIFI_JAVA_OPTS="${NIFI_JAVA_OPTS} -Djava.security.auth.login.config=${CONF_DIR}/conf/jaas.conf"
}

nifi_start() {
    NIFI_JAVA_OPTS="${CSD_JAVA_OPTS} ${NIFI_JAVA_OPTS}"
    run_nifi_cmd="'${JAVA}' -cp '${CONF_DIR}:${CDH_NIFI_HOME}/lib/*' ${NIFI_JAVA_OPTS} org.apache.nifi.NiFi"
    eval "cd ${CONF_DIR} && exec ${run_nifi_cmd}"
}

nifi_reset() {
    cmd=$(get_property nifi-reset $1)
    exec $cmd
}

case "$1" in
    nifi-start)
        nifi_init "${1//nifi-}"
        nifi_start
        ;;
    nifi-reset)
        nifi_init "${1//nifi-}"
        nifi_reset "${@:2}"
        ;;
    *)
        echo "Usage control.sh {nifi-run|nifi-stop}"
        ;;
esac
