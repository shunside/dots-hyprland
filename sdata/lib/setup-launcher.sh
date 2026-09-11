# This is NOT a script for execution, but for loading functions, so NOT need execution permission or shebang.
#
# Global setup launcher: a symlink named $SETUP_GLOBAL_CMD inside
# XDG_BIN_HOME pointing at this repository's ./setup, plus a managed fish
# conf.d drop-in keeping that directory on PATH, so the normal workflow
# runs from any directory in every new shell and always dispatches into
# the existing setup command system (no second updater, no duplicated
# logic). The symlink carries no logic of its own; the drop-in carries
# only a PATH prepend for the launcher directory, nothing else.

# shellcheck shell=bash

# First line of the managed fish drop-in. Ownership rule: a conf.d file
# starting with this marker is ours to normalize; anything else is the
# user's and is never touched.
SETUP_PATH_SNIPPET_MARKER="# impulse-path (managed by illogical-impulse setup)"

# Render the drop-in for the current XDG_BIN_HOME. The default spells the
# directory via $HOME so the content stays valid if the home moves; an
# overridden bin dir is baked in literally.
setup_path_snippet_content(){
  local dir="${XDG_BIN_HOME:-$HOME/.local/bin}"
  local shown="$dir"
  if [[ "$dir" == "$HOME/.local/bin" ]]; then shown='$HOME/.local/bin'; fi
  printf '%s\n' \
    "$SETUP_PATH_SNIPPET_MARKER" \
    '# Keeps the `impulse` launcher directory on PATH in every new fish shell.' \
    '# Recreated by `impulse adopt`/`impulse update`; safe to delete after uninstall.' \
    "if test -d \"$shown\"; and not contains -- \"$shown\" \$PATH" \
    "    set -gx PATH \"$shown\" \$PATH" \
    'end'
}

# Ensure the persistent PATH drop-in. Idempotent: missing is written, ours
# is normalized, foreign content is left alone with a warning. Own machine
# only when the adoption context says foreign; warn-only so a completed
# deployment never fails over cosmetics.
function setup_path_ensure(){
  if [[ -n "${DEPLOY_HOME:-}" && -n "${DEPLOY_SELF_HOME:-}" && "${DEPLOY_HOME}" != "${DEPLOY_SELF_HOME}" ]]; then
    return 0
  fi
  local confdir="${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d"
  local file="$confdir/impulse-path.fish"
  local want
  want="$(setup_path_snippet_content)"
  if [[ -f "$file" ]]; then
    local first
    first="$(head -n 1 "$file" 2>/dev/null || true)"
    if [[ "$first" != "$SETUP_PATH_SNIPPET_MARKER" ]]; then
      echo "warning: \"$file\" is not managed by setup; leaving it alone (new shells need ${XDG_BIN_HOME:-$HOME/.local/bin} on PATH)." >&2
      return 1
    fi
    if [[ "$(cat "$file" 2>/dev/null)" == "$want" ]]; then
      return 0
    fi
  fi
  mkdir -p "$confdir" 2>/dev/null || {
    echo "warning: cannot create $confdir; new shells need ${XDG_BIN_HOME:-$HOME/.local/bin} on PATH." >&2
    return 1
  }
  if printf '%s\n' "$want" > "$file" 2>/dev/null; then
    return 0
  fi
  echo "warning: cannot write $file; new shells need ${XDG_BIN_HOME:-$HOME/.local/bin} on PATH." >&2
  return 1
}

# Install (or repair) the launcher. Idempotent: an already-correct link
# is a no-op, a stale link is replaced, and a non-symlink occupant is
# left alone with a warning instead of failing the install.
function setup_launcher_install(){
  local target link
  target="${REPO_ROOT}/setup"
  link="${XDG_BIN_HOME:-$HOME/.local/bin}/${SETUP_GLOBAL_CMD:-impulse}"
  mkdir -p "$(dirname "$link")" || { echo "error: cannot create $(dirname "$link")" >&2; return 1; }
  if [[ -L "$link" ]]; then
    local cur rtarget
    cur="$(readlink -f "$link" 2>/dev/null || true)"
    rtarget="$(readlink -f "$target" 2>/dev/null || printf '%s' "$target")"
    if [[ -n "$cur" && "$cur" == "$rtarget" ]]; then
      printf 'Global command already installed at "%s".\n' "$link"
      return 0
    fi
    printf 'Replacing stale launcher at "%s".\n' "$link"
    rm -f -- "$link" || { echo "error: cannot remove $link" >&2; return 1; }
  elif [[ -e "$link" ]]; then
    echo "warning: \"$link\" exists and is not the setup launcher; leaving it alone." >&2
    return 0
  fi
  ln -s "$target" "$link" || { echo "error: cannot link $link" >&2; return 1; }
  printf 'Installed global command "%s".\n' "$link"
  # Current-process courtesy for bash callers: prepend for this process so
  # the command works immediately here. Persistence across sessions comes
  # solely from the drop-in below, never from this export (a child process
  # cannot change its parent shell's PATH, so fish needs a new shell).
  case ":${PATH}:" in
    *":$(dirname "$link"):"*) ;;
    *) export PATH="$(dirname "$link"):$PATH";;
  esac
  setup_path_ensure || true
  return 0
}

