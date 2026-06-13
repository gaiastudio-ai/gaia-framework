#!/usr/bin/env bats
# brain-harvest-edges.bats — coverage for the seven-edge harvester library
# (scripts/brain/harvest-edges.sh). The harvester derives all seven typed
# governance edges for a single node from the project's existing artifacts and
# emits a single-node manifest fragment (an `edges:` list + an `unlinked:` bool)
# on stdout. It writes nothing to the manifest (that is the reindex sweep's job).
#
# Behaviour under test:
#   - The emitter produces exactly the seven closed-enum edge types and refuses
#     any other type (an unknown type is dropped with a warning, never emitted).
#   - `implements` is harvested from epics-prose Allocates bullets and the
#     traceability-matrix requirement-to-story column — NEVER from frontmatter.
#   - The frontmatter-sourced edges (traces-to / decomposes / governed-by) parse
#     from the story's own frontmatter fields.
#   - `verified-by` parses the per-story matrix verification row.
#   - `reviewed-in` parses type-FIRST review filenames (incl. slug-prefixed),
#     excluding summary / bare-review / evidence / legacy key-first siblings.
#   - `designs` reads UX artifact references; absent is a clean exit 0.
#   - Allocation tokens split requirement-shaped (-> implements) from
#     decision-shaped (-> governed-by); parenthetical glosses are stripped.
#   - Whole-token key matching: a node key never matches a superstring key.
#   - The fragment is deterministic: stable order + de-dup across input orderings.
#
# The frontmatter reader prefers python3+PyYAML (mirroring the sibling
# validate-brain-index.sh) with a grep/sed inline-list fallback; tests that
# require the structured reader are guarded with a backend skip.

load 'test_helper.bash'

setup() {
  common_setup
  HARVEST="$SCRIPTS_DIR/brain/harvest-edges.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures/brain-harvest"
  EPICS="$FIX/epics-fragment.md"
  MATRIX="$FIX/traceability-fragment.md"
  FM_FULL="$FIX/story-frontmatter-full.md"
  FM_EMPTY="$FIX/story-frontmatter-empty.md"
  FM_ZERO="$FIX/story-frontmatter-zerolink.md"
  REVIEWS="$FIX/reviews"
  UX="$FIX/ux-fragment.md"
}

teardown() { common_teardown; }

# Does the host have python3 + PyYAML for the structured frontmatter reader?
_has_pyyaml() {
  command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1
}

# Full-source harvest of the primary node, used by most assertions.
_harvest_primary() {
  run bash "$HARVEST" \
    --key "E777-S2" \
    --epics "$EPICS" \
    --matrix "$MATRIX" \
    --frontmatter "$FM_FULL" \
    --reviews-dir "$REVIEWS" \
    --ux "$UX"
}

# Assert the fragment carries an edge of the given type+target.
_has_edge() {
  local etype="$1" target="$2"
  # The emitter renders one edge as two adjacent lines:
  #   - type: <etype>
  #     target: "<target>"
  # The target is a double-quoted YAML scalar (quoting is required so a target
  # containing a ': ' does not corrupt the manifest YAML).
  printf '%s\n' "$output" | awk -v t="$etype" -v g="$target" '
    $0 ~ ("- type: " t "$") { seen_type=1; next }
    seen_type && $0 ~ ("target: \"" g "\"$") { found=1 }
    seen_type { seen_type=0 }
    END { exit (found ? 0 : 1) }
  '
}

# ---------------------------------------------------------------------------
# AC1 — closed enum of exactly seven edge types; an eighth is rejected.
# ---------------------------------------------------------------------------

@test "the script exists and is syntactically valid bash" {
  [ -f "$HARVEST" ]
  run bash -n "$HARVEST"
  [ "$status" -eq 0 ]
}

@test "the emitter accepts each of the seven canonical edge types" {
  # shellcheck disable=SC1090
  source "$HARVEST"
  local t
  for t in implements traces-to decomposes governed-by verified-by reviewed-in designs; do
    run _is_valid_edge_type "$t"
    [ "$status" -eq 0 ]
  done
}

