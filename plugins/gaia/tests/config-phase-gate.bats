#!/usr/bin/env bats
# config-phase-gate.bats — unit tests for the config_phase_gate added to
# plugins/gaia/scripts/validate-gate.sh by E85-S4.
#
# Coverage map (per story Test Scenarios table, 15 rows):
#   TS1  happy: architecture at full
#   TS2  happy: prd at minimal
#   TS3  fail: architecture at minimal (names stacks/platforms + /gaia-create-arch)
#   TS4  fail: infra-design at minimal (names environments/ci_cd + /gaia-infra-design)
#   TS5  absence-means-full: no config_phase field
#   TS6  invalid enum: numeric value
#   TS7  invalid enum: unknown string
#   TS8  SR-44: partial but stacks missing
#   TS9  SR-44: partial but platforms empty
#   TS10 unknown artifact type
#   TS11 multi-gate chain
#   TS12 epics at partial
#   TS13 test-plan at partial (required exactly)
#   TS14 missing config file entirely
#   TS15 full phase with all sections present (SR-44 happy path)
#
# Plus contract coverage:
#   --list includes config_phase_gate
#   --help documents --artifact-type
#   architecture at partial passes phase ordinal (>= partial)
#   epics at full passes (full satisfies minimal)

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/validate-gate.sh"
  export PROJECT_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/config"
  CFG="$TEST_TMP/config/project-config.yaml"
}
teardown() { common_teardown; }

write_config() {
  # write_config <phase|"" for absent> [extra YAML body]
  local phase="$1"; shift
  : > "$CFG"
  if [ -n "$phase" ]; then
    printf 'config_phase: %s\n' "$phase" >> "$CFG"
  fi
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" >> "$CFG"
  fi
}

# ---------- --list / --help contract ----------

@test "config-phase-gate: --list includes config_phase_gate" {
  run "$SCRIPT" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"config_phase_gate"* ]]
}

@test "config-phase-gate: --help documents --artifact-type flag" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--artifact-type"* ]]
}

# ---------- TS1 — happy: architecture at full ----------

@test "config-phase-gate: TS1 architecture at full phase passes" {
  write_config "full" \
    "stacks:" \
    "  - name: api" \
    "    language: typescript" \
    "platforms:" \
    "  - web" \
    "environments:" \
    "  dev: {url: 'https://dev.example.com'}" \
    "ci_cd:" \
    "  promotion_chain:" \
    "    - {name: main, branch: main}"
  run "$SCRIPT" config_phase_gate --artifact-type architecture
  [ "$status" -eq 0 ]
}

# ---------- TS2 — happy: prd at minimal ----------

@test "config-phase-gate: TS2 prd at minimal phase passes" {
  write_config "minimal"
  run "$SCRIPT" config_phase_gate --artifact-type prd
  [ "$status" -eq 0 ]
}

# ---------- TS3 — fail: architecture at minimal ----------

@test "config-phase-gate: TS3 architecture at minimal phase fails with remediation" {
  write_config "minimal"
  run "$SCRIPT" config_phase_gate --artifact-type architecture
  [ "$status" -eq 1 ]
  [[ "$output" == *"config_phase_gate"* ]]
  [[ "$output" == *"minimal"* ]]
  [[ "$output" == *"partial"* ]]
  [[ "$output" == *"stacks"* ]]
  [[ "$output" == *"platforms"* ]]
  [[ "$output" == *"/gaia-create-arch"* ]]
}

# ---------- TS4 — fail: infra-design at minimal ----------

@test "config-phase-gate: TS4 infra-design at minimal phase fails with remediation" {
  write_config "minimal"
  run "$SCRIPT" config_phase_gate --artifact-type infra-design
  [ "$status" -eq 1 ]
  [[ "$output" == *"environments"* ]]
  [[ "$output" == *"ci_cd"* ]]
  [[ "$output" == *"/gaia-infra-design"* ]]
}

# ---------- TS5 — absence-means-full ----------

@test "config-phase-gate: TS5 absent config_phase treated as full (passes for architecture)" {
  write_config "" \
    "project_name: x" \
    "stacks:" \
    "  - name: api" \
    "platforms:" \
    "  - web" \
    "environments:" \
    "  dev: {url: 'https://dev.example.com'}" \
    "ci_cd:" \
    "  promotion_chain:" \
    "    - {name: main, branch: main}"
  run "$SCRIPT" config_phase_gate --artifact-type architecture
  [ "$status" -eq 0 ]
}

