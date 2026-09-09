#!/usr/bin/env bash
#
# Fixture tests for `setup adopt --reconcile`: re-evaluating an
# already-adopted machine under a changed ownership registry without
# touching deployed/user files and without inventing deployment provenance.
#
# Drifted/missing rows must survive re-baselining byte-identically (except
# the baseline rev); reclassification must move rows between manifest and
# informational state instead of laundering them into confirmed.
# Read-only with respect to the real machine: everything lives under $T.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBDIR="${HERE}/../../lib"
ADOPTDIR="${HERE}/../../subcmd-adopt"
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

T="$(mktemp -d /tmp/deploy-reconcile-XXXXXX)"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$T"' EXIT

R="$T/repo"
mkdir -p "$R"
git -C "$R" init -qb main
git -C "$R" config user.email "fixture@example"
git -C "$R" config user.name "fixture"
git -C "$R" config commit.gpgsign false
GCOMMIT=(-c user.email=fixture@example -c user.name=fixture -c commit.gpgsign=false commit -qm)
export REPO_ROOT="$R"

mkdir -p "$R/dots/.config/app/um" "$R/dots/.config/hypr/custom" "$R/sdata/deploy"
printf 'same\n' > "$R/dots/.config/app/keep.conf"
printf 'v1\n' > "$R/dots/.config/app/staydrift.conf"
printf 'v1\n' > "$R/dots/.config/app/gone-missing.conf"
printf 'v1\n' > "$R/dots/.config/app/todemote.conf"
printf 'v1\n' > "$R/dots/.config/app/um/um-match.conf"
printf 'v1\n' > "$R/dots/.config/app/um/um-drift.conf"
printf 'v1\n' > "$R/dots/.config/app/um/um-miss.conf"
ln -s ta "$R/dots/.config/app/link.conf"
ln -s ta "$R/dots/.config/app/linkdrift.conf"
printf 'v1 side\n' > "$R/dots/.config/hypr/side.conf"
printf 'v1 clean\n' > "$R/dots/.config/hypr/sideclean.conf"
printf 'seed\n' > "$R/dots/.config/hypr/custom/seed.lua"
cat > "$R/sdata/deploy/ownership.conf" <<'EOF'
managed dots/.config/app .config/app
user dots/.config/app/um .config/app/um
sidecar dots/.config/hypr/side.conf .config/hypr/side.conf
sidecar dots/.config/hypr/sideclean.conf .config/hypr/sideclean.conf
user dots/.config/hypr/custom .config/hypr/custom
EOF
git -C "$R" add -A
git -C "$R" "${GCOMMIT[@]}" "rev one"
REV_ONE=$(git -C "$R" rev-parse HEAD)

# rev2: um/ becomes managed; todemote.conf becomes exact-file user;
# keep.conf becomes exact-file sidecar. Payload bytes are untouched.
cat > "$R/sdata/deploy/ownership.conf" <<'EOF'
managed dots/.config/app .config/app
managed dots/.config/app/um .config/app/um
user dots/.config/app/todemote.conf .config/app/todemote.conf
sidecar dots/.config/app/keep.conf .config/app/keep.conf
sidecar dots/.config/hypr/side.conf .config/hypr/side.conf
sidecar dots/.config/hypr/sideclean.conf .config/hypr/sideclean.conf
user dots/.config/hypr/custom .config/hypr/custom
EOF
git -C "$R" add -A
git -C "$R" "${GCOMMIT[@]}" "rev two reclassifies"
REV_TWO=$(git -C "$R" rev-parse HEAD)
BLOB_V1=$(git -C "$R" rev-parse "$REV_TWO:dots/.config/app/um/um-match.conf")
LIVE_HASH_DISKV=$(printf 'disk-v\n' | git -C "$R" hash-object --stdin)

H0="$T/home0"
mkdir -p "$H0/.config/app/um" "$H0/.config/hypr/custom" "$H0/.config/illogical-impulse"
printf 'same\n' > "$H0/.config/app/keep.conf"
printf 'disk-v\n' > "$H0/.config/app/staydrift.conf"
printf 'disk-v\n' > "$H0/.config/app/todemote.conf"
printf 'v1\n' > "$H0/.config/app/um/um-match.conf"
printf 'disk-v\n' > "$H0/.config/app/um/um-drift.conf"
ln -s ta "$H0/.config/app/link.conf"
ln -s tb "$H0/.config/app/linkdrift.conf"
printf 'disk-side\n' > "$H0/.config/hypr/side.conf"
printf 'v1 clean\n' > "$H0/.config/hypr/sideclean.conf"
printf 'seed\n' > "$H0/.config/hypr/custom/seed.lua"
printf '%s/.config/app/keep.conf\n' "$H0" > "$H0/.config/illogical-impulse/installed_listfile"

