#!/usr/bin/env bats
# assert-protected-jobs.bats — E98-S3 (FR-517, ADR-114 §(d), TC-CCL-6/7)

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"
  ASSERT="$PLUGIN_DIR/scripts/lib/assert-protected-jobs.sh"
  WORKDIR="$TEST_TMP/.github/workflows"
  mkdir -p "$WORKDIR"
}

teardown() { common_teardown; }

# ---------- TC-CCL-7 protected names exit non-zero ----------

@test "TC-CCL-7: bats-tests is protected → exit non-zero with canonical stderr" {
  cat > "$WORKDIR/gaia-ci.user-jobs.yml" <<'YAML'
jobs:
  bats-tests:
    runs-on: ubuntu-latest
    steps:
      - run: echo override
YAML
  run bash -c "source '$ASSERT' && assert_protected_jobs '$WORKDIR/gaia-ci.user-jobs.yml'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'protected job name collision'
  echo "$output" | grep -q 'bats-tests'
  echo "$output" | grep -q 'gaia-ci.user-jobs.yml'
}

@test "TC-CCL-7: shellcheck is protected → exit non-zero" {
  cat > "$WORKDIR/gaia-ci.user-jobs.yml" <<'YAML'
jobs:
  shellcheck:
    runs-on: ubuntu-latest
    steps:
      - run: echo override
YAML
  run bash -c "source '$ASSERT' && assert_protected_jobs '$WORKDIR/gaia-ci.user-jobs.yml'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'shellcheck'
}

@test "TC-CCL-7: markdownlint is protected → exit non-zero" {
  cat > "$WORKDIR/gaia-ci.user-jobs.yml" <<'YAML'
jobs:
  markdownlint:
    runs-on: ubuntu-latest
    steps:
      - run: echo override
YAML
  run bash -c "source '$ASSERT' && assert_protected_jobs '$WORKDIR/gaia-ci.user-jobs.yml'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'markdownlint'
}

# ---------- TC-CCL-7 non-protected names exit 0 ----------

@test "TC-CCL-7: non-protected-1 (coverage-upload) → exit 0" {
  cat > "$WORKDIR/gaia-ci.user-jobs.yml" <<'YAML'
jobs:
  coverage-upload:
    runs-on: ubuntu-latest
    steps:
      - run: echo coverage
YAML
  run bash -c "source '$ASSERT' && assert_protected_jobs '$WORKDIR/gaia-ci.user-jobs.yml'"
  [ "$status" -eq 0 ]
}

@test "TC-CCL-7: non-protected-2 (notify-slack) → exit 0" {
  cat > "$WORKDIR/gaia-ci.user-jobs.yml" <<'YAML'
jobs:
  notify-slack:
    runs-on: ubuntu-latest
    steps:
      - run: echo slack
YAML
  run bash -c "source '$ASSERT' && assert_protected_jobs '$WORKDIR/gaia-ci.user-jobs.yml'"
  [ "$status" -eq 0 ]
}

@test "TC-CCL-7: non-protected-3 (deploy-prod) → exit 0" {
  cat > "$WORKDIR/gaia-ci.user-jobs.yml" <<'YAML'
jobs:
  deploy-prod:
    runs-on: ubuntu-latest
    steps:
      - run: echo deploy
YAML
  run bash -c "source '$ASSERT' && assert_protected_jobs '$WORKDIR/gaia-ci.user-jobs.yml'"
  [ "$status" -eq 0 ]
}

# ---------- AC5: actionable error mentions remediation + ADR cite ----------

@test "AC5: collision error names file + job + remediation + ADR-114 cite" {
  cat > "$WORKDIR/gaia-ci.user-jobs.yml" <<'YAML'
jobs:
  bats-tests:
    runs-on: ubuntu-latest
    steps:
      - run: echo override
YAML
  run bash -c "source '$ASSERT' && assert_protected_jobs '$WORKDIR/gaia-ci.user-jobs.yml'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'rename'
  echo "$output" | grep -qE 'ADR-114|FR-517'
}

# ---------- TC-CCL-6: stitcher HALTs on collision; no file written ----------

@test "TC-CCL-6: stitcher HALTs on protected-job collision; output NOT written" {
  cat > "$WORKDIR/gaia-ci.yml" <<'YAML'
name: ci
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo build
YAML
  cat > "$WORKDIR/gaia-ci.user-jobs.yml" <<'YAML'
jobs:
  bats-tests:
    runs-on: ubuntu-latest
    steps:
      - run: echo override
YAML
  local target="$TEST_TMP/out.yml"
  STITCHER="$PLUGIN_DIR/scripts/lib/ci-workflow-stitcher.sh"
  run bash -c "source '$STITCHER' && gaia_ci_stitch '$WORKDIR/gaia-ci.yml' '$target'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'protected job name collision'
  # Output file MUST NOT exist (no partial regeneration)
  [ ! -f "$target" ]
}

# ---------- Source-guard + multi-collision report ----------

@test "source-guard: double-source is idempotent" {
  run bash -c "source '$ASSERT' && source '$ASSERT' && declare -F assert_protected_jobs >/dev/null && echo OK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "multi-collision: two protected names in one overlay → exit non-zero, both reported" {
  cat > "$WORKDIR/gaia-ci.user-jobs.yml" <<'YAML'
jobs:
  bats-tests:
    runs-on: ubuntu-latest
    steps:
      - run: echo a
  shellcheck:
    runs-on: ubuntu-latest
    steps:
      - run: echo b
YAML
  run bash -c "source '$ASSERT' && assert_protected_jobs '$WORKDIR/gaia-ci.user-jobs.yml'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'bats-tests'
  echo "$output" | grep -q 'shellcheck'
}
