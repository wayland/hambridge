# Changelog

Notable changes to **HaMBridge** (this repository). Release history for packaging metadata remains in `packaging/debian/changelog` (Debian) and the RPM spec where required by those formats.

## [0.4.1] — 2026-05-09

### Changed

- **Bus schema enforcement** — `buses.<id>` requires `transport` + `protocol`, validates `protocol_config` (if present) is an object, and reads serial settings from `transport_configuration`.

## [0.4.0] — 2026-05-09

### Changed

- **Unified YAML configuration** — One file **`hambridge.yaml`** replaces **`bridge.json`** + **`devices.json`**. Top-level **`bridge`** holds MQTT and logging; **`device_mappings.visca`** points at the VISCA mapping file (paths relative to the main config directory). **`buses`** may use **`transport: serial`** and nested **`transport_configuration`** ( **`port`**, **`baud`**, **`rs485`**, …). **`--devices`** and **`BRIDGE_DEVICES`** are removed; pass the same path to **`--config`** / **`BRIDGE_CONFIG`** for everything.
- **Config discovery** — Matches **`docs/user/ConfigurationGuide.md`** (no implicit **`./config/`** probe): CLI, **`BRIDGE_CONFIG`**, **`.local/etc/config/hambridge.yaml`**, **`/etc/hambridge/config/`**, **`/etc/hambridge/hambridge.yaml`**.
- **VISCA mapping** — **`mappings/visca.yaml`** (and **`.yml`**) supported via in-tree minimal YAML parsing; **`.json`** mapping files still work.

## [0.3.3] — 2026-05-02

### Added

- **Device reply decode** — `device/<slug>/telemetry` and **`lastReply`** on **`device/<slug>/status`** may include a **`decode`** object (generic VISCA: **replyClass**, **socket**, **payload** / **code** as applicable) via `viscareplydecode`.
- **`controller/<bus>/status`** — JSON snapshot with **`lastController`** and **`lastDeviceReply`** (objects or `null`), published after **`controller/<bus>/event`** and after device replies on that bus.

## [0.3.2] — 2026-05-02

### Added

- **`devices.json`** — `devices[].scheduler.coalesce`: array of first path segments (`pan`, `tilt`, `zoom`, …). Before enqueueing, older **queued** commands for the same device and segment are removed (the item waiting for ACK is not dropped).
- **Redundant VISCA skip** — Per-device, per-command-path **last successful wire** cache (bridge ACK/completion and controller semantic re-encode). Matching MQTT control is answered with **`commandAck`** (`reason: redundant`, `viscaKind: skipped`) without enqueueing or sending; duplicates already queued are dropped at send time the same way.
- **`device/<slug>/status`** — Optional **`state`** object with last JSON for **`pan`**, **`tilt`**, **`zoom`**, and **preset**-family commands, updated from bridge successes and controller decodes.

## [0.3.1] — 2026-05-02

### Added

- **VISCA command lifecycle** (`commandrouter`): per-bus state machine — drain TX queue, wait for device **ACK / completion / error** (or `scheduler.ackTimeoutMs` timeout), **`commandRetryMax`** resends with **`retryBackoffMs`**. **`ackTimeoutMs`: 0** skips wait and publishes **`commandAck`** with `viscaKind` **immediate**.
- **MQTT `device/<slug>/commandAck`**: JSON with `ok`, `reason`, `attempts`, `mqttTopic`, `command`, `viscaKind`, `viscaHex`.
- **Serial** (`serialport`): software **TX queue** (up to 8 KiB), **`PumpTransmit`** for partial **`write`** / **`EAGAIN`**; **reopen** with backoff after hard read/write errors; optional **`TIOCSRS485`** from **`devices.json`** `buses.<id>.rs485`.
- **`visca-mapping.json`**: template slots as **string** (one byte) or **object** `slot` + **`width`** (1..8); MQTT / `variables` value as integer (big-endian) or JSON **array** of bytes. Controller reverse-decode updated.

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
