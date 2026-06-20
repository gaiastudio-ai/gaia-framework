#!/usr/bin/env bats
# clean-room-gate.bats — reviewer clean-room enforcement (3-layer gate).
#
# Verifies that reviewer personas cannot be spawned as Mode B teammates
# (runtime gate), that SKILL.md rosters declaring reviewer teammates are
# flagged (static roster lint), and that source-level spawn_teammate calls
# with reviewer-persona literals are detected (static call-site scan).

load 'test_helper.bash'

setup() {
  common_setup

  LIB_DIR="$SCRIPTS_DIR/lib"
  LIB="$LIB_DIR/dispatch-teammate.sh"
  REVIEWER_LIST="$BATS_TEST_DIRNAME/../knowledge/reviewer-personas.txt"
  CLEAN_ROOM_LINT="$LIB_DIR/clean-room-lint.sh"

  # Session-scoped directories for the library under test.
  export GAIA_SESSION_DIR="$TEST_TMP/session"
  export GAIA_PROVENANCE_LOG="$TEST_TMP/session/provenance.log"
  export GAIA_SESSION_TRANSCRIPT="$TEST_TMP/session/transcript.md"
  mkdir -p "$GAIA_SESSION_DIR"

  # Force substrate unavailable — tests exercise plumbing.
  export GAIA_MODE_B_SUBSTRATE="${GAIA_MODE_B_SUBSTRATE:-unavailable}"
}

teardown() { common_teardown; }

# ============================================================
# Runtime gate — reviewer persona rejected (AC1)
# ============================================================

@test "spawn_teammate with reviewer persona 'validator' fails non-zero (AC1)" {
  source "$LIB"
  run spawn_teammate "validator"
  [ "$status" -ne 0 ]
}

@test "spawn_teammate with reviewer persona 'tdd-reviewer' fails non-zero (AC1)" {
  source "$LIB"
  run spawn_teammate "tdd-reviewer"
  [ "$status" -ne 0 ]
}

@test "spawn_teammate with reviewer persona 'security' fails non-zero (AC1)" {
  source "$LIB"
  run spawn_teammate "security"
  [ "$status" -ne 0 ]
}

@test "spawn_teammate with reviewer persona 'qa' fails non-zero (AC1)" {
  source "$LIB"
  run spawn_teammate "qa"
  [ "$status" -ne 0 ]
}

@test "spawn_teammate with reviewer persona 'performance' fails non-zero (AC1)" {
  source "$LIB"
  run spawn_teammate "performance"
  [ "$status" -ne 0 ]
}

@test "spawn_teammate with reviewer persona 'adversarial-reviewer' fails non-zero (AC1)" {
  source "$LIB"
  run spawn_teammate "adversarial-reviewer"
  [ "$status" -ne 0 ]
}

@test "spawn_teammate with reviewer persona 'test-architect' fails non-zero (AC1)" {
  source "$LIB"
  run spawn_teammate "test-architect"
  [ "$status" -ne 0 ]
}

@test "spawn_teammate with reviewer persona 'code-reviewer' fails non-zero (AC1)" {
  source "$LIB"
  run spawn_teammate "code-reviewer"
  [ "$status" -ne 0 ]
}

@test "spawn_teammate with reviewer persona 'reviewer' fails non-zero (AC1)" {
  source "$LIB"
  run spawn_teammate "reviewer"
  [ "$status" -ne 0 ]
}

@test "spawn_teammate rejection diagnostic cites clean-room invariant (AC1)" {
  source "$LIB"
  run spawn_teammate "validator"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "clean-room" ]] || [[ "$output" =~ "clean room" ]]
}

@test "spawn_teammate rejection diagnostic names the rejected persona (AC1)" {
  source "$LIB"
  run spawn_teammate "tdd-reviewer"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "tdd-reviewer" ]]
}

@test "spawn_teammate rejects gaia:-prefixed reviewer persona (AC1)" {
  source "$LIB"
  run spawn_teammate "gaia:validator"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "clean-room" ]] || [[ "$output" =~ "clean room" ]]
}

@test "clean-room gate fires BEFORE ceiling check (AC1)" {
  source "$LIB"
  # Fill to ceiling
  local i
  for i in $(seq 1 8); do
    spawn_teammate "gaia:agent-$i" >/dev/null
  done
  # A reviewer persona must be rejected with clean-room, not ceiling
  run spawn_teammate "validator"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "clean-room" ]] || [[ "$output" =~ "clean room" ]]
}

# ============================================================
# Runtime gate — non-reviewer persona allowed (AC2)
# ============================================================

@test "spawn_teammate with non-reviewer persona 'gaia:architect' succeeds (AC2)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:architect" 2>/dev/null)"
  [ -n "$handle" ]
}

@test "spawn_teammate with non-reviewer persona 'gaia:pm' succeeds (AC2)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:pm" 2>/dev/null)"
  [ -n "$handle" ]
}

@test "spawn_teammate with non-reviewer persona 'gaia:sm' succeeds (AC2)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "gaia:sm" 2>/dev/null)"
  [ -n "$handle" ]
}

@test "spawn_teammate with non-reviewer persona 'devops' succeeds (AC2)" {
  source "$LIB"
  local handle
  handle="$(spawn_teammate "devops" 2>/dev/null)"
  [ -n "$handle" ]
}

# ============================================================
# Static SKILL.md roster lint (AC3)
# ============================================================

