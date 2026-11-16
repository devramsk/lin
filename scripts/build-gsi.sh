#!/usr/bin/env bash
# LineageOS 21 pre-QPR2 GSI build for a dedicated Ubuntu 24.04 x86_64 server.
#
# This script is RESUMABLE. Safe to re-run after an interruption: each stage
# records a marker `$BUILD_ROOT/audit/<stage>.done`, and completed stages are
# skipped. The upstream steps themselves (repo sync, repopick, patches,
# ninja/make in out/) are incremental, so re-running continues roughly from
# where the previous attempt stopped.
#
# Usage:
#   sudo bash scripts/build-gsi.sh                    # BUILD_ROOT=./lineage-work
#   BUILD_ROOT=/opt/dev/lin/lineage-work bash scripts/build-gsi.sh
#
# Environment overrides:
#   BUILD_ROOT            Absolute build directory. Default: $PWD/lineage-work
#   INSTALL_DEPS          1 = install Ubuntu packages via apt (default), 0 = skip
#   DISK_GUARD            1 = stop the build stage before the disk fills (default), 0 = disable
#   DISK_RESERVE_GIB      Free space reserve for DISK_GUARD (default: 3 GiB)
#   ALLOW_NON_2404        1 = allow hosts other than Ubuntu 24.04 (unsupported)
#   STOP_AFTER            Stop after this stage: deps | init | build | validate (default: none)
#   FORCE_ADOPT           1 = adopt a pre-existing BUILD_ROOT created by this script family
#                         even when the evidence is ambiguous (default: 0)
#
# Safety contract: this script never deletes or resets trees it did not build.
# A non-empty BUILD_ROOT that was not created by this script family is refused,
# and the refusal happens BEFORE anything is written into the directory.
set -Eeuo pipefail

BUILD_COMMIT=301f406f6d0f213798afffb3be5c367cb8d20f2d
PATCH_COMMIT=01a11cee86eeef3fffa744c8efa37985d28312fc
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

ROOT=${BUILD_ROOT:-"$PWD/lineage-work"}
INSTALL_DEPS=${INSTALL_DEPS:-1}
DISK_GUARD=${DISK_GUARD:-1}
DISK_RESERVE_GIB=${DISK_RESERVE_GIB:-3}
ALLOW_NON_2404=${ALLOW_NON_2404:-0}
STOP_AFTER=${STOP_AFTER:-}
FORCE_ADOPT=${FORCE_ADOPT:-0}

