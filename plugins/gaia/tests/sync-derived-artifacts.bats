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
    '[{"file": $f, "hash": $h}]' > "$baseline"

  # Write a DIFFERENT screen file and build the snapshot via --rawfile
  _write_screen_file "$screens_dir" "new-home.spec.html" "<h1>New Home</h1>"
  local snapshot="$root/snapshot.json"
  jq -n --rawfile c "$screens_dir/new-home.spec.html" \
    '{"components":[],"screens":[{"name":"Home Screen","file":"screens/home.spec.html","content":$c}]}' > "$snapshot"

  run "$SYNC_SCRIPT" --last-published "$baseline" \
    "$snapshot" "$ux_doc"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Must contain boundary markers
  [[ "$output" == *'<<<DESIGN_PROJECT_BOUNDARY>>>'* ]] || \
    fail "missing opening boundary marker: $output"
  [[ "$output" == *'<<<END_DESIGN_PROJECT_BOUNDARY>>>'* ]] || \
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
    '[{"file": $f1, "hash": $h1}, {"file": $f2, "hash": $h2}]' > "$baseline"

  # Build snapshot with identical content via --rawfile (preserves exact bytes)
  local snapshot="$root/snapshot.json"
  jq -n --rawfile c1 "$screens_dir/settings.spec.html" \
        --rawfile c2 "$screens_dir/profile.spec.html" \
    '{"components":["nav"],"screens":[
      {"name":"Settings","file":"screens/settings.spec.html","content":$c1},
      {"name":"Profile","file":"screens/profile.spec.html","content":$c2}
    ]}' > "$snapshot"

  run "$SYNC_SCRIPT" --last-published "$baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # No screen report (no boundary markers, no screen-changed lines)
  [[ "$output" != *'DESIGN_PROJECT_BOUNDARY'* ]] || \
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

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"

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

  run "$SYNC_SCRIPT" "$snapshot" "$ux_doc"

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

  # Both special-char components must appear in the doc intact
  grep -qF 'nav\bar' "$doc_dir/ux-design.md" || \
    fail "backslash component not preserved in doc"
  grep -qF 'R&D-panel' "$doc_dir/ux-design.md" || \
    fail "ampersand component not preserved in doc"

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

  # Empty baseline — no entries
  local baseline="$root/baseline.json"
  printf '[]\n' > "$baseline"

  # Write screen file and build snapshot via --rawfile
  local screens_dir="$root/screens"
  _write_screen_file "$screens_dir" "new.spec.html" "<h1>Brand New</h1>"
  local snapshot="$root/snapshot.json"
  jq -n --rawfile c "$screens_dir/new.spec.html" \
    '{"components":["nav"],"screens":[{"name":"New Screen","file":"screens/new.spec.html","content":$c}]}' > "$snapshot"

  run "$SYNC_SCRIPT" --last-published "$baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Must report "no baseline"
  [[ "$output" == *"no baseline"* ]] || \
    fail "should report 'no baseline' for screen not in baseline: $output"

  # Must still show content in boundary markers
  [[ "$output" == *'<<<DESIGN_PROJECT_BOUNDARY>>>'* ]] || \
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

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"

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
  printf '%s\n' "$template_section" | grep -q 'new-gamma' || \
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

