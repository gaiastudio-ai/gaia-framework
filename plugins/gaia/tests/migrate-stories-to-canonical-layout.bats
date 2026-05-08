#!/usr/bin/env bats
# migrate-stories-to-canonical-layout.bats — coverage for plugins/gaia/scripts/migrate-stories-to-canonical-layout.sh
#
# Story: E79-S6 — Migration script — backfill legacy flat stories + flat
#                 `story-index.yaml`.
# Trace: TC-CSP-9, TC-CSP-14, TC-CSP-15
# Refs:  AC1a, AC1b, AC2a, AC2b, AC3, AC4, AC5
#
# Per-AC test scenarios (1:1 mapping with ATDD skeletons in
# docs/test-artifacts/atdd-E79-S6.md):
#   - TS1 (golden, AC2a, TC-CSP-9):    flat-index merge into per-epic indices
#   - TS2 (non-git CWD, AC1b):         plain mv fallback + canonical notice
#   - TS3 (idempotency, AC3, TC-CSP-14): no-op rerun produces zero diffs
#   - TS4 (per-epic merge conflict):   per-epic entry wins, flat entry logged
#   - TS5 (unresolved residual, AC2b): flat index preserved + WARNING line
#   - TS6 (E77-S10/E77-S11 repro, AC4, TC-CSP-15): regression repro
#   - TS7 (post-condition probe, AC5): zero WARNING/CRITICAL after migration
#   - TS8 (AC1a):                       git mv flat-to-nested under git work tree

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  MIGRATE_SCRIPT="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/migrate-stories-to-canonical-layout.sh"
  CHECK_SCRIPT="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/check-story-layout-sync.sh"
  cd "$TEST_TMP"
  mkdir -p docs/implementation-artifacts docs/planning-artifacts
  # Seed a minimal epics-and-stories.md the resolver can read. Two epics so
  # the test grid can mix epics for index-merge coverage.
  cat > docs/planning-artifacts/epics-and-stories.md <<'EOF'
# Epics and stories

## E77 — Plugin Project Shape and Tooling (Phase 2 Tiers 1+2)

Phase 2 plugin tooling.

## E78 — Alpha epic for migration tests

Helper epic.

## E79 — Canonical Per-Epic Story-File Layout (`/gaia-create-story` Path Convergence)

Path convergence epic.
EOF
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Fixture helpers.
# ---------------------------------------------------------------------------

# Seed a flat story file at the legacy path. The frontmatter `epic:` value is
# derived from the story key prefix (E77-S10 -> E77).
_make_flat_story() {
  local story_key="$1" slug="$2"
  local epic_key="${story_key%-S*}"
  cat > "docs/implementation-artifacts/${story_key}-${slug}.md" <<EOF
---
key: "${story_key}"
title: "Legacy flat story ${story_key}"
epic: "${epic_key}"
status: ready-for-dev
---

# Body
EOF
}

# Initialize the current dir as a git work tree with an initial commit so
# `git mv` works.
_init_git_repo() {
  git init -q .
  git config user.email migration-test@example.invalid
  git config user.name "migration-test"
  git add -A
  git -c commit.gpgsign=false commit -q -m "seed" --allow-empty
}

# Deterministic snapshot of the directory tree (filenames + content hashes)
# for byte-identical idempotency assertions. Excludes .git.
_snapshot_tree() {
  find . -type f -not -path './.git/*' -not -name '.bats-tmp*' \
    | LC_ALL=C sort \
    | while IFS= read -r f; do
        printf '%s\n' "$f"
        if command -v shasum >/dev/null 2>&1; then
          shasum -a 256 "$f" | awk '{print $1}'
        else
          sha256sum "$f" | awk '{print $1}'
        fi
      done
}

# ---------------------------------------------------------------------------
# Tests.
# ---------------------------------------------------------------------------

# AC1a / TC-CSP-9 — git mv flat-to-nested migration inside a git work tree.
@test "AC1a: git mv flat-to-nested migration preserves history" {
  _make_flat_story "E77-S10" "some-slug"
  _init_git_repo

  run "$MIGRATE_SCRIPT"
  [ "$status" -eq 0 ]

  # Resolved destination uses the canonical epic-slug for E77.
  local moved="docs/implementation-artifacts/epic-E77-plugin-project-shape-and-tooling/stories/E77-S10-some-slug.md"
  [ -f "$moved" ]
  [ ! -f "docs/implementation-artifacts/E77-S10-some-slug.md" ]

  # git mv stages a rename — `git status --porcelain` shows an `R` entry
  # whose destination is the moved path.
  run git status --porcelain
  printf '%s\n' "$output" | grep -qE "^R.*${moved}"
}

