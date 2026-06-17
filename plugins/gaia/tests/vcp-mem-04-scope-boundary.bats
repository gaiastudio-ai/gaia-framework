#!/usr/bin/env bats
# vcp-mem-04-scope-boundary.bats — ADR-061 / ADR-057 scope-boundary regression
#
# Story:        E45-S5 (ADR-061 / ADR-057 scope-boundary regression test)
# Test plan:    docs/test-artifacts/test-plan.md §11.46.9 VCP-MEM-04
# Traceability: VCP-MEM-04, FR-349, ADR-061, ADR-057, FR-YOLO-2(f)
# Architecture: §10.30.4 (yolo-mode.sh is_yolo precedence table)
#               §10.30.5 (Inheritance and memory-save boundary)
#               §10.31.5 (Auto-Save Session Memory at Finalize)
#
# Purpose
# -------
# Guard the scope boundary between ADR-061 (Phase 1-3 unconditional auto-save
# at finalize) and ADR-057 / FR-YOLO-2(f) (Phase 4 interactive memory-save
# prompt). A silent breach in either direction is the regression this file
# is built to catch:
#
#   * Phase 4 leak: auto-save fires for a Phase 4 skill, skipping the
#     mandatory `[y] Save / [n] Skip / [e] Edit` confirmation. ADR-057 §10.30.5
#     hard-gate broken.
#   * Phase 1-3 muting: auto-save no longer fires for a Phase 1-3 skill.
#     ADR-061 §10.31.5 contract broken.
#
# Coverage matrix (mapped to story ACs):
#   AC1 — Phase 4 skill defers to interactive prompt (no auto-save)
#   AC2 — `GAIA_CONTEXT=memory-save` forces `yolo-mode.sh is_yolo` exit 1
#   AC3 — CI workflow path filter covers finalize/yolo-mode.sh edits
#   AC4 — `GAIA_CONTEXT=memory-save` overrides `GAIA_YOLO_MODE=1` (context wins)
#   AC5 — Phase 1-3 skill auto-saves, no prompt (counterexample)
#
# Reproducibility — run locally with:
#   bats plugins/gaia/tests/vcp-mem-04-scope-boundary.bats
#
# All internal helpers carry the leading-underscore prefix (NFR-052) so the
# public-function coverage gate in run-with-coverage.sh treats them as
# implementation details, not contract surface.

load 'test_helper.bash'

setup() {
    common_setup
    YOLO_SCRIPT="$SCRIPTS_DIR/yolo-mode.sh"
    AUTOSAVE_SCRIPT="$SCRIPTS_DIR/lib/auto-save-memory.sh"
    PHASE_LIB="$SCRIPTS_DIR/lib/phase-classification.sh"
    PLUGIN_CI="$SCRIPTS_DIR/../../../.github/workflows/plugin-ci.yml"

    # Per-test fake _memory tree — never write to the real repo sidecars.
    FAKE_MEMORY="$TEST_TMP/_memory"
    mkdir -p "$FAKE_MEMORY"
    cat > "$FAKE_MEMORY/config.yaml" <<'YAML'
agents:
  pm:
    sidecar: pm-sidecar
  analyst:
    sidecar: analyst-sidecar
  architect:
    sidecar: architect-sidecar
  validator:
    sidecar: validator-sidecar
YAML
    export MEMORY_PATH="$FAKE_MEMORY"
}

teardown() {
    # Leave no residue under the developer's real _memory/.
    common_teardown
}

# Strip every YOLO-related env so each test starts from a clean baseline.
_clean_yolo_env() {
    unset GAIA_YOLO_FLAG GAIA_YOLO_MODE GAIA_YOLO_OVERRIDE GAIA_CONTEXT
}

# Run _auto_save_memory in a clean subshell with the fake memory path
# injected and capture stdout+stderr separately via bats' run.
_run_save() {
    run bash -c "
        export MEMORY_PATH='$FAKE_MEMORY'
        export AUTO_SAVE_LATENCY_THRESHOLD=10
        source '$AUTOSAVE_SCRIPT'
        _auto_save_memory $*
    "
}

