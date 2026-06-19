#!/usr/bin/env bats
# e39-s2-create-story-spawn-guard-integration.bats
#
# Integration tests for E39-S2 (Subagent spawn for injected stories).
# Maps to TC-FITP-4, TC-FITP-5, TC-FITP-6, TC-FITP-7 from test-plan.md §11.44.
#
# These tests exercise the CLI entry points of spawn-guard.sh end-to-end,
# simulating the pre-spawn validation, collision detection, and post-spawn
# verification flows that correct-course and triage-findings SKILL.md route
# through before and after subagent spawn of /gaia-create-story.
#
# CLI contract:
#   spawn-guard.sh validate-ref <origin_ref>
#       exit 0 → origin_ref is valid (alnum + -_:.)
#       exit 1 → invalid origin_ref, error message on stderr
#
#   spawn-guard.sh check-collision <artifacts_dir> <story_key>
#       exit 0 → no collision, safe to spawn
#       exit 1 → collision detected, story file already exists
#
#   spawn-guard.sh verify <story_file> <expected_origin> <expected_origin_ref>
#       exit 0 → frontmatter origin/origin_ref match expected values
#       exit 1 → mismatch or missing fields (schema-drift error)
#
#   spawn-guard.sh cleanup <story_file>
#       exit 0 → partial file removed (or already absent)
#       exit 1 → error (empty path)
#
# AC-EC1 coverage note: the idempotent collision check (sg_check_collision)
# is the mechanism that prevents story duplication when a parent crashes
# after the subagent writes the story file but before reading the return
# payload. On retry, the collision check detects the existing file and
# halts, preventing a second spawn. This is tested in the collision
# integration tests below (TC-FITP-COLL-*).

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

SPAWN_GUARD_SH="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/spawn-guard.sh"

# ---------------------------------------------------------------------------
# Fixture builder
# ---------------------------------------------------------------------------
_make_story() {
  local dir="$1" key="$2" origin="${3:-}" origin_ref="${4:-}"
  local file="${dir}/${key}-test-story.md"
  {
    printf -- '---\n'
    printf -- "template: 'story'\n"
    printf -- 'key: "%s"\n' "$key"
    printf -- 'status: backlog\n'
    [ -n "$origin" ]     && printf -- 'origin: "%s"\n' "$origin"
    [ -n "$origin_ref" ] && printf -- 'origin_ref: "%s"\n' "$origin_ref"
    printf -- '---\n\n'
    printf -- '# Story: %s\n' "$key"
  } > "$file"
  printf '%s' "$file"
}

# ===========================================================================
# TC-FITP-4 — correct-course spawn pre-validation (origin_ref sanitization)
# ===========================================================================

@test "validate-ref accepts sprint ID format" {
  run "$SPAWN_GUARD_SH" validate-ref "sprint-26"
  [ "$status" -eq 0 ]
}

@test "validate-ref accepts finding ID format" {
  run "$SPAWN_GUARD_SH" validate-ref "F-2026-04-22-1"
  [ "$status" -eq 0 ]
}

@test "validate-ref rejects shell injection attempt" {
  run "$SPAWN_GUARD_SH" validate-ref ";rm -rf /"
  [ "$status" -eq 1 ]
}

@test "validate-ref rejects empty string" {
  run "$SPAWN_GUARD_SH" validate-ref ""
  [ "$status" -eq 1 ]
}

@test "validate-ref rejects null literal" {
  run "$SPAWN_GUARD_SH" validate-ref "null"
  [ "$status" -eq 1 ]
}

@test "validate-ref rejects path traversal" {
  run "$SPAWN_GUARD_SH" validate-ref "../../etc/passwd"
  [ "$status" -eq 1 ]
}

# ===========================================================================
# TC-FITP-5 — collision detection before spawn
# Covers AC-EC1 (idempotent retry), AC-EC3 (pre-existing stub), AC-EC6 (race)
# ===========================================================================

@test "check-collision passes when no file exists" {
  run "$SPAWN_GUARD_SH" check-collision "$TEST_TMP" "E99-S99"
  [ "$status" -eq 0 ]
}

@test "check-collision halts when story file already exists" {
  touch "$TEST_TMP/E5-S1-existing-story.md"
  run "$SPAWN_GUARD_SH" check-collision "$TEST_TMP" "E5-S1"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "E5-S1"
}

