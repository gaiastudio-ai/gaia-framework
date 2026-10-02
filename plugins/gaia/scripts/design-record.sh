#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C; export LC_ALL

# design-record.sh — sole writer for .gaia/state/design-record.yaml.
#
# Five-state design-approval machine (draft/review/approved/in-dev/stale),
# per-stakeholder iteration-keyed convergence, chained-digest append-only
# audit trail, and atomic publication via tempfile-then-mv.
#
# Usage: design-record.sh <verb> [options]
#
# Verbs:
#   init               Create a new design record
#   show               Display the record (human-readable)
#   status             Machine-readable state + convergence
#   transition         State-machine transition
#   approve            Record a stakeholder approval
#   add-review         Record a review verdict
#   add-override       Record an audited override
#   not-applicable     Mark the project as not requiring design approval
#   init-not-applicable  Create a minimal not-applicable record or delegate
#   reopen-applicable  Transition a not-applicable record back to applicable/draft
#   check-convergence  Compute convergence from summary fields
#   verify-integrity   Validate the chained digest
#   set-product-project  Bind a product-design project to an existing record

# ---------------------------------------------------------------------------
# Bootstrap: shared helpers
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/acquire-lock.sh
source "$SCRIPT_DIR/lib/acquire-lock.sh"

_PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-.}}}"
RECORD_PATH="${_PROJECT_ROOT}/.gaia/state/design-record.yaml"
LOCK_PATH="${RECORD_PATH}.lock"

# 30s default: safe for production (only hit under genuine contention);
# high enough for the ln(2) fallback's retry loop under heavy concurrency.
LOCK_TIMEOUT="${GAIA_LOCK_TIMEOUT:-30}"
LOCK_FD=9

# Fail loudly if yq is absent — never skip or degrade
command -v yq >/dev/null 2>&1 || {
  printf 'design-record.sh: yq is required but not found on PATH\n' >&2
  exit 2
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_die() { printf 'design-record.sh: %s\n' "$1" >&2; exit 1; }

_now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

_sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# _parse_opts PAIRS... — shared arg parser for all cmd_* functions.
# Accepts pairs of (flag-name, variable-name) followed by "--" then "$@".
# Sets the named variables in the caller's scope.  Unknown flags die.
#
# Example:  _parse_opts --to to --actor actor -- "$@"
_parse_opts() {
  # Build an associative mapping: flag -> variable name
  local -a _flags=() _vars=()
  while [ "$1" != "--" ]; do
    _flags+=("$1"); _vars+=("$2"); shift 2
  done
  shift  # skip "--"

  while [ $# -gt 0 ]; do
    local _matched=false
    local _i
    for _i in "${!_flags[@]}"; do
      if [ "$1" = "${_flags[$_i]}" ]; then
        printf -v "${_vars[$_i]}" '%s' "$2"
        shift 2; _matched=true; break
      fi
    done
    "$_matched" || _die "unknown option: $1"
  done
}

# _assert_valid_state VALUE CONTEXT — reject non-enum values before any I/O.
_assert_valid_state() {
  local value="$1" context="${2:-}"
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    printf 'design-record.sh: illegal state value "%s" in %s\n' "$value" "$context" >&2
    printf 'design-record.sh: legal values: draft, review, approved, in-dev, stale\n' >&2
    exit 1
  fi
  case "$value" in
    draft|review|approved|in-dev|stale) return 0 ;;
  esac
  printf 'design-record.sh: illegal state value "%s" in %s\n' "$value" "$context" >&2
  printf 'design-record.sh: legal values: draft, review, approved, in-dev, stale\n' >&2
  exit 1
}

# _assert_valid_verdict VALUE — reject non-enum review verdicts before any I/O.
_assert_valid_verdict() {
  local value="$1"
  case "$value" in
    approved|changes-requested|blocked|escalated) return 0 ;;
  esac
  printf 'design-record.sh: illegal verdict "%s" in add-review\n' "$value" >&2
  printf 'design-record.sh: legal verdicts: approved, changes-requested, blocked, escalated\n' >&2
  exit 1
}

# _assert_valid_kind VALUE — reject non-enum review kinds before any I/O.
_assert_valid_kind() {
  local value="$1"
  case "$value" in
    internal|stakeholder|design-review) return 0 ;;
  esac
  printf 'design-record.sh: illegal kind "%s" in add-review\n' "$value" >&2
  printf 'design-record.sh: legal kinds: internal, stakeholder, design-review\n' >&2
  exit 1
}

# _assert_legal_transition FROM TO — reject illegal edges before any I/O.
_assert_legal_transition() {
  local from="$1" to="$2"
  case "${from}:${to}" in
    draft:review) return 0 ;;
    review:review) return 0 ;;   # iteration bump
    review:approved) return 0 ;; # requires convergence (checked in-lock)
    approved:in-dev) return 0 ;;
    *:stale) return 0 ;;         # any -> stale
    stale:review) return 0 ;;
  esac
  printf 'design-record.sh: illegal transition %s -> %s\n' "$from" "$to" >&2
  printf 'design-record.sh: legal edges: draft->review, review->review, review->approved, approved->in-dev, *->stale, stale->review\n' >&2
  exit 1
}

# _validate_schema_version FILE — reject unknown schema versions.
_validate_schema_version() {
  local file="$1"
  local ver
  ver="$(yq '.schema_version' "$file" 2>/dev/null)" || \
    _die "cannot read schema_version from $file"
  case "$ver" in
    1.0|2.0) return 0 ;;
  esac
  printf 'design-record.sh: unknown schema_version "%s"\n' "$ver" >&2
  printf 'design-record.sh: supported versions: 1.0, 2.0\n' >&2
  printf 'design-record.sh: update the script or migrate the record\n' >&2
  exit 1
}

# _assert_not_sentinel VALUE FLAG — reject "not-applicable" as a project reference.
_assert_not_sentinel() {
  local value="$1" flag="$2"
  if [ "$value" = "not-applicable" ]; then
    _die "${flag}: the literal \"not-applicable\" is reserved as a sentinel and cannot be used as a project reference"
  fi
}

# _assert_discovered_via VALUE ENUM_LIST CONTEXT — reject unknown discovered_via values.
_assert_discovered_via() {
  local value="$1" enum="$2" context="$3"
  local item
  for item in $enum; do
    [ "$value" = "$item" ] && return 0
  done
  printf 'design-record.sh: %s: unknown discovered_via value "%s"\n' "$context" "$value" >&2
  printf 'design-record.sh: legal values: %s\n' "$enum" >&2
  exit 1
}

# _assert_sync_mode VALUE — reject unknown sync_mode values.
_assert_sync_mode() {
  local value="$1"
  case "$value" in
    react-components|brand-style) return 0 ;;
  esac
  printf 'design-record.sh: unknown sync_mode value "%s"\n' "$value" >&2
  printf 'design-record.sh: legal values: react-components, brand-style\n' >&2
  exit 1
}

# ---------------------------------------------------------------------------
# v2 migration and cross-validation
# ---------------------------------------------------------------------------

