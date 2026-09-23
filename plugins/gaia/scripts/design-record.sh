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
#   check-convergence  Compute convergence from summary fields
#   verify-integrity   Validate the chained digest

# ---------------------------------------------------------------------------
# Bootstrap: shared helpers
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/acquire-lock.sh
source "$SCRIPT_DIR/lib/acquire-lock.sh"

_PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-.}}}"
RECORD_PATH="${_PROJECT_ROOT}/.gaia/state/design-record.yaml"
LOCK_PATH="${RECORD_PATH}.lock"

# 30s default: safe for production (only hit under genuine contention);
# high enough for the ln(2) fallback's retry loop under heavy concurrency.
LOCK_TIMEOUT="${GAIA_LOCK_TIMEOUT:-30}"
LOCK_FD=9

SUPPORTED_SCHEMA_VERSION="1.0"

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
  if [ "$ver" != "$SUPPORTED_SCHEMA_VERSION" ]; then
    printf 'design-record.sh: unknown schema_version "%s"\n' "$ver" >&2
    printf 'design-record.sh: supported versions: %s\n' "$SUPPORTED_SCHEMA_VERSION" >&2
    printf 'design-record.sh: update the script or migrate the record\n' >&2
    exit 1
  fi
}

# _compute_entry_digest ENTRY_JSON PREV_DIGEST — compute chained sha256.
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
    trap 'release_lock "$LOCK_FD" 2>/dev/null || true; rm -f "${_DR_TMP:-}" 2>/dev/null || true' EXIT

    # Read current record into working copy
    local tmp
    tmp=$(mktemp "${RECORD_PATH}.tmp.XXXXXX")
    _DR_TMP="$tmp"
    cp "$RECORD_PATH" "$tmp"

    # In-lock validations
    _validate_schema_version "$tmp"
    _verify_chain "$tmp"

    # Apply mutation callback
    "$callback" "$tmp" "$@"

    # Atomic publish: mv is atomic on POSIX within a single filesystem
    mv -f "$tmp" "$RECORD_PATH" || _die "atomic publish failed"
    _DR_TMP=""
  )
}

# ---------------------------------------------------------------------------
# Roster resolution
# ---------------------------------------------------------------------------

# _resolve_roster_dir — set ROSTER_DIR to the stakeholder directory.
# Prefers .gaia/custom/stakeholders/ over the legacy custom/stakeholders/ path.
_resolve_roster_dir() {
  if [ -d "${_PROJECT_ROOT}/.gaia/custom/stakeholders" ]; then
    ROSTER_DIR="${_PROJECT_ROOT}/.gaia/custom/stakeholders"
  elif [ -d "${_PROJECT_ROOT}/custom/stakeholders" ]; then
    ROSTER_DIR="${_PROJECT_ROOT}/custom/stakeholders"
  else
    ROSTER_DIR=""
  fi
}

