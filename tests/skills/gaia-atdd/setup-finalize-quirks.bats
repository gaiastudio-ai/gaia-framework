#!/usr/bin/env bats
# setup-finalize-quirks.bats — E80-S1 Cluster B (TC-ATDD-1..TC-ATDD-3)
#
# Validates the three /gaia-atdd recurring-quirk fixes:
#   TC-ATDD-1: setup.sh emits no validate-gate.sh story_file_exists warning
#   TC-ATDD-2: finalize.sh derives ATDD_ARTIFACT from STORY_KEY and runs SV-01
#   TC-ATDD-3: 12-AC high-risk artifact >=10KB does not trip noisy WARNING
#
# Usage:
#   bats tests/skills/gaia-atdd/setup-finalize-quirks.bats
#
# Dependencies: bats-core 1.10+

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SKILL_DIR="$REPO_ROOT/plugins/gaia/skills/gaia-atdd"
  SETUP_SCRIPT="$SKILL_DIR/scripts/setup.sh"
  FINALIZE_SCRIPT="$SKILL_DIR/scripts/finalize.sh"

  TEST_TMP="$BATS_TEST_TMPDIR/atdd-quirks-$$"
  mkdir -p "$TEST_TMP/docs/implementation-artifacts" \
           "$TEST_TMP/docs/test-artifacts" \
           "$TEST_TMP/checkpoints" \
           "$TEST_TMP/memory" \
           "$TEST_TMP/config"

  # Minimal project-config.yaml so resolve-config.sh succeeds.
  cat >"$TEST_TMP/config/project-config.yaml" <<EOF
project_root: "$TEST_TMP"
project_path: "$TEST_TMP"
memory_path: "$TEST_TMP/memory"
checkpoint_path: "$TEST_TMP/checkpoints"
installed_path: "$REPO_ROOT/plugins/gaia"
framework_version: "test"
date: "2026-05-07"
EOF

  export CLAUDE_SKILL_DIR="$TEST_TMP"
  export GAIA_PROJECT_ROOT="$TEST_TMP"
  export GAIA_PROJECT_PATH="$TEST_TMP"
  export GAIA_MEMORY_PATH="$TEST_TMP/memory"
  export GAIA_CHECKPOINT_PATH="$TEST_TMP/checkpoints"
  export GAIA_INSTALLED_PATH="$REPO_ROOT/plugins/gaia"
  export PROJECT_ROOT="$TEST_TMP"
  export TEST_ARTIFACTS="$TEST_TMP/docs/test-artifacts"
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/docs/implementation-artifacts"

  # Clear ATDD_ARTIFACT so finalize.sh derivation path is exercised.
  unset ATDD_ARTIFACT
}

# Write a minimal story file at the canonical path.
write_story_file() {
  local key="$1"
  cat >"$TEST_TMP/docs/implementation-artifacts/${key}-test-story.md" <<EOF
---
key: "$key"
title: "Test story"
status: ready-for-dev
risk: high
---

## Acceptance Criteria

- [ ] AC1
EOF
}

# Write an ATDD artifact of approximately the requested size with a valid
# AC-to-Test Mapping table so SV-01 PASSes.
write_atdd_artifact() {
  local key="$1" target_kb="$2" risk="${3:-high}"
  local f="$TEST_TMP/docs/test-artifacts/atdd-${key}.md"
  {
    cat <<EOF
# ATDD: $key

> Risk: $risk

## AC-to-Test Mapping

| AC ID | Description | Test Name |
|-------|-------------|-----------|
EOF
    # 12 ACs, each with a long description to push past the size threshold.
    for i in $(seq 1 12); do
      printf '| AC%d | Long description for AC %d ' "$i" "$i"
      # Pad each row so the total file lands around the requested KB.
      for _ in $(seq 1 50); do printf 'pad-pad-pad-pad-pad-pad '; done
      printf '| test_ac_%d |\n' "$i"
    done
    echo
    echo "## Tests"
    for i in $(seq 1 12); do
      printf 'Given context %d, when action %d, then result %d.\n' "$i" "$i" "$i"
      # Bulk content per AC.
      for _ in $(seq 1 30); do printf 'lorem ipsum dolor sit amet '; done
      printf '\n'
    done
  } >"$f"
  # Validate size — pad further if under target.
  local size
  size="$(wc -c <"$f" | tr -d ' ')"
  local target_bytes=$(( target_kb * 1024 ))
  while [ "$size" -lt "$target_bytes" ]; do
    for _ in $(seq 1 50); do printf 'extra-pad-line ' >>"$f"; done
    printf '\n' >>"$f"
    size="$(wc -c <"$f" | tr -d ' ')"
  done
  printf '%s' "$f"
}

# ---------- Pre-flight ----------

@test "Pre-flight: setup.sh is executable" {
  [ -x "$SETUP_SCRIPT" ]
}

@test "Pre-flight: finalize.sh is executable" {
  [ -x "$FINALIZE_SCRIPT" ]
}

# ---------- TC-ATDD-1: no validate-gate noise ----------

@test "TC-ATDD-1: setup.sh emits no validate-gate.sh story_file_exists warning" {
  write_story_file "E99-S1"
  export STORY_KEY="E99-S1"

  run "$SETUP_SCRIPT"
  # The setup itself may exit 0 or non-zero depending on resolve-config
  # behavior in the test fixture, but the specific warning string MUST NOT
  # appear on stderr regardless.
  ! printf '%s' "$output" | grep -q "validate-gate.sh story_file_exists check returned non-zero"
}

# ---------- TC-ATDD-2: finalize derives ATDD_ARTIFACT from STORY_KEY ----------

@test "TC-ATDD-2: finalize.sh runs SV-01 checklist without external ATDD_ARTIFACT export" {
  write_story_file "E99-S2"
  artifact_path="$(write_atdd_artifact "E99-S2" 5 medium)"
  [ -f "$artifact_path" ]

  unset ATDD_ARTIFACT
  export STORY_KEY="E99-S2"

  run "$FINALIZE_SCRIPT"
  # The SV-01 line MUST appear in stderr — the silent-skip branch must
  # not fire when STORY_KEY is set and the derived artifact exists.
  printf '%s\n' "$output" | grep -q "SV-01"
}

# ---------- TC-ATDD-3: 10KB advisory respects risk ----------

@test "TC-ATDD-3: 12-AC high-risk artifact >=10KB does not emit WARNING" {
  write_story_file "E99-S3"
  artifact_path="$(write_atdd_artifact "E99-S3" 12 high)"
  [ -f "$artifact_path" ]
  size_kb="$(($(wc -c <"$artifact_path") / 1024))"
  [ "$size_kb" -ge 10 ]

  unset ATDD_ARTIFACT
  export STORY_KEY="E99-S3"

  run "$FINALIZE_SCRIPT"
  # For a high-risk story the 10KB advisory MUST be downgraded to INFO,
  # not surfaced as a WARNING. We assert no `WARNING` line referring to
  # the size advisory appears.
  ! printf '%s\n' "$output" | grep -Eq 'WARNING.*(exceeds 10KB|atdd output exceeds)'
}
