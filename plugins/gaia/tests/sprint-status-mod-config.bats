#!/usr/bin/env bats
# bats file_tags=config
# sprint-status-mod-config.bats — schema surface, hydration classification,
# reconciler skip behaviour, and config-show extract for the sprint_status_mod
# config section.
#
# Negative scenarios (unknown key, empty-string alias) run UNCONDITIONALLY — no
# skip guard. Each asserts exit 1 AND output is not "PASS (DEGRADED)" so a
# missing schema engine is a hard failure.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

setup() {
  common_setup

  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  VALIDATOR="$PLUGIN_ROOT/scripts/validate-project-config.sh"
  EDITOR="$PLUGIN_ROOT/scripts/config-yaml-editor.sh"
  RECONCILER="$PLUGIN_ROOT/scripts/gaia-reconcile-v2.sh"
  HYDRATION="$PLUGIN_ROOT/scripts/lib/config-hydration.sh"
  SCHEMA="$PLUGIN_ROOT/schemas/project-config.schema.json"

  # The seven required top-level keys. Without these the validator fails for
  # the wrong reason and every assertion below becomes meaningless.
  BASE_REQUIRED='project_root: /tmp/test-project
project_path: /tmp/test-project/src
memory_path: /tmp/test-project/.gaia/memory
checkpoint_path: /tmp/test-project/.gaia/checkpoints
installed_path: /tmp/test-project/.gaia/installed
framework_version: "1.220.2"
date: "2026-10-12"'
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# _write_config <extra-yaml> — compose the seven required keys + extra, echo
# the path. Uses a per-call counter so multiple configs in one test do not
# collide.
_write_config() {
  _WRITE_CFG_N=$(( ${_WRITE_CFG_N:-0} + 1 ))
  local out="$TEST_TMP/config-${_WRITE_CFG_N}.yaml"
  printf '%s\n%s\n' "$BASE_REQUIRED" "$1" > "$out"
  printf '%s' "$out"
}

# _assert_schema_declares — fail unless the schema defines sprint_status_mod.
# Guards positive-validation tests against vacuously passing via the top-level
# additionalProperties: true when the property is absent from the schema.
_assert_schema_declares() {
  jq -e '.properties | has("sprint_status_mod")' "$SCHEMA" >/dev/null
}

# _assert_validator_rejects <config-yaml> [expected-field] — run the validator
# on a config that must be rejected. Asserts exit 1, that the validator used a
# full schema engine (not the degraded jq-only path), and optionally that the
# error output names the expected field.
_assert_validator_rejects() {
  local cfg="$1"
  local expected_field="${2:-}"
  run "$VALIDATOR" "$cfg"
  [ "$status" -eq 1 ]
  [[ "$output" != *"PASS (DEGRADED)"* ]]
  if [ -n "$expected_field" ]; then
    [[ "$output" == *"$expected_field"* ]]
  fi
}

# _assert_validator_passes <config-yaml> — run the validator on a config that
# must pass. Asserts exit 0 AND a full (non-degraded) PASS so tests cannot
# vacuously pass on a runner without a schema engine.
_assert_validator_passes() {
  run "$VALIDATOR" "$1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
  [[ "$output" != *"PASS (DEGRADED)"* ]]
}

# _write_reconciler_fixture <tmpdir> [omit-sections...] — write a project
# config under <tmpdir>/config/ with every allowlisted section present except
# the named ones, plus managed-elsewhere identity fields. schema_version is
# set below the schema title version so the reconciler enters the upgrade
# path and actually processes sections.
_write_reconciler_fixture() {
  local tmpdir="$1"; shift
  local omit=" $* "
  mkdir -p "$tmpdir/config"

  {
    printf '%s\n' "$BASE_REQUIRED"
    printf 'project_name: "test"\n'
    printf 'config_phase: full\n'
    printf 'schema_version: "1.0.0"\n'

    local section
    # Derive the section list from the canonical allowlist so this fixture
    # cannot drift when a new section is added to config-hydration.sh.
    # ci_platform and platforms are in the allowlist but have explicit typed
    # values below, so skip them here to avoid duplicate YAML keys.
    local sections
    sections="$(_get_hydration_array _CONFIG_HYDRATION_ALLOWLIST)"
    for section in $sections; do
      case "$omit" in
        *" $section "*) ;;  # deliberately omitted
        *) case "$section" in
             ci_platform|platforms) ;;  # written below with typed values
             *) printf '%s: {}\n' "$section" ;;
           esac ;;
      esac
    done

    printf 'ci_platform: "github-actions"\n'
    printf 'platforms: []\n'
    printf 'user_name: "test"\n'
    printf 'communication_language: "en"\n'
    printf 'project_kind: "framework"\n'
    printf 'planning_artifacts: "docs/planning-artifacts"\n'
    printf 'implementation_artifacts: "docs/implementation-artifacts"\n'
    printf 'test_artifacts: "docs/test-artifacts"\n'
    printf 'creative_artifacts: "docs/creative-artifacts"\n'
  } > "$tmpdir/config/project-config.yaml"
}

