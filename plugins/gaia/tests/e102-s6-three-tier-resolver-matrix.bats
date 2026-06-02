#!/usr/bin/env bats
# e102-s6-three-tier-resolver-matrix.bats
#
# Story: E102-S6 — /gaia-sprint-close retro-glob dual-path acceptance + the
# three-tier resolver covering all four artifact families (adversarial,
# sprint-plan, sprint-review, retrospective).
# Origin: AF-2026-05-24-2. Traces to: FR-536, ADR-119, TC-ASG-5.

load 'test_helper.bash'

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RESOLVER="$PLUGIN/scripts/lib/artifact-three-tier-resolve.sh"
  CLOSE_SH="$PLUGIN/skills/gaia-sprint-close/scripts/close.sh"
  # Per-test temp project root so the matrix can stage isolated layouts.
  TMP_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t e102s6)"
}

teardown() {
  rm -rf "$TMP_ROOT" 2>/dev/null || true
  common_teardown
}

stage_nested_only() {
  local family="$1" id="$2" stem="$3"
  local nested_dir flat_dir
  case "$family" in
    retro)        nested_dir="$TMP_ROOT/.gaia/artifacts/implementation-artifacts/retrospective"; flat_dir="$TMP_ROOT/.gaia/artifacts/implementation-artifacts" ;;
    sprint-plan)  nested_dir="$TMP_ROOT/.gaia/artifacts/implementation-artifacts/sprint-plan"; flat_dir="$TMP_ROOT/.gaia/artifacts/implementation-artifacts" ;;
    sprint-review) nested_dir="$TMP_ROOT/.gaia/artifacts/implementation-artifacts/sprint-review"; flat_dir="$TMP_ROOT/.gaia/artifacts/implementation-artifacts" ;;
    adversarial)  nested_dir="$TMP_ROOT/.gaia/artifacts/planning-artifacts/adversarial"; flat_dir="$TMP_ROOT/.gaia/artifacts/planning-artifacts" ;;
  esac
  mkdir -p "$nested_dir"
  touch "$nested_dir/$stem.md"
}

stage_flat_only() {
  local family="$1" id="$2" stem="$3"
  local flat_dir
  case "$family" in
    retro|sprint-plan|sprint-review) flat_dir="$TMP_ROOT/.gaia/artifacts/implementation-artifacts" ;;
    adversarial) flat_dir="$TMP_ROOT/.gaia/artifacts/planning-artifacts" ;;
  esac
  mkdir -p "$flat_dir"
  touch "$flat_dir/$stem.md"
}

stage_both() {
  stage_nested_only "$1" "$2" "$3"
  stage_flat_only "$1" "$2" "$3"
}

# ---------------------------------------------------------------------------
# Retrospective family — Tier 1/2/3 + env-var override
# ---------------------------------------------------------------------------

@test "TC-ASG-5-retro-nested: only nested present → resolver returns nested dir" {
  stage_nested_only retro sprint-99 "retrospective-sprint-99-2026-05-24"
  out="$(bash "$RESOLVER" --family retro --id sprint-99 --project-root "$TMP_ROOT")"
  [[ "$out" == "$TMP_ROOT/.gaia/artifacts/implementation-artifacts/retrospective" ]]
}

@test "TC-ASG-5-retro-flat: only legacy flat present → resolver returns legacy dir" {
  stage_flat_only retro sprint-99 "retrospective-sprint-99-2026-05-24"
  out="$(bash "$RESOLVER" --family retro --id sprint-99 --project-root "$TMP_ROOT")"
  [[ "$out" == "$TMP_ROOT/.gaia/artifacts/implementation-artifacts" ]]
}

@test "TC-ASG-5-retro-both: both present → nested wins (Tier 3 dominates)" {
  stage_both retro sprint-99 "retrospective-sprint-99-2026-05-24"
  out="$(bash "$RESOLVER" --family retro --id sprint-99 --project-root "$TMP_ROOT")"
  [[ "$out" == "$TMP_ROOT/.gaia/artifacts/implementation-artifacts/retrospective" ]]
}

@test "TC-ASG-5-retro-env: RETRO_DIR override wins (Tier 1)" {
  stage_both retro sprint-99 "retrospective-sprint-99-2026-05-24"
  RETRO_DIR="/tmp/custom-retro-dir" bash -c "
    $RESOLVER --family retro --id sprint-99 --project-root '$TMP_ROOT'
  " > /tmp/e102s6_retro_env.out
  read out < /tmp/e102s6_retro_env.out
  [[ "$out" == "/tmp/custom-retro-dir" ]]
}

# ---------------------------------------------------------------------------
# Sprint-plan family
# ---------------------------------------------------------------------------

@test "TC-ASG-5-plan-nested: only nested present → nested dir" {
  stage_nested_only sprint-plan sprint-99 "sprint-99-plan"
  out="$(bash "$RESOLVER" --family sprint-plan --id sprint-99 --project-root "$TMP_ROOT")"
  [[ "$out" == "$TMP_ROOT/.gaia/artifacts/implementation-artifacts/sprint-plan" ]]
}

