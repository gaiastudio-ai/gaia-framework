#!/usr/bin/env bats
# e45-s3-auto-save-memory.bats — auto-save-memory.sh regression suite
#
# Story: E45-S3 (Auto-save session memory at finalize for 24 Phase 1-3 skills)
# ADR-061 (scope-bounded auto-save), ADR-057 (Phase 4 boundary preserved)
#
# Coverage matrix (mapped to story ACs):
#   AC1   — Phase 1-3 finalize writes session summary, no prompt
#   AC2   — entry contains key fields (Inputs / Outputs / Open questions)
#   AC3   — no `[y]/[n]/[e]` prompt appears in output
#   AC-EC1 — Phase 4 skill: function returns 0, NO write happens
#   AC-EC3 — sidecar dir absent: created with canonical header
#   AC-EC5 — empty session: minimal "No persistable decisions" entry
#   AC-EC7 — unknown skill: exit 64, actionable error message
#   AC-EC8 — secret patterns redacted before write
#   AC-EC10 — skill present in both Phase 1-3 and Phase 4 -> Phase 4 wins
#
# NFR-052 public functions exercised: _auto_save_memory, _autosave_log,
#   _autosave_redact_secrets, _autosave_compose_summary, _autosave_append.

load 'test_helper.bash'

setup() {
    common_setup
    SCRIPT="$SCRIPTS_DIR/lib/auto-save-memory.sh"
    PHASE_LIB="$SCRIPTS_DIR/lib/phase-classification.sh"

    # Build a per-test fake _memory tree so we never write to the real
    # repository sidecar directories.
    FAKE_MEMORY="$TEST_TMP/_memory"
    mkdir -p "$FAKE_MEMORY"
    cat > "$FAKE_MEMORY/config.yaml" <<'EOF'
agents:
  pm:
    sidecar: pm-sidecar
  analyst:
    sidecar: analyst-sidecar
  architect:
    sidecar: architect-sidecar
  validator:
    sidecar: validator-sidecar
  ux-designer:
    sidecar: ux-designer-sidecar
  test-architect:
    sidecar: test-architect-sidecar
  security:
    sidecar: security-sidecar
  devops:
    sidecar: devops-sidecar
EOF
    export MEMORY_PATH="$FAKE_MEMORY"
}

teardown() { common_teardown; }

# Helper — invoke _auto_save_memory in a clean subshell with the fake
# memory path injected. Captures stdout+stderr separately via run.
run_save() {
    run bash -c "
        export MEMORY_PATH='$FAKE_MEMORY'
        export AUTO_SAVE_LATENCY_THRESHOLD=10
        source '$SCRIPT'
        _auto_save_memory $*
    "
}

# --- Existence ------------------------------------------------------------

@test "auto-save-memory.sh: file exists and is executable" {
    [ -f "$SCRIPT" ]
    [ -x "$SCRIPT" ]
}

@test "auto-save-memory.sh: sourceable without side effects" {
    run bash -c "MEMORY_PATH='$FAKE_MEMORY' source '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "auto-save-memory.sh: defines _auto_save_memory public function" {
    grep -qE '^_auto_save_memory\(\)[[:space:]]*\{' "$SCRIPT"
}

@test "auto-save-memory.sh: defines _autosave_redact_secrets public function" {
    grep -qE '^_autosave_redact_secrets\(\)[[:space:]]*\{' "$SCRIPT"
}

@test "auto-save-memory.sh: defines _autosave_compose_summary public function" {
    grep -qE '^_autosave_compose_summary\(\)[[:space:]]*\{' "$SCRIPT"
}

@test "auto-save-memory.sh: defines _autosave_append public function" {
    grep -qE '^_autosave_append\(\)[[:space:]]*\{' "$SCRIPT"
}

# --- AC1 + AC2: Phase 1-3 happy path --------------------------------------

@test "Phase 1-3 skill writes session summary to agent sidecar" {
    # Arrange — fake artifact for /gaia-create-prd.
    local artifact="$TEST_TMP/prd.md"
    printf '# PRD\n\n## Goals\n\n- Solve the world.\n' > "$artifact"

    run_save gaia-create-prd "$artifact"
    [ "$status" -eq 0 ]

    # The decision-log file should now exist under pm-sidecar.
    local sidecar="$FAKE_MEMORY/pm-sidecar/decision-log.md"
    [ -f "$sidecar" ]
    grep -q 'gaia-create-prd Session Summary' "$sidecar"
}

@test "written entry contains Inputs/Outputs/Open questions sections" {
    local artifact="$TEST_TMP/brief.md"
    printf '# Brief\n\n## Vision\n\nSomething.\n' > "$artifact"

    run_save gaia-product-brief "$artifact"
    [ "$status" -eq 0 ]

    local sidecar="$FAKE_MEMORY/analyst-sidecar/decision-log.md"
    [ -f "$sidecar" ]
    grep -q '\*\*Inputs:\*\*' "$sidecar"
    grep -q '\*\*Outputs:\*\*' "$sidecar"
    grep -q '\*\*Open questions:\*\*' "$sidecar"
}

