#!/usr/bin/env bats
# sprint-state-split-repo-resolution.bats
#
# Regression guard: in a split-repo layout where the application code lives in
# a subdir (PROJECT_PATH) but `.gaia/` lives at the repo root (PROJECT_ROOT),
# sprint-state.sh MUST resolve `.gaia/state/sprint-status.yaml` relative to
# PROJECT_ROOT — NOT PROJECT_PATH. Previously, `sprint-state.sh init`/`inject`
# silently wrote a stray nested `${PROJECT_PATH}/.gaia/state/sprint-status.yaml`
# while dashboards/retros/validate-gate read the canonical
# `${PROJECT_ROOT}/.gaia/state/sprint-status.yaml`, so sprint state appeared
# not to change.
#
# Backward-compat invariant: when PROJECT_ROOT is unset, the script must still
# fall back to PROJECT_PATH so legacy single-tree callers continue to work.

load 'test_helper.bash'

SCRIPT="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/sprint-state.sh"

setup() {
  common_setup
  REPO_ROOT="$TEST_TMP/repo"
  APP_DIR="$REPO_ROOT/app"
  mkdir -p "$REPO_ROOT/.gaia/state" "$APP_DIR"
  export REPO_ROOT APP_DIR
}

teardown() { common_teardown; }

@test "split-repo: PROJECT_ROOT anchors .gaia/state, PROJECT_PATH (subdir) leaves no stray" {
  # Explicit split: PROJECT_ROOT at the repo root, PROJECT_PATH at the app subdir.
  # init MUST write to PROJECT_ROOT/.gaia/state/sprint-status.yaml.
  PROJECT_ROOT="$REPO_ROOT" PROJECT_PATH="$APP_DIR" \
    "$SCRIPT" init --sprint-id sprint-split-1 >/dev/null 2>&1

  [ -f "$REPO_ROOT/.gaia/state/sprint-status.yaml" ]
  [ ! -f "$APP_DIR/.gaia/state/sprint-status.yaml" ]
}

@test "split-repo: a second writer (inject) also lands at PROJECT_ROOT, not PROJECT_PATH" {
  PROJECT_ROOT="$REPO_ROOT" PROJECT_PATH="$APP_DIR" \
    "$SCRIPT" init --sprint-id sprint-split-2 >/dev/null 2>&1

  # Mutate state via the canonical path (set-shape is a cheap mutation that
  # exercises the same resolver as inject; it MUST find the yaml at
  # PROJECT_ROOT, not PROJECT_PATH).
  run env PROJECT_ROOT="$REPO_ROOT" PROJECT_PATH="$APP_DIR" \
    "$SCRIPT" set-shape --sprint sprint-split-2 --shape thrust
  [ "$status" -eq 0 ]

  grep -q "^sprint_shape: thrust" "$REPO_ROOT/.gaia/state/sprint-status.yaml"
  [ ! -f "$APP_DIR/.gaia/state/sprint-status.yaml" ]
}

@test "backward-compat: PROJECT_ROOT unset falls back to PROJECT_PATH (legacy single-tree)" {
  # Legacy callers that only set PROJECT_PATH must keep working — the resolver
  # falls back to PROJECT_PATH when PROJECT_ROOT and CLAUDE_PROJECT_ROOT are
  # both unset.
  LEGACY="$TEST_TMP/legacy"
  mkdir -p "$LEGACY"

  # Explicitly UNSET both to exercise the fallback chain.
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT PROJECT_PATH="$LEGACY" \
    "$SCRIPT" init --sprint-id sprint-legacy
  [ "$status" -eq 0 ]
  [ -f "$LEGACY/.gaia/state/sprint-status.yaml" ]
}

@test "CLAUDE_PROJECT_ROOT takes precedence over PROJECT_PATH when PROJECT_ROOT unset" {
  # When PROJECT_ROOT is unset but CLAUDE_PROJECT_ROOT is set, the latter wins
  # over PROJECT_PATH — matches the documented Claude Code substrate convention.
  ROOT_VIA_CLAUDE="$TEST_TMP/via_claude_root"
  STRAY="$TEST_TMP/stray_path"
  mkdir -p "$ROOT_VIA_CLAUDE" "$STRAY"

  run env -u PROJECT_ROOT CLAUDE_PROJECT_ROOT="$ROOT_VIA_CLAUDE" PROJECT_PATH="$STRAY" \
    "$SCRIPT" init --sprint-id sprint-claude
  [ "$status" -eq 0 ]
  [ -f "$ROOT_VIA_CLAUDE/.gaia/state/sprint-status.yaml" ]
  [ ! -f "$STRAY/.gaia/state/sprint-status.yaml" ]
}
