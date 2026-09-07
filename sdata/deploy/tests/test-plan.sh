#!/usr/bin/env bash
#
# Fixture tests for the Slice 3A read-only planner (deploy-plan.sh).
# Builds a baseline rev + target rev, adopts the baseline in a fixture
# home/state, mutates the home to "now", and asserts every op of the
# decision table plus refusal paths. Nothing leaves $T.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBDIR="${HERE}/../../lib"
ADOPTDIR="${HERE}/../../subcmd-adopt"
PLANDIR="${HERE}/../../subcmd-plan"
# shellcheck source=../lib/deploy-common.sh
source "${LIBDIR}/deploy-common.sh"
# shellcheck source=../lib/deploy-state.sh
source "${LIBDIR}/deploy-state.sh"
# shellcheck source=../lib/deploy-plan.sh
source "${LIBDIR}/deploy-plan.sh"

PASS=0
FAIL=0
pass(){ PASS=$((PASS+1)); echo "PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }

T="$(mktemp -d /tmp/deploy-plan-XXXXXX)"
trap 'rm -rf "$T"' EXIT

R="$T/repo"
H="$T/home"
S="$T/state"
mkdir -p "$R" "$H" "$S"

git -C "$R" init -qb main
git -C "$R" config user.email "fixture@example"
git -C "$R" config user.name "fixture"
git -C "$R" config commit.gpgsign false
GCOMMIT=(-c user.email=fixture@example -c user.name=fixture -c commit.gpgsign=false commit -qm)

# rev0: payload without any registry (target-refusal fixture).
mkdir -p "$R/dots/.config/app"
printf 'same\n' > "$R/dots/.config/app/keep.conf"
git -C "$R" add -A
git -C "$R" "${GCOMMIT[@]}" "rev zero no registry"
REV_NONE=$(git -C "$R" rev-parse HEAD)

# revB: full baseline payload + registry.
mkdir -p "$R/dots/.config/hypr/custom" "$R/dots/.config/fontconfig"
mkdir -p "$R/dots-extra/fontsets/fs" "$R/sdata/deploy"
payload_b(){
  printf 'same\n' > "$R/dots/.config/app/keep.conf"
  printf 'v1\n' > "$R/dots/.config/app/change.conf"
  printf 'bye\n' > "$R/dots/.config/app/drop.conf"
  printf 'bye2\n' > "$R/dots/.config/app/staledrift.conf"
  printf 'v1\n' > "$R/dots/.config/app/wasdrift.conf"
  printf 'v1\n' > "$R/dots/.config/app/moved.conf"
  printf 'v1\n' > "$R/dots/.config/app/steady.conf"
  printf 'v1\n' > "$R/dots/.config/app/back.conf"
  printf 'v1\n' > "$R/dots/.config/app/rmd.conf"
  printf 'v1\n' > "$R/dots/.config/app/rmd2.conf"
  printf 'disk-v\n' > "$R/dots/.config/app/rmdgone.conf"
  printf 'v1\n' > "$R/dots/.config/app/rmdgone.conf.tmp"
  printf 'install-me\n' > "$R/dots/.config/app/gone.conf"
  printf 'install-me2\n' > "$R/dots/.config/app/appeared.conf"
  printf 'v1\n' > "$R/dots/.config/app/conv.conf"
  printf 'regfile\n' > "$R/dots/.config/app/type.conf"
  printf 'reclass-me\n' > "$R/dots/.config/app/reclass.conf"
  ln -s ta "$R/dots/.config/app/stfx.conf"
  ln -s ta "$R/dots/.config/app/stdiv.conf"
  ln -s ta "$R/dots/.config/app/stchg.conf"
  ln -s ta "$R/dots/.config/app/stfile.conf"
  ln -s ta "$R/dots/.config/app/stlate.conf"
  printf 'install-me3\n' > "$R/dots/.config/app/gone2.conf"
  printf 'lock\n' > "$R/dots/.config/app/locked.conf"
  printf 'x\n' > "$R/dots/.config/app/weirdname.conf"
  printf 'seed\n' > "$R/dots/.config/hypr/custom/seed.lua"
  printf 'oldseed\n' > "$R/dots/.config/hypr/custom/oldseed.lua"
  printf 'repo idle\n' > "$R/dots/.config/hypr/hypridle.conf"
  printf 'repo idle3\n' > "$R/dots/.config/hypr/idle3.conf"
  printf 'default fonts\n' > "$R/dots/.config/fontconfig/fonts.conf"
  printf 'fs fonts\n' > "$R/dots-extra/fontsets/fs/fonts.conf"
}
payload_b
# rmdgone.conf must hold v1 in the repo (live holds drifted disk-v).
printf 'v1\n' > "$R/dots/.config/app/rmdgone.conf"
rm -f "$R/dots/.config/app/rmdgone.conf.tmp"
cat > "$R/sdata/deploy/ownership.conf" <<'EOF'
managed dots/.config/app .config/app
managed dots/.config/fontconfig .config/fontconfig
sidecar dots/.config/hypr/hypridle.conf .config/hypr/hypridle.conf
sidecar dots/.config/hypr/idle3.conf .config/hypr/idle3.conf
user dots/.config/hypr/custom .config/hypr/custom
EOF
EMPTY_TREE=$(git -C "$R" hash-object -t tree /dev/null)
git -C "$R" add -A
git -C "$R" "${GCOMMIT[@]}" "rev base"
git -C "$R" update-index --add --cacheinfo "160000,${EMPTY_TREE},dots/.config/app/sub"
git -C "$R" update-index --add --cacheinfo "160000,${EMPTY_TREE},dots/.config/app/sub2"
git -C "$R" update-index --add --cacheinfo "160000,${EMPTY_TREE},dots/.config/app/sub4"
git -C "$R" "${GCOMMIT[@]}" "rev base plus gitlinks"
# Mini submodule source for the diverged case (local only, no network).
SUBSRC="$T/subsrc"
git init -qb main "$SUBSRC"
git -C "$SUBSRC" config user.email "fixture@example"
git -C "$SUBSRC" config user.name "fixture"
git -C "$SUBSRC" config commit.gpgsign false
printf 'a\n' > "$SUBSRC/f"
git -C "$SUBSRC" add -A
git -C "$SUBSRC" "${GCOMMIT[@]}" "sub A"
SUB_A=$(git -C "$SUBSRC" rev-parse HEAD)
printf 'b\n' > "$SUBSRC/f"
git -C "$SUBSRC" add -A
git -C "$SUBSRC" "${GCOMMIT[@]}" "sub B"
SUB_B=$(git -C "$SUBSRC" rev-parse HEAD)
# NOTE: no .git file inside the REPO worktree (it would make `git add`
# register an embedded repo and fight the fabricated gitlink below).
# The live HOME copy does carry the gitfile pointer for observation.
# NOTE: no bare `git add -A` from here on: with fabricated gitlinks in the
# index and no worktree presence, it would stage their deletion. All staging
# below names explicit paths.
git -C "$R" update-index --add --cacheinfo "160000,${SUB_A},dots/.config/app/sub5"
git -C "$R" "${GCOMMIT[@]}" "rev base plus diverged gitlink"
REV_B=$(git -C "$R" rev-parse HEAD)

# Live home as of adoption.
mkdir -p "$H/.config/app/sub" "$H/.config/app/sub4" "$H/.config/app/sub5"
mkdir -p "$H/.config/hypr/custom" "$H/.config/fontconfig"
printf 'gitdir: %s/.git\n' "$SUBSRC" > "$H/.config/app/sub5/.git"
printf 'same\n' > "$H/.config/app/keep.conf"
printf 'v1\n' > "$H/.config/app/change.conf"
printf 'bye\n' > "$H/.config/app/drop.conf"
printf 'disk\n' > "$H/.config/app/staledrift.conf"
printf 'disk-v\n' > "$H/.config/app/wasdrift.conf"
printf 'disk-v\n' > "$H/.config/app/moved.conf"
printf 'disk-v\n' > "$H/.config/app/steady.conf"
printf 'disk-v\n' > "$H/.config/app/back.conf"
printf 'v1\n' > "$H/.config/app/rmd.conf"
printf 'v1\n' > "$H/.config/app/rmd2.conf"
printf 'disk-v\n' > "$H/.config/app/rmdgone.conf"
printf 'disk-v\n' > "$H/.config/app/conv.conf"
printf 'regfile\n' > "$H/.config/app/type.conf"
printf 'reclass-me\n' > "$H/.config/app/reclass.conf"
ln -s ta "$H/.config/app/stfx.conf"
ln -s ta "$H/.config/app/stdiv.conf"
ln -s tb "$H/.config/app/stchg.conf"
ln -s ta "$H/.config/app/stlate.conf"
printf 'user replaced the link\n' > "$H/.config/app/stfile.conf"
printf 'lock\n' > "$H/.config/app/locked.conf"
printf 'x\n' > "$H/.config/app/weirdname.conf"
printf 'seed\n' > "$H/.config/hypr/custom/seed.lua"
printf 'oldseed\n' > "$H/.config/hypr/custom/oldseed.lua"
printf 'repo idle\n' > "$H/.config/hypr/hypridle.conf"
printf 'repo idle3\n' > "$H/.config/hypr/idle3.conf"
printf 'default fonts\n' > "$H/.config/fontconfig/fonts.conf"
printf 'legacy weak evidence\n' > "$H/.config/app/retired.conf"
mkdir -p "$H/.config/illogical-impulse"
printf '%s/.config/app/keep.conf\n' "$H" > "$H/.config/illogical-impulse/installed_listfile"
printf '%s/.config/app/retired.conf\n' "$H" >> "$H/.config/illogical-impulse/installed_listfile"
printf '/outside/home\n' >> "$H/.config/illogical-impulse/installed_listfile"

adopt_run(){
  local at="$1" home="$2" statedir="$3" mode="$4" extra_env="${5:-}"
  (
    export REPO_ROOT="$R" DEPLOY_LIB_DIR="$LIBDIR"
    unset FONTSET_DIR_NAME INSTALL_VIA_NIX
    # shellcheck disable=SC2086
    eval "$extra_env"
    DEPLOY_AT="$at" DEPLOY_HOME_DIR="$home" DEPLOY_STATE_DIR="$statedir"
    DEPLOY_WANT_APPLY=false DEPLOY_WANT_STATUS=false DEPLOY_WANT_DRYRUN=false
    case "$mode" in
      apply) DEPLOY_WANT_APPLY=true;;
      status) DEPLOY_WANT_STATUS=true;;
    esac
    # shellcheck disable=SC1091
    source "${ADOPTDIR}/0.run.sh"
  )
}
plan_run(){
  local at="$1" home="$2" statedir="$3" extra_env="${4:-}"
  (
    export REPO_ROOT="$R" DEPLOY_LIB_DIR="$LIBDIR"
    unset FONTSET_DIR_NAME INSTALL_VIA_NIX DEPLOY_PLAN_FONTSET DEPLOY_PLAN_VIANIX_SET
    # shellcheck disable=SC2086
    eval "$extra_env"
    DEPLOY_AT="$at" DEPLOY_HOME_DIR="$home" DEPLOY_STATE_DIR="$statedir"
    DEPLOY_PLAN_FONTSET_SET=false DEPLOY_PLAN_VIANIX_SET=false
    case "$extra_env" in
      *DEPLOY_PLAN_FONTSET=*) DEPLOY_PLAN_FONTSET_SET=true;;
    esac
    case "$extra_env" in
      *DEPLOY_PLAN_VIANIX_SET=true*) DEPLOY_PLAN_VIANIX_SET=true;;
    esac
    # shellcheck disable=SC1091
    source "${PLANDIR}/0.run.sh"
  )
}

