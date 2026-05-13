#!/usr/bin/env bats
# val-gate-fail-closed.bats — coverage for E83-S1 (sentinel checkpoint primitive
# + AskUserQuestion precondition) for /gaia-add-feature.
#
# Story: E83-S1 — Sentinel checkpoint primitive + AskUserQuestion precondition
#
# Test cases (TC-VFC-*):
#   TC-VFC-1: happy path — sentinel written; finalize.sh exits 0
#   TC-VFC-2: bypass — sentinel missing; finalize.sh exits non-zero with
#             stderr matching "Val gate sentinel missing.*re-invoke from a
#             parent orchestrator thread"
#   TC-VFC-3: malformed sentinel (missing status, invalid enum) — exit non-zero
#             with stderr identifying the missing key or invalid value
#   TC-VFC-4: static check — sentinel-writer reuses checkpoint.sh foundation;
#             zero `cat <<EOF` / heredoc-JSON patterns in scripts/
#   TC-VFC-5: concurrent writes — every reader sees a complete JSON
#   TC-VFC-7: static check — AskUserQuestion is sole interactive boundary
#             primitive in SKILL.md Step 2 (no Stop hooks, stdout sentinels,
#             pause-and-wait scripts)
#
# TC-VFC-6 is a manual transcript-inspection case (Auto Mode harness halt) —
# documented but not in bats.

load 'test_helper.bash'

setup() {
  common_setup
  ADD_FEATURE_SCRIPTS="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-add-feature/scripts" && pwd)"
  ADD_FEATURE_SKILL="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-add-feature" && pwd)/SKILL.md"
  WRITE_SENTINEL="$ADD_FEATURE_SCRIPTS/write-val-sentinel.sh"
  FINALIZE="$ADD_FEATURE_SCRIPTS/finalize.sh"

  cd "$TEST_TMP"
  mkdir -p _memory/checkpoints docs/planning-artifacts docs/test-artifacts

  # Minimal config so resolve-config.sh / checkpoint.sh have somewhere to write.
  export CHECKPOINT_PATH="$TEST_TMP/_memory/checkpoints"
  export PROJECT_PATH="$TEST_TMP"
  export PLANNING_ARTIFACTS="$TEST_TMP/docs/planning-artifacts"
  export TEST_ARTIFACTS="$TEST_TMP/docs/test-artifacts"

  # Seed prereqs so finalize.sh prerequisites do not derail the gate test.
  : > "$PLANNING_ARTIFACTS/prd.md"
  : > "$PLANNING_ARTIFACTS/epics-and-stories.md"
}

teardown() { common_teardown; }

_well_formed_payload() {
  cat <<'EOF'
{
  "schema_version": "1.0",
  "feature_id": "AF-2026-05-10-1",
  "skill": "gaia-add-feature",
  "agent": "val",
  "status": "PASS",
  "summary": "OK",
  "findings": [],
  "next": "PROCEED_CASCADE"
}
EOF
}

# ---------------------------------------------------------------------------
# TC-VFC-1 — happy path
# ---------------------------------------------------------------------------

@test "TC-VFC-1: write-val-sentinel.sh writes the canonical sentinel JSON" {
  [ -x "$WRITE_SENTINEL" ] || skip "write-val-sentinel.sh not yet implemented"
  payload="$(_well_formed_payload)"
  run "$WRITE_SENTINEL" --feature-id AF-2026-05-10-1 --payload-stdin <<<"$payload"
  [ "$status" -eq 0 ]
  sentinel="$CHECKPOINT_PATH/add-feature-AF-2026-05-10-1-val-dispatched.json"
  [ -f "$sentinel" ]
  # Required keys per AC1
  run jq -e '.status and .summary and .findings and .agent == "val"' "$sentinel"
  [ "$status" -eq 0 ]
}