# AC1b — Non-git CWD fallback uses plain mv with canonical notice.
@test "AC1b: non-git CWD fallback uses plain mv and emits canonical notice" {
  _make_flat_story "E77-S10" "some-slug"
  # Sanity: not inside a git work tree.
  run git rev-parse --is-inside-work-tree
  [ "$status" -ne 0 ]

  run "$MIGRATE_SCRIPT"
  [ "$status" -eq 0 ]

  # File moved.
  local moved="docs/implementation-artifacts/epic-E77-plugin-project-shape-and-tooling/stories/E77-S10-some-slug.md"
  [ -f "$moved" ]
  [ ! -f "docs/implementation-artifacts/E77-S10-some-slug.md" ]

  # Canonical fallback notice present on stderr.
  run env BATS_REUSE_STDIO=1 bash -c "'$MIGRATE_SCRIPT' 2>&1 1>/dev/null"
  # Not strictly needed since we re-ran; check that the notice is the
  # canonical text. We test the second call: tree is converged so nothing
  # moves, but the message is checked from a fresh fixture below.
}

# AC1b reinforced — the canonical notice is on stderr.
@test "AC1b: canonical 'non-git CWD: using plain mv' notice on stderr" {
  _make_flat_story "E77-S10" "some-slug"

  run --separate-stderr "$MIGRATE_SCRIPT"
  [ "$status" -eq 0 ]
  printf '%s\n' "$stderr" | grep -q 'non-git CWD: using plain mv'
}

# AC2a / TC-CSP-9 — flat story-index.yaml merges into per-epic indices and is
# deleted after every entry is drained.
@test "AC2a: flat story-index.yaml merges into per-epic indices and is deleted" {
  # Seed flat stories so the resolver has files to point at AND a flat index.
  _make_flat_story "E77-S10" "some-slug"
  _make_flat_story "E77-S11" "other-slug"
  cat > "docs/implementation-artifacts/story-index.yaml" <<'EOF'
last_updated: "2026-05-07T00:00:00Z"
stories:
  E77-S10:
    story_key: "E77-S10"
    title: "First"
    epic: "E77"
    priority: "P1"
    risk: "low"
    author: "Test"
    file: "E77-S10-some-slug.md"
    status: "ready-for-dev"
  E77-S11:
    story_key: "E77-S11"
    title: "Second"
    epic: "E77"
    priority: "P1"
    risk: "low"
    author: "Test"
    file: "E77-S11-other-slug.md"
    status: "ready-for-dev"
EOF

  run "$MIGRATE_SCRIPT"
  [ "$status" -eq 0 ]

  local per_epic="docs/implementation-artifacts/epic-E77-plugin-project-shape-and-tooling/story-index.yaml"
  [ -f "$per_epic" ]
  # Both keys present in the per-epic index.
  grep -q '^  E77-S10:' "$per_epic"
  grep -q '^  E77-S11:' "$per_epic"
  # Flat index is gone.
  [ ! -f "docs/implementation-artifacts/story-index.yaml" ]
}

# AC2b — unresolved residual preserves the flat index with a WARNING.
@test "AC2b: unresolved entries preserve flat index with WARNING" {
  cat > "docs/implementation-artifacts/story-index.yaml" <<'EOF'
last_updated: "2026-05-07T00:00:00Z"
stories:
  E999-S1:
    story_key: "E999-S1"
    title: "Orphan"
    epic: "E999"
    priority: "P1"
    risk: "low"
    author: "Test"
    file: "E999-S1-orphan.md"
    status: "ready-for-dev"
EOF

  run --separate-stderr "$MIGRATE_SCRIPT"
  [ "$status" -eq 0 ]

  # Flat index preserved.
  [ -f "docs/implementation-artifacts/story-index.yaml" ]

  # WARNING about residual unresolved entries on stderr.
  printf '%s\n' "$stderr" | grep -q 'WARNING: 1 unresolved entries retained in flat story-index.yaml'
}

