#!/usr/bin/env bats
# design-record.bats — sole-writer, state machine, audit trail, convergence.
#
# Public functions covered: main, cmd_init, cmd_show, cmd_status,
# cmd_transition, cmd_approve, cmd_add_review, cmd_add_override,
# cmd_not_applicable, cmd_check_convergence, cmd_verify_integrity,
# validate_record.

load 'test_helper.bash'

# fail MSG — abort the current test with a diagnostic message.
# Not a bats built-in; we define it here.
fail() { printf '%s\n' "$1" >&2; return 1; }

# ---------------------------------------------------------------------------
# Portable helpers — work on both macOS and Linux
# ---------------------------------------------------------------------------

_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

_sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

_file_inode() {
  if stat --version >/dev/null 2>&1; then
    stat -c '%i' "$1"
  else
    stat -f '%i' "$1"
  fi
}

_file_mtime() {
  if stat --version >/dev/null 2>&1; then
    stat -c '%Y' "$1"
  else
    stat -f '%m' "$1"
  fi
}

_file_size() {
  if stat --version >/dev/null 2>&1; then
    stat -c '%s' "$1"
  else
    stat -f '%z' "$1"
  fi
}

# assert_record_unchanged FILE SHA INODE MTIME SIZE
# Prove no I/O occurred: sha256, inode, mtime, size all identical.
assert_record_unchanged() {
  local file="$1" pre_sha="$2" pre_inode="$3" pre_mtime="$4" pre_size="$5"
  local post_sha post_inode post_mtime post_size
  post_sha="$(_sha256_file "$file")"
  post_inode="$(_file_inode "$file")"
  post_mtime="$(_file_mtime "$file")"
  post_size="$(_file_size "$file")"
  [ "$pre_sha" = "$post_sha" ] || {
    printf 'sha256 changed: %s -> %s\n' "$pre_sha" "$post_sha" >&2; return 1; }
  [ "$pre_inode" = "$post_inode" ] || {
    printf 'inode changed: %s -> %s\n' "$pre_inode" "$post_inode" >&2; return 1; }
  [ "$pre_mtime" = "$post_mtime" ] || {
    printf 'mtime changed: %s -> %s\n' "$pre_mtime" "$post_mtime" >&2; return 1; }
  [ "$pre_size" = "$post_size" ] || {
    printf 'size changed: %s -> %s\n' "$pre_size" "$post_size" >&2; return 1; }
}

# assert_no_lock_or_tmp DIR BASENAME
# Prove no lock or tmpfile sibling was created.
assert_no_lock_or_tmp() {
  local dir="$1" base="$2"
  local found
  found="$(ls -1 "$dir" 2>/dev/null | grep -E "^${base}\.(lock|tmp\.)" || true)"
  [ -z "$found" ] || {
    printf 'unexpected lock/tmp siblings: %s\n' "$found" >&2; return 1; }
}

# capture_record_state FILE — sets PRE_SHA, PRE_INODE, PRE_MTIME, PRE_SIZE
capture_record_state() {
  PRE_SHA="$(_sha256_file "$1")"
  PRE_INODE="$(_file_inode "$1")"
  PRE_MTIME="$(_file_mtime "$1")"
  PRE_SIZE="$(_file_size "$1")"
}

# assert_script_exists — guard used by every test that invokes the writer.
assert_script_exists() {
  [ -x "$SCRIPT" ] || fail "design-record.sh does not exist or is not executable"
}

# make_barrier — create a named fifo; sets BARRIER.
make_barrier() {
  BARRIER="$(mktemp -u "$TEST_TMP/barrier.XXXXXX")"
  mkfifo "$BARRIER"
}

# release_barrier N — unblock N waiters simultaneously.
release_barrier() {
  local n="$1" i
  for i in $(seq 1 "$n"); do echo go; done > "$BARRIER"
}

# _extract_fn_body FUNCNAME FILE — extract a shell function body from FILE.
# Captures from the `funcname() {` header to the matching `^}$` closing brace.
# Fails loudly if the body is empty, preventing silently vacuous static tests.
_extract_fn_body() {
  local funcname="$1" file="$2"
  local body
  body="$(awk "/^${funcname}\\(\\)/{p=1} p{print} p && /^}\$/{exit}" "$file" 2>/dev/null)"
  [ -n "$body" ] || fail "_extract_fn_body: function '$funcname' not found or empty in $file"
  printf '%s' "$body"
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# seed_roster_gaia — create .gaia/custom/stakeholders/ with tagged files
seed_roster_gaia() {
  local roster_dir="$TEST_TMP/.gaia/custom/stakeholders"
  mkdir -p "$roster_dir"
  cat > "$roster_dir/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design, ux]
---
STAKE
  cat > "$roster_dir/stakeholder-B.md" <<'STAKE'
---
name: "Stakeholder B"
slug: stakeholder-B
tags: [ux]
---
STAKE
}

# seed_roster_legacy — create custom/stakeholders/ (legacy path)
seed_roster_legacy() {
  local roster_dir="$TEST_TMP/custom/stakeholders"
  mkdir -p "$roster_dir"
  cat > "$roster_dir/stakeholder-L1.md" <<'STAKE'
---
name: "Legacy Stakeholder L1"
slug: stakeholder-L1
tags: [design]
---
STAKE
}

# seed_minimal_record STATE ITERATION — write a minimal valid record
seed_minimal_record() {
  local state="${1:-draft}" iteration="${2:-1}"
  mkdir -p "$STATE_DIR"
  cat > "$RECORD" <<EOF
schema_version: "1.0"
applicability: applicable
design_state: "$state"
iteration: $iteration
project:
  reference: "test-project-ref"
  discovered_via: "created"
  questionnaire_record: ".gaia/artifacts/planning-artifacts/ux-design/design-questionnaire.md"
reviews: []
approvals: []
overrides: []
audit: []
audit_head:
  count: 0
  last_digest: ""
EOF
}

# seed_review_with_roster — seed a review-state record with the gaia roster.
# Most mutation tests start from this combination.
seed_review_with_roster() {
  seed_minimal_record "review" 1
  seed_roster_gaia
}

# seed_record_with_audit STATE ITERATION N_ENTRIES — record with N audit entries
seed_record_with_audit() {
  local state="${1:-draft}" iteration="${2:-1}" n_entries="${3:-3}"
  seed_minimal_record "$state" "$iteration"
  local audit_yaml="" i
  for i in $(seq 1 "$n_entries"); do
    audit_yaml="${audit_yaml}
  - at: \"2026-01-0${i}T00:00:00Z\"
    actor: \"test-actor\"
    event: \"state-transition\"
    from: \"draft\"
    to: \"review\"
    design_state: \"review\"
    iteration: $iteration
    _digest: \"placeholder-digest-$i\""
  done
  yq -i ".audit = [${audit_yaml}]" "$RECORD"
  yq -i ".audit_head.count = $n_entries" "$RECORD"
  yq -i ".audit_head.last_digest = \"placeholder-digest-$n_entries\"" "$RECORD"
}

# seed_frontmatter_story — create a story file with a design-state frontmatter
seed_frontmatter_story() {
  local frontmatter_state="${1:-approved}"
  mkdir -p "$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  cat > "$TEST_TMP/.gaia/artifacts/implementation-artifacts/test-story.md" <<EOF
---
template: 'story'
key: "TEST-1"
title: "Test story"
status: in-progress
design_state: "$frontmatter_state"
---

# Story: Test story
EOF
}

# seed_frontmatter_ux — create a UX doc with a design-state frontmatter
seed_frontmatter_ux() {
  local frontmatter_state="${1:-approved}"
  mkdir -p "$TEST_TMP/.gaia/artifacts/planning-artifacts/ux-design"
  cat > "$TEST_TMP/.gaia/artifacts/planning-artifacts/ux-design/ux-design.md" <<EOF
---
template: 'ux-design'
design_state: "$frontmatter_state"
---

# UX Design
EOF
}

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/design-record.sh"
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCHEMA="$PLUGIN_ROOT/schemas/design-record.schema.json"
  ALLOWLIST="$BATS_TEST_DIRNAME/fixtures/design-record-mention-allowlist.txt"

  # Run with all path vars unset so tests prove correct resolution
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT PROJECT_PATH CLAUDE_PLUGIN_ROOT 2>/dev/null || true
  export PROJECT_ROOT="$TEST_TMP"

  STATE_DIR="$TEST_TMP/.gaia/state"
  mkdir -p "$STATE_DIR"
  RECORD="$STATE_DIR/design-record.yaml"

  command -v yq >/dev/null 2>&1 || fail "yq is required but not found on PATH"
}

teardown() { common_teardown; }


# =========================================================================
# (AC1) schema conformance and round-trip fidelity
# =========================================================================

@test "(AC1) init creates a schema-conformant record and all readers agree" {
  assert_script_exists

  run "$SCRIPT" init \
    --reference "test-ref" \
    --discovered-via "created" \
    --questionnaire-record ".gaia/artifacts/planning-artifacts/ux-design/dq.md"
  [ "$status" -eq 0 ] || fail "init failed: $output"
  [ -f "$RECORD" ] || fail "init did not create $RECORD"

  # Schema validation via shared helper (exit 3 = FAIL, not skip)
  [ -f "$SCHEMA" ] || fail "design-record.schema.json does not exist"
  source "$SCRIPTS_DIR/lib/validate-artifact-schema.sh"
  run validate_artifact_schema "$SCHEMA" "$RECORD"
  [ "$status" -ne 3 ] || fail "schema validation backend absent — cannot skip"
  [ "$status" -eq 0 ] || fail "schema validation failed: $output"

  # Three-reader round-trip: show, raw yq, status must agree
  run "$SCRIPT" show
  [ "$status" -eq 0 ] || fail "show failed: $output"
  local show_output="$output"

  run "$SCRIPT" status
  [ "$status" -eq 0 ] || fail "status failed: $output"
  local status_output="$output"

  local yq_state yq_iter yq_schema
  yq_state="$(yq '.design_state' "$RECORD")"
  yq_iter="$(yq '.iteration' "$RECORD")"
  yq_schema="$(yq '.schema_version' "$RECORD")"

  [[ "$show_output" == *"$yq_state"* ]] || fail "show output missing design_state '$yq_state'"
  [[ "$show_output" == *"$yq_schema"* ]] || fail "show output missing schema_version '$yq_schema'"
  [[ "$status_output" == *"$yq_state"* ]] || fail "status output missing design_state '$yq_state'"

  # Verify all required top-level keys present
  for key in schema_version applicability design_state iteration project reviews approvals overrides audit audit_head; do
    yq -e ".$key" "$RECORD" >/dev/null 2>&1 || fail "missing key: $key"
  done
}

@test "(AC1) round-trip mutant: normalized timestamp is detected" {
  assert_script_exists

  run "$SCRIPT" init \
    --reference "test-ref" \
    --discovered-via "created" \
    --questionnaire-record ".gaia/artifacts/planning-artifacts/ux-design/dq.md"
  [ "$status" -eq 0 ] || fail "init failed: $output"

  local raw_ts
  raw_ts="$(yq '.audit[0].at' "$RECORD")"
  [ -n "$raw_ts" ] || fail "audit[0].at is empty after init"

  local stripped
  stripped="$(printf '%s' "$raw_ts" | sed 's/[+-][0-9][0-9]:[0-9][0-9]$//' | sed 's/Z$//')"
  [ "$raw_ts" != "$stripped" ] || fail "timestamp has no timezone info — round-trip mutant is vacuous"
}


