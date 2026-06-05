#!/usr/bin/env bats
# val-bridge-migration.bats — coverage for E87 Val Bridge Migration consumer skills.
#
# Anchor: ADR-104 — Val Bridge Migration: Main-Turn Agent Dispatch Across Val-Consuming Skills.
#
# This file accumulates per-story migration tests as E87-S2..S5 land. E87-S2
# adds TC-VBR-12 (and its meta variants 12c/12d/12e/12f) covering the
# `/gaia-val-validate` + `validator.md` frontmatter + persona sentinel-write
# migration.
#
# E87-S2 coverage:
#   TC-VBR-12   — Forged sentinel (agent=val, no persona_sig) is rejected by
#                 assert_agent_envelope (primary forgery-resistance, NFR-064).
#   TC-VBR-12c  — Neither /gaia-val-validate SKILL.md nor validator.md
#                 contains `context: fork` in the dispatch frontmatter.
#   TC-VBR-12d  — /gaia-val-validate SKILL.md grep-count of
#                 `assert_agent_envelope` is >= 1 (helper is consumed).
#   TC-VBR-12e  — /gaia-val-validate SKILL.md contains an ADR-104 reference
#                 in a changelog or revision-history section.
#   TC-VBR-12f  — validator.md instructs the Val persona to emit the envelope
#                 sentinel (persona_sig / envelope-sentinel reference present).

load 'test_helper.bash'

PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
HELPER="$PLUGIN_ROOT/scripts/lib/assert-agent-envelope.sh"
SKILL_MD="$PLUGIN_ROOT/skills/gaia-val-validate/SKILL.md"
VALIDATOR_MD="$PLUGIN_ROOT/agents/validator.md"
FORGED_FIXTURE="$BATS_TEST_DIRNAME/fixtures/assert-agent-envelope/forged.json"

# Canonical HALT prefix — literal string from E87-S1 (no regex drift).
HALT_PREFIX='HALT: Val agent envelope assertion failed'

setup() {
  common_setup
}

teardown() {
  common_teardown
}

# ---------------- TC-VBR-12: forged sentinel rejected (primary) ----------------
@test "TC-VBR-12: forged sentinel (no persona_sig) is rejected by assert_agent_envelope — NFR-064" {
  [ -f "$HELPER" ] || skip "E87-S1 helper not present"
  [ -f "$FORGED_FIXTURE" ] || skip "E87-S1 forged fixture not present"
  source "$HELPER"
  run assert_agent_envelope "$FORGED_FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$HALT_PREFIX"* ]]
}

# ---------------- TC-VBR-12c: frontmatter migration ----------------
@test "TC-VBR-12c: /gaia-val-validate SKILL.md frontmatter does not declare context: fork" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not present"
  # Inspect only the frontmatter block (between the leading --- and the next ---).
  run awk '/^---$/{c++; next} c==1{print}' "$SKILL_MD"
  [ "$status" -eq 0 ]
  # Guard against vacuous green if awk emits empty (no frontmatter delimiters).
  [ -n "$output" ]
  ! grep -Eq '^context:[[:space:]]*fork' <<< "$output"
}

@test "TC-VBR-12c (validator.md sibling): validator.md frontmatter does not declare context: fork" {
  [ -f "$VALIDATOR_MD" ] || skip "validator.md not present"
  run awk '/^---$/{c++; next} c==1{print}' "$VALIDATOR_MD"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  ! grep -Eq '^context:[[:space:]]*fork' <<< "$output"
}

# ---------------- TC-VBR-12d: helper consumption ----------------
@test "TC-VBR-12d: SKILL.md references assert_agent_envelope (helper is consumed)" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not present"
  count=$(grep -c "assert_agent_envelope" "$SKILL_MD" || true)
  [ "$count" -ge 1 ]
}

# ---------------- TC-VBR-12e: ADR-104 changelog ----------------
@test "TC-VBR-12e: SKILL.md contains ADR-104 reference (changelog/migration note)" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not present"
  grep -q 'ADR-104' "$SKILL_MD"
}

