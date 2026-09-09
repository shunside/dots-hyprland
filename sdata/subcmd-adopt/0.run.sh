# This script is meant to be sourced by ./setup (subcommand: adopt).
# It's not for directly running.
#
# Adoption baseline. Default (and --dry-run) is read-only: prints the
# classifier TSV to stdout and a human summary to stderr, zero writes.
# --apply records the baseline durably (manifest + legacy evidence +
# identity, inside the resolved state dir only) and refuses while the
# classification is incomplete. --reconcile re-evaluates an already-adopted
# machine under the current registry/revision (same writes, same
# never-touch-deployed-files guarantee) while preserving adoption
# provenance; drifted/missing rows are re-observed, never laundered into
# confirmed. --status reads back recorded state.
# Exit codes: 0 completed/recorded/adoption-complete; 2 incomplete-or-absent state
# (status mode) or refused apply/reconcile; 1 hard error or corrupt state.

# shellcheck shell=bash

set -uo pipefail
# DEPLOY_LIB_DIR override exists solely so fixture tests can exercise the
# live worktree sources while REPO_ROOT points at a throwaway repo.
# Production always uses the default below.
DEPLOY_LIB_DIR="${DEPLOY_LIB_DIR:-${REPO_ROOT}/sdata/lib}"
source "${DEPLOY_LIB_DIR}/deploy-common.sh"
source "${DEPLOY_LIB_DIR}/deploy-state.sh"

# jq reads deployment state (status verification); fail closed first.
if ! deploy_require_jq; then
  exit 1
fi

DEPLOY_ORDER=(adoptable drifted missing sidecar-clean sidecar-drifted sidecar-missing preserved user-absent input-excluded unclassified submodule-present submodule-missing error)

# --- --status: pure readback, no comparison needed. ---
if [[ "${DEPLOY_WANT_STATUS}" == true ]]; then
  STATUS_SD="${DEPLOY_STATE_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/illogical-impulse}"
  deploy_status "$STATUS_SD"
  exit $?
fi

if [[ ! -d "${DEPLOY_HOME_DIR}" ]]; then
  echo "[$0]: --home is not a directory: ${DEPLOY_HOME_DIR}" >&2
  exit 1
fi

# Canonical home root; recorded in the identity so later stages can refuse
# to operate on a different root.
if ! DEPLOY_HOME=$(cd "${DEPLOY_HOME_DIR}" 2>/dev/null && pwd -P); then
  echo "[$0]: cannot resolve --home: ${DEPLOY_HOME_DIR}" >&2
  exit 1
fi
DEPLOY_SELF_HOME=$(cd "$HOME" 2>/dev/null && pwd -P || echo "$HOME")
if [[ "$DEPLOY_HOME" == "$DEPLOY_SELF_HOME" ]]; then
  # Own machine: honor the environment's XDG layout.
  DEPLOY_XDG_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
  DEPLOY_XDG_DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
else
  # Foreign root (fixtures, alternate machines): resolve XDG against it so
  # environment variables of this shell cannot redirect the comparison.
  DEPLOY_XDG_CONFIG="${DEPLOY_HOME}/.config"
  DEPLOY_XDG_DATA="${DEPLOY_HOME}/.local/share"
fi
export DEPLOY_HOME DEPLOY_XDG_CONFIG DEPLOY_XDG_DATA

if ! DEPLOY_SHA=$(deploy_resolve_revision "${DEPLOY_AT}"); then
  exit 1
fi
DEPLOY_ONELINE=$(git -C "$REPO_ROOT" log -1 --format='%h %s' "$DEPLOY_SHA" 2>/dev/null || echo "(no log)")

if ! deploy_load_registry "$DEPLOY_SHA"; then
  exit 1
fi

TSV=$(deploy_classify "$DEPLOY_SHA") || { echo "[$0]: classification failed" >&2; exit 1; }
printf '%s\n' "$TSV"

# Effective payload inputs (recorded in the identity, never SHA-alone).
if [[ "${INSTALL_VIA_NIX:-false}" == "true" ]]; then DEPLOY_EFF_VIANIX=true; else DEPLOY_EFF_VIANIX=false; fi
DEPLOY_EFF_FONTSET="${FONTSET_DIR_NAME:-}"

