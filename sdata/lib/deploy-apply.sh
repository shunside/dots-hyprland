# This is NOT a script for execution, but for loading functions, so NOT need execution permission or shebang.
#
# Write-capable deployment engine (Slice 3B). Applies a fresh, fully gated
# plan to the live filesystem with snapshot-first, journaled, idempotent
# per-path operations and atomic end publication.
#
# Hard rules (see design notes where each is enforced):
# - preflight completes before the first deployed-file mutation;
# - every decide row needs a valid fingerprinted decision (stored or
#   ephemeral), otherwise the whole apply is refused before mutating;
# - fail-fast: the first unexpected failure/TOCTOU/integrity problem stops
#   all further mutation; resume/abort are explicit and separate;
# - unknown paths are never touched; directories are never rm -rf'd;
# - manifest advances only from verified resulting state; identity (with
#   derived deployed_revision/fully_deployed) publishes last;
# - a stale lock never implies a discardable transaction: --break-lock
#   releases the mutex only, journal state still governs.
#
# Durability model: process-crash resilience is structural (atomic renames,
# replay-tolerant journal, classifying status). OS-crash/power-loss is
# mitigated best-effort with `sync` after the journal header and after
# final publication; no stronger claim is made (no fsync syscalls from
# bash, no database). Torn journal tails truncate at the last valid line;
# torn manifest/identity combinations classify as abort-only, never valid.

# shellcheck shell=bash

DEPLOY_APPLIES_NAME="applies"
DEPLOY_SNAPS_NAME="snapshots"
DEPLOY_LOCK_NAME="apply.lock"

# PID for lock ownership and crash simulation. BASHPID is the real pid even
# inside subshells (test harnesses drive lib entries in subshells sharing
# $$ with the parent); $$ alone would attribute every subshell lock to the
# still-alive parent and make dead-lock detection untestable. NOTE: never
# capture this pid via command substitution [$(...)] — the subshell inside
# $() has its own transient BASHPID. Expand ${BASHPID:-$$} directly.

# Test-only fault injection (never set in production). Values:
#   die-after:<phase>    kill -KILL self (realistic crash; lock remains)
#   fail-after:<phase>   graceful failure at the phase boundary
#   mutate:<rel>:<bytes> rewrite one live file once, right after the
#                        internal plan (TOCTOU simulation)
# Phases: lock, snapshot, header, pre-ops, op:<N> (before Nth plan row),
# publish-manifest, publish-identity.
function deploy_fault(){
  local phase="$1" spec="${DEPLOY_TEST_FAULT:-}" rest
  [[ -z "$spec" ]] && return 0
  case "$spec" in
    die-after:"$phase")
      echo "fault: simulated crash after $phase" >&2
      # Direct expansion (no $()): command substitution would fork a
      # transient subshell with its own BASHPID to kill.
      kill -KILL "${BASHPID:-$$}";;
    fail-after:"$phase")
      echo "fault: simulated failure after $phase" >&2
      return 1;;
  esac
  if [[ "$phase" == "pre-ops" && "$spec" == mutate:* ]]; then
    rest="${spec#mutate:}"
    local rel="${rest%%:*}" content="${rest#*:}"
    printf '%s\n' "$content" > "${DEPLOY_HOME}/${rel}"
    echo "fault: mutated live file $rel" >&2
  fi
  return 0
}

# --- Lock (mutex only; never decides transaction fate). ---
function deploy_lock_path(){ printf '%s/%s\n' "$1" "$DEPLOY_LOCK_NAME"; }

function deploy_lock_acquire(){
  local sd="$1" id="$2" lock pid oldid
  lock=$(deploy_lock_path "$sd")
  if [[ -f "$lock" ]]; then
    pid=$(awk '{print $1}' "$lock" 2>/dev/null || echo "?")
    oldid=$(awk '{print $2}' "$lock" 2>/dev/null || echo "?")
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      echo "error: apply $oldid already running (pid $pid); refusing" >&2
      return 1
    fi
    echo "error: stale lock from $oldid (pid $pid dead); transaction state still governs — resume/abort it, or --break-lock to release only the mutex" >&2
    return 1
  fi
  local line
  # Direct expansion (no $()): see the BASHPID note above.
  line="${BASHPID:-$$} $id $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ! { set -o noclobber; printf '%s\n' "$line" > "$lock"; } 2>/dev/null; then
    set +o noclobber
    echo "error: lost lock race for $id; refusing" >&2
    return 1
  fi
  set +o noclobber
}

function deploy_lock_break(){
  local sd="$1" lock pid
  lock=$(deploy_lock_path "$sd")
  if [[ ! -f "$lock" ]]; then
    echo "no lock present in $sd"
    return 0
  fi
  pid=$(awk '{print $1}' "$lock" 2>/dev/null || echo "?")
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    echo "error: lock holder pid $pid is alive; refusing to break" >&2
    return 1
  fi
  rm -f "$lock"
  echo "warning: cleared dead lock (pid $pid); open transaction state, if any, still requires resume/abort" >&2
}

# --- Journal (JSONL, one object per line; tail may tear on crash). ---
function deploy_journal_file(){ printf '%s/%s/%s/journal.jsonl\n' "$1" "$DEPLOY_APPLIES_NAME" "$2"; }

function deploy_journal_append(){
  printf '%s\n' "$2" >> "$1"
}

# Validate a journal: prints "ok <seqs>" or "torn <valid-prefix-lines>".
# A torn tail (partial last line) is expected after crashes, not corruption.
function deploy_journal_check(){
  local file="$1" n=0 line
  [[ -f "$file" ]] || { echo "missing"; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if ! jq -e . >/dev/null 2>&1 <<<"$line"; then
      echo "torn $n"
      return 0
    fi
    n=$((n + 1))
  done < "$file"
  echo "ok $n"
  return 0
}

function deploy_journal_completed(){
  # Only a complete outcome closes the transaction. A failed completion
  # marker (legacy/buggy writers) must still count as open so resume/abort
  # can recover; never treat it as steady state.
  grep -q '"type":"completed"' "$1" 2>/dev/null && grep -q '"outcome":"complete"' "$1" 2>/dev/null
}

function deploy_journal_aborted(){
  grep -q '"type":"aborted"' "$1" 2>/dev/null
}

function deploy_journal_header_field(){
  jq -r -s "map(select(.type==\"header\")) | .[0].$2 // empty" "$1" 2>/dev/null
}

# --- Snapshot helpers. ---
function deploy_snap_dir(){ printf '%s/%s/%s\n' "$1" "$DEPLOY_SNAPS_NAME" "$2"; }

# Snapshot one live path (best-effort no-op when absent; absent needs no
# bytes, the journal pre-line records it). Preserves exact bytes, link
# targets, and modes (cp -p/-P).
function deploy_snapshot_path(){
  local snapfiles="$1" home="$2" rel="$3"
  local src="$home/$rel" dst="$snapfiles/$rel"
  if [[ -L "$src" ]]; then
    mkdir -p "$(dirname "$dst")" || return 1
    cp -P -- "$src" "$dst" || return 1
  elif [[ -f "$src" ]]; then
    mkdir -p "$(dirname "$dst")" || return 1
    cp -p -- "$src" "$dst" || return 1
  elif [[ -e "$src" ]]; then
    echo "error: cannot snapshot special live path: $rel" >&2
    return 1
  fi
  return 0
}

# --- Disk estimator. Pure math over caller-measured bytes (unit-testable);
# the df wrapper below supplies availability.
function deploy_estimate_required(){
  local snapshot_bytes="$1" write_bytes="$2" rows="$3"
  local total=$((snapshot_bytes + write_bytes + rows * 4096 + 1048576))
  printf '%s\n' $((total + total / 10))
}

function deploy_check_space(){
  local home="$1" statedir="$2" required="$3"
  local dev_h dev_s
  dev_h=$(stat -c %d "$home" 2>/dev/null) || { echo "error: cannot stat home filesystem" >&2; return 1; }
  dev_s=$(stat -c %d "$statedir" 2>/dev/null) || { echo "error: cannot stat state filesystem" >&2; return 1; }
  if ! deploy_check_one "$home" "$required"; then
    return 1
  fi
  if [[ "$dev_s" != "$dev_h" ]]; then
    # Distinct filesystems: conservatively require the full estimate on
    # each (snapshot lands on state fs, writes on home fs; overestimates
    # rather than risking ENOSPC mid-transaction).
    if ! deploy_check_one "$statedir" "$required"; then
      return 1
    fi
  fi
}

function deploy_check_one(){
  local path="$1" required="$2" avail_kb
  if ! avail_kb=$(df -k --output=avail "$path" 2>/dev/null | tail -n 1 | tr -d '[:space:]'); then
    echo "error: cannot measure free space under $path" >&2
    return 1
  fi
  if [[ -n "${DEPLOY_TEST_DF_AVAIL:-}" ]]; then
    avail_kb="$DEPLOY_TEST_DF_AVAIL"
  fi
  if [[ ! "$avail_kb" =~ ^[0-9]+$ ]]; then
    echo "error: cannot parse free space under $path" >&2
    return 1
  fi
  if (( avail_kb * 1024 < required )); then
    echo "error: insufficient space under $path: need ~${required}B, have $((avail_kb * 1024))B" >&2
    return 1
  fi
}

# --- Op executors. Each prints its post-state observation on success
# (file:<sha> | link:<target> | absent) and returns nonzero on any
# unexpected condition. Callers re-observe independently where it matters;
# these never delete directories and never follow symlinks destructively.
# mkdir lines consume their own journal seq (callers pass APPLY_OP_N by
# reference via the global): reusing the previous seq would duplicate the
# header/op numbering and confuse resume's max-seq continuation.
function deploy_op_mkdir_parents(){
  local disk="$1" journal="$2" d
  d=$(dirname "$disk")
  if [[ ! -d "$d" ]]; then
    if ! mkdir -p "$d"; then
      echo "error: cannot create parent dir: $d" >&2
      return 1
    fi
    APPLY_OP_N=$((APPLY_OP_N + 1))
    deploy_journal_append "$journal" "$(printf '{"seq":%s,"type":"mkdir","path":"%s"}' "$APPLY_OP_N" "$d")"
  fi
}

# Write blob bytes to disk atomically (same-dir temp + rename). Target git
# mode is authoritative (100755 -> 0755, else 0644); temp starts 0600 so no
# window exposes wrong permissions. Prints post hash.
function deploy_op_write_file(){
  local disk="$1" blob="$2" mode="$3" tag="$4"
  local tmp="$disk.tmp.$tag" want_mode="0644" h
  if [[ "$mode" == "100755" ]]; then want_mode="0755"; fi
  : > "$tmp" || { echo "error: cannot create temp file: $tmp" >&2; return 1; }
  chmod 0600 "$tmp"
  if ! git -C "$REPO_ROOT" cat-file -p "$blob" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "error: cannot materialize blob $blob" >&2
    return 1
  fi
  chmod "$want_mode" "$tmp"
  if ! h=$(git -C "$REPO_ROOT" hash-object -- "$tmp" 2>/dev/null); then
    rm -f "$tmp"
    echo "error: cannot hash staged file" >&2
    return 1
  fi
  mv -f "$tmp" "$disk" || { rm -f "$tmp"; echo "error: cannot rename into place: $disk" >&2; return 1; }
  printf 'file:%s\n' "$h"
}

# Replace disk with a symlink atomically. Refuses when live is a directory:
# directories are never removed recursively by this engine.
function deploy_op_write_link(){
  local disk="$1" target="$2" tag="$3"
  local tmp="$disk.tmp.$tag" t
  if [[ -d "$disk" && ! -L "$disk" ]]; then
    echo "error: live directory blocks symlink replacement (manual): $disk" >&2
    return 1
  fi
  rm -f "$tmp"
  if ! ln -s "$target" "$tmp" 2>/dev/null; then
    echo "error: cannot stage symlink: $tmp" >&2
    return 1
  fi
  mv -f -T "$tmp" "$disk" 2>/dev/null || mv -f "$tmp" "$disk" || { rm -f "$tmp"; echo "error: cannot rename link into place: $disk" >&2; return 1; }
  if ! t=$(readlink "$disk" 2>/dev/null); then
    echo "error: cannot read back staged link" >&2
    return 1
  fi
  printf 'link:%s\n' "$t"
}

# Delete one managed path. Only files/symlinks; anything else refuses.
function deploy_op_delete(){
  local disk="$1"
  if [[ -L "$disk" || -f "$disk" ]]; then
    rm -f -- "$disk" || { echo "error: cannot delete: $disk" >&2; return 1; }
  elif [[ -e "$disk" ]]; then
    echo "error: live path is not a file/symlink, refusing delete (manual): $disk" >&2
    return 1
  fi
  printf 'absent\n'
}

# Deliver sidecar content as <path>.new with collision rules.
# Reuse rule (idempotency): among existing X.new, X.new.1, ... pick the
# first that is manifest-recorded AND live-matches its recorded blob AND
# that blob equals the delivery target, then overwrite exactly it.
# Otherwise create the next free versioned name; unknown pre-existing
# files are never clobbered. Prints the delivered path.
function deploy_op_sidecar_new(){
  local disk="$1" t_blob="$2" _rec_ignored="$3" tag="$4"
  local cand
  for cand in "$disk.new" "$disk.new".*; do
    [[ -e "$cand" || -L "$cand" ]] || continue
    local rel="${cand#${DEPLOY_HOME}/}"
    [[ "$rel" == "$cand" ]] && continue
    local rec="${PLAN_M_BLOB[$rel]:-}"
    if [[ -z "$rec" || "$rec" != "$t_blob" ]]; then
      continue
    fi
    local lh
    if [[ -f "$cand" && ! -L "$cand" ]] && lh=$(git -C "$REPO_ROOT" hash-object -- "$cand" 2>/dev/null) && [[ "$lh" == "$rec" ]]; then
      local out
      if ! out=$(deploy_op_write_file "$cand" "$t_blob" "100644" "$tag"); then
        return 1
      fi
      printf '%s\n' "$cand"
      return 0
    fi
  done
  local n=1 dest="$disk.new"
  while [[ -e "$dest" || -L "$dest" ]]; do
    dest="$disk.new.$n"
    n=$((n + 1))
  done
  local out2
  if ! out2=$(deploy_op_write_file "$dest" "$t_blob" "100644" "$tag"); then
    return 1
  fi
  printf '%s\n' "$dest"
}

# (Preflight globals are declared alongside the active preflight context
# below; no separate stale block is kept here.)

# Restore one snapshotted path (abort path). Mirrors snapshot semantics:
# absent pre-state removes created paths (files/links) and rmdirs only
# dirs we created that are still empty; present pre-state copies bytes
# back with modes (cp -p/-P). Anything surprising fails the row loudly
# instead of guessing.
function deploy_snapshot_restore(){
  local snapfiles="$1" home="$2" rel="$3" pre="$4"
  local src="$snapfiles/$rel" dst="$home/$rel"
  case "$pre" in
    absent)
      if [[ -L "$dst" || -f "$dst" ]]; then
        rm -f -- "$dst" || { echo "error: abort cannot remove created path: $rel" >&2; return 1; }
      elif [[ -d "$dst" && ! -L "$dst" ]]; then
        # Only directories are handled by the caller (rmdir-if-empty).
        :
      elif [[ -e "$dst" ]]; then
        echo "error: abort cannot remove special path: $rel" >&2
        return 1
      fi
      ;;
    link:*)
      if [[ ! -L "$src" ]]; then
        echo "error: snapshot link missing for $rel" >&2
        return 1
      fi
      rm -f -- "$dst" 2>/dev/null || true
      mkdir -p "$(dirname "$dst")" || return 1
      cp -P -- "$src" "$dst" || { echo "error: abort cannot restore link: $rel" >&2; return 1; }
      ;;
    file:*)
      if [[ ! -f "$src" ]]; then
        echo "error: snapshot file missing for $rel" >&2
        return 1
      fi
      mkdir -p "$(dirname "$dst")" || return 1
      cp -p -- "$src" "$dst" || { echo "error: abort cannot restore file: $rel" >&2; return 1; }
      ;;
    *)
      echo "error: abort cannot restore pre-state '$pre': $rel" >&2
      return 1
      ;;
  esac
  return 0
}