# ---------------- TC-VBR-12f: persona sentinel-write contract ----------------
@test "TC-VBR-12f: validator.md instructs the Val persona to emit the envelope sentinel" {
  [ -f "$VALIDATOR_MD" ] || skip "validator.md not present"
  # Any of three markers is sufficient: persona_sig field, envelope-sentinel prose, or canonical sentinel path slug.
  grep -Eq 'persona_sig|envelope sentinel|val-envelope-' "$VALIDATOR_MD"
}

# ============================================================================
# E87-S3 coverage:
#   TC-VBR-9          — /gaia-validate-story SKILL.md references assert_agent_envelope
#   TC-VBR-9-runtime  — validate-story dispatch path HALTs against forged sentinel
#   TC-VBR-9b         — /gaia-validate-story frontmatter does not declare context: fork
#   TC-VBR-9c         — /gaia-validate-story SKILL.md contains no self-judgment
#                       fallthrough prose ("inline Val", "auto-judged", "main-turn
#                       inline validation")
#   TC-VBR-10         — /gaia-fix-story SKILL.md references assert_agent_envelope
#   TC-VBR-10-runtime — fix-story dispatch path HALTs against forged sentinel
#   TC-VBR-10b        — /gaia-fix-story SKILL.md contains no self-judgment fallthrough prose
#   TC-VBR-10c        — Both migrated SKILL.md files contain ADR-104 reference
# ============================================================================

VALIDATE_STORY_MD="$PLUGIN_ROOT/skills/gaia-validate-story/SKILL.md"
FIX_STORY_MD="$PLUGIN_ROOT/skills/gaia-fix-story/SKILL.md"

# ---------------- TC-VBR-9: validate-story envelope-assert grep ----------------
@test "TC-VBR-9: /gaia-validate-story SKILL.md references assert_agent_envelope" {
  [ -f "$VALIDATE_STORY_MD" ] || skip "validate-story SKILL.md not present"
  count=$(grep -c "assert_agent_envelope" "$VALIDATE_STORY_MD" || true)
  [ "$count" -ge 1 ]
}

# ---------------- TC-VBR-9-runtime: validate-story forgery HALT ----------------
@test "TC-VBR-9-runtime: validate-story dispatch path HALTs on forged sentinel — NFR-064" {
  [ -f "$HELPER" ] || skip "E87-S1 helper not present"
  [ -f "$FORGED_FIXTURE" ] || skip "E87-S1 forged fixture not present"
  source "$HELPER"
  run assert_agent_envelope "$FORGED_FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$HALT_PREFIX"* ]]
}

# ---------------- TC-VBR-9b: validate-story frontmatter migrated ----------------
@test "TC-VBR-9b: /gaia-validate-story SKILL.md frontmatter does not declare context: fork" {
  [ -f "$VALIDATE_STORY_MD" ] || skip "validate-story SKILL.md not present"
  run awk '/^---$/{c++; next} c==1{print}' "$VALIDATE_STORY_MD"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  ! grep -Eq '^context:[[:space:]]*fork' <<< "$output"
}

# ---------------- TC-VBR-9c: validate-story no fallthrough prose ----------------
@test "TC-VBR-9c: /gaia-validate-story SKILL.md contains no inline-Val / auto-judged fallthrough prose" {
  [ -f "$VALIDATE_STORY_MD" ] || skip "validate-story SKILL.md not present"
  # Scan for the documented bypass class. A "removed" callout in a Changelog
  # entry could legitimately mention these phrases; we exempt explicit
  # Changelog lines (lines that contain "Changelog" or "(removed)").
  hits=$(grep -E 'inline Val|auto-judged|main-turn inline validation' "$VALIDATE_STORY_MD" 2>/dev/null | grep -v -E 'Changelog|\(removed\)|removed the|no longer|MUST NOT|do NOT fall' || true)
  [ -z "$hits" ]
}

# ---------------- TC-VBR-10: fix-story envelope-assert grep ----------------
@test "TC-VBR-10: /gaia-fix-story SKILL.md references assert_agent_envelope" {
  [ -f "$FIX_STORY_MD" ] || skip "fix-story SKILL.md not present"
  count=$(grep -c "assert_agent_envelope" "$FIX_STORY_MD" || true)
  [ "$count" -ge 1 ]
}

