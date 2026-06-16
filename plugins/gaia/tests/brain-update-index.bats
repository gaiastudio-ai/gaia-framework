#!/usr/bin/env bats
# brain-update-index.bats — coverage for the partitioned lesson/edge writer
# (scripts/brain/update-brain-index.sh).
#
# Behaviour under test:
#   - The writer merges ONLY lesson entries into brain-index.yaml; project-artifact
#     rows pass through byte-untouched (partition-disjoint guard).
#   - Edge mutations (e.g. appending reviewed-in) do not alter the source_type
#     of any existing entry.
#   - Writes are atomic (sibling tempfile + mv).
#
# Paths derive from $BATS_TEST_DIRNAME via test_helper.bash (SCRIPTS_DIR); no
# hardcoded source-layout prefix, so the gate runs identically from a cache.

load 'test_helper.bash'

# Portable sha256 — dual idiom matching the brain scripts.
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
  UPDATER="$SCRIPTS_DIR/brain/update-brain-index.sh"

  PROJ="$TEST_TMP/proj"
  mkdir -p "$PROJ/.gaia/knowledge"
  export CLAUDE_PROJECT_ROOT="$PROJ"
  MANIFEST="$PROJ/.gaia/knowledge/brain-index.yaml"
}

teardown() {
  unset CLAUDE_PROJECT_ROOT
  common_teardown
}

# ---------------------------------------------------------------------------
# Helper: extract ALL lines belonging to a single entry block by key.
# An entry block starts with `- key: "<key>"` and ends at the next `- key:`
# or EOF. Outputs the raw YAML lines.
# ---------------------------------------------------------------------------
_extract_entry_block() {
  local manifest="$1" key="$2"
  awk -v key="$key" '
    /^- key:/ {
      k = $0; sub(/^- key:[[:space:]]*"?/, "", k); sub(/"?$/, "", k)
      if (k == key) { found = 1 }
      else if (found) { exit }
    }
    found { print }
  ' "$manifest"
}

# ---- TC-BRN-73 — partition-disjoint: lesson write never mutates project-artifact rows

@test "TC-BRN-73 — update-brain-index.sh writes only lesson entries; project-artifact rows are byte-identical" {
  [ -f "$UPDATER" ]

  # Seed manifest with one project-artifact entry and one lesson entry.
  cat > "$MANIFEST" <<'YAML'
schema_version: 1
entries:
- key: "architecture-shard-infra"
  source_type: project-artifact
  path: ".gaia/artifacts/planning-artifacts/architecture/infra.md"
  tags: ["architecture"]
  synopsis: "Infrastructure architecture shard."
  edges: []
  trust:
    confidence: 1.0
    content_hash: "aaa111aaa111aaa111aaa111aaa111aaa111aaa111aaa111aaa111aaa111aaa1"
    source_url: null
    fetched_at: null
    expires_at: null
- key: "lesson-strategy-existing"
  source_type: lesson
  path: ".gaia/artifacts/retro/retro-sprint-50.md"
  tags: ["strategy"]
  synopsis: "Existing lesson."
  edges: []
  trust:
    confidence: 1.0
    content_hash: "bbb222bbb222bbb222bbb222bbb222bbb222bbb222bbb222bbb222bbb222bbb2"
    source_url: "retro:sprint-50"
    fetched_at: null
    expires_at: null
YAML

  # Snapshot the project-artifact block BEFORE the write.
  local pa_before
  pa_before="$(_extract_entry_block "$MANIFEST" "architecture-shard-infra")"
  [ -n "$pa_before" ]

  # Run the writer to add a NEW lesson entry.
  run bash "$UPDATER" --manifest "$MANIFEST" --add-lesson \
    --key "lesson-strategy-newone" \
    --source-type lesson \
    --path ".gaia/artifacts/retro/retro-sprint-55.md" \
    --tags "strategy" \
    --synopsis "New lesson from the partitioned writer." \
    --content-hash "ccc333ccc333ccc333ccc333ccc333ccc333ccc333ccc333ccc333ccc333ccc3" \
    --source-url "retro:sprint-55"
  [ "$status" -eq 0 ]

  # The project-artifact block must be byte-identical AFTER the write.
  local pa_after
  pa_after="$(_extract_entry_block "$MANIFEST" "architecture-shard-infra")"
  [ "$pa_before" = "$pa_after" ]

  # The new lesson must be present.
  grep -q 'lesson-strategy-newone' "$MANIFEST"
  grep -q 'New lesson from the partitioned writer.' "$MANIFEST"

  # The writer must NOT have added any project-artifact entries.
  local pa_count
  pa_count=$(grep -c 'source_type: project-artifact' "$MANIFEST")
  [ "$pa_count" -eq 1 ]
}

# ---- TC-BRN-74 — edge mutation does not alter source_type

@test "TC-BRN-74 — edge mutation does not alter the source_type of existing entries" {
  [ -f "$UPDATER" ]

  # Seed manifest with one lesson entry that has no edges.
  cat > "$MANIFEST" <<'YAML'
schema_version: 1
entries:
- key: "lesson-strategy-target"
  source_type: lesson
  path: ".gaia/artifacts/retro/retro-sprint-50.md"
  tags: ["strategy"]
  synopsis: "Target entry for edge mutation."
  edges: []
  trust:
    confidence: 1.0
    content_hash: "ddd444ddd444ddd444ddd444ddd444ddd444ddd444ddd444ddd444ddd444ddd4"
    source_url: "retro:sprint-50"
    fetched_at: null
    expires_at: null
YAML

  # Snapshot the source_type BEFORE the edge mutation.
  local st_before
  st_before=$(grep 'source_type:' "$MANIFEST" | head -1)
  [ -n "$st_before" ]

  # Append a reviewed-in edge to the existing entry.
  run bash "$UPDATER" --manifest "$MANIFEST" --add-edge \
    --target-key "lesson-strategy-target" \
    --edge-type "reviewed-in" \
    --edge-target "sprint-review-sprint-50"
  [ "$status" -eq 0 ]

  # source_type must be unchanged.
  local st_after
  st_after=$(grep 'source_type:' "$MANIFEST" | head -1)
  [ "$st_before" = "$st_after" ]

  # The edge must be present.
  grep -q 'reviewed-in' "$MANIFEST"
  grep -q 'sprint-review-sprint-50' "$MANIFEST"

  # The entry must still have exactly one source_type line reading "lesson".
  local lesson_count
  lesson_count=$(grep -c 'source_type: lesson' "$MANIFEST")
  [ "$lesson_count" -eq 1 ]
}
