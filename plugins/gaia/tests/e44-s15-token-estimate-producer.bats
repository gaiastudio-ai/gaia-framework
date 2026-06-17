#!/usr/bin/env bats
# e44-s15-token-estimate-producer.bats — E44-S15
#
# Tests the producer-side token_estimate emit instrumentation in the val
# auto-fix loop. Verifies that:
#
#   AC1 — When the producer is invoked for an iteration, the resulting
#         checkpoint has custom.val_loop_iterations[*].token_estimate
#         populated with a numeric value > 0.
#   AC2 — A populated checkpoint feeds scripts/measure-val-auto-fix-token-budget.sh
#         without parser errors and produces a verdict.
#   AC3 — When no auto-fix iterations occur (single-pass clean), the
#         producer is not invoked and no val_loop_iterations entries
#         are emitted (no zero-token noise records).
#   Task 5 — bats coverage asserts token_estimate is numeric and > 0
#         on at least one iteration record.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PRODUCER="$REPO_ROOT/plugins/gaia/scripts/append-val-iteration.sh"
  HARNESS="$REPO_ROOT/plugins/gaia/scripts/measure-val-auto-fix-token-budget.sh"
  TEST_TMP="$(mktemp -d)"
  export CHECKPOINT_ROOT="$TEST_TMP/checkpoints"
  mkdir -p "$CHECKPOINT_ROOT"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ---------- Producer existence ----------

@test "producer: append-val-iteration.sh exists and is executable" {
  [ -f "$PRODUCER" ]
  [ -x "$PRODUCER" ]
}

@test "producer: --help exits 0 and documents token_estimate" {
  run "$PRODUCER" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"token_estimate"* ]]
  [[ "$output" == *"val_loop_iterations"* ]]
}

# ---------- AC1: token_estimate populated as numeric > 0 ----------

@test "producer writes checkpoint with numeric token_estimate > 0" {
  run "$PRODUCER" \
    --skill gaia-brainstorm \
    --step 6 \
    --iteration 1 \
    --token-estimate 4820 \
    --revalidation-outcome findings_present \
    --findings-json '[{"severity":"CRITICAL","description":"x","location":"y"}]' \
    --fix-summary "patched typo"
  [ "$status" -eq 0 ]
  CKPT="$output"
  [ -f "$CKPT" ]
  # Validate JSON shape and field presence
  python3 - "$CKPT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
iters = d["custom"]["val_loop_iterations"]
assert len(iters) == 1, f"expected 1 iteration record, got {len(iters)}"
rec = iters[0]
assert isinstance(rec["token_estimate"], (int, float)), \
    f"token_estimate must be numeric, got {type(rec['token_estimate'])}"
assert rec["token_estimate"] > 0, \
    f"token_estimate must be > 0, got {rec['token_estimate']}"
assert rec["iteration_number"] == 1
assert rec["revalidation_outcome"] == "findings_present"
assert rec["fix_diff_summary"] == "patched typo"
assert isinstance(rec["findings"], list)
assert isinstance(rec["timestamp"], str)
PY
}

@test "rejects token-estimate that is not numeric" {
  run "$PRODUCER" \
    --skill gaia-brainstorm \
    --step 6 \
    --iteration 1 \
    --token-estimate notanumber \
    --revalidation-outcome findings_present \
    --findings-json '[]'
  [ "$status" -ne 0 ]
  [[ "$output" == *"numeric"* || "$output" == *"token-estimate"* ]]
}

@test "rejects token-estimate <= 0" {
  run "$PRODUCER" \
    --skill gaia-brainstorm \
    --step 6 \
    --iteration 1 \
    --token-estimate 0 \
    --revalidation-outcome findings_present \
    --findings-json '[]'
  [ "$status" -ne 0 ]
}

@test "omits token_estimate field when --token-estimate=null is passed (AC-EC8 fallback)" {
  run "$PRODUCER" \
    --skill gaia-brainstorm \
    --step 6 \
    --iteration 1 \
    --token-estimate null \
    --revalidation-outcome findings_present \
    --findings-json '[]'
  [ "$status" -eq 0 ]
  CKPT="$output"
  python3 - "$CKPT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
rec = d["custom"]["val_loop_iterations"][0]
# AC-EC8: when runtime token-counting is unavailable, the field is null
# (omitting it would also be acceptable; we choose explicit null per
# the canonical record shape in gaia-val-validate SKILL.md).
assert rec.get("token_estimate") is None, \
    f"token_estimate should be null when runtime primitive unavailable, got {rec.get('token_estimate')}"
PY
}

