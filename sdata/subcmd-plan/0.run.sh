# This script is meant to be sourced by ./setup (subcommand: plan).
# It's not for directly running.
#
# Slice 3A: read-only update planning. Prints the plan TSV to stdout
# (machine-readable, pipeable) and a human summary to stderr. Zero writes:
# no deployed/user files, no metadata, no plan persistence, no refs,
# no network. Exit 0 = plan complete (conflicts are data, not failure);
# exit 2 = planning refused (bad/incomplete state, home mismatch,
# unclassifiable target); exit 1 = hard error.

# shellcheck shell=bash

set -uo pipefail
# DEPLOY_LIB_DIR override exists solely for fixture tests (see adopt).
DEPLOY_LIB_DIR="${DEPLOY_LIB_DIR:-${REPO_ROOT}/sdata/lib}"
source "${DEPLOY_LIB_DIR}/deploy-common.sh"
source "${DEPLOY_LIB_DIR}/deploy-state.sh"
source "${DEPLOY_LIB_DIR}/deploy-plan.sh"

# jq reads all durable state; fail closed before any output or comparison.
if ! deploy_require_jq; then
  exit 1
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

# State destination: same explicitness rule as adoption.
STATE_RC=0
STATE_DIR=$(deploy_state_dir_resolve "$DEPLOY_HOME" "${DEPLOY_STATE_DIR:-}" 2>/dev/null) || STATE_RC=$?
if (( STATE_RC != 0 )); then
  deploy_state_dir_resolve "$DEPLOY_HOME" "${DEPLOY_STATE_DIR:-}" >&2 || true
  exit 2
fi

# Baseline first: verifies state, checks the comparison home, and rejects
# mixed-revision manifests. Refusal, not error.
if ! deploy_plan_load_state "$STATE_DIR"; then
  exit 2
fi

# Target revision: local resolution only (no fetch/latest in this slice).
if ! TARGET_SHA=$(deploy_resolve_revision "${DEPLOY_AT}"); then
  exit 1
fi
TARGET_ONELINE=$(git -C "$REPO_ROOT" log -1 --format='%h %s' "$TARGET_SHA" 2>/dev/null || echo "(no log)")

# Effective payload inputs: explicit flags win; otherwise the adopted inputs
# (like-for-like comparison is the conservative default). Ambient
# FONTSET_DIR_NAME/INSTALL_VIA_NIX are deliberately ignored so plans are
# reproducible regardless of shell environment; adoption has no prior
# identity to default from, which is why it still honors them.
unset FONTSET_DIR_NAME INSTALL_VIA_NIX
if [[ "${DEPLOY_PLAN_FONTSET_SET}" == true ]]; then
  if [[ "${DEPLOY_PLAN_FONTSET}" != "default" ]]; then
    FONTSET_DIR_NAME="${DEPLOY_PLAN_FONTSET}"
  fi
  EFF_FONTSET="${DEPLOY_PLAN_FONTSET}"
elif [[ -n "$PLAN_BASE_FONTSET" ]]; then
  FONTSET_DIR_NAME="$PLAN_BASE_FONTSET"
  EFF_FONTSET="$PLAN_BASE_FONTSET"
else
  EFF_FONTSET="(default)"
fi
if [[ "${DEPLOY_PLAN_VIANIX_SET}" == true ]]; then
  INSTALL_VIA_NIX=true
  EFF_VIANIX=true
else
  EFF_VIANIX="$PLAN_BASE_VIANIX"
  if [[ "$EFF_VIANIX" == true ]]; then INSTALL_VIA_NIX=true; fi
fi
export FONTSET_DIR_NAME INSTALL_VIA_NIX

# Target image + lint gate: an unclassifiable target means no plan at all.
if ! deploy_plan_load_target "$TARGET_SHA"; then
  exit 2
fi

