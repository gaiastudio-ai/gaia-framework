#!/usr/bin/env bats
# memory-roundtrip.bats — integration / round-trip tests for the hybrid
# memory surface (ADR-046). Proves that a decision written via
# memory-writer.sh (E28-S146) in "session A" is readable via
# memory-loader.sh (E28-S13) in "session B" after the first session has
# exited.
#
# Story: E28-S149 — Test memory round-trip
# Refs:  FR-331, NFR-048, ADR-046, ADR-042, ADR-014
#
# Session model: bats cannot spawn real Claude Code sessions. Each test
# performs the write in a `bash -c '...'` subshell and the read in a
# separate `bash -c '...'` subshell. The filesystem-backed contract that
# ADR-046 Path 2 relies on is fully exercised this way — the subshell
# boundary is sufficient because the real session boundary in Claude
# Code is also bounded by filesystem state.
#
# Determinism: fixtures are deterministic. The only runtime-derived bytes
# in a log entry are the ISO 8601 timestamp emitted by memory-writer.sh;
# assertions pattern-match that timestamp rather than comparing literals.

load 'test_helper.bash'

setup() {
  common_setup
  WRITER="$SCRIPTS_DIR/memory-writer.sh"
  LOADER="$SCRIPTS_DIR/memory-loader.sh"
  export MEMORY_PATH="$TEST_TMP/_memory"
  mkdir -p "$MEMORY_PATH"
}
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Happy path — decision round-trip (AC1, AC2, AC3)
# ---------------------------------------------------------------------------

@test "roundtrip: decision written in session A surfaces via loader in session B" {
  local fixture='ROUNDTRIP-DECISION-FIXTURE-ALPHA'
  # Session A — write and exit.
  bash -c "MEMORY_PATH='$MEMORY_PATH' '$WRITER' --agent sm --type decision --content '$fixture' --source create-story"

  # Session B — fresh process, read.
  run bash -c "MEMORY_PATH='$MEMORY_PATH' '$LOADER' sm decision-log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$fixture"* ]]
  [[ "$output" == *"create-story"* ]]
  [[ "$output" == *"sm"* ]]
}

@test "roundtrip: decision timestamp / source / agent preserved byte-for-byte across the boundary" {
  bash -c "MEMORY_PATH='$MEMORY_PATH' '$WRITER' --agent sm --type decision --content 'FIDELITY-BODY' --source create-story"

  # Capture bytes stored by session A.
  local on_disk
  on_disk="$(cat "$MEMORY_PATH/sm-sidecar/decision-log.md")"

  # Session B loads via memory-loader.sh.
  run bash -c "MEMORY_PATH='$MEMORY_PATH' '$LOADER' sm decision-log"
  [ "$status" -eq 0 ]

  # ISO 8601 UTC timestamp format is present.
  echo "$output" | grep -qE '\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\]'
  # The exact timestamp the writer stored is what the reader returns.
  local ts
  ts="$(printf '%s\n' "$on_disk" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' | head -n 1)"
  [ -n "$ts" ]
  [[ "$output" == *"$ts"* ]]
  # Source workflow and agent id are preserved unchanged.
  [[ "$output" == *"create-story"* ]]
  [[ "$output" == *"sm"* ]]
}

# ---------------------------------------------------------------------------
# Happy path — ground-truth round-trip (AC4)
# ---------------------------------------------------------------------------

@test "roundtrip: ground-truth section written in session A surfaces in session B with _last_updated marker" {
  bash -c "MEMORY_PATH='$MEMORY_PATH' '$WRITER' --agent architect --type ground-truth --section '## Test Section' --content 'round-trip-test-value' --source create-arch"

  run bash -c "MEMORY_PATH='$MEMORY_PATH' '$LOADER' architect ground-truth"
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Test Section"* ]]
  [[ "$output" == *"round-trip-test-value"* ]]
  [[ "$output" == *"_last_updated"* ]]
}

# ---------------------------------------------------------------------------
# Edge case EC-1 — multi-line content with shell-special chars (data fidelity)
# ---------------------------------------------------------------------------

