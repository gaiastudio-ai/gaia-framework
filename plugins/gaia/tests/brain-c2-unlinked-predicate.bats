#!/usr/bin/env bats
# brain-c2-unlinked-predicate.bats — coverage for the four-source "is this node
# linked?" predicate (binding condition C2) in the seven-edge harvester
# (scripts/brain/harvest-edges.sh).
#
# A node is LINKED if ANY of the four sources connect it:
#   1. frontmatter `traces_to:` is non-empty;
#   2. frontmatter `epic:` is present;
#   3. an epics-prose Allocates row references the node key;
#   4. a matrix Story mapping references the node key.
# A node is UNLINKED only when ALL FOUR miss — then it ships `edges: []` and
# `unlinked: true`. A node is NEVER dropped, and an unlinked node is NEVER a
# non-zero exit.

load 'test_helper.bash'

setup() {
  common_setup
  HARVEST="$SCRIPTS_DIR/brain/harvest-edges.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures/brain-harvest"
  EPICS="$FIX/epics-fragment.md"
  MATRIX="$FIX/traceability-fragment.md"
  FM_FULL="$FIX/story-frontmatter-full.md"
  FM_EMPTY="$FIX/story-frontmatter-empty.md"
  FM_TRACES="$FIX/story-frontmatter-traces-only.md"
  FM_ZERO="$FIX/story-frontmatter-zerolink.md"
  REVIEWS="$FIX/reviews"
  UX="$FIX/ux-fragment.md"
}

teardown() { common_teardown; }

_has_pyyaml() {
  command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Source 3 only — epics-prose Allocates row, empty frontmatter traces.
# ---------------------------------------------------------------------------

@test "a node linked only via the epics-prose Allocates row is not unlinked" {
  # Frontmatter has NO epic and empty traces; the matrix is suppressed
  # (/dev/null). Only the epics-prose Allocates row links the node.
  run bash "$HARVEST" \
    --key "E777-S2" \
    --epics "$EPICS" \
    --matrix /dev/null \
    --frontmatter "$FIX/story-frontmatter-zerolink.md"
  # Note: the zerolink frontmatter carries no epic and empty traces, so it
  # contributes no link; the link here comes purely from the epics-prose
  # Allocates row for E777-S2.
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^unlinked: false$'
}

# ---------------------------------------------------------------------------
# Source 4 only — matrix Story mapping, empty frontmatter, no prose.
# ---------------------------------------------------------------------------

@test "a node linked only via the traceability matrix is not unlinked" {
  run bash "$HARVEST" \
    --key "E777-S2" \
    --epics /dev/null \
    --matrix "$MATRIX" \
    --frontmatter "$FIX/story-frontmatter-zerolink.md"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^unlinked: false$'
}

# ---------------------------------------------------------------------------
# Source 2 only — frontmatter epic present, empty traces, no prose, no matrix.
# ---------------------------------------------------------------------------

@test "a node linked only via the frontmatter epic field is not unlinked" {
  if ! _has_pyyaml; then skip "no python3+PyYAML on host"; fi
  run bash "$HARVEST" \
    --key "E777-S2" \
    --epics /dev/null \
    --matrix /dev/null \
    --frontmatter "$FM_EMPTY"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^unlinked: false$'
}

# ---------------------------------------------------------------------------
# Source 1 only — frontmatter traces_to non-empty.
# ---------------------------------------------------------------------------

@test "a node linked only via a non-empty frontmatter traces_to is not unlinked" {
  if ! _has_pyyaml; then skip "no python3+PyYAML on host"; fi
  # The traces-only frontmatter carries a non-empty traces_to BUT no epic field
  # and no blocks/depends_on links; epics + matrix are suppressed (/dev/null).
  # The ONLY possible linking signal is the frontmatter traces_to source, so
  # this test genuinely fails if the traces_to check breaks — it cannot pass via
  # the epic source the way the full fixture (epic + traces) would.
  run bash "$HARVEST" \
    --key "E777-S2" \
    --epics /dev/null \
    --matrix /dev/null \
    --frontmatter "$FM_TRACES"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^unlinked: false$'
}

# ---------------------------------------------------------------------------
# Zero-link node — all four sources miss.
# ---------------------------------------------------------------------------

@test "a zero-link node ships edges:[] and unlinked:true" {
  if ! _has_pyyaml; then skip "no python3+PyYAML on host"; fi
  run bash "$HARVEST" \
    --key "E777-S404" \
    --epics "$EPICS" \
    --matrix "$MATRIX" \
    --frontmatter "$FM_ZERO"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^edges: \[\]$'
  printf '%s\n' "$output" | grep -q '^unlinked: true$'
}

@test "a zero-link node is emitted, never dropped, and exits 0" {
  if ! _has_pyyaml; then skip "no python3+PyYAML on host"; fi
  run bash "$HARVEST" \
    --key "E777-S404" \
    --epics "$EPICS" \
    --matrix "$MATRIX" \
    --frontmatter "$FM_ZERO"
  [ "$status" -eq 0 ]
  # The fragment is non-empty (the node is emitted, not silently dropped).
  [ -n "$output" ]
  printf '%s\n' "$output" | grep -q '^unlinked:'
}
