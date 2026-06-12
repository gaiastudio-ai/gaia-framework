#!/usr/bin/env bash
# audit-skill-memory-load.sh — find skills that dispatch a sidecar-bearing
# agent WITHOUT loading that agent's memory (the "blind agent" bug class).
#
# An agent's own `## Memory` `!`-bash line does NOT fire when the agent is
# spawned via the main-turn Agent tool — `!`-bash inlining is a SKILL.md /
# slash-command substrate feature. So memory (ground-truth + decision-log)
# reaches a dispatched agent only when the DISPATCHING skill carries a
# `memory-loader.sh <agent> <tier>` line. A skill that dispatches a
# sidecar-bearing agent without one runs that agent memory-blind.
#
# For each SKILL.md:
#   DISPATCHED = agents named in `subagent_type: [gaia:]<agent>` lines
#   LOADED     = agents in `memory-loader.sh <agent> <tier>` lines
# A skill is FLAGGED when it dispatches a sidecar-bearing agent (Tier 1 + 2)
# that is not in its LOADED set. Tier-3 dev personas carry no ground-truth, so
# they are out of scope unless --strict is passed.
#
# Output:
#   - stdout: one `GAP  <skill>  dispatches <agent> ...` line per finding,
#             followed by a summary line.
# Exit codes:
#   0 — no gaps · 1 — gaps found · 2 — usage/error
#
# POSIX discipline: bash 3.2 compatible (macOS default).

set -eu
LC_ALL=C
export LC_ALL

# Resolve the plugin root: prefer the substrate var; fall back to this
# script's own location (scripts/ -> plugin root) so the audit also runs from
# a source checkout. Never hard-code a cache path.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  PLUGIN="$CLAUDE_PLUGIN_ROOT"
else
  _self="${BASH_SOURCE[0]}"
  PLUGIN="$(cd "$(dirname "$_self")/.." && pwd)"
fi

STRICT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --plugin) PLUGIN="$2"; shift 2 ;;
    --strict) STRICT=1; shift ;;
    -h|--help)
      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

SKILLS="$PLUGIN/skills"
[ -d "$SKILLS" ] || { echo "no skills dir: $SKILLS" >&2; exit 2; }

# Sidecar-bearing agents: Tier 1 + Tier 2 per the memory config. Persona
# aliases normalize to the agent id.
sidecar_agents="validator architect pm sm orchestrator security devops test-architect"

_canon() {
  case "$1" in
    val) echo validator ;;
    theo) echo architect ;;
    derek) echo pm ;;
    nate) echo sm ;;
    *) echo "$1" ;;
  esac
}

_is_sidecar() {
  local a; a="$(_canon "$1")"
  case " $sidecar_agents " in *" $a "*) return 0 ;; *) return 1 ;; esac
}

gaps=0
flagged_skills=""

for f in "$SKILLS"/*/SKILL.md; do
  [ -f "$f" ] || continue
  skill="$(basename "$(dirname "$f")")"

  # `|| true` guards set -e when grep finds no match (rc=1).
  dispatched="$( { grep -oE 'subagent_type:[[:space:]]*`?(gaia:)?[a-z][a-z0-9-]+' "$f" 2>/dev/null || true; } \
                 | sed -E 's/.*subagent_type:[[:space:]]*`?(gaia:)?//' | sort -u )"
  [ -n "$dispatched" ] || continue

  loaded="$( { grep -oE 'memory-loader\.sh[[:space:]]+[a-z][a-z0-9-]+' "$f" 2>/dev/null || true; } \
             | sed -E 's/.*memory-loader\.sh[[:space:]]+//' | sort -u )"

  for d in $dispatched; do
    if ! _is_sidecar "$d"; then
      # Out of scope (Tier-3 / non-agent token such as the bare `gaia` left by
      # a dynamic `gaia:<stack-persona>` dispatch) unless --strict.
      [ "$STRICT" -eq 1 ] || continue
    fi
    dc="$(_canon "$d")"
    hit=0
    for l in $loaded; do
      lc="$(_canon "$l")"
      [ "$lc" = "$dc" ] && { hit=1; break; }
    done
    if [ "$hit" -eq 0 ]; then
      printf 'GAP  %-34s dispatches %-16s but does NOT load its memory\n' "$skill" "$d"
      gaps=$((gaps + 1))
      case " $flagged_skills " in *" $skill "*) : ;; *) flagged_skills="$flagged_skills $skill" ;; esac
    fi
  done
done

echo "----------------------------------------------------------------"
if [ "$gaps" -eq 0 ]; then
  echo "OK: every audited dispatch loads the dispatched agent's memory."
  exit 0
else
  echo "FLAGGED $gaps dispatch(es) across skills:$flagged_skills"
  echo "Fix: add '!\${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh <agent> all' to each flagged SKILL.md." >&2
  exit 1
fi
