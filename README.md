# HaMBridge (Hardware-MQTT Bridge)

A headless Linux daemon that bridges **hardware** (Linux evdev input today; VISCA/serial in
later releases) **to MQTT**. Architecture and phased behaviour are in
[Visca-MQTT-bridge-Plan.md](Visca-MQTT-bridge-Plan.md); **release notes** in [CHANGELOG.md](CHANGELOG.md)
and **upcoming work** in [ROADMAP.md](ROADMAP.md).

The v0.1 binary is **`hambridge`**; systemd and packaging use the **HaMBridge** product name and
`/etc/hambridge/` for configuration.

To **build from source**, see [DEVELOPING.md](DEVELOPING.md). The first `make` run downloads a
pinned [fpc-mqtt-client](https://github.com/prof7bit/fpc-mqtt-client) release (needs `curl`,
`unzip`, and network access). Packaging helpers (systemd, udev, sysusers) live under
[packaging/](packaging/).

## Roadmap (summary)

- **v0.1** — evdev → MQTT: configured `/dev/input/event*` via `libevdev`, JSON to MQTT.
- **v0.2** — MQTT → VISCA: `device/<slug>/<command>`, serial TX, `visca-mapping.json`.
- **v0.2.1** — Framed mapping + MQTT JSON template slots.
- **v0.3** — VISCA → MQTT: serial RX, `controller/<bus>/event`, device telemetry/status.

Later **v0.3.1**–**v0.3.3** items are listed in [ROADMAP.md](ROADMAP.md).

## Requirements (runtime)

- **Linux** (v0.1 targets the Linux input subsystem).
- An **MQTT broker** reachable from the host (e.g. Mosquitto).
- The **`libevdev` runtime library** on the system (e.g. `libevdev2` on Debian/Ubuntu) if you
  run a binary that links it dynamically.
- **Read access** to the `/dev/input/event*` nodes you configure.

## Deployment with systemd (recommended)

HaMBridge is intended to run as a **systemd service** under an unprivileged **`hambridge`**
user, with **narrow udev rules** so only the intended input devices are group-accessible to that
user (not the whole `input` group for every keyboard on the machine).

1. Install the unit and account snippets from [packaging/](packaging/) — see
   [packaging/README.md](packaging/README.md) for the full ordered checklist (sysusers, tmpfiles,
   udev, configs, `systemctl enable --now hambridge`).
2. Copy `bridge.json.example` and `devices.json.example` to `/etc/hambridge/bridge.json` and
   `/etc/hambridge/devices.json` and edit them.
3. Edit **`/etc/udev/rules.d/70-hambridge-input.rules`** (start from
   [packaging/udev/70-hambridge-input.rules](packaging/udev/70-hambridge-input.rules)) so the
   `GROUP="hambridge"` match applies only to your hardware (`lsusb`, `udevadm info`, etc.).

The bridge discovers configs from the current directory, `/etc/hambridge/`, or paths you pass
on the command line; see the plan §3.0 for the full discovery order.

## Manual / interactive use

If you run the binary as your own user (not via systemd), you still need access to the event
nodes. Options:

- Add your user to the **`input`** group (broad — readable access to many input devices):

  ```bash
  sudo usermod -aG input "$USER"
  # log out and back in for the new group to take effect
  ```

- Or use the same **udev** approach as production: a rule scoped to your device, with
  `GROUP=` set to a group your user belongs to.

## Configure and run (quick test)

See [DEVELOPING.md](DEVELOPING.md) for build steps and environment overrides. After building:

```bash
./build/hambridge --config ./bridge.json --devices ./devices.json
```

Each kernel event is published as JSON to `evdev/<slug>/event` (or the configured topic) at
QoS 0, no retain. Subscribers (e.g. Node-RED) translate events into VISCA-side actions until
v0.2 lands.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE) for the full text.

`SPDX-License-Identifier: GPL-3.0-or-later`
