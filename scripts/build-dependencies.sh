#!/usr/bin/env bash
# Output the LineageOS 21 build package names, one per line.
set -Eeuo pipefail
[[ $# == 2 ]] || { echo 'Usage: build-dependencies.sh DISTRO VERSION' >&2; exit 2; }
[[ $1 == ubuntu && ( $2 == 22.04 || $2 == 24.04 ) ]] || {
  echo 'Automatic package installation supports Ubuntu 22.04 and 24.04 only' >&2; exit 1;
}
packages=(
  bc bison build-essential ccache curl erofs-utils flex g++-multilib gcc-multilib
  git git-lfs gnupg gperf imagemagick kmod protobuf-compiler python3-protobuf
  lib32readline-dev lib32z1-dev libdw-dev libelf-dev libgnutls28-dev lz4
  libsdl1.2-dev libssl-dev libxml2 libxml2-utils lzop pngcrush rsync schedtool
  squashfs-tools xsltproc xxd zip unzip zlib1g-dev python-is-python3 ca-certificates patch
)
# Older ncurses compatibility packages are not needed for LineageOS 21 on 24.04.
if [[ $2 == 22.04 ]]; then
  packages+=(lib32ncurses5-dev libncurses5 libncurses5-dev)
fi
printf '%s\n' "${packages[@]}"
