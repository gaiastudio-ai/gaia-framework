#!/usr/bin/env bats
# test-no-bare-name-persona-spawn.bats — Static check: no bare-name persona
# subagent dispatch in skill prose.
#
# Story: E28-S226 — Subagent dispatch rewrite (skill prose to plugin-namespaced
# spawn, e.g., `gaia:architect`).
#
# Traces to: ADR-041 (subagent dispatch invariant), NFR-046 (single-spawn-level
# constraint).
#
# Rule
# ----
# Skill prose under `plugins/gaia/skills/` MUST refer to a subagent dispatch by
# the plugin-namespaced form `gaia:<persona>`, never the bare name. Bare-name
# spawns route to the `general-purpose` substrate with persona-prose injection,
# bypassing sidecar memory and isolated context (the ADR-041 invariant).
#
# Allowlist
# ---------
# Lines that legitimately gloss the persona by display name (introductory
# definitions, schema doc) MAY carry a trailing `# spawn-audit-allow` comment.
# The check skips lines bearing that comment so unrelated future violations
# still fail. Use the comment sparingly and document the rationale in the
# adjacent prose.
#
# AC coverage: AC1, AC2, AC3.

load '../test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$PLUGIN_ROOT/skills"
}

teardown() { common_teardown; }

# The canonical persona alternation — taken from the `name:` field of every
# `plugins/gaia/agents/*.md` file (excluding `_base-dev.md` and `_SCHEMA.md`).
# Keep this in sync with the agents directory; a missing persona here means
# a bare-name violation against that persona will not be caught.
PERSONAS='architect|validator|pm|sm|tdd-reviewer|ux-designer|test-architect|design-thinking-coach|problem-solver|innovation-strategist|presentation-designer|stack-dev|qa|devops|brainstorming-coach|analyst|orchestrator|performance|data-engineer|angular-dev|flutter-dev|go-dev|java-dev|mobile-dev|python-dev|storyteller|security|tech-writer|typescript-dev'

# AC2 — Audit-pass static check: zero bare-name dispatch verbs.
@test "no bare-name persona spawn in skill prose (AC1, AC2)" {
  [ -d "$SKILLS_DIR" ]

  # Broadened pattern: any of {spawn, invoke, re-invoke, delegate to, dispatch}
  # followed by an article ("the" or "a") and a bare persona name and the
  # token (subagent|agent). The bracketed "gaia:" check filters away matches
  # that already use the namespaced form.
  local pattern='(spawn|invoke|re-invoke|delegate to|dispatch) (the |a )?('"$PERSONAS"') (subagent|agent)'

  # grep -E recursive over the skills tree. -i case-insensitive (catches
  # sentence-initial "Spawn", "Invoke"). -n line number. Filter out:
  #   1. Lines containing 'gaia:<persona>' (already namespaced).
  #   2. Lines bearing the trailing '# spawn-audit-allow' AC3 allowlist.
  local hits
  hits="$(grep -rEni "$pattern" "$SKILLS_DIR" 2>/dev/null \
    | grep -vE 'gaia:('"$PERSONAS"')' \
    | grep -vE '# spawn-audit-allow' \
    || true)"

  if [ -n "$hits" ]; then
    printf 'bare-name persona spawn detected:\n%s\n' "$hits" >&2
    return 1
  fi
}

# AC3 — Allowlist mechanism works: a line annotated with
# `# spawn-audit-allow` MUST be ignored by the check.
@test "allowlist comment suppresses match (AC3)" {
  local sandbox="$TEST_TMP/skills/sandbox-skill"
  mkdir -p "$sandbox"
  cat >"$sandbox/SKILL.md" <<'EOF'
# Sandbox skill

Spawn the architect subagent for review purposes. # spawn-audit-allow
EOF

  local pattern='(spawn|invoke|re-invoke|delegate to|dispatch) (the |a )?(architect) (subagent|agent)'

  local hits
  hits="$(grep -rEni "$pattern" "$sandbox" 2>/dev/null \
    | grep -vE 'gaia:(architect)' \
    | grep -vE '# spawn-audit-allow' \
    || true)"

  [ -z "$hits" ]
}

# AC3 (negative) — Without the allowlist comment, the same line MUST fail.
@test "match without allowlist comment is detected (AC3 negative)" {
  local sandbox="$TEST_TMP/skills/sandbox-skill"
  mkdir -p "$sandbox"
  cat >"$sandbox/SKILL.md" <<'EOF'
# Sandbox skill

Spawn the architect subagent for review purposes.
EOF

  local pattern='(spawn|invoke|re-invoke|delegate to|dispatch) (the |a )?(architect) (subagent|agent)'

  local hits
  hits="$(grep -rEni "$pattern" "$sandbox" 2>/dev/null \
    | grep -vE 'gaia:(architect)' \
    | grep -vE '# spawn-audit-allow' \
    || true)"

  [ -n "$hits" ]
}

# AC6 — Original triage reproduction MUST return zero matches.
@test "original triage reproduction returns zero (AC6)" {
  [ -d "$SKILLS_DIR" ]
  local pattern='spawn the (architect|validator|pm|sm|tdd-reviewer) (subagent|agent)'

  local hits
  hits="$(grep -rEni "$pattern" "$SKILLS_DIR" 2>/dev/null \
    | grep -vE 'gaia:(architect|validator|pm|sm|tdd-reviewer)' \
    | grep -vE '# spawn-audit-allow' \
    || true)"

  [ -z "$hits" ]
}
