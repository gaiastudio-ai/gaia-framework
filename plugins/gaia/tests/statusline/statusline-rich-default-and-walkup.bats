#!/usr/bin/env bats
# statusline-rich-default-and-walkup.bats — sprint-43 follow-up.
#
# Covers two coordinated behavioural changes:
#
#   1. Rich theme is now the runtime default (opt-out via
#      GAIA_STATUSLINE_THEME=minimal). Historically users had to set
#      GAIA_STATUSLINE_THEME=rich to surface context-bar / rate-limits /
#      sprint segments — which almost nobody did because settings.json
#      statusLine commands run without env.
#
#   2. sprint-status.yaml is now resolved by walking UP from PROJECT_PATH
#      up to 5 levels, so terminals whose cwd is inside a subproject
#      (e.g., $PROJECT_ROOT/gaia-framework/) still find the artifact at the
#      true project root.

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
  export HOME="$TEST_TMP/home"
  mkdir -p "$HOME"
}
teardown() { common_teardown; }

# ---- Default theme is rich (sprint chunk visible without env) -----------

@test "default theme renders sprint when sprint-status.yaml exists" {
  mkdir -p docs/implementation-artifacts
  cat > docs/implementation-artifacts/sprint-status.yaml <<'YAML'
sprint_id: sprint-99
status: active
YAML
  stdin='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$TEST_TMP"'"}}'
  # No GAIA_STATUSLINE_THEME env — relies on the new default.
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$TEST_TMP' printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$TEST_TMP' '$RUNTIME'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-99"* ]]
}

@test "minimal theme suppresses sprint chunk (opt-out path)" {
  mkdir -p docs/implementation-artifacts
  cat > docs/implementation-artifacts/sprint-status.yaml <<'YAML'
sprint_id: sprint-99
status: active
YAML
  stdin='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$TEST_TMP"'"}}'
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=minimal HOME='$HOME' PROJECT_PATH='$TEST_TMP' printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=minimal HOME='$HOME' PROJECT_PATH='$TEST_TMP' '$RUNTIME'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"sprint-99"* ]]
}

@test "explicit rich theme still renders sprint (backward-compat)" {
  mkdir -p docs/implementation-artifacts
  cat > docs/implementation-artifacts/sprint-status.yaml <<'YAML'
sprint_id: sprint-99
status: active
YAML
  stdin='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$TEST_TMP"'"}}'
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich HOME='$HOME' PROJECT_PATH='$TEST_TMP' printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich HOME='$HOME' PROJECT_PATH='$TEST_TMP' '$RUNTIME'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-99"* ]]
}

@test "rate-limits chunk renders by default with rich theme + rate_limits stdin" {
  # AF-27-5: the rate-limits chunk is now per-window "5h:<pct>%" (no "RL:" prefix).
  stdin='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$TEST_TMP"'"},"rate_limits":{"five_hour":{"used_percentage":42}}}'
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$TEST_TMP' printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$TEST_TMP' '$RUNTIME'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"5h:42%"* ]]
}

@test "rate-limits chunk suppressed under minimal theme" {
  stdin='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$TEST_TMP"'"},"rate_limits":{"five_hour":{"used_percentage":42}}}'
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=minimal HOME='$HOME' PROJECT_PATH='$TEST_TMP' printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=minimal HOME='$HOME' PROJECT_PATH='$TEST_TMP' '$RUNTIME'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"5h:"* ]]
}

# ---- Sprint-status walk-up resolution ------------------------------------

@test "walk-up: sprint-status.yaml at project root resolves from subdir cwd" {
  # docs/implementation-artifacts/sprint-status.yaml lives at $TEST_TMP root.
  # PROJECT_PATH is $TEST_TMP/gaia-framework — one level deeper. The walk-up
  # should find it.
  mkdir -p docs/implementation-artifacts
  cat > docs/implementation-artifacts/sprint-status.yaml <<'YAML'
sprint_id: sprint-77
status: active
YAML
  stdin='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$TEST_TMP/gaia-framework"'"}}'
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$TEST_TMP/gaia-framework' printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$TEST_TMP/gaia-framework' '$RUNTIME'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-77"* ]]
}

@test "walk-up: 4 levels deep still resolves sprint-status.yaml" {
  # Sprint artifact at root, cwd 4 levels deep.
  mkdir -p docs/implementation-artifacts
  cat > docs/implementation-artifacts/sprint-status.yaml <<'YAML'
sprint_id: sprint-77
status: active
YAML
  mkdir -p a/b/c/d
  stdin='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$TEST_TMP/a/b/c/d"'"}}'
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$TEST_TMP/a/b/c/d' printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$TEST_TMP/a/b/c/d' '$RUNTIME'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-77"* ]]
}

@test "walk-up: bounded at 5 levels (deeper sprint-status.yaml NOT found)" {
  # Sprint artifact buried 6 levels above PROJECT_PATH (impossible from a
  # reasonable cwd, but proves the bound).
  mkdir -p docs/implementation-artifacts
  cat > docs/implementation-artifacts/sprint-status.yaml <<'YAML'
sprint_id: sprint-77
status: active
YAML
  mkdir -p a/b/c/d/e/f
  stdin='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$TEST_TMP/a/b/c/d/e/f"'"}}'
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$TEST_TMP/a/b/c/d/e/f' printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$TEST_TMP/a/b/c/d/e/f' '$RUNTIME'"
  [ "$status" -eq 0 ]
  # 6 levels = beyond the 5-level cap; sprint should NOT render.
  [[ "$output" != *"sprint-77"* ]]
}

@test "walk-up: stops at filesystem root without infinite loop" {
  # Run from /tmp; no sprint-status.yaml exists anywhere up the chain;
  # script should complete cleanly without hanging.
  stdin='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"}}'
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH=/tmp printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH=/tmp '$RUNTIME'"
  [ "$status" -eq 0 ]
}

@test "walk-up: nearest sprint-status.yaml wins when multiple in the chain" {
  # Two sprint-status.yaml files exist in the walk-up chain. The NEAREST
  # one (the one we hit first) wins. PROJECT_PATH = $TEST_TMP/a/b/c, with
  # a file at $TEST_TMP/a/docs/implementation-artifacts/ (closer) and one
  # at $TEST_TMP/docs/... (farther). The closer one wins.
  mkdir -p docs/implementation-artifacts
  cat > docs/implementation-artifacts/sprint-status.yaml <<'YAML'
sprint_id: sprint-FAR
status: active
YAML
  mkdir -p a/docs/implementation-artifacts a/b/c
  cat > a/docs/implementation-artifacts/sprint-status.yaml <<'YAML'
sprint_id: sprint-NEAR
status: active
YAML
  stdin='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$TEST_TMP/a/b/c"'"}}'
  run bash -c "COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$TEST_TMP/a/b/c' printf '%s' '$stdin' | env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 HOME='$HOME' PROJECT_PATH='$TEST_TMP/a/b/c' '$RUNTIME'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-NEAR"* ]]
  [[ "$output" != *"sprint-FAR"* ]]
}
