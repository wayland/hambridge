# Developing HaMBridge (Hardware-MQTT Bridge)

This document is for **building from source** and contributor-oriented setup. For what the
project does and how to run a binary you already have, see [README.md](README.md). The full
design is in [Visca-MQTT-bridge-Plan.md](Visca-MQTT-bridge-Plan.md). **Release notes:** [CHANGELOG.md](CHANGELOG.md).
**Backlog / upcoming minors:** [ROADMAP.md](ROADMAP.md).

The product name is **HaMBridge**; the v0.1 build produces the `hambridge` binary.

## Toolchain (v0.1)

- **Linux** (v0.1 is Linux-only because of `libevdev`).
- **Free Pascal Compiler** 3.2.x or newer (`fpc`).
- **GNU Make** (`make`).
- **`curl`** and **`unzip`** — used once per clean tree to fetch the MQTT client zip.
- **MQTT client**: [prof7bit/fpc-mqtt-client](https://github.com/prof7bit/fpc-mqtt-client) is
  **downloaded when you run `make`**: the Makefile fetches a pinned release zip into
  `build/deps/`, checks **SHA256**, and unpacks it. The first build needs **network access**,
  `curl`, and `unzip`. Bump the tag and checksum in the `Makefile` when you intentionally
  upgrade the client.
- **`libevdev` shared library** (`libevdev.so.2`) in a standard library directory so the
  Makefile can link against it:

  - Debian / Ubuntu: `sudo apt install libevdev2` (runtime; enough to **build** and run)
  - Fedora: `sudo dnf install libevdev`
  - Arch: `sudo pacman -S libevdev`

  The Makefile passes `-l:libevdev.so.2` (no unversioned `libevdev.so` symlink required). Optional
  **development** packages (`libevdev-dev` / `libevdev-devel`) are only needed if you change the
  C binding or use other tooling that expects headers.

- An **MQTT broker** for local testing (e.g. Mosquitto).

## Build

From the repository root:

```bash
make            # builds ./build/hambridge
make clean      # removes ./build/
make run        # runs against ./bridge.json + ./devices.json
```

**Fedora RPM (optional)** — on a Fedora/RHEL-family host with `rpm-build`, `git`, and the same
build deps as `make`:

```bash
make fedora-rpm    # git archive + rpmbuild into build/rpmbuild/{SOURCES,SRPMS,RPMS}
make fedora-test   # builds the RPM then smoke-tests (requires, paths, hambridge --version via rpm2cpio)
```

`make clean` removes `build/` including that rpmbuild tree. Bump `RPM_VER` in the `Makefile` when
you bump `AppVersion` in `src/hambridge.lpr` and `Version` in `packaging/Redhat/hambridge.spec`.

The Makefile invokes `fpc` with `-k-L<libdir> -k-l:libevdev.so.2` when it finds that shared
library under `/usr/lib64` or `/usr/lib/x86_64-linux-gnu`. Recommended compiler flags are
documented in the plan (§5.1).

**Fully offline builds:** after a successful `make` on a networked machine, the zip under
`build/deps/fpc-mqtt-client-*.zip` matches the `FPC_MQTT_SHA256` line in the `Makefile`. You can
copy that zip into the same path on an air-gapped tree (before `make`) so `curl` is never
invoked; `sha256sum` still validates the file before unzip.

## Source layout (v0.1)

See **§5.1 Build & layout** in `Visca-MQTT-bridge-Plan.md` for the intended `src/` unit list and
responsibilities (`config.pas`, `devicesconfig.pas`, `evdevreader.pas`, `libevdev_binding.pas`,
`mainloop.pas`, `mqttpublisher.pas`, `logger.pas`, `hambridge.lpr`).

## Configuration (development copies)

Example files are committed; copy and edit for local runs:

```bash
cp bridge.json.example bridge.json
cp devices.json.example devices.json
```

- **`bridge.json`** — broker connection (host, port, auth, TLS, client ID, LWT, birth) and
  global runtime (logging). Any field can be overridden by a `BRIDGE_*` environment variable;
  see the plan §3.0.
- **`devices.json`** — buses, devices, and (for v0.1) the `evdev` block listing which input
  nodes to read. See the plan §3.1 and §3.1.2.

### Config path discovery (first hit wins)

1. `--config <path>` / `--devices <path>` command-line flag
2. `BRIDGE_CONFIG` / `BRIDGE_DEVICES` environment variable
3. `./bridge.json` / `./devices.json`
4. `/etc/hambridge/bridge.json` / `/etc/hambridge/devices.json`

`bridge.json` and `devices.json` are listed in `.gitignore` so local copies are not committed;
only the `*.example` variants are tracked.

## Run (from a dev build)

```bash
./build/hambridge --config ./bridge.json --devices ./devices.json
```

## systemd / udev (production-style)

For the expected **systemd** deployment, unprivileged user **`hambridge`**, and **udev** rules
shipped as templates, follow [packaging/README.md](packaging/README.md).

## Input device permissions

The bridge must be able to read `/dev/input/event*`. See [README.md](README.md) for interactive
use vs systemd + `packaging/udev/`.

## License

Same as the project: GPL-3.0-or-later. See [LICENSE](LICENSE).
