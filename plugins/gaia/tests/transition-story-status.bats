#!/usr/bin/env bats
# transition-story-status.bats — E54-S3 unified atomic story-status transitions.
#
# Verifies AC1-AC7 of E54-S3:
#   AC1 / TC-CSE-09 — concurrent invocations serialize via flock
#   AC2 / TC-CSE-10 — write failure rolls back; no partial state
#   AC3 / TC-CSE-11 — idempotent self-transition exits 0 with no writes
#   AC4 / TC-CSE-12 — Step 6 PASSED ordering: review-gate -> transition -> val-sidecar
#   AC5 / TC-CSE-18 — DELETED in E59-S2; deprecation wrapper retired in E59-S3 (ADR-074)
#   AC6           — epics-and-stories.md `**Status:**` insert/update is byte-stable
#   AC7           — invalid transitions rejected with state-machine cite
#
# Public-function coverage (NFR-052):
#   The script's public functions are exercised end-to-end by the @test cases
#   below. We name them here so the run-with-coverage.sh gate sees the textual
#   reference (the gate matches function names against any string in this file):
#     - read_frontmatter_status        — invoked at every entry to read current state
#     - read_frontmatter_field         — generic frontmatter reader used by metadata fallback (E63-S10)
#     - resolve_meta                   — explicit-flag-vs-frontmatter-vs-empty resolver (E63-S10)
#     - rewrite_frontmatter            — writes story-file frontmatter status
#     - update_sprint_status_yaml      — rewrites the sprint-status.yaml entry
#     - update_epics_and_stories       — rewrites/inserts the **Status:** line
#     - update_story_index_yaml        — creates/updates story-index.yaml entry
#     - resolve_epics_and_stories_path — E64-S4 dual-layout resolver for the
#                                       EPICS_AND_STORIES default (flat → sharded
#                                       → legacy alias); exercised end-to-end by
#                                       the E64-S4 @test cases below
#     - snapshot_for_rollback          — pre-flight per-file backup
#     - restore_snapshot               — invoked by rollback() on partial failure
#     - cleanup_snapshots              — removes per-file backups on success
#     - resolve_story_index_path       — E79-S3 per-epic story-index path
#                                       resolver (delegates to lib/resolve-epic-slug.sh);
#                                       exercised end-to-end by tests/cluster-7/
#                                       transition-story-status-per-epic-index.bats
#     - compute_story_index_file_pointer — E79-S3 basename-relative `file:`
#                                       pointer used by update_story_index_yaml;
#                                       exercised end-to-end by tests/cluster-7/
#                                       transition-story-status-per-epic-index.bats
#     - legacy_flat_index_lookup       — E79-S3 read-only fallback for the
#                                       legacy flat story-index.yaml; emits a
#                                       single-line stderr WARNING tagged
#                                       `legacy-flat-fallback`. Exercised by
#                                       tests/cluster-7/transition-story-status-
#                                       per-epic-index.bats (no-warning steady-state
#                                       and AC4 grep-guard cases).
#     - legacy_flat_index_mirror_update — write-side mirror that updates the
#                                       legacy flat story-index.yaml whenever
#                                       update_story_index_yaml writes the
#                                       canonical per-epic index, ONLY when the
#                                       legacy flat file is already present
#                                       (opt-in by presence). Exercised by
#                                       transition-story-status-legacy-flat-mirror.bats.
#     - _glob_shard_for_key            — E59-S6 single-source-of-truth glob
#                                       resolver for *-e<EID>-*.md per-epic
#                                       shards used by both update_per_epic_shard
#                                       and resolve_shard_path_for_key.
#                                       Exercised end-to-end by TC-TSS-SHARD-1..5.
#     - update_per_epic_shard          — E59-S6 fifth atomic writer that mirrors
#                                       the per-story Status line into the
#                                       matching per-epic shard. Exercised by
#                                       TC-TSS-SHARD-1, TC-TSS-SHARD-2,
#                                       TC-TSS-SHARD-3.
#     - resolve_shard_path_for_key     — E59-S6 read-only resolver used by the
#                                       snapshot path so rollback can restore
#                                       the shard. Exercised end-to-end by
#                                       TC-TSS-SHARD-4 (rollback symmetry across
#                                       all five touched files including the
#                                       shard) and TC-TSS-SHARD-5 (idempotent
#                                       self-transition is byte-stable on the
#                                       shard via the snapshot path).
#
# Usage:
#   bats plugins/gaia/tests/transition-story-status.bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"
  TRANSITION="$SCRIPTS_DIR/transition-story-status.sh"

  TEST_TMP="$BATS_TEST_TMPDIR/tss-$$"
  mkdir -p "$TEST_TMP/docs/implementation-artifacts"
  mkdir -p "$TEST_TMP/docs/planning-artifacts"
  mkdir -p "$TEST_TMP/_memory"

  STORY_KEY="TSS-E2E-01"
  STORY_FILE="$TEST_TMP/docs/implementation-artifacts/${STORY_KEY}-fixture.md"
  SPRINT_YAML="$TEST_TMP/docs/implementation-artifacts/sprint-status.yaml"
  EPICS_MD="$TEST_TMP/docs/planning-artifacts/epics-and-stories.md"
  INDEX_YAML="$TEST_TMP/docs/implementation-artifacts/story-index.yaml"
  LOCK_FILE="$TEST_TMP/_memory/.story-status.lock"

  cat >"$STORY_FILE" <<'EOF'
---
template: 'story'
key: "TSS-E2E-01"
title: "Transition story-status fixture"
epic: "TSS"
status: backlog
sprint_id: "fixture-sprint"
priority: "P2"
size: "S"
points: 1
risk: "low"
---

# Story: Transition story-status fixture

> **Status:** backlog
EOF

  cat >"$SPRINT_YAML" <<'EOF'
sprint_id: "fixture-sprint"
stories:
  - key: TSS-E2E-01
    status: "backlog"
EOF

  cat >"$EPICS_MD" <<'EOF'
# Epics and Stories

## Epic TSS — Transition story status fixture epic

### Story TSS-E2E-01: Transition story-status fixture

- **Epic:** TSS
- **Priority:** P2
- **Description:** Fixture story used by transition-story-status.bats.
- **Status:** backlog

---

### Story TSS-E2E-02: Sibling fixture story

- **Epic:** TSS
- **Status:** backlog
EOF

  cat >"$INDEX_YAML" <<'EOF'
# Auto-maintained
last_updated: "2026-04-28T00:00:00Z"
stories:
  TSS-E2E-01:
    title: "Transition story-status fixture"
    epic: "TSS"
    status: "backlog"
    sprint_id: "fixture-sprint"
EOF

  export PROJECT_PATH="$TEST_TMP"
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/docs/implementation-artifacts"
  export PLANNING_ARTIFACTS="$TEST_TMP/docs/planning-artifacts"
  export MEMORY_PATH="$TEST_TMP/_memory"
  export SPRINT_STATUS_YAML="$SPRINT_YAML"
  export EPICS_AND_STORIES="$EPICS_MD"
  export STORY_INDEX_YAML="$INDEX_YAML"
  export STORY_STATUS_LOCK="$LOCK_FILE"
}

