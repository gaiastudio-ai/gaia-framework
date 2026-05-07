#!/usr/bin/env bats
# write-boundary-fixture.bats — fixture-meeting end-to-end write-set guard (E76-S3)
#
# AC10 / FR-MTG-31
#
# Run a fixture meeting close+save pipeline and assert that every disk write
# falls under one of the three allowed roots — and nothing else.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts"
  TMPDIR_T="$(mktemp -d)"
  ROOT_T="$TMPDIR_T/root"
  mkdir -p "$ROOT_T"
}

teardown() {
  rm -rf "$TMPDIR_T"
}

@test "AC10: fixture meeting writes only inside the three permitted roots" {
  # 1) Action-items write
  drafts_dir="$TMPDIR_T/ai-drafts"
  mkdir -p "$drafts_dir"
  cat > "$drafts_dir/items.yaml" <<'YAML'
- type: feature
  priority: normal
  assignee: "derek"
  context_for_target: "Fixture context"
  acceptance: "Fixture acceptance"
- type: discussion-only
  priority: low
  assignee: "user"
  context_for_target: "Discussion only"
  acceptance: "—"
YAML
  registry="$ROOT_T/docs/planning-artifacts/action-items.yaml"
  mkdir -p "$(dirname "$registry")"
  "$SCRIPTS/action-items-writer.sh" --registry "$registry" --drafts "$drafts_dir/items.yaml" --source-meeting "fixture-slug" --date 2026-05-07

  # 2) Memory write-through
  mem_drafts="$TMPDIR_T/mem-drafts"
  mkdir -p "$mem_drafts"
  for agent in layla derek; do
    cat > "$mem_drafts/${agent}.md" <<MD
---
agent: ${agent}
decided:
  - "${agent} decided X"
constraints:
  - "${agent} committed Y"
open_items:
  - "AI-2026-05-07-1"
sources:
  - "docs/planning-artifacts/architecture/01.md"
tags:
  - "fixture-tag"
---
MD
  done
  "$SCRIPTS/memory-writethrough.sh" --root "$ROOT_T" --drafts "$mem_drafts" --source-meeting "fixture-slug" --date 2026-05-07 --slug fixture-slug

  # 3) Meeting notes
  payload="$TMPDIR_T/payload.yaml"
  cat > "$payload" <<'YAML'
charter: "Fixture charter"
mode: decide
attendees:
  - name: layla
    role: tester
    tokens: 1000
  - name: derek
    role: pm
    tokens: 500
total_tokens: 1500
transcript: |
  [round 1 / turn 1 / Layla] Hi.
summary: "Fixture summary"
preludes: |
  [Prelude] Layla
decisions:
  - "Decision A"
risks:
  - "Risk B"
open_questions:
  - "Q?"
scratchpad_final: ""
action_items:
  - AI-2026-05-07-1
  - AI-2026-05-07-2
memory_writethrough:
  - layla
  - derek
YAML
  "$SCRIPTS/meeting-notes-writer.sh" --root "$ROOT_T" --payload "$payload" --date 2026-05-07 --slug fixture-slug

  # 4) Capture every file the fixture wrote under $ROOT_T and assert allowlist.
  while IFS= read -r f; do
    rel="${f#"$ROOT_T/"}"
    case "$rel" in
      docs/creative-artifacts/meeting-*.md) ;;
      docs/planning-artifacts/action-items.yaml) ;;
      _memory/*-sidecar/decisions/*.md) ;;
      *)
        echo "REJECTED write outside allowlist: $rel"
        return 1
        ;;
    esac
  done < <(find "$ROOT_T" -type f)
}

@test "AC10: write-boundary guard rejects sprint-status.yaml" {
  run "$SCRIPTS/write-boundary.sh" "docs/planning-artifacts/sprint-status.yaml"
  [ "$status" -eq 2 ]
}

@test "AC10: write-boundary guard rejects PRD path" {
  run "$SCRIPTS/write-boundary.sh" "docs/planning-artifacts/prd/01.md"
  [ "$status" -eq 2 ]
}

@test "AC10: write-boundary guard rejects story files" {
  run "$SCRIPTS/write-boundary.sh" "docs/implementation-artifacts/E1-S1.md"
  [ "$status" -eq 2 ]
}

@test "AC10: write-boundary guard rejects traceability" {
  run "$SCRIPTS/write-boundary.sh" "docs/test-artifacts/strategy/traceability-matrix.md"
  [ "$status" -eq 2 ]
}