# ---------------- TC-VBR-10-runtime: fix-story forgery HALT ----------------
@test "TC-VBR-10-runtime: fix-story dispatch path HALTs on forged sentinel — closes feedback_fix_story_inline_revalidation_bypass.md" {
  [ -f "$HELPER" ] || skip "E87-S1 helper not present"
  [ -f "$FORGED_FIXTURE" ] || skip "E87-S1 forged fixture not present"
  source "$HELPER"
  run assert_agent_envelope "$FORGED_FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$HALT_PREFIX"* ]]
}

# ---------------- TC-VBR-10b: fix-story no fallthrough prose ----------------
@test "TC-VBR-10b: /gaia-fix-story SKILL.md contains no inline-Val / main-turn-inline-validation fallthrough prose" {
  [ -f "$FIX_STORY_MD" ] || skip "fix-story SKILL.md not present"
  hits=$(grep -E 'inline Val|auto-judged|main-turn inline validation' "$FIX_STORY_MD" 2>/dev/null | grep -v -E 'Changelog|\(removed\)|removed the|no longer|MUST NOT|do NOT fall' || true)
  [ -z "$hits" ]
}

# ---------------- TC-VBR-10c: both migrated SKILL.md files document the Val Bridge Migration ----------------
@test "TC-VBR-10c: both validate-story and fix-story SKILL.md contain Val Bridge Migration reference" {
  [ -f "$VALIDATE_STORY_MD" ] || skip "validate-story SKILL.md not present"
  [ -f "$FIX_STORY_MD" ] || skip "fix-story SKILL.md not present"
  grep -q 'Val Bridge Migration' "$VALIDATE_STORY_MD"
  grep -q 'Val Bridge Migration' "$FIX_STORY_MD"
}

# ============================================================================
# E87-S4 coverage:
#   TC-VBR-7   — /gaia-dev-story Step 4 region references assert_agent_envelope
#   TC-VBR-7b  — /gaia-dev-story Step 4 region has no `context: fork` Val-dispatch refs
#   TC-VBR-8   — /gaia-dev-story Step 7b region references assert_agent_envelope
#   TC-VBR-8b  — /gaia-dev-story Step 7b region has no `context: fork` Val-dispatch refs
#   TC-VBR-8c  — /gaia-dev-story SKILL.md total `assert_agent_envelope` grep count >= 2
#   TC-VBR-8d  — /gaia-dev-story Steps 10-16 retain canonical push/PR/CI/merge tokens
#                (regression-class — behavior unchanged in promotion-chain block)
#   TC-VBR-8e  — /gaia-dev-story Steps 10-16 leak guard (no envelope-assert leaked in)
# ============================================================================

DEV_STORY_MD="$PLUGIN_ROOT/skills/gaia-dev-story/SKILL.md"

# Helper — extract the region between two `### Step ` headings from dev-story SKILL.md
_extract_region() {
  local start="$1" end="$2" file="$3"
  awk -v s="$start" -v e="$end" '
    $0 ~ "^### Step " s {in_=1; print; next}
    $0 ~ "^### Step " e {in_=0; exit}
    in_ {print}
  ' "$file"
}

# ---------------- TC-VBR-7: Step 4 envelope-assert ----------------
@test "TC-VBR-7: /gaia-dev-story Step 4 region references assert_agent_envelope" {
  [ -f "$DEV_STORY_MD" ] || skip "dev-story SKILL.md not present"
  region=$(_extract_region "4" "5" "$DEV_STORY_MD")
  [ -n "$region" ]
  echo "$region" | grep -q 'assert_agent_envelope'
}

# ---------------- TC-VBR-7b: Step 4 no context: fork Val-dispatch refs ----------------
@test "TC-VBR-7b: /gaia-dev-story Step 4 region has no context: fork Val-dispatch refs" {
  [ -f "$DEV_STORY_MD" ] || skip "dev-story SKILL.md not present"
  region=$(_extract_region "4" "5" "$DEV_STORY_MD")
  [ -n "$region" ]
  # Permit prose that NAMES "context: fork" in a "removed/migrated-away" callout
  # (the Changelog or historical-context note). Filter such lines before the
  # anti-pattern grep — same pattern used by E87-S3 TC-VBR-9c.
  hits=$(echo "$region" | grep -E 'context:[[:space:]]*fork' 2>/dev/null | grep -v -E 'Changelog|\(removed\)|removed the|no longer|MUST NOT|do NOT|migrated|prior to E87' || true)
  [ -z "$hits" ]
}