echo "--- adopt baseline ---"
adopt_run "$REV_B" "$H" "$S" apply > /dev/null 2>&1
[[ $? == 0 ]] && pass "fixture adoption succeeds" || fail "fixture adoption succeeds"

# revT: payload evolution + one registry reclassification.
printf 'v2\n' > "$R/dots/.config/app/change.conf"
printf 'v2\n' > "$R/dots/.config/app/wasdrift.conf"
printf 'v2\n' > "$R/dots/.config/app/back.conf"
printf 'v2\n' > "$R/dots/.config/app/conv.conf"
printf 'v3\n' > "$R/dots/.config/app/new.conf"
printf 'user-unrelated\n' > "$R/dots/.config/app/newpresent.conf"
printf 'v3\n' > "$R/dots/.config/app/newmatch.conf"
printf 'repo idle2\n' > "$R/dots/.config/hypr/idle2.conf"
rm "$R/dots/.config/app/stdiv.conf"
ln -s tb "$R/dots/.config/app/stdiv.conf"
git -C "$R" rm -q dots/.config/app/drop.conf dots/.config/app/staledrift.conf dots/.config/hypr/idle3.conf dots/.config/app/gone2.conf
rm "$R/dots/.config/app/type.conf"
ln -s target-t "$R/dots/.config/app/type.conf"
printf 'managed dots/.config/app .config/app\nmanaged dots/.config/fontconfig .config/fontconfig\nsidecar dots/.config/hypr/hypridle.conf .config/hypr/hypridle.conf\nsidecar dots/.config/hypr/idle2.conf .config/hypr/idle2.conf\nuser dots/.config/hypr/custom .config/hypr/custom\nuser dots/.config/app/reclass.conf .config/app/reclass.conf\n' > "$R/sdata/deploy/ownership.conf"
# Explicit pathspec staging only: a bare `git add -A` would stage deletion
# of the fabricated gitlinks (no worktree presence) and destroy the fixture.
git -C "$R" add -- dots/.config/app/change.conf dots/.config/app/wasdrift.conf dots/.config/app/back.conf dots/.config/app/conv.conf dots/.config/app/new.conf dots/.config/app/newpresent.conf dots/.config/app/newmatch.conf dots/.config/hypr/idle2.conf dots/.config/app/type.conf dots/.config/app/stdiv.conf sdata/deploy/ownership.conf
git -C "$R" update-index --add --cacheinfo "160000,${EMPTY_TREE},dots/.config/app/sub6"
git -C "$R" update-index --add --cacheinfo "160000,${SUB_B},dots/.config/app/sub4"
git -C "$R" "${GCOMMIT[@]}" "rev target"
REV_T=$(git -C "$R" rev-parse HEAD)