@test "TC-ASG-5-plan-flat: only legacy flat present → legacy dir" {
  stage_flat_only sprint-plan sprint-99 "sprint-99-plan"
  out="$(bash "$RESOLVER" --family sprint-plan --id sprint-99 --project-root "$TMP_ROOT")"
  [[ "$out" == "$TMP_ROOT/.gaia/artifacts/implementation-artifacts" ]]
}

@test "TC-ASG-5-plan-both: both present → nested wins" {
  stage_both sprint-plan sprint-99 "sprint-99-plan"
  out="$(bash "$RESOLVER" --family sprint-plan --id sprint-99 --project-root "$TMP_ROOT")"
  [[ "$out" == "$TMP_ROOT/.gaia/artifacts/implementation-artifacts/sprint-plan" ]]
}

@test "TC-ASG-5-plan-env: SPRINT_PLAN_DIR override wins" {
  stage_both sprint-plan sprint-99 "sprint-99-plan"
  out="$(SPRINT_PLAN_DIR="/tmp/custom-plan-dir" bash "$RESOLVER" --family sprint-plan --id sprint-99 --project-root "$TMP_ROOT")"
  [[ "$out" == "/tmp/custom-plan-dir" ]]
}

# ---------------------------------------------------------------------------
# Sprint-review family
# ---------------------------------------------------------------------------

@test "TC-ASG-5-review-nested: only nested present → nested dir" {
  stage_nested_only sprint-review sprint-99 "sprint-review-sprint-99-2026-05-24"
  out="$(bash "$RESOLVER" --family sprint-review --id sprint-99 --project-root "$TMP_ROOT")"
  [[ "$out" == "$TMP_ROOT/.gaia/artifacts/implementation-artifacts/sprint-review" ]]
}

@test "TC-ASG-5-review-flat: only legacy flat present → legacy dir" {
  stage_flat_only sprint-review sprint-99 "sprint-review-sprint-99-2026-05-24"
  out="$(bash "$RESOLVER" --family sprint-review --id sprint-99 --project-root "$TMP_ROOT")"
  [[ "$out" == "$TMP_ROOT/.gaia/artifacts/implementation-artifacts" ]]
}

@test "TC-ASG-5-review-both: both present → nested wins" {
  stage_both sprint-review sprint-99 "sprint-review-sprint-99-2026-05-24"
  out="$(bash "$RESOLVER" --family sprint-review --id sprint-99 --project-root "$TMP_ROOT")"
  [[ "$out" == "$TMP_ROOT/.gaia/artifacts/implementation-artifacts/sprint-review" ]]
}

@test "TC-ASG-5-review-env: SPRINT_REVIEW_DIR override wins" {
  stage_both sprint-review sprint-99 "sprint-review-sprint-99-2026-05-24"
  out="$(SPRINT_REVIEW_DIR="/tmp/custom-review-dir" bash "$RESOLVER" --family sprint-review --id sprint-99 --project-root "$TMP_ROOT")"
  [[ "$out" == "/tmp/custom-review-dir" ]]
}

# ---------------------------------------------------------------------------
# Adversarial family
# ---------------------------------------------------------------------------

@test "TC-ASG-5-adv-nested: only nested present → nested dir" {
  stage_nested_only adversarial prd "adversarial-review-prd-2026-05-24"
  out="$(bash "$RESOLVER" --family adversarial --id prd --project-root "$TMP_ROOT")"
  [[ "$out" == "$TMP_ROOT/.gaia/artifacts/planning-artifacts/adversarial" ]]
}

@test "TC-ASG-5-adv-flat: only legacy flat present → legacy dir" {
  stage_flat_only adversarial prd "adversarial-review-prd-2026-05-24"
  out="$(bash "$RESOLVER" --family adversarial --id prd --project-root "$TMP_ROOT")"
  [[ "$out" == "$TMP_ROOT/.gaia/artifacts/planning-artifacts" ]]
}

@test "TC-ASG-5-adv-both: both present → nested wins" {
  stage_both adversarial prd "adversarial-review-prd-2026-05-24"
  out="$(bash "$RESOLVER" --family adversarial --id prd --project-root "$TMP_ROOT")"
  [[ "$out" == "$TMP_ROOT/.gaia/artifacts/planning-artifacts/adversarial" ]]
}

@test "TC-ASG-5-adv-env: ADVERSARIAL_DIR override wins" {
  stage_both adversarial prd "adversarial-review-prd-2026-05-24"
  out="$(ADVERSARIAL_DIR="/tmp/custom-adv-dir" bash "$RESOLVER" --family adversarial --id prd --project-root "$TMP_ROOT")"
  [[ "$out" == "/tmp/custom-adv-dir" ]]
}

# ---------------------------------------------------------------------------
# /gaia-sprint-close integration: close.sh wires the resolver
# ---------------------------------------------------------------------------

@test "TC-ASG-5-close-wires-resolver: close.sh sources or invokes the resolver helper" {
  [ -f "$CLOSE_SH" ]
  grep -qF "artifact-three-tier-resolve.sh" "$CLOSE_SH"
}
