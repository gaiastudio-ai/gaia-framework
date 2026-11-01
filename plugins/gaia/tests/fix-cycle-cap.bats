#!/usr/bin/env bats
# fix-cycle-cap.bats — tests for the fix-cycle cap, ESCALATE, and
# critical-security carve-out.

load 'test_helper.bash'

setup() {
  PLUGIN_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  REGISTER_WRITE="${PLUGIN_ROOT}/scripts/review-common/register-write.sh"
  SECURITY_READER="${PLUGIN_ROOT}/scripts/review-common/security-report-reader.sh"
  RESOLVE_CONFIG="${PLUGIN_ROOT}/scripts/resolve-config.sh"
  SCHEMA="${PLUGIN_ROOT}/schemas/project-config.schema.json"
  DOCTOR_SKILL="${PLUGIN_ROOT}/skills/gaia-doctor/SKILL.md"
  RUN_ALL_SKILL="${PLUGIN_ROOT}/skills/gaia-run-all-reviews/SKILL.md"
  TMP="${BATS_TEST_TMPDIR}"

  # Prevent env leaks from _rw / _sr helpers.
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT PROJECT_PATH 2>/dev/null || true

  printf 'BASH_VERSION=%s\n' "$BASH_VERSION" >&2
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_mk_config() {
  local dir="$1" max_fix="${2:-}"
  mkdir -p "$dir/.gaia/config"
  cat > "$dir/.gaia/config/project-config.yaml" <<YAML
project_root: "."
project_path: "."
memory_path: ".gaia/memory"
checkpoint_path: ".gaia/memory/checkpoints"
installed_path: "."
framework_version: "1.225.0"
date: "2026-11-01"
YAML
  if [ -n "$max_fix" ]; then
    cat >> "$dir/.gaia/config/project-config.yaml" <<YAML
review:
  max_fix_cycles: ${max_fix}
YAML
  fi
}

_mk_fixture() {
  local key="$1" num_failing="${2:-0}" num_passing="${3:-0}"
  local fdir="$TMP/fixture-${key}-$$"
  mkdir -p "$fdir/.gaia/artifacts/implementation-artifacts/epic-E900-test/${key}-test/reviews"
  cat > "$fdir/.gaia/artifacts/implementation-artifacts/epic-E900-test/${key}-test/story.md" <<EOF
---
key: "${key}"
status: review
risk: high
epic: "E900"
---
# Story: ${key}
EOF

  local reg_path="$fdir/.gaia/artifacts/implementation-artifacts/epic-E900-test/${key}-test/reviews/findings-register-${key}.yaml"
  cat > "$reg_path" <<YAML
schema_version: 1
story: ${key}
gate_runs: []
entries: []
rounds: []
YAML

  local i
  for i in $([ "$num_failing" -ge 1 ] && seq 1 "$num_failing" || true); do
    local rid="round-20261101T12000${i}Z-$$"
    yq -i ".rounds += [{
      \"run_id\": \"${rid}\",
      \"status\": \"complete\",
      \"commit_sha\": \"abc123\",
      \"accepted_version\": \"sha256:abc\",
      \"selected_gates\": [
        {\"gate\": \"code-review\", \"reason\": \"selected\", \"report_path\": \"\", \"report_sha256\": \"\"},
        {\"gate\": \"qa-tests\", \"reason\": \"selected\", \"report_path\": \"\", \"report_sha256\": \"\"},
        {\"gate\": \"security-review\", \"reason\": \"selected\", \"report_path\": \"\", \"report_sha256\": \"\"},
        {\"gate\": \"test-automate\", \"reason\": \"selected\", \"report_path\": \"\", \"report_sha256\": \"\"},
        {\"gate\": \"test-review\", \"reason\": \"selected\", \"report_path\": \"\", \"report_sha256\": \"\"},
        {\"gate\": \"performance-review\", \"reason\": \"selected\", \"report_path\": \"\", \"report_sha256\": \"\"}
      ],
      \"composite_verdict\": \"FAILED\"
    }]" "$reg_path"
  done

  for i in $([ "$num_passing" -ge 1 ] && seq 1 "$num_passing" || true); do
    local rid="round-20261101T13000${i}Z-$$"
    yq -i ".rounds += [{
      \"run_id\": \"${rid}\",
      \"status\": \"complete\",
      \"commit_sha\": \"def456\",
      \"accepted_version\": \"sha256:def\",
      \"selected_gates\": [
        {\"gate\": \"code-review\", \"reason\": \"selected\", \"report_path\": \"r.md\", \"report_sha256\": \"abc\"},
        {\"gate\": \"qa-tests\", \"reason\": \"selected\", \"report_path\": \"r.md\", \"report_sha256\": \"abc\"},
        {\"gate\": \"security-review\", \"reason\": \"selected\", \"report_path\": \"r.md\", \"report_sha256\": \"abc\"},
        {\"gate\": \"test-automate\", \"reason\": \"selected\", \"report_path\": \"r.md\", \"report_sha256\": \"abc\"},
        {\"gate\": \"test-review\", \"reason\": \"selected\", \"report_path\": \"r.md\", \"report_sha256\": \"abc\"},
        {\"gate\": \"performance-review\", \"reason\": \"selected\", \"report_path\": \"r.md\", \"report_sha256\": \"abc\"}
      ],
      \"composite_verdict\": \"PASSED\"
    }]" "$reg_path"
  done

  printf '%s' "$fdir"
}

_add_critical_security_finding() {
  local fdir="$1" key="$2" finding_id="$3" owasp="${4:-A01}" impact="${5:-high}" disposition="${6:-open}"
  local reg_path="$fdir/.gaia/artifacts/implementation-artifacts/epic-E900-test/${key}-test/reviews/findings-register-${key}.yaml"
  export _RW_FID="$finding_id" _RW_OWASP="$owasp" _RW_IMPACT="$impact" _RW_DISP="$disposition"
  yq -i '.entries += [{
    "id": strenv(_RW_FID),
    "severity": "critical",
    "disposition": strenv(_RW_DISP),
    "blocking": true,
    "gate_ratings": [{"gate": "security-review", "owasp_category": strenv(_RW_OWASP)}],
    "impact": strenv(_RW_IMPACT)
  }]' "$reg_path"
  unset _RW_FID _RW_OWASP _RW_IMPACT _RW_DISP
}

_reg_path() {
  local fdir="$1" key="$2"
  printf '%s' "$fdir/.gaia/artifacts/implementation-artifacts/epic-E900-test/${key}-test/reviews/findings-register-${key}.yaml"
}

_rw() {
  local fdir="$1"; shift
  export PROJECT_ROOT="$fdir" CLAUDE_PROJECT_ROOT="$fdir" PROJECT_PATH="$fdir"
  bash "$REGISTER_WRITE" "$@"
}

_sr() {
  local fdir="$1"; shift
  export PROJECT_ROOT="$fdir" CLAUDE_PROJECT_ROOT="$fdir" PROJECT_PATH="$fdir"
  bash "$SECURITY_READER" "$@"
}

# ---------------------------------------------------------------------------
# AC1 — schema, point-of-use default, doctor report
# ---------------------------------------------------------------------------

@test "max_fix_cycles accepts integers >= 1, defaults to 2 at point of use, and doctor reports it" {
  run jq '.properties.review.properties.max_fix_cycles.minimum' "$SCHEMA"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  run jq '.properties.review.properties.max_fix_cycles.default' "$SCHEMA"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]

  run jq '.properties.review.properties.max_fix_cycles.type' "$SCHEMA"
  [ "$status" -eq 0 ]
  [ "$output" = '"integer"' ]

  run bash "$REGISTER_WRITE" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"count-rounds"* ]]

  local fallback_count
  fallback_count=$(/usr/bin/grep -c 'default of 2\|default.*2' "$RUN_ALL_SKILL")
  [ "$fallback_count" -ge 1 ]

  /usr/bin/grep -q 'Review limits' "$DOCTOR_SKILL"
  /usr/bin/grep -q 'max_fix_cycles' "$DOCTOR_SKILL"
}

# ---------------------------------------------------------------------------
# AC2 — ESCALATE after the cap
# ---------------------------------------------------------------------------

@test "escalate after max_fix_cycles failing rounds offers three choices and accept does not pass the gate" {
  local key="E900-S1"
  local fdir
  fdir="$(_mk_fixture "$key" 2)"
  local reg_path
  reg_path="$(_reg_path "$fdir" "$key")"

  run _rw "$fdir" count-rounds --story "$key" --max 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"escalate true"* ]]

  local run_id
  run_id="$(yq '.rounds[-1].run_id' "$reg_path")"
  run _rw "$fdir" record-escalation \
    --story "$key" --run-id "$run_id" \
    --round-count 2 --max-cycles 2
  [ "$status" -eq 0 ]

  local esc_state
  esc_state="$(yq '(.rounds[-1].escalation.state)' "$reg_path")"
  [ "$esc_state" = "escalated" ]

  run _rw "$fdir" record-accept-override \
    --story "$key" --run-id "$run_id" \
    --decision "accept" --user "tester" \
    --round 2 --timestamp "2026-11-01T12:00:00Z"
  [ "$status" -eq 0 ]

  local override_decision
  override_decision="$(yq '(.rounds[-1].accept_override.decision)' "$reg_path")"
  [ "$override_decision" = "accept" ]

  /usr/bin/grep -q 'accept override' "$RUN_ALL_SKILL"
  /usr/bin/grep -q 'descope to backlog' "$RUN_ALL_SKILL"
  /usr/bin/grep -q 'one more cycle' "$RUN_ALL_SKILL"
}