@test "TC-VFC-1: finalize.sh PASSes when the sentinel exists and is well-formed" {
  [ -x "$WRITE_SENTINEL" ] || skip "write-val-sentinel.sh not yet implemented"
  payload="$(_well_formed_payload)"
  "$WRITE_SENTINEL" --feature-id AF-2026-05-10-1 --payload-stdin <<<"$payload"
  export FEATURE_ID="AF-2026-05-10-1"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# TC-VFC-2 — bypass: sentinel missing
# ---------------------------------------------------------------------------

@test "TC-VFC-2: finalize.sh fails non-zero when sentinel is missing" {
  export FEATURE_ID="AF-2026-05-10-2"
  # No sentinel written.
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Val gate sentinel missing"* ]]
  [[ "$output" == *"re-invoke from a parent orchestrator thread"* ]]
}

@test "TC-VFC-2: finalize.sh fails non-zero when sentinel is deleted before run" {
  [ -x "$WRITE_SENTINEL" ] || skip "write-val-sentinel.sh not yet implemented"
  payload="$(_well_formed_payload)"
  "$WRITE_SENTINEL" --feature-id AF-2026-05-10-3 <<<"$payload"
  rm -f "$CHECKPOINT_PATH/add-feature-AF-2026-05-10-3-val-dispatched.json"
  export FEATURE_ID="AF-2026-05-10-3"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Val gate sentinel missing"* ]]
}

# ---------------------------------------------------------------------------
# TC-VFC-3 — malformed sentinel
# ---------------------------------------------------------------------------

@test "TC-VFC-3: finalize.sh rejects sentinel missing the status key" {
  export FEATURE_ID="AF-2026-05-10-4"
  printf '%s\n' '{"summary":"x","findings":[],"agent":"val"}' \
    > "$CHECKPOINT_PATH/add-feature-AF-2026-05-10-4-val-dispatched.json"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"status"* ]]
}

@test "TC-VFC-3: finalize.sh rejects sentinel with invalid status enum" {
  export FEATURE_ID="AF-2026-05-10-5"
  printf '%s\n' '{"status":"FAKE","summary":"x","findings":[],"agent":"val"}' \
    > "$CHECKPOINT_PATH/add-feature-AF-2026-05-10-5-val-dispatched.json"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAKE"* || "$output" == *"status"* ]]
}

@test "TC-VFC-3: finalize.sh rejects sentinel with wrong agent value" {
  export FEATURE_ID="AF-2026-05-10-6"
  printf '%s\n' '{"status":"PASS","summary":"x","findings":[],"agent":"impostor"}' \
    > "$CHECKPOINT_PATH/add-feature-AF-2026-05-10-6-val-dispatched.json"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent"* ]]
}

@test "TC-VFC-3: finalize.sh rejects sentinel missing the findings array" {
  export FEATURE_ID="AF-2026-05-10-7"
  printf '%s\n' '{"status":"PASS","summary":"x","agent":"val"}' \
    > "$CHECKPOINT_PATH/add-feature-AF-2026-05-10-7-val-dispatched.json"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"findings"* ]]
}

# ---------------------------------------------------------------------------
# TC-VFC-4 — static check: no hand-rolled JSON via heredoc/printf
# ---------------------------------------------------------------------------

@test "TC-VFC-4: sentinel-writer scripts contain no 'cat <<EOF' JSON" {
  # Scan only sentinel-write paths — finalize.sh and write-val-sentinel.sh.
  # We exclude setup.sh (no JSON write) and any future scripts via explicit list.
  for f in "$ADD_FEATURE_SCRIPTS/finalize.sh" "$WRITE_SENTINEL"; do
    [ -f "$f" ] || continue
    # Forbid `cat <<EOF` immediately followed by `{` JSON pattern, OR `printf '{'`.
    run grep -nE "cat[[:space:]]+<<.*EOF" "$f"
    [ "$status" -ne 0 ] || {
      # If a heredoc is present, ensure it is NOT used to construct JSON.
      run grep -B1 -A1 -nE "cat[[:space:]]+<<.*EOF" "$f"
      [[ "$output" != *'"status"'* ]]
      [[ "$output" != *'"agent"'* ]]
    }
    run grep -nE "printf[[:space:]]+'\\{" "$f"
    [ "$status" -ne 0 ]
  done
}