@test "(AC1) round-trip injection: special characters survive all mutation verbs" {
  # Proves that values containing double quotes, single quotes, backslashes,
  # dollar signs, backticks, newlines, unicode, and yq-injection payloads
  # round-trip identically through every mutation verb.
  assert_script_exists
  seed_review_with_roster

  # Payload containing every dangerous character class
  local payload='He said "ship it" & she said '\''yes'\'' — cost \$100 `rm -rf /` foo
bar ñ日本語 .design_state = "approved"'

  # 1. add-review: reviewer and notes-ref fields carry the payload
  #    (verdict is now enum-guarded, so we use a valid verdict and test
  #    special-char round-tripping via free-text fields instead)
  run "$SCRIPT" add-review \
    --verdict "approved" \
    --reviewer "$payload" \
    --actor "$payload" \
    --kind "internal" \
    --notes-ref "$payload"
  [ "$status" -eq 0 ] || fail "add-review with special chars failed: $output"

  local stored_actor stored_notes_ref
  stored_actor="$(yq '.reviews[-1].actor' "$RECORD")"
  [ "$stored_actor" = "$payload" ] || \
    fail "review actor not round-tripped: expected <<<$payload>>> got <<<$stored_actor>>>"
  stored_notes_ref="$(yq '.reviews[-1].notes_ref' "$RECORD")"
  [ "$stored_notes_ref" = "$payload" ] || \
    fail "review notes_ref not round-tripped: expected <<<$payload>>> got <<<$stored_notes_ref>>>"

  # 2. add-override: reason field carries the payload
  run "$SCRIPT" add-override \
    --actor "admin" \
    --reason "$payload" \
    --entry-point "/test"
  [ "$status" -eq 0 ] || fail "add-override with special chars failed: $output"

  local stored_reason
  stored_reason="$(yq '.overrides[-1].reason' "$RECORD")"
  [ "$stored_reason" = "$payload" ] || \
    fail "override reason not round-tripped: expected <<<$payload>>> got <<<$stored_reason>>>"

  # 3. approve: recorded_by field carries the payload
  run "$SCRIPT" approve \
    --stakeholder "stakeholder-A" \
    --recorded-by "$payload"
  [ "$status" -eq 0 ] || fail "approve with special chars failed: $output"

  local stored_recorded_by
  stored_recorded_by="$(yq '.approvals[-1].recorded_by' "$RECORD")"
  [ "$stored_recorded_by" = "$payload" ] || \
    fail "approval recorded_by not round-tripped: expected <<<$payload>>> got <<<$stored_recorded_by>>>"

  # 4. transition: actor field carries the payload (via audit trail)
  run "$SCRIPT" transition --to "review" --actor "$payload"
  [ "$status" -eq 0 ] || fail "transition with special chars failed: $output"

  local stored_actor
  stored_actor="$(yq '.audit[-1].actor' "$RECORD")"
  [ "$stored_actor" = "$payload" ] || \
    fail "audit actor not round-tripped: expected <<<$payload>>> got <<<$stored_actor>>>"

  # 5. design_state is still 'review' — the yq-injection payload in the
  #    reason/verdict did not break out and change top-level state
  local final_state
  final_state="$(yq '.design_state' "$RECORD")"
  [ "$final_state" = "review" ] || \
    fail "design_state mutated to '$final_state' — injection escaped"

  # 6. integrity still validates — chained digest is coherent
  run "$SCRIPT" verify-integrity
  [ "$status" -eq 0 ] || fail "integrity check failed after special-char writes: $output"
}

@test "(AC1) round-trip injection: init project fields survive special characters" {
  assert_script_exists

  local payload='ref with "quotes" and $dollar and `backtick`'
  run "$SCRIPT" init \
    --reference "$payload" \
    --discovered-via "$payload" \
    --questionnaire-record "$payload"
  [ "$status" -eq 0 ] || fail "init with special chars failed: $output"

  local stored_ref stored_dv stored_qr
  stored_ref="$(yq '.project.reference' "$RECORD")"
  stored_dv="$(yq '.project.discovered_via' "$RECORD")"
  stored_qr="$(yq '.project.questionnaire_record' "$RECORD")"

  [ "$stored_ref" = "$payload" ] || fail "project.reference not round-tripped"
  [ "$stored_dv" = "$payload" ] || fail "project.discovered_via not round-tripped"
  [ "$stored_qr" = "$payload" ] || fail "project.questionnaire_record not round-tripped"
}


# =========================================================================
# (AC2) sole-writer contract enforced by static sweep
# =========================================================================

@test "(AC2) mention registry: every file referencing design-record is allowlisted" {
  [ -f "$ALLOWLIST" ] || fail "mention allowlist not found at $ALLOWLIST"

  local mentions
  mentions="$(grep -rln 'design-record' "$PLUGIN_ROOT/" 2>/dev/null || true)"

  local unlisted="" rel_path
  while IFS= read -r filepath; do
    [ -n "$filepath" ] || continue
    rel_path="${filepath#"$PLUGIN_ROOT/"}"
    if ! grep -qF "$rel_path" "$ALLOWLIST"; then
      unlisted="${unlisted}${rel_path}\n"
    fi
  done <<< "$mentions"

  [ -z "$unlisted" ] || {
    printf 'Files referencing design-record not in allowlist (%s):\n' "$ALLOWLIST"
    printf '%b' "$unlisted"
    printf '\nFix: add a line to %s classifying each file as writer|reader|prose|test|schema with a reason.\n' "$ALLOWLIST"
    fail "unlisted design-record references found"
  }
}

@test "(AC2) mention registry mutant: unlisted new file is caught" {
  [ -f "$ALLOWLIST" ] || fail "mention allowlist not found at $ALLOWLIST"

  # Plant a file that references design-record but is NOT in the allowlist
  local mutant_dir="$TEST_TMP/mutant-plugin"
  cp -R "$PLUGIN_ROOT" "$mutant_dir"
  cat > "$mutant_dir/scripts/rogue-writer.sh" <<'EOF'
#!/usr/bin/env bash
yq -i '.design_state = "approved"' .gaia/state/design-record.yaml
EOF

  local mentions
  mentions="$(grep -rln 'design-record' "$mutant_dir/" 2>/dev/null || true)"

  local found_rogue=false rel_path
  while IFS= read -r filepath; do
    [ -n "$filepath" ] || continue
    rel_path="${filepath#"$mutant_dir/"}"
    if ! grep -qF "$rel_path" "$ALLOWLIST"; then
      found_rogue=true; break
    fi
  done <<< "$mentions"

  [ "$found_rogue" = true ] || fail "mutant rogue-writer.sh was not caught by the mention registry"
}

@test "(AC2) write-pattern scan: no write constructs outside the sole writer" {
  [ -f "$SCRIPTS_DIR/design-record.sh" ] || fail "design-record.sh does not exist"

  local write_patterns='(>[> ]*|yq[[:space:]]+(--inplace|-i)|sed[[:space:]]+-i|tee[[:space:]]|mv[[:space:]]|cp[[:space:]]|install[[:space:]]|truncate[[:space:]]).*design-record'
  local violations=""

  while IFS= read -r filepath; do
    [ -n "$filepath" ] || continue
    local rel_path="${filepath#"$PLUGIN_ROOT/"}"

    # Skip the sole writer and test files (which manipulate temp-dir fixtures)
    [ "$rel_path" = "scripts/design-record.sh" ] && continue
    [ "$rel_path" = "tests/design-record.bats" ] && continue
    # design-gate.bats: one printf writes corrupt YAML for the schema-invalid
    # test; one yq -i injects an unknown state for the default-fail mutant.
    # Both write to temp-dir fixtures, not production records.
    [ "$rel_path" = "tests/design-gate.bats" ] && continue

    local matches
    matches="$(grep -nE "$write_patterns" "$filepath" 2>/dev/null \
      | grep -vE '^\s*#' || true)"
    if [ -n "$matches" ]; then
      violations="${violations}${rel_path}:\n${matches}\n"
    fi
  done < <(find "$PLUGIN_ROOT" -type f \( -name '*.sh' -o -name '*.bash' -o -name '*.bats' -o -name '*.py' -o -name '*.rb' \) 2>/dev/null)

  [ -z "$violations" ] || {
    printf 'Write constructs targeting design-record outside the sole writer:\n%b\n' "$violations"
    fail "sole-writer contract violated"
  }
}

@test "(AC2) write-pattern mutant: planted yq -i is caught" {
  local mutant_dir="$TEST_TMP/mutant-plugin"
  mkdir -p "$mutant_dir/scripts"
  cat > "$mutant_dir/scripts/rogue.sh" <<'ROGUE'
#!/usr/bin/env bash
yq -i '.test = true' .gaia/state/design-record.yaml
ROGUE

  local write_patterns='(>[> ]*|yq[[:space:]]+(--inplace|-i)|sed[[:space:]]+-i|tee[[:space:]]|mv[[:space:]]|cp[[:space:]]).*design-record'
  local matches
  matches="$(grep -nE "$write_patterns" "$mutant_dir/scripts/rogue.sh" 2>/dev/null \
    | grep -vE '^\s*#' || true)"

  [ -n "$matches" ] || fail "planted yq -i write was not caught"
}


# =========================================================================
# (AC3) concurrent writers serialized with zero lost updates
# =========================================================================

@test "(AC3) N concurrent approvals produce N entries with zero lost updates" {
  assert_script_exists
  seed_review_with_roster

  local N=10
  make_barrier

  # Generous lock timeout to prevent false failures under host load:
  # 10 serialized writers at ~1-3s each can take 10-30s; 120s gives ample margin
  local i
  for i in $(seq 1 "$N"); do
    (
      read < "$BARRIER"
      GAIA_LOCK_TIMEOUT=120 GAIA_DREC_WRITE_DELAY=0.1 "$SCRIPT" approve \
        --stakeholder "stakeholder-A" \
        --recorded-by "approver-$i"
    ) &
  done

  release_barrier "$N"
  wait

  local count
  count="$(yq '.approvals | length' "$RECORD")"
  [ "$count" -eq "$N" ] || fail "expected $N approvals, got $count"

  local audit_count
  audit_count="$(yq '.audit | length' "$RECORD")"
  [ "$audit_count" -ge "$N" ] || fail "expected at least $N audit entries, got $audit_count"
}

@test "(AC3) lock timeout fails closed — record unchanged" {
  assert_script_exists
  seed_review_with_roster

  local lock_file="${RECORD}.lock"

  # Hold the lock using the same library the script uses
  (
    source "$SCRIPTS_DIR/lib/acquire-lock.sh"
    acquire_lock "$lock_file" 30 8 || exit 1
    sleep 60
  ) &
  local holder_pid=$!
  sleep 1  # Let the holder acquire

  capture_record_state "$RECORD"

  run env GAIA_LOCK_TIMEOUT=2 "$SCRIPT" approve \
    --stakeholder "stakeholder-A" --recorded-by "test"
  [ "$status" -ne 0 ] || fail "expected non-zero exit on lock timeout"
  [[ "$output" == *"lock"* ]] || [[ "$output" == *"timeout"* ]] || \
    fail "expected lock-timeout diagnostic"

  assert_record_unchanged "$RECORD" "$PRE_SHA" "$PRE_INODE" "$PRE_MTIME" "$PRE_SIZE"

  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
}

# =========================================================================
# cmd_reopen_applicable — a not-applicable record reopens for design review
# =========================================================================

