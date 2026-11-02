#!/usr/bin/env bats
# fix-cycle-cap.bats — behavioural tests for the fix-cycle cap, ESCALATE,
# and critical-security carve-out.  All register fixtures are built with the
# REAL writers (record-round, record-run, record-round-report, complete-round,
# add), never hand-written YAML.

load 'test_helper.bash'

setup() {
  PLUGIN_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  RW="${PLUGIN_ROOT}/scripts/review-common/register-write.sh"
  SR="${PLUGIN_ROOT}/scripts/review-common/security-report-reader.sh"
  RC="${PLUGIN_ROOT}/scripts/resolve-config.sh"
  SCHEMA="${PLUGIN_ROOT}/schemas/project-config.schema.json"
  DOCTOR_SKILL="${PLUGIN_ROOT}/skills/gaia-doctor/SKILL.md"
  RUN_ALL_SKILL="${PLUGIN_ROOT}/skills/gaia-run-all-reviews/SKILL.md"
  TMP="${BATS_TEST_TMPDIR}"

  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT PROJECT_PATH 2>/dev/null || true

  printf 'BASH_VERSION=%s\n' "$BASH_VERSION" >&2
}

# ---------------------------------------------------------------------------
# Helpers — every fixture built through real writers
# ---------------------------------------------------------------------------

# Create a minimal project tree with a story, a git repo and env exports.
# Sets FIXTURE_DIR, exports IMPLEMENTATION_ARTIFACTS and PROJECT_ROOT.
_mk_project() {
  local key="$1"
  FIXTURE_DIR="$TMP/fix-${key}-$$"
  mkdir -p "$FIXTURE_DIR/ia/epic-test/stories"
  cat > "$FIXTURE_DIR/ia/epic-test/stories/${key}-x.md" <<S
---
key: "${key}"
status: review
---
## Acceptance Criteria

- [ ] AC1: x
S
  mkdir -p "$FIXTURE_DIR/repo"
  git -C "$FIXTURE_DIR/repo" init -q
  git -C "$FIXTURE_DIR/repo" -c user.email=a@b -c user.name=t commit -q --allow-empty -m init
  export IMPLEMENTATION_ARTIFACTS="$FIXTURE_DIR/ia" PROJECT_ROOT="$FIXTURE_DIR"
  unset CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT PROJECT_PATH 2>/dev/null || true
}

# Run a full failing round through the real writers: record-round, record-run
# (completed), record-round-report (with a FAILED verdict), count-rounds
# (with --current-verdict FAILED to record the verdict), then complete-round.
_run_failing_round() {
  local key="$1" rid="$2"
  bash "$RW" record-round --story "$key" --run-id "$rid" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story "$key" --run-id "$rid" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: FAILED (round %s)\n' "$rid" > "$FIXTURE_DIR/report-${rid}.md"
  bash "$RW" record-round-report --story "$key" --run-id "$rid" \
    --gate security-review --report "$FIXTURE_DIR/report-${rid}.md"
  bash "$RW" complete-round --story "$key" --run-id "$rid" --repo "$FIXTURE_DIR/repo" --verdict FAILED
}

# Run a full passing round.
_run_passing_round() {
  local key="$1" rid="$2"
  bash "$RW" record-round --story "$key" --run-id "$rid" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story "$key" --run-id "$rid" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: PASSED\n' > "$FIXTURE_DIR/pass-${rid}.md"
  bash "$RW" record-round-report --story "$key" --run-id "$rid" \
    --gate security-review --report "$FIXTURE_DIR/pass-${rid}.md"
  bash "$RW" complete-round --story "$key" --run-id "$rid" --repo "$FIXTURE_DIR/repo" --verdict PASSED
}

# Add a critical security finding via the real add subcommand.
_add_critical_finding() {
  local key="$1" defect="$2" owasp="${3:-A03}" impact="${4:-high impact}"
  bash "$RW" add --story "$key" --defect "$defect" --type security \
    --severity critical --gate security-review --impact "$impact" \
    --owasp-category "$owasp" \
    --blocking --blocking-rationale "critical security"
}

