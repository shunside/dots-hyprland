#!/usr/bin/env bash
#
# Fixture tests for sdata/lib/terminal-spin.sh: the activity indicator
# must stay silent without a TTY (pipes/logs get zero bytes) and show
# transient frames on a terminal, ending with a clean line. No repo,
# home, or network involved.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/terminal-spin.sh
source "${HERE}/../../lib/terminal-spin.sh"

PASS=0
FAIL=0
pass(){ PASS=$((PASS+1)); echo "PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }

echo "--- silent without a TTY ---"
SPIN_OUT=$(TERM_SPIN_INTERVAL=0.01 bash -c '
  source "'"$HERE"'/../../lib/terminal-spin.sh"
  term_spin_start "doing things"
  sleep 0.3
  term_spin_stop
  echo done
' 2>&1)
[[ "$SPIN_OUT" == "done" ]] && pass "no output when piped" || fail "no output when piped: $(printf '%q' "$SPIN_OUT")"
if grep -q $'\r' <<<"$SPIN_OUT"; then
  fail "no carriage returns when piped"
else
  pass "no carriage returns when piped"
fi
TERM_SPIN_INTERVAL=0.01 term_spin_start "stray" < /dev/null > /tmp/spin-direct.out 2>&1
term_spin_stop < /dev/null >> /tmp/spin-direct.out 2>&1
[[ $? == 0 ]] && pass "start/stop return 0" || fail "start/stop return 0"
[[ ! -s /tmp/spin-direct.out ]] && pass "direct calls stay silent when piped" || fail "direct calls stay silent when piped"
rm -f /tmp/spin-direct.out

echo "--- frames on a terminal, clean ending ---"
if ! command -v script >/dev/null 2>&1; then
  echo "SKIP: script(1) unavailable for pty check"
else
  TERM_SPIN_INTERVAL=0.01 script -qec "bash -c 'source \"$HERE/../../lib/terminal-spin.sh\"; term_spin_start \"testing stages\"; sleep 0.5; term_spin_stop; echo landed'" /dev/null > /tmp/spin-pty.out 2>&1 < /dev/null
  if grep -q '⠋' /tmp/spin-pty.out; then
    pass "spinner frames appear on a tty"
  else
    fail "spinner frames appear on a tty"
  fi
  if grep -q 'landed' /tmp/spin-pty.out; then
    pass "output continues after stop"
  else
    fail "output continues after stop"
  fi
  rm -f /tmp/spin-pty.out
fi

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
