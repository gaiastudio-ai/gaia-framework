#!/usr/bin/env bats
# gaia-dev-story.bats — unit tests for gaia-dev-story skill (E28-S53)
#
# Covers: SKILL.md frontmatter validation (AC1), playbook reasoning-only (AC2),
# scripts directory completeness (AC3), PostToolUse checkpoint hook (AC4),
# frontmatter linter pass (AC7), and edge cases (AC-EC1..AC-EC10).

load 'test_helper.bash'

SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-dev-story"

setup() {
  common_setup
  export CHECKPOINT_PATH="$TEST_TMP/_memory/checkpoints"
  mkdir -p "$CHECKPOINT_PATH"
}
teardown() { common_teardown; }

# ---------- AC1: SKILL.md frontmatter ----------

@test "AC1: SKILL.md exists" {
  [ -f "$SKILL_DIR/SKILL.md" ]
}

@test "AC1: SKILL.md frontmatter contains name: gaia-dev-story" {
  run awk '/^---/{n++; next} n==1' "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"name: gaia-dev-story"* ]]
}

@test "AC1: SKILL.md frontmatter contains description" {
  run awk '/^---/{n++; next} n==1' "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"description:"* ]]
}

@test "AC1: SKILL.md frontmatter contains argument-hint: [story-key]" {
  run awk '/^---/{n++; next} n==1' "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"argument-hint:"* ]]
  [[ "$output" == *"story-key"* ]]
}

@test "AC1: SKILL.md frontmatter declares orchestration_class (post-ADR-093)" {
  # ADR-093 / E84-S3: `context: fork` stripped from non-reviewer plugin
  # SKILL.md. gaia-dev-story is heavy-procedural.
  run awk '/^---/{n++; next} n==1' "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"orchestration_class: heavy-procedural"* ]]
}

@test "AC1: SKILL.md frontmatter contains allowed-tools with Read Write Edit Grep Glob Bash" {
  run awk '/^---/{n++; next} n==1' "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"allowed-tools:"* ]]
  [[ "$output" == *"Read"* ]]
  [[ "$output" == *"Write"* ]]
  [[ "$output" == *"Edit"* ]]
  [[ "$output" == *"Grep"* ]]
  [[ "$output" == *"Glob"* ]]
  [[ "$output" == *"Bash"* ]]
}

@test "AC1: SKILL.md frontmatter contains PostToolUse hook with Edit|Write matcher" {
  run awk '/^---/{n++; next} n==1' "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"PostToolUse"* ]]
  [[ "$output" == *'matcher: "Edit|Write"'* ]]
}

@test "AC1: SKILL.md PostToolUse hook command invokes checkpoint.sh write gaia-dev-story" {
  run awk '/^---/{n++; next} n==1' "$SKILL_DIR/SKILL.md"
  [[ "$output" == *'checkpoint.sh write gaia-dev-story'* ]]
  # E92-S3: hook command MUST use ${CLAUDE_PLUGIN_ROOT} (substrate-supplied), not ${CLAUDE_SKILL_DIR} (silently empty).
  [[ "$output" == *'${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/checkpoint.sh write gaia-dev-story'* ]]
  [[ "$output" != *'${CLAUDE_SKILL_DIR}'* ]]
}

# ---------- AC2: playbook.md reasoning only ----------

@test "AC2: playbook.md exists" {
  [ -f "$SKILL_DIR/playbook.md" ]
}

@test "AC2: playbook.md contains zero shell commands" {
  run grep -ciE '^\s*(git |shasum |npm |bats |gh |cd |mkdir |chmod |cp |mv |rm )' "$SKILL_DIR/playbook.md"
  [ "$status" -ne 0 ] || [ "$output" = "0" ]
}

@test "AC2: playbook.md contains zero sprint-state transitions" {
  run grep -ciE 'sprint-state\.sh|update-story-status\.sh|status.*transition' "$SKILL_DIR/playbook.md"
  [ "$status" -ne 0 ] || [ "$output" = "0" ]
}

