# HaMBridge roadmap

This file lists **planned or deferred work** compared to [`docs/developers/Specification.md`](docs/developers/Specification.md) and the current codebase. **Shipped releases** are recorded in [`CHANGELOG.md`](CHANGELOG.md).

---

## v0.3.1 — Real-Bus Discipline and Transport Hardening

**Intent:** tighten real-bus behaviour (timing, failures, feedback) on top of v0.3’s VISCA → MQTT surface.

**Design note — queues:** The bridge uses **per-bus** command FIFOs with an inter-command gap. That is **intentional** (and preferred to strict per-device serialization for this design); it is not listed as a gap.

**Reference — max queue depth:** Each VISCA device defaults to **`maxQueueDepth` = 50** queued commands (`hambridge.yaml` **`endpoints`** → **`endpoint_type: device`** → **`scheduler.maxQueueDepth`**, clamped to **≥ 1**). For each serial bus, the router uses the **largest** `maxQueueDepth` among devices on that bus as the cap for the **shared** bus queue (see `commandrouter` / `devicesconfig`).

### Real-Bus Discipline and Transport Hardening Checklist

- [x] **ACK / completion discipline** — Parse `scheduler.ackTimeoutMs`; after each bridge-originated command, wait for VISCA ACK / completion / error or **timeout** before the next command on that bus. **`ackTimeoutMs`: 0** skips the wait (see plan §3.1.1).
- [x] **Serial reconnection / recovery** — Reopen the TTY after hard read/write errors with exponential backoff (`serialport`).
- [x] **MQTT acknowledgements after bridge-originated VISCA TX** — Publish JSON on **`device/<slug>/commandAck`** (`ok`, `reason`, `attempts`, `viscaKind`, `viscaHex`, …).
- [x] **RS-485 half-duplex / direction / collisions** — Optional per-bus **`rs485`** under **`transport_configuration`** in **`hambridge.yaml`**: `TIOCSRS485` (`enabled`, `rtsOnSend`, `rtsAfterSend`, delays). Shared-bus collision behaviour remains deployment-defined; no software multi-master arbitration.
- [x] **Retry failed VISCA commands** — `scheduler.commandRetryMax` (extra attempts after the first TX) and **`retryBackoffMs`** before each resend; final failure publishes **`commandAck`** with `reason: timeout`.
- [x] **Multi-byte template slots** — Template array entries may be strings (1 byte) or objects **`slot` + `width`** (1..8); MQTT / `variables` supply a big-endian integer or a byte array. **Nibbles** remain deferred (ROADMAP).
- [x] **Buffered serial writes** — Software TX queue + **`PumpTransmit`** handles partial **`write()`** and **`EAGAIN`** (non-blocking fd).

---

## v0.3.2 — Coalescing and Device State Cache

**Intent:** scheduling and **state** above raw bytes-on-the-wire (without replacing the VISCA mapping file as the way new commands are defined).

### Coalescing and Device State Cache Checklist

- [x] **Coalescing for continuous controls** — When **`scheduler.coalesce`** lists a command’s first path segment (e.g. `pan`), older **queued** (not in-flight) commands for the same device and segment are dropped before enqueueing the newest.
- [x] **Device state cache** (plan §3.5) — Last MQTT JSON for **`pan`**, **`tilt`**, **`zoom`**, and **preset**-family paths (`preset/…`) is merged into **`device/<slug>/status`** as a **`state`** object. Updates come from **bridge-originated** successes and **controller** semantic decodes (re-encoded wire); device **inquiry** semantics remain **v0.3.3**.
- [x] **Use cache to skip redundant VISCA** — If the encoded packet matches the per-path **last wire** cache, the bridge skips TX (MQTT **`commandAck`** with `reason: redundant` / `viscaKind: skipped`) at receive time and again at send time if a duplicate reached the queue.

---

## v0.3.3 — Semantic Decode of Camera Replies