@test "roundtrip : multi-line content with backticks, code fences, and shell specials is byte-for-byte preserved" {
  # Write the fixture from a file to avoid quoting games at the shell boundary.
  local fixture_file="$TEST_TMP/ec1-fixture.txt"
  cat > "$fixture_file" <<'FIX'
line-one
```
- key: "value with $var"
- other: 'single-quoted'
```
final-line
FIX
  # Session A — read fixture from disk and pass via --content.
  bash -c '
    set -e
    content="$(cat "'$fixture_file'")"
    MEMORY_PATH="'$MEMORY_PATH'" "'$WRITER'" --agent sm --type decision --content "$content" --source dev-story
  '

  # Session B — load and compare to the original fixture, byte-for-byte.
  run bash -c "MEMORY_PATH='$MEMORY_PATH' '$LOADER' sm decision-log"
  [ "$status" -eq 0 ]
  local fixture
  fixture="$(cat "$fixture_file")"
  [[ "$output" == *"$fixture"* ]]
  # Backticks, dollar signs, and the code fence must all survive unchanged.
  [[ "$output" == *'```'* ]]
  [[ "$output" == *'$var'* ]]
  [[ "$output" == *"'single-quoted'"* ]]
}

# ---------------------------------------------------------------------------
# Edge case EC-2 — concurrent writers before a read
# ---------------------------------------------------------------------------

@test "roundtrip : two parallel writers both land; loader surfaces both entries" {
  mkdir -p "$MEMORY_PATH/sm-sidecar"
  (bash -c "MEMORY_PATH='$MEMORY_PATH' '$WRITER' --agent sm --type decision --content 'EC2-ALPHA' --source dev-story") &
  local p1=$!
  (bash -c "MEMORY_PATH='$MEMORY_PATH' '$WRITER' --agent sm --type decision --content 'EC2-BRAVO' --source dev-story") &
  local p2=$!
  wait "$p1"
  wait "$p2"

  run bash -c "MEMORY_PATH='$MEMORY_PATH' '$LOADER' sm decision-log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"EC2-ALPHA"* ]]
  [[ "$output" == *"EC2-BRAVO"* ]]
}

# ---------------------------------------------------------------------------
# Edge case EC-3 — fresh agent (no sidecar directory pre-existing)
# ---------------------------------------------------------------------------

@test "roundtrip : first-ever write for a never-seen agent creates sidecar dir and is loadable" {
  local fresh="brand-new-agent-$$"
  [ ! -d "$MEMORY_PATH/${fresh}-sidecar" ]

  bash -c "MEMORY_PATH='$MEMORY_PATH' '$WRITER' --agent '$fresh' --type decision --content 'EC3-FRESH' --source dev-story"
  [ -d "$MEMORY_PATH/${fresh}-sidecar" ]
  [ -f "$MEMORY_PATH/${fresh}-sidecar/decision-log.md" ]

  run bash -c "MEMORY_PATH='$MEMORY_PATH' '$LOADER' '$fresh' decision-log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"EC3-FRESH"* ]]
}

# ---------------------------------------------------------------------------
# Edge case EC-4 — over-budget ground-truth, loader --max-tokens caps output
# ---------------------------------------------------------------------------

@test "roundtrip : loader --max-tokens truncates an oversize ground-truth at read time" {
  # Write a ground-truth section whose body is ~4000 chars, then ask the
  # loader to cap at 100 tokens (== 400 chars by default token_approximation).
  local big
  big="$(python3 -c "print('x' * 4000, end='')")"
  bash -c "MEMORY_PATH='$MEMORY_PATH' '$WRITER' --agent sm --type ground-truth --section '## Big' --content '$big' --source create-arch"

  run bash -c "MEMORY_PATH='$MEMORY_PATH' '$LOADER' sm ground-truth --max-tokens 100"
  [ "$status" -eq 0 ]
  # Truncation is observable — the cap is 100 * 4 = 400 chars.
  [ "${#output}" -le 400 ]

  # Without the cap, the full content is surfaced.
  run bash -c "MEMORY_PATH='$MEMORY_PATH' '$LOADER' sm ground-truth"
  [ "$status" -eq 0 ]
  [ "${#output}" -ge 4000 ]
}

# ---------------------------------------------------------------------------
# Edge case EC-5 — create new ground-truth section that didn't previously exist
# ---------------------------------------------------------------------------

