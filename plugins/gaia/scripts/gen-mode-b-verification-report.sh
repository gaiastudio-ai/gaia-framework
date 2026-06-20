#!/usr/bin/env bash
# shellcheck disable=SC2016  # report body emits literal backtick code spans in single-quoted printf formats
# gen-mode-b-verification-report.sh — generate the persistent-teammate
# dispatch verification report.
#
# Walks every skill under the plugin, records its persistent-teammate
# readiness status (readiness section present? named bridge reachable? per-skill
# foreground override declared?), runs the roster-cost measurement, and writes
# a markdown report.
#
# SUBSTRATE-HONEST: live persistent-teammate dispatch is not exercisable in
# this environment, so every team-ready skill resolves to the foreground
# fallback path at runtime. The report records readiness and reachability —
# the static preconditions for team dispatch — plus the fallback-path
# roster-cost number. It does NOT claim any skill was exercised live.
#
# Usage:
#   gen-mode-b-verification-report.sh [--out PATH] [--iterations N]
#
# Default --out: knowledge/mode-b-verification-report.md (relative to plugin).
#
# Exit codes:
#   0 — report written
#   2 — usage error
#
# bash 3.2-safe: no mapfile, no ${var,,}.

set -eu
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS_DIR="$PLUGIN_DIR/skills"
LIB_DIR="$SCRIPT_DIR/lib"
ROSTER="$LIB_DIR/roster-cost.sh"

OUT="$PLUGIN_DIR/knowledge/mode-b-verification-report.md"
ITERATIONS=30

while [ $# -gt 0 ]; do
  case "$1" in
    --out)        OUT="${2:-}"; shift 2 ;;
    --out=*)      OUT="${1#--out=}"; shift ;;
    --iterations) ITERATIONS="${2:-}"; shift 2 ;;
    --iterations=*) ITERATIONS="${1#--iterations=}"; shift ;;
    -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
    *) printf 'gen-mode-b-verification-report.sh: unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# Has the skill a persistent-teammate readiness section?
_has_readiness() {
  grep -qiE 'mode b readiness' "$1" 2>/dev/null
}

# Print the named bridge file (basename) referenced by the readiness prose, if
# any.
_bridge_ref() {
  grep -oE 'scripts/lib/[a-z-]+bridge\.sh' "$1" 2>/dev/null | sort -u | head -1
}

