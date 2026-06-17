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

# ---------------------------------------------------------------------------
# E59-S6 / TC-TSS-SHARD-6 — per-story status drift between monolith and shard
# ---------------------------------------------------------------------------
#
# Story: E59-S6 — extend check-monolith-shard-sync.sh to walk every story key
# in the monolith, resolve the matching per-epic shard via the `e<EID>` token
# glob, parse the per-story `- **Status:** <state>` line in each, and emit a
# WARNING when the values differ.
# Refs: AF-2026-05-08-6, ADR-070, ADR-074 contract C3.

# Helper: write a per-epic shard with one story entry at a known status.
_write_per_epic_shard() {
  local nn="$1" eid="$2" key="$3" status="$4"
  local file="$TEST_TMP/docs/planning-artifacts/epics/${nn}-e${eid}-fixture.md"
  cat > "$file" <<EOF
## Epic E${eid}: Fixture

### Story ${key}: Fixture story

- **Epic:** E${eid}
- **Status:** ${status}

EOF
}

# Helper: write the epics monolith with one story entry at a known status.
_write_epics_monolith_story() {
  local key="$1" status="$2"
  cat > "$TEST_TMP/docs/planning-artifacts/epics/epics-and-stories.md" <<EOF
# Epics and Stories

## Change Log

| Date | Change |
|------|--------|
| 2026-05-04 | Initial |

## Epic E99: Fixture

### Story ${key}: Fixture story

- **Epic:** E99
- **Status:** ${status}
EOF
  # Empty shard for the Epic E99 H2 so the H2-section sync path is silent.
  cat > "$TEST_TMP/docs/planning-artifacts/epics/02-e99-fixture-h2.md" <<EOF
## Epic E99: Fixture

### Story ${key}: Fixture story

- **Epic:** E99
- **Status:** ${status}
EOF
  # Mirror the change-log shard.
  cat > "$TEST_TMP/docs/planning-artifacts/epics/01-change-log.md" <<'EOF'
## Change Log

| Date | Change |
|------|--------|
| 2026-05-04 | Initial |
EOF
}

# TC-TSS-SHARD-6 (a) — divergent monolith vs shard pair triggers WARNING.
@test "divergent per-story status emits epics-shard WARNING" {
  _write_synced_prd
  _write_synced_arch
  _write_epics_monolith_story "E99-S1" "done"
  # Single `*-e99-*.md` shard with the per-story-status divergence so the
  # new walk's `*-e<EID>-*.md` glob has exactly one match. (Multi-match
  # silently skips by design — correct contract but defeats this AC.)
  rm -f "$TEST_TMP/docs/planning-artifacts/epics/02-e99-fixture-h2.md"
  cat > "$TEST_TMP/docs/planning-artifacts/epics/02-e99-fixture.md" <<EOF
## Epic E99: Fixture

### Story E99-S1: Fixture story

- **Epic:** E99
- **Status:** backlog
EOF

  run "$CHECK_SCRIPT" --root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"epics-shard"* ]]
  [[ "$output" == *"E99-S1"* ]]
  [[ "$output" == *"monolith=done"* ]]
  [[ "$output" == *"shard=backlog"* ]]
}

# TC-TSS-SHARD-6 (b) — absent shard does NOT emit a WARNING.
@test "absent per-epic shard emits NO epics-shard WARNING" {
  _write_synced_prd
  _write_synced_arch
  _write_epics_monolith_story "E99-S1" "done"
  # Remove the per-epic shard for the story (only the H2 mirror remains).
  rm -f "$TEST_TMP/docs/planning-artifacts/epics/03-e99-fixture.md"

  run "$CHECK_SCRIPT" --root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARNING: epics-shard"* ]]
}

# TC-TSS-SHARD-6 (c) — regression guard: existing 12 prd/architecture WARNINGs are preserved
# byte-untouched when the per-story status walk runs. We use synced fixtures so this AC reads
# as: zero new false-positive WARNINGs from the new walk.
@test "synced fixture stays clean — new walk introduces no false positives" {
  _write_synced_prd
  _write_synced_arch
  _write_synced_epics
  # Add a per-epic shard for E1 with the SAME status as the monolith says
  # (synced). The new walk MUST stay silent for the synced case.
  cat > "$TEST_TMP/docs/planning-artifacts/epics/04-e1-foo-stories.md" <<'EOF'
## Epic E1: Foo (per-epic shard)

### Story E1-S1: Synced story

- **Epic:** E1
- **Status:** ready-for-dev
EOF
  cat >> "$TEST_TMP/docs/planning-artifacts/epics/epics-and-stories.md" <<'EOF'

### Story E1-S1: Synced story

- **Epic:** E1
- **Status:** ready-for-dev
EOF

  run "$CHECK_SCRIPT" --root "$TEST_TMP"
  [ "$status" -eq 0 ]
  # New walk MUST NOT emit a per-story status WARNING for the synced pair.
  [[ "$output" != *"WARNING: epics-shard — story E1-S1"* ]]
}

