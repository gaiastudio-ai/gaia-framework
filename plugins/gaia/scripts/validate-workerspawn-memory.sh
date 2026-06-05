#!/usr/bin/env bash
# validate-workerspawn-memory.sh — WorkerSpawn memory-loader invocation validator
#
# Asserts that every skill listed in
#   plugins/gaia/skills/_workerspawn-manifest.yaml
# embeds the canonical `memory-loader.sh {agent_id} {tier}` invocation in its
# SKILL.md body. Exit 0 when all 20 skills comply; non-zero with a per-skill
# diagnostic when any invocation is missing or malformed.
#
# Usage:
#   validate-workerspawn-memory.sh [--plugin-root PATH]
#
# Default --plugin-root is the parent directory of this script (matches the
# live install layout under plugins/gaia/). Tests point it at a temp clone
# of the plugin tree to exercise corruption scenarios.

set -euo pipefail

PLUGIN_ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plugin-root)
      PLUGIN_ROOT="${2:-}"
      shift 2
      ;;
    -h|--help)
      cat <<'EOF'
Usage: validate-workerspawn-memory.sh [--plugin-root PATH]

Scans every skill listed in {plugin-root}/skills/_workerspawn-manifest.yaml
for a canonical memory-loader.sh invocation matching the manifest's
{agent_id} + {tier} pair. Prints one diagnostic per non-compliant skill and
exits 1. Exits 0 with a "CLEAN" summary when all 20 skills comply.
EOF
      exit 0
      ;;
    *)
      echo "error: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

# Default --plugin-root to the directory that contains this script's parent.
if [[ -z "$PLUGIN_ROOT" ]]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PLUGIN_ROOT="$(dirname "$script_dir")"
fi

MANIFEST="${PLUGIN_ROOT}/skills/_workerspawn-manifest.yaml"
SKILLS_DIR="${PLUGIN_ROOT}/skills"

if [[ ! -f "$MANIFEST" ]]; then
  echo "FAIL: manifest not found at $MANIFEST" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Parse manifest (skill -> list of "agent_id tier" pairs).
# Uses a compact awk parser instead of yq to keep the check zero-dependency
# in CI environments where yq may not be installed. Manifest schema is stable
# and flat enough for awk to handle safely.
#
# Output format (per line): skill<TAB>agent_id<TAB>tier
# ---------------------------------------------------------------------------
parse_manifest() {
  awk '
    function emit(skill, agent, tier) {
      if (skill != "" && agent != "" && tier != "") {
        printf "%s\t%s\t%s\n", skill, agent, tier
      }
    }
    BEGIN { skill = ""; agent = ""; tier = ""; in_skills = 0 }
    /^[[:space:]]*#/ { next }
    /^skills:[[:space:]]*$/ { in_skills = 1; next }
    in_skills == 0 { next }
    # New skill entry: "  - name: gaia-..."
    /^[[:space:]]*-[[:space:]]+name:[[:space:]]*/ {
      # Flush pending (agent, tier) before resetting skill.
      emit(skill, agent, tier)
      agent = ""; tier = ""
      name = $0
      sub(/^[[:space:]]*-[[:space:]]+name:[[:space:]]*/, "", name)
      sub(/[[:space:]]*(#.*)?$/, "", name)
      skill = name
      next
    }
    # Persona entry under current skill: "      - agent_id: ..."
    /^[[:space:]]*-[[:space:]]+agent_id:[[:space:]]*/ {
      # Flush pending pair from previous persona.
      emit(skill, agent, tier)
      tier = ""
      a = $0
      sub(/^[[:space:]]*-[[:space:]]+agent_id:[[:space:]]*/, "", a)
      sub(/[[:space:]]*(#.*)?$/, "", a)
      agent = a
      next
    }
    # Tier field under current persona: "        tier: ..."
    /^[[:space:]]+tier:[[:space:]]*/ {
      t = $0
      sub(/^[[:space:]]+tier:[[:space:]]*/, "", t)
      sub(/[[:space:]]*(#.*)?$/, "", t)
      tier = t
      next
    }
    END { emit(skill, agent, tier) }
  ' "$MANIFEST"
}

# ---------------------------------------------------------------------------
# Walk each (skill, agent, tier) tuple and check the skill's SKILL.md body.
# ---------------------------------------------------------------------------
failures=0
checked=0
missing_skills=()

while IFS=$'\t' read -r skill agent tier; do
  [[ -z "$skill" || -z "$agent" || -z "$tier" ]] && continue
  checked=$((checked + 1))

  skill_md="${SKILLS_DIR}/${skill}/SKILL.md"
  if [[ ! -f "$skill_md" ]]; then
    echo "FAIL: ${skill} — SKILL.md not found at ${skill_md}"
    failures=$((failures + 1))
    continue
  fi

  # Validate tier against the canonical set.
  case "$tier" in
    decision-log|ground-truth|all) ;;
    *)
      echo "FAIL: ${skill} — manifest declares invalid tier '${tier}' (expected decision-log | ground-truth | all)"
      failures=$((failures + 1))
      continue
      ;;
  esac

  # Canonical pattern: memory-loader.sh <agent> <tier>
  # The pattern is anchored to the literal string so arbitrary whitespace
  # within the file is still matched by the fixed-string grep.
  pattern="memory-loader.sh ${agent} ${tier}"
  if ! grep -Fq "$pattern" "$skill_md"; then
    echo "FAIL: ${skill} — missing canonical invocation: ${pattern}"
    failures=$((failures + 1))
    continue
  fi
done < <(parse_manifest)

if [[ $failures -gt 0 ]]; then
  echo
  echo "validate-workerspawn-memory: ${failures} failure(s) across ${checked} checked invocation(s)"
  exit 1
fi

echo "validate-workerspawn-memory: CLEAN — ${checked} WorkerSpawn invocation(s) verified"
exit 0