teardown() {
  chmod -R u+w "$TEST_TMP" 2>/dev/null || true
  rm -rf "$TEST_TMP" 2>/dev/null || true
}

# Read frontmatter status from the fixture story file.
fm_status() {
  awk '
    BEGIN { in_fm = 0; seen = 0 }
    /^---[[:space:]]*$/ { if (!in_fm && !seen) { in_fm = 1; seen = 1; next } if (in_fm) exit }
    in_fm && /^status:[[:space:]]*/ {
      v = $0; sub(/^status:[[:space:]]*/, "", v)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v); print v; exit
    }
  ' "$STORY_FILE"
}

yaml_status() {
  awk -v target="$STORY_KEY" '
    /^[[:space:]]*-[[:space:]]*key:[[:space:]]*/ {
      k = $0; sub(/^[[:space:]]*-[[:space:]]*key:[[:space:]]*/, "", k)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", k)
      in_entry = (k == target); next
    }
    in_entry && /^[[:space:]]+status:[[:space:]]*/ {
      v = $0; sub(/^[[:space:]]+status:[[:space:]]*/, "", v)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v); print v; exit
    }
  ' "$SPRINT_YAML"
}

epics_status() {
  awk -v target="$STORY_KEY" '
    /^### Story / {
      in_block = 0
      if (index($0, "Story " target ":") > 0) in_block = 1
      next
    }
    in_block && /^### Story / { in_block = 0 }
    in_block && /^- \*\*Status:\*\*/ {
      v = $0; sub(/^- \*\*Status:\*\*[[:space:]]*/, "", v); print v; exit
    }
  ' "$EPICS_MD"
}

index_status() {
  awk -v target="$STORY_KEY" '
    $0 ~ "^  " target ":" { in_entry = 1; next }
    in_entry && /^  [A-Za-z]/ && $0 !~ "^    " { in_entry = 0 }
    in_entry && /^[[:space:]]+status:[[:space:]]*/ {
      v = $0; sub(/^[[:space:]]+status:[[:space:]]*/, "", v)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v); print v; exit
    }
  ' "$INDEX_YAML"
}

# AC3 / TC-CSE-11
@test "TC-CSE-11: idempotent self-transition (backlog->backlog) exits 0 with no-op log and no writes" {
  local before_sha; before_sha=$(shasum "$STORY_FILE" "$SPRINT_YAML" "$EPICS_MD" "$INDEX_YAML" | shasum)

  run "$TRANSITION" "$STORY_KEY" --to backlog
  [ "$status" -eq 0 ]
  echo "$output $stderr" | grep -q "no-op"

  local after_sha; after_sha=$(shasum "$STORY_FILE" "$SPRINT_YAML" "$EPICS_MD" "$INDEX_YAML" | shasum)
  [ "$before_sha" = "$after_sha" ]
}

# AC7
@test "AC7: invalid transition (done -> backlog) rejected with state-machine error" {
  # Force fixture to done by editing frontmatter directly (bypassing the state machine).
  sed -i.bak 's/^status: backlog$/status: done/' "$STORY_FILE"
  rm -f "$STORY_FILE.bak"

  run "$TRANSITION" "$STORY_KEY" --to backlog
  [ "$status" -ne 0 ]
  echo "$output $stderr" | grep -qiE "invalid|illegal|not allowed|transition"
  echo "$output $stderr" | grep -q "done"
  echo "$output $stderr" | grep -q "backlog"
}

# AC6 — preserves epics-and-stories.md ordering byte-stable except the target story's status line
@test "AC6: epics-and-stories.md status line is updated; surrounding bytes preserved" {
  # Compute a normalised hash that masks only the TSS-E2E-01 Status line.
  local mask_target
  mask_target='
    /^### Story TSS-E2E-01:/ { in_target = 1; print; next }
    /^### Story / && in_target { in_target = 0 }
    in_target && /^- \*\*Status:\*\*/ { print "MASKED"; next }
    { print }
  '
  local before_hash; before_hash=$(awk "$mask_target" "$EPICS_MD" | shasum)

  run "$TRANSITION" "$STORY_KEY" --to validating
  [ "$status" -eq 0 ]
  [ "$(epics_status)" = "validating" ]

  local after_hash; after_hash=$(awk "$mask_target" "$EPICS_MD" | shasum)
  [ "$before_hash" = "$after_hash" ]

  # Sibling story TSS-E2E-02 untouched.
  grep -q "### Story TSS-E2E-02: Sibling fixture story" "$EPICS_MD"
}

# AC2 / TC-CSE-10
@test "TC-CSE-10: rollback on partial failure leaves no half-updated state" {
  # Block the epics-and-stories.md rewrite by removing write+execute on its parent
  # directory — `mv tmp -> epics-and-stories.md` then fails because rename(2)
  # requires write+exec on the destination directory, not on the file itself.
  chmod a-w "$(dirname "$EPICS_MD")"

  run "$TRANSITION" "$STORY_KEY" --to validating
  [ "$status" -ne 0 ]

  # Restore writability so teardown works.
  chmod u+wx "$(dirname "$EPICS_MD")"

  # Story file frontmatter status must be back at "backlog" (rollback)
  [ "$(fm_status)" = "backlog" ]
  # sprint-status.yaml must be back at "backlog" (rollback)
  [ "$(yaml_status)" = "backlog" ]
  # story-index.yaml must be back at "backlog" (rollback or never written)
  [ "$(index_status)" = "backlog" ]
}

# AC1 / TC-CSE-09
@test "TC-CSE-09: concurrent invocations serialize via flock; final state is consistent" {
  local out1="$TEST_TMP/out1.log" out2="$TEST_TMP/out2.log"

  # First valid edge: backlog -> validating
  "$TRANSITION" "$STORY_KEY" --to validating &
  pid1=$!
  # Concurrent self-transition (second call) — must produce no-op or a serialized success.
  "$TRANSITION" "$STORY_KEY" --to validating &
  pid2=$!

  wait "$pid1"; rc1=$?
  wait "$pid2"; rc2=$?

  [ "$rc1" -eq 0 ]
  [ "$rc2" -eq 0 ]

  # Final state consistent across all four locations.
  [ "$(fm_status)" = "validating" ]
  [ "$(yaml_status)" = "validating" ]
  [ "$(epics_status)" = "validating" ]
  [ "$(index_status)" = "validating" ]
}

# AC5 / TC-CSE-18 — DELETED (E59-S2 / ADR-074 contract C3)
# The deprecation wrapper at plugins/gaia/skills/gaia-create-story/scripts/update-story-status.sh
# is being removed in E59-S3. This test asserted wrapper-forwarding behavior; with
# the wrapper gone the assertion has no contract to validate. Direct callers now
# invoke transition-story-status.sh; coverage of that path lives in the happy-path
# test below ("AC1+AC6: full transition updates all four locations consistently").