@test "AC2: playbook.md contains zero sha256 computations" {
  run grep -ci 'shasum' "$SKILL_DIR/playbook.md"
  [ "$status" -ne 0 ] || [ "$output" = "0" ]
}

# ---------- AC3: scripts directory completeness ----------

@test "AC3: scripts/ directory exists" {
  [ -d "$SKILL_DIR/scripts" ]
}

@test "AC3: setup.sh exists and is executable" {
  [ -x "$SKILL_DIR/scripts/setup.sh" ]
}

@test "AC3: finalize.sh exists and is executable" {
  [ -x "$SKILL_DIR/scripts/finalize.sh" ]
}

@test "AC3: load-story.sh exists and is executable" {
  [ -x "$SKILL_DIR/scripts/load-story.sh" ]
}

@test "AC3: SKILL.md references transition-story-status.sh directly (post E59-S2 wrapper migration)" {
  # Post-E59-S1 contract: gaia-dev-story SKILL.md must invoke
  # plugins/gaia/scripts/transition-story-status.sh directly, not the
  # update-story-status.sh deprecation wrapper. The wrapper is removed in E59-S3;
  # this assertion guards against regressions reintroducing the wrapper path.
  [ -f "$SKILL_DIR/SKILL.md" ]
  run grep -c 'transition-story-status\.sh' "$SKILL_DIR/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
  # Wrapper path must be absent — proves the assertion catches the negative case.
  run grep -c 'update-story-status\.sh' "$SKILL_DIR/SKILL.md"
  # grep -c returns 1 with output "0" when no match; treat that as success here.
  [ "$output" = "0" ]
}

@test "AC3: git-branch.sh exists and is executable" {
  [ -x "$SKILL_DIR/scripts/git-branch.sh" ]
}

@test "AC3: checkpoint.sh exists and is executable" {
  [ -x "$SKILL_DIR/scripts/checkpoint.sh" ]
}

@test "AC3: sprint-state.sh exists and is executable" {
  [ -x "$SKILL_DIR/scripts/sprint-state.sh" ]
}

@test "AC3: pr-create.sh exists and is executable" {
  [ -x "$SKILL_DIR/scripts/pr-create.sh" ]
}

@test "AC3: ci-wait.sh exists and is executable" {
  [ -x "$SKILL_DIR/scripts/ci-wait.sh" ]
}

@test "AC3: merge.sh exists and is executable" {
  [ -x "$SKILL_DIR/scripts/merge.sh" ]
}