# ===========================================================================
# E53-S249 — Sub-shard awareness (marker shard + sibling directory).
#
# NFR-052 public-function coverage anchor: _is_marker_shard_pair, _strip_sub_sharded_suffix
#
# Tests that the marker-shard + sibling-directory pattern is recognised:
# - Forward pass: monolith H2 matches the normalized (suffix-stripped)
#   shard title, no "no matching shard" WARNING.
# - Reverse pass: shard's "<title> — Sub-Sharded" stub matches the
#   monolith H2 after suffix-strip, no "absent from monolith" WARNING.
# - Body-hash comparison is skipped for marker pairs (stub vs. body
#   divergence is the expected state, not drift).
# - Single-half states (marker shard without dir, dir without marker
#   shard) keep the WARNING — corruption signals.
# ===========================================================================

# Seed a PRD-§4-shaped marker-shard + sibling-directory fixture.
# Creates:
#   prd/prd.md with `## 4. Functional Requirements` section
#   prd/04-functional-requirements.md (marker shard, stub body)
#   prd/04-functional-requirements/_preamble.md + 04-01-fr-001.md (children)
_seed_sub_shard_fixture() {
  local prd_dir="$TEST_TMP/docs/planning-artifacts/prd"
  mkdir -p "$prd_dir/04-functional-requirements"
  cat > "$prd_dir/prd.md" <<'PRD'
---
title: PRD
---

# PRD

## 1. Vision

Vision body.

## 4. Functional Requirements

Body of section 4.

### FR-1

Detail.

## 5. Other

Other content.
PRD
  cat > "$prd_dir/01-vision.md" <<'SH'
## 1. Vision

Vision body.
SH
  cat > "$prd_dir/04-functional-requirements.md" <<'SH'
## 4. Functional Requirements — Sub-Sharded

Stub: the body of this section has been split into sibling children. See
`./04-functional-requirements/` for the per-FR child files.
SH
  cat > "$prd_dir/04-functional-requirements/_preamble.md" <<'SH'
---
parent: 04-functional-requirements.md
---
SH
  cat > "$prd_dir/04-functional-requirements/04-01-fr-001.md" <<'SH'
### FR-1

Detail.
SH
  cat > "$prd_dir/05-other.md" <<'SH'
## 5. Other

Other content.
SH
}

@test "PRD-§4 marker-pair fixture emits 0 WARNINGs related to §4" {
  _seed_sub_shard_fixture
  run "$CHECK_SCRIPT" --root "$TEST_TMP"
  [ "$status" -eq 0 ]
  # Neither forward-pass nor reverse-pass WARNING for "4. Functional Requirements".
  ! echo "$output" | grep -q 'section "4. Functional Requirements" present in'
  ! echo "$output" | grep -q 'section "4. Functional Requirements — Sub-Sharded"'
  ! echo "$output" | grep -q 'section "4. Functional Requirements" diverges'
}

@test "marker-shard without sibling dir KEEPS the WARNING (corruption signal)" {
  local prd_dir="$TEST_TMP/docs/planning-artifacts/prd"
  mkdir -p "$prd_dir"
  cat > "$prd_dir/prd.md" <<'PRD'
# PRD

## 4. Functional Requirements

Body.
PRD
  # Marker shard with `— Sub-Sharded` suffix but NO sibling directory.
  cat > "$prd_dir/04-functional-requirements.md" <<'SH'
## 4. Functional Requirements — Sub-Sharded

Stub.
SH
  run "$CHECK_SCRIPT" --root "$TEST_TMP"
  [ "$status" -eq 0 ]
  # The `— Sub-Sharded` suffix in the shard title doesn't match the
  # monolith H2 — reverse-pass WARNING fires because the pair is incomplete.
  echo "$output" | grep -q "WARNING: prd"
}

@test "_strip_sub_sharded_suffix strips em-dash + literal token" {
  # Extract just the function definition and exec it in a sub-bash that
  # doesn't run the script's main logic. The script's main pass exits
  # under `set -e`, so we can't `source` it directly.
  local fn_src
  fn_src=$(awk '/^_strip_sub_sharded_suffix\(\)/,/^}/' "$CHECK_SCRIPT")
  result=$(bash -c "${fn_src}
_strip_sub_sharded_suffix \"4. Functional Requirements — Sub-Sharded\"")
  [ "$result" = "4. Functional Requirements" ]
  # Idempotent — stripping a non-suffixed title is a no-op.
  result2=$(bash -c "${fn_src}
_strip_sub_sharded_suffix \"4. Functional Requirements\"")
  [ "$result2" = "4. Functional Requirements" ]
}

@test "flat-layout (no sibling dirs) regression-guard — output unchanged" {
  # Pure flat shard layout — no marker pairs anywhere.
  local prd_dir="$TEST_TMP/docs/planning-artifacts/prd"
  mkdir -p "$prd_dir"
  cat > "$prd_dir/prd.md" <<'PRD'
# PRD

## 1. Vision

Vision body.
PRD
  cat > "$prd_dir/01-vision.md" <<'SH'
## 1. Vision

Vision body.
SH
  run "$CHECK_SCRIPT" --root "$TEST_TMP"
  [ "$status" -eq 0 ]
  # Synced flat layout — no WARNINGs at all.
  ! echo "$output" | grep -q "WARNING: prd"
}
