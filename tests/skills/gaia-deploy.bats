#!/usr/bin/env bats
# tests/skills/gaia-deploy.bats — /gaia-deploy Pattern A end-to-end (E73-S5, AC2/3/4/5/6/7/14).
#
# Exercises the five-phase pipeline (pre-deploy gate → deploy → health-check →
# smoke → verdict) against fixtures and a mock adapter / mock smoke runners.

bats_require_minimum_version 1.5.0

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/../../plugins/gaia" && pwd)"
  SKILL_SCRIPTS="$PLUGIN_ROOT/skills/gaia-deploy/scripts"
  WORK_TMP="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/gaia-deploy-$$-$BATS_TEST_NUMBER"
  mkdir -p "$WORK_TMP/evidence/deploy" "$WORK_TMP/evidence/smoke"
  export GAIA_DEPLOY_EVIDENCE_DIR="$WORK_TMP/evidence"
}

teardown() {
  if [ -n "${WORK_TMP:-}" ] && [ -d "$WORK_TMP" ]; then
    rm -rf "$WORK_TMP" 2>/dev/null || true
  fi
}

# ---------- Pre-deploy gate (AC2) ----------

@test "pre-deploy gate: APPROVE allows deploy" {
  cat > "$WORK_TMP/composite-verdict.json" <<EOF
{"composite": "APPROVE", "reviews": []}
EOF
  GAIA_DEPLOY_COMPOSITE_FILE="$WORK_TMP/composite-verdict.json" run \
    "$SKILL_SCRIPTS/pre-deploy-gate.sh" --story-key E73-S5
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "APPROVE"
}

@test "pre-deploy gate: BLOCKED halts pipeline" {
  cat > "$WORK_TMP/composite-verdict.json" <<EOF
{"composite": "REQUEST_CHANGES", "reviews": [{"name":"qa-tests","status":"FAILED"}]}
EOF
  GAIA_DEPLOY_COMPOSITE_FILE="$WORK_TMP/composite-verdict.json" run \
    "$SKILL_SCRIPTS/pre-deploy-gate.sh" --story-key E73-S5
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "BLOCKED\|REQUEST_CHANGES"
  echo "$output" | grep -q "qa-tests"
}

@test "pre-deploy gate: missing composite file emits BLOCKED diagnostic" {
  GAIA_DEPLOY_COMPOSITE_FILE="$WORK_TMP/does-not-exist.json" run \
    "$SKILL_SCRIPTS/pre-deploy-gate.sh" --story-key E73-S5
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "BLOCKED"
}

# ---------- Deploy adapter dispatch (AC3) ----------

@test "deploy dispatch: adapter exit 0 → phase succeeds, evidence captured" {
  cat > "$WORK_TMP/fake-adapter.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$3"
echo "deployed env=$1 ver=$2" > "$3/deploy.stdout"
exit 0
EOF
  chmod +x "$WORK_TMP/fake-adapter.sh"
  GAIA_DEPLOY_ADAPTER_CMD="$WORK_TMP/fake-adapter.sh" \
    run "$SKILL_SCRIPTS/deploy-dispatch.sh" --env staging --version v1.2.3 --output-dir "$WORK_TMP/evidence/deploy"
  [ "$status" -eq 0 ]
  [ -f "$WORK_TMP/evidence/deploy/deploy.stdout" ]
}

@test "deploy dispatch: adapter exit non-zero → BLOCKED with diagnostic" {
  cat > "$WORK_TMP/fake-adapter.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$3"
echo "adapter crash" > "$3/deploy.stderr"
exit 1
EOF
  chmod +x "$WORK_TMP/fake-adapter.sh"
  GAIA_DEPLOY_ADAPTER_CMD="$WORK_TMP/fake-adapter.sh" \
    run "$SKILL_SCRIPTS/deploy-dispatch.sh" --env staging --version v1 --output-dir "$WORK_TMP/evidence/deploy"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "BLOCKED"
}

# ---------- Health-check (AC4) ----------

@test "health-check: 2xx within timeout → PASSED" {
  GAIA_DEPLOY_HEALTH_FAKE_RC=0 run \
    "$SKILL_SCRIPTS/health-check.sh" --url "http://example.invalid/health" --timeout 2 --output-dir "$WORK_TMP/evidence/deploy"
  [ "$status" -eq 0 ]
  [ -f "$WORK_TMP/evidence/deploy/health-check.json" ]
  jq -e '.status == "passed"' "$WORK_TMP/evidence/deploy/health-check.json"
}

