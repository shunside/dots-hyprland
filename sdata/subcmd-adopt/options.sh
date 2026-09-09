# Handle args for subcmd: adopt
# shellcheck shell=bash

showhelp(){
echo -e "Syntax: $0 adopt [OPTIONS]...

Adoption baseline for the safe-update deployment system.

Default (no mode flag) is a read-only dry-run: compares the deployable
payload at a locally-resolved revision against the live filesystem and
reports what adoption would record. Performs ZERO writes.

  --apply asks to record that baseline durably (manifest + identity
  metadata only; never installs, replaces, deletes, or sidecars any
  deployed/user file). Refuses while the payload classification is
  incomplete (unclassified paths, errors, registry lint findings).

  --status only reads back previously recorded adoption state.

Options:
  --at SPEC      Revision spec: HEAD (default, works detached), a full or
                 abbreviated commit SHA, or any local ref (branch, tag,
                 remote-tracking ref as last fetched). Never fetches.
                 (Ignored by --status.)
  --home DIR     Home root to compare against (default: \$HOME).
                 Foreign roots are inspection-only unless --state-dir
                 is also given. (Ignored by --status.)
  --state-dir D  Absolute directory for adoption metadata.
                 Default: \$XDG_CONFIG_HOME/illogical-impulse (or
                 \$HOME/.config/illogical-impulse) when adopting \$HOME;
                 required when --home points elsewhere.
  --fontset NAME Use a fontset overlay as the fontconfig source, mirroring
                 install --fontset. Recorded in the deployment identity.
  --via-nix      Use the via-nix hypridle.conf source, mirroring install
                 --via-nix. Recorded in the deployment identity.
  --dry-run      Explicit dry-run (the default behavior).
  --apply        Record the adoption baseline durably (fail-closed, see above).
  --reconcile    Re-evaluate an already-adopted machine under the current
                 registry/revision without touching deployed/user files.
                 Requires complete adoption state, no lock, no open
                 transaction. Preserves adoption provenance (adopted_at,
                 deployed_revision, last_apply); drifted/missing rows are
                 re-observed, never laundered into confirmed.
  --status       Read back recorded adoption state (read-only).
  -h, --help     Show this help message.

Requires: jq (for reading deployment state).
"
}

# `man getopt` to see more
para=$(getopt \
  -o h \
  -l help,at:,home:,state-dir:,fontset:,via-nix,dry-run,apply,reconcile,status \
  -n "$0" -- "$@")
[ $? != 0 ] && echo "$0: Error when getopt, please recheck parameters." && exit 1

DEPLOY_AT="HEAD"
DEPLOY_HOME_DIR="$HOME"
DEPLOY_STATE_DIR=""
DEPLOY_WANT_DRYRUN=false
DEPLOY_WANT_APPLY=false
DEPLOY_WANT_RECONCILE=false
DEPLOY_WANT_STATUS=false

eval set -- "$para"
while true ; do
  case "$1" in
    -h|--help) showhelp;exit;;
    --at) DEPLOY_AT="$2";shift 2;;
    --home) DEPLOY_HOME_DIR="$2";shift 2;;
    --state-dir) DEPLOY_STATE_DIR="$2";shift 2;;
    --fontset) FONTSET_DIR_NAME="$2";shift 2;;
    --via-nix) INSTALL_VIA_NIX=true;shift;;
    --dry-run) DEPLOY_WANT_DRYRUN=true;shift;;
    --apply) DEPLOY_WANT_APPLY=true;shift;;
    --reconcile) DEPLOY_WANT_RECONCILE=true;shift;;
    --status) DEPLOY_WANT_STATUS=true;shift;;
    --) shift;break ;;
    *) echo -e "$0: Wrong parameters.";exit 1;;
  esac
done

if [[ "$DEPLOY_WANT_APPLY" == true && "$DEPLOY_WANT_STATUS" == true ]]; then
  echo "$0: --apply and --status are mutually exclusive." >&2
  exit 1
fi
if [[ "$DEPLOY_WANT_APPLY" == true && "$DEPLOY_WANT_DRYRUN" == true ]]; then
  echo "$0: --apply and --dry-run are mutually exclusive." >&2
  exit 1
fi
if [[ "$DEPLOY_WANT_RECONCILE" == true && "$DEPLOY_WANT_APPLY" == true ]]; then
  echo "$0: --reconcile and --apply are mutually exclusive." >&2
  exit 1
fi
if [[ "$DEPLOY_WANT_RECONCILE" == true && "$DEPLOY_WANT_STATUS" == true ]]; then
  echo "$0: --reconcile and --status are mutually exclusive." >&2
  exit 1
fi
if [[ "$DEPLOY_WANT_RECONCILE" == true && "$DEPLOY_WANT_DRYRUN" == true ]]; then
  echo "$0: --reconcile and --dry-run are mutually exclusive." >&2
  exit 1
fi
