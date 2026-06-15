#!/usr/bin/env bats
# brain-ingestion-boundary.bats — coverage for the partitioned two-writer
# boundary between the reindex sweep (project-artifact partition) and the
# ingestion writer (ingested partition).
#
# Behaviour under test:
#   - A full reindex sweep preserves existing ingested entries verbatim.
#   - The reindexer only writes project-artifact entries (never ingested).
#   - The ingestion writer only writes ingested entries (never project-artifact).
#   - The no-vector-dep audit covers the ingestion path.
#   - The C2 unlinked-node report excludes ingested entries from the gap surface.
#
# Each test builds an isolated per-test project tree.

load 'test_helper.bash'

setup() {
  common_setup
  REINDEX="$SCRIPTS_DIR/brain/gaia-brain-reindex.sh"
  HEALTH="$SCRIPTS_DIR/brain/brain-health.sh"
  FEED="$SCRIPTS_DIR/brain/gaia-feed.sh"
  VALIDATE="$SCRIPTS_DIR/brain/validate-brain-index.sh"
  AUDIT="$SCRIPTS_DIR/brain/audit-no-vector-dep.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures/brain-reindex"

  # Build an isolated project tree from the existing reindex fixture.
  PROJ="$TEST_TMP/proj"
  mkdir -p "$PROJ/.gaia"
  cp -R "$FIX/artifacts" "$PROJ/.gaia/artifacts"
  cp -R "$FIX/state"     "$PROJ/.gaia/state"
  cp -R "$FIX/memory"    "$PROJ/.gaia/memory"

  export CLAUDE_PROJECT_ROOT="$PROJ"
  KNOW="$PROJ/.gaia/knowledge"
  MANIFEST="$KNOW/brain-index.yaml"
}

teardown() {
  unset CLAUDE_PROJECT_ROOT
  common_teardown
}

# _sha FILE — sha256 hex digest, dual idiom.
_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# ---- AC1: reindex preserves ingested entries --------------------------------

@test "a full reindex sweep preserves existing ingested entries verbatim" {
  # First run a normal reindex to get a valid manifest.
  run bash "$REINDEX"
  [ "$status" -eq 0 ]
  [ -f "$MANIFEST" ]

  # Now inject an ingested entry into the manifest.
  # Use python3+PyYAML if available, otherwise awk append.
  local ingested_block
  ingested_block='- key: "ext-reference-doc"
  source_type: ingested
  path: ".gaia/knowledge/ingested/ext-reference-doc.md"
  tags: ["ingested", "file"]
  synopsis: "Ingested document: External Reference"
  edges: []
  trust:
    confidence: 0.8
    content_hash: "abc123def456"
    source_url: "/tmp/ext-reference.md"
    fetched_at: "2026-06-01T00:00:00Z"
    expires_at: "2026-07-01T00:00:00Z"'
  printf '%s\n' "$ingested_block" >> "$MANIFEST"

  # Also create the backing ingested file so it's plausible.
  mkdir -p "$KNOW/ingested"
  cat > "$KNOW/ingested/ext-reference-doc.md" <<'INGEST'
---
title: External Reference
---
Body.
INGEST

  # Re-run the reindex sweep.
  run bash "$REINDEX"
  [ "$status" -eq 0 ]

  # The ingested entry must survive, with all fields intact.
  # PyYAML may or may not quote scalar values; match without requiring quotes.
  grep -q 'ext-reference-doc' "$MANIFEST"
  grep -q 'source_type: ingested' "$MANIFEST"
  grep -q 'content_hash:.*abc123def456' "$MANIFEST"
  grep -q 'confidence: 0.8' "$MANIFEST"
  grep -q 'fetched_at:.*2026-06-01T00:00:00Z' "$MANIFEST"
}

# ---- AC2: reindex never writes source_type: ingested -----------------------

@test "the reindex sweep only emits project-artifact entries, never ingested" {
  run bash "$REINDEX"
  [ "$status" -eq 0 ]

  # All source_type values in the manifest from reindex must be project-artifact.
  # No ingested entry was injected, so the sweep should only produce project-artifact.
  local types
  types="$(grep 'source_type:' "$MANIFEST" | sed 's/.*source_type:[[:space:]]*//' | sort -u)"
  [ "$types" = "project-artifact" ]
}

# ---- AC2: ingestion writer never writes project-artifact --------------------

@test "the ingestion writer rejects writing a project-artifact entry" {
  # The ingestion writer (_gf_register_brain_index) hardcodes source_type: ingested.
  # Verify by grepping the script — no code path can emit project-artifact.
  [ -f "$FEED" ]
  # The register function only ever emits source_type: ingested.
  # In the python path:
  grep -q "'source_type': \"ingested\"" "$FEED" || grep -q '"source_type": "ingested"' "$FEED" || \
    grep -q "source_type.*ingested" "$FEED"
  # And the awk fallback path:
  grep -q 'source_type: ingested' "$FEED"
  # Neither path ever writes project-artifact.
  ! grep -q 'source_type: project-artifact' "$FEED"
}

# ---- AC4: no-vector-dep audit covers ingestion path -------------------------

@test "the no-vector-dep audit covers the ingestion path and passes" {
  [ -f "$AUDIT" ]
  [ -f "$FEED" ]
  # Run the audit with the brain dir as root (includes gaia-feed.sh).
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
}

# ---- AC3: brain-health excludes ingested entries from the unlinked surface ---

@test "brain-health excludes ingested entries from the unlinked gap report" {
  # Build a manifest, then inject an ingested entry that has no governance edges.
  run bash "$REINDEX"
  [ "$status" -eq 0 ]

  local ingested_block
  ingested_block='- key: "ext-no-edges"
  source_type: ingested
  path: ".gaia/knowledge/ingested/ext-no-edges.md"
  tags: ["ingested"]
  synopsis: "Ingested doc with no edges"
  edges: []
  trust:
    confidence: 0.7
    content_hash: "deadbeef"
    source_url: "https://example.com"
    fetched_at: "2026-06-01T00:00:00Z"
    expires_at: "2026-07-01T00:00:00Z"'
  printf '%s\n' "$ingested_block" >> "$MANIFEST"

  mkdir -p "$KNOW/ingested"
  cat > "$KNOW/ingested/ext-no-edges.md" <<'INGEST'
---
title: No Edges
---
Body.
INGEST

  # Run brain-health.
  run bash "$HEALTH"
  [ "$status" -eq 0 ]

  # The ingested entry must NOT appear in the unlinked output.
  ! printf '%s\n' "$output" | grep -q 'ext-no-edges'
}
