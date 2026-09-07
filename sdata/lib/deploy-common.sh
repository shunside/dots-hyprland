# This is NOT a script for execution, but for loading functions, so NOT need execution permission or shebang.
#
# Read-only foundation of the safe-update deployment system (Slice 1).
#
# Provides: target-revision resolution, ownership-registry loading, and
# adoption dry-run classification. Uses ONLY non-mutating git verbs
# (rev-parse, cat-file, ls-tree, show, log, hash-object without -w).
# Nothing here writes to disk, the network, refs, index, or worktree.
#
# Callers must set REPO_ROOT (repository root), DEPLOY_HOME (home root the
# live machine is compared against), DEPLOY_XDG_CONFIG and DEPLOY_XDG_DATA
# (config/data base dirs, mirroring sdata/lib/environment-variables.sh).

# shellcheck shell=bash

DEPLOY_REGISTRY_PATH="sdata/deploy/ownership.conf"
DEPLOY_PAYLOAD_ROOTS=(dots/.config dots/.local/share)

declare -a DEPLOY_R_CLASS=()
declare -a DEPLOY_R_SRC=()
declare -a DEPLOY_R_HOME=()
declare -a DEPLOY_R_EXCL=()
DEPLOY_FONTSET_NOTE=""
DEPLOY_VIANIX_NOTE=""
# Swapped-away rule sources ("repo-src|home-prefix|rule-class|input-name").
# Payload under these prefixes is deliberately undeployed under the current
# inputs: it classifies as `input-excluded`, never `unclassified`.
declare -a DEPLOY_SWAPPED_OUT=()

# Resolve a user-supplied revision spec to a full commit SHA (stdout).
# Accepts HEAD (incl. detached), full/abbreviated SHAs, branches, tags, and
# remote-tracking refs. Purely local: never fetches, never touches the
# checkout. Fails on empty specs, leading dashes, and unresolvable names.
function deploy_resolve_revision(){
  local spec="${1:-}"
  if [[ -z "$spec" ]]; then
    echo "error: empty revision spec" >&2
    return 1
  fi
  case "$spec" in
    -*) echo "error: revision spec must not start with '-': $spec" >&2; return 1;;
  esac
  local sha
  if ! sha=$(git -C "$REPO_ROOT" rev-parse --verify --quiet "${spec}^{commit}"); then
    echo "error: cannot resolve revision spec (not a commit, branch, tag, or known ref): $spec" >&2
    return 1
  fi
  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "error: unexpected revision resolution output" >&2
    return 1
  fi
  printf '%s\n' "$sha"
}

