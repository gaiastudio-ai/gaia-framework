#!/usr/bin/env bats
# ATDD — E28-S147 Update all 28 subagent .md files with memory-loader.sh injection points
# Tests each acceptance criterion from docs/implementation-artifacts/E28-S147-*.md.

setup() {
  REPO_ROOT="$(git rev-parse --show-toplevel)"
  AGENTS_DIR="${REPO_ROOT}/plugins/gaia/agents"
  SCHEMA_FILE="${REPO_ROOT}/plugins/gaia/knowledge/agent-frontmatter-schema.md"
  LOADER="${REPO_ROOT}/plugins/gaia/scripts/memory-loader.sh"
  MEMORY_ROOT="${REPO_ROOT}/../_memory"

  # Canonical agent inventory (28 live + _base-dev = 29 total).
  AGENTS=(
    _base-dev
    analyst architect data-engineer devops performance pm qa security sm
    tech-writer ux-designer validator
    brainstorming-coach design-thinking-coach innovation-strategist
    presentation-designer problem-solver storyteller test-architect
    orchestrator
    angular-dev typescript-dev flutter-dev java-dev python-dev mobile-dev go-dev
  )
}

agent_file() {
  echo "${AGENTS_DIR}/$1.md"
}

# --- AC1 --------------------------------------------------------------------
# Every agent file has a ground-truth memory-loader.sh injection line
# referencing its own name.
@test "AC1: every agent file contains a ground-truth memory-loader.sh injection with its own name" {
  for agent in "${AGENTS[@]}"; do
    file="$(agent_file "$agent")"
    [ -f "$file" ] || { echo "missing agent file: $file"; return 1; }
    run grep -F "!\${PLUGIN_DIR}/scripts/memory-loader.sh $agent ground-truth" "$file"
    [ "$status" -eq 0 ] || { echo "AC1 FAIL in $file"; return 1; }
  done
}

# --- AC-EC1: exactly one ## Memory section and one memory-loader.sh line per file.
@test "AC-EC1: each agent file has exactly one ## Memory section and one memory-loader.sh invocation" {
  for agent in "${AGENTS[@]}"; do
    file="$(agent_file "$agent")"
    mem_count="$(grep -c '^## Memory$' "$file" || true)"
    [ "$mem_count" = "1" ] || { echo "expected 1 ## Memory in $file, got $mem_count"; return 1; }
    loader_count="$(grep -cE '^!\$\{PLUGIN_DIR\}/scripts/memory-loader.sh ' "$file" || true)"
    [ "$loader_count" = "1" ] || { echo "expected 1 loader in $file, got $loader_count"; return 1; }
  done
}

# --- AC2 --------------------------------------------------------------------
# ## Memory section placed AFTER persona/identity and BEFORE the first
# behavioural section (Rules / Activation / Mission when it's behavioural / Scope).
# Canonical anchor per agent:
#   - Dev agents (have ## Identity + ## Expertise persona block): Memory must
#     sit AFTER ## Expertise and BEFORE ## Rules.
#   - Non-dev agents (have ## Mission + ## Persona): Memory must sit AFTER
#     ## Persona and BEFORE ## Rules (or before the first section after Persona
#     if Rules is absent).
#   - _base-dev (has ## Mission + ## Persona): Memory must sit AFTER ## Persona
#     and BEFORE ## Rules.
@test "AC2: ## Memory sits after persona/identity and before first behavioural section" {
  for agent in "${AGENTS[@]}"; do
    file="$(agent_file "$agent")"
    mem_line="$(grep -n '^## Memory$' "$file" | head -1 | cut -d: -f1)"
    rules_line="$(grep -n '^## Rules$' "$file" | head -1 | cut -d: -f1)"
    persona_line="$(grep -n '^## Persona$' "$file" | head -1 | cut -d: -f1)"
    expertise_line="$(grep -n '^## Expertise$' "$file" | head -1 | cut -d: -f1)"

    # Memory must exist.
    [ -n "$mem_line" ] || { echo "no ## Memory in $file"; return 1; }

    # Anchor: last of persona/expertise blocks (the persona-ish block).
    anchor=""
    if [ -n "$expertise_line" ]; then
      anchor="$expertise_line"
    elif [ -n "$persona_line" ]; then
      anchor="$persona_line"
    fi
    [ -n "$anchor" ] || { echo "no persona anchor in $file"; return 1; }

    # Memory must appear AFTER the anchor.
    [ "$mem_line" -gt "$anchor" ] || {
      echo "AC2 FAIL: ## Memory ($mem_line) must be after persona/expertise anchor ($anchor) in $file"; return 1;
    }

    # Memory must appear BEFORE ## Rules (if present).
    if [ -n "$rules_line" ]; then
      [ "$mem_line" -lt "$rules_line" ] || {
        echo "AC2 FAIL: ## Memory ($mem_line) must be before ## Rules ($rules_line) in $file"; return 1;
      }
    fi
  done
}

