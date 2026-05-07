#!/usr/bin/env bats
# frontmatter-mode-bias.bats — meeting-notes-writer mode + bias frontmatter (E76-S5)
#
# T7 / AC16 / FR-MTG-17 / FR-MTG-18
#
# Verifies meeting-notes-writer.sh emits closing_artifact_bias,
# default_invitees_resolved, missing_invitees, and invitees_override (when
# applicable) into the saved meeting frontmatter.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  WRITER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/meeting-notes-writer.sh"
  TMPDIR_T="$(mktemp -d)"
  ROOT_T="$TMPDIR_T/root"
  mkdir -p "$ROOT_T"
  PAYLOAD="$TMPDIR_T/payload.yaml"
}

teardown() {
  rm -rf "$TMPDIR_T"
}

write_payload() {
  cat > "$PAYLOAD"
}

@test "AC16: writer emits closing_artifact_bias and resolved/missing invitees frontmatter" {
  write_payload <<'YAML'
charter: "Choose the architecture pattern"
mode: architecture
closing_artifact_bias: architecture-decisions
default_invitees_resolved:
  - Theo
  - Soren
  - Milo
  - Juno
  - Priya
missing_invitees:
  - Omar
attendees:
  - name: Theo
    role: architect
    tokens: 500
total_tokens: 500
transcript: |
  [round 1 / turn 1 / Theo] Pattern A.
summary: "Discussed architecture options"
preludes: |
  [Prelude] Theo — sources: docs/arch.md
decisions:
  - "Choose pattern A"
risks:
  - "Migration cost"
open_questions:
  - "Timeline?"
scratchpad_final: ""
action_items:
  - AI-2026-05-07-1
memory_writethrough:
  - Theo
YAML

  run "$WRITER" --root "$ROOT_T" --payload "$PAYLOAD" --date 2026-05-07 --slug arch-decision
  [ "$status" -eq 0 ]

  out="$ROOT_T/docs/creative-artifacts/meeting-2026-05-07-arch-decision.md"
  [ -f "$out" ]

  grep -qE "^mode: architecture\$" "$out"
  grep -qE "^closing_artifact_bias: architecture-decisions\$" "$out"
  grep -qE "^default_invitees_resolved:" "$out"
  grep -qE "^missing_invitees:" "$out"
  grep -qE "^  - Theo\$" "$out"
  grep -qE "^  - Omar\$" "$out"
}

@test "AC16: missing_invitees emits empty list when no defaults missing" {
  write_payload <<'YAML'
charter: "Decide on auth refactor"
mode: decide
closing_artifact_bias: decision-record
default_invitees_resolved: []
missing_invitees: []
attendees:
  - name: alice
    role: dev
    tokens: 100
total_tokens: 100
transcript: |
  [round 1 / turn 1 / alice] Hi.
summary: "x"
preludes: |
  [Prelude] alice
decisions:
  - "x"
risks:
  - "y"
open_questions:
  - "z"
scratchpad_final: ""
action_items:
  - AI-1
memory_writethrough:
  - alice
YAML
  run "$WRITER" --root "$ROOT_T" --payload "$PAYLOAD" --date 2026-05-07 --slug d
  [ "$status" -eq 0 ]
  out="$ROOT_T/docs/creative-artifacts/meeting-2026-05-07-d.md"
  grep -qE "^missing_invitees: \[\]\$" "$out"
  grep -qE "^default_invitees_resolved: \[\]\$" "$out"
}

@test "AC14: invitees_override frontmatter recorded when override path used" {
  write_payload <<'YAML'
charter: "Red-team the auth spec"
mode: red-team
closing_artifact_bias: risk-register
default_invitees_resolved: []
missing_invitees: []
invitees_override: true
attendees:
  - name: alice
    role: dev
    tokens: 100
  - name: bob
    role: dev
    tokens: 100
total_tokens: 200
transcript: |
  [round 1 / turn 1 / alice] Hi.
summary: "x"
preludes: |
  [Prelude] alice
decisions:
  - "x"
risks:
  - "y"
open_questions:
  - "z"
scratchpad_final: ""
action_items:
  - AI-1
memory_writethrough:
  - alice
YAML
  run "$WRITER" --root "$ROOT_T" --payload "$PAYLOAD" --date 2026-05-07 --slug r
  [ "$status" -eq 0 ]
  out="$ROOT_T/docs/creative-artifacts/meeting-2026-05-07-r.md"
  grep -qE "^invitees_override: true\$" "$out"
}

@test "Backward compat: payload without new fields still writes (legacy E76-S3 path)" {
  # A payload that omits closing_artifact_bias / default_invitees_resolved /
  # missing_invitees / invitees_override MUST still produce a valid notes file.
  # This guarantees E76-S5 does not break existing E76-S3 callers.
  write_payload <<'YAML'
charter: "Decide on auth refactor"
mode: decide
attendees:
  - name: alice
    role: dev
    tokens: 100
total_tokens: 100
transcript: |
  [round 1 / turn 1 / alice] Hi.
summary: "x"
preludes: |
  [Prelude] alice
decisions:
  - "x"
risks:
  - "y"
open_questions:
  - "z"
scratchpad_final: ""
action_items:
  - AI-1
memory_writethrough:
  - alice
YAML
  run "$WRITER" --root "$ROOT_T" --payload "$PAYLOAD" --date 2026-05-07 --slug legacy
  [ "$status" -eq 0 ]
  out="$ROOT_T/docs/creative-artifacts/meeting-2026-05-07-legacy.md"
  [ -f "$out" ]
  grep -qE "^mode: decide\$" "$out"
}