[[ $ROOT == /* ]] || { echo "BUILD_ROOT must be an absolute path, got: $ROOT" >&2; exit 2; }
[[ $INSTALL_DEPS == 0 || $INSTALL_DEPS == 1 ]] || { echo 'INSTALL_DEPS must be 0 or 1' >&2; exit 2; }
[[ $DISK_GUARD == 0 || $DISK_GUARD == 1 ]] || { echo 'DISK_GUARD must be 0 or 1' >&2; exit 2; }
[[ $DISK_RESERVE_GIB =~ ^[0-9]+$ ]] || { echo 'DISK_RESERVE_GIB must be a non-negative integer' >&2; exit 2; }
[[ -z $STOP_AFTER || $STOP_AFTER =~ ^(deps|init|build|validate)$ ]] || { echo 'STOP_AFTER must be deps|init|build|validate' >&2; exit 2; }
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo 'Linux x86_64 required' >&2; exit 1; }

# Ubuntu 24.04 is the supported host (hard requirement for this build).
if [[ $ALLOW_NON_2404 != 1 ]]; then
  os_id=''; os_ver=''
  if [[ -r /etc/os-release ]]; then . /etc/os-release; os_id=${ID:-}; os_ver=${VERSION_ID:-}; fi
  if [[ $os_id != ubuntu || $os_ver != 24.04 ]]; then
    echo "Ubuntu 24.04 required (found: ${os_id:-unknown} ${os_ver:-unknown})." >&2
    echo 'Run on Ubuntu 24.04, or set ALLOW_NON_2404=1 to override at your own risk.' >&2
    exit 1
  fi
fi

mkdir -p "$ROOT"
ROOT=$(cd "$ROOT" && pwd -P)
exec 9>"$ROOT/.lock"
flock -n 9 || { echo "Build root already in use by another run: $ROOT" >&2; exit 1; }

AUDIT="$ROOT/audit"
EVENTS="$AUDIT/events"
LOGS="$AUDIT/logs"

# =============================================================================
# Build-root decision (READ-ONLY with respect to $ROOT).
# A root is "ours" when it carries the adoption marker written by this script,
# or carries evidence created by a previous run of this script family
# (source/ created by it, plus its audit artifacts). Anything else is refused.
# =============================================================================
MARKER="$ROOT/.lineage-build-v2"
expected_marker="$(printf 'v2\n%s\n%s\n' "$BUILD_COMMIT" "$PATCH_COMMIT")"
adopt_reason=''
if [[ -f $MARKER ]]; then
  if [[ $(cat "$MARKER") != "$expected_marker" ]]; then
    echo "Build root $ROOT was created for different pinned commits/toolchain." >&2
    echo 'Refusing to mix. Select a fresh BUILD_ROOT or restore the original pins.' >&2
    exit 1
  fi
  adopt_reason='resume'
else
  # Never consider our own lock file, and never consider nothing: compute evidence first.
  nonempty=$(find "$ROOT" -mindepth 1 -maxdepth 1 ! -name .lock -print -quit)
  has_source=0; [[ -d $ROOT/source ]] && has_source=1
  has_evidence=0
  if [[ -f $AUDIT/environment.txt || -d $AUDIT/.git || -d $AUDIT/events || -f $ROOT/.lineage-staged-v3 || -f $AUDIT/result.txt ]]; then
    has_evidence=1
  fi
  if [[ -z $nonempty ]]; then
    adopt_reason='fresh'
  elif [[ $FORCE_ADOPT == 1 ]]; then
    adopt_reason='forced'
  elif [[ $has_source == 1 && $has_evidence == 1 ]]; then
    adopt_reason='legacy'
  else
    echo "Refusing to reuse $ROOT; select a fresh BUILD_ROOT." >&2
    echo 'If you are sure this directory was created by this build script, re-run with FORCE_ADOPT=1.' >&2
    exit 1
  fi
fi

# =============================================================================
# From here on we own the root: create audit layout and the local audit repo.
# =============================================================================
mkdir -p "$EVENTS" "$LOGS" "$ROOT/home/bin" "$ROOT/source"

ensure_audit_repo() {
  if [[ ! -d $AUDIT/.git ]]; then
    git -C "$AUDIT" init -q
    git -C "$AUDIT" config user.name 'Lineage Build'
    git -C "$AUDIT" config user.email 'lineage-build@localhost'
    printf 'logs/\nresources.log\n' > "$AUDIT/.gitignore"
  fi
}
ensure_audit_repo

# Microtask records are first written in TMPDIR (default /tmp), then copied
# into $BUILD_ROOT/audit/events, atomically renamed, and committed into the
# small *local* audit Git repository (never into the source tree).
record_event() {
  local stage=$1 status=$2 log=${3:-} tmp target
  tmp=$(mktemp "${TMPDIR:-/tmp}/lineage-event.XXXXXXXX") || return 0
  {
    printf 'stage=%s\nstatus=%s\ntime=%s\n' "$stage" "$status" "$(date -u +%FT%TZ)"
    printf 'build_commit=%s\npatch_commit=%s\n' "$BUILD_COMMIT" "$PATCH_COMMIT"
    printf 'build_root=%s\n' "$ROOT"
    uname -a
    [[ -z $log || ! -f $log ]] || sha256sum "$log"
  } > "$tmp"
  target="$EVENTS/${stage}-${status}-$(date -u +%Y%m%dT%H%M%S)-$$"
  cp "$tmp" "$target.tmp" && mv "$target.tmp" "$target" && rm -f "$tmp"
  git -C "$AUDIT" add .gitignore events >/dev/null 2>&1 || true
  git -C "$AUDIT" -c commit.gpgsign=false commit -qm "$stage: $status" >/dev/null 2>&1 || true
}

case "$adopt_reason" in
  fresh)  record_event root fresh  ;;
  forced) echo "Adopting existing build root $ROOT (FORCE_ADOPT=1)."; record_event root forced ;;
  legacy) echo "Adopting existing build root $ROOT (evidence of a previous run found)."; record_event root adopted ;;
  resume) : ;;                    # marker already present; normal resume
esac
if [[ $adopt_reason != resume ]]; then
  printf '%s' "$expected_marker" > "$MARKER.tmp" && mv "$MARKER.tmp" "$MARKER"
fi

# ---- Environment -------------------------------------------------------------
export HOME="$ROOT/home"
export PATH="$ROOT/home/bin:$PATH"
export ROOT AUDIT EVENTS LOGS SCRIPT_DIR INSTALL_DEPS DISK_GUARD DISK_RESERVE_GIB

monitor=''
start_monitor() {
  ( exec 9>&-; while :; do date -u +%FT%TZ; df -h "$ROOT"; free -h; sleep 60; done ) >> "$AUDIT/resources.log" 2>&1 &
  monitor=$!
}
stop_monitor() {
  [[ -z $monitor ]] && return 0
  kill "$monitor" 2>/dev/null || true
  wait "$monitor" 2>/dev/null || true
  monitor=''
}
finish() {
  local rc=$?
  trap - EXIT INT TERM
  stop_monitor
  if [[ -d $ROOT/source/.repo && ! -f $AUDIT/resolved-manifest.xml ]]; then
    ( cd "$ROOT/source" && repo manifest -r -o "$AUDIT/resolved-manifest.xml" ) >/dev/null 2>&1 || true
  fi
  printf 'exit_status=%s\n' "$rc" > "$AUDIT/result.txt"
  if (( rc != 0 )); then
    echo "Build exited with status $rc. See $LOGS/ for stage logs and $AUDIT for markers/events." >&2
    echo 'Re-run the same command to resume; completed stages are skipped.' >&2
  fi
  exit "$rc"
}
trap finish EXIT INT TERM

# ---- Stages ------------------------------------------------------------------
marker_path() { printf '%s/%s.done' "$AUDIT" "$1"; }

skip_check() {
  local name=$1
  [[ -f $(marker_path "$name") ]] || return 1
  case "$name" in
    build)
      # Do not trust the marker alone: images must actually be present.
      shopt -s nullglob
      local imgs=("$HOME"/build-output/lineage-*-UNOFFICIAL-gsi_arm64_vN.img
                  "$HOME"/build-output/lineage-*-UNOFFICIAL-gsi_arm64_gN.img)
      [[ ${#imgs[@]} == 2 ]] || return 1
      ;;
  esac
  return 0
}

run_stage() {
  local name=$1 func=$2
  if skip_check "$name"; then
    echo "==> Stage '$name': already completed ($(cat "$(marker_path "$name")")); skipping"
    record_event "$name" skipped
    if [[ -n $STOP_AFTER && $STOP_AFTER == "$name" ]]; then
      echo "STOP_AFTER=$name reached (stage already complete); stopping."
      exit 0
    fi
    return 0
  fi
  local log="$LOGS/$name.log"
  echo "==> Stage '$name': starting $(date -u +%FT%TZ) (log: $log)"
  record_event "$name" started "$log"
  set +e
  if [[ $DISK_GUARD == 1 && $name == build ]]; then
    # Deliberately the heavy stage: refuse to fill the disk.
    DISK_RESERVE_GIB="$DISK_RESERVE_GIB" "$SCRIPT_DIR/run-with-disk-guard.sh" "$ROOT" "$log" bash -c "$func"
    rc=$?
  else
    set -o pipefail
    bash -e -o pipefail -c "$func" 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    set +o pipefail
  fi
  set -e
  if (( rc == 0 )); then
    date -u +%FT%TZ > "$(marker_path "$name").tmp"
    mv "$(marker_path "$name").tmp" "$(marker_path "$name")"
    echo "==> Stage '$name': OK $(date -u +%FT%TZ)"
    record_event "$name" completed "$log"
    if [[ -n $STOP_AFTER && $STOP_AFTER == "$name" ]]; then
      echo "STOP_AFTER=$name reached; stopping before the next stage."
      exit 0
    fi
    return 0
  fi
  echo "==> Stage '$name': FAILED (exit $rc). Log: $log" >&2
  record_event "$name" failed "$log"
  return "$rc"
}

stage_deps() {
  if [[ $INSTALL_DEPS == 1 ]]; then
    if ! bash "$SCRIPT_DIR/install-build-deps.sh"; then
      echo 'Dependency installation failed.' >&2
      echo 'If sudo requires a password, run "sudo -v" first, or install the packages manually' >&2
      echo 'and re-run with INSTALL_DEPS=0.' >&2
      return 1
    fi
  else
    echo 'INSTALL_DEPS=0: skipping package installation (operator responsibility).'
  fi
}

clone_or_verify() {
  local url=$1 dir=$2 branch=$3 commit=$4 head
  if [[ -d $dir ]]; then
    [[ -d $dir/.git ]] || { echo "$dir exists but is not a git checkout; refusing to touch it" >&2; return 1; }
    head=$(git -C "$dir" rev-parse HEAD)
    if [[ $head == "$commit" ]]; then
      echo "==> $dir already at $commit"
      return 0
    fi
    echo "==> $dir at $head; fetching pinned commit $commit"
    git -C "$dir" fetch origin "$commit" || git -C "$dir" fetch origin || return 1
    git -C "$dir" checkout --detach "$commit" || return 1
  else
    git clone --branch "$branch" "$url" "$dir"
    git -C "$dir" checkout --detach "$commit"
  fi
  [[ $(git -C "$dir" rev-parse HEAD) == "$commit" ]]
}

stage_init() {
  git config --global user.name 'Lineage Build'
  git config --global user.email 'lineage-build@localhost'
  git config --global trailer.changeid.key Change-Id
  git lfs install
  curl --fail --location --retry 3 https://storage.googleapis.com/git-repo-downloads/repo -o "$HOME/bin/repo"
  chmod 755 "$HOME/bin/repo"
  cd "$ROOT/source"
  repo init -u https://github.com/LOS21-pre-QPR2/android.git -b lineage-21.0 --git-lfs
  clone_or_verify https://github.com/AndyCGYan/lineage_build_unified.git lineage_build_unified lineage-21-pre-qpr2-light "$BUILD_COMMIT"
  clone_or_verify https://github.com/AndyCGYan/lineage_patches_unified.git lineage_patches_unified lineage-21-pre-qpr2-light "$PATCH_COMMIT"
  {
    printf 'UTC start: '; date -u +%FT%TZ
    printf 'Build script: %s\nPatches: %s\n' "$BUILD_COMMIT" "$PATCH_COMMIT"
    uname -a
    cat /etc/os-release 2>/dev/null || true
    df -h "$ROOT"
    free -h
    git --version; repo --version 2>&1 | head -1 || true
  } > "$AUDIT/environment.txt"
}

stage_build() {
  cd "$ROOT/source"
  # Fresh HOME intentionally has no signing keys; the upstream prompt needs one byte.
  if ! printf '\n' | bash lineage_build_unified/build_unified.sh treble 64VN 64GN; then
    return 1
  fi
  # Record the exact resolved source state for this build (best effort).
  if [[ -d .repo ]]; then
    repo manifest -r -o "$AUDIT/resolved-manifest.xml" || true
    git -C "$AUDIT" add resolved-manifest.xml >/dev/null 2>&1 || true
    git -C "$AUDIT" -c commit.gpgsign=false commit -qm 'Record resolved manifest' >/dev/null 2>&1 || true
  fi
}

stage_validate() {
  shopt -s nullglob
  local vs=("$HOME"/build-output/lineage-*-UNOFFICIAL-gsi_arm64_vN.img)
  local gs=("$HOME"/build-output/lineage-*-UNOFFICIAL-gsi_arm64_gN.img)
  if (( ${#vs[@]} != 1 || ${#gs[@]} != 1 )); then
    echo "Expected exactly one image per target, found vN=${#vs[@]} gN=${#gs[@]}" >&2
    return 1
  fi
  [[ -s ${vs[0]} && -s ${gs[0]} ]] || { echo 'Image(s) are empty' >&2; return 1; }
  sha256sum "${vs[0]}" "${gs[0]}" > "$AUDIT/SHA256SUMS"
  git -C "$AUDIT" add SHA256SUMS >/dev/null 2>&1 || true
  git -C "$AUDIT" -c commit.gpgsign=false commit -qm 'Record image hashes' >/dev/null 2>&1 || true
  printf 'Images:\n  %s\n  %s\nSHA256SUMS: %s\n' "${vs[0]}" "${gs[0]}" "$AUDIT/SHA256SUMS"
}

export -f stage_deps stage_init stage_build stage_validate clone_or_verify skip_check marker_path

printf '\nLineageOS 21 pre-QPR2 GSI build\n'
printf '  BUILD_ROOT:  %s\n  HOME:        %s\n  Disk guard:  %s (reserve %s GiB)\n  Stop after:  %s\n\n' \
  "$ROOT" "$HOME" "$DISK_GUARD" "$DISK_RESERVE_GIB" "${STOP_AFTER:-<none>}"

start_monitor
cd "$ROOT/source"

run_stage deps stage_deps
run_stage init stage_init
run_stage build stage_build
run_stage validate stage_validate
sha256sum -c "$AUDIT/SHA256SUMS"

echo
echo "Build finished."
echo "  Images:      $HOME/build-output"
echo "  Logs:        $LOGS"
echo "  Audit repo:  $AUDIT (local git)"
