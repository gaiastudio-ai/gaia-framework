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

# _find_enclosing_project — walk up from the test file's directory to find
# the nearest .gaia/config/project-config.yaml.  Returns the project root
# or empty if none exists (e.g. CI checkout with no enclosing project).
_find_enclosing_project() {
  local dir
  dir="$(cd "$BATS_TEST_DIRNAME" && pwd)"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/.gaia/config/project-config.yaml" ]; then
      printf '%s' "$dir"
      return
    fi
    dir="$(dirname "$dir")"
  done
}

setup_file() {
  # Snapshot the real baseline state once per file, so teardown can
  # detect a leak without ever deleting or modifying the file.
  _ENCLOSING_PROJECT="$(_find_enclosing_project)"
  export _ENCLOSING_PROJECT
  if [ -n "$_ENCLOSING_PROJECT" ]; then
    _REAL_BASELINE="${_ENCLOSING_PROJECT}/.gaia/state/design-token-baseline.json"
    export _REAL_BASELINE
    if [ -f "$_REAL_BASELINE" ]; then
      _BASELINE_EXISTED=true
      if command -v sha256sum >/dev/null 2>&1; then
        _BASELINE_HASH="$(sha256sum "$_REAL_BASELINE" | awk '{print $1}')"
      else
        _BASELINE_HASH="$(shasum -a 256 "$_REAL_BASELINE" | awk '{print $1}')"
      fi
    else
      _BASELINE_EXISTED=false
      _BASELINE_HASH=""
    fi
    export _BASELINE_EXISTED _BASELINE_HASH
  fi
}

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SYNC_SCRIPT="$PLUGIN_ROOT/skills/gaia-design-review/scripts/sync-derived-artifacts.sh"
  # Isolate every test from the real project's config tree. Export
  # PROJECT_ROOT to a temp directory with no .gaia/config/ ancestor,
  # so the walk-up in _resolve_token_baseline never reaches the real
  # project and never writes the real baseline.
  export PROJECT_ROOT="$TEST_TMP"
}

teardown() {
  common_teardown
  # Safety guard: detect if any test changed the real baseline.
  # Never delete or modify the file — it may be legitimate state.
  # On CI or when no enclosing project exists, skip silently.
  [ -n "${_ENCLOSING_PROJECT:-}" ] || return 0
  if [ "$_BASELINE_EXISTED" = true ]; then
    # File existed before the suite — verify it was not changed
    if [ ! -f "$_REAL_BASELINE" ]; then
      printf 'TEARDOWN FAILURE: test deleted the real baseline %s\n' "$_REAL_BASELINE" >&2
      return 1
    fi
    local current_hash
    if command -v sha256sum >/dev/null 2>&1; then
      current_hash="$(sha256sum "$_REAL_BASELINE" | awk '{print $1}')"
    else
      current_hash="$(shasum -a 256 "$_REAL_BASELINE" | awk '{print $1}')"
    fi
    if [ "$current_hash" != "$_BASELINE_HASH" ]; then
      printf 'TEARDOWN FAILURE: test modified the real baseline %s (hash %s -> %s)\n' \
        "$_REAL_BASELINE" "$_BASELINE_HASH" "$current_hash" >&2
      return 1
    fi
  else
    # File did not exist before — it must not have been created
    if [ -f "$_REAL_BASELINE" ]; then
      printf 'TEARDOWN FAILURE: test created the real baseline %s\n' "$_REAL_BASELINE" >&2
      return 1
    fi
  fi
}

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


# =========================================================================
# Newline injection — control characters in component names
# =========================================================================

@test "sync rejects component names containing newline characters" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  _seed_stale_ux_doc "$doc_dir"

  local ux_doc="$doc_dir/ux-design.md"
  local sha_before
  sha_before="$(_sha256_file "$ux_doc")"

  # Build a snapshot with a component containing a literal newline via jq
  printf '{"components":["header","footer","main-content","evil\\ninjection"]}\n' \
    > "$root/snapshot.json"

  run "$SYNC_SCRIPT" "$root/snapshot.json" "$ux_doc"
  # Must exit non-zero
  [ "$status" -ne 0 ] || \
    fail "should reject component name containing newline"

  # Doc must be byte-identical (no partial write)
  local sha_after
  sha_after="$(_sha256_file "$ux_doc")"
  [ "$sha_before" = "$sha_after" ] || \
    fail "doc changed despite rejected component — partial write occurred"

  # stderr should name the offending component
  local cleaned_output
  cleaned_output="$(printf '%s' "$output" | sed "s|${root}||g")"
  [[ "$cleaned_output" == *"control"* ]] || [[ "$cleaned_output" == *"newline"* ]] || [[ "$cleaned_output" == *"invalid"* ]] || \
    fail "should report the control-character rejection on stderr: $cleaned_output"

  rm -rf "$root"
}

@test "sync rejects component names containing carriage return" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  _seed_stale_ux_doc "$doc_dir"

  local ux_doc="$doc_dir/ux-design.md"
  local sha_before
  sha_before="$(_sha256_file "$ux_doc")"

  # Build a snapshot with a component containing a literal CR via jq
  printf '{"components":["header","footer","main-content","evil\\rreturn"]}\n' \
    > "$root/snapshot.json"

  run "$SYNC_SCRIPT" "$root/snapshot.json" "$ux_doc"
  [ "$status" -ne 0 ] || \
    fail "should reject component name containing carriage return"

  local sha_after
  sha_after="$(_sha256_file "$ux_doc")"
  [ "$sha_before" = "$sha_after" ] || \
    fail "doc changed despite rejected component — partial write occurred"

  rm -rf "$root"
}


# =========================================================================
# Batch performance — 200 new components under 3 seconds
# =========================================================================

# =========================================================================
# Template heading: & variant (AC1)
# =========================================================================

@test "(AC1) sync adds component to doc with template ampersand heading" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
design_state: review
---

# UX Design

## 8. Components & Design System

| Component | Source | Notes |
|-----------|--------|-------|
| header | custom | top bar |

## 9. Design Record Reference

Project reference: test-project-ref
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["header","sidebar","modal"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # The two new components must be in the doc
  grep -q 'sidebar' "$doc_dir/ux-design.md" || \
    fail "sidebar not added to doc after sync"
  grep -q 'modal' "$doc_dir/ux-design.md" || \
    fail "modal not added to doc after sync"

  # "added" diagnostic must appear for new components
  [[ "$output" == *'added'*'sidebar'* ]] || \
    fail "no 'added' diagnostic for sidebar: $output"

  # File must have changed (sha differs from fixture)
  local sha_after
  sha_after="$(_sha256_file "$doc_dir/ux-design.md")"
  [ -n "$sha_after" ] || fail "sha256 computation failed"

  # Position: rows must land directly after the last original data row
  local header_ln sidebar_ln modal_ln
  header_ln="$(grep -n '| header |' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  sidebar_ln="$(grep -n 'sidebar' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  modal_ln="$(grep -n 'modal' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  [ "$sidebar_ln" -eq "$((header_ln + 1))" ] || \
    fail "sidebar row not directly after the last table row (expected line $((header_ln + 1)), got $sidebar_ln)"
  [ "$modal_ln" -eq "$((header_ln + 2))" ] || \
    fail "modal row not consecutive after sidebar (expected line $((header_ln + 2)), got $modal_ln)"

  rm -rf "$root"
}


# =========================================================================
# Template heading: and variant (AC5)
# =========================================================================

@test "(AC5) sync adds component to doc with template and heading" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
design_state: review
---

# UX Design

## 8. Components and Design System

- existing-button

## 9. Design Record Reference

Project reference: test-project-ref
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["existing-button","new-card"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  grep -q 'new-card' "$doc_dir/ux-design.md" || \
    fail "new-card not added to doc with 'and' variant heading"

  rm -rf "$root"
}


# =========================================================================
# Legacy heading backward compat (AC-EC1) — regression guard, green
# =========================================================================

@test "(AC-EC1) sync adds component to doc with legacy Component Inventory heading" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  _seed_stale_ux_doc "$doc_dir"
  _seed_snapshot "$root" "header" "footer" "main-content" "legacy-widget"

  local ux_doc="$doc_dir/ux-design.md"

  run "$SYNC_SCRIPT" "$root/snapshot.json" "$ux_doc"
  [ "$status" -eq 0 ] || fail "sync failed: $output"

  grep -q 'legacy-widget' "$ux_doc" || \
    fail "legacy-widget not added under legacy Component Inventory heading"

  rm -rf "$root"
}


# =========================================================================
# Neither heading present (AC-EC2)
# =========================================================================

@test "(AC-EC2) sync exits non-zero when neither heading is present" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Some Other Section

Content here.

## Another Section

More content.
UX

  local ux_doc="$doc_dir/ux-design.md"
  local sha_before
  sha_before="$(_sha256_file "$ux_doc")"

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["new-widget"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$ux_doc"

  # Must exit non-zero
  [ "$status" -ne 0 ] || \
    fail "should exit non-zero when neither heading is present (exit $status): $output"

  # No "added" lines
  local added_count
  added_count="$(printf '%s\n' "$output" | grep -c 'added' || true)"
  [ "$added_count" -eq 0 ] || \
    fail "should print no 'added' lines when heading is missing, got $added_count"

  # File byte-unchanged
  local sha_after
  sha_after="$(_sha256_file "$ux_doc")"
  [ "$sha_before" = "$sha_after" ] || \
    fail "doc changed despite missing heading: sha $sha_before -> $sha_after"

  # Diagnostic should name both headings
  [[ "$output" == *"Components"* ]] || \
    fail "diagnostic should name the expected headings: $output"

  rm -rf "$root"
}


# =========================================================================
# False-success prevention (AC2) — "added" not printed when heading missing
# =========================================================================

@test "(AC2) added diagnostic not printed when file is byte-unchanged" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  # A doc with a heading the current code does NOT match (template heading).
  # The current buggy code prints "added" before the write attempt, so this
  # test must FAIL against the unmodified code.
  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- existing-widget

## 9. Design Record Reference
UX

  local ux_doc="$doc_dir/ux-design.md"
  local sha_before
  sha_before="$(_sha256_file "$ux_doc")"

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["brand-new-thing"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$ux_doc"

  # Regardless of exit code, check the invariant:
  # If the file did not change, "added" must not appear.
  local sha_after
  sha_after="$(_sha256_file "$ux_doc")"

  if [ "$sha_before" = "$sha_after" ]; then
    # File unchanged — "added" must NOT appear
    local added_count
    added_count="$(printf '%s\n' "$output" | grep -c 'added' || true)"
    [ "$added_count" -eq 0 ] || \
      fail "printed 'added' $added_count time(s) but file is byte-unchanged"
  fi

  # If the file DID change, the test passes — the implementation correctly
  # matched the heading and wrote the component. The "added" is truthful.
  # This path is the green state after the fix.

  rm -rf "$root"
}


# =========================================================================
# Table-row components: session fixture (AC-EC6)
# =========================================================================

@test "(AC-EC6) sync handles existing table-row components without false additions" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"

  # Session section 8 fixture: 8 components as table rows
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
design_state: review
---

# UX Design

## 8. Components & Design System

| Component | Source | Notes |
|-----------|--------|-------|
| BottomNavigation | React Navigation | Tab navigator |
| ExerciseCard | Custom | Swipeable card |
| ProgressRing | Custom | Circular progress |
| WeeklyCalendar | Custom | Horizontal scroll |
| StatBadge | Custom | Metric display |
| QuickLogButton | Custom | FAB variant |
| StreakCounter | Custom | Gamification |
| GoalTracker | Custom | Progress toward goal |

## 9. Design Record Reference

Project reference: session-ref
UX

  local ux_doc="$doc_dir/ux-design.md"
  local sha_before
  sha_before="$(_sha256_file "$ux_doc")"

  # Snapshot with exactly the same 8 components
  local snapshot="$root/snapshot.json"
  jq -n '{"components":["BottomNavigation","ExerciseCard","ProgressRing","WeeklyCalendar","StatBadge","QuickLogButton","StreakCounter","GoalTracker"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$ux_doc"

  # Exit 0 (no error)
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # File must be byte-identical — no additions
  local sha_after
  sha_after="$(_sha256_file "$ux_doc")"
  [ "$sha_before" = "$sha_after" ] || \
    fail "doc changed despite all components already present: sha $sha_before -> $sha_after"

  # No "added" lines
  local added_count
  added_count="$(printf '%s\n' "$output" | grep -c 'added' || true)"
  [ "$added_count" -eq 0 ] || \
    fail "printed 'added' $added_count time(s) but all 8 components already exist"

  # No "absent" lines for header/separator row cells
  local absent_component
  absent_component="$(printf '%s\n' "$output" | grep -i 'absent' | grep -iE 'Component|---' || true)"
  [ -z "$absent_component" ] || \
    fail "reported header/separator row as absent: $absent_component"

  rm -rf "$root"
}


# =========================================================================
# Screen change reported with boundary markers (AC3)
# =========================================================================

# _write_screen_file DIR NAME BODY — write a realistic screen spec file
# with a trailing newline (as a real file would have).
_write_screen_file() {
  local dir="$1" name="$2" body="$3"
  mkdir -p "$dir"
  printf '%s\n' "$body" > "$dir/$name"
}

@test "(AC3) screen change reported with boundary markers" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- existing-nav

## 9. Design Record Reference
UX

  local ux_doc="$doc_dir/ux-design.md"
  local sha_before
  sha_before="$(_sha256_file "$ux_doc")"

  # Write a realistic screen file with trailing newline, then hash the FILE
  local screens_dir="$root/screens"
  _write_screen_file "$screens_dir" "old-home.spec.html" "<h1>Old Home</h1>"
  local old_hash
  old_hash="$(_sha256_file "$screens_dir/old-home.spec.html")"

  local baseline="$root/baseline.json"
  jq -n --arg f "screens/home.spec.html" --arg h "$old_hash" \
    '{"product_design":{"files":[{"file": $f, "hash": $h}]}}' > "$baseline"

  # Write a DIFFERENT screen file and build the snapshot via --rawfile
  _write_screen_file "$screens_dir" "new-home.spec.html" "<h1>New Home</h1>"
  local snapshot="$root/snapshot.json"
  jq -n --rawfile c "$screens_dir/new-home.spec.html" \
    '{"components":[],"screens":[{"name":"Home Screen","file":"screens/home.spec.html","content":$c}]}' > "$snapshot"

  run "$SYNC_SCRIPT" --project product_design --last-published "$baseline" \
    "$snapshot" "$ux_doc"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Must contain boundary markers
  [[ "$output" == *'<<<PRODUCT_DESIGN_PROJECT_BOUNDARY>>>'* ]] || \
    fail "missing opening boundary marker: $output"
  [[ "$output" == *'<<<END_PRODUCT_DESIGN_PROJECT_BOUNDARY>>>'* ]] || \
    fail "missing closing boundary marker: $output"

  # Must contain the screen content
  [[ "$output" == *"<h1>New Home</h1>"* ]] || \
    fail "screen content not in report: $output"

  # Must NOT contain false "added component" lines
  local added_count
  added_count="$(printf '%s\n' "$output" | grep -c 'added component' || true)"
  [ "$added_count" -eq 0 ] || \
    fail "false 'added component' lines for screen-only sync ($added_count)"

  # UX doc must be byte-unchanged (screen changes are reported, not written)
  local sha_after
  sha_after="$(_sha256_file "$ux_doc")"
  [ "$sha_before" = "$sha_after" ] || \
    fail "UX doc changed during screen reporting: sha $sha_before -> $sha_after"

  rm -rf "$root"
}


# =========================================================================
# Unchanged screens produce no report (AC-EC5)
# =========================================================================

@test "(AC-EC5) unchanged screen with trailing newline produces no report" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Component Inventory

- nav

## Design Record Reference
UX

  # Write realistic screen files WITH trailing newlines, hash the FILES
  local screens_dir="$root/screens"
  _write_screen_file "$screens_dir" "settings.spec.html" "<h1>Settings</h1>\n<p>Preferences</p>"
  _write_screen_file "$screens_dir" "profile.spec.html" "<h1>Profile</h1>\n<p>User info</p>"

  local hash_settings hash_profile
  hash_settings="$(_sha256_file "$screens_dir/settings.spec.html")"
  hash_profile="$(_sha256_file "$screens_dir/profile.spec.html")"

  # Baseline with the FILE hashes (these include the trailing newline)
  local baseline="$root/baseline.json"
  jq -n --arg f1 "screens/settings.spec.html" --arg h1 "$hash_settings" \
        --arg f2 "screens/profile.spec.html" --arg h2 "$hash_profile" \
    '{"product_design":{"files":[{"file": $f1, "hash": $h1}, {"file": $f2, "hash": $h2}]}}' > "$baseline"

  # Build snapshot with identical content via --rawfile (preserves exact bytes)
  local snapshot="$root/snapshot.json"
  jq -n --rawfile c1 "$screens_dir/settings.spec.html" \
        --rawfile c2 "$screens_dir/profile.spec.html" \
    '{"components":["nav"],"screens":[
      {"name":"Settings","file":"screens/settings.spec.html","content":$c1},
      {"name":"Profile","file":"screens/profile.spec.html","content":$c2}
    ]}' > "$snapshot"

  run "$SYNC_SCRIPT" --project product_design --last-published "$baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # No screen report (no boundary markers, no screen-changed lines)
  [[ "$output" != *'PRODUCT_DESIGN_PROJECT_BOUNDARY'* ]] || \
    fail "boundary markers present for unchanged screens: $output"
  local screen_count
  screen_count="$(printf '%s\n' "$output" | grep -ci 'screen.*changed\|screen.*baseline' || true)"
  [ "$screen_count" -eq 0 ] || \
    fail "screen report emitted for unchanged screens ($screen_count lines)"

  rm -rf "$root"
}


# =========================================================================
# Screen name with control characters rejected (AC-EC8)
# =========================================================================

@test "(AC-EC8) screen name with control characters rejected" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Component Inventory

- nav

## Design Record Reference
UX

  # Screen name with embedded newline
  local snapshot="$root/snapshot.json"
  printf '{"components":["nav"],"screens":[{"name":"evil\\nscreen","file":"screens/evil.spec.html","content":"some body"}]}\n' > "$snapshot"

  run "$SYNC_SCRIPT" --project product_design "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -ne 0 ] || \
    fail "should reject screen name with control characters (exit $status): $output"

  # Diagnostic must mention control characters or invalid
  [[ "$output" == *"control"* ]] || [[ "$output" == *"invalid"* ]] || \
    fail "diagnostic should mention control characters: $output"

  rm -rf "$root"
}


# =========================================================================
# Screens-only snapshot, no components key (AC-EC7)
# =========================================================================

@test "(AC-EC7) snapshot with screens but no components key" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Component Inventory

- nav

## Design Record Reference
UX

  local ux_doc="$doc_dir/ux-design.md"
  local sha_before
  sha_before="$(_sha256_file "$ux_doc")"

  # Snapshot with screens but NO components key
  local snapshot="$root/snapshot.json"
  jq -n '{"screens":[{"name":"Home","file":"screens/home.spec.html","content":"home body"}]}' > "$snapshot"

  run "$SYNC_SCRIPT" --project product_design "$snapshot" "$ux_doc"

  [ "$status" -eq 0 ] || \
    fail "should exit 0 with screens-only snapshot (exit $status): $output"

  # Screen report should be produced
  [[ "$output" == *"Home"* ]] || \
    fail "screen report should mention the screen name: $output"

  # UX doc must be byte-unchanged (screens are reported, not written)
  local sha_after
  sha_after="$(_sha256_file "$ux_doc")"
  [ "$sha_before" = "$sha_after" ] || \
    fail "UX doc changed during screen-only sync: sha $sha_before -> $sha_after"

  rm -rf "$root"
}