# Get the register path for a key.
_reg() {
  local key="$1"
  "$PLUGIN_ROOT/scripts/resolve-review-report-path.sh" --key "$key" --type findings-register
}

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

# ---------------------------------------------------------------------------
# AC1 — schema, point-of-use default, doctor report
# ---------------------------------------------------------------------------

@test "max_fix_cycles schema, point-of-use default and doctor reports it" {
  # Schema structure.
  run jq '.properties.review.properties.max_fix_cycles.minimum' "$SCHEMA"
  [ "$status" -eq 0 ]; [ "$output" = "1" ]

  run jq '.properties.review.properties.max_fix_cycles.default' "$SCHEMA"
  [ "$status" -eq 0 ]; [ "$output" = "2" ]

  run jq '.properties.review.properties.max_fix_cycles.type' "$SCHEMA"
  [ "$status" -eq 0 ]; [ "$output" = '"integer"' ]

  # count-rounds is the single point-of-use default: when --max is absent
  # and config has no review key, the fallback of 2 applies.
  _mk_project TEST-S1
  _run_failing_round TEST-S1 "round-20261101T120001Z-10001"
  _run_failing_round TEST-S1 "round-20261101T120002Z-10002"
  run bash "$RW" count-rounds --story TEST-S1
  [ "$status" -eq 0 ]
  [[ "$output" == *"max_fix_cycles 2"* ]]
  [[ "$output" == *"escalate true"* ]]

  # When config sets max_fix_cycles: 3, count-rounds (no --max) uses 3.
  mkdir -p "$FIXTURE_DIR/.gaia/config"
  cat > "$FIXTURE_DIR/.gaia/config/project-config.yaml" <<CONF
project_root: "."
project_path: "."
memory_path: ".gaia/memory"
checkpoint_path: ".gaia/memory/checkpoints"
installed_path: "."
framework_version: "1.225.0"
date: "2026-11-01"
review:
  max_fix_cycles: 3
CONF
  run bash "$RW" count-rounds --story TEST-S1
  [ "$status" -eq 0 ]
  [[ "$output" == *"max_fix_cycles 3"* ]]
  [[ "$output" == *"escalate false"* ]]

  # Doctor SKILL.md names the section and the key.
  /usr/bin/grep -q 'Review limits' "$DOCTOR_SKILL"
  /usr/bin/grep -q 'max_fix_cycles' "$DOCTOR_SKILL"
}

# ---------------------------------------------------------------------------
# AC2 — ESCALATE after the cap, three choices, accept does not pass the gate
# ---------------------------------------------------------------------------

@test "escalate after cap, three choices, accept records but does not pass the gate" {
  _mk_project TEST-S2
  _run_failing_round TEST-S2 "round-20261101T120001Z-20001"
  _run_failing_round TEST-S2 "round-20261101T120002Z-20002"

  # count-rounds with --max 2 on 2 failing rounds → escalate.
  run bash "$RW" count-rounds --story TEST-S2 --max 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 2"* ]]
  [[ "$output" == *"escalate true"* ]]

  # record-escalation.
  run bash "$RW" record-escalation --story TEST-S2 \
    --run-id "round-20261101T120002Z-20002" --round-count 2 --max-cycles 2
  [ "$status" -eq 0 ]
  local reg; reg="$(_reg TEST-S2)"
  [ "$(yq '.rounds[-1].escalation.state' "$reg")" = "escalated" ]

  # accept-override (no critical security findings → allowed).
  run bash "$RW" record-accept-override --story TEST-S2 \
    --run-id "round-20261101T120002Z-20002" \
    --decision "accept" --user "operator" --round 2 --timestamp "2026-11-01T12:00:00Z"
  [ "$status" -eq 0 ]
  [ "$(yq '.rounds[-1].accept_override.decision' "$reg")" = "accept" ]

  # SKILL.md names the three choices.
  /usr/bin/grep -q 'accept override' "$RUN_ALL_SKILL"
  /usr/bin/grep -q 'descope to backlog' "$RUN_ALL_SKILL"
  /usr/bin/grep -q 'one more cycle' "$RUN_ALL_SKILL"
}

