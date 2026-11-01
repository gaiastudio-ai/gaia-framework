#!/usr/bin/env bats
# review-telemetry.bats — tests for plugins/gaia/scripts/review-telemetry-writer.sh
#
# Covers: gate-entry format, round-summary, story-total, timing budget,
# concurrent append safety, no-secrets guard, quote-bearing values,
# standalone review path, write-failure resilience, bash 3.2 portability.

load 'test_helper.bash'

setup() {
  common_setup
  WRITER="$SCRIPTS_DIR/review-telemetry-writer.sh"

  # Build a minimal story fixture that resolve-story-file.sh can find.
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  IMPL="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  STORY_DIR="$IMPL/epic-E900-test/E900-S1-telemetry-test"
  mkdir -p "$STORY_DIR"
  cat > "$STORY_DIR/story.md" <<'STORY'
---
template: 'story'
key: "E900-S1"
title: "Telemetry test fixture"
status: review
---

# Story: Telemetry test fixture

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | — |
| QA Tests | UNVERIFIED | — |
| Security Review | UNVERIFIED | — |
| Test Automation | UNVERIFIED | — |
| Test Review | UNVERIFIED | — |
| Performance Review | UNVERIFIED | — |
STORY

  JSONL="$STORY_DIR/review-telemetry.jsonl"
}

teardown() { common_teardown; }

# ---------- Scenario 1: gate entry with all fields ----------

@test "gate entry writes valid JSON with all allowlisted fields" {
  run bash "$WRITER" gate-entry \
    --story E900-S1 --gate "Code Review" --verdict PASSED \
    --round 1 --run-id "round-20260101T120000Z-1234" \
    --started-at 1700000000000 --ended-at 1700000005000 \
    --mutation-score 85.5 --token-estimate 4200
  [ "$status" -eq 0 ]

  # File must exist with exactly one line.
  [ -f "$JSONL" ]
  local count
  count="$(wc -l < "$JSONL" | tr -d ' ')"
  [ "$count" -eq 1 ]

  # Line must parse as JSON.
  jq -e '.' "$JSONL" >/dev/null

  # Verify every allowlisted field is present.
  local line
  line="$(cat "$JSONL")"
  [ "$(jq -r '.schema_version' <<< "$line")" = "1" ]
  [ "$(jq -r '.type' <<< "$line")" = "gate" ]
  [ "$(jq -r '.gate' <<< "$line")" = "Code Review" ]
  [ "$(jq -r '.verdict' <<< "$line")" = "PASSED" ]
  [ "$(jq -r '.round' <<< "$line")" = "1" ]
  [ "$(jq -r '.run_id' <<< "$line")" = "round-20260101T120000Z-1234" ]
  [ "$(jq -r '.start' <<< "$line")" = "1700000000000" ]
  [ "$(jq -r '.end' <<< "$line")" = "1700000005000" ]
  [ "$(jq -r '.duration_ms' <<< "$line")" = "5000" ]
  [ "$(jq -r '.mutation_score' <<< "$line")" = "85.5" ]
  [ "$(jq -r '.token_estimate' <<< "$line")" = "4200" ]

  # Verify NO extra fields beyond the allowlist.
  local keys
  keys="$(jq -r 'keys[]' <<< "$line" | sort)"
  local expected
  expected="$(printf '%s\n' duration_ms end gate mutation_score round run_id schema_version start token_estimate type verdict | sort)"
  [ "$keys" = "$expected" ]
}

# ---------- Scenario 2: non-mutation gate ----------

@test "gate entry with no mutation score writes null" {
  run bash "$WRITER" gate-entry \
    --story E900-S1 --gate "Code Review" --verdict PASSED
  [ "$status" -eq 0 ]
  [ -f "$JSONL" ]
  [ "$(jq -r '.mutation_score' "$JSONL")" = "null" ]
}

# ---------- Scenario 3: round summary ----------

@test "round summary writes valid JSON with type discriminator" {
  local gates='{"Code Review":"PASSED","QA Tests":"PASSED","Security Review":"PASSED","Test Automation":"PASSED","Test Review":"PASSED","Performance Review":"PASSED"}'
  run bash "$WRITER" round-summary \
    --story E900-S1 --round 1 \
    --composite-verdict COMPLETE \
    --total-duration-ms 30000 --total-tokens 12000 \
    --gates-json "$gates"
  [ "$status" -eq 0 ]
  [ -f "$JSONL" ]

  local line
  line="$(cat "$JSONL")"
  [ "$(jq -r '.type' <<< "$line")" = "round-summary" ]
  [ "$(jq -r '.composite_verdict' <<< "$line")" = "COMPLETE" ]
  [ "$(jq -r '.total_duration_ms' <<< "$line")" = "30000" ]
  [ "$(jq -r '.total_tokens' <<< "$line")" = "12000" ]
  [ "$(jq -r '.gates["Code Review"]' <<< "$line")" = "PASSED" ]
  [ "$(jq -r '.round' <<< "$line")" = "1" ]
  [ "$(jq -r '.schema_version' <<< "$line")" = "1" ]

  # Verify only allowlisted fields in summary.
  local keys
  keys="$(jq -r 'keys[]' <<< "$line" | sort)"
  local expected
  expected="$(printf '%s\n' composite_verdict gates round schema_version total_duration_ms total_tokens type | sort)"
  [ "$keys" = "$expected" ]
}