**Intent:** turn device-side VISCA **replies** into structured meaning beyond ACK / completion / hex on telemetry, and publish a **per-bus controller status** topic alongside events.

### Semantic Decode of Camera Replies Checklist

- [x] **Semantic decode of device replies** — `device/<slug>/telemetry` and `lastReply` on **`device/<slug>/status`** include optional **`decode`** (replyClass ack/completion/error/data, **socket**, **payload** byte array, **code** for errors). Generic VISCA framing (90..96, 4x/5x/60); not model-specific inquiry tables (future refinement).
- [x] **`controller/<bus>/status`** — JSON with **`lastController`** (last semantic or raw controller event summary) and **`lastDeviceReply`** (last device reply summary + **decode** when present). Published after each **`controller/<bus>/event`** and after each device reply on that bus.

---

## v0.4.0 — YAML Conversion

**Shipped:** single **`hambridge.yaml`** ( **`bridge`**, **`device_mappings`**, **`buses`**, **`devices`**, **`evdev`** ) plus VISCA mapping **`.yaml`**, with discovery as in **`docs/user/ConfigurationGuide.md`** (`--config`, **`BRIDGE_CONFIG`**, **`.local/etc/config/`**, **`/etc/hambridge/`**). **`--devices`** / **`BRIDGE_DEVICES`** removed.

### YAML Conversion Checklist

- [x] Load **`bridge`** subtree via minimal YAML → JSON; **`BRIDGE_*`** env overrides unchanged in spirit.
- [x] **`device_mappings.visca`**, **`buses`** with **`transport_configuration`** (serial); UDP buses rejected with a clear error until implemented.
- [x] VISCA mapping file **`.yaml`/`.yml`** supported (JSON mapping path still accepted).
- [x] Single **`--config`** path for both process and device configuration.

## v0.4.1 — Bus Enrichment

**Shipped:** `buses.<id>` uses `transport`, `transport_configuration`, `protocol`, and optional `protocol_config` (validated as an object when present). `protocol` is `visca` only for now.

## v0.4.2 — Devices → Endpoints

**Shipped:** `hambridge.yaml` uses **`endpoints[]`** with a required **`match`** stanza. VISCA devices are
**`match.endpoint_type: device`** and use **`match.bus`** + **`match.deviceID`** for routing.

### Devices → Endpoints Checklist

- [x] Replace `devices:` with `endpoints:` in config and loader.
- [x] Parse `match.endpoint_type`, `match.bus`, and `match.deviceID` (1..7) for VISCA devices.

## v0.4.3 — Evdev → Endpoints

- The "evdev" section of the config file should be rolled into the "endpoints" section, and each input should become a "controller" device.  
- The match section should allow a "deviceNode" option, but there should be other ways of matching too.  

## v0.4.4 — VISCA over UDP

**Intent:** add VISCA over UDP transport so HaMBridge can talk to devices that expose VISCA over IP (e.g. as supported by Bitfocus Companion’s Sony VISCA connection: `https://bitfocus.io/connections/sony-visca`).

### VISCA over UDP Checklist

- [ ] **UDP transport** — send/receive VISCA frames over UDP (socket lifecycle, timeouts, and retry semantics).
- [ ] **Per-device UDP endpoints** — allow selecting UDP host/port per device in **`hambridge.yaml`** alongside serial buses.
- [ ] **Telemetry/status parity** — keep `device/<slug>/telemetry`, `device/<slug>/status`, and `device/<slug>/commandAck` semantics consistent across serial vs UDP transports.

### VISCA over UDP — Open Questions

**Addresses (UDP)**

- [ ] **Single socket vs per-device ports** — Must every device share the bound `bindPort`, or do we support per-device listener ports?
- [ ] **Reply routing** — When multiple devices share one UDP socket, how do replies map to the correct `device/<slug>` (VISCA address byte only, or IP+port correlation, or dedicated sockets)?
- [ ] **NAT / asymmetric paths** — How do we behave when outbound and return paths differ (e.g. NAT, Docker bridge networks)?