# _get_required_stakeholders — output one slug per line for design/ux-tagged stakeholders.
_get_required_stakeholders() {
  _resolve_roster_dir
  if [ -z "$ROSTER_DIR" ] || [ ! -d "$ROSTER_DIR" ]; then
    return 0
  fi

  local f slug tags
  for f in "$ROSTER_DIR"/*.md; do
    [ -f "$f" ] || continue
    # select(di == 0): read only the first YAML document (frontmatter).
    # Without this, yq treats prose after the closing --- as a second
    # document and emits "--- null ---" for missing keys.
    tags="$(yq 'select(di == 0) | .tags[]' "$f" 2>/dev/null || true)"
    if printf '%s\n' "$tags" | grep -qE '^(design|ux)$'; then
      slug="$(yq 'select(di == 0) | .slug' "$f" 2>/dev/null || true)"
      if [ -n "$slug" ] && [ "$slug" != "null" ]; then
        printf '%s\n' "$slug"
      fi
    fi
  done
}

# _assert_known_stakeholder STAKEHOLDER — reject stakeholders not on the roster.
_assert_known_stakeholder() {
  local stakeholder="$1"
  _resolve_roster_dir
  if [ -z "$ROSTER_DIR" ]; then
    printf 'design-record.sh: warning: vacuous roster — no stakeholder directory found\n' >&2
    return 0
  fi
  [ -f "$ROSTER_DIR/${stakeholder}.md" ]
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
# Same as _preflight_read; the in-lock chain verification happens inside _locked_mutate.
_preflight_mutate() {
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
# Returns: 0 on converged/vacuous, 1 on not-converged
_check_convergence_at() {
  local file="$1"
  local iteration
  iteration="$(yq '.iteration' "$file")"

  local required_stakeholders
  required_stakeholders="$(_get_required_stakeholders)"

  _resolve_roster_dir
  if [ -z "$ROSTER_DIR" ]; then
    printf 'design-record.sh: warning: vacuous roster — no stakeholder directory found\n' >&2
    printf 'vacuous-convergence\n'
    return 0
  fi

  if [ -z "$required_stakeholders" ]; then
    printf 'design-record.sh: warning: vacuous roster — no design/ux-tagged stakeholders\n' >&2
    printf 'vacuous-convergence\n'
    return 0
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
  local reference="" discovered_via="" questionnaire_record="" actor=""
  _parse_opts \
    --reference reference \
    --discovered-via discovered_via \
    --questionnaire-record questionnaire_record \
    --actor actor \
    -- "$@"

  [ -n "$reference" ] || _die "init: --reference required"
  [ -n "$discovered_via" ] || _die "init: --discovered-via required"
  [ -n "$questionnaire_record" ] || _die "init: --questionnaire-record required"
  actor="${actor:-${USER:-unknown}}"

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
  trap 'rm -f "$tmp" 2>/dev/null || true' EXIT

  cat > "$tmp" <<'EOF'
schema_version: "1.0"
applicability: applicable
design_state: draft
iteration: 1
project:
  reference: ""
  discovered_via: ""
  questionnaire_record: ""
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
  local to="" actor=""
  _parse_opts --to to --actor actor -- "$@"

  if [ -z "$to" ]; then
    printf 'design-record.sh: transition: --to required\n' >&2
    printf 'design-record.sh: legal values: draft, review, approved, in-dev, stale\n' >&2
    exit 1
  fi
  actor="${actor:-${USER:-unknown}}"

  # Pre-lock validation: enum and transition legality checked BEFORE
  # acquiring the lock so illegal requests never block other writers.
  _assert_valid_state "$to" "transition --to"
  _preflight_mutate

  local current_state
  current_state="$(yq '.design_state' "$RECORD_PATH")"
  _assert_legal_transition "$current_state" "$to"

  _locked_mutate _do_transition "$to" "$actor"
}

_do_transition() {
  local tmp="$1" to="$2" actor="$3"

  local current_state current_iter
  current_state="$(yq '.design_state' "$tmp")"
  current_iter="$(yq '.iteration' "$tmp")"

  # For review -> approved, convergence is a gate
  if [ "$current_state" = "review" ] && [ "$to" = "approved" ]; then
    local conv_result
    conv_result="$(_check_convergence_at "$tmp" 2>/dev/null)" || \
      _die "transition review->approved blocked: ${conv_result}"
  fi

  # review -> review bumps iteration; prior approvals remain but are
  # keyed to the old iteration, so they no longer satisfy convergence.
  local new_iter="$current_iter"
  if [ "$current_state" = "review" ] && [ "$to" = "review" ]; then
    new_iter=$((current_iter + 1))
    yq -i ".iteration = $new_iter" "$tmp"
  fi

  _DT_TO="$to" yq -i '.design_state = strenv(_DT_TO)' "$tmp"
  _append_audit "$tmp" "state-transition" "$actor" "from=${current_state}" "to=${to}"
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
  local verdict="" reviewer="" actor="" kind="design-review"
  _parse_opts \
    --verdict verdict \
    --reviewer reviewer \
    --actor actor \
    --kind kind \
    -- "$@"

  [ -n "$verdict" ] || _die "add-review: --verdict required"
  [ -n "$reviewer" ] || _die "add-review: --reviewer required"
  actor="${actor:-$reviewer}"

  _preflight_mutate
  _locked_mutate _do_add_review "$verdict" "$reviewer" "$actor" "$kind"
}

_do_add_review() {
  local tmp="$1" verdict="$2" reviewer="$3" actor="$4" kind="$5"
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
  _DR_ENTRY="$entry" yq -i '.reviews += [env(_DR_ENTRY)]' "$tmp"
  _append_audit "$tmp" "review-verdict" "$actor" "verdict=${verdict}" "kind=${kind}"
}

# cmd_add_override — record an audited override.
cmd_add_override() {
  local actor="" reason="" entry_point=""
  _parse_opts --actor actor --reason reason --entry-point entry_point -- "$@"

  [ -n "$actor" ] || _die "add-override: --actor required"
  [ -n "$reason" ] || _die "add-override: --reason required"
  [ -n "$entry_point" ] || _die "add-override: --entry-point required"

  _preflight_mutate
  _locked_mutate _do_add_override "$actor" "$reason" "$entry_point"
}

_do_add_override() {
  local tmp="$1" actor="$2" reason="$3" entry_point="$4"
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
  _DO_ENTRY="$entry" yq -i '.overrides += [env(_DO_ENTRY)]' "$tmp"
  _append_audit "$tmp" "override" "$actor" "reason=${reason}" "entry_point=${entry_point}"
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
    not-applicable)    cmd_not_applicable "$@" ;;
    check-convergence) cmd_check_convergence "$@" ;;
    verify-integrity)  cmd_verify_integrity "$@" ;;
    *)
      _die "unknown verb: $verb — valid verbs: init, show, status, transition, approve, add-review, add-override, not-applicable, check-convergence, verify-integrity"
      ;;
  esac
}

main "$@"
