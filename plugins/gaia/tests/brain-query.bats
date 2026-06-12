#!/usr/bin/env bats
# brain-query.bats — coverage for the read-only governance-envelope query
# (scripts/brain/gaia-brain-query.sh).
#
# Behaviour under test:
#   - From a seed story key, a single invocation returns the governance envelope
#     grouped by direction: UP (the governance chain — requirements, decisions,
#     parent epic), DOWN (tests + reviews), LATERAL (design). Exit 0.
#   - A partial graph degrades gracefully: an orphan node (no edges) renders a
#     non-error "(no ... edges)" line and exits 0; an unknown key is reported as
#     unresolved and still exits 0.
#   - Read-time content-hash fall-through: when a node's canonical file no longer
#     matches the stored hash (or is missing), the node is marked stale and the
#     canonical PATH is surfaced (never the stored synopsis as if current).
#   - Read-only boundary (query direction): the query never references the memory
#     tree; a memory decoy is left byte-/mtime-untouched and never appears in the
#     output.
#   - The no-vector audit passes with the new script in scope.
#
# Each test builds an isolated per-test project tree (mirroring brain-health.bats)
# and points the path helper at it via CLAUDE_PROJECT_ROOT, so the query runs on a
# fixture project and never touches the real .gaia/ tree.

load 'test_helper.bash'

setup() {
  common_setup
  REINDEX="$SCRIPTS_DIR/brain/gaia-brain-reindex.sh"
  HARVEST="$SCRIPTS_DIR/brain/harvest-edges.sh"
  QUERY="$SCRIPTS_DIR/brain/gaia-brain-query.sh"
  AUDIT="$SCRIPTS_DIR/brain/audit-no-vector-dep.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures/brain-reindex"

  PROJ="$TEST_TMP/proj"
  mkdir -p "$PROJ/.gaia"
  cp -R "$FIX/artifacts" "$PROJ/.gaia/artifacts"
  cp -R "$FIX/state"     "$PROJ/.gaia/state"
  cp -R "$FIX/memory"    "$PROJ/.gaia/memory"

  export CLAUDE_PROJECT_ROOT="$PROJ"
  KNOW="$PROJ/.gaia/knowledge"
  MANIFEST="$KNOW/brain-index.yaml"
  MEMORY_DECOY="$PROJ/.gaia/memory/validator-sidecar/ground-truth.md"

  # Build the manifest the query consumes.
  run bash "$REINDEX"
  [ "$status" -eq 0 ]

  # The reindex sweep deliberately wires an empty reviews-dir and an absent UX
  # path into its per-node harvest, so it never emits `designs` (LATERAL) or
  # `reviewed-in` (DOWN-review) edges. To exercise BOTH lateral and the review
  # DOWN edge for the primary story, additively splice those two edges into the
  # primary entry — harvested directly from the additive fixture files (a UX ref
  # and a type-first review report) so they are REAL harvested edges, not faked.
  _augment_primary_edges
}

teardown() {
  unset CLAUDE_PROJECT_ROOT
  common_teardown
}

# Re-harvest the primary story WITH the additive UX + reviews dir, then splice the
# resulting `designs` / `reviewed-in` edge lines into its manifest entry just
# before its `  trust:` block. Deterministic + idempotent within a single setup.
_augment_primary_edges() {
  local ux="$PROJ/.gaia/artifacts/creative-artifacts/ux/ux-fragment.md"
  local reviews="$PROJ/.gaia/artifacts/implementation-artifacts/epic-E777-demo/E777-S2-primary/reviews"
  local story="$PROJ/.gaia/artifacts/implementation-artifacts/epic-E777-demo/E777-S2-primary/story.md"
  local epics="$PROJ/.gaia/artifacts/planning-artifacts/epics-and-stories.md"
  local matrix="$PROJ/.gaia/artifacts/test-artifacts/strategy/traceability-matrix.md"

  # Harvest the full edge set for the primary story including UX + reviews.
  local frag
  frag="$(bash "$HARVEST" --key "E777-S2" --epics "$epics" --matrix "$matrix" \
    --frontmatter "$story" --reviews-dir "$reviews" --ux "$ux" 2>/dev/null || true)"

  # Pull ONLY the designs + reviewed-in two-line edge entries from the fragment,
  # re-indented to the manifest's 4-space edge-list form (the harvester emits a
  # 2-space form; the committed manifest nests edges one level deeper).
  local extra="$TEST_TMP/extra-edges.txt"
  : > "$extra"
  printf '%s\n' "$frag" | awk '
    /^  - type: designs$/ {
      print "    - type: designs"; getline l; sub(/^  /, "    ", l); print l; next
    }
    /^  - type: reviewed-in$/ {
      print "    - type: reviewed-in"; getline l; sub(/^  /, "    ", l); print l; next
    }
  ' >> "$extra"

  [ -s "$extra" ] || return 0

  # Splice $extra into the E777-S2 entry, right before its `  trust:` line.
  local out="$TEST_TMP/manifest-aug.yaml"
  awk -v extra="$extra" '
    $0 == "- key: \"E777-S2\"" { inentry=1 }
    inentry && /^- key:/ && $0 != "- key: \"E777-S2\"" { inentry=0 }
    inentry && $0 == "  trust:" {
      while ((getline el < extra) > 0) print el
      close(extra)
      inentry=0
    }
    { print }
  ' "$MANIFEST" > "$out"
  mv "$out" "$MANIFEST"
}

