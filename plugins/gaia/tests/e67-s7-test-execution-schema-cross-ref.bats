#!/usr/bin/env bats
# E67-S7 — test_execution schema cross-ref scanner
#
# Codifies the AC3 acceptance criterion: zero `test_execution.{context}.{tier}`
# mentions remain in normative spec text after sprint-38 reconciliation.
#
# Normative scope:
#   - docs/planning-artifacts/prd/         (PRD shards + merged prd.md)
#   - docs/planning-artifacts/architecture/ (architecture shards + merged
#     architecture.md, ADRs)
#   - docs/test-artifacts/strategy/        (test-plan.md, traceability-matrix.md)
#
# Out of normative scope (audit trail / immutable / done-story records):
#   - docs/planning-artifacts/decisions/   (source-report — immutable)
#   - docs/planning-artifacts/epics/       (epic specs, story-meta references)
#   - docs/implementation-artifacts/       (story files, triage reports,
#     tech-debt dashboards, sprint-status, story-index)
#
# The scanner also asserts the canonical concrete-schema form
# `test_execution.tier_{1,2,3}.placement` is present in PRD §4.38.2 / FR-RSV2-11
# so the reconciliation note is anchored where readers expect it.

setup() {
  # Resolve the project root by walking up from the test file until we find
  # docs/planning-artifacts/. The test file lives at
  # {project_root}/gaia-framework/plugins/gaia/tests/*.bats, so the project root
  # is four levels up. If docs/planning-artifacts/ is not present (e.g., when
  # the plugin is consumed standalone outside a project), the test self-skips.
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../../.." && pwd)"
  if [ ! -d "$PROJECT_ROOT/docs/planning-artifacts" ]; then
    skip "project docs not present in this checkout (resolved root: $PROJECT_ROOT)"
  fi

  # Divergent schema-form patterns — any of these used as a config key indicates
  # an unreconciled `test_execution.{context}.{tier}` shape. The canonical form
  # is `test_execution.tier_{1,2,3}.placement` (FR-RSV2-11).
  DIVERGENT_RE='test_execution\.{context}\.{tier}\|test_execution\.local\.\|test_execution\.ci_pre_merge\.\|test_execution\.ci_post_merge\.\|test_execution\.post_deploy\.'

  # Lines that DECLARE the divergent form invalid (the canonical-prohibition
  # note added by E67-S7 itself) are filtered out — they are documentation,
  # not usage.
  PROHIBITION_FILTER='is NOT a valid'
}

# scan_for_divergent_usage <dir> — run the divergent-pattern scanner against
# <dir>, filtering out the canonical prohibition note. Captures any remaining
# match into BATS' $output for an emptiness assertion.
scan_for_divergent_usage() {
  local dir="$1"
  run bash -c "grep -rn '$DIVERGENT_RE' '$dir' | grep -v '$PROHIBITION_FILTER' || true"
}

@test "E67-S7 AC3: zero test_execution.{context}.{tier} hits in normative PRD text" {
  scan_for_divergent_usage "$PROJECT_ROOT/docs/planning-artifacts/prd/"
  [ -z "$output" ]
}

@test "E67-S7 AC3: zero test_execution.{context}.{tier} hits in test-plan / traceability" {
  scan_for_divergent_usage "$PROJECT_ROOT/docs/test-artifacts/strategy/"
  [ -z "$output" ]
}

@test "E67-S7 AC1: canonical concrete schema documented in FR-RSV2-11 shard" {
  shard="$PROJECT_ROOT/docs/planning-artifacts/prd/04-functional-requirements/39-4-38-gaia-review-system-v2-three-tier-pipeline-tool-adapter-framework-layered-ru.md"
  [ -f "$shard" ]
  run grep -F 'test_execution.tier_' "$shard"
  [ "$status" -eq 0 ]
}

@test "E67-S7 AC1: canonical concrete schema documented in merged prd.md" {
  monolith="$PROJECT_ROOT/docs/planning-artifacts/prd/prd.md"
  [ -f "$monolith" ]
  run grep -F 'test_execution.tier_' "$monolith"
  [ "$status" -eq 0 ]
}

@test "E67-S7 AC4: traceability matrix has an E67-S7 row referencing the reconciliation" {
  matrix="$PROJECT_ROOT/docs/test-artifacts/strategy/traceability-matrix.md"
  [ -f "$matrix" ]
  run grep -F 'E67-S7' "$matrix"
  [ "$status" -eq 0 ]
}
