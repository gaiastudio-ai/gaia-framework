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
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT
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

# ---------- Scenario G: PROJECT_ROOT branch (MEMORY_PATH unset) ---------------
# Exercises: _CALLER_MEMORY_PATH empty -> PROJECT_ROOT non-empty -> snapshot at
# PROJECT_ROOT/.gaia/memory/. Seed via the real statusline writer.

@test "G: emitter resolves snapshot via PROJECT_ROOT when MEMORY_PATH is unset" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  # Produce the snapshot via the real statusline writer.
  local subdir="$TEST_TMP/sub/deep"
  mkdir -p "$subdir"
  printf '{"model":{"id":"o","display_name":"Opus"},"workspace":{"project_dir":"%s","current_dir":"%s"},"context_window":{"used_percentage":42,"current_usage":{"input_tokens":7777,"output_tokens":3333,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":1000000}}' \
    "$TEST_TMP" "$subdir" > "$TEST_TMP/.stdin.json"
  run bash "$STATUSLINE" < "$TEST_TMP/.stdin.json"
  [ "$status" -eq 0 ]
  [ -f "$SNAPSHOT_FILE" ] \
    || { echo "statusline did not write snapshot at project root" >&2; false; }
  # Emitter: MEMORY_PATH unset, only PROJECT_ROOT set. CWD is a directory
  # with no .gaia/ so the walk-up cannot find the root on its own — only the
  # explicit PROJECT_ROOT branch succeeds.
  local cwd_iso="$TEST_TMP/isolated-cwd"
  mkdir -p "$cwd_iso"
  unset MEMORY_PATH
  unset CLAUDE_PROJECT_ROOT
  export PROJECT_ROOT="$TEST_TMP"
  export GAIA_NO_PROJECT_WALKUP=1
  rm -f "$TEST_TMP/.gaia/memory/lifecycle-events.jsonl" 2>/dev/null || true
  run bash -c "cd '$cwd_iso' && bash '$EMIT_HELPER' 1 load-story E999-S1"
  [ "$status" -eq 0 ]
  local line
  line=$(cat "$TEST_TMP/.gaia/memory/lifecycle-events.jsonl")
  echo "$line" | jq -e '.data.tokens_snapshot.input_tokens == 7777' >/dev/null \
    || { echo "emitter did not read snapshot via PROJECT_ROOT" >&2; echo "$line" >&2; false; }
}

# ---------- Scenario H: CLAUDE_PROJECT_ROOT branch (PROJECT_ROOT also unset) --
# Exercises: _CALLER_MEMORY_PATH empty -> PROJECT_ROOT empty ->
# CLAUDE_PROJECT_ROOT non-empty. Seed via the real statusline writer.

@test "H: emitter resolves snapshot via CLAUDE_PROJECT_ROOT when PROJECT_ROOT is unset" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  # Produce the snapshot via the real statusline writer.
  printf '{"model":{"id":"o","display_name":"Opus"},"workspace":{"project_dir":"%s","current_dir":"%s"},"context_window":{"used_percentage":42,"current_usage":{"input_tokens":4444,"output_tokens":1111,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":1000000}}' \
    "$TEST_TMP" "$TEST_TMP" > "$TEST_TMP/.stdin.json"
  run bash "$STATUSLINE" < "$TEST_TMP/.stdin.json"
  [ "$status" -eq 0 ]
  [ -f "$SNAPSHOT_FILE" ] \
    || { echo "statusline did not write snapshot" >&2; false; }
  # Emitter: MEMORY_PATH unset, PROJECT_ROOT unset, only CLAUDE_PROJECT_ROOT.
  # CWD is isolated (no .gaia/ above it) so the walk-up cannot succeed — only
  # CLAUDE_PROJECT_ROOT resolves. Use BATS_TEST_TMPDIR as the isolated CWD
  # (parent of TEST_TMP, no .gaia/ at that level or above).
  # Also set PROJECT_PATH to a decoy worktree. If the emitter wrongly
  # prefers PROJECT_PATH over CLAUDE_PROJECT_ROOT, it reads the decoy
  # instead of the real root.
  local decoy_wt="$TEST_TMP/decoy-worktree"
  mkdir -p "$decoy_wt/.gaia/memory"
  printf '{"input_tokens":9999,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}' \
    > "$decoy_wt/.gaia/memory/.context-window-snapshot.json"
  unset MEMORY_PATH
  unset PROJECT_ROOT
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$decoy_wt"
  export GAIA_NO_PROJECT_WALKUP=1
  rm -f "$TEST_TMP/.gaia/memory/lifecycle-events.jsonl" 2>/dev/null || true
  run bash -c "cd '$BATS_TEST_TMPDIR' && bash '$EMIT_HELPER' 1 load-story E999-S1"
  [ "$status" -eq 0 ]
  local line
  line=$(cat "$TEST_TMP/.gaia/memory/lifecycle-events.jsonl")
  # Must read the real root snapshot (4444), not the decoy (9999).
  echo "$line" | jq -e '.data.tokens_snapshot.input_tokens == 4444' >/dev/null \
    || { echo "emitter did not read snapshot via CLAUDE_PROJECT_ROOT" >&2; echo "$line" >&2; false; }
}

