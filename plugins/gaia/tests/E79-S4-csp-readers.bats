#!/usr/bin/env bats
# E79-S4-csp-readers.bats — TC-CSP-10..13 reader-convergence tests for the
# canonical per-epic story-file layout (E79 cluster).
#
# Coverage:
#   TC-CSP-10 — `/gaia-sprint-plan` Step 2 prose contract describes the
#               canonical recursive scan idiom and the legacy-flat fallback.
#   TC-CSP-11 — `pflag_scan_backlog` walks `epic-*/stories/**/*.md`
#               recursively; nested-flagged AND flat-flagged surface;
#               nested-null is excluded; non-story `.md` is skipped.
#   TC-CSP-12 — `validate-canonical-filename.sh` rejects legacy-flat shadow
#               state (nested + flat sibling for same key) with the canonical
#               stderr line.
#   TC-CSP-13 — `dead-reference-scan.sh` is empty-dir tolerant on epic-*/
#               and emits no false-positive references to story-file paths.
#   Edge      — empty epic dir (no stories/ subdir) produces no error.
#   Edge      — non-story `.md` under stories/ is skipped by pflag.
#
# Story: E79-S4 (P0, M, 5 pts, medium risk; sprint-40)
# =============================================================================

set -euo pipefail

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
PRIORITY_FLAG_SH="$PLUGIN_DIR/scripts/priority-flag.sh"
VALIDATE_CANONICAL="$PLUGIN_DIR/skills/gaia-create-story/scripts/validate-canonical-filename.sh"
DEAD_REF_SCAN="$PLUGIN_DIR/scripts/dead-reference-scan.sh"
SPRINT_PLAN_SKILL="$PLUGIN_DIR/skills/gaia-sprint-plan/SKILL.md"

setup() {
  TEST_TMP="${BATS_TEST_TMPDIR:-/tmp}/gaia-e79-s4-$$-$BATS_TEST_NUMBER"
  mkdir -p "$TEST_TMP/docs/implementation-artifacts"
  IMPL="$TEST_TMP/docs/implementation-artifacts"
  export IMPL TEST_TMP
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP" 2>/dev/null || true
  fi
}

# Helper: write a nested story file at epic-<slug>/stories/<key>-<slug>.md
write_nested_story() {
  local epic_slug="$1" key="$2" slug="$3" status="$4" pflag="${5:-null}"
  local dir="$IMPL/epic-$epic_slug/stories"
  mkdir -p "$dir"
  local path="$dir/$key-$slug.md"
  local pflag_line
  if [ "$pflag" = "null" ]; then
    pflag_line='priority_flag: null'
  else
    pflag_line="priority_flag: \"$pflag\""
  fi
  cat >"$path" <<EOF
---
key: "$key"
title: "$slug"
status: $status
$pflag_line
---

# $key
EOF
  printf '%s\n' "$path"
}

# Helper: write a flat-path story file at <key>-<slug>.md (legacy)
write_flat_story() {
  local key="$1" slug="$2" status="$3" pflag="${4:-null}"
  local path="$IMPL/$key-$slug.md"
  local pflag_line
  if [ "$pflag" = "null" ]; then
    pflag_line='priority_flag: null'
  else
    pflag_line="priority_flag: \"$pflag\""
  fi
  cat >"$path" <<EOF
---
key: "$key"
title: "$slug"
status: $status
$pflag_line
---

# $key
EOF
  printf '%s\n' "$path"
}

# ---------------------------------------------------------------------------
# TC-CSP-10 — sprint-plan SKILL.md prose contract describes recursive walk
# ---------------------------------------------------------------------------
@test "TC-CSP-10: sprint-plan Step 2 prose names the canonical recursive idiom" {
  [ -f "$SPRINT_PLAN_SKILL" ]
  run grep -E "epic-\*/stories/|find .* -path .\*/stories/\*\.md" "$SPRINT_PLAN_SKILL"
  [ "$status" -eq 0 ]
}