@test "health-check: timeout → BLOCKED with remediation" {
  GAIA_DEPLOY_HEALTH_FAKE_RC=1 run \
    "$SKILL_SCRIPTS/health-check.sh" --url "http://example.invalid/health" --timeout 1 --output-dir "$WORK_TMP/evidence/deploy"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "BLOCKED\|timeout"
  jq -e '.status == "timeout"' "$WORK_TMP/evidence/deploy/health-check.json"
}

# ---------- Health-check mode (E78-S3, FR-425) ----------
# AC1 — Default poll preserved (no --mode flag → poll behavior unchanged).
# AC2 — Skip mode recognized (--mode skip bypasses poll).
# AC3 — Evidence record on skip (health-check.json captures the configured-skip reason).
# AC4 — Invalid mode rejected (any value other than poll | skip halts with diagnostic).

@test "health-check mode: omitted flag preserves default poll behavior (AC1)" {
  GAIA_DEPLOY_HEALTH_FAKE_RC=0 run \
    "$SKILL_SCRIPTS/health-check.sh" --url "http://example.invalid/health" --timeout 2 --output-dir "$WORK_TMP/evidence/deploy"
  [ "$status" -eq 0 ]
  jq -e '.status == "passed"' "$WORK_TMP/evidence/deploy/health-check.json"
}

@test "health-check mode: explicit poll runs poll loop (AC1)" {
  GAIA_DEPLOY_HEALTH_FAKE_RC=0 run \
    "$SKILL_SCRIPTS/health-check.sh" --mode poll --url "http://example.invalid/health" --timeout 2 --output-dir "$WORK_TMP/evidence/deploy"
  [ "$status" -eq 0 ]
  jq -e '.status == "passed"' "$WORK_TMP/evidence/deploy/health-check.json"
}

@test "health-check mode: skip bypasses poll and writes evidence (AC2, AC3)" {
  # No URL is required when skipping; the skill MUST not invoke curl.
  # Setting GAIA_DEPLOY_HEALTH_FAKE_RC=1 would fail a poll run — proves we did not poll.
  GAIA_DEPLOY_HEALTH_FAKE_RC=1 run \
    "$SKILL_SCRIPTS/health-check.sh" --mode skip --output-dir "$WORK_TMP/evidence/deploy"
  [ "$status" -eq 0 ]
  [ -f "$WORK_TMP/evidence/deploy/health-check.json" ]
  jq -e '.status == "skipped"' "$WORK_TMP/evidence/deploy/health-check.json"
  jq -e '.mode == "skip"' "$WORK_TMP/evidence/deploy/health-check.json"
  jq -e '.reason == "configured skip"' "$WORK_TMP/evidence/deploy/health-check.json"
}

@test "health-check mode: invalid value rejected with actionable error (AC4)" {
  run "$SKILL_SCRIPTS/health-check.sh" --mode banana --url "http://example.invalid/health" --output-dir "$WORK_TMP/evidence/deploy"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "invalid"
  echo "$output" | grep -q "banana"
  echo "$output" | grep -q "poll"
  echo "$output" | grep -q "skip"
}

# AC5 — Schema validation: project-config.schema.json declares health_check.mode
# as enum {poll, skip}. Validated via the jsonschema adapter.
@test "health-check mode: schema declares health_check.mode enum [poll, skip] (AC5)" {
  SCHEMA="$PLUGIN_ROOT/schemas/project-config.schema.json"
  [ -f "$SCHEMA" ]
  # The health_check definition must exist and declare exactly the two enum values.
  jq -e '.definitions.healthCheck.properties.mode.enum == ["poll", "skip"]' "$SCHEMA"
  # Default value MUST be "poll" for backward compatibility.
  jq -e '.definitions.healthCheck.properties.mode.default == "poll"' "$SCHEMA"
  # Top-level health_check property must reference the definition.
  jq -e '.properties.health_check."$ref" == "#/definitions/healthCheck"' "$SCHEMA"
}

# ---------- Smoke orchestration (AC5, AC14) ----------

@test "smoke orchestrate: all suites APPROVE → returns 0" {
  cat > "$WORK_TMP/suites.txt" <<EOF
mock-pass
mock-pass
EOF
  cat > "$WORK_TMP/mock-pass-runner.sh" <<'EOF'
#!/usr/bin/env bash
echo APPROVE
exit 0
EOF
  chmod +x "$WORK_TMP/mock-pass-runner.sh"
  GAIA_DEPLOY_SMOKE_RUNNER="$WORK_TMP/mock-pass-runner.sh" \
    run "$SKILL_SCRIPTS/smoke-orchestrate.sh" --suites-file "$WORK_TMP/suites.txt" --target-url "http://t" --output-dir "$WORK_TMP/evidence/smoke"
  [ "$status" -eq 0 ]
  ls "$WORK_TMP/evidence/smoke" | grep -q "mock-pass"
}

