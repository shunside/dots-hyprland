# This is NOT a script for execution, but for loading functions, so NOT need execution permission or shebang.
#
# Read-only update planner (Slice 3A). Compares three inputs without writing
# anything anywhere (no files, no refs, no network):
#   1. baseline adoption state (manifest.jsonl + deployment-identity.json),
#   2. the current live filesystem (freshly observed, never trusted from
#      the manifest),
#   3. a locally-resolved target revision (+ effective payload inputs).
#
# Op vocabulary (TSV column 1; rollup class in parentheses):
#   noop:    unchanged, converged, gone
#   write:   update, add, delete-stale, sidecar-new
#   decide:  conflict-drift, conflict-removed, delete-blocked,
#            drift-unchanged, drift-update, drift-moved, drift-removed,
#            missing-unchanged, add-evidence, appeared, class-changed,
#            type-changed, submodule-diverged, submodule-update-available,
#            submodule-missing, submodule-drifted
#   info:    preserved, user-absent, submodule-ok, submodule-unverified,
#            retired, sidecar-pending, legacy
# Every op maps to exactly one future-apply behavior (apply / ask /
# skip / delete-with-proof); collapsing any two would destroy a
# distinction the planner is required to preserve.

# shellcheck shell=bash

# Weak legacy evidence paths, loaded read-only into PLAN_EV (one home-
# relative path per element). Batch jq parse: byte format, whitespace, and
# key order never matter. Any malformed row refuses the whole load.
declare -a PLAN_EV=()
function deploy_plan_load_evidence(){
  local file="$1" rows
  PLAN_EV=()
  if ! rows=$(jq -r -s '.[] | (.path // "__MISSING__")' "$file" 2>/dev/null); then
    echo "error: evidence file is not valid JSON: $file" >&2
    return 1
  fi
  local p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if [[ "$p" == __MISSING__ ]]; then
      echo "error: evidence file has a corrupt row" >&2
      return 1
    fi
    PLAN_EV+=("$p")
  done <<<"$rows"
}

# Fresh live-filesystem observation for one absolute disk path (stdout,
# always succeeds): file:<sha> | link:<target> | dir | absent | special |
# error:<reason>. Never trusts manifest-recorded hashes.
function deploy_plan_observe(){
  local disk="$1" t h
  if [[ -L "$disk" ]]; then
    if t=$(readlink "$disk" 2>/dev/null); then
      printf 'link:%s\n' "$t"
    else
      printf 'error:readlink\n'
    fi
    return 0
  fi
  if [[ -d "$disk" ]]; then
    printf 'dir\n'
    return 0
  fi
  if [[ -f "$disk" ]]; then
    if h=$(git -C "$REPO_ROOT" hash-object -- "$disk" 2>/dev/null); then
      printf 'file:%s\n' "$h"
    else
      printf 'error:hash\n'
    fi
    return 0
  fi
  if [[ -e "$disk" ]]; then
    printf 'special\n'
    return 0
  fi
  printf 'absent\n'
  return 0
}

# Executable-bit comparison between live file and target git mode.
# Only the owner-exec bit is compared (group/other bits are umask noise).
# Returns 0 (true) when they differ, 1 when they agree or the comparison
# does not apply (non-files, symlinks, unknown modes).
function deploy_file_mode_differs(){
  local disk="$1" t_mode="$2"
  if [[ ! -f "$disk" || -L "$disk" ]]; then
    return 1
  fi
  case "$t_mode" in
    100755)
      if [[ -x "$disk" ]]; then return 1; else return 0; fi;;
    100644)
      if [[ -x "$disk" ]]; then return 0; else return 1; fi;;
    *)
      return 1;;
  esac
}

# Submodule live observation for one absolute disk path (stdout, rc 0):
# present:<head|none> | absent | symlink
function deploy_plan_submodule_observe(){
  local disk="$1" head
  if [[ -L "$disk" ]]; then
    printf 'symlink\n'
    return 0
  fi
  if [[ -d "$disk" ]]; then
    if head=$(git -C "$disk" rev-parse HEAD 2>/dev/null); then
      printf 'present:%s\n' "$head"
    else
      printf 'present:none\n'
    fi
    return 0
  fi
  printf 'absent\n'
  return 0
}

# Manifest record stores, keyed by home-relative path. Filled by
# deploy_plan_load_state; all values are raw (unescaped) strings.
declare -A PLAN_M_CLASS=() PLAN_M_KIND=() PLAN_M_STATUS=()
declare -A PLAN_M_BLOB=() PLAN_M_DISK=() PLAN_M_REV=() PLAN_M_DETAIL=()
# Recorded submodule tree fingerprint, "" when the row predates them.
declare -A PLAN_M_FP=()
# Baseline identity values.
PLAN_BASE_REV=""
PLAN_BASE_FONTSET=""
PLAN_BASE_VIANIX="false"
PLAN_BASE_HOME=""

# Load and cross-check adoption state (read-only). Refuses on: missing or
# corrupt state, unsupported schema, mixed-revision manifest rows, or a
# comparison home that is not the recorded home root.
function deploy_plan_load_state(){
  local sd="$1"
  if ! deploy_verify_files "$sd" 2>/dev/null; then
    echo "error: adoption state at $sd is missing or inconsistent (run setup adopt --status)" >&2
    return 1
  fi
  if ! deploy_plan_load_identity "$sd/$DEPLOY_IDENTITY_NAME"; then
    return 1
  fi
  if ! deploy_plan_load_manifest_rows "$sd/$DEPLOY_MANIFEST_NAME"; then
    return 1
  fi
}