# Drive 0.run.sh the way options.sh would (its `exit`s stay in the subshell).
adopt_run(){
  local at="$1" home="$2" statedir="$3" mode="$4" extra_env="${5:-}"
  (
    export REPO_ROOT="$R" DEPLOY_LIB_DIR="$LIBDIR"
    unset FONTSET_DIR_NAME INSTALL_VIA_NIX
    # shellcheck disable=SC2086
    eval "$extra_env"
    DEPLOY_AT="$at" DEPLOY_HOME_DIR="$home" DEPLOY_STATE_DIR="$statedir"
    DEPLOY_WANT_APPLY=false DEPLOY_WANT_STATUS=false DEPLOY_WANT_DRYRUN=false DEPLOY_WANT_RECONCILE=false
    case "$mode" in
      apply) DEPLOY_WANT_APPLY=true;;
      status) DEPLOY_WANT_STATUS=true;;
      reconcile) DEPLOY_WANT_RECONCILE=true;;
    esac
    # shellcheck disable=SC1091
    source "${ADOPTDIR}/0.run.sh"
  )
}
mrow(){ python3 -c "import json,sys; rows=[json.loads(l) for l in open(sys.argv[1])]; r=[x for x in rows if x['path']==sys.argv[2]]; print(json.dumps(r[0], sort_keys=True) if r else 'ABSENT')" "$1" "$2"; }

echo "--- baseline adoption at rev1 ---"
cp -r "$H0" "$T/h-home"
printf '%s/.config/app/keep.conf\n' "$T/h-home" > "$T/h-home/.config/illogical-impulse/installed_listfile"
adopt_run "$REV_ONE" "$T/h-home" "$T/h-state" apply > /dev/null 2>&1
[[ $? == 0 ]] && pass "baseline apply exits 0" || fail "baseline apply exits 0"
# Give the baseline proven-deployment provenance (seal covers the manifest
# only, so this keeps status green while exercising preservation).
jq '.deployed_revision = "'"$REV_ONE"'" | .last_apply = {"id":"fixture","target":"'"$REV_ONE"'","finished":"2026-01-01T00:00:00Z","outcome":"complete"}' \
  "$T/h-state/deployment-identity.json" > "$T/h-state/deployment-identity.json.new" \
  && mv "$T/h-state/deployment-identity.json.new" "$T/h-state/deployment-identity.json"
adopt_run "$REV_ONE" "$T/h-home" "$T/h-state" status > /dev/null 2>&1
[[ $? == 0 ]] && pass "patched identity still verifies" || fail "patched identity still verifies"
OLD_ADOPTED_AT=$(jq -r '.adopted_at' "$T/h-state/deployment-identity.json")
EV_PRE=$(jq -s 'length' "$T/h-state/legacy-evidence.jsonl")
cp "$T/h-state/manifest.jsonl" "$T/baseline-manifest.jsonl"
HOME_SNAP_BEFORE="$T/home.snap"
(cd "$T/h-home" && find . \( -type f -exec sha256sum {} + \; -o -type l -printf 'L %p -> %l\n' \) 2>/dev/null | sort) > "$HOME_SNAP_BEFORE"
REPO_STATUS_BEFORE=$(git -C "$R" status --porcelain=v1)
REFLOG_BEFORE=$(git -C "$R" log -g --format=%H HEAD | head -n 1)

echo "--- reconcile at rev2 ---"
adopt_run "$REV_TWO" "$T/h-home" "$T/h-state" reconcile > "$T/reconcile-main.out" 2>&1
[[ $? == 0 ]] && pass "reconcile exits 0" || fail "reconcile exits 0: $(tail -n 3 "$T/reconcile-main.out")"
adopt_run "$REV_TWO" "$T/h-home" "$T/h-state" status > /dev/null 2>&1
[[ $? == 0 ]] && pass "status adoption-complete after reconcile" || fail "status adoption-complete after reconcile"

echo "--- managed->user demotion drops the row ---"
[[ "$(mrow "$T/h-state/manifest.jsonl" ".config/app/todemote.conf")" == "ABSENT" ]] \
  && pass "demoted path has no manifest row" || fail "demoted path has no manifest row"

