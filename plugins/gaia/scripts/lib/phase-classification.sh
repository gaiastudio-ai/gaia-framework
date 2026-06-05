#!/usr/bin/env bash
# phase-classification.sh — Canonical Phase 1-3 skill classification
#
# Purpose
# -------
# Single source of truth for the 24 Phase 1-3 skill names that auto-save
# session memory at finalize. Used by `auto-save-memory.sh` and the
# per-skill `finalize.sh` shims to decide whether auto-save fires
# or whether memory-save defers to skill-owned interactive logic.
#
# Hard rule (fail-closed):
#   If a skill name appears in BOTH the Phase 1-3 set and the Phase 4 set,
#   Phase 4 wins — `_is_phase_1_3` returns 1 (false). The interactive prompt
#   is preserved. Phase 1-3 scope boundary is protected.
#
# Public predicate:
#   _is_phase_1_3 <skill-name>   exit 0 = yes, exit 1 = no
#
# Helper:
#   _phase_1_3_skills            prints the 24 canonical skill names, one per line
#
# Shellcheck: clean.

# --- Canonical Phase 1-3 skill set (24 entries) ----------------------------
#
# Derived from: architecture.md §10.31 (V2 Skill Completeness and Parity).
#
# This list is intentionally a flat space-separated string so the single
# declaration is trivial to grep, lint, and diff.
_PHASE_1_3_SKILLS="\
gaia-brainstorm \
gaia-market-research \
gaia-domain-research \
gaia-tech-research \
gaia-advanced-elicitation \
gaia-product-brief \
gaia-create-prd \
gaia-create-ux \
gaia-create-arch \
gaia-edit-arch \
gaia-review-api \
gaia-adversarial \
gaia-create-epics \
gaia-threat-model \
gaia-infra-design \
gaia-readiness-check \
gaia-test-design \
gaia-edit-test-plan \
gaia-test-framework \
gaia-atdd \
gaia-trace \
gaia-ci-setup \
gaia-review-a11y \
gaia-val-validate"

# --- Phase 4 skill set (subset; explicitly NOT auto-save) ------------------
#
# Phase 4 (implementation/build) skills retain the interactive memory-save
# prompt. Listing them here is the fail-closed safety net: if a skill is
# mistakenly added to BOTH sets, the Phase 4 entry wins.
#
# This is not exhaustive — it lists the Phase 4 skills that are most likely
# to collide with the Phase 1-3 set. The unconditional logic in
# _is_phase_1_3 returns false for any unknown skill, so omissions here only
# affect explicit collision detection, not safety.
_PHASE_4_SKILLS="\
gaia-dev-story \
gaia-quick-dev \
gaia-quick-spec \
gaia-fix-story \
gaia-validate-story \
gaia-code-review \
gaia-test-review \
gaia-test-automate \
gaia-qa-tests \
gaia-security-review \
gaia-performance-review"

# _phase_1_3_skills — print the 24 canonical Phase 1-3 skill names, one per
# line. Used by audits, lints, and the bats coverage gate.
_phase_1_3_skills() {
    printf '%s\n' $_PHASE_1_3_SKILLS
}

# _phase_4_skills — print the registered Phase 4 skill names, one per line.
_phase_4_skills() {
    printf '%s\n' $_PHASE_4_SKILLS
}

# _is_phase_1_3 <skill-name>
# ---------------------------
# Predicate: returns 0 (true) if the supplied skill name is in the Phase 1-3
# set AND is NOT in the Phase 4 set. Returns 1 (false) otherwise.
#
# Fail-closed semantics:
#   - skill-name in Phase 1-3 only           -> exit 0 (auto-save)
#   - skill-name in both Phase 1-3 and Phase 4 -> exit 1 (interactive — Phase 4 wins)
#   - skill-name in Phase 4 only             -> exit 1 (interactive)
#   - skill-name unknown                     -> exit 1 (default-deny)
#
# Empty / missing argument is treated as unknown — exit 1.
_is_phase_1_3() {
    local skill="${1:-}"
    [ -n "$skill" ] || return 1

    # Step 1 — Phase 4 always wins. If the name is on the Phase 4 list,
    # short-circuit to exit 1 even if it also appears in Phase 1-3.
    local s
    for s in $_PHASE_4_SKILLS; do
        if [ "$s" = "$skill" ]; then
            return 1
        fi
    done

    # Step 2 — Phase 1-3 membership.
    for s in $_PHASE_1_3_SKILLS; do
        if [ "$s" = "$skill" ]; then
            return 0
        fi
    done

    # Step 3 — Unknown skill: default-deny.
    return 1
}