# Registry lint: structural completeness of the classification itself.
# (Assignment guarded: a failing lint must report, not trip `set -e` from setup.)
LINT_RC=0
LINT_OUT=$(deploy_lint_registry "$DEPLOY_SHA" 2>&1) || LINT_RC=$?

# Histogram over the captured TSV (no re-scan).
declare -A DEPLOY_COUNTS=()
while IFS=$'\t' read -r st _c _p _b _d _t _m; do
  case "$st" in \#*) continue;; esac
  DEPLOY_COUNTS[$st]=$(( ${DEPLOY_COUNTS[$st]:-0} + 1 ))
done <<<"$TSV"

# Legacy evidence preview (read-only; reused verbatim by --apply).
LEGACY_SRC="${DEPLOY_XDG_CONFIG}/illogical-impulse/installed_listfile"
EVIDENCE=$(deploy_import_legacy "$LEGACY_SRC" 2>/dev/null || true)
EV_COUNT=$(deploy_content_lines "$EVIDENCE")

# State destination (pure resolution; no writes here).
if STATE_DIR=$(deploy_state_dir_resolve "$DEPLOY_HOME" "${DEPLOY_STATE_DIR:-}" 2>/dev/null); then
  STATE_NOTE="$STATE_DIR"
else
  STATE_NOTE="(foreign home — pass --state-dir explicitly to enable --apply)"
  STATE_DIR=""
fi

counts_json(){
  local s first=true out=""
  for s in "${DEPLOY_ORDER[@]}"; do
    if [[ "$first" == true ]]; then first=false; else out+=","; fi
    out+="\"$s\": ${DEPLOY_COUNTS[$s]:-0}"
  done
  printf '{%s}' "$out"
}

print_sections(){
  local section n
  for section in drifted missing sidecar-drifted sidecar-missing sidecar-clean input-excluded unclassified submodule-present submodule-missing error; do
    n=${DEPLOY_COUNTS[$section]:-0}
    if (( n > 0 )); then
      echo "  --- ${section} (${n}) ---"
      while IFS=$'\t' read -r state _class path blob disk detail _mode; do
        if [[ "$state" == "$section" ]]; then
          printf '    %s  [blob %s] [disk %s] %s\n' "$path" "${blob:0:12}" "${disk:0:12}" "$detail"
        fi
      done <<<"$TSV"
    fi
  done
  if (( ${DEPLOY_COUNTS[preserved]:-0} > 0 )); then
    echo "  --- preserved user-managed (${DEPLOY_COUNTS[preserved]}) left alone ---"
    while IFS=$'\t' read -r state _class path _b _d _t _m; do
      if [[ "$state" == "preserved" ]]; then
        echo "    $path"
      fi
    done <<<"$TSV"
  fi
}

