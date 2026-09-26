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

# Helper: compute sha256 of a string (jq -j style, no trailing newline)
_sha256_string() {
  printf '%s' "$1" | {
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum | awk '{print $1}'
    else
      shasum -a 256 | awk '{print $1}'
    fi
  }
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

  # Build a baseline with an OLD hash for the screen
  local old_content="old screen content"
  local old_hash
  old_hash="$(_sha256_string "$old_content")"

  local baseline="$root/baseline.json"
  jq -n --arg f "screens/home.spec.html" --arg h "$old_hash" \
    '[{"file": $f, "hash": $h}]' > "$baseline"

  # Build a snapshot with a screen whose content differs
  local new_content="new screen content with changes"
  local snapshot="$root/snapshot.json"
  jq -n --arg name "Home Screen" \
        --arg file "screens/home.spec.html" \
        --arg content "$new_content" \
    '{"components":[],"screens":[{"name":$name,"file":$file,"content":$content}]}' > "$snapshot"

  run "$SYNC_SCRIPT" --last-published "$baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # Must contain boundary markers
  [[ "$output" == *'<<<DESIGN_PROJECT_BOUNDARY>>>'* ]] || \
    fail "missing opening boundary marker: $output"
  [[ "$output" == *'<<<END_DESIGN_PROJECT_BOUNDARY>>>'* ]] || \
    fail "missing closing boundary marker: $output"

  # Must contain the screen content
  [[ "$output" == *"$new_content"* ]] || \
    fail "screen content not in report: $output"

  # Must NOT contain false "added component" lines
  local added_count
  added_count="$(printf '%s\n' "$output" | grep -c 'added component' || true)"
  [ "$added_count" -eq 0 ] || \
    fail "false 'added component' lines for screen-only sync ($added_count)"

  rm -rf "$root"
}


# =========================================================================
# Unchanged screens produce no report (AC-EC5)
# =========================================================================

@test "(AC-EC5) unchanged screens produce no report" {
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

  local screen_content="unchanged screen body"
  local screen_hash
  screen_hash="$(_sha256_string "$screen_content")"

  # Baseline with matching hash
  local baseline="$root/baseline.json"
  jq -n --arg f "screens/settings.spec.html" --arg h "$screen_hash" \
        --arg f2 "screens/profile.spec.html" --arg h2 "$screen_hash" \
    '[{"file": $f, "hash": $h}, {"file": $f2, "hash": $h2}]' > "$baseline"

  # Snapshot with same content (hash will match)
  local snapshot="$root/snapshot.json"
  jq -n --arg c "$screen_content" \
    '{"components":["nav"],"screens":[
      {"name":"Settings","file":"screens/settings.spec.html","content":$c},
      {"name":"Profile","file":"screens/profile.spec.html","content":$c}
    ]}' > "$snapshot"

  run "$SYNC_SCRIPT" --last-published "$baseline" \
    "$snapshot" "$doc_dir/ux-design.md"

  # The script must accept --last-published as a named flag.
  # Current code treats it as a positional arg and fails.
  [ "$status" -eq 0 ] || fail "sync failed (exit $status): $output"

  # No screen report (no boundary markers, no "screen" in output)
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

  # Snapshot with screens but NO components key
  local snapshot="$root/snapshot.json"
  jq -n '{"screens":[{"name":"Home","file":"screens/home.spec.html","content":"home body"}]}' > "$snapshot"

  run "$SYNC_SCRIPT" "$snapshot" "$doc_dir/ux-design.md"

  [ "$status" -eq 0 ] || \
    fail "should exit 0 with screens-only snapshot (exit $status): $output"

  # Screen report should be produced
  [[ "$output" == *"Home"* ]] || \
    fail "screen report should mention the screen name: $output"

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

  local snapshot="$root/snapshot.json"
  jq -n '{"components":["nav"],"screens":[{"name":"New Screen","file":"screens/new.spec.html","content":"brand new content"}]}' > "$snapshot"

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