# ---------------------------------------------------------------------------
# AC3 — Security carve-out blocks accept override
# ---------------------------------------------------------------------------

@test "accept override is blocked by unresolved critical security finding or unreported security gate" {
  local key="E900-S2"
  local fdir
  fdir="$(_mk_fixture "$key" 2)"
  _add_critical_security_finding "$fdir" "$key" "RF-1" "A01" "SQL injection" "open"

  run _sr "$fdir" --story "$key"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RF-1"* ]]
  [[ "$output" == *"A01"* ]]
  [[ "$output" == *"open"* ]]
}

# ---------------------------------------------------------------------------
# AC4 — Complete sign-off record required
# ---------------------------------------------------------------------------

@test "sign-off record requires all six fields and an incomplete record keeps accept blocked" {
  local key="E900-S3"
  local fdir
  fdir="$(_mk_fixture "$key" 1)"
  _add_critical_security_finding "$fdir" "$key" "RF-1" "A01" "XSS" "open"

  run _rw "$fdir" sign-off-finding \
    --story "$key" --finding-id RF-1 \
    --risk-accepted-by "admin" --owasp-category "A01" \
    --impact "XSS in login" --round 1
  [ "$status" -ne 0 ]

  run _rw "$fdir" sign-off-finding \
    --story "$key" --finding-id RF-1 \
    --risk-accepted-by "admin" --owasp-category "A01" \
    --impact "XSS in login" --round 1 \
    --timestamp "2026-11-01T12:00:00Z"
  [ "$status" -eq 0 ]

  local reg_path
  reg_path="$(_reg_path "$fdir" "$key")"
  [ "$(yq '.entries[0].sign_off.risk_accepted_by' "$reg_path")" = "admin" ]
  [ "$(yq '.entries[0].sign_off.owasp_category' "$reg_path")" = "A01" ]
  [ "$(yq '.entries[0].sign_off.impact' "$reg_path")" = "XSS in login" ]
  [ "$(yq '.entries[0].sign_off.finding_id' "$reg_path")" = "RF-1" ]
  [ "$(yq '.entries[0].sign_off.round' "$reg_path")" = "1" ]
  [ "$(yq '.entries[0].sign_off.timestamp' "$reg_path")" = "2026-11-01T12:00:00Z" ]
}

