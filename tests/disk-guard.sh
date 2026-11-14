#!/usr/bin/env bash
set -euo pipefail
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
script=$(cd "$(dirname "$0")/.." && pwd)/scripts/run-with-disk-guard.sh
DISK_RESERVE_GIB=0 DISK_GUARD_INTERVAL=1 bash "$script" "$tmp" "$tmp/success.log" bash -c 'echo stage-ok'
grep -q stage-ok "$tmp/success.log"
if DISK_RESERVE_GIB=0 DISK_GUARD_INTERVAL=1 bash "$script" "$tmp" "$tmp/failure.log" bash -c 'exit 42'; then
  echo 'Guard hid command failure' >&2; exit 1
else
  rc=$?
  [[ $rc == 42 ]] || { echo "Unexpected exit $rc" >&2; exit 1; }
fi
if DISK_RESERVE_GIB=999999 DISK_GUARD_INTERVAL=1 bash "$script" "$tmp" "$tmp/guard.log" bash -c 'sleep 30' >"$tmp/guard-output" 2>&1; then
  echo 'Disk guard did not interrupt the stage' >&2; exit 1
fi
grep -q 'Disk guard: stopping stage' "$tmp/guard-output"
echo 'Disk guard checks passed'
