#!/usr/bin/env bats
# statusline-toggle.bats — coverage for gaia-statusline-toggle.sh and the
# /gaia-statusline-enable / /gaia-statusline-disable wrapper skills.
#
# Story: E82-S3.
#
# Covers TC-STATUSLINE-13 (idempotent enable/disable) and
# TC-STATUSLINE-14 (round-trip enable+disable preserves byte-identity).

load '../test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TOGGLE="$PLUGIN_ROOT/scripts/gaia-statusline-toggle.sh"
  cd "$TEST_TMP"
  # Sandbox the install destination.
  export HOME="$TEST_TMP/home"
  mkdir -p "$HOME/.claude/gaia-statusline"
  # Provide the runtime stub so the enable pre-flight passes.
  cat > "$HOME/.claude/gaia-statusline/statusline.sh" <<'STUB'
#!/usr/bin/env bash
echo "stub statusline"
STUB
  chmod +x "$HOME/.claude/gaia-statusline/statusline.sh"
}

teardown() { common_teardown; }

# Helper — write a canonical settings.json (sorted keys, 2-space indent).
write_settings() {
  printf '%s\n' "$1" | jq -S '.' > "$HOME/.claude/settings.json"
}

# ---------------------------------------------------------------------------
# Toggle script existence + executability
# ---------------------------------------------------------------------------

@test "toggle script exists and is executable" {
  [ -x "$TOGGLE" ]
}

