# This script is meant to be sourced by ./setup (subcommand: update).
# It's not for directly running.
#
# One-command fork update with user-facing presentation. Composes the
# existing deployment primitives in order — state classification, shared
# plan computation, shared preflight gates, transactional apply,
# post-apply verification — without adding new gates or bypassing any.
# Read-only until every gate passes; on any refusal it stops before the
# first write and names the exact next command.
#
# Presentation contract: normal output talks about user concepts only
# (revisions, file counts, kept choices, readiness, next actions).
# Technical detail (preflight internals, fingerprints, transaction
# machinery) stays in a captured log shown solely on failure, in the
# fallback refusal path, or with --verbose. Exit 0 updated / already up
# to date / dry-run clean; 2 blocked pre-publish (guidance printed);
# 1 failed mid-transaction (lock remains, resume/abort via `setup apply`).

# shellcheck shell=bash

set -uo pipefail
DEPLOY_LIB_DIR="${DEPLOY_LIB_DIR:-${REPO_ROOT}/sdata/lib}"
# Terminal styles come from sdata/lib/environment-variables.sh under real
# ./setup; default them here so direct sourcing (tests, harnesses) renders
# plain instead of tripping `set -u`. Empty means the same degradation
# setup applies for piped/NO_COLOR/dumb output.
: "${STY_RED:=}" "${STY_GREEN:=}" "${STY_YELLOW:=}" "${STY_BLUE:=}"
: "${STY_PURPLE:=}" "${STY_CYAN:=}" "${STY_BOLD:=}" "${STY_FAINT:=}"
: "${STY_SLANT:=}" "${STY_UNDERLINE:=}" "${STY_BLINK:=}" "${STY_INVERT:=}" "${STY_RST:=}"
source "${DEPLOY_LIB_DIR}/deploy-common.sh"
source "${DEPLOY_LIB_DIR}/deploy-state.sh"
source "${DEPLOY_LIB_DIR}/deploy-plan.sh"
source "${DEPLOY_LIB_DIR}/deploy-decide.sh"
source "${DEPLOY_LIB_DIR}/deploy-apply.sh"

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

if ! APPLY_SD_RESOLVED=$(deploy_state_dir_resolve "$DEPLOY_HOME" "${DEPLOY_STATE_DIR:-}" 2>/dev/null); then
  deploy_state_dir_resolve "$DEPLOY_HOME" "${DEPLOY_STATE_DIR:-}" >&2 || true
  exit 2
fi
APPLY_SD="$APPLY_SD_RESOLVED"
APPLY_DECISIONS_FILE="$APPLY_SD/$DEPLOY_DECISIONS_NAME"
export APPLY_SD APPLY_DECISIONS_FILE

# Echo-back suffix so copy-pasted follow-ups reuse non-default inputs.
UPDATE_SUFFIX=""
if [[ "${DEPLOY_AT:-HEAD}" != "HEAD" ]]; then
  UPDATE_SUFFIX+=" --at $(printf '%q' "$DEPLOY_AT")"
fi
if [[ -n "${DEPLOY_STATE_DIR:-}" ]]; then
  UPDATE_SUFFIX+=" --state-dir $(printf '%q' "$DEPLOY_STATE_DIR")"
fi
if [[ "${DEPLOY_HOME_DIR}" != "$HOME" ]]; then
  UPDATE_SUFFIX+=" --home $(printf '%q' "$DEPLOY_HOME_DIR")"
fi

# Technical log: captured in normal mode, streamed live with --verbose.
UPDATE_LOG=""
if [[ "${DEPLOY_UPDATE_VERBOSE:-false}" != true ]]; then
  UPDATE_LOG="$(mktemp "${TMPDIR:-/tmp}/setup-update-XXXXXX.log" 2>/dev/null)" || exit 1
  # shellcheck disable=SC2064
  trap "rm -f '$UPDATE_LOG'" EXIT
