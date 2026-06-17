#!/usr/bin/env bats
# reconcile-stale-graph.bats — TDD tests for reconcile-stale-graph.sh (E113-S5)
#
# Public functions covered (NFR-052): usage, parse_args, parse_affected_set,
# build_depgraph_for_detector, invoke_detector, parse_unsanctioned_edges,
# emit_report, reconcile, main.
#
# Test seam: --detected-edges-file <path> feeds a synthetic dep-graph JSON file
# directly to the detector invocation, bypassing brownfield path resolution.
# This prevents the need for a real project-config.yaml depgraph at the
# default .gaia/ location.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

# ---------------------------------------------------------------------------
# setup / teardown
# ---------------------------------------------------------------------------

setup() {
  common_setup

  # Synthetic two-stack project config. stack-alpha has cross_refs to stack-beta
  # (sanctioned edge). No other cross-stack refs are declared.
  cat > "$TEST_TMP/project-config.yaml" <<'EOF'
stacks:
  - name: stack-alpha
    language: bash
    path: "alpha"
    cross_refs:
      - stack-beta
  - name: stack-beta
    language: bash
    path: "beta"
EOF

  # A second minimal config with no cross_refs declared (used for undeclared-edge tests).
  cat > "$TEST_TMP/project-config-no-refs.yaml" <<'EOF'
stacks:
  - name: stack-alpha
    language: bash
    path: "alpha"
  - name: stack-beta
    language: bash
    path: "beta"
EOF

  # Dep-graph JSON: one sanctioned edge (alpha -> beta).
  # This matches the cross_refs in project-config.yaml → CLEAN.
  cat > "$TEST_TMP/depgraph-clean.json" <<'EOF'
{
  "edges": [
    {"source": "alpha/src/foo.sh", "target": "beta/lib/bar.sh"}
  ]
}
EOF

  # Dep-graph JSON: one UNSANCTIONED edge (beta -> alpha — not declared in cross_refs).
  cat > "$TEST_TMP/depgraph-unsanctioned.json" <<'EOF'
{
  "edges": [
    {"source": "beta/src/main.sh", "target": "alpha/lib/util.sh"}
  ]
}
EOF

  # Dep-graph JSON: empty edges (no cross-stack activity).
  cat > "$TEST_TMP/depgraph-empty.json" <<'EOF'
{
  "edges": []
}
EOF
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# NFR-052: source script — every public function must be callable
# ---------------------------------------------------------------------------

@test "NFR-052: source script — usage is callable" {
  source "$SCRIPTS_DIR/reconcile-stale-graph.sh"
  type usage
}

@test "NFR-052: source script — parse_args is callable" {
  source "$SCRIPTS_DIR/reconcile-stale-graph.sh"
  type parse_args
}

@test "NFR-052: source script — parse_affected_set is callable" {
  source "$SCRIPTS_DIR/reconcile-stale-graph.sh"
  type parse_affected_set
}

@test "NFR-052: source script — build_depgraph_for_detector is callable" {
  source "$SCRIPTS_DIR/reconcile-stale-graph.sh"
  type build_depgraph_for_detector
}

@test "NFR-052: source script — invoke_detector is callable" {
  source "$SCRIPTS_DIR/reconcile-stale-graph.sh"
  type invoke_detector
}

@test "NFR-052: source script — parse_unsanctioned_edges is callable" {
  source "$SCRIPTS_DIR/reconcile-stale-graph.sh"
  type parse_unsanctioned_edges
}

@test "NFR-052: source script — emit_report is callable" {
  source "$SCRIPTS_DIR/reconcile-stale-graph.sh"
  type emit_report
}

@test "NFR-052: source script — reconcile is callable" {
  source "$SCRIPTS_DIR/reconcile-stale-graph.sh"
  type reconcile
}

@test "NFR-052: source script — main is callable" {
  source "$SCRIPTS_DIR/reconcile-stale-graph.sh"
  type main
}

@test "NFR-052: main-guard — sourcing does NOT invoke main" {
  # If main runs on source it will fail (missing args) — exit 1 would surface here.
  source "$SCRIPTS_DIR/reconcile-stale-graph.sh"
  true
}

# ---------------------------------------------------------------------------
# --help
# ---------------------------------------------------------------------------

@test "--help exits 0 and prints usage" {
  run "$SCRIPTS_DIR/reconcile-stale-graph.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

# ---------------------------------------------------------------------------
# AC5 (STRUCTURAL): reconcile-stale-graph.sh must REFERENCE the detector,
# not reimplement edge detection.
# ---------------------------------------------------------------------------

@test "AC5 structural: script references reconcile-cross-stack or unsanctioned-cross-stack-reference" {
  grep -E 'unsanctioned-cross-stack-reference|reconcile-cross-stack' \
    "$SCRIPTS_DIR/reconcile-stale-graph.sh"
}

# ---------------------------------------------------------------------------
# AC5 FORMAT-PIN: invoke the real detector against a known-bad fixture,
# capture STDOUT, assert WARNING line format.
# (Guarded: requires yq + jq; skipped when absent.)
# ---------------------------------------------------------------------------

@test "AC5 format-pin: real detector emits WARNING on STDOUT (not stderr)" {
  command -v yq >/dev/null 2>&1 || skip "yq absent"
  command -v jq >/dev/null 2>&1 || skip "jq absent"

  DETECTOR="$SCRIPTS_DIR/adapters/brownfield/reconcile-cross-stack.sh"
  [ -f "$DETECTOR" ] || skip "reconcile-cross-stack.sh not found"

  # Config with no cross_refs (any cross-stack edge is unsanctioned).
  local detector_out
  detector_out="$(XSTACK_CONFIG="$TEST_TMP/project-config-no-refs.yaml" \
    XSTACK_DEPGRAPH="$TEST_TMP/depgraph-unsanctioned.json" \
    GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
    GAIA_BROWNFIELD_PHASE_4B_CROSS_STACK_ENABLED=true \
    bash "$DETECTOR" 2>/dev/null)" || true

  # Must match the canonical WARNING format on STDOUT.
  echo "$detector_out" | grep -E \
    'WARNING: [^:]+: unsanctioned-cross-stack-reference: [^:]+:[^ ]+ -> [^:]+:[^ ]+'
}

# ---------------------------------------------------------------------------
# ["*"] early passthrough — AC2 edge case (already-full-suite input)
# ---------------------------------------------------------------------------

@test "AC2 passthrough: [\"*\"] input echoes [\"*\"] without calling detector" {
  # No --config needed — early passthrough before any detector call.
  run --separate-stderr "$SCRIPTS_DIR/reconcile-stale-graph.sh" \
    --affected-set '["*"]'
  [ "$status" -eq 0 ]
  [[ "$output" == '["*"]' ]]
}

# ---------------------------------------------------------------------------
# AC4: missing dep-graph → graceful passthrough (no escalation)
# ---------------------------------------------------------------------------

@test "AC4 graceful: missing dep-graph path emits affected-set unmodified" {
  run --separate-stderr "$SCRIPTS_DIR/reconcile-stale-graph.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --affected-set '["stack-alpha"]' \
    --detected-edges-file "$TEST_TMP/DOES_NOT_EXIST.json"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-alpha"]' ]]
}

