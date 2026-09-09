#!/usr/bin/env bash
#
# Fixture tests for the Slice 3B write engine (deploy-apply.sh +
# subcmd-apply/decide flows). Drives lib entries directly with the same
# global contract as the subcommands (plus one real-entrypoint suite in
# test-apply-entrypoint.sh). Everything lives under $T; the real $HOME,
# repo, and network are never touched.

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
# shellcheck source=../lib/deploy-decide.sh
source "${LIBDIR}/deploy-decide.sh"
# shellcheck source=../lib/deploy-apply.sh
source "${LIBDIR}/deploy-apply.sh"

PASS=0
FAIL=0
pass(){ PASS=$((PASS+1)); echo "PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }

T="$(mktemp -d /tmp/deploy-apply-XXXXXX)"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$T"' EXIT

R="$T/repo"
mkdir -p "$R"
git -C "$R" init -qb main
git -C "$R" config user.email "fixture@example"
git -C "$R" config user.name "fixture"
git -C "$R" config commit.gpgsign false
GCOMMIT=(-c user.email=fixture@example -c user.name=fixture -c commit.gpgsign=false commit -qm)
export REPO_ROOT="$R"

mkdir -p "$R/dots/.config/app" "$R/dots/.config/hypr/custom" "$R/sdata/deploy"
cat > "$R/sdata/deploy/ownership.conf" <<'EOF'
managed dots/.config/app .config/app
sidecar dots/.config/hypr/hypridle.conf .config/hypr/hypridle.conf
sidecar dots/.config/hypr/side3.conf .config/hypr/side3.conf
sidecar dots/.config/hypr/sc5.conf .config/hypr/sc5.conf
user dots/.config/hypr/custom .config/hypr/custom
EOF
printf 'same\n' > "$R/dots/.config/app/keep.conf"
printf 'v1\n' > "$R/dots/.config/app/upd.conf"
printf '#!/bin/sh\necho hi\n' > "$R/dots/.config/app/exe.sh"
chmod 644 "$R/dots/.config/app/exe.sh"
ln -s ta "$R/dots/.config/app/relink.conf"
printf 'bye\n' > "$R/dots/.config/app/gonebye.conf"
printf 'bye2\n' > "$R/dots/.config/app/staled.conf"
printf 'v1\n' > "$R/dots/.config/app/drift.conf"
printf 'install-me\n' > "$R/dots/.config/app/miss.conf"
printf 'install-me2\n' > "$R/dots/.config/app/miss2.conf"
printf 'v1\n' > "$R/dots/.config/app/keepd.conf"
printf 'seed\n' > "$R/dots/.config/hypr/custom/seed.lua"
printf 'v1 idle\n' > "$R/dots/.config/hypr/hypridle.conf"
printf 'v1 side\n' > "$R/dots/.config/hypr/side3.conf"
printf 'v1 five\n' > "$R/dots/.config/hypr/sc5.conf"
git -C "$R" add -A
git -C "$R" "${GCOMMIT[@]}" "rev base"
EMPTY_TREE=$(git -C "$R" hash-object -t tree /dev/null)
git -C "$R" update-index --add --cacheinfo "160000,${EMPTY_TREE},dots/.config/app/sub"
git -C "$R" update-index --add --cacheinfo "160000,${EMPTY_TREE},dots/.config/app/sub2"
git -C "$R" "${GCOMMIT[@]}" "rev base plus gitlinks"
REV_B=$(git -C "$R" rev-parse HEAD)

# Live template home (copied per case).
H0="$T/home0"
mkdir -p "$H0/.config/app/sub" "$H0/.config/app/sub2" "$H0/.config/hypr/custom" "$H0/.config/illogical-impulse"
printf 'same\n' > "$H0/.config/app/keep.conf"
printf 'v1\n' > "$H0/.config/app/upd.conf"
printf '#!/bin/sh\necho hi\n' > "$H0/.config/app/exe.sh"
chmod 644 "$H0/.config/app/exe.sh"
ln -s ta "$H0/.config/app/relink.conf"
printf 'bye\n' > "$H0/.config/app/gonebye.conf"
printf 'disk\n' > "$H0/.config/app/staled.conf"
printf 'disk-v\n' > "$H0/.config/app/drift.conf"
printf 'disk-v\n' > "$H0/.config/app/keepd.conf"
printf 'seed\n' > "$H0/.config/hypr/custom/seed.lua"
printf 'v1 idle\n' > "$H0/.config/hypr/hypridle.conf"
printf 'disk side3\n' > "$H0/.config/hypr/side3.conf"
printf 'disk side3\n' > "$H0/.config/hypr/side3.conf.new"
printf 'v1 five\n' > "$H0/.config/hypr/sc5.conf"
printf '%s/.config/app/keep.conf\n' "$H0" > "$H0/.config/illogical-impulse/installed_listfile"

# revT: evolution under test.
printf 'v2\n' > "$R/dots/.config/app/upd.conf"
chmod 755 "$R/dots/.config/app/exe.sh"
rm "$R/dots/.config/app/relink.conf"
ln -s tb "$R/dots/.config/app/relink.conf"
git -C "$R" rm -q dots/.config/app/gonebye.conf dots/.config/app/staled.conf
printf 'v2\n' > "$R/dots/.config/app/drift.conf"
printf 'v3\n' > "$R/dots/.config/app/newf.conf"
mkdir -p "$R/dots/.config/app/subdir"
printf 'deep\n' > "$R/dots/.config/app/subdir/newdeep.conf"
printf 'v1 idle\n' > "$R/dots/.config/hypr/hypridle.conf"
printf 'repo idle2\n' > "$R/dots/.config/hypr/idle2.conf"
printf 'v2 side\n' > "$R/dots/.config/hypr/side3.conf"
printf 'v2 five\n' > "$R/dots/.config/hypr/sc5.conf"
cat > "$R/sdata/deploy/ownership.conf" <<'EOF'
managed dots/.config/app .config/app
sidecar dots/.config/hypr/hypridle.conf .config/hypr/hypridle.conf
sidecar dots/.config/hypr/idle2.conf .config/hypr/idle2.conf
sidecar dots/.config/hypr/side3.conf .config/hypr/side3.conf
sidecar dots/.config/hypr/sc5.conf .config/hypr/sc5.conf
user dots/.config/hypr/custom .config/hypr/custom
EOF
git -C "$R" add -- dots/.config/app/upd.conf dots/.config/app/exe.sh dots/.config/app/relink.conf dots/.config/app/drift.conf dots/.config/app/newf.conf dots/.config/app/subdir/newdeep.conf dots/.config/hypr/hypridle.conf dots/.config/hypr/idle2.conf dots/.config/hypr/side3.conf dots/.config/hypr/sc5.conf sdata/deploy/ownership.conf
git -C "$R" "${GCOMMIT[@]}" "rev target"
REV_T=$(git -C "$R" rev-parse HEAD)

# Per-case home+state from template, adopted at REV_B.
fresh_case(){
  local name="$1"
  rm -rf "$T/$name-home" "$T/$name-state"
  cp -r "$H0" "$T/$name-home"
  printf '%s/.config/app/keep.conf\n' "$T/$name-home" > "$T/$name-home/.config/illogical-impulse/installed_listfile"
  (
    export REPO_ROOT="$R" DEPLOY_LIB_DIR="$LIBDIR"
    unset FONTSET_DIR_NAME INSTALL_VIA_NIX
    DEPLOY_AT="$REV_B" DEPLOY_HOME_DIR="$T/$name-home" DEPLOY_STATE_DIR="$T/$name-state"
    DEPLOY_WANT_APPLY=true DEPLOY_WANT_STATUS=false DEPLOY_WANT_DRYRUN=false
    source "${ADOPTDIR}/0.run.sh" > /dev/null 2>&1
  ) || { echo "fixture adoption failed for $name" >&2; return 1; }
}

# Drive lib entries the way subcmd-apply does.
do_prepare(){
  local home="$1" statedir="$2" target="$3" extra_env="${4:-}"
  (
    export REPO_ROOT="$R" DEPLOY_LIB_DIR="$LIBDIR"
    unset FONTSET_DIR_NAME INSTALL_VIA_NIX DEPLOY_PLAN_FONTSET DEPLOY_PLAN_VIANIX_SET
    # shellcheck disable=SC2086
    eval "$extra_env"
    DEPLOY_HOME="$home"
    DEPLOY_XDG_CONFIG="$home/.config"
    DEPLOY_XDG_DATA="$home/.local/share"
    export DEPLOY_HOME DEPLOY_XDG_CONFIG DEPLOY_XDG_DATA
    APPLY_SD="$statedir" APPLY_TARGET="$target" APPLY_FONTSET="" APPLY_VIANIX="false"
    APPLY_AT=""; APPLY_RESOLVE=()
    DEPLOY_AT="$target" DEPLOY_APPLY_FONTSET_SET=false DEPLOY_APPLY_VIANIX_SET=false
    export APPLY_SD APPLY_TARGET APPLY_FONTSET APPLY_VIANIX
    deploy_apply_prepare_all
  )
}

echo "--- preflight refusal + zero writes ---"
fresh_case refuse
disk_before(){
  (cd "$1" && find . \( -type f -exec sha256sum {} + \; -o -type l -printf 'L %p -> %l\n' \) 2>/dev/null | sort)
}
SNAP_PRE=$(disk_before "$T/refuse-home")
if do_prepare "$T/refuse-home" "$T/refuse-state" "$REV_T" > /tmp/pfl.out 2>&1; then
  fail "preflight refuses undecided"
else
  [[ $? == 2 ]] && pass "preflight refuses undecided" || fail "preflight refuses undecided"
fi
grep -q "no-decision-recorded" /tmp/pfl.out && pass "refusal names undecided" || fail "refusal names undecided"
[[ "$(disk_before "$T/refuse-home")" == "$SNAP_PRE" ]] && pass "refusal writes nothing to home" || fail "refusal writes nothing to home"
[[ ! -e "$T/refuse-state/apply.lock" && ! -d "$T/refuse-state/applies" ]] && pass "refusal writes no tx state" || fail "refusal writes no tx state"

echo "--- decisions UX ---"
fresh_case decide
decide_run(){
  (
    export REPO_ROOT="$R" DEPLOY_LIB_DIR="$LIBDIR"
    unset FONTSET_DIR_NAME INSTALL_VIA_NIX
    DEPLOY_AT="$REV_T" DEPLOY_HOME_DIR="$T/decide-home" DEPLOY_STATE_DIR="$T/decide-state"
    DEPLOY_DECIDE_SET=() DEPLOY_DECIDE_REMOVE=() DEPLOY_DECIDE_LIST=false
    DEPLOY_DECIDE_FONTSET=""; DEPLOY_DECIDE_FONTSET_SET=false; DEPLOY_DECIDE_VIANIX_SET=false
    eval "$1"
    source "${HERE}/../../subcmd-decide/0.run.sh"
  )
}
decide_run 'DEPLOY_DECIDE_SET=("app/drift.conf:replace")' > /dev/null 2>&1 || true
decide_run 'DEPLOY_DECIDE_SET=(".config/app/drift.conf=replace" ".config/app/staled.conf=delete" ".config/app/miss.conf=install" ".config/app/miss2.conf=preserve-absence" ".config/app/keepd.conf=keep" ".config/hypr/side3.conf=replace")' > /tmp/dec.out 2>&1
[[ $? == 0 ]] && pass "decide records valid batch" || fail "decide records valid batch: $(tail -n 2 /tmp/dec.out)"
python3 -c "import json;[json.loads(l) for l in open('$T/decide-state/decisions.jsonl')]" \
  && pass "decisions file is valid JSON" || fail "decisions file is valid JSON"
[[ "$(grep -c . "$T/decide-state/decisions.jsonl")" == 6 ]] && pass "six decisions stored" || fail "six decisions stored"
decide_run 'DEPLOY_DECIDE_SET=(".config/app/keep.conf=replace")' > /dev/null 2>&1
[[ $? == 2 ]] && pass "decision for noop refused" || fail "decision for noop refused"
decide_run 'DEPLOY_DECIDE_SET=(".config/app/drift.conf=vaporize")' > /dev/null 2>&1
[[ $? == 2 ]] && pass "invalid choice refused" || fail "invalid choice refused"
decide_run 'DEPLOY_DECIDE_SET=(".config/app/nonexistent=keep")' > /dev/null 2>&1
[[ $? == 2 ]] && pass "unknown path refused" || fail "unknown path refused"
decide_run 'DEPLOY_DECIDE_REMOVE=(".config/app/miss2.conf")' > /dev/null 2>&1
[[ $? == 0 ]] && pass "decision remove works" || fail "decision remove works"
[[ "$(grep -c . "$T/decide-state/decisions.jsonl")" == 5 ]] && pass "remove shrinks file" || fail "remove shrinks file"
decide_run 'DEPLOY_DECIDE_REMOVE=(".config/app/miss2.conf")' > /dev/null 2>&1
[[ $? != 0 ]] && pass "double remove refused" || fail "double remove refused"
decide_run 'DEPLOY_DECIDE_SET=(".config/app/miss2.conf=preserve-absence")' > /dev/null 2>&1
decide_run 'DEPLOY_DECIDE_LIST=true' > /tmp/dec-list.out 2>&1
grep -q "miss2.conf.*preserve-absence" /tmp/dec-list.out && pass "decide list shows rows" || fail "decide list shows rows"

echo "--- stale fingerprints ---"
fresh_case stale
decide_run2(){
  (
    export REPO_ROOT="$R" DEPLOY_LIB_DIR="$LIBDIR" STATED="$T/stale-state" HOMED="$T/stale-home"
    unset FONTSET_DIR_NAME INSTALL_VIA_NIX
    DEPLOY_AT="$REV_T" DEPLOY_HOME_DIR="$HOMED" DEPLOY_STATE_DIR="$STATED"
    DEPLOY_DECIDE_SET=() DEPLOY_DECIDE_REMOVE=() DEPLOY_DECIDE_LIST=false
    DEPLOY_DECIDE_FONTSET=""; DEPLOY_DECIDE_FONTSET_SET=false; DEPLOY_DECIDE_VIANIX_SET=false
    eval "$1"
    source "${HERE}/../../subcmd-decide/0.run.sh"
  )
}
decide_run2 'DEPLOY_DECIDE_SET=(".config/app/drift.conf=replace")' > /dev/null 2>&1
printf 'drifted-again\n' > "$T/stale-home/.config/app/drift.conf"
if do_prepare "$T/stale-home" "$T/stale-state" "$REV_T" > /tmp/stale.out 2>&1; then
  fail "stale fingerprint refuses"
else
  [[ $? == 2 ]] && pass "stale fingerprint refuses" || fail "stale fingerprint refuses"
fi
grep -q "stale-decision" /tmp/stale.out && pass "stale names the path" || fail "stale names the path"

# Full apply driver through the real subcommand path (same composition).
apply_run(){
  local mode="$1" home="$2" statedir="$3" extra_env="${4:-}"
  (
    export REPO_ROOT="$R" DEPLOY_LIB_DIR="$LIBDIR"
    unset FONTSET_DIR_NAME INSTALL_VIA_NIX
    eval "$extra_env"
    DEPLOY_AT="$REV_T" DEPLOY_HOME_DIR="$home" DEPLOY_STATE_DIR="$statedir"
    DEPLOY_APPLY_FONTSET=""; DEPLOY_APPLY_FONTSET_SET=false; DEPLOY_APPLY_VIANIX_SET=false
    DEPLOY_APPLY_PREFLIGHT=false; DEPLOY_APPLY_RESUME=""; DEPLOY_APPLY_ABORT=""; DEPLOY_APPLY_BREAK=false
    APPLY_AT_GIVEN=""; APPLY_INPUTS_GIVEN=""; APPLY_RESOLVE=()
    case "$mode" in
      preflight) DEPLOY_APPLY_PREFLIGHT=true;;
      resume:*) DEPLOY_APPLY_RESUME="${mode#resume:}";;
      abort:*) DEPLOY_APPLY_ABORT="${mode#abort:}";;
      break) DEPLOY_APPLY_BREAK=true;;
    esac
    source "${HERE}/../../subcmd-apply/0.run.sh"
  )
}

