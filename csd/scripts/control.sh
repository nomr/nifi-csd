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

    for h_xml in `find . -type f -name "${prefix}-*.hadoop_xml"`; do
        xsltproc -o ${h_xml//hadoop_xml/xml} aux/${prefix}.xslt ${h_xml}
        rm -f ${h_xml}
    done
}

hadoop_xml_to_json()
{
    local file=$1

    xsltproc aux/hadoop2element-value.xslt ${file}.hadoop_xml > ${file}.xml
    xsltproc aux/xml2json.xslt ${file}.xml | jq '
      .configuration |
      .port=(.port| tonumber) |
      .days=(.days | tonumber) |
      .keySize=(.keySize | tonumber) |
      .reorderDn=(.reorderDn == "true")' > ${file}.json
}

tls_init() {
    # NiFi 1.4.0 was compiled with 1.8.0
    locate_java8_home $1

    # Simulate NIFI_TOOLKIT_HOME
    NIFI_TOOLKIT_HOME=$(pwd)
    [ -e lib ] || ln -s ${CDH_NIFI_TOOLKIT_HOME}/lib .

    hadoop_xml_to_json server
}

tls_run() {
    LIBS="${NIFI_TOOLKIT_HOME}/lib/*"

    CLASSPATH=".:${LIBS}"

    export JAVA_HOME="$JAVA_HOME"
    export NIFI_TOOLKIT_HOME="$NIFI_TOOLKIT_HOME"

    umask 0077

    case "$1" in
        run)
            exec "${JAVA}" -cp "${CLASSPATH}" \
                ${JAVA_OPTS:--Xms12m -Xmx24m} \
                ${CSD_JAVA_OPTS} \
                org.apache.nifi.toolkit.tls.TlsToolkitMain \
                server -F \
                --configJsonIn server.json
        ;;
        deploy)
            echo "deploy script"
        ;;
    esac
}

tls() {
    tls_init "$1"
    tls_run "$@"
}

tls_client_init() {
    hadoop_xml_to_json tls-client

    CLASSPATH=".:${CDH_NIFI_TOOLKIT_HOME}/lib"

    "${JAVA}" -cp "${CLASSPATH}" \
                ${JAVA_OPTS:--Xms12m -Xmx24m} \
                ${CSD_JAVA_OPTS} \
                org.apache.nifi.toolkit.tls.TlsToolkitMain \
                client -F \
                -c `hostname` \
                --configJson tls-client.json

}

nifi_init() {
    # Unlimit the number of file descriptors if possible
    unlimitFD

    # NiFi 1.4.0 was compiled with 1.8.0
    locate_java8_home $1

    # TLS Client Init
    tls_client_init

    # Simulate NIFI_HOME
    [ -d conf ] || mkdir conf
    [ -e lib ] || ln -s ${CDH_NIFI_HOME}/lib .
    [ -e docs ] || ln -s ${CDH_NIFI_HOME}/docs .

    # Update bootstrap files
    update_bootstrap_conf
    close_xml_file "services" bootstrap-notification-services.xml


    [ -e 'login-identity-providers.xml' ] || create_login_identity_providers_xml
    [ -e 'state-management.xml' ] || create_state_management_xml
    [ -e 'authorizers.xml' ] || create_authorizers_xml

    update_logback_xml
    update_nifi_properties

    find ${CONF_DIR} -maxdepth 1 -type f -name '*.conf' -exec ln -sf {} ${CONF_DIR}/conf \;
    find ${CONF_DIR} -maxdepth 1 -type f -name '*.xml' -exec ln -sf {} ${CONF_DIR}/conf \;
    find ${CONF_DIR} -maxdepth 1 -type f -name '*.properties' -exec ln -sf {} ${CONF_DIR}/conf \;

    init_bootstrap
}

create_login_identity_providers_xml() {
    prefix=login-identity-providers

    convert_prefix_hadoop_xml ${prefix}

    close_prefix_safety_valve_xml ${prefix} "loginIdentityProviders"

    # Merge Providers
    merge=aux/merge.xslt
    in_a=${prefix}-kerberos.xml
    in_b=${prefix}-safety-valve.xml
    out=${prefix}.xml
    xsltproc -o ${out} \
             --param with "'${in_b}'" \
             --param dontmerge "'provider'" \
             ${merge} ${in_a}
    rm -f ${in_a} ${in_b}
}

create_authorizers_xml() {
    prefix=authorizers
    convert_prefix_hadoop_xml ${prefix}

    close_prefix_safety_valve_xml ${prefix} "authorizers"
     
    # Merge with User Group Providers
    merge=aux/merge.xslt
    prefix=authorizers-user-group-provider
    in_a=${prefix}-file.xml
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
    out=authorizers.xml
    xsltproc -o ${out} \
             --param with "'${in_b}'" \
             --param dontmerge "'authorizer'" \
             ${merge} ${in_a}
    rm -f ${in_a} ${in_b}
}

create_state_management_xml() {
    prefix=state-management
    convert_prefix_hadoop_xml ${prefix}

    close_prefix_safety_valve_xml ${prefix} "stateManagement"

    # Merge
    merge=aux/merge.xslt
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
}

