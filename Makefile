# HaMBridge v0.1 — Free Pascal build
FPC ?= fpc
SRCDIR := src
MQTTDIR := third_party/fpc-mqtt-client/mqtt
OUTDIR := build
BINARY := $(OUTDIR)/hambridge

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

$(BINARY): $(OUTDIR) $(SRCDIR)/hambridge.lpr $(wildcard $(SRCDIR)/*.pas) $(wildcard $(MQTTDIR)/*.pas)
	$(FPC) $(FPCFLAGS) -o$(BINARY) $(SRCDIR)/hambridge.lpr

clean:
	rm -rf $(OUTDIR)

run: $(BINARY)
	$(BINARY) --config ./bridge.json --devices ./devices.json