@test "COLL: collision prevents duplicate on parent retry (AC-EC1)" {
  # Simulate: subagent wrote file, parent crashed, retry detects collision
  _make_story "$TEST_TMP" "E10-S5" "correct-course" "sprint-26" >/dev/null
  run "$SPAWN_GUARD_SH" check-collision "$TEST_TMP" "E10-S5"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "E10-S5"
}

@test "check-collision does not false-positive on different key" {
  touch "$TEST_TMP/E5-S10-other-story.md"
  run "$SPAWN_GUARD_SH" check-collision "$TEST_TMP" "E5-S1"
  [ "$status" -eq 0 ]
}

@test "check-collision requires directory argument" {
  run "$SPAWN_GUARD_SH" check-collision "" "E1-S1"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "missing\|required\|usage\|argument"
}

@test "check-collision requires story key argument" {
  run "$SPAWN_GUARD_SH" check-collision "$TEST_TMP" ""
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "missing\|required\|usage\|argument"
}

# ===========================================================================
# TC-FITP-6 — post-spawn frontmatter verification (origin/origin_ref)
# Covers AC-EC8 (schema regression detection)
# ===========================================================================

@test "verify passes with matching origin and origin_ref" {
  local file
  file="$(_make_story "$TEST_TMP" "E1-S1" "correct-course" "sprint-26")"
  run "$SPAWN_GUARD_SH" verify "$file" "correct-course" "sprint-26"
  [ "$status" -eq 0 ]
}

@test "verify passes for triage-findings origin" {
  local file
  file="$(_make_story "$TEST_TMP" "E2-S1" "triage-findings" "F-2026-04-22-1")"
  run "$SPAWN_GUARD_SH" verify "$file" "triage-findings" "F-2026-04-22-1"
  [ "$status" -eq 0 ]
}

@test "verify fails when origin missing from frontmatter" {
  local file="$TEST_TMP/no-origin.md"
  cat > "$file" <<'EOF'
---
template: 'story'
key: "E1-S1"
status: backlog
origin_ref: "sprint-26"
---
EOF
  run "$SPAWN_GUARD_SH" verify "$file" "correct-course" "sprint-26"
  [ "$status" -eq 1 ]
}

@test "verify fails when origin_ref missing from frontmatter" {
  local file="$TEST_TMP/no-ref.md"
  cat > "$file" <<'EOF'
---
template: 'story'
key: "E1-S1"
status: backlog
origin: "correct-course"
---
EOF
  run "$SPAWN_GUARD_SH" verify "$file" "correct-course" "sprint-26"
  [ "$status" -eq 1 ]
}

@test "verify fails on origin value mismatch (AC-EC8 drift)" {
  local file
  file="$(_make_story "$TEST_TMP" "E1-S1" "triage-findings" "sprint-26")"
  run "$SPAWN_GUARD_SH" verify "$file" "correct-course" "sprint-26"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "mismatch\|drift\|schema"
}

@test "verify fails on origin_ref value mismatch" {
  local file
  file="$(_make_story "$TEST_TMP" "E1-S1" "correct-course" "sprint-25")"
  run "$SPAWN_GUARD_SH" verify "$file" "correct-course" "sprint-26"
  [ "$status" -eq 1 ]
}

@test "verify fails when file does not exist" {
  run "$SPAWN_GUARD_SH" verify "$TEST_TMP/nonexistent.md" "correct-course" "sprint-26"
  [ "$status" -eq 1 ]
}

# ===========================================================================
# TC-FITP-7 — partial file cleanup on spawn failure
# Covers AC4, AC-EC4 (partial file), AC-EC5 (timeout cleanup)
# ===========================================================================

@test "cleanup removes partial file" {
  local file="$TEST_TMP/E1-S1-partial.md"
  echo "partial" > "$file"
  run "$SPAWN_GUARD_SH" cleanup "$file"
  [ "$status" -eq 0 ]
  [ ! -f "$file" ]
}

@test "cleanup is idempotent (no file = no error)" {
  run "$SPAWN_GUARD_SH" cleanup "$TEST_TMP/already-gone.md"
  [ "$status" -eq 0 ]
}

@test "cleanup rejects empty path" {
  run "$SPAWN_GUARD_SH" cleanup ""
  [ "$status" -eq 1 ]
}

# ===========================================================================
# CLI contract edge cases
# ===========================================================================

@test "spawn-guard.sh: usage on no arguments" {
  run "$SPAWN_GUARD_SH"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "usage"
}

@test "spawn-guard.sh: unknown subcommand exits 1" {
  run "$SPAWN_GUARD_SH" foobar
  [ "$status" -eq 1 ]
}
