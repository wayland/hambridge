# HaMBridge — Free Pascal build (native: Fedora x86_64, Debian/Raspberry Pi OS armhf & aarch64, …)
FPC ?= fpc
SRCDIR := src
OUTDIR := build
BINARY := $(OUTDIR)/hambridge

# prof7bit/fpc-mqtt-client — downloaded at build time (see $(MQTTDIR) rule); not vendored in git.
FPC_MQTT_TAG := 1.2
FPC_MQTT_URL := https://github.com/prof7bit/fpc-mqtt-client/archive/refs/tags/$(FPC_MQTT_TAG).zip
# sha256sum of the release zip (update when bumping FPC_MQTT_TAG).
FPC_MQTT_SHA256 := 702ded75607d2ba8429fffc3509bbb7607466be9596bc23d8bd73c13f8e74214
MQTTZIP := $(OUTDIR)/deps/fpc-mqtt-client-$(FPC_MQTT_TAG).zip
MQTT_EXTRACT := $(OUTDIR)/deps/fpc-mqtt-client-$(FPC_MQTT_TAG)
MQTTDIR := $(MQTT_EXTRACT)/mqtt
MQTT_PATCH := patches/fpc-mqtt-client-$(FPC_MQTT_TAG)-tls-verify-before-connect.patch

FPCFLAGS := -MObjFPC -Scghi -O2 -gl -Xs
FPCFLAGS += -Fu$(SRCDIR) -Fu$(MQTTDIR) -FU$(OUTDIR)
# Link against versioned libevdev.so.2 (runtime package); no unversioned libevdev.so symlink required.
EVDEV_SO := $(firstword $(wildcard /usr/lib64/libevdev.so.2) \
  $(wildcard /usr/lib/x86_64-linux-gnu/libevdev.so.2) \
  $(wildcard /usr/lib/aarch64-linux-gnu/libevdev.so.2) \
  $(wildcard /usr/lib/arm-linux-gnueabihf/libevdev.so.2))
ifeq ($(EVDEV_SO),)
$(error libevdev.so.2 not found — install libevdev (e.g. Debian libevdev2 / Raspberry Pi OS: same; Fedora: libevdev). See packaging/raspbian/README.md)
endif
EVDEV_LDIR := $(dir $(EVDEV_SO))
FPCFLAGS += -k-L$(EVDEV_LDIR) -k-l:libevdev.so.2
FPCFLAGS += -Fl/usr/lib64 -Fl/usr/lib/x86_64-linux-gnu -Fl/usr/lib/aarch64-linux-gnu -Fl/usr/lib/arm-linux-gnueabihf

# Keep in sync with src/hambridge.lpr AppVersion and packaging/Redhat/hambridge.spec Version.
RPM_VER := 0.5.2

# FPCUnit (fcl-fpcunit) for `make test` — path varies by distro / multiarch.
FPC_VER := $(shell fpc -iV 2>/dev/null)
FPC_OS := $(shell fpc -iTO 2>/dev/null)
FPC_CPU := $(shell fpc -iTP 2>/dev/null)
FPCUNIT_DIR := $(firstword $(wildcard /usr/lib64/fpc/$(FPC_VER)/units/$(FPC_CPU)-$(FPC_OS)/fcl-fpcunit) \
  $(wildcard /usr/lib/fpc/$(FPC_VER)/units/$(FPC_CPU)-$(FPC_OS)/fcl-fpcunit))
TESTSRC := tests/hambridge_tests.lpr tests/fixturepaths.pas tests/test_devicesconfig.pas tests/test_viscamapping.pas tests/test_bridgeconfig.pas
TESTBIN := $(OUTDIR)/hambridge_tests
TESTFLAGS := -MObjFPC -Scghi -O2 -gl -Futests -Fusrc -Fu$(MQTTDIR) -Fu$(FPCUNIT_DIR) -FU$(OUTDIR)
ifeq ($(FPCUNIT_DIR),)
$(error fcl-fpcunit not found (FPC $(FPC_VER), $(FPC_CPU)-$(FPC_OS)) — install the full fpc / fpc-src package that provides FPCUnit)
endif
RPM_TOPDIR := $(abspath build/rpmbuild)
RPM_SPEC := packaging/Redhat/hambridge.spec

DISTDIR := dist
RELEASE_TAR := $(DISTDIR)/hambridge-$(RPM_VER)-linux-x86_64.tar.gz

