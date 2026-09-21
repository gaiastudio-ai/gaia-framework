#!/usr/bin/env bats
# memory-writethrough.bats — gaia-meeting per-agent memory write-through
#
# Covers one sidecar decision file per accepted agent, its frontmatter, and the
# four mandatory body sections.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  WRITER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/memory-writethrough.sh"
  TMPDIR_T="$(mktemp -d)"
  ROOT_T="$TMPDIR_T/root"
  mkdir -p "$ROOT_T"

  # The writer resolves its sidecar tree from PROJECT_ROOT (it takes --root for
  # argument-shape compatibility but does not use it for the output location),
  # so the fixture must set PROJECT_ROOT or the writer lands files relative to
  # the current working directory. Export it, then ask the shared paths helper
  # for the memory tree rather than writing a second path literal here.
  export PROJECT_ROOT="$ROOT_T"
  MEMORY_DIR="$(
    _GAIA_PATHS_LOADED="" \
    bash -c '. "$1/plugins/gaia/scripts/lib/gaia-paths.sh" >/dev/null 2>&1;
             printf "%s" "$GAIA_MEMORY_DIR"' _ "$REPO_ROOT"
  )"
}

# _sidecar_decision — the decision file the writer produces for one agent.
_sidecar_decision() {
  printf '%s/%s-sidecar/decisions/2026-05-07-fixture-slug.md\n' "$MEMORY_DIR" "$1"
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

@test "writes exactly one file per accepted agent at the canonical path" {
  drafts=$(_seed_drafts layla derek sable)
  run "$WRITER" --root "$ROOT_T" --drafts "$drafts" --source-meeting "meeting-2026-05-07-fixture-slug" --date 2026-05-07 --slug fixture-slug
  [ "$status" -eq 0 ]
  [ -f "$(_sidecar_decision layla)" ]
  [ -f "$(_sidecar_decision derek)" ]
  [ -f "$(_sidecar_decision sable)" ]
}

@test "zero files are written for dropped agents" {
  # Simulate K=3 of N=4 — Theo dropped (no draft file)
  drafts=$(_seed_drafts layla derek sable)
  run "$WRITER" --root "$ROOT_T" --drafts "$drafts" --source-meeting "meeting-2026-05-07-fixture-slug" --date 2026-05-07 --slug fixture-slug
  [ "$status" -eq 0 ]
  [ ! -d "$MEMORY_DIR/theo-sidecar" ]
}

@test "each file frontmatter contains agent, date, source_meeting, type: decision, tags" {
  drafts=$(_seed_drafts layla)
  "$WRITER" --root "$ROOT_T" --drafts "$drafts" --source-meeting "meeting-2026-05-07-fixture-slug" --date 2026-05-07 --slug fixture-slug
  out="$(_sidecar_decision layla)"
  grep -qE '^agent: layla' "$out"
  grep -qE '^date: 2026-05-07' "$out"
  grep -qE '^source_meeting: meeting-2026-05-07-fixture-slug' "$out"
  grep -qE '^type: decision' "$out"
  grep -qE '^tags:' "$out"
}

@test "body has the four mandatory H2 sections in fixed order" {
  drafts=$(_seed_drafts layla)
  "$WRITER" --root "$ROOT_T" --drafts "$drafts" --source-meeting "meeting-2026-05-07-fixture-slug" --date 2026-05-07 --slug fixture-slug
  out="$(_sidecar_decision layla)"

  h1=$(grep -n "^## What I decided / agreed to in this meeting" "$out" | head -1 | cut -d: -f1)
  h2=$(grep -n "^## Constraints I committed to" "$out" | head -1 | cut -d: -f1)
  h3=$(grep -n "^## Open items I'm tracking" "$out" | head -1 | cut -d: -f1)
  h4=$(grep -n "^## Sources I relied on" "$out" | head -1 | cut -d: -f1)

  [ -n "$h1" ] && [ -n "$h2" ] && [ -n "$h3" ] && [ -n "$h4" ]
  [ "$h1" -lt "$h2" ]
  [ "$h2" -lt "$h3" ]
  [ "$h3" -lt "$h4" ]
}

@test "the Open items section lists the action-item ids from the draft" {
  drafts=$(_seed_drafts layla)
  "$WRITER" --root "$ROOT_T" --drafts "$drafts" --source-meeting "meeting-2026-05-07-fixture-slug" --date 2026-05-07 --slug fixture-slug
  out="$(_sidecar_decision layla)"
  # Body Open items section must list AI-2026-05-07-2
  awk '/^## Open items I'\''m tracking/{flag=1; next} /^## /{flag=0} flag' "$out" | grep -q 'AI-2026-05-07-2'
}

@test "only the four mandatory H2 sections appear" {
  drafts=$(_seed_drafts layla)
  "$WRITER" --root "$ROOT_T" --drafts "$drafts" --source-meeting "meeting-2026-05-07-fixture-slug" --date 2026-05-07 --slug fixture-slug
  out="$(_sidecar_decision layla)"
  count=$(grep -c '^## ' "$out")
  [ "$count" -eq 4 ]
}