# --- Dry-run (default): report only. ---
if [[ "${DEPLOY_WANT_APPLY}" != true && "${DEPLOY_WANT_RECONCILE:-false}" != true ]]; then
  {
  echo "[$0]: adoption dry-run (zero writes performed)"
  echo "  target:   ${DEPLOY_SHA} (${DEPLOY_ONELINE})"
  echo "  specced:  ${DEPLOY_AT}"
  echo "  home:     ${DEPLOY_HOME} (config=${DEPLOY_XDG_CONFIG})"
  echo "  inputs:   fontset=${DEPLOY_EFF_FONTSET:-(default)} via_nix=${DEPLOY_EFF_VIANIX}"
  echo "  registry: ${#DEPLOY_R_SRC[@]} rules from ${DEPLOY_REGISTRY_PATH}@${DEPLOY_SHA:0:12}"
  if [[ -n "${DEPLOY_FONTSET_NOTE}" ]]; then echo "  swap:     ${DEPLOY_FONTSET_NOTE}"; fi
  if [[ -n "${DEPLOY_VIANIX_NOTE}" ]]; then echo "  swap:     ${DEPLOY_VIANIX_NOTE}"; fi
  if [[ "$LINT_RC" == 0 ]]; then
    echo "  lint:     clean (every rule matches payload, no duplicates)"
  else
    echo "  lint:     PROBLEMS (would refuse --apply):"
    while IFS= read -r l; do echo "    $l"; done <<<"$LINT_OUT"
  fi
  echo "  states:"
  for s in "${DEPLOY_ORDER[@]}"; do
    printf '    %-17s %s\n' "$s" "${DEPLOY_COUNTS[$s]:-0}"
  done
  print_sections
  echo "  legacy:   ${EV_COUNT} evidence records previewed from ${LEGACY_SRC}"
  echo "  state:    ${STATE_NOTE}"
  if (( ${DEPLOY_COUNTS[unclassified]:-0} > 0 || ${DEPLOY_COUNTS[error]:-0} > 0 )) || [[ "$LINT_RC" != 0 ]]; then
    echo "  --apply would REFUSE: classification incomplete (no override flag by design)"
  else
    echo "  --apply would record ${DEPLOY_COUNTS[adoptable]:-0} confirmed + $(( ${DEPLOY_COUNTS[drifted]:-0} + ${DEPLOY_COUNTS[sidecar-drifted]:-0} )) drifted + $(( ${DEPLOY_COUNTS[missing]:-0} + ${DEPLOY_COUNTS[sidecar-missing]:-0} )) missing as unresolved state"
  fi
  echo "  adoptable/confirmed: live content matches baseline, may become confirmed records"
  echo "  drifted/missing: unresolved adoption state, never implies prior deployment"
  } >&2
  exit 0
fi

# --- --apply/--reconcile: fail closed BEFORE any write (not even mkdir). ---
{
if [[ "${DEPLOY_WANT_RECONCILE:-false}" == true ]]; then
  echo "[$0]: adoption reconciliation requested (re-evaluate under current registry; deployed/user files untouched)"
else
  echo "[$0]: adoption apply requested"
fi
if (( ${DEPLOY_COUNTS[unclassified]:-0} > 0 )); then
  echo "[$0]: REFUSED: ${DEPLOY_COUNTS[unclassified]} unclassified payload paths (see TSV); classify them in the registry first" >&2
  exit 2
fi
if (( ${DEPLOY_COUNTS[error]:-0} > 0 )); then
  echo "[$0]: REFUSED: ${DEPLOY_COUNTS[error]} classification errors (see TSV)" >&2
  exit 2
fi
if [[ "$LINT_RC" != 0 ]]; then
  echo "[$0]: REFUSED: registry lint problems:" >&2
  while IFS= read -r l; do echo "  $l" >&2; done <<<"$LINT_OUT"
  exit 2
fi
if [[ -z "$STATE_DIR" ]]; then
  echo "[$0]: REFUSED: cannot resolve a safe state destination for this home" >&2
  deploy_state_dir_resolve "$DEPLOY_HOME" "${DEPLOY_STATE_DIR:-}" >&2 || true
  exit 2
fi
} >&2

# Reconciliation provenance (only read when --reconcile was asked).
RECON_ADOPTED_AT=""
RECON_FROM_REV=""
RECON_DEPLOYED_LINE=""
RECON_LASTAPPLY_FRAG=""

