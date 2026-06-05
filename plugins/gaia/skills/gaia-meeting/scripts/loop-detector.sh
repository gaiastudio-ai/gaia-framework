#!/usr/bin/env bash
# loop-detector.sh — gaia-meeting loop detector
#
# Scans the last three consecutive turns. Fires when EXACTLY two distinct
# agents occupy those three turns (A↔B alternation) AND none of the three
# turns produced any progress signal. Three-way alternation (A→B→C) and
# same-agent triples (A→A→A) do NOT trigger.
#
# Progress signal vocabulary:
#   - new-citation : a previously-unseen source citation
#   - new-decision : a recorded decision (CLOSE-phase artifact)
#   - new-pin      : a new scratchpad pin (SP-N)
#
# On fire, emits a forced FACILITATOR / LOOP-BREAK turn marker on stdout.
#
# Turns file format — one line per turn, pipe-separated:
#   <agent>|<progress>|<text>
# where <progress> is one of: no-progress | new-citation | new-decision | new-pin
#
# Usage:
#   loop-detector.sh --turns-file <path>
#
# Exit codes:
#   0 = loop detected — LOOP-BREAK emitted on stdout
#   1 = no loop — no action needed
#   3 = malformed args / missing input file

set -euo pipefail

TURNS_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --turns-file)    TURNS_FILE="${2-}"; shift 2 ;;
    --turns-file=*)  TURNS_FILE="${1#--turns-file=}"; shift ;;
    *)
      echo "loop-detector.sh: unknown argument: $1" >&2
      exit 3
      ;;
  esac
done

if [[ -z "$TURNS_FILE" ]]; then
  echo "loop-detector.sh: --turns-file is required" >&2
  exit 3
fi
if [[ ! -f "$TURNS_FILE" ]]; then
  echo "loop-detector.sh: turns file not found: $TURNS_FILE" >&2
  exit 3
fi

# Read all turns into arrays.
agents=()
progress=()
while IFS='|' read -r a p _rest || [[ -n "$a" ]]; do
  [[ -z "$a" ]] && continue
  agents+=("$a")
  progress+=("$p")
done < "$TURNS_FILE"

n=${#agents[@]}
if [[ "$n" -lt 3 ]]; then
  exit 1
fi

# Look only at the last three turns.
i1=$((n - 3))
i2=$((n - 2))
i3=$((n - 1))

a1="${agents[$i1]}"
a2="${agents[$i2]}"
a3="${agents[$i3]}"

p1="${progress[$i1]}"
p2="${progress[$i2]}"
p3="${progress[$i3]}"

# Distinct-speaker count over the window.
distinct=0
for a in "$a1" "$a2" "$a3"; do
  found=0
  for b in "$a1" "$a2" "$a3"; do
    [[ "$a" == "$b" ]] && found=$((found + 1))
  done
  # No-op — counted via distinct loop below.
done

# Compute the size of the unique-set {a1, a2, a3}.
distinct=1
[[ "$a2" != "$a1" ]] && distinct=$((distinct + 1))
if [[ "$a3" != "$a1" && "$a3" != "$a2" ]]; then
  distinct=$((distinct + 1))
fi

# Rule: exactly two distinct agents AND alternation (a1==a3 or a1==a2 with a2!=a1).
# A↔B with three turns means the middle differs from the ends, OR the first
# matches a2 and a3 differs — but the canonical alternation is a1==a3, a2!=a1.
# We accept the broader "exactly two distinct agents over the window" rule.
if [[ "$distinct" -ne 2 ]]; then
  exit 1
fi

# Reject same-agent triples — those need distinct=1, but A-A-B has distinct=2
# and is also not alternation. Require the middle to differ from one of the
# ends to enforce A↔B (not A-A-B / A-B-B).
if [[ "$a1" == "$a2" ]] || [[ "$a2" == "$a3" ]]; then
  exit 1
fi

# All three turns must lack a progress signal.
for p in "$p1" "$p2" "$p3"; do
  case "$p" in
    new-citation|new-decision|new-pin)
      exit 1
      ;;
  esac
done

# Loop confirmed — emit LOOP-BREAK marker.
printf 'FACILITATOR / LOOP-BREAK turn injected — A=%s B=%s no-progress fr=FR-MTG-30\n' \
  "$a1" "$a2"
exit 0