echo "--- user->managed promotion observes honestly ---"
UM_MATCH=$(mrow "$T/h-state/manifest.jsonl" ".config/app/um/um-match.conf")
[[ "$UM_MATCH" == *"\"status\": \"confirmed\""* && "$UM_MATCH" == *"\"blob\": \"$BLOB_V1\""* && "$UM_MATCH" == *"\"disk\": \"$BLOB_V1\""* && "$UM_MATCH" == *"\"rev\": \"$REV_TWO\""* ]] \
  && pass "promoted match is confirmed@rev2" || fail "promoted match is confirmed@rev2: $UM_MATCH"
UM_DRIFT=$(mrow "$T/h-state/manifest.jsonl" ".config/app/um/um-drift.conf")
[[ "$UM_DRIFT" == *"\"status\": \"drifted\""* && "$UM_DRIFT" == *"\"disk\": \"$LIVE_HASH_DISKV\""* ]] \
  && pass "promoted drift stays drifted with live hash" || fail "promoted drift stays drifted: $UM_DRIFT"
UM_MISS=$(mrow "$T/h-state/manifest.jsonl" ".config/app/um/um-miss.conf")
[[ "$UM_MISS" == *"\"status\": \"missing\""* && "$UM_MISS" == *'"disk": null'* ]] \
  && pass "promoted absence stays missing" || fail "promoted absence stays missing: $UM_MISS"

echo "--- pre-existing state is preserved, never laundered ---"
OLD_STAY=$(mrow "$T/baseline-manifest.jsonl" ".config/app/staydrift.conf")
NEW_STAY=$(mrow "$T/h-state/manifest.jsonl" ".config/app/staydrift.conf")
[[ "$NEW_STAY" == *"\"status\": \"drifted\""* && "$NEW_STAY" == *"\"disk\": \"$LIVE_HASH_DISKV\""* ]] \
  && pass "old drift keeps live hash" || fail "old drift keeps live hash: $NEW_STAY"
[[ "$(python3 -c "import json; o=json.loads('$OLD_STAY'); n=json.loads('$NEW_STAY'); o.pop('rev'); n.pop('rev'); print(o==n)")" == "True" ]] \
  && pass "old drift identical except rev" || fail "old drift identical except rev"
[[ "$(mrow "$T/h-state/manifest.jsonl" ".config/app/gone-missing.conf")" == *"\"status\": \"missing\""* ]] \
  && pass "old missing stays missing" || fail "old missing stays missing"
[[ "$(mrow "$T/h-state/manifest.jsonl" ".config/hypr/side.conf")" == *"\"status\": \"drifted\""* ]] \
  && pass "sidecar drift stays drifted" || fail "sidecar drift stays drifted"
[[ "$(mrow "$T/h-state/manifest.jsonl" ".config/hypr/sideclean.conf")" == *"\"status\": \"confirmed\""* ]] \
  && pass "sidecar clean stays confirmed" || fail "sidecar clean stays confirmed"
[[ "$(mrow "$T/h-state/manifest.jsonl" ".config/app/link.conf")" == *"\"status\": \"confirmed\""* && "$(mrow "$T/h-state/manifest.jsonl" ".config/app/link.conf")" == *'"disk": null'* ]] \
  && pass "symlink confirm keeps null disk" || fail "symlink confirm keeps null disk"
[[ "$(mrow "$T/h-state/manifest.jsonl" ".config/app/linkdrift.conf")" == *"\"status\": \"drifted\""* ]] \
  && pass "drifted symlink stays drifted" || fail "drifted symlink stays drifted"
KEEP_ROW=$(mrow "$T/h-state/manifest.jsonl" ".config/app/keep.conf")
[[ "$KEEP_ROW" == *"\"class\": \"sidecar\""* && "$KEEP_ROW" == *"\"status\": \"confirmed\""* ]] \
  && pass "managed->sidecar with matching live becomes confirmed sidecar" || fail "managed->sidecar: $KEEP_ROW"

echo "--- provenance preserved, nothing invented ---"
[[ "$(jq -r '.adopted_at' "$T/h-state/deployment-identity.json")" == "$OLD_ADOPTED_AT" ]] \
  && pass "adopted_at preserved" || fail "adopted_at preserved"
[[ "$(jq -r '.reconciled_from' "$T/h-state/deployment-identity.json")" == "$REV_ONE" ]] \
  && pass "reconciled_from pins old baseline" || fail "reconciled_from pins old baseline"
[[ "$(jq -r '.revision' "$T/h-state/deployment-identity.json")" == "$REV_TWO" ]] \
  && pass "revision advances to reconcile target" || fail "revision advances"
grep -q '"tool": "setup adopt --reconcile"' "$T/h-state/deployment-identity.json" \
  && pass "tool marks reconciliation" || fail "tool marks reconciliation"
