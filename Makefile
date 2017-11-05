TAG:=$(shell git describe --tags | sed -e 's/^v//')
TAG_DIST=$(shell echo $(TAG) | sed -r -e 's/.*-([[:digit:]]+)-g.*/\1/')
TAG_HASH=$(shell echo $(TAG) | sed -r -e 's/^.*(g[0-9a-f]+|$$)/\1/')
NIFI_VERSION=$(shell echo $(TAG) | sed -r -e 's/\+nifi.*//')

ifeq ($(TRAVIS), true)
  VERSION=$(TAG)
else
  VERSION=0.1.0
endif

.INTERMEDIATE: %-SHA256
.DELETE_ON_ERROR:
.PHONY: release install .cookie NIFI-$(VERSION).jar

all: info clean install

info:
	@echo '       Git Tag: $(TAG)'
	@[ ! -z $(TAG) ]
	@echo '      Tag dist: $(TAG_DIST)'
	@echo '      Tag hash: $(TAG_HASH)'
	@echo '  NiFi version: $(NIFI_VERSION)'
	@echo '   CSD version: $(VERSION)'

clean:
	rm -rf release NIFI-*

release: NIFI-$(VERSION).jar
	([ -d /opt/cloudera/csd ] && rm -rf /opt/cloudera/csd/NIFI-*.jar && cp $< /opt/cloudera/csd) || true

install: NIFI-0.1.0.jar .cookie
	cp $< /opt/cloudera/csd
	chown cloudera-scm:cloudera-scm /opt/cloudera/csd/$<
	curl -b .cookie -s http://localhost:7180/cmf/csd/refresh | jq
	curl -b .cookie -s -X POST http://localhost:7180/api/v17/clusters/zeus/services/nifi/commands/stop | jq || true
	curl -b .cookie -s 'http://localhost:7180/cmf/csd/uninstall?csdName=NIFI-0.1.0&force=true' | jq || true
	curl -b .cookie -s http://localhost:7180/cmf/csd/install?csdName=NIFI-0.1.0 | jq
	curl -b .cookie -s -X POST http://localhost:7180/api/v17/clusters/zeus/services/nifi/commands/start | jq || true

uninstall:
	curl -s http://localhost:7180/cmf/csd/uninstall?csdName=NIFI-0.1.0 -b .cookie  | jq

.cookie:
	curl -s http://localhost:7180/cmf/login/j_spring_security_check -c .cookie -d "j_username=$(CM_USR)&j_password=$(CM_PSW)"


NIFI-$(VERSION): csd NIFI-$(VERSION)/images/icon.png validator.jar
	rsync --exclude '*.swp' -a  $</ $@/
	cat $</descriptor/service.sdl | jq ".version=\"$(subst NIFI-,,$@)\"" > $@/descriptor/service.sdl
	java -jar validator.jar -l 'TLS' -s $@/descriptor/service.sdl || (rm -rf $@ && false)

NIFI-$(VERSION).jar: NIFI-$(VERSION)
	jar cvf $@ -C $< .



# Remote dependencies
validator.jar:
	cd tools/cm_ext && mvn -q install && cd -
	ln tools/cm_ext/validator/target/validator.jar .

nifi-$(NIFI_VERSION)-bin.tar.gz: nifi-$(NIFI_VERSION)-bin.tar.gz-SHA256
	wget 'https://www.apache.org/dyn/mirrors/mirrors.cgi?action=download&filename=nifi/$(NIFI_VERSION)/$@' -O $@
	touch $@
	sha256sum -c $<

%/icon.ico:
	@mkdir -p $(shell dirname $@)
	wget https://nifi.apache.org/assets/images/nifi16.ico -O $@


# Implicit rules
%-SHA256: SHA256SUMS
	grep $(subst -SHA256,,$@) SHA256SUMS > $@

%.png: %.ico
	convert $< $@