# --- Skill -> agent map for sidecar resolution -----------------------------
#
# Each Phase 1-3 skill maps to the agent sidecar where its session summary
# is written. Agent ids match the agents config keys.
#
# Format: one "skill:agent" pair per line in a here-doc. Lookup is a linear
# scan — 24 entries, never hot-path.

_skill_agent_for() {
    local skill="${1:-}"
    [ -n "$skill" ] || { printf ''; return 1; }
    case "$skill" in
        gaia-brainstorm)            printf 'analyst' ;;
        gaia-market-research)       printf 'analyst' ;;
        gaia-domain-research)       printf 'analyst' ;;
        gaia-tech-research)         printf 'analyst' ;;
        gaia-advanced-elicitation)  printf 'analyst' ;;
        gaia-product-brief)         printf 'analyst' ;;
        gaia-create-prd)            printf 'pm' ;;
        gaia-create-ux)             printf 'ux-designer' ;;
        gaia-create-arch)           printf 'architect' ;;
        gaia-edit-arch)             printf 'architect' ;;
        gaia-review-api)            printf 'architect' ;;
        gaia-adversarial)           printf 'validator' ;;
        gaia-create-epics)          printf 'architect' ;;
        gaia-threat-model)          printf 'security' ;;
        gaia-infra-design)          printf 'devops' ;;
        gaia-readiness-check)       printf 'architect' ;;
        gaia-test-design)           printf 'test-architect' ;;
        gaia-edit-test-plan)        printf 'test-architect' ;;
        gaia-test-framework)        printf 'test-architect' ;;
        gaia-atdd)                  printf 'test-architect' ;;
        gaia-trace)                 printf 'test-architect' ;;
        gaia-ci-setup)              printf 'devops' ;;
        gaia-review-a11y)           printf 'ux-designer' ;;
        gaia-val-validate)          printf 'validator' ;;
        *)                          printf ''; return 1 ;;
    esac
    return 0
}

# --- Direct invocation -----------------------------------------------------
# Allows scripts to call `phase-classification.sh is_phase_1_3 <skill>` and
# read $? without sourcing.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    case "${1:-}" in
        is_phase_1_3)
            shift
            _is_phase_1_3 "$@"
            exit $?
            ;;
        list_phase_1_3)
            _phase_1_3_skills
            exit 0
            ;;
        list_phase_4)
            _phase_4_skills
            exit 0
            ;;
        agent_for)
            shift
            _skill_agent_for "$@"
            rc=$?
            printf '\n'
            exit $rc
            ;;
        --help|-h|"")
            cat <<'EOF'
phase-classification.sh — Canonical Phase 1-3 classification

Usage:
  source phase-classification.sh && _is_phase_1_3 <skill>      # library form
  phase-classification.sh is_phase_1_3 <skill>                 # subcommand form
  phase-classification.sh list_phase_1_3                       # print 24 names
  phase-classification.sh list_phase_4                         # print Phase 4 set
  phase-classification.sh agent_for <skill>                    # print agent id
  phase-classification.sh --help

Exit codes:
  0  is_phase_1_3 -> true
  1  is_phase_1_3 -> false (or unknown skill, or in Phase 4)
EOF
            exit 0
            ;;
        *)
            echo "phase-classification.sh: unknown subcommand '$1'. Try '--help'." >&2
            exit 2
            ;;
    esac
fi