# ---------- Scenario I: config-anchored walk-up (all explicit vars unset) -----
# Exercises: _CALLER_MEMORY_PATH empty -> PROJECT_ROOT empty ->
# CLAUDE_PROJECT_ROOT empty -> gaia-paths.sh walk-up from CWD.

@test "I: emitter resolves snapshot via config-anchored walk-up from subdirectory" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  # Seed the root snapshot via the real statusline writer.
  printf '{"model":{"id":"o","display_name":"Opus"},"workspace":{"project_dir":"%s","current_dir":"%s"},"context_window":{"used_percentage":42,"current_usage":{"input_tokens":6000,"output_tokens":2000,"cache_creation_input_tokens":0,"cache_read_input_tokens":500},"context_window_size":1000000}}' \
    "$TEST_TMP" "$TEST_TMP" > "$TEST_TMP/.stdin.json"
  run bash "$STATUSLINE" < "$TEST_TMP/.stdin.json"
  [ "$status" -eq 0 ]
  [ -f "$SNAPSHOT_FILE" ] \
    || { echo "statusline did not write snapshot" >&2; false; }
  # Create a config so the walk-up finds the root.
  mkdir -p "$TEST_TMP/.gaia/config"
  touch "$TEST_TMP/.gaia/config/project-config.yaml"
  # Subdirectory to cd into.
  local subdir="$TEST_TMP/src/deep"
  mkdir -p "$subdir"
  # Emitter: all explicit vars unset, CWD in subdirectory.
  unset MEMORY_PATH
  unset PROJECT_ROOT
  unset CLAUDE_PROJECT_ROOT
  unset PROJECT_PATH
  unset CLAUDE_SKILL_DIR
  unset _GAIA_PATHS_LOADED
  unset GAIA_NO_PROJECT_WALKUP
  rm -f "$TEST_TMP/.gaia/memory/lifecycle-events.jsonl" 2>/dev/null || true
  # HOME must encompass TEST_TMP so the walk-up boundary allows discovery.
  local home_canon; home_canon="$(cd "$TEST_TMP" && pwd -P)"
  run bash -c "HOME='$home_canon' && export HOME && cd '$subdir' && bash '$EMIT_HELPER' 1 load-story E999-S1"
  [ "$status" -eq 0 ]
  local line
  line=$(cat "$TEST_TMP/.gaia/memory/lifecycle-events.jsonl")
  echo "$line" | jq -e '.data.tokens_snapshot.input_tokens == 6000' >/dev/null \
    || { echo "emitter did not read snapshot via walk-up from subdirectory" >&2; echo "$line" >&2; false; }
}

# ---------- Scenario J: walk-up from nested config-less sub-repo --------------
# The walk-up must skip a bare .gaia/ (no project-config.yaml) and find the
# config-bearing root above it.

@test "J: emitter walk-up skips config-less nested sub-repo and finds root" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  # Seed the root snapshot via the real statusline writer.
  printf '{"model":{"id":"o","display_name":"Opus"},"workspace":{"project_dir":"%s","current_dir":"%s"},"context_window":{"used_percentage":42,"current_usage":{"input_tokens":9000,"output_tokens":3000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":1000000}}' \
    "$TEST_TMP" "$TEST_TMP" > "$TEST_TMP/.stdin.json"
  run bash "$STATUSLINE" < "$TEST_TMP/.stdin.json"
  [ "$status" -eq 0 ]
  [ -f "$SNAPSHOT_FILE" ] \
    || { echo "statusline did not write snapshot" >&2; false; }
  # Root has a config.
  mkdir -p "$TEST_TMP/.gaia/config"
  touch "$TEST_TMP/.gaia/config/project-config.yaml"
  # Nested sub-repo has bare .gaia/ but no config.
  local nested="$TEST_TMP/nested-repo"
  mkdir -p "$nested/.gaia/memory"
  # All explicit vars unset, CWD inside the nested sub-repo.
  unset MEMORY_PATH
  unset PROJECT_ROOT
  unset CLAUDE_PROJECT_ROOT
  unset PROJECT_PATH
  unset CLAUDE_SKILL_DIR
  unset _GAIA_PATHS_LOADED
  unset GAIA_NO_PROJECT_WALKUP
  rm -f "$TEST_TMP/.gaia/memory/lifecycle-events.jsonl" 2>/dev/null || true
  local home_canon; home_canon="$(cd "$TEST_TMP" && pwd -P)"
  run bash -c "HOME='$home_canon' && export HOME && cd '$nested' && bash '$EMIT_HELPER' 1 load-story E999-S1"
  [ "$status" -eq 0 ]
  local line
  line=$(cat "$TEST_TMP/.gaia/memory/lifecycle-events.jsonl")
  echo "$line" | jq -e '.data.tokens_snapshot.input_tokens == 9000' >/dev/null \
    || { echo "emitter walk-up did not skip config-less nested sub-repo" >&2; echo "$line" >&2; false; }
}

