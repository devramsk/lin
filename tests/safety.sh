#!/usr/bin/env bash
# Safety contract of scripts/build-gsi.sh:
#   * unowned non-empty BUILD_ROOT is refused;
#   * a root created by a previous run of this script (source/ + audit/) is
#     adopted and completed stages are skipped (no more "Refusing to reuse");
#   * the old 400 GiB minimum free-space gate is gone (disk guard remains).
set -euo pipefail
export ALLOW_NON_2404=1   # test host may not be Ubuntu 24.04
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
script=$(cd "$(dirname "$0")/.." && pwd)/scripts/build-gsi.sh

# 1. Unowned non-empty root is refused.
mkdir -p "$root/existing/source"
if BUILD_ROOT="$root/existing" INSTALL_DEPS=0 bash "$script" >"$root/log" 2>&1; then
  echo 'Existing unowned source unexpectedly accepted' >&2; exit 1
fi
grep -q 'Refusing to reuse' "$root/log"

# 2. A root with evidence of a previous run is adopted instead of refused.
legacy="$root/legacy"
mkdir -p "$legacy/source" "$legacy/audit"
echo 'previous environment dump' > "$legacy/audit/environment.txt"
BUILD_ROOT="$legacy" INSTALL_DEPS=0 STOP_AFTER=deps bash "$script" >"$root/log2" 2>&1
grep -q 'Adopting existing build root' "$root/log2"
grep -q "Stage 'deps': OK" "$root/log2"
! grep -q 'Refusing to reuse' "$root/log2"

# 3. Fresh root proceeds past the (removed) free-space gate.
BUILD_ROOT="$root/fresh" INSTALL_DEPS=0 STOP_AFTER=deps bash "$script" >"$root/log3" 2>&1
grep -q "Stage 'deps': OK" "$root/log3"

# 4. There is no MIN_FREE_GIB gate anymore: the variable is ignored.
BUILD_ROOT="$root/fresh2" INSTALL_DEPS=0 STOP_AFTER=deps MIN_FREE_GIB=999999 bash "$script" >"$root/log4" 2>&1
grep -q "Stage 'deps': OK" "$root/log4"

echo 'Safety checks passed'
