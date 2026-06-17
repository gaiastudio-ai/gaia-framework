#!/usr/bin/env bats
# product-brief-post-complete-gate.bats — E46-S9 (FR-358, FR-347)
#
# VCP-PB-03 / VCP-PB-04 — post_complete gate enforcement on the
# /gaia-product-brief skill. The gate is wired via E45-S2's shared
# gate-predicates.sh library; this fixture validates the skill-specific
# contract: 9 required H2 sections in the generated brief, with the
# missing-sections error line reachable via grep.
#
# Test plan classification: Script-verifiable (2). All bats tests run
# hermetically under $BATS_TEST_TMPDIR. macOS /bin/bash 3.2 compatible.

load 'test_helper.bash'

SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-product-brief"
FINALIZE="$SKILL_DIR/scripts/finalize.sh"

setup() {
  common_setup
  mkdir -p "$TEST_TMP/docs/creative-artifacts"
  mkdir -p "$TEST_TMP/_memory/checkpoints"
  export CHECKPOINT_PATH="$TEST_TMP/_memory/checkpoints"
  export LIFECYCLE_EVENTS_LOG="$TEST_TMP/_memory/lifecycle-events.ndjson"
}

teardown() { common_teardown; }

# _make_brief <path> [omit_section ...] — emit a synthetic product brief
# with all 9 required sections populated. Each remaining argument is the
# literal section name to OMIT.
_make_brief() {
  local out="$1"; shift
  local sections=(
    "Vision Statement"
    "Target Users"
    "Problem Statement"
    "Proposed Solution"
    "Key Features"
    "Scope and Boundaries"
    "Risks and Assumptions"
    "Competitive Landscape"
    "Success Metrics"
  )
  _emit_section() {
    case "$1" in
      "Target Users")
        printf '## Target Users\n\n- Role: developer — pain points: slow CI.\n- Role: ops — pain points: noisy alerts.\n\n' ;;
      "Key Features")
        printf '## Key Features\n\n- Feature one — primary differentiator\n- Feature two — secondary lever\n\n' ;;
      "Scope and Boundaries")
        printf '## Scope and Boundaries\n\nIn-scope: A, B, C. Out-of-scope: D, E.\n\n' ;;
      "Competitive Landscape")
        printf '## Competitive Landscape\n\n- Competitor X — positioning note\n- Competitor Y — positioning note\n\n' ;;
      "Success Metrics")
        printf '## Success Metrics\n\n- 80%% adoption within 30 days\n- p95 latency under 200 ms\n\n' ;;
      *)
        printf '## %s\n\nFixture content for %s.\n\n' "$1" "$1" ;;
    esac
  }
  {
    printf '# Product Brief Fixture\n\n'
    local s
    for s in "${sections[@]}"; do
      local omit=0
      local skip
      for skip in "$@"; do
        if [ "$s" = "$skip" ]; then omit=1; break; fi
      done
      [ $omit -eq 1 ] && continue
      _emit_section "$s"
    done
  } >"$out"
}

# -------------------------------------------------------------------------
# VCP-PB-03 — post_complete gate passes when all 9 sections present.
# -------------------------------------------------------------------------
@test "finalize.sh exits 0 when all 9 sections are present" {
  _make_brief "$TEST_TMP/docs/creative-artifacts/product-brief-foo.md"
  cd "$TEST_TMP"
  export PRODUCT_BRIEF_ARTIFACT="$TEST_TMP/docs/creative-artifacts/product-brief-foo.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
  # No "Missing required sections" line in the output.
  [[ "$output" != *"Missing required sections"* ]]
  # Lifecycle observability still ran.
  [[ "$output" == *"checkpoint written for create-product-brief"* ]] || \
    [[ "$output" == *"finalize complete for create-product-brief"* ]]
}

# -------------------------------------------------------------------------
# VCP-PB-04 — post_complete gate halts when one section is missing,
# error message names exactly the missing section.
# -------------------------------------------------------------------------
@test "finalize.sh exits non-zero when Success Metrics missing" {
  _make_brief "$TEST_TMP/docs/creative-artifacts/product-brief-foo.md" \
    "Success Metrics"
  cd "$TEST_TMP"
  export PRODUCT_BRIEF_ARTIFACT="$TEST_TMP/docs/creative-artifacts/product-brief-foo.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  # Grep-matchable on the canonical phrase (case-insensitive on the
  # leading capital — the gate-predicates library prints "Missing
  # required sections:" which subsumes the "missing sections:" anchor).
  [[ "$output" == *"Missing required sections"* ]]
  [[ "$output" == *"Success Metrics"* ]]
}

@test "2 missing sections both appear in the failure line" {
  _make_brief "$TEST_TMP/docs/creative-artifacts/product-brief-foo.md" \
    "Risks and Assumptions" "Competitive Landscape"
  cd "$TEST_TMP"
  export PRODUCT_BRIEF_ARTIFACT="$TEST_TMP/docs/creative-artifacts/product-brief-foo.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Missing required sections"* ]]
  [[ "$output" == *"Risks and Assumptions"* ]]
  [[ "$output" == *"Competitive Landscape"* ]]
}

# -------------------------------------------------------------------------
# VCP-PB-05 — Template reference is present in SKILL.md.
# -------------------------------------------------------------------------
@test "SKILL.md references product-brief-template.md by name" {
  run grep -F 'product-brief-template.md' \
    "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "plugin-shipped template file exists on disk" {
  template="$BATS_TEST_DIRNAME/../templates/product-brief-template.md"
  [ -f "$template" ]
}

@test "plugin template carries all 9 canonical headings" {
  template="$BATS_TEST_DIRNAME/../templates/product-brief-template.md"
  [ -f "$template" ]
  for h in \
    "Vision Statement" \
    "Target Users" \
    "Problem Statement" \
    "Proposed Solution" \
    "Key Features" \
    "Scope and Boundaries" \
    "Risks and Assumptions" \
    "Competitive Landscape" \
    "Success Metrics"; do
    grep -F "## $h" "$template" >/dev/null
  done
}

# -------------------------------------------------------------------------
# VCP-PB-06 — Analyst (Elena) agent is assigned in SKILL.md.
# -------------------------------------------------------------------------
@test "SKILL.md mentions both 'analyst' and 'Elena' tokens" {
  run grep -E '(analyst|Elena)' "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
  # Both identifiers must be present at least once.
  grep -F 'analyst' "$SKILL_DIR/SKILL.md" >/dev/null
  grep -F 'Elena' "$SKILL_DIR/SKILL.md" >/dev/null
}
