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
#   record-run     Record a gate-run entry (with monotonic seq)
#   gate-status    Query gate status for a run (stdout: RAN / UNVERIFIED)
#   record-round   Record a new review round with gates, commit SHA and req version
#   record-round-report  Record a gate's report path and hash for a round
#   round-info     Read-only: print round status, SHA, versions, per-gate evidence
#   complete-round Complete a round after all gates pass
#   assert-round-complete  Guard: exit 0 if latest round complete or legacy
#   impact-assessment  Record changed files between two rounds
#   record-scope-revision  Record a scope change decision on an open round
#   bind-brief     Bind a correction brief to a round by path and hash
#   supersede-brief  Replace a bound brief with a rationale
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

  # Validate rounds[] when present.
  local rounds_type
  rounds_type="$(yq '.rounds | type' "$path" 2>/dev/null)" || rounds_type=""
  case "$rounds_type" in
    "!!null"|"") ;; # Missing or null — legacy, no rounds.
    "!!seq")
      # Each round must be a map with run_id and selected_gates sequence.
      local rounds_valid
      rounds_valid="$(yq '
        ([.rounds[] | select(
          ((. | type) != "!!map")
          or (.run_id == null)
          or ((.selected_gates | type) != "!!seq")
          or (.status != "open" and .status != "complete" and .status != "superseded")
        )] | length == 0)
        and ([.rounds[] | select(
          (.carried_gates != null) and ((.carried_gates | type) != "!!seq")
        )] | length == 0)
      ' "$path" 2>/dev/null)" || rounds_valid="__err"
      case "$rounds_valid" in
        true) ;;
        *)
          _rw_err "structural validation failed (rounds): $path"
          exit 2 ;;
      esac
      ;;
    *)
      _rw_err "structural validation failed (rounds is not a sequence): $path"
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
_RW_CLEANUP_EXTRA=""
_rw_cleanup() {
  if [ -n "$_RW_CLEANUP_TMP" ] && [ -f "$_RW_CLEANUP_TMP" ]; then
    rm -f "$_RW_CLEANUP_TMP"
  fi
  # Clean up extra temp files (space-separated list).
  if [ -n "$_RW_CLEANUP_EXTRA" ]; then
    local _f
    for _f in $_RW_CLEANUP_EXTRA; do
      rm -f "$_f" 2>/dev/null || true
    done
  fi
  if [ -n "$_RW_CLEANUP_FD" ]; then
    release_lock "$_RW_CLEANUP_FD" 2>/dev/null || true
  fi
}
trap _rw_cleanup EXIT

# Create a temp file with a descriptive tag.  Registered in _RW_CLEANUP_EXTRA.
_rw_mktemp() {
  local tag="${1:-rw}"
  local f
  f="$(mktemp "${TMPDIR:-/tmp}/rw-${tag}.XXXXXX")" || _rw_die 1 "mktemp failed"
  _RW_CLEANUP_EXTRA="${_RW_CLEANUP_EXTRA:+$_RW_CLEANUP_EXTRA }$f"
  printf '%s' "$f"
}

# SHA-256 helper — portable across macOS (shasum) and Linux (sha256sum).
# Reads stdin, prints the 64-hex digest.
_rw_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    _rw_die 1 "neither shasum nor sha256sum found"
  fi
}

# Compute the SHA-256 of a file, print just the hex.
_rw_file_sha256() {
  _rw_sha256 < "$1"
}

# Validate a round run-id against the canonical pattern.
_rw_validate_round_id() {
  local id="$1"
  local _rw_round_id_re='^round-[0-9]{8}T[0-9]{6}Z-[0-9]+$'
  if ! grep -qE "$_rw_round_id_re" <<<"$id"; then
    _rw_die 1 "invalid round run-id: $id"
  fi
}

# Resolve the HEAD commit SHA from a --repo path.
# Prints the 40- or 64-hex SHA; exits 1 on failure.
_rw_resolve_code_tree() {
  local repo="$1"
  local inside
  inside="$(git -C "$repo" rev-parse --is-inside-work-tree 2>/dev/null)" || _rw_die 1 "not inside a git work tree: $repo"
  [ "$inside" = "true" ] || _rw_die 1 "not inside a git work tree: $repo"
  local sha
  sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || _rw_die 1 "failed to resolve HEAD in: $repo"
  local _rw_sha_re='^([0-9a-f]{40}|[0-9a-f]{64})$'
  if ! grep -qE "$_rw_sha_re" <<<"$sha"; then
    _rw_die 1 "HEAD is not a valid hex SHA: $sha"
  fi
  printf '%s' "$sha"
}