# ---------- Scenario J2: same as J but the nested sub-repo is a git init ------
# The walk-up must cross a regular git repo (not a linked worktree) to find
# the config-bearing root above it.

@test "J2: emitter walk-up crosses git-init sub-repo to find root" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  printf '{"model":{"id":"o","display_name":"Opus"},"workspace":{"project_dir":"%s","current_dir":"%s"},"context_window":{"used_percentage":42,"current_usage":{"input_tokens":8000,"output_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":1000000}}' \
    "$TEST_TMP" "$TEST_TMP" > "$TEST_TMP/.stdin.json"
  run bash "$STATUSLINE" < "$TEST_TMP/.stdin.json"
  [ "$status" -eq 0 ]
  [ -f "$SNAPSHOT_FILE" ] \
    || { echo "statusline did not write snapshot" >&2; false; }
  mkdir -p "$TEST_TMP/.gaia/config"
  touch "$TEST_TMP/.gaia/config/project-config.yaml"
  # Nested sub-repo is a real git repo with bare .gaia/ but no config.
  local nested="$TEST_TMP/git-subrepo"
  mkdir -p "$nested/.gaia/memory"
  git -C "$nested" init -q 2>/dev/null
  git -C "$nested" -c user.name=test -c user.email=test@test commit --allow-empty -m "init" -q 2>/dev/null
  unset MEMORY_PATH PROJECT_ROOT CLAUDE_PROJECT_ROOT PROJECT_PATH CLAUDE_SKILL_DIR _GAIA_PATHS_LOADED GAIA_NO_PROJECT_WALKUP
  rm -f "$TEST_TMP/.gaia/memory/lifecycle-events.jsonl" 2>/dev/null || true
  local home_canon; home_canon="$(cd "$TEST_TMP" && pwd -P)"
  run bash -c "HOME='$home_canon' && export HOME && cd '$nested' && bash '$EMIT_HELPER' 1 load-story test-story"
  [ "$status" -eq 0 ]
  local line
  line=$(cat "$TEST_TMP/.gaia/memory/lifecycle-events.jsonl")
  echo "$line" | jq -e '.data.tokens_snapshot.input_tokens == 8000' >/dev/null \
    || { echo "emitter walk-up did not cross git-init sub-repo" >&2; echo "$line" >&2; false; }
}

# ---------- Scenario K: MEMORY_PATH save/restore across exec boundary ---------
# The emitter must restore (or unset) MEMORY_PATH before exec'ing
# lifecycle-event.sh, so that script does not mkdir a stray .gaia/memory
# under whatever CWD it sees when CLAUDE_SKILL_DIR is set.

@test "K: emitter with CLAUDE_SKILL_DIR does not leak MEMORY_PATH to lifecycle-event" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  # Seed the root snapshot via the real statusline writer.
  printf '{"model":{"id":"o","display_name":"Opus"},"workspace":{"project_dir":"%s","current_dir":"%s"},"context_window":{"used_percentage":42,"current_usage":{"input_tokens":1234,"output_tokens":567,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"context_window_size":1000000}}' \
    "$TEST_TMP" "$TEST_TMP" > "$TEST_TMP/.stdin.json"
  run bash "$STATUSLINE" < "$TEST_TMP/.stdin.json"
  [ "$status" -eq 0 ]
  [ -f "$SNAPSHOT_FILE" ] \
    || { echo "statusline did not write snapshot" >&2; false; }
  # Emitter: MEMORY_PATH unset, PROJECT_ROOT set, CLAUDE_SKILL_DIR set.
  # CWD isolated, walk-up disabled — only PROJECT_ROOT resolves.
  local cwd_iso="$TEST_TMP/isolated-cwd"
  mkdir -p "$cwd_iso"
  unset MEMORY_PATH
  export CLAUDE_SKILL_DIR="$TEST_TMP/some-skill"
  mkdir -p "$CLAUDE_SKILL_DIR"
  export PROJECT_ROOT="$TEST_TMP"
  unset CLAUDE_PROJECT_ROOT
  export GAIA_NO_PROJECT_WALKUP=1
  rm -f "$TEST_TMP/.gaia/memory/lifecycle-events.jsonl" 2>/dev/null || true
  run bash -c "cd '$cwd_iso' && bash '$EMIT_HELPER' 1 load-story E999-S1"
  [ "$status" -eq 0 ]
  # CLAUDE_SKILL_DIR must NOT get a stray .gaia/memory.
  [ ! -d "$CLAUDE_SKILL_DIR/.gaia" ] \
    || { echo "stray .gaia/ created under CLAUDE_SKILL_DIR" >&2; false; }
  local line
  line=$(cat "$TEST_TMP/.gaia/memory/lifecycle-events.jsonl")
  echo "$line" | jq -e '.data.tokens_snapshot.input_tokens == 1234' >/dev/null \
    || { echo "emitter did not read snapshot with CLAUDE_SKILL_DIR set" >&2; echo "$line" >&2; false; }
}
