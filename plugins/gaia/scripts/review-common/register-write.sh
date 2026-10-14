#!/usr/bin/env bash
# register-write.sh — sole sanctioned writer for the shared findings register.
#
# Every review skill records findings, run entries and verdicts through this
# script.  The register is a per-story YAML file resolved via
# resolve-review-report-path.sh --type findings-register.
#
# Subcommands:
#   add            Append a finding (or merge into existing via dedup key)
#   merge          Explicitly merge two entries
#   resolve-severity  Record a severity resolution with rationale
#   set-disposition   Set entry disposition (open / resolved / triage)
#   triage-nonblocking  Auto-triage non-blocking open entries for a run
#   findings-rows  Write triage entries as Findings rows in the story file
#   record-run     Record a gate-run entry
#   gate-status    Query gate status for a run (stdout: RAN / UNVERIFIED)
#   --help         Show usage
#
# Exit codes: 0 success, 1 caller/validation error, 2 malformed register.

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_NAME="register-write.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source the shared locking helper.
# shellcheck source=../lib/acquire-lock.sh
. "$SCRIPTS_DIR/lib/acquire-lock.sh"

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

_rw_err() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
_rw_die() { local rc="$1"; shift; _rw_err "$*"; exit "$rc"; }

_rw_require_tool() {
  command -v "$1" >/dev/null 2>&1 || _rw_die 1 "$1 is required but not on PATH"
}

# Find entry index by field value in a register file.
# Usage: _rw_find_entry_idx <file> <field> <value>
# Prints the 0-based index or -1 if not found.
_rw_find_entry_idx() {
  local file="$1" field="$2" value="$3"
  export _RW_LOOKUP_VAL="$value"
  local idx
  idx="$(yq "[.entries[].${field}] | to_entries | map(select(.value == strenv(_RW_LOOKUP_VAL))) | .[0].key // -1" "$file" 2>/dev/null)" || idx="-1"
  unset _RW_LOOKUP_VAL
  printf '%s' "$idx"
}

# Force a yq path to a boolean value (yq strenv() converts bools to strings).
_rw_force_bool() {
  local file="$1" yq_path="$2" value="$3"
  if [ "$value" = "true" ]; then
    yq -i "${yq_path} = true" "$file"
  else
    yq -i "${yq_path} = false" "$file"
  fi
}

# Recompute top-level material and blocking flags from gate_ratings.
# Call after adding or merging gate_ratings on an entry.
_rw_recompute_blocking() {
  local tmp="$1" idx="$2" context="$3"
  local any_material
  any_material="$(yq "[.entries[$idx].gate_ratings[] | select(.material == true)] | length > 0" "$tmp" 2>/dev/null)" || any_material="false"
  if [ "$any_material" = "true" ]; then
    yq -i ".entries[$idx].material = true" "$tmp"
    yq -i ".entries[$idx].blocking = true" "$tmp"
    local existing_rationale
    existing_rationale="$(yq ".entries[$idx].blocking_rationale" "$tmp" 2>/dev/null)" || existing_rationale=""
    if [ -z "$existing_rationale" ] || [ "$existing_rationale" = "null" ] || [ "$existing_rationale" = '""' ]; then
      export _RW_AUTO_RATIONALE="auto: $context"
      yq -i ".entries[$idx].blocking_rationale = strenv(_RW_AUTO_RATIONALE)" "$tmp"
      unset _RW_AUTO_RATIONALE
    fi
  else
    yq -i ".entries[$idx].material = false" "$tmp"
  fi

  local any_blocking
  any_blocking="$(yq "[.entries[$idx].gate_ratings[] | select(.blocking == true)] | length > 0" "$tmp" 2>/dev/null)" || any_blocking="false"
  if [ "$any_blocking" = "true" ]; then
    local cur_blocking
    cur_blocking="$(yq ".entries[$idx].blocking" "$tmp" 2>/dev/null)" || cur_blocking="false"
    if [ "$cur_blocking" != "true" ]; then
      yq -i ".entries[$idx].blocking = true" "$tmp"
      export _RW_AUTO_RATIONALE="auto: $context"
      yq -i ".entries[$idx].blocking_rationale = strenv(_RW_AUTO_RATIONALE)" "$tmp"
      unset _RW_AUTO_RATIONALE
    fi
  fi
}

