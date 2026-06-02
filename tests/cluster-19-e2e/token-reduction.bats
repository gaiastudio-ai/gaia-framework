#!/usr/bin/env bats
# token-reduction.bats — E28-S139: Token-reduction measurement suite (Cluster 19, NFR-048)
#
# Structural assertions on the artifacts, fixtures, and driver-behavior
# contract declared by AC1–AC5 and AC-EC1–AC-EC8 of
# docs/test-artifacts/atdd-E28-S139.md.
#
# This is the bats-equivalent of test/validation/atdd/e28-s139.test.js.
# Both files assert the same contract; this one executes in CI without
# requiring vitest/node modules. Each AC / AC-EC maps to one @test.
#
# Usage:
#   bats tests/cluster-19-e2e/token-reduction.bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"   # .../gaia-framework
  GAIA_ROOT="$(cd "$REPO_ROOT/.." && pwd)"               # .../GAIA-Framework
  DRIVER_DIR="$REPO_ROOT/plugins/gaia/test/scripts/token-reduction"
  TOKENIZER_PIN="$DRIVER_DIR/tokenizer.version"
  FIXTURES_DIR="$REPO_ROOT/plugins/gaia/test/fixtures/parity-baseline/token-budget"
  CLUSTER_19_DIR="$GAIA_ROOT/docs/test-artifacts/cluster-19"
  TOKEN_BUDGET_DIR="$CLUSTER_19_DIR/token-budget"
  METHODOLOGY="$CLUSTER_19_DIR/token-reduction-methodology.md"
  RESULTS="$CLUSTER_19_DIR/token-reduction-results.md"
  CLUSTER_19_PLAN="$GAIA_ROOT/docs/test-artifacts/cluster-19-e2e-test-plan.md"
  CHANGELOG="$REPO_ROOT/CHANGELOG.md"
  TEST_PLAN="$GAIA_ROOT/docs/test-artifacts/test-plan.md"
  WORKFLOWS=(dev-story create-prd code-review sprint-planning brownfield-onboarding)
}

# sha256 of a file's bytes
sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# Validate JSON with python3 (ships on macOS/linux CI)
json_valid() {
  python3 -c "import json,sys; json.loads(open('$1').read())" 2>/dev/null
}

json_field() {
  python3 -c "import json,sys; d=json.loads(open('$1').read()); v=d.get('$2'); print(v if v is not None else '__MISSING__')" 2>/dev/null
}

# ---------- AC1 ----------

@test "AC1: all 5 workflows have baseline + native prompt captures and token-count.json" {
  for wf in "${WORKFLOWS[@]}"; do
    [ -f "$TOKEN_BUDGET_DIR/$wf/baseline.prompt.txt" ] || { echo "$wf baseline.prompt.txt missing"; return 1; }
    [ -f "$TOKEN_BUDGET_DIR/$wf/baseline.token-count.json" ] || { echo "$wf baseline.token-count.json missing"; return 1; }
    [ -f "$TOKEN_BUDGET_DIR/$wf/native.prompt.txt" ] || { echo "$wf native.prompt.txt missing"; return 1; }
    [ -f "$TOKEN_BUDGET_DIR/$wf/native.token-count.json" ] || { echo "$wf native.token-count.json missing"; return 1; }
    json_valid "$TOKEN_BUDGET_DIR/$wf/baseline.token-count.json" || { echo "$wf baseline json invalid"; return 1; }
    json_valid "$TOKEN_BUDGET_DIR/$wf/native.token-count.json" || { echo "$wf native json invalid"; return 1; }
    bt=$(json_field "$TOKEN_BUDGET_DIR/$wf/baseline.token-count.json" tokens)
    nt=$(json_field "$TOKEN_BUDGET_DIR/$wf/native.token-count.json" tokens)
    [[ "$bt" =~ ^[0-9]+$ ]] || { echo "$wf baseline tokens not numeric: $bt"; return 1; }
    [[ "$nt" =~ ^[0-9]+$ ]] || { echo "$wf native tokens not numeric: $nt"; return 1; }
  done
}

# ---------- AC2 ----------

@test "AC2: token-reduction-methodology.md covers required sections" {
  [ -f "$METHODOLOGY" ] || { echo "methodology document missing"; return 1; }
  grep -qiE 'tokenizer' "$METHODOLOGY"
  grep -qiE 'pin(ned)? version|sha' "$METHODOLOGY"
  grep -qiE '(included|includes).*(system prompt|skills|knowledge)' "$METHODOLOGY"
  grep -qiE '(excluded|excludes).*(response|assistant)' "$METHODOLOGY"
  grep -qiE 'determinism|fixed seed|frozen fixture' "$METHODOLOGY"
  grep -q  'v-parity-baseline' "$METHODOLOGY"
  grep -qiE 'native plugin|native implementation' "$METHODOLOGY"
  for wf in "${WORKFLOWS[@]}"; do
    grep -q "$wf" "$METHODOLOGY" || { echo "methodology does not mention $wf"; return 1; }
  done
}

