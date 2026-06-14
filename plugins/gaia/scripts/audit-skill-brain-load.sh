#!/usr/bin/env bash
# audit-skill-brain-load.sh — find consultation-required dispatching skills that
# load NO brain context (the "brain-blind" regression class).
#
# A workflow stage that the hand-authored reliance map declares as
# consultation-required reaches its brain context only when the entering
# SKILL.md carries a brain-context loader line (the brain-reliance-loader
# invocation). A consultation-required stage whose SKILL.md has no such line
# runs brain-blind — a regression that drops the consultation wiring slips
# through unless CI catches it.
#
# This is a DECIDED SIBLING of audit-skill-memory-load.sh, NOT an extension:
# the join key differs (consultation-required STAGES declared in the reliance
# map, vs the memory audit's dispatched subagent_type agents), the source of
# truth differs (this reads the reliance map; the memory audit reads none), and
# keeping them separate isolates blast radius from the memory audit's pinned
# regression anchors. The contract is mirrored verbatim: the same
# `GAP <skill> ...` stdout shape and the same 0/1/2 exit-code semantics.
#
# Scope is DERIVED FROM THE MAP, never hard-coded: the consultation-required
# skill set is the set of skills named by the `<skill>:<stage-id>` stage keys
# in the reliance map. Adding a consultation-required stage to the map extends
# this audit's coverage without a code change.
#
# For each consultation-required skill:
#   the skill "loads brain context" if its SKILL.md carries a
#   brain-reliance-loader.sh invocation line (analogous to how the memory audit
#   looks for a memory-loader.sh line). A consultation-required skill with no
#   such line is a GAP.
#
# FAIL DIRECTION — the explicit inverse of the runtime loader.
#   The runtime brain-reliance-loader fails OPEN (warn + exit 0) when the map is
#   absent or malformed: a governance-artifact fault must never wedge every
#   workflow at runtime. This CI gate is the asymmetric counterpart: it fails
#   CLOSED — a malformed map at build time is an exit-2 build error, because a
#   broken source of truth must not let a brain-blind regression merge.
#
# Output:
#   - stdout: one `GAP  <skill>  ...` line per finding, then a summary line.
# Exit codes:
#   0 — no gaps (clean, or an empty/seed-only map with no stages)
#   1 — gaps found (a consultation-required skill loads no brain context)
#   2 — usage error OR a malformed reliance map (fail CLOSED at build time)
#
# POSIX discipline: bash 3.2 compatible (macOS default). No mapfile, no
# associative arrays, no GNU-only flags. LC_ALL=C. set -eu.

set -eu
LC_ALL=C
export LC_ALL

# Resolve the plugin root: prefer the substrate var; fall back to this script's
# own location (scripts/ -> plugin root) so the audit also runs from a source
# checkout. Never hard-code a cache path.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  PLUGIN="$CLAUDE_PLUGIN_ROOT"
else
  _self="${BASH_SOURCE[0]}"
  PLUGIN="$(cd "$(dirname "$_self")/.." && pwd)"
fi

MAP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --plugin) PLUGIN="$2"; shift 2 ;;
    --map) MAP="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

SKILLS="$PLUGIN/skills"
[ -d "$SKILLS" ] || { echo "no skills dir: $SKILLS" >&2; exit 2; }

# Resolve the reliance map. An explicit --map wins; otherwise default to the
# canonical knowledge-store path via gaia-paths.sh GAIA_KNOWLEDGE_DIR (NOT a
# hard-coded literal), mirroring the runtime loader's resolution.
if [ -z "$MAP" ]; then
  _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  _lib="$_self_dir/lib/gaia-paths.sh"
  # shellcheck source=lib/gaia-paths.sh
  . "$_lib" || { echo "could not source gaia-paths.sh" >&2; exit 2; }
  MAP="$GAIA_KNOWLEDGE_DIR/brain-reliance-map.yaml"
fi

# An absent map declares no consultation-required scope. The runtime loader
# treats this as un-evaluable and fails open; the CI gate has nothing to audit
# either, so it is clean (exit 0). Only a PRESENT-but-MALFORMED map is the
# fail-closed build error.
if [ ! -r "$MAP" ]; then
  echo "----------------------------------------------------------------"
  echo "OK: no reliance map at $MAP — no consultation-required scope to audit."
  exit 0
fi

# Probe PyYAML once for the authoritative malformed-map detection.
have_pyyaml=0
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  have_pyyaml=1
fi

