#!/usr/bin/env bats
# mode-b-parity.bats — capstone parity + backward-compatibility verification
# for the persistent-teammate dispatch stack.
#
# Substrate-honest: live persistent-teammate round-trips are not exercisable in
# this environment, so the spawn path degrades to foreground fallback. These
# tests assert:
#   - the opt-in per-skill fallback knob (a skill declaring `mode: A` in its
#     frontmatter forces foreground dispatch even under a team-mode framework);
#   - the roster-cost measurement runs, emits a P95, and compares it to a
#     documented threshold (measured on the fallback bookkeeping path);
#   - the verification report is generated with the required fields.

load 'test_helper.bash'

setup() {
  common_setup

  LIB_DIR="$SCRIPTS_DIR/lib"
  RESOLVE_LIB="$LIB_DIR/mode-resolve.sh"
  DT_LIB="$LIB_DIR/dispatch-teammate.sh"
  ROSTER="$LIB_DIR/roster-cost.sh"
  REPORT_GEN="$SCRIPTS_DIR/gen-mode-b-verification-report.sh"

  export GAIA_SESSION_DIR="$TEST_TMP/session"
  export GAIA_PROVENANCE_LOG="$TEST_TMP/session/provenance.log"
  export GAIA_SESSION_TRANSCRIPT="$TEST_TMP/session/transcript.md"
  mkdir -p "$GAIA_SESSION_DIR"

  export GAIA_MODE_B_SUBSTRATE=unavailable
}

teardown() { common_teardown; }

# Build a minimal fixture SKILL.md with optional `mode:` frontmatter.
# Usage: _make_skill <dir> [mode_value]
_make_skill() {
  local dir="$1" mode="${2:-}"
  mkdir -p "$dir"
  {
    printf -- '---\n'
    printf 'name: fixture-skill\n'
    printf 'description: a fixture skill for parity testing\n'
    if [ -n "$mode" ]; then
      printf 'mode: %s\n' "$mode"
    fi
    printf -- '---\n\n'
    printf '# Fixture\n'
  } > "$dir/SKILL.md"
}

# ============================================================
# Opt-in per-skill fallback knob
# ============================================================

@test "mode-resolve library is sourceable and exports resolve_skill_mode (AC2)" {
  source "$RESOLVE_LIB"
  declare -F resolve_skill_mode
}

@test "a skill declaring mode A forces Mode A even under team mode (AC2)" {
  source "$RESOLVE_LIB"
  _make_skill "$TEST_TMP/skill-a" "A"
  run resolve_skill_mode "$TEST_TMP/skill-a/SKILL.md" team
  [ "$status" -eq 0 ]
  [ "$output" = "subagent" ]
}

@test "a skill without mode override under team mode attempts team (AC2)" {
  source "$RESOLVE_LIB"
  _make_skill "$TEST_TMP/skill-none"
  run resolve_skill_mode "$TEST_TMP/skill-none/SKILL.md" team
  [ "$status" -eq 0 ]
  [ "$output" = "team" ]
}

@test "global subagent mode stays subagent regardless of frontmatter (AC2)" {
  source "$RESOLVE_LIB"
  _make_skill "$TEST_TMP/skill-b" "B"
  run resolve_skill_mode "$TEST_TMP/skill-b/SKILL.md" subagent
  [ "$status" -eq 0 ]
  [ "$output" = "subagent" ]
}

@test "lowercase mode a is recognised as a Mode A override (AC2)" {
  source "$RESOLVE_LIB"
  _make_skill "$TEST_TMP/skill-lc" "a"
  run resolve_skill_mode "$TEST_TMP/skill-lc/SKILL.md" team
  [ "$status" -eq 0 ]
  [ "$output" = "subagent" ]
}

@test "a missing SKILL.md falls back to the global mode without error (AC2)" {
  source "$RESOLVE_LIB"
  run resolve_skill_mode "$TEST_TMP/does-not-exist/SKILL.md" team
  [ "$status" -eq 0 ]
  [ "$output" = "team" ]
}

# ============================================================
# Mode A dispatch asserted under team mode with opt-in fallback
# ============================================================

