# Handle args for subcmd: apply
# shellcheck shell=bash

showhelp(){
echo -e "Syntax: $0 apply [OPTIONS]...

Write-capable deployment (Slice 3B). Applies a fully gated plan to the
live filesystem: snapshot-first, journaled, idempotent per-path
operations, atomic end publication. Refuses unless every gate passes:
complete adoption state, classifiable target, valid decisions for every
decide row, submodule rows ok, sufficient space, no live lock, no open
transaction. Fail-fast: the first unexpected failure stops all further
mutation and leaves an explicit incomplete transaction.

Default mode performs the apply. --preflight only evaluates gates and
prints what would happen (zero writes).

  --at SPEC      Target revision (default: HEAD). Local only, never fetches.
  --home DIR     Home root (default: \$HOME). Must match adopted home_root.
  --state-dir D  Adoption state directory (default: own-home standard
                 location; required with a foreign --home).
  --fontset NAME Payload input override (default: the adopted input).
  --via-nix      Payload input override (default: the adopted input).
  --resolve P:C  Ephemeral decision (choice C for path P, validated
                 against its fresh operation). Repeatable, never persisted.
  --preflight    Evaluate all gates and report; perform zero writes.
  --resume ID    Resume an open transaction (journal intent authoritative).
  --abort ID     Abort an open transaction (verified snapshot restore).
  --break-lock   Release a dead lock file only; never resolves transaction
                 state (resume/abort still govern afterwards).
  -h, --help     Show this help message.

Requires: jq (for reading deployment state).
"
}

# `man getopt` to see more
para=$(getopt \
  -o h \
  -l help,at:,home:,state-dir:,fontset:,via-nix,resolve:,preflight,resume:,abort:,break-lock \
  -n "$0" -- "$@")
[ $? != 0 ] && echo "$0: Error when getopt, please recheck parameters." && exit 1

DEPLOY_AT="HEAD"
DEPLOY_HOME_DIR="$HOME"
DEPLOY_STATE_DIR=""
DEPLOY_APPLY_FONTSET=""
DEPLOY_APPLY_FONTSET_SET=false
DEPLOY_APPLY_VIANIX_SET=false
DEPLOY_APPLY_PREFLIGHT=false
DEPLOY_APPLY_RESUME=""
DEPLOY_APPLY_ABORT=""
DEPLOY_APPLY_BREAK=false
APPLY_AT_GIVEN=""
APPLY_INPUTS_GIVEN=""
declare -a APPLY_RESOLVE=()

eval set -- "$para"
while true ; do
  case "$1" in
    -h|--help) showhelp;exit;;
    --at) DEPLOY_AT="$2";APPLY_AT_GIVEN=1;shift 2;;
    --home) DEPLOY_HOME_DIR="$2";shift 2;;
    --state-dir) DEPLOY_STATE_DIR="$2";shift 2;;
    --fontset) DEPLOY_APPLY_FONTSET="$2";DEPLOY_APPLY_FONTSET_SET=true;APPLY_INPUTS_GIVEN=1;shift 2;;
    --via-nix) DEPLOY_APPLY_VIANIX_SET=true;APPLY_INPUTS_GIVEN=1;shift;;
    --resolve) APPLY_RESOLVE+=("$2");shift 2;;
    --preflight) DEPLOY_APPLY_PREFLIGHT=true;shift;;
    --resume) DEPLOY_APPLY_RESUME="$2";shift 2;;
    --abort) DEPLOY_APPLY_ABORT="$2";shift 2;;
    --break-lock) DEPLOY_APPLY_BREAK=true;shift;;
    --) shift;break ;;
    *) echo -e "$0: Wrong parameters.";exit 1;;
  esac
done

nmodes=0
[[ -n "$DEPLOY_APPLY_RESUME" ]] && nmodes=$((nmodes + 1))
[[ -n "$DEPLOY_APPLY_ABORT" ]] && nmodes=$((nmodes + 1))
[[ "$DEPLOY_APPLY_BREAK" == true ]] && nmodes=$((nmodes + 1))
[[ "$DEPLOY_APPLY_PREFLIGHT" == true ]] && nmodes=$((nmodes + 1))
if (( nmodes > 1 )); then
  echo "$0: --preflight/--resume/--abort/--break-lock are mutually exclusive." >&2
  exit 1
fi
if [[ -n "$DEPLOY_APPLY_RESUME" || -n "$DEPLOY_APPLY_ABORT" ]] && (( ${#APPLY_RESOLVE[@]} > 0 )); then
  echo "$0: --resolve cannot combine with --resume/--abort (journal intent governs)." >&2
  exit 1
fi
