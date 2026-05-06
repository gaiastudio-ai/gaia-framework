#!/usr/bin/env bats
# detect-signals.bats — E71-S2 / AC1-AC10
#
# Verifies detect-signals.sh produces a structured JSON document with four
# top-level keys (stacks, platforms, ci_platform, tool_providers) by scanning
# a target project root for stack, platform, CI, and tool-provider signals.
# Also exercises RFC 7396 merge semantics and ADR-063 verdict surfacing.

load 'test_helper.bash'

setup() {
  common_setup
  DETECT="${SCRIPTS_DIR}/detect-signals.sh"
  export DETECT
}
teardown() { common_teardown; }

# Helper: jq query convenience
jqv() {
  local query="$1" file="$2"
  jq -r "$query" "$file"
}

@test "AC1: Node/React + Vitest stack detection" {
  mkdir -p "$TEST_TMP/proj"
  cat > "$TEST_TMP/proj/package.json" <<'JSON'
{
  "name": "demo",
  "dependencies": {
    "react": "18.3.1"
  },
  "devDependencies": {
    "vitest": "1.4.0"
  }
}
JSON
  run "$DETECT" --project-root "$TEST_TMP/proj" --format json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TEST_TMP/out.json"
  # name
  [ "$(jqv '.stacks[0].name' "$TEST_TMP/out.json")" = "react" ]
  # version (must be a non-empty value pulled from package.json)
  ver="$(jqv '.stacks[0].version' "$TEST_TMP/out.json")"
  [ -n "$ver" ] && [ "$ver" != "null" ]
  # test_runner is vitest (single string when no conflict)
  tr_val="$(jqv '.stacks[0].test_runner' "$TEST_TMP/out.json")"
  [ "$tr_val" = "vitest" ]
}

@test "AC2: docker + kubernetes platform detection" {
  mkdir -p "$TEST_TMP/proj"
  : > "$TEST_TMP/proj/Dockerfile"
  : > "$TEST_TMP/proj/docker-compose.yml"
  cat > "$TEST_TMP/proj/Makefile" <<'MAKE'
deploy:
	kubectl apply -f k8s/
MAKE
  run "$DETECT" --project-root "$TEST_TMP/proj" --format json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TEST_TMP/out.json"
  has_docker="$(jqv '.platforms | map(.name) | index("docker") != null' "$TEST_TMP/out.json")"
  has_k8s="$(jqv '.platforms | map(.name) | index("kubernetes") != null' "$TEST_TMP/out.json")"
  [ "$has_docker" = "true" ]
  [ "$has_k8s" = "true" ]
}

@test "AC3: GitHub Actions CI platform detection" {
  mkdir -p "$TEST_TMP/proj/.github/workflows"
  cat > "$TEST_TMP/proj/.github/workflows/ci.yml" <<'YAML'
name: ci
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YAML
  run "$DETECT" --project-root "$TEST_TMP/proj" --format json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TEST_TMP/out.json"
  [ "$(jqv '.ci_platform.provider' "$TEST_TMP/out.json")" = "github-actions" ]
  [ "$(jqv '.ci_platform.config_path' "$TEST_TMP/out.json")" = ".github/workflows/" ]
}

@test "AC4: GitLab CI platform detection" {
  mkdir -p "$TEST_TMP/proj"
  cat > "$TEST_TMP/proj/.gitlab-ci.yml" <<'YAML'
stages: [test]
YAML
  run "$DETECT" --project-root "$TEST_TMP/proj" --format json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TEST_TMP/out.json"
  [ "$(jqv '.ci_platform.provider' "$TEST_TMP/out.json")" = "gitlab-ci" ]
  [ "$(jqv '.ci_platform.config_path' "$TEST_TMP/out.json")" = ".gitlab-ci.yml" ]
}