if [[ "${DEPLOY_WANT_RECONCILE:-false}" == true ]]; then
  # An open or crashed transaction owns live+metadata truth right now;
  # re-baselining underneath it would strand snapshots and poison resume.
  # Any lock file refuses first: --break-lock releases the mutex only, and
  # resume/abort still govern afterwards.
  if [[ -f "$STATE_DIR/apply.lock" ]]; then
    echo "[$0]: REFUSED: lock present in $STATE_DIR; break it only when dead (--break-lock), then resume/abort any open transaction before reconciling" >&2
    exit 2
  fi
  # Guarded assignment: non-zero status must reach the branches below, not
  # trip `set -e` inherited from setup.
  RECON_STATUS_RC=0
  deploy_status "$STATE_DIR" >/dev/null 2>&1 || RECON_STATUS_RC=$?
  if [[ "$RECON_STATUS_RC" == 1 ]]; then
    echo "[$0]: REFUSED: existing state is corrupt; inspect manually before reconciling:" >&2
    deploy_status "$STATE_DIR" >&2 || true
    exit 1
  fi
  if [[ "$RECON_STATUS_RC" != 0 ]]; then
    echo "[$0]: REFUSED: --reconcile needs complete adoption state (nothing to re-evaluate; use --apply for a fresh adoption):" >&2
    deploy_status "$STATE_DIR" >&2 || true
    exit 2
  fi
  # Preserve adoption provenance; the new baseline observes live state
  # afresh but must not invent deployment history.
  RECON_ID="$STATE_DIR/$DEPLOY_IDENTITY_NAME"
  RECON_ADOPTED_AT=$(jq -r '.adopted_at // empty' "$RECON_ID" 2>/dev/null || true)
  RECON_FROM_REV=$(jq -r '.revision // empty' "$RECON_ID" 2>/dev/null || true)
  if [[ -z "$RECON_ADOPTED_AT" || -z "$RECON_FROM_REV" ]]; then
    echo "[$0]: REFUSED: existing identity lacks adoption provenance (adopted_at/revision); manual recovery needed" >&2
    exit 1
  fi
  RECON_DEPLOYED_JSON=$(jq -c '.deployed_revision // null' "$RECON_ID" 2>/dev/null || echo "null")
  RECON_LASTAPPLY_JSON=$(jq -c '.last_apply // null' "$RECON_ID" 2>/dev/null || echo "null")
  if [[ "$RECON_DEPLOYED_JSON" != "null" ]]; then
    printf -v RECON_DEPLOYED_LINE '  "deployed_revision": %s,\n' "$RECON_DEPLOYED_JSON"
  fi
  if [[ "$RECON_LASTAPPLY_JSON" != "null" ]]; then
    RECON_LASTAPPLY_FRAG=$',\n  "last_apply": '"${RECON_LASTAPPLY_JSON}"
  fi
else
  # Existing state decides whether publication may proceed: absent/incomplete
  # may be (over)written; complete or corrupt must never be clobbered here.
  # (Guarded assignment: `absent` reports rc 2, which must not trip `set -e`.)
  STATUS_RC=0
  STATUS_PRE=$(deploy_status "$STATE_DIR" 2>/dev/null) || STATUS_RC=$?
  if [[ "$STATUS_RC" == 0 ]]; then
    echo "[$0]: REFUSED: complete adoption already recorded at $STATE_DIR (use --reconcile to re-evaluate under the current registry)" >&2
    exit 2
  fi
  if [[ "$STATUS_RC" == 1 ]]; then
    echo "[$0]: REFUSED: existing state is corrupt; inspect manually before re-adopting:" >&2
    deploy_status "$STATE_DIR" >&2 || true
    exit 2
  fi
fi

if ! mkdir -p "$STATE_DIR"; then
  echo "[$0]: cannot create state dir: $STATE_DIR" >&2
  exit 1
fi

MANIFEST=$(deploy_manifest_build "$TSV" "$DEPLOY_SHA") || { echo "[$0]: manifest build failed" >&2; exit 1; }
MF_COUNT=$(deploy_content_lines "$MANIFEST")
MF_SHA=$(deploy_bytes_sha "$MANIFEST")
EV_COUNT_CHECK=$(deploy_content_lines "$EVIDENCE")
if [[ "$EV_COUNT" != "$EV_COUNT_CHECK" ]]; then
  echo "[$0]: internal error: evidence count drift" >&2
  exit 1
fi
if [[ "${DEPLOY_EFF_VIANIX}" == true ]]; then VIANIX_JSON="true"; else VIANIX_JSON="false"; fi
if [[ -n "$DEPLOY_EFF_FONTSET" ]]; then FONTSET_JSON="\"$(deploy_json_escape "$DEPLOY_EFF_FONTSET")\""; else FONTSET_JSON="null"; fi
# Reconciliation keeps the original adoption moment and any deployment
# history the updater itself previously proved; only fresh observation
# (manifest/counts/fully_deployed) is re-derived. Fresh adoption mints them.
if [[ "${DEPLOY_WANT_RECONCILE:-false}" == true ]]; then
  RECON_TOOL="setup adopt --reconcile"
  RECON_STAMP="  \"adopted_at\": \"${RECON_ADOPTED_AT}\",\n  \"reconciled_from\": \"${RECON_FROM_REV}\",\n  \"reconciled_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
