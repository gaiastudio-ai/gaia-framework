#!/usr/bin/env bats
# write-boundary-fixture.bats — fixture-meeting end-to-end write-set guard.
#
# Run a fixture meeting close+save pipeline and assert that every disk write
# lands under one of the permitted roots — and nothing else. This is the
# end-to-end counterpart to the unit-level boundary checks: it catches a writer
# that starts emitting somewhere the guard would have refused.
#
# Roots are resolved through the same path helper the shipped scripts use
# rather than restated as literals here.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts"
  TMPDIR_T="$(mktemp -d)"
  ROOT_T="$TMPDIR_T/root"
  mkdir -p "$ROOT_T/.gaia"
  load helpers/runtime-paths
  gaia_load_runtime_paths "$REPO_ROOT" || {
    skip "runtime path helper unavailable; cannot resolve the tree the way production does"
  }
}

teardown() {
  rm -rf "$TMPDIR_T"
}

@test "a fixture meeting writes only inside the three permitted roots" {
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
  registry="$ROOT_T/$GAIA_REL_STATE/action-items.yaml"
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
  - "planning-artifacts/architecture/01.md"
tags:
  - "fixture-tag"
---
MD
  done
  PROJECT_ROOT="$ROOT_T" "$SCRIPTS/memory-writethrough.sh" --root "$ROOT_T" --drafts "$mem_drafts" --source-meeting "fixture-slug" --date 2026-05-07 --slug fixture-slug

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
      "$GAIA_REL_ARTIFACTS"/creative-artifacts/meeting-notes/meeting-*.md) ;;
      "$GAIA_REL_ARTIFACTS"/creative-artifacts/meeting-*.md) ;;
      "$GAIA_REL_STATE"/action-items.yaml) ;;
      "$GAIA_REL_MEMORY"/*-sidecar/decisions/*.md) ;;
      *)
        echo "REJECTED write outside allowlist: $rel"
        return 1
        ;;
    esac
  done < <(find "$ROOT_T" -type f)
}

@test "the write-boundary guard rejects the sprint-status file" {
  run "$SCRIPTS/write-boundary.sh" "$GAIA_REL_STATE/sprint-status.yaml"
  [ "$status" -eq 2 ]
}

@test "the write-boundary guard rejects a requirements-document path" {
  run "$SCRIPTS/write-boundary.sh" "$GAIA_REL_ARTIFACTS/planning-artifacts/prd/01.md"
  [ "$status" -eq 2 ]
}

@test "the write-boundary guard rejects story files" {
  run "$SCRIPTS/write-boundary.sh" "$GAIA_REL_ARTIFACTS/implementation-artifacts/some-story.md"
  [ "$status" -eq 2 ]
}

@test "the write-boundary guard rejects the traceability matrix" {
  run "$SCRIPTS/write-boundary.sh" "$GAIA_REL_ARTIFACTS/test-artifacts/strategy/traceability-matrix.md"
  [ "$status" -eq 2 ]
}
