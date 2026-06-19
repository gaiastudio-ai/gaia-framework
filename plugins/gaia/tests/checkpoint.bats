#!/usr/bin/env bats
# checkpoint.bats — unit tests for plugins/gaia/scripts/checkpoint.sh
# Public functions covered: iso_utc_now, file_mtime_utc, file_sha256,
# validate_workflow_name, yaml_scalar, resolve_checkpoint_path, cmd_write,
# cmd_read, parse_files_touched, cmd_validate, main.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/checkpoint.sh"
  export CHECKPOINT_PATH="$TEST_TMP/_memory/checkpoints"
  mkdir -p "$CHECKPOINT_PATH"
}
teardown() { common_teardown; }

@test "checkpoint.sh: --help exits 0 and lists subcommands" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"write"* ]]
  [[ "$output" == *"read"* ]]
  [[ "$output" == *"validate"* ]]
}

@test "checkpoint.sh: write happy path — writes yaml file" {
  run "$SCRIPT" write --workflow dev-story --step 3 --var story_key=E1-S1
  [ "$status" -eq 0 ]
  [ -f "$CHECKPOINT_PATH/dev-story.yaml" ]
  run cat "$CHECKPOINT_PATH/dev-story.yaml"
  [[ "$output" == *"workflow: dev-story"* ]]
  [[ "$output" == *"step: 3"* ]]
}

@test "checkpoint.sh: write then read round-trips content" {
  "$SCRIPT" write --workflow w1 --step 1
  run "$SCRIPT" read --workflow w1
  [ "$status" -eq 0 ]
  [[ "$output" == *"w1"* ]]
}

@test "checkpoint.sh: read missing checkpoint → exit 2" {
  run "$SCRIPT" read --workflow nope
  [ "$status" -eq 2 ]
}

@test "checkpoint.sh: write rejects malformed workflow name" {
  run "$SCRIPT" write --workflow "../evil" --step 1
  [ "$status" -ne 0 ]
}

@test "checkpoint.sh: write with --file records sha256 in files_touched" {
  local f="$TEST_TMP/touched.txt"
  printf "hello\n" > "$f"
  run "$SCRIPT" write --workflow w2 --step 1 --file "$f"
  [ "$status" -eq 0 ]
  run cat "$CHECKPOINT_PATH/w2.yaml"
  [[ "$output" == *"files_touched"* ]]
  [[ "$output" == *"sha256:"* ]]
}

@test "checkpoint.sh: write with --file pointing to missing path fails" {
  run "$SCRIPT" write --workflow w3 --step 1 --file "$TEST_TMP/missing.txt"
  [ "$status" -ne 0 ]
}

@test "checkpoint.sh: validate happy path returns 0 when files unchanged" {
  local f="$TEST_TMP/a.txt"
  printf "stable\n" > "$f"
  "$SCRIPT" write --workflow w4 --step 1 --file "$f"
  run "$SCRIPT" validate --workflow w4
  [ "$status" -eq 0 ]
}

@test "checkpoint.sh: validate detects checksum drift" {
  local f="$TEST_TMP/b.txt"
  printf "v1\n" > "$f"
  "$SCRIPT" write --workflow w5 --step 1 --file "$f"
  printf "v2\n" > "$f"
  run "$SCRIPT" validate --workflow w5
  [ "$status" -ne 0 ]
}

@test "checkpoint.sh: idempotent — two writes with no diffs produce stable step" {
  "$SCRIPT" write --workflow w6 --step 1 --var k=v
  local a b
  a="$(cat "$CHECKPOINT_PATH/w6.yaml" | grep -v '^timestamp:' | grep -v 'last_modified:')"
  "$SCRIPT" write --workflow w6 --step 1 --var k=v
  b="$(cat "$CHECKPOINT_PATH/w6.yaml" | grep -v '^timestamp:' | grep -v 'last_modified:')"
  [ "$a" = "$b" ]
}

