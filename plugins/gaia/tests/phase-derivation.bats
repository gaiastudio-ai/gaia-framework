#!/usr/bin/env bats
# phase-derivation.bats — execution-phase partition over a candidate story set.
#
# The helper under test partitions a sprint's candidate set into execution
# phases: phase 1 is every story with no hard dependency inside the set, and a
# story whose hard dependencies all sit in phases <= N lands in phase N+1.
# Stories sharing a phase carry no ordering constraint between them, which is
# what lets a planner run them concurrently.
#
# It is a deliberate fork of the dependency-depth traversal in
# sm-capacity-check.sh: same input contract, same memoised recurrence, same
# "a dependency outside the candidate set contributes nothing" rule. Two
# deliberate divergences:
#
#   * OUTPUT  — the capacity check reduces the graph to one scalar (the longest
#     serial chain); this helper keeps the per-story value and emits the
#     partition.
#   * CYCLES  — the capacity check breaks a cycle defensively and still reports
#     a number, because a capacity advisory must never halt planning. A phase
#     partition is undefined on a cyclic graph, so a cycle here is a HARD ERROR
#     that names every member and emits NO partition at all.
#
# Part A drives the real helper directly. Part B drives the real helper AND the
# real sprint-state.sh end to end, so the seam between the two is exercised by
# an executing test rather than assumed. No mocks anywhere: the point of the
# cycle path is catching a bad graph, and a mocked surface would prove nothing.
#
# Keys in fixtures and test names are deliberately neutral (K1/K2/K3, C1/C2,
# D1/D2, EXTERNAL-1) rather than realistic story keys.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/lib/phase-derivation.sh"
  SPRINT_STATE="$SCRIPTS_DIR/sprint-state.sh"
  export SPRINT_STATE_SCRIPT_DIR="$SCRIPTS_DIR"
  export MEMORY_PATH="$TEST_TMP/_memory"
  export PROJECT_PATH="$TEST_TMP"
  # Hermetic: never inherit an ambient project from the developer's shell.
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT PROJECT_CONFIG
  ART="$TEST_TMP/docs/implementation-artifacts"
  YAML="$TEST_TMP/.gaia/state/sprint-status.yaml"
  export SCRIPT SPRINT_STATE ART YAML
  mkdir -p "$ART" "$MEMORY_PATH" "$TEST_TMP/.gaia/state"
}
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Fixture helpers. Every stories file is written under the per-test temp dir,
# so the suite never reads or writes the working tree.
# ---------------------------------------------------------------------------

# write_stories <name> <line>...  — one `KEY|DEPS|POINTS` line per argument.
# Prints the path on stdout.
write_stories() {
  local name="$1"; shift
  local path="$TEST_TMP/$name.stories"
  local line
  : > "$path"
  for line in "$@"; do
    printf '%s\n' "$line" >> "$path"
  done
  printf '%s' "$path"
}

# run_helper <stories-path> — run the real helper with $status/$output set.
run_helper() {
  run "$SCRIPT" --stories-file "$1"
}

# sorted_output — the partition sorted, so an assertion pins the phase MAP
# rather than intra-phase line order (which legitimately follows first
# appearance and therefore varies with input order).
sorted_output() {
  printf '%s\n' "$output" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//'
}

# Seed a story file whose frontmatter carries the fields inject validates.
seed_story() {
  local key="$1" sprint_id="${2:-sprint-99}"
  cat > "$ART/${key}-x.md" <<EOF
---
template: 'story'
key: "$key"
title: "Fake $key"
status: ready-for-dev
sprint_id: $sprint_id
points: 3
risk: "medium"
---

# Story: Fake $key

> **Status:** ready-for-dev
EOF
}

# Seed an active sprint yaml with no story rows.
seed_empty_yaml() {
  local sprint_id="${1:-sprint-99}"
  {
    printf 'sprint_id: "%s"\n' "$sprint_id"
    printf 'status: active\n'
    printf 'total_points: 0\n'
    printf 'goals: []\n'
    printf 'items: []\n'
    printf 'stories: []\n'
  } > "$YAML"
}