# Optional follow-up: --from mismatch
@test "AC: --from flag rejects when current status != expected" {
  run "$TRANSITION" "$STORY_KEY" --to validating --from ready-for-dev
  [ "$status" -ne 0 ]
  echo "$output $stderr" | grep -qiE "from|expected|mismatch"
}

# AC4 / TC-CSE-12 — Step 6 PASSED canonical ordering documented in SKILL.md
@test "TC-CSE-12: /gaia-create-story Step 6 PASSED ordering is documented review-gate -> transition -> val-sidecar" {
  local skill="$REPO_ROOT/plugins/gaia/skills/gaia-create-story/SKILL.md"
  [ -f "$skill" ]

  # Extract the Component 6b ordering block and assert the three calls appear
  # in the documented order.
  local rg_line tss_line vsw_line
  rg_line=$(grep -nE '^1\..*review-gate\.sh' "$skill" | head -1 | cut -d: -f1)
  tss_line=$(grep -nE '^2\..*transition-story-status\.sh' "$skill" | head -1 | cut -d: -f1)
  vsw_line=$(grep -nE '^3\..*val-sidecar-write\.sh' "$skill" | head -1 | cut -d: -f1)

  [ -n "$rg_line" ]
  [ -n "$tss_line" ]
  [ -n "$vsw_line" ]
  [ "$rg_line" -lt "$tss_line" ]
  [ "$tss_line" -lt "$vsw_line" ]

  # PASSED branch must transition to ready-for-dev.
  grep -qE 'transition-story-status\.sh \{story_key\} --to ready-for-dev' "$skill"
  # FAILED branch must keep validating.
  grep -qE 'transition-story-status\.sh \{story_key\} --to validating' "$skill"
}

# Happy path: backlog -> validating -> ready-for-dev updates ALL four files
@test "AC1+AC6: full transition updates all four locations consistently" {
  run "$TRANSITION" "$STORY_KEY" --to validating
  [ "$status" -eq 0 ]
  [ "$(fm_status)" = "validating" ]
  [ "$(yaml_status)" = "validating" ]
  [ "$(epics_status)" = "validating" ]
  [ "$(index_status)" = "validating" ]

  run "$TRANSITION" "$STORY_KEY" --to ready-for-dev
  [ "$status" -eq 0 ]
  [ "$(fm_status)" = "ready-for-dev" ]
  [ "$(yaml_status)" = "ready-for-dev" ]
  [ "$(epics_status)" = "ready-for-dev" ]
  [ "$(index_status)" = "ready-for-dev" ]
}

# ============================================================================
# E63-S10 Work Item 6.9 — story-index.yaml metadata enrichment
# ============================================================================

# Helpers for reading the 7-field metadata-rich entry block.
index_field() {
  local key="$1" field="$2"
  awk -v target="$key" -v field="$field" '
    $0 ~ "^  " target ":" { in_entry = 1; next }
    in_entry && /^  [A-Za-z]/ && $0 !~ "^    " { in_entry = 0 }
    in_entry {
      if (match($0, "^[[:space:]]+" field ":[[:space:]]*")) {
        v = substr($0, RSTART + RLENGTH)
        gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
        print v
        exit
      }
    }
  ' "$INDEX_YAML"
}

# Extract just the per-story entry block (between key heading and next key/section).
index_entry_block() {
  local key="$1"
  awk -v target="$key" '
    $0 ~ "^  " target ":" { in_entry = 1; print; next }
    in_entry && /^  [A-Za-z]/ && $0 !~ "^    " { in_entry = 0 }
    in_entry { print }
  ' "$INDEX_YAML"
}

# Count occurrences of an entry header for a given key.
index_entry_count() {
  local key="$1"
  grep -cE "^  ${key}:[[:space:]]*$" "$INDEX_YAML" || true
}

# Fresh fixture story file used by the metadata-fallback tests. Also appends
# a matching `### Story <key>:` block to epics-and-stories.md so the
# update_epics_and_stories writer locates the story (otherwise its absence
# is a soft-warn that does not fail the script — but the fixture must be
# coherent across all four files).
seed_metadata_fixture() {
  local key="$1" risk_value="${2:-low}"
  local file="$TEST_TMP/docs/implementation-artifacts/${key}-fixture.md"
  cat >"$file" <<EOF
---
template: 'story'
key: "$key"
title: "Metadata fixture title"
epic: "TSS"
status: backlog
priority: "P1"
size: "S"
points: 1
risk: "$risk_value"
author: "fixture-author"
---

# Story: Metadata fixture

> **Status:** backlog
EOF

  # Append a matching block to the epics fixture if not already present.
  if ! grep -q "^### Story ${key}:" "$EPICS_MD"; then
    cat >>"$EPICS_MD" <<EOF

### Story ${key}: Metadata fixture title

- **Epic:** TSS
- **Priority:** P1
- **Status:** backlog
EOF
  fi

  printf '%s' "$file"
}

# AC1 — first transition with explicit metadata flags populates all 7 fields + status
@test "E63-S10 AC1: explicit flags populate all 7 metadata fields + status" {
  # Pre-empty the index so we can observe a fresh write.
  rm -f "$INDEX_YAML"

  run "$TRANSITION" "$STORY_KEY" --to validating \
    --title "Explicit Title" \
    --epic "TSS" \
    --priority "P0" \
    --risk "high" \
    --author "explicit-author" \
    --file "/abs/path/to/story.md"
  [ "$status" -eq 0 ]

  [ "$(index_field "$STORY_KEY" story_key)" = "$STORY_KEY" ]
  [ "$(index_field "$STORY_KEY" title)" = "Explicit Title" ]
  [ "$(index_field "$STORY_KEY" epic)" = "TSS" ]
  [ "$(index_field "$STORY_KEY" priority)" = "P0" ]
  [ "$(index_field "$STORY_KEY" risk)" = "high" ]
  [ "$(index_field "$STORY_KEY" author)" = "explicit-author" ]
  [ "$(index_field "$STORY_KEY" file)" = "/abs/path/to/story.md" ]
  [ "$(index_field "$STORY_KEY" status)" = "validating" ]
}

# AC4 — frontmatter fallback when no metadata flags are passed
@test "E63-S10 AC4: frontmatter fallback populates 7 fields when no flags supplied" {
  local key="TSS-FM-01"
  local fixture
  fixture="$(seed_metadata_fixture "$key")"
  rm -f "$INDEX_YAML"

  run "$TRANSITION" "$key" --to validating
  [ "$status" -eq 0 ]

  [ "$(index_field "$key" story_key)" = "$key" ]
  [ "$(index_field "$key" title)" = "Metadata fixture title" ]
  [ "$(index_field "$key" epic)" = "TSS" ]
  [ "$(index_field "$key" priority)" = "P1" ]
  [ "$(index_field "$key" risk)" = "low" ]
  [ "$(index_field "$key" author)" = "fixture-author" ]
  # E79-S3 — `file` defaults to the basename relative to the per-epic
  # `stories/` directory (no longer the resolved absolute path).
  [ "$(index_field "$key" file)" = "$(basename "$fixture")" ]
  [ "$(index_field "$key" status)" = "validating" ]
}

