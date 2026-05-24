#!/usr/bin/env bats
# e101-s1-adr-118-architecture-artifacts-decision.bats
#
# Story: E101-S1 — ADR-118 MOVE-vs-DOCUMENT decision for
#   architecture-artifacts/ phase
# Origin: AF-2026-05-24-1
# Traces to: FR-529, ADR-118, TC-AAT-1
#
# Asserts that ADR-118 has been authored as a sharded ADR file under
# .gaia/artifacts/planning-artifacts/architecture/ and that its Decision +
# Rejected Alternatives + Related sections satisfy the story's AC6 sub-cases
# TC-AAT-1a..1e.

load 'test_helper.bash'

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  ARCH_DIR="$REPO_ROOT/.gaia/artifacts/planning-artifacts/architecture"
  ADR_FILE=""
  if [ -d "$ARCH_DIR" ]; then
    for candidate in "$ARCH_DIR"/*-adr-118-architecture-artifacts-phase-decision.md; do
      if [ -f "$candidate" ]; then
        ADR_FILE="$candidate"
        break
      fi
    done
  fi
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# TC-AAT-1a — ADR shard exists at canonical sharded location
# ---------------------------------------------------------------------------

@test "TC-AAT-1a: ADR-118 shard exists under .gaia/artifacts/planning-artifacts/architecture/" {
  [ -n "$ADR_FILE" ]
  [ -f "$ADR_FILE" ]
}

# ---------------------------------------------------------------------------
# TC-AAT-1b — Decision section names exactly one of {MOVE, DOCUMENT}
# ---------------------------------------------------------------------------

@test "TC-AAT-1b: ADR Decision section contains Selected: MOVE or Selected: DOCUMENT" {
  [ -n "$ADR_FILE" ]
  grep -qE "^Selected: (MOVE|DOCUMENT)" "$ADR_FILE"
}

# ---------------------------------------------------------------------------
# TC-AAT-1c — Rejected Alternatives section is present and non-empty
# ---------------------------------------------------------------------------

@test "TC-AAT-1c: ADR has a non-empty Rejected Alternatives section" {
  [ -n "$ADR_FILE" ]
  # Extract Rejected Alternatives section body (between its heading and the
  # next ## heading) and assert non-empty after trim.
  body="$(awk '
    /^## Rejected Alternatives/ {capture=1; next}
    capture && /^## / {capture=0}
    capture {print}
  ' "$ADR_FILE" | tr -d "[:space:]")"
  [ -n "$body" ]
}

# ---------------------------------------------------------------------------
# TC-AAT-1d — Related section cross-references ADR-111 and AF-2026-05-24-1
# ---------------------------------------------------------------------------

@test "TC-AAT-1d: ADR Related section names ADR-111 and AF-2026-05-24-1" {
  [ -n "$ADR_FILE" ]
  grep -q "ADR-111" "$ADR_FILE"
  grep -q "AF-2026-05-24-1" "$ADR_FILE"
}

# ---------------------------------------------------------------------------
# TC-AAT-1e — Downstream story status matches ADR decision
# ---------------------------------------------------------------------------
# When Selected: DOCUMENT, then E101-S3 stays backlog/ready-for-dev (chosen
# path) and E101-S2 is superseded-by-decision. Mirror case for MOVE.

@test "TC-AAT-1e: downstream story status aligns with ADR-118 decision" {
  [ -n "$ADR_FILE" ]
  STORIES_DIR="$REPO_ROOT/.gaia/artifacts/implementation-artifacts/epic-E101-architecture-artifacts-ghost-directory-resolution/stories"
  E101_S2="$STORIES_DIR/E101-S2-move-architecture-docs-update-producer-consumer-skills.md"
  E101_S3="$STORIES_DIR/E101-S3-document-architecture-lives-under-planning-artifacts.md"
  [ -f "$E101_S2" ]
  [ -f "$E101_S3" ]

  if grep -qE "^Selected: DOCUMENT" "$ADR_FILE"; then
    grep -qE '^status: superseded-by-decision' "$E101_S2"
    grep -qE '^status: (backlog|ready-for-dev|in-progress|review|done)' "$E101_S3"
  elif grep -qE "^Selected: MOVE" "$ADR_FILE"; then
    grep -qE '^status: superseded-by-decision' "$E101_S3"
    grep -qE '^status: (backlog|ready-for-dev|in-progress|review|done)' "$E101_S2"
  else
    return 1
  fi
}