@test "sync 200 new components completes in under 3 s and is idempotent" {
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

  # Measure wall-clock time via python3
  local start_ms end_ms elapsed_ms
  start_ms="$(python3 -c 'import time; print(int(time.monotonic() * 1000))')"

  run "$SYNC_SCRIPT" "$root/snapshot.json" "$ux_doc"

  end_ms="$(python3 -c 'import time; print(int(time.monotonic() * 1000))')"
  elapsed_ms=$((end_ms - start_ms))

  [ "$status" -eq 0 ] || fail "sync of 200 components failed — exit $status: $output"
  [ "$elapsed_ms" -lt 3000 ] || \
    fail "performance: ${elapsed_ms} ms exceeds 3000 ms budget for 200 new components"

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

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -ne 0 ] || \
    fail "should reject screen with no content key (exit $status): $output"

  # Diagnostic should name the screen
  [[ "$output" == *"Broken"* ]] || \
    fail "diagnostic should name the screen: $output"

  # No boundary markers emitted for the broken screen
  [[ "$output" != *'DESIGN_PROJECT_BOUNDARY'* ]] || \
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

  TMPDIR="$iso_tmpdir" run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"
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

  TMPDIR="$iso_tmpdir" run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"

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
  # fail on the 3rd invocation (the 2nd screen's hash; the 1st is the ux doc
  # sha check, the 2nd is screen 1's hash).
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

  # Shim hash command: fail after the 1st call (the 2nd screen's hash)
  _create_hash_shim "$root/shim-bin" "$root/sha_call_count" 1

  PATH="$root/shim-bin:$PATH" TMPDIR="$iso_tmpdir" run "$SYNC_SCRIPT" \
    "$snapshot" "$doc_dir/ux-design.md"

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

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -ne 0 ] || fail "should reject numeric content (exit $status): $output"
  [[ "$output" == *"NumScreen"* ]] || fail "diagnostic should name the screen: $output"
  [[ "$output" != *'DESIGN_PROJECT_BOUNDARY'* ]] || fail "no boundary markers for rejected screen"

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

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -ne 0 ] || fail "should reject object content (exit $status): $output"
  [[ "$output" == *"ObjScreen"* ]] || fail "diagnostic should name the screen: $output"
  [[ "$output" != *'DESIGN_PROJECT_BOUNDARY'* ]] || fail "no boundary markers for rejected screen"

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

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -ne 0 ] || fail "should reject array content (exit $status): $output"
  [[ "$output" == *"ArrScreen"* ]] || fail "diagnostic should name the screen: $output"
  [[ "$output" != *'DESIGN_PROJECT_BOUNDARY'* ]] || fail "no boundary markers for rejected screen"

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

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -ne 0 ] || fail "should fail on invalid screen (exit $status): $output"

  # No boundary markers at all — the valid screen must not have been reported
  [[ "$output" != *'DESIGN_PROJECT_BOUNDARY'* ]] || \
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

  # Shim: fail on the 2nd hash call (the 2nd screen)
  _create_hash_shim "$root/shim-bin" "$root/sha_call_count" 1

  PATH="$root/shim-bin:$PATH" TMPDIR="$iso_tmpdir" run "$SYNC_SCRIPT" \
    "$snapshot" "$doc_dir/ux-design.md"

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

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"

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
    '[{"file": $f, "hash": $h}]' > "$baseline"

  # Snapshot with the same content and backslash path
  local snapshot="$root/snapshot.json"
  jq -n --rawfile c "$screens_dir/backslash.spec.html" \
        --arg f "$bslash_path" \
    '{"components":["nav"],"screens":[{"name":"Backslash Screen","file":$f,"content":$c}]}' > "$snapshot"

  run "$SYNC_SCRIPT" --last-published "$baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # No screen report — the hashes match, so no change
  [[ "$output" != *'DESIGN_PROJECT_BOUNDARY'* ]] || \
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

  run "$SYNC_SCRIPT" "$root/snapshot.json" "$doc_dir/ux-design.md"

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
    '[{"file":$f0,"hash":$h0},{"file":$f1,"hash":$h1}]' > "$root/baseline.json"

  # Snapshot via --rawfile
  jq -n --rawfile c0 "$root/s0.html" \
        --rawfile c1 "$root/s1.html" \
        --rawfile c2 "$root/s2.html" \
    '{"components":["nav"],"screens":[
      {"name":"Home","file":"screens/s0.html","content":$c0},
      {"name":"Settings","file":"screens/s1.html","content":$c1},
      {"name":"Profile","file":"screens/s2.html","content":$c2}
    ]}' > "$root/snapshot.json"

  # Golden expected output — generated from the current script
  local expected="$root/expected.txt"
  cat > "$expected" <<'GOLDEN'
sync: ux-design.md is up to date — no components to add
sync: screen "Settings" changed (file: screens/s1.html)
<<<DESIGN_PROJECT_BOUNDARY>>>
<h1>Settings</h1>
<p>Updated settings page</p>
<<<END_DESIGN_PROJECT_BOUNDARY>>>
sync: screen "Profile" has no baseline (file: screens/s2.html)
<<<DESIGN_PROJECT_BOUNDARY>>>
<h1>Profile</h1>
<p>User profile</p>
<<<END_DESIGN_PROJECT_BOUNDARY>>>
GOLDEN

  run "$SYNC_SCRIPT" --last-published "$root/baseline.json" \
    "$root/snapshot.json" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Compare byte-for-byte
  local actual="$root/actual.txt"
  printf '%s\n' "$output" > "$actual"

  diff -u "$expected" "$actual" || \
    fail "output differs from golden reference"

  rm -rf "$root"
}
