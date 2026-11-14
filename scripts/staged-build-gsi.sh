#!/usr/bin/env bash
# Staged build on a persistent, dedicated disk. Never run against a personal source tree.
set -Eeuo pipefail
BUILD_COMMIT=301f406f6d0f213798afffb3be6c367cb8d20f2d
PATCH_COMMIT=01a11cee86eeef3fffa744c8efa37985d28312fc
ROOT=${BUILD_ROOT:-"$HOME/lineage-gsi-work"}
INSTALL_DEPS=${INSTALL_DEPS:-1}
MIN_FREE_GIB=${MIN_FREE_GIB:-400}
[[ $ROOT == /* && $MIN_FREE_GIB =~ ^[0-9]+$ ]] || { echo 'BUILD_ROOT must be absolute; MIN_FREE_GIB must be an integer' >&2; exit 1; }
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo 'Linux x86_64 required' >&2; exit 1; }
mkdir -p "$ROOT"
ROOT=$(cd "$ROOT" && pwd -P)
exec 9>"$ROOT/.lock"
flock -n 9 || { echo 'Build root already in use' >&2; exit 1; }
if [[ ! -e $ROOT/.lineage-staged-v1 ]]; then
  [[ -z $(find "$ROOT" -mindepth 1 -maxdepth 1 ! -name .lock -print -quit) ]] || { echo 'Refusing nonempty unowned BUILD_ROOT' >&2; exit 1; }
  printf '%s\n%s\n' "$BUILD_COMMIT" "$PATCH_COMMIT" > "$ROOT/.lineage-staged-v1"
fi
[[ $(cat "$ROOT/.lineage-staged-v1") == "$(printf '%s\n%s' "$BUILD_COMMIT" "$PATCH_COMMIT")" ]] || { echo 'Build root version mismatch' >&2; exit 1; }
mkdir -p "$ROOT/audit/events" "$ROOT/audit/logs" "$ROOT/home/bin" "$ROOT/source"
export HOME="$ROOT/home" PATH="$ROOT/home/bin:$PATH"
if [[ ! -d $ROOT/audit/.git ]]; then
  git -C "$ROOT/audit" init -q
  git -C "$ROOT/audit" config user.name 'Lineage Build'
  git -C "$ROOT/audit" config user.email 'lineage-build@localhost'
  printf 'logs/\nresources.log\n' > "$ROOT/audit/.gitignore"
fi
# Stage records are first written in /tmp, copied to the persistent filesystem,
# atomically renamed there, then committed to a small *local* audit repository.
event() {
  local stage=$1 status=$2 log=$3 tmp target
  tmp=$(mktemp "${TMPDIR:-/tmp}/lineage-event.XXXXXXXX")
  {
    printf 'stage=%s\nstatus=%s\ntime=%s\n' "$stage" "$status" "$(date -u +%FT%TZ)"
    printf 'build_script=%s\npatches=%s\n' "$BUILD_COMMIT" "$PATCH_COMMIT"
    [[ ! -f $log ]] || sha256sum "$log"
  } > "$tmp"
  target="$ROOT/audit/events/${stage}-${status}-$(date -u +%Y%m%dT%H%M%S)-$$"
  cp "$tmp" "$target.tmp"
  mv "$target.tmp" "$target"
  rm -f "$tmp"
  git -C "$ROOT/audit" add .gitignore events
  git -C "$ROOT/audit" -c commit.gpgsign=false commit -qm "$stage: $status"
}
run_stage() {
  local name=$1; shift
  local marker="$ROOT/audit/$name.done" active="$ROOT/audit/$name.active" log="$ROOT/audit/logs/$name.log" rc
  local -a statuses
  [[ ! -f $marker ]] || { echo "Already completed: $name"; return; }
  if [[ -f $active && $name != build-* ]]; then
    echo "Interrupted $name; unsafe to repeat automatically. Inspect $log and use a fresh BUILD_ROOT." >&2
    return 1
  fi
  printf 'started %s\n' "$(date -u +%FT%TZ)" > "$active"
  event "$name" started "$log"
  set +e
  bash -e -o pipefail -c '"$@"' _ "$@" 2>&1 | tee -a "$log"
  statuses=("${PIPESTATUS[@]}")
  rc=${statuses[0]}
  (( statuses[1] == 0 )) || rc=1
  set -e
  if (( rc == 0 )); then
    event "$name" completed "$log"
    printf '%s\n' "$(date -u +%FT%TZ)" > "$marker.tmp"
    mv "$marker.tmp" "$marker"
    rm -f "$active"
  else
    event "$name" failed "$log" || true
    echo "$name failed (exit $rc), see $log" >&2
    return "$rc"
  fi
}
setup() {
  local free_gib
  free_gib=$(df -Pk "$ROOT" | awk 'NR==2 {print int($4/1048576)}')
  (( free_gib >= MIN_FREE_GIB )) || { echo "Need ${MIN_FREE_GIB} GiB free; available ${free_gib} GiB" >&2; return 1; }
  if [[ $INSTALL_DEPS == 1 ]]; then
    . /etc/os-release
    [[ $ID == ubuntu && $VERSION_ID == 22.04 ]] || { echo 'Automatic installation supports Ubuntu 22.04 only' >&2; return 1; }
    sudo -n apt-get update
    sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y bc bison build-essential ccache curl erofs-utils flex g++-multilib gcc-multilib git git-lfs gnupg gperf imagemagick kmod protobuf-compiler python3-protobuf lib32readline-dev lib32z1-dev lib32ncurses5-dev libncurses5 libncurses5-dev libdw-dev libelf-dev libgnutls28-dev lz4 libsdl1.2-dev libssl-dev libxml2 libxml2-utils lzop pngcrush rsync schedtool squashfs-tools xsltproc xxd zip unzip zlib1g-dev python-is-python3 ca-certificates patch
  fi
  git config --global user.name 'Lineage Build'
  git config --global user.email 'lineage-build@localhost'
  git config --global trailer.changeid.key Change-Id
  git lfs install
  curl --fail --location --retry 3 https://storage.googleapis.com/git-repo-downloads/repo -o "$HOME/bin/repo"
  chmod 755 "$HOME/bin/repo"
  cd "$ROOT/source"
  repo init -u https://github.com/LOS21-pre-QPR2/android.git -b lineage-21.0 --git-lfs
  git clone -b lineage-21-pre-qpr2-light https://github.com/AndyCGYan/lineage_build_unified.git lineage_build_unified
  git -C lineage_build_unified checkout --detach "$BUILD_COMMIT"
  git clone -b lineage-21-pre-qpr2-light https://github.com/AndyCGYan/lineage_patches_unified.git lineage_patches_unified
  git -C lineage_patches_unified checkout --detach "$PATCH_COMMIT"
}
prepare() {
  cd "$ROOT/source"
  [[ $(git -C lineage_build_unified rev-parse HEAD) == "$BUILD_COMMIT" && $(git -C lineage_patches_unified rev-parse HEAD) == "$PATCH_COMMIT" ]]
  # Use precisely the function definitions from the pinned upstream script.
  # Do not execute its main loop here; this is the non-resumable patch stage.
  local script="$ROOT/audit/upstream-prepare.sh"
  awk '/^if \$\{NOSYNC\}$/ {found=1; exit} {print} END {if (!found) exit 1}' lineage_build_unified/build_unified.sh > "$script"
  cat >> "$script" <<'EOS'
prep_build
prep_treble
apply_patches patches_platform
apply_patches patches_treble
finalize_treble
EOS
  printf '\n' | bash "$script" treble 64VN
  repo manifest -r -o "$ROOT/audit/resolved-manifest.xml"
  git -C "$ROOT/audit" add upstream-prepare.sh resolved-manifest.xml
  git -C "$ROOT/audit" -c commit.gpgsign=false commit -qm 'Record preparation and resolved manifest'
}
build_target() {
  local target=$1
  cd "$ROOT/source"
  local suffix
  case $target in 64VN) suffix=vN;; 64GN) suffix=gN;; *) return 1;; esac
  shopt -s nullglob
  local existing=("$HOME"/build-output/lineage-*-UNOFFICIAL-gsi_arm64_${suffix}.img)
  (( ${#existing[@]} == 0 )) || { echo "Output already exists for $target; inspect before recovery" >&2; return 1; }
  printf '\n' | bash lineage_build_unified/build_unified.sh treble nosync "$target"
}
validate() {
  local v g
  shopt -s nullglob
  local vs=("$HOME"/build-output/lineage-*-UNOFFICIAL-gsi_arm64_vN.img)
  local gs=("$HOME"/build-output/lineage-*-UNOFFICIAL-gsi_arm64_gN.img)
  (( ${#vs[@]} == 1 && ${#gs[@]} == 1 )) || { echo 'Expected exactly one image of each target' >&2; return 1; }
  v=${vs[0]}; g=${gs[0]}
  [[ -s $v && -s $g ]] || return 1
  sha256sum "$v" "$g" > "$ROOT/audit/SHA256SUMS"
  git -C "$ROOT/audit" add SHA256SUMS
  git -C "$ROOT/audit" -c commit.gpgsign=false commit -qm 'Record image hashes'
}
export ROOT BUILD_COMMIT PATCH_COMMIT MIN_FREE_GIB INSTALL_DEPS
export -f setup prepare build_target validate
( exec 9>&-; while :; do date -u +%FT%TZ; df -h "$ROOT"; free -h; sleep 60; done ) >> "$ROOT/audit/resources.log" 2>&1 &
monitor=$!
trap 'kill "$monitor" 2>/dev/null || true; wait "$monitor" 2>/dev/null || true' EXIT
require_stage() {
  [[ -f "$ROOT/audit/$1.done" ]] || { echo "Missing prerequisite checkpoint: $1" >&2; return 1; }
}
case ${STAGE:-all} in
  setup) run_stage setup setup ;;
  prepare) require_stage setup; run_stage prepare prepare ;;
  build-64VN) require_stage prepare; run_stage build-64VN build_target 64VN ;;
  build-64GN) require_stage build-64VN; run_stage build-64GN build_target 64GN ;;
  validate) require_stage build-64GN; run_stage validate validate; sha256sum -c "$ROOT/audit/SHA256SUMS" ;;
  all)
    run_stage setup setup
    run_stage prepare prepare
    run_stage build-64VN build_target 64VN
    run_stage build-64GN build_target 64GN
    run_stage validate validate
    sha256sum -c "$ROOT/audit/SHA256SUMS" ;;
  *) echo "Unknown STAGE: $STAGE" >&2; exit 1 ;;
esac
echo "Images: $HOME/build-output; logs and local audit Git: $ROOT/audit"
