#!/usr/bin/env bats
# anti-amnesia-contract.bats — gaia-meeting anti-amnesia session-load contract (E76-S3)
#
# AC8 / FR-MTG-26
#
# The anti-amnesia property is enforced by the §4.10 sidecar load contract
# (memory-management skill) which surfaces decision-log entries automatically
# when an agent's session-load runs against a workflow that touches a topic
# carried forward (matched on `tags` or `source_meeting`). Verification
# requires three artifacts on disk:
#
#   1. A memory entry written by the fan-out writer with proper frontmatter
#      (agent, date, source_meeting, type: decision, tags).
#   2. The §4.10 load contract documented in the memory-management skill.
#   3. The gaia-meeting SKILL.md anchoring AC8 / FR-MTG-26 to this contract.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  WRITER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/memory-writethrough.sh"
  MEETING_SKILL="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/SKILL.md"
  TMPDIR_T="$(mktemp -d)"
  ROOT_T="$TMPDIR_T/root"
  mkdir -p "$ROOT_T"
}

teardown() {
  rm -rf "$TMPDIR_T"
}

@test "AC8: write-through entry carries `tags` so a later load can match by tag" {
  drafts="$TMPDIR_T/drafts"
  mkdir -p "$drafts"
  cat > "$drafts/theo.md" <<'MD'
---
agent: theo
decided:
  - "Adopt JWT refresh"
constraints:
  - "Rotate every 15m"
open_items:
  - "AI-2026-05-07-1"
sources:
  - "docs/planning-artifacts/architecture/01.md"
tags:
  - "auth-refactor"
---
MD
  "$WRITER" --root "$ROOT_T" --drafts "$drafts" --source-meeting "meeting-2026-05-07-fixture" --date 2026-05-07 --slug fixture
  out="$ROOT_T/_memory/theo-sidecar/decisions/2026-05-07-fixture.md"
  [ -f "$out" ]
  awk '/^tags:/{flag=1; next} /^[A-Za-z_][A-Za-z0-9_]*:/{flag=0} flag' "$out" | grep -q 'auth-refactor'
}

@test "AC8: write-through entry carries `source_meeting` for cross-meeting matching" {
  drafts="$TMPDIR_T/drafts"
  mkdir -p "$drafts"
  cat > "$drafts/theo.md" <<'MD'
---
agent: theo
decided:
  - "x"
constraints:
  - "y"
open_items:
  - "AI-1"
sources:
  - "docs/x.md"
tags:
  - "auth-refactor"
---
MD
  "$WRITER" --root "$ROOT_T" --drafts "$drafts" --source-meeting "meeting-2026-05-07-fixture" --date 2026-05-07 --slug fixture
  out="$ROOT_T/_memory/theo-sidecar/decisions/2026-05-07-fixture.md"
  grep -qE '^source_meeting: meeting-2026-05-07-fixture' "$out"
}

@test "AC8: gaia-meeting/SKILL.md anchors anti-amnesia to the §4.10 sidecar load contract" {
  grep -qE 'FR-MTG-26|anti-amnesia' "$MEETING_SKILL"
}
