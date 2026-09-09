# This is NOT a script for execution, but for loading functions, so NOT need execution permission or shebang.
#
# Write-capable adoption state (Slice 2). Writes ONLY deployment metadata
# inside the resolved state dir:
#   manifest.jsonl, legacy-evidence.jsonl, deployment-identity.json
# (plus same-dir `.tmp.<pid>.*` files during publication).
# Never installs, replaces, deletes, sidecars, or otherwise modifies any
# deployed/user configuration file.
#
# Publication is atomic by rename: readers only ever open the final names,
# so interruption can leave at most an orphan manifest (no identity) or
# stale tmps, both reported as incomplete by deploy_status and safely
# overwritten by the next --apply.

# shellcheck shell=bash

DEPLOY_MANIFEST_NAME="manifest.jsonl"
DEPLOY_EVIDENCE_NAME="legacy-evidence.jsonl"
DEPLOY_IDENTITY_NAME="deployment-identity.json"
DEPLOY_SCHEMA=1

# JSON-escape one string (no surrounding quotes).
function deploy_json_escape(){
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

# Resolve the metadata destination without ever defaulting across machines:
# - explicit --state-dir wins (must be absolute);
# - otherwise allowed only when the comparison home IS $HOME, and then
#   honors $XDG_CONFIG_HOME;
# - a foreign --home without explicit --state-dir is a hard error, so
#   inspecting another root can never silently record identity for it.
function deploy_state_dir_resolve(){
  local home="$1" explicit="${2:-}" canon_home canon_self
  if [[ -n "$explicit" ]]; then
    case "$explicit" in
      /*) printf '%s\n' "$explicit"; return 0;;
      *) echo "error: --state-dir must be absolute: $explicit" >&2; return 1;;
    esac
  fi
  if ! canon_home=$(cd "$home" 2>/dev/null && pwd -P); then
    echo "error: cannot canonicalize home root: $home" >&2
    return 1
  fi
  if ! canon_self=$(cd "$HOME" 2>/dev/null && pwd -P); then
    echo "error: cannot canonicalize \$HOME" >&2
    return 1
  fi
  if [[ "$canon_home" != "$canon_self" ]]; then
    echo "error: --home points at a foreign root ($canon_home); pass --state-dir explicitly to record state there" >&2
    return 1
  fi
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/illogical-impulse"
}

# Build manifest JSONL from classifier TSV (stdout). Records exactly the
# actionable universe (managed/sidecar classes, incl. submodule presence):
# user-managed rows need no records because the updater never touches them.
# Status vocabulary preserves the adoption invariant:
#   confirmed = live content matches the baseline revision (may later back
#               update planning); drifted/missing = unresolved adoption
#               state that MUST NEVER be read as previously deployed.
function deploy_manifest_build(){
  local tsv="$1" rev="$2"
  local state class path blob disk detail mode
  while IFS=$'\t' read -r state class path blob disk detail mode; do
    case "$state" in \#*) continue;; esac
    local status="" kind=""
    case "$mode" in
      120000) kind="symlink";;
      160000) kind="submodule";;
      100644|100755) kind="file";;
      *) kind="file";;
    esac
    case "$state" in
      adoptable|sidecar-clean) status="confirmed";;
      drifted|sidecar-drifted) status="drifted";;
      missing|sidecar-missing) status="missing";;
      submodule-present) status="present"; kind="submodule";;
      submodule-missing) status="missing"; kind="submodule";;
      preserved|user-absent|unclassified|input-excluded|error) continue;;
      *) echo "error: manifest builder hit unexpected state: $state" >&2; return 1;;
    esac
    local out_disk="$disk" out_detail="$detail"
    if [[ "$kind" == "submodule" ]]; then
      # Disk holds the observed submodule HEAD (or null), never content.
      # Fingerprint (self-anchored change detection, best effort here) is
      # recorded when computable; absence just means legacy-style rows.
      out_disk="null"
      out_detail="$detail"
      local fp_now=""
      if [[ "$state" == "submodule-present" ]]; then
        local hrel_abs sub_head
        if hrel_abs=$(deploy_map_home "$path" 2>/dev/null) && [[ -d "$hrel_abs" && ! -L "$hrel_abs" ]]; then
          if sub_head=$(git -C "$hrel_abs" rev-parse HEAD 2>/dev/null); then
            out_disk="\"$sub_head\""
          fi
          if fp_now=$(deploy_submodule_fingerprint "$hrel_abs" 2>/dev/null); then
            :
          else
            out_detail="${out_detail};fingerprint-unavailable"
          fi
        fi
      fi
      printf '{"path":"%s","kind":"submodule","class":"%s","status":"%s","blob":"%s","disk":%s,"rev":"%s","detail":"%s"' \
        "$(deploy_json_escape "$path")" "$class" "$status" "$blob" "$out_disk" "$rev" "$(deploy_json_escape "$out_detail")"
      if [[ -n "$fp_now" ]]; then
        printf ',"fingerprint":"%s"}\n' "$fp_now"
      else
        printf '}\n'
      fi
      continue
    fi
    if [[ "$disk" == "-" ]]; then out_disk="null"; else out_disk="\"$disk\""; fi
    # Quiet details stay "-" (never ""): `read` with an all-whitespace IFS
    # silently skips empty middle fields, so the manifest must not contain
    # any. Readers still tolerate legacy "" details.
    if [[ "$detail" == "-" || -z "$detail" ]]; then out_detail="-"; fi
    printf '{"path":"%s","kind":"%s","class":"%s","status":"%s","blob":"%s","disk":%s,"rev":"%s","detail":"%s"}\n' \
      "$(deploy_json_escape "$path")" "$kind" "$class" "$status" "$blob" "$out_disk" "$rev" "$(deploy_json_escape "$out_detail")"
  done <<<"$tsv"
}

# Import the legacy installed_listfile as WEAK evidence (stdout JSONL).
# Records only prove the old installer once wrote that path (invariant
# clause a); with no hashes they can never prove current content, so they
# live in a separate file and can only ever gate deletions behind approval.
# Lines outside the comparison home, duplicates, and blanks are skipped
# (counts to stderr for the logs).
function deploy_import_legacy(){
  local listfile="$1" imported=0 skipped=0
  if [[ -z "$listfile" || ! -f "$listfile" ]]; then
    echo "legacy import: no listfile, 0 records" >&2
    return 0
  fi
  declare -A seen=()
  local line rel
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ -z "$line" ]]; then skipped=$((skipped + 1)); continue; fi
    case "$line" in
      "${DEPLOY_HOME}"/*) ;;
      *) skipped=$((skipped + 1)); continue;;
    esac
    rel="${line#"${DEPLOY_HOME}/"}"
    if [[ -z "$rel" ]]; then skipped=$((skipped + 1)); continue; fi
    if [[ -n "${seen[$rel]:-}" ]]; then skipped=$((skipped + 1)); continue; fi
    seen[$rel]=1
    printf '{"path":"%s","provenance":"legacy-list"}\n' "$(deploy_json_escape "$rel")"
    imported=$((imported + 1))
  done < "$listfile"
  echo "legacy import: $imported records, $skipped skipped" >&2
}

# Shared content writer: the single definition of what "storing text" means,
# used by both publication and digest computation so they cannot diverge.
function deploy_write_content(){
  local file="$1" text="$2"
  if [[ -z "$text" ]]; then
    : > "$file"
  else
    printf '%s\n' "$text" > "$file"
  fi
}

# Digest of exactly the bytes deploy_write_content would store.
function deploy_bytes_sha(){
  local text="$1"
  if [[ -z "$text" ]]; then
    printf '' | sha256sum | awk '{print $1}'
  else
    printf '%s\n' "$text" | sha256sum | awk '{print $1}'
  fi
}

function deploy_content_lines(){
  local text="$1"
  if [[ -z "$text" ]]; then
    printf '0\n'
  else
    printf '%s\n' "$text" | grep -c . || true
  fi
}

# Remove our own publication tmps (stale or otherwise) from the state dir.
function deploy_cleanup_tmps(){
  local sd="$1"
  rm -f "$sd"/.tmp.*.manifest.jsonl "$sd"/.tmp.*.legacy-evidence.jsonl "$sd"/.tmp.*.deployment-identity.json 2>/dev/null || true
}

# Atomically publish one adoption: manifest, evidence, then identity LAST.
# Identity is the commit record; readers treat identity as authoritative, so
# a crash can only leave an identity-less orphan (reported incomplete).
# Args: state-dir, manifest text, evidence text, identity text (without the
# manifest_sha256 / record counts? No: caller embeds final values; this
# function only writes, renames, and verifies).
function deploy_atomic_publish(){
  local sd="$1" manifest_text="$2" evidence_text="$3" identity_text="$4"
  local tag=".tmp.$$"
  deploy_cleanup_tmps "$sd"
  deploy_write_content "$sd/$tag.manifest.jsonl" "$manifest_text"
  deploy_write_content "$sd/$tag.legacy-evidence.jsonl" "$evidence_text"
  if [[ -z "$identity_text" ]]; then
    echo "error: refusing to publish empty identity" >&2
    rm -f "$sd/$tag".*
    return 1
  fi
  printf '%s\n' "$identity_text" > "$sd/$tag.deployment-identity.json"
  mv -f "$sd/$tag.manifest.jsonl" "$sd/$DEPLOY_MANIFEST_NAME"
  mv -f "$sd/$tag.legacy-evidence.jsonl" "$sd/$DEPLOY_EVIDENCE_NAME"
  mv -f "$sd/$tag.deployment-identity.json" "$sd/$DEPLOY_IDENTITY_NAME"
  if ! deploy_verify_files "$sd"; then
    # Leave the orphan manifest (status => incomplete) but never a
    # half-verified identity behind.
    rm -f "$sd/$DEPLOY_IDENTITY_NAME"
    echo "error: post-publish verification failed; identity withdrawn" >&2
    return 1
  fi
}

# Verify a state dir's internal consistency (shared by publish and status).
# Prints findings to stderr; 0 only when identity, manifest, and evidence
# all agree.
function deploy_verify_files(){
  local sd="$1"
  local id="$sd/$DEPLOY_IDENTITY_NAME" mf="$sd/$DEPLOY_MANIFEST_NAME" ev="$sd/$DEPLOY_EVIDENCE_NAME"
  [[ -f "$id" && -f "$mf" && -f "$ev" ]] || { echo "verify: state files missing" >&2; return 1; }
  local want_sha got_sha want_mf want_ev got_mf got_ev
  # Identity fields are parsed semantically with jq: byte format,
  # whitespace, and key order must never matter for durable state.
  # (Trailing `|| true`: malformed JSON must reach the explicit check
  # below, not trip `set -e` inherited from setup.)
  local idline
  if ! idline=$(jq -r '[.manifest_sha256 // "__MISSING__", ((.manifest_records // "__MISSING__") | tostring), ((.legacy_evidence_records // "__MISSING__") | tostring)] | join("\t")' "$id" 2>/dev/null); then
    echo "verify: identity is not valid JSON" >&2
    return 1
  fi
  IFS=$'\t' read -r want_sha want_mf want_ev <<<"$idline"
  if [[ ! "$want_sha" =~ ^[0-9a-f]{64}$ || ! "$want_mf" =~ ^[0-9]+$ || ! "$want_ev" =~ ^[0-9]+$ ]]; then
    echo "verify: identity fields missing or malformed" >&2
    return 1
  fi
  got_sha=$(sha256sum "$mf" | awk '{print $1}')
  # Record counts are semantic (JSON values per file), never line counts:
  # pretty-printing must not change what verification accepts.
  if ! got_mf=$(jq -s 'length' "$mf" 2>/dev/null); then
    echo "verify: manifest is not valid JSON" >&2
    return 1
  fi
  if ! got_ev=$(jq -s 'length' "$ev" 2>/dev/null); then
    echo "verify: evidence file is not valid JSON" >&2
    return 1
  fi
  if [[ "$want_sha" != "$got_sha" ]]; then
    echo "verify: manifest sha256 mismatch (tampered or torn write)" >&2
    return 1
  fi
  if [[ "$want_mf" != "$got_mf" ]]; then
    echo "verify: manifest record count mismatch ($want_mf != $got_mf)" >&2
    return 1
  fi
  if [[ "$want_ev" != "$got_ev" ]]; then
    echo "verify: evidence record count mismatch ($want_ev != $got_ev)" >&2
    return 1
  fi
  return 0
}

# Read back adoption state. Stdout: transparent identity content plus checks.
# Verdict line is always last. The word `adoption-complete` is deliberate:
# it certifies the METADATA (a baseline was recorded against some revision),
# never that the revision is fully deployed on this machine. That separate
# claim lives only in the identity's `fully_deployed` field, and future
# planning code must treat a revision as fully deployed ONLY when
# `fully_deployed` is true — `revision` alone means "baselined against".
# Transaction awareness (Slice 3B): an open journal or live lock is never
# mistaken for steady state. Verdicts:
#   in-progress:<id>      lock held by a live pid (rc 2)
#   incomplete:<id>        open transaction, snapshot present (rc 2);
#                          resume/abort (not plain apply) decide next
#   corrupt                torn/unparseable state incl. missing snapshot
#                          for an open transaction (rc 1)
#   absent / incomplete:manifest-without-identity / corrupt:* / 
#   adoption-complete      steady-state verdicts as before (rc 2/2/1/0)
# A stale (dead-pid) lock alone never changes the verdict; it is reported
# as a note line. Only --break-lock clears it, and clearing never resolves
# transaction state.
function deploy_status(){
  local sd="$1"
  local id="$sd/$DEPLOY_IDENTITY_NAME" mf="$sd/$DEPLOY_MANIFEST_NAME" ev="$sd/$DEPLOY_EVIDENCE_NAME"
  local lock="$sd/apply.lock"
  if [[ -f "$lock" ]]; then
    local lpid lid
    lpid=$(awk '{print $1}' "$lock" 2>/dev/null || echo "?")
    lid=$(awk '{print $2}' "$lock" 2>/dev/null || echo "?")
    if [[ "$lpid" =~ ^[0-9]+$ ]] && kill -0 "$lpid" 2>/dev/null; then
      echo "state-dir: $sd"
      echo "verdict: in-progress:$lid"
      return 2
    fi
  fi
  local openj=""
  local jf jid
  for jf in "$sd/applies"/*/journal.jsonl; do
    [[ -f "$jf" ]] || continue
    # Only a complete outcome (or an abort) closes the transaction. A
    # failed completion marker leaves the transaction open for
    # resume/abort; it must never read as steady state.
    if { grep -q '"type":"completed"' "$jf" 2>/dev/null && grep -q '"outcome":"complete"' "$jf" 2>/dev/null; } || grep -q '"type":"aborted"' "$jf" 2>/dev/null; then
      continue
    fi
    jid=$(basename "$(dirname "$jf")")
    if [[ -z "$openj" ]]; then
      openj="$jid"
    else
      echo "state-dir: $sd"
      echo "verdict: corrupt:multiple-open-transactions"
      return 1
    fi
  done
  if [[ -n "$openj" ]]; then
    if [[ ! -d "$sd/snapshots/$openj" ]]; then
      echo "state-dir: $sd"
      echo "verdict: corrupt:transaction-without-snapshot:$openj"
      return 1
    fi
    echo "state-dir: $sd"
    if [[ -f "$sd/snapshots/$openj/manifest.jsonl" ]] && ! cmp -s "$sd/snapshots/$openj/manifest.jsonl" "$mf" 2>/dev/null; then
      echo "note: manifest advanced past snapshot (crash during/after publication likely)"
    fi
    echo "verdict: incomplete:$openj"
    return 2
  fi
  if [[ ! -f "$id" && ! -f "$mf" && ! -f "$ev" ]]; then
    echo "state-dir: $sd"
    if [[ -f "$lock" ]]; then
      echo "note: stale lock present with no transaction history"
    fi
    echo "verdict: absent"
    return 2
  fi
  if [[ ! -f "$id" ]]; then
    echo "state-dir: $sd"
    echo "verdict: incomplete:manifest-without-identity"
    return 2
  fi
  cat "$id"
  if [[ ! -f "$mf" ]]; then
    echo "verdict: corrupt:identity-without-manifest"
    return 1
  fi
  if [[ ! -f "$ev" ]]; then
    echo "verdict: corrupt:identity-without-evidence"
    return 1
  fi
  if deploy_verify_files "$sd" 2>/dev/null; then
    echo "checks: manifest-sha256=ok record-counts=ok"
    if [[ -f "$lock" ]]; then
      echo "note: stale lock present; no open transaction (break-lock to clear)"
    fi
    echo "verdict: adoption-complete"
    return 0
  fi
  echo "verdict: corrupt:verification-failed"
  return 1
}
