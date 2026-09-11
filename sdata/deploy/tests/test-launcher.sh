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
# Contain the managed fish PATH drop-in too: install() writes it under
# XDG_CONFIG_HOME, which would otherwise be the real home here.
export XDG_CONFIG_HOME="$T/xdg"
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
setup_launcher_install > /tmp/lc-path.out 2>&1
[[ $? == 0 ]] && pass "install exits 0" || fail "install exits 0"
[[ -f "$T/xdg/fish/conf.d/impulse-path.fish" ]] \
  && pass "install persists fish PATH drop-in" || fail "install persists fish PATH drop-in"
[[ "$(head -n 1 "$T/xdg/fish/conf.d/impulse-path.fish")" == "# impulse-path (managed by illogical-impulse setup)" ]] \
  && pass "drop-in carries the ownership marker" || fail "drop-in carries the ownership marker"
grep -qF "set -gx PATH \"$T/bin\" \$PATH" "$T/xdg/fish/conf.d/impulse-path.fish" \
  && pass "drop-in prepends the launcher dir" || fail "drop-in prepends the launcher dir"
printf '# user content\n' > "$T/xdg/fish/conf.d/impulse-path.fish"
setup_launcher_install > /tmp/lc-pathforeign.out 2>&1
[[ $? == 0 ]] && [[ "$(cat "$T/xdg/fish/conf.d/impulse-path.fish")" == "# user content" ]] \
  && pass "foreign drop-in left alone" || fail "foreign drop-in left alone"
rm -f "$T/xdg/fish/conf.d/impulse-path.fish"
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
# NOTE: copy before any mkdir of $LR/sdata, or cp -r nests sdata/sdata.
cp -r "$SRC/sdata" "$LR/sdata"
cp "$SRC/setup" "$LR/setup"
mkdir -p "$LR/dots/.config/app"
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
grep -q "new shells pick it up automatically" /tmp/lc-adopt-own.out \
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

echo "--- persistent PATH and new-shell resolution ---"
# Field model: ~/.local/bin exists but is absent from PATH, no launcher,
# fish is the shell. Everything resolves inside the fixture home.
PH="$T/pathhome"
mkdir -p "$PH/.config/app" "$PH/.config/illogical-impulse" "$PH/.local/bin"
printf 'v2\n' > "$PH/.config/app/upd.conf"
printf '#!/bin/sh\necho unrelated\n' > "$PH/.local/bin/other-tool"
chmod +x "$PH/.local/bin/other-tool"
REV_PH=$(git -C "$LR" rev-parse HEAD)
adopt_home(){
  (
    export HOME="$PH" XDG_CONFIG_HOME="$PH/.config" XDG_DATA_HOME="$PH/.local/share" XDG_BIN_HOME="$PH/.local/bin"
    export REPO_ROOT="$LR" DEPLOY_LIB_DIR="$LIBDIR"
    unset FONTSET_DIR_NAME INSTALL_VIA_NIX
    DEPLOY_AT="$REV_PH" DEPLOY_HOME_DIR="$PH" DEPLOY_STATE_DIR=""
    DEPLOY_WANT_APPLY=true DEPLOY_WANT_STATUS=false DEPLOY_WANT_DRYRUN=false DEPLOY_WANT_RECONCILE=false
    # shellcheck disable=SC1091
    source "${HERE}/../../subcmd-adopt/0.run.sh" > /tmp/lc-adopt-ph.out 2>&1
  )
}
FISHBIN="$(command -v fish || true)"
# A brand-new session: scrubbed environment, fixture bin NOT on PATH.
new_fish(){
  env -i HOME="$PH" PATH="/usr/bin:/bin" "$FISHBIN" -c "$1"
}
adopt_home
[[ $? == 0 ]] && pass "path-model adopt exits 0" || fail "path-model adopt exits 0"
[[ -L "$PH/.local/bin/impulse" ]] && pass "lifecycle creates the launcher" || fail "lifecycle creates the launcher"
[[ -f "$PH/.config/fish/conf.d/impulse-path.fish" ]] \
  && pass "lifecycle persists the PATH drop-in" || fail "lifecycle persists the PATH drop-in"
# The reported presentation bug: styles set (tty) but printed literally.
# Force styled output and prove the note renders real escapes, not text.
(
  export HOME="$T/shome" XDG_CONFIG_HOME="$T/shome/.config" XDG_BIN_HOME="$T/shome/.local/bin"
  export REPO_ROOT="$SRC" DEPLOY_HOME="$T/shome" DEPLOY_SELF_HOME="$T/shome"
  mkdir -p "$T/shome"
  STY_FAINT='\e[2m' STY_RST='\e[00m' setup_launcher_ensure > /tmp/lc-styled.out 2>&1
)
grep -q "new shells pick it up automatically" /tmp/lc-styled.out \
  && pass "styled note announces" || fail "styled note announces"