# Parse one identity file into PLAN_BASE_* (no seal checked here; callers
# that need seal integrity use deploy_verify_files or load_state first).
# Always enforces the comparison-home match.
function deploy_plan_load_identity(){
  local id="$1"
  # Identity is parsed semantically with jq in a single pass: field order,
  # whitespace, and pretty-printing must never matter for durable state.
  local idline
  if ! idline=$(jq -r '[((.schema // "__MISSING__") | tostring), (.revision // "__MISSING__"), (if has("fontset") | not then "__MISSING__" elif .fontset == null then "__NULL__" elif (.fontset | type) == "string" then .fontset else "__BAD__" end), (if .via_nix == true then "true" elif .via_nix == false then "false" else "__MISSING__" end), (.home_root // "__MISSING__")] | join("\t")' "$id" 2>/dev/null); then
    echo "error: adoption identity is not valid JSON" >&2
    return 1
  fi
  local schema rev fontset vianix homeroot
  IFS=$'\t' read -r schema rev fontset vianix homeroot <<<"$idline"
  if [[ "$schema" != "1" ]]; then
    echo "error: unsupported adoption state schema: ${schema:-(unreadable)}" >&2
    return 1
  fi
  if [[ ! "$rev" =~ ^[0-9a-f]{40}$ || -z "$homeroot" || "$homeroot" == __MISSING__ ]]; then
    echo "error: adoption identity fields missing or malformed" >&2
    return 1
  fi
  # The baseline anchor must resolve locally (it claims to be the commit
  # this machine was adopted against). Uniformity with row revs is NOT
  # required: rows advance individually across applies.
  if ! git -C "$REPO_ROOT" cat-file -e "${rev}^{commit}" 2>/dev/null; then
    echo "error: adoption baseline revision does not resolve: $rev" >&2
    return 1
  fi
  case "$fontset" in
    __NULL__) fontset="";;
    __MISSING__|__BAD__|'') echo "error: adoption identity fontset malformed" >&2; return 1;;
  esac
  if [[ "$vianix" != "true" && "$vianix" != "false" ]]; then
    echo "error: adoption identity via_nix malformed" >&2
    return 1
  fi
  local canon_home
  if ! canon_home=$(cd "$DEPLOY_HOME" 2>/dev/null && pwd -P); then
    echo "error: cannot resolve comparison home" >&2
    return 1
  fi
  if [[ "$canon_home" != "$homeroot" ]]; then
    echo "error: comparison home $canon_home != adopted home $homeroot; refusing to plan against foreign state" >&2
    return 1
  fi
  PLAN_BASE_REV="$rev"; PLAN_BASE_FONTSET="$fontset"; PLAN_BASE_VIANIX="$vianix"; PLAN_BASE_HOME="$homeroot"
}

# Parse one manifest file into PLAN_M_* (no seal checked here). Every row
# must be well-formed with locally resolvable revisions; per-row revisions
# stay authoritative (partial advancement is normal).
function deploy_plan_load_manifest_rows(){
  local mf="$1"
  PLAN_M_CLASS=(); PLAN_M_KIND=(); PLAN_M_STATUS=()
  PLAN_M_BLOB=(); PLAN_M_DISK=(); PLAN_M_REV=(); PLAN_M_DETAIL=()
  PLAN_M_FP=()
  declare -A SEEN_REV=()
  # Manifest rows are parsed semantically in one jq pass (same byte-format
  # freedom as the identity). Empty or missing fields are corrupt rows.
  # Captured first: flags set inside process substitution stay in a
  # subshell and never propagate, so jq failure is detected here.
  local mrows
  if ! mrows=$(jq -r -s '.[] | [.path // "__MISSING__", .kind // "__MISSING__", .class // "__MISSING__", .status // "__MISSING__", .blob // "__MISSING__", (if has("disk") | not then "__MISSING__" elif .disk == null then "null" elif (.disk | type) == "string" then .disk else "__MISSING__" end), .rev // "__MISSING__", (if has("detail") | not then "__MISSING__" elif .detail == "" then "-" else .detail end), (if has("fingerprint") | not then "__MISSING__" elif .fingerprint == null then "__MISSING__" elif (.fingerprint | type) == "string" then .fingerprint else "__MISSING__" end)] | join("\t")' "$mf" 2>/dev/null); then
    echo "error: manifest is not valid JSON" >&2
    return 1
  fi
  local mrow
  # NOTE: `read` with an all-whitespace IFS (tab) silently SKIPS empty
  # middle fields, shifting later columns left. The writer therefore never
  # emits empty fields (quiet details stay "-"), and the reader below must
  # still tolerate legacy "" details from existing manifests.
  while IFS=$'\t' read -r path kind class status blob disk rowrev detail fp; do
    [[ -z "$path" ]] && continue
    if [[ -z "$path" || "$path" == __MISSING__ || -z "$kind" || "$kind" == __MISSING__ || -z "$class" || "$class" == __MISSING__ || -z "$status" || "$status" == __MISSING__ || -z "$blob" || "$blob" == __MISSING__ || -z "$rowrev" || "$rowrev" == __MISSING__ ]]; then
      echo "error: manifest has a corrupt row" >&2
      return 1
    fi
    if [[ "$disk" != "null" && ( -z "$disk" || "$disk" == __MISSING__ ) ]]; then
      echo "error: manifest row without disk: $path" >&2
      return 1
    fi
    # Detail is informational-only (never drives a decision). The jq
    # extraction above normalizes legacy "" to "-", so an empty or
    # __MISSING__ value here is genuinely corrupt. (Rationale: `read`
    # with an all-whitespace IFS skips empty middle fields, so no
    # TSV column may ever be legitimately empty.)
    if [[ -z "$detail" || "$detail" == __MISSING__ ]]; then
      echo "error: manifest row without detail: $path" >&2
      return 1
    fi
    # Per-row revisions are authoritative: partial advancement across
    # applies is normal, so uniformity is not required. Every pinned
    # revision must still resolve locally (else the row is unverifiable).
    if [[ -z "${SEEN_REV[$rowrev]:-}" ]]; then
      if ! git -C "$REPO_ROOT" cat-file -e "${rowrev}^{commit}" 2>/dev/null; then
        echo "error: manifest row pins unresolvable revision: $path -> $rowrev" >&2
        return 1
      fi
      SEEN_REV[$rowrev]=1
    fi
    # Fingerprint is optional (rows predating it simply lack the field);
    # "__MISSING__" normalizes to "" meaning unrecorded.
    if [[ "$fp" == __MISSING__ ]]; then fp=""; fi
    PLAN_M_CLASS[$path]="$class"; PLAN_M_KIND[$path]="$kind"; PLAN_M_STATUS[$path]="$status"
    PLAN_M_BLOB[$path]="$blob"; PLAN_M_DISK[$path]="$disk"; PLAN_M_REV[$path]="$rowrev"
    PLAN_M_DETAIL[$path]="$detail"; PLAN_M_FP[$path]="$fp"
  done <<<"$mrows"
}

