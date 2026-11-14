#!/usr/bin/env bash
# Static upstream inventory, not a security audit or Android compilation.
set -Eeuo pipefail
BUILD_COMMIT=301f406f6d0f213798afffb3be5c367cb8d20f2d
PATCH_COMMIT=01a11cee86eeef3fffa744c8efa37985d28312fc
OUT=${AUDIT_OUTPUT:?Set AUDIT_OUTPUT to a new absolute directory}
[[ $OUT == /* && ! -e $OUT ]] || { echo 'AUDIT_OUTPUT must be a new absolute path' >&2; exit 1; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/lineage-upstream-audit.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$OUT"
for name in build patches; do
  if [[ $name == build ]]; then url=https://github.com/AndyCGYan/lineage_build_unified.git; commit=$BUILD_COMMIT
  else url=https://github.com/AndyCGYan/lineage_patches_unified.git; commit=$PATCH_COMMIT; fi
  git clone -q --branch lineage-21-pre-qpr2-light "$url" "$tmp/$name"
  git -C "$tmp/$name" checkout -q --detach "$commit"
  [[ $(git -C "$tmp/$name" rev-parse HEAD) == "$commit" ]]
done
git clone -q --depth 1 --branch lineage-21.0 https://github.com/LOS21-pre-QPR2/android.git "$tmp/manifest"
[[ -s $tmp/build/build_unified.sh && -s $tmp/build/apply_patches.sh && -f $tmp/build/local_manifests_treble/manifest.xml ]]
[[ -d $tmp/patches/patches_platform && -d $tmp/patches/patches_treble ]]
python3 - "$tmp" "$OUT/inventory.txt" <<'PY'
import pathlib, sys, xml.etree.ElementTree as ET
root = pathlib.Path(sys.argv[1])
man = ET.parse(root / 'build/local_manifests_treble/manifest.xml').getroot()
assert man.tag == 'manifest'
projects = man.findall('project')
assert projects, 'No Treble projects in local manifest'
patchroot = root / 'patches'
with open(sys.argv[2], 'w', encoding='utf-8') as out:
    for p in projects:
        print('local_project', p.get('remote'), p.get('name'), p.get('path'), p.get('revision'), file=out)
    for group in ('patches_platform', 'patches_treble'):
        files = sorted((patchroot / group).rglob('*.patch'))
        assert files, f'No patches in {group}'
        print('patch_count', group, len(files), file=out)
PY
{
  date -u +%FT%TZ
  printf 'build='; git -C "$tmp/build" rev-parse HEAD
  printf 'patches='; git -C "$tmp/patches" rev-parse HEAD
  printf 'manifest_branch_head='; git -C "$tmp/manifest" rev-parse HEAD
  sha256sum "$tmp/build/build_unified.sh" "$tmp/build/apply_patches.sh" "$tmp/build/local_manifests_treble/manifest.xml"
} > "$OUT/versions.txt"
# Commit only the small reports, not the Android source tree or compiled outputs.
git -C "$OUT" init -q
git -C "$OUT" add inventory.txt versions.txt
git -C "$OUT" -c user.name='Lineage audit' -c user.email='lineage-audit@localhost' -c commit.gpgsign=false commit -qm 'Record upstream inventory'
git -C "$OUT" bundle create "$OUT/inventory.bundle" --all
printf 'Upstream inventory completed; this is not a full build or full security audit.\n'