[[ "$(jq -r '.deployed_revision' "$T/h-state/deployment-identity.json")" == "$REV_ONE" ]] \
  && pass "deployed_revision preserved" || fail "deployed_revision preserved"
[[ "$(jq -c '.last_apply' "$T/h-state/deployment-identity.json")" == '{"id":"fixture","target":"'"$REV_ONE"'","finished":"2026-01-01T00:00:00Z","outcome":"complete"}' ]] \
  && pass "last_apply preserved verbatim" || fail "last_apply preserved verbatim"
grep -q '"fully_deployed": false' "$T/h-state/deployment-identity.json" \
  && pass "unresolved rows keep fully_deployed false" || fail "fully_deployed false"
[[ "$(jq -s 'length' "$T/h-state/legacy-evidence.jsonl")" == "$EV_PRE" ]] \
  && pass "evidence stable across reconcile" || fail "evidence stable across reconcile"

echo "--- byte-identity oracles ---"
rm -rf "$T/h-fresh" && mkdir -p "$T/h-fresh"
adopt_run "$REV_TWO" "$T/h-home" "$T/h-fresh" apply > /dev/null 2>&1
[[ $? == 0 ]] && pass "fresh adopt at rev2 succeeds" || fail "fresh adopt at rev2 succeeds"
if cmp -s "$T/h-state/manifest.jsonl" "$T/h-fresh/manifest.jsonl"; then
  pass "reconciled manifest equals fresh-adopt manifest"
else
  fail "reconciled manifest equals fresh-adopt manifest"
fi
cp "$T/h-state/manifest.jsonl" "$T/reconciled-once.jsonl"
adopt_run "$REV_TWO" "$T/h-home" "$T/h-state" reconcile > /dev/null 2>&1
[[ $? == 0 ]] && pass "second reconcile exits 0" || fail "second reconcile exits 0"
if cmp -s "$T/reconciled-once.jsonl" "$T/h-state/manifest.jsonl"; then
  pass "reconcile is idempotent"
else
  fail "reconcile is idempotent"
fi

echo "--- zero live/repo mutation ---"
(cd "$T/h-home" && find . \( -type f -exec sha256sum {} + \; -o -type l -printf 'L %p -> %l\n' \) 2>/dev/null | sort) > "$T/home.snap.after"
if cmp -s "$HOME_SNAP_BEFORE" "$T/home.snap.after"; then pass "home tree identical"; else fail "home tree identical"; fi
[[ "$(git -C "$R" status --porcelain=v1)" == "$REPO_STATUS_BEFORE" ]] && pass "worktree+index untouched" || fail "worktree+index untouched"
[[ "$(git -C "$R" log -g --format=%H HEAD | head -n 1)" == "$REFLOG_BEFORE" ]] && pass "reflog frozen" || fail "reflog frozen"

echo "--- planner behavior after reconciliation ---"
(
  export REPO_ROOT="$R" DEPLOY_LIB_DIR="$LIBDIR"
  DEPLOY_HOME="$T/h-home" DEPLOY_XDG_CONFIG="$T/h-home/.config" DEPLOY_XDG_DATA="$T/h-home/.local/share"
  export DEPLOY_HOME DEPLOY_XDG_CONFIG DEPLOY_XDG_DATA
  deploy_plan_load_state "$T/h-state" || exit 1
  deploy_plan_load_target "$REV_TWO" || exit 1
  deploy_plan_compute "$T/h-state" || exit 2
  printf '%s\n' "${DEPLOY_PLAN_ROWS[@]}" > "$T/post-rows.tsv"
)
[[ $? == 0 ]] && pass "plan computes on reconciled state" || fail "plan computes on reconciled state"
if grep -q "^class-changed" "$T/post-rows.tsv"; then fail "no class-changed rows remain"; else pass "no class-changed rows remain"; fi
grep -q $'^preserved\tuser\t.config/app/todemote.conf' "$T/post-rows.tsv" \
  && pass "demoted path plans as preserved" || fail "demoted path plans as preserved"
grep -q $'^missing-unchanged\tmanaged\t.config/app/gone-missing.conf' "$T/post-rows.tsv" \
  && pass "old missing still missing-unchanged" || fail "old missing still missing-unchanged"
grep -q $'^drift-unchanged\tmanaged\t.config/app/staydrift.conf' "$T/post-rows.tsv" \
  && pass "old drift still drift-unchanged" || fail "old drift still drift-unchanged"
grep -q "^unchanged" "$T/post-rows.tsv" && pass "confirmed rows plan as unchanged" || fail "confirmed rows plan as unchanged"

