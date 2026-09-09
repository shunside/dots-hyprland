# This script is meant to be sourced by ./setup (subcommand: apply).
# It's not for directly running.
#
# Slice 3B write engine driver. Modes: default apply, --preflight
# (read-only gate evaluation), --resume/--abort (explicit recovery),
# --break-lock (dead-mutex release only).
# Exit 0 completed/nothing-to-do; 2 refused pre-publish; 1 failed
# mid-transaction (lock remains, resume/abort required).

# shellcheck shell=bash

set -uo pipefail
DEPLOY_LIB_DIR="${DEPLOY_LIB_DIR:-${REPO_ROOT}/sdata/lib}"
source "${DEPLOY_LIB_DIR}/deploy-common.sh"
source "${DEPLOY_LIB_DIR}/deploy-state.sh"
source "${DEPLOY_LIB_DIR}/deploy-plan.sh"
source "${DEPLOY_LIB_DIR}/deploy-decide.sh"
source "${DEPLOY_LIB_DIR}/deploy-apply.sh"

if ! deploy_require_jq; then
  exit 1
fi

# --- break-lock: dead mutex release only, then stop. ---
if [[ "${DEPLOY_APPLY_BREAK}" == true ]]; then
  BREAK_SD="${DEPLOY_STATE_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/illogical-impulse}"
  if ! deploy_lock_break "$BREAK_SD"; then
    exit 1
  fi
  exit 0
fi

if [[ ! -d "${DEPLOY_HOME_DIR}" ]]; then
  echo "[$0]: --home is not a directory: ${DEPLOY_HOME_DIR}" >&2
  exit 1
fi
if ! DEPLOY_HOME=$(cd "${DEPLOY_HOME_DIR}" 2>/dev/null && pwd -P); then
  echo "[$0]: cannot resolve --home: ${DEPLOY_HOME_DIR}" >&2
  exit 1
fi
DEPLOY_SELF_HOME=$(cd "$HOME" 2>/dev/null && pwd -P || echo "$HOME")
if [[ "$DEPLOY_HOME" == "$DEPLOY_SELF_HOME" ]]; then
  DEPLOY_XDG_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
  DEPLOY_XDG_DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
else
  DEPLOY_XDG_CONFIG="${DEPLOY_HOME}/.config"
  DEPLOY_XDG_DATA="${DEPLOY_HOME}/.local/share"
fi
export DEPLOY_HOME DEPLOY_XDG_CONFIG DEPLOY_XDG_DATA

if ! APPLY_SD_RESOLVED=$(deploy_state_dir_resolve "$DEPLOY_HOME" "${DEPLOY_STATE_DIR:-}" 2>/dev/null); then
  deploy_state_dir_resolve "$DEPLOY_HOME" "${DEPLOY_STATE_DIR:-}" >&2 || true
  exit 2
fi
APPLY_SD="$APPLY_SD_RESOLVED"
APPLY_DECISIONS_FILE="$APPLY_SD/$DEPLOY_DECISIONS_NAME"
export APPLY_SD APPLY_DECISIONS_FILE

# --- resume / abort: journal intent governs; never trust new flags. ---
# Preserve the callee's exit code (2 refusal vs 1 failure) for callers.
if [[ -n "${DEPLOY_APPLY_RESUME}" ]]; then
  rc=0
  deploy_apply_resume "${DEPLOY_APPLY_RESUME}" || rc=$?
  exit "$rc"
fi
if [[ -n "${DEPLOY_APPLY_ABORT}" ]]; then
  rc=0
  deploy_apply_abort "${DEPLOY_APPLY_ABORT}" || rc=$?
  exit "$rc"
fi

# --- fresh path: shared prepare (identical gates for every caller). ---
prepare_rc=0
deploy_apply_prepare_all || prepare_rc=$?
if (( prepare_rc != 0 )); then
  exit "$prepare_rc"
fi
if [[ "${DEPLOY_APPLY_PREFLIGHT}" == true ]]; then
  echo "[$0]: preflight would proceed; zero writes performed"
  exit 0
fi

# --- mutation path. ---
run_rc=0
deploy_apply_run_fresh || run_rc=$?
# run_fresh returns 2 for pre-publish refusals (lock race), 1 for mid-tx
# failure (lock remains, resume/abort required).
exit "$run_rc"
