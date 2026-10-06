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
# Runs checks for whichever keys are present — never returns early when one
# key is absent, so type and enum checks are not skipped.
_validate_project_references() {
  local file="$1"

  # Single yq pass: compute every decision inside yq so no user-editable
  # string (e.g. applicability) reaches the CSV split.  Each field is either
  # a boolean or a fixed token derived from a comparison — never a raw value.
  local _vpr_data
  _vpr_data="$(yq -o=csv -N '
    [(.applicability == "not-applicable"),
     (.schema_version == "2.0"),
     has("design_system_project"),
     has("product_design_project"),
     has("ds_attachment_mode"),
     (.design_system_project | tag == "!!null"),
     (.product_design_project | tag == "!!null")]
    | @csv
  ' "$file")"

  local is_na is_v2 has_dsp has_pdp has_dam dsp_null pdp_null
  IFS=',' read -r is_na is_v2 has_dsp has_pdp has_dam dsp_null pdp_null <<< "$_vpr_data"

  # Missing key check: v2 applicable records must have both keys
  if [ "$is_v2" = "true" ] && [ "$is_na" = "false" ]; then
    if [ "$has_dsp" = "false" ]; then
      _die "v2.0 applicable record missing design_system_project key"
    fi
    if [ "$has_pdp" = "false" ]; then
      _die "v2.0 applicable record missing product_design_project key"
    fi
  fi

  # Per-key checks: run for whichever key is present (no early return)
  if [ "$has_dsp" = "true" ]; then
    # Null design_system_project allowed only on not-applicable
    if [ "$dsp_null" = "true" ] && [ "$is_na" = "false" ]; then
      _die "design_system_project is null on an applicable record — this is not allowed"
    fi
    # Type-check non-null design_system_project
    if [ "$dsp_null" = "false" ]; then
      local dsp_type
      dsp_type="$(yq '.design_system_project.type' "$file")"
      if [ "$dsp_type" != "design-system" ]; then
        _die "design_system_project.type is \"$dsp_type\" — expected \"design-system\""
      fi
    fi
  fi

  if [ "$has_pdp" = "true" ]; then
    if [ "$pdp_null" = "false" ]; then
      local pdp_type
      pdp_type="$(yq '.product_design_project.type' "$file")"
      if [ "$pdp_type" != "design" ]; then
        _die "product_design_project.type is \"$pdp_type\" — expected \"design\""
      fi
    fi
  fi

  # Identical references check (only when both present and non-null)
  if [ "$has_dsp" = "true" ] && [ "$dsp_null" = "false" ] \
     && [ "$has_pdp" = "true" ] && [ "$pdp_null" = "false" ]; then
    local dsp_ref pdp_ref
    dsp_ref="$(yq '.design_system_project.reference' "$file")"
    pdp_ref="$(yq '.product_design_project.reference' "$file")"
    if [ "$dsp_ref" = "$pdp_ref" ]; then
      _die "design_system_project.reference and product_design_project.reference are identical (\"$dsp_ref\") — they must refer to different projects"
    fi
  fi

  # ds_attachment_mode enum check (when the key is present)
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

# _verify_chain_tail FILE COUNT PREV_DIGEST HEAD_DIGEST — shared tail checks.
_verify_chain_tail() {
  local file="$1" count="$2" prev_digest="$3" head_digest="$4"
  if [ "$prev_digest" != "$head_digest" ]; then
    printf 'design-record.sh: integrity failure — audit_head.last_digest mismatch\n' >&2
    printf 'design-record.sh: expected %s, found %s\n' "$prev_digest" "$head_digest" >&2
    exit 1
  fi
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

# _check_empty_head FILE — an empty audit array is valid only when the head agrees.
_check_empty_head() {
  local file="$1" hc hd
  hc="$(yq '.audit_head.count // 0' "$file")"
  hd="$(yq -r '.audit_head.last_digest // ""' "$file")"
  if [ "$hc" != "0" ]; then
    printf 'design-record.sh: integrity failure — audit_head.count (%s) != audit length (%s)\n' "$hc" 0 >&2
    exit 1
  fi
  if [ -n "$hd" ]; then
    printf 'design-record.sh: integrity failure — audit_head.last_digest mismatch\n' >&2
    exit 1
  fi
}

# _verify_chain_legacy FILE — per-entry fallback when Digest::SHA is unavailable.
_verify_chain_legacy() {
  local file="$1"
  local count
  count="$(yq '.audit | length' "$file")"
  [ "$count" -gt 0 ] || { _check_empty_head "$file"; return 0; }
  local head_count head_digest
  head_count="$(yq '.audit_head.count' "$file")"
  head_digest="$(yq '.audit_head.last_digest' "$file")"
  if [ "$head_count" != "$count" ]; then
    printf 'design-record.sh: integrity failure — audit_head.count (%s) != audit length (%s)\n' \
      "$head_count" "$count" >&2
    exit 1
  fi
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
  _verify_chain_tail "$file" "$count" "$prev_digest" "$head_digest"
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
  [ "$count" -gt 0 ] || { _check_empty_head "$file"; return 0; }

  # Per-module guard: fall back to per-entry path with warning
  local _mod
  for _mod in Digest::SHA JSON::PP; do
    if ! perl -M"$_mod" -e1 2>/dev/null; then
      printf 'design-record.sh: warning: perl %s unavailable — using per-entry fallback\n' "$_mod" >&2
      _verify_chain_legacy "$file"
      return $?
    fi
  done

  local head_count head_digest
  head_count="$(yq '.audit_head.count' "$file")"
  head_digest="$(yq '.audit_head.last_digest' "$file")"
  if [ "$head_count" != "$count" ]; then
    printf 'design-record.sh: integrity failure — audit_head.count (%s) != audit length (%s)\n' \
      "$head_count" "$count" >&2
    exit 1
  fi

  # Single pass: two fixed yq streams fed into one perl hashing process.
  # Data via file descriptors, never args or env (128 KB Linux arg limit).
  # Digests are read as JSON-encoded strings (-o=json -I=0) so a newline
  # inside a _digest value cannot split the stream into extra lines.
  # Each digest decode is wrapped in eval: a deeply nested structure that
  # exceeds the JSON nesting limit, or any non-string decoded value (array,
  # hash, number, boolean), is treated as a chain break at that index —
  # never allowed to make perl die for the whole stream.
  # Perl line-count check (exit 4) catches failed or malformed yq output.
  local result rc=0
  result="$(perl -MDigest::SHA=sha256_hex -MJSON::PP -e '
    my $j = JSON::PP->new->allow_nonref;
    my $n = shift; my $prev = "";
    open(my $c, "<&=3") or exit 3;
    open(my $d, "<&=4") or exit 3;
    my @c = <$c>; my @d = <$d>;
    exit 4 if @c != $n || @d != $n;
    for (my $i = 0; $i < $n; $i++) {
      chomp $c[$i];
      chomp $d[$i];
      my $v = eval { $j->decode($d[$i]) };
      $v = "" if !defined $v || ref $v;
      my $exp = sha256_hex($c[$i] . "\n" . $prev);
      if ($v ne $exp) { printf "broken\n%d\n%s\n", $i, $exp; exit 0 }
      $prev = $v; }
    printf "ok\n%s\n", $prev;
  ' "$count" \
    3< <(yq -o=json -I=0 '.audit[] | sort_keys(..) | del(._digest)' "$file" 2>/dev/null) \
    4< <(yq -o=json -I=0 '.audit[]._digest' "$file" 2>/dev/null))" || rc=$?

  case "$rc:$result" in
    0:broken*)
      # Re-read the broken entry's stored digest via the old two-step command.
      # 2 yq calls on the failure path only — byte-identical to old output.
      local idx exp ej found
      idx="$(printf '%s\n' "$result" | sed -n 2p)"
      exp="$(printf '%s\n' "$result" | sed -n 3p)"
      ej="$(yq -o=json -I=0 ".audit[$idx]" "$file")"
      found="$(printf '%s' "$ej" | yq -r '._digest')"
      printf 'design-record.sh: integrity failure — digest chain broken at audit[%d]\n' "$idx" >&2
      printf 'design-record.sh: expected %s, found %s\n' "$exp" "$found" >&2
      exit 1
      ;;
    0:ok*)
      # Fast path succeeded — fall through to shared tail checks
      _verify_chain_tail "$file" "$count" "$(printf '%s\n' "$result" | sed -n 2p)" "$head_digest"
      ;;
    *)
      # Non-zero rc (perl exit 3/4, or signal) or unrecognised output — legacy fallback.
      # This catches: failed yq producing wrong line count, etc.
      printf 'design-record.sh: warning: fast-path verification failed (rc=%s) — using per-entry fallback\n' "$rc" >&2
      _verify_chain_legacy "$file"
      ;;
  esac
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
    _rc=0  # initialise for shellcheck (SC2154); the trap body reassigns it
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

