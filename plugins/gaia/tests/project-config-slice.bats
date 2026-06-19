#!/usr/bin/env bats
# project-config-slice.bats — per-service config-slice projection (multi-repo layouts).
#
# The script emits the minimal self-contained config a single service repo needs:
# its own stacks[] entries + the transitive cross_refs closure, plus
# ci_cd.promotion_chain / release / environments / platforms / project_name.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/project-config-slice.sh"
  CENTRAL="$TEST_TMP/central.yaml"
  cat > "$CENTRAL" <<'YAML'
project_name: acme-platform
platforms:
  - web
ci_cd:
  promotion_chain:
    - {id: staging, branch: staging}
    - {id: main, branch: main}
release:
  strategy: conventional-commits
  version_files: [backend/package.json, frontend/package.json]
environments:
  - {id: production, branch: main, kind: deploy}
stacks:
  - {name: backend,    language: typescript, paths: ["backend/**"],   repository: acme/backend,    cross_refs: ["shared-lib"]}
  - {name: frontend,   language: typescript, paths: ["frontend/**"],  repository: acme/frontend,   cross_refs: ["shared-lib"]}
  - {name: shared-lib, language: typescript, paths: ["shared/**"],    repository: acme/shared-lib}
  - {name: marketing,  language: html,       paths: ["marketing/**"], repository: acme/marketing}
YAML
}
teardown() { common_teardown; }

# names <args...> → newline-sorted stack names in the emitted slice
names() {
  run --separate-stderr bash "$SCRIPT" "$@"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | yq '.stacks[].name' | sort
}

@test "script exists and is executable" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
}

@test "--help exits 0 with usage" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--service"* ]]
  [[ "$output" == *"slice"* ]]
}

@test "missing --config or --service exits 1" {
  run bash "$SCRIPT" --service acme/backend
  [ "$status" -eq 1 ]
  run bash "$SCRIPT" --config "$CENTRAL"
  [ "$status" -eq 1 ]
}

@test "slice by repository includes the service stack + transitive cross_refs closure" {
  result="$(names --config "$CENTRAL" --service acme/backend)"
  [[ "$result" == *"backend"* ]]
  [[ "$result" == *"shared-lib"* ]]
  # NOT the unrelated services
  [[ "$result" != *"frontend"* ]]
  [[ "$result" != *"marketing"* ]]
}

@test "a service with no cross_refs yields only its own stack" {
  result="$(names --config "$CENTRAL" --service acme/marketing)"
  [ "$result" = "marketing" ]
}

@test "slice carries promotion_chain / release / environments / platforms / project_name" {
  run --separate-stderr bash "$SCRIPT" --config "$CENTRAL" --service acme/backend
  [ "$status" -eq 0 ]
  for key in ci_cd release environments platforms project_name; do
    [ "$(printf '%s' "$output" | yq "has(\"$key\")")" = "true" ]
  done
  # promotion_chain must be carried verbatim so the promotion-push rail fires.
  [ "$(printf '%s' "$output" | yq '.ci_cd.promotion_chain[-1].branch')" = "main" ]
}

@test "slice by stack name (no repository declared on the CLI) resolves" {
  result="$(names --config "$CENTRAL" --service shared-lib)"
  [ "$result" = "shared-lib" ]
}

@test "unknown service exits 2" {
  run --separate-stderr bash "$SCRIPT" --config "$CENTRAL" --service acme/nope
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"no stack matches"* ]]
}

@test "missing config file exits 1" {
  run bash "$SCRIPT" --config "$TEST_TMP/does-not-exist.yaml" --service acme/backend
  [ "$status" -eq 1 ]
}

@test "projection is idempotent (two runs byte-identical)" {
  a="$(bash "$SCRIPT" --config "$CENTRAL" --service acme/backend 2>/dev/null)"
  b="$(bash "$SCRIPT" --config "$CENTRAL" --service acme/backend 2>/dev/null)"
  [ "$a" = "$b" ]
}

@test "--out writes the slice to the named path, creating parent dirs" {
  run --separate-stderr bash "$SCRIPT" --config "$CENTRAL" --service acme/backend --out "$TEST_TMP/svc/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/svc/.gaia/config/project-config.yaml" ]
  [ "$(yq '.project_name' "$TEST_TMP/svc/.gaia/config/project-config.yaml")" = "acme-platform" ]
}

@test "emitted slice carries the generated-file header" {
  run --separate-stderr bash "$SCRIPT" --config "$CENTRAL" --service acme/backend
  [ "$status" -eq 0 ]
  [[ "$output" == *"DO NOT EDIT BY HAND"* ]]
  [[ "$output" == *"acme/backend"* ]]
}

@test "diamond cross_refs closure resolves fully (a→b, a→c, b→d)" {
  cat > "$TEST_TMP/diamond.yaml" <<'YAML'
project_name: d
platforms: [web]
stacks:
  - {name: a, language: ts, paths: ["a/**"], repository: o/a, cross_refs: ["b","c"]}
  - {name: b, language: ts, paths: ["b/**"], repository: o/b, cross_refs: ["d"]}
  - {name: c, language: ts, paths: ["c/**"], repository: o/c}
  - {name: d, language: ts, paths: ["d/**"], repository: o/d}
  - {name: z, language: ts, paths: ["z/**"], repository: o/z}
YAML
  result="$(names --config "$TEST_TMP/diamond.yaml" --service o/a)"
  for s in a b c d; do [[ "$result" == *"$s"* ]]; done
  [[ "$result" != *"z"* ]]
}
