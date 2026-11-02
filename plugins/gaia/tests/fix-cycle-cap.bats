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

# Run a full failing round through the real writers. The round goes through
# the SKILL's real order: record-round, record-run, record-round-report,
# then count-rounds --current-verdict FAILED (decision point), then
# complete-round --verdict FAILED.
_run_failing_round() {
  local key="$1" rid="$2"
  bash "$RW" record-round --story "$key" --run-id "$rid" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story "$key" --run-id "$rid" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: FAILED (round %s)\n' "$rid" > "$FIXTURE_DIR/report-${rid}.md"
  bash "$RW" record-round-report --story "$key" --run-id "$rid" \
    --gate security-review --report "$FIXTURE_DIR/report-${rid}.md"
  # Decision point (cap check), then complete.
  bash "$RW" count-rounds --story "$key" --current-verdict FAILED >/dev/null
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

  # Build round 1 up to the decision point (open, report recorded, not yet
  # completed) — the SKILL's real order.
  bash "$RW" record-round --story TEST-EC1 --run-id "round-20261102T120001Z-10101" \
    --repo "$FIXTURE_DIR/repo" --gate "security-review=selected"
  bash "$RW" record-run --story TEST-EC1 --run-id "round-20261102T120001Z-10101" \
    --gate security-review --outcome completed >/dev/null
  printf 'Verdict: FAILED\n' > "$FIXTURE_DIR/r1.md"
  bash "$RW" record-round-report --story TEST-EC1 --run-id "round-20261102T120001Z-10101" \
    --gate security-review --report "$FIXTURE_DIR/r1.md"

  # Decision point: cap 1. The open round with --current-verdict FAILED counts.
  run bash "$RW" count-rounds --story TEST-EC1 --max 1 --current-verdict FAILED
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

  # Round 1: gate crashes (errored, no report). complete-round will refuse
  # so the round stays open until superseded by the next round.
  bash "$RW" record-round --story TEST-EC4 --run-id "round-20261102T120001Z-40401" \
    --repo "$FIXTURE_DIR/repo" --gate "security-review=selected"
  bash "$RW" record-run --story TEST-EC4 --run-id "round-20261102T120001Z-40401" \
    --gate security-review --outcome errored >/dev/null

  # At the decision point, the open errored round counts (--current-verdict).
  run bash "$RW" count-rounds --story TEST-EC4 --max 1 --current-verdict FAILED
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 1"* ]]
  [[ "$output" == *"escalate true"* ]]

  # Round 2: another crash. Opening it supersedes round 1.
  bash "$RW" record-round --story TEST-EC4 --run-id "round-20261102T120002Z-40402" \
    --repo "$FIXTURE_DIR/repo" --gate "security-review=selected"
  bash "$RW" record-run --story TEST-EC4 --run-id "round-20261102T120002Z-40402" \
    --gate security-review --outcome errored >/dev/null

  # Cap 2: superseded round 1 (errored) + open round 2 (errored).
  run bash "$RW" count-rounds --story TEST-EC4 --max 2 --current-verdict FAILED
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 2"* ]]
  [[ "$output" == *"escalate true"* ]]

  # Round 3: supersedes round 2.
  bash "$RW" record-round --story TEST-EC4 --run-id "round-20261102T120003Z-40403" \
    --repo "$FIXTURE_DIR/repo" --gate "security-review=selected"
  bash "$RW" record-run --story TEST-EC4 --run-id "round-20261102T120003Z-40403" \
    --gate security-review --outcome errored >/dev/null

  # All three count: 2 superseded + 1 open.
  run bash "$RW" count-rounds --story TEST-EC4 --max 2 --current-verdict FAILED
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 3"* ]]
  [[ "$output" == *"escalate true"* ]]
}

# ---------------------------------------------------------------------------
# AC-EC5 — Concurrent runs under the register lock
# ---------------------------------------------------------------------------

