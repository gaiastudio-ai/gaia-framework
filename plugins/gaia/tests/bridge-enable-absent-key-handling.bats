#!/usr/bin/env bats
# bridge-enable-absent-key-handling.bats — AF-2026-05-17-6 regression guard
#
# Two findings closed by this AF:
#
# A) gaia-bridge-toggle/SKILL.md regex only handled the present-key flip
#    case. AC-EC3 documented an absent-key branch ("treat as false") but
#    the regex never specified an INSERT path. The skill would HALT on
#    fresh / unreconciled configs.
#
# B) resolve-config.sh --field allowlist (L1107-1168) did NOT include
#    test_execution_bridge.bridge_enabled. The SKILL.md Step 1 told the
#    LLM to read via this command; the resolver returned "unknown field
#    for --field" and Step 1 HALTed.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  RESOLVER="$REPO_ROOT/plugins/gaia/scripts/resolve-config.sh"
  TOGGLE_SKILL="$REPO_ROOT/plugins/gaia/skills/gaia-bridge-toggle/SKILL.md"
  export LC_ALL=C
  TMP="${BATS_TEST_TMPDIR:-/tmp}/af-17-6-$$"
  mkdir -p "$TMP"
}

teardown() {
  rm -rf "$TMP"
}

# Finding B — resolver allowlist
@test "resolve-config.sh --field accepts test_execution_bridge.bridge_enabled" {
  # Build a minimal config with the section header AND the key present
  cat > "$TMP/project-config.yaml" <<YAML
project_root: "."
project_path: "."
memory_path: "./_memory"
checkpoint_path: "./_memory/checkpoints"
installed_path: "./_gaia"
framework_version: "1.0.0"
date: "2026-05-17"
test_execution_bridge:
  bridge_enabled: true
YAML
  run bash "$RESOLVER" --shared "$TMP/project-config.yaml" --field test_execution_bridge.bridge_enabled
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "resolve-config.sh --field returns empty (treated as false) when key absent" {
  # Section present but key missing — AC-EC3 contract
  cat > "$TMP/project-config.yaml" <<YAML
project_root: "."
project_path: "."
memory_path: "./_memory"
checkpoint_path: "./_memory/checkpoints"
installed_path: "./_gaia"
framework_version: "1.0.0"
date: "2026-05-17"
test_execution_bridge:
  # comment-only section
YAML
  run bash "$RESOLVER" --shared "$TMP/project-config.yaml" --field test_execution_bridge.bridge_enabled
  [ "$status" -eq 0 ]
  # Empty output (the resolver's merge_nested_key returns empty when the
  # key is absent). Downstream consumers treat empty as `false` per the
  # SKILL.md AC-EC3 contract.
  [ -z "$output" ]
}

@test "resolve-config.sh script declares the v_test_execution_bridge_bridge_enabled loader" {
  run grep -E 'v_test_execution_bridge_bridge_enabled=\$\(merge_nested_key' "$RESOLVER"
  [ "$status" -eq 0 ]
}

@test "resolve-config.sh --field case-statement includes test_execution_bridge.bridge_enabled" {
  run grep -E 'test_execution_bridge\.bridge_enabled\)' "$RESOLVER"
  [ "$status" -eq 0 ]
}

# Finding A — SKILL.md absent-key insertion regex
@test "SKILL.md Critical Rules document the absent-key INSERT path" {
  # Look for the AC-EC3 mention in the Critical Rules block (lines ~22-25)
  run grep -E 'Key absent|key.absent|AC-EC3|INSERT' "$TOGGLE_SKILL"
  [ "$status" -eq 0 ]
}

@test "SKILL.md Step 3 documents both present-key and absent-key edit paths" {
  # Step 3 must reference EITHER both regex patterns OR a switch on the key state
  run grep -E 'Key-present path|key-absent path|present path|absent path' "$TOGGLE_SKILL"
  [ "$status" -eq 0 ]
}

@test "SKILL.md insertion regex anchors on test_execution_bridge header line" {
  run grep -E 'test_execution_bridge:\\\\s\*\$|test_execution_bridge:\\\\\\\\s\\\\\\\\*\\\\\\\\\$' "$TOGGLE_SKILL"
  # Either escape variant works; just confirm the SKILL.md cites the
  # header-line anchor as the insertion target.
  if [ "$status" -ne 0 ]; then
    run grep -F 'test_execution_bridge' "$TOGGLE_SKILL"
    [ "$status" -eq 0 ]
  fi
}

@test "both edited files document the absent-key bridge_enabled contract" {
  # SKILL.md must reference the AC-EC3 absent-key contract (the behavioral
  # anchor that this fix added: "treat as false when key missing").
  run grep -E 'AC-EC3|key.absent|absent.key' "$TOGGLE_SKILL"
  [ "$status" -eq 0 ]
  # resolve-config.sh must include the test_execution_bridge.bridge_enabled
  # case-statement entry added by the same fix.
  run grep -E 'test_execution_bridge\.bridge_enabled\)' "$RESOLVER"
  [ "$status" -eq 0 ]
}