# Live home evolves to "now".
printf 'disk-v2\n' > "$H/.config/app/moved.conf"
rm "$H/.config/app/rmd2.conf" "$H/.config/app/rmdgone.conf"
printf 'user-made\n' > "$H/.config/app/appeared.conf"
printf 'v2\n' > "$H/.config/app/conv.conf"
printf 'v1\n' > "$H/.config/app/back.conf"
printf 'user-made\n' > "$H/.config/app/newpresent.conf"
printf 'v3\n' > "$H/.config/app/newmatch.conf"
chmod 000 "$H/.config/app/locked.conf"
# Retarget a confirmed link after adoption: the explicit gate must fire.
rm "$H/.config/app/stlate.conf"
ln -s tb "$H/.config/app/stlate.conf"

echo "--- plan ops ---"
PLAN_TSV=$(plan_run "$REV_T" "$H" "$S" 2>/dev/null)
[[ $? == 0 ]] && pass "plan exits 0 with conflicts present" || fail "plan exits 0 with conflicts present"
row_for(){ awk -F'\t' -v s="$2" -v p="$3" '$1==s && $3==p' <<<"$1"; }
expect_op(){
  if [[ -n "$(row_for "$1" "$2" "$3")" ]]; then pass "$2 :: $3"; else fail "$2 :: $3"; fi
}
expect_op "$PLAN_TSV" unchanged .config/app/keep.conf
expect_op "$PLAN_TSV" unchanged .config/app/rmd.conf
expect_op "$PLAN_TSV" unchanged .config/app/weirdname.conf
expect_op "$PLAN_TSV" unchanged .config/hypr/hypridle.conf
expect_op "$PLAN_TSV" unchanged .config/fontconfig/fonts.conf
expect_op "$PLAN_TSV" update .config/app/change.conf
expect_op "$PLAN_TSV" update .config/app/back.conf
expect_op "$PLAN_TSV" delete-stale .config/app/drop.conf
expect_op "$PLAN_TSV" delete-blocked .config/app/staledrift.conf
expect_op "$PLAN_TSV" drift-update .config/app/wasdrift.conf
expect_op "$PLAN_TSV" drift-unchanged .config/app/steady.conf
expect_op "$PLAN_TSV" drift-moved .config/app/moved.conf
expect_op "$PLAN_TSV" drift-removed .config/app/rmdgone.conf
expect_op "$PLAN_TSV" missing-unchanged .config/app/gone.conf
expect_op "$PLAN_TSV" appeared .config/app/appeared.conf
expect_op "$PLAN_TSV" converged .config/app/conv.conf
expect_op "$PLAN_TSV" converged .config/app/newmatch.conf
expect_op "$PLAN_TSV" add .config/app/new.conf
expect_op "$PLAN_TSV" appeared .config/app/newpresent.conf
expect_op "$PLAN_TSV" conflict-removed .config/app/rmd2.conf
expect_op "$PLAN_TSV" update .config/app/type.conf
expect_op "$PLAN_TSV" class-changed .config/app/reclass.conf
expect_op "$PLAN_TSV" sidecar-new .config/hypr/idle2.conf
expect_op "$PLAN_TSV" retired .config/hypr/idle3.conf
expect_op "$PLAN_TSV" conflict-drift .config/app/locked.conf
expect_op "$PLAN_TSV" unchanged .config/app/stfx.conf
expect_op "$PLAN_TSV" update .config/app/stdiv.conf
expect_op "$PLAN_TSV" drift-moved .config/app/stchg.conf
expect_op "$PLAN_TSV" drift-moved .config/app/stfile.conf
expect_op "$PLAN_TSV" drift-moved .config/app/stfile.conf
if row_for "$PLAN_TSV" conflict-drift .config/app/stlate.conf | grep -q "symlink-target-differs-from-baseline"; then
  pass "retargeted confirmed link explicitly distrusted"
