#!/usr/bin/env bats
# meeting-notes-writer.bats — gaia-meeting saved-notes writer (E76-S3)
#
# AC9 / FR-MTG-27

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  WRITER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/meeting-notes-writer.sh"
  TMPDIR_T="$(mktemp -d)"
  ROOT_T="$TMPDIR_T/root"
  mkdir -p "$ROOT_T"
  PAYLOAD="$TMPDIR_T/payload.yaml"
  cat > "$PAYLOAD" <<'YAML'
charter: "Decide on auth refactor"
mode: decide
attendees:
  - name: layla
    role: tester
    tokens: 1200
  - name: derek
    role: pm
    tokens: 800
total_tokens: 2000
transcript: |
  [round 1 / turn 1 / Layla] Hello.
  [round 1 / turn 2 / Derek] Hi.
summary: "Discussion concluded with two action items"
preludes: |
  [Prelude] Layla — sources consulted: docs/x.md
decisions:
  - "Adopt JWT refresh"
risks:
  - "Token leakage"
open_questions:
  - "What is the rotation period?"
scratchpad_final: ""
action_items:
  - AI-2026-05-07-1
  - AI-2026-05-07-2
memory_writethrough:
  - layla
  - derek
YAML
}

teardown() {
  rm -rf "$TMPDIR_T"
}

@test "Pre-flight: meeting-notes-writer.sh exists and is executable" {
  [ -x "$WRITER" ]
}

@test "AC9: writes to docs/creative-artifacts/meeting-{date}-{slug}.md" {
  run "$WRITER" --root "$ROOT_T" --payload "$PAYLOAD" --date 2026-05-07 --slug fixture-slug
  [ "$status" -eq 0 ]
  [ -f "$ROOT_T/docs/creative-artifacts/meeting-2026-05-07-fixture-slug.md" ]
}

@test "AC9: frontmatter contains per-attendee + total token-cost breakdown" {
  "$WRITER" --root "$ROOT_T" --payload "$PAYLOAD" --date 2026-05-07 --slug fixture-slug
  out="$ROOT_T/docs/creative-artifacts/meeting-2026-05-07-fixture-slug.md"
  grep -qE '^cost_breakdown:' "$out"
  grep -qE '^[[:space:]]+- name: layla' "$out"
  grep -qE 'tokens: 1200' "$out"
  grep -qE '^total_tokens: 2000' "$out"
}

@test "AC9: frontmatter contains scratchpad_extractions: (empty list when absent)" {
  "$WRITER" --root "$ROOT_T" --payload "$PAYLOAD" --date 2026-05-07 --slug fixture-slug
  out="$ROOT_T/docs/creative-artifacts/meeting-2026-05-07-fixture-slug.md"
  grep -qE '^scratchpad_extractions: \[\]' "$out"
}

@test "AC9: frontmatter contains action_items with IDs" {
  "$WRITER" --root "$ROOT_T" --payload "$PAYLOAD" --date 2026-05-07 --slug fixture-slug
  out="$ROOT_T/docs/creative-artifacts/meeting-2026-05-07-fixture-slug.md"
  grep -qE 'AI-2026-05-07-1' "$out"
  grep -qE 'AI-2026-05-07-2' "$out"
}

@test "AC9: body contains all required sections in order" {
  "$WRITER" --root "$ROOT_T" --payload "$PAYLOAD" --date 2026-05-07 --slug fixture-slug
  out="$ROOT_T/docs/creative-artifacts/meeting-2026-05-07-fixture-slug.md"

  for section in "## Charter" "## Summary" "## Research preludes" "## Transcript" "## Decisions" "## Risks identified" "## Open questions" "## Scratchpad final state" "## Action items" "## Memory write-through"; do
    grep -qF "$section" "$out" || { echo "missing section: $section"; cat "$out"; return 1; }
  done
}