@test "cmd_reopen_applicable turns a not-applicable record into a draft awaiting design" {
  assert_script_exists
  run "$SCRIPT" init-not-applicable --actor "design-gate"
  [ "$status" -eq 0 ] || fail "init-not-applicable failed: $output"
  local trail_before
  trail_before="$(yq '.audit | length' "$RECORD")"

  run "$SCRIPT" reopen-applicable --reference "design-ref-1" \
    --discovered-via created --questionnaire-record "ux/questionnaire.md" --actor "owner"
  [ "$status" -eq 0 ] || fail "reopen-applicable failed: $output"

  [ "$(yq '.applicability' "$RECORD")" = "applicable" ] || fail "applicability not reopened"
  [ "$(yq '.design_state' "$RECORD")" = "draft" ] || fail "design_state is not draft"
  [ "$(yq '.project.reference' "$RECORD")" = "design-ref-1" ] || fail "reference not recorded"
  [ "$(yq '.audit | length' "$RECORD")" -eq $(( trail_before + 1 )) ] \
    || fail "expected exactly one new audit entry"
  [ "$(yq '.audit[-1].event' "$RECORD")" = "applicability-change" ] \
    || fail "last audit entry is not an applicability change"

  run "$SCRIPT" verify-integrity
  [ "$status" -eq 0 ] || fail "audit chain broken after reopen: $output"
}

# =========================================================================
# (AC-EC1) cmd_init_not_applicable — fresh record, idempotent, integrity
# =========================================================================

@test "(AC-EC1) cmd_init_not_applicable creates a schema-valid not-applicable record" {
  assert_script_exists
  # No record on disk yet
  [ ! -f "$RECORD" ]

  run "$SCRIPT" init-not-applicable --actor "design-gate"
  [ "$status" -eq 0 ] || fail "init-not-applicable failed: $output"
  [ -f "$RECORD" ] || fail "init-not-applicable did not create $RECORD"

  # Verify required fields
  local app ds sv ref dv qr
  app="$(yq '.applicability' "$RECORD")"
  ds="$(yq '.design_state' "$RECORD")"
  sv="$(yq '.schema_version' "$RECORD")"
  ref="$(yq '.project.reference' "$RECORD")"
  dv="$(yq '.project.discovered_via' "$RECORD")"
  qr="$(yq '.project.questionnaire_record' "$RECORD")"

  [ "$app" = "not-applicable" ] || fail "applicability=$app, expected not-applicable"
  [ "$ds" = "draft" ] || fail "design_state=$ds, expected draft"
  [ "$sv" = "1.0" ] || fail "schema_version=$sv, expected 1.0"
  [ "$ref" = "not-applicable" ] || fail "project.reference=$ref"
  [ "$dv" = "project-artifacts" ] || fail "project.discovered_via=$dv"
  [ "$qr" = "not-applicable" ] || fail "project.questionnaire_record=$qr"

  # Audit entry
  local event
  event="$(yq '.audit[0].event' "$RECORD")"
  [ "$event" = "not-applicable-pass" ] || fail "audit[0].event=$event, expected not-applicable-pass"

  # Integrity chain must verify
  run "$SCRIPT" verify-integrity
  [ "$status" -eq 0 ] || fail "integrity check failed after init-not-applicable: $output"
}

@test "(AC3) torn-read immunity: reader never observes partial record" {
  assert_script_exists
  seed_review_with_roster

  # Start a slow writer in background
  GAIA_DREC_WRITE_DELAY=0.5 "$SCRIPT" approve \
    --stakeholder "stakeholder-A" --recorded-by "slow-writer" &
  local writer_pid=$!

  # Poll the record for 2 seconds, validating each snapshot
  local end_time i=0 snapshot
  end_time=$(( $(date +%s) + 2 ))
  while [ "$(date +%s)" -lt "$end_time" ]; do
    if [ -f "$RECORD" ]; then
      snapshot="$(cat "$RECORD" 2>/dev/null || true)"
      if [ -n "$snapshot" ]; then
        printf '%s' "$snapshot" | yq '.' >/dev/null 2>&1 || \
          fail "observed partial/corrupt record at poll $i"
        i=$((i + 1))
      fi
    fi
    sleep 0.01
  done

  wait "$writer_pid" 2>/dev/null || true
  [ "$i" -gt 0 ] || fail "reader never observed the record"
}


# =========================================================================
# (AC4) illegal state and transition rejected before I/O
# =========================================================================

@test "(AC4) illegal enum values rejected with record unchanged and no lock/tmp" {
  assert_script_exists
  seed_minimal_record "draft" 1

  local illegal_values=("pending" "APPROVED" "" "null" "Approved" "DRAFT")
  for val in "${illegal_values[@]}"; do
    capture_record_state "$RECORD"

    run "$SCRIPT" transition --to "$val"
    [ "$status" -ne 0 ] || fail "expected non-zero exit for illegal value '$val'"

    assert_record_unchanged "$RECORD" "$PRE_SHA" "$PRE_INODE" "$PRE_MTIME" "$PRE_SIZE"
    assert_no_lock_or_tmp "$(dirname "$RECORD")" "$(basename "$RECORD")"

    [[ "$output" == *"draft"* ]] || [[ "$output" == *"review"* ]] || \
      fail "diagnostic does not name legal values for illegal value '$val'"
  done
}

@test "(AC4) illegal transitions rejected with record unchanged and no lock/tmp" {
  assert_script_exists

  # draft -> approved (must go through review)
  seed_minimal_record "draft" 1
  capture_record_state "$RECORD"
  run "$SCRIPT" transition --to "approved"
  [ "$status" -ne 0 ] || fail "draft->approved should be illegal"
  assert_record_unchanged "$RECORD" "$PRE_SHA" "$PRE_INODE" "$PRE_MTIME" "$PRE_SIZE"
  assert_no_lock_or_tmp "$(dirname "$RECORD")" "$(basename "$RECORD")"

  # draft -> in-dev (must go through review+approved)
  seed_minimal_record "draft" 1
  capture_record_state "$RECORD"
  run "$SCRIPT" transition --to "in-dev"
  [ "$status" -ne 0 ] || fail "draft->in-dev should be illegal"
  assert_record_unchanged "$RECORD" "$PRE_SHA" "$PRE_INODE" "$PRE_MTIME" "$PRE_SIZE"
  assert_no_lock_or_tmp "$(dirname "$RECORD")" "$(basename "$RECORD")"

  # approved -> review (must go through stale first)
  seed_minimal_record "approved" 1
  capture_record_state "$RECORD"
  run "$SCRIPT" transition --to "review"
  [ "$status" -ne 0 ] || fail "approved->review should be illegal"
  assert_record_unchanged "$RECORD" "$PRE_SHA" "$PRE_INODE" "$PRE_MTIME" "$PRE_SIZE"

  # in-dev -> draft (no such edge)
  seed_minimal_record "in-dev" 1
  capture_record_state "$RECORD"
  run "$SCRIPT" transition --to "draft"
  [ "$status" -ne 0 ] || fail "in-dev->draft should be illegal"
  assert_record_unchanged "$RECORD" "$PRE_SHA" "$PRE_INODE" "$PRE_MTIME" "$PRE_SIZE"
}

@test "(AC4) legal transitions each append exactly one audit entry" {
  assert_script_exists
  seed_roster_gaia

  # draft -> review
  seed_minimal_record "draft" 1
  run "$SCRIPT" transition --to "review" --actor "test-actor"
  [ "$status" -eq 0 ] || fail "draft->review failed: $output"
  local count
  count="$(yq '.audit | length' "$RECORD")"
  [ "$count" -eq 1 ] || fail "expected 1 audit entry after draft->review, got $count"

  # Verify audit entry fields
  local entry_event entry_from entry_to entry_actor entry_at entry_ds entry_iter
  entry_event="$(yq '.audit[0].event' "$RECORD")"
  entry_from="$(yq '.audit[0].from' "$RECORD")"
  entry_to="$(yq '.audit[0].to' "$RECORD")"
  entry_actor="$(yq '.audit[0].actor' "$RECORD")"
  entry_at="$(yq '.audit[0].at' "$RECORD")"
  entry_ds="$(yq '.audit[0].design_state' "$RECORD")"
  entry_iter="$(yq '.audit[0].iteration' "$RECORD")"
  [ "$entry_event" = "state-transition" ]
  [ "$entry_from" = "draft" ]
  [ "$entry_to" = "review" ]
  [ -n "$entry_actor" ] && [ "$entry_actor" != "null" ]
  [ -n "$entry_at" ] && [ "$entry_at" != "null" ]
  [ "$entry_ds" = "review" ]
  [ "$entry_iter" -eq 1 ]

  # review -> review (iteration bump)
  local pre_iter
  pre_iter="$(yq '.iteration' "$RECORD")"
  run "$SCRIPT" transition --to "review" --actor "test-actor"
  [ "$status" -eq 0 ] || fail "review->review failed: $output"
  count="$(yq '.audit | length' "$RECORD")"
  [ "$count" -eq 2 ] || fail "expected 2 audit entries after review->review, got $count"
  local post_iter
  post_iter="$(yq '.iteration' "$RECORD")"
  [ "$post_iter" -gt "$pre_iter" ] || fail "iteration not bumped on review->review"

  # Approve all required stakeholders for convergence, then review -> approved
  run "$SCRIPT" approve --stakeholder "stakeholder-A" --recorded-by "test"
  [ "$status" -eq 0 ] || fail "approve stakeholder-A failed: $output"
  run "$SCRIPT" approve --stakeholder "stakeholder-B" --recorded-by "test"
  [ "$status" -eq 0 ] || fail "approve stakeholder-B failed: $output"

  run "$SCRIPT" transition --to "approved" --actor "test-actor"
  [ "$status" -eq 0 ] || fail "review->approved failed: $output"

  # approved -> in-dev
  run "$SCRIPT" transition --to "in-dev" --actor "test-actor"
  [ "$status" -eq 0 ] || fail "approved->in-dev failed: $output"

  # in-dev -> stale (any -> stale)
  run "$SCRIPT" transition --to "stale" --actor "test-actor"
  [ "$status" -eq 0 ] || fail "in-dev->stale failed: $output"

  # stale -> review
  run "$SCRIPT" transition --to "review" --actor "test-actor"
  [ "$status" -eq 0 ] || fail "stale->review failed: $output"

  local final_state
  final_state="$(yq '.design_state' "$RECORD")"
  [ "$final_state" = "review" ]
}

@test "(AC4) two sequential mutations in one process both succeed (subshell proof)" {
  assert_script_exists
  seed_review_with_roster

  run "$SCRIPT" transition --to "review" --actor "first"
  [ "$status" -eq 0 ] || fail "first mutation failed: $output"

  run "$SCRIPT" transition --to "review" --actor "second"
  [ "$status" -eq 0 ] || fail "second mutation failed: $output"

  local count
  count="$(yq '.audit | length' "$RECORD")"
  [ "$count" -eq 2 ] || fail "expected 2 audit entries from sequential mutations, got $count"
}


# =========================================================================
# (AC5) append-only trail with detectable truncation and convergence
# =========================================================================

@test "(AC5) writer refuses trail-shortening verb" {
  assert_script_exists
  seed_minimal_record "review" 1

  run "$SCRIPT" transition --to "review" --actor "a"
  [ "$status" -eq 0 ] || fail "transition to review failed: $output"
  run "$SCRIPT" transition --to "review" --actor "b"
  [ "$status" -eq 0 ] || fail "second transition to review failed: $output"

  local count_before
  count_before="$(yq '.audit | length' "$RECORD")"
  [ "$count_before" -ge 2 ] || fail "expected at least 2 audit entries, got $count_before"

  capture_record_state "$RECORD"

  run "$SCRIPT" audit-delete --index 0
  [ "$status" -ne 0 ] || fail "trail-shortening verb should be refused"
  assert_record_unchanged "$RECORD" "$PRE_SHA" "$PRE_INODE" "$PRE_MTIME" "$PRE_SIZE"
}

