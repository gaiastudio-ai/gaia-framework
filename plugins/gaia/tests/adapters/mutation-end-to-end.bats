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
    '  # a b&c.sh
  . "$BATS_TEST_DIRNAME/../scripts/sub dir/a b&c.sh"; run amp 1; [ "$status" -eq 0 ]'
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