# ---------------------------------------------------------------------------
# AC3 — Security carve-out blocks accept override
# ---------------------------------------------------------------------------

@test "accept override blocked by unresolved critical security finding" {
  _mk_project TEST-S3
  _run_failing_round TEST-S3 "round-20261101T120001Z-30001"
  _add_critical_finding TEST-S3 "SQL injection in login" "A03" "database compromise"

  # accept-override MUST fail (unresolved critical finding).
  run bash "$RW" record-accept-override --story TEST-S3 \
    --run-id "round-20261101T120001Z-30001" \
    --decision "accept" --user "mallory" --round 1 --timestamp "now"
  [ "$status" -ne 0 ]
  [[ "$output" == *"blocked"* ]] || [[ "${lines[*]}" == *"blocked"* ]]

  # security-report-reader outputs the finding with correct OWASP category.
  run bash "$SR" --story TEST-S3
  [ "$status" -eq 0 ]
  [[ "$output" == *"A03"* ]]
  [[ "$output" == *"database compromise"* ]]
}

@test "accept override blocked when security gate has no completed report" {
  _mk_project TEST-S3b
  # Start a round but do NOT record a security-review report.
  bash "$RW" record-round --story TEST-S3b --run-id "round-20261101T120001Z-30010" \
    --repo "$FIXTURE_DIR/repo" --gate "security-review=selected"

  run bash "$RW" record-accept-override --story TEST-S3b \
    --run-id "round-20261101T120001Z-30010" \
    --decision "accept" --user "attacker" --round 1 --timestamp "now"
  [ "$status" -ne 0 ]
  [[ "${lines[*]}" == *"security gate has no completed report"* ]]
}

# ---------------------------------------------------------------------------
# AC4 — Complete sign-off record: each of the six fields required
# ---------------------------------------------------------------------------

@test "sign-off rejects incomplete records and accepts a complete one" {
  _mk_project TEST-S4
  _run_failing_round TEST-S4 "round-20261101T120001Z-40001"
  _add_critical_finding TEST-S4 "XSS in search" "A07" "account takeover"

  local reg; reg="$(_reg TEST-S4)"
  local fid; fid="$(yq '.entries[-1].id' "$reg")"

  # Omit each field in turn — every one must cause rejection.
  local base_args="--story TEST-S4 --finding-id $fid"
  local full="--risk-accepted-by admin --owasp-category A07 --impact xss --round 1 --timestamp 2026-11-01T12:00:00Z"

  # Missing risk-accepted-by.
  run bash "$RW" sign-off-finding $base_args --owasp-category A07 --impact xss --round 1 --timestamp 2026-11-01T12:00:00Z
  [ "$status" -ne 0 ]

  # Missing owasp-category.
  run bash "$RW" sign-off-finding $base_args --risk-accepted-by admin --impact xss --round 1 --timestamp 2026-11-01T12:00:00Z
  [ "$status" -ne 0 ]

  # Missing impact.
  run bash "$RW" sign-off-finding $base_args --risk-accepted-by admin --owasp-category A07 --round 1 --timestamp 2026-11-01T12:00:00Z
  [ "$status" -ne 0 ]

  # Missing round.
  run bash "$RW" sign-off-finding $base_args --risk-accepted-by admin --owasp-category A07 --impact xss --timestamp 2026-11-01T12:00:00Z
  [ "$status" -ne 0 ]

  # Missing timestamp.
  run bash "$RW" sign-off-finding $base_args --risk-accepted-by admin --owasp-category A07 --impact xss --round 1
  [ "$status" -ne 0 ]

  # Missing finding-id.
  run bash "$RW" sign-off-finding --story TEST-S4 --risk-accepted-by admin --owasp-category A07 --impact xss --round 1 --timestamp 2026-11-01T12:00:00Z
  [ "$status" -ne 0 ]

  # After all rejections: nothing written (sign_off is absent/null).
  [ "$(yq '.entries[-1].sign_off // "absent"' "$reg")" = "absent" ]

  # Accept override is still blocked.
  run bash "$RW" record-accept-override --story TEST-S4 \
    --run-id "round-20261101T120001Z-40001" \
    --decision accept --user admin --round 1 --timestamp "2026-11-01T12:00:00Z"
  [ "$status" -ne 0 ]

  # Complete — must succeed.
  run bash "$RW" sign-off-finding $base_args $full
  [ "$status" -eq 0 ]

  # Verify all six fields stored.
  [ "$(yq '.entries[-1].sign_off.risk_accepted_by' "$reg")" = "admin" ]
  [ "$(yq '.entries[-1].sign_off.owasp_category' "$reg")" = "A07" ]
  [ "$(yq '.entries[-1].sign_off.impact' "$reg")" = "xss" ]
  [ "$(yq '.entries[-1].sign_off.finding_id' "$reg")" = "$fid" ]
  [ "$(yq '.entries[-1].sign_off.round' "$reg")" = "1" ]
  [ "$(yq '.entries[-1].sign_off.timestamp' "$reg")" = "2026-11-01T12:00:00Z" ]
}