# ---------- AC3 ----------

@test "AC3: token-reduction-results.md contains the required comparison table" {
  [ -f "$RESULTS" ] || { echo "results document missing"; return 1; }
  for col in "Workflow" "Baseline tokens" "Native tokens" "Delta (tokens)" "Reduction %" "NFR-048 pass/fail" "Stretch (≥55%) pass/warn" "Evidence"; do
    grep -qF "$col" "$RESULTS" || { echo "results table missing column '$col'"; return 1; }
  done
  for wf in "${WORKFLOWS[@]}"; do
    grep -q "$wf" "$RESULTS" || { echo "results table missing row for $wf"; return 1; }
  done
  grep -qE '\-?[0-9]+\.[0-9]%' "$RESULTS" || { echo "no one-decimal percentage found"; return 1; }
  grep -qE 'token-budget/(dev-story|create-prd|code-review|sprint-planning|brownfield-onboarding)/(baseline|native)\.(prompt|token-count)' "$RESULTS"
}

# ---------- AC4 ----------

@test "AC4: aggregate reduction and per-workflow PASS/FAIL gates are computed correctly" {
  [ -f "$RESULTS" ] || { echo "results document missing"; return 1; }
  grep -qiE 'aggregate reduction' "$RESULTS"
  grep -qiE 'overall.*nfr-048.*verdict|overall verdict' "$RESULTS"
  for wf in "${WORKFLOWS[@]}"; do
    grep -qE "\|[[:space:]]*$wf[[:space:]]*\|.*\|[[:space:]]*(PASS|FAIL|N/A)" "$RESULTS" \
      || { echo "row for $wf has no PASS/FAIL verdict"; return 1; }
  done
  grep -qE '55[[:space:]]*%|≥[[:space:]]*55' "$RESULTS"
}

# ---------- AC5 ----------

@test "AC5: results artifact is published and cross-referenced" {
  [ -f "$RESULTS" ] || { echo "results artifact not published"; return 1; }
  [ -f "$CLUSTER_19_PLAN" ] || { echo "cluster-19-e2e-test-plan.md missing"; return 1; }
  grep -qiE 'token.?reduction' "$CLUSTER_19_PLAN"
  grep -qF 'token-reduction-results.md' "$CLUSTER_19_PLAN"

  [ -f "$TEST_PLAN" ] || { echo "test-plan.md missing"; return 1; }
  for ncp in NCP-14 NCP-15 NCP-16 NCP-17 NCP-18 NCP-19 NCP-20; do
    grep -qE "$ncp.*(PASS|FAIL)" "$TEST_PLAN" || { echo "$ncp not marked PASS/FAIL"; return 1; }
  done

  [ -f "$CHANGELOG" ] || { echo "CHANGELOG.md missing"; return 1; }
  grep -qiE 'cluster 19.*token.?reduction' "$CHANGELOG"
  grep -qiE 'nfr-048.*(pass|fail)' "$CHANGELOG"
}

# ---------- AC-EC1 ----------

@test "AC-EC1: driver aborts on tokenizer version mismatch" {
  [ -f "$TOKENIZER_PIN" ] || { echo "tokenizer.version pin missing"; return 1; }
  [ -f "$DRIVER_DIR/index.js" ] || { echo "driver entrypoint missing"; return 1; }
  grep -qiE 'tokenizer[_-]?sha|tokenizer_version' "$DRIVER_DIR/index.js"
  grep -qE '(process\.exit\([1-9])|(throw new Error[^)]*tokenizer)' "$DRIVER_DIR/index.js"
}

# ---------- AC-EC2 ----------

@test "AC-EC2: every token-count.json records cache_control: disabled" {
  for wf in "${WORKFLOWS[@]}"; do
    for run in baseline native; do
      path="$TOKEN_BUDGET_DIR/$wf/$run.token-count.json"
      [ -f "$path" ] || { echo "$wf/$run missing"; return 1; }
      v=$(json_field "$path" cache_control)
      [ "$v" = "disabled" ] || { echo "$wf/$run cache_control=$v, want disabled"; return 1; }
    done
  done
}

# ---------- AC-EC3 ----------

