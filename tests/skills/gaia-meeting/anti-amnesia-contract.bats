#!/usr/bin/env bats
# anti-amnesia-contract.bats — gaia-meeting anti-amnesia session-load contract
#
# The anti-amnesia property is enforced by the sidecar load contract
# (memory-management skill) which surfaces decision-log entries automatically
# when an agent's session-load runs against a workflow that touches a topic
# carried forward (matched on `tags` or `source_meeting`). Verification
# requires three artifacts on disk:
#
#   1. A memory entry written by the fan-out writer with proper frontmatter
#      (agent, date, source_meeting, type: decision, tags).
#   2. The load contract documented in the memory-management skill.
#   3. The gaia-meeting SKILL.md anchoring anti-amnesia to this contract.

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

# The writer resolves the sidecar tree from PROJECT_ROOT, the same way
# production does; driving it any other way would assert a path the shipped
# code does not write.
run_writer() {
  PROJECT_ROOT="$ROOT_T" "$WRITER" \
    --root "$ROOT_T" \
    --drafts "$TMPDIR_T/drafts" \
    --source-meeting "meeting-2026-05-07-fixture" \
    --date 2026-05-07 --slug fixture
}

sidecar_entry() {
  printf '%s' "$ROOT_T/.gaia/memory/$1-sidecar/decisions/2026-05-07-fixture.md"
}

@test "write-through entry carries its tags so a later load can match on them" {
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
  run_writer
  out="$(sidecar_entry theo)"
  [ -f "$out" ]
  awk '/^tags:/{flag=1; next} /^[A-Za-z_][A-Za-z0-9_]*:/{flag=0} flag' "$out" | grep -q 'auth-refactor'
}

@test "write-through entry carries its source meeting for cross-meeting matching" {
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
  run_writer
  out="$(sidecar_entry theo)"
  grep -qE '^source_meeting: meeting-2026-05-07-fixture' "$out"
}

@test "meeting SKILL.md anchors anti-amnesia to the sidecar load contract" {
  grep -qE 'FR-MTG-26|anti-amnesia' "$MEETING_SKILL"
}
