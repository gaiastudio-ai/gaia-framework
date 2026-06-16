#!/usr/bin/env bats
# brain-retro-lesson.bats — coverage for the retro-to-brain lesson emission
# (skills/gaia-retro/scripts/emit-brain-lessons.sh) and the brain-query
# --category filter (scripts/brain/gaia-brain-query.sh --category).
#
# Behaviour under test:
#   - The retro workflow emits first-class `lesson` brain entries to
#     brain-index.yaml with source_type=lesson, a category tag from the closed
#     set, non-empty path, numeric confidence, retro provenance in source_url,
#     null default expires_at, and schema-valid structure.
#   - Malformed lessons (empty path, out-of-range confidence, empty-string
#     source_type) are rejected with non-zero exit and the manifest is unchanged.
#   - gaia-brain-query --category <tag> filters to lesson entries matching the
#     requested category tag.

load 'test_helper.bash'

# Portable sha256 — dual idiom matching the emit script (sha256sum first,
# shasum fallback).
_sha256_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf 'no-sha256-tool'
  fi
}

setup() {
  common_setup
  EMIT="$BATS_TEST_DIRNAME/../skills/gaia-retro/scripts/emit-brain-lessons.sh"
  QUERY="$SCRIPTS_DIR/brain/gaia-brain-query.sh"
  SCHEMA="$BATS_TEST_DIRNAME/../schemas/brain-index.schema.json"
  VALIDATE="$SCRIPTS_DIR/lib/validate-artifact-schema.sh"
  FIX="$BATS_TEST_DIRNAME/fixtures/brain-retro-lesson"

  PROJ="$TEST_TMP/proj"
  mkdir -p "$PROJ/.gaia/knowledge"
  cp "$FIX/seed-manifest.yaml" "$PROJ/.gaia/knowledge/brain-index.yaml"

  export CLAUDE_PROJECT_ROOT="$PROJ"
  MANIFEST="$PROJ/.gaia/knowledge/brain-index.yaml"
}

teardown() {
  unset CLAUDE_PROJECT_ROOT
  common_teardown
}

# ── TC-BRN-65 — emit one strategy lesson ─────────────────────────────────────

@test "TC-BRN-65 — emit one strategy lesson produces a lesson entry in brain-index.yaml" {
  run bash "$EMIT" \
    --sprint-id sprint-57 \
    --retro-artifact "$FIX/retro-artifact.md" \
    --project-root "$PROJ" \
    --category strategy \
    --synopsis "Brain layer ships cleanly when each writer owns a disjoint partition."
  [ "$status" -eq 0 ]

  # The manifest must contain a lesson entry.
  grep -q 'source_type: lesson' "$MANIFEST"
}

# ── TC-BRN-66 — all 5 lesson categories round-trip ───────────────────────────

@test "TC-BRN-66 — five-category payload produces 5 lesson entries with all category tags" {
  # Reset to empty seed before bulk emit.
  cp "$FIX/seed-manifest.yaml" "$MANIFEST"

  run bash "$EMIT" \
    --sprint-id sprint-57 \
    --retro-artifact "$FIX/retro-artifact.md" \
    --project-root "$PROJ" \
    --lessons-yaml "$FIX/five-category-lessons.yaml"
  [ "$status" -eq 0 ]

  # Exactly 5 lesson entries.
  local count
  count=$(grep -c 'source_type: lesson' "$MANIFEST")
  [ "$count" -eq 5 ]

  # All five category tags are present.
  grep -q 'strategy' "$MANIFEST"
  grep -q 'writing-rule' "$MANIFEST"
  grep -q 'doc-maintenance-obligation' "$MANIFEST"
  grep -q 'anti-pattern' "$MANIFEST"
  grep -q 'tool-constraint' "$MANIFEST"
}

# ── TC-BRN-67 — lesson path is non-empty and equals the retro artifact ───────

@test "TC-BRN-67 — lesson entry path is non-empty and points to the retro artifact" {
  run bash "$EMIT" \
    --sprint-id sprint-57 \
    --retro-artifact "$FIX/retro-artifact.md" \
    --project-root "$PROJ" \
    --category strategy \
    --synopsis "Partition writers prevent contention."
  [ "$status" -eq 0 ]

  # path must contain the retro artifact path (the fixture path).
  grep -q "path:" "$MANIFEST"
  local path_line
  path_line=$(grep 'path:' "$MANIFEST" | grep -v '^#' | head -1)
  # Must not be empty-string-valued.
  [[ "$path_line" != *'path: ""'* ]]
  [[ "$path_line" != *"path: ''"* ]]
  # Must reference the retro artifact.
  [[ "$path_line" == *"retro-artifact.md"* ]]
}

# ── TC-BRN-68 — provenance source_url and numeric confidence ─────────────────