# ---------------------------------------------------------------------------
# AC1 / AC2: undeclared edge → escalation to ["*"]
# ---------------------------------------------------------------------------

@test "AC1+AC2: undeclared edge triggers escalation to [\"*\"]" {
  command -v yq >/dev/null 2>&1 || skip "yq absent"
  command -v jq >/dev/null 2>&1 || skip "jq absent"

  run --separate-stderr "$SCRIPTS_DIR/reconcile-stale-graph.sh" \
    --config "$TEST_TMP/project-config-no-refs.yaml" \
    --affected-set '["stack-alpha","stack-beta"]' \
    --detected-edges-file "$TEST_TMP/depgraph-unsanctioned.json"
  [ "$status" -eq 0 ]
  [[ "$output" == '["*"]' ]]
}

# ---------------------------------------------------------------------------
# AC3: escalation report names the specific undeclared edge
# ---------------------------------------------------------------------------

@test "AC3: escalation report names source stack, target stack, and import path" {
  command -v yq >/dev/null 2>&1 || skip "yq absent"
  command -v jq >/dev/null 2>&1 || skip "jq absent"

  local report_file="$TEST_TMP/report.txt"

  run --separate-stderr "$SCRIPTS_DIR/reconcile-stale-graph.sh" \
    --config "$TEST_TMP/project-config-no-refs.yaml" \
    --affected-set '["stack-alpha","stack-beta"]' \
    --detected-edges-file "$TEST_TMP/depgraph-unsanctioned.json" \
    --report-file "$report_file"
  [ "$status" -eq 0 ]
  [ -f "$report_file" ]

  # Report must name source stack (stack-beta), target stack (stack-alpha), and a file path.
  grep -q 'stack-beta' "$report_file"
  grep -q 'stack-alpha' "$report_file"
  # Must contain a file path (the import path)
  grep -qE '[a-zA-Z/._-]+\.(sh|py|ts|js|rb|go)' "$report_file"
}

