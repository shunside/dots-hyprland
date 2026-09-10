#!/usr/bin/env bash
#
# Fixture tests for `setup update` remote discovery: the default update
# resolves the branch's tracking branch over the network (fetch only),
# pins the fetched commit, and deploys it; explicit --at stays fully
# local. Uses a local bare repo as the "remote", so no network is needed
# and file:// transport cannot leak anywhere real. Everything under $T.
# This file is safe to run from any working directory (all paths absolute
# or repo-anchored); that itself exercises cwd independence.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBDIR="${HERE}/../../lib"
ADOPTDIR="${HERE}/../../subcmd-adopt"
UPDATEDIR="${HERE}/../../subcmd-update"
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

T="$(mktemp -d /tmp/deploy-update-remote-XXXXXX)"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$T"' EXIT

U="$T/upstream.git"
# NOTE: `git init -qb --bare` does NOT work: -b consumes --bare as its
# branch-name argument, leaving HEAD pointing at a nonexistent ref and
# every later clone without a checkout. Init bare, then point HEAD.
git init -q --bare "$U"
git --git-dir="$U" symbolic-ref HEAD refs/heads/main
R="$T/repo"
git clone -q "$U" "$R" 2>/dev/null
# A clone of an empty repo leaves HEAD unborn on an implementation-defined
# branch; create main explicitly so pushes and tracking match production.
git -C "$R" checkout -qb main 2>/dev/null || true
git -C "$R" config user.email "fixture@example"
git -C "$R" config user.name "fixture"
git -C "$R" config commit.gpgsign false
GCOMMIT=(-c user.email=fixture@example -c user.name=fixture -c commit.gpgsign=false commit -qm)
# Cloning an empty repo leaves HEAD unborn on main without upstream state;
# push explicitly so the tracking relationship exists like a normal clone.
mkdir -p "$R/dots/.config/app" "$R/sdata/deploy"
cat > "$R/sdata/deploy/ownership.conf" <<'EOF'
managed dots/.config/app .config/app
EOF
printf 'same\n' > "$R/dots/.config/app/keep.conf"
printf 'v1\n' > "$R/dots/.config/app/upd.conf"
git -C "$R" add -A
git -C "$R" "${GCOMMIT[@]}" "rev base"
git -C "$R" push -q origin main 2>/dev/null
git -C "$R" branch --set-upstream-to=origin/main main 2>/dev/null
REV_B=$(git -C "$R" rev-parse HEAD)
printf 'v2\n' > "$R/dots/.config/app/upd.conf"
git -C "$R" add -A
git -C "$R" "${GCOMMIT[@]}" "rev target"
REV_T=$(git -C "$R" rev-parse HEAD)
git -C "$R" push -q origin main 2>/dev/null
# Fail fast if the remote plumbing silently broke: every case below
# depends on origin/main existing.
git -C "$R" rev-parse --verify origin/main >/dev/null 2>&1 \
  || { echo "fixture remote setup failed" >&2; exit 1; }
export REPO_ROOT="$R"

# Second clone acts as "another machine" advancing the fork.
W="$T/work"
git clone -q "$U" "$W" 2>/dev/null
git -C "$W" config user.email "fixture@example"
git -C "$W" config user.name "fixture"
git -C "$W" config commit.gpgsign false

H0="$T/home0"
mkdir -p "$H0/.config/app" "$H0/.config/illogical-impulse"
printf 'same\n' > "$H0/.config/app/keep.conf"
printf 'v1\n' > "$H0/.config/app/upd.conf"
printf '%s/.config/app/keep.conf\n' "$H0" > "$H0/.config/illogical-impulse/installed_listfile"

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