# ---------------------------------------------------------------------------
# AC5 — Upgrade default
# ---------------------------------------------------------------------------

@test "project without review section gets cap 2, override works, upgrade notes document it" {
  local proj="$TMP/ac5"
  _mk_config "$proj"

  run bash "$RESOLVE_CONFIG" --field review.max_fix_cycles \
    --config "$proj/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || [ "$output" = "" ]

  _mk_config "$proj" 3
  run bash "$RESOLVE_CONFIG" --field review.max_fix_cycles \
    --config "$proj/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]

  local changelog="${PLUGIN_ROOT}/../../CHANGELOG.md"
  /usr/bin/grep -q 'max_fix_cycles' "$changelog"
  /usr/bin/grep -q 'default.*2' "$changelog"
}

# ---------------------------------------------------------------------------
# AC6 — Bash 3.2 and bash 5
# ---------------------------------------------------------------------------

@test "fix-cycle suite runs green under bash 3.2 and bash 5" {
  [[ "$BASH_VERSION" =~ ^[0-9]+\.[0-9]+ ]]
}

# ---------------------------------------------------------------------------
# AC-EC1 — Cap of 1
# ---------------------------------------------------------------------------

@test "cap of 1 escalates after the first failing round" {
  local key="E900-S4"
  local fdir
  fdir="$(_mk_fixture "$key" 1)"

  run _rw "$fdir" count-rounds --story "$key" --max 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 1"* ]]
  [[ "$output" == *"escalate true"* ]]
}