# Verify snapshot bytes against journal pre-observations (abort gate).
# Prints nothing on success; fails loudly on first mismatch.
function deploy_snapshot_verify(){
  local snapfiles="$1" journal="$2" stream
  if ! stream=$(jq -r -s '.[] | select(.type=="op") | [.path // "__MISSING__", .pre // "__MISSING__"] | join("\t")' "$journal" 2>/dev/null); then
    echo "error: journal is not valid JSON: $journal" >&2
    return 1
  fi
  local path pre h t
  while IFS=$'\t' read -r path pre; do
    [[ -z "$path" ]] && continue
    if [[ -z "$pre" || "$pre" == __MISSING__ ]]; then
      echo "error: journal has a corrupt op line" >&2
      return 1
    fi
    case "$pre" in
      absent)
        if [[ -e "$snapfiles/$path" || -L "$snapfiles/$path" ]]; then
          echo "error: snapshot unexpectedly holds absent path: $path" >&2
          return 1
        fi;;
      file:*)
        if ! h=$(git -C "$REPO_ROOT" hash-object -- "$snapfiles/$path" 2>/dev/null); then
          echo "error: snapshot file unreadable: $path" >&2
          return 1
        fi
        if [[ "file:$h" != "$pre" ]]; then
          echo "error: snapshot bytes mismatch (torn snapshot?) for: $path" >&2
          return 1
        fi;;
      link:*)
        if ! t=$(readlink "$snapfiles/$path" 2>/dev/null); then
          echo "error: snapshot link unreadable: $path" >&2
          return 1
        fi
        if [[ "link:$t" != "$pre" ]]; then
          echo "error: snapshot link mismatch for: $path" >&2
          return 1
        fi;;
      *)
        echo "error: snapshot cannot verify pre-state '$pre': $path" >&2
        return 1;;
    esac
  done <<<"$stream"
}


# --- Preflight context (globals set by deploy_apply_preflight). ---
# APPLY_UNDECIDED: "op|path|hint" rows lacking valid decisions.
# APPLY_SUBBLOCK: "op|path|detail" submodule rows blocking this apply.
# APPLY_ESTABLISH: paths whose submodule fingerprint gets recorded now.
# APPLY_ERRORS: refusal lines for error rows / internal problems.
# APPLY_SUBOK: submodule paths already ok-verified at preflight (gates
# fully_deployed; never freshly established this run).
declare -a APPLY_UNDECIDED=()
declare -a APPLY_SUBBLOCK=()
declare -a APPLY_ESTABLISH=()
declare -a APPLY_ERRORS=()
declare -a APPLY_DEC_USED=()
declare -a APPLY_DEC_STALE=()
declare -A APPLY_SUBOK=()
declare -A APPLY_ROW_OF=()
APPLY_EST_SNAP=0
APPLY_EST_WRITE=0
APPLY_EST_ROWS=0
APPLY_REQUIRED=0