# Validate story key against safe pattern.
_rw_validate_key() {
  local key="$1"
  case "$key" in
    *..* | */* | "")
      _rw_die 1 "invalid story key: $key" ;;
  esac
  if ! grep -qE '^[A-Za-z0-9]+-[A-Za-z0-9]+(-[A-Za-z0-9_-]+)*$' <<<"$key"; then
    _rw_die 1 "invalid story key: $key"
  fi
}

# Normalise severity: case-insensitive, map template tiers.
_rw_normalise_severity() {
  local raw="$1"
  local lower
  lower="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    warning) lower="medium" ;;
    suggestion) lower="low" ;;
  esac
  printf '%s' "$lower"
}

# Validate severity.
_rw_validate_severity() {
  case "$1" in
    critical|high|medium|low) return 0 ;;
    *) _rw_die 1 "unknown severity: $1" ;;
  esac
}

# Validate type.
_rw_validate_type() {
  case "$1" in
    bug|security|tech-debt|test-debt|code-debt|doc-debt|design-debt|process-debt|framework-defect) return 0 ;;
    *) _rw_die 1 "unknown type: $1" ;;
  esac
}

# Validate disposition.
_rw_validate_disposition() {
  case "$1" in
    open|resolved|triage) return 0 ;;
    *) _rw_die 1 "unknown disposition: $1" ;;
  esac
}

# Validate gate for record-run.
_rw_validate_gate() {
  case "$1" in
    code-review|qa-tests|security-review|test-automate|test-review|performance-review) return 0 ;;
    *) _rw_die 1 "unknown gate: $1" ;;
  esac
}

# Validate outcome.
_rw_validate_outcome() {
  case "$1" in
    completed|errored) return 0 ;;
    *) _rw_die 1 "unknown outcome: $1" ;;
  esac
}

# Resolve the register path for a story key.
_rw_resolve_path() {
  local key="$1"
  "$SCRIPTS_DIR/resolve-review-report-path.sh" --key "$key" --type findings-register
}

# Create new empty register file.
_rw_create_register() {
  local path="$1" key="$2"
  mkdir -p "$(dirname "$path")"
  export _RW_KEY="$key"
  cat > "$path" <<'NEWREG'
schema_version: 1
story: PLACEHOLDER_KEY
gate_runs: []
entries: []
NEWREG
  yq -i '.story = strenv(_RW_KEY)' "$path"
  unset _RW_KEY
}

# Structural validation of an existing register.  Exit 2 on failure.
_rw_validate_structure() {
  local path="$1"
  # Parse check first.
  if ! yq '.' "$path" >/dev/null 2>&1; then
    _rw_err "structural validation failed (parse error): $path"
    exit 2
  fi
  local _rw_valid
  _rw_valid="$(yq '
    .schema_version == 1
    and ((.entries | type) == "!!seq")
    and ((.gate_runs | type) == "!!seq")
    and ([.entries[] | select(
      ((. | type) != "!!map") or (.id == null) or (.disposition == null)
      or ((.blocking | type) != "!!bool")
      or ((.gate_ratings | type) != "!!seq")
    )] | length == 0)
  ' "$path" 2>/dev/null)" || _rw_valid="__err"
  case "$_rw_valid" in
    true) ;; # valid
    *)
      _rw_err "structural validation failed: $path"
      exit 2 ;;
  esac
}

# Get next RF-n ID (highest existing + 1).
_rw_next_id() {
  local path="$1"
  local max_n
  max_n="$(yq '[.entries[].id | sub("^RF-"; "") | to_number] | max // 0' "$path" 2>/dev/null)" || max_n="0"
  case "$max_n" in
    null|"") max_n=0 ;;
  esac
  local next=$(( max_n + 1 ))
  printf 'RF-%d' "$next"
}

# Atomic write helper: copy to tmp, caller modifies tmp, then mv over.
_rw_atomic_start() {
  local path="$1"
  local tmp="${path}.tmp.$$"
  cp "$path" "$tmp"
  printf '%s' "$tmp"
}

_rw_atomic_finish() {
  local tmp="$1" path="$2"
  mv "$tmp" "$path"
}

_rw_atomic_abort() {
  local tmp="$1"
  rm -f "$tmp"
}

# Trap helper to clean up temp files and release lock on exit.
_RW_CLEANUP_TMP=""
_RW_CLEANUP_FD=""
_rw_cleanup() {
  if [ -n "$_RW_CLEANUP_TMP" ] && [ -f "$_RW_CLEANUP_TMP" ]; then
    rm -f "$_RW_CLEANUP_TMP"
  fi
  if [ -n "$_RW_CLEANUP_FD" ]; then
    release_lock "$_RW_CLEANUP_FD" 2>/dev/null || true
  fi
}
trap _rw_cleanup EXIT

# ---------------------------------------------------------------------------
# Subcommand: add
# ---------------------------------------------------------------------------

_rw_cmd_add() {
  local key="" defect="" ftype="" severity="" gate="" evidence="" impact=""
  local reproduction="" material=false blocking="" blocking_rationale=""
  local requirement_or_risk="" dedup_key=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --story) [ "$#" -ge 2 ] || _rw_die 1 "--story requires a value"; key="$2"; shift 2 ;;
      --defect) [ "$#" -ge 2 ] || _rw_die 1 "--defect requires a value"; defect="$2"; shift 2 ;;
      --type) [ "$#" -ge 2 ] || _rw_die 1 "--type requires a value"; ftype="$2"; shift 2 ;;
      --severity) [ "$#" -ge 2 ] || _rw_die 1 "--severity requires a value"; severity="$2"; shift 2 ;;
      --gate) [ "$#" -ge 2 ] || _rw_die 1 "--gate requires a value"; gate="$2"; shift 2 ;;
      --evidence) [ "$#" -ge 2 ] || _rw_die 1 "--evidence requires a value"; evidence="$2"; shift 2 ;;
      --impact) [ "$#" -ge 2 ] || _rw_die 1 "--impact requires a value"; impact="$2"; shift 2 ;;
      --reproduction) [ "$#" -ge 2 ] || _rw_die 1 "--reproduction requires a value"; reproduction="$2"; shift 2 ;;
      --material) material=true; shift 1 ;;
      --blocking) blocking="true"; shift 1 ;;
      --blocking-rationale) [ "$#" -ge 2 ] || _rw_die 1 "--blocking-rationale requires a value"; blocking_rationale="$2"; shift 2 ;;
      --requirement-or-risk) [ "$#" -ge 2 ] || _rw_die 1 "--requirement-or-risk requires a value"; requirement_or_risk="$2"; shift 2 ;;
      --dedup-key) [ "$#" -ge 2 ] || _rw_die 1 "--dedup-key requires a value"; dedup_key="$2"; shift 2 ;;
      *) _rw_die 1 "add: unknown argument: $1" ;;
    esac
  done

  [ -n "$key" ] || _rw_die 1 "add: --story is required"
  [ -n "$defect" ] || _rw_die 1 "add: --defect is required"
  [ -n "$ftype" ] || _rw_die 1 "add: --type is required"
  [ -n "$severity" ] || _rw_die 1 "add: --severity is required"
  [ -n "$gate" ] || _rw_die 1 "add: --gate is required"

  _rw_validate_key "$key"

  # Normalise severity.
  severity="$(_rw_normalise_severity "$severity")"
  _rw_validate_severity "$severity"
  _rw_validate_type "$ftype"

  # material flag forces blocking.
  if [ "$material" = "true" ]; then
    blocking="true"
    if [ -z "$blocking_rationale" ]; then
      _rw_die 1 "add: --material requires --blocking-rationale"
    fi
  fi

  # Severity-to-blocking auto-derivation when --blocking not passed.
  if [ -z "$blocking" ]; then
    case "$severity" in
      critical)
        blocking="true"
        blocking_rationale="Critical severity: ${gate} rated this defect critical"
        ;;
      high)
        blocking="true"
        blocking_rationale="High severity: ${gate} rated this defect high -- meets the blocker definition (demonstrated failure or credible unresolved risk)"
        ;;
      medium|low)
        blocking="false"
        ;;
    esac
  fi

  # When blocking is explicitly true, rationale is required.
  if [ "$blocking" = "true" ] && [ -z "$blocking_rationale" ]; then
    _rw_die 1 "add: --blocking requires --blocking-rationale"
  fi

  # Non-blocking bug with high/critical is rejected.
  if [ "$blocking" = "false" ] && [ "$ftype" = "bug" ]; then
    case "$severity" in
      critical|high)
        _rw_die 1 "add: non-blocking bug with $severity severity contradicts the blocker definition" ;;
    esac
  fi

  local reg_path
  reg_path="$(_rw_resolve_path "$key")"

  # Acquire lock.
  acquire_lock "${reg_path}.lock" 15 8
  _RW_CLEANUP_FD="8"

  # Create register if it does not exist.
  if [ ! -f "$reg_path" ]; then
    _rw_create_register "$reg_path" "$key"
  else
    _rw_validate_structure "$reg_path"
  fi

  local tmp
  tmp="$(_rw_atomic_start "$reg_path")"
  _RW_CLEANUP_TMP="$tmp"

  # Check for dedup match.
  local match_idx="-1"
  if [ -n "$dedup_key" ]; then
    match_idx="$(_rw_find_entry_idx "$tmp" "dedup_key" "$dedup_key")"
  fi

  if [ "$match_idx" != "-1" ] && [ "$match_idx" != "null" ]; then
    # Dedup merge into existing entry.
    _rw_dedup_merge "$tmp" "$match_idx" "$gate" "$severity" "$blocking" "$material" "$blocking_rationale" "$defect"
  else
    # New entry.
    _rw_new_entry "$tmp" "$key" "$defect" "$ftype" "$severity" "$gate" \
      "$evidence" "$impact" "$reproduction" "$material" "$blocking" \
      "$blocking_rationale" "$requirement_or_risk" "$dedup_key"
  fi

  _rw_atomic_finish "$tmp" "$reg_path"
  _RW_CLEANUP_TMP=""
  release_lock 8
  _RW_CLEANUP_FD=""
}

_rw_new_entry() {
  local tmp="$1" key="$2" defect="$3" ftype="$4" severity="$5" gate="$6"
  local evidence="$7" impact="$8" reproduction="$9"
  shift 9
  local material="$1" blocking="$2" blocking_rationale="$3"
  local requirement_or_risk="$4" dedup_key="$5"

  local new_id
  new_id="$(_rw_next_id "$tmp")"

  local blocking_bool="false"
  if [ "$blocking" = "true" ]; then blocking_bool="true"; fi
  local material_bool="false"
  if [ "$material" = "true" ]; then material_bool="true"; fi

  export _RW_ID="$new_id"
  export _RW_DEFECT="$defect"
  export _RW_TYPE="$ftype"
  export _RW_SEVERITY="$severity"
  export _RW_GATE="$gate"
  export _RW_EVIDENCE="${evidence:-}"
  export _RW_IMPACT="${impact:-}"
  export _RW_REPRODUCTION="${reproduction:-}"
  export _RW_MATERIAL="$material_bool"
  export _RW_BLOCKING="$blocking_bool"
  export _RW_BLOCKING_RATIONALE="${blocking_rationale:-}"
  export _RW_REQUIREMENT_OR_RISK="${requirement_or_risk:-}"
  export _RW_DEDUP_KEY="${dedup_key:-}"
  export _RW_TIMESTAMP
  _RW_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  yq -i '
    .entries += [{
      "id": strenv(_RW_ID),
      "defect": strenv(_RW_DEFECT),
      "requirement_or_risk": strenv(_RW_REQUIREMENT_OR_RISK),
      "evidence": strenv(_RW_EVIDENCE),
      "impact": strenv(_RW_IMPACT),
      "type": strenv(_RW_TYPE),
      "severity": strenv(_RW_SEVERITY),
      "reproduction": strenv(_RW_REPRODUCTION),
      "material": env(_RW_MATERIAL),
      "blocking": env(_RW_BLOCKING),
      "blocking_rationale": strenv(_RW_BLOCKING_RATIONALE),
      "dedup_key": strenv(_RW_DEDUP_KEY),
      "originating_gates": [strenv(_RW_GATE)],
      "gate_ratings": [{
        "gate": strenv(_RW_GATE),
        "severity": strenv(_RW_SEVERITY),
        "blocking": env(_RW_BLOCKING),
        "material": env(_RW_MATERIAL)
      }],
      "owner": "",
      "priority": "",
      "disposition": "open",
      "history": [{
        "at": strenv(_RW_TIMESTAMP),
        "gate": strenv(_RW_GATE),
        "action": "created",
        "note": "initial finding"
      }]
    }]
  ' "$tmp"

  # Force boolean types (yq strenv() converts bools to strings).
  local idx
  idx="$(yq '.entries | length - 1' "$tmp")"
  _rw_force_bool "$tmp" ".entries[$idx].material" "$material_bool"
  _rw_force_bool "$tmp" ".entries[$idx].gate_ratings[0].material" "$material_bool"
  _rw_force_bool "$tmp" ".entries[$idx].blocking" "$blocking_bool"
  _rw_force_bool "$tmp" ".entries[$idx].gate_ratings[0].blocking" "$blocking_bool"

  unset _RW_ID _RW_DEFECT _RW_TYPE _RW_SEVERITY _RW_GATE _RW_EVIDENCE
  unset _RW_IMPACT _RW_REPRODUCTION _RW_MATERIAL _RW_BLOCKING
  unset _RW_BLOCKING_RATIONALE _RW_REQUIREMENT_OR_RISK _RW_DEDUP_KEY _RW_TIMESTAMP
}

_rw_dedup_merge() {
  local tmp="$1" idx="$2" gate="$3" severity="$4" blocking="$5"
  local material="$6" blocking_rationale="$7" defect="$8"

  local blocking_bool="false"
  if [ "$blocking" = "true" ]; then blocking_bool="true"; fi
  local material_bool="false"
  if [ "$material" = "true" ]; then material_bool="true"; fi

  export _RW_GATE="$gate"
  export _RW_SEVERITY="$severity"
  export _RW_MATERIAL="$material_bool"
  export _RW_BLOCKING="$blocking_bool"
  export _RW_TIMESTAMP
  _RW_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Append gate to originating_gates if not present.
  local already_present
  already_present="$(yq ".entries[$idx].originating_gates[] | select(. == strenv(_RW_GATE))" "$tmp" 2>/dev/null)" || already_present=""
  if [ -z "$already_present" ]; then
    yq -i ".entries[$idx].originating_gates += [strenv(_RW_GATE)]" "$tmp"
  fi

  # Append gate rating.
  yq -i ".entries[$idx].gate_ratings += [{
    \"gate\": strenv(_RW_GATE),
    \"severity\": strenv(_RW_SEVERITY),
    \"blocking\": env(_RW_BLOCKING),
    \"material\": env(_RW_MATERIAL)
  }]" "$tmp"

  # Force boolean types on new gate_rating.
  local gr_len
  gr_len="$(yq ".entries[$idx].gate_ratings | length" "$tmp")"
  local gr_last=$(( gr_len - 1 ))
  _rw_force_bool "$tmp" ".entries[$idx].gate_ratings[$gr_last].blocking" "$blocking_bool"
  _rw_force_bool "$tmp" ".entries[$idx].gate_ratings[$gr_last].material" "$material_bool"

  _rw_recompute_blocking "$tmp" "$idx" "dedup merge from ${gate}"

  # If the existing entry is resolved, reopen it.
  local cur_disp
  cur_disp="$(yq ".entries[$idx].disposition" "$tmp" 2>/dev/null)" || cur_disp=""
  if [ "$cur_disp" = "resolved" ]; then
    # Move severity_resolution to history if present.
    local has_sr
    has_sr="$(yq ".entries[$idx] | has(\"severity_resolution\")" "$tmp" 2>/dev/null)" || has_sr="false"
    if [ "$has_sr" = "true" ]; then
      export _RW_HIST_TIMESTAMP="$_RW_TIMESTAMP"
      export _RW_HIST_GATE="$gate"
      yq -i ".entries[$idx].history += [{
        \"at\": strenv(_RW_HIST_TIMESTAMP),
        \"gate\": strenv(_RW_HIST_GATE),
        \"action\": \"severity_resolution_archived\",
        \"note\": \"severity_resolution moved to history on reopen\"
      }]" "$tmp"
      # Archive the resolution data into the history entry.
      yq -i ".entries[$idx].history[-1].archived_resolution = .entries[$idx].severity_resolution" "$tmp"
      yq -i "del(.entries[$idx].severity_resolution)" "$tmp"
      unset _RW_HIST_TIMESTAMP _RW_HIST_GATE
    fi
    yq -i ".entries[$idx].disposition = \"open\"" "$tmp"
    # Record reopen in history.
    export _RW_REOPEN_TIMESTAMP="$_RW_TIMESTAMP"
    export _RW_REOPEN_GATE="$gate"
    yq -i ".entries[$idx].history += [{
      \"at\": strenv(_RW_REOPEN_TIMESTAMP),
      \"gate\": strenv(_RW_REOPEN_GATE),
      \"action\": \"reopen\",
      \"note\": \"reopened by new finding from gate\"
    }]" "$tmp"
    unset _RW_REOPEN_TIMESTAMP _RW_REOPEN_GATE
  fi

  unset _RW_GATE _RW_SEVERITY _RW_MATERIAL _RW_BLOCKING _RW_TIMESTAMP
}

# ---------------------------------------------------------------------------
# Subcommand: merge
# ---------------------------------------------------------------------------

_rw_cmd_merge() {
  local key="" source_id="" target_id=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --story) [ "$#" -ge 2 ] || _rw_die 1 "--story requires a value"; key="$2"; shift 2 ;;
      --source-id) [ "$#" -ge 2 ] || _rw_die 1 "--source-id requires a value"; source_id="$2"; shift 2 ;;
      --target-id) [ "$#" -ge 2 ] || _rw_die 1 "--target-id requires a value"; target_id="$2"; shift 2 ;;
      *) _rw_die 1 "merge: unknown argument: $1" ;;
    esac
  done

  [ -n "$key" ] || _rw_die 1 "merge: --story is required"
  [ -n "$source_id" ] || _rw_die 1 "merge: --source-id is required"
  [ -n "$target_id" ] || _rw_die 1 "merge: --target-id is required"

  _rw_validate_key "$key"

  local reg_path
  reg_path="$(_rw_resolve_path "$key")"

  [ -f "$reg_path" ] || _rw_die 1 "merge: register not found: $reg_path"

  acquire_lock "${reg_path}.lock" 15 8
  _RW_CLEANUP_FD="8"

  _rw_validate_structure "$reg_path"

  local tmp
  tmp="$(_rw_atomic_start "$reg_path")"
  _RW_CLEANUP_TMP="$tmp"

  # Find source and target indices.
  local src_idx
  src_idx="$(_rw_find_entry_idx "$tmp" "id" "$source_id")"
  local tgt_idx
  tgt_idx="$(_rw_find_entry_idx "$tmp" "id" "$target_id")"

  if [ "$src_idx" = "-1" ] || [ "$src_idx" = "null" ]; then
    _rw_die 1 "merge: source entry not found: $source_id"
  fi
  if [ "$tgt_idx" = "-1" ] || [ "$tgt_idx" = "null" ]; then
    _rw_die 1 "merge: target entry not found: $target_id"
  fi

  # Determine survivor ID: lower of source and target.
  local src_n tgt_n
  src_n="$(printf '%s' "$source_id" | sed 's/^RF-//')"
  tgt_n="$(printf '%s' "$target_id" | sed 's/^RF-//')"
  local survivor_id="$target_id"
  if [ "$src_n" -lt "$tgt_n" ]; then
    survivor_id="$source_id"
  fi

  # Union originating_gates from source into target.
  local src_gates
  src_gates="$(yq ".entries[$src_idx].originating_gates[]" "$tmp" 2>/dev/null)" || src_gates=""
  local g
  if [ -n "$src_gates" ]; then
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      export _RW_MERGE_GATE="$g"
      local present
      present="$(yq ".entries[$tgt_idx].originating_gates[] | select(. == strenv(_RW_MERGE_GATE))" "$tmp" 2>/dev/null)" || present=""
      if [ -z "$present" ]; then
        yq -i ".entries[$tgt_idx].originating_gates += [strenv(_RW_MERGE_GATE)]" "$tmp"
      fi
      unset _RW_MERGE_GATE
    done <<< "$src_gates"
  fi

  # Union gate_ratings from source into target.
  local src_gr_len
  src_gr_len="$(yq ".entries[$src_idx].gate_ratings | length" "$tmp" 2>/dev/null)" || src_gr_len="0"
  local i=0
  while [ "$i" -lt "$src_gr_len" ]; do
    local gr_yaml
    gr_yaml="$(yq -o=json ".entries[$src_idx].gate_ratings[$i]" "$tmp" 2>/dev/null)" || gr_yaml=""
    if [ -n "$gr_yaml" ]; then
      export _RW_GR_JSON="$gr_yaml"
      yq -i ".entries[$tgt_idx].gate_ratings += [env(_RW_GR_JSON) | from_json]" "$tmp" 2>/dev/null || \
        yq -i ".entries[$tgt_idx].gate_ratings += [strenv(_RW_GR_JSON) | from_json]" "$tmp" 2>/dev/null || true
      unset _RW_GR_JSON
    fi
    i=$(( i + 1 ))
  done

  # Set survivor ID.
  export _RW_SURVIVOR_ID="$survivor_id"
  yq -i ".entries[$tgt_idx].id = strenv(_RW_SURVIVOR_ID)" "$tmp"
  unset _RW_SURVIVOR_ID

  _rw_recompute_blocking "$tmp" "$tgt_idx" "merge of ${source_id} into ${target_id}"

  # Record merge in history.
  export _RW_MERGE_TIMESTAMP
  _RW_MERGE_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  export _RW_MERGE_NOTE="merged ${source_id} into ${target_id}"
  yq -i ".entries[$tgt_idx].history += [{
    \"at\": strenv(_RW_MERGE_TIMESTAMP),
    \"gate\": \"merge\",
    \"action\": \"merge\",
    \"note\": strenv(_RW_MERGE_NOTE)
  }]" "$tmp"
  unset _RW_MERGE_TIMESTAMP _RW_MERGE_NOTE

  # Remove source entry.
  yq -i "del(.entries[$src_idx])" "$tmp"

  _rw_atomic_finish "$tmp" "$reg_path"
  _RW_CLEANUP_TMP=""
  release_lock 8
  _RW_CLEANUP_FD=""
}

# ---------------------------------------------------------------------------
# Subcommand: resolve-severity
# ---------------------------------------------------------------------------

_rw_cmd_resolve_severity() {
  local key="" entry_id="" severity="" blocking="" rationale=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --story) [ "$#" -ge 2 ] || _rw_die 1 "--story requires a value"; key="$2"; shift 2 ;;
      --id) [ "$#" -ge 2 ] || _rw_die 1 "--id requires a value"; entry_id="$2"; shift 2 ;;
      --severity) [ "$#" -ge 2 ] || _rw_die 1 "--severity requires a value"; severity="$2"; shift 2 ;;
      --blocking) [ "$#" -ge 2 ] || _rw_die 1 "--blocking requires a value"; blocking="$2"; shift 2 ;;
      --rationale) [ "$#" -ge 2 ] || _rw_die 1 "--rationale requires a value"; rationale="$2"; shift 2 ;;
      *) _rw_die 1 "resolve-severity: unknown argument: $1" ;;
    esac
  done

  [ -n "$key" ] || _rw_die 1 "resolve-severity: --story is required"
  [ -n "$entry_id" ] || _rw_die 1 "resolve-severity: --id is required"
  [ -n "$severity" ] || _rw_die 1 "resolve-severity: --severity is required"
  [ -n "$blocking" ] || _rw_die 1 "resolve-severity: --blocking is required"
  [ -n "$rationale" ] || _rw_die 1 "resolve-severity: --rationale is required (non-empty)"

  # Trim whitespace from rationale.
  local trimmed
  trimmed="$(printf '%s' "$rationale" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [ -z "$trimmed" ]; then
    _rw_die 1 "resolve-severity: rationale must be non-empty (got only whitespace)"
  fi

  _rw_validate_key "$key"
  severity="$(_rw_normalise_severity "$severity")"
  _rw_validate_severity "$severity"

  local reg_path
  reg_path="$(_rw_resolve_path "$key")"
  [ -f "$reg_path" ] || _rw_die 1 "resolve-severity: register not found: $reg_path"

  acquire_lock "${reg_path}.lock" 15 8
  _RW_CLEANUP_FD="8"

  _rw_validate_structure "$reg_path"

  local tmp
  tmp="$(_rw_atomic_start "$reg_path")"
  _RW_CLEANUP_TMP="$tmp"

  # Find entry by ID.
  local idx
  idx="$(_rw_find_entry_idx "$tmp" "id" "$entry_id")"

  if [ "$idx" = "-1" ] || [ "$idx" = "null" ]; then
    _rw_die 1 "resolve-severity: entry not found: $entry_id"
  fi

  # Check if entry is material — cannot clear material via resolution.
  local cur_material
  cur_material="$(yq ".entries[$idx].material" "$tmp" 2>/dev/null)" || cur_material="false"
  if [ "$cur_material" = "true" ]; then
    # Material cannot be cleared.  Force blocking to true regardless.
    if [ "$blocking" = "false" ]; then
      # Resolution cannot clear material; blocking stays true.
      # We allow the resolution to be recorded but override blocking.
      blocking="true"
    fi
  fi

  # Non-blocking bug guard for resolve-severity.
  local entry_type
  entry_type="$(yq ".entries[$idx].type" "$tmp" 2>/dev/null)" || entry_type=""
  if [ "$entry_type" = "bug" ] && [ "$blocking" = "false" ]; then
    case "$severity" in
      critical|high)
        _rw_die 1 "resolve-severity: non-blocking bug with $severity severity contradicts the blocker definition" ;;
    esac
  fi

  # Write severity_resolution.
  export _RW_RSEV="$severity"
  export _RW_RRAT="$rationale"

  local blocking_val="false"
  if [ "$blocking" = "true" ]; then blocking_val="true"; fi

  yq -i ".entries[$idx].severity_resolution = {
    \"resolved_severity\": strenv(_RW_RSEV),
    \"resolved_blocking\": ${blocking_val},
    \"rationale\": strenv(_RW_RRAT)
  }" "$tmp"

  # Mirror to top level.
  yq -i ".entries[$idx].severity = strenv(_RW_RSEV)" "$tmp"
  _rw_force_bool "$tmp" ".entries[$idx].blocking" "$blocking_val"

  unset _RW_RSEV _RW_RRAT

  _rw_atomic_finish "$tmp" "$reg_path"
  _RW_CLEANUP_TMP=""
  release_lock 8
  _RW_CLEANUP_FD=""
}

# ---------------------------------------------------------------------------
# Subcommand: set-disposition
# ---------------------------------------------------------------------------

_rw_cmd_set_disposition() {
  local key="" entry_id="" disposition="" owner="" priority=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --story) [ "$#" -ge 2 ] || _rw_die 1 "--story requires a value"; key="$2"; shift 2 ;;
      --id) [ "$#" -ge 2 ] || _rw_die 1 "--id requires a value"; entry_id="$2"; shift 2 ;;
      --disposition) [ "$#" -ge 2 ] || _rw_die 1 "--disposition requires a value"; disposition="$2"; shift 2 ;;
      --owner) [ "$#" -ge 2 ] || _rw_die 1 "--owner requires a value"; owner="$2"; shift 2 ;;
      --priority) [ "$#" -ge 2 ] || _rw_die 1 "--priority requires a value"; priority="$2"; shift 2 ;;
      *) _rw_die 1 "set-disposition: unknown argument: $1" ;;
    esac
  done

  [ -n "$key" ] || _rw_die 1 "set-disposition: --story is required"
  [ -n "$entry_id" ] || _rw_die 1 "set-disposition: --id is required"
  [ -n "$disposition" ] || _rw_die 1 "set-disposition: --disposition is required"

  _rw_validate_key "$key"
  _rw_validate_disposition "$disposition"

  if [ "$disposition" = "triage" ]; then
    [ -n "$owner" ] || _rw_die 1 "set-disposition: triage requires --owner"
    [ -n "$priority" ] || _rw_die 1 "set-disposition: triage requires --priority"
  fi

  local reg_path
  reg_path="$(_rw_resolve_path "$key")"
  [ -f "$reg_path" ] || _rw_die 1 "set-disposition: register not found: $reg_path"

  acquire_lock "${reg_path}.lock" 15 8
  _RW_CLEANUP_FD="8"

  _rw_validate_structure "$reg_path"

  local tmp
  tmp="$(_rw_atomic_start "$reg_path")"
  _RW_CLEANUP_TMP="$tmp"

  local idx
  idx="$(_rw_find_entry_idx "$tmp" "id" "$entry_id")"

  if [ "$idx" = "-1" ] || [ "$idx" = "null" ]; then
    _rw_die 1 "set-disposition: entry not found: $entry_id"
  fi

  # Triage guard: high/critical blocking bug cannot be triaged directly.
  if [ "$disposition" = "triage" ]; then
    local entry_type entry_sev entry_blk
    entry_type="$(yq ".entries[$idx].type" "$tmp" 2>/dev/null)" || entry_type=""
    entry_sev="$(yq ".entries[$idx].severity" "$tmp" 2>/dev/null)" || entry_sev=""
    entry_blk="$(yq ".entries[$idx].blocking" "$tmp" 2>/dev/null)" || entry_blk=""
    if [ "$entry_type" = "bug" ] && [ "$entry_blk" = "true" ]; then
      case "$entry_sev" in
        critical|high)
          _rw_die 1 "set-disposition: high/critical blocking bug cannot be triaged directly; use resolve-severity first" ;;
      esac
    fi
  fi

  yq -i ".entries[$idx].disposition = \"${disposition}\"" "$tmp"
  if [ -n "$owner" ]; then
    export _RW_OWNER="$owner"
    yq -i ".entries[$idx].owner = strenv(_RW_OWNER)" "$tmp"
    unset _RW_OWNER
  fi
  if [ -n "$priority" ]; then
    export _RW_PRIORITY="$priority"
    yq -i ".entries[$idx].priority = strenv(_RW_PRIORITY)" "$tmp"
    unset _RW_PRIORITY
  fi

  _rw_atomic_finish "$tmp" "$reg_path"
  _RW_CLEANUP_TMP=""
  release_lock 8
  _RW_CLEANUP_FD=""
}

# ---------------------------------------------------------------------------
# Subcommand: triage-nonblocking
# ---------------------------------------------------------------------------

_rw_cmd_triage_nonblocking() {
  local key="" run_id=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --story) [ "$#" -ge 2 ] || _rw_die 1 "--story requires a value"; key="$2"; shift 2 ;;
      --run-id) [ "$#" -ge 2 ] || _rw_die 1 "--run-id requires a value"; run_id="$2"; shift 2 ;;
      *) _rw_die 1 "triage-nonblocking: unknown argument: $1" ;;
    esac
  done

  [ -n "$key" ] || _rw_die 1 "triage-nonblocking: --story is required"
  [ -n "$run_id" ] || _rw_die 1 "triage-nonblocking: --run-id is required"

  _rw_validate_key "$key"

  local reg_path
  reg_path="$(_rw_resolve_path "$key")"
  [ -f "$reg_path" ] || _rw_die 1 "triage-nonblocking: register not found: $reg_path"

  acquire_lock "${reg_path}.lock" 15 8
  _RW_CLEANUP_FD="8"

  _rw_validate_structure "$reg_path"

  local tmp
  tmp="$(_rw_atomic_start "$reg_path")"
  _RW_CLEANUP_TMP="$tmp"

  local entry_count
  entry_count="$(yq '.entries | length' "$tmp" 2>/dev/null)" || entry_count="0"

  local i=0
  while [ "$i" -lt "$entry_count" ]; do
    local disp blk
    disp="$(yq ".entries[$i].disposition" "$tmp" 2>/dev/null)" || disp=""
    blk="$(yq ".entries[$i].blocking" "$tmp" 2>/dev/null)" || blk=""

    if [ "$disp" = "open" ] && [ "$blk" != "true" ]; then
      # Check for disagreement (mixed blocking in gate_ratings, no resolution).
      local has_mixed="false"
      local has_any_blocking has_any_non_blocking
      has_any_blocking="$(yq "[.entries[$i].gate_ratings[] | select(.blocking == true)] | length > 0" "$tmp" 2>/dev/null)" || has_any_blocking="false"
      has_any_non_blocking="$(yq "[.entries[$i].gate_ratings[] | select(.blocking == false)] | length > 0" "$tmp" 2>/dev/null)" || has_any_non_blocking="false"
      if [ "$has_any_blocking" = "true" ] && [ "$has_any_non_blocking" = "true" ]; then
        local has_sr
        has_sr="$(yq ".entries[$i] | has(\"severity_resolution\")" "$tmp" 2>/dev/null)" || has_sr="false"
        if [ "$has_sr" != "true" ]; then
          has_mixed="true"
        fi
      fi

      if [ "$has_mixed" = "true" ]; then
        # Skip disagreement entries.
        i=$(( i + 1 ))
        continue
      fi

      # Determine priority from severity.
      local sev
      sev="$(yq ".entries[$i].severity" "$tmp" 2>/dev/null)" || sev="low"
      local auto_priority="$sev"

      # Get first originating gate as owner.
      local auto_owner
      auto_owner="$(yq ".entries[$i].originating_gates[0]" "$tmp" 2>/dev/null)" || auto_owner="unknown"

      export _RW_OWNER="$auto_owner"
      export _RW_PRIORITY="$auto_priority"
      yq -i ".entries[$i].disposition = \"triage\"" "$tmp"
      yq -i ".entries[$i].owner = strenv(_RW_OWNER)" "$tmp"
      yq -i ".entries[$i].priority = strenv(_RW_PRIORITY)" "$tmp"
      unset _RW_OWNER _RW_PRIORITY
    fi

    i=$(( i + 1 ))
  done

  _rw_atomic_finish "$tmp" "$reg_path"
  _RW_CLEANUP_TMP=""
  release_lock 8
  _RW_CLEANUP_FD=""
}

# ---------------------------------------------------------------------------
# Subcommand: record-run
# ---------------------------------------------------------------------------

_rw_cmd_record_run() {
  local key="" run_id="" gate="" outcome=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --story) [ "$#" -ge 2 ] || _rw_die 1 "--story requires a value"; key="$2"; shift 2 ;;
      --run-id) [ "$#" -ge 2 ] || _rw_die 1 "--run-id requires a value"; run_id="$2"; shift 2 ;;
      --gate) [ "$#" -ge 2 ] || _rw_die 1 "--gate requires a value"; gate="$2"; shift 2 ;;
      --outcome) [ "$#" -ge 2 ] || _rw_die 1 "--outcome requires a value"; outcome="$2"; shift 2 ;;
      *) _rw_die 1 "record-run: unknown argument: $1" ;;
    esac
  done

  [ -n "$key" ] || _rw_die 1 "record-run: --story is required"
  [ -n "$run_id" ] || _rw_die 1 "record-run: --run-id is required"
  [ -n "$gate" ] || _rw_die 1 "record-run: --gate is required"
  [ -n "$outcome" ] || _rw_die 1 "record-run: --outcome is required"

  _rw_validate_key "$key"
  _rw_validate_gate "$gate"
  _rw_validate_outcome "$outcome"

  local reg_path
  reg_path="$(_rw_resolve_path "$key")"

  acquire_lock "${reg_path}.lock" 15 8
  _RW_CLEANUP_FD="8"

  if [ ! -f "$reg_path" ]; then
    _rw_create_register "$reg_path" "$key"
  else
    _rw_validate_structure "$reg_path"
  fi

  local tmp
  tmp="$(_rw_atomic_start "$reg_path")"
  _RW_CLEANUP_TMP="$tmp"

  export _RW_RUN_ID="$run_id"
  export _RW_GATE="$gate"
  export _RW_OUTCOME="$outcome"
  export _RW_TIMESTAMP
  _RW_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  yq -i '.gate_runs += [{
    "run_id": strenv(_RW_RUN_ID),
    "gate": strenv(_RW_GATE),
    "at": strenv(_RW_TIMESTAMP),
    "outcome": strenv(_RW_OUTCOME)
  }]' "$tmp"

  unset _RW_RUN_ID _RW_GATE _RW_OUTCOME _RW_TIMESTAMP

  _rw_atomic_finish "$tmp" "$reg_path"
  _RW_CLEANUP_TMP=""
  release_lock 8
  _RW_CLEANUP_FD=""
}

# ---------------------------------------------------------------------------
# Subcommand: gate-status
# ---------------------------------------------------------------------------

_rw_cmd_gate_status() {
  local key="" run_id="" gate=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --story) [ "$#" -ge 2 ] || _rw_die 1 "--story requires a value"; key="$2"; shift 2 ;;
      --run-id) [ "$#" -ge 2 ] || _rw_die 1 "--run-id requires a value"; run_id="$2"; shift 2 ;;
      --gate) [ "$#" -ge 2 ] || _rw_die 1 "--gate requires a value"; gate="$2"; shift 2 ;;
      *) _rw_die 1 "gate-status: unknown argument: $1" ;;
    esac
  done

  [ -n "$key" ] || _rw_die 1 "gate-status: --story is required"
  [ -n "$run_id" ] || _rw_die 1 "gate-status: --run-id is required"
  [ -n "$gate" ] || _rw_die 1 "gate-status: --gate is required"

  _rw_validate_key "$key"

  local reg_path
  reg_path="$(_rw_resolve_path "$key")"
  [ -f "$reg_path" ] || { printf 'UNVERIFIED\n'; exit 0; }

  _rw_validate_structure "$reg_path"

  export _RW_RUN_ID="$run_id"
  export _RW_GATE="$gate"
  local match
  match="$(yq '[.gate_runs[] | select(.run_id == strenv(_RW_RUN_ID) and .gate == strenv(_RW_GATE))] | length' "$reg_path" 2>/dev/null)" || match="0"

  if [ "$match" = "0" ] || [ "$match" = "null" ]; then
    unset _RW_RUN_ID _RW_GATE
    printf 'UNVERIFIED\n'
    exit 0
  fi

  # Check outcome.
  local outcome
  outcome="$(yq '[.gate_runs[] | select(.run_id == strenv(_RW_RUN_ID) and .gate == strenv(_RW_GATE))][-1].outcome' "$reg_path" 2>/dev/null)" || outcome=""
  unset _RW_RUN_ID _RW_GATE

  case "$outcome" in
    completed) printf 'RAN\n' ;;
    *) printf 'UNVERIFIED\n' ;;
  esac
  exit 0
}

# ---------------------------------------------------------------------------
# Subcommand: findings-rows
# ---------------------------------------------------------------------------

_rw_cmd_findings_rows() {
  local key="" run_id=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --story) [ "$#" -ge 2 ] || _rw_die 1 "--story requires a value"; key="$2"; shift 2 ;;
      --run-id) [ "$#" -ge 2 ] || _rw_die 1 "--run-id requires a value"; run_id="$2"; shift 2 ;;
      *) _rw_die 1 "findings-rows: unknown argument: $1" ;;
    esac
  done

  [ -n "$key" ] || _rw_die 1 "findings-rows: --story is required"
  [ -n "$run_id" ] || _rw_die 1 "findings-rows: --run-id is required"

  _rw_validate_key "$key"

  local reg_path
  reg_path="$(_rw_resolve_path "$key")"
  [ -f "$reg_path" ] || _rw_die 1 "findings-rows: register not found: $reg_path"

  _rw_validate_structure "$reg_path"

  # Resolve story file path.
  local story_file
  story_file="$("$SCRIPTS_DIR/resolve-story-file.sh" "$key" 2>/dev/null)" || \
    _rw_die 1 "findings-rows: cannot resolve story file for: $key"
  [ -f "$story_file" ] || _rw_die 1 "findings-rows: story file not found: $story_file"

  # Read triage entries from register.
  local entry_count
  entry_count="$(yq '.entries | length' "$reg_path" 2>/dev/null)" || entry_count="0"

  # Build rows in a temp file.
  local rows_file="$reg_path.rows.$$"
  : > "$rows_file"

  local i=0
  while [ "$i" -lt "$entry_count" ]; do
    local disp
    disp="$(yq ".entries[$i].disposition" "$reg_path" 2>/dev/null)" || disp=""
    if [ "$disp" = "triage" ]; then
      local entry_id ftype sev defect repro gates owner priority
      entry_id="$(yq ".entries[$i].id" "$reg_path" 2>/dev/null)" || entry_id=""
      ftype="$(yq ".entries[$i].type" "$reg_path" 2>/dev/null)" || ftype=""
      sev="$(yq ".entries[$i].severity" "$reg_path" 2>/dev/null)" || sev=""
      defect="$(yq ".entries[$i].defect" "$reg_path" 2>/dev/null)" || defect=""
      repro="$(yq ".entries[$i].reproduction" "$reg_path" 2>/dev/null)" || repro=""
      owner="$(yq ".entries[$i].owner" "$reg_path" 2>/dev/null)" || owner=""
      priority="$(yq ".entries[$i].priority" "$reg_path" 2>/dev/null)" || priority=""

      # Get originating gates as comma-separated.
      gates="$(yq '.entries['"$i"'].originating_gates | join(", ")' "$reg_path" 2>/dev/null)" || gates=""

      # Sanitise cell values.
      defect="$(_rw_sanitise_cell "$defect")"
      repro="$(_rw_sanitise_repro "$repro")"
      gates="$(_rw_sanitise_cell "$gates")"
      owner="$(_rw_sanitise_cell "$owner")"
      priority="$(_rw_sanitise_cell "$priority")"
      ftype="$(_rw_sanitise_cell "$ftype")"
      sev="$(_rw_sanitise_cell "$sev")"

      # Build the finding column.
      local finding="${defect} (gates: ${gates})"

      # Build the action column with em dash separator.
      local action=""
      if [ -n "$repro" ] && [ "$repro" != "null" ] && [ "$repro" != "" ]; then
        action="Reproduce: ${repro} \xe2\x80\x94 owner: ${owner}; priority: ${priority}"
      else
        action="\xe2\x80\x94 owner: ${owner}; priority: ${priority}"
      fi
      # Write the em dash as actual UTF-8.
      action="$(printf '%b' "$action")"

      printf '| %s | %s | %s | %s | %s |\n' \
        "$entry_id" "$ftype" "$sev" "$finding" "$action" >> "$rows_file"
    fi
    i=$(( i + 1 ))
  done

  # If no rows, nothing to do.
  if [ ! -s "$rows_file" ]; then
    rm -f "$rows_file"
    return 0
  fi

  # Acquire story-file lock (fd 9).
  acquire_lock "${story_file}.lock" 15 9

  # Process with awk: find ## Findings section, insert rows, replace placeholder.
  local new_rows
  new_rows="$(cat "$rows_file")"
  rm -f "$rows_file"

  export _RW_NEW_ROWS="$new_rows"

  # Use awk to build the new file content.
  local output_file="${story_file}.tmp.$$"

  # Pass the em-dash placeholder pattern via ENVIRON so awk compares UTF-8
  # bytes correctly (no hex escapes inside awk strings).
  export _RW_PLACEHOLDER
  _RW_PLACEHOLDER="$(printf '| \xe2\x80\x94 | \xe2\x80\x94 | \xe2\x80\x94 | \xe2\x80\x94 | \xe2\x80\x94 |')"

  awk '
    BEGIN {
      in_findings = 0
      after_sep = 0
      rows_inserted = 0
      n_rows = split(ENVIRON["_RW_NEW_ROWS"], row_arr, "\n")
      placeholder = ENVIRON["_RW_PLACEHOLDER"]

      # Collect RF-IDs from new rows for idempotency check.
      for (r = 1; r <= n_rows; r++) {
        if (match(row_arr[r], /RF-[0-9]+/)) {
          new_rfids[substr(row_arr[r], RSTART, RLENGTH)] = r
        }
      }
    }
    /^## Findings/ { in_findings = 1 }
    /^## [^F]/ && in_findings { in_findings = 0 }
    {
      if (!in_findings) { print; next }

      # Placeholder row — replace it with new rows.
      if (index($0, placeholder) > 0) {
        for (r = 1; r <= n_rows; r++) {
          if (row_arr[r] != "") print row_arr[r]
        }
        rows_inserted = 1
        next
      }

      # Separator row — print it, then mark insertion point.
      if ($0 ~ /^\|---/) {
        print
        after_sep = 1
        next
      }

      # Existing data rows: check if any new RF-ID is already present.
      for (rfid in new_rfids) {
        if (index($0, rfid) > 0) {
          # Already present — suppress this RF-ID from insertion.
          delete new_rfids[rfid]
        }
      }

      # If we just passed the separator and have not inserted, insert now.
      if (after_sep && !rows_inserted) {
        for (r = 1; r <= n_rows; r++) {
          if (row_arr[r] == "") continue
          # Only emit if the RF-ID has not been suppressed.
          if (match(row_arr[r], /RF-[0-9]+/)) {
            rfid = substr(row_arr[r], RSTART, RLENGTH)
            if (rfid in new_rfids) print row_arr[r]
          } else {
            print row_arr[r]
          }
        }
        rows_inserted = 1
      }
      after_sep = 0

      print
    }
  ' "$story_file" > "$output_file"

  mv "$output_file" "$story_file"

  unset _RW_NEW_ROWS _RW_PLACEHOLDER

  release_lock 9 2>/dev/null || true
}

# Shared sanitisation: pipe chars, triple-dash runs, bracket-prefixed keywords.
_rw_sanitise_table_chars() {
  local val="$1"
  # Replace | with / (breaks pipe-delimited tables).
  val="$(printf '%s' "$val" | tr '|' '/')"
  # Replace runs of 3+ dashes with spaced dashes (breaks table separators).
  val="$(printf '%s' "$val" | sed 's/---/- - -/g')"
  # Strip [ before TRIAGED or DISMISSED (repeat until none remain).
  # Use a case pattern instead of a pipe to avoid SIGPIPE under pipefail.
  while case "$val" in *'[TRIAGED'*|*'[DISMISSED'*) true ;; *) false ;; esac; do
    val="${val//\[TRIAGED/TRIAGED}"
    val="${val//\[DISMISSED/DISMISSED}"
  done
  printf '%s' "$val"
}

# Sanitise a cell value for pipe-delimited table (newlines become spaces).
_rw_sanitise_cell() {
  local val="$1"
  if [ "$val" = "null" ] || [ -z "$val" ]; then printf ''; return 0; fi
  val="$(printf '%s' "$val" | tr '\n' ' ')"
  _rw_sanitise_table_chars "$val"
}

# Sanitise reproduction text (newlines joined with " ; ").
_rw_sanitise_repro() {
  local val="$1"
  if [ "$val" = "null" ] || [ -z "$val" ]; then printf ''; return 0; fi
  # Join newlines with " ; " (POSIX-portable, no GNU sed).
  local _joined=""
  while IFS= read -r _line || [ -n "$_line" ]; do
    if [ -z "$_joined" ]; then _joined="$_line"; else _joined="$_joined ; $_line"; fi
  done <<EOF
$val
EOF
  _rw_sanitise_table_chars "$_joined"
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

_rw_usage() {
  cat <<'EOF'
register-write.sh — sole writer for the shared findings register

Usage:
  register-write.sh add --story <key> --defect <text> --type <type> --severity <sev>
      --gate <gate> [--evidence <text>] [--impact <text>] [--reproduction <text>]
      [--material] [--blocking --blocking-rationale <text>]
      [--requirement-or-risk <text>] [--dedup-key <key>]
  register-write.sh merge --story <key> --source-id <RF-n> --target-id <RF-n>
  register-write.sh resolve-severity --story <key> --id <RF-n>
      --severity <sev> --blocking <true|false> --rationale <text>
  register-write.sh set-disposition --story <key> --id <RF-n>
      --disposition <open|resolved|triage> [--owner <name>] [--priority <p>]
  register-write.sh triage-nonblocking --story <key> --run-id <id>
  register-write.sh findings-rows --story <key> --run-id <id>
  register-write.sh record-run --story <key> --run-id <id> --gate <gate>
      --outcome <completed|errored>
  register-write.sh gate-status --story <key> --run-id <id> --gate <gate>
  register-write.sh --help

Exit codes: 0 success, 1 caller error, 2 malformed register.
EOF
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------

_rw_require_tool yq
_rw_require_tool jq

case "${1:-}" in
  add) shift; _rw_cmd_add "$@" ;;
  merge) shift; _rw_cmd_merge "$@" ;;
  resolve-severity) shift; _rw_cmd_resolve_severity "$@" ;;
  set-disposition) shift; _rw_cmd_set_disposition "$@" ;;
  triage-nonblocking) shift; _rw_cmd_triage_nonblocking "$@" ;;
  findings-rows) shift; _rw_cmd_findings_rows "$@" ;;
  record-run) shift; _rw_cmd_record_run "$@" ;;
  gate-status) shift; _rw_cmd_gate_status "$@" ;;
  -h|--help) _rw_usage; exit 0 ;;
  "") _rw_die 1 "missing subcommand; use --help" ;;
  *) _rw_die 1 "unknown subcommand: $1" ;;
esac