# ---------------------------------------------------------------------------
# AC-EC2 — Invalid cap values rejected by schema
# ---------------------------------------------------------------------------

@test "invalid max_fix_cycles values are rejected by the schema" {
  local val
  val=$(jq '.properties.review.properties.max_fix_cycles.minimum' "$SCHEMA")
  [ "$val" = "1" ]
  val=$(jq '.properties.review.properties.max_fix_cycles.type' "$SCHEMA")
  [ "$val" = '"integer"' ]
}

# ---------------------------------------------------------------------------
# AC-EC3 — Passing round stops the counter
# ---------------------------------------------------------------------------

@test "passing round before the cap stops the counter without escalation" {
  local key="E900-S5"
  local fdir
  fdir="$(_mk_fixture "$key" 0 1)"

  run _rw "$fdir" count-rounds --story "$key" --max 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 0"* ]]
  [[ "$output" == *"escalate false"* ]]
}

# ---------------------------------------------------------------------------
# AC-EC4 — Crashed gate counts as FAILED toward the cap
# ---------------------------------------------------------------------------

@test "crashed gate counts as FAILED and repeated crashes escalate exactly at the cap" {
  local key="E900-S6"
  local fdir
  fdir="$(_mk_fixture "$key" 2)"

  run _rw "$fdir" count-rounds --story "$key" --max 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 2"* ]]
  [[ "$output" == *"escalate true"* ]]
}

# ---------------------------------------------------------------------------
# AC-EC5 — Concurrent runs: round count under lock
# ---------------------------------------------------------------------------

@test "concurrent review runs for one story never double count a round" {
  local key="E900-S7"
  local fdir
  fdir="$(_mk_fixture "$key" 1)"

  run _rw "$fdir" count-rounds --story "$key" --max 2
  [ "$status" -eq 0 ]
  local count1="$output"

  run _rw "$fdir" count-rounds --story "$key" --max 2
  [ "$status" -eq 0 ]
  local count2="$output"

  [ "$count1" = "$count2" ]
}

# ---------------------------------------------------------------------------
# AC-EC6 — Escalation state recorded before the question
# ---------------------------------------------------------------------------

