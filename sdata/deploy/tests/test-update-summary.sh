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
# Genuinely current before invocation: concise verdict, no narrative.
[[ "$(grep -c '^Updating ' /tmp/sum-a.out)" == "0" ]] \
  && pass "A skips the update narrative" || fail "A skips the update narrative"
[[ "$(grep -c '^Payload:' /tmp/sum-a.out)" == "0" ]] \
  && pass "A prints no payload dimension" || fail "A prints no payload dimension"
grep -q "^✓ Already up to date at " /tmp/sum-a.out \
  && pass "A verdict claims up-to-date" || fail "A verdict claims up-to-date"
[[ "$(jq -r '.last_verified.target // empty' "$HA/.config/illogical-impulse/deployment-identity.json")" == "$BASE" ]] \
  && pass "A records the verified target" || fail "A records the verified target"
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
grep -q "checkout $BASE_SHORT evaluated as-is" /tmp/sum-b.out \
  && pass "B names the unevaluated checkout" || fail "B names the unevaluated checkout"
[[ "$(grep -c '^Updating ' /tmp/sum-b.out)" == "1" ]] \
  && pass "B prints one summary, not two" || fail "B prints one summary, not two"
grep -q "^Payload: 0 files to deploy" /tmp/sum-b.out \
  && pass "B scopes its zero to payload" || fail "B scopes its zero to payload"
grep -q "^✓ Up to date at $TIP1_SHORT" /tmp/sum-b.out && ! grep -q "Already" /tmp/sum-b.out \
  && pass "B verdict is became-current" || fail "B verdict is became-current"

echo "--- C: followed checkout needs no delegation ---"
grep -q "fetched origin/main .* -> $TIP1_SHORT" /tmp/sum-b.out \
  && pass "C reports the tracking advance" || fail "C reports the tracking advance"
entry_update "$HB" "$C" > /tmp/sum-c.out 2>&1
[[ $? == 0 ]] && pass "C steady-state exits 0" || fail "C steady-state exits 0"
if grep -q "fetched origin/main" /tmp/sum-c.out; then
  fail "C stays silent when nothing moved"
else
  pass "C stays silent when nothing moved"
fi
if grep -q "Handed off" /tmp/sum-c.out; then
  fail "C delegates nothing at target"
else
  pass "C delegates nothing at target"
fi
grep -q "^✓ Already up to date at $TIP1_SHORT" /tmp/sum-c.out \
  && pass "C verdict is already-current" || fail "C verdict is already-current"

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

echo "--- E: immediate second invocation is steady ---"
entry_update "$HB" "$C" > /tmp/sum-e.out 2>&1
[[ $? == 0 ]] && pass "E second update exits 0" || fail "E second update exits 0"
[[ "$(grep -c '^Updating ' /tmp/sum-e.out)" == "0" ]] \
  && pass "E skips the update narrative" || fail "E skips the update narrative"
grep -q "^✓ Already up to date at $TIP2_SHORT" /tmp/sum-e.out \
  && pass "E verdict is already-current" || fail "E verdict is already-current"
[[ "$(git -C "$C" rev-parse HEAD)" == "$(git -C "$C" rev-parse origin/main)" ]] \
  && pass "E checkout follows the target" || fail "E checkout follows the target"

echo "--- C2: stuck checkout delegates every run ---"
git -C "$C" config user.email "fixture@example"
git -C "$C" config user.name "fixture"
printf 'local\n' > "$C/local-notes.txt"
git -C "$C" add local-notes.txt
git -C "$C" "${GCOMMIT[@]}" "local work" 2>/dev/null
git -C "$R" -c user.email=fixture@example -c user.name=fixture -c commit.gpgsign=false \
  commit -q --allow-empty -m "remote moves on" 2>/dev/null