_run_query() {
  run bash "$QUERY" "$@"
}

# --- AC1: the governance envelope in one invocation ------------------------

@test "envelope returns UP, DOWN, and LATERAL edges grouped by direction" {
  _run_query "E777-S2"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TEST_TMP/env.out"
  # Direction group headers are present.
  grep -q 'UP' "$TEST_TMP/env.out"
  grep -q 'DOWN' "$TEST_TMP/env.out"
  grep -q 'LATERAL' "$TEST_TMP/env.out"
  # UP carries the governance chain (a requirement + a decision + the parent epic).
  grep -qE 'UP.*implements.*FR-901' "$TEST_TMP/env.out"
  grep -qE 'UP.*governed-by.*ADR-701' "$TEST_TMP/env.out"
  grep -qE 'UP.*decomposes.*E777([^0-9-]|$)' "$TEST_TMP/env.out"
  # DOWN carries a test (verified-by) and a review (reviewed-in).
  grep -qE 'DOWN.*verified-by.*TC-RDX-1' "$TEST_TMP/env.out"
  grep -qE 'DOWN.*reviewed-in.*security-review-E777-S2' "$TEST_TMP/env.out"
  # LATERAL carries the design edge.
  grep -qE 'LATERAL.*designs.*E777-S2' "$TEST_TMP/env.out"
}

@test "the --envelope flag is the default mode and yields identical output" {
  _run_query "E777-S2"
  [ "$status" -eq 0 ]
  local default_out="$output"
  _run_query "E777-S2" --envelope
  [ "$status" -eq 0 ]
  [ "$default_out" = "$output" ]
}

@test "the UP walk does NOT descend into sibling sub-stories via child-decomposes" {
  # E777-S2's frontmatter blocks/depends_on emit decomposes edges to sibling
  # stories (E777-S1/S4/S5). Those are NOT up the governance chain — only the
  # parent EPIC (E777) is. The envelope must not surface the siblings as UP.
  _run_query "E777-S2"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TEST_TMP/env.out"
  ! grep -qE 'UP.*E777-S1' "$TEST_TMP/env.out"
  ! grep -qE 'UP.*E777-S4' "$TEST_TMP/env.out"
  ! grep -qE 'UP.*E777-S5' "$TEST_TMP/env.out"
}

@test "envelope output is deterministic across runs" {
  _run_query "E777-S2"
  [ "$status" -eq 0 ]
  local first="$output"
  _run_query "E777-S2"
  [ "$status" -eq 0 ]
  [ "$first" = "$output" ]
}

# --- AC2: graceful degradation on a partial graph --------------------------

@test "an orphan node with no edges degrades to a non-error empty-direction view" {
  # E777-S6 is the orphan (no edges). The query must exit 0 and render a
  # non-error "(no ... edges)" line, not raise an error.
  _run_query "E777-S6"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'no .*(UP|DOWN|LATERAL).* edges|no edges'
}

@test "an unknown key is reported as unresolved and still exits 0" {
  _run_query "E999-S999"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'unresolved|not found|no .*entry'
}

@test "a missing manifest exits 0 with an explanatory line" {
  rm -f "$MANIFEST"
  _run_query "E777-S2"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'no.*manifest|not found|no brain index'
}

