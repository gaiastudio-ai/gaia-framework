#!/usr/bin/env bats
# sync-derived-artifacts.bats — unit tests for the delta-sync script that
# reconciles project-side designer changes into the derived ux-design.md.
#
# The script under test:
#   skills/gaia-design-review/scripts/sync-derived-artifacts.sh
#
# Contract:
#   sync-derived-artifacts.sh <snapshot-file> <ux-design-doc-path>
#   - snapshot-file: JSON/YAML listing components and screens from the project
#   - ux-design-doc-path: the derived ux-design.md to update
#   - Adds components/screens present in the snapshot but missing from the doc
#   - Never silently deletes: a removed component is reported, not dropped
#   - Values go in via strenv/--arg only (no shell expansion in yq)

load 'test_helper.bash'

fail() { printf 'FAIL: %s\n' "$1" >&2; return 1; }

_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

SYNC_SCRIPT=""

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SYNC_SCRIPT="$PLUGIN_ROOT/skills/gaia-design-review/scripts/sync-derived-artifacts.sh"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# _seed_stale_ux_doc DIR — create a ux-design.md missing "new-sidebar"
_seed_stale_ux_doc() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/ux-design.md" <<'UX'
---
template: ux-design
design_state: review
---

# UX Design

## Component Inventory

- header
- footer
- main-content

## Screen Specifications

### Home Screen

Standard landing page layout.

## Design Record Reference

Project reference: test-project-ref
UX
}

# _seed_snapshot DIR COMPONENTS... — create a project snapshot JSON.
# Uses jq --arg to safely encode component names containing quotes,
# dollar signs, backticks, newlines, and unicode.
_seed_snapshot() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local out="$dir/snapshot.json"
  # Build the array element by element via jq --arg
  local arr='[]'
  local c
  for c in "$@"; do
    arr="$(printf '%s' "$arr" | jq --arg v "$c" '. + [$v]')"
  done
  printf '%s' "$arr" | jq '{components: .}' > "$out"
  # Validate: the fixture must parse as valid JSON
  jq empty "$out" 2>/dev/null || {
    printf 'FAIL: _seed_snapshot produced invalid JSON\n' >&2
    return 1
  }
}


# =========================================================================
# Existence guard
# =========================================================================

@test "sync-derived-artifacts.sh exists and is executable" {
  [ -f "$SYNC_SCRIPT" ] || \
    fail "sync-derived-artifacts.sh does not exist: $SYNC_SCRIPT"
  [ -x "$SYNC_SCRIPT" ] || \
    fail "sync-derived-artifacts.sh is not executable: $SYNC_SCRIPT"
}


# =========================================================================
# Happy path: designer-added component appears after sync
# =========================================================================

@test "(AC4) sync adds designer-added component to ux-design.md" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  _seed_stale_ux_doc "$doc_dir"
  _seed_snapshot "$root" "header" "footer" "main-content" "new-sidebar"

  local ux_doc="$doc_dir/ux-design.md"

  # Pre-check: new-sidebar is absent
  ! grep -q 'new-sidebar' "$ux_doc" || fail "fixture already contains new-sidebar"

  run "$SYNC_SCRIPT" "$root/snapshot.json" "$ux_doc"
  [ "$status" -eq 0 ] || fail "sync failed: $output"

  # Post-check: new-sidebar is present
  grep -q 'new-sidebar' "$ux_doc" || \
    fail "ux-design.md does not contain new-sidebar after sync"

  rm -rf "$root"
}


# =========================================================================
# Idempotence: second run is byte-identical
# =========================================================================

@test "(AC4) sync is idempotent — second run produces byte-identical doc" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  _seed_stale_ux_doc "$doc_dir"
  _seed_snapshot "$root" "header" "footer" "main-content" "new-sidebar"

  local ux_doc="$doc_dir/ux-design.md"

  # First run
  run "$SYNC_SCRIPT" "$root/snapshot.json" "$ux_doc"
  [ "$status" -eq 0 ] || fail "first sync failed: $output"

  local sha_after_first
  sha_after_first="$(_sha256_file "$ux_doc")"

  # Second run
  run "$SYNC_SCRIPT" "$root/snapshot.json" "$ux_doc"
  [ "$status" -eq 0 ] || fail "second sync failed: $output"

  local sha_after_second
  sha_after_second="$(_sha256_file "$ux_doc")"

  [ "$sha_after_first" = "$sha_after_second" ] || \
    fail "second sync changed the doc: sha $sha_after_first -> $sha_after_second"

  rm -rf "$root"
}