# --- Existence + traceability anchors --------------------------------------

@test "regression test file references the load-bearing ADRs" {
    # Future readers must land on the right ADRs from the test header alone.
    grep -q "VCP-MEM-04"      "$BATS_TEST_FILENAME"
    grep -q "FR-349"          "$BATS_TEST_FILENAME"
    grep -q "ADR-061"         "$BATS_TEST_FILENAME"
    grep -q "ADR-057"         "$BATS_TEST_FILENAME"
    grep -q "FR-YOLO-2(f)"    "$BATS_TEST_FILENAME"
}

@test "yolo-mode.sh exists and is executable" {
    [ -f "$YOLO_SCRIPT" ]
    [ -x "$YOLO_SCRIPT" ]
}

@test "phase-classification.sh exists and is sourceable" {
    [ -f "$PHASE_LIB" ]
    run bash -c ". '$PHASE_LIB'"
    [ "$status" -eq 0 ]
}

# --- AC2 — GAIA_CONTEXT=memory-save forces is_yolo exit 1 ------------------

@test "GAIA_CONTEXT=memory-save forces is_yolo exit 1" {
    _clean_yolo_env
    run bash -c "GAIA_CONTEXT=memory-save '$YOLO_SCRIPT' is_yolo"
    [ "$status" -eq 1 ]
}

@test "GAIA_CONTEXT=memory-save still forces exit 1 with GAIA_YOLO_FLAG=1" {
    _clean_yolo_env
    run bash -c "GAIA_CONTEXT=memory-save GAIA_YOLO_FLAG=1 '$YOLO_SCRIPT' is_yolo"
    [ "$status" -eq 1 ]
}

# --- AC4 — GAIA_CONTEXT=memory-save overrides GAIA_YOLO_MODE=1 -------------

@test "GAIA_CONTEXT=memory-save overrides GAIA_YOLO_MODE=1 (context wins)" {
    _clean_yolo_env
    run bash -c "GAIA_CONTEXT=memory-save GAIA_YOLO_MODE=1 '$YOLO_SCRIPT' is_yolo"
    [ "$status" -eq 1 ]
}

@test "GAIA_CONTEXT=memory-save overrides every YOLO signal combined" {
    # All four signals set simultaneously — context still forces interactive.
    _clean_yolo_env
    run bash -c "GAIA_CONTEXT=memory-save GAIA_YOLO_MODE=1 GAIA_YOLO_FLAG=1 GAIA_YOLO_OVERRIDE=no '$YOLO_SCRIPT' is_yolo"
    [ "$status" -eq 1 ]
}

# --- Sanity counter-tests for the YOLO precedence table --------------------

@test "sanity: GAIA_YOLO_FLAG=1 alone returns exit 0 (YOLO active)" {
    # Confirms the test does not over-block — when GAIA_CONTEXT is unset,
    # YOLO activation works normally. Without this, AC2/AC4 could pass on a
    # globally-broken yolo-mode.sh that always returned 1.
    _clean_yolo_env
    run bash -c "GAIA_YOLO_FLAG=1 '$YOLO_SCRIPT' is_yolo"
    [ "$status" -eq 0 ]
}

@test "sanity: no env signals -> default exit 1 (interactive)" {
    _clean_yolo_env
    run bash -c "unset GAIA_YOLO_FLAG GAIA_YOLO_MODE GAIA_YOLO_OVERRIDE GAIA_CONTEXT; '$YOLO_SCRIPT' is_yolo"
    [ "$status" -eq 1 ]
}

# --- AC1 — Phase 4 skill defers to interactive prompt (no auto-save) -------

@test "_is_phase_1_3 gaia-dev-story returns false (Phase 4 wins)" {
    # /gaia-dev-story is the canonical Phase 4 skill cited by the story.
    run bash -c ". '$PHASE_LIB'; _is_phase_1_3 gaia-dev-story"
    [ "$status" -eq 1 ]
}