# =========================================================================
# Special characters in component name with table insert (AC-EC4)
# =========================================================================

@test "(AC-EC4) special characters in component name preserved in table insert" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

| Component | Source | Notes |
|-----------|--------|-------|
| header | custom | top |

## 9. Design Record Reference
UX

  # Component with backslash and ampersand
  local snapshot="$root/snapshot.json"
  jq -n '{"components":["header","nav\\bar","R&D-panel"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Both special-char components must appear in the doc intact.
  # After the escape fix, nav\bar is stored as nav\\bar (backslash doubled).
  grep -qF 'nav\\bar' "$doc_dir/ux-design.md" || \
    fail "backslash component not preserved in doc (expected nav\\\\bar)"
  grep -qF 'R&D-panel' "$doc_dir/ux-design.md" || \
    fail "ampersand component not preserved in doc"

  # Position: rows must land directly after the last original data row
  local header_ln navbar_ln rdpanel_ln
  header_ln="$(grep -n '| header |' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  navbar_ln="$(grep -nF 'nav\\bar' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  rdpanel_ln="$(grep -nF 'R&D-panel' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  [ "$navbar_ln" -eq "$((header_ln + 1))" ] || \
    fail "nav\\bar row not directly after the last table row (expected line $((header_ln + 1)), got $navbar_ln)"
  [ "$rdpanel_ln" -eq "$((header_ln + 2))" ] || \
    fail "R&D-panel row not consecutive after nav\\bar (expected line $((header_ln + 2)), got $rdpanel_ln)"

  rm -rf "$root"
}


# =========================================================================
# Screen with no baseline entry reported as "no baseline" (AC3)
# =========================================================================

@test "(AC3) screen with no baseline entry reported as no baseline" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Component Inventory

- nav

## Design Record Reference
UX

  # Empty baseline — no entries for the product_design key
  local baseline="$root/baseline.json"
  printf '{"product_design":{"files":[]}}\n' > "$baseline"

  # Write screen file and build snapshot via --rawfile
  local screens_dir="$root/screens"
  _write_screen_file "$screens_dir" "new.spec.html" "<h1>Brand New</h1>"
  local snapshot="$root/snapshot.json"
  jq -n --rawfile c "$screens_dir/new.spec.html" \
    '{"components":["nav"],"screens":[{"name":"New Screen","file":"screens/new.spec.html","content":$c}]}' > "$snapshot"

  run "$SYNC_SCRIPT" --project product_design --last-published "$baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Must report "no baseline"
  [[ "$output" == *"no baseline"* ]] || \
    fail "should report 'no baseline' for screen not in baseline: $output"

  # Must still show content in boundary markers
  [[ "$output" == *'<<<PRODUCT_DESIGN_PROJECT_BOUNDARY>>>'* ]] || \
    fail "missing boundary markers for no-baseline screen: $output"

  rm -rf "$root"
}


# =========================================================================
# Screens-only snapshot with no heading exits 0 (AC-EC2 + AC-EC7)
# =========================================================================

@test "(AC-EC2) screens-only snapshot with no component heading exits 0" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Some Unrelated Section

Content only.
UX

  # No components key, only screens
  local snapshot="$root/snapshot.json"
  jq -n '{"screens":[{"name":"Only Screen","file":"screens/only.spec.html","content":"only body"}]}' > "$snapshot"

  run "$SYNC_SCRIPT" --project product_design "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || \
    fail "should exit 0 with screens-only snapshot and no heading (exit $status): $output"

  rm -rf "$root"
}


# =========================================================================
# Dual headings: only the first (template) is edited (AC1)
# =========================================================================

@test "(AC1) dual headings in one doc: only first match is edited" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- existing-alpha

## Component Inventory

- existing-beta

## Design Record Reference
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["existing-alpha","existing-beta","new-gamma"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # new-gamma should appear in the template section (between "Components & Design System" and "Component Inventory")
  local template_section
  template_section="$(awk '/## 8\. Components/,/## Component Inventory/' "$doc_dir/ux-design.md")"
  grep -q 'new-gamma' <<<"$template_section" || \
    fail "new-gamma should be in the template heading section, not the legacy one"

  # The legacy section should NOT contain new-gamma
  local legacy_section
  legacy_section="$(awk '/## Component Inventory/,/## Design Record/' "$doc_dir/ux-design.md")"
  local legacy_gamma
  legacy_gamma="$(printf '%s\n' "$legacy_section" | grep -c 'new-gamma' || true)"
  [ "$legacy_gamma" -eq 0 ] || \
    fail "new-gamma should NOT be in the legacy heading section ($legacy_gamma occurrences)"

  rm -rf "$root"
}


# =========================================================================
# Batch performance — 200 new components under 3 seconds (existing)
# =========================================================================

@test "sync 200 new components correct and idempotent" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  _seed_stale_ux_doc "$doc_dir"
  local ux_doc="$doc_dir/ux-design.md"

  # Build a snapshot with 200 new components plus the 3 existing.
  # Use python3 for fast JSON generation (jq-per-element is too slow).
  python3 -c '
import json, sys
components = ["header", "footer", "main-content"]
components += [f"new-component-{i}" for i in range(1, 201)]
json.dump({"components": components}, sys.stdout)
' > "$root/snapshot.json"

  run "$SYNC_SCRIPT" "$root/snapshot.json" "$ux_doc"
  [ "$status" -eq 0 ] || fail "sync of 200 components failed — exit $status: $output"

  # All 200 components present
  local count
  count="$(grep -c '^- new-component-' "$ux_doc")"
  [ "$count" -eq 200 ] || fail "expected 200 new components, found $count"

  # Second run — byte-identical (idempotence)
  local sha_first
  sha_first="$(_sha256_file "$ux_doc")"

  run "$SYNC_SCRIPT" "$root/snapshot.json" "$ux_doc"
  [ "$status" -eq 0 ] || fail "second sync failed: $output"

  local sha_second
  sha_second="$(_sha256_file "$ux_doc")"
  [ "$sha_first" = "$sha_second" ] || \
    fail "second sync changed the doc: sha $sha_first -> $sha_second"

  rm -rf "$root"
}

# bats test_tags=hardware-dependent
@test "sync 200 new components completes in under 5 s" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  _seed_stale_ux_doc "$doc_dir"
  local ux_doc="$doc_dir/ux-design.md"

  python3 -c '
import json, sys
components = ["header", "footer", "main-content"]
components += [f"new-component-{i}" for i in range(1, 201)]
json.dump({"components": components}, sys.stdout)
' > "$root/snapshot.json"

  local start_ms end_ms elapsed_ms
  start_ms="$(python3 -c 'import time; print(int(time.monotonic() * 1000))')"

  run "$SYNC_SCRIPT" "$root/snapshot.json" "$ux_doc"

  end_ms="$(python3 -c 'import time; print(int(time.monotonic() * 1000))')"
  elapsed_ms=$((end_ms - start_ms))

  [ "$status" -eq 0 ] || fail "sync failed — exit $status: $output"
  [ "$elapsed_ms" -lt 5000 ] || \
    fail "performance: ${elapsed_ms} ms exceeds 5000 ms budget for 200 new components"

  rm -rf "$root"
}


# =========================================================================
# Screen with no .content key rejected (V4)
# =========================================================================

@test "(AC-EC8) screen with no content key rejected with diagnostic" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Component Inventory

- nav

## Design Record Reference
UX

  # Screen with no .content key at all
  local snapshot="$root/snapshot.json"
  jq -n '{"components":["nav"],"screens":[{"name":"Broken","file":"screens/broken.spec.html"}]}' > "$snapshot"

  run "$SYNC_SCRIPT" --project product_design "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -ne 0 ] || \
    fail "should reject screen with no content key (exit $status): $output"

  # Diagnostic should name the screen
  [[ "$output" == *"Broken"* ]] || \
    fail "diagnostic should name the screen: $output"

  # No boundary markers emitted for the broken screen
  [[ "$output" != *'PRODUCT_DESIGN_PROJECT_BOUNDARY'* ]] || \
    fail "boundary markers should not appear for a rejected screen: $output"

  rm -rf "$root"
}


# =========================================================================
# Temp file cleanup (V2)
# =========================================================================

@test "(AC3) temp files cleaned up after sync" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Component Inventory

- nav

## Design Record Reference
UX

  # Isolated TMPDIR for leak detection
  local iso_tmpdir="$root/tmpdir"
  mkdir -p "$iso_tmpdir"

  # Write screen file and build snapshot via --rawfile
  local screens_dir="$root/screens"
  _write_screen_file "$screens_dir" "home.spec.html" "<h1>Home</h1>"
  local snapshot="$root/snapshot.json"
  jq -n --rawfile c "$screens_dir/home.spec.html" \
    '{"components":["nav"],"screens":[{"name":"Home","file":"screens/home.spec.html","content":$c}]}' > "$snapshot"

  TMPDIR="$iso_tmpdir" run "$SYNC_SCRIPT" --project product_design "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # The isolated TMPDIR must be empty after the script exits
  local leftover
  leftover="$(find "$iso_tmpdir" -type f 2>/dev/null | wc -l)"
  [ "$leftover" -eq 0 ] || \
    fail "temp files leaked in TMPDIR ($leftover files remain)"

  rm -rf "$root"
}

@test "(AC-EC8) temp files cleaned up after failed sync" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Component Inventory

- nav

## Design Record Reference
UX

  # Isolated TMPDIR for leak detection
  local iso_tmpdir="$root/tmpdir"
  mkdir -p "$iso_tmpdir"

  # Screen with no .content key — should fail
  local snapshot="$root/snapshot.json"
  jq -n '{"components":["nav"],"screens":[{"name":"Bad","file":"screens/bad.spec.html"}]}' > "$snapshot"

  TMPDIR="$iso_tmpdir" run "$SYNC_SCRIPT" --project product_design "$snapshot" "$doc_dir/ux-design.md"

  # The isolated TMPDIR must be empty even after a failure
  local leftover
  leftover="$(find "$iso_tmpdir" -type f 2>/dev/null | wc -l)"
  [ "$leftover" -eq 0 ] || \
    fail "temp files leaked in TMPDIR after failure ($leftover files remain)"

  rm -rf "$root"
}


# =========================================================================
# Temp file cleaned up on mid-loop abort (V2)
# =========================================================================

@test "(AC3) temp file cleaned up on mid-loop abort" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Component Inventory

- nav

## Design Record Reference
UX

  # Isolated TMPDIR for leak detection
  local iso_tmpdir="$root/tmpdir"
  mkdir -p "$iso_tmpdir"

  # Two valid screens. We force a mid-loop abort by making shasum/sha256sum
  # fail after the 1st call: screen 1's hash succeeds, screen 2's hash fails.
  local screens_dir="$root/screens"
  _write_screen_file "$screens_dir" "s1.spec.html" "<h1>Screen 1</h1>"
  _write_screen_file "$screens_dir" "s2.spec.html" "<h1>Screen 2</h1>"
  local snapshot="$root/snapshot.json"
  jq -n --rawfile c1 "$screens_dir/s1.spec.html" \
        --rawfile c2 "$screens_dir/s2.spec.html" \
    '{"components":["nav"],"screens":[
      {"name":"S1","file":"screens/s1.spec.html","content":$c1},
      {"name":"S2","file":"screens/s2.spec.html","content":$c2}
    ]}' > "$snapshot"

  # Shim hash command: fail after the 1st call (screen 2's hash)
  _create_hash_shim "$root/shim-bin" "$root/sha_call_count" 1

  PATH="$root/shim-bin:$PATH" TMPDIR="$iso_tmpdir" run "$SYNC_SCRIPT" \
    --project product_design "$snapshot" "$doc_dir/ux-design.md"

  # Must exit non-zero (the forced failure triggers set -e)
  [ "$status" -ne 0 ] || \
    fail "should fail when hash command fails mid-loop (exit $status)"

  # The isolated TMPDIR must be empty — no leaked temp file
  local leftover
  leftover="$(find "$iso_tmpdir" -type f 2>/dev/null | wc -l)"
  [ "$leftover" -eq 0 ] || \
    fail "temp file leaked in TMPDIR after mid-loop abort ($leftover files: $(ls "$iso_tmpdir"))"

  rm -rf "$root"
}


# =========================================================================
# Non-string content types rejected (V4 extended)
# =========================================================================

@test "(AC-EC8) screen with numeric content rejected" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Component Inventory

- nav

## Design Record Reference
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["nav"],"screens":[{"name":"NumScreen","file":"screens/num.spec.html","content":42}]}' > "$snapshot"

  run "$SYNC_SCRIPT" --project product_design "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -ne 0 ] || fail "should reject numeric content (exit $status): $output"
  [[ "$output" == *"NumScreen"* ]] || fail "diagnostic should name the screen: $output"
  [[ "$output" != *'PRODUCT_DESIGN_PROJECT_BOUNDARY'* ]] || fail "no boundary markers for rejected screen"

  rm -rf "$root"
}

@test "(AC-EC8) screen with object content rejected" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Component Inventory

- nav

## Design Record Reference
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["nav"],"screens":[{"name":"ObjScreen","file":"screens/obj.spec.html","content":{"x":1}}]}' > "$snapshot"

  run "$SYNC_SCRIPT" --project product_design "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -ne 0 ] || fail "should reject object content (exit $status): $output"
  [[ "$output" == *"ObjScreen"* ]] || fail "diagnostic should name the screen: $output"
  [[ "$output" != *'PRODUCT_DESIGN_PROJECT_BOUNDARY'* ]] || fail "no boundary markers for rejected screen"

  rm -rf "$root"
}

@test "(AC-EC8) screen with array content rejected" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Component Inventory

- nav

## Design Record Reference
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["nav"],"screens":[{"name":"ArrScreen","file":"screens/arr.spec.html","content":[1]}]}' > "$snapshot"

  run "$SYNC_SCRIPT" --project product_design "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -ne 0 ] || fail "should reject array content (exit $status): $output"
  [[ "$output" == *"ArrScreen"* ]] || fail "diagnostic should name the screen: $output"
  [[ "$output" != *'PRODUCT_DESIGN_PROJECT_BOUNDARY'* ]] || fail "no boundary markers for rejected screen"

  rm -rf "$root"
}


# =========================================================================
# No partial output: valid screen followed by invalid screen (V4 + INFO)
# =========================================================================

@test "(AC-EC8) valid screen followed by invalid screen produces no output" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Component Inventory

- nav

## Design Record Reference
UX

  # First screen is valid, second has non-string content
  local screens_dir="$root/screens"
  _write_screen_file "$screens_dir" "good.spec.html" "<h1>Good</h1>"
  local snapshot="$root/snapshot.json"
  jq -n --rawfile c "$screens_dir/good.spec.html" \
    '{"components":["nav"],"screens":[
      {"name":"Good","file":"screens/good.spec.html","content":$c},
      {"name":"Bad","file":"screens/bad.spec.html","content":42}
    ]}' > "$snapshot"

  run "$SYNC_SCRIPT" --project product_design "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -ne 0 ] || fail "should fail on invalid screen (exit $status): $output"

  # No boundary markers at all — the valid screen must not have been reported
  [[ "$output" != *'PRODUCT_DESIGN_PROJECT_BOUNDARY'* ]] || \
    fail "boundary markers present — partial output emitted before validation: $output"

  rm -rf "$root"
}


# =========================================================================
# Temp file cleaned up on component-phase abort
# =========================================================================

# Helper: create a shim hash command that fails on the Nth call.
# Usage: _create_hash_shim SHIM_DIR COUNTER_FILE FAIL_AFTER
_create_hash_shim() {
  local shim_dir="$1" counter_file="$2" fail_after="$3"
  mkdir -p "$shim_dir"
  printf '0\n' > "$counter_file"
  local real_hash_cmd
  if command -v sha256sum >/dev/null 2>&1; then
    real_hash_cmd="sha256sum"
  else
    real_hash_cmd="shasum"
  fi
  local real_path
  real_path="$(command -v "$real_hash_cmd")"
  cat > "$shim_dir/$real_hash_cmd" <<SHIM
#!/usr/bin/env bash
count=\$(cat "$counter_file")
count=\$((count + 1))
printf '%d\n' "\$count" > "$counter_file"
if [ "\$count" -gt $fail_after ]; then
  printf 'FORCED HASH FAILURE\n' >&2
  exit 1
fi
exec "$real_path" "\$@"
SHIM
  chmod +x "$shim_dir/$real_hash_cmd"
}

@test "(AC2) temp files cleaned up on component-phase abort" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Component Inventory

- existing

## Design Record Reference
UX

  local iso_tmpdir="$root/tmpdir"
  mkdir -p "$iso_tmpdir"

  # Snapshot with a NEW component so the sha-before check runs
  local snapshot="$root/snapshot.json"
  jq -n '{"components":["existing","brand-new"]}' > "$snapshot"

  # Shim: fail on the 1st hash call (the UX doc sha-before check)
  _create_hash_shim "$root/shim-bin" "$root/sha_call_count" 0

  PATH="$root/shim-bin:$PATH" TMPDIR="$iso_tmpdir" run "$SYNC_SCRIPT" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -ne 0 ] || \
    fail "should fail when hash command fails in component phase (exit $status)"

  local leftover
  leftover="$(find "$iso_tmpdir" -type f 2>/dev/null | wc -l)"
  [ "$leftover" -eq 0 ] || \
    fail "temp file leaked in TMPDIR after component-phase abort ($leftover files: $(ls "$iso_tmpdir"))"

  rm -rf "$root"
}

@test "(AC3) temp files cleaned up on screen-phase abort" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Component Inventory

- nav

## Design Record Reference
UX

  local iso_tmpdir="$root/tmpdir"
  mkdir -p "$iso_tmpdir"

  local screens_dir="$root/screens"
  _write_screen_file "$screens_dir" "s1.spec.html" "<h1>Screen 1</h1>"
  _write_screen_file "$screens_dir" "s2.spec.html" "<h1>Screen 2</h1>"
  local snapshot="$root/snapshot.json"
  jq -n --rawfile c1 "$screens_dir/s1.spec.html" \
        --rawfile c2 "$screens_dir/s2.spec.html" \
    '{"components":["nav"],"screens":[
      {"name":"S1","file":"screens/s1.spec.html","content":$c1},
      {"name":"S2","file":"screens/s2.spec.html","content":$c2}
    ]}' > "$snapshot"

  # Shim: fail on the 2nd hash call (screen 2's hash)
  _create_hash_shim "$root/shim-bin" "$root/sha_call_count" 1

  PATH="$root/shim-bin:$PATH" TMPDIR="$iso_tmpdir" run "$SYNC_SCRIPT" \
    --project product_design "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -ne 0 ] || \
    fail "should fail when hash command fails in screen phase (exit $status)"

  local leftover
  leftover="$(find "$iso_tmpdir" -type f 2>/dev/null | wc -l)"
  [ "$leftover" -eq 0 ] || \
    fail "temp file leaked in TMPDIR after screen-phase abort ($leftover files: $(ls "$iso_tmpdir"))"

  rm -rf "$root"
}