@test "AC-EC3: driver-input.txt is byte-identical across baseline and native runs" {
  for wf in "${WORKFLOWS[@]}"; do
    fixture="$FIXTURES_DIR/$wf/driver-input.txt"
    [ -f "$fixture" ] || { echo "$wf driver-input.txt fixture missing"; return 1; }
    [ -s "$fixture" ] || { echo "$wf driver-input.txt empty"; return 1; }
    want=$(sha256_file "$fixture")
    got_b=$(json_field "$TOKEN_BUDGET_DIR/$wf/baseline.token-count.json" driver_input_sha256)
    got_n=$(json_field "$TOKEN_BUDGET_DIR/$wf/native.token-count.json" driver_input_sha256)
    [ "$got_b" = "$want" ] || { echo "$wf baseline sha mismatch"; return 1; }
    [ "$got_n" = "$want" ] || { echo "$wf native sha mismatch"; return 1; }
  done
}

# ---------- AC-EC4 ----------

@test "AC-EC4: workflow failure produces failure.log and marks row N/A with overall FAIL" {
  [ -f "$RESULTS" ] || { echo "results document missing"; return 1; }
  any_failure=0
  for wf in "${WORKFLOWS[@]}"; do
    if [ -f "$TOKEN_BUDGET_DIR/$wf/failure.log" ]; then
      any_failure=1
      grep -qE "\|[[:space:]]*$wf[[:space:]]*\|.*N/A.*measurement failed" "$RESULTS" \
        || { echo "$wf failed but row is not N/A — measurement failed"; return 1; }
    fi
  done
  if [ "$any_failure" -eq 1 ]; then
    grep -qiE 'overall.*verdict.*fail' "$RESULTS" || { echo "overall verdict must be FAIL"; return 1; }
  fi
}

# ---------- AC-EC5 ----------

@test "AC-EC5: non-positive baseline_tokens is rejected" {
  [ -f "$DRIVER_DIR/index.js" ] || { echo "driver entrypoint missing"; return 1; }
  grep -qiE 'baseline_tokens[[:space:]]*(>|must be positive|<=[[:space:]]*0)' "$DRIVER_DIR/index.js"
  for wf in "${WORKFLOWS[@]}"; do
    path="$TOKEN_BUDGET_DIR/$wf/baseline.token-count.json"
    if [ -f "$path" ]; then
      bt=$(json_field "$path" tokens)
      [ "$bt" -gt 0 ] || { echo "$wf baseline tokens not positive: $bt"; return 1; }
    fi
  done
}

# ---------- AC-EC6 ----------

@test "AC-EC6: negative reductions are displayed as negative and marked FAIL" {
  [ -f "$RESULTS" ] || { echo "results document missing"; return 1; }
  while IFS= read -r line; do
    if echo "$line" | grep -qE '\|[[:space:]]*-[0-9]+\.[0-9]%'; then
      echo "$line" | grep -qE '\|[[:space:]]*FAIL[[:space:]]*\|' \
        || { echo "row with negative reduction not FAIL: $line"; return 1; }
      echo "$line" | grep -q 'abs()' && { echo "abs() hiding detected"; return 1; } || true
    fi
  done < "$RESULTS"
}

# ---------- AC-EC7 ----------

@test "AC-EC7: assistant-role turns in prompt capture are rejected" {
  [ -f "$DRIVER_DIR/index.js" ] || { echo "driver entrypoint missing"; return 1; }
  grep -qiE "role[[:space:]]*[:=][[:space:]]*['\"]assistant['\"]|assistant[- ]role" "$DRIVER_DIR/index.js"
  grep -qiE 'Response tokens leaked into prompt capture|leaked.*prompt.*capture' "$DRIVER_DIR/index.js"
  for wf in "${WORKFLOWS[@]}"; do
    for run in baseline native; do
      path="$TOKEN_BUDGET_DIR/$wf/$run.prompt.txt"
      if [ -f "$path" ]; then
        grep -qE '"role"[[:space:]]*:[[:space:]]*"assistant"' "$path" && { echo "$wf/$run contains assistant turn"; return 1; } || true
      fi
    done
  done
}

# ---------- AC-EC8 ----------

@test "AC-EC8: second run produces byte-identical token-count.json (NCP-20 determinism)" {
  for wf in "${WORKFLOWS[@]}"; do
    r1="$TOKEN_BUDGET_DIR/$wf/native.token-count.json"
    r2="$TOKEN_BUDGET_DIR/$wf/run2.token-count.json"
    [ -f "$r1" ] || { echo "$wf first-run missing"; return 1; }
    [ -f "$r2" ] || { echo "$wf run2 missing"; return 1; }
    s1=$(sha256_file "$r1")
    s2=$(sha256_file "$r2")
    [ "$s1" = "$s2" ] || { echo "$wf run 1 vs run 2 not byte-identical"; return 1; }
  done
}