@test "TC-CSP-10: sprint-plan Step 2 prose mentions legacy-flat fallback warning" {
  [ -f "$SPRINT_PLAN_SKILL" ]
  run grep -F "legacy-flat" "$SPRINT_PLAN_SKILL"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# TC-CSP-11 — pflag_scan_backlog walks nested epic dirs recursively
# ---------------------------------------------------------------------------
@test "TC-CSP-11: pflag_scan_backlog finds nested-flagged stories under epic-*/stories/" {
  write_nested_story "E79-canonical" "E79-S99" "demo-flagged" "backlog" "next-sprint" >/dev/null
  write_nested_story "E76-meeting"   "E76-S99" "demo-flagged" "backlog" "next-sprint" >/dev/null

  source "$PRIORITY_FLAG_SH"
  run pflag_scan_backlog "$IMPL"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "E79-S99"
  echo "$output" | grep -qx "E76-S99"
}

@test "TC-CSP-11: pflag_scan_backlog excludes nested-null stories" {
  write_nested_story "E79-canonical" "E79-S99" "demo-flagged" "backlog" "next-sprint" >/dev/null
  write_nested_story "E79-canonical" "E79-S98" "demo-unflagged" "backlog" "null" >/dev/null

  source "$PRIORITY_FLAG_SH"
  run pflag_scan_backlog "$IMPL"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "E79-S99"
  if echo "$output" | grep -qx "E79-S98"; then
    echo "unexpected: nested-null story surfaced" >&2
    return 1
  fi
}

@test "TC-CSP-11: pflag_scan_backlog still surfaces flat-flagged stories (legacy fallback)" {
  write_flat_story "E20-S99" "demo-flat-flagged" "backlog" "next-sprint" >/dev/null

  source "$PRIORITY_FLAG_SH"
  run pflag_scan_backlog "$IMPL"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "E20-S99"
}

@test "TC-CSP-11 edge: pflag_scan_backlog skips non-story .md under stories/ without erroring" {
  mkdir -p "$IMPL/epic-E79-canonical/stories"
  printf '# Just a README, no frontmatter\n' >"$IMPL/epic-E79-canonical/stories/README.md"
  write_nested_story "E79-canonical" "E79-S99" "demo-flagged" "backlog" "next-sprint" >/dev/null

  source "$PRIORITY_FLAG_SH"
  run pflag_scan_backlog "$IMPL"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "E79-S99"
}

@test "TC-CSP-11 edge: pflag_scan_backlog tolerates empty epic dir without stories/ subdir" {
  mkdir -p "$IMPL/epic-E99-empty"

  source "$PRIORITY_FLAG_SH"
  run pflag_scan_backlog "$IMPL"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# TC-CSP-12 — validate-canonical-filename rejects shadow (nested + flat sibling)
# ---------------------------------------------------------------------------
@test "TC-CSP-12: validate-canonical-filename rejects legacy-flat shadow for same key" {
  # Use the slugify the script will produce to ensure basename matches.
  local nested_path
  nested_path=$(write_nested_story "E79-canonical" "E79-S99" "demo-shadow-title" "ready-for-dev" "null")
  # Need to use the actual slug produced by slugify.sh — re-derive it.
  local slug_dir slug_basename slug
  slug=$("$PLUGIN_DIR/skills/gaia-create-story/scripts/slugify.sh" --title "demo-shadow-title")
  local correct_nested="$IMPL/epic-E79-canonical/stories/E79-S99-$slug.md"
  if [ "$nested_path" != "$correct_nested" ]; then
    mv "$nested_path" "$correct_nested"
  fi

  # Add flat sibling for same key
  write_flat_story "E79-S99" "$slug" "ready-for-dev" "null" >/dev/null

  run "$VALIDATE_CANONICAL" --file "$correct_nested"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F "legacy-flat sibling detected for E79-S99"
}

@test "TC-CSP-12: validate-canonical-filename accepts nested-only (no shadow)" {
  local nested_path
  nested_path=$(write_nested_story "E79-canonical" "E79-S99" "demo-nested-only-title" "ready-for-dev" "null")
  local slug
  slug=$("$PLUGIN_DIR/skills/gaia-create-story/scripts/slugify.sh" --title "demo-nested-only-title")
  local correct_nested="$IMPL/epic-E79-canonical/stories/E79-S99-$slug.md"
  if [ "$nested_path" != "$correct_nested" ]; then
    mv "$nested_path" "$correct_nested"
  fi

  run "$VALIDATE_CANONICAL" --file "$correct_nested"
  [ "$status" -eq 0 ]
}

@test "TC-CSP-12: validate-canonical-filename accepts flat-only with WARNING (legacy fallback)" {
  local flat_path
  flat_path=$(write_flat_story "E20-S99" "demo-flat-fallback-title" "ready-for-dev" "null")
  local slug
  slug=$("$PLUGIN_DIR/skills/gaia-create-story/scripts/slugify.sh" --title "demo-flat-fallback-title")
  local correct_flat="$IMPL/E20-S99-$slug.md"
  if [ "$flat_path" != "$correct_flat" ]; then
    mv "$flat_path" "$correct_flat"
  fi

  run "$VALIDATE_CANONICAL" --file "$correct_flat"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "legacy-flat path accepted"
}

# ---------------------------------------------------------------------------
# TC-CSP-13 — dead-reference-scan.sh empty-dir tolerance & no false positive
# ---------------------------------------------------------------------------
@test "TC-CSP-13: dead-reference-scan tolerates an empty epic-* dir under docs/implementation-artifacts" {
  # Set up minimal project root with empty epic-* subdir
  local proj="$TEST_TMP/proj"
  mkdir -p "$proj/docs/implementation-artifacts/epic-E99-empty"
  mkdir -p "$proj/plugins/gaia/scripts"
  printf '#!/bin/sh\necho ok\n' >"$proj/plugins/gaia/scripts/clean.sh"

  run "$DEAD_REF_SCAN" --project-root "$proj"
  [ "$status" -eq 0 ]
}

@test "TC-CSP-13: dead-reference-scan does not false-positive on canonical nested story-file path strings" {
  # A canonical-nested story-file path is NOT a retired engine path, so the
  # scan PATTERN must not match. Plant a fake plugin script that mentions a
  # canonical nested path as a comment — the scan should still report CLEAN.
  local proj="$TEST_TMP/proj"
  mkdir -p "$proj/plugins/gaia/scripts"
  cat >"$proj/plugins/gaia/scripts/example.sh" <<'EOF'
#!/bin/sh
# Example: docs/implementation-artifacts/epic-E79-canonical/stories/E79-S4-readers.md
echo ok
EOF

  run "$DEAD_REF_SCAN" --project-root "$proj"
  [ "$status" -eq 0 ]
}
