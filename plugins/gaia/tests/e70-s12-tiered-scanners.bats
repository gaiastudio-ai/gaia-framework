#!/usr/bin/env bats
# e70-s12-tiered-scanners.bats — tiered / multi-provider scanners for
# tools.<category>: a blocking PR-gate provider + optional non-blocking
# scheduled deep-scan scanners, mirroring the test-tier placement model.
#
# Drives the REAL schema (jsonschema), the REAL scanner-placement.sh helper, and
# asserts the brownfield scanner_tier reconciliation prose. Back-compat (bare
# provider) is the load-bearing invariant.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCHEMA="$REPO_ROOT/plugins/gaia/schemas/project-config.schema.json"
  YAML_DESC="$REPO_ROOT/plugins/gaia/config/project-config.schema.yaml"
  SP="$REPO_ROOT/plugins/gaia/scripts/scanner-placement.sh"
  SKILL="$REPO_ROOT/plugins/gaia/skills/gaia-config-tool/SKILL.md"
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

have_jsonschema() { command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' 2>/dev/null; }
have_yq() { command -v yq >/dev/null 2>&1; }

# validate a tools:{} fragment against the schema; prints "valid" or "error"
_validate_tools() {
  local tools_json="$1"
  python3 - "$SCHEMA" "$tools_json" <<'PY'
import json, sys, jsonschema
schema = json.load(open(sys.argv[1]))
base = {"project_root":".","project_path":".","memory_path":"_memory",
        "checkpoint_path":"_memory/checkpoints","installed_path":"_gaia",
        "framework_version":"1.0.0","date":"2026-06-30"}
base["tools"] = json.loads(sys.argv[2])
try:
    jsonschema.validate(base, schema); print("valid")
except jsonschema.ValidationError as e:
    print("error:", e.message)
PY
}

# ---------- AC1/AC2: schema — additive tiered shape + back-compat ----------

@test "a bare provider validates (single-gate back-compat, unchanged) (AC2)" {
  have_jsonschema || skip "python3 + jsonschema not available"
  run _validate_tools '{"sast":{"provider":"semgrep"}}'
  [[ "$output" == *"valid"* ]]
}

@test "provider + scheduled[string] validates (tiered) (AC1)" {
  have_jsonschema || skip "python3 + jsonschema not available"
  run _validate_tools '{"sast":{"provider":"semgrep","scheduled":["sonarqube"]}}'
  [[ "$output" == *"valid"* ]]
}

@test "provider + placement + scheduled[object] validates (tiered, object form) (AC1)" {
  have_jsonschema || skip "python3 + jsonschema not available"
  run _validate_tools '{"sast":{"provider":"semgrep","placement":"ci-pre-merge","scheduled":[{"provider":"codeql","placement":"ci-post-merge"}]}}'
  [[ "$output" == *"valid"* ]]
}

@test "an unknown sibling key is still rejected (additionalProperties stays tight) (AC2)" {
  have_jsonschema || skip "python3 + jsonschema not available"
  run _validate_tools '{"sast":{"provider":"semgrep","bogus":1}}'
  [[ "$output" == *"error"* ]]
}

@test "a bad placement enum value is rejected (AC1)" {
  have_jsonschema || skip "python3 + jsonschema not available"
  run _validate_tools '{"sast":{"provider":"semgrep","placement":"whenever"}}'
  [[ "$output" == *"error"* ]]
}

@test "a scheduled object entry without provider is rejected (AC1)" {
  have_jsonschema || skip "python3 + jsonschema not available"
  run _validate_tools '{"sast":{"provider":"semgrep","scheduled":[{"config":{}}]}}'
  [[ "$output" == *"error"* ]]
}

# ---------- AC5: routing — gate vs scheduled placement ----------

@test "bare provider resolves to a single gate at ci-pre-merge (AC2, AC5)" {
  have_yq || skip "yq not available"
  printf 'tools:\n  sast:\n    provider: semgrep\n' > "$TMP/c.yaml"
  run bash "$SP" --config "$TMP/c.yaml" --category sast
  [ "$status" -eq 0 ]
  [[ "$output" == *"gate"*"semgrep"*"ci-pre-merge"* ]]
  # No scheduled rows for a bare provider.
  [[ "$output" != *"scheduled"* ]]
}

@test "tiered config routes the gate to pre-merge and scheduled to post-merge (AC5)" {
  have_yq || skip "yq not available"
  cat > "$TMP/c.yaml" <<'EOF'
tools:
  sast:
    provider: semgrep
    scheduled:
      - sonarqube
      - { provider: codeql, placement: ci-post-merge }
EOF
  run bash "$SP" --config "$TMP/c.yaml" --category sast
  [ "$status" -eq 0 ]
  [[ "$output" == *$'gate\tsemgrep\tci-pre-merge'* ]]
  [[ "$output" == *$'scheduled\tsonarqube\tci-post-merge'* ]]
  [[ "$output" == *$'scheduled\tcodeql\tci-post-merge'* ]]
}

@test "an explicit scheduled placement overrides the post-merge default (AC5)" {
  have_yq || skip "yq not available"
  cat > "$TMP/c.yaml" <<'EOF'
tools:
  dast:
    provider: zap-baseline
    scheduled:
      - { provider: zap-full, placement: post-deploy }
EOF
  run bash "$SP" --config "$TMP/c.yaml" --category dast
  [ "$status" -eq 0 ]
  [[ "$output" == *$'scheduled\tzap-full\tpost-deploy'* ]]
}

@test "an unconfigured category exits 2 (benign, nothing to place) (AC5)" {
  have_yq || skip "yq not available"
  printf 'tools:\n  sast:\n    provider: semgrep\n' > "$TMP/c.yaml"
  run bash "$SP" --config "$TMP/c.yaml" --category sca
  [ "$status" -eq 2 ]
}

@test "json format emits gate + scheduled objects (AC5)" {
  have_yq || skip "yq not available"
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  cat > "$TMP/c.yaml" <<'EOF'
tools:
  sca:
    provider: grype
    scheduled: [owasp-dependency-check]
EOF
  run bash "$SP" --config "$TMP/c.yaml" --category sca --format json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.gate.provider')" = "grype" ]
  [ "$(printf '%s' "$output" | jq -r '.gate.placement')" = "ci-pre-merge" ]
  [ "$(printf '%s' "$output" | jq -r '.scheduled[0].provider')" = "owasp-dependency-check" ]
  [ "$(printf '%s' "$output" | jq -r '.scheduled[0].placement')" = "ci-post-merge" ]
}

# ---------- robustness: parser must not desync or fail-open (adversarial) ----------

@test "a whitespace-containing scheduled provider stays ONE field and is not dropped (no desync)" {
  have_yq || skip "yq not available"
  cat > "$TMP/c.yaml" <<'EOF'
tools:
  sast:
    provider: semgrep
    scheduled:
      - { provider: "two words", placement: ci-post-merge }
      - { provider: codeql, placement: ci-post-merge }
      - { provider: snyk, placement: ci-post-merge }
EOF
  run bash "$SP" --config "$TMP/c.yaml" --category sast
  [ "$status" -eq 0 ]
  # All THREE scheduled scanners must survive — none silently dropped.
  [ "$(printf '%s\n' "$output" | grep -c '^scheduled')" -eq 3 ]
  # The multi-word provider is one field with its correct placement.
  [[ "$output" == *$'scheduled\ttwo words\tci-post-merge'* ]]
  [[ "$output" == *$'scheduled\tsnyk\tci-post-merge'* ]]
}

@test "json form keeps a whitespace provider as a single value with all entries present" {
  have_yq || skip "yq not available"
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  cat > "$TMP/c.yaml" <<'EOF'
tools:
  sast:
    provider: semgrep
    scheduled:
      - { provider: "two words" }
      - codeql
      - snyk
EOF
  run bash "$SP" --config "$TMP/c.yaml" --category sast --format json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '.scheduled | length')" -eq 3 ]
  [ "$(printf '%s' "$output" | jq -r '.scheduled[0].provider')" = "two words" ]
}

