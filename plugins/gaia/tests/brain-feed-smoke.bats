#!/usr/bin/env bats
# brain-feed-smoke.bats — smoke coverage for the feed ingestion pipeline
# (scripts/brain/gaia-feed.sh).
#
# Behaviour under test:
#   - File ingestion end-to-end: a local markdown file is ingested into the
#     knowledge store under .gaia/knowledge/ingested/<slug>.md with provenance
#     frontmatter, and the brain-index manifest is updated with an ingested entry.
#   - Stdin ingestion: piped content is ingested via the "-" source specifier.
#   - Brain-index registration: ingested entries carry source_type: ingested
#     and a populated trust block.
#   - Frontmatter completeness: exactly the 11 canonical fields, no extras.
#   - Content-hash integrity: the content_hash matches the sha256 of the
#     post-strip body (body after the closing frontmatter delimiter).
#   - Slug-containment guard: path separators in a slug are rejected.
#   - Confidence tiering: file source kind maps to confidence 0.8.
#   - Kind override: --kind llms_txt via --fetched-content stamps
#     ingest_source_kind llms_txt and confidence 0.9 in the trust block.
#
# Each test builds an isolated per-test project tree (mktemp -d) and sources
# gaia-feed.sh to call gaia_feed() directly, so it never touches the real
# .gaia/knowledge/ store.

load 'test_helper.bash'

