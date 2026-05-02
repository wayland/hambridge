# 📡 MQTT ↔ VISCA Bridge (Object Pascal / Free Pascal)

**Product name:** **HaMBridge** (Hardware-MQTT Bridge) — a headless Linux daemon; this repository
and plan focus on MQTT, Linux input (evdev), and VISCA/serial as phases land.

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

## Roadmap / Phased scope

The bridge is being built in three releases. Each release is a usable end-to-end slice; later
releases extend the same daemon rather than replacing it.

* **v0.1 — evdev → MQTT** *(current focus)*
  * Reads kernel input events from configured `/dev/input/event*` nodes via **libevdev**.
  * Publishes each event as JSON to MQTT (see §3.1.2).
  * No VISCA, no serial, no `device/<slug>/...` control topics, no state cache.
  * Linux only.
  * Out-of-process integrations (e.g. Node-RED) are responsible for translating evdev events
    into VISCA-side actions if any are wanted at this stage.

* **v0.2 — MQTT → VISCA**
  * Adds the serial layer (§3.4), VISCA encoder (§3.3), and command router (§3.2).
  * Subscribes to `device/<slug>/<command>` and drives a single bus / single device first.
  * Loads `visca-mapping.json` (§3.3) for per-model topic → byte mappings.
  * No automatic state polling yet; ACK/error reply topics introduced.

* **v0.2.1 — VISCA mapping + MQTT JSON**
  * **Framed encoding** in `visca-mapping.json`: the bridge emits **`[device]` + `bytes` + template slots + `FF`**, where **`[device]`** is **`0x80 + viscaAddress`** (from each VISCA device’s **`viscaAddress`** in `devices.json`, 1..7) and **`FF`** is the VISCA terminator (not stored per topic).
  * **`bytes`** holds the fixed middle of the command when present (typically starting with controller **`01`**, then category / command bytes — see §3.3). It may be **omitted or empty** only when a non-empty **`template`** supplies every byte between **`[device]`** and **`FF`**.
  * **`template`** / **`variables`** may be **omitted** when the command is fully described by **`bytes`** alone (fixed middle between device byte and **`FF`**).
  * **`template`** is a JSON array of **slot names**; each slot becomes **one byte** on the wire. Values come from the **MQTT JSON payload** (key = slot name, case-insensitive), then fall back to **`variables`** defaults in the mapping.
  * **Raspberry Pi OS / Debian armhf & aarch64**: the root `Makefile` discovers `libevdev.so.2` under multiarch paths; see **`packaging/raspbian/README.md`** and **`make raspbian-help`**.

* **v0.3 — VISCA → MQTT**
  * Adds inbound VISCA decoding (RS-485 sniffing of controllers, device responses).
  * Publishes `controller/<bus>/event` semantic JSON (§3.1.1).
  * Adds the State Manager (§3.5) and `device/<slug>/status` / `device/<slug>/telemetry` topics.

Sections in this document marked **Phase: v0.2** or **Phase: v0.3** describe deferred work and
are kept here for design continuity; v0.1 implementers can ignore them.

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

## 3.0 `bridge.json` (broker + runtime)

The bridge loads a process-wide configuration file separate from `devices.json`. `bridge.json`
holds **broker connection** and **runtime** settings; `devices.json` holds **what** the bridge
talks to (buses, devices, evdev inputs).

### Fields

```json
{
  "mqtt": {
    "host": "localhost",
    "port": 1883,
    "tls": false,
    "username": null,
    "password": null,
    "clientId": "hambridge",
    "keepaliveSec": 30,
    "lwt": {
      "topic": "bridge/hambridge/status",
      "payload": "offline",
      "retain": true,
      "qos": 1
    },
    "birth": {
      "topic": "bridge/hambridge/status",
      "payload": "online",
      "retain": true,
      "qos": 1
    }
  },
  "log": {
    "level": "info",
    "format": "text"
  }
}
```

Notes:

* `tls`: bool for v0.1; full TLS material (CA, cert, key, verifyPeer) is deferred — when `true`
  in v0.1, default OS trust is used.
* `clientId`: must be unique per broker; recommend suffixing with hostname or a random tail when
  running multiple bridges against one broker.
