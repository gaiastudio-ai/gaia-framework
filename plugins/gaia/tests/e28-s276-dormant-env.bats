#!/usr/bin/env bats
# Tests for dormant-environment handling in the script-deploy adapter.

bats_require_minimum_version 1.5.0

setup() {
  ADAPTER="${BATS_TEST_DIRNAME}/../scripts/adapters/script-deploy/run.sh"
  TMPDIR_FIX="${BATS_TEST_TMPDIR}/deploy-$$"
  mkdir -p "$TMPDIR_FIX/output"
}

teardown() {
  rm -rf "$TMPDIR_FIX"
}

@test "dormant env with empty SCRIPT_DEPLOY_PATH exits 3 (AC1)" {
  export GAIA_DEPLOY_ENV_DORMANT=1
  export SCRIPT_DEPLOY_PATH=""
  run bash "$ADAPTER" --env production --version 1.0.0 --output-dir "$TMPDIR_FIX/output"
  [ "$status" -eq 3 ]
  [[ "$output" == *"dormant"* ]]
  [[ "$output" == *"production"* ]]
}

@test "dormant env with missing deploy script exits 3 (AC2)" {
  export GAIA_DEPLOY_ENV_DORMANT=1
  export SCRIPT_DEPLOY_PATH="$TMPDIR_FIX/nonexistent-deploy.sh"
  run bash "$ADAPTER" --env staging --version 2.0.0 --output-dir "$TMPDIR_FIX/output"
  [ "$status" -eq 3 ]
  [[ "$output" == *"dormant"* ]]
}

@test "non-dormant env with empty SCRIPT_DEPLOY_PATH exits 127 (AC3)" {
  unset GAIA_DEPLOY_ENV_DORMANT 2>/dev/null || true
  export SCRIPT_DEPLOY_PATH=""
  run -127 bash "$ADAPTER" --env production --version 1.0.0 --output-dir "$TMPDIR_FIX/output"
  [[ "$output" == *"SCRIPT_DEPLOY_PATH not set"* ]]
}

@test "non-dormant env with missing script exits 127 (AC4)" {
  unset GAIA_DEPLOY_ENV_DORMANT 2>/dev/null || true
  export SCRIPT_DEPLOY_PATH="$TMPDIR_FIX/nonexistent-deploy.sh"
  run -127 bash "$ADAPTER" --env production --version 1.0.0 --output-dir "$TMPDIR_FIX/output"
  [[ "$output" == *"not found or not executable"* ]]
}

@test "dormant diagnostic message mentions not yet provisioned (AC5)" {
  export GAIA_DEPLOY_ENV_DORMANT=1
  export SCRIPT_DEPLOY_PATH=""
  run bash "$ADAPTER" --env production --version 1.0.0 --output-dir "$TMPDIR_FIX/output"
  [[ "$output" == *"not yet provisioned"* ]]
}

@test "valid deploy script runs normally even when dormant flag is unset (AC6)" {
  # Create a simple deploy script that exits 0
  local script="$TMPDIR_FIX/deploy-ok.sh"
  printf '#!/usr/bin/env bash\necho "deployed $1 $2"\n' > "$script"
  chmod +x "$script"
  export SCRIPT_DEPLOY_PATH="$script"
  unset GAIA_DEPLOY_ENV_DORMANT 2>/dev/null || true
  run bash "$ADAPTER" --env staging --version 3.0.0 --output-dir "$TMPDIR_FIX/output"
  [ "$status" -eq 0 ]
}

@test "schema includes dormant field for environment entries (AC7)" {
  local schema="${BATS_TEST_DIRNAME}/../schemas/project-config.schema.json"
  grep -q '"dormant"' "$schema"
}

@test "deploy SKILL.md documents dormant environments (AC8)" {
  local skillmd="${BATS_TEST_DIRNAME}/../skills/gaia-deploy/SKILL.md"
  grep -q 'Dormant' "$skillmd"
  grep -q 'exit.*3\|code.*3' "$skillmd"
}