# _get_hydration_array <array-name> — echo the entries of a config-hydration
# bash array, one per line.
_get_hydration_array() {
  bash -c "source '$HYDRATION' 2>/dev/null; printf '%s\n' \"\${$1[@]}\""
}

# ---------------------------------------------------------------------------
# Scenario 1: valid sprint_status_mod section passes schema validation
# ---------------------------------------------------------------------------

@test "valid sprint_status_mod section passes schema validation" {
  _assert_schema_declares

  local cfg
  cfg="$(_write_config 'sprint_status_mod:
  user_aliases:
    - alice
    - bob')"
  _assert_validator_passes "$cfg"
}

# ---------------------------------------------------------------------------
# Scenario 2: unknown property under sprint_status_mod rejected
# ---------------------------------------------------------------------------

@test "unknown key inside sprint_status_mod is rejected" {
  _assert_validator_rejects "$(_write_config 'sprint_status_mod:
  user_aliases: []
  unknown_key: true')" "sprint_status_mod"
}

@test "deprecated waiting_agent_threshold_seconds is tolerated by schema" {
  local cfg
  cfg="$(_write_config 'sprint_status_mod:
  user_aliases:
    - alice
  waiting_agent_threshold_seconds: 300')"
  _assert_validator_passes "$cfg"
}

# ---------------------------------------------------------------------------
# Scenario 3a: bare key (YAML null) accepted
# ---------------------------------------------------------------------------

@test "bare sprint_status_mod key (YAML null) is accepted" {
  _assert_schema_declares

  local cfg
  cfg="$(_write_config 'sprint_status_mod:')"
  _assert_validator_passes "$cfg"
}

# ---------------------------------------------------------------------------
# Scenario 3b: empty object accepted
# ---------------------------------------------------------------------------

@test "empty sprint_status_mod object is accepted" {
  _assert_schema_declares

  local cfg
  cfg="$(_write_config 'sprint_status_mod: {}')"
  _assert_validator_passes "$cfg"
}

# ---------------------------------------------------------------------------
# Scenario 3c: empty user_aliases array accepted (disables alias matching)
# ---------------------------------------------------------------------------

@test "empty user_aliases array is accepted" {
  _assert_schema_declares

  local cfg
  cfg="$(_write_config 'sprint_status_mod:
  user_aliases: []')"
  _assert_validator_passes "$cfg"
}

# ---------------------------------------------------------------------------
# Scenario 3: empty string in user_aliases rejected
# ---------------------------------------------------------------------------

@test "empty string in user_aliases is rejected" {
  _assert_validator_rejects "$(_write_config 'sprint_status_mod:
  user_aliases:
    - ""')" "user_aliases"
}

# ---------------------------------------------------------------------------
# Scenario 4: absent section is valid and reconciler writes no stub
# ---------------------------------------------------------------------------

@test "absent sprint_status_mod section validates" {
  local cfg
  cfg="$(_write_config 'project_name: demo')"
  _assert_validator_passes "$cfg"
}

