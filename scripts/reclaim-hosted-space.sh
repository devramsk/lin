#!/usr/bin/env bash
# Optional, destructive cleanup ONLY for a disposable GitHub-hosted VM.
set -Eeuo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted && ${RUNNER_OS:-} == Linux ]] || {
  echo 'Refusing cleanup outside a GitHub-hosted Linux runner' >&2; exit 1;
}
[[ -n ${GITHUB_WORKSPACE:-} && -n ${RUNNER_TEMP:-} ]] || { echo 'Missing runner paths' >&2; exit 1; }
workspace=$(realpath -e "$GITHUB_WORKSPACE")
temp=$(realpath -e "$RUNNER_TEMP")
echo 'Disk space before cleanup:'
df -h "$temp"
# Keep tool cache, runner, Docker, swap, Java and every Android source checkout.
for path in /usr/local/lib/android /usr/share/dotnet /usr/local/.ghcup /opt/ghc /usr/local/share/powershell; do
  [[ -e $path ]] || continue
  [[ -d $path && ! -L $path && $(realpath -e "$path") == "$path" ]] || { echo "Skipping noncanonical path: $path"; continue; }
  if findmnt -rn --mountpoint "$path" >/dev/null; then echo "Skipping mountpoint: $path"; continue; fi
  case "$workspace/" in "$path/"*) echo "Refusing workspace under $path" >&2; exit 1;; esac
  case "$temp/" in "$path/"*) echo "Refusing runner temp under $path" >&2; exit 1;; esac
  echo "Removing preinstalled tool directory: $path"
  sudo -n rm -rf --one-file-system -- "$path"
done
echo 'Disk space after cleanup:'
df -h "$temp"
