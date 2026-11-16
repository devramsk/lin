#!/usr/bin/env bash
# Install dependencies on Ubuntu 22.04 or 24.04; requires noninteractive sudo.
set -Eeuo pipefail
. /etc/os-release
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
package_list=$(bash "$script_dir/build-dependencies.sh" "${ID:-}" "${VERSION_ID:-}")
mapfile -t packages <<< "$package_list"
(( ${#packages[@]} > 0 )) || { echo 'Empty package list' >&2; exit 1; }
if ! sudo -n true 2>/dev/null; then
  echo 'Passwordless sudo is required (sudo -n). Either:' >&2
  echo '  1) run "sudo -v" to authenticate first, or' >&2
  echo '  2) configure this user with NOPASSWD sudo for apt, or' >&2
  echo '  3) install the packages manually and re-run with INSTALL_DEPS=0.' >&2
  exit 1
fi
sudo -n apt-get update
sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