@test "the emitter rejects an eighth, unknown edge type" {
  # shellcheck disable=SC1090
  source "$HARVEST"
  run _is_valid_edge_type "cites"
  [ "$status" -ne 0 ]
}

@test "an unknown edge type is dropped with a warning, never emitted" {
  # shellcheck disable=SC1090
  source "$HARVEST"
  # _emit_edge refuses an invalid type: it returns non-zero, warns on stderr,
  # and emits no edge line. (bats folds stderr into $output, so the warning
  # text — which names the rejected type — is expected to appear there; what
  # must NOT appear is an actual `- type: <bad>` edge line.)
  run _emit_edge "inspired-by" "E777-S9"
  [ "$status" -ne 0 ]
  ! printf '%s\n' "$output" | grep -q '^- type: inspired-by'
  printf '%s\n' "$output" | grep -q 'WARNING'
}

# ---------------------------------------------------------------------------
# AC2 — `implements` from prose + matrix, NEVER from frontmatter.
# ---------------------------------------------------------------------------

@test "implements edges are harvested from the epics-prose Allocates bullet" {
  _harvest_primary
  [ "$status" -eq 0 ]
  _has_edge "implements" "FR-901"
  _has_edge "implements" "NFR-310"
}

@test "implements edges are harvested from the matrix requirement-to-story column" {
  _harvest_primary
  [ "$status" -eq 0 ]
  # FR-902 maps the primary node in the matrix but NOT in the prose Allocates
  # bullet — proving the matrix source is read.
  _has_edge "implements" "FR-902"
}

@test "implements edges are produced even with no frontmatter source (negative pin)" {
  # Point the frontmatter arg at /dev/null: the implements edge MUST still be
  # produced from prose + matrix. Any regression that wires implements to
  # frontmatter yields zero edges here and fails this pin.
  run bash "$HARVEST" \
    --key "E777-S2" \
    --epics "$EPICS" \
    --matrix "$MATRIX" \
    --frontmatter /dev/null \
    --reviews-dir "$REVIEWS" \
    --ux "$UX"
  [ "$status" -eq 0 ]
  _has_edge "implements" "FR-901"
}

@test "a glossed allocation token is stripped to its bare target" {
  _harvest_primary
  # The prose bullet reads `FR-901 (master harvest policy)`; the emitted target
  # is the bare `FR-901`, not the glossed string.
  _has_edge "implements" "FR-901"
  ! printf '%s\n' "$output" | grep -q 'master harvest policy'
}

@test "a decision-shaped allocation token routes to governed-by, not implements" {
  _harvest_primary
  # The prose bullet mixes FR-901/NFR-310 with ADR-701. The ADR token must NOT
  # become an implements edge; it must become a governed-by edge.
  ! _has_edge "implements" "ADR-701"
  _has_edge "governed-by" "ADR-701"
}

@test "whole-token key matching: the near-miss superstring key does not leak in" {
  _harvest_primary
  # FR-999 / FR-555 belong to the near-miss + unrelated nodes only. They must
  # never appear in the primary node's edge set.
  ! _has_edge "implements" "FR-999"
  ! _has_edge "implements" "FR-555"
}

# ---------------------------------------------------------------------------
# AC3 — frontmatter-sourced edges + reviewed-in type-first filenames.
# ---------------------------------------------------------------------------

@test "traces-to edges are sourced from the frontmatter traces_to field" {
  if ! _has_pyyaml; then skip "no python3+PyYAML on host"; fi
  _harvest_primary
  _has_edge "traces-to" "FR-901"
  _has_edge "traces-to" "ADR-701"
}

@test "decomposes edges are sourced from frontmatter epic + blocks + depends_on" {
  if ! _has_pyyaml; then skip "no python3+PyYAML on host"; fi
  _harvest_primary
  _has_edge "decomposes" "E777"      # epic membership
  _has_edge "decomposes" "E777-S4"   # a blocks target
  _has_edge "decomposes" "E777-S1"   # a depends_on target
}

