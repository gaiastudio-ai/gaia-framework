#!/usr/bin/env bats
# resolve-publish-adapter.bats — E100-S8 TC-PUB-9 + TC-PUB-10 + SR-81 negative case.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"
  RESOLVER="$PLUGIN_DIR/scripts/lib/resolve-publish-adapter.sh"
  PROJECT_ROOT="$TEST_TMP/project"
  mkdir -p "$PROJECT_ROOT/.gaia/custom/adapters"
}

teardown() { common_teardown; }

_make_custom_adapter() {
  local name="$1"
  local dir="$PROJECT_ROOT/.gaia/custom/adapters/publish-$name"
  mkdir -p "$dir"
  cat > "$dir/run.sh" <<'SHIM'
#!/usr/bin/env bash
echo "custom adapter"
SHIM
  chmod +x "$dir/run.sh"
  cat > "$dir/adapter-manifest.yaml" <<YAML
adapter_name: publish-$name
adapter_version: "1.0.0"
channel: custom
verify_retry_window_seconds: 60
credential_env_vars: []
description: "Test custom adapter."
YAML
}

# ---------- TC-PUB-9: custom-only discovery ----------

@test "custom adapter at .gaia/custom/adapters/publish-my-custom/ is discovered" {
  _make_custom_adapter my-custom
  run "$RESOLVER" --adapter my-custom --project-root "$PROJECT_ROOT" --plugin-root "$PLUGIN_DIR"
  [ "$status" -eq 0 ]
  # Output is absolute path to the custom adapter directory.
  echo "$output" | grep -qF "/.gaia/custom/adapters/publish-my-custom"
}

@test "custom adapter manifest exists at the resolved path" {
  _make_custom_adapter my-custom
  run "$RESOLVER" --adapter my-custom --project-root "$PROJECT_ROOT" --plugin-root "$PLUGIN_DIR"
  [ "$status" -eq 0 ]
  local dir="$output"
  [ -f "$dir/adapter-manifest.yaml" ]
  [ -x "$dir/run.sh" ]
}

# ---------- TC-PUB-10 (shadow): custom shadows built-in ----------

@test "shadow): custom npm shadows built-in; canonical WARN on stderr" {
  _make_custom_adapter npm
  run "$RESOLVER" --adapter npm --project-root "$PROJECT_ROOT" --plugin-root "$PLUGIN_DIR"
  [ "$status" -eq 0 ]
  # Returned path is the CUSTOM adapter (ADR-020 precedence)
  echo "$output" | grep -qF "/.gaia/custom/adapters/publish-npm"
  # Canonical WARN message per AC5
  echo "$output" | grep -qF "WARN: custom adapter at .gaia/custom/adapters/publish-npm/ shadows built-in adapter"
}

@test "built-in only): no custom → built-in wins, no WARN" {
  # No custom adapter — should resolve built-in npm.
  run "$RESOLVER" --adapter npm --project-root "$PROJECT_ROOT" --plugin-root "$PLUGIN_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "scripts/adapters/publish-npm"
  ! echo "$output" | grep -q "WARN:"
}

# ---------- TC-PUB-10 (strict): --strict-builtin refuses sensitive shadow ----------

@test "strict): --strict-builtin HALTs on custom shadow of sensitive npm" {
  _make_custom_adapter npm
  run "$RESOLVER" --adapter npm --strict-builtin --project-root "$PROJECT_ROOT" --plugin-root "$PLUGIN_DIR"
  [ "$status" -eq 3 ]
  echo "$output" | grep -qF "HALT: --strict-builtin refuses custom shadow for sensitive channel"
}

@test "strict, non-sensitive): --strict-builtin does NOT block custom shadow on non-sensitive channel" {
  _make_custom_adapter homebrew  # homebrew is NOT in default sensitive list
  run "$RESOLVER" --adapter homebrew --strict-builtin --project-root "$PROJECT_ROOT" --plugin-root "$PLUGIN_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "/.gaia/custom/adapters/publish-homebrew"
  # WARN still emitted because shadow exists
  echo "$output" | grep -qF "WARN:"
}

# ---------- SR-81 negative case: path-traversal payload ----------