@test "checkpoint.sh: usage error with no args → non-zero" {
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# E28-S191 / B2 — auto-create missing checkpoint directory
# ---------------------------------------------------------------------------
# When CHECKPOINT_PATH points at a directory that does not yet exist (fresh v2
# project immediately after /gaia-migrate apply deletes _memory/), checkpoint.sh
# write must create the path on demand with mkdir -p, not fail with ENOENT.

@test "B2: write auto-creates missing CHECKPOINT_PATH directory" {
  local fresh="$TEST_TMP/fresh/_memory/checkpoints"
  # The directory does NOT exist — write must create it.
  [ ! -d "$fresh" ]
  CHECKPOINT_PATH="$fresh" run "$SCRIPT" write --workflow w-b2 --step 1
  [ "$status" -eq 0 ]
  [ -d "$fresh" ]
  [ -f "$fresh/w-b2.yaml" ]
}

# ---------------------------------------------------------------------------
# E28-S202 / AC5 — CLAUDE_SKILL_DIR pre-check removed; resolver is authoritative
# ---------------------------------------------------------------------------
# Post-E28-S191 the resolver has its own 6-level precedence ladder. checkpoint.sh
# must NOT short-circuit on ${CLAUDE_SKILL_DIR:-} before calling the resolver:
# without this change setup.sh and finalize.sh on any workspace that doesn't
# export CLAUDE_SKILL_DIR (i.e. every Claude Code skill invocation) will die
# before the resolver gets a chance to look at CLAUDE_PROJECT_ROOT/config/…
# See the story file at docs/implementation-artifacts/E28-S202-*.md.

@test ".a: CHECKPOINT_PATH set → existing happy path still works" {
  # Early-exit branch of resolve_checkpoint_path must be untouched by the fix.
  # CLAUDE_SKILL_DIR is deliberately absent to prove the gate isn't load-bearing
  # on this path either.
  unset CLAUDE_SKILL_DIR
  run "$SCRIPT" write --workflow w-ac5a --step 1
  [ "$status" -eq 0 ]
  [ -f "$CHECKPOINT_PATH/w-ac5a.yaml" ]
}

@test ".b: CHECKPOINT_PATH unset + CLAUDE_PROJECT_ROOT config → resolver succeeds" {
  # Build a minimal project-config.yaml at CLAUDE_PROJECT_ROOT/config/ with
  # every required field so resolve-config.sh emits a usable checkpoint_path
  # line. CLAUDE_SKILL_DIR is deliberately unset — the old pre-check would
  # skip the resolver entirely and die 1 before touching the file system.
  local proj="$TEST_TMP/proj"
  mkdir -p "$proj/config"
  local ck="$proj/_memory/checkpoints"
  cat >"$proj/config/project-config.yaml" <<YAML
project_root: "$proj"
project_path: "."
memory_path: "$proj/_memory"
checkpoint_path: "$ck"
installed_path: "$proj/_gaia"
framework_version: "test"
date: "2026-04-19"
YAML

  unset CHECKPOINT_PATH
  unset CLAUDE_SKILL_DIR
  CLAUDE_PROJECT_ROOT="$proj" run "$SCRIPT" write --workflow w-ac5b --step 1
  [ "$status" -eq 0 ]
  [ -f "$ck/w-ac5b.yaml" ]
}

@test ".c: resolver output missing checkpoint_path key → die 1" {
  # AC2 fail-hard preservation: if the resolver succeeds but its output never
  # contains a 'checkpoint_path=' line, checkpoint.sh must still die 1 with
  # the canonical "CHECKPOINT_PATH not resolved" message. Shim the sibling
  # resolver with a stub that emits only an unrelated key and invoke via a
  # copy of checkpoint.sh so SCRIPT_DIR points at the stub directory.
  local stubdir="$TEST_TMP/stub-scripts"
  mkdir -p "$stubdir"
  cp "$SCRIPT" "$stubdir/checkpoint.sh"
  cat >"$stubdir/resolve-config.sh" <<'RESOLVER'
#!/usr/bin/env bash
printf "project_root='/nope'\n"
RESOLVER
  chmod +x "$stubdir/resolve-config.sh"

  unset CHECKPOINT_PATH
  unset CLAUDE_SKILL_DIR
  run "$stubdir/checkpoint.sh" write --workflow w-ac5c --step 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"CHECKPOINT_PATH not resolved"* ]] \
    || [[ "$stderr" == *"CHECKPOINT_PATH not resolved"* ]]
}