# _migrate_v1_to_v2 TMP — atomically upgrade a v1.0 record to v2.0 in place.
# Writes only to TMP (the lock-held copy). Idempotent: no-op on v2.0.
_migrate_v1_to_v2() {
  local tmp="$1"

  # Single probe: compute boolean decisions inside yq so user data never
  # reaches shell splitting (a reference with commas/newlines would break cut).
  # Returns 4 CSV booleans: is_v2, has_dsp, has_pdp, is_na_sentinel (1 yq fork)
  local probe
  probe="$(yq '[
    .schema_version == "2.0",
    has("design_system_project"),
    has("product_design_project"),
    (.applicability == "not-applicable" and .project.reference == "not-applicable")
  ] | @csv' "$tmp")"
  local is_v2 has_dsp has_pdp is_na
  is_v2="$(printf '%s' "$probe" | cut -d',' -f1)"
  has_dsp="$(printf '%s' "$probe" | cut -d',' -f2)"
  has_pdp="$(printf '%s' "$probe" | cut -d',' -f3)"
  is_na="$(printf '%s' "$probe" | cut -d',' -f4)"

  # Already v2 — no-op
  [ "$is_v2" = "true" ] && return 0

  # Downgrade check: v1.0 with v2 keys is tampering
  if [ "$has_dsp" = "true" ] || [ "$has_pdp" = "true" ]; then
    _die "schema downgrade detected: v1.0 record contains v2 keys (design_system_project or product_design_project) — refusing to migrate"
  fi

  if [ "$is_na" = "true" ]; then
    # Not-applicable sentinel: null projects, no sync_mode, no ds_attachment_mode (1 yq fork)
    yq -i '
      .design_system_project = null |
      .product_design_project = null |
      .schema_version = "2.0"
    ' "$tmp"
  else
    # Applicable (or real-ref + not-applicable): copy reference INSIDE yq (1 yq fork).
    # Copying inside yq avoids shell command-substitution trailing-newline stripping.
    yq -i '
      .design_system_project.reference = .project.reference |
      .design_system_project.type = "design-system" |
      .design_system_project.surface = "designsync" |
      .design_system_project.discovered_via = .project.discovered_via |
      .product_design_project = null |
      .sync_mode = "react-components" |
      .ds_attachment_mode = "token-by-value" |
      .schema_version = "2.0"
    ' "$tmp"
  fi
}

# _validate_project_references FILE — cross-validate dual project references.
# Null-aware: allows null design_system_project only on not-applicable records.
_validate_project_references() {
  local file="$1"
  local app dsp pdp

  app="$(yq '.applicability' "$file")"

  # has() in its own invocation
  local has_dsp
  has_dsp="$(yq 'has("design_system_project")' "$file")"
  local has_pdp
  has_pdp="$(yq 'has("product_design_project")' "$file")"

  local sv
  sv="$(yq '.schema_version' "$file")"

  # Missing key check: v2 applicable records must have both keys
  if [ "$sv" = "2.0" ] && [ "$app" != "not-applicable" ]; then
    if [ "$has_dsp" = "false" ]; then
      _die "v2.0 applicable record missing design_system_project key"
    fi
    if [ "$has_pdp" = "false" ]; then
      _die "v2.0 applicable record missing product_design_project key"
    fi
  fi

  # If keys not present, nothing more to check
  [ "$has_dsp" = "true" ] || return 0
  [ "$has_pdp" = "true" ] || return 0

  dsp="$(yq '.design_system_project' "$file")"
  pdp="$(yq '.product_design_project' "$file")"

  # Null design_system_project allowed only on not-applicable
  if [ "$dsp" = "null" ] && [ "$app" != "not-applicable" ]; then
    _die "design_system_project is null on an applicable record — this is not allowed"
  fi

  # Type-check non-null projects
  if [ "$dsp" != "null" ]; then
    local dsp_type
    dsp_type="$(yq '.design_system_project.type' "$file")"
    if [ "$dsp_type" != "design-system" ]; then
      _die "design_system_project.type is \"$dsp_type\" — expected \"design-system\""
    fi
  fi
  if [ "$pdp" != "null" ]; then
    local pdp_type
    pdp_type="$(yq '.product_design_project.type' "$file")"
    if [ "$pdp_type" != "design" ]; then
      _die "product_design_project.type is \"$pdp_type\" — expected \"design\""
    fi
  fi

  # Identical references check (only when both non-null)
  if [ "$dsp" != "null" ] && [ "$pdp" != "null" ]; then
    local dsp_ref pdp_ref
    dsp_ref="$(yq '.design_system_project.reference' "$file")"
    pdp_ref="$(yq '.product_design_project.reference' "$file")"
    if [ "$dsp_ref" = "$pdp_ref" ]; then
      _die "design_system_project.reference and product_design_project.reference are identical (\"$dsp_ref\") — they must refer to different projects"
    fi
  fi

  # ds_attachment_mode enum check (when present)
  local has_dam
  has_dam="$(yq 'has("ds_attachment_mode")' "$file")"
  if [ "$has_dam" = "true" ]; then
    local dam
    dam="$(yq '.ds_attachment_mode' "$file")"
    case "$dam" in
      token-by-value|artifact-installed) ;;
      *) _die "ds_attachment_mode is \"$dam\" — expected \"token-by-value\" or \"artifact-installed\"" ;;
    esac
  fi
}

# ---------------------------------------------------------------------------
# Chained-digest helpers
# ---------------------------------------------------------------------------

_compute_entry_digest() {
  local entry_json="$1" prev_digest="$2"
  local canonical
  canonical="$(printf '%s' "$entry_json" | yq -o=json -I=0 'sort_keys(..) | del(._digest)')"
  printf '%s\n%s' "$canonical" "$prev_digest" | _sha256_stdin
}

# _verify_chain FILE — walk the audit chain and die on mismatch.
#
# Validates three properties:
#   1. Each _digest equals sha256(canonical_entry + "\n" + prev_digest)
#   2. audit_head.{count,last_digest} agrees with the actual array
#   3. Top-level design_state matches the last audit entry's design_state
#
# The third check catches edits to the top-level field via yq -i outside
# the writer.  The chained digest alone would not detect that because the
# digest covers only the audit entries, not the top-level summary fields.
_verify_chain() {
  local file="$1"
  local count
  count="$(yq '.audit | length' "$file")"
  [ "$count" -gt 0 ] || return 0

  # Check audit_head consistency
  local head_count head_digest
  head_count="$(yq '.audit_head.count' "$file")"
  head_digest="$(yq '.audit_head.last_digest' "$file")"

  if [ "$head_count" != "$count" ]; then
    printf 'design-record.sh: integrity failure — audit_head.count (%s) != audit length (%s)\n' \
      "$head_count" "$count" >&2
    exit 1
  fi

  # Walk the chain
  local i prev_digest="" entry_json stored_digest computed_digest
  for (( i=0; i<count; i++ )); do
    entry_json="$(yq -o=json -I=0 ".audit[$i]" "$file")"
    stored_digest="$(printf '%s' "$entry_json" | yq -r '._digest')"
    computed_digest="$(_compute_entry_digest "$entry_json" "$prev_digest")"
    if [ "$stored_digest" != "$computed_digest" ]; then
      printf 'design-record.sh: integrity failure — digest chain broken at audit[%d]\n' "$i" >&2
      printf 'design-record.sh: expected %s, found %s\n' "$computed_digest" "$stored_digest" >&2
      exit 1
    fi
    prev_digest="$stored_digest"
  done

  # Verify the last digest matches audit_head
  if [ "$prev_digest" != "$head_digest" ]; then
    printf 'design-record.sh: integrity failure — audit_head.last_digest mismatch\n' >&2
    printf 'design-record.sh: expected %s, found %s\n' "$prev_digest" "$head_digest" >&2
    exit 1
  fi

  # Cross-check: top-level design_state must match the last audit entry's
  local top_state last_audit_state
  top_state="$(yq '.design_state' "$file")"
  last_audit_state="$(yq ".audit[$((count - 1))].design_state" "$file")"
  if [ "$top_state" != "$last_audit_state" ]; then
    printf 'design-record.sh: integrity failure — design_state (%s) disagrees with last audit entry (%s)\n' \
      "$top_state" "$last_audit_state" >&2
    printf 'design-record.sh: this indicates tampering outside the sole writer\n' >&2
    exit 1
  fi
}

