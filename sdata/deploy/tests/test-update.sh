#!/usr/bin/env bash
#
# Fixture tests for the `setup update` one-command flow
# (sdata/subcmd-update). Drives the real driver the way `setup` sources it
# (same `set -e` production shell in the entrypoint half), plus a real
# `./setup` end-to-end half that catches dispatcher/options divergences.
# Everything lives under $T; the real $HOME and network are never touched.
# Standard input is closed for every driver invocation: update must never
# prompt, so non-interactive runs are the only runs tested here.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBDIR="${HERE}/../../lib"
ADOPTDIR="${HERE}/../../subcmd-adopt"
UPDATEDIR="${HERE}/../../subcmd-update"
DECIDEDIR="${HERE}/../../subcmd-decide"
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

T="$(mktemp -d /tmp/deploy-update-XXXXXX)"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$T"' EXIT

R="$T/repo"
mkdir -p "$R"
git -C "$R" init -qb main
git -C "$R" config user.email "fixture@example"
git -C "$R" config user.name "fixture"
git -C "$R" config commit.gpgsign false
GCOMMIT=(-c user.email=fixture@example -c user.name=fixture -c commit.gpgsign=false commit -qm)
export REPO_ROOT="$R"

mkdir -p "$R/dots/.config/app" "$R/sdata/deploy"
cat > "$R/sdata/deploy/ownership.conf" <<'EOF'
managed dots/.config/app .config/app
EOF
printf 'same\n' > "$R/dots/.config/app/keep.conf"
printf 'v1\n' > "$R/dots/.config/app/upd.conf"
git -C "$R" add -A
git -C "$R" "${GCOMMIT[@]}" "rev base"
REV_B=$(git -C "$R" rev-parse HEAD)

H0="$T/home0"
mkdir -p "$H0/.config/app" "$H0/.config/illogical-impulse"
printf 'same\n' > "$H0/.config/app/keep.conf"
printf 'v1\n' > "$H0/.config/app/upd.conf"
printf '%s/.config/app/keep.conf\n' "$H0" > "$H0/.config/illogical-impulse/installed_listfile"

printf 'v2\n' > "$R/dots/.config/app/upd.conf"
printf 'new\n' > "$R/dots/.config/app/new.conf"
git -C "$R" add -A
git -C "$R" "${GCOMMIT[@]}" "rev target"
REV_T=$(git -C "$R" rev-parse HEAD)

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
    # shellcheck disable=SC1091
    source "${ADOPTDIR}/0.run.sh" > /dev/null 2>&1
  ) || { echo "fixture adoption failed for $name" >&2; return 1; }
}

# Drive subcmd-update exactly the way ./setup sources it (exits contained).
update_run(){
  local mode="$1" home="$2" statedir="$3" extra_env="${4:-}"
  (
    export REPO_ROOT="$R" DEPLOY_LIB_DIR="$LIBDIR"
    unset FONTSET_DIR_NAME INSTALL_VIA_NIX
    # shellcheck disable=SC2086
    eval "$extra_env"
    DEPLOY_AT="$REV_T" DEPLOY_HOME_DIR="$home" DEPLOY_STATE_DIR="$statedir"
    DEPLOY_APPLY_FONTSET=""; DEPLOY_APPLY_FONTSET_SET=false; DEPLOY_APPLY_VIANIX_SET=false
    DEPLOY_UPDATE_DRYRUN=false
    DEPLOY_UPDATE_VERBOSE=false
    declare -a APPLY_RESOLVE=()
    case "$mode" in
      dryrun) DEPLOY_UPDATE_DRYRUN=true;;
      verbose) DEPLOY_UPDATE_VERBOSE=true;;
    esac
    # shellcheck disable=SC1091
    source "${UPDATEDIR}/0.run.sh"
  ) < /dev/null
}

disk_snapshot(){
  (cd "$1" && find . \( -type f -exec sha256sum {} + \; -o -type l -printf 'L %p -> %l\n' \) 2>/dev/null | sort)
}

