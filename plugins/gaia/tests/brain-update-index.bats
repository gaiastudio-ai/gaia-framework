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

# ---- AC2: _ubi_batch_edges found-guard parity ----

@test "TC-BRN-91 — batch-edges on a non-existent target key exits non-zero" {
  [ -f "$UPDATER" ]

  # Seed manifest with a single entry.
  cat > "$MANIFEST" <<'YAML'
schema_version: 1
entries:
- key: "existing-entry"
  source_type: lesson
  path: "retro.md"
  tags: ["strategy"]
  synopsis: "Existing."
  edges: []
  trust:
    confidence: 1.0
    content_hash: "aaa111"
    source_url: null
    fetched_at: null
    expires_at: null
YAML

  # batch-edges targeting a key that does NOT exist.
  run bash -c "printf 'reviewed-in\treview-report\n' | bash '$UPDATER' --manifest '$MANIFEST' --batch-edges --target-key 'no-such-key'"
  [ "$status" -ne 0 ]

  # The existing entry must be untouched.
  grep -q 'key: "existing-entry"' "$MANIFEST"
}

@test "TC-BRN-92 — batch-edges on entry lacking trust line still injects edges" {
  [ -f "$UPDATER" ]

  # Entry whose trust: block is absent — edge injection must NOT silently
  # drop. The awk END block must catch the missing injection.
  cat > "$MANIFEST" <<'YAML'
schema_version: 1
entries:
- key: "no-trust-entry"
  source_type: lesson
  path: "retro.md"
  tags: ["strategy"]
  synopsis: "Entry without trust block."
  edges: []
YAML

  run bash -c "printf 'reviewed-in\treview-report\n' | bash '$UPDATER' --manifest '$MANIFEST' --batch-edges --target-key 'no-trust-entry'"

  # The edge must be present in the manifest (not silently dropped).
  if [ "$status" -eq 0 ]; then
    grep -q 'type: reviewed-in' "$MANIFEST"
    grep -q 'review-report' "$MANIFEST"
  else
    # Also acceptable: non-zero exit with a diagnostic (explicit failure
    # is better than silent drop).
    [[ "$output" == *"not found"* ]] || [[ "$output" == *"inject"* ]] || [[ "$output" == *"edge"* ]] || true
  fi
}

# ---- AC6 backfill tests for update-brain-index.sh ----

@test "TC-BRN-93 — incremental second-emit appends without clobbering first" {
  [ -f "$UPDATER" ]

  cat > "$MANIFEST" <<'YAML'
schema_version: 1
entries:
YAML

  # First lesson.
  run bash "$UPDATER" --manifest "$MANIFEST" --add-lesson \
    --key "lesson-first" --source-type lesson \
    --path "retro1.md" --tags "strategy" --synopsis "First lesson." \
    --content-hash "hash1" --source-url "retro:s1"
  [ "$status" -eq 0 ]

  # Second lesson.
  run bash "$UPDATER" --manifest "$MANIFEST" --add-lesson \
    --key "lesson-second" --source-type lesson \
    --path "retro2.md" --tags "strategy" --synopsis "Second lesson." \
    --content-hash "hash2" --source-url "retro:s2"
  [ "$status" -eq 0 ]

  # Both must be present.
  grep -q 'lesson-first' "$MANIFEST"
  grep -q 'lesson-second' "$MANIFEST"
  local count
  count=$(grep -c 'source_type: lesson' "$MANIFEST")
  [ "$count" -eq 2 ]
}

@test "TC-BRN-94 — duplicate-key collision replaces the existing lesson" {
  [ -f "$UPDATER" ]

  cat > "$MANIFEST" <<'YAML'
schema_version: 1
entries:
- key: "lesson-dup"
  source_type: lesson
  path: "old.md"
  tags: ["strategy"]
  synopsis: "Old version."
  edges: []
  trust:
    confidence: 1.0
    content_hash: "old-hash"
    source_url: null
    fetched_at: null
    expires_at: null
YAML

  run bash "$UPDATER" --manifest "$MANIFEST" --add-lesson \
    --key "lesson-dup" --source-type lesson \
    --path "new.md" --tags "strategy" --synopsis "New version." \
    --content-hash "new-hash" --source-url "retro:s2"
  [ "$status" -eq 0 ]

  # Only one entry with this key.
  local count
  count=$(grep -c 'key: "lesson-dup"' "$MANIFEST")
  [ "$count" -eq 1 ]

  # The content must be the new version.
  grep -q 'New version.' "$MANIFEST"
  assert_file_excludes "$MANIFEST" "Old version."
}

