#!/usr/bin/env bats
# post-ci-smoke.bats — tests: smoke runner, hydration, global.yaml isolation,
# quoted-key handling, doctor listing, readiness, and dev-story wiring.

load 'test_helper.bash'

setup() {
  export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
  # Clear root variables so resolve-config.sh tests use fixture paths only.
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT PROJECT_PATH PROJECT_CONFIG
  PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$PLUGIN_ROOT/skills/gaia-dev-story/scripts/run-configured-commands.sh"
  CFG_DIR="$BATS_TEST_TMPDIR/.gaia/config"
  mkdir -p "$CFG_DIR"
  WORKDIR="$BATS_TEST_TMPDIR/workdir"
  mkdir -p "$WORKDIR"
  CONFIG="$CFG_DIR/project-config.yaml"
}

teardown() {
  rm -rf "$BATS_TEST_TMPDIR"
}

# --- Smoke runner edge cases ---

@test "smoke command exits 1 — HALT names command and exit code" {
  cat > "$CONFIG" <<'YAML'
post_ci_smoke_commands:
  - "exit 1"
YAML
  run bash "$SCRIPT" --key post_ci_smoke_commands --config "$CONFIG" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  grep -q 'HALT:.*exit 1.*(exit 1)' <<< "$output"
}

@test "smoke multi-command — first passes, second fails, third skipped" {
  cat > "$CONFIG" <<'YAML'
post_ci_smoke_commands:
  - "true"
  - "exit 42"
  - "echo should-not-run"
YAML
  run bash "$SCRIPT" --key post_ci_smoke_commands --config "$CONFIG" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  grep -q 'HALT:.*exit 42.*(exit 42)' <<< "$output"
  case "$output" in *should-not-run*) return 1 ;; esac
}

@test "smoke all pass — merge proceeds" {
  cat > "$CONFIG" <<'YAML'
post_ci_smoke_commands:
  - "true"
  - "echo health-ok"
YAML
  run bash "$SCRIPT" --key post_ci_smoke_commands --config "$CONFIG" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  grep -q 'all 2 commands passed' <<< "$output"
}

@test "smoke key absent on config with other keys — no-op, empty output" {
  cat > "$CONFIG" <<'YAML'
project_name: myproject
ci_cd:
  promotion_chain:
    - staging
YAML
  run bash "$SCRIPT" --key post_ci_smoke_commands --config "$CONFIG" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "smoke commands run in the story working tree" {
  cat > "$CONFIG" <<'YAML'
post_ci_smoke_commands:
  - "pwd"
YAML
  run bash "$SCRIPT" --key post_ci_smoke_commands --config "$CONFIG" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  grep -qF "$WORKDIR" <<< "$output"
}

# --- Quoted/spaced key handling (fail closed, not fail open) ---

@test "quoted key with double quotes is detected and commands run" {
  cat > "$CONFIG" <<'YAML'
"preflight_commands":
  - "false"
YAML
  run bash "$SCRIPT" --key preflight_commands --config "$CONFIG" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  grep -q 'HALT' <<< "$output"
  grep -q 'false' <<< "$output"
}

@test "key with trailing space is detected and commands run" {
  printf 'preflight_commands :\n  - "false"\n' > "$CONFIG"
  run bash "$SCRIPT" --key preflight_commands --config "$CONFIG" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  grep -q 'HALT' <<< "$output"
  grep -q 'false' <<< "$output"
}

# --- Hydration tests (resolve-config.sh) ---

@test "resolve-config.sh emits preflight_commands in JSON output" {
  command -v yq >/dev/null 2>&1 || skip "yq not available"
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  cat > "$CONFIG" <<'YAML'
project_root: /tmp/test
project_path: /tmp/test/src
memory_path: /tmp/test/memory
checkpoint_path: /tmp/test/checkpoints
installed_path: /tmp/test/installed
framework_version: "1.0.0"
date: "2026-01-01"
preflight_commands:
  - "make lint"
  - "make test"
YAML
  run bash "$PLUGIN_ROOT/scripts/resolve-config.sh" --format json \
    --shared "$CONFIG"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.preflight_commands' >/dev/null
  local count
  count="$(echo "$output" | jq '.preflight_commands | length')"
  [ "$count" -eq 2 ]
  local first
  first="$(echo "$output" | jq -r '.preflight_commands[0]')"
  [ "$first" = "make lint" ]
}

@test "resolve-config.sh emits post_ci_smoke_commands in JSON output" {
  command -v yq >/dev/null 2>&1 || skip "yq not available"
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  cat > "$CONFIG" <<'YAML'
project_root: /tmp/test
project_path: /tmp/test/src
memory_path: /tmp/test/memory
checkpoint_path: /tmp/test/checkpoints
installed_path: /tmp/test/installed
framework_version: "1.0.0"
date: "2026-01-01"
post_ci_smoke_commands:
  - "curl -f http://localhost/health"
YAML
  run bash "$PLUGIN_ROOT/scripts/resolve-config.sh" --format json \
    --shared "$CONFIG"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.post_ci_smoke_commands' >/dev/null
  local first
  first="$(echo "$output" | jq -r '.post_ci_smoke_commands[0]')"
  [ "$first" = "curl -f http://localhost/health" ]
}

@test "resolve-config.sh emits preflight_commands_json in shell output" {
  command -v yq >/dev/null 2>&1 || skip "yq not available"
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  cat > "$CONFIG" <<'YAML'
project_root: /tmp/test
project_path: /tmp/test/src
memory_path: /tmp/test/memory
checkpoint_path: /tmp/test/checkpoints
installed_path: /tmp/test/installed
framework_version: "1.0.0"
date: "2026-01-01"
preflight_commands:
  - "echo hello"
YAML
  run bash "$PLUGIN_ROOT/scripts/resolve-config.sh" --format shell \
    --shared "$CONFIG"
  [ "$status" -eq 0 ]
  grep -q 'preflight_commands_json' <<< "$output"
}

@test "resolve-config.sh omits arrays when both keys absent" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  cat > "$CONFIG" <<'YAML'
project_root: /tmp/test
project_path: /tmp/test/src
memory_path: /tmp/test/memory
checkpoint_path: /tmp/test/checkpoints
installed_path: /tmp/test/installed
framework_version: "1.0.0"
date: "2026-01-01"
YAML
  run bash "$PLUGIN_ROOT/scripts/resolve-config.sh" --format json \
    --shared "$CONFIG"
  [ "$status" -eq 0 ]
  local has_pre has_post
  has_pre="$(echo "$output" | jq 'has("preflight_commands")')"
  has_post="$(echo "$output" | jq 'has("post_ci_smoke_commands")')"
  [ "$has_pre" = "false" ]
  [ "$has_post" = "false" ]
}

