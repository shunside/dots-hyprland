# This is NOT a script for execution, but for loading functions, so NOT need execution permission or shebang.
#
# Global setup launcher: a symlink named $SETUP_GLOBAL_CMD inside
# XDG_BIN_HOME pointing at this repository's ./setup, plus per-shell PATH
# integration, so the normal workflow runs from any directory in every new
# shell and always dispatches into the existing setup command system (no
# second updater, no duplicated logic). The symlink carries no logic of
# its own; shell artifacts carry only a PATH prepend for the launcher
# directory, nothing else.
#
# Shell strategy (per supported shell, managed independently so partial
# state converges file by file):
#   fish  whole-file-owned drop-in under fish/conf.d (native extension
#         point; read by every new fish, login or not).
#   bash  one hook line in ~/.bashrc (interactive terminals) sourcing the
#         owned env.sh below.
#   sh    one hook line in ~/.profile (login shells; also the fallback
#         bash reads when no ~/.bash_profile exists).
#   zsh   one hook line in ~/.zshrc and ~/.zprofile (ZDOTDIR-aware).
# Managed shells are the INSTALLED ones (command -v), never just $SHELL:
# a user switching shells converges on the next update instead of losing
# the command. Nushell is deliberately not managed: no interpreter here
# to validate against, and its config/autoload layout is version
# sensitive; fish/bash/zsh/sh cover the installed base. systemd
# environment.d and friends were rejected: they need a re-login, while a
# new shell process must be sufficient.
# Ownership: whole-owned files (drop-in, env.sh) are normalized when the
# marker proves them ours; rc hook lines match exactly or are left alone.
# The ensure path only ever deletes byte-identical owned duplicates and
# rewrites whole-owned files — a modified user block is never rewritten
# there. Uninstall sweeps every shell artifact unconditionally.

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

# Quiet predicate: does the managed drop-in currently hold? No writes,
# no warnings; pairs with setup_path_ensure for check-then-act without
# duplicating the ownership rule.
function setup_path_present(){
  local file="${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/impulse-path.fish"
  [[ -f "$file" ]] || return 1
  [[ "$(head -n 1 "$file" 2>/dev/null || true)" == "$SETUP_PATH_SNIPPET_MARKER" ]] || return 1
  [[ "$(cat "$file" 2>/dev/null || true)" == "$(setup_path_snippet_content)" ]] || return 1
  return 0
}

# Ensure the persistent PATH drop-in. Idempotent: missing is written, ours
# is normalized, foreign content is left alone with a warning. Own machine
# only when the adoption context says foreign; warn-only so a completed
# deployment never fails over cosmetics.
function setup_path_ensure(){
  if [[ -n "${DEPLOY_HOME:-}" && -n "${DEPLOY_SELF_HOME:-}" && "${DEPLOY_HOME}" != "${DEPLOY_SELF_HOME}" ]]; then
    return 0
  fi
  if setup_path_present; then
    return 0
  fi
  local confdir="${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d"
  local file="$confdir/impulse-path.fish"
  if [[ -f "$file" ]]; then
    echo "warning: \"$file\" is not managed by setup; leaving it alone (new shells need ${XDG_BIN_HOME:-$HOME/.local/bin} on PATH)." >&2
    return 1
  fi
  mkdir -p "$confdir" 2>/dev/null || {
    echo "warning: cannot create $confdir; new shells need ${XDG_BIN_HOME:-$HOME/.local/bin} on PATH." >&2
    return 1
  }
  if printf '%s\n' "$(setup_path_snippet_content)" > "$file" 2>/dev/null; then
    return 0
  fi
  echo "warning: cannot write $file; new shells need ${XDG_BIN_HOME:-$HOME/.local/bin} on PATH." >&2
  return 1
}

# Owned sh-family env file: single source of PATH truth for the rc hooks
# below, so logic updates converge by rewriting this one file.
setup_env_sh_path(){
  printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/illogical-impulse/env.sh"
}