@test "smoke orchestrate: one suite REQUEST_CHANGES → returns non-zero" {
  cat > "$WORK_TMP/suites.txt" <<EOF
mock-fail
EOF
  cat > "$WORK_TMP/mock-fail-runner.sh" <<'EOF'
#!/usr/bin/env bash
echo REQUEST_CHANGES
exit 1
EOF
  chmod +x "$WORK_TMP/mock-fail-runner.sh"
  GAIA_DEPLOY_SMOKE_RUNNER="$WORK_TMP/mock-fail-runner.sh" \
    run "$SKILL_SCRIPTS/smoke-orchestrate.sh" --suites-file "$WORK_TMP/suites.txt" --target-url "http://t" --output-dir "$WORK_TMP/evidence/smoke"
  [ "$status" -ne 0 ]
}

@test "smoke orchestrate: --skip-smoke produces WARNING and exits 0" {
  : > "$WORK_TMP/suites.txt"
  run "$SKILL_SCRIPTS/smoke-orchestrate.sh" --skip-smoke --output-dir "$WORK_TMP/evidence/smoke"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "WARNING"
}

# ---------- Empty smoke_suites / manual-checklist mode (E78-S5, FR-427) ----------
# AC1 — Empty suites file produces APPROVE evidence with required metadata fields.
# AC2 — Empty suites path MUST NOT yield BLOCKED.
# AC3 — Non-empty suites preserves existing path (backward compatibility).
# AC4 — evidence/smoke/ directory is created if absent.
# AC5 — manual-checklist.json contains valid JSON with required schema.

@test "smoke orchestrate: empty suites-file writes manual-checklist.json with APPROVE (AC1, AC2)" {
  : > "$WORK_TMP/suites.txt"
  run "$SKILL_SCRIPTS/smoke-orchestrate.sh" \
    --suites-file "$WORK_TMP/suites.txt" \
    --target-url "http://t" \
    --output-dir "$WORK_TMP/evidence/smoke"
  [ "$status" -eq 0 ]
  [ -f "$WORK_TMP/evidence/smoke/manual-checklist.json" ]
  jq -e '.verdict == "APPROVE"' "$WORK_TMP/evidence/smoke/manual-checklist.json"
  ! echo "$output" | grep -qi "BLOCKED"
}

@test "smoke orchestrate: --mode manual-checklist writes APPROVE evidence without runner (AC1, AC2)" {
  run "$SKILL_SCRIPTS/smoke-orchestrate.sh" \
    --mode manual-checklist \
    --output-dir "$WORK_TMP/evidence/smoke"
  [ "$status" -eq 0 ]
  [ -f "$WORK_TMP/evidence/smoke/manual-checklist.json" ]
  jq -e '.verdict == "APPROVE"' "$WORK_TMP/evidence/smoke/manual-checklist.json"
  jq -e '.mode == "manual-checklist"' "$WORK_TMP/evidence/smoke/manual-checklist.json"
}

@test "smoke orchestrate: non-empty suites preserves existing path (AC3)" {
  cat > "$WORK_TMP/suites.txt" <<EOF
mock-pass
EOF
  cat > "$WORK_TMP/mock-pass-runner.sh" <<'EOF'
#!/usr/bin/env bash
echo APPROVE
exit 0
EOF
  chmod +x "$WORK_TMP/mock-pass-runner.sh"
  GAIA_DEPLOY_SMOKE_RUNNER="$WORK_TMP/mock-pass-runner.sh" \
    run "$SKILL_SCRIPTS/smoke-orchestrate.sh" \
      --suites-file "$WORK_TMP/suites.txt" \
      --target-url "http://t" \
      --output-dir "$WORK_TMP/evidence/smoke"
  [ "$status" -eq 0 ]
  [ -f "$WORK_TMP/evidence/smoke/mock-pass.json" ]
  # Must NOT write manual-checklist.json when the suite list is non-empty.
  [ ! -f "$WORK_TMP/evidence/smoke/manual-checklist.json" ]
}