# =========================================================================
# Pipe character in component name escaped in table cell (AC-EC4)
# =========================================================================

@test "(AC-EC4) pipe in component name escaped as table cell" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

| Component | Source | Notes |
|-----------|--------|-------|
| header | custom | top |

## 9. Design Record Reference
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["header","Input|Output"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # The pipe must be escaped as \| in the table cell
  grep -qF 'Input\|Output' "$doc_dir/ux-design.md" || \
    fail "pipe character not escaped in table cell"

  # Position: row must land directly after the last original data row
  local header_ln input_ln
  header_ln="$(grep -n '| header |' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  input_ln="$(grep -nF 'Input\|Output' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  [ "$input_ln" -eq "$((header_ln + 1))" ] || \
    fail "Input|Output row not directly after the last table row (expected line $((header_ln + 1)), got $input_ln)"

  # The table column count must be unchanged (3 columns).
  # Count unescaped pipe delimiters on the inserted row. The escaped \|
  # must not count as a column separator.
  local inserted_row
  inserted_row="$(grep 'Input' "$doc_dir/ux-design.md")"
  # Remove escaped pipes, then count unescaped pipes minus 1
  local unescaped
  unescaped="$(printf '%s' "$inserted_row" | sed 's/\\|//g')"
  local col_count
  col_count="$(printf '%s' "$unescaped" | awk '{print gsub(/\|/,"|") - 1}')"
  [ "$col_count" -eq 3 ] || \
    fail "table column count changed from 3 to $col_count after inserting pipe-containing name"

  rm -rf "$root"
}


# =========================================================================
# Wrong snapshot shape rejected
# =========================================================================

@test "snapshot with object component elements rejected" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Component Inventory

- existing

## Design Record Reference
UX

  local ux_doc="$doc_dir/ux-design.md"
  local sha_before
  sha_before="$(_sha256_file "$ux_doc")"

  local snapshot="$root/snapshot.json"
  jq -n '{"components":[{"name":"Button"}]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$ux_doc"

  [ "$status" -ne 0 ] || \
    fail "should reject components with object elements (exit $status): $output"

  local sha_after
  sha_after="$(_sha256_file "$ux_doc")"
  [ "$sha_before" = "$sha_after" ] || \
    fail "doc changed despite rejected snapshot: sha $sha_before -> $sha_after"

  rm -rf "$root"
}

@test "snapshot with number component element rejected" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Component Inventory

- existing

## Design Record Reference
UX

  local ux_doc="$doc_dir/ux-design.md"
  local sha_before
  sha_before="$(_sha256_file "$ux_doc")"

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["valid", 42]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$ux_doc"

  [ "$status" -ne 0 ] || \
    fail "should reject components with number element (exit $status): $output"

  local sha_after
  sha_after="$(_sha256_file "$ux_doc")"
  [ "$sha_before" = "$sha_after" ] || \
    fail "doc changed despite rejected snapshot: sha $sha_before -> $sha_after"

  rm -rf "$root"
}

@test "snapshot with components as bare string rejected" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Component Inventory

- existing

## Design Record Reference
UX

  local ux_doc="$doc_dir/ux-design.md"
  local sha_before
  sha_before="$(_sha256_file "$ux_doc")"

  local snapshot="$root/snapshot.json"
  jq -n '{"components":"Button"}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$ux_doc"

  [ "$status" -ne 0 ] || \
    fail "should reject components as a string (exit $status): $output"

  local sha_after
  sha_after="$(_sha256_file "$ux_doc")"
  [ "$sha_before" = "$sha_after" ] || \
    fail "doc changed despite rejected snapshot: sha $sha_before -> $sha_after"

  rm -rf "$root"
}

@test "snapshot with screens as object rejected" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Component Inventory

- nav

## Design Record Reference
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["nav"],"screens":{"name":"Bad","file":"bad.html","content":"x"}}' > "$snapshot"

  run "$SYNC_SCRIPT" --project product_design "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -ne 0 ] || \
    fail "should reject screens as an object (exit $status): $output"

  rm -rf "$root"
}


# =========================================================================
# Baseline lookup with backslash in file path (AF1)
# =========================================================================

@test "(AC-EC5) unchanged screen with backslash in path produces no report" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Component Inventory

- nav

## Design Record Reference
UX

  # Screen whose file path contains a backslash
  local bslash_path='screens/a\b.spec.html'
  local screens_dir="$root/screens"
  _write_screen_file "$screens_dir" "backslash.spec.html" "<h1>Backslash</h1>"

  local file_hash
  file_hash="$(_sha256_file "$screens_dir/backslash.spec.html")"

  # Baseline entry with the backslash path and the matching hash
  local baseline="$root/baseline.json"
  jq -n --arg f "$bslash_path" --arg h "$file_hash" \
    '{"product_design":{"files":[{"file": $f, "hash": $h}]}}' > "$baseline"

  # Snapshot with the same content and backslash path
  local snapshot="$root/snapshot.json"
  jq -n --rawfile c "$screens_dir/backslash.spec.html" \
        --arg f "$bslash_path" \
    '{"components":["nav"],"screens":[{"name":"Backslash Screen","file":$f,"content":$c}]}' > "$snapshot"

  run "$SYNC_SCRIPT" --project product_design --last-published "$baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # No screen report — the hashes match, so no change
  [[ "$output" != *'PRODUCT_DESIGN_PROJECT_BOUNDARY'* ]] || \
    fail "boundary markers present for unchanged screen with backslash path: $output"
  local screen_count
  screen_count="$(printf '%s\n' "$output" | grep -ci 'screen.*changed\|screen.*baseline' || true)"
  [ "$screen_count" -eq 0 ] || \
    fail "screen report emitted for unchanged screen with backslash path ($screen_count lines)"

  rm -rf "$root"
}


# =========================================================================
# Scale test: 500 screens under 30 s
# =========================================================================

# Helper: generate a snapshot with N screens (no baseline — all "no baseline")
_gen_scale_snapshot() {
  local n="$1" dir="$2"
  mkdir -p "$dir/screens"
  python3 -c "
import json, sys
n = int(sys.argv[1])
d = sys.argv[2]
screens = []
for i in range(n):
    body = '<html><head><title>Screen %d</title></head><body>' % i
    body += '<div class=\"container\"><h1>Screen %d Title</h1>' % i
    body += '<p>This is the content of screen %d with some realistic text to simulate a real screen specification.</p>' % i
    body += '<ul><li>Item A</li><li>Item B</li><li>Item C</li></ul></div></body></html>\n'
    screens.append({'name': 'Screen %d' % i, 'file': 'screens/screen-%d.spec.html' % i, 'content': body})
json.dump({'components': ['nav'], 'screens': screens}, sys.stdout)
" "$n" "$dir" > "$dir/snapshot.json"
}

# Gate at 30 s: the optimized implementation runs 500 screens in ~11 s
# locally. The old per-screen-jq implementation took ~56 s and would
# fail this gate at any CI speed. 30 s gives 3x headroom for slower
# Linux runners while still catching an O(N*jq) regression.
@test "(AC3) sync 500 screens completes in under 30 s" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Component Inventory

- nav

## Design Record Reference
UX

  _gen_scale_snapshot 500 "$root"

  local start_ms end_ms elapsed_ms
  start_ms="$(python3 -c 'import time; print(int(time.monotonic() * 1000))')"

  run "$SYNC_SCRIPT" --project product_design "$root/snapshot.json" "$doc_dir/ux-design.md"

  end_ms="$(python3 -c 'import time; print(int(time.monotonic() * 1000))')"
  elapsed_ms=$((end_ms - start_ms))

  [ "$status" -eq 0 ] || fail "sync of 500 screens failed — exit $status"
  [ "$elapsed_ms" -lt 30000 ] || \
    fail "performance: ${elapsed_ms} ms exceeds 30000 ms budget for 500 screens"

  rm -rf "$root"
}


# =========================================================================
# Golden output byte-identity test
# =========================================================================

@test "(AC3) screen output is byte-identical to the golden reference" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Component Inventory

- nav

## Design Record Reference
UX

  # Screen 0: unchanged (hash matches baseline)
  printf '<h1>Home</h1>\n<p>Welcome</p>\n' > "$root/s0.html"
  local s0_hash
  s0_hash="$(_sha256_file "$root/s0.html")"

  # Screen 1: changed (baseline has a different hash)
  printf '<h1>Settings</h1>\n<p>Updated settings page</p>\n' > "$root/s1.html"

  # Screen 2: no baseline entry
  printf '<h1>Profile</h1>\n<p>User profile</p>\n' > "$root/s2.html"

  # Baseline: s0 matches, s1 has a stale hash, s2 absent
  jq -n --arg f0 "screens/s0.html" --arg h0 "$s0_hash" \
        --arg f1 "screens/s1.html" --arg h1 "0000000000000000000000000000000000000000000000000000000000000000" \
    '{"product_design":{"files":[{"file":$f0,"hash":$h0},{"file":$f1,"hash":$h1}]}}' > "$root/baseline.json"

  # Snapshot via --rawfile
  jq -n --rawfile c0 "$root/s0.html" \
        --rawfile c1 "$root/s1.html" \
        --rawfile c2 "$root/s2.html" \
    '{"components":["nav"],"screens":[
      {"name":"Home","file":"screens/s0.html","content":$c0},
      {"name":"Settings","file":"screens/s1.html","content":$c1},
      {"name":"Profile","file":"screens/s2.html","content":$c2}
    ]}' > "$root/snapshot.json"

  # Golden expected output — the product_design pass does not run the
  # absence report (that belongs to the design_system pass).
  local expected="$root/expected.txt"
  cat > "$expected" <<'GOLDEN'
sync: screen "Settings" changed (file: screens/s1.html)
<<<PRODUCT_DESIGN_PROJECT_BOUNDARY>>>
<h1>Settings</h1>
<p>Updated settings page</p>
<<<END_PRODUCT_DESIGN_PROJECT_BOUNDARY>>>
sync: screen "Profile" has no baseline (file: screens/s2.html)
<<<PRODUCT_DESIGN_PROJECT_BOUNDARY>>>
<h1>Profile</h1>
<p>User profile</p>
<<<END_PRODUCT_DESIGN_PROJECT_BOUNDARY>>>
GOLDEN

  run "$SYNC_SCRIPT" --project product_design --last-published "$root/baseline.json" \
    "$root/snapshot.json" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Compare byte-for-byte
  local actual="$root/actual.txt"
  printf '%s\n' "$output" > "$actual"

  diff -u "$expected" "$actual" || \
    fail "output differs from golden reference"

  rm -rf "$root"
}


# =========================================================================
# Scenario 1 (AC1) — table followed by prose: row inserted inside table
# =========================================================================

@test "(AC1) table followed by prose: row inserted inside table" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
design_state: review
---

# UX Design

## 8. Components & Design System

| Component | Source | Notes | Status |
|-----------|--------|-------|--------|
| HabitRow | Custom | Row card | Active |

Design tokens: primary-500 = #6366F1, surface = #FFFFFF

