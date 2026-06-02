#!/usr/bin/env bats
#
# E28-S172 — Doc-integrity checks for the consolidated checkpoint.sh rename.
#
# Story: docs/implementation-artifacts/E28-S172-update-architecture-to-reference-consolidated-checkpoint-sh.md
#
# These tests lock in the post-E28-S10 naming in the three live documents that
# still referenced the pre-consolidation script names (checkpoint-write.sh,
# checkpoint-verify.sh, sha256-verify.sh). They do NOT touch the historical
# story artifacts under docs/implementation-artifacts/ — those are an immutable
# record of what was specified at the time.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  PROJECT_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

  # AF-2026-06-01-3: docs/ retired from gaia-framework; architecture.md is project-root
  # canonical post-ADR-111. The MIGRATION constant was removed with the AC2 tests
  # (the former gaia-framework/docs/migration-guide-v2.md was retired).
  ARCH="$PROJECT_ROOT/.gaia/artifacts/planning-artifacts/architecture.md"
  BROWNFIELD="$REPO_ROOT/plugins/gaia/skills/gaia-brownfield/SKILL.md"
}

# ---------- AC1: architecture.md §10.26.3 names the consolidated script ----------
#
# Scope: the §10.26.3 foundation-scripts TABLE must not list the legacy names as
# active scripts (table rows or the addresses-map table), and the §10.26.7 HOOKS
# TABLE must not name sha256-verify.sh as the hook target. Legacy names are
# tolerated only inside explicit history / redirection prose (the Naming history
# note and the ADR-042 Decision narrative) — those are the intentional mentions
# that preserve traceability for older story artifacts.

# Extract a markdown section delimited by two `####` headers.
# Usage: extract_section <file> <start_heading_prefix> <end_heading_prefix>
# The emitted range is [start, end) — start-inclusive, end-exclusive.
extract_section() {
  awk -v start="$2" -v end="$3" '
    index($0, start) == 1 { flag = 1 }
    index($0, end)   == 1 { flag = 0 }
    flag
  ' "$1"
}

# Count markdown table rows in a section that list a specific script name in the
# Script column (the column 2 cell, backticked).
count_script_rows() {
  local section=$1 script=$2
  printf '%s' "$section" | grep -cE "^\| [0-9]+ \| \`${script}\`" || true
}

@test "AC1 — §10.26.3 foundation-scripts table does not list checkpoint-write.sh as an active row" {
  section=$(extract_section "$ARCH" '#### 10.26.3 ' '#### 10.26.4 ')
  [ "$(count_script_rows "$section" 'checkpoint-write\.sh')" = "0" ]
}

@test "AC1 — §10.26.3 foundation-scripts table does not list checkpoint-verify.sh as an active row" {
  section=$(extract_section "$ARCH" '#### 10.26.3 ' '#### 10.26.4 ')
  [ "$(count_script_rows "$section" 'checkpoint-verify\.sh')" = "0" ]
}

@test "AC1 — §10.26.3 foundation-scripts table does not list sha256-verify.sh as an active row" {
  section=$(extract_section "$ARCH" '#### 10.26.3 ' '#### 10.26.4 ')
  [ "$(count_script_rows "$section" 'sha256-verify\.sh')" = "0" ]
}

@test "AC3 — §10.26.7 hook-wiring table does not invoke sha256-verify.sh" {
  section=$(extract_section "$ARCH" '#### 10.26.7 ' '#### 10.26.8 ')
  count=$(printf '%s' "$section" | grep -c 'sha256-verify\.sh' || true)
  [ "$count" = "0" ]
}

@test "AC1 — architecture.md §10.26.3 names the consolidated checkpoint.sh" {
  run grep -c '`checkpoint\.sh`' "$ARCH"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "AC1 — architecture.md §10.26.3 names the write subcommand" {
  run grep -c 'checkpoint\.sh write' "$ARCH"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "AC1 — architecture.md §10.26.3 names the validate subcommand" {
  run grep -c 'checkpoint\.sh validate' "$ARCH"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "AC1 — architecture.md §10.26.3 names the read subcommand" {
  run grep -c 'checkpoint\.sh read' "$ARCH"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# ---------- AC2 (RETIRED): migration guide redirection note ----------
#
# The four AC2 tests were retired by AF-2026-06-01-3 along with the
# gaia-framework/docs/migration-guide-v2.md they pinned. The legacy-name
# redirection block is no longer required as a documentation surface —
# the V1 sunset under ADR-049 removed the need for a migration guide,
# and the live SKILL.md / script files referenced by AC1 + AC3 carry
# the post-consolidation naming directly.

# ---------- AC3: live skills no longer frame checkpoint.sh as a "deployed equivalent" ----------

@test "AC3 — gaia-brownfield SKILL.md does not reference checkpoint-write.sh" {
  run grep -c 'checkpoint-write\.sh' "$BROWNFIELD"
  [ "$output" = "0" ]
}

@test "AC3 — gaia-brownfield SKILL.md does not reference checkpoint-verify.sh" {
  run grep -c 'checkpoint-verify\.sh' "$BROWNFIELD"
  [ "$output" = "0" ]
}

@test "AC3 — gaia-brownfield SKILL.md names the consolidated checkpoint.sh" {
  run grep -c '`checkpoint\.sh`' "$BROWNFIELD"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}