@test "smoke orchestrate: empty suites creates evidence/smoke/ if absent (AC4)" {
  rm -rf "$WORK_TMP/evidence/smoke"
  : > "$WORK_TMP/suites.txt"
  run "$SKILL_SCRIPTS/smoke-orchestrate.sh" \
    --suites-file "$WORK_TMP/suites.txt" \
    --target-url "http://t" \
    --output-dir "$WORK_TMP/evidence/smoke"
  [ "$status" -eq 0 ]
  [ -d "$WORK_TMP/evidence/smoke" ]
  [ -f "$WORK_TMP/evidence/smoke/manual-checklist.json" ]
}

@test "smoke orchestrate: manual-checklist.json schema has required fields (AC5)" {
  : > "$WORK_TMP/suites.txt"
  run "$SKILL_SCRIPTS/smoke-orchestrate.sh" \
    --suites-file "$WORK_TMP/suites.txt" \
    --target-url "http://t" \
    --checklist-source "docs/manual-checklist.md" \
    --output-dir "$WORK_TMP/evidence/smoke"
  [ "$status" -eq 0 ]
  jq -e '.verdict == "APPROVE"' "$WORK_TMP/evidence/smoke/manual-checklist.json"
  jq -e '.mode == "manual-checklist"' "$WORK_TMP/evidence/smoke/manual-checklist.json"
  jq -e '.checklist_source == "docs/manual-checklist.md"' "$WORK_TMP/evidence/smoke/manual-checklist.json"
  jq -e '.tester_acknowledgement | type == "string"' "$WORK_TMP/evidence/smoke/manual-checklist.json"
  jq -e '.tester_acknowledgement | length > 0' "$WORK_TMP/evidence/smoke/manual-checklist.json"
  # ISO 8601 timestamp pattern: YYYY-MM-DDTHH:MM:SSZ
  jq -e '.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' \
    "$WORK_TMP/evidence/smoke/manual-checklist.json"
}

@test "smoke orchestrate: empty suites with no --checklist-source defaults to 'none' (AC5)" {
  : > "$WORK_TMP/suites.txt"
  run "$SKILL_SCRIPTS/smoke-orchestrate.sh" \
    --suites-file "$WORK_TMP/suites.txt" \
    --target-url "http://t" \
    --output-dir "$WORK_TMP/evidence/smoke"
  [ "$status" -eq 0 ]
  jq -e '.checklist_source == "none"' "$WORK_TMP/evidence/smoke/manual-checklist.json"
}

# ---------- Final verdict aggregation (AC6) ----------

@test "verdict aggregate: all APPROVE → final PASSED" {
  mkdir -p "$WORK_TMP/evidence/smoke"
  cat > "$WORK_TMP/evidence/smoke/suite-1.json" <<EOF
{"name":"e2e","verdict":"APPROVE"}
EOF
  cat > "$WORK_TMP/evidence/smoke/suite-2.json" <<EOF
{"name":"perf","verdict":"APPROVE"}
EOF
  run "$SKILL_SCRIPTS/verdict-aggregate.sh" --evidence-dir "$WORK_TMP/evidence" --env staging --version v1
  [ "$status" -eq 0 ]
  [ -f "$WORK_TMP/evidence/deployment-report.json" ]
  jq -e '.final_verdict == "PASSED"' "$WORK_TMP/evidence/deployment-report.json"
}

@test "verdict aggregate: one BLOCKED → final FAILED" {
  mkdir -p "$WORK_TMP/evidence/smoke"
  cat > "$WORK_TMP/evidence/smoke/suite-1.json" <<EOF
{"name":"e2e","verdict":"APPROVE"}
EOF
  cat > "$WORK_TMP/evidence/smoke/suite-2.json" <<EOF
{"name":"dast","verdict":"BLOCKED"}
EOF
  run "$SKILL_SCRIPTS/verdict-aggregate.sh" --evidence-dir "$WORK_TMP/evidence" --env staging --version v1
  [ "$status" -ne 0 ]
  jq -e '.final_verdict == "FAILED"' "$WORK_TMP/evidence/deployment-report.json"
}

@test "verdict aggregate: --skip-smoke flag produces PASSED with skip flag" {
  mkdir -p "$WORK_TMP/evidence/smoke"
  run "$SKILL_SCRIPTS/verdict-aggregate.sh" --evidence-dir "$WORK_TMP/evidence" --env staging --version v1 --skip-smoke
  [ "$status" -eq 0 ]
  jq -e '.final_verdict == "PASSED" and .skip_smoke == true' "$WORK_TMP/evidence/deployment-report.json"
}