echo "--- main apply success ---"
fresh_case main
decide_run_main(){
  (
    export REPO_ROOT="$R" DEPLOY_LIB_DIR="$LIBDIR" STATED="$T/main-state" HOMED="$T/main-home"
    unset FONTSET_DIR_NAME INSTALL_VIA_NIX
    DEPLOY_AT="$REV_T" DEPLOY_HOME_DIR="$HOMED" DEPLOY_STATE_DIR="$STATED"
    DEPLOY_DECIDE_SET=() DEPLOY_DECIDE_REMOVE=() DEPLOY_DECIDE_LIST=false
    DEPLOY_DECIDE_FONTSET=""; DEPLOY_DECIDE_FONTSET_SET=false; DEPLOY_DECIDE_VIANIX_SET=false
    eval "$1"
    source "${HERE}/../../subcmd-decide/0.run.sh"
  )
}
decide_run_main 'DEPLOY_DECIDE_SET=(".config/app/drift.conf=replace" ".config/app/staled.conf=delete" ".config/app/miss.conf=install" ".config/app/miss2.conf=preserve-absence" ".config/app/keepd.conf=keep" ".config/hypr/side3.conf=replace")' > /dev/null 2>&1
MH="$T/main-home"
MS="$T/main-state"
snap_home(){
  (cd "$1" && find .config .local -printf '%y %m %p\n' 2>/dev/null | sort; cd "$1" && find .config .local -type f -exec sha256sum {} + 2>/dev/null | sort; cd "$1" && find .config .local -type l -printf 'L %p -> %l\n' 2>/dev/null | sort)
}
SNAP_MH_PRE=$(snap_home "$MH")
apply_run apply "$MH" "$MS" > /tmp/apply-main.out 2>&1
[[ $? == 0 ]] && pass "apply exits 0" || fail "apply exits 0: $(tail -n 3 /tmp/apply-main.out)"
cp /tmp/apply-main.out /tmp/apply-main.run1.out
cp /tmp/apply-main.out /tmp/apply-main.run1.out
cp "$MS/manifest.jsonl" /tmp/manifest-run1.jsonl
[[ "$(cat "$MH/.config/app/upd.conf")" == "v2" ]] && pass "update delivered" || fail "update delivered"
[[ "$(stat -c %a "$MH/.config/app/exe.sh")" == "755" ]] && pass "mode normalized to 755" || fail "mode normalized to 755"
[[ "$(cat "$MH/.config/app/exe.sh")" == "#!/bin/sh
echo hi" ]] && pass "mode-change kept bytes" || fail "mode-change kept bytes"
[[ "$(readlink "$MH/.config/app/relink.conf")" == "tb" ]] && pass "symlink retargeted" || fail "symlink retargeted"
[[ ! -e "$MH/.config/app/gonebye.conf" ]] && pass "stale deleted" || fail "stale deleted"
[[ ! -e "$MH/.config/app/staled.conf" ]] && pass "drifted-stale deleted by decision" || fail "drifted-stale deleted by decision"
[[ "$(cat "$MH/.config/app/drift.conf")" == "v2" ]] && pass "drift replaced" || fail "drift replaced"
[[ "$(cat "$MH/.config/app/miss.conf")" == "install-me" ]] && pass "missing installed" || fail "missing installed"
[[ ! -e "$MH/.config/app/miss2.conf" ]] && pass "preserved absence kept absent" || fail "preserved absence kept absent"
[[ "$(cat "$MH/.config/app/keepd.conf")" == "disk-v" ]] && pass "kept drift untouched" || fail "kept drift untouched"
[[ "$(cat "$MH/.config/app/newf.conf")" == "v3" ]] && pass "novelty added" || fail "novelty added"
[[ "$(cat "$MH/.config/app/subdir/newdeep.conf")" == "deep" ]] && pass "deep novelty added with parents" || fail "deep novelty added with parents"
[[ "$(cat "$MH/.config/hypr/idle2.conf.new")" == "repo idle2" ]] && pass "sidecar-new delivered" || fail "sidecar-new delivered"
[[ "$(cat "$MH/.config/hypr/side3.conf")" == "disk side3" ]] && pass "sidecar live untouched" || fail "sidecar live untouched"
[[ -f "$MH/.config/hypr/side3.conf.new.1" ]] && pass "colliding .new versioned" || fail "colliding .new versioned"
[[ "$(cat "$MH/.config/hypr/side3.conf.new.1")" == "v2 side" ]] && pass "versioned .new has target bytes" || fail "versioned .new has target bytes"
[[ "$(cat "$MH/.config/hypr/side3.conf.new")" == "disk side3" ]] && pass "junk .new preserved" || fail "junk .new preserved"
[[ "$(cat "$MH/.config/hypr/sc5.conf")" == "v1 five" ]] && pass "pristine sidecar live untouched" || fail "pristine sidecar live untouched"
[[ "$(cat "$MH/.config/hypr/sc5.conf.new")" == "v2 five" ]] && pass "pristine sidecar delivered as .new" || fail "pristine sidecar delivered as .new"
[[ -d "$MH/.config/app/sub" && -d "$MH/.config/app/sub2" ]] && pass "submodule dirs intact" || fail "submodule dirs intact"
grep -q '"path":".config/app/gonebye.conf"' "$MS/manifest.jsonl" && fail "deleted row dropped" || pass "deleted row dropped"
grep -q '"path":".config/app/upd.conf","kind":"file","class":"managed","status":"confirmed"' "$MS/manifest.jsonl" && pass "updated row confirmed@T" || fail "updated row confirmed@T"
grep -q '"path":".config/app/keepd.conf".*"status":"drifted"' "$MS/manifest.jsonl" && pass "kept row frozen drifted" || fail "kept row frozen drifted"
grep -q '"path":".config/app/miss2.conf".*"status":"missing"' "$MS/manifest.jsonl" && pass "preserved row stays missing" || fail "preserved row stays missing"
grep -q '"path":".config/hypr/idle2.conf.new"' "$MS/manifest.jsonl" && pass ".new row recorded" || fail ".new row recorded"
[[ "$(grep -c . "$MS/manifest.jsonl")" == "$(grep -o '"manifest_records": [0-9]*' "$MS/deployment-identity.json" | grep -o '[0-9]*')" ]] && pass "identity counts match" || fail "identity counts match"
grep -q '"fully_deployed": false' "$MS/deployment-identity.json" && pass "fully_deployed false with open decisions" || fail "fully_deployed false with open decisions"
apply_run preflight "$MH" "$MS" > /dev/null 2>&1
[[ $? == 0 ]] && pass "second preflight clean" || fail "second preflight clean"

echo "--- second apply idempotency ---"
SNAP_MF_1=$(sha256sum "$MS/manifest.jsonl" | awk '{print $1}')
cp "$MS/manifest.jsonl" /tmp/manifest-apply1.jsonl
SNAP_HOME_1=$(snap_home "$MH")
apply_run apply "$MH" "$MS" > /tmp/apply2.out 2>&1
ARC=$?
[[ $ARC == 0 ]] && pass "second apply exits 0" || fail "second apply exits 0 (rc=$ARC)"
cp "$MS/manifest.jsonl" /tmp/manifest-apply2.jsonl
[[ "$(sha256sum "$MS/manifest.jsonl" | awk '{print $1}')" == "$SNAP_MF_1" ]] && pass "manifest stable across noop apply" || fail "manifest stable across noop apply"
[[ "$(snap_home "$MH")" == "$SNAP_HOME_1" ]] && pass "home stable across noop apply" || fail "home stable across noop apply"

echo "--- journal hygiene (no placeholders, no dup seq, no debug) ---"
MAIN_JOURNAL=$(ls "$MS/applies/"*/journal.jsonl | head -n 1)
if grep -q '"pre":"live"' "$MAIN_JOURNAL"; then fail "journal pre records real observations (no live placeholder)"; else pass "journal pre records real observations (no live placeholder)"; fi
if [[ "$(jq -r -s '.[].seq' "$MAIN_JOURNAL" | sort -n | uniq -d | wc -l)" == 0 ]]; then pass "journal seq unique"; else fail "journal seq unique"; fi
if grep -q "DBG-" /tmp/apply-main.out /tmp/apply2.out 2>/dev/null; then fail "no debug noise in apply output"; else pass "no debug noise in apply output"; fi

echo "--- recovery: mid-op failure -> abort restores ---"
fresh_case recover-abort
decide_for(){
  (
    export REPO_ROOT="$R" DEPLOY_LIB_DIR="$LIBDIR" STATED="$1" HOMED="$2"
    unset FONTSET_DIR_NAME INSTALL_VIA_NIX
    DEPLOY_AT="$REV_T" DEPLOY_HOME_DIR="$HOMED" DEPLOY_STATE_DIR="$STATED"
    DEPLOY_DECIDE_SET=() DEPLOY_DECIDE_REMOVE=() DEPLOY_DECIDE_LIST=false
    DEPLOY_DECIDE_FONTSET=""; DEPLOY_DECIDE_FONTSET_SET=false; DEPLOY_DECIDE_VIANIX_SET=false
    eval "$3"
    source "${HERE}/../../subcmd-decide/0.run.sh"
  )
}
decide_for "$T/recover-abort-state" "$T/recover-abort-home" 'DEPLOY_DECIDE_SET=(".config/app/drift.conf=replace" ".config/app/staled.conf=delete" ".config/app/miss.conf=install" ".config/app/miss2.conf=preserve-absence" ".config/app/keepd.conf=keep" ".config/hypr/side3.conf=replace")' > /dev/null 2>&1
RAH="$T/recover-abort-home" RAS="$T/recover-abort-state"
RA_DRIFT_BEFORE=$(cat "$RAH/.config/app/drift.conf")
RA_UPD_BEFORE=$(cat "$RAH/.config/app/upd.conf")
apply_run apply "$RAH" "$RAS" 'DEPLOY_TEST_FAULT="fail-after:op:3"' > /tmp/recover-abort-apply.out 2>&1
[[ $? == 1 ]] && pass "mid-op failure exits 1" || fail "mid-op failure exits 1"
RATX=$(ls "$RAS/applies/")
[[ -n "$RATX" ]] && pass "failed transaction recorded" || fail "failed transaction recorded"
if grep -q '"type":"completed"' "$RAS/applies/$RATX/journal.jsonl" 2>/dev/null && grep -q '"outcome":"complete"' "$RAS/applies/$RATX/journal.jsonl" 2>/dev/null; then fail "failed journal stays open (no complete marker)"; else pass "failed journal stays open (no complete marker)"; fi
( export REPO_ROOT="$R"; deploy_status "$RAS" > /tmp/recover-abort-status.out 2>&1; [[ $? == 2 ]] && grep -q "verdict: incomplete:$RATX" /tmp/recover-abort-status.out && pass "status reports incomplete after failure" || fail "status reports incomplete after failure" )
apply_run "abort:$RATX" "$RAH" "$RAS" > /tmp/recover-abort-abort.out 2>&1
[[ $? == 2 ]] && pass "abort refuses with stale lock (break required)" || fail "abort refuses with stale lock (break required)"
apply_run break "$RAH" "$RAS" > /dev/null 2>&1
[[ $? == 0 ]] && pass "break-lock releases dead mutex" || fail "break-lock releases dead mutex"
apply_run "abort:$RATX" "$RAH" "$RAS" > /tmp/recover-abort-abort2.out 2>&1
[[ $? == 0 ]] && pass "abort restores after break" || fail "abort restores after break: $(tail -n 2 /tmp/recover-abort-abort2.out)"
[[ "$(cat "$RAH/.config/app/drift.conf")" == "$RA_DRIFT_BEFORE" ]] && pass "abort restores drift bytes" || fail "abort restores drift bytes"
[[ "$(cat "$RAH/.config/app/upd.conf")" == "$RA_UPD_BEFORE" ]] && pass "abort restores upd bytes" || fail "abort restores upd bytes"
[[ ! -e "$RAH/.config/app/miss.conf" ]] && pass "abort removes installed file" || fail "abort removes installed file"
[[ ! -e "$RAH/.config/app/newf.conf" ]] && pass "abort removes novelty" || fail "abort removes novelty"
[[ ! -e "$RAH/.config/hypr/idle2.conf.new" ]] && pass "abort removes delivered .new" || fail "abort removes delivered .new"
( export REPO_ROOT="$R"; deploy_status "$RAS" > /dev/null 2>&1; [[ $? == 0 ]] && pass "status adoption-complete after abort" || fail "status adoption-complete after abort" )

echo "--- recovery: mid-op failure -> resume completes ---"
fresh_case recover-resume
decide_for "$T/recover-resume-state" "$T/recover-resume-home" 'DEPLOY_DECIDE_SET=(".config/app/drift.conf=replace" ".config/app/staled.conf=delete" ".config/app/miss.conf=install" ".config/app/miss2.conf=preserve-absence" ".config/app/keepd.conf=keep" ".config/hypr/side3.conf=replace")' > /dev/null 2>&1
RRH="$T/recover-resume-home" RRS="$T/recover-resume-state"
apply_run apply "$RRH" "$RRS" 'DEPLOY_TEST_FAULT="fail-after:op:3"' > /dev/null 2>&1
RRTX=$(ls "$RRS/applies/")
apply_run break "$RRH" "$RRS" > /dev/null 2>&1
apply_run "resume:$RRTX" "$RRH" "$RRS" > /tmp/recover-resume.out 2>&1
[[ $? == 0 ]] && pass "resume completes after mid-op failure" || fail "resume completes after mid-op failure: $(tail -n 3 /tmp/recover-resume.out)"
[[ "$(cat "$RRH/.config/app/drift.conf")" == "v2" ]] && pass "resumed drift delivered" || fail "resumed drift delivered"
[[ "$(cat "$RRH/.config/app/miss.conf")" == "install-me" ]] && pass "resumed missing installed" || fail "resumed missing installed"
[[ "$(cat "$RRH/.config/app/newf.conf")" == "v3" ]] && pass "resumed novelty added" || fail "resumed novelty added"
apply_run preflight "$RRH" "$RRS" > /dev/null 2>&1
[[ $? == 0 ]] && pass "preflight clean after resume" || fail "preflight clean after resume"

echo "--- recovery: publish-manifest crash -> resume finalizes ---"
fresh_case recover-pub
decide_for "$T/recover-pub-state" "$T/recover-pub-home" 'DEPLOY_DECIDE_SET=(".config/app/drift.conf=replace" ".config/app/staled.conf=delete" ".config/app/miss.conf=install" ".config/app/miss2.conf=preserve-absence" ".config/app/keepd.conf=keep" ".config/hypr/side3.conf=replace")' > /dev/null 2>&1
RPH="$T/recover-pub-home" RPS="$T/recover-pub-state"
apply_run apply "$RPH" "$RPS" 'DEPLOY_TEST_FAULT="fail-after:publish-manifest"' > /tmp/recover-pub-apply.out 2>&1
[[ $? == 1 ]] && pass "publish crash exits 1" || fail "publish crash exits 1"
RPTX=$(ls "$RPS/applies/")
( export REPO_ROOT="$R"; deploy_status "$RPS" > /tmp/recover-pub-status.out 2>&1; grep -q "manifest advanced past snapshot" /tmp/recover-pub-status.out && grep -q "verdict: incomplete:$RPTX" /tmp/recover-pub-status.out && pass "status notes advanced manifest" || fail "status notes advanced manifest" )
apply_run break "$RPH" "$RPS" > /dev/null 2>&1
apply_run "resume:$RPTX" "$RPH" "$RPS" > /tmp/recover-pub-resume.out 2>&1
[[ $? == 0 ]] && pass "resume finalizes advanced manifest" || fail "resume finalizes advanced manifest: $(tail -n 3 /tmp/recover-pub-resume.out)"
( export REPO_ROOT="$R"; deploy_status "$RPS" > /dev/null 2>&1; [[ $? == 0 ]] && pass "status complete after publish resume" || fail "status complete after publish resume" )

echo "--- recovery: TOCTOU fail-fast and abort ---"
fresh_case recover-toctou
decide_for "$T/recover-toctou-state" "$T/recover-toctou-home" 'DEPLOY_DECIDE_SET=(".config/app/drift.conf=replace" ".config/app/staled.conf=delete" ".config/app/miss.conf=install" ".config/app/miss2.conf=preserve-absence" ".config/app/keepd.conf=keep" ".config/hypr/side3.conf=replace")' > /dev/null 2>&1
RTH="$T/recover-toctou-home" RTS="$T/recover-toctou-state"
RTH_UPD_BEFORE=$(cat "$RTH/.config/app/upd.conf")
apply_run apply "$RTH" "$RTS" 'DEPLOY_TEST_FAULT="mutate:.config/app/upd.conf:EVIL"' > /tmp/recover-toctou.out 2>&1
[[ $? == 1 ]] && pass "TOCTOU failure exits 1" || fail "TOCTOU failure exits 1"
grep -q "TOCTOU" /tmp/recover-toctou.out && pass "TOCTOU names the raced path" || fail "TOCTOU names the raced path"
[[ "$(cat "$RTH/.config/app/upd.conf")" == "EVIL" ]] && pass "raced live left for operator" || fail "raced live left for operator"
RTTX=$(ls "$RTS/applies/")
apply_run break "$RTH" "$RTS" > /dev/null 2>&1
apply_run "abort:$RTTX" "$RTH" "$RTS" > /dev/null 2>&1
[[ $? == 0 ]] && pass "abort restores after TOCTOU" || fail "abort restores after TOCTOU"
# The raced file was mutated externally after the snapshot (never by the
# transaction, which refused before touching it): abort preserves the
# external change rather than clobbering it back to the snapshot.
[[ "$(cat "$RTH/.config/app/upd.conf")" == "EVIL" ]] && pass "abort preserves external race" || fail "abort preserves external race"

echo "--- recovery: real crash (die-after) -> abort ---"
fresh_case recover-die
decide_for "$T/recover-die-state" "$T/recover-die-home" 'DEPLOY_DECIDE_SET=(".config/app/drift.conf=replace" ".config/app/staled.conf=delete" ".config/app/miss.conf=install" ".config/app/miss2.conf=preserve-absence" ".config/app/keepd.conf=keep" ".config/hypr/side3.conf=replace")' > /dev/null 2>&1
RDH="$T/recover-die-home" RDS="$T/recover-die-state"
apply_run apply "$RDH" "$RDS" 'DEPLOY_TEST_FAULT="die-after:op:2"' > /tmp/recover-die.out 2>&1
# die-after KILLs the subshell driver; the harness subshell exit code is 137.
[[ $? != 0 ]] && pass "real crash fails the apply" || fail "real crash fails the apply"
RDTX=$(ls "$RDS/applies/")
[[ -n "$RDTX" ]] && pass "crashed transaction recorded" || fail "crashed transaction recorded"
( export REPO_ROOT="$R"; deploy_status "$RDS" > /tmp/recover-die-status.out 2>&1; [[ $? == 2 ]] && grep -q "verdict: incomplete:$RDTX" /tmp/recover-die-status.out && pass "status incomplete after crash" || fail "status incomplete after crash" )
apply_run break "$RDH" "$RDS" > /dev/null 2>&1
apply_run "abort:$RDTX" "$RDH" "$RDS" > /dev/null 2>&1
[[ $? == 0 ]] && pass "abort restores after real crash" || fail "abort restores after real crash"

echo "--- recovery: live lock refusal and break-lock guard ---"
fresh_case recover-lock
RLH="$T/recover-lock-home" RLS="$T/recover-lock-state"
sleep 30 &
LOCKHOLDER=$!
printf '%s %s\n' "$LOCKHOLDER" "fake-live-tx" > "$RLS/apply.lock"
apply_run preflight "$RLH" "$RLS" > /tmp/recover-lock-pre.out 2>&1
[[ $? == 2 ]] && grep -q "in progress" /tmp/recover-lock-pre.out && pass "preflight refuses live lock" || fail "preflight refuses live lock"
apply_run break "$RLH" "$RLS" > /tmp/recover-lock-break.out 2>&1
[[ $? != 0 ]] && pass "break-lock refuses live holder" || fail "break-lock refuses live holder"
kill "$LOCKHOLDER" 2>/dev/null || true
wait "$LOCKHOLDER" 2>/dev/null || true
apply_run break "$RLH" "$RLS" > /dev/null 2>&1
[[ $? == 0 ]] && pass "break-lock clears dead mutex" || fail "break-lock clears dead mutex"
[[ ! -f "$RLS/apply.lock" ]] && pass "lock file removed" || fail "lock file removed"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
