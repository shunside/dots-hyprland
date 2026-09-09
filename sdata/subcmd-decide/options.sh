# Handle args for subcmd: decide
# shellcheck shell=bash

showhelp(){
echo -e "Syntax: $0 decide [OPTIONS]...

Record, remove, or list durable update decisions for safe deployment.

A decision resolves one decide-class planner operation for one path and is
fingerprinted against the exact fresh operation state (operation, live
observation, target, base). Any drift in those fingerprints renders the
decision stale, and stale decisions never apply.

Decisions are stored in the adoption state directory and never modify
deployed files. Applying happens separately via 'setup apply'.

Options:
  --at SPEC      Target revision context (default: HEAD). Local only.
  --home DIR     Home root to compare (default: \$HOME).
  --state-dir D  Adoption state directory (default: own-home standard
                 location; required with a foreign --home).
  --fontset NAME Payload input override (default: the adopted input).
  --via-nix      Payload input override (default: the adopted input).
  --set P=C      Record choice C for home-relative path P. Repeatable.
                 C must be valid for the path's fresh planner operation.
  --remove P     Forget the recorded decision for path P.
  --list         List recorded decisions (default when no other flag).
  -h, --help     Show this help message.

Requires: jq (for reading deployment state).
"
}

# `man getopt` to see more
para=$(getopt \
  -o h \
  -l help,at:,home:,state-dir:,fontset:,via-nix,set:,remove:,list \
  -n "$0" -- "$@")
[ $? != 0 ] && echo "$0: Error when getopt, please recheck parameters." && exit 1

DEPLOY_AT="HEAD"
DEPLOY_HOME_DIR="$HOME"
DEPLOY_STATE_DIR=""
DEPLOY_DECIDE_FONTSET=""
DEPLOY_DECIDE_FONTSET_SET=false
DEPLOY_DECIDE_VIANIX_SET=false
DEPLOY_DECIDE_LIST=false
declare -a DEPLOY_DECIDE_SET=()
declare -a DEPLOY_DECIDE_REMOVE=()

eval set -- "$para"
while true ; do
  case "$1" in
    -h|--help) showhelp;exit;;
    --at) DEPLOY_AT="$2";shift 2;;
    --home) DEPLOY_HOME_DIR="$2";shift 2;;
    --state-dir) DEPLOY_STATE_DIR="$2";shift 2;;
    --fontset) DEPLOY_DECIDE_FONTSET="$2";DEPLOY_DECIDE_FONTSET_SET=true;shift 2;;
    --via-nix) DEPLOY_DECIDE_VIANIX_SET=true;shift;;
    --set) DEPLOY_DECIDE_SET+=("$2");shift 2;;
    --remove) DEPLOY_DECIDE_REMOVE+=("$2");shift 2;;
    --list) DEPLOY_DECIDE_LIST=true;shift;;
    --) shift;break ;;
    *) echo -e "$0: Wrong parameters.";exit 1;;
  esac
done
