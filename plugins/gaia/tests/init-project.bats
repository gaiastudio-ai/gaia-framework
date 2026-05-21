#!/usr/bin/env bats
# init-project.bats — unit tests for plugins/gaia/scripts/init-project.sh
# Public functions covered: cleanup_lock, err, usage, main.

load 'test_helper.bash'

setup() { common_setup; SCRIPT="$SCRIPTS_DIR/init-project.sh"; }
teardown() { common_teardown; }

@test "init-project.sh: --help exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
}

@test "init-project.sh: missing --name exits 1" {
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "init-project.sh: happy path creates full skeleton" {
  local p="$TEST_TMP/demo"
  run "$SCRIPT" --name demo --path "$p"
  [ "$status" -eq 0 ]
  # init-project.sh creates the .gaia/ consolidated runtime tree (ADR-111)
  # instead of the legacy docs/ + _memory/ + config/ split.
  [ -d "$p/.gaia/artifacts/planning-artifacts" ]
  [ -d "$p/.gaia/artifacts/implementation-artifacts" ]
  [ -d "$p/.gaia/artifacts/test-artifacts" ]
  [ -d "$p/.gaia/artifacts/creative-artifacts" ]
  [ -d "$p/.gaia/memory/checkpoints" ]
  [ -d "$p/.gaia/config" ]
  [ -s "$p/.gaia/config/project-config.yaml" ]
  [ -s "$p/CLAUDE.md" ]
}

@test "init-project.sh: CLAUDE.md is concise (<=60 lines)" {
  local p="$TEST_TMP/demo"
  "$SCRIPT" --name demo --path "$p"
  local lines
  lines=$(wc -l < "$p/CLAUDE.md" | tr -d ' ')
  [ "$lines" -le 60 ]
}

@test "init-project.sh: idempotent re-run exits 0" {
  local p="$TEST_TMP/demo"
  "$SCRIPT" --name demo --path "$p"
  run "$SCRIPT" --name demo --path "$p"
  [ "$status" -eq 0 ]
}

@test "init-project.sh: non-empty git repo rejected without --force" {
  local p="$TEST_TMP/gitrepo"
  mkdir -p "$p"
  (cd "$p" && git init -q && echo x > a && git add a \
    && git -c user.email=x@x -c user.name=x commit -qm x)
  run "$SCRIPT" --name g --path "$p"
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-empty git repo"* ]]
}

@test "init-project.sh: --force overrides git-repo guard" {
  local p="$TEST_TMP/gitrepo"
  mkdir -p "$p"
  (cd "$p" && git init -q && echo x > a && git add a \
    && git -c user.email=x@x -c user.name=x commit -qm x)
  run "$SCRIPT" --name g --path "$p" --force
  [ "$status" -eq 0 ]
}

@test "init-project.sh: non-empty CLAUDE.md refused without --force" {
  local p="$TEST_TMP/ne"
  mkdir -p "$p"
  printf "user content\n" > "$p/CLAUDE.md"
  run "$SCRIPT" --name ne --path "$p"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to clobber"* ]]
}

@test "init-project.sh: unicode + space in path accepted" {
  local p="$TEST_TMP/démo projet"
  run "$SCRIPT" --name uni --path "$p"
  [ "$status" -eq 0 ]
  [ -s "$p/CLAUDE.md" ]
}
