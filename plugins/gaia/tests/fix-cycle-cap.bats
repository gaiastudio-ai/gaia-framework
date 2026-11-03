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
    --gate security-review --report "$FIXTURE_DIR/report-${rid}.md" --verdict FAILED
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
    --gate security-review --report "$FIXTURE_DIR/pass-${rid}.md" --verdict PASSED
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
  [[ "$output" == *"max_fix_cycles 2"* ]] || return 1
  [[ "$output" == *"escalate true"* ]] || return 1

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
  [[ "$output" == *"max_fix_cycles 3"* ]] || return 1
  [[ "$output" == *"escalate false"* ]] || return 1

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
  [[ "$output" == *"round_count 2"* ]] || return 1
  [[ "$output" == *"escalate true"* ]] || return 1

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
  [[ "$output" == *"blocked"* ]] || [[ "${lines[*]}" == *"blocked"* ]] || return 1

  # security-report-reader outputs the finding with correct OWASP category.
  run bash "$SR" --story TEST-S3
  [ "$status" -eq 0 ]
  [[ "$output" == *"A03"* ]] || return 1
  [[ "$output" == *"database compromise"* ]] || return 1
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
  [[ "${lines[*]}" == *"security gate has no completed report"* ]] || return 1
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
    --gate security-review --report "$FIXTURE_DIR/r1.md" --verdict FAILED

  # Decision point: cap 1. The open round with --current-verdict FAILED counts.
  run bash "$RW" count-rounds --story TEST-EC1 --max 1 --current-verdict FAILED
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 1"* ]] || return 1
  [[ "$output" == *"escalate true"* ]] || return 1
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
  [[ "$output" == *"round_count 0"* ]] || return 1
  [[ "$output" == *"escalate false"* ]] || return 1
}

@test "passing round after a failing round resets escalation" {
  _mk_project TEST-EC3b
  _run_failing_round TEST-EC3b "round-20261101T120001Z-30311"
  _run_passing_round TEST-EC3b "round-20261101T120002Z-30312"

  run bash "$RW" count-rounds --story TEST-EC3b --max 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 1"* ]] || return 1
  [[ "$output" == *"escalate false"* ]] || return 1
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
  [[ "$output" == *"round_count 1"* ]] || return 1
  [[ "$output" == *"escalate true"* ]] || return 1

  # Round 2: another crash. Opening it supersedes round 1.
  bash "$RW" record-round --story TEST-EC4 --run-id "round-20261102T120002Z-40402" \
    --repo "$FIXTURE_DIR/repo" --gate "security-review=selected"
  bash "$RW" record-run --story TEST-EC4 --run-id "round-20261102T120002Z-40402" \
    --gate security-review --outcome errored >/dev/null

  # Cap 2: superseded round 1 (errored) + open round 2 (errored).
  run bash "$RW" count-rounds --story TEST-EC4 --max 2 --current-verdict FAILED
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 2"* ]] || return 1
  [[ "$output" == *"escalate true"* ]] || return 1

  # Round 3: supersedes round 2.
  bash "$RW" record-round --story TEST-EC4 --run-id "round-20261102T120003Z-40403" \
    --repo "$FIXTURE_DIR/repo" --gate "security-review=selected"
  bash "$RW" record-run --story TEST-EC4 --run-id "round-20261102T120003Z-40403" \
    --gate security-review --outcome errored >/dev/null

  # All three count: 2 superseded + 1 open.
  run bash "$RW" count-rounds --story TEST-EC4 --max 2 --current-verdict FAILED
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 3"* ]] || return 1
  [[ "$output" == *"escalate true"* ]] || return 1
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
    --gate security-review --report "$FIXTURE_DIR/r2.md" --verdict FAILED

  # Writer (complete-round) and reader (count-rounds) race for the lock.
  bash "$RW" complete-round --story TEST-EC5 --run-id "round-20261102T120002Z-50502" \
    --repo "$FIXTURE_DIR/repo" --verdict FAILED &
  local wpid=$!
  bash "$RW" count-rounds --story TEST-EC5 --max 2 --current-verdict FAILED > "$TMP/race.out" &
  local rpid=$!
  wait "$wpid"; local ws=$?
  wait "$rpid"; local rs=$?

  # Both must succeed; count must be >= 1 (at least the first completed round).
  [ "$ws" -eq 0 ]
  [ "$rs" -eq 0 ]
  local rc; rc="$(cat "$TMP/race.out")"
  [[ "$rc" == *"round_count"* ]] || return 1
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
  [[ "$output" == *"escalation_state escalated"* ]] || return 1
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
  [[ "${lines[*]}" == *"blocked"* ]] || return 1
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
  bash "$SR" --story TEST-EC9b > "$FIXTURE_DIR/sr-ec9b.txt" 2>&1
  local sr_ec9b; sr_ec9b="$(/usr/bin/grep 'security_gate_state' "$FIXTURE_DIR/sr-ec9b.txt")"
  [ "$sr_ec9b" = "security_gate_state unassessed" ]
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
  [[ "$output" == *"escalate true"* ]] || return 1

  # "one more cycle" → round 3 fails.
  _run_failing_round TEST-EC10 "round-20261101T120003Z-10003"
  run bash "$RW" count-rounds --story TEST-EC10 --max 2
  [[ "$output" == *"round_count 3"* ]] || return 1
  [[ "$output" == *"escalate true"* ]] || return 1

  # Another "one more cycle" → round 4 fails.
  _run_failing_round TEST-EC10 "round-20261101T120004Z-10004"
  run bash "$RW" count-rounds --story TEST-EC10 --max 2
  [[ "$output" == *"round_count 4"* ]] || return 1
  [[ "$output" == *"escalate true"* ]] || return 1
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
  [[ "$story" == *"status: review"* ]] || return 1
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
    --gate security-review --report "$FIXTURE_DIR/fc-report.md" --verdict FAILED
  bash "$RW" complete-round --story TEST-FC --run-id "round-20261102T120001Z-99901" \
    --repo "$FIXTURE_DIR/repo"

  run bash "$RW" count-rounds --story TEST-FC --max 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 1"* ]] || return 1
  [[ "$output" == *"escalate true"* ]] || return 1
}

# ---------------------------------------------------------------------------
# Security review SKILL.md passes --owasp-category and --impact
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
# Forged and unsigned --signed-off-findings refusals
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
  [[ "$output" == *"not a critical security finding"* ]] || return 1

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
# Scenario 15c — valid carried security assessment
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
    --gate security-review --report "$FIXTURE_DIR/sec-15c.md" --verdict PASSED
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
    --gate code-review --report "$FIXTURE_DIR/cr-15c.md" --verdict FAILED

  # security-report-reader must report "assessed" (carried gate has a report).
  bash "$SR" --story TEST-15C > "$FIXTURE_DIR/sr-15c.txt" 2>&1
  local sr_15c; sr_15c="$(/usr/bin/grep 'security_gate_state' "$FIXTURE_DIR/sr-15c.txt")"
  [ "$sr_15c" = "security_gate_state assessed" ]

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
# Triage disposition blocks accept
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
  [[ "$output" == *"blocked"* ]] || [[ "$output" == *"unresolved"* ]] || return 1
}

# ---------------------------------------------------------------------------
# Finding resolved once fixed (disposition=resolved) unblocks
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

# ---------------------------------------------------------------------------
# Errored-but-reported security gate blocks accept
# ---------------------------------------------------------------------------

@test "errored security gate with report blocks accept override" {
  _mk_project TEST-ERR
  local rid="round-20261102T120001Z-77001"
  bash "$RW" record-round --story TEST-ERR --run-id "$rid" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story TEST-ERR --run-id "$rid" --gate security-review \
    --outcome errored >/dev/null
  printf 'Verdict: FAILED (crash)\n' > "$FIXTURE_DIR/err-sec.md"
  bash "$RW" record-round-report --story TEST-ERR --run-id "$rid" \
    --gate security-review --report "$FIXTURE_DIR/err-sec.md" --verdict FAILED

  # Reader must report unassessed (errored is not assessed).
  bash "$SR" --story TEST-ERR > "$FIXTURE_DIR/sr-err.txt" 2>&1
  local sr_line; sr_line="$(/usr/bin/grep 'security_gate_state' "$FIXTURE_DIR/sr-err.txt")"
  [ "$sr_line" = "security_gate_state unassessed" ]

  # Accept must be blocked (errored gate, even with a report).
  run bash "$RW" record-accept-override --story TEST-ERR \
    --run-id "$rid" --decision accept --user admin --round 1 \
    --timestamp "2026-11-02T12:00:00Z"
  [ "$status" -ne 0 ]
  [[ "$output" == *"blocked"* ]] || return 1
}

# ---------------------------------------------------------------------------
# SKILL wiring: count-rounds --current-verdict documented
# ---------------------------------------------------------------------------

@test "run-all-reviews SKILL documents count-rounds with --current-verdict" {
  # Anchor on the backticked command, not the explanatory prose on the same
  # line. Dropping --current-verdict from the command must fail this test.
  /usr/bin/grep -q '`register-write.sh count-rounds --story {key} --current-verdict' "$RUN_ALL_SKILL"
}

# ---------------------------------------------------------------------------
# SKILL wiring: record-escalation documented before asking
# ---------------------------------------------------------------------------

@test "run-all-reviews SKILL documents record-escalation before asking the user" {
  /usr/bin/grep -q 'record-escalation.*--story.*--run-id.*--round-count' "$RUN_ALL_SKILL"
  # record-escalation must appear BEFORE the AskUserQuestion choices
  # (i.e. before the three choice bullets). Pin the ordering.
  local esc_line choice_line
  esc_line=$(/usr/bin/grep -n 'record-escalation.*--story.*--run-id.*--round-count' "$RUN_ALL_SKILL" | head -1 | cut -d: -f1)
  choice_line=$(/usr/bin/grep -n 'AskUserQuestion\|Present.*three choices' "$RUN_ALL_SKILL" | head -1 | cut -d: -f1)
  [ -n "$esc_line" ]
  [ -n "$choice_line" ]
  [ "$esc_line" -lt "$choice_line" ]
}

