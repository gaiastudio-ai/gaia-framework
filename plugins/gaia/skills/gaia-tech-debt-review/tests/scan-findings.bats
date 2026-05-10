#!/usr/bin/env bats
# E55-S12 — scan-findings.sh recursive-glob hardening.
#
# Verifies AC1, AC2, AC3, AC7: scan-findings.sh discovers story files in the
# per-epic nested layout introduced by E79 (`epic-*/stories/**/*.md`) AND
# remains backwards-compatible with the legacy flat layout.

setup() {
  SKILL_DIR="${BATS_TEST_DIRNAME}/.."
  SCRIPT="${SKILL_DIR}/scripts/scan-findings.sh"
  TMPDIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPDIR"
}

# Build a story file with one tech-debt finding row in the Findings table.
# Args: 1=path  2=story_key  3=sprint_id
#
# Uses the 4-column table format (Type | Severity | Finding | Action) that
# the legacy scanner is built for — see e.g. E28-S185 in the live corpus.
fabricate_story() {
  local path="$1" key="$2" sprint="$3"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<EOF
---
key: "$key"
status: in-progress
sprint_id: "$sprint"
---

# Story: $key

## Findings

| Type | Severity | Finding | Suggested Action |
|---|---|---|---|
| tech-debt | medium | Some debt finding for $key | Refactor later |
EOF
}

@test "scan-findings.sh exists and is executable" {
  [ -x "$SCRIPT" ]
}

@test "AC1+AC7: nested per-epic layout discovers story files recursively" {
  fabricate_story "$TMPDIR/epic-E999-foo/stories/E999-S1-bar.md" "E999-S1" "sprint-99"
  run bash "$SCRIPT" --artifacts-dir "$TMPDIR"
  [ "$status" -eq 0 ]
  # Output line count must be > 0 — zero lines is the regression.
  [ -n "$output" ]
  printf '%s\n' "$output" | grep -q '^E999-S1|'
}

@test "AC3: flat-layer backwards-compat — files at root are still discovered" {
  fabricate_story "$TMPDIR/E0-S0-flat.md" "E0-S0" "sprint-99"
  run bash "$SCRIPT" --artifacts-dir "$TMPDIR"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^E0-S0|'
}

@test "AC1+AC3: mixed flat+nested layout discovers BOTH sets" {
  fabricate_story "$TMPDIR/E1-S1-flat.md" "E1-S1" "sprint-99"
  fabricate_story "$TMPDIR/epic-E998-nested/stories/E998-S1-bar.md" "E998-S1" "sprint-99"
  run bash "$SCRIPT" --artifacts-dir "$TMPDIR"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^E1-S1|'
  printf '%s\n' "$output" | grep -q '^E998-S1|'
}

@test "AC2: empty artifacts dir exits 0 with zero output (not a regression)" {
  run bash "$SCRIPT" --artifacts-dir "$TMPDIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
