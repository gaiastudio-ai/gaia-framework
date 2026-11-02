#!/usr/bin/env bats
# post-ci-smoke.bats — additional tests: smoke runner, hydration,
# doctor listing, readiness, and dev-story wiring.

load 'test_helper.bash'

setup() {
  export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
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
  # Third command must not appear.
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
  # The JSON must contain the preflight_commands array.
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
  # Must NOT contain preflight_commands or post_ci_smoke_commands.
  local has_pre has_post
  has_pre="$(echo "$output" | jq 'has("preflight_commands")')"
  has_post="$(echo "$output" | jq 'has("post_ci_smoke_commands")')"
  [ "$has_pre" = "false" ]
  [ "$has_post" = "false" ]
}

# --- Doctor and readiness tests ---

@test "doctor SKILL.md contains configured command listing step" {
  grep -q 'preflight_commands' "$PLUGIN_ROOT/skills/gaia-doctor/SKILL.md"
  grep -q 'post_ci_smoke_commands' "$PLUGIN_ROOT/skills/gaia-doctor/SKILL.md"
}

@test "readiness SKILL.md contains empty-string validation step" {
  grep -q 'empty.string' "$PLUGIN_ROOT/skills/gaia-readiness-check/SKILL.md" || \
    grep -q 'empty-string' "$PLUGIN_ROOT/skills/gaia-readiness-check/SKILL.md" || \
    grep -qi 'empty.*entry\|empty.*command' "$PLUGIN_ROOT/skills/gaia-readiness-check/SKILL.md"
}

# --- Dev-story SKILL.md wiring ---

@test "preflight gate is inside Step 10 markers before git-push.sh" {
  local skill="$PLUGIN_ROOT/skills/gaia-dev-story/SKILL.md"
  # Extract the Step 10 block (between the markers).
  local block
  block="$(sed -n '/<!-- step 10 git-push wire begin -->/,/<!-- step 10 git-push wire end -->/p' "$skill")"
  # The preflight gate must appear in the block.
  grep -q 'run-configured-commands.sh' <<< "$block"
  grep -q 'preflight_commands' <<< "$block"
  # The preflight gate must appear BEFORE git-push.sh in the block.
  local preflight_line push_line
  preflight_line="$(grep -n 'preflight_commands' <<< "$block" | head -1 | cut -d: -f1)"
  push_line="$(grep -n 'git-push.sh' <<< "$block" | head -1 | cut -d: -f1)"
  [ -n "$preflight_line" ]
  [ -n "$push_line" ]
  [ "$preflight_line" -lt "$push_line" ]
}

@test "smoke hook is between Step 12 and Step 13 in dev-story SKILL.md" {
  local skill="$PLUGIN_ROOT/skills/gaia-dev-story/SKILL.md"
  # The smoke block must appear after "Step 12" header and before "Step 13" header.
  local step12_line step13_line smoke_line
  step12_line="$(grep -n '### Step 12' "$skill" | head -1 | cut -d: -f1)"
  step13_line="$(grep -n '### Step 13' "$skill" | head -1 | cut -d: -f1)"
  smoke_line="$(grep -n 'post_ci_smoke_commands' "$skill" | head -1 | cut -d: -f1)"
  [ -n "$step12_line" ]
  [ -n "$step13_line" ]
  [ -n "$smoke_line" ]
  [ "$smoke_line" -gt "$step12_line" ]
  [ "$smoke_line" -lt "$step13_line" ]
}

@test "removing preflight block from Step 10 would lose run-configured-commands" {
  local skill="$PLUGIN_ROOT/skills/gaia-dev-story/SKILL.md"
  # Both the runner reference and the preflight key must be inside step 10.
  local block
  block="$(sed -n '/<!-- step 10 git-push wire begin -->/,/<!-- step 10 git-push wire end -->/p' "$skill")"
  grep -q 'run-configured-commands.sh' <<< "$block"
  grep -q 'preflight_commands' <<< "$block"
}

@test "removing smoke block would lose post_ci_smoke reference" {
  local skill="$PLUGIN_ROOT/skills/gaia-dev-story/SKILL.md"
  # Both the runner reference and the smoke key must exist between Steps 12-13.
  local between
  between="$(sed -n '/### Step 12/,/### Step 13/p' "$skill")"
  grep -q 'run-configured-commands.sh' <<< "$between"
  grep -q 'post_ci_smoke_commands' <<< "$between"
}