# --- AC3 + AC4: memory-loader.sh invocations produce expected outputs -------
# Tier 1 (ground-truth exists): non-empty stdout, exit 0.
# Tier 2/3 (no ground-truth): empty stdout, exit 0.
@test "AC3/AC4: memory-loader.sh returns exit 0 for every tier; non-empty only for Tier 1 agents with real ground-truth" {
  [ -x "$LOADER" ] || { echo "loader missing or not executable: $LOADER"; return 1; }

  # Tier 1 sample — architect.
  if [ -f "${MEMORY_ROOT}/architect-sidecar/ground-truth.md" ]; then
    run env MEMORY_PATH="$MEMORY_ROOT" "$LOADER" architect ground-truth
    [ "$status" -eq 0 ] || { echo "architect loader exit $status"; return 1; }
    [ -n "$output" ] || { echo "architect ground-truth unexpectedly empty"; return 1; }
  fi

  # Tier 2 sample — orchestrator (no ground-truth).
  run env MEMORY_PATH="$MEMORY_ROOT" "$LOADER" orchestrator ground-truth
  [ "$status" -eq 0 ] || { echo "orchestrator loader exit $status"; return 1; }
  [ -z "$output" ] || { echo "orchestrator unexpected output: $output"; return 1; }

  # Tier 3 sample — typescript-dev (no ground-truth).
  run env MEMORY_PATH="$MEMORY_ROOT" "$LOADER" typescript-dev ground-truth
  [ "$status" -eq 0 ] || { echo "typescript-dev loader exit $status"; return 1; }
  [ -z "$output" ] || { echo "typescript-dev unexpected output: $output"; return 1; }

  # Missing sidecar directory (AC4) — invent an agent name that doesn't exist.
  run env MEMORY_PATH="$MEMORY_ROOT" "$LOADER" no-such-agent-xyz ground-truth
  [ "$status" -eq 0 ] || { echo "missing-sidecar loader exit $status"; return 1; }
  [ -z "$output" ] || { echo "missing-sidecar unexpected output: $output"; return 1; }
}

# --- AC-EC4: orchestrator uniformity (ground-truth, not decision-log/all) ---
@test "AC-EC4: orchestrator injection uses ground-truth tier uniformly" {
  file="$(agent_file orchestrator)"
  run grep -F '!${PLUGIN_DIR}/scripts/memory-loader.sh orchestrator ground-truth' "$file"
  [ "$status" -eq 0 ]
  run grep -F '!${PLUGIN_DIR}/scripts/memory-loader.sh orchestrator all' "$file"
  [ "$status" -ne 0 ]
  run grep -F '!${PLUGIN_DIR}/scripts/memory-loader.sh orchestrator decision-log' "$file"
  [ "$status" -ne 0 ]
}

# --- AC-EC9 + Task 9: agent-frontmatter-schema.md documents the canonical ground-truth convention
@test "AC-EC9: agent-frontmatter-schema.md documents the ground-truth convention and placement rule" {
  run grep -F 'ground-truth' "$SCHEMA_FILE"
  [ "$status" -eq 0 ]
  # Should reference the post-persona / pre-behavioural placement somewhere.
  run grep -iE 'after.*persona|post-persona|before.*rules|before.*behavioural' "$SCHEMA_FILE"
  [ "$status" -eq 0 ]
  # Should reference ADR-046 and FR-331 anchors per Task 9.
  run grep -F 'ADR-046' "$SCHEMA_FILE"
  [ "$status" -eq 0 ]
  run grep -F 'FR-331' "$SCHEMA_FILE"
  [ "$status" -eq 0 ]
}

# --- Task 7: repo-wide scan counts ------------------------------------------
# The schema doc (agent-frontmatter-schema.md) has been moved to knowledge/
# and is no longer in the agents directory, so no exclusion is needed.
@test "Task 7: exactly 28 loader injections and 28 ## Memory sections across subagent files" {
  total_loaders=0
  total_mem=0
  for f in "${AGENTS_DIR}"/*.md; do
    if grep -qE '^!\$\{PLUGIN_DIR\}/scripts/memory-loader.sh ' "$f"; then
      total_loaders=$((total_loaders + 1))
    fi
    if grep -q '^## Memory$' "$f"; then
      total_mem=$((total_mem + 1))
    fi
  done
  [ "$total_loaders" = "28" ] || { echo "expected 28 loader lines, got $total_loaders"; return 1; }
  [ "$total_mem" = "28" ] || { echo "expected 28 ## Memory sections, got $total_mem"; return 1; }
  # No 'all' tier leftovers in subagent injection lines.
  for f in "${AGENTS_DIR}"/*.md; do
    if grep -qE '^!\$\{PLUGIN_DIR\}/scripts/memory-loader.sh [^ ]+ all$' "$f"; then
      echo "legacy 'all' tier found in $f"
      return 1
    fi
  done
}
