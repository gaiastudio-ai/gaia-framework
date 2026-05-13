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
