#!/usr/bin/env bash
set -euo pipefail
script=$(cd "$(dirname "$0")/.." && pwd)/scripts/build-dependencies.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
bash "$script" ubuntu 22.04 > "$tmp/22"
bash "$script" ubuntu 24.04 > "$tmp/24"
for package in git git-lfs python-is-python3 libxml2 lib32readline-dev; do
  grep -Fxq "$package" "$tmp/22"
  grep -Fxq "$package" "$tmp/24"
done
for package in lib32ncurses5-dev libncurses5 libncurses5-dev; do
  grep -Fxq "$package" "$tmp/22"
  if grep -Fxq "$package" "$tmp/24"; then echo "Unsupported legacy package on 24.04: $package" >&2; exit 1; fi
done
if bash "$script" debian 12 >/dev/null 2>&1 || bash "$script" ubuntu 26.04 >/dev/null 2>&1 || bash "$script" ubuntu >/dev/null 2>&1; then
  echo 'Unsupported distribution unexpectedly accepted' >&2; exit 1
fi
for list in "$tmp/22" "$tmp/24"; do
  [[ -z $(sort "$list" | uniq -d) ]] || { echo 'Duplicate package' >&2; exit 1; }
done
echo 'Dependency selection checks passed'