* `lwt` / `birth`: emit on connect/disconnect so subscribers can detect bridge availability.
* `log.level`: one of `debug` / `info` / `warn` / `error`.
* `log.format`: `text` for v0.1; `json` reserved for later.

### Environment-variable overrides

Any field above can be overridden by an environment variable. The mapping is mechanical:

* Prefix `BRIDGE_`, then uppercase the path, joining levels with `_`.
* Examples:
  * `BRIDGE_MQTT_HOST` → `mqtt.host`
  * `BRIDGE_MQTT_PORT` → `mqtt.port`
  * `BRIDGE_MQTT_USERNAME` → `mqtt.username`
  * `BRIDGE_MQTT_PASSWORD` → `mqtt.password`
  * `BRIDGE_MQTT_CLIENTID` → `mqtt.clientId`
  * `BRIDGE_MQTT_LWT_TOPIC` → `mqtt.lwt.topic`
  * `BRIDGE_LOG_LEVEL` → `log.level`

Env vars **win** over the file. Booleans accept `true`/`false`/`1`/`0`; integers must parse as
base-10. Empty string clears the field (treated as unset).

### Config-path discovery order

The bridge resolves `bridge.json` in this order; the first hit wins:

1. `--config <path>` command-line flag
2. `BRIDGE_CONFIG` environment variable
3. `./bridge.json` (current working directory)
4. `/etc/hambridge/bridge.json` (recommended for **HaMBridge** systemd packages; see `packaging/systemd/`)

`devices.json` follows the analogous pattern via `--devices <path>`, `BRIDGE_DEVICES`,
`./devices.json`, `/etc/hambridge/devices.json`.

If no `bridge.json` (respectively `devices.json`) is found in any of the locations above, the
bridge logs a clear error and exits non-zero.

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

### Configuration (`devices.json`)

The bridge should load a device configuration file (e.g. `devices.json`) at startup. This file
defines:

* which serial buses exist (ports and UART settings)
* which VISCA devices exist (**`slug`** for `device/<slug>/...`, **`viscaAddress`** 1..7 on the VISCA bus, **`model`**, **`bus`**, optional scheduler)
* which VISCA model/profile each device uses (ties into the VISCA mapping table)
* optional per-device scheduler overrides (timing, queue bounds, coalescing rules)
* optional **evdev** inputs: which kernel input nodes to open and which MQTT topic each stream
  publishes to (see §3.1.2); the bridge emits **raw evdev-style events** only—no translation to
  VISCA or `device/<slug>/...` commands in-process

Example shape (illustrative):

```json
{
  "buses": {
    "rs485-1": {
      "port": "/dev/ttyUSB0",
      "baud": 9600,
      "dataBits": 8,
      "parity": "N",
      "stopBits": 1
    }
  },
  "devices": [
    {
      "slug": "camera_stage",
      "model": "marshall-cv344",
      "bus": "rs485-1",
      "viscaAddress": 1,
      "scheduler": {
        "minInterCommandMs": 50,
        "ackTimeoutMs": 500,
        "maxQueueDepth": 50,
        "coalesce": ["pan", "tilt", "zoom"]
      }
    }
  ],
  "evdev": {
    "enabled": false,
    "inputs": [
      {
        "slug": "usb-keypad-ptz",
        "deviceNode": "/dev/input/event2",
        "grabExclusive": false,
        "mqttTopic": "evdev/usb-keypad-ptz/event"
      }
    ]
  }
}
```

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
* **Implementation**: v0.1 uses the **`libevdev`** C library (linked as `-l:libevdev.so.2`) via a small
  Pascal binding unit. Raw `ioctl`/`read` is reserved for a possible later alternative; either
  way the MQTT contract above does not change.


## 3.1.1 VISCA Commands in MQTT

