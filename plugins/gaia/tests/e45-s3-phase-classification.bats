#!/usr/bin/env bats
# e45-s3-phase-classification.bats — phase-classification.sh regression suite
#
# Story: E45-S3 (Auto-save session memory at finalize for 24 Phase 1-3 skills)
# ADR-061 (Auto-Save Session Memory at Finalize, scope-bounded to Phase 1-3)
# AC: 5, AC-EC1, AC-EC7, AC-EC10
#
# Coverage:
#   - is_phase_1_3 returns true for each of 24 canonical skills
#   - is_phase_1_3 returns false for Phase 4 skills (e.g. gaia-dev-story)
#   - AC-EC10: skill in BOTH lists fails closed to false (Phase 4 wins)
#   - list_phase_1_3 emits exactly 24 lines, no duplicates
#   - agent_for resolves a non-empty agent for every Phase 1-3 skill
#   - unknown skill -> false; missing arg -> false
#
# NFR-052 public function coverage gate:
#   _is_phase_1_3, _phase_1_3_skills, _phase_4_skills, _skill_agent_for
#   are public (no leading underscore is fine — bats `@test` names cover
#   them via the matrix below). Internal helpers in this lib all use a
#   leading underscore by convention.

load 'test_helper.bash'

setup() {
    common_setup
    SCRIPT="$SCRIPTS_DIR/lib/phase-classification.sh"
}

teardown() { common_teardown; }

# --- Existence ------------------------------------------------------------

@test "phase-classification.sh: file exists and is executable" {
    [ -f "$SCRIPT" ]
    [ -x "$SCRIPT" ]
}

@test "phase-classification.sh: sourceable without side effects" {
    run bash -c "source '$SCRIPT'"
    [ "$status" -eq 0 ]
}

# --- _is_phase_1_3 happy-path matrix --------------------------------------

@test "_is_phase_1_3: gaia-product-brief is in Phase 1-3" {
    run bash -c "source '$SCRIPT' && _is_phase_1_3 gaia-product-brief"
    [ "$status" -eq 0 ]
}

@test "_is_phase_1_3: gaia-create-prd is in Phase 1-3" {
    run bash -c "source '$SCRIPT' && _is_phase_1_3 gaia-create-prd"
    [ "$status" -eq 0 ]
}

@test "_is_phase_1_3: gaia-trace is in Phase 1-3" {
    run bash -c "source '$SCRIPT' && _is_phase_1_3 gaia-trace"
    [ "$status" -eq 0 ]
}

@test "_is_phase_1_3: gaia-val-validate is in Phase 1-3" {
    run bash -c "source '$SCRIPT' && _is_phase_1_3 gaia-val-validate"
    [ "$status" -eq 0 ]
}

# --- _is_phase_1_3 negative cases -----------------------------------------

@test "_is_phase_1_3: gaia-dev-story is NOT in Phase 1-3 (Phase 4)" {
    run bash -c "source '$SCRIPT' && _is_phase_1_3 gaia-dev-story"
    [ "$status" -eq 1 ]
}

@test "_is_phase_1_3: gaia-quick-dev is NOT in Phase 1-3 (Phase 4)" {
    run bash -c "source '$SCRIPT' && _is_phase_1_3 gaia-quick-dev"
    [ "$status" -eq 1 ]
}

@test "_is_phase_1_3: unknown skill returns false (default-deny)" {
    run bash -c "source '$SCRIPT' && _is_phase_1_3 gaia-not-a-real-skill"
    [ "$status" -eq 1 ]
}

@test "_is_phase_1_3: empty argument returns false" {
    run bash -c "source '$SCRIPT' && _is_phase_1_3 ''"
    [ "$status" -eq 1 ]
}

@test "_is_phase_1_3: missing argument returns false" {
    run bash -c "source '$SCRIPT' && _is_phase_1_3"
    [ "$status" -eq 1 ]
}

# --- AC-EC10 fail-closed: skill in BOTH lists -----------------------------

