#!/usr/bin/env bats
# e69-skill-md-usage-strings.bats — E69-S6
# Sweeps the eight E69 renames for AC6 consistency:
#   /gaia-review-code, /gaia-review-qa, /gaia-review-test,
#   /gaia-review-security, /gaia-review-perf, /gaia-perf-deepdive,
#   /gaia-test-a11y, /gaia-config-ci.
# For each renamed skill, the SKILL.md body usage strings and frontmatter
# argument-hint MUST reference the new canonical slash-command name (no
# stale legacy aliases in user-facing prose). Deprecation-alias stub
# SKILL.md files (those whose `name:` begins with `deprecated-`) are
# intentionally exempt — they MUST keep the old name so the alias prompt
# reads correctly during the one-sprint deprecation window per E69-S1.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILLS_DIR="$PLUGIN_DIR/skills"
}

# Helper: returns 0 if the SKILL.md is a deprecated alias stub
# (frontmatter `name:` starts with `deprecated-`), 1 otherwise.
is_deprecated_alias() {
  local skill_md="$1"
  awk '/^---$/{c++; next} c==1 && /^name:[[:space:]]*deprecated-/{found=1; exit} c==2{exit} END{exit !found}' "$skill_md"
}

# AC1: each renamed skill SKILL.md body uses the new canonical
# `usage: /gaia-{new}` slash-command name (no legacy aliases in usage prose).
@test "gaia-code-review/SKILL.md body uses /gaia-review-code in usage strings" {
  local f="$SKILLS_DIR/gaia-code-review/SKILL.md"
  is_deprecated_alias "$f" && skip "deprecation alias stub"
  run grep -nE 'usage: /gaia-code-review' "$f"
  [ "$status" -ne 0 ]
  run grep -cF 'usage: /gaia-review-code' "$f"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

@test "gaia-qa-tests/SKILL.md body uses /gaia-review-qa in usage strings" {
  local f="$SKILLS_DIR/gaia-qa-tests/SKILL.md"
  is_deprecated_alias "$f" && skip "deprecation alias stub"
  run grep -nE 'usage: /gaia-qa-tests' "$f"
  [ "$status" -ne 0 ]
  run grep -cF 'usage: /gaia-review-qa' "$f"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

@test "gaia-test-review/SKILL.md body uses /gaia-review-test in usage strings" {
  local f="$SKILLS_DIR/gaia-test-review/SKILL.md"
  is_deprecated_alias "$f" && skip "deprecation alias stub"
  run grep -nE 'usage: /gaia-test-review' "$f"
  [ "$status" -ne 0 ]
  run grep -cF 'usage: /gaia-review-test' "$f"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

@test "gaia-performance-review/SKILL.md body uses /gaia-perf-deepdive in usage strings ( baseline)" {
  local f="$SKILLS_DIR/gaia-performance-review/SKILL.md"
  is_deprecated_alias "$f" && skip "deprecation alias stub"
  run grep -nE 'usage: /gaia-performance-review' "$f"
  [ "$status" -ne 0 ]
  run grep -cF 'usage: /gaia-perf-deepdive' "$f"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

# AC2: argument-hint frontmatter is canonical-name agnostic (uses
# generic "[story-key]" / "[target …]" / etc., never the legacy slash
# command literal). Verified by ensuring no argument-hint line embeds
# `/gaia-` followed by a legacy slug.
@test "no SKILL.md argument-hint embeds a legacy /gaia-<old-slug> literal" {
  for d in gaia-code-review gaia-qa-tests gaia-test-review gaia-review-security gaia-review-perf gaia-performance-review gaia-a11y-testing gaia-ci-setup; do
    local f="$SKILLS_DIR/$d/SKILL.md"
    [ -f "$f" ] || continue
    is_deprecated_alias "$f" && continue
    # argument-hint line should never contain a literal slash command.
    run grep -nE '^argument-hint:.*/gaia-' "$f"
    [ "$status" -ne 0 ] || {
      printf 'argument-hint contains /gaia- literal in %s:\n%s\n' "$f" "$output" >&2
      false
    }
  done
}

# AC3: every renamed skill exposes the new canonical name as its
# frontmatter `name:` (the addressable slash-command surface).
@test "each renamed SKILL.md frontmatter name reflects the new canonical command" {
  local pairs=(
    "gaia-code-review:gaia-review-code"
    "gaia-qa-tests:gaia-review-qa"
    "gaia-test-review:gaia-review-test"
    "gaia-review-security:gaia-review-security"
    "gaia-review-perf:gaia-review-perf"
    "gaia-performance-review:gaia-perf-deepdive"
    "gaia-a11y-testing:gaia-test-a11y"
    "gaia-ci-setup:gaia-config-ci"
  )
  for entry in "${pairs[@]}"; do
    local dir="${entry%%:*}"
    local expected="${entry##*:}"
    local f="$SKILLS_DIR/$dir/SKILL.md"
    [ -f "$f" ] || { printf 'missing SKILL.md: %s\n' "$f" >&2; false; continue; }
    run awk '/^---$/{c++; next} c==1 && /^name:/{print; exit}' "$f"
    [ "$status" -eq 0 ]
    [[ "$output" == "name: $expected" ]] || {
      printf 'expected name: %s in %s but got: %s\n' "$expected" "$f" "$output" >&2
      false
    }
  done
}

# AC4: deprecation-alias stub SKILL.md (frontmatter name begins with
# `deprecated-`) keeps its legacy slash-command name and a deprecation
# notice routing to the canonical replacement — i.e. AC4 forbids us
# from "fixing" alias stubs into canonical names. This guards against
# accidental over-sweep.
@test "deprecated-* alias stubs preserve their legacy slash-command name and route to the canonical replacement" {
  local f="$SKILLS_DIR/gaia-security-review/SKILL.md"
  if [ -f "$f" ] && is_deprecated_alias "$f"; then
    run grep -F 'usage: /gaia-security-review' "$f"
    [ "$status" -eq 0 ]
    run grep -E 'DEPRECATED|/gaia-review-security' "$f"
    [ "$status" -eq 0 ]
  else
    skip "no gaia-security-review deprecation stub present"
  fi
}
