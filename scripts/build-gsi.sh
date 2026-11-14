#!/usr/bin/env bash
# Fresh, unsigned LineageOS 21 pre-QPR2 Light GSI build. Run on a dedicated host.
set -Eeuo pipefail

BUILD_COMMIT=301f406f6d0f213798afffb3be5c367cb8d20f2d
PATCH_COMMIT=01a11cee86eeef3fffa744c8efa37985d28312fc
ROOT=${BUILD_ROOT:-"$PWD/lineage-work"}
INSTALL_DEPS=${INSTALL_DEPS:-1}
MIN_FREE_GIB=${MIN_FREE_GIB:-400}
[[ $MIN_FREE_GIB =~ ^[0-9]+$ ]] || { echo 'MIN_FREE_GIB must be an integer' >&2; exit 1; }
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo 'Linux x86_64 required' >&2; exit 1; }
mkdir -p "$ROOT"
ROOT=$(cd "$ROOT" && pwd -P)
# Never patch or clean existing source trees. Upstream uses git clean -fdx and reset --hard.
[[ ! -e "$ROOT/source" && ! -e "$ROOT/home" ]] || { echo "Refusing to reuse $ROOT; select a fresh BUILD_ROOT" >&2; exit 1; }
free_gib=$(df -Pk "$ROOT" | awk 'NR==2 {print int($4/1048576)}')
(( free_gib >= MIN_FREE_GIB )) || { echo "Need ${MIN_FREE_GIB} GiB free at $ROOT; available ${free_gib} GiB" >&2; exit 1; }

if [[ $INSTALL_DEPS == 1 ]]; then
  . /etc/os-release
  [[ $ID == ubuntu && $VERSION_ID == 22.04 ]] || { echo 'Automatic installation supports Ubuntu 22.04 only' >&2; exit 1; }
  sudo -n apt-get update
  sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y bc bison build-essential ccache curl erofs-utils flex g++-multilib gcc-multilib git git-lfs gnupg gperf imagemagick kmod protobuf-compiler python3-protobuf lib32readline-dev lib32z1-dev lib32ncurses5-dev libncurses5 libncurses5-dev libdw-dev libelf-dev libgnutls28-dev lz4 libsdl1.2-dev libssl-dev libxml2 libxml2-utils lzop pngcrush rsync schedtool squashfs-tools xsltproc xxd zip unzip zlib1g-dev python-is-python3 ca-certificates patch
fi

mkdir -p "$ROOT/home/bin" "$ROOT/source" "$ROOT/audit"
export HOME="$ROOT/home" PATH="$ROOT/home/bin:$PATH"
git config --global user.name 'Lineage Build'
git config --global user.email 'lineage-build@localhost'
git config --global trailer.changeid.key Change-Id
git lfs install
curl --fail --location --retry 3 https://storage.googleapis.com/git-repo-downloads/repo -o "$HOME/bin/repo"
chmod 755 "$HOME/bin/repo"
cd "$ROOT/source"
repo init -u https://github.com/LOS21-pre-QPR2/android.git -b lineage-21.0 --git-lfs
clone_at() {
  local url=$1 dir=$2 branch=$3 commit=$4
  git clone --branch "$branch" "$url" "$dir"
  git -C "$dir" checkout --detach "$commit"
  [[ $(git -C "$dir" rev-parse HEAD) == "$commit" ]]
}
clone_at https://github.com/AndyCGYan/lineage_build_unified.git lineage_build_unified lineage-21-pre-qpr2-light "$BUILD_COMMIT"
clone_at https://github.com/AndyCGYan/lineage_patches_unified.git lineage_patches_unified lineage-21-pre-qpr2-light "$PATCH_COMMIT"
{
  printf 'UTC start: '; date -u +%FT%TZ
  printf 'Build script: %s\nPatches: %s\n' "$BUILD_COMMIT" "$PATCH_COMMIT"
  uname -a
  df -h "$ROOT"
  free -h
} > "$ROOT/audit/environment.txt"
# Resource audit runs concurrently with the upstream sync, patch and build.
( while :; do date -u +%FT%TZ; df -h "$ROOT"; free -h; sleep 60; done ) > "$ROOT/audit/resources.log" 2>&1 &
monitor=$!
finish() {
  local rc=$?
  trap - EXIT
  kill "$monitor" 2>/dev/null || true
  wait "$monitor" 2>/dev/null || true
  if [[ -d .repo ]]; then repo manifest -r -o "$ROOT/audit/resolved-manifest.xml" || true; fi
  printf 'exit_status=%s\n' "$rc" > "$ROOT/audit/result.txt"
  exit "$rc"
}
trap finish EXIT
# Fresh HOME intentionally has no signing keys. The upstream read -n1 prompt needs one byte.
printf '\n' | bash lineage_build_unified/build_unified.sh treble 64VN 64GN 2>&1 | tee "$ROOT/audit/build.log"
shopt -s nullglob
images=("$HOME"/build-output/lineage-*-UNOFFICIAL-gsi_arm64_vN.img "$HOME"/build-output/lineage-*-UNOFFICIAL-gsi_arm64_gN.img)
(( ${#images[@]} == 2 )) || { echo 'Expected both unsigned images; build incomplete' >&2; exit 1; }
sha256sum "${images[@]}" > "$ROOT/audit/SHA256SUMS"
echo "Images: $HOME/build-output; audit: $ROOT/audit"
