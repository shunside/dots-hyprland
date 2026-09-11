#!/usr/bin/env bash
#
# Real-entrypoint integration coverage for adopt + plan (Slice 3A).
# Library-only fixture runs cannot catch production-shell divergences
# (notably `set -e`, which `setup` enables and test harnesses do not), so
# this suite clones the REAL repo to scratch, commits the worktree
# implementation under test plus a tiny fixture payload, and drives the
# REAL `./setup` end to end. Local clone/file transport only; no network.
# Nothing leaves $T and the source repo is never touched.

set -uo pipefail

PASS=0
FAIL=0
pass(){ PASS=$((PASS+1)); echo "PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }

T="$(mktemp -d /tmp/deploy-entry-XXXXXX)"
trap 'rm -rf "$T"' EXIT

SRC="${DEPLOY_ENTRY_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
I="$T/intrepo"
H="$T/home"
S="$T/state"
mkdir -p "$H/.config/app"

git clone -q "$SRC" "$I"
git -C "$I" checkout -qb inttest
git -C "$I" config user.email "fixture@example"
git -C "$I" config user.name "fixture"
git -C "$I" config commit.gpgsign false
# Worktree implementation under test (tracked modifications + new files).
cp "$SRC/setup" "$I/setup"
mkdir -p "$I/sdata/deploy" "$I/sdata/subcmd-adopt" "$I/sdata/subcmd-plan"
cp "$SRC/sdata/deploy/ownership.conf" "$I/sdata/deploy/"
cp "$SRC/sdata/lib/deploy-common.sh" "$SRC/sdata/lib/deploy-state.sh" "$SRC/sdata/lib/deploy-plan.sh" "$SRC/sdata/lib/setup-launcher.sh" "$I/sdata/lib/"
cp "$SRC/sdata/subcmd-adopt/options.sh" "$SRC/sdata/subcmd-adopt/0.run.sh" "$I/sdata/subcmd-adopt/"
cp "$SRC/sdata/subcmd-plan/options.sh" "$SRC/sdata/subcmd-plan/0.run.sh" "$I/sdata/subcmd-plan/"
# Tiny fixture payload + registry rules.
mkdir -p "$I/dots/.config/inttest"
printf 'same\n' > "$I/dots/.config/inttest/keep.conf"
printf 'v1\n' > "$I/dots/.config/inttest/change.conf"
printf 'bye\n' > "$I/dots/.config/inttest/drop.conf"
printf 'managed dots/.config/inttest .config/inttest\n' >> "$I/sdata/deploy/ownership.conf"
mkdir -p "$H/.config/inttest"
printf 'same\n' > "$H/.config/inttest/keep.conf"
printf 'v1\n' > "$H/.config/inttest/change.conf"
printf 'bye\n' > "$H/.config/inttest/drop.conf"
git -C "$I" add -A
git -C "$I" -c user.email=fixture@example -c user.name=fixture -c commit.gpgsign=false commit -qm "inttest baseline"
REV_B=$(git -C "$I" rev-parse HEAD)

echo "--- real adopt end to end ---"
"$I/setup" adopt --apply --at HEAD --home "$H" --state-dir "$S" > /tmp/entry-adopt.out 2>&1
[[ $? == 0 ]] && pass "real adopt exits 0" || fail "real adopt exits 0: $(tail -n 3 /tmp/entry-adopt.out)"
[[ -f "$S/manifest.jsonl" && -f "$S/deployment-identity.json" ]] \
  && pass "real adopt wrote state" || fail "real adopt wrote state"
"$I/setup" adopt --status --state-dir "$S" > /tmp/entry-status.out 2>&1
[[ $? == 0 ]] && pass "real status exits 0" || fail "real status exits 0"
grep -q "verdict: adoption-complete" /tmp/entry-status.out \
  && pass "real status adoption-complete" || fail "real status adoption-complete"

echo "--- real plan end to end ---"
printf 'v2\n' > "$I/dots/.config/inttest/change.conf"
git -C "$I" rm -q dots/.config/inttest/drop.conf
printf 'new\n' > "$I/dots/.config/inttest/new.conf"
git -C "$I" add -A
git -C "$I" -c user.email=fixture@example -c user.name=fixture -c commit.gpgsign=false commit -qm "inttest delta"
REV_T=$(git -C "$I" rev-parse HEAD)
"$I/setup" plan --at "$REV_T" --home "$H" --state-dir "$S" > /tmp/entry-plan.tsv 2> /tmp/entry-plan.err
[[ $? == 0 ]] && pass "real plan exits 0" || fail "real plan exits 0: $(tail -n 3 /tmp/entry-plan.err)"
grep -q "^update	managed	.config/inttest/change.conf" /tmp/entry-plan.tsv \
  && pass "real plan update row" || fail "real plan update row"
grep -q "^delete-stale	managed	.config/inttest/drop.conf" /tmp/entry-plan.tsv \
  && pass "real plan delete-stale row" || fail "real plan delete-stale row"
grep -q "^add	managed	.config/inttest/new.conf" /tmp/entry-plan.tsv \
  && pass "real plan add row" || fail "real plan add row"
grep -q "^unchanged	managed	.config/inttest/keep.conf" /tmp/entry-plan.tsv \
  && pass "real plan unchanged row" || fail "real plan unchanged row"
"$I/setup" plan --at "$REV_B" --home "$H" --state-dir "$S" > /tmp/entry-plan-same.tsv 2>/dev/null
[[ $? == 0 ]] && pass "real plan at baseline exits 0" || fail "real plan at baseline exits 0"
if grep -Eq "^(update|add|delete-stale|sidecar-new)	" /tmp/entry-plan-same.tsv; then
  fail "real plan proposes no writes at baseline"
else
  pass "real plan proposes no writes at baseline"
fi

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