# Print the yaml block belonging to one story key: entry-scoped, so a
# per-row assertion cannot pass spuriously by matching a sibling row.
entry_block() {
  local key="$1"
  awk -v target="$key" '
    BEGIN { in_entry = 0 }
    { line = $0; sub(/\r$/, "", line) }
    line ~ /^[[:space:]]*-[[:space:]]*key:[[:space:]]*/ {
      k = line
      sub(/^[[:space:]]*-[[:space:]]*key:[[:space:]]*/, "", k)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", k)
      if (k == target) { in_entry = 1; print; next }
      in_entry = 0
      next
    }
    in_entry && line ~ /^[^[:space:]]/ { in_entry = 0 }
    in_entry { print }
  ' "$YAML"
}

# The phase value recorded on one story row, or empty when absent.
entry_phase() {
  entry_block "$1" | sed -n 's/^[[:space:]]*phase:[[:space:]]*//p'
}

# ===========================================================================
# Part A — the helper in isolation, driven directly.
# ===========================================================================

@test "no-hard-dependency stories land in phase 1 (AC1)" {
  local f
  f="$(write_stories independents 'K1||1' 'K2||2' 'K3||3')"
  run_helper "$f"
  [ "$status" -eq 0 ]
  [ "$(sorted_output)" = "K1|1 K2|1 K3|1" ]
}

@test "a linear chain assigns one phase per link (AC1)" {
  local f
  f="$(write_stories chain 'K3||1' 'K2|K3|1' 'K1|K2|1')"
  run_helper "$f"
  [ "$status" -eq 0 ]
  [ "$(sorted_output)" = "K1|3 K2|2 K3|1" ]
}

@test "a story whose deps all sit in phase N lands in phase N+1 (AC1)" {
  local f
  f="$(write_stories fanin 'K1||1' 'K2||1' 'K3|K1,K2|1')"
  run_helper "$f"
  [ "$status" -eq 0 ]
  [ "$(sorted_output)" = "K1|1 K2|1 K3|2" ]
}

@test "a hard dependency raises the phase and its absence does not (AC1)" {
  # Two files differing ONLY in the dep cell: the second is what the caller
  # writes once a soft-dep tail has been normalised away. If the dep column
  # were not load-bearing, both would agree.
  local with without
  with="$(write_stories with_dep 'K2||1' 'K1|K2|1')"
  without="$(write_stories without_dep 'K2||1' 'K1||1')"

  run_helper "$with"
  [ "$status" -eq 0 ]
  [ "$(sorted_output)" = "K1|2 K2|1" ]

  run_helper "$without"
  [ "$status" -eq 0 ]
  [ "$(sorted_output)" = "K1|1 K2|1" ]
}

@test "the dep column is read as hard dependencies only, with no soft-dep grammar (AC1)" {
  # The input contract is hard deps ONLY, already normalised by the caller —
  # matching the capacity check, which splits the dep cell on commas with zero
  # grammar handling. The helper must NOT grow its own soft-dep parser: a cell
  # still carrying a soft tail yields no usable in-set key, so the phase does
  # not rise. Pinning this keeps the grammar in one place (the caller) instead
  # of drifting into two implementations.
  local f
  f="$(write_stories soft_tail 'K2||1' 'K1|K2; soft on K3|1')"
  run_helper "$f"
  [ "$status" -eq 0 ]
  [ "$(sorted_output)" = "K1|1 K2|1" ]
}

@test "a soft tail naming an IN-SET story still does not raise the phase (AC1)" {
  # The companion above names a soft target that is ABSENT from the candidate
  # set, so the out-of-set rule returns 0 for it however the cell is parsed —
  # which means that fixture alone would pass even if the helper grew a
  # soft-dep parser. Here K3 IS in the set and sits in phase 1, so a helper
  # that mistook the soft tail for a hard dependency would put K1 in phase 2.
  #
  # That inflation is the failure this pins: it would serialize two stories the
  # planner is entitled to run concurrently, and it would do so silently.
  local f
  f="$(write_stories soft_tail_inset 'K2||1' 'K3||1' 'K1|K2; soft on K3|1')"
  run_helper "$f"
  [ "$status" -eq 0 ]
  [ "$(sorted_output)" = "K1|1 K2|1 K3|1" ]
  # Stated as its own assertion because this is the exact value that moves
  # under a soft-dep-parsing regression.
  [[ "$output" == *"K1|1"* ]]
  [[ "$output" != *"K1|2"* ]]
}