else
  RECON_TOOL="setup adopt"
  RECON_STAMP="  \"adopted_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
fi
# fully_deployed is the ONLY field that may ever be read as "revision X is
# completely deployed and verified on this machine". `revision` alone means
# "baselined against X". Any unresolved row (drifted/missing content or a
# missing submodule) forces false; future plan/apply code must honor this.
# Re-observing live state can therefore never launder drifted/missing rows
# into deployed ones: the mapping below is the same one fresh adoption uses.
UNRESOLVED=$(( ${DEPLOY_COUNTS[drifted]:-0} + ${DEPLOY_COUNTS[sidecar-drifted]:-0} + ${DEPLOY_COUNTS[missing]:-0} + ${DEPLOY_COUNTS[sidecar-missing]:-0} + ${DEPLOY_COUNTS[submodule-missing]:-0} ))
if (( UNRESOLVED == 0 )); then FULLY_JSON="true"; else FULLY_JSON="false"; fi
IDENTITY=$(cat <<EOF
{
  "schema": ${DEPLOY_SCHEMA},
  "status": "adopted",
  "fully_deployed": ${FULLY_JSON},
  "revision": "${DEPLOY_SHA}",
${RECON_DEPLOYED_LINE}  "fontset": ${FONTSET_JSON},
  "via_nix": ${VIANIX_JSON},
  "home_root": "$(deploy_json_escape "$DEPLOY_HOME")",
  "xdg_config": "$(deploy_json_escape "$DEPLOY_XDG_CONFIG")",
$(printf '%b' "$RECON_STAMP")
  "tool": "${RECON_TOOL}",
  "manifest": "${DEPLOY_MANIFEST_NAME}",
  "manifest_sha256": "${MF_SHA}",
  "manifest_records": ${MF_COUNT},
  "legacy_evidence": "${DEPLOY_EVIDENCE_NAME}",
  "legacy_evidence_records": ${EV_COUNT},
  "counts": $(counts_json)${RECON_LASTAPPLY_FRAG}
}
EOF
)

if ! deploy_atomic_publish "$STATE_DIR" "$MANIFEST" "$EVIDENCE" "$IDENTITY"; then
  echo "[$0]: adoption publication failed (see above); no valid identity exists" >&2
  exit 1
fi

{
echo "[$0]: adoption recorded"
echo "  state:    $STATE_DIR"
echo "  revision: ${DEPLOY_SHA} (${DEPLOY_ONELINE})"
echo "  inputs:   fontset=${DEPLOY_EFF_FONTSET:-(default)} via_nix=${DEPLOY_EFF_VIANIX}"
echo "  manifest: ${MF_COUNT} records (sha256 ${MF_SHA:0:16}…)"
echo "  legacy:   ${EV_COUNT} weak-evidence records (hashless, approval-only downstream)"
echo "  confirmed(adoptable+sidecar-clean): $(( ${DEPLOY_COUNTS[adoptable]:-0} + ${DEPLOY_COUNTS[sidecar-clean]:-0} ))"
echo "  unresolved drift: $(( ${DEPLOY_COUNTS[drifted]:-0} + ${DEPLOY_COUNTS[sidecar-drifted]:-0} )), unresolved missing: $(( ${DEPLOY_COUNTS[missing]:-0} + ${DEPLOY_COUNTS[sidecar-missing]:-0} ))"
if (( UNRESOLVED == 0 )); then
  echo "  fully_deployed: true (revision is completely deployed and verified here)"
else
  echo "  fully_deployed: false (baselined only; ${UNRESOLVED} unresolved rows must never read as deployed)"
fi
echo "  submodule: present=${DEPLOY_COUNTS[submodule-present]:-0} missing=${DEPLOY_COUNTS[submodule-missing]:-0} (informational, never gates)"
} >&2
exit 0