.PHONY: all clean run test release-tarball release-checksums verify-release-pins verify-release-tag \
	fedora-rpm-sources fedora-rpm fedora-test raspbian-help debian-deb

all: $(BINARY)

$(OUTDIR):
	mkdir -p $(OUTDIR)

# Fetch, verify, unzip, and patch MQTT client sources (first build needs network: curl + unzip + patch).
$(MQTTDIR)/mqtt.pas: $(MQTT_PATCH) | $(OUTDIR)
	@set -e; \
	command -v patch >/dev/null 2>&1 || { echo 'patch(1) required (e.g. dnf install patch, apt install patch)' >&2; exit 1; }; \
	mkdir -p $(dir $(MQTTZIP)); \
	if [ ! -f '$(MQTTZIP)' ]; then \
	  tmp="$(MQTTZIP).$$$$.part"; \
	  curl -fsSL -o "$$tmp" '$(FPC_MQTT_URL)'; \
	  mv -f "$$tmp" '$(MQTTZIP)'; \
	fi; \
	echo '$(FPC_MQTT_SHA256)  $(MQTTZIP)' | sha256sum -c -; \
	rm -rf '$(MQTT_EXTRACT)'; \
	unzip -qo '$(MQTTZIP)' -d '$(OUTDIR)/deps'; \
	if ! grep -q 'TLS verification rejected by application' '$(MQTTDIR)/mqtt.pas'; then \
	  patch -d '$(MQTT_EXTRACT)' -p1 --forward --batch < '$(CURDIR)/$(MQTT_PATCH)'; \
	fi; \
	grep -q 'TLS verification rejected by application' '$(MQTTDIR)/mqtt.pas' \
	  || { echo 'MQTT patch did not apply — check $(MQTT_PATCH) vs FPC_MQTT_TAG' >&2; exit 1; }

