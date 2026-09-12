#!/usr/bin/env bash
#
# Fixture tests for update self-update handoff: a stale checkout's own
# entrypoint must end up executing the pinned target revision's updater
# implementation when the checkout cannot follow it itself.
#
# The "stale" tree is built mechanically, never hand-written: full current
# sdata with exactly the handoff block and the launcher-ensure calls
# removed from a copy of subcmd-update/0.run.sh. That is a handoff-unaware
# runner on otherwise shared tails (gates, record, fast-forward, steady
# verdicts), so any delegation line proves the target implementation took
# over. Anchor counts are asserted: silent anchor drift fails here instead
# of testing something unintended. Only file:// transports are used.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${DEPLOY_ENTRY_SRC:-$(cd "${HERE}/../../.." && pwd)}"
LIBDIR="${HERE}/../../lib"
UPDATEDIR="${HERE}/../../subcmd-update"

PASS=0
FAIL=0
pass(){ PASS=$((PASS+1)); echo "PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }

T="$(mktemp -d /tmp/deploy-handoff-XXXXXX)"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$T"' EXIT

R="$T/repo"
U="$T/upstream.git"
# NOTE: `git init -qb --bare` does NOT work: -b consumes --bare as its
# branch-name argument. Init bare, then point HEAD.
git init -q --bare "$U"
git --git-dir="$U" symbolic-ref HEAD refs/heads/main
git clone -q "$U" "$R" 2>/dev/null
git -C "$R" checkout -qb main 2>/dev/null || true
git -C "$R" config user.email "fixture@example"
git -C "$R" config user.name "fixture"
git -C "$R" config commit.gpgsign false
GCOMMIT=(-c user.email=fixture@example -c user.name=fixture -c commit.gpgsign=false commit -qm)

cp -r "$SRC/sdata" "$R/sdata"
cp "$SRC/setup" "$R/setup"
python3 - "$R/sdata/subcmd-update/0.run.sh" <<'EOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()
start, end = '# --- Self-update handoff', '# --- End self-update handoff. ---'
assert t.count(start) == 1 and t.count(end) == 1, "handoff anchors drifted"
t = t[:t.index(start)] + t[t.index(end) + len(end):]
# Any line invoking ensure (bare or captured) belongs to the launcher era.
calls = [l for l in t.split('\n') if 'setup_launcher_ensure' in l and not l.strip().startswith('#')]
assert len(calls) == 2, "ensure call sites drifted"
t = '\n'.join(l for l in t.split('\n') if not ('setup_launcher_ensure' in l and not l.strip().startswith('#')))
p.write_text(t)
print("stripped stale runner")
EOF
[[ "$(grep -c 'setup_launcher_ensure' "$R/sdata/subcmd-update/0.run.sh")" -eq 0 ]] \
  && pass "stale runner carries no ensure calls" || fail "stale runner carries no ensure calls"
[[ "$(grep -c 'Self-update handoff' "$R/sdata/subcmd-update/0.run.sh")" -eq 0 ]] \
  && pass "stale runner carries no handoff" || fail "stale runner carries no handoff"
bash -n "$R/sdata/subcmd-update/0.run.sh" && pass "stale runner still parses" || fail "stale runner still parses"

mkdir -p "$R/dots/.config/app"
printf 'managed dots/.config/app .config/app\n' > "$R/sdata/deploy/ownership.conf"
printf 'same\n' > "$R/dots/.config/app/keep.conf"
printf 'v1\n' > "$R/dots/.config/app/upd.conf"
git -C "$R" add -A
git -C "$R" "${GCOMMIT[@]}" "stale baseline"
S0=$(git -C "$R" rev-parse HEAD)
git -C "$R" push -q origin main 2>/dev/null
git -C "$R" branch --set-upstream-to=origin/main main 2>/dev/null
git -C "$R" rev-parse --verify origin/main >/dev/null 2>&1 \
  || { echo "fixture remote setup failed" >&2; exit 1; }

# Second clone advances the fork without touching the stale checkout.
W="$T/work"
git clone -q "$U" "$W" 2>/dev/null
git -C "$W" config user.email "fixture@example"
git -C "$W" config user.name "fixture"
git -C "$W" config commit.gpgsign false

# Pristine home template (v1 live content, no state); every case copies it
# and adopts fresh so no case inherits another's baseline.
H0="$T/home0"
mkdir -p "$H0/.config/app" "$H0/.config/illogical-impulse"
printf 'same\n' > "$H0/.config/app/keep.conf"
printf 'v1\n' > "$H0/.config/app/upd.conf"

# Pre-existing launcher symlink, as on a machine onboarded long ago.
BIN="$T/fakebin"
mkdir -p "$BIN"

# Old entrypoint, invoked from outside the repo through the launcher,
# exactly like a normal user would. HOME override makes the adopted home
# the machine's own, so lifecycle behavior applies to the fixture only.
old_update(){
  (cd /tmp && HOME="$1" XDG_CONFIG_HOME="$1/.config" XDG_DATA_HOME="$1/.local/share" \
    XDG_BIN_HOME="$1/.local/bin" PATH="$BIN:$PATH" impulse update --home "$1" --state-dir "$1/.config/illogical-impulse" "$@")
}
adopt_at(){
  (cd /tmp && HOME="$1" XDG_CONFIG_HOME="$1/.config" XDG_DATA_HOME="$1/.local/share" \
    "$R/setup" adopt --apply --at "$2" --home "$1" --state-dir "$1/.config/illogical-impulse" </dev/null > /dev/null 2>&1)
}

echo "--- adopt at the stale baseline ---"
rm -rf "$T/h" && cp -r "$H0" "$T/h" && H="$T/h" && SD="$H/.config/illogical-impulse"
adopt_at "$H" "$S0"
[[ $? == 0 ]] && pass "stale-tree adopt exits 0" || fail "stale-tree adopt exits 0"
ln -s "$R/setup" "$BIN/impulse"

echo "--- stale checkout follows the target without handoff ---"
printf 'v2\n' > "$W/dots/.config/app/upd.conf"
cp "$SRC/sdata/subcmd-update/0.run.sh" "$W/sdata/subcmd-update/0.run.sh"
git -C "$W" add -A
git -C "$W" -c user.email=fixture@example -c user.name=fixture -c commit.gpgsign=false commit -qm "target implementation"
git -C "$W" push -q origin main 2>/dev/null
S1=$(git -C "$W" rev-parse HEAD)
S1_SHORT=$(git -C "$W" rev-parse --short HEAD)
old_update "$H" > /tmp/hand-core.out 2>&1
[[ $? == 0 ]] && pass "stale entrypoint update exits 0" || fail "stale entrypoint update exits 0: $(tail -n 3 /tmp/hand-core.out)"
[[ "$(cat "$H/.config/app/upd.conf")" == "v2" ]] && pass "pinned target payload deployed" || fail "pinned target payload deployed"
[[ -L "$H/.local/bin/impulse" ]] && pass "adopt delivered the launcher" || fail "adopt delivered the launcher"
[[ "$(readlink -f "$H/.local/bin/impulse")" == "$(readlink -f "$R/setup")" ]] \
  && pass "launcher points at checkout, not tempdir" || fail "launcher points at checkout, not tempdir"
[[ "$(git -C "$R" rev-parse HEAD)" == "$S1" ]] \
  && pass "clean checkout advanced to target" || fail "clean checkout advanced to target"
[[ -z "$(git -C "$R" status --porcelain=v1)" ]] && pass "checkout worktree clean" || fail "checkout worktree clean"
[[ "$(cat "$R/dots/.config/app/upd.conf")" == "v2" ]] && pass "checkout payload advanced with the branch" || fail "checkout payload advanced with the branch"
grep -q "^Advanced checkout .* -> $S1_SHORT" /tmp/hand-core.out \
  && pass "checkout advance is reported" || fail "checkout advance is reported"
if grep -q "Handed off" /tmp/hand-core.out; then
  fail "stripped runner cannot delegate"
else
  pass "stripped runner cannot delegate"
fi
grep -q "\"target\":\"$S1\"" "$SD/applies/"*/journal.jsonl \
  && pass "journal pins the discovered target" || fail "journal pins the discovered target"
grep -q "\"path\":\".config/app/upd.conf\".*\"rev\":\"$S1\"" "$SD/manifest.jsonl" \
  && pass "manifest advanced to pinned target" || fail "manifest advanced to pinned target"
[[ "$(find "$SD/applies" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]] \
  && pass "exactly one transaction exists" || fail "exactly one transaction exists"

echo "--- repeat update through the stale entrypoint ---"
old_update "$H" > /tmp/hand-repeat.out 2>&1
[[ $? == 0 ]] && pass "repeat update exits 0" || fail "repeat update exits 0"
# Steady now: checkout at target, tracking unmoved, launcher converged —
# a single verdict line instead of another update narrative.
[[ "$(grep -c '^Updating ' /tmp/hand-repeat.out)" == "0" ]] \
  && pass "steady run skips the update narrative" || fail "steady run skips the update narrative"
grep -q "^✓ Already up to date at $S1_SHORT" /tmp/hand-repeat.out \
  && pass "steady verdict claims already-current" || fail "steady verdict claims already-current"
[[ "$(find "$SD/applies" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]] \
  && pass "noop opens no new transaction" || fail "noop opens no new transaction"

echo "--- handed-off guidance pins the evaluated target ---"
printf 'local\n' > "$H/.config/app/upd.conf"
old_update "$H" > /tmp/hand-pin.out 2>&1
[[ $? == 2 ]] && pass "pinned-target block exits 2" || fail "pinned-target block exits 2"
grep -q "decide --set PATH=CHOICE.*--at $S1" /tmp/hand-pin.out \
  && pass "decide guidance pins the target" || fail "decide guidance pins the target"
grep -q "plan.*--at $S1" /tmp/hand-pin.out \
  && pass "plan guidance pins the target" || fail "plan guidance pins the target"

echo "--- dirty and diverged checkout is preserved ---"
printf '# local comment\n' >> "$R/dots/.config/app/keep.conf"
printf 'untracked\n' > "$R/scratch.tmp"
printf 'mine\n' > "$R/dots/.config/app/localonly.conf"
git -C "$R" add dots/.config/app/localonly.conf
git -C "$R" "${GCOMMIT[@]}" "rev local-only tweak"
git -C "$W" checkout -qb tmp 2>/dev/null
printf 'v3\n' > "$W/dots/.config/app/upd.conf"
git -C "$W" add -A
git -C "$W" -c user.email=fixture@example -c user.name=fixture -c commit.gpgsign=false commit -qm "payload v3"
git -C "$W" push -q origin tmp:main 2>/dev/null
S2=$(git -C "$W" rev-parse HEAD)
git -C "$W" checkout -q main 2>/dev/null; git -C "$W" branch -qD tmp 2>/dev/null || true
rm -rf "$T/h2" && cp -r "$H0" "$T/h2" && H2="$T/h2" && SD2="$H2/.config/illogical-impulse"
adopt_at "$H2" "$S0"
[[ $? == 0 ]] && pass "second adopt exits 0" || fail "second adopt exits 0"
(cd /tmp && HOME="$H2" XDG_CONFIG_HOME="$H2/.config" XDG_DATA_HOME="$H2/.local/share" \
  XDG_BIN_HOME="$H2/.local/bin" PATH="$BIN:$PATH" impulse update --home "$H2" --state-dir "$SD2" </dev/null > /tmp/hand-div.out 2>&1)
[[ $? == 0 ]] && pass "diverged update exits 0" || fail "diverged update exits 0: $(tail -n 3 /tmp/hand-div.out)"
grep -q "1 commit(s) not on origin/main" /tmp/hand-div.out \
  && pass "local commits are named" || fail "local commits are named"
[[ "$(cat "$H2/.config/app/upd.conf")" == "v3" ]] \
  && pass "remote tip deployed over divergence" || fail "remote tip deployed over divergence"
[[ "$(git -C "$R" log --oneline | head -n 1)" == *"local-only tweak"* ]] \
  && pass "local commit untouched" || fail "local commit untouched"
if grep -q "^Advanced checkout" /tmp/hand-div.out; then
  fail "diverged checkout never advances"
else
  pass "diverged checkout never advances"
fi
grep -q "local comment" "$R/dots/.config/app/keep.conf" && [[ -f "$R/scratch.tmp" ]] \
  && pass "worktree dirt survives the fetch" || fail "worktree dirt survives the fetch"
rm -f "$R/scratch.tmp"
git -C "$R" checkout -q -- dots/.config/app/keep.conf

echo "--- explicit --at never fetches, even stale ---"
git -C "$R" remote set-url origin "$T/does-not-exist.git"
rm -rf "$T/h5" && cp -r "$H0" "$T/h5" && H5="$T/h5" && SD5="$H5/.config/illogical-impulse"
adopt_at "$H5" "$S0"
(cd /tmp && HOME="$H5" XDG_CONFIG_HOME="$H5/.config" XDG_DATA_HOME="$H5/.local/share" \
  XDG_BIN_HOME="$H5/.local/bin" PATH="$BIN:$PATH" \
  impulse update --at "$S2" --home "$H5" --state-dir "$SD5" </dev/null > /tmp/hand-explicit.out 2>&1)
[[ $? == 0 ]] && pass "explicit target works with broken remote" || fail "explicit target works with broken remote: $(tail -n 3 /tmp/hand-explicit.out)"
[[ "$(cat "$H5/.config/app/upd.conf")" == "v3" ]] \
  && pass "explicit revision deployed" || fail "explicit revision deployed"
# Same pin again: payload noop, but the checkout's updater lags the pinned
# target, so the run must say tool revision differs (not just "up to date").
(cd /tmp && HOME="$H5" XDG_CONFIG_HOME="$H5/.config" XDG_DATA_HOME="$H5/.local/share" \
  XDG_BIN_HOME="$H5/.local/bin" PATH="$BIN:$PATH" \
  impulse update --at "$S2" --home "$H5" --state-dir "$SD5" </dev/null > /tmp/hand-skew.out 2>&1)
[[ $? == 0 ]] && pass "repeated explicit pin is a noop" || fail "repeated explicit pin is a noop"
grep -q "Payload: already matches target" /tmp/hand-skew.out \
  && pass "noop wording names the payload" || fail "noop wording names the payload"
grep -q "tool revision differs" /tmp/hand-skew.out \
  && pass "noop names the updater skew" || fail "noop names the updater skew"
# Became-current, not already-current: the checkout still lags the pin.
grep -q "^✓ Up to date at " /tmp/hand-skew.out && ! grep -q "Already" /tmp/hand-skew.out \
  && pass "skewed noop verdict avoids Already" || fail "skewed noop verdict avoids Already"
git -C "$R" remote set-url origin "$U"

echo "--- dry run hands off but deploys nothing ---"
rm -rf "$T/h3" && cp -r "$H0" "$T/h3" && H3="$T/h3" && SD3="$H3/.config/illogical-impulse"
adopt_at "$H3" "$S0"
# Current-runner driver (worktree implementation): reaching the handoff
# check itself requires code that has it, so cases below drive the new
# runner directly against the stale checkout. Mirrors old_update's
# environment exactly, including /tmp cwd; only the sourced file differs.
new_update(){
  local dry="$1" home="$2" statedir="$3"
  (
    export HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share"
    export XDG_BIN_HOME="$home/.local/bin"
    export REPO_ROOT="$R" DEPLOY_LIB_DIR="$LIBDIR"
    unset FONTSET_DIR_NAME INSTALL_VIA_NIX
    DEPLOY_AT="HEAD" DEPLOY_UPDATE_AT_GIVEN=false
    DEPLOY_HOME_DIR="$home" DEPLOY_STATE_DIR="$statedir"
    DEPLOY_APPLY_FONTSET=""; DEPLOY_APPLY_FONTSET_SET=false; DEPLOY_APPLY_VIANIX_SET=false
    DEPLOY_UPDATE_DRYRUN="$dry" DEPLOY_UPDATE_VERBOSE=false
    declare -a APPLY_RESOLVE=()
    cd /tmp || exit 1
    # shellcheck disable=SC1091
    source "${UPDATEDIR}/0.run.sh"
  ) < /dev/null
}
new_update true "$H3" "$SD3" > /tmp/hand-dry.out 2>&1
[[ $? == 0 ]] && pass "stale dry run exits 0" || fail "stale dry run exits 0"
grep -q "^Handed off to updater " /tmp/hand-dry.out \
  && pass "dry run delegates visibly" || fail "dry run delegates visibly"
grep -q "(latest on origin/main)" /tmp/hand-dry.out \
  && pass "dry run shows discovered target" || fail "dry run shows discovered target"
[[ "$(cat "$H3/.config/app/upd.conf")" == "v1" ]] \
  && pass "dry run leaves live alone" || fail "dry run leaves live alone"
[[ ! -e "$SD3/applies" ]] && pass "dry run opens no transaction" || fail "dry run opens no transaction"

echo "--- ancient target without a runner fails cleanly ---"
git -C "$W" fetch -q origin 2>/dev/null
git -C "$W" checkout -qb tmp2 origin/main 2>/dev/null
git -C "$W" rm -rq sdata/subcmd-update 2>/dev/null
git -C "$W" -c user.email=fixture@example -c user.name=fixture -c commit.gpgsign=false commit -qm "payload without updater"
git -C "$W" push -q origin tmp2:main 2>/dev/null
git -C "$W" checkout -q main 2>/dev/null; git -C "$W" branch -qD tmp2 2>/dev/null || true
rm -rf "$T/h4" && cp -r "$H0" "$T/h4" && H4="$T/h4" && SD4="$H4/.config/illogical-impulse"
adopt_at "$H4" "$S0"
# Current runner again: only new code can reach the handoff check whose
# failure mode is under test (the stale entrypoint cannot get there).
new_update false "$H4" "$SD4" > /tmp/hand-ancient.out 2>&1
[[ $? == 1 ]] && pass "ancient target fails safe" || fail "ancient target fails safe"
grep -q -- "--at" /tmp/hand-ancient.out && pass "ancient failure suggests explicit target" || fail "ancient failure suggests explicit target"
[[ ! -e "$SD4/applies" ]] && pass "ancient failure writes no transaction" || fail "ancient failure writes no transaction"
if grep -q "^Handed off" /tmp/hand-ancient.out; then
  fail "failed delegation claims nothing"
else
  pass "failed delegation claims nothing"
fi

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
