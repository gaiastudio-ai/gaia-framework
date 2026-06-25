#!/usr/bin/env bats
# generate-multi-stack-ci.bats — TDD tests for multi-stack CI workflow generation
#
# Verifies that the skill-local generate-pipeline.sh (or its orchestrating
# wrapper) detects multi-stack configs and generates selective-tests.yml,
# per-component release workflows, and the engine-script delivery mechanism.
# Single-stack configs must still produce only gaia-pre-merge.yml (regression).
#
# Public functions covered: generate_multi_stack_ci, generate_release_workflow,
# vendor_engine_scripts, count_config_stacks.

load 'test_helper.bash'

setup() {
  common_setup

  SKILL_SCRIPTS_DIR="$(cd "$SCRIPTS_DIR/../skills/gaia-ci-setup/scripts" && pwd)"

  # Two-stack config with test_policy and promotion_chain
  cat > "$TEST_TMP/multi-stack-config.yaml" <<'EOF'
project_name: test-multi-stack
stacks:
  - name: backend
    language: python
    paths:
      - "backend/**"
    test_cmd: "pytest -q"
  - name: frontend
    language: node
    paths:
      - "frontend/**"
    cross_refs:
      - backend
    test_cmd: "npm test"
test_policy:
  pr:
    include_stacks: []
  push:
    include_stacks: []
ci_cd:
  promotion_chain:
    - id: dev
      name: Development
      branch: staging
      merge_strategy: squash
    - id: prod
      name: Production
      branch: main
      merge_strategy: merge-commit
EOF

  # Single-stack config (regression guard)
  cat > "$TEST_TMP/single-stack-config.yaml" <<'EOF'
project_name: test-single-stack
stacks:
  - name: api
    language: go
    paths:
      - "cmd/**"
    test_cmd: "go test ./..."
ci_cd:
  promotion_chain:
    - id: dev
      name: Development
      branch: staging
      merge_strategy: squash
EOF

  # Three-stack config
  cat > "$TEST_TMP/three-stack-config.yaml" <<'EOF'
project_name: test-three-stack
stacks:
  - name: backend
    language: python
    paths:
      - "backend/**"
    test_cmd: "pytest -q"
  - name: frontend
    language: node
    paths:
      - "frontend/**"
    cross_refs:
      - backend
    test_cmd: "npm test"
  - name: mobile
    language: node
    paths:
      - "mobile/**"
    cross_refs:
      - backend
    test_cmd: "npm test"
test_policy:
  pr:
    include_stacks: []
ci_cd:
  promotion_chain:
    - id: dev
      name: Development
      branch: staging
      merge_strategy: squash
    - id: prod
      name: Production
      branch: main
      merge_strategy: merge-commit
EOF
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Helper: run the skill-local generator with multi-stack detection
# ---------------------------------------------------------------------------
_run_generator() {
  local config="$1"; shift
  bash "$SKILL_SCRIPTS_DIR/generate-pipeline.sh" \
    --provider github-actions \
    --config "$config" \
    --project-root "$TEST_TMP" \
    "$@"
}

# ---------------------------------------------------------------------------
# AC1: multi-stack config produces selective-tests.yml (TS-1)
# ---------------------------------------------------------------------------

@test "multi-stack config produces selective-tests.yml (AC1)" {
  _run_generator "$TEST_TMP/multi-stack-config.yaml"
  [ -f "$TEST_TMP/.github/workflows/selective-tests.yml" ]
}

@test "generated selective-tests.yml contains matrix referencing both stacks (AC1)" {
  _run_generator "$TEST_TMP/multi-stack-config.yaml"
  local wf="$TEST_TMP/.github/workflows/selective-tests.yml"
  [ -f "$wf" ]
  # Must reference the selective-test-driver or detect-affected pipeline
  grep -qE 'selective-test-driver|detect-affected' "$wf"
  # Must reference matrix strategy
  grep -qE 'matrix|strategy' "$wf"
}

@test "generated selective-tests.yml wires promotion_chain escalation (AC1)" {
  _run_generator "$TEST_TMP/multi-stack-config.yaml"
  local wf="$TEST_TMP/.github/workflows/selective-tests.yml"
  [ -f "$wf" ]
  # Must contain promotion-push escalation wiring
  grep -qE 'promotion-push|promotion' "$wf"
}

@test "generated selective-tests.yml wires cross_refs transitive closure (AC1)" {
  _run_generator "$TEST_TMP/multi-stack-config.yaml"
  local wf="$TEST_TMP/.github/workflows/selective-tests.yml"
  [ -f "$wf" ]
  # Must reference cross-refs-walk or the driver that chains it
  grep -qE 'selective-test-driver|cross-refs-walk' "$wf"
}

@test "three-stack config also produces selective-tests.yml (AC1)" {
  _run_generator "$TEST_TMP/three-stack-config.yaml"
  [ -f "$TEST_TMP/.github/workflows/selective-tests.yml" ]
}

# ---------------------------------------------------------------------------
# AC2: multi-stack config produces per-component release workflow (TS-2)
# ---------------------------------------------------------------------------

@test "multi-stack config produces per-component release workflow (AC2)" {
  _run_generator "$TEST_TMP/multi-stack-config.yaml"
  [ -f "$TEST_TMP/.github/workflows/gaia-release.yml" ]
}

@test "per-component release workflow scopes to affected components (AC2)" {
  _run_generator "$TEST_TMP/multi-stack-config.yaml"
  local wf="$TEST_TMP/.github/workflows/gaia-release.yml"
  [ -f "$wf" ]
  # Must reference affected-set or component scoping
  grep -qE 'affected|component|matrix' "$wf"
}

# ---------------------------------------------------------------------------
# AC3: multi-stack branch reuses existing generators (TS-7)
# ---------------------------------------------------------------------------

@test "multi-stack generation references vendored ci-scripts path (AC3)" {
  _run_generator "$TEST_TMP/multi-stack-config.yaml"
  local wf="$TEST_TMP/.github/workflows/selective-tests.yml"
  [ -f "$wf" ]
  # Must reference the vendored path (.gaia/ci-scripts/), NOT plugins/gaia/scripts/
  grep -qE '\.gaia/ci-scripts/selective-test-driver' "$wf"
  ! grep -qE 'plugins/gaia/scripts/' "$wf"
}

@test "multi-stack generation references detect-affected via vendored path (AC3)" {
  _run_generator "$TEST_TMP/multi-stack-config.yaml"
  local wf="$TEST_TMP/.github/workflows/selective-tests.yml"
  [ -f "$wf" ]
  # The workflow comment or driver must use detect-affected
  grep -qE 'detect-affected' "$wf"
}

# ---------------------------------------------------------------------------
# AC4: engine-script delivery mechanism (TS-4)
# ---------------------------------------------------------------------------

@test "multi-stack generation deposits engine scripts at tracked path (AC4)" {
  _run_generator "$TEST_TMP/multi-stack-config.yaml"
  # Engine scripts must be vendored under a tracked path
  [ -d "$TEST_TMP/.gaia/ci-scripts" ]
}

@test "engine-script delivery includes drift manifest (AC4)" {
  _run_generator "$TEST_TMP/multi-stack-config.yaml"
  [ -f "$TEST_TMP/.gaia/ci-scripts/MANIFEST.sha256" ]
}

@test "drift manifest lists the vendored engine scripts (AC4)" {
  _run_generator "$TEST_TMP/multi-stack-config.yaml"
  local manifest="$TEST_TMP/.gaia/ci-scripts/MANIFEST.sha256"
  [ -f "$manifest" ]
  # Must list the driver and detect-affected scripts
  grep -qE 'selective-test-driver' "$manifest"
  grep -qE 'detect-affected' "$manifest"
}

# ---------------------------------------------------------------------------
# AC5: single-stack config still produces only gaia-pre-merge.yml (TS-3)
# ---------------------------------------------------------------------------

@test "single-stack config produces gaia-pre-merge.yml (AC5)" {
  _run_generator "$TEST_TMP/single-stack-config.yaml" --stack go
  [ -f "$TEST_TMP/.github/workflows/gaia-pre-merge.yml" ]
}

@test "single-stack config does NOT produce selective-tests.yml (AC5)" {
  _run_generator "$TEST_TMP/single-stack-config.yaml" --stack go
  [ ! -f "$TEST_TMP/.github/workflows/selective-tests.yml" ]
}

@test "single-stack config does NOT produce gaia-release.yml (AC5)" {
  _run_generator "$TEST_TMP/single-stack-config.yaml" --stack go
  [ ! -f "$TEST_TMP/.github/workflows/gaia-release.yml" ]
}

@test "single-stack config does NOT deposit engine scripts (AC5)" {
  _run_generator "$TEST_TMP/single-stack-config.yaml" --stack go
  [ ! -d "$TEST_TMP/.gaia/ci-scripts" ]
}

# ---------------------------------------------------------------------------
# count_config_stacks helper unit tests
# ---------------------------------------------------------------------------

@test "count_config_stacks returns 2 for two-stack config" {
  source "$SKILL_SCRIPTS_DIR/generate-pipeline.sh"
  local count
  count="$(count_config_stacks "$TEST_TMP/multi-stack-config.yaml")"
  [ "$count" -eq 2 ]
}

@test "count_config_stacks returns 1 for single-stack config" {
  source "$SKILL_SCRIPTS_DIR/generate-pipeline.sh"
  local count
  count="$(count_config_stacks "$TEST_TMP/single-stack-config.yaml")"
  [ "$count" -eq 1 ]
}

@test "count_config_stacks returns 3 for three-stack config" {
  source "$SKILL_SCRIPTS_DIR/generate-pipeline.sh"
  local count
  count="$(count_config_stacks "$TEST_TMP/three-stack-config.yaml")"
  [ "$count" -eq 3 ]
}

@test "count_config_stacks returns 0 for empty stacks list (AC5)" {
  cat > "$TEST_TMP/zero-stack-config.yaml" <<'EOF'
project_name: test-zero-stack
stacks: []
ci_cd:
  promotion_chain:
    - id: dev
      name: Development
      branch: staging
      merge_strategy: squash
EOF
  source "$SKILL_SCRIPTS_DIR/generate-pipeline.sh"
  local count
  count="$(count_config_stacks "$TEST_TMP/zero-stack-config.yaml")"
  [ "$count" -eq 0 ]
}

@test "count_config_stacks returns 0 when stacks key is absent (AC5)" {
  cat > "$TEST_TMP/no-stacks-config.yaml" <<'EOF'
project_name: test-no-stacks
ci_cd:
  promotion_chain:
    - id: dev
      name: Development
      branch: staging
      merge_strategy: squash
EOF
  source "$SKILL_SCRIPTS_DIR/generate-pipeline.sh"
  local count
  count="$(count_config_stacks "$TEST_TMP/no-stacks-config.yaml")"
  [ "$count" -eq 0 ]
}

@test "zero-stack config routes to single-stack path (AC5)" {
  cat > "$TEST_TMP/zero-stack-config.yaml" <<'EOF'
project_name: test-zero-stack
stacks: []
ci_cd:
  promotion_chain:
    - id: dev
      name: Development
      branch: staging
      merge_strategy: squash
EOF
  # Zero stacks + explicit --stack should produce gaia-pre-merge.yml
  _run_generator "$TEST_TMP/zero-stack-config.yaml" --stack go
  [ -f "$TEST_TMP/.github/workflows/gaia-pre-merge.yml" ]
  [ ! -f "$TEST_TMP/.github/workflows/selective-tests.yml" ]
}

# ---------------------------------------------------------------------------
# Vendored-path correctness: generated workflows MUST reference .gaia/ci-scripts/
# and MUST NOT reference plugins/gaia/scripts/ (the framework repo-local path).
# ---------------------------------------------------------------------------

@test "generated selective-tests.yml references .gaia/ci-scripts/ not plugins/gaia/scripts/ (AC4)" {
  _run_generator "$TEST_TMP/multi-stack-config.yaml"
  local wf="$TEST_TMP/.github/workflows/selective-tests.yml"
  [ -f "$wf" ]
  grep -qE '\.gaia/ci-scripts/' "$wf"
  ! grep -qE 'plugins/gaia/scripts/[a-z]' "$wf"
}

@test "generated gaia-release.yml references .gaia/ci-scripts/ not plugins/gaia/scripts/ (AC4)" {
  _run_generator "$TEST_TMP/multi-stack-config.yaml"
  local wf="$TEST_TMP/.github/workflows/gaia-release.yml"
  [ -f "$wf" ]
  grep -qE '\.gaia/ci-scripts/' "$wf"
  ! grep -qE 'plugins/gaia/scripts/[a-z]' "$wf"
}

@test "release workflow marks release step as operator extension point (AC2)" {
  _run_generator "$TEST_TMP/multi-stack-config.yaml"
  local wf="$TEST_TMP/.github/workflows/gaia-release.yml"
  [ -f "$wf" ]
  grep -qE 'TODO.*operator.*wire' "$wf"
}

@test "vendored ci-scripts include every script the workflows reference (AC4)" {
  _run_generator "$TEST_TMP/multi-stack-config.yaml"
  local ci_dir="$TEST_TMP/.gaia/ci-scripts"
  [ -d "$ci_dir" ]
  # Every script the selective-tests and release workflows call must exist
  [ -f "$ci_dir/selective-test-driver.sh" ]
  [ -f "$ci_dir/detect-affected.sh" ]
  [ -f "$ci_dir/run-stack-tests.sh" ]
  [ -f "$ci_dir/generate-pipeline.sh" ]
  [ -f "$ci_dir/cross-refs-walk.sh" ]
  [ -f "$ci_dir/reconcile-stale-graph.sh" ]
  [ -f "$ci_dir/apply-test-policy.sh" ]
  # lib/ must also be vendored (resolve-file-to-stack.sh etc.)
  [ -d "$ci_dir/lib" ]
}
