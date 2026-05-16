# Patches for build-time dependencies

## `fpc-mqtt-client-1.2-tls-verify-before-connect.patch`

**Target:** `prof7bit/fpc-mqtt-client` tag **1.2** (`mqtt/mqtt.pas` inside the release zip pinned in the root `Makefile`).

**Why:** Upstream calls `OnVerifySSL` after the SSL socket is already connecting. HaMBridge must configure trust anchors, `verifyPeer`, SNI hostname, and cipher list on the handler **before** the TLS handshake (see `bridge.mqtt.tls` in `docs/developers/Specification.md`).

**What it does:**

- Extends `TMQTTSocket.CreateSSL` to accept `OnVerify` + `Mqtt` and invoke `OnVerifySSL` before `Inherited Create` / `Connect`.
- Moves verify handling out of post-connect `ConnectSocket` into that pre-connect path; maps rejection to `mqeSSLVerifyError`.

**When bumping `FPC_MQTT_TAG`:** unzip the new release, try `patch -p1` from the extract root; if it fails, refresh this diff against the new `mqtt/mqtt.pas` and rename or version the patch file if the tag changes.

**Apply (manual):** from `build/deps/fpc-mqtt-client-<tag>/`:

```bash
patch -p1 < ../../patches/fpc-mqtt-client-1.2-tls-verify-before-connect.patch
```

The `Makefile` applies this automatically after each unzip.