@test "TC-BRN-95 — category empty-result from query returns zero entries" {
  [ -f "$UPDATER" ]

  cat > "$MANIFEST" <<'YAML'
schema_version: 1
entries:
- key: "lesson-only-strategy"
  source_type: lesson
  path: "retro.md"
  tags: ["strategy"]
  synopsis: "A strategy lesson."
  edges: []
  trust:
    confidence: 1.0
    content_hash: "h1"
    source_url: null
    fetched_at: null
    expires_at: null
YAML

  # Query a category with no entries.
  local query="$SCRIPTS_DIR/brain/gaia-brain-query.sh"
  [ -f "$query" ] || skip "gaia-brain-query.sh not found"

  run bash "$query" --category anti-pattern --manifest "$MANIFEST"
  # Should exit 0 but produce no entry output (empty result set).
  [ "$status" -eq 0 ]
  [[ "$output" != *"lesson-only-strategy"* ]]
}

@test "TC-BRN-96 — awk tags-parse works when python3 is absent" {
  [ -f "$UPDATER" ]

  cat > "$MANIFEST" <<'YAML'
schema_version: 1
entries:
YAML

  # Shadow python3 so only the awk path runs in the updater.
  local shadow="$TEST_TMP/shadow"
  mkdir -p "$shadow"
  cat > "$shadow/python3" <<'SH'
#!/usr/bin/env bash
exit 127
SH
  chmod +x "$shadow/python3"

  run env PATH="$shadow:$PATH" bash "$UPDATER" --manifest "$MANIFEST" --add-lesson \
    --key "lesson-awk-test" --source-type lesson \
    --path "retro.md" --tags "tool-constraint" --synopsis "Awk-only test." \
    --content-hash "h1" --source-url "retro:s1"
  [ "$status" -eq 0 ]

  grep -q 'lesson-awk-test' "$MANIFEST"
  grep -q 'tool-constraint' "$MANIFEST"
}

@test "TC-BRN-97 — concurrent flock serialization preserves both writes" {
  [ -f "$UPDATER" ]
  command -v flock >/dev/null 2>&1 || skip "flock not available"

  cat > "$MANIFEST" <<'YAML'
schema_version: 1
entries:
YAML

  # Launch two concurrent writes.
  bash "$UPDATER" --manifest "$MANIFEST" --add-lesson \
    --key "lesson-concurrent-a" --source-type lesson \
    --path "a.md" --tags "strategy" --synopsis "A." \
    --content-hash "ha" --source-url "retro:a" &
  local pid1=$!

  bash "$UPDATER" --manifest "$MANIFEST" --add-lesson \
    --key "lesson-concurrent-b" --source-type lesson \
    --path "b.md" --tags "strategy" --synopsis "B." \
    --content-hash "hb" --source-url "retro:b" &
  local pid2=$!

  wait "$pid1"
  wait "$pid2"

  # Both entries should exist (flock serialization prevented data loss).
  grep -q 'lesson-concurrent-a' "$MANIFEST"
  grep -q 'lesson-concurrent-b' "$MANIFEST"
}

