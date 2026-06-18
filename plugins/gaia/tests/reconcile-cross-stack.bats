#!/usr/bin/env bats
# reconcile-cross-stack.bats — TDD tests for the cross-stack import-edge detector.
#
# Covers the paths-glob-list extension to stacks[].paths[] (alongside the
# existing stacks[].path scalar). Also covers the unowned-file stderr log.
#
# Public functions covered (NFR-052): file_to_stack, ref_allowed,
# _cross_refs_for.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

# ---------------------------------------------------------------------------
# setup / teardown
# ---------------------------------------------------------------------------

setup() {
  common_setup

  DETECTOR="$SCRIPTS_DIR/adapters/brownfield/reconcile-cross-stack.sh"

  # --- paths-glob config: stacks use paths[] list, NO scalar path ---
  cat > "$TEST_TMP/config-paths-glob.yaml" <<'EOF'
stacks:
  - name: frontend
    language: typescript
    paths:
      - "app/web/**"
      - "app/mobile/**"
    cross_refs: []
  - name: backend
    language: python
    paths:
      - "services/api/**"
    cross_refs: []
EOF

  # --- paths-glob config with cross_refs declared (clean) ---
  cat > "$TEST_TMP/config-paths-glob-clean.yaml" <<'EOF'
stacks:
  - name: frontend
    language: typescript
    paths:
      - "app/web/**"
      - "app/mobile/**"
    cross_refs:
      - backend
  - name: backend
    language: python
    paths:
      - "services/api/**"
    cross_refs: []
EOF

  # --- config with BOTH path scalar AND paths list ---
  cat > "$TEST_TMP/config-both.yaml" <<'EOF'
stacks:
  - name: frontend
    language: typescript
    path: "app/web"
    paths:
      - "app/mobile/**"
    cross_refs: []
  - name: backend
    language: python
    path: "services/api"
    paths:
      - "services/worker/**"
    cross_refs: []
EOF

  # --- dep-graph with unsanctioned cross-stack edge (frontend -> backend) ---
  cat > "$TEST_TMP/depgraph-paths-unsanctioned.json" <<'EOF'
{
  "edges": [
    {"source": "app/web/src/client.ts", "target": "services/api/routes.py"}
  ]
}
EOF

  # --- dep-graph with edge sanctioned by cross_refs ---
  cat > "$TEST_TMP/depgraph-paths-sanctioned.json" <<'EOF'
{
  "edges": [
    {"source": "app/web/src/client.ts", "target": "services/api/routes.py"}
  ]
}
EOF

  # --- dep-graph with edge using paths-list glob match (mobile -> api) ---
  cat > "$TEST_TMP/depgraph-both-unsanctioned.json" <<'EOF'
{
  "edges": [
    {"source": "app/mobile/src/sdk.ts", "target": "services/worker/tasks.py"}
  ]
}
EOF

  # --- dep-graph with file matching no stack ---
  cat > "$TEST_TMP/depgraph-unowned.json" <<'EOF'
{
  "edges": [
    {"source": "orphan/misc/tool.sh", "target": "services/api/routes.py"}
  ]
}
EOF
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# paths-glob: undeclared cross-stack edge is detected and reported
# ---------------------------------------------------------------------------

@test "paths-glob config with undeclared edge emits warning" {
  command -v yq >/dev/null 2>&1 || skip "yq absent"
  command -v jq >/dev/null 2>&1 || skip "jq absent"

  local out
  out="$(XSTACK_CONFIG="$TEST_TMP/config-paths-glob.yaml" \
    XSTACK_DEPGRAPH="$TEST_TMP/depgraph-paths-unsanctioned.json" \
    GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
    GAIA_BROWNFIELD_PHASE_4B_CROSS_STACK_ENABLED=true \
    bash "$DETECTOR" 2>/dev/null)" || true

  # The detector must report the unsanctioned edge (frontend -> backend).
  echo "$out" | grep -q 'unsanctioned-cross-stack-reference'
  echo "$out" | grep -q 'frontend'
  echo "$out" | grep -q 'backend'
}

# ---------------------------------------------------------------------------
# paths-glob: all edges declared → clean passthrough, no false escalation
# ---------------------------------------------------------------------------

