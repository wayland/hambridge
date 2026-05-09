# 📡 MQTT ↔ VISCA Bridge (Object Pascal / Free Pascal)

**Product name:** **HaMBridge** (Hardware-MQTT Bridge) — a headless Linux daemon; this repository
and specification focus on MQTT, Linux input (evdev), and VISCA/serial.

## 1. Purpose

This project implements a **bidirectional bridge between MQTT and Sony VISCA camera control protocol** over serial (RS-232 / RS-485).

### Core function:

* MQTT messages → VISCA commands
* (Optional) VISCA responses → MQTT telemetry/status updates

### Target use cases:

* PTZ camera control systems
* AV automation workflows
* Control rooms (Node-RED / dashboards / custom UIs)
* Embedded or industrial control systems

---

## Terminology

* **device**: any end device, such as a camera
* **controller**: any device that sends controls, such as a VISCA controller

---

## Implementation status (high level)

This specification is **versionless**. Versioned planning and release tracking live in:

- `ROADMAP.md` (planned / deferred work)
- `CHANGELOG.md` (shipped changes)

At a high level, HaMBridge supports:

- **evdev → MQTT**: publish kernel input events as JSON
- **MQTT → VISCA**: subscribe to `device/<slug>/<command>` and send VISCA over serial
- **VISCA → MQTT**: decode controller traffic (`controller/<bus-slug>/...`) and device replies (`device/<slug>/...`)

---

# 2. System Architecture

```
MQTT Broker
     ↕
MQTT Client (Object Pascal)
     ↕
Command Router / State Manager
     ↕
VISCA Protocol Encoder/Decoder
     ↕
Serial Port Layer (RS-485 / RS-232)
     ↕
Device Hardware
```

---

# 3. Components

## 3.0 Configuration (`hambridge.yaml`)

Normative configuration is a **single UTF-8 YAML document**. Top-level keys include:

* **`bridge`** — MQTT broker connection and global runtime (logging, TLS material paths, …).
* **`device_mappings`** — paths to protocol mapping documents. **`device_mappings.visca`** is the
  string path to the VISCA topic→bytes file (YAML; see §3.3). Other keys may be reserved later;
  unknown keys under **`device_mappings`** are ignored (§3.0.3).
* **`buses`** — object keyed by **bus-slug**; each value is a bus entry (§3.1).
* **`devices`** — sequence (array) of VISCA device records (**`slug`**, **`model`**, **`bus`**, …).
* **`evdev`** — optional block for Linux input → MQTT (§3.1.2).

On disk, configuration is **YAML** only: **`hambridge.yaml`** plus the VISCA mapping file named by
**`device_mappings.visca`**.

In this repository, **committed templates** live under **`config/`** (e.g. **`config/hambridge.yaml.example`**,
**`config/mappings/visca.yaml.example`**). A checkout may keep working copies beside them
(**`config/hambridge.yaml`**, **`config/mappings/visca.yaml`**), but those paths are **not** part of
default discovery: developers pass **`--config`** or **`BRIDGE_CONFIG`**. On a host, packaged installs
use **`/etc/hambridge/config/hambridge.yaml`** next to **`/etc/hambridge/config/mappings/`** (or paths
given in **`device_mappings.visca`**).

### 3.0.1 File naming

* **Process config:** **`hambridge.yaml`** (preferred) or **`hambridge.yml`** (accepted). When
  probing default paths, implementations **should** try **`hambridge.yaml`** before **`hambridge.yml`**.
* **VISCA mapping file:** path is **`device_mappings.visca`** (string). **`mappings/visca.yaml`**
  (or **`.yml`**) is the **recommended** relative path; relative paths resolve against the directory
  containing **`hambridge.yaml`** unless absolute.

### 3.0.2 YAML parsing

