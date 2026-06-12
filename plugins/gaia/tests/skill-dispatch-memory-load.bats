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
# ground-truth, no decision-log). Proven 2026-06-12 by a canary probe: a raw
# Agent-tool dispatch of the validator persona could not see a canary token
# injected into validator-sidecar/ground-truth.md, while the skill-inlined
# load path could.
#
# This complements the WorkerSpawn memory-load test (which checks a fixed
# 20-skill manifest); this guard is general — it scans ALL skills and is keyed
# on the actual dispatch surface, so a newly-added blind dispatch fails CI.
#
# Dir-rename-resilient: PLUGIN_ROOT derives from BATS_TEST_DIRNAME, never a
# hard-coded repo/owner literal.

setup() {
  PLUGIN_ROOT="${BATS_TEST_DIRNAME}/.."
  SKILLS_DIR="${PLUGIN_ROOT}/skills"
}

# Canonicalize a persona alias to its agent id.
_canon() {
  case "$1" in
    val) echo validator ;;
    theo) echo architect ;;
    derek) echo pm ;;
    nate) echo sm ;;
    *) echo "$1" ;;
  esac
}

# Tier 1 + Tier 2 agents have a real sidecar worth loading.
# (Tier 3 dev personas have no ground-truth; not required to load.)
_is_sidecar_agent() {
  local a; a="$(_canon "$1")"
  case " validator architect pm sm orchestrator security devops test-architect " in
    *" $a "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Collect blind dispatches across all skills into a newline list:
#   "<skill> <agent>"
_blind_dispatches() {
  local f skill dispatched loaded d dc l lc hit
  for f in "$SKILLS_DIR"/*/SKILL.md; do
    [ -f "$f" ] || continue
    skill="$(basename "$(dirname "$f")")"

    dispatched="$( { grep -oE 'subagent_type:[[:space:]]*`?(gaia:)?[a-z][a-z0-9-]+' "$f" 2>/dev/null || true; } \
                   | sed -E 's/.*subagent_type:[[:space:]]*`?(gaia:)?//' | sort -u )"
    [ -n "$dispatched" ] || continue

    loaded="$( { grep -oE 'memory-loader\.sh[[:space:]]+[a-z][a-z0-9-]+' "$f" 2>/dev/null || true; } \
               | sed -E 's/.*memory-loader\.sh[[:space:]]+//' | sort -u )"

    for d in $dispatched; do
      # Only sidecar-bearing agents are in scope. This also drops the bare
      # `gaia` token that a `subagent_type: gaia:<stack-persona>` dynamic
      # dispatch can leave behind (it is not a sidecar agent id).
      _is_sidecar_agent "$d" || continue
      dc="$(_canon "$d")"
      hit=0
      for l in $loaded; do
        lc="$(_canon "$l")"
        [ "$lc" = "$dc" ] && { hit=1; break; }
      done
      [ "$hit" -eq 0 ] && printf '%s %s\n' "$skill" "$d"
    done
  done
}

@test "every skill dispatching a Tier 1/2 sidecar agent also loads that agent's memory" {
  run _blind_dispatches
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    echo "Skills dispatching a sidecar agent WITHOUT loading its memory:" >&2
    echo "$output" | while read -r skill agent; do
      echo "  GAP: $skill dispatches '$agent' but has no memory-loader.sh line for it" >&2
    done
    echo "Fix: add '!\${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh <agent> all' to the SKILL.md (see gaia-validate-prd)." >&2
    return 1
  fi
}

@test "regression anchors: known Val-dispatch skills load validator memory" {
  # These two were the live blind-dispatch gaps fixed 2026-06-12; pin them so
  # the loader line cannot silently regress out.
  for skill in gaia-validate-story gaia-sprint-review; do
    grep -qE 'memory-loader\.sh[[:space:]]+validator' "$SKILLS_DIR/$skill/SKILL.md" \
      || { echo "REGRESSION: $skill no longer loads validator memory" >&2; return 1; }
  done
}