else
  fail "retargeted confirmed link explicitly distrusted"
fi
expect_op "$PLAN_TSV" preserved .config/hypr/custom/seed.lua
expect_op "$PLAN_TSV" preserved .config/hypr/custom/oldseed.lua
expect_op "$PLAN_TSV" submodule-ok .config/app/sub
expect_op "$PLAN_TSV" submodule-missing .config/app/sub2
expect_op "$PLAN_TSV" submodule-update-available .config/app/sub4
expect_op "$PLAN_TSV" submodule-diverged .config/app/sub5
expect_op "$PLAN_TSV" add .config/app/sub6
expect_op "$PLAN_TSV" gone .config/app/gone2.conf
[[ "$(awk -F'\t' '$1=="delete-stale"' <<<"$PLAN_TSV" | wc -l)" == 1 ]] \
  && pass "exactly one deletable path" || fail "exactly one deletable path"
[[ "$(awk -F'\t' '$1=="update"' <<<"$PLAN_TSV" | wc -l)" == 4 ]] \
  && pass "exactly four clean updates (incl. pristine link retarget)" || fail "exactly four clean updates (incl. pristine link retarget)"
if row_for "$PLAN_TSV" delete-stale .config/app/staledrift.conf | grep -q .; then
  fail "drifted path must never be delete-stale"