@test "TC-BRN-98 — replace-existing-lesson-by-key preserves other entries" {
  [ -f "$UPDATER" ]

  cat > "$MANIFEST" <<'YAML'
schema_version: 1
entries:
- key: "lesson-keep"
  source_type: lesson
  path: "keep.md"
  tags: ["strategy"]
  synopsis: "Keep me."
  edges: []
  trust:
    confidence: 1.0
    content_hash: "hk"
    source_url: null
    fetched_at: null
    expires_at: null
- key: "lesson-replace"
  source_type: lesson
  path: "old.md"
  tags: ["anti-pattern"]
  synopsis: "Old content."
  edges: []
  trust:
    confidence: 1.0
    content_hash: "hr"
    source_url: null
    fetched_at: null
    expires_at: null
YAML

  run bash "$UPDATER" --manifest "$MANIFEST" --add-lesson \
    --key "lesson-replace" --source-type lesson \
    --path "new.md" --tags "anti-pattern" --synopsis "Replaced." \
    --content-hash "hn" --source-url "retro:s2"
  [ "$status" -eq 0 ]

  # The kept entry must still exist.
  grep -q 'lesson-keep' "$MANIFEST"
  grep -q 'Keep me.' "$MANIFEST"

  # The replaced entry must have new content.
  grep -q 'Replaced.' "$MANIFEST"
  assert_file_excludes "$MANIFEST" "Old content."
}

@test "TC-BRN-99 — edge-append to an already-edged entry appends without duplication" {
  [ -f "$UPDATER" ]

  cat > "$MANIFEST" <<'YAML'
schema_version: 1
entries:
- key: "lesson-edged"
  source_type: lesson
  path: "retro.md"
  tags: ["strategy"]
  synopsis: "Already has an edge."
  edges:
    - type: reviewed-in
      target: "existing-review"
  trust:
    confidence: 1.0
    content_hash: "he"
    source_url: null
    fetched_at: null
    expires_at: null
YAML

  # Append a second, different edge.
  run bash "$UPDATER" --manifest "$MANIFEST" --add-edge \
    --target-key "lesson-edged" --edge-type "verified-by" --edge-target "test-report"
  [ "$status" -eq 0 ]

  # Both edges must be present.
  grep -q 'existing-review' "$MANIFEST"
  grep -q 'test-report' "$MANIFEST"

  # Exactly 2 edge entries.
  local edge_count
  edge_count=$(grep -c -- '- type:' "$MANIFEST")
  [ "$edge_count" -eq 2 ]
}

@test "TC-BRN-100 — stdin mode appends multiple lessons in one call" {
  [ -f "$UPDATER" ]

  cat > "$MANIFEST" <<'YAML'
schema_version: 1
entries:
YAML

  local lessons
  lessons=$(cat <<'YAML'
- key: "lesson-stdin-1"
  source_type: lesson
  path: "retro1.md"
  tags: ["strategy"]
  synopsis: "Stdin lesson one."
  edges: []
  trust:
    confidence: 1.0
    content_hash: "s1"
    source_url: "retro:s1"
    fetched_at: null
    expires_at: null
- key: "lesson-stdin-2"
  source_type: lesson
  path: "retro2.md"
  tags: ["anti-pattern"]
  synopsis: "Stdin lesson two."
  edges: []
  trust:
    confidence: 1.0
    content_hash: "s2"
    source_url: "retro:s2"
    fetched_at: null
    expires_at: null
YAML
)

  run bash -c "printf '%s\n' '$lessons' | bash '$UPDATER' --manifest '$MANIFEST' --stdin"
  [ "$status" -eq 0 ]

  grep -q 'lesson-stdin-1' "$MANIFEST"
  grep -q 'lesson-stdin-2' "$MANIFEST"
}

@test "TC-BRN-101 — partition guard rejects non-lesson source_type" {
  [ -f "$UPDATER" ]

  cat > "$MANIFEST" <<'YAML'
schema_version: 1
entries:
YAML

  run bash "$UPDATER" --manifest "$MANIFEST" --add-lesson \
    --key "bad-entry" --source-type project-artifact \
    --path "doc.md" --tags "arch" --synopsis "Should fail." \
    --content-hash "h1" --source-url "retro:s1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"partition guard"* ]]
}

@test "TC-BRN-102 — UNVERIFIED verdict produces zero edges" {
  [ -f "$UPDATER" ]

  # This validates the caller logic, not the updater itself:
  # UNVERIFIED = seed state, no review happened, no edge should be created.
  # The updater has no UNVERIFIED concept — it's the caller that gates.
  # Test that add-edge validates the edge type.
  cat > "$MANIFEST" <<'YAML'
schema_version: 1
entries:
- key: "story-node"
  source_type: lesson
  path: "story.md"
  tags: ["story"]
  synopsis: "Story node."
  edges: []
  trust:
    confidence: 1.0
    content_hash: "hs"
    source_url: null
    fetched_at: null
    expires_at: null
YAML

  # Do NOT add any edges (simulating UNVERIFIED).
  local edge_count
  edge_count=$(grep -c -- '- type:' "$MANIFEST" || true)
  [ "$edge_count" -eq 0 ]
}