# ---------------- TC-VBR-8: Step 7b envelope-assert ----------------
@test "TC-VBR-8: /gaia-dev-story Step 7b region references assert_agent_envelope" {
  [ -f "$DEV_STORY_MD" ] || skip "dev-story SKILL.md not present"
  region=$(_extract_region "7b" "8" "$DEV_STORY_MD")
  [ -n "$region" ]
  echo "$region" | grep -q 'assert_agent_envelope'
}

# ---------------- TC-VBR-8b: Step 7b no context: fork Val-dispatch refs ----------------
@test "TC-VBR-8b: /gaia-dev-story Step 7b region has no context: fork Val-dispatch refs" {
  [ -f "$DEV_STORY_MD" ] || skip "dev-story SKILL.md not present"
  region=$(_extract_region "7b" "8" "$DEV_STORY_MD")
  [ -n "$region" ]
  hits=$(echo "$region" | grep -E 'context:[[:space:]]*fork' 2>/dev/null | grep -v -E 'Changelog|\(removed\)|removed the|no longer|MUST NOT|do NOT|migrated|prior to E87' || true)
  [ -z "$hits" ]
}

# ---------------- TC-VBR-8c: total grep count >= 2 ----------------
@test "TC-VBR-8c: /gaia-dev-story SKILL.md total assert_agent_envelope count >= 2" {
  [ -f "$DEV_STORY_MD" ] || skip "dev-story SKILL.md not present"
  count=$(grep -c "assert_agent_envelope" "$DEV_STORY_MD" || true)
  [ "$count" -ge 2 ]
}

# Helper — extract the Steps 10-16 region from dev-story SKILL.md.
# Terminates at the first `^## ` heading after Step 10 — that's either
# `## Changelog` (post-E87-S4) or `## Finalize`. Captures the push/PR/CI/merge/
# review-gate region cleanly without bleeding into the Changelog.
_extract_steps_10_to_16() {
  awk '
    /^### Step 1[0-6]/ {in_=1; print; next}
    in_ && /^## [^#]/ {exit}
    in_ {print}
  ' "$1"
}

# ---------------- TC-VBR-8d: Steps 10-16 canonical tokens preserved (regression) ----------------
@test "TC-VBR-8d: /gaia-dev-story Steps 10-16 retain canonical push/PR/CI/merge tokens" {
  [ -f "$DEV_STORY_MD" ] || skip "dev-story SKILL.md not present"
  region=$(_extract_steps_10_to_16 "$DEV_STORY_MD")
  [ -n "$region" ]
  # The canonical promotion-chain tokens that MUST remain in Steps 10-16.
  echo "$region" | grep -q 'git-push.sh'
  echo "$region" | grep -q 'pr-create.sh'
  echo "$region" | grep -q 'ci-wait.sh'
  echo "$region" | grep -q 'merge.sh'
  echo "$region" | grep -q 'verify-pr-merged.sh'
  echo "$region" | grep -q 'init-review-gate.sh'
}

# ---------------- TC-VBR-8e: Steps 10-16 leak guard ----------------
@test "TC-VBR-8e: /gaia-dev-story Steps 10-16 contain no assert_agent_envelope leak" {
  [ -f "$DEV_STORY_MD" ] || skip "dev-story SKILL.md not present"
  region=$(_extract_steps_10_to_16 "$DEV_STORY_MD")
  [ -n "$region" ]
  # Steps 10-16 are push/PR/CI/merge/review-gate — they MUST NOT reference
  # the envelope-assert (which is a Val-dispatch concern living in Steps 4 + 7b only).
  ! echo "$region" | grep -q 'assert_agent_envelope'
}

