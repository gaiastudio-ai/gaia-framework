#!/usr/bin/env bats
# memory-writer.bats — unit tests for plugins/gaia/scripts/memory-writer.sh
# Story: E28-S146
# Coverage: flag parsing, type dispatch (decision / ground-truth), sidecar
# resolution via _memory/config.yaml, first-ever-write mkdir, ISO 8601 UTC
# timestamp shape, atomic write, POSIX advisory lock (flock + fallback),
# lock timeout exit 75, sysexits exit codes (64/74/75), large payloads,
# round-trip with memory-loader.sh.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/memory-writer.sh"
  LOADER="$SCRIPTS_DIR/memory-loader.sh"
  export MEMORY_PATH="$TEST_TMP/_memory"
  mkdir -p "$MEMORY_PATH"
}
teardown() { common_teardown; }

# ---------- Help / usage ----------

@test "memory-writer.sh: --help exits 0 and prints usage" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *[Uu]sage* ]]
}

@test "memory-writer.sh: no args exits 64 (usage)" {
  run "$SCRIPT"
  [ "$status" -eq 64 ]
}

# ---------- Parameter validation (exit 64) ----------

@test "memory-writer.sh: missing --agent exits 64 and names the flag" {
  run "$SCRIPT" --type decision --content "x" --source dev-story
  [ "$status" -eq 64 ]
  [[ "$output" == *"--agent"* ]]
}

@test "memory-writer.sh: missing --type exits 64 and names the flag" {
  run "$SCRIPT" --agent sm --content "x" --source dev-story
  [ "$status" -eq 64 ]
  [[ "$output" == *"--type"* ]]
}

@test "memory-writer.sh: missing --content exits 64 and names the flag" {
  run "$SCRIPT" --agent sm --type decision --source dev-story
  [ "$status" -eq 64 ]
  [[ "$output" == *"--content"* ]]
}

@test "memory-writer.sh: missing --source exits 64 and names the flag" {
  run "$SCRIPT" --agent sm --type decision --content "x"
  [ "$status" -eq 64 ]
  [[ "$output" == *"--source"* ]]
}

@test "memory-writer.sh: empty --source exits 64" {
  run "$SCRIPT" --agent sm --type decision --content "x" --source ""
  [ "$status" -eq 64 ]
  [[ "$output" == *"--source"* ]]
}

@test "memory-writer.sh: invalid --type value exits 64 and explains allowed values" {
  run "$SCRIPT" --agent sm --type bogus --content "x" --source dev-story
  [ "$status" -eq 64 ]
  [[ "$output" == *"decision"* ]]
  [[ "$output" == *"ground-truth"* ]]
}

@test "memory-writer.sh: --type ground-truth without --section exits 64" {
  run "$SCRIPT" --agent architect --type ground-truth --content "x" --source create-arch
  [ "$status" -eq 64 ]
  [[ "$output" == *"--section"* ]]
}

# ---------- Happy path: --type decision ----------

@test "memory-writer.sh: decision append creates sidecar dir on first-ever write" {
  [ ! -d "$MEMORY_PATH/sm-sidecar" ]
  run "$SCRIPT" --agent sm --type decision --content "Selected story E28-S146" --source create-story
  [ "$status" -eq 0 ]
  [ -d "$MEMORY_PATH/sm-sidecar" ]
  [ -f "$MEMORY_PATH/sm-sidecar/decision-log.md" ]
}

@test "memory-writer.sh: decision append writes entry with ISO 8601 timestamp, source, agent, and content" {
  run "$SCRIPT" --agent sm --type decision --content "Body text here" --source create-story
  [ "$status" -eq 0 ]
  local body
  body="$(cat "$MEMORY_PATH/sm-sidecar/decision-log.md")"
  [[ "$body" == *"create-story"* ]]
  [[ "$body" == *"sm"* ]]
  [[ "$body" == *"Body text here"* ]]
  # ISO 8601 UTC: YYYY-MM-DDTHH:MM:SSZ
  grep -qE '\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\]' <<<"$body"
}

@test "memory-writer.sh: decision append is additive — prior entries preserved" {
  "$SCRIPT" --agent sm --type decision --content "first" --source dev-story
  "$SCRIPT" --agent sm --type decision --content "second" --source dev-story
  local body
  body="$(cat "$MEMORY_PATH/sm-sidecar/decision-log.md")"
  [[ "$body" == *"first"* ]]
  [[ "$body" == *"second"* ]]
}

@test "memory-writer.sh: config.yaml sidecar mapping wins over default path" {
  mkdir -p "$MEMORY_PATH/custom-sidecar"
  cat > "$MEMORY_PATH/config.yaml" <<'EOF'
agents:
  nate:
    sidecar: "custom-sidecar"
EOF
  run "$SCRIPT" --agent nate --type decision --content "routed" --source dev-story
  [ "$status" -eq 0 ]
  [ -f "$MEMORY_PATH/custom-sidecar/decision-log.md" ]
  [ ! -f "$MEMORY_PATH/nate-sidecar/decision-log.md" ]
}