**Device control over UDP**

- [ ] **ACK / completion over lossy UDP** — Same `ackTimeoutMs` / retry semantics as serial, or UDP-specific defaults (e.g. shorter timeouts, different retry cap)?
- [ ] **Datagram boundaries vs command boundaries** — Confirm one VISCA frame per sent datagram always; any exception for large payloads?
- [ ] **Half-duplex / collision** — Is there any scenario where the bridge must not send while expecting a reply on the same socket (shared medium semantics)?
- [ ] **MTU / fragmentation** — Do we forbid IP fragmentation (stay under PMTU), or detect and log?

## v0.5.0 — Test Suite

Does Free Pascal have a testing suite?  If so, fill in some information here about using it


## v0.5.1 — TLS Configuration (Optional)

**Intent:** implement full MQTT TLS configuration while keeping TLS **optional**.

### TLS Configuration Checklist

- [ ] **Full TLS material** — CA bundle, client cert/key, and peer verification controls (beyond `tls: true` + OS default trust).
- [ ] **Operational docs** — document common TLS deployment patterns and failure modes.

---

## v0.5.2 — GitHub Actions

Set up GitHub Actions that will do a release.  A release should consist of packages for a) Redhat and b) Raspbian

## v0.5.3 — Security Scan

See if there's a skill for doing a security scan, then use that.  

## v1.0.0 — Release!

When the Github Release actions fully work, release v1.0.0

---

## Command Router & Scheduler (Plan §3.2)

- [ ] **Rate limiting / backpressure** — Beyond fixed **max queue depth** and **inter-command gap**; no explicit RS-485 saturation policy as described in the plan.

ACK / completion timing and **`scheduler.ackTimeoutMs`** are tracked under **v0.3.1** above. **Coalescing** and **`scheduler.coalesce`** are implemented under **v0.3.2** above.

## VISCA Protocol Layer (Plan §3.3)

- [ ] **Nibble / exotic template slot encodings** — Still deferred (not in v0.3.1 multi-byte scope).

**Decode / retry / mapping / TX:** semantic decode of camera replies and **`controller/<bus>/status`** → **v0.3.3** above; retry, **multi-byte slots**, and **buffered serial writes** → **v0.3.1** above.

## Serial Layer (Plan §3.4, §7)

*(No separate backlog lines here — **buffered writes**, half-duplex, and **serial recovery** are under **v0.3.1** above.)*

## MQTT & `bridge` Subtree (Plan §3.0–3.1, §7)

- [ ] **`log.format`: `json`** — Still reserved; operational logging is effectively **text** only.
- [ ] **Full TLS configuration** — tracked under **v0.3.4** above.
- [ ] **Broader QoS usage** — Generic `PublishJson` uses **QoS 0** for evdev / VISCA-side publishes; not a full “QoS 0 and 1 everywhere” productization.

MQTT acknowledgements for **bridge-originated VISCA** are tracked under **v0.3.1** above.

## Device List in `hambridge.yaml` (Plan §3.1 Example)

`scheduler.ackTimeoutMs` → **v0.3.1**. **`scheduler.coalesce`** → **v0.3.2**.

## Build & Install (Plan §5.1)

- [ ] **`make install`** — Optional install to `/usr/local/bin` + example configs under **`/etc/hambridge/config/`** — not in the `Makefile`.

## Documentation

- [ ] **Strict frozen MQTT ↔ VISCA mapping spec** — Standalone artifact with exact payloads for every supported command (beyond examples in the plan and the VISCA mapping YAML).

## Evdev (Plan §3.1.2, Minor)

- [ ] **Input discovery by name or sysfs** — Still path-only; plan allows optional discovery later.
- [ ] **Surface kernel event timestamp** in JSON — Today `ts` is bridge clock; kernel `input_event` time not exposed separately.


# Future versions:
## v0.4.4 — VISCA Controllers → Endpoints

Allow defining a visca controller on serial as well (in the config file)