# ---------------------------------------------------------------------------
# Process-scoped roster cache — resolved at most once per process.
# ---------------------------------------------------------------------------

# Cache state: set by _ensure_roster, read by consumers directly.
_CACHED_ROSTER=""
_ROSTER_RESOLVED=0
_ROSTER_RC=0

# _ensure_roster — resolve the merged roster at most once per process.
# Stores the result in $_CACHED_ROSTER and the resolver's exit code in
# $_ROSTER_RC.  Subsequent calls return $_ROSTER_RC without re-running
# the resolver.  Callers that need the roster to succeed should test the
# return value; callers that must proceed regardless (cmd_approve) use
# `_ensure_roster || true` and inspect $_ROSTER_RC later.
_ensure_roster() {
  [ "$_ROSTER_RESOLVED" -eq 1 ] && return "$_ROSTER_RC"
  local out rc=0
  out="$(_resolve_merged_roster_impl)" || rc=$?
  if [ "$rc" -ne 0 ]; then out=""; fi
  _CACHED_ROSTER="$out"
  _ROSTER_RC=$rc
  _ROSTER_RESOLVED=1
  return "$rc"
}

# _check_symlink_ancestry DIR — refuse symlinks on the directory itself and
# each parent component up to (but not including) $_PROJECT_ROOT.
# Returns 0 when clean, 1 on refusal (with diagnostic on stderr).
_check_symlink_ancestry() {
  local dir="$1"
  local cur="$dir"
  while :; do
    # Stop at project root BEFORE testing -L, so a symlinked project root
    # is not falsely refused.
    case "$cur" in
      "${_PROJECT_ROOT}"|"${_PROJECT_ROOT}/") return 0 ;;
    esac
    if [ -L "$cur" ]; then
      local target
      target="$(readlink "$cur" 2>/dev/null || echo '(unreadable)')"
      if [ -d "$cur" ] || [ "$cur" = "$dir" ]; then
        printf 'design-record.sh: refusing symlinked roster directory %s -> %s\n' "$cur" "$target" >&2
      else
        printf 'design-record.sh: refusing symlinked roster path component %s -> %s\n' "$cur" "$target" >&2
      fi
      return 1
    fi
    local parent
    parent="${cur%/*}"
    [ "$parent" != "$cur" ] || return 0
    cur="$parent"
  done
}

