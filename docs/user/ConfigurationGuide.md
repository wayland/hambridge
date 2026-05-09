# HaMBridge configuration guide

HaMBridge reads a **single main file**, **`hambridge.yaml`**, plus a **VISCA mapping** YAML file whose path you set under **`device_mappings.visca`**.

In this repository, **templates** live under **`config/`** (copy **`*.example`** to **`config/hambridge.yaml`** and **`config/mappings/visca.yaml`** and edit). That layout is for convenience in a checkout only; it is **not** probed automatically (see below).

**Local development / testing:** you must pass the main file explicitly or set an environment variable, for example:

- **`./build/hambridge --config ./config/hambridge.yaml`**
- **`export BRIDGE_CONFIG="$PWD/config/hambridge.yaml"`** then run the binary (exact semantics when **`BRIDGE_CONFIG`** is set are as in the discovery list below).

The **`make run`** target in the **`Makefile`** passes **`--config ./config/hambridge.yaml`** for you after seeding from **`*.example`** if needed.

## Top-level keys in `hambridge.yaml`

- **`bridge`** — MQTT broker (**`mqtt`**: host, port, TLS, credentials, client ID, keepalive, LWT, birth) and logging (**`log`**: level, format).
- **`device_mappings`** — paths to mapping files. **`device_mappings.visca`** is a string path to the VISCA mapping YAML (recommended: **`mappings/visca.yaml`**, i.e. **`config/mappings/visca.yaml`** next to **`config/hambridge.yaml`**). Relative paths are resolved from the directory that contains **`hambridge.yaml`**.
- **`buses`** — object whose keys are **bus slugs** (used in MQTT as `controller/<bus-slug>/…`). Each bus has:
  - **`transport`**: `serial` or `udp`
  - **`transport_configuration`**: serial port / baud / parity / stop bits / optional RS‑485 settings, or UDP bind host/port, allow list, defaults for outbound control
  - **`protocol`**: e.g. `visca`
  - **`protocol_config`** (optional): extra options for that protocol; keys that do not apply may be ignored
- **`devices`** — list of cameras: **`slug`**, **`model`**, **`bus`** (must match a bus slug), **`viscaAddress`** (1–7), optional **`scheduler`** (pacing, retries, queue depth, **`coalesce`** for high-rate commands).
- **`evdev`** (optional) — **`enabled`**, **`inputs`** with **`slug`**, **`deviceNode`**, **`grabExclusive`**, **`mqttTopic`** for publishing raw input events to MQTT.

## Finding `hambridge.yaml`

The daemon picks the first file that exists, in this order:

1. Path from **`--config`**
2. Path from **`BRIDGE_CONFIG`**
3. **`.local/etc/config/hambridge.yaml`**, then **`.local/etc/config/hambridge.yml`**
4. **`/etc/hambridge/config/hambridge.yaml`**, then **`/etc/hambridge/config/hambridge.yml`**
5. **`/etc/hambridge/hambridge.yaml`**, then **`/etc/hambridge/hambridge.yml`**

## Environment overrides (`bridge` only)

Any value under **`bridge`** can be overridden: prefix **`BRIDGE_`**, uppercase, use **`_`** between nested keys (e.g. **`BRIDGE_MQTT_HOST`**, **`BRIDGE_LOG_LEVEL`**). Environment wins over the file.

## MQTT topics (overview)

### Device control

- **`device/<slug>/<command>`** — publish a **JSON** body to drive a VISCA device; **`slug`** matches **`devices[].slug`**. Command names are slash-separated (e.g. **`preset/call`**).

### Telemetry and status

- **`device/<slug>/telemetry`** — device replies (may include a structured **`decode`**).
- **`device/<slug>/status`** — snapshot (e.g. last controller / last reply, optional **`state`**).
- **`device/<slug>/commandAck`** — outcome for each command the bridge sent on behalf of MQTT.

### Controller traffic

- **`controller/<bus-slug>/event`** — decoded or raw controller-side VISCA events on that bus.
- **`controller/<bus-slug>/status`** — snapshot for that bus.

### Evdev (if configured)

- **`evdev/<slug>/event`** or the topic you set per input — each kernel input event as JSON.

## Further reading

- **Install and service layout:** [INSTALL.md](INSTALL.md) (this folder)
- **What the daemon does (topic table):** [README.md](../../README.md)
- **Building from source:** [DEVELOPING.md](../developers/DEVELOPING.md)