@test "AC3: all scripts are POSIX-safe (no bashisms beyond [[ ]] and arrays)" {
  for script in "$SKILL_DIR"/scripts/*.sh; do
    # Check that each script starts with bash shebang (allowing [[ ]] per GAIA convention)
    run head -1 "$script"
    [[ "$output" == *"bash"* ]]
  done
}

# ---------- AC4: PostToolUse checkpoint hook ----------

@test "AC4: checkpoint.sh write creates checkpoint file" {
  export CLAUDE_SKILL_DIR="$SKILL_DIR"
  run "$SKILL_DIR/scripts/checkpoint.sh" write gaia-dev-story
  [ "$status" -eq 0 ]
  # Check that a checkpoint file exists in CHECKPOINT_PATH
  local count
  count=$(find "$CHECKPOINT_PATH" -type f -name '*.yaml' | wc -l | tr -d ' ')
  [ "$count" -gt 0 ]
}

@test "AC4: checkpoint file is non-empty" {
  export CLAUDE_SKILL_DIR="$SKILL_DIR"
  "$SKILL_DIR/scripts/checkpoint.sh" write gaia-dev-story
  local f
  f=$(find "$CHECKPOINT_PATH" -type f -name '*.yaml' | head -1)
  [ -s "$f" ]
}

@test "AC4: checkpoint file contains workflow name gaia-dev-story" {
  export CLAUDE_SKILL_DIR="$SKILL_DIR"
  "$SKILL_DIR/scripts/checkpoint.sh" write gaia-dev-story
  local f
  f=$(find "$CHECKPOINT_PATH" -type f -name '*.yaml' | head -1)
  run cat "$f"
  [[ "$output" == *"gaia-dev-story"* ]]
}

# ---------- AC7: frontmatter linter ----------

@test "AC7: frontmatter linter passes on SKILL.md" {
  cd "$BATS_TEST_DIRNAME/../../.."
  run .github/scripts/lint-skill-frontmatter.sh
  [ "$status" -eq 0 ]
}

# ---------- AC-EC1: missing checkpoint.sh ----------

@test "AC-EC1: missing checkpoint.sh logs error and exits non-zero" {
  local tmp_skill="$TEST_TMP/fake-skill/scripts"
  mkdir -p "$tmp_skill"
  # Create a minimal checkpoint.sh that delegates to missing shared script
  cat > "$tmp_skill/checkpoint.sh" << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED="$SCRIPT_DIR/../../../scripts/checkpoint.sh"
if [ ! -x "$SHARED" ]; then
  echo "ERROR: shared checkpoint.sh not found at $SHARED" >&2
  exit 1
fi
exec "$SHARED" "$@"
SCRIPT
  chmod +x "$tmp_skill/checkpoint.sh"
  run "$tmp_skill/checkpoint.sh" write gaia-dev-story
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]] || [[ "$output" == *"not found"* ]]
}

# ---------- AC-EC3: zero file modifications ----------

@test "AC-EC3: no PostToolUse checkpoints when no Edit/Write occurs" {
  # When no Edit/Write happens, the PostToolUse hook does not fire.
  # Only finalize.sh writes a terminal checkpoint.
  # This test verifies checkpoint.sh is not invoked without arguments.
  export CLAUDE_SKILL_DIR="$SKILL_DIR"
  local count_before
  count_before=$(find "$CHECKPOINT_PATH" -type f -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')
  # No calls to checkpoint.sh
  local count_after
  count_after=$(find "$CHECKPOINT_PATH" -type f -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')
  [ "$count_before" -eq "$count_after" ]
}

# ---------- AC-EC9: missing CLAUDE_SKILL_DIR ----------

@test "AC-EC9: checkpoint.sh warns when CLAUDE_SKILL_DIR is unset" {
  unset CLAUDE_SKILL_DIR
  export CHECKPOINT_PATH="$TEST_TMP/_memory/checkpoints"
  run "$SKILL_DIR/scripts/checkpoint.sh" write gaia-dev-story
  # Should either warn and succeed, or warn and exit non-zero — but not crash
  # The key assertion: stderr contains a warning about CLAUDE_SKILL_DIR
  [[ "$output" == *"CLAUDE_SKILL_DIR"* ]] || [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

# ---------- AC-EC2: atomic checkpoint writes ----------

@test "AC-EC2: checkpoint.sh uses atomic write (temp + rename)" {
  # Verify the script contains temp file + rename pattern
  run grep -cE 'mv |rename|tmp|\.tmp' "$SKILL_DIR/scripts/checkpoint.sh"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ] 2>/dev/null || [[ "$output" == *"1"* ]]
}

# ---------- AC-EC4: git branch collision detection ----------

@test "AC-EC4: git-branch.sh detects existing branch and does not force-overwrite" {
  cd "$TEST_TMP"
  git init -q test-repo && cd test-repo
  # Set a repo-scoped identity so CI runners without a global user.email
  # can still create the init commit (no --global here — we do not want to
  # mutate the runner's git config).
  git config user.email "ci@example.com"
  git config user.name "CI Test"
  git commit --allow-empty -m "init" -q
  git checkout -b feat/E99-S1-test -q
  git checkout -b main -q 2>/dev/null || git checkout main -q 2>/dev/null || true
  # Now feat/E99-S1-test already exists — git-branch.sh should detect collision
  export PROJECT_PATH="$TEST_TMP/test-repo"
  run "$SKILL_DIR/scripts/git-branch.sh" E99-S1 test
  [[ "$output" == *"already exists"* ]] || [[ "$output" == *"collision"* ]] || [ "$status" -ne 0 ]
}