echo "--- clean update applies ---"
fresh_case clean
apply_count_before=$(find "$T/clean-state" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
update_run apply "$T/clean-home" "$T/clean-state" > /tmp/upd-clean.out 2>&1
[[ $? == 0 ]] && pass "clean update exits 0" || fail "clean update exits 0: $(tail -n 3 /tmp/upd-clean.out)"
grep -q "1 updates, 1 new, 0 deletions, 0 sidecars" /tmp/upd-clean.out \
  && pass "summary counts the operation set" || fail "summary counts the operation set"
grep -q "Updated to " /tmp/upd-clean.out && grep -q "fully_deployed=true" /tmp/upd-clean.out \
  && pass "success names target and deployment state" || fail "success names target and deployment state"
[[ "$(cat "$T/clean-home/.config/app/upd.conf")" == "v2" ]] && pass "update delivered" || fail "update delivered"
[[ "$(cat "$T/clean-home/.config/app/new.conf")" == "new" ]] && pass "new file installed" || fail "new file installed"
grep -q '"path":".config/app/upd.conf","kind":"file","class":"managed","status":"confirmed"' "$T/clean-state/manifest.jsonl" \
  && pass "updated row confirmed at target" || fail "updated row confirmed at target"

echo "--- nothing left to do is clean ---"
update_run apply "$T/clean-home" "$T/clean-state" > /tmp/upd-noop.out 2>&1
[[ $? == 0 ]] && pass "second update exits 0" || fail "second update exits 0"
[[ $? == 0 ]] && grep -q "Already up to date" /tmp/upd-noop.out \
  && pass "reports up-to-date" || fail "reports up-to-date"
[[ "$(find "$T/clean-state/applies" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)" == 1 ]] \
  && pass "noop update opens no new transaction" || fail "noop update opens no new transaction"

echo "--- update-from follows the last applied target ---"
printf 'v3\n' > "$R/dots/.config/app/upd.conf"
git -C "$R" add -A
git -C "$R" "${GCOMMIT[@]}" "rev third"
REV_U=$(git -C "$R" rev-parse HEAD)
REV_T_SHORT=$(git -C "$R" rev-parse --short "$REV_T")
# Point the clean fixture at the newer revision without touching decisions:
# the previously applied revT is recorded in last_apply, so the summary
# must present revT -> revU, not baseline -> revU.
(
  export REPO_ROOT="$R" DEPLOY_LIB_DIR="$LIBDIR"
  unset FONTSET_DIR_NAME INSTALL_VIA_NIX
  DEPLOY_AT="$REV_U" DEPLOY_HOME_DIR="$T/clean-home" DEPLOY_STATE_DIR="$T/clean-state"
  DEPLOY_APPLY_FONTSET=""; DEPLOY_APPLY_FONTSET_SET=false; DEPLOY_APPLY_VIANIX_SET=false
  DEPLOY_UPDATE_DRYRUN=true
  DEPLOY_UPDATE_VERBOSE=false
  declare -a APPLY_RESOLVE=()
  # shellcheck disable=SC1091
  source "${UPDATEDIR}/0.run.sh"
) < /dev/null > /tmp/upd-from.out 2>&1
[[ $? == 0 ]] && pass "third-rev dry run exits 0" || fail "third-rev dry run exits 0"
grep -q "Updating payload $REV_T_SHORT" /tmp/upd-from.out \
  && pass "summary starts from last applied target" || fail "summary starts from last applied target: $(grep '^Updating' /tmp/upd-from.out)"
grep -q "1 updates" /tmp/upd-from.out && pass "third rev proposes one update" || fail "third rev proposes one update"
fresh_case dry
SNAP_DRY=$(disk_snapshot "$T/dry-home")
update_run dryrun "$T/dry-home" "$T/dry-state" > /tmp/upd-dry.out 2>&1
[[ $? == 0 ]] && pass "dry run exits 0" || fail "dry run exits 0"
grep -q "dry run" /tmp/upd-dry.out && pass "dry run says so" || fail "dry run says so"
[[ "$(disk_snapshot "$T/dry-home")" == "$SNAP_DRY" ]] && pass "dry run leaves home alone" || fail "dry run leaves home alone"
[[ ! -e "$T/dry-state/applies" && ! -e "$T/dry-state/apply.lock" ]] \
  && pass "dry run leaves no transaction state" || fail "dry run leaves no transaction state"

echo "--- undecided rows block with guidance ---"
fresh_case blocked
printf 'local-edit\n' > "$T/blocked-home/.config/app/upd.conf"
SNAP_BLOCKED=$(disk_snapshot "$T/blocked-home")
update_run apply "$T/blocked-home" "$T/blocked-state" > /tmp/upd-blocked.out 2>&1
[[ $? == 2 ]] && pass "blocked update exits 2" || fail "blocked update exits 2"
grep -q "need your decisions" /tmp/upd-blocked.out && grep -q "decide --set" /tmp/upd-blocked.out \
  && pass "blockage names the decide command" || fail "blockage names the decide command"
grep -q ".config/app/upd.conf" /tmp/upd-blocked.out \
  && pass "blockage lists the path" || fail "blockage lists the path"
[[ "$(disk_snapshot "$T/blocked-home")" == "$SNAP_BLOCKED" ]] && pass "blocked update writes no home files" || fail "blocked update writes no home files"
[[ ! -e "$T/blocked-state/applies" && ! -e "$T/blocked-state/apply.lock" ]] \
  && pass "blocked update writes no transaction state" || fail "blocked update writes no transaction state"

echo "--- stale decisions block, not apply ---"
fresh_case stale
decide_stale(){
  (
    export REPO_ROOT="$R" DEPLOY_LIB_DIR="$LIBDIR" STATED="$T/stale-state" HOMED="$T/stale-home"
    unset FONTSET_DIR_NAME INSTALL_VIA_NIX
    DEPLOY_AT="$REV_T" DEPLOY_HOME_DIR="$HOMED" DEPLOY_STATE_DIR="$STATED"
    DEPLOY_DECIDE_SET=(".config/app/upd.conf=replace") DEPLOY_DECIDE_REMOVE=() DEPLOY_DECIDE_LIST=false
    DEPLOY_DECIDE_FONTSET=""; DEPLOY_DECIDE_FONTSET_SET=false; DEPLOY_DECIDE_VIANIX_SET=false
    # shellcheck disable=SC1091
    source "${HERE}/../../subcmd-decide/0.run.sh" > /dev/null 2>&1
  )
}
printf 'disk-edit\n' > "$T/stale-home/.config/app/upd.conf"
decide_stale
printf 'drifted-again\n' > "$T/stale-home/.config/app/upd.conf"
update_run apply "$T/stale-home" "$T/stale-state" > /tmp/upd-stale.out 2>&1
[[ $? == 2 ]] && pass "stale decision exits 2" || fail "stale decision exits 2"
grep -q "no longer matches" /tmp/upd-stale.out && pass "stale names itself" || fail "stale names itself"
[[ ! -e "$T/stale-state/applies" ]] && pass "stale writes no transaction state" || fail "stale writes no transaction state"

echo "--- verbose streams technical detail ---"
update_run verbose "$T/blocked-home" "$T/blocked-state" > /tmp/upd-verbose.out 2>&1
[[ $? == 2 ]] && pass "verbose blocked exits 2" || fail "verbose blocked exits 2"
grep -q "preflight refused" /tmp/upd-verbose.out && pass "verbose shows technical report" || fail "verbose shows technical report"

echo "--- open transaction blocks with recovery pointers ---"
fresh_case txn
TXID="fixture-open-tx"
mkdir -p "$T/txn-state/applies/$TXID" "$T/txn-state/snapshots/$TXID"
printf '{"seq":1,"type":"header","apply_id":"%s"}\n' "$TXID" > "$T/txn-state/applies/$TXID/journal.jsonl"
cp "$T/txn-state/manifest.jsonl" "$T/txn-state/snapshots/$TXID/manifest.jsonl"
SNAP_TXN=$(disk_snapshot "$T/txn-home")
update_run apply "$T/txn-home" "$T/txn-state" > /tmp/upd-txn.out 2>&1
[[ $? == 2 ]] && pass "open transaction exits 2" || fail "open transaction exits 2"
grep -q "resume" /tmp/upd-txn.out && grep -q "abort" /tmp/upd-txn.out \
  && pass "blockage points at resume/abort" || fail "blockage points at resume/abort"
grep -q "$TXID" /tmp/upd-txn.out && pass "blockage names the transaction" || fail "blockage names the transaction"
[[ "$(disk_snapshot "$T/txn-home")" == "$SNAP_TXN" ]] && pass "open-txn block writes nothing home" || fail "open-txn block writes nothing home"

echo "--- missing adoption blocks with adopt pointers ---"
rm -rf "$T/nostate-home" "$T/nostate-state"
cp -r "$H0" "$T/nostate-home"
update_run apply "$T/nostate-home" "$T/nostate-state" > /tmp/upd-noadopt.out 2>&1
[[ $? == 2 ]] && pass "unadopted exits 2" || fail "unadopted exits 2"
grep -q "adopt" /tmp/upd-noadopt.out && pass "blockage points at adopt" || fail "blockage points at adopt"
[[ ! -e "$T/nostate-state" ]] && pass "unadopted block creates no state" || fail "unadopted block creates no state"

echo "--- corrupt state refuses ---"
fresh_case corrupt
printf '}\n' >> "$T/corrupt-state/manifest.jsonl"
update_run apply "$T/corrupt-home" "$T/corrupt-state" > /tmp/upd-corrupt.out 2>&1
[[ $? == 1 ]] && pass "corrupt state exits 1" || fail "corrupt state exits 1"

echo "--- real entrypoint: help UX ---"
SRC="${DEPLOY_ENTRY_SRC:-$(cd "${HERE}/../../.." && pwd)}"
I="$T/intrepo"
IH="$T/inthome"
IS="$T/intstate"
mkdir -p "$IH/.config/app"
git clone -q "$SRC" "$I"
git -C "$I" checkout -qb inttest
git -C "$I" config user.email "fixture@example"
git -C "$I" config user.name "fixture"
git -C "$I" config commit.gpgsign false
# Worktree implementation under test (tracked modifications + new files).
cp "$SRC/setup" "$I/setup"
mkdir -p "$I/sdata/deploy" "$I/sdata/lib"
mkdir -p "$I/sdata/subcmd-adopt" "$I/sdata/subcmd-plan" "$I/sdata/subcmd-decide"
mkdir -p "$I/sdata/subcmd-apply" "$I/sdata/subcmd-update" "$I/sdata/subcmd-commands"
cp "$SRC/sdata/deploy/ownership.conf" "$I/sdata/deploy/"
cp "$SRC/sdata/lib/deploy-common.sh" "$SRC/sdata/lib/deploy-state.sh" "$SRC/sdata/lib/deploy-plan.sh" \
  "$SRC/sdata/lib/deploy-decide.sh" "$SRC/sdata/lib/deploy-apply.sh" \
  "$SRC/sdata/lib/setup-launcher.sh" "$SRC/sdata/lib/terminal-spin.sh" "$I/sdata/lib/"
cp "$SRC/sdata/subcmd-adopt/options.sh" "$SRC/sdata/subcmd-adopt/0.run.sh" "$I/sdata/subcmd-adopt/"
cp "$SRC/sdata/subcmd-plan/options.sh" "$SRC/sdata/subcmd-plan/0.run.sh" "$I/sdata/subcmd-plan/"
cp "$SRC/sdata/subcmd-decide/options.sh" "$SRC/sdata/subcmd-decide/0.run.sh" "$I/sdata/subcmd-decide/"
cp "$SRC/sdata/subcmd-apply/options.sh" "$SRC/sdata/subcmd-apply/0.run.sh" "$I/sdata/subcmd-apply/"
cp "$SRC/sdata/subcmd-update/options.sh" "$SRC/sdata/subcmd-update/0.run.sh" "$I/sdata/subcmd-update/"
cp "$SRC/sdata/subcmd-commands/options.sh" "$SRC/sdata/subcmd-commands/0.run.sh" "$I/sdata/subcmd-commands/"
"$I/setup" </dev/null > /tmp/upd-help-bare.out 2>&1
[[ $? == 0 ]] && pass "bare setup exits 0" || fail "bare setup exits 0"
grep -q "illogical-impulse setup" /tmp/upd-help-bare.out \
  && pass "bare help is a landing screen" || fail "bare help is a landing screen"
grep -q "setup update --dry-run" /tmp/upd-help-bare.out \
  && pass "landing leads with update" || fail "landing leads with update"
grep -q "setup commands" /tmp/upd-help-bare.out \
  && pass "landing points at full inventory" || fail "landing points at full inventory"
if grep -q "virtmon\|install\.sh\|Inspect and control" /tmp/upd-help-bare.out; then
  fail "landing keeps internals out of sight"
else
  pass "landing keeps internals out of sight"
fi
if grep -q $'\e' /tmp/upd-help-bare.out; then
  fail "piped help degrades to plain text"
else
  pass "piped help degrades to plain text"
fi
"$I/setup" help </dev/null > /tmp/upd-help-cmd.out 2>&1
[[ $? == 0 ]] && pass "setup help exits 0" || fail "setup help exits 0"
grep -q "update" /tmp/upd-help-cmd.out && pass "setup help lists update" || fail "setup help lists update"
"$I/setup" update --help </dev/null > /tmp/upd-help-update.out 2>&1
[[ $? == 0 ]] && pass "update --help exits 0" || fail "update --help exits 0"
grep -q -- "--dry-run" /tmp/upd-help-update.out && grep -q "Example" /tmp/upd-help-update.out \
  && pass "update help documents flags and examples" || fail "update help documents flags and examples"
"$I/setup" update --help-all </dev/null > /tmp/upd-help-all.out 2>&1
[[ $? == 0 ]] && pass "update --help-all exits 0" || fail "update --help-all exits 0"
grep -qi "advanced reference" /tmp/upd-help-all.out && grep -q -- "--state-dir" /tmp/upd-help-all.out \
  && pass "advanced help lists advanced controls" || fail "advanced help lists advanced controls"
"$I/setup" commands </dev/null > /tmp/upd-commands.out 2>&1
[[ $? == 0 ]] && pass "commands view exits 0" || fail "commands view exits 0"
grep -q "Development:" /tmp/upd-commands.out && grep -q "virtmon" /tmp/upd-commands.out \
  && pass "commands view reveals internals" || fail "commands view reveals internals"
grep -q "install-deps" /tmp/upd-commands.out \
  && pass "commands view covers installer pieces" || fail "commands view covers installer pieces"
"$I/setup" frobnicator </dev/null > /dev/null 2>&1
[[ $? == 1 ]] && pass "unknown subcommand still fails" || fail "unknown subcommand still fails"

echo "--- real entrypoint: clean update end to end ---"
# Narrow the fixture payload to inttest only: the cloned worktree carries
# the real quickshell gitlinks (no checkouts in a clone), and the
# updater correctly refuses to proceed past submodule-missing rows.
rm -rf "$I/dots"
mkdir -p "$I/dots/.config/inttest"
printf 'managed dots/.config/inttest .config/inttest\n' > "$I/sdata/deploy/ownership.conf"
printf 'same\n' > "$I/dots/.config/inttest/keep.conf"
printf 'v1\n' > "$I/dots/.config/inttest/change.conf"
mkdir -p "$IH/.config/inttest"
printf 'same\n' > "$IH/.config/inttest/keep.conf"
printf 'v1\n' > "$IH/.config/inttest/change.conf"
git -C "$I" add -A
git -C "$I" -c user.email=fixture@example -c user.name=fixture -c commit.gpgsign=false commit -qm "inttest baseline"
"$I/setup" adopt --apply --at HEAD --home "$IH" --state-dir "$IS" </dev/null > /dev/null 2>&1
[[ $? == 0 ]] && pass "real adopt exits 0" || fail "real adopt exits 0"
printf 'v2\n' > "$I/dots/.config/inttest/change.conf"
git -C "$I" add -A
git -C "$I" -c user.email=fixture@example -c user.name=fixture -c commit.gpgsign=false commit -qm "inttest delta"
"$I/setup" update --home "$IH" --state-dir "$IS" </dev/null > /tmp/upd-entry.out 2>&1
[[ $? == 0 ]] && pass "real update exits 0" || fail "real update exits 0: $(tail -n 3 /tmp/upd-entry.out)"
grep -q "1 updates" /tmp/upd-entry.out && pass "real update summarizes" || fail "real update summarizes"
[[ "$(cat "$IH/.config/inttest/change.conf")" == "v2" ]] && pass "real update delivered" || fail "real update delivered"
"$I/setup" update --home "$IH" --state-dir "$IS" </dev/null > /tmp/upd-entry2.out 2>&1
[[ $? == 0 ]] && grep -q "Already up to date" /tmp/upd-entry2.out \
  && pass "real second update is a noop" || fail "real second update is a noop"
printf 'local\n' > "$IH/.config/inttest/change.conf"
"$I/setup" update --dry-run --home "$IH" --state-dir "$IS" </dev/null > /tmp/upd-entry3.out 2>&1
[[ $? == 2 ]] && pass "real drifted update blocks" || fail "real drifted update blocks"
grep -q "decide" /tmp/upd-entry3.out && pass "real blockage guides" || fail "real blockage guides"
[[ "$(cat "$IH/.config/inttest/change.conf")" == "local" ]] && pass "blocked run preserves live" || fail "blocked run preserves live"

echo "--- pty transitions leave no residue ---"
if ! command -v script >/dev/null 2>&1; then
  echo "SKIP: script(1) unavailable for pty checks"
else
  # Driver wrapper: update_run's environment as a file so script(1) can
  # execute it under a pty. Raw bytes are kept (no CR stripping): every
  # persistent line must start its own segment, and no spinner fragment
  # may share one (the reported concatenation bug).
  cat > "$T/pty-update.sh" <<'SCRIPT'
unset FONTSET_DIR_NAME INSTALL_VIA_NIX
DEPLOY_HOME_DIR="$PTY_HOME" DEPLOY_STATE_DIR="$PTY_STATE"
DEPLOY_AT="${PTY_AT:-HEAD}" DEPLOY_UPDATE_AT_GIVEN=false
[[ -n "${PTY_AT:-}" ]] && DEPLOY_UPDATE_AT_GIVEN=true
DEPLOY_APPLY_FONTSET=""; DEPLOY_APPLY_FONTSET_SET=false; DEPLOY_APPLY_VIANIX_SET=false
DEPLOY_UPDATE_DRYRUN="${PTY_DRYRUN:-false}" DEPLOY_UPDATE_VERBOSE=false
declare -a APPLY_RESOLVE=()
# shellcheck disable=SC1091
source "${UPDATEDIR}/0.run.sh"
SCRIPT
  pty_run(){
    TERM_SPIN_INTERVAL=0.001 script -qec "bash $T/pty-update.sh" /dev/null > "$T/pty-raw.out" 2>&1 < /dev/null
  }
  export REPO_ROOT="$R" DEPLOY_LIB_DIR="$LIBDIR" UPDATEDIR
  export TERM_SPIN_INTERVAL=0.001
  export PTY_HOME="$T/clean-home" PTY_STATE="$T/clean-state" PTY_AT="" PTY_DRYRUN=true
  pty_run
  [[ $? == 0 ]] && pass "pty dry run exits 0" || fail "pty dry run exits 0"
  tr '\r' '\n' < "$T/pty-raw.out" | grep -c '^Updating ' | grep -q '^1$' \
    && pass "summary starts its own segment" || fail "summary starts its own segment"
  if grep -q 'Evaluating updateUpdating' "$T/pty-raw.out"; then
    fail "no spinner residue before summary"
  else
    pass "no spinner residue before summary"
  fi
  grep -q '1 updates' "$T/pty-raw.out" \
    && pass "dry run reports the pending update" || fail "dry run reports the pending update"
  export PTY_HOME="$T/blocked-home" PTY_STATE="$T/blocked-state"
  pty_run
  [[ $? == 2 ]] && pass "pty blocked exits 2" || fail "pty blocked exits 2"
  tr '\r' '\n' < "$T/pty-raw.out" | grep -q '^! Update blocked' \
    && pass "blockage starts its own segment" || fail "blockage starts its own segment"
  rm -rf "$T/pty-home" "$T/pty-state"
  cp -r "$H0" "$T/pty-home"
  printf '%s/.config/app/keep.conf\n' "$T/pty-home" > "$T/pty-home/.config/illogical-impulse/installed_listfile"
  (
    export REPO_ROOT="$R" DEPLOY_LIB_DIR="$LIBDIR"
    unset FONTSET_DIR_NAME INSTALL_VIA_NIX
    DEPLOY_AT="$REV_B" DEPLOY_HOME_DIR="$T/pty-home" DEPLOY_STATE_DIR="$T/pty-state"
    DEPLOY_WANT_APPLY=true DEPLOY_WANT_STATUS=false DEPLOY_WANT_DRYRUN=false
    # shellcheck disable=SC1091
    source "${ADOPTDIR}/0.run.sh" > /dev/null 2>&1
  ) || fail "pty fixture adoption failed"
  export PTY_HOME="$T/pty-home" PTY_STATE="$T/pty-state" PTY_AT="" PTY_DRYRUN=false
  pty_run
  [[ $? == 0 ]] && pass "pty success exits 0" || fail "pty success exits 0: $(tail -n 2 "$T/pty-raw.out")"
  tr '\r' '\n' < "$T/pty-raw.out" | grep -q '^✓ Updated to' \
    && pass "success starts its own segment" || fail "success starts its own segment"
  if grep -q 'Applying update✓ Updated' "$T/pty-raw.out"; then
    fail "no spinner residue before result"
  else
    pass "no spinner residue before result"
  fi
  export PTY_DRYRUN=true
  pty_run
  [[ $? == 0 ]] && pass "pty second dry run exits 0" || fail "pty second dry run exits 0"
  tr '\r' '\n' < "$T/pty-raw.out" | grep -q '^✓ Already up to date' \
    && pass "noop result starts its own segment" || fail "noop result starts its own segment"
fi

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