@test "toggle script rejects unknown mode" {
  run bash "$TOGGLE" --bogus
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC1 — enable on file with no statusLine block adds the canonical block
#       and preserves all unrelated top-level keys
# ---------------------------------------------------------------------------

@test "AC1: enable adds statusLine block to settings.json without existing block" {
  write_settings '{"theme": "dark", "model": "opus"}'
  run bash "$TOGGLE" --enable
  [ "$status" -eq 0 ]
  # statusLine block exists and points at the canonical runtime path.
  expected_cmd="$HOME/.claude/gaia-statusline/statusline.sh"
  [ "$(jq -r '.statusLine.command' "$HOME/.claude/settings.json")" = "$expected_cmd" ]
  [ "$(jq -r '.statusLine.refreshInterval' "$HOME/.claude/settings.json")" = "3600000" ]
  # Unrelated keys preserved.
  [ "$(jq -r '.theme' "$HOME/.claude/settings.json")" = "dark" ]
  [ "$(jq -r '.model' "$HOME/.claude/settings.json")" = "opus" ]
}

@test "AC1: enable seeds settings.json when file is absent" {
  rm -f "$HOME/.claude/settings.json"
  run bash "$TOGGLE" --enable
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/settings.json" ]
  jq -e '.statusLine.command' "$HOME/.claude/settings.json"
}

# ---------------------------------------------------------------------------
# AC2 / TC-STATUSLINE-13 — enable is idempotent on already-enabled file
# ---------------------------------------------------------------------------

@test "AC2 / TC-13: enable is idempotent when statusLine already canonical" {
  bash "$TOGGLE" --enable
  cp "$HOME/.claude/settings.json" "$TEST_TMP/before.json"
  before_mtime="$(stat -f '%m' "$HOME/.claude/settings.json" 2>/dev/null || stat -c '%Y' "$HOME/.claude/settings.json")"
  sleep 1
  run bash "$TOGGLE" --enable
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "no-op (already enabled)"
  diff "$TEST_TMP/before.json" "$HOME/.claude/settings.json"
  after_mtime="$(stat -f '%m' "$HOME/.claude/settings.json" 2>/dev/null || stat -c '%Y' "$HOME/.claude/settings.json")"
  [ "$before_mtime" = "$after_mtime" ]
}

# ---------------------------------------------------------------------------
# AC3 — disable removes statusLine block, preserves unrelated keys
# ---------------------------------------------------------------------------

@test "AC3: disable removes statusLine block and preserves unrelated keys" {
  bash "$TOGGLE" --enable
  # Add unrelated keys post-enable to verify they survive disable.
  jq '. + {theme: "dark", model: "opus"}' "$HOME/.claude/settings.json" > "$TEST_TMP/with-keys.json"
  mv "$TEST_TMP/with-keys.json" "$HOME/.claude/settings.json"
  run bash "$TOGGLE" --disable
  [ "$status" -eq 0 ]
  # statusLine removed.
  [ "$(jq -r '.statusLine // "missing"' "$HOME/.claude/settings.json")" = "missing" ]
  # Unrelated keys preserved.
  [ "$(jq -r '.theme' "$HOME/.claude/settings.json")" = "dark" ]
  [ "$(jq -r '.model' "$HOME/.claude/settings.json")" = "opus" ]
}

# ---------------------------------------------------------------------------
# AC4 — disable is idempotent on file with no statusLine block
# ---------------------------------------------------------------------------

@test "AC4: disable is idempotent when no statusLine block present" {
  write_settings '{"theme": "dark"}'
  cp "$HOME/.claude/settings.json" "$TEST_TMP/before.json"
  before_mtime="$(stat -f '%m' "$HOME/.claude/settings.json" 2>/dev/null || stat -c '%Y' "$HOME/.claude/settings.json")"
  sleep 1
  run bash "$TOGGLE" --disable
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "no-op (already disabled)"
  diff "$TEST_TMP/before.json" "$HOME/.claude/settings.json"
  after_mtime="$(stat -f '%m' "$HOME/.claude/settings.json" 2>/dev/null || stat -c '%Y' "$HOME/.claude/settings.json")"
  [ "$before_mtime" = "$after_mtime" ]
}

@test "AC4: disable is idempotent when settings.json is absent" {
  rm -f "$HOME/.claude/settings.json"
  run bash "$TOGGLE" --disable
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "no-op (already disabled)"
  [ ! -f "$HOME/.claude/settings.json" ]
}

# ---------------------------------------------------------------------------
# AC5 / TC-STATUSLINE-14 — round-trip enable + disable preserves byte-identity
# ---------------------------------------------------------------------------

@test "AC5 / TC-14: round-trip enable+disable preserves byte-identity" {
  # Starting file is in canonical jq format (sorted keys, 2-space indent)
  # so the round-trip can preserve byte-for-byte.
  write_settings '{"theme": "dark", "model": "opus", "hooks": {"PostToolUse": [{"matcher": "Edit"}]}}'
  cp "$HOME/.claude/settings.json" "$TEST_TMP/original.json"
  bash "$TOGGLE" --enable
  bash "$TOGGLE" --disable
  diff "$TEST_TMP/original.json" "$HOME/.claude/settings.json"
}

@test "AC5: round-trip on file with arbitrary key set" {
  write_settings '{"a": 1, "b": [1, 2, 3], "c": {"nested": true}, "z": "last"}'
  cp "$HOME/.claude/settings.json" "$TEST_TMP/original.json"
  bash "$TOGGLE" --enable
  bash "$TOGGLE" --disable
  diff "$TEST_TMP/original.json" "$HOME/.claude/settings.json"
}

# ---------------------------------------------------------------------------
# AC6 — atomic write via sibling-tempfile + mv (no /tmp/ usage)
# ---------------------------------------------------------------------------

@test "AC6: toggle uses sibling-tempfile (no /tmp/ atomic-rename)" {
  [ -f "$TOGGLE" ]
  ! grep -E 'mktemp[[:space:]]+(/tmp|--tmpdir=/tmp)' "$TOGGLE"
}

@test "AC6: toggle script never writes to /tmp/ (non-comment lines)" {
  # Strip comment-only lines (leading whitespace + #) before scanning so
  # documentation that mentions "Never /tmp/" doesn't false-positive.
  ! grep -vE '^[[:space:]]*#' "$TOGGLE" | grep -E '/tmp/[A-Za-z0-9_.-]*'
}

# ---------------------------------------------------------------------------
# AC7 — enable refuses when runtime missing and points at install-statusline.sh
# ---------------------------------------------------------------------------

@test "AC7: enable fails when runtime statusline.sh missing" {
  rm -f "$HOME/.claude/gaia-statusline/statusline.sh"
  write_settings '{"theme": "dark"}'
  cp "$HOME/.claude/settings.json" "$TEST_TMP/before.json"
  # Capture combined stdout+stderr via a subshell wrapper so both streams
  # are visible to grep.
  run bash -c "bash '$TOGGLE' --enable 2>&1"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "install-statusline.sh"
  # settings.json unmodified.
  diff "$TEST_TMP/before.json" "$HOME/.claude/settings.json"
}

# ---------------------------------------------------------------------------
# AC8 — malformed JSON: refuse with clear error, file unmodified
# ---------------------------------------------------------------------------

@test "AC8: enable refuses on malformed settings.json" {
  [ -x "$TOGGLE" ]
  printf '{ this is not json' > "$HOME/.claude/settings.json"
  cp "$HOME/.claude/settings.json" "$TEST_TMP/before.json"
  run bash -c "bash '$TOGGLE' --enable 2>&1"
  [ "$status" -ne 0 ]
  # Error message must reference settings.json or "malformed"/"invalid".
  echo "$output" | grep -qiE "malformed|invalid|settings"
  diff "$TEST_TMP/before.json" "$HOME/.claude/settings.json"
}

@test "AC8: disable refuses on malformed settings.json" {
  [ -x "$TOGGLE" ]
  printf '{ this is not json' > "$HOME/.claude/settings.json"
  cp "$HOME/.claude/settings.json" "$TEST_TMP/before.json"
  run bash -c "bash '$TOGGLE' --disable 2>&1"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qiE "malformed|invalid|settings"
  diff "$TEST_TMP/before.json" "$HOME/.claude/settings.json"
}

# ---------------------------------------------------------------------------
# Wrapper SKILL.md files exist
# ---------------------------------------------------------------------------

@test "enable wrapper SKILL.md exists" {
  [ -f "$PLUGIN_ROOT/skills/gaia-statusline-enable/SKILL.md" ]
}

@test "disable wrapper SKILL.md exists" {
  [ -f "$PLUGIN_ROOT/skills/gaia-statusline-disable/SKILL.md" ]
}

@test "enable wrapper references the toggle script" {
  grep -q 'gaia-statusline-toggle.sh' "$PLUGIN_ROOT/skills/gaia-statusline-enable/SKILL.md"
  grep -q -- '--enable' "$PLUGIN_ROOT/skills/gaia-statusline-enable/SKILL.md"
}

@test "disable wrapper references the toggle script" {
  grep -q 'gaia-statusline-toggle.sh' "$PLUGIN_ROOT/skills/gaia-statusline-disable/SKILL.md"
  grep -q -- '--disable' "$PLUGIN_ROOT/skills/gaia-statusline-disable/SKILL.md"
}
