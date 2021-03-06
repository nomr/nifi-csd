<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0"
                xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:template match="configuration" >
    <loginIdentityProviders>
    <xsl:choose>
      <xsl:when test="property[name='cdh.login.identity.providers.type' and value='provider']">
        <provider>
          <xsl:apply-templates/>
        </provider>
      </xsl:when>
    </xsl:choose>
    </loginIdentityProviders>
  </xsl:template>

  <xsl:include href="hadoop2nifi.xslt"/>

</xsl:stylesheet>