## 9. Interaction Patterns
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["HabitRow","EmptyState"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # The new component must be present
  grep -q 'EmptyState' "$doc_dir/ux-design.md" || \
    fail "EmptyState not added to doc after sync"

  # Row must appear directly after the last original data row
  local habitrow_ln emptystate_ln
  habitrow_ln="$(grep -n '| HabitRow |' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  emptystate_ln="$(grep -n 'EmptyState' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  [ "$emptystate_ln" -eq "$((habitrow_ln + 1))" ] || \
    fail "EmptyState row not directly after HabitRow (expected line $((habitrow_ln + 1)), got $emptystate_ln)"

  # Row must be padded to 4 columns
  local row_text
  row_text="$(sed -n "${emptystate_ln}p" "$doc_dir/ux-design.md")"
  [[ "$row_text" == '| EmptyState | | | |' ]] || \
    fail "EmptyState row not padded to 4 columns: $row_text"

  # Prose after the table must be byte-unchanged
  grep -q 'Design tokens: primary-500 = #6366F1, surface = #FFFFFF' "$doc_dir/ux-design.md" || \
    fail "prose after the table was altered"

  # The heading must still be present (shifted by 1 line)
  local heading_ln
  heading_ln="$(grep -n '## 9\. Interaction Patterns' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  [ -n "$heading_ln" ] || fail "## 9. heading disappeared"

  rm -rf "$root"
}


# =========================================================================
# Scenario 2 (AC2) — table then blank line then heading: rows in order
# =========================================================================

@test "(AC2) table then blank line then heading: rows in order inside table" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
design_state: review
---

# UX Design

## 8. Components & Design System

| Component | Source |
|-----------|--------|
| ExistingA | Custom |

## 9. Next Section
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["ExistingA","NewB","NewC"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Both new components must be present
  grep -q 'NewB' "$doc_dir/ux-design.md" || fail "NewB not added"
  grep -q 'NewC' "$doc_dir/ux-design.md" || fail "NewC not added"

  # Rows must appear directly after ExistingA, in order
  local existing_ln newb_ln newc_ln
  existing_ln="$(grep -n '| ExistingA |' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  newb_ln="$(grep -n 'NewB' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  newc_ln="$(grep -n 'NewC' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  [ "$newb_ln" -eq "$((existing_ln + 1))" ] || \
    fail "NewB not directly after ExistingA (expected line $((existing_ln + 1)), got $newb_ln)"
  [ "$newc_ln" -eq "$((existing_ln + 2))" ] || \
    fail "NewC not directly after NewB (expected line $((existing_ln + 2)), got $newc_ln)"

  # Blank line must still exist between the last new row and the heading
  local heading_ln
  heading_ln="$(grep -n '## 9\. Next Section' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  local line_before_heading
  line_before_heading="$(sed -n "$((heading_ln - 1))p" "$doc_dir/ux-design.md")"
  [ -z "$line_before_heading" ] || \
    fail "blank line missing between new rows and heading (line $((heading_ln - 1)) is: $line_before_heading)"

  rm -rf "$root"
}


# =========================================================================
# Scenario 3 (AC2) — table then blank lines then EOF: rows inside table
# =========================================================================

@test "(AC2) table then blank lines then EOF: rows inside table, blanks kept" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  # Two trailing blank lines after the table, then EOF
  printf '%s' '---
template: ux-design
design_state: review
---

# UX Design

## 8. Components & Design System

| Component | Source |
|-----------|--------|
| Only | Custom |


' > "$doc_dir/ux-design.md"

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["Only","Added"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  grep -q 'Added' "$doc_dir/ux-design.md" || fail "Added not present in doc"

  # Row must appear directly after Only
  local only_ln added_ln
  only_ln="$(grep -n '| Only |' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  added_ln="$(grep -n 'Added' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  [ "$added_ln" -eq "$((only_ln + 1))" ] || \
    fail "Added row not directly after Only (expected line $((only_ln + 1)), got $added_ln)"

  # Two trailing blank lines must still follow the new row at EOF
  local total_lines
  total_lines="$(wc -l < "$doc_dir/ux-design.md" | tr -d ' ')"
  local second_last last_line
  second_last="$(sed -n "$((total_lines - 1))p" "$doc_dir/ux-design.md")"
  last_line="$(sed -n "${total_lines}p" "$doc_dir/ux-design.md")"
  [ -z "$second_last" ] || \
    fail "second-to-last line should be blank but is: $second_last"
  [ -z "$last_line" ] || \
    fail "last line should be blank but is: $last_line"

  rm -rf "$root"
}


# =========================================================================
# Scenario 4 (AC2) — table directly abutting heading: output unchanged
# =========================================================================

@test "(AC2) table directly abutting heading: output unchanged from today" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  # No blank line between table and heading
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
design_state: review
---

# UX Design

## 8. Components & Design System

| Component | Source |
|-----------|--------|
| Only | Custom |
## 9. Next Section
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["Only","NewRow"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  grep -q 'NewRow' "$doc_dir/ux-design.md" || fail "NewRow not added"

  # NewRow must appear between Only and the heading
  local only_ln newrow_ln heading_ln
  only_ln="$(grep -n '| Only |' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  newrow_ln="$(grep -n 'NewRow' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  heading_ln="$(grep -n '## 9\. Next Section' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  [ "$newrow_ln" -eq "$((only_ln + 1))" ] || \
    fail "NewRow not directly after Only (expected line $((only_ln + 1)), got $newrow_ln)"
  [ "$heading_ln" -eq "$((newrow_ln + 1))" ] || \
    fail "heading not directly after NewRow (expected line $((newrow_ln + 1)), got $heading_ln)"

  rm -rf "$root"
}


# =========================================================================
# Scenario 5 (AC3) — bullet-list section: placement unchanged
# =========================================================================

@test "(AC3) bullet-list section: placement unchanged" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
design_state: review
---

# UX Design

## 8. Components & Design System

- existing-btn

Some trailing prose here.

## 9. Next Section
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["existing-btn","new-card"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  grep -q 'new-card' "$doc_dir/ux-design.md" || fail "new-card not added"

  # The new bullet must appear before the heading (bullet mode inserts at heading boundary)
  local heading_ln card_ln
  heading_ln="$(grep -n '## 9\. Next Section' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  card_ln="$(grep -n 'new-card' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  [ "$card_ln" -lt "$heading_ln" ] || \
    fail "new-card should appear before ## 9. heading (card at $card_ln, heading at $heading_ln)"

  # Must be a bullet, not a table row
  local card_text
  card_text="$(sed -n "${card_ln}p" "$doc_dir/ux-design.md")"
  [[ "$card_text" == '- new-card' ]] || \
    fail "new-card should be a bullet entry, got: $card_text"

  rm -rf "$root"
}


# =========================================================================
# Scenario 6 (AC4) — two tables in section: row in first, second unchanged
# =========================================================================

@test "(AC4) two tables in section: row in first, second byte-identical" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
design_state: review
---

# UX Design

## 8. Components & Design System

| Component | Source |
|-----------|--------|
| Alpha | Custom |

| Token | Value |
|-------|-------|
| primary-500 | #6366F1 |

## 9. Next Section
UX

  # Capture the second table before sync
  local second_table_before
  second_table_before="$(awk '/^\| Token/,/^$/' "$doc_dir/ux-design.md")"

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["Alpha","Beta"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  grep -q 'Beta' "$doc_dir/ux-design.md" || fail "Beta not added"

  # Beta must appear directly after Alpha (in the first table)
  local alpha_ln beta_ln
  alpha_ln="$(grep -n '| Alpha |' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  beta_ln="$(grep -n 'Beta' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  [ "$beta_ln" -eq "$((alpha_ln + 1))" ] || \
    fail "Beta not directly after Alpha (expected line $((alpha_ln + 1)), got $beta_ln)"

  # Second table must be byte-identical
  local second_table_after
  second_table_after="$(awk '/^\| Token/,/^$/' "$doc_dir/ux-design.md")"
  [ "$second_table_before" = "$second_table_after" ] || \
    fail "second table was modified by the sync"

  rm -rf "$root"
}


# =========================================================================
# Scenario 7 (AC5) — header-separator-only table: row after separator
# =========================================================================

@test "(AC5) header-separator-only table: row after separator" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
design_state: review
---

# UX Design

## 8. Components & Design System

| Component | Source |
|-----------|--------|

Design tokens note.

## 9. Next Section
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["FirstComp"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  grep -q 'FirstComp' "$doc_dir/ux-design.md" || fail "FirstComp not added"

  # Row must appear directly after the separator row
  local sep_ln comp_ln
  sep_ln="$(grep -n '^|---' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  comp_ln="$(grep -n 'FirstComp' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  [ "$comp_ln" -eq "$((sep_ln + 1))" ] || \
    fail "FirstComp not directly after separator (expected line $((sep_ln + 1)), got $comp_ln)"

  # Prose after the table must be preserved
  grep -q 'Design tokens note.' "$doc_dir/ux-design.md" || \
    fail "prose after the table was lost"

  rm -rf "$root"
}


# =========================================================================
# Scenario 8 (AC5) — blank lines between heading and table: preserved
# =========================================================================

@test "(AC5) blank lines between heading and table: preserved" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  # Two blank lines between the heading and the table
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
design_state: review
---

# UX Design

## 8. Components & Design System


| Component | Source |
|-----------|--------|
| Existing | Custom |

## 9. Next Section
UX

  # Count blank lines between heading and table before sync
  local heading_ln_before table_ln_before
  heading_ln_before="$(grep -n '## 8\. Components' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  table_ln_before="$(grep -n '| Component |' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  local gap_before=$((table_ln_before - heading_ln_before - 1))

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["Existing","NewWidget"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  grep -q 'NewWidget' "$doc_dir/ux-design.md" || fail "NewWidget not added"

  # Blank lines between heading and table must be preserved
  local heading_ln_after table_ln_after
  heading_ln_after="$(grep -n '## 8\. Components' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  table_ln_after="$(grep -n '| Component |' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  local gap_after=$((table_ln_after - heading_ln_after - 1))
  [ "$gap_after" -eq "$gap_before" ] || \
    fail "blank lines between heading and table changed (was $gap_before, now $gap_after)"

  # Row must be inside the table (after Existing)
  local existing_ln widget_ln
  existing_ln="$(grep -n '| Existing |' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  widget_ln="$(grep -n 'NewWidget' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  [ "$widget_ln" -eq "$((existing_ln + 1))" ] || \
    fail "NewWidget not directly after Existing (expected line $((existing_ln + 1)), got $widget_ln)"

  rm -rf "$root"
}


# =========================================================================
# Scenario 9 (AC6) — second Token/Value table: no spurious absent lines
# =========================================================================

@test "(AC6) second Token/Value table: no spurious absent lines, component added" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
design_state: review
---

# UX Design

## 8. Components & Design System

| Component | Source |
|-----------|--------|
| Alpha | Custom |

| Token | Value |
|-------|-------|
| primary-500 | #6366F1 |

## 9. Next Section
UX

  # Snapshot includes Alpha (existing) and primary-500 (name matching a
  # cell in the second table — must still be added as a component)
  local snapshot="$root/snapshot.json"
  jq -n '{"components":["Alpha","primary-500"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # No "absent" line mentioning primary-500 (would mean extraction read the second table)
  local absent_primary
  absent_primary="$(printf '%s\n' "$output" | grep -i 'absent' | grep 'primary-500' || true)"
  [ -z "$absent_primary" ] || \
    fail "primary-500 reported as absent — extraction read past the first table: $absent_primary"

  # primary-500 must be added as a component row in the first table
  grep -q 'primary-500' "$doc_dir/ux-design.md" || \
    fail "primary-500 not added to doc"

  # It must appear directly after Alpha (in the first table)
  local alpha_ln primary_ln
  alpha_ln="$(grep -n '| Alpha |' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  primary_ln="$(grep -n '| primary-500 |' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  [ "$primary_ln" -eq "$((alpha_ln + 1))" ] || \
    fail "primary-500 row not directly after Alpha (expected line $((alpha_ln + 1)), got $primary_ln)"

  rm -rf "$root"
}


# =========================================================================
# Scenario 10 (AC7) — table under triple-hash subheading: row added
# =========================================================================

@test "(AC7) table under triple-hash subheading: row added to table" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
design_state: review
---

# UX Design

## 8. Components & Design System

### Component inventory

| Component | Source |
|-----------|--------|
| CardA | Custom |

## 9. Next Section
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["CardA","CardB"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  grep -q 'CardB' "$doc_dir/ux-design.md" || fail "CardB not added"

  # CardB must appear as a table row, not a bullet
  local cardb_text
  cardb_text="$(grep 'CardB' "$doc_dir/ux-design.md")"
  [[ "$cardb_text" == '| CardB |'* ]] || \
    fail "CardB should be a table row, got: $cardb_text"

  # CardB must appear directly after CardA (inside the table)
  local carda_ln cardb_ln
  carda_ln="$(grep -n '| CardA |' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  cardb_ln="$(grep -n '| CardB |' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  [ "$cardb_ln" -eq "$((carda_ln + 1))" ] || \
    fail "CardB not directly after CardA (expected line $((carda_ln + 1)), got $cardb_ln)"

  # No bullet "- CardB" should appear
  local bullet_count
  bullet_count="$(grep -c '^- CardB' "$doc_dir/ux-design.md" || true)"
  [ "$bullet_count" -eq 0 ] || \
    fail "CardB appeared as a bullet ($bullet_count times) instead of a table row"

  rm -rf "$root"
}


# =========================================================================
# Scenario 11 (AC8) — duplicate snapshot names: one row, reported once
# =========================================================================

@test "(AC8) duplicate snapshot names: one row, reported once" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
design_state: review
---

# UX Design

## 8. Components & Design System

| Component | Source |
|-----------|--------|
| Existing | Custom |

## 9. Next Section
UX

  # Snapshot with Alpha listed twice and Beta once
  local snapshot="$root/snapshot.json"
  jq -n '{"components":["Existing","Alpha","Alpha","Beta"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Exactly one Alpha row must be added
  local alpha_count
  alpha_count="$(grep -c '| Alpha |' "$doc_dir/ux-design.md" || true)"
  [ "$alpha_count" -eq 1 ] || \
    fail "expected exactly 1 Alpha row, found $alpha_count"

  # Beta must also be present (exactly once)
  local beta_count
  beta_count="$(grep -c '| Beta |' "$doc_dir/ux-design.md" || true)"
  [ "$beta_count" -eq 1 ] || \
    fail "expected exactly 1 Beta row, found $beta_count"

  # The "added" output must mention Alpha exactly once
  local added_alpha_count
  added_alpha_count="$(printf '%s\n' "$output" | grep -c 'added.*Alpha' || true)"
  [ "$added_alpha_count" -eq 1 ] || \
    fail "expected 'added' for Alpha exactly once, got $added_alpha_count"

  rm -rf "$root"
}


# =========================================================================
# Combined snapshot shape — design_system selection
# =========================================================================

@test "combined snapshot design_system selects only design_system part" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

| Component | Source |
|-----------|--------|
| Existing | Custom |

## Design Record Reference
UX

  local screens_dir="$root/screens"
  _write_screen_file "$screens_dir" "home.spec.html" "<h1>Home</h1>"

  local snapshot="$root/snapshot.json"
  jq -n --rawfile sc "$screens_dir/home.spec.html" \
    '{"design_system":{"components":["Existing","Button"],"templates":["Card"]},
      "product_design":{"screens":[{"name":"Home","file":"screens/home.spec.html","content":$sc}]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Button must be added to the components section
  grep -q 'Button' "$doc_dir/ux-design.md" || \
    fail "Button not added by design_system pass"

  # No screen output (screens belong to product_design)
  [[ "$output" != *'PRODUCT_DESIGN_PROJECT_BOUNDARY'* ]] || \
    fail "design_system pass should not emit product-design boundary markers"
  [[ "$output" != *'screen'*'changed'* ]] && [[ "$output" != *'no baseline'* ]] || \
    fail "design_system pass should not report screens"

  rm -rf "$root"
}


# =========================================================================
# Combined snapshot shape — product_design selection
# =========================================================================

@test "combined snapshot product_design selects only product_design part" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

| Component | Source |
|-----------|--------|
| Existing | Custom |

## Design Record Reference
UX

  local screens_dir="$root/screens"
  _write_screen_file "$screens_dir" "home.spec.html" "<h1>Home</h1>"

  local snapshot="$root/snapshot.json"
  jq -n --rawfile sc "$screens_dir/home.spec.html" \
    '{"design_system":{"components":["Existing","Button"]},
      "product_design":{"screens":[{"name":"Home","file":"screens/home.spec.html","content":$sc}]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project product_design "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Screens should be reported
  [[ "$output" == *'no baseline'* ]] || [[ "$output" == *'changed'* ]] || \
    fail "product_design pass should report screens: $output"

  # Components should NOT be added (Button belongs to design_system)
  local sha_before sha_after
  sha_before="$(_sha256_file "$doc_dir/ux-design.md")"
  # Doc should be unchanged — product_design doesn't write components
  # (already ran above, so check output for added-component lines)
  local added_count
  added_count="$(printf '%s\n' "$output" | grep -c 'added component' || true)"
  [ "$added_count" -eq 0 ] || \
    fail "product_design pass should not add components ($added_count added)"

  rm -rf "$root"
}


# =========================================================================
# Legacy flat snapshot — design_system selects components
# =========================================================================

@test "legacy flat snapshot under design_system selects components" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

| Component | Source |
|-----------|--------|
| Existing | Custom |

## Design Record Reference
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["Existing","NewComp"],"screens":[{"name":"Home","file":"screens/home.spec.html","content":"body"}]}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  grep -q 'NewComp' "$doc_dir/ux-design.md" || \
    fail "NewComp not added by design_system pass on flat snapshot"

  rm -rf "$root"
}


# =========================================================================
# Legacy flat snapshot — product_design selects screens
# =========================================================================

@test "legacy flat snapshot under product_design selects screens" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

| Component | Source |
|-----------|--------|
| Existing | Custom |

## Design Record Reference
UX

  local screens_dir="$root/screens"
  _write_screen_file "$screens_dir" "home.spec.html" "<h1>Home</h1>"

  local snapshot="$root/snapshot.json"
  jq -n --rawfile sc "$screens_dir/home.spec.html" \
    '{"components":["Existing","NewComp"],"screens":[{"name":"Home","file":"screens/home.spec.html","content":$sc}]}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project product_design "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Screens should be reported
  [[ "$output" == *'no baseline'* ]] || [[ "$output" == *'changed'* ]] || \
    fail "product_design pass should report screens on flat snapshot: $output"

  rm -rf "$root"
}


# =========================================================================
# Templates reconciled into components section
# =========================================================================

@test "templates reconciled into components section" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

| Component | Source |
|-----------|--------|
| Existing | Custom |

## Design Record Reference
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":["Existing"],"templates":["CardTemplate"]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  grep -q 'CardTemplate' "$doc_dir/ux-design.md" || \
    fail "CardTemplate from templates not added to components section"

  rm -rf "$root"
}


# =========================================================================
# Removal report compares against union of components and templates
# =========================================================================

@test "removal report compares against union of components and templates" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

| Component | Source |
|-----------|--------|
| CardTemplate | Custom |
| OldWidget | Legacy |

## Design Record Reference
UX

  # CardTemplate is in templates (not components) — the union should include it
  # OldWidget is absent from both — positive control for the absence report
  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":[],"templates":["CardTemplate"]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Must NOT report CardTemplate as absent — it is in the templates union
  [[ "$output" != *'CardTemplate'*'absent'* ]] || \
    fail "CardTemplate reported as absent despite being in templates: $output"

  # Must report OldWidget as absent — positive control
  [[ "$output" == *'OldWidget'*'absent'* ]] || \
    fail "OldWidget should be reported as absent (positive control): $output"

  rm -rf "$root"
}

@test "empty components and templates still reports doc components as absent" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

| Component | Source |
|-----------|--------|
| Button | Custom |

## Design Record Reference
UX

  # Both components and templates are empty
  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":[],"templates":[]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Must report Button as absent even with empty snapshot
  [[ "$output" == *'Button'*'absent'* ]] || \
    fail "Button should be reported as absent when snapshot has no components: $output"

  # Must NOT also print the "up to date" line (contradicts the absence report)
  [[ "$output" != *'up to date'* ]] || \
    fail "zero-components pass should not print 'up to date' alongside absence lines: $output"

  rm -rf "$root"
}


# =========================================================================
# Product-design pass must not report absent components
# =========================================================================

@test "product-design pass prints no absent-component lines" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

| Component | Source |
|-----------|--------|
| Button | Custom |
| Card | Custom |

## Design Record Reference
UX

  local snapshot="$root/snapshot.json"
  # Components exist only in design_system — product_design gets []
  jq -n '{"design_system":{"components":["Button","Card"]},
          "product_design":{"screens":[{"name":"Home","file":"screens/home.spec.html","content":"body"}]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project product_design "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Must NOT print any absent line (that belongs to the design_system pass)
  local absent_count
  absent_count="$(printf '%s\n' "$output" | grep -c 'absent' || true)"
  [ "$absent_count" -eq 0 ] || \
    fail "product-design pass should print no absent-component lines ($absent_count found): $output"

  rm -rf "$root"
}


# =========================================================================
# Flows emitted like screens with product-design markers
# =========================================================================

@test "flows emitted like screens with product-design markers" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"product_design":{"screens":[],"flows":[{"name":"Login Flow","file":"flows/login.flow.html","content":"flow body"}]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project product_design "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Flow content should be emitted with product-design markers
  [[ "$output" == *'<<<PRODUCT_DESIGN_PROJECT_BOUNDARY>>>'* ]] || \
    fail "missing product-design boundary markers for flow: $output"
  [[ "$output" == *'flow body'* ]] || \
    fail "flow content not in output: $output"

  rm -rf "$root"
}


# =========================================================================
# Token change with referencing screen produces reconciliation finding
# =========================================================================

@test "token change with referencing screen produces reconciliation finding" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local tok_baseline="$BATS_TMPDIR/tok-baseline-$$.json"
  printf '{"--primary-color":"#3B82F6"}\n' > "$tok_baseline"

  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":["nav"],"tokens":{"--primary-color":"#2563EB"}},
          "product_design":{"screens":[{"name":"login","file":"screens/login.spec.html","content":"body { color: var(--primary-color); }"}]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Must produce exactly one reconciliation finding with the exact pinned line
  local recon_lines
  recon_lines="$(printf '%s\n' "$output" | grep -c 'reconciliation (medium)' || true)"
  [ "$recon_lines" -eq 1 ] || \
    fail "expected exactly 1 reconciliation finding, got $recon_lines: $output"
  [[ "$output" == *'reconciliation (medium): token --primary-color #3B82F6 -> #2563EB affects screen login'* ]] || \
    fail "expected exact reconciliation line for --primary-color: $output"

  # Baseline must be updated with the new value
  local baseline_val
  baseline_val="$(jq -r '."--primary-color"' "$tok_baseline")"
  [ "$baseline_val" = "#2563EB" ] || \
    fail "baseline should hold the new value #2563EB, got: $baseline_val"

  rm -f "$tok_baseline"
  rm -rf "$root"
}

@test "token change with non-referencing screen produces no finding for it" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local tok_baseline="$BATS_TMPDIR/tok-nonref-baseline-$$.json"
  printf '{"--primary-color":"#3B82F6"}\n' > "$tok_baseline"

  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":["nav"],"tokens":{"--primary-color":"#2563EB"}},
          "product_design":{"screens":[
            {"name":"login","file":"screens/login.spec.html","content":"body { color: var(--primary-color); }"},
            {"name":"about","file":"screens/about.spec.html","content":"body { color: var(--other-token); }"}
          ]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Must produce a finding for login but not for about
  [[ "$output" == *'affects screen login'* ]] || \
    fail "expected reconciliation finding for login: $output"
  [[ "$output" != *'affects screen about'* ]] || \
    fail "about does not reference --primary-color, should have no finding: $output"

  rm -f "$tok_baseline"
  rm -rf "$root"
}


# =========================================================================
# Screen name with newline skips token-screen reconciliation
# =========================================================================

@test "screen name with newline skips token-screen reconciliation" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local tok_baseline="$BATS_TMPDIR/tok-newline-name-$$.json"
  printf '{"--primary":"#000"}\n' > "$tok_baseline"

  # Screen name contains a literal newline — must be rejected
  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":["nav"],"tokens":{"--primary":"#fff"}},
          "product_design":{"screens":[{"name":"bad\nname","file":"s/bad.spec.html","content":"var(--primary)"}]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync should not abort (exit $status): $output"

  # Diagnostic about invalid screen data
  [[ "$output" == *'invalid product screen data'* ]] || \
    fail "should print a diagnostic about the bad screen name: $output"

  # Must NOT produce a reconciliation finding (screens were refused)
  local recon_findings
  recon_findings="$(printf '%s\n' "$output" | grep -c 'reconciliation (medium)' || true)"
  [ "$recon_findings" -eq 0 ] || \
    fail "should not produce reconciliation findings against invalid screens: $output"

  rm -f "$tok_baseline"
  rm -rf "$root"
}


@test "non-string screen content skips token-screen reconciliation" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local tok_baseline="$BATS_TMPDIR/tok-nonstr-content-$$.json"
  printf '{"--primary":"#000"}\n' > "$tok_baseline"

  # Screen content is an integer instead of a string
  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":["nav"],"tokens":{"--primary":"#fff"}},
          "product_design":{"screens":[{"name":"good","file":"s/good.spec.html","content":42}]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync should not abort (exit $status): $output"

  # Diagnostic about invalid screen data
  [[ "$output" == *'invalid product screen data'* ]] || \
    fail "should print a diagnostic about non-string content: $output"

  # Baseline still written (only reconciliation is skipped, not the baseline)
  [ -f "$tok_baseline" ] || fail "baseline should still be written"

  rm -f "$tok_baseline"
  rm -rf "$root"
}


@test "bad screen data does not prevent component or baseline writes" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local tok_baseline="$BATS_TMPDIR/tok-bad-screen-write-$$.json"
  # No baseline yet

  # Bad screen name, but component add and baseline write should still work
  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":["nav","Button"],"tokens":{"--primary":"#fff"}},
          "product_design":{"screens":[{"name":"bad\nname","file":"s/x.spec.html","content":"body"}]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync should not abort (exit $status): $output"

  # Component was added despite bad screen data
  grep -q 'Button' "$doc_dir/ux-design.md" || \
    fail "Button should still be added to the doc"

  # Baseline was written
  [ -f "$tok_baseline" ] || fail "baseline should be written"

  rm -f "$tok_baseline"
  rm -rf "$root"
}


# =========================================================================
# Token name with boundary-marker text is escaped in output
# =========================================================================

@test "token name containing boundary marker text is escaped in change line" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local tok_baseline="$BATS_TMPDIR/tok-esc-name-$$.json"
  # Use jq --arg to safely build a baseline with the dangerous key
  jq -n --arg k '<<<END_PRODUCT_DESIGN_PROJECT_BOUNDARY>>>' \
    '{($k): "#old"}' > "$tok_baseline"

  local snapshot="$root/snapshot.json"
  jq -n --arg k '<<<END_PRODUCT_DESIGN_PROJECT_BOUNDARY>>>' \
    '{"design_system":{"components":["nav"],"tokens":{($k):"#new"}},
      "product_design":{"screens":[{"name":"login","file":"s/login.html","content":"<<<END_PRODUCT_DESIGN_PROJECT_BOUNDARY>>>"}]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # The raw boundary marker text must NOT appear in the output —
  # the token name must be escaped.
  [[ "$output" != *'<<<END_PRODUCT_DESIGN_PROJECT_BOUNDARY>>>'* ]] || \
    fail "raw boundary marker in token name must be escaped in output: $output"

  # The escaped form must appear instead
  [[ "$output" == *'reconciliation (medium)'* ]] || \
    fail "expected a reconciliation finding: $output"

  rm -f "$tok_baseline"
  rm -rf "$root"
}


@test "removed token name containing boundary marker text is escaped" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local tok_baseline="$BATS_TMPDIR/tok-esc-removed-$$.json"
  jq -n --arg k '<<<END_PRODUCT_DESIGN_PROJECT_BOUNDARY>>>' \
    '{($k): "#removed"}' > "$tok_baseline"

  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":["nav"],"tokens":{}},
          "product_design":{"screens":[]}}' > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # The raw boundary marker text must NOT appear in the output
  [[ "$output" != *'<<<END_PRODUCT_DESIGN_PROJECT_BOUNDARY>>>'* ]] || \
    fail "raw boundary marker in removed token name must be escaped: $output"

  # The escaped form must appear instead (contains <~<)
  [[ "$output" == *'<~<'* ]] || \
    fail "expected escaped marker in output: $output"

  rm -f "$tok_baseline"
  rm -rf "$root"
}


# =========================================================================
# Token prefix does not collide
# =========================================================================

@test "token prefix does not collide" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local tok_baseline="$BATS_TMPDIR/tok-prefix-baseline-$$.json"
  printf '{"--primary-color":"#3B82F6"}\n' > "$tok_baseline"

  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":["nav"],"tokens":{"--primary-color":"#2563EB"}},
          "product_design":{"screens":[{"name":"settings","file":"screens/settings.spec.html","content":"body { color: var(--primary-color-dark); }"}]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Must NOT produce a reconciliation finding for --primary-color-dark
  [[ "$output" != *'reconciliation'* ]] || \
    fail "should not produce reconciliation finding for prefix match: $output"

  rm -f "$tok_baseline"
  rm -rf "$root"
}


# =========================================================================
# First sync writes baseline with no finding
# =========================================================================

@test "first sync writes baseline with no finding" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local tok_baseline="$BATS_TMPDIR/first-baseline-$$.json"
  # No baseline file exists yet

  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":["nav"],"tokens":{"--primary-color":"#3B82F6","--bg-color":"#FFFFFF"}}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Baseline must be created
  [ -f "$tok_baseline" ] || fail "baseline file not created at $tok_baseline"

  # Baseline must hold both tokens
  local bl_primary bl_bg
  bl_primary="$(jq -r '."--primary-color"' "$tok_baseline")"
  bl_bg="$(jq -r '."--bg-color"' "$tok_baseline")"
  [ "$bl_primary" = "#3B82F6" ] || fail "baseline --primary-color should be #3B82F6, got: $bl_primary"
  [ "$bl_bg" = "#FFFFFF" ] || fail "baseline --bg-color should be #FFFFFF, got: $bl_bg"

  # No reconciliation findings on first sync
  [[ "$output" != *'reconciliation'* ]] || \
    fail "first sync should not produce reconciliation findings: $output"

  rm -f "$tok_baseline"
  rm -rf "$root"
}


# =========================================================================
# No product part writes baseline with no finding
# =========================================================================

@test "no product part writes baseline with no finding" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local tok_baseline="$BATS_TMPDIR/nopd-baseline-$$.json"
  printf '{"--primary-color":"#3B82F6"}\n' > "$tok_baseline"

  # Combined snapshot with only design_system (no product_design key)
  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":["nav"],"tokens":{"--primary-color":"#2563EB"}}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Baseline must be updated with the new value
  [ -f "$tok_baseline" ] || fail "baseline file missing"
  local bl_val
  bl_val="$(jq -r '."--primary-color"' "$tok_baseline")"
  [ "$bl_val" = "#2563EB" ] || fail "baseline should be updated to #2563EB, got: $bl_val"

  # No reconciliation findings (no product_design screens to scan)
  [[ "$output" != *'reconciliation'* ]] || \
    fail "no-product-part sync should not produce reconciliation findings: $output"

  rm -f "$tok_baseline"
  rm -rf "$root"
}


