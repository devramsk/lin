#!/usr/bin/env bash
# Safety contract of scripts/staged-build-gsi.sh. Hermetic: network tools are
# stubbed so the interrupted-stage path behaves identically on any host.
set -euo pipefail
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
script=$(cd "$(dirname "$0")/.." && pwd)/scripts/staged-build-gsi.sh

# git-lfs stub: `git lfs install` fails deterministically, real git keeps working.
stub_bin="$root/stub-bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/git-lfs" <<'STUB'
#!/usr/bin/env bash
echo 'git-lfs stub: fail deterministically' >&2
exit 1
STUB
chmod +x "$stub_bin/git-lfs"

mkdir -p "$root/occupied"; echo keep > "$root/occupied/file"
if BUILD_ROOT="$root/occupied" INSTALL_DEPS=0 bash "$script" >"$root/log" 2>&1; then
  echo 'Accepted an unowned root' >&2; exit 1
fi
grep -q 'Refusing nonempty unowned' "$root/log"

set +e
PATH="$stub_bin:$PATH" BUILD_ROOT="$root/build" INSTALL_DEPS=0 bash "$script" >"$root/log" 2>&1
rc=$?
set -e
[[ $rc != 0 ]] || { echo 'setup unexpectedly succeeded' >&2; exit 1; }
[[ ! -e "$root/build/audit/setup.done" && -e "$root/build/audit/setup.active" ]]
[[ $(git -C "$root/build/audit" log --oneline | wc -l) -eq 2 ]]

# Interrupted non-build stage: refused by default...
set +e
PATH="$stub_bin:$PATH" BUILD_ROOT="$root/build" INSTALL_DEPS=0 bash "$script" >"$root/log" 2>&1
rc=$?
set -e
[[ $rc != 0 ]] || { echo 'Repeated an unsafe setup' >&2; exit 1; }
grep -q 'Interrupted setup' "$root/log"

# ...and re-run explicitly only with RESUME_INTERRUPTED=1 (still fails at the stub, not refused).
set +e
PATH="$stub_bin:$PATH" BUILD_ROOT="$root/build" INSTALL_DEPS=0 RESUME_INTERRUPTED=1 bash "$script" >"$root/log-resume" 2>&1
rc=$?
set -e
[[ $rc != 0 ]] || { echo 'Resumed setup unexpectedly succeeded' >&2; exit 1; }
grep -q 'RESUME_INTERRUPTED=1' "$root/log-resume"
! grep -q 'Interrupted setup' "$root/log-resume"

if BUILD_ROOT=relative INSTALL_DEPS=0 bash "$script" >"$root/log" 2>&1; then
  echo 'Accepted a relative root' >&2; exit 1
fi
grep -q 'BUILD_ROOT must be absolute' "$root/log"
if BUILD_ROOT="$root/empty" INSTALL_DEPS=0 STAGE=sync bash "$script" >"$root/log" 2>&1; then
  echo 'Accepted sync without setup' >&2; exit 1
fi
grep -q 'Missing prerequisite checkpoint: setup' "$root/log"
if BUILD_ROOT="$root/invalid" REPO_DEPTH=2 bash "$script" >"$root/log" 2>&1; then
  echo 'Accepted invalid REPO_DEPTH' >&2; exit 1
fi
grep -q 'REPO_DEPTH must be 0 or 1' "$root/log"
if BUILD_ROOT="$root/build" INSTALL_DEPS=0 REPO_DEPTH=1 bash "$script" >"$root/log" 2>&1; then
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
