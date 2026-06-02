#!/usr/bin/env bats
# statusline-sprint-closed-suppress.bats — suppress closed sprint_id display.
#
# Bug: after /gaia-sprint-close stamps `status: closed`, the statusline kept
# rendering the closed sprint_id because it only read the `sprint_id:` field
# and ignored the `status:` field. Suppressing closed sprints lets the
# statusline correctly show "no active sprint" until /gaia-sprint-plan rolls
# the next sprint forward.

load '../test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  RUNTIME="$PLUGIN_ROOT/scripts/statusline.sh"
  cd "$TEST_TMP"
  mkdir -p gaia-framework/plugins/gaia/.claude-plugin
  cat > gaia-framework/plugins/gaia/.claude-plugin/plugin.json <<'PJ'
{ "name": "gaia", "version": "9.9.9-test" }
PJ
  mkdir -p docs/implementation-artifacts
  export PROJECT_PATH="$TEST_TMP"
  export GAIA_STATUSLINE_THEME="rich"
}
teardown() { common_teardown; }

_stdin() {
  printf '{"model":{"id":"o","display_name":"Opus"},"workspace":{"current_dir":"%s"}}' \
    "$TEST_TMP"
}

@test "rich theme: active sprint_id is rendered" {
  cat > docs/implementation-artifacts/sprint-status.yaml <<'YAML'
sprint_id: "sprint-42"
status: "active"
YAML
  stdin="$(_stdin)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich PROJECT_PATH='$TEST_TMP' '$RUNTIME'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-42"* ]]
}

@test "rich theme: closed sprint_id is suppressed" {
  cat > docs/implementation-artifacts/sprint-status.yaml <<'YAML'
sprint_id: "sprint-42"
status: "closed"
closed_at: "2026-05-12T05:06:01Z"
YAML
  stdin="$(_stdin)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich PROJECT_PATH='$TEST_TMP' '$RUNTIME'"
  [ "$status" -eq 0 ]
  # sprint-42 MUST NOT appear in rendered output.
  ! echo "$output" | grep -q "sprint-42"
}

@test "rich theme: missing status field (legacy yaml) defaults to active and renders sprint_id" {
  # Backward-compat: a sprint-status.yaml with no top-level status: field is
  # treated as active per gaia-sprint-close SKILL.md backward-compat rule.
  cat > docs/implementation-artifacts/sprint-status.yaml <<'YAML'
sprint_id: "sprint-41"
YAML
  stdin="$(_stdin)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich PROJECT_PATH='$TEST_TMP' '$RUNTIME'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-41"* ]]
}

@test "rich theme: closed status with quoted value is suppressed (yaml-quoting variant)" {
  cat > docs/implementation-artifacts/sprint-status.yaml <<'YAML'
sprint_id: sprint-42
status: closed
closed_at: 2026-05-12T05:06:01Z
YAML
  stdin="$(_stdin)"
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich PROJECT_PATH='$TEST_TMP' '$RUNTIME'"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "sprint-42"
}