# Drive subcmd-update with explicit control over the target flag, exactly
# the way ./setup sources it (exits contained). Empty atspec means the
# default path (remote discovery); anything else is passed as --at.
update_run(){
  local atspec="$1" home="$2" statedir="$3" extra_env="${4:-}"
  (
    export REPO_ROOT="$R" DEPLOY_LIB_DIR="$LIBDIR"
    unset FONTSET_DIR_NAME INSTALL_VIA_NIX
    # shellcheck disable=SC2086
    eval "$extra_env"
    DEPLOY_HOME_DIR="$home" DEPLOY_STATE_DIR="$statedir"
    DEPLOY_APPLY_FONTSET=""; DEPLOY_APPLY_FONTSET_SET=false; DEPLOY_APPLY_VIANIX_SET=false
    DEPLOY_UPDATE_DRYRUN=false
    DEPLOY_UPDATE_VERBOSE=false
    declare -a APPLY_RESOLVE=()
    if [[ -n "$atspec" ]]; then
      DEPLOY_AT="$atspec" DEPLOY_UPDATE_AT_GIVEN=true
    else
      DEPLOY_AT="HEAD" DEPLOY_UPDATE_AT_GIVEN=false
    fi
    # shellcheck disable=SC1091
    source "${UPDATEDIR}/0.run.sh"
  ) < /dev/null
}

advance_remote(){
  local content="$1" msg="$2"
  printf '%s\n' "$content" > "$W/dots/.config/app/upd.conf"
  git -C "$W" add -A
  git -C "$W" -c user.email=fixture@example -c user.name=fixture -c commit.gpgsign=false commit -qm "$msg"
  git -C "$W" push -q origin main 2>/dev/null
  git -C "$W" rev-parse HEAD
}

echo "--- remote-ahead deploys the fetched commit ---"
fresh_case ahead
REV_U=$(advance_remote "v3-remote" "rev remote")
update_run "" "$T/ahead-home" "$T/ahead-state" > /tmp/updr-ahead.out 2>&1
[[ $? == 0 ]] && pass "remote-ahead update exits 0" || fail "remote-ahead update exits 0: $(tail -n 3 /tmp/updr-ahead.out)"
grep -q "(latest on origin/main)" /tmp/updr-ahead.out \
  && pass "summary names the discovery source" || fail "summary names the discovery source"
[[ "$(cat "$T/ahead-home/.config/app/upd.conf")" == "v3-remote" ]] \
  && pass "fetched content deployed" || fail "fetched content deployed"
[[ "$(git -C "$R" rev-parse HEAD)" == "$REV_T" ]] \
  && pass "local branch never moved" || fail "local branch never moved"

echo "--- already-current after fetching ---"
update_run "" "$T/ahead-home" "$T/ahead-state" > /tmp/updr-current.out 2>&1
[[ $? == 0 ]] && grep -q "Already up to date" /tmp/updr-current.out \
  && pass "second update is a noop" || fail "second update is a noop"

echo "--- offline failure is safe and explicit ---"
fresh_case offline
git -C "$R" remote set-url origin "$T/does-not-exist.git"
SNAP_OFFLINE_HOME=$(cd "$T/offline-home" && find . -exec sha256sum {} + 2>/dev/null | sort)
update_run "" "$T/offline-home" "$T/offline-state" > /tmp/updr-offline.out 2>&1
[[ $? == 1 ]] && pass "offline exits 1" || fail "offline exits 1"
grep -q "could not fetch" /tmp/updr-offline.out && grep -q -- "--at HEAD" /tmp/updr-offline.out \
  && pass "offline names the local alternative" || fail "offline names the local alternative"
[[ ! -e "$T/offline-state/applies" && ! -e "$T/offline-state/apply.lock" ]] \
  && pass "offline writes no transaction state" || fail "offline writes no transaction state"
[[ "$(cd "$T/offline-home" && find . -exec sha256sum {} + 2>/dev/null | sort)" == "$SNAP_OFFLINE_HOME" ]] \
  && pass "offline writes no home files" || fail "offline writes no home files"
git -C "$R" remote set-url origin "$U"

echo "--- dirty checkout is preserved ---"
fresh_case dirty
printf '# local comment\n' >> "$R/dots/.config/app/keep.conf"
printf 'untracked\n' > "$R/dots/.config/app/scratch.txt"
REV_U2=$(advance_remote "v4-remote" "rev remote two")
update_run "" "$T/dirty-home" "$T/dirty-state" > /tmp/updr-dirty.out 2>&1
[[ $? == 0 ]] && pass "dirty-checkout update exits 0" || fail "dirty-checkout update exits 0: $(tail -n 3 /tmp/updr-dirty.out)"
[[ "$(cat "$T/dirty-home/.config/app/upd.conf")" == "v4-remote" ]] \
  && pass "dirty run still deploys" || fail "dirty run still deploys"
