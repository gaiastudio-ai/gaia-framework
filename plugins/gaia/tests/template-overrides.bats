#!/usr/bin/env bats
# template-overrides.bats — E98-S4 (FR-518, ADR-114 §(e), SR-78, TC-TOV-1/2/3/4)

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"
  OVERRIDES="$PLUGIN_DIR/scripts/lib/template-overrides.sh"
  WORKDIR="$TEST_TMP"
  mkdir -p "$WORKDIR"
}

teardown() { common_teardown; }

# Helper: write a canonical generated workflow with two jobs (bats-tests,
# shellcheck) and a markdownlint adapter-invoking job for the override tests.
_canonical_workflow() {
  cat > "$WORKDIR/gaia-ci.yml" <<'YAML'
name: ci
on: [push]
jobs:
  bats-tests:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - run: echo bats
  shellcheck:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - run: echo shellcheck
  markdownlint:
    runs-on: ubuntu-latest
    steps:
      - run: npm install markdownlint@latest
      - run: npx markdownlint .
YAML
}

# ---------- TC-TOV-1: disable removes named job ----------

@test "disable: [shellcheck] removes the job from generated workflow" {
  _canonical_workflow
  cat > "$WORKDIR/project-config.yaml" <<'YAML'
ci_cd:
  template_overrides:
    disable: [shellcheck]
YAML
  run bash -c "source '$OVERRIDES' && gaia_apply_template_overrides '$WORKDIR/gaia-ci.yml' '$WORKDIR/project-config.yaml'"
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -qE '^  shellcheck:'
  printf '%s\n' "$output" | grep -qE '^  bats-tests:'
  printf '%s\n' "$output" | grep -qE '^  markdownlint:'
}

# ---------- TC-TOV-2: timeout_overrides rewrites timeout-minutes ----------

@test "timeout_overrides: {bats-tests: 15} sets timeout-minutes: 15" {
  _canonical_workflow
  cat > "$WORKDIR/project-config.yaml" <<'YAML'
ci_cd:
  template_overrides:
    timeout_overrides:
      bats-tests: 15
YAML
  run bash -c "source '$OVERRIDES' && gaia_apply_template_overrides '$WORKDIR/gaia-ci.yml' '$WORKDIR/project-config.yaml'"
  [ "$status" -eq 0 ]
  # Confirm bats-tests has timeout-minutes: 15
  out=$(printf '%s\n' "$output")
  echo "$out" | yq eval '.jobs.bats-tests."timeout-minutes"' - | grep -q '^15$'
  # Confirm shellcheck still has 10
  echo "$out" | yq eval '.jobs.shellcheck."timeout-minutes"' - | grep -q '^10$'
}

# ---------- TC-TOV-3: adapter_versions pins version ----------

@test "adapter_versions: {markdownlint: 0.41.0} pins the version in the job invocation" {
  _canonical_workflow
  cat > "$WORKDIR/project-config.yaml" <<'YAML'
ci_cd:
  template_overrides:
    adapter_versions:
      markdownlint: "0.41.0"
YAML
  run bash -c "source '$OVERRIDES' && gaia_apply_template_overrides '$WORKDIR/gaia-ci.yml' '$WORKDIR/project-config.yaml'"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'markdownlint@0\.41\.0'
}

# ---------- TC-TOV-4 / SR-78: refuse security-critical disable entries ----------

@test "disable: [commitlint] is rejected with canonical error citing + T" {
  _canonical_workflow
  cat > "$WORKDIR/project-config.yaml" <<'YAML'
ci_cd:
  template_overrides:
    disable: [commitlint]
YAML
  run bash -c "source '$OVERRIDES' && gaia_apply_template_overrides '$WORKDIR/gaia-ci.yml' '$WORKDIR/project-config.yaml'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE 'refusal|security-critical'
  echo "$output" | grep -q 'commitlint'
}

