# HaMBridge (Hardware-MQTT Bridge)

A headless Linux daemon that bridges **hardware ↔ MQTT**.

The v0.1 binary is **`hambridge`**; systemd and packaging use the **HaMBridge** product name and
`/etc/hambridge/` for configuration.

## Summary

| Input | Output | MQTT Topic | Description |
|-------|--------|------------|-------------|
| Linux evdev | MQTT JSON | `evdev/<slug>/event` (pub)* | Publish kernel input events as JSON. From (`/dev/input/event*`) |
| Serial VISCA | MQTT JSON | `controller/<bus-slug>/event` (pub), `controller/<bus-slug>/status` (pub), `device/<slug>/telemetry` (pub), `device/<slug>/status` (pub), `device/<slug>/commandAck` (pub) | Decode controller traffic and device replies and publish JSON for subscribers. |
| MQTT JSON | VISCA over serial (RS-232 / RS-485) | `device/<slug>/<command>` (sub) (bridge subscribes to `device/#`) | Encode JSON payloads with `visca-mapping.json` and transmit on the device’s bus. |

* = Configurable

## Documentation

- **Install / deploy (preferred: distro packages)**: [INSTALL.md](INSTALL.md)
- **Configuration guide** (`bridge.json`, `devices.json`, topics): [ConfigurationGuide.md](ConfigurationGuide.md)
- **Developer / manual / interactive use**: [DEVELOPING.md](DEVELOPING.md)
- **Specification (versionless)**: [Specification.md](Specification.md)
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