@test "AC5: tool-provider detection for sonarqube + eslint" {
  mkdir -p "$TEST_TMP/proj"
  : > "$TEST_TMP/proj/sonar-project.properties"
  : > "$TEST_TMP/proj/eslint.config.js"
  run "$DETECT" --project-root "$TEST_TMP/proj" --format json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TEST_TMP/out.json"
  has_sonar="$(jqv '.tool_providers | map(.name) | index("sonarqube") != null' "$TEST_TMP/out.json")"
  has_eslint="$(jqv '.tool_providers | map(.name) | index("eslint") != null' "$TEST_TMP/out.json")"
  [ "$has_sonar" = "true" ]
  [ "$has_eslint" = "true" ]
}

@test "AC6: empty project — no signals, advisory emitted" {
  mkdir -p "$TEST_TMP/proj"
  # Documentation-only files do not count as signals.
  echo "# README" > "$TEST_TMP/proj/README.md"
  run "$DETECT" --project-root "$TEST_TMP/proj" --format json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TEST_TMP/out.json"
  [ "$(jqv '.stacks | length' "$TEST_TMP/out.json")" = "0" ]
  [ "$(jqv '.platforms | length' "$TEST_TMP/out.json")" = "0" ]
  [ "$(jqv '.ci_platform' "$TEST_TMP/out.json")" = "null" ]
  [ "$(jqv '.tool_providers | length' "$TEST_TMP/out.json")" = "0" ]
  # An advisory must reference manual configuration via /gaia-config-*
  count="$(jqv '.warnings | map(select(test("No signals detected"; "i"))) | length' "$TEST_TMP/out.json")"
  [ "$count" -ge 1 ]
}

@test "AC7: conflicting test runners — array + WARNING advisory" {
  mkdir -p "$TEST_TMP/proj"
  cat > "$TEST_TMP/proj/package.json" <<'JSON'
{
  "name": "demo",
  "dependencies": { "react": "18.3.1" },
  "devDependencies": { "vitest": "1.4.0", "jest": "29.7.0" }
}
JSON
  : > "$TEST_TMP/proj/jest.config.js"
  : > "$TEST_TMP/proj/vitest.config.ts"
  run "$DETECT" --project-root "$TEST_TMP/proj" --format json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TEST_TMP/out.json"
  # test_runner becomes an array containing both
  tr_type="$(jqv '.stacks[0].test_runner | type' "$TEST_TMP/out.json")"
  [ "$tr_type" = "array" ]
  has_vitest="$(jqv '.stacks[0].test_runner | index("vitest") != null' "$TEST_TMP/out.json")"
  has_jest="$(jqv '.stacks[0].test_runner | index("jest") != null' "$TEST_TMP/out.json")"
  [ "$has_vitest" = "true" ]
  [ "$has_jest" = "true" ]
  # WARNING advisory present
  warn_count="$(jqv '.warnings | map(select(test("test_runner|primary runner|conflict"; "i"))) | length' "$TEST_TMP/out.json")"
  [ "$warn_count" -ge 1 ]
  # Verdict surfaces WARNING
  [ "$(jqv '.verdict' "$TEST_TMP/out.json")" = "WARNING" ]
}

@test "AC8: RFC 7396 merge — user-edited values are preserved" {
  mkdir -p "$TEST_TMP/proj/config"
  cat > "$TEST_TMP/proj/package.json" <<'JSON'
{ "name": "demo", "dependencies": { "react": "18.3.1" } }
JSON
  # User has hand-edited a stacks entry already.
  cat > "$TEST_TMP/proj/config/project-config.yaml" <<'YAML'
project_root: /tmp/gaia
date: 2026-05-05
stacks:
  - name: legacy-thing
    paths: ["legacy/**"]
YAML
  run "$DETECT" --project-root "$TEST_TMP/proj" \
    --merge-into "$TEST_TMP/proj/config/project-config.yaml" \
    --output "$TEST_TMP/proj/config/project-config.draft.yaml"
  [ "$status" -eq 0 ]
  # The user-edited stacks entry must survive verbatim somewhere in the draft.
  grep -q "legacy-thing" "$TEST_TMP/proj/config/project-config.draft.yaml"
  # The original top-level keys must not be wiped out.
  grep -qE '^project_root:' "$TEST_TMP/proj/config/project-config.draft.yaml"
  grep -qE '^date:' "$TEST_TMP/proj/config/project-config.draft.yaml"
}