# --- C1: read-time content-hash fall-through -------------------------------

@test "a fresh node surfaces its synopsis (hash matches the canonical file)" {
  _run_query "E777-S2"
  [ "$status" -eq 0 ]
  # The synopsis seed line from the canonical story is surfaced, not a stale marker.
  printf '%s\n' "$output" | grep -q 'Primary reindex node'
  ! printf '%s\n' "$output" | grep -qi 'stale'
}

@test "a node whose canonical file changed is marked stale and surfaces the path" {
  # Mutate the canonical story AFTER the manifest was built so its content hash no
  # longer matches the stored trust.content_hash.
  echo "MUTATED extra line that changes the content hash" \
    >> "$PROJ/.gaia/artifacts/implementation-artifacts/epic-E777-demo/E777-S2-primary/story.md"
  _run_query "E777-S2"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TEST_TMP/env.out"
  # The stale marker is present and surfaces the canonical PATH (not inline bytes).
  grep -qi 'stale' "$TEST_TMP/env.out"
  grep -q 'E777-S2-primary/story.md' "$TEST_TMP/env.out"
}

@test "a node whose canonical file is missing is marked stale, not an error" {
  rm -f "$PROJ/.gaia/artifacts/implementation-artifacts/epic-E777-demo/E777-S2-primary/story.md"
  _run_query "E777-S2"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qi 'stale'
}

# --- Read-only boundary hardening: out-of-bounds manifest path is never read --

@test "a manifest path that escapes the project root is treated as unverifiable and never read" {
  # Defense-in-depth: the manifest is trusted, but the read-only boundary is the
  # core contract, so a `path` that traverses OUTSIDE the project root via `..`
  # must NOT be opened — the node degrades to stale/unverifiable and the query
  # still exits 0. SYNTHETIC out-of-bounds path; no real out-of-tree file is read.
  #
  # Plant a decoy OUTSIDE the project root with a KNOWN content + matching hash,
  # then rewrite E777-S2's manifest path to a `..`-traversal that resolves to it.
  # If the boundary check were absent, the query would read the decoy and the
  # hash would MATCH (so the node would render fresh). With the check, it never
  # opens the decoy → the node renders stale and surfaces the (escaping) path.
  local decoy="$TEST_TMP/outside-decoy.md"
  printf 'OUT-OF-BOUNDS DECOY CONTENT\n' > "$decoy"
  local decoy_hash
  if command -v sha256sum >/dev/null 2>&1; then
    decoy_hash="$(sha256sum "$decoy" | awk '{print $1}')"
  else
    decoy_hash="$(shasum -a 256 "$decoy" | awk '{print $1}')"
  fi

  # A relative `..` path from the project root up to $TEST_TMP/outside-decoy.md.
  local escape_path="../outside-decoy.md"

  # Rewrite E777-S2's path + content_hash in the manifest in place.
  local out="$TEST_TMP/manifest-escape.yaml"
  awk -v ep="$escape_path" -v eh="$decoy_hash" '
    $0 == "- key: \"E777-S2\"" { inentry=1 }
    inentry && /^- key:/ && $0 != "- key: \"E777-S2\"" { inentry=0 }
    inentry && /^  path:/ { print "  path: \"" ep "\""; next }
    inentry && /^    content_hash:/ { print "    content_hash: \"" eh "\""; next }
    { print }
  ' "$MANIFEST" > "$out"
  mv "$out" "$MANIFEST"

  _run_query "E777-S2"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TEST_TMP/env.out"
  # The decoy's content is NEVER surfaced (we never read it).
  ! grep -q 'OUT-OF-BOUNDS DECOY CONTENT' "$TEST_TMP/env.out"
  # The node is treated as stale/unverifiable despite the hash "matching" the
  # decoy — because the boundary check refused to open the out-of-root file.
  grep -qi 'stale' "$TEST_TMP/env.out"
}

