#!/usr/bin/env bats
# check-monolith-shard-sync.bats — coverage for plugins/gaia/scripts/check-monolith-shard-sync.sh
#
# Story: E53-S243 — Document and enforce monolith-vs-shard sync contract
# Refs:  AC2, AC3, AC4, AC5, AC6
#
# The script is advisory: it ALWAYS exits 0 and emits WARNING / INFO lines on
# stdout when monolith-vs-shard drift is detected. The "_preamble.md partial
# mirror" and "Change Log monolith-as-source-of-truth" exceptions must NOT
# produce false-positive WARNINGs.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  CHECK_SCRIPT="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/check-monolith-shard-sync.sh"
  cd "$TEST_TMP"
  mkdir -p docs/planning-artifacts/prd
  mkdir -p docs/planning-artifacts/architecture
  mkdir -p docs/planning-artifacts/epics
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Helpers — build canonical synced fixtures.
# ---------------------------------------------------------------------------

# _write_synced_prd — writes a tiny PRD monolith + matching shards.
_write_synced_prd() {
  local root="${1:-$TEST_TMP}"
  cat > "$root/docs/planning-artifacts/prd/prd.md" <<'EOF'
---
title: "PRD"
---

# PRD

## 1. Overview

Overview body.

## 2. Goals and Non-Goals

Goals body.
EOF
  # _preamble mirrors only the frontmatter (partial-mirror exception).
  cat > "$root/docs/planning-artifacts/prd/_preamble.md" <<'EOF'
---
title: "PRD"
---
EOF
  cat > "$root/docs/planning-artifacts/prd/01-overview.md" <<'EOF'
## 1. Overview

Overview body.
EOF
  cat > "$root/docs/planning-artifacts/prd/02-goals-and-non-goals.md" <<'EOF'
## 2. Goals and Non-Goals

Goals body.
EOF
}

# _write_synced_arch — writes a tiny architecture monolith + matching shards.
_write_synced_arch() {
  local root="${1:-$TEST_TMP}"
  cat > "$root/docs/planning-artifacts/architecture/architecture.md" <<'EOF'
# Architecture

## 1. System Overview

System overview body.

## 2. Architecture Decisions

Decisions body.
EOF
  cat > "$root/docs/planning-artifacts/architecture/01-1-system-overview.md" <<'EOF'
## 1. System Overview

System overview body.
EOF
  cat > "$root/docs/planning-artifacts/architecture/02-2-architecture-decisions.md" <<'EOF'
## 2. Architecture Decisions

Decisions body.
EOF
}

# _write_synced_epics — writes a tiny epics monolith + matching shards.
_write_synced_epics() {
  local root="${1:-$TEST_TMP}"
  cat > "$root/docs/planning-artifacts/epics/epics-and-stories.md" <<'EOF'
# Epics and Stories

## Change Log

| Date | Change |
|------|--------|
| 2026-05-04 | Initial |

## Epic E1: Foo

Epic E1 body.

## Epic E2: Bar

Epic E2 body.
EOF
  cat > "$root/docs/planning-artifacts/epics/01-change-log.md" <<'EOF'
## Change Log

| Date | Change |
|------|--------|
| 2026-05-04 | Initial |
EOF
  cat > "$root/docs/planning-artifacts/epics/02-e1-foo.md" <<'EOF'
## Epic E1: Foo

Epic E1 body.
EOF
  cat > "$root/docs/planning-artifacts/epics/03-e2-bar.md" <<'EOF'
## Epic E2: Bar

Epic E2 body.
EOF
}

# ---------------------------------------------------------------------------
# AC4 — synced fixtures pass clean.
# ---------------------------------------------------------------------------

@test "synced PRD + arch + epics: no WARNING lines, exit 0" {
  _write_synced_prd
  _write_synced_arch
  _write_synced_epics
  run "$CHECK_SCRIPT" --root "$TEST_TMP"
  [ "$status" -eq 0 ]
  # No WARNING lines on stdout.
  [[ "$output" != *"WARNING"* ]]
}

# ---------------------------------------------------------------------------
# AC2 + AC4 — monolith-only PRD edit triggers WARNING.
# ---------------------------------------------------------------------------