*Phase: v0.2 (control topics) and v0.3 (semantic controller events).*

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
```

#### VISCA-controller → MQTT (semantic JSON events)

To support RS-485 controllers (hardware control panels) and remote replay/transforms through
JSON tooling (e.g. Node-RED), the bridge should be able to **listen to VISCA traffic** and publish
**decoded semantic events** to MQTT.

This is intentionally *not* a raw-bytes tunnel as the primary interface; the goal is MQTT-friendly
JSON that intermediaries can inspect/transform/reroute.

Suggested topics:

```
controller/<bus>/event
controller/<bus>/status
```

Suggested payload for `controller/<bus>/event` (JSON):

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

*Phase: v0.1 (this is the entire v0.1 surface besides MQTT and config).*

**Linux-only** capability: open configured **`/dev/input/event*`** nodes via **`libevdev`**
(linked as `-levdev`, see §6), read kernel **input events** (`struct input_event`: `type`,
`code`, `value`, time), and **publish each event as JSON to MQTT**.

Raw `read()`/`ioctl()` on the character device is a possible future alternative implementation
but is **not** an option for v0.1.

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
  not surfaced separately in v0.1 (can be added later).
* `value` follows kernel convention: for `EV_KEY` it is `0` release, `1` press, `2` repeat;
  for `EV_REL` / `EV_ABS` it is the axis value; for `EV_SYN` it is the sync subtype.

### Filtering policy

v0.1 publishes **every event the kernel delivers**, including:

* `EV_SYN` markers (so subscribers can detect input frames if they care)
* Auto-repeat key events (`value == 2`)
* All axis updates from `EV_REL` / `EV_ABS`

Subscribers are responsible for any filtering. Future versions may grow optional per-input filter
rules; v0.1 keeps the wire format faithful to the kernel.

### MQTT QoS and retain

Evdev publishes use **QoS 0** by default and **`retain = false`** (events are point-in-time;
retaining them would mislead late subscribers). These defaults are not configurable in v0.1.

### Relationship to §3.1.1

Evdev streams are **separate** from **VISCA-controller semantic events** on
`controller/<bus>/event`. The latter remain decoded VISCA → JSON; evdev topics carry **raw input
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
    `devices.json`), not on an absent input node.
* When an input is grabbed (`grabExclusive = true`), failure to acquire the grab is logged and
  the bridge falls back to non-exclusive reading rather than aborting.

---

## 3.2 Command Router

*Phase: v0.2 (initial MQTT → VISCA dispatch); extended in v0.3 to publish decoded VISCA events.*

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

*Phase: v0.2 (encoder + per-model `visca-mapping.json`); response decode extended in v0.3.*

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

Plan for a device capability layer that can be selected per `device/<slug>`:

* **Base VISCA profile**: common commands (power, zoom, preset recall/set, etc.)
* **Device profile**: model-specific support/overrides (e.g., Marshall CV344 OSD menu controls)

This can be expressed as a mapping table or a per-model encoder class (e.g. `TViscaProfileBase`,
`TViscaProfileMarshallCV344`) that the command router uses when converting MQTT messages into
VISCA packets.

 u#### JSON mapping table (recommended)

For device-specific commands that can be represented as static VISCA frames, use a JSON mapping
file (e.g. `visca-mapping.json`) loaded at startup. This allows adding/overriding commands per
model without recompiling.

The mapping table should support:

* **Per-model selection**: e.g. `"model": "marshall-cv344"` assigned per `device/<slug>`
* **Topic → VISCA frame(s)**: static byte sequences (hex) and/or **framed** rules (fixed middle + template slots)
* **Optional parameters**: MQTT JSON and `variables` defaults supply **one byte per template slot** (v0.2.1); richer encodings (multi-byte, nibbles) are a later extension.

#### Wire assembly (v0.2.1)

For topics that define a **non-empty `template`** array:

1. **`[device]`** — single byte **`0x80 + viscaAddress`** (from `devices.json`, clamped to 1..7). Not stored in `bytes`.
2. **`bytes`** — space-separated hex for the **fixed middle** (normally includes **`01`** controller + category/command bytes).
3. **Template slots** — each name in `template` appends **one byte**: look up the key in the MQTT payload object, then in **`variables`**, case-insensitive keys. Values may be JSON numbers **0–255** or strings (`"02"`, `"$02"`).
4. **`FF`** — terminator appended by the bridge.

If **`template`** is absent or empty, **`bytes`** must contain the **full middle** of the command (everything after **`[device]`** and before **`FF`**), as space-separated hex.

Example (framed + inherited model override; illustrative):

```json
{
  "models": {
    "base-visca": {
      "topics": {
        "power/on": {
          "bytes": "01 04 00",
          "template": ["powerArgument"],
          "variables": { "powerArgument": "02" }
        },
        "power/off": {
          "bytes": "01 04 00 03"
        }
      }
    },
    "marshall-cv344": {
      "inherits": "base-visca",
      "topics": {
        "preset/call": {
          "bytes": "01 04 3F 02",
          "template": ["presetIndex"],
          "variables": { "presetIndex": "01" }
        }
      }
    }
  }
}
```

Publishing MQTT to **`device/camera_stage/preset/call`** with payload **`{"presetIndex": 2}`** overrides the default **`presetIndex`** byte for that command.

---

## 3.4 Serial Communication Layer (RS-485)

*Phase: v0.2 (TX path); RX/sniff path in v0.3.*

### Responsibilities

* Open serial port device
* Configure baud rate (typically 9600 / 38400)
* Send and receive raw VISCA packets
* Handle RS-485 direction control if required
* (Optional) Listen/sniff traffic from an RS-485 VISCA controller for VISCA-over-MQTT tunneling

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

*Phase: v0.3.*

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

*Phase: v0.2.*

1. MQTT message received
2. JSON parsed into `TCameraCommand`
3. Command routed to VISCA layer
4. VISCA packet encoded
5. Sent via serial port
6. Optional MQTT acknowledgement published

---

## Device → MQTT

*Phase: v0.3.*

1. VISCA response received via serial
2. Parsed into internal state update
3. Converted to JSON
4. Published to MQTT status topic

---

## Evdev → MQTT

*Phase: v0.1.*

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

The class list above describes the **eventual** shape across all phases. v0.1 only needs the
units listed in §5.1.

---

## 5.1 Build & layout (v0.1)

v0.1 builds with **`fpc` + `make`**; no Lazarus IDE is required. The Lazarus IDE may still be
used to author code, but project files (`.lpi`, `.lpr`, `.lps`) are **not** committed.

### Repository layout

```
/Makefile                      # also downloads prof7bit/fpc-mqtt-client (pinned zip + SHA256) into build/deps/
/README.md
/DEVELOPING.md
/.gitignore
/LICENSE                       # GPL-3.0-or-later
/Visca-MQTT-bridge-Plan.md     # this file
/bridge.json.example
/devices.json.example
/packaging/README.md             # systemd, sysusers, tmpfiles, udev templates
/packaging/systemd/hambridge.service
/packaging/systemd/sysusers.d/hambridge.conf
/packaging/systemd/tmpfiles.d/hambridge.conf
/packaging/udev/70-hambridge-input.rules
/packaging/raspbian/README.md   # Raspberry Pi OS / Debian native build notes
/src/
  hambridge.lpr                # program entry point
  config.pas                   # bridge.json loader + env override
  devicesconfig.pas            # devices.json loader (evdev block in v0.1)
  logger.pas                   # stdout text logger (info/warn/error/debug)
  libevdev_binding.pas         # cdecl externs for libevdev (linked via -l:libevdev.so.2)
  evdevreader.pas              # opens /dev/input/event*, polls, emits records
  mqttpublisher.pas            # wraps prof7bit/fpc-mqtt-client; LWT + birth + device/# subscribe
  mainloop.pas                 # poll() over evdev fds + MQTT tick + VISCA router tick
  serialport.pas               # Linux serial TX (stty + fpOpen/fpWrite); v0.2+
  viscamapping.pas             # visca-mapping.json encoder (legacy + framed v0.2.1)
  commandrouter.pas            # MQTT device/# → queued VISCA TX per bus