grep -q "local comment" "$R/dots/.config/app/keep.conf" && [[ -f "$R/dots/.config/app/scratch.txt" ]] \
  && pass "worktree dirt survives the fetch" || fail "worktree dirt survives the fetch"
git -C "$R" checkout -q -- dots/.config/app/keep.conf
rm -f "$R/dots/.config/app/scratch.txt"

echo "--- diverged branch is named, not followed ---"
fresh_case diverged
printf '# local-only tweak\n' >> "$R/dots/.config/app/keep.conf"
git -C "$R" add -A
git -C "$R" "${GCOMMIT[@]}" "rev local-only tweak"
REV_U3=$(advance_remote "v5-remote" "rev remote three")
update_run "" "$T/diverged-home" "$T/diverged-state" > /tmp/updr-div.out 2>&1
[[ $? == 0 ]] && pass "diverged update exits 0" || fail "diverged update exits 0: $(tail -n 3 /tmp/updr-div.out)"
grep -q "1 commit(s) not on origin/main" /tmp/updr-div.out \
  && pass "local commits are named" || fail "local commits are named"
[[ "$(cat "$T/diverged-home/.config/app/upd.conf")" == "v5-remote" ]] \
  && pass "remote tip deployed over divergence" || fail "remote tip deployed over divergence"
git -C "$R" log --oneline | grep -q "local-only tweak" \
  && pass "local commit untouched" || fail "local commit untouched"

echo "--- no tracking branch falls back loudly ---"
fresh_case notrack
git -C "$R" checkout -qb stray 2>/dev/null
update_run "" "$T/notrack-home" "$T/notrack-state" > /tmp/updr-notrack.out 2>&1
[[ $? == 0 ]] && pass "untracked-branch update exits 0" || fail "untracked-branch update exits 0: $(tail -n 3 /tmp/updr-notrack.out)"
grep -q "no remote tracking branch configured" /tmp/updr-notrack.out \
  && pass "fallback says what happened" || fail "fallback says what happened"
git -C "$R" checkout -q main

echo "--- explicit --at never fetches ---"
fresh_case explicit
git -C "$R" remote set-url origin "$T/does-not-exist.git"
update_run "$REV_U3" "$T/explicit-home" "$T/explicit-state" > /tmp/updr-explicit.out 2>&1
[[ $? == 0 ]] && pass "explicit target works offline" || fail "explicit target works offline: $(tail -n 3 /tmp/updr-explicit.out)"
[[ "$(cat "$T/explicit-home/.config/app/upd.conf")" == "v5-remote" ]] \
  && pass "explicit revision deployed" || fail "explicit revision deployed"
git -C "$R" remote set-url origin "$U"

echo "--- dry run discovers but deploys nothing ---"
fresh_case dryremote
REV_U4=$(advance_remote "v6-remote" "rev remote four")
(
  export REPO_ROOT="$R" DEPLOY_LIB_DIR="$LIBDIR"
  unset FONTSET_DIR_NAME INSTALL_VIA_NIX
  DEPLOY_HOME_DIR="$T/dryremote-home" DEPLOY_STATE_DIR="$T/dryremote-state"
  DEPLOY_APPLY_FONTSET=""; DEPLOY_APPLY_FONTSET_SET=false; DEPLOY_APPLY_VIANIX_SET=false
  DEPLOY_UPDATE_DRYRUN=true
  DEPLOY_UPDATE_VERBOSE=false
  declare -a APPLY_RESOLVE=()
  DEPLOY_AT="HEAD" DEPLOY_UPDATE_AT_GIVEN=false
  # shellcheck disable=SC1091
  source "${UPDATEDIR}/0.run.sh"
) < /dev/null > /tmp/updr-dry.out 2>&1
[[ $? == 0 ]] && pass "dry run exits 0" || fail "dry run exits 0"
grep -q "(latest on origin/main)" /tmp/updr-dry.out \
  && pass "dry run shows discovered target" || fail "dry run shows discovered target"
[[ "$(cat "$T/dryremote-home/.config/app/upd.conf")" == "v1" ]] \
  && pass "dry run leaves live alone" || fail "dry run leaves live alone"
[[ ! -e "$T/dryremote-state/applies" ]] \
  && pass "dry run opens no transaction" || fail "dry run opens no transaction"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