# _append_audit TMP_FILE EVENT ACTOR [extra yq expressions...]
# Appends an audit entry, computes its chained digest, and updates audit_head.
_append_audit() {
  local tmp="$1" event="$2" actor="$3"; shift 3

  local now design_state iteration
  now="$(_now_iso)"
  design_state="$(yq '.design_state' "$tmp")"
  iteration="$(yq '.iteration' "$tmp")"

  # Previous digest: last entry's, or empty for the first entry
  local prev_digest="" count
  count="$(yq '.audit | length' "$tmp")"
  if [ "$count" -gt 0 ]; then
    prev_digest="$(yq -r ".audit[$((count - 1))]._digest" "$tmp")"
  fi

  # Build the entry as JSON (without _digest initially).
  # All values passed through the environment + strenv()/env() to avoid
  # injection via quotes, backslashes, or yq expressions in user input.
  local entry_json
  entry_json="$(
    _AE_AT="$now" _AE_ACTOR="$actor" _AE_EVENT="$event" \
    _AE_DS="$design_state" _AE_ITER="$iteration" \
    yq -n -o=json -I=0 \
      '{"at":strenv(_AE_AT),"actor":strenv(_AE_ACTOR),"event":strenv(_AE_EVENT),"design_state":strenv(_AE_DS),"iteration":env(_AE_ITER)}'
  )"

  # Merge optional key=value pairs from extra args
  local extra
  for extra in "$@"; do
    local key="${extra%%=*}" val="${extra#*=}"
    entry_json="$(printf '%s' "$entry_json" | _AE_VAL="$val" yq -o=json -I=0 ".${key} = strenv(_AE_VAL)")"
  done

  # Compute and append the chained digest
  local digest
  digest="$(_compute_entry_digest "$entry_json" "$prev_digest")"
  entry_json="$(printf '%s' "$entry_json" | _AE_DIG="$digest" yq -o=json -I=0 '._digest = strenv(_AE_DIG)')"

  _AE_ENTRY="$entry_json" yq -i '.audit += [env(_AE_ENTRY)]' "$tmp"
  yq -i ".audit_head.count = $((count + 1))" "$tmp"
  _AE_DIG="$digest" yq -i '.audit_head.last_digest = strenv(_AE_DIG)' "$tmp"

  # Injected delay for concurrency testing — never present in production
  if [ -n "${GAIA_DREC_WRITE_DELAY:-}" ]; then
    sleep "$GAIA_DREC_WRITE_DELAY"
  fi
}

# _locked_mutate CALLBACK [ARGS...] — acquire lock, validate, mutate, publish.
#
# Runs CALLBACK inside a subshell that holds the lock.  The subshell is
# intentional: it guarantees the lock FD is closed on exit regardless of
# how the callback terminates (errexit, signal, _die), preventing leaked
# locks that would block all subsequent writers.
_locked_mutate() {
  local callback="$1"; shift
  (
    if ! acquire_lock "$LOCK_PATH" "$LOCK_TIMEOUT" "$LOCK_FD"; then
      _die "lock timeout acquiring $LOCK_PATH"
    fi
    _DR_DONE=0
    trap '_rc=$?; release_lock "$LOCK_FD" 2>/dev/null || true; [ "${_DR_DONE:-0}" = 1 ] || { [ "$_rc" -eq 0 ] && _rc=1; }; rm -f "${_DR_TMP:-}" 2>/dev/null || true; exit $_rc' EXIT

    # Read current record into working copy
    local tmp
    tmp=$(mktemp "${RECORD_PATH}.tmp.XXXXXX")
    _DR_TMP="$tmp"
    cp "$RECORD_PATH" "$tmp"

    # In-lock validations
    _validate_schema_version "$tmp"
    _verify_chain "$tmp"

    # Migrate v1 → v2 before the callback
    _migrate_v1_to_v2 "$tmp"

    # Cross-validation after migration, before callback
    _validate_project_references "$tmp"

    # Apply mutation callback
    "$callback" "$tmp" "$@"

    # Cross-validation after callback, before publish
    _validate_project_references "$tmp"

    # Atomic publish: mv is atomic on POSIX within a single filesystem
    mv -f "$tmp" "$RECORD_PATH" || _die "atomic publish failed"
    _DR_TMP=""
    _DR_DONE=1
  )
}

# ---------------------------------------------------------------------------
# Roster resolution
# ---------------------------------------------------------------------------

# _roster_dir_exists — true when at least one roster directory is present.
_roster_dir_exists() {
  [ -d "${_PROJECT_ROOT}/.gaia/custom/stakeholders" ] || \
    [ -d "${_PROJECT_ROOT}/custom/stakeholders" ]
}

# _resolve_merged_roster — output one line per resolved stakeholder file:
#   slug\tpath
# Scans .gaia/custom/stakeholders first (higher precedence), then root
# custom/stakeholders. Deduplicates by slug: a slug already seen from the
# higher-precedence directory is skipped when encountered in the root.
# Before yq: checks that a closing --- delimiter exists after line 1.
# If slug: is present and disagrees with the filename stem, warns and skips.
# Bash 3.2 safe — no associative arrays.
_resolve_merged_roster() {
  local _seen_slugs=" "
  local dir f stem slug_field

  for dir in "${_PROJECT_ROOT}/.gaia/custom/stakeholders" "${_PROJECT_ROOT}/custom/stakeholders"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.md; do
      [ -f "$f" ] || continue
      stem="$(basename "$f" .md)"

      # Frontmatter delimiter check: require a closing --- after line 1.
      # The opening --- is line 1; a closing --- must appear on a later line.
      if ! sed -n '2,$p' "$f" | grep -q '^---$'; then
        printf 'design-record.sh: warning: %s has no closing --- delimiter — skipped\n' "$(basename "$f")" >&2
        continue
      fi

      # Read slug: field from frontmatter
      slug_field="$(yq 'select(di == 0) | .slug' "$f" 2>/dev/null || true)"
      if [ -n "$slug_field" ] && [ "$slug_field" != "null" ]; then
        # slug: field present — must agree with filename stem
        if [ "$slug_field" != "$stem" ]; then
          printf 'design-record.sh: warning: %s: slug '\''%s'\'' disagrees with filename '\''%s'\'' — skipped\n' \
            "$(basename "$f")" "$slug_field" "$stem" >&2
          continue
        fi
      fi

      # Dedup by slug: skip if already seen from a higher-precedence directory
      case "$_seen_slugs" in
        *" ${stem} "*) continue ;;
      esac
      _seen_slugs="${_seen_slugs}${stem} "

      printf '%s\t%s\n' "$stem" "$f"
    done
  done
}