# Ensure the launcher for interactive human use. Intended after a
# successful adopt/update publication: silent when already correct, one
# note when newly created, warning (still rc 0) when creation fails so a
# completed deployment never fails over cosmetics. Own machine only —
# adopting or updating a foreign tree must not touch the operator's bin
# dir. Expects DEPLOY_HOME, DEPLOY_SELF_HOME, and REPO_ROOT from the
# caller; styles degrade via defaults when sourced without setup.
function setup_launcher_ensure(){
  if [[ "${DEPLOY_HOME:-}" != "${DEPLOY_SELF_HOME:-}" || -z "${DEPLOY_HOME:-}" ]]; then
    return 0
  fi
  local link want cur
  link="${XDG_BIN_HOME:-$HOME/.local/bin}/${SETUP_GLOBAL_CMD:-impulse}"
  want="$(readlink -f "$REPO_ROOT/setup" 2>/dev/null || printf '%s' "$REPO_ROOT/setup")"
  cur=""
  if [[ -L "$link" ]]; then
    cur="$(readlink -f "$link" 2>/dev/null || true)"
  fi
  if [[ -n "$cur" && "$cur" == "$want" ]]; then
    return 0
  fi
  setup_launcher_install >/dev/null 2>&1 || true
  # Announce only what is actually true now: re-check the symlink, then
  # re-run the (idempotent, quiet-on-success) PATH step to decide which
  # half of the message applies. Fish shells always need a new session;
  # nothing a child process does can change the parent shell's PATH.
  cur=""
  if [[ -L "$link" ]]; then
    cur="$(readlink -f "$link" 2>/dev/null || true)"
  fi
  if [[ -n "$cur" && "$cur" == "$want" ]]; then
    if setup_path_ensure >/dev/null 2>&1; then
      echo -e "${STY_FAINT:-}note: installed the global 'impulse' command — new shells pick it up automatically${STY_RST:-}"
    else
      echo -e "${STY_FAINT:-}note: installed the global 'impulse' command — add ${XDG_BIN_HOME:-$HOME/.local/bin} to PATH for new shells to find it${STY_RST:-}"
    fi
  else
    echo "warning: could not install the global 'impulse' launcher; ./setup keeps working" >&2
  fi
  return 0
}

# Remove the launcher, but only when it actually points into this
# repository. A foreign occupant is never touched. The managed PATH
# drop-in goes with it, again only when its marker proves it is ours.
function setup_launcher_remove(){
  local link
  link="${XDG_BIN_HOME:-$HOME/.local/bin}/${SETUP_GLOBAL_CMD:-impulse}"
  if [[ -L "$link" ]]; then
    local cur rrepo
    cur="$(readlink -f "$link" 2>/dev/null || true)"
    rrepo="$(readlink -f "$REPO_ROOT" 2>/dev/null || printf '%s' "$REPO_ROOT")"
    case "$cur" in
      "$rrepo"/*)
        rm -f -- "$link" || { echo "error: cannot remove $link" >&2; return 1; }
        printf 'Removed global command "%s".\n' "$link";;
      *)
        printf 'Leaving "%s" alone (it does not point into this repository).\n' "$link" >&2;;
    esac
  fi
  local snippet="${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/impulse-path.fish"
  if [[ -f "$snippet" ]]; then
    if [[ "$(head -n 1 "$snippet" 2>/dev/null || true)" == "$SETUP_PATH_SNIPPET_MARKER" ]]; then
      rm -f -- "$snippet" || { echo "error: cannot remove $snippet" >&2; return 1; }
      printf 'Removed "%s".\n' "$snippet"
    else
      printf 'Leaving "%s" alone (it is not managed by setup).\n' "$snippet" >&2
    fi
  fi
  return 0
}
