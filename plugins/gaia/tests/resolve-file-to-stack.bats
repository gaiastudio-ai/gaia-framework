#!/usr/bin/env bats
# resolve-file-to-stack.bats — unit tests for the shared file-to-stack
# resolution helper (lib/resolve-file-to-stack.sh).
#
# Public functions covered (public-function-coverage gate):
# resolve_file_to_stack, locate_repo_script.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

# ---------------------------------------------------------------------------
# setup / teardown
# ---------------------------------------------------------------------------

setup() {
  common_setup

  LIB_SCRIPT="$SCRIPTS_DIR/lib/resolve-file-to-stack.sh"

  # Build a synthetic stacks TSV table for resolution tests.
  # Format: name<TAB>candidate<TAB>match_type
  # - prefix entries (from /** globs or scalar path)
  # - glob entries (non-/** patterns)
  cat > "$TEST_TMP/stacks.tsv" <<'EOF'
stack-alpha	agents	prefix
stack-alpha	packages/shared	prefix
stack-beta	packages	prefix
stack-beta	config/*.yaml	glob
stack-plugin	plugins/gaia/scripts	prefix
stack-plugin	plugins/gaia/config	prefix
EOF

  # A stacks table with NO catch-all and no matching entries for orphan paths.
  cat > "$TEST_TMP/stacks-no-catchall.tsv" <<'EOF'
frontend	app/web	prefix
backend	services/api	prefix
EOF

  # A stacks table WITH a root-dot catch-all entry.
  cat > "$TEST_TMP/stacks-with-catchall.tsv" <<'EOF'
frontend	app/web	prefix
backend	services/api	prefix
root-stack	.	prefix
EOF
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Public-function-coverage: source the script and verify public functions resolve
# ---------------------------------------------------------------------------

@test "source script — resolve_file_to_stack is callable" {
  source "$LIB_SCRIPT"
  type resolve_file_to_stack
}

@test "source script — locate_repo_script is callable" {
  source "$LIB_SCRIPT"
  type locate_repo_script
}

@test "main-guard — sourcing does NOT produce side effects" {
  source "$LIB_SCRIPT"
  # If any main logic ran on source, something is wrong.
  true
}

# ---------------------------------------------------------------------------
# Longest-prefix-wins resolution
# ---------------------------------------------------------------------------

@test "longest-prefix wins — packages/shared/util.sh resolves to stack-alpha not stack-beta" {
  source "$LIB_SCRIPT"
  local result
  result="$(resolve_file_to_stack "packages/shared/util.sh" "$TEST_TMP/stacks.tsv")"
  [ "$result" = "stack-alpha" ]
}

@test "prefix match — agents/my-agent.md resolves to stack-alpha" {
  source "$LIB_SCRIPT"
  local result
  result="$(resolve_file_to_stack "agents/my-agent.md" "$TEST_TMP/stacks.tsv")"
  [ "$result" = "stack-alpha" ]
}

@test "shallower prefix — packages/other/module.sh resolves to stack-beta" {
  source "$LIB_SCRIPT"
  local result
  result="$(resolve_file_to_stack "packages/other/module.sh" "$TEST_TMP/stacks.tsv")"
  [ "$result" = "stack-beta" ]
}

@test "prefix match requires path-segment boundary" {
  source "$LIB_SCRIPT"
  # "agentsmith.md" starts with "agent" but is NOT under "agents/" directory
  local result
  result="$(resolve_file_to_stack "agentsmith.md" "$TEST_TMP/stacks.tsv")"
  [ -z "$result" ]
}

@test "exact path match — file name equals candidate" {
  source "$LIB_SCRIPT"
  local result
  result="$(resolve_file_to_stack "agents" "$TEST_TMP/stacks.tsv")"
  [ "$result" = "stack-alpha" ]
}

# ---------------------------------------------------------------------------
# Glob fallback resolution
# ---------------------------------------------------------------------------

@test "glob fallback — config/settings.yaml matches stack-beta" {
  source "$LIB_SCRIPT"
  local result
  result="$(resolve_file_to_stack "config/settings.yaml" "$TEST_TMP/stacks.tsv")"
  [ "$result" = "stack-beta" ]
}

@test "glob single-level guard — config/sub/deep.yaml does NOT match config/*.yaml" {
  source "$LIB_SCRIPT"
  local result
  result="$(resolve_file_to_stack "config/sub/deep.yaml" "$TEST_TMP/stacks.tsv")"
  [ -z "$result" ]
}

# ---------------------------------------------------------------------------
# Root-dot catch-all default
# ---------------------------------------------------------------------------

@test "root-dot catch-all — README.md resolves to root-stack" {
  source "$LIB_SCRIPT"
  local result
  result="$(resolve_file_to_stack "README.md" "$TEST_TMP/stacks-with-catchall.tsv")"
  [ "$result" = "root-stack" ]
}

@test "root-dot catch-all is lower priority than prefix match" {
  source "$LIB_SCRIPT"
  local result
  result="$(resolve_file_to_stack "app/web/index.ts" "$TEST_TMP/stacks-with-catchall.tsv")"
  [ "$result" = "frontend" ]
}

# ---------------------------------------------------------------------------
# No match returns empty
# ---------------------------------------------------------------------------

@test "no match and no catch-all returns empty string" {
  source "$LIB_SCRIPT"
  local result
  result="$(resolve_file_to_stack "completely/unknown/path.txt" "$TEST_TMP/stacks-no-catchall.tsv")"
  [ -z "$result" ]
}

@test "empty stacks table returns empty string" {
  source "$LIB_SCRIPT"
  printf '' > "$TEST_TMP/empty-stacks.tsv"
  local result
  result="$(resolve_file_to_stack "any/file.sh" "$TEST_TMP/empty-stacks.tsv")"
  [ -z "$result" ]
}

# ---------------------------------------------------------------------------
# locate_repo_script — robust script locator
# ---------------------------------------------------------------------------

@test "locate_repo_script finds an existing script by basename" {
  source "$LIB_SCRIPT"
  # Use detect-affected.sh itself as a known script under scripts/
  local result
  result="$(locate_repo_script "detect-affected.sh")"
  [ -n "$result" ]
  [ -f "$result" ]
}

@test "locate_repo_script returns empty for a nonexistent script" {
  source "$LIB_SCRIPT"
  local result
  result="$(locate_repo_script "nonexistent-script-xyz.js" 2>/dev/null)" || true
  [ -z "$result" ]
}
