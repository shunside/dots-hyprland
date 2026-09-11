#!/usr/bin/env bash
#
# Fixture tests for the global `impulse` launcher (sdata/lib/setup-launcher.sh
# + symlink-aware ./setup dispatch). Unit-tests install/remove semantics
# against a fake bin dir, then proves end-to-end dispatch from the repo
# directory, $HOME, and an unrelated temp dir. Everything lives under $T
# (plus a fake PATH entry); the real $HOME, real adoption state, and the
# network are never touched: every setup invocation passes explicit
# --home/--state-dir pointing inside $T.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBDIR="${HERE}/../../lib"
SRC="${DEPLOY_ENTRY_SRC:-$(cd "${HERE}/../../.." && pwd)}"
# shellcheck source=../lib/setup-launcher.sh
source "${LIBDIR}/environment-variables.sh"
source "${LIBDIR}/setup-launcher.sh"

PASS=0
FAIL=0
pass(){ PASS=$((PASS+1)); echo "PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }

T="$(mktemp -d /tmp/deploy-launcher-XXXXXX)"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$T"' EXIT

export REPO_ROOT="$SRC"
export XDG_BIN_HOME="$T/bin"
export PATH="$T/bin:$PATH"

echo "--- install/remove semantics ---"
setup_launcher_install > /tmp/lc-install.out 2>&1
[[ $? == 0 ]] && pass "install exits 0" || fail "install exits 0"
[[ -L "$T/bin/impulse" ]] && pass "launcher is a symlink" || fail "launcher is a symlink"
[[ "$(readlink -f "$T/bin/impulse")" == "$(readlink -f "$SRC/setup")" ]] \
  && pass "symlink targets this repo setup" || fail "symlink targets this repo setup"
setup_launcher_install > /tmp/lc-reinstall.out 2>&1
[[ $? == 0 ]] && grep -q "already installed" /tmp/lc-reinstall.out \
  && pass "reinstall is a no-op" || fail "reinstall is a no-op"
ln -sfn /bin/false "$T/bin/impulse"
setup_launcher_install > /tmp/lc-stale.out 2>&1
[[ $? == 0 ]] && [[ "$(readlink -f "$T/bin/impulse")" == "$(readlink -f "$SRC/setup")" ]] \
  && pass "stale symlink repaired" || fail "stale symlink repaired"
rm -f "$T/bin/impulse"
printf '#!/bin/sh\n' > "$T/bin/impulse"
setup_launcher_install > /tmp/lc-foreign.out 2>&1
[[ $? == 0 ]] && [[ ! -L "$T/bin/impulse" ]] && grep -q "leaving it alone" /tmp/lc-foreign.out \
  && pass "foreign occupant left alone" || fail "foreign occupant left alone"
rm -f "$T/bin/impulse"
setup_launcher_remove > /dev/null 2>&1
[[ $? == 0 ]] && pass "remove with no link exits 0" || fail "remove with no link exits 0"
ln -s "$SRC/setup" "$T/bin/impulse"
setup_launcher_remove > /dev/null 2>&1
[[ $? == 0 && ! -e "$T/bin/impulse" ]] && pass "remove deletes ours" || fail "remove deletes ours"
ln -s /bin/false "$T/bin/impulse"
setup_launcher_remove > /dev/null 2>&1
[[ -L "$T/bin/impulse" ]] && pass "remove leaves foreign link" || fail "remove leaves foreign link"
rm -f "$T/bin/impulse"
ln -s "$SRC/setup" "$T/bin/impulse"

echo "--- dispatch from arbitrary directories ---"
(cd "$SRC" && ./setup commands </dev/null > /tmp/lc-direct.out 2>&1)
[[ $? == 0 ]] && pass "direct commands exits 0" || fail "direct commands exits 0"
(cd "$HOME" && impulse commands </dev/null > /tmp/lc-home.out 2>&1)
[[ $? == 0 ]] && pass "impulse from HOME exits 0" || fail "impulse from HOME exits 0"
mkdir -p "$T/elsewhere" && (cd "$T/elsewhere" && impulse commands </dev/null > /tmp/lc-tmp.out 2>&1)
[[ $? == 0 ]] && pass "impulse from tmp exits 0" || fail "impulse from tmp exits 0"
if cmp -s /tmp/lc-home.out /tmp/lc-tmp.out; then
  pass "inventory identical across directories"
else
  fail "inventory identical across directories"
fi
grep -q "impulse update" /tmp/lc-tmp.out && pass "examples use invoked name" || fail "examples use invoked name"
grep -q "./setup update" /tmp/lc-direct.out && pass "direct keeps ./setup form" || fail "direct keeps ./setup form"
(cd "$T/elsewhere" && impulse update --help </dev/null > /tmp/lc-uhelp.out 2>&1)
[[ $? == 0 ]] && grep -q -- "--dry-run" /tmp/lc-uhelp.out \
  && pass "impulse update --help works anywhere" || fail "impulse update --help works anywhere"

echo "--- gates work through the launcher ---"
mkdir -p "$T/fhome/.config/app" "$T/fhome/.config/illogical-impulse"
# Present (uninitialized) shapes checkout keeps the submodule gate quiet so
# the decision gate is what blocks; the submodule refusal itself is covered
# by test-update's entrypoint and by the unadopted-state check ordering.
mkdir -p "$T/fhome/.config/quickshell/ii/modules/common/widgets/shapes"
(cd "$T/elsewhere" && impulse update --home "$T/fhome" --state-dir "$T/fstate" </dev/null > /tmp/lc-noadopt.out 2>&1)
[[ $? == 2 ]] && grep -q "not adopted" /tmp/lc-noadopt.out \
  && pass "unadopted refused via launcher" || fail "unadopted refused via launcher"
(cd "$SRC" && ./setup adopt --apply --at HEAD --home "$T/fhome" --state-dir "$T/fstate" </dev/null > /dev/null 2>&1)
[[ $? == 0 ]] && pass "fixture adopt exits 0" || fail "fixture adopt exits 0"
# Explicit --at keeps this hermetic: the default path would fetch the
# real repo's configured remote over the network.
(cd "$T/elsewhere" && impulse update --dry-run --at HEAD --home "$T/fhome" --state-dir "$T/fstate" </dev/null > /tmp/lc-dry.out 2>&1)
[[ $? == 2 ]] && grep -q "need your decisions" /tmp/lc-dry.out \
  && pass "undecided refused via launcher" || fail "undecided refused via launcher"
[[ ! -e "$T/fstate/applies" && ! -e "$T/fstate/apply.lock" ]] \
  && pass "refusal writes no transaction state" || fail "refusal writes no transaction state"

echo "--- launcher self-delivery in adopt/update ---"
LR="$T/lrepo"
mkdir -p "$LR"
git -C "$LR" init -qb main
git -C "$LR" config user.email "fixture@example"
git -C "$LR" config user.name "fixture"
git -C "$LR" config commit.gpgsign false
mkdir -p "$LR/dots/.config/app" "$LR/sdata/deploy"
printf 'managed dots/.config/app .config/app\n' > "$LR/sdata/deploy/ownership.conf"
printf 'v1\n' > "$LR/dots/.config/app/upd.conf"
git -C "$LR" add -A
git -C "$LR" -c user.email=fixture@example -c user.name=fixture -c commit.gpgsign=false commit -qm "launcher rev"
REV_L0=$(git -C "$LR" rev-parse HEAD)
OH="$T/ohome"
mkdir -p "$OH/.config/app" "$OH/.config/illogical-impulse"
printf 'v1\n' > "$OH/.config/app/upd.conf"
adopt_own(){
  (
    export HOME="$OH" XDG_CONFIG_HOME="$OH/.config" XDG_DATA_HOME="$OH/.local/share" XDG_BIN_HOME="$OH/.local/bin"
    export REPO_ROOT="$LR" DEPLOY_LIB_DIR="$LIBDIR"
    unset FONTSET_DIR_NAME INSTALL_VIA_NIX
    DEPLOY_AT="$REV_L0" DEPLOY_HOME_DIR="$OH" DEPLOY_STATE_DIR=""
    DEPLOY_WANT_APPLY=true DEPLOY_WANT_STATUS=false DEPLOY_WANT_DRYRUN=false DEPLOY_WANT_RECONCILE=false
    # shellcheck disable=SC1091
    source "${HERE}/../../subcmd-adopt/0.run.sh" > /tmp/lc-adopt-own.out 2>&1
  )
}
update_own(){
  local dry="$1"
  (
    export HOME="$OH" XDG_CONFIG_HOME="$OH/.config" XDG_DATA_HOME="$OH/.local/share"
    export XDG_BIN_HOME="${OWN_BIN_OVERRIDE:-$OH/.local/bin}"
    export REPO_ROOT="$LR" DEPLOY_LIB_DIR="$LIBDIR"
    unset FONTSET_DIR_NAME INSTALL_VIA_NIX
    DEPLOY_AT="HEAD" DEPLOY_HOME_DIR="$OH" DEPLOY_STATE_DIR=""
    DEPLOY_APPLY_FONTSET=""; DEPLOY_APPLY_FONTSET_SET=false; DEPLOY_APPLY_VIANIX_SET=false
    DEPLOY_UPDATE_DRYRUN="$dry" DEPLOY_UPDATE_VERBOSE=false
    declare -a APPLY_RESOLVE=()
    # shellcheck disable=SC1091
    source "${HERE}/../../subcmd-update/0.run.sh" > /tmp/lc-update-own.out 2>&1
  )
}
adopt_own
[[ $? == 0 ]] && pass "own-home adopt exits 0" || fail "own-home adopt exits 0"
[[ -L "$OH/.local/bin/impulse" ]] && pass "adopt delivers launcher" || fail "adopt delivers launcher"
[[ "$(readlink -f "$OH/.local/bin/impulse")" == "$(readlink -f "$LR/setup")" ]] \
  && pass "launcher points at adopted repo" || fail "launcher points at adopted repo"
grep -q "now works from any directory" /tmp/lc-adopt-own.out \
  && pass "adopt announces the launcher once" || fail "adopt announces the launcher once"
rm -f "$OH/.local/bin/impulse"
printf 'v2\n' > "$LR/dots/.config/app/upd.conf"
git -C "$LR" add -A
git -C "$LR" -c user.email=fixture@example -c user.name=fixture -c commit.gpgsign=false commit -qm "launcher delta"
update_own false
[[ $? == 0 ]] && pass "own-home update exits 0" || fail "own-home update exits 0"
[[ "$(cat "$OH/.config/app/upd.conf")" == "v2" ]] && pass "update delivered through lifecycle" || fail "update delivered through lifecycle"
[[ -L "$OH/.local/bin/impulse" ]] \
  && pass "update delivers launcher" || fail "update delivers launcher"
printf 'x' > "$T/binblock"
OWN_BIN_OVERRIDE="$T/binblock" update_own false
[[ $? == 0 ]] && grep -q "could not install" /tmp/lc-update-own.out \
  && pass "launcher failure only warns" || fail "launcher failure only warns"
unset OWN_BIN_OVERRIDE
rm -f "$T/binblock"
mkdir -p "$T/foreign2"
(
  export REPO_ROOT="$LR" DEPLOY_LIB_DIR="$LIBDIR"
  unset FONTSET_DIR_NAME INSTALL_VIA_NIX
  export XDG_BIN_HOME="$T/fakebin2"
  DEPLOY_AT="$REV_L0" DEPLOY_HOME_DIR="$T/foreign2" DEPLOY_STATE_DIR="$T/fstate2"
  DEPLOY_WANT_APPLY=true DEPLOY_WANT_STATUS=false DEPLOY_WANT_DRYRUN=false DEPLOY_WANT_RECONCILE=false
  # shellcheck disable=SC1091
  source "${HERE}/../../subcmd-adopt/0.run.sh" > /dev/null 2>&1
)
[[ $? == 0 ]] && pass "foreign adopt exits 0" || fail "foreign adopt exits 0"
[[ ! -e "$T/fakebin2" ]] && pass "foreign adopt leaves bin alone" || fail "foreign adopt leaves bin alone"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
