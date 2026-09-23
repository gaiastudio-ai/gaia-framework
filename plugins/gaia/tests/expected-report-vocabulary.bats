#!/usr/bin/env bats
# expected-report-vocabulary.bats -- bidirectional vocabulary assertion for
# expected-report fixtures against their respective review rubrics, plus
# rubric-drift guards scoped to the defining Phase block, and retired-
# provider terminology checks.

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  # Fixture paths
  CR_FIXTURE="$PLUGIN_ROOT/tests/fixtures/code-review/end-to-end-real-story/expected-report.md"
  SR_FIXTURE="$PLUGIN_ROOT/tests/fixtures/security-review/end-to-end-real-story/expected-report.md"

  # Rubric paths -- each fixture is checked against ITS OWN rubric.
  # The code-review fixture belongs to gaia-code-review.
  # The security-review fixture belongs to the DEPRECATED gaia-security-review
  # (consumed by gaia-security-review.bats which reads the deprecated skill).
  CR_RUBRIC="$PLUGIN_ROOT/skills/gaia-code-review/SKILL.md"
  SR_RUBRIC="$PLUGIN_ROOT/skills/gaia-security-review/SKILL.md"

  # Split-fragment provider literal -- never contiguous in this file
  _PROVIDER="$(printf '%s%s' 'fig' 'ma')"

  # Per-rubric section sets.
  #
  # Code-review rubric:
  #   Phase 6 mandatory: Deterministic Analysis, LLM Semantic Review
  #   Phase 4 exemplar:  Architecture Conformance, Design Fidelity
  #   Verdict:           **Verdict: {APPROVE|REQUEST_CHANGES|BLOCKED}**
  #
  # Security-review rubric (deprecated):
  #   Phase 6 mandatory: Deterministic Analysis, LLM Semantic Review
  #   Phase 4 exemplar:  Architecture Conformance  (NO Design Fidelity)
  #   Verdict:           **Verdict: {APPROVE|REQUEST_CHANGES|BLOCKED}**

  CR_ALLOWED_H2=("Deterministic Analysis" "LLM Semantic Review" "Architecture Conformance" "Design Fidelity")
  CR_MANDATORY_H2=("Deterministic Analysis" "LLM Semantic Review")

  SR_ALLOWED_H2=("Deterministic Analysis" "LLM Semantic Review" "Architecture Conformance")
  SR_MANDATORY_H2=("Deterministic Analysis" "LLM Semantic Review")
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Extract H2 headings from a fixture (strips the "## " prefix).
_extract_h2() {
  grep '^## ' "$1" | sed 's/^## //'
}

# Extract a Phase block from a rubric SKILL.md.
# Prints all lines from "### Phase N ..." to the next "### Phase" or EOF.
_phase_block() {
  local file="$1" pattern="$2"
  sed -n "/^### Phase.*${pattern}/,/^### Phase/{/^### Phase.*${pattern}/p;/^### Phase/!p;}" "$file"
}