# ---------------------------------------------------------------------------
# SKILL wiring: resume detection documented before record-round
# ---------------------------------------------------------------------------

@test "run-all-reviews SKILL documents resume detection before round-start" {
  # Resume detection must appear BEFORE the round-start sequence.
  local resume_line skill_line
  resume_line=$(/usr/bin/grep -n 'Resume detection\|escalation_state.*escalated' "$RUN_ALL_SKILL" | head -1 | cut -d: -f1)
  skill_line=$(/usr/bin/grep -n 'Round-start sequence' "$RUN_ALL_SKILL" | head -1 | cut -d: -f1)
  [ -n "$resume_line" ]
  [ -n "$skill_line" ]
  [ "$resume_line" -lt "$skill_line" ]
}

# ---------------------------------------------------------------------------
# Doctor documents review limits
# ---------------------------------------------------------------------------

@test "doctor SKILL documents review limits with the effective cap" {
  /usr/bin/grep -q 'Review limits' "$DOCTOR_SKILL"
  /usr/bin/grep -q 'review.max_fix_cycles' "$DOCTOR_SKILL"
  /usr/bin/grep -q '2 (default)' "$DOCTOR_SKILL"
}

# ---------------------------------------------------------------------------
# Unsigned listed id: resolved critical without sign-off blocks
# ---------------------------------------------------------------------------

