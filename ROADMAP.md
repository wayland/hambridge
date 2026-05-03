# HaMBridge roadmap

This file lists **planned or deferred work** compared to [`Visca-MQTT-bridge-Plan.md`](Visca-MQTT-bridge-Plan.md) and the current codebase. **Shipped releases** are recorded in [`CHANGELOG.md`](CHANGELOG.md).

---

## v0.3.1 — Real-bus discipline and transport hardening

**Intent:** tighten real-bus behaviour (timing, failures, feedback) on top of v0.3’s VISCA → MQTT surface.

**Design note — queues:** The bridge uses **per-bus** command FIFOs with an inter-command gap. That is **intentional** (and preferred to strict per-device serialization for this design); it is not listed as a gap.

**Reference — max queue depth:** Each VISCA device defaults to **`maxQueueDepth` = 50** queued commands (`devices.json` → `devices[].scheduler.maxQueueDepth`, clamped to **≥ 1**). For each serial bus, the router uses the **largest** `maxQueueDepth` among devices on that bus as the cap for the **shared** bus queue (see `commandrouter` / `devicesconfig`).

### v0.3.1 checklist

- [ ] **ACK / completion discipline** — Parse `scheduler.ackTimeoutMs` (and related rules); after each bridge-originated command, wait for VISCA ACK / completion or **timeout** before sending the next command for that device (or bus policy TBD).
- [ ] **Serial reconnection / recovery** — Reopen the TTY on `ENODEV` / hard I/O errors with backoff; today ports are opened once at startup.
- [ ] **MQTT acknowledgements after bridge-originated VISCA TX** — Plan §4 optional path: publish an ack/nack (or completion) to MQTT tied to commands the bridge sent.
- [ ] **RS-485 half-duplex / direction / collisions** — Driver-level `TIOCSRS485` or DE/RE control, documented behaviour when a **controller** and the **bridge** share the same bus; not multi-master software arbitration unless explicitly scoped later.
- [ ] **Retry failed VISCA commands** — Policy TBD (counts, backoff, which errors are retryable); ties naturally to ACK / completion and MQTT nack/ack behaviour.
- [ ] **Multi-byte template slots** — Extend `visca-mapping.json` / encoder so a template slot can expand to **more than one** wire byte from MQTT JSON or `variables` (plan §3.3 today is one byte per slot). **Nibble-packed and other exotic slot encodings** stay deferred beyond v0.3.1.
- [ ] **Buffered serial writes** — Handle **partial `write()`**, `EAGAIN`, and/or a small TX queue so outbound VISCA bytes are not dropped under load (plan §3.4 “buffered writes”).

---

## v0.3.2 — Coalescing and device state cache

**Intent:** scheduling and **state** above raw bytes-on-the-wire (without replacing `visca-mapping.json` as the way new commands are defined).

### v0.3.2 checklist

- [ ] **Coalescing for continuous controls** (`pan` / `tilt` / `zoom`) — Drop superseded high-rate commands; parse and honour `devices.json` **`scheduler.coalesce`**.
- [ ] **Device state cache** (plan §3.5) — Pan, tilt, zoom, preset (and related) as first-class cached fields where inquiries or events supply them.
- [ ] **Use cache to skip redundant VISCA** — Avoid re-sending when state already matches intent.

---

## v0.3.3 — Semantic decode of camera replies

**Intent:** turn device-side VISCA **replies** into structured meaning beyond ACK / completion / hex on telemetry.

### v0.3.3 checklist

- [ ] **Semantic decode of device replies** — Inquiry results, error payloads, pan/tilt/zoom where the wire format allows it; richer JSON on `device/<slug>/telemetry` (and/or status) than today’s `kind` + `viscaHex`.

---

## Command router & scheduler (plan §3.2)

- [ ] **Rate limiting / backpressure** — Beyond fixed **max queue depth** and **inter-command gap**; no explicit RS-485 saturation policy as described in the plan.

ACK / completion timing and **`scheduler.ackTimeoutMs`** are tracked under **v0.3.1** above. **Coalescing** and **`scheduler.coalesce`** are under **v0.3.2** above.

## VISCA protocol layer (plan §3.3)

- [ ] **Nibble / exotic template slot encodings** — Still deferred (not in v0.3.1 multi-byte scope).

**Decode / retry / mapping / TX:** semantic decode of camera replies → **v0.3.3** above; retry, **multi-byte slots**, and **buffered serial writes** → **v0.3.1** above.

## Serial layer (plan §3.4, §7)

*(No separate backlog lines here — **buffered writes**, half-duplex, and **serial recovery** are under **v0.3.1** above.)*

## MQTT & `bridge.json` (plan §3.0–3.1, §7)

- [ ] **`controller/<bus>/status`** — Suggested in plan alongside `controller/<bus>/event`; not published today.
- [ ] **`log.format`: `json`** — Still reserved; operational logging is effectively **text** only.
- [ ] **Full TLS configuration** — CA bundle, client cert/key, `verifyPeer`, etc.; beyond **`tls: true`** + OS default trust.
- [ ] **Broader QoS usage** — Generic `PublishJson` uses **QoS 0** for evdev / VISCA-side publishes; not a full “QoS 0 and 1 everywhere” productization.

MQTT acknowledgements for **bridge-originated VISCA** are tracked under **v0.3.1** above.

## `devices.json` (plan §3.1 example)

`scheduler.ackTimeoutMs` → **v0.3.1**. **`scheduler.coalesce`** → **v0.3.2**.

## Build & install (plan §5.1)

- [ ] **`make install`** — Optional install to `/usr/local/bin` + example configs under `/etc/hambridge/` — not in the `Makefile`.

## Documentation

- [ ] **Strict frozen MQTT ↔ VISCA mapping spec** — Standalone artifact with exact payloads for every supported command (beyond examples in the plan and mapping JSON).

## Evdev (plan §3.1.2, minor)

- [ ] **Input discovery by name or sysfs** — Still path-only; plan allows optional discovery later.
- [ ] **Surface kernel event timestamp** in JSON — Today `ts` is bridge clock; kernel `input_event` time not exposed separately.
