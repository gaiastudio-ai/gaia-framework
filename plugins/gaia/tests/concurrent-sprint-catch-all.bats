#!/usr/bin/env bats
# concurrent-sprint-catch-all.bats — Tests for the catch-all epic flag parser.
# Component: concurrent-sprint

# shellcheck disable=SC2154  # $BATS_TEST_TMPDIR is set by bats

setup() {
  # Locate the plugin root relative to this test file.
  PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="${PLUGIN_ROOT}/scripts/lib/catch-all-flag.sh"

  # Create a temp directory for test fixtures.
  TEST_DIR="${BATS_TEST_TMPDIR}/catch-all-$$"
  mkdir -p "$TEST_DIR"
  SHARDS_DIR="${TEST_DIR}/epics"
  mkdir -p "$SHARDS_DIR"
  EPICS_FILE="${TEST_DIR}/epics-and-stories.md"
}

teardown() {
  rm -rf "${TEST_DIR:-/nonexistent}"
}

# ---------------------------------------------------------------------------
# Helper: write an epics file with optional catch_all markers.
# ---------------------------------------------------------------------------
_write_epics_file() {
  cat > "$EPICS_FILE"
}

_write_shard() {
  local filename="$1"
  shift
  cat > "${SHARDS_DIR}/${filename}"
}

# ===========================================================================
# AC1: Inline marker recognized via standalone line below heading
# ===========================================================================

@test "form (a) em-dash: inline marker recognized" {
  _write_epics_file <<'EOF'
## E900 — Bugs and Enhancements
<!-- catch_all: true -->

### Story E900-S1: Fix login
EOF
  run bash "$SCRIPT" --epics-file "$EPICS_FILE" --shards-dir "$SHARDS_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "E900" ]
}

@test "form (b) natural-language: inline marker recognized" {
  _write_epics_file <<'EOF'
## Epic 900: Bugs and Enhancements
<!-- catch_all: true -->

### Story E900-S1: Fix login
EOF
  run bash "$SCRIPT" --epics-file "$EPICS_FILE" --shards-dir "$SHARDS_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "E900" ]
}

@test "form (c) ASCII double-hyphen: inline marker recognized" {
  _write_epics_file <<'EOF'
## Epic E900 -- Bugs and Enhancements
<!-- catch_all: true -->

### Story E900-S1: Fix login
EOF
  run bash "$SCRIPT" --epics-file "$EPICS_FILE" --shards-dir "$SHARDS_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "E900" ]
}

@test "form (d) em-dash with Epic prefix: inline marker recognized" {
  printf '%s\n' "## Epic E900 — Bugs and Enhancements" '<!-- catch_all: true -->' '' '### Story E900-S1: Fix login' > "$EPICS_FILE"
  run bash "$SCRIPT" --epics-file "$EPICS_FILE" --shards-dir "$SHARDS_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "E900" ]
}

@test "shard frontmatter recognized" {
  _write_epics_file <<'EOF'
## E900 — Bugs and Enhancements

### Story E900-S1: Fix login
EOF
  _write_shard "01-e900-bugs-and-enhancements.md" <<'EOF'
---
catch_all: true
---
# Bugs and Enhancements
EOF
  run bash "$SCRIPT" --epics-file "$EPICS_FILE" --shards-dir "$SHARDS_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "E900" ]
}

# ===========================================================================
# AC2: No name-based inference
# ===========================================================================

@test "no name-based inference: bugs/enhancements epic without marker is NOT catch-all" {
  _write_epics_file <<'EOF'
## E900 — Bugs and Enhancements

### Story E900-S1: Fix login
EOF
  run bash "$SCRIPT" --epics-file "$EPICS_FILE" --shards-dir "$SHARDS_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "source grep: no inference logic outside audit advisory function" {
  # The only title/name matching in catch-all-flag.sh that inspects epic
  # title content is inside _catch_all_audit_advisory which only warns,
  # never sets the flag. Outside that function, no code should use
  # grep -qi or case/if on those title pattern words to decide the flag.

  local advisory_start advisory_end
  advisory_start="$(grep -n '^_catch_all_audit_advisory()' "$SCRIPT" | head -1 | cut -d: -f1)"
  [ -n "$advisory_start" ]
  advisory_end="$(tail -n "+${advisory_start}" "$SCRIPT" | grep -n '^}' | head -1 | cut -d: -f1)"
  advisory_end=$((advisory_start + advisory_end - 1))

  # Outside the advisory function: look for grep -qi calls that match
  # the title-pattern words — that is the only way the script could infer
  # the flag from a title.
  local inference_hits
  inference_hits="$(sed -n "1,$((advisory_start - 1))p;$((advisory_end + 1)),\$p" "$SCRIPT" \
    | grep -v '^[[:space:]]*#' \
    | grep 'grep.*-q' \
    | grep -ci 'bug\|enhancement\|maintenance\|backlog\|misc' || true)"
  [ "$inference_hits" -eq 0 ]
}

