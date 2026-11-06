#!/usr/bin/env bats
# mutation-end-to-end.bats — drives the mutation feature through real tools.
#
# Nothing here stubs yq, jq, bats, patch or the findings register: the fixture
# is a real git project with a real project-config, so a parser or wiring fault
# in any producer or consumer turns these tests red.

load '../test_helper.bash'

# Keeps a literal test keyword off column 0 in this source (it would inflate
# the plan count) while the generated file is valid bats.
_bats_fixture() {
  local outfile="$1"; shift
  local kw='@test'
  mkdir -p "$(dirname "$outfile")"
  printf '#!/usr/bin/env bats\n' > "$outfile"
  while [ $# -ge 2 ]; do
    printf '%s "%s" {\n%s\n}\n' "$kw" "$1" "$2" >> "$outfile"
    shift 2
  done
}

_commit_all() {
  git -C "$PROJ" add -A
  git -C "$PROJ" commit -q -m "${1:-fixture}"
}

_write_config() {
  mkdir -p "$PROJ/.gaia/config"
  printf '%s\n' "$1" > "$PROJ/.gaia/config/project-config.yaml"
}

# _mk_project <priority> [thresholds-yaml-lines]
_mk_project() {
  local prio="$1"
  local thresholds="${2:-    P0: 80
    P1: 60}"
  mkdir -p "$PROJ/scripts" "$PROJ/tests"
  git -C "$PROJ" init -q
  git -C "$PROJ" config user.email "test@test.local"
  git -C "$PROJ" config user.name "Test"
  cat > "$PROJ/scripts/calc.sh" <<'SRC'
#!/usr/bin/env bash
is_one() {
  if [ "$1" -eq 1 ]; then
    return 0
  fi
  return 1
}
is_big() {
  [ "$1" -gt 100 ]
}
SRC
  _bats_fixture "$PROJ/tests/calc.bats" \
    'is_one accepts one' '  . "$BATS_TEST_DIRNAME/../scripts/calc.sh"; run is_one 1; [ "$status" -eq 0 ]' \
    'is_one rejects two' '  . "$BATS_TEST_DIRNAME/../scripts/calc.sh"; run is_one 2; [ "$status" -eq 1 ]' \
    'calc noop' '  true'
  _write_config "project_name: demo
test_execution:
  mutation_thresholds:
$thresholds"
  STORY_DIR="$PROJ/.gaia/artifacts/implementation-artifacts/epic-E9-demo/E9-S1-demo"
  mkdir -p "$STORY_DIR"
  cat > "$STORY_DIR/story.md" <<STORY
---
template: 'story'
key: "E9-S1"
title: "demo"
epic: "E9"
status: review
priority: "$prio"
---

# Story: demo

## Dev Agent Record

### File List

- \`scripts/calc.sh\` — the source, with a flag called \`--unrelated\`
- \`tests/calc.bats\` — NEW

## Findings

| # | Type | Severity | Finding | Suggested Action |
|---|------|----------|---------|-----------------|

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
  mkdir -p "$PROJ/.gaia/artifacts/test-artifacts/test-results"
  printf 'keep\n' > "$PROJ/.gaia/artifacts/test-artifacts/test-results/.keep"
  _commit_all init
  EV="$PROJ/.gaia/artifacts/test-artifacts/test-results/E9-S1-mutation.json"
  CFG="$PROJ/.gaia/config/project-config.yaml"
}

_mutation_subcmd() {
  (cd "$PROJ" && "$PLUGIN/skills/gaia-test-automate/scripts/subcmd-mutation.sh" E9-S1 "$@")
}

_head() { git -C "$PROJ" rev-parse HEAD; }

# The verdict only: the resolver explains itself on stderr.
_verdict() { "$SCRIPTS/verdict-resolver.sh" "$@" 2>/dev/null; }

_analysis_empty() {
  printf '{"schema_version":"1.0","checks":[]}' > "$T/analysis.json"
  printf '{"findings":[]}' > "$T/llm.json"
}

# Minimal approved plan, ledger and test environment for the execution phase.
_phase2() {
  local plan="$T/plan.md" ledger="$T/ledger" tenv="$T/test-environment.yaml"
  cat > "$plan" <<PLAN
---
template: test-automate-plan
story_key: "E9-S1"
plan_id: "plan-1"
phase: approved
approval:
  verdict: "PASSED"
  verdict_plan_id: "plan-1"
analyzed_sources: []
proposed_tests: []
---

# Plan
PLAN
  printf '%s\t%s\t%s\t%s\n' E9-S1 test-automate-plan plan-1 PASSED > "$ledger"
  printf -- '---\ntier_directories:\n  - "%s"\n' "$PROJ/tests" > "$tenv"
  run "$PLUGIN/skills/gaia-test-automate/scripts/phase2-execute.sh" \
    --story E9-S1 --plan "$plan" --ledger "$ledger" --test-env "$tenv" --project-root "$PROJ"
}

# A copy of the plugin scripts with one extra adapter, so adapter contract
# paths can be driven without any test hook in the production runner.
_plugin_copy_with_adapter() {
  local name="$1" ext="$2" fmt="$3"
  mkdir -p "$T/plugin"
  cp -R "$PLUGIN/scripts" "$T/plugin/scripts"
  ADAPTER="$T/plugin/scripts/adapters/mutation-$name"
  mkdir -p "$ADAPTER"
  jq -n --arg e "$ext" --arg f "$fmt" --arg p "$name" \
    '{provider:$p,stack:$p,"file-extensions":[$e],"default-timeout-seconds":5,"version-range":">=0","mutant-format":$f,description:"fixture"}' \
    > "$ADAPTER/mutation-adapter.json"
  cat > "$ADAPTER/generate.sh" <<'GEN'
#!/usr/bin/env bash
set -euo pipefail
while [ $# -gt 0 ]; do case "$1" in --out-dir) out="$2"; shift 2;; --files-from) files="$2"; shift 2;; *) shift 2;; esac; done
f="$(head -1 "$files")"
printf '{}' > "$out/batch-1.json"
jq -n --arg f "$f" '[{mutant_id:"batch-1",batch_file:"batch-1.json",file:$f,line:1,operator:"native"}]' > "$out/index.json"
GEN
  chmod +x "$ADAPTER/generate.sh"
}

setup() {
  BATS_TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  PLUGIN="$(cd "$BATS_TEST_DIR/../.." && pwd)"
  SCRIPTS="$PLUGIN/scripts"
  RUNNER="$SCRIPTS/mutation-runner.sh"
  CHECKER="$SCRIPTS/review-common/mutation-evidence-check.sh"
  ADAPTER_RUN="$SCRIPTS/adapters/mutation-bash/run.sh"
  T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/mre2e-XXXXXX")" && pwd -P)"
  export TMPDIR="$T/tmp"
  mkdir -p "$TMPDIR"
  PROJ="$T/proj"
  mkdir -p "$PROJ"
  export PROJECT_ROOT="$PROJ" CLAUDE_PROJECT_ROOT="$PROJ" PROJECT_PATH="$PROJ"
  export GAIA_STATE_DIR="$T/state"
  mkdir -p "$GAIA_STATE_DIR"
  unset GAIA_TEST_ARTIFACTS IMPLEMENTATION_ARTIFACTS CLAUDE_SKILL_DIR || true
}

teardown() {
  rm -rf "$T"
}

# ---------- the required end-to-end proof ----------

@test "end to end with real tools yields exact killed and survived counts and one registered survivor" {
  _mk_project P1

  run _mutation_subcmd
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [ -f "$EV" ]

  [ "$(jq -c .totals "$EV")" = '{"mutants":4,"killed":3,"survived":1,"timeout":0,"error":0}' ]
  [ "$(jq -r .score "$EV")" = "75" ]
  [ "$(jq -r .gate "$EV")" = "passed" ]
  [ "$(jq -r .priority "$EV")" = "P1" ]
  [ "$(jq -r .commit_sha "$EV")" = "$(_head)" ]

  # The known survivor: nothing exercises is_big.
  [ "$(jq -r '[.mutants[]|select(.status=="survived")]|length' "$EV")" = "1" ]
  [ "$(jq -r '.mutants[]|select(.status=="survived")|.line' "$EV")" = "9" ]
  [ "$(jq -r '.mutants[]|select(.status=="survived")|.file' "$EV")" = "scripts/calc.sh" ]
  [ "$(jq -r '.mutants[]|select(.status=="survived")|.operator' "$EV")" = "comparison flip gt/le" ]

  # The known kills, each naming the real test that caught it.
  [ "$(jq -c '.mutants[]|select(.line==4)|.killed_by' "$EV")" = '["is_one accepts one"]' ]
  [ "$(jq -c '.mutants[]|select(.line==6)|.killed_by' "$EV")" = '["is_one rejects two"]' ]
  [ "$(jq -c '.mutants[]|select(.line==3)|.killed_by|sort' "$EV")" = '["is_one accepts one","is_one rejects two"]' ]

  # Survivor reached the real findings register exactly once, as a warning.
  local reg sid
  reg="$(cd "$PROJ" && "$SCRIPTS/resolve-review-report-path.sh" --key E9-S1 --type findings-register)"
  [ -f "$reg" ]
  sid="$(jq -r '.mutants[]|select(.status=="survived")|.mutant_id' "$EV")"
  [ "$(yq '.entries|length' "$reg")" = "1" ]
  [ "$(yq '.entries[0].dedup_key' "$reg")" = "mutant:$sid" ]
  [ "$(yq '.entries[0].severity // .entries[0].gate_ratings[0].severity' "$reg")" = "medium" ]
  [ "$(yq '.entries[0].blocking' "$reg")" = "false" ]

  # Evidence check with the real config value: a passing score at this HEAD.
  local thr
  thr="$(yq -o=json -I=0 '.test_execution.mutation_thresholds' "$CFG")"
  run "$CHECKER" --story-key E9-S1 --evidence "$EV" --commit "$(_head)" --priority P1 --thresholds "$thr" --zero-kill
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "passed" ]
  # Exactly the one test that killed nothing is reported, by its test name.
  [ "$(printf '%s' "$output" | jq -c '[.findings[].message]')" = '["weak-assertion: calc noop killed zero mutants"]' ]

  # Re-running the same mutants never duplicates the register entry.
  run _mutation_subcmd
  [ "$status" -eq 0 ]
  [ "$(yq '.entries|length' "$reg")" = "1" ]
  [ "$(jq -c .totals "$EV")" = '{"mutants":4,"killed":3,"survived":1,"timeout":0,"error":0}' ]
}

@test "end to end on a P0 story records the survivor as a blocking critical finding and fails the gate" {
  _mk_project P0
  run _mutation_subcmd
  [ "$status" -eq 0 ]
  [ "$(jq -r .gate "$EV")" = "failed" ]
  local reg
  reg="$(cd "$PROJ" && "$SCRIPTS/resolve-review-report-path.sh" --key E9-S1 --type findings-register)"
  [ "$(yq '.entries[0].blocking' "$reg")" = "true" ]
}

# ---------- yq parsing at every read site ----------

@test "yq read: runner --config honours configured thresholds" {
  _mk_project P1
  printf 'scripts/calc.sh\n' > "$T/f"; printf 'tests/calc.bats\n' > "$T/t"
  run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --config "$CFG" --priority P0
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.thresholds.P1' "$T/ev.json")" = "60" ]
  [ "$(jq -r .gate "$T/ev.json")" = "failed" ]
}

@test "yq read: doctor shows configured thresholds and the effective defaults" {
  _mk_project P1 "    P1: 50"
  run "$RUNNER" --doctor --config "$CFG"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Effective: P0=80 P1=50 P2=0 P3=0'* ]]
  [[ "$output" != *'is off'* ]]
}

@test "yq read: resolve-config surfaces the thresholds object and treats an empty object as present" {
  _mk_project P1
  run bash -c "cd '$PROJ' && '$SCRIPTS/resolve-config.sh' --field test_execution.mutation_thresholds"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c .)" = '{"P0":80,"P1":60}' ]
  _write_config 'project_name: demo
test_execution:
  mutation_thresholds: {}'
  run bash -c "cd '$PROJ' && '$SCRIPTS/resolve-config.sh' --field test_execution.mutation_thresholds"
  [ "$status" -eq 0 ]
  [ "$output" = '{}' ]
}

@test "yq read: a failing yq is reported, never treated as mutation testing off" {
  _mk_project P1
  mkdir -p "$T/badbin"
  printf '#!/bin/sh\necho "broken yq" >&2\nexit 3\n' > "$T/badbin/yq"
  chmod +x "$T/badbin/yq"
  printf 'scripts/calc.sh\n' > "$T/f"; printf 'tests/calc.bats\n' > "$T/t"

  PATH="$T/badbin:$PATH" run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --config "$CFG"
  [ "$status" -ne 0 ]
  [[ "$output" == *yq* ]]
  [ ! -f "$T/ev.json" ]

  PATH="$T/badbin:$PATH" run _mutation_subcmd
  [ "$status" -ne 0 ]
  [[ "$output" == *yq* ]]
}

@test "yq read: a comment that mentions the key does not switch anything on or fail" {
  _mk_project P1
  _write_config 'project_name: demo
# mutation_thresholds: not set here
test_execution: {}'
  run _mutation_subcmd
  [ "$status" -eq 0 ]
  [ ! -f "$EV" ]
}

# ---------- automatic run from the execution phase ----------

@test "automatic run fires for a story in the per-story layout after a green execution" {
  _mk_project P1
  _phase2
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [ -f "$EV" ]
  [ "$(jq -c .totals "$EV")" = '{"mutants":4,"killed":3,"survived":1,"timeout":0,"error":0}' ]
  [ "$(dirname "$EV")" = "$PROJ/.gaia/artifacts/test-artifacts/test-results" ]
  [ -f "$PROJ/.gaia/artifacts/test-artifacts/test-results/E9-S1-execution.json" ]
}

@test "automatic run does not wait on the slot its own execution step holds" {
  _mk_project P1
  printf 'review:\n  max_concurrent_heavy_reviewers: 1\n' >> "$CFG"
  _commit_all oneslot
  GAIA_REVIEW_SEMAPHORE_WAIT_SECS=3 _phase2
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *runner_unavailable* ]]
  [ "$(jq -r .totals.mutants "$EV")" = "4" ]
}

@test "automatic run stays off when thresholds are absent" {
  _mk_project P1
  _write_config 'project_name: demo'
  _phase2
  [ "$status" -eq 0 ]
  [ ! -f "$EV" ]
  [[ "$output" != *runner_unavailable* ]]
}

@test "runner failure in the execution phase records runner_unavailable and the action verdict is BLOCKED" {
  _mk_project P1
  # A red baseline makes the mutation run unable to produce a score.
  _bats_fixture "$PROJ/tests/calc.bats" 'always red calc.sh' '  false'
  _commit_all red
  _phase2
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *'blocking_failure: runner_unavailable'* ]]
  grep -q 'blocking_failure: runner_unavailable' "$T/plan.md"
  local ee="$PROJ/.gaia/artifacts/test-artifacts/test-results/E9-S1-execution.json"
  [ "$(jq -r .blocking_failure "$ee")" = "runner_unavailable" ]
  run _verdict --action-mode --analysis-results "$ee"
  [ "$output" = "BLOCKED" ]
}

# ---------- QA consumer reaches the verdict ----------

@test "QA runner reads evidence at the producer path and its check reaches the verdict" {
  _mk_project P1
  run _mutation_subcmd
  [ "$status" -eq 0 ]
  _analysis_empty
  local wd="$T/qa"
  run "$SCRIPTS/review-common/qa-test-runner.sh" --story-key E9-S1 --workdir "$wd" --config "$CFG" \
    --story-file "$STORY_DIR/story.md"
  [ "$status" -eq 0 ]
  [ "$(jq -r .mutation_check.name "$wd/execution-evidence.json")" = "mutation-score" ]
  [ "$(jq -r .mutation_check.status "$wd/execution-evidence.json")" = "passed" ]
  run _verdict --analysis-results "$T/analysis.json" --llm-findings "$T/llm.json" \
    --execution-evidence "$wd/execution-evidence.json"
  [ "$output" = "APPROVE" ]
}

@test "QA with a failed gate yields REQUEST_CHANGES through the resolver" {
  _mk_project P0
  run _mutation_subcmd
  [ "$status" -eq 0 ]
  _analysis_empty
  local wd="$T/qa"
  run "$SCRIPTS/review-common/qa-test-runner.sh" --story-key E9-S1 --workdir "$wd" --config "$CFG" --story-file "$STORY_DIR/story.md"
  [ "$status" -eq 0 ]
  [ "$(jq -r .mutation_check.status "$wd/execution-evidence.json")" = "failed" ]
  run _verdict --analysis-results "$T/analysis.json" --llm-findings "$T/llm.json" --execution-evidence "$wd/execution-evidence.json"
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "QA with missing or stale evidence yields BLOCKED and names the fix" {
  _mk_project P1
  _analysis_empty
  local wd="$T/qa"
  run "$SCRIPTS/review-common/qa-test-runner.sh" --story-key E9-S1 --workdir "$wd" --config "$CFG" --story-file "$STORY_DIR/story.md"
  [ "$status" -eq 0 ]
  [ "$(jq -r .mutation_check.status "$wd/execution-evidence.json")" = "errored" ]
  [[ "$(jq -r .mutation_check.message "$wd/execution-evidence.json")" == *'/gaia-test-automate --mutation E9-S1'* ]]
  run _verdict --analysis-results "$T/analysis.json" --llm-findings "$T/llm.json" --execution-evidence "$wd/execution-evidence.json"
  [ "$output" = "BLOCKED" ]

  run _mutation_subcmd
  [ "$status" -eq 0 ]
  printf 'x\n' > "$PROJ/moved.txt"; _commit_all moved
  run "$SCRIPTS/review-common/qa-test-runner.sh" --story-key E9-S1 --workdir "$wd" --config "$CFG" --story-file "$STORY_DIR/story.md"
  [ "$(jq -r .mutation_check.status "$wd/execution-evidence.json")" = "errored" ]
  [[ "$(jq -r .mutation_check.message "$wd/execution-evidence.json")" == *stale* ]]
}

@test "QA without thresholds adds no mutation check at all" {
  _mk_project P1
  _write_config 'project_name: demo'
  local wd="$T/qa"
  run "$SCRIPTS/review-common/qa-test-runner.sh" --story-key E9-S1 --workdir "$wd" --config "$CFG"
  [ "$status" -eq 0 ]
  [ "$(jq 'has("mutation_check")' "$wd/execution-evidence.json")" = "false" ]
}

@test "test review driver reports the check from the producer path with real thresholds" {
  _mk_project P0
  run _mutation_subcmd
  [ "$status" -eq 0 ]
  run bash -c "cd '$PROJ' && '$SCRIPTS/review-common/phase3a-test-review.sh' --story-key E9-S1 --stack bash-dev tests/calc.bats 2>/dev/null"
  [ "$status" -eq 0 ]
  printf '%s' "$output" > "$T/a.json"
  [ "$(jq -r '.checks[]|select(.name=="mutation-score")|.status' "$T/a.json")" = "failed" ]
  [ "$(jq -r '[.checks[]|select(.name=="mutation-score")|.findings[]|select(.rule=="weak-assertion")|.message]|length' "$T/a.json")" = "1" ]
  printf '{"findings":[]}' > "$T/llm.json"
  run _verdict --analysis-results "$T/a.json" --llm-findings "$T/llm.json"
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "unreadable thresholds give the test review driver an errored check naming yq, so the verdict is BLOCKED" {
  _mk_project P1
  mkdir -p "$T/badbin"
  printf '#!/bin/sh\necho "broken yq" >&2\nexit 3\n' > "$T/badbin/yq"
  chmod +x "$T/badbin/yq"
  run bash -c "cd '$PROJ' && PATH='$T/badbin':\"\$PATH\" '$SCRIPTS/review-common/phase3a-test-review.sh' --story-key E9-S1 --stack bash-dev tests/calc.bats 2>/dev/null"
  [ "$status" -eq 0 ]
  printf '%s' "$output" > "$T/a.json"
  [ "$(jq -r '.checks[]|select(.name=="mutation-score")|.status' "$T/a.json")" = "errored" ]
  [[ "$(jq -r '.checks[]|select(.name=="mutation-score")|.message' "$T/a.json")" == *yq* ]]
  printf '{"findings":[]}' > "$T/llm.json"
  run _verdict --analysis-results "$T/a.json" --llm-findings "$T/llm.json"
  [ "$output" = "BLOCKED" ]
}

# ---------- telemetry ----------

@test "gate updates feed mutation_score from the evidence file to the telemetry line" {
  _mk_project P1
  run _mutation_subcmd
  [ "$status" -eq 0 ]
  run bash -c "cd '$PROJ' && '$SCRIPTS/review-gate.sh' update --story E9-S1 --gate 'QA Tests' --verdict PASSED --report-missing-reason fixture"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  run bash -c "cd '$PROJ' && '$SCRIPTS/review-gate.sh' update --story E9-S1 --gate 'Test Review' --verdict PASSED --report-missing-reason fixture"
  [ "$status" -eq 0 ]
  run bash -c "cd '$PROJ' && '$SCRIPTS/review-gate.sh' update --story E9-S1 --gate 'Code Review' --verdict PASSED --report-missing-reason fixture"
  [ "$status" -eq 0 ]
  local tel="$STORY_DIR/review-telemetry.jsonl"
  [ -f "$tel" ]
  [ "$(jq -r 'select(.gate=="QA Tests")|.mutation_score' "$tel")" = "75" ]
  [ "$(jq -r 'select(.gate=="Test Review")|.mutation_score' "$tel")" = "75" ]
  [ "$(jq -r 'select(.gate=="Code Review")|.mutation_score' "$tel")" = "null" ]
}

# ---------- interrupted runs ----------

_hanging_project() {
  _mk_project P1
  local sum
  sum="$(cksum < "$PROJ/scripts/calc.sh")"
  # Green against the pristine file, hangs against any mutated copy.
  _bats_fixture "$PROJ/tests/calc.bats" 'hang on mutant calc.sh' \
    "  [ \"\$(cksum < \"\$BATS_TEST_DIRNAME/../scripts/calc.sh\")\" = \"$sum\" ] || sleep 45"
  _commit_all hang
  printf 'scripts/calc.sh\n' > "$T/f"; printf 'tests/calc.bats\n' > "$T/t"
}

# Starts the runner with SIGINT at its default disposition: a background job of
# a non-interactive shell inherits SIGINT ignored, which would hide the path.
_start_runner_bg() {
  perl -e '$SIG{INT}="DEFAULT"; exec @ARGV' "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" \
    --output "$T/ev.json" --thresholds '{"P1":60}' --priority P1 --jobs 4 >"$T/runner.log" 2>&1 3>&- &
  RPID=$!
}

_wait_for_copies() {
  local want="$1" i=0 n=0
  while [ "$i" -lt 150 ]; do
    n="$(find "$TMPDIR" -type f -name calc.bats 2>/dev/null | wc -l | tr -d ' ')"
    [ "$n" -ge "$want" ] && [ -n "$(pgrep -f 'sleep 45' || true)" ] && return 0
    /bin/sleep 0.2
    i=$((i + 1))
  done
  printf 'only %s copies appeared\n' "$n" >&2
  cat "$T/runner.log" >&2
  return 1
}

_assert_no_leftovers() {
  local left
  left="$(find "$TMPDIR" -name 'gaia-mutation-*' 2>/dev/null || true)"
  [ -z "$left" ] || { printf 'leftover copies:\n%s\n' "$left" >&2; return 1; }
}

@test "SIGTERM mid-run leaves no throwaway copy behind and exits 143" {
  _hanging_project
  _start_runner_bg
  _wait_for_copies 4
  kill -TERM "$RPID"
  local rc=0
  wait "$RPID" 2>/dev/null || rc=$?
  [ "$rc" -eq 143 ]
  _assert_no_leftovers
}

@test "SIGINT mid-run leaves no throwaway copy behind and exits 130" {
  _hanging_project
  _start_runner_bg
  _wait_for_copies 4
  kill -INT "$RPID"
  local rc=0
  wait "$RPID" 2>/dev/null || rc=$?
  [ "$rc" -eq 130 ]
  _assert_no_leftovers
}

# ---------- first run with evidence inside the worktree ----------

@test "first run with evidence and patches inside the worktree does not report worktree_mutated" {
  _mk_project P1
  printf 'scripts/calc.sh\n' > "$T/f"; printf 'tests/calc.bats\n' > "$T/t"
  run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$PROJ/out/ev.json" \
    --patch-dir "$PROJ/out/patches" --thresholds '{"P1":60}' --priority P1
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [ -f "$PROJ/out/ev.json" ]
  [ "$(find "$PROJ/out/patches" -name '*.patch' | wc -l | tr -d ' ')" = "4" ]
  # And a re-run over its own previous output is clean too.
  run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$PROJ/out/ev.json" \
    --patch-dir "$PROJ/out/patches" --thresholds '{"P1":60}' --priority P1
  [ "$status" -eq 0 ]
}

@test "a real worktree change during the run still aborts with worktree_mutated and no evidence" {
  _mk_project P1
  _bats_fixture "$PROJ/tests/calc.bats" 'tampers calc.sh' "  printf 'x' >> '$PROJ/scripts/calc.sh'"
  _commit_all tamper
  printf 'scripts/calc.sh\n' > "$T/f"; printf 'tests/calc.bats\n' > "$T/t"
  run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P1":60}' --priority P1
  [ "$status" -eq 2 ]
  [[ "$output" == *worktree_mutated* ]]
  [ ! -f "$T/ev.json" ]
}

# ---------- zero-kill ----------

@test "zero-kill compares test names, not file names, so a killing test is never reported" {
  _mk_project P1
  run _mutation_subcmd
  [ "$status" -eq 0 ]
  jq -e '.covering_test_names|index("is_one accepts one")' "$EV" >/dev/null
  run "$CHECKER" --story-key E9-S1 --evidence "$EV" --commit "$(_head)" --priority P1 --thresholds '{"P1":60}' --zero-kill
  [ "$status" -eq 0 ]
  [[ "$output" != *'is_one accepts one'* ]]
  [[ "$output" != *'tests/calc.bats'* ]]
  [ "$(printf '%s' "$output" | jq '.findings|length')" = "1" ]
}

@test "zero-kill names a killer in a later test file because every covering file runs" {
  _mk_project P1
  _bats_fixture "$PROJ/tests/calc.bats" 'first file kills calc.sh' \
    '  . "$BATS_TEST_DIRNAME/../scripts/calc.sh"; run is_one 1; [ "$status" -eq 0 ]'
  _bats_fixture "$PROJ/tests/calc2.bats" 'second file also kills calc.sh' \
    '  . "$BATS_TEST_DIRNAME/../scripts/calc.sh"; run is_one 1; [ "$status" -eq 0 ]'
  _commit_all two
  printf 'scripts/calc.sh\n' > "$T/f"; printf 'tests/calc.bats\ntests/calc2.bats\n' > "$T/t"
  run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P1":60}' --priority P1
  [ "$status" -eq 0 ]
  [ "$(jq -c '.mutants[]|select(.line==4)|.killed_by|sort' "$T/ev.json")" = '["first file kills calc.sh","second file also kills calc.sh"]' ]
}

# ---------- scoring honesty ----------

@test "a red baseline refuses to score" {
  _mk_project P1
  _bats_fixture "$PROJ/tests/calc.bats" 'always red calc.sh' '  false'
  _commit_all red
  printf 'scripts/calc.sh\n' > "$T/f"; printf 'tests/calc.bats\n' > "$T/t"
  run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P1":60}' --priority P1
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [ "$(jq -r .gate "$T/ev.json")" = "errored" ]
  [ "$(jq -r .score "$T/ev.json")" = "null" ]
  [ "$(jq -r .refused "$T/ev.json")" = "baseline_red" ]
  [ "$(jq -r .totals.killed "$T/ev.json")" = "0" ]
  [ "$(jq -r '.baseline.test_output' "$T/ev.json" | grep -c 'always red')" -ge 1 ]
}

@test "adapter counts only a genuine test failure as killed" {
  _mk_project P1
  local src="$TMPDIR/gaia-mutation-unit"
  mkdir -p "$src"
  cp -R "$PROJ/scripts" "$src/scripts"
  : > "$T/empty.patch"
  run "$ADAPTER_RUN" --source-dir "$src" --patch-file "$T/empty.patch" --test-command 'definitely-not-a-command-xyz' --output "$T/r.json" --timeout 10
  [ "$status" -eq 0 ]
  [ "$(jq -r .status "$T/r.json")" = "error" ]
  run "$ADAPTER_RUN" --source-dir "$src" --patch-file "$T/empty.patch" --test-command 'exit 126' --output "$T/r.json" --timeout 10
  [ "$(jq -r .status "$T/r.json")" = "error" ]
  run "$ADAPTER_RUN" --source-dir "$src" --patch-file "$T/empty.patch" --test-command 'kill -9 $$' --output "$T/r.json" --timeout 10
  [ "$(jq -r .status "$T/r.json")" = "error" ]
  run "$ADAPTER_RUN" --source-dir "$src" --patch-file "$T/empty.patch" --test-command 'exit 1' --output "$T/r.json" --timeout 10
  [ "$(jq -r .status "$T/r.json")" = "killed" ]
  run "$ADAPTER_RUN" --source-dir "$src" --patch-file "$T/empty.patch" --test-command 'true' --output "$T/r.json" --timeout 10
  [ "$(jq -r .status "$T/r.json")" = "survived" ]
}

@test "a test tool missing from the copy gives gate errored, never a perfect score" {
  _mk_project P1
  printf 'scripts/calc.sh\n' > "$T/f"; printf 'tests/calc.sh.test\n' > "$T/t"
  printf 'calc.sh\ndefinitely-not-a-command-xyz\n' > "$PROJ/tests/calc.sh.test"
  _commit_all m
  run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P1":60}' --priority P1
  [ "$status" -eq 0 ]
  [ "$(jq -r .gate "$T/ev.json")" = "errored" ]
  [ "$(jq -r .score "$T/ev.json")" = "null" ]
}

# ---------- adapter isolation ----------

@test "adapter runs the test command inside the throwaway copy, not the caller directory" {
  _mk_project P1
  local src="$TMPDIR/gaia-mutation-unit"
  mkdir -p "$src"
  : > "$T/empty.patch"
  run bash -c "cd '$PROJ' && '$ADAPTER_RUN' --source-dir '$src' --patch-file '$T/empty.patch' --test-command 'pwd -P > where.txt; printf %s \"\$PROJECT_PATH\" > env.txt' --output '$T/r.json' --timeout 10"
  [ "$status" -eq 0 ]
  [ ! -f "$PROJ/where.txt" ]
  [ -f "$src/where.txt" ]
  [ "$(cat "$src/where.txt")" = "$(cd "$src" && pwd -P)" ]
  [ "$(cat "$src/env.txt")" = "$(cd "$src" && pwd -P)" ]
}

@test "adapter accepts relative patch and output paths after moving into the copy" {
  _mk_project P1
  local src="$TMPDIR/gaia-mutation-unit"
  mkdir -p "$src"
  : > "$T/empty.patch"
  run bash -c "cd '$T' && '$ADAPTER_RUN' --source-dir '$src' --patch-file empty.patch --test-command 'true' --output rel.json --timeout 10"
  [ "$status" -eq 0 ]
  [ "$(jq -r .status "$T/rel.json")" = "survived" ]
}

# ---------- tool-native output ----------

@test "array output from a tool-native adapter is flattened into per-mutant records" {
  _mk_project P1
  _plugin_copy_with_adapter native .nat tool-native
  cat > "$ADAPTER/run.sh" <<'RUN'
#!/usr/bin/env bash
set -euo pipefail
while [ $# -gt 0 ]; do case "$1" in --output) out="$2"; shift 2;; *) shift 2;; esac; done
jq -n '[{mutant_id:"a",status:"killed",test_output:"",killed_by:["t1"]},{mutant_id:"b",status:"survived",test_output:""},{mutant_id:"c",status:"killed",test_output:""}]' > "$out"
RUN
  chmod +x "$ADAPTER/run.sh"
  printf 'x\n' > "$PROJ/scripts/m.nat"
  printf 'm.nat\n' > "$PROJ/tests/m.test"
  _commit_all nat
  printf 'scripts/m.nat\n' > "$T/f"; printf 'tests/m.test\n' > "$T/t"
  run "$T/plugin/scripts/mutation-runner.sh" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P1":60}' --priority P1
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [ "$(jq -c .totals "$T/ev.json")" = '{"mutants":3,"killed":2,"survived":1,"timeout":0,"error":0}' ]
  [ "$(jq -r '.mutants|map(type)|unique|join(",")' "$T/ev.json")" = "object" ]
  [ "$(jq -r '.mutants|map(.mutant_id)|unique|length' "$T/ev.json")" = "3" ]
  [ "$(jq -r .score "$T/ev.json")" = "66" ]
  [ "$(jq -r '[.mutants[]|.file]|unique|join(",")' "$T/ev.json")" = "scripts/m.nat" ]
}

@test "unparsable adapter output and a non-zero adapter exit are error records and excluded from the score" {
  _mk_project P1
  _plugin_copy_with_adapter broken .brk patch
  # Honest on the baseline call (empty patch); broken on the mutant calls.
  cat > "$ADAPTER/run.sh" <<'RUN'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in --output) out="$2"; shift 2;; --patch-file) p="$2"; shift 2;; *) shift 2;; esac; done
if [ ! -s "$p" ]; then printf '{"status":"survived","test_output":""}' > "$out"; exit 0; fi
[ "$BROKEN_MODE" = "exit" ] && { printf '{"status":"killed","test_output":""}' > "$out"; exit 9; }
printf 'not json' > "$out"
RUN
  chmod +x "$ADAPTER/run.sh"
  printf 'x\n' > "$PROJ/scripts/m.brk"
  printf 'm.brk\n' > "$PROJ/tests/m.test"
  _commit_all brk
  printf 'scripts/m.brk\n' > "$T/f"; printf 'tests/m.test\n' > "$T/t"
  local mode
  for mode in junk exit; do
    BROKEN_MODE="$mode" run "$T/plugin/scripts/mutation-runner.sh" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P1":60}' --priority P1
    [ "$status" -eq 0 ]
    [ "$(jq -c .totals "$T/ev.json")" = '{"mutants":1,"killed":0,"survived":0,"timeout":0,"error":1}' ]
    [ "$(jq -r .gate "$T/ev.json")" = "errored" ]
    [ "$(jq -r .score "$T/ev.json")" = "null" ]
  done
}

@test "an adapter that cannot run even the baseline refuses to score" {
  _mk_project P1
  _plugin_copy_with_adapter broken .brk patch
  printf '#!/usr/bin/env bash\nexit 7\n' > "$ADAPTER/run.sh"
  chmod +x "$ADAPTER/run.sh"
  printf 'x\n' > "$PROJ/scripts/m.brk"
  printf 'm.brk\n' > "$PROJ/tests/m.test"
  _commit_all brk
  printf 'scripts/m.brk\n' > "$T/f"; printf 'tests/m.test\n' > "$T/t"
  run "$T/plugin/scripts/mutation-runner.sh" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P1":60}' --priority P1
  [ "$status" -eq 0 ]
  [ "$(jq -r .gate "$T/ev.json")" = "errored" ]
  [ "$(jq -r .refused "$T/ev.json")" = "baseline_error" ]
  [ "$(jq -r .score "$T/ev.json")" = "null" ]
}

@test "a generator failure is an error record for that file, not a silent gap" {
  _mk_project P1
  _plugin_copy_with_adapter genfail .gf patch
  printf '#!/usr/bin/env bash\nexit 3\n' > "$ADAPTER/generate.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$ADAPTER/run.sh"
  chmod +x "$ADAPTER/generate.sh" "$ADAPTER/run.sh"
  printf 'x\n' > "$PROJ/scripts/m.gf"
  _commit_all gf
  printf 'scripts/calc.sh\nscripts/m.gf\n' > "$T/f"; printf 'tests/calc.bats\n' > "$T/t"
  run "$T/plugin/scripts/mutation-runner.sh" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P1":60}' --priority P1
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.mutants[]|select(.file=="scripts/m.gf" and .status=="error")]|length' "$T/ev.json")" = "1" ]
  [ "$(jq -r .totals.killed "$T/ev.json")" = "3" ]
}

# ---------- shell-hostile paths ----------

@test "paths with a space and an ampersand generate, apply and kill for real" {
  _mk_project P1
  mkdir -p "$PROJ/scripts/sub dir"
  cat > "$PROJ/scripts/sub dir/a b&c.sh" <<'SRC'
#!/usr/bin/env bash
amp() {
  [ "$1" -eq 1 ]
}
SRC
  _bats_fixture "$PROJ/tests/t x&y.bats" 'amp handles one' \
    '  . "$BATS_TEST_DIRNAME/../scripts/sub dir/a b&c.sh"; run amp 1; [ "$status" -eq 0 ]'
  _commit_all amp
  printf 'scripts/sub dir/a b&c.sh\n' > "$T/f"; printf 'tests/t x&y.bats\n' > "$T/t"
  run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P1":60}' --priority P1
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [ "$(jq -c .totals "$T/ev.json")" = '{"mutants":1,"killed":1,"survived":0,"timeout":0,"error":0}' ]
  [ "$(jq -r '.mutants[0].file' "$T/ev.json")" = 'scripts/sub dir/a b&c.sh' ]
  [ "$(jq -c '.mutants[0].killed_by' "$T/ev.json")" = '["amp handles one"]' ]
}

@test "manifest handles a worktree path with a pipe or ampersand in it" {
  PROJ="$T/pro|j&x"
  mkdir -p "$PROJ"
  export PROJECT_ROOT="$PROJ" CLAUDE_PROJECT_ROOT="$PROJ" PROJECT_PATH="$PROJ"
  _mk_project P1
  printf 'scripts/calc.sh\n' > "$T/f"; printf 'tests/calc.bats\n' > "$T/t"
  run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P1":60}' --priority P1
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [ "$(jq -r .totals.killed "$T/ev.json")" = "3" ]
}

# ---------- several source files in one run ----------

@test "multi-file run keeps operators, unique ids and one patch per mutant" {
  _mk_project P1
  cat > "$PROJ/scripts/other.sh" <<'SRC'
#!/usr/bin/env bash
other() {
  [ "$1" -lt 3 ]
}
SRC
  _bats_fixture "$PROJ/tests/other.bats" 'other sees two' \
    '  . "$BATS_TEST_DIRNAME/../scripts/other.sh"; run other 2; [ "$status" -eq 0 ]'
  _commit_all other
  printf 'scripts/calc.sh\nscripts/other.sh\n' > "$T/f"; printf 'tests/calc.bats\ntests/other.bats\n' > "$T/t"
  run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --patch-dir "$T/patches" --thresholds '{"P1":60}' --priority P1
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [ "$(jq -c .totals "$T/ev.json")" = '{"mutants":5,"killed":4,"survived":1,"timeout":0,"error":0}' ]
  [ "$(jq -r '[.mutants[].operator|select(.==null)]|length' "$T/ev.json")" = "0" ]
  [ "$(jq -r '.mutants|map(.mutant_id)|unique|length' "$T/ev.json")" = "5" ]
  [ "$(find "$T/patches" -name '*.patch' | wc -l | tr -d ' ')" = "5" ]
  [ "$(jq -r '.mutants[]|select(.file=="scripts/other.sh")|.operator' "$T/ev.json")" = "comparison flip lt/ge" ]
  # Each record's patch really targets that record's file.
  local id file
  while IFS=$'\t' read -r id file; do
    grep -qF -- "+++ b/$file" "$T/patches/$id.patch"
  done < <(jq -r '.mutants[]|[.mutant_id,.file]|@tsv' "$T/ev.json")
}

@test "a source file with no mutable line gives gate errored under every interpreter, not a crash" {
  _mk_project P1
  printf '#!/usr/bin/env bash\necho hello\n' > "$PROJ/scripts/plain.sh"
  _commit_all plain
  printf 'scripts/plain.sh\n' > "$T/f"; printf 'tests/calc.bats\n' > "$T/t"
  run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P1":60}' --priority P1
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [ "$(jq -r .gate "$T/ev.json")" = "errored" ]
  [ "$(jq -r .totals.mutants "$T/ev.json")" = "0" ]
}

# ---------- covering-test selection ----------

@test "a test mentioning a longer sibling name does not cover the file" {
  _mk_project P1
  cat > "$PROJ/scripts/foo.sh" <<'SRC'
#!/usr/bin/env bash
foo() {
  [ "$1" -eq 1 ]
}
SRC
  _bats_fixture "$PROJ/tests/foobar.bats" 'covers foobar.sh and myfoo.sh and foo.sh.bak only' '  true'
  _bats_fixture "$PROJ/tests/foo-stem.bats" 'mentions foo only by stem' '  true'
  _commit_all foo
  printf 'scripts/foo.sh\n' > "$T/f"; printf 'tests/foobar.bats\ntests/foo-stem.bats\n' > "$T/t"
  run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P1":60}' --priority P1
  [ "$status" -eq 0 ]
  [ "$(jq -r '.mutants[0].no_coverage' "$T/ev.json")" = "true" ]
  [ "$(jq -r '.covering_tests|length' "$T/ev.json")" = "0" ]
}

@test "a test naming the same basename in another directory does not cover the file" {
  _mk_project P1
  mkdir -p "$PROJ/lib" "$PROJ/bin"
  printf '#!/usr/bin/env bash\nlibfn() {\n  [ "$1" -eq 1 ]\n}\n' > "$PROJ/lib/util.sh"
  _bats_fixture "$PROJ/tests/wrong.bats" 'uses bin/util.sh' '  true'
  _bats_fixture "$PROJ/tests/right.bats" 'uses lib/util.sh' '  true'
  _bats_fixture "$PROJ/tests/viavar.bats" 'uses $DIR/util.sh' '  true'
  _commit_all util
  printf 'lib/util.sh\n' > "$T/f"; printf 'tests/wrong.bats\ntests/right.bats\ntests/viavar.bats\n' > "$T/t"
  run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P1":60}' --priority P1
  [ "$status" -eq 0 ]
  [ "$(jq -c '.covering_tests|sort' "$T/ev.json")" = '["tests/right.bats","tests/viavar.bats"]' ]
}

# ---------- empty thresholds object ----------

@test "an empty thresholds object is present: defaults apply and missing evidence is errored" {
  _mk_project P0 
  run "$CHECKER" --story-key E9-S1 --evidence "$T/none.json" --commit "$(_head)" --priority P0 --thresholds '{}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "errored" ]
  [[ "$output" == *'/gaia-test-automate --mutation E9-S1'* ]]

  _write_config 'project_name: demo
test_execution:
  mutation_thresholds: {}'
  run _mutation_subcmd
  [ "$status" -eq 0 ]
  [ "$(jq -r .thresholds.P0 "$EV")" = "80" ]
  [ "$(jq -r .gate "$EV")" = "failed" ]
}

@test "a failed score with only advisory findings still blocks through the resolver" {
  _mk_project P0
  run _mutation_subcmd
  [ "$status" -eq 0 ]
  run "$CHECKER" --story-key E9-S1 --evidence "$EV" --commit "$(_head)" --priority P0 --thresholds '{"P0":80}' --zero-kill
  [ "$status" -eq 0 ]
  printf '{"schema_version":"1.0","checks":[%s]}' "$output" > "$T/a.json"
  printf '{"findings":[]}' > "$T/llm.json"
  run _verdict --analysis-results "$T/a.json" --llm-findings "$T/llm.json"
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "unresolved story priority is gated, never treated as advisory" {
  _mk_project P1
  run "$CHECKER" --story-key E9-S1 --evidence "$T/none.json" --commit "$(_head)" --thresholds '{"P1":60}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "errored" ]
}

@test "P2 story check is skipped with a stated reason" {
  _mk_project P2
  run "$CHECKER" --story-key E9-S1 --evidence "$T/none.json" --commit "$(_head)" --priority P2 --thresholds '{"P1":60}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "skipped" ]
  [ -n "$(printf '%s' "$output" | jq -r .skip_reason)" ]
}

# ---------- shared configuration helper ----------

@test "mutation_read_thresholds and mutation_evidence_path resolve from the project" {
  _mk_project P1
  run bash -c ". '$SCRIPTS/lib/mutation-config.sh'; mutation_read_thresholds '$CFG'"
  [ "$status" -eq 0 ]
  [ "$output" = '{"P0":80,"P1":60}' ]
  run bash -c "cd '$PROJ'; . '$SCRIPTS/lib/mutation-config.sh'; mutation_evidence_path E9-S1"
  [ "$status" -eq 0 ]
  [ "$output" = "$EV" ]
  run bash -c ". '$SCRIPTS/lib/mutation-config.sh'; mutation_story_priority '$STORY_DIR/story.md'"
  [ "$output" = "P1" ]
  run bash -c ". '$SCRIPTS/lib/mutation-config.sh'; mutation_read_thresholds '$T/absent.yaml'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mutation_short_hash, mutation_init_run_root and mutation_terminate_children behave as documented" {
  run bash -c ". '$SCRIPTS/lib/mutation-isolation.sh'; a=\$(mutation_short_hash 'x y&z'); b=\$(mutation_short_hash 'x y&z'); [ \"\$a\" = \"\$b\" ] && [ \${#a} -eq 8 ] && echo same"
  [ "$output" = "same" ]
  mkdir -p "$PROJ/w"
  run bash -c ". '$SCRIPTS/lib/mutation-isolation.sh'; mutation_init_run_root '$PROJ/w'; printf '%s' \"\$_MI_RUN_ROOT\""
  [ "$status" -eq 0 ]
  [[ "$(basename "$output")" == gaia-mutation-* ]]
  run bash -c ". '$SCRIPTS/lib/mutation-isolation.sh'; sleep 40 & p=\$!; mutation_terminate_children; kill -0 \$p 2>/dev/null && echo alive || echo gone"
  [[ "$output" == *gone ]]
  TMPDIR="$PROJ/w" run bash -c ". '$SCRIPTS/lib/mutation-isolation.sh'; mutation_init_run_root '$PROJ/w'"
  [ "$status" -ne 0 ]
  [[ "$output" == *containment* ]]
}

@test "mutation_config_path and mutation_story_file_list read the real story and config layout" {
  _mk_project P1
  run bash -c ". '$SCRIPTS/lib/mutation-config.sh'; mutation_config_path"
  [ "$output" = "$CFG" ]
  run bash -c ". '$SCRIPTS/lib/mutation-config.sh'; mutation_story_file_list '$STORY_DIR/story.md'"
  [ "$output" = "scripts/calc.sh
tests/calc.bats" ]
}

# ---------- test output: names and secrets ----------

# `! grep` does not fail a bats test unless it is the last command.
_not_in() {
  if grep -q -- "$1" "$2"; then
    printf 'found %s in %s\n' "$1" "$2"
    return 1
  fi
}

@test "every test name is seen and the killer is named when the output exceeds the stored cap" {
  _mk_project P1
  printf '#!/usr/bin/env bash\nf() {\n  [ "$1" -eq 1 ]\n}\n' > "$PROJ/scripts/f.sh"
  local args i
  args=('the only killer' '  . "$BATS_TEST_DIRNAME/../scripts/f.sh"; f 1')
  for i in $(seq 1 99); do
    args+=("filler with a long descriptive name so that the output passes the stored cap, number $i" '  true')
  done
  _bats_fixture "$PROJ/tests/f.bats" "${args[@]}"
  _commit_all many
  printf 'scripts/f.sh\n' > "$T/f"; printf 'tests/f.bats\n' > "$T/t"
  run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P1":60}' --priority P1
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.mutants[0].killed_by' "$T/ev.json")" = '["the only killer"]' ]
  [ "$(jq -r '.covering_test_names|length' "$T/ev.json")" = "100" ]
  [ "$(jq -r '.mutants[0].test_output|length' "$T/ev.json")" -le 4200 ]
}

@test "secrets a test prints never reach the evidence, in any shape" {
  _mk_project P1
  printf '#!/usr/bin/env bash\nf() {\n  [ "$1" -eq 1 ]\n}\n' > "$PROJ/scripts/f.sh"
  _bats_fixture "$PROJ/tests/f.bats" 'prints secrets f.sh' \
    '  env | grep AWS_SECRET
  echo "bare value $MY_API_KEY"
  export OWN_PASSWORD=hunter2hunter2; env | grep OWN_PASSWORD
  echo "AKIAABCDEFGHIJKLMNOP"
  . "$BATS_TEST_DIRNAME/../scripts/f.sh"; f 1'
  _commit_all secrets
  printf 'scripts/f.sh\n' > "$T/f"; printf 'tests/f.bats\n' > "$T/t"
  AWS_SECRET_ACCESS_KEY=AKIAFAKESECRET123 MY_API_KEY=plainkeyvalue run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P1":60}' --priority P1
  [ "$status" -eq 0 ]
  [ "$(jq -r .totals.killed "$T/ev.json")" = "1" ]
  [ "$(jq -c '.mutants[0].killed_by' "$T/ev.json")" = '["prints secrets f.sh"]' ]
  jq -r '.mutants[0].test_output' "$T/ev.json" | grep -q 'REDACTED'
  _not_in AKIAFAKESECRET123 "$T/ev.json"
  _not_in plainkeyvalue "$T/ev.json"
  _not_in hunter2hunter2 "$T/ev.json"
  _not_in AKIAABCDEFGHIJKLMNOP "$T/ev.json"
}

@test "secrets in a refused baseline never reach the evidence" {
  _mk_project P1
  printf '#!/usr/bin/env bash\nf() {\n  [ "$1" -eq 1 ]\n}\n' > "$PROJ/scripts/f.sh"
  _bats_fixture "$PROJ/tests/f.bats" 'red and noisy f.sh' '  env | grep AWS_SECRET; false'
  _commit_all red
  printf 'scripts/f.sh\n' > "$T/f"; printf 'tests/f.bats\n' > "$T/t"
  AWS_SECRET_ACCESS_KEY=AKIAFAKESECRET123 run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P1":60}' --priority P1
  [ "$status" -eq 0 ]
  [ "$(jq -r .refused "$T/ev.json")" = "baseline_red" ]
  _not_in AKIAFAKESECRET123 "$T/ev.json"
}

@test "test output that cannot be scrubbed is withheld, not stored raw" {
  local src="$TMPDIR/gaia-mutation-unit"
  mkdir -p "$src" "$T/plugin"
  cp -R "$PLUGIN/scripts" "$T/plugin/scripts"
  : > "$T/empty.patch"
  run "$T/plugin/scripts/adapters/mutation-bash/run.sh" --source-dir "$src" --patch-file "$T/empty.patch" \
    --test-command 'echo printed-by-the-test' --output "$T/rec.json" --timeout 10
  [ "$status" -eq 0 ]
  [ "$(jq -r .status "$T/rec.json")" = "survived" ]
  _not_in printed-by-the-test "$T/rec.json"
  jq -r .test_output "$T/rec.json" | grep -q 'withheld'
}

# ---------- no mutants ----------

# _set_file_list <entry>... rewrites the story's File List and commits.
_set_file_list() {
  local entry list=""
  for entry in "$@"; do list="$list- \`$entry\`
"; done
  _LIST="$list" awk '
    /^### File List/ { print; print ""; printf "%s", ENVIRON["_LIST"]; print ""; skip = 1; next }
    /^## Findings/   { skip = 0 }
    !skip
  ' "$STORY_DIR/story.md" > "$T/story.new"
  cp "$T/story.new" "$STORY_DIR/story.md"
  _commit_all list
}

_zero_mutant_files() {
  mkdir -p "$PROJ/docs" "$PROJ/src"
  printf 'words\n' > "$PROJ/docs/readme.md"
  printf 'x = 1\n' > "$PROJ/src/app.py"
  printf '#!/usr/bin/env bash\necho hello\n' > "$PROJ/scripts/plain.sh"
}

@test "a P2 or P3 story with no mutants is advisory with a null score and the subcommand exits 0" {
  local prio
  for prio in P2 P3; do
    rm -rf "$PROJ/.git"
    _mk_project "$prio" "    P2: 50
    P3: 50"
    _zero_mutant_files
    _set_file_list docs/readme.md
    rm -f "$EV"
    run _mutation_subcmd
    printf '%s\n' "$output"
    [ "$status" -eq 0 ]
    [ "$(jq -r .gate "$EV")" = "advisory" ]
    [ "$(jq -r .score "$EV")" = "null" ]
    [ "$(jq 'has("zero_mutant_reason")' "$EV")" = "false" ]
  done
}

@test "a P0 or P1 story whose File List no adapter covers is not_applicable with a reason" {
  local prio list
  for prio in P0 P1; do
    for list in docs/readme.md src/app.py tests/calc.bats "docs/readme.md src/app.py tests/calc.bats"; do
      rm -rf "$PROJ/.git"
      _mk_project "$prio"
      _zero_mutant_files
      # shellcheck disable=SC2086 # the list is split on purpose
      _set_file_list $list
      rm -f "$EV"
      run _mutation_subcmd
      printf '%s: %s\n' "$list" "$output"
      [ "$status" -eq 0 ]
      [ "$(jq -r .gate "$EV")" = "not_applicable" ]
      [ "$(jq -r .score "$EV")" = "null" ]
      [ -n "$(jq -r '.zero_mutant_reason // ""' "$EV")" ]
    done
  done
}

@test "not_applicable evidence at HEAD is skipped with its reason, and does not block the verdict" {
  _mk_project P1
  _zero_mutant_files
  _set_file_list docs/readme.md
  run _mutation_subcmd
  [ "$status" -eq 0 ]
  run "$CHECKER" --story-key E9-S1 --evidence "$EV" --commit "$(_head)" --priority P1 --thresholds '{"P1":60}' --zero-kill
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "skipped" ]
  [ "$(printf '%s' "$output" | jq -r .skip_reason)" = "$(jq -r .zero_mutant_reason "$EV")" ]
  [ "$(printf '%s' "$output" | jq -r '.findings|length')" = "0" ]
  printf '%s' "$output" | jq '{mutation_check:.}' > "$T/ee.json"
  _analysis_empty
  run _verdict --analysis-results "$T/analysis.json" --llm-findings "$T/llm.json" --execution-evidence "$T/ee.json"
  [ "$output" = "APPROVE" ]
}

@test "not_applicable evidence that is stale, has no reason or has a score is errored" {
  _mk_project P1
  _zero_mutant_files
  _set_file_list docs/readme.md
  run _mutation_subcmd
  [ "$status" -eq 0 ]
  run "$CHECKER" --story-key E9-S1 --evidence "$EV" --commit deadbeef --priority P1 --thresholds '{"P1":60}'
  [ "$(printf '%s' "$output" | jq -r .status)" = "errored" ]
  jq 'del(.zero_mutant_reason)' "$EV" > "$T/no-reason.json"
  run "$CHECKER" --story-key E9-S1 --evidence "$T/no-reason.json" --commit "$(_head)" --priority P1 --thresholds '{"P1":60}'
  [ "$(printf '%s' "$output" | jq -r .status)" = "errored" ]
  jq '.score = 90' "$EV" > "$T/scored.json"
  run "$CHECKER" --story-key E9-S1 --evidence "$T/scored.json" --commit "$(_head)" --priority P1 --thresholds '{"P1":60}'
  [ "$(printf '%s' "$output" | jq -r .status)" = "errored" ]
  jq '.gate = "whatever"' "$EV" > "$T/unknown.json"
  run "$CHECKER" --story-key E9-S1 --evidence "$T/unknown.json" --commit "$(_head)" --priority P1 --thresholds '{"P1":60}'
  [ "$(printf '%s' "$output" | jq -r .status)" = "errored" ]
}

@test "a P0 or P1 story with no mutants is errored when a covered file has none, is missing, or the list is empty" {
  local prio list
  for prio in P0 P1; do
    for list in scripts/plain.sh scripts/gone.sh "docs/readme.md scripts/gone.sh" ""; do
      rm -rf "$PROJ/.git"
      _mk_project "$prio"
      _zero_mutant_files
      # shellcheck disable=SC2086 # the list is split on purpose
      _set_file_list $list
      rm -f "$EV"
      run _mutation_subcmd
      printf '[%s]: %s\n' "$list" "$output"
      [ "$status" -eq 1 ]
      [[ "$output" == *'blocking_failure: runner_unavailable'* ]]
      [ "$(jq -r .gate "$EV")" = "errored" ]
      [ "$(jq -r .score "$EV")" = "null" ]
      [ "$(jq 'has("zero_mutant_reason")' "$EV")" = "false" ]
    done
  done
}

@test "an unreadable File List is errored with evidence, whichever way the list arrives" {
  _mk_project P1
  chmod 000 "$STORY_DIR/story.md"
  if [ -r "$STORY_DIR/story.md" ]; then
    chmod 644 "$STORY_DIR/story.md"
    skip "file permissions are not enforced for this user"
  fi
  run bash -c "cd '$PROJ' && '$RUNNER' --story E9-S1 --worktree '$PROJ' --output '$T/ev.json' --thresholds '{\"P1\":60}'"
  chmod 644 "$STORY_DIR/story.md"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [ "$(jq -r .gate "$T/ev.json")" = "errored" ]
  [ "$(jq -r .score "$T/ev.json")" = "null" ]
  printf 'scripts/calc.sh\n' > "$T/f"
  chmod 000 "$T/f"
  run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --output "$T/ev2.json" --thresholds '{"P1":60}' --priority P1
  chmod 644 "$T/f"
  [ "$status" -eq 0 ]
  [ "$(jq -r .gate "$T/ev2.json")" = "errored" ]
  [ "$(jq -r .score "$T/ev2.json")" = "null" ]
}

# ---------- thresholds that cannot be compared ----------

@test "a P0 or P1 threshold that is not a whole number from 0 to 100 gives gate errored, with evidence" {
  _mk_project P1
  local bad
  printf 'scripts/calc.sh\n' > "$T/f"; printf 'tests/calc.bats\n' > "$T/t"
  for bad in '74.5' '"abc"' '"60"' '101' '-1' 'true' '[60]'; do
    rm -f "$T/ev.json"
    run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds "{\"P1\":$bad}" --priority P1
    printf '%s: %s\n' "$bad" "$output"
    [ "$status" -eq 0 ]
    [ "$(jq -r .gate "$T/ev.json")" = "errored" ]
    [[ "$output" == *'threshold'* ]]
  done
}

@test "a threshold is compared on the boundary and a bad one on another priority does not gate this one" {
  _mk_project P1
  printf 'scripts/calc.sh\n' > "$T/f"; printf 'tests/calc.bats\n' > "$T/t"
  run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P1":75}' --priority P1
  [ "$(jq -r .gate "$T/ev.json")" = "passed" ]
  run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P1":76}' --priority P1
  [ "$(jq -r .gate "$T/ev.json")" = "failed" ]
  run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P0":"abc","P1":60}' --priority P1
  [ "$status" -eq 0 ]
  [ "$(jq -r .gate "$T/ev.json")" = "passed" ]
  run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P2":"abc"}' --priority P2
  [ "$status" -eq 0 ]
  [ "$(jq -r .gate "$T/ev.json")" = "advisory" ]
}

# ---------- action-mode verdict ----------

@test "action mode blocks on a blocking_failure held only in the execution evidence" {
  printf '{"plan":"present","execution":"success"}' > "$T/a.json"
  printf '{"blocking_failure":"runner_unavailable"}' > "$T/e.json"
  run _verdict --action-mode --analysis-results "$T/a.json" --execution-evidence "$T/e.json"
  [ "$output" = "BLOCKED" ]
}

@test "action mode blocks on execution evidence it cannot read" {
  printf '{"plan":"present","execution":"success"}' > "$T/a.json"
  printf 'not json' > "$T/e.json"
  run _verdict --action-mode --analysis-results "$T/a.json" --execution-evidence "$T/e.json"
  [ "$output" = "BLOCKED" ]
  run _verdict --action-mode --analysis-results "$T/a.json" --execution-evidence "$T/absent.json"
  [ "$output" = "BLOCKED" ]
}

@test "action mode approves on green execution evidence" {
  printf '{"plan":"present","execution":"success"}' > "$T/a.json"
  printf '{"blocking_failure":""}' > "$T/e.json"
  run _verdict --action-mode --analysis-results "$T/a.json" --execution-evidence "$T/e.json"
  [ "$output" = "APPROVE" ]
  printf '{}' > "$T/e.json"
  run _verdict --action-mode --analysis-results "$T/a.json" --execution-evidence "$T/e.json"
  [ "$output" = "APPROVE" ]
  run _verdict --action-mode --analysis-results "$T/a.json"
  [ "$output" = "APPROVE" ]
}

# ---------- shell-hostile directories in test selection ----------

@test "a test naming a source under a directory with a space and an ampersand covers it" {
  _mk_project P1
  mkdir -p "$PROJ/my scripts&x" "$PROJ/my tests"
  printf '#!/usr/bin/env bash\nf() {\n  if [ "$1" -eq 1 ]; then return 0; fi\n  return 1\n}\n' > "$PROJ/my scripts&x/a&b c.sh"
  _bats_fixture "$PROJ/my tests/t (1)&.bats" 'f accepts one' '  . "$BATS_TEST_DIRNAME/../my scripts&x/a&b c.sh"; f 1'
  _commit_all hostile
  printf 'my scripts&x/a&b c.sh\n' > "$T/f"; printf 'my tests/t (1)&.bats\n' > "$T/t"
  run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P1":60}' --priority P1
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.mutants[]|select(.no_coverage==true)]|length' "$T/ev.json")" = "0" ]
  [ "$(jq -r .totals.killed "$T/ev.json")" -gt 0 ]
  [ "$(jq -c .covering_tests "$T/ev.json")" = '["my tests/t (1)&.bats"]' ]
}

@test "a same-named source under a different spaced directory does not count as covered" {
  _mk_project P1
  mkdir -p "$PROJ/my scripts" "$PROJ/tests"
  printf '#!/usr/bin/env bash\nf() {\n  [ "$1" -eq 1 ]\n}\n' > "$PROJ/my scripts/a.sh"
  _bats_fixture "$PROJ/tests/other.bats" 'elsewhere' '  # see not my scripts/b/a.sh and xmy scripts/a.sh
  true'
  _commit_all other
  printf 'my scripts/a.sh\n' > "$T/f"; printf 'tests/other.bats\n' > "$T/t"
  run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P1":60}' --priority P1
  [ "$status" -eq 0 ]
  [ "$(jq -c .covering_tests "$T/ev.json")" = '[]' ]
  [ "$(jq -r '.mutants[0].no_coverage' "$T/ev.json")" = "true" ]
}

# ---------- adapter index that cannot be planned from ----------

@test "an unusable index entry is an error record with gate errored and evidence, whatever the entry" {
  _mk_project P1
  _plugin_copy_with_adapter stub .stub patch
  cat > "$ADAPTER/generate.sh" <<'GEN'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in --out-dir) o="$2"; shift 2;; *) shift 2;; esac; done
printf -- '--- a/x\n' > "$o/m1.patch"
printf '%s' "$STUB_INDEX" > "$o/index.json"
GEN
  printf '#!/usr/bin/env bash\nwhile [ $# -gt 0 ]; do case "$1" in --output) o="$2"; shift 2;; *) shift 2;; esac; done\necho "{\\"status\\":\\"survived\\",\\"test_output\\":\\"\\"}" > "$o"\n' > "$ADAPTER/run.sh"
  chmod +x "$ADAPTER/generate.sh" "$ADAPTER/run.sh"
  printf 'x\n' > "$PROJ/scripts/a.stub"
  _bats_fixture "$PROJ/tests/s.bats" 'names a.stub' '  true'
  _commit_all stub
  printf 'scripts/a.stub\n' > "$T/f"; printf 'tests/s.bats\n' > "$T/t"
  local idx
  while IFS= read -r idx; do
    rm -f "$T/ev.json"
    STUB_INDEX="$idx" run "$T/plugin/scripts/mutation-runner.sh" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P1":60}' --priority P1
    printf '%s => %s\n' "$idx" "$output"
    [ "$status" -eq 0 ]
    [ "$(jq -r .gate "$T/ev.json")" = "errored" ]
    [ "$(jq -r .score "$T/ev.json")" = "null" ]
    [ "$(jq -r '.mutants[0].status' "$T/ev.json")" = "error" ]
  done <<'INDEXES'
[{"mutant_id":"m1","patch_file":"m1.patch","line":"x","operator":"o"}]
[{"mutant_id":"m1","line":3,"operator":"o"}]
[{"mutant_id":"m1"}]
[{"mutant_id":"m1","patch_file":"gone.patch","line":3}]
[{"patch_file":"m1.patch","line":3}]
[{"mutant_id":"a/b","patch_file":"m1.patch","line":3}]
[{"mutant_id":"m1","patch_file":"../m1.patch","line":3}]
[{"mutant_id":"m1","patch_file":"m1.patch","line":1.5}]
["m1"]
INDEXES
}

@test "an unusable index taints the gate even when another file scores" {
  _mk_project P1
  _plugin_copy_with_adapter stub .stub patch
  mkdir -p "$T/plugin/skills"
  cp -R "$PLUGIN/skills/gaia-meeting" "$T/plugin/skills/gaia-meeting"
  cat > "$ADAPTER/generate.sh" <<'GEN'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in --out-dir) o="$2"; shift 2;; *) shift 2;; esac; done
printf '[{"mutant_id":"m1","line":"x"}]' > "$o/index.json"
GEN
  printf '#!/usr/bin/env bash\nexit 0\n' > "$ADAPTER/run.sh"
  chmod +x "$ADAPTER/generate.sh" "$ADAPTER/run.sh"
  printf 'x\n' > "$PROJ/scripts/a.stub"
  _commit_all stub
  printf 'scripts/calc.sh\nscripts/a.stub\n' > "$T/f"; printf 'tests/calc.bats\n' > "$T/t"
  run "$T/plugin/scripts/mutation-runner.sh" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P1":60}' --priority P1
  [ "$status" -eq 0 ]
  [ "$(jq -r .gate "$T/ev.json")" = "errored" ]
  [ "$(jq -r .totals.killed "$T/ev.json")" = "3" ]
  [ "$(jq -r '[.mutants[]|select(.file=="scripts/a.stub" and .status=="error")]|length' "$T/ev.json")" = "1" ]
}

# ---------- time limit ----------

_slow_project() {
  _mk_project P1
  printf '#!/usr/bin/env bash\nf() {\n  [ "$1" -eq 1 ]\n}\n' > "$PROJ/scripts/f.sh"
  _bats_fixture "$PROJ/tests/f.bats" 'slow f' '  sleep 3; . "$BATS_TEST_DIRNAME/../scripts/f.sh"; f 1'
  _commit_all slow
  printf 'scripts/f.sh\n' > "$T/f"; printf 'tests/f.bats\n' > "$T/t"
}

@test "covering tests that run out of time are reported as a timeout, not as red, and say how to raise the limit" {
  _slow_project
  run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P1":60}' --priority P1 --timeout 1
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [ "$(jq -r .gate "$T/ev.json")" = "errored" ]
  [ "$(jq -r .score "$T/ev.json")" = "null" ]
  [ "$(jq -r .refused "$T/ev.json")" = "baseline_error" ]
  [ "$(jq -r .baseline.status "$T/ev.json")" = "timeout" ]
  jq -r .baseline.test_output "$T/ev.json" | grep -q -- '--timeout'
  [[ "$output" == *'--timeout'* ]]
}

@test "the time limit is raised by the option, by the environment, and the option wins" {
  _slow_project
  GAIA_MUTATION_TIMEOUT=1 run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P1":60}' --priority P1
  [ "$(jq -r .baseline.status "$T/ev.json")" = "timeout" ]
  GAIA_MUTATION_TIMEOUT=1 run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --tests-from "$T/t" --output "$T/ev.json" --thresholds '{"P1":60}' --priority P1 --timeout 120
  [ "$status" -eq 0 ]
  [ "$(jq -r .gate "$T/ev.json")" = "passed" ]
  [ "$(jq -r .totals.killed "$T/ev.json")" = "1" ]
}

@test "the mutation subcommand passes the time limit to the runner" {
  _slow_project
  _set_file_list scripts/f.sh tests/f.bats
  run _mutation_subcmd --timeout 1
  [ "$status" -eq 1 ]
  [ "$(jq -r .baseline.status "$EV")" = "timeout" ]
  run _mutation_subcmd --timeout 120
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [ "$(jq -r .gate "$EV")" = "passed" ]
}

@test "a time limit that is not a positive whole number is a caller error" {
  _mk_project P1
  printf 'scripts/calc.sh\n' > "$T/f"
  local bad
  for bad in 0 abc 1.5 -3; do
    run "$RUNNER" --worktree "$PROJ" --files-from "$T/f" --output "$T/ev.json" --timeout "$bad"
    [ "$status" -eq 1 ]
    [[ "$output" == *'--timeout'* ]]
  done
}
