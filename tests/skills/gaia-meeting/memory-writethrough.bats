#!/usr/bin/env bats
# memory-writethrough.bats — gaia-meeting per-agent memory write-through (E76-S3)
#
# AC6 / AC7 / FR-MTG-24 / FR-MTG-25 / TC-MTG-MEM-1 / TC-MTG-MEM-2 / TC-MTG-MEM-3

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  WRITER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/memory-writethrough.sh"
  TMPDIR_T="$(mktemp -d)"
  ROOT_T="$TMPDIR_T/root"
  mkdir -p "$ROOT_T"
}

teardown() {
  rm -rf "$TMPDIR_T"
}

@test "Pre-flight: memory-writethrough.sh exists and is executable" {
  [ -x "$WRITER" ]
}

# Helper: build a per-agent draft directory
# Each accepted draft is a file: <agent>.yaml with payload sections + tags/decided/etc.
_seed_drafts() {
  local dir="$TMPDIR_T/drafts"
  mkdir -p "$dir"
  for agent in "$@"; do
    cat > "$dir/${agent}.md" <<MD
---
agent: ${agent}
decided:
  - "${agent} decided to do X"
constraints:
  - "${agent} committed to constraint Y"
open_items:
  - "AI-2026-05-07-2"
sources:
  - "docs/planning-artifacts/architecture/01.md"
tags:
  - "auth-refactor"
---
MD
  done
  echo "$dir"
}

@test "AC6: writes exactly one file per accepted agent at canonical path" {
  drafts=$(_seed_drafts layla derek sable)
  run "$WRITER" --root "$ROOT_T" --drafts "$drafts" --source-meeting "meeting-2026-05-07-fixture-slug" --date 2026-05-07 --slug fixture-slug
  [ "$status" -eq 0 ]
  [ -f "$ROOT_T/_memory/layla-sidecar/decisions/2026-05-07-fixture-slug.md" ]
  [ -f "$ROOT_T/_memory/derek-sidecar/decisions/2026-05-07-fixture-slug.md" ]
  [ -f "$ROOT_T/_memory/sable-sidecar/decisions/2026-05-07-fixture-slug.md" ]
}

@test "AC6: zero files written for dropped agents (K of N)" {
  # Simulate K=3 of N=4 — Theo dropped (no draft file)
  drafts=$(_seed_drafts layla derek sable)
  run "$WRITER" --root "$ROOT_T" --drafts "$drafts" --source-meeting "meeting-2026-05-07-fixture-slug" --date 2026-05-07 --slug fixture-slug
  [ "$status" -eq 0 ]
  [ ! -d "$ROOT_T/_memory/theo-sidecar" ]
}

@test "AC6: each file frontmatter contains agent, date, source_meeting, type: decision, tags" {
  drafts=$(_seed_drafts layla)
  "$WRITER" --root "$ROOT_T" --drafts "$drafts" --source-meeting "meeting-2026-05-07-fixture-slug" --date 2026-05-07 --slug fixture-slug
  out="$ROOT_T/_memory/layla-sidecar/decisions/2026-05-07-fixture-slug.md"
  grep -qE '^agent: layla' "$out"
  grep -qE '^date: 2026-05-07' "$out"
  grep -qE '^source_meeting: meeting-2026-05-07-fixture-slug' "$out"
  grep -qE '^type: decision' "$out"
  grep -qE '^tags:' "$out"
}

@test "AC7: body has four mandatory H2 sections in fixed order" {
  drafts=$(_seed_drafts layla)
  "$WRITER" --root "$ROOT_T" --drafts "$drafts" --source-meeting "meeting-2026-05-07-fixture-slug" --date 2026-05-07 --slug fixture-slug
  out="$ROOT_T/_memory/layla-sidecar/decisions/2026-05-07-fixture-slug.md"

  h1=$(grep -n "^## What I decided / agreed to in this meeting" "$out" | head -1 | cut -d: -f1)
  h2=$(grep -n "^## Constraints I committed to" "$out" | head -1 | cut -d: -f1)
  h3=$(grep -n "^## Open items I'm tracking" "$out" | head -1 | cut -d: -f1)
  h4=$(grep -n "^## Sources I relied on" "$out" | head -1 | cut -d: -f1)

  [ -n "$h1" ] && [ -n "$h2" ] && [ -n "$h3" ] && [ -n "$h4" ]
  [ "$h1" -lt "$h2" ]
  [ "$h2" -lt "$h3" ]
  [ "$h3" -lt "$h4" ]
}

@test "AC7: Open items section lists action item IDs from draft" {
  drafts=$(_seed_drafts layla)
  "$WRITER" --root "$ROOT_T" --drafts "$drafts" --source-meeting "meeting-2026-05-07-fixture-slug" --date 2026-05-07 --slug fixture-slug
  out="$ROOT_T/_memory/layla-sidecar/decisions/2026-05-07-fixture-slug.md"
  # Body Open items section must list AI-2026-05-07-2
  awk '/^## Open items I'\''m tracking/{flag=1; next} /^## /{flag=0} flag' "$out" | grep -q 'AI-2026-05-07-2'
}

@test "AC7: only the four mandatory H2 sections appear" {
  drafts=$(_seed_drafts layla)
  "$WRITER" --root "$ROOT_T" --drafts "$drafts" --source-meeting "meeting-2026-05-07-fixture-slug" --date 2026-05-07 --slug fixture-slug
  out="$ROOT_T/_memory/layla-sidecar/decisions/2026-05-07-fixture-slug.md"
  count=$(grep -c '^## ' "$out")
  [ "$count" -eq 4 ]
}