# _get_required_stakeholders — output one slug per line for design/ux-tagged stakeholders.
# Reads the merged roster and filters by tag (case-insensitive).
_get_required_stakeholders() {
  local slug path tags
  while IFS='	' read -r slug path; do
    [ -n "$slug" ] || continue
    # select(di == 0): read only the first YAML document (frontmatter).
    tags="$(yq 'select(di == 0) | .tags[]' "$path" 2>/dev/null || true)"
    if printf '%s\n' "$tags" | grep -qiE '^(design|ux)$'; then
      printf '%s\n' "$slug"
    fi
  done <<< "$(_resolve_merged_roster)"
}

# _assert_known_stakeholder STAKEHOLDER — reject stakeholders not on the roster.
# Searches the merged roster for the given slug (literal match, not regex).
# Returns 1 when the roster is empty (fail closed) or the slug is not found.
_assert_known_stakeholder() {
  local stakeholder="$1"
  local roster
  roster="$(_resolve_merged_roster)"
  if [ -z "$roster" ]; then
    if _roster_dir_exists; then
      printf 'design-record.sh: warning: vacuous roster — no design/ux-tagged stakeholders\n' >&2
    else
      printf 'design-record.sh: warning: vacuous roster — no stakeholder directory found\n' >&2
    fi
    return 1
  fi
  # Literal slug match via awk -v (not grep regex) to prevent injection
  printf '%s\n' "$roster" | awk -F'	' -v slug="$stakeholder" '$1 == slug { found=1; exit } END { exit !found }'
}

# ---------------------------------------------------------------------------
# Record pre-flight checks (used by both read and mutation paths)
# ---------------------------------------------------------------------------

_assert_record_exists() {
  if [ ! -f "$RECORD_PATH" ]; then
    printf 'design-record.sh: record absent — no design record at %s\n' "$RECORD_PATH" >&2
    exit 1
  fi
}

# _preflight_read — validate for read-only paths (show, status, check-convergence).
# Checks existence, parseability, and schema version.
_preflight_read() {
  _assert_record_exists
  if ! yq '.' "$RECORD_PATH" >/dev/null 2>&1; then
    printf 'design-record.sh: corrupt YAML — cannot parse design-record at %s\n' "$RECORD_PATH" >&2
    exit 1
  fi
  _validate_schema_version "$RECORD_PATH"
}

# _preflight_mutate — validate for mutation paths (transition, approve, etc).
# Checks existence, schema, and refuses symlinks before any lock or I/O.
_preflight_mutate() {
  if [ -L "$RECORD_PATH" ]; then
    _die "record path is a symlink at $RECORD_PATH — refusing to follow; remove the symlink first"
  fi
  _preflight_read
}

# ---------------------------------------------------------------------------
# Convergence check (shared between cmd_check_convergence and _do_transition)
# ---------------------------------------------------------------------------

# _check_convergence_at FILE — check whether all required stakeholders
# have approved at the record's current iteration.
# Reads ONLY .design_state, .iteration, .approvals — NEVER .audit.
# This is deliberate: convergence is answerable from summary fields alone,
# so the read path avoids the O(n) chain walk, keeping it fast for CI gates.
#
# Outputs: "converged", "not-converged (missing: ...)", or "vacuous-convergence"
# Returns: 0 on converged, 1 on not-converged or vacuous
_check_convergence_at() {
  local file="$1"
  local iteration
  iteration="$(yq '.iteration' "$file")"

  # Detect whether any roster directory exists before running the resolver.
  # This keeps the two vacuous diagnostics distinguishable: "no stakeholder
  # directory found" vs "no design/ux-tagged stakeholders".
  if ! _roster_dir_exists; then
    printf 'design-record.sh: warning: vacuous roster — no stakeholder directory found\n' >&2
    printf 'vacuous-convergence\n'
    return 1
  fi

  local required_stakeholders
  required_stakeholders="$(_get_required_stakeholders)"

  if [ -z "$required_stakeholders" ]; then
    printf 'design-record.sh: warning: vacuous roster — no design/ux-tagged stakeholders\n' >&2
    printf 'vacuous-convergence\n'
    return 1
  fi

  local stakeholder missing=""
  while IFS= read -r stakeholder; do
    [ -n "$stakeholder" ] || continue
    local has_approval
    has_approval="$(_CC_SH="$stakeholder" _CC_ITER="$iteration" \
      yq '.approvals[] | select(.stakeholder == strenv(_CC_SH) and .iteration == env(_CC_ITER))' "$file" 2>/dev/null || true)"
    if [ -z "$has_approval" ]; then
      missing="${missing} ${stakeholder}"
    fi
  done <<< "$required_stakeholders"

  if [ -n "$missing" ]; then
    printf 'not-converged (missing:%s)\n' "$missing"
    return 1
  fi

  printf 'converged\n'
  return 0
}

# ---------------------------------------------------------------------------
# Public functions: mutation verbs
# ---------------------------------------------------------------------------

# validate_record — schema + integrity pre-flight used on mutation paths.
validate_record() {
  _preflight_read
}

