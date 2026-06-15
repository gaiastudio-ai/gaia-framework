#!/usr/bin/env bats
# brain-knowledge-refresh.bats — coverage for the hash-gated re-fetch lifecycle
# (scripts/brain/gaia-knowledge-refresh.sh).
#
# Behaviour under test:
#   - Skip on hash match: when re-fetched content hash matches the stored
#     content_hash, the ingested file is NOT rewritten and the brain-index
#     entry is NOT mutated.
#   - Overwrite on diff: when re-fetched content differs, the ingested file
#     is overwritten (atomic sibling tempfile + mv) and the brain-index entry's
#     content_hash and fetched_at are updated.
#   - Fetch failure: when the re-fetch fails, the entry is marked status: failed
#     and the existing stale file is preserved (no destructive delete).
#   - Idempotency: a second consecutive run over unchanged sources produces
#     zero file-mtime changes and zero brain-index diffs.
#
# Each test builds an isolated per-test project tree (mktemp -d) and sources
# gaia-knowledge-refresh.sh to call gaia_knowledge_refresh() directly.
# Network fetches are controlled via the --fetched-content seam (no live
# network in tests).

load 'test_helper.bash'

setup() {
  common_setup
  REFRESH="$SCRIPTS_DIR/brain/gaia-knowledge-refresh.sh"
  FEED="$SCRIPTS_DIR/brain/gaia-feed.sh"
  VALIDATE="$SCRIPTS_DIR/brain/validate-brain-index.sh"

  # Build an isolated project tree.
  PROJ="$TEST_TMP/proj"
  mkdir -p "$PROJ/.gaia/knowledge/ingested"

  export CLAUDE_PROJECT_ROOT="$PROJ"
  KNOW="$PROJ/.gaia/knowledge"
  MANIFEST="$KNOW/brain-index.yaml"
}

teardown() {
  unset CLAUDE_PROJECT_ROOT
  common_teardown
}

# _sha_stdin — sha256 hex digest of stdin.
_sha_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# _extract_body FILE — print post-frontmatter body (everything after second ---).
_extract_body() {
  awk 'BEGIN{n=0} /^---[[:space:]]*$/{n++; if(n==2){found=1; next}} found{print}' "$1"
}

# _get_mtime FILE — portable mtime (epoch seconds).
_get_mtime() {
  if stat -f '%m' "$1" >/dev/null 2>&1; then
    stat -f '%m' "$1"
  else
    stat -c '%Y' "$1"
  fi
}

# _seed_ingested SLUG BODY — write an ingested file + brain-index entry with
# matching content_hash. Returns the hash on stdout.
_seed_ingested() {
  local slug="$1"
  local body="$2"
  local source_url="${3:-https://example.com/${slug}}"

  local hash
  hash="$(printf '%s\n' "$body" | _sha_stdin)"

  local fetched_at="2026-06-01T00:00:00Z"
  local expires_at="2026-07-01T00:00:00Z"

  # Write the ingested file with frontmatter.
  cat > "$KNOW/ingested/${slug}.md" <<EOF
---
title: $slug
slug: $slug
ingest_source_kind: url
source_url: $source_url
fetched_at: $fetched_at
expires_at: $expires_at
content_hash: $hash
ttl_days: 30
token_estimate: 10
tags: [ingested, url]
status: current
---
$body
EOF

  # Write a brain-index.yaml with this entry.
  cat > "$MANIFEST" <<EOF
schema_version: 1
entries:
  - key: "$slug"
    source_type: ingested
    path: ".gaia/knowledge/ingested/${slug}.md"
    tags: ["ingested", "url"]
    synopsis: "Ingested document: $slug"
    edges: []
    trust:
      confidence: 0.7
      content_hash: "$hash"
      source_url: "$source_url"
      fetched_at: "$fetched_at"
      expires_at: "$expires_at"
EOF

  printf '%s' "$hash"
}

# ---- skip on hash match (no write) ----------------------------------------------

@test "refresh skips ingested source when re-fetched content hash matches stored hash" {
  local body="# Test Doc

This is the original body content that has not changed."

  local hash
  hash="$(_seed_ingested "test-skip" "$body")"

  # Capture the ingested file mtime before refresh.
  local ingested_file="$KNOW/ingested/test-skip.md"
  local mtime_before
  mtime_before="$(_get_mtime "$ingested_file")"

  # Snapshot the manifest before refresh.
  local manifest_before
  manifest_before="$(cat "$MANIFEST")"

  # Write the fetched content to a temp file (same content = same hash).
  local fetched="$TEST_TMP/fetched-content.txt"
  printf '%s\n' "$body" > "$fetched"

  # Wait 1 second to ensure mtime would differ if a write occurred.
  sleep 1

  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$REFRESH'
    gaia_knowledge_refresh --fetched-content '$fetched'
  "
  [ "$status" -eq 0 ]

  # Assert: ingested file mtime is unchanged (no rewrite).
  local mtime_after
  mtime_after="$(_get_mtime "$ingested_file")"
  [ "$mtime_before" = "$mtime_after" ]

  # Assert: brain-index is byte-identical (no mutation).
  local manifest_after
  manifest_after="$(cat "$MANIFEST")"
  [ "$manifest_before" = "$manifest_after" ]
}

# ---- overwrite on content diff (entry updated) ----------------------------------

