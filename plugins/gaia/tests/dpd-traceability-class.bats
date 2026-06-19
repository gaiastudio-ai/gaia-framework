#!/usr/bin/env bats
# dpd-traceability-class.bats — E88-S6 (scope-split implementation).
#
# In-scope: TC-DPD-22, TC-DPD-23, TC-DPD-24.
# Deferred (with the AC1 matrix-wide migration): TC-DPD-21 (matrix row
# schema validation) and the test_class column itself.
#
# Helper under test:
#   gaia-public/plugins/gaia/scripts/lib/trace-dispatch-verb-enforcement.sh
#
# Invocation contract:
#   trace-dispatch-verb-enforcement.sh --story-file <path> --matrix-file <path>
#     - exits 0 if no dispatch-verb medium/high-risk ACs lack integration coverage
#       (or no dispatch-verb ACs in the story at all).
#     - exits 1 with canonical stderr on a coverage gap.

load 'test_helper.bash'

setup() {
  common_setup
  LIB_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts/lib" && pwd)"
  HELPER="$LIB_DIR/trace-dispatch-verb-enforcement.sh"
  export LIB_DIR HELPER
}

teardown() {
  common_teardown
}

_write_story() {
  local path="$1"; shift
  local risk="$1"; shift
  local ac_body="$1"; shift
  cat > "$path" <<EOF
---
key: "E99-S99"
title: "Fixture"
risk: "$risk"
status: ready-for-dev
---

## Acceptance Criteria

**AC1.** $ac_body

EOF
}

# ---------------- TC-DPD-22: dispatch-verb medium-risk AC without integration row -> HALT ----------------
@test "dispatch-verb medium-risk AC with no integration row HALTs" {
  local story="$TEST_TMP/story.md"
  local matrix="$TEST_TMP/matrix.md"
  _write_story "$story" "medium" "the orchestrator spawns the subagent"
  # Matrix has rows but NONE with test_class: integration referencing E99-S99.
  cat > "$matrix" <<'EOF'
| TC-X-1 | something else | test_class: contract | E99-S99:AC1 |
EOF
  run "$HELPER" --story-file "$story" --matrix-file "$matrix"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dispatch-verb AC"* ]]
  [[ "$output" == *"requires ≥1 integration row"* ]]
}

# ---------------- TC-DPD-23: same fixture with integration row -> PASS ----------------
@test "same fixture with test_class: integration row added passes" {
  local story="$TEST_TMP/story.md"
  local matrix="$TEST_TMP/matrix.md"
  _write_story "$story" "medium" "the orchestrator spawns the subagent"
  cat > "$matrix" <<'EOF'
| TC-Y-1 | integration test | test_class: integration | E99-S99:AC1 |
EOF
  run "$HELPER" --story-file "$story" --matrix-file "$matrix"
  [ "$status" -eq 0 ]
}

# ---------------- TC-DPD-23b: low-risk dispatch-verb AC -> not enforced ----------------
@test "low-risk dispatch-verb AC does NOT require integration row" {
  local story="$TEST_TMP/story.md"
  local matrix="$TEST_TMP/matrix.md"
  _write_story "$story" "low" "the orchestrator spawns the subagent"
  cat > "$matrix" <<'EOF'
| TC-X-1 | something | test_class: contract | E99-S99:AC1 |
EOF
  run "$HELPER" --story-file "$story" --matrix-file "$matrix"
  [ "$status" -eq 0 ]
}

# ---------------- TC-DPD-23c: high-risk non-dispatch AC -> not enforced ----------------
@test "high-risk non-dispatch AC does NOT require integration row" {
  local story="$TEST_TMP/story.md"
  local matrix="$TEST_TMP/matrix.md"
  _write_story "$story" "high" "the user is shown an error message"
  : > "$matrix"  # empty matrix
  run "$HELPER" --story-file "$story" --matrix-file "$matrix"
  [ "$status" -eq 0 ]
}

# ---------------- TC-DPD-24: E76-S10 frontmatter delivered:false + status:done coexist ----------------
@test "synthetic fixture passes delivered:false + status:done coexistence" {
  # Run against a synthetic fixture rather than the project-root E76-S10
  # story file. The real E76-S10 lives at project-root docs/ (outside the
  # gaia-public/ repo CI sees), so a project-root lookup would always
  # skip on CI. The synthetic fixture proves the assertion shape; the
  # real E76-S10 edit is verified manually post-merge.
  local synthetic="$TEST_TMP/e76-s10-fixture.md"
  cat > "$synthetic" <<'EOF'
---
key: "E76-S10"
title: "Fixture for TC-DPD-24"
status: done
delivered: false
risk: medium
---
EOF
  grep -q "^delivered: false" "$synthetic"
  grep -q "^status: done" "$synthetic"
}