# =========================================================================
# Explicit token-baseline flag isolates path
# =========================================================================

@test "explicit token-baseline flag isolates path" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local tok_baseline="$BATS_TMPDIR/iso-baseline-$$.json"

  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":["nav"],"tokens":{"--color":"#000"}}}' \
    > "$snapshot"

  # Run without PROJECT_ROOT so the only baseline path is the explicit flag
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Baseline must be written at the explicit path
  [ -f "$tok_baseline" ] || fail "baseline not written at explicit path $tok_baseline"

  rm -f "$tok_baseline"
  rm -rf "$root"
}


# =========================================================================
# No project config folder skips baseline with warning
# =========================================================================

@test "no project config folder skips baseline with warning" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  # Deliberately do NOT create .gaia/config/project-config.yaml
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":["nav"],"tokens":{"--color":"#000"}}}' \
    > "$snapshot"

  # Run from inside root (no .gaia/config ancestor) so the walk-up
  # cannot find a real project config and leak a baseline write.
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    -C "$root" \
    "$SYNC_SCRIPT" --project design_system \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync should continue without error (exit $status): $output"

  # The skip warning must appear on stderr (captured by bats `run`)
  [[ "$output" == *'no project config folder'*'skipping token baseline'* ]] || \
    fail "expected 'no project config folder ... skipping token baseline' warning: $output"

  # No baseline file should exist anywhere under root
  local baseline_count
  baseline_count="$(find "$root" -name 'design-token-baseline.json' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$baseline_count" -eq 0 ] || \
    fail "baseline should not be written when no project config folder exists"

  rm -rf "$root"
}


# =========================================================================
# Token with control character skipped with diagnostic
# =========================================================================

@test "token with control character in name skipped with diagnostic" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local tok_baseline="$BATS_TMPDIR/ctrl-tok-baseline-$$.json"
  printf '{"--normal":"#000"}\n' > "$tok_baseline"

  # Token name with a control character (tab)
  local snapshot="$root/snapshot.json"
  printf '{"design_system":{"components":["nav"],"tokens":{"--bad\\ttoken":"#FFF","--normal":"#111"}}}\n' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  # Run should continue (not hard-fail) but emit a diagnostic
  [ "$status" -eq 0 ] || fail "sync should continue past control-char token (exit $status): $output"
  # The diagnostic must name the skipped token
  [[ "$output" == *'skipping token with control character'* ]] || \
    fail "expected diagnostic for control-char token name: $output"
  # The bad token must not appear in the baseline
  jq -e '."--bad\ttoken" // empty' "$tok_baseline" >/dev/null 2>&1 && \
    fail "bad token should not be in the baseline"
  # The normal token must still be updated
  local normal_val
  normal_val="$(jq -r '."--normal"' "$tok_baseline")"
  [ "$normal_val" = "#111" ] || \
    fail "normal token should be updated in baseline, got: $normal_val"

  rm -f "$tok_baseline"
  rm -rf "$root"
}

@test "token with control character in value skipped with diagnostic" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local tok_baseline="$BATS_TMPDIR/ctrl-val-baseline-$$.json"
  printf '{"--normal":"#000"}\n' > "$tok_baseline"

  # Token VALUE with a control character (tab)
  local snapshot="$root/snapshot.json"
  printf '{"design_system":{"components":["nav"],"tokens":{"--bad-val":"2\\tX","--normal":"#111"}}}\n' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync should continue past control-char value (exit $status): $output"
  [[ "$output" == *'skipping token with control character'* ]] || \
    fail "expected diagnostic for control-char token value: $output"
  # The bad-value token must not appear in the baseline
  jq -e '."--bad-val" // empty' "$tok_baseline" >/dev/null 2>&1 && \
    fail "token with control-char value should not be in the baseline"
  # The normal token must still be updated
  local normal_val
  normal_val="$(jq -r '."--normal"' "$tok_baseline")"
  [ "$normal_val" = "#111" ] || \
    fail "normal token should be updated in baseline, got: $normal_val"

  rm -f "$tok_baseline"
  rm -rf "$root"
}

@test "malformed token baseline emits diagnostic and is not overwritten" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local tok_baseline="$BATS_TMPDIR/malformed-baseline-$$.json"
  printf 'not json at all\n' > "$tok_baseline"
  local before_hash
  before_hash="$(shasum -a 256 "$tok_baseline" | awk '{print $1}')"

  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":["nav"],"tokens":{"--color":"#FFF"}}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync should continue past malformed baseline (exit $status): $output"
  [[ "$output" == *'malformed token baseline'* ]] || \
    fail "expected diagnostic for malformed baseline: $output"
  # The malformed baseline must NOT be overwritten
  local after_hash
  after_hash="$(shasum -a 256 "$tok_baseline" | awk '{print $1}')"
  [ "$before_hash" = "$after_hash" ] || \
    fail "malformed baseline must not be overwritten"

  rm -f "$tok_baseline"
  rm -rf "$root"
}

@test "non-object tokens emits diagnostic and skips reconciliation" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local tok_baseline="$BATS_TMPDIR/nonobj-baseline-$$.json"
  printf '{"--color":"#000"}\n' > "$tok_baseline"

  # .tokens is an array instead of an object
  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":["nav"],"tokens":["not","an","object"]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync should continue past non-object tokens (exit $status): $output"
  [[ "$output" == *'invalid token data'* ]] || \
    fail "expected diagnostic for non-object tokens: $output"

  rm -f "$tok_baseline"
  rm -rf "$root"
}


# =========================================================================
# Screen content escaped before wrapping in markers
# =========================================================================

@test "screen content escaped before wrapping in markers" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  # Screen content with double angle brackets that must be escaped
  local screens_dir="$root/screens"
  mkdir -p "$screens_dir"
  printf '<h1>Test</h1>\n<<alert>>\n' > "$screens_dir/angles.spec.html"

  local snapshot="$root/snapshot.json"
  jq -n --rawfile sc "$screens_dir/angles.spec.html" \
    '{"components":[],"screens":[{"name":"Angles","file":"screens/angles.spec.html","content":$sc}]}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project product_design "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # The << in the content must be escaped to <~<
  [[ "$output" == *'<~<'* ]] || \
    fail "double angle bracket in screen content not escaped to <~<: $output"

  # Raw << should NOT appear inside the boundary markers
  # (The markers themselves contain <<< but the content between them should not have raw <<)
  local between_markers
  between_markers="$(printf '%s\n' "$output" | sed -n '/<<<PRODUCT_DESIGN_PROJECT_BOUNDARY>>>/,/<<<END_PRODUCT_DESIGN_PROJECT_BOUNDARY>>>/p' | grep -v 'BOUNDARY')"
  [[ "$between_markers" != *'<<'* ]] || [[ "$between_markers" == *'<~<'* ]] || \
    fail "raw << found between markers (should be escaped): $between_markers"

  rm -rf "$root"
}


# =========================================================================
# Hostile screen filename rejection under product_design run
# =========================================================================

@test "hostile flow filename rejection under product_design run" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  # Flow with shell-meta characters in the file path
  local snapshot="$root/snapshot.json"
  jq -n '{"product_design":{"screens":[],"flows":[{"name":"Evil Flow","file":"flows/evil$(id);.flow.html","content":"body"}]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project product_design "$snapshot" "$doc_dir/ux-design.md"

  # Must reject the hostile flow filename
  [ "$status" -ne 0 ] || \
    fail "should reject hostile flow filename with shell-meta characters (exit $status): $output"
  [[ "$output" == *'unsafe'* ]] || \
    fail "expected 'unsafe' diagnostic for hostile flow filename: $output"

  rm -rf "$root"
}

@test "hostile screen filename rejection under product_design run" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  # Screen with shell-meta characters in the file path
  local snapshot="$root/snapshot.json"
  jq -n '{"components":[],"screens":[{"name":"Evil","file":"screens/evil$(cmd).html","content":"body"}]}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project product_design "$snapshot" "$doc_dir/ux-design.md"

  # Must reject the hostile filename
  [ "$status" -ne 0 ] || \
    fail "should reject hostile filename with shell-meta characters (exit $status): $output"

  rm -rf "$root"
}


# =========================================================================
# Reconciliation uses pre-extracted screens (structure test)
# =========================================================================

@test "reconciliation does not fork per screen per token" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  # Verify the reconciliation section uses a single awk pass over all
  # screens instead of spawning one grep/jq per (token, screen) pair.
  # The section must read screen content files from within awk (via
  # getline) and must NOT have per-screen grep or jq calls.
  local recon_section
  recon_section="$(sed -n '/changed_tokens/,/removed_tokens/p' "$SYNC_SCRIPT")"
  [ -n "$recon_section" ] || fail "could not find the reconciliation section"

  # Must NOT have jq calls inside the inner screen loop
  local inner_jq_count
  inner_jq_count="$(printf '%s\n' "$recon_section" | grep -c 'jq.*\.\[.*\$si' || true)"
  [ "$inner_jq_count" -eq 0 ] || \
    fail "reconciliation must not fork jq per screen (found $inner_jq_count jq calls with index variable)"

  # Must use a single awk call that reads screen content via getline
  grep -q 'getline.*scr_path' <<<"$recon_section" || \
    fail "reconciliation must use a single awk with getline for screen content"
}


# =========================================================================
# Reconciliation at 20x20 scale completes in reasonable time
# =========================================================================

# bats test_tags=hardware-dependent
@test "reconciliation 20x20 completes in under 15 seconds" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local tok_baseline="$BATS_TMPDIR/scale-baseline-$$.json"

  # Build a baseline with 20 tokens and a snapshot with 20 changed tokens + 20 screens
  local baseline_obj='{' new_tok_obj='{'
  local screens_arr='['
  local i
  for i in $(seq 1 20); do
    [ "$i" -gt 1 ] && baseline_obj="${baseline_obj},"
    [ "$i" -gt 1 ] && new_tok_obj="${new_tok_obj},"
    [ "$i" -gt 1 ] && screens_arr="${screens_arr},"
    baseline_obj="${baseline_obj}\"--color-${i}\":\"#old${i}\""
    new_tok_obj="${new_tok_obj}\"--color-${i}\":\"#new${i}\""
    screens_arr="${screens_arr}{\"name\":\"screen${i}\",\"file\":\"screens/s${i}.html\",\"content\":\"body { color: var(--color-${i}); }\"}"
  done
  baseline_obj="${baseline_obj}}"
  new_tok_obj="${new_tok_obj}}"
  screens_arr="${screens_arr}]"

  printf '%s\n' "$baseline_obj" > "$tok_baseline"

  local snapshot="$root/snapshot.json"
  jq -n --argjson t "$new_tok_obj" --argjson s "$screens_arr" \
    '{"design_system":{"components":["nav"],"tokens":$t},"product_design":{"screens":$s}}' \
    > "$snapshot"

  local start_time
  start_time="$(date +%s)"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  local end_time elapsed
  end_time="$(date +%s)"
  elapsed=$((end_time - start_time))

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Must complete in under 15 seconds (the old quadratic loop took ~10s at 20x20)
  [ "$elapsed" -lt 15 ] || \
    fail "20x20 reconciliation took ${elapsed}s (limit: 15s)"

  # Must produce 20 reconciliation findings
  local recon_count
  recon_count="$(printf '%s\n' "$output" | grep -c 'reconciliation (medium)' || true)"
  [ "$recon_count" -eq 20 ] || \
    fail "expected 20 reconciliation findings, got $recon_count"

  rm -f "$tok_baseline"
  rm -rf "$root"
}


# =========================================================================
# Component-sync subprocess count does not grow with N
# =========================================================================

# Helper: create a counting shim for a command.
# Usage: _make_counting_shim SHIM_DIR CMD COUNTER_FILE
_make_counting_shim() {
  local shim_dir="$1" cmd="$2" counter_file="$3"
  local real_path
  real_path="$(command -v "$cmd")"
  printf '0\n' > "$counter_file"
  cat > "$shim_dir/$cmd" <<SHIM
#!/usr/bin/env bash
count=\$(cat "$counter_file")
printf '%d\n' "\$((count + 1))" > "$counter_file"
exec "$real_path" "\$@"
SHIM
  chmod +x "$shim_dir/$cmd"
}

@test "removal report awk count is constant regardless of component count" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  # The regression was that the removal report re-extracted doc components
  # after additions, spawning N awk calls. The fix reuses the pre-computed
  # variable. This test verifies that the awk count does not grow with N.
  # Grep counts scale linearly with N (one per snapshot component in the
  # addition loop) — that is inherent, not a regression.
  local root10 root200
  root10="$(mktemp -d)"
  root200="$(mktemp -d)"

  local n_dir
  for n_dir in "$root10" "$root200"; do
    local doc_dir="$n_dir/.gaia/artifacts/planning-artifacts"
    mkdir -p "$doc_dir"
    cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

| Component | Source |
|-----------|--------|
| Existing | Custom |

## Design Record Reference
UX
  done

  python3 -c '
import json, sys
comps = ["Existing"] + [f"c{i}" for i in range(1, 10)]
json.dump({"components": comps}, sys.stdout)
' > "$root10/snapshot.json"

  python3 -c '
import json, sys
comps = ["Existing"] + [f"c{i}" for i in range(1, 200)]
json.dump({"components": comps}, sys.stdout)
' > "$root200/snapshot.json"

  local shim_dir10="$root10/shim"
  mkdir -p "$shim_dir10"
  _make_counting_shim "$shim_dir10" "awk" "$root10/awk_count"

  local shim_dir200="$root200/shim"
  mkdir -p "$shim_dir200"
  _make_counting_shim "$shim_dir200" "awk" "$root200/awk_count"

  PATH="$shim_dir10:$PATH" run "$SYNC_SCRIPT" \
    "$root10/snapshot.json" "$root10/.gaia/artifacts/planning-artifacts/ux-design.md"
  [ "$status" -eq 0 ] || fail "10-component sync failed: $output"
  local awk10
  awk10="$(cat "$root10/awk_count")"

  PATH="$shim_dir200:$PATH" run "$SYNC_SCRIPT" \
    "$root200/snapshot.json" "$root200/.gaia/artifacts/planning-artifacts/ux-design.md"
  [ "$status" -eq 0 ] || fail "200-component sync failed: $output"
  local awk200
  awk200="$(cat "$root200/awk_count")"

  # The awk count must not grow with N (was +200 before the fix).
  # Allow up to 3x headroom for constant-factor variation.
  [ "$awk200" -le "$((awk10 * 3))" ] || \
    fail "awk calls scaled with N: 10-comp=$awk10, 200-comp=$awk200"

  rm -rf "$root10" "$root200"
}


# =========================================================================
# Token reconciliation process count is constant per screen count
# =========================================================================

@test "reconciliation process count does not grow with token count" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root5 root50
  root5="$(mktemp -d)"
  root50="$(mktemp -d)"

  local n_dir
  for n_dir in "$root5" "$root50"; do
    local doc_dir="$n_dir/.gaia/artifacts/planning-artifacts"
    mkdir -p "$doc_dir"
    cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX
  done

  # Build scale snapshots with different token counts
  python3 -c "
import json, sys
n = int(sys.argv[1])
baseline = {}
tokens = {}
for i in range(n):
    baseline['--tok-%d' % i] = '#old%d' % i
    tokens['--tok-%d' % i] = '#new%d' % i
screens = []
for j in range(5):
    body = 'body { '
    for i in range(n):
        body += 'var(--tok-%d) ' % i
    body += '}'
    screens.append({'name': 'screen%d' % j, 'file': 'screens/s%d.html' % j, 'content': body})