# cmd_init — create a new record from arguments.
# Refuses when a record already exists (protecting the audit trail) and when
# the record path is a symlink (preventing writes through symlinks).
cmd_init() {
  local reference="" ds_reference="__UNSET__" pd_reference="__UNSET__" discovered_via="" questionnaire_record="__UNSET__" actor="" sync_mode="__UNSET__"
  _parse_opts \
    --reference reference \
    --ds-reference ds_reference \
    --pd-reference pd_reference \
    --discovered-via discovered_via \
    --questionnaire-record questionnaire_record \
    --sync-mode sync_mode \
    --actor actor \
    -- "$@"

  # --ds-reference wins over --reference when both given
  if [ "$ds_reference" != "__UNSET__" ]; then
    reference="$ds_reference"
  fi

  [ -n "$reference" ] || _die "init: --reference (or --ds-reference) required"
  [ -n "$discovered_via" ] || _die "init: --discovered-via required"
  actor="${actor:-${USER:-unknown}}"

  # Sentinel rejection on all reference flags
  _assert_not_sentinel "$reference" "init --reference/--ds-reference"
  if [ "$pd_reference" != "__UNSET__" ]; then
    [ -n "$pd_reference" ] || _die "init: --pd-reference must not be empty"
    _assert_not_sentinel "$pd_reference" "init --pd-reference"
    # Identical references check
    if [ "$pd_reference" = "$reference" ]; then
      _die "init: --ds-reference and --pd-reference must refer to different projects (both are \"$reference\")"
    fi
  fi

  # Enum validations
  _assert_discovered_via "$discovered_via" "project-artifacts integration-list created" "init"
  if [ "$sync_mode" != "__UNSET__" ]; then
    _assert_sync_mode "$sync_mode"
  else
    sync_mode="react-components"
  fi

  # Questionnaire-record: required on created path; -f validated whenever supplied
  if [ "$discovered_via" = "created" ] && [ "$questionnaire_record" = "__UNSET__" ]; then
    _die "init: --questionnaire-record is required when --discovered-via is \"created\""
  fi
  if [ "$questionnaire_record" != "__UNSET__" ]; then
    [ -n "$questionnaire_record" ] || _die "init: --questionnaire-record must not be empty"
    local resolved_qr="$questionnaire_record"
    [ "${resolved_qr#/}" = "$resolved_qr" ] && resolved_qr="${_PROJECT_ROOT}/$resolved_qr"
    [ -f "$resolved_qr" ] || _die "init: --questionnaire-record file not found: $questionnaire_record"
  else
    questionnaire_record="skipped"
  fi

  mkdir -p "$(dirname "$RECORD_PATH")"

  # Refuse if the record path is a symlink — prevents writes through symlinks
  if [ -L "$RECORD_PATH" ]; then
    _die "init: record path is a symlink at $RECORD_PATH — refusing to follow; remove the symlink first"
  fi

  # Refuse when a record already exists — protects the audit trail, approvals,
  # overrides, and state from accidental destruction
  if [ -f "$RECORD_PATH" ]; then
    _die "init: record already exists at $RECORD_PATH — use transition, approve, add-review, add-override, or other mutation verbs to modify it"
  fi

  # Write to a temp file first, then atomically move into place —
  # same pattern as mutation verbs, preventing partial writes
  local tmp
  tmp=$(mktemp "$(dirname "$RECORD_PATH")/design-record.yaml.tmp.XXXXXX")
  trap '_rc=$?; [ "$_rc" -eq 0 ] && _rc=1; rm -f "$tmp" 2>/dev/null || true; exit $_rc' EXIT

  cat > "$tmp" <<'EOF'
schema_version: "2.0"
applicability: applicable
design_state: draft
iteration: 1
project:
  reference: ""
  discovered_via: ""
  questionnaire_record: ""
design_system_project:
  reference: ""
  type: "design-system"
  surface: "designsync"
  discovered_via: ""
product_design_project: null
sync_mode: "react-components"
ds_attachment_mode: "token-by-value"
reviews: []
approvals: []
overrides: []
audit: []
audit_head:
  count: 0
  last_digest: ""
EOF

  # Set project fields via strenv() to handle special characters safely
  _CI_REF="$reference" yq -i '.project.reference = strenv(_CI_REF)' "$tmp"
  _CI_DV="$discovered_via" yq -i '.project.discovered_via = strenv(_CI_DV)' "$tmp"
  _CI_QR="$questionnaire_record" yq -i '.project.questionnaire_record = strenv(_CI_QR)' "$tmp"

  # design_system_project mirrors project
  _CI_REF="$reference" yq -i '.design_system_project.reference = strenv(_CI_REF)' "$tmp"
  _CI_DV="$discovered_via" yq -i '.design_system_project.discovered_via = strenv(_CI_DV)' "$tmp"

  # sync_mode
  _CI_SM="$sync_mode" yq -i '.sync_mode = strenv(_CI_SM)' "$tmp"

  # product_design_project when --pd-reference given
  if [ "$pd_reference" != "__UNSET__" ]; then
    _CI_PD="$pd_reference" yq -i '
      .product_design_project.reference = strenv(_CI_PD) |
      .product_design_project.type = "design" |
      .product_design_project.surface = "artifact" |
      .product_design_project.discovered_via = "existing"
    ' "$tmp"
  fi

  # Cross-validation before publish
  _validate_project_references "$tmp"

  # No lock needed — new file, no contention possible
  _append_audit "$tmp" "state-transition" "$actor" "from=draft" "to=draft"

  # Atomic publish
  mv -f "$tmp" "$RECORD_PATH" || _die "init: atomic publish failed"
  trap - EXIT
}

# cmd_show — read and display the record (human-readable).
cmd_show() {
  _preflight_read

  local design_state iteration schema_version applicability
  design_state="$(yq '.design_state' "$RECORD_PATH")"
  iteration="$(yq '.iteration' "$RECORD_PATH")"
  schema_version="$(yq '.schema_version' "$RECORD_PATH")"
  applicability="$(yq '.applicability' "$RECORD_PATH")"

  printf 'Design Record (schema %s)\n' "$schema_version"
  printf '  state:         %s\n' "$design_state"
  printf '  iteration:     %s\n' "$iteration"
  printf '  applicability: %s\n' "$applicability"

  local approvals reviews overrides audit_count
  approvals="$(yq '.approvals | length' "$RECORD_PATH")"
  reviews="$(yq '.reviews | length' "$RECORD_PATH")"
  overrides="$(yq '.overrides | length' "$RECORD_PATH")"
  audit_count="$(yq '.audit | length' "$RECORD_PATH")"

  printf '  approvals:     %s\n' "$approvals"
  printf '  reviews:       %s\n' "$reviews"
  printf '  overrides:     %s\n' "$overrides"
  printf '  audit entries: %s\n' "$audit_count"
}

# cmd_status — machine-readable state + convergence status.
cmd_status() {
  _preflight_read

  printf 'design_state: %s\n' "$(yq '.design_state' "$RECORD_PATH")"
  printf 'iteration: %s\n' "$(yq '.iteration' "$RECORD_PATH")"
}

# cmd_transition — state-machine transition.
cmd_transition() {
  local to="" actor="" int_state="" int_source=""
  _parse_opts --to to --actor actor --integration-state int_state --integration-source int_source -- "$@"

  if [ -z "$to" ]; then
    printf 'design-record.sh: transition: --to required\n' >&2
    printf 'design-record.sh: legal values: draft, review, approved, in-dev, stale\n' >&2
    exit 1
  fi
  actor="${actor:-${USER:-unknown}}"

  # Both-or-neither: the two integration options travel as a pair
  if { [ -n "$int_state" ] && [ -z "$int_source" ]; } || \
     { [ -z "$int_state" ] && [ -n "$int_source" ]; }; then
    _die "transition: --integration-state and --integration-source must be provided together"
  fi

  # Stale-only: integration options are meaningful only on the stale edge
  if [ -n "$int_state" ] && [ "$to" != "stale" ]; then
    _die "transition: --integration-state and --integration-source are only allowed with --to stale"
  fi

  # Enum validation for integration options (before any lock or I/O)
  if [ -n "$int_state" ]; then
    case "$int_state" in
      available|missing|unauthorized) ;;
      *) _die "transition: illegal --integration-state value \"$int_state\"; legal values: available, missing, unauthorized" ;;
    esac
    case "$int_source" in
      attested|probed) ;;
      *) _die "transition: illegal --integration-source value \"$int_source\"; legal values: attested, probed" ;;
    esac
  fi

  # Pre-lock validation: enum and transition legality checked BEFORE
  # acquiring the lock so illegal requests never block other writers.
  _assert_valid_state "$to" "transition --to"
  _preflight_mutate

  local current_state
  current_state="$(yq '.design_state' "$RECORD_PATH")"
  _assert_legal_transition "$current_state" "$to"

  _locked_mutate _do_transition "$to" "$actor" "$int_state" "$int_source"
}