# _resolve_merged_roster_impl — internal resolver called by _ensure_roster.
# Output: tab-separated lines: slug\tpath\ttags_csv
# Constant process count: one awk (frontmatter extraction) → one yq -N
# (slug+tags+index) → one awk (validation+dedup).  Per-file fallback on error.
# Filenames never enter the YAML stream — awk1 builds an index→path map
# and awk3 joins by index.
_resolve_merged_roster_impl() {
  local dir

  # Check symlinks on parent components (.gaia, .gaia/custom, custom)
  # unconditionally BEFORE the directory loop, so a dangling or empty-target
  # symlink never falls through to the lower-precedence directory.
  for dir in "${_PROJECT_ROOT}/.gaia" "${_PROJECT_ROOT}/.gaia/custom" "${_PROJECT_ROOT}/custom"; do
    if [ -L "$dir" ]; then
      local sl_target
      sl_target="$(readlink "$dir" 2>/dev/null || echo '(unreadable)')"
      printf 'design-record.sh: refusing symlinked roster path component %s -> %s\n' "$dir" "$sl_target" >&2
      return 1
    fi
  done

  # Collect roster directories (quoted iteration, safe with spaces in path)
  local roster_dir_list="" roster_dir_count=0
  for dir in "${_PROJECT_ROOT}/.gaia/custom/stakeholders" "${_PROJECT_ROOT}/custom/stakeholders"; do
    [ -d "$dir" ] || [ -L "$dir" ] || continue
    # Symlink check on directory itself
    _check_symlink_ancestry "$dir" || return 1
    roster_dir_list="${roster_dir_list}${dir}
"
    roster_dir_count=$((roster_dir_count + 1))
  done

  if [ "$roster_dir_count" -eq 0 ]; then
    return 0
  fi

  # Collect all .md files, check each for symlinks and tab/newline stems
  local _tab=$'\t' _nl=$'\n'
  local all_files="" file_count=0
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    for f in "$dir"/*.md; do
      [ -f "$f" ] || [ -L "$f" ] || continue
      # Symlinked file check
      if [ -L "$f" ]; then
        local target
        target="$(readlink "$f" 2>/dev/null || echo '(unreadable)')"
        printf 'design-record.sh: refusing symlinked roster file %s -> %s\n' "$f" "$target" >&2
        return 1
      fi
      # Tab/newline in stem check
      local bn
      bn="${f##*/}"
      local stem="${bn%.md}"
      case "$stem" in
        *"$_tab"*|*"$_nl"*)
          printf 'design-record.sh: refusing stem with tab/newline: %s\n' "$bn" >&2
          continue
          ;;
      esac
      all_files="${all_files}${f}