# Fence-aware requirement-version helper.
# Extracts the Acceptance Criteria block, normalises it, and prints sha256:<hex>.
_rw_compute_requirement_version() {
  local story_file="$1"
  [ -f "$story_file" ] || _rw_die 1 "story file not found: $story_file"

  local normalised
  normalised="$(awk '
    BEGIN { collecting = 0; fence = 0 }
    /^```/ { fence = 1 - fence }
    /^## Acceptance Criteria/ && fence == 0 { collecting = 1; next }
    /^## / && collecting == 1 && fence == 0 { exit }
    collecting == 1 { print }
  ' "$story_file" \
    | tr -d '\r' \
    | sed 's/[[:space:]]*$//' \
    | sed 's/^\([[:space:]]*\)- \[[xX]\]/\1- [ ]/' \
    | awk '{ lines[NR]=$0 } END { e=NR; while(e>0 && lines[e]~/^[[:space:]]*$/) e--; for(i=1;i<=e;i++) print lines[i] }'
  )" || _rw_die 1 "failed to extract AC block from: $story_file"

  [ -n "$normalised" ] || _rw_die 1 "no Acceptance Criteria block found in: $story_file"

  local hash
  hash="$(printf '%s' "$normalised" | _rw_sha256)" || _rw_die 1 "sha256 computation failed"
  printf 'sha256:%s' "$hash"
}

# Resolve the story file path for a given story key.
_rw_resolve_story_file() {
  local key="$1"
  "$SCRIPTS_DIR/resolve-story-file.sh" "$key"
}

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

  # Check whether an existing severity_resolution should be archived.
  # A resolution is stale only when the incoming rating is genuinely new
  # information: the gate had no prior rating, or its severity/blocking
  # changed.  Re-reporting an identical rating from the same gate keeps
  # the resolution intact so settled disagreements survive across rounds.
  local has_sr _archive_sr="false"
  has_sr="$(yq ".entries[$idx] | has(\"severity_resolution\")" "$tmp" 2>/dev/null)" || has_sr="false"
  if [ "$has_sr" = "true" ]; then
    # Look at all gate_ratings EXCEPT the one just appended (the last).
    export _RW_CHK_GATE="$gate"
    local _prev_count
    _prev_count="$(yq "[.entries[$idx].gate_ratings[0:-1] | .[] | select(.gate == strenv(_RW_CHK_GATE))] | length" "$tmp" 2>/dev/null)" || _prev_count="0"
    if [ "$_prev_count" = "0" ]; then
      # Gate had no prior rating — new information.
      _archive_sr="true"
    else
      # Gate already rated; check if the latest prior rating differs.
      local _prev_sev _prev_blk
      _prev_sev="$(yq "[.entries[$idx].gate_ratings[0:-1] | .[] | select(.gate == strenv(_RW_CHK_GATE))][-1].severity" "$tmp" 2>/dev/null)" || _prev_sev=""
      _prev_blk="$(yq "[.entries[$idx].gate_ratings[0:-1] | .[] | select(.gate == strenv(_RW_CHK_GATE))][-1].blocking" "$tmp" 2>/dev/null)" || _prev_blk=""
      if [ "$_prev_sev" != "$severity" ] || [ "$_prev_blk" != "$blocking_bool" ]; then
        _archive_sr="true"
      fi
    fi
    unset _RW_CHK_GATE
  fi

  if [ "$_archive_sr" = "true" ]; then
    export _RW_HIST_TIMESTAMP="$_RW_TIMESTAMP"
    export _RW_HIST_GATE="$gate"
    yq -i ".entries[$idx].history += [{
      \"at\": strenv(_RW_HIST_TIMESTAMP),
      \"gate\": strenv(_RW_HIST_GATE),
      \"action\": \"severity_resolution_archived\",
      \"note\": \"severity_resolution moved to history on new rating\"
    }]" "$tmp"
    yq -i ".entries[$idx].history[-1].archived_resolution = .entries[$idx].severity_resolution" "$tmp"
    yq -i "del(.entries[$idx].severity_resolution)" "$tmp"
    unset _RW_HIST_TIMESTAMP _RW_HIST_GATE
  fi

  # Recompute blocking from gate_ratings.  When a severity_resolution is
  # still in effect (identical re-report), restore its resolved values
  # afterwards so the resolution is authoritative.
  _rw_recompute_blocking "$tmp" "$idx" "dedup merge from ${gate}"

  if [ "$has_sr" = "true" ] && [ "$_archive_sr" = "false" ]; then
    # Restore the resolved values — the resolution is authoritative.
    local _res_blk
    _res_blk="$(yq ".entries[$idx].severity_resolution.resolved_blocking" "$tmp" 2>/dev/null)" || _res_blk="false"
    _rw_force_bool "$tmp" ".entries[$idx].blocking" "$_res_blk"
    local _res_sev
    _res_sev="$(yq ".entries[$idx].severity_resolution.resolved_severity" "$tmp" 2>/dev/null)" || _res_sev=""
    if [ -n "$_res_sev" ] && [ "$_res_sev" != "null" ]; then
      export _RW_RES_SEV="$_res_sev"
      yq -i ".entries[$idx].severity = strenv(_RW_RES_SEV)" "$tmp"
      unset _RW_RES_SEV
    fi
  fi

  # If the existing entry is resolved, reopen it.
  local cur_disp
  cur_disp="$(yq ".entries[$idx].disposition" "$tmp" 2>/dev/null)" || cur_disp=""
  if [ "$cur_disp" = "resolved" ]; then
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

  # Self-merge is a no-op bug; reject it.
  if [ "$source_id" = "$target_id" ]; then
    _rw_die 1 "merge: source and target must differ (both are $source_id)"
  fi

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

  # When the source was unresolved and the target is resolved, reopen the
  # target so the blocker survives consolidation.  Also archive any stale
  # severity_resolution so the verdict-resolver uses the new gate_ratings.
  local src_disp tgt_disp
  src_disp="$(yq ".entries[$src_idx].disposition" "$tmp" 2>/dev/null)" || src_disp=""
  tgt_disp="$(yq ".entries[$tgt_idx].disposition" "$tmp" 2>/dev/null)" || tgt_disp=""
  if [ "$tgt_disp" = "resolved" ] && [ "$src_disp" != "resolved" ]; then
    yq -i ".entries[$tgt_idx].disposition = \"open\"" "$tmp"
  fi

  # Archive severity_resolution when present, so the verdict-resolver uses the
  # current gate_ratings rather than a stale resolution.  This covers three
  # cases: (a) resolved target reopened above, (b) open target with a prior
  # resolve-severity call, (c) triage target receiving a blocking merge.
  local tgt_has_sr
  tgt_has_sr="$(yq ".entries[$tgt_idx] | has(\"severity_resolution\")" "$tmp" 2>/dev/null)" || tgt_has_sr="false"
  if [ "$tgt_has_sr" = "true" ]; then
    local _merge_ts
    _merge_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    export _RW_MERGE_TS="$_merge_ts"
    yq -i ".entries[$tgt_idx].history += [{
      \"at\": strenv(_RW_MERGE_TS),
      \"gate\": \"merge\",
      \"action\": \"severity_resolution_archived\",
      \"note\": \"severity_resolution archived on merge — merged ratings take precedence\"
    }]" "$tmp"
    yq -i ".entries[$tgt_idx].history[-1].archived_resolution = .entries[$tgt_idx].severity_resolution" "$tmp"
    yq -i "del(.entries[$tgt_idx].severity_resolution)" "$tmp"
    unset _RW_MERGE_TS
  fi

  # When a blocking source is merged into a triage target, reopen it so the
  # finding is not silently triaged away.
  tgt_disp="$(yq ".entries[$tgt_idx].disposition" "$tmp" 2>/dev/null)" || tgt_disp=""
  local tgt_blocking
  tgt_blocking="$(yq ".entries[$tgt_idx].blocking" "$tmp" 2>/dev/null)" || tgt_blocking="false"
  if [ "$tgt_disp" = "triage" ] && [ "$tgt_blocking" = "true" ]; then
    yq -i ".entries[$tgt_idx].disposition = \"open\"" "$tmp"
  fi

  # Recompute blocking with the final merged state.
  _rw_recompute_blocking "$tmp" "$tgt_idx" "merge post-resolution of ${target_id}"

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

  # Normalise and validate --blocking: only true/false accepted.
  local blocking_lower
  blocking_lower="$(printf '%s' "$blocking" | tr '[:upper:]' '[:lower:]')"
  case "$blocking_lower" in
    true|false) blocking="$blocking_lower" ;;
    *) _rw_die 1 "resolve-severity: --blocking must be true or false (got: $blocking)" ;;
  esac

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

  # Single yq pass: triage all eligible entries at once. An entry is eligible
  # when disposition == open, blocking == false, and there is no unresolved
  # disagreement (mixed blocking ratings without a severity_resolution).
  yq -i '
    .entries[] |= (
      select(
        .disposition == "open"
        and .blocking != true
        and (
          (([.gate_ratings[] | select(.blocking == true)] | length > 0)
           and ([.gate_ratings[] | select(.blocking == false)] | length > 0)
           and (has("severity_resolution") | not)
          ) | not
        )
      ) |= (
        .disposition = "triage"
        | .owner = .originating_gates[0]
        | .priority = .severity
      )
    )
  ' "$tmp" 2>/dev/null || {
    _rw_err "triage-nonblocking: yq batch update failed"
    _rw_atomic_abort "$tmp"
    _RW_CLEANUP_TMP=""
    release_lock 8
    _RW_CLEANUP_FD=""
    exit 1
  }

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

  # Compute monotonically increasing seq.
  local max_seq
  max_seq="$(yq '[.gate_runs[].seq // 0] | max // 0' "$tmp" 2>/dev/null)" || _rw_die 1 "record-run: failed to compute max seq"
  local next_seq=$(( max_seq + 1 ))

  export _RW_RUN_ID="$run_id"
  export _RW_GATE="$gate"
  export _RW_OUTCOME="$outcome"
  export _RW_TIMESTAMP
  _RW_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  export _RW_SEQ="$next_seq"

  yq -i '.gate_runs += [{
    "run_id": strenv(_RW_RUN_ID),
    "gate": strenv(_RW_GATE),
    "at": strenv(_RW_TIMESTAMP),
    "outcome": strenv(_RW_OUTCOME),
    "seq": env(_RW_SEQ)
  }]' "$tmp" || _rw_die 1 "record-run: yq write failed"

  unset _RW_RUN_ID _RW_GATE _RW_OUTCOME _RW_TIMESTAMP _RW_SEQ

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
  _rw_validate_gate "$gate"

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

  # Extract triage entries in a single yq pass (tab-separated fields, one
  # entry per line).  This keeps the yq spawn count constant regardless of
  # the number of entries.
  local rows_file="$reg_path.rows.$$"
  : > "$rows_file"

  # Single yq→jq pipeline: extract triage entries and format as table rows
  # in one pass.  The jq filter handles sanitisation (pipes, dashes, bracket
  # keywords, newlines) so no per-entry subprocess loop is needed.
  local emdash
  emdash="$(printf '\xe2\x80\x94')"

  if yq -o=json '[.entries[] | select(.disposition == "triage") | {
    "id": .id,
    "type": .type,
    "severity": .severity,
    "defect": .defect,
    "reproduction": (.reproduction // ""),
    "gates": (.originating_gates | join(", ")),
    "owner": (.owner // ""),
    "priority": (.priority // "")
  }]' "$reg_path" 2>/dev/null \
  | jq -r --arg emdash "$emdash" '
    def strip_brackets: until(test("\\[TRIAGED|\\[DISMISSED") | not; gsub("\\[TRIAGED"; "TRIAGED") | gsub("\\[DISMISSED"; "DISMISSED"));
    def sanitise_cell: gsub("\n"; " ") | gsub("\\|"; "/") | gsub("---[-]*"; " - - - ") | strip_brackets;
    def sanitise_repro: gsub("\n"; " ; ") | gsub("\\|"; "/") | gsub("---[-]*"; " - - - ") | strip_brackets;
    .[] |
      "| " + .id + " | " + (.type | sanitise_cell) + " | " + (.severity | sanitise_cell) +
      " | " + ((.defect | sanitise_cell) + " (gates: " + (.gates | sanitise_cell) + ")") +
      " | " + (if (.reproduction // "") != "" then
        "Reproduce: " + (.reproduction | sanitise_repro) + " " + $emdash + " owner: " + ((.owner // "") | sanitise_cell) + "; priority: " + ((.priority // "") | sanitise_cell)
      else
        $emdash + " owner: " + ((.owner // "") | sanitise_cell) + "; priority: " + ((.priority // "") | sanitise_cell)
      end) + " |"
  ' > "$rows_file" 2>"${rows_file}.err"; then
    : # pipeline succeeded
  else
    local _diag=""
    [ -s "${rows_file}.err" ] && _diag=" ($(head -1 "${rows_file}.err"))"
    rm -f "$rows_file" "${rows_file}.err"
    _rw_die 1 "findings-rows: extraction pipeline failed${_diag}"
  fi
  rm -f "${rows_file}.err"

  # If no rows, nothing to do.
  if [ ! -s "$rows_file" ]; then
    rm -f "$rows_file"
    return 0
  fi

  # Acquire story-file lock (fd 9).
  acquire_lock "${story_file}.lock" 15 9

  # Process with awk: find ## Findings section, insert rows, replace placeholder.
  # The rows are read from the temp file rather than an environment variable:
  # Linux caps a single environment string at 128 KB, so a large finding would
  # otherwise make awk fail to start.

  # Use awk to build the new file content.
  local output_file="${story_file}.tmp.$$"

  # Pass the em-dash placeholder pattern via ENVIRON so awk compares UTF-8
  # bytes correctly (no hex escapes inside awk strings).
  export _RW_PLACEHOLDER
  _RW_PLACEHOLDER="$(printf '| \xe2\x80\x94 | \xe2\x80\x94 | \xe2\x80\x94 | \xe2\x80\x94 | \xe2\x80\x94 |')"

  # Two-pass awk: first pass collects all lines and scans existing RF-IDs in
  # the Findings section.  Second pass (END block) outputs lines, inserting
  # only truly new rows after the separator.  This prevents re-insertion of
  # rows that appear later in the section.
  awk -v rowsfile="$rows_file" '
    BEGIN {
      n_rows = 0
      while ((getline row_line < rowsfile) > 0) row_arr[++n_rows] = row_line
      close(rowsfile)
      placeholder = ENVIRON["_RW_PLACEHOLDER"]

      # Collect RF-IDs from new rows.
      for (r = 1; r <= n_rows; r++) {
        if (match(row_arr[r], /RF-[0-9]+/)) {
          new_rfids[substr(row_arr[r], RSTART, RLENGTH)] = r
        }
      }
    }
    {
      lines[NR] = $0
      total = NR

      # Track Findings section boundaries.
      if ($0 ~ /^## Findings/) { findings_start = NR; in_f = 1 }
      if (in_f && NR > findings_start && $0 ~ /^## [^F]/) { findings_end = NR; in_f = 0 }

      if (in_f) {
        if (index($0, placeholder) > 0) placeholder_line = NR
        if ($0 ~ /^\|---/) { if (sep_line == 0) sep_line = NR }
        # Scan existing data rows for RF-IDs already present.
        for (rfid in new_rfids) {
          if (index($0, "| " rfid " |") > 0) delete new_rfids[rfid]
        }
      }
    }
    END {
      for (i = 1; i <= total; i++) {
        # Placeholder row: replace with all new rows.
        if (i == placeholder_line) {
          for (r = 1; r <= n_rows; r++) {
            if (row_arr[r] != "") print row_arr[r]
          }
          continue
        }
        print lines[i]
        # Insert non-duplicate rows right after the separator.
        if (i == sep_line && placeholder_line == 0) {
          for (r = 1; r <= n_rows; r++) {
            if (row_arr[r] == "") continue
            if (match(row_arr[r], /RF-[0-9]+/)) {
              rfid = substr(row_arr[r], RSTART, RLENGTH)
              if (rfid in new_rfids) print row_arr[r]
            } else {
              print row_arr[r]
            }
          }
        }
      }
    }
  ' "$story_file" > "$output_file" || {
    rm -f "$output_file" "$rows_file"
    unset _RW_PLACEHOLDER
    release_lock 9 2>/dev/null || true
    _rw_die 1 "findings-rows: failed to rewrite the story file"
  }
  rm -f "$rows_file"

  mv "$output_file" "$story_file"

  unset _RW_PLACEHOLDER

  release_lock 9 2>/dev/null || true
}

# Sanitisation of table cells (pipe, triple-dash, bracket-prefixed markers) is
# handled by the jq pipeline inside _rw_cmd_findings_rows.  The canonical
# sanitiser is the jq strip_brackets / sanitise_cell / sanitise_repro defs.
# No bash-side helpers are needed — production writes go through jq only.

# ---------------------------------------------------------------------------
# Subcommand: record-round
# ---------------------------------------------------------------------------

_rw_cmd_record_round() {
  local key="" run_id="" repo=""
  local gate_args="" carry_args=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --story) [ "$#" -ge 2 ] || _rw_die 1 "--story requires a value"; key="$2"; shift 2 ;;
      --run-id) [ "$#" -ge 2 ] || _rw_die 1 "--run-id requires a value"; run_id="$2"; shift 2 ;;
      --repo) [ "$#" -ge 2 ] || _rw_die 1 "--repo requires a value"; repo="$2"; shift 2 ;;
      --gate) [ "$#" -ge 2 ] || _rw_die 1 "--gate requires a value"
        gate_args="${gate_args:+$gate_args
}$2"; shift 2 ;;
      --carry) [ "$#" -ge 2 ] || _rw_die 1 "--carry requires a value"
        carry_args="${carry_args:+$carry_args
}$2"; shift 2 ;;
      *) _rw_die 1 "record-round: unknown argument: $1" ;;
    esac
  done

  [ -n "$key" ] || _rw_die 1 "record-round: --story is required"
  [ -n "$run_id" ] || _rw_die 1 "record-round: --run-id is required"
  [ -n "$repo" ] || _rw_die 1 "record-round: --repo is required"
  [ -n "$gate_args" ] || _rw_die 1 "a round must select at least one gate"

  _rw_validate_key "$key"
  _rw_validate_round_id "$run_id"

  # Resolve HEAD from --repo.
  local commit_sha
  commit_sha="$(_rw_resolve_code_tree "$repo")"

  # Resolve story file and compute requirement version.
  local story_file
  story_file="$(_rw_resolve_story_file "$key")" || _rw_die 1 "record-round: could not resolve story file for: $key"
  local req_ver
  req_ver="$(_rw_compute_requirement_version "$story_file")"

  # Parse gate args: split on first '='.
  local selected_json="[]"
  while IFS= read -r garg; do
    [ -n "$garg" ] || continue
    local gname="${garg%%=*}"
    local greason="${garg#*=}"
    _rw_validate_gate "$gname"
    export _RW_GNAME="$gname" _RW_GREASON="$greason"
    selected_json="$(printf '%s' "$selected_json" | jq --arg g "$gname" --arg r "$greason" '. + [{"gate": $g, "reason": $r, "report_path": "", "report_sha256": ""}]')" || _rw_die 1 "record-round: jq failed building selected gates"
    unset _RW_GNAME _RW_GREASON
  done <<< "$gate_args"

  # Parse carry args: split on first '=' then first ':'.
  local carried_json="[]"
  while IFS= read -r carg; do
    [ -n "$carg" ] || continue
    local cname="${carg%%=*}"
    local crest="${carg#*=}"
    local crun="${crest%%:*}"
    local crat="${crest#*:}"
    _rw_validate_gate "$cname"
    _rw_validate_round_id "$crun"
    [ -n "$crat" ] || _rw_die 1 "carried gate $cname: empty applicability rationale"
    carried_json="$(printf '%s' "$carried_json" | jq --arg g "$cname" --arg r "$crun" --arg a "$crat" '. + [{"gate": $g, "from_run": $r, "applicability_rationale": $a}]')" || _rw_die 1 "record-round: jq failed building carried gates"
  done <<< "$carry_args"

  local reg_path
  reg_path="$(_rw_resolve_path "$key")"

  acquire_lock "${reg_path}.lock" 15 8
  _RW_CLEANUP_FD="8"

  # Create register if missing.
  if [ ! -f "$reg_path" ]; then
    _rw_create_register "$reg_path" "$key"
  else
    _rw_validate_structure "$reg_path"
  fi

  local tmp
  tmp="$(_rw_atomic_start "$reg_path")"
  _RW_CLEANUP_TMP="$tmp"

  # Idempotency: if a round with the same run_id exists, compare fields.
  export _RW_RUN_ID="$run_id"
  local existing
  existing="$(yq '[.rounds[] | select(.run_id == strenv(_RW_RUN_ID))] | length' "$tmp" 2>/dev/null)" || existing="0"
  if [ "$existing" != "0" ] && [ "$existing" != "null" ]; then
    # Compare key fields — gate names and reasons plus requirement_version.
    local ex_sha ex_req ex_gates
    ex_sha="$(yq '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).commit_sha' "$tmp" 2>/dev/null)" || ex_sha=""
    ex_req="$(yq '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).requirement_version' "$tmp" 2>/dev/null)" || ex_req=""
    ex_gates="$(yq '[(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).selected_gates[].gate] | sort | join(",")' "$tmp" 2>/dev/null)" || ex_gates=""
    local new_gates
    new_gates="$(printf '%s' "$selected_json" | jq -r '[.[].gate] | sort | join(",")')" || _rw_die 1 "record-round: jq failed"
    unset _RW_RUN_ID
    if [ "$ex_sha" = "$commit_sha" ] && [ "$ex_req" = "$req_ver" ] && [ "$ex_gates" = "$new_gates" ]; then
      # Identical — no-op.
      _rw_atomic_abort "$tmp"
      _RW_CLEANUP_TMP=""
      release_lock 8; _RW_CLEANUP_FD=""
      exit 0
    else
      _rw_atomic_abort "$tmp"
      _RW_CLEANUP_TMP=""
      release_lock 8; _RW_CLEANUP_FD=""
      _rw_die 1 "conflicting record-round for run-id: $run_id"
    fi
  fi
  unset _RW_RUN_ID

  # Supersede any existing open round.
  export _RW_NEW_RUN_ID="$run_id"
  yq -i '(.rounds[] | select(.status == "open")).status = "superseded" | (.rounds[] | select(.status == "superseded" and .superseded_by == null)).superseded_by = strenv(_RW_NEW_RUN_ID)' "$tmp" 2>/dev/null || true
  unset _RW_NEW_RUN_ID

  # Write selected_gates and carried_gates as JSON temp files, load via load().
  local sel_tmp car_tmp
  sel_tmp="$(_rw_mktemp "sel.json")"
  car_tmp="$(_rw_mktemp "car.json")"
  printf '%s' "$selected_json" > "$sel_tmp"
  printf '%s' "$carried_json" > "$car_tmp"

  export _RW_RUN_ID="$run_id"
  export _RW_COMMIT_SHA="$commit_sha"
  export _RW_REQ_VER="$req_ver"
  export _RW_SEL_TMP="$sel_tmp"
  export _RW_CAR_TMP="$car_tmp"

  # Ensure rounds key exists.
  yq -i '.rounds = (.rounds // [])' "$tmp" || _rw_die 1 "record-round: yq failed"

  yq -i '.rounds += [{
    "run_id": strenv(_RW_RUN_ID),
    "commit_sha": strenv(_RW_COMMIT_SHA),
    "requirement_version": strenv(_RW_REQ_VER),
    "accepted_version": strenv(_RW_REQ_VER),
    "status": "open",
    "superseded_by": null,
    "selected_gates": load(strenv(_RW_SEL_TMP)),
    "carried_gates": load(strenv(_RW_CAR_TMP)),
    "impact_assessment": null,
    "scope_revisions": [],
    "brief": null
  }]' "$tmp" || _rw_die 1 "record-round: yq write failed"

  unset _RW_RUN_ID _RW_COMMIT_SHA _RW_REQ_VER _RW_SEL_TMP _RW_CAR_TMP

  _rw_atomic_finish "$tmp" "$reg_path"
  _RW_CLEANUP_TMP=""
  release_lock 8
  _RW_CLEANUP_FD=""
}

# ---------------------------------------------------------------------------
# Subcommand: record-round-report
# ---------------------------------------------------------------------------

_rw_cmd_record_round_report() {
  local key="" run_id="" gate="" report=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --story) [ "$#" -ge 2 ] || _rw_die 1 "--story requires a value"; key="$2"; shift 2 ;;
      --run-id) [ "$#" -ge 2 ] || _rw_die 1 "--run-id requires a value"; run_id="$2"; shift 2 ;;
      --gate) [ "$#" -ge 2 ] || _rw_die 1 "--gate requires a value"; gate="$2"; shift 2 ;;
      --report) [ "$#" -ge 2 ] || _rw_die 1 "--report requires a value"; report="$2"; shift 2 ;;
      *) _rw_die 1 "record-round-report: unknown argument: $1" ;;
    esac
  done

  [ -n "$key" ] || _rw_die 1 "record-round-report: --story is required"
  [ -n "$run_id" ] || _rw_die 1 "record-round-report: --run-id is required"
  [ -n "$gate" ] || _rw_die 1 "record-round-report: --gate is required"
  [ -n "$report" ] || _rw_die 1 "record-round-report: --report is required"

  _rw_validate_key "$key"
  _rw_validate_round_id "$run_id"
  _rw_validate_gate "$gate"
  [ -f "$report" ] || _rw_die 1 "record-round-report: report file not found: $report"

  local report_hash
  report_hash="$(_rw_file_sha256 "$report")" || _rw_die 1 "record-round-report: sha256 failed"

  local reg_path
  reg_path="$(_rw_resolve_path "$key")"

  acquire_lock "${reg_path}.lock" 15 8
  _RW_CLEANUP_FD="8"

  [ -f "$reg_path" ] || _rw_die 1 "record-round-report: no register for: $key"
  _rw_validate_structure "$reg_path"

  local tmp
  tmp="$(_rw_atomic_start "$reg_path")"
  _RW_CLEANUP_TMP="$tmp"

  # Find the round and gate.
  export _RW_RUN_ID="$run_id" _RW_GATE="$gate" _RW_RPATH="$report" _RW_RHASH="$report_hash"
  local found
  found="$(yq '[.rounds[] | select(.run_id == strenv(_RW_RUN_ID)).selected_gates[] | select(.gate == strenv(_RW_GATE))] | length' "$tmp" 2>/dev/null)" || found="0"
  [ "$found" != "0" ] && [ "$found" != "null" ] || {
    unset _RW_RUN_ID _RW_GATE _RW_RPATH _RW_RHASH
    _rw_atomic_abort "$tmp"; _RW_CLEANUP_TMP=""
    release_lock 8; _RW_CLEANUP_FD=""
    _rw_die 1 "record-round-report: gate $gate not found in round $run_id"
  }

  yq -i '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID)).selected_gates[] | select(.gate == strenv(_RW_GATE))).report_path = strenv(_RW_RPATH) | (.rounds[] | select(.run_id == strenv(_RW_RUN_ID)).selected_gates[] | select(.gate == strenv(_RW_GATE))).report_sha256 = strenv(_RW_RHASH)' "$tmp" || _rw_die 1 "record-round-report: yq write failed"

  unset _RW_RUN_ID _RW_GATE _RW_RPATH _RW_RHASH

  _rw_atomic_finish "$tmp" "$reg_path"
  _RW_CLEANUP_TMP=""
  release_lock 8
  _RW_CLEANUP_FD=""
}

# ---------------------------------------------------------------------------
# Subcommand: round-info (read-only)
# ---------------------------------------------------------------------------

# Six canonical register gate names.
_RW_CANONICAL_GATES="code-review qa-tests security-review test-automate test-review performance-review"

_rw_cmd_round_info() {
  local key="" run_id=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --story) [ "$#" -ge 2 ] || _rw_die 1 "--story requires a value"; key="$2"; shift 2 ;;
      --run-id) [ "$#" -ge 2 ] || _rw_die 1 "--run-id requires a value"; run_id="$2"; shift 2 ;;
      *) _rw_die 1 "round-info: unknown argument: $1" ;;
    esac
  done

  [ -n "$key" ] || _rw_die 1 "round-info: --story is required"
  if [ -n "$run_id" ]; then
    _rw_validate_round_id "$run_id"
  fi

  _rw_validate_key "$key"

  local reg_path
  reg_path="$(_rw_resolve_path "$key")"

  # No register — print six none lines, exit 1.
  if [ ! -f "$reg_path" ]; then
    local _g
    for _g in $_RW_CANONICAL_GATES; do
      printf 'last_completed_run %s none\n' "$_g"
    done
    exit 1
  fi

  _rw_validate_structure "$reg_path"

  # Check if rounds exist.
  local rounds_len
  rounds_len="$(yq '.rounds | length // 0' "$reg_path" 2>/dev/null)" || rounds_len="0"
  if [ "$rounds_len" = "0" ] || [ "$rounds_len" = "null" ]; then
    local _g
    for _g in $_RW_CANONICAL_GATES; do
      printf 'last_completed_run %s none\n' "$_g"
    done
    exit 1
  fi

  # Find the target round.
  local target_round_json
  if [ -n "$run_id" ]; then
    export _RW_RUN_ID="$run_id"
    target_round_json="$(yq -o=json '.rounds[] | select(.run_id == strenv(_RW_RUN_ID))' "$reg_path" 2>/dev/null)" || _rw_die 1 "round-info: round not found for run-id: $run_id"
    unset _RW_RUN_ID
  else
    target_round_json="$(yq -o=json '.rounds[-1]' "$reg_path" 2>/dev/null)" || _rw_die 1 "round-info: failed to read latest round"
  fi
  [ -n "$target_round_json" ] && [ "$target_round_json" != "null" ] || _rw_die 1 "round-info: round not found"

  # Print round fields.
  local r_run_id r_status r_sha r_accepted
  r_run_id="$(printf '%s' "$target_round_json" | jq -r '.run_id')" || _rw_die 1 "round-info: jq failed"
  r_status="$(printf '%s' "$target_round_json" | jq -r '.status')" || _rw_die 1 "round-info: jq failed"
  r_sha="$(printf '%s' "$target_round_json" | jq -r '.commit_sha')" || _rw_die 1 "round-info: jq failed"
  r_accepted="$(printf '%s' "$target_round_json" | jq -r '.accepted_version')" || _rw_die 1 "round-info: jq failed"

  # Compute current version from story file.
  local story_file
  story_file="$(_rw_resolve_story_file "$key")" || _rw_die 1 "round-info: could not resolve story file for: $key"
  local current_ver
  current_ver="$(_rw_compute_requirement_version "$story_file")"

  printf 'run_id %s\n' "$r_run_id"
  printf 'status %s\n' "$r_status"
  printf 'commit_sha %s\n' "$r_sha"
  printf 'accepted_version %s\n' "$r_accepted"
  printf 'current_version %s\n' "$current_ver"

  # Print brief info.
  local brief_path brief_sha
  brief_path="$(printf '%s' "$target_round_json" | jq -r '.brief.path // "none"')" || brief_path="none"
  brief_sha="$(printf '%s' "$target_round_json" | jq -r '.brief.sha256 // "none"')" || brief_sha="none"
  printf 'brief_path %s\n' "$brief_path"
  printf 'brief_sha256 %s\n' "$brief_sha"

  # Compute last_completed_run for each gate.
  local _g _rw_round_id_re='^round-[0-9]{8}T[0-9]{6}Z-[0-9]+$'
  for _g in $_RW_CANONICAL_GATES; do
    # Find the latest completed gate_runs entry ordered by seq.
    export _RW_GATE="$_g"
    local latest_run_id
    latest_run_id="$(yq '[.gate_runs[] | select(.gate == strenv(_RW_GATE) and .outcome == "completed")] | sort_by(.seq // 0) | .[-1].run_id // ""' "$reg_path" 2>/dev/null)" || latest_run_id=""
    unset _RW_GATE

    if [ -z "$latest_run_id" ] || [ "$latest_run_id" = "null" ]; then
      printf 'last_completed_run %s none\n' "$_g"
      continue
    fi

    # Must match the round pattern AND have a recorded report in rounds[].
    if grep -qE "$_rw_round_id_re" <<<"$latest_run_id"; then
      export _RW_CHECK_RID="$latest_run_id" _RW_CHECK_GATE="$_g"
      local has_report
      has_report="$(yq '[.rounds[] | select(.run_id == strenv(_RW_CHECK_RID)).selected_gates[] | select(.gate == strenv(_RW_CHECK_GATE) and .report_path != "")] | length' "$reg_path" 2>/dev/null)" || has_report="0"
      unset _RW_CHECK_RID _RW_CHECK_GATE
      if [ "$has_report" != "0" ] && [ "$has_report" != "null" ]; then
        printf 'last_completed_run %s %s\n' "$_g" "$latest_run_id"
      else
        printf 'last_completed_run %s none\n' "$_g"
      fi
    else
      printf 'last_completed_run %s none\n' "$_g"
    fi
  done

  exit 0
}

# ---------------------------------------------------------------------------
# Subcommand: complete-round
# ---------------------------------------------------------------------------

_rw_cmd_complete_round() {
  local key="" run_id="" repo=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --story) [ "$#" -ge 2 ] || _rw_die 1 "--story requires a value"; key="$2"; shift 2 ;;
      --run-id) [ "$#" -ge 2 ] || _rw_die 1 "--run-id requires a value"; run_id="$2"; shift 2 ;;
      --repo) [ "$#" -ge 2 ] || _rw_die 1 "--repo requires a value"; repo="$2"; shift 2 ;;
      *) _rw_die 1 "complete-round: unknown argument: $1" ;;
    esac
  done

  [ -n "$key" ] || _rw_die 1 "complete-round: --story is required"
  [ -n "$run_id" ] || _rw_die 1 "complete-round: --run-id is required"
  [ -n "$repo" ] || _rw_die 1 "complete-round: --repo is required"

  _rw_validate_key "$key"
  _rw_validate_round_id "$run_id"

  local reg_path
  reg_path="$(_rw_resolve_path "$key")"

  acquire_lock "${reg_path}.lock" 15 8
  _RW_CLEANUP_FD="8"

  [ -f "$reg_path" ] || { release_lock 8; _RW_CLEANUP_FD=""; _rw_die 1 "complete-round: no register for: $key"; }
  _rw_validate_structure "$reg_path"

  local tmp
  tmp="$(_rw_atomic_start "$reg_path")"
  _RW_CLEANUP_TMP="$tmp"

  # Find the round.
  export _RW_RUN_ID="$run_id"
  local round_status
  round_status="$(yq '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).status' "$tmp" 2>/dev/null)" || round_status=""
  [ -n "$round_status" ] && [ "$round_status" != "null" ] || {
    unset _RW_RUN_ID
    _rw_atomic_abort "$tmp"; _RW_CLEANUP_TMP=""
    release_lock 8; _RW_CLEANUP_FD=""
    _rw_die 1 "round not found for run-id: $run_id"
  }

  case "$round_status" in
    superseded)
      unset _RW_RUN_ID
      _rw_atomic_abort "$tmp"; _RW_CLEANUP_TMP=""
      release_lock 8; _RW_CLEANUP_FD=""
      _rw_die 1 "cannot complete a superseded round: $run_id"
      ;;
    complete)
      unset _RW_RUN_ID
      _rw_atomic_abort "$tmp"; _RW_CLEANUP_TMP=""
      release_lock 8; _RW_CLEANUP_FD=""
      exit 0  # Idempotent.
      ;;
  esac

  # HEAD check.
  local current_head
  current_head="$(_rw_resolve_code_tree "$repo")"
  local round_sha
  round_sha="$(yq '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).commit_sha' "$tmp" 2>/dev/null)" || _rw_die 1 "complete-round: failed to read round SHA"
  if [ "$current_head" != "$round_sha" ]; then
    unset _RW_RUN_ID
    _rw_atomic_abort "$tmp"; _RW_CLEANUP_TMP=""
    release_lock 8; _RW_CLEANUP_FD=""
    _rw_die 1 "HEAD ($current_head) does not equal round SHA ($round_sha)"
  fi

  # Requirement version check.
  local story_file
  story_file="$(_rw_resolve_story_file "$key")" || _rw_die 1 "complete-round: could not resolve story file"
  local current_ver
  current_ver="$(_rw_compute_requirement_version "$story_file")"
  local accepted_ver
  accepted_ver="$(yq '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).accepted_version' "$tmp" 2>/dev/null)" || _rw_die 1 "complete-round: failed to read accepted_version"
  if [ "$current_ver" != "$accepted_ver" ]; then
    unset _RW_RUN_ID
    _rw_atomic_abort "$tmp"; _RW_CLEANUP_TMP=""
    release_lock 8; _RW_CLEANUP_FD=""
    _rw_die 1 "requirement version mismatch: current=$current_ver accepted=$accepted_ver"
  fi

  # impact_assessment validation.
  local has_impact
  has_impact="$(yq '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).impact_assessment | type' "$tmp" 2>/dev/null)" || has_impact=""
  if [ "$has_impact" = "!!map" ]; then
    local ia_to_sha ia_from_run
    ia_to_sha="$(yq '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).impact_assessment.to_sha' "$tmp" 2>/dev/null)" || ia_to_sha=""
    ia_from_run="$(yq '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).impact_assessment.from_run' "$tmp" 2>/dev/null)" || ia_from_run=""
    if [ "$ia_to_sha" != "$round_sha" ]; then
      unset _RW_RUN_ID
      _rw_atomic_abort "$tmp"; _RW_CLEANUP_TMP=""
      release_lock 8; _RW_CLEANUP_FD=""
      _rw_die 1 "impact_assessment.to_sha ($ia_to_sha) does not match round SHA ($round_sha)"
    fi
    # Verify from_run references a valid round.
    if [ -n "$ia_from_run" ] && [ "$ia_from_run" != "null" ]; then
      export _RW_FROM_RUN="$ia_from_run"
      local from_exists
      from_exists="$(yq '[.rounds[] | select(.run_id == strenv(_RW_FROM_RUN))] | length' "$tmp" 2>/dev/null)" || from_exists="0"
      unset _RW_FROM_RUN
      if [ "$from_exists" = "0" ] || [ "$from_exists" = "null" ]; then
        unset _RW_RUN_ID
        _rw_atomic_abort "$tmp"; _RW_CLEANUP_TMP=""
        release_lock 8; _RW_CLEANUP_FD=""
        _rw_die 1 "impact_assessment.from_run ($ia_from_run) not found in rounds"
      fi
    fi
  fi

  # Check predecessor and six-gate requirement.
  local round_idx
  round_idx="$(yq '[.rounds[].run_id] | to_entries | map(select(.value == strenv(_RW_RUN_ID))) | .[0].key' "$tmp" 2>/dev/null)" || round_idx="0"
  if [ "$round_idx" != "0" ] && [ "$round_idx" != "null" ]; then
    local pred_idx=$(( round_idx - 1 ))
    local pred_sha
    pred_sha="$(yq ".rounds[$pred_idx].commit_sha" "$tmp" 2>/dev/null)" || pred_sha=""
    if [ "$pred_sha" != "$round_sha" ] && [ -n "$pred_sha" ] && [ "$pred_sha" != "null" ]; then
      # Different commit — need impact_assessment and all 6 gates.
      if [ "$has_impact" != "!!map" ]; then
        unset _RW_RUN_ID
        _rw_atomic_abort "$tmp"; _RW_CLEANUP_TMP=""
        release_lock 8; _RW_CLEANUP_FD=""
        _rw_die 1 "impact_assessment required when commit changed from predecessor"
      fi
      # Check all six gates are accounted for.
      local _g errors=""
      for _g in $_RW_CANONICAL_GATES; do
        export _RW_CHECK_GATE="$_g"
        local in_sel in_car
        in_sel="$(yq '[(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).selected_gates[] | select(.gate == strenv(_RW_CHECK_GATE))] | length' "$tmp" 2>/dev/null)" || in_sel="0"
        in_car="$(yq '[(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).carried_gates[] | select(.gate == strenv(_RW_CHECK_GATE))] | length' "$tmp" 2>/dev/null)" || in_car="0"
        unset _RW_CHECK_GATE
        if [ "$in_sel" = "0" ] || [ "$in_sel" = "null" ]; then
          if [ "$in_car" = "0" ] || [ "$in_car" = "null" ]; then
            errors="${errors}gate $_g is neither selected nor carried; "
          fi
        fi
      done
      if [ -n "$errors" ]; then
        unset _RW_RUN_ID
        _rw_atomic_abort "$tmp"; _RW_CLEANUP_TMP=""
        release_lock 8; _RW_CLEANUP_FD=""
        _rw_die 1 "complete-round: $errors"
      fi
    fi
  fi

  # Check each selected gate.
  local sel_count errors=""
  sel_count="$(yq '[(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).selected_gates[]] | length' "$tmp" 2>/dev/null)" || sel_count="0"
  local si=0
  while [ "$si" -lt "$sel_count" ]; do
    local sg
    sg="$(yq "(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).selected_gates[$si].gate" "$tmp" 2>/dev/null)" || sg=""
    local sg_report
    sg_report="$(yq "(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).selected_gates[$si].report_path" "$tmp" 2>/dev/null)" || sg_report=""

    if [ -z "$sg_report" ] || [ "$sg_report" = "null" ] || [ "$sg_report" = '""' ] || [ "$sg_report" = "" ]; then
      errors="${errors}gate $sg: no report recorded; "
      si=$((si + 1))
      continue
    fi
    [ -f "$sg_report" ] || { errors="${errors}gate $sg: report file missing: $sg_report; "; si=$((si + 1)); continue; }

    # Check if the gate was reassessed by a scope revision.
    export _RW_CHECK_GATE="$sg"
    local reassess_seq
    reassess_seq="$(yq '[(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).scope_revisions[] | select(.kind == "essential_missing_requirement" and (.reassessed_gates[] == strenv(_RW_CHECK_GATE)))] | sort_by(.seq) | .[-1].seq // 0' "$tmp" 2>/dev/null)" || reassess_seq="0"

    # Find latest gate_runs entry for this gate+run-id with seq > reassess_seq.
    local latest_outcome
    if [ "$reassess_seq" != "0" ] && [ "$reassess_seq" != "null" ]; then
      export _RW_RSEQ="$reassess_seq"
      latest_outcome="$(yq '[.gate_runs[] | select(.run_id == strenv(_RW_RUN_ID) and .gate == strenv(_RW_CHECK_GATE) and (.seq // 0) > env(_RW_RSEQ))] | sort_by(.seq // 0) | .[-1].outcome // ""' "$tmp" 2>/dev/null)" || latest_outcome=""
      unset _RW_RSEQ
    else
      latest_outcome="$(yq '[.gate_runs[] | select(.run_id == strenv(_RW_RUN_ID) and .gate == strenv(_RW_CHECK_GATE))] | sort_by(.seq // 0) | .[-1].outcome // ""' "$tmp" 2>/dev/null)" || latest_outcome=""
    fi
    unset _RW_CHECK_GATE

    if [ "$latest_outcome" != "completed" ]; then
      errors="${errors}gate $sg: not completed (outcome: ${latest_outcome:-none}); "
    fi
    si=$((si + 1))
  done

  # Check each carried gate.
  local car_count
  car_count="$(yq '[(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).carried_gates[]] | length' "$tmp" 2>/dev/null)" || car_count="0"
  local ci=0
  while [ "$ci" -lt "$car_count" ]; do
    local cg cg_from cg_rat
    cg="$(yq "(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).carried_gates[$ci].gate" "$tmp" 2>/dev/null)" || cg=""
    cg_from="$(yq "(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).carried_gates[$ci].from_run" "$tmp" 2>/dev/null)" || cg_from=""
    cg_rat="$(yq "(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).carried_gates[$ci].applicability_rationale" "$tmp" 2>/dev/null)" || cg_rat=""

    if [ -z "$cg_rat" ] || [ "$cg_rat" = "null" ] || [ "$cg_rat" = '""' ]; then
      errors="${errors}carried gate $cg: empty applicability rationale; "
      ci=$((ci + 1))
      continue
    fi

    # Hop-chain resolution.
    local hop_run="$cg_from" hop_gate="$cg" hops=0 visited=":"
    local terminal_found=false
    while [ "$hops" -lt 10 ]; do
      # Cycle detection.
      case "$visited" in
        *":$hop_run:"*) errors="${errors}carried gate $cg: cycle detected in carry chain; "; break ;;
      esac
      visited="${visited}${hop_run}:"
      hops=$((hops + 1))

      # Find this round in rounds[].
      export _RW_HOP_RUN="$hop_run" _RW_HOP_GATE="$hop_gate"
      local hop_exists
      hop_exists="$(yq '[.rounds[] | select(.run_id == strenv(_RW_HOP_RUN))] | length' "$tmp" 2>/dev/null)" || hop_exists="0"
      if [ "$hop_exists" = "0" ] || [ "$hop_exists" = "null" ]; then
        unset _RW_HOP_RUN _RW_HOP_GATE
        errors="${errors}carried gate $cg: from_run $hop_run not found in rounds; "
        break
      fi

      # Is the gate in selected_gates?
      local in_hop_sel
      in_hop_sel="$(yq '[(.rounds[] | select(.run_id == strenv(_RW_HOP_RUN))).selected_gates[] | select(.gate == strenv(_RW_HOP_GATE))] | length' "$tmp" 2>/dev/null)" || in_hop_sel="0"
      if [ "$in_hop_sel" != "0" ] && [ "$in_hop_sel" != "null" ]; then
        # Terminal run — check gate completion.
        local hop_reassess_seq
        hop_reassess_seq="$(yq '[(.rounds[] | select(.run_id == strenv(_RW_HOP_RUN))).scope_revisions[] | select(.kind == "essential_missing_requirement" and (.reassessed_gates[] == strenv(_RW_HOP_GATE)))] | sort_by(.seq) | .[-1].seq // 0' "$tmp" 2>/dev/null)" || hop_reassess_seq="0"
        local hop_outcome
        if [ "$hop_reassess_seq" != "0" ] && [ "$hop_reassess_seq" != "null" ]; then
          export _RW_HRSEQ="$hop_reassess_seq"
          hop_outcome="$(yq '[.gate_runs[] | select(.run_id == strenv(_RW_HOP_RUN) and .gate == strenv(_RW_HOP_GATE) and (.seq // 0) > env(_RW_HRSEQ))] | sort_by(.seq // 0) | .[-1].outcome // ""' "$tmp" 2>/dev/null)" || hop_outcome=""
          unset _RW_HRSEQ
        else
          hop_outcome="$(yq '[.gate_runs[] | select(.run_id == strenv(_RW_HOP_RUN) and .gate == strenv(_RW_HOP_GATE))] | sort_by(.seq // 0) | .[-1].outcome // ""' "$tmp" 2>/dev/null)" || hop_outcome=""
        fi
        if [ "$hop_outcome" != "completed" ]; then
          errors="${errors}carried gate $cg: not completed at terminal run $hop_run; "
        fi
        # Check report exists and matches.
        local hop_rpath hop_rsha
        hop_rpath="$(yq '(.rounds[] | select(.run_id == strenv(_RW_HOP_RUN))).selected_gates[] | select(.gate == strenv(_RW_HOP_GATE)) | .report_path' "$tmp" 2>/dev/null)" || hop_rpath=""
        hop_rsha="$(yq '(.rounds[] | select(.run_id == strenv(_RW_HOP_RUN))).selected_gates[] | select(.gate == strenv(_RW_HOP_GATE)) | .report_sha256' "$tmp" 2>/dev/null)" || hop_rsha=""
        if [ -z "$hop_rpath" ] || [ "$hop_rpath" = "null" ] || [ "$hop_rpath" = '""' ] || ! [ -f "$hop_rpath" ]; then
          errors="${errors}carried gate $cg: report missing at terminal run $hop_run; "
        elif [ -n "$hop_rsha" ] && [ "$hop_rsha" != "null" ] && [ "$hop_rsha" != '""' ]; then
          local current_rsha
          current_rsha="$(_rw_file_sha256 "$hop_rpath")" || current_rsha=""
          if [ "$current_rsha" != "$hop_rsha" ]; then
            errors="${errors}carried gate $cg: report edited after recording (SHA mismatch); "
          fi
        fi
        unset _RW_HOP_RUN _RW_HOP_GATE
        terminal_found=true
        break
      fi

      # Is the gate in carried_gates? Follow the chain.
      local in_hop_car
      in_hop_car="$(yq '[(.rounds[] | select(.run_id == strenv(_RW_HOP_RUN))).carried_gates[] | select(.gate == strenv(_RW_HOP_GATE))] | length' "$tmp" 2>/dev/null)" || in_hop_car="0"
      if [ "$in_hop_car" != "0" ] && [ "$in_hop_car" != "null" ]; then
        local next_hop
        next_hop="$(yq '(.rounds[] | select(.run_id == strenv(_RW_HOP_RUN))).carried_gates[] | select(.gate == strenv(_RW_HOP_GATE)) | .from_run' "$tmp" 2>/dev/null)" || next_hop=""
        unset _RW_HOP_RUN _RW_HOP_GATE
        hop_run="$next_hop"
        continue
      fi

      # Gate not found in this round.
      unset _RW_HOP_RUN _RW_HOP_GATE
      errors="${errors}carried gate $cg: gate not found in round $hop_run; "
      break
    done

    if [ "$hops" -ge 10 ] && [ "$terminal_found" != "true" ]; then
      errors="${errors}carried gate $cg: chain exceeds 10 hops; "
    fi

    ci=$((ci + 1))
  done

  # Brief check.
  local brief_type
  brief_type="$(yq '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).brief | type' "$tmp" 2>/dev/null)" || brief_type=""
  if [ "$brief_type" = "!!map" ]; then
    local bp bs
    bp="$(yq '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).brief.path' "$tmp" 2>/dev/null)" || bp=""
    bs="$(yq '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).brief.sha256' "$tmp" 2>/dev/null)" || bs=""
    if [ -n "$bp" ] && [ "$bp" != "null" ] && [ -f "$bp" ]; then
      local current_bsha
      current_bsha="$(_rw_file_sha256 "$bp")" || current_bsha=""
      if [ "$current_bsha" != "$bs" ]; then
        errors="${errors}silently widened brief; "
      fi
    fi
  fi

  if [ -n "$errors" ]; then
    unset _RW_RUN_ID
    _rw_atomic_abort "$tmp"; _RW_CLEANUP_TMP=""
    release_lock 8; _RW_CLEANUP_FD=""
    _rw_die 1 "complete-round: $errors"
  fi

  # Mark complete.
  yq -i '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).status = "complete"' "$tmp" || _rw_die 1 "complete-round: yq write failed"
  unset _RW_RUN_ID

  _rw_atomic_finish "$tmp" "$reg_path"
  _RW_CLEANUP_TMP=""
  release_lock 8
  _RW_CLEANUP_FD=""
}

# ---------------------------------------------------------------------------
# Subcommand: assert-round-complete
# ---------------------------------------------------------------------------

_rw_cmd_assert_round_complete() {
  local key=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --story) [ "$#" -ge 2 ] || _rw_die 1 "--story requires a value"; key="$2"; shift 2 ;;
      *) _rw_die 1 "assert-round-complete: unknown argument: $1" ;;
    esac
  done

  [ -n "$key" ] || _rw_die 1 "assert-round-complete: --story is required"
  _rw_validate_key "$key"

  local reg_path
  reg_path="$(_rw_resolve_path "$key")"

  # No register — legacy.
  if [ ! -f "$reg_path" ]; then
    printf 'no orchestrated round\n'
    exit 0
  fi

  _rw_validate_structure "$reg_path"

  local rounds_len
  rounds_len="$(yq '.rounds | length // 0' "$reg_path" 2>/dev/null)" || rounds_len="0"
  if [ "$rounds_len" = "0" ] || [ "$rounds_len" = "null" ]; then
    printf 'no orchestrated round\n'
    exit 0
  fi

  # Get latest round.
  local latest_status
  latest_status="$(yq '.rounds[-1].status' "$reg_path" 2>/dev/null)" || latest_status=""

  # Brief integrity check (on any status).
  local brief_type
  brief_type="$(yq '.rounds[-1].brief | type' "$reg_path" 2>/dev/null)" || brief_type=""
  if [ "$brief_type" = "!!map" ]; then
    local bp bs
    bp="$(yq '.rounds[-1].brief.path' "$reg_path" 2>/dev/null)" || bp=""
    bs="$(yq '.rounds[-1].brief.sha256' "$reg_path" 2>/dev/null)" || bs=""
    if [ -n "$bp" ] && [ "$bp" != "null" ] && [ -f "$bp" ]; then
      local current_bsha
      current_bsha="$(_rw_file_sha256 "$bp")" || current_bsha=""
      if [ "$current_bsha" != "$bs" ]; then
        _rw_die 1 "silently widened brief"
      fi
    fi
  fi

  case "$latest_status" in
    complete) exit 0 ;;
    open) _rw_die 1 "latest round is not complete" ;;
    superseded) _rw_die 1 "latest round is superseded" ;;
    *) _rw_die 1 "unexpected round status: $latest_status" ;;
  esac
}

# ---------------------------------------------------------------------------
# Subcommand: impact-assessment
# ---------------------------------------------------------------------------

_rw_cmd_impact_assessment() {
  local key="" run_id="" from_run="" repo=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --story) [ "$#" -ge 2 ] || _rw_die 1 "--story requires a value"; key="$2"; shift 2 ;;
      --run-id) [ "$#" -ge 2 ] || _rw_die 1 "--run-id requires a value"; run_id="$2"; shift 2 ;;
      --from-run) [ "$#" -ge 2 ] || _rw_die 1 "--from-run requires a value"; from_run="$2"; shift 2 ;;
      --repo) [ "$#" -ge 2 ] || _rw_die 1 "--repo requires a value"; repo="$2"; shift 2 ;;
      *) _rw_die 1 "impact-assessment: unknown argument: $1" ;;
    esac
  done

  [ -n "$key" ] || _rw_die 1 "impact-assessment: --story is required"
  [ -n "$run_id" ] || _rw_die 1 "impact-assessment: --run-id is required"
  [ -n "$from_run" ] || _rw_die 1 "impact-assessment: --from-run is required"
  [ -n "$repo" ] || _rw_die 1 "impact-assessment: --repo is required"

  _rw_validate_key "$key"
  _rw_validate_round_id "$run_id"
  _rw_validate_round_id "$from_run"

  local reg_path
  reg_path="$(_rw_resolve_path "$key")"

  acquire_lock "${reg_path}.lock" 15 8
  _RW_CLEANUP_FD="8"

  [ -f "$reg_path" ] || { release_lock 8; _RW_CLEANUP_FD=""; _rw_die 1 "impact-assessment: no register for: $key"; }
  _rw_validate_structure "$reg_path"

  local tmp
  tmp="$(_rw_atomic_start "$reg_path")"
  _RW_CLEANUP_TMP="$tmp"

  # Find current round.
  export _RW_RUN_ID="$run_id"
  local cur_exists
  cur_exists="$(yq '[.rounds[] | select(.run_id == strenv(_RW_RUN_ID))] | length' "$tmp" 2>/dev/null)" || cur_exists="0"
  if [ "$cur_exists" = "0" ] || [ "$cur_exists" = "null" ]; then
    unset _RW_RUN_ID
    _rw_atomic_abort "$tmp"; _RW_CLEANUP_TMP=""
    release_lock 8; _RW_CLEANUP_FD=""
    _rw_die 1 "round not found for run-id: $run_id"
  fi

  local new_sha
  new_sha="$(yq '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).commit_sha' "$tmp" 2>/dev/null)" || _rw_die 1 "impact-assessment: failed to read round SHA"

  # Find previous round.
  export _RW_FROM_RUN="$from_run"
  local from_exists
  from_exists="$(yq '[.rounds[] | select(.run_id == strenv(_RW_FROM_RUN))] | length' "$tmp" 2>/dev/null)" || from_exists="0"
  if [ "$from_exists" = "0" ] || [ "$from_exists" = "null" ]; then
    unset _RW_RUN_ID _RW_FROM_RUN
    _rw_atomic_abort "$tmp"; _RW_CLEANUP_TMP=""
    release_lock 8; _RW_CLEANUP_FD=""
    _rw_die 1 "round not found for from-run: $from_run"
  fi

  local old_sha
  old_sha="$(yq '(.rounds[] | select(.run_id == strenv(_RW_FROM_RUN))).commit_sha' "$tmp" 2>/dev/null)" || _rw_die 1 "impact-assessment: failed to read from-run SHA"

  # Verify current HEAD matches.
  local current_head
  current_head="$(_rw_resolve_code_tree "$repo")"
  if [ "$current_head" != "$new_sha" ]; then
    unset _RW_RUN_ID _RW_FROM_RUN
    _rw_atomic_abort "$tmp"; _RW_CLEANUP_TMP=""
    release_lock 8; _RW_CLEANUP_FD=""
    _rw_die 1 "HEAD does not match round SHA"
  fi

  # Verify old SHA exists in the repo.
  git -C "$repo" cat-file -t "$old_sha" >/dev/null 2>&1 || {
    unset _RW_RUN_ID _RW_FROM_RUN
    _rw_atomic_abort "$tmp"; _RW_CLEANUP_TMP=""
    release_lock 8; _RW_CLEANUP_FD=""
    _rw_die 1 "earlier SHA not found in repo: $old_sha"
  }

  # Compute changed files via NUL-delimited diff + jq.
  local diff_tmp list_json
  diff_tmp="$(_rw_mktemp "diff")"
  list_json="$(_rw_mktemp "list.json")"
  git -C "$repo" diff -z --name-only "$old_sha" "$new_sha" > "$diff_tmp" || _rw_die 1 "impact-assessment: git diff failed"
  # Note: jq -R replaces filenames that are not valid UTF-8 with U+FFFD.
  jq -Rs 'split("\u0000") | map(select(. != ""))' "$diff_tmp" > "$list_json" || _rw_die 1 "impact-assessment: jq failed"

  export _RW_OLD_SHA="$old_sha" _RW_NEW_SHA="$new_sha" _RW_LIST_JSON="$list_json"
  yq -i '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).impact_assessment = {
    "from_run": strenv(_RW_FROM_RUN),
    "from_sha": strenv(_RW_OLD_SHA),
    "to_sha": strenv(_RW_NEW_SHA),
    "changed_files": load(strenv(_RW_LIST_JSON))
  }' "$tmp" || _rw_die 1 "impact-assessment: yq write failed"

  unset _RW_RUN_ID _RW_FROM_RUN _RW_OLD_SHA _RW_NEW_SHA _RW_LIST_JSON

  _rw_atomic_finish "$tmp" "$reg_path"
  _RW_CLEANUP_TMP=""
  release_lock 8
  _RW_CLEANUP_FD=""
}

# ---------------------------------------------------------------------------
# Subcommand: record-scope-revision
# ---------------------------------------------------------------------------

_rw_cmd_record_scope_revision() {
  local key="" run_id="" kind="" decision="" followon=""
  local reassess_args=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --story) [ "$#" -ge 2 ] || _rw_die 1 "--story requires a value"; key="$2"; shift 2 ;;
      --run-id) [ "$#" -ge 2 ] || _rw_die 1 "--run-id requires a value"; run_id="$2"; shift 2 ;;
      --kind) [ "$#" -ge 2 ] || _rw_die 1 "--kind requires a value"; kind="$2"; shift 2 ;;
      --decision) [ "$#" -ge 2 ] || _rw_die 1 "--decision requires a value"; decision="$2"; shift 2 ;;
      --reassess) [ "$#" -ge 2 ] || _rw_die 1 "--reassess requires a value"
        reassess_args="${reassess_args:+$reassess_args
}$2"; shift 2 ;;
      --followon) [ "$#" -ge 2 ] || _rw_die 1 "--followon requires a value"; followon="$2"; shift 2 ;;
      *) _rw_die 1 "record-scope-revision: unknown argument: $1" ;;
    esac
  done

  [ -n "$key" ] || _rw_die 1 "record-scope-revision: --story is required"
  [ -n "$run_id" ] || _rw_die 1 "record-scope-revision: --run-id is required"
  [ -n "$kind" ] || _rw_die 1 "record-scope-revision: --kind is required"
  [ -n "$decision" ] || _rw_die 1 "record-scope-revision: empty --decision"

  _rw_validate_key "$key"
  _rw_validate_round_id "$run_id"

  case "$kind" in
    essential_missing_requirement) ;;
    unrelated_enhancement)
      [ -z "$reassess_args" ] || _rw_die 1 "cannot reassess gates with an unrelated enhancement"
      [ -n "$followon" ] || _rw_die 1 "unrelated_enhancement requires --followon"
      ;;
    *) _rw_die 1 "record-scope-revision: unknown kind: $kind" ;;
  esac

  local reg_path
  reg_path="$(_rw_resolve_path "$key")"

  acquire_lock "${reg_path}.lock" 15 8
  _RW_CLEANUP_FD="8"

  [ -f "$reg_path" ] || { release_lock 8; _RW_CLEANUP_FD=""; _rw_die 1 "record-scope-revision: no register for: $key"; }
  _rw_validate_structure "$reg_path"

  local tmp
  tmp="$(_rw_atomic_start "$reg_path")"
  _RW_CLEANUP_TMP="$tmp"

  # Find the open round.
  export _RW_RUN_ID="$run_id"
  local round_status
  round_status="$(yq '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).status' "$tmp" 2>/dev/null)" || round_status=""
  [ "$round_status" = "open" ] || {
    unset _RW_RUN_ID
    _rw_atomic_abort "$tmp"; _RW_CLEANUP_TMP=""
    release_lock 8; _RW_CLEANUP_FD=""
    _rw_die 1 "record-scope-revision: round $run_id is not open (status: $round_status)"
  }

  # Compute current max seq.
  local max_seq
  max_seq="$(yq '[.gate_runs[].seq // 0] | max // 0' "$tmp" 2>/dev/null)" || max_seq="0"

  # Derive disposition.
  local disposition="" new_version=""
  case "$kind" in
    essential_missing_requirement)
      disposition="accepted"
      local story_file
      story_file="$(_rw_resolve_story_file "$key")" || _rw_die 1 "record-scope-revision: could not resolve story file"
      new_version="$(_rw_compute_requirement_version "$story_file")"
      # Advance accepted_version.
      export _RW_NEW_VER="$new_version"
      yq -i '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).accepted_version = strenv(_RW_NEW_VER)' "$tmp" || _rw_die 1 "record-scope-revision: yq write failed"
      unset _RW_NEW_VER
      ;;
    unrelated_enhancement)
      disposition="filed_as_followon"
      ;;
  esac

  # Validate and process reassessed gates.
  local reassess_json="[]"
  while IFS= read -r rg; do
    [ -n "$rg" ] || continue
    _rw_validate_gate "$rg"
    # Must be in selected or carried.
    export _RW_RG="$rg"
    local in_sel in_car
    in_sel="$(yq '[(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).selected_gates[] | select(.gate == strenv(_RW_RG))] | length' "$tmp" 2>/dev/null)" || in_sel="0"
    in_car="$(yq '[(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).carried_gates[] | select(.gate == strenv(_RW_RG))] | length' "$tmp" 2>/dev/null)" || in_car="0"
    if [ "$in_sel" = "0" ] || [ "$in_sel" = "null" ]; then
      if [ "$in_car" = "0" ] || [ "$in_car" = "null" ]; then
        unset _RW_RG
        _rw_atomic_abort "$tmp"; _RW_CLEANUP_TMP=""
        release_lock 8; _RW_CLEANUP_FD=""
        _rw_die 1 "reassessed gate $rg is neither selected nor carried"
      fi
      # Move from carried to selected.
      local car_json
      car_json="$(yq -o=json '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).carried_gates[] | select(.gate == strenv(_RW_RG))' "$tmp" 2>/dev/null)" || car_json=""
      # Remove from carried_gates.
      yq -i 'del((.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).carried_gates[] | select(.gate == strenv(_RW_RG)))' "$tmp" || _rw_die 1 "record-scope-revision: yq delete failed"
      # Add to selected_gates with reason "reassessed by scope revision".
      export _RW_REASON="reassessed by scope revision"
      yq -i '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).selected_gates += [{"gate": strenv(_RW_RG), "reason": strenv(_RW_REASON), "report_path": "", "report_sha256": ""}]' "$tmp" || _rw_die 1 "record-scope-revision: yq write failed"
      unset _RW_REASON
    fi
    unset _RW_RG
    reassess_json="$(printf '%s' "$reassess_json" | jq --arg g "$rg" '. + [$g]')" || _rw_die 1 "record-scope-revision: jq failed"
  done <<< "$reassess_args"

  # Write scope revision entry.
  local rev_tmp
  rev_tmp="$(_rw_mktemp "rev.json")"
  if [ "$kind" = "essential_missing_requirement" ]; then
    jq -n --arg kind "$kind" --arg dec "$decision" --arg nv "$new_version" --arg disp "$disposition" --argjson seq "$max_seq" --argjson rg "$reassess_json" '{kind: $kind, decision: $dec, new_version: $nv, disposition: $disp, seq: $seq, reassessed_gates: $rg}' > "$rev_tmp" || _rw_die 1 "record-scope-revision: jq failed"
  else
    jq -n --arg kind "$kind" --arg dec "$decision" --arg disp "$disposition" --arg fk "$followon" --argjson seq "$max_seq" --argjson rg "$reassess_json" '{kind: $kind, decision: $dec, disposition: $disp, followon_key: $fk, seq: $seq, reassessed_gates: $rg}' > "$rev_tmp" || _rw_die 1 "record-scope-revision: jq failed"
  fi

  export _RW_REV_TMP="$rev_tmp"
  yq -i '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).scope_revisions += [load(strenv(_RW_REV_TMP))]' "$tmp" || _rw_die 1 "record-scope-revision: yq write failed"
  unset _RW_REV_TMP _RW_RUN_ID

  _rw_atomic_finish "$tmp" "$reg_path"
  _RW_CLEANUP_TMP=""
  release_lock 8
  _RW_CLEANUP_FD=""
}

# ---------------------------------------------------------------------------
# Subcommand: bind-brief
# ---------------------------------------------------------------------------

_rw_cmd_bind_brief() {
  local key="" run_id="" brief=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --story) [ "$#" -ge 2 ] || _rw_die 1 "--story requires a value"; key="$2"; shift 2 ;;
      --run-id) [ "$#" -ge 2 ] || _rw_die 1 "--run-id requires a value"; run_id="$2"; shift 2 ;;
      --brief) [ "$#" -ge 2 ] || _rw_die 1 "--brief requires a value"; brief="$2"; shift 2 ;;
      *) _rw_die 1 "bind-brief: unknown argument: $1" ;;
    esac
  done

  [ -n "$key" ] || _rw_die 1 "bind-brief: --story is required"
  [ -n "$run_id" ] || _rw_die 1 "bind-brief: --run-id is required"
  [ -n "$brief" ] || _rw_die 1 "bind-brief: --brief is required"

  _rw_validate_key "$key"
  _rw_validate_round_id "$run_id"
  [ -f "$brief" ] || _rw_die 1 "bind-brief: brief file not found: $brief"

  local brief_hash
  brief_hash="$(_rw_file_sha256 "$brief")" || _rw_die 1 "bind-brief: sha256 failed"

  local reg_path
  reg_path="$(_rw_resolve_path "$key")"

  acquire_lock "${reg_path}.lock" 15 8
  _RW_CLEANUP_FD="8"

  [ -f "$reg_path" ] || { release_lock 8; _RW_CLEANUP_FD=""; _rw_die 1 "bind-brief: no register for: $key"; }
  _rw_validate_structure "$reg_path"

  local tmp
  tmp="$(_rw_atomic_start "$reg_path")"
  _RW_CLEANUP_TMP="$tmp"

  export _RW_RUN_ID="$run_id"
  local round_status
  round_status="$(yq '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).status' "$tmp" 2>/dev/null)" || round_status=""
  case "$round_status" in
    open|complete) ;;
    superseded)
      unset _RW_RUN_ID
      _rw_atomic_abort "$tmp"; _RW_CLEANUP_TMP=""
      release_lock 8; _RW_CLEANUP_FD=""
      _rw_die 1 "cannot bind brief to a superseded round"
      ;;
    *)
      unset _RW_RUN_ID
      _rw_atomic_abort "$tmp"; _RW_CLEANUP_TMP=""
      release_lock 8; _RW_CLEANUP_FD=""
      _rw_die 1 "bind-brief: round not found for run-id: $run_id"
      ;;
  esac

  # Check existing brief.
  local existing_brief_type
  existing_brief_type="$(yq '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).brief | type' "$tmp" 2>/dev/null)" || existing_brief_type=""
  if [ "$existing_brief_type" = "!!map" ]; then
    local ex_path ex_hash
    ex_path="$(yq '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).brief.path' "$tmp" 2>/dev/null)" || ex_path=""
    ex_hash="$(yq '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).brief.sha256' "$tmp" 2>/dev/null)" || ex_hash=""
    if [ "$ex_path" = "$brief" ] && [ "$ex_hash" = "$brief_hash" ]; then
      # Idempotent re-bind.
      unset _RW_RUN_ID
      _rw_atomic_abort "$tmp"; _RW_CLEANUP_TMP=""
      release_lock 8; _RW_CLEANUP_FD=""
      exit 0
    fi
    unset _RW_RUN_ID
    _rw_atomic_abort "$tmp"; _RW_CLEANUP_TMP=""
    release_lock 8; _RW_CLEANUP_FD=""
    _rw_die 1 "brief already bound; use supersede-brief"
  fi

  # Set brief.
  export _RW_BPATH="$brief" _RW_BHASH="$brief_hash"
  yq -i '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).brief = {"path": strenv(_RW_BPATH), "sha256": strenv(_RW_BHASH), "status": "active", "superseded_by": null, "history": []}' "$tmp" || _rw_die 1 "bind-brief: yq write failed"
  unset _RW_RUN_ID _RW_BPATH _RW_BHASH

  _rw_atomic_finish "$tmp" "$reg_path"
  _RW_CLEANUP_TMP=""
  release_lock 8
  _RW_CLEANUP_FD=""
}

# ---------------------------------------------------------------------------
# Subcommand: supersede-brief
# ---------------------------------------------------------------------------

_rw_cmd_supersede_brief() {
  local key="" run_id="" brief="" rationale=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --story) [ "$#" -ge 2 ] || _rw_die 1 "--story requires a value"; key="$2"; shift 2 ;;
      --run-id) [ "$#" -ge 2 ] || _rw_die 1 "--run-id requires a value"; run_id="$2"; shift 2 ;;
      --brief) [ "$#" -ge 2 ] || _rw_die 1 "--brief requires a value"; brief="$2"; shift 2 ;;
      --rationale) [ "$#" -ge 2 ] || _rw_die 1 "--rationale requires a value"; rationale="$2"; shift 2 ;;
      *) _rw_die 1 "supersede-brief: unknown argument: $1" ;;
    esac
  done

  [ -n "$key" ] || _rw_die 1 "supersede-brief: --story is required"
  [ -n "$run_id" ] || _rw_die 1 "supersede-brief: --run-id is required"
  [ -n "$brief" ] || _rw_die 1 "supersede-brief: --brief is required"
  [ -n "$rationale" ] || _rw_die 1 "supersede-brief: empty --rationale"

  _rw_validate_key "$key"
  _rw_validate_round_id "$run_id"
  [ -f "$brief" ] || _rw_die 1 "supersede-brief: brief file not found: $brief"

  local brief_hash
  brief_hash="$(_rw_file_sha256 "$brief")" || _rw_die 1 "supersede-brief: sha256 failed"

  local reg_path
  reg_path="$(_rw_resolve_path "$key")"

  acquire_lock "${reg_path}.lock" 15 8
  _RW_CLEANUP_FD="8"

  [ -f "$reg_path" ] || { release_lock 8; _RW_CLEANUP_FD=""; _rw_die 1 "supersede-brief: no register for: $key"; }
  _rw_validate_structure "$reg_path"

  local tmp
  tmp="$(_rw_atomic_start "$reg_path")"
  _RW_CLEANUP_TMP="$tmp"

  export _RW_RUN_ID="$run_id"
  local round_status
  round_status="$(yq '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).status' "$tmp" 2>/dev/null)" || round_status=""
  case "$round_status" in
    open|complete) ;;
    superseded)
      unset _RW_RUN_ID
      _rw_atomic_abort "$tmp"; _RW_CLEANUP_TMP=""
      release_lock 8; _RW_CLEANUP_FD=""
      _rw_die 1 "cannot supersede brief on a superseded round"
      ;;
    *)
      unset _RW_RUN_ID
      _rw_atomic_abort "$tmp"; _RW_CLEANUP_TMP=""
      release_lock 8; _RW_CLEANUP_FD=""
      _rw_die 1 "supersede-brief: round not found for run-id: $run_id"
      ;;
  esac

  # Must have an existing brief.
  local existing_brief_type
  existing_brief_type="$(yq '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).brief | type' "$tmp" 2>/dev/null)" || existing_brief_type=""
  [ "$existing_brief_type" = "!!map" ] || {
    unset _RW_RUN_ID
    _rw_atomic_abort "$tmp"; _RW_CLEANUP_TMP=""
    release_lock 8; _RW_CLEANUP_FD=""
    _rw_die 1 "supersede-brief: no brief bound to supersede"
  }

  # Preserve old brief in history.
  local old_path old_hash
  old_path="$(yq '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).brief.path' "$tmp" 2>/dev/null)" || old_path=""
  old_hash="$(yq '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).brief.sha256' "$tmp" 2>/dev/null)" || old_hash=""

  local hist_tmp
  hist_tmp="$(_rw_mktemp "hist.json")"
  jq -n --arg p "$old_path" --arg s "$old_hash" --arg sb "$brief" --arg r "$rationale" '{path: $p, sha256: $s, status: "superseded", superseded_by: $sb, rationale: $r}' > "$hist_tmp" || _rw_die 1 "supersede-brief: jq failed"
  export _RW_HIST_TMP="$hist_tmp"
  yq -i '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).brief.history += [load(strenv(_RW_HIST_TMP))]' "$tmp" || _rw_die 1 "supersede-brief: yq history write failed"
  unset _RW_HIST_TMP

  # Set new brief.
  export _RW_BPATH="$brief" _RW_BHASH="$brief_hash"
  yq -i '(.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).brief.path = strenv(_RW_BPATH) | (.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).brief.sha256 = strenv(_RW_BHASH) | (.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).brief.status = "active" | (.rounds[] | select(.run_id == strenv(_RW_RUN_ID))).brief.superseded_by = null' "$tmp" || _rw_die 1 "supersede-brief: yq write failed"
  unset _RW_RUN_ID _RW_BPATH _RW_BHASH

  _rw_atomic_finish "$tmp" "$reg_path"
  _RW_CLEANUP_TMP=""
  release_lock 8
  _RW_CLEANUP_FD=""
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
  register-write.sh record-round --story <key> --run-id <id> --repo <path>
      --gate <name>=<reason> ... [--carry <name>=<run-id>:<rationale> ...]
  register-write.sh record-round-report --story <key> --run-id <id>
      --gate <name> --report <path>
  register-write.sh round-info --story <key> [--run-id <id>]
  register-write.sh complete-round --story <key> --run-id <id> --repo <path>
  register-write.sh assert-round-complete --story <key>
  register-write.sh impact-assessment --story <key> --run-id <id>
      --from-run <old-run-id> --repo <path>
  register-write.sh record-scope-revision --story <key> --run-id <id>
      --kind <essential_missing_requirement|unrelated_enhancement>
      --decision <text> [--reassess <gate>...] [--followon <key>]
  register-write.sh bind-brief --story <key> --run-id <id> --brief <path>
  register-write.sh supersede-brief --story <key> --run-id <id>
      --brief <new-path> --rationale <text>
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
  record-round) shift; _rw_cmd_record_round "$@" ;;
  record-round-report) shift; _rw_cmd_record_round_report "$@" ;;
  round-info) shift; _rw_cmd_round_info "$@" ;;
  complete-round) shift; _rw_cmd_complete_round "$@" ;;
  assert-round-complete) shift; _rw_cmd_assert_round_complete "$@" ;;
  impact-assessment) shift; _rw_cmd_impact_assessment "$@" ;;
  record-scope-revision) shift; _rw_cmd_record_scope_revision "$@" ;;
  bind-brief) shift; _rw_cmd_bind_brief "$@" ;;
  supersede-brief) shift; _rw_cmd_supersede_brief "$@" ;;
  -h|--help) _rw_usage; exit 0 ;;
  "") _rw_die 1 "missing subcommand; use --help" ;;
  *) _rw_die 1 "unknown subcommand: $1" ;;
esac
