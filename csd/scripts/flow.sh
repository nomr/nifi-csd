NIFI_COMMON_SCRIPT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/common.sh"
. ${NIFI_COMMON_SCRIPT}

create_flow_xml() {
    local prefix=flow

    if [ -e "${prefix}.xml.gz" ]; then
        return 0
    fi

    close_prefix_safety_valve_xml ${prefix} "flowController"

    local in=${prefix}-safety-valve.xml
    local out=${prefix}.xml
    xmllint --format $in > $out
    rm -f $in

    sed -i \
        -e "s|@@FLOWCONTROLLER_ROOTGROUP_GUID@@|$(guid flowController/rootGroup)|" \
        $out

    gzip ${prefix}.xml
}

case "$1" in
    deploy)
        create_flow_xml
        cp -f --backup=numbered flow.xml.gz $2
        ;;
    *)
        echo "Usage flow.sh deploy"
        exit 1
        ;;
esac