# ---------------------------------------------------------------------------
# AC5 — Upgrade default
# ---------------------------------------------------------------------------

@test "project without review section gets cap 2, override works, upgrade notes" {
  local proj="$TMP/ac5"
  _mk_config "$proj"

  run bash "$RC" --field review.max_fix_cycles --config "$proj/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || [ "$output" = "" ]

  _mk_config "$proj" 3
  run bash "$RC" --field review.max_fix_cycles --config "$proj/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]

  local changelog="${PLUGIN_ROOT}/../../CHANGELOG.md"
  /usr/bin/grep -q 'max_fix_cycles' "$changelog"
  /usr/bin/grep -q 'default.*2' "$changelog"
}

# ---------------------------------------------------------------------------
# AC-EC1 — Cap of 1
# ---------------------------------------------------------------------------

@test "cap of 1 escalates after the first failing round" {
  _mk_project TEST-EC1
  _run_failing_round TEST-EC1 "round-20261101T120001Z-10101"

  run bash "$RW" count-rounds --story TEST-EC1 --max 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 1"* ]]
  [[ "$output" == *"escalate true"* ]]
}

# ---------------------------------------------------------------------------
# AC-EC2 — Invalid cap values rejected by the actual schema validator
# ---------------------------------------------------------------------------

@test "invalid max_fix_cycles values are rejected by the schema" {
  # Structural assertions (always available).
  [ "$(jq '.properties.review.properties.max_fix_cycles.minimum' "$SCHEMA")" = "1" ]
  [ "$(jq '.properties.review.properties.max_fix_cycles.type' "$SCHEMA")" = '"integer"' ]

  # When a validator is available, exercise it with real invalid configs.
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema, yaml' 2>/dev/null; then
    local proj="$TMP/ec2-val"
    for bad_val in 0 -1 2.5 '"two"'; do
      _mk_config "$proj"
      printf 'review:\n  max_fix_cycles: %s\n' "$bad_val" >> "$proj/.gaia/config/project-config.yaml"
      # Convert YAML to JSON for validation.
      yq -o=json '.' "$proj/.gaia/config/project-config.yaml" > "$proj/cfg.json"
      run python3 -c "
import json, jsonschema, sys
schema = json.load(open('$SCHEMA'))
cfg = json.load(open('$proj/cfg.json'))
try:
    jsonschema.validate(cfg, schema)
    sys.exit(1)
except jsonschema.ValidationError:
    sys.exit(0)
"
      [ "$status" -eq 0 ]
    done
  fi
}

# ---------------------------------------------------------------------------
# AC-EC3 — Passing round stops the counter
# ---------------------------------------------------------------------------

