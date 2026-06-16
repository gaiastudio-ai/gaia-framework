#!/usr/bin/env bats
# test-manual-agent.bats — contract tests for the manual-tester agent persona.
#
# Validates frontmatter shape, persona identity, memory-loader reference,
# severity vocabulary, read-only allowlist, and the absence of orchestration
# class on the agent file (behavior comes from context:fork + allowlist).

load 'test_helper.bash'

setup() {
  common_setup
  # Resolve gaia-public root from tests/ → plugins/gaia/ → plugins/ → gaia-public/
  PUBLIC_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  AGENT_FILE="$PUBLIC_ROOT/plugins/gaia/agents/manual-tester.md"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC1 — Agent file exists on disk.
# ---------------------------------------------------------------------------

@test "agent file manual-tester.md exists" {
  [ -f "$AGENT_FILE" ]
}

# ---------------------------------------------------------------------------
# AC1 — Frontmatter: name field is manual-tester.
# ---------------------------------------------------------------------------

@test "frontmatter name is manual-tester" {
  awk 'BEGIN{n=0} /^---$/{n++; next} n==1{print}' "$AGENT_FILE" > "$TEST_TMP/fm.yaml"
  grep -E '^name:[[:space:]]+manual-tester[[:space:]]*$' "$TEST_TMP/fm.yaml"
}

# ---------------------------------------------------------------------------
# AC1 — Frontmatter: context is fork.
# ---------------------------------------------------------------------------

@test "frontmatter has context: fork" {
  awk 'BEGIN{n=0} /^---$/{n++; next} n==1{print}' "$AGENT_FILE" > "$TEST_TMP/fm.yaml"
  grep -E '^context:[[:space:]]+fork[[:space:]]*$' "$TEST_TMP/fm.yaml"
}

# ---------------------------------------------------------------------------
# AC1 — Frontmatter: allowed-tools exactly [Read, Grep, Glob, Bash].
# ---------------------------------------------------------------------------

@test "frontmatter allowed-tools is [Read, Grep, Glob, Bash]" {
  awk 'BEGIN{n=0} /^---$/{n++; next} n==1{print}' "$AGENT_FILE" > "$TEST_TMP/fm.yaml"
  grep -E '^allowed-tools:[[:space:]]+\[Read,[[:space:]]*Grep,[[:space:]]*Glob,[[:space:]]*Bash\][[:space:]]*$' \
    "$TEST_TMP/fm.yaml"
}

# ---------------------------------------------------------------------------
# AC1 — Frontmatter: Write and Edit MUST NOT appear in allowed-tools.
# ---------------------------------------------------------------------------

@test "frontmatter does not allow Write or Edit" {
  awk 'BEGIN{n=0} /^---$/{n++; next} n==1{print}' "$AGENT_FILE" > "$TEST_TMP/fm.yaml"
  assert_file_excludes "$TEST_TMP/fm.yaml" "Write"
  assert_file_excludes "$TEST_TMP/fm.yaml" "Edit"
}

# ---------------------------------------------------------------------------
# AC1 — No orchestration_class field on the agent file.
# ---------------------------------------------------------------------------

@test "agent file has no orchestration_class field" {
  assert_file_excludes "$AGENT_FILE" "orchestration_class"
}

# ---------------------------------------------------------------------------
# AC1 — Persona name is Reese.
# ---------------------------------------------------------------------------

@test "persona section names Reese" {
  grep -F "**Reese**" "$AGENT_FILE"
}

# ---------------------------------------------------------------------------
# AC1 — Memory loader references manual-tester ground-truth via CLAUDE_PLUGIN_ROOT.
# ---------------------------------------------------------------------------

@test "memory loader uses CLAUDE_PLUGIN_ROOT and loads manual-tester ground-truth" {
  grep -F '${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh manual-tester ground-truth' "$AGENT_FILE"
}

# ---------------------------------------------------------------------------
# AC1 — Memory loader does NOT use PLUGIN_DIR (not a substrate var).
# ---------------------------------------------------------------------------

@test "memory loader does not use PLUGIN_DIR" {
  assert_file_excludes "$AGENT_FILE" "PLUGIN_DIR"
}

# ---------------------------------------------------------------------------
# AC1 — Severity vocabulary: CRITICAL, WARNING, INFO.
# ---------------------------------------------------------------------------

@test "severity vocabulary includes CRITICAL WARNING INFO" {
  grep -F "CRITICAL" "$AGENT_FILE"
  grep -F "WARNING" "$AGENT_FILE"
  grep -F "INFO" "$AGENT_FILE"
}

# ---------------------------------------------------------------------------
# AC1 — Mechanical verdict clause present.
# ---------------------------------------------------------------------------

@test "agent documents mechanical verdict" {
  grep -iE "verdict.*mechanical|mechanical.*verdict" "$AGENT_FILE"
}

# ---------------------------------------------------------------------------
# AC1 — Read-only / never-edit-source rule present.
# ---------------------------------------------------------------------------

@test "agent documents read-only never-edit-source rule" {
  grep -iE "read.only|never.*edit.*source|never.*modify" "$AGENT_FILE"
}

# ---------------------------------------------------------------------------
# AC1 — Output Contract section documents run-record shape.
# ---------------------------------------------------------------------------

@test "output contract section documents run-record" {
  grep -F "## Output Contract" "$AGENT_FILE"
  grep -F "run-record" "$AGENT_FILE"
}

# ---------------------------------------------------------------------------
# AC1 — Required body sections present.
# ---------------------------------------------------------------------------

@test "agent has all required body sections" {
  grep -F "## Mission" "$AGENT_FILE"
  grep -F "## Persona" "$AGENT_FILE"
  grep -F "## Memory" "$AGENT_FILE"
  grep -F "## Rules" "$AGENT_FILE"
  grep -F "## Scope" "$AGENT_FILE"
  grep -F "## Output Contract" "$AGENT_FILE"
  grep -F "## Definition of Done" "$AGENT_FILE"
}