# Parse the consultation-required stage keys (the `<skill>:<stage-id>` keys
# under `stages:`) into a flat list, one per line. PyYAML primary, awk fallback
# — the same dual idiom the runtime loader uses, so scope is derived like for
# like. The function writes the keys to $1 and returns:
#   0 — map parsed cleanly (keys file holds zero or more stage keys)
#   1 — map could not be parsed (malformed) -> caller fails CLOSED (exit 2)
_parse_stage_keys() {
  keys_out="$1"
  : > "$keys_out"

  if [ "$have_pyyaml" = "1" ]; then
    python3 - "$MAP" "$keys_out" <<'PYEOF'
import sys, yaml
mapf, keys_out = sys.argv[1], sys.argv[2]
try:
    doc = yaml.safe_load(open(mapf))
except Exception:
    sys.exit(1)                       # malformed map -> fail CLOSED
if doc is None:
    doc = {}
if not isinstance(doc, dict):
    sys.exit(1)
stages = doc.get("stages")
if stages is None:
    stages = {}
if not isinstance(stages, dict):
    sys.exit(1)
with open(keys_out, "w") as kf:
    for k in stages:
        kf.write("%s\n" % str(k).replace("\n", " ").replace("\r", " "))
sys.exit(0)
PYEOF
    return $?
  fi

  # awk fallback: pull each stage key from the map's stable two-space-indented
  # `<key>:` form under `stages:`. awk cannot detect a YAML parse error, so the
  # PyYAML path (preferred on any host with PyYAML, including CI) is the
  # authoritative malformed-map detector.
  awk '
    function unq(v) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (substr(v,1,1) == "\"" && substr(v,length(v),1) == "\"")
        v = substr(v, 2, length(v)-2)
      return v
    }
    /^stages:[[:space:]]*$/ { in_stages = 1; next }
    /^[^[:space:]]/ { in_stages = 0 }
    in_stages && /^  [^ ].*:[[:space:]]*$/ {
      k=$0; sub(/:[[:space:]]*$/, "", k); k=unq(k)
      if (k != "") print k
    }
  ' "$MAP" > "$keys_out" 2>/dev/null || return 1
  return 0
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/asbl.XXXXXX")"
trap 'rm -rf "$tmp" 2>/dev/null || true' EXIT

stage_keys="$tmp/stage-keys.txt"
parse_rc=0
_parse_stage_keys "$stage_keys" || parse_rc=$?
if [ "$parse_rc" -ne 0 ]; then
  echo "FAIL: reliance map at $MAP could not be parsed (malformed)." >&2
  echo "CI gate fails CLOSED: a broken source of truth must not let a brain-blind regression merge." >&2
  exit 2
fi

# Reduce the stage keys to the unique set of consultation-required SKILLS (the
# part before the first ':' in each `<skill>:<stage-id>` key).
req_skills="$( { sed -E 's/:.*$//' "$stage_keys" || true; } | sort -u )"

gaps=0
flagged_skills=""

for skill in $req_skills; do
  [ -n "$skill" ] || continue
  f="$SKILLS/$skill/SKILL.md"
  if [ ! -f "$f" ]; then
    # A consultation-required skill named in the map with no SKILL.md cannot be
    # loading its brain context — it is brain-blind by omission.
    printf 'GAP  %-34s is consultation-required but has no SKILL.md\n' "$skill"
    gaps=$((gaps + 1))
    case " $flagged_skills " in *" $skill "*) : ;; *) flagged_skills="$flagged_skills $skill" ;; esac
    continue
  fi

  # The skill loads brain context iff its SKILL.md carries a
  # brain-reliance-loader invocation line. `|| true` guards set -e on no-match.
  loads="$( { grep -cE 'brain-reliance-loader\.sh' "$f" 2>/dev/null || true; } )"
  if [ "${loads:-0}" -eq 0 ]; then
    printf 'GAP  %-34s is consultation-required but does NOT load its brain context\n' "$skill"
    gaps=$((gaps + 1))
    case " $flagged_skills " in *" $skill "*) : ;; *) flagged_skills="$flagged_skills $skill" ;; esac
  fi
done

echo "----------------------------------------------------------------"
if [ "$gaps" -eq 0 ]; then
  echo "OK: every consultation-required skill loads its brain context."
  exit 0
else
  echo "FLAGGED $gaps consultation-required skill(s):$flagged_skills"
  echo "Fix: add '!\${CLAUDE_PLUGIN_ROOT}/scripts/brain/brain-reliance-loader.sh <skill>:<stage-id>' to each flagged SKILL.md." >&2
  exit 1
fi