@test "(AC5) external middle truncation detected by chained digest" {
  assert_script_exists
  seed_minimal_record "draft" 1

  # Build a 5-entry trail via legitimate transitions
  local actor
  for actor in a b c; do
    run "$SCRIPT" transition --to "review" --actor "$actor"
    [ "$status" -eq 0 ] || fail "transition by $actor failed: $output"
  done
  run "$SCRIPT" transition --to "stale" --actor "d"
  [ "$status" -eq 0 ]
  run "$SCRIPT" transition --to "review" --actor "e"
  [ "$status" -eq 0 ]

  [ "$(yq '.audit | length' "$RECORD")" -eq 5 ]

  # Remove the middle entry outside the writer
  yq -i 'del(.audit[2])' "$RECORD"

  run "$SCRIPT" verify-integrity
  [ "$status" -ne 0 ] || fail "middle truncation was not detected"
  [[ "$output" == *"integrity"* ]] || [[ "$output" == *"digest"* ]] || [[ "$output" == *"chain"* ]] || \
    fail "expected integrity-failure diagnostic"
}

@test "(AC5) external tail truncation detected by audit_head mismatch" {
  assert_script_exists
  seed_minimal_record "draft" 1

  local actor
  for actor in a b c; do
    run "$SCRIPT" transition --to "review" --actor "$actor"
    [ "$status" -eq 0 ] || fail "transition by $actor failed: $output"
  done

  [ "$(yq '.audit | length' "$RECORD")" -eq 3 ]

  # Delete the LAST entry without touching audit_head
  yq -i 'del(.audit[-1])' "$RECORD"

  run "$SCRIPT" verify-integrity
  [ "$status" -ne 0 ] || fail "tail truncation was not detected"
  [[ "$output" == *"audit_head"* ]] || [[ "$output" == *"count"* ]] || [[ "$output" == *"integrity"* ]] || \
    fail "expected audit_head mismatch diagnostic"
}

@test "(AC5) iteration bump makes prior approvals stop satisfying convergence" {
  assert_script_exists
  seed_review_with_roster

  run "$SCRIPT" approve --stakeholder "stakeholder-A" --recorded-by "test"
  [ "$status" -eq 0 ]
  run "$SCRIPT" approve --stakeholder "stakeholder-B" --recorded-by "test"
  [ "$status" -eq 0 ]

  # Convergence should hold at iteration 1
  run "$SCRIPT" check-convergence
  [ "$status" -eq 0 ]
  [[ "$output" == *"converged"* ]]

  # Bump iteration — prior approvals at iter 1 don't satisfy iter 2
  run "$SCRIPT" transition --to "review" --actor "test"
  [ "$status" -eq 0 ]

  run "$SCRIPT" check-convergence
  [ "$status" -ne 0 ] || [[ "$output" == *"not-converged"* ]] || \
    fail "prior-iteration approvals still satisfy convergence after bump"

  # Prior approvals must still exist (keyed, not purged)
  local approval_count
  approval_count="$(yq '.approvals | length' "$RECORD")"
  [ "$approval_count" -eq 2 ] || fail "prior approvals were deleted — should be keyed, not purged"
}

@test "(AC5) fixed test vector: pinned digest matches expected hex" {
  command -v yq >/dev/null 2>&1 || fail "yq required"

  local entry='{"actor":"test-actor","at":"2026-01-01T00:00:00Z","design_state":"draft","event":"state-transition","from":"draft","iteration":1,"to":"review"}'
  local canonical
  canonical="$(printf '%s' "$entry" | yq -o=json -I=0 'sort_keys(..)')"

  local actual_hex
  actual_hex="$(printf '%s\n%s' "$canonical" "" | _sha256_stdin)"

  local expected_hex="d7932a54181000548d611b29a22a3a74be40b5fe005aae4b38201a29fee6f213"
  [ "$actual_hex" = "$expected_hex" ] || \
    fail "test vector mismatch: expected $expected_hex, got $actual_hex"
}

@test "(AC5) mutant: dropping iteration predicate makes convergence report converged after bump" {
  assert_script_exists
  seed_review_with_roster

  run "$SCRIPT" approve --stakeholder "stakeholder-A" --recorded-by "test"
  [ "$status" -eq 0 ]
  run "$SCRIPT" approve --stakeholder "stakeholder-B" --recorded-by "test"
  [ "$status" -eq 0 ]

  # Bump iteration
  run "$SCRIPT" transition --to "review" --actor "test"
  [ "$status" -eq 0 ]

  run "$SCRIPT" check-convergence
  [[ "$output" == *"not-converged"* ]] || [ "$status" -ne 0 ] || \
    fail "convergence reports converged after iteration bump — iteration predicate is not load-bearing"
}

@test "(AC5) static: no invalidation/lapse/expire verb and no approvals write on review->review" {
  [ -f "$SCRIPTS_DIR/design-record.sh" ] || fail "design-record.sh does not exist"

  local matches
  matches="$(grep -nE 'invalidat|lapse|expire' "$SCRIPTS_DIR/design-record.sh" 2>/dev/null || true)"
  [ -z "$matches" ] || fail "found invalidation/lapse/expire reference: $matches"

  # cmd_transition's review->review path must not write to .approvals
  local fn_body
  fn_body="$(_extract_fn_body cmd_transition "$SCRIPTS_DIR/design-record.sh")"
  local approval_writes
  approval_writes="$(printf '%s' "$fn_body" | grep -E '\.approvals' | grep -vE '^\s*#' || true)"
  [ -z "$approval_writes" ] || fail "cmd_transition writes to .approvals: $approval_writes"
}


# =========================================================================
# (AC-EC1) absent record reads as not-approved
# =========================================================================

@test "(AC-EC1) absent record: show, status, check-convergence each report absent" {
  assert_script_exists
  [ ! -f "$RECORD" ] || rm -f "$RECORD"

  local verb
  for verb in show status check-convergence; do
    run "$SCRIPT" "$verb"
    [ "$status" -ne 0 ] || fail "$verb should fail on absent record"
    [[ "$output" == *"absent"* ]] || fail "$verb should say 'absent'"
  done

  # The diagnostic must distinguish absent from present-but-not-approved
  [[ "$output" != *"not-approved"* ]] || [[ "$output" == *"absent"* ]] || \
    fail "diagnostic does not distinguish absent from present-but-not-approved"
}


# =========================================================================
# (AC-EC2) unknown schema version rejected as unreadable
# =========================================================================

@test "(AC-EC2) unknown schema version rejected before any field read" {
  assert_script_exists
  seed_minimal_record "draft" 1

  # Future version
  yq -i '.schema_version = "999.0.0"' "$RECORD"
  capture_record_state "$RECORD"

  run "$SCRIPT" show
  [ "$status" -ne 0 ] || fail "should reject unknown schema version"
  [[ "$output" == *"999.0.0"* ]] || fail "diagnostic should name the unknown version"
  [[ "$output" == *"1.0"* ]] || fail "diagnostic should name supported versions"
  assert_record_unchanged "$RECORD" "$PRE_SHA" "$PRE_INODE" "$PRE_MTIME" "$PRE_SIZE"

  # Older version
  yq -i '.schema_version = "0.9.0"' "$RECORD"
  capture_record_state "$RECORD"

  run "$SCRIPT" show
  [ "$status" -ne 0 ] || fail "should reject older schema version"
  assert_record_unchanged "$RECORD" "$PRE_SHA" "$PRE_INODE" "$PRE_MTIME" "$PRE_SIZE"
}


# =========================================================================
# (AC-EC3) tamper detection via audit integrity and static scan
# =========================================================================

@test "(AC-EC3) hand-edit tampering detected by digest chain on next invocation" {
  assert_script_exists
  seed_minimal_record "draft" 1

  run "$SCRIPT" transition --to "review" --actor "a"
  [ "$status" -eq 0 ]
  run "$SCRIPT" transition --to "review" --actor "b"
  [ "$status" -eq 0 ]

  # Tamper: change design_state outside the writer
  yq -i '.design_state = "approved"' "$RECORD"

  run "$SCRIPT" transition --to "in-dev" --actor "c"
  [ "$status" -ne 0 ] || fail "tampered record was accepted"
  [[ "$output" == *"integrity"* ]] || [[ "$output" == *"tamper"* ]] || [[ "$output" == *"digest"* ]] || \
    fail "expected tamper-detection diagnostic"
}


# =========================================================================
# (AC-EC4) concurrent heterogeneous mutations preserve both updates
# =========================================================================

@test "(AC-EC4) concurrent review + override both preserved" {
  assert_script_exists
  seed_review_with_roster
  make_barrier

  (
    read < "$BARRIER"
    GAIA_LOCK_TIMEOUT=120 GAIA_DREC_WRITE_DELAY=0.1 "$SCRIPT" add-review \
      --verdict "changes-requested" --reviewer "reviewer-A" --actor "reviewer-A"
  ) &

  (
    read < "$BARRIER"
    GAIA_LOCK_TIMEOUT=120 GAIA_DREC_WRITE_DELAY=0.1 "$SCRIPT" add-override \
      --actor "admin-B" --reason "unblocking deployment" --entry-point "/gaia-create-arch"
  ) &

  release_barrier 2
  wait

  local review_count override_count
  review_count="$(yq '.reviews | length' "$RECORD")"
  override_count="$(yq '.overrides | length' "$RECORD")"
  [ "$review_count" -ge 1 ] || fail "review entry missing (count=$review_count)"
  [ "$override_count" -ge 1 ] || fail "override entry missing (count=$override_count)"

  local audit_count
  audit_count="$(yq '.audit | length' "$RECORD")"
  [ "$audit_count" -ge 2 ] || fail "expected at least 2 audit entries, got $audit_count"
}


# =========================================================================
# (AC-EC5) fallback serialization without flock binary
# =========================================================================

@test "(AC-EC5) fallback path serializes writers when flock is unavailable" {
  assert_script_exists
  seed_review_with_roster
  make_barrier

  local N=5
  local lock_log="$TEST_TMP/lock-debug.log"
  local i
  for i in $(seq 1 "$N"); do
    (
      read < "$BARRIER"
      GAIA_LOCK_TIMEOUT=120 GAIA_LOCK_FORCE_FALLBACK=1 GAIA_DREC_WRITE_DELAY=0.1 \
        ACQUIRE_LOCK_DEBUG=1 ACQUIRE_LOCK_DEBUG_LOG="$lock_log" \
        "$SCRIPT" approve \
          --stakeholder "stakeholder-A" \
          --recorded-by "fallback-approver-$i"
    ) &
  done

  release_barrier "$N"
  wait

  local count
  count="$(yq '.approvals | length' "$RECORD")"
  [ "$count" -eq "$N" ] || fail "expected $N approvals via fallback, got $count"

  # Non-vacuousness: debug log must prove ln-based fallback was engaged
  [ -f "$lock_log" ] || fail "lock debug log not created — fallback path not exercised"
  local acquire_count
  acquire_count="$(grep -c '^acquire ' "$lock_log" || true)"
  [ "$acquire_count" -ge "$N" ] || \
    fail "expected at least $N 'acquire' entries in lock log, got $acquire_count — fallback not engaged"
}


# =========================================================================
# (AC-EC6) unknown approver refused and refusal audited
# =========================================================================

