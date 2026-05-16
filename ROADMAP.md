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

**Shipped:** Linux input is configured via an **`evdev` bus** (`transport: none`, `protocol: evdev`,
`protocol_config.enabled: true`) plus **controller endpoints** under **`endpoints[]`** with
`match.endpoint_type: controller`, `match.protocol: evdev`, and `match.deviceNode`.

### Evdev → Endpoints Checklist

- [x] Add `buses.<id>` entries with `protocol: evdev` and `transport: none`.
- [x] Load each input as an endpoint (`match.protocol: evdev`) and publish to `controller/<slug>/event`.
- [x] Validate evdev buses require `protocol_config.enabled: true`.

## v0.4.4 — VISCA over UDP

**Shipped:** VISCA frames can be sent/received over UDP using **`transport: udp`** + **`protocol: visca`** buses,
with **`endpoints[]`** selecting per-device **`udpHost`/`udpPort`** (or bus defaults) and strict reply correlation
per **`Specification.md` §3.4.

### VISCA over UDP Checklist

- [x] **UDP transport** — send/receive VISCA frames over UDP (socket lifecycle, timeouts, and retry semantics).
- [x] **Per-device UDP endpoints** — allow selecting UDP host/port per device in **`hambridge.yaml`** alongside serial buses.
- [x] **Telemetry/status parity** — keep `device/<slug>/telemetry`, `device/<slug>/status`, and `device/<slug>/commandAck` semantics consistent across serial vs UDP transports.

### VISCA over UDP — Decisions (documented in `Specification.md` §3.4)

**Addresses + sockets (UDP)**

- [x] **Single socket vs per-device ports** — both are supported: endpoint-level `udpHost`/`udpPort` overrides bus defaults; multiple UDP buses allowed (distinct `bindHost`/`bindPort`).
- [x] **Reply routing** — per extracted frame, attribute by `(match.bus, remoteHost, remotePort, deviceID)` with strict must-match against the endpoint’s resolved `udpHost`/`udpPort`.
- [x] **NAT / asymmetric paths** — strict **must-match**; non-matching return traffic is not correlated (future relaxation would be a spec change).

**Device control over UDP**

- [x] **ACK / completion / retry** — use the same per-endpoint `scheduler` fields as serial (`ackTimeoutMs`, `commandRetryMax`, `retryBackoffMs`, …).
- [x] **Datagram boundaries vs frames** — conservative send: one VISCA frame per datagram; liberal receive: accept one-or-more frames per datagram (no cross-datagram reassembly by default).
- [x] **MTU / fragmentation** — keep outbound frames within a reasonable upper bound (spec suggests ≤ 1024 bytes); drop/handle oversized datagrams safely on receive.

## v0.5.0 — Test Suite

**Shipped:** FPCUnit + **`make test`** (see **`docs/developers/Specification.md`** §10 and **`tests/`**).

### Test Suite Checklist

- [x] **`make test`** — builds **`./build/hambridge_tests`** and runs all registered tests (plain output).
- [x] **Fixtures** — **`tests/fixtures/`** YAML for config validation and **`visca-min.yaml`** for mapping golden I/O.
- [x] **Config / validation coverage** — duplicate device slug; duplicate UDP `(host, port, deviceID)`; UDP `(host, port)` reused across buses; UDP bus without controller; two VISCA controllers on one UDP bus.
- [x] **VISCA mapping coverage** — encode **preset/call** and **power/on**; **ViscaPacketToHex**; decode controller **power/on** wire bytes.

## v0.5.1 — TLS Configuration (Optional)

**Shipped:** full **`bridge.mqtt.tls`** object + boolean shorthand; CA file/path, client PEM + key, **`verifyPeer`**, **`serverName`** (cert verify + SNI), **`ciphers`**; build-time patch on **`fpc-mqtt-client`** so trust is applied before connect (see **`patches/README.md`**). **`minVersion`** / **`maxVersion`** parsed but not enforced (warn once — use **ciphers** / OpenSSL defaults).

### TLS Configuration Checklist

- [x] **Full TLS material** — CA bundle (`caFile` / `caPath`), client cert/key, **`verifyPeer`**, SNI via **`serverName`**, **`ciphers`** (`Specification.md` §3.0).
- [x] **Operational docs** — **`docs/user/ConfigurationGuide.md`** (MQTT TLS section) + **`CHANGELOG.md`** / **`Specification.md`**.

---

## v0.5.2 — GitHub Actions

**Shipped:** `.github/workflows/ci.yml` and `.github/workflows/release.yml`; `release-pins.json`; `scripts/ci/` helpers. See **`WORKFLOWS.md`** and **`docs/developers/Specification.md`** §10.6.

### GitHub Actions Checklist

- [x] **PR CI** — `build-and-test` (`make`, `make test`) on `ubuntu-24.04`; `verify-release-pins` after.
- [x] **Release on tag** — `verify-tag` vs `AppVersion` / `RPM_VER` / spec / debian changelog.
- [x] **Artifacts** — `hambridge-{ver}-linux-x86_64.tar.gz`, `SHA256SUMS`, `.deb` (amd64 + arm64), Fedora `.rpm`.
- [x] **GitHub Release** — attach assets; body from `CHANGELOG.md` section.

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
- [x] **Full TLS configuration** — **v0.5.1** above (`bridge.mqtt.tls`).
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