@test "refresh overwrites ingested file and updates brain-index when content differs" {
  local original_body="# Original Doc

This is the original content."

  local hash
  hash="$(_seed_ingested "test-diff" "$original_body")"

  # Capture the original content_hash from the manifest.
  local hash_before="$hash"

  # Capture the ingested file mtime before refresh.
  local ingested_file="$KNOW/ingested/test-diff.md"
  local mtime_before
  mtime_before="$(_get_mtime "$ingested_file")"

  # The new (different) content to be fetched.
  local new_body="# Original Doc

This is UPDATED content that differs from the original."

  # Write the new fetched content to a temp file.
  local fetched="$TEST_TMP/fetched-content.txt"
  printf '%s\n' "$new_body" > "$fetched"

  # Wait 1 second so that a write produces a distinguishable mtime
  # (symmetric with the skip test, which asserts mtime unchanged).
  sleep 1

  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$REFRESH'
    gaia_knowledge_refresh --fetched-content '$fetched'
  "
  [ "$status" -eq 0 ]

  # Assert: the ingested file mtime CHANGED (the file was rewritten).
  local mtime_after
  mtime_after="$(_get_mtime "$ingested_file")"
  [ "$mtime_before" != "$mtime_after" ]

  # Assert: the ingested file now contains the new content.
  grep -q 'UPDATED content' "$ingested_file"

  # Assert: the brain-index content_hash has changed.
  local new_hash
  new_hash="$(printf '%s\n' "$new_body" | _sha_stdin)"
  grep -q "$new_hash" "$MANIFEST"

  # Assert: the old hash is no longer in the manifest.
  ! grep -q "$hash_before" "$MANIFEST"

  # Assert: fetched_at has been updated (not the old seed timestamp).
  ! grep -q '2026-06-01T00:00:00Z' "$MANIFEST" || {
    # If fetched_at still matches the old value, the entry was not updated.
    # (Allow for the case where the test runs exactly at the seed timestamp,
    # which is practically impossible.)
    local current_year
    current_year="$(date -u '+%Y')"
    grep -q "fetched_at.*${current_year}" "$MANIFEST"
  }
}

# ---- fetch failure preserves stale file + marks failed --------------------------

@test "refresh marks status: failed and preserves stale file on fetch failure" {
  local body="# Stale Doc

This stale content must be preserved on fetch failure."

  _seed_ingested "test-fail" "$body" > /dev/null

  local ingested_file="$KNOW/ingested/test-fail.md"

  # Snapshot the body content before refresh.
  local body_before
  body_before="$(awk 'BEGIN{n=0} /^---[[:space:]]*$/{n++; if(n==2){found=1; next}} found{print}' "$ingested_file")"

  # Do NOT provide --fetched-content — simulate a fetch failure by passing
  # a non-existent file path as fetched content.
  local fetched="$TEST_TMP/nonexistent-fetch-result.txt"

  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$REFRESH'
    gaia_knowledge_refresh --fetched-content '$fetched'
  "
  # The refresh should still exit 0 (partial failure is handled gracefully).
  [ "$status" -eq 0 ]

  # Assert: the stale ingested file is still present (no destructive delete).
  [ -f "$ingested_file" ]

  # Assert: the ingested file's frontmatter status is now "failed".
  # The status field lives in the ingested file's frontmatter (not the brain-index
  # trust block, which has a closed schema with additionalProperties: false).
  grep -q 'status:.*failed' "$ingested_file"

  # Assert: the stale file body content is preserved byte-identical.
  local body_after
  body_after="$(awk 'BEGIN{n=0} /^---[[:space:]]*$/{n++; if(n==2){found=1; next}} found{print}' "$ingested_file")"
  [ "$body_before" = "$body_after" ]
  grep -q 'stale content must be preserved' "$ingested_file"

  # Assert: the brain-index entry itself still exists (not deleted by the
  # failure path). A buggy impl that removed the manifest entry while keeping
  # the file would pass the file-level assertions above but fail here.
  grep -q 'test-fail' "$MANIFEST"
  grep -q 'source_type: ingested' "$MANIFEST"

  # Assert: the entry's trust block was not zeroed — content_hash is still
  # the original seeded value (the refresh did not touch the manifest entry
  # on the failure path, only the ingested file's frontmatter status).
  local original_hash
  original_hash="$(printf '%s\n' "$body_before" | _sha_stdin)"
  grep -q "$original_hash" "$MANIFEST"
}

# ---- idempotency (no spurious writes on repeat run) -----------------------------

@test "refresh is idempotent — second run over unchanged sources produces zero writes" {
  local body="# Idempotent Doc

Content for the idempotency test."

  local hash
  hash="$(_seed_ingested "test-idem" "$body")"

  # Write the fetched content (same as original).
  local fetched="$TEST_TMP/fetched-content.txt"
  printf '%s\n' "$body" > "$fetched"

  # First run.
  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$REFRESH'
    gaia_knowledge_refresh --fetched-content '$fetched'
  "
  [ "$status" -eq 0 ]

  # Capture state after first run.
  local ingested_file="$KNOW/ingested/test-idem.md"
  local mtime_after_first
  mtime_after_first="$(_get_mtime "$ingested_file")"
  local manifest_after_first
  manifest_after_first="$(cat "$MANIFEST")"

  sleep 1

  # Second run with identical content.
  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$REFRESH'
    gaia_knowledge_refresh --fetched-content '$fetched'
  "
  [ "$status" -eq 0 ]

  # Assert: file mtime unchanged between first and second run.
  local mtime_after_second
  mtime_after_second="$(_get_mtime "$ingested_file")"
  [ "$mtime_after_first" = "$mtime_after_second" ]

  # Assert: manifest byte-identical between first and second run.
  local manifest_after_second
  manifest_after_second="$(cat "$MANIFEST")"
  [ "$manifest_after_first" = "$manifest_after_second" ]
}