@test "TC-VFC-4: sentinel-writer invokes jq for JSON construction" {
  [ -f "$WRITE_SENTINEL" ] || skip "write-val-sentinel.sh not yet implemented"
  run grep -E "\\bjq\\b" "$WRITE_SENTINEL"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# TC-VFC-5 — concurrent writes: atomic
# ---------------------------------------------------------------------------

@test "TC-VFC-5: parallel writers + readers see only complete JSON" {
  [ -x "$WRITE_SENTINEL" ] || skip "write-val-sentinel.sh not yet implemented"
  # Skip on systems where flock isn't available — atomicity then relies on
  # mv-rename which is still POSIX-atomic on the same filesystem.
  feature_id="AF-2026-05-10-CONCUR"
  sentinel="$CHECKPOINT_PATH/add-feature-${feature_id}-val-dispatched.json"

  payload="$(_well_formed_payload)"

  # Writer loop — N=20 writes
  (
    for i in $(seq 1 20); do
      "$WRITE_SENTINEL" --feature-id "$feature_id" <<<"$payload" 2>/dev/null
    done
  ) &
  writer_pid=$!

  # Reader loop — read 30 times in parallel; each parse must succeed once
  # the file exists. Collect failures.
  failures=0
  for i in $(seq 1 30); do
    if [ -f "$sentinel" ]; then
      if ! jq -e '.status' "$sentinel" >/dev/null 2>&1; then
        failures=$((failures + 1))
      fi
    fi
  done

  wait "$writer_pid" 2>/dev/null || true

  # Final sentinel must be parseable.
  run jq -e '.status' "$sentinel"
  [ "$status" -eq 0 ]
  [ "$failures" -eq 0 ]
}

# ---------------------------------------------------------------------------
# TC-VFC-7 — static check: AskUserQuestion is sole interactive primitive
# ---------------------------------------------------------------------------

@test "TC-VFC-7: SKILL.md Step 2 contains AskUserQuestion precondition" {
  [ -f "$ADD_FEATURE_SKILL" ] || skip "SKILL.md not present"
  # Scoped to Step 2 — extract Step 2 region between '### Step 2' and '### Step 3'.
  run awk '/^### Step 2/{flag=1} /^### Step 3/{flag=0} flag' "$ADD_FEATURE_SKILL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AskUserQuestion"* ]]
}

@test "TC-VFC-7: SKILL.md Step 2 contains no stdout-sentinel anti-patterns" {
  [ -f "$ADD_FEATURE_SKILL" ] || skip "SKILL.md not present"
  # Step 2 region — must NOT mention legacy interactive primitives.
  step2="$(awk '/^### Step 2/{flag=1} /^### Step 3/{flag=0} flag' "$ADD_FEATURE_SKILL")"
  # No Stop-hook references
  [[ "$step2" != *"Stop hook"* ]]
  [[ "$step2" != *"PreToolUse"* ]]
  # No pause-and-wait anti-pattern
  [[ "$step2" != *"pause-and-wait"* ]]
  # No stdout sentinel anti-pattern (gaia-meeting precedent)
  [[ "$step2" != *"stdout sentinel"* ]]
  [[ "$step2" != *"YIELD_FOR_USER"* ]]
}

@test "TC-VFC-7: SKILL.md Critical Rules lists sentinel + AskUserQuestion" {
  [ -f "$ADD_FEATURE_SKILL" ] || skip "SKILL.md not present"
  # Extract Critical Rules region.
  rules="$(awk '/^## Critical Rules/{flag=1} /^## Subagent Dispatch Contract/{flag=0} flag' "$ADD_FEATURE_SKILL")"
  [[ "$rules" == *"sentinel"* ]] || [[ "$rules" == *"Sentinel"* ]]
  [[ "$rules" == *"AskUserQuestion"* ]]
}

# ---------------------------------------------------------------------------
# TC-VFC-8 — static check: forbidden-pattern clause for "patch-mode exception"
# ---------------------------------------------------------------------------
# E83-S2: SKILL.md prose hardening — forbid auto-judge patterns.
# These tests assert the load-bearing strings that close the AF-2026-05-09-3
# and AF-2026-05-09-4 self-license bypass class. The wording is intentional —
# E83-S3's bats anti-pattern check will fail the build if the strings drift.

