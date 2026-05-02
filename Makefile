# HaMBridge v0.1 — Free Pascal build
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

FPCFLAGS := -MObjFPC -Scghi -O2 -gl -Xs
FPCFLAGS += -Fu$(SRCDIR) -Fu$(MQTTDIR) -FU$(OUTDIR)
# Link against versioned libevdev.so.2 (runtime package); no unversioned libevdev.so symlink required.
EVDEV_SO := $(firstword $(wildcard /usr/lib64/libevdev.so.2) $(wildcard /usr/lib/x86_64-linux-gnu/libevdev.so.2))
ifeq ($(EVDEV_SO),)
$(error libevdev.so.2 not found under /usr/lib64 or /usr/lib/x86_64-linux-gnu — install the libevdev runtime package (e.g. libevdev2 on Debian, libevdev on Fedora))
endif
EVDEV_LDIR := $(dir $(EVDEV_SO))
FPCFLAGS += -k-L$(EVDEV_LDIR) -k-l:libevdev.so.2
FPCFLAGS += -Fl/usr/lib64 -Fl/usr/lib/x86_64-linux-gnu

.PHONY: all clean run

all: $(BINARY)

$(OUTDIR):
	mkdir -p $(OUTDIR)

# Fetch and verify MQTT client sources (first build needs network: curl + unzip).
$(MQTTDIR)/mqtt.pas: | $(OUTDIR)
	@set -e; \
	mkdir -p $(dir $(MQTTZIP)); \
	if [ ! -f '$(MQTTZIP)' ]; then \
	  tmp="$(MQTTZIP).$$$$.part"; \
	  curl -fsSL -o "$$tmp" '$(FPC_MQTT_URL)'; \
	  mv -f "$$tmp" '$(MQTTZIP)'; \
	fi; \
	echo '$(FPC_MQTT_SHA256)  $(MQTTZIP)' | sha256sum -c -; \
	rm -rf '$(MQTT_EXTRACT)'; \
	unzip -qo '$(MQTTZIP)' -d '$(OUTDIR)/deps'

$(BINARY): $(OUTDIR) $(MQTTDIR)/mqtt.pas $(SRCDIR)/hambridge.lpr $(wildcard $(SRCDIR)/*.pas) $(wildcard $(MQTTDIR)/*.pas)
	$(FPC) $(FPCFLAGS) -o$(BINARY) $(SRCDIR)/hambridge.lpr

clean:
	rm -rf $(OUTDIR)

run: $(BINARY)
	$(BINARY) --config ./bridge.json --devices ./devices.json
