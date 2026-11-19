#!/usr/bin/env bats
# gaia-dev-story-step2b-atdd.bats — ATDD gate (Step 2b) contract tests
#
# Validates the ATDD gate and plan-structure validator contracts in
# gaia-dev-story SKILL.md.
#
# Validates:
#   Test 1:  Step 2b region is present in SKILL.md, bounded by
#            begin/end markers `<!-- step 2b atdd gate begin/end -->`.
#   Test 2:  Step 2b invokes `atdd-gate.sh {story_key}`.
#   Test 3:  Step 2b instructs HALT on non-zero exit.
#   Test 4:  Step 2b documents the resolver + exact-name discovery rule
#            (resolver path, exact atdd-{story_key}.md, exact
#            atdd-{epic_key}.md; no prefix matching).
#   Test 5:  Step 2b sits between Step 2 (Update Status) and Step 3
#            (Create Feature Branch).
#   Test 6:  atdd-gate.sh helper script is shipped with the plugin and
#            is executable.
#   Test 7:  atdd-gate.sh exits non-zero on high-risk story with no
#            atdd file (HALT condition).
#   Test 8:  atdd-gate.sh exits 0 on medium-risk story (proceeds).
#   Test 9:  atdd-gate.sh exits 0 on low-risk story (proceeds).
#   Test 10: atdd-gate.sh exits 0 on unset risk (proceeds).
#   Test 11: atdd-gate.sh rejects suffix-named epic ATDD file
#            (atdd-{epic_key}-{suffix}.md does NOT satisfy the gate).
#   Test 12: atdd-gate.sh rejects suffix-named story ATDD file
#            (atdd-{story_key}-{suffix}.md does NOT satisfy the gate).
#   Test 13: atdd-gate.sh accepts exact atdd-{epic_key}.md (exit 0).
#   Test 14: atdd-gate.sh accepts exact atdd-{story_key}.md (exit 0).
#
# Usage:
#   bats tests/skills/gaia-dev-story-step2b-atdd.bats
#
# Dependencies: bats-core 1.10+

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILL_FILE="$REPO_ROOT/plugins/gaia/skills/gaia-dev-story/SKILL.md"
  ATDD_GATE="$REPO_ROOT/plugins/gaia/skills/gaia-dev-story/scripts/atdd-gate.sh"

  GATE_BEGIN='<!-- step 2b atdd gate begin -->'
  GATE_END='<!-- step 2b atdd gate end -->'

  # Per-test working dir for fixtures.
  TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
  if [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

extract_step2b_region() {
  awk -v b="$GATE_BEGIN" -v e="$GATE_END" '
    index($0, b) { in_region = 1 }
    in_region    { print }
    index($0, e) { in_region = 0 }
  ' "$SKILL_FILE"
}

# Build a fixture project root for atdd-gate.sh runs. The script must accept
# a project-root override (PROJECT_PATH or first-arg-derived) so tests can
# point it at a temp dir.
make_fixture_project() {
  local risk="$1"
  local story_key="$2"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  local epic_key="${story_key%-S*}"
  local proj="$TEST_TMPDIR/proj"
  mkdir -p "$proj/docs/implementation-artifacts"
  mkdir -p "$proj/docs/test-artifacts"
  local story_file="$proj/docs/implementation-artifacts/${story_key}-fixture.md"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  cat > "$story_file" <<FIXTURE_EOF
---
key: "$story_key"
title: "Fixture story"
epic: "$epic_key"
status: in-progress
risk: $risk
---
# Story: Fixture story
FIXTURE_EOF
  printf '%s\n' "$proj"
}

# ---------- Preconditions ----------

@test "SKILL.md exists at gaia-dev-story skill directory" {
  [ -f "$SKILL_FILE" ]
}

# ---------- Step 2b region in SKILL.md ----------

@test "Step 2b region markers are present in SKILL.md" {
  grep -qF "$GATE_BEGIN" "$SKILL_FILE"
  grep -qF "$GATE_END" "$SKILL_FILE"
}

@test "Step 2b region invokes atdd-gate.sh with story_key" {
  region="$(extract_step2b_region)"
  [ -n "$region" ]
  echo "$region" | grep -qE "atdd-gate\.sh"
}

@test "Step 2b region instructs HALT on non-zero exit" {
  region="$(extract_step2b_region)"
  [ -n "$region" ]
  echo "$region" | grep -qiE "HALT"
}

@test "Step 2b region documents the resolver + exact-name discovery rule" {
  region="$(extract_step2b_region)"
  [ -n "$region" ]
  # Must reference the resolver, exact story_key and epic_key names, and
  # the "no prefix" / exact-match semantics.
  echo "$region" | grep -qF "resolve-test-artifact-per-story"
  echo "$region" | grep -qF "story_key"
  echo "$region" | grep -qF "epic_key"
  echo "$region" | grep -qiE "exact|no prefix"
}

@test "Step 2b sits between Step 2 (Update Status) and Step 3 (Create Feature Branch)" {
  # Find line numbers for Step 2 header, Step 2b begin, Step 3 header.
  step2_line=$(grep -nF "### Step 2 -- Update Status" "$SKILL_FILE" | head -1 | cut -d: -f1)
  s2b_line=$(grep -nF "$GATE_BEGIN" "$SKILL_FILE" | head -1 | cut -d: -f1)
  step3_line=$(grep -nF "### Step 3 -- Create Feature Branch" "$SKILL_FILE" | head -1 | cut -d: -f1)
  [ -n "$step2_line" ]
  [ -n "$s2b_line" ]
  [ -n "$step3_line" ]
  [ "$s2b_line" -gt "$step2_line" ]
  [ "$s2b_line" -lt "$step3_line" ]
}

# ---------- atdd-gate.sh helper ----------

@test "atdd-gate.sh helper is shipped and executable" {
  [ -x "$ATDD_GATE" ]
}

@test "atdd-gate.sh exits non-zero on high-risk story with no atdd file" {
  local _k="E99-S1"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  proj="$(make_fixture_project high "$_k")"
  run env PROJECT_PATH="$proj" "$ATDD_GATE" "$_k"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "atdd-"
}

# ---------- non-high risk paths ----------

@test "atdd-gate.sh exits 0 on medium-risk story even with no atdd file" {
  local _k="E99-S2"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  proj="$(make_fixture_project medium "$_k")"
  run env PROJECT_PATH="$proj" "$ATDD_GATE" "$_k"
  [ "$status" -eq 0 ]
}

@test "atdd-gate.sh exits 0 on low-risk story" {
  local _k="E99-S3"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  proj="$(make_fixture_project low "$_k")"
  run env PROJECT_PATH="$proj" "$ATDD_GATE" "$_k"
  [ "$status" -eq 0 ]
}

@test "atdd-gate.sh exits 0 when risk frontmatter is unset" {
  # Build a story file without a risk: line.
  local _k="E99-S4"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  proj="$TEST_TMPDIR/proj-norisk"
  mkdir -p "$proj/docs/implementation-artifacts"
  mkdir -p "$proj/docs/test-artifacts"
  local story_file="$proj/docs/implementation-artifacts/${_k}-norisk.md"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  cat > "$story_file" <<NORISK_EOF
---
key: "$_k"
title: "No risk fixture"
epic: "E99"
status: in-progress
---
# Story: no risk
NORISK_EOF
  run env PROJECT_PATH="$proj" "$ATDD_GATE" "$_k"
  [ "$status" -eq 0 ]
}

# ---------- high-risk — suffix-named files must NOT satisfy the gate ----------

@test "high-risk story rejects suffix-named epic ATDD file" {
  local _k="E99-S5"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  proj="$(make_fixture_project high "$_k")"
  printf '# ATDD: Epic-level scenarios\n' > "$proj/docs/test-artifacts/atdd-E99-something.md"
  run env PROJECT_PATH="$proj" "$ATDD_GATE" "$_k"
  [ "$status" -eq 1 ] \
    || { echo "suffix-named epic file should not satisfy the gate, got exit $status" >&2; echo "$output" >&2; false; }
}

@test "high-risk story rejects suffix-named story ATDD file" {
  local _k="E99-S6"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  proj="$(make_fixture_project high "$_k")"
  printf '# ATDD: story-level scenarios\n' > "$proj/docs/test-artifacts/atdd-E99-S6-some-scenario.md"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  run env PROJECT_PATH="$proj" "$ATDD_GATE" "$_k"
  [ "$status" -eq 1 ] \
    || { echo "suffix-named story file should not satisfy the gate, got exit $status" >&2; echo "$output" >&2; false; }
}

# ---------- high-risk — exact-name files satisfy the gate ----------

@test "high-risk story passes with exact atdd-{epic_key}.md" {
  local _k="E99-S7"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  proj="$(make_fixture_project high "$_k")"
  printf '# ATDD: epic-level exact\n' > "$proj/docs/test-artifacts/atdd-E99.md"
  run env PROJECT_PATH="$proj" "$ATDD_GATE" "$_k"
  [ "$status" -eq 0 ] \
    || { echo "exact atdd-{epic_key}.md should satisfy the gate, got exit $status" >&2; echo "$output" >&2; false; }
}

@test "high-risk story passes with exact atdd-{story_key}.md" {
  local _k="E99-S8"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  proj="$(make_fixture_project high "$_k")"
  printf '# ATDD: story-level exact\n' > "$proj/docs/test-artifacts/atdd-E99-S8.md"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  run env PROJECT_PATH="$proj" "$ATDD_GATE" "$_k"
  [ "$status" -eq 0 ] \
    || { echo "exact atdd-{story_key}.md should satisfy the gate, got exit $status" >&2; echo "$output" >&2; false; }
}