@test "hyphenated form commit-lint is canonicalized and STILL rejected" {
  _canonical_workflow
  cat > "$WORKDIR/project-config.yaml" <<'YAML'
ci_cd:
  template_overrides:
    disable: [commit-lint]
YAML
  run bash -c "source '$OVERRIDES' && gaia_apply_template_overrides '$WORKDIR/gaia-ci.yml' '$WORKDIR/project-config.yaml'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE 'refusal|security-critical'
}

@test "uppercase form Commit-Lint is canonicalized and STILL rejected" {
  _canonical_workflow
  cat > "$WORKDIR/project-config.yaml" <<'YAML'
ci_cd:
  template_overrides:
    disable: [Commit-Lint]
YAML
  run bash -c "source '$OVERRIDES' && gaia_apply_template_overrides '$WORKDIR/gaia-ci.yml' '$WORKDIR/project-config.yaml'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE 'refusal|security-critical'
}

@test "each of the 5 security-critical names is rejected" {
  _canonical_workflow
  for name in commitlint adr-048-guard no-claude-attribution secrets-scan nfr-082-credential-audit; do
    cat > "$WORKDIR/project-config.yaml" <<YAML
ci_cd:
  template_overrides:
    disable: [$name]
YAML
    run bash -c "source '$OVERRIDES' && gaia_apply_template_overrides '$WORKDIR/gaia-ci.yml' '$WORKDIR/project-config.yaml'"
    [ "$status" -ne 0 ] || { echo "FAIL: $name should have been rejected" >&2; return 1; }
  done
}

# ---------- AC6: per-field validation ----------

@test "unknown disable name emits WARNING but does not fail" {
  _canonical_workflow
  cat > "$WORKDIR/project-config.yaml" <<'YAML'
ci_cd:
  template_overrides:
    disable: [does-not-exist-job]
YAML
  run bash -c "source '$OVERRIDES' && gaia_apply_template_overrides '$WORKDIR/gaia-ci.yml' '$WORKDIR/project-config.yaml' 2>&1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qiE 'WARN|warning'
}

@test "timeout out of range (> 360 min) is HARD ERROR" {
  _canonical_workflow
  cat > "$WORKDIR/project-config.yaml" <<'YAML'
ci_cd:
  template_overrides:
    timeout_overrides:
      bats-tests: 999
YAML
  run bash -c "source '$OVERRIDES' && gaia_apply_template_overrides '$WORKDIR/gaia-ci.yml' '$WORKDIR/project-config.yaml'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE 'timeout|range|360'
}

@test "timeout below range (< 1 min) is HARD ERROR" {
  _canonical_workflow
  cat > "$WORKDIR/project-config.yaml" <<'YAML'
ci_cd:
  template_overrides:
    timeout_overrides:
      bats-tests: 0
YAML
  run bash -c "source '$OVERRIDES' && gaia_apply_template_overrides '$WORKDIR/gaia-ci.yml' '$WORKDIR/project-config.yaml'"
  [ "$status" -ne 0 ]
}

@test "unparseable semver in adapter_versions is HARD ERROR" {
  _canonical_workflow
  cat > "$WORKDIR/project-config.yaml" <<'YAML'
ci_cd:
  template_overrides:
    adapter_versions:
      markdownlint: "not-a-version"
YAML
  run bash -c "source '$OVERRIDES' && gaia_apply_template_overrides '$WORKDIR/gaia-ci.yml' '$WORKDIR/project-config.yaml'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE 'semver|version'
}

# ---------- Source-guard ----------

@test "source-guard: double-source is idempotent" {
  run bash -c "source '$OVERRIDES' && source '$OVERRIDES' && declare -F gaia_apply_template_overrides >/dev/null && echo OK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------- No-op when template_overrides absent ----------

@test "no-op: workflow passes through unchanged when template_overrides is absent" {
  _canonical_workflow
  cat > "$WORKDIR/project-config.yaml" <<'YAML'
ci_cd:
  promotion_chain: []
YAML
  run bash -c "source '$OVERRIDES' && gaia_apply_template_overrides '$WORKDIR/gaia-ci.yml' '$WORKDIR/project-config.yaml'"
  [ "$status" -eq 0 ]
  expected=$(cat "$WORKDIR/gaia-ci.yml")
  [ "$output" = "$expected" ]
}
