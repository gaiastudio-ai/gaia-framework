#!/usr/bin/env bats
# e45-s3-wire-in-coverage.bats — static scan: every Phase 1-3 finalize.sh
# invokes the auto-save helper.
#
# Story: E45-S3 (Auto-save session memory at finalize for 24 Phase 1-3 skills)
# AC5  — All 24 skill finalize paths invoke auto-save targeting the correct
#        agent sidecar.
# AC-EC1 — Phase 4 finalize.sh must NOT contain the same wire-in (their
#        memory-save is interactive per ADR-057). gaia-dev-story is the
#        canonical Phase 4 anchor for this regression check.
# VCP-MEM-06 — bats/shell static scan across the 24 skills.

load 'test_helper.bash'

setup() {
    common_setup
    PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SKILLS_DIR="$PLUGIN_DIR/skills"
}

teardown() { common_teardown; }

# Canonical Phase 1-3 skill list (mirrors phase-classification.sh).
phase_1_3_skills() {
    cat <<'EOF'
gaia-brainstorm
gaia-market-research
gaia-domain-research
gaia-tech-research
gaia-advanced-elicitation
gaia-product-brief
gaia-create-prd
gaia-create-ux
gaia-create-arch
gaia-edit-arch
gaia-review-api
gaia-adversarial
gaia-create-epics
gaia-threat-model
gaia-infra-design
gaia-readiness-check
gaia-test-design
gaia-edit-test-plan
gaia-test-framework
gaia-atdd
gaia-trace
gaia-ci-setup
gaia-review-a11y
gaia-val-validate
EOF
}

@test "AC5: every Phase 1-3 skill has a finalize.sh" {
    local missing=()
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        local f="$SKILLS_DIR/$s/scripts/finalize.sh"
        if [ ! -f "$f" ]; then
            missing+=("$s")
        fi
    done < <(phase_1_3_skills)
    if [ "${#missing[@]}" -gt 0 ]; then
        printf 'missing finalize.sh:\n' >&2
        printf '  - %s\n' "${missing[@]}" >&2
        return 1
    fi
}

@test "AC5: every Phase 1-3 finalize.sh sources auto-save-memory.sh" {
    local missing=()
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        local f="$SKILLS_DIR/$s/scripts/finalize.sh"
        [ -f "$f" ] || continue
        if ! grep -q 'auto-save-memory.sh' "$f"; then
            missing+=("$s")
        fi
    done < <(phase_1_3_skills)
    if [ "${#missing[@]}" -gt 0 ]; then
        printf 'finalize.sh missing auto-save-memory wire-in:\n' >&2
        printf '  - %s\n' "${missing[@]}" >&2
        return 1
    fi
}

@test "AC5: every Phase 1-3 finalize.sh calls _auto_save_memory" {
    local missing=()
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        local f="$SKILLS_DIR/$s/scripts/finalize.sh"
        [ -f "$f" ] || continue
        if ! grep -q '_auto_save_memory' "$f"; then
            missing+=("$s")
        fi
    done < <(phase_1_3_skills)
    if [ "${#missing[@]}" -gt 0 ]; then
        printf 'finalize.sh missing _auto_save_memory call:\n' >&2
        printf '  - %s\n' "${missing[@]}" >&2
        return 1
    fi
}

@test "AC5: every Phase 1-3 finalize.sh references the E45-S3 marker" {
    # Canonical comment so future audits can grep one token.
    # The durable anchor is the section heading 'Auto-save session memory'
    # present in every wired finalize.sh (the bookkeeping ID was removed by
    # a scrub pass; the behavioral phrase is the stable substitute).
    local missing=()
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        local f="$SKILLS_DIR/$s/scripts/finalize.sh"
        [ -f "$f" ] || continue
        if ! grep -q 'Auto-save session memory' "$f"; then
            missing+=("$s")
        fi
    done < <(phase_1_3_skills)
    if [ "${#missing[@]}" -gt 0 ]; then
        printf 'finalize.sh missing auto-save section marker:\n' >&2
        printf '  - %s\n' "${missing[@]}" >&2
        return 1
    fi
}

@test "AC5: count of wired Phase 1-3 finalize.sh equals 24" {
    local count=0
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        local f="$SKILLS_DIR/$s/scripts/finalize.sh"
        if [ -f "$f" ] && grep -q 'Auto-save session memory' "$f" && grep -q '_auto_save_memory' "$f"; then
            count=$(( count + 1 ))
        fi
    done < <(phase_1_3_skills)
    [ "$count" -eq 24 ]
}

@test "AC-EC1: gaia-dev-story finalize.sh does NOT auto-save (Phase 4)" {
    # The Phase 4 wire-in MUST NOT be present in dev-story's finalize.sh.
    # The dev-story finalize is allowed to call the helper if it ever
    # extends the contract — but as of E45-S3 it must not. The
    # auto-save-memory helper itself short-circuits Phase 4 even if
    # called, so this test reads the file for the absence of the
    # E45-S3 marker.
    local f="$SKILLS_DIR/gaia-dev-story/scripts/finalize.sh"
    if [ -f "$f" ]; then
        if grep -q 'E45-S3' "$f"; then
            echo "gaia-dev-story finalize.sh unexpectedly contains the E45-S3 marker" >&2
            return 1
        fi
    fi
}

@test "AC-EC10: phase-classification.sh treats Phase 4 as fail-closed" {
    # Cross-check via the helper directly — gaia-dev-story is in the Phase
    # 4 set and must return false from _is_phase_1_3 even after mutation.
    local script="$SKILLS_DIR/../scripts/lib/phase-classification.sh"
    run bash -c "
        source '$script'
        _PHASE_1_3_SKILLS=\"\$_PHASE_1_3_SKILLS gaia-dev-story\"
        _is_phase_1_3 gaia-dev-story
    "
    [ "$status" -eq 1 ]
}