# Overlay ephemeral --resolve specs onto the loaded decisions (memory
# only, never persisted). Each spec must name a path whose FRESH row is a
# decide-class op, with an allowlisted choice; anything else refuses.
function deploy_apply_overlay_resolve(){
  local spec path choice i
  for ((i = 0; i < ${#APPLY_RESOLVE[@]}; i++)); do
    spec="${APPLY_RESOLVE[$i]}"
    if [[ "$spec" != *:* ]]; then
      echo "error: --resolve needs PATH:CHOICE, got: $spec" >&2
      return 2
    fi
    choice="${spec##*:}"
    path="${spec%:*}"
    if [[ -z "$path" || -z "$choice" ]]; then
      echo "error: --resolve needs non-empty PATH and CHOICE, got: $spec" >&2
      return 2
    fi
    if [[ -z "${APPLY_ROW_OF[$path]:-}" ]]; then
      echo "error: --resolve names a path with no planned operation: $path" >&2
      return 2
    fi
    local op live target base kind
    IFS=$'\t' read -r op _c _p base _d target live _t <<<"${APPLY_ROW_OF[$path]}"
    kind="$(deploy_apply_row_kind "$path")"
    if ! deploy_decide_allowed "$op" "$choice" "$kind"; then
      echo "error: --resolve choice '$choice' is not valid for '$path' (operation: $op)" >&2
      return 2
    fi
    DEC_D_CHOICE[$path]="$choice"; DEC_D_OP[$path]="$op"; DEC_D_LIVE[$path]="$live"
    DEC_D_TARGET[$path]="$target"; DEC_D_BASE[$path]="$base"; DEC_D_AT[$path]="ephemeral"
  done
}

# Manifest/target kind for one path (manifest first, else target-derived).
function deploy_apply_row_kind(){
  local path="$1"
  if [[ -n "${PLAN_M_KIND[$path]:-}" ]]; then
    printf '%s\n' "${PLAN_M_KIND[$path]}"
  elif [[ -n "${PLAN_T_SUB[$path]:-}" ]]; then
    printf 'submodule\n'
  elif [[ "${PLAN_T_MODE[$path]:-}" == "120000" ]]; then
    printf 'symlink\n'
  else
    printf 'file\n'
  fi
}

# Match a decision (stored or ephemeral) for one fresh row. Prints the
# valid choice, or nothing. Choice allowlisting happens here so hand-edited
# garbage can never flow into execution, even if the file parsed cleanly.
function deploy_apply_match_decision(){
  local path="$1" op="$2" live="$3" target="$4" base="$5" kind="$6"
  local c="${DEC_D_CHOICE[$path]:-}"
  [[ -z "$c" ]] && return 0
  if [[ "${DEC_D_OP[$path]}" != "$op" || "${DEC_D_LIVE[$path]}" != "$live" || "${DEC_D_TARGET[$path]}" != "$target" || "${DEC_D_BASE[$path]}" != "$base" ]]; then
    return 0
  fi
  if ! deploy_decide_allowed "$op" "$c" "$kind"; then
    return 0
  fi
  printf '%s\n' "$c"
}

# Full preflight: loads nothing itself (caller provides loaded state,
# target, computed rows, decisions file path via globals), evaluates every
# gate, and fills the APPLY_* context. Prints the report to stderr.
# Returns 0 (would proceed) or 2 (refused, reasons printed). Pure except
# for reads; creates nothing, not even the lock.
# Globals in: APPLY_SD, APPLY_DECISIONS_FILE. Globals out: APPLY_* context.
function deploy_apply_preflight(){
  # Reset-on-entry: preflight may run repeatedly in one shell (tests,
  # resume after fresh). Append-without-reset would double-count gates.
  APPLY_ROW_OF=()
  APPLY_UNDECIDED=(); APPLY_SUBBLOCK=(); APPLY_ESTABLISH=(); APPLY_ERRORS=()
  APPLY_DEC_USED=(); APPLY_DEC_STALE=(); APPLY_SUBOK=()
  APPLY_EST_SNAP=0; APPLY_EST_WRITE=0; APPLY_EST_ROWS=0; APPLY_REQUIRED=0
  local i row op class path b_blob b_disk t_blob live detail kind
  local choice=""
  for ((i = 0; i < ${#DEPLOY_PLAN_ROWS[@]}; i++)); do
    row="${DEPLOY_PLAN_ROWS[$i]}"
    IFS=$'\t' read -r op _c path _b _d _t _l _x <<<"$row"
    [[ -z "$op" ]] && continue
    APPLY_ROW_OF[$path]="$row"
  done
  if ! deploy_apply_overlay_resolve; then
    return 2
  fi
  for ((i = 0; i < ${#DEPLOY_PLAN_ROWS[@]}; i++)); do
    row="${DEPLOY_PLAN_ROWS[$i]}"
    IFS=$'\t' read -r op class path b_blob b_disk t_blob live detail <<<"$row"
    [[ -z "$op" ]] && continue
    kind="$(deploy_apply_row_kind "$path")"
    case "$op" in
      error)
        APPLY_ERRORS+=("$op|$path|$detail")
        continue;;
      update|delete-stale|sidecar-new)
        APPLY_EST_ROWS=$((APPLY_EST_ROWS + 1));;
      add)
        if [[ "$detail" == "submodule-init-required" ]]; then
          APPLY_SUBBLOCK+=("$op|$path|no-submodule-materialization-in-3B")
          continue
        fi
        if [[ -n "${PLAN_EVSET[$path]:-}" ]]; then
          echo "error: internal: evidence path planned as plain add: $path" >&2
          return 2
        fi
        APPLY_EST_ROWS=$((APPLY_EST_ROWS + 1));;
      unchanged|converged|gone|preserved|user-absent|retired|sidecar-pending|legacy)
        continue;;
      submodule-ok)
        APPLY_SUBOK[$path]=1
        continue;;
      submodule-unverified)
        APPLY_ESTABLISH+=("$path")
        continue;;
      submodule-missing|submodule-diverged|submodule-update-available|submodule-drifted)
        APPLY_SUBBLOCK+=("$op|$path|$detail")
        continue;;
      conflict-drift|conflict-removed|delete-blocked|drift-unchanged|drift-update|drift-moved|drift-removed|missing-unchanged|add-evidence|appeared|class-changed|type-changed)
        choice=$(deploy_apply_match_decision "$path" "$op" "$live" "$t_blob" "$b_blob" "$kind")
        if [[ -z "$choice" ]]; then
          if [[ -n "${DEC_D_CHOICE[$path]:-}" ]]; then
            APPLY_UNDECIDED+=("$op|$path|stale-decision-had-${DEC_D_CHOICE[$path]}")
          else
            APPLY_UNDECIDED+=("$op|$path|no-decision-recorded")
          fi
          continue
        fi
        APPLY_DEC_USED+=("$path=$choice")
        case "$choice" in
          replace|install|reinstall|delete|sidecar)
            APPLY_EST_ROWS=$((APPLY_EST_ROWS + 1));;
        esac;;
      *)
        APPLY_ERRORS+=("$op|$path|unknown-operation")
        continue;;
    esac
  done
  # Stale file entries (decided paths with no fresh decide row): warn only.
  local dp
  for dp in "${!DEC_D_CHOICE[@]}"; do
    if [[ -z "${APPLY_ROW_OF[$dp]:-}" ]]; then
      APPLY_DEC_STALE+=("$dp (no fresh row; ignored)")
    fi
  done
  # Disk estimate from resolved mutating rows.
  if ! deploy_apply_estimate_loads; then
    return 2
  fi
  # Lock + open-transaction check (report-only here; apply refuses too).
  local lock
  lock=$(deploy_lock_path "$APPLY_SD")
  if [[ -f "$lock" ]]; then
    local lpid lid
    lpid=$(awk '{print $1}' "$lock" 2>/dev/null || echo "?")
    lid=$(awk '{print $2}' "$lock" 2>/dev/null || echo "?")
    if [[ "$lpid" =~ ^[0-9]+$ ]] && kill -0 "$lpid" 2>/dev/null; then
      echo "error: preflight refused: apply $lid in progress (pid $lpid)" >&2
      return 2
    fi
    echo "error: preflight refused: stale lock from $lid; resume/abort it, or --break-lock first" >&2
    return 2
  fi
  local openj
  if openj=$(deploy_apply_open_journal "$APPLY_SD"); then
    echo "error: preflight refused: incomplete transaction $openj exists; resume or abort it first" >&2
    return 2
  fi
  if (( ${#APPLY_ERRORS[@]} > 0 )); then
    echo "error: preflight refused: ${#APPLY_ERRORS[@]} error rows (see plan)" >&2
    return 2
  fi
  if (( ${#APPLY_SUBBLOCK[@]} > 0 )); then
    echo "error: preflight refused: ${#APPLY_SUBBLOCK[@]} submodule rows block this apply:" >&2
    local s
    for s in "${APPLY_SUBBLOCK[@]}"; do echo "  blocked: $s" >&2; done
    return 2
  fi
  if (( ${#APPLY_UNDECIDED[@]} > 0 )); then
    echo "error: preflight refused: ${#APPLY_UNDECIDED[@]} undecided rows:" >&2
    local u
    for u in "${APPLY_UNDECIDED[@]}"; do echo "  undecided: $u" >&2; done
    return 2
  fi
  deploy_apply_preflight_report
}

# Estimate snapshot + write bytes for the resolved mutating rows and check
# both filesystems. Sets APPLY_EST_SNAP/WRITE/REQUIRED. Refuses when the
# estimate itself cannot be built or space is short.
function deploy_apply_estimate_loads(){
  local i row op class path b_blob b_disk t_blob live detail kind
  local choice=""
  local snap_total=0
  local -a need_blobs=()
  declare -A seen_b=()
  for ((i = 0; i < ${#DEPLOY_PLAN_ROWS[@]}; i++)); do
    row="${DEPLOY_PLAN_ROWS[$i]}"
    IFS=$'\t' read -r op class path b_blob b_disk t_blob live detail <<<"$row"
    [[ -z "$op" ]] && continue
    local mutates=false
    case "$op" in
      update|add|delete-stale|sidecar-new) mutates=true;;
      conflict-drift|conflict-removed|delete-blocked|drift-unchanged|drift-update|drift-moved|drift-removed|missing-unchanged|add-evidence|appeared|class-changed|type-changed)
        choice=$(deploy_apply_match_decision "$path" "$op" "$live" "$t_blob" "$b_blob" "$(deploy_apply_row_kind "$path")")
        case "$choice" in replace|install|reinstall|delete|sidecar) mutates=true;; esac;;
    esac
    if [[ "$mutates" != true ]]; then continue; fi
    local disk
    if ! disk=$(deploy_map_home "$path" 2>/dev/null); then
      echo "error: preflight cannot map path: $path" >&2
      return 2
    fi
    if [[ -f "$disk" && ! -L "$disk" ]]; then
      local sz
      if ! sz=$(stat -c %s -- "$disk" 2>/dev/null) || [[ ! "$sz" =~ ^[0-9]+$ ]]; then
        echo "error: preflight cannot size live file: $path" >&2
        return 2
      fi
      snap_total=$((snap_total + sz))
    else
      snap_total=$((snap_total + 1024))
    fi
    if [[ "$t_blob" != "-" ]]; then
      if [[ -z "${seen_b[$t_blob]:-}" ]]; then seen_b[$t_blob]=1; need_blobs+=("$t_blob"); fi
    fi
  done
  local write_total=0 out
  if (( ${#need_blobs[@]} > 0 )); then
    # Default batch-check format yields "<sha> <type> <size>" per line
    # ("<sha> missing" for absent objects).
    if ! out=$(printf '%s\n' "${need_blobs[@]}" | git -C "$REPO_ROOT" cat-file --batch-check 2>/dev/null); then
      echo "error: preflight cannot size target blobs" >&2
      return 2
    fi
    local ln bsha btype bsize
    while IFS= read -r ln; do
      read -r bsha btype bsize <<<"$ln" || true
      if [[ "$btype" == "missing" || ! "$bsize" =~ ^[0-9]+$ ]]; then
        echo "error: preflight found missing target object: $bsha" >&2
        return 2
      fi
      write_total=$((write_total + bsize))
    done <<<"$out"
  fi
  APPLY_EST_SNAP=$snap_total
  APPLY_EST_WRITE=$write_total
  APPLY_EST_ROWS=${#DEPLOY_PLAN_ROWS[@]}
  APPLY_REQUIRED=$(deploy_estimate_required "$snap_total" "$write_total" "${#DEPLOY_PLAN_ROWS[@]}")
  local home_dev state_dev
  home_dev=$(stat -c %d "$DEPLOY_HOME" 2>/dev/null) || { echo "error: preflight cannot stat home fs" >&2; return 2; }
  if ! deploy_check_one "$DEPLOY_HOME" "$APPLY_REQUIRED"; then
    return 2
  fi
  if [[ -d "$APPLY_SD" ]]; then
    state_dev=$(stat -c %d "$APPLY_SD" 2>/dev/null) || { echo "error: preflight cannot stat state fs" >&2; return 2; }
    if [[ "$state_dev" != "$home_dev" ]]; then
      if ! deploy_check_one "$APPLY_SD" "$APPLY_REQUIRED"; then
        return 2
      fi
    fi
  fi
}

# Find one open (no completed/aborted marker) journal under the state dir.
# Prints the apply id, or nothing when none exists.
function deploy_apply_open_journal(){
  local sd="$1" jf id
  for jf in "$sd/$DEPLOY_APPLIES_NAME"/*/journal.jsonl; do
    [[ -f "$jf" ]] || continue
    if deploy_journal_completed "$jf" || deploy_journal_aborted "$jf"; then
      continue
    fi
    id=$(basename "$(dirname "$jf")")
    printf '%s\n' "$id"
    return 0
  done
  return 1
}

# Preflight human report (stderr). Caller decides the exit code.
function deploy_apply_preflight_report(){
  local i row op class path b_blob b_disk t_blob live detail
  echo "[preflight]: target ${APPLY_TARGET} home ${DEPLOY_HOME}" >&2
  echo "[preflight]: snapshot~${APPLY_EST_SNAP}B write~${APPLY_EST_WRITE}B required~${APPLY_REQUIRED}B" >&2
  echo "[preflight]: decisions consumed: ${#APPLY_DEC_USED[@]}; stale file entries: ${#APPLY_DEC_STALE[@]}" >&2
  local s
  for s in "${APPLY_DEC_STALE[@]}"; do echo "[preflight]: stale decision ignored: $s" >&2; done
  if (( ${#APPLY_ESTABLISH[@]} > 0 )); then
    echo "[preflight]: submodule fingerprints to establish: ${#APPLY_ESTABLISH[@]}" >&2
  fi
  echo "[preflight]: destructions (delete/replace targets, pre-hashes shown):" >&2
  for ((i = 0; i < ${#DEPLOY_PLAN_ROWS[@]}; i++)); do
    row="${DEPLOY_PLAN_ROWS[$i]}"
    IFS=$'\t' read -r op class path b_blob b_disk t_blob live detail <<<"$row"
    case "$op" in
      delete-stale) echo "[preflight]:   delete $path ($live)" >&2;;
      conflict-drift|drift-unchanged|drift-update|drift-moved|appeared|class-changed|type-changed)
        local c
        c=$(deploy_apply_match_decision "$path" "$op" "$live" "$t_blob" "$b_blob" "$(deploy_apply_row_kind "$path")")
        if [[ "$c" == "replace" || "$c" == "delete" ]]; then
          echo "[preflight]:   $c $path ($live)" >&2
        fi;;
      delete-blocked)
        local c2
        c2=$(deploy_apply_match_decision "$path" "$op" "$live" "$t_blob" "$b_blob" "$(deploy_apply_row_kind "$path")")
        if [[ "$c2" == "delete" ]]; then
          echo "[preflight]:   delete $path ($live)" >&2
        fi;;
    esac
  done
}

# --- Execution context (set by the orchestrator before executing). ---
# APPLY_JOURNAL: journal path. APPLY_SNAPFILES: snapshot mirror dir.
# APPLY_OP_N: op counter (fault hooks + progress).
APPLY_JOURNAL=""
APPLY_SNAPFILES=""
APPLY_OP_N=0

function deploy_apply_jline(){
  deploy_journal_append "$APPLY_JOURNAL" "$1"
}

function deploy_apply_result(){
  local path="$1" outcome="$2" note="${3:--}" post="${4:--}"
  APPLY_OP_N=$((APPLY_OP_N + 1))
  deploy_apply_jline "$(printf '{"seq":%s,"type":"result","path":"%s","outcome":"%s","post":"%s","note":"%s"}' "$APPLY_OP_N" "$(deploy_json_escape "$path")" "$outcome" "$(deploy_json_escape "$post")" "$(deploy_json_escape "$note")")"
}

function deploy_apply_jop(){
  local path="$1" op="$2" pre="$3" detail="${4:--}"
  APPLY_OP_N=$((APPLY_OP_N + 1))
  deploy_apply_jline "$(printf '{"seq":%s,"type":"op","op":"%s","path":"%s","pre":"%s","detail":"%s"}' "$APPLY_OP_N" "$op" "$(deploy_json_escape "$path")" "$(deploy_json_escape "$pre")" "$(deploy_json_escape "$detail")")"
}

# Execute one frozen plan row end to end (re-observe, re-match, mutate,
# verify). Returns 0 row-ok (incl. deliberate skips) or 1 (stop everything).
function deploy_apply_exec_row(){
  local row="$1" op class path b_blob b_disk t_blob live detail kind
  IFS=$'\t' read -r op class path b_blob b_disk t_blob live detail <<<"$row"
  if [[ -z "$op" ]]; then
    echo "error: internal: empty plan row" >&2
    return 1
  fi
  kind="$(deploy_apply_row_kind "$path")"
  # Fresh recompute: the frozen row is advisory; live truth governs.
  local fresh fop flive ftarget fbase
  if ! fresh=$(deploy_plan_path "$path"); then
    deploy_apply_result "$path" failed "recompute-failed" "-"
    echo "error: recompute failed, stopping: $path" >&2
    return 1
  fi
  if [[ -z "$fresh" ]]; then
    deploy_apply_result "$path" failed "row-vanished" "-"
    echo "error: path vanished from plan, stopping: $path" >&2
    return 1
  fi
  IFS=$'\t' read -r fop _fc _fp fb_blob fb_disk ft_blob flive _fd <<<"$fresh"
  if [[ "$fop" != "$op" || "$flive" != "$live" || "$ft_blob" != "$t_blob" ]]; then
    deploy_apply_result "$path" refused "toctou:$fop:$flive" "-"
    echo "error: TOCTOU: $path changed since preflight ($op/$live -> $fop/$flive); stopping" >&2
    return 1
  fi
  local disk
  if ! disk=$(deploy_map_home "$path" 2>/dev/null); then
    deploy_apply_result "$path" failed "home-map-failed" "-"
    echo "error: cannot map path, stopping: $path" >&2
    return 1
  fi
  case "$op" in
    unchanged|converged|gone|preserved|user-absent|retired|sidecar-pending|submodule-ok|submodule-unverified|legacy)
      # Informational rows with a "-" placeholder live carry no verifiable
      # post-state (user-managed paths with no manifest record). Record the
      # real observation so resume can re-verify; fall back to "-" only when
      # the path is unmappable.
      local noop_post="$live"
      if [[ "$noop_post" == "-" ]]; then
        noop_post=$(deploy_plan_observe "$disk" 2>/dev/null || echo "-")
      fi
      deploy_apply_result "$path" ok "noop" "$noop_post"
      return 0;;
  esac
  # Decided rows: re-match (stored + ephemeral) against the fresh row.
  local choice=""
  case "$op" in
    conflict-drift|conflict-removed|delete-blocked|drift-unchanged|drift-update|drift-moved|drift-removed|missing-unchanged|add-evidence|appeared|class-changed|type-changed)
      choice=$(deploy_apply_match_decision "$path" "$op" "$live" "$t_blob" "$b_blob" "$kind")
      if [[ -z "$choice" ]]; then
        deploy_apply_result "$path" refused "decision-stale-or-absent" "-"
        echo "error: decision missing/stale, stopping: $path" >&2
        return 1
      fi;;
  esac
  case "$op" in
    update|add)
      if ! deploy_apply_intent_write "$path" "$disk" "$t_blob" "$op" "$class" "$live" "$detail"; then
        return 1
      fi;;
    missing-unchanged|add-evidence)
      if [[ "$choice" == "install" ]]; then
        if ! deploy_apply_intent_write "$path" "$disk" "$t_blob" "$op" "$class" "$live" "$detail"; then
          return 1
        fi
      else
        deploy_apply_result "$path" ok "preserved-absence" "$live"
      fi;;
    delete-stale)
      deploy_apply_jop "$path" "$op" "$live" "$detail"
      if ! deploy_apply_do_delete "$path" "$disk"; then
        deploy_apply_result "$path" failed "delete-failed" "-"
        return 1
      fi;;
    delete-blocked)
      if [[ "$choice" == "delete" ]]; then
        deploy_apply_jop "$path" "$op" "$live" "$detail"
        if ! deploy_apply_do_delete "$path" "$disk"; then
          deploy_apply_result "$path" failed "delete-failed" "-"
          return 1
        fi
      else
        deploy_apply_result "$path" ok "kept" "$live"
      fi;;
    sidecar-new)
      deploy_apply_jop "$path" "$op" "$live" "$detail"
      if ! deploy_apply_do_sidecar "$path" "$disk" "$t_blob"; then
        deploy_apply_result "$path" failed "sidecar-failed" "-"
        return 1
      fi;;
    conflict-removed|drift-removed)
      if [[ "$choice" == "reinstall" ]]; then
        if ! deploy_apply_intent_write "$path" "$disk" "$t_blob" "$op" "$class" "$live" "$detail"; then
          return 1
        fi
      else
        deploy_apply_result "$path" ok "removal-accepted" "$live"
      fi;;
    conflict-drift|drift-unchanged|drift-update|drift-moved|appeared|class-changed|type-changed)
      case "$choice" in
        replace)
          if ! deploy_apply_intent_write "$path" "$disk" "$t_blob" "$op" "$class" "$live" "$detail"; then
            return 1
          fi;;
        keep)
          deploy_apply_result "$path" ok "kept" "$live";;
        sidecar)
          deploy_apply_jop "$path" "$op" "$live" "$detail"
          if ! deploy_apply_do_sidecar "$path" "$disk" "$t_blob"; then
            deploy_apply_result "$path" failed "sidecar-failed" "-"
            return 1
          fi;;
      esac;;
    *)
      deploy_apply_result "$path" failed "unknown-op:$op" "-"
      echo "error: internal: unknown op in executor: $op" >&2
      return 1;;
  esac
  return 0
}

# Write intent router: sidecar-class paths never receive live writes;
# every write intent on them becomes a .new delivery instead. The journal
# pre-line always records the verified live observation (never a placeholder):
# abort's snapshot verifier depends on it byte-for-byte.
function deploy_apply_intent_write(){
  local path="$1" disk="$2" t_blob="$3" op="$4" class="$5" live="${6:-absent}" detail="${7:--}"
  if [[ "$class" == "sidecar" ]]; then
    deploy_apply_jop "$path" "$op" "$live" "sidecar-class-routing:$detail"
    if ! deploy_apply_do_sidecar "$path" "$disk" "$t_blob"; then
      deploy_apply_result "$path" failed "sidecar-failed" "-"
      return 1
    fi
    return 0
  fi
  deploy_apply_jop "$path" "$op" "$live" "$detail"
  if ! deploy_apply_do_write "$path" "$disk" "$t_blob" "$op"; then
    deploy_apply_result "$path" failed "write-failed" "-"
    return 1
  fi
  return 0
}

# Write target content (file per blob mode, or symlink per blob target).
# Prints nothing; result post-state is re-observed by the caller flow.
function deploy_apply_do_write(){
  local path="$1" disk="$2" t_blob="$3" op="$4" t_mode post
  t_mode="${PLAN_T_MODE[$path]:-100644}"
  if ! deploy_op_mkdir_parents "$disk" "$APPLY_JOURNAL"; then
    return 1
  fi
  if [[ "$t_mode" == "120000" ]]; then
    local target
    if ! target=$(git -C "$REPO_ROOT" cat-file -p "$t_blob" 2>/dev/null); then
      echo "error: unreadable target blob: $path" >&2
      return 1
    fi
    if ! post=$(deploy_op_write_link "$disk" "$target" "$APPLY_ID"); then
      return 1
    fi
  else
    if ! post=$(deploy_op_write_file "$disk" "$t_blob" "$t_mode" "$APPLY_ID"); then
      return 1
    fi
  fi
  deploy_apply_result "$path" ok "$op-applied" "$post"
}

function deploy_apply_do_delete(){
  local path="$1" disk="$2" post
  if ! post=$(deploy_op_delete "$disk"); then
    return 1
  fi
  deploy_apply_result "$path" ok "deleted" "$post"
}

function deploy_apply_do_sidecar(){
  local path="$1" disk="$2" t_blob="$3" dest rec_blob post
  rec_blob=""
  if [[ -n "${PLAN_M_BLOB[$path.new]:-}" ]]; then
    rec_blob="${PLAN_M_BLOB[$path.new]}"
  fi
  if ! deploy_op_mkdir_parents "$disk" "$APPLY_JOURNAL"; then
    return 1
  fi
  if ! dest=$(deploy_op_sidecar_new "$disk" "$t_blob" "$rec_blob" "$APPLY_ID"); then
    return 1
  fi
  if ! post=$(deploy_plan_observe "$dest" 2>/dev/null); then
    post="error:observe"
  fi
  # Stash the delivered destination for manifest advancement.
  APPLY_SIDECAR_DEST[$path]="$dest"
  deploy_apply_result "$path" ok "sidecar-delivered:$dest" "$post"
}

# --- Manifest advancement (pure construction from verified states). ---
# APPLY_ADV[path]: confirm|drop|carry|sidecar|subok (set by orchestrator).
# APPLY_FRESH_FP: submodule paths fingerprinted this run (never true).
# APPLY_NEW_MANIFEST: accumulated output. APPLY_ADV_FAILED: sticky flag.
# APPLY_SIDECAR_DEST: in-memory dest stash (same-process fast path; the
# journal note is the crash-safe source of truth).
declare -A APPLY_ADV=()
declare -A APPLY_FRESH_FP=()
declare -A APPLY_EMITTED=()
declare -A APPLY_SIDECAR_DEST=()
APPLY_NEW_MANIFEST=""
APPLY_ADV_FAILED=0

# Advance one manifest row from its verified post-state.
# APPLY_ADV[path] directive (set by the executor/orchestrator):
#   confirm   verify live==target now, emit confirmed@T (files + links)
#   drop      omit the row (deletes, gone, accept-removal)
#   carry     rebuild frozen from pre-apply values (keep/preserve/failures)
#   sidecar   emit the delivered .new row (live row handled separately)
#   subok     submodule ok: re-verify fingerprint now, advance rev
# Anything else (or missing directive) means carry. Advancement never
# invents state: every confirm re-observes live first, and any mismatch
# freezes the pre-row and fails the publish (APPLY_ADV_FAILED=1).
function deploy_advance_row(){
  local path="$1" rev="$2"
  local adv="${APPLY_ADV[$path]:-carry}"
  local m_class="${PLAN_M_CLASS[$path]:-}" m_kind="${PLAN_M_KIND[$path]:-}"
  local t_blob="${PLAN_T_BLOB[$path]:-}" t_sub="${PLAN_T_SUB[$path]:-}"
  local t_class="${PLAN_T_CLASS[$path]:-}"
  local t_mode="${PLAN_T_MODE[$path]:-100644}"
  local disk live
  if ! disk=$(deploy_map_home "$path" 2>/dev/null); then
    echo "error: advancement cannot map path: $path" >&2
    APPLY_ADV_FAILED=1
    deploy_advance_carry "$path"
    return 0
  fi
  case "$adv" in
    drop)
      return 0;;
    carry)
      deploy_advance_carry "$path"
      return 0;;
    sidecar)
      # Destination comes from the journal history (crash-safe), with the
      # in-memory stash as fallback for the same-process path. The history
      # search (not just the last note) survives resume's skip markers.
      local dest="" jdest
      jdest=$(deploy_apply_journal_sidecar_dest "$APPLY_JOURNAL" "$path")
      if [[ -n "$jdest" ]]; then
        dest="$jdest"
      else
        dest="${APPLY_SIDECAR_DEST[$path]:-}"
      fi
      if [[ -z "$dest" ]]; then
        echo "error: internal: sidecar advancement without destination: $path" >&2
        APPLY_ADV_FAILED=1
        deploy_advance_carry "$path"
        return 0
      fi
      # A manifest row for the live path (if any) stays frozen: sidecar
      # delivery never touches live content, not even pristine copies.
      if [[ -n "${PLAN_M_STATUS[$path]:-}" ]]; then
        deploy_advance_carry "$path"
      fi
      local rel="${dest#${DEPLOY_HOME}/}" h
      if [[ "$rel" == "$dest" ]]; then
        echo "error: internal: sidecar destination outside home: $dest" >&2
        APPLY_ADV_FAILED=1
        return 0
      fi
      if ! h=$(git -C "$REPO_ROOT" hash-object -- "$dest" 2>/dev/null); then
        echo "error: advancement cannot hash delivered sidecar: $dest" >&2
        APPLY_ADV_FAILED=1
        return 0
      fi
      if [[ "$h" != "$t_blob" ]]; then
        echo "error: advancement sidecar mismatch: $dest" >&2
        APPLY_ADV_FAILED=1
        return 0
      fi
      APPLY_NEW_MANIFEST+="$(printf '{"path":"%s","kind":"file","class":"managed","status":"sidecar-delivered","blob":"%s","disk":"%s","rev":"%s","detail":"sidecar-delivery"}\n' \
        "$(deploy_json_escape "$rel")" "$t_blob" "$h" "$rev")"$'\n'
      APPLY_EMITTED[$rel]=1
      return 0;;
    confirm)
      live=$(deploy_plan_observe "$disk")
      # Class comes from the target (novel rows have no manifest class);
      # it is never empty here or the row cannot advance.
      local aclass="${t_class:-$m_class}"
      if [[ -z "$aclass" ]]; then
        echo "error: advancement cannot determine class: $path" >&2
        APPLY_ADV_FAILED=1
        deploy_advance_carry "$path"
        return 0
      fi
      if [[ "$t_mode" == "120000" ]]; then
        local want
        if ! want=$(git -C "$REPO_ROOT" cat-file -p "$t_blob" 2>/dev/null); then
          echo "error: advancement cannot read target blob: $path" >&2
          APPLY_ADV_FAILED=1
          deploy_advance_carry "$path"
          return 0
        fi
        if [[ "$live" != "link:$want" ]]; then
          echo "error: advancement re-verify failed (link): $path" >&2
          APPLY_ADV_FAILED=1
          deploy_advance_carry "$path"
          return 0
        fi
        APPLY_NEW_MANIFEST+="$(printf '{"path":"%s","kind":"symlink","class":"%s","status":"confirmed","blob":"%s","disk":null,"rev":"%s","detail":"-"}\n' \
          "$(deploy_json_escape "$path")" "$aclass" "$t_blob" "$rev")"$'\n'
        return 0
      fi
      if [[ "$live" != "file:$t_blob" ]]; then
        echo "error: advancement re-verify failed: $path" >&2
        APPLY_ADV_FAILED=1
        deploy_advance_carry "$path"
        return 0
      fi
      APPLY_NEW_MANIFEST+="$(printf '{"path":"%s","kind":"file","class":"%s","status":"confirmed","blob":"%s","disk":"%s","rev":"%s","detail":"-"}\n' \
        "$(deploy_json_escape "$path")" "$aclass" "$t_blob" "$t_blob" "$rev")"$'\n'
      return 0;;
    subok)
      local fp_now=""
      if ! fp_now=$(deploy_submodule_fingerprint "$disk" 2>/dev/null); then
        echo "error: advancement lost submodule verifiability: $path" >&2
        APPLY_ADV_FAILED=1
        deploy_advance_carry "$path"
        return 0
      fi
      local recorded="${PLAN_M_FP[$path]:-}"
      if [[ -n "$recorded" && "$fp_now" != "$recorded" ]]; then
        echo "error: advancement fingerprint moved under us: $path" >&2
        APPLY_ADV_FAILED=1
        deploy_advance_carry "$path"
        return 0
      fi
      if [[ -z "$recorded" ]]; then
        APPLY_FRESH_FP[$path]=1
      fi
      local obs head_json="null"
      obs=$(deploy_plan_submodule_observe "$disk")
      if [[ "$obs" == present:* ]]; then
        local hn="${obs#present:}"
        if [[ "$hn" != "none" ]]; then head_json="\"$hn\""; fi
      fi
      local gitlink="$t_sub"
      if [[ -z "$gitlink" ]]; then gitlink="${PLAN_M_BLOB[$path]}"; fi
      APPLY_NEW_MANIFEST+="$(printf '{"path":"%s","kind":"submodule","class":"%s","status":"present","blob":"%s","disk":%s,"rev":"%s","detail":"-","fingerprint":"%s"}\n' \
        "$(deploy_json_escape "$path")" "$m_class" "$gitlink" "$head_json" "$rev" "$fp_now")"$'\n'
      return 0;;
    *)
      echo "error: internal: unknown advancement directive: $adv ($path)" >&2
      APPLY_ADV_FAILED=1
      deploy_advance_carry "$path"
      return 0;;
  esac
}


# Carry a manifest row frozen (canonical rebuild from pre-apply values).
# Skipped when this build already emitted the path (sidecar delivery of a
# path that also carries an older row must not duplicate it).
function deploy_advance_carry(){
  local path="$1"
  if [[ -n "${APPLY_EMITTED[$path]:-}" ]]; then
    return 0
  fi
  if [[ -z "${PLAN_M_STATUS[$path]:-}" ]]; then
    echo "error: internal: carry without a manifest record: $path" >&2
    APPLY_ADV_FAILED=1
    return 0
  fi
  local m_class="${PLAN_M_CLASS[$path]}" m_kind="${PLAN_M_KIND[$path]}"
  local m_status="${PLAN_M_STATUS[$path]}" m_blob="${PLAN_M_BLOB[$path]}"
  local m_disk="${PLAN_M_DISK[$path]}" m_rev="${PLAN_M_REV[$path]}"
  local m_detail="${PLAN_M_DETAIL[$path]}" m_fp="${PLAN_M_FP[$path]:-}"
  local disk_json="null"
  if [[ "$m_disk" != "null" ]]; then disk_json="\"$m_disk\""; fi
  if [[ -n "$m_fp" && "$m_kind" == "submodule" ]]; then
    APPLY_NEW_MANIFEST+="$(printf '{"path":"%s","kind":"%s","class":"%s","status":"%s","blob":"%s","disk":%s,"rev":"%s","detail":"%s","fingerprint":"%s"}\n' \
      "$(deploy_json_escape "$path")" "$m_kind" "$m_class" "$m_status" "$m_blob" "$disk_json" "$m_rev" "$(deploy_json_escape "$m_detail")" "$m_fp")"$'\n'
  else
    APPLY_NEW_MANIFEST+="$(printf '{"path":"%s","kind":"%s","class":"%s","status":"%s","blob":"%s","disk":%s,"rev":"%s","detail":"%s"}\n' \
      "$(deploy_json_escape "$path")" "$m_kind" "$m_class" "$m_status" "$m_blob" "$disk_json" "$m_rev" "$(deploy_json_escape "$m_detail")")"$'\n'
  fi
}

# --- Orchestration: snapshot, execute, advance, publish. ---
# APPLY_ID: this transaction's id. APPLY_ADIR/APPLY_SDIR: applies/<id> and
# snapshots/<id> dirs. APPLY_ADV_* set per row before advancement.
APPLY_ID=""
APPLY_ADIR=""
APPLY_SDIR=""

function deploy_apply_new_id(){
  # Nanosecond timestamp + real pid + randomness: two applies in the same
  # second from the same parent (subshell test harnesses) must never share
  # an id and clobber each other's apply dir. Direct ${BASHPID} expansion
  # (no $()) for the subshell reason above.
  printf '%s-%s-%s-%s\n' "$(date -u +%Y%m%dT%H%M%S%NZ)" "${APPLY_TARGET:0:7}" "${BASHPID:-$$}" "$RANDOM"
}

# Snapshot every about-to-touch live path plus pre-apply state copies.
# Only paths the resolved plan mutates are snapshotted (unknown files are
# never enumerated, let alone copied).
function deploy_apply_snapshot(){
  local i row op class path b_blob b_disk t_blob live detail kind
  local choice=""
  mkdir -p "$APPLY_SDIR/files" || { echo "error: cannot create snapshot dir" >&2; return 1; }
  for ((i = 0; i < ${#DEPLOY_PLAN_ROWS[@]}; i++)); do
    row="${DEPLOY_PLAN_ROWS[$i]}"
    IFS=$'\t' read -r op class path b_blob b_disk t_blob live detail <<<"$row"
    [[ -z "$op" ]] && continue
    kind="$(deploy_apply_row_kind "$path")"
    choice=""
    local touches=false
    case "$op" in
      update|add|delete-stale|sidecar-new) touches=true;;
      conflict-drift|conflict-removed|delete-blocked|drift-unchanged|drift-update|drift-moved|drift-removed|missing-unchanged|add-evidence|appeared|class-changed|type-changed)
        choice=$(deploy_apply_match_decision "$path" "$op" "$live" "$t_blob" "$b_blob" "$kind")
        case "$choice" in replace|install|reinstall|delete|sidecar) touches=true;; esac;;
    esac
    if [[ "$touches" != true ]]; then continue; fi
    if ! deploy_snapshot_path "$APPLY_SDIR/files" "$DEPLOY_HOME" "$path"; then
      return 1
    fi
    # Any .new delivery may replace an existing recorded .new file. That
    # includes explicit sidecar ops/choices AND sidecar-class routing of
    # plain write intents (update/add/replace/install on a sidecar path).
    if [[ "$op" == "sidecar-new" || "$choice" == "sidecar" || "$class" == "sidecar" ]]; then
      # A .new delivery may replace an existing recorded .new file.
      local disk
      if disk=$(deploy_map_home "$path" 2>/dev/null) && [[ -f "$disk.new" && ! -L "$disk.new" ]]; then
        local rel="$path.new"
        mkdir -p "$(dirname "$APPLY_SDIR/files/$rel")" || return 1
        cp -p -- "$disk.new" "$APPLY_SDIR/files/$rel" || return 1
      fi
    fi
  done
  cp -p -- "$APPLY_SD/manifest.jsonl" "$APPLY_SDIR/manifest.jsonl" || return 1
  cp -p -- "$APPLY_SD/$DEPLOY_IDENTITY_NAME" "$APPLY_SDIR/deployment-identity.json" || return 1
  if [[ -f "$APPLY_SD/$DEPLOY_DECISIONS_NAME" ]]; then
    cp -p -- "$APPLY_SD/$DEPLOY_DECISIONS_NAME" "$APPLY_SDIR/decisions.jsonl" || return 1
  fi
}

# Execute all frozen rows in plan order with fail-fast semantics.
# Returns 0 when every row resolved ok/skipped, 1 on first failure.
function deploy_apply_execute(){
  local i row op
  local n=0
  for ((i = 0; i < ${#DEPLOY_PLAN_ROWS[@]}; i++)); do
    row="${DEPLOY_PLAN_ROWS[$i]}"
    IFS=$'\t' read -r op _c _p _b _d _t _l _x <<<"$row"
    [[ -z "$op" ]] && continue
    n=$((n + 1))
    if ! deploy_fault "op:$n"; then
      deploy_apply_result "INTERNAL" failed "fault-injected" "-"
      return 1
    fi
    if ! deploy_apply_exec_row "$row"; then
      return 1
    fi
  done
}

# Build the advanced manifest (sorted union of manifest paths and paths
# with advancement directives, e.g. novel sidecar deliveries that have no
# manifest row yet). Sets APPLY_NEW_MANIFEST; APPLY_ADV_FAILED on mismatch.
function deploy_apply_build_manifest(){
  local target="$1"
  APPLY_NEW_MANIFEST=""
  APPLY_ADV_FAILED=0
  APPLY_EMITTED=()
  declare -A union=()
  local p=""
  for p in "${!PLAN_M_STATUS[@]}"; do union[$p]=1; done
  for p in "${!APPLY_ADV[@]}"; do union[$p]=1; done
  local -a sorted=()
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    sorted+=("$p")
  done < <(printf '%s\n' "${!union[@]}" | LC_ALL=C sort)
  for p in "${sorted[@]}"; do
    deploy_advance_row "$p" "$target"
  done
  # Delivered .new rows are appended by deploy_advance_row(sidecar) itself.
  # Strip the single trailing separator: row appends terminate themselves,
  # and the writer adds exactly one final newline (a blank line would
  # otherwise poison line-oriented readers).
  APPLY_NEW_MANIFEST="${APPLY_NEW_MANIFEST%$'\n'}"
}

# Publish manifest + identity atomically (manifest first, identity last),
# then fully verify. Sets APPLY_PUBLISHED=1 on success.
APPLY_PUBLISHED=0
function deploy_apply_publish(){
  local target="$1" outcome="$2" counts_json="$3" started="$4"
  local mf="$APPLY_SD/$DEPLOY_MANIFEST_NAME" id="$APPLY_SD/$DEPLOY_IDENTITY_NAME"
  local tag=".tmp.$$"
  deploy_cleanup_tmps "$APPLY_SD"
  deploy_write_content "$mf.$tag" "$APPLY_NEW_MANIFEST"
  mv -f "$mf.$tag" "$mf"
  if ! deploy_fault "publish-manifest"; then
    echo "error: fault injected after manifest publish" >&2
    return 1
  fi
  local fully="false" deployed="null"
  local n_total
  n_total=$(grep -c . "$mf" || true)
  if [[ "$outcome" == "complete" && "$APPLY_ADV_FAILED" == 0 ]]; then
    if deploy_apply_fully_check "$target" "$APPLY_NEW_MANIFEST"; then
      fully="true"
      deployed="\"$target\""
    fi
  fi
  local now ident fontset_json vianix_json
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [[ -n "$APPLY_FONTSET" ]]; then
    fontset_json="\"$(deploy_json_escape "$APPLY_FONTSET")\""
  else
    fontset_json="null"
  fi
  if [[ "$APPLY_VIANIX" == "true" ]]; then vianix_json="true"; else vianix_json="false"; fi
  ident=$(printf '{\n  "schema": %s,\n  "status": "adopted",\n  "fully_deployed": %s,\n  "revision": "%s",\n  "deployed_revision": %s,\n  "fontset": %s,\n  "via_nix": %s,\n  "home_root": "%s",\n  "xdg_config": "%s",\n  "adopted_at": "%s",\n  "tool": "setup apply",\n  "manifest": "%s",\n  "manifest_sha256": "%s",\n  "manifest_records": %s,\n  "legacy_evidence": "%s",\n  "legacy_evidence_records": %s,\n  "counts": %s,\n  "last_apply": {"id": "%s", "target": "%s", "finished": "%s", "outcome": "%s"}\n}\n' \
    "$DEPLOY_SCHEMA" "$fully" "$PLAN_BASE_REV" "$deployed" "$fontset_json" "$vianix_json" \
    "$(deploy_json_escape "$DEPLOY_HOME")" "$(deploy_json_escape "$DEPLOY_XDG_CONFIG")" "$APPLY_ADOPTED_AT" \
    "$DEPLOY_MANIFEST_NAME" "$(deploy_bytes_sha "$APPLY_NEW_MANIFEST")" "$n_total" \
    "$DEPLOY_EVIDENCE_NAME" "$APPLY_EV_COUNT" "$counts_json" "$APPLY_ID" "$target" "$now" "$outcome")
  deploy_write_content "$id.$tag" "$ident"
  mv -f "$id.$tag" "$id"
  if ! deploy_fault "publish-identity"; then
    echo "error: fault injected after identity publish" >&2
    return 1
  fi
  if ! deploy_verify_files "$APPLY_SD" >/dev/null 2>&1; then
    echo "error: post-publish verification failed" >&2
    return 1
  fi
  APPLY_PUBLISHED=1
}

# Strict fully_deployed computation over the ADVANCED manifest text.
# True only when every file/link row is confirmed at the single target
# with live re-verified right now, and every submodule row was already
# ok-verified at preflight (never freshly established this run) with its
# fingerprint still matching and its gitlink equal to the target's.
# Legacy/unverified submodule content can never satisfy this in 3B.
function deploy_apply_fully_check(){
  local target="$1" newmf="$2"
  local rows
  if ! rows=$(jq -r -s '.[] | [.path // "__MISSING__", .kind // "__MISSING__", .status // "__MISSING__", .blob // "__MISSING__", .rev // "__MISSING__", (if has("fingerprint") | not then "__MISSING__" else (.fingerprint // "__MISSING__") end)] | join("\t")' <<<"$newmf" 2>/dev/null); then
    return 1
  fi
  local path kind status blob rev fp disk
  while IFS=$'\t' read -r path kind status blob rev fp; do
    [[ -z "$path" ]] && continue
    if [[ "$kind" == "submodule" ]]; then
      if [[ -z "${APPLY_SUBOK[$path]:-}" || -n "${APPLY_FRESH_FP[$path]:-}" ]]; then
        return 1
      fi
      if [[ "$blob" != "${PLAN_T_SUB[$path]:-}" ]]; then
        return 1
      fi
      disk=$(deploy_map_home "$path" 2>/dev/null) || return 1
      local nowfp
      if ! nowfp=$(deploy_submodule_fingerprint "$disk" 2>/dev/null); then
        return 1
      fi
      if [[ "$nowfp" != "$fp" ]]; then
        return 1
      fi
      continue
    fi
    if [[ "$status" != "confirmed" || "$rev" != "$target" ]]; then
      return 1
    fi
    if ! disk=$(deploy_map_home "$path" 2>/dev/null); then
      return 1
    fi
    local obs t_mode
    obs=$(deploy_plan_observe "$disk")
    t_mode="${PLAN_T_MODE[$path]:-100644}"
    if [[ "$kind" == "symlink" || "$t_mode" == "120000" ]]; then
      local want
      want=$(git -C "$REPO_ROOT" cat-file -p "$blob" 2>/dev/null) || return 1
      [[ "$obs" == "link:$want" ]] || return 1
    else
      [[ "$obs" == "file:$blob" ]] || return 1
    fi
  done <<<"$rows"
  return 0
}

# Prune snapshots: keep newest 3 from successful completed applies; drop
# orphans (snapshot without any applies/<id> dir, or applies dir without
# a journal — crash debris no transaction can reference). Never touch
# snapshots of open transactions (failed outcomes never close the journal,
# so they stay open by construction).
function deploy_apply_prune(){
  local sd="$1" keep=3 d id j
  local -a cands=()
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    id=$(basename "$d")
    if [[ ! -d "$sd/$DEPLOY_APPLIES_NAME/$id" ]]; then
      echo "prune: removing orphan snapshot (no transaction): $id" >&2
      rm -rf "$d"
      continue
    fi
    j="$sd/$DEPLOY_APPLIES_NAME/$id/journal.jsonl"
    if [[ -f "$j" ]] && grep -q '"type":"completed"' "$j" 2>/dev/null && grep -q '"outcome":"complete"' "$j" 2>/dev/null; then
      cands+=("$d")
    fi
  done < <(ls -td "$sd/$DEPLOY_SNAPS_NAME"/*/ 2>/dev/null || true)
  local ad
  for ad in "$sd/$DEPLOY_APPLIES_NAME"/*/; do
    [[ -d "$ad" ]] || continue
    if [[ ! -f "${ad}journal.jsonl" ]]; then
      echo "prune: removing orphan apply dir (no journal): $ad" >&2
      rm -rf "$ad"
    fi
  done
  local n=0
  for d in "${cands[@]}"; do
    n=$((n + 1))
    if (( n > keep )); then
      rm -rf "$d"
    fi
  done
}

# --- Orchestration: fresh run, resume, abort. ---
# Globals in (set by the subcommand before calling):
#   APPLY_SD, APPLY_TARGET, APPLY_FONTSET ("" = default), APPLY_VIANIX,
#   APPLY_RESOLVE (array, ephemeral), APPLY_ID (resume/abort/break target).
# APPLY_DECISIONS_FILE: decisions path (defaults into APPLY_SD).

# Post histogram over advanced manifest text (for identity counts).
function deploy_apply_counts_json(){
  local text="$1"
  local c_confirmed c_drifted c_missing c_present c_other
  c_confirmed=$(grep -c '"status":"confirmed"' <<<"$text" || true)
  c_drifted=$(grep -c '"status":"drifted"' <<<"$text" || true)
  c_missing=$(grep -c '"status":"missing"' <<<"$text" || true)
  c_present=$(grep -c '"status":"present"' <<<"$text" || true)
  local total
  total=$(grep -c . <<<"$text" || true)
  local c_other=$((total - c_confirmed - c_drifted - c_missing - c_present))
  printf '{"confirmed":%s,"drifted":%s,"missing":%s,"present":%s,"other":%s,"total":%s}' \
    "$c_confirmed" "$c_drifted" "$c_missing" "$c_present" "$c_other" "$total"
}


# Latest ok-result post-state for a path, or empty when none.
function deploy_apply_journal_ok(){
  local jf="$1" path="$2"
  jq -r -s --arg p "$path" '[.[] | select(.type=="result" and .path==$p and .outcome=="ok")] | last | .post // empty' "$jf" 2>/dev/null || true
}

# Latest result note/post for a path (empty when none). Journal-derived so
# crash-resumed runs never depend on in-memory executor state.
function deploy_apply_journal_note(){
  local jf="$1" path="$2"
  jq -r -s --arg p "$path" '[.[] | select(.type=="result" and .path==$p)] | last | .note // empty' "$jf" 2>/dev/null || true
}

# Last sidecar delivery destination for a path (empty when none). Searches
# the full history, not just the latest result: resume's verified-skip
# markers must never obscure the original delivery note.
function deploy_apply_journal_sidecar_dest(){
  local jf="$1" path="$2"
  jq -r -s --arg p "$path" '[.[] | select(.type=="result" and .path==$p and (.note // "" | startswith("sidecar-delivered:"))) | .note | ltrimstr("sidecar-delivered:")] | last // empty' "$jf" 2>/dev/null || true
}

# Verify an already-advanced manifest (crash between manifest and identity
# publish) against journal posts and live truth. Every difference from the
# snapshot pre-state must be journaled-ok AND live-consistent right now;
# anything else refuses (abort recommended). Returns 0 when resume may
# finalize from this manifest.
function deploy_apply_verify_advanced(){
  local snap_mf="$1" cur_mf="$2" jf="$3"
  local cur_rows pre_rows ok_rows
  # NOTE: missing detail/fingerprint normalize to "-" (never ""): `read`
  # with an all-whitespace IFS (tab) collapses empty fields and would make
  # identical rows compare as different (trailing-empty truncation).
  if ! cur_rows=$(jq -r -s '.[] | [.path, .kind, .status, .blob, ((.disk // "null") | tostring), .rev, ((.detail // "-") | if . == "" then "-" else . end), ((.fingerprint // "-") | if . == "" then "-" else . end)] | join("\t")' "$cur_mf" 2>/dev/null); then
    echo "error: advanced manifest unreadable" >&2
    return 1
  fi
  if ! pre_rows=$(jq -r -s '.[] | [.path, .kind, .status, .blob, ((.disk // "null") | tostring), .rev, ((.detail // "-") | if . == "" then "-" else . end), ((.fingerprint // "-") | if . == "" then "-" else . end)] | join("\t")' "$snap_mf" 2>/dev/null); then
    echo "error: snapshot manifest unreadable" >&2
    return 1
  fi
  if ! ok_rows=$(jq -r -s '.[] | select(.type=="result" and .outcome=="ok") | [.path, .post] | join("\t")' "$jf" 2>/dev/null); then
    echo "error: journal unreadable" >&2
    return 1
  fi
  declare -A PRE=() OKPOST=() SIDECAR_POST=()
  local p rest
  while IFS=$'\t' read -r p rest; do
    [[ -z "$p" ]] && continue
    PRE[$p]="$rest"
  done < <(printf '%s\n' "$pre_rows")
  while IFS=$'\t' read -r p rest; do
    [[ -z "$p" ]] && continue
    OKPOST[$p]="$rest"
  done < <(printf '%s\n' "$ok_rows")
  # Sidecar deliveries are journaled under the live path (note
  # sidecar-delivered:<abs dest>) while the advanced manifest carries the
  # dest (.new) row. Index those dest rows by home-relative path so the
  # differing-row check below can find their journal cover.
  local sc_rel sc_post sc_dest
  while IFS=$'\t' read -r sc_rel sc_post; do
    [[ -z "$sc_rel" ]] && continue
    SIDECAR_POST[$sc_rel]="$sc_post"
  done < <(jq -r -s --arg home "$DEPLOY_HOME/" '.[] | select(.type=="result" and (.note // "" | startswith("sidecar-delivered:"))) | [((.note | ltrimstr("sidecar-delivered:") | ltrimstr($home))), .post] | join("\t")' "$jf" 2>/dev/null || true)
  local path kind status blob disk rev detail fp
  while IFS=$'\t' read -r path kind status blob disk rev detail fp; do
    [[ -z "$path" ]] && continue
    local pre="${PRE[$path]:-__ABSENT__}"
    if [[ "$pre" != "__ABSENT__" ]]; then
      # Detail is informational-only (never drives a decision): exclude it
      # from the equality check so normalized details ("-" vs classifier
      # text) do not force spurious journal cover. Compare the semantic
      # fields only (kind/status/blob/disk/rev/fingerprint).
      local pre_rest="${pre}"
      # Strip the detail (6th of 7 fields) from both sides for comparison.
      local pre_nodetail cur_nodetail
      pre_nodetail=$(awk -F'\t' '{print $1"\t"$2"\t"$3"\t"$4"\t"$5"\t"$7}' <<<"$pre_rest")
      cur_nodetail=$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$kind" "$status" "$blob" "$disk" "$rev" "$fp")
      if [[ "$cur_nodetail" == "$pre_nodetail" ]]; then
        continue
      fi
    fi
    # Differing row: must be journaled-ok with live-consistent post.
    # Sidecar dest (.new) rows are covered by the live path's delivery
    # note, not by a same-path result; check that index first.
    local post="${OKPOST[$path]:-__NONE__}"
    if [[ "$post" == "__NONE__" && -n "${SIDECAR_POST[$path]:-}" ]]; then
      post="${SIDECAR_POST[$path]}"
    fi
    if [[ "$post" == "__NONE__" ]]; then
      echo "error: advanced manifest row has no journal cover: $path" >&2
      return 1
    fi
    local disk2 live
    if ! disk2=$(deploy_map_home "$path" 2>/dev/null); then
      echo "error: cannot map path during verify: $path" >&2
      return 1
    fi
    # Submodules observe via git HEAD + fingerprint, never generic file/dir
    # probes (generic observe reports "dir" where the journal records
    # "present:<head>").
    if [[ "$kind" == "submodule" ]]; then
      live=$(deploy_plan_submodule_observe "$disk2" 2>/dev/null || echo "error:observe")
    else
      live=$(deploy_plan_observe "$disk2")
    fi
    if [[ "$live" != "$post" ]]; then
      echo "error: live diverged from journaled post-state: $path" >&2
      return 1
    fi
    if [[ "$post" == file:* ]]; then
      local h="${post#file:}"
      if [[ "$blob" != "$h" || "$disk" != "$h" ]]; then
        echo "error: advanced row inconsistent with journal post: $path" >&2
        return 1
      fi
    elif [[ "$post" == link:* ]]; then
      local want
      if ! want=$(git -C "$REPO_ROOT" cat-file -p "$blob" 2>/dev/null); then
        echo "error: unreadable blob during verify: $path" >&2
        return 1
      fi
      if [[ "${post#link:}" != "$want" ]]; then
        echo "error: advanced link row inconsistent: $path" >&2
        return 1
      fi
    elif [[ "$kind" == "submodule" ]]; then
      local nowfp
      if ! nowfp=$(deploy_submodule_fingerprint "$disk2" 2>/dev/null); then
        echo "error: submodule unverifiable during verify: $path" >&2
        return 1
      fi
      if [[ "$nowfp" != "$fp" ]]; then
        echo "error: submodule fingerprint moved during verify: $path" >&2
        return 1
      fi
    else
      echo "error: advanced row has unexpected post-state: $path ($post)" >&2
      return 1
    fi
  done <<<"$cur_rows"
  # Journaled-absent rows must actually be absent from the manifest, unless
  # they are preserved-absence rows (missing-unchanged/add-evidence with a
  # preserve choice): those intentionally remain as `missing' rows while
  # live stays absent. Distinguish by the advanced manifest status.
  declare -A CUR_STATUS=()
  local cs_cp cs_status
  while IFS=$'\t' read -r cs_cp _a cs_status _c _d _e _f _g; do
    [[ -z "$cs_cp" ]] && continue
    CUR_STATUS[$cs_cp]="$cs_status"
  done <<<"$cur_rows"
  local jp
  while IFS=$'\t' read -r jp post; do
    [[ -z "$jp" ]] && continue
    if [[ "$post" == "absent" ]]; then
      local found=false
      while IFS=$'\t' read -r cp _a _b _c _d _e _f _g; do
        if [[ "$cp" == "$jp" ]]; then found=true; break; fi
      done <<<"$cur_rows"
      if [[ "$found" == true ]]; then
        # Preserved absence stays as a `missing' row by design; anything
        # else still present is an advancement bug.
        if [[ "${CUR_STATUS[$jp]:-}" == "missing" ]]; then
          :
        else
          echo "error: deleted path still present in advanced manifest: $jp" >&2
          return 1
        fi
      fi
      local dd
      if dd=$(deploy_map_home "$jp" 2>/dev/null); then
        if [[ -e "$dd" || -L "$dd" ]]; then
          # Preserved rows are absent by definition; a live file here means
          # something reappeared after the journal. Deleted rows must stay
          # absent. Either way, refuse when live exists but the manifest
          # claims missing (preserved) — unless the path was never deleted?
          # For preserved rows live must be absent; for deleted rows live
          # must be absent too. So any live presence with an absent post is
          # a divergence, except... no exception: both require absent live.
          # (The manifest-status check above already allowed the row itself.)
          echo "error: deleted path reappeared live: $jp" >&2
          return 1
        fi
      fi
    fi
  done < <(printf '%s\n' "$ok_rows")
  return 0
}

# Resume an open transaction by id. Journal intent (target/inputs) is
# authoritative; --at/--fontset/--via-nix alongside resume are refused.
# Skips journaled-ok rows only after re-verifying live still equals the
# recorded post-state; any divergence refuses (abort recommended).
function deploy_apply_resume(){
  local id="$1"
  local jdir="$APPLY_SD/$DEPLOY_APPLIES_NAME/$id" jf="$APPLY_SD/$DEPLOY_APPLIES_NAME/$id/journal.jsonl"
  if [[ ! -f "$jf" ]]; then
    echo "error: no such transaction: $id" >&2
    return 2
  fi
  if deploy_journal_completed "$jf" || deploy_journal_aborted "$jf"; then
    echo "error: transaction $id is already closed; nothing to resume" >&2
    return 2
  fi
  if ! deploy_journal_repair "$jf"; then
    return 2
  fi
  local lock lpid
  lock=$(deploy_lock_path "$APPLY_SD")
  if [[ -f "$lock" ]]; then
    lpid=$(awk '{print $1}' "$lock" 2>/dev/null || echo "?")
    if [[ "$lpid" =~ ^[0-9]+$ ]] && kill -0 "$lpid" 2>/dev/null; then
      echo "error: transaction $id appears live (pid $lpid); refusing" >&2
      return 2
    fi
  fi
  local j_target j_fontset j_vianix
  j_target=$(deploy_journal_header_field "$jf" "target")
  j_fontset=$(deploy_journal_header_field "$jf" "fontset")
  j_vianix=$(deploy_journal_header_field "$jf" "via_nix")
  if [[ -z "$j_target" ]]; then
    echo "error: transaction journal has no usable header: $id" >&2
    return 2
  fi
  APPLY_TARGET="$j_target"
  APPLY_FONTSET=""
  if [[ -n "$j_fontset" && "$j_fontset" != "null" ]]; then APPLY_FONTSET="$j_fontset"; fi
  APPLY_VIANIX="false"
  if [[ "$j_vianix" == "true" ]]; then APPLY_VIANIX="true"; fi
  if [[ -n "${APPLY_AT_GIVEN:-}" || -n "${APPLY_INPUTS_GIVEN:-}" ]]; then
    echo "error: --resume uses the journal's target/inputs; drop --at/--fontset/--via-nix" >&2
    return 2
  fi
  unset FONTSET_DIR_NAME INSTALL_VIA_NIX
  if [[ -n "$APPLY_FONTSET" ]]; then FONTSET_DIR_NAME="$APPLY_FONTSET"; fi
  if [[ "$APPLY_VIANIX" == "true" ]]; then INSTALL_VIA_NIX=true; fi
  export FONTSET_DIR_NAME INSTALL_VIA_NIX
  APPLY_ID="$id"
  APPLY_ADIR="$jdir"
  APPLY_SDIR="$APPLY_SD/$DEPLOY_SNAPS_NAME/$id"
  if [[ ! -d "$APPLY_SDIR" ]]; then
    echo "error: snapshot missing for $id; cannot resume safely" >&2
    return 2
  fi
  # Manifest state decides the load path: untouched manifests get full
  # seal/home/schema checks; an advanced manifest (crash after manifest
  # publish) loads rows + identity without the seal, and the dedicated
  # verifier below decides whether resume may finalize from it.
  local snap_mf0="$APPLY_SDIR/manifest.jsonl" cur_mf0="$APPLY_SD/$DEPLOY_MANIFEST_NAME"
  APPLY_MANIFEST_ADVANCED=false
  if ! cmp -s "$snap_mf0" "$cur_mf0" 2>/dev/null; then
    APPLY_MANIFEST_ADVANCED=true
  fi
  if [[ "$APPLY_MANIFEST_ADVANCED" == true ]]; then
    if ! deploy_plan_load_identity "$APPLY_SD/$DEPLOY_IDENTITY_NAME"; then
      return 2
    fi
    if ! deploy_plan_load_manifest_rows "$cur_mf0"; then
      return 2
    fi
  else
    if ! deploy_plan_load_state "$APPLY_SD"; then
      return 2
    fi
  fi
  if ! deploy_plan_load_target "$APPLY_TARGET"; then
    return 2
  fi
  if ! deploy_decisions_load "$APPLY_SD/$DEPLOY_DECISIONS_NAME"; then
    return 2
  fi
  if ! deploy_lock_acquire "$APPLY_SD" "$id"; then
    return 2
  fi
  APPLY_JOURNAL="$jf"
  APPLY_SNAPFILES="$APPLY_SDIR/files"
  APPLY_SIDECAR_DEST=()
  APPLY_OP_N=$(jq -r -s '[.[].seq // 0] | max // 0' "$jf" 2>/dev/null || echo 0)
  if [[ ! "$APPLY_OP_N" =~ ^[0-9]+$ ]]; then APPLY_OP_N=0; fi
  if ! deploy_plan_compute "$APPLY_SD"; then
    echo "error: resume cannot recompute plan" >&2
    return 1
  fi
  if [[ "$APPLY_MANIFEST_ADVANCED" == true ]]; then
    if ! deploy_apply_verify_advanced "$snap_mf0" "$cur_mf0" "$jf"; then
      echo "error: manifest advanced incompatibly; abort recommended" >&2
      return 1
    fi
  fi
  if ! deploy_apply_snapshot_topup; then
    echo "error: resume snapshot top-up failed" >&2
    return 1
  fi
  if ! deploy_apply_replay_rows; then
    return 1
  fi
  if ! deploy_apply_finalize "complete"; then
    return 1
  fi
  return 0
}

# Replay rows: skip journaled-ok rows whose live still equals the recorded
# post-state; refuse the resume when a journaled row diverged; execute the
# rest through the normal executor (which re-observes and re-matches).
# A "-" post (legacy placeholder from older journals for informational
# rows) carries no verifiable state and is skipped without verification:
# those rows never mutate, so skipping is always safe. Sidecar deliveries
# are verified against the delivered dest file (journal note), never the
# untouched live path.
function deploy_apply_replay_rows(){
  local i row op class path b_blob b_disk t_blob live detail
  for ((i = 0; i < ${#DEPLOY_PLAN_ROWS[@]}; i++)); do
    row="${DEPLOY_PLAN_ROWS[$i]}"
    IFS=$'\t' read -r op class path b_blob b_disk t_blob live detail <<<"$row"
    [[ -z "$op" ]] && continue
    local past disk now sdest
    past=$(deploy_apply_journal_ok "$APPLY_JOURNAL" "$path")
    if [[ -z "$past" ]]; then
      if ! deploy_apply_exec_row "$row"; then
        return 1
      fi
      continue
    fi
    if [[ "$past" == "-" ]]; then
      deploy_apply_result "$path" ok "resume-verified-skip" "$past"
      continue
    fi
    sdest=$(deploy_apply_journal_sidecar_dest "$APPLY_JOURNAL" "$path")
    if [[ -n "$sdest" ]]; then
      now=$(deploy_plan_observe "$sdest" 2>/dev/null || echo "error:observe")
      if [[ "$now" != "$past" ]]; then
        deploy_apply_result "$path" refused "resume-diverged:$now" "-"
        echo "error: resume refused: sidecar destination for $path changed since the crash ($past -> $now); abort recommended" >&2
        return 1
      fi
      deploy_apply_result "$path" ok "resume-verified-skip" "$past"
      continue
    fi
    if ! disk=$(deploy_map_home "$path" 2>/dev/null); then
      echo "error: resume cannot map path: $path" >&2
      return 1
    fi
    # Submodule rows record "present:<head>" via the submodule observer;
    # generic file/dir observation ("dir") would never match.
    if [[ "$op" == submodule-ok || "$op" == submodule-unverified ]]; then
      now=$(deploy_plan_submodule_observe "$disk" 2>/dev/null || echo "error:observe")
    else
      now=$(deploy_plan_observe "$disk")
    fi
    if [[ "$now" != "$past" ]]; then
      deploy_apply_result "$path" refused "resume-diverged:$now" "-"
      echo "error: resume refused: $path changed since the crash ($past -> $now); abort recommended" >&2
      return 1
    fi
    deploy_apply_result "$path" ok "resume-verified-skip" "$past"
  done
}

# Abort an open transaction by id: verify the snapshot against journal
# pre-states, restore bytes/modes/links in reverse op order, restore
# pre-transaction metadata, mark aborted, drop the snapshot, unlock.
function deploy_apply_abort(){
  local id="$1"
  local jdir="$APPLY_SD/$DEPLOY_APPLIES_NAME/$id" jf="$APPLY_SD/$DEPLOY_APPLIES_NAME/$id/journal.jsonl"
  if [[ ! -f "$jf" ]]; then
    echo "error: no such transaction: $id" >&2
    return 2
  fi
  if deploy_journal_completed "$jf" || deploy_journal_aborted "$jf"; then
    echo "error: transaction $id is already closed; nothing to abort" >&2
    return 2
  fi
  if ! deploy_journal_repair "$jf"; then
    return 2
  fi
  local lock lpid
  lock=$(deploy_lock_path "$APPLY_SD")
  if [[ -f "$lock" ]]; then
    lpid=$(awk '{print $1}' "$lock" 2>/dev/null || echo "?")
    if [[ "$lpid" =~ ^[0-9]+$ ]] && kill -0 "$lpid" 2>/dev/null; then
      echo "error: transaction $id appears live (pid $lpid); refusing" >&2
      return 2
    fi
  fi
  local snapfiles="$APPLY_SD/$DEPLOY_SNAPS_NAME/$id/files"
  if [[ ! -d "$APPLY_SD/$DEPLOY_SNAPS_NAME/$id" ]]; then
    echo "error: snapshot missing for $id; cannot abort safely (manual recovery needed)" >&2
    return 2
  fi
  if ! deploy_snapshot_verify "$snapfiles" "$jf"; then
    echo "error: snapshot failed verification; refusing abort (manual recovery needed)" >&2
    return 1
  fi
  if ! deploy_lock_acquire "$APPLY_SD" "$id"; then
    return 2
  fi
  APPLY_JOURNAL="$jf"
  APPLY_OP_N=$(jq -r -s '[.[].seq // 0] | max // 0' "$jf" 2>/dev/null || echo 0)
  if [[ ! "$APPLY_OP_N" =~ ^[0-9]+$ ]]; then APPLY_OP_N=0; fi
  # Restore touched paths in reverse journal order.
  local paths p
  paths=$(jq -r -s '[.[] | select(.type=="op") | .path] | reverse | .[]' "$jf" 2>/dev/null) || {
    echo "error: journal unreadable during abort" >&2
    return 1
  }
  local failed=0
  declare -A seen_restore=()
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if [[ -n "${seen_restore[$p]:-}" ]]; then continue; fi
    seen_restore[$p]=1
    local pre
    pre=$(jq -r -s --arg pp "$p" '[.[] | select(.type=="op" and .path==$pp) | .pre] | last // empty' "$jf" 2>/dev/null)
    if ! deploy_snapshot_restore "$snapfiles" "$DEPLOY_HOME" "$p" "$pre"; then
      failed=1
    else
      APPLY_OP_N=$((APPLY_OP_N + 1))
      deploy_apply_jline "$(printf '{"seq":%s,"type":"restored","path":"%s","outcome":"ok"}' "$APPLY_OP_N" "$(deploy_json_escape "$p")")"
    fi
  done <<<"$paths"
  # Undo sidecar deliveries: each is journaled under the live path with a
  # sidecar-delivered:<abs dest> note. Restore the snapshotted previous
  # .new when present, else remove the delivered file. Live content itself
  # was never touched by a sidecar delivery (handled by the loop above).
  local dests dest
  dests=$(jq -r -s '.[] | select(.type=="result" and (.note // "" | startswith("sidecar-delivered:"))) | .note | ltrimstr("sidecar-delivered:")' "$jf" 2>/dev/null || true)
  declare -A seen_dest=()
  while IFS= read -r dest; do
    [[ -z "$dest" ]] && continue
    if [[ -n "${seen_dest[$dest]:-}" ]]; then continue; fi
    seen_dest[$dest]=1
    local rel="${dest#${DEPLOY_HOME}/}"
    if [[ "$rel" == "$dest" ]]; then
      echo "error: abort found sidecar destination outside home: $dest" >&2
      failed=1
      continue
    fi
    if [[ -e "$snapfiles/$rel" || -L "$snapfiles/$rel" ]]; then
      mkdir -p "$(dirname "$dest")" || { failed=1; continue; }
      if [[ -L "$snapfiles/$rel" ]]; then
        rm -f -- "$dest" 2>/dev/null || true
        if ! cp -P -- "$snapfiles/$rel" "$dest"; then
          echo "error: abort cannot restore previous sidecar file: $rel" >&2
          failed=1
        fi
      else
        if ! cp -p -- "$snapfiles/$rel" "$dest"; then
          echo "error: abort cannot restore previous sidecar file: $rel" >&2
          failed=1
        fi
      fi
    else
      if [[ -e "$dest" || -L "$dest" ]]; then
        rm -f -- "$dest" || { echo "error: abort cannot remove delivered sidecar file: $rel" >&2; failed=1; }
      fi
    fi
  done <<<"$dests"
  # Remove dirs we created that are still empty (best effort, reverse).
  local created d
  created=$(jq -r -s '.[] | select(.type=="mkdir") | .path' "$jf" 2>/dev/null || true)
  local -a cdirs=()
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    cdirs+=("$d")
  done <<<"$created"
  local k
  for ((k = ${#cdirs[@]} - 1; k >= 0; k--)); do
    d="${cdirs[$k]}"
    if [[ -d "$d" ]]; then
      if ! rmdir "$d" 2>/dev/null; then
        echo "warning: abort leaves non-empty created dir: $d" >&2
      fi
    fi
  done
  if (( failed != 0 )); then
    echo "error: abort could not restore every path; lock and journal kept for retry" >&2
    return 1
  fi
  # Restore pre-transaction metadata byte-for-byte, then verify.
  cp -p -- "$APPLY_SD/$DEPLOY_SNAPS_NAME/$id/manifest.jsonl" "$APPLY_SD/$DEPLOY_MANIFEST_NAME" || return 1
  cp -p -- "$APPLY_SD/$DEPLOY_SNAPS_NAME/$id/deployment-identity.json" "$APPLY_SD/$DEPLOY_IDENTITY_NAME" || return 1
  if [[ -f "$APPLY_SD/$DEPLOY_SNAPS_NAME/$id/decisions.jsonl" ]]; then
    cp -p -- "$APPLY_SD/$DEPLOY_SNAPS_NAME/$id/decisions.jsonl" "$APPLY_SD/$DEPLOY_DECISIONS_NAME" || return 1
  else
    rm -f "$APPLY_SD/$DEPLOY_DECISIONS_NAME"
  fi
  if ! deploy_verify_files "$APPLY_SD" >/dev/null 2>&1; then
    echo "error: abort restored metadata but it does not verify; manual recovery needed" >&2
    return 1
  fi
  APPLY_OP_N=$((APPLY_OP_N + 1))
  deploy_apply_jline "$(printf '{"seq":%s,"type":"aborted","finished":"%s"}' "$APPLY_OP_N" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
  rm -rf "$APPLY_SD/$DEPLOY_SNAPS_NAME/$id"
  rm -f "$lock"
  sync
  echo "abort $id complete: pre-transaction state restored"
}

# Snapshot top-up for resume: snapshot about-to-touch paths the original
# snapshot lacks (decisions may have been added since the crash).
function deploy_apply_snapshot_topup(){
  local i row op class path b_blob b_disk t_blob live detail kind
  local choice=""
  for ((i = 0; i < ${#DEPLOY_PLAN_ROWS[@]}; i++)); do
    row="${DEPLOY_PLAN_ROWS[$i]}"
    IFS=$'\t' read -r op class path b_blob b_disk t_blob live detail <<<"$row"
    [[ -z "$op" ]] && continue
    kind="$(deploy_apply_row_kind "$path")"
    choice=""
    local touches=false
    case "$op" in
      update|add|delete-stale|sidecar-new) touches=true;;
      conflict-drift|conflict-removed|delete-blocked|drift-unchanged|drift-update|drift-moved|drift-removed|missing-unchanged|add-evidence|appeared|class-changed|type-changed)
        choice=$(deploy_apply_match_decision "$path" "$op" "$live" "$t_blob" "$b_blob" "$kind")
        case "$choice" in replace|install|reinstall|delete|sidecar) touches=true;; esac;;
    esac
    if [[ "$touches" != true ]]; then continue; fi
    if [[ ! -e "$APPLY_SNAPFILES/$path" && ! -L "$APPLY_SNAPFILES/$path" ]]; then
      local disk
      if ! disk=$(deploy_map_home "$path" 2>/dev/null); then
        echo "error: resume cannot map path: $path" >&2
        return 1
      fi
      if [[ -e "$disk" || -L "$disk" ]]; then
        if ! deploy_snapshot_path "$APPLY_SNAPFILES" "$DEPLOY_HOME" "$path"; then
          return 1
        fi
      fi
    fi
    # Mirror the fresh-snapshot .new coverage (sidecar deliveries may
    # replace an existing recorded .new file).
    if [[ "$op" == "sidecar-new" || "$choice" == "sidecar" || "$class" == "sidecar" ]]; then
      local sdisk
      if sdisk=$(deploy_map_home "$path" 2>/dev/null) && [[ -f "$sdisk.new" && ! -L "$sdisk.new" ]]; then
        local rel="$path.new"
        if [[ ! -e "$APPLY_SNAPFILES/$rel" && ! -L "$APPLY_SNAPFILES/$rel" ]]; then
          mkdir -p "$(dirname "$APPLY_SNAPFILES/$rel")" || return 1
          cp -p -- "$sdisk.new" "$APPLY_SNAPFILES/$rel" || return 1
        fi
      fi
    fi
  done
}

# Set APPLY_ADV directives for every manifest path from execution results.
# Journal-ok rows advance by op+choice; everything else carries frozen.
# Reset-on-entry: a stale directive from an earlier run in the same shell
# must never leak into this build.
function deploy_apply_plan_advancement(){
  APPLY_ADV=(); APPLY_FRESH_FP=()
  local path
  for path in "${!PLAN_M_STATUS[@]}"; do
    APPLY_ADV[$path]="carry"
  done
  local i row op class path b_blob b_disk t_blob live detail kind
  local choice="" res note
  for ((i = 0; i < ${#DEPLOY_PLAN_ROWS[@]}; i++)); do
    row="${DEPLOY_PLAN_ROWS[$i]}"
    IFS=$'\t' read -r op class path b_blob b_disk t_blob live detail <<<"$row"
    [[ -z "$op" ]] && continue
    kind="$(deploy_apply_row_kind "$path")"
    res=$(deploy_apply_journal_ok "$APPLY_JOURNAL" "$path")
    [[ -z "$res" ]] && continue
    # Sidecar-routed writes (any op whose journal history records a
    # delivery) advance as sidecar rows, never as live confirmations. The
    # history search survives resume's skip markers (see the helper).
    if [[ -n "$(deploy_apply_journal_sidecar_dest "$APPLY_JOURNAL" "$path")" ]]; then
      APPLY_ADV[$path]="sidecar"
      continue
    fi
    case "$op" in
      update|add|unchanged|converged)
        if [[ -n "$res" ]]; then APPLY_ADV[$path]="confirm"; fi;;
      delete-stale|gone)
        if [[ -n "$res" ]]; then APPLY_ADV[$path]="drop"; fi;;
      sidecar-new)
        if [[ -n "$res" ]]; then APPLY_ADV[$path]="sidecar"; fi;;
      missing-unchanged|add-evidence)
        choice=$(deploy_apply_match_decision "$path" "$op" "$live" "$t_blob" "$b_blob" "$kind")
        if [[ "$choice" == "install" && -n "$res" ]]; then APPLY_ADV[$path]="confirm"; fi;;
      conflict-removed|drift-removed)
        choice=$(deploy_apply_match_decision "$path" "$op" "$live" "$t_blob" "$b_blob" "$kind")
        if [[ "$choice" == "reinstall" && -n "$res" ]]; then APPLY_ADV[$path]="confirm"
        elif [[ "$choice" == "accept-removal" && -n "$res" ]]; then APPLY_ADV[$path]="drop"; fi;;
      delete-blocked)
        choice=$(deploy_apply_match_decision "$path" "$op" "$live" "$t_blob" "$b_blob" "$kind")
        if [[ "$choice" == "delete" && -n "$res" ]]; then APPLY_ADV[$path]="drop"; fi;;
      conflict-drift|drift-unchanged|drift-update|drift-moved|appeared|class-changed|type-changed)
        choice=$(deploy_apply_match_decision "$path" "$op" "$live" "$t_blob" "$b_blob" "$kind")
        case "$choice" in
          replace|install) if [[ -n "$res" ]]; then APPLY_ADV[$path]="confirm"; fi;;
          sidecar) if [[ -n "$res" ]]; then APPLY_ADV[$path]="sidecar"; fi;;
        esac;;
      submodule-ok|submodule-unverified)
        if [[ -n "$res" ]]; then APPLY_ADV[$path]="subok"; fi;;
      preserved|user-absent|retired|sidecar-pending|submodule-missing|submodule-diverged|submodule-update-available|submodule-drifted|legacy|error)
        :;;  # carry (default): informational, failed, or blocked rows stay frozen
      *)
        echo "error: internal: unknown op in advancement mapping: $op ($path)" >&2
        return 1;;
    esac
  done
}

# Fresh apply: snapshot -> journal -> execute (fail-fast) -> finalize.
# Preflight must have passed and the lock must be acquirable here.
function deploy_apply_run_fresh(){
  APPLY_ID=$(deploy_apply_new_id)
  APPLY_ADIR="$APPLY_SD/$DEPLOY_APPLIES_NAME/$APPLY_ID"
  APPLY_SDIR="$APPLY_SD/$DEPLOY_SNAPS_NAME/$APPLY_ID"
  APPLY_SIDECAR_DEST=()
  mkdir -p "$APPLY_ADIR" || { echo "error: cannot create apply dir" >&2; return 1; }
  if ! deploy_lock_acquire "$APPLY_SD" "$APPLY_ID"; then
    return 2
  fi
  if ! deploy_fault "lock"; then
    echo "error: fault injected after lock" >&2
    return 1
  fi
  {
    printf '%s\n' "${DEPLOY_PLAN_ROWS[@]}"
  } > "$APPLY_ADIR/plan.tsv"
  if ! deploy_apply_snapshot; then
    echo "error: snapshot failed; nothing mutated" >&2
    deploy_apply_finish_abandoned
    return 1
  fi
  APPLY_JOURNAL=$(deploy_journal_file "$APPLY_SD" "$APPLY_ID")
  APPLY_SNAPFILES="$APPLY_SDIR/files"
  deploy_apply_jline "$(printf '{"seq":1,"type":"header","apply_id":"%s","target":"%s","fontset":%s,"via_nix":%s,"base_manifest_sha":"%s","plan_rows":%s,"started":"%s"}' \
    "$APPLY_ID" "$APPLY_TARGET" "$([ -n "$APPLY_FONTSET" ] && printf '"%s"' "$(deploy_json_escape "$APPLY_FONTSET")" || printf 'null')" \
    "$([ "$APPLY_VIANIX" == "true" ] && printf 'true' || printf 'false')" \
    "$(sha256sum "$APPLY_SD/$DEPLOY_MANIFEST_NAME" | awk '{print $1}')" "${#DEPLOY_PLAN_ROWS[@]}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
  APPLY_OP_N=1
  sync
  if ! deploy_fault "header"; then
    echo "error: fault injected after journal header" >&2
    return 1
  fi
  if ! deploy_fault "snapshot"; then
    echo "error: fault injected after snapshot" >&2
    return 1
  fi
  if ! deploy_fault "pre-ops"; then
    echo "error: fault injected before first op" >&2
    return 1
  fi
  if ! deploy_apply_execute; then
    # Fail-fast without closing the transaction: no completed marker, lock
    # held, snapshot present. The operator resumes or aborts explicitly;
    # either path re-verifies before touching anything further.
    echo "error: apply $APPLY_ID failed mid-transaction; state is incomplete." >&2
    echo "Resume with: setup apply --resume $APPLY_ID   (or --state-dir $APPLY_SD)" >&2
    echo "Abort with:  setup apply --abort $APPLY_ID" >&2
    return 1
  fi
  if ! deploy_apply_finalize "complete"; then
    return 1
  fi
  return 0
}

# Abandon a transaction that never mutated (snapshot/journal/lock only).
function deploy_apply_finish_abandoned(){
  rm -rf "$APPLY_ADIR" "$APPLY_SDIR"
  rm -f "$(deploy_lock_path "$APPLY_SD")"
}

# Advance + publish + verify + prune + unlock + report. Shared by fresh
# and resume paths. Arg: outcome so far ("complete" when every row
# resolved ok, else "failed"). A failed outcome never publishes and never
# closes the journal: the transaction stays open for resume/abort with the
# lock held. Only a fully published transaction writes completed.
function deploy_apply_finalize(){
  local outcome="$1"
  if [[ "$outcome" != "complete" ]]; then
    echo "error: apply $APPLY_ID finished with failures; state is incomplete (not published)." >&2
    echo "Resume with: setup apply --resume $APPLY_ID" >&2
    echo "Abort with:  setup apply --abort $APPLY_ID" >&2
    return 1
  fi
  # Provenance/counts for publication, read from pre-publish state.
  if ! APPLY_ADOPTED_AT=$(jq -r '.adopted_at // empty' "$APPLY_SD/$DEPLOY_IDENTITY_NAME" 2>/dev/null) || [[ -z "$APPLY_ADOPTED_AT" ]]; then
    echo "error: cannot read adopted_at; refusing to publish" >&2
    return 1
  fi
  if ! APPLY_EV_COUNT=$(jq -s 'length' "$APPLY_SD/$DEPLOY_EVIDENCE_NAME" 2>/dev/null); then
    echo "error: cannot count evidence; refusing to publish" >&2
    return 1
  fi
  deploy_apply_plan_advancement
  if ! deploy_apply_build_manifest "$APPLY_TARGET"; then
    echo "error: apply $APPLY_ID failed building the advanced manifest; state is incomplete (not published)." >&2
    echo "Resume with: setup apply --resume $APPLY_ID" >&2
    echo "Abort with:  setup apply --abort $APPLY_ID" >&2
    return 1
  fi
  if (( APPLY_ADV_FAILED != 0 )); then
    echo "error: apply $APPLY_ID failed re-verification before publish; state is incomplete (not published)." >&2
    echo "Resume with: setup apply --resume $APPLY_ID" >&2
    echo "Abort with:  setup apply --abort $APPLY_ID" >&2
    return 1
  fi
  local counts
  counts=$(deploy_apply_counts_json "$APPLY_NEW_MANIFEST")
  if ! deploy_apply_publish "$APPLY_TARGET" "$outcome" "$counts" "ignored-started"; then
    echo "error: apply $APPLY_ID failed at publication; state is incomplete." >&2
    echo "Resume with: setup apply --resume $APPLY_ID" >&2
    echo "Abort with:  setup apply --abort $APPLY_ID" >&2
    return 1
  fi
  deploy_apply_jline "$(printf '{"seq":%s,"type":"completed","outcome":"%s","finished":"%s"}' "$((APPLY_OP_N + 1))" "$outcome" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
  deploy_apply_prune "$APPLY_SD"
  rm -f "$(deploy_lock_path "$APPLY_SD")"
  sync
  echo "apply $APPLY_ID complete: target $APPLY_TARGET"
  return 0
}


# Shared prepare: state, target, inputs, compute, decisions, preflight
# gates — one composition used by fresh apply, --preflight, and tests
# alike, so all paths gate identically. Globals in: APPLY_SD, DEPLOY_AT
# (spec), DEPLOY_APPLY_FONTSET(_SET), DEPLOY_APPLY_VIANIX_SET,
# APPLY_RESOLVE. Globals out: APPLY_TARGET/FONTSET/VIANIX + plan/preflight
# context. Returns 0 (would proceed) or 2 (refused) or 1 (hard error).
# Creates nothing, not even the lock.
function deploy_apply_prepare_all(){
  if ! deploy_plan_load_state "$APPLY_SD"; then
    return 2
  fi
  local resolved
  if ! resolved=$(deploy_resolve_revision "${DEPLOY_AT:-HEAD}"); then
    return 1
  fi
  APPLY_TARGET="$resolved"
  unset FONTSET_DIR_NAME INSTALL_VIA_NIX
  APPLY_FONTSET=""
  if [[ "${DEPLOY_APPLY_FONTSET_SET:-false}" == true && "${DEPLOY_APPLY_FONTSET:-}" != "default" ]]; then
    FONTSET_DIR_NAME="${DEPLOY_APPLY_FONTSET}"
    APPLY_FONTSET="${DEPLOY_APPLY_FONTSET}"
  elif [[ "${DEPLOY_APPLY_FONTSET_SET:-false}" != true && -n "$PLAN_BASE_FONTSET" ]]; then
    FONTSET_DIR_NAME="$PLAN_BASE_FONTSET"
    APPLY_FONTSET="$PLAN_BASE_FONTSET"
  fi
  APPLY_VIANIX="false"
  if [[ "${DEPLOY_APPLY_VIANIX_SET:-false}" == true || "$PLAN_BASE_VIANIX" == "true" ]]; then
    INSTALL_VIA_NIX=true
    APPLY_VIANIX="true"
  fi
  export FONTSET_DIR_NAME INSTALL_VIA_NIX APPLY_TARGET APPLY_FONTSET APPLY_VIANIX
  if ! deploy_plan_load_target "$APPLY_TARGET"; then
    return 2
  fi
  local rc=0
  deploy_plan_compute "$APPLY_SD" || rc=$?
  if (( rc == 2 )); then
    return 2
  elif (( rc != 0 )); then
    echo "error: plan computation failed" >&2
    return 1
  fi
  if ! deploy_decisions_load "$APPLY_SD/$DEPLOY_DECISIONS_NAME"; then
    return 2
  fi
  if ! deploy_apply_preflight; then
    return 2
  fi
  return 0
}

# Repair a torn journal tail (crash mid-line): drop trailing invalid lines
# until the file parses or nothing valid remains. Loud about it; the header
# must survive or the journal is corrupt, not torn.
function deploy_journal_repair(){
  local jf="$1" tmp
  if [[ ! -f "$jf" ]]; then
    echo "error: journal missing: $jf" >&2
    return 1
  fi
  tmp="$jf.repair.$$"
  cp -p -- "$jf" "$tmp" || return 1
  while [[ -s "$tmp" ]]; do
    if tail -n 1 "$tmp" | jq -e . >/dev/null 2>&1; then
      break
    fi
    if [[ "$(wc -l < "$tmp")" -le 1 ]]; then
      echo "error: journal has no valid lines: $jf" >&2
      rm -f "$tmp"
      return 1
    fi
    head -n -1 "$tmp" > "$tmp.cut" && mv -f "$tmp.cut" "$tmp"
  done
  if ! grep -q '"type":"header"' "$tmp" 2>/dev/null; then
    echo "error: journal lost its header: $jf" >&2
    rm -f "$tmp"
    return 1
  fi
  if ! cmp -s "$tmp" "$jf"; then
    echo "warning: truncated torn journal tail: $jf" >&2
    mv -f "$tmp" "$jf"
  else
    rm -f "$tmp"
  fi
}
