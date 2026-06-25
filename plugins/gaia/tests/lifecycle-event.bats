#!/usr/bin/env bats
# lifecycle-event.bats — unit tests for plugins/gaia/scripts/lifecycle-event.sh
# Public functions covered: iso_utc_now_ms, event_type_allowed,
# append_line, main.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/lifecycle-event.sh"
  export MEMORY_PATH="$TEST_TMP/_memory"
  JSONL="$MEMORY_PATH/lifecycle-events.jsonl"
}
teardown() { common_teardown; }

need_jq() {
  command -v jq >/dev/null 2>&1 || skip "jq not on PATH"
}

@test "lifecycle-event.sh: --help prints usage, exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *[Uu]sage* ]]
}

@test "lifecycle-event.sh: happy path emits one valid JSON line" {
  need_jq
  run "$SCRIPT" --type step_complete --workflow create-story
  [ "$status" -eq 0 ]
  [ -f "$JSONL" ]
  [ "$(wc -l < "$JSONL" | tr -d ' ')" = "1" ]
  run jq -e . "$JSONL"
  [ "$status" -eq 0 ]
}

@test "lifecycle-event.sh: full field event includes story_key/step/data" {
  need_jq
  run "$SCRIPT" --type gate_failed --workflow dev-story --story E1-S1 --step 7 --data '{"gate":"lint"}'
  [ "$status" -eq 0 ]
  line="$(tail -1 "$JSONL")"
  printf '%s' "$line" | jq -e '.event_type == "gate_failed" and .workflow == "dev-story" and .story_key == "E1-S1" and .step == 7 and .data.gate == "lint"' >/dev/null
}

@test "lifecycle-event.sh: timestamp is ISO 8601 UTC with ms precision" {
  need_jq
  "$SCRIPT" --type step_complete --workflow w
  local ts
  ts="$(jq -r .timestamp "$JSONL")"
  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$ ]]
}

@test "lifecycle-event.sh: missing --type → non-zero with usage hint" {
  run "$SCRIPT" --workflow create-story
  [ "$status" -ne 0 ]
  [[ "$output" == *[Tt]ype* ]]
}

@test "lifecycle-event.sh: malformed --data rejected, no partial append" {
  run "$SCRIPT" --type step_complete --workflow x --data 'not-json'
  [ "$status" -ne 0 ]
  [ ! -s "$JSONL" ] || [ "$(wc -l < "$JSONL" | tr -d ' ')" = "0" ]
}

@test "lifecycle-event.sh: event-types file rejects unknown type" {
  local f="$TEST_TMP/types.txt"
  printf 'step_complete\ngate_failed\n' > "$f"
  run "$SCRIPT" --type bogus --workflow x --event-types-file "$f"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bogus"* ]]
}

@test "lifecycle-event.sh: event-types file accepts known type" {
  local f="$TEST_TMP/types.txt"
  printf 'step_complete\n' > "$f"
  run "$SCRIPT" --type step_complete --workflow x --event-types-file "$f"
  [ "$status" -eq 0 ]
  [ -s "$JSONL" ]
}

@test "lifecycle-event.sh: 10 concurrent writes produce 10 valid lines" {
  need_jq
  seq 1 10 | xargs -P 10 -I {} "$SCRIPT" --type concurrent_test --workflow cw --step {}
  [ "$(wc -l < "$JSONL" | tr -d ' ')" = "10" ]
  while IFS= read -r l; do printf '%s' "$l" | jq -e . >/dev/null; done < "$JSONL"
}

@test "lifecycle-event.sh: JSONL created with 0644 permissions" {
  "$SCRIPT" --type step_complete --workflow w
  local mode
  if stat -f %Lp "$JSONL" >/dev/null 2>&1; then mode=$(stat -f %Lp "$JSONL")
  else mode=$(stat -c %a "$JSONL"); fi
  [ "$mode" = "644" ]
}

# ---------- Project-root-anchored MEMORY_PATH resolution ----------