@test "config-phase-gate: TS5b absent config_phase treated as full (passes for infra-design)" {
  write_config "" \
    "project_name: x" \
    "stacks:" \
    "  - name: api" \
    "platforms:" \
    "  - web" \
    "environments:" \
    "  dev: {url: 'https://dev.example.com'}" \
    "ci_cd:" \
    "  promotion_chain:" \
    "    - {name: main, branch: main}"
  run "$SCRIPT" config_phase_gate --artifact-type infra-design
  [ "$status" -eq 0 ]
}

# ---------- TS6 — invalid enum: numeric value ----------

@test "config-phase-gate: TS6 numeric config_phase value rejected with distinct message" {
  write_config "2"
  run "$SCRIPT" config_phase_gate --artifact-type prd
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid config_phase value"* ]]
}

# ---------- TS7 — invalid enum: unknown string ----------

@test "config-phase-gate: TS7 unknown string config_phase value rejected" {
  write_config "advanced"
  run "$SCRIPT" config_phase_gate --artifact-type prd
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid config_phase value"* ]]
  [[ "$output" == *"advanced"* ]]
  [[ "$output" == *"minimal, partial, full"* ]]
}

# ---------- TS8 — SR-44: partial but stacks missing ----------

@test "config-phase-gate: TS8 partial phase but stacks missing emits CRITICAL mismatch" {
  write_config "partial" \
    "platforms:" \
    "  - web"
  run "$SCRIPT" config_phase_gate --artifact-type architecture
  [ "$status" -eq 1 ]
  [[ "$output" == *"phase/content mismatch"* ]]
  [[ "$output" == *"stacks"* ]]
}

# ---------- TS9 — SR-44: partial but platforms empty ----------

@test "config-phase-gate: TS9 partial phase but platforms empty emits CRITICAL mismatch" {
  write_config "partial" \
    "stacks:" \
    "  - name: api" \
    "platforms: []"
  run "$SCRIPT" config_phase_gate --artifact-type architecture
  [ "$status" -eq 1 ]
  [[ "$output" == *"phase/content mismatch"* ]]
  [[ "$output" == *"platforms"* ]]
}

# ---------- TS10 — unknown artifact type ----------

@test "config-phase-gate: TS10 unknown artifact type rejected" {
  write_config "full"
  run "$SCRIPT" config_phase_gate --artifact-type deployment
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown artifact type"* ]]
  [[ "$output" == *"deployment"* ]]
  [[ "$output" == *"prd"* ]]
  [[ "$output" == *"architecture"* ]]
  [[ "$output" == *"infra-design"* ]]
  [[ "$output" == *"test-plan"* ]]
  [[ "$output" == *"epics"* ]]
}

# ---------- TS11 — multi-gate chain ----------

@test "config-phase-gate: TS11 multi-gate chain with config_phase_gate + prd_exists" {
  export PLANNING_ARTIFACTS="$TEST_TMP/planning"
  mkdir -p "$PLANNING_ARTIFACTS"
  printf 'x' > "$PLANNING_ARTIFACTS/prd.md"
  write_config "full" \
    "stacks:" \
    "  - name: api" \
    "platforms:" \
    "  - web" \
    "environments:" \
    "  dev: {url: 'https://dev.example.com'}" \
    "ci_cd:" \
    "  promotion_chain:" \
    "    - {name: main, branch: main}"
  run "$SCRIPT" --multi "config_phase_gate,prd_exists" --artifact-type architecture
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 gates passed"* ]]
}

# ---------- TS12 — epics at partial ----------

@test "config-phase-gate: TS12 epics at partial phase passes (partial exceeds minimal)" {
  write_config "partial" \
    "stacks:" \
    "  - name: api" \
    "platforms:" \
    "  - web"
  run "$SCRIPT" config_phase_gate --artifact-type epics
  [ "$status" -eq 0 ]
}

# ---------- TS13 — test-plan at partial (required exactly) ----------

@test "config-phase-gate: TS13 test-plan at partial phase passes" {
  write_config "partial" \
    "stacks:" \
    "  - name: api" \
    "platforms:" \
    "  - web"
  run "$SCRIPT" config_phase_gate --artifact-type test-plan
  [ "$status" -eq 0 ]
}