"
      file_count=$((file_count + 1))
    done
  done <<< "$roster_dir_list"

  if [ "$file_count" -eq 0 ]; then
    return 0
  fi

  # --- Constant-process-count pipeline ---
  # awk1: extract frontmatter, inject _gaia_rix (index) as the LAST line.
  # Filenames never enter the YAML stream — awk emits index→path map
  # lines prefixed with #GAIAMAP: on stdout (split out in bash afterwards
  # — no tempfile, no signal-leak).
  # Files with no opening --- or no closing --- are skipped with a warning.
  # If any frontmatter line contains the reserved map prefix #GAIAMAP:
  # (checked via index(), not anchored, to catch NUL/byte-prefixed lines),
  # awk1 sets needs_fallback=1 so the caller forces the safe per-file path
  # (which reads the true YAML without the index-map protocol).
  # User-authored _gaia_rix keys are NOT stripped: yq resolves duplicate
  # keys last-wins, and the injected index is always the last key in the
  # document, so any user-authored _gaia_rix is harmlessly overwritten.
  local awk1_raw
  awk1_raw="$(printf '%s' "$all_files" | awk '
BEGIN { idx = 0; needs_fallback = 0 }
{
  file = $0; if (file == "") next
  in_fm = 0; doc_started = 0; fm = ""; got_close = 0
  while ((getline line < file) > 0) {
    if (!doc_started) { if (line == "---") { doc_started = 1; in_fm = 1; continue } else break }
    if (in_fm) { if (line == "---") { got_close = 1; in_fm = 0; break } }
    if (in_fm) {
      if (index(line, "#GAIAMAP:") > 0) { needs_fallback = 1 }
      fm = fm line "\n" } }
  close(file)
  if (!doc_started) { bn = file; sub(/.*\//, "", bn); printf "design-record.sh: warning: no frontmatter in %s — skipped\n", bn > "/dev/stderr"; next }
  if (!got_close) { bn = file; sub(/.*\//, "", bn); printf "design-record.sh: warning: unclosed frontmatter in %s — skipped\n", bn > "/dev/stderr"; next }
  printf "---\n%s_gaia_rix: %d\n", fm, idx
  printf "#GAIAMAP:%d\t%s\n", idx, file
  idx++
}
END { if (needs_fallback) printf "#GAIA_NEEDS_FALLBACK\n" }
  ')" || true

  # If awk1 detected a frontmatter line matching the reserved map prefix
  # (#GAIAMAP:), it appends a sentinel.  Force the safe per-file fallback,
  # which reads the true YAML for each file individually.
  case "$awk1_raw" in
    *"#GAIA_NEEDS_FALLBACK"*)
      _resolve_merged_roster_perfile "$all_files"
      return $?
      ;;
  esac

  if [ -z "$awk1_raw" ]; then
    return 0
  fi

  # Split awk1 output: YAML documents (combined_fm) and map lines (file_map).
  local combined_fm file_map
  combined_fm="$(printf '%s\n' "$awk1_raw" | grep -v '^#GAIAMAP:')" || true
  file_map="$(printf '%s\n' "$awk1_raw" | sed -n 's/^#GAIAMAP://p')"

  if [ -z "$combined_fm" ]; then
    return 0
  fi

  # yq: extract slug, tags and index from each document.
  # (.slug // "") with spaces around // to avoid yq v4.53.2 null bug.
  # [.tags[]?] iterates only list-valued tags; scalar tags are ignored.
  # tostring on slug guards against numeric/boolean slugs (yq returns !!int).
  # sub() strips tab/newline/CR from slug and from each tag individually
  # BEFORE join — so an escaped control character in a tag value cannot
  # inject fake roster rows or split a slug across tab-delimited fields.
  # Note: a literal comma inside a tag (e.g. "design,x") is NOT stripped;
  # _roster_tag_is_required uses comma-padded substring matching and would
  # still match "design" inside such a tag.  This is acceptable because
  # stakeholder files are project-owned, not user-supplied attack surface.
  local yq_out rc_yq=0
  yq_out="$(printf '%s\n' "$combined_fm" | yq -N \
    '((.slug // "" | tostring) | sub("\t","") | sub("\n","") | sub("\r","")) + "\t" + ([.tags[]? | (. | tostring | sub("\t","") | sub("\n","") | sub("\r",""))] | join(",")) + "\t" + (._gaia_rix | tostring)' \
    2>/dev/null)" || rc_yq=$?
  if [ "$rc_yq" -ne 0 ]; then
    _resolve_merged_roster_perfile "$all_files"
    return $?
  fi

  # awk3: join index→path map, validate indices (exactly once, numeric),
  # enforce slug==stem, dedup.  Exits 2 on index anomaly to trigger fallback.
  local awk3_out rc_awk3=0
  awk3_out="$(printf '%s\n' "$file_map" "$yq_out" | awk -F'\t' '
NF == 2 && $1 ~ /^[0-9]+$/ { if ($1 in fmap) { fallback = 1; exit }; fmap[$1] = $2; next }
NF < 3 { next }
{
  slug = $1; tags_csv = $2; rix = $3
  if (rix !~ /^[0-9]+$/) { fallback = 1; exit }
  if (rix in rix_seen) { fallback = 1; exit }
  rix_seen[rix] = 1
  if (!(rix in fmap)) { fallback = 1; exit }
  file_path = fmap[rix]
  stem = file_path; sub(/.*\//, "", stem); sub(/\.md$/, "", stem)
  if (slug == "" || slug == "null") { slug = stem }
  else if (slug != stem) { printf "design-record.sh: warning: %s: slug \x27%s\x27 disagrees with filename \x27%s\x27 — skipped\n", stem ".md", slug, stem > "/dev/stderr"; next }
  if (slug in seen) next
  seen[slug] = 1
  print slug "\t" file_path "\t" tags_csv
}
END { if (fallback) exit 2 }
  ')" || rc_awk3=$?

  if [ "$rc_awk3" -eq 2 ]; then
    _resolve_merged_roster_perfile "$all_files"
    return $?
  fi
  if [ -n "$awk3_out" ]; then
    printf '%s\n' "$awk3_out"
  fi
  return "$rc_awk3"
}

# _resolve_merged_roster_perfile — per-file fallback when combined yq fails.
# Accepts the newline-separated file list as $1 (from the caller's all_files).
# Extracts frontmatter via awk (content between opening --- and closing ---),
# then lets yq decide whether it contains multiple documents (NEL, LS, PS,
# CR-based separators, or real --- / ... markers).  NUL bytes are handled
# differently by awk implementations: macOS (BSD) awk drops the rest of a
# line after a NUL, so yq never sees it; gawk and mawk pass it through.
# Files with any
# document index > 0 are refused as malformed.  Reads slug and tags from
# the first document only (select(di == 0)).
# Applies the same tab/newline/CR stripping as the fast path.
# Drops bad files with diagnostic, then deduplicates through a final awk pass.
_resolve_merged_roster_perfile() {
  local all_files_arg="$1"
  local raw=""
  local f fm_block

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    local bn="${f##*/}"
    local stem="${bn%.md}"

    # Extract frontmatter only via awk (identical logic to awk1).
    # Reads the file via getline in BEGIN, with /dev/null as main input
    # to avoid double-reading.  ENVIRON["file"] is used instead of
    # -v file=... so that backslash-bearing paths are passed verbatim.
    # No regex document-marker check: yq decides what constitutes a
    # second document (covers NEL, LS, PS, and mid-line CR cases that a
    # regex cannot reliably detect).  NUL bytes behave differently across
    # awk implementations: macOS (BSD) awk drops the rest of a line after
    # a NUL, so yq never sees it; gawk and mawk pass NUL through.
    export file="$f"
    fm_block="$(awk 'BEGIN { file=ENVIRON["file"]; in_fm=0; ds=0; fm=""; gc=0; while ((getline line < file) > 0) { if (!ds) { if (line == "---") { ds=1; in_fm=1; continue } else break }; if (in_fm) { if (line == "---") { gc=1; in_fm=0; break } }; if (in_fm) { fm = fm line "\n" } }; close(file); if (!ds || !gc) exit 1; printf "%s", fm }' /dev/null 2>/dev/null)" || { printf 'design-record.sh: warning: malformed frontmatter in %s — skipped\n' "$bn" >&2; continue; }
    unset file

    # Empty frontmatter is valid: slug falls back to the filename, no tags.
    # Do not refuse it — the fast path accepts it the same way.

    # Wrap as a single YAML document for yq.
    # Use -- to prevent the leading '---' from being parsed as a printf flag.
    # No trailing ... — yq rejects comment-only content followed by ...
    # ("did not find expected node content"), and the absence of a trailing
    # --- means no spurious second document appears.
    fm_block="$(printf -- '---\n%s\n' "$fm_block")"

    # Refuse multi-document frontmatter: count the documents yq sees.
    # If there is more than one, the frontmatter contains a second
    # document (via NEL, LS, PS, CR-based marker, or a real --- / ...
    # separator that awk did not catch).  NUL bytes may or may not reach
    # yq depending on the awk implementation (see comment above).
    # yq decides what constitutes a document boundary — no regex guessing.
    local _doc_count
    _doc_count="$(printf '%s\n' "$fm_block" | yq -N 'di' 2>/dev/null | wc -l)" || _doc_count=0
    _doc_count="${_doc_count##* }"  # strip leading spaces (macOS wc)
    if [ "$_doc_count" -gt 1 ] 2>/dev/null; then
      printf 'design-record.sh: warning: malformed frontmatter in %s — skipped\n' "$bn" >&2
      continue
    fi

    # Parse with yq — first document only (select(di == 0)).
    # Frontmatter only, so bodies never reach yq.
    # Apply the same tab/newline/CR stripping as the fast path for both
    # slug and tags to prevent injection via control characters.
    local slug_field tags_csv
    slug_field="$(printf '%s\n' "$fm_block" | yq -N 'select(di == 0) | ((.slug // "" | tostring) | sub("\t","") | sub("\n","") | sub("\r",""))' 2>/dev/null)" \
      || { printf 'design-record.sh: warning: malformed frontmatter in %s — skipped\n' "$bn" >&2; continue; }
    if [ "$slug_field" = "null" ]; then slug_field=""; fi

    if [ -n "$slug_field" ] && [ "$slug_field" != "$stem" ]; then
      printf 'design-record.sh: warning: %s: slug '\''%s'\'' disagrees with filename '\''%s'\'' — skipped\n' \
        "$bn" "$slug_field" "$stem" >&2
      continue
    fi
    [ -n "$slug_field" ] || slug_field="$stem"

    tags_csv="$(printf '%s\n' "$fm_block" | yq -N 'select(di == 0) | ([.tags[]? | (. | tostring | sub("\t","") | sub("\n","") | sub("\r",""))] | join(","))' 2>/dev/null)" || tags_csv=""

    raw="${raw}${slug_field}	${f}	${tags_csv}
"
  done <<< "$all_files_arg"

  # Final dedup pass
  if [ -n "$raw" ]; then
    printf '%s' "$raw" | awk -F'\t' '
{ slug = $1; if (slug in seen) next; seen[slug] = 1; print }
    '
  fi
}

# _roster_tag_is_required TAG_CSV — true when tags include design or ux.
# Fork-free: uses case-pattern matching instead of tr/printf subshells.
_roster_tag_is_required() {
  local tags_csv="$1"
  # Prepend and append comma for boundary matching
  local padded=",${tags_csv},"
  # Case-insensitive match via case pattern (no fork)
  case "$padded" in
    *,[Dd][Ee][Ss][Ii][Gg][Nn],*) return 0 ;;
    *,[Uu][Xx],*)                 return 0 ;;
  esac
  return 1
}

# _get_required_stakeholders — output one slug per line for design/ux-tagged stakeholders.
# Reads $_CACHED_ROSTER directly (caller must call _ensure_roster first).
_get_required_stakeholders() {
  _ensure_roster || return 1
  [ -n "$_CACHED_ROSTER" ] || return 0
  local slug _path tags_csv
  while IFS='	' read -r slug _path tags_csv; do
    [ -n "$slug" ] || continue
    if _roster_tag_is_required "$tags_csv"; then
      printf '%s\n' "$slug"
    fi
  done <<< "$_CACHED_ROSTER"
}

# _assert_known_stakeholder STAKEHOLDER — reject stakeholders not on the roster.
# Reads $_CACHED_ROSTER directly (caller must call _ensure_roster first).
# Returns 1 when the roster is empty (fail closed) or the slug is not found.
_assert_known_stakeholder() {
  local stakeholder="$1"
  _ensure_roster || return 1
  if [ -z "$_CACHED_ROSTER" ]; then
    if _roster_dir_exists; then
      printf 'design-record.sh: warning: vacuous roster — no design/ux-tagged stakeholders\n' >&2
    else
      printf 'design-record.sh: warning: vacuous roster — no stakeholder directory found\n' >&2
    fi
    return 1
  fi
  # Literal slug match via awk -v (not grep regex) to prevent injection
  printf '%s\n' "$_CACHED_ROSTER" | awk -F'	' -v slug="$stakeholder" '$1 == slug { found=1; exit } END { exit !found }'
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

  # If the roster resolver failed (e.g. symlink refusal), fail closed.
  # The diagnostic was already printed by the resolver.
  if [ "$_ROSTER_RC" -ne 0 ]; then
    return 1
  fi

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
  local reference="" ds_reference="__UNSET__" pd_reference="__UNSET__" pd_discovered_via="__UNSET__" discovered_via="" questionnaire_record="__UNSET__" actor="" sync_mode="__UNSET__"
  _parse_opts \
    --reference reference \
    --ds-reference ds_reference \
    --pd-reference pd_reference \
    --pd-discovered-via pd_discovered_via \
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
  if [ "$pd_discovered_via" != "__UNSET__" ]; then
    _assert_discovered_via "$pd_discovered_via" "existing created" "init --pd-discovered-via"
  else
    pd_discovered_via="existing"
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
  _rc=0  # initialise for shellcheck (SC2154); the trap body reassigns it
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
    _CI_PD="$pd_reference" _CI_PDDV="$pd_discovered_via" yq -i '
      .product_design_project.reference = strenv(_CI_PD) |
      .product_design_project.type = "design" |
      .product_design_project.surface = "artifact" |
      .product_design_project.discovered_via = strenv(_CI_PDDV)
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

  # Resolve roster only for the review→approved edge (the only edge
  # gated by convergence).
  if [ "$to" = "approved" ]; then
    _ensure_roster || true
  fi

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
  _ensure_roster || true

  # Check roster before locking — reject unknown stakeholders early.
  # Distinguish two refusal reasons: roster resolution itself failed
  # (e.g. symlink) vs. the stakeholder is simply not on a valid roster.
  if ! _assert_known_stakeholder "$stakeholder"; then
    if [ "$_ROSTER_RC" -ne 0 ]; then
      _locked_mutate _do_refuse_approval_resolution "$stakeholder" "$recorded_by"
    else
      _locked_mutate _do_refuse_approval "$stakeholder" "$recorded_by"
    fi
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

_do_refuse_approval_resolution() {
  local tmp="$1" stakeholder="$2" recorded_by="$3"
  printf 'design-record.sh: roster resolution refused — cannot verify stakeholder "%s"\n' "$stakeholder" >&2
  _append_audit "$tmp" "approval-refused" "$recorded_by" \
    "stakeholder_id=${stakeholder}" "reason=roster resolution refused"
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
  _rc=0  # initialise for shellcheck (SC2154); the trap body reassigns it
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
  local reference="" ds_reference="__UNSET__" pd_reference="__UNSET__" pd_discovered_via="__UNSET__" discovered_via="" questionnaire_record="__UNSET__" actor="" sync_mode="__UNSET__"
  _parse_opts \
    --reference reference \
    --ds-reference ds_reference \
    --pd-reference pd_reference \
    --pd-discovered-via pd_discovered_via \
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
  if [ "$pd_discovered_via" != "__UNSET__" ]; then
    _assert_discovered_via "$pd_discovered_via" "existing created" "reopen-applicable --pd-discovered-via"
  else
    pd_discovered_via="existing"
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

  _locked_mutate _do_reopen_applicable "$reference" "$discovered_via" "$questionnaire_record" "$actor" "$pd_reference" "$sync_mode" "$pd_discovered_via"
}

_do_reopen_applicable() {
  local tmp="$1" reference="$2" discovered_via="$3" questionnaire_record="$4" actor="$5" pd_reference="${6:-__UNSET__}" sync_mode="${7:-__UNSET__}" pd_discovered_via="${8:-existing}"

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
      _die "reopen-applicable: product_design_project is already set — the existing reference is preserved; omit --pd-reference to keep it"
    fi
    _RA_PD="$pd_reference" _RA_PDDV="$pd_discovered_via" yq -i '
      .product_design_project.reference = strenv(_RA_PD) |
      .product_design_project.type = "design" |
      .product_design_project.surface = "artifact" |
      .product_design_project.discovered_via = strenv(_RA_PDDV)
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
  _ensure_roster || true
  _check_convergence_at "$RECORD_PATH"
}

# cmd_verify_integrity — validate the chained digest.
cmd_verify_integrity() {
  _preflight_read
  _verify_chain "$RECORD_PATH"
  printf 'integrity: ok\n'
}

# cmd_record_review_coverage — record which projects the review covered.
cmd_record_review_coverage() {
  local coverage=""
  _parse_opts --coverage coverage -- "$@"
  [ -n "$coverage" ] || _die "record-review-coverage: --coverage is required"

  # Split comma-separated values, deduplicate, sort
  local -a raw_values=()
  local IFS=','
  local val
  local _had_noglob=false
  case "$-" in *f*) _had_noglob=true ;; esac
  set -f  # disable glob expansion during the split
  for val in $coverage; do
    raw_values+=("$val")
  done
  if [ "$_had_noglob" = false ]; then
    set +f
  fi
  unset IFS

  # Deduplicate and sort
  local -a values=()
  local seen_ds=false seen_pd=false
  local v
  for v in ${raw_values[@]+"${raw_values[@]}"}; do
    case "$v" in
      design-system)
        if [ "$seen_ds" = false ]; then
          values+=("design-system")
          seen_ds=true
        fi
        ;;
      product-design)
        if [ "$seen_pd" = false ]; then
          values+=("product-design")
          seen_pd=true
        fi
        ;;
      *)
        _die "record-review-coverage: unknown coverage value: $v — valid values: design-system, product-design"
        ;;
    esac
  done

  # Sort: design-system always comes before product-design
  local sorted=""
  if [ "$seen_ds" = true ] && [ "$seen_pd" = true ]; then
    sorted='["design-system","product-design"]'
  elif [ "$seen_ds" = true ]; then
    sorted='["design-system"]'
  elif [ "$seen_pd" = true ]; then
    _die "record-review-coverage: product-design requires design-system — cannot record product-design-only coverage"
  fi

  _preflight_mutate
  _locked_mutate _do_record_review_coverage "$sorted"
}

_do_record_review_coverage() {
  local tmp="$1" coverage_json="$2"

  # Write review_coverage as a YAML array
  case "$coverage_json" in
    '["design-system"]')
      yq -i '.review_coverage = ["design-system"]' "$tmp"
      ;;
    '["design-system","product-design"]')
      yq -i '.review_coverage = ["design-system","product-design"]' "$tmp"
      ;;
    *)
      _die "record-review-coverage: unexpected serialised coverage: $coverage_json"
      ;;
  esac

  # Append audit entry with the serialised coverage string
  _append_audit "$tmp" "review-coverage-recorded" "${USER:-unknown}" "coverage=${coverage_json}"
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
    set-product-project)        cmd_set_product_project "$@" ;;
    record-review-coverage)     cmd_record_review_coverage "$@" ;;
    *)
      _die "unknown verb: $verb — valid verbs: init, show, status, transition, approve, add-review, add-override, not-applicable, init-not-applicable, reopen-applicable, check-convergence, verify-integrity, set-product-project, record-review-coverage"
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