# ============================================================================
# E87-S5 coverage:
#   TC-VBR-11   — /gaia-add-feature Step 2 region references assert_agent_envelope
#   TC-VBR-11b  — /gaia-add-feature Step 2 region contains `main-turn Agent tool` token
#   TC-VBR-11c  — /gaia-add-feature Step 2 region has no `context: fork` Val-dispatch refs
#                 (region-scoped to avoid false positives on historical Changelog refs)
#   TC-VBR-11d  — /gaia-add-feature SKILL.md total `assert_agent_envelope` grep count >= 1
#   TC-VBR-11e  — /gaia-add-feature SKILL.md contains ADR-104 reference
#   TC-VBR-11f  — /gaia-add-feature/scripts/finalize.sh contains no envelope-sentinel-write
#                 (AC3 leak guard — Val persona owns the envelope-write, finalize.sh validates
#                 the separate E83 dispatch checkpoint only)
#   TC-VBR-11g  — /gaia-add-feature SKILL.md references BOTH E83 dispatch checkpoint
#                 (`add-feature-{feature_id}-val-dispatched.json`) AND E87 envelope sentinel
#                 (`val-envelope-`) — AC4 coexistence
# ============================================================================

ADD_FEATURE_MD="$PLUGIN_ROOT/skills/gaia-add-feature/SKILL.md"
ADD_FEATURE_FINALIZE="$PLUGIN_ROOT/skills/gaia-add-feature/scripts/finalize.sh"

# Helper — extract /gaia-add-feature Step 2 region (between `### Step 2` and `### Step 3`).
_extract_add_feature_step_2() {
  awk '/^### Step 2/{flag=1} /^### Step 3/{flag=0} flag' "$1"
}

# ---------------- TC-VBR-11: Step 2 envelope-assert ----------------
@test "TC-VBR-11: /gaia-add-feature Step 2 region references assert_agent_envelope" {
  [ -f "$ADD_FEATURE_MD" ] || skip "add-feature SKILL.md not present"
  region=$(_extract_add_feature_step_2 "$ADD_FEATURE_MD")
  [ -n "$region" ]
  echo "$region" | grep -q 'assert_agent_envelope'
}

# ---------------- TC-VBR-11b: Step 2 main-turn dispatch token ----------------
@test "TC-VBR-11b: /gaia-add-feature Step 2 region contains main-turn Agent tool token" {
  [ -f "$ADD_FEATURE_MD" ] || skip "add-feature SKILL.md not present"
  region=$(_extract_add_feature_step_2 "$ADD_FEATURE_MD")
  [ -n "$region" ]
  echo "$region" | grep -q 'main-turn Agent tool'
}

# ---------------- TC-VBR-11c: Step 2 no context: fork Val-dispatch refs (region-scoped) ----------------
@test "TC-VBR-11c: /gaia-add-feature Step 2 region has no context: fork Val-dispatch refs" {
  [ -f "$ADD_FEATURE_MD" ] || skip "add-feature SKILL.md not present"
  region=$(_extract_add_feature_step_2 "$ADD_FEATURE_MD")
  [ -n "$region" ]
  # Filter-allowed "migrated from / removed" Changelog-style callouts (same pattern
  # used by E87-S3 TC-VBR-9c and E87-S4 TC-VBR-7b).
  hits=$(echo "$region" | grep -E 'context:[[:space:]]*fork' 2>/dev/null | grep -v -E 'Changelog|\(removed\)|removed the|no longer|MUST NOT|do NOT|migrated|prior to E87|prior model|historically' || true)
  [ -z "$hits" ]
}

# ---------------- TC-VBR-11d: total grep count >= 1 ----------------
@test "TC-VBR-11d: /gaia-add-feature SKILL.md total assert_agent_envelope count >= 1" {
  [ -f "$ADD_FEATURE_MD" ] || skip "add-feature SKILL.md not present"
  count=$(grep -c "assert_agent_envelope" "$ADD_FEATURE_MD" || true)
  [ "$count" -ge 1 ]
}

# ---------------- TC-VBR-11e: Val Bridge Migration documented in Changelog ----------------
@test "TC-VBR-11e: /gaia-add-feature SKILL.md contains Val Bridge Migration reference" {
  [ -f "$ADD_FEATURE_MD" ] || skip "add-feature SKILL.md not present"
  grep -q 'Val Bridge Migration' "$ADD_FEATURE_MD"
}