@test "TC-BRN-68 — source_url carries retro provenance and confidence is numeric 1.0" {
  run bash "$EMIT" \
    --sprint-id sprint-57 \
    --retro-artifact "$FIX/retro-artifact.md" \
    --project-root "$PROJ" \
    --category strategy \
    --synopsis "Provenance test."
  [ "$status" -eq 0 ]

  # source_url must be "retro:sprint-57".
  grep -q 'source_url: "retro:sprint-57"' "$MANIFEST" \
    || grep -q "source_url: retro:sprint-57" "$MANIFEST"

  # confidence must be numeric 1.0 (not the string "1.0").
  # The YAML value must look like `confidence: 1.0` without enclosing quotes.
  grep -q 'confidence: 1.0' "$MANIFEST"
  # Guard: must NOT be quoted string form.
  local conf_lines
  conf_lines=$(grep 'confidence:' "$MANIFEST" || true)
  [[ "$conf_lines" != *'confidence: "1.0"'* ]]
  [[ "$conf_lines" != *"confidence: '1.0'"* ]]
}

# ── TC-BRN-69 — TTL defaults to null; explicit expiry honoured ───────────────

@test "TC-BRN-69 — default expires_at is null and explicit expiry is honoured" {
  # Default: no --expires-at flag.
  cp "$FIX/seed-manifest.yaml" "$MANIFEST"
  run bash "$EMIT" \
    --sprint-id sprint-57 \
    --retro-artifact "$FIX/retro-artifact.md" \
    --project-root "$PROJ" \
    --category strategy \
    --synopsis "Default TTL."
  [ "$status" -eq 0 ]
  grep -q 'expires_at: null' "$MANIFEST"

  # Explicit: --expires-at 2026-12-31.
  cp "$FIX/seed-manifest.yaml" "$MANIFEST"
  run bash "$EMIT" \
    --sprint-id sprint-57 \
    --retro-artifact "$FIX/retro-artifact.md" \
    --project-root "$PROJ" \
    --category strategy \
    --synopsis "Explicit TTL." \
    --expires-at "2026-12-31"
  [ "$status" -eq 0 ]

  grep -q 'expires_at:' "$MANIFEST"
  grep -q '2026-12-31' "$MANIFEST"
}

# ── TC-BRN-70 — schema validation ────────────────────────────────────────────

@test "TC-BRN-70 — emitted manifest validates against brain-index.schema.json" {
  run bash "$EMIT" \
    --sprint-id sprint-57 \
    --retro-artifact "$FIX/retro-artifact.md" \
    --project-root "$PROJ" \
    --category strategy \
    --synopsis "Schema validation test."
  [ "$status" -eq 0 ]

  # --- Cheap structural guard (runs everywhere, no validator needed) ----------
  # The entry-level keys under each `- key:` block MUST be exactly the 7
  # allowed by the schema (additionalProperties: false): key, source_type,
  # path, tags, synopsis, trust, edges. A stray entry-level field (e.g. a
  # duplicated fetched_at outside the trust block) would pass unnoticed
  # without this check.
  #
  # Strategy: extract all 2-space-indented field names from the first entry
  # block (lines between the first `- key:` and the next `- key:` or EOF) and
  # assert they are a subset of the allowed set.
  local allowed="key source_type path tags synopsis trust edges"
  local entry_fields
  entry_fields=$(awk '
    /^- key:/ { if (seen++) exit; next }
    seen && /^  [a-z]/ {
      f = $0; sub(/^  /, "", f); sub(/:.*/, "", f); print f
    }
  ' "$MANIFEST")
  local f
  for f in $entry_fields; do
    case " $allowed " in
      *" $f "*) ;;
      *) fail "stray entry-level field '$f' not in allowed set: $allowed" ;;
    esac
  done

  # Also assert fetched_at appears ONLY inside the trust block (4-space indent)
  # and never at entry level (2-space indent).
  local stray_fetched
  stray_fetched=$(grep -c '^  fetched_at:' "$MANIFEST" || true)
  [ "$stray_fetched" -eq 0 ] || fail "fetched_at found at entry level (2-space indent) — must only appear inside trust (4-space)"

  # --- Full JSON-schema validation (backend-guarded) -------------------------
  if [ -x "$VALIDATE" ] || [ -r "$VALIDATE" ]; then
    source "$VALIDATE"
    run validate_artifact_schema "$SCHEMA" "$MANIFEST"
    if [ "$status" -eq 3 ]; then
      # Structural guard above already ran; skip only the schema-validator part.
      return 0
    fi
    [ "$status" -eq 0 ]
  fi
}

# ── TC-BRN-71 — malformed lessons rejected ───────────────────────────────────