_do_transition() {
  local tmp="$1" to="$2" actor="$3" int_state="${4:-}" int_source="${5:-}"

  local current_state current_iter
  current_state="$(yq '.design_state' "$tmp")"
  current_iter="$(yq '.iteration' "$tmp")"

  # For review -> approved, convergence is a gate
  if [ "$current_state" = "review" ] && [ "$to" = "approved" ]; then
    local conv_result
    conv_result="$(_check_convergence_at "$tmp" 2>/dev/null)" || \
      _die "transition review->approved blocked: ${conv_result}"
  fi

  # Bump iteration on review-to-review and stale-to-review: prior approvals
  # remain keyed to the old iteration, so they no longer satisfy convergence.
  local new_iter="$current_iter"
  if [ "$to" = "review" ] && { [ "$current_state" = "review" ] || [ "$current_state" = "stale" ]; }; then
    new_iter=$((current_iter + 1))
    yq -i ".iteration = $new_iter" "$tmp"
  fi

  _DT_TO="$to" yq -i '.design_state = strenv(_DT_TO)' "$tmp"

  # Append the audit entry; include integration state when present
  if [ -n "$int_state" ]; then
    _append_audit "$tmp" "state-transition" "$actor" "from=${current_state}" "to=${to}" \
      "integration_state=${int_state}" "integration_source=${int_source}"
  else
    _append_audit "$tmp" "state-transition" "$actor" "from=${current_state}" "to=${to}"
  fi
}

# cmd_approve — record a stakeholder approval.
cmd_approve() {
  local stakeholder="" recorded_by=""
  _parse_opts --stakeholder stakeholder --recorded-by recorded_by -- "$@"

  [ -n "$stakeholder" ] || _die "approve: --stakeholder required"
  [ -n "$recorded_by" ] || _die "approve: --recorded-by required"

  _preflight_mutate

  # Check roster before locking — reject unknown stakeholders early
  if ! _assert_known_stakeholder "$stakeholder"; then
    _locked_mutate _do_refuse_approval "$stakeholder" "$recorded_by"
    exit 1
  fi

  _locked_mutate _do_approve "$stakeholder" "$recorded_by"
}

_do_approve() {
  local tmp="$1" stakeholder="$2" recorded_by="$3"
  local now iteration
  now="$(_now_iso)"
  iteration="$(yq '.iteration' "$tmp")"

  local entry
  entry="$(
    _DA_SH="$stakeholder" _DA_RB="$recorded_by" _DA_ITER="$iteration" _DA_AT="$now" \
    yq -n -o=json -I=0 \
      '{"stakeholder":strenv(_DA_SH),"recorded_by":strenv(_DA_RB),"iteration":env(_DA_ITER),"at":strenv(_DA_AT)}'
  )"
  _DA_ENTRY="$entry" yq -i '.approvals += [env(_DA_ENTRY)]' "$tmp"
  _append_audit "$tmp" "approval" "$recorded_by" "stakeholder_id=${stakeholder}" "recorded_by=${recorded_by}"
}

_do_refuse_approval() {
  local tmp="$1" stakeholder="$2" recorded_by="$3"
  printf 'design-record.sh: unknown stakeholder "%s" — not on the roster\n' "$stakeholder" >&2
  _append_audit "$tmp" "approval-refused" "$recorded_by" \
    "stakeholder_id=${stakeholder}" "reason=stakeholder not on roster"
}

# cmd_add_review — record a review verdict.
cmd_add_review() {
  local verdict="" reviewer="" actor="" kind="design-review" notes_ref=""
  _parse_opts \
    --verdict verdict \
    --reviewer reviewer \
    --actor actor \
    --kind kind \
    --notes-ref notes_ref \
    -- "$@"

  [ -n "$verdict" ] || _die "add-review: --verdict required"
  [ -n "$reviewer" ] || _die "add-review: --reviewer required"
  actor="${actor:-$reviewer}"

  # Enum guards — reject invalid values before any record I/O.
  _assert_valid_verdict "$verdict"
  _assert_valid_kind "$kind"

  _preflight_mutate
  _locked_mutate _do_add_review "$verdict" "$reviewer" "$actor" "$kind" "$notes_ref"
}

_do_add_review() {
  local tmp="$1" verdict="$2" reviewer="$3" actor="$4" kind="$5" notes_ref="${6:-}"
  local now iteration
  now="$(_now_iso)"
  iteration="$(yq '.iteration' "$tmp")"

  local entry
  entry="$(
    _DR_ITER="$iteration" _DR_KIND="$kind" _DR_VERD="$verdict" \
    _DR_ACTOR="$reviewer" _DR_AT="$now" \
    yq -n -o=json -I=0 \
      '{"iteration":env(_DR_ITER),"kind":strenv(_DR_KIND),"verdict":strenv(_DR_VERD),"actor":strenv(_DR_ACTOR),"at":strenv(_DR_AT)}'
  )"
  # Conditionally add notes_ref only when a value was provided
  if [ -n "$notes_ref" ]; then
    entry="$(printf '%s' "$entry" | _DR_NR="$notes_ref" yq -o=json -I=0 '.notes_ref = strenv(_DR_NR)')"
  fi
  _DR_ENTRY="$entry" yq -i '.reviews += [env(_DR_ENTRY)]' "$tmp"
  _append_audit "$tmp" "review-verdict" "$actor" "verdict=${verdict}" "kind=${kind}"
}

# cmd_add_override — record an audited override.
cmd_add_override() {
  local actor="" reason="" entry_point="" sprint_id=""
  _parse_opts --actor actor --reason reason --entry-point entry_point --sprint-id sprint_id -- "$@"

  [ -n "$actor" ] || _die "add-override: --actor required"
  [ -n "$reason" ] || _die "add-override: --reason required"
  [ -n "$entry_point" ] || _die "add-override: --entry-point required"

  # Validate sprint_id format before taking the lock (early rejection).
  if [ -n "$sprint_id" ] && ! printf '%s' "$sprint_id" | grep -Eq '^sprint-[0-9]+$'; then
    printf 'add-override: malformed --sprint-id value.\n' >&2
    printf '  Got:      %s\n' "$sprint_id" >&2
    printf '  Expected: sprint-N (matching ^sprint-[0-9]+$)\n' >&2
    exit 1
  fi

  _preflight_mutate
  _locked_mutate _do_add_override "$actor" "$reason" "$entry_point" "$sprint_id"
}

_do_add_override() {
  local tmp="$1" actor="$2" reason="$3" entry_point="$4" sprint_id="${5:-}"
  local now design_state
  now="$(_now_iso)"
  design_state="$(yq '.design_state' "$tmp")"

  local entry
  entry="$(
    _DO_USER="$actor" _DO_AT="$now" _DO_REASON="$reason" \
    _DO_EP="$entry_point" _DO_DS="$design_state" \
    yq -n -o=json -I=0 \
      '{"user":strenv(_DO_USER),"at":strenv(_DO_AT),"reason":strenv(_DO_REASON),"entry_point":strenv(_DO_EP),"design_state_at_override":strenv(_DO_DS)}'
  )"

  # Add sprint_id to the override entry only when supplied (omit the key entirely otherwise).
  if [ -n "$sprint_id" ]; then
    entry="$(printf '%s' "$entry" | _DO_SID="$sprint_id" yq -o=json -I=0 '.sprint_id = strenv(_DO_SID)')"
  fi

  _DO_ENTRY="$entry" yq -i '.overrides += [env(_DO_ENTRY)]' "$tmp"

  # Pass sprint_id to the audit trail only when supplied.
  if [ -n "$sprint_id" ]; then
    _append_audit "$tmp" "override" "$actor" "reason=${reason}" "entry_point=${entry_point}" "sprint_id=${sprint_id}"
  else
    _append_audit "$tmp" "override" "$actor" "reason=${reason}" "entry_point=${entry_point}"
  fi
}

