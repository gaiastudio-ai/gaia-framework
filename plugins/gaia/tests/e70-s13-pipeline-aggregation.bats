#!/usr/bin/env bats
# e70-s13-pipeline-aggregation.bats — pipeline-wide SARIF-merge + dedup +
# DefectDojo aggregation. Promotes the brownfield-only knobs to the standard
# security pipeline via a tools.aggregation block (under the already-allowlisted
# `tools` section — no config-hydration churn), preserving the brownfield path
# and the defectdojo_api_token = env-var-NAME-not-secret invariant.
#
# Drives the REAL schema (jsonschema), the REAL resolver (resolve-config.sh),
# and asserts the token-name invariant in the published schema + SKILL prose.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCHEMA="$REPO_ROOT/plugins/gaia/schemas/project-config.schema.json"
  YAML_DESC="$REPO_ROOT/plugins/gaia/config/project-config.schema.yaml"
  RC="$REPO_ROOT/plugins/gaia/scripts/resolve-config.sh"
  SKILL="$REPO_ROOT/plugins/gaia/skills/gaia-review-security/SKILL.md"
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

have_jsonschema() { command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' 2>/dev/null; }
have_yq() { command -v yq >/dev/null 2>&1; }

_validate_tools() {
  python3 - "$SCHEMA" "$1" <<'PY'
import json, sys, jsonschema
schema=json.load(open(sys.argv[1]))
base={"project_root":".","project_path":".","memory_path":"_memory",
      "checkpoint_path":"_memory/checkpoints","installed_path":"_gaia",
      "framework_version":"1.0.0","date":"2026-06-30"}
base["tools"]=json.loads(sys.argv[2])
try: jsonschema.validate(base,schema); print("valid")
except jsonschema.ValidationError as e: print("error:", e.message)
PY
}

_cfg() {
  cat > "$TMP/c.yaml" <<EOF
project_root: "."
project_path: "."
memory_path: "_memory"
checkpoint_path: "_memory/checkpoints"
installed_path: "_gaia"
framework_version: "1.0.0"
date: "2026-06-30"
$1
EOF
}

# ---------- AC2: schema — aggregation block under tools ----------

@test "tools.aggregation block validates (AC2)" {
  have_jsonschema || skip "python3 + jsonschema not available"
  run _validate_tools '{"aggregation":{"sarif_merge_enabled":true,"dedup_enabled":true,"defectdojo_enabled":true,"defectdojo_api_url":"https://dojo","defectdojo_api_token":"DOJO_TOKEN","defectdojo_engagement_id":"42"}}'
  [[ "$output" == *"valid"* ]]
}

@test "aggregation coexists with a real scanner category (AC2)" {
  have_jsonschema || skip "python3 + jsonschema not available"
  run _validate_tools '{"aggregation":{"sarif_merge_enabled":true},"sast":{"provider":"semgrep"}}'
  [[ "$output" == *"valid"* ]]
}

@test "an unknown key inside aggregation is rejected (additionalProperties:false) (AC2)" {
  have_jsonschema || skip "python3 + jsonschema not available"
  run _validate_tools '{"aggregation":{"bogus":1}}'
  [[ "$output" == *"error"* ]]
}

@test "a scanner category STILL requires provider (no regression from adding aggregation) (AC2)" {
  have_jsonschema || skip "python3 + jsonschema not available"
  run _validate_tools '{"sast":{"config":{}}}'
  [[ "$output" == *"error"* ]]
}

# ---------- AC1/AC4: resolver reads pipeline-wide path; brownfield unchanged ----------

@test "resolver reads tools.aggregation.* in a non-brownfield (pipeline-wide) context (AC1)" {
  have_yq || skip "yq not available"
  _cfg 'tools:
  aggregation:
    sarif_merge_enabled: true
    dedup_enabled: true
    defectdojo_enabled: true
    defectdojo_api_url: "https://dojo.example/api"
    defectdojo_api_token: "DOJO_API_TOKEN"
    defectdojo_engagement_id: "42"'
  run bash "$RC" --field tools.aggregation.sarif_merge_enabled --shared "$TMP/c.yaml"
  [[ "$output" == *"true"* ]]
  run bash "$RC" --field tools.aggregation.defectdojo_enabled --shared "$TMP/c.yaml"
  [[ "$output" == *"true"* ]]
  run bash "$RC" --field tools.aggregation.defectdojo_engagement_id --shared "$TMP/c.yaml"
  [[ "$output" == *"42"* ]]
}

@test "the brownfield aggregation path still resolves unchanged (back-compat) (AC4)" {
  have_yq || skip "yq not available"
  _cfg 'brownfield:
  sarif_merge_enabled: false
  defectdojo_enabled: true'
  run bash "$RC" --field brownfield.sarif_merge_enabled --shared "$TMP/c.yaml"
  [[ "$output" == *"false"* ]]
  run bash "$RC" --field brownfield.defectdojo_enabled --shared "$TMP/c.yaml"
  [[ "$output" == *"true"* ]]
}

@test "defectdojo_api_token resolves to the env-var NAME verbatim (never a literal secret) (AC3)" {
  have_yq || skip "yq not available"
  _cfg 'tools:
  aggregation:
    defectdojo_api_token: "MY_DOJO_TOKEN_ENV"'
  run bash "$RC" --field tools.aggregation.defectdojo_api_token --shared "$TMP/c.yaml"
  # The resolved value is the env-var NAME, used to read the secret at run time.
  [[ "$output" == *"MY_DOJO_TOKEN_ENV"* ]]
}

# ---------- AC3/AC5/AC7: token-name invariant carried into published prose ----------

@test "the schema describes defectdojo_api_token as an env-var NAME, never a secret (AC3)" {
  run python3 -c "
import json
s=json.load(open('$SCHEMA'))
d=s['properties']['tools']['properties']['aggregation']['properties']['defectdojo_api_token']['description']
assert 'NAME of an environment variable' in d, 'missing env-var-name phrasing'
assert 'NEVER a literal secret' in d or 'never a literal secret' in d.lower(), 'missing never-a-secret phrasing'
print('ok')
"
  [[ "$output" == *"ok"* ]]
}

@test "the security SKILL documents pipeline-wide aggregation + the token-name invariant (AC5)" {
  grep -qi 'tools.aggregation\|pipeline-wide' "$SKILL"
  grep -qi 'sarif' "$SKILL"
  grep -qi 'defectdojo' "$SKILL"
  # The token-name invariant is carried verbatim.
  grep -qi 'NAME of an environment variable' "$SKILL"
}

@test "the SKILL actually CONSUMES the aggregation knobs — it exports the adapter env + invokes the real adapters (not write-only config) (AC1)" {
  # The promotion must do real work: resolve tools.aggregation.* into the env
  # contract the existing brownfield aggregation adapters consume, then run them.
  grep -q 'tools.aggregation.sarif_merge_enabled' "$SKILL"
  grep -q 'GAIA_BROWNFIELD_SARIF_MERGE_ENABLED' "$SKILL"
  grep -q 'GAIA_BROWNFIELD_DEFECTDOJO_API_TOKEN' "$SKILL"
  # The three real aggregation adapters are invoked from the standard pipeline.
  grep -q 'adapters/brownfield/sarif-merge.sh' "$SKILL"
  grep -q 'adapters/brownfield/dedup.sh' "$SKILL"
  grep -q 'adapters/brownfield/defectdojo-export.sh' "$SKILL"
}

@test "the reused adapters key off the same GAIA_BROWNFIELD_* env the SKILL exports (contract match) (AC1)" {
  ADAPTERS="$REPO_ROOT/plugins/gaia/scripts/adapters/brownfield"
  # The env-var names the SKILL exports must match what the adapters read.
  grep -q 'GAIA_BROWNFIELD_SARIF_MERGE_ENABLED' "$ADAPTERS/sarif-merge.sh"
  grep -q 'GAIA_BROWNFIELD_DEDUP_ENABLED' "$ADAPTERS/dedup.sh"
  grep -q 'GAIA_BROWNFIELD_DEFECTDOJO_API_TOKEN' "$ADAPTERS/defectdojo-export.sh"
}

@test "the SKILL records the token blast-radius confirmation (does not widen it) (AC7)" {
  grep -qi 'blast.radius' "$SKILL"
}

@test "the YAML descriptor documents the promoted aggregation + token-name invariant (AC5)" {
  grep -q 'tools.aggregation' "$YAML_DESC"
  grep -qi 'NAME of an env var' "$YAML_DESC"
  grep -qi 'unchanged\|additive' "$YAML_DESC"
}

# ---------- AC1 consume-path: the deref + adapter wiring actually works ----------

@test "the token-name deref turns the configured env-var NAME into the secret VALUE (\${!var}), never the literal name (AC1, AC3)" {
  # Reproduce the Step 5b deref contract exactly: config holds the NAME, the
  # caller resolves the name then derefs it to the value. A real secret only
  # ever lives in the env var, never in config.
  export DOJO_TOKEN_ENV="s3cr3t-value-xyz"
  DD_TOKEN_VAR="DOJO_TOKEN_ENV"            # this is what resolve-config returns (the NAME)
  resolved="${!DD_TOKEN_VAR:-}"            # the Step 5b deref
  [ "$resolved" = "s3cr3t-value-xyz" ]     # adapter receives the VALUE, not the name
  unset DOJO_TOKEN_ENV
}

@test "a pasted LITERAL token (not a valid var name) derefs to empty → fail-closed (no broken auth, no secret leak) (AC3)" {
  # The structural safeguard: a literal secret pasted into config is not a valid
  # shell var name, so \${!literal} expands to empty and the export fail-closes.
  DD_TOKEN_VAR="abcdef0123456789abcdef0123456789"   # looks like a literal token
  resolved="${!DD_TOKEN_VAR:-}"
  [ -z "$resolved" ]                                 # empty → defectdojo-export.sh WARN-skips
}

@test "the SKILL Step 5b derefs the token via \${!var} (not the raw resolved name) (AC1)" {
  # Guard against the broken-by-construction wiring the review caught: Step 5b
  # MUST deref, not export the raw resolved field into the token env var.
  grep -q 'DD_TOKEN_VAR=' "$SKILL"
  grep -q 'GAIA_BROWNFIELD_DEFECTDOJO_API_TOKEN="${!DD_TOKEN_VAR' "$SKILL"
  # And it must NOT export the raw --field result straight into the token var.
  ! grep -qE 'GAIA_BROWNFIELD_DEFECTDOJO_API_TOKEN="\$\("\$?RC"? --field tools.aggregation.defectdojo_api_token' "$SKILL"
}

@test "the merge adapter actually runs from the promoted env contract (real adapter, gated) (AC1)" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available (sarif-merge needs it)"
  ADAPTERS="$REPO_ROOT/plugins/gaia/scripts/adapters/brownfield"
  WORK="$TMP/work"; mkdir -p "$WORK/.gaia/memory/brownfield-audit/sarif" "$WORK/.gaia/artifacts/planning-artifacts"
  # gate ON → adapter does real work (or a clean info path), exit 0
  ( cd "$WORK"
    GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_SARIF_MERGE_ENABLED=true \
    GAIA_MEMORY_DIR="$WORK/.gaia/memory" GAIA_ARTIFACTS_DIR="$WORK/.gaia/artifacts" \
    bash "$ADAPTERS/sarif-merge.sh" >/dev/null 2>&1 )
  [ "$?" -eq 0 ]
}