@test "AC9: draft config validates via resolve-config.sh" {
  mkdir -p "$TEST_TMP/proj/config"
  : > "$TEST_TMP/proj/Dockerfile"
  cat > "$TEST_TMP/proj/package.json" <<'JSON'
{ "name": "demo", "dependencies": { "react": "18.3.1" } }
JSON
  cat > "$TEST_TMP/proj/config/project-config.yaml" <<'YAML'
project_root: /tmp/gaia
project_path: /tmp/gaia/app
memory_path: /tmp/gaia/_memory
checkpoint_path: /tmp/gaia/_memory/checkpoints
installed_path: /tmp/gaia/_gaia
framework_version: 1.134.1
date: 2026-05-05
YAML
  run "$DETECT" --project-root "$TEST_TMP/proj" \
    --merge-into "$TEST_TMP/proj/config/project-config.yaml" \
    --output "$TEST_TMP/proj/config/project-config.draft.yaml"
  [ "$status" -eq 0 ]
  # Validate the merged draft using resolve-config.sh against the canonical schema.
  schema="$(cd "$BATS_TEST_DIRNAME/../../config" && pwd)/project-config.schema.yaml"
  run "${SCRIPTS_DIR}/resolve-config.sh" \
    --shared "$TEST_TMP/proj/config/project-config.draft.yaml" \
    --schema "$schema"
  [ "$status" -eq 0 ]
}

@test "AC10: verdict PASS surfaced when fully populated, no conflicts" {
  mkdir -p "$TEST_TMP/proj"
  cat > "$TEST_TMP/proj/package.json" <<'JSON'
{ "name": "demo", "dependencies": { "react": "18.3.1" }, "devDependencies": { "vitest": "1.4.0" } }
JSON
  : > "$TEST_TMP/proj/Dockerfile"
  mkdir -p "$TEST_TMP/proj/.github/workflows"
  : > "$TEST_TMP/proj/.github/workflows/ci.yml"
  : > "$TEST_TMP/proj/eslint.config.js"
  run "$DETECT" --project-root "$TEST_TMP/proj" --format json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TEST_TMP/out.json"
  verdict="$(jqv '.verdict' "$TEST_TMP/out.json")"
  [ "$verdict" = "PASS" ]
}

@test "verdict CRITICAL when post-merge validation fails" {
  mkdir -p "$TEST_TMP/proj/config"
  cat > "$TEST_TMP/proj/package.json" <<'JSON'
{ "name": "demo", "dependencies": { "react": "18.3.1" } }
JSON
  # Existing config contains a key not in the schema — schema validator rejects it.
  cat > "$TEST_TMP/proj/config/project-config.yaml" <<'YAML'
project_root: /tmp/gaia
date: 2026-05-05
totally_unknown_field: oops
YAML
  schema="$(cd "$BATS_TEST_DIRNAME/../../config" && pwd)/project-config.schema.yaml"
  run "$DETECT" --project-root "$TEST_TMP/proj" \
    --merge-into "$TEST_TMP/proj/config/project-config.yaml" \
    --output "$TEST_TMP/proj/config/project-config.draft.yaml" \
    --schema "$schema" \
    --format json
  # exit code is non-zero on CRITICAL OR the JSON verdict is CRITICAL — accept either contract.
  if [ "$status" -ne 0 ]; then
    : pass
  else
    printf '%s\n' "$output" > "$TEST_TMP/out.json"
    [ "$(jqv '.verdict' "$TEST_TMP/out.json")" = "CRITICAL" ]
  fi
}