@test "reconciler does not write a sprint_status_mod stub" {
  _assert_schema_declares

  local tmpdir="$TEST_TMP/reconciler-no-stub"
  # Omit `release` as a positive control: the reconciler must hydrate it,
  # proving it processed the file and reached the section loop.
  _write_reconciler_fixture "$tmpdir" release

  cd "$tmpdir"
  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$RECONCILER" apply --project-root . --yes
  printf 'reconciler output:\n%s\n' "$output" >&2

  [ "$status" -eq 0 ]

  # Positive control: the reconciler hydrated the missing section.
  grep -q '^release:' "$tmpdir/config/project-config.yaml"

  # The managed-elsewhere section must not have been stubbed.
  run grep -c 'sprint_status_mod' "$tmpdir/config/project-config.yaml"
  [ "$output" = "0" ]
}

@test "reconciler preserves existing sprint_status_mod empty object" {
  _assert_schema_declares

  local tmpdir="$TEST_TMP/reconciler-preserve"
  _write_reconciler_fixture "$tmpdir"

  # Append the section the reconciler should leave alone.
  printf 'sprint_status_mod: {}\n' >> "$tmpdir/config/project-config.yaml"

  local pre_line
  pre_line="$(grep 'sprint_status_mod' "$tmpdir/config/project-config.yaml")"

  cd "$tmpdir"
  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$RECONCILER" apply --project-root . --yes
  printf 'reconciler output:\n%s\n' "$output" >&2
  [ "$status" -eq 0 ]

  local post_line
  post_line="$(grep 'sprint_status_mod' "$tmpdir/config/project-config.yaml")"
  [ "$pre_line" = "$post_line" ]
}

@test "reconciler preserves bare sprint_status_mod key (null) without injecting a stub" {
  _assert_schema_declares

  local tmpdir="$TEST_TMP/reconciler-bare-key"
  _write_reconciler_fixture "$tmpdir"

  # Append a bare key (YAML null) — the reconciler must leave it alone.
  printf 'sprint_status_mod:\n' >> "$tmpdir/config/project-config.yaml"

  cd "$tmpdir"
  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$RECONCILER" apply --project-root . --yes
  printf 'reconciler output:\n%s\n' "$output" >&2
  [ "$status" -eq 0 ]

  # The bare key must still be present and unchanged.
  grep -Fxq 'sprint_status_mod:' "$tmpdir/config/project-config.yaml"

  # No stub object must have been injected.
  run grep -c 'sprint_status_mod' "$tmpdir/config/project-config.yaml"
  [ "$output" = "1" ]
}

# ---------------------------------------------------------------------------
# Scenario 5: config-show extract displays section byte-verbatim
# ---------------------------------------------------------------------------

@test "config-yaml-editor extract returns sprint_status_mod byte-verbatim" {
  local cfg="$TEST_TMP/verbatim.yaml"
  cat > "$cfg" <<'YAML'
project_root: /tmp/test-project
project_path: /tmp/test-project/src
memory_path: /tmp/test-project/.gaia/memory
checkpoint_path: /tmp/test-project/.gaia/checkpoints
installed_path: /tmp/test-project/.gaia/installed
framework_version: "1.220.2"
date: "2026-10-12"
sprint_status_mod:
  # project alias overrides
  user_aliases:
    - "Alice B"
    - bob
YAML

  # extract emits the header line followed by the body, preserving comments,
  # quoting, and indentation byte-for-byte.
  local expected
  expected="$(cat <<'EOF'
sprint_status_mod:
  # project alias overrides
  user_aliases:
    - "Alice B"
    - bob
EOF
)"

  run "$EDITOR" extract "$cfg" sprint_status_mod
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

# ---------------------------------------------------------------------------
# Scenario 8: hydration invariant and reconciler skip hold
#
# Three SEPARATE per-line assertions so a single-bucket failure is visible
# in the test output rather than hidden inside a combined check.
# ---------------------------------------------------------------------------

@test "sprint_status_mod is registered in managed-elsewhere" {
  _get_hydration_array _CONFIG_HYDRATION_MANAGED_ELSEWHERE | grep -Fxq "sprint_status_mod"
}

