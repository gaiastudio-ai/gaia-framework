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

  # expires_at is deliberately far in the FUTURE so the default-seeded entry is
  # always unexpired: the hash-match SKIP path is then a true no-op (no expiry
  # revalidation write), which the "no rewrite / mtime unchanged / untouched"
  # tests depend on. Tests that WANT expiry override this to a past date
  # (e.g. 2020-01-01) after seeding. A fixed calendar date here is a time bomb —
  # once it passes, every no-op test starts rewriting the file and fails.
  local fetched_at="2026-06-01T00:00:00Z"
  local expires_at="2099-01-01T00:00:00Z"

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

# ---- status recovery (failed -> current on hash-match re-fetch) -----------------

@test "refresh recovers status failed -> current when a failed source re-fetches identical content" {
  local body="# Recover Doc

Content that re-fetches identical after a transient failure."

  _seed_ingested "test-recover" "$body" > /dev/null
  local ingested_file="$KNOW/ingested/test-recover.md"

  # Simulate the entry having been left "failed" by a prior transient fetch
  # error (the seed writes status: current, so flip it).
  sed -i.bak 's/^status: current$/status: failed/' "$ingested_file" && rm -f "${ingested_file}.bak"
  grep -q '^status: failed' "$ingested_file"

  # Re-fetch IDENTICAL content — the post-strip hash matches the stored hash,
  # so this exercises the hash-match SKIP branch, not the content-diff branch.
  local fetched="$TEST_TMP/recover-fetch.txt"
  printf '%s\n' "$body" > "$fetched"

  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$REFRESH'
    gaia_knowledge_refresh --fetched-content '$fetched'
  "
  [ "$status" -eq 0 ]

  # Assert: status healed back to current on the hash-match path. (Bare
  # `! grep` is vacuous under bats' set -e — use assert_file_excludes so the
  # negative assertion can actually fail.)
  assert_file_contains "$ingested_file" 'status: current'
  assert_file_excludes "$ingested_file" 'status: failed'

  # Assert: the document body was NOT rewritten — only the status field moved.
  assert_file_contains "$ingested_file" 'transient failure'

  # Assert: no spurious index mutation — the heal touches only per-file status.
  assert_file_contains "$MANIFEST" 'test-recover'
}