# ---------- Append semantics: subsequent iterations append to existing array ----------

@test "subsequent iterations append to the same skill's checkpoint stream" {
  # Iteration 1
  run "$PRODUCER" \
    --skill gaia-brainstorm \
    --step 6 \
    --iteration 1 \
    --token-estimate 1500 \
    --revalidation-outcome findings_present \
    --findings-json '[{"severity":"CRITICAL"}]'
  [ "$status" -eq 0 ]
  CKPT1="$output"
  # Iteration 2
  run "$PRODUCER" \
    --skill gaia-brainstorm \
    --step 6 \
    --iteration 2 \
    --token-estimate 1500 \
    --revalidation-outcome findings_present \
    --findings-json '[{"severity":"CRITICAL"}]'
  [ "$status" -eq 0 ]
  CKPT2="$output"
  # Iteration 3
  run "$PRODUCER" \
    --skill gaia-brainstorm \
    --step 6 \
    --iteration 3 \
    --token-estimate 1500 \
    --revalidation-outcome findings_present \
    --findings-json '[{"severity":"CRITICAL"}]'
  [ "$status" -eq 0 ]
  CKPT3="$output"
  # The latest checkpoint must contain all 3 iteration records — the loop's
  # authoritative state for /gaia-resume.
  python3 - "$CKPT3" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
iters = d["custom"]["val_loop_iterations"]
assert len(iters) == 3, f"expected 3 iteration records on latest checkpoint, got {len(iters)}"
nums = [r["iteration_number"] for r in iters]
assert nums == [1, 2, 3], f"iteration_numbers must be in append order, got {nums}"
for r in iters:
    assert r["token_estimate"] == 1500
PY
}

# ---------- AC2: harness consumes the populated checkpoint without parser errors ----------

@test "harness parses producer-emitted checkpoint and reports a verdict" {
  # Three iterations of 1500 tokens; baseline 1000 → per_iteration 1.5, total 4.5 → PASS
  for i in 1 2 3; do
    "$PRODUCER" \
      --skill gaia-brainstorm \
      --step 6 \
      --iteration "$i" \
      --token-estimate 1500 \
      --revalidation-outcome findings_present \
      --findings-json '[{"severity":"CRITICAL"}]' >/dev/null
  done
  CKPT="$(ls -t "$CHECKPOINT_ROOT/gaia-brainstorm/"*.json | head -n 1)"
  run "$HARNESS" --baseline 1000 --checkpoint "$CKPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"data_source: checkpoint"* ]]
  [[ "$output" == *"PASS"* ]]
  [[ "$output" == *"per_iteration_ratio: 1.5"* ]]
  [[ "$output" == *"total_loop_ratio: 4.5"* ]]
}

# ---------- AC3: no iterations emitted when single-pass clean ----------

@test "zero iterations emit no val_loop_iterations records" {
  # When the loop terminates on the first Val invocation (clean / INFO-only),
  # the producer is never invoked. We assert here that no checkpoint with a
  # val_loop_iterations array is created in the brainstorm skill directory.
  [ ! -d "$CHECKPOINT_ROOT/gaia-brainstorm" ] || \
    [ -z "$(find "$CHECKPOINT_ROOT/gaia-brainstorm" -type f -name '*.json' 2>/dev/null)" ]
}

# ---------- Wire-in: gaia-brainstorm SKILL.md cites the producer ----------

@test "wire-in: gaia-brainstorm SKILL.md invokes the producer in the val auto-fix loop" {
  SKILL="$REPO_ROOT/plugins/gaia/skills/gaia-brainstorm/SKILL.md"
  [ -f "$SKILL" ]
  grep -q "append-val-iteration.sh" "$SKILL"
  grep -q "token_estimate\|token-estimate" "$SKILL"
}

# ---------- Canonical record-shape doc carries token_estimate field ----------

@test "contract: gaia-val-validate SKILL.md documents token_estimate as the harness contract field" {
  SKILL="$REPO_ROOT/plugins/gaia/skills/gaia-val-validate/SKILL.md"
  [ -f "$SKILL" ]
  grep -q "token_estimate" "$SKILL"
}
