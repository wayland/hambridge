# Changelog

Notable changes to **HaMBridge** (this repository). Release history for packaging metadata remains in `packaging/debian/changelog` (Debian) and the RPM spec where required by those formats.

## [0.3.0] — 2026-05-02

### Added

- Serial **RX**: non-blocking reads, VISCA frames terminated by `0xFF`.
- **Controller traffic:** reverse-map packets against `visca-mapping.json`; publish `controller/<bus>/event` (semantic or raw `event`).
- **Device replies:** classify ACK / completion / error; publish `device/<slug>/telemetry` and merge `lastController` / `lastReply` into `device/<slug>/status`.

## [0.2.1] — (mapping)

- Framed VISCA encoding in `visca-mapping.json` (`bytes` + optional `template` / `variables` + MQTT JSON for slots).

## [0.2.0] — (VISCA TX)

- MQTT `device/<slug>/<command>` → `visca-mapping.json` → serial TX; per-bus queue and inter-command spacing.

## [0.1.0] — (evdev)

- Linux **evdev** → MQTT JSON; `bridge.json` / `devices.json`; MQTT reconnect, LWT/birth.
