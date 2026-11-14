#!/usr/bin/env bash
set -euo pipefail
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
script=$(cd "$(dirname "$0")/.." && pwd)/scripts/staged-build-gsi.sh
mkdir -p "$root/occupied"; echo keep > "$root/occupied/file"
if BUILD_ROOT="$root/occupied" INSTALL_DEPS=0 MIN_FREE_GIB=0 bash "$script" >"$root/log" 2>&1; then
  echo 'Accepted an unowned root' >&2; exit 1
fi
grep -q 'Refusing nonempty unowned' "$root/log"
if BUILD_ROOT="$root/build" INSTALL_DEPS=0 MIN_FREE_GIB=999999 bash "$script" >"$root/log" 2>&1; then
  echo 'Accepted insufficient free space' >&2; exit 1
fi
grep -q 'Need 999999 GiB free' "$root/log"
[[ ! -e "$root/build/audit/setup.done" && -e "$root/build/audit/setup.active" ]]
[[ $(git -C "$root/build/audit" log --oneline | wc -l) -eq 2 ]]
if BUILD_ROOT="$root/build" INSTALL_DEPS=0 MIN_FREE_GIB=0 bash "$script" >"$root/log" 2>&1; then
  echo 'Repeated an unsafe setup' >&2; exit 1
fi
grep -q 'Interrupted setup' "$root/log"
if BUILD_ROOT=relative INSTALL_DEPS=0 MIN_FREE_GIB=0 bash "$script" >"$root/log" 2>&1; then
  echo 'Accepted a relative root' >&2; exit 1
fi
if BUILD_ROOT="$root/empty" INSTALL_DEPS=0 MIN_FREE_GIB=0 STAGE=sync bash "$script" >"$root/log" 2>&1; then
  echo 'Accepted sync without setup' >&2; exit 1
fi
grep -q 'Missing prerequisite checkpoint: setup' "$root/log"
if BUILD_ROOT="$root/invalid" REPO_DEPTH=2 bash "$script" >"$root/log" 2>&1; then
  echo 'Accepted invalid REPO_DEPTH' >&2; exit 1
fi
grep -q 'REPO_DEPTH must be 0 or 1' "$root/log"
if BUILD_ROOT="$root/build" REPO_DEPTH=1 INSTALL_DEPS=0 MIN_FREE_GIB=0 bash "$script" >"$root/log" 2>&1; then
  echo 'Accepted a changed workspace depth' >&2; exit 1
fi
grep -q 'Build root version mismatch' "$root/log"
if BUILD_ROOT="$root/invalid2" REPO_DEPTH=1 REPO_PARTIAL=1 bash "$script" >"$root/log" 2>&1; then
  echo 'Accepted conflicting clone options' >&2; exit 1
fi
grep -q 'REPO_PARTIAL and REPO_DEPTH cannot both be 1' "$root/log"
if BUILD_ROOT="$root/invalid3" REPO_PARTIAL=bad bash "$script" >"$root/log" 2>&1; then
  echo 'Accepted invalid REPO_PARTIAL' >&2; exit 1
fi
grep -q 'REPO_PARTIAL must be 0 or 1' "$root/log"
echo 'Staged safety checks passed'