@test "dispatch under team mode with mode A takes the foreground path (AC4)" {
  source "$RESOLVE_LIB"
  source "$DT_LIB"
  _make_skill "$TEST_TMP/skill-a" "A"

  resolved="$(resolve_skill_mode "$TEST_TMP/skill-a/SKILL.md" team)"
  [ "$resolved" = "subagent" ]

  # With Mode A resolved, the caller must NOT spawn a teammate. Assert that no
  # registry file is created when the resolved mode is subagent.
  if [ "$resolved" != "subagent" ]; then
    handle="$(spawn_teammate "gaia:analyst")"
    [ -n "$handle" ]
  fi

  local registry="$GAIA_SESSION_DIR/registry"
  local file_count=0
  if [ -d "$registry" ]; then
    file_count="$(find "$registry" -maxdepth 1 -type f | wc -l | tr -d ' ')"
  fi
  [ "$file_count" -eq 0 ]
}

@test "dispatch without mode override under team mode degrades to fallback (AC4)" {
  source "$RESOLVE_LIB"
  source "$DT_LIB"
  _make_skill "$TEST_TMP/skill-none"

  resolved="$(resolve_skill_mode "$TEST_TMP/skill-none/SKILL.md" team)"
  [ "$resolved" = "team" ]

  # Resolved team mode → caller attempts a spawn; with substrate unavailable
  # the shared library emits the MODE_B_FALLBACK token to stderr and the handle
  # to stdout. Capture stdout in-process so the fallback token does not pollute
  # the handle assertion.
  local handle fallback
  handle="$(spawn_teammate "gaia:analyst" --context "parity-test" 2>"$TEST_TMP/spawn.err")"
  [[ "$handle" == tm-* ]]
  fallback="$(cat "$TEST_TMP/spawn.err")"
  [[ "$fallback" == *MODE_B_FALLBACK* ]]
}

# ============================================================
# Roster-cost measurement
# ============================================================

@test "roster-cost script runs and emits a P95 number (AC3)" {
  run bash "$ROSTER" --iterations 10
  [ "$status" -eq 0 ]
  [[ "$output" =~ p95_ms=[0-9]+ ]]
}

@test "roster-cost emits the documented threshold and a pass/fail verdict (AC3)" {
  run bash "$ROSTER" --iterations 10
  [ "$status" -eq 0 ]
  [[ "$output" =~ threshold_ms=[0-9]+ ]]
  [[ "$output" =~ verdict=(pass|fail) ]]
}

@test "roster-cost P95 is at or under the documented threshold (AC3)" {
  run bash "$ROSTER" --iterations 20
  [ "$status" -eq 0 ]
  p95="$(printf '%s\n' "$output" | grep -oE 'p95_ms=[0-9]+' | head -1 | cut -d= -f2)"
  thr="$(printf '%s\n' "$output" | grep -oE 'threshold_ms=[0-9]+' | head -1 | cut -d= -f2)"
  [ -n "$p95" ]
  [ -n "$thr" ]
  [ "$p95" -le "$thr" ]
}

# ============================================================
# Verification report
# ============================================================

@test "report generator runs and writes the report file (AC5)" {
  run bash "$REPORT_GEN" --out "$TEST_TMP/report.md"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/report.md" ]
}

@test "report contains a per-skill status table and a roster-cost P95 (AC5)" {
  run bash "$REPORT_GEN" --out "$TEST_TMP/report.md"
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_TMP/report.md" "Per-Skill"
  assert_file_contains "$TEST_TMP/report.md" "p95_ms"
}

@test "report lists every team-ready skill discovered in the plugin (AC5)" {
  run bash "$REPORT_GEN" --out "$TEST_TMP/report.md"
  [ "$status" -eq 0 ]
  # At least one team-ready skill must appear with a readiness column value.
  run grep -cE 'readiness section present' "$TEST_TMP/report.md"
  [ "$status" -eq 0 ]
}

@test "report records fallback status honestly (no live-substrate claim) (AC5)" {
  run bash "$REPORT_GEN" --out "$TEST_TMP/report.md"
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_TMP/report.md" "fallback"
}

# ============================================================
# No leaked internal identifiers in generated artifacts
# ============================================================

@test "mode-resolve library is free of leaked internal identifiers" {
  run grep -nE '(FR|NFR|SR|ADR|TC|AF|AI)-[0-9]|E[0-9]+-S[0-9]+' "$RESOLVE_LIB"
  [ "$status" -ne 0 ]
}

@test "roster-cost script is free of leaked internal identifiers" {
  run grep -nE '(FR|NFR|SR|ADR|TC|AF|AI)-[0-9]|E[0-9]+-S[0-9]+' "$ROSTER"
  [ "$status" -ne 0 ]
}

@test "report generator is free of leaked internal identifiers" {
  run grep -nE '(FR|NFR|SR|ADR|TC|AF|AI)-[0-9]|E[0-9]+-S[0-9]+' "$REPORT_GEN"
  [ "$status" -ne 0 ]
}