@test "the partition is emitted in ascending phase order (AC3)" {
  # Asserts RAW $output, deliberately NOT sorted_output(): sorting is exactly
  # what would discard the property under test. The helper documents its output
  # as "ascending by phase then by first-appearance order within a phase", and
  # the sprint-plan consumer renders phases in that order — a descending emit
  # would put the last phase at the top of the rendered plan.
  #
  # Three phases, so an inverted phase loop cannot coincide with the correct
  # sequence.
  local f
  f="$(write_stories order_phases 'K9||1' 'K3||1' 'K7||1' 'K5|K9|1' 'K1|K5|1')"
  run_helper "$f"
  [ "$status" -eq 0 ]

  # The phase column, read top to bottom, never decreases.
  local phases
  phases="$(printf '%s\n' "$output" | cut -d'|' -f2 | tr '\n' ' ')"
  [ "$phases" = "1 1 1 2 3 " ]
}

@test "stories within one phase are emitted in first-appearance order (AC3)" {
  # The intra-phase half of the same contract. Phase 1 holds three stories
  # declared K9, K3, K7 — non-alphabetical on purpose, so neither a sort nor a
  # reversed emit loop can reproduce the expected sequence by coincidence.
  #
  # This is what lets the sprint plan claim "intra-phase ordering preserved":
  # the planner's selection order (priority ordering) survives into the
  # rendered group only because the helper emits it unchanged.
  local f expected
  f="$(write_stories order_intraphase 'K9||1' 'K3||1' 'K7||1' 'K5|K9|1' 'K1|K5|1')"
  run_helper "$f"
  [ "$status" -eq 0 ]

  # Full raw sequence, exact.
  expected="$(printf 'K9|1\nK3|1\nK7|1\nK5|2\nK1|3')"
  [ "$output" = "$expected" ]

  # And the phase-1 block specifically, in declaration order.
  local phase1
  phase1="$(printf '%s\n' "$output" | grep '|1$' | cut -d'|' -f1 | tr '\n' ' ')"
  [ "$phase1" = "K9 K3 K7 " ]
}

@test "a dependency diamond assigns the deep node last regardless of line order (AC-EC1)" {
  # Permutation invariance ONLY. A symmetric diamond cannot distinguish
  # max-over-deps from first- or last-wins (both mid-nodes sit in phase 2),
  # which is what the asymmetric fixture below is for.
  local f expected="D|3 K1|2 K2|2 K3|1"

  f="$(write_stories diamond_a 'D|K1,K2|1' 'K1|K3|1' 'K2|K3|1' 'K3||1')"
  run_helper "$f"
  [ "$status" -eq 0 ]
  [ "$(sorted_output)" = "$expected" ]

  f="$(write_stories diamond_b 'K3||1' 'K1|K3|1' 'K2|K3|1' 'D|K1,K2|1')"
  run_helper "$f"
  [ "$status" -eq 0 ]
  [ "$(sorted_output)" = "$expected" ]

  f="$(write_stories diamond_c 'K2|K3|1' 'D|K1,K2|1' 'K1|K3|1' 'K3||1')"
  run_helper "$f"
  [ "$status" -eq 0 ]
  [ "$(sorted_output)" = "$expected" ]

  f="$(write_stories diamond_d 'K1|K3|1' 'K3||1' 'D|K1,K2|1' 'K2|K3|1')"
  run_helper "$f"
  [ "$status" -eq 0 ]
  [ "$(sorted_output)" = "$expected" ]
}

