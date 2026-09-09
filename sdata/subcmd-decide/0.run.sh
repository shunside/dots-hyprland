# This script is meant to be sourced by ./setup (subcommand: decide).
# It's not for directly running.
#
# Durable decision records for update planning. --list is read-only;
# --set/--remove write only the decisions file inside the state dir
# (atomically), never deployed files or adoption metadata.
# Exit 0 success; 2 refusal (bad choice, nothing to decide, unknown path);
# 1 hard error.

# shellcheck shell=bash

set -uo pipefail
DEPLOY_LIB_DIR="${DEPLOY_LIB_DIR:-${REPO_ROOT}/sdata/lib}"
source "${DEPLOY_LIB_DIR}/deploy-common.sh"
source "${DEPLOY_LIB_DIR}/deploy-state.sh"
source "${DEPLOY_LIB_DIR}/deploy-plan.sh"
source "${DEPLOY_LIB_DIR}/deploy-decide.sh"

if ! deploy_require_jq; then
  exit 1
fi

# State destination: same explicitness rule as adoption/planning.
if ! DECIDE_SD=$(deploy_state_dir_resolve "${DEPLOY_HOME_DIR}" "${DEPLOY_STATE_DIR:-}" 2>/dev/null); then
  deploy_state_dir_resolve "${DEPLOY_HOME_DIR}" "${DEPLOY_STATE_DIR:-}" >&2 || true
  exit 2
fi
DECIDE_FILE="${DECIDE_SD}/${DEPLOY_DECISIONS_NAME}"

# --- --list (default when nothing else asked): pure readback. ---
if [[ "${#DEPLOY_DECIDE_SET[@]}" == 0 && "${#DEPLOY_DECIDE_REMOVE[@]}" == 0 ]]; then
  if ! deploy_decisions_load "$DECIDE_FILE"; then
    exit 1
  fi
  if (( ${#DEC_D_CHOICE[@]} == 0 )); then
    echo "[$0]: no decisions recorded in $DECIDE_FILE"
    exit 0
  fi
  printf 'path\tchoice\top\tlive\ttarget\tdecided_at\n'
  p=""
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$p" "${DEC_D_CHOICE[$p]}" "${DEC_D_OP[$p]}" "${DEC_D_LIVE[$p]:0:18}" "${DEC_D_TARGET[$p]:0:12}" "${DEC_D_AT[$p]}"
  done < <(printf '%s\n' "${!DEC_D_CHOICE[@]}" | LC_ALL=C sort)
  exit 0
fi

# --- --set/--remove need full fresh-plan context for fingerprinting. ---
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

if ! deploy_plan_load_state "$DECIDE_SD"; then
  exit 2
fi
if ! DECIDE_SHA=$(deploy_resolve_revision "${DEPLOY_AT}"); then
  exit 1
fi
# Effective inputs: explicit flags win, else adopted inputs. Ambient
# FONTSET_DIR_NAME/INSTALL_VIA_NIX are ignored so fingerprints recorded
# here stay reproducible regardless of shell environment.
unset FONTSET_DIR_NAME INSTALL_VIA_NIX
if [[ "${DEPLOY_DECIDE_FONTSET_SET}" == true && "${DEPLOY_DECIDE_FONTSET}" != "default" ]]; then
  FONTSET_DIR_NAME="${DEPLOY_DECIDE_FONTSET}"
elif [[ "${DEPLOY_DECIDE_FONTSET_SET}" != true && -n "$PLAN_BASE_FONTSET" ]]; then
  FONTSET_DIR_NAME="$PLAN_BASE_FONTSET"
fi
if [[ "${DEPLOY_DECIDE_VIANIX_SET}" == true || "$PLAN_BASE_VIANIX" == "true" ]]; then
  INSTALL_VIA_NIX=true
fi
export FONTSET_DIR_NAME INSTALL_VIA_NIX
if ! deploy_plan_load_target "$DECIDE_SHA"; then
  exit 2
fi

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# Index-based iteration: specs may contain spaces (paths); unquoted
# ${arr[@]} expansion would re-split them on IFS.
for ((di = 0; di < ${#DEPLOY_DECIDE_SET[@]}; di++)); do
  spec="${DEPLOY_DECIDE_SET[$di]}"
  if [[ "$spec" != *=* ]]; then
    echo "[$0]: --set needs PATH=CHOICE, got: $spec" >&2
    exit 2
  fi
  spath="${spec%%=*}"
  schoice="${spec#*=}"
  if [[ -z "$spath" || -z "$schoice" ]]; then
    echo "[$0]: --set needs non-empty PATH and CHOICE, got: $spec" >&2
    exit 2
  fi
  srow=$(deploy_plan_path "$spath") || { echo "[$0]: decision failed for $spath" >&2; exit 1; }
  if [[ -z "$srow" ]]; then
    echo "[$0]: nothing to decide for path (invisible to planner): $spath" >&2
    exit 2
  fi
  IFS=$'\t' read -r sop sclass _p sb_blob sb_disk st_blob slive _detail <<<"$srow"
  # Kind for choice validation: manifest kind, else target-derived (new
  # payload rows have no manifest record).
  skind="${PLAN_M_KIND[$spath]:-}"
  if [[ -z "$skind" ]]; then
    if [[ -n "${PLAN_T_SUB[$spath]:-}" ]]; then skind="submodule"
    elif [[ "${PLAN_T_MODE[$spath]:-}" == "120000" ]]; then skind="symlink"
    else skind="file"; fi
  fi
  if ! deploy_decide_allowed "$sop" "$schoice" "$skind"; then
    echo "[$0]: choice '$schoice' is not valid for '$spath' (operation: $sop)" >&2
    exit 2
  fi
  # Fingerprints are the fresh row values (live observation, target, base).
  if ! deploy_decision_record "$DECIDE_FILE" "$spath" "$schoice" "$sop" "$slive" "$st_blob" "$sb_blob" "$skind" "$NOW"; then
    exit 1
  fi
  echo "[$0]: recorded $spath = $schoice (op $sop)"
done
for ((di = 0; di < ${#DEPLOY_DECIDE_REMOVE[@]}; di++)); do
  rpath="${DEPLOY_DECIDE_REMOVE[$di]}"
  if ! deploy_decision_remove "$DECIDE_FILE" "$rpath"; then
    exit 1
  fi
  echo "[$0]: forgot decision for $rpath"
done
exit 0