json.dump(baseline, open(sys.argv[2], 'w'))
json.dump({'design_system': {'components': ['nav'], 'tokens': tokens}, 'product_design': {'screens': screens}}, sys.stdout)
" 5 "$root5/tok-baseline.json" > "$root5/snapshot.json"

  python3 -c "
import json, sys
n = int(sys.argv[1])
baseline = {}
tokens = {}
for i in range(n):
    baseline['--tok-%d' % i] = '#old%d' % i
    tokens['--tok-%d' % i] = '#new%d' % i
screens = []
for j in range(5):
    body = 'body { '
    for i in range(n):
        body += 'var(--tok-%d) ' % i
    body += '}'
    screens.append({'name': 'screen%d' % j, 'file': 'screens/s%d.html' % j, 'content': body})
json.dump(baseline, open(sys.argv[2], 'w'))
json.dump({'design_system': {'components': ['nav'], 'tokens': tokens}, 'product_design': {'screens': screens}}, sys.stdout)
" 50 "$root50/tok-baseline.json" > "$root50/snapshot.json"

  local shim5="$root5/shim"
  mkdir -p "$shim5"
  _make_counting_shim "$shim5" "grep" "$root5/grep_count"

  local shim50="$root50/shim"
  mkdir -p "$shim50"
  _make_counting_shim "$shim50" "grep" "$root50/grep_count"

  PATH="$shim5:$PATH" run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$root5/tok-baseline.json" \
    "$root5/snapshot.json" "$root5/.gaia/artifacts/planning-artifacts/ux-design.md"
  [ "$status" -eq 0 ] || fail "5-token sync failed: $output"
  local grep5
  grep5="$(cat "$root5/grep_count")"

  PATH="$shim50:$PATH" run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$root50/tok-baseline.json" \
    "$root50/snapshot.json" "$root50/.gaia/artifacts/planning-artifacts/ux-design.md"
  [ "$status" -eq 0 ] || fail "50-token sync failed: $output"
  local grep50
  grep50="$(cat "$root50/grep_count")"

  # Grep count must not grow proportionally with token count.
  [ "$grep50" -le "$((grep5 * 3))" ] || \
    fail "grep calls scaled with token count: 5-tok=$grep5, 50-tok=$grep50"

  rm -rf "$root5" "$root50"
}


# =========================================================================
# Non-array screens in design-system pass gives diagnostic, not crash
# =========================================================================

@test "design-system pass with non-array screens gives diagnostic" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local tok_baseline="$BATS_TMPDIR/nonarray-screens-$$.json"
  printf '{"--primary":"#000"}\n' > "$tok_baseline"

  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":["nav"],"tokens":{"--primary":"#fff"}},
          "product_design":{"screens":"oops"}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "should not crash on non-array screens (exit $status): $output"
  [[ "$output" == *'invalid product screen data'* ]] || \
    fail "should print a diagnostic about non-array screens: $output"

  # Baseline must NOT be updated
  local bl_val
  bl_val="$(jq -r '."--primary"' "$tok_baseline")"
  [ "$bl_val" = "#000" ] || \
    fail "baseline should be preserved when reconciliation is skipped, got: $bl_val"

  rm -f "$tok_baseline"
  rm -rf "$root"
}


@test "design-system pass with non-object screen entries gives diagnostic" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local tok_baseline="$BATS_TMPDIR/nonobj-screens-$$.json"
  printf '{"--primary":"#000"}\n' > "$tok_baseline"

  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":["nav"],"tokens":{"--primary":"#fff"}},
          "product_design":{"screens":["login"]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "should not crash on non-object screen entries (exit $status): $output"
  [[ "$output" == *'invalid product screen data'* ]] || \
    fail "should print a diagnostic: $output"

  local bl_val
  bl_val="$(jq -r '."--primary"' "$tok_baseline")"
  [ "$bl_val" = "#000" ] || \
    fail "baseline should be preserved, got: $bl_val"

  rm -f "$tok_baseline"
  rm -rf "$root"
}


# =========================================================================
# Skipped reconciliation preserves baseline for re-evaluation
# =========================================================================

@test "invalid screen data then fixed data still reports token change" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local tok_baseline="$BATS_TMPDIR/skip-reeval-$$.json"
  printf '{"--primary":"#3B82F6"}\n' > "$tok_baseline"

  # First run: invalid screen (null entry), token changed
  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":["nav"],"tokens":{"--primary":"#2563EB"}},
          "product_design":{"screens":[null,{"name":"login","file":"s/login.html","content":"var(--primary)"}]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "first run failed: $output"

  local bl_val1
  bl_val1="$(jq -r '."--primary"' "$tok_baseline")"
  [ "$bl_val1" = "#3B82F6" ] || \
    fail "baseline should be preserved after skipped reconciliation, got: $bl_val1"

  # Second run: fixed screen data
  jq -n '{"design_system":{"components":["nav"],"tokens":{"--primary":"#2563EB"}},
          "product_design":{"screens":[{"name":"login","file":"s/login.html","content":"var(--primary)"}]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "second run failed: $output"

  [[ "$output" == *'reconciliation (medium): token --primary #3B82F6 -> #2563EB affects screen login'* ]] || \
    fail "expected reconciliation finding on re-run after fix: $output"

  rm -f "$tok_baseline"
  rm -rf "$root"
}


# =========================================================================
# Baseline token with control character filtered before reconciliation
# =========================================================================

@test "baseline token with tab in value filtered with diagnostic" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local tok_baseline="$BATS_TMPDIR/bl-ctrl-$$.json"
  printf '{"--dirty":"#fff\\t#000","--clean":"#aaa"}\n' > "$tok_baseline"

  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":["nav"],"tokens":{"--dirty":"#111","--clean":"#bbb"}},
          "product_design":{"screens":[{"name":"s","file":"s/s.html","content":"var(--clean)"}]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed: $output"
  [[ "$output" == *'baseline token with control character'* ]] || \
    fail "expected diagnostic for baseline control character: $output"
  [[ "$output" == *'reconciliation (medium): token --clean'* ]] || \
    fail "expected reconciliation finding for clean token: $output"

  rm -f "$tok_baseline"
  rm -rf "$root"
}


# =========================================================================
# Left word boundary: identifier char before token suppresses finding
# =========================================================================

@test "token preceded by identifier char is not reported" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local tok_baseline="$BATS_TMPDIR/left-boundary-$$.json"
  printf '{"--primary":"#000"}\n' > "$tok_baseline"

  # Screen A: token preceded by identifier chars (no left word boundary)
  # Screen B: token inside var() (left word boundary present)
  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":["nav"],"tokens":{"--primary":"#fff"}},
          "product_design":{"screens":[
            {"name":"no-boundary","file":"screens/a.html","content":"body { color: var(--brand--primary); x--primary; }"},
            {"name":"has-boundary","file":"screens/b.html","content":"body { color: var(--primary); }"}
          ]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Must NOT report for the screen where the token is preceded by an identifier char
  [[ "$output" != *'affects screen no-boundary'* ]] || \
    fail "token preceded by identifier char should not be reported: $output"

  # Must report for the screen where the token has a proper word boundary
  [[ "$output" == *'reconciliation (medium): token --primary #000 -> #fff affects screen has-boundary'* ]] || \
    fail "token with word boundary should be reported: $output"

  rm -f "$tok_baseline"
  rm -rf "$root"
}


# =========================================================================
# Combined snapshot with non-array components exits with diagnostic
# =========================================================================

@test "combined snapshot with non-array components exits with diagnostic" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local ux_doc="$doc_dir/ux-design.md"
  local sha_before
  sha_before="$(_sha256_file "$ux_doc")"

  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":"not-an-array"}}' > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system "$snapshot" "$ux_doc"

  [ "$status" -ne 0 ] || \
    fail "should exit non-zero for non-array components (exit $status): $output"
  [[ "$output" == *'.components must be an array'* ]] || \
    fail "expected diagnostic about non-array components: $output"

  local sha_after
  sha_after="$(_sha256_file "$ux_doc")"
  [ "$sha_before" = "$sha_after" ] || \
    fail "doc changed despite rejected snapshot"

  rm -rf "$root"
}

@test "combined snapshot with non-array templates exits with diagnostic" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":[],"templates":"not-an-array"}}' > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -ne 0 ] || \
    fail "should exit non-zero for non-array templates (exit $status): $output"
  [[ "$output" == *'.templates must be an array'* ]] || \
    fail "expected diagnostic about non-array templates: $output"

  rm -rf "$root"
}


# =========================================================================
# First fill of empty components table does not re-read the doc
# =========================================================================

@test "first fill from empty table does not re-extract doc components" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  # This test verifies the fix for the slow first fill. When the doc's
  # components table starts empty (header row only, no data rows), the
  # awk count must remain constant — the script must not re-extract
  # doc components after additions.
  local root10 root200
  root10="$(mktemp -d)"
  root200="$(mktemp -d)"

  local n_dir
  for n_dir in "$root10" "$root200"; do
    local doc_dir="$n_dir/.gaia/artifacts/planning-artifacts"
    mkdir -p "$doc_dir"
    # Empty components table: header row + separator, no data rows.
    cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

| Component | Source |
|-----------|--------|

## Design Record Reference
UX
  done

  python3 -c '
import json, sys
comps = [f"c{i}" for i in range(1, 10)]
json.dump({"components": comps}, sys.stdout)
' > "$root10/snapshot.json"

  python3 -c '
import json, sys
comps = [f"c{i}" for i in range(1, 200)]
json.dump({"components": comps}, sys.stdout)
' > "$root200/snapshot.json"

  local shim_dir10="$root10/shim"
  mkdir -p "$shim_dir10"
  _make_counting_shim "$shim_dir10" "awk" "$root10/awk_count"

  local shim_dir200="$root200/shim"
  mkdir -p "$shim_dir200"
  _make_counting_shim "$shim_dir200" "awk" "$root200/awk_count"

  PATH="$shim_dir10:$PATH" run "$SYNC_SCRIPT" \
    "$root10/snapshot.json" "$root10/.gaia/artifacts/planning-artifacts/ux-design.md"
  [ "$status" -eq 0 ] || fail "10-component empty-table sync failed: $output"
  local awk10
  awk10="$(cat "$root10/awk_count")"

  PATH="$shim_dir200:$PATH" run "$SYNC_SCRIPT" \
    "$root200/snapshot.json" "$root200/.gaia/artifacts/planning-artifacts/ux-design.md"
  [ "$status" -eq 0 ] || fail "200-component empty-table sync failed: $output"
  local awk200
  awk200="$(cat "$root200/awk_count")"

  # The awk count must not grow with N. Before the fix, an empty table
  # caused a re-read that spawned +N awk calls.
  [ "$awk200" -le "$((awk10 * 3))" ] || \
    fail "empty-table awk calls scaled with N: 10-comp=$awk10, 200-comp=$awk200"

  rm -rf "$root10" "$root200"
}


# =========================================================================
# Token after NUL byte in screen content is still reported
# =========================================================================

@test "token after nul byte in screen content is reported" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local tok_baseline="$BATS_TMPDIR/nul-tok-$$.json"
  printf '{"--a":"#000"}\n' > "$tok_baseline"

  # Build a screen content string that contains a real NUL byte.
  # Write the raw content to a file, inject it into JSON via --rawfile,
  # and verify the NUL round-trips through jq.
  local content_file="$BATS_TMPDIR/nul-content-$$.bin"
  printf 'before text\x00 var(--a) after' > "$content_file"

  local snapshot="$root/snapshot.json"
  jq -n --rawfile c "$content_file" \
    '{"design_system":{"components":["nav"],"tokens":{"--a":"#fff"}},
      "product_design":{"screens":[{"name":"s1","file":"s/s.html","content":$c}]}}' \
    > "$snapshot"

  # Confirm the NUL byte survives a jq extraction of the content field
  local nul_count
  nul_count="$(jq -j '.product_design.screens[0].content' "$snapshot" \
    | od -A n -t x1 | tr ' ' '\n' | grep -c '^00$')" || true
  [ "$nul_count" -ge 1 ] || fail "extracted content should contain at least one NUL byte, got $nul_count"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed: $output"
  [[ "$output" == *'reconciliation (medium): token --a'* ]] || \
    fail "token after NUL byte should still be reported: $output"

  rm -f "$tok_baseline" "$content_file"
  rm -rf "$root"
}

@test "nul byte replaced with space preserves token boundary" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  # When NUL is deleted (tr -d), "x\0--a" becomes "x--a" and the token
  # is not found because "x" is an identifier character touching "--a".
  # When NUL is replaced with a space, "x --a" has a proper boundary.
  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local tok_baseline="$BATS_TMPDIR/nul-join-tok-$$.json"
  printf '{"--a":"#000"}\n' > "$tok_baseline"

  # Content: identifier char immediately before NUL, then the token.
  # tr -d would merge them (false negative); tr '\0' ' ' preserves the boundary.
  local content_file="$BATS_TMPDIR/nul-join-content-$$.bin"
  printf 'x\x00--a rest' > "$content_file"

  local snapshot="$root/snapshot.json"
  jq -n --rawfile c "$content_file" \
    '{"design_system":{"components":["nav"],"tokens":{"--a":"#fff"}},
      "product_design":{"screens":[{"name":"s1","file":"s/s.html","content":$c}]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed: $output"
  [[ "$output" == *'reconciliation (medium): token --a'* ]] || \
    fail "token separated from identifier by NUL should be reported: $output"

  rm -f "$tok_baseline" "$content_file"
  rm -rf "$root"
}


# =========================================================================
# Empty old value reported in the correct order
# =========================================================================

@test "empty old value reported as empty-string to new" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  # Baseline with an empty value for --a
  local tok_baseline="$BATS_TMPDIR/empty-old-$$.json"
  printf '{"--a":""}\n' > "$tok_baseline"

  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":["nav"],"tokens":{"--a":"red"}},
          "product_design":{"screens":[{"name":"s1","file":"s/s.html","content":"var(--a)"}]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed: $output"
  # The old value (empty) must come before the arrow, new value after.
  [[ "$output" == *'token --a  -> red affects screen s1'* ]] || \
    fail "expected 'token --a  -> red' (empty old before arrow): $output"

  rm -f "$tok_baseline"
  rm -rf "$root"
}

@test "empty new value reported as old to empty-string" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  # Baseline with a non-empty value for --a
  local tok_baseline="$BATS_TMPDIR/empty-new-$$.json"
  printf '{"--a":"red"}\n' > "$tok_baseline"

  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":["nav"],"tokens":{"--a":""}},
          "product_design":{"screens":[{"name":"s1","file":"s/s.html","content":"var(--a)"}]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed: $output"
  # The old value (red) must come before the arrow, new value (empty) after.
  [[ "$output" == *'token --a red ->  affects screen s1'* ]] || \
    fail "expected 'token --a red -> ' (empty new after arrow): $output"

  rm -f "$tok_baseline"
  rm -rf "$root"
}


# =========================================================================
# Non-object design_system part gives diagnostic, not raw jq error
# =========================================================================

@test "non-object design_system part gives diagnostic" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":"not-an-object","product_design":{}}' > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 1 ] || \
    fail "non-object design_system should exit 1, got $status: $output"
  [[ "$output" == *'design_system must be an object'* ]] || \
    fail "expected named diagnostic about non-object design_system: $output"

  rm -rf "$root"
}

@test "non-object product_design part gives diagnostic" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":["nav"]},"product_design":"bad"}' > "$snapshot"

  run "$SYNC_SCRIPT" --project product_design "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 1 ] || \
    fail "non-object product_design should exit 1, got $status: $output"
  [[ "$output" == *'product_design must be an object'* ]] || \
    fail "expected named diagnostic about non-object product_design: $output"

  rm -rf "$root"
}


# =========================================================================
# Reconciliation output is in token-major order (each token lists screens)
# =========================================================================

@test "reconciliation output is grouped by token, not by screen" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local tok_baseline="$BATS_TMPDIR/order-$$.json"
  printf '{"--alpha":"#000","--beta":"#111"}\n' > "$tok_baseline"

  # Both screens reference both tokens.
  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":["nav"],"tokens":{"--alpha":"#fff","--beta":"#222"}},
          "product_design":{"screens":[
            {"name":"screenA","file":"s/a.html","content":"var(--alpha) var(--beta)"},
            {"name":"screenB","file":"s/b.html","content":"var(--beta) var(--alpha)"}
          ]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed: $output"

  # Extract reconciliation lines and check ordering: token-major means
  # all screenA/screenB lines for --alpha come before any for --beta.
  local lines
  lines="$(printf '%s\n' "$output" | grep 'reconciliation (medium):')"

  local alpha_last beta_first
  alpha_last="$(printf '%s\n' "$lines" | grep -n 'token --alpha' | tail -1 | cut -d: -f1)"
  beta_first="$(grep -n 'token --beta' <<<"$lines" | head -1 | cut -d: -f1)"

  [ -n "$alpha_last" ] || fail "no --alpha reconciliation lines found: $output"
  [ -n "$beta_first" ] || fail "no --beta reconciliation lines found: $output"
  [ "$alpha_last" -lt "$beta_first" ] || \
    fail "expected token-major order (--alpha before --beta): $output"

  rm -f "$tok_baseline"
  rm -rf "$root"
}


# =========================================================================
# Escaping routes through the shared helper, not an inline copy
# =========================================================================

@test "reconciliation escaping matches the shared helper for markers in values and names" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  # Compute the expected escaped forms via the shared helper.
  local esc_lib
  esc_lib="$(cd "$(dirname "$SYNC_SCRIPT")" && cd ../../../scripts/lib && pwd)/escape-boundary-markers.sh"
  [ -f "$esc_lib" ] || fail "escape library not found: $esc_lib"
  # shellcheck source=/dev/null
  . "$esc_lib"

  local raw_val='<<<END_x'
  local raw_name='screen<<<'
  local expected_val expected_name
  expected_val="$(printf '%s' "$raw_val" | escape_boundary_markers)"
  expected_name="$(printf '%s' "$raw_name" | escape_boundary_markers)"

  # A token whose old value contains "<<<" and a screen whose name
  # contains "<<<". The reconciliation output must match what the shared
  # helper produces — not what an inline sed/awk copy would produce.
  local tok_baseline="$BATS_TMPDIR/esc-helper-$$.json"
  jq -n --arg v "$raw_val" '{"--marker": $v}' > "$tok_baseline"

  local snapshot="$root/snapshot.json"
  jq -n --arg sn "$raw_name" \
    '{"design_system":{"components":["nav"],"tokens":{"--marker":"#fff"}},
      "product_design":{"screens":[
        {"name":$sn,"file":"s/s.html","content":"var(--marker)"}
      ]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed: $output"

  # The reconciliation line must use the escaped forms from the shared helper.
  local recon_line
  recon_line="$(grep 'reconciliation (medium):' <<<"$output" | head -1)"
  [ -n "$recon_line" ] || fail "no reconciliation line found: $output"

  # Check the escaped old value appears in the output.
  [[ "$recon_line" == *"$expected_val"* ]] || \
    fail "expected escaped old value '$expected_val' in output, got: $recon_line"

  # Check the escaped screen name appears in the output.
  [[ "$recon_line" == *"$expected_name"* ]] || \
    fail "expected escaped screen name '$expected_name' in output, got: $recon_line"

  # The raw marker strings must NOT appear in the output.
  [[ "$recon_line" != *'<<<'* ]] || \
    fail "raw marker '<<<' should not appear in escaped output: $recon_line"

  rm -f "$tok_baseline"
  rm -rf "$root"
}