else
  pass "deletion safety holds"
fi
# TSV shape: 8 columns on every data row.
if awk -F'\t' '$1 !~ /^#/ && NF != 8 {bad=1} END{exit bad+0}' <<<"$PLAN_TSV"; then
  pass "tsv has 8 columns"
else
  fail "tsv has 8 columns"
fi

echo "--- plan at baseline rev (sanity) ---"
PLAN_SAME=$(plan_run "$REV_B" "$H" "$S" 2>/dev/null)
[[ $? == 0 ]] && pass "plan at baseline exits 0" || fail "plan at baseline exits 0"
expect_op "$PLAN_SAME" unchanged .config/app/keep.conf
expect_op "$PLAN_SAME" drift-unchanged .config/app/steady.conf
expect_op "$PLAN_SAME" missing-unchanged .config/app/gone.conf
if grep -Eq "^(update|add|delete-stale|sidecar-new)	" <<<"$PLAN_SAME"; then
  fail "no writes proposed against identical baseline"
else
  pass "no writes proposed against identical baseline"
fi

echo "--- inputs override ---"
PLAN_FS=$(plan_run "$REV_T" "$H" "$S" "DEPLOY_PLAN_FONTSET=fs" 2>"$T/fs.err")
[[ $? == 0 ]] && pass "fontset override plans" || fail "fontset override plans"
expect_op "$PLAN_FS" update .config/fontconfig/fonts.conf
grep -q "excluded-by-input: 1" "$T/fs.err" \
  && pass "swapped-away source reported, not silent" || fail "swapped-away source reported, not silent"