Configuration **must** be parsed with a **third-party YAML library** (no custom YAML grammar or
hand-rolled scanner). For Free Pascal, [**otYaml**](https://github.com/openTemplot/otYaml) is a
reasonable choice; which library ships in a given build **must** be documented in release notes.

### 3.0.3 Unknown keys and `protocol_config`

Throughout the YAML document (root, **`bridge`**, **`device_mappings`**, **`buses`**, device rows,
**`evdev`**, bus entries, and other objects defined in this spec): **unknown keys are ignored** (no
parse failure) so forward-compatible files load on older daemons.

For **`protocol_config`** (optional, per bus): keys that are **irrelevant** to the selected
**`protocol`** / **`transport`** are **ignored**; the spec does **not** require omitting unused
keys.

### 3.0.4 Recommended packaging paths

* **`/etc/hambridge/config/hambridge.yaml`** — main configuration (config tree under **`config/`**)
* **`/etc/hambridge/config/mappings/visca.yaml`** — typical VISCA mapping path when
  **`device_mappings.visca`** is **`mappings/visca.yaml`** (relative to that **`hambridge.yaml`**)
* **`/etc/hambridge/tls/`** — PEM trust and client auth material referenced from
  `bridge.mqtt.tls.*` (restrictive modes; readable only by the service user)

Example templates **`config/hambridge.yaml.example`** and **`config/mappings/visca.yaml.example`**
should ship as package documentation (e.g. RPM **`%doc`**, or **`/usr/share/doc/hambridge/examples/`**
on Debian).

### Fields under `bridge`

Illustrative YAML (TLS shown in object form; see MQTT TLS notes below):

```yaml
bridge:
  mqtt:
    host: localhost
    port: 1883
    tls:
      enabled: false
      caFile: null
      caPath: null
      clientCertFile: null
      clientKeyFile: null
      verifyPeer: true
      serverName: null
      minVersion: null
      maxVersion: null
      ciphers: null
    username: null
    password: null
    clientId: hambridge
    keepaliveSec: 30
    lwt:
      topic: bridge/hambridge/status
      payload: offline
      retain: true
      qos: 1
    birth:
      topic: bridge/hambridge/status
      payload: online
      retain: true
      qos: 1
  log:
    level: info
    format: text
```

Notes:

* `clientId`: must be unique per broker; recommend suffixing with hostname or a random tail when
  running multiple bridges against one broker.
* `lwt` / `birth`: emit on connect/disconnect so subscribers can detect bridge availability.
* `log.level`: one of `debug` / `info` / `warn` / `error`.
* `log.format`: `text` for now; `json` reserved for later.

### MQTT TLS Notes

* **`mqtt.tls` shape:** Either a **boolean** shorthand (`false` = TLS off; `true` = TLS on with OS
  default trust only, peer verification per implementation default) **or** a **mapping** as in the
  example. When the mapping is used, **`enabled`** gates TLS; other keys apply only when
  `enabled` is true.
* **`mqtt.tls.caFile`**: path to a PEM file containing one or more CA certificates (trust anchor for
  verifying the broker). Mutually exclusive with using only `caPath` for a directory, unless the
  implementation merges both; if both are set, behaviour must be defined (recommended: prefer
  `caFile` when non-empty, else `caPath`).
* **`mqtt.tls.caPath`**: path to a directory of hashed CA certs (OpenSSL-style `c_rehash` layout),
  when used instead of or in addition to `caFile` (see implementation note above).
* **`mqtt.tls.clientCertFile`** / **`mqtt.tls.clientKeyFile`**: optional client certificate and private
  key (PEM) for mutual TLS.
* **`mqtt.tls.verifyPeer`**: only meaningful when TLS is **enabled** (`mqtt.tls.enabled` true, or
  legacy `mqtt.tls: true`). When TLS is **off**, **`verifyPeer` is ignored** (no peer to verify).
  When TLS is on and **`verifyPeer`** is true, the broker certificate must validate against trust
  anchors (custom CA / `caFile` / `caPath` and/or OS store per implementation). When TLS is on and
  **`verifyPeer`** is false, insecure verification is allowed (discouraged in production; must be
  obvious in logs at connect).
* **`mqtt.tls.serverName`**: optional TLS Server Name Indication (SNI) / hostname used for
  certificate verification when it differs from `mqtt.host` (e.g. IP in `host`, name in
  `serverName`).
* **`mqtt.tls.minVersion`** / **`mqtt.tls.maxVersion`**: optional TLS protocol bounds (string names
  such as `TLSv1.2` / `TLSv1.3` — exact accepted tokens are implementation-defined but must be
  documented in release notes).
* **`mqtt.tls.ciphers`**: optional OpenSSL cipher list string; omit for implementation default.

### MQTT TLS behavioural rules

* **Startup / config:** Malformed YAML, unreadable `caFile` / `clientCertFile` / `clientKeyFile`, or
  invalid combinations (e.g. client cert without key) should fail **at startup** with a clear
  error and non-zero exit (fail closed).
* **Runtime / broker:** TLS handshake or broker auth failures should be treated like other broker
  errors: **log**, **disconnect**, **reconnect with backoff** (same class as TCP connect failure),
  without dumping private key material or passwords into logs.
* **Secrets:** Never log `mqtt.password`, private key contents, or client certificate PEM bodies.
  Logging may include **paths** to cert files and **boolean** flags (e.g. `verifyPeer`).
* **Trust:** When TLS **`enabled`** is true and **`verifyPeer`** is true with **no** `caFile`/`caPath`,
  implementations use **OS default trust stores** only. When `caFile` or `caPath` is set, broker
  verification must include those anchors (exact merge order is implementation-defined but must be
  documented). When TLS **`enabled`** is false, **`verifyPeer` must not** be treated as a required
  field (it does not apply).
* **Certificate expiry:** implementations **may** warn at connect when the broker or client
  certificate is within a configurable horizon of expiry (optional; document if supported).
* **Insecure verification:** when TLS is enabled and **`verifyPeer`** is false, implementations
  **should** emit a **high-visibility log** at connect (e.g. `warn` with a fixed message id), and
  **may** require an additional explicit config flag to allow it in production builds (policy choice;
  document which applies).
* **Key file permissions:** if **`clientKeyFile`** is world-readable or group-readable beyond the
  service user, implementations **should** log a **warning** or refuse startup (document which).
* **Deployment:** Recommended layout for packaged installs is PEM files under
  `/etc/hambridge/tls/` (or similar), readable only by the service user; `hambridge.yaml` holds paths,
  not inline secrets.

### Environment-variable overrides

Any field under **`bridge`** in the YAML document can be overridden by an environment variable. The mapping is mechanical:

* Prefix `BRIDGE_`, then uppercase the path under `bridge`, joining levels with `_`.
* Examples:
  * `BRIDGE_MQTT_HOST` → `mqtt.host`
  * `BRIDGE_MQTT_PORT` → `mqtt.port`
  * `BRIDGE_MQTT_USERNAME` → `mqtt.username`
  * `BRIDGE_MQTT_PASSWORD` → `mqtt.password`
  * `BRIDGE_MQTT_CLIENTID` → `mqtt.clientId`
  * `BRIDGE_MQTT_LWT_TOPIC` → `mqtt.lwt.topic`
  * `BRIDGE_LOG_LEVEL` → `log.level`
  * `BRIDGE_MQTT_TLS_ENABLED` → `mqtt.tls.enabled` (when `mqtt.tls` is an object)
  * `BRIDGE_MQTT_TLS_CAFILE` → `mqtt.tls.caFile`
  * `BRIDGE_MQTT_TLS_CAPATH` → `mqtt.tls.caPath`
  * `BRIDGE_MQTT_TLS_CLIENTCERTFILE` → `mqtt.tls.clientCertFile`
  * `BRIDGE_MQTT_TLS_CLIENTKEYFILE` → `mqtt.tls.clientKeyFile`
  * `BRIDGE_MQTT_TLS_VERIFYPEER` → `mqtt.tls.verifyPeer`
  * `BRIDGE_MQTT_TLS_SERVERNAME` → `mqtt.tls.serverName`
  * `BRIDGE_MQTT_TLS_MINVERSION` → `mqtt.tls.minVersion`
  * `BRIDGE_MQTT_TLS_MAXVERSION` → `mqtt.tls.maxVersion`
  * `BRIDGE_MQTT_TLS_CIPHERS` → `mqtt.tls.ciphers`

Env vars **win** over the file. Booleans accept `true`/`false`/`1`/`0`; integers must parse as
base-10. Empty string clears the field (treated as unset).

### Config-path discovery order

The bridge resolves **`hambridge.yaml`** / **`hambridge.yml`** in this order; the first **existing**
file wins:

1. **`--config <path>`** command-line flag (path may be `.yaml` or `.yml` or any filename; may be relative to the process working directory)
2. **`BRIDGE_CONFIG`** environment variable (non-empty path to the main file)
3. **`.local/etc/config/hambridge.yaml`**, then **`.local/etc/config/hambridge.yml`** (relative to the process working directory)
4. **`/etc/hambridge/config/hambridge.yaml`**, then **`/etc/hambridge/config/hambridge.yml`**
   (recommended for **HaMBridge** systemd packages; see `packaging/systemd/`)
5. **`/etc/hambridge/hambridge.yaml`**, then **`/etc/hambridge/hambridge.yml`** (legacy single-file layout)

There is **no** fallback that searches **`./config/`** or the current directory by name: a checkout or
any non-standard layout **must** use step **1** or **2**. **`docs/user/ConfigurationGuide.md`** describes this for operators.

**`bridge`**, **`device_mappings`**, **`buses`**, **`devices`**, and **`evdev`** are **siblings**
at the document root (same file as **`hambridge.yaml`**). A second on-disk file is required only for
the VISCA mapping document referenced by **`device_mappings.visca`**.

If no configuration file is found, the bridge logs a clear error and exits non-zero.

---

## 3.1 MQTT Client Module

### Responsibilities

* Connect to MQTT broker (TCP/IP)
* Subscribe to control topics
* Publish status, acknowledgements, controller-originated events, and (optional) **raw evdev** event
  streams (§3.1.2)
* Handle reconnection automatically

### Requirements

* QoS 0 and QoS 1 support
* Topic filtering
* JSON payload parsing
* Non-blocking message handling

### Configuration (roots beside `bridge` in `hambridge.yaml`)

Alongside **`bridge`**, the process config file defines:

* **`device_mappings.visca`**: path to the VISCA topic mapping YAML (see §3.3)
* **`buses`**: which buses exist (transport, wire-level settings, protocol)
* **`devices`**: sequence of VISCA devices (**`slug`** for `device/<slug>/...`, **`viscaAddress`**
  1..7 on the VISCA bus, **`model`**, **`bus`**, optional **`scheduler`**)
* optional per-device scheduler overrides (timing, queue bounds, coalescing rules)
* **`evdev`**: optional Linux inputs—kernel nodes to open and MQTT topic per stream (§3.1.2); the
  bridge emits **raw evdev-style events** only—no translation to VISCA or `device/<slug>/...`
  commands in-process

#### Normative bus entry schema (v0.4.1+)

Each value under **`buses.<bus-slug>`** is a mapping with:

* **`transport`** (required): wire transport identifier, e.g. **`serial`** or **`udp`**.
* **`transport_configuration`** (required): mapping whose **keys depend on `transport`** (serial
  vs UDP field sets are defined in §3.4). All port/baud/RS-485 and UDP bind/ACL/default-remote
  fields live **here**, not alongside `transport` at the top level of the bus object.
* **`protocol`** (required): logical protocol on that wire, e.g. **`visca`**.
* **`protocol_config`** (optional): mapping for protocol-specific options. Keys that do not apply
  to the selected **`protocol`** / **`transport`** are **ignored** (see §3.0.3).

**`buses` object keys** are **bus-slugs** (MQTT segments such as `controller/<bus-slug>/event`).

Example shape (illustrative; **`serial` + `visca`** and **`udp` + `visca`** buses; aligns with
**`config/hambridge.yaml.example`**):

```yaml
device_mappings:
  visca: mappings/visca.yaml

buses:
  rs485-1:
    transport: serial
    protocol: visca
    protocol_config: {}
    transport_configuration:
      port: /dev/ttyUSB0
      baud: 9600
      dataBits: 8
      parity: "N"
      stopBits: 1
  visca-udp-1:
    transport: udp
    protocol: visca
    protocol_config: {}
    transport_configuration:
      bindHost: "0.0.0.0"
      bindPort: 52381
      allowFrom: ["192.0.2.0/24"]
      defaultUdpHost: null
      defaultUdpPort: null

devices:
  - slug: camera_stage
    model: marshall-cv344
    bus: rs485-1
    viscaAddress: 1
    scheduler:
      minInterCommandMs: 50
      ackTimeoutMs: 500
      commandRetryMax: 2
      retryBackoffMs: 50
      maxQueueDepth: 50
      coalesce: [pan, tilt, zoom]

evdev:
  enabled: false
  inputs:
    - slug: usb-keypad-ptz
      deviceNode: /dev/input/event2
      grabExclusive: false
      mqttTopic: evdev/usb-keypad-ptz/event
```

Per-device **`scheduler`** (VISCA): **`minInterCommandMs`**,
**`maxQueueDepth`**, **`ackTimeoutMs`**, **`commandRetryMax`**,
**`retryBackoffMs`**. **`coalesce`** is a sequence of
**first path segments** (e.g. `pan` matches `pan` and `pan/…` topics): before
enqueueing a new command, the bridge drops older **queued** commands for the
same device and segment (the command currently waiting for ACK is never removed
this way).

Wire-specific serial and UDP fields are specified under **`transport_configuration`** in §3.4.

**VISCA logical bus vs wire addressing:** The Sony VISCA framing you use on a link does **not**
define a separate global “bus ID” byte distinct from **device/peripheral address** (typically
**1–7**, configured as **`viscaAddress`** per device). One physical medium — one serial port (**one
`bus-slug`**) or one UDP bind (**one `bus-slug`**) — carries traffic for **multiple** devices that
differ by **`viscaAddress`** only. So the mapping is:
**`bus-slug` → one transport endpoint (TTY or UDP listener) → one shared VISCA medium**;
**`viscaAddress` → which device on that medium**. (Some ecosystems use the words “bus” loosely; on
the wire here, **per-medium** identity is the bridge **`bus-slug`**, and **per-device** identity on
that medium is **`viscaAddress`**.)

`evdev` block (when `enabled` is true):

* **`inputs`**: list of sources. Each entry names **which kernel input node** to open and **where**
  to publish JSON events (see §3.1.2).
* **`deviceNode`**: path under `/dev/input/` (e.g. `/dev/input/event2`). The implementation may
  optionally support discovery by name or sysfs attributes later; the config must at minimum
  allow explicit node paths for deterministic deployments.
* **`grabExclusive`**: whether to `EVIOCGRAB` the device so only this process receives events
  (use with care if the same keyboard is shared with the console).
* **`slug`**: stable MQTT segment for this input (letters, digits, `_`, `-`); used in default topics and emitted as **`inputSlug`** in JSON (§3.1.2).
* **`mqttTopic`**: topic for that input's event stream. If omitted, the default is
  `evdev/<slug>/event`.
* **Implementation**: HaMBridge uses the **`libevdev`** C library (linked as `-l:libevdev.so.2`) via a small
  Pascal binding unit. Raw `ioctl`/`read` is reserved for a possible later alternative; either
  way the MQTT contract above does not change.


## 3.1.1 VISCA Commands in MQTT

Define a canonical set of **VISCA commands** for the MQTT representation. These commands appear
in two places:

1. **Device control topics**: `device/<slug>/<command>`
2. **Controller-originated event JSON**: `{"command": "<command>", "payload": {...}}`

The goal is that intermediaries (Node-RED, rules engines, etc.) can transform/reroute JSON and
either:

* publish directly to `device/<slug>/<command>`, or
* forward the event form by mapping `command` into a topic path.

### Canonical command names (topic-path compatible)

Commands should be slash-separated and safe to embed in MQTT topics. Examples:

* `pan`
* `tilt`
* `zoom`
* `preset/set`
* `preset/call`
* `power`
* `osd/menu`
* `osd/up`
* `osd/down`
* `osd/left`
* `osd/right`
* `osd/enter`
* `osd/back`
* `event` -- Could be any kind of command; the command is defined in the `command` field of the JSON, instead of in the topic

### Examples

* Device command topic:
  * Topic: `device/camera_stage/preset/set`
  * Payload: `{ "value": 3 }`

* Controller event JSON (to `controller/rs485-1/event`):
  * ```
  	{
  		"command": "preset/set",
  		"deviceSlug": "camera_stage",
  		"payload": { "value": 3 } 
  	}
  	 ```

### Suggested MQTT Topics

#### Control topics

```
device/<slug>/<command>
```

#### Status topics

```
device/<slug>/status
device/<slug>/telemetry
device/<slug>/commandAck
```

`device/<slug>/telemetry`: may include a **`decode`** object for device replies (generic VISCA: **replyClass**, **socket**, **payload** bytes, **code** for errors).

`device/<slug>/status`: JSON includes **`lastController`**, **`lastReply`**, and optional **`state`** (`pan`, `tilt`, `zoom`, `preset` keys with last-known MQTT JSON payloads from the bridge or from decoded controller traffic). **`lastReply`** may include the same **`decode`** field as telemetry when available.

`device/<slug>/commandAck`: JSON result for each **bridge-originated** VISCA command (success after ACK/completion, failure on timeout / serial I/O / encode / VISCA error). Set `scheduler.ackTimeoutMs` to **0** to skip waiting for a VISCA reply (fire-and-forget; payload still reports `viscaKind` **immediate**). When the encoded packet matches the last successful wire for that command path, the bridge may skip TX and publish `viscaKind: skipped` with `reason: redundant`.

#### VISCA-controller → MQTT (semantic JSON events)

To support RS-485 controllers (hardware control panels) and remote replay/transforms through
JSON tooling (e.g. Node-RED), the bridge should be able to **listen to VISCA traffic** and publish
**decoded semantic events** to MQTT.

This is intentionally *not* a raw-bytes tunnel as the primary interface; the goal is MQTT-friendly
JSON that intermediaries can inspect/transform/reroute.

Suggested topics:

```
controller/<bus-slug>/event
controller/<bus-slug>/status
```

The bridge publishes **`controller/<bus-slug>/status`** after each **`controller/<bus-slug>/event`** and after device-side replies on that bus, with **`lastController`** and **`lastDeviceReply`** snapshots (JSON objects or `null`).

Suggested payload for `controller/<bus-slug>/event` (JSON):

```json
{
  "ts": 1713720000,
  "bus": "rs485-1",
  "source": "controller",
  "command": "power/set",
  "payload": { "state": "on" },
  "trace": { "viscaHex": "81 01 04 00 02 FF" }
}
```

Notes:

* `command` should be stable and MQTT/Node-RED friendly and **topic-path compatible**.
  Prefer slash-separated command paths (e.g. `zoom/drive`, `preset/call`, `osd/menu`, `osd/nav`)
  so they can be embedded in MQTT topics without translation.
* `payload` is command-specific and is what intermediaries should transform.
* `trace.viscaHex` is for debugging.  

Forwarding rule (controller event → device control topic):

* If an intermediary knows the destination device **slug**, it can forward a controller event to:

  * **Canonical path form**: `device/<slug>/<command>`
    - Example: controller event `{ "command": "osd/menu", ... }` → publish to `device/camera_stage/osd/menu`

  * **Alias-to-existing-control-topics form**: map event `command` to the bridge's control topics
    (recommended where topics already exist, e.g. `device/<slug>/pan`, `device/<slug>/tilt`,
    `device/<slug>/zoom`), and forward using those topic names.

For example, a controller-derived "pan left" event could be represented as:

* Topic: `device/camera_stage/pan`
* Payload: `{ "dir": "left", "speed": 10 }`

## 3.1.2 Evdev Events in MQTT

**Linux-only** capability: open configured **`/dev/input/event*`** nodes via **`libevdev`**
(linked as `-levdev`, see §6), read kernel **input events** (`struct input_event`: `type`,
`code`, `value`, time), and **publish each event as JSON to MQTT**.

Raw `read()`/`ioctl()` on the character device is a possible future alternative implementation
but is not currently implemented.

The bridge performs **no** translation from evdev into VISCA packets or into the canonical
`device/<slug>/<command>` control model (§3.1.1). **Node-RED**, rules engines, or other subscribers
subscribe to the evdev topics, interpret `type` / `code` / `value`, and publish to
`device/<slug>/...` or elsewhere as needed.

### Suggested MQTT topics

Per-input topic (recommended), configured explicitly or defaulted:

```
evdev/<slug>/event
```

### Payload shape

Stable, easy-to-parse JSON mirroring the evdev data. Numeric `typeNum` and `codeNum` are
**always** present so subscribers do not depend on a symbol table. Symbolic `type` and `code`
strings are populated by `libevdev_event_type_get_name` and `libevdev_event_code_get_name`; if
libevdev cannot resolve them (rare), those fields are emitted as `null`. Example:

```json
{
  "ts": 1713720000123,
  "inputSlug": "usb-keypad-ptz",
  "deviceNode": "/dev/input/event2",
  "source": "evdev",
  "type": "EV_KEY",
  "typeNum": 1,
  "code": "KEY_KP1",
  "codeNum": 79,
  "value": 1
}
```

* `ts` is milliseconds since Unix epoch from the bridge clock; the kernel `input_event.time` is
  not surfaced separately (can be added later).
* `value` follows kernel convention: for `EV_KEY` it is `0` release, `1` press, `2` repeat;
  for `EV_REL` / `EV_ABS` it is the axis value; for `EV_SYN` it is the sync subtype.

### Filtering policy

The bridge publishes **every event the kernel delivers**, including:

* `EV_SYN` markers (so subscribers can detect input frames if they care)
* Auto-repeat key events (`value == 2`)
* All axis updates from `EV_REL` / `EV_ABS`

Subscribers are responsible for any filtering. Future versions may grow optional per-input filter
rules; for now the wire format stays faithful to the kernel.

### MQTT QoS and retain

Evdev publishes use **QoS 0** by default and **`retain = false`** (events are point-in-time;
retaining them would mislead late subscribers). These defaults are not configurable for now.

### Relationship to §3.1.1

Evdev streams are **separate** from **VISCA-controller semantic events** on
`controller/<bus-slug>/event`. The latter remain decoded VISCA → JSON; evdev topics carry **raw input
events** only.

### Implementation notes

* Integrate with the process **main poll loop**: a single thread does `poll()` over each input
  fd plus a periodic MQTT client tick. No per-input thread.
* **Hotplug** policy:
  * If `deviceNode` is missing or temporarily unavailable at startup or after disconnect, the
    bridge logs a warning and **retries with exponential backoff** (e.g. 1 s → 2 s → 4 s,
    capped at ~30 s).
  * Read errors that look like a disconnected device (e.g. `ENODEV`) close the fd and re-enter
    the retry loop.
  * The bridge **only exits non-zero** on clearly fatal misconfiguration (e.g. malformed
    `hambridge.yaml`), not on an absent input node.
* When an input is grabbed (`grabExclusive = true`), failure to acquire the grab is logged and
  the bridge falls back to non-exclusive reading rather than aborting.

---

## 3.2 Command Router

### Responsibilities

* Parse MQTT payloads (JSON)
* Convert into internal command objects
* Dispatch to VISCA encoder
* Convert decoded VISCA responses/events into internal state updates and MQTT-friendly JSON
* Publish telemetry/status/events back to MQTT (device state, ACK/error, controller-derived events)

### VISCA command scheduling (queue/coalescing)

VISCA devices commonly behave like single-threaded state machines: sending commands too quickly
or concurrently can lead to ignored commands, "busy" responses, or loss of synchronization.

To make MQTT (bursty/asynchronous) safe for VISCA (sequential/stateful), the bridge should act as
a deterministic scheduler:

* **Per-device serialization**: at most one in-flight VISCA transaction per device (conservative,
  reliable default).
* **Command queue for discrete actions**: enqueue commands such as `power`, `preset/set`,
  `preset/call`, and OSD navigation (`osd/*`) and execute them sequentially.
* **Coalescing for continuous controls**: for high-rate controls (pan/tilt/zoom drive), keep only
  the latest desired intent (drop older superseded commands) to avoid "backlog motion."
* **Inter-command spacing**: enforce a small delay (e.g. 20–100 ms, device-dependent) between
  transactions to accommodate device processing time and RS-485 bus load.
* **ACK/timeout discipline**: after sending a command, wait for VISCA ACK (and optionally
  completion, depending on command type) or a timeout before issuing the next command for that
  device.
* **Rate limiting / backpressure**: protect the RS-485 bus from saturation; if MQTT input exceeds
  execution capacity, coalesce continuous commands and bound queue growth for discrete commands.

### Internal data model

```pascal
type
  TCameraCommandType = (
    cmdPan,
    cmdTilt,
    cmdZoom,
    cmdPresetSet,
    cmdPresetCall,
    cmdPower
  );

  TCameraCommand = record
    CameraId: Integer;
    CommandType: TCameraCommandType;
    Value: Integer; // speed, preset index, etc.
  end;
```

---

## 3.3 VISCA Protocol Layer

### Responsibilities

* Encode commands into VISCA packets
* Decode responses (optional)
* Handle device addressing
* Retry failed commands if needed
* Support device-specific VISCA command sets (model quirks/extensions)
* Expose decoded responses/events in a neutral form (usable for MQTT publishing and state updates)

### Key features

* Packet framing (VISCA standard format)
* Start byte: `0x81`
* End byte: `0xFF`
* Device ID addressing
* Command construction and validation

### Device-specific command support

Not all cameras implement the same VISCA feature set. Some devices support additional commands
(or require different encodings) for functions like on-screen display (OSD) menu control, image
settings, or extended presets.

**Normative path:** MQTT → VISCA encoding is **only** through the YAML file named by
**`device_mappings.visca`** (and the same logical schema whether the file is merged at load time—an
implementation detail). The bridge selects the mapping **`model`** string from each object in the
top-level **`devices`** sequence in **`hambridge.yaml`**. There is **no** specified or required parallel layer of per-model Pascal “encoder
profile” classes; model quirks and extensions are expressed by **adding or overriding topics and
frames under that model** in the mapping document.

Conceptually, the file holds **per-model** tables:

* A **base** model (e.g. shared `generic` / common topics): power, zoom, preset recall/set, etc.
* **Derived** models (e.g. `marshall-cv344`): extra topics or different byte templates for OSD,
  image settings, extended presets, and so on.

#### VISCA mapping document (`device_mappings.visca`)

The mapping file is loaded at startup so commands can be added or adjusted **without recompiling**
the bridge. Its path is **`device_mappings.visca`** in **`hambridge.yaml`**. The on-disk format is
**YAML** with **`models`**, **`topics`**, **`inherits`**, and related keys as defined in this section.

The mapping file must support:

* **Per-model selection**: e.g. `"model": "marshall-cv344"` assigned per `device/<slug>`
* **Topic → VISCA frame(s)**: static byte sequences (hex) and/or **framed** rules (fixed middle + template slots)
* **Optional parameters**: MQTT JSON and `variables` defaults supply values per template slot. A slot is **one wire byte** when the template entry is a **string** name, or **1..8 bytes** when the entry is an object with **`slot`** and **`width`**; values are a big-endian integer or a JSON **array** of byte-sized numbers. **Nibble** and other exotic encodings remain a later extension.

#### Wire assembly

For topics that define a **non-empty `template`** array:

1. **`[device]`** — single byte **`0x80 + viscaAddress`** (from the device row in **`hambridge.yaml`**, clamped to 1..7). Not stored in `bytes`.
2. **`bytes`** — space-separated hex for the **fixed middle** (normally includes **`01`** controller + category/command bytes).
3. **Template slots** — each name in `template` appends **one byte**: look up the key in the MQTT payload object, then in **`variables`**, case-insensitive keys. Values may be JSON numbers **0–255** or strings (`"02"`, `"$02"`).
4. **`FF`** — terminator appended by the bridge.

If **`template`** is absent or empty, **`bytes`** must contain the **full middle** of the command (everything after **`[device]`** and before **`FF`**), as space-separated hex.

Example (framed + inherited model override; illustrative YAML):

```yaml
models:
  base-visca:
    topics:
      power/on:
        bytes: "01 04 00"
        template: [powerArgument]
        variables: { powerArgument: "02" }
      power/off:
        bytes: "01 04 00 03"
  marshall-cv344:
    inherits: base-visca
    topics:
      preset/call:
        bytes: "01 04 3F 02"
        template: [presetIndex]
        variables: { presetIndex: "01" }
```

Publishing MQTT to **`device/camera_stage/preset/call`** with payload **`{"presetIndex": 2}`** overrides the default **`presetIndex`** byte for that command.

---

## 3.4 Serial Communication Layer (RS-485)

### Responsibilities

* Open serial port device
* Configure baud rate (typically 9600 / 38400)
* Send and receive raw VISCA packets
* Handle RS-485 direction control if required
* (Optional) Listen/sniff traffic from an RS-485 VISCA controller for VISCA-over-MQTT tunneling

### VISCA over IP (UDP)

In addition to serial buses, HaMBridge can support VISCA transported over IP using **UDP**
(“VISCA over IP”). This transport supports:

1. **Controller ingest / protocol translation (primary):** receive VISCA frames from one or more
   network controllers on the **same logical bus** and publish MQTT-friendly JSON on
   `controller/<bus-slug>/event` (and snapshots on `controller/<bus-slug>/status`), so downstream
   tooling can transform/reroute to `device/<slug>/...`.
2. **Device control:** send VISCA commands to devices that accept VISCA/UDP, with MQTT
   **`device/<slug>/commandAck`**, **`device/<slug>/telemetry`**, and **`device/<slug>/status`**
   semantics aligned with serial where practical.

#### Configuration (`transport_configuration` under `buses`)

Each bus entry follows §3.1: **`transport`**, **`transport_configuration`**, **`protocol`**, optional
**`protocol_config`**. Wire-level settings below apply to the mapping named **`transport_configuration`**
(not as siblings of **`transport`** on the bus object).

Each entry **must** set **`transport`** to **`serial`** or **`udp`**.

**Serial (`transport`: `serial`):** under **`transport_configuration`**: `port`, `baud`, `dataBits`,
`parity`, `stopBits`, optional **`rs485`** (direction-control and timing fields as implemented), …

**UDP (`transport`: `udp`):** under **`transport_configuration`**:

* **`bindHost`:** local address to bind (default `"0.0.0.0"` for all interfaces; use `"127.0.0.1"` for
  loopback-only if desired).
* **`bindPort`:** UDP port the bridge listens on for ingress (required).
* **`allowFrom`:** optional list of CIDR strings; if present, datagrams from other sources are dropped
  without emitting MQTT (defence-in-depth).
* **`defaultUdpHost`** / **`defaultUdpPort`:** optional default remote for **outbound** device control
  when a device row does not specify `udpHost` / `udpPort`.

**Bus identity:**

* **`bus-slug`** (the object key under **`buses`**) identifies the **whole bus** for MQTT topics
  (`controller/<bus-slug>/…`). **Multiple controllers** may send to the same UDP listener; all are
  on the same logical bus. Distinguish sources using **`trace`** fields on published JSON (below).

Each VISCA device references **`bus: "<bus-slug>"`**. For UDP device control, each device **must**
have a resolvable remote endpoint: **`udpHost`** / **`udpPort`** on the device row, or bus-level
**`defaultUdpHost`** / **`defaultUdpPort`**.

#### Controller events: `trace` fields (UDP)

For traffic received over UDP, `controller/<bus-slug>/event` payloads **should** include:

* **`trace.transport`:** `"udp"`.
* **`trace.remoteHost`:** source IP string.
* **`trace.remotePort`:** source UDP port (integer).
* **`trace.viscaHex`:** space-separated hex of the decoded frame (as for serial).

#### Datagram-to-frame rules (Postel principle)

**Sending (conservative):** The bridge **should** send **one complete VISCA frame per UDP datagram**,
terminated by **`0xFF`**, with payload length within a reasonable upper bound (e.g. ≤ **1024** bytes;
exact default is implementation-defined). No trailing bytes after `0xFF` in the datagram.

**Receiving (liberal):**

* A datagram may contain **one or more** complete VISCA frames, each ending with **`0xFF`**. Emit
  one MQTT controller event (or processing step) per extracted frame in order.
* **Trailing garbage** after a well-formed frame (bytes after `0xFF` before the next valid start) **may**
  be ignored, or logged at debug; implementers must not treat arbitrary padding as a second frame
  unless it parses as a new frame.
* **Incomplete frame** (no `0xFF` within the datagram): **do not** merge across datagrams unless a
  separate reassembly policy is explicitly implemented; the default is to **discard** the incomplete
  tail for that datagram (or log once at `warn`). Cross-datagram framing is a known interoperability
  hazard and is **out of scope** unless added later with explicit sequence rules.
* **Oversized datagram:** drop or truncate per implementation policy; must be documented and must not
  crash the process.

These datagram rules are **recommended normative** behaviour for interoperability (“be conservative in
what you send, liberal in what you accept”).

#### Frame handling (receive)

When a UDP datagram is received on a VISCA/UDP bus:

* Apply **`allowFrom`** if configured.
* Extract zero or more VISCA frames per the rules above.
* Pass each frame through the same “VISCA sniff / decode” path as serial RX.
  * If it matches a known controller-originated command, publish `controller/<bus-slug>/event` with
    semantic JSON (`command`, `deviceSlug` when resolvable, `payload`, **`trace`** as above).
  * If it cannot be mapped, publish a raw controller event (`command: "event"`, `payload.raw: true`)
    with **`trace.viscaHex`** and **`trace.remoteHost`** / **`trace.remotePort`**.

#### Frame handling (send — device control over UDP)

For device control, the bridge sends encoded VISCA frames (from MQTT control topics) as UDP
datagrams to the device’s **`udpHost`** / **`udpPort`**. Use the same conservative one-frame-per-datagram
rule as in “Sending” above unless a documented exception applies.

* **`device/<slug>/commandAck`** remains the authoritative bridge-originated command lifecycle result.
* **`device/<slug>/telemetry`** / **`device/<slug>/status`** remain transport-agnostic (serial vs UDP).

#### Topics and compatibility

Transport changes do not change topic shapes:

* Controller-side publishes remain `controller/<bus-slug>/event` and `controller/<bus-slug>/status`.
* Device control remains `device/<slug>/<command>` regardless of serial vs UDP.

### Requirements

* Non-blocking or timeout-based reads
* Buffered writes
* Robust reconnection handling
* Careful handling of RS-485 half-duplex bus direction and collisions (controller + bridge)

### Example devices

* `/dev/ttyUSB0`
* `/dev/ttyS0`

---

## 3.5 State Manager

### Responsibilities

* Maintain device state cache
* Track:

  * pan position
  * tilt position
  * zoom level
  * preset state

### Benefits

* Avoid redundant VISCA commands
* Enable MQTT status updates
* Provide last-known-good state

---

# 4. Data Flow

## MQTT → Device

1. MQTT message received
2. JSON parsed into `TCameraCommand`
3. Command routed to VISCA layer
4. VISCA packet encoded
5. Sent via serial port
6. Optional MQTT acknowledgement published

---

## Device → MQTT

1. VISCA response received via serial
2. Parsed into internal state update
3. Converted to JSON
4. Published to MQTT status topic

---

## Evdev → MQTT

1. libevdev delivers a `struct input_event` from a configured device node
2. Reader builds a JSON record (`type`, `typeNum`, `code`, `codeNum`, `value`, `inputSlug`, `deviceNode`, `ts`)
3. Publisher emits to `evdev/<slug>/event` (or configured topic) at QoS 0 (default)
4. No translation, no acknowledgement, no state retained

```mermaid
flowchart LR
    Kernel[Linux input subsystem] --> Evdev["/dev/input/eventX"]
    Evdev --> Reader["evdevreader (libevdev)"]
    Reader --> Loop["mainloop: poll() + MQTT tick"]
    Loop --> Publisher[mqttpublisher]
    Publisher --> Broker[MQTT broker]
    Broker --> Subscribers["Node-RED / other subscribers"]
```

---

# 5. Object Pascal Architecture

## Core principle

* Headless service first (no GUI dependency)
* Modular object-oriented design
* Free Pascal compatible

---

## Suggested class structure

```pascal
type
  TMqttClient = class
  public
    procedure Connect;
    procedure SubscribeTopics;
    procedure Publish(const Topic, Payload: string);
  end;

  TViscaController = class
  public
    procedure SendCommand(const Cmd: TCameraCommand);
  end;

  TSerialPort = class
  public
    procedure Open(const Device: string);
    procedure Write(const Data: TBytes);
    function Read: TBytes;
  end;

  TCommandRouter = class
  public
    procedure HandleMqttMessage(const Topic, Payload: string);
    procedure HandleViscaFrame(const Data: TBytes);
    procedure PublishDeviceEvent(const DeviceId: Integer; const Command: string; const PayloadJson: string);
  end;
```

The class list above describes the **eventual** shape. The implementation is split into units
under `src/` (see repository layout below).

---

## 5.1 Build & layout

HaMBridge builds with **`fpc` + `make`**. Optional IDE project metadata (e.g. `.lpi`, `.lps`) is
not committed; **`hambridge.lpr`** in `src/` is the program entry source.

### Repository layout

```
/Makefile                      # also downloads prof7bit/fpc-mqtt-client (pinned zip + SHA256) into build/deps/
/README.md
/docs/user/INSTALL.md
/docs/developers/DEVELOPING.md
/docs/user/ConfigurationGuide.md
/.gitignore
/LICENSE                       # GPL-3.0-or-later
/docs/developers/Specification.md   # this file (architecture + spec)
/CHANGELOG.md                  # release notes (human-oriented)
/ROADMAP.md                    # backlog / planned work
/config/hambridge.yaml.example
/config/mappings/visca.yaml.example
/packaging/README.md             # systemd, sysusers, tmpfiles, udev templates
/packaging/systemd/hambridge.service
/packaging/systemd/sysusers.d/hambridge.conf
/packaging/systemd/tmpfiles.d/hambridge.conf
/packaging/udev/70-hambridge-input.rules
/packaging/raspbian/README.md   # Raspberry Pi OS / Debian native build + .deb notes
/packaging/debian/             # Debian source package (dpkg-buildpackage → ../hambridge_*.deb)
/debian                         # symlink → packaging/debian (dpkg-buildpackage expects ./debian)
/src/
  hambridge.lpr                # program entry point
  config.pas                   # hambridge.yaml: bridge subtree + discovery + BRIDGE_* env override
  devicesconfig.pas            # hambridge.yaml: buses, devices[], evdev, device_mappings (VISCA path)
  logger.pas                   # stdout text logger (info/warn/error/debug)
  libevdev_binding.pas         # cdecl externs for libevdev (linked via -l:libevdev.so.2)
  evdevreader.pas              # opens /dev/input/event*, polls, emits records
  mqttpublisher.pas            # wraps prof7bit/fpc-mqtt-client; LWT + birth + device/# subscribe
  mainloop.pas                 # poll() over evdev fds + MQTT tick + VISCA router tick
  serialport.pas               # Linux serial TX (stty + fpOpen/fpWrite)
  viscamapping.pas             # VISCA map file (device_mappings.visca): encode + controller decode
  viscareplydecode.pas         # device reply → JSON decode fragment for telemetry/status
  commandrouter.pas            # MQTT device/# → queued VISCA TX per bus; status/telemetry/events
```

Unit responsibilities:

* **`hambridge.lpr`** — argument parsing (`--config`, `--help`, `--version`), top-level wiring,
  signal handling (`SIGTERM` graceful shutdown).
* **`config.pas`** — load **`hambridge.yaml`**, apply `BRIDGE_*` env overrides to the **`bridge`**
  subtree, validate. Path discovery as in §3.0.
* **`devicesconfig.pas`** — parse **`buses`**, top-level **`devices`** sequence, **`evdev`**, and
  **`device_mappings`** from the same loaded document as **`bridge`**.
* **`logger.pas`** — global logger, level-filtered, plain text to stdout. No external deps.
* **`libevdev_binding.pas`** — minimal `cdecl; external name '<symbol>'` declarations (one
  quoted linker symbol per function, e.g. `libevdev_new`) for:
  `libevdev_new`, `libevdev_free`, `libevdev_set_fd`, `libevdev_grab`,
  `libevdev_next_event`, `libevdev_event_type_get_name`, `libevdev_event_code_get_name`, plus
  the `input_event` record. Opaque `Plibevdev` pointer.
* **`evdevreader.pas`** — owns one `TEvdevInput` per configured input. Opens the device node,
  initialises libevdev, optionally grabs, exposes the underlying fd for the main loop's
  `poll()`, and turns each `input_event` into a record/JSON payload.
* **`mqttpublisher.pas`** — connects to broker, registers LWT and birth, exposes
  `Publish(topic, payload, qos, retain)`; auto-reconnects with backoff.
* **`mainloop.pas`** — single-threaded loop: `poll()` on all evdev fds, drain ready inputs,
  hand each event to the publisher, periodic MQTT keepalive tick. Exit on `SIGTERM`.

### Makefile targets

* **`make`** (default) — builds `hambridge` into `./build/` using `fpc`, linking
  `libevdev.so.2` via `-l:libevdev.so.2` and a discovered `-L` path (Fedora `/usr/lib64`,
  Debian / Raspberry Pi OS multiarch: `/usr/lib/x86_64-linux-gnu`, `/usr/lib/aarch64-linux-gnu`,
  `/usr/lib/arm-linux-gnueabihf`). Before compiling, downloads the pinned
  **`prof7bit/fpc-mqtt-client`** release zip into `./build/deps/`, verifies **SHA256**, and
  unpacks it (first build needs **network**, **`curl`**, and **`unzip`**). Recommended flags:
  `-MObjFPC -Scghi -O2 -Xs -gl` (Object Pascal mode, line info for stack traces, optimisation,
  strip after link).
* **`make clean`** — removes `./build/` (including downloaded MQTT sources) and stray `.o` /
  `.ppu` files.
* **`make run`** — convenience target: build (if needed), seed **`config/*.yaml`** from **`*.example`**
  when missing, then run **`./build/hambridge --config ./config/hambridge.yaml`** (explicit **`--config`**;
  not relying on discovery). See **`docs/developers/DEVELOPING.md`**.
* **`make raspbian-help`** — prints install hints for **Raspberry Pi OS / Debian** native builds
  (`fpc`, FCL units, `libevdev-dev`, …). Full notes: **`packaging/raspbian/README.md`**.
* **`make debian-deb`** — on **Debian / Raspberry Pi OS**, runs **`dpkg-buildpackage`** using
  **`packaging/debian/`** (exposed as **`./debian`** via symlink); produces **`../hambridge_<ver>_<arch>.deb`**.
  See **`packaging/raspbian/README.md`**.
* **`make install`** *(optional)* — install binary to `/usr/local/bin` and example configs under
  **`/etc/hambridge/config/`** (if implemented; match **`config/`** layout in the repository).

### Example config files

* **`config/hambridge.yaml.example`** — template with **`bridge`**, **`device_mappings`**, **`buses`**,
  **`devices`**, **`evdev`** (§3.0–§3.1).
* **`config/mappings/visca.yaml.example`** — minimal **`models`** / **`topics`** illustration for VISCA encode.

### Runtime prerequisites

* Linux kernel with input subsystem (any modern distro).
* `libevdev.so.2` available at runtime (e.g. `libevdev2` on Debian/Ubuntu).
* The bridge process must have read access to the configured `/dev/input/event*` nodes.
  **systemd deployments** should use an unprivileged service user (`hambridge`) plus **narrow
  udev rules** from `packaging/udev/` (preferred over adding that user to the broad `input` group).
  See [README.md](../../README.md) and [packaging/README.md](../../packaging/README.md).

---

# 6. Dependencies

HaMBridge has a small dependency footprint:

* **MQTT client**: **`prof7bit/fpc-mqtt-client`** (preferred) — pure Pascal MQTT client; not
  committed in-tree. `make` downloads a tag-pinned zip, checks **SHA256**, and unpacks under
  `./build/deps/` (see `Makefile`).
* **JSON**: `fpjson` + `jsonparser` (FCL, ships with FPC) — MQTT payloads and internal JSON helpers.
* **YAML**: third-party library for **`hambridge.yaml`** and the VISCA mapping file (see §3.0.2);
  not hand-rolled.
* **Free Pascal Compiler**: 3.2.x or newer.
* **libevdev** (Linux only): linked at build time as `-l:libevdev.so.2` (runtime SONAME; no
  unversioned `.so` symlink required).
* **Serial I/O** (Linux): uses POSIX I/O on a raw TTY (see `src/serialport.pas`).

## Notes

* The bridge is **headless** (no GUI toolkit in the runtime).
* Building uses **`fpc`** plus the root **`Makefile`** (see §5.1).

---

# 7. Runtime Requirements

* **systemd** is the expected deployment: install `packaging/systemd/hambridge.service` (and
  matching `sysusers.d` / `tmpfiles.d` snippets) so the daemon starts at boot, restarts on
  failure, and runs as user `hambridge`. See `packaging/README.md`.
* Long-running daemon/service
* Automatic MQTT reconnection
* Serial port recovery on failure
* Non-blocking main loop
* Logging of all command transitions

---

# 8. Performance Targets

* MQTT → VISCA latency: **< 50ms target**
* Lightweight CPU usage
* Single-threaded event loop acceptable
* No GUI overhead -- no GUI needed
* Multi-device support

---

# 9. Design Philosophy

> This system is a deterministic protocol translator between messaging and hardware control.

### Layers:

* MQTT = control plane
* Pascal service = translation + state management
* VISCA = execution plane (hardware)

---

# 🧠 One-line build instruction for Cursor

> Build a Free Pascal service that subscribes to MQTT device control topics, parses JSON commands, converts them into VISCA packets, sends them over RS-485/serial, and optionally publishes device state updates back to MQTT.