update_nifi_properties() {
    sed -i \
        -e "s|@@CDH_NIFI_HOME@@|${CDH_NIFI_HOME}|g" \
        nifi.properties

    if [ $NIFI_SSL_ENABLED == "true" ]; then
        sed -i \
            -e 's/nifi.web.http\..*//' \
            nifi.properties
    fi
}

init_bootstrap() {
    #BOOTSTRAP_LIBS=`find "${CDH_NIFI_HOME}/lib/bootstrap" -maxdepth 1 -name '*.jar' | tr "\n" ":"`
    BOOTSTRAP_LIBS="${CDH_NIFI_HOME}/lib/bootstrap/*"

    BOOTSTRAP_CLASSPATH="${CONF_DIR}:${BOOTSTRAP_LIBS}"
    if [ -n "${TOOLS_JAR}" ]; then
        BOOTSTRAP_CLASSPATH="${TOOLS_JAR}:${BOOTSTRAP_CLASSPATH}"
    fi

    #setup directory parameters
    BOOTSTRAP_LOG_PARAMS="-Dorg.apache.nifi.bootstrap.config.log.dir='${NIFI_LOG_DIR}'"
    BOOTSTRAP_PID_PARAMS="-Dorg.apache.nifi.bootstrap.config.pid.dir='${NIFI_PID_DIR}'"
    BOOTSTRAP_CONF_PARAMS="-Dorg.apache.nifi.bootstrap.config.file='${CONF_DIR}/conf/bootstrap.conf'"

    BOOTSTRAP_DIR_PARAMS="${BOOTSTRAP_LOG_PARAMS} ${BOOTSTRAP_PID_PARAMS} ${BOOTSTRAP_CONF_PARAMS}"
}

update_bootstrap_conf() {
    BOOTSTRAP_CONF="${CONF_DIR}/bootstrap.conf";
    # Update bootstrap.conf
    insert_if_not_exists "lib.dir=${CONF_DIR}/lib" ${BOOTSTRAP_CONF}
    insert_if_not_exists "conf.dir=${CONF_DIR}/conf" ${BOOTSTRAP_CONF}

    # Disable JSR 199 so that we can use JSP's without running a JDK
    insert_if_not_exists "java.arg.1=-Dorg.apache.jasper.compiler.disablejsr199=true" ${BOOTSTRAP_CONF}
    # JVM memory settings
    insert_if_not_exists "java.arg.2=-Xms512m" ${BOOTSTRAP_CONF}
    insert_if_not_exists "java.arg.3=-Xmx512m" ${BOOTSTRAP_CONF}

    # Enable Remote Debugging
    #java.arg.debug=-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=8000

    insert_if_not_exists "java.arg.4=-Djava.net.preferIPv4Stack=true" ${BOOTSTRAP_CONF}

    # allowRestrictedHeaders is required for Cluster/Node communications to work properly
    insert_if_not_exists "java.arg.5=-Dsun.net.http.allowRestrictedHeaders=true" ${BOOTSTRAP_CONF}
    insert_if_not_exists "java.arg.6=-Djava.protocol.handler.pkgs=sun.net.www.protocol" ${BOOTSTRAP_CONF}

    # The G1GC is still considered experimental but has proven to be very advantageous in providing great
    # performance without significant "stop-the-world" delays.
    insert_if_not_exists "java.arg.13=-XX:+UseG1GC" ${BOOTSTRAP_CONF}

    #Set headless mode by default
    insert_if_not_exists "java.arg.14=-Djava.awt.headless=true" ${BOOTSTRAP_CONF}

    # Sets the provider of SecureRandom to /dev/urandom to prevent blocking on VMs
    insert_if_not_exists "java.arg.15=-Djava.security.egd=file:/dev/urandom" ${BOOTSTRAP_CONF}
}

update_logback_xml() {
    sed -i 's/<configuration>/<configuration scan="true" scanPeriod="30 seconds">/' logback.xml
}

nifi_run() {
    run_nifi_cmd="'${JAVA}' -cp '${BOOTSTRAP_CLASSPATH}' -Xms12m -Xmx24m ${BOOTSTRAP_DIR_PARAMS} org.apache.nifi.bootstrap.RunNiFi $@"

    if [ "$1" = "run" ]; then
      # Use exec to handover PID to RunNiFi java process, instead of foking it as a child process
      run_nifi_cmd="exec ${run_nifi_cmd}"
    fi

    eval "cd ${CONF_DIR} && ${run_nifi_cmd}"
    EXIT_STATUS=$?

    # Wait just a bit (3 secs) to wait for the logging to finish and then echo a new-line.
    # We do this to avoid having logs spewed on the console after running the command and then not giving
    # control back to the user
    sleep 3
    echo
}

nifi() {
    nifi_init "$1"
    nifi_run "$@"
}

case "$1" in
    nifi-run|nifi-stop)
        nifi ${1//nifi-/} "${@:2}"
        ;;
    tls-run|tls-deploy)
        tls ${1//tls-/} "${@:2}"
        ;;
    *)
        echo "Usage nifi {stop|run|status|dump|env}"
        ;;
esac