# Helper: scaffold a minimal project fixture with enough config for
# resolve-config.sh to resolve project_root.
_scaffold_project_fixture() {
  local root="$1"
  mkdir -p "$root/.gaia/config"
  cat > "$root/.gaia/config/project-config.yaml" <<YAML
project_name: lifecycle-test
date: 2026-01-01
framework_version: "1.0.0"
installed_path: /tmp/gaia
project_path: $root
project_root: $root
YAML
}

@test "lifecycle-event.sh: unset MEMORY_PATH writes under project root, not CWD (AC1)" {
  need_jq
  # Set up a project root and a separate CWD — they must differ.
  local proj_root="$TEST_TMP/project"
  local other_cwd="$TEST_TMP/elsewhere"
  mkdir -p "$proj_root" "$other_cwd"
  _scaffold_project_fixture "$proj_root"

  # Unset MEMORY_PATH so the default-resolution branch fires.
  unset MEMORY_PATH

  # Point the resolver at our project root.
  export CLAUDE_PROJECT_ROOT="$proj_root"

  # Run from a DIFFERENT directory.
  run bash -c "cd '$other_cwd' && '$SCRIPT' --type step_complete --workflow mem-test"
  [ "$status" -eq 0 ]

  # Event must land under the project root's .gaia/memory/, not under CWD.
  [ -f "$proj_root/.gaia/memory/lifecycle-events.jsonl" ]

  # Must NOT exist under the CWD.
  [ ! -f "$other_cwd/.gaia/memory/lifecycle-events.jsonl" ]
}

@test "lifecycle-event.sh: explicit MEMORY_PATH wins over project-root resolution (AC2)" {
  need_jq
  local custom_mem="$TEST_TMP/custom-mem"
  mkdir -p "$custom_mem"
  export MEMORY_PATH="$custom_mem"

  run "$SCRIPT" --type step_complete --workflow explicit-test
  [ "$status" -eq 0 ]
  [ -f "$custom_mem/lifecycle-events.jsonl" ]
}

@test "lifecycle-event.sh: config memory_path override honored when env unset (AC4)" {
  need_jq
  # Scaffold a project whose config sets a CUSTOM memory_path that differs
  # from the default {project_root}/.gaia/memory.
  local proj_root="$TEST_TMP/proj-custom-mem"
  local custom_mem="$TEST_TMP/custom-mem-dir"
  mkdir -p "$proj_root/.gaia/config" "$custom_mem"

  cat > "$proj_root/.gaia/config/project-config.yaml" <<YAML
project_name: custom-mem-test
date: 2026-01-01
framework_version: "1.0.0"
installed_path: /tmp/gaia
project_path: $proj_root
project_root: $proj_root
memory_path: $custom_mem
YAML

  # Unset MEMORY_PATH so the resolve-from-config branch fires.
  unset MEMORY_PATH
  export CLAUDE_PROJECT_ROOT="$proj_root"

  run bash -c "cd '$proj_root' && '$SCRIPT' --type step_complete --workflow mem-override-test"
  [ "$status" -eq 0 ]

  # Event MUST land under the config-specified custom_mem, NOT project_root/.gaia/memory.
  [ -f "$custom_mem/lifecycle-events.jsonl" ]

  # Must NOT exist under the default location.
  [ ! -f "$proj_root/.gaia/memory/lifecycle-events.jsonl" ]
}

@test "lifecycle-event.sh: resolver failure degrades gracefully, never aborts (AC3)" {
  need_jq
  # Unset MEMORY_PATH so the default-resolution branch fires.
  unset MEMORY_PATH
  # Set a project root that has NO config — resolver will fail.
  local bare_root="$TEST_TMP/bare"
  mkdir -p "$bare_root"
  export CLAUDE_PROJECT_ROOT="$bare_root"

  # The script must still exit 0 (best-effort contract) and write SOMEWHERE.
  run bash -c "cd '$bare_root' && '$SCRIPT' --type step_complete --workflow fallback-test"
  [ "$status" -eq 0 ]

  # It should have written the JSONL under the fallback .gaia/memory/ relative
  # to SOME base (bare_root CWD fallback or project root).
  local found=0
  if [ -f "$bare_root/.gaia/memory/lifecycle-events.jsonl" ]; then found=1; fi
  [ "$found" -eq 1 ]
}