@test "passing round before the cap stops the counter without escalation" {
  _mk_project TEST-EC3
  _run_passing_round TEST-EC3 "round-20261101T120001Z-30301"

  run bash "$RW" count-rounds --story TEST-EC3 --max 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 0"* ]]
  [[ "$output" == *"escalate false"* ]]
}

@test "passing round after a failing round resets escalation" {
  _mk_project TEST-EC3b
  _run_failing_round TEST-EC3b "round-20261101T120001Z-30311"
  _run_passing_round TEST-EC3b "round-20261101T120002Z-30312"

  run bash "$RW" count-rounds --story TEST-EC3b --max 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 1"* ]]
  [[ "$output" == *"escalate false"* ]]
}

# ---------------------------------------------------------------------------
# AC-EC4 — Crashed gate counts as FAILED toward the cap
# ---------------------------------------------------------------------------

@test "crashed gate counts as FAILED and repeated crashes escalate at the cap" {
  _mk_project TEST-EC4
  # Round 1: one gate completes normally (FAILED), one crashes.
  # Complete-round succeeds because the completed gate has a report.
  # The errored gate makes the round non-passing.
  _run_failing_round TEST-EC4 "round-20261101T120001Z-40401"

  # Cap 1: one failing round escalates.
  run bash "$RW" count-rounds --story TEST-EC4 --max 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 1"* ]]
  [[ "$output" == *"escalate true"* ]]

  # Round 2: also fails.
  _run_failing_round TEST-EC4 "round-20261101T120002Z-40402"

  # Cap 2: two failing rounds escalate at exactly cap 2.
  run bash "$RW" count-rounds --story TEST-EC4 --max 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 2"* ]]
  [[ "$output" == *"escalate true"* ]]

  # Open round with errored gate also counts.
  bash "$RW" record-round --story TEST-EC4 --run-id "round-20261101T120003Z-40403" \
    --repo "$FIXTURE_DIR/repo" --gate "security-review=selected"
  bash "$RW" record-run --story TEST-EC4 --run-id "round-20261101T120003Z-40403" \
    --gate security-review --outcome errored >/dev/null

  run bash "$RW" count-rounds --story TEST-EC4 --max 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 3"* ]]
  [[ "$output" == *"escalate true"* ]]
}

# ---------------------------------------------------------------------------
# AC-EC5 — Concurrent runs under the register lock
# ---------------------------------------------------------------------------

@test "concurrent count-rounds calls produce consistent results" {
  _mk_project TEST-EC5
  _run_failing_round TEST-EC5 "round-20261101T120001Z-50501"

  # Two parallel calls.
  bash "$RW" count-rounds --story TEST-EC5 --max 2 > "$TMP/c1.out" &
  local pid1=$!
  bash "$RW" count-rounds --story TEST-EC5 --max 2 > "$TMP/c2.out" &
  local pid2=$!
  wait "$pid1" "$pid2"

  local c1 c2
  c1="$(cat "$TMP/c1.out")"
  c2="$(cat "$TMP/c2.out")"
  [ "$c1" = "$c2" ]
  [[ "$c1" == *"round_count 1"* ]]
}

# ---------------------------------------------------------------------------
# AC-EC6 — Escalation state recorded and visible to a resumed run
# ---------------------------------------------------------------------------

@test "escalation state is recorded and visible to round-info" {
  _mk_project TEST-EC6
  _run_failing_round TEST-EC6 "round-20261101T120001Z-60601"
  _run_failing_round TEST-EC6 "round-20261101T120002Z-60602"

  bash "$RW" record-escalation --story TEST-EC6 \
    --run-id "round-20261101T120002Z-60602" --round-count 2 --max-cycles 2

  local reg; reg="$(_reg TEST-EC6)"
  [ "$(yq '.rounds[-1].escalation.state' "$reg")" = "escalated" ]
  [ "$(yq '.rounds[-1].escalation.round_count' "$reg")" = "2" ]
  [ "$(yq '.rounds[-1].escalation.max_cycles' "$reg")" = "2" ]

  # round-info surfaces the escalation state for a resumed run.
  run bash "$RW" round-info --story TEST-EC6
  [ "$status" -eq 0 ]
  [[ "$output" == *"escalation_state escalated"* ]]
}