fi
# Run a lib entry, capturing technical output unless verbose. Both
# streams are captured: success/failure reporting below speaks in user
# concepts, and the transaction machinery (journal ids, preflight
# internals) must not leak into the normal presentation.
update_tech(){
  if [[ -n "$UPDATE_LOG" ]]; then
    "$@" >>"$UPDATE_LOG" 2>&1
  else
    "$@"
  fi
}
# Show the captured technical log (failure/fallback paths only).
update_show_tech_log(){
  if [[ -n "$UPDATE_LOG" && -s "$UPDATE_LOG" ]]; then
    echo "  Technical detail:" >&2
    sed 's/^/    /' "$UPDATE_LOG" >&2
  fi
}

# --- Read-only state gates (no writes, not even the lock). ---
UPDATE_LOCK="$APPLY_SD/$DEPLOY_LOCK_NAME"
if [[ -f "$UPDATE_LOCK" ]]; then
  UPDATE_LPID=$(awk '{print $1}' "$UPDATE_LOCK" 2>/dev/null || echo "?")
  UPDATE_LID=$(awk '{print $2}' "$UPDATE_LOCK" 2>/dev/null || echo "?")
  if [[ "$UPDATE_LPID" =~ ^[0-9]+$ ]] && kill -0 "$UPDATE_LPID" 2>/dev/null; then
    echo -e "${STY_YELLOW}!${STY_RST} Update blocked: another update ($UPDATE_LID) is already running (pid $UPDATE_LPID)." >&2
    echo "  Wait for it to finish, then re-run: $0 update${UPDATE_SUFFIX}" >&2
    exit 2
  fi
  echo -e "${STY_YELLOW}!${STY_RST} Update blocked: a previous apply left its lock behind (holder $UPDATE_LPID is dead)." >&2
  echo "  Next step: check state with $0 adopt --status --state-dir $(printf '%q' "$APPLY_SD")" >&2
  echo "  An incomplete transaction still needs resume/abort first (see below); otherwise release only the lock with" >&2
  echo "    $0 apply --break-lock --state-dir $(printf '%q' "$APPLY_SD")" >&2
  exit 2
fi
UPDATE_OPEN=""
if [[ -d "$APPLY_SD/$DEPLOY_APPLIES_NAME" ]]; then
  # Guarded: no open journal reports rc 1, which must not trip `set -e`.
  UPDATE_OPEN=$(deploy_apply_open_journal "$APPLY_SD" 2>/dev/null) || true
fi
if [[ -n "$UPDATE_OPEN" ]]; then
  echo -e "${STY_YELLOW}!${STY_RST} Update blocked: incomplete transaction $UPDATE_OPEN exists; plain updates never touch it." >&2
  echo "  Next step (pick one):" >&2
  echo "    $0 apply --resume $UPDATE_OPEN --state-dir $(printf '%q' "$APPLY_SD")" >&2
  echo "    $0 apply --abort $UPDATE_OPEN --state-dir $(printf '%q' "$APPLY_SD")" >&2
  exit 2
fi
# Canonical state classification (read-only); refused states stop here.
UPDATE_STATUS_OUT=""
UPDATE_STATUS_RC=0
UPDATE_STATUS_OUT=$(deploy_status "$APPLY_SD" 2>&1) || UPDATE_STATUS_RC=$?
UPDATE_VERDICT=$(grep '^verdict: ' <<<"$UPDATE_STATUS_OUT" | tail -n 1 || true)
if (( UPDATE_STATUS_RC != 0 )); then
  case "$UPDATE_VERDICT" in
    'verdict: absent')
      echo -e "${STY_YELLOW}!${STY_RST} Update blocked: this machine is not adopted yet (no deployment state at $APPLY_SD)." >&2
      echo "  Next step: preview with $0 adopt${UPDATE_SUFFIX}" >&2
      echo "  then record with: $0 adopt --apply${UPDATE_SUFFIX}" >&2
      exit 2;;
    *)
      echo -e "${STY_RED}x${STY_RST} Update blocked: deployment state needs attention ($UPDATE_VERDICT)." >&2
      echo "  Next step: inspect with $0 adopt --status --state-dir $(printf '%q' "$APPLY_SD")" >&2
      exit 1;;
  esac
fi

# --- Shared gates: state, target, inputs, plan, decisions, preflight. ---
# Identical evaluation to every other caller; pure except for reads.
UPDATE_PREP_RC=0
update_tech deploy_apply_prepare_all || UPDATE_PREP_RC=$?
if (( UPDATE_PREP_RC == 1 )); then
  echo -e "${STY_RED}x${STY_RST} Update failed: could not evaluate the pending update." >&2
  update_show_tech_log
  exit 1