# --- Global.yaml isolation: arrays are project-level only ---

@test "global.yaml does not blank project-level command arrays" {
  command -v yq >/dev/null 2>&1 || skip "yq not available"
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  cat > "$CONFIG" <<'YAML'
project_root: /tmp/test
project_path: /tmp/test/src
memory_path: /tmp/test/memory
checkpoint_path: /tmp/test/checkpoints
installed_path: /tmp/test/installed
framework_version: "1.0.0"
date: "2026-01-01"
preflight_commands:
  - "make lint"
post_ci_smoke_commands:
  - "make smoke"
YAML
  local global="$CFG_DIR/global.yaml"
  printf 'user_name: testuser\n' > "$global"
  run bash "$PLUGIN_ROOT/scripts/resolve-config.sh" --format json \
    --shared "$CONFIG" --local "$global"
  [ "$status" -eq 0 ]
  local count
  count="$(echo "$output" | jq '.preflight_commands | length')"
  [ "$count" -eq 1 ]
  local first
  first="$(echo "$output" | jq -r '.preflight_commands[0]')"
  [ "$first" = "make lint" ]
  local smoke
  smoke="$(echo "$output" | jq -r '.post_ci_smoke_commands[0]')"
  [ "$smoke" = "make smoke" ]
}

# --- Doctor listing (anchored to step) ---

@test "doctor Step 8 lists preflight_commands with numbered entries" {
  local step8
  step8="$(sed -n '/### Step 8/,/## Finalize/p' "$PLUGIN_ROOT/skills/gaia-doctor/SKILL.md")"
  # The step must mention both keys.
  grep -q 'preflight_commands' <<< "$step8"
  grep -q 'post_ci_smoke_commands' <<< "$step8"
  # The step must describe numbered listing.
  grep -q 'numbered' <<< "$step8"
}

# --- Readiness empty-string check (anchored to rule sentence) ---

@test "readiness Step 9b flags empty-string entries as configuration error" {
  local step9b
  step9b="$(sed -n '/### Step 9b/,/### Step 10/p' "$PLUGIN_ROOT/skills/gaia-readiness-check/SKILL.md")"
  # Pin the rule sentence: empty entries must be reported as a WARNING with key and index.
  grep -qF 'must be reported as a WARNING finding with the key name and the index of the empty entry' <<< "$step9b"
}

# --- Dev-story SKILL.md wiring (anchored on code fences) ---

