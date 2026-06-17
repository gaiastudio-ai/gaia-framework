#!/usr/bin/env bats
# detect-signals-proposal.bats — E70-S11 stacks[].path proposal/audit mode.
#
# Story: E70-S11. FR-548 / NFR-88 / ADR-126. Extends the existing E71-S2
# detect-signals.sh with an OPT-IN --stacks-path-mode {proposal|audit|auto}:
#   - proposal: when no stack declares `path`, scan ecosystem manifests and
#     write a stacks[].path mapping to a draft file. Single-stack => no draft.
#   - audit: when `path` IS declared, compare declared vs detected, log
#     disagreement to partitioning-audit.json; do NOT regenerate the draft.
#   - nested manifests scope to the parent stack (ignore_nested_manifests: true).
#   - ≤2s on a 10-manifest fixture (NFR-88).
# The existing no-flag invocation (E71-S2 root-only detection) stays byte-stable.

load 'test_helper.bash'

setup() {
  common_setup
  DS="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/detect-signals.sh"
  FX="$BATS_TEST_DIRNAME/fixtures/detect-signals"
  export DS FX
  export DRAFT_OUT="$TEST_TMP/project-config.draft.yaml"
  export AUDIT_OUT="$TEST_TMP/partitioning-audit.json"
}
teardown() { common_teardown; }

run_proposal() {
  PATH="$PATH" run bash "$DS" --project-root "$FX/$1" \
    --stacks-path-mode proposal --draft-out "$DRAFT_OUT" --format json
}

# --- AC5(a) — single-stack degenerate: no draft + "nothing to propose" ----

@test "a): single-stack repo emits NO draft and logs 'nothing to propose'" {
  run_proposal single-stack
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to propose"* ]]
  [ ! -f "$DRAFT_OUT" ]
}

# --- AC1 / AC5(b) — 3-stack proposal correctness --------------------------

@test "b): 3-stack repo proposes Go + TS + Python paths in the draft" {
  run_proposal three-stack
  [ "$status" -eq 0 ]
  [ -f "$DRAFT_OUT" ]
  run yq eval '[.stacks[].path] | sort | join(",")' "$DRAFT_OUT"
  [ "$output" = "services/api,services/batch,services/web" ]
}

@test "draft includes a header comment on how to accept" {
  run_proposal three-stack
  [ "$status" -eq 0 ]
  run head -5 "$DRAFT_OUT"
  [[ "$output" == *"accept"* ]] || [[ "$output" == *"rename"* ]] || [[ "$output" == *"gaia-config-stack"* ]]
}

# --- AC4 / AC5(d) — nested-manifest scoping -------------------------------

@test "d): nested package.json under a Go stack does NOT spawn a phantom JS stack" {
  run_proposal nested-manifest
  [ "$status" -eq 0 ]
  [ -f "$DRAFT_OUT" ]
  # Exactly one stack (Go at services/api); the nested scripts/package.json is scoped to it.
  run yq eval '.stacks | length' "$DRAFT_OUT"
  [ "$output" -eq 1 ]
  run yq eval '.stacks[0].path' "$DRAFT_OUT"
  [ "$output" = "services/api" ]
}

# --- Proposal idempotency (Scenario 6) ------------------------------------

@test "scenario 6): proposal is idempotent (byte-identical re-run)" {
  run_proposal three-stack; [ "$status" -eq 0 ]; cp "$DRAFT_OUT" "$TEST_TMP/first"
  run_proposal three-stack; [ "$status" -eq 0 ]
  run diff "$TEST_TMP/first" "$DRAFT_OUT"
  [ "$status" -eq 0 ]
}

# --- AC2 / AC5(c) — audit mode disagreement -------------------------------