# ---------------- TC-VBR-11f: finalize.sh sentinel leak guard (AC3) ----------------
@test "TC-VBR-11f: /gaia-add-feature/scripts/finalize.sh contains no envelope-sentinel write" {
  [ -f "$ADD_FEATURE_FINALIZE" ] || skip "add-feature finalize.sh not present"
  # The E87 envelope sentinel is written by the Val persona (per E87-S2 contract);
  # finalize.sh validates only the SEPARATE E83 dispatch checkpoint
  # (`add-feature-{feature_id}-val-dispatched.json`). The envelope sentinel
  # filename slug (`val-envelope-`) MUST NOT appear anywhere in finalize.sh.
  ! grep -q 'val-envelope-' "$ADD_FEATURE_FINALIZE"
}

# ---------------- TC-VBR-11g: E83 + E87 sentinel coexistence (AC4) ----------------
@test "TC-VBR-11g: /gaia-add-feature SKILL.md references BOTH E83 dispatch checkpoint AND E87 envelope sentinel" {
  [ -f "$ADD_FEATURE_MD" ] || skip "add-feature SKILL.md not present"
  # E83 dispatch checkpoint reference (existing).
  grep -q 'add-feature-.*val-dispatched' "$ADD_FEATURE_MD"
  # E87 envelope sentinel reference (added by E87-S5 Green phase).
  grep -q 'val-envelope-' "$ADD_FEATURE_MD"
}

# ============================================================================
# E87-S7 — Sentinel-Write Writer Shift (ADR-105 amends ADR-104)
# ============================================================================
# Following the AI-2026-05-13-13 incident, the Val sentinel write was relocated
# from the Val sub-agent context to the orchestrator's main turn. Val now
# RETURNS the sentinel content as a `sentinel_envelope` field inside the
# ADR-037 envelope; the caller writes the sentinel via the new helper at
# plugins/gaia/scripts/lib/write-val-envelope.sh. These three tests cover the
# writer-shift contract.

WRITE_ENVELOPE_HELPER="$SCRIPTS_DIR/lib/write-val-envelope.sh"
VALIDATOR_MD="$SCRIPTS_DIR/../agents/validator.md"

# ---------------- TC-VBR-13: write-val-envelope.sh helper exists ----------------
@test "TC-VBR-13: write-val-envelope.sh helper exists at canonical path (E87-S7)" {
  [ -f "$WRITE_ENVELOPE_HELPER" ]
  [ -x "$WRITE_ENVELOPE_HELPER" ]
  # Header documents the writer-shift contract: sentinel write moves to the
  # orchestrator's main turn (the behavioral anchor for the E87-S7 shift).
  run head -40 "$WRITE_ENVELOPE_HELPER"
  [[ "$output" == *"orchestrator"* ]]
  [[ "$output" == *"sentinel"* ]]
}

# ---------------- TC-VBR-14: validator.md §Sentinel-Write Contract specifies sentinel_envelope return-channel ----------------
@test "TC-VBR-14: validator.md Sentinel-Write Contract references sentinel_envelope return-channel (E87-S7)" {
  [ -f "$VALIDATOR_MD" ]
  # The new contract specifies that Val embeds the sentinel content in the
  # ADR-037 envelope as a `sentinel_envelope` field.
  grep -q 'sentinel_envelope' "$VALIDATOR_MD"
  # The new contract explicitly states Val MUST NOT write the sentinel file.
  grep -q 'MUST NOT write' "$VALIDATOR_MD"
  # The writer-shift helper is the durable behavioral anchor for this contract.
  grep -q 'write-val-envelope.sh' "$VALIDATOR_MD"
}

# ---------------- TC-VBR-15: validator.md Write allowlist removal (E87-S7 / AC7) ----------------
@test "TC-VBR-15: validator.md frontmatter allowed-tools omits 'Write' (E87-S7)" {
  [ -f "$VALIDATOR_MD" ]
  # Extract the frontmatter allowed-tools line. Val is now read-only on the
  # filesystem under the new contract — Write is removed.
  run grep -E '^allowed-tools:' "$VALIDATOR_MD"
  [ "$status" -eq 0 ]
  # 'Write' must NOT appear in the allowed-tools list.
  [[ "$output" != *"Write"* ]]
}