# Render env.sh for the current XDG_BIN_HOME (same $HOME-anchoring rule
# as the fish drop-in).
setup_env_sh_content(){
  local dir="${XDG_BIN_HOME:-$HOME/.local/bin}"
  local shown="$dir"
  if [[ "$dir" == "$HOME/.local/bin" ]]; then shown='$HOME/.local/bin'; fi
  printf '%s\n' \
    "$SETUP_PATH_SNIPPET_MARKER" \
    '# Sourced by shell rc hooks; keeps the `impulse` launcher directory on PATH.' \
    '# Recreated by `impulse adopt`/`impulse update`; safe to delete after uninstall.' \
    "if [ -d \"$shown\" ]; then" \
    '  case ":$PATH:" in' \
    "    *\":$shown:\"*) ;;" \
    "    *) export PATH=\"$shown:\$PATH\" ;;" \
    '  esac' \
    'fi'
}

function setup_env_present(){
  local file
  file="$(setup_env_sh_path)"
  [[ -f "$file" ]] || return 1
  [[ "$(head -n 1 "$file" 2>/dev/null || true)" == "$SETUP_PATH_SNIPPET_MARKER" ]] || return 1
  [[ "$(cat "$file" 2>/dev/null || true)" == "$(setup_env_sh_content)" ]] || return 1
  return 0
}

function setup_env_ensure(){
  local file
  file="$(setup_env_sh_path)"
  if setup_env_present; then
    return 0
  fi
  if [[ -f "$file" ]]; then
    echo "warning: \"$file\" is not managed by setup; leaving it alone." >&2
    return 1
  fi
  mkdir -p "$(dirname "$file")" 2>/dev/null || {
    echo "warning: cannot create $(dirname "$file")." >&2
    return 1
  }
  if printf '%s\n' "$(setup_env_sh_content)" > "$file" 2>/dev/null; then
    return 0
  fi
  echo "warning: cannot write $file." >&2
  return 1
}

# Render the one hook line sourcing env.sh. Default data dir uses the
# runtime-default form so the line survives home moves; an overridden
# XDG_DATA_HOME is baked in literally.
setup_sh_hook_line(){
  local env="${XDG_DATA_HOME:-$HOME/.local/share}/illogical-impulse/env.sh"
  local shown="$env"
  if [[ "$env" == "$HOME/.local/share/illogical-impulse/env.sh" ]]; then
    shown='${XDG_DATA_HOME:-$HOME/.local/share}/illogical-impulse/env.sh'
  fi
  printf '%s' "[ -f \"$shown\" ] && . \"$shown\" # impulse-path (managed by illogical-impulse setup)"
}

# Exact-line ownership: a line is ours only when it equals the hook line
# byte for byte. Anything merely resembling it is foreign.
function setup_hook_present(){
  [[ -f "$1" ]] || return 1
  grep -qFx -e "$(setup_sh_hook_line)" "$1" 2>/dev/null
}

# Append the hook when absent; collapse byte-identical duplicates to one.
# A present-but-different marker line means user-modified: warn and touch
# nothing. Missing files are created holding only the hook; existing
# content is otherwise preserved byte for byte (one blank separator).
function setup_hook_add(){
  local file="$1" hook count
  hook="$(setup_sh_hook_line)"
  if [[ ! -e "$file" ]]; then
    mkdir -p "$(dirname "$file")" 2>/dev/null || {
      echo "warning: cannot create $(dirname "$file")." >&2
      return 1
    }
    printf '%s\n' "$hook" > "$file" 2>/dev/null || {
      echo "warning: cannot write $file." >&2
      return 1
    }
    return 0
  fi
  count="$(grep -cFx -e "$hook" "$file" 2>/dev/null || true)"
  if [[ "$count" == "1" ]]; then
    return 0
  fi
  if (( count > 1 )); then
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/setup-hook-XXXXXX" 2>/dev/null)" || return 1
    grep -vxF -e "$hook" "$file" 2>/dev/null > "$tmp" || true
    printf '\n%s\n' "$hook" >> "$tmp" || { rm -f "$tmp"; return 1; }
    cat "$tmp" > "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    return 0
  fi
  if grep -qF "$SETUP_PATH_SNIPPET_MARKER" "$file" 2>/dev/null; then
    echo "warning: \"$file\" holds a modified impulse-path block; leaving it alone." >&2
    return 1
  fi
  if [[ -s "$file" ]]; then
    printf '\n%s\n' "$hook" >> "$file" 2>/dev/null || {
      echo "warning: cannot write $file." >&2
      return 1
    }
  else
    printf '%s\n' "$hook" >> "$file" 2>/dev/null || {
      echo "warning: cannot write $file." >&2
      return 1
    }
  fi
  return 0
}