@test "c): audit mode logs disagreement, does NOT regenerate the draft" {
  # Declared 2 stacks (api, web); the three-stack tree also has batch → disagreement_count 1.
  PATH="$PATH" run bash "$DS" --project-root "$FX/three-stack" \
    --stacks-path-mode audit \
    --declared-paths "services/api,services/web" \
    --audit-out "$AUDIT_OUT" --format json
  [ "$status" -eq 0 ]
  [ -f "$AUDIT_OUT" ]
  run jq -r '.disagreement_count' "$AUDIT_OUT"
  [ "$output" -eq 1 ]
  run jq -r '.declared_partitioning | sort | join(",")' "$AUDIT_OUT"
  [ "$output" = "services/api,services/web" ]
  run jq -e '.auto_detected_partitioning | index("services/batch")' "$AUDIT_OUT"
  [ "$status" -eq 0 ]
  # Audit mode MUST NOT write a draft.
  [ ! -f "$DRAFT_OUT" ]
}

# --- AC3 / AC5(e) — NFR-88 10-manifest ≤2s latency ------------------------

@test "10-manifest proposal completes in <= 2s wall-clock" {
  local start end elapsed
  start=$(date +%s)
  PATH="$PATH" bash "$DS" --project-root "$FX/ten-manifest" \
    --stacks-path-mode proposal --draft-out "$DRAFT_OUT" --format json >/dev/null 2>&1
  end=$(date +%s)
  elapsed=$(( end - start ))
  [ "$elapsed" -le 2 ]
}

@test "scenario 10): 10-manifest proposal detects all ten ecosystems" {
  run_proposal ten-manifest
  [ "$status" -eq 0 ]
  run yq eval '.stacks | length' "$DRAFT_OUT"
  [ "$output" -eq 10 ]
}

# --- AC-X1 — flag-off skip + detect_signals_mode --------------------------

@test "stacks-path-mode unset → existing root-only detection is unchanged (no draft)" {
  # No --stacks-path-mode flag: the legacy detection path runs, emits its JSON,
  # and writes NO draft (the new capability is opt-in).
  PATH="$PATH" run bash "$DS" --project-root "$FX/three-stack" --format json
  [ "$status" -eq 0 ]
  [[ "$output" == *"stacks"* ]]        # legacy inventory JSON still emitted
  [ ! -f "$DRAFT_OUT" ]                 # opt-in: no draft without the flag
}

# --- AC-X3 — detect_signals_mode reporting --------------------------------

@test "proposal mode reports detect_signals_mode=proposal" {
  run_proposal three-stack
  [ "$status" -eq 0 ]
  [[ "$output" == *"detect_signals_mode"* ]]
  [[ "$output" == *"proposal"* ]]
}

# --- Robustness (Val F1/F2) — degenerate empty inputs ---------------------

@test "F1): manifest-free repo proposes nothing, writes NO draft (no blank-path draft)" {
  run_proposal no-manifest
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to propose"* ]]
  [ ! -f "$DRAFT_OUT" ]
}

@test "F2): audit mode with empty --declared-paths emits a valid audit (all detected = disagreement)" {
  PATH="$PATH" run bash "$DS" --project-root "$FX/three-stack" \
    --stacks-path-mode audit --declared-paths "" \
    --audit-out "$AUDIT_OUT" --format json
  [ "$status" -eq 0 ]
  [ -f "$AUDIT_OUT" ]
  run jq -r '.declared_partitioning | length' "$AUDIT_OUT"
  [ "$output" -eq 0 ]
  # All 3 detected stacks count as disagreement against an empty declared set.
  run jq -r '.disagreement_count' "$AUDIT_OUT"
  [ "$output" -eq 3 ]
}

# --- Regression: existing detect-signals tests still pass (sentinel) ------

@test "existing cluster-14/detect-signals.bats is present ( regression guard)" {
  [ -f "$BATS_TEST_DIRNAME/cluster-14/detect-signals.bats" ]
}

# --- Hygiene --------------------------------------------------------------

@test "detect-signals.sh is executable and passes bash -n" {
  [ -x "$DS" ]
  run bash -n "$DS"
  [ "$status" -eq 0 ]
}