@test "_auto_save_memory short-circuits for Phase 4 skill (no write)" {
    # Per architecture §10.31.5 the auto-save library MUST defer to the
    # skill's interactive memory-save logic for Phase 4 skills. Verify by
    # observing that no sidecar file is written under MEMORY_PATH.
    _run_save gaia-dev-story
    [ "$status" -eq 0 ]
    # No decision-log.md anywhere under the fake memory tree.
    run find "$FAKE_MEMORY" -name 'decision-log.md' -print
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "_auto_save_memory Phase 4 short-circuit does not log a save" {
    # Auto-save Phase 4 short-circuit must be silent w.r.t. "saved" lines.
    # The function may emit a generic "auto-save:" diagnostic in some paths,
    # but it MUST NOT report a synchronous OR async save for Phase 4.
    _run_save gaia-dev-story
    [ "$status" -eq 0 ]
    ! echo "$output" | grep -qE 'session summary saved synchronously'
    ! echo "$output" | grep -qE 'saving asynchronously'
}

# --- AC5 — Phase 1-3 counterexample: auto-save fires, no prompt ------------

@test "_is_phase_1_3 gaia-create-prd returns true (Phase 1-3)" {
    run bash -c ". '$PHASE_LIB'; _is_phase_1_3 gaia-create-prd"
    [ "$status" -eq 0 ]
}

@test "Phase 1-3 skill auto-save fires without prompting" {
    # /gaia-create-prd is one of the 24 Phase 1-3 skills. Run auto-save and
    # assert (a) success exit, (b) no `[y]/[n]/[e]` interactive prompt
    # appeared in the captured output, and (c) the fake sidecar received a
    # decision-log.md entry. This is the AC5 counterexample that prevents a
    # false positive from a globally-disabled auto-save.
    _run_save gaia-create-prd
    [ "$status" -eq 0 ]

    # No interactive prompt string in captured output.
    ! echo "$output" | grep -qE '\[y\] Save'
    ! echo "$output" | grep -qE '\[n\] Skip'
    ! echo "$output" | grep -qE '\[e\] Edit'

    # A sidecar decision-log.md file was created — auto-save did fire.
    run find "$FAKE_MEMORY" -name 'decision-log.md' -print
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

# --- AC3 — CI workflow path filter covers the script surface ---------------

@test "plugin-ci.yml exists at the canonical path" {
    [ -f "$PLUGIN_CI" ]
}

@test "plugin-ci.yml path filter covers plugins/gaia/** (catches finalize/yolo-mode.sh edits)" {
    # The repo-wide path filter `plugins/gaia/**` automatically covers any
    # edit under plugins/gaia/scripts/, including finalize.sh (the future
    # per-skill shim) and yolo-mode.sh. The bats job reads the entire
    # plugins/gaia/tests/ tree via run-with-coverage.sh, so this regression
    # test is exercised on every PR that touches either script.
    grep -qE "'plugins/gaia/\*\*'" "$PLUGIN_CI"
}

@test "plugin-ci.yml runs the bats suite (regression test gets executed)" {
    # The bats job invokes run-with-coverage.sh which discovers every .bats
    # file under plugins/gaia/tests/ — including this one.
    grep -qE 'run-with-coverage\.sh' "$PLUGIN_CI"
}

@test "this regression file lives where run-with-coverage.sh discovers it" {
    [ -f "$SCRIPTS_DIR/../tests/vcp-mem-04-scope-boundary.bats" ]
}

# --- Determinism / cleanup -------------------------------------------------

@test "tmp sidecar is under BATS_TEST_TMPDIR (no real _memory pollution)" {
    # Guard against accidental writes to the developer's real _memory/.
    case "$FAKE_MEMORY" in
        "$BATS_TEST_TMPDIR"/*|/tmp/*|"$BATS_TMPDIR"/*) : ;;
        *) printf 'fake _memory escaped tmp tree: %s\n' "$FAKE_MEMORY" >&2; return 1 ;;
    esac
}