git -C "$R" push -q origin main 2>/dev/null
TIP3_SHORT=$(git -C "$R" rev-parse --short HEAD)
entry_update "$HB" "$C" > /tmp/sum-c2a.out 2>&1
entry_update "$HB" "$C" > /tmp/sum-c2b.out 2>&1
[[ $? == 0 ]] && pass "C2 stuck updates exit 0" || fail "C2 stuck updates exit 0"
grep -q "^Handed off to updater $TIP3_SHORT" /tmp/sum-c2a.out && grep -q "^Handed off to updater $TIP3_SHORT" /tmp/sum-c2b.out \
  && pass "C2 delegates on every run" || fail "C2 delegates on every run"
grep -q "^✓ Up to date at $TIP3_SHORT" /tmp/sum-c2a.out && ! grep -q "Already" /tmp/sum-c2a.out \
  && pass "C2 never claims already-current" || fail "C2 never claims already-current"
if grep -q "^Advanced checkout" /tmp/sum-c2a.out /tmp/sum-c2b.out; then
  fail "C2 diverged checkout never advances"
else
  pass "C2 diverged checkout never advances"
fi
[[ "$(git -C "$C" log --oneline | head -n 1)" == *"local work"* ]] \
  && pass "C2 local commit untouched" || fail "C2 local commit untouched"

echo "--- F: detached checkout degrades to local, advances nothing ---"
CF="$T/detached"
git clone -q "$U" "$CF" 2>/dev/null
git -C "$CF" checkout -q --detach HEAD 2>/dev/null
DETACHED=$(git -C "$CF" rev-parse HEAD)
rm -rf "$T/hf" && cp -r "$H0" "$T/hf" && HF="$T/hf"
printf 'v2\n' > "$HF/.config/app/upd.conf"
entry_adopt "$HF" "$CF" "$DETACHED"
entry_update "$HF" "$CF" > /tmp/sum-f.out 2>&1
[[ $? == 0 ]] && pass "F detached update exits 0" || fail "F detached update exits 0"
grep -q "no remote tracking branch configured" /tmp/sum-f.out \
  && pass "F says it runs local-only" || fail "F says it runs local-only"
if grep -q "Handed off\|Advanced checkout\|fetched " /tmp/sum-f.out; then
  fail "F touches no remote state"
else
  pass "F touches no remote state"
fi
[[ "$(git -C "$CF" rev-parse HEAD)" == "$DETACHED" ]] \
  && pass "F detached HEAD unmoved" || fail "F detached HEAD unmoved"
grep -q "^✓ Already up to date at " /tmp/sum-f.out && [[ "$(grep -c '^Updating ' /tmp/sum-f.out)" == "0" ]] \
  && pass "F steady verdict is a single line" || fail "F steady verdict is a single line"

echo "--- G: cross-version handoff converges the checkout ---"
# Exact field shape: the checkout's own updater predates checkout
# convergence (hands off silently, then exits), while the pinned target
# implementation skips advancement for explicitly pinned runs. Only the
# handoff-inner path may advance here.
OLD_REV="a2a890be"
if ! git -C "$SRC" cat-file -e "${OLD_REV}^{commit}" 2>/dev/null; then
  echo "SKIP: outer revision $OLD_REV not present"