```

Unit responsibilities for v0.1:

* **`hambridge.lpr`** — argument parsing (`--config`, `--devices`, `--help`,
  `--version`), top-level wiring, signal handling (`SIGTERM` graceful shutdown).
* **`config.pas`** — load `bridge.json`, apply `BRIDGE_*` env overrides, validate. Path
  discovery as in §3.0.
* **`devicesconfig.pas`** — load `devices.json`. v0.1 only consumes the `evdev` block; bus and
  device blocks are parsed but otherwise unused.
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
* **`make run`** — convenience target: `./build/hambridge --config ./bridge.json
  --devices ./devices.json`.
* **`make raspbian-help`** — prints install hints for **Raspberry Pi OS / Debian** native builds
  (`fpc`, FCL units, `libevdev-dev`, …). Full notes: **`packaging/raspbian/README.md`**.
* **`make install`** *(optional, post-v0.1)* — install binary to `/usr/local/bin` and example
  configs to `/etc/hambridge/`.

### Example config files

* **`bridge.json.example`** — annotated copy of the §3.0 example, with `mqtt.host` =
  `localhost`, no auth, no TLS, `log.level` = `info`.
* **`devices.json.example`** — minimal config: empty `buses` and `devices` arrays plus an
  `evdev` block with `enabled` true, one input pointing at `/dev/input/event0` (edit to a node
  you can read), and `mqttTopic` = `evdev/example/event`.

### Runtime prerequisites

* Linux kernel with input subsystem (any modern distro).
* `libevdev.so.2` available at runtime (e.g. `libevdev2` on Debian/Ubuntu).
* The bridge process must have read access to the configured `/dev/input/event*` nodes.
  **systemd deployments** should use an unprivileged service user (`hambridge`) plus **narrow
  udev rules** from `packaging/udev/` (preferred over adding that user to the broad `input` group).
  See [README.md](README.md) and [packaging/README.md](packaging/README.md).

---

# 6. Dependencies

Dependencies are listed alongside the phase that introduces them. v0.1 has the smallest set.

## v0.1 (required)

* **MQTT client**: **`prof7bit/fpc-mqtt-client`** (preferred) — pure Pascal MQTT v5 client;
  **not** committed in-tree: `make` downloads a **tag-pinned** zip, checks **SHA256**, unpacks
  under `./build/deps/` (see `Makefile`).
* **JSON**: `fpjson` + `jsonparser` (FCL, ships with FPC) — used to load `bridge.json` /
  `devices.json` and to encode evdev event payloads.
* **libevdev** (Linux only): the C library `libevdev`, linked at build time as `-l:libevdev.so.2`
  (runtime SONAME; no unversioned `.so` symlink required). Distro packages: Debian/Ubuntu
  `libevdev2`, Fedora `libevdev`, Arch `libevdev`. v0.1 calls this library via a small in-tree
  Pascal binding (`src/libevdev_binding.pas`); there is no separate Pascal package dependency.
  Optional `-dev` / `-devel` packages are only needed when editing the binding against C headers.
* **Free Pascal Compiler**: 3.2.x or newer.

## v0.2 (added)

* **Serial**: Linux **`stty`** + **`fpOpen`/`fpWrite`** on a raw TTY (see `src/serialport.pas`).
  *Note:* the plan previously mentioned Synapse `synaser` as an option; the implemented v0.2
  path uses POSIX I/O without that dependency.

## v0.3 (added)

* No new third-party dependencies expected; reuses the v0.2 serial layer for RS-485 RX and the
  existing JSON stack for `controller/<bus>/event` and status/telemetry payloads.

## Notes

* The bridge is **headless**; LCL / Lazarus runtime components are not required.
* Building does not require the Lazarus IDE — `fpc` plus a Makefile is the supported flow.

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

# 9. Optional Extensions

* Macro command sequences (multi-step VISCA scripts)
* Scheduled presets / automation rules

---

# 10. Design Philosophy

> This system is a deterministic protocol translator between messaging and hardware control.

### Layers:

* MQTT = control plane
* Pascal service = translation + state management
* VISCA = execution plane (hardware)

---

# 🧠 One-line build instruction for Cursor

> Build a Free Pascal service that subscribes to MQTT device control topics, parses JSON commands, converts them into VISCA packets, sends them over RS-485/serial, and optionally publishes device state updates back to MQTT.

---

If you want next, I can turn this into:

* a **full Free Pascal project skeleton (.lpi + unit files)**
* or a **strict MQTT ↔ VISCA mapping spec (exact payload examples + packet formats)** which is usually the next thing Cursor needs to generate correct code.
