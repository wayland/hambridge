# HaMBridge configuration guide

HaMBridge is configured by two JSON files:

- `bridge.json`: broker connection + runtime/logging
- `devices.json`: buses, devices, VISCA mapping selection, and optional evdev inputs

Example templates are included as `bridge.json.example` and `devices.json.example`.

## Config path discovery

First match wins:

1. CLI flags: `--config <path>` / `--devices <path>`
2. Env vars: `BRIDGE_CONFIG` / `BRIDGE_DEVICES`
3. Local files: `./bridge.json` / `./devices.json`
4. System install: `/etc/hambridge/bridge.json` / `/etc/hambridge/devices.json`

## `bridge.json`

Defines MQTT connection and global runtime settings.

Key fields:

- `mqtt.host`, `mqtt.port`, `mqtt.tls`
- `mqtt.username`, `mqtt.password`
- `mqtt.clientId`, `mqtt.keepaliveSec`
- `mqtt.lwt` / `mqtt.birth` (topic, payload, retain, qos)
- `log.level` (`debug|info|warn|error`)

Most fields can be overridden via environment variables by uppercasing the JSON path and prefixing with `BRIDGE_` (e.g. `BRIDGE_MQTT_HOST`, `BRIDGE_LOG_LEVEL`).

## `devices.json`

Defines:

- `buses`: serial ports and UART settings (optionally RS-485 ioctl configuration)
- `devices`: VISCA devices attached to buses (slug, model, address, scheduler settings)
- `evdev`: optional input event publishing configuration

Scheduler-related fields (per device) control command pacing and reliability:

- `minInterCommandMs`
- `maxQueueDepth`
- `ackTimeoutMs`
- `commandRetryMax`
- `retryBackoffMs`
- `coalesce` (drop older queued commands for the same “first segment”)

## MQTT topics

### Device control

- `device/<slug>/<command>`: publish JSON to control a VISCA device

The mapping from topic/payload → VISCA bytes is defined in `visca-mapping.json` for each device model.

### Device telemetry & status

- `device/<slug>/telemetry`: device replies (plus optional structured `decode`)
- `device/<slug>/status`: snapshot with `lastController`, `lastReply`, and optional `state`
- `device/<slug>/commandAck`: result for each bridge-originated command (enqueue/send/ack/completion/timeout/retry/error)

### Controller traffic

- `controller/<bus>/event`: controller-originated commands (semantic or raw) observed on the bus
- `controller/<bus>/status`: snapshot with `lastController` and `lastDeviceReply`

## Next

For the protocol/data model details (topics, payload shapes, mapping file), see `Specification.md`.