@test "a malformed YAML config HARD-FAILS (exit 1), not a benign 'not configured' exit 2 (no fail-open)" {
  have_yq || skip "yq not available"
  printf 'tools:\n  sast:\n  provider: : broken: [\n' > "$TMP/bad.yaml"
  run bash "$SP" --config "$TMP/bad.yaml" --category sast
  [ "$status" -eq 1 ]
  [[ "$output" == *"not valid YAML"* ]] || [[ "$output" == *"parse error"* ]]
}

@test "a genuinely-absent category on a WELL-FORMED file is still benign exit 2" {
  have_yq || skip "yq not available"
  printf 'tools:\n  sast:\n    provider: semgrep\n' > "$TMP/ok.yaml"
  run bash "$SP" --config "$TMP/ok.yaml" --category dast
  [ "$status" -eq 2 ]
}

# ---------- AC4: reconciliation with brownfield scanner_tier ----------

@test "the schema documents that tools placement is orthogonal to brownfield scanner_tier (AC4)" {
  # The JSON schema tools.description must call out the orthogonality so the two
  # tier vocabularies are not conflated.
  run python3 -c "
import json
s=json.load(open('$SCHEMA'))
d=s['properties']['tools']['description']
assert 'scanner_tier' in d, 'tools description does not mention scanner_tier'
assert 'orthogonal' in d.lower() or 'do not conflict' in d.lower() or 'independent' in d.lower(), 'no orthogonality statement'
print('ok')
"
  [[ "$output" == *"ok"* ]]
}

@test "the YAML descriptor + the helper both document the scanner_tier reconciliation (AC4)" {
  grep -q 'scanner_tier' "$YAML_DESC"
  grep -qi 'orthogonal\|do not conflict\|independent' "$YAML_DESC"
  # The helper explicitly states it does not read scanner_tier.
  grep -q 'scanner_tier' "$SP"
}

@test "the config-tool SKILL documents the tiered model + back-compat + reconciliation (AC6)" {
  grep -qi 'scheduled' "$SKILL"
  grep -qi 'blocking' "$SKILL"
  grep -qi 'back-compat\|unchanged single' "$SKILL"
  grep -q 'scanner_tier' "$SKILL"
}

@test "the helper is referenced from the SKILL prose (discoverable) (AC6)" {
  grep -q 'scanner-placement.sh' "$SKILL"
}