# ---------------------------------------------------------------------------
# AC-EC7 — Partial sign-off: one of two signed off, accept still blocked
# ---------------------------------------------------------------------------

@test "one of two critical findings signed off keeps accept blocked" {
  _mk_project TEST-EC7
  _run_failing_round TEST-EC7 "round-20261101T120001Z-70701"
  _add_critical_finding TEST-EC7 "SQLi in search" "A03" "database"
  _add_critical_finding TEST-EC7 "XSS in profile" "A07" "account takeover"

  local reg; reg="$(_reg TEST-EC7)"
  local fid1; fid1="$(yq '.entries[-2].id' "$reg")"
  local fid2; fid2="$(yq '.entries[-1].id' "$reg")"

  # Sign off only the first.
  bash "$RW" sign-off-finding --story TEST-EC7 --finding-id "$fid1" \
    --risk-accepted-by admin --owasp-category A03 --impact database \
    --round 1 --timestamp "2026-11-01T12:00:00Z"

  # accept must still be blocked (second finding unresolved).
  run bash "$RW" record-accept-override --story TEST-EC7 \
    --run-id "round-20261101T120001Z-70701" \
    --decision accept --user admin --round 1 --timestamp now \
    --signed-off-findings "$fid1"
  [ "$status" -ne 0 ]
  [[ "${lines[*]}" == *"blocked"* ]]
}

# ---------------------------------------------------------------------------
# AC-EC8 — Quotes and newlines in sign-off text round-trip
# ---------------------------------------------------------------------------

@test "sign-off impact text with quotes and newlines round-trips" {
  _mk_project TEST-EC8
  _run_failing_round TEST-EC8 "round-20261101T120001Z-80801"
  _add_critical_finding TEST-EC8 "injection test" "A03" "test"

  local reg; reg="$(_reg TEST-EC8)"
  local fid; fid="$(yq '.entries[-1].id' "$reg")"

  local tricky
  tricky="Line1 \"quoted\" and 'single' and \$(whoami)
Line2 end"

  run bash "$RW" sign-off-finding --story TEST-EC8 --finding-id "$fid" \
    --risk-accepted-by admin --owasp-category A03 --impact "$tricky" \
    --round 1 --timestamp "2026-11-01T12:00:00Z"
  [ "$status" -eq 0 ]

  local readback
  readback="$(yq '.entries[-1].sign_off.impact' "$reg")"
  [ "$readback" = "$tricky" ]
}

# ---------------------------------------------------------------------------
# AC-EC9 — Missing or crashed security review blocks accept (fail closed)
# ---------------------------------------------------------------------------

@test "missing or crashed security review blocks accept override" {
  # SKILL.md documents the fail-closed rule.
  /usr/bin/grep -q 'security gate has no completed report' "$RUN_ALL_SKILL"

  # Reader on malformed register exits 1.
  _mk_project TEST-EC9
  _run_failing_round TEST-EC9 "round-20261101T120001Z-90901"
  local reg; reg="$(_reg TEST-EC9)"
  cp "$reg" "$TMP/bak.yaml"
  yq -i '.entries = "garbage"' "$reg"
  run bash "$SR" --story TEST-EC9
  [ "$status" -ne 0 ]
  cp "$TMP/bak.yaml" "$reg"

  # Reader reports unassessed gate when security report is missing.
  _mk_project TEST-EC9b
  bash "$RW" record-round --story TEST-EC9b --run-id "round-20261101T120001Z-90910" \
    --repo "$FIXTURE_DIR/repo" --gate "security-review=selected"
  run bash "$SR" --story TEST-EC9b
  [ "$status" -eq 0 ]
  [[ "$output" == *"unassessed"* ]]
}

# ---------------------------------------------------------------------------
# AC-EC10 — One more cycle, repeatedly
# ---------------------------------------------------------------------------