# Load the ownership registry as stored IN the target revision (never from
# the worktree) into DEPLOY_R_* arrays. Then applies payload source swaps
# for install inputs that change the desired payload (fontset, via-nix),
# mirroring 3.files-legacy.sh behavior.
function deploy_load_registry(){
  local sha="$1"
  DEPLOY_R_CLASS=()
  DEPLOY_R_SRC=()
  DEPLOY_R_HOME=()
  DEPLOY_R_EXCL=()
  DEPLOY_SWAPPED_OUT=()
  DEPLOY_FONTSET_NOTE=""
  DEPLOY_VIANIX_NOTE=""
  local content
  if ! content=$(git -C "$REPO_ROOT" show "${sha}:${DEPLOY_REGISTRY_PATH}" 2>/dev/null); then
    echo "error: registry ${DEPLOY_REGISTRY_PATH} not present at revision $sha" >&2
    return 1
  fi
  local line lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%%#*}"
    local -a parts=()
    # read (not unquoted expansion) splits without pathname expansion,
    # so registry patterns containing `*` survive verbatim.
    IFS=$' \t' read -r -a parts <<<"$line"
    if [[ ${#parts[@]} -eq 0 ]]; then
      continue
    fi
    if [[ ${#parts[@]} -lt 3 ]]; then
      echo "error: registry line $lineno: need at least <class> <repo-prefix> <home-prefix>" >&2
      return 1
    fi
    local class="${parts[0]}" src="${parts[1]}" home="${parts[2]}"
    case "$class" in
      managed|user|sidecar) ;;
      *) echo "error: registry line $lineno: unknown class '$class'" >&2; return 1;;
    esac
    case "$home" in
      .config/*|.local/share/*) ;;
      *) echo "error: registry line $lineno: home-prefix must start with .config/ or .local/share/" >&2; return 1;;
    esac
    local -a excl_list=()
    local p
    for p in "${parts[@]:3}"; do
      case "$p" in
        !*) excl_list+=("${p#!}");;
        *) echo "error: registry line $lineno: excludes must look like '!pattern', got '$p'" >&2; return 1;;
      esac
    done
    DEPLOY_R_CLASS+=("$class")
    DEPLOY_R_SRC+=("$src")
    DEPLOY_R_HOME+=("$home")
    if [[ ${#excl_list[@]} -gt 0 ]]; then
      DEPLOY_R_EXCL+=("$(printf '%s\n' "${excl_list[@]}")")
    else
      DEPLOY_R_EXCL+=("")
    fi
  done <<<"$content"
  if [[ ${#DEPLOY_R_SRC[@]} -eq 0 ]]; then
    echo "error: registry at revision $sha contains no rules" >&2
    return 1
  fi
  if ! deploy_apply_source_swaps "$sha"; then
    return 1
  fi
}

# Rewrite rule sources for install inputs that change the desired payload.
# Exactly two scalars, mirroring install flags 1:1 (no profile framework):
# FONTSET_DIR_NAME (--fontset) swaps the fontconfig source, INSTALL_VIA_NIX
# (--via-nix) swaps the hypridle.conf source. Both are recorded in the
# deployment identity, so revision SHA alone is never the whole identity.
function deploy_apply_source_swaps(){
  local sha="$1" i
  if [[ -n "${FONTSET_DIR_NAME:-}" ]]; then
    local new_src="dots-extra/fontsets/${FONTSET_DIR_NAME}"
    if ! git -C "$REPO_ROOT" cat-file -e "${sha}:${new_src}" 2>/dev/null; then
      echo "error: FONTSET_DIR_NAME='${FONTSET_DIR_NAME}' not present at revision $sha" >&2
      return 1
    fi
    local swapped=false
    for i in "${!DEPLOY_R_SRC[@]}"; do
      if [[ "${DEPLOY_R_SRC[$i]}" == "dots/.config/fontconfig" ]]; then
        DEPLOY_SWAPPED_OUT+=("dots/.config/fontconfig|${DEPLOY_R_HOME[$i]}|${DEPLOY_R_CLASS[$i]}|fontset")
        DEPLOY_R_SRC[$i]="$new_src"
        swapped=true
      fi
    done
    if [[ "$swapped" == true ]]; then
      DEPLOY_FONTSET_NOTE="fontconfig source swapped to ${new_src} (FONTSET_DIR_NAME)"
    fi
  fi
  if [[ "${INSTALL_VIA_NIX:-false}" == "true" ]]; then
    local new_idle="dots-extra/via-nix/hypridle.conf"
    if ! git -C "$REPO_ROOT" cat-file -e "${sha}:${new_idle}" 2>/dev/null; then
      echo "error: via-nix hypridle source not present at revision $sha" >&2
      return 1
    fi
    local swapped_idle=false
    for i in "${!DEPLOY_R_SRC[@]}"; do
      if [[ "${DEPLOY_R_SRC[$i]}" == "dots/.config/hypr/hypridle.conf" ]]; then
        DEPLOY_SWAPPED_OUT+=("dots/.config/hypr/hypridle.conf|${DEPLOY_R_HOME[$i]}|${DEPLOY_R_CLASS[$i]}|via-nix")
        DEPLOY_R_SRC[$i]="$new_idle"
        swapped_idle=true
      fi
    done
    if [[ "$swapped_idle" == true ]]; then
      DEPLOY_VIANIX_NOTE="hypridle.conf source swapped to ${new_idle} (INSTALL_VIA_NIX)"
    fi
  fi
}

# Longest-prefix registry lookup for a repo-relative payload path (stdout):
# "<rule-index>\texcluded\t" when an exclude matched, or
# "<rule-index>\tincluded\t<home-relative-path>".
# Returns 1 when no rule matches. Excluded paths are reported as user class
# by the caller.
function deploy_lookup_rule(){
  local p="$1"
  local best=-1 bestlen=-1 i src
  for i in "${!DEPLOY_R_SRC[@]}"; do
    src="${DEPLOY_R_SRC[$i]}"
    if [[ "$p" == "$src" || "$p" == "$src"/* ]]; then
      if (( ${#src} > bestlen )); then
        best=$i
        bestlen=${#src}
      fi
    fi
  done
  if (( best < 0 )); then
    return 1
  fi
  local rel=""
  if [[ "$p" != "${DEPLOY_R_SRC[$best]}" ]]; then
    rel="${p:$((bestlen + 1))}"
  fi
  local hrel="${DEPLOY_R_HOME[$best]}"
  if [[ -n "$rel" ]]; then
    hrel="${hrel}/${rel}"
  fi
  local excl_block="${DEPLOY_R_EXCL[$best]}" e
  if [[ -n "$excl_block" ]]; then
    while IFS= read -r e; do
      [[ -z "$e" ]] && continue
      if [[ "$rel" == "$e" || "$rel" == "$e"/* ]]; then
        printf '%s\texcluded\t%s\n' "$best" "$hrel"
        return 0
      fi
    done <<<"$excl_block"
  fi
  printf '%s\tincluded\t%s\n' "$best" "$hrel"
}

# Map a home-relative path (e.g. .config/hypr/hyprland.lua) to an absolute
# path under DEPLOY_HOME via the XDG bases. Refuses results escaping home.
function deploy_map_home(){
  local hrel="$1" base rest abs
  case "$hrel" in
    .config/*) base="${DEPLOY_XDG_CONFIG}"; rest="${hrel#.config/}";;
    .local/share/*) base="${DEPLOY_XDG_DATA}"; rest="${hrel#.local/share/}";;
    *) echo "error: cannot map home-relative path: $hrel" >&2; return 1;;
  esac
  abs="${base}/${rest}"
  case "$abs" in
    "${DEPLOY_HOME}"/*) printf '%s\n' "$abs";;
    *) echo "error: mapped path escapes home root: $abs" >&2; return 1;;
  esac
}

# Read-only three-way building block: compare one blob against one disk path.
# Stdout: "<verdict>\t<disk-sha-or-->\t<detail>"; verdict is one of
# match|differ|absent|error. `git hash-object` runs without -w: pure hashing.
function deploy_compare(){
  local blob="$1" bmode="$2" disk="$3"
  local target diskt disksha
  if [[ -L "$disk" ]]; then
    if [[ ! -e "$disk" ]]; then
      if [[ "$bmode" != "120000" ]]; then
        printf 'differ\t-\tdangling-symlink-on-disk\n'
        return 0
      fi
      if ! target=$(git -C "$REPO_ROOT" cat-file -p "$blob" 2>/dev/null); then
        printf 'error\t-\tblob-unreadable\n'
        return 0
      fi
      if ! diskt=$(readlink "$disk" 2>/dev/null); then
        printf 'error\t-\treadlink-failed\n'
        return 0
      fi
      if [[ "$diskt" == "$target" ]]; then
        printf 'match\t-\t-\n'
      else
        printf 'differ\t-\tdangling-symlink-target-differs\n'
      fi
      return 0
    fi
    if [[ "$bmode" == "120000" ]]; then
      if ! target=$(git -C "$REPO_ROOT" cat-file -p "$blob" 2>/dev/null); then
        printf 'error\t-\tblob-unreadable\n'
        return 0
      fi
      if ! diskt=$(readlink "$disk" 2>/dev/null); then
        printf 'error\t-\treadlink-failed\n'
        return 0
      fi
      if [[ "$diskt" == "$target" ]]; then
        printf 'match\t-\t-\n'
      else
        printf 'differ\t-\tsymlink-target-differs\n'
      fi
    else
      printf 'differ\t-\tsymlink-on-disk\n'
    fi
    return 0
  fi
  if [[ -d "$disk" ]]; then
    printf 'differ\t-\tdir-on-disk\n'
    return 0
  fi
  if [[ -f "$disk" ]]; then
    if [[ "$bmode" == "120000" ]]; then
      printf 'differ\t-\tfile-for-symlink\n'
      return 0
    fi
    if ! disksha=$(git -C "$REPO_ROOT" hash-object -- "$disk" 2>/dev/null); then
      printf 'error\t-\thash-failed\n'
      return 0
    fi
    if [[ "$disksha" == "$blob" ]]; then
      printf 'match\t%s\t-\n' "$disksha"
    else
      printf 'differ\t%s\tcontent-differs\n' "$disksha"
    fi
    return 0
  fi
  if [[ -e "$disk" ]]; then
    printf 'differ\t-\tspecial-on-disk\n'
    return 0
  fi
  printf 'absent\t-\t-\n'
}

# Default 1:1 home mapping for payload paths outside any rule. Hint only:
# it implies no ownership and drives no decision; it merely keeps
# `unclassified` rows from being misread as "not on disk".
function deploy_default_home(){
  local p="$1"
  case "$p" in
    dots/.config/*) printf '.config/%s\n' "${p#dots/.config/}";;
    dots/.local/share/*) printf '.local/share/%s\n' "${p#dots/.local/share/}";;
    *) return 1;;
  esac
}

# Classify every payload file at revision <sha> against the live filesystem.
# Stdout is TSV (comment lines start with `#`):
#   state \t class \t path \t blob \t disk \t detail \t mode
# `path` is home-relative when a rule mapped it, else `repo:<repo-path>`.
# `mode` is the blob mode (100644/100755/120000/160000) or `-`.
# States keep observed baseline strictly separate from confirmed deployment:
# adoptable = matches baseline (may later become a confirmed managed record);
# drifted/missing = unresolved adoption state, implying nothing about who
# wrote the live content; preserved/user-absent = user-managed, never touch.
function deploy_classify(){
  local sha="$1"
  if ! git -C "$REPO_ROOT" cat-file -e "${sha}^{commit}" 2>/dev/null; then
    echo "error: not a resolvable commit: $sha" >&2
    return 1
  fi
  printf '# deploy-adopt-dryrun\trev=%s\n' "$sha"
  printf '# state\tclass\tpath\tblob\tdisk\tdetail\tmode\n'
  local rec meta path mode ftype blob
  local -a roots=()
  mapfile -t roots < <(deploy_enum_roots)
  while IFS= read -r -d '' rec; do
    if [[ "$rec" != *$'\t'* ]]; then
      printf 'error\t-\trepo:?\t-\t-\tbad-ls-tree-record\t-\n'
      continue
    fi
    meta="${rec%%$'\t'*}"
    path="${rec#*$'\t'}"
    read -r mode ftype blob <<<"$meta"
    if [[ "$path" == *$'\n'* || "$path" == *$'\t'* ]]; then
      printf 'error\t-\trepo:unsupported-filename\t-\t-\tnewline-or-tab-in-name\t-\n'
      continue
    fi
    local lookup rule_idx scope hrel
    if ! lookup=$(deploy_lookup_rule "$path"); then
      # Swapped-away source: deliberately undeployed under the current
      # install inputs (fontset/via-nix). Reported, never deployed, and
      # never confused with registry incompleteness.
      local sw s_src s_home s_class s_inp s_rel s_hrel s_abs s_hint
      for sw in ${DEPLOY_SWAPPED_OUT[@]+"${DEPLOY_SWAPPED_OUT[@]}"}; do
        IFS='|' read -r s_src s_home s_class s_inp <<<"$sw"
        if [[ "$path" == "$s_src" || "$path" == "$s_src"/* ]]; then
          if [[ "$path" != "$s_src" ]]; then s_rel="${path:$((${#s_src} + 1))}"; else s_rel=""; fi
          s_hrel="$s_home"
          if [[ -n "$s_rel" ]]; then s_hrel="${s_hrel}/${s_rel}"; fi
          s_hint="disk-unknown"
          if s_abs=$(deploy_map_home "$s_hrel" 2>/dev/null); then
            if [[ -e "$s_abs" || -L "$s_abs" ]]; then s_hint="disk-present"; else s_hint="disk-absent"; fi
          fi
          printf 'input-excluded\t%s\t%s\t%s\t-\tinput:%s;%s\t%s\n' "$s_class" "$s_hrel" "$blob" "$s_inp" "$s_hint" "$mode"
          continue 2
        fi
      done
      local dhint="disk-unknown" drel dabs
      if drel=$(deploy_default_home "$path") && dabs=$(deploy_map_home "$drel" 2>/dev/null); then
        if [[ -e "$dabs" || -L "$dabs" ]]; then dhint="disk-present"; else dhint="disk-absent"; fi
      fi
      printf 'unclassified\t-\trepo:%s\t%s\t-\tno-registry-rule;%s\t%s\n' "$path" "$blob" "$dhint" "$mode"
      continue
    fi
    IFS=$'\t' read -r rule_idx scope hrel <<<"$lookup"
    local class="${DEPLOY_R_CLASS[$rule_idx]}"
    if [[ "$scope" == "excluded" ]]; then
      class="user"
    fi
    if [[ "$ftype" == "commit" ]]; then
      # Gitlink: content lives outside the superproject object store, so blob
      # hashes can never verify it. Policy (see submodule audit): record
      # presence explicitly instead of ignoring it. A present directory is
      # recorded with the expected gitlink SHA plus the locally observed
      # submodule HEAD (or none when no usable git metadata exists, which is
      # the normal case for rsync-deployed checkouts). Absence is recorded as
      # unresolved, never auto-fixed. Neither state gates adoption; the
      # remediation (submodule init / quickshell reinstall step) is documented
      # in the dry-run output, not left as an unexplained manual step.
      local sub_disp sub_disk sub_head="none"
      if ! sub_disp=$(deploy_map_home_fallback "$path" "$hrel"); then
        printf 'error\t%s\trepo:%s\t%s\t-\t-\thome-map-failed\t%s\n' "$class" "$path" "$blob" "$mode"
        continue
      fi
      if ! sub_disk=$(deploy_map_home "$hrel" 2>/dev/null); then
        printf 'error\t%s\trepo:%s\t%s\t-\t-\thome-map-failed\t%s\n' "$class" "$path" "$blob" "$mode"
        continue
      fi
      if [[ -L "$sub_disk" ]]; then
        printf 'submodule-present\t%s\t%s\t%s\t-\t%s\tsymlink-not-followed\t%s\n' "$class" "$sub_disp" "$blob" "$mode"
        continue
      fi
      if [[ -d "$sub_disk" ]]; then
        sub_head=$(git -C "$sub_disk" rev-parse HEAD 2>/dev/null || echo "none")
        printf 'submodule-present\t%s\t%s\t%s\t-\t%s\tgitlink=%s head=%s\t%s\n' "$class" "$sub_disp" "$blob" "$mode" "$blob" "$sub_head" "$mode"
      else
        printf 'submodule-missing\t%s\t%s\t%s\t-\t%s\tgitlink=%s\t%s\n' "$class" "$sub_disp" "$blob" "$mode" "$blob" "$mode"
      fi
      continue
    fi
    if [[ "$ftype" != "blob" ]]; then
      printf 'error\t%s\trepo:%s\t%s\t-\t-\tunsupported-git-type:%s\t%s\n' "$class" "$path" "$blob" "$ftype" "$mode"
      continue
    fi
    local disk
    if ! disk=$(deploy_map_home "$hrel"); then
      printf 'error\t%s\trepo:%s\t%s\t-\t-\thome-map-failed\t%s\n' "$class" "$path" "$blob" "$mode"
      continue
    fi
    if [[ "$class" == "user" ]]; then
      if [[ -e "$disk" || -L "$disk" ]]; then
        printf 'preserved\tuser\t%s\t%s\t-\tuser-managed-left-alone\t%s\n' "$hrel" "$blob" "$mode"
      else
        printf 'user-absent\tuser\t%s\t%s\t-\tuser-managed-not-present\t%s\n' "$hrel" "$blob" "$mode"
      fi
      continue
    fi
    local cmp verdict disksha detail
    cmp=$(deploy_compare "$blob" "$mode" "$disk")
    IFS=$'\t' read -r verdict disksha detail <<<"$cmp"
    case "$class/$verdict" in
      managed/match) printf 'adoptable\tmanaged\t%s\t%s\t%s\t-\t%s\n' "$hrel" "$blob" "$disksha" "$mode";;
      managed/differ) printf 'drifted\tmanaged\t%s\t%s\t%s\t%s\t%s\n' "$hrel" "$blob" "$disksha" "$detail" "$mode";;
      managed/absent) printf 'missing\tmanaged\t%s\t%s\t-\t-\t%s\n' "$hrel" "$blob" "$mode";;
      sidecar/match) printf 'sidecar-clean\tsidecar\t%s\t%s\t%s\t-\t%s\n' "$hrel" "$blob" "$disksha" "$mode";;
      sidecar/differ) printf 'sidecar-drifted\tsidecar\t%s\t%s\t%s\t%s\t%s\n' "$hrel" "$blob" "$disksha" "$detail" "$mode";;
      sidecar/absent) printf 'sidecar-missing\tsidecar\t%s\t%s\t-\t-\t%s\n' "$hrel" "$blob" "$mode";;
      */error) printf 'error\t%s\t%s\t%s\t%s\t%s\t%s\n' "$class" "$hrel" "$blob" "$disksha" "$detail" "$mode";;
      *) printf 'error\t%s\t%s\t%s\t%s\tinternal-state:%s/%s\t%s\n' "$class" "$hrel" "$blob" "$disksha" "$class" "$verdict" "$mode";;
    esac
  done < <(git -C "$REPO_ROOT" ls-tree -r -z "$sha" -- "${roots[@]}")
}

# Helper: prefer the mapped home-relative path for display, fall back to the
# repo path when mapping fails (never fails the row itself).
function deploy_map_home_fallback(){
  local repo_path="$1" hrel="$2" abs
  if abs=$(deploy_map_home "$hrel" 2>/dev/null); then
    printf '%s\n' "$hrel"
  else
    printf 'repo:%s\n' "$repo_path"
  fi
  return 0
}

# Enumeration roots for payload listing: the fixed payload roots plus any
# rule source outside them (e.g. swapped-in fontset/via-nix overlays under
# dots-extra/). Without this, swapped-in files would never be classified.
function deploy_enum_roots(){
  local r i src inside
  declare -A seen=()
  for r in "${DEPLOY_PAYLOAD_ROOTS[@]}"; do
    if [[ -z "${seen[$r]:-}" ]]; then seen[$r]=1; printf '%s\n' "$r"; fi
  done
  for i in "${!DEPLOY_R_SRC[@]}"; do
    src="${DEPLOY_R_SRC[$i]}"
    inside=false
    for r in "${DEPLOY_PAYLOAD_ROOTS[@]}"; do
      if [[ "$src" == "$r" || "$src" == "$r"/* ]]; then inside=true; break; fi
    done
    if [[ "$inside" != true && -z "${seen[$src]:-}" ]]; then
      seen[$src]=1
      printf '%s\n' "$src"
    fi
  done
}
# Prints `lint: ...` findings to stderr; returns 0 only when the registry is
# internally valid and covers the payload structurally:
# - no two rules declare the same repo-prefix (silent shadowing);
# - every rule matches at least one payload path (dead rules would hide
#   typos and payload renames instead of forcing deliberate updates).
# Per-path coverage (zero unclassified rows) is enforced by the caller from
# the classification output, where disk context is available.
# Lint the loaded registry against the payload at <sha> (read-only).
function deploy_lint_registry(){
  local sha="$1"
  local problems=0 i
  declare -A seen_src=()
  for i in "${!DEPLOY_R_SRC[@]}"; do
    if [[ -n "${seen_src[${DEPLOY_R_SRC[$i]}]:-}" ]]; then
      echo "lint: duplicate repo-prefix: ${DEPLOY_R_SRC[$i]}" >&2
      problems=$((problems + 1))
    else
      seen_src[${DEPLOY_R_SRC[$i]}]=1
    fi
  done
  declare -a hits=()
  for i in "${!DEPLOY_R_SRC[@]}"; do hits[$i]=0; done
  local p
  local -a roots=()
  mapfile -t roots < <(deploy_enum_roots)
  while IFS= read -r -d '' p; do
    local best=-1 bestlen=-1 j src
    for j in "${!DEPLOY_R_SRC[@]}"; do
      src="${DEPLOY_R_SRC[$j]}"
      if [[ "$p" == "$src" || "$p" == "$src"/* ]]; then
        if (( ${#src} > bestlen )); then best=$j; bestlen=${#src}; fi
      fi
    done
    if (( best >= 0 )); then hits[$best]=$((hits[$best] + 1)); fi
  done < <(git -C "$REPO_ROOT" ls-tree -r -z --name-only "$sha" -- "${roots[@]}")
  for i in "${!DEPLOY_R_SRC[@]}"; do
    if (( hits[$i] == 0 )); then
      echo "lint: dead rule (matches no payload path): ${DEPLOY_R_CLASS[$i]} ${DEPLOY_R_SRC[$i]}" >&2
      problems=$((problems + 1))
    fi
  done
  if (( problems > 0 )); then return 1; fi
  return 0
}