@test "TC-BRN-71 — malformed lessons are rejected and manifest is unchanged" {
  # Guard: the emit script must exist for this test to be meaningful.
  [ -x "$EMIT" ] || [ -f "$EMIT" ]

  local before_hash
  before_hash=$(_sha256_of_file "$MANIFEST")

  # Empty path.
  run bash "$EMIT" \
    --sprint-id sprint-57 \
    --retro-artifact "$FIX/retro-artifact.md" \
    --project-root "$PROJ" \
    --lessons-yaml "$FIX/malformed-empty-path.yaml"
  [ "$status" -ne 0 ]

  local after_hash
  after_hash=$(_sha256_of_file "$MANIFEST")
  [ "$before_hash" = "$after_hash" ]

  # Bad confidence (1.5).
  run bash "$EMIT" \
    --sprint-id sprint-57 \
    --retro-artifact "$FIX/retro-artifact.md" \
    --project-root "$PROJ" \
    --lessons-yaml "$FIX/malformed-bad-confidence.yaml"
  [ "$status" -ne 0 ]

  after_hash=$(_sha256_of_file "$MANIFEST")
  [ "$before_hash" = "$after_hash" ]

  # Empty source_type.
  run bash "$EMIT" \
    --sprint-id sprint-57 \
    --retro-artifact "$FIX/retro-artifact.md" \
    --project-root "$PROJ" \
    --lessons-yaml "$FIX/malformed-empty-source-type.yaml"
  [ "$status" -ne 0 ]

  after_hash=$(_sha256_of_file "$MANIFEST")
  [ "$before_hash" = "$after_hash" ]
}

# ── TC-BRN-72 — gaia-brain-query --category filters lesson entries ────────────

@test "TC-BRN-72 — gaia-brain-query --category strategy returns only strategy lessons" {
  # Pre-populate the manifest with 2 lessons and 1 project-artifact.
  cat > "$MANIFEST" <<'YAML'
schema_version: 1
entries:
- key: lesson-strategy-abcdef
  source_type: lesson
  path: .gaia/artifacts/implementation-artifacts/retrospective/retro-sprint-57.md
  tags:
  - strategy
  synopsis: Partition writers prevent contention.
  trust:
    confidence: 1.0
    content_hash: aaa111
    source_url: "retro:sprint-57"
    fetched_at: null
    expires_at: null
  edges: []
- key: lesson-anti-pattern-bcdef1
  source_type: lesson
  path: .gaia/artifacts/implementation-artifacts/retrospective/retro-sprint-57.md
  tags:
  - anti-pattern
  synopsis: Never round-trip YAML through a generic serializer.
  trust:
    confidence: 1.0
    content_hash: bbb222
    source_url: "retro:sprint-57"
    fetched_at: null
    expires_at: null
  edges: []
- key: architecture-shard-infra
  source_type: project-artifact
  path: .gaia/artifacts/planning-artifacts/architecture/infra.md
  tags:
  - architecture
  synopsis: Infrastructure architecture shard.
  trust:
    confidence: 1.0
    content_hash: ccc333
    source_url: null
    fetched_at: null
    expires_at: null
  edges: []
YAML

  run bash "$QUERY" --category strategy --manifest "$MANIFEST"
  [ "$status" -eq 0 ]

  # Must contain the strategy lesson key.
  [[ "$output" == *"lesson-strategy-abcdef"* ]]
  [[ "$output" == *"Partition writers prevent contention"* ]]

  # Must NOT contain the anti-pattern lesson or the project-artifact.
  [[ "$output" != *"lesson-anti-pattern-bcdef1"* ]]
  [[ "$output" != *"architecture-shard-infra"* ]]
}

# -- AC1 hardening: backslash-bearing synopsis cannot inject a sibling YAML key

@test "TC-BRN-90 — backslash in synopsis does not inject a sibling YAML key" {
  cp "$FIX/seed-manifest.yaml" "$MANIFEST"

  # Synopsis containing backslashes — in a YAML double-quoted scalar these
  # MUST be escaped as \\ or the parser treats them as escape-sequence
  # introducers (e.g. \U is an 8-digit unicode escape in YAML 1.1).
  run bash "$EMIT" \
    --sprint-id sprint-57 \
    --retro-artifact "$FIX/retro-artifact.md" \
    --project-root "$PROJ" \
    --category strategy \
    --synopsis 'Path C:\Users\dev needs escaping'
  [ "$status" -eq 0 ]

  # The raw manifest must contain escaped backslashes (\\) inside the
  # double-quoted synopsis value. Without proper escaping the raw YAML
  # would contain bare \U and \d.
  grep -q 'synopsis:' "$MANIFEST"

  # Extract the synopsis line and assert it contains \\ (escaped backslash).
  local syn_line
  syn_line="$(grep 'synopsis:' "$MANIFEST" | grep -v '^#' | head -1)"
  # The line must contain a doubled backslash (\\U or \\d).
  printf '%s\n' "$syn_line" | grep -qF '\\'
}
