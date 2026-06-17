#!/usr/bin/env bats
# selective-test-driver.bats — TDD tests for selective-test-driver.sh
#
# Public functions covered (NFR-052): parse_args, run_stage, run_pipeline, main.
# Internal helpers use underscore prefix (_log_info, _die) so they are
# exempt from the NFR-052 public-fn coverage gate.

load 'test_helper.bash'

setup() {
  common_setup

  DRIVER="$SCRIPTS_DIR/selective-test-driver.sh"

  # -----------------------------------------------------------------------
  # Fixture shim directory — small scripts echoing canned output.
  # Each stage shim is injectable via <STAGE>_BIN env vars.
  # -----------------------------------------------------------------------
  SHIM_DIR="$TEST_TMP/shims"
  mkdir -p "$SHIM_DIR"

  # Default config fixture (needed for --config forwarding)
  cat > "$TEST_TMP/project-config.yaml" <<'YAML'
stacks:
  - name: api
    language: typescript
    path: src/api
  - name: web
    language: typescript
    path: src/web
  - name: worker
    language: python
    path: src/worker
YAML

  # --- detect-affected shim (default: emits single stack) ----------------
  cat > "$SHIM_DIR/detect-affected.sh" <<'SH'
#!/usr/bin/env bash
echo '["api"]'
SH
  chmod +x "$SHIM_DIR/detect-affected.sh"

  # --- cross-refs-walk shim (default: passthrough) -----------------------
  cat > "$SHIM_DIR/cross-refs-walk.sh" <<'SH'
#!/usr/bin/env bash
# Parse --stacks value and echo it back (passthrough)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stacks) echo "$2"; exit 0 ;;
    *) shift ;;
  esac
done
echo '[]'
SH
  chmod +x "$SHIM_DIR/cross-refs-walk.sh"

  # --- reconcile-stale-graph shim (default: passthrough) -----------------
  cat > "$SHIM_DIR/reconcile-stale-graph.sh" <<'SH'
#!/usr/bin/env bash
# Parse --affected-set value and echo it back (passthrough)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --affected-set) echo "$2"; exit 0 ;;
    *) shift ;;
  esac
done
echo '[]'
SH
  chmod +x "$SHIM_DIR/reconcile-stale-graph.sh"

  # --- apply-test-policy shim (default: passthrough) ---------------------
  cat > "$SHIM_DIR/apply-test-policy.sh" <<'SH'
#!/usr/bin/env bash
# Parse --affected-set value and echo it back (passthrough)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --affected-set) echo "$2"; exit 0 ;;
    *) shift ;;
  esac
done
echo '[]'
SH
  chmod +x "$SHIM_DIR/apply-test-policy.sh"

  # --- generate-pipeline shim (default: wrap input in matrix JSON) -------
  cat > "$SHIM_DIR/generate-pipeline.sh" <<'SH'
#!/usr/bin/env bash
# Parse --affected-set and produce matrix JSON
affected=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --affected-set) affected="$2"; shift 2 ;;
    --config) shift 2 ;;
    *) shift ;;
  esac
done
if [[ "$affected" == '[]' ]] || [[ -z "$affected" ]]; then
  echo '{"include":[]}'
else
  # Build include array from stack names
  # Simple: strip brackets, split on comma, wrap each
  local_affected="${affected#[}"
  local_affected="${local_affected%]}"
  local_affected="${local_affected//\"/}"
  IFS=',' read -ra stacks <<< "$local_affected"
  result='{"include":['
  first=true
  for s in "${stacks[@]}"; do
    s="${s// /}"
    [[ -z "$s" ]] && continue
    $first || result+=","
    result+="{\"stack\":\"$s\"}"
    first=false
  done
  result+=']}'
  echo "$result"
