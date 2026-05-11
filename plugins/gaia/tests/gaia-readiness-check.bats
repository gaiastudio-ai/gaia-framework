#!/usr/bin/env bats
# gaia-readiness-check.bats — tests for the readiness-check skill setup.sh
# Validates AC2 (dual gate enforcement), AC3 (finalize.sh pattern), and AC5
# (frontmatter linter compliance).

load 'test_helper.bash'

setup() {
  common_setup
  SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-readiness-check"
  SETUP_SCRIPT="$SKILL_DIR/scripts/setup.sh"
  FINALIZE_SCRIPT="$SKILL_DIR/scripts/finalize.sh"
  SKILL_FILE="$SKILL_DIR/SKILL.md"

  # Provide a minimal environment that setup.sh expects
  export TEST_ARTIFACTS="$TEST_TMP/test-artifacts"
  export PROJECT_ROOT="$TEST_TMP"
  export CHECKPOINT_PATH="$TEST_TMP/checkpoints"
  mkdir -p "$TEST_ARTIFACTS" "$CHECKPOINT_PATH"

  # Create a mock resolve-config.sh that emits the env vars setup.sh needs
  MOCK_SCRIPTS="$TEST_TMP/mock-scripts"
  mkdir -p "$MOCK_SCRIPTS"
  cat > "$MOCK_SCRIPTS/resolve-config.sh" <<'MOCK'
#!/usr/bin/env bash
echo "PROJECT_ROOT=$PROJECT_ROOT"
echo "TEST_ARTIFACTS=$TEST_ARTIFACTS"
echo "CHECKPOINT_PATH=$CHECKPOINT_PATH"
MOCK
  chmod +x "$MOCK_SCRIPTS/resolve-config.sh"

  # Create mock checkpoint.sh and lifecycle-event.sh
  cat > "$MOCK_SCRIPTS/checkpoint.sh" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  read)  exit 2 ;;   # no prior checkpoint
  write) exit 0 ;;
esac
MOCK
  chmod +x "$MOCK_SCRIPTS/checkpoint.sh"

  cat > "$MOCK_SCRIPTS/lifecycle-event.sh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$MOCK_SCRIPTS/lifecycle-event.sh"

  # Create mock validate-gate.sh that checks real file existence
  cat > "$MOCK_SCRIPTS/validate-gate.sh" <<'MOCK'
#!/usr/bin/env bash
# Minimal validate-gate that supports --multi with traceability_exists and ci_setup_exists
set -euo pipefail
while [ $# -gt 0 ]; do
  case "$1" in
    --multi)
      IFS=',' read -r -a GATES <<< "$2"
      for g in "${GATES[@]}"; do
        g="${g#"${g%%[![:space:]]*}"}"
        g="${g%"${g##*[![:space:]]}"}"
        case "$g" in
          traceability_exists)
            [ -f "${TEST_ARTIFACTS}/traceability-matrix.md" ] || { echo "validate-gate: traceability_exists failed — expected: ${TEST_ARTIFACTS}/traceability-matrix.md" >&2; exit 1; }
            ;;
          ci_setup_exists)
            [ -f "${TEST_ARTIFACTS}/ci-setup.md" ] || { echo "validate-gate: ci_setup_exists failed — expected: ${TEST_ARTIFACTS}/ci-setup.md" >&2; exit 1; }
            ;;
        esac
      done
      exit 0
      ;;
    *) shift ;;
  esac
done
MOCK
  chmod +x "$MOCK_SCRIPTS/validate-gate.sh"
}

teardown() { common_teardown; }

# ---------- AC1: SKILL.md exists with required frontmatter ----------

@test "SKILL.md exists at the expected skill directory path" {
  [ -f "$SKILL_FILE" ]
}

@test "SKILL.md frontmatter contains required 'name' field" {
  frontmatter=$(awk 'BEGIN{in_fm=0;seen=0}/^---[[:space:]]*$/{if(seen==0){in_fm=1;seen=1;next}else if(in_fm==1){exit}}in_fm==1{print}' "$SKILL_FILE")
  echo "$frontmatter" | grep -q '^name:'
}

@test "SKILL.md frontmatter contains required 'description' field" {
  frontmatter=$(awk 'BEGIN{in_fm=0;seen=0}/^---[[:space:]]*$/{if(seen==0){in_fm=1;seen=1;next}else if(in_fm==1){exit}}in_fm==1{print}' "$SKILL_FILE")
  echo "$frontmatter" | grep -q '^description:'
}

@test "SKILL.md frontmatter name is 'gaia-readiness-check'" {
  frontmatter=$(awk 'BEGIN{in_fm=0;seen=0}/^---[[:space:]]*$/{if(seen==0){in_fm=1;seen=1;next}else if(in_fm==1){exit}}in_fm==1{print}' "$SKILL_FILE")
  echo "$frontmatter" | grep -q '^name: gaia-readiness-check'
}

