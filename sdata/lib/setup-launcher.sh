# This is NOT a script for execution, but for loading functions, so NOT need execution permission or shebang.
#
# Global setup launcher: a symlink named $SETUP_GLOBAL_CMD inside
# XDG_BIN_HOME pointing at this repository's ./setup, so the normal
# workflow runs from any directory and always dispatches into the
# existing setup command system (no second updater, no duplicated logic).
# CLI updates can never strand it: it carries no logic of its own.

# shellcheck shell=bash

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
  case ":${PATH}:" in
    *":$(dirname "$link"):"*) ;;
    *) printf 'note: %s is not on PATH; add it to use "%s" from anywhere.\n' "$(dirname "$link")" "${SETUP_GLOBAL_CMD:-impulse}" >&2;;
  esac
  return 0
}

# Remove the launcher, but only when it actually points into this
# repository. A foreign occupant is never touched.
function setup_launcher_remove(){
  local link
  link="${XDG_BIN_HOME:-$HOME/.local/bin}/${SETUP_GLOBAL_CMD:-impulse}"
  [[ -L "$link" ]] || return 0
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
  return 0
}