@test "preflight runner invocation precedes git-push.sh in Step 10" {
  local skill="$PLUGIN_ROOT/skills/gaia-dev-story/SKILL.md"
  local block
  block="$(sed -n '/<!-- step 10 git-push wire begin -->/,/<!-- step 10 git-push wire end -->/p' "$skill")"
  # Anchor on the runner code fence line, not prose.
  grep -qF -- '--key preflight_commands' <<< "$block"
  grep -q 'HALT the push' <<< "$block"
  # The runner --key line must appear BEFORE git-push.sh.
  local runner_line push_line
  runner_line="$(grep -nF -- '--key preflight_commands' <<< "$block" | head -1 | cut -d: -f1)"
  push_line="$(grep -n 'git-push.sh' <<< "$block" | head -1 | cut -d: -f1)"
  [ -n "$runner_line" ]
  [ -n "$push_line" ]
  [ "$runner_line" -lt "$push_line" ]
}

@test "smoke runner invocation follows CI wait and precedes Step 13" {
  local skill="$PLUGIN_ROOT/skills/gaia-dev-story/SKILL.md"
  local between
  between="$(sed -n '/### Step 12/,/### Step 13/p' "$skill")"
  # Anchor on the runner code fence line.
  grep -qF -- '--key post_ci_smoke_commands' <<< "$between"
  grep -q 'HALT the merge' <<< "$between"
  # The green-CI outcome line must appear BEFORE the smoke runner.
  local green_line smoke_line
  green_line="$(grep -n 'CI checks passed. Proceed to Step 13' <<< "$between" | head -1 | cut -d: -f1)"
  smoke_line="$(grep -nF -- '--key post_ci_smoke_commands' <<< "$between" | head -1 | cut -d: -f1)"
  [ -n "$green_line" ]
  [ -n "$smoke_line" ]
  [ "$green_line" -lt "$smoke_line" ]
}

@test "removing preflight gate from Step 10 loses runner invocation" {
  local skill="$PLUGIN_ROOT/skills/gaia-dev-story/SKILL.md"
  local block
  block="$(sed -n '/<!-- step 10 git-push wire begin -->/,/<!-- step 10 git-push wire end -->/p' "$skill")"
  grep -qF -- '--key preflight_commands' <<< "$block"
  grep -q 'HALT the push' <<< "$block"
}

@test "removing smoke hook loses runner invocation" {
  local skill="$PLUGIN_ROOT/skills/gaia-dev-story/SKILL.md"
  local between
  between="$(sed -n '/### Step 12/,/### Step 13/p' "$skill")"
  grep -qF -- '--key post_ci_smoke_commands' <<< "$between"
  grep -q 'HALT the merge' <<< "$between"
}

# --- Helper: build a narrow PATH without yq ---

_build_no_yq_path() {
  local narrow="$BATS_TEST_TMPDIR/narrow-bin"
  mkdir -p "$narrow"
  local b p
  for b in bash grep cat awk sed printf head wc cut tr date mktemp rm jq dirname pwd basename readlink; do
    p="$(command -v "$b" 2>/dev/null || true)"
    [ -n "$p" ] && ln -sf "$p" "$narrow/$b"
  done
  # Verify yq is actually hidden. Use bash -c because env can't find
  # the 'command' builtin directly.
  if env PATH="$narrow" bash -c 'command -v yq' >/dev/null 2>&1; then
    printf 'FAIL: yq is still reachable on the narrow PATH\n' >&2
    return 1
  fi
  printf '%s' "$narrow"
}

# --- Hydration without yq ---

@test "resolve-config.sh fails loudly when yq absent and keys present" {
  [ -x "$(command -v jq)" ] || { echo "jq missing"; return 1; }
  cat > "$CONFIG" <<'YAML'
project_root: /tmp/test
project_path: /tmp/test/src
memory_path: /tmp/test/memory
checkpoint_path: /tmp/test/checkpoints
installed_path: /tmp/test/installed
framework_version: "1.0.0"
date: "2026-01-01"
preflight_commands:
  - "make lint"
YAML
  local narrow
  narrow="$(_build_no_yq_path)"
  run env PATH="$narrow" bash "$PLUGIN_ROOT/scripts/resolve-config.sh" --format json --shared "$CONFIG"
  [ "$status" -ne 0 ]
  grep -qF 'yq is required for preflight_commands' <<< "$output"
}

# --- Comment-only config with no-yq PATH (pins the anchored grep) ---

@test "resolve-config.sh ignores comment-only key when yq absent (no-yq path)" {
  [ -x "$(command -v jq)" ] || { echo "jq missing"; return 1; }
  cat > "$CONFIG" <<'YAML'
project_root: /tmp/test
project_path: /tmp/test/src
memory_path: /tmp/test/memory
checkpoint_path: /tmp/test/checkpoints
installed_path: /tmp/test/installed
framework_version: "1.0.0"
date: "2026-01-01"
# preflight_commands disabled for now
YAML
  local narrow
  narrow="$(_build_no_yq_path)"
  run env PATH="$narrow" bash "$PLUGIN_ROOT/scripts/resolve-config.sh" --format json --shared "$CONFIG"
  [ "$status" -eq 0 ]
}