_write_skill_fixture() {
  local path="$1"
  shift
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "---" > "$path"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >> "$path"
  done
  printf '%s\n' "---" >> "$path"
  printf '%s\n' "# Test Skill" >> "$path"
  printf '%s\n' "" >> "$path"
  printf '%s\n' "Body text." >> "$path"
}

@test "roster lint flags SKILL.md that declares reviewer persona as teammate (AC3)" {
  local fixture="$TEST_TMP/skills/test-bad/SKILL.md"
  _write_skill_fixture "$fixture" \
    "name: test-bad" \
    "roster:" \
    "  - name: val" \
    "    persona: gaia:validator" \
    "  - name: arch" \
    "    persona: gaia:architect" \
    "topology: hub"

  run bash "$CLEAN_ROOM_LINT" --roster "$fixture"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "validator" ]]
}

@test "roster lint passes SKILL.md with only non-reviewer personas (AC3)" {
  local fixture="$TEST_TMP/skills/test-ok/SKILL.md"
  _write_skill_fixture "$fixture" \
    "name: test-ok" \
    "roster:" \
    "  - name: arch" \
    "    persona: gaia:architect" \
    "  - name: pm" \
    "    persona: gaia:pm" \
    "topology: hub"

  run bash "$CLEAN_ROOM_LINT" --roster "$fixture"
  [ "$status" -eq 0 ]
}

@test "roster lint passes SKILL.md with no roster section (AC3)" {
  local fixture="$TEST_TMP/skills/test-noroster/SKILL.md"
  _write_skill_fixture "$fixture" \
    "name: test-noroster" \
    "topology: hub"

  run bash "$CLEAN_ROOM_LINT" --roster "$fixture"
  [ "$status" -eq 0 ]
}

@test "roster lint reports multiple reviewer personas in one roster (AC3)" {
  local fixture="$TEST_TMP/skills/test-multi/SKILL.md"
  _write_skill_fixture "$fixture" \
    "name: test-multi" \
    "roster:" \
    "  - name: val" \
    "    persona: gaia:validator" \
    "  - name: sec" \
    "    persona: gaia:security" \
    "  - name: arch" \
    "    persona: gaia:architect" \
    "topology: hub"

  run bash "$CLEAN_ROOM_LINT" --roster "$fixture"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "validator" ]]
  [[ "$output" =~ "security" ]]
}

# ============================================================
# Static call-site scan (AC4)
# ============================================================

@test "call-site scan flags spawn_teammate with reviewer-persona literal (AC4)" {
  local src="$TEST_TMP/src/bad-caller.sh"
  mkdir -p "$TEST_TMP/src"
  printf '#!/usr/bin/env bash\nspawn_teammate "validator"\n' > "$src"

  run bash "$CLEAN_ROOM_LINT" --callsite "$TEST_TMP/src"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "validator" ]]
}

@test "call-site scan passes source with no reviewer-persona spawn calls (AC4)" {
  local src="$TEST_TMP/src/ok-caller.sh"
  mkdir -p "$TEST_TMP/src"
  printf '#!/usr/bin/env bash\nspawn_teammate "gaia:architect"\n' > "$src"

  run bash "$CLEAN_ROOM_LINT" --callsite "$TEST_TMP/src"
  [ "$status" -eq 0 ]
}

@test "call-site scan detects gaia:-prefixed reviewer persona in spawn call (AC4)" {
  local src="$TEST_TMP/src/prefixed.sh"
  mkdir -p "$TEST_TMP/src"
  printf '#!/usr/bin/env bash\nspawn_teammate "gaia:security"\n' > "$src"

  run bash "$CLEAN_ROOM_LINT" --callsite "$TEST_TMP/src"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "security" ]]
}

@test "call-site scan ignores comments containing spawn_teammate reviewer (AC4)" {
  local src="$TEST_TMP/src/comment.sh"
  mkdir -p "$TEST_TMP/src"
  printf '#!/usr/bin/env bash\n# spawn_teammate "validator" — example only\nspawn_teammate "gaia:architect"\n' > "$src"

  run bash "$CLEAN_ROOM_LINT" --callsite "$TEST_TMP/src"
  [ "$status" -eq 0 ]
}

# ============================================================
# Corpus scan — existing skills have zero violations (AC5)
# ============================================================

@test "corpus scan of existing skills finds zero reviewer-as-teammate violations (AC5)" {
  local skills_dir="$BATS_TEST_DIRNAME/../skills"

  # Scan all SKILL.md files via roster lint
  local violations=0
  local scanned=0
  local skill_file
  while IFS= read -r skill_file; do
    scanned=$((scanned + 1))
    if bash "$CLEAN_ROOM_LINT" --roster "$skill_file" 2>/dev/null; then
      : # clean
    else
      violations=$((violations + 1))
    fi
  done < <(find "$skills_dir" -name 'SKILL.md' -type f 2>/dev/null)

  # Min-count guard: must have scanned a meaningful number of skills
  [ "$scanned" -ge 50 ]
  # Zero violations
  [ "$violations" -eq 0 ]
}

@test "corpus call-site scan of existing scripts finds zero violations (AC5)" {
  local scripts_dir="$BATS_TEST_DIRNAME/../scripts"
  local skills_dir="$BATS_TEST_DIRNAME/../skills"

  # Scan scripts/ and skills/*/scripts/ for spawn_teammate calls with reviewer personas
  run bash "$CLEAN_ROOM_LINT" --callsite "$scripts_dir" "$skills_dir"
  [ "$status" -eq 0 ]
}