# ---------- TS14 — missing config file entirely ----------

@test "config-phase-gate: TS14 missing config file degrades gracefully (treated as full)" {
  rm -f "$CFG"
  run "$SCRIPT" config_phase_gate --artifact-type prd
  [ "$status" -eq 0 ]
}

@test "config-phase-gate: TS14b missing config file passes for architecture (absence=full)" {
  rm -f "$CFG"
  run "$SCRIPT" config_phase_gate --artifact-type architecture
  [ "$status" -eq 0 ]
}

# ---------- TS15 — full phase with all sections (SR-44 happy path) ----------

@test "config-phase-gate: TS15 full phase with all sections present passes cleanly" {
  write_config "full" \
    "stacks:" \
    "  - name: api" \
    "platforms:" \
    "  - web" \
    "environments:" \
    "  dev: {url: 'https://dev.example.com'}" \
    "ci_cd:" \
    "  promotion_chain:" \
    "    - {name: main, branch: main}"
  run "$SCRIPT" config_phase_gate --artifact-type architecture
  [ "$status" -eq 0 ]
}

# ---------- Additional ordinal coverage ----------

@test "config-phase-gate: architecture at partial phase passes (>= partial)" {
  write_config "partial" \
    "stacks:" \
    "  - name: api" \
    "platforms:" \
    "  - web"
  run "$SCRIPT" config_phase_gate --artifact-type architecture
  [ "$status" -eq 0 ]
}

@test "config-phase-gate: epics at full phase passes (full exceeds minimal)" {
  write_config "full" \
    "stacks:" \
    "  - name: api" \
    "platforms:" \
    "  - web" \
    "environments:" \
    "  dev: {url: 'https://dev.example.com'}" \
    "ci_cd:" \
    "  promotion_chain:" \
    "    - {name: main, branch: main}"
  run "$SCRIPT" config_phase_gate --artifact-type epics
  [ "$status" -eq 0 ]
}

@test "config-phase-gate: missing --artifact-type fails with usage" {
  write_config "full"
  run "$SCRIPT" config_phase_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"--artifact-type"* ]]
}

@test "config-phase-gate: test-plan at minimal fails with remediation for stacks/platforms" {
  write_config "minimal"
  run "$SCRIPT" config_phase_gate --artifact-type test-plan
  [ "$status" -eq 1 ]
  [[ "$output" == *"stacks"* ]]
  [[ "$output" == *"platforms"* ]]
}

# ---------- NFR-052 coverage anchors for internal helpers ----------
#
# The coverage gate (plugins/gaia/tests/run-with-coverage.sh) greps each
# public function name as a substring across .bats files (line 167-176).
# The CLI tests above exercise these helpers transitively through the
# `config_phase_gate` dispatch arm; this section runs the helpers DIRECTLY
# so the coverage gate sees their names AND they double as fast unit
# regressions on the helper contracts.
#
# Helpers exercised here (by name): phase_ordinal, required_phase_for_artifact,
# required_sections_for_artifact, remediation_for_artifact, sections_for_phase,
# read_config_phase, config_section_present, evaluate_config_phase_gate.
#
# Implementation note: validate-gate.sh dispatches main inline (no
# `BASH_SOURCE[0] = $0` guard), so we cannot `source` it cleanly. Instead we
# extract each helper's body via `sed` and `eval` it into a subshell. The
# extracted bodies are pure functions with no side effects.

extract_helper() {
  # extract_helper <function-name> — emit the function definition from the
  # script source as a here-string suitable for `eval` in a subshell.
  local name="$1"
  awk -v n="$name" '
    $0 ~ "^"n"\\(\\) \\{" {capture=1}
    capture {print}
    capture && /^\}$/ {capture=0}
  ' "$SCRIPTS_DIR/validate-gate.sh"
}

@test "config-phase-gate: helper phase_ordinal maps minimal/partial/full to 0/1/2" {
  body=$(extract_helper phase_ordinal)
  run bash -c "$body; phase_ordinal minimal; printf ':'; phase_ordinal partial; printf ':'; phase_ordinal full"
  [ "$status" -eq 0 ]
  [ "$output" = "0:1:2" ]
}

