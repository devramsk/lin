#!/usr/bin/env bash
# Commit the audit bundle ($AUDIT_SRC) to a dedicated branch of this repository.
#
# Design goals:
#   * Never fail the calling job/step. On any error, warn and exit 0.
#   * The GITHUB_TOKEN never appears in URLs or logs (http.extraheader auth).
#   * Files larger than 90 MiB are split into .part-NN chunks (GitHub rejects
#     git objects > 100 MB); AUDIT-MANIFEST.txt records names and SHA-256.
#   * $AUDIT_SRC/.git (the local audit repo) is never committed.
#   * Suitable for both GitHub Actions (defaults) and local testing
#     (override AUDIT_REMOTE with a file:// URL).
#
# Inputs (environment):
#   AUDIT_SRC          Audit directory to bundle (required; positional arg 1 also accepted)
#   AUDIT_REMOTE       Push target URL   (default: https://github.com/$GITHUB_REPOSITORY)
#   AUDIT_BRANCH       Branch to create  (default: audit/$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT)
#   AUDIT_CHUNK_BYTES  Chunk size for large files (default: 94371840 = 90 MiB)
#   GITHUB_TOKEN       Token used via http.extraheader (not needed for file:// remotes)
#   GITHUB_STEP_SUMMARY  When set, the audit branch name is appended to it
set -uo pipefail

AUDIT_SRC=${AUDIT_SRC:-${1:-}}
[[ -n $AUDIT_SRC ]] || { echo 'Usage: commit-audit.sh AUDIT_DIR' >&2; exit 2; }
[[ -d $AUDIT_SRC ]] || { echo "::warning title=No audit directory::Nothing to commit ($AUDIT_SRC)"; exit 0; }
AUDIT_SRC=$(cd "$AUDIT_SRC" && pwd -P)

REPO_SLUG=${GITHUB_REPOSITORY:-devramsk/lin}
RUN_ID=${GITHUB_RUN_ID:-manual}
ATTEMPT=${GITHUB_RUN_ATTEMPT:-1}
BRANCH=${AUDIT_BRANCH:-audit/${RUN_ID}-${ATTEMPT}}
CHUNK=${AUDIT_CHUNK_BYTES:-94371840}
REMOTE=${AUDIT_REMOTE:-https://github.com/${REPO_SLUG}.git}
[[ $CHUNK =~ ^[0-9]+$ && $CHUNK -ge 1024 ]] || { echo '::warning::AUDIT_CHUNK_BYTES must be an integer >= 1024'; exit 0; }

warn() { echo "::warning title=Audit commit skipped::$*" >&2; }

work=$(mktemp -d "${TMPDIR:-/tmp}/audit-commit.XXXXXXXX") || { warn 'mktemp failed'; exit 0; }
trap 'rm -rf "$work"' EXIT
repo="$work/repo"
mkdir -p "$repo"

git init -q "$repo" || { warn 'git init failed'; exit 0; }
cd "$repo" || exit 0
git checkout -q --orphan "$BRANCH" || { warn 'orphan checkout failed'; exit 0; }
git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git config commit.gpgsign false

{
  echo "run_id=${RUN_ID}"
  echo "attempt=${ATTEMPT}"
  echo "repository=${REPO_SLUG}"
  echo "branch=${BRANCH}"
  echo "commit=${GITHUB_SHA:-unknown}"
  echo "event=${GITHUB_EVENT_NAME:-local}"
  date -u +%FT%TZ
  echo 'Note: files >90 MiB are split into .part-NN chunks; see AUDIT-MANIFEST.txt for SHA-256 of every file.'
} > AUDIT-INFO.txt
: > AUDIT-MANIFEST.txt

# Copy the audit tree (excluding its internal git dir), preserving paths.
while IFS= read -r -d '' f; do
  rel=${f#"$AUDIT_SRC"/}
  [[ $rel == .git/* ]] && continue
  dst="$repo/$rel"
  mkdir -p "$(dirname "$dst")"
  cp "$f" "$dst" || warn "could not copy $rel"
done < <(find "$AUDIT_SRC" -type f -not -path "$AUDIT_SRC/.git/*" -print0)

# Split any oversized file into .part-NN chunks to stay below GitHub's 100 MB object limit.
: > "$repo/AUDIT-MANIFEST.txt.chunks"
while IFS= read -r -d '' big; do
  rel=${big#"$repo"/}
  if split -b "$CHUNK" -d -- "$big" "$big.part-"; then
    rm -- "$big"
    echo "chunked: $rel -> $(basename "$big").part-*" >> "$repo/AUDIT-MANIFEST.txt.chunks"
  else
    warn "could not chunk $rel"
  fi
done < <(find "$repo" -type f ! -name AUDIT-MANIFEST.txt ! -name AUDIT-MANIFEST.txt.chunks ! -name AUDIT-INFO.txt -size +"${CHUNK}"c -print0)

# Record SHA-256 of every committed file (relative paths), plus chunking notes.
(
  cd "$repo" || exit 0
  {
    echo "# Audit manifest for $BRANCH"
    echo "# run_id=${RUN_ID} attempt=${ATTEMPT} generated=$(date -u +%FT%TZ)"
    find . -mindepth 1 -type f ! -path './.git/*' ! -name AUDIT-MANIFEST.txt ! -name AUDIT-MANIFEST.txt.chunks -print0 | sort -z | xargs -0 sha256sum
    echo
    echo '# chunking notes'
    cat AUDIT-MANIFEST.txt.chunks 2>/dev/null || echo '# (none)'
  } > AUDIT-MANIFEST.txt.tmp
  mv AUDIT-MANIFEST.txt.tmp AUDIT-MANIFEST.txt
  rm -f AUDIT-MANIFEST.txt.chunks
)

git add -A || { warn 'git add failed'; exit 0; }
if git diff --cached --quiet; then
  warn 'nothing to commit (empty audit bundle)'
  exit 0
fi
git -c commit.gpgsign=false commit -qm "audit: ${RUN_ID} attempt ${ATTEMPT} (${GITHUB_EVENT_NAME:-local})" \
  || { warn 'git commit failed'; exit 0; }

export GIT_TERMINAL_PROMPT=0
if [[ $REMOTE == file://* || $REMOTE == /* ]]; then
  git push "$REMOTE" "HEAD:refs/heads/$BRANCH" || { warn 'git push failed (local remote)'; exit 0; }
else
  header=$(printf 'x-access-token:%s' "${GITHUB_TOKEN:-}" | base64 | tr -d '\n')
  git -c http.extraheader="AUTHORIZATION: basic $header" \
      push "$REMOTE" "HEAD:refs/heads/$BRANCH" \
    || { warn 'git push failed. Check Settings -> Actions -> General -> Workflow permissions ("Read and write permissions"). The audit bundle is still available as a job artifact.'; exit 0; }
fi

echo "audit_branch=$BRANCH"
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  {
    echo '## Audit bundle'
    echo "Committed to branch \`$BRANCH\`."
    echo 'Large files are split into `.part-NN` chunks; verify against `AUDIT-MANIFEST.txt`.'
  } >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
fi
exit 0