echo "--- refusals ---"
adopt_run "$REV_TWO" "$T/h-home" "$T/no-state" reconcile > /dev/null 2>&1
[[ $? == 2 ]] && pass "absent state refuses (rc2)" || fail "absent state refuses (rc2)"
[[ ! -e "$T/no-state" ]] && pass "absent refusal writes nothing" || fail "absent refusal writes nothing"
cp -r "$T/h-state" "$T/s-corrupt" && chmod -R u+w "$T/s-corrupt"
sed -i 's/"status":"confirmed"/"status":"CONFIRMED"/' "$T/s-corrupt/manifest.jsonl"
adopt_run "$REV_TWO" "$T/h-home" "$T/s-corrupt" reconcile > /dev/null 2>&1
[[ $? == 1 ]] && pass "corrupt state refuses (rc1)" || fail "corrupt state refuses (rc1)"
cp -r "$T/h-state" "$T/s-incomplete" && chmod -R u+w "$T/s-incomplete" && rm "$T/s-incomplete/deployment-identity.json"
adopt_run "$REV_TWO" "$T/h-home" "$T/s-incomplete" reconcile > /dev/null 2>&1
[[ $? == 2 ]] && pass "incomplete state refuses (rc2)" || fail "incomplete state refuses (rc2)"
cp -r "$T/h-state" "$T/s-locked" && chmod -R u+w "$T/s-locked"
sleep 60 &
LOCKPID=$!
printf '%s lock-tx 2026-01-01T00:00:00Z\n' "$LOCKPID" > "$T/s-locked/apply.lock"
adopt_run "$REV_TWO" "$T/h-home" "$T/s-locked" reconcile > "$T/recon-lock.out" 2>&1
[[ $? == 2 ]] && pass "live lock refuses (rc2)" || fail "live lock refuses (rc2)"
grep -q "break-lock" "$T/recon-lock.out" && pass "lock refusal names break-lock" || fail "lock refusal names break-lock"
kill "$LOCKPID" 2>/dev/null || true
wait "$LOCKPID" 2>/dev/null || true
adopt_run "$REV_TWO" "$T/h-home" "$T/s-locked" reconcile > /dev/null 2>&1
[[ $? == 2 ]] && pass "stale lock still refuses (rc2)" || fail "stale lock still refuses (rc2)"
rm "$T/s-locked/apply.lock"
adopt_run "$REV_TWO" "$T/h-home" "$T/s-locked" reconcile > /dev/null 2>&1
[[ $? == 0 ]] && pass "reconcile proceeds after lock cleared" || fail "reconcile proceeds after lock cleared"
mkdir -p "$T/s-open" "$T/s-open/applies/TX" "$T/s-open/snapshots/TX"
cp "$T/h-state/manifest.jsonl" "$T/s-open/manifest.jsonl"
cp "$T/h-state/deployment-identity.json" "$T/s-open/deployment-identity.json"
cp "$T/h-state/legacy-evidence.jsonl" "$T/s-open/legacy-evidence.jsonl"
printf '{"seq":1,"type":"header","apply_id":"TX"}\n' > "$T/s-open/applies/TX/journal.jsonl"
cp "$T/h-state/manifest.jsonl" "$T/s-open/snapshots/TX/manifest.jsonl"
adopt_run "$REV_TWO" "$T/h-home" "$T/s-open" reconcile > /dev/null 2>&1
[[ $? == 2 ]] && pass "open transaction refuses (rc2)" || fail "open transaction refuses (rc2)"
rm -rf "$T/s-open/applies" "$T/s-open/snapshots"
adopt_run "$REV_TWO" "$T/h-home" "$T/s-open" reconcile > /dev/null 2>&1
[[ $? == 0 ]] && pass "reconcile proceeds after txn cleared" || fail "reconcile proceeds after txn cleared"

echo "--- same-rev reconcile is a no-op on the manifest ---"
cp -r "$H0" "$T/hsame-home"
printf '%s/.config/app/keep.conf\n' "$T/hsame-home" > "$T/hsame-home/.config/illogical-impulse/installed_listfile"
adopt_run "$REV_ONE" "$T/hsame-home" "$T/hsame-state" apply > /dev/null 2>&1
cp "$T/hsame-state/manifest.jsonl" "$T/same-before.jsonl"
adopt_run "$REV_ONE" "$T/hsame-home" "$T/hsame-state" reconcile > /dev/null 2>&1
[[ $? == 0 ]] && pass "same-rev reconcile exits 0" || fail "same-rev reconcile exits 0"
if cmp -s "$T/same-before.jsonl" "$T/hsame-state/manifest.jsonl"; then
  pass "same-rev reconcile leaves manifest identical"
else
  fail "same-rev reconcile leaves manifest identical"
fi

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
