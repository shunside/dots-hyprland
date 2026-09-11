# Standalone one-time bridge for checkouts that predate the updater handoff.
#
# NEVER source this file: it must run without executing ANY code from the
# local checkout, because on a pre-handoff machine the checkout's own
# updater cannot hand off by itself (the mechanism postdates it). Only
# bash, git, and the target revision's updater (materialized read-only
# from the object store, or the checkout itself after a fast-forward)
# execute here.
#
# Supported invocation (the fetched ref supplies this script, so the
# checkout's age does not matter):
#   git -C <repo> fetch origin main &&
#   bash <(git -C <repo> show FETCH_HEAD:sdata/lib/update-bridge.sh) --repo <repo>
#
# What it does, in order:
#   1. Resolves the checkout's tracking remote/branch (origin/main fallback)
#      and fetches it. Remote-tracking refs only — same safety as update.
#   2. Tries to advance the checkout's branch to the fetched target with
#      `merge --ff-only`. This refuses rather than harms: dirty, diverged,
#      local-ahead, and detached checkouts are left exactly as they are.
#   3. Fast-forward succeeded: the checkout is now handoff-capable, so its
#      own `./setup update` runs (normal discovery, launcher included).
#      Nothing else to do afterwards — future updates hand off by themselves.
#   4. Fast-forward refused: the target revision's updater is materialized
#      with read-only `git archive` into a temp dir and run pinned at the
#      target, so payload and launcher still come up to date. The branch,
#      index, and worktree stay untouched; reconcile the branch whenever
#      suits and re-run this bridge (or just update) to finish migrating.
#
# succeed-or-nothing per stage; worktree dirt and local commits are never
# clobbered. --dry-run changes nothing (skips the advance, passes through).

# shellcheck shell=bash
set -uo pipefail

BRIDGE_REPO=""
BRIDGE_HOME="$HOME"
BRIDGE_STATE_DIR=""
BRIDGE_DRYRUN=false
BRIDGE_VERBOSE=false

while (( $# > 0 )); do
  case "$1" in
    --repo) BRIDGE_REPO="${2:-}"; shift 2;;
    --home) BRIDGE_HOME="${2:-}"; shift 2;;
    --state-dir) BRIDGE_STATE_DIR="${2:-}"; shift 2;;
    --dry-run) BRIDGE_DRYRUN=true; shift;;
    --verbose) BRIDGE_VERBOSE=true; shift;;
    -h|--help)
      echo "Usage: bash <(git -C <repo> show FETCH_HEAD:sdata/lib/update-bridge.sh) [--repo DIR] [--home DIR] [--state-dir DIR] [--dry-run] [--verbose]"
      echo "One-time bridge: fetch the tracked fork revision, fast-forward the checkout when safe,"
      echo "then run the target revision's updater pinned. Never resets or rewrites local state."
      exit 0;;
    *) echo "update-bridge: unknown argument: $1" >&2; exit 2;;
  esac
done

if [[ -z "$BRIDGE_REPO" ]]; then
  BRIDGE_REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
if [[ -z "$BRIDGE_REPO" ]] || ! BRIDGE_REPO="$(cd "$BRIDGE_REPO" 2>/dev/null && pwd -P)"; then
  echo "update-bridge: cannot locate a repository checkout (pass --repo DIR)." >&2
  exit 2
fi

