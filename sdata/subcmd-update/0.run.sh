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
source "${DEPLOY_LIB_DIR}/terminal-spin.sh"
source "${DEPLOY_LIB_DIR}/setup-launcher.sh"

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
# UPDATE_PIN_SUFFIX additionally pins the discovered target commit for
# commands that must evaluate the identical rows (plan, decide --set).
# A handoff run inherits its target (and the plain suffix) from the
# outer run instead of re-resolving, so --at echo-back stays deduplicated.
UPDATE_SUFFIX=""
if [[ "${DEPLOY_UPDATE_AT_GIVEN:-false}" == true && "${UPDATE_HANDED_OFF:-false}" != true ]]; then
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
  trap "term_spin_stop || true; rm -f '$UPDATE_LOG'" EXIT
fi
# Activity stages show only on interactive terminals (see terminal-spin);
# verbose mode streams the raw technical report instead.
update_stage(){
  if [[ "${DEPLOY_UPDATE_VERBOSE:-false}" != true ]]; then
    term_spin_start "$1"
  fi
}
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
    sed 's/^/    /' "$UPDATE_LOG" >&2 || true
  fi
  return 0
}

# Checkpoint: live payload fully evaluated against APPLY_TARGET (applied
# and verified, or cleanly noop). Identity-only, journal and manifest
# untouched; gives the next run an honest base instead of stale apply
# provenance. Never reached by dry runs, refusals, or failures. Atomic
# rewrite; concurrent runs converge on the same value.
update_record_verified(){
  [[ -n "${APPLY_TARGET:-}" ]] || return 0
  local ident tmp now
  ident="$APPLY_SD/$DEPLOY_IDENTITY_NAME"
  [[ -f "$ident" ]] || return 0
  now="$(date -u +%FT%TZ 2>/dev/null || date 2>/dev/null || true)"
  tmp="$(mktemp "${TMPDIR:-/tmp}/setup-verified-XXXXXX.json" 2>/dev/null)" || return 0
  if jq --arg t "$APPLY_TARGET" --arg ts "$now" \
       '.last_verified = {target: $t, at: $ts}' "$ident" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$ident" 2>/dev/null || rm -f "$tmp" || true
  else
    rm -f "$tmp" || true
  fi
  return 0
}

# Advance the checkout branch to the fetched target when safe: default
# discovery flow only (never explicit --at, never dry run), on a branch
# (never detached), tracking exactly the ref just fetched, and only from
# a remote (never a local branch). git's own fast-forward rules decide:
# dirty/diverged/local-ahead trees refuse by themselves and fall back to
# handoff behavior. Reports only an actual pointer change.
update_advance_checkout(){
  [[ "${DEPLOY_UPDATE_AT_GIVEN:-false}" == true ]] && return 0
  [[ "${DEPLOY_UPDATE_DRYRUN:-false}" == true ]] && return 0
  [[ -z "${UPDATE_DISCOVERED_FROM:-}" || "$UPDATE_DISCOVERED_FROM" == local* ]] && return 0
  [[ -z "${UPDATE_REMOTE:-}" || -z "${UPDATE_BRANCH:-}" ]] && return 0
  git -C "$REPO_ROOT" symbolic-ref -q HEAD >/dev/null 2>&1 || return 0
  local up
  up="$(git -C "$REPO_ROOT" rev-parse --symbolic-full-name "@{u}" 2>/dev/null || true)"
  [[ "$up" == "refs/remotes/$UPDATE_REMOTE/$UPDATE_BRANCH" ]] || return 0
  local before after
  before="$(git -C "$REPO_ROOT" rev-parse --verify HEAD^{commit} 2>/dev/null || true)"
  git -C "$REPO_ROOT" merge --ff-only --quiet "$UPDATE_REMOTE/$UPDATE_BRANCH" 2>/dev/null || return 0
  after="$(git -C "$REPO_ROOT" rev-parse --verify HEAD^{commit} 2>/dev/null || true)"
  if [[ -n "$before" && -n "$after" && "$before" != "$after" ]]; then
    local bs as
    bs="$(git -C "$REPO_ROOT" rev-parse --short "$before" 2>/dev/null || printf '%s' "${before:0:7}")"
    as="$(git -C "$REPO_ROOT" rev-parse --short "$after" 2>/dev/null || printf '%s' "${after:0:7}")"
    echo "Advanced checkout ${bs} -> ${as}"
  fi
  return 0
}