echo "--- refusals ---"
plan_run "$REV_NONE" "$H" "$S" > /dev/null 2>&1
[[ $? == 2 ]] && pass "target without registry refused" || fail "target without registry refused"
mkdir -p "$T/otherhome"
plan_run "$REV_T" "$T/otherhome" "$S" > /dev/null 2>&1
[[ $? == 2 ]] && pass "foreign home refused" || fail "foreign home refused"
S_BAD="$T/s-bad"
mkdir -p "$S_BAD"
cp "$S/manifest.jsonl" "$S_BAD/manifest.jsonl"
plan_run "$REV_T" "$H" "$S_BAD" > /dev/null 2>&1
[[ $? == 2 ]] && pass "manifest-without-identity refused" || fail "manifest-without-identity refused"
S_TAMP="$T/s-tamp"
cp -r "$S" "$S_TAMP"
sed -i '0,/"rev":"/s//"rev":"0/' "$S_TAMP/manifest.jsonl"
plan_run "$REV_T" "$H" "$S_TAMP" > /dev/null 2>&1
[[ $? == 2 ]] && pass "mixed-revision manifest refused" || fail "mixed-revision manifest refused"
S_MIX="$T/s-mix"
mkdir -p "$S_MIX"
sed "s/$REV_B/0000000000000000000000000000000000000000/" "$S/deployment-identity.json" > "$S_MIX/deployment-identity.json"
cp "$S/manifest.jsonl" "$S_MIX/manifest.jsonl"
cp "$S/legacy-evidence.jsonl" "$S_MIX/legacy-evidence.jsonl" 2>/dev/null || true
plan_run "$REV_T" "$H" "$S_MIX" > /dev/null 2>&1
[[ $? == 2 ]] && pass "tampered identity refused" || fail "tampered identity refused"

echo "--- baseline integrity tripwire ---"
S_INC="$T/s-inc"
cp -r "$S" "$S_INC"
# Corrupt one confirmed row AND re-seal the identity: this simulates a buggy
# writer, not post-hoc tampering (which the sha seal already catches).
python3 - "$S_INC/manifest.jsonl" "$S_INC/deployment-identity.json" <<'EOF'
import json, sys, hashlib, re
mp, ip = sys.argv[1], sys.argv[2]
rows = [json.loads(l) for l in open(mp)]
for r in rows:
    if r['status'] == 'confirmed' and r['kind'] == 'file':
        r['disk'] = '0' * 40
        break
# Compact separators: the manifest reader assumes the generator's exact
# byte format (no spaces), so the rewrite must preserve it.
blob = ''.join(json.dumps(r, separators=(',', ':')) + '\n' for r in rows)
open(mp, 'w').write(blob)
sha = hashlib.sha256(blob.encode()).hexdigest()
ident = open(ip).read()
ident = re.sub(r'"manifest_sha256": "[0-9a-f]*"', '"manifest_sha256": "%s"' % sha, ident)
open(ip, 'w').write(ident)
EOF
PLAN_INC=$(plan_run "$REV_T" "$H" "$S_INC" 2>/dev/null)
[[ $? == 0 ]] && pass "plan runs over inconsistent baseline" || fail "plan runs over inconsistent baseline"
if grep -q "baseline-record-inconsistent" <<<"$PLAN_INC"; then
  pass "inconsistent confirmed row distrusted, never applied"
