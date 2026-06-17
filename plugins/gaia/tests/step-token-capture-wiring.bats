#!/usr/bin/env bats
# step-token-capture-wiring.bats — integration coverage for the producer->consumer
# wiring that connects the context-window snapshot (the number only statusline
# receives from the substrate) to emit-step-boundary's token payload.
#
# Background: the token-payload PLUMBING (emit-step-boundary --tokens) and the
# token-derivation CONSUMERS (throughput-telemetry --step-durations) already
# existed and were green, but nothing ever PRODUCED the snapshot during a real
# run, so every real step_boundary landed with timing only. These tests pin the
# missing wiring:
#   1. statusline.sh persists the latest cumulative snapshot to a reusable file.
#   2. emit-step-boundary.sh auto-reads that file when --tokens is not supplied.
#
# Covers:
#   A. statusline persists current_usage to the snapshot file (numeric subset only)
#   B. statusline never persists prompt/response text (allowlist on the producer)
#   C. statusline does not crash / still renders when current_usage is null
#   D. emit-step-boundary auto-captures the persisted snapshot (no --tokens)
#   E. explicit --tokens still wins over the persisted file (back-compat)
#   F. absent snapshot file -> graceful-skip (timing lands, no tokens_snapshot)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  STATUSLINE="$REPO_ROOT/plugins/gaia/scripts/statusline.sh"
  EMIT_HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-dev-story/scripts/emit-step-boundary.sh"

  TEST_TMP="$BATS_TEST_TMPDIR/wire-$$"
  mkdir -p "$TEST_TMP/.gaia/memory"
  # Minimal plugin.json so statusline's version resolution does not error out.
  mkdir -p "$TEST_TMP/gaia-public/plugins/gaia/.claude-plugin"
  cat > "$TEST_TMP/gaia-public/plugins/gaia/.claude-plugin/plugin.json" <<'PJ'
{ "name": "gaia", "version": "9.9.9-test" }
PJ
  export PROJECT_PATH="$TEST_TMP"
  SNAPSHOT_FILE="$TEST_TMP/.gaia/memory/.context-window-snapshot.json"
}

teardown() {
  rm -rf "$TEST_TMP" 2>/dev/null || true
}

_stdin_with_usage() {
  # $1 = used_percentage, $2 = current_usage JSON object (or "null")
  printf '{"model":{"id":"o","display_name":"Opus"},"workspace":{"current_dir":"%s"},"context_window":{"used_percentage":%s,"current_usage":%s,"context_window_size":1000000}}' \
    "$TEST_TMP" "$1" "$2"
}

# ---------- Scenario A: statusline PRODUCES the snapshot file ----------

@test "A: statusline persists current_usage to the snapshot file (numeric subset)" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  run bash -c "_stdin_with_usage() { printf '{\"model\":{\"id\":\"o\",\"display_name\":\"Opus\"},\"workspace\":{\"current_dir\":\"$TEST_TMP\"},\"context_window\":{\"used_percentage\":42,\"current_usage\":{\"input_tokens\":8200,\"output_tokens\":2400,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":100},\"context_window_size\":1000000}}'; }; _stdin_with_usage | bash '$STATUSLINE'"
  [ "$status" -eq 0 ]
  [ -f "$SNAPSHOT_FILE" ] \
    || { echo "snapshot file not written at $SNAPSHOT_FILE" >&2; ls -la "$TEST_TMP/.gaia/memory" >&2; false; }
  jq -e '.input_tokens == 8200' "$SNAPSHOT_FILE" >/dev/null \
    || { echo "input_tokens not persisted" >&2; cat "$SNAPSHOT_FILE" >&2; false; }
  jq -e '.output_tokens == 2400' "$SNAPSHOT_FILE" >/dev/null
  # All leaves numeric
  jq -e '[.. | scalars | type == "number"] | all' "$SNAPSHOT_FILE" >/dev/null \
    || { echo "non-numeric leaf in persisted snapshot" >&2; cat "$SNAPSHOT_FILE" >&2; false; }
}

# ---------- Scenario B: producer-side allowlist (privacy) ----------

