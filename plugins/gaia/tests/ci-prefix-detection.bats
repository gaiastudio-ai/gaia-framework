#!/usr/bin/env bats
# ci-prefix-detection.bats — E98-S1 (FR-516, FR-519, ADR-114, TC-CCL-1/2/3)
#
# Verifies that gaia_ci_classify in scripts/lib/ci-prefix-detection.sh
# classifies .github/workflows/*.yml basenames as one of:
#   generated | user-authored | overlay | unprefixed
#
# Precedence (first match wins, per AC2):
#   1. overlay      — gaia-*.user-jobs.yml OR gaia-*.user-steps.yml
#   2. generated    — basename starts with gaia-
#   3. user-authored— basename starts with user-
#   4. unprefixed   — anything else (E98-S5 migration-eligible)

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"
  HELPER="$PLUGIN_DIR/scripts/lib/ci-prefix-detection.sh"
}

teardown() {
  common_teardown
}

# ---------- AC4 / TC-CCL-1: gaia- prefix → generated ----------

@test "gaia-ci.yml classifies as generated" {
  run bash -c "source '$HELPER' && gaia_ci_classify gaia-ci.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "generated" ]
}

@test "variant: gaia-pre-merge.yml classifies as generated" {
  run bash -c "source '$HELPER' && gaia_ci_classify gaia-pre-merge.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "generated" ]
}

# ---------- AC4 / TC-CCL-2: user- prefix → user-authored ----------

@test "user-custom-deploy.yml classifies as user-authored" {
  run bash -c "source '$HELPER' && gaia_ci_classify user-custom-deploy.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "user-authored" ]
}

# ---------- AC4 / TC-CCL-3: no prefix → unprefixed (migration-eligible) ----------

@test "ci.yml (no prefix) classifies as unprefixed" {
  run bash -c "source '$HELPER' && gaia_ci_classify ci.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "unprefixed" ]
}

@test "variant: deploy.yml (no prefix) classifies as unprefixed" {
  run bash -c "source '$HELPER' && gaia_ci_classify deploy.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "unprefixed" ]
}

# ---------- AC2 / AC4: overlay precedence (rule 1 wins over rule 2) ----------

@test "overlay: gaia-ci.user-jobs.yml classifies as overlay" {
  run bash -c "source '$HELPER' && gaia_ci_classify gaia-ci.user-jobs.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "overlay" ]
}

@test "overlay: gaia-ci.user-steps.yml classifies as overlay" {
  run bash -c "source '$HELPER' && gaia_ci_classify gaia-ci.user-steps.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "overlay" ]
}

@test "overlay precedence: gaia-pre-merge.user-jobs.yml still classifies as overlay (rule 1 beats rule 2)" {
  run bash -c "source '$HELPER' && gaia_ci_classify gaia-pre-merge.user-jobs.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "overlay" ]
}

# ---------- AC2: full-path inputs (helper basenames internally) ----------

@test "full path: .github/workflows/gaia-ci.yml classifies as generated" {
  run bash -c "source '$HELPER' && gaia_ci_classify .github/workflows/gaia-ci.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "generated" ]
}

@test "full path: .github/workflows/gaia-ci.user-jobs.yml classifies as overlay" {
  run bash -c "source '$HELPER' && gaia_ci_classify .github/workflows/gaia-ci.user-jobs.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "overlay" ]
}

# ---------- AC4: mixed-state directory — each file classified independently ----------

@test "mixed-state directory: each file classified independently per AC2 precedence" {
  mkdir -p "$TEST_TMP/.github/workflows"
  touch "$TEST_TMP/.github/workflows/gaia-ci.yml"
  touch "$TEST_TMP/.github/workflows/gaia-ci.user-jobs.yml"
  touch "$TEST_TMP/.github/workflows/gaia-ci.user-steps.yml"
  touch "$TEST_TMP/.github/workflows/user-custom-deploy.yml"
  touch "$TEST_TMP/.github/workflows/legacy.yml"

  # shellcheck disable=SC1090
  source "$HELPER"

  run gaia_ci_classify "$TEST_TMP/.github/workflows/gaia-ci.yml"
  [ "$output" = "generated" ]

  run gaia_ci_classify "$TEST_TMP/.github/workflows/gaia-ci.user-jobs.yml"
  [ "$output" = "overlay" ]

  run gaia_ci_classify "$TEST_TMP/.github/workflows/gaia-ci.user-steps.yml"
  [ "$output" = "overlay" ]

  run gaia_ci_classify "$TEST_TMP/.github/workflows/user-custom-deploy.yml"
  [ "$output" = "user-authored" ]

  run gaia_ci_classify "$TEST_TMP/.github/workflows/legacy.yml"
  [ "$output" = "unprefixed" ]
}

# ---------- AC5: no side effects / no global-state mutation ----------

@test "gaia_ci_classify has no side effects (no global state mutation)" {
  # Source once; capture environment-variable count before/after invocation.
  # shellcheck disable=SC1090
  source "$HELPER"
  local before after
  before="$(env | wc -l | tr -d ' ')"
  gaia_ci_classify gaia-ci.yml >/dev/null
  gaia_ci_classify user-foo.yml >/dev/null
  gaia_ci_classify other.yml >/dev/null
  after="$(env | wc -l | tr -d ' ')"
  [ "$before" = "$after" ]
}

@test "source-guard prevents double-source side effect" {
  run bash -c "source '$HELPER' && source '$HELPER' && declare -F gaia_ci_classify >/dev/null && echo OK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}
