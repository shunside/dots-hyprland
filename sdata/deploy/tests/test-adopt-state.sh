#!/usr/bin/env bash
#
# Fixture tests for the Slice 2 durable adoption layer
# (sdata/lib/deploy-state.sh + subcmd-adopt write paths).
# Everything lives under $T. The real $HOME is never touched: every apply
# passes an explicit --home fixture dir, except dedicated subshell tests
# that override HOME itself.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBDIR="${HERE}/../../lib"
ADOPTDIR="${HERE}/../../subcmd-adopt"
# shellcheck source=../lib/deploy-common.sh
source "${LIBDIR}/deploy-common.sh"
# shellcheck source=../lib/deploy-state.sh
source "${LIBDIR}/deploy-state.sh"

PASS=0
FAIL=0
pass(){ PASS=$((PASS+1)); echo "PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }

T="$(mktemp -d /tmp/deploy-state-XXXXXX)"
trap 'rm -rf "$T"' EXIT

R="$T/repo"
H="$T/home"
H2="$T/home2"
mkdir -p "$R" "$H" "$H2"

git -C "$R" init -qb main
git -C "$R" config user.email "fixture@example"
git -C "$R" config user.name "fixture"
git -C "$R" config commit.gpgsign false
GCOMMIT=(-c user.email=fixture@example -c user.name=fixture -c commit.gpgsign=false commit -qm)

mkdir -p "$R/dots/.config/app" "$R/dots/.config/hypr/custom"
mkdir -p "$R/dots/.config/fontconfig" "$R/dots-extra/fontsets/good" "$R/dots-extra/via-nix"
mkdir -p "$R/dots/.config/stray" "$R/sdata/deploy"
printf 'same\n' > "$R/dots/.config/app/keep.conf"
printf 'repo version\n' > "$R/dots/.config/app/changed.conf"
printf 'only in repo\n' > "$R/dots/.config/app/gone.conf"
printf 'repo unreadable-on-disk\n' > "$R/dots/.config/app/err.conf"
printf 'seed\n' > "$R/dots/.config/hypr/custom/seed.lua"
printf 'repo idle\n' > "$R/dots/.config/hypr/hypridle.conf"
printf 'default fonts\n' > "$R/dots/.config/fontconfig/fonts.conf"
printf 'goodset fonts\n' > "$R/dots-extra/fontsets/good/fonts.conf"
printf 'nix idle\n' > "$R/dots-extra/via-nix/hypridle.conf"
cat > "$R/sdata/deploy/ownership.conf" <<'EOF'
managed dots/.config/app .config/app
managed dots/.config/fontconfig .config/fontconfig
sidecar dots/.config/hypr/hypridle.conf .config/hypr/hypridle.conf
user dots/.config/hypr/custom .config/hypr/custom
EOF
git -C "$R" add -A
git -C "$R" "${GCOMMIT[@]}" "rev one"
EMPTY_TREE=$(git -C "$R" hash-object -t tree /dev/null)
git -C "$R" update-index --add --cacheinfo "160000,${EMPTY_TREE},dots/.config/app/submod"
git -C "$R" "${GCOMMIT[@]}" "rev two adds gitlink"
REV_CLEAN=$(git -C "$R" rev-parse HEAD)
printf 'undeclared\n' > "$R/dots/.config/stray/undeclared.txt"
git -C "$R" add -A
git -C "$R" "${GCOMMIT[@]}" "rev three adds stray"
REV_STRAY=$(git -C "$R" rev-parse HEAD)
git -C "$R" rm -q dots/.config/stray/undeclared.txt
printf '\nmanaged dots/.config/does-not-exist .config/does-not-exist\n' >> "$R/sdata/deploy/ownership.conf"
git -C "$R" add -A
git -C "$R" "${GCOMMIT[@]}" "rev four adds dead rule"
REV_DEAD=$(git -C "$R" rev-parse HEAD)

mklive(){
  local base="$1"
  mkdir -p "$base/.config/app" "$base/.config/hypr/custom" "$base/.config/fontconfig" "$base/.config/app/submod"
  printf 'same\n' > "$base/.config/app/keep.conf"
  printf 'disk version\n' > "$base/.config/app/changed.conf"
  printf 'x\n' > "$base/.config/app/err.conf"
  chmod 000 "$base/.config/app/err.conf"
  printf 'seed\n' > "$base/.config/hypr/custom/seed.lua"
  printf 'disk idle\n' > "$base/.config/hypr/hypridle.conf"
  printf 'default fonts\n' > "$base/.config/fontconfig/fonts.conf"
  mkdir -p "$base/.config/illogical-impulse"
  printf '/home/imnot/.config/app/keep.conf\n' > "$base/.config/illogical-impulse/installed_listfile"
  printf '/home/imnot/.config/app/keep.conf\n' >> "$base/.config/illogical-impulse/installed_listfile"
  printf '/etc/should-be-skipped\n' >> "$base/.config/illogical-impulse/installed_listfile"
  printf '\n' >> "$base/.config/illogical-impulse/installed_listfile"
  printf '%s/.config/app/keep.conf\n' "$base" >> "$base/.config/illogical-impulse/installed_listfile"
  printf '%s\n' "$base" >> "$base/.config/illogical-impulse/installed_listfile"
}
mklive "$H"
# H2: same but err.conf readable (clean tree for golden apply).
rm -f "$H2"/.config/app/err.conf
mkdir -p "$H2/.config/app" "$H2/.config/hypr/custom" "$H2/.config/fontconfig" "$H2/.config/app/submod"
printf 'same\n' > "$H2/.config/app/keep.conf"
printf 'disk version\n' > "$H2/.config/app/changed.conf"
printf 'seed\n' > "$H2/.config/hypr/custom/seed.lua"
printf 'disk idle\n' > "$H2/.config/hypr/hypridle.conf"
printf 'default fonts\n' > "$H2/.config/fontconfig/fonts.conf"
mkdir -p "$H2/.config/illogical-impulse"
cp "$H/.config/illogical-impulse/installed_listfile" "$H2/.config/illogical-impulse/installed_listfile"
printf '%s/.config/app/keep.conf\n' "$H2" >> "$H2/.config/illogical-impulse/installed_listfile"

# Drive 0.run.sh the way options.sh would: preset DEPLOY_* vars in a
# subshell (its `exit`s must not kill this runner).
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

echo "--- golden apply ---"
S1="$T/s1"
adopt_run "$REV_CLEAN" "$H2" "$S1" apply > "$T/golden.tsv" 2> "$T/golden.err"
[[ $? == 0 ]] && pass "apply exits 0" || fail "apply exits 0"
[[ -f "$S1/manifest.jsonl" && -f "$S1/deployment-identity.json" && -f "$S1/legacy-evidence.jsonl" ]] \
  && pass "three state files exist" || fail "three state files exist"
python3 -c "import json;[json.loads(l) for l in open('$S1/manifest.jsonl')];json.load(open('$S1/deployment-identity.json'));[json.loads(l) for l in open('$S1/legacy-evidence.jsonl')]" \
  && pass "all state files are valid JSON" || fail "all state files are valid JSON"
MF_SHA=$(sha256sum "$S1/manifest.jsonl" | awk '{print $1}')
[[ "$(grep -o '"manifest_sha256": "[0-9a-f]*"' "$S1/deployment-identity.json" | cut -d'"' -f4)" == "$MF_SHA" ]] \
  && pass "identity pins manifest sha" || fail "identity pins manifest sha"
[[ "$(grep -o "\"revision\": \"[0-9a-f]*\"" "$S1/deployment-identity.json" | cut -d'"' -f4)" == "$REV_CLEAN" ]] \
  && pass "identity pins revision" || fail "identity pins revision"
[[ "$(grep -o '"fontset": [a-z]*' "$S1/deployment-identity.json")" == '"fontset": null' ]] \
  && pass "identity fontset null by default" || fail "identity fontset null by default"
grep -q '"via_nix": false' "$S1/deployment-identity.json" && pass "identity via_nix false" || fail "identity via_nix false"
grep -q '"fully_deployed": false' "$S1/deployment-identity.json" && pass "drifted baseline is not fully_deployed" || fail "drifted baseline is not fully_deployed"
[[ "$(grep -o "\"home_root\": \"[^\"]*\"" "$S1/deployment-identity.json" | cut -d'"' -f4)" == "$H2" ]] \
  && pass "identity home_root" || fail "identity home_root"
[[ "$(grep -c . "$S1/manifest.jsonl")" == "$(grep -o '"manifest_records": [0-9]*' "$S1/deployment-identity.json" | grep -o '[0-9]*')" ]] \
  && pass "manifest count agrees" || fail "manifest count agrees"
grep -q '"path":".config/app/keep.conf","kind":"file","class":"managed","status":"confirmed"' "$S1/manifest.jsonl" \
  && pass "match becomes confirmed" || fail "match becomes confirmed"
grep -q '"path":".config/app/changed.conf".*"status":"drifted"' "$S1/manifest.jsonl" \
  && pass "differ stays drifted" || fail "differ stays drifted"
grep -q '"path":".config/app/gone.conf".*"status":"missing"' "$S1/manifest.jsonl" \
  && pass "absent stays missing" || fail "absent stays missing"
grep -q '"path":".config/hypr/hypridle.conf".*"status":"drifted"' "$S1/manifest.jsonl" \
  && pass "sidecar drift recorded" || fail "sidecar drift recorded"
grep -q '"kind":"submodule".*"status":"present"' "$S1/manifest.jsonl" \
  && pass "submodule presence recorded" || fail "submodule presence recorded"
if grep -q "fish_variables\|custom/seed" "$S1/manifest.jsonl"; then fail "no user rows in manifest"; else pass "no user rows in manifest"; fi
[[ "$(cat "$S1/legacy-evidence.jsonl")" == '{"path":".config/app/keep.conf","provenance":"legacy-list"}' ]] \
  && pass "legacy evidence exact (dedupe+filter)" || fail "legacy evidence exact (dedupe+filter): $(cat "$S1/legacy-evidence.jsonl")"
[[ "$(ls -A "$S1" | grep -c tmp)" == 0 ]] && pass "no tmps left" || fail "no tmps left"

echo "--- status readback ---"
adopt_run "$REV_CLEAN" "$H2" "$S1" status > "$T/status.out" 2> "$T/status.err"
[[ $? == 0 ]] && pass "status exits 0 when complete" || fail "status exits 0 when complete"
grep -q "verdict: adoption-complete" "$T/status.out" && pass "verdict adoption-complete" || fail "verdict adoption-complete"
adopt_run "$REV_CLEAN" "$H2" "$T/nostate" status > /dev/null 2>&1
[[ $? == 2 ]] && pass "status exits 2 when absent" || fail "status exits 2 when absent"

echo "--- fail closed ---"
adopt_run "$REV_STRAY" "$H2" "$T/s-stray" apply > /dev/null 2> "$T/stray.err"
[[ $? == 2 ]] && pass "unclassified refuses (exit 2)" || fail "unclassified refuses (exit 2)"
[[ ! -e "$T/s-stray" ]] && pass "refusal writes nothing" || fail "refusal writes nothing"
adopt_run "$REV_DEAD" "$H2" "$T/s-dead" apply > /dev/null 2> "$T/dead.err"
[[ $? == 2 ]] && pass "dead rule refuses" || fail "dead rule refuses"
grep -q "lint: dead rule" "$T/dead.err" && pass "dead rule reported" || fail "dead rule reported"
adopt_run "$REV_CLEAN" "$H" "$T/s-err" apply > /dev/null 2>&1
[[ $? == 2 ]] && pass "classification error refuses" || fail "classification error refuses"
[[ ! -e "$T/s-err" ]] && pass "error refusal writes nothing" || fail "error refusal writes nothing"

echo "--- fontset + via-nix inputs ---"
adopt_run "$REV_CLEAN" "$H2" "$T/s-fs" apply "FONTSET_DIR_NAME=good" > "$T/fs.tsv" 2>&1
[[ $? == 0 ]] && pass "fontset apply succeeds" || fail "fontset apply succeeds"
GOOD_BLOB=$(git -C "$R" rev-parse "$REV_CLEAN:dots-extra/fontsets/good/fonts.conf")
grep -q "\"path\":\".config/fontconfig/fonts.conf\".*\"blob\":\"$GOOD_BLOB\"" "$T/s-fs/manifest.jsonl" \
  && pass "fontset source swapped in manifest" || fail "fontset source swapped in manifest"
grep -q '"fontset": "good"' "$T/s-fs/deployment-identity.json" && pass "identity records fontset" || fail "identity records fontset"
if grep -q "^input-excluded	managed	.config/fontconfig/fonts.conf" "$T/fs.tsv"; then
  pass "swapped-away source is input-excluded, not unclassified"
else
  fail "swapped-away source is input-excluded, not unclassified"
fi
if [[ "$(grep -c 'fontconfig/fonts.conf' "$T/s-fs/manifest.jsonl")" == 1 ]]; then
  pass "exactly one fontconfig row (the swapped-in source)"
else
  fail "exactly one fontconfig row (the swapped-in source)"
fi
adopt_run "$REV_CLEAN" "$H2" "$T/s-fsbad" apply "FONTSET_DIR_NAME=bogus" > /dev/null 2>&1
[[ $? != 0 ]] && pass "bogus fontset fails" || fail "bogus fontset fails"
[[ ! -e "$T/s-fsbad" ]] && pass "bogus fontset writes nothing" || fail "bogus fontset writes nothing"
adopt_run "$REV_CLEAN" "$H2" "$T/s-nix" apply "INSTALL_VIA_NIX=true" > /dev/null 2>&1
[[ $? == 0 ]] && pass "via-nix apply succeeds" || fail "via-nix apply succeeds"
NIX_BLOB=$(git -C "$R" rev-parse "$REV_CLEAN:dots-extra/via-nix/hypridle.conf")
grep -q "\"path\":\".config/hypr/hypridle.conf\".*\"blob\":\"$NIX_BLOB\"" "$T/s-nix/manifest.jsonl" \
  && pass "via-nix source swapped in manifest" || fail "via-nix source swapped in manifest"
grep -q '"via_nix": true' "$T/s-nix/deployment-identity.json" && pass "identity records via_nix" || fail "identity records via_nix"

echo "--- atomicity / interruption ---"
S2="$T/s2"
mkdir -p "$S2"
cp "$S1/manifest.jsonl" "$S2/manifest.jsonl"
adopt_run "$REV_CLEAN" "$H2" "$S2" status > /dev/null 2>&1
[[ $? == 2 ]] && pass "manifest-without-identity is incomplete" || fail "manifest-without-identity is incomplete"
touch "$S2/.tmp.999.manifest.jsonl" "$S2/.tmp.999.deployment-identity.json"
adopt_run "$REV_CLEAN" "$H2" "$S2" apply > /dev/null 2>&1
[[ $? == 0 ]] && pass "apply completes over partial state" || fail "apply completes over partial state"
[[ "$(ls -A "$S2" | grep -c tmp)" == 0 ]] && pass "stale tmps cleaned" || fail "stale tmps cleaned"
adopt_run "$REV_CLEAN" "$H2" "$S2" status > /dev/null 2>&1
[[ $? == 0 ]] && pass "completed after overwrite" || fail "completed after overwrite"
sed -i 's/"status":"confirmed"/"status":"CONFIRMED"/' "$S2/manifest.jsonl"
adopt_run "$REV_CLEAN" "$H2" "$S2" status > /dev/null 2>&1
[[ $? == 1 ]] && pass "tampered manifest is corrupt" || fail "tampered manifest is corrupt"
S3="$T/s3"
mkdir -p "$S3"
cp "$S1/deployment-identity.json" "$S3/deployment-identity.json"
adopt_run "$REV_CLEAN" "$H2" "$S3" status > /dev/null 2>&1
[[ $? == 1 ]] && pass "identity-without-manifest is corrupt" || fail "identity-without-manifest is corrupt"
adopt_run "$REV_CLEAN" "$H2" "$S1" apply > /dev/null 2>&1
[[ $? == 2 ]] && pass "re-apply on complete refuses" || fail "re-apply on complete refuses"

echo "--- home/state-dir matrix ---"
adopt_run "$REV_CLEAN" "$H2" "" apply > /dev/null 2> "$T/foreign.err"
[[ $? == 2 ]] && pass "foreign home without state-dir refuses" || fail "foreign home without state-dir refuses"
grep -q "state-dir" "$T/foreign.err" && pass "refusal names --state-dir" || fail "refusal names --state-dir"
[[ ! -e "$H2/.config/illogical-impulse/manifest.jsonl" && ! -e "$H2/.config/illogical-impulse/deployment-identity.json" && ! -e "$H2/.config/illogical-impulse/legacy-evidence.jsonl" ]] && pass "no metadata leaked into inspected home" || fail "no metadata leaked into inspected home"
S4="$T/s4"
adopt_run "$REV_CLEAN" "$H2" "$S4" apply > /dev/null 2>&1
[[ $? == 0 && -f "$S4/deployment-identity.json" ]] && pass "explicit state-dir works" || fail "explicit state-dir works"
(
  export HOME="$T/fh" XDG_CONFIG_HOME="$T/fh/xdg" XDG_DATA_HOME="$T/fh/share"
  unset FONTSET_DIR_NAME INSTALL_VIA_NIX
  mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
  export REPO_ROOT="$R" DEPLOY_LIB_DIR="$LIBDIR"
  DEPLOY_AT="$REV_CLEAN" DEPLOY_HOME_DIR="$HOME" DEPLOY_STATE_DIR=""
  DEPLOY_WANT_APPLY=true DEPLOY_WANT_STATUS=false DEPLOY_WANT_DRYRUN=false
  # shellcheck disable=SC1091
  source "${ADOPTDIR}/0.run.sh" > /dev/null 2>&1
)
[[ $? == 0 && -f "$T/fh/xdg/illogical-impulse/deployment-identity.json" ]] \
  && pass "fake-HOME default honors XDG" || fail "fake-HOME default honors XDG"
T2="$T/decoy"
mkdir -p "$T2/xdg" "$T2/xhome/.config/app"
cp -r "$H2/.config" "$T2/xhome/"
printf 'same\n' > "$T2/xhome/.config/app/keep.conf"
S5="$T/s5"
# Ambient XDG points at a decoy tree while --home names the foreign root:
# the comparison must follow --home, never the ambient variables.
XDG_CONFIG_HOME="$T2/xdg" XDG_DATA_HOME="$T2/xdgshare" \
  adopt_run "$REV_CLEAN" "$T2/xhome" "$S5" dryrun > "$T/decoy.tsv" 2>/dev/null
grep -q "^adoptable	managed	.config/app/keep.conf" "$T/decoy.tsv" \
  && pass "foreign home ignores ambient XDG" || fail "foreign home ignores ambient XDG"

echo "--- dry-run default + CLI ---"adopt_run "$REV_CLEAN" "$H2" "$T/s-unused" dryrun > /dev/null 2>&1
[[ $? == 0 ]] && pass "default mode is dry-run" || fail "default mode is dry-run"
[[ ! -e "$T/s-unused" ]] && pass "dry-run writes nothing" || fail "dry-run writes nothing"
( set -- --at HEAD --apply; source "${ADOPTDIR}/options.sh" >/dev/null 2>&1;
  [[ "$DEPLOY_AT" == HEAD && "$DEPLOY_WANT_APPLY" == true ]] ) \
  && pass "options parsing" || fail "options parsing"
( set -- --apply --status; source "${ADOPTDIR}/options.sh" >/dev/null 2>&1 ) \
  && fail "apply+status conflict" || pass "apply+status conflict"
( set -- --state-dir relative/path --apply; source "${ADOPTDIR}/options.sh" >/dev/null 2>&1;
  DEPLOY_AT="$REV_CLEAN" DEPLOY_HOME_DIR="$H2" DEPLOY_WANT_STATUS=false DEPLOY_WANT_APPLY=true DEPLOY_WANT_DRYRUN=false
  export REPO_ROOT="$R" DEPLOY_LIB_DIR="$LIBDIR"; source "${ADOPTDIR}/0.run.sh" > /dev/null 2> "$T/rel.err" ) \
  && fail "relative state-dir refused" || pass "relative state-dir refused"
grep -q "must be absolute" "$T/rel.err" \
  && pass "relative state-dir names the problem" || fail "relative state-dir names the problem"

echo "--- fully deployed baseline ---"
RC="$T/cleanrepo"
HC="$T/cleanhome"
mkdir -p "$RC/dots/.config/app" "$RC/sdata/deploy" "$HC/.config/app"
printf 'same\n' > "$RC/dots/.config/app/keep.conf"
printf 'same\n' > "$HC/.config/app/keep.conf"
printf 'managed dots/.config/app .config/app\n' > "$RC/sdata/deploy/ownership.conf"
git -C "$RC" init -qb main
git -C "$RC" config user.email "fixture@example"
git -C "$RC" config user.name "fixture"
git -C "$RC" config commit.gpgsign false
git -C "$RC" add -A
git -C "$RC" "${GCOMMIT[@]}" "clean rev"
REV_OK=$(git -C "$RC" rev-parse HEAD)
SC="$T/s-clean"
(
  export REPO_ROOT="$RC" DEPLOY_LIB_DIR="$LIBDIR"
  unset FONTSET_DIR_NAME INSTALL_VIA_NIX
  DEPLOY_AT="$REV_OK" DEPLOY_HOME_DIR="$HC" DEPLOY_STATE_DIR="$SC"
  DEPLOY_WANT_APPLY=true DEPLOY_WANT_STATUS=false DEPLOY_WANT_DRYRUN=false
  # shellcheck disable=SC1091
  source "${ADOPTDIR}/0.run.sh" > /dev/null 2>&1
)
[[ $? == 0 ]] && pass "clean baseline applies" || fail "clean baseline applies"
grep -q '"fully_deployed": true' "$SC/deployment-identity.json" \
  && pass "clean baseline is fully_deployed" || fail "clean baseline is fully_deployed"

echo "--- set -e production parity ---"
# setup runs with `set -e`; bare `VAR=$(failing)` assignments would abort the
# run instead of reaching explicit error handling. Lock the guarded behavior.
( set -e; adopt_run "$REV_CLEAN" "$H2" "$T/s-sete" apply > /dev/null 2>&1 )
[[ $? == 0 ]] && pass "apply survives set -e" || fail "apply survives set -e"
( set -e; adopt_run "$REV_DEAD" "$H2" "$T/s-sete-dry" dryrun > /dev/null 2> "$T/sete-dry.err" )
[[ $? == 0 ]] && pass "lint-failure dry-run survives set -e" || fail "lint-failure dry-run survives set -e"
grep -q "lint:     PROBLEMS" "$T/sete-dry.err" \
  && pass "lint problems still reported under set -e" || fail "lint problems still reported under set -e"

echo "--- json escaping ---"# Branch off the clean rev so the dead-rule/stray history cannot interfere.
git -C "$R" checkout -qb weird "$REV_CLEAN"
printf 'x\n' > "$R/dots/.config/app/we'ird\"name.conf"
printf 'x\n' > "$H2/.config/app/we'ird\"name.conf"
git -C "$R" add -A
git -C "$R" "${GCOMMIT[@]}" "rev weird adds weird name"
REV_WEIRD=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -q main
S6="$T/s6"
adopt_run "$REV_WEIRD" "$H2" "$S6" apply > /dev/null 2>&1
[[ $? == 0 ]] && pass "weird filename applies" || fail "weird filename applies"
python3 -c "import json;[json.loads(l) for l in open('$S6/manifest.jsonl')]" \
  && pass "manifest with weird name still parses" || fail "manifest with weird name still parses"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