@test "(AC-EC6) unknown approver refused: approval state unchanged, refusal audited" {
  assert_script_exists
  seed_review_with_roster

  local pre_approvals pre_state pre_iter
  pre_approvals="$(yq -o=json '.approvals' "$RECORD")"
  pre_state="$(yq '.design_state' "$RECORD")"
  pre_iter="$(yq '.iteration' "$RECORD")"

  run "$SCRIPT" approve --stakeholder "stakeholder-X" --recorded-by "test"
  [ "$status" -ne 0 ] || fail "unknown approver should be rejected"

  local post_approvals post_state post_iter
  post_approvals="$(yq -o=json '.approvals' "$RECORD")"
  post_state="$(yq '.design_state' "$RECORD")"
  post_iter="$(yq '.iteration' "$RECORD")"
  [ "$pre_approvals" = "$post_approvals" ] || fail "approvals list changed on rejection"
  [ "$pre_state" = "$post_state" ] || fail "design_state changed on rejection"
  [ "$pre_iter" = "$post_iter" ] || fail "iteration changed on rejection"

  local refusal_event
  refusal_event="$(yq '.audit[-1].event' "$RECORD")"
  [ "$refusal_event" = "approval-refused" ] || \
    fail "expected approval-refused audit entry, got '$refusal_event'"

  local refusal_stakeholder
  refusal_stakeholder="$(yq '.audit[-1]' "$RECORD")"
  [[ "$refusal_stakeholder" == *"stakeholder-X"* ]] || \
    fail "refusal entry does not name stakeholder-X"
}

@test "(AC-EC6) vacuous roster: warning emitted, approval accepted" {
  assert_script_exists
  seed_minimal_record "review" 1

  run "$SCRIPT" approve --stakeholder "anyone" --recorded-by "test"
  [[ "$output" == *"vacuous"* ]] || [[ "$output" == *"roster"* ]] || [[ "$output" == *"empty"* ]] || \
    fail "expected vacuous-roster warning"
}


# =========================================================================
# (AC-EC7) convergence answerable from summary fields without trail walk
# =========================================================================

@test "(AC-EC7) convergence does not read .audit (structural proof)" {
  assert_script_exists
  seed_review_with_roster

  run "$SCRIPT" approve --stakeholder "stakeholder-A" --recorded-by "test"
  [ "$status" -eq 0 ]
  run "$SCRIPT" approve --stakeholder "stakeholder-B" --recorded-by "test"
  [ "$status" -eq 0 ]

  # Baseline: convergence works on the full record
  run "$SCRIPT" check-convergence
  [ "$status" -eq 0 ] || fail "convergence should hold on full record: $output"
  [[ "$output" == *"converged"* ]] || fail "full-record convergence missing 'converged' in output"

  # Build a second PROJECT_ROOT with the record stripped of .audit/.audit_head
  local alt_root="$TEST_TMP/alt-convergence"
  mkdir -p "$alt_root/.gaia/state"
  yq 'del(.audit) | del(.audit_head)' "$RECORD" > "$alt_root/.gaia/state/design-record.yaml"
  cp -R "$TEST_TMP/.gaia/custom" "$alt_root/.gaia/custom"

  run env PROJECT_ROOT="$alt_root" "$SCRIPT" check-convergence
  [ "$status" -eq 0 ] || fail "convergence failed without .audit — it reads the trail: $output"
  [[ "$output" == *"converged"* ]] || fail "stripped-record convergence missing 'converged' in output"

  # Non-vacuousness: stripped record must actually lack .audit
  local stripped_audit_len
  stripped_audit_len="$(yq '.audit | length' "$alt_root/.gaia/state/design-record.yaml" 2>/dev/null || echo 0)"
  [ "${stripped_audit_len:-0}" -eq 0 ] || fail "stripped record still has .audit — test is vacuous"

  # PATH-injected yq wrapper: fails on any expression referencing .audit,
  # delegates all other calls to the real yq.  This catches mutants that
  # add .audit reads inside the convergence path — the stripped-record
  # approach above does not, because yq silently returns null/0 for
  # missing keys rather than erroring.
  local wrapper_dir="$TEST_TMP/yq-wrapper"
  mkdir -p "$wrapper_dir"
  local real_yq
  real_yq="$(command -v yq)"
  cat > "$wrapper_dir/yq" <<WRAPPER
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *.audit*) printf 'yq-wrapper: .audit access blocked on convergence path\n' >&2; exit 99 ;;
  esac
done
exec "$real_yq" "\$@"
WRAPPER
  chmod +x "$wrapper_dir/yq"

  # Run check-convergence with the wrapper in front of PATH
  run env PROJECT_ROOT="$TEST_TMP" PATH="$wrapper_dir:$PATH" "$SCRIPT" check-convergence
  [ "$status" -eq 0 ] || fail "check-convergence touched .audit (wrapper exit $status): $output"
  [[ "$output" == *"converged"* ]] || fail "wrapper-guarded convergence missing 'converged' in output"
}

@test "(AC-EC7) static: convergence function has no .audit reference" {
  [ -f "$SCRIPTS_DIR/design-record.sh" ] || fail "design-record.sh does not exist"

  local fn_body
  fn_body="$(_extract_fn_body cmd_check_convergence "$SCRIPTS_DIR/design-record.sh")"

  local audit_refs
  audit_refs="$(printf '%s' "$fn_body" | grep -E '\.audit' | grep -vE '^\s*#' || true)"
  [ -z "$audit_refs" ] || fail "cmd_check_convergence references .audit: $audit_refs"

  local chain_refs
  chain_refs="$(printf '%s' "$fn_body" | grep -E '_verify_chain' | grep -vE '^\s*#' || true)"
  [ -z "$chain_refs" ] || fail "cmd_check_convergence calls _verify_chain: $chain_refs"
}


# =========================================================================
# Roster resolution: preference cascade tests
# =========================================================================

@test "roster resolver prefers .gaia/custom/stakeholders/ over legacy custom/stakeholders/" {
  assert_script_exists
  seed_minimal_record "review" 1

  seed_roster_gaia     # stakeholder-A (design,ux), stakeholder-B (ux)
  seed_roster_legacy   # stakeholder-L1 (design)

  run "$SCRIPT" approve --stakeholder "stakeholder-A" --recorded-by "test"
  [ "$status" -eq 0 ] || fail "stakeholder-A from .gaia/custom/ path not resolved"

  # Legacy stakeholder rejected when .gaia/custom/ exists
  seed_minimal_record "review" 1
  seed_roster_gaia
  seed_roster_legacy
  run "$SCRIPT" approve --stakeholder "stakeholder-L1" --recorded-by "test"
  [ "$status" -ne 0 ] || fail "stakeholder-L1 from legacy path should be ignored when .gaia/custom/ exists"
}

@test "roster resolver falls back to legacy custom/stakeholders/ when .gaia/custom/ absent" {
  assert_script_exists
  seed_minimal_record "review" 1
  seed_roster_legacy

  run "$SCRIPT" approve --stakeholder "stakeholder-L1" --recorded-by "test"
  [ "$status" -eq 0 ] || fail "stakeholder-L1 from legacy path not resolved as fallback"
}

@test "roster resolver: both paths absent reports vacuous-convergence" {
  assert_script_exists
  seed_minimal_record "review" 1

  run "$SCRIPT" check-convergence
  [[ "$output" == *"vacuous"* ]] || fail "expected vacuous-convergence with no roster"
}


# =========================================================================
# Static analysis: pre-lock validation ordering
# =========================================================================

@test "static: every cmd_* calls its policy validators before _locked_mutate" {
  [ -f "$SCRIPTS_DIR/design-record.sh" ] || fail "design-record.sh does not exist"

  local script="$SCRIPTS_DIR/design-record.sh"

  # Per-verb requirement table: each mutating cmd_* must call _preflight_mutate
  # AND its verb-specific policy validators before _locked_mutate.
  # Format: "funcname:validator1,validator2,..."
  local -a requirements=(
    "cmd_transition:_preflight_mutate,_assert_valid_state,_assert_legal_transition"
    "cmd_approve:_preflight_mutate,_assert_known_stakeholder"
    "cmd_add_review:_preflight_mutate"
    "cmd_add_override:_preflight_mutate"
    "cmd_not_applicable:_preflight_mutate"
  )

  local fail_list="" entry func validators
  for entry in "${requirements[@]}"; do
    func="${entry%%:*}"
    validators="${entry#*:}"

    local body
    body="$(_extract_fn_body "$func" "$script")"

    # The function must call _locked_mutate
    printf '%s' "$body" | grep -q '_locked_mutate' || {
      fail_list="${fail_list}${func} does not call _locked_mutate\n"; continue; }

    local mutate_line
    mutate_line="$(printf '%s' "$body" | grep -n '_locked_mutate' | head -1 | cut -d: -f1)"

    # Each required validator must appear before _locked_mutate
    local v
    IFS=',' read -ra v_arr <<< "$validators"
    for v in "${v_arr[@]}"; do
      local v_line
      v_line="$(printf '%s' "$body" | grep -n "$v" | head -1 | cut -d: -f1)"
      if [ -z "$v_line" ]; then
        fail_list="${fail_list}${func} missing required validator: $v\n"
      elif [ "$v_line" -gt "$mutate_line" ]; then
        fail_list="${fail_list}${func} calls $v (line $v_line) AFTER _locked_mutate (line $mutate_line)\n"
      fi
    done
  done

  [ -z "$fail_list" ] || {
    printf 'Policy-validator ordering violations:\n%b' "$fail_list"
    fail "pre-lock policy-validator ordering violated"
  }
}

@test "static: every multi-line function in design-record.sh closes at column 0" {
  # Style guard: _extract_fn_body relies on `^}$` to find function ends.
  # An indented closing brace would cause the extractor to overshoot and
  # silently capture subsequent functions, making static tests vacuous.
  [ -f "$SCRIPTS_DIR/design-record.sh" ] || fail "design-record.sh does not exist"

  local script="$SCRIPTS_DIR/design-record.sh"

  # Top-level guard: no indented closing braces anywhere in the script.
  # Catches the LAST function (where the header-count check below can't
  # detect overshoot because there's no subsequent function header to find).
  ! grep -nE '^[[:space:]]+\}[[:space:]]*$' "$script" || \
    fail "indented closing brace found — column-0 convention violated"

  # Find all multi-line function declarations (exclude single-line `f() { ...; }`)
  local func_names
  func_names="$(grep -E '^[a-z_][a-z0-9_]*\(\)' "$script" \
    | grep -vE '\{.*\}' \
    | sed 's/().*//' || true)"
  [ -n "$func_names" ] || fail "no multi-line functions found"

  # For each multi-line function, _extract_fn_body must capture exactly one
  # function header.  If the closing brace is indented, the awk extractor
  # overshoots and the body contains a second `^funcname()` header line.
  local func fail_list=""
  for func in $func_names; do
    local body header_count
    body="$(_extract_fn_body "$func" "$script")"
    header_count="$(printf '%s\n' "$body" | grep -cE '^[a-z_][a-z0-9_]*\(\)' || true)"
    if [ "$header_count" -ne 1 ]; then
      fail_list="${fail_list}${func}: extracted body contains $header_count function headers (expected 1) — closing brace likely indented\n"
    fi
  done

  [ -z "$fail_list" ] || {
    printf 'Functions whose extraction overshoots:\n%b' "$fail_list"
    fail "column-0 brace convention violated — _extract_fn_body would overshoot"
  }
}


# =========================================================================
# Consumers ignore design state in artifact frontmatter
# =========================================================================

