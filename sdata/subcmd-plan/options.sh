# Handle args for subcmd: plan
# shellcheck shell=bash

showhelp(){
echo -e "Syntax: $0 plan [OPTIONS]...

Read-only update planner for the safe-update deployment system.

Compares the adopted baseline (manifest + identity), the live filesystem,
and a locally-resolved target revision, then prints the resulting plan as
TSV on stdout plus a human summary on stderr. Performs ZERO writes: no
deployed/user files, no metadata, no plan persistence, no git/network
activity beyond local object-store reads.

Options:
  --at SPEC      Target revision: HEAD (default), commit SHA, or local ref.
                 Never fetches. The baseline stays as adopted; only the
                 target is selected here.
  --home DIR     Home root to compare (default: \$HOME). Must match the
                 adopted home_root or planning is refused.
  --state-dir D  Adoption state directory (default: own-home standard
                 location; required with a foreign --home).
  --fontset NAME Payload input override (default: the adopted input).
                 Use \"default\" to return to the default payload.
  --via-nix      Payload input override (default: the adopted input).
  --verbose      List every row in the human summary, including the
                 informational-only bulk rows summarized by default.
  -h, --help     Show this help message.

Requires: jq (for reading deployment state).
"
}

# `man getopt` to see more
para=$(getopt \
  -o h \
  -l help,at:,home:,state-dir:,fontset:,via-nix,verbose \
  -n "$0" -- "$@")
[ $? != 0 ] && echo "$0: Error when getopt, please recheck parameters." && exit 1

DEPLOY_AT="HEAD"
DEPLOY_HOME_DIR="$HOME"
DEPLOY_STATE_DIR=""
DEPLOY_PLAN_FONTSET=""
DEPLOY_PLAN_FONTSET_SET=false
DEPLOY_PLAN_VIANIX_SET=false
DEPLOY_PLAN_VERBOSE=false

eval set -- "$para"
while true ; do
  case "$1" in
    -h|--help) showhelp;exit;;
    --at) DEPLOY_AT="$2";shift 2;;
    --home) DEPLOY_HOME_DIR="$2";shift 2;;
    --state-dir) DEPLOY_STATE_DIR="$2";shift 2;;
    --fontset) DEPLOY_PLAN_FONTSET="$2";DEPLOY_PLAN_FONTSET_SET=true;shift 2;;
    --via-nix) DEPLOY_PLAN_VIANIX_SET=true;shift;;
    --verbose) DEPLOY_PLAN_VERBOSE=true;shift;;
    --) shift;break ;;
    *) echo -e "$0: Wrong parameters.";exit 1;;
  esac
done