if grep -qF '\e' /tmp/lc-styled.out; then
  fail "styled note has no literal escapes"
else
  pass "styled note has no literal escapes"
fi
[[ -x "$PH/.local/bin/other-tool" && "$(cat "$PH/.local/bin/other-tool")" == "$(printf '#!/bin/sh\necho unrelated')" ]] \
  && pass "unrelated bin entry untouched" || fail "unrelated bin entry untouched"
if [[ -z "$FISHBIN" ]]; then
  echo "SKIP: fish unavailable for new-session checks"
else
  [[ "$(new_fish 'command -v impulse')" == "$PH/.local/bin/impulse" ]] \
    && pass "new fish session resolves impulse" || fail "new fish session resolves impulse: $(new_fish 'command -v impulse' 2>&1)"
  (cd /tmp && new_fish 'impulse commands' > /tmp/lc-fish-out.txt 2>&1)
  [[ $? == 0 ]] && grep -q "impulse update" /tmp/lc-fish-out.txt \
    && pass "impulse works outside the repo in a new shell" || fail "impulse works outside the repo in a new shell"
fi
SNIP_SUM="$(sha256sum "$PH/.config/fish/conf.d/impulse-path.fish" | awk '{print $1}')"
(
  export HOME="$PH" XDG_CONFIG_HOME="$PH/.config" XDG_DATA_HOME="$PH/.local/share" XDG_BIN_HOME="$PH/.local/bin"
  export REPO_ROOT="$LR" DEPLOY_HOME="$PH" DEPLOY_SELF_HOME="$PH"
  out="$(setup_launcher_ensure 2>&1)"; rc=$?
  [[ $rc == 0 && -z "$out" ]] && pass "repeat ensure is silent" || { fail "repeat ensure is silent"; echo "$out"; }
)
[[ "$(sha256sum "$PH/.config/fish/conf.d/impulse-path.fish" | awk '{print $1}')" == "$SNIP_SUM" ]] \
  && pass "repeat ensure leaves the drop-in identical" || fail "repeat ensure leaves the drop-in identical"
# Dry runs change nothing at all, including the launcher lifecycle.
rm -f "$PH/.local/bin/impulse" "$PH/.config/fish/conf.d/impulse-path.fish"
(
  export HOME="$PH" XDG_CONFIG_HOME="$PH/.config" XDG_DATA_HOME="$PH/.local/share" XDG_BIN_HOME="$PH/.local/bin"
  export REPO_ROOT="$LR" DEPLOY_LIB_DIR="$LIBDIR"
  unset FONTSET_DIR_NAME INSTALL_VIA_NIX
  DEPLOY_AT="HEAD" DEPLOY_HOME_DIR="$PH" DEPLOY_STATE_DIR=""
  DEPLOY_APPLY_FONTSET=""; DEPLOY_APPLY_FONTSET_SET=false; DEPLOY_APPLY_VIANIX_SET=false
  DEPLOY_UPDATE_DRYRUN=true DEPLOY_UPDATE_VERBOSE=false
  declare -a APPLY_RESOLVE=()
  # shellcheck disable=SC1091
  source "${HERE}/../../subcmd-update/0.run.sh" > /tmp/lc-dry-ph.out 2>&1
)
[[ $? == 0 ]] && pass "dry-run noop exits 0" || fail "dry-run noop exits 0"
[[ ! -e "$PH/.local/bin/impulse" && ! -e "$PH/.config/fish/conf.d/impulse-path.fish" ]] \
  && pass "dry run installs nothing" || fail "dry run installs nothing"
# Uninstall removes exactly what the project owns: recreate both owned
# files first (the dry run above must not have), then remove.
(
  export HOME="$PH" XDG_CONFIG_HOME="$PH/.config" XDG_DATA_HOME="$PH/.local/share" XDG_BIN_HOME="$PH/.local/bin"
  export REPO_ROOT="$LR" DEPLOY_HOME="$PH" DEPLOY_SELF_HOME="$PH"
  setup_launcher_ensure > /dev/null 2>&1
)
printf '# user content\n' > "$PH/.config/fish/conf.d/user-path.fish"
(
  export HOME="$PH" XDG_CONFIG_HOME="$PH/.config" XDG_BIN_HOME="$PH/.local/bin" REPO_ROOT="$LR"
  setup_launcher_remove > /tmp/lc-remove-ph.out 2>&1
)
[[ $? == 0 && ! -e "$PH/.local/bin/impulse" && ! -e "$PH/.config/fish/conf.d/impulse-path.fish" ]] \
  && pass "uninstall removes owned launcher and drop-in" || fail "uninstall removes owned launcher and drop-in"
[[ -x "$PH/.local/bin/other-tool" && -f "$PH/.config/fish/conf.d/user-path.fish" ]] \
  && pass "uninstall keeps foreign files" || fail "uninstall keeps foreign files"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
