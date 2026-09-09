# This is NOT a script for execution, but for loading functions, so NOT need execution permission or shebang.
#
# Durable user decisions for update planning (Slice 3B). A decision resolves
# one decide-class planner op for one path, fingerprinted against the exact
# fresh operation state (op + live observation + target + base). Any drift
# in those fingerprints renders the decision stale, and stale decisions
# never apply: apply re-derives every row fresh and refuses on mismatch.
# `keep`/`preserve-absence` freeze their rows (never laundered to confirmed).

# shellcheck shell=bash

DEPLOY_DECISIONS_NAME="decisions.jsonl"

# Choice allowlist per planner op. Anything else (including decisions for
# noop/write/info rows, which need none) is refused at record time.
function deploy_decide_allowed(){
  local op="$1" choice="$2" kind="${3:-file}"
  case "$op" in
    conflict-drift|drift-unchanged|drift-update|drift-moved|appeared)
      case "$choice" in
        replace|keep) return 0;;
        sidecar) [[ "$kind" == "file" ]] && return 0 || return 1;;
      esac;;
    conflict-removed|drift-removed)
      case "$choice" in reinstall|accept-removal) return 0;; esac;;
    delete-blocked)
      case "$choice" in delete|keep) return 0;; esac;;
    missing-unchanged|add-evidence)
      case "$choice" in install|preserve-absence) return 0;; esac;;
    class-changed|type-changed)
      case "$choice" in replace|keep) return 0;; esac;;
  esac
  return 1
}

declare -A DEC_D_CHOICE=() DEC_D_OP=() DEC_D_LIVE=()
declare -A DEC_D_TARGET=() DEC_D_BASE=() DEC_D_AT=()

# Load a decisions file into DEC_D_* (read-only). Absent file means no
# decisions (not an error). Duplicate paths or malformed rows refuse.
function deploy_decisions_load(){
  local file="$1" rows
  DEC_D_CHOICE=(); DEC_D_OP=(); DEC_D_LIVE=()
  DEC_D_TARGET=(); DEC_D_BASE=(); DEC_D_AT=()
  [[ -f "$file" ]] || return 0
  if ! rows=$(jq -r -s '.[] | [.path // "__MISSING__", (.choice // "__MISSING__"), (.op // "__MISSING__"), (.live // "__MISSING__"), (.target // "__MISSING__"), (.base // "__MISSING__"), (.decided_at // "__MISSING__")] | join("\t")' "$file" 2>/dev/null); then
    echo "error: decisions file is not valid JSON: $file" >&2
    return 1
  fi
  local path choice op live target base at
  while IFS=$'\t' read -r path choice op live target base at; do
    [[ -z "$path" ]] && continue
    local f
    for f in "$choice" "$op" "$live" "$target" "$base" "$at"; do
      if [[ -z "$f" || "$f" == __MISSING__ ]]; then
        echo "error: decisions file has a corrupt row" >&2
        return 1
      fi
    done
    if [[ -n "${DEC_D_CHOICE[$path]:-}" ]]; then
      echo "error: decisions file lists a path twice: $path" >&2
      return 1
    fi
    DEC_D_CHOICE[$path]="$choice"; DEC_D_OP[$path]="$op"; DEC_D_LIVE[$path]="$live"
    DEC_D_TARGET[$path]="$target"; DEC_D_BASE[$path]="$base"; DEC_D_AT[$path]="$at"
  done <<<"$rows"
}

# Match a stored decision against fresh values. Prints the choice, or
# nothing when absent/stale (both are non-errors; the caller decides).
function deploy_decisions_match(){
  local path="$1" op="$2" live="$3" target="$4" base="$5"
  local c="${DEC_D_CHOICE[$path]:-}"
  [[ -z "$c" ]] && return 0
  if [[ "${DEC_D_OP[$path]}" == "$op" && "${DEC_D_LIVE[$path]}" == "$live" && "${DEC_D_TARGET[$path]}" == "$target" && "${DEC_D_BASE[$path]}" == "$base" ]]; then
    printf '%s\n' "$c"
  fi
  return 0
}

# Record (or replace) one decision, rewriting the file atomically. The
# choice is validated against the op and manifest kind first.
function deploy_decision_record(){
  local file="$1" path="$2" choice="$3" op="$4" live="$5" target="$6" base="$7" kind="$8"
  local now="$9"
  if ! deploy_decide_allowed "$op" "$choice" "$kind"; then
    echo "error: choice '$choice' is not valid for operation '$op'" >&2
    return 1
  fi
  if ! deploy_decisions_load "$file"; then
    return 1
  fi
  DEC_D_CHOICE[$path]="$choice"; DEC_D_OP[$path]="$op"; DEC_D_LIVE[$path]="$live"
  DEC_D_TARGET[$path]="$target"; DEC_D_BASE[$path]="$base"; DEC_D_AT[$path]="$now"
  local out="" p
  local -a keys=()
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    keys+=("$p")
  done < <(printf '%s\n' "${!DEC_D_CHOICE[@]}" | LC_ALL=C sort)
  local sep=""
  for p in "${keys[@]}"; do
    out+="${sep}$(printf '{"path":"%s","choice":"%s","op":"%s","live":"%s","target":"%s","base":"%s","decided_at":"%s"}' \
      "$(deploy_json_escape "$p")" "$(deploy_json_escape "${DEC_D_CHOICE[$p]}")" "$(deploy_json_escape "${DEC_D_OP[$p]}")" \
      "$(deploy_json_escape "${DEC_D_LIVE[$p]}")" "$(deploy_json_escape "${DEC_D_TARGET[$p]}")" \
      "$(deploy_json_escape "${DEC_D_BASE[$p]}")" "$(deploy_json_escape "${DEC_D_AT[$p]}")")"
    sep=$'\n'
  done
  local tmp="$file.tmp.$$"
  deploy_write_content "$tmp" "$out"
  mv -f "$tmp" "$file"
}

# Remove one decision (strict: absent path is a typo-protection error).
function deploy_decision_remove(){
  local file="$1" path="$2"
  if ! deploy_decisions_load "$file"; then
    return 1
  fi
  if [[ -z "${DEC_D_CHOICE[$path]:-}" ]]; then
    echo "error: no decision recorded for path: $path" >&2
    return 1
  fi
  unset 'DEC_D_CHOICE[$path]' 'DEC_D_OP[$path]' 'DEC_D_LIVE[$path]'
  unset 'DEC_D_TARGET[$path]' 'DEC_D_BASE[$path]' 'DEC_D_AT[$path]'
  local out="" p
  local -a keys=()
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    keys+=("$p")
  done < <(printf '%s\n' "${!DEC_D_CHOICE[@]}" | LC_ALL=C sort)
  local sep=""
  for p in "${keys[@]}"; do
    out+="${sep}$(printf '{"path":"%s","choice":"%s","op":"%s","live":"%s","target":"%s","base":"%s","decided_at":"%s"}' \
      "$(deploy_json_escape "$p")" "$(deploy_json_escape "${DEC_D_CHOICE[$p]}")" "$(deploy_json_escape "${DEC_D_OP[$p]}")" \
      "$(deploy_json_escape "${DEC_D_LIVE[$p]}")" "$(deploy_json_escape "${DEC_D_TARGET[$p]}")" \
      "$(deploy_json_escape "${DEC_D_BASE[$p]}")" "$(deploy_json_escape "${DEC_D_AT[$p]}")")"
    sep=$'\n'
  done
  local tmp="$file.tmp.$$"
  deploy_write_content "$tmp" "$out"
  mv -f "$tmp" "$file"
}