# AC3 / TC-CSP-14 — idempotent rerun on a converged tree emits no-op notice
# and produces a byte-identical tree.
@test "AC3: idempotent rerun emits no-op notice (zero moves, zero writes)" {
  # Seed an already-converged per-epic story plus per-epic index. No flat files.
  mkdir -p "docs/implementation-artifacts/epic-E77-plugin-project-shape-and-tooling/stories"
  cat > "docs/implementation-artifacts/epic-E77-plugin-project-shape-and-tooling/stories/E77-S10-some-slug.md" <<'EOF'
---
key: "E77-S10"
title: "Already converged"
epic: "E77"
status: ready-for-dev
---

# Body
EOF
  cat > "docs/implementation-artifacts/epic-E77-plugin-project-shape-and-tooling/story-index.yaml" <<'EOF'
last_updated: "2026-05-07T00:00:00Z"
stories:
  E77-S10:
    story_key: "E77-S10"
    title: "Already converged"
    epic: "E77"
    priority: "P1"
    risk: "low"
    author: "Test"
    file: "E77-S10-some-slug.md"
    status: "ready-for-dev"
EOF

  local pre
  pre="$(_snapshot_tree)"

  run --separate-stderr "$MIGRATE_SCRIPT"
  [ "$status" -eq 0 ]
  printf '%s\n' "$stderr" | grep -q 'migration: no-op (already converged)'

  local post
  post="$(_snapshot_tree)"
  [ "$pre" = "$post" ]
}

# AC4 / TC-CSP-15 — E77-S10 / E77-S11 regression repro.
@test "AC4: E77-S10/E77-S11 regression repro lands both under nested layout" {
  _make_flat_story "E77-S10" "flat-landing"
  _make_flat_story "E77-S11" "flat-landing"

  run "$MIGRATE_SCRIPT"
  [ "$status" -eq 0 ]

  for key in E77-S10 E77-S11; do
    local moved="docs/implementation-artifacts/epic-E77-plugin-project-shape-and-tooling/stories/${key}-flat-landing.md"
    [ -f "$moved" ]
    # frontmatter epic: agrees with destination epic key.
    grep -q '^epic: "E77"' "$moved"
  done
}

# AC5 — post-condition probe: check-story-layout-sync.sh reports zero
# WARNING / CRITICAL after migration.
@test "AC5: post-condition probe — check-story-layout-sync.sh clean" {
  _make_flat_story "E77-S10" "some-slug"

  run --separate-stderr "$MIGRATE_SCRIPT"
  [ "$status" -eq 0 ]
  printf '%s\n' "$stderr" \
    | grep -q 'migration: post-condition PASSED (check-story-layout-sync.sh clean)'

  # Independent re-run of the advisory script should be quiet too.
  run "$CHECK_SCRIPT"
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -q '^WARNING'
  ! printf '%s\n' "$output" | grep -q '^CRITICAL'
}

# Per-epic merge conflict — existing per-epic entry wins, flat entry logged.
@test "TS4: per-epic index merge conflict — per-epic entry wins" {
  _make_flat_story "E77-S10" "some-slug"
  # Pre-seed per-epic index with a conflicting entry.
  mkdir -p "docs/implementation-artifacts/epic-E77-plugin-project-shape-and-tooling"
  cat > "docs/implementation-artifacts/epic-E77-plugin-project-shape-and-tooling/story-index.yaml" <<'EOF'
last_updated: "2026-05-07T00:00:00Z"
stories:
  E77-S10:
    story_key: "E77-S10"
    title: "Per-epic wins"
    epic: "E77"
    priority: "P0"
    risk: "low"
    author: "Pre-Existing"
    file: "E77-S10-some-slug.md"
    status: "in-progress"
EOF
  # Flat index has a conflicting entry.
  cat > "docs/implementation-artifacts/story-index.yaml" <<'EOF'
last_updated: "2026-05-07T00:00:00Z"
stories:
  E77-S10:
    story_key: "E77-S10"
    title: "Flat losing"
    epic: "E77"
    priority: "P9"
    risk: "high"
    author: "Flat-Author"
    file: "E77-S10-some-slug.md"
    status: "ready-for-dev"
EOF

  run --separate-stderr "$MIGRATE_SCRIPT"
  [ "$status" -eq 0 ]

  # Per-epic entry preserved (title `Per-epic wins`).
  grep -q 'Per-epic wins' "docs/implementation-artifacts/epic-E77-plugin-project-shape-and-tooling/story-index.yaml"
  ! grep -q 'Flat losing' "docs/implementation-artifacts/epic-E77-plugin-project-shape-and-tooling/story-index.yaml"
  # Flat index drained and deleted.
  [ ! -f "docs/implementation-artifacts/story-index.yaml" ]
  # INFO log line emitted on stderr.
  printf '%s\n' "$stderr" | grep -q 'INFO: index-merge conflict on E77-S10: keeping per-epic entry'
}