@test "TC-VFC-8: SKILL.md Step 2 prose forbids the patch-mode exception" {
  [ -f "$ADD_FEATURE_SKILL" ] || skip "SKILL.md not present"
  # Step 2 region must contain the explicit forbidden-pattern clause.
  step2="$(awk '/^### Step 2/{flag=1} /^### Step 3/{flag=0} flag' "$ADD_FEATURE_SKILL")"
  printf '%s\n' "$step2" | grep -Eq '[Tt]here is NO patch-mode exception'
}

@test "TC-VFC-8: SKILL.md does not license auto-judging in patch mode" {
  [ -f "$ADD_FEATURE_SKILL" ] || skip "SKILL.md not present"
  # Negative guard — the AF-2026-05-09-3 bypass phrase must NOT appear as license.
  run grep -F "auto-judged in patch mode" "$ADD_FEATURE_SKILL"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# TC-VFC-9 — static check: Agent-tool dispatch requirement + parent-thread halt
# ---------------------------------------------------------------------------

@test "POST-E87-S5: SKILL.md Step 2 prose mandates Agent-tool dispatch with main-turn dispatch (ADR-104)" {
  # Originally pinned `Val MUST be dispatched as a context: fork subagent`
  # (E83-S2 / AI-2026-05-09-12). E87-S5 (Val Bridge Migration, ADR-104)
  # migrates the dispatch model to main-turn Agent-tool dispatch. The two
  # sibling TC-VFC-9 @test blocks below (parent-thread HALT, no-inline-Val
  # license) preserve the dispatch-FAILURE semantics verbatim — only this
  # @test block flips the dispatch-MODEL vocabulary from `context: fork`
  # literal to `main-turn Agent tool` semantic equivalent.
  [ -f "$ADD_FEATURE_SKILL" ] || skip "SKILL.md not present"
  step2="$(awk '/^### Step 2/{flag=1} /^### Step 3/{flag=0} flag' "$ADD_FEATURE_SKILL")"
  printf '%s\n' "$step2" | grep -Eq 'Val MUST be dispatched via the .*main-turn Agent tool'
}

@test "TC-VFC-9: SKILL.md Step 2 contains parent-thread re-invoke HALT instruction" {
  [ -f "$ADD_FEATURE_SKILL" ] || skip "SKILL.md not present"
  step2="$(awk '/^### Step 2/{flag=1} /^### Step 3/{flag=0} flag' "$ADD_FEATURE_SKILL")"
  printf '%s\n' "$step2" | grep -Eq 're-invoke .* from a parent orchestrator thread'
}

@test "TC-VFC-9: SKILL.md Step 2 prose does not license inline-Val verdicts" {
  [ -f "$ADD_FEATURE_SKILL" ] || skip "SKILL.md not present"
  step2="$(awk '/^### Step 2/{flag=1} /^### Step 3/{flag=0} flag' "$ADD_FEATURE_SKILL")"
  # Negative guard — no sentence licensing inline review as a Val verdict.
  ! printf '%s\n' "$step2" | grep -Eqi 'inline.*Val.*verdict'
}

# ---------------------------------------------------------------------------
# Critical Rules — cite AI-2026-05-09-12 precedent (E83-S2 AC4)
# ---------------------------------------------------------------------------

@test "TC-VFC-8/9: SKILL.md Critical Rules cites AI-2026-05-09-12 precedent" {
  [ -f "$ADD_FEATURE_SKILL" ] || skip "SKILL.md not present"
  rules="$(awk '/^## Critical Rules/{flag=1} /^## Subagent Dispatch Contract/{flag=0} flag' "$ADD_FEATURE_SKILL")"
  [[ "$rules" == *"AI-2026-05-09-12"* ]]
  [[ "$rules" == *"no patch-mode exception"* ]] || [[ "$rules" == *"NO patch-mode exception"* ]]
  [[ "$rules" == *"no inline Val"* ]] || [[ "$rules" == *"inline Val"* ]]
}
