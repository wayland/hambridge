# Developing HaMBridge (Hardware-MQTT Bridge)

This document is for **building from source** and contributor-oriented setup. For what the
project does and how to run a binary you already have, see [README.md](README.md). The full
design is in [Visca-MQTT-bridge-Plan.md](Visca-MQTT-bridge-Plan.md).

The product name is **HaMBridge**; the v0.1 build target may still be named `visca-mqtt-bridge`.

## Toolchain (v0.1)

- **Linux** (v0.1 is Linux-only because of `libevdev`).
- **Free Pascal Compiler** 3.2.x or newer (`fpc`).
- **GNU Make** (`make`).
- **`libevdev` development headers** and the runtime library (link with `-levdev`):

  - Debian / Ubuntu: `sudo apt install libevdev-dev`
  - Fedora: `sudo dnf install libevdev-devel`
  - Arch: `sudo pacman -S libevdev`

- An **MQTT broker** for local testing (e.g. Mosquitto).

## Build

From the repository root:

```bash
make            # builds ./build/visca-mqtt-bridge
make clean      # removes ./build/
make run        # runs against ./bridge.json + ./devices.json
```

The Makefile invokes `fpc` with `-levdev`. Recommended compiler flags are documented in the
plan (§5.1).

## Source layout (v0.1)

See **§5.1 Build & layout** in `Visca-MQTT-bridge-Plan.md` for the intended `src/` unit list and
responsibilities (`config.pas`, `devicesconfig.pas`, `evdevreader.pas`, `libevdev_binding.pas`,
`mainloop.pas`, `mqttpublisher.pas`, `logger.pas`, `visca-mqtt-bridge.lpr`).

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
./build/visca-mqtt-bridge --config ./bridge.json --devices ./devices.json
```

## systemd / udev (production-style)

For the expected **systemd** deployment, unprivileged user **`hambridge`**, and **udev** rules
shipped as templates, follow [packaging/README.md](packaging/README.md).

## Input device permissions

The bridge must be able to read `/dev/input/event*`. See [README.md](README.md) for interactive
use vs systemd + `packaging/udev/`.

## License

Same as the project: GPL-3.0-or-later. See [LICENSE](LICENSE).