@test "governed-by edges are the ADR-shaped subset of frontmatter traces_to" {
  if ! _has_pyyaml; then skip "no python3+PyYAML on host"; fi
  _harvest_primary
  _has_edge "governed-by" "ADR-701"
  _has_edge "governed-by" "ADR-702"
  # A requirement-shaped traces_to token is NOT a governed-by edge.
  ! _has_edge "governed-by" "FR-901"
}

@test "reviewed-in parses the six type-first review filenames" {
  _harvest_primary
  _has_edge "reviewed-in" "code-review-E777-S2"
  _has_edge "reviewed-in" "qa-tests-E777-S2"
  _has_edge "reviewed-in" "security-review-E777-S2"
  _has_edge "reviewed-in" "test-automate-review-E777-S2"
  _has_edge "reviewed-in" "test-review-E777-S2"
  _has_edge "reviewed-in" "performance-review-E777-S2"
}

@test "reviewed-in matches a slug-prefixed review filename (suffix-anchored)" {
  _harvest_primary
  _has_edge "reviewed-in" "align-research-slug-with-filename-performance-review-E777-S2"
}

@test "reviewed-in excludes summary / bare-review / evidence / key-first siblings" {
  _harvest_primary
  ! printf '%s\n' "$output" | grep -q 'review-summary'
  ! printf '%s\n' "$output" | grep -q 'execution-evidence'
  # The bare `*-review-<KEY>.md` whose review token is not an allowlisted type
  # must be excluded.
  ! _has_edge "reviewed-in" "align-research-slug-with-filename-review-E777-S2"
}

# ---------------------------------------------------------------------------
# verified-by — per-STORY matrix shape only.
# ---------------------------------------------------------------------------

@test "verified-by parses the per-story matrix verification row" {
  _harvest_primary
  _has_edge "verified-by" "TC-HARV-1"
  _has_edge "verified-by" "TC-HARV-2"
  # The near-miss row's test must not leak into the primary node.
  ! _has_edge "verified-by" "TC-HARV-99"
}

# ---------------------------------------------------------------------------
# designs — UX refs; present and graceful-absent.
# ---------------------------------------------------------------------------

@test "designs edge is harvested from a UX artifact reference" {
  _harvest_primary
  _has_edge "designs" "E777-S2"
}

@test "a missing UX source degrades gracefully to a clean exit" {
  run bash "$HARVEST" \
    --key "E777-S2" \
    --epics "$EPICS" \
    --matrix "$MATRIX" \
    --frontmatter "$FM_FULL" \
    --reviews-dir "$REVIEWS" \
    --ux "/nonexistent/ux-fragment.md"
  [ "$status" -eq 0 ]
  ! _has_edge "designs" "E777-S2"
}

# ---------------------------------------------------------------------------
# Determinism — stable order + de-dup, byte-identical across runs.
# ---------------------------------------------------------------------------

@test "the emitted fragment is byte-identical across repeated harvests" {
  _harvest_primary
  local first="$output"
  _harvest_primary
  [ "$output" = "$first" ]
}

@test "edges are de-duplicated and sorted deterministically" {
  _harvest_primary
  # FR-901 appears in both the prose Allocates bullet AND the matrix
  # requirement-to-story column; it must yield exactly ONE implements edge, not
  # two. (FR-901 also legitimately appears as a distinct traces-to edge from
  # frontmatter — a different edge type sharing a target is not a duplicate, so
  # this assertion is scoped to the implements edge only.)
  local count
  count="$(printf '%s\n' "$output" | awk '
    /^  - type: implements$/ { it = 1; next }
    it && /^    target: "FR-901"$/ { n++ }
    { it = 0 }
    END { print n + 0 }
  ')"
  [ "$count" -eq 1 ]
}