setup() {
  common_setup
  FEED="$SCRIPTS_DIR/brain/gaia-feed.sh"
  VALIDATE="$SCRIPTS_DIR/brain/validate-brain-index.sh"

  # Build an isolated project tree with a minimal brain-index.
  PROJ="$TEST_TMP/proj"
  mkdir -p "$PROJ/.gaia/knowledge/ingested"
  # Seed a minimal valid brain-index so the ingestion writer can append.
  cat > "$PROJ/.gaia/knowledge/brain-index.yaml" <<'YAML'
schema_version: 1
entries: []
YAML

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

# _extract_fm_field FILE FIELD — print the value of a frontmatter field.
_extract_fm_field() {
  awk -v field="$2" '
    BEGIN{in_fm=0}
    /^---[[:space:]]*$/{in_fm++; next}
    in_fm==1 && $0 ~ "^"field":"{
      sub(/^[^:]+:[[:space:]]*/, ""); gsub(/^"/, ""); gsub(/"$/, ""); print
    }
  ' "$1"
}

# _count_fm_fields FILE — count frontmatter fields (lines matching key: value
# between the two --- delimiters).
_count_fm_fields() {
  awk '
    BEGIN{n=0; count=0}
    /^---[[:space:]]*$/{n++; next}
    n==1 && /^[a-z_]+:/{count++}
    END{print count}
  ' "$1"
}

# ---- Test 1: file ingestion end-to-end --------------------------------------

@test "file ingestion writes an ingested file under knowledge/ingested/" {
  # Create a source file to ingest.
  local src="$TEST_TMP/reference-doc.md"
  cat > "$src" <<'MD'
# My Reference Document

This is the body of the reference document.

It has multiple paragraphs for testing purposes.
MD

  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$FEED'
    gaia_feed '$src'
  "
  [ "$status" -eq 0 ]

  # An ingested file should exist under the knowledge store.
  local ingested_dir="$KNOW/ingested"
  local count
  count="$(find "$ingested_dir" -name '*.md' -type f | wc -l | tr -d ' ')"
  [ "$count" -ge 1 ]

  # The ingested file should contain the body content.
  local ingested_file
  ingested_file="$(find "$ingested_dir" -name '*.md' -type f | head -1)"
  grep -q 'reference document' "$ingested_file"
}

# ---- Test 2: stdin ingestion -------------------------------------------------

@test "stdin ingestion via dash source writes an ingested file" {
  # Write stdin content to a temp file, then pipe it in a fresh bash process.
  local stdin_src="$TEST_TMP/stdin-input.md"
  cat > "$stdin_src" <<'MD'
# Stdin Document

This content was piped via stdin.
MD

  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$FEED'
    gaia_feed --slug test-stdin - < '$stdin_src'
  "
  [ "$status" -eq 0 ]

  # An ingested file should exist.
  local ingested_dir="$KNOW/ingested"
  [ -f "$ingested_dir/test-stdin.md" ]
}

# ---- Test 3: brain-index registration ----------------------------------------

@test "ingestion registers an ingested entry in brain-index.yaml" {
  local src="$TEST_TMP/for-index.md"
  cat > "$src" <<'MD'
# Index Test

Body for index registration test.
MD

  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$FEED'
    gaia_feed '$src'
  "
  [ "$status" -eq 0 ]

  # The manifest should now contain an ingested entry.
  grep -q 'source_type: ingested' "$MANIFEST"

  # Validate the manifest against the schema.
  run env -u _GAIA_PATHS_LOADED bash "$VALIDATE" "$MANIFEST"
  # Accept exit 0 (valid) or exit 3 (schema backend unavailable, structural
  # check skipped but index-in-place guard ran).
  [ "$status" -eq 0 ] || [ "$status" -eq 3 ]
}

# ---- Test 4: frontmatter completeness (exactly 11 fields) --------------------

@test "ingested file frontmatter has exactly 11 canonical fields" {
  local src="$TEST_TMP/fm-check.md"
  cat > "$src" <<'MD'
# Frontmatter Completeness Check

Body content for the frontmatter test.
MD

  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$FEED'
    gaia_feed '$src'
  "
  [ "$status" -eq 0 ]

  local ingested_file
  ingested_file="$(find "$KNOW/ingested" -name '*.md' -type f | head -1)"
  [ -f "$ingested_file" ]

  # Exactly 11 fields: title, slug, ingest_source_kind, source_url, fetched_at,
  # expires_at, content_hash, ttl_days, token_estimate, tags, status.
  local field_count
  field_count="$(_count_fm_fields "$ingested_file")"
  [ "$field_count" -eq 11 ]

  # Verify each required field is present.
  for field in title slug ingest_source_kind source_url fetched_at expires_at content_hash ttl_days token_estimate tags status; do
    grep -q "^${field}:" "$ingested_file" || {
      echo "Missing field: $field" >&2
      return 1
    }
  done
}

# ---- Test 5: content_hash integrity -----------------------------------------

@test "content_hash matches sha256 of the post-frontmatter body" {
  local src="$TEST_TMP/hash-check.md"
  cat > "$src" <<'MD'
# Hash Integrity

The body whose hash we verify.
MD

  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$FEED'
    gaia_feed '$src'
  "
  [ "$status" -eq 0 ]

  local ingested_file
  ingested_file="$(find "$KNOW/ingested" -name '*.md' -type f | head -1)"
  [ -f "$ingested_file" ]

  # Extract the content_hash from frontmatter.
  local stored_hash
  stored_hash="$(_extract_fm_field "$ingested_file" content_hash)"
  [ -n "$stored_hash" ]

  # Compute the expected hash from the body (post-frontmatter content).
  local expected_hash
  expected_hash="$(_extract_body "$ingested_file" | _sha_stdin)"

  [ "$stored_hash" = "$expected_hash" ]
}

# ---- Test 6: slug-containment guard rejects path separators ------------------

@test "slug-containment guard rejects slugs with path separators" {
  local src="$TEST_TMP/bad-slug.md"
  cat > "$src" <<'MD'
# Bad Slug Test

Body.
MD

  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$FEED'
    gaia_feed --slug '../../etc/evil' '$src'
  "
  [ "$status" -ne 0 ]
}

# ---- Test 7: confidence tiering (file -> 0.8) --------------------------------

@test "file source kind maps to confidence 0.8 in brain-index trust block" {
  local src="$TEST_TMP/confidence.md"
  cat > "$src" <<'MD'
# Confidence Tier

Body for the confidence test.
MD

  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$FEED'
    gaia_feed '$src'
  "
  [ "$status" -eq 0 ]

  # The brain-index entry should carry confidence: 0.8 for a file source.
  grep -q 'confidence: 0.8' "$MANIFEST"
}

# ---- Test 8: --kind llms_txt override stamps correct kind + confidence -------

@test "--kind llms_txt stamps ingest_source_kind llms_txt and confidence 0.9" {
  # Simulate the orchestration layer's llms-full.txt probe: content is
  # pre-fetched into a file and passed via --fetched-content + --kind llms_txt.
  local fetched="$TEST_TMP/llms-full-content.md"
  cat > "$fetched" <<'MD'
# LLMs Full Reference

This is the llms-full.txt content for the site.
MD

  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$FEED'
    gaia_feed --kind llms_txt --fetched-content '$fetched' --slug llms-ref 'https://example.com/docs'
  "
  [ "$status" -eq 0 ]

  # Verify the ingested file exists and has the correct source kind.
  local ingested_file="$KNOW/ingested/llms-ref.md"
  [ -f "$ingested_file" ]

  local actual_kind
  actual_kind="$(_extract_fm_field "$ingested_file" ingest_source_kind)"
  [ "$actual_kind" = "llms_txt" ]

  # Verify the brain-index trust block carries confidence 0.9.
  grep -q 'confidence: 0.9' "$MANIFEST"
}
