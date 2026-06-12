#!/usr/bin/env bats
# skill-dispatch-memory-load.bats
#
# Guard: every SKILL.md that DISPATCHES a sidecar-bearing agent (Tier 1 +
# Tier 2 per memory config) MUST also LOAD that agent's memory via a
# `memory-loader.sh <agent> <tier>` line in the same SKILL.md.
#
# Rationale: a GAIA agent's own `## Memory` `!`-bash line does NOT fire when
# the agent is spawned via the main-turn Agent tool — `!`-bash inlining is a
# SKILL.md/slash-command substrate feature. So memory reaches a dispatched
# agent only if the DISPATCHING SKILL loads it. A skill that dispatches a
# sidecar agent without a loader line runs that agent memory-blind (no
# ground-truth, no decision-log). Proven by a canary probe: a raw Agent-tool
# dispatch of the validator persona could not see a canary token injected into
# validator-sidecar/ground-truth.md, while the skill-inlined load path could.
#
# This complements the WorkerSpawn memory-load test (a fixed-manifest check);
# this guard is general — it drives scripts/audit-skill-memory-load.sh, which
# scans ALL skills keyed on the actual dispatch surface, so a newly-added
# blind dispatch fails CI.
#
# Dir-rename-resilient: PLUGIN_ROOT derives from BATS_TEST_DIRNAME, never a
# hard-coded repo/owner literal.

setup() {
  PLUGIN_ROOT="${BATS_TEST_DIRNAME}/.."
  SKILLS_DIR="${PLUGIN_ROOT}/skills"
  AUDIT="${PLUGIN_ROOT}/scripts/audit-skill-memory-load.sh"
}

@test "audit script exists and is executable" {
  [ -f "$AUDIT" ]
  [ -x "$AUDIT" ]
}

@test "no skill dispatches a Tier 1/2 sidecar agent without loading its memory" {
  run "$AUDIT" --plugin "$PLUGIN_ROOT"
  if [ "$status" -ne 0 ]; then
    echo "audit-skill-memory-load.sh reported gaps:" >&2
    echo "$output" >&2
  fi
  [ "$status" -eq 0 ]
}

@test "regression anchors: known Val-dispatch skills load validator memory" {
  # These two were the live blind-dispatch gaps the audit first surfaced; pin
  # them so the loader line cannot silently regress out.
  for skill in gaia-validate-story gaia-sprint-review; do
    grep -qE 'memory-loader\.sh[[:space:]]+validator' "$SKILLS_DIR/$skill/SKILL.md" \
      || { echo "REGRESSION: $skill no longer loads validator memory" >&2; return 1; }
  done
}

@test "audit actually bites: a fixture skill that dispatches without loading is flagged" {
  # Build a throwaway plugin tree with one blind-dispatch skill and confirm the
  # audit flags it (a guard that cannot fail is worthless).
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/skills/fixture-blind"
  cat > "$tmp/skills/fixture-blind/SKILL.md" <<'EOF'
---
name: fixture-blind
---
## Step 1
Dispatch via `subagent_type: validator` without loading memory.
EOF
  run "$AUDIT" --plugin "$tmp"
  rm -rf "$tmp"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'fixture-blind'
  echo "$output" | grep -q 'validator'
}

@test "audit passes a fixture skill that dispatches AND loads" {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/skills/fixture-ok"
  cat > "$tmp/skills/fixture-ok/SKILL.md" <<'EOF'
---
name: fixture-ok
---
## Memory
!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh validator all
## Step 1
Dispatch via `subagent_type: validator`.
EOF
  run "$AUDIT" --plugin "$tmp"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}