# Target payload stores, keyed by home-relative path. Filled by
# deploy_plan_load_target from the target revision's registry + object store.
declare -A PLAN_T_CLASS=() PLAN_T_BLOB=() PLAN_T_MODE=()
# Gitlinks found in the target payload (path -> commit SHA).
declare -A PLAN_T_SUB=()
# Target payload paths skipped as deliberately undeployed under the
# effective inputs (swapped-away fontset/via-nix sources). Reported in the
# summary so the omission is visible, never silent.
declare -a PLAN_T_EXCLUDED=()

# Load the target payload image (read-only). Prints `lint: ...` problems to
# stderr and returns 1 when the target cannot be fully classified; the
# caller must then refuse the plan (a partial plan is worse than none).
function deploy_plan_load_target(){
  local sha="$1"
  PLAN_T_CLASS=(); PLAN_T_BLOB=(); PLAN_T_MODE=(); PLAN_T_SUB=()
  PLAN_T_EXCLUDED=()
  if ! deploy_load_registry "$sha"; then
    return 1
  fi
  local lint_out lint_rc=0
  lint_out=$(deploy_lint_registry "$sha" 2>&1) || lint_rc=$?
  if (( lint_rc != 0 )); then
    echo "error: target registry fails lint; refusing to plan:" >&2
    while IFS= read -r l; do echo "  $l" >&2; done <<<"$lint_out"
    return 1
  fi
  local -a roots=()
  mapfile -t roots < <(deploy_enum_roots)
  local bad=0
  local rec meta path mode ftype blob
  while IFS= read -r -d '' rec; do
    if [[ "$rec" != *$'\t'* ]]; then
      echo "error: bad ls-tree record in target image" >&2
      bad=1
      continue
    fi
    meta="${rec%%$'\t'*}"
    path="${rec#*$'\t'}"
    read -r mode ftype blob <<<"$meta" || true
    if [[ "$path" == *$'\n'* || "$path" == *$'\t'* ]]; then
      echo "error: unsupported filename in target image" >&2
      bad=1
      continue
    fi
    local lookup rule_idx scope hrel
    if ! lookup=$(deploy_lookup_rule "$path"); then
      # Swapped-away sources are deliberately undeployed, not unclassified.
      local sw s_src found=false
      for sw in ${DEPLOY_SWAPPED_OUT[@]+"${DEPLOY_SWAPPED_OUT[@]}"}; do
        IFS='|' read -r s_src _s_home _s_class _s_inp <<<"$sw"
        if [[ "$path" == "$s_src" || "$path" == "$s_src"/* ]]; then found=true; break; fi
      done
      if [[ "$found" != true ]]; then
        echo "error: target payload path matches no rule: $path" >&2
        bad=1
      else
        PLAN_T_EXCLUDED+=("$path")
      fi
      continue
    fi
    IFS=$'\t' read -r rule_idx scope hrel <<<"$lookup"
    local class="${DEPLOY_R_CLASS[$rule_idx]}"
    if [[ "$scope" == "excluded" ]]; then
      class="user"
    fi
    if [[ "$ftype" == "commit" ]]; then
      PLAN_T_SUB[$hrel]="$blob"
      PLAN_T_CLASS[$hrel]="$class"
      PLAN_T_MODE[$hrel]="160000"
      continue
    fi
    if [[ "$ftype" != "blob" ]]; then
      echo "error: unsupported git type in target image: $path ($ftype)" >&2
      bad=1
      continue
    fi
    PLAN_T_CLASS[$hrel]="$class"
    PLAN_T_BLOB[$hrel]="$blob"
    PLAN_T_MODE[$hrel]="$mode"
  done < <(git -C "$REPO_ROOT" ls-tree -r -z "$sha" -- "${roots[@]}" || true)
  if (( bad != 0 )); then
    return 1
  fi
  return 0
}

# Evidence home-paths with prior-management provenance (weak-only or
# overlapping), for the novelty check below. Filled by deploy_plan_compute
# BEFORE rows are decided: a target addition with any prior evidence is
# NOT pure novelty and must never auto-add.
declare -A PLAN_EVSET=()

# Computed plan rows (sorted, no header/comments). Filled by
# deploy_plan_compute; consumed by plan display and apply preflight alike
# so both always decide identically.
declare -a DEPLOY_PLAN_ROWS=()
declare -a DEPLOY_PLAN_EVID=()

# Compute the full fresh plan into DEPLOY_PLAN_ROWS / DEPLOY_PLAN_EVID.
# Args: state dir (evidence source of truth when present there, else the
# XDG default path). Requires: state loaded, target loaded, DEPLOY_HOME
# and DEPLOY_XDG_CONFIG set. Read-only. Exit 1 internal failure, 2 when
# evidence is malformed (refusal, like any unclassifiable input).
function deploy_plan_compute(){
  local sd="$1"
  DEPLOY_PLAN_ROWS=()
  DEPLOY_PLAN_EVID=()
  PLAN_EVSET=()
  # Evidence first: the novelty check inside row decisions needs prior
  # provenance before any row is classified.
  local ev_src="${DEPLOY_XDG_CONFIG}/illogical-impulse/${DEPLOY_EVIDENCE_NAME}"
  if [[ -f "${sd}/${DEPLOY_EVIDENCE_NAME}" ]]; then
    ev_src="${sd}/${DEPLOY_EVIDENCE_NAME}"
  fi
  local ev_have=false
  if [[ -f "$ev_src" ]]; then
    if ! deploy_plan_load_evidence "$ev_src"; then
      return 2
    fi
    ev_have=true
    local ep
    for ((i = 0; i < ${#PLAN_EV[@]}; i++)); do
      ep="${PLAN_EV[$i]}"
      PLAN_EVSET[$ep]=1
    done
  fi
  declare -A UNION_ALL=()
  local p=""
  for p in "${!PLAN_M_STATUS[@]}"; do UNION_ALL[$p]=1; done
  for p in "${!PLAN_T_CLASS[@]}" "${!PLAN_T_SUB[@]}"; do UNION_ALL[$p]=1; done
  local -a sorted=()
  if (( ${#UNION_ALL[@]} > 0 )); then
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      sorted+=("$p")
    done < <(printf '%s\n' "${!UNION_ALL[@]}" | LC_ALL=C sort)
  fi
  local row
  for p in "${sorted[@]}"; do
    if ! row=$(deploy_plan_path "$p"); then
      echo "error: decision failed for $p" >&2
      return 1
    fi
    [[ -z "$row" ]] && continue
    DEPLOY_PLAN_ROWS+=("$row")
  done
  if [[ "$ev_have" != true ]]; then
    return 0
  fi
  local ev_path overlap ev_disk ev_live ev_blob ev_row i
  for ((i = 0; i < ${#PLAN_EV[@]}; i++)); do
    ev_path="${PLAN_EV[$i]}"
    overlap="weak-only"
    if [[ -n "${PLAN_M_STATUS[$ev_path]:-}" ]]; then overlap="also-in-manifest"; fi
    if [[ -n "${PLAN_T_CLASS[$ev_path]:-}" || -n "${PLAN_T_SUB[$ev_path]:-}" ]]; then
      if [[ "$overlap" == "weak-only" ]]; then overlap="also-in-target"; else overlap="also-in-manifest+target"; fi
    fi
    ev_disk=""; ev_live="unknown"
    if ev_disk=$(deploy_map_home "$ev_path" 2>/dev/null); then
      ev_live=$(deploy_plan_observe "$ev_disk")
    fi
    ev_blob="-"
    if [[ -n "${PLAN_T_BLOB[$ev_path]:-}" ]]; then ev_blob="${PLAN_T_BLOB[$ev_path]}"; fi
    printf -v ev_row 'legacy\t-\t%s\t-\t-\t%s\t%s\t%s;informational-only-never-an-op' "$ev_path" "$ev_blob" "$ev_live" "$overlap"
    DEPLOY_PLAN_EVID+=("$ev_row")
  done
}
# Prints TSV: op \t class \t path \t base-blob \t base-disk \t target-blob \t live \t detail
# (`-` for not-applicable; live is a fresh observation, never manifest data).
function deploy_plan_path(){
  local path="$1"
  local m_status="${PLAN_M_STATUS[$path]:-}" m_class="${PLAN_M_CLASS[$path]:-}"
  local m_blob="${PLAN_M_BLOB[$path]:-}" m_disk="${PLAN_M_DISK[$path]:-}"
  local m_kind="${PLAN_M_KIND[$path]:-}"
  local t_class="${PLAN_T_CLASS[$path]:-}" t_blob="${PLAN_T_BLOB[$path]:-}"
  local t_sub="${PLAN_T_SUB[$path]:-}"
  local disk
  if ! disk=$(deploy_map_home "$path" 2>/dev/null); then
    printf 'error\t%s\t%s\t%s\t%s\t%s\t-\thome-map-failed\n' "${m_class:--}" "$path" "${m_blob:--}" "${m_disk:--}" "${t_blob:--}"
    return 0
  fi

  # --- Submodule paths (content unprovable offline; gitlink + presence).
  # A matched pair compares gitlinks. Anything else is structural:
  # unrecorded-but-targeted is a new dependency (add/appeared), and a
  # file<->submodule swap either way is a type change — silently swapping
  # a file for a checkout (or the reverse) would destroy data.
  if [[ "$m_kind" == "submodule" && -n "$t_sub" ]]; then
    deploy_plan_submodule_row "$path" "$disk" "$m_blob" "$t_sub" "${m_class:-managed}" "${m_disk:--}"
    return 0
  fi
  if [[ -z "$m_status" && -n "$t_sub" ]]; then
    local obs_new
    obs_new=$(deploy_plan_submodule_observe "$disk")
    if [[ "$obs_new" == "absent" ]]; then
      printf 'add\t%s\t%s\t-\t-\t%s\tabsent\tsubmodule-init-required\n' "${t_class:-managed}" "$path" "$t_sub"
    else
      printf 'appeared\t%s\t%s\t-\t-\t%s\t%s\tnew-submodule-content-unverifiable\n' "${t_class:-managed}" "$path" "$t_sub" "$obs_new"
    fi
    return 0
  fi
  if [[ "$m_kind" == "submodule" ]]; then
    # Target dropped the submodule entirely: retire in place or gone.
    # (A target-side file at this path is handled by the type-change
    # branch below only when a file blob actually exists there.)
    if [[ -z "$t_blob" ]]; then
      deploy_plan_submodule_row "$path" "$disk" "$m_blob" "" "${m_class:-managed}" "${m_disk:--}"
      return 0
    fi
  fi
  if [[ -n "$t_sub" ]]; then
    # Manifest file record, target gitlink: a file<->submodule swap.
    local live_tc
    live_tc=$(deploy_plan_observe "$disk")
    printf 'type-changed\t%s\t%s\t%s\t%s\t%s\t%s\tkind-file-vs-submodule\n' "${m_class:-${t_class:-managed}}" "$path" "${m_blob:--}" "${m_disk:--}" "$t_sub" "$live_tc"
    return 0
  fi
  if [[ "$m_kind" == "submodule" ]]; then
    # Manifest submodule record, target regular file.
    local live_tc2
    live_tc2=$(deploy_plan_observe "$disk")
    printf 'type-changed\t%s\t%s\t%s\t%s\t%s\t%s\tkind-submodule-vs-file\n' "${m_class:-managed}" "$path" "${m_blob:--}" "${m_disk:--}" "${t_blob:--}" "$live_tc2"
    return 0
  fi

  # --- User-managed target paths (informational only, never applied).
  if [[ -n "$t_class" && "$t_class" == "user" && -z "$m_status" ]]; then
    if [[ -e "$disk" || -L "$disk" ]]; then
      printf 'preserved\tuser\t%s\t-\t-\t-\t-\tuser-managed-left-alone\n' "$path"
    else
      printf 'user-absent\tuser\t%s\t-\t-\t-\t-\tuser-managed-not-present\n' "$path"
    fi
    return 0
  fi

  local live
  live=$(deploy_plan_observe "$disk")

  # --- No manifest record: genuinely new target payload (or nothing at all).
  if [[ -z "$m_status" ]]; then
    if [[ -z "$t_blob" ]]; then
      return 0  # In neither baseline nor target: invisible by design.
    fi
    if [[ "${PLAN_T_MODE[$path]:-}" == "120000" && "$live" == link:* ]]; then
      local t_link_new
      if ! t_link_new=$(git -C "$REPO_ROOT" cat-file -p "$t_blob" 2>/dev/null); then
        printf 'error\t%s\t%s\t-\t-\t%s\t%s\tblob-unreadable\n' "$t_class" "$path" "$t_blob" "$live"
        return 0
      fi
      if [[ "${live#link:}" == "$t_link_new" ]]; then
        printf 'converged\t%s\t%s\t-\t-\t%s\t%s\tunrecorded-symlink-at-target\n' "$t_class" "$path" "$t_blob" "$live"
      else
        printf 'appeared\t%s\t%s\t-\t-\t%s\t%s\tunrecorded-present-differs\n' "$t_class" "$path" "$t_blob" "$live"
      fi
      return 0
    fi
    case "$t_class/$live" in
      managed/absent)
        # Pure novelty auto-adds; any prior (weak) evidence means the
        # absence may be intentional and forces an explicit decision.
        if [[ -n "${PLAN_EVSET[$path]:-}" ]]; then
          printf 'add-evidence\tmanaged\t%s\t-\t-\t%s\tabsent\tweak-prior-evidence;decision-required\n' "$path" "$t_blob"
        else
          printf 'add\tmanaged\t%s\t-\t-\t%s\tabsent\t-\n' "$path" "$t_blob"
        fi;;
      sidecar/absent) printf 'sidecar-new\tsidecar\t%s\t-\t-\t%s\tabsent\twill-deliver-.new-only\n' "$path" "$t_blob";;
      */absent)
        if [[ -n "${PLAN_EVSET[$path]:-}" ]]; then
          printf 'add-evidence\t%s\t%s\t-\t-\t%s\tabsent\tweak-prior-evidence;decision-required\n' "$t_class" "$path" "$t_blob"
        else
          printf 'add\t%s\t%s\t-\t-\t%s\tabsent\t-\n' "$t_class" "$path" "$t_blob"
        fi;;
      *)
        if [[ "$live" == "file:$t_blob" ]]; then
          printf 'converged\t%s\t%s\t-\t-\t%s\t%s\tunrecorded-already-at-target\n' "$t_class" "$path" "$t_blob" "$live"
        else
          printf 'appeared\t%s\t%s\t-\t-\t%s\t%s\tunrecorded-present-differs\n' "$t_class" "$path" "$t_blob" "$live"
        fi
        ;;
    esac
    return 0
  fi

  # --- Manifest record exists: sanity-check its own consistency first.
  # A `confirmed` row whose recorded disk hash is not the blob was never a
  # valid confirmation (tampered or buggy manifest): distrust, never apply.
  # Symlink rows carry no disk hash by design (adoption stores null), so
  # they are validated explicitly instead of exempted: the live link must
  # resolve right now to the recorded baseline target. Anything else
  # (retargeted, dangling, replaced) is drift, decided downstream.
  if [[ "$m_status" == "confirmed" && "$m_kind" == "symlink" ]]; then
    local base_target live_target
    if ! base_target=$(git -C "$REPO_ROOT" cat-file -p "$m_blob" 2>/dev/null); then
      printf 'error\t%s\t%s\t%s\t%s\t%s\t%s\tblob-unreadable\n' "$m_class" "$path" "$m_blob" "$m_disk" "${t_blob:--}" "$live"
      return 0
    fi
    if [[ "$live" == link:* ]] && [[ "${live#link:}" == "$base_target" ]]; then
      : # freshly validated: live link identity equals the baseline target
    else
      printf 'conflict-drift\t%s\t%s\t%s\t%s\t%s\t%s\tsymlink-target-differs-from-baseline\n' "$m_class" "$path" "$m_blob" "$m_disk" "${t_blob:--}" "$live"
      return 0
    fi
  elif [[ "$m_status" == "confirmed" && "$m_disk" != "$m_blob" ]]; then
    printf 'conflict-drift\t%s\t%s\t%s\t%s\t%s\t%s\tbaseline-record-inconsistent\n' "$m_class" "$path" "$m_blob" "$m_disk" "${t_blob:--}" "$live"
    return 0
  fi

  # --- Class changed between baseline and target: never auto-resolve.
  if [[ -n "$t_blob" && -n "$t_class" && "$t_class" != "$m_class" ]]; then
    printf 'class-changed\t%s\t%s\t%s\t%s\t%s\t%s\t%s-to-%s\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live" "$m_class" "$t_class"
    return 0
  fi

  # --- Target dropped the path.
  if [[ -z "$t_blob" ]]; then
    # Delivered .new rows are terminal review state, never stale: a
    # matching live file stays pending, a consumed one drops its row.
    if [[ "$m_status" == "sidecar-delivered" ]]; then
      if [[ "$live" == "absent" ]]; then
        printf 'gone\t%s\t%s\t%s\t%s\t-\tabsent\t-\n' "$m_class" "$path" "$m_blob" "$m_disk"
      elif [[ "$live" == "file:$m_blob" ]]; then
        printf 'sidecar-pending\t%s\t%s\t%s\t%s\t-\t%s\tunder-review-untouched\n' "$m_class" "$path" "$m_blob" "$m_disk" "$live"
      else
        printf 'sidecar-pending\t%s\t%s\t%s\t%s\t-\t%s\tuser-modified-untouched\n' "$m_class" "$path" "$m_blob" "$m_disk" "$live"
      fi
      return 0
    fi
    case "$m_class" in
      sidecar)
        if [[ "$live" == "absent" ]]; then
          printf 'gone\tsidecar\t%s\t%s\t%s\t-\tabsent\t-\n' "$path" "$m_blob" "$m_disk"
        else
          printf 'retired\tsidecar\t%s\t%s\t%s\t-\t%s\tpayload-dropped-user-copy-kept\n' "$path" "$m_blob" "$m_disk" "$live"
        fi
        return 0
        ;;
      user)
        printf 'preserved\tuser\t%s\t%s\t%s\t-\t%s\tuser-managed-left-alone\n' "$path" "$m_blob" "$m_disk" "$live"
        return 0
        ;;
    esac
    case "$m_status" in
      confirmed)
        if [[ "$live" == "file:$m_blob" ]]; then
          printf 'delete-stale\tmanaged\t%s\t%s\t%s\t-\t%s\tproven-managed-untouched\n' "$path" "$m_blob" "$m_disk" "$live"
        elif [[ "$live" == "absent" ]]; then
          printf 'gone\tmanaged\t%s\t%s\t%s\t-\tabsent\t-\n' "$path" "$m_blob" "$m_disk"
        else
          printf 'delete-blocked\tmanaged\t%s\t%s\t%s\t-\t%s\tmanaged-but-live-differs\n' "$path" "$m_blob" "$m_disk" "$live"
        fi
        ;;
      drifted)
        if [[ "$live" == "absent" ]]; then
          printf 'gone\tmanaged\t%s\t%s\t%s\t-\tabsent\t-\n' "$path" "$m_blob" "$m_disk"
        else
          printf 'delete-blocked\tmanaged\t%s\t%s\t%s\t-\t%s\tunresolved-baseline-never-delete\n' "$path" "$m_blob" "$m_disk" "$live"
        fi
        ;;
      missing)
        if [[ "$live" == "absent" ]]; then
          printf 'gone\t%s\t%s\t%s\t%s\t-\tabsent\t-\n' "$m_class" "$path" "$m_blob" "$m_disk"
        else
          printf 'appeared\t%s\t%s\t%s\t%s\t-\t%s\tappeared-after-missing-payload-dropped\n' "$m_class" "$path" "$m_blob" "$m_disk" "$live"
        fi
        ;;
    esac
    return 0
  fi

  # --- Blob kind transitions involving symlinks (file<->symlink).
  # Unlike submodule swaps (unverifiable content, missing machinery), these
  # auto-apply exactly when live provably equals the baseline side (the
  # destroyed bytes are then known repo bytes); any local divergence is a
  # decision. Symlink rows never carry a recorded disk hash (adoption stores
  # null), so drifted-link stasis cannot be proven and stays conservative.
  if [[ "$m_kind" == "symlink" || "${PLAN_T_MODE[$path]:-}" == "120000" ]]; then
    deploy_plan_link_row "$path" "$disk" "$live"
    return 0
  fi

  # --- Target has the path (same class): the three-way core.
  # live-on-target short-circuit first: nothing to write either way, except
  # executable-bit flips (content-identical mode changes still need chmod).
  if [[ "$live" == "file:$t_blob" ]]; then
    if [[ "$m_status" == "confirmed" && "$m_blob" == "$t_blob" ]]; then
      if deploy_file_mode_differs "$disk" "${PLAN_T_MODE[$path]:-100644}"; then
        printf 'update\t%s\t%s\t%s\t%s\t%s\t%s\tmode-change-only\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live"
      else
        printf 'unchanged\t%s\t%s\t%s\t%s\t%s\t%s\t-\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live"
      fi
    else
      if deploy_file_mode_differs "$disk" "${PLAN_T_MODE[$path]:-100644}"; then
        printf 'update\t%s\t%s\t%s\t%s\t%s\t%s\tmode-change-only\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live"
      else
        printf 'converged\t%s\t%s\t%s\t%s\t%s\t%s\tlive-already-at-target\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live"
      fi
    fi
    return 0
  fi
  case "$m_status" in
    confirmed)
      if [[ "$live" == "absent" ]]; then
        printf 'conflict-removed\t%s\t%s\t%s\t%s\t%s\tabsent\tconfirmed-but-deleted-locally\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob"
      elif [[ "$live" == "file:$m_blob" ]]; then
        printf 'update\t%s\t%s\t%s\t%s\t%s\t%s\tclean-update\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live"
      else
        printf 'conflict-drift\t%s\t%s\t%s\t%s\t%s\t%s\tlive-differs-from-baseline\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live"
      fi
      ;;
    drifted)
      if [[ "$live" == "absent" ]]; then
        printf 'drift-removed\t%s\t%s\t%s\t%s\t%s\tabsent\tdrifted-now-absent\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob"
      elif [[ "$live" == "file:$m_disk" && "$m_disk" != "-" && "$m_disk" != "null" ]]; then
        if [[ "$t_blob" == "$m_blob" ]]; then
          printf 'drift-unchanged\t%s\t%s\t%s\t%s\t%s\t%s\tstill-drifted-as-adopted\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live"
        else
          printf 'drift-update\t%s\t%s\t%s\t%s\t%s\t%s\trepo-moved-under-static-drift\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live"
        fi
      elif [[ "$live" == "file:$m_blob" ]]; then
        printf 'update\t%s\t%s\t%s\t%s\t%s\t%s\tdrift-resolved-live-matches-baseline\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live"
      else
        printf 'drift-moved\t%s\t%s\t%s\t%s\t%s\t%s\tlive-moved-since-adoption\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live"
      fi
      ;;
    missing)
      if [[ "$live" == "absent" ]]; then
        printf 'missing-unchanged\t%s\t%s\t%s\t%s\t%s\tabsent\tstill-to-install\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob"
      else
        printf 'appeared\t%s\t%s\t%s\t%s\t%s\t%s\tappeared-after-missing-baseline\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live"
      fi
      ;;
    present)
      # Submodule rows never reach here (handled above); anything else
      # with status `present` is a corrupt manifest.
      printf 'error\t%s\t%s\t%s\t%s\t%s\t%s\tunexpected-present-status\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live"
      ;;
  esac
}