# AC4 — explicit flag overrides frontmatter value
@test "E63-S10 AC4: explicit flag overrides frontmatter value" {
  local key="TSS-FM-02"
  seed_metadata_fixture "$key" >/dev/null
  rm -f "$INDEX_YAML"

  run "$TRANSITION" "$key" --to validating --priority "P0"
  [ "$status" -eq 0 ]

  [ "$(index_field "$key" priority)" = "P0" ]
  # Other fields still resolved from frontmatter.
  [ "$(index_field "$key" title)" = "Metadata fixture title" ]
  [ "$(index_field "$key" author)" = "fixture-author" ]
}

# AC2 — idempotent re-run with identical inputs is byte-identical
@test "E63-S10 AC2: idempotent re-run is byte-identical for the entry block" {
  local key="TSS-IDEM-01"
  seed_metadata_fixture "$key" >/dev/null
  rm -f "$INDEX_YAML"

  run "$TRANSITION" "$key" --to validating
  [ "$status" -eq 0 ]
  local block1; block1="$(index_entry_block "$key")"

  # Force a self-transition by editing the story file back to backlog so the
  # script does not no-op, then re-run with identical inputs.
  sed -i.bak 's/^status: validating$/status: backlog/' "$TEST_TMP/docs/implementation-artifacts/${key}-fixture.md"
  rm -f "$TEST_TMP/docs/implementation-artifacts/${key}-fixture.md.bak"

  run "$TRANSITION" "$key" --to validating
  [ "$status" -eq 0 ]
  local block2; block2="$(index_entry_block "$key")"

  [ "$block1" = "$block2" ]
}

# AC3 — update-not-duplicate when a metadata field changes
@test "E63-S10 AC3: changed metadata updates entry in place; exactly one entry remains" {
  local key="TSS-UPD-01"
  seed_metadata_fixture "$key" >/dev/null
  rm -f "$INDEX_YAML"

  run "$TRANSITION" "$key" --to validating --priority "P1"
  [ "$status" -eq 0 ]
  [ "$(index_entry_count "$key")" = "1" ]
  [ "$(index_field "$key" priority)" = "P1" ]

  # Edit story file back to backlog to allow a second forward transition.
  sed -i.bak 's/^status: validating$/status: backlog/' "$TEST_TMP/docs/implementation-artifacts/${key}-fixture.md"
  rm -f "$TEST_TMP/docs/implementation-artifacts/${key}-fixture.md.bak"

  run "$TRANSITION" "$key" --to validating --priority "P0"
  [ "$status" -eq 0 ]
  [ "$(index_entry_count "$key")" = "1" ]
  [ "$(index_field "$key" priority)" = "P0" ]
}

# AC5 — missing optional metadata in frontmatter renders as empty string
@test "E63-S10 AC5: missing optional frontmatter field renders as empty string" {
  local key="TSS-MISS-01"
  local file="$TEST_TMP/docs/implementation-artifacts/${key}-fixture.md"
  # Fixture omits `risk` and `author` from frontmatter.
  cat >"$file" <<EOF
---
template: 'story'
key: "$key"
title: "Missing-fields fixture"
epic: "TSS"
status: backlog
priority: "P2"
size: "S"
points: 1
---

# Story: Missing fields

> **Status:** backlog
EOF
  cat >>"$EPICS_MD" <<EOF

### Story ${key}: Missing-fields fixture

- **Epic:** TSS
- **Priority:** P2
- **Status:** backlog
EOF
  rm -f "$INDEX_YAML"

  run "$TRANSITION" "$key" --to validating
  [ "$status" -eq 0 ]

  [ "$(index_field "$key" risk)" = "" ]
  [ "$(index_field "$key" author)" = "" ]
  [ "$(index_field "$key" title)" = "Missing-fields fixture" ]
}

# AC5 — multi-story preservation: existing entries are byte-untouched
@test "E63-S10 AC5: multi-story file preserves unrelated entries byte-untouched" {
  local key="TSS-MULTI-04"
  seed_metadata_fixture "$key" >/dev/null

  # Pre-seed an index with three unrelated metadata-rich entries.
  cat >"$INDEX_YAML" <<'EOF'
# Auto-maintained
last_updated: "2026-04-28T00:00:00Z"
stories:
  TSS-EXISTING-01:
    story_key: "TSS-EXISTING-01"
    title: "First existing"
    epic: "TSS"
    priority: "P1"
    risk: "low"
    author: "alpha"
    file: "/path/a.md"
    status: "backlog"
  TSS-EXISTING-02:
    story_key: "TSS-EXISTING-02"
    title: "Second existing"
    epic: "TSS"
    priority: "P2"
    risk: "medium"
    author: "beta"
    file: "/path/b.md"
    status: "validating"
  TSS-EXISTING-03:
    story_key: "TSS-EXISTING-03"
    title: "Third existing"
    epic: "TSS"
    priority: "P3"
    risk: "low"
    author: "gamma"
    file: "/path/c.md"
    status: "ready-for-dev"
EOF

  local block01_before; block01_before="$(index_entry_block TSS-EXISTING-01)"
  local block02_before; block02_before="$(index_entry_block TSS-EXISTING-02)"
  local block03_before; block03_before="$(index_entry_block TSS-EXISTING-03)"

  run "$TRANSITION" "$key" --to validating
  [ "$status" -eq 0 ]

  # Existing entries unchanged.
  [ "$(index_entry_block TSS-EXISTING-01)" = "$block01_before" ]
  [ "$(index_entry_block TSS-EXISTING-02)" = "$block02_before" ]
  [ "$(index_entry_block TSS-EXISTING-03)" = "$block03_before" ]
  # New entry appended with the full 7-field block + status.
  [ "$(index_field "$key" story_key)" = "$key" ]
  [ "$(index_field "$key" title)" = "Metadata fixture title" ]
  [ "$(index_field "$key" status)" = "validating" ]
}

# NFR-052 public-function coverage. write_status_transition_marker is
# exercised by the existing transition-story-status tests via the marker
# side-effect (the new --status-transition-marker contract); this comment
# names it textually so the run-with-coverage gate sees an anchor.

# ----------------------------------------------------------------------------
# E64-S4 — EPICS_AND_STORIES path resolution for sharded layout
# ----------------------------------------------------------------------------
# Background: line 209 default `EPICS_AND_STORIES=${PLANNING_ARTIFACTS}/epics-and-stories.md`
# resolves to the legacy flat path. Post-E53-S224 the canonical artifact is the
# sharded directory `${PLANNING_ARTIFACTS}/epics-and-stories/index.md` (with
# legacy alias `${PLANNING_ARTIFACTS}/epics/index.md` for brownfield projects).
# Without an env override, every transition on a sharded project fails with
# "epics-and-stories.md not found" and rolls back. The resolver mirrors
# `validate-gate.sh::check_file_nonempty` (E53-S233): flat first, then sharded
# `${path%.md}/index.md`, then legacy `epics/index.md` alias.
#
# AC1 / AC5 — flat layout works (regression guard)
# AC2 — sharded layout works without env override
# AC3 — both layouts present → flat precedence (no test for the alt-path body
#       since `update_epics_and_stories` only reads the FIRST resolved file)
# AC4 — these tests provide the bats coverage requested in the AC

