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

NIFI_COMMON_SCRIPT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/common.sh"
. ${NIFI_COMMON_SCRIPT}

NIFI_TLS_ENABLED=true
pki_init() {
    NIFI_TLS_ENABLED=false
    return 0
}
pki_get_default_subject_suffix() {
    return 0
}
if [ -e pki-conf/init.sh ]; then
  . pki-conf/init.sh
fi

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

#TODO: replace with sed
insert_if_not_exists() {
    LINE=$1
    FILE=$2
    if ! grep -c "${LINE}" ${FILE} > /dev/null; then
        echo "${LINE}" >> ${FILE}
    fi
}

nifi_create_certificates() {
    local KRB5_USER=$(echo ${nifi_principal} | cut -d '/' -f 1)
    local KRB5_REALM=$(echo ${nifi_principal} | cut -d '@' -f 2)

    # TLS Client Init
    export PKI_CSR_OUS="${KRB5_USER}@${KRB5_REALM}"
    pki_init

    DN_SUFFIX=", OU=${PKI_CSR_OUS}$(pki_get_default_subject_suffix)"
}

nifi_init() {
    # Unlimit the number of file descriptors if possible
    unlimitFD

    # NiFi 1.4.0 was compiled with 1.8.0
    locate_java8_home $1

    # PKI Init
    nifi_create_certificates

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
    [ -e 'tenants.xml' ] || create_tenants_xml

    update_logback_xml
    update_nifi_properties

    find ${CONF_DIR} -maxdepth 1 -type f -name '*.conf' -exec ln -sf {} ${CONF_DIR}/conf \;
    find ${CONF_DIR} -maxdepth 1 -type f -name '*.xml' -exec ln -sf {} ${CONF_DIR}/conf \;
    find ${CONF_DIR} -maxdepth 1 -type f -name '*.properties' -exec ln -sf {} ${CONF_DIR}/conf \;
}

create_login_identity_providers_xml() {
    local prefix=login-identity-providers
    local realm=$(echo ${nifi_principal} | cut -d '@' -f 2)

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

    sed -i \
        -e "s|@@REALM@@|${realm}|g" \
        $out

}

create_authorizers_xml() {
    local prefix=authorizers

    convert_prefix_hadoop_xml ${prefix}
    close_prefix_safety_valve_xml ${prefix} "authorizers"

    # Merge with User Group Providers
    merge=${CDH_NIFI_XSLT}/merge.xslt
    prefix=authorizers-user-group-provider
    in_a=${prefix}-file.xml
    in_b=${prefix}-cloudera.xml
    out=${prefix}-1.xml
    xsltproc -o ${out} \
             --param with "'${in_b}'" \
             --param dontmerge "'userGroupProvider'" \
             ${merge} ${in_a}
    rm -f ${in_a} ${in_b}

    in_a=${out}
    in_b=${prefix}-composite-configurable.xml
    out=${prefix}-2.xml
    xsltproc -o ${out} \
             --param with "'${in_b}'" \
             --param dontmerge "'userGroupProvider'" \
             ${merge} ${in_a}
    rm -f ${in_a} ${in_b}

    in_a=${out}
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
    in_b=${prefix}-file.xml
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
    xmllint --format $in_a > $out
    rm -f ${in_a}

    sed -i \
        -e "s|@@CONF_DIR@@|${CONF_DIR}|g" \
        $out
}