# Blob kind transitions involving symlinks. Args: path, disk, live observation.
# Reads the manifest/target assocs. Only ever auto-applies (as `update`)
# when live provably equals the baseline side; every other divergence is a
# decision row. Statuses keep their adoption meaning throughout.
function deploy_plan_link_row(){
  local path="$1" disk="$2" live="$3"
  local m_status="${PLAN_M_STATUS[$path]}" m_class="${PLAN_M_CLASS[$path]}"
  local m_blob="${PLAN_M_BLOB[$path]}" m_disk="${PLAN_M_DISK[$path]}"
  local m_kind="${PLAN_M_KIND[$path]}" t_blob="${PLAN_T_BLOB[$path]}"
  local t_mode="${PLAN_T_MODE[$path]:-}"
  local m_link="" t_link="" live_link="" live_file=""
  [[ "$live" == link:* ]] && live_link="${live#link:}"
  [[ "$live" == file:* ]] && live_file="${live#file:}"
  if [[ "$m_kind" == "symlink" ]]; then
    if ! m_link=$(git -C "$REPO_ROOT" cat-file -p "$m_blob" 2>/dev/null); then
      printf 'error\t%s\t%s\t%s\t%s\t%s\t%s\tblob-unreadable\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live"
      return 0
    fi
  fi
  if [[ "$t_mode" == "120000" ]]; then
    if ! t_link=$(git -C "$REPO_ROOT" cat-file -p "$t_blob" 2>/dev/null); then
      printf 'error\t%s\t%s\t%s\t%s\t%s\t%s\tblob-unreadable\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live"
      return 0
    fi
  fi
  # Live absent first: same conservatism as the byte core.
  if [[ "$live" == "absent" ]]; then
    case "$m_status" in
      confirmed) printf 'conflict-removed\t%s\t%s\t%s\t%s\t%s\tabsent\tconfirmed-but-deleted-locally\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob";;
      drifted) printf 'drift-removed\t%s\t%s\t%s\t%s\t%s\tabsent\tdrifted-now-absent\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob";;
      *) printf 'missing-unchanged\t%s\t%s\t%s\t%s\t%s\tabsent\tstill-to-install\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob";;
    esac
    return 0
  fi
  if [[ "$m_kind" != "symlink" && "$t_mode" != "120000" ]]; then
    printf 'error\t%s\t%s\t%s\t%s\t%s\t%s\tlink-row-without-link\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live"
    return 0
  fi
  # Live already at target.
  if [[ -n "$live_link" && "$live_link" == "$t_link" && "$t_mode" == "120000" ]]; then
    if [[ "$m_kind" == "symlink" && "$m_link" == "$t_link" && "$m_status" == "confirmed" ]]; then
      printf 'unchanged\t%s\t%s\t%s\t%s\t%s\t%s\t-\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live"
    else
      printf 'converged\t%s\t%s\t%s\t%s\t%s\t%s\tlive-already-at-target\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live"
    fi
    return 0
  fi
  if [[ -n "$live_file" && "$live_file" == "$t_blob" && "$t_mode" != "120000" ]]; then
    if [[ "$m_status" == "confirmed" && "$m_kind" != "symlink" && "$m_blob" == "$t_blob" ]]; then
      if deploy_file_mode_differs "$disk" "$t_mode"; then
        printf 'update\t%s\t%s\t%s\t%s\t%s\t%s\tmode-change-only\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live"
      else
        printf 'unchanged\t%s\t%s\t%s\t%s\t%s\t%s\t-\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live"
      fi
    else
      if deploy_file_mode_differs "$disk" "$t_mode"; then
        printf 'update\t%s\t%s\t%s\t%s\t%s\t%s\tmode-change-only\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live"
      else
        printf 'converged\t%s\t%s\t%s\t%s\t%s\t%s\tlive-already-at-target\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live"
      fi
    fi
    return 0
  fi
  # Live matches the baseline side: the transition destroys only known bytes.
  if [[ "$m_kind" != "symlink" && -n "$live_file" && "$live_file" == "$m_blob" ]]; then
    case "$m_status" in
      confirmed) printf 'update\t%s\t%s\t%s\t%s\t%s\t%s\tfile-to-symlink-clean\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live";;
      drifted) printf 'update\t%s\t%s\t%s\t%s\t%s\t%s\tdrift-resolved-file-to-symlink\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live";;
      *) printf 'appeared\t%s\t%s\t%s\t%s\t%s\t%s\tappeared-after-missing-baseline\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live";;
    esac
    return 0
  fi
  if [[ "$m_kind" == "symlink" && -n "$live_link" && "$live_link" == "$m_link" ]]; then
    case "$m_status" in
      confirmed) printf 'update\t%s\t%s\t%s\t%s\t%s\t%s\tsymlink-to-file-clean\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live";;
      drifted) printf 'update\t%s\t%s\t%s\t%s\t%s\t%s\tdrift-resolved-symlink-to-file\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live";;
      *) printf 'appeared\t%s\t%s\t%s\t%s\t%s\t%s\tappeared-after-missing-baseline\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live";;
    esac
    return 0
  fi
  # Anything else: local content the transition would destroy is unknown.
  case "$m_status" in
    confirmed) printf 'conflict-drift\t%s\t%s\t%s\t%s\t%s\t%s\tkind-transition-with-local-drift\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live";;
    drifted) printf 'drift-moved\t%s\t%s\t%s\t%s\t%s\t%s\tkind-transition-with-local-drift\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live";;
    *) printf 'appeared\t%s\t%s\t%s\t%s\t%s\t%s\tappeared-after-missing-baseline\n' "$m_class" "$path" "$m_blob" "$m_disk" "$t_blob" "$live";;
  esac
}

