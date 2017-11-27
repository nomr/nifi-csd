<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0"
                xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
                xmlns:str="http://exslt.org/strings"
                extension-element-prefixes="str">
  <xsl:template match="configuration" >
    <tenants>
    <xsl:choose>
      <xsl:when test="property[name='cdh.tenants.type' and value='groups']">
        <groups>
          <xsl:for-each select="property[not(starts-with(name, 'cdh'))]">
            <group identifier="{name}" name="{value}">
              <xsl:for-each select="str:split(description)">
                <xsl:element name="user">
                  <xsl:attribute name="identifier">
                    <xsl:value-of select="."/>
                  </xsl:attribute>
                </xsl:element>
              </xsl:for-each>
            </group>
          </xsl:for-each>
        </groups>
      </xsl:when>
      <xsl:when test="property[name='cdh.tenants.type' and value='users']">
        <users>
          <xsl:for-each select="property[not(starts-with(name, 'cdh'))]">
                <user identifier="{name}" identity="{value}"/>
          </xsl:for-each>
        </users>
      </xsl:when>
    </xsl:choose>
    </tenants>
  </xsl:template>
</xsl:stylesheet>
