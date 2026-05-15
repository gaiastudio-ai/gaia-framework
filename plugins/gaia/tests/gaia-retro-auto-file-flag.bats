#!/usr/bin/env bats
# gaia-retro-auto-file-flag.bats — E92-S5 / AI-84 / AI-RETRO-S46-3.
#
# Tests the opt-in `--auto-file` flag wiring on /gaia-retro. The full
# cross-skill subagent dispatch path (TC-RAF-1, TC-RAF-2 in the story) is
# substrate-gap-blocked per `feedback_askuserquestion_forked_skill_gap`
# and `feedback_plugin_context_fork_broken` — those test cases are deferred
# to a follow-up story once the upstream substrate fix closes (Claude Code
# issue #49559).
#
# This file lands the partial AC4 coverage:
#   TC-RAF-3: v1 schema (`classification:` not `type:`) entries are never
#             auto-filed — v1 entries are read-only per ADR-086 dual-schema.
#   TC-RAF-4: without --auto-file, behavior is byte-identical to the
#             pre-E92-S5 default (no auto-file traces in the retro artifact).
#
# Plus structural assertions on the SKILL.md wiring:
#   AC3-1: argument-hint advertises [--auto-file?].
#   AC3-2: Step 5b begin marker present in SKILL.md.
#   AC6-1: Changelog references E92-S5 / AI-84.
#   AC6-2: ## Refs section names the design note.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

SKILL_MD="$BATS_TEST_DIRNAME/../skills/gaia-retro/SKILL.md"
DESIGN_NOTE="$BATS_TEST_DIRNAME/../../../../docs/planning-artifacts/retro-auto-file-design.md"

setup() { common_setup; }
teardown() { common_teardown; }

# ---------- AC3 / AC6: SKILL.md wiring ----------

@test "AC3-1: SKILL.md argument-hint advertises [--auto-file?]" {
  run grep -F 'argument-hint: "[sprint-id?] [--auto-file?]"' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC3-2: SKILL.md introduces Step 5b auto-file branch" {
  run grep -F '#### Step 5b --- Optional auto-file pass (E92-S5, opt-in via `--auto-file`)' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC3-3: SKILL.md Step 5b documents the AC-EC7 invariant (auto-file does NOT bypass gate)" {
  run grep -F 'auto-spawn the gate' "$SKILL_MD"
  [ "$status" -eq 0 ]
  run grep -F 'NOT' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC3-4: SKILL.md Step 5b enumerates the eligible types per the design note" {
  run grep -F '`feature`, `new-story`, `bug`, `enhancement`, `automation`' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC6-1: SKILL.md Changelog row references E92-S5 / AI-84 / AI-RETRO-S46-3" {
  run grep -F 'E92-S5 — Opt-in `--auto-file` flag for retro action items (AI-84 / AI-RETRO-S46-3)' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC6-2: SKILL.md ## Refs section names the design note" {
  run grep -F 'docs/planning-artifacts/retro-auto-file-design.md' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

# ---------- AC1: Design note delivered ----------

@test "AC1-1: design note exists at the canonical path" {
  [ -f "$DESIGN_NOTE" ]
}

@test "AC1-2: design note documents eligibility rubric (11 v2 types mapped)" {
  run grep -F '| `feature` | YES' "$DESIGN_NOTE"
  [ "$status" -eq 0 ]
  run grep -F '| `tech-debt` | NO' "$DESIGN_NOTE"
  [ "$status" -eq 0 ]
  run grep -F '| `process` | NO' "$DESIGN_NOTE"
  [ "$status" -eq 0 ]
}

@test "AC1-3: design note picks Option B (opt-in) as the recommendation" {
  run grep -F '**Recommendation: Option B.**' "$DESIGN_NOTE"
  [ "$status" -eq 0 ]
}

@test "AC1-4: design note documents AC-EC7 gate interaction" {
  run grep -F 'Auto-file means "auto-spawn the AskUserQuestion bucket prompt at retro close", not "auto-bypass the prompt".' "$DESIGN_NOTE"
  [ "$status" -eq 0 ]
}

# ---------- AC4 partial: TC-RAF-3 + TC-RAF-4 ----------

# TC-RAF-3 — v1 classification entries are read-only (no auto-file). The
# SKILL.md prose documents this; assert the documentation invariant since
# the runtime path is substrate-deferred.
@test "TC-RAF-3: SKILL.md Step 5b documents v1 (classification:) entries are NEVER auto-filed" {
  run grep -F 'Items written via the v1 dual-schema path' "$SKILL_MD"
  [ "$status" -eq 0 ]
  run grep -F 'NEVER auto-filed' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

# TC-RAF-4 — backward-compat preserved when --auto-file flag is absent.
# Assert the explicit default-OFF documentation in the SKILL.md prose
# (full runtime test deferred with TC-RAF-1/-2).
@test "TC-RAF-4: SKILL.md Step 5b documents default-OFF backward-compat" {
  run grep -F 'Default is OFF — when the flag is absent (the sprint-45/46/47 default), this step is a no-op' "$SKILL_MD"
  [ "$status" -eq 0 ]
}