# Submodule op rows. Comparable inputs, honestly bounded: the two gitlink
# SHAs (baseline record vs target payload) plus local presence and an
# observed submodule HEAD when metadata exists (usually `none` on
# rsync-deployed machines). Content itself is never claimed proven.
function deploy_plan_submodule_row(){
  local path="$1" disk="$2" gitlink_b="$3" gitlink_t="$4" class="${5:-managed}" b_disk="${6:--}"
  local obs sub_head="none" moved="same"
  obs=$(deploy_plan_submodule_observe "$disk")
  if [[ "$obs" == present:* ]]; then
    sub_head="${obs#present:}"
  fi
  # Dropped from the target payload: directories are never deleted, so a
  # present checkout is retired in place (informational), never removed.
  if [[ -z "$gitlink_t" ]]; then
    if [[ "$obs" == "absent" ]]; then
      printf 'gone\t%s\t%s\t%s\t%s\t-\tabsent\t-\n' "$class" "$path" "${gitlink_b:--}" "$b_disk"
    else
      printf 'retired\t%s\t%s\t%s\t%s\t-\t%s\tpayload-dropped-dir-left-alone\n' "$class" "$path" "${gitlink_b:--}" "$b_disk" "$obs"
    fi
    return 0
  fi
  if [[ -n "$gitlink_b" && "$gitlink_b" != "$gitlink_t" ]]; then
    moved="moved"
  fi
  case "$obs/$moved" in
    absent/*)
      printf 'submodule-missing\t%s\t%s\t%s\t%s\t%s\tabsent\tgitlink=%s\n' "$class" "$path" "${gitlink_b:--}" "$b_disk" "$gitlink_t" "$gitlink_t"
      ;;
    symlink/*)
      printf 'submodule-missing\t%s\t%s\t%s\t%s\t%s\tsymlink\tsymlink-not-followed\n' "$class" "$path" "${gitlink_b:--}" "$b_disk" "$gitlink_t"
      ;;
    */moved)
      printf 'submodule-update-available\t%s\t%s\t%s\t%s\t%s\t%s\tgitlink-%s-to-%s;content-unprovable-offline\n' "$class" "$path" "${gitlink_b:--}" "$b_disk" "$gitlink_t" "$obs" "${gitlink_b:--}" "$gitlink_t"
      ;;
    *)
      if [[ "$sub_head" != "none" && "$sub_head" != "$gitlink_t" ]]; then
        printf 'submodule-diverged\t%s\t%s\t%s\t%s\t%s\t%s\tchecked-out-head-differs-from-target\n' "$class" "$path" "${gitlink_b:--}" "$b_disk" "$gitlink_t" "$obs"
        return 0
      fi
      # Gitlink stable and directory present: the recorded tree fingerprint
      # is self-anchored: it never proves equality with the upstream
      # commit, only changed/unchanged since the last observation.
      local recorded="${PLAN_M_FP[$path]:-}" livefp=""
      if livefp=$(deploy_submodule_fingerprint "$disk" 2>/dev/null); then
        if [[ -z "$recorded" ]]; then
          printf 'submodule-unverified\t%s\t%s\t%s\t%s\t%s\t%s\tno-recorded-fingerprint;establish-on-apply\n' "$class" "$path" "${gitlink_b:--}" "$b_disk" "$gitlink_t" "$obs"
        elif [[ "$livefp" == "$recorded" ]]; then
          printf 'submodule-ok\t%s\t%s\t%s\t%s\t%s\t%s\tfingerprint-match;content-still-unanchored\n' "$class" "$path" "${gitlink_b:--}" "$b_disk" "$gitlink_t" "$obs"
        else
          printf 'submodule-drifted\t%s\t%s\t%s\t%s\t%s\t%s\tcontent-changed-since-observation\n' "$class" "$path" "${gitlink_b:--}" "$b_disk" "$gitlink_t" "$obs"
        fi
      else
        printf 'submodule-drifted\t%s\t%s\t%s\t%s\t%s\t%s\tfingerprint-unavailable\n' "$class" "$path" "${gitlink_b:--}" "$b_disk" "$gitlink_t" "$obs"
      fi
      ;;
  esac
}