@test "paths-glob config with all edges declared emits zero warnings" {
  command -v yq >/dev/null 2>&1 || skip "yq absent"
  command -v jq >/dev/null 2>&1 || skip "jq absent"

  local out
  out="$(XSTACK_CONFIG="$TEST_TMP/config-paths-glob-clean.yaml" \
    XSTACK_DEPGRAPH="$TEST_TMP/depgraph-paths-sanctioned.json" \
    GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
    GAIA_BROWNFIELD_PHASE_4B_CROSS_STACK_ENABLED=true \
    bash "$DETECTOR" 2>/dev/null)" || true

  # Must NOT contain any unsanctioned warning.
  local match_count
  match_count="$(echo "$out" | grep -c 'unsanctioned-cross-stack-reference' || true)"
  [ "$match_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# BOTH path scalar AND paths list → both consulted
# ---------------------------------------------------------------------------

@test "config with both path scalar and paths list consults both" {
  command -v yq >/dev/null 2>&1 || skip "yq absent"
  command -v jq >/dev/null 2>&1 || skip "jq absent"

  # The edge is: app/mobile/src/sdk.ts (frontend via paths[]) ->
  #              services/worker/tasks.py (backend via paths[]).
  # Neither stack's cross_refs allows this edge.
  local out
  out="$(XSTACK_CONFIG="$TEST_TMP/config-both.yaml" \
    XSTACK_DEPGRAPH="$TEST_TMP/depgraph-both-unsanctioned.json" \
    GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
    GAIA_BROWNFIELD_PHASE_4B_CROSS_STACK_ENABLED=true \
    bash "$DETECTOR" 2>/dev/null)" || true

  # The edge must be detected as cross-stack (frontend -> backend).
  echo "$out" | grep -q 'unsanctioned-cross-stack-reference'
  echo "$out" | grep -q 'frontend'
  echo "$out" | grep -q 'backend'
}

# ---------------------------------------------------------------------------
# Unowned file → logged to stderr (info), not silently dropped
# ---------------------------------------------------------------------------

@test "file matching no stack is logged as unowned to stderr" {
  command -v yq >/dev/null 2>&1 || skip "yq absent"
  command -v jq >/dev/null 2>&1 || skip "jq absent"

  local stderr_out
  stderr_out="$(XSTACK_CONFIG="$TEST_TMP/config-paths-glob.yaml" \
    XSTACK_DEPGRAPH="$TEST_TMP/depgraph-unowned.json" \
    GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
    GAIA_BROWNFIELD_PHASE_4B_CROSS_STACK_ENABLED=true \
    bash "$DETECTOR" 2>&1 >/dev/null)" || true

  # stderr must mention the unowned file.
  echo "$stderr_out" | grep -qi 'unowned'
}

# ---------------------------------------------------------------------------
# Backward compatibility: path-scalar-only config still works
# ---------------------------------------------------------------------------

@test "path-scalar-only config still resolves files correctly" {
  command -v yq >/dev/null 2>&1 || skip "yq absent"
  command -v jq >/dev/null 2>&1 || skip "jq absent"

  # Reuse the stale-graph test pattern: scalar path config with no cross_refs.
  cat > "$TEST_TMP/config-scalar.yaml" <<'EOF'
stacks:
  - name: alpha
    language: bash
    path: "alpha"
  - name: beta
    language: bash
    path: "beta"
EOF

  cat > "$TEST_TMP/depgraph-scalar.json" <<'EOF'
{
  "edges": [
    {"source": "beta/src/main.sh", "target": "alpha/lib/util.sh"}
  ]
}
EOF

  local out
  out="$(XSTACK_CONFIG="$TEST_TMP/config-scalar.yaml" \
    XSTACK_DEPGRAPH="$TEST_TMP/depgraph-scalar.json" \
    GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
    GAIA_BROWNFIELD_PHASE_4B_CROSS_STACK_ENABLED=true \
    bash "$DETECTOR" 2>/dev/null)" || true

  # Edge must be detected (beta -> alpha, no cross_refs declared).
  echo "$out" | grep -q 'unsanctioned-cross-stack-reference'
}

# ---------------------------------------------------------------------------
# Regression pin: non-** glob single-level depth guard through reconcile
#
# The shared resolution library applies a single-level depth guard for non-**
# globs: config/*.yaml matches config/foo.yaml but NOT config/sub/deep.yaml.
# Before the shared lib was introduced, reconcile used a bare bash case-glob
# that let * span /, so it WOULD have matched the deep file. The stricter
# behavior is intentional and more correct. These tests pin it so a future
# change that accidentally re-widens the matching will fail.
# ---------------------------------------------------------------------------