create_state_management_xml() {
    local principal=$(echo ${nifi_principal} | cut -d '/' -f 1)

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

create_tenants_nodes_hadoop_xml() {
    local prefix=$1
    local out=${prefix}-users.hadoop.xml

    echo '<?xml version="1.0" encoding="UTF-8"?>' > $out
    echo '<configuration>' >> $out
    echo '  <property>' >> $out
    echo '    <name>cdh.tenants.type</name>' >> $out
    echo '    <value>users</value>' >> $out
    echo '  </property>' >> $out

    local CMF_NODES_USER_GUIDS=()
    for i in $(grep nifi.cluster.node.protocol.port nifi-nodes.properties|sort|uniq); do
      local node_name=$(echo $i | cut -d':' -f 1)
      local node_guid=$(guid $i)
      CMF_NODES_USER_GUIDS+=($node_guid)
      echo '  <property>' >> $out
      echo "    <name>${node_guid}</name>" >> $out
      echo "    <value>CN=${node_name}${DN_SUFFIX}</value>" >> $out
      echo '  </property>' >> $out
    done

    local CMF_ADMINS_USER_GUIDS=()
    IFS='^' read -ra identities <<< ${NIFI_CMF_ADMINS}
    for i in "${identities[@]}"; do
      local identifier=$(guid "$i")
      CMF_ADMINS_USER_GUIDS+=($identifier)
      echo '  <property>' >> $out
      echo "    <name>${identifier}</name>" >> $out
      echo "    <value>${i}</value>" >> $out
      echo '  </property>' >> $out
    done

    echo '</configuration>' >> $out

    sed -i \
        -e "s|@@CMF_NODES_USER_GUIDS@@|$(echo ${CMF_NODES_USER_GUIDS[*]})|" \
        -e "s|@@NIFI_ADMIN_GUID@@|$(echo ${CMF_ADMINS_USER_GUIDS[*]})|" \
        ${prefix}-groups-safety-valve.hadoop.xml
}

create_tenants_xml() {
    local prefix=tenants
    local principal=$(echo ${nifi_principal} | cut -d '/' -f 1)

    create_tenants_nodes_hadoop_xml ${prefix}

    close_prefix_safety_valve_xml ${prefix}-groups "groups"
    close_prefix_safety_valve_xml ${prefix} "tenants"

    convert_prefix_hadoop_xml ${prefix}

    # Merge users and groups
    merge=${CDH_NIFI_XSLT}/merge.xslt
    in_a=${prefix}-groups-safety-valve.xml
    in_b=${prefix}-users.xml
    out=${prefix}-1.xml
    xsltproc -o ${out} \
             --param with "'${in_b}'" \
             ${merge} ${in_a}
    rm -f ${in_a} ${in_b}

    in_a=${out}
    out=${prefix}.xml
    xmllint --format ${in_a} > ${out}
    rm -f ${in_a}

    sed -i \
        -e "s|@@CMF_ADMINS_GUID@@|$(guid cmf-admins)|" \
        -e "s|@@CMF_NODES_GUID@@|$(guid cmf-nodes)|" \
        -e "s|@@PRINCIPAL@@|${principal}|" \
        $out
}

explode_arrays() {
    local input=$1

    array_type=colon_array
    for i in $(grep "\.${array_type}=" ${input}.properties); do
        key_prefix=${i/${array_type}=*/}
        value=${i/*${array_type}=/}
        exploded=$(explode_array $key_prefix $value)
        for item in $exploded; do
          sed -i -e "/${key_prefix}${array_type}=/a${item}" ${input}.properties
        done
        sed -i -e "/${key_prefix}${array_type}=/d" ${input}.properties
    done
}

explode_array() {
    local key_prefix=$1
    local value=$2

    IFS=':' read -ra array <<< $value
    for (( i=0; i<${#array[@]}; i++)); do
      echo $1$i=${array[$i]}
    done
}


update_nifi_properties() {
    local num_of_nodes=$(cut -d ':' -f 1 nifi-nodes.properties | sort | uniq | wc -l)
    local principal=$(echo ${nifi_principal} | cut -d '/' -f 1)

    if [ $NIFI_TLS_ENABLED == "true" ]; then
        echo -e "$(cat nifi-tls.properties)$(cat nifi.properties)" > nifi.properties
        sed -i \
            -e 's/nifi\.web\.http\./nifi.web.https./' \
            nifi.properties
    fi

    explode_arrays nifi

    sed -i \
        -e "s|@@CONF_DIR@@|${CONF_DIR}|g" \
        -e "s|@@CDH_NIFI_HOME@@|${CDH_NIFI_HOME}|g" \
        -e "s|@@ZK_QUORUM@@|${ZK_QUORUM}|g" \
        -e "s|@@ZK_ROOT@@|/${principal}|g" \
        -e "s|@@NIFI_CLUSTER_FLOW_ELECTION_MAX_CANDIDATES@@|$(( ($num_of_nodes + 1)/2 ))|g" \
        -e "s|@@NIFI_TLS_ENABLED@@|${NIFI_TLS_ENABLED}|g" \
        nifi.properties

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
    sed -i \
        -e "s|@@CONF_DIR@@|${CONF_DIR}|" \
        -e "s|@@NIFI_PRINCIPAL@@|${nifi_principal}|" \
        jaas.conf

    NIFI_JAVA_OPTS="${NIFI_JAVA_OPTS} -Djava.security.auth.login.config=${CONF_DIR}/conf/jaas.conf"
}

nifi_start() {
    CLASSPATH="${CONF_DIR}"
    [ -e "${CONF_DIR}/hadoop-conf" ] && CLASSPATH="${CLASSPATH}:${CONF_DIR}/hadoop-conf"
    [ -e "${CONF_DIR}/hbase-conf" ] && CLASSPATH="${CLASSPATH}:${CONF_DIR}/hbase-conf"
    [ -e "${CONF_DIR}/hive-conf" ] && CLASSPATH="${CLASSPATH}:${CONF_DIR}/hive-conf"

    IFS=':' read -ra parcel_dirnames <<< ${PARCEL_DIRNAMES}
    for p in "${parcel_dirnames[@]}"; do
        if [[ $p == GPLEXTRAS* ]]; then
            export NIFI_HDFS_AUX="${PARCELS_ROOT}/${p}/lib/hadoop/lib"
        fi
    done

    NIFI_JAVA_OPTS="${CSD_JAVA_OPTS} -cp '${CLASSPATH}:${CDH_NIFI_HOME}/lib/*' ${NIFI_JAVA_OPTS}"
    NIFI_JAVA_OPTS="-Djava.library.path=${JAVA_LIBRARY_PATH} ${NIFI_JAVA_OPTS}"

    run_nifi_cmd="cd ${CONF_DIR} && exec '${JAVA}' ${NIFI_JAVA_OPTS} org.apache.nifi.NiFi"

    unset HADOOP_CREDSTORE_PASSWORD
    unset NIFI_SEED
    eval "${run_nifi_cmd}"
}

nifi_reset() {
    cmd=$(get_property nifi-reset $1)
    exec sh -c "$cmd"
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
        exit 1
        ;;
esac