@test "sprint_status_mod is NOT in the auto-hydration allowlist" {
  local entries
  entries="$(_get_hydration_array _CONFIG_HYDRATION_ALLOWLIST)"
  # Guard against vacuously passing on an empty list (e.g. if source errors
  # are swallowed). A known stable member must be present.
  grep -Fxq "release" <<<"$entries"
  run grep -Fxc "sprint_status_mod" <<<"$entries"
  [ "$output" = "0" ]
}

@test "sprint_status_mod carries x-no-auto-hydration in the schema" {
  local val
  val="$(jq -r '.properties.sprint_status_mod["x-no-auto-hydration"] // "absent"' "$SCHEMA")"
  [ "$val" = "true" ]
}

# ---------------------------------------------------------------------------
# Type-constraint rejection tests — guards against aliases accepting
# non-array or non-string types, and the section accepting bare scalars.
# ---------------------------------------------------------------------------

@test "scalar string user_aliases is rejected (must be array)" {
  _assert_validator_rejects "$(_write_config 'sprint_status_mod:
  user_aliases: "alice"')" "user_aliases"
}

@test "non-string items in user_aliases are rejected" {
  _assert_validator_rejects "$(_write_config 'sprint_status_mod:
  user_aliases:
    - 1')" "user_aliases"
}

@test "plain string for the whole section is rejected" {
  _assert_validator_rejects "$(_write_config 'sprint_status_mod: some-string')" "sprint_status_mod"
}

# ---------------------------------------------------------------------------
# Degraded validator path (no ajv, no python jsonschema): the section's types
# and ranges are still checked.
# ---------------------------------------------------------------------------

# _run_degraded <config-yaml> — run the validator with the python jsonschema
# module masked, so it takes the jq-only path, and require that it did.
_run_degraded() {
  if command -v ajv >/dev/null 2>&1; then
    skip "ajv on PATH takes precedence over the degraded path"
  fi
  local fakelib="$TEST_TMP/nojsonschema"
  mkdir -p "$fakelib"
  printf 'raise ImportError("masked")\n' > "$fakelib/jsonschema.py"
  PYTHONPATH="$fakelib" run "$VALIDATOR" "$1"
  [[ "$output" == *"running DEGRADED structural validation only"* ]]
}

_degraded_passes() {
  _run_degraded "$1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS (DEGRADED)"* ]]
}

_degraded_rejects() {
  _run_degraded "$1"
  [ "$status" -eq 1 ]
  [[ "$output" != *"PASS"* ]]
  [[ "$output" == *"FAIL: \$.sprint_status_mod$2"* ]]
}

@test "degraded path accepts valid sprint_status_mod sections" {
  _degraded_passes "$(_write_config 'sprint_status_mod:
  user_aliases:
    - alice')"
  _degraded_passes "$(_write_config 'sprint_status_mod:')"
  _degraded_passes "$(_write_config 'sprint_status_mod: {}')"
  _degraded_passes "$(_write_config 'sprint_status_mod:
  user_aliases: []')"
}

@test "degraded path tolerates deprecated waiting_agent_threshold_seconds" {
  _degraded_passes "$(_write_config 'sprint_status_mod:
  user_aliases:
    - alice
  waiting_agent_threshold_seconds: 300')"
}

@test "degraded path rejects bad user_aliases values" {
  _degraded_rejects "$(_write_config 'sprint_status_mod:
  user_aliases: "alice"')" ".user_aliases — must be a list"
  _degraded_rejects "$(_write_config 'sprint_status_mod:
  user_aliases:
    - alice
    - ""')" ".user_aliases[1] — must be a non-empty string"
  _degraded_rejects "$(_write_config 'sprint_status_mod:
  user_aliases:
    - 1')" ".user_aliases[0] — must be a non-empty string"
}

@test "degraded path rejects an unknown key and a non-object section" {
  _degraded_rejects "$(_write_config 'sprint_status_mod:
  unknown_key: true')" ".unknown_key — property is not allowed"
  _degraded_rejects "$(_write_config 'sprint_status_mod: some-string')" " — must be an object or null"
}