# =========================================================================
# Control-character baseline test goes red when the filter is removed
# =========================================================================

@test "dirty baseline token with screen reference reports no tab in output" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local tok_baseline="$BATS_TMPDIR/dirty-ref-$$.json"
  # A baseline with a tab in the value — this is the dirty token.
  printf '{"--dirty":"#fff\\t#000","--clean":"#aaa"}\n' > "$tok_baseline"

  # A screen that references the dirty token. If the filter is removed,
  # the tab leaks into the reconciliation output.
  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":["nav"],"tokens":{"--dirty":"#111","--clean":"#bbb"}},
          "product_design":{"screens":[{"name":"s","file":"s/s.html","content":"var(--dirty) var(--clean)"}]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed: $output"
  [[ "$output" == *'baseline token with control character'* ]] || \
    fail "expected diagnostic for baseline control character: $output"

  # The dirty token must NOT appear in any reconciliation output.
  # When the baseline filter works, --dirty is removed from comparison
  # so it never reaches the changed-tokens file. Skipping the filter
  # lets the dirty token through, producing a reconciliation line with
  # mangled values or a leaked tab.
  [[ "$output" != *'reconciliation (medium): token --dirty'* ]] || \
    fail "dirty token should not be in reconciliation output (filter leaked): $output"

  # No reconciliation line should contain a tab character.
  local recon_lines
  recon_lines="$(printf '%s\n' "$output" | grep 'reconciliation (medium):' || true)"
  if [ -n "$recon_lines" ]; then
    printf '%s\n' "$recon_lines" | while IFS= read -r line; do
      case "$line" in *$'\t'*)
        fail "reconciliation line contains tab (dirty token leaked): $line"
        ;;
      esac
    done
  fi

  # The clean token should still be reported.
  [[ "$output" == *'reconciliation (medium): token --clean'* ]] || \
    fail "clean token should still be reconciled: $output"

  rm -f "$tok_baseline"
  rm -rf "$root"
}


# =========================================================================
# Unwritable state directory prints diagnostic and does not abort
# =========================================================================

@test "unwritable state directory prints diagnostic and exits 0" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  local state_dir="$root/.gaia/state"
  mkdir -p "$state_dir"

  # Create a baseline in a read-only directory so mktemp fails.
  local tok_baseline="$state_dir/design-token-baseline.json"
  printf '{"--primary":"#000"}\n' > "$tok_baseline"
  chmod 555 "$state_dir"

  local snapshot="$root/snapshot.json"
  jq -n '{"design_system":{"components":["nav"],"tokens":{"--primary":"#fff"}},
          "product_design":{"screens":[]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  # Restore write permissions for cleanup.
  chmod 755 "$state_dir"

  [ "$status" -eq 0 ] || fail "should exit 0 even with unwritable state dir: $output"
  [[ "$output" == *'not writable'* ]] || \
    fail "expected diagnostic about unwritable directory: $output"

  rm -rf "$root"
}


# =========================================================================
# Literal token matching: tokens with regex metacharacters
# =========================================================================

# Helper: build a one-screen reconciliation fixture with a specific
# token name and screen content, run the script, and return whether
# a reconciliation finding was reported.
_run_token_match_test() {
  local tok_name="$1" screen_content="$2"
  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

  # Baseline with old value, snapshot with new value
  local tok_baseline="$root/tok-baseline.json"
  jq -n --arg k "$tok_name" '{ ($k): "#000" }' > "$tok_baseline"

  local snapshot="$root/snapshot.json"
  jq -n --arg k "$tok_name" --arg c "$screen_content" \
    '{"design_system":{"components":["nav"],"tokens":{($k):"#fff"}},
      "product_design":{"screens":[{"name":"s1","file":"s/s.html","content":$c}]}}' \
    > "$snapshot"

  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$tok_baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  rm -rf "$root"
}

@test "token with dot is matched literally, not as regex wildcard" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  # --a.b must NOT match --axb (dot-as-wildcard would match)
  _run_token_match_test "--a.b" "var(--axb)"
  [ "$status" -eq 0 ] || fail "sync failed on false-content: $output"
  [[ "$output" != *'reconciliation'* ]] || \
    fail "dot in token should not match as regex wildcard: $output"

  # --a.b MUST match --a.b (literal dot)
  _run_token_match_test "--a.b" "var(--a.b)"
  [ "$status" -eq 0 ] || fail "sync failed on literal-content: $output"
  [[ "$output" == *'reconciliation (medium): token --a.b'* ]] || \
    fail "literal dot in token should match: $output"
}

@test "token with plus is matched literally" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  _run_token_match_test "--x+y" "var(--x+y)"
  [ "$status" -eq 0 ] || fail "sync failed: $output"
  [[ "$output" == *'reconciliation (medium): token --x+y'* ]] || \
    fail "token with plus should match literally: $output"
}

@test "token with parentheses is matched literally" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  _run_token_match_test "--p(1)" "var(--p(1))"
  [ "$status" -eq 0 ] || fail "sync failed: $output"
  [[ "$output" == *'reconciliation (medium): token --p(1)'* ]] || \
    fail "token with parentheses should match literally: $output"
}

@test "token with dollar sign is matched literally" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  _run_token_match_test '--a$' 'var(--a$)'
  [ "$status" -eq 0 ] || fail "sync failed: $output"
  [[ "$output" == *'reconciliation (medium): token --a$'* ]] || \
    fail "token with dollar should match literally: $output"
}

@test "token with open bracket does not crash awk" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  _run_token_match_test "--a[" "var(--a[)"
  [ "$status" -eq 0 ] || fail "token with [ should not crash: $output"
  [[ "$output" == *'reconciliation (medium): token --a['* ]] || \
    fail "token with [ should match literally: $output"
}

@test "token with backslash-dot is matched literally" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  _run_token_match_test '--a\.b' 'var(--a\.b)'
  [ "$status" -eq 0 ] || fail "sync failed: $output"
  [[ "$output" == *'reconciliation (medium): token --a'* ]] || \
    fail "token with backslash-dot should match literally: $output"
}

@test "token with pipe is matched literally" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  _run_token_match_test "--a|b" "x --a|b y"
  [ "$status" -eq 0 ] || fail "sync failed: $output"
  [[ "$output" == *'reconciliation'* ]] || \
    fail "token with pipe should match literally: $output"
}

@test "token with asterisk is matched literally" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  _run_token_match_test "--a*" "var(--a*)"
  [ "$status" -eq 0 ] || fail "sync failed: $output"
  [[ "$output" == *'reconciliation'* ]] || \
    fail "token with asterisk should match literally: $output"
}


# =========================================================================
# Adjacent occurrences must not give a false positive
# =========================================================================

@test "adjacent identical tokens are not a false boundary match" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  # var(--a--a): both sides of each occurrence border an identifier char
  _run_token_match_test "--a" "var(--a--a)"
  [ "$status" -eq 0 ] || fail "sync failed: $output"
  [[ "$output" != *'reconciliation'* ]] || \
    fail "adjacent --a--a should not be reported as a match: $output"

  # --a --a: space-separated, first occurrence has a valid boundary
  _run_token_match_test "--a" "x --a --a y"
  [ "$status" -eq 0 ] || fail "sync failed: $output"
  [[ "$output" == *'reconciliation (medium): token --a'* ]] || \
    fail "space-separated --a --a should be reported: $output"
}


# =========================================================================
# Pathological token name finishes quickly
# =========================================================================

# ===========================================================================
# Bare "## N. Components" heading support
# ===========================================================================

@test "sync adds component to doc with bare numbered Components heading" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  export PROJECT_ROOT="$root"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components

| Component | Variants | Usage |
|-----------|----------|-------|
| header | default | Navigation |

## Design Record Reference

Present.
UX

  local ux_doc="$doc_dir/ux-design.md"
  local sha_before
  sha_before="$(_sha256_file "$ux_doc")"

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["header","bare-widget"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$ux_doc"
  [ "$status" -eq 0 ] || fail "exit $status: $output"

  grep -q 'bare-widget' "$ux_doc" || \
    fail "bare-widget not added under bare ## 8. Components heading"

  local sha_after
  sha_after="$(_sha256_file "$ux_doc")"
  [ "$sha_before" != "$sha_after" ] || \
    fail "doc should have changed after adding bare-widget"

  rm -rf "$root"
}

@test "sync adds component to doc with bare unnumbered Components heading" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  export PROJECT_ROOT="$root"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Components

- header
- footer

## Design Record Reference

Present.
UX

  local ux_doc="$doc_dir/ux-design.md"

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["header","footer","new-comp"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$ux_doc"
  [ "$status" -eq 0 ] || fail "exit $status: $output"

  grep -q 'new-comp' "$ux_doc" || \
    fail "new-comp not added under bare ## Components heading"

  rm -rf "$root"
}

@test "sync rejects unrelated heading like Component testing" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  export PROJECT_ROOT="$root"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Component testing

Some test content.

## Design Record Reference

Present.
UX

  local ux_doc="$doc_dir/ux-design.md"
  local sha_before
  sha_before="$(_sha256_file "$ux_doc")"

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["widget"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$ux_doc"
  [ "$status" -ne 0 ] || \
    fail "should exit non-zero when only unrelated heading present (exit $status)"

  local sha_after
  sha_after="$(_sha256_file "$ux_doc")"
  [ "$sha_before" = "$sha_after" ] || \
    fail "doc should be unchanged when heading is unrelated"

  rm -rf "$root"
}

@test "pathological token name does not cause exponential regex backtracking" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  # A name that would cause catastrophic backtracking if used as a regex.
  # The content is much longer than the name and contains many near-matches
  # (repeated "(a" runs) that force the literal index() walk to work.
  local tok_name="--(a{1,255}){1,255}"

  # Build content: 500 near-misses of "(a" then the literal token itself.
  local content
  content="$(printf '%0500s' '' | sed 's/ /(a /g') x ${tok_name} y"

  # The run must finish well under 30 seconds.  With literal matching
  # it completes in milliseconds; a regex matcher would hang or crash.
  local t0 t1 elapsed
  t0="$(perl -e 'use Time::HiRes qw(time); printf "%.3f\n", time()')"
  _run_token_match_test "$tok_name" "$content"
  t1="$(perl -e 'use Time::HiRes qw(time); printf "%.3f\n", time()')"
  elapsed="$(perl -e "printf '%.1f', $t1 - $t0")"

  [ "$status" -eq 0 ] || fail "pathological token name should not crash: $output"
  perl -e "exit($elapsed > 30.0 ? 1 : 0)" || \
    fail "pathological token name took ${elapsed}s (expected < 30)"

  # The token literally appears in the content with non-identifier chars
  # on both sides, so the matcher must find it.
  [[ "$output" == *'reconciliation'* ]] || \
    fail "token should be found where it literally appears: $output"
}


# =========================================================================
# Empty token name must not produce a false finding
# =========================================================================

@test "empty token name does not produce a finding" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  # A token whose name is empty after parsing.  The matcher must skip it
  # (no output for that token) and the run must still succeed.
  _run_token_match_test "" "var(--a); color: red"
  [ "$status" -eq 0 ] || fail "empty token name should not crash: $output"
  [[ "$output" != *'reconciliation'* ]] || \
    fail "empty token name should not produce a finding: $output"
}


# =========================================================================
# Quadratic scan guard: the matcher must scale linearly
# =========================================================================

@test "matcher scales linearly with content length and near-miss count" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  # Behavioural bound: run reconciliation at N and 10N near-misses
  # with proportional content length (each near-miss adds 10 bytes).
  # A linear matcher gives about 10x; a quadratic one about 100x.
  # Threshold 30 gives wide margins for noisy CI runners.
  #
  # The script is invoked directly (not through bats `run`) so the
  # timing measures only the script, without fork/capture overhead.
  # If the small run is under 0.2s, repeat it 5 times and average.
  _build_scaling_fixture() {
    local n="$1" root="$2"
    local doc_dir="$root/.gaia/artifacts/planning-artifacts"
    mkdir -p "$doc_dir"
    cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

- nav

## Design Record Reference
UX

    printf '{"--a":"#000"}\n' > "$root/tok-baseline.json"

    # Write content to a file, then inject via --rawfile to avoid
    # ARG_MAX limits on large content strings.
    python3 -c "
import sys
for i in range($n):
    sys.stdout.write('var(--ab) ')
sys.stdout.write('var(--a)')
" > "$root/content.txt"

    jq -n --rawfile c "$root/content.txt" \
      '{"design_system":{"components":["nav"],"tokens":{"--a":"#fff"}},
        "product_design":{"screens":[{"name":"s1","file":"s/s.html","content":$c}]}}' \
      > "$root/snapshot.json"
  }

  local root_small root_large
  root_small="$(mktemp -d)"
  root_large="$(mktemp -d)"
  _build_scaling_fixture 10000 "$root_small"
  _build_scaling_fixture 100000 "$root_large"

  # Correctness check: the small fixture must succeed.
  run "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$root_small/tok-baseline.json" \
    "$root_small/snapshot.json" "$root_small/.gaia/artifacts/planning-artifacts/ux-design.md"
  [ "$status" -eq 0 ] || fail "small fixture failed: $output"

  # Time the small fixture directly (no bats run overhead).
  # Reset the baseline before every timed run so the matcher always
  # sees a changed token and actually reconciles.
  local t0 t1 dur_small
  printf '{"--a":"#000"}\n' > "$root_small/tok-baseline.json"
  t0="$(perl -e 'use Time::HiRes qw(time); printf "%.3f\n", time()')"
  "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$root_small/tok-baseline.json" \
    "$root_small/snapshot.json" \
    "$root_small/.gaia/artifacts/planning-artifacts/ux-design.md" > /dev/null 2>&1
  t1="$(perl -e 'use Time::HiRes qw(time); printf "%.3f\n", time()')"
  dur_small="$(perl -e "printf '%.3f', $t1 - $t0")"

  if perl -e "exit($dur_small < 0.2 ? 0 : 1)"; then
    # Too fast for a single sample — run 5 iterations and average.
    t0="$(perl -e 'use Time::HiRes qw(time); printf "%.3f\n", time()')"
    local _rep=0
    while [ "$_rep" -lt 5 ]; do
      printf '{"--a":"#000"}\n' > "$root_small/tok-baseline.json"
      "$SYNC_SCRIPT" --project design_system \
        --token-baseline "$root_small/tok-baseline.json" \
        "$root_small/snapshot.json" \
        "$root_small/.gaia/artifacts/planning-artifacts/ux-design.md" > /dev/null 2>&1
      _rep=$((_rep + 1))
    done
    t1="$(perl -e 'use Time::HiRes qw(time); printf "%.3f\n", time()')"
    dur_small="$(perl -e "printf '%.3f', ($t1 - $t0) / 5")"
  fi

  # Time the large fixture directly.
  local t2 t3 dur_large
  printf '{"--a":"#000"}\n' > "$root_large/tok-baseline.json"
  t2="$(perl -e 'use Time::HiRes qw(time); printf "%.3f\n", time()')"
  "$SYNC_SCRIPT" --project design_system \
    --token-baseline "$root_large/tok-baseline.json" \
    "$root_large/snapshot.json" \
    "$root_large/.gaia/artifacts/planning-artifacts/ux-design.md" > /dev/null 2>&1 || \
    fail "large fixture script failed"
  t3="$(perl -e 'use Time::HiRes qw(time); printf "%.3f\n", time()')"
  dur_large="$(perl -e "printf '%.3f', $t3 - $t2")"

  local ratio
  ratio="$(perl -e "printf '%.1f', $dur_large / $dur_small")"

  # Linear: ratio near 10.  Quadratic: ratio near 100.  Bound: 30.
  perl -e "exit($ratio > 30.0 ? 1 : 0)" || \
    fail "near-miss scaling looks quadratic: 10K=${dur_small}s, 100K=${dur_large}s, ratio=$ratio (expected < 30)"

  rm -rf "$root_small" "$root_large"
}

# ===========================================================================
# Heading end-of-line anchor tests — pin all five match sites
# ===========================================================================

@test "sync rejects Components of the backend heading — doc unchanged" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  export PROJECT_ROOT="$root"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Components of the backend

| Component | Variants | Usage |
|-----------|----------|-------|
| header | default | Navigation |

## Design Record Reference

Present.
UX

  local ux_doc="$doc_dir/ux-design.md"
  local sha_before
  sha_before="$(_sha256_file "$ux_doc")"

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["widget"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$ux_doc"
  [ "$status" -ne 0 ] || \
    fail "should reject 'Components of the backend' heading (exit $status)"

  local sha_after
  sha_after="$(_sha256_file "$ux_doc")"
  [ "$sha_before" = "$sha_after" ] || \
    fail "doc should be unchanged when heading is rejected"

  rm -rf "$root"
}

@test "sync does not produce duplicate header row under numbered bare heading" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  export PROJECT_ROOT="$root"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components

| Component | Variants | Usage |
|-----------|----------|-------|
| header | default | Navigation |

## Design Record Reference

Present.
UX

  local ux_doc="$doc_dir/ux-design.md"

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["header","newone"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$ux_doc"
  [ "$status" -eq 0 ] || fail "exit $status: $output"

  # Exactly one header row (no duplicate)
  local header_count
  header_count="$(grep -c '| Component |' "$ux_doc")"
  [ "$header_count" -eq 1 ] || \
    fail "expected exactly 1 header row under numbered bare heading, got $header_count"

  # New component is present as a table row (not a bullet)
  grep -q '| newone |' "$ux_doc" || \
    fail "newone should be added as a table row, not a bullet"

  rm -rf "$root"
}

@test "sync finds column count under numbered bare Components heading" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  export PROJECT_ROOT="$root"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components

| Component | Variants | Usage | Notes |
|-----------|----------|-------|-------|
| header | default | Navigation | top |

## Design Record Reference

Present.
UX

  local ux_doc="$doc_dir/ux-design.md"

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["header","widget"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$ux_doc"
  [ "$status" -eq 0 ] || fail "exit $status: $output"

  # widget should have 4 columns (matching the table)
  local widget_pipes
  widget_pipes="$(grep '| widget |' "$ux_doc" | tr -cd '|' | wc -c | tr -d ' ')"
  [ "$widget_pipes" -eq 5 ] || \
    fail "widget row should have 4 columns (5 pipes), got $widget_pipes pipes"

  rm -rf "$root"
}


# =========================================================================
# Escape / CRLF / pipe-less table defect-class tests
# =========================================================================

@test "backslash-pipe name round-trips through table write and read" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

| Component | Source | Notes |
|-----------|--------|-------|
| header | custom | top |

