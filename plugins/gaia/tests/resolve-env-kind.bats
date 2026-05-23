#!/usr/bin/env bats
# resolve-env-kind.bats — E99-S1 (FR-520, ADR-112 §(a), NFR-080,
# TC-EKD-1/2/3/4/6 + TC-NFR-080-1/2)
#
# Bats coverage for the runtime-callable parts of E99-S1:
#   - env-kind resolver with read-time default `deployable` (NFR-080)
#   - closed-enum rejection of unknown values
#   - default propagation to downstream consumers
#
# The four downstream skill gates (/gaia-deploy HALT, /gaia-post-deploy HALT,
# /gaia-deploy-checklist shape-agnostic, /gaia-config-validate WARN) are
# documentation-orchestrated via SKILL.md prose since the production skills
# are LLM-driven, not script-callable. The resolver IS the script-callable
# single source of truth that each SKILL.md cites.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"
  RESOLVER="$PLUGIN_DIR/scripts/lib/resolve-env-kind.sh"
  SCHEMA="$PLUGIN_DIR/schemas/project-config.schema.json"
  CONFIG="$TEST_TMP/project-config.yaml"
}

teardown() { common_teardown; }

# ---------- TC-EKD-1: legacy fixture, missing kind → resolves to deployable ----------

@test "TC-EKD-1: missing kind: resolves to 'deployable' (NFR-080 silent default)" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: staging
    name: Staging
    branch: staging
  - id: production
    name: Production
    branch: main
YAML
  run bash -c "source '$RESOLVER' && gaia_resolve_env_kind '$CONFIG' staging"
  [ "$status" -eq 0 ]
  [ "$output" = "deployable" ]
  run bash -c "source '$RESOLVER' && gaia_resolve_env_kind '$CONFIG' production"
  [ "$status" -eq 0 ]
  [ "$output" = "deployable" ]
}

@test "TC-EKD-1: NO stderr WARNING on missing kind at read time" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: staging
    branch: staging
YAML
  run bash -c "source '$RESOLVER' && gaia_resolve_env_kind '$CONFIG' staging 2>&1 >/dev/null"
  [ -z "$output" ]
}

# ---------- AC1: all three legal kinds resolve to themselves ----------

@test "AC1: kind: deployable resolves verbatim" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: staging
    kind: deployable
YAML
  run bash -c "source '$RESOLVER' && gaia_resolve_env_kind '$CONFIG' staging"
  [ "$status" -eq 0 ]
  [ "$output" = "deployable" ]
}

@test "AC1: kind: branch-only resolves verbatim" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: marketplace
    kind: branch-only
YAML
  run bash -c "source '$RESOLVER' && gaia_resolve_env_kind '$CONFIG' marketplace"
  [ "$status" -eq 0 ]
  [ "$output" = "branch-only" ]
}

@test "AC1: kind: distribution-only resolves verbatim" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: cdn
    kind: distribution-only
YAML
  run bash -c "source '$RESOLVER' && gaia_resolve_env_kind '$CONFIG' cdn"
  [ "$status" -eq 0 ]
  [ "$output" = "distribution-only" ]
}

# ---------- AC6 / TC-EKD-6: closed-enum rejects unknown values ----------

@test "TC-EKD-6: unknown kind value 'hybrid' is rejected with non-zero exit" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: staging
    kind: hybrid
YAML
  run bash -c "source '$RESOLVER' && gaia_resolve_env_kind '$CONFIG' staging"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE 'ADR-112|closed enum|invalid kind'
  echo "$output" | grep -q 'hybrid'
  # All three legal values should be listed in the error message
  echo "$output" | grep -q 'deployable'
  echo "$output" | grep -q 'branch-only'
  echo "$output" | grep -q 'distribution-only'
}

@test "TC-EKD-6: unknown value is NEVER silently coerced to deployable" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: staging
    kind: production
YAML
  run bash -c "source '$RESOLVER' && gaia_resolve_env_kind '$CONFIG' staging"
  [ "$status" -ne 0 ]
  # Must NOT print "deployable" as a fallback — must HALT
  ! echo "$output" | grep -qE '^deployable$'
}

# ---------- AC8 / TC-NFR-080-2: default propagation across consumers ----------

@test "TC-NFR-080-2: every entry in a no-kind fixture resolves to deployable" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: staging
    branch: staging
  - id: production
    branch: main
  - id: preview
    branch: preview
YAML
  local probes=0 deployable_count=0
  for env in staging production preview; do
    probes=$((probes + 1))
    out=$(bash -c "source '$RESOLVER' && gaia_resolve_env_kind '$CONFIG' '$env'")
    [ "$out" = "deployable" ] && deployable_count=$((deployable_count + 1))
  done
  [ "$probes" = "3" ]
  [ "$deployable_count" = "3" ]
}

# ---------- Mixed kinds in same config ----------

@test "mixed-kinds: each env resolves independently per-id" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: staging
    kind: deployable
  - id: marketplace
    kind: branch-only
  - id: cdn
    kind: distribution-only
  - id: legacy
    branch: legacy
YAML
  run bash -c "source '$RESOLVER' && gaia_resolve_env_kind '$CONFIG' staging"
  [ "$output" = "deployable" ]
  run bash -c "source '$RESOLVER' && gaia_resolve_env_kind '$CONFIG' marketplace"
  [ "$output" = "branch-only" ]
  run bash -c "source '$RESOLVER' && gaia_resolve_env_kind '$CONFIG' cdn"
  [ "$output" = "distribution-only" ]
  run bash -c "source '$RESOLVER' && gaia_resolve_env_kind '$CONFIG' legacy"
  [ "$output" = "deployable" ]
}

# ---------- AC1: JSON schema declares the closed 3-value enum ----------

@test "AC1: schema declares environments[].kind as closed enum of exactly 3 values" {
  # The schema uses oneOf to admit both the legacy map-of-entries shape and
  # the FR-520 array-of-entries shape. The enum lives on the array branch.
  local values
  values=$(jq -r '
    .properties.environments.oneOf[]?
    | select(.type == "array")
    | .items.properties.kind.enum // []
    | .[] // ""
  ' "$SCHEMA" 2>/dev/null | sort | tr -d ' \r')
  [ "$values" = "branch-only
deployable
distribution-only" ]
}

# ---------- Usage errors ----------

@test "usage: missing config arg fails with non-zero exit" {
  run bash -c "source '$RESOLVER' && gaia_resolve_env_kind"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE 'usage|config'
}

@test "usage: missing env-id arg fails with non-zero exit" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: staging
YAML
  run bash -c "source '$RESOLVER' && gaia_resolve_env_kind '$CONFIG'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE 'usage|env|id'
}

@test "missing env-id in config: clear error" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: staging
YAML
  run bash -c "source '$RESOLVER' && gaia_resolve_env_kind '$CONFIG' nonexistent"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE 'not found|nonexistent'
}

# ---------- Source guard ----------

@test "source-guard: double-source is idempotent" {
  run bash -c "source '$RESOLVER' && source '$RESOLVER' && declare -F gaia_resolve_env_kind >/dev/null && echo OK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}