# Union of manifest paths and target payload paths, sorted for stable output.
declare -A UNION_ALL=()
p=""
for p in "${!PLAN_M_STATUS[@]}"; do UNION_ALL[$p]=1; done
for p in "${!PLAN_T_CLASS[@]}" "${!PLAN_T_SUB[@]}"; do UNION_ALL[$p]=1; done
PLAN_TSV=""
sorted=()
if (( ${#UNION_ALL[@]} > 0 )); then
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    sorted+=("$p")
  done < <(printf '%s\n' "${!UNION_ALL[@]}" | LC_ALL=C sort)
fi
row=""
for p in "${sorted[@]}"; do
  row=$(deploy_plan_path "$p") || { echo "[$0]: decision failed for $p" >&2; exit 1; }
  [[ -z "$row" ]] && continue  # Invisible by design (in neither universe).
  PLAN_TSV+="${row}"$'\n'
done
# Strip the trailing newline: a leftover empty row would poison the
# histogram below with an empty op key.
PLAN_TSV="${PLAN_TSV%$'\n'}"

# Weak legacy evidence: informational rows for every evidence path, with
# overlap marked (manifest/target already carry the strong state).
# Parsed with jq via deploy_plan_load_evidence; malformed evidence refuses
# the plan rather than silently dropping rows.
EVIDENCE_ROWS=""
ev_src="${DEPLOY_XDG_CONFIG}/illogical-impulse/${DEPLOY_EVIDENCE_NAME}"
if [[ -f "${STATE_DIR}/${DEPLOY_EVIDENCE_NAME}" ]]; then
  ev_src="${STATE_DIR}/${DEPLOY_EVIDENCE_NAME}"
fi
if [[ -f "$ev_src" ]]; then
  if ! deploy_plan_load_evidence "$ev_src"; then
    exit 2
  fi
  for ev_path in ${PLAN_EV[@]+"${PLAN_EV[@]}"}; do
    overlap="weak-only"
    if [[ -n "${PLAN_M_STATUS[$ev_path]:-}" ]]; then overlap="also-in-manifest"; fi
    if [[ -n "${PLAN_T_CLASS[$ev_path]:-}" || -n "${PLAN_T_SUB[$ev_path]:-}" ]]; then
      if [[ "$overlap" == "weak-only" ]]; then overlap="also-in-target"; else overlap="also-in-manifest+target"; fi
    fi
    ev_disk=""; ev_live="unknown"
    if ev_disk=$(deploy_map_home "$ev_path" 2>/dev/null); then
      ev_live=$(deploy_plan_observe "$ev_disk")
    fi
    ev_blob="-"
    if [[ -n "${PLAN_T_BLOB[$ev_path]:-}" ]]; then ev_blob="${PLAN_T_BLOB[$ev_path]}"; fi
    printf -v ev_row 'legacy\t-\t%s\t-\t-\t%s\t%s\t%s;informational-only-never-an-op\n' "$ev_path" "$ev_blob" "$ev_live" "$overlap"
    EVIDENCE_ROWS+="$ev_row"
  done
fi
EVIDENCE_ROWS="${EVIDENCE_ROWS%$'\n'}"

printf '# deploy-plan\tbaseline=%s\ttarget=%s\n' "$PLAN_BASE_REV" "$TARGET_SHA"
printf '# op\tclass\tpath\tbase-blob\tbase-disk\ttarget-blob\tlive\tdetail\n'
# Bodies are newline-stripped; exactly one separator each, no empty rows.
if [[ -n "$PLAN_TSV" ]]; then printf '%s\n' "$PLAN_TSV"; fi
if [[ -n "$EVIDENCE_ROWS" ]]; then printf '%s\n' "$EVIDENCE_ROWS"; fi

# --- Human summary on stderr. ---
{
echo "[$0]: update plan (zero writes performed)"
echo "  baseline: ${PLAN_BASE_REV} (adopted; inputs fontset=${PLAN_BASE_FONTSET:-(default)} via_nix=${PLAN_BASE_VIANIX})"
echo "  target:   ${TARGET_SHA} (${TARGET_ONELINE})"
echo "  specced:  ${DEPLOY_AT}"
echo "  inputs:   fontset=${EFF_FONTSET} via_nix=${EFF_VIANIX}"
echo "  home:     ${DEPLOY_HOME}"
echo "  registry: ${#DEPLOY_R_SRC[@]} rules from target revision"
if (( ${#PLAN_T_EXCLUDED[@]} > 0 )); then
  echo "  excluded-by-input: ${#PLAN_T_EXCLUDED[@]} target path(s) deliberately undeployed under these inputs:"
  for p in "${PLAN_T_EXCLUDED[@]}"; do echo "    $p"; done
fi
declare -A ocounts=()
while IFS=$'\t' read -r op _c _p _b _d _t _l _x; do
  [[ -z "$op" ]] && continue
  case "$op" in \#*) continue;; esac
  ocounts[$op]=$(( ${ocounts[$op]:-0} + 1 ))
done <<<"${PLAN_TSV}${EVIDENCE_ROWS}"
order=(update add delete-stale sidecar-new unchanged converged gone conflict-drift conflict-removed delete-blocked drift-unchanged drift-update drift-moved drift-removed missing-unchanged appeared class-changed retired type-changed preserved user-absent submodule-ok submodule-diverged submodule-update-available submodule-missing legacy error)
rollup_noop=0; rollup_write=0; rollup_decide=0; rollup_info=0
for op in "${order[@]}"; do
  n=${ocounts[$op]:-0}
  (( n == 0 )) && continue
  case "$op" in
    unchanged|converged|gone) rollup_noop=$((rollup_noop + n));;
    update|add|delete-stale|sidecar-new) rollup_write=$((rollup_write + n));;
    preserved|user-absent|submodule-ok|retired|legacy) rollup_info=$((rollup_info + n));;
    *) rollup_decide=$((rollup_decide + n));;
  esac
done
echo "  rollup:   noop=${rollup_noop} write=${rollup_write} decide=${rollup_decide} info=${rollup_info}"
echo "  ops:"
for op in "${order[@]}"; do
  n=${ocounts[$op]:-0}
  (( n == 0 )) && continue
  printf '    %-26s %s\n' "$op" "$n"
done
for op in update add delete-stale sidecar-new conflict-drift conflict-removed delete-blocked drift-unchanged drift-update drift-moved drift-removed missing-unchanged appeared class-changed retired type-changed submodule-diverged submodule-update-available submodule-missing legacy error; do
  n=${ocounts[$op]:-0}
  (( n == 0 )) && continue
  echo "  --- ${op} (${n}) ---"
  while IFS=$'\t' read -r o c path bb bd tb live detail; do
    [[ -z "$o" ]] && continue
    if [[ "$o" == "$op" ]]; then
      printf '    [%s] %s  base=%s live=%s target=%s %s\n' "$c" "$path" "${bb:0:12}" "${live:0:24}" "${tb:0:12}" "$detail"
    fi
  done <<<"${PLAN_TSV}${EVIDENCE_ROWS}"
done
echo "  unchanged/converged/gone omitted from listing (see TSV); preserved user paths left alone"
echo "  decide/* rows need a recorded decision before any future apply may touch them"
} >&2

exit 0