@test "a story takes the phase of its deepest dependency, not its first or last (AC1)" {
  # Asymmetric AND carrying both dep orders in one fixture. D1 lists the deep
  # dependency first, D2 lists it last; a correct max-over-deps puts BOTH at 3.
  # One order alone is not enough: D1 catches a last-wins reduction while a
  # first-wins reduction survives it, and vice versa.
  local f
  f="$(write_stories asymmetric 'K1||1' 'K2|K1|1' 'D1|K2,K1|1' 'D2|K1,K2|1')"
  run_helper "$f"
  [ "$status" -eq 0 ]
  [ "$(sorted_output)" = "D1|3 D2|3 K1|1 K2|2" ]
}

@test "the deepest dependency wins when it is listed FIRST in the cell (AC1)" {
  # Redundant cover for the max-over-dependencies recurrence, which is the core
  # of the phase rule. The companion asymmetric test carries both dep orders in
  # one fixture; this and the next split the two orders apart so the property
  # survives the loss or weakening of any single test.
  #
  # D3 depends on a phase-3 story and a phase-1 story, deeper one FIRST. A
  # last-wins reduction takes the trailing shallow dep and reports D3|2.
  local f
  f="$(write_stories deepest_first 'K4||1' 'K5|K4|1' 'K6|K5|1' 'D3|K6,K4|1')"
  run_helper "$f"
  [ "$status" -eq 0 ]
  [ "$(sorted_output)" = "D3|4 K4|1 K5|2 K6|3" ]
  [[ "$output" == *"D3|4"* ]]
  [[ "$output" != *"D3|2"* ]]
}

@test "the deepest dependency wins when it is listed LAST in the cell (AC1)" {
  # Mirror of the above: deeper dep LAST, so a first-wins reduction takes the
  # leading shallow dep and reports D4|2. Between the two, both reductions die
  # to a test that does not depend on the other fixture surviving.
  local f
  f="$(write_stories deepest_last 'K4||1' 'K5|K4|1' 'K6|K5|1' 'D4|K4,K6|1')"
  run_helper "$f"
  [ "$status" -eq 0 ]
  [ "$(sorted_output)" = "D4|4 K4|1 K5|2 K6|3" ]
  [[ "$output" == *"D4|4"* ]]
  [[ "$output" != *"D4|2"* ]]
}

@test "a dependency cycle exits non-zero and names every member of the cycle (AC2)" {
  local f
  f="$(write_stories cycle3 'K1|K2|1' 'K2|K3|1' 'K3|K1|1')"
  run_helper "$f"
  [ "$status" -eq 2 ]
  # Every member named, closing back to the re-entered node.
  [[ "$output" == *"cycle detected: K1 -> K2 -> K3 -> K1"* ]]
}

@test "a cycle emits no partition and records no phase for a cycle member (AC2)" {
  # stdout emptiness is the contract (a partition is undefined on a cyclic
  # graph). The absence of the internal-error line is the mutation signal: the
  # traversal must abandon the computation the moment a cycle is seen, so a
  # cycle's own members can never reach the memo table.
  local f
  for f in \
    "$(write_stories cyc2 'K1|K2|1' 'K2|K1|1')" \
    "$(write_stories cyc3 'K1|K2|1' 'K2|K3|1' 'K3|K1|1')" \
    "$(write_stories cycself 'K1|K1|1')"
  do
    run "$SCRIPT" --stories-file "$f"
    [ "$status" -eq 2 ]
    # No partition line whatsoever on stdout.
    run bash -c "'$SCRIPT' --stories-file '$f' 2>/dev/null"
    [ -z "$output" ]
    # And no cycle member carries a recorded phase.
    run bash -c "'$SCRIPT' --stories-file '$f' 2>&1 >/dev/null"
    [[ "$output" != *"internal error"* ]]
  done
}

@test "the cycle member set is stable across input permutations (AC2)" {
  # The rotation of the report follows input order, which is a deterministic
  # function of the file rather than of awk's hash order. The member SET —
  # what the criterion requires be named — is invariant.
  local f members
  for f in \
    "$(write_stories rot_a 'K1|K2|1' 'K2|K3|1' 'K3|K1|1')" \
    "$(write_stories rot_b 'K2|K3|1' 'K3|K1|1' 'K1|K2|1')" \
    "$(write_stories rot_c 'K3|K1|1' 'K1|K2|1' 'K2|K3|1')"
  do
    run bash -c "'$SCRIPT' --stories-file '$f' 2>&1 >/dev/null"
    [ "$status" -eq 2 ]
    members="$(printf '%s\n' "$output" \
      | sed 's/^.*cycle detected: //' \
      | tr ' ' '\n' | grep -v '^->$' | grep -v '^$' \
      | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ *$//')"
    [ "$members" = "K1 K2 K3" ]
  done
}