@test "consumers ignore design state in artifact frontmatter — record wins" {
  assert_script_exists
  seed_frontmatter_story "approved"
  seed_frontmatter_ux "approved"
  seed_minimal_record "draft" 1

  run "$SCRIPT" show
  [ "$status" -eq 0 ]
  [[ "$output" == *"draft"* ]] || fail "show reports something other than 'draft'"
  [[ "$output" != *"approved"* ]] || fail "show consults frontmatter 'approved' state"

  run "$SCRIPT" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"draft"* ]] || fail "status reports something other than 'draft'"

  run "$SCRIPT" check-convergence
  [[ "$output" != *"approved"* ]] || fail "convergence consults frontmatter state"
}

@test "consumers ignore frontmatter: absent record blocks regardless of frontmatter" {
  assert_script_exists
  seed_frontmatter_story "approved"
  seed_frontmatter_ux "approved"
  [ ! -f "$RECORD" ] || rm -f "$RECORD"

  run "$SCRIPT" status
  [ "$status" -ne 0 ] || fail "absent record should block despite frontmatter approval"
  [[ "$output" == *"absent"* ]] || fail "should report absent, not read frontmatter"
}


# =========================================================================
# Not-applicable pass
# =========================================================================

@test "not-applicable pass: sets applicability and appends audit entry" {
  assert_script_exists
  seed_minimal_record "draft" 1

  run "$SCRIPT" not-applicable --actor "test-actor"
  [ "$status" -eq 0 ] || fail "not-applicable failed: $output"

  local applicability
  applicability="$(yq '.applicability' "$RECORD")"
  [ "$applicability" = "not-applicable" ] || fail "applicability not set to not-applicable"

  local last_event
  last_event="$(yq '.audit[-1].event' "$RECORD")"
  [ "$last_event" = "not-applicable-pass" ] || fail "expected not-applicable-pass audit entry"
}


# =========================================================================
# Corrupt record handling
# =========================================================================

@test "corrupt YAML rejected with diagnostic naming record path" {
  assert_script_exists
  mkdir -p "$STATE_DIR"
  printf 'this: is: not: valid: yaml: [unterminated' > "$RECORD"

  run "$SCRIPT" show
  [ "$status" -ne 0 ] || fail "corrupt YAML should be rejected"
  [[ "$output" == *"design-record"* ]] || fail "diagnostic should name the record"
}


# =========================================================================
# PROJECT_ROOT precedence
# =========================================================================

@test "PROJECT_ROOT precedence: CLAUDE_PROJECT_ROOT used when PROJECT_ROOT unset" {
  assert_script_exists

  local alt_root="$TEST_TMP/alt-root"
  mkdir -p "$alt_root/.gaia/state"
  seed_minimal_record "draft" 1
  cp "$RECORD" "$alt_root/.gaia/state/design-record.yaml"

  run env -u PROJECT_ROOT -u PROJECT_PATH \
    CLAUDE_PROJECT_ROOT="$alt_root" \
    "$SCRIPT" status
  [ "$status" -eq 0 ] || fail "should resolve via CLAUDE_PROJECT_ROOT"
  [[ "$output" == *"draft"* ]] || fail "should read the record from alt-root"
}


# =========================================================================
# (AC5) init refuses when a record already exists (review-rework item 1)
# =========================================================================

@test "(AC5) init refuses when a record already exists and leaves it byte-identical" {
  assert_script_exists

  # Create an initial record via the writer
  run "$SCRIPT" init \
    --reference "original-ref" \
    --discovered-via "created" \
    --questionnaire-record "original-qr.md"
  [ "$status" -eq 0 ] || fail "first init failed: $output"

  # Build up state: transition + approval + override so the record is populated
  seed_roster_gaia
  run "$SCRIPT" transition --to "review" --actor "test-actor"
  [ "$status" -eq 0 ] || fail "transition failed: $output"
  run "$SCRIPT" approve --stakeholder "stakeholder-A" --recorded-by "test"
  [ "$status" -eq 0 ] || fail "approve failed: $output"
  run "$SCRIPT" add-override --actor "admin" --reason "unblocking" --entry-point "/test"
  [ "$status" -eq 0 ] || fail "add-override failed: $output"

  # Snapshot: sha256 + inode + mtime
  capture_record_state "$RECORD"

  # Second init must refuse
  run "$SCRIPT" init \
    --reference "new-ref" \
    --discovered-via "created" \
    --questionnaire-record "new-qr.md" \
    --actor "evil"
  [ "$status" -ne 0 ] || fail "second init should be refused but exited 0"

  # Record must be byte-identical
  assert_record_unchanged "$RECORD" "$PRE_SHA" "$PRE_INODE" "$PRE_MTIME" "$PRE_SIZE"

  # Diagnostic must name the record path and tell the user to use mutation verbs
  [[ "$output" == *"$RECORD"* ]] || [[ "$output" == *"design-record"* ]] || \
    fail "diagnostic does not name the record path"
  [[ "$output" == *"transition"* ]] || [[ "$output" == *"mutation"* ]] || [[ "$output" == *"already exists"* ]] || \
    fail "diagnostic does not guide the user to use mutation verbs"
}


# =========================================================================
# (AC5) init refuses when record path is a symlink (review-rework item 2)
# =========================================================================

@test "(AC5) init refuses when record path is a symlink and target is untouched" {
  assert_script_exists
  mkdir -p "$STATE_DIR"

  # Plant a symlink at the record path pointing to a target file
  local target="$TEST_TMP/symlink-target.yaml"
  printf 'original-content: true\n' > "$target"
  local pre_target_sha
  pre_target_sha="$(_sha256_file "$target")"

  ln -sf "$target" "$RECORD"
  [ -L "$RECORD" ] || fail "symlink not created"

  run "$SCRIPT" init \
    --reference "sym-ref" \
    --discovered-via "created" \
    --questionnaire-record "sym-qr.md"
  [ "$status" -ne 0 ] || fail "init should refuse when record path is a symlink"
  [[ "$output" == *"refusing to follow"* ]] || \
    fail "diagnostic does not contain the symlink-guard phrase 'refusing to follow'"
  [[ "$output" != *"already exists"* ]] || \
    fail "existing-record guard fired instead of the symlink guard"

  # Symlink target must be untouched
  local post_target_sha
  post_target_sha="$(_sha256_file "$target")"
  [ "$pre_target_sha" = "$post_target_sha" ] || \
    fail "symlink target was modified: $pre_target_sha -> $post_target_sha"
}


# =========================================================================
# (AC-EC3) field-level audit tampering detected by digest chain (review-rework item 3)
# =========================================================================

@test "(AC-EC3) field-level audit entry tampering detected by digest chain" {
  assert_script_exists
  seed_minimal_record "draft" 1

  # Build a 3-entry trail via legitimate transitions
  run "$SCRIPT" transition --to "review" --actor "actor-a"
  [ "$status" -eq 0 ] || fail "transition 1 failed: $output"
  run "$SCRIPT" transition --to "review" --actor "actor-b"
  [ "$status" -eq 0 ] || fail "transition 2 failed: $output"
  run "$SCRIPT" transition --to "review" --actor "actor-c"
  [ "$status" -eq 0 ] || fail "transition 3 failed: $output"

  # Baseline: integrity holds
  run "$SCRIPT" verify-integrity
  [ "$status" -eq 0 ] || fail "integrity check failed on legitimate record: $output"

  # Tamper: change a FIELD of audit[1] without touching the digest
  yq -i '.audit[1].actor = "TAMPERED"' "$RECORD"

  # verify-integrity must detect the tamper via the digest chain
  run "$SCRIPT" verify-integrity
  [ "$status" -ne 0 ] || fail "field-level tampering in audit[1].actor was not detected"
  [[ "$output" == *"digest"* ]] || [[ "$output" == *"integrity"* ]] || \
    fail "expected digest-chain diagnostic, got: $output"

  # Also: the NEXT mutation verb must refuse (the in-lock chain check)
  run "$SCRIPT" transition --to "stale" --actor "attacker"
  [ "$status" -ne 0 ] || fail "mutation verb should refuse on tampered record"
}


# =========================================================================
# (AC4) convergence gate rejects review->approved without convergence (review-rework item 4)
# =========================================================================

@test "(AC4) review->approved refused without convergence and record unchanged" {
  assert_script_exists
  seed_review_with_roster  # review state, roster with stakeholder-A and stakeholder-B

  # Do NOT approve any stakeholders — convergence is not satisfied
  capture_record_state "$RECORD"

  run "$SCRIPT" transition --to "approved" --actor "test-actor"
  [ "$status" -ne 0 ] || fail "review->approved should be refused without convergence"

  # Record must be unchanged (no side effects from the failed transition)
  assert_record_unchanged "$RECORD" "$PRE_SHA" "$PRE_INODE" "$PRE_MTIME" "$PRE_SIZE"

  # Diagnostic must mention convergence or missing stakeholders
  [[ "$output" == *"converge"* ]] || [[ "$output" == *"not-converged"* ]] || \
    [[ "$output" == *"blocked"* ]] || [[ "$output" == *"missing"* ]] || \
    fail "expected convergence-refusal diagnostic, got: $output"
}

@test "(AC4) review->approved refused with partial convergence" {
  assert_script_exists
  seed_review_with_roster

  # Approve only ONE of the two required stakeholders
  run "$SCRIPT" approve --stakeholder "stakeholder-A" --recorded-by "test"
  [ "$status" -eq 0 ] || fail "approve A failed: $output"

  capture_record_state "$RECORD"

  run "$SCRIPT" transition --to "approved" --actor "test-actor"
  [ "$status" -ne 0 ] || fail "review->approved should be refused with partial convergence"
  [[ "$output" == *"stakeholder-B"* ]] || [[ "$output" == *"not-converged"* ]] || \
    [[ "$output" == *"blocked"* ]] || [[ "$output" == *"missing"* ]] || \
    fail "diagnostic should identify the missing stakeholder"
}


# =========================================================================
# (AC4) illegal enum: distinct enum-validator diagnostic (review-rework item 5)
# =========================================================================

@test "(AC4) illegal enum values produce the enum-validator diagnostic distinct from transition" {
  assert_script_exists
  seed_minimal_record "draft" 1

  # Try an illegal enum value — should hit _assert_valid_state with "legal values:"
  run "$SCRIPT" transition --to "BOGUS"
  [ "$status" -ne 0 ] || fail "BOGUS should be rejected"
  [[ "$output" == *"legal values:"* ]] || \
    fail "expected enum-validator diagnostic 'legal values:', got: $output"

  # Now try a legal enum value on an illegal EDGE — should hit _assert_legal_transition
  # with "legal edges:" (NOT "legal values:")
  run "$SCRIPT" transition --to "approved"
  [ "$status" -ne 0 ] || fail "draft->approved should be rejected"
  [[ "$output" == *"legal edges:"* ]] || \
    fail "expected transition-validator diagnostic 'legal edges:', got: $output"
  # This diagnostic must NOT contain "legal values:" — it comes from a different guard
  [[ "$output" != *"legal values:"* ]] || \
    fail "illegal-transition diagnostic should not contain 'legal values:' — guards are indistinct"
}


# =========================================================================
# (AC3) concurrent test with generous lock timeout (review-rework item 6)
# =========================================================================


# =========================================================================
# (AC4) add-review --notes-ref field round-trip
# =========================================================================

