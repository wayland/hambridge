#!/usr/bin/env bash
# Fail if git tag vX.Y.Z does not match AppVersion / RPM_VER / spec / debian changelog (§10.6.5).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

tag="${GITHUB_REF_NAME:-${RELEASE_TAG:-}}"
if [ -z "$tag" ]; then
  echo 'verify-release-tag: set GITHUB_REF_NAME or RELEASE_TAG (e.g. v0.5.2)' >&2
  exit 1
fi
case "$tag" in
  v*.*.*) ;;
  *)
    echo "verify-release-tag: tag must look like vX.Y.Z (got $tag)" >&2
    exit 1
    ;;
esac
ver="${tag#v}"

app="$(sed -n "s/^[[:space:]]*AppVersion[[:space:]]*=[[:space:]]*'\\([^']*\\)'.*/\\1/p" src/hambridge.lpr | head -1)"
rpm_ver="$(sed -n 's/^RPM_VER := //p' Makefile | head -1 | tr -d ' ')"
spec_ver="$(sed -n 's/^Version:[[:space:]]*//p' packaging/Redhat/hambridge.spec | head -1 | tr -d ' ')"
deb_head="$(head -1 packaging/debian/changelog | sed -n 's/^hambridge (\([^)]*\)).*/\1/p')"
deb_ver="${deb_head%%-*}"

fail=0
check() {
  local name="$1" want="$2" got="$3"
  if [ "$want" != "$got" ]; then
    echo "verify-release-tag: $name want $want got $got" >&2
    fail=1
  fi
}

check 'AppVersion' "$ver" "$app"
check 'RPM_VER' "$ver" "$rpm_ver"
check 'hambridge.spec Version' "$ver" "$spec_ver"
check 'debian/changelog' "$ver" "$deb_ver"

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "tag $tag matches version $ver in tree"