@test "B: statusline never persists non-allowlisted keys from current_usage" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  # current_usage carries an extra non-allowlisted key with text — must be dropped
  local usage='{"input_tokens":100,"output_tokens":50,"sneaky":"prompt text"}'
  run bash -c "printf '{\"model\":{\"id\":\"o\",\"display_name\":\"Opus\"},\"workspace\":{\"current_dir\":\"$TEST_TMP\"},\"context_window\":{\"used_percentage\":10,\"current_usage\":$usage,\"context_window_size\":1000000}}' | bash '$STATUSLINE'"
  [ "$status" -eq 0 ]
  if [ -f "$SNAPSHOT_FILE" ]; then
    # If a file is written, it must NOT contain the smuggled key or its text.
    ! grep -qF "prompt text" "$SNAPSHOT_FILE" \
      || { echo "PRIVACY: smuggled text persisted to snapshot" >&2; cat "$SNAPSHOT_FILE" >&2; false; }
    ! jq -e 'has("sneaky")' "$SNAPSHOT_FILE" >/dev/null \
      || { echo "PRIVACY: non-allowlisted key persisted" >&2; cat "$SNAPSHOT_FILE" >&2; false; }
  fi
}

# ---------- Scenario C: null current_usage does not crash / no stale write ----------

@test "C: statusline with null current_usage still renders (no crash)" {
  run bash -c "printf '{\"model\":{\"id\":\"o\",\"display_name\":\"Opus\"},\"workspace\":{\"current_dir\":\"$TEST_TMP\"},\"context_window\":{\"used_percentage\":0,\"current_usage\":null}}' | bash '$STATUSLINE'"
  [ "$status" -eq 0 ]
}

# ---------- Scenario D: consumer AUTO-CAPTURES the persisted snapshot ----------

@test "D: emit-step-boundary auto-captures persisted snapshot when --tokens omitted" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  # Pre-seed a persisted snapshot (as statusline would have written it).
  printf '{"input_tokens":5000,"output_tokens":1200,"cache_creation_input_tokens":0,"cache_read_input_tokens":800}' > "$SNAPSHOT_FILE"
  export MEMORY_PATH="$TEST_TMP/.gaia/memory"
  # NOTE: no --tokens flag passed — the wiring must read the file.
  run bash "$EMIT_HELPER" 1 load-story E999-S1
  [ "$status" -eq 0 ]
  local line
  line=$(cat "$MEMORY_PATH/lifecycle-events.jsonl")
  echo "$line" | jq -e '.data.tokens_snapshot.input_tokens == 5000' >/dev/null \
    || { echo "auto-capture failed: tokens_snapshot not derived from file" >&2; echo "$line" >&2; false; }
  echo "$line" | jq -e '.data.tokens_snapshot.cache_read_input_tokens == 800' >/dev/null
}

# ---------- Scenario E: explicit --tokens wins over the persisted file ----------

@test "E: explicit --tokens overrides the persisted snapshot file" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  printf '{"input_tokens":5000,"output_tokens":1200}' > "$SNAPSHOT_FILE"
  export MEMORY_PATH="$TEST_TMP/.gaia/memory"
  run bash "$EMIT_HELPER" 1 load-story E999-S1 \
    --tokens '{"input_tokens":111,"output_tokens":222}'
  [ "$status" -eq 0 ]
  local line
  line=$(cat "$MEMORY_PATH/lifecycle-events.jsonl")
  echo "$line" | jq -e '.data.tokens_snapshot.input_tokens == 111' >/dev/null \
    || { echo "explicit --tokens did not win" >&2; echo "$line" >&2; false; }
}

# ---------- Scenario F: absent snapshot file -> graceful-skip ----------

@test "F: emit-step-boundary with no snapshot file and no --tokens lands timing-only" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  export MEMORY_PATH="$TEST_TMP/.gaia/memory"
  [ ! -f "$SNAPSHOT_FILE" ]
  run bash "$EMIT_HELPER" 1 load-story E999-S1
  [ "$status" -eq 0 ]
  local line
  line=$(cat "$MEMORY_PATH/lifecycle-events.jsonl")
  echo "$line" | jq -e '.data.step_name == "load-story"' >/dev/null
  local has_tokens
  has_tokens=$(echo "$line" | jq '.data | has("tokens_snapshot")')
  [ "$has_tokens" = "false" ] \
    || { echo "tokens_snapshot present with no file and no --tokens" >&2; echo "$line" >&2; false; }
}