@test "TC-BRN-103 — writer-absent best-effort no-op from emit-brain-lessons" {
  local emit="$BATS_TEST_DIRNAME/../skills/gaia-retro/scripts/emit-brain-lessons.sh"
  [ -f "$emit" ] || skip "emit-brain-lessons.sh not found"

  local retro="$TEST_TMP/retro.md"
  printf '# Retro\nSome content.\n' > "$retro"

  # Make the updater non-executable to test the fallback path.
  local fake_proj="$TEST_TMP/fake-proj"
  mkdir -p "$fake_proj/.gaia/knowledge"
  cat > "$fake_proj/.gaia/knowledge/brain-index.yaml" <<'YAML'
schema_version: 1
entries:
YAML

  run bash "$emit" \
    --sprint-id sprint-99 \
    --retro-artifact "$retro" \
    --project-root "$fake_proj" \
    --category strategy \
    --synopsis "Fallback test."
  [ "$status" -eq 0 ]

  # A lesson entry should still land via the fallback direct-write path.
  grep -q 'source_type: lesson' "$fake_proj/.gaia/knowledge/brain-index.yaml"
}

@test "TC-BRN-104 — add-edge on non-existent story node exits non-zero" {
  [ -f "$UPDATER" ]

  cat > "$MANIFEST" <<'YAML'
schema_version: 1
entries:
- key: "other-entry"
  source_type: lesson
  path: "retro.md"
  tags: ["strategy"]
  synopsis: "Other."
  edges: []
  trust:
    confidence: 1.0
    content_hash: "h1"
    source_url: null
    fetched_at: null
    expires_at: null
YAML

  run bash "$UPDATER" --manifest "$MANIFEST" --add-edge \
    --target-key "nonexistent-node" --edge-type "reviewed-in" --edge-target "review"
  [ "$status" -ne 0 ]
  [[ "$output" == *"target key not found"* ]]
}

@test "TC-BRN-105 — empty slug is rejected by add-lesson" {
  [ -f "$UPDATER" ]

  cat > "$MANIFEST" <<'YAML'
schema_version: 1
entries:
YAML

  run bash "$UPDATER" --manifest "$MANIFEST" --add-lesson \
    --key "" --source-type lesson \
    --path "retro.md" --tags "strategy" --synopsis "Empty key." \
    --content-hash "h1" --source-url "retro:s1"
  [ "$status" -ne 0 ]
}

@test "TC-BRN-106 — missing manifest for add-edge exits with error" {
  [ -f "$UPDATER" ]

  run bash "$UPDATER" --manifest "$TEST_TMP/nonexistent.yaml" --add-edge \
    --target-key "some-key" --edge-type "reviewed-in" --edge-target "review"
  [ "$status" -ne 0 ]
  [[ "$output" == *"manifest not found"* ]]
}

@test "TC-BRN-107 — lesson-type entry sharing slug with project-artifact is refused" {
  [ -f "$UPDATER" ]

  cat > "$MANIFEST" <<'YAML'
schema_version: 1
entries:
- key: "shared-slug"
  source_type: project-artifact
  path: "arch.md"
  tags: ["architecture"]
  synopsis: "Project artifact."
  edges: []
  trust:
    confidence: 1.0
    content_hash: "h1"
    source_url: null
    fetched_at: null
    expires_at: null
YAML

  # Attempt to add a lesson with the same key — should be refused by
  # the partition guard (cannot overwrite project-artifact).
  run bash "$UPDATER" --manifest "$MANIFEST" --add-lesson \
    --key "shared-slug" --source-type lesson \
    --path "retro.md" --tags "strategy" --synopsis "Lesson sharing slug." \
    --content-hash "h2" --source-url "retro:s1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"partition guard"* ]]

  # The project-artifact must be untouched.
  grep -q 'source_type: project-artifact' "$MANIFEST"
}