@test "absent marker means not catch-all" {
  _write_epics_file <<'EOF'
## E900 — Authentication System

### Story E900-S1: Add OAuth
EOF
  run bash "$SCRIPT" --epics-file "$EPICS_FILE" --shards-dir "$SHARDS_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "explicit catch_all: false in shard means not catch-all" {
  _write_epics_file <<'EOF'
## E900 — Bugs and Enhancements

### Story E900-S1: Fix login
EOF
  _write_shard "01-e900-bugs-and-enhancements.md" <<'EOF'
---
catch_all: false
---
# Bugs
EOF
  run bash "$SCRIPT" --epics-file "$EPICS_FILE" --shards-dir "$SHARDS_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ===========================================================================
# AC3: SKILL.md offer assertion
# ===========================================================================

@test "SKILL.md Step 3: create-epics offers catch_all marker for matching epics" {
  local skill_file="${PLUGIN_ROOT}/skills/gaia-create-epics/SKILL.md"
  [ -f "$skill_file" ]
  # The SKILL.md must mention offering the marker.
  grep -q 'offer.*catch_all.*true\|catch_all.*true.*offer' "$skill_file"
}

@test "SKILL.md Step 3: create-epics never auto-sets catch_all" {
  local skill_file="${PLUGIN_ROOT}/skills/gaia-create-epics/SKILL.md"
  [ -f "$skill_file" ]
  # Must state it is never set automatically.
  grep -q 'never set automatically\|never auto-set' "$skill_file"
}

@test "SKILL.md Step 8: accepted offer places marker under heading" {
  local skill_file="${PLUGIN_ROOT}/skills/gaia-create-epics/SKILL.md"
  [ -f "$skill_file" ]
  # The output contract must describe placing the marker below the heading.
  grep -q 'first.*non-blank.*line.*under.*heading\|below.*heading' "$skill_file"
}

# ===========================================================================
# AC4: Shard overrides inline when both disagree
# ===========================================================================

@test "shard explicit false overrides inline true; warning emitted" {
  _write_epics_file <<'EOF'
## E900 — Bugs and Enhancements
<!-- catch_all: true -->

### Story E900-S1: Fix login
EOF
  _write_shard "01-e900-bugs-and-enhancements.md" <<'EOF'
---
catch_all: false
---
# Bugs
EOF
  run bash "$SCRIPT" --epics-file "$EPICS_FILE" --shards-dir "$SHARDS_DIR"
  [ "$status" -eq 0 ]
  # Epic should NOT be in catch-all set (shard wins with false).
  [ -z "$(grep -x 'E900' <<<"$output")" ]
  # Warning should be emitted (captured in output since run merges stderr).
  grep -q 'conflicting catch_all values' <<<"$output"
}

@test "inline true + shard without frontmatter reads as true (silent)" {
  _write_epics_file <<'EOF'
## E900 — Bugs and Enhancements
<!-- catch_all: true -->

### Story E900-S1: Fix login
EOF
  # Shard exists but has no frontmatter.
  _write_shard "01-e900-bugs-and-enhancements.md" <<'EOF'
# Bugs and Enhancements

Some content without frontmatter.
EOF
  run bash "$SCRIPT" --epics-file "$EPICS_FILE" --shards-dir "$SHARDS_DIR"
  [ "$status" -eq 0 ]
  grep -qx 'E900' <<<"$output"
  # No warning should be emitted.
  ! grep -q 'conflicting\|warning' <<<"$output"
}

# ===========================================================================
# AC5: No internal traceability IDs in published files
# ===========================================================================

@test "no internal traceability IDs in catch-all-flag.sh" {
  local found=0
  # Only scan the script this story creates (catch-all-flag.sh).
  # The SKILL.md has pre-existing example story keys (E1-S1) that are not leaks.
  local f="$SCRIPT"
  [ -f "$f" ]
  if grep -Eq 'FR-[0-9]{2,}|NFR-[0-9]{2,}|SR-[0-9]{2,}|ADR-[0-9]{2,}' "$f"; then
    printf 'leaked ID in %s\n' "$f" >&2
    found=1
  fi
  if grep -Eq 'E[0-9]+-S[0-9]+' "$f"; then
    local real_hits
    real_hits="$(grep -Eo 'E[0-9]+-S[0-9]+' "$f" | grep -v 'E{N}-S{N}' | sort -u)"
    if [ -n "$real_hits" ]; then
      printf 'leaked story key in %s: %s\n' "$f" "$real_hits" >&2
      found=1
    fi
  fi
  if grep -Eq 'AF-20[0-9]{2}-[0-9]{2}-[0-9]{2}|AI-20[0-9]{2}' "$f"; then
    printf 'leaked cascade ID in %s\n' "$f" >&2
    found=1
  fi
  [ "$found" -eq 0 ]
}

# ===========================================================================
# AC6: resolve-epic-slug.sh slug unchanged with marker
# ===========================================================================

@test "slug unchanged with marker line: form (a) em-dash" {
  local slug_script="${PLUGIN_ROOT}/scripts/lib/resolve-epic-slug.sh"
  [ -f "$slug_script" ] || skip "resolve-epic-slug.sh not found"

  # Without marker.
  cat > "${TEST_DIR}/no-marker.md" <<'EOF'
## E900 — Bugs and Enhancements

### Story E900-S1: Fix login
EOF
  local slug_without
  slug_without="$(bash "$slug_script" --epic-key E900 --epics-file "${TEST_DIR}/no-marker.md")"

  # With marker.
  cat > "${TEST_DIR}/with-marker.md" <<'EOF'
## E900 — Bugs and Enhancements
<!-- catch_all: true -->

### Story E900-S1: Fix login
EOF
  local slug_with
  slug_with="$(bash "$slug_script" --epic-key E900 --epics-file "${TEST_DIR}/with-marker.md")"

  [ "$slug_without" = "$slug_with" ]
}

@test "slug unchanged with marker line: form (b) natural-language" {
  local slug_script="${PLUGIN_ROOT}/scripts/lib/resolve-epic-slug.sh"
  [ -f "$slug_script" ] || skip "resolve-epic-slug.sh not found"

  cat > "${TEST_DIR}/no-marker.md" <<'EOF'
## Epic 900: Bugs and Enhancements

### Story E900-S1: Fix login
EOF
  local slug_without
  slug_without="$(bash "$slug_script" --epic-key E900 --epics-file "${TEST_DIR}/no-marker.md")"

  cat > "${TEST_DIR}/with-marker.md" <<'EOF'
## Epic 900: Bugs and Enhancements
<!-- catch_all: true -->

### Story E900-S1: Fix login
EOF
  local slug_with
  slug_with="$(bash "$slug_script" --epic-key E900 --epics-file "${TEST_DIR}/with-marker.md")"

  [ "$slug_without" = "$slug_with" ]
}

@test "slug unchanged with marker line: form (c) ASCII double-hyphen" {
  local slug_script="${PLUGIN_ROOT}/scripts/lib/resolve-epic-slug.sh"
  [ -f "$slug_script" ] || skip "resolve-epic-slug.sh not found"

  cat > "${TEST_DIR}/no-marker.md" <<'EOF'
## Epic E900 -- Bugs and Enhancements

### Story E900-S1: Fix login
EOF
  local slug_without
  slug_without="$(bash "$slug_script" --epic-key E900 --epics-file "${TEST_DIR}/no-marker.md")"

  cat > "${TEST_DIR}/with-marker.md" <<'EOF'
## Epic E900 -- Bugs and Enhancements
<!-- catch_all: true -->

### Story E900-S1: Fix login
EOF
  local slug_with
  slug_with="$(bash "$slug_script" --epic-key E900 --epics-file "${TEST_DIR}/with-marker.md")"

  [ "$slug_without" = "$slug_with" ]
}

@test "slug unchanged with marker line: form (d) em-dash Epic prefix" {
  local slug_script="${PLUGIN_ROOT}/scripts/lib/resolve-epic-slug.sh"
  [ -f "$slug_script" ] || skip "resolve-epic-slug.sh not found"

  printf '%s\n' "## Epic E900 — Bugs and Enhancements" '' '### Story E900-S1: Fix login' > "${TEST_DIR}/no-marker.md"
  local slug_without
  slug_without="$(bash "$slug_script" --epic-key E900 --epics-file "${TEST_DIR}/no-marker.md")"

  printf '%s\n' "## Epic E900 — Bugs and Enhancements" '<!-- catch_all: true -->' '' '### Story E900-S1: Fix login' > "${TEST_DIR}/with-marker.md"
  local slug_with
  slug_with="$(bash "$slug_script" --epic-key E900 --epics-file "${TEST_DIR}/with-marker.md")"

  [ "$slug_without" = "$slug_with" ]
}

@test "epic-status-dashboard.sh title unaffected by marker line" {
  local dash_script="${PLUGIN_ROOT}/scripts/epic-status-dashboard.sh"
  [ -f "$dash_script" ] || skip "epic-status-dashboard.sh not found"

  # Build a minimal epics-and-stories.md with a marker.
  local project_dir="${TEST_DIR}/project"
  mkdir -p "${project_dir}/.gaia/artifacts/planning-artifacts"
  mkdir -p "${project_dir}/.gaia/state"
  cat > "${project_dir}/.gaia/artifacts/planning-artifacts/epics-and-stories.md" <<'EOF'
## E900 — Bugs and Enhancements
<!-- catch_all: true -->

### Story E900-S1: Fix login
- Epic: E900
- Status: done
EOF
  # Empty sprint-status.yaml.
  printf 'sprint_id: sprint-test\nstories: {}\n' > "${project_dir}/.gaia/state/sprint-status.yaml"

  run bash -c "PROJECT_PATH='${project_dir}' bash '${dash_script}' --epic E900 2>&1 || true"
  # The title should show "Bugs and Enhancements", NOT include the marker.
  grep -q 'Bugs and Enhancements' <<<"$output"
  ! grep -q 'catch_all' <<<"$output"
}

# ===========================================================================
# AC7: Audit advisory
# ===========================================================================

@test "audit advisory emitted for flagged non-matching title" {
  _write_epics_file <<'EOF'
## E901 — Authentication System
<!-- catch_all: true -->

### Story E901-S1: Add OAuth
EOF
  run bash "$SCRIPT" --epics-file "$EPICS_FILE" --shards-dir "$SHARDS_DIR" --audit
  [ "$status" -eq 0 ]
  grep -qx 'E901' <<<"$output"
  grep -q 'advisory.*Authentication System' <<<"$output"
}

@test "no audit advisory for flagged matching title" {
  _write_epics_file <<'EOF'
## E900 — Bugs and Enhancements
<!-- catch_all: true -->

### Story E900-S1: Fix login
EOF
  run bash "$SCRIPT" --epics-file "$EPICS_FILE" --shards-dir "$SHARDS_DIR" --audit
  [ "$status" -eq 0 ]
  grep -qx 'E900' <<<"$output"
  ! grep -q 'advisory' <<<"$output"
}

@test "normal parsing (no --audit) emits no advisory regardless of title" {
  _write_epics_file <<'EOF'
## E901 — Authentication System
<!-- catch_all: true -->

### Story E901-S1: Add OAuth
EOF
  run bash "$SCRIPT" --epics-file "$EPICS_FILE" --shards-dir "$SHARDS_DIR"
  [ "$status" -eq 0 ]
  grep -qx 'E901' <<<"$output"
  ! grep -q 'advisory' <<<"$output"
}

# ===========================================================================
# Edge cases
# ===========================================================================

@test "catch-all epic with zero stories is returned" {
  _write_epics_file <<'EOF'
## E900 — Bugs and Enhancements
<!-- catch_all: true -->

## E901 — Authentication System

### Story E901-S1: Add OAuth
EOF
  run bash "$SCRIPT" --epics-file "$EPICS_FILE" --shards-dir "$SHARDS_DIR"
  [ "$status" -eq 0 ]
  grep -qx 'E900' <<<"$output"
}

@test "two shard files matching same epic: not flagged + stderr error" {
  _write_epics_file <<'EOF'
## E900 — Bugs and Enhancements
<!-- catch_all: true -->

### Story E900-S1: Fix login
EOF
  _write_shard "01-e900-bugs-and-enhancements.md" <<'EOF'
---
catch_all: true
---
# Bugs
EOF
  _write_shard "02-e900-bugs-duplicate.md" <<'EOF'
---
catch_all: true
---
# Duplicate
EOF
  run bash "$SCRIPT" --epics-file "$EPICS_FILE" --shards-dir "$SHARDS_DIR"
  [ "$status" -eq 0 ]
  # Epic should NOT be in the catch-all set (fail closed on multiple matches).
  ! grep -qx 'E900' <<<"$output"
  # Error message on stderr (captured in output by run).
  grep -q 'multiple shard files' <<<"$output"
}

@test "missing epics file: non-zero exit, empty set" {
  run bash "$SCRIPT" --epics-file "${TEST_DIR}/nonexistent.md" --shards-dir "$SHARDS_DIR"
  [ "$status" -ne 0 ]
  # No epic keys in stdout (only error messages in output).
  ! grep -qx 'E[0-9][0-9]*' <<<"$output"
}

@test "marker ON heading line not recognized" {
  printf '%s\n' '## E900 — Title <!-- catch_all: true -->' '' '### Story E900-S1: Fix' > "$EPICS_FILE"
  run bash "$SCRIPT" --epics-file "$EPICS_FILE" --shards-dir "$SHARDS_DIR"
  [ "$status" -eq 0 ]
  # Epic should NOT be in catch-all set (marker on heading is not recognized).
  [ -z "$(grep -x 'E900' <<<"$output")" ]
}

@test "blank line between heading and marker: still flagged" {
  _write_epics_file <<'EOF'
## E900 — Bugs and Enhancements

<!-- catch_all: true -->

### Story E900-S1: Fix login
EOF
  run bash "$SCRIPT" --epics-file "$EPICS_FILE" --shards-dir "$SHARDS_DIR"
  [ "$status" -eq 0 ]
  grep -qx 'E900' <<<"$output"
}

@test "marker under unrecognized heading form: not flagged + diagnostic" {
  _write_epics_file <<'EOF'
## E900: Bugs and Enhancements
<!-- catch_all: true -->

### Story E900-S1: Fix login
EOF
  run bash "$SCRIPT" --epics-file "$EPICS_FILE" --shards-dir "$SHARDS_DIR"
  [ "$status" -eq 0 ]
  # NOT flagged — unrecognized heading form.
  [ -z "$(grep -x 'E900' <<<"$output")" ]
  # Diagnostic emitted.
  grep -q 'unrecognized heading form' <<<"$output"
}

@test "validate-epic-registry.sh output unchanged with marker line" {
  local registry_script="${PLUGIN_ROOT}/scripts/validate-epic-registry.sh"
  [ -f "$registry_script" ] || skip "validate-epic-registry.sh not found"

  # The marker line sits below the heading and should not affect heading parsing.
  # Build minimal project structure.
  local project_dir="${TEST_DIR}/project-registry"
  mkdir -p "${project_dir}/.gaia/artifacts/planning-artifacts"
  mkdir -p "${project_dir}/.gaia/artifacts/implementation-artifacts/epic-E900-bugs-and-enhancements/E900-S1-fix-login"

  # Without marker.
  cat > "${project_dir}/.gaia/artifacts/planning-artifacts/epics-and-stories.md" <<'EOF'
## Epic 900: Bugs and Enhancements

### Story E900-S1: Fix login
- Epic: E900
EOF
  cat > "${project_dir}/.gaia/artifacts/implementation-artifacts/epic-E900-bugs-and-enhancements/E900-S1-fix-login/story.md" <<'EOF'
---
key: "E900-S1"
epic: "E900"
status: backlog
---
# Fix login
EOF
  local output_without
  output_without="$(PROJECT_PATH="${project_dir}" bash "$registry_script" 2>&1 || true)"

  # With marker.
  cat > "${project_dir}/.gaia/artifacts/planning-artifacts/epics-and-stories.md" <<'EOF'
## Epic 900: Bugs and Enhancements
<!-- catch_all: true -->

### Story E900-S1: Fix login
- Epic: E900
EOF
  local output_with
  output_with="$(PROJECT_PATH="${project_dir}" bash "$registry_script" 2>&1 || true)"

  # The outputs should be identical (marker does not affect heading parsing).
  [ "$output_without" = "$output_with" ]
}

# ===========================================================================
# Sourced API: is_catch_all convenience reader
# ===========================================================================

@test "is_catch_all returns 0 for flagged epic" {
  _write_epics_file <<'EOF'
## E900 — Bugs and Enhancements
<!-- catch_all: true -->
EOF
  bash -c "
    source '$SCRIPT'
    is_catch_all E900 '$EPICS_FILE' '$SHARDS_DIR'
  "
}

@test "is_catch_all returns 1 for unflagged epic" {
  _write_epics_file <<'EOF'
## E900 — Authentication System
EOF
  run bash -c "
    source '$SCRIPT'
    is_catch_all E900 '$EPICS_FILE' '$SHARDS_DIR'
  "
  [ "$status" -ne 0 ]
}
