#!/usr/bin/env bash
# Print CHANGELOG.md body for ## [X.Y.Z] (first section only).
set -euo pipefail
ver="${1:-}"
if [ -z "$ver" ]; then
  echo 'usage: extract-changelog-section.sh X.Y.Z' >&2
  exit 1
fi
root="$(cd "$(dirname "$0")/../.." && pwd)"
awk -v ver="$ver" '
  $0 ~ "^## \\[" ver "\\]" { found=1; next }
  found && /^## \[/ { exit }
  found { print }
' "$root/CHANGELOG.md"