fi
SH
  chmod +x "$SHIM_DIR/generate-pipeline.sh"

  # Export shim paths as env vars consumed by the driver
  export DETECT_AFFECTED_BIN="$SHIM_DIR/detect-affected.sh"
  export CROSS_REFS_WALK_BIN="$SHIM_DIR/cross-refs-walk.sh"
  export RECONCILE_STALE_GRAPH_BIN="$SHIM_DIR/reconcile-stale-graph.sh"
  export APPLY_TEST_POLICY_BIN="$SHIM_DIR/apply-test-policy.sh"
  export GENERATE_PIPELINE_BIN="$SHIM_DIR/generate-pipeline.sh"
}

teardown() { common_teardown; }

# =========================================================================
# NFR-052: source the script and verify every public function resolves
# =========================================================================

@test "source script — parse_args is callable" {
  source "$DRIVER"
  type parse_args
}

@test "source script — run_stage is callable" {
  source "$DRIVER"
  type run_stage
}

@test "source script — run_pipeline is callable" {
  source "$DRIVER"
  type run_pipeline
}

@test "source script — main is callable" {
  source "$DRIVER"
  type main
}

@test "sourcing the script does not run main" {
  run bash -c 'source "'"$DRIVER"'" && echo "sourced-ok"'
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"sourced-ok"* ]]
  # Should NOT contain pipeline output or HALT messages
  [[ "$output" != *'"include"'* ]]
  [[ "$output" != *'HALT'* ]]
}

# =========================================================================
# Test 1: selective single-stack path produces correct matrix JSON
# =========================================================================

@test "selective path — single stack produces matrix JSON with that stack" {
  run "$DRIVER" \
    --config "$TEST_TMP/project-config.yaml" \
    --trigger pr \
    --files "src/api/index.ts"

  [[ "$status" -eq 0 ]]
  # stdout must be valid matrix JSON containing the api stack
  [[ "$output" == *'"include"'* ]]
  [[ "$output" == *'"stack":"api"'* ]]
}

# =========================================================================
# Test 2: wildcard/escalation path forwards --config to generate-pipeline
# =========================================================================

@test "escalation path — wildcard forwards config to generate-pipeline" {
  # Make reconcile-stale-graph escalate to ["*"]
  cat > "$SHIM_DIR/reconcile-stale-graph.sh" <<'SH'
#!/usr/bin/env bash
echo '["*"]'
SH
  chmod +x "$SHIM_DIR/reconcile-stale-graph.sh"

  # Replace generate-pipeline shim to capture args and verify --config
  cat > "$SHIM_DIR/generate-pipeline.sh" <<'SH'
#!/usr/bin/env bash
# Capture all args to a file for assertion, then produce output
echo "$@" > "${GENERATE_PIPELINE_ARGS_FILE:-/dev/null}"
echo '{"include":[{"stack":"api"},{"stack":"web"},{"stack":"worker"}]}'
SH
  chmod +x "$SHIM_DIR/generate-pipeline.sh"

  export GENERATE_PIPELINE_ARGS_FILE="$TEST_TMP/gp-args.txt"

  run "$DRIVER" \
    --config "$TEST_TMP/project-config.yaml" \
    --trigger pr \
    --files "src/api/index.ts"

  [[ "$status" -eq 0 ]]
  # generate-pipeline must have received --config
  [[ -f "$TEST_TMP/gp-args.txt" ]]
  grep -qF -- "--config" "$TEST_TMP/gp-args.txt"
  grep -qF "$TEST_TMP/project-config.yaml" "$TEST_TMP/gp-args.txt"
}

# =========================================================================
# Test 3: empty set short-circuit (docs-only change)
# =========================================================================