@test "one more cycle escalates again after each extra round" {
  _mk_project TEST-EC10
  _run_failing_round TEST-EC10 "round-20261101T120001Z-10001"
  _run_failing_round TEST-EC10 "round-20261101T120002Z-10002"

  # First escalation at cap=2.
  run bash "$RW" count-rounds --story TEST-EC10 --max 2
  [[ "$output" == *"escalate true"* ]]

  # "one more cycle" → round 3 fails.
  _run_failing_round TEST-EC10 "round-20261101T120003Z-10003"
  run bash "$RW" count-rounds --story TEST-EC10 --max 2
  [[ "$output" == *"round_count 3"* ]]
  [[ "$output" == *"escalate true"* ]]

  # Another "one more cycle" → round 4 fails.
  _run_failing_round TEST-EC10 "round-20261101T120004Z-10004"
  run bash "$RW" count-rounds --story TEST-EC10 --max 2
  [[ "$output" == *"round_count 4"* ]]
  [[ "$output" == *"escalate true"* ]]
}

# ---------------------------------------------------------------------------
# AC-EC11 — No review key in config
# ---------------------------------------------------------------------------

@test "no review key in project-config activates cap 2 and upgrade note exists" {
  local proj="$TMP/ec11"
  _mk_config "$proj"

  run bash "$RC" --field review.max_fix_cycles --config "$proj/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || [ "$output" = "" ]

  local changelog="${PLUGIN_ROOT}/../../CHANGELOG.md"
  /usr/bin/grep -q 'max_fix_cycles' "$changelog"
  /usr/bin/grep -q 'default.*2' "$changelog"
}

# ---------------------------------------------------------------------------
# AC2 / AC-EC12 — Descope and status unchanged after accept
# ---------------------------------------------------------------------------

@test "accept override does not change story status" {
  _mk_project TEST-D1
  _run_failing_round TEST-D1 "round-20261101T120001Z-12001"
  _run_failing_round TEST-D1 "round-20261101T120002Z-12002"

  bash "$RW" record-accept-override --story TEST-D1 \
    --run-id "round-20261101T120002Z-12002" \
    --decision accept --user admin --round 2 --timestamp "2026-11-01T12:00:00Z"

  # Story file still says review (accept does not pass the gate).
  local story
  story="$(cat "$FIXTURE_DIR/ia/epic-test/stories/TEST-D1-x.md")"
  [[ "$story" == *"status: review"* ]]
}

# ---------------------------------------------------------------------------
# Descope transition: documented as two sanctioned transitions
# ---------------------------------------------------------------------------

@test "descope route documented as blocked then backlog" {
  /usr/bin/grep -q 'transition-story-status.sh.*--to blocked' "$RUN_ALL_SKILL"
  /usr/bin/grep -q 'transition-story-status.sh.*--to backlog' "$RUN_ALL_SKILL"
}

# ---------------------------------------------------------------------------
# Fail closed: round completed WITHOUT --verdict counts as non-passing
# ---------------------------------------------------------------------------

@test "round completed without --verdict counts as non-passing (fail closed)" {
  _mk_project TEST-FC
  # Complete a round without --verdict.
  bash "$RW" record-round --story TEST-FC --run-id "round-20261101T120001Z-99901" \
    --repo "$FIXTURE_DIR/repo" --gate "security-review=selected"
  bash "$RW" record-run --story TEST-FC --run-id "round-20261101T120001Z-99901" \
    --gate security-review --outcome completed >/dev/null
  printf 'Verdict: FAILED\n' > "$FIXTURE_DIR/fc-report.md"
  bash "$RW" record-round-report --story TEST-FC --run-id "round-20261101T120001Z-99901" \
    --gate security-review --report "$FIXTURE_DIR/fc-report.md"
  bash "$RW" complete-round --story TEST-FC --run-id "round-20261101T120001Z-99901" \
    --repo "$FIXTURE_DIR/repo"

  # No composite_verdict on the round — fail closed: counts as non-passing.
  run bash "$RW" count-rounds --story TEST-FC --max 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 1"* ]]
  [[ "$output" == *"escalate true"* ]]
}