# Delete exactly-owned hook lines, preserving everything else byte for
# byte. When our hook is the final line preceded by exactly the blank
# separator our own append added, both go (exact reversal of the add).
# Otherwise plain line filtering applies. A file left empty held only our
# hook, so removing it restores the pre-integration state exactly.
function setup_hook_remove(){
  local file="$1" hook left
  hook="$(setup_sh_hook_line)"
  [[ -f "$file" ]] || return 0
  if ! grep -qFx -e "$hook" "$file" 2>/dev/null; then
    if grep -qF "$SETUP_PATH_SNIPPET_MARKER" "$file" 2>/dev/null; then
      printf 'Leaving "%s" alone (its impulse-path block is not ours).\n' "$file" >&2
    fi
    return 0
  fi
  local last prev n
  last="$(tail -n 1 "$file" 2>/dev/null || true)"
  prev="$(tail -n 2 "$file" 2>/dev/null | head -n 1 || true)"
  n="$(wc -l < "$file" 2>/dev/null || echo 0)"
  if [[ "$last" == "$hook" && -z "$prev" ]] && [[ "$n" =~ ^[0-9]+$ ]] && (( n > 2 )); then
    left="$(mktemp "${TMPDIR:-/tmp}/setup-hook-XXXXXX" 2>/dev/null)" || return 1
    if head -n $(( n - 2 )) "$file" > "$left" 2>/dev/null && cat "$left" > "$file" 2>/dev/null; then
      rm -f "$left"
      return 0
    fi
    rm -f "$left"
    echo "error: cannot write $file" >&2
    return 1
  fi
  left="$(mktemp "${TMPDIR:-/tmp}/setup-hook-XXXXXX" 2>/dev/null)" || return 1
  grep -vxF -e "$hook" "$file" 2>/dev/null > "$left" || true
  if [[ -s "$left" ]]; then
    cat "$left" > "$file" 2>/dev/null || { rm -f "$left"; echo "error: cannot write $file" >&2; return 1; }
  else
    rm -f -- "$file" || { rm -f "$left"; echo "error: cannot remove $file" >&2; return 1; }
    printf 'Removed "%s".\n' "$file"
  fi
  rm -f "$left"
  return 0
}

# rc files per shell family. ZDOTDIR-aware for zsh; bash/profile live
# directly under $HOME (bash has no relocatable dotdir).
setup_shell_rc_files(){
  local shell="$1"
  case "$shell" in
    bash) printf '%s\n' "$HOME/.bashrc";;
    profile) printf '%s\n' "$HOME/.profile";;
    zsh) printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc" "${ZDOTDIR:-$HOME}/.zprofile";;
  esac
}

# Shells to integrate: installed binaries, never just $SHELL, so switching
# shells converges on the next lifecycle run. sh (via ~/.profile) is the
# POSIX baseline and always applies.
setup_managed_shells(){
  printf '%s\n' "profile"
  command -v bash >/dev/null 2>&1 && printf '%s\n' "bash"
  command -v fish >/dev/null 2>&1 && printf '%s\n' "fish"
  command -v zsh >/dev/null 2>&1 && printf '%s\n' "zsh"
}

# Quiet predicate over every applicable component (symlink excluded: the
# caller owns that half).
function setup_shells_present(){
  local shell rc
  while IFS= read -r shell; do
    case "$shell" in
      fish) setup_path_present || return 1;;
      profile|bash|zsh)
        setup_env_present || return 1
        while IFS= read -r rc; do
          setup_hook_present "$rc" || return 1
        done < <(setup_shell_rc_files "$shell");;
    esac
  done < <(setup_managed_shells)
  return 0
}

# Converge every applicable component; nonzero when anything failed (the
# caller announces). Foreign-home safe like the rest of this file.
function setup_shells_ensure(){
  if [[ -n "${DEPLOY_HOME:-}" && -n "${DEPLOY_SELF_HOME:-}" && "${DEPLOY_HOME}" != "${DEPLOY_SELF_HOME}" ]]; then
    return 0
  fi
  local rc_all=0 shell rc
  while IFS= read -r shell; do
    case "$shell" in
      fish) setup_path_ensure || rc_all=1;;
      profile|bash|zsh)
        setup_env_ensure || rc_all=1
        while IFS= read -r rc; do
          setup_hook_add "$rc" || rc_all=1
        done < <(setup_shell_rc_files "$shell");;
    esac
  done < <(setup_managed_shells)
  return "$rc_all"
}