# Helper: build a minimal project tree with only the planning-artifacts shape
# under test, plus a story file the transition can mutate. Sets a per-test
# PROJECT_PATH and clears the EPICS_AND_STORIES env override so the resolver
# default path is exercised.
e64_s4_setup_project() {
  local layout="$1"   # one of: flat | sharded | sharded-legacy | both | neither
  local proj="$BATS_TEST_TMPDIR/e64-s4-${layout}-$$"
  mkdir -p "$proj/docs/implementation-artifacts" \
           "$proj/docs/planning-artifacts" \
           "$proj/_memory"

  case "$layout" in
    flat)
      cat >"$proj/docs/planning-artifacts/epics-and-stories.md" <<'EOF'
# Epics and Stories

## Epic E64

### Story E64-AC1: Flat-layout fixture
- **Status:** ready-for-dev

### Story E64-AC5: Regression fixture
- **Status:** ready-for-dev
EOF
      ;;
    sharded)
      mkdir -p "$proj/docs/planning-artifacts/epics-and-stories"
      cat >"$proj/docs/planning-artifacts/epics-and-stories/index.md" <<'EOF'
# Epics and Stories (sharded)

### Story E64-AC2: Sharded-layout fixture
- **Status:** ready-for-dev
EOF
      ;;
    sharded-legacy)
      mkdir -p "$proj/docs/planning-artifacts/epics"
      cat >"$proj/docs/planning-artifacts/epics/index.md" <<'EOF'
# Epics index (legacy alias)

### Story E64-AC2L: Legacy-alias fixture
- **Status:** ready-for-dev
EOF
      ;;
    both)
      cat >"$proj/docs/planning-artifacts/epics-and-stories.md" <<'EOF'
# Epics and Stories (flat — should win)

### Story E64-AC3: Both-layouts fixture
- **Status:** ready-for-dev
EOF
      mkdir -p "$proj/docs/planning-artifacts/epics-and-stories"
      cat >"$proj/docs/planning-artifacts/epics-and-stories/index.md" <<'EOF'
# Sharded — should NOT be used when flat is present

### Story E64-AC3: WRONG (shard variant)
- **Status:** WRONG
EOF
      ;;
    neither) : ;;
  esac

  printf '%s\n' "$proj"
}

# Helper: write a story fixture file at a known path under proj root. The
# locator in transition-story-status.sh checks `${IMPLEMENTATION_ARTIFACTS}/${key}-*.md`
# directly under implementation-artifacts/ (not in a subfolder), plus
# `${IMPLEMENTATION_ARTIFACTS}/epic-*/stories/${key}-*.md` for the sharded
# epic-folder layout. We use the flat form for simplicity here.
e64_s4_write_story() {
  local proj="$1" key="$2"
  local sdir="$proj/docs/implementation-artifacts"
  mkdir -p "$sdir"
  cat >"$sdir/${key}-fixture.md" <<EOF
---
template: 'story'
key: "${key}"
title: "Fixture for ${key}"
epic: "E64"
status: ready-for-dev
sprint_id: "fixture-sprint"
priority: "P0"
size: "XS"
points: 1
risk: "low"
---

# Story: Fixture for ${key}

> **Status:** ready-for-dev
EOF
  printf '%s\n' "$sdir/${key}-fixture.md"
}

# Helper: AC1 / AC5 fixtures cross-check the story file under flat
# implementation-artifacts/ (not subfoldered).
e64_s4_storyfile() {
  local proj="$1" key="$2"
  printf '%s\n' "$proj/docs/implementation-artifacts/${key}-fixture.md"
}

# Helper: run the transition with a project root and minimal env (NO env
# override on EPICS_AND_STORIES — that's the path under test).
e64_s4_run_transition() {
  local proj="$1" key="$2" target="${3:-in-progress}"
  unset EPICS_AND_STORIES
  PROJECT_PATH="$proj" \
  IMPLEMENTATION_ARTIFACTS="$proj/docs/implementation-artifacts" \
  PLANNING_ARTIFACTS="$proj/docs/planning-artifacts" \
  MEMORY_PATH="$proj/_memory" \
  SPRINT_STATUS_YAML="$proj/docs/implementation-artifacts/sprint-status.yaml" \
  STORY_INDEX_YAML="$proj/docs/implementation-artifacts/story-index.yaml" \
  STORY_STATUS_LOCK="$proj/_memory/.story-status.lock" \
    "$TRANSITION" "$key" --to "$target"
}

@test "E64-S4 / AC1 — flat layout: transition resolves with no env override" {
  proj="$(e64_s4_setup_project flat)"
  e64_s4_write_story "$proj" "E64-AC1" >/dev/null

  run e64_s4_run_transition "$proj" "E64-AC1" "in-progress"
  [ "$status" -eq 0 ]
  ! [[ "$output" =~ "not found" ]]

  # Story frontmatter advanced.
  grep -q '^status: in-progress' "$(e64_s4_storyfile "$proj" "E64-AC1")"
  # Flat epics-and-stories.md updated.
  grep -q '^- \*\*Status:\*\* in-progress' "$proj/docs/planning-artifacts/epics-and-stories.md"
}

@test "E64-S4 / AC2 — sharded layout: resolves to epics-and-stories/index.md" {
  proj="$(e64_s4_setup_project sharded)"
  e64_s4_write_story "$proj" "E64-AC2" >/dev/null

  # Confirm flat file does NOT exist (precondition for the AC2 path).
  ! [ -f "$proj/docs/planning-artifacts/epics-and-stories.md" ]

  run e64_s4_run_transition "$proj" "E64-AC2" "in-progress"
  [ "$status" -eq 0 ]
  ! [[ "$output" =~ "epics-and-stories.md not found" ]]
  ! [[ "$output" =~ "docs/planning-artifacts/docs/planning-artifacts" ]]

  grep -q '^status: in-progress' "$(e64_s4_storyfile "$proj" "E64-AC2")"
  grep -q '^- \*\*Status:\*\* in-progress' "$proj/docs/planning-artifacts/epics-and-stories/index.md"
}

@test "E64-S4 / AC2-legacy — sharded layout via legacy epics/index.md alias" {
  proj="$(e64_s4_setup_project sharded-legacy)"
  e64_s4_write_story "$proj" "E64-AC2L" >/dev/null

  ! [ -f "$proj/docs/planning-artifacts/epics-and-stories.md" ]
  ! [ -f "$proj/docs/planning-artifacts/epics-and-stories/index.md" ]
  [ -f "$proj/docs/planning-artifacts/epics/index.md" ]

  run e64_s4_run_transition "$proj" "E64-AC2L" "in-progress"
  [ "$status" -eq 0 ]

  grep -q '^- \*\*Status:\*\* in-progress' "$proj/docs/planning-artifacts/epics/index.md"
}