@test "roundtrip : writing a brand-new ground-truth section is surfaced by the loader" {
  mkdir -p "$MEMORY_PATH/sm-sidecar"
  cat > "$MEMORY_PATH/sm-sidecar/ground-truth.md" <<'EOF'
## Pre-Existing

existing body
EOF

  bash -c "MEMORY_PATH='$MEMORY_PATH' '$WRITER' --agent sm --type ground-truth --section '## Round-Trip Test' --content 'new-section-value' --source create-arch"

  run bash -c "MEMORY_PATH='$MEMORY_PATH' '$LOADER' sm ground-truth"
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Round-Trip Test"* ]]
  [[ "$output" == *"new-section-value"* ]]
  [[ "$output" == *"existing body"* ]]
  [[ "$output" == *"_last_updated"* ]]
}

# ---------------------------------------------------------------------------
# Edge case EC-6 — missing config.yaml between write and read, fallback path
# ---------------------------------------------------------------------------

@test "roundtrip : config.yaml deleted after the write; loader falls back to <agent>-sidecar/" {
  # Session A — write under a config.yaml that maps sm to sm-sidecar.
  cat > "$MEMORY_PATH/config.yaml" <<'EOF'
agents:
  sm:
    sidecar: "sm-sidecar"
EOF
  bash -c "MEMORY_PATH='$MEMORY_PATH' '$WRITER' --agent sm --type decision --content 'EC6-CONFIG-GONE' --source dev-story"
  [ -f "$MEMORY_PATH/sm-sidecar/decision-log.md" ]

  # Between sessions: delete the config file.
  rm -f "$MEMORY_PATH/config.yaml"

  # Session B — loader must fall back to _memory/sm-sidecar/ and still succeed.
  run bash -c "MEMORY_PATH='$MEMORY_PATH' '$LOADER' sm decision-log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"EC6-CONFIG-GONE"* ]]
}

# ---------------------------------------------------------------------------
# Edge case EC-7 — aged entry: loader is not a hygiene filter
# ---------------------------------------------------------------------------

@test "roundtrip : loader returns entries regardless of age (hygiene is a separate concern)" {
  mkdir -p "$MEMORY_PATH/sm-sidecar"
  # Write a decision normally.
  bash -c "MEMORY_PATH='$MEMORY_PATH' '$WRITER' --agent sm --type decision --content 'EC7-AGED' --source dev-story"
  # Back-date the file mtime so any naive hygiene sweep would skip it.
  # The loader must still return the bytes — it does not filter by age.
  touch -t 202001010000 "$MEMORY_PATH/sm-sidecar/decision-log.md"

  run bash -c "MEMORY_PATH='$MEMORY_PATH' '$LOADER' sm decision-log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"EC7-AGED"* ]]
}

# ---------------------------------------------------------------------------
# Edge case EC-8 — writer crash mid-write: lock released, log remains well-formed
# ---------------------------------------------------------------------------

@test "roundtrip : killing writer mid-operation leaves log well-formed; lock is released" {
  mkdir -p "$MEMORY_PATH/sm-sidecar"
  # Seed a first, clean entry.
  bash -c "MEMORY_PATH='$MEMORY_PATH' '$WRITER' --agent sm --type decision --content 'EC8-BEFORE' --source dev-story"
  local size_before
  size_before="$(wc -c < "$MEMORY_PATH/sm-sidecar/decision-log.md")"

  # Background writer holds an external lock so our target writer would
  # block; kill the target before it can rename a temp file into place.
  local lockfile="$MEMORY_PATH/sm-sidecar/.decision-log.md.lock"
  if command -v flock >/dev/null 2>&1; then
    (
      exec 9>"$lockfile"
      flock 9
      sleep 2
    ) &
    local holder=$!
    sleep 0.2
    # Start the writer in the background; it will wait on the lock.
    (MEMORY_PATH="$MEMORY_PATH" "$WRITER" --agent sm --type decision --content 'EC8-CRASHED' --source dev-story --lock-timeout 30) &
    local victim=$!
    sleep 0.2
    kill -9 "$victim" 2>/dev/null || true
    wait "$victim" 2>/dev/null || true
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
  else
    mkdir "$lockfile"
    (MEMORY_PATH="$MEMORY_PATH" "$WRITER" --agent sm --type decision --content 'EC8-CRASHED' --source dev-story --lock-timeout 30) &
    local victim=$!
    sleep 0.2
    kill -9 "$victim" 2>/dev/null || true
    wait "$victim" 2>/dev/null || true
    rmdir "$lockfile" 2>/dev/null || true
  fi

  # No partial entry should have landed: log content is unchanged (or at
  # most unchanged — the aborted writer never got past the lock wait).
  local size_after
  size_after="$(wc -c < "$MEMORY_PATH/sm-sidecar/decision-log.md")"
  [ "$size_after" -eq "$size_before" ]

  # The log is still well-formed — the loader reads it and surfaces the
  # pre-existing entry.
  run bash -c "MEMORY_PATH='$MEMORY_PATH' '$LOADER' sm decision-log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"EC8-BEFORE"* ]]
  [[ "$output" != *"EC8-CRASHED"* ]]

  # After recovery, a fresh write succeeds — the stale lock did not survive.
  bash -c "MEMORY_PATH='$MEMORY_PATH' '$WRITER' --agent sm --type decision --content 'EC8-AFTER' --source dev-story --lock-timeout 2"
  run bash -c "MEMORY_PATH='$MEMORY_PATH' '$LOADER' sm decision-log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"EC8-AFTER"* ]]
}

