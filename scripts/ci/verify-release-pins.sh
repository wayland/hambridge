#!/usr/bin/env bash
# Assert release-pins.json matches Makefile MQTT pin (§10.6.6).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
command -v jq >/dev/null 2>&1 || { echo 'verify-release-pins: jq required' >&2; exit 1; }

pins_tag="$(jq -r '.fpc_mqtt_tag' release-pins.json)"
pins_sha="$(jq -r '.fpc_mqtt_sha256' release-pins.json)"
mk_tag="$(sed -n 's/^FPC_MQTT_TAG := //p' Makefile | head -1 | tr -d ' ')"
mk_sha="$(sed -n 's/^FPC_MQTT_SHA256 := //p' Makefile | head -1 | tr -d ' ')"

if [ "$pins_tag" != "$mk_tag" ]; then
  echo "release-pins.json fpc_mqtt_tag=$pins_tag != Makefile FPC_MQTT_TAG=$mk_tag" >&2
  exit 1
fi
if [ "$pins_sha" != "$mk_sha" ]; then
  echo "release-pins.json fpc_mqtt_sha256 mismatch Makefile FPC_MQTT_SHA256" >&2
  exit 1
fi

spec_tag="$(sed -n 's/^%global fpc_mqtt_tag[[:space:]]*//p' packaging/Redhat/hambridge.spec | head -1 | tr -d ' ')"
spec_sha="$(sed -n 's/^%global fpc_mqtt_sha256[[:space:]]*//p' packaging/Redhat/hambridge.spec | head -1 | tr -d ' ')"
if [ "$pins_tag" != "$spec_tag" ] || [ "$pins_sha" != "$spec_sha" ]; then
  echo "release-pins.json MQTT pin mismatch packaging/Redhat/hambridge.spec" >&2
  exit 1
fi

echo "release-pins.json matches Makefile and hambridge.spec"