# ---------------------------------------------------------------------------
# AC4: clean dep-graph (all edges sanctioned) → affected-set passes through
# unmodified (no false escalation)
# ---------------------------------------------------------------------------

@test "AC4: sanctioned edges only → affected-set passes through unmodified" {
  command -v yq >/dev/null 2>&1 || skip "yq absent"
  command -v jq >/dev/null 2>&1 || skip "jq absent"

  run --separate-stderr "$SCRIPTS_DIR/reconcile-stale-graph.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --affected-set '["stack-alpha"]' \
    --detected-edges-file "$TEST_TMP/depgraph-clean.json"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-alpha"]' ]]
}

@test "AC4: empty dep-graph edges → affected-set passes through unmodified" {
  command -v yq >/dev/null 2>&1 || skip "yq absent"
  command -v jq >/dev/null 2>&1 || skip "jq absent"

  run --separate-stderr "$SCRIPTS_DIR/reconcile-stale-graph.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --affected-set '["stack-beta"]' \
    --detected-edges-file "$TEST_TMP/depgraph-empty.json"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-beta"]' ]]
}

# ---------------------------------------------------------------------------
# Tool-absent guard: when yq or jq is absent, script degrades to passthrough
# ---------------------------------------------------------------------------

@test "tool-absent: missing yq → graceful passthrough (affected-set unmodified)" {
  # Build a temp bin dir that contains all tools the script needs EXCEPT yq.
  # This shadows any real yq from being found via PATH.
  local fake_bin="$TEST_TMP/fake-no-yq"
  mkdir -p "$fake_bin"
  # Symlink each required tool that is NOT yq/jq into fake_bin.
  local tool
  for tool in bash awk dirname grep sed; do
    local tool_path
    tool_path="$(command -v "$tool" 2>/dev/null || true)"
    if [ -n "$tool_path" ]; then
      ln -sf "$tool_path" "$fake_bin/$tool"
    fi
  done
  # Provide jq (not under test here) so the jq check passes.
  local jq_path
  jq_path="$(command -v jq 2>/dev/null || true)"
  if [ -n "$jq_path" ]; then
    ln -sf "$jq_path" "$fake_bin/jq"
  fi
  # yq is intentionally NOT symlinked → command -v yq will fail.

  run --separate-stderr env PATH="$fake_bin" \
    "$SCRIPTS_DIR/reconcile-stale-graph.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --affected-set '["stack-alpha"]' \
    --detected-edges-file "$TEST_TMP/depgraph-unsanctioned.json"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-alpha"]' ]]
}

@test "tool-absent: missing jq → graceful passthrough (affected-set unmodified)" {
  # Build a temp bin dir that contains all tools the script needs EXCEPT jq.
  local fake_bin="$TEST_TMP/fake-no-jq"
  mkdir -p "$fake_bin"
  local tool
  for tool in bash awk dirname grep sed; do
    local tool_path
    tool_path="$(command -v "$tool" 2>/dev/null || true)"
    if [ -n "$tool_path" ]; then
      ln -sf "$tool_path" "$fake_bin/$tool"
    fi
  done
  # Provide yq (not under test here).
  local yq_path
  yq_path="$(command -v yq 2>/dev/null || true)"
  if [ -n "$yq_path" ]; then
    ln -sf "$yq_path" "$fake_bin/yq"
  else
    skip "yq absent — cannot test jq-absent branch"
  fi
  # jq is intentionally NOT symlinked → command -v jq will fail.

  run --separate-stderr env PATH="$fake_bin" \
    "$SCRIPTS_DIR/reconcile-stale-graph.sh" \
    --config "$TEST_TMP/project-config.yaml" \
    --affected-set '["stack-alpha"]' \
    --detected-edges-file "$TEST_TMP/depgraph-unsanctioned.json"
  [ "$status" -eq 0 ]
  [[ "$output" == '["stack-alpha"]' ]]
}

# ---------------------------------------------------------------------------
# --affected-set required check
# ---------------------------------------------------------------------------

@test "missing --affected-set exits non-zero" {
  run "$SCRIPTS_DIR/reconcile-stale-graph.sh"
  [ "$status" -ne 0 ]
}