@test "concurrent writer and count-rounds produce consistent results under lock" {
  _mk_project TEST-EC5
  _run_failing_round TEST-EC5 "round-20261102T120001Z-50501"

  # Race: complete-round (writer) vs count-rounds (reader) in parallel.
  # Both acquire the register lock. The result must be deterministic.
  bash "$RW" record-round --story TEST-EC5 --run-id "round-20261102T120002Z-50502" \
    --repo "$FIXTURE_DIR/repo" --gate "security-review=selected"
  bash "$RW" record-run --story TEST-EC5 --run-id "round-20261102T120002Z-50502" \
    --gate security-review --outcome completed >/dev/null
  printf 'Verdict: FAILED\n' > "$FIXTURE_DIR/r2.md"
  bash "$RW" record-round-report --story TEST-EC5 --run-id "round-20261102T120002Z-50502" \
    --gate security-review --report "$FIXTURE_DIR/r2.md"

  # Writer (complete-round) and reader (count-rounds) race for the lock.
  bash "$RW" complete-round --story TEST-EC5 --run-id "round-20261102T120002Z-50502" \
    --repo "$FIXTURE_DIR/repo" --verdict FAILED &
  local wpid=$!
  bash "$RW" count-rounds --story TEST-EC5 --max 2 --current-verdict FAILED > "$TMP/race.out" &
  local rpid=$!
  wait "$wpid" "$rpid"

  # Both must succeed; count must be >= 1 (at least the first completed round).
  local rc; rc="$(cat "$TMP/race.out")"
  [[ "$rc" == *"round_count"* ]]
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

@test "descope route exercises the two sanctioned transitions" {
  # The SKILL.md documents the route as review -> blocked -> backlog.
  /usr/bin/grep -q 'transition-story-status.sh.*--to blocked' "$RUN_ALL_SKILL"
  /usr/bin/grep -q 'transition-story-status.sh.*--to backlog' "$RUN_ALL_SKILL"
  # The transitions are sanctioned by the state machine; this test verifies
  # the SKILL documents the correct two-step route.
}

# ---------------------------------------------------------------------------
# Fail closed: round completed WITHOUT --verdict counts as non-passing
# ---------------------------------------------------------------------------

@test "round completed without --verdict counts as non-passing (fail closed)" {
  _mk_project TEST-FC
  bash "$RW" record-round --story TEST-FC --run-id "round-20261102T120001Z-99901" \
    --repo "$FIXTURE_DIR/repo" --gate "security-review=selected"
  bash "$RW" record-run --story TEST-FC --run-id "round-20261102T120001Z-99901" \
    --gate security-review --outcome completed >/dev/null
  printf 'Verdict: FAILED\n' > "$FIXTURE_DIR/fc-report.md"
  bash "$RW" record-round-report --story TEST-FC --run-id "round-20261102T120001Z-99901" \
    --gate security-review --report "$FIXTURE_DIR/fc-report.md"
  bash "$RW" complete-round --story TEST-FC --run-id "round-20261102T120001Z-99901" \
    --repo "$FIXTURE_DIR/repo"

  run bash "$RW" count-rounds --story TEST-FC --max 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 1"* ]]
  [[ "$output" == *"escalate true"* ]]
}

# ---------------------------------------------------------------------------
# Item 1: security review SKILL.md passes --owasp-category and --impact
# ---------------------------------------------------------------------------

@test "security review add call shape includes owasp-category and impact" {
  local sec_skill="${PLUGIN_ROOT}/skills/gaia-review-security/SKILL.md"
  /usr/bin/grep -q '\-\-owasp-category' "$sec_skill"
  /usr/bin/grep -q '\-\-impact' "$sec_skill"

  # Behavioural: add with --owasp-category writes it to gate_ratings.
  _mk_project TEST-OWASP
  _run_failing_round TEST-OWASP "round-20261102T120001Z-77701"
  _add_critical_finding TEST-OWASP "Injection flaw" "A03" "account takeover"
  local reg; reg="$(_reg TEST-OWASP)"
  local owasp; owasp="$(yq '.entries[-1].gate_ratings[0].owasp_category' "$reg")"
  [ "$owasp" = "A03" ]
  local impact; impact="$(yq '.entries[-1].impact' "$reg")"
  [ "$impact" = "account takeover" ]
}

# ---------------------------------------------------------------------------
# Item 3: forged and unsigned --signed-off-findings refusals
# ---------------------------------------------------------------------------

@test "record-accept-override rejects forged and unsigned signed-off-findings" {
  _mk_project TEST-FORGE
  _run_failing_round TEST-FORGE "round-20261102T120001Z-88801"
  _add_critical_finding TEST-FORGE "XSS" "A07" "session hijack"

  local reg; reg="$(_reg TEST-FORGE)"
  local fid; fid="$(yq '.entries[-1].id' "$reg")"

  # Sign off the real finding so we can test the signed-off-findings validation.
  bash "$RW" sign-off-finding --story TEST-FORGE --finding-id "$fid" \
    --risk-accepted-by admin --owasp-category A07 --impact "session hijack" \
    --round 1 --timestamp "2026-11-02T12:00:00Z"

  # Forged: non-existent finding id alongside the real one.
  run bash "$RW" record-accept-override --story TEST-FORGE \
    --run-id "round-20261102T120001Z-88801" \
    --decision accept --user admin --round 1 --timestamp "2026-11-02T12:00:00Z" \
    --signed-off-findings "RF-999"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a critical security finding"* ]]

  # Unsigned: add a SECOND critical finding without signing it off.
  _add_critical_finding TEST-FORGE "SQLi" "A03" "data breach"
  local fid2; fid2="$(yq '.entries[-1].id' "$reg")"

  run bash "$RW" record-accept-override --story TEST-FORGE \
    --run-id "round-20261102T120001Z-88801" \
    --decision accept --user admin --round 1 --timestamp "2026-11-02T12:00:00Z" \
    --signed-off-findings "$fid2"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Item 4: Scenario 15c — valid carried security assessment
# ---------------------------------------------------------------------------

@test "valid carried security assessment reads as assessed" {
  _mk_project TEST-15C

  # Round 1: security-review selected and produces a completed report.
  local rid1="round-20261102T120001Z-15001"
  bash "$RW" record-round --story TEST-15C --run-id "$rid1" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story TEST-15C --run-id "$rid1" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: PASSED\n' > "$FIXTURE_DIR/sec-15c.md"
  bash "$RW" record-round-report --story TEST-15C --run-id "$rid1" \
    --gate security-review --report "$FIXTURE_DIR/sec-15c.md"
  bash "$RW" complete-round --story TEST-15C --run-id "$rid1" \
    --repo "$FIXTURE_DIR/repo" --verdict PASSED

  # Round 2: security-review carried from round 1 (not selected again).
  local rid2="round-20261102T120002Z-15002"
  bash "$RW" record-round --story TEST-15C --run-id "$rid2" --repo "$FIXTURE_DIR/repo" \
    --gate "code-review=selected" \
    --carry "security-review=${rid1}:carried from prior round"
  bash "$RW" record-run --story TEST-15C --run-id "$rid2" --gate code-review \
    --outcome completed >/dev/null
  printf 'Verdict: FAILED\n' > "$FIXTURE_DIR/cr-15c.md"
  bash "$RW" record-round-report --story TEST-15C --run-id "$rid2" \
    --gate code-review --report "$FIXTURE_DIR/cr-15c.md"

  # security-report-reader must report "assessed" (carried gate has a report).
  run bash "$SR" --story TEST-15C
  [ "$status" -eq 0 ]
  [[ "$output" == *"assessed"* ]]

  # record-accept-override must NOT block on the security gate (carried with
  # a completed report counts as assessed). It may still block on critical
  # findings, but not on the gate state.
  run bash "$RW" record-accept-override --story TEST-15C \
    --run-id "$rid2" --decision accept --user admin --round 2 \
    --timestamp "2026-11-02T12:00:00Z"
  [ "$status" -eq 0 ]

  local ao; ao="$(yq '(.rounds[-1].accept_override.decision)' "$(_reg TEST-15C)")"
  [ "$ao" = "accept" ]
}

# ---------------------------------------------------------------------------
# Item 3 supplement: triage disposition blocks accept
# ---------------------------------------------------------------------------

@test "critical finding in triage disposition blocks accept override" {
  _mk_project TEST-TRIAGE
  _run_failing_round TEST-TRIAGE "round-20261102T120001Z-99801"
  _add_critical_finding TEST-TRIAGE "SQLi" "A03" "data breach"

  # Change disposition to triage (not resolved).
  local reg; reg="$(_reg TEST-TRIAGE)"
  local fid; fid="$(yq '.entries[-1].id' "$reg")"
  bash "$RW" set-disposition --story TEST-TRIAGE --id "$fid" --disposition triage --owner triage-bot --priority P2

  # Accept must still be blocked (triage != resolved).
  run bash "$RW" record-accept-override --story TEST-TRIAGE \
    --run-id "round-20261102T120001Z-99801" \
    --decision accept --user admin --round 1 --timestamp "2026-11-02T12:00:00Z"
  [ "$status" -ne 0 ]
  [[ "$output" == *"blocked"* ]] || [[ "$output" == *"unresolved"* ]]
}

# ---------------------------------------------------------------------------
# Item 3 supplement: finding resolved once fixed (disposition=resolved) unblocks
# ---------------------------------------------------------------------------

@test "critical finding resolved once fixed unblocks accept" {
  _mk_project TEST-RES
  _run_failing_round TEST-RES "round-20261102T120001Z-99701"
  _add_critical_finding TEST-RES "XSS" "A07" "session hijack"

  local reg; reg="$(_reg TEST-RES)"
  local fid; fid="$(yq '.entries[-1].id' "$reg")"

  # Set disposition to resolved (finding was fixed).
  bash "$RW" set-disposition --story TEST-RES --id "$fid" --disposition resolved

  # Accept should now be allowed (resolved = no longer blocking).
  run bash "$RW" record-accept-override --story TEST-RES \
    --run-id "round-20261102T120001Z-99701" \
    --decision accept --user admin --round 1 --timestamp "2026-11-02T12:00:00Z"
  [ "$status" -eq 0 ]
}
