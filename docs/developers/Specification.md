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

- **evdev → MQTT**: publish kernel input events as JSON on **`controller/<slug>/event`** (**`endpoints`**
  **`controller`** / **`match.protocol: evdev`**, §3.1.2)
- **MQTT → VISCA**: subscribe to `device/<slug>/<command>` and send VISCA over serial
- **VISCA → MQTT**: decode controller traffic (`controller/<slug>/...`) and device replies (`device/<slug>/...`)

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
* **`endpoints`** — sequence (array) of **endpoint** records (§3.1): each has a **`slug`**, a **`match`**
  stanza, and type-specific fields (e.g. VISCA **`device`** endpoints use **`model`**, optional **`scheduler`**;
  Linux input is configured as **`endpoint_type: controller`** with **`match.protocol: evdev`** — §3.1.2).

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

Throughout the YAML document (root, **`bridge`**, **`device_mappings`**, **`buses`**, endpoint rows,
bus entries, and other objects defined in this spec): **unknown keys are ignored** (no
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

**`bridge`**, **`device_mappings`**, **`buses`**, and **`endpoints`** are **siblings**
at the document root (same file as **`hambridge.yaml`**). A second on-disk file is required only for
the VISCA mapping document referenced by **`device_mappings.visca`**.

If no configuration file is found, the bridge logs a clear error and exits non-zero.

---

## 3.1 MQTT Client Module

### Responsibilities

* Connect to MQTT broker (TCP/IP)
* Subscribe to control topics
* Publish status, acknowledgements, controller-originated events (including **Linux evdev** as
  **`controller/<slug>/…`** — §3.1.2)
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
* **`endpoints`**: sequence of endpoints; each has a **`slug`** and **`match`** (**`endpoint_type`**
  **`device`** vs **`controller`**, wire **`bus`**, and for controllers **`match.protocol`**: **`evdev`**
  or **`visca`**). See **Normative endpoints schema** below.

#### Normative bus entry schema

Each value under **`buses.<bus-slug>`** is a mapping with:

* **`transport`** (required): wire transport identifier. For **`protocol: visca`**, **`serial`** or
  **`udp`** as in §3.4. For **`protocol: evdev`** (Linux input bus), **`transport`** **must**
  be **`none`** and **`transport_configuration`** **must** be **`{}`** (no TTY or UDP socket).
* **`transport_configuration`** (required): mapping whose **keys depend on `transport`** (serial
  vs UDP field sets are defined in §3.4). For **`transport: none`**, use an **empty** mapping **`{}`**.
* **`protocol`** (required): logical protocol on that bus: **`visca`** (VISCA on serial/UDP) or
  **`evdev`** (logical grouping for Linux input **controller** endpoints).
* **`protocol_config`** (optional): protocol-specific options. For **`protocol: evdev`**, **`enabled`**
  (boolean) **must** be present: when **`false`**, no endpoint may reference this **`bus-slug`** in
  **`match.bus`**. Other keys are **ignored** if irrelevant (§3.0.3).

**`buses` object keys** are **bus-slugs**: they identify the **shared wire or logical medium** for
**`match.bus`** on **device** and **controller** endpoints (e.g. VISCA medium, or the **`evdev`**
logical bus). **Controller MQTT topics** use the **endpoint `slug`**, not the bus-slug (§3.1.1).

**Validation (normative, wire buses):**

* **`protocol: visca`** **must** use **`transport: serial`** or **`transport: udp`** (never **`none`**).
* **`transport: udp`** **must** pair with **`protocol: visca`** on that row (UDP is only for VISCA wire
  in this spec; **`evdev`** buses use **`transport: none`**).
* **`transport: udp`**: **`transport_configuration.bindPort`** is **required**; **`bindHost`** follows §3.4.
  **Multiple** **`transport: udp`** rows (**multiple bus-slugs**) are allowed — each defines its own
  listen socket **`bindHost`/`bindPort`** (ports **must** not conflict on the host).
* **`transport: serial`**: **`transport_configuration.port`** (and related serial fields) per §3.4.

#### Normative endpoints schema

The top-level **`endpoints`** key is a **sequence** (YAML array); each element is one **endpoint**
object. Per-field rules are summarized in the table below. Unknown keys under **`match`** (and other
reserved **`match`** dimensions such as sysfs / USB identity) **may** appear in later revisions; until
then they are **ignored** per §3.0.3.

**Normative field summary (`endpoints[]` is a YAML sequence; each row is one endpoint object):**

| Config Item | Requires | Values | Notes |
|-------------|----------|--------|-------|
| **`endpoints[].slug`** | Always | `camera_stage`, `usb-keypad-ptz` | Letters, digits, `_`, `-` only; no `/`. Used in MQTT: `device/<slug>/…` or `controller/<slug>/…`. **Globally unique** across all endpoints. |
| **`endpoints[].match`** | Always | *(mapping)* | Discriminates **`device`** vs **`controller`** and binds the endpoint to a **`buses`** row. |
| **`endpoints[].match.endpoint_type`** | Always | `device`, `controller` | Together with **`match.protocol`** (controllers) determines which other keys apply. |
| **`endpoints[].match.bus`** | Always | `rs485-1`, `evdev` | **Bus-slug**; **must** match a key under **`buses`**. For **`device`**, that bus **`protocol`** **must** be **`visca`**. For **`controller`** + **`evdev`**, bus **`protocol`** **must** be **`evdev`** and **`protocol_config.enabled`** **must** be **`true`**. For **`controller`** + **`visca`**, bus **`protocol`** **must** be **`visca`** (**`transport`** **`serial`** or **`udp`**). |
| **`endpoints[].match.protocol`** | **`endpoint_type: controller`** only | `evdev`, `visca` | **Must not** appear on **`device`**. **`visca`**: ingress decode for that **VISCA** bus (serial or UDP wire); publish MQTT JSON on **`controller/<slug>/…`**. **At most one** **`controller`** endpoint with **`match.protocol: visca`** per **`match.bus`** (single decode owner per medium). |
| **`endpoints[].match.deviceID`** | **`device`** and **`buses[match.bus].protocol` is `visca`** | `1` … `7` | VISCA peripheral address (wire byte **`0x80 + deviceID`**); same role as pre-v0.4.2 **`viscaAddress`**. Omit when not a VISCA **device** endpoint. |
| **`endpoints[].match.deviceNode`** | **`controller`** and **`match.protocol` is `evdev`** | `/dev/input/event2` | Kernel evdev character device path. **Pairwise unique** among **`evdev`** controllers. |
| **`endpoints[].model`** | **`device`** only | `marshall-cv344` | **Must not** appear on **`controller`**. Selects **`models.<name>`** in **`device_mappings.visca`**. |
| **`endpoints[].scheduler`** | Optional; meaningful only for **`device`** | *(mapping)* | VISCA pacing: **`minInterCommandMs`**, **`maxQueueDepth`**, **`ackTimeoutMs`**, **`commandRetryMax`**, **`retryBackoffMs`**, **`coalesce`** (array of path segments). On **`controller`** + **`evdev`**: **ignored** if present. |
| **`endpoints[].udpHost`**, **`endpoints[].udpPort`** | **`device`** on **`transport: udp`** bus | `192.0.2.10`, `52381` | **Required** unless **`buses[match.bus].transport_configuration`** sets **both** **`defaultUdpHost`** and **`defaultUdpPort`** (then those are the fallback for outbound and **must-match** reply correlation — §3.4). If the endpoint sets **either** host or port, **both** **must** be set. Omit when **`transport`** is not **`udp`**. |
| **`endpoints[].grabExclusive`** | Optional **`controller`** + **`evdev`** | `true`, `false` | `EVIOCGRAB`; default **`false`** if omitted (implementation-defined but must document). |
| **`endpoints[].mqttTopic`** | Optional **`controller`** + **`evdev`** | `custom/topic` | Overrides **event** publish topic only; default **`controller/<slug>/event`**. Implementations **should** publish **`controller/<slug>/status`** snapshots (same pattern as VISCA controller streams) unless documented otherwise. |

**Binding and uniqueness (normative):** For **`device/<slug>/<command>`**, the bridge resolves **`slug`**
to the unique **`endpoint_type: device`** entry. **`match.bus`** / **`match.deviceID`** supply wire routing
and **`[device]`** assembly (§3.3). **Serial:** inbound VISCA replies are attributed by **`(match.bus, match.deviceID)`**
on the shared medium. **UDP:** see §3.4 — reply routing uses **`(match.bus, remoteHost, remotePort, match.deviceID)`**
per decoded frame, where **`remoteHost/remotePort`** **must** match the endpoint’s resolved **`udpHost/udpPort`**.

**`slug`** **must** be **pairwise distinct across all endpoints** (device and controller). Among **`device`**
endpoints on **`visca`** **serial** buses, **`(match.bus, match.deviceID)`** **must** be pairwise distinct.
Among **`device`** endpoints on the **same** **`transport: udp`** **`match.bus`**, **`(udpHost, udpPort, match.deviceID)`**
**must** be pairwise distinct after resolving bus **`defaultUdpHost`/`defaultUdpPort`** (same triple must
not identify two endpoints).

**No reuse across buses (UDP, normative):** A resolved **`(udpHost, udpPort)`** pair **must not** appear on
**two different** UDP VISCA buses. In other words: two endpoints may share the same remote **`udpHost/udpPort`**
only when they share the same **`match.bus`**; distinction between devices behind one remote then relies on
different **`match.deviceID`** values (i.e. unique **`(udpHost, udpPort, match.deviceID)`** on that bus).

**At most one** **`controller`** with **`match.protocol: visca`** per **`match.bus`**. Among **`controller`**
endpoints with **`match.protocol: evdev`**, **`match.deviceNode`** **must** be pairwise distinct (one endpoint
per opened input node).

Example shape (illustrative; **`serial` + `visca`**, **`udp` + `visca`**, and **`evdev`** logical bus):

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
  evdev:
    transport: none
    protocol: evdev
    protocol_config:
      enabled: true
    transport_configuration: {}

endpoints:
  - match:
      endpoint_type: device
      bus: rs485-1
      deviceID: 1
    slug: camera_stage
    model: marshall-cv344
    scheduler:
      minInterCommandMs: 50
      ackTimeoutMs: 500
      commandRetryMax: 2
      retryBackoffMs: 50
      maxQueueDepth: 50
      coalesce: [pan, tilt, zoom]
  - match:
      endpoint_type: controller
      protocol: evdev
      bus: evdev
      deviceNode: /dev/input/event2
    slug: usb-keypad-ptz
    grabExclusive: false
  - match:
      endpoint_type: device
      bus: visca-udp-1
      deviceID: 1
    slug: camera_udp
    model: marshall-cv344
    udpHost: 192.0.2.10
    udpPort: 52381
  - match:
      endpoint_type: controller
      protocol: visca
      bus: visca-udp-1
    slug: udp-visca-sniff
```

Per-endpoint **`scheduler`** (VISCA **`device`** endpoints): **`minInterCommandMs`**,
**`maxQueueDepth`**, **`ackTimeoutMs`**, **`commandRetryMax`**,
**`retryBackoffMs`**. **`coalesce`** is a sequence of
**first path segments** (e.g. `pan` matches `pan` and `pan/…` topics): before
enqueueing a new command, the bridge drops older **queued** commands for the
same device and segment (the command currently waiting for ACK is never removed
this way).

Wire-specific serial and UDP fields are specified under **`transport_configuration`** in §3.4.

**VISCA logical bus vs wire addressing (for `buses.*.protocol: visca` only):** The Sony VISCA framing you use on a link does **not**
define a separate global “bus ID” byte distinct from **device/peripheral address** (typically
**1–7**, configured as **`match.deviceID`** per **`endpoint_type: device`** endpoint). One physical medium — one serial port (**one
`bus-slug`**) or one UDP bind (**one `bus-slug`**) — carries traffic for **multiple** devices that
differ by **`match.deviceID`** only. So the mapping is:
**`bus-slug` → one transport endpoint (TTY or UDP listener) → one shared VISCA medium**;
**`match.deviceID` → which device on that medium**. (Some ecosystems use the words “bus” loosely; on
the wire here, **per-medium** identity is the bridge **`bus-slug`**, and **per-device** identity on
that medium is **`match.deviceID`**.)

**`protocol: evdev` buses:** A bus entry with **`protocol: evdev`** is a **logical** bus (no serial or
UDP socket). It groups **Linux input** **controller** endpoints that list its **`bus-slug`** in **`match.bus`**.
**`protocol_config.enabled`** gates whether those endpoints are active.


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

* Controller event JSON (to **`controller/<slug>/event`**, e.g. `controller/ptz-panel/event`):
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

`device/<slug>/status`: JSON includes **`lastController`**, **`lastReply`**, and optional **`state`** (`pan`, `tilt`, `zoom`, `preset` keys with last-known MQTT JSON payloads from the bridge or from decoded controller traffic). **`lastController`** is the last **MQTT-published** semantic or raw event from a **VISCA** **`controller`** endpoint (**`controller/<slug>/…`**), not the result of UDP **reply** correlation alone. **`lastReply`** (device-originated) uses **UDP** **source IP:port** + **`deviceID`** correlation per §3.4 when **`transport: udp`**. **`lastReply`** may include the same **`decode`** field as telemetry when available.

`device/<slug>/commandAck`: JSON result for each **bridge-originated** VISCA command (success after ACK/completion, failure on timeout / serial or UDP I/O / encode / VISCA error). Set `scheduler.ackTimeoutMs` to **0** to skip waiting for a VISCA reply (fire-and-forget; payload still reports `viscaKind` **immediate**). When the encoded packet matches the last successful wire for that command path, the bridge may skip TX and publish `viscaKind: skipped` with `reason: redundant`.

#### VISCA-controller → MQTT (semantic JSON events)

To support RS-485 controllers (hardware control panels) and remote replay/transforms through
JSON tooling (e.g. Node-RED), the bridge should be able to **listen to VISCA traffic** and publish
**decoded semantic events** to MQTT.

This is intentionally *not* a raw-bytes tunnel as the primary interface; the goal is MQTT-friendly
JSON that intermediaries can inspect/transform/reroute.

Suggested topics ( **`slug`** = the **controller endpoint’s** `slug` from **`endpoints`**):

```
controller/<slug>/event
controller/<slug>/status
```

The bridge publishes **`controller/<slug>/status`** after each **`controller/<slug>/event`** for that
endpoint and (for VISCA decode paths) after device-side replies on the **same `match.bus`**, with
**`lastController`** and **`lastDeviceReply`** snapshots (JSON objects or `null`) as today’s semantics,
but keyed to the **endpoint `slug`** topic family.

Suggested payload for **`controller/<slug>/event`** (VISCA-derived JSON):

```json
{
  "ts": 1713720000,
  "bus": "rs485-1",
  "slug": "ptz-panel",
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
* **`bus`** is the **`match.bus`** bus-slug (wire medium). **`slug`** repeats the endpoint **`slug`**
  (topic segment) for subscribers that only inspect payloads.
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

## 3.1.2 Linux evdev (controller endpoints)

**Linux-only** capability: each **`endpoint_type: controller`** endpoint with **`match.protocol: evdev`**
opens **`match.deviceNode`** via **`libevdev`** (linked as `-l:libevdev.so.2`, see §6), reads kernel
**input events** (`struct input_event`: `type`, `code`, `value`, time), and **publishes each event as
JSON** to MQTT.

Configuration lives only under **`endpoints`** (there is **no** top-level **`evdev`** block). The
endpoint’s **`match.bus`** **must** reference a **`buses`** entry with **`protocol: evdev`** and
**`protocol_config.enabled: true`**.

Raw `read()`/`ioctl()` without libevdev is a possible future alternative; the MQTT contract below does
not change.

The bridge performs **no** translation from evdev into VISCA packets or into the canonical
**`device/<slug>/<command>`** control model (§3.1.1). Subscribers use **`controller/<slug>/event`** and
may publish to **`device/<slug>/…`** or elsewhere as needed.

### MQTT topics

Default per-endpoint event topic:

```
controller/<slug>/event
```

Optional **`mqttTopic`** on the endpoint overrides the event topic only; status snapshots (if
implemented) remain under **`controller/<slug>/status`** unless otherwise documented by the
implementation.

The historical **`evdev/<slug>/event`** topic family is **removed** from the normative spec.

### Payload shape

Stable, easy-to-parse JSON mirroring the evdev data. Numeric **`typeNum`** and **`codeNum`** are
**always** present. Symbolic **`type`** and **`code`** strings come from **`libevdev_event_type_get_name`**
and **`libevdev_event_code_get_name`**; if resolution fails, those fields are **`null`**. Example:

```json
{
  "ts": 1713720000123,
  "slug": "usb-keypad-ptz",
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

* **`slug`** and **`inputSlug`** **must** both repeat the endpoint **`slug`** (same string) for
  compatibility with older consumers that read **`inputSlug`**.
* **`bus`** may be included as the **`match.bus`** bus-slug (logical **`evdev`** bus); recommended for
  symmetry with VISCA controller JSON.

* `ts` is milliseconds since Unix epoch from the bridge clock; the kernel `input_event.time` is
  not surfaced separately (can be added later).
* `value` follows kernel convention: for `EV_KEY` it is `0` release, `1` press, `2` repeat;
  for `EV_REL` / `EV_ABS` it is the axis value; for `EV_SYN` it is the sync subtype.

### Filtering policy

The bridge publishes **every event the kernel delivers**, including **`EV_SYN`**, auto-repeat key
events (`value == 2`), and axis updates. Subscribers filter as needed.

### MQTT QoS and retain

Evdev-derived publishes use **QoS 0** by default and **`retain = false`**.

### Relationship to §3.1.1

**Evdev** traffic is a **`controller`** stream: **`controller/<slug>/event`** carries **raw** kernel
input JSON. **VISCA** **`controller`** endpoints (**`match.protocol: visca`**, bus **`serial`** or **`udp`**)
use the **same MQTT topic family** with decoded **`command`** / **`payload`** / **`trace.viscaHex`** shapes.

### Implementation notes

* Integrate with the process **main poll loop**: a single thread does `poll()` over each input
  fd plus a periodic MQTT client tick. No per-input thread.
* **Hotplug** policy:
  * If **`match.deviceNode`** is missing or temporarily unavailable at startup or after disconnect, the
    bridge logs a warning and **retries with exponential backoff** (e.g. 1 s → 2 s → 4 s,
    capped at ~30 s).
  * Read errors that look like a disconnected device (e.g. `ENODEV`) close the fd and re-enter
    the retry loop.
  * The bridge **only exits non-zero** on clearly fatal misconfiguration (e.g. malformed
    `hambridge.yaml`), not on an absent input node.
* When **`grabExclusive`** is true, failure to acquire the grab is logged and the bridge falls back to
  non-exclusive reading rather than aborting.

* **Implementation**: HaMBridge uses the **`libevdev`** C library via a small Pascal binding unit.

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
implementation detail). The bridge selects the mapping **`model`** string from each **`endpoint_type: device`**
object in the **`endpoints`** sequence in **`hambridge.yaml`**. There is **no** specified or required parallel layer of per-model Pascal “encoder
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

1. **`[device]`** — single byte **`0x80 + match.deviceID`** (from the **`endpoint_type: device`** endpoint in **`hambridge.yaml`**, clamped to 1..7). Not stored in `bytes`.
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

In addition to serial buses, HaMBridge supports VISCA carried in **UDP datagrams** on the wire
(**raw VISCA framing** — bytes terminated by **`0xFF`** per §3.3 / §3.4). **JSON exists only on MQTT**;
UDP payloads are **not** JSON.

This transport supports:

1. **Controller ingest / decode:** receive VISCA frames on the bus’s **`bindHost`/`bindPort`** and run
   the same decode path as serial RX. Publish **MQTT** JSON on **`controller/<slug>/event`** (and
   **`controller/<slug>/status`**), where **`slug`** is the **`endpoint_type: controller`** row with
   **`match.protocol: visca`** and **`match.bus`** equal to that UDP bus-slug (**exactly one** such
   endpoint per **`match.bus`** — see endpoints table).
2. **Device control:** send **VISCA** datagrams to cameras/controllers; **MQTT**
   **`device/<slug>/commandAck`**, **`device/<slug>/telemetry`**, and **`device/<slug>/status`** use the
   **same JSON semantics** as on serial (telemetry/status parity — §3.1.1).

#### Configuration (`transport_configuration` under `buses`)

Each bus entry follows §3.1: **`transport`**, **`transport_configuration`**, **`protocol`**, optional
**`protocol_config`**. Wire-level settings below apply to the mapping named **`transport_configuration`**
(not as siblings of **`transport`** on the bus object).

Each entry **must** set **`transport`** to **`serial`**, **`udp`**, or **`none`** ( **`none`** only when
**`protocol`** is **`evdev`**, per §3.1).

**Serial (`transport`: `serial`):** under **`transport_configuration`**: `port`, `baud`, `dataBits`,
`parity`, `stopBits`, optional **`rs485`** (direction-control and timing fields as implemented), …

**UDP (`transport`: `udp`):** under **`transport_configuration`**:

* **`bindHost`:** local address to bind (default `"0.0.0.0"` for all interfaces; use `"127.0.0.1"` for
  loopback-only if desired).
* **`bindPort`:** UDP port the bridge listens on for ingress (required).
* **`allowFrom`:** optional list of CIDR strings; if present, datagrams from other sources are dropped
  without emitting MQTT (defence-in-depth).
* **`defaultUdpHost`** / **`defaultUdpPort`:** optional default remote for **outbound** device control
  when a **`device`** endpoint does not specify `udpHost` / `udpPort`.

**Evdev logical bus (`transport`: `none`, `protocol`: `evdev`):** **`transport_configuration`** is **`{}`**.
No serial or UDP socket is opened for this bus row. **`protocol_config.enabled`** gates **`match.bus`**
references from **`endpoints`** (§3.1).

**Bus identity:**

* **`bus-slug`** (the object key under **`buses`**) identifies the **shared wire or logical medium**
  (VISCA serial/UDP, or the **`evdev`** logical bus). **Controller MQTT topics** use **`controller/<slug>/…`**
  where **`slug`** is the **endpoint**’s **`slug`**, not the bus-slug. **Multiple UDP senders** may hit
  the same **`bindPort`**; distinguish sources using **`trace`** fields on published JSON (below).

Each VISCA **`device`** endpoint references **`match.bus: "<bus-slug>"`**. For **UDP** device control,
the **remote** host/port used for **outbound** datagrams is:

* **`endpoints[].udpHost`** and **`endpoints[].udpPort`** when **both** are set on the endpoint; else
* **`transport_configuration.defaultUdpHost`** and **`defaultUdpPort`** on that **`buses`** row — **both**
  **must** be set if the endpoint omits **`udpHost`/`udpPort`**.

**Load-time:** every **`device`** on a **`transport: udp`** bus **must** have a resolvable **`(udpHost, udpPort)`**
after the rule above (else fail closed).

**Reply routing (UDP, normative):** Device-originated datagrams arrive on the socket for **`buses.<bus-slug>`**
(so the **bus** is known from the receiving socket). Let **`remoteHost`** / **`remotePort`** be the datagram
source. For each extracted VISCA frame, parse its **device/peripheral address** byte and compute
**`deviceID`** (1..7).

Attribute that frame to the unique **`endpoint_type: device`** endpoint with:

* **`match.bus`** equal to this bus-slug,
* resolved **`udpHost`/`udpPort`** equal to **`remoteHost`/`remotePort`** (string and port **must match** exactly), and
* **`match.deviceID`** equal to the parsed **`deviceID`**.

Then run the same device-reply decode and publish pipeline as serial for **`device/<slug>/telemetry`** and
**`device/<slug>/status`**.

**NAT / asymmetric paths:** the **remoteHost/remotePort must-match** rule is strict — deployments
where return traffic does not match the configured remote **will not** correlate; relaxing that is a
later spec change.

**Sufficiency:** **`(bus via receiving socket, remoteHost, remotePort, deviceID in frame)`** is sufficient
when uniqueness holds: **on the same UDP bus**, no two **`device`** endpoints share the same resolved
**`(udpHost, udpPort, deviceID)`** triple. Two devices may share one NAT public **`(host, port)`** when
their VISCA **`deviceID`** values differ (the triple stays unique). If the triple is duplicated, routing
is ambiguous and the bridge must fail load (preferred) or log-and-drop (must be documented).

**ACK / completion / retry (UDP, recommendation):** Use the **same** per-endpoint **`scheduler`** fields as
serial (**`ackTimeoutMs`**, **`commandRetryMax`**, **`retryBackoffMs`**, …). Lossy links may need a **lower**
**`ackTimeoutMs`** or operator tuning; implementations **should** treat persistent UDP socket errors like
serial I/O errors (log, backoff, continue).

#### Controller events: `trace` fields (UDP)

For traffic received over UDP, **`controller/<slug>/event`** payloads **should** include:

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

These datagram rules are **normative** for UDP VISCA interoperability (“be conservative in what
you send, liberal in what you accept”).

#### Frame handling (receive)

When a UDP datagram is received on a VISCA/UDP bus:

* Apply **`allowFrom`** if configured.
* Extract zero or more **VISCA** frames per the rules above (wire bytes only).
* **Device-originated** replies: attribute to **`device/<slug>/…`** using **reply routing** above, then run
  the same reply/decode path as serial for **`telemetry`/`status`**.
* **Controller-originated** (or unclassified) frames: pass through the same “VISCA sniff / decode” path
  as serial RX. Let **`slug`** be the **`controller`** endpoint **`slug`** with **`match.protocol: visca`**
  and **`match.bus`** equal to this bus-slug.
  * If it matches a known controller-originated command, publish **`controller/<slug>/event`** with
    semantic **MQTT** JSON (`command`, `deviceSlug` when resolvable, `payload`, **`trace`** as above).
  * If it cannot be mapped, publish a raw controller event (`command: "event"`, `payload.raw: true`)
    with **`trace.viscaHex`** and **`trace.remoteHost`** / **`trace.remotePort`**.

#### Frame handling (send — device control over UDP)

For device control, the bridge sends **encoded VISCA** frames (from MQTT-subscribed control topics) as
UDP datagrams to the endpoint’s **resolved** **`udpHost`/`udpPort`** (endpoint fields or bus defaults).
Use the same conservative one-frame-per-datagram rule as in “Sending” above unless a documented exception applies.

* **`device/<slug>/commandAck`** remains the authoritative bridge-originated command lifecycle result.
* **`device/<slug>/telemetry`** / **`device/<slug>/status`** remain transport-agnostic (serial vs UDP).

#### Topics and compatibility

**MQTT** topic shapes do not depend on serial vs UDP:

* Controller-side publishes use **`controller/<slug>/event`** and **`controller/<slug>/status`**
  ( **`slug`** = the owning **`controller`** endpoint).
* Device control remains **`device/<slug>/<command>`**; **`telemetry`**, **`status`**, **`commandAck`**
  JSON **must** follow the same semantics as on serial (field names, **`decode`**, lifecycle), aside from
  optional transport hints inside payloads where already allowed.

### Requirements

* Non-blocking or timeout-based reads
* Buffered writes
* Robust reconnection handling
* Careful handling of RS-485 half-duplex bus direction and collisions (controller + bridge)

### Example serial device nodes

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

1. libevdev delivers a `struct input_event` from **`match.deviceNode`** on a **`controller` / `evdev`** endpoint
2. Reader builds a JSON record (`type`, `typeNum`, `code`, `codeNum`, `value`, `slug`, `inputSlug`, `deviceNode`, `ts`)
3. Publisher emits to **`controller/<slug>/event`** (or **`mqttTopic`** override) at QoS 0 (default)
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
  devicesconfig.pas            # hambridge.yaml: buses, endpoints[], device_mappings (VISCA path)
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
* **`devicesconfig.pas`** — parse **`buses`**, top-level **`endpoints`** sequence, and
  **`device_mappings`** from the same loaded document as **`bridge`** (including **`protocol: evdev`**
  buses and **`match.protocol: evdev`** controller endpoints).
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
  **`endpoints`** (§3.0–§3.1); Linux input via **`buses.*.protocol: evdev`** plus **`endpoints`** controller rows.
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