@test "a cycle suppresses the partition of an unrelated clean component (AC2)" {
  # The clean component is declared FIRST, so it memoises legitimately before
  # the cycle is ever reached. Without a cycle-time reset the helper would emit
  # `C1|1 C2|2` alongside the error — a PARTIAL partition, which the contract
  # forbids just as firmly as a wrong one.
  local f
  f="$(write_stories mixed 'C1||1' 'C2|C1|1' 'K1|K2|1' 'K2|K1|1')"

  run "$SCRIPT" --stories-file "$f"
  [ "$status" -eq 2 ]

  run bash -c "'$SCRIPT' --stories-file '$f' 2>/dev/null"
  [ -z "$output" ]

  run bash -c "'$SCRIPT' --stories-file '$f' 2>&1 >/dev/null"
  [[ "$output" == *"cycle detected: K1 -> K2 -> K1"* ]]
  [[ "$output" != *"internal error"* ]]
}

@test "output suppression on a cycle runs through exactly one mechanism (AC2)" {
  # Guards the SHAPE of the cycle path, not just its result. Suppression lives
  # in one place — the emit flag — and the source carries no second guard that
  # could mask its removal. An earlier design paired an END-block `if (!cycle)`
  # with a memo wipe; either alone suppressed the output, so swapping one for
  # the other was completely unobservable and the pair could rot untested.
  #
  # A source assertion is the honest tool here: the redundancy is a property of
  # the code's structure, and once removed the only way it returns is by
  # someone re-adding a guard.
  local helper="$SCRIPTS_DIR/lib/phase-derivation.sh"
  [ -r "$helper" ]

  # Exactly one place decides whether the partition is printed.
  run grep -c 'emit = 0' "$helper"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  # And no second guard wraps the emit loop.
  run grep -c 'if (!cycle)' "$helper"
  [ "$output" = "0" ]
}

@test "the cycle report starts at the first-declared member of the cycle (AC2)" {
  # Traversal order is a BEHAVIOURAL property, not merely a source property.
  # The top-level loop walks first-appearance order, so the member the report
  # STARTS at tracks the input file. Driving the graph from awk's hash order
  # instead still names the same member set and still exits 2 — only the
  # starting member exposes the difference, and only on a permutation whose
  # first line is not the key hash order happens to visit first.
  local f body expected starting
  for body in "K1|K2|1
K2|K3|1
K3|K1|1" "K2|K3|1
K3|K1|1
K1|K2|1" "K3|K1|1
K1|K2|1
K2|K3|1"
  do
    expected="${body%%|*}"
    f="$TEST_TMP/rotstart.stories"
    printf '%s\n' "$body" > "$f"

    run bash -c "'$SCRIPT' --stories-file '$f' 2>&1 >/dev/null"
    [ "$status" -eq 2 ]
    starting="$(printf '%s\n' "$output" | sed 's/^.*cycle detected: //' | awk '{print $1}')"
    [ "$starting" = "$expected" ]
  done
}

@test "a self-dependency is reported as a cycle naming the story (AC-EC2)" {
  local f
  f="$(write_stories selfdep 'K1|K1|1')"
  run_helper "$f"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cycle detected: K1 -> K1"* ]]
}