@test "non-** glob depth guard: deep file resolves to unowned through reconcile" {
  command -v yq >/dev/null 2>&1 || skip "yq absent"
  command -v jq >/dev/null 2>&1 || skip "jq absent"

  # Config: stack "cfg" owns config/*.yaml (non-** glob, single-level only).
  # Stack "api" owns services/api/** (recursive, for the edge target).
  cat > "$TEST_TMP/config-depth-guard.yaml" <<'EOF'
stacks:
  - name: cfg
    language: yaml
    paths:
      - "config/*.yaml"
    cross_refs: []
  - name: api
    language: python
    paths:
      - "services/api/**"
    cross_refs: []
EOF

  # Edge: a deep file (config/sub/deep.yaml) imports from api.
  # Under the depth guard, config/sub/deep.yaml does NOT match config/*.yaml
  # so its source stack is UNOWNED — the edge is skipped, not reported.
  cat > "$TEST_TMP/depgraph-depth-deep.json" <<'EOF'
{
  "edges": [
    {"source": "config/sub/deep.yaml", "target": "services/api/routes.py"}
  ]
}
EOF

  local out stderr_out
  stderr_out="$(XSTACK_CONFIG="$TEST_TMP/config-depth-guard.yaml" \
    XSTACK_DEPGRAPH="$TEST_TMP/depgraph-depth-deep.json" \
    GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
    GAIA_BROWNFIELD_PHASE_4B_CROSS_STACK_ENABLED=true \
    bash "$DETECTOR" 2>&1 >/dev/null)" || true

  out="$(XSTACK_CONFIG="$TEST_TMP/config-depth-guard.yaml" \
    XSTACK_DEPGRAPH="$TEST_TMP/depgraph-depth-deep.json" \
    GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
    GAIA_BROWNFIELD_PHASE_4B_CROSS_STACK_ENABLED=true \
    bash "$DETECTOR" 2>/dev/null)" || true

  # The deep file must NOT trigger a cross-stack warning — it is unowned.
  local match_count
  match_count="$(echo "$out" | grep -c 'unsanctioned-cross-stack-reference' || true)"
  [ "$match_count" -eq 0 ]

  # stderr should mention the file as unowned.
  echo "$stderr_out" | grep -qi 'unowned'
}

@test "non-** glob depth guard: shallow file resolves to owning stack through reconcile" {
  command -v yq >/dev/null 2>&1 || skip "yq absent"
  command -v jq >/dev/null 2>&1 || skip "jq absent"

  # Same config: stack "cfg" owns config/*.yaml (single level).
  # Stack "api" owns services/api/**.
  cat > "$TEST_TMP/config-depth-guard.yaml" <<'EOF'
stacks:
  - name: cfg
    language: yaml
    paths:
      - "config/*.yaml"
    cross_refs: []
  - name: api
    language: python
    paths:
      - "services/api/**"
    cross_refs: []
EOF

  # Edge: a shallow file (config/settings.yaml) imports from api.
  # Under the depth guard, config/settings.yaml DOES match config/*.yaml
  # so its source stack is "cfg" — the edge IS a cross-stack reference.
  cat > "$TEST_TMP/depgraph-depth-shallow.json" <<'EOF'
{
  "edges": [
    {"source": "config/settings.yaml", "target": "services/api/routes.py"}
  ]
}
EOF

  local out
  out="$(XSTACK_CONFIG="$TEST_TMP/config-depth-guard.yaml" \
    XSTACK_DEPGRAPH="$TEST_TMP/depgraph-depth-shallow.json" \
    GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
    GAIA_BROWNFIELD_PHASE_4B_CROSS_STACK_ENABLED=true \
    bash "$DETECTOR" 2>/dev/null)" || true

  # The shallow file DOES resolve to "cfg" — the edge is a real cross-stack
  # reference (cfg -> api) and must be reported as unsanctioned.
  echo "$out" | grep -q 'unsanctioned-cross-stack-reference'
  echo "$out" | grep -q 'cfg'
  echo "$out" | grep -q 'api'
}