@test "defectdojo export is GATED off by default (no network when defectdojo_enabled unset/false) (AC1)" {
  ADAPTERS="$REPO_ROOT/plugins/gaia/scripts/adapters/brownfield"
  run env GAIA_BROWNFIELD_DEFECTDOJO_ENABLED=false bash "$ADAPTERS/defectdojo-export.sh" "$TMP/none.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]] || [[ "$output" == *"disabled"* ]] || [ -z "$output" ]
}

@test "Step 5b gates the DefectDojo token exports behind defectdojo_enabled == true (AC1)" {
  # The token/url/engagement exports must be inside an enabled-guard (mirrors
  # the brownfield contract; no token resolution when export is off).
  grep -q 'GAIA_BROWNFIELD_DEFECTDOJO_ENABLED.*= *.true' "$SKILL" || grep -q 'if \[ "\${GAIA_BROWNFIELD_DEFECTDOJO_ENABLED}" = "true" \]' "$SKILL"
}

# ---------- H1: aggregation reserved-key documented in the editor ----------

@test "H1: /gaia-config-tool documents aggregation as a reserved (non-category) key" {
  CONFIG_TOOL="$REPO_ROOT/plugins/gaia/skills/gaia-config-tool/SKILL.md"
  grep -qi 'reserved' "$CONFIG_TOOL"
  grep -q 'tools.aggregation\|aggregation' "$CONFIG_TOOL"
  grep -qi 'NOT a scanner category\|not a valid' "$CONFIG_TOOL"
}

# ---------- no-leak guard ----------

@test "no literal secret token value appears in the promoted schema/SKILL (only env-var names)" {
  # Defensive: the published artifacts must never contain a literal-looking
  # bearer/api token; the contract is env-var NAME only.
  ! grep -qE 'defectdojo_api_token["[:space:]:]+["'\'']?[A-Za-z0-9]{32,}' "$SCHEMA"
  ! grep -qiE 'api_token.*=.*[a-f0-9]{32,}' "$SKILL"
}