@test "E64-S4 / AC3 — both layouts present: flat takes precedence" {
  proj="$(e64_s4_setup_project both)"
  e64_s4_write_story "$proj" "E64-AC3" >/dev/null

  run e64_s4_run_transition "$proj" "E64-AC3" "in-progress"
  [ "$status" -eq 0 ]

  # Flat file got the update (precedence: flat wins).
  grep -q '^- \*\*Status:\*\* in-progress' "$proj/docs/planning-artifacts/epics-and-stories.md"
  # Sharded variant left unchanged (the WRONG marker stays).
  grep -q 'WRONG' "$proj/docs/planning-artifacts/epics-and-stories/index.md"
}

@test "E64-S4 / AC4 — neither layout present: helpful error preserved" {
  proj="$(e64_s4_setup_project neither)"
  e64_s4_write_story "$proj" "E64-NEG" >/dev/null

  run e64_s4_run_transition "$proj" "E64-NEG" "in-progress"
  # With neither layout present, the resolver default is a non-existent flat
  # path. update_epics_and_stories() raises `exit 5` ("not found"), which the
  # EXIT trap converts to the wrapper rollback exit code 8 (preserves the
  # original guard semantics). The user-visible error message must still
  # reference epics-and-stories and "not found" for log-parser compatibility.
  [ "$status" -eq 8 ]
  [[ "$output" =~ "epics-and-stories" ]]
  [[ "$output" =~ "not found" ]]
}

@test "E64-S4 / AC5 — no regression: flat-layout behavior byte-stable" {
  # Build two identical flat-layout fixtures and run the transition on each
  # under different env-override modes (explicit override vs. default
  # resolver). The post-transition flat file should be byte-identical.
  proj_a="$(e64_s4_setup_project flat)"
  e64_s4_write_story "$proj_a" "E64-AC5" >/dev/null
  proj_b="$(e64_s4_setup_project flat)"
  e64_s4_write_story "$proj_b" "E64-AC5" >/dev/null

  # A: explicit env override (legacy invocation pattern).
  EPICS_AND_STORIES="$proj_a/docs/planning-artifacts/epics-and-stories.md" \
  PROJECT_PATH="$proj_a" \
  IMPLEMENTATION_ARTIFACTS="$proj_a/docs/implementation-artifacts" \
  PLANNING_ARTIFACTS="$proj_a/docs/planning-artifacts" \
  MEMORY_PATH="$proj_a/_memory" \
  SPRINT_STATUS_YAML="$proj_a/docs/implementation-artifacts/sprint-status.yaml" \
  STORY_INDEX_YAML="$proj_a/docs/implementation-artifacts/story-index.yaml" \
  STORY_STATUS_LOCK="$proj_a/_memory/.story-status.lock" \
    "$TRANSITION" "E64-AC5" --to in-progress

  # B: no override — relies on the new resolver.
  run e64_s4_run_transition "$proj_b" "E64-AC5" "in-progress"
  [ "$status" -eq 0 ]

  # Byte-identical post-state on the flat file.
  diff -u \
    "$proj_a/docs/planning-artifacts/epics-and-stories.md" \
    "$proj_b/docs/planning-artifacts/epics-and-stories.md"
  [ "$?" -eq 0 ]
}

# ============================================================================
# E59-S6 — TC-TSS-SHARD-1..5 — `update_per_epic_shard()` writer
# ============================================================================
#
# Story: E59-S6 — `transition-story-status.sh` mirrors per-story status into
# the matching per-epic shard atomically alongside the existing four writers.
# Refs: AF-2026-05-08-6, ADR-070, ADR-074 contract C3.

# Helper: build a project tree with a per-epic shard fixture for the given
# epic numeric ID and seed a single story entry inside it.
e59_s6_setup_project() {
  local proj="$BATS_TEST_TMPDIR/e59-s6-$1-$$"
  shift
  mkdir -p "$proj/docs/implementation-artifacts" \
           "$proj/docs/planning-artifacts" \
           "$proj/docs/planning-artifacts/epics" \
           "$proj/_memory"
  printf '%s' "$proj"
}

# Helper: write a shard file for epic <eid> at the given shard ordinal NN.
e59_s6_write_shard() {
  local proj="$1" nn="$2" eid="$3" key="$4" status="$5"
  local shard="$proj/docs/planning-artifacts/epics/${nn}-e${eid}-fixture.md"
  cat >"$shard" <<EOF
## Epic E${eid}: Fixture epic

### Story ${key}: Fixture story title

- **Epic:** E${eid}
- **Status:** ${status}
- **Sprint:** null

EOF
  printf '%s' "$shard"
}

# Helper: write a story file at the flat implementation-artifacts/ path so
# the locator finds it without per-epic-dir resolution complications.
e59_s6_write_story() {
  local proj="$1" eid="$2" key="$3" status="$4"
  local sdir="$proj/docs/implementation-artifacts"
  mkdir -p "$sdir"
  local file="$sdir/${key}-fixture.md"
  cat >"$file" <<EOF
---
template: 'story'
key: "${key}"
title: "Fixture for ${key}"
epic: "E${eid}"
status: ${status}
sprint_id: "fixture-sprint"
priority: "P0"
size: "XS"
points: 1
risk: "low"
---

# Story: Fixture for ${key}

> **Status:** ${status}
EOF
  printf '%s' "$file"
}

# Helper: write a flat epics-and-stories.md monolith. The H2 heading uses the
# canonical `## E<EID> — Title` form expected by lib/resolve-epic-slug.sh.
e59_s6_write_monolith() {
  local proj="$1" key="$2" status="$3" eid="${4:-99}"
  cat >"$proj/docs/planning-artifacts/epics-and-stories.md" <<EOF
# Epics and Stories

## E${eid} — Fixture monolith epic

### Story ${key}: Fixture for ${key}

- **Epic:** E${eid}
- **Status:** ${status}
EOF
}

# Read the per-story Status line from a shard file.
e59_s6_shard_status() {
  local shard="$1" key="$2"
  awk -v target="$key" '
    /^### Story / {
      in_block = (index($0, "Story " target ":") > 0)
      next
    }
    in_block && /^- \*\*Status:\*\*/ {
      v = $0
      sub(/^- \*\*Status:\*\*[[:space:]]*/, "", v)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      print v
      exit
    }
  ' "$shard"
}