@test "(AC4) add-review writes notes-ref field when provided" {
  assert_script_exists
  seed_review_with_roster

  run "$SCRIPT" add-review \
    --verdict "approved" \
    --reviewer "reviewer-A" \
    --kind "internal" \
    --notes-ref ".gaia/artifacts/review-notes.md"
  [ "$status" -eq 0 ] || fail "add-review with --notes-ref failed: $output"

  local stored_ref
  stored_ref="$(yq '.reviews[-1].notes_ref' "$RECORD")"
  [ "$stored_ref" = ".gaia/artifacts/review-notes.md" ] || \
    fail "notes_ref not stored: expected '.gaia/artifacts/review-notes.md', got '$stored_ref'"
}

@test "(AC4) add-review omits notes-ref when not provided" {
  assert_script_exists
  seed_review_with_roster

  # First verify that --notes-ref IS a recognized option (added by this story)
  local help_output
  help_output="$(grep -c 'notes.ref\|notes_ref' "$SCRIPT" 2>/dev/null || true)"
  [ "$help_output" -gt 0 ] || fail "design-record.sh does not recognize --notes-ref yet"

  run "$SCRIPT" add-review \
    --verdict "approved" \
    --reviewer "reviewer-A" \
    --kind "internal"
  [ "$status" -eq 0 ] || fail "add-review without --notes-ref failed: $output"

  local stored_ref
  stored_ref="$(yq '.reviews[-1].notes_ref' "$RECORD" 2>/dev/null)"
  # notes_ref should be absent (null) when not provided — backward compat
  [ "$stored_ref" = "null" ] || [ -z "$stored_ref" ] || \
    fail "notes_ref should be absent when not provided, got '$stored_ref'"
}

@test "(AC4) notes-ref round-trip with special characters" {
  assert_script_exists
  seed_review_with_roster

  # Payload containing quotes, $, backticks, newlines, and unicode
  local payload
  payload="$(printf 'path/with "quotes" and $dollar and \x60backtick\x60\nand newline and \xc3\xb1 and \xf0\x9f\x8e\xa8')"

  run "$SCRIPT" add-review \
    --verdict "approved" \
    --reviewer "reviewer-A" \
    --kind "internal" \
    --notes-ref "$payload"
  [ "$status" -eq 0 ] || fail "add-review with special-char notes-ref failed: $output"

  local stored_ref
  stored_ref="$(yq '.reviews[-1].notes_ref' "$RECORD")"
  [ "$stored_ref" = "$payload" ] || \
    fail "notes_ref not round-tripped: expected <<<$payload>>> got <<<$stored_ref>>>"
}


# =========================================================================
# (AC4) writer enum guards — verdict and kind validation
# =========================================================================

@test "(AC4) add-review refuses an unknown verdict and leaves the record byte-identical" {
  assert_script_exists
  seed_review_with_roster

  capture_record_state "$RECORD"

  run "$SCRIPT" add-review \
    --verdict "bogus" \
    --reviewer "tester" \
    --kind "internal"
  [ "$status" -ne 0 ] || fail "add-review should refuse unknown verdict 'bogus'"

  assert_record_unchanged "$RECORD" "$PRE_SHA" "$PRE_INODE" "$PRE_MTIME" "$PRE_SIZE"
  assert_no_lock_or_tmp "$(dirname "$RECORD")" "$(basename "$RECORD")"
}

@test "(AC4) add-review refuses an unknown kind and leaves the record byte-identical" {
  assert_script_exists
  seed_review_with_roster

  capture_record_state "$RECORD"

  run "$SCRIPT" add-review \
    --verdict "approved" \
    --reviewer "tester" \
    --kind "fantasy"
  [ "$status" -ne 0 ] || fail "add-review should refuse unknown kind 'fantasy'"

  assert_record_unchanged "$RECORD" "$PRE_SHA" "$PRE_INODE" "$PRE_MTIME" "$PRE_SIZE"
  assert_no_lock_or_tmp "$(dirname "$RECORD")" "$(basename "$RECORD")"
}

@test "(AC4) mutant: removing the enum guard admits a schema-invalid review" {
  # This test proves the enum guard (_assert_valid_verdict) is load-bearing.
  # It first asserts the function exists in the source, then neutralises it
  # in a copy and verifies that bogus verdicts slip through.
  assert_script_exists

  # Step 1: the _assert_valid_verdict function must exist — fail if absent
  grep -q '^_assert_valid_verdict()' "$SCRIPT" || \
    fail "_assert_valid_verdict function not found in design-record.sh — the enum guard has not been added yet"

  # Step 2: neutralise the function in a copy and prove bogus verdicts pass
  seed_review_with_roster
  local mutant_script="$TEST_TMP/design-record-mutant.sh"
  cp "$SCRIPT" "$mutant_script"
  # The copy needs the lib/ directory for acquire-lock.sh sourcing
  ln -sfn "$SCRIPTS_DIR/lib" "$TEST_TMP/lib"
  # Replace the function body with a no-op, preserving the function header
  # so _parse_opts and callers still resolve, but the guard does nothing.
  sed -i.bak '/^_assert_valid_verdict()/,/^}$/c\
_assert_valid_verdict() {\
  : # neutralised by mutant test\
}' "$mutant_script"
  chmod +x "$mutant_script"

  # The neutralised copy must still contain the function header
  grep -q '^_assert_valid_verdict()' "$mutant_script" || \
    fail "sed neutralisation failed — function header not found in mutant copy"

  run env PROJECT_ROOT="$TEST_TMP" "$mutant_script" add-review \
    --verdict "bogus" \
    --reviewer "tester" \
    --kind "internal"
  [ "$status" -eq 0 ] || \
    fail "mutant: neutralising _assert_valid_verdict should admit schema-invalid reviews, but exit=$status: $output"
}


# =========================================================================
# (AC4) schema conformance — escalated verdict
# =========================================================================

@test "(AC4) schema accepts escalated as a review verdict" {
  [ -f "$SCHEMA" ] || fail "design-record.schema.json does not exist"

  # Create a fixture record with verdict: escalated
  local fixture="$TEST_TMP/escalated-fixture.yaml"
  cat > "$fixture" <<'FIXTURE'
schema_version: "1.0"
applicability: applicable
design_state: review
iteration: 1
project:
  reference: "test-ref"
  discovered_via: "created"
  questionnaire_record: "q.md"
reviews:
  - iteration: 1
    kind: stakeholder
    verdict: escalated
    actor: reviewer-A
    at: "2026-01-01T00:00:00Z"
approvals: []
overrides: []
audit: []
audit_head:
  count: 0
  last_digest: ""
FIXTURE

  # Convert to JSON for schema validation
  local json_fixture="$TEST_TMP/escalated-fixture.json"
  yq -o=json "$fixture" > "$json_fixture"

  # Validate via shared helper
  source "$SCRIPTS_DIR/lib/validate-artifact-schema.sh"
  run validate_artifact_schema "$SCHEMA" "$json_fixture"
  [ "$status" -ne 3 ] || fail "schema validation backend absent — cannot proceed"
  [ "$status" -eq 0 ] || fail "schema should accept verdict: escalated, but validation failed: $output"
}

# =========================================================================
# Symlink refusal on mutating verbs (shared mutate path)
# =========================================================================

@test "transition refuses a symlinked record and target stays byte-identical" {
  assert_script_exists
  seed_minimal_record "draft" 1

  # Move the real record aside and plant a symlink at RECORD_PATH
  local real_file="$TEST_TMP/real-record.yaml"
  mv "$RECORD" "$real_file"
  ln -s "$real_file" "$RECORD"
  [ -L "$RECORD" ] || fail "symlink not created"

  local pre_sha
  pre_sha="$(_sha256_file "$real_file")"

  run "$SCRIPT" transition --to review --actor test
  [ "$status" -ne 0 ] || fail "transition should refuse a symlinked record but exited 0"
  [[ "$output" == *"symlink"* ]] || fail "diagnostic should mention symlink"

  # Target must be untouched
  local post_sha
  post_sha="$(_sha256_file "$real_file")"
  [ "$pre_sha" = "$post_sha" ] || fail "symlink target was modified"
}

@test "add-review refuses a symlinked record and target stays byte-identical" {
  assert_script_exists
  seed_minimal_record "review" 1

  local real_file="$TEST_TMP/real-record.yaml"
  mv "$RECORD" "$real_file"
  ln -s "$real_file" "$RECORD"
  [ -L "$RECORD" ] || fail "symlink not created"

  local pre_sha
  pre_sha="$(_sha256_file "$real_file")"

  run "$SCRIPT" add-review --verdict approved --reviewer tester --kind internal
  [ "$status" -ne 0 ] || fail "add-review should refuse a symlinked record but exited 0"
  [[ "$output" == *"symlink"* ]] || fail "diagnostic should mention symlink"

  local post_sha
  post_sha="$(_sha256_file "$real_file")"
  [ "$pre_sha" = "$post_sha" ] || fail "symlink target was modified"
}

@test "mutant: removing the mutate-path symlink check lets transition proceed" {
  assert_script_exists
  seed_review_with_roster

  # Move the real record aside and plant a symlink
  local real_file="$TEST_TMP/real-record-mutant.yaml"
  mv "$RECORD" "$real_file"
  ln -s "$real_file" "$RECORD"

  # Create a mutant copy with the _preflight_mutate symlink guard replaced
  # by a no-op function that only calls _preflight_read (the original body
  # before the hardening added the -L check).
  local mutant_script="$TEST_TMP/design-record-mutant-sym.sh"
  cp "$SCRIPT" "$mutant_script"
  ln -sfn "$SCRIPTS_DIR/lib" "$TEST_TMP/lib"

  # Replace _preflight_mutate() body: strip the entire function and replace
  # with one that just calls _preflight_read (no symlink check)
  awk '
    /^_preflight_mutate\(\)/ {
      print "_preflight_mutate() {"
      print "  _preflight_read"
      print "}"
      # Skip until the closing brace of the original function
      while ((getline line) > 0) {
        if (line ~ /^\}$/) break
      }
      next
    }
    { print }
  ' "$mutant_script" > "$mutant_script.tmp"
  mv "$mutant_script.tmp" "$mutant_script"
  chmod +x "$mutant_script"

  run env PROJECT_ROOT="$TEST_TMP" "$mutant_script" transition --to review --actor test
  [ "$status" -eq 0 ] || \
    fail "mutant: removing the symlink check should let transition proceed, but exit=$status: $output"
}

@test "(AC4) schema rejects an unknown review verdict" {
  [ -f "$SCHEMA" ] || fail "design-record.schema.json does not exist"

  # Pre-check: the schema must include escalated as a valid verdict
  # (this story adds it).  If it's missing, the test is premature.
  grep -q '"escalated"' "$SCHEMA" || \
    fail "schema does not include 'escalated' as a valid verdict — schema update not applied yet"

  # Create a fixture record with verdict: bogus
  local fixture="$TEST_TMP/bogus-fixture.yaml"
  cat > "$fixture" <<'FIXTURE'
schema_version: "1.0"
applicability: applicable
design_state: review
iteration: 1
project:
  reference: "test-ref"
  discovered_via: "created"
  questionnaire_record: "q.md"
reviews:
  - iteration: 1
    kind: stakeholder
    verdict: bogus
    actor: reviewer-A
    at: "2026-01-01T00:00:00Z"
approvals: []
overrides: []
audit: []
audit_head:
  count: 0
  last_digest: ""
FIXTURE

  local json_fixture="$TEST_TMP/bogus-fixture.json"
  yq -o=json "$fixture" > "$json_fixture"

  source "$SCRIPTS_DIR/lib/validate-artifact-schema.sh"
  run validate_artifact_schema "$SCHEMA" "$json_fixture"
  [ "$status" -ne 3 ] || fail "schema validation backend absent — cannot proceed"
  [ "$status" -ne 0 ] || fail "schema should reject verdict: bogus, but validation passed"
}

