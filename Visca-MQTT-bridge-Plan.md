# 📡 MQTT ↔ VISCA Bridge (Object Pascal / Free Pascal)

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
* which devices exist (IDs used in `device/<id>/...`)
* which VISCA model/profile each device uses (ties into the VISCA mapping table)
* optional per-device scheduler overrides (timing, queue bounds, coalescing rules)
* optional **evdev** inputs: which kernel input nodes to open and which MQTT topic each stream
  publishes to (see §3.1.2); the bridge emits **raw evdev-style events** only—no translation to
  VISCA or `device/<id>/...` commands in-process

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
      "id": 1,
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
        "id": "usb-keypad-ptz",
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
* **`mqttTopic`**: topic for that input’s event stream. If omitted, a default such as
  `evdev/<inputId>/event` may be used.
* **Implementation** may use the **`libevdev`** C library, a thin Pascal binding, or raw
  `ioctl`/`read` on the event device; that choice does not change the MQTT contract above.


## 3.1.1 VISCA Commands in MQTT

Define a canonical set of **VISCA commands** for the MQTT representation. These commands appear
in two places:

1. **Device control topics**: `device/<id>/<command>`
2. **Controller-originated event JSON**: `{"command": "<command>", "payload": {...}}`

The goal is that intermediaries (Node-RED, rules engines, etc.) can transform/reroute JSON and
either:

* publish directly to `device/<id>/<command>`, or
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
  * Topic: `device/1/preset/set`
  * Payload: `{ "value": 3 }`

* Controller event JSON (to `controller/rs485-1/event`):
  * ```
  	{
  		"command": "preset/set",
  		"deviceId": 1,
  		"payload": { "value": 3 } 
  	}
  	 ```

### Suggested MQTT Topics

#### Control topics

```
device/<id>/<command>
```

#### Status topics

```
device/<id>/status
device/<id>/telemetry
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

* If an intermediary knows the destination device ID, it can forward a controller event to:

  * **Canonical path form**: `device/<id>/<command>`
    - Example: controller event `{ "command": "osd/menu", ... }` → publish to `device/1/osd/menu`

  * **Alias-to-existing-control-topics form**: map event `command` to the bridge's control topics
    (recommended where topics already exist, e.g. `device/<id>/pan`, `device/<id>/tilt`,
    `device/<id>/zoom`), and forward using those topic names.

For example, a controller-derived "pan left" event could be represented as:

* Topic: `device/1/pan`
* Payload: `{ "dir": "left", "speed": 10 }`

## 3.1.2 Evdev Events in MQTT

Optional **Linux-only** capability: open configured **`/dev/input/event*`** nodes (via **libevdev**,
a thin Pascal binding, or raw `ioctl` / `read` on the character device), read kernel **input
events** (`struct input_event`: `type`, `code`, `value`, time), and **publish each event as JSON
to MQTT**.

The bridge performs **no** translation from evdev into VISCA packets or into the canonical
`device/<id>/<command>` control model (§3.1.1). **Node-RED**, rules engines, or other subscribers
subscribe to the evdev topics, interpret `type` / `code` / `value`, and publish to
`device/<id>/...` or elsewhere as needed.

### Suggested MQTT topics

Per-input topic (recommended), configured explicitly or defaulted:

```
evdev/<inputId>/event
```

### Payload shape

Stable, easy-to-parse JSON mirroring the evdev data. Symbolic names (e.g. `EV_KEY`, `KEY_KP1`) may
be included when the implementation can resolve them; numeric `type` and `code` should always be
present for unambiguous handling in Node-RED. Example:

```json
{
  "ts": 1713720000123,
  "inputId": "usb-keypad-ptz",
  "deviceNode": "/dev/input/event2",
  "source": "evdev",
  "type": "EV_KEY",
  "typeNum": 1,
  "code": "KEY_KP1",
  "codeNum": 79,
  "value": 1
}
```

### Relationship to §3.1.1

Evdev streams are **separate** from **VISCA-controller semantic events** on `controller/<bus>/event`.
The latter remain decoded VISCA → JSON; evdev topics carry **raw input events** only.

### Implementation notes

* Integrate with the process **main poll loop** (non-blocking reads on the evdev fd alongside MQTT
  and serial).
* **Hotplug** (device appears/disappears) is optional in v1; minimum viable behavior is a clear
  log or exit when `deviceNode` is missing at startup.

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

Plan for a device capability layer that can be selected per `device/<id>`:

* **Base VISCA profile**: common commands (power, zoom, preset recall/set, etc.)
* **Device profile**: model-specific support/overrides (e.g., Marshall CV344 OSD menu controls)

This can be expressed as a mapping table or a per-model encoder class (e.g. `TViscaProfileBase`,
`TViscaProfileMarshallCV344`) that the command router uses when converting MQTT messages into
VISCA packets.

#### JSON mapping table (recommended)

For device-specific commands that can be represented as static VISCA frames, use a JSON mapping
file (e.g. `visca-mapping.json`) loaded at startup. This allows adding/overriding commands per
model without recompiling.

The mapping table should support:

* **Per-model selection**: e.g. `"model": "marshall-cv344"` assigned per `device/<id>`
* **Topic → VISCA frame(s)**: static byte sequences (hex) per topic/action
* **Optional parameters**: where a command needs a numeric parameter (speed, preset), allow a
  template/encoding rule rather than raw bytes only

Example shape (illustrative only):

```json
{
  "models": {
    "base-visca": {
      "topics": {
        "power/on": { "bytes": "81 01 04 00 02 FF" },
        "power/off": { "bytes": "81 01 04 00 03 FF" }
      }
    },
    "marshall-cv344": {
      "inherits": "base-visca",
      "topics": {
        "osd/menu": { "bytes": "..." },
        "osd/up": { "bytes": "..." }
      }
    }
  }
}
```

---

## 3.4 Serial Communication Layer (RS-485)

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

---

# 6. Dependencies

## MQTT

* **`prof7bit/fpc-mqtt-client`** (preferred): pure Pascal MQTT client component (MQTT v5)

## Serial

* **Synapse `synaser`** (preferred): pure Pascal serial library (cross-platform) used for RS-485 I/O

## JSON

* `fpjson`
* `jsonparser`

## libevdev (optional, Linux only)

* **`libevdev`** (linked as `-levdev`) when the **`evdev`** config block (§3.1.2) is enabled and the
  implementation chooses that library to read input devices; otherwise omit the dependency for
  non-Linux builds or builds without evdev publishing. Raw `read`/`ioctl` on `/dev/input/event*`
  avoids this dependency entirely.

---

# 7. Runtime Requirements

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