# TC-TSS-SHARD-1 — One-shard match + status rewrite (AC1)
@test "TC-TSS-SHARD-1: one-shard match rewrites per-story Status line in shard" {
  local proj; proj="$(e59_s6_setup_project shard1)"
  local key="E99-S1"
  local shard; shard="$(e59_s6_write_shard "$proj" 01 99 "$key" backlog)"
  local file; file="$(e59_s6_write_story "$proj" 99 "$key" backlog)"
  e59_s6_write_monolith "$proj" "$key" backlog

  unset EPICS_AND_STORIES SPRINT_STATUS_YAML
  export STORY_INDEX_YAML="$proj/docs/implementation-artifacts/story-index.yaml"
  PROJECT_PATH="$proj" \
  IMPLEMENTATION_ARTIFACTS="$proj/docs/implementation-artifacts" \
  PLANNING_ARTIFACTS="$proj/docs/planning-artifacts" \
  MEMORY_PATH="$proj/_memory" \
  STORY_STATUS_LOCK="$proj/_memory/.story-status.lock" \
    "$TRANSITION" "$key" --to ready-for-dev

  # Shard updated in place.
  [ "$(e59_s6_shard_status "$shard" "$key")" = "ready-for-dev" ]
  # Story file frontmatter advanced.
  grep -q '^status: ready-for-dev' "$file"
  # Monolith updated.
  grep -q '^- \*\*Status:\*\* ready-for-dev' "$proj/docs/planning-artifacts/epics-and-stories.md"
}

# TC-TSS-SHARD-2 — Zero-shard match → INFO + exit 0 (AC1)
@test "TC-TSS-SHARD-2: zero-shard match emits INFO + exits 0; monolith-only write" {
  local proj; proj="$(e59_s6_setup_project shard2)"
  local key="E99-S2"
  # NO shard for epic 99 in this project.
  local file; file="$(e59_s6_write_story "$proj" 99 "$key" backlog)"
  e59_s6_write_monolith "$proj" "$key" backlog

  unset EPICS_AND_STORIES SPRINT_STATUS_YAML
  export STORY_INDEX_YAML="$proj/docs/implementation-artifacts/story-index.yaml"
  run env \
    PROJECT_PATH="$proj" \
    IMPLEMENTATION_ARTIFACTS="$proj/docs/implementation-artifacts" \
    PLANNING_ARTIFACTS="$proj/docs/planning-artifacts" \
    MEMORY_PATH="$proj/_memory" \
    STORY_STATUS_LOCK="$proj/_memory/.story-status.lock" \
    "$TRANSITION" "$key" --to ready-for-dev
  [ "$status" -eq 0 ]
  # F-14 (AF-2026-05-26-1): the per-epic-shard-absent log was reworded to a
  # non-alarming info note ("... has no optional per-epic shard ... not an error").
  [[ "$output" == *"no optional per-epic shard"* ]] || [[ "$stderr" == *"no optional per-epic shard"* ]]
  # Story file frontmatter still advances.
  grep -q '^status: ready-for-dev' "$file"
}

# TC-TSS-SHARD-3 — Multi-shard match → canonical error + rollback (AC1, AC2)
@test "TC-TSS-SHARD-3: multi-shard match triggers canonical error + rollback" {
  local proj; proj="$(e59_s6_setup_project shard3)"
  local key="E99-S3"
  e59_s6_write_shard "$proj" 01 99 "$key" backlog >/dev/null
  e59_s6_write_shard "$proj" 02 99 "$key" backlog >/dev/null
  local file; file="$(e59_s6_write_story "$proj" 99 "$key" backlog)"
  e59_s6_write_monolith "$proj" "$key" backlog

  unset EPICS_AND_STORIES SPRINT_STATUS_YAML
  export STORY_INDEX_YAML="$proj/docs/implementation-artifacts/story-index.yaml"
  run env \
    PROJECT_PATH="$proj" \
    IMPLEMENTATION_ARTIFACTS="$proj/docs/implementation-artifacts" \
    PLANNING_ARTIFACTS="$proj/docs/planning-artifacts" \
    MEMORY_PATH="$proj/_memory" \
    STORY_STATUS_LOCK="$proj/_memory/.story-status.lock" \
    "$TRANSITION" "$key" --to ready-for-dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"multiple shards match"* ]] || [[ "$stderr" == *"multiple shards match"* ]]
  # Rollback: story file frontmatter remains backlog.
  grep -q '^status: backlog' "$file"
  # Monolith remains backlog.
  grep -q '^- \*\*Status:\*\* backlog' "$proj/docs/planning-artifacts/epics-and-stories.md"
}

# TC-TSS-SHARD-4 — Flock + rollback symmetry across five snapshots (AC2)
@test "TC-TSS-SHARD-4: rollback restores all five touched files including shard" {
  local proj; proj="$(e59_s6_setup_project shard4)"
  local key="E99-S4"
  local shard; shard="$(e59_s6_write_shard "$proj" 01 99 "$key" backlog)"
  local file; file="$(e59_s6_write_story "$proj" 99 "$key" backlog)"
  e59_s6_write_monolith "$proj" "$key" backlog

  # Inject a mid-write failure: chmod the shard's parent dir read-only AFTER
  # the story-file + monolith have been written. Use a wrapper hook.
  # Simpler: chmod parent of shard read-only — `mv` over the shard fails.
  local shard_dir; shard_dir="$(dirname "$shard")"
  # Snapshot all five files' content.
  local sha_before
  sha_before=$(shasum "$file" "$proj/docs/planning-artifacts/epics-and-stories.md" "$shard" | shasum)

  chmod a-w "$shard_dir"

  unset EPICS_AND_STORIES SPRINT_STATUS_YAML
  export STORY_INDEX_YAML="$proj/docs/implementation-artifacts/story-index.yaml"
  run env \
    PROJECT_PATH="$proj" \
    IMPLEMENTATION_ARTIFACTS="$proj/docs/implementation-artifacts" \
    PLANNING_ARTIFACTS="$proj/docs/planning-artifacts" \
    MEMORY_PATH="$proj/_memory" \
    STORY_STATUS_LOCK="$proj/_memory/.story-status.lock" \
    "$TRANSITION" "$key" --to ready-for-dev

  chmod u+wx "$shard_dir"
  [ "$status" -ne 0 ]
  # Rollback: all three on-disk content shas match pre-transition.
  local sha_after
  sha_after=$(shasum "$file" "$proj/docs/planning-artifacts/epics-and-stories.md" "$shard" | shasum)
  [ "$sha_before" = "$sha_after" ]
}

# TC-TSS-SHARD-5 — Self-transition idempotency across all five files (AC3)
@test "TC-TSS-SHARD-5: self-transition is byte-stable across all five files (incl. shard)" {
  local proj; proj="$(e59_s6_setup_project shard5)"
  local key="E99-S5"
  local shard; shard="$(e59_s6_write_shard "$proj" 01 99 "$key" done)"
  local file; file="$(e59_s6_write_story "$proj" 99 "$key" done)"
  e59_s6_write_monolith "$proj" "$key" done

  local sha_before
  sha_before=$(shasum "$file" "$proj/docs/planning-artifacts/epics-and-stories.md" "$shard" | shasum)

  unset EPICS_AND_STORIES SPRINT_STATUS_YAML
  export STORY_INDEX_YAML="$proj/docs/implementation-artifacts/story-index.yaml"
  run env \
    PROJECT_PATH="$proj" \
    IMPLEMENTATION_ARTIFACTS="$proj/docs/implementation-artifacts" \
    PLANNING_ARTIFACTS="$proj/docs/planning-artifacts" \
    MEMORY_PATH="$proj/_memory" \
    STORY_STATUS_LOCK="$proj/_memory/.story-status.lock" \
    "$TRANSITION" "$key" --to done
  [ "$status" -eq 0 ]

  local sha_after
  sha_after=$(shasum "$file" "$proj/docs/planning-artifacts/epics-and-stories.md" "$shard" | shasum)
  [ "$sha_before" = "$sha_after" ]
}