# cmd_not_applicable — mark the project as not requiring design approval.
cmd_not_applicable() {
  local actor=""
  _parse_opts --actor actor -- "$@"
  actor="${actor:-${USER:-unknown}}"

  _preflight_mutate
  _locked_mutate _do_not_applicable "$actor"
}

_do_not_applicable() {
  local tmp="$1" actor="$2"
  yq -i '.applicability = "not-applicable"' "$tmp"
  _append_audit "$tmp" "not-applicable-pass" "$actor"
}

# cmd_init_not_applicable — create a minimal not-applicable record on a fresh
# project, or delegate to cmd_not_applicable on an existing record.
#
# On a fresh project (no record on disk): creates a schema-valid record with
# applicability not-applicable, documented sentinel project values, and a single
# not-applicable-pass audit entry. Published via tempfile-then-mv (same as init).
#
# On an existing record: delegates to cmd_not_applicable (idempotent).
cmd_init_not_applicable() {
  local actor=""
  _parse_opts --actor actor -- "$@"
  actor="${actor:-${USER:-unknown}}"

  # Refuse symlinks BEFORE checking existence (same discipline as init)
  if [ -L "$RECORD_PATH" ]; then
    _die "init-not-applicable: record path is a symlink at $RECORD_PATH — refusing to follow; remove the symlink first"
  fi

  if [ -f "$RECORD_PATH" ]; then
    # Record exists — delegate to the existing not-applicable verb
    cmd_not_applicable --actor "$actor"
    return $?
  fi

  mkdir -p "$(dirname "$RECORD_PATH")"

  # Write to a temp file first, then atomically move into place
  local tmp
  tmp=$(mktemp "$(dirname "$RECORD_PATH")/design-record.yaml.tmp.XXXXXX")
  trap '_rc=$?; [ "$_rc" -eq 0 ] && _rc=1; rm -f "$tmp" 2>/dev/null || true; exit $_rc' EXIT

  cat > "$tmp" <<'EOF'
schema_version: "2.0"
applicability: not-applicable
design_state: draft
iteration: 1
project:
  reference: "not-applicable"
  discovered_via: "project-artifacts"
  questionnaire_record: "not-applicable"
design_system_project: null
product_design_project: null
reviews: []
approvals: []
overrides: []
audit: []
audit_head:
  count: 0
  last_digest: ""
EOF

  # Append the not-applicable-pass audit entry with a chained digest
  _append_audit "$tmp" "not-applicable-pass" "$actor"

  # Atomic publish
  mv -f "$tmp" "$RECORD_PATH" || _die "init-not-applicable: atomic publish failed"
  trap - EXIT
}

# cmd_reopen_applicable — transition a not-applicable record back to
# applicable/draft so the project can go through the design approval process.
# Refuses unless the current applicability is not-applicable. Validates inputs
# the same way cmd_init does. Resets design_state to draft and iteration to 1.
cmd_reopen_applicable() {
  local reference="" ds_reference="__UNSET__" pd_reference="__UNSET__" discovered_via="" questionnaire_record="__UNSET__" actor="" sync_mode="__UNSET__"
  _parse_opts \
    --reference reference \
    --ds-reference ds_reference \
    --pd-reference pd_reference \
    --discovered-via discovered_via \
    --questionnaire-record questionnaire_record \
    --sync-mode sync_mode \
    --actor actor \
    -- "$@"

  # --ds-reference wins over --reference when both given
  if [ "$ds_reference" != "__UNSET__" ]; then
    reference="$ds_reference"
  fi

  [ -n "$reference" ] || _die "reopen-applicable: --reference (or --ds-reference) required"
  [ -n "$discovered_via" ] || _die "reopen-applicable: --discovered-via required"
  actor="${actor:-${USER:-unknown}}"

  # Sentinel rejection
  _assert_not_sentinel "$reference" "reopen-applicable --reference/--ds-reference"
  if [ "$pd_reference" != "__UNSET__" ]; then
    [ -n "$pd_reference" ] || _die "reopen-applicable: --pd-reference must not be empty"
    _assert_not_sentinel "$pd_reference" "reopen-applicable --pd-reference"
    if [ "$pd_reference" = "$reference" ]; then
      _die "reopen-applicable: --ds-reference and --pd-reference must refer to different projects (both are \"$reference\")"
    fi
  fi

  # Enum validations
  _assert_discovered_via "$discovered_via" "project-artifacts integration-list created" "reopen-applicable"
  if [ "$sync_mode" != "__UNSET__" ]; then
    _assert_sync_mode "$sync_mode"
  fi

  # Questionnaire-record: required on created path; -f validated whenever supplied
  if [ "$discovered_via" = "created" ] && [ "$questionnaire_record" = "__UNSET__" ]; then
    _die "reopen-applicable: --questionnaire-record is required when --discovered-via is \"created\""
  fi
  if [ "$questionnaire_record" != "__UNSET__" ]; then
    [ -n "$questionnaire_record" ] || _die "reopen-applicable: --questionnaire-record must not be empty"
    local resolved_qr="$questionnaire_record"
    [ "${resolved_qr#/}" = "$resolved_qr" ] && resolved_qr="${_PROJECT_ROOT}/$resolved_qr"
    [ -f "$resolved_qr" ] || _die "reopen-applicable: --questionnaire-record file not found: $questionnaire_record"
  else
    questionnaire_record="skipped"
  fi

  # Refuse symlinks (same discipline as init)
  if [ -L "$RECORD_PATH" ]; then
    _die "reopen-applicable: record path is a symlink at $RECORD_PATH — refusing to follow; remove the symlink first"
  fi

  _preflight_mutate

  # Pre-lock check: must be not-applicable
  local current_app
  current_app="$(yq '.applicability' "$RECORD_PATH")"
  if [ "$current_app" != "not-applicable" ]; then
    _die "reopen-applicable: record applicability is '$current_app', not 'not-applicable' — this verb only transitions from not-applicable"
  fi

  _locked_mutate _do_reopen_applicable "$reference" "$discovered_via" "$questionnaire_record" "$actor" "$pd_reference" "$sync_mode"
}

