#!/usr/bin/env bats
# e83-s4-adr-063-amendment-alignment.bats — verification matrix for E83-S4
#
# Story: E83-S4 — ADR-063 in-place amendment + traceability matrix regeneration
# Refs:  AC1, AC2, AC3, AC4, AC5, AC6 + Test Scenarios 1..7
#
# Verifies that the AF-2026-05-09-5 cascade artifacts are aligned at the four
# canonical locations (monolith ADR row + monolith ADR detail + shard ADR row
# + shard ADR detail) and that the traceability matrix §19.4 / §19.4.1 are
# present and complete.
#
# This is a verification test, not a synthesis test — it asserts against the
# real project-root artifacts authored during the AF-2026-05-09-5 cascade.
# PROJECT_ROOT is resolved from $GAIA_PROJECT_ROOT or, when unset, walked up
# from the CWD until the docs/planning-artifacts/architecture/architecture.md
# anchor file is found.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

# _resolve_project_root — find the project root by walking up from CWD looking
# for docs/planning-artifacts/architecture/architecture.md. Honors
# $GAIA_PROJECT_ROOT override for CI environments.
_resolve_project_root() {
  if [ -n "${GAIA_PROJECT_ROOT:-}" ] && [ -f "$GAIA_PROJECT_ROOT/docs/planning-artifacts/architecture/architecture.md" ]; then
    printf '%s\n' "$GAIA_PROJECT_ROOT"
    return 0
  fi
  local dir
  dir="$(pwd)"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/docs/planning-artifacts/architecture/architecture.md" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

setup() {
  common_setup
  PROJECT_ROOT="$(_resolve_project_root)" || skip "project-root docs/ not resolvable from CWD"
  export PROJECT_ROOT
  ARCH_MONOLITH="$PROJECT_ROOT/docs/planning-artifacts/architecture/architecture.md"
  ARCH_SHARD_DECISIONS="$PROJECT_ROOT/docs/planning-artifacts/architecture/02-2-architecture-decisions.md"
  ARCH_SHARD_DETAIL="$PROJECT_ROOT/docs/planning-artifacts/architecture/12-12-adr-detail-records.md"
  TRACE="$PROJECT_ROOT/docs/test-artifacts/strategy/traceability-matrix.md"
  ASSESSMENT="$PROJECT_ROOT/docs/planning-artifacts/assessment-AF-2026-05-09-5.md"
  export ARCH_MONOLITH ARCH_SHARD_DECISIONS ARCH_SHARD_DETAIL TRACE ASSESSMENT
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC1 / Test Scenario 1 — ADR-063 row sync (monolith vs shard)
# ---------------------------------------------------------------------------

@test "AC1: ADR-063 row at monolith L126 == shard 02-2 L66 (bytewise)" {
  [ -f "$ARCH_MONOLITH" ] || skip "monolith missing"
  [ -f "$ARCH_SHARD_DECISIONS" ] || skip "decisions shard missing"
  run diff <(sed -n '126p' "$ARCH_MONOLITH") <(sed -n '66p' "$ARCH_SHARD_DECISIONS")
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "AC1: monolith ADR-063 row contains AF-2026-05-09-5 amendment marker" {
  run grep -F '+amendment AF-2026-05-09-5: script-side fail-closed enforcement primitive' "$ARCH_MONOLITH"
  [ "$status" -eq 0 ]
}

@test "AC1: shard 02-2 ADR-063 row contains AF-2026-05-09-5 amendment marker" {
  run grep -F '+amendment AF-2026-05-09-5: script-side fail-closed enforcement primitive' "$ARCH_SHARD_DECISIONS"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC2 / Test Scenario 2 — ADR-063 detail block sync (monolith vs shard)
# ---------------------------------------------------------------------------

@test "AC2: ADR-063 detail block bytewise-identical between monolith and shard" {
  local mono_block shard_block
  mono_block="$(awk '/^### ADR-063/,/^### ADR-064/' "$ARCH_MONOLITH")"
  shard_block="$(awk '/^### ADR-063/,/^### ADR-064/' "$ARCH_SHARD_DETAIL")"
  [ -n "$mono_block" ]
  [ -n "$shard_block" ]
  run diff <(printf '%s\n' "$mono_block") <(printf '%s\n' "$shard_block")
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "AC2: ADR-063 detail block contains AF-2026-05-09-5 amendment heading" {
  run grep -F 'AF-2026-05-09-5 amendment (2026-05-09): Script-side fail-closed enforcement primitive.' "$ARCH_MONOLITH"
  [ "$status" -eq 0 ]
}

@test "AC2: ADR-063 detail block names all five amendment subsections" {
  for needle in 'Amendment context' 'Amendment decision' 'Pattern.' 'Amendment consequences' 'Implementing stories.'; do
    run grep -F "$needle" "$ARCH_MONOLITH"
    [ "$status" -eq 0 ] || { echo "monolith missing: $needle"; return 1; }
    run grep -F "$needle" "$ARCH_SHARD_DETAIL"
    [ "$status" -eq 0 ] || { echo "shard missing: $needle"; return 1; }
  done
}

# ---------------------------------------------------------------------------
# AC3 / Test Scenarios 3 — §19.4 traceability table present
# ---------------------------------------------------------------------------

@test "AC3: §19.4 section header present in traceability-matrix.md" {
  run grep -F '## §19.4 AF-2026-05-09-5 / E83' "$TRACE"
  [ "$status" -eq 0 ]
}

@test "AC3: §19.4 maps ADR-063 amendment to TC-VFC-1..TC-VFC-12" {
  for tc in TC-VFC-1 TC-VFC-2 TC-VFC-3 TC-VFC-4 TC-VFC-5 TC-VFC-6 TC-VFC-7 TC-VFC-8 TC-VFC-9 TC-VFC-10 TC-VFC-11 TC-VFC-12; do
    run grep -F "$tc" "$TRACE"
    [ "$status" -eq 0 ] || { echo "missing TC ID: $tc"; return 1; }
  done
}

@test "AC3: §19.4 lists all six E83 stories" {
  for sk in 'E83-S1 ' 'E83-S2 ' 'E83-S3 ' 'E83-S4 ' 'E83-S5 ' 'E83-S6 '; do
    run grep -F "$sk" "$TRACE"
    [ "$status" -eq 0 ] || { echo "missing story key: $sk"; return 1; }
  done
}

@test "AC3: §19.4 maps action items AI-2026-05-09-10/11/12" {
  for ai in 'AI-2026-05-09-10' 'AI-2026-05-09-11' 'AI-2026-05-09-12'; do
    run grep -F "$ai" "$TRACE"
    [ "$status" -eq 0 ] || { echo "missing action item: $ai"; return 1; }
  done
}

@test "AC3: §19.4 maps three user memory rules" {
  for rule in 'feedback_priority_flag_never_auto_set.md' 'feedback_askuserquestion_under_automode.md' 'feedback_no_per_machine_settings_fixes.md'; do
    run grep -F "$rule" "$TRACE"
    [ "$status" -eq 0 ] || { echo "missing memory rule: $rule"; return 1; }
  done
}

# ---------------------------------------------------------------------------
# AC4 / Test Scenario 4 — §19.4.1 Coverage Notes
# ---------------------------------------------------------------------------

@test "AC4: §19.4.1 Coverage Notes header present" {
  run grep -F '### 19.4.1 Coverage Notes' "$TRACE"
  [ "$status" -eq 0 ]
}

@test "AC4: §19.4.1 documents MUST-PASS gates" {
  run grep -F 'MUST-PASS gates' "$TRACE"
  [ "$status" -eq 0 ]
  for gate in 'TC-VFC-1' 'TC-VFC-2' 'TC-VFC-6' 'TC-VFC-8' 'TC-VFC-10' 'TC-VFC-12'; do
    run grep -F "$gate" "$TRACE"
    [ "$status" -eq 0 ] || { echo "missing MUST-PASS gate: $gate"; return 1; }
  done
}

@test "AC4: §19.4.1 documents strict-sequential topology" {
  run grep -F 'Topology:' "$TRACE"
  [ "$status" -eq 0 ]
  run grep -F 'E83-S1' "$TRACE"
  [ "$status" -eq 0 ]
}

@test "AC4: §19.4.1 documents coverage delta (411->417 / 56->57 / ~1082->~1094)" {
  run grep -F 'Coverage Summary delta' "$TRACE"
  [ "$status" -eq 0 ]
  run grep -F '411 → 417' "$TRACE"
  [ "$status" -eq 0 ]
  run grep -F '56 → 57' "$TRACE"
  [ "$status" -eq 0 ]
  run grep -F '~1082' "$TRACE"
  [ "$status" -eq 0 ]
  run grep -F '~1094' "$TRACE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC5 / Test Scenario 5 — Monolith-shard sync — no NEW drift naming
# architecture.md or epics-and-stories.md
# ---------------------------------------------------------------------------

@test "AC5: zero new architecture WARNINGs beyond pre-existing 2/12/13/16/10" {
  local script="$PROJECT_ROOT/gaia-framework/plugins/gaia/scripts/check-monolith-shard-sync.sh"
  [ -x "$script" ] || skip "check-monolith-shard-sync.sh not present"
  cd "$PROJECT_ROOT"
  run "$script"
  # Script always exits 0 (advisory).
  [ "$status" -eq 0 ]
  # Pre-existing arch WARNINGs documented in assessment-AF-2026-05-09-5.md §13:
  #   sections 2, 12, 13, 16 (Version History)
  # Plus pre-existing E53-S235 sub-shard WARNING for section 10 (predates this AF).
  # Anything outside this set naming architecture is NEW drift introduced by AF-5.
  local arch_warnings
  arch_warnings="$(printf '%s\n' "$output" | grep '^WARNING: architecture' || true)"
  # Whitelist patterns:
  local unexpected
  unexpected="$(printf '%s\n' "$arch_warnings" | grep -v 'section "2\.' | grep -v 'section "12\.' | grep -v 'section "13\.' | grep -v 'section "Version History"' | grep -v 'section "10\. Target Architecture (Gaps) — Sub-Sharded"' || true)"
  if [ -n "$unexpected" ]; then
    echo "Unexpected architecture WARNINGs (NEW drift):"
    printf '%s\n' "$unexpected"
    return 1
  fi
}

@test "AC5: zero NEW WARNINGs naming epics-and-stories.md" {
  local script="$PROJECT_ROOT/gaia-framework/plugins/gaia/scripts/check-monolith-shard-sync.sh"
  [ -x "$script" ] || skip "check-monolith-shard-sync.sh not present"
  cd "$PROJECT_ROOT"
  run "$script"
  [ "$status" -eq 0 ]
  # Per assessment §13: pre-existing E53-S248, E76-S9, E76-S10 status divergences
  # are in the per-epic shards, not in the monolith epics-and-stories.md, and
  # the script may emit no epics-shard WARNINGs at all on a clean run.
  # AF-5 introduces zero new drift here.
  local epics_new
  epics_new="$(printf '%s\n' "$output" | grep '^WARNING: epics' | grep -v 'E53-S248\|E76-S9\|E76-S10' || true)"
  [ -z "$epics_new" ]
}

# ---------------------------------------------------------------------------
# AC6 / Test Scenario 6 — AF-1 audit note present, names E83-S6
# ---------------------------------------------------------------------------

@test "AC6: AF-2026-05-09-1 cascade narrative carries audit note flagging E83-S6" {
  run grep -F 'AF-2026-05-09-1 cascade narrative' "$TRACE"
  [ "$status" -eq 0 ]
  # The audit note text immediately follows the narrative line.
  local note
  note="$(grep -F 'AF-2026-05-09-1 cascade narrative' "$TRACE")"
  printf '%s\n' "$note" | grep -F 'Audit note' >/dev/null
  printf '%s\n' "$note" | grep -F 'E83-S6' >/dev/null
  printf '%s\n' "$note" | grep -F 'AF-2026-05-09-5' >/dev/null
}

# ---------------------------------------------------------------------------
# Test Scenario 7 — No new ADR row allocated for AF-2026-05-09-5
# (in-place amendment honored per ADR-083 precedent)
# ---------------------------------------------------------------------------

@test "TS7: exactly one ADR row references AF-2026-05-09-5 (the amended ADR-063)" {
  local count
  count="$(grep -c '^| ADR-[0-9]\+.*AF-2026-05-09-5' "$ARCH_MONOLITH" || true)"
  [ "$count" -eq 1 ]
  # And it MUST be ADR-063 (in-place amendment, not a new ADR number).
  run grep '^| ADR-063 .*AF-2026-05-09-5' "$ARCH_MONOLITH"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Cross-cutting: assessment-doc cross-references the four canonical locations
# ---------------------------------------------------------------------------

@test "ASSESSMENT: cross-references monolith L126 + shard L66 + monolith L7286 + shard L821" {
  [ -f "$ASSESSMENT" ] || skip "assessment-doc missing"
  for needle in 'L126' 'L66' 'L7286' 'L821' '§19.4' '02-2-architecture-decisions.md' '12-12-adr-detail-records.md'; do
    run grep -F "$needle" "$ASSESSMENT"
    [ "$status" -eq 0 ] || { echo "assessment missing: $needle"; return 1; }
  done
}
