#!/usr/bin/env bash
# Stop a resource-heavy subprocess before it fills the runner's filesystem.
set -Eeuo pipefail
[[ $# -ge 3 ]] || { echo 'Usage: run-with-disk-guard.sh ROOT LOG COMMAND...' >&2; exit 2; }
root=$1 log=$2; shift 2
reserve=${DISK_RESERVE_GIB:-3}
interval=${DISK_GUARD_INTERVAL:-5}
[[ $reserve =~ ^[0-9]+$ && $interval =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid disk guard configuration' >&2; exit 2; }
[[ -d $root && -d $(dirname "$log") ]] || { echo 'Disk guard paths missing' >&2; exit 2; }
fifo_dir=$(mktemp -d "${TMPDIR:-/tmp}/lineage-disk-guard.XXXXXXXX")
fifo="$fifo_dir/output"
mkfifo "$fifo"
# FIFO keeps the command exit code and the log writer exit code separate.
tee -a "$log" < "$fifo" &
tee_pid=$!
setsid bash -e -o pipefail -c '"$@"' _ "$@" > "$fifo" 2>&1 &
child=$!
(
  exec 9>&-
  while kill -0 "$child" 2>/dev/null; do
    available=$(df -Pk "$root" | awk 'NR==2 {print $4}') || exit 0
    if [[ $available =~ ^[0-9]+$ ]] && (( available < reserve * 1048576 )); then
      echo "Disk guard: stopping stage; available ${available} KiB, reserve ${reserve} GiB" >&2
      kill -TERM -- "-$child" 2>/dev/null || true
      sleep 5
      kill -KILL -- "-$child" 2>/dev/null || true
      exit 0
    fi
    sleep "$interval"
  done
) &
watcher=$!
cleanup() {
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  rm -rf "$fifo_dir"
}
trap cleanup EXIT
set +e
wait "$child"; rc=$?
wait "$tee_pid"; tee_rc=$?
set -e
(( tee_rc == 0 )) || rc=1
exit "$rc"
