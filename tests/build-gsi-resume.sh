#!/usr/bin/env bash
# Resume semantics of scripts/build-gsi.sh with the network stubbed out:
# a legacy (pre-marker) root is adopted, completed stages are skipped,
# and the audit repository accumulates commits.
set -euo pipefail
export ALLOW_NON_2404=1   # test host may not be Ubuntu 24.04

root_parent=$(mktemp -d)
trap 'rm -rf "$root_parent"' EXIT

# Stub the network: init stage must fail fast and deterministically.
bin="$root_parent/bin"
mkdir -p "$bin"
cat > "$bin/curl" <<'STUB'
#!/usr/bin/env bash
echo 'curl stub: network disabled in tests' >&2
exit 7
STUB
cat > "$bin/git-lfs" <<'STUB'
#!/usr/bin/env bash
echo 'git-lfs stub: fail deterministically' >&2
exit 7
STUB
chmod +x "$bin/curl" "$bin/git-lfs"
export PATH="$bin:$PATH"

script=$(cd "$(dirname "$0")/.." && pwd)/scripts/build-gsi.sh

# 1. Legacy root (source/ + audit/environment.txt, no marker) is adopted.
legacy="$root_parent/legacy"
mkdir -p "$legacy/source" "$legacy/audit"
echo 'previous environment dump' > "$legacy/audit/environment.txt"
BUILD_ROOT="$legacy" INSTALL_DEPS=0 STOP_AFTER=deps bash "$script" >"$root_parent/log1" 2>&1
grep -q 'Adopting existing build root' "$root_parent/log1"
grep -q "Stage 'deps': OK" "$root_parent/log1"

# 2. Re-run: deps skipped, init fails (stubbed network), no refusal.
set +e
BUILD_ROOT="$legacy" INSTALL_DEPS=0 STOP_AFTER=init bash "$script" >"$root_parent/log2" 2>&1
rc=$?
set -e
[[ $rc != 0 ]] || { echo 'init unexpectedly succeeded' >&2; exit 1; }
grep -q "Stage 'deps': already completed" "$root_parent/log2"
grep -q "Stage 'init': FAILED" "$root_parent/log2"
! grep -q 'Refusing to reuse' "$root_parent/log2"
! grep -q 'GiB free' "$root_parent/log2"

# 3. With init/build markers and images present, build is skipped (resume).
mkdir -p "$legacy/home/build-output"
echo 'vN-image' > "$legacy/home/build-output/lineage-21.0-20260101-UNOFFICIAL-gsi_arm64_vN.img"
echo 'gN-image' > "$legacy/home/build-output/lineage-21.0-20260101-UNOFFICIAL-gsi_arm64_gN.img"
date -u +%FT%TZ > "$legacy/audit/init.done"
date -u +%FT%TZ > "$legacy/audit/build.done"
BUILD_ROOT="$legacy" INSTALL_DEPS=0 STOP_AFTER=build DISK_GUARD=0 bash "$script" >"$root_parent/log3" 2>&1
grep -q "Stage 'build': already completed" "$root_parent/log3"
! grep -q 'Refusing to reuse' "$root_parent/log3"

# 4. Unknown non-empty root is refused; FORCE_ADOPT overrides explicitly.
personal="$root_parent/personal"
mkdir -p "$personal/my-precious-sources"
set +e
BUILD_ROOT="$personal" INSTALL_DEPS=0 bash "$script" >"$root_parent/log4" 2>&1
rc=$?
set -e
[[ $rc != 0 ]] || { echo 'unowned root unexpectedly accepted' >&2; exit 1; }
grep -q 'Refusing to reuse' "$root_parent/log4"
BUILD_ROOT="$personal" FORCE_ADOPT=1 INSTALL_DEPS=0 STOP_AFTER=deps bash "$script" >"$root_parent/log5" 2>&1
grep -q 'Adopting existing build root' "$root_parent/log5"

# 5. Audit events are committed to the local audit git repository.
commits=$(git -C "$legacy/audit" log --oneline | wc -l)
(( commits >= 2 )) || { echo "expected audit commits, got $commits" >&2; exit 1; }
[[ -f $legacy/audit/result.txt ]] || { echo 'result.txt missing' >&2; exit 1; }
grep -q 'exit_status=0' "$legacy/audit/result.txt"

# 6. Ubuntu 24.04 gate rejects other hosts unless explicitly overridden.
if [[ $(. /etc/os-release 2>/dev/null; echo "${ID:-}-${VERSION_ID:-}") != 'ubuntu-24.04' ]]; then
  set +e
  env -u ALLOW_NON_2404 BUILD_ROOT="$root_parent/gated" INSTALL_DEPS=0 bash "$script" >"$root_parent/log6" 2>&1
  rc=$?
  set -e
  [[ $rc != 0 ]] || { echo 'non-Ubuntu host unexpectedly accepted' >&2; exit 1; }
  grep -q 'Ubuntu 24.04 required' "$root_parent/log6"
fi

echo 'build-gsi resume checks passed'