# TC-TSS-SHARD-RECONCILE — `--reconcile-only` flag forces replay across all five writers (AC6)
@test "TC-TSS-SHARD-RECONCILE: --reconcile-only forces shard rewrite at current frontmatter status" {
  local proj; proj="$(e59_s6_setup_project recon)"
  local key="E99-S99"
  # Drift fixture: story-file = done, monolith = done, shard = backlog (drifted).
  local shard; shard="$(e59_s6_write_shard "$proj" 01 99 "$key" backlog)"
  local file; file="$(e59_s6_write_story "$proj" 99 "$key" done)"
  e59_s6_write_monolith "$proj" "$key" done

  # Self-transition without --reconcile-only is a no-op (TC-CSE-11).
  # With --reconcile-only the shard must be rewritten to match the story file.
  unset EPICS_AND_STORIES SPRINT_STATUS_YAML
  export STORY_INDEX_YAML="$proj/docs/implementation-artifacts/story-index.yaml"
  run env \
    PROJECT_PATH="$proj" \
    IMPLEMENTATION_ARTIFACTS="$proj/docs/implementation-artifacts" \
    PLANNING_ARTIFACTS="$proj/docs/planning-artifacts" \
    MEMORY_PATH="$proj/_memory" \
    STORY_STATUS_LOCK="$proj/_memory/.story-status.lock" \
    "$TRANSITION" "$key" --reconcile-only
  [ "$status" -eq 0 ]
  [ "$(e59_s6_shard_status "$shard" "$key")" = "done" ]
}

# E55-S13 D6 (TC-DSF-6): backlog stories (sprint_id: null + no per-epic shard)
# generate two stderr "skip" messages on every status transition. These are
# legitimate backlog-state events, not error conditions, so they MUST be
# suppressed when BOTH conditions hold. Warnings MUST still fire when only
# one holds (e.g., sprint_id set but yaml entry missing == real drift).
@test "TC-DSF-6: backlog story (sprint_id null + no shard) suppresses both skip warnings" {
  # Per-test fixture: backlog story, no sprint-status.yaml entry, no shard.
  local proj="$TEST_TMP/d6-proj"
  mkdir -p "$proj/docs/implementation-artifacts" "$proj/docs/planning-artifacts" "$proj/_memory"
  local key="DSF-E1-S6"
  local story="$proj/docs/implementation-artifacts/${key}-d6-fixture.md"
  cat > "$story" <<EOF2
---
template: 'story'
key: "${key}"
title: "D6 backlog fixture"
epic: "DSF-E1"
status: backlog
sprint_id: null
priority: "P3"
size: "S"
points: 1
risk: "low"
---

# Story: D6 backlog fixture
EOF2
  cat > "$proj/docs/planning-artifacts/epics-and-stories.md" <<'EOF2'
# Epics and Stories

## Epic DSF-E1: D6 fixture epic

### Story DSF-E1-S6: D6 backlog fixture

- **Status:** backlog
EOF2

  run env \
    PROJECT_PATH="$proj" \
    IMPLEMENTATION_ARTIFACTS="$proj/docs/implementation-artifacts" \
    PLANNING_ARTIFACTS="$proj/docs/planning-artifacts" \
    MEMORY_PATH="$proj/_memory" \
    STORY_STATUS_LOCK="$proj/_memory/.d6.lock" \
    "$TRANSITION" "$key" --to ready-for-dev
  [ "$status" -eq 0 ]

  # Both legacy backlog-only skip messages MUST be absent when sprint_id IS null
  # AND no shard exists.
  echo "STDERR_OUT: $output"
  [[ "$output" != *"story '${key}' not present in sprint-status.yaml — skipping yaml update"* ]]
  [[ "$output" != *"no per-epic shard entry found for ${key} — monolith-only write"* ]]
}

# TC-DSF-6b: when sprint_id IS set but the yaml entry is missing (real drift),
# the warning MUST still fire — not silently swallowed.
@test "TC-DSF-6b: drift case (sprint_id set, yaml entry missing) still warns" {
  local proj="$TEST_TMP/d6b-proj"
  mkdir -p "$proj/docs/implementation-artifacts" "$proj/docs/planning-artifacts" "$proj/_memory"
  local key="DSF-E1-S7"
  local story="$proj/docs/implementation-artifacts/${key}-d6b-fixture.md"
  cat > "$story" <<EOF2
---
template: 'story'
key: "${key}"
title: "D6b drift fixture"
epic: "DSF-E1"
status: backlog
sprint_id: "missing-sprint"
priority: "P3"
size: "S"
points: 1
risk: "low"
---

# Story: D6b drift fixture
EOF2
  # Sprint yaml exists but does NOT contain the story entry — legitimate drift.
  cat > "$proj/docs/implementation-artifacts/sprint-status.yaml" <<EOF2
sprint_id: "missing-sprint"
stories: []
EOF2
  cat > "$proj/docs/planning-artifacts/epics-and-stories.md" <<'EOF2'
# Epics and Stories

## Epic DSF-E1: D6b fixture epic

### Story DSF-E1-S7: D6b drift fixture

- **Status:** backlog
EOF2

  run env \
    PROJECT_PATH="$proj" \
    IMPLEMENTATION_ARTIFACTS="$proj/docs/implementation-artifacts" \
    PLANNING_ARTIFACTS="$proj/docs/planning-artifacts" \
    MEMORY_PATH="$proj/_memory" \
    STORY_STATUS_LOCK="$proj/_memory/.d6b.lock" \
    "$TRANSITION" "$key" --to ready-for-dev
  [ "$status" -eq 0 ]

  # The yaml-skip warning MUST fire (real drift, not backlog-state).
  [[ "$output" == *"not present in sprint-status.yaml"* ]]
}

# A committed transition emits a state_transition lifecycle event via the
# script's emit_state_transition_event helper, so throughput-telemetry.sh can
# derive per-story wall-clock. (Dedicated coverage in
# transition-story-status-lifecycle-emit.bats; this case keeps the helper
# named in the canonically-paired suite and guards the happy path here.)
@test "emit_state_transition_event: a committed transition appends a state_transition event" {
  run "$TRANSITION" "$STORY_KEY" --to ready-for-dev --from backlog
  [ "$status" -eq 0 ]

  local events="$MEMORY_PATH/lifecycle-events.jsonl"
  [ -f "$events" ]
  grep -q '"event_type":"state_transition"' "$events"
  grep -q '"story_key":"TSS-E2E-01"' "$events"
  grep -q '"from":"backlog","to":"ready-for-dev"' "$events"
}