else
  G2U="$T/g-upstream.git"
  git init -q --bare "$G2U"
  git --git-dir="$G2U" symbolic-ref HEAD refs/heads/main
  GR="$T/g-origin"
  git init -q "$GR"
  git -C "$GR" checkout -qb main 2>/dev/null || true
  git -C "$GR" config user.email "fixture@example"
  git -C "$GR" config user.name "fixture"
  git -C "$GR" config commit.gpgsign false
  git -C "$SRC" archive "$OLD_REV" setup sdata | tar -x -C "$GR"
  mkdir -p "$GR/dots/.config/app"
  printf 'managed dots/.config/app .config/app\n' > "$GR/sdata/deploy/ownership.conf"
  printf 'same\n' > "$GR/dots/.config/app/keep.conf"
  printf 'v1\n' > "$GR/dots/.config/app/upd.conf"
  git -C "$GR" add -A
  git -C "$GR" "${GCOMMIT[@]}" "stale era base"
  GBASE=$(git -C "$GR" rev-parse HEAD)
  git -C "$GR" push -q "$G2U" main 2>/dev/null
  rm -rf "$GR/sdata"
  cp -r "$SRC/sdata" "$GR/sdata"
  cp "$SRC/setup" "$GR/setup"
  printf 'managed dots/.config/app .config/app\n' > "$GR/sdata/deploy/ownership.conf"
  git -C "$GR" add -A
  git -C "$GR" "${GCOMMIT[@]}" "current tip"
  git -C "$GR" push -q "$G2U" main 2>/dev/null
  GTIP=$(git -C "$GR" rev-parse HEAD)
  GTIP_SHORT=$(git -C "$GR" rev-parse --short HEAD)
  GC="$T/g-stale"
  git clone -q "$G2U" "$GC" 2>/dev/null
  git -C "$GC" checkout -q -B main "$GBASE" 2>/dev/null
  git -C "$GC" branch --set-upstream-to=origin/main main 2>/dev/null
  [[ "$(grep -c 'update_advance_checkout' "$GC/sdata/subcmd-update/0.run.sh" 2>/dev/null)" == "0" ]] \
    && pass "G outer predates checkout convergence" || fail "G outer predates checkout convergence"
  rm -rf "$T/hg" && cp -r "$H0" "$T/hg" && HG="$T/hg" && SDG="$HG/.config/illogical-impulse"
  (cd /tmp && HOME="$HG" XDG_CONFIG_HOME="$HG/.config" XDG_DATA_HOME="$HG/.local/share" \
    XDG_BIN_HOME="$HG/.local/bin" "$GC/setup" adopt --apply --at "$GBASE" --home "$HG" --state-dir "$SDG" </dev/null > /dev/null 2>&1)
  [[ $? == 0 ]] && pass "G old adopt exits 0" || fail "G old adopt exits 0"
  (cd /tmp && HOME="$HG" XDG_CONFIG_HOME="$HG/.config" XDG_DATA_HOME="$HG/.local/share" \
    XDG_BIN_HOME="$HG/.local/bin" "$GC/setup" update --home "$HG" --state-dir "$SDG" </dev/null > /tmp/sum-g.out 2>&1)
  [[ $? == 0 ]] && pass "G cross-version update exits 0" || fail "G cross-version update exits 0: $(tail -n 3 /tmp/sum-g.out)"
  [[ "$(git -C "$GC" rev-parse HEAD)" == "$GTIP" ]] \
    && pass "G stale checkout converged to target" || fail "G stale checkout converged to target"
  [[ "$(jq -r '.last_verified.target // empty' "$SDG/deployment-identity.json")" == "$GTIP" ]] \
    && pass "G verified checkpoint pinned target" || fail "G verified checkpoint pinned target"
  grep -q "^Advanced checkout .* -> $GTIP_SHORT" /tmp/sum-g.out \
    && pass "G advance reported by inner runner" || fail "G advance reported by inner runner"
  (cd /tmp && HOME="$HG" XDG_CONFIG_HOME="$HG/.config" XDG_DATA_HOME="$HG/.local/share" \
    XDG_BIN_HOME="$HG/.local/bin" "$GC/setup" update --home "$HG" --state-dir "$SDG" </dev/null > /tmp/sum-g2.out 2>&1)
  [[ $? == 0 ]] && pass "G second update exits 0" || fail "G second update exits 0"
  grep -q "^✓ Already up to date at $GTIP_SHORT" /tmp/sum-g2.out && [[ "$(grep -c '^Updating ' /tmp/sum-g2.out)" == "0" ]] \
    && pass "G second run is concise steady state" || fail "G second run is concise steady state"
fi

if grep -q "will change" /tmp/sum-d.out /tmp/sum-b.out /tmp/sum-a.out; then
  fail "no shape uses the old conflated wording"
else
  pass "no shape uses the old conflated wording"
fi

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