_do_reopen_applicable() {
  local tmp="$1" reference="$2" discovered_via="$3" questionnaire_record="$4" actor="$5" pd_reference="${6:-__UNSET__}" sync_mode="${7:-__UNSET__}"

  # Double-check applicability inside the lock
  local current_app
  current_app="$(yq '.applicability' "$tmp")"
  if [ "$current_app" != "not-applicable" ]; then
    _die "reopen-applicable: concurrent race — applicability changed to '$current_app'"
  fi

  # Set applicability, state, and iteration
  yq -i '.applicability = "applicable"' "$tmp"
  yq -i '.design_state = "draft"' "$tmp"
  yq -i '.iteration = 1' "$tmp"

  # Overwrite project fields via strenv() (safe for special characters)
  _RA_REF="$reference" yq -i '.project.reference = strenv(_RA_REF)' "$tmp"
  _RA_DV="$discovered_via" yq -i '.project.discovered_via = strenv(_RA_DV)' "$tmp"
  _RA_QR="$questionnaire_record" yq -i '.project.questionnaire_record = strenv(_RA_QR)' "$tmp"

  # design_system_project mirrors project
  _RA_REF="$reference" yq -i '
    .design_system_project.reference = strenv(_RA_REF) |
    .design_system_project.type = "design-system" |
    .design_system_project.surface = "designsync"
  ' "$tmp"
  _RA_DV="$discovered_via" yq -i '.design_system_project.discovered_via = strenv(_RA_DV)' "$tmp"

  # sync_mode: use given value, else keep existing, else default
  if [ "$sync_mode" != "__UNSET__" ]; then
    _RA_SM="$sync_mode" yq -i '.sync_mode = strenv(_RA_SM)' "$tmp"
  else
    local has_sm
    has_sm="$(yq 'has("sync_mode")' "$tmp")"
    if [ "$has_sm" = "false" ]; then
      yq -i '.sync_mode = "react-components"' "$tmp"
    fi
  fi

  # product_design_project handling
  if [ "$pd_reference" != "__UNSET__" ]; then
    # Check no-overwrite: refuse when product_design_project is already non-null
    local current_pdp
    current_pdp="$(yq '.product_design_project' "$tmp")"
    if [ "$current_pdp" != "null" ]; then
      _die "reopen-applicable: product_design_project is already set — use set-product-project to modify"
    fi
    _RA_PD="$pd_reference" yq -i '
      .product_design_project.reference = strenv(_RA_PD) |
      .product_design_project.type = "design" |
      .product_design_project.surface = "artifact" |
      .product_design_project.discovered_via = "existing"
    ' "$tmp"
    # Set ds_attachment_mode when absent
    local has_dam
    has_dam="$(yq 'has("ds_attachment_mode")' "$tmp")"
    if [ "$has_dam" = "false" ]; then
      yq -i '.ds_attachment_mode = "token-by-value"' "$tmp"
    fi
  else
    # Ensure product_design_project key exists (set to null if absent)
    local has_pdp_key
    has_pdp_key="$(yq 'has("product_design_project")' "$tmp")"
    if [ "$has_pdp_key" = "false" ]; then
      yq -i '.product_design_project = null' "$tmp"
    fi
  fi

  # Append applicability-change audit entry with from/to
  _append_audit "$tmp" "applicability-change" "$actor" "from=not-applicable" "to=applicable"
}

# cmd_set_product_project — bind a product-design project to an existing record.
cmd_set_product_project() {
  local pd_reference="__UNSET__" discovered_via="" actor=""
  _parse_opts \
    --pd-reference pd_reference \
    --discovered-via discovered_via \
    --actor actor \
    -- "$@"

  if [ "$pd_reference" = "__UNSET__" ]; then
    _die "set-product-project: --pd-reference is required"
  fi
  [ -n "$pd_reference" ] || _die "set-product-project: --pd-reference must not be empty"
  [ -n "$discovered_via" ] || _die "set-product-project: --discovered-via required"
  actor="${actor:-${USER:-unknown}}"

  _assert_not_sentinel "$pd_reference" "set-product-project --pd-reference"
  _assert_discovered_via "$discovered_via" "existing created" "set-product-project"

  _preflight_mutate

  # Pre-lock check: must be applicable
  local current_app
  current_app="$(yq '.applicability' "$RECORD_PATH")"
  if [ "$current_app" = "not-applicable" ]; then
    _die "set-product-project: cannot set product project on a not-applicable record"
  fi

  _locked_mutate _do_set_product_project "$pd_reference" "$discovered_via" "$actor"
}

_do_set_product_project() {
  local tmp="$1" pd_reference="$2" discovered_via="$3" actor="$4"

  # Re-check applicability in-lock
  local app
  app="$(yq '.applicability' "$tmp")"
  if [ "$app" = "not-applicable" ]; then
    _die "set-product-project: concurrent race — record became not-applicable"
  fi

  # No-overwrite: refuse when product_design_project is already non-null
  local current_pdp
  current_pdp="$(yq '.product_design_project' "$tmp")"
  if [ "$current_pdp" != "null" ]; then
    _die "set-product-project: product_design_project is already set — cannot overwrite"
  fi

  # Identical references check
  local ds_ref
  ds_ref="$(yq '.design_system_project.reference' "$tmp")"
  if [ "$pd_reference" = "$ds_ref" ]; then
    _die "set-product-project: --pd-reference is identical to design_system_project.reference (\"$ds_ref\") — they must refer to different projects"
  fi

  # Set product_design_project
  _SP_PD="$pd_reference" _SP_DV="$discovered_via" yq -i '
    .product_design_project.reference = strenv(_SP_PD) |
    .product_design_project.type = "design" |
    .product_design_project.surface = "artifact" |
    .product_design_project.discovered_via = strenv(_SP_DV)
  ' "$tmp"

  # Set ds_attachment_mode when absent; preserve existing valid value
  local has_dam
  has_dam="$(yq 'has("ds_attachment_mode")' "$tmp")"
  if [ "$has_dam" = "false" ]; then
    yq -i '.ds_attachment_mode = "token-by-value"' "$tmp"
  fi

  # Stale-on-creation: when design_state is approved/in-dev/review → stale
  local current_state
  current_state="$(yq '.design_state' "$tmp")"
  case "$current_state" in
    approved|in-dev|review)
      yq -i '.design_state = "stale"' "$tmp"
      _append_audit "$tmp" "state-transition" "$actor" "from=${current_state}" "to=stale" "discovered_via=${discovered_via}"
      ;;
    *)
      _append_audit "$tmp" "product-project-set" "$actor" "discovered_via=${discovered_via}"
      ;;
  esac
}

# cmd_check_convergence — compute convergence from summary fields only.
# This is the READ path: validates schema version but SKIPS chain
# verification.  Convergence depends only on .design_state, .iteration,
# and .approvals — never on .audit — so skipping the O(n) chain walk
# keeps this verb fast for CI quality gates that poll frequently.
cmd_check_convergence() {
  _preflight_read
  _check_convergence_at "$RECORD_PATH"
}

# cmd_verify_integrity — validate the chained digest.
cmd_verify_integrity() {
  _preflight_read
  _verify_chain "$RECORD_PATH"
  printf 'integrity: ok\n'
}

# ---------------------------------------------------------------------------
# main — dispatch verbs
# ---------------------------------------------------------------------------

main() {
  local verb="${1:-}"
  [ -n "$verb" ] || _die "usage: design-record.sh <verb> [options]"
  shift

  case "$verb" in
    init)              cmd_init "$@" ;;
    show)              cmd_show "$@" ;;
    status)            cmd_status "$@" ;;
    transition)        cmd_transition "$@" ;;
    approve)           cmd_approve "$@" ;;
    add-review)        cmd_add_review "$@" ;;
    add-override)      cmd_add_override "$@" ;;
    not-applicable)       cmd_not_applicable "$@" ;;
    init-not-applicable)  cmd_init_not_applicable "$@" ;;
    reopen-applicable)    cmd_reopen_applicable "$@" ;;
    check-convergence)    cmd_check_convergence "$@" ;;
    verify-integrity)     cmd_verify_integrity "$@" ;;
    set-product-project)  cmd_set_product_project "$@" ;;
    *)
      _die "unknown verb: $verb — valid verbs: init, show, status, transition, approve, add-review, add-override, not-applicable, init-not-applicable, reopen-applicable, check-convergence, verify-integrity, set-product-project"
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
