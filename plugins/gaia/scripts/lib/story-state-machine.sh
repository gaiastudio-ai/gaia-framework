#!/usr/bin/env bash
# story-state-machine.sh — Story status transition table.
#
# Encodes the canonical seven-state lifecycle plus the matrix of allowed edges.
# Source-only — must be `source`d, not executed.
#
# Canonical states (must match sprint-state.sh CANONICAL_STATES):
#   backlog | validating | ready-for-dev | in-progress | blocked | review | done
#
# Allowed-edge table (Dev Notes §state-machine-table):
#
#   from \\ to        | backlog | ready-for-dev | in-progress | review | validating | done | blocked
#   ----------------- | ------- | ------------- | ----------- | ------ | ---------- | ---- | -------
#   backlog           | (no-op) | yes           | no          | no     | yes        | no   | yes
#   ready-for-dev     | no      | (no-op)       | yes         | no     | no         | no   | yes
#   in-progress       | no      | no            | (no-op)     | yes    | no         | no   | yes
#   review            | no      | no            | no          | (no-op)| no         | yes  | yes
#   validating        | yes     | yes           | no          | no     | (no-op)    | no   | yes
#   done              | no      | no            | no          | no     | no         | (no-op) | no
#   blocked           | yes     | yes           | yes         | yes    | yes        | no   | (no-op)
#
# (no-op) entries are handled BEFORE this table is consulted by the caller —
# self-transitions exit 0 with a benign log message and never write.

# Guard against double-sourcing.
if [ "${__STORY_STATE_MACHINE_SH:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
__STORY_STATE_MACHINE_SH=1

STORY_CANONICAL_STATES=(
  "backlog"
  "validating"
  "ready-for-dev"
  "in-progress"
  "blocked"
  "review"
  "done"
)

# Pipe-encoded "from|to" edges. Self-edges are NOT listed here — the caller
# handles idempotent self-transitions before calling validate_story_transition.
STORY_ALLOWED_EDGES=(
  # backlog
  "backlog|ready-for-dev"
  "backlog|validating"
  "backlog|blocked"
  # /gaia-dev-story Step 2 transitions a fresh story to in-progress directly
  # per SKILL.md when invoked from FRESH mode. Previously this required an
  # intermediate `ready-for-dev` hop that the documented happy-path did NOT
  # mention — operators had to do the two-step transition manually or hit an
  # adjacency-rejection error mid-dev-story. The backlog → in-progress edge
  # is sanctioned; the JIT materialization path (--for-sprint backlog row →
  # file) lands a story directly in a backlog state on a sprint that's
  # already active, and dev-story has to pick it up.
  "backlog|in-progress"
  # validating (recovery + happy-path forward)
  "validating|ready-for-dev"
  "validating|backlog"
  "validating|blocked"
  # ready-for-dev
  "ready-for-dev|in-progress"
  "ready-for-dev|blocked"
  # in-progress
  "in-progress|review"
  "in-progress|blocked"
  # review
  "review|done"
  "review|blocked"
  # blocked is reversible to any prior non-terminal state
  "blocked|backlog"
  "blocked|ready-for-dev"
  "blocked|in-progress"
  "blocked|review"
  "blocked|validating"
  # done is terminal — no outbound edges
)

# Return 0 if $1 is one of the canonical states; 1 otherwise.
is_canonical_story_state() {
  local candidate="$1" s
  for s in "${STORY_CANONICAL_STATES[@]}"; do
    [ "$s" = "$candidate" ] && return 0
  done
  return 1
}

# Render the canonical enum as `value | value | value` for error messages.
canonical_story_states_hint() {
  local s out=""
  for s in "${STORY_CANONICAL_STATES[@]}"; do
    if [ -z "$out" ]; then out="$s"; else out="${out} | ${s}"; fi
  done
  printf '%s' "$out"
}

# Validate that ${from} -> ${to} is a permitted edge. Self-transitions return 0
# (caller is responsible for the no-op log when from == to). Unknown states
# return 1 with stderr citing the offending value and the canonical enum.
# Invalid edges return 1 with a stderr line citing the violated edge.
validate_story_transition() {
  local from="$1" to="$2"
  if ! is_canonical_story_state "$from"; then
    printf 'story-state-machine: error: unknown source state %q (allowed: %s)\n' \
      "$from" "$(canonical_story_states_hint)" >&2
    return 1
  fi
  if ! is_canonical_story_state "$to"; then
    printf 'story-state-machine: error: unknown target state %q (allowed: %s)\n' \
      "$to" "$(canonical_story_states_hint)" >&2
    return 1
  fi
  if [ "$from" = "$to" ]; then
    return 0
  fi
  local edge
  for edge in "${STORY_ALLOWED_EDGES[@]}"; do
    if [ "$edge" = "${from}|${to}" ]; then
      return 0
    fi
  done
  printf 'story-state-machine: error: invalid transition: %q -> %q is not in the allowed adjacency list\n' \
    "$from" "$to" >&2
  return 1
}