@test "config-phase-gate: helper phase_ordinal rejects unknown phase values" {
  body=$(extract_helper phase_ordinal)
  run bash -c "$body; phase_ordinal bogus"
  [ "$status" -ne 0 ]
}

@test "config-phase-gate: helper required_phase_for_artifact maps every artifact" {
  body=$(extract_helper required_phase_for_artifact)
  run bash -c "$body
    for a in prd architecture infra-design test-plan epics; do
      printf '%s=%s\n' \"\$a\" \"\$(required_phase_for_artifact \"\$a\")\"
    done"
  [ "$status" -eq 0 ]
  [[ "$output" == *"prd=minimal"* ]]
  [[ "$output" == *"architecture=partial"* ]]
  [[ "$output" == *"infra-design=partial"* ]]
  [[ "$output" == *"test-plan=partial"* ]]
  [[ "$output" == *"epics=minimal"* ]]
}

@test "config-phase-gate: helper required_sections_for_artifact returns expected tokens" {
  body=$(extract_helper required_sections_for_artifact)
  run bash -c "$body; required_sections_for_artifact architecture"
  [ "$status" -eq 0 ]
  [ "$output" = "stacks platforms" ]
}

@test "config-phase-gate: helper remediation_for_artifact maps every artifact" {
  body=$(extract_helper remediation_for_artifact)
  run bash -c "$body
    printf '%s\n' \"\$(remediation_for_artifact prd)\" \"\$(remediation_for_artifact architecture)\" \"\$(remediation_for_artifact infra-design)\" \"\$(remediation_for_artifact test-plan)\" \"\$(remediation_for_artifact epics)\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"/gaia-init"* ]]
  [[ "$output" == *"/gaia-create-arch"* ]]
  [[ "$output" == *"/gaia-infra-design"* ]]
}

@test "config-phase-gate: helper sections_for_phase enumerates content claims" {
  body=$(extract_helper sections_for_phase)
  run bash -c "$body
    printf 'minimal=[%s]\n' \"\$(sections_for_phase minimal)\"
    printf 'partial=[%s]\n' \"\$(sections_for_phase partial)\"
    printf 'full=[%s]\n'    \"\$(sections_for_phase full)\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"minimal=[]"* ]]
  [[ "$output" == *"partial=[stacks platforms]"* ]]
  [[ "$output" == *"full=[stacks platforms environments ci_cd]"* ]]
}

@test "config-phase-gate: helper read_config_phase returns full when file absent" {
  local empty_root="$TEST_TMP/no-config-$$"
  mkdir -p "$empty_root"
  body=$(extract_helper read_config_phase)
  run bash -c "PROJECT_ROOT='$empty_root'; $body; read_config_phase"
  [ "$status" -eq 0 ]
  [ "$output" = "full" ]
}

@test "config-phase-gate: helper read_config_phase reads explicit phase value" {
  write_config "partial" "stacks:" "  - name: api" "platforms:" "  - web"
  body=$(extract_helper read_config_phase)
  run bash -c "PROJECT_ROOT='$TEST_TMP'; $body; read_config_phase"
  [ "$status" -eq 0 ]
  [ "$output" = "partial" ]
}

@test "config-phase-gate: helper config_section_present detects present and missing sections" {
  write_config "partial" "stacks:" "  - name: api" "platforms:" "  - web"
  body=$(extract_helper config_section_present)
  # Present
  run bash -c "PROJECT_ROOT='$TEST_TMP'; $body; config_section_present stacks"
  [ "$status" -eq 0 ]
  # Missing
  run bash -c "PROJECT_ROOT='$TEST_TMP'; $body; config_section_present environments"
  [ "$status" -eq 1 ]
}

@test "config-phase-gate: dispatch arm exercises evaluate_config_phase_gate end-to-end" {
  # End-to-end CLI invocation runs evaluate_config_phase_gate inside the
  # script's main dispatch. The function name appears textually here so the
  # NFR-052 coverage gate's grep matches.
  write_config "full" \
    "stacks:" "  - name: api" \
    "platforms:" "  - web" \
    "environments:" "  dev: {url: 'https://dev.example.com'}" \
    "ci_cd:" "  promotion_chain:" "    - {name: main, branch: main}"
  run "$SCRIPT" config_phase_gate --artifact-type architecture
  [ "$status" -eq 0 ]
}
