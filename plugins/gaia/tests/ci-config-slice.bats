#!/usr/bin/env bats
# ci-config-slice.bats — the tracked CI-scoped config slice + its generator.
#
# Some projects keep the canonical project-config OUTSIDE the published repo
# (above the checkout root, gitignored within). gen-ci-config.sh emits a
# minimal, comment-free, CI-scoped slice (stacks + ci_cd.promotion_chain +
# test_policy) that IS committed at .gaia/ci-config.yaml so CI resolves config
# at the checkout root. These tests pin the generator's contract and assert the
# committed slice is well-formed; the drift check (committed == regenerated)
# runs only where a canonical config is reachable.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  GEN="$SCRIPTS_DIR/gen-ci-config.sh"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  COMMITTED="$REPO_ROOT/.gaia/ci-config.yaml"
  CENTRAL="$TEST_TMP/canonical.yaml"
  cat > "$CENTRAL" <<'YAML'
project_name: acme
platforms: [web]
# a comment carrying something that must NOT leak into the slice
ci_cd:
  promotion_chain:
    - { id: staging, branch: staging }
    - { id: main, branch: main }
release:
  version_files: [package.json]
environments:
  - { id: production, branch: main, kind: deploy }
test_policy:
  always_run: [api]
  triggers:
    pr: { include_stacks: [api] }
stacks:
  - { name: api, language: typescript, paths: ["api/**"] }
YAML
}
teardown() { common_teardown; }

@test "generator exists and is executable" {
  [ -f "$GEN" ]
  [ -x "$GEN" ]
}

@test "--help exits 0 with usage" {
  run bash "$GEN" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"CI-scoped"* ]]
}

@test "missing --config exits 1" {
  run bash "$GEN"
  [ "$status" -eq 1 ]
}

@test "slice carries ONLY the CI fields (stacks, ci_cd.promotion_chain, test_policy)" {
  run --separate-stderr bash "$GEN" --config "$CENTRAL"
  [ "$status" -eq 0 ]
  # present
  [ "$(printf '%s' "$output" | yq 'has("stacks")')" = "true" ]
  [ "$(printf '%s' "$output" | yq 'has("ci_cd")')" = "true" ]
  [ "$(printf '%s' "$output" | yq '.ci_cd | has("promotion_chain")')" = "true" ]
  [ "$(printf '%s' "$output" | yq 'has("test_policy")')" = "true" ]
  # excluded — no secrets/local/deploy fields
  [ "$(printf '%s' "$output" | yq 'has("environments")')" = "false" ]
  [ "$(printf '%s' "$output" | yq 'has("release")')" = "false" ]
  [ "$(printf '%s' "$output" | yq 'has("platforms")')" = "false" ]
}

@test "slice is comment-free (no source comments leak through)" {
  run --separate-stderr bash "$GEN" --config "$CENTRAL"
  [ "$status" -eq 0 ]
  # The YAML body (excluding the generated header block) carries no '#'.
  body="$(printf '%s\n' "$output" | grep -v '^#' || true)"
  [[ "$body" != *"# a comment carrying"* ]]
  [[ "$body" != *"must NOT leak"* ]]
}

@test "promotion_chain is carried verbatim (last tier = main)" {
  run --separate-stderr bash "$GEN" --config "$CENTRAL"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | yq '.ci_cd.promotion_chain[-1].branch')" = "main" ]
}

@test "generation is idempotent (two runs byte-identical)" {
  a="$(bash "$GEN" --config "$CENTRAL" 2>/dev/null)"
  b="$(bash "$GEN" --config "$CENTRAL" 2>/dev/null)"
  [ "$a" = "$b" ]
}

@test "--out writes the slice, creating parent dirs" {
  run --separate-stderr bash "$GEN" --config "$CENTRAL" --out "$TEST_TMP/x/.gaia/ci-config.yaml"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/x/.gaia/ci-config.yaml" ]
  [ "$(yq '.stacks[0].name' "$TEST_TMP/x/.gaia/ci-config.yaml")" = "api" ]
}

@test "committed .gaia/ci-config.yaml exists, is well-formed, comment-free, and CI-scoped" {
  [ -f "$COMMITTED" ]
  [ "$(yq 'has("stacks")' "$COMMITTED")" = "true" ]
  [ "$(yq '.ci_cd | has("promotion_chain")' "$COMMITTED")" = "true" ]
  [ "$(yq 'has("environments")' "$COMMITTED")" = "false" ]
  [ "$(yq 'has("release")' "$COMMITTED")" = "false" ]
  # no leaked internal IDs in the committed slice body
  ! grep -qE '(FR|NFR|SR)-[0-9]|ADR-[0-9]|E[0-9]+-S[0-9]+|TC-[A-Z][A-Z]' "$COMMITTED"
}

@test "drift: committed slice matches the generator when a canonical config is reachable" {
  # The canonical config lives outside the repo (above the checkout). When it is
  # reachable (local dev), assert no drift. In CI (config absent) this is a
  # documented skip — the committed slice IS the source of truth there.
  canonical=""
  for c in "$REPO_ROOT/../.gaia/config/project-config.yaml" "${GAIA_CONFIG:-}" "${CLAUDE_PROJECT_ROOT:-}/.gaia/config/project-config.yaml"; do
    [ -n "$c" ] && [ -f "$c" ] && { canonical="$c"; break; }
  done
  [ -n "$canonical" ] || skip "canonical project-config not reachable (expected in CI)"
  # The committed slice is generated with --strip-prefix gaia-public/ so its
  # globs are checkout-root-relative; regenerate the same way for the diff.
  diff <(bash "$GEN" --config "$canonical" --strip-prefix "gaia-public/" 2>/dev/null) "$COMMITTED"
}

@test "committed slice globs are checkout-root-relative (no gaia-public/ prefix)" {
  # In this repo CI checks out gaia-public/ as the root, so the slice's stack
  # globs must NOT carry the gaia-public/ prefix or detect-affected won't match.
  run grep -E 'gaia-public/' "$COMMITTED"
  [ "$status" -ne 0 ]
}

@test "--strip-prefix rebases stack globs to the checkout root" {
  run --separate-stderr bash "$GEN" --config "$CENTRAL" --strip-prefix "api/"
  [ "$status" -eq 0 ]
  # api/** -> ** (the prefix is stripped from the front of each glob)
  [ "$(printf '%s' "$output" | yq '.stacks[0].paths[0]')" = "**" ]
}
