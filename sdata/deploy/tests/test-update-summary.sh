#!/usr/bin/env bash
#
# Semantic tests for the update summary model (not string snapshots):
# payload dimensions, delegation (handoff), discovery (fetch), and verdict
# must each tell the truth about what actually happened.
#
# Shapes, all driven through the real `./setup` entrypoint:
#   A  noop at target: scoped payload line, verdict, no handoff/fetch lines.
#   B  stale checkout, newer tip: handoff names both implementations, the
#      summary appears exactly once, zeros never claim nothing happened.
#   C  tracking ref moves between runs: the fetch advance is reported once,
#      then silence when nothing moved.
#   D  payload change: counts line, apply, verdict.
# Only file:// transports are used.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${DEPLOY_ENTRY_SRC:-$(cd "${HERE}/../../.." && pwd)}"

PASS=0
FAIL=0
pass(){ PASS=$((PASS+1)); echo "PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }

T="$(mktemp -d /tmp/deploy-summary-XXXXXX)"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$T"' EXIT

U="$T/upstream.git"
git init -q --bare "$U"
git --git-dir="$U" symbolic-ref HEAD refs/heads/main
R="$T/repo"
git clone -q "$U" "$R" 2>/dev/null
git -C "$R" checkout -qb main 2>/dev/null || true
git -C "$R" config user.email "fixture@example"
git -C "$R" config user.name "fixture"
git -C "$R" config commit.gpgsign false
GCOMMIT=(-c user.email=fixture@example -c user.name=fixture -c commit.gpgsign=false commit -qm)
# Full updater tree: the tip must materialize a runnable updater.
# NOTE: copy before any mkdir of $R/sdata, or cp -r nests sdata/sdata.
cp -r "$SRC/sdata" "$R/sdata"
cp "$SRC/setup" "$R/setup"
mkdir -p "$R/dots/.config/app"
printf 'managed dots/.config/app .config/app\n' > "$R/sdata/deploy/ownership.conf"
printf 'same\n' > "$R/dots/.config/app/keep.conf"
printf 'v1\n' > "$R/dots/.config/app/upd.conf"
git -C "$R" add -A
git -C "$R" "${GCOMMIT[@]}" "base"
git -C "$R" push -q origin main 2>/dev/null
git -C "$R" branch --set-upstream-to=origin/main main 2>/dev/null
BASE=$(git -C "$R" rev-parse HEAD)
BASE_SHORT=$(git -C "$R" rev-parse --short HEAD)

H0="$T/home0"
mkdir -p "$H0/.config/app" "$H0/.config/illogical-impulse"
printf 'same\n' > "$H0/.config/app/keep.conf"
printf 'v1\n' > "$H0/.config/app/upd.conf"

# Real entrypoint, fixture home as the machine's own.
entry_update(){
  (cd /tmp && HOME="$1" XDG_CONFIG_HOME="$1/.config" XDG_DATA_HOME="$1/.local/share" \
    XDG_BIN_HOME="$1/.local/bin" "$2/setup" update --home "$1" --state-dir "$1/.config/illogical-impulse" </dev/null)
}
entry_adopt(){
  (cd /tmp && HOME="$1" XDG_CONFIG_HOME="$1/.config" XDG_DATA_HOME="$1/.local/share" \
    XDG_BIN_HOME="$1/.local/bin" "$2/setup" adopt --apply --at "$3" --home "$1" --state-dir "$1/.config/illogical-impulse" </dev/null > /dev/null 2>&1)
}

echo "--- A: noop at target says exactly what it means ---"
C2="$T/current"
git clone -q "$U" "$C2" 2>/dev/null
rm -rf "$T/ha" && cp -r "$H0" "$T/ha" && HA="$T/ha"
entry_adopt "$HA" "$C2" "$BASE"
[[ $? == 0 ]] && pass "A adopt exits 0" || fail "A adopt exits 0"
entry_update "$HA" "$C2" > /tmp/sum-a.out 2>&1
[[ $? == 0 ]] && pass "A noop update exits 0" || fail "A noop update exits 0"
grep -q "^Updating payload $BASE_SHORT" /tmp/sum-a.out \
  && pass "A scopes the revision span to payload" || fail "A scopes the revision span to payload"
grep -q "^Payload: 0 files to deploy (0 updates, 0 new, 0 deletions, 0 sidecars)" /tmp/sum-a.out \
  && pass "A reports zero payload dimension" || fail "A reports zero payload dimension"
grep -q "^✓ Already up to date at " /tmp/sum-a.out \
  && pass "A verdict claims up-to-date" || fail "A verdict claims up-to-date"
if grep -q "Handed off" /tmp/sum-a.out; then
  fail "A has no delegation to report"
else
  pass "A has no delegation to report"
fi
if grep -q "will change" /tmp/sum-a.out; then
  fail "A never implies nothing happened"
else
  pass "A never implies nothing happened"
fi
# The launcher path works from outside the repo through the real name.
ln -sfn "$C2/setup" "$HA/.local/bin/impulse"
(cd /tmp && HOME="$HA" XDG_CONFIG_HOME="$HA/.config" XDG_DATA_HOME="$HA/.local/share" \
  XDG_BIN_HOME="$HA/.local/bin" PATH="$HA/.local/bin:/usr/bin:/bin" \
  impulse update --home "$HA" --state-dir "$HA/.config/illogical-impulse" </dev/null > /tmp/sum-a-imp.out 2>&1)
[[ $? == 0 ]] && grep -q "Already up to date" /tmp/sum-a-imp.out \
  && pass "A impulse update works outside the repo" || fail "A impulse update works outside the repo"

echo "--- B: stale checkout delegates visibly ---"
C="$T/stale"
git clone -q "$U" "$C" 2>/dev/null
git -C "$C" checkout -q -B main "$BASE" 2>/dev/null
git -C "$C" branch --set-upstream-to=origin/main main 2>/dev/null
rm -rf "$T/hb" && cp -r "$H0" "$T/hb" && HB="$T/hb"
entry_adopt "$HB" "$C" "$BASE"
# Updater-only tip: SHA moves, payload identical (empty commit). Note: the
# shared GCOMMIT ends in bare -qm, which would swallow --allow-empty as
# its message, so this commit spells its flags out explicitly.
git -C "$R" -c user.email=fixture@example -c user.name=fixture -c commit.gpgsign=false \
  commit -q --allow-empty -m "updater-only tip" 2>/dev/null
git -C "$R" push -q origin main 2>/dev/null
TIP1=$(git -C "$R" rev-parse HEAD)
TIP1_SHORT=$(git -C "$R" rev-parse --short HEAD)
entry_update "$HB" "$C" > /tmp/sum-b.out 2>&1
[[ $? == 0 ]] && pass "B handed-off noop exits 0" || fail "B handed-off noop exits 0: $(tail -n 3 /tmp/sum-b.out)"
grep -q "Handed off to updater $TIP1_SHORT" /tmp/sum-b.out \
  && pass "B names the executing implementation" || fail "B names the executing implementation"
grep -q "checkout at $BASE_SHORT stays untouched" /tmp/sum-b.out \
  && pass "B names the untouched checkout" || fail "B names the untouched checkout"
[[ "$(grep -c '^Updating ' /tmp/sum-b.out)" == "1" ]] \
  && pass "B prints one summary, not two" || fail "B prints one summary, not two"
grep -q "^Payload: 0 files to deploy" /tmp/sum-b.out \
  && pass "B scopes its zero to payload" || fail "B scopes its zero to payload"
grep -q "^✓ Already up to date at $TIP1_SHORT" /tmp/sum-b.out \
  && pass "B verdict pins the evaluated target" || fail "B verdict pins the evaluated target"

echo "--- C: fetch advances are reported once ---"
grep -q "fetched origin/main .* -> $TIP1_SHORT" /tmp/sum-b.out \
  && pass "C reports the tracking advance" || fail "C reports the tracking advance"
entry_update "$HB" "$C" > /tmp/sum-c.out 2>&1
[[ $? == 0 ]] && pass "C steady-state exits 0" || fail "C steady-state exits 0"
if grep -q "fetched origin/main" /tmp/sum-c.out; then
  fail "C stays silent when nothing moved"
else
  pass "C stays silent when nothing moved"
fi
grep -q "Handed off to updater $TIP1_SHORT" /tmp/sum-c.out \
  && pass "C still delegates every run" || fail "C still delegates every run"

echo "--- D: payload change counts, applies, and reports ---"
printf 'v2\n' > "$R/dots/.config/app/upd.conf"
git -C "$R" add -A
git -C "$R" "${GCOMMIT[@]}" "payload v2" 2>/dev/null
git -C "$R" push -q origin main 2>/dev/null
TIP2_SHORT=$(git -C "$R" rev-parse --short HEAD)
entry_update "$HB" "$C" > /tmp/sum-d.out 2>&1
[[ $? == 0 ]] && pass "D payload update exits 0" || fail "D payload update exits 0: $(tail -n 3 /tmp/sum-d.out)"
grep -q "^Payload: 1 files to deploy (1 updates, 0 new, 0 deletions, 0 sidecars)" /tmp/sum-d.out \
  && pass "D counts the payload dimension" || fail "D counts the payload dimension"
[[ "$(cat "$HB/.config/app/upd.conf")" == "v2" ]] \
  && pass "D deployed the payload" || fail "D deployed the payload"
grep -q "^✓ Updated to $TIP2_SHORT" /tmp/sum-d.out \
  && pass "D verdict names the deployed target" || fail "D verdict names the deployed target"
if grep -q "will change" /tmp/sum-d.out /tmp/sum-b.out /tmp/sum-a.out; then
  fail "no shape uses the old conflated wording"
else
  pass "no shape uses the old conflated wording"
fi

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