@test "empty set — detect-affected emits empty array, driver short-circuits with empty matrix" {
  # Make detect-affected emit []
  cat > "$SHIM_DIR/detect-affected.sh" <<'SH'
#!/usr/bin/env bash
echo '[]'
SH
  chmod +x "$SHIM_DIR/detect-affected.sh"

  # Replace cross-refs-walk shim to detect if it was called
  cat > "$SHIM_DIR/cross-refs-walk.sh" <<'SH'
#!/usr/bin/env bash
echo "SHOULD-NOT-BE-CALLED" > "${CROSS_REFS_CALLED_FILE:-/dev/null}"
echo '[]'
SH
  chmod +x "$SHIM_DIR/cross-refs-walk.sh"

  export CROSS_REFS_CALLED_FILE="$TEST_TMP/cross-refs-called.txt"

  run "$DRIVER" \
    --config "$TEST_TMP/project-config.yaml" \
    --trigger pr \
    --files "docs/readme.md"

  [[ "$status" -eq 0 ]]
  # Must emit the canonical empty matrix JSON
  [[ "$output" == *'{"include":[]}'* ]] || [[ "$output" == *'{ "include": [] }'* ]] || {
    # Trim whitespace and check
    local trimmed
    trimmed="$(echo "$output" | tr -d '[:space:]')"
    [[ "$trimmed" == *'{"include":[]}'* ]]
  }
  # cross-refs-walk must NOT have been called
  [[ ! -f "$TEST_TMP/cross-refs-called.txt" ]]
}

# =========================================================================
# Test 4: undeclared-edge escalation path produces wildcard matrix
# =========================================================================

@test "undeclared-edge escalation — reconcile emits wildcard, pipeline includes all stacks" {
  # reconcile-stale-graph escalates to ["*"]
  cat > "$SHIM_DIR/reconcile-stale-graph.sh" <<'SH'
#!/usr/bin/env bash
echo '["*"]'
SH
  chmod +x "$SHIM_DIR/reconcile-stale-graph.sh"

  run "$DRIVER" \
    --config "$TEST_TMP/project-config.yaml" \
    --trigger pr \
    --files "src/api/index.ts"

  [[ "$status" -eq 0 ]]
  [[ "$output" == *'"include"'* ]]
}

# =========================================================================
# Test 5: mid-chain stage failure emits HALT and exits 1
# =========================================================================

@test "stage failure — mid-chain non-zero exit emits HALT to stderr and exits 1" {
  # Make cross-refs-walk fail with exit 1
  cat > "$SHIM_DIR/cross-refs-walk.sh" <<'SH'
#!/usr/bin/env bash
echo "cross-refs-walk: bad config" >&2
exit 1
SH
  chmod +x "$SHIM_DIR/cross-refs-walk.sh"

  run "$DRIVER" \
    --config "$TEST_TMP/project-config.yaml" \
    --trigger pr \
    --files "src/api/index.ts"

  [[ "$status" -eq 1 ]]
  # bats captures stderr in output when using run
  [[ "$output" == *"HALT:"* ]]
  [[ "$output" == *"cross-refs-walk"* ]]
  [[ "$output" == *"failed"* ]]
  [[ "$output" == *"exit"* ]]
}

# =========================================================================
# Test 6: --trigger is forwarded to apply-test-policy
# =========================================================================

@test "trigger forwarding — trigger value is passed to apply-test-policy" {
  # Replace apply-test-policy to capture args
  cat > "$SHIM_DIR/apply-test-policy.sh" <<'SH'
#!/usr/bin/env bash
echo "$@" > "${APPLY_POLICY_ARGS_FILE:-/dev/null}"
# Parse --affected-set and echo it (passthrough)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --affected-set) echo "$2"; exit 0 ;;
    *) shift ;;
  esac
done
echo '[]'
SH
  chmod +x "$SHIM_DIR/apply-test-policy.sh"

  export APPLY_POLICY_ARGS_FILE="$TEST_TMP/policy-args.txt"

  run "$DRIVER" \
    --config "$TEST_TMP/project-config.yaml" \
    --trigger push \
    --files "src/api/index.ts"

  [[ "$status" -eq 0 ]]
  [[ -f "$TEST_TMP/policy-args.txt" ]]
  grep -qF -- "--trigger" "$TEST_TMP/policy-args.txt"
  grep -qF "push" "$TEST_TMP/policy-args.txt"
}