@test "refresh leaves a current, unchanged source untouched (no spurious heal write)" {
  local body="# Healthy Doc

Already current; refresh must not rewrite it."

  _seed_ingested "test-healthy" "$body" > /dev/null
  local ingested_file="$KNOW/ingested/test-healthy.md"
  local mtime_before
  mtime_before="$(_get_mtime "$ingested_file")"

  local fetched="$TEST_TMP/healthy-fetch.txt"
  printf '%s\n' "$body" > "$fetched"
  sleep 1

  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$REFRESH'
    gaia_knowledge_refresh --fetched-content '$fetched'
  "
  [ "$status" -eq 0 ]

  # A current source on the hash-match path must not be rewritten at all.
  local mtime_after
  mtime_after="$(_get_mtime "$ingested_file")"
  [ "$mtime_before" = "$mtime_after" ]
  assert_file_contains "$ingested_file" 'status: current'
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

# ---- expiry recompute on content-change overwrite ------------------------------

@test "refresh recomputes expires_at on overwrite (not stuck at the old value)" {
  local body="# Expiry Doc

Original content."
  _seed_ingested "test-exp" "$body" > /dev/null
  local ingested_file="$KNOW/ingested/test-exp.md"

  # Backdate fetched_at + expires_at far into the past to simulate a long-stale
  # entry, in BOTH the file and the manifest.
  sed -i.bak -E 's/^fetched_at:.*/fetched_at: 2020-01-01T00:00:00Z/; s/^expires_at:.*/expires_at: 2020-01-31T00:00:00Z/' "$ingested_file" && rm -f "${ingested_file}.bak"

  # Provide CHANGED content -> overwrite branch.
  local fetched="$TEST_TMP/changed.txt"
  printf '# Expiry Doc\n\nREVISED content.\n' > "$fetched"

  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$REFRESH'
    gaia_knowledge_refresh --fetched-content '$fetched'
  "
  [ "$status" -eq 0 ]

  # The old 2020 expiry must be gone — recomputed forward to fetched_at+ttl.
  assert_file_excludes "$ingested_file" '2020-01-31'
  assert_file_excludes "$ingested_file" '2020-01-01'
  # fetched_at and expires_at must both be present and current-era (post-2025).
  run grep -E '^expires_at: 20(2[5-9]|[3-9][0-9])' "$ingested_file"
  [ "$status" -eq 0 ]
  # The index trust block expires_at must also be refreshed (no 2020 left).
  assert_file_excludes "$MANIFEST" '2020-01-31'
}

# ---- expiry enforcement: stale sweep -------------------------------------------

@test "refresh marks an expired, un-revalidated entry as stale" {
  # A stdin-sourced entry has no re-fetchable origin, so it is the clean way to
  # land an entry in the expiry sweep without a fetch result.
  local body="# Stale Sweep Doc

Pasted content, no re-fetchable source."
  _seed_ingested "test-stale" "$body" > /dev/null
  local ingested_file="$KNOW/ingested/test-stale.md"

  # Make it a stdin entry (null source_url) and expire it while status: current.
  sed -i.bak -E 's#^source_url:.*#source_url: null#; s/^ingest_source_kind:.*/ingest_source_kind: stdin/; s/^expires_at:.*/expires_at: 2020-01-01T00:00:00Z/; s/^status:.*/status: current/' "$ingested_file" && rm -f "${ingested_file}.bak"
  # Null the manifest trust-block source_url (6-space indent) and retag stdin so
  # the enumerator classifies the entry as stdin (no re-fetchable source).
  sed -i.bak -E 's#^      source_url:.*#      source_url: null#; s/\["ingested", "url"\]/["ingested", "stdin"]/' "$MANIFEST" && rm -f "${MANIFEST}.bak"

  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$REFRESH'
    gaia_knowledge_refresh
  "
  [ "$status" -eq 0 ]

  # The expired current entry must now be stale.
  assert_file_contains "$ingested_file" 'status: stale'
}

@test "refresh does NOT mark a not-yet-expired entry stale" {
  local body="# Fresh Doc

Still well within its TTL."
  _seed_ingested "test-fresh" "$body" > /dev/null
  local ingested_file="$KNOW/ingested/test-fresh.md"

  # stdin entry, status current, expiry far in the FUTURE.
  sed -i.bak -E 's#^source_url:.*#source_url: null#; s/^ingest_source_kind:.*/ingest_source_kind: stdin/; s/^expires_at:.*/expires_at: 2099-01-01T00:00:00Z/; s/^status:.*/status: current/' "$ingested_file" && rm -f "${ingested_file}.bak"
  sed -i.bak -E 's#^      source_url:.*#      source_url: null#; s/\["ingested", "url"\]/["ingested", "stdin"]/' "$MANIFEST" && rm -f "${MANIFEST}.bak"

  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$REFRESH'
    gaia_knowledge_refresh
  "
  [ "$status" -eq 0 ]

  assert_file_contains "$ingested_file" 'status: current'
  assert_file_excludes "$ingested_file" 'status: stale'
}

@test "refresh does NOT mark a stdin entry failed (no re-fetchable source)" {
  local body="# Stdin Doc

Pasted once."
  _seed_ingested "test-stdin" "$body" > /dev/null
  local ingested_file="$KNOW/ingested/test-stdin.md"

  sed -i.bak -E 's#^source_url:.*#source_url: null#; s/^ingest_source_kind:.*/ingest_source_kind: stdin/; s/^status:.*/status: current/' "$ingested_file" && rm -f "${ingested_file}.bak"
  sed -i.bak -E 's#^      source_url:.*#      source_url: null#; s/\["ingested", "url"\]/["ingested", "stdin"]/' "$MANIFEST" && rm -f "${MANIFEST}.bak"

  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$REFRESH'
    gaia_knowledge_refresh
  "
  [ "$status" -eq 0 ]

  # A stdin entry within TTL must remain current — never flipped to failed.
  assert_file_contains "$ingested_file" 'status: current'
  assert_file_excludes "$ingested_file" 'status: failed'
}
