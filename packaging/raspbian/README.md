# HaMBridge on Raspberry Pi OS / Debian (native build)

Build **on the Pi** (or any Debian-derived armhf / aarch64 host) with the same `Makefile` as on Fedora: the Makefile discovers `libevdev.so.2` under common multiarch paths (`aarch64-linux-gnu`, `arm-linux-gnueabihf`, `x86_64-linux-gnu`, …).

## Install build dependencies

```bash
sudo apt-get update
sudo apt-get install -y fpc fp-units-fcl fp-units-rtl libevdev-dev make unzip curl
```

Optional: `git` if you clone the repository.

## Build

```bash
cd /path/to/Visca-MQTT-bridge
make
./build/hambridge --version
```

First build downloads the pinned **fpc-mqtt-client** zip into `build/deps/` (needs network).

## Runtime

```bash
sudo apt-get install -y libevdev2
```

The service user needs read access to configured `/dev/input/event*` and serial devices; reuse `packaging/systemd/` and `packaging/udev/` from the repo root where appropriate (paths match Debian/Raspberry Pi OS under `/usr/lib/systemd/system`).

## Debian package (`.deb`)

Build **on the same architecture you want to install** (e.g. 64-bit Pi OS: **arm64**; 32-bit Pi OS: **armhf**). The source package’s `packaging/debian/control` declares **`Architecture: arm64`** by default; if you build on **armhf** or **amd64**, edit that one line to match `dpkg --print-architecture` before building. (The repo keeps a root **`debian`** symlink → **`packaging/debian`** so `dpkg-buildpackage` finds the standard layout.)

Install packaging tools and the same compiler/runtime deps as a native `make`:

```bash
sudo apt-get update
sudo apt-get install -y build-essential debhelper fakeroot dpkg-dev \
  fpc fp-units-fcl fp-units-rtl libevdev-dev make unzip curl
```

From the repository root:

```bash
make debian-deb
```

`dpkg-buildpackage` writes **`../hambridge_<version>_<arch>.deb`** (and related `.changes` / `.buildinfo`) **one directory above** the repo. Install on the same machine (or same arch):

```bash
sudo dpkg -i ../hambridge_*_*.deb
sudo apt-get install -f   # if dpkg reports missing dependencies
```

The package installs `/usr/bin/hambridge` and `hambridge.service`; **`postinst`** creates system user **`hambridge`** if missing. Add **`/etc/hambridge/`** configs and udev rules yourself (see `packaging/README.md`).

## Cross-compile from Fedora

Not covered here: that requires an FPC cross toolchain and matching RTL/units for `arm-linux`. For most users, **native `make` on the Pi** is simpler.

## Quick reference

From the repo root: `make raspbian-help` prints a short dependency reminder.