# =========================================================================
# Removed component: reported, not silently dropped
# =========================================================================

@test "(AC4) sync reports a component removed designer-side instead of dropping it" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  _seed_stale_ux_doc "$doc_dir"
  # Snapshot is MISSING "footer" that the doc has
  _seed_snapshot "$root" "header" "main-content"

  local ux_doc="$doc_dir/ux-design.md"

  run "$SYNC_SCRIPT" "$root/snapshot.json" "$ux_doc"
  # The script should still succeed
  [ "$status" -eq 0 ] || fail "sync failed: $output"

  # "footer" must still be in the doc (never silently deleted)
  grep -q 'footer' "$ux_doc" || \
    fail "sync silently removed 'footer' from ux-design.md"

  # Output/stderr must mention the removed component
  [[ "$output" == *"footer"* ]] || \
    fail "sync did not report the removed component 'footer'"

  rm -rf "$root"
}


# =========================================================================
# Special-character round-trip via strenv/--arg
# =========================================================================

@test "(AC4) sync round-trips component names with special characters" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  _seed_stale_ux_doc "$doc_dir"

  local ux_doc="$doc_dir/ux-design.md"

  # Component name with quotes, $, backticks, and unicode
  local special_name='nav-"panel" $cost `exec` ñ日本🎨'
  # Build fixture via jq --arg so special chars produce valid JSON
  jq -n --arg c "$special_name" \
    '{"components":["header","footer","main-content",$c]}' \
    > "$root/snapshot.json"
  # Validate: the fixture must parse as valid JSON before we test
  jq empty "$root/snapshot.json" || fail "fixture produced invalid JSON"

  run "$SYNC_SCRIPT" "$root/snapshot.json" "$ux_doc"
  [ "$status" -eq 0 ] || fail "sync with special chars failed: $output"

  grep -qF "$special_name" "$ux_doc" || \
    fail "special-character component name not round-tripped in ux-design.md"

  rm -rf "$root"
}


# =========================================================================
# Argument errors
# =========================================================================

@test "sync fails with no arguments" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  run "$SYNC_SCRIPT"
  [ "$status" -ne 0 ] || fail "should fail with no arguments"
}

@test "sync fails with nonexistent snapshot file" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  run "$SYNC_SCRIPT" "/nonexistent/snapshot.json" "/nonexistent/ux-design.md"
  [ "$status" -ne 0 ] || fail "should fail with nonexistent snapshot file"
}

@test "sync fails with nonexistent doc path" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  _seed_snapshot "$root" "header"

  run "$SYNC_SCRIPT" "$root/snapshot.json" "/nonexistent/ux-design.md"
  [ "$status" -ne 0 ] || fail "should fail with nonexistent doc path"

  rm -rf "$root"
}


# =========================================================================
# Mutant: skip the sync — new-sidebar stays absent
# =========================================================================

@test "(AC4) mutant: without sync, designer-added component is absent" {
  # This mutant proves the sync is load-bearing.  First assert the script
  # exists (so the mutant is meaningful), then show that NOT running it
  # leaves the doc stale.
  [ -x "$SYNC_SCRIPT" ] || \
    fail "sync-derived-artifacts.sh does not exist — mutant test is premature"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  _seed_stale_ux_doc "$doc_dir"
  _seed_snapshot "$root" "header" "footer" "main-content" "new-sidebar"

  local ux_doc="$doc_dir/ux-design.md"

  # Do NOT run the sync script — mutant behaviour
  # The doc must still lack new-sidebar
  ! grep -q 'new-sidebar' "$ux_doc" || \
    fail "mutant: new-sidebar is present without running sync — fixture is wrong"

  rm -rf "$root"
}