else
  fail "inconsistent confirmed row distrusted, never applied"
fi
if grep -Eq "^update	.*keep.conf" <<<"$PLAN_INC"; then
  fail "inconsistent row must not propose update"
else
  pass "inconsistent row must not propose update"
fi

echo "--- byte-format independence ---"
S_FMT="$T/s-fmt"
mkdir -p "$S_FMT"
# Semantically identical state, hostile formatting: pretty-printed,
# sorted keys, extra blank lines. Record counts are semantic (values per
# file, not lines), so only the byte seal needs refreshing.
jq -S . "$S/deployment-identity.json" > "$S_FMT/deployment-identity.json"
jq -S . "$S/manifest.jsonl" > "$S_FMT/manifest.jsonl"
printf '\n\n' >> "$S_FMT/manifest.jsonl"
jq -S . "$S/legacy-evidence.jsonl" > "$S_FMT/legacy-evidence.jsonl"
FMT_SHA=$(sha256sum "$S_FMT/manifest.jsonl" | awk '{print $1}')
FMT_M=$(jq -s 'length' "$S_FMT/manifest.jsonl")
FMT_E=$(jq -s 'length' "$S_FMT/legacy-evidence.jsonl")
jq --arg sha "$FMT_SHA" --argjson m "$FMT_M" --argjson e "$FMT_E" \
  '.manifest_sha256 = $sha | .manifest_records = $m | .legacy_evidence_records = $e' \
  "$S_FMT/deployment-identity.json" > "$S_FMT/identity.tmp" && mv "$S_FMT/identity.tmp" "$S_FMT/deployment-identity.json"
PLAN_FMT=$(plan_run "$REV_T" "$H" "$S_FMT" 2>/dev/null)
[[ $? == 0 ]] && pass "reformatted state plans" || fail "reformatted state plans"
if [[ "$(sort <<<"$PLAN_TSV")" == "$(sort <<<"$PLAN_FMT")" ]]; then
  pass "reformatted state plans identically"
else
  fail "reformatted state plans identically"
fi

echo "--- jq availability gate ---"
if PATH="/nonexistent" "$BASH" -c 'source "$0" 2>/dev/null; deploy_require_jq' "$LIBDIR/deploy-common.sh" 2>/dev/null; then
  fail "missing jq fails closed"
else
  pass "missing jq fails closed"
fi
if PATH="/nonexistent" "$BASH" -c 'source "$0"; deploy_require_jq' "$LIBDIR/deploy-common.sh" 2>"$T/jqmsg"; then
  fail "missing jq message"
elif grep -q "jq.*required" "$T/jqmsg"; then
  pass "missing jq names the dependency"
else
  fail "missing jq names the dependency"
fi
deploy_require_jq && pass "present jq passes" || fail "present jq passes"

echo "--- legacy section ---"
if grep -q "^legacy	-	.config/app/keep.conf" <<<"$PLAN_TSV"; then
  pass "legacy overlap marked"
else
  fail "legacy overlap marked"
fi
if grep -q "^legacy	-	.config/app/retired.conf" <<<"$PLAN_TSV"; then
  pass "weak-only legacy listed"
else
  fail "weak-only legacy listed"
fi

echo "--- zero-write proof ---"
REFLOG_B=$(git -C "$R" log -g --format=%H HEAD | head -n 1)
STATUS_B=$(git -C "$R" status --porcelain=v1)
plan_run "$REV_T" "$H" "$S" > /dev/null 2>&1
[[ "$(git -C "$R" log -g --format=%H HEAD | head -n 1)" == "$REFLOG_B" ]] && pass "reflog frozen" || fail "reflog frozen"
[[ "$(git -C "$R" status --porcelain=v1)" == "$STATUS_B" ]] && pass "worktree untouched" || fail "worktree untouched"
chmod 644 "$H/.config/app/locked.conf"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