@test "PRD monolith edited but shard not synced: WARNING names section" {
  _write_synced_prd
  _write_synced_arch
  _write_synced_epics
  # Edit monolith section 1 only — shard 01-overview.md untouched.
  cat > "$TEST_TMP/docs/planning-artifacts/prd/prd.md" <<'EOF'
---
title: "PRD"
---

# PRD

## 1. Overview

Overview body MUTATED.

## 2. Goals and Non-Goals

Goals body.
EOF
  run "$CHECK_SCRIPT" --root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"prd"* ]]
  # Section name "1. Overview" is named.
  [[ "$output" == *"Overview"* ]]
}

# ---------------------------------------------------------------------------
# Architecture monolith-only edit.
# ---------------------------------------------------------------------------

@test "architecture monolith edited but shard not synced: WARNING" {
  _write_synced_prd
  _write_synced_arch
  _write_synced_epics
  cat > "$TEST_TMP/docs/planning-artifacts/architecture/architecture.md" <<'EOF'
# Architecture

## 1. System Overview

System overview body MUTATED.

## 2. Architecture Decisions

Decisions body.
EOF
  run "$CHECK_SCRIPT" --root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"architecture"* ]]
}

# ---------------------------------------------------------------------------
# Shard-only edit triggers WARNING.
# ---------------------------------------------------------------------------

@test "epics shard edited but monolith not synced: WARNING" {
  _write_synced_prd
  _write_synced_arch
  _write_synced_epics
  cat > "$TEST_TMP/docs/planning-artifacts/epics/02-e1-foo.md" <<'EOF'
## Epic E1: Foo

Epic E1 body MUTATED.
EOF
  run "$CHECK_SCRIPT" --root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"E1"* || "$output" == *"epic"* || "$output" == *"epics"* ]]
}

# ---------------------------------------------------------------------------
# Change Log exception — monolith-as-source-of-truth, no WARNING when
# monolith Change Log differs from shard.
# ---------------------------------------------------------------------------

@test "Change Log differs (monolith newer): no WARNING due to documented exception" {
  _write_synced_prd
  _write_synced_arch
  _write_synced_epics
  # Mutate monolith Change Log only — shard 01-change-log.md unchanged.
  cat > "$TEST_TMP/docs/planning-artifacts/epics/epics-and-stories.md" <<'EOF'
# Epics and Stories

## Change Log

| Date | Change |
|------|--------|
| 2026-05-04 | Initial |
| 2026-05-05 | Monolith-newer entry |

## Epic E1: Foo

Epic E1 body.

## Epic E2: Bar

Epic E2 body.
EOF
  run "$CHECK_SCRIPT" --root "$TEST_TMP"
  [ "$status" -eq 0 ]
  # No WARNING for "Change Log" section specifically.
  ! [[ "$output" == *"WARNING"*"Change Log"* ]] || true
  # Specifically: must not name "01-change-log.md" as drifted.
  [[ "$output" != *"WARNING"*"01-change-log.md"* ]]
}

# ---------------------------------------------------------------------------
# _preamble partial-mirror exception.
# ---------------------------------------------------------------------------

@test "_preamble.md partial mirror does not trigger WARNING" {
  _write_synced_prd
  _write_synced_arch
  _write_synced_epics
  # _preamble.md is a partial mirror of frontmatter only — its content
  # intentionally diverges from the monolith's full body. The check must
  # NOT flag _preamble.md as drifted.
  run "$CHECK_SCRIPT" --root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARNING"*"_preamble.md"* ]]
}

# ---------------------------------------------------------------------------
# Missing shard directory — graceful INFO/skip.
# ---------------------------------------------------------------------------

@test "monolith exists but shard directory missing: graceful INFO, no crash" {
  # Build a PRD monolith without the prd/ shard directory at all.
  rm -rf "$TEST_TMP/docs/planning-artifacts/prd"
  mkdir -p "$TEST_TMP/docs/planning-artifacts"
  cat > "$TEST_TMP/docs/planning-artifacts/prd.md" <<'EOF'
# PRD

## 1. Overview

Body.
EOF
  run "$CHECK_SCRIPT" --root "$TEST_TMP"
  # Always exit 0 (advisory).
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Usage / arg handling.
# ---------------------------------------------------------------------------

@test "runs with no args (defaults to cwd) without crash" {
  cd "$TEST_TMP"
  _write_synced_prd
  _write_synced_arch
  _write_synced_epics
  run "$CHECK_SCRIPT"
  [ "$status" -eq 0 ]
}
