set -efu -o pipefail

. ${COMMON_SCRIPT}

warn() {
    echo "${PROGNAME}: $*"
}

die() {
    warn "$*"
    exit 1
}

guid() {
    local bits=$(echo "${1}#${NIFI_SEED}" | md5sum | cut -d' ' -f 1)
    echo ${bits:0:8}-${bits:8:4}-${bits:12:4}-${bits:16:4}-${bits:20}
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

    # hadoop.xml or hadoop_xml files use "configuration" as xml_tag
    for sv_xml in `find . -type f -name "${prefix}-*safety-valve.hadoop[_,.]xml"`; do
        close_xml_file "configuration" ${sv_xml}
    done
}

convert_prefix_hadoop_xml() {
    local prefix=$1
    local xslt=${2:-aux/${prefix}.xslt}

    local basename=$(basename $prefix)
    local dirname=$(dirname $prefix)

    for h_xml in `find ${dirname} -type f -name "${basename}-*.hadoop[_,.]xml"`; do
        xsltproc -o ${h_xml//hadoop[_.]xml/xml} ${xslt} ${h_xml}
        rm -f ${h_xml}
    done
}

### REMOVE THESE WHEN PKI_COMMON_SCRIPTS is created
load_vars() {
    local prefix=$1
    local file=$2.vars

    eval $(sed -e 's/ /\\ /g' \
               -e 's/"/\\"/g' \
               -e 's/^/export ${prefix}_/' $file)
}
envsubst_all() {
    local var_prefix=$1
    local filename_prefix=${2:-}

    local shell_format="\$CONF_DIR,\$ZK_QUORUM"
    for i in $(eval "echo \${!${var_prefix}*}"); do
        shell_format="${shell_format},\$$i"
    done

    for i in $(find . -maxdepth 1 -type f -name "${filename_prefix}*.envsubst*"); do
        cat $i | envsubst $shell_format > ${i/\.envsubst/}
        rm -f $i
    done
}
get_peers() {
    local file=$1

    cat $1.pvars \
        | cut -d: -f 1 \
        | sort \
        | uniq
}
get_property() {
    local file=$1
    local key=$2

    for suffix in properties pvars; do
        if [ -f "${file}.${suffix}" ]; then
            file="${file}.${suffix}"
            break
        fi
    done
    local line=$(grep "$key=" ${file} | tail -1)

    echo "${line/$key=/}"
}
base64_to_hex() {
    echo $1 \
      | base64 -d \
      | od -t x8 \
      | cut -s -d' ' -f2- \
      | sed -e ':a;N;$!ba;s/\n/ /g' \
      | sed -e 's/ //g'
    # do not join the last two sed lines
}