@test "resolve-config.sh detects quoted key without yq (double-quote)" {
  [ -x "$(command -v jq)" ] || { echo "jq missing"; return 1; }
  printf '"preflight_commands":\n  - "make lint"\nproject_root: /tmp/t\nproject_path: /tmp/t\nmemory_path: /tmp/t\ncheckpoint_path: /tmp/t\ninstalled_path: /tmp/t\nframework_version: "1.0.0"\ndate: "2026-01-01"\n' > "$CONFIG"
  local narrow
  narrow="$(_build_no_yq_path)"
  run env PATH="$narrow" bash "$PLUGIN_ROOT/scripts/resolve-config.sh" --format json --shared "$CONFIG"
  [ "$status" -ne 0 ]
  grep -qF 'yq is required for preflight_commands' <<< "$output"
}

@test "resolve-config.sh detects spaced key without yq (trailing space)" {
  [ -x "$(command -v jq)" ] || { echo "jq missing"; return 1; }
  printf 'preflight_commands :\n  - "make lint"\nproject_root: /tmp/t\nproject_path: /tmp/t\nmemory_path: /tmp/t\ncheckpoint_path: /tmp/t\ninstalled_path: /tmp/t\nframework_version: "1.0.0"\ndate: "2026-01-01"\n' > "$CONFIG"
  local narrow
  narrow="$(_build_no_yq_path)"
  run env PATH="$narrow" bash "$PLUGIN_ROOT/scripts/resolve-config.sh" --format json --shared "$CONFIG"
  [ "$status" -ne 0 ]
  grep -qF 'yq is required for preflight_commands' <<< "$output"
}

@test "resolve-config.sh detects single-quoted key without yq" {
  [ -x "$(command -v jq)" ] || { echo "jq missing"; return 1; }
  printf "'preflight_commands':\n  - \"make lint\"\nproject_root: /tmp/t\nproject_path: /tmp/t\nmemory_path: /tmp/t\ncheckpoint_path: /tmp/t\ninstalled_path: /tmp/t\nframework_version: \"1.0.0\"\ndate: \"2026-01-01\"\n" > "$CONFIG"
  local narrow
  narrow="$(_build_no_yq_path)"
  run env PATH="$narrow" bash "$PLUGIN_ROOT/scripts/resolve-config.sh" --format json --shared "$CONFIG"
  [ "$status" -ne 0 ]
  grep -qF 'yq is required for preflight_commands' <<< "$output"
}

# --- Runner: comment-only config without yq ---

@test "runner ignores comment-only key when yq absent" {
  [ -x "$(command -v jq)" ] || { echo "jq missing"; return 1; }
  cat > "$CONFIG" <<'YAML'
# preflight_commands disabled
YAML
  local narrow
  narrow="$(_build_no_yq_path)"
  run env PATH="$narrow" bash "$SCRIPT" --key preflight_commands --config "$CONFIG" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "runner halts on real key when yq absent" {
  [ -x "$(command -v jq)" ] || { echo "jq missing"; return 1; }
  cat > "$CONFIG" <<'YAML'
preflight_commands:
  - "true"
YAML
  local narrow
  narrow="$(_build_no_yq_path)"
  run env PATH="$narrow" bash "$SCRIPT" --key preflight_commands --config "$CONFIG" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  grep -qF 'yq is required for preflight_commands' <<< "$output"
}

@test "runner halts on double-quoted key when yq absent" {
  [ -x "$(command -v jq)" ] || { echo "jq missing"; return 1; }
  printf '"preflight_commands":\n  - "true"\n' > "$CONFIG"
  local narrow
  narrow="$(_build_no_yq_path)"
  run env PATH="$narrow" bash "$SCRIPT" --key preflight_commands --config "$CONFIG" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  grep -qF 'yq is required for preflight_commands' <<< "$output"
}

@test "runner halts on single-quoted key when yq absent" {
  [ -x "$(command -v jq)" ] || { echo "jq missing"; return 1; }
  printf "'preflight_commands':\n  - \"true\"\n" > "$CONFIG"
  local narrow
  narrow="$(_build_no_yq_path)"
  run env PATH="$narrow" bash "$SCRIPT" --key preflight_commands --config "$CONFIG" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  grep -qF 'yq is required for preflight_commands' <<< "$output"
}

@test "runner halts on spaced key when yq absent" {
  [ -x "$(command -v jq)" ] || { echo "jq missing"; return 1; }
  printf 'preflight_commands :\n  - "true"\n' > "$CONFIG"
  local narrow
  narrow="$(_build_no_yq_path)"
  run env PATH="$narrow" bash "$SCRIPT" --key preflight_commands --config "$CONFIG" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  grep -qF 'yq is required for preflight_commands' <<< "$output"
}