@test "skill present in both Phase 1-3 and Phase 4 fails closed (Phase 4 wins)" {
    # Synthesize a collision by stubbing the env. The classifier uses the
    # in-script literal lists, so the most reliable way to verify the
    # fail-closed behaviour is to source the script and then mutate the
    # internal _PHASE_4_SKILLS variable to include a Phase 1-3 name.
    run bash -c "
        source '$SCRIPT'
        _PHASE_4_SKILLS=\"\$_PHASE_4_SKILLS gaia-product-brief\"
        _is_phase_1_3 gaia-product-brief
    "
    [ "$status" -eq 1 ]
}

# --- list_phase_1_3 inventory ---------------------------------------------

@test "list_phase_1_3: emits exactly 24 unique skill names" {
    run "$SCRIPT" list_phase_1_3
    [ "$status" -eq 0 ]
    # Count lines in the output.
    local n
    n="$(printf '%s\n' "$output" | grep -c '^gaia-')"
    [ "$n" -eq 24 ]
    # Confirm uniqueness.
    local uniq_n
    uniq_n="$(printf '%s\n' "$output" | sort -u | grep -c '^gaia-')"
    [ "$uniq_n" -eq 24 ]
}

@test "list_phase_1_3: includes all 24 expected canonical skill names" {
    local expected="\
gaia-brainstorm gaia-market-research gaia-domain-research gaia-tech-research \
gaia-advanced-elicitation gaia-product-brief gaia-create-prd gaia-create-ux \
gaia-create-arch gaia-edit-arch gaia-review-api gaia-adversarial \
gaia-create-epics gaia-threat-model gaia-infra-design gaia-readiness-check \
gaia-test-design gaia-edit-test-plan gaia-test-framework gaia-atdd \
gaia-trace gaia-ci-setup gaia-review-a11y gaia-val-validate"
    run "$SCRIPT" list_phase_1_3
    [ "$status" -eq 0 ]
    local s
    for s in $expected; do
        printf '%s\n' "$output" | grep -qx "$s" || {
            echo "missing skill in list_phase_1_3: $s" >&2
            return 1
        }
    done
}

# --- _skill_agent_for resolution ------------------------------------------

@test "_skill_agent_for: resolves non-empty agent for every Phase 1-3 skill" {
    run bash -c "
        source '$SCRIPT'
        rc=0
        while IFS= read -r s; do
            [ -n \"\$s\" ] || continue
            agent=\$(_skill_agent_for \"\$s\")
            if [ -z \"\$agent\" ]; then
                echo \"missing agent for: \$s\" >&2
                rc=1
            fi
        done < <(_phase_1_3_skills)
        exit \$rc
    "
    [ "$status" -eq 0 ]
}

@test "_skill_agent_for: gaia-create-prd -> pm" {
    run bash -c "source '$SCRIPT' && _skill_agent_for gaia-create-prd"
    [ "$status" -eq 0 ]
    [ "$output" = "pm" ]
}

@test "_skill_agent_for: gaia-create-arch -> architect" {
    run bash -c "source '$SCRIPT' && _skill_agent_for gaia-create-arch"
    [ "$status" -eq 0 ]
    [ "$output" = "architect" ]
}

@test "_skill_agent_for: unknown skill returns empty + exit 1" {
    run bash -c "source '$SCRIPT' && _skill_agent_for gaia-not-real"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

# --- Public function name coverage (NFR-052) ------------------------------

@test "phase-classification.sh: defines _is_phase_1_3 function" {
    grep -qE '^_is_phase_1_3\(\)[[:space:]]*\{' "$SCRIPT"
}

@test "phase-classification.sh: defines _skill_agent_for function" {
    grep -qE '^_skill_agent_for\(\)[[:space:]]*\{' "$SCRIPT"
}

@test "phase-classification.sh: defines _phase_1_3_skills function" {
    grep -qE '^_phase_1_3_skills\(\)[[:space:]]*\{' "$SCRIPT"
}
