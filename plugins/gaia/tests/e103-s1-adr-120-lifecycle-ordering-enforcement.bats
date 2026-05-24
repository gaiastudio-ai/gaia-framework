#!/usr/bin/env bats
# e103-s1-adr-120-lifecycle-ordering-enforcement.bats
# Story: E103-S1 — ADR-120 lifecycle ordering enforcement + --bypass vocabulary.
# Origin: AF-2026-05-24-3. Traces to: FR-535, ADR-120, TC-LOE-1.

load 'test_helper.bash'

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  ARCH_DIR="$REPO_ROOT/.gaia/artifacts/planning-artifacts/architecture"
  ADR_FILE=""
  if [ -d "$ARCH_DIR" ]; then
    for c in "$ARCH_DIR"/*-adr-120-lifecycle-ordering-enforcement.md; do
      if [ -f "$c" ]; then ADR_FILE="$c"; break; fi
    done
  fi
}

teardown() { common_teardown; }

@test "TC-LOE-1a: ADR-120 shard exists" {
  [ -n "$ADR_FILE" ]; [ -f "$ADR_FILE" ]
}

@test "TC-LOE-1b: Skill Classification section enumerates >=16 canonical skills" {
  [ -n "$ADR_FILE" ]
  grep -qE "^## Skill Classification" "$ADR_FILE"
  count="$(grep -cE "^- \`/gaia-" "$ADR_FILE")"
  [ "$count" -ge 16 ]
}

@test "TC-LOE-1c: Bypass Vocabulary names --bypass, --reason, per-sprint, append-only" {
  [ -n "$ADR_FILE" ]
  grep -qF -- "--bypass" "$ADR_FILE"
  grep -qF -- "--reason" "$ADR_FILE"
  grep -qE "per-sprint|sprint_id" "$ADR_FILE"
  grep -qF "append-only" "$ADR_FILE"
}

@test "TC-LOE-1d: Recording Schema names all 5 YAML fields" {
  [ -n "$ADR_FILE" ]
  grep -qF "skill:" "$ADR_FILE"
  grep -qF "reason:" "$ADR_FILE"
  grep -qF "recorded_at:" "$ADR_FILE"
  grep -qF "recorded_by:" "$ADR_FILE"
  grep -qF "sprint_id:" "$ADR_FILE"
}

@test "TC-LOE-1e: Mode Toggle names --strict-lifecycle and lifecycle.strict_mode" {
  [ -n "$ADR_FILE" ]
  grep -qF -- "--strict-lifecycle" "$ADR_FILE"
  grep -qF "lifecycle.strict_mode" "$ADR_FILE"
}

@test "TC-LOE-1f: Amends ADR-042 section present with non-empty body" {
  [ -n "$ADR_FILE" ]
  body="$(awk '/^## Amends/{c=1; next} c && /^## /{c=0} c{print}' "$ADR_FILE" | tr -d '[:space:]')"
  [ -n "$body" ]
}

@test "TC-LOE-1g: Out of Scope names /gaia-doctor" {
  [ -n "$ADR_FILE" ]
  grep -qE "^## Out of Scope" "$ADR_FILE"
  grep -qF "/gaia-doctor" "$ADR_FILE"
}

@test "TC-LOE-1h: Related section names ADR-042, ADR-111, AF-2026-05-24-3" {
  [ -n "$ADR_FILE" ]
  grep -q "ADR-042" "$ADR_FILE"
  grep -q "ADR-111" "$ADR_FILE"
  grep -q "AF-2026-05-24-3" "$ADR_FILE"
}