# Print the top-level `mode:` frontmatter value, if any.
_mode_override() {
  awk '
    NR == 1 && $0 != "---" { exit }
    NR == 1 { in_fm = 1; next }
    in_fm && $0 == "---" { exit }
    in_fm && /^mode:[[:space:]]*/ {
      sub(/^mode:[[:space:]]*/, "")
      sub(/[[:space:]]*#.*$/, "")
      sub(/^"/, ""); sub(/"$/, "")
      sub(/^'\''/, ""); sub(/'\''$/, "")
      sub(/[[:space:]]+$/, "")
      print
      exit
    }
  ' "$1" 2>/dev/null || printf ''
}

# Run the roster-cost measurement and capture its key=value output.
roster_out="$(bash "$ROSTER" --iterations "$ITERATIONS" 2>/dev/null || true)"
p95_line="$(printf '%s\n' "$roster_out" | grep -E '^p95_ms=' | head -1)"
threshold_line="$(printf '%s\n' "$roster_out" | grep -E '^threshold_ms=' | head -1)"
verdict_line="$(printf '%s\n' "$roster_out" | grep -E '^verdict=' | head -1)"
[ -n "$p95_line" ] || p95_line="p95_ms=unknown"
[ -n "$threshold_line" ] || threshold_line="threshold_ms=unknown"
[ -n "$verdict_line" ] || verdict_line="verdict=unknown"

mkdir -p "$(dirname "$OUT")"

generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# Build the per-skill table rows, tallying counts as we go.
rows=""
count_ready=0
count_total=0
count_bridge_ok=0
count_override=0

for skill_md in "$SKILLS_DIR"/*/SKILL.md; do
  [ -f "$skill_md" ] || continue
  skill_name="$(basename "$(dirname "$skill_md")")"
  count_total=$((count_total + 1))

  readiness="absent"
  if _has_readiness "$skill_md"; then
    readiness="readiness section present"
    count_ready=$((count_ready + 1))
  fi

  bridge="$(_bridge_ref "$skill_md")"
  bridge_status="n/a"
  if [ -n "$bridge" ]; then
    if [ -f "$PLUGIN_DIR/$bridge" ]; then
      bridge_status="reachable"
      count_bridge_ok=$((count_bridge_ok + 1))
    else
      bridge_status="MISSING"
    fi
  fi

  override="$(_mode_override "$skill_md")"
  override_status="none"
  case "$override" in
    A|a) override_status="foreground override"; count_override=$((count_override + 1)) ;;
  esac

  # Only list skills that participate in the readiness contract or pin a mode.
  if [ "$readiness" != "absent" ] || [ "$override_status" != "none" ]; then
    rows="${rows}| \`${skill_name}\` | ${readiness} | ${bridge_status} | ${override_status} | fallback |
"
  fi
done

{
  printf '# Persistent-Teammate Dispatch — Verification Report\n\n'
  printf '_Generated: %s_\n\n' "$generated_at"

  printf '## Summary\n\n'
  printf 'This report verifies the persistent-teammate (team-dispatch) stack against\n'
  printf 'every skill in the plugin. It records the static readiness preconditions —\n'
  printf 'whether each skill declares a team-dispatch readiness section, whether the\n'
  printf 'shared dispatch bridge it names is reachable on disk, and whether the skill\n'
  printf 'pins itself to the foreground dispatch path via a per-skill override.\n\n'
  printf 'Live team dispatch is not exercisable in this environment: the runtime\n'
  printf 'primitives for persistent teammates are gated, so every skill resolves to\n'
  printf 'the foreground **fallback** path at runtime. The Dispatch column therefore\n'
  printf 'reads `fallback` for every row — this is an honest record of what was\n'
  printf 'measured, not a claim that any skill was exercised live. The roster-cost\n'
  printf 'number below is likewise the fallback-path bookkeeping cost.\n\n'

  printf -- '- Skills scanned: **%d**\n' "$count_total"
  printf -- '- Team-ready skills (readiness section present): **%d**\n' "$count_ready"
  printf -- '- Named bridges reachable: **%d**\n' "$count_bridge_ok"
  printf -- '- Skills with a per-skill foreground override: **%d**\n\n' "$count_override"

  printf '## Roster Cost (fallback-path spawn latency)\n\n'
  printf 'Measured over %d iterations of a single spawn-then-shutdown cycle on the\n' "$ITERATIONS"
  printf 'foreground fallback path. The P95 below is the fallback bookkeeping cost\n'
  printf '(registry write, handle generation, provenance append, fallback-token\n'
  printf 'emission) — the floor cost the dispatcher always pays. Live teammate\n'
  printf 'startup would add substrate latency on top of this number.\n\n'
  printf -- '- `%s`\n' "$p95_line"
  printf -- '- `%s`\n' "$threshold_line"
  printf -- '- `%s`\n\n' "$verdict_line"

  printf '## Per-Skill Status\n\n'
  printf '| Skill | Readiness | Bridge | Mode override | Dispatch |\n'
  printf '|-------|-----------|--------|---------------|----------|\n'
  printf '%s' "$rows"
  printf '\n'

  printf '## Backward-Compatibility Note\n\n'
  printf 'The per-skill foreground override is opt-in and one-directional: a skill\n'
  printf 'that declares `mode: A` in its frontmatter is pinned to the foreground\n'
  printf 'dispatch path even when the framework runs with persistent teammates\n'
  printf 'enabled globally. A foreground-only framework can never be upgraded by a\n'
  printf 'skill — the knob only opts a skill OUT of team dispatch, never into it.\n'
  printf 'This preserves existing foreground behaviour unchanged for any skill that\n'
  printf 'is not team-ready.\n'
} > "$OUT"

printf 'gen-mode-b-verification-report.sh: wrote %s\n' "$OUT"
exit 0
