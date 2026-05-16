# HaMBridge (Hardware-MQTT Bridge)

A headless Linux daemon that bridges **hardware ↔ MQTT** (Linux **evdev**, **VISCA** over serial or UDP,
and related controller/device traffic).

The shipped binary is **`hambridge`**; systemd and packaging use the **HaMBridge** product name and
**`/etc/hambridge/`** for machine-local state. **Target** YAML config lives under **`/etc/hambridge/config/`**
(see **[docs/user/ConfigurationGuide.md](docs/user/ConfigurationGuide.md)**).

## Summary

| Input | Output | MQTT Topic | Description |
|-------|--------|------------|-------------|
| Linux evdev | MQTT JSON | `controller/<slug>/event` (pub)* | Publish kernel input events as JSON (`/dev/input/event*`, **`endpoints`** with **`match.protocol: evdev`**) |
| VISCA (serial or UDP) | MQTT JSON | `controller/<bus-slug>/event` (pub), `controller/<bus-slug>/status` (pub), `device/<slug>/telemetry` (pub), `device/<slug>/status` (pub), `device/<slug>/commandAck` (pub) | Decode controller traffic and device replies from RS-232 / RS-485 or UDP datagrams and publish JSON for subscribers. |
| MQTT JSON | VISCA (serial RS-232 / RS-485 or UDP/IP) | `device/<slug>/<command>` (sub) (bridge subscribes to `device/#`) | Encode JSON payloads using **`device_mappings.visca`** (e.g. **`config/mappings/visca.yaml`** next to **`hambridge.yaml`**) and send on the device’s bus (**`transport: serial`** or **`transport: udp`** with per-endpoint **`udpHost`** / **`udpPort`**). |

* = Configurable

## Documentation

- **Install / deploy (preferred: distro packages)**: [docs/user/INSTALL.md](docs/user/INSTALL.md)
- **Configuration guide** (YAML layout, **`--config` / `BRIDGE_CONFIG`**, topics): [docs/user/ConfigurationGuide.md](docs/user/ConfigurationGuide.md)
- **Developer / manual / interactive use**: [docs/developers/DEVELOPING.md](docs/developers/DEVELOPING.md)
- **Specification (versionless)**: [docs/developers/Specification.md](docs/developers/Specification.md)
- **Release notes**: [CHANGELOG.md](CHANGELOG.md)
- **Roadmap (versioned)**: [ROADMAP.md](ROADMAP.md)

## What you get (MQTT surface)

- **Control**: `device/<slug>/<command>` (VISCA mapping driven)
- **Device status**: `device/<slug>/status` (last controller + last reply; optional state cache)
- **Telemetry**: `device/<slug>/telemetry` (device replies; optional structured `decode`)
- **Command acks**: `device/<slug>/commandAck` (bridge-originated command lifecycle)
- **Controller events**: `controller/<bus-slug>/event` (semantic or raw)
- **Controller bus status**: `controller/<bus-slug>/status` (last controller event + last device reply)

## License

GPL-3.0-or-later. See [LICENSE](LICENSE) for the full text.

`SPDX-License-Identifier: GPL-3.0-or-later`