@test "no [y]/[n]/[e] prompt appears in any output stream" {
    local artifact="$TEST_TMP/arch.md"
    printf '# Arch\n' > "$artifact"

    run_save gaia-create-arch "$artifact"
    [ "$status" -eq 0 ]

    # Combined stdout+stderr must not contain the interactive prompt.
    printf '%s' "$output" | grep -q '\[y\]/\[n\]/\[e\]' && return 1
    return 0
}

# --- AC-EC1: Phase 4 boundary preserved ------------------------------------

@test "Phase 4 skill (gaia-dev-story) is a no-op (no write happens)" {
    run_save gaia-dev-story
    [ "$status" -eq 0 ]

    # No sidecar should have been created for Phase 4.
    [ ! -f "$FAKE_MEMORY/dev-sidecar/decision-log.md" ]
    # And specifically no pm-sidecar (which would imply mis-classification).
    [ ! -f "$FAKE_MEMORY/pm-sidecar/decision-log.md" ]
}

# --- AC-EC3: sidecar directory missing -------------------------------------

@test "missing sidecar directory is created with canonical header" {
    # Confirm pre-state: directory absent.
    [ ! -d "$FAKE_MEMORY/architect-sidecar" ]

    local artifact="$TEST_TMP/epics.md"
    printf '# Epics\n' > "$artifact"

    run_save gaia-create-epics "$artifact"
    [ "$status" -eq 0 ]

    # Directory exists, decision-log.md has canonical header.
    [ -d "$FAKE_MEMORY/architect-sidecar" ]
    local sidecar="$FAKE_MEMORY/architect-sidecar/decision-log.md"
    [ -f "$sidecar" ]
    head -1 "$sidecar" | grep -q 'Decision Log'
}

# --- AC-EC5: empty session ------------------------------------------------

@test "empty session writes minimal No persistable decisions entry" {
    # Invoke without any artifact paths.
    run_save gaia-brainstorm
    [ "$status" -eq 0 ]

    local sidecar="$FAKE_MEMORY/analyst-sidecar/decision-log.md"
    [ -f "$sidecar" ]
    grep -q 'No persistable decisions this session' "$sidecar"
}

# --- AC-EC7: unknown skill ------------------------------------------------

@test "unknown skill exits 64 with actionable error" {
    run_save gaia-not-real-skill
    [ "$status" -eq 64 ]
    printf '%s' "$output" | grep -q 'cannot resolve agent sidecar'
}

# --- AC-EC8: secret redaction ---------------------------------------------

@test "API key in summary is redacted before write" {
    # Inject a secret into the artifact filename and content.
    local artifact="$TEST_TMP/notes.md"
    printf '# Notes\n\nKey: sk-abcdefghijklmnopqrstuvwxyz123\n' > "$artifact"

    run_save gaia-product-brief "$artifact"
    [ "$status" -eq 0 ]

    local sidecar="$FAKE_MEMORY/analyst-sidecar/decision-log.md"
    [ -f "$sidecar" ]
    # Body of saved summary shouldn't contain the raw secret.
    ! grep -q 'sk-abcdefghijklmnopqrstuvwxyz123' "$sidecar"
}

@test "redact_secrets pure function replaces sk- pattern" {
    run bash -c "
        source '$SCRIPT'
        _autosave_redact_secrets 'token sk-abcdefghijklmnopqrstuvwxyz1'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"[REDACTED]"* ]]
    [[ "$output" != *"sk-abcdefghijklmnopqrstuvwxyz1"* ]]
}

@test "redact_secrets pure function replaces AWS access key" {
    run bash -c "
        source '$SCRIPT'
        _autosave_redact_secrets 'AKIAIOSFODNN7EXAMPLE'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"[REDACTED]"* ]]
    [[ "$output" != *"AKIAIOSFODNN7EXAMPLE"* ]]
}

@test "redact_secrets pure function replaces Bearer token" {
    run bash -c "
        source '$SCRIPT'
        _autosave_redact_secrets 'Authorization: Bearer abcdef0123456789ABCDEFGHIJ'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"[REDACTED]"* ]]
    [[ "$output" != *"abcdef0123456789ABCDEFGHIJ"* ]]
}

# --- AC-EC10: ambiguous classification fails closed ------------------------

@test "skill in both Phase 1-3 and Phase 4 lists is treated as Phase 4 (no auto-save)" {
    # Mutate the in-memory _PHASE_4_SKILLS so a Phase 1-3 skill collides.
    run bash -c "
        export MEMORY_PATH='$FAKE_MEMORY'
        source '$SCRIPT'
        _PHASE_4_SKILLS=\"\$_PHASE_4_SKILLS gaia-product-brief\"
        _auto_save_memory gaia-product-brief
    "
    [ "$status" -eq 0 ]

    # Confirm Phase 4 won — no sidecar file produced.
    [ ! -f "$FAKE_MEMORY/analyst-sidecar/decision-log.md" ]
}

# --- Composer behaviour ---------------------------------------------------

@test "compose_summary emits header with skill name and date" {
    run bash -c "
        source '$SCRIPT'
        _autosave_compose_summary gaia-create-prd
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"gaia-create-prd Session Summary"* ]]
}