@test "symlink-traversal — C1 from code review): symlinked custom-adapter dir pointing outside .gaia/custom/adapters/ is rejected by physical-path containment" {
  # Construct a custom-adapter directory OUTSIDE the project root, then
  # symlink it into .gaia/custom/adapters/publish-evil/. With `pwd -L` the
  # logical path would resolve under the custom-adapter root and bypass the
  # containment check. With `pwd -P` / `realpath` the symlink is resolved
  # to its physical target and the check correctly refuses.
  local outside="$TEST_TMP/outside-evil"
  mkdir -p "$outside"
  cat > "$outside/run.sh" <<'SHIM'
#!/usr/bin/env bash
echo "evil adapter would run with publish creds"
SHIM
  chmod +x "$outside/run.sh"
  ln -s "$outside" "$PROJECT_ROOT/.gaia/custom/adapters/publish-evil"
  run "$RESOLVER" --adapter evil --project-root "$PROJECT_ROOT" --plugin-root "$PLUGIN_DIR"
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF "HALT: custom adapter resolves outside .gaia/custom/adapters/"
}

@test "traversal payload (../../bin/sh) rejected by regex" {
  run "$RESOLVER" --adapter "../../bin/sh" --project-root "$PROJECT_ROOT" --plugin-root "$PLUGIN_DIR"
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF "violates regex"
}

@test "uppercase in adapter_name rejected" {
  run "$RESOLVER" --adapter "MyAdapter" --project-root "$PROJECT_ROOT" --plugin-root "$PLUGIN_DIR"
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF "violates regex"
}

@test "underscore in adapter_name rejected" {
  run "$RESOLVER" --adapter "my_adapter" --project-root "$PROJECT_ROOT" --plugin-root "$PLUGIN_DIR"
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF "violates regex"
}

@test "65-char name rejected (exceeds 64-char limit)" {
  local n
  n=$(printf 'a%.0s' {1..65})
  run "$RESOLVER" --adapter "$n" --project-root "$PROJECT_ROOT" --plugin-root "$PLUGIN_DIR"
  [ "$status" -eq 2 ]
}

@test "dots in adapter_name rejected" {
  run "$RESOLVER" --adapter "my.adapter" --project-root "$PROJECT_ROOT" --plugin-root "$PLUGIN_DIR"
  [ "$status" -eq 2 ]
}

# ---------- AC1 manifest validation (C1 fix from E100-S8 third pass) ----------

@test "C1 fix): custom adapter without adapter-manifest.yaml is REJECTED" {
  local dir="$PROJECT_ROOT/.gaia/custom/adapters/publish-noyaml"
  mkdir -p "$dir"
  cat > "$dir/run.sh" <<'SHIM'
#!/usr/bin/env bash
echo "no manifest"
SHIM
  chmod +x "$dir/run.sh"
  # No adapter-manifest.yaml
  run "$RESOLVER" --adapter noyaml --project-root "$PROJECT_ROOT" --plugin-root "$PLUGIN_DIR"
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF "HALT: custom adapter missing adapter-manifest.yaml"
}

@test "C1 fix): custom adapter with missing required field is REJECTED" {
  local dir="$PROJECT_ROOT/.gaia/custom/adapters/publish-incomplete"
  mkdir -p "$dir"
  cat > "$dir/run.sh" <<'SHIM'
#!/usr/bin/env bash
echo "incomplete"
SHIM
  chmod +x "$dir/run.sh"
  # Missing required fields (only adapter_name set)
  cat > "$dir/adapter-manifest.yaml" <<YAML
adapter_name: publish-incomplete
YAML
  run "$RESOLVER" --adapter incomplete --project-root "$PROJECT_ROOT" --plugin-root "$PLUGIN_DIR"
  [ "$status" -eq 2 ]
  echo "$output" | grep -qiE 'HALT: custom adapter manifest missing required field'
}

@test "C1 fix): custom adapter with complete manifest is ACCEPTED" {
  _make_custom_adapter complete-test
  run "$RESOLVER" --adapter complete-test --project-root "$PROJECT_ROOT" --plugin-root "$PLUGIN_DIR"
  [ "$status" -eq 0 ]
}

# ---------- Adapter not found ----------

@test "Not found: nonexistent adapter exits 1 with diagnostic" {
  run "$RESOLVER" --adapter doesnt-exist --project-root "$PROJECT_ROOT" --plugin-root "$PLUGIN_DIR"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "adapter not found"
}

# ---------- Project-config schema regex (SR-81 enforced schema-side) ----------

@test "schema): project-config.schema.json adapter_name pattern is ^[a-z0-9-]{1,64}\$" {
  local schema="$PLUGIN_DIR/schemas/project-config.schema.json"
  [ -f "$schema" ]
  local pattern
  pattern=$(jq -r '.definitions.distribution.properties.adapter_name.pattern // .definitions.deployment.properties.adapter_name.pattern // ""' "$schema")
  # The schema's adapter_name pattern (search broadly via grep too)
  grep -qF '"^[a-z0-9-]{1,64}$"' "$schema"
}
