#!/usr/bin/env bats
# gaia-sprint-review-mode-a-anti-pattern.bats — durable CI regression guard.
#
# Story: E93-S3 — /gaia-sprint-review skill scaffold (Mode A) + Track A Val
#                 dispatch + composite verdict + UNVERIFIED bypass.
# Anchor: ADR-108 D3 (main-turn Mode A invariant), NFR-067 (AskUserQuestion
#         reachability), T-SGR-6 (Mode A bypass mitigation).
#
# Coverage:
#   TC-SGR-43      — Anti-pattern bats: no `context: fork` directive, no
#                    stdout sentinels (`<<YIELD-STOP`, `<<TURN-END`), no
#                    direct `yq -i` against sprint-status.yaml, AskUserQuestion
#                    invoked at the mandatory boundaries.
#   TC-SGR-24      — Main-turn Mode A orchestration class assertion (skill
#                    SKILL.md frontmatter carries orchestration_class:
#                    heavy-procedural).
#
# Filter-allow regex precedent: val-bridge-anti-pattern.bats (E87-S6).
# Anti-pattern scan idiom precedent: gaia-shell-idioms (awk state-machine
# extraction NOT awk-range pattern).

load 'test_helper.bash'

PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SKILL_DIR="$PLUGIN_ROOT/skills/gaia-sprint-review"
SKILL_MD="$SKILL_DIR/SKILL.md"

# Filter-allow regex — exempts lines that legitimately reference the
# forbidden patterns: Changelog entries, migration-callout prose,
# MUST-NOT prose, anti-pattern documentation. Mirrors the
# val-bridge-anti-pattern.bats pattern (E87-S6).
FILTER_ALLOW='Changelog|MUST NOT|do NOT|forbidden|legacy directive|anti-pattern|^- \*\*[0-9]{4}-[0-9]{2}-[0-9]{2}|migration|historical|prior to'

setup() { common_setup; }
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# TC-SGR-43: forbidden patterns — `context: fork` / stdout sentinels /
# direct yq -i against sprint-status.yaml
# ---------------------------------------------------------------------------

@test "anti-pattern: SKILL.md does not contain literal 'context: fork' directive (filter-allowed)" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not yet implemented (TDD red)"
  # Scan SKILL.md for `context: fork` outside filter-allow lines.
  hits=$(grep -nE 'context:[[:space:]]*fork' "$SKILL_MD" 2>/dev/null | grep -vE "$FILTER_ALLOW" || true)
  [ -z "$hits" ] || {
    echo "Found forbidden 'context: fork' references:"
    echo "$hits"
    return 1
  }
}

@test "anti-pattern: SKILL.md does not contain stdout-sentinel tokens (<<YIELD-STOP, <<TURN-END)" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not yet implemented (TDD red)"
  hits=$(grep -nE '<<YIELD-STOP|<<TURN-END' "$SKILL_MD" 2>/dev/null | grep -vE "$FILTER_ALLOW" || true)
  [ -z "$hits" ] || {
    echo "Found forbidden stdout-sentinel tokens:"
    echo "$hits"
    return 1
  }
}

@test "anti-pattern: scripts/ directory has no direct 'yq -i' against sprint-status.yaml" {
  [ -d "$SKILL_DIR/scripts" ] || skip "scripts/ not yet implemented (TDD red)"
  hits=$(grep -rnE 'yq[[:space:]]+-i' "$SKILL_DIR/scripts" 2>/dev/null | grep sprint-status.yaml | grep -vE "$FILTER_ALLOW" || true)
  [ -z "$hits" ] || {
    echo "Found forbidden direct yq -i against sprint-status.yaml (boundary-write bypass per NFR-071/T-SGR-7):"
    echo "$hits"
    return 1
  }
}

# ---------------------------------------------------------------------------
# TC-SGR-43: required patterns — AskUserQuestion invocations at the
# 3 mandatory boundaries (Step 3 pre-Val, Step 4 per-goal Track B,
# Step 8 PM explanation for UNVERIFIED bypass)
# ---------------------------------------------------------------------------

@test "anti-pattern: SKILL.md mentions AskUserQuestion at least 3 times (3 mandatory boundaries)" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not yet implemented (TDD red)"
  count=$(grep -cE 'AskUserQuestion' "$SKILL_MD")
  [ "$count" -ge 3 ] || {
    echo "AskUserQuestion appears only $count time(s); expected >= 3 (Step 3 pre-Val, Step 4 per-goal, Step 8 PM explanation)"
    return 1
  }
}

# ---------------------------------------------------------------------------
# TC-SGR-24: main-turn Mode A orchestration class assertion
# ---------------------------------------------------------------------------

@test "main-turn Mode A: SKILL.md frontmatter declares orchestration_class: heavy-procedural" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not yet implemented (TDD red)"
  # Extract frontmatter block (between first two --- lines) via awk state-machine.
  frontmatter=$(awk '/^---$/{f++; next} f==1{print}' "$SKILL_MD")
  echo "$frontmatter" | grep -qE '^orchestration_class:[[:space:]]*heavy-procedural[[:space:]]*$' || {
    echo "SKILL.md frontmatter missing or mis-set orchestration_class. Expected 'orchestration_class: heavy-procedural'."
    echo "Frontmatter content:"
    echo "$frontmatter"
    return 1
  }
}

# ---------------------------------------------------------------------------
# TC-SGR-43 supplemental: SKILL.md mentions the canonical Val-dispatch
# pattern (Agent tool + write-val-envelope + assert_agent_envelope) at the
# Step 3 prose level. Verifies the ADR-105 writer-shift contract is
# documented per R7.
# ---------------------------------------------------------------------------

@test "anti-pattern: SKILL.md references write-val-envelope.sh + assert_agent_envelope" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not yet implemented (TDD red)"
  grep -qE 'write-val-envelope\.sh' "$SKILL_MD" || {
    echo "SKILL.md does not reference write-val-envelope.sh (ADR-105 orchestrator-side writer contract — R7)"
    return 1
  }
  grep -qE 'assert_agent_envelope|assert-agent-envelope\.sh' "$SKILL_MD" || {
    echo "SKILL.md does not reference assert_agent_envelope (ADR-104 envelope-assert contract)"
    return 1
  }
}