# ---------------------------------------------------------------------------
# Edge case EC-9 — reader-before-writer race against an existing log
# ---------------------------------------------------------------------------

@test "roundtrip : reader with pre-existing content sees it; in-flight writer does not corrupt the read" {
  mkdir -p "$MEMORY_PATH/sm-sidecar"
  bash -c "MEMORY_PATH='$MEMORY_PATH' '$WRITER' --agent sm --type decision --content 'EC9-PRE-EXISTING' --source dev-story"

  # Start a slow writer in the background (lock-timeout gives it runway).
  (MEMORY_PATH="$MEMORY_PATH" "$WRITER" --agent sm --type decision --content 'EC9-LATE-WRITER' --source dev-story --lock-timeout 5) &
  local writer_pid=$!

  # Immediately read. The loader is atomic per-file; whether the late
  # writer has committed yet or not, the reader must see a valid log.
  run bash -c "MEMORY_PATH='$MEMORY_PATH' '$LOADER' sm decision-log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"EC9-PRE-EXISTING"* ]]

  wait "$writer_pid"

  # After the late writer finishes, both entries are present.
  run bash -c "MEMORY_PATH='$MEMORY_PATH' '$LOADER' sm decision-log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"EC9-PRE-EXISTING"* ]]
  [[ "$output" == *"EC9-LATE-WRITER"* ]]
}

# ---------------------------------------------------------------------------
# Edge case EC-10 — no-`flock` environment, POSIX mkdir fallback path
# ---------------------------------------------------------------------------

@test "roundtrip : round-trip succeeds with flock hidden from PATH (mkdir-lock fallback)" {
  # Craft a PATH that excludes any directory holding `flock`. Assemble a
  # stub PATH with just bash/core utilities — enough for the writer but
  # without flock on disk.
  local stub="$TEST_TMP/no-flock-bin"
  mkdir -p "$stub"
  for tool in bash sh cat cp mv mkdir mktemp rm rmdir date printf head wc awk sed grep sleep kill stat touch dirname basename python3 chmod tr cut sort uniq tee tail env true false test [; do
    if command -v "$tool" >/dev/null 2>&1; then
      ln -sf "$(command -v "$tool")" "$stub/$tool" 2>/dev/null || true
    fi
  done

  # Sanity: flock must be absent from the stub PATH.
  if PATH="$stub" command -v flock >/dev/null 2>&1; then
    skip "unable to hide flock from PATH in this environment"
  fi

  # Session A — write using the stubbed PATH; mkdir-lock path is exercised.
  PATH="$stub" MEMORY_PATH="$MEMORY_PATH" bash -c "'$WRITER' --agent sm --type decision --content 'EC10-NO-FLOCK' --source dev-story"
  [ -f "$MEMORY_PATH/sm-sidecar/decision-log.md" ]

  # Session B — also under the stubbed PATH, read the content.
  run bash -c "PATH='$stub' MEMORY_PATH='$MEMORY_PATH' '$LOADER' sm decision-log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"EC10-NO-FLOCK"* ]]
}