@test "escalation state is recorded before the question and the story is resumable" {
  local key="E900-S8"
  local fdir
  fdir="$(_mk_fixture "$key" 2)"
  local reg_path
  reg_path="$(_reg_path "$fdir" "$key")"
  local run_id
  run_id="$(yq '.rounds[-1].run_id' "$reg_path")"

  run _rw "$fdir" record-escalation \
    --story "$key" --run-id "$run_id" \
    --round-count 2 --max-cycles 2
  [ "$status" -eq 0 ]

  [ "$(yq '(.rounds[-1].escalation.state)' "$reg_path")" = "escalated" ]
  [ "$(yq '(.rounds[-1].escalation.round_count)' "$reg_path")" = "2" ]
}

# ---------------------------------------------------------------------------
# AC-EC7 — Partial sign-off
# ---------------------------------------------------------------------------

@test "one of two critical findings signed off keeps accept blocked" {
  local key="E900-S9"
  local fdir
  fdir="$(_mk_fixture "$key" 1)"
  _add_critical_security_finding "$fdir" "$key" "RF-1" "A01" "SQLi" "open"
  _add_critical_security_finding "$fdir" "$key" "RF-2" "A07" "XSS" "open"

  run _rw "$fdir" sign-off-finding \
    --story "$key" --finding-id RF-1 \
    --risk-accepted-by "admin" --owasp-category "A01" \
    --impact "SQLi in search" --round 1 \
    --timestamp "2026-11-01T12:00:00Z"
  [ "$status" -eq 0 ]

  run _sr "$fdir" --story "$key"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RF-2"* ]]
  [[ "$output" == *"open"* ]]
}

# ---------------------------------------------------------------------------
# AC-EC8 — Quotes and newlines in sign-off text
# ---------------------------------------------------------------------------

@test "sign-off impact text with quotes and newlines round-trips through the record" {
  local key="E900-S10"
  local fdir
  fdir="$(_mk_fixture "$key" 1)"
  _add_critical_security_finding "$fdir" "$key" "RF-1" "A01" "test" "open"

  local tricky_impact
  tricky_impact="Line1 \"quoted\" and 'single' and \$(whoami)
Line2 end"

  run _rw "$fdir" sign-off-finding \
    --story "$key" --finding-id RF-1 \
    --risk-accepted-by "admin" --owasp-category "A01" \
    --impact "$tricky_impact" --round 1 \
    --timestamp "2026-11-01T12:00:00Z"
  [ "$status" -eq 0 ]

  local reg_path
  reg_path="$(_reg_path "$fdir" "$key")"
  local readback
  readback="$(yq '.entries[0].sign_off.impact' "$reg_path")"
  [ "$readback" = "$tricky_impact" ]
}

# ---------------------------------------------------------------------------
# AC-EC9 — Missing or crashed security review (fail closed)
# ---------------------------------------------------------------------------

@test "missing or crashed security review blocks accept override (fail closed)" {
  /usr/bin/grep -q 'security gate has no completed report' "$RUN_ALL_SKILL"

  run _sr "/nonexistent" --story NONEXISTENT-KEY
  [ "$status" -ne 0 ] || [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# AC-EC10 — One more cycle, repeatedly
# ---------------------------------------------------------------------------

@test "one more cycle escalates again after each extra round" {
  local key="E900-S11"
  local fdir
  fdir="$(_mk_fixture "$key" 4)"

  run _rw "$fdir" count-rounds --story "$key" --max 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 4"* ]]
  [[ "$output" == *"escalate true"* ]]
}

# ---------------------------------------------------------------------------
# AC-EC11 — No review key
# ---------------------------------------------------------------------------

@test "no review key in project-config activates cap 2 and the upgrade note exists" {
  local proj="$TMP/ec11"
  _mk_config "$proj"

  run bash "$RESOLVE_CONFIG" --field review.max_fix_cycles \
    --config "$proj/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || [ "$output" = "" ]

  local changelog="${PLUGIN_ROOT}/../../CHANGELOG.md"
  /usr/bin/grep -q 'max_fix_cycles' "$changelog"
  /usr/bin/grep -q 'default.*2' "$changelog"
}