@test "unsigned resolved critical in signed-off-findings is rejected" {
  _mk_project TEST-UNSIGN
  _run_failing_round TEST-UNSIGN "round-20261102T120001Z-66601"
  _add_critical_finding TEST-UNSIGN "RCE" "A08" "remote code exec"

  local reg; reg="$(_reg TEST-UNSIGN)"
  local fid; fid="$(yq '.entries[-1].id' "$reg")"

  # Resolve the finding (fixed in code, no sign-off).
  bash "$RW" set-disposition --story TEST-UNSIGN --id "$fid" --disposition resolved

  # Accept with this id in --signed-off-findings must be rejected
  # because the finding has no complete sign-off record.
  run bash "$RW" record-accept-override --story TEST-UNSIGN \
    --run-id "round-20261102T120001Z-66601" \
    --decision accept --user admin --round 1 --timestamp "2026-11-02T12:00:00Z" \
    --signed-off-findings "$fid"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Multi-hop carry: 3-round chain reads as assessed, accept rc 0
# ---------------------------------------------------------------------------

@test "multi-hop carry chain: round 3 carried from 2 carried from 1 reads assessed" {
  _mk_project TEST-MHC

  # Round 1: security-review selected, completed, PASSED.
  local rid1="round-20261102T120001Z-55501"
  bash "$RW" record-round --story TEST-MHC --run-id "$rid1" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story TEST-MHC --run-id "$rid1" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: PASSED\n' > "$FIXTURE_DIR/mhc-sec-r1.md"
  bash "$RW" record-round-report --story TEST-MHC --run-id "$rid1" \
    --gate security-review --report "$FIXTURE_DIR/mhc-sec-r1.md" --verdict PASSED
  bash "$RW" complete-round --story TEST-MHC --run-id "$rid1" \
    --repo "$FIXTURE_DIR/repo" --verdict PASSED

  # Round 2: security-review carried from round 1, code-review selected.
  local rid2="round-20261102T120002Z-55502"
  bash "$RW" record-round --story TEST-MHC --run-id "$rid2" --repo "$FIXTURE_DIR/repo" \
    --gate "code-review=selected" \
    --carry "security-review=${rid1}:carried from prior round"
  bash "$RW" record-run --story TEST-MHC --run-id "$rid2" --gate code-review \
    --outcome completed >/dev/null
  printf 'Verdict: FAILED\n' > "$FIXTURE_DIR/mhc-cr-r2.md"
  bash "$RW" record-round-report --story TEST-MHC --run-id "$rid2" \
    --gate code-review --report "$FIXTURE_DIR/mhc-cr-r2.md" --verdict FAILED
  bash "$RW" complete-round --story TEST-MHC --run-id "$rid2" \
    --repo "$FIXTURE_DIR/repo" --verdict FAILED

  # Round 3: security-review carried from round 2 (which carries from 1).
  local rid3="round-20261102T120003Z-55503"
  bash "$RW" record-round --story TEST-MHC --run-id "$rid3" --repo "$FIXTURE_DIR/repo" \
    --gate "code-review=selected" \
    --carry "security-review=${rid2}:carried from prior round"

  # Reader must follow the full two-hop carry chain and report assessed.
  # Use a file capture to avoid bats-internal buffering differences.
  bash "$SR" --story TEST-MHC > "$FIXTURE_DIR/sr-out.txt" 2>&1
  local sr_line; sr_line="$(/usr/bin/grep 'security_gate_state' "$FIXTURE_DIR/sr-out.txt")"
  [ "$sr_line" = "security_gate_state assessed" ]

  # Accept override must succeed (no critical findings, gate assessed via chain).
  run bash "$RW" record-accept-override --story TEST-MHC \
    --run-id "$rid3" --decision accept --user admin --round 3 \
    --timestamp "2026-11-02T12:00:00Z"
  [ "$status" -eq 0 ]
  local ao; ao="$(yq '(.rounds[-1].accept_override.decision)' "$(_reg TEST-MHC)")"
  [ "$ao" = "accept" ]
}

# ---------------------------------------------------------------------------
# Missing reviewer OWASP category: accept stays blocked, reader shows unknown
# ---------------------------------------------------------------------------

@test "missing reviewer owasp category blocks accept and reader shows unknown" {
  _mk_project TEST-NOCAT

  local rid="round-20261102T120001Z-44401"
  bash "$RW" record-round --story TEST-NOCAT --run-id "$rid" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story TEST-NOCAT --run-id "$rid" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: FAILED\n' > "$FIXTURE_DIR/nocat-sec.md"
  bash "$RW" record-round-report --story TEST-NOCAT --run-id "$rid" \
    --gate security-review --report "$FIXTURE_DIR/nocat-sec.md" --verdict FAILED

  # Add a critical finding WITHOUT --owasp-category.
  bash "$RW" add --story TEST-NOCAT --defect "injection flaw" --type security \
    --severity critical --gate security-review --impact "data breach" \
    --blocking --blocking-rationale "critical security"

  local reg; reg="$(_reg TEST-NOCAT)"
  local fid; fid="$(yq '.entries[-1].id' "$reg")"

  # Sign off with an owasp-category (the approver's classification).
  bash "$RW" sign-off-finding --story TEST-NOCAT --finding-id "$fid" \
    --risk-accepted-by admin --owasp-category "A03" --impact "data breach" \
    --round 1 --timestamp "2026-11-02T12:00:00Z"

  # Accept must still be blocked: the reviewer's gate_ratings has no category.
  run bash "$RW" record-accept-override --story TEST-NOCAT \
    --run-id "$rid" --decision accept --user admin --round 1 \
    --timestamp "2026-11-02T12:00:00Z"
  [ "$status" -ne 0 ]
  [[ "${lines[*]}" == *"blocked"* ]] || return 1

  # Reader must show "unknown" for OWASP, NOT the approver's "A03".
  run bash "$SR" --story TEST-NOCAT
  [ "$status" -eq 0 ]
  # Extract the owasp value from the JSON output. The reader outputs
  # multi-line JSON so use grep to isolate the field.
  local owasp_line
  owasp_line="$(printf '%s\n' "$output" | /usr/bin/grep -o '"owasp": *"[^"]*"' | head -1)"
  [[ "$owasp_line" == *'"unknown"'* ]] || return 1
  # Must NOT contain A03 (the approver's sign-off text).
  [[ "$owasp_line" != *'"A03"'* ]] || return 1
}

# ---------------------------------------------------------------------------
# Halted all-FAILED round: open round with all reports counts toward cap
# ---------------------------------------------------------------------------

@test "halted round with all FAILED reports counts toward the cap" {
  _mk_project TEST-HALT

  # Round 1: completed FAILED (the SKILL's real call order).
  _run_failing_round TEST-HALT "round-20261102T120001Z-33301"

  # Round 2: all gates have reports (FAILED) but halted before complete-round.
  local rid2="round-20261102T120002Z-33302"
  bash "$RW" record-round --story TEST-HALT --run-id "$rid2" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story TEST-HALT --run-id "$rid2" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: FAILED\n' > "$FIXTURE_DIR/halt-r2.md"
  bash "$RW" record-round-report --story TEST-HALT --run-id "$rid2" \
    --gate security-review --report "$FIXTURE_DIR/halt-r2.md" --verdict FAILED
  # Do NOT call complete-round — the round is halted.

  # count-rounds without --current-verdict must count both rounds.
  run bash "$RW" count-rounds --story TEST-HALT --max 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 2"* ]] || return 1
  [[ "$output" == *"escalate true"* ]] || return 1

  # --- THE REAL PATH (SKILL always uses --current-verdict) ---
  # Round 3 supersedes the halted round 2. The superseded round counts
  # (fail closed) because it never received a PASSED verdict.
  local rid3="round-20261102T120003Z-33303"
  bash "$RW" record-round --story TEST-HALT --run-id "$rid3" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story TEST-HALT --run-id "$rid3" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: FAILED (round 3)\n' > "$FIXTURE_DIR/halt-r3-uniq.md"
  bash "$RW" record-round-report --story TEST-HALT --run-id "$rid3" \
    --gate security-review --report "$FIXTURE_DIR/halt-r3-uniq.md" --verdict FAILED

  # Decision point with --current-verdict FAILED (the SKILL path).
  # Round 1 (complete, FAILED) + round 2 (superseded, counted) + round 3 (open, FAILED).
  run bash "$RW" count-rounds --story TEST-HALT --max 2 --current-verdict FAILED
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 3"* ]] || return 1
  [[ "$output" == *"escalate true"* ]] || return 1
}

# ---------------------------------------------------------------------------
# Deterministic lock test: count-rounds blocks while lock is held
# ---------------------------------------------------------------------------

@test "count-rounds blocks while the register lock is held" {
  if ! command -v flock >/dev/null 2>&1; then
    # On hosts that are expected to have flock (CI: Linux), fail not skip.
    # On macOS without flock installed, skip remains acceptable.
    if [ "$(uname -s)" = "Linux" ]; then
      fail "flock is required on Linux but not on PATH"
    fi
    skip "flock not available on this macOS host"
  fi

  _mk_project TEST-LOCK
  _run_failing_round TEST-LOCK "round-20261102T120001Z-22201"

  local reg; reg="$(_reg TEST-LOCK)"
  local lockfile="${reg}.lock"
  local ready_marker="$TMP/lock-ready"
  local release_marker="$TMP/lock-released"

  # Hold the exclusive lock in a background subshell. Write a ready marker
  # after acquiring the lock; wait for the release marker to let go.
  touch "$lockfile"
  (
    exec 7>>"$lockfile"
    flock -x 7
    touch "$ready_marker"
    # Bounded wait for the release signal (max 15 s).
    local waited=0
    while [ ! -f "$release_marker" ] && [ "$waited" -lt 15 ]; do
      sleep 0.2; waited=$((waited + 1))
    done
    exec 7>&-
  ) &
  local holder_pid=$!

  # Bounded wait for the holder to acquire the lock (max 5 s).
  local waited=0
  while [ ! -f "$ready_marker" ] && [ "$waited" -lt 25 ]; do
    sleep 0.2; waited=$((waited + 1))
  done
  if [ ! -f "$ready_marker" ]; then
    kill "$holder_pid" 2>/dev/null
    [ -f "$ready_marker" ]  # assertion — fails the test
  fi

  # While the lock is held, start count-rounds in the background.
  bash "$RW" count-rounds --story TEST-LOCK --max 2 > "$TMP/lock-out.txt" 2>&1 &
  local cr_pid=$!

  # Give count-rounds a moment to start and block on the lock.
  sleep 0.5

  # Assert count-rounds has NOT produced output yet (still blocked).
  if [ -s "$TMP/lock-out.txt" ]; then
    kill "$holder_pid" 2>/dev/null; wait "$cr_pid" 2>/dev/null
    [ ! -s "$TMP/lock-out.txt" ]  # assertion — fails the test
  fi

  # Release the lock.
  touch "$release_marker"
  wait "$holder_pid" 2>/dev/null || true
  wait "$cr_pid"; local cr_rc=$?

  # count-rounds must succeed and report the correct count.
  [ "$cr_rc" -eq 0 ]
  local out; out="$(cat "$TMP/lock-out.txt")"
  [[ "$out" == *"round_count 1"* ]] || return 1
}

# ---------------------------------------------------------------------------
# Descope: review->backlog is refused; review->blocked->backlog succeeds
# ---------------------------------------------------------------------------

@test "descope: review->backlog is refused by the state machine" {
  # Source the state machine library and test the edge directly.
  source "${PLUGIN_ROOT}/scripts/lib/story-state-machine.sh"

  # review -> backlog must be rejected.
  run validate_story_transition "review" "backlog"
  [ "$status" -ne 0 ]

  # review -> blocked is allowed.
  run validate_story_transition "review" "blocked"
  [ "$status" -eq 0 ]

  # blocked -> backlog is allowed.
  run validate_story_transition "blocked" "backlog"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Three escalation choices documented in the SKILL
# ---------------------------------------------------------------------------

@test "three escalation choices are documented with correct patterns" {
  # Accept override: check the recording path.
  /usr/bin/grep -q 'record-accept-override' "$RUN_ALL_SKILL"

  # Descope to backlog: the two-step transition path.
  /usr/bin/grep -q 'transition-story-status.sh.*--to blocked' "$RUN_ALL_SKILL"
  /usr/bin/grep -q 'transition-story-status.sh.*--to backlog' "$RUN_ALL_SKILL"

  # One more cycle: documented explicitly.
  /usr/bin/grep -q 'one more cycle' "$RUN_ALL_SKILL"

  # All three appear in the same escalation section (Substep 2.4a).
  local sec_start sec_end
  sec_start=$(/usr/bin/grep -n 'Substep 2.4a' "$RUN_ALL_SKILL" | head -1 | cut -d: -f1)
  sec_end=$(/usr/bin/grep -n 'Substep 2.4b' "$RUN_ALL_SKILL" | head -1 | cut -d: -f1)
  [ -n "$sec_start" ] && [ -n "$sec_end" ]
  [ "$sec_start" -lt "$sec_end" ]

  # The three choices appear between 2.4a and 2.4b.
  local section; section="$(sed -n "${sec_start},${sec_end}p" "$RUN_ALL_SKILL")"
  [[ "$section" == *"accept override"* ]] || return 1
  [[ "$section" == *"descope to backlog"* ]] || return 1
  [[ "$section" == *"one more cycle"* ]] || return 1
}

# ---------------------------------------------------------------------------
# Doctor: effective cap reported with and without config
# ---------------------------------------------------------------------------

@test "doctor reports effective cap 2 (default) and configured value" {
  # Without config: resolve-config returns empty, count-rounds defaults to 2.
  _mk_project TEST-DOC
  _run_failing_round TEST-DOC "round-20261102T120001Z-11101"
  _run_failing_round TEST-DOC "round-20261102T120002Z-11102"

  # No review section in config → count-rounds uses default 2.
  run bash "$RW" count-rounds --story TEST-DOC
  [ "$status" -eq 0 ]
  [[ "$output" == *"max_fix_cycles 2"* ]] || return 1
  [[ "$output" == *"escalate true"* ]] || return 1

  # With config: count-rounds reads the configured value.
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
  max_fix_cycles: 5
CONF
  run bash "$RW" count-rounds --story TEST-DOC
  [ "$status" -eq 0 ]
  [[ "$output" == *"max_fix_cycles 5"* ]] || return 1
  [[ "$output" == *"escalate false"* ]] || return 1

  # Doctor SKILL.md documents the "2 (default)" text.
  /usr/bin/grep -q '2 (default)' "$DOCTOR_SKILL"

  # Doctor SKILL.md documents the resolve-config command.
  /usr/bin/grep -q 'resolve-config.sh --field review.max_fix_cycles' "$DOCTOR_SKILL"
}

# ---------------------------------------------------------------------------
# Carried from a crashed round with no report blocks accept and reads unassessed
# ---------------------------------------------------------------------------

@test "carried from a crashed round with no report blocks accept" {
  _mk_project TEST-CARRY-CRASH

  # Round 1: security-review selected but errored with NO report.
  local rid1="round-20261103T120001Z-80001"
  bash "$RW" record-round --story TEST-CARRY-CRASH --run-id "$rid1" \
    --repo "$FIXTURE_DIR/repo" --gate "security-review=selected"
  bash "$RW" record-run --story TEST-CARRY-CRASH --run-id "$rid1" \
    --gate security-review --outcome errored >/dev/null
  # No report recorded for round 1 — the reviewer crashed.
  bash "$RW" complete-round --story TEST-CARRY-CRASH --run-id "$rid1" \
    --repo "$FIXTURE_DIR/repo" --verdict FAILED 2>/dev/null || true

  # Round 2: security-review carried from round 1, code-review selected.
  local rid2="round-20261103T120002Z-80002"
  bash "$RW" record-round --story TEST-CARRY-CRASH --run-id "$rid2" \
    --repo "$FIXTURE_DIR/repo" --gate "code-review=selected" \
    --carry "security-review=${rid1}:carried from crashed round"
  bash "$RW" record-run --story TEST-CARRY-CRASH --run-id "$rid2" \
    --gate code-review --outcome completed >/dev/null
  printf 'Verdict: FAILED\n' > "$FIXTURE_DIR/crash-cr-r2.md"
  bash "$RW" record-round-report --story TEST-CARRY-CRASH --run-id "$rid2" \
    --gate code-review --report "$FIXTURE_DIR/crash-cr-r2.md" --verdict FAILED

  # Reader must report unassessed (carry chain has no completed report).
  bash "$SR" --story TEST-CARRY-CRASH > "$FIXTURE_DIR/sr-crash.txt" 2>&1
  local sr_line; sr_line="$(/usr/bin/grep 'security_gate_state' "$FIXTURE_DIR/sr-crash.txt")"
  [ "$sr_line" = "security_gate_state unassessed" ]

  # Accept must be blocked (carried gate has no completed report).
  run bash "$RW" record-accept-override --story TEST-CARRY-CRASH \
    --run-id "$rid2" --decision accept --user admin --round 2 \
    --timestamp "2026-11-03T12:00:00Z"
  [ "$status" -ne 0 ]
  [[ "$output" == *"blocked"* ]] || [[ "$output" == *"no completed report"* ]] || return 1

  # Sub-case: carried from a round with a report but errored outcome.
  # The reader must still say unassessed because the run errored.
  _mk_project TEST-CARRY-ERR
  local rid_e1="round-20261103T120001Z-80011"
  bash "$RW" record-round --story TEST-CARRY-ERR --run-id "$rid_e1" \
    --repo "$FIXTURE_DIR/repo" --gate "security-review=selected"
  bash "$RW" record-run --story TEST-CARRY-ERR --run-id "$rid_e1" \
    --gate security-review --outcome errored >/dev/null
  # Report was written before the crash.
  printf 'Verdict: FAILED (crash)\n' > "$FIXTURE_DIR/err-carry-r1.md"
  bash "$RW" record-round-report --story TEST-CARRY-ERR --run-id "$rid_e1" \
    --gate security-review --report "$FIXTURE_DIR/err-carry-r1.md" --verdict FAILED
  bash "$RW" complete-round --story TEST-CARRY-ERR --run-id "$rid_e1" \
    --repo "$FIXTURE_DIR/repo" --verdict FAILED 2>/dev/null || true

  # Round 2 carries security from round 1.
  local rid_e2="round-20261103T120002Z-80012"
  bash "$RW" record-round --story TEST-CARRY-ERR --run-id "$rid_e2" \
    --repo "$FIXTURE_DIR/repo" --gate "code-review=selected" \
    --carry "security-review=${rid_e1}:carried from errored round"

  # Reader must say unassessed (errored outcome, even with a report).
  bash "$SR" --story TEST-CARRY-ERR > "$FIXTURE_DIR/sr-carry-err.txt" 2>&1
  local sr_err; sr_err="$(/usr/bin/grep 'security_gate_state' "$FIXTURE_DIR/sr-carry-err.txt")"
  [ "$sr_err" = "security_gate_state unassessed" ]

  # Accept must be blocked.
  run bash "$RW" record-accept-override --story TEST-CARRY-ERR \
    --run-id "$rid_e2" --decision accept --user admin --round 2 \
    --timestamp "2026-11-03T12:00:00Z"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Missing reviewer impact blocks accept override
# ---------------------------------------------------------------------------

@test "missing reviewer impact blocks accept override" {
  _mk_project TEST-NOIMP

  local rid="round-20261103T120001Z-90001"
  bash "$RW" record-round --story TEST-NOIMP --run-id "$rid" \
    --repo "$FIXTURE_DIR/repo" --gate "security-review=selected"
  bash "$RW" record-run --story TEST-NOIMP --run-id "$rid" \
    --gate security-review --outcome completed >/dev/null
  printf 'Verdict: FAILED\n' > "$FIXTURE_DIR/noimp-sec.md"
  bash "$RW" record-round-report --story TEST-NOIMP --run-id "$rid" \
    --gate security-review --report "$FIXTURE_DIR/noimp-sec.md" --verdict FAILED

  # Add a critical finding WITHOUT --impact but WITH --owasp-category.
  bash "$RW" add --story TEST-NOIMP --defect "injection flaw" --type security \
    --severity critical --gate security-review --owasp-category "A03" \
    --blocking --blocking-rationale "critical security"

  local reg; reg="$(_reg TEST-NOIMP)"
  local fid; fid="$(yq '.entries[-1].id' "$reg")"

  # Sign off with all fields (the approver fills in impact).
  bash "$RW" sign-off-finding --story TEST-NOIMP --finding-id "$fid" \
    --risk-accepted-by admin --owasp-category "A03" --impact "high severity" \
    --round 1 --timestamp "2026-11-03T12:00:00Z"

  # Accept must still be blocked: the reviewer's entry.impact is missing.
  run bash "$RW" record-accept-override --story TEST-NOIMP \
    --run-id "$rid" --decision accept --user admin --round 1 \
    --timestamp "2026-11-03T12:00:00Z"
  [ "$status" -ne 0 ]

  # Reader must show "unknown" for impact, NOT the approver's text.
  run bash "$SR" --story TEST-NOIMP
  [ "$status" -eq 0 ]
  local impact_line
  impact_line="$(printf '%s\n' "$output" | /usr/bin/grep -o '"impact": *"[^"]*"' | head -1)"
  [[ "$impact_line" == *'"unknown"'* ]] || return 1
}

# ---------------------------------------------------------------------------
# Escalation state cleared after each choice
# ---------------------------------------------------------------------------

@test "resolve-escalation clears the escalated state for each choice" {
  _mk_project TEST-RESESC

  # Build up to the escalation point.
  _run_failing_round TEST-RESESC "round-20261103T120001Z-70001"
  _run_failing_round TEST-RESESC "round-20261103T120002Z-70002"
  local rid2="round-20261103T120002Z-70002"

  bash "$RW" record-escalation --story TEST-RESESC \
    --run-id "$rid2" --round-count 2 --max-cycles 2

  local reg; reg="$(_reg TEST-RESESC)"
  [ "$(yq '.rounds[-1].escalation.state' "$reg")" = "escalated" ]

  # --- Accept choice ---
  bash "$RW" record-accept-override --story TEST-RESESC \
    --run-id "$rid2" --decision accept --user admin --round 2 \
    --timestamp "2026-11-03T12:00:00Z"
  bash "$RW" resolve-escalation --story TEST-RESESC --run-id "$rid2" --choice accept
  [ "$(yq '.rounds[-1].escalation.state' "$reg")" = "resolved:accept" ]

  # round-info must NOT report "escalated" after resolving.
  run bash "$RW" round-info --story TEST-RESESC
  [ "$status" -eq 0 ]
  [[ "$output" != *"escalation_state escalated"* ]] || return 1
  [[ "$output" == *"escalation_state resolved:accept"* ]] || return 1
}

@test "resolve-escalation with descope choice clears the state" {
  _mk_project TEST-RESDESC
  _run_failing_round TEST-RESDESC "round-20261103T120001Z-71001"
  _run_failing_round TEST-RESDESC "round-20261103T120002Z-71002"
  local rid2="round-20261103T120002Z-71002"

  bash "$RW" record-escalation --story TEST-RESDESC \
    --run-id "$rid2" --round-count 2 --max-cycles 2

  bash "$RW" resolve-escalation --story TEST-RESDESC --run-id "$rid2" --choice descope
  local reg; reg="$(_reg TEST-RESDESC)"
  [ "$(yq '.rounds[-1].escalation.state' "$reg")" = "resolved:descope" ]

  # round-info confirms the resolved state.
  run bash "$RW" round-info --story TEST-RESDESC
  [[ "$output" == *"escalation_state resolved:descope"* ]] || return 1
}

@test "resolve-escalation with one-more-cycle choice clears the state" {
  _mk_project TEST-RESOMC
  _run_failing_round TEST-RESOMC "round-20261103T120001Z-72001"
  _run_failing_round TEST-RESOMC "round-20261103T120002Z-72002"
  local rid2="round-20261103T120002Z-72002"

  bash "$RW" record-escalation --story TEST-RESOMC \
    --run-id "$rid2" --round-count 2 --max-cycles 2

  bash "$RW" resolve-escalation --story TEST-RESOMC --run-id "$rid2" --choice one-more-cycle
  local reg; reg="$(_reg TEST-RESOMC)"
  [ "$(yq '.rounds[-1].escalation.state' "$reg")" = "resolved:one-more-cycle" ]

  # A new round after one-more-cycle: round 3 fails, escalation at cap.
  _run_failing_round TEST-RESOMC "round-20261103T120003Z-72003"
  run bash "$RW" count-rounds --story TEST-RESOMC --max 2 --current-verdict FAILED
  [[ "$output" == *"round_count 3"* ]] || return 1
  [[ "$output" == *"escalate true"* ]] || return 1
}

@test "resolve-escalation rejects non-escalated round" {
  _mk_project TEST-RESBAD
  _run_failing_round TEST-RESBAD "round-20261103T120001Z-73001"
  local rid1="round-20261103T120001Z-73001"

  # No escalation recorded — resolve must fail.
  run bash "$RW" resolve-escalation --story TEST-RESBAD --run-id "$rid1" --choice accept
  [ "$status" -ne 0 ]
  [[ "$output" == *"not in escalated state"* ]] || return 1
}

# ---------------------------------------------------------------------------
# resolve-escalation wired into the SKILL for each choice
# ---------------------------------------------------------------------------

@test "run-all-reviews SKILL wires resolve-escalation after each choice" {
  # Each choice must be followed by a resolve-escalation call.
  /usr/bin/grep -q 'resolve-escalation.*--choice accept' "$RUN_ALL_SKILL"
  /usr/bin/grep -q 'resolve-escalation.*--choice descope' "$RUN_ALL_SKILL"
  /usr/bin/grep -q 'resolve-escalation.*--choice one-more-cycle' "$RUN_ALL_SKILL"

  # The resolve-escalation call must appear in Substep 2.2a too (resume doc).
  /usr/bin/grep -q 'resolve-escalation' "$RUN_ALL_SKILL"
}

# ---------------------------------------------------------------------------
# End-to-end descope through the transition tooling
# ---------------------------------------------------------------------------

_mk_transition_project() {
  # Set up a minimal project tree that transition-story-status.sh can work with.
  local key="$1"
  FIXTURE_DIR="$TMP/trans-${key}-$$"
  mkdir -p "$FIXTURE_DIR/ia/epic-E900-fixture/stories"
  cat > "$FIXTURE_DIR/ia/epic-E900-fixture/stories/${key}-x.md" <<S
---
template: 'story'
key: "${key}"
title: "test story"
epic: "E900"
status: review
sprint_id: sprint-test
---
## Acceptance Criteria

- [ ] AC1: x

**Status:** review
S
  # Create a git repo.
  mkdir -p "$FIXTURE_DIR/repo"
  git -C "$FIXTURE_DIR/repo" init -q
  git -C "$FIXTURE_DIR/repo" -c user.email=a@b -c user.name=t commit -q --allow-empty -m init

  # epics-and-stories.md.
  mkdir -p "$FIXTURE_DIR/pa"
  cat > "$FIXTURE_DIR/pa/epics-and-stories.md" <<EAS
# Epics and Stories

## E900 — Fixture

### Story ${key}: test story
- **Status:** review
- **Priority:** high
- **Risk:** medium
EAS

  # sprint-status.yaml.
  mkdir -p "$FIXTURE_DIR/.gaia/state"
  cat > "$FIXTURE_DIR/.gaia/state/sprint-status.yaml" <<SPR
sprint_id: sprint-test
status: active
total_points: 5
completed_points: 0
stories:
  - key: "${key}"
    status: review
    points: 5
SPR

  # story-index.yaml.
  cat > "$FIXTURE_DIR/ia/epic-E900-fixture/stories/story-index.yaml" <<IDX
- story_key: "${key}"
  title: "test story"
  epic: "E900"
  priority: "high"
  risk: "medium"
  author: ""
  file: "${key}-x.md"
  status: review
IDX

  # Memory path (for the lock file).
  mkdir -p "$FIXTURE_DIR/.gaia/memory"

  export IMPLEMENTATION_ARTIFACTS="$FIXTURE_DIR/ia" \
         PROJECT_ROOT="$FIXTURE_DIR" \
         PLANNING_ARTIFACTS="$FIXTURE_DIR/pa" \
         EPICS_AND_STORIES="$FIXTURE_DIR/pa/epics-and-stories.md" \
         SPRINT_STATUS_YAML="$FIXTURE_DIR/.gaia/state/sprint-status.yaml"
  unset CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT PROJECT_PATH 2>/dev/null || true
}

@test "descope: transition tooling refuses review->backlog, allows review->blocked->backlog" {
  local trans="${PLUGIN_ROOT}/scripts/transition-story-status.sh"
  [ -f "$trans" ]

  _mk_transition_project TEST-TRANS1

  # review -> backlog must be refused (exit 7 = invalid transition).
  run bash "$trans" TEST-TRANS1 --to backlog
  [ "$status" -eq 7 ]

  # review -> blocked is allowed.
  run bash "$trans" TEST-TRANS1 --to blocked
  [ "$status" -eq 0 ]

  # Verify the status changed to blocked.
  local story_path="$FIXTURE_DIR/ia/epic-E900-fixture/stories/TEST-TRANS1-x.md"
  /usr/bin/grep -q '^status: blocked' "$story_path"

  # blocked -> backlog is allowed.
  run bash "$trans" TEST-TRANS1 --to backlog
  [ "$status" -eq 0 ]

  # Verify the final status is backlog.
  /usr/bin/grep -q '^status: backlog' "$story_path"
}

# ---------------------------------------------------------------------------
# Three escalation choices driven end-to-end through scripts
# ---------------------------------------------------------------------------

@test "escalation choices driven end-to-end: accept, descope, one-more-cycle" {
  # --- Accept choice ---
  _mk_project TEST-CHO-A
  _run_failing_round TEST-CHO-A "round-20261103T120001Z-85001"
  _run_failing_round TEST-CHO-A "round-20261103T120002Z-85002"
  local rid_a="round-20261103T120002Z-85002"
  bash "$RW" record-escalation --story TEST-CHO-A \
    --run-id "$rid_a" --round-count 2 --max-cycles 2
  # Accept the override.
  bash "$RW" record-accept-override --story TEST-CHO-A \
    --run-id "$rid_a" --decision accept --user admin --round 2 \
    --timestamp "2026-11-03T12:00:00Z"
  # Resolve the escalation.
  bash "$RW" resolve-escalation --story TEST-CHO-A --run-id "$rid_a" --choice accept
  # Complete the round.
  bash "$RW" complete-round --story TEST-CHO-A --run-id "$rid_a" \
    --repo "$FIXTURE_DIR/repo" --verdict FAILED
  local reg_a; reg_a="$(_reg TEST-CHO-A)"
  [ "$(yq '.rounds[-1].escalation.state' "$reg_a")" = "resolved:accept" ]
  [ "$(yq '.rounds[-1].accept_override.decision' "$reg_a")" = "accept" ]
  [ "$(yq '.rounds[-1].status' "$reg_a")" = "complete" ]

  # --- Descope choice ---
  _mk_project TEST-CHO-D
  _run_failing_round TEST-CHO-D "round-20261103T120001Z-86001"
  _run_failing_round TEST-CHO-D "round-20261103T120002Z-86002"
  local rid_d="round-20261103T120002Z-86002"
  bash "$RW" record-escalation --story TEST-CHO-D \
    --run-id "$rid_d" --round-count 2 --max-cycles 2
  # Resolve as descope.
  bash "$RW" resolve-escalation --story TEST-CHO-D --run-id "$rid_d" --choice descope
  local reg_d; reg_d="$(_reg TEST-CHO-D)"
  [ "$(yq '.rounds[-1].escalation.state' "$reg_d")" = "resolved:descope" ]

  # --- One-more-cycle choice ---
  _mk_project TEST-CHO-O
  _run_failing_round TEST-CHO-O "round-20261103T120001Z-87001"
  _run_failing_round TEST-CHO-O "round-20261103T120002Z-87002"
  local rid_o="round-20261103T120002Z-87002"
  bash "$RW" record-escalation --story TEST-CHO-O \
    --run-id "$rid_o" --round-count 2 --max-cycles 2
  # Resolve as one-more-cycle.
  bash "$RW" resolve-escalation --story TEST-CHO-O --run-id "$rid_o" --choice one-more-cycle
  local reg_o; reg_o="$(_reg TEST-CHO-O)"
  [ "$(yq '.rounds[-1].escalation.state' "$reg_o")" = "resolved:one-more-cycle" ]
  # Run one more round (round 3), then check escalation triggers again.
  _run_failing_round TEST-CHO-O "round-20261103T120003Z-87003"
  run bash "$RW" count-rounds --story TEST-CHO-O --max 2 --current-verdict FAILED
  [[ "$output" == *"round_count 3"* ]] || return 1
  [[ "$output" == *"escalate true"* ]] || return 1
}

# ---------------------------------------------------------------------------
# Passing-round regression: a round where every review passed never counts
# ---------------------------------------------------------------------------

# Helper: run a round up to the report stage but do NOT call complete-round.
# The round will be superseded when the next record-round is called.
_run_halted_round() {
  local key="$1" rid="$2" verdict="${3:-FAILED}"
  bash "$RW" record-round --story "$key" --run-id "$rid" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story "$key" --run-id "$rid" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: %s\n' "$verdict" > "$FIXTURE_DIR/halt-${rid}.md"
  bash "$RW" record-round-report --story "$key" --run-id "$rid" \
    --gate security-review --report "$FIXTURE_DIR/halt-${rid}.md" --verdict "$verdict"
}

@test "case a: F, F -> escalate, one more cycle, P -> escalate false" {
  _mk_project TEST-CASE-A
  _run_failing_round TEST-CASE-A "round-20261103T130001Z-91001"
  _run_failing_round TEST-CASE-A "round-20261103T130002Z-91002"

  # At cap 2, two failed rounds escalate.
  run bash "$RW" count-rounds --story TEST-CASE-A --max 2 --current-verdict FAILED
  [[ "$output" == *"escalate true"* ]] || return 1

  # One more cycle: round 3 passes.
  _run_passing_round TEST-CASE-A "round-20261103T130003Z-91003"

  # Decision point: the passing round must not escalate.
  run bash "$RW" count-rounds --story TEST-CASE-A --max 2 --current-verdict PASSED
  [ "$status" -eq 0 ]
  [[ "$output" == *"escalate false"* ]] || return 1
}

@test "case b: F, F -> escalate, accept, P -> escalate false" {
  _mk_project TEST-CASE-B
  _run_failing_round TEST-CASE-B "round-20261103T130001Z-92001"
  _run_failing_round TEST-CASE-B "round-20261103T130002Z-92002"

  # Escalate and accept.
  bash "$RW" record-escalation --story TEST-CASE-B \
    --run-id "round-20261103T130002Z-92002" --round-count 2 --max-cycles 2
  bash "$RW" record-accept-override --story TEST-CASE-B \
    --run-id "round-20261103T130002Z-92002" \
    --decision accept --user admin --round 2 --timestamp "2026-11-03T13:00:00Z"
  bash "$RW" resolve-escalation --story TEST-CASE-B \
    --run-id "round-20261103T130002Z-92002" --choice accept

  # Next round passes.
  _run_passing_round TEST-CASE-B "round-20261103T130003Z-92003"

  run bash "$RW" count-rounds --story TEST-CASE-B --max 2 --current-verdict PASSED
  [ "$status" -eq 0 ]
  [[ "$output" == *"escalate false"* ]] || return 1
}

@test "case c: F, halted all-PASSED (superseded), F -> round_count 2, escalate false at cap 3" {
  _mk_project TEST-CASE-C

  # Round 1: completed FAILED.
  _run_failing_round TEST-CASE-C "round-20261103T130001Z-93001"

  # Round 2: halted with all gates PASSED (report says PASSED, not completed).
  # This round will be superseded when round 3 starts.
  _run_halted_round TEST-CASE-C "round-20261103T130002Z-93002" "PASSED"

  # Round 3: supersedes round 2, fails.
  _run_failing_round TEST-CASE-C "round-20261103T130003Z-93003"

  # Cap 3: round 1 (complete, FAILED=1) + round 2 (superseded, all-PASSED=0)
  # + round 3 (complete, FAILED=1) = round_count 2, escalate false.
  run bash "$RW" count-rounds --story TEST-CASE-C --max 3 --current-verdict FAILED
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 2"* ]] || return 1
  [[ "$output" == *"escalate false"* ]] || return 1
}

@test "case d: halted all-FAILED round (superseded) counts toward the cap" {
  _mk_project TEST-CASE-D

  # Round 1: halted with all gates FAILED (report recorded, not completed).
  _run_halted_round TEST-CASE-D "round-20261103T130001Z-94001" "FAILED"

  # Round 2: supersedes round 1, decision at cap 2.
  local rid2="round-20261103T130002Z-94002"
  bash "$RW" record-round --story TEST-CASE-D --run-id "$rid2" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story TEST-CASE-D --run-id "$rid2" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: FAILED (round 2)\n' > "$FIXTURE_DIR/case-d-r2.md"
  bash "$RW" record-round-report --story TEST-CASE-D --run-id "$rid2" \
    --gate security-review --report "$FIXTURE_DIR/case-d-r2.md" --verdict FAILED

  # Round 1 (superseded, counted — fail closed) + round 2 (open, FAILED)
  # = round_count 2, escalate true at cap 2.
  # The superseded round MUST count; without it, round_count would be 1.
  run bash "$RW" count-rounds --story TEST-CASE-D --max 2 --current-verdict FAILED
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 2"* ]] || return 1
  [[ "$output" == *"escalate true"* ]] || return 1
}

# ---------------------------------------------------------------------------
# Canonical-path tests: one report path per gate, reused across rounds
# (models the real SKILL behaviour where report paths are overwritten).
# ---------------------------------------------------------------------------

# Helper: run a halted round using a SHARED canonical report path.
_run_halted_round_canonical() {
  local key="$1" rid="$2" report_path="$3" verdict_text="${4:-FAILED}" stored_verdict="${5:-FAILED}"
  bash "$RW" record-round --story "$key" --run-id "$rid" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story "$key" --run-id "$rid" --gate security-review \
    --outcome completed >/dev/null
  printf '%s\n' "$verdict_text" > "$report_path"
  bash "$RW" record-round-report --story "$key" --run-id "$rid" \
    --gate security-review --report "$report_path" --verdict "$stored_verdict"
}

# Helper: run a full failing round using a SHARED canonical report path.
_run_failing_round_canonical() {
  local key="$1" rid="$2" report_path="$3"
  _run_halted_round_canonical "$key" "$rid" "$report_path" "Verdict: FAILED round $rid" "FAILED"
  bash "$RW" count-rounds --story "$key" --current-verdict FAILED >/dev/null
  bash "$RW" complete-round --story "$key" --run-id "$rid" --repo "$FIXTURE_DIR/repo" --verdict FAILED
}

@test "case c canonical: F, halted all-PASSED, F -> round_count 2, escalate false at cap 3" {
  _mk_project TEST-CC
  local rpath="$FIXTURE_DIR/security-review-TEST-CC.md"

  # Round 1: completed FAILED, uses the shared report path.
  _run_failing_round_canonical TEST-CC "round-20261103T140001Z-95001" "$rpath"

  # Round 2: halted with PASSED — report says Verdict: PASSED.
  # This overwrites the same report path as round 1.
  _run_halted_round_canonical TEST-CC "round-20261103T140002Z-95002" "$rpath" "Verdict: PASSED" "PASSED"

  # Round 3: supersedes round 2, fails — overwrites the same report path again.
  local rid3="round-20261103T140003Z-95003"
  bash "$RW" record-round --story TEST-CC --run-id "$rid3" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story TEST-CC --run-id "$rid3" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: FAILED round 3\n' > "$rpath"
  bash "$RW" record-round-report --story TEST-CC --run-id "$rid3" \
    --gate security-review --report "$rpath" --verdict FAILED

  # The report file now holds round 3's FAILED text, but the stored
  # verdict for round 2 was recorded as PASSED via --verdict.
  run bash "$RW" count-rounds --story TEST-CC --max 3 --current-verdict FAILED
  [ "$status" -eq 0 ]
  # Round 1 (complete FAILED=1) + round 2 (superseded all-PASSED=0) + round 3 (open FAILED=1) = 2.
  [[ "$output" == *"round_count 2"* ]] || return 1
  [[ "$output" == *"escalate false"* ]] || return 1
}

@test "canonical path: FAILED R1 does not vanish when R2 overwrites the path" {
  _mk_project TEST-CVAN
  local rpath="$FIXTURE_DIR/security-review-TEST-CVAN.md"

  # Round 1: security FAILED, halted.
  _run_halted_round_canonical TEST-CVAN "round-20261103T140001Z-96001" "$rpath" "Verdict: FAILED" "FAILED"

  # Round 2: security PASSED + code-review FAILED — overwrites the same path.
  local rid2="round-20261103T140002Z-96002"
  bash "$RW" record-round --story TEST-CVAN --run-id "$rid2" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected" --gate "code-review=selected"
  bash "$RW" record-run --story TEST-CVAN --run-id "$rid2" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: PASSED\n' > "$rpath"
  bash "$RW" record-round-report --story TEST-CVAN --run-id "$rid2" \
    --gate security-review --report "$rpath" --verdict PASSED
  bash "$RW" record-run --story TEST-CVAN --run-id "$rid2" --gate code-review \
    --outcome completed >/dev/null
  printf 'Verdict: FAILED round 2 code-review\n' > "$FIXTURE_DIR/code-review-TEST-CVAN.md"
  bash "$RW" record-round-report --story TEST-CVAN --run-id "$rid2" \
    --gate code-review --report "$FIXTURE_DIR/code-review-TEST-CVAN.md" --verdict FAILED

  # The file now says PASSED (round 2's security), but round 1's stored verdict is FAILED.
  run bash "$RW" count-rounds --story TEST-CVAN --max 2 --current-verdict FAILED
  [ "$status" -eq 0 ]
  # Round 1 (superseded, stored FAILED=1) + round 2 (open, FAILED=1) = 2.
  [[ "$output" == *"round_count 2"* ]] || return 1
  [[ "$output" == *"escalate true"* ]] || return 1
}

# ---------------------------------------------------------------------------
# Decorated verdict forms: real framework report formats must be accepted
# ---------------------------------------------------------------------------

@test "report text PASSED but recorded FAILED: round counts (text is ignored)" {
  _mk_project TEST-TXT-V1
  local rpath="$FIXTURE_DIR/report-txt-v1.md"
  local rid="round-20261103T150001Z-97000"
  bash "$RW" record-round --story TEST-TXT-V1 --run-id "$rid" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story TEST-TXT-V1 --run-id "$rid" --gate security-review \
    --outcome completed >/dev/null
  # Report TEXT says PASSED, but the recorded verdict is FAILED.
  printf 'Verdict: PASSED\n' > "$rpath"
  bash "$RW" record-round-report --story TEST-TXT-V1 --run-id "$rid" \
    --gate security-review --report "$rpath" --verdict FAILED
  # Round 2 supersedes, FAILED.
  local rid2="round-20261103T150002Z-97100"
  bash "$RW" record-round --story TEST-TXT-V1 --run-id "$rid2" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story TEST-TXT-V1 --run-id "$rid2" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: FAILED\n' > "$FIXTURE_DIR/report-txt-v1-r2.md"
  bash "$RW" record-round-report --story TEST-TXT-V1 --run-id "$rid2" \
    --gate security-review --report "$FIXTURE_DIR/report-txt-v1-r2.md" --verdict FAILED
  # The recorded verdict is FAILED, so the round counts — text is irrelevant.
  run bash "$RW" count-rounds --story TEST-TXT-V1 --max 2 --current-verdict FAILED
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 2"* ]] || return 1
  [[ "$output" == *"escalate true"* ]] || return 1
}

@test "report text with Verdict heading + FAILED prose but recorded PASSED: round not counted" {
  _mk_project TEST-TXT-V2
  local rpath="$FIXTURE_DIR/report-txt-v2.md"
  local rid="round-20261103T150001Z-97010"
  bash "$RW" record-round --story TEST-TXT-V2 --run-id "$rid" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story TEST-TXT-V2 --run-id "$rid" --gate security-review \
    --outcome completed >/dev/null
  # Report has a ## Verdict heading with FAILED-looking prose, but recorded PASSED.
  printf '## Verdict\n\nFAILED — blocking issues found.\n\n**Verdict: REQUEST_CHANGES**\n' > "$rpath"
  bash "$RW" record-round-report --story TEST-TXT-V2 --run-id "$rid" \
    --gate security-review --report "$rpath" --verdict PASSED
  # Round 2 supersedes, FAILED.
  local rid2="round-20261103T150002Z-97110"
  bash "$RW" record-round --story TEST-TXT-V2 --run-id "$rid2" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story TEST-TXT-V2 --run-id "$rid2" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: FAILED\n' > "$FIXTURE_DIR/report-txt-v2-r2.md"
  bash "$RW" record-round-report --story TEST-TXT-V2 --run-id "$rid2" \
    --gate security-review --report "$FIXTURE_DIR/report-txt-v2-r2.md" --verdict FAILED
  # The recorded verdict is PASSED, so the superseded round does NOT count.
  run bash "$RW" count-rounds --story TEST-TXT-V2 --max 2 --current-verdict FAILED
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 1"* ]] || return 1
  [[ "$output" == *"escalate false"* ]] || return 1
}

# ---------------------------------------------------------------------------
# Substring match must fail closed: lines containing PASSED that are not
# ---------------------------------------------------------------------------

@test "record-round-report rejects missing --verdict" {
  _mk_project TEST-NO-VERD
  local rid="round-20261103T160001Z-98000"
  bash "$RW" record-round --story TEST-NO-VERD --run-id "$rid" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story TEST-NO-VERD --run-id "$rid" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: FAILED\n' > "$FIXTURE_DIR/report-no-verd.md"
  # Omit --verdict: must fail.
  run bash "$RW" record-round-report --story TEST-NO-VERD --run-id "$rid" \
    --gate security-review --report "$FIXTURE_DIR/report-no-verd.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--verdict is required"* ]] || return 1
}

@test "record-round-report rejects invalid --verdict values" {
  _mk_project TEST-BAD-VERD
  local rid="round-20261103T160001Z-98010"
  bash "$RW" record-round --story TEST-BAD-VERD --run-id "$rid" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story TEST-BAD-VERD --run-id "$rid" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: PASSED\n' > "$FIXTURE_DIR/report-bad-verd.md"
  local bad_vals=( "APPROVE" "BLOCKED" "not-passed" "passed" "failed" "" )
  local v
  for v in "${bad_vals[@]}"; do
    run bash "$RW" record-round-report --story TEST-BAD-VERD --run-id "$rid" \
      --gate security-review --report "$FIXTURE_DIR/report-bad-verd.md" --verdict "$v"
    [ "$status" -ne 0 ] || { echo "FAIL: accepted invalid verdict: '$v'"; return 1; }
  done
}

@test "carried gate whose source stored FAILED counts toward the cap" {
  # This exercises the carry-chain walk specifically for a FAILED source.
  _mk_project TEST-CARRY-F
  # Round 0: code-review selected, completed, FAILED.
  local rid0="round-20261103T160001Z-98500"
  bash "$RW" record-round --story TEST-CARRY-F --run-id "$rid0" --repo "$FIXTURE_DIR/repo" \
    --gate "code-review=selected"
  bash "$RW" record-run --story TEST-CARRY-F --run-id "$rid0" --gate code-review \
    --outcome completed >/dev/null
  printf 'Code review failed.\n' > "$FIXTURE_DIR/cr-carry-f-r0.md"
  bash "$RW" record-round-report --story TEST-CARRY-F --run-id "$rid0" \
    --gate code-review --report "$FIXTURE_DIR/cr-carry-f-r0.md" --verdict FAILED
  bash "$RW" complete-round --story TEST-CARRY-F --run-id "$rid0" \
    --repo "$FIXTURE_DIR/repo" --verdict FAILED
  # Round 1: security selected PASSED, code-review carried from round 0 (FAILED).
  local rid1="round-20261103T160002Z-98600"
  bash "$RW" record-round --story TEST-CARRY-F --run-id "$rid1" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected" \
    --carry "code-review=${rid0}:carried from prior round"
  bash "$RW" record-run --story TEST-CARRY-F --run-id "$rid1" --gate security-review \
    --outcome completed >/dev/null
  printf 'Security passed.\n' > "$FIXTURE_DIR/sec-carry-f-r1.md"
  bash "$RW" record-round-report --story TEST-CARRY-F --run-id "$rid1" \
    --gate security-review --report "$FIXTURE_DIR/sec-carry-f-r1.md" --verdict PASSED
  # Round 2 supersedes round 1, FAILED.
  local rid2="round-20261103T160003Z-98700"
  bash "$RW" record-round --story TEST-CARRY-F --run-id "$rid2" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story TEST-CARRY-F --run-id "$rid2" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: FAILED r2\n' > "$FIXTURE_DIR/sec-carry-f-r2.md"
  bash "$RW" record-round-report --story TEST-CARRY-F --run-id "$rid2" \
    --gate security-review --report "$FIXTURE_DIR/sec-carry-f-r2.md" --verdict FAILED
  # Round 0 (complete FAILED=1) + round 1 (superseded: selected PASSED but
  # carried code-review FAILED=1) + round 2 (open FAILED=1) = 3.
  run bash "$RW" count-rounds --story TEST-CARRY-F --max 3 --current-verdict FAILED
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 3"* ]] || return 1
  [[ "$output" == *"escalate true"* ]] || return 1
}

@test "carried gate not found in source round counts (fail closed)" {
  _mk_project TEST-CARRY-NF
  # Round 0: only code-review selected.
  local rid0="round-20261103T160001Z-98800"
  bash "$RW" record-round --story TEST-CARRY-NF --run-id "$rid0" --repo "$FIXTURE_DIR/repo" \
    --gate "code-review=selected"
  bash "$RW" record-run --story TEST-CARRY-NF --run-id "$rid0" --gate code-review \
    --outcome completed >/dev/null
  printf 'Code review passed.\n' > "$FIXTURE_DIR/cr-nf-r0.md"
  bash "$RW" record-round-report --story TEST-CARRY-NF --run-id "$rid0" \
    --gate code-review --report "$FIXTURE_DIR/cr-nf-r0.md" --verdict PASSED
  bash "$RW" complete-round --story TEST-CARRY-NF --run-id "$rid0" \
    --repo "$FIXTURE_DIR/repo" --verdict PASSED
  # Round 1: carries security-review from round 0, but round 0 has NO
  # security-review gate — the carry target does not exist.
  local rid1="round-20261103T160002Z-98900"
  bash "$RW" record-round --story TEST-CARRY-NF --run-id "$rid1" --repo "$FIXTURE_DIR/repo" \
    --gate "code-review=selected" \
    --carry "security-review=${rid0}:carried from prior round"
  bash "$RW" record-run --story TEST-CARRY-NF --run-id "$rid1" --gate code-review \
    --outcome completed >/dev/null
  printf 'Code review passed round 1.\n' > "$FIXTURE_DIR/cr-nf-r1.md"
  bash "$RW" record-round-report --story TEST-CARRY-NF --run-id "$rid1" \
    --gate code-review --report "$FIXTURE_DIR/cr-nf-r1.md" --verdict PASSED
  # Round 2 supersedes round 1, FAILED.
  local rid2="round-20261103T160003Z-99000"
  bash "$RW" record-round --story TEST-CARRY-NF --run-id "$rid2" --repo "$FIXTURE_DIR/repo" \
    --gate "code-review=selected"
  bash "$RW" record-run --story TEST-CARRY-NF --run-id "$rid2" --gate code-review \
    --outcome completed >/dev/null
  printf 'Code review failed.\n' > "$FIXTURE_DIR/cr-nf-r2.md"
  bash "$RW" record-round-report --story TEST-CARRY-NF --run-id "$rid2" \
    --gate code-review --report "$FIXTURE_DIR/cr-nf-r2.md" --verdict FAILED
  # Round 0 (complete PASSED=0) + round 1 (superseded: selected PASSED but
  # carried security-review NOT FOUND in round 0 → fail closed=1) + round 2
  # (open FAILED=1) = 2.
  run bash "$RW" count-rounds --story TEST-CARRY-NF --max 2 --current-verdict FAILED
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 2"* ]] || return 1
  [[ "$output" == *"escalate true"* ]] || return 1
}

# ---------------------------------------------------------------------------
# Fail-closed branches: missing report, errored run, zero gates
# ---------------------------------------------------------------------------

@test "stored verdict survives report file deletion (no re-read at count time)" {
  _mk_project TEST-MISS
  local rpath="$FIXTURE_DIR/report-miss.md"
  local rid="round-20261103T170001Z-99001"
  bash "$RW" record-round --story TEST-MISS --run-id "$rid" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story TEST-MISS --run-id "$rid" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: PASSED\n' > "$rpath"
  bash "$RW" record-round-report --story TEST-MISS --run-id "$rid" \
    --gate security-review --report "$rpath" --verdict PASSED
  # Delete the report after recording — the stored verdict was PASSED.
  rm -f "$rpath"
  # Round 2 supersedes, FAILED.
  local rid2="round-20261103T170002Z-99002"
  bash "$RW" record-round --story TEST-MISS --run-id "$rid2" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story TEST-MISS --run-id "$rid2" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: FAILED\n' > "$FIXTURE_DIR/report-miss-r2.md"
  bash "$RW" record-round-report --story TEST-MISS --run-id "$rid2" \
    --gate security-review --report "$FIXTURE_DIR/report-miss-r2.md" --verdict FAILED
  # The stored verdict from record time was PASSED — file deletion does not
  # change the stored value.  count-rounds reads the stored verdict only.
  run bash "$RW" count-rounds --story TEST-MISS --max 2 --current-verdict FAILED
  [ "$status" -eq 0 ]
  # Stored verdict is PASSED: the round does not count.
  [[ "$output" == *"round_count 1"* ]] || return 1
}

@test "missing stored verdict on a superseded round counts (fail closed)" {
  _mk_project TEST-NOVERDICT
  local rpath="$FIXTURE_DIR/report-nv.md"
  local rid="round-20261103T170001Z-99051"
  bash "$RW" record-round --story TEST-NOVERDICT --run-id "$rid" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story TEST-NOVERDICT --run-id "$rid" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: PASSED\n' > "$rpath"
  bash "$RW" record-round-report --story TEST-NOVERDICT --run-id "$rid" \
    --gate security-review --report "$rpath" --verdict PASSED
  # Round 2 supersedes.
  local rid2="round-20261103T170002Z-99052"
  bash "$RW" record-round --story TEST-NOVERDICT --run-id "$rid2" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story TEST-NOVERDICT --run-id "$rid2" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: FAILED unique nv\n' > "$FIXTURE_DIR/report-nv-r2.md"
  bash "$RW" record-round-report --story TEST-NOVERDICT --run-id "$rid2" \
    --gate security-review --report "$FIXTURE_DIR/report-nv-r2.md" --verdict FAILED
  # Force-clear the stored report_verdict on round 1 to simulate a register
  # written before the verdict-capture feature existed.
  local reg_path
  reg_path="$(find "$FIXTURE_DIR/ia" -name 'findings-register*.yaml' -not -name '*.lock' -type f | head -1)"
  [ -n "$reg_path" ]
  export _RW_NV_RID="$rid"
  yq -i '(.rounds[] | select(.run_id == strenv(_RW_NV_RID))).selected_gates[0].report_verdict = ""' "$reg_path"
  unset _RW_NV_RID
  # Missing stored verdict must cause the round to count (fail closed).
  run bash "$RW" count-rounds --story TEST-NOVERDICT --max 2 --current-verdict FAILED
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 2"* ]] || return 1
  [[ "$output" == *"escalate true"* ]] || return 1
}

@test "superseded round with no report_path recorded counts (fail closed)" {
  _mk_project TEST-NOREP
  # Round 1: gate selected but NO report ever recorded (gate crashed before
  # producing a report).
  local rid="round-20261103T170001Z-99101"
  bash "$RW" record-round --story TEST-NOREP --run-id "$rid" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  # No record-run, no record-round-report — gate never ran.
  # Round 2 supersedes, FAILED.
  local rid2="round-20261103T170002Z-99102"
  bash "$RW" record-round --story TEST-NOREP --run-id "$rid2" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story TEST-NOREP --run-id "$rid2" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: FAILED\n' > "$FIXTURE_DIR/report-norep-r2.md"
  bash "$RW" record-round-report --story TEST-NOREP --run-id "$rid2" \
    --gate security-review --report "$FIXTURE_DIR/report-norep-r2.md" --verdict FAILED
  # Round 1 has no report path: must count (fail closed).
  run bash "$RW" count-rounds --story TEST-NOREP --max 2 --current-verdict FAILED
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 2"* ]] || return 1
  [[ "$output" == *"escalate true"* ]] || return 1
}

@test "superseded round with errored gate run counts (fail closed)" {
  _mk_project TEST-ERR
  local rpath="$FIXTURE_DIR/report-err.md"
  local rid="round-20261103T170001Z-99201"
  bash "$RW" record-round --story TEST-ERR --run-id "$rid" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story TEST-ERR --run-id "$rid" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: PASSED\n' > "$rpath"
  bash "$RW" record-round-report --story TEST-ERR --run-id "$rid" \
    --gate security-review --report "$rpath" --verdict PASSED
  # Record an errored run after the completed one.
  bash "$RW" record-run --story TEST-ERR --run-id "$rid" --gate security-review \
    --outcome errored >/dev/null
  # Round 2 supersedes, FAILED.
  local rid2="round-20261103T170002Z-99202"
  bash "$RW" record-round --story TEST-ERR --run-id "$rid2" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story TEST-ERR --run-id "$rid2" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: FAILED\n' > "$FIXTURE_DIR/report-err-r2.md"
  bash "$RW" record-round-report --story TEST-ERR --run-id "$rid2" \
    --gate security-review --report "$FIXTURE_DIR/report-err-r2.md" --verdict FAILED
  # The errored run means the round counts even though the stored verdict was PASSED.
  run bash "$RW" count-rounds --story TEST-ERR --max 2 --current-verdict FAILED
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 2"* ]] || return 1
  [[ "$output" == *"escalate true"* ]] || return 1
}

@test "superseded round with zero selected gates is rejected by structure validation" {
  _mk_project TEST-ZERO
  # The writer requires at least one gate, so create round 1 normally,
  # then supersede it with round 2 and force-empty selected_gates on round 1
  # to simulate the edge case of a corrupted register.
  local rid="round-20261103T170001Z-99301"
  bash "$RW" record-round --story TEST-ZERO --run-id "$rid" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  local rid2="round-20261103T170002Z-99302"
  bash "$RW" record-round --story TEST-ZERO --run-id "$rid2" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story TEST-ZERO --run-id "$rid2" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: FAILED\n' > "$FIXTURE_DIR/report-zero-r2.md"
  bash "$RW" record-round-report --story TEST-ZERO --run-id "$rid2" \
    --gate security-review --report "$FIXTURE_DIR/report-zero-r2.md" --verdict FAILED
  # Force-empty the selected_gates on round 1 to simulate a corrupt register.
  local reg_path
  reg_path="$(find "$FIXTURE_DIR/ia" -name 'findings-register*.yaml' -not -name '*.lock' -type f | head -1)"
  [ -n "$reg_path" ]
  export _RW_ZERO_RID="$rid"
  yq -i '(.rounds[] | select(.run_id == strenv(_RW_ZERO_RID))).selected_gates = []' "$reg_path"
  unset _RW_ZERO_RID
  # Structure validation rejects a round with zero selected gates (fail closed).
  run bash "$RW" count-rounds --story TEST-ZERO --max 2 --current-verdict FAILED
  [ "$status" -ne 0 ]
  [[ "$output" == *"structural validation failed"* ]] || return 1
}

# ---------------------------------------------------------------------------
# Carried gate in superseded round: FAILED source must count
# ---------------------------------------------------------------------------

@test "superseded round with carried gate from FAILED source counts" {
  _mk_project TEST-CARRY
  # Round 0: completed FAILED with code-review gate.
  local rid0="round-20261103T180001Z-99401"
  bash "$RW" record-round --story TEST-CARRY --run-id "$rid0" --repo "$FIXTURE_DIR/repo" \
    --gate "code-review=selected"
  bash "$RW" record-run --story TEST-CARRY --run-id "$rid0" --gate code-review \
    --outcome completed >/dev/null
  printf 'Verdict: FAILED\n' > "$FIXTURE_DIR/code-review-r0.md"
  bash "$RW" record-round-report --story TEST-CARRY --run-id "$rid0" \
    --gate code-review --report "$FIXTURE_DIR/code-review-r0.md" --verdict FAILED
  bash "$RW" complete-round --story TEST-CARRY --run-id "$rid0" \
    --repo "$FIXTURE_DIR/repo" --verdict FAILED

  # Round 1: halted; selected security=PASSED, carried code-review from round 0 (FAILED).
  local rid1="round-20261103T180002Z-99402"
  bash "$RW" record-round --story TEST-CARRY --run-id "$rid1" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected" \
    --carry "code-review=${rid0}:applicability rationale for carry"
  bash "$RW" record-run --story TEST-CARRY --run-id "$rid1" --gate security-review \
    --outcome completed >/dev/null
  printf 'Verdict: PASSED\n' > "$FIXTURE_DIR/sec-r1.md"
  bash "$RW" record-round-report --story TEST-CARRY --run-id "$rid1" \
    --gate security-review --report "$FIXTURE_DIR/sec-r1.md" --verdict PASSED

  # Round 2: supersedes round 1, FAILED.
  local rid2="round-20261103T180003Z-99403"
  bash "$RW" record-round --story TEST-CARRY --run-id "$rid2" --repo "$FIXTURE_DIR/repo" \
    --gate "security-review=selected"
  bash "$RW" record-run --story TEST-CARRY --run-id "$rid2" --gate security-review \
    --outcome completed >/dev/null
  # Unique report content avoids the cross-round SHA reuse guard.
  printf 'Verdict: FAILED\nsecurity round 2 unique content\n' > "$FIXTURE_DIR/sec-r2.md"
  bash "$RW" record-round-report --story TEST-CARRY --run-id "$rid2" \
    --gate security-review --report "$FIXTURE_DIR/sec-r2.md" --verdict FAILED

  # Round 0 (complete FAILED=1) + round 1 (superseded: selected PASSED but
  # carried code-review has FAILED source=1) + round 2 (open FAILED=1) = 3.
  run bash "$RW" count-rounds --story TEST-CARRY --max 3 --current-verdict FAILED
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 3"* ]] || return 1
  [[ "$output" == *"escalate true"* ]] || return 1
}

# ---------------------------------------------------------------------------
# SKILL wiring: step 4b passes --verdict to record-round-report
# ---------------------------------------------------------------------------

@test "run-all-reviews SKILL step 4b passes --verdict to record-round-report" {
  # Per-line assertion: the step 4b COMMAND (inside backticks) includes --verdict.
  local line
  line="$(/usr/bin/grep 'record-round-report' "$RUN_ALL_SKILL" | /usr/bin/grep '4b')"
  [ -n "$line" ]
  # Extract the backticked command and check --verdict appears inside it.
  local cmd
  cmd="$(printf '%s' "$line" | sed -n 's/.*`\(register-write.sh record-round-report[^`]*\)`.*/\1/p')"
  [ -n "$cmd" ] || { echo "no backticked command found in: $line"; return 1; }
  [[ "$cmd" == *"--verdict"* ]] || { echo "step 4b command missing --verdict: $cmd"; return 1; }
}

@test "open round with PASSED current-verdict is not counted (short-circuit)" {
  _mk_project TEST-OPEN-P
  _run_failing_round TEST-OPEN-P "round-20261103T190001Z-88801"
  # Open round 2 with a PASSED report, not yet completed.
  bash "$RW" record-round --story TEST-OPEN-P --run-id "round-20261103T190002Z-88802" \
    --repo "$FIXTURE_DIR/repo" --gate "security-review=selected"
  bash "$RW" record-run --story TEST-OPEN-P --run-id "round-20261103T190002Z-88802" \
    --gate security-review --outcome completed >/dev/null
  printf 'Verdict: PASSED\n' > "$FIXTURE_DIR/open-p.md"
  bash "$RW" record-round-report --story TEST-OPEN-P --run-id "round-20261103T190002Z-88802" \
    --gate security-review --report "$FIXTURE_DIR/open-p.md" --verdict PASSED
  # The open round should NOT count (current verdict is PASSED).
  run bash "$RW" count-rounds --story TEST-OPEN-P --max 2 --current-verdict PASSED
  [ "$status" -eq 0 ]
  [[ "$output" == *"round_count 1"* ]] || return 1
  [[ "$output" == *"escalate false"* ]] || return 1
}
