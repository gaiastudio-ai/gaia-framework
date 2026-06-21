#!/usr/bin/env bats
# create-story-sizing-map.bats — E61-S2 / ADR-074 contract C1
#
# Verifies that gaia-create-story Step 4 documents `points` derivation from
# `size` via `!scripts/resolve-config.sh sizing_map`, mirroring the existing
# pattern in gaia-sprint-plan, and exercises the resolver with a project-
# layer override fixture across all four sizes (S/M/L/XL) plus the default
# fallback.
#
# Test scenarios trace back to the story's Test Scenarios table:
#   #1   SKILL.md documentation grep                (AC1)
#   #2   Override M=3                               (AC2)
#   #3-5 Override S=1, L=5, XL=8                    (AC3)
#   #6   Default fallback                           (AC3)
#   #8   Pattern parity with gaia-sprint-plan       (AC1)
#   HALT-on-resolver-error documented in SKILL.md  (Dev Notes / Technical Notes)
#
# Pattern: cluster-1 fixture pattern (synthetic configs in TEST_TMP/skill,
# CLAUDE_SKILL_DIR-driven discovery; the real repo configs are not touched).

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/resolve-config.sh"
  SKILL_DIR="$SKILLS_DIR/gaia-create-story"
  SPRINT_PLAN_SKILL_DIR="$SKILLS_DIR/gaia-sprint-plan"
}
teardown() { common_teardown; }

mk_required_fields() {
  cat <<'YAML'
project_root: /tmp/gaia-szm-cs
project_path: /tmp/gaia-szm-cs/app
memory_path: /tmp/gaia-szm-cs/_memory
checkpoint_path: /tmp/gaia-szm-cs/_memory/checkpoints
installed_path: /tmp/gaia-szm-cs/_gaia
framework_version: 1.127.2-rc.1
date: 2026-04-28
YAML
}

mk_shared_with_override() {
  # Writes a synthetic shared project-config.yaml with the canonical override
  # sizing_map: {S: 1, M: 3, L: 5, XL: 8}. Values are deliberately distinct
  # from the framework defaults (S=2, M=5, L=8, XL=13) so the override is
  # unambiguously visible in the resolver output for each size.
  local dir="$1"
  mkdir -p "$dir/config"
  {
    mk_required_fields
    cat <<'YAML'
sizing_map:
  S: 1
  M: 3
  L: 5
  XL: 8
YAML
  } > "$dir/config/project-config.yaml"
}

mk_shared_no_override() {
  local dir="$1"
  mkdir -p "$dir/config"
  mk_required_fields > "$dir/config/project-config.yaml"
}

# Helper: extract a single size's resolved value from `resolve-config.sh
# sizing_map` output. Each line has the form `S=1`, `M=3`, etc. Returns the
# numeric value for the requested size on stdout.
extract_size_value() {
  local size="$1" output="$2"
  printf '%s\n' "$output" | awk -F= -v k="$size" '$1==k{print $2; exit}'
}

# ---------------------------------------------------------------------------
# AC1 — SKILL.md Step 4 documents sizing_map resolution
# ---------------------------------------------------------------------------

@test "AC1: SKILL.md exists for gaia-create-story" {
  [ -f "$SKILL_DIR/SKILL.md" ]
}

