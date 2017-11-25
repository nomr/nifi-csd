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


