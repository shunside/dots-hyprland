#!/usr/bin/env bash
#
# Fixture tests for the pre-handoff migration bridge.
#
# Boundary under test: the starting checkout runs the ACTUAL pre-handoff
# updater — byte-identical `setup`+`sdata` from commit 0e07b151, extracted
# read-only via `git archive` (never reimplemented, never hand-stripped).
# The remote tip carries the current handoff-capable updater. Only file://
# transports are used, and the real worktree is only ever read from.
#
# Proves the field report and its fix:
#   S1  old `./setup update` fetches the new target, deploys nothing,
#       prints "Already up to date", and leaves no launcher (the bug).
#   S2  the documented one-time bridge flow fast-forwards the checkout,
#       deploys the target, creates the launcher, and a later
#       `impulse update` from outside the repo works.
#   S3  a diverged checkout is preserved byte-for-byte while the bridge
#       still deploys the target payload and launcher via its fallback.
#   S4  a target without a runnable updater fails safe and touches nothing.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${DEPLOY_ENTRY_SRC:-$(cd "${HERE}/../../.." && pwd)}"

PASS=0
FAIL=0
pass(){ PASS=$((PASS+1)); echo "PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }

OLD_REV="0e07b151"
if ! git -C "$SRC" cat-file -e "${OLD_REV}^{commit}" 2>/dev/null; then
  echo "SKIP: pre-handoff commit $OLD_REV not present in $SRC"
  exit 0
fi

T="$(mktemp -d /tmp/deploy-bridge-XXXXXX)"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$T"' EXIT

R="$T/origin"
git init -q "$R"
git -C "$R" checkout -qb main 2>/dev/null || true
git -C "$R" config user.email "fixture@example"
git -C "$R" config user.name "fixture"
git -C "$R" config commit.gpgsign false
GCOMMIT=(-c user.email=fixture@example -c user.name=fixture -c commit.gpgsign=false commit -qm)

# Base: the real pre-handoff updater plus a minimal managed payload.
git -C "$SRC" archive "$OLD_REV" setup sdata | tar -x -C "$R"
mkdir -p "$R/dots/.config/app"
printf 'managed dots/.config/app .config/app\n' > "$R/sdata/deploy/ownership.conf"
printf 'same\n' > "$R/dots/.config/app/keep.conf"
printf 'v1\n' > "$R/dots/.config/app/upd.conf"
git -C "$R" add -A
git -C "$R" "${GCOMMIT[@]}" "pre-handoff base (updater code @ $OLD_REV)"
BASE=$(git -C "$R" rev-parse HEAD)
# The updater code is byte-identical to the real pre-handoff commit.
for f in setup sdata/subcmd-update/0.run.sh sdata/subcmd-update/options.sh; do
  if cmp -s <(git -C "$SRC" show "$OLD_REV:$f") "$R/$f"; then
    pass "base $f is byte-identical to $OLD_REV"
  else
    fail "base $f is byte-identical to $OLD_REV"
  fi
done
[[ "$(grep -c 'Self-update handoff' "$R/sdata/subcmd-update/0.run.sh")" -eq 0 ]] \
  && pass "base updater predates handoff" || fail "base updater predates handoff"

# Tip: the current updater over the same payload (an updater-only change,
# exactly like the field report: nothing for the payload plan to do).
# The registry is read from the TARGET revision, so the fixture rule must
# be re-applied after overlaying the current tree.
rm -rf "$R/sdata"
cp -r "$SRC/sdata" "$R/sdata"
cp "$SRC/setup" "$R/setup"
printf 'managed dots/.config/app .config/app\n' > "$R/sdata/deploy/ownership.conf"
[[ -f "$R/sdata/lib/update-bridge.sh" ]] \
  && pass "tip carries the bridge" || fail "tip carries the bridge"
git -C "$R" add -A
git -C "$R" "${GCOMMIT[@]}" "handoff-capable tip"
TIP=$(git -C "$R" rev-parse HEAD)

# Stale machine: branch main at BASE tracking origin/main at TIP, no
# launcher — the exact field state (HEAD 0e07b151-era, origin/main ahead).
# checkout -B moves the branch AND the worktree (a bare update-ref would
# leave tip content behind under an old HEAD — a Frankenstein checkout).
C="$T/stale"
git clone -q "$R" "$C" 2>/dev/null
git -C "$C" checkout -q -B main "$BASE" 2>/dev/null
git -C "$C" branch --set-upstream-to=origin/main main 2>/dev/null
[[ "$(git -C "$C" rev-parse HEAD)" == "$BASE" ]] \
  && pass "stale checkout starts at base" || fail "stale checkout starts at base"
[[ -z "$(git -C "$C" status --porcelain)" ]] \
  && pass "stale worktree matches base" || fail "stale worktree matches base"
[[ "$(grep -c 'Self-update handoff' "$C/sdata/subcmd-update/0.run.sh")" -eq 0 ]] \
  && pass "stale worktree executes pre-handoff code" || fail "stale worktree executes pre-handoff code"
[[ "$(git -C "$C" rev-parse origin/main)" == "$TIP" ]] \
  && pass "stale checkout tracks the tip" || fail "stale checkout tracks the tip"

H0="$T/home0"
mkdir -p "$H0/.config/app" "$H0/.config/illogical-impulse"
printf 'same\n' > "$H0/.config/app/keep.conf"
printf 'v1\n' > "$H0/.config/app/upd.conf"

old_setup(){
  (cd /tmp && HOME="$1" XDG_CONFIG_HOME="$1/.config" XDG_DATA_HOME="$1/.local/share" \
    XDG_BIN_HOME="$1/.local/bin" "$C/setup" "${@:2}" </dev/null)
}
adopt_old_at(){
  old_setup "$1" adopt --apply --at "$2" --home "$1" --state-dir "$1/.config/illogical-impulse" > /dev/null 2>&1
}

echo "--- S1: the field report, reproduced with real pre-handoff code ---"
rm -rf "$T/h1" && cp -r "$H0" "$T/h1" && H1="$T/h1" && SD1="$H1/.config/illogical-impulse"
adopt_old_at "$H1" "$BASE"
[[ $? == 0 ]] && pass "old adopt exits 0" || fail "old adopt exits 0"
[[ ! -e "$H1/.local/bin/impulse" ]] \
  && pass "old lifecycle leaves no launcher" || fail "old lifecycle leaves no launcher"
(cd /tmp && HOME="$H1" XDG_CONFIG_HOME="$H1/.config" XDG_DATA_HOME="$H1/.local/share" \
  XDG_BIN_HOME="$H1/.local/bin" "$C/setup" update --home "$H1" --state-dir "$SD1" </dev/null > /tmp/br-s1.out 2>&1)
[[ $? == 0 ]] && pass "old update exits 0" || fail "old update exits 0"
grep -q "Already up to date" /tmp/br-s1.out \
  && pass "old update claims to be up to date" || fail "old update claims to be up to date"
[[ ! -e "$H1/.local/bin/impulse" ]] \
  && pass "old update leaves no launcher" || fail "old update leaves no launcher"
[[ "$(git -C "$C" rev-parse HEAD)" == "$BASE" ]] \
  && pass "old update moves no branch" || fail "old update moves no branch"

echo "--- S2: documented one-time bridge on a clean checkout ---"
echo scratch > "$C/scratch.txt"
git -C "$C" fetch -q origin main 2>/dev/null
(cd /tmp && HOME="$H1" XDG_CONFIG_HOME="$H1/.config" XDG_DATA_HOME="$H1/.local/share" \
  XDG_BIN_HOME="$H1/.local/bin" \
  bash <(git -C "$C" show FETCH_HEAD:sdata/lib/update-bridge.sh) --repo "$C" --home "$H1" --state-dir "$SD1" > /tmp/br-s2.out 2>&1)
[[ $? == 0 ]] && pass "bridge exits 0" || fail "bridge exits 0"
[[ "$(git -C "$C" rev-parse HEAD)" == "$TIP" ]] \
  && pass "bridge fast-forwarded the checkout" || fail "bridge fast-forwarded the checkout"
[[ -L "$H1/.local/bin/impulse" && "$(readlink -f "$H1/.local/bin/impulse")" == "$C/setup" ]] \
  && pass "bridge created the launcher" || fail "bridge created the launcher"
[[ "$(cat "$C/scratch.txt")" == "scratch" ]] \
  && pass "untracked worktree file survives" || fail "untracked worktree file survives"
[[ "$(git -C "$C" status --porcelain)" == "?? scratch.txt" ]] \
  && pass "checkout is clean apart from scratch" || fail "checkout is clean apart from scratch"
grep -q "$BASE" "$SD1/deployment-identity.json" \
  && pass "baseline still recorded after noop" || fail "baseline still recorded after noop"
(cd /tmp && HOME="$H1" XDG_CONFIG_HOME="$H1/.config" XDG_DATA_HOME="$H1/.local/share" \
  XDG_BIN_HOME="$H1/.local/bin" PATH="$H1/.local/bin:$PATH" \
  impulse update --home "$H1" --state-dir "$SD1" </dev/null > /tmp/br-s2b.out 2>&1)
[[ $? == 0 ]] && pass "impulse update works outside the repo" || fail "impulse update works outside the repo"
grep -q "Already up to date" /tmp/br-s2b.out \
  && pass "follow-up update is a noop" || fail "follow-up update is a noop"

echo "--- S3: diverged checkout is preserved, target still deployed ---"
C2="$T/diverged"
git clone -q "$R" "$C2" 2>/dev/null
git -C "$C2" config user.email "fixture@example"
git -C "$C2" config user.name "fixture"
git -C "$C2" config commit.gpgsign false
git -C "$C2" checkout -q -B main "$BASE" 2>/dev/null
git -C "$C2" branch --set-upstream-to=origin/main main 2>/dev/null
[[ "$(grep -c 'Self-update handoff' "$C2/sdata/subcmd-update/0.run.sh")" -eq 0 ]] \
  && pass "diverged worktree executes pre-handoff code" || fail "diverged worktree executes pre-handoff code"
rm -rf "$T/h2" && cp -r "$H0" "$T/h2" && H2="$T/h2" && SD2="$H2/.config/illogical-impulse"
(cd /tmp && HOME="$H2" XDG_CONFIG_HOME="$H2/.config" XDG_DATA_HOME="$H2/.local/share" \
  XDG_BIN_HOME="$H2/.local/bin" "$C2/setup" adopt --apply --at "$BASE" --home "$H2" --state-dir "$SD2" </dev/null > /dev/null 2>&1)
[[ $? == 0 ]] && pass "diverged-tree adopt exits 0" || fail "diverged-tree adopt exits 0"
echo local > "$C2/notes.txt"
git -C "$C2" add notes.txt
git -C "$C2" "${GCOMMIT[@]}" "local work" 2>/dev/null
LOCAL=$(git -C "$C2" rev-parse HEAD)
echo dirt >> "$C2/notes.txt"
printf 'v3\n' > "$R/dots/.config/app/upd.conf"
git -C "$R" add -A
git -C "$R" "${GCOMMIT[@]}" "payload v3"
TIP3=$(git -C "$R" rev-parse HEAD)
git -C "$C2" fetch -q origin main 2>/dev/null
(cd /tmp && HOME="$H2" XDG_CONFIG_HOME="$H2/.config" XDG_DATA_HOME="$H2/.local/share" \
  XDG_BIN_HOME="$H2/.local/bin" \
  bash <(git -C "$C2" show FETCH_HEAD:sdata/lib/update-bridge.sh) --repo "$C2" --home "$H2" --state-dir "$SD2" > /tmp/br-s3.out 2>&1)
[[ $? == 0 ]] && pass "diverged bridge exits 0" || fail "diverged bridge exits 0"
[[ "$(git -C "$C2" rev-parse HEAD)" == "$LOCAL" ]] \
  && pass "local commit untouched" || fail "local commit untouched"
[[ "$(tail -n 1 "$C2/notes.txt")" == "dirt" ]] \
  && pass "worktree dirt survives" || fail "worktree dirt survives"
[[ "$(cat "$H2/.config/app/upd.conf")" == "v3" ]] \
  && pass "target payload deployed over divergence" || fail "target payload deployed over divergence"
[[ -L "$H2/.local/bin/impulse" ]] \
  && pass "diverged bridge created the launcher" || fail "diverged bridge created the launcher"
grep -q "leaving branch" /tmp/br-s3.out \
  && pass "bridge says the branch was left alone" || fail "bridge says the branch was left alone"

echo "--- S4: target without a runner fails safe ---"
git -C "$R" rm -rq sdata/subcmd-update 2>/dev/null
git -C "$R" "${GCOMMIT[@]}" "payload without updater" 2>/dev/null
rm -rf "$T/h3" && cp -r "$H0" "$T/h3" && H3="$T/h3" && SD3="$H3/.config/illogical-impulse"
(cd /tmp && HOME="$H3" XDG_CONFIG_HOME="$H3/.config" XDG_DATA_HOME="$H3/.local/share" \
  XDG_BIN_HOME="$H3/.local/bin" "$C2/setup" adopt --apply --at "$BASE" --home "$H3" --state-dir "$SD3" </dev/null > /dev/null 2>&1)
git -C "$C2" fetch -q origin main 2>/dev/null
(cd /tmp && HOME="$H3" XDG_CONFIG_HOME="$H3/.config" XDG_DATA_HOME="$H3/.local/share" \
  XDG_BIN_HOME="$H3/.local/bin" \
  bash <(git -C "$C2" show FETCH_HEAD:sdata/lib/update-bridge.sh) --repo "$C2" --home "$H3" --state-dir "$SD3" > /tmp/br-s4.out 2>&1)
[[ $? == 1 ]] && pass "ancient target fails safe" || fail "ancient target fails safe"
[[ "$(git -C "$C2" rev-parse HEAD)" == "$LOCAL" ]] \
  && pass "failed bridge moves no branch" || fail "failed bridge moves no branch"
grep -q -- "--at" /tmp/br-s4.out \
  && pass "ancient failure suggests explicit target" || fail "ancient failure suggests explicit target"
[[ ! -e "$SD3/applies" ]] \
  && pass "ancient failure writes no transaction" || fail "ancient failure writes no transaction"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