@test "AC1: SKILL.md Step 4 references resolve-config.sh sizing_map" {
  run grep -nE "resolve-config\.sh[[:space:]]+sizing_map" "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AC1: SKILL.md Step 4 documents points derivation from size" {
  # The bullet must name `points` and `size` together so the derivation
  # contract is unambiguous to a future maintainer.
  run grep -nE "points.*(derived|derive).*size|size.*(derived|derive).*points" \
    "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

# These assert the CONCEPTS the SKILL.md documents, not internal traceability
# identifiers (FR-/ADR-/E<n>-S<n> are scrubbed from published source by policy —
# asserting their presence would force a leak back into shipped prose).

@test "AC1: SKILL.md documents the deterministic-script-lift contract (no algorithm re-implemented in prose)" {
  # The SKILL must state that frontmatter/sizing/canonical-filename logic is
  # delegated to scripts, not re-described in prose.
  run grep -niE 'no longer (describe|re-implement)|delegated to|deterministic' "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AC1: SKILL.md documents project-over-global precedence for the resolved config" {
  run grep -niE 'project-over-global|project > global|project over global' "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AC1: SKILL.md documents the project-config.yaml sizing_map block as the points source" {
  run grep -niE 'sizing_map' "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Pattern parity (Scenario 8) — both skills invoke the resolver with the
# identical positional key. Locks the contract that gaia-create-story does
# NOT diverge from gaia-sprint-plan's resolver invocation form.
# ---------------------------------------------------------------------------

@test "Scenario 8: pattern parity — gaia-sprint-plan also invokes resolve-config.sh sizing_map" {
  run grep -E "resolve-config\.sh[[:space:]]+sizing_map" \
    "$SPRINT_PLAN_SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "Scenario 8: pattern parity — both skills use the identical resolver key" {
  # Stronger parity assertion: the literal token `resolve-config.sh sizing_map`
  # appears in BOTH SKILL.md files. Any future drift (e.g., one skill adds an
  # argument, the other does not) trips this test.
  run grep -lE "resolve-config\.sh[[:space:]]+sizing_map" \
    "$SKILL_DIR/SKILL.md" "$SPRINT_PLAN_SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
  # Both files must match — output is the list of matching files.
  [[ "$output" == *"gaia-create-story/SKILL.md"* ]]
  [[ "$output" == *"gaia-sprint-plan/SKILL.md"* ]]
}

# ---------------------------------------------------------------------------
# HALT-on-resolver-error — Dev Notes / Technical Notes contract that the
# skill MUST NOT silently fall back to a hardcoded mapping (FR-340 / story
# AC2 + Test Scenario #7).
# ---------------------------------------------------------------------------

@test "AC1: SKILL.md documents HALT on resolver non-zero or malformed sizing_map" {
  # Stronger than a global HALT match: the no-silent-fallback contract for
  # sizing_map specifically must be documented. Allow either a single line
  # combining HALT + sizing_map/resolver, or an explicit "no silent fallback"
  # phrase with sizing_map anywhere in the same paragraph.
  run grep -niE "HALT.*(resolve-config|sizing_map)|no[[:space:]]+silent[[:space:]]+fallback.*sizing_map|sizing_map.*(no[[:space:]]+silent[[:space:]]+fallback|HALT)" \
    "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC2 / AC3 — resolver returns the project-layer override values for each
# of the four sizes (S/M/L/XL). These tests exercise the SAME positional
# `sizing_map` invocation that gaia-create-story will use to derive the
# `points:` line in Step 4.
# ---------------------------------------------------------------------------

@test "AC2: override M=3 resolves to 3 (not the 5 default)" {
  mk_shared_with_override "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" sizing_map
  [ "$status" -eq 0 ]
  local v
  v="$(extract_size_value M "$output")"
  [ "$v" = "3" ]
  [ "$v" != "5" ]
}

@test "AC3: override S=1 resolves to 1 (not the 2 default)" {
  mk_shared_with_override "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" sizing_map
  [ "$status" -eq 0 ]
  local v
  v="$(extract_size_value S "$output")"
  [ "$v" = "1" ]
  [ "$v" != "2" ]
}

@test "AC3: override L=5 resolves to 5 (not the 8 default)" {
  mk_shared_with_override "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" sizing_map
  [ "$status" -eq 0 ]
  local v
  v="$(extract_size_value L "$output")"
  [ "$v" = "5" ]
  [ "$v" != "8" ]
}

@test "AC3: override XL=8 resolves to 8 (not the 13 default)" {
  mk_shared_with_override "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" sizing_map
  [ "$status" -eq 0 ]
  local v
  v="$(extract_size_value XL "$output")"
  [ "$v" = "8" ]
  [ "$v" != "13" ]
}

# ---------------------------------------------------------------------------
# Default fallback (Test Scenario #6) — no project-level sizing_map block →
# resolver returns the canonical Fibonacci defaults (S=2, M=5, L=8, XL=13).
# Locks the contract that the resolver is the single source of points truth
# even when the project has not declared an override block.
# ---------------------------------------------------------------------------

@test "Scenario 6: default fallback — no override → S=2, M=5, L=8, XL=13" {
  mk_shared_no_override "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" sizing_map
  [ "$status" -eq 0 ]
  [ "$(extract_size_value S  "$output")" = "2" ]
  [ "$(extract_size_value M  "$output")" = "5" ]
  [ "$(extract_size_value L  "$output")" = "8" ]
  [ "$(extract_size_value XL "$output")" = "13" ]
}
