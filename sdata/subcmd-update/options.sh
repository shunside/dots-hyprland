# Handle args for subcmd: update
# shellcheck shell=bash

showhelp(){
echo -e "Syntax: $0 update [OPTIONS]...

Update this machine to the fork target revision.

Without --at, update first asks the current branch's configured remote
for the latest revision (fetch only: your checkout, working branch, and
local commits are never modified) and deploys that exact commit, so a
plain `update` tracks the fork. Pass --at for a fully local, offline
deploy of whatever the checkout already has; explicit targets never
trigger network access.

Runs the normal clean update path end to end: summarizes what will
change, evaluates every deployment gate (adoption state, decisions,
submodules, disk space, locks, open transactions), applies the update
transactionally when everything is decided, and verifies the result.
Stops before writing anything when a decision or manual recovery step
is needed, and tells you exactly which command to run next.

The lower-level plan/decide/apply commands stay available for
inspection and recovery; update never bypasses their safety model.

  --at SPEC      Target revision (default: latest on the configured
                 remote). An explicit --at is always local-only and never
                 fetches; use it (e.g. --at HEAD) for offline deploys.
                 Pull or switch branches yourself first if needed.
  --dry-run      Show what would change and evaluate all gates without
                 applying anything. Follows the same target discovery as
                 a real run (including the remote check); only --at
                 makes it fully offline.
  -h, --help     Show this help message.

Exit codes:
  0  updated, already up to date, or dry-run preview clean.
  2  blocked before any write (undecided/stale rows, submodule or error
     rows, missing adoption, lock, or open transaction). The message
     names the exact next step.
  1  failed mid-transaction (lock remains; resume/abort via setup apply).

Examples:
  $0 update
  $0 update --dry-run
  $0 update --at origin/main --resolve .config/app/drift.conf:replace

Advanced payload controls (--home, --state-dir, --fontset, --via-nix,
--resolve, --verbose) follow adoption defaults and are rarely needed.
See: $0 update --help-all

Requires: jq (for reading deployment state).
"
}

showhelp_all(){
echo -e "Syntax: $0 update [OPTIONS]... (advanced reference)

Same update flow as \`$0 update --help\`, with every control listed.

  --at SPEC      Target revision explicitly given: always local-only,
                 never fetches. Omit --at to track the branch's
                 configured remote instead (see above).
  --home DIR     Home root (default: \$HOME). Must match adopted home_root.
  --state-dir D  Adoption state directory (default: own-home standard
                 location; required with a foreign --home).
  --fontset NAME Payload input override (default: the adopted input).
  --via-nix      Payload input override (default: the adopted input).
  --resolve P:C  Ephemeral decision (choice C for path P, validated
                 against its fresh operation). Repeatable, never persisted.
  --dry-run      Show what would change and evaluate all gates without
                 applying anything. Follows the same target discovery as
                 a real run; only --at makes it fully offline.
  --verbose      Stream the full technical report (preflight internals,
                 fingerprints, transaction detail) instead of the concise
                 user summary. Blocked and failed paths always name the
                 technical detail needed to resolve them.
  --help-all     Show this advanced reference.
  -h, --help     Show the common help message.

Target discovery details: remote and branch come from the current
branch's tracking configuration (no hardcoded remote). Fetching updates
remote-tracking refs only; the working branch and worktree are never
modified. With no tracking branch configured, update uses the local
checkout and says so. If the fetch itself fails, update stops before
any deployment write. --at is fully local in all cases.

Requires: jq (for reading deployment state).
"
}

# `man getopt` to see more
para=$(getopt \
  -o h \
  -l help,help-all,at:,home:,state-dir:,fontset:,via-nix,resolve:,dry-run,verbose \
  -n "$0" -- "$@")
[ $? != 0 ] && echo "$0: Error when getopt, please recheck parameters." && exit 1

DEPLOY_AT="HEAD"
DEPLOY_UPDATE_AT_GIVEN=false
DEPLOY_HOME_DIR="$HOME"
DEPLOY_STATE_DIR=""
DEPLOY_APPLY_FONTSET=""
DEPLOY_APPLY_FONTSET_SET=false
DEPLOY_APPLY_VIANIX_SET=false
DEPLOY_UPDATE_DRYRUN=false
DEPLOY_UPDATE_VERBOSE=false
declare -a APPLY_RESOLVE=()

eval set -- "$para"
while true ; do
  case "$1" in
    -h|--help) showhelp;exit;;
    --help-all) showhelp_all;exit;;
    --at) DEPLOY_AT="$2"; DEPLOY_UPDATE_AT_GIVEN=true;shift 2;;
    --home) DEPLOY_HOME_DIR="$2";shift 2;;
    --state-dir) DEPLOY_STATE_DIR="$2";shift 2;;
    --fontset) DEPLOY_APPLY_FONTSET="$2";DEPLOY_APPLY_FONTSET_SET=true;shift 2;;
    --via-nix) DEPLOY_APPLY_VIANIX_SET=true;shift;;
    --resolve) APPLY_RESOLVE+=("$2");shift 2;;
    --dry-run) DEPLOY_UPDATE_DRYRUN=true;shift;;
    --verbose) DEPLOY_UPDATE_VERBOSE=true;shift;;
    --) shift;break ;;
    *) echo -e "$0: Wrong parameters.";exit 1;;
  esac
done