## 9. Next Section
UX

  # Snapshot with Nav\|Bar (a component name containing backslash then pipe)
  local snapshot="$root/snapshot.json"
  jq -n '{"components":["header","Nav\\|Bar"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # The doc must contain the escaped form: Nav\\\|Bar
  # (backslash doubled to \\, then pipe escaped to \|)
  grep -qF 'Nav\\\|Bar' "$doc_dir/ux-design.md" || \
    fail "expected escaped form Nav\\\|Bar in doc, got: $(grep 'Nav' "$doc_dir/ux-design.md")"

  # Column count must be unchanged (3 columns = 4 pipes on the row)
  local row
  row="$(grep 'Nav' "$doc_dir/ux-design.md")"
  # Count only unescaped pipes: remove \| sequences, then count |
  local cleaned
  cleaned="$(printf '%s' "$row" | sed 's/\\|//g')"
  local pipe_count
  pipe_count="$(printf '%s' "$cleaned" | tr -cd '|' | wc -c | tr -d ' ')"
  [ "$pipe_count" -eq 4 ] || \
    fail "expected 4 unescaped pipes (3 columns), got $pipe_count"

  # Second sync: Nav\|Bar must be read back correctly and not re-added
  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "second sync failed: $output"
  [[ "$output" == *"up to date"* ]] || \
    fail "second sync should report up to date, got: $output"

  # Exactly one Nav row in the doc
  local nav_count
  nav_count="$(grep -cF 'Nav' "$doc_dir/ux-design.md")"
  [ "$nav_count" -eq 1 ] || \
    fail "expected exactly 1 Nav row after two syncs, got $nav_count"

  rm -rf "$root"
}

@test "literal pipe name round-trips through table" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

| Component | Source | Notes |
|-----------|--------|-------|
| header | custom | top |

## 9. Next Section
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["header","A|B"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # The pipe must be escaped in the doc
  grep -qF 'A\|B' "$doc_dir/ux-design.md" || \
    fail "pipe not escaped in doc, got: $(grep 'A' "$doc_dir/ux-design.md" | head -1)"

  # Second sync: A|B must be read back and not re-added
  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "second sync failed: $output"
  [[ "$output" == *"up to date"* ]] || \
    fail "second sync should report up to date (no re-add), got: $output"

  rm -rf "$root"
}

@test "lone backslash name round-trips through table" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

| Component | Source | Notes |
|-----------|--------|-------|
| header | custom | top |

## 9. Next Section
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["header","nav\\bar"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # The backslash must be doubled in the doc: nav\\bar
  grep -qF 'nav\\bar' "$doc_dir/ux-design.md" || \
    fail "backslash not doubled in doc, got: $(grep 'nav' "$doc_dir/ux-design.md" | head -1)"

  # Second sync: nav\bar must read back correctly and not re-add
  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "second sync failed: $output"
  [[ "$output" == *"up to date"* ]] || \
    fail "second sync should report up to date (no re-add), got: $output"

  rm -rf "$root"
}

@test "escaped name synced twice produces exactly one row" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

| Component | Source | Notes |
|-----------|--------|-------|
| header | custom | top |

## 9. Next Section
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["header","Nav\\|Bar"]}' > "$snapshot"

  # First sync: adds the row
  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "first sync failed: $output"

  # Second sync
  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "second sync failed: $output"

  # Third sync
  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "third sync failed: $output"

  # Count rows containing Nav (escaped form) — must be exactly 1
  local nav_count
  nav_count="$(grep -cF 'Nav' "$doc_dir/ux-design.md")"
  [ "$nav_count" -eq 1 ] || \
    fail "expected exactly 1 Nav row after three syncs, got $nav_count"

  rm -rf "$root"
}

@test "legacy broken row yields correct extracted name and next sync adds fixed row" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  # Seed a doc with the OLD broken escaping: | Nav\\|Bar |
  # Under the AC4 read rule, the | after \\ is an unescaped cell boundary
  # (two backslashes = even count), so the first cell is Nav\\ -> unescape -> Nav\
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

| Component | Source | Notes |
|-----------|--------|-------|
| Nav\\|Bar | custom | legacy |

## 9. Next Section
UX

  # Sync with an empty snapshot to trigger the absence report.
  # The report will say what name was extracted from the legacy row.
  local snapshot="$root/snapshot.json"
  printf '{"components":[]}\n' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # The extracted name from | Nav\\|Bar | under AC4 rules must be exactly Nav\
  # (Nav\\ unescaped = Nav\). Assert via the absence report.
  local absent_line
  absent_line="$(printf '%s\n' "$output" | grep 'absent' || true)"
  [ -n "$absent_line" ] || \
    fail "no absence report for the legacy row"

  # The reported name must be Nav\ (with a single trailing backslash).
  # The absence report format is: component "NAME" is in ux-design.md ...
  # We grep for the exact quoted name.
  printf '%s\n' "$absent_line" | grep -qF '"Nav\"' || \
    fail "expected extracted name Nav\\ from legacy row, got: $absent_line"

  # Now sync with the CORRECT name Nav\|Bar — it should add a new correctly
  # escaped row (Nav\\\|Bar) since the legacy row reads as Nav\, not Nav\|Bar
  local snapshot2="$root/snapshot2.json"
  jq -n '{"components":["Nav\\|Bar"]}' > "$snapshot2"

  run "$SYNC_SCRIPT" "$snapshot2" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "second sync failed: $output"

  # Doc should now have both the legacy row and the new correctly escaped row
  grep -qF 'Nav\\\|Bar' "$doc_dir/ux-design.md" || \
    fail "correctly escaped Nav\\\|Bar row not added"

  # The legacy row should still be in the doc (never silently deleted)
  grep -qF 'Nav\\|Bar' "$doc_dir/ux-design.md" || \
    fail "legacy row was silently deleted"

  rm -rf "$root"
}

@test "CRLF document table insert ends with CR LF" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  # Create a CRLF-terminated document (sed adds \r before every \n)
  cat > "$doc_dir/ux-design.md.tmp" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

| Component | Source | Notes |
|-----------|--------|-------|
| header | custom | top |

## 9. Next Section
UX
  sed "s/\$/$( printf '\r' )/" "$doc_dir/ux-design.md.tmp" > "$doc_dir/ux-design.md"
  rm -f "$doc_dir/ux-design.md.tmp"

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["header","NewComponent"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # The inserted row must end with \r\n (CRLF), verified with od
  local inserted_line
  inserted_line="$(grep 'NewComponent' "$doc_dir/ux-design.md")"
  [ -n "$inserted_line" ] || fail "NewComponent row not found"

  # Check that the line contains \r (0d) before \n
  local line_bytes
  line_bytes="$(grep 'NewComponent' "$doc_dir/ux-design.md" | od -c)"
  printf '%s\n' "$line_bytes" | grep -q '\\r' || \
    fail "inserted table row does not end with CR LF: $line_bytes"

  rm -rf "$root"
}

@test "CRLF document bullet insert ends with CR LF" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  # Create a CRLF bullet-mode document (no table)
  cat > "$doc_dir/ux-design.md.tmp" <<'UX'
---
template: ux-design
---

# UX Design

## Component Inventory

- header

## Design Record Reference
UX
  sed "s/\$/$( printf '\r' )/" "$doc_dir/ux-design.md.tmp" > "$doc_dir/ux-design.md"
  rm -f "$doc_dir/ux-design.md.tmp"

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["header","Card"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # The inserted bullet must end with \r\n
  local bullet_line
  bullet_line="$(grep 'Card' "$doc_dir/ux-design.md")"
  [ -n "$bullet_line" ] || fail "Card bullet not found"

  local bullet_bytes
  bullet_bytes="$(grep 'Card' "$doc_dir/ux-design.md" | od -c | head -1)"
  printf '%s\n' "$bullet_bytes" | grep -q '\\r' || \
    fail "inserted bullet does not end with CR LF: $bullet_bytes"

  rm -rf "$root"
}

@test "CRLF bullet read strips trailing carriage return" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  # CRLF bullet-mode doc with ButtonPrimary
  cat > "$doc_dir/ux-design.md.tmp" <<'UX'
---
template: ux-design
---

# UX Design

## Component Inventory

- ButtonPrimary

## Design Record Reference
UX
  sed "s/\$/$( printf '\r' )/" "$doc_dir/ux-design.md.tmp" > "$doc_dir/ux-design.md"
  rm -f "$doc_dir/ux-design.md.tmp"

  # Snapshot includes ButtonPrimary — if the reader strips \r, this is
  # already present and no re-add occurs
  local snapshot="$root/snapshot.json"
  jq -n '{"components":["ButtonPrimary"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Must report "up to date" (no re-add), meaning ButtonPrimary was read
  # without a trailing \r
  [[ "$output" == *"up to date"* ]] || \
    fail "ButtonPrimary was re-added (reader did not strip CR): $output"

  rm -rf "$root"
}

@test "pipe-less table detected with correct column count" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  # Pipe-less table: no leading or trailing pipes on separator or data rows
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

Component | Source | Notes
----------|--------|------
Button | primary | yes
Toggle | custom | no

## 9. Next Section
UX

  # Snapshot includes Button (already in doc) and Card (new)
  local snapshot="$root/snapshot.json"
  jq -n '{"components":["Button","Card"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Button must NOT be re-added (it was read from the pipe-less table).
  # The output must say "up to date" OR report only Card, never Button.
  local added_button
  added_button="$(printf '%s\n' "$output" | grep 'added.*"Button"' || true)"
  [ -z "$added_button" ] || \
    fail "Button was re-added (pipe-less table not detected): $output"

  # Card must be added
  local added_card
  added_card="$(printf '%s\n' "$output" | grep 'added.*"Card"' || true)"
  [ -n "$added_card" ] || \
    fail "Card was not added: $output"

  # The inserted Card row must be in table form (pipe-separated), not bullet
  local card_row
  card_row="$(grep 'Card' "$doc_dir/ux-design.md")"
  [ -n "$card_row" ] || fail "Card row not found in doc"

  # Must NOT be a bullet (must not start with "- ")
  [[ "$card_row" != '- '* ]] || \
    fail "Card was inserted as a bullet in a pipe-less table: $card_row"

  # Must contain at least one pipe (it's a pipe-less table row)
  [[ "$card_row" == *'|'* ]] || \
    fail "Card row has no pipes (not a table row): $card_row"

  # Must NOT start with | (matching the pipe-less form)
  [[ "$card_row" != '|'* ]] || \
    fail "Card row has leading pipe in a pipe-less table: $card_row"

  rm -rf "$root"
}

@test "pipe-less table new row inserted without outer pipes" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  # 3-column pipe-less table
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

Component | Source | Notes
----------|--------|------
Button | primary | yes

## 9. Next Section
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["Button","Card"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  local card_row
  card_row="$(grep 'Card' "$doc_dir/ux-design.md")"
  [ -n "$card_row" ] || fail "Card row not found"

  # For a 3-column pipe-less table, the new row must be exactly:
  # Card | |  (no outer pipes, 2 inner pipes for 3 columns)
  # Verify: no leading pipe, has exactly 2 pipes total (for 3 columns)
  [[ "$card_row" != '|'* ]] || \
    fail "Card row starts with pipe in pipe-less table: $card_row"

  local pipe_count
  pipe_count="$(printf '%s' "$card_row" | tr -cd '|' | wc -c | tr -d ' ')"
  [ "$pipe_count" -eq 2 ] || \
    fail "expected 2 pipes (3 columns, pipe-less form), got $pipe_count: $card_row"

  # Card must land immediately after the last existing data row (Button)
  local button_ln card_ln
  button_ln="$(grep -nF 'Button' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  card_ln="$(grep -nF 'Card' "$doc_dir/ux-design.md" | head -1 | cut -d: -f1)"
  [ "$card_ln" -eq "$((button_ln + 1))" ] || \
    fail "Card row not directly after Button (expected line $((button_ln + 1)), got $card_ln)"

  # No existing component duplicated: Button must appear exactly once
  local button_count
  button_count="$(grep -cF 'Button' "$doc_dir/ux-design.md")"
  [ "$button_count" -eq 1 ] || \
    fail "Button duplicated: appears $button_count times"

  rm -rf "$root"
}

@test "bullet line containing pipe is not treated as pipe-less row" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  # Bullet-mode doc where a bullet contains a pipe character
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Component Inventory

- A|B
- header

## Design Record Reference
UX

  # Snapshot includes A|B — if bullets are correctly read, no re-add
  local snapshot="$root/snapshot.json"
  jq -n '{"components":["A|B","header"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  [[ "$output" == *"up to date"* ]] || \
    fail "A|B was re-added (bullet with pipe treated as table row?): $output"

  rm -rf "$root"
}

@test "half-piped separator detected with correct column count" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  # Leading-pipe-only table (no trailing pipe)
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

| Component | Source | Notes
|-----------|--------|------
| Button | primary | yes

## 9. Next Section
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["Button","Card"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Card must be added
  [[ "$output" == *"Card"* ]] || \
    fail "Card was not added: $output"

  # Verify Card row has correct column count (3 = same as table)
  local card_row
  card_row="$(grep 'Card' "$doc_dir/ux-design.md")"
  [ -n "$card_row" ] || fail "Card row not found"

  # For a 3-column table with leading-pipe-only, there are 3 pipes
  # (leading + 2 internal, no trailing)
  local pipe_count
  pipe_count="$(printf '%s' "$card_row" | tr -cd '|' | wc -c | tr -d ' ')"
  [ "$pipe_count" -eq 3 ] || \
    fail "expected 3 pipes for 3-col half-piped table, got $pipe_count: $card_row"

  rm -rf "$root"
}

@test "bullet mode writes raw name with backslash" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  local root
  root="$(mktemp -d)"
  local doc_dir="$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$doc_dir"
  # Bullet-mode doc (no table)
  cat > "$doc_dir/ux-design.md" <<'UX'
---
template: ux-design
---

# UX Design

## Component Inventory

- header

## Design Record Reference
UX

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["header","nav\\bar"]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Bullet mode must write the raw name, NOT the escaped form.
  # The bullet must be exactly "- nav\bar" (single backslash).
  local bullet_line
  bullet_line="$(grep 'nav' "$doc_dir/ux-design.md")"
  [ "$bullet_line" = '- nav\bar' ] || \
    fail "expected bullet '- nav\\bar', got: $bullet_line"

  # Second sync: nav\bar must not be re-added
  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
  [ "$status" -eq 0 ] || fail "second sync failed: $output"
  [[ "$output" == *"up to date"* ]] || \
    fail "nav\\bar was re-added in bullet mode: $output"

  rm -rf "$root"
}

@test "component extraction scales without per-row subprocesses" {
  [ -x "$SYNC_SCRIPT" ] || fail "script missing: $SYNC_SCRIPT"

  # Deterministic subprocess counter: put counting shims for awk, sed,
  # grep, cut, tr on PATH. Each shim increments a file counter and then
  # calls the real tool. Comparing the counts on 50 vs 500 rows detects
  # per-row subprocess spawning without timing or CI-load sensitivity.

  local shim_dir
  shim_dir="$(mktemp -d)"

  # Locate the real tools BEFORE we prepend the shim dir to PATH.
  local real_awk real_sed real_grep real_cut real_tr
  real_awk="$(command -v awk)"
  real_sed="$(command -v sed)"
  real_grep="$(command -v grep)"
  real_cut="$(command -v cut)"
  real_tr="$(command -v tr)"

  # Create counting shims.
  for tool in awk sed grep cut tr; do
    eval "local real_path=\$real_${tool}"
    cat > "$shim_dir/$tool" <<SHIM
#!/usr/bin/env bash
# counting shim for $tool
_cnt_file="\${_SHIM_COUNT_DIR}/${tool}.count"
if [ -n "\${_SHIM_COUNT_DIR:-}" ] && [ -d "\${_SHIM_COUNT_DIR:-}" ]; then
  printf 'x' >> "\$_cnt_file"
fi
exec "$real_path" "\$@"
SHIM
    chmod +x "$shim_dir/$tool"
  done

  # Verify the shim actually intercepts: call awk through the shimmed
  # PATH and check it counts.
  local verify_dir
  verify_dir="$(mktemp -d)"
  _SHIM_COUNT_DIR="$verify_dir" PATH="$shim_dir:$PATH" awk 'BEGIN{print "ok"}' >/dev/null
  local verify_count
  verify_count="$(wc -c < "$verify_dir/awk.count" | tr -d ' ')"
  [ "$verify_count" -gt 0 ] || \
    fail "shim verification failed: awk shim counted 0 calls"
  rm -rf "$verify_dir"

  # Helper: generate a table doc with N component rows
  _gen_table_doc() {
    local out="$1" count="$2"
    local dir
    dir="$(dirname "$out")"
    mkdir -p "$dir"
    {
      cat <<'HEADER'
---
template: ux-design
---

# UX Design

## 8. Components & Design System

| Component | Source | Notes |
|-----------|--------|-------|
HEADER
      local i
      for i in $(seq 1 "$count"); do
        printf '| comp-%03d | auto | row |\n' "$i"
      done
      printf '\n## 9. Next Section\n'
    } > "$out"
  }

  # Generate 50-row and 500-row table docs
  local root50 root500
  root50="$(mktemp -d)"
  root500="$(mktemp -d)"
  local doc_dir_50="$root50/.gaia/artifacts/planning-artifacts"
  local doc_dir_500="$root500/.gaia/artifacts/planning-artifacts"
  _gen_table_doc "$doc_dir_50/ux-design.md" 50
  _gen_table_doc "$doc_dir_500/ux-design.md" 500

  # Build snapshots with all existing components plus one new one
  _gen_snap() {
    local out="$1" count="$2"
    {
      printf '{"components":['
      local i
      for i in $(seq 1 "$count"); do
        printf '"comp-%03d"' "$i"
        [ "$i" -lt "$count" ] && printf ','
      done
      printf ',"newcomp"]}'
    } > "$out"
  }
  _gen_snap "$root50/snapshot.json" 50
  _gen_snap "$root500/snapshot.json" 500

  # Run 50-row sync with counting shims
  local count_dir_50
  count_dir_50="$(mktemp -d)"
  _SHIM_COUNT_DIR="$count_dir_50" PATH="$shim_dir:$PATH" \
    run "$SYNC_SCRIPT" "$root50/snapshot.json" "$doc_dir_50/ux-design.md"
  [ "$status" -eq 0 ] || fail "50-row sync failed: $output"

  # Run 500-row sync with counting shims
  local count_dir_500
  count_dir_500="$(mktemp -d)"
  _SHIM_COUNT_DIR="$count_dir_500" PATH="$shim_dir:$PATH" \
    run "$SYNC_SCRIPT" "$root500/snapshot.json" "$doc_dir_500/ux-design.md"
  [ "$status" -eq 0 ] || fail "500-row sync failed: $output"

  # Count total tool invocations for each run.
  # Each shim appends one 'x' per call; wc -c counts bytes = calls.
  local total_50=0 total_500=0
  for tool in awk sed grep cut tr; do
    local c50=0 c500=0
    [ -f "$count_dir_50/${tool}.count" ] && \
      c50="$(wc -c < "$count_dir_50/${tool}.count" | tr -d ' ')"
    [ -f "$count_dir_500/${tool}.count" ] && \
      c500="$(wc -c < "$count_dir_500/${tool}.count" | tr -d ' ')"
    total_50=$((total_50 + c50))
    total_500=$((total_500 + c500))
  done

  # Non-vacuity: the 50-row run must have counted more than 0 calls
  [ "$total_50" -gt 0 ] || \
    fail "shim counted 0 tool calls on 50-row run — shim is not intercepting"

  # The 500-row count must not exceed the 50-row count plus a small
  # constant (5). If extraction spawns a subprocess per row, the
  # 500-row run will have ~450 more calls than the 50-row run.
  local limit=$((total_50 + 5))
  [ "$total_500" -le "$limit" ] || \
    fail "500-row run had $total_500 tool calls vs $total_50 for 50-row (limit $limit) — per-row subprocess detected"

  rm -rf "$root50" "$root500" "$shim_dir" "$count_dir_50" "$count_dir_500"
}