@test "a manifest path that points into the sidecar memory subtree is never read" {
  # Companion boundary assertion: a `path` inside the agent-sidecar tree must be
  # refused even though it resolves UNDER the project root. Plant a decoy in the
  # sidecar with a matching hash; the query must NOT read it (renders stale).
  local sidecar="$PROJ/.gaia/memory/sidecar-decoy.md"
  printf 'SIDECAR DECOY CONTENT\n' > "$sidecar"
  local decoy_hash
  if command -v sha256sum >/dev/null 2>&1; then
    decoy_hash="$(sha256sum "$sidecar" | awk '{print $1}')"
  else
    decoy_hash="$(shasum -a 256 "$sidecar" | awk '{print $1}')"
  fi

  # Path relative to the project root, landing inside the sidecar subtree.
  local mem_path=".gaia/memory/sidecar-decoy.md"

  local out="$TEST_TMP/manifest-mem.yaml"
  awk -v ep="$mem_path" -v eh="$decoy_hash" '
    $0 == "- key: \"E777-S2\"" { inentry=1 }
    inentry && /^- key:/ && $0 != "- key: \"E777-S2\"" { inentry=0 }
    inentry && /^  path:/ { print "  path: \"" ep "\""; next }
    inentry && /^    content_hash:/ { print "    content_hash: \"" eh "\""; next }
    { print }
  ' "$MANIFEST" > "$out"
  mv "$out" "$MANIFEST"

  _run_query "E777-S2"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TEST_TMP/env.out"
  ! grep -q 'SIDECAR DECOY CONTENT' "$TEST_TMP/env.out"
  grep -qi 'stale' "$TEST_TMP/env.out"
}

# --- CR: --search with no term yields a friendly usage error, not a crash -----

@test "the --search mode with no trailing term exits with a friendly usage error" {
  # Under `set -u` a bare --search must NOT abort with an unbound-variable crash;
  # it must surface the usage error and a non-zero usage exit (2).
  _run_query "E777-S2" --search
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qi 'search requires a term'
  ! printf '%s\n' "$output" | grep -qi 'unbound variable'
}

# --- AC4: read-only boundary, query direction ------------------------------

@test "the query source never references the memory tree" {
  # Static guard: the query's OWN source must not write the memory path literal
  # nor echo the memory env var. (Sourcing gaia-paths.sh exports GAIA_MEMORY_DIR;
  # the boundary is that the QUERY never touches it.)
  ! grep -qE '\.gaia/memory|GAIA_MEMORY_DIR|MEMORY_PATH' "$QUERY"
}

@test "the query source references the knowledge, artifacts, and state roots only" {
  # The read roots are knowledge (manifest) + artifacts/state (canonical files
  # for the C1 hash check). It must reference those dir constants, not memory.
  grep -qE 'GAIA_KNOWLEDGE_DIR' "$QUERY"
  grep -qE 'GAIA_ARTIFACTS_DIR|GAIA_STATE_DIR' "$QUERY"
}

# bats test_tags=hardware-dependent
@test "a query run leaves the memory decoy untouched and absent from output" {
  local before after
  before="$(stat -c %Y "$MEMORY_DECOY" 2>/dev/null || stat -f %m "$MEMORY_DECOY")"
  _run_query "E777-S2"
  [ "$status" -eq 0 ]
  after="$(stat -c %Y "$MEMORY_DECOY" 2>/dev/null || stat -f %m "$MEMORY_DECOY")"
  [ "$before" = "$after" ]
  # And the memory decoy never surfaces in the query output.
  ! printf '%s\n' "$output" | grep -q 'validator-sidecar'
  ! printf '%s\n' "$output" | grep -q 'DECOY'
}

# --- AC4: read-only boundary, refresh direction (pin existing behaviour) ----

@test "the ground-truth refresh skill never references the knowledge tree" {
  # Reverse-direction static guard: the refresh side must not read the knowledge
  # store. This pins the confirmed-clean state — no production change is expected.
  local refresh_dir="$BATS_TEST_DIRNAME/../skills/gaia-refresh-ground-truth"
  [ -d "$refresh_dir" ]
  ! grep -rqE 'knowledge|brain-index|GAIA_KNOWLEDGE' "$refresh_dir"
}

# --- Sibling modes: --health delegation + thin --search --------------------

@test "the --health mode delegates to the unlinked-node view and exits 0" {
  _run_query --health
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qiE 'unlinked|gap'
}

@test "the --search mode greps the indexed synopses and exits 0" {
  _run_query --search "Primary"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'E777-S2'
}

# --- AC3: no vector / embedding / external dependency ----------------------

@test "the no-vector audit passes with the query script in scope" {
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
}