# Evaluation scope header shared by every non-steady shape: which payload
# window is being reconciled with which target, plus divergence context.
update_scope_head(){
  echo -e "Updating payload ${UPDATE_BASE_SHORT} ${STY_FAINT}->${STY_RST} ${STY_BOLD}${UPDATE_TARGET_SHORT}${STY_RST}${UPDATE_TARGET_WHENCE:-}"
  # Local-only commits never ride along implicitly: name them instead.
  if [[ -n "${UPDATE_DISCOVERED_FROM:-}" && "$UPDATE_DISCOVERED_FROM" != local* ]]; then
    UPDATE_AHEAD=0
    UPDATE_AHEAD=$(git -C "$REPO_ROOT" rev-list --count "$APPLY_TARGET..HEAD" 2>/dev/null || echo 0)
    if [[ "$UPDATE_AHEAD" =~ ^[0-9]+$ ]] && (( UPDATE_AHEAD > 0 )); then
      echo -e "${STY_FAINT}note: local branch holds $UPDATE_AHEAD commit(s) not on $UPDATE_DISCOVERED_FROM; deploying the remote tip, local work untouched.${STY_RST}"
    fi
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

# --- Target discovery (read-only network at most; never touches home/state).
# Bare `update` means "bring this machine to the latest normal revision
# of its configured fork": resolve the current branch's tracking branch,
# fetch it (remote-tracking refs only — the working branch, index, and
# worktree are never modified), and pin the fetched commit before any
# gate runs, so later remote movement cannot change the target mid-run.
# An explicit --at keeps the historical fully-local behavior and never
# fetches. plan/decide/apply are untouched and stay local-only.
# Discovery context survives handoff: the inner run inherits these from
# the outer run's environment rather than re-resolving, so its summary
# and divergence reporting describe the same pinned target.
UPDATE_DISCOVERED_FROM="${UPDATE_DISCOVERED_FROM:-}"
UPDATE_TARGET_WHENCE="${UPDATE_TARGET_WHENCE:-}"
UPDATE_FETCH_MOVED="${UPDATE_FETCH_MOVED:-false}"
UPDATE_PIN_SUFFIX="$UPDATE_SUFFIX"
if [[ "${UPDATE_HANDED_OFF:-false}" == true ]]; then
  # Handoff runs arrive with an explicitly pinned target but must still
  # point inspection guidance (plan, decide --set) at those identical
  # rows. Re-running update itself stays unpinned to re-discover.
  UPDATE_PIN_SUFFIX+=" --at ${DEPLOY_AT:-HEAD}"
fi
update_stage "Checking for updates"
if [[ "${DEPLOY_UPDATE_AT_GIVEN:-false}" != true ]]; then
  UPDATE_UPSTREAM=""
  UPDATE_UPSTREAM=$(git -C "$REPO_ROOT" rev-parse --symbolic-full-name "@{u}" 2>/dev/null || true)
  if [[ "$UPDATE_UPSTREAM" == refs/remotes/* ]]; then
    UPDATE_TRACK="${UPDATE_UPSTREAM#refs/remotes/}"
    UPDATE_REMOTE=""
    UPDATE_BRANCH=""
    while IFS= read -r UPDATE_R; do
      [[ -z "$UPDATE_R" ]] && continue
      case "$UPDATE_TRACK" in
        "$UPDATE_R"/*) UPDATE_REMOTE="$UPDATE_R"; UPDATE_BRANCH="${UPDATE_TRACK:$((${#UPDATE_R} + 1))}"; break;;
      esac
    done < <(git -C "$REPO_ROOT" remote 2>/dev/null || true)
    if [[ -z "$UPDATE_REMOTE" || -z "$UPDATE_BRANCH" ]]; then
      term_spin_stop || true
      echo -e "${STY_FAINT}note: tracking ref $UPDATE_UPSTREAM matches no configured remote; using the local checkout.${STY_RST}"
    else
      UPDATE_FETCH_ERR=""
      # Record the ref before fetching: a moved tracking ref is repository
      # state this run advanced, and the summary reports it as such.
      UPDATE_FETCH_BEFORE=""
      UPDATE_FETCH_BEFORE=$(git -C "$REPO_ROOT" rev-parse --verify "$UPDATE_REMOTE/$UPDATE_BRANCH^{commit}" 2>/dev/null || true)
      if ! UPDATE_FETCH_ERR=$(git -C "$REPO_ROOT" fetch --quiet -- "$UPDATE_REMOTE" "$UPDATE_BRANCH" 2>&1); then
        echo -e "${STY_RED}x${STY_RST} Update failed: could not fetch $UPDATE_REMOTE/$UPDATE_BRANCH." >&2
        if [[ -n "$UPDATE_FETCH_ERR" ]]; then
          echo "  $(head -n 1 <<<"$UPDATE_FETCH_ERR")" >&2
        fi
        echo "  Check the network or remote access, then re-run: $0 update${UPDATE_SUFFIX}" >&2
        echo "  For a fully local deploy of the current checkout: $0 update --at HEAD${UPDATE_SUFFIX}" >&2
        term_spin_stop || true
        exit 1
      fi
      UPDATE_RESOLVED=""
      UPDATE_RESOLVED=$(git -C "$REPO_ROOT" rev-parse --verify "$UPDATE_REMOTE/$UPDATE_BRANCH^{commit}" 2>/dev/null || true)
      if [[ ! "$UPDATE_RESOLVED" =~ ^[0-9a-f]{40}$ ]]; then
        echo -e "${STY_RED}x${STY_RST} Update failed: remote tracking ref $UPDATE_REMOTE/$UPDATE_BRANCH did not resolve after fetching." >&2
        term_spin_stop || true
        exit 1
      fi
      DEPLOY_AT="$UPDATE_RESOLVED"
      UPDATE_DISCOVERED_FROM="$UPDATE_REMOTE/$UPDATE_BRANCH"
      UPDATE_TARGET_WHENCE=" (latest on $UPDATE_REMOTE/$UPDATE_BRANCH)"
      UPDATE_PIN_SUFFIX+=" --at $UPDATE_RESOLVED"
      if [[ "$UPDATE_FETCH_BEFORE" =~ ^[0-9a-f]{40}$ && "$UPDATE_FETCH_BEFORE" != "$UPDATE_RESOLVED" ]]; then
        UPDATE_FETCH_BEFORE_SHORT=$(git -C "$REPO_ROOT" rev-parse --short "$UPDATE_FETCH_BEFORE" 2>/dev/null || printf '%s' "${UPDATE_FETCH_BEFORE:0:7}")
        UPDATE_FETCH_AFTER_SHORT=$(git -C "$REPO_ROOT" rev-parse --short "$UPDATE_RESOLVED" 2>/dev/null || printf '%s' "${UPDATE_RESOLVED:0:7}")
        echo -e "${STY_FAINT}note: fetched $UPDATE_REMOTE/$UPDATE_BRANCH ${UPDATE_FETCH_BEFORE_SHORT} -> ${UPDATE_FETCH_AFTER_SHORT}${STY_RST}"
        UPDATE_FETCH_MOVED=true
      fi
    fi
  elif [[ "$UPDATE_UPSTREAM" == refs/heads/* ]]; then
    UPDATE_LOCAL_TRACK="${UPDATE_UPSTREAM#refs/heads/}"
    UPDATE_RESOLVED=""
    UPDATE_RESOLVED=$(git -C "$REPO_ROOT" rev-parse --verify "${UPDATE_UPSTREAM}^{commit}" 2>/dev/null || true)
    if [[ ! "$UPDATE_RESOLVED" =~ ^[0-9a-f]{40}$ ]]; then
      echo -e "${STY_RED}x${STY_RST} Update failed: tracked local branch $UPDATE_LOCAL_TRACK did not resolve." >&2
      term_spin_stop || true
      exit 1
    fi
    DEPLOY_AT="$UPDATE_RESOLVED"
    UPDATE_DISCOVERED_FROM="local $UPDATE_LOCAL_TRACK"
    UPDATE_PIN_SUFFIX+=" --at $UPDATE_RESOLVED"
    term_spin_stop || true
    echo -e "${STY_FAINT}note: tracking local branch $UPDATE_LOCAL_TRACK (no remote involved).${STY_RST}"
  else
    term_spin_stop || true
    echo -e "${STY_FAINT}note: no remote tracking branch configured; using the local checkout. Pass --at explicitly to pin a revision, or set an upstream to track the fork.${STY_RST}"
  fi
fi

term_spin_stop || true

# --- Self-update handoff: run the target revision's updater, not ours.
# A checkout older than the target would otherwise execute stale
# deployment/CLI logic against new payload (and never pick up updater
# fixes at all). When the pinned target differs from the running
# checkout, materialize the target's updater implementation with
# read-only object-store reads into a temp dir — working branch, index,
# and worktree are never touched — and continue inside it as a subshell.
# The inner run sees an explicit --at pin, so it never re-discovers and
# can never hand off again. Cleanup runs here afterwards because the
# inner run exits its subshell, never this shell.
if [[ "${DEPLOY_UPDATE_AT_GIVEN:-false}" != true && -n "${UPDATE_DISCOVERED_FROM:-}" ]]; then
  UPDATE_LOCAL_HEAD=""
  UPDATE_LOCAL_HEAD=$(git -C "$REPO_ROOT" rev-parse --verify HEAD^{commit} 2>/dev/null || true)
  if [[ "$DEPLOY_AT" != "$UPDATE_LOCAL_HEAD" || -z "$UPDATE_LOCAL_HEAD" ]]; then
    UPDATE_HANDOFF_DIR=""
    UPDATE_HANDOFF_DIR="$(mktemp -d "${TMPDIR:-/tmp}/setup-update-handoff-XXXXXX" 2>/dev/null)" || {
      echo -e "${STY_RED}x${STY_RST} Update failed: cannot stage the target updater implementation." >&2
      exit 1
    }
    UPDATE_HANDOFF_OK=false
    if git -C "$REPO_ROOT" archive "$DEPLOY_AT" sdata/lib sdata/subcmd-update 2>/dev/null | tar -x -C "$UPDATE_HANDOFF_DIR" 2>/dev/null; then
      if [[ -f "$UPDATE_HANDOFF_DIR/sdata/subcmd-update/0.run.sh" ]] && bash -n "$UPDATE_HANDOFF_DIR/sdata/subcmd-update/0.run.sh" 2>/dev/null; then
        UPDATE_HANDOFF_OK=true
      fi
    fi
    if [[ "$UPDATE_HANDOFF_OK" != true ]]; then
      rm -rf "$UPDATE_HANDOFF_DIR" || true
      echo -e "${STY_RED}x${STY_RST} Update failed: target $DEPLOY_AT has no runnable updater implementation." >&2
      echo "  Deploy it explicitly with the local logic instead: $0 update --at $DEPLOY_AT${UPDATE_SUFFIX}" >&2
      exit 1
    fi
    UPDATE_HANDOFF_RC=0
    # Visible delegation: the implementation running from here on is the
    # target's, not the checkout's. Without this line a stale checkout
    # would print a summary that hides whose logic evaluated it.
    UPDATE_HANDOFF_SHORT=$(git -C "$REPO_ROOT" rev-parse --short "$UPDATE_RESOLVED" 2>/dev/null || printf '%s' "${UPDATE_RESOLVED:0:7}")
    UPDATE_HEAD_SHORT=""
    if [[ -n "$UPDATE_LOCAL_HEAD" ]]; then
      UPDATE_HEAD_SHORT=$(git -C "$REPO_ROOT" rev-parse --short "$UPDATE_LOCAL_HEAD" 2>/dev/null || printf '%s' "${UPDATE_LOCAL_HEAD:0:7}")
    else
      UPDATE_HEAD_SHORT="unknown"
    fi
    echo "Handed off to updater ${UPDATE_HANDOFF_SHORT} (checkout ${UPDATE_HEAD_SHORT} evaluated as-is)"
    (
      # Pin the full driver contract explicitly: the inner runner belongs
      # to another revision and may expect variables this runner never
      # set (or vice versa). Defaults mirror options.sh so version skew
      # in either direction degrades to documented behavior, never to
      # unbound-variable aborts. The target is pinned, never re-resolved.
      # UPDATE_HANDED_OFF marks this as a handoff (not a user --at) so
      # echo-back suffixes don't duplicate the pin.
      # Keep this contract in sync with sdata/lib/update-bridge.sh, which
      # pins the same variables for pre-handoff checkouts.
      DEPLOY_AT="$UPDATE_RESOLVED"
      UPDATE_HANDED_OFF=true
      DEPLOY_HOME_DIR="${DEPLOY_HOME_DIR:-$HOME}"
      DEPLOY_STATE_DIR="${DEPLOY_STATE_DIR:-}"
      DEPLOY_APPLY_FONTSET="${DEPLOY_APPLY_FONTSET:-}"
      DEPLOY_APPLY_FONTSET_SET="${DEPLOY_APPLY_FONTSET_SET:-false}"
      DEPLOY_APPLY_VIANIX_SET="${DEPLOY_APPLY_VIANIX_SET:-false}"
      DEPLOY_UPDATE_DRYRUN="${DEPLOY_UPDATE_DRYRUN:-false}"
      DEPLOY_UPDATE_VERBOSE="${DEPLOY_UPDATE_VERBOSE:-false}"
      DEPLOY_UPDATE_AT_GIVEN=true
      DEPLOY_LIB_DIR="$UPDATE_HANDOFF_DIR/sdata/lib"
      if ! declare -p APPLY_RESOLVE >/dev/null 2>&1; then declare -a APPLY_RESOLVE=(); fi
      # shellcheck disable=SC1091
      source "$UPDATE_HANDOFF_DIR/sdata/subcmd-update/0.run.sh"
    ) || UPDATE_HANDOFF_RC=$?
    rm -rf "$UPDATE_HANDOFF_DIR" || true
    # The inner run evaluated, deployed, verified, recorded, and ensured
    # on its own; the outer run only maintains the checkout itself, on
    # success, with the discovery context gathered above.
    if (( UPDATE_HANDOFF_RC == 0 )); then
      update_advance_checkout || true
    fi
    exit "$UPDATE_HANDOFF_RC"
  fi
fi
# --- End self-update handoff. ---

# --- Shared gates: state, target, inputs, plan, decisions, preflight. ---
# Identical evaluation to every other caller; pure except for reads.
update_stage "Evaluating update"
UPDATE_PREP_RC=0
update_tech deploy_apply_prepare_all || UPDATE_PREP_RC=$?
term_spin_stop || true
if (( UPDATE_PREP_RC == 1 )); then
  echo -e "${STY_RED}x${STY_RST} Update failed: could not evaluate the pending update." >&2
  update_show_tech_log
  exit 1
elif (( UPDATE_PREP_RC != 0 )); then
  if (( ${#APPLY_ERRORS[@]} > 0 )); then
    echo -e "${STY_YELLOW}!${STY_RST} Update blocked: the plan contains ${#APPLY_ERRORS[@]} error row(s); nothing was changed." >&2
    echo "  Next step: inspect with $0 plan${UPDATE_PIN_SUFFIX}" >&2
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
    echo "  Details: $0 plan${UPDATE_PIN_SUFFIX} — then re-run: $0 update${UPDATE_SUFFIX}" >&2
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
      echo "    ...and $(( ${#APPLY_UNDECIDED[@]} - 12 )) more (full list: $0 plan${UPDATE_PIN_SUFFIX})" >&2
    fi
    echo "  Next step: record choices with $0 decide --set PATH=CHOICE [--set ...]${UPDATE_PIN_SUFFIX}" >&2
    echo "  (inspect rows with: $0 plan${UPDATE_PIN_SUFFIX}; valid choices per path: $0 decide --help)" >&2
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
  for UPDATE_S in "${APPLY_DEC_STALE[@]}"; do echo -e "${STY_FAINT}note: saved choice no longer matches and was ignored: $UPDATE_S${STY_RST}"; done
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
# User-facing base: the freshest confirmed payload state — last verified
# target when one is recorded, else the last applied target, else the
# adoption baseline. Presentation only; the planner keeps reasoning from
# PLAN_BASE_REV, whose provenance meaning ("baselined against") is
# unchanged. Recovery history (last_apply, journal, manifest) is never
# rewritten here.
UPDATE_FROM_REV="$PLAN_BASE_REV"
UPDATE_LAST_VERIFIED=""
UPDATE_LAST_VERIFIED=$(jq -r '.last_verified.target // empty' "$APPLY_SD/$DEPLOY_IDENTITY_NAME" 2>/dev/null || true)
UPDATE_LAST_APPLIED=""
UPDATE_LAST_APPLIED=$(jq -r '.last_apply.target // empty' "$APPLY_SD/$DEPLOY_IDENTITY_NAME" 2>/dev/null || true)
if [[ -n "$UPDATE_LAST_VERIFIED" ]]; then
  UPDATE_FROM_REV="$UPDATE_LAST_VERIFIED"
elif [[ -n "$UPDATE_LAST_APPLIED" ]]; then
  UPDATE_FROM_REV="$UPDATE_LAST_APPLIED"
fi
UPDATE_BASE_SHORT=$(git -C "$REPO_ROOT" rev-parse --short "$UPDATE_FROM_REV" 2>/dev/null || printf '%s' "${UPDATE_FROM_REV:0:7}")
UPDATE_TARGET_SHORT=$(git -C "$REPO_ROOT" rev-parse --short "$APPLY_TARGET" 2>/dev/null || printf '%s' "${APPLY_TARGET:0:7}")
UPDATE_KEEP_TXT=""
if (( UPDATE_N_KEEP > 0 )); then
  UPDATE_KEEP_TXT=" · ${UPDATE_N_KEEP} kept as-is by your decisions"
fi
UPDATE_PAYLOAD_LINE="Payload: ${UPDATE_N_WRITE} files to deploy (${UPDATE_N_UPD} updates, ${UPDATE_N_INS} new, ${UPDATE_N_DEL} deletions, ${UPDATE_N_SIDE} sidecars)${UPDATE_KEEP_TXT}"

# Dry runs evaluate only: full narrative, zero writes of any kind — no
# verification record, no checkout advance, no launcher lifecycle. A clean
# dry run still reports its finding (already- vs up-to-date), followed by
# the explicit dry disclaimer.
if [[ "${DEPLOY_UPDATE_DRYRUN:-false}" == true ]]; then
  update_scope_head
  echo "$UPDATE_PAYLOAD_LINE"
  if (( UPDATE_N_WRITE == 0 )); then
    UPDATE_HEAD_NOW=""
    UPDATE_HEAD_NOW=$(git -C "$REPO_ROOT" rev-parse --verify HEAD^{commit} 2>/dev/null || true)
    if [[ "${UPDATE_HANDED_OFF:-false}" != true && "${UPDATE_FETCH_MOVED:-false}" != true ]] \
      && [[ -n "$UPDATE_HEAD_NOW" && -n "${APPLY_TARGET:-}" && "$UPDATE_HEAD_NOW" == "$APPLY_TARGET" ]]; then
      echo -e "${STY_GREEN}✓${STY_RST} Already up to date at ${UPDATE_TARGET_SHORT} — payload matches, nothing to deploy"
    else
      echo -e "${STY_GREEN}✓${STY_RST} Up to date at ${UPDATE_TARGET_SHORT} — payload matches, nothing to deploy"
    fi
  fi
  echo "dry run: showing the above without applying anything (nothing changed)"
  exit 0
fi

if (( UPDATE_N_WRITE == 0 )); then
  update_record_verified || true
  update_advance_checkout || true
  # Launcher repair is captured, not just printed: a repaired launcher
  # means this run did work, so the verdict below must not claim a pure
  # steady state.
  UPDATE_LAUNCHER_OUT=""
  UPDATE_LAUNCHER_OUT="$(setup_launcher_ensure 2>&1)" || true
  UPDATE_LAUNCHER_REPAIRED=false
  if [[ -n "$UPDATE_LAUNCHER_OUT" ]]; then
    UPDATE_LAUNCHER_REPAIRED=true
  fi
  UPDATE_HEAD_NOW=""
  UPDATE_HEAD_NOW=$(git -C "$REPO_ROOT" rev-parse --verify HEAD^{commit} 2>/dev/null || true)
  # Steady state: payload matches, checkout at target, tracking ref
  # unmoved, no delegation, launcher converged. Only then does the run
  # collapse to a single verdict line instead of an update narrative.
  if [[ "${UPDATE_HANDED_OFF:-false}" != true && "${UPDATE_FETCH_MOVED:-false}" != true ]] \
    && [[ "$UPDATE_LAUNCHER_REPAIRED" != true ]] \
    && [[ -n "$UPDATE_HEAD_NOW" && -n "${APPLY_TARGET:-}" && "$UPDATE_HEAD_NOW" == "$APPLY_TARGET" ]]; then
    echo -e "${STY_GREEN}✓${STY_RST} Already up to date at ${UPDATE_TARGET_SHORT} — payload matches, nothing to deploy"
    exit 0
  fi
  update_scope_head
  echo "$UPDATE_PAYLOAD_LINE"
  # Deployment state and tool revision are distinct: the payload can be
  # current while the checkout's own updater lags the deployed target
  # (explicit --at always runs local logic by design). Handoff-inner runs
  # are exempt — they already execute the target's implementation despite
  # the checkout lagging behind it.
  if [[ "${UPDATE_HANDED_OFF:-false}" != true ]]; then
    UPDATE_RUNNER_HEAD=""
    UPDATE_RUNNER_HEAD=$(git -C "$REPO_ROOT" rev-parse --verify HEAD^{commit} 2>/dev/null || true)
    if [[ -n "$UPDATE_RUNNER_HEAD" && -n "${APPLY_TARGET:-}" && "$UPDATE_RUNNER_HEAD" != "$APPLY_TARGET" ]]; then
      UPDATE_RUNNER_SHORT=$(git -C "$REPO_ROOT" rev-parse --short "$UPDATE_RUNNER_HEAD" 2>/dev/null || printf '%s' "${UPDATE_RUNNER_HEAD:0:7}")
      echo -e "${STY_FAINT}note: this updater itself is running from ${UPDATE_RUNNER_SHORT}, not ${UPDATE_TARGET_SHORT} — payload is current, tool revision differs.${STY_RST}"
    fi
  fi
  if [[ "$UPDATE_LAUNCHER_REPAIRED" == true ]]; then
    printf '%s\n' "$UPDATE_LAUNCHER_OUT"
  fi
  echo -e "${STY_GREEN}✓${STY_RST} Up to date at ${UPDATE_TARGET_SHORT} — payload matches, nothing to deploy"
  exit 0
fi

# --- Mutation path (the only writer; reached solely through shared gates). ---
update_scope_head
echo "$UPDATE_PAYLOAD_LINE"
update_stage "Applying update"
UPDATE_RUN_RC=0
update_tech deploy_apply_run_fresh || UPDATE_RUN_RC=$?
term_spin_stop || true
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
update_record_verified || true
update_advance_checkout || true
setup_launcher_ensure
echo -e "${STY_GREEN}✓${STY_RST} Updated to ${UPDATE_TARGET_SHORT} — ${UPDATE_N_WRITE} written, ${UPDATE_N_KEEP} kept · fully_deployed=${UPDATE_DEPLOYED}"
exit 0
