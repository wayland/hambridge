# CI and release helper scripts

Used by **`.github/workflows/ci.yml`** and **`.github/workflows/release.yml`**. See **`docs/developers/Specification.md`** §10.6 and **`release-pins.json`**.

| Script | Purpose |
|--------|---------|
| `verify-release-pins.sh` | `release-pins.json` ↔ `Makefile` / `hambridge.spec` MQTT zip pin |
| `verify-release-tag.sh` | Tag `vX.Y.Z` ↔ `AppVersion`, `RPM_VER`, spec, debian changelog |
| `extract-changelog-section.sh` | Body for GitHub Release notes from `CHANGELOG.md` |

Local examples:

```bash
./scripts/ci/verify-release-pins.sh
RELEASE_TAG=v0.5.2 ./scripts/ci/verify-release-tag.sh
```