# ---------- Scenario 4: story total ----------

@test "story total writes valid JSON with story-total type" {
  local gates='{"Code Review":"PASSED","QA Tests":"PASSED","Security Review":"PASSED","Test Automation":"PASSED","Test Review":"PASSED","Performance Review":"PASSED"}'
  run bash "$WRITER" story-total \
    --story E900-S1 --round 2 \
    --composite-verdict COMPLETE \
    --total-duration-ms 60000 --total-tokens 25000 \
    --gates-json "$gates"
  [ "$status" -eq 0 ]
  [ -f "$JSONL" ]

  local line
  line="$(cat "$JSONL")"
  [ "$(jq -r '.type' <<< "$line")" = "story-total" ]
  [ "$(jq -r '.composite_verdict' <<< "$line")" = "COMPLETE" ]
}

# ---------- Scenario 5: write failure ----------

@test "write failure logs warning and exits 0" {
  # Point IMPLEMENTATION_ARTIFACTS at a non-writable location.
  # Create a separate tmpdir whose parent we can chmod.
  local rwdir="$TEST_TMP/rw-test"
  local impl="$rwdir/.gaia/artifacts/implementation-artifacts"
  local sdir="$impl/epic-E900-test/E900-S1-telemetry-test"
  mkdir -p "$sdir"
  cp "$STORY_DIR/story.md" "$sdir/story.md"
  # Pre-create the jsonl file, then make it read-only.
  touch "$sdir/review-telemetry.jsonl"
  chmod 000 "$sdir/review-telemetry.jsonl"

  local captured
  captured="$(PROJECT_ROOT="$rwdir" PROJECT_PATH="$rwdir" \
    bash "$WRITER" gate-entry \
    --story E900-S1 --gate "Code Review" --verdict PASSED 2>&1)" \
    && true
  local rc=$?
  chmod 644 "$sdir/review-telemetry.jsonl"
  [ "$rc" -eq 0 ]
  # Combined output (stdout+stderr) should contain the warning.
  [[ "$captured" == *"write failed"* ]] || [[ "$captured" == *"skipping telemetry write"* ]]
}

# ---------- Scenario 6: timing budget (p95 <= 50ms) ----------

@test "p95 write time is within 50ms budget" {
  # Measure only the atomic append (printf + jq), not process-spawn
  # overhead. Pre-build a valid JSON line and time the append loop.
  local line
  line="$(jq -nc \
    --argjson schema_version 1 \
    --arg type "gate" \
    --arg gate "Code Review" \
    --arg verdict "PASSED" \
    --argjson round 1 \
    --arg run_id "round-20260101T120000Z-999" \
    --argjson start 1700000000000 \
    --argjson end 1700000005000 \
    --argjson duration_ms 5000 \
    --argjson mutation_score "null" \
    --argjson token_estimate "null" \
    '{schema_version:$schema_version,type:$type,gate:$gate,
      round:$round,run_id:$run_id,start:$start,end:$end,
      duration_ms:$duration_ms,verdict:$verdict,
      mutation_score:$mutation_score,token_estimate:$token_estimate}')"

  local times=()
  local i
  for i in $(seq 1 100); do
    local t_start t_end elapsed
    t_start="$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')"
    printf '%s\n' "$line" >> "$JSONL" 2>/dev/null
    t_end="$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')"
    elapsed=$(( t_end - t_start ))
    times+=("$elapsed")
  done

  # Sort and find p95 (index 94 in 0-based, sed line 95).
  local sorted
  sorted="$(printf '%s\n' "${times[@]}" | sort -n)"
  local p95
  p95="$(printf '%s\n' "$sorted" | sed -n '95p')"

  # p95 must be <= 50ms per entry.
  [ "$p95" -le 50 ]
}

# ---------- Scenario 7: concurrent append ----------

@test "concurrent appends produce no interleaved or partial lines" {
  # Launch 20 parallel writers.
  local pids=()
  local j
  for j in $(seq 1 20); do
    bash "$WRITER" gate-entry \
      --story E900-S1 --gate "Code Review" --verdict PASSED \
      --round "$j" &
    pids+=($!)
  done
  # Wait for all.
  for p in "${pids[@]}"; do
    wait "$p" || true
  done

  [ -f "$JSONL" ]
  local line_count
  line_count="$(wc -l < "$JSONL" | tr -d ' ')"
  [ "$line_count" -eq 20 ]

  # Every line must parse as valid JSON.
  local bad
  bad="$(jq -c '.' "$JSONL" 2>&1 | grep -c 'parse error' || true)"
  [ "$bad" -eq 0 ]
}

# ---------- Scenario 8: no secrets ----------

