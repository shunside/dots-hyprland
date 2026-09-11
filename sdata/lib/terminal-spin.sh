# This is NOT a script for execution, but for loading functions, so NOT need execution permission or shebang.
#
# Minimal terminal activity indicator for operations with quiet stretches
# (network fetch, plan evaluation, file writes). Frames go to stderr and
# only when stderr is a terminal: pipes, logs, and non-interactive runs
# never see a frame. Transient by design — stopping clears the line so
# scrollback keeps only the persistent summary/result lines.

# shellcheck shell=bash

TERM_SPIN_PID=""

# Start spinning with a stage label. Safe to call when already spinning
# (restarts with the new label) and safe anywhere: no-op without a TTY.
function term_spin_start(){
  term_spin_stop >/dev/null 2>&1 || true
  [[ -t 2 ]] || return 0
  local label="${1:-working}"
  local interval="${TERM_SPIN_INTERVAL:-0.08}"
  (
    while :; do
      for frame in ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏; do
        printf '\r%s %s' "$frame" "$label" >&2
        sleep "$interval"
      done
    done
  ) &
  TERM_SPIN_PID=$!
  return 0
}

function term_spin_stop(){
  if [[ -n "${TERM_SPIN_PID:-}" ]]; then
    kill "$TERM_SPIN_PID" 2>/dev/null || true
    wait "$TERM_SPIN_PID" 2>/dev/null || true
    TERM_SPIN_PID=""
    if [[ -t 2 ]]; then printf '\r%*s\r' 48 '' >&2 || true; fi
  fi
  return 0
}
