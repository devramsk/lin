#!/usr/bin/env bash
set -euo pipefail
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
script=$(cd "$(dirname "$0")/.." && pwd)/scripts/build-gsi.sh
mkdir -p "$root/existing/source"
if BUILD_ROOT="$root/existing" INSTALL_DEPS=0 MIN_FREE_GIB=0 bash "$script" >"$root/log" 2>&1; then
  echo 'Existing source unexpectedly accepted' >&2; exit 1
fi
grep -q 'Refusing to reuse' "$root/log"
if BUILD_ROOT="$root/space" INSTALL_DEPS=0 MIN_FREE_GIB=999999 bash "$script" >"$root/log" 2>&1; then
  echo 'Insufficient space unexpectedly accepted' >&2; exit 1
fi
grep -q 'GiB free' "$root/log"
echo 'Safety checks passed'