# Tracking remote/branch, same rule as `setup update`: no hardcoded remote.
BRIDGE_UPSTREAM="$(git -C "$BRIDGE_REPO" rev-parse --symbolic-full-name "@{u}" 2>/dev/null || true)"
BRIDGE_REMOTE="origin"
BRIDGE_BRANCH="main"
if [[ "$BRIDGE_UPSTREAM" == refs/remotes/* ]]; then
  BRIDGE_TRACK="${BRIDGE_UPSTREAM#refs/remotes/}"
  while IFS= read -r BRIDGE_R; do
    [[ -z "$BRIDGE_R" ]] && continue
    case "$BRIDGE_TRACK" in
      "$BRIDGE_R"/*)
        BRIDGE_REMOTE="$BRIDGE_R"
        BRIDGE_BRANCH="${BRIDGE_TRACK:$((${#BRIDGE_R} + 1))}"
        break;;
    esac
  done < <(git -C "$BRIDGE_REPO" remote 2>/dev/null || true)
  echo "update-bridge: tracking $BRIDGE_REMOTE/$BRIDGE_BRANCH."
else
  echo "update-bridge: no remote tracking branch; assuming $BRIDGE_REMOTE/$BRIDGE_BRANCH."
fi

echo "update-bridge: fetching $BRIDGE_REMOTE/$BRIDGE_BRANCH (remote-tracking refs only)."
if ! BRIDGE_FETCH_ERR=$(git -C "$BRIDGE_REPO" fetch --quiet -- "$BRIDGE_REMOTE" "$BRIDGE_BRANCH" 2>&1); then
  echo "update-bridge: could not fetch $BRIDGE_REMOTE/$BRIDGE_BRANCH." >&2
  [[ -n "$BRIDGE_FETCH_ERR" ]] && echo "  $(head -n 1 <<<"$BRIDGE_FETCH_ERR")" >&2
  exit 1
fi
BRIDGE_TARGET="$(git -C "$BRIDGE_REPO" rev-parse --verify "$BRIDGE_REMOTE/$BRIDGE_BRANCH^{commit}" 2>/dev/null || true)"
if [[ ! "$BRIDGE_TARGET" =~ ^[0-9a-f]{40}$ ]]; then
  echo "update-bridge: $BRIDGE_REMOTE/$BRIDGE_BRANCH did not resolve after fetching." >&2
  exit 1
fi
BRIDGE_HEAD="$(git -C "$BRIDGE_REPO" rev-parse --verify HEAD^{commit} 2>/dev/null || true)"
echo "update-bridge: target $BRIDGE_TARGET."

BRIDGE_PASSTHROUGH=()
[[ -n "$BRIDGE_STATE_DIR" ]] && BRIDGE_PASSTHROUGH+=(--state-dir "$BRIDGE_STATE_DIR")
[[ "$BRIDGE_HOME" != "$HOME" ]] && BRIDGE_PASSTHROUGH+=(--home "$BRIDGE_HOME")
[[ "$BRIDGE_DRYRUN" == true ]] && BRIDGE_PASSTHROUGH+=(--dry-run)
[[ "$BRIDGE_VERBOSE" == true ]] && BRIDGE_PASSTHROUGH+=(--verbose)

# One-time advance: fast-forward only, so anything that is not a clean
# descendant refuses instead of changing. Attempted only on a branch and
# never under --dry-run.
BRIDGE_ADVANCED=false
if [[ "$BRIDGE_DRYRUN" == true ]]; then
  echo "update-bridge: dry run — leaving the checkout exactly as it is."
elif ! BRIDGE_BRANCH_NAME=$(git -C "$BRIDGE_REPO" symbolic-ref --quiet --short HEAD 2>/dev/null); then
  echo "update-bridge: detached checkout — leaving it untouched (no branch to advance)."
elif [[ "$BRIDGE_HEAD" == "$BRIDGE_TARGET" ]]; then
  echo "update-bridge: checkout already at the target."
  BRIDGE_ADVANCED=true
elif git -C "$BRIDGE_REPO" merge --ff-only --quiet "$BRIDGE_REMOTE/$BRIDGE_BRANCH" 2>/dev/null; then
  echo "update-bridge: fast-forwarded $BRIDGE_BRANCH_NAME to the target; the checkout is now handoff-capable."
  BRIDGE_ADVANCED=true
else
  echo "update-bridge: cannot fast-forward $BRIDGE_BRANCH_NAME (dirty, diverged, or local-ahead) — leaving branch, index, and worktree untouched."
fi

if [[ "$BRIDGE_ADVANCED" == true ]]; then
  # The checkout now runs its own updater, which hands off by itself from
  # here on. No fetched-code materialization needed on this path.
  echo "update-bridge: running the checkout's updater."
  "$BRIDGE_REPO/setup" update "${BRIDGE_PASSTHROUGH[@]}"
  exit $?
fi

# Fallback: run the TARGET revision's updater without moving anything.
# Read-only object-store reads into a temp dir; branch, index, and
# worktree are never touched. Pinned driver contract mirrors the handoff
# block in sdata/subcmd-update/0.run.sh — keep the two in sync.
echo "update-bridge: running the target revision's updater pinned at $BRIDGE_TARGET."
BRIDGE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/setup-update-bridge-XXXXXX" 2>/dev/null)" || {
  echo "update-bridge: cannot stage the target updater implementation." >&2
  exit 1
}
trap 'rm -rf "$BRIDGE_TMP"' EXIT
if ! git -C "$BRIDGE_REPO" archive "$BRIDGE_TARGET" sdata/lib sdata/subcmd-update 2>/dev/null | tar -x -C "$BRIDGE_TMP" 2>/dev/null; then
  echo "update-bridge: target $BRIDGE_TARGET has no updater implementation to run." >&2
  echo "  Deploy it explicitly with the checkout's own logic instead: $BRIDGE_REPO/setup update --at $BRIDGE_TARGET" >&2
  exit 1
fi
if [[ ! -f "$BRIDGE_TMP/sdata/subcmd-update/0.run.sh" ]] || ! bash -n "$BRIDGE_TMP/sdata/subcmd-update/0.run.sh" 2>/dev/null; then
  echo "update-bridge: target $BRIDGE_TARGET has no runnable updater implementation." >&2
  echo "  Deploy it explicitly with the checkout's own logic instead: $BRIDGE_REPO/setup update --at $BRIDGE_TARGET" >&2
  exit 1
fi

export REPO_ROOT="$BRIDGE_REPO"
export DEPLOY_LIB_DIR="$BRIDGE_TMP/sdata/lib"
export DEPLOY_AT="$BRIDGE_TARGET"
export DEPLOY_UPDATE_AT_GIVEN=true
export UPDATE_HANDED_OFF=true
export DEPLOY_HOME_DIR="$BRIDGE_HOME"
export DEPLOY_STATE_DIR="$BRIDGE_STATE_DIR"
export DEPLOY_APPLY_FONTSET="${DEPLOY_APPLY_FONTSET:-}"
export DEPLOY_APPLY_FONTSET_SET=false
export DEPLOY_APPLY_VIANIX_SET=false
export DEPLOY_UPDATE_DRYRUN="$BRIDGE_DRYRUN"
export DEPLOY_UPDATE_VERBOSE="$BRIDGE_VERBOSE"
BRIDGE_RUNNER="$BRIDGE_TMP/sdata/subcmd-update/0.run.sh"
# bash -c so the inner run's $0 names the real entry point (copy-pasted
# follow-ups keep working) instead of this script's stdin path.
BRIDGE_RC=0
bash -c 'declare -a APPLY_RESOLVE=(); source "$1"' "$BRIDGE_REPO/setup" "$BRIDGE_RUNNER" || BRIDGE_RC=$?
if (( BRIDGE_RC == 0 )); then
  if [[ "$BRIDGE_DRYRUN" == true ]]; then
    echo "update-bridge: dry run finished — nothing applied, branch untouched."
  else
    echo "update-bridge: target updater finished. Payload and launcher are current; the branch itself was left untouched."
    echo "  To finish migrating: reconcile the branch onto $BRIDGE_REMOTE/$BRIDGE_BRANCH, then just use impulse update."
  fi
fi
exit "$BRIDGE_RC"
