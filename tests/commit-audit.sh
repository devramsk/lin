#!/usr/bin/env bash
# Offline test of scripts/commit-audit.sh using a local bare git remote.
set -euo pipefail
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
script=$(cd "$(dirname "$0")/.." && pwd)/scripts/commit-audit.sh

fixture="$tmp/audit"
mkdir -p "$fixture/events" "$fixture/logs" "$fixture/.git"
echo 'event-a' > "$fixture/events/setup-started"
echo 'log-content' > "$fixture/logs/build.log"
echo 'must-not-appear' > "$fixture/.git/internal-noise"
# Incompressible 4 KB file to exercise chunking with a tiny chunk size.
head -c 4096 /dev/urandom > "$fixture/logs/big.bin"

bare="$tmp/remote.git"
git init -q --bare "$bare"

AUDIT_SRC="$fixture" \
AUDIT_REMOTE="file://$bare" \
AUDIT_BRANCH="audit/test-1" \
AUDIT_CHUNK_BYTES=1024 \
GITHUB_RUN_ID=test GITHUB_RUN_ATTEMPT=1 GITHUB_SHA=deadbeef GITHUB_EVENT_NAME=workflow_dispatch \
  bash "$script" >"$tmp/out" 2>&1 || { echo 'commit-audit failed' >&2; cat "$tmp/out" >&2; exit 1; }

git --git-dir="$bare" rev-parse --verify refs/heads/audit/test-1 >/dev/null
tree=$(git --git-dir="$bare" ls-tree -r --name-only refs/heads/audit/test-1)
grep -q 'AUDIT-INFO.txt' <<<"$tree"
grep -q 'AUDIT-MANIFEST.txt' <<<"$tree"
grep -q 'events/setup-started' <<<"$tree"
grep -q 'logs/build.log' <<<"$tree"
grep -q 'logs/big.bin.part-00' <<<"$tree"
grep -q 'logs/big.bin.part-01' <<<"$tree"
! grep -q 'internal-noise' <<<"$tree"
grep -q 'audit_branch=audit/test-1' "$tmp/out"

# Manifest lists every chunk's sha256.
manifest=$(git --git-dir="$bare" show refs/heads/audit/test-1:AUDIT-MANIFEST.txt)
grep -q 'big.bin.part-00' <<<"$manifest"

# Missing audit dir: warns and exits 0 (never fails the pipeline).
env -u GITHUB_TOKEN AUDIT_SRC="$tmp/does-not-exist" AUDIT_REMOTE="file://$bare" bash "$script" >"$tmp/out2" 2>&1
[[ $? -eq 0 ]]
grep -qi 'nothing to commit' "$tmp/out2"

echo 'commit-audit checks passed'