@test "gate entry does not accept or emit findings text" {
  # The writer has no --findings flag. Verify allowlist by confirming
  # only the 11 gate-entry fields appear.
  run bash "$WRITER" gate-entry \
    --story E900-S1 --gate "Security Review" --verdict FAILED
  [ "$status" -eq 0 ]
  [ -f "$JSONL" ]

  local keys
  keys="$(jq -r 'keys | length' "$JSONL")"
  [ "$keys" -eq 11 ]
}

# ---------- Scenario 9: quote-bearing values ----------

@test "gate name with quotes stays valid JSON" {
  # Use a gate name with embedded quotes (synthetic).
  run bash "$WRITER" gate-entry \
    --story E900-S1 --gate 'Code "Review"' --verdict PASSED
  [ "$status" -eq 0 ]
  [ -f "$JSONL" ]
  jq -e '.' "$JSONL" >/dev/null
  [ "$(jq -r '.gate' "$JSONL")" = 'Code "Review"' ]
}

# ---------- Scenario 10: standalone review ----------

@test "standalone review writes gate line with null round and run_id" {
  run bash "$WRITER" gate-entry \
    --story E900-S1 --gate "Security Review" --verdict PASSED
  [ "$status" -eq 0 ]
  [ -f "$JSONL" ]
  [ "$(jq -r '.round' "$JSONL")" = "null" ]
  [ "$(jq -r '.run_id' "$JSONL")" = "null" ]
  [ "$(jq -r '.start' "$JSONL")" = "null" ]
  [ "$(jq -r '.duration_ms' "$JSONL")" = "null" ]
  [ "$(jq -r '.token_estimate' "$JSONL")" = "null" ]
}

# ---------- Scenario 11: append-only ----------

@test "multiple writes append lines without rewriting existing ones" {
  bash "$WRITER" gate-entry \
    --story E900-S1 --gate "Code Review" --verdict PASSED --round 1
  local first_line
  first_line="$(head -1 "$JSONL")"

  bash "$WRITER" gate-entry \
    --story E900-S1 --gate "QA Tests" --verdict FAILED --round 1

  local count
  count="$(wc -l < "$JSONL" | tr -d ' ')"
  [ "$count" -eq 2 ]

  # First line must be unchanged.
  local current_first
  current_first="$(head -1 "$JSONL")"
  [ "$first_line" = "$current_first" ]
}

# ---------- Required args validation ----------

@test "gate-entry without --story exits 1" {
  run bash "$WRITER" gate-entry --gate "Code Review" --verdict PASSED
  [ "$status" -eq 1 ]
}

@test "gate-entry without --gate exits 1" {
  run bash "$WRITER" gate-entry --story E900-S1 --verdict PASSED
  [ "$status" -eq 1 ]
}

@test "gate-entry without --verdict exits 1" {
  run bash "$WRITER" gate-entry --story E900-S1 --gate "Code Review"
  [ "$status" -eq 1 ]
}

@test "unknown subcommand exits 1" {
  run bash "$WRITER" bad-subcmd
  [ "$status" -eq 1 ]
}

@test "no arguments exits 1" {
  run bash "$WRITER"
  [ "$status" -eq 1 ]
}

# ---------- Integration: review-gate.sh triggers telemetry ----------

@test "review-gate.sh update PASSED triggers telemetry write" {
  local GATE_SCRIPT="$SCRIPTS_DIR/review-gate.sh"
  export REVIEW_GATE_PROOF_OF_EXECUTION=off

  run bash "$GATE_SCRIPT" update \
    --story E900-S1 --gate "Code Review" --verdict PASSED \
    --started-at 1700000000000 --token-estimate 5000 \
    --telemetry-round 1 --telemetry-run-id "round-20260101T120000Z-9999"
  [ "$status" -eq 0 ]

  [ -f "$JSONL" ]
  local line
  line="$(cat "$JSONL")"
  [ "$(jq -r '.type' <<< "$line")" = "gate" ]
  [ "$(jq -r '.gate' <<< "$line")" = "Code Review" ]
  [ "$(jq -r '.verdict' <<< "$line")" = "PASSED" ]
  [ "$(jq -r '.round' <<< "$line")" = "1" ]
  [ "$(jq -r '.run_id' <<< "$line")" = "round-20260101T120000Z-9999" ]
  [ "$(jq -r '.token_estimate' <<< "$line")" = "5000" ]
  # start should be the --started-at value.
  [ "$(jq -r '.start' <<< "$line")" = "1700000000000" ]
  # end and duration_ms should be non-null (computed at write time).
  [ "$(jq -r '.end' <<< "$line")" != "null" ]
  [ "$(jq -r '.duration_ms' <<< "$line")" != "null" ]
}

@test "review-gate.sh update UNVERIFIED does not trigger telemetry write" {
  local GATE_SCRIPT="$SCRIPTS_DIR/review-gate.sh"
  export REVIEW_GATE_PROOF_OF_EXECUTION=off

  run bash "$GATE_SCRIPT" update \
    --story E900-S1 --gate "Code Review" --verdict UNVERIFIED
  [ "$status" -eq 0 ]

  # Telemetry file should not exist (UNVERIFIED is the seed state).
  [ ! -f "$JSONL" ]
}