# _assert_h2_in_set <fixture_path> <label> <allowed_1> [allowed_2 ...]
# Fails if the fixture contains any H2 heading not in the allowed set.
_assert_h2_in_set() {
  local fixture="$1" label="$2"; shift 2
  local -a allowed=("$@")
  local bad=()
  while IFS= read -r heading; do
    local found=0
    for a in "${allowed[@]}"; do
      [ "$heading" = "$a" ] && { found=1; break; }
    done
    [ "$found" -eq 0 ] && bad+=("$heading")
  done < <(_extract_h2 "$fixture")

  if [ ${#bad[@]} -gt 0 ]; then
    printf 'Non-rubric H2 in %s fixture (remove or add to rubric): %s\n' "$label" "${bad[*]}"
    return 1
  fi
}

# _assert_names_in_phase <rubric> <phase_pattern> <label> <name_1> [name_2 ...]
# Fails if any name is missing from the rubric's Phase block.
_assert_names_in_phase() {
  local rubric="$1" phase_pat="$2" label="$3"; shift 3
  local block
  block="$(_phase_block "$rubric" "$phase_pat")"
  [ -n "$block" ] || { printf 'Phase %s block not found in %s rubric\n' "$phase_pat" "$label"; return 1; }
  for name in "$@"; do
    if ! printf '%s' "$block" | grep -qF "$name"; then
      printf 'Pinned name "%s" missing from %s Phase %s block (rubric changed?)\n' "$name" "$label" "$phase_pat"
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------
# Code-review — Direction A: every fixture H2 is rubric-defined
# ---------------------------------------------------------------------------

@test "(AC4) code-review fixture sections are rubric-defined (direction A)" {
  [ -f "$CR_FIXTURE" ] || { printf 'Missing: %s\n' "$CR_FIXTURE"; return 1; }
  _assert_h2_in_set "$CR_FIXTURE" "code-review" "${CR_ALLOWED_H2[@]}"
}

# ---------------------------------------------------------------------------
# Code-review — Direction B: every mandatory rubric section is in fixture
# ---------------------------------------------------------------------------

@test "(AC4) code-review fixture contains all mandatory rubric sections (direction B)" {
  [ -f "$CR_FIXTURE" ] || { printf 'Missing: %s\n' "$CR_FIXTURE"; return 1; }
  for name in "${CR_MANDATORY_H2[@]}"; do
    grep -qF "## $name" "$CR_FIXTURE" || { printf 'Missing mandatory section "## %s" in code-review fixture\n' "$name"; return 1; }
  done
  grep -qE '^\*\*Verdict: (APPROVE|REQUEST_CHANGES|BLOCKED)\*\*' "$CR_FIXTURE" \
    || { printf 'Missing **Verdict:** line in code-review fixture\n'; return 1; }
}

# ---------------------------------------------------------------------------
# Code-review — rubric-drift guard (scoped to defining blocks)
# ---------------------------------------------------------------------------

@test "(AC4) code-review rubric-drift guard" {
  [ -f "$CR_RUBRIC" ] || { printf 'Missing: %s\n' "$CR_RUBRIC"; return 1; }
  _assert_names_in_phase "$CR_RUBRIC" '6' "code-review" "${CR_MANDATORY_H2[@]}"
  _assert_names_in_phase "$CR_RUBRIC" '4' "code-review" "Architecture Conformance" "Design Fidelity"
}

# ---------------------------------------------------------------------------
# Security-review — Direction A: every fixture H2 is rubric-defined
# ---------------------------------------------------------------------------

@test "(AC4) security-review fixture sections are rubric-defined (direction A)" {
  [ -f "$SR_FIXTURE" ] || { printf 'Missing: %s\n' "$SR_FIXTURE"; return 1; }
  _assert_h2_in_set "$SR_FIXTURE" "security-review" "${SR_ALLOWED_H2[@]}"
}

# ---------------------------------------------------------------------------
# Security-review — Direction B: every mandatory rubric section is in fixture
# ---------------------------------------------------------------------------

@test "(AC4) security-review fixture contains all mandatory rubric sections (direction B)" {
  [ -f "$SR_FIXTURE" ] || { printf 'Missing: %s\n' "$SR_FIXTURE"; return 1; }
  for name in "${SR_MANDATORY_H2[@]}"; do
    grep -qF "## $name" "$SR_FIXTURE" || { printf 'Missing mandatory section "## %s" in security-review fixture\n' "$name"; return 1; }
  done
  grep -qE '^\*\*Verdict: (APPROVE|REQUEST_CHANGES|BLOCKED)\*\*' "$SR_FIXTURE" \
    || { printf 'Missing **Verdict:** line in security-review fixture\n'; return 1; }
}

# ---------------------------------------------------------------------------
# Security-review — rubric-drift guard (scoped to defining blocks)
# ---------------------------------------------------------------------------

@test "(AC4) security-review rubric-drift guard" {
  [ -f "$SR_RUBRIC" ] || { printf 'Missing: %s\n' "$SR_RUBRIC"; return 1; }
  _assert_names_in_phase "$SR_RUBRIC" '6' "security-review" "${SR_MANDATORY_H2[@]}"
  _assert_names_in_phase "$SR_RUBRIC" '4' "security-review" "Architecture Conformance"
}

# ---------------------------------------------------------------------------
# AC4 — no retired-provider terminology in either fixture
# ---------------------------------------------------------------------------

@test "(AC4) code-review fixture carries no retired-provider terminology" {
  [ -f "$CR_FIXTURE" ] || { printf 'Missing: %s\n' "$CR_FIXTURE"; return 1; }
  run grep -wiF "$_PROVIDER" "$CR_FIXTURE"
  [ "$status" -ne 0 ]
}

@test "(AC4) security-review fixture carries no retired-provider terminology" {
  [ -f "$SR_FIXTURE" ] || { printf 'Missing: %s\n' "$SR_FIXTURE"; return 1; }
  run grep -wiF "$_PROVIDER" "$SR_FIXTURE"
  [ "$status" -ne 0 ]
}