$(BINARY): $(OUTDIR) $(MQTTDIR)/mqtt.pas $(SRCDIR)/hambridge.lpr $(wildcard $(SRCDIR)/*.pas) $(wildcard $(MQTTDIR)/*.pas)
	$(FPC) $(FPCFLAGS) -o$(BINARY) $(SRCDIR)/hambridge.lpr

$(TESTBIN): $(OUTDIR) $(MQTTDIR)/mqtt.pas $(TESTSRC) $(wildcard $(SRCDIR)/*.pas)
	$(FPC) $(TESTFLAGS) -o$(TESTBIN) tests/hambridge_tests.lpr

test: $(TESTBIN)
	@"$(TESTBIN)" --all --format=plain

clean:
	rm -rf $(OUTDIR)

# Release tarball for GitHub Actions (§10.6.5).
release-tarball: $(BINARY)
	@mkdir -p '$(DISTDIR)'
	@tmpdir=$$(mktemp -d); \
	trap 'rm -rf "$$tmpdir"' EXIT; \
	staging="$$tmpdir/hambridge-$(RPM_VER)"; \
	mkdir -p "$$staging/config/mappings"; \
	cp '$(BINARY)' LICENSE README.md "$$staging/"; \
	cp config/hambridge.yaml.example "$$staging/config/"; \
	cp config/mappings/visca.yaml.example "$$staging/config/mappings/"; \
	tar -C "$$tmpdir" -czf '$(RELEASE_TAR)' "hambridge-$(RPM_VER)"

release-checksums: release-tarball
	@cd '$(DISTDIR)' && sha256sum "$$(basename '$(RELEASE_TAR)')" > SHA256SUMS

verify-release-pins:
	@./scripts/ci/verify-release-pins.sh

verify-release-tag:
	@./scripts/ci/verify-release-tag.sh

run: $(BINARY)
	@mkdir -p config/mappings
	@test -f ./config/hambridge.yaml || cp config/hambridge.yaml.example ./config/hambridge.yaml
	@test -f ./config/mappings/visca.yaml || cp config/mappings/visca.yaml.example ./config/mappings/visca.yaml
	$(BINARY) --config ./config/hambridge.yaml

# Native build on Raspberry Pi OS / Debian: install deps then `make` (see packaging/raspbian/README.md).
raspbian-help:
	@echo 'Raspberry Pi OS / Debian (on the Pi):'
	@echo '  sudo apt-get update && sudo apt-get install -y fpc fp-units-fcl fp-units-rtl libevdev-dev make unzip curl patch'
	@echo '  cd /path/to/Visca-MQTT-bridge && make'
	@echo '  ./build/hambridge --version'
	@echo 'Runtime: sudo apt-get install -y libevdev2 (or libevdev2 + matching arch multiarch).'
	@echo 'Debian .deb: sudo apt-get install -y build-essential debhelper fakeroot fpc libevdev-dev make unzip curl patch'
	@echo '  then: make debian-deb   (outputs ../hambridge_*_*.deb — see packaging/raspbian/README.md; debian/ → packaging/debian)'

# Debian / Raspberry Pi OS .deb (run on Debian-derived host; dpkg-buildpackage writes to parent dir).
debian-deb:
	@command -v dpkg-buildpackage >/dev/null 2>&1 || { echo 'debian-deb: install dpkg-dev debhelper (Debian/Raspberry Pi OS)' >&2; exit 1; }
	dpkg-buildpackage -us -uc -b -rfakeroot

# --- Fedora RPM (needs: git, rpm-build, fpc, gcc, make, unzip, patch, systemd-rpm-macros) ---
# Uses a private rpmbuild tree under build/rpmbuild/ (removed by make clean).
# Source1 zip is copied from build/deps/ when present to avoid an extra download.

fedora-rpm-sources:
	@command -v git >/dev/null 2>&1 || { echo 'fedora-rpm: git is required' >&2; exit 1; }
	@command -v rpmbuild >/dev/null 2>&1 || { echo 'fedora-rpm: install rpm-build (dnf install rpm-build)' >&2; exit 1; }
	@test -d .git || { echo 'fedora-rpm: need a git checkout (git archive uses HEAD)' >&2; exit 1; }
	mkdir -p '$(RPM_TOPDIR)'/{BUILD,BUILDROOT,RPMS/noarch,RPMS/x86_64,RPMS/aarch64,SRPMS,SOURCES,SPECS}
	git archive --format=tar.gz --prefix=hambridge-$(RPM_VER)/ \
	  -o '$(RPM_TOPDIR)/SOURCES/hambridge-$(RPM_VER).tar.gz' HEAD
	@set -e; z='$(RPM_TOPDIR)/SOURCES/fpc-mqtt-client-$(FPC_MQTT_TAG).zip'; \
	if [ -f '$(MQTTZIP)' ]; then cp -f '$(MQTTZIP)' "$$z"; \
	else curl -fsSL -o "$$z.part" '$(FPC_MQTT_URL)' && mv -f "$$z.part" "$$z"; fi; \
	echo '$(FPC_MQTT_SHA256)  '"$$z" | sha256sum -c -
	install -Dpm0644 '$(RPM_SPEC)' '$(RPM_TOPDIR)/SPECS/hambridge.spec'

fedora-rpm: fedora-rpm-sources
	rpmbuild -ba --define "_topdir $(RPM_TOPDIR)" '$(RPM_TOPDIR)/SPECS/hambridge.spec'

# Smoke-test the binary RPM: metadata, file list, extract hambridge --version (no system install).
fedora-test: fedora-rpm
	@command -v rpm2cpio >/dev/null 2>&1 || { echo 'fedora-test: install rpm-build (rpm2cpio)' >&2; exit 1; }
	@set -e; \
	rpmfile=$$(find '$(RPM_TOPDIR)/RPMS' -maxdepth 2 -type f -name 'hambridge-$(RPM_VER)-*.rpm' ! -name '*debuginfo*' | head -n1); \
	test -n "$$rpmfile" || { echo 'fedora-test: no hambridge RPM under $(RPM_TOPDIR)/RPMS' >&2; exit 1; }; \
	echo "==> RPM: $$rpmfile"; \
	rpm -qp "$$rpmfile" --requires | grep -E 'libevdev|openssl|systemd' >/dev/null; \
	rpm -qpl "$$rpmfile" | grep -E '^/usr/bin/hambridge$$|^/usr/lib/systemd/system/hambridge.service$$' >/dev/null; \
	echo '==> Extract and run hambridge --version'; \
	tmpdir=$$(mktemp -d); \
	trap 'rm -rf "$$tmpdir"' EXIT; \
	(cd "$$tmpdir" && rpm2cpio "$$rpmfile" | cpio -idm 2>/dev/null); \
	"$$tmpdir/usr/bin/hambridge" --version; \
	if command -v rpmlint >/dev/null 2>&1; then echo '==> rpmlint (optional)'; rpmlint "$$rpmfile" || true; fi
