NIFI_COMMON_SCRIPT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/common.sh"
. ${NIFI_COMMON_SCRIPT}

create_authorizations_xml() {
    local prefix=authorizations

    if [ -e "${prefix}.xml" ]; then
        return
    fi

    close_prefix_safety_valve_xml ${prefix} "policies></authorizations"

    local in=${prefix}-safety-valve.xml
    local out=${prefix}.xml
    xmllint --format $in > $out
    rm -f $in

    sed -i \
        -e "s|@@POLICY_GUID_FLOW_R@@|$(guid /flow/R)|" \
        -e "s|@@POLICY_GUID_RESTRICTED_COMPONENTS_W|$(guid /restricted-components/W)|" \
        -e "s|@@POLICY_GUID_TENANTS_R|$(guid /tenants/R)|" \
        -e "s|@@POLICY_GUID_TENANTS_W|$(guid /tenants/W)|" \
        -e "s|@@POLICY_GUID_POLICIES_R|$(guid /policies/R)|" \
        -e "s|@@POLICY_GUID_POLICIES_W|$(guid /policies/W)|" \
        -e "s|@@POLICY_GUID_CONTROLLER_R|$(guid /controller/R)|" \
        -e "s|@@POLICY_GUID_CONTROLLER_W|$(guid /controller/W)|" \
        -e "s|@@POLICY_GUID_PROXY_W|$(guid /proxy/W)|" \
        -e "s|@@CM_NODE_GUID@@|$(guid cmf-nodes)|" \
        -e "s|@@CM_ADMIN_GUID@@|$(guid cmf-admins)|" \
        $out
}

case "$1" in
    deploy)
        create_authorizations_xml
        cp -f --backup=numbered authorizations.xml $2
        ;;
    *)
        echo "Usage authorizations.sh deploy"
        exit 1
        ;;
esac