@test "SKILL.md frontmatter declares orchestration_class (post-ADR-093)" {
  # ADR-093 / E84-S3: `context: fork` stripped from non-reviewer plugin
  # SKILL.md. gaia-readiness-check is heavy-procedural.
  frontmatter=$(awk 'BEGIN{in_fm=0;seen=0}/^---[[:space:]]*$/{if(seen==0){in_fm=1;seen=1;next}else if(in_fm==1){exit}}in_fm==1{print}' "$SKILL_FILE")
  echo "$frontmatter" | grep -q '^orchestration_class: heavy-procedural'
}

@test "SKILL.md frontmatter contains 'allowed-tools' list" {
  frontmatter=$(awk 'BEGIN{in_fm=0;seen=0}/^---[[:space:]]*$/{if(seen==0){in_fm=1;seen=1;next}else if(in_fm==1){exit}}in_fm==1{print}' "$SKILL_FILE")
  echo "$frontmatter" | grep -q '^allowed-tools:'
}

# ---------- AC2: setup.sh dual gate enforcement ----------

@test "setup.sh exists and is executable" {
  [ -x "$SETUP_SCRIPT" ]
}

@test "setup.sh passes when both traceability-matrix.md and ci-setup.md exist" {
  echo "# Traceability Matrix" > "$TEST_ARTIFACTS/traceability-matrix.md"
  echo "# CI Setup" > "$TEST_ARTIFACTS/ci-setup.md"
  # Override PLUGIN_SCRIPTS_DIR to use our mocks
  PLUGIN_SCRIPTS_DIR="$MOCK_SCRIPTS" run "$SETUP_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "setup.sh HALTs when traceability-matrix.md is missing" {
  : > "$TEST_ARTIFACTS/ci-setup.md"
  PLUGIN_SCRIPTS_DIR="$MOCK_SCRIPTS" run "$SETUP_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"traceability"* ]] || [[ "${output:-}" == *"gate"* ]]
}

@test "setup.sh HALTs when ci-setup.md is missing" {
  : > "$TEST_ARTIFACTS/traceability-matrix.md"
  PLUGIN_SCRIPTS_DIR="$MOCK_SCRIPTS" run "$SETUP_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ci-setup"* ]] || [[ "${output:-}" == *"gate"* ]]
}

@test "setup.sh HALTs when both artifacts are missing" {
  PLUGIN_SCRIPTS_DIR="$MOCK_SCRIPTS" run "$SETUP_SCRIPT"
  [ "$status" -ne 0 ]
}

@test "setup.sh invokes validate-gate.sh with both gates — no partial pass" {
  # Only ci-setup exists — should still fail because traceability is missing
  : > "$TEST_ARTIFACTS/ci-setup.md"
  PLUGIN_SCRIPTS_DIR="$MOCK_SCRIPTS" run "$SETUP_SCRIPT"
  [ "$status" -ne 0 ]
}

# ---------- E28-S98: -s (non-zero-byte) guard for traceability + ci-setup ----------

@test "setup.sh HALTs when traceability-matrix.md is zero-byte" {
  : > "$TEST_ARTIFACTS/traceability-matrix.md"
  echo "real content" > "$TEST_ARTIFACTS/ci-setup.md"
  PLUGIN_SCRIPTS_DIR="$MOCK_SCRIPTS" run "$SETUP_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty (zero-byte)"* ]]
  [[ "$output" == *"traceability-matrix.md"* ]]
}

@test "setup.sh HALTs when ci-setup.md is zero-byte" {
  echo "real content" > "$TEST_ARTIFACTS/traceability-matrix.md"
  : > "$TEST_ARTIFACTS/ci-setup.md"
  PLUGIN_SCRIPTS_DIR="$MOCK_SCRIPTS" run "$SETUP_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty (zero-byte)"* ]]
  [[ "$output" == *"ci-setup.md"* ]]
}

# ---------- AC3: finalize.sh pattern ----------

@test "finalize.sh exists and is executable" {
  [ -x "$FINALIZE_SCRIPT" ]
}

@test "finalize.sh succeeds with mock checkpoint.sh and lifecycle-event.sh" {
  PLUGIN_SCRIPTS_DIR="$MOCK_SCRIPTS" run "$FINALIZE_SCRIPT"
  [ "$status" -eq 0 ]
}

# ---------- AC4: subagent routing in SKILL.md ----------

@test "SKILL.md body references architect subagent" {
  grep -qi 'architect' "$SKILL_FILE"
}

@test "SKILL.md body references devops subagent" {
  grep -qi 'devops' "$SKILL_FILE"
}

# ---------- AC5: frontmatter linter compliance ----------

@test "lint-skill-frontmatter.sh passes for the readiness-check SKILL.md" {
  LINTER="$BATS_TEST_DIRNAME/../../.github/scripts/lint-skill-frontmatter.sh"
  if [ ! -x "$LINTER" ]; then
    skip "lint-skill-frontmatter.sh not found"
  fi
  cd "$BATS_TEST_DIRNAME/.."
  run "$LINTER"
  [ "$status" -eq 0 ]
}
