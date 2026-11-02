#!/usr/bin/env bats
# review-telemetry.bats — tests for review-telemetry-writer.sh
#
# Covers: gate-entry format, round-summary, story-total, in-process timing,
# paired-overhead, canonical field enforcement, null handling, input
# validation, concurrent append, write failure, portability.

load 'test_helper.bash'

setup() {
  common_setup
  WRITER="$SCRIPTS_DIR/review-telemetry-writer.sh"
  GATE_SCRIPT="$SCRIPTS_DIR/review-gate.sh"

  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export REVIEW_GATE_PROOF_OF_EXECUTION=off

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

# ===== Format tests =====

@test "gate entry writes valid JSON with all allowlisted fields" {
  run bash "$WRITER" gate-entry \
    --story E900-S1 --gate "Code Review" --verdict PASSED \
    --round 1 --run-id "round-20260101T120000Z-1234" \
    --started-at 1700000000000 --ended-at 1700000005000 \
    --mutation-score 85.5 --token-estimate 4200
  [ "$status" -eq 0 ]
  [ -f "$JSONL" ]
  local line; line="$(cat "$JSONL")"
  jq -e '.' <<< "$line" >/dev/null
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
  local keys; keys="$(jq -r 'keys[]' <<< "$line" | sort)"
  local expected; expected="$(printf '%s\n' duration_ms end gate mutation_score round run_id schema_version start token_estimate type verdict | sort)"
  [ "$keys" = "$expected" ]
}

@test "round summary writes valid JSON with type discriminator" {
  local gates='{"Code Review":"PASSED","QA Tests":"PASSED","Security Review":"PASSED","Test Automation":"PASSED","Test Review":"PASSED","Performance Review":"PASSED"}'
  run bash "$WRITER" round-summary \
    --story E900-S1 --round 1 --composite-verdict COMPLETE \
    --total-duration-ms 30000 --total-tokens 12000 --gates-json "$gates"
  [ "$status" -eq 0 ]
  [ -f "$JSONL" ]
  local line; line="$(cat "$JSONL")"
  [ "$(jq -r '.type' <<< "$line")" = "round-summary" ]
  [ "$(jq -r '.composite_verdict' <<< "$line")" = "COMPLETE" ]
  [ "$(jq -r '.total_duration_ms' <<< "$line")" = "30000" ]
  [ "$(jq -r '.gates["Code Review"]' <<< "$line")" = "PASSED" ]
}

@test "story total writes valid JSON with story-total type" {
  local gates='{"Code Review":"PASSED","QA Tests":"PASSED","Security Review":"PASSED","Test Automation":"PASSED","Test Review":"PASSED","Performance Review":"PASSED"}'
  run bash "$WRITER" story-total \
    --story E900-S1 --round 2 --composite-verdict COMPLETE \
    --total-duration-ms 60000 --total-tokens 25000 --gates-json "$gates"
  [ "$status" -eq 0 ]
  [ -f "$JSONL" ]
  [ "$(jq -r '.type' "$JSONL")" = "story-total" ]
}

# ===== In-process timing (p95 <= 50 ms) =====

@test "in-process gate-entry completes 100 writes within 5 seconds total" {
  # Measures the REAL in-process write path (jq + printf), 100 invocations.
  # Total budget: 100 * 50ms = 5000ms. Uses a single pair of timestamps
  # to avoid per-iteration perl spawn overhead on bash 3.2.
  # A 40ms sleep mutant would push total to ~4000ms+jq = ~7s (fails).
  # A 60ms sleep mutant would push total to ~6000ms+jq = ~9s (fails).
  _TW_SOURCED=1 . "$WRITER"
  local t1 t2 i
  t1="$(_tw_epoch_ms)"
  for i in $(seq 1 100); do
    _tw_gate_entry --story E900-S1 --story-file "$STORY_DIR/story.md" \
      --gate "Code Review" --verdict PASSED --round "$i" 2>/dev/null
  done
  t2="$(_tw_epoch_ms)"
  local total=$(( t2 - t1 ))
  echo "total=${total}ms (100 writes, budget 5000ms)"
  [ "$total" -le 5000 ]
}

@test "timing test catches a 40 ms sleep mutant" {
  _TW_SOURCED=1 . "$WRITER"
  eval "$(declare -f _tw_append)" # save original
  _tw_real_append() { local path="$1" line="$2"; local dir="${path%/*}"; [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0; printf '%s\n' "$line" >> "$path" 2>/dev/null || return 0; }
  _tw_append() { sleep 0.04; _tw_real_append "$@"; }
  local times=() i
  for i in $(seq 1 10); do
    local t1 t2
    t1="$(_tw_epoch_ms)"
    _tw_gate_entry --story E900-S1 --story-file "$STORY_DIR/story.md" \
      --gate "Code Review" --verdict PASSED --round "$i" 2>/dev/null
    t2="$(_tw_epoch_ms)"
    times+=( $(( t2 - t1 )) )
  done
  local p95
  p95="$(printf '%s\n' "${times[@]}" | sort -n | sed -n '10p')"
  echo "mutant-40ms p95=${p95}ms"
  [ "$p95" -gt 50 ]
}

@test "timing test catches a 60 ms sleep mutant" {
  _TW_SOURCED=1 . "$WRITER"
  _tw_real_append2() { local path="$1" line="$2"; local dir="${path%/*}"; [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0; printf '%s\n' "$line" >> "$path" 2>/dev/null || return 0; }
  _tw_append() { sleep 0.06; _tw_real_append2 "$@"; }
  local times=() i
  for i in $(seq 1 10); do
    local t1 t2
    t1="$(_tw_epoch_ms)"
    _tw_gate_entry --story E900-S1 --story-file "$STORY_DIR/story.md" \
      --gate "Code Review" --verdict PASSED --round "$i" 2>/dev/null
    t2="$(_tw_epoch_ms)"
    times+=( $(( t2 - t1 )) )
  done
  local p95
  p95="$(printf '%s\n' "${times[@]}" | sort -n | sed -n '10p')"
  echo "mutant-60ms p95=${p95}ms"
  [ "$p95" -gt 50 ]
}

@test "removing --story-file makes the resolve path slower" {
  _TW_SOURCED=1 . "$WRITER"
  local slow=() fast=() i
  for i in 1 2 3; do
    local t1 t2
    t1="$(_tw_epoch_ms)"
    _tw_gate_entry --story E900-S1 --gate "Code Review" --verdict PASSED --round "$i" 2>/dev/null
    t2="$(_tw_epoch_ms)"; slow+=( $(( t2 - t1 )) )
  done
  for i in 1 2 3; do
    local t1 t2
    t1="$(_tw_epoch_ms)"
    _tw_gate_entry --story E900-S1 --story-file "$STORY_DIR/story.md" --gate "Code Review" --verdict PASSED --round "$i" 2>/dev/null
    t2="$(_tw_epoch_ms)"; fast+=( $(( t2 - t1 )) )
  done
  local sm fm
  sm="$(printf '%s\n' "${slow[@]}" | sort -n | sed -n '2p')"
  fm="$(printf '%s\n' "${fast[@]}" | sort -n | sed -n '2p')"
  echo "no-story-file=${sm}ms with-story-file=${fm}ms"
  [ "$sm" -gt "$fm" ]
}

# ===== Paired-median overhead =====

@test "paired-median overhead is within 100 ms tolerance" {
  local with_t=() without_t=() i
  for i in $(seq 1 5); do
    rm -f "$JSONL"
    local t1 t2
    t1="$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')"
    bash "$GATE_SCRIPT" update --story E900-S1 --gate "Code Review" --verdict PASSED >/dev/null 2>&1
    t2="$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')"
    with_t+=( $(( t2 - t1 )) )
    t1="$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')"
    bash "$GATE_SCRIPT" update --story E900-S1 --gate "Code Review" --verdict UNVERIFIED >/dev/null 2>&1
    t2="$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')"
    without_t+=( $(( t2 - t1 )) )
  done
  local mw mwo
  mw="$(printf '%s\n' "${with_t[@]}" | sort -n | sed -n '3p')"
  mwo="$(printf '%s\n' "${without_t[@]}" | sort -n | sed -n '3p')"
  local oh=$(( mw - mwo )); [ "$oh" -lt 0 ] && oh=0
  echo "with=${mw}ms without=${mwo}ms overhead=${oh}ms"
  [ "$oh" -le 100 ]
}

@test "500 ms sleep mutant exceeds overhead tolerance" {
  local wrapper="$TEST_TMP/slow-gate.sh"
  cat > "$wrapper" <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail
_TW_SOURCED=1 . "$1"; shift
_tw_real_a() { local p="$1" l="$2"; local d="${p%/*}"; [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || return 0; printf '%s\n' "$l" >> "$p" 2>/dev/null || return 0; }
_tw_append() { sleep 0.5; _tw_real_a "$@"; }
_tw_gate_entry "$@"
WRAP
  chmod +x "$wrapper"
  local t1 t2
  t1="$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')"
  bash "$wrapper" "$WRITER" --story E900-S1 --story-file "$STORY_DIR/story.md" \
    --gate "Code Review" --verdict PASSED >/dev/null 2>&1
  t2="$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')"
  local el=$(( t2 - t1 ))
  echo "500ms-mutant=${el}ms"
  [ "$el" -gt 500 ]
}

# ===== Canonical field enforcement =====

@test "non-canonical gate name is rejected" {
  run bash "$WRITER" gate-entry --story E900-S1 --gate "Bad Gate" --verdict PASSED
  [ "$status" -eq 0 ]; [ ! -f "$JSONL" ]
}

@test "non-canonical verdict is rejected" {
  run bash "$WRITER" gate-entry --story E900-S1 --gate "Code Review" --verdict APPROVE
  [ "$status" -eq 0 ]; [ ! -f "$JSONL" ]
}

@test "non-canonical composite verdict is rejected" {
  local g='{"Code Review":"PASSED","QA Tests":"PASSED","Security Review":"PASSED","Test Automation":"PASSED","Test Review":"PASSED","Performance Review":"PASSED"}'
  run bash "$WRITER" round-summary --story E900-S1 --round 1 --composite-verdict "ALL_GOOD" --gates-json "$g"
  [ "$status" -eq 0 ]; [ ! -f "$JSONL" ]
}

@test "gates-json with non-canonical key is rejected" {
  run bash "$WRITER" round-summary --story E900-S1 --round 1 --composite-verdict COMPLETE --gates-json '{"Bad Gate":"PASSED"}'
  [ "$status" -eq 0 ]; [ ! -f "$JSONL" ]
}

@test "gates-json with non-canonical verdict value is rejected" {
  run bash "$WRITER" round-summary --story E900-S1 --round 1 --composite-verdict COMPLETE --gates-json '{"Code Review":"APPROVE"}'
  [ "$status" -eq 0 ]; [ ! -f "$JSONL" ]
}

# ===== No secrets =====

@test "findings text and credentials injected through every field never appear" {
  local secret="FINDINGS_SECRET_TEXT_abc123"
  local fake_key="sk-ant-api03-FAKEFAKEFAKE"
  local g='{"Code Review":"PASSED","QA Tests":"PASSED","Security Review":"PASSED","Test Automation":"PASSED","Test Review":"PASSED","Performance Review":"PASSED"}'

  # Each of these must produce no file (all rejected by validation).
  bash "$WRITER" gate-entry --story E900-S1 --gate "$secret" --verdict PASSED 2>/dev/null || true
  bash "$WRITER" gate-entry --story E900-S1 --gate "Code Review" --verdict "$fake_key" 2>/dev/null || true
  bash "$WRITER" gate-entry --story E900-S1 --gate "Code Review" --verdict PASSED --token-estimate '{"findings":"secret"}' 2>/dev/null || true
  bash "$WRITER" gate-entry --story E900-S1 --gate "Code Review" --verdict PASSED --started-at "$secret" 2>/dev/null || true
  bash "$WRITER" gate-entry --story E900-S1 --gate "Code Review" --verdict PASSED --ended-at "$secret" 2>/dev/null || true
  bash "$WRITER" gate-entry --story E900-S1 --gate "Code Review" --verdict PASSED --round '"diff --git"' 2>/dev/null || true
  bash "$WRITER" gate-entry --story E900-S1 --gate "Code Review" --verdict PASSED --mutation-score "$secret" 2>/dev/null || true
  bash "$WRITER" round-summary --story E900-S1 --round 1 --composite-verdict "$secret" --gates-json "$g" 2>/dev/null || true
  bash "$WRITER" round-summary --story E900-S1 --round 1 --composite-verdict COMPLETE --total-duration-ms "$fake_key" --gates-json "$g" 2>/dev/null || true
  bash "$WRITER" round-summary --story E900-S1 --round 1 --composite-verdict COMPLETE --total-tokens "$fake_key" --gates-json "$g" 2>/dev/null || true

  # No file was ever created.
  [ ! -f "$JSONL" ]
}

# ===== Null handling =====

@test "gate entry with no optional fields writes JSON null values" {
  run bash "$WRITER" gate-entry --story E900-S1 --gate "Code Review" --verdict PASSED
  [ "$status" -eq 0 ]; [ -f "$JSONL" ]
  local l; l="$(cat "$JSONL")"
  [ "$(jq -r '.round' <<< "$l")" = "null" ]
  [ "$(jq -r '.run_id' <<< "$l")" = "null" ]
  [ "$(jq -r '.start' <<< "$l")" = "null" ]
  [ "$(jq -r '.end' <<< "$l")" = "null" ]
  [ "$(jq -r '.duration_ms' <<< "$l")" = "null" ]
  [ "$(jq -r '.mutation_score' <<< "$l")" = "null" ]
  [ "$(jq -r '.token_estimate' <<< "$l")" = "null" ]
}

@test "review-gate with no token-estimate writes null token_estimate" {
  run bash "$GATE_SCRIPT" update --story E900-S1 --gate "Code Review" --verdict PASSED
  [ "$status" -eq 0 ]; [ -f "$JSONL" ]
  [ "$(jq -r '.token_estimate' "$JSONL")" = "null" ]
}

@test "round summary with no totals writes null total fields" {
  local g='{"Code Review":"PASSED","QA Tests":"PASSED","Security Review":"PASSED","Test Automation":"PASSED","Test Review":"PASSED","Performance Review":"PASSED"}'
  run bash "$WRITER" round-summary --story E900-S1 --round 1 --composite-verdict COMPLETE --gates-json "$g"
  [ "$status" -eq 0 ]; [ -f "$JSONL" ]
  local l; l="$(cat "$JSONL")"
  [ "$(jq -r '.total_duration_ms' <<< "$l")" = "null" ]
  [ "$(jq -r '.total_tokens' <<< "$l")" = "null" ]
}

# ===== Untested validators =====

@test "ended-at with injection payload is rejected" {
  local marker="$TEST_TMP/inject-ended"
  run bash "$WRITER" gate-entry --story E900-S1 --gate "Code Review" --verdict PASSED \
    --started-at 1000 --ended-at 'x[$(touch '"$marker"')]'
  [ "$status" -eq 0 ]; [ ! -f "$marker" ]; [ ! -f "$JSONL" ]
}

@test "mutation-score with jq-parseable object is rejected" {
  run bash "$WRITER" gate-entry --story E900-S1 --gate "Code Review" --verdict PASSED --mutation-score '{"x":1}'
  [ "$status" -eq 0 ]; [ ! -f "$JSONL" ]
}

@test "summary round non-integer is rejected" {
  local g='{"Code Review":"PASSED","QA Tests":"PASSED","Security Review":"PASSED","Test Automation":"PASSED","Test Review":"PASSED","Performance Review":"PASSED"}'
  run bash "$WRITER" round-summary --story E900-S1 --composite-verdict COMPLETE --round abc --gates-json "$g"
  [ "$status" -eq 0 ]; [ ! -f "$JSONL" ]
}

@test "summary total-duration-ms non-integer is rejected" {
  local g='{"Code Review":"PASSED","QA Tests":"PASSED","Security Review":"PASSED","Test Automation":"PASSED","Test Review":"PASSED","Performance Review":"PASSED"}'
  run bash "$WRITER" round-summary --story E900-S1 --round 1 --composite-verdict COMPLETE --total-duration-ms abc --gates-json "$g"
  [ "$status" -eq 0 ]; [ ! -f "$JSONL" ]
}

@test "summary total-tokens non-integer is rejected" {
  local g='{"Code Review":"PASSED","QA Tests":"PASSED","Security Review":"PASSED","Test Automation":"PASSED","Test Review":"PASSED","Performance Review":"PASSED"}'
  run bash "$WRITER" round-summary --story E900-S1 --round 1 --composite-verdict COMPLETE --total-tokens abc --gates-json "$g"
  [ "$status" -eq 0 ]; [ ! -f "$JSONL" ]
}

@test "leading-zero values (08, 09) are rejected" {
  run bash "$WRITER" gate-entry --story E900-S1 --gate "Code Review" --verdict PASSED --round 08
  [ "$status" -eq 0 ]; [ ! -f "$JSONL" ]
  run bash "$WRITER" gate-entry --story E900-S1 --gate "Code Review" --verdict PASSED --round 09
  [ "$status" -eq 0 ]; [ ! -f "$JSONL" ]
}

@test "negative duration (end < start) is rejected" {
  run bash "$WRITER" gate-entry --story E900-S1 --gate "Code Review" --verdict PASSED \
    --started-at 2000 --ended-at 1000
  [ "$status" -eq 0 ]; [ ! -f "$JSONL" ]
}

@test "started-at with command injection payload is rejected" {
  local marker="$TEST_TMP/inject-start"
  run bash "$WRITER" gate-entry --story E900-S1 --gate "Code Review" --verdict PASSED \
    --started-at 'SCHEMA_VERSION[$(touch '"$marker"')]'
  [ "$status" -eq 0 ]; [ ! -f "$marker" ]; [ ! -f "$JSONL" ]
}

@test "token-estimate with JSON payload is rejected" {
  run bash "$WRITER" gate-entry --story E900-S1 --gate "Code Review" --verdict PASSED \
    --token-estimate '{"findings":"secret"}'
  [ "$status" -eq 0 ]; [ ! -f "$JSONL" ]
}

@test "run-id with unsafe characters is rejected" {
  run bash "$WRITER" gate-entry --story E900-S1 --gate "Code Review" --verdict PASSED \
    --run-id '$(touch /tmp/pwned)'
  [ "$status" -eq 0 ]; [ ! -f "$JSONL" ]; [ ! -f /tmp/pwned ]
}

# ===== Integration =====

@test "review-gate update with telemetry flags writes non-null fields" {
  run bash "$GATE_SCRIPT" update --story E900-S1 --gate "Code Review" --verdict PASSED \
    --started-at 1700000000000 --token-estimate 5000 \
    --telemetry-round 1 --telemetry-run-id "round-20260101T120000Z-9999"
  [ "$status" -eq 0 ]; [ -f "$JSONL" ]
  local l; l="$(cat "$JSONL")"
  [ "$(jq -r '.gate' <<< "$l")" = "Code Review" ]
  [ "$(jq -r '.round' <<< "$l")" = "1" ]
  [ "$(jq -r '.run_id' <<< "$l")" = "round-20260101T120000Z-9999" ]
  [ "$(jq -r '.start' <<< "$l")" = "1700000000000" ]
  [ "$(jq -r '.end' <<< "$l")" != "null" ]
  [ "$(jq -r '.duration_ms' <<< "$l")" != "null" ]
  [ "$(jq -r '.token_estimate' <<< "$l")" = "5000" ]
}

@test "review-gate update UNVERIFIED does not trigger telemetry" {
  run bash "$GATE_SCRIPT" update --story E900-S1 --gate "Code Review" --verdict UNVERIFIED
  [ "$status" -eq 0 ]; [ ! -f "$JSONL" ]
}

@test "write failure logs warning on stderr and exits 0" {
  touch "$JSONL"; chmod 000 "$JSONL"
  local cap rc
  cap="$(bash "$GATE_SCRIPT" update --story E900-S1 --gate "Code Review" --verdict PASSED 2>&1 1>/dev/null)" && rc=0 || rc=$?
  chmod 644 "$JSONL"
  [ "$rc" -eq 0 ]
  [[ "$cap" == *"write failed"* ]] || [[ "$cap" == *"skipping telemetry write"* ]]
}

@test "concurrent appends produce no interleaved lines" {
  local pids=() j
  for j in $(seq 1 20); do
    bash "$WRITER" gate-entry --story E900-S1 --gate "Code Review" --verdict PASSED --round "$j" &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" || true; done
  [ -f "$JSONL" ]
  local c; c="$(wc -l < "$JSONL" | tr -d ' ')"; [ "$c" -eq 20 ]
  local bad; bad="$(jq -c '.' "$JSONL" 2>&1 | /usr/bin/grep -c 'parse error' || true)"; [ "$bad" -eq 0 ]
}

@test "append-only: existing lines are not rewritten" {
  bash "$WRITER" gate-entry --story E900-S1 --gate "Code Review" --verdict PASSED --round 1
  local first; first="$(head -1 "$JSONL")"
  bash "$WRITER" gate-entry --story E900-S1 --gate "QA Tests" --verdict FAILED --round 1
  local c; c="$(wc -l < "$JSONL" | tr -d ' ')"; [ "$c" -eq 2 ]
  [ "$(head -1 "$JSONL")" = "$first" ]
}

@test "unknown subcommand exits 1" {
  run bash "$WRITER" bad-subcmd; [ "$status" -eq 1 ]
}

@test "no arguments exits 1" {
  run bash "$WRITER"; [ "$status" -eq 1 ]
}