elif (( UPDATE_PREP_RC != 0 )); then
  if (( ${#APPLY_ERRORS[@]} > 0 )); then
    echo -e "${STY_YELLOW}!${STY_RST} Update blocked: the plan contains ${#APPLY_ERRORS[@]} error row(s); nothing was changed." >&2
    echo "  Next step: inspect with $0 plan${UPDATE_SUFFIX}" >&2
    echo "  Fix the underlying cause, then re-run: $0 update${UPDATE_SUFFIX}" >&2
    exit 2
  fi
  if (( ${#APPLY_SUBBLOCK[@]} > 0 )); then
    echo -e "${STY_YELLOW}!${STY_RST} Update blocked: ${#APPLY_SUBBLOCK[@]} submodule path(s) need manual attention; nothing was changed." >&2
    echo "  The updater never materializes submodules; resolve these checkouts by hand:" >&2
    UPDATE_ROW=""
    for UPDATE_ROW in "${APPLY_SUBBLOCK[@]}"; do
      UPDATE_S_OP="${UPDATE_ROW%%|*}"
      UPDATE_S_REST="${UPDATE_ROW#*|}"
      echo "    ${UPDATE_S_OP}  ${UPDATE_S_REST%%|*}" >&2
    done
    echo "  Details: $0 plan${UPDATE_SUFFIX} — then re-run: $0 update${UPDATE_SUFFIX}" >&2
    exit 2
  fi
  if (( ${#APPLY_UNDECIDED[@]} > 0 )); then
    echo -e "${STY_YELLOW}!${STY_RST} Update blocked: ${#APPLY_UNDECIDED[@]} path(s) need your decisions; nothing was changed." >&2
    UPDATE_ROW=""
    UPDATE_N=0
    for UPDATE_ROW in "${APPLY_UNDECIDED[@]}"; do
      UPDATE_N=$((UPDATE_N + 1))
      if (( UPDATE_N <= 12 )); then
        UPDATE_U_OP="${UPDATE_ROW%%|*}"
        UPDATE_U_REST="${UPDATE_ROW#*|}"
        UPDATE_U_PATH="${UPDATE_U_REST%%|*}"
        UPDATE_U_HINT="${UPDATE_U_REST#*|}"
        UPDATE_U_EXTRA=""
        if [[ "$UPDATE_U_HINT" == stale-decision-had-* ]]; then
          UPDATE_U_EXTRA=" (saved choice '${UPDATE_U_HINT#stale-decision-had-}' no longer matches — re-decide)"
        fi
        echo "    ${UPDATE_U_OP}  ${UPDATE_U_PATH}${UPDATE_U_EXTRA}" >&2
      fi
    done
    if (( ${#APPLY_UNDECIDED[@]} > 12 )); then
      echo "    ...and $(( ${#APPLY_UNDECIDED[@]} - 12 )) more (full list: $0 plan${UPDATE_SUFFIX})" >&2
    fi
    echo "  Next step: record choices with $0 decide --set PATH=CHOICE [--set ...]${UPDATE_SUFFIX}" >&2
    echo "  (each path's valid choices are listed by: $0 decide --help)" >&2
    echo "  One-shot alternative: $0 update --resolve PATH:CHOICE [...]${UPDATE_SUFFIX}" >&2
    echo "  Saved choices: $0 decide --list${UPDATE_SUFFIX}" >&2
    exit 2
  fi
  echo -e "${STY_YELLOW}!${STY_RST} Update blocked before any write (see above); nothing was changed." >&2
  update_show_tech_log
  exit 2
fi
if (( ${#APPLY_DEC_STALE[@]} > 0 )); then
  UPDATE_S=""
  for UPDATE_S in "${APPLY_DEC_STALE[@]}"; do echo "${STY_FAINT}note: saved choice no longer matches and was ignored: $UPDATE_S${STY_RST}"; done
fi

# --- Concise summary of the resolved operation set. ---
UPDATE_N_UPD=0 UPDATE_N_INS=0 UPDATE_N_DEL=0 UPDATE_N_SIDE=0 UPDATE_N_KEEP=0
UPDATE_SUM_ROW="" UPDATE_SUM_OP="" UPDATE_SUM_CLASS="" UPDATE_SUM_PATH=""
UPDATE_SUM_B="" UPDATE_SUM_D="" UPDATE_SUM_T="" UPDATE_SUM_L="" UPDATE_SUM_X=""
for ((UPDATE_SUM_I = 0; UPDATE_SUM_I < ${#DEPLOY_PLAN_ROWS[@]}; UPDATE_SUM_I++)); do
  UPDATE_SUM_ROW="${DEPLOY_PLAN_ROWS[$UPDATE_SUM_I]}"
  IFS=$'\t' read -r UPDATE_SUM_OP UPDATE_SUM_CLASS UPDATE_SUM_PATH UPDATE_SUM_B UPDATE_SUM_D UPDATE_SUM_T UPDATE_SUM_L UPDATE_SUM_X <<<"$UPDATE_SUM_ROW"
  [[ -z "$UPDATE_SUM_OP" ]] && continue
  UPDATE_SUM_CHOICE=""
  case "$UPDATE_SUM_OP" in
    conflict-drift|conflict-removed|delete-blocked|drift-unchanged|drift-update|drift-moved|drift-removed|missing-unchanged|add-evidence|appeared|class-changed|type-changed)
      UPDATE_SUM_CHOICE=$(deploy_apply_match_decision "$UPDATE_SUM_PATH" "$UPDATE_SUM_OP" "$UPDATE_SUM_L" "$UPDATE_SUM_T" "$UPDATE_SUM_B" "$(deploy_apply_row_kind "$UPDATE_SUM_PATH")");;
  esac
  # A sidecar-class write intent always lands as a .new delivery, never live.
  if [[ "$UPDATE_SUM_CLASS" == "sidecar" ]]; then
    case "$UPDATE_SUM_OP" in
      update|add) UPDATE_N_SIDE=$((UPDATE_N_SIDE + 1)); continue;;
      missing-unchanged|add-evidence|conflict-removed|drift-removed) [[ "$UPDATE_SUM_CHOICE" == "install" || "$UPDATE_SUM_CHOICE" == "reinstall" ]] && { UPDATE_N_SIDE=$((UPDATE_N_SIDE + 1)); continue; };;
      conflict-drift|drift-unchanged|drift-update|drift-moved|appeared|class-changed|type-changed) [[ "$UPDATE_SUM_CHOICE" == "replace" ]] && { UPDATE_N_SIDE=$((UPDATE_N_SIDE + 1)); continue; };;
    esac
  fi
  case "$UPDATE_SUM_OP" in
    update) UPDATE_N_UPD=$((UPDATE_N_UPD + 1));;
    add) UPDATE_N_INS=$((UPDATE_N_INS + 1));;
    delete-stale) UPDATE_N_DEL=$((UPDATE_N_DEL + 1));;
    sidecar-new) UPDATE_N_SIDE=$((UPDATE_N_SIDE + 1));;
    missing-unchanged|add-evidence)
      [[ "$UPDATE_SUM_CHOICE" == "install" ]] && UPDATE_N_INS=$((UPDATE_N_INS + 1));;
    conflict-removed|drift-removed)
      [[ "$UPDATE_SUM_CHOICE" == "reinstall" ]] && UPDATE_N_UPD=$((UPDATE_N_UPD + 1));;
    delete-blocked)
      [[ "$UPDATE_SUM_CHOICE" == "delete" ]] && UPDATE_N_DEL=$((UPDATE_N_DEL + 1));;
    conflict-drift|drift-unchanged|drift-update|drift-moved|appeared|class-changed|type-changed)
      case "$UPDATE_SUM_CHOICE" in
        replace) UPDATE_N_UPD=$((UPDATE_N_UPD + 1));;
        sidecar) UPDATE_N_SIDE=$((UPDATE_N_SIDE + 1));;
      esac;;
  esac
  case "$UPDATE_SUM_CHOICE" in
    keep|preserve-absence|accept-removal) UPDATE_N_KEEP=$((UPDATE_N_KEEP + 1));;
  esac
done
UPDATE_N_WRITE=$((UPDATE_N_UPD + UPDATE_N_INS + UPDATE_N_DEL + UPDATE_N_SIDE))
# User-facing "from" revision: the last successfully applied target when
# one is recorded, else the adoption baseline. Presentation only — the
# planner keeps reasoning from PLAN_BASE_REV, whose provenance meaning
# ("baselined against") is unchanged. Guarded: an unreadable identity
# falls back to the baseline instead of failing the summary.
UPDATE_FROM_REV="$PLAN_BASE_REV"
UPDATE_LAST_APPLIED=""
UPDATE_LAST_APPLIED=$(jq -r '.last_apply.target // empty' "$APPLY_SD/$DEPLOY_IDENTITY_NAME" 2>/dev/null || true)
if [[ -n "$UPDATE_LAST_APPLIED" ]]; then
  UPDATE_FROM_REV="$UPDATE_LAST_APPLIED"
fi
UPDATE_BASE_SHORT=$(git -C "$REPO_ROOT" rev-parse --short "$UPDATE_FROM_REV" 2>/dev/null || printf '%s' "${UPDATE_FROM_REV:0:7}")
UPDATE_TARGET_SHORT=$(git -C "$REPO_ROOT" rev-parse --short "$APPLY_TARGET" 2>/dev/null || printf '%s' "${APPLY_TARGET:0:7}")
UPDATE_KEEP_TXT=""
if (( UPDATE_N_KEEP > 0 )); then
  UPDATE_KEEP_TXT=" · ${UPDATE_N_KEEP} kept as-is by your decisions"
fi
echo -e "Updating ${UPDATE_BASE_SHORT} ${STY_FAINT}->${STY_RST} ${STY_BOLD}${UPDATE_TARGET_SHORT}${STY_RST}"
echo "${UPDATE_N_WRITE} files will change: ${UPDATE_N_UPD} updates, ${UPDATE_N_INS} new, ${UPDATE_N_DEL} deletions, ${UPDATE_N_SIDE} sidecars${UPDATE_KEEP_TXT}"

if (( UPDATE_N_WRITE == 0 )); then
  echo -e "${STY_GREEN}✓${STY_RST} Already up to date at ${UPDATE_TARGET_SHORT} — nothing to do"
  exit 0
fi
if [[ "${DEPLOY_UPDATE_DRYRUN}" == true ]]; then
  echo "dry run: showing the above without applying anything (nothing changed)"
  exit 0
fi

# --- Mutation path (the only writer; reached solely through shared gates). ---
echo "Applying..."
UPDATE_RUN_RC=0
update_tech deploy_apply_run_fresh || UPDATE_RUN_RC=$?
if (( UPDATE_RUN_RC != 0 )); then
  echo -e "${STY_RED}x${STY_RST} Update to ${UPDATE_TARGET_SHORT} failed — no further writes attempted." >&2
  echo "  Resume: $0 apply --resume ${APPLY_ID:-<id>} --state-dir $(printf '%q' "$APPLY_SD")" >&2
  echo "  Abort:  $0 apply --abort ${APPLY_ID:-<id>} --state-dir $(printf '%q' "$APPLY_SD")" >&2
  update_show_tech_log
  exit "$UPDATE_RUN_RC"
fi

# --- Post-apply verification (read-only). ---
UPDATE_VERIFY_RC=0
deploy_status "$APPLY_SD" >/dev/null 2>&1 || UPDATE_VERIFY_RC=$?
if (( UPDATE_VERIFY_RC != 0 )); then
  echo -e "${STY_RED}x${STY_RST} Update applied, but the resulting state does not verify." >&2
  echo "  Next step: inspect with $0 adopt --status before doing anything else" >&2
  exit 1
fi
UPDATE_DEPLOYED="?"
UPDATE_DEPLOYED=$(jq -r '.fully_deployed // "?"' "$APPLY_SD/$DEPLOY_IDENTITY_NAME" 2>/dev/null || echo "?")
echo -e "${STY_GREEN}✓${STY_RST} Updated to ${UPDATE_TARGET_SHORT} — ${UPDATE_N_WRITE} written, ${UPDATE_N_KEEP} kept · fully_deployed=${UPDATE_DEPLOYED}"
exit 0