@test "memory-writer.sh: agent missing from config.yaml falls back to <agent>-sidecar" {
  cat > "$MEMORY_PATH/config.yaml" <<'EOF'
agents:
  other:
    sidecar: "other-sidecar"
EOF
  run "$SCRIPT" --agent brand-new --type decision --content "fallback" --source dev-story
  [ "$status" -eq 0 ]
  [ -f "$MEMORY_PATH/brand-new-sidecar/decision-log.md" ]
}

# ---------- Happy path: --type ground-truth ----------

@test "memory-writer.sh: ground-truth overwrites named section and preserves others" {
  mkdir -p "$MEMORY_PATH/architect-sidecar"
  cat > "$MEMORY_PATH/architect-sidecar/ground-truth.md" <<'EOF'
## Alpha

alpha body

## Project Paths

old paths

## Omega

omega body
EOF
  run "$SCRIPT" --agent architect --type ground-truth \
    --section "## Project Paths" --content "new paths body" --source create-arch
  [ "$status" -eq 0 ]
  local body
  body="$(cat "$MEMORY_PATH/architect-sidecar/ground-truth.md")"
  [[ "$body" == *"alpha body"* ]]
  [[ "$body" == *"omega body"* ]]
  [[ "$body" == *"new paths body"* ]]
  [[ "$body" != *"old paths"* ]]
  [[ "$body" == *"_last_updated"* ]]
}

@test "memory-writer.sh: ground-truth creates section when header absent" {
  mkdir -p "$MEMORY_PATH/architect-sidecar"
  cat > "$MEMORY_PATH/architect-sidecar/ground-truth.md" <<'EOF'
## Existing

existing body
EOF
  run "$SCRIPT" --agent architect --type ground-truth \
    --section "## Brand New" --content "new body" --source create-arch
  [ "$status" -eq 0 ]
  local body
  body="$(cat "$MEMORY_PATH/architect-sidecar/ground-truth.md")"
  [[ "$body" == *"## Brand New"* ]]
  [[ "$body" == *"new body"* ]]
  [[ "$body" == *"existing body"* ]]
}

# ---------- Content edge cases ----------

@test "memory-writer.sh: content with special characters is written verbatim" {
  local special='line1
`code`
- a: b
"quoted"'
  run "$SCRIPT" --agent sm --type decision --content "$special" --source dev-story
  [ "$status" -eq 0 ]
  local body
  body="$(cat "$MEMORY_PATH/sm-sidecar/decision-log.md")"
  [[ "$body" == *"\`code\`"* ]]
  [[ "$body" == *"line1"* ]]
  [[ "$body" == *'"quoted"'* ]]
}

@test "memory-writer.sh: large content (20KB) is written in full without truncation" {
  local big
  big="$(python3 -c "print('x' * 20000, end='')")"
  run "$SCRIPT" --agent sm --type decision --content "$big" --source dev-story
  [ "$status" -eq 0 ]
  local size
  size="$(wc -c < "$MEMORY_PATH/sm-sidecar/decision-log.md")"
  [ "$size" -ge 20000 ]
}

# ---------- Locking / concurrency ----------

@test "memory-writer.sh: concurrent writers both land entries without corruption" {
  mkdir -p "$MEMORY_PATH/sm-sidecar"
  "$SCRIPT" --agent sm --type decision --content "ALPHA-ENTRY" --source dev-story &
  local pid1=$!
  "$SCRIPT" --agent sm --type decision --content "BRAVO-ENTRY" --source dev-story &
  local pid2=$!
  wait "$pid1"
  wait "$pid2"
  local body
  body="$(cat "$MEMORY_PATH/sm-sidecar/decision-log.md")"
  [[ "$body" == *"ALPHA-ENTRY"* ]]
  [[ "$body" == *"BRAVO-ENTRY"* ]]
}

@test "memory-writer.sh: lock timeout exits 75 when lock held" {
  mkdir -p "$MEMORY_PATH/sm-sidecar"
  touch "$MEMORY_PATH/sm-sidecar/decision-log.md"
  local lockfile="$MEMORY_PATH/sm-sidecar/.decision-log.md.lock"
  # Hold the lock in a background subshell. Use flock when available;
  # otherwise emulate by creating the lock directory/file the script checks.
  if command -v flock >/dev/null 2>&1; then
    (
      exec 9>"$lockfile"
      flock 9
      sleep 3
    ) &
    local holder=$!
    sleep 0.2
    run "$SCRIPT" --agent sm --type decision --content "blocked" --source dev-story --lock-timeout 1
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    [ "$status" -eq 75 ]
  else
    # Fallback path — the script uses mkdir-style lockfile.
    mkdir "$lockfile"
    run "$SCRIPT" --agent sm --type decision --content "blocked" --source dev-story --lock-timeout 1
    rmdir "$lockfile" 2>/dev/null || true
    [ "$status" -eq 75 ]
  fi
}

# ---------- Round-trip with memory-loader.sh ----------

@test "memory-writer.sh: round-trip — written decision is readable via memory-loader.sh" {
  "$SCRIPT" --agent sm --type decision --content "ROUNDTRIP-MARKER" --source dev-story
  run "$LOADER" sm decision-log
  [ "$status" -eq 0 ]
  [[ "$output" == *"ROUNDTRIP-MARKER"* ]]
  [[ "$output" == *"dev-story"* ]]
}