# =========================================================================
# Stale-to-review iteration bump (AC8)
# =========================================================================

@test "(AC8) stale-to-review bumps iteration and prior approvals no longer satisfy convergence" {
  assert_script_exists

  seed_roster_gaia
  # Init and drive to approved at iteration 1
  run "$SCRIPT" init --reference test --discovered-via created --questionnaire-record na
  [ "$status" -eq 0 ]
  run "$SCRIPT" transition --to review --actor ci
  [ "$status" -eq 0 ]
  run "$SCRIPT" approve --stakeholder stakeholder-A --recorded-by ci
  [ "$status" -eq 0 ]
  run "$SCRIPT" approve --stakeholder stakeholder-B --recorded-by ci
  [ "$status" -eq 0 ]
  run "$SCRIPT" transition --to approved --actor ci
  [ "$status" -eq 0 ]

  # Transition to stale
  run "$SCRIPT" transition --to stale --actor ci
  [ "$status" -eq 0 ]

  # Transition stale -> review: should bump iteration to 2
  run "$SCRIPT" transition --to review --actor ci
  [ "$status" -eq 0 ]

  local iter
  iter="$(yq '.iteration' "$RECORD")"
  [ "$iter" -eq 2 ] || fail "iteration should be 2 after stale-to-review but is $iter"

  # Check-convergence should report not-converged
  run "$SCRIPT" check-convergence
  [ "$status" -ne 0 ] || [[ "$output" == *"not-converged"* ]] \
    || fail "should report not-converged after iteration bump"

  # Transition to approved should fail (no fresh approval at iter 2)
  run "$SCRIPT" transition --to approved --actor ci
  [ "$status" -ne 0 ] || fail "transition to approved should fail without fresh approvals"

  # Approve at iteration 2 and transition
  run "$SCRIPT" approve --stakeholder stakeholder-A --recorded-by ci
  [ "$status" -eq 0 ]
  run "$SCRIPT" approve --stakeholder stakeholder-B --recorded-by ci
  [ "$status" -eq 0 ]
  run "$SCRIPT" transition --to approved --actor ci
  [ "$status" -eq 0 ]

  iter="$(yq '.iteration' "$RECORD")"
  [ "$iter" -eq 2 ] || fail "iteration should still be 2 after approval but is $iter"
}

# =========================================================================
# Schema conformance for audit integration fields
# =========================================================================

@test "schema conformance: audit entry with integration_state and integration_source" {
  assert_script_exists
  source "$SCRIPTS_DIR/lib/validate-artifact-schema.sh"

  # Init a record and transition to stale with integration options
  run "$SCRIPT" init --reference test --discovered-via created --questionnaire-record na
  [ "$status" -eq 0 ]
  run "$SCRIPT" transition --to review --actor ci
  [ "$status" -eq 0 ]

  run "$SCRIPT" transition --to stale --actor ci \
    --integration-state available --integration-source attested
  [ "$status" -eq 0 ] || fail "transition with integration options should succeed but got: $output"

  # Validate against schema
  run validate_artifact_schema "$SCHEMA" "$RECORD"
  [ "$status" -ne 3 ] || fail "schema validation backend absent — cannot proceed"
  [ "$status" -eq 0 ] || fail "schema validation failed after transition with integration fields: $output"

  # Assert the audit entry has the fields
  local audit_int_state audit_int_source
  audit_int_state="$(yq '.audit[-1].integration_state' "$RECORD")"
  audit_int_source="$(yq '.audit[-1].integration_source' "$RECORD")"
  [ "$audit_int_state" = "available" ] || fail "audit integration_state should be available but is $audit_int_state"
  [ "$audit_int_source" = "attested" ] || fail "audit integration_source should be attested but is $audit_int_source"
}

# =========================================================================
# Writer option validation (both-or-neither, stale-only, enum)
# =========================================================================

@test "transition --integration-state without --integration-source is refused with both-required diagnostic" {
  assert_script_exists

  run "$SCRIPT" init --reference test --discovered-via created --questionnaire-record na
  [ "$status" -eq 0 ]
  run "$SCRIPT" transition --to review --actor ci
  [ "$status" -eq 0 ]

  capture_record_state "$RECORD"

  run "$SCRIPT" transition --to stale --actor ci --integration-state available
  [ "$status" -ne 0 ] || fail "should refuse --integration-state without --integration-source"

  # The diagnostic must name both options (not just "unknown option")
  [[ "$output" == *"integration-source"* ]] \
    || fail "diagnostic should name the missing --integration-source option but got: $output"

  assert_record_unchanged "$RECORD" "$PRE_SHA" "$PRE_INODE" "$PRE_MTIME" "$PRE_SIZE"
}

@test "transition --integration-source without --integration-state is refused with both-required diagnostic" {
  assert_script_exists

  run "$SCRIPT" init --reference test --discovered-via created --questionnaire-record na
  [ "$status" -eq 0 ]
  run "$SCRIPT" transition --to review --actor ci
  [ "$status" -eq 0 ]

  capture_record_state "$RECORD"

  run "$SCRIPT" transition --to stale --actor ci --integration-source probed
  [ "$status" -ne 0 ] || fail "should refuse --integration-source without --integration-state"

  # The diagnostic must name both options (not just "unknown option")
  [[ "$output" == *"integration-state"* ]] \
    || fail "diagnostic should name the missing --integration-state option but got: $output"

  assert_record_unchanged "$RECORD" "$PRE_SHA" "$PRE_INODE" "$PRE_MTIME" "$PRE_SIZE"
}

@test "transition --integration-state with invalid enum is refused with enum diagnostic" {
  assert_script_exists

  run "$SCRIPT" init --reference test --discovered-via created --questionnaire-record na
  [ "$status" -eq 0 ]
  run "$SCRIPT" transition --to review --actor ci
  [ "$status" -eq 0 ]

  capture_record_state "$RECORD"

  run "$SCRIPT" transition --to stale --actor ci \
    --integration-state garbage --integration-source attested
  [ "$status" -ne 0 ] || fail "should refuse invalid --integration-state enum"

  # Must mention the invalid value (not just "unknown option")
  [[ "$output" == *"garbage"* ]] \
    || fail "diagnostic should name the invalid value 'garbage' but got: $output"

  assert_record_unchanged "$RECORD" "$PRE_SHA" "$PRE_INODE" "$PRE_MTIME" "$PRE_SIZE"
}

@test "transition --integration-source with invalid enum is refused with enum diagnostic" {
  assert_script_exists

  run "$SCRIPT" init --reference test --discovered-via created --questionnaire-record na
  [ "$status" -eq 0 ]
  run "$SCRIPT" transition --to review --actor ci
  [ "$status" -eq 0 ]

  capture_record_state "$RECORD"

  run "$SCRIPT" transition --to stale --actor ci \
    --integration-state available --integration-source fabricated
  [ "$status" -ne 0 ] || fail "should refuse invalid --integration-source enum"

  # Must mention the invalid value (not just "unknown option")
  [[ "$output" == *"fabricated"* ]] \
    || fail "diagnostic should name the invalid value 'fabricated' but got: $output"

  assert_record_unchanged "$RECORD" "$PRE_SHA" "$PRE_INODE" "$PRE_MTIME" "$PRE_SIZE"
}

@test "transition --integration-state on non-stale transition is refused with stale-only diagnostic" {
  assert_script_exists

  run "$SCRIPT" init --reference test --discovered-via created --questionnaire-record na
  [ "$status" -eq 0 ]

  capture_record_state "$RECORD"

  run "$SCRIPT" transition --to review --actor ci \
    --integration-state available --integration-source attested
  [ "$status" -ne 0 ] || fail "should refuse integration options on draft-to-review"

  # Must mention stale (not just "unknown option")
  [[ "$output" == *"stale"* ]] || [[ "$output" == *"--to stale"* ]] \
    || fail "diagnostic should mention stale-only restriction but got: $output"

  assert_record_unchanged "$RECORD" "$PRE_SHA" "$PRE_INODE" "$PRE_MTIME" "$PRE_SIZE"
}

@test "transition --integration-state available --integration-source attested on stale succeeds" {
  assert_script_exists

  run "$SCRIPT" init --reference test --discovered-via created --questionnaire-record na
  [ "$status" -eq 0 ]
  run "$SCRIPT" transition --to review --actor ci
  [ "$status" -eq 0 ]

  run "$SCRIPT" transition --to stale --actor ci \
    --integration-state available --integration-source attested
  [ "$status" -eq 0 ] || fail "valid integration options on stale should succeed: $output"
}

# =========================================================================
# Mutant 6: stale-to-review without iteration bump
# =========================================================================

@test "(AC7) mutant: stale-to-review without iteration bump" {
  assert_script_exists

  seed_roster_gaia
  # Drive to approved at iteration 1
  run "$SCRIPT" init --reference test --discovered-via created --questionnaire-record na
  [ "$status" -eq 0 ]
  run "$SCRIPT" transition --to review --actor ci
  [ "$status" -eq 0 ]
  run "$SCRIPT" approve --stakeholder stakeholder-A --recorded-by ci
  [ "$status" -eq 0 ]
  run "$SCRIPT" approve --stakeholder stakeholder-B --recorded-by ci
  [ "$status" -eq 0 ]
  run "$SCRIPT" transition --to approved --actor ci
  [ "$status" -eq 0 ]
  run "$SCRIPT" transition --to stale --actor ci
  [ "$status" -eq 0 ]

  # Original: stale -> review should bump iteration
  run "$SCRIPT" transition --to review --actor ci
  [ "$status" -eq 0 ]
  local orig_iter
  orig_iter="$(yq '.iteration' "$RECORD")"
  [ "$orig_iter" -eq 2 ] || fail "original should bump iteration to 2 but got $orig_iter"

  # Reset for mutant
  rm -f "$RECORD"
  run "$SCRIPT" init --reference test --discovered-via created --questionnaire-record na
  [ "$status" -eq 0 ]
  run "$SCRIPT" transition --to review --actor ci
  [ "$status" -eq 0 ]
  run "$SCRIPT" approve --stakeholder stakeholder-A --recorded-by ci
  [ "$status" -eq 0 ]
  run "$SCRIPT" approve --stakeholder stakeholder-B --recorded-by ci
  [ "$status" -eq 0 ]
  run "$SCRIPT" transition --to approved --actor ci
  [ "$status" -eq 0 ]
  run "$SCRIPT" transition --to stale --actor ci
  [ "$status" -eq 0 ]

  # Patch: remove stale from the iteration-bump condition so only
  # review-to-review bumps (the stale-to-review edge no longer bumps)
  local mutant_script="$TEST_TMP/design-record-mutant.sh"
  cp "$SCRIPT" "$mutant_script"
  ln -sfn "$SCRIPTS_DIR/lib" "$TEST_TMP/lib"
  sed 's/\[ "$current_state" = "review" \] || \[ "$current_state" = "stale" \]/[ "$current_state" = "review" ]/' \
    "$mutant_script" > "$TEST_TMP/mutant-patched.sh"
  mv "$TEST_TMP/mutant-patched.sh" "$mutant_script"
  chmod +x "$mutant_script"
  if cmp -s "$SCRIPT" "$mutant_script"; then fail "patch did not apply"; fi

  run env PROJECT_ROOT="$TEST_TMP" "$mutant_script" transition --to review --actor ci
  [ "$status" -eq 0 ]

  local mutant_iter
  mutant_iter="$(yq '.iteration' "$RECORD")"
  [ "$mutant_iter" -eq 1 ] || fail "mutant should keep iteration at 1 but got $mutant_iter"
}


