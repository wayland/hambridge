# HaMBridge on Raspberry Pi OS / Debian (native build)

Build **on the Pi** (or any Debian-derived armhf / aarch64 host) with the same `Makefile` as on Fedora: the Makefile discovers `libevdev.so.2` under common multiarch paths (`aarch64-linux-gnu`, `arm-linux-gnueabihf`, `x86_64-linux-gnu`, …).

## Debian package (`.deb`)

Build **on the same architecture you want to install** (e.g. 64-bit Pi OS: **arm64**; 32-bit Pi OS: **armhf**). (The repo keeps a root **`debian`** symlink → **`packaging/debian`** so `dpkg-buildpackage` finds the standard layout.)

If you have `deb-src` enabled in APT, you can install build dependencies straight from `debian/control` (Fedora’s `dnf builddep` equivalent):

```bash
sudo apt-get update
sudo apt-get build-dep -y .
```

Then build the package:

```bash
dpkg-buildpackage -b -us -uc
```

Or use the repo wrapper target:

```bash
make debian-deb
```

`dpkg-buildpackage` writes **`../hambridge_<version>_<arch>.deb`** (and related `.changes` / `.buildinfo`) **one directory above** the repo. Install on the same machine (or same arch):

```bash
sudo dpkg -i ../hambridge_*_*.deb
sudo apt-get install -f   # if dpkg reports missing dependencies
```

The package installs `/usr/bin/hambridge` and `hambridge.service`; **`postinst`** creates system user **`hambridge`** if missing. Add **`/etc/hambridge/`** configs and udev rules yourself (see `packaging/README.md`).

## Manual build

### Install build dependencies

```bash
sudo apt-get update
sudo apt-get install -y fpc fp-units-fcl fp-units-rtl libevdev-dev make unzip curl
```

Optional: `git` if you clone the repository.

### Build

```bash
cd /path/to/hambridge
make
./build/hambridge --version
```

First build downloads the pinned **fpc-mqtt-client** zip into `build/deps/` (needs network).

### Runtime

```bash
sudo apt-get install -y libevdev2
```

The service user needs read access to configured `/dev/input/event*` and serial devices; reuse `packaging/systemd/` and `packaging/udev/` from the repo root where appropriate (paths match Debian/Raspberry Pi OS under `/usr/lib/systemd/system`).

## Quick reference

From the repo root: `make raspbian-help` prints a short dependency reminder.