@test "an empty candidate set produces empty output and exits 0 (AC-EC3)" {
  local empty ws
  empty="$TEST_TMP/empty.stories"
  : > "$empty"
  run_helper "$empty"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  ws="$(write_stories whitespace '' '   ' '')"
  run_helper "$ws"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "every story is phase 1 when no story has a dependency (AC-EC4)" {
  local f count
  f="$(write_stories all_independent 'K1||1' 'K2||1' 'K3||1' 'K4||1' 'K5||1')"
  run_helper "$f"
  [ "$status" -eq 0 ]
  count="$(printf '%s\n' "$output" | grep -c '|1$' || true)"
  [ "$count" -eq 5 ]
  # Nothing landed in any other phase.
  [ "$(printf '%s\n' "$output" | grep -vc '|1$' || true)" -eq 0 ]
}

@test "a dependency outside the candidate set is treated as satisfied (AC5)" {
  # EXTERNAL-1 is absent from the set: closed in an earlier sprint, or simply
  # not selected. It must neither error nor raise the phase. The `K1|1`
  # assertion also pins that the partition is 1-based — an external-only
  # dependency is the exact input shape a 0-based off-by-one would expose, and
  # 0 is the one value the downstream writer rejects outright.
  local f
  f="$(write_stories external 'K1|EXTERNAL-1|1' 'K2|K1|1')"
  run_helper "$f"
  [ "$status" -eq 0 ]
  [ "$(sorted_output)" = "K1|1 K2|2" ]
  [[ "$output" != *"|0"* ]]
}

@test "the helper emits a phase above the writer ceiling unclamped, and the writer refuses it (AC1)" {
  # The helper's output domain and the writer's accepted range (1..999) are
  # coupled across two scripts that do not import each other. A 1000-link chain
  # is the shape that crosses the ceiling.
  #
  # The helper deliberately does NOT clamp: clamping would silently emit a
  # WRONG partition, whereas leaving the true value lets the writer fail loudly
  # at a validator that is already fail-closed. This test pins both halves of
  # that decision, so neither script can drift into the other's job.
  local f i
  f="$TEST_TMP/deep.stories"
  {
    printf 'K1||1\n'
    for i in $(seq 2 1000); do printf 'K%d|K%d|1\n' "$i" "$((i - 1))"; done
  } > "$f"

  run_helper "$f"
  [ "$status" -eq 0 ]
  # The true value, not a ceiling-clamped 999.
  [[ "$output" == *"K1000|1000"* ]]
  [[ "$output" != *"K1000|999"* ]]

  # And the writer refuses that value with its range diagnostic.
  seed_empty_yaml sprint-99
  seed_story K1
  run "$SPRINT_STATE" inject --story K1 --phase 1000
  [ "$status" -ne 0 ]
  [[ "$output" == *"between 1 and 999"* ]]
  # Nothing was written on the refusal.
  [ -z "$(entry_phase K1)" ]
}

@test "a missing or unreadable stories file is a usage error, not a crash (AC1)" {
  # Drives the helper's two public functions: `die` emits the diagnostic
  # through `log`, and both are named here for the public-function coverage
  # gate. They are the ONLY non-underscore functions the helper defines.
  run "$SCRIPT" --stories-file "$TEST_TMP/does-not-exist.stories"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does-not-exist.stories"* ]]
  # The diagnostic is prefixed by the script name, which is `log`'s format.
  [[ "$output" == *"phase-derivation.sh:"* ]]

  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--stories-file"* ]]

  run "$SCRIPT" --bogus-flag
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown argument"* ]]
}

# ===========================================================================
# Part B — end to end: the real helper feeding the real sprint-state.sh.
#
# These pin the seam between the two: a phase the helper derives must reach
# the sprint yaml through the documented flag. Every row is written by the
# real writer; none is hand-authored.
# ===========================================================================

@test "a derived phase reaches the sprint yaml row through inject --phase (AC3)" {
  local f line key phase
  f="$(write_stories e2e_chain 'K3||1' 'K2|K3|1' 'K1|K2|1')"
  seed_empty_yaml sprint-99
  seed_story K1; seed_story K2; seed_story K3

  run_helper "$f"
  [ "$status" -eq 0 ]

  # Feed the helper's REAL output into the REAL writer, one row at a time.
  while IFS='|' read -r key phase; do
    [ -n "$key" ] || continue
    run "$SPRINT_STATE" inject --story "$key" --phase "$phase"
    [ "$status" -eq 0 ]
  done <<< "$output"

  [ "$(entry_phase K3)" = "1" ]
  [ "$(entry_phase K2)" = "2" ]
  [ "$(entry_phase K1)" = "3" ]
}

@test "every phase the helper emits is accepted by the inject validator (AC3)" {
  # Spans phases 1..4, plus an external-only graph — the boundary shape that
  # would emit 0 under a 0-based off-by-one, which the validator rejects.
  local f key phase
  f="$(write_stories e2e_deep 'K1||1' 'K2|K1|1' 'K3|K2|1' 'K4|K3|1' 'K5||1' 'K6|EXTERNAL-1|1')"
  seed_empty_yaml sprint-99
  for key in K1 K2 K3 K4 K5 K6; do seed_story "$key"; done

  run_helper "$f"
  [ "$status" -eq 0 ]

  while IFS='|' read -r key phase; do
    [ -n "$key" ] || continue
    run "$SPRINT_STATE" inject --story "$key" --phase "$phase"
    [ "$status" -eq 0 ]
  done <<< "$output"

  [ "$(entry_phase K4)" = "4" ]
  [ "$(entry_phase K6)" = "1" ]
}

@test "the derived phase is emitted as an unquoted integer on the row (AC3)" {
  local f
  f="$(write_stories e2e_quote 'K1||1')"
  seed_empty_yaml sprint-99
  seed_story K1

  run_helper "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "K1|1" ]

  run "$SPRINT_STATE" inject --story K1 --phase 1
  [ "$status" -eq 0 ]

  # The row carries an unquoted integer, matching the points field.
  run bash -c "sed -n 's/^[[:space:]]*phase:[[:space:]]*//p' '$YAML'"
  [ "$output" = "1" ]
  run bash -c "grep -c 'phase: \"' '$YAML' || true"
  [ "$output" = "0" ]
}

@test "injecting without --phase writes no phase key at all (AC3)" {
  # The back-compat half: a sprint planned without phases must write exactly
  # the yaml it wrote before the field existed — never `phase: null`.
  seed_empty_yaml sprint-99
  seed_story K1

  run "$SPRINT_STATE" inject --story K1
  [ "$status" -eq 0 ]

  [ -z "$(entry_phase K1)" ]
  run bash -c "grep -c 'phase:' '$YAML' || true"
  [ "$output" = "0" ]
}

@test "injecting with an empty --phase value fails closed while a valid one writes (AC3)" {
  # Asserted against a tree that already HAS state, so "nothing was mutated" is
  # a real result rather than a vacuous one. The positive control proves the
  # write path is genuinely reachable on this same fixture.
  local before
  seed_empty_yaml sprint-99
  seed_story K1
  seed_story K2
  run "$SPRINT_STATE" inject --story K1 --phase 2
  [ "$status" -eq 0 ]
  before="$(cat "$YAML")"

  run "$SPRINT_STATE" inject --story K2 --phase ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"--phase"* ]]
  [ "$(cat "$YAML")" = "$before" ]

  # Positive control: the same inject with a valid phase does write.
  run "$SPRINT_STATE" inject --story K2 --phase 3
  [ "$status" -eq 0 ]
  [ "$(entry_phase K2)" = "3" ]
}

@test "phase grouping in the yaml matches the helper's partition for a diamond (AC3)" {
  local f key phase
  f="$(write_stories e2e_diamond 'D|K1,K2|1' 'K1|K3|1' 'K2|K3|1' 'K3||1')"
  seed_empty_yaml sprint-99
  for key in D K1 K2 K3; do seed_story "$key"; done

  run_helper "$f"
  [ "$status" -eq 0 ]

  while IFS='|' read -r key phase; do
    [ -n "$key" ] || continue
    run "$SPRINT_STATE" inject --story "$key" --phase "$phase"
    [ "$status" -eq 0 ]
  done <<< "$output"

  # Reading the persisted rows back reproduces the helper's grouping.
  [ "$(entry_phase K3)" = "1" ]
  [ "$(entry_phase K1)" = "2" ]
  [ "$(entry_phase K2)" = "2" ]
  [ "$(entry_phase D)" = "3" ]
}