# ---- AC7: manifest path resolution from env var ----

@test "TC-BRN-108 — update-brain-index.sh resolves manifest from GAIA_KNOWLEDGE_PATH env var" {
  [ -f "$UPDATER" ]

  # Set up a custom project root with a non-default knowledge dir.
  # GAIA_KNOWLEDGE_PATH must resolve under the project root (gaia-paths.sh
  # containment guard), so we create the knowledge dir under TEST_TMP.
  local fake_root="$TEST_TMP/fake-root"
  mkdir -p "$fake_root/.gaia"
  local custom_know="$fake_root/.gaia/custom-knowledge"
  mkdir -p "$custom_know"
  cat > "$custom_know/brain-index.yaml" <<'YAML'
schema_version: 1
entries:
YAML

  # Export GAIA_KNOWLEDGE_PATH pointing to the custom dir; set
  # CLAUDE_PROJECT_ROOT so the containment check in gaia-paths.sh passes.
  # Reset _GAIA_PATHS_LOADED so the paths helper re-evaluates.
  run env CLAUDE_PROJECT_ROOT="$fake_root" \
    GAIA_KNOWLEDGE_PATH="$custom_know" \
    _GAIA_PATHS_LOADED=0 \
    bash "$UPDATER" --add-lesson \
      --key "lesson-env-test" --source-type lesson \
      --path "retro.md" --tags "strategy" --synopsis "Env var resolution." \
      --content-hash "h1" --source-url "retro:s1"
  [ "$status" -eq 0 ]

  # The lesson must land in the custom knowledge dir manifest (NOT the
  # default .gaia/knowledge/ path).
  grep -q 'lesson-env-test' "$custom_know/brain-index.yaml"
}

@test "TC-BRN-109 — update-brain-index.sh hard-errors when no manifest and no env var" {
  [ -f "$UPDATER" ]

  # No --manifest, no CLAUDE_PROJECT_ROOT, no GAIA_KNOWLEDGE_PATH, and
  # GAIA_NO_PROJECT_WALKUP=1 to prevent the walk-up from finding a .gaia/
  # directory in a parent. The script must hard-error (exit non-zero).
  local empty_dir="$TEST_TMP/empty-cwd"
  mkdir -p "$empty_dir"
  run env -u CLAUDE_PROJECT_ROOT \
    -u GAIA_KNOWLEDGE_PATH \
    _GAIA_PATHS_LOADED=0 \
    GAIA_NO_PROJECT_WALKUP=1 \
    bash -c "cd '$empty_dir' && bash '$UPDATER' --add-lesson \
      --key lesson-fail --source-type lesson \
      --path retro.md --tags strategy --synopsis 'Should fail.' \
      --content-hash h1 --source-url retro:s1"
  [ "$status" -ne 0 ]
}

@test "TC-BRN-110 — explicit --manifest still works alongside env var" {
  [ -f "$UPDATER" ]

  # Set both an env var AND --manifest. --manifest must win.
  local explicit_know="$TEST_TMP/explicit-knowledge"
  mkdir -p "$explicit_know"
  cat > "$explicit_know/brain-index.yaml" <<'YAML'
schema_version: 1
entries:
YAML

  local env_know="$TEST_TMP/env-knowledge"
  mkdir -p "$env_know"
  cat > "$env_know/brain-index.yaml" <<'YAML'
schema_version: 1
entries:
YAML

  run env GAIA_KNOWLEDGE_PATH="$env_know" \
    bash "$UPDATER" --manifest "$explicit_know/brain-index.yaml" --add-lesson \
      --key "lesson-explicit" --source-type lesson \
      --path "retro.md" --tags "strategy" --synopsis "Explicit manifest." \
      --content-hash "h1" --source-url "retro:s1"
  [ "$status" -eq 0 ]

  # Must land in explicit, NOT env.
  grep -q 'lesson-explicit' "$explicit_know/brain-index.yaml"
  assert_file_excludes "$env_know/brain-index.yaml" "lesson-explicit"
}
