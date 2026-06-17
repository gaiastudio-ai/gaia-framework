#!/usr/bin/env bats
# static-next-steps.bats — E45-S1 regression guard.
#
# Story: E45-S1 — Static `## Next Steps` sections for 10 skills (FR-348 / ADR-060).
#
# Context: ADR-060 mandates a trailing static `## Next Steps` H2 section in
# 10 lifecycle SKILL.md files, replacing dynamic `lifecycle-sequence.yaml`
# routing. Each section MUST list a primary successor command, optionally an
# alternative, in pure markdown (no `{...}` placeholders, no `$(...)` command
# substitution).
#
# This guard asserts:
#   - VCP-NXT-01..NXT-10: each of the 10 target SKILL.md files has a
#     `## Next Steps` H2 header followed by the expected primary successor
#     command (before the next `## ` header or EOF).
#   - VCP-NXT-11: zero references to `lifecycle-sequence.yaml` across the 10
#     target SKILL.md files (the routing file may still exist on disk per
#     ADR-060, but no skill may reference it).
#   - Static-markdown guard: each `## Next Steps` body contains no `{` or
#     `$(` tokens (no templating, no shell substitution).
#
# Failure output enumerates each offender with file path and reason so the
# regression is trivial to locate.

load test_helper

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILLS_DIR="$PLUGIN_ROOT/skills"
  export PLUGIN_ROOT SKILLS_DIR
}

teardown() { common_teardown; }

# _extract_next_steps_body <file> — print the body of the trailing
# `## Next Steps` section (lines after the header up to the next `## ` or EOF).
_extract_next_steps_body() {
  local file="$1"
  awk '
    /^## Next Steps[[:space:]]*$/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section { print }
  ' "$file"
}

# _assert_section_with_primary <skill> <expected_primary>
_assert_section_with_primary() {
  local skill="$1" expected="$2"
  local file="$SKILLS_DIR/$skill/SKILL.md"
  [ -f "$file" ] || { echo "SKILL.md missing: $file"; return 1; }
  grep -qE '^## Next Steps[[:space:]]*$' "$file" \
    || { echo "$skill: no '## Next Steps' H2 header found"; return 1; }
  local body
  body="$(_extract_next_steps_body "$file")"
  [ -n "$body" ] || { echo "$skill: '## Next Steps' section is empty"; return 1; }
  echo "$body" | grep -qE "(^|[^A-Za-z0-9_-])${expected}([^A-Za-z0-9_-]|$)" \
    || { echo "$skill: expected primary '${expected}' not found in '## Next Steps' body. Body was:"; echo "$body"; return 1; }
}

# ---------- VCP-NXT-01..NXT-10: per-skill section + primary successor ----------

@test "gaia-create-epics has '## Next Steps' with primary /gaia-atdd" {
  _assert_section_with_primary gaia-create-epics "/gaia-atdd"
}

@test "gaia-threat-model has '## Next Steps' with primary /gaia-infra-design" {
  _assert_section_with_primary gaia-threat-model "/gaia-infra-design"
}

@test "gaia-infra-design has '## Next Steps' with primary /gaia-trace" {
  _assert_section_with_primary gaia-infra-design "/gaia-trace"
}

@test "gaia-test-design has '## Next Steps' with primary /gaia-create-epics" {
  _assert_section_with_primary gaia-test-design "/gaia-create-epics"
}

@test "gaia-trace has '## Next Steps' with /gaia-ci-setup or /gaia-readiness-check" {
  local file="$SKILLS_DIR/gaia-trace/SKILL.md"
  [ -f "$file" ]
  grep -qE '^## Next Steps[[:space:]]*$' "$file"
  local body
  body="$(_extract_next_steps_body "$file")"
  echo "$body" | grep -qE '/gaia-ci-setup|/gaia-readiness-check' \
    || { echo "gaia-trace: neither /gaia-ci-setup nor /gaia-readiness-check found in '## Next Steps' body. Body was:"; echo "$body"; return 1; }
}

@test "gaia-ci-setup has '## Next Steps' with primary /gaia-readiness-check" {
  _assert_section_with_primary gaia-ci-setup "/gaia-readiness-check"
}

@test "gaia-brainstorm has '## Next Steps' with primary /gaia-product-brief" {
  _assert_section_with_primary gaia-brainstorm "/gaia-product-brief"
}

@test "gaia-market-research has '## Next Steps' with primary /gaia-product-brief" {
  _assert_section_with_primary gaia-market-research "/gaia-product-brief"
}

@test "gaia-domain-research has '## Next Steps' with primary /gaia-product-brief" {
  _assert_section_with_primary gaia-domain-research "/gaia-product-brief"
}

@test "gaia-tech-research has '## Next Steps' with primary /gaia-create-arch" {
  _assert_section_with_primary gaia-tech-research "/gaia-create-arch"
}

# ---------- VCP-NXT-11: zero lifecycle-sequence.yaml references ----------

@test "no SKILL.md in the 10-file set references lifecycle-sequence.yaml" {
  local skills=(gaia-brainstorm gaia-market-research gaia-domain-research gaia-tech-research \
                gaia-create-epics gaia-threat-model gaia-infra-design gaia-test-design \
                gaia-trace gaia-ci-setup)
  local offenders=""
  local s
  for s in "${skills[@]}"; do
    local file="$SKILLS_DIR/$s/SKILL.md"
    if grep -q 'lifecycle-sequence.yaml' "$file" 2>/dev/null; then
      offenders="${offenders}${file}"$'\n'
    fi
  done
  if [ -n "$offenders" ]; then
    echo "SKILL.md files still reference 'lifecycle-sequence.yaml' (ADR-060 forbids this in the 10-skill set):"
    printf '%s' "$offenders"
    return 1
  fi
}

# ---------- Static-markdown guard (AC3): no templating in '## Next Steps' bodies ----------

@test "guard: no '## Next Steps' section contains { or \$( templating tokens" {
  local skills=(gaia-brainstorm gaia-market-research gaia-domain-research gaia-tech-research \
                gaia-create-epics gaia-threat-model gaia-infra-design gaia-test-design \
                gaia-trace gaia-ci-setup)
  local offenders=""
  local s
  for s in "${skills[@]}"; do
    local file="$SKILLS_DIR/$s/SKILL.md"
    [ -f "$file" ] || continue
    local body
    body="$(_extract_next_steps_body "$file")"
    if echo "$body" | grep -qE '\{|\$\('; then
      offenders="${offenders}${file}"$'\n'
    fi
  done
  if [ -n "$offenders" ]; then
    echo "SKILL.md files contain dynamic templating tokens ({ or \$() inside their '## Next Steps' bodies (ADR-060 mandates pure static markdown):"
    printf '%s' "$offenders"
    return 1
  fi
}