# Sweep every shell artifact unconditionally (no installed-gates: removal
# must also catch shells uninstalled since integration). Owned-only.
function setup_shells_remove(){
  local rc
  setup_hook_remove "$HOME/.bashrc"
  setup_hook_remove "$HOME/.profile"
  setup_hook_remove "${ZDOTDIR:-$HOME}/.zshrc"
  setup_hook_remove "${ZDOTDIR:-$HOME}/.zprofile"
  local envfile snippet
  envfile="$(setup_env_sh_path)"
  if [[ -f "$envfile" ]]; then
    if [[ "$(head -n 1 "$envfile" 2>/dev/null || true)" == "$SETUP_PATH_SNIPPET_MARKER" ]]; then
      rm -f -- "$envfile" || { echo "error: cannot remove $envfile" >&2; return 1; }
      printf 'Removed "%s".\n' "$envfile"
    else
      printf 'Leaving "%s" alone (it is not managed by setup).\n' "$envfile" >&2
    fi
  fi
  snippet="${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/impulse-path.fish"
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

# Install (or repair) the launcher. Idempotent: an already-correct link
# is kept, a stale link is replaced, and a non-symlink occupant is left
# alone with a warning instead of failing the install. Every path below
# (except the foreign occupant, which returns early) converges the PATH
# drop-in too: a correct symlink must never skip it.
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
    else
      printf 'Replacing stale launcher at "%s".\n' "$link"
      rm -f -- "$link" || { echo "error: cannot remove $link" >&2; return 1; }
      ln -s "$target" "$link" || { echo "error: cannot link $link" >&2; return 1; }
      printf 'Installed global command "%s".\n' "$link"
    fi
  elif [[ -e "$link" ]]; then
    echo "warning: \"$link\" exists and is not the setup launcher; leaving it alone." >&2
    return 0
  else
    ln -s "$target" "$link" || { echo "error: cannot link $link" >&2; return 1; }
    printf 'Installed global command "%s".\n' "$link"
  fi
  # Current-process courtesy for bash callers: prepend for this process so
  # the command works immediately here. Persistence across sessions comes
  # solely from the shell integration below, never from this export (a
  # child process cannot change its parent shell's PATH).
  case ":${PATH}:" in
    *":$(dirname "$link"):"*) ;;
    *) export PATH="$(dirname "$link"):$PATH";;
  esac
  setup_shells_ensure || true
  return 0
}

# Ensure the launcher for interactive human use. Intended after a
# successful adopt/update publication: silent when already converged, one
# note when anything was repaired, warning (still rc 0) when creation
# fails so a completed deployment never fails over cosmetics. Convergent
# across the symlink AND every shell component independently: a correct
# symlink alone never skips shell integration, nor vice versa. Own machine
# only — adopting or updating a foreign tree must not touch the operator's
# bin dir. Expects DEPLOY_HOME, DEPLOY_SELF_HOME, and REPO_ROOT from the
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
  if [[ -n "$cur" && "$cur" == "$want" ]] && setup_shells_present; then
    return 0
  fi
  setup_launcher_install >/dev/null 2>&1 || true
  # Announce only what is actually true now: re-check the symlink, then
  # re-run the (idempotent, quiet-on-success) shell step to decide which
  # half of the message applies. New shell sessions are always needed;
  # nothing a child process does can change the parent shell's PATH.
  cur=""
  if [[ -L "$link" ]]; then
    cur="$(readlink -f "$link" 2>/dev/null || true)"
  fi
  if [[ -n "$cur" && "$cur" == "$want" ]]; then
    if setup_shells_ensure >/dev/null 2>&1; then
      echo -e "${STY_FAINT:-}note: installed the global 'impulse' command — new shells pick it up automatically${STY_RST:-}"
    else
      echo -e "${STY_FAINT:-}note: installed the global 'impulse' command — add ${XDG_BIN_HOME:-$HOME/.local/bin} to PATH for new shells to find it${STY_RST:-}"
    fi
  else
    echo "warning: could not install the global 'impulse' launcher; ./setup keeps working" >&2
  fi
  return 0
}

# Remove the launcher and every shell artifact, but only what the marker
# or symlink target proves is ours. Foreign occupants are never touched.
# Sweeps all shells unconditionally (a shell uninstalled since integration
# still gets cleaned).
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
  setup_shells_remove
  return 0
}
