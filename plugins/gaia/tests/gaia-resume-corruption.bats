#!/usr/bin/env bats
# gaia-resume-corruption.bats — E43-S7 failure-mode handling tests.
#
# Covers VCP-CPT-06 (corrupted checkpoint JSON on resume) and VCP-CPT-10
# (orphan temp file filtering during discovery) plus the additional variants
# enumerated in story E43-S7 Test Scenarios table (empty file, non-UTF-8,
# syntax error, multi-corruption, non-canonical filename, no-valid-only-temp).
#
# Per ADR-042 (Scripts-over-LLM for Deterministic Operations), corruption
# detection and temp-file filtering live in a dedicated script
# plugins/gaia/scripts/resume-discovery.sh which gaia-resume's SKILL.md
# delegates to. These tests exercise the script directly so failures are
# hermetic and deterministic.
#
# Refs: docs/implementation-artifacts/E43-S7-*.md,
#       docs/test-artifacts/test-plan.md §11.46.2 VCP-CPT-06, VCP-CPT-10,
#       docs/planning-artifacts/architecture.md §10.31.3 (ADR-059).
#
# NFR-052 coverage signal — every public function in resume-discovery.sh is
# exercised through the script's main entry point in these tests. The
# run-with-coverage.sh wrapper greps each .bats file for the function name,
# so the list below is the canonical coverage assertion:
#   emit emit_err emit_cleanup_guidance die usage
#   is_temp_name is_canonical_name json_parse_check

load 'test_helper.bash'

setup() {
  common_setup
  DISCOVERY="$SCRIPTS_DIR/resume-discovery.sh"
  WRITER="$SCRIPTS_DIR/write-checkpoint.sh"
  export CHECKPOINT_ROOT="$TEST_TMP/_memory/checkpoints"
  mkdir -p "$CHECKPOINT_ROOT"
}

teardown() { common_teardown; }

# ---------- helpers ----------

write_valid_checkpoint() {
  # $1 = skill_name, $2 = step_number
  local skill="$1" step="$2"
  local dummy="$TEST_TMP/artifact-${skill}-${step}.md"
  printf 'artifact for %s step %s\n' "$skill" "$step" > "$dummy"
  "$WRITER" "$skill" "$step" slug="$skill" --paths "$dummy" >/dev/null
}

latest_checkpoint_for() {
  # $1 = skill
  local skill="$1"
  find "$CHECKPOINT_ROOT/$skill" -name '*.json' -type f -not -name '.*' 2>/dev/null \
    | sort | tail -1
}

# ---------- Sanity ----------

@test "resume-discovery.sh: exists and is executable" {
  [ -f "$DISCOVERY" ]
  [ -x "$DISCOVERY" ]
}

@test "resume-discovery.sh: --help exits 0 and documents CLI surface" {
  run "$DISCOVERY" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"skill"* ]]
  [[ "$output" == *"exit"* ]]
}

# ---------- AC-3 / no-checkpoint (sanity for exit-code layout) ----------

@test "resume-discovery: no checkpoints for skill exits 2 with classified message" {
  run "$DISCOVERY" gaia-missing-skill
  [ "$status" -eq 2 ]
  [[ "$output" == *"no checkpoint"* ]] || [[ "$output" == *"No checkpoint"* ]]
}

# ---------- Happy path (baseline for corruption tests) ----------

@test "resume-discovery: valid checkpoint exits 0 and prints checkpoint path" {
  write_valid_checkpoint gaia-create-prd 3
  run "$DISCOVERY" gaia-create-prd
  [ "$status" -eq 0 ]
  # Output includes the selected checkpoint path
  [[ "$output" == *"gaia-create-prd"* ]]
  [[ "$output" == *"-step-3.json"* ]]
}

# ---------- VCP-CPT-06 — truncated JSON ----------

@test "truncated JSON exits 3 with corrupted checkpoint message" {
  write_valid_checkpoint gaia-create-prd 2
  local cp
  cp=$(latest_checkpoint_for gaia-create-prd)
  local full_size half_size
  full_size=$(wc -c < "$cp" | tr -d ' ')
  half_size=$((full_size / 2))
  # Truncate to half size — invalid JSON (mid-object).
  dd if="$cp" of="${cp}.tmp" bs=1 count="$half_size" status=none
  mv "${cp}.tmp" "$cp"
  run "$DISCOVERY" gaia-create-prd
  [ "$status" -eq 3 ]
  [[ "$output" == *"corrupted checkpoint"* ]]
  [[ "$output" == *"$cp"* ]]
  [[ "$output" == *"re-run"* ]] || [[ "$output" == *"Suggestion"* ]]
  # No bare Python traceback or bash 'unbound variable' leaks.
  ! [[ "$output" == *"Traceback"* ]]
  ! [[ "$output" == *"unbound variable"* ]]
}

# ---------- Syntax-error JSON ----------

@test "Syntax-error JSON exits 3 with classified message" {
  mkdir -p "$CHECKPOINT_ROOT/gaia-create-prd"
  printf '{"schema_version":1,"step_number": x }' \
    > "$CHECKPOINT_ROOT/gaia-create-prd/2026-04-24T10:00:00.000000Z-step-1.json"
  run "$DISCOVERY" gaia-create-prd
  [ "$status" -eq 3 ]
  [[ "$output" == *"corrupted checkpoint"* ]]
  ! [[ "$output" == *"Traceback"* ]]
}

# ---------- Empty file ----------

@test "Empty checkpoint file exits 3 with classified message" {
  mkdir -p "$CHECKPOINT_ROOT/gaia-create-prd"
  : > "$CHECKPOINT_ROOT/gaia-create-prd/2026-04-24T10:00:00.000000Z-step-1.json"
  run "$DISCOVERY" gaia-create-prd
  [ "$status" -eq 3 ]
  [[ "$output" == *"corrupted checkpoint"* ]] || [[ "$output" == *"empty"* ]]
}

# ---------- Non-UTF-8 bytes ----------

@test "Non-UTF-8 bytes in checkpoint exits 3 with classified message" {
  mkdir -p "$CHECKPOINT_ROOT/gaia-create-prd"
  # Binary garbage
  head -c 256 /dev/urandom \
    > "$CHECKPOINT_ROOT/gaia-create-prd/2026-04-24T10:00:00.000000Z-step-1.json"
  run "$DISCOVERY" gaia-create-prd
  [ "$status" -eq 3 ]
  [[ "$output" == *"corrupted checkpoint"* ]]
  ! [[ "$output" == *"Traceback"* ]]
}

# ---------- VCP-CPT-10 — orphan temp file alongside valid checkpoint ----------

@test "orphan temp file alongside valid checkpoint is filtered from discovery" {
  write_valid_checkpoint gaia-create-prd 3
  # Drop an orphan temp file matching the write-checkpoint.sh convention
  # ({FINAL}.tmp.$$) and the alternative leading-dot convention.
  local valid orphan_suffix orphan_dot
  valid=$(latest_checkpoint_for gaia-create-prd)
  orphan_suffix="${valid}.tmp.99999"
  orphan_dot="$CHECKPOINT_ROOT/gaia-create-prd/.tmp-2026-04-24T09:00:00.000000Z-step-3.json"
  printf 'partial-write-garbage' > "$orphan_suffix"
  printf 'partial-write-garbage' > "$orphan_dot"
  run "$DISCOVERY" gaia-create-prd
  [ "$status" -eq 0 ]
  [[ "$output" == *"$valid"* ]]
  # Cleanup guidance references both orphan files.
  [[ "$output" == *"orphan"* ]] || [[ "$output" == *"cleanup"* ]] || [[ "$output" == *"safe to delete"* ]]
  [[ "$output" == *"$orphan_suffix"* ]] || [[ "$output" == *".tmp.99999"* ]]
  [[ "$output" == *".tmp-2026-04-24T09:00:00.000000Z-step-3.json"* ]]
}

# ---------- Orphan temp file, no valid checkpoint ----------

@test "Orphan temp file with no valid checkpoint exits 2 with cleanup guidance" {
  mkdir -p "$CHECKPOINT_ROOT/gaia-create-prd"
  printf 'partial' \
    > "$CHECKPOINT_ROOT/gaia-create-prd/.tmp-2026-04-24T09:00:00.000000Z-step-1.json"
  run "$DISCOVERY" gaia-create-prd
  [ "$status" -eq 2 ]
  [[ "$output" == *"no checkpoint"* ]] || [[ "$output" == *"No checkpoint"* ]]
  # Cleanup guidance still emitted for the orphan.
  [[ "$output" == *".tmp-"* ]]
}

# ---------- Non-canonical filename ----------

@test "Non-canonical filename is ignored during discovery; cleanup guidance emitted" {
  write_valid_checkpoint gaia-create-prd 2
  local valid
  valid=$(latest_checkpoint_for gaia-create-prd)
  printf '{"schema_version":1}' \
    > "$CHECKPOINT_ROOT/gaia-create-prd/my-random-file.json"
  run "$DISCOVERY" gaia-create-prd
  [ "$status" -eq 0 ]
  [[ "$output" == *"$valid"* ]]
  [[ "$output" == *"my-random-file.json"* ]]
  [[ "$output" == *"non-canonical"* ]] || [[ "$output" == *"cleanup"* ]] || [[ "$output" == *"orphan"* ]]
}

# ---------- Multi-corruption: latest corrupted, earlier valid ----------

@test "Multi-corruption: latest corrupted reports all corruption cases in a structured list" {
  write_valid_checkpoint gaia-create-prd 1
  sleep 0.01
  write_valid_checkpoint gaia-create-prd 2
  sleep 0.01
  write_valid_checkpoint gaia-create-prd 3
  # Corrupt the latest (step 3)
  local all cp3 cp2
  # shellcheck disable=SC2012
  all=$(ls -1 "$CHECKPOINT_ROOT/gaia-create-prd"/*.json | sort)
  cp3=$(printf '%s\n' "$all" | grep 'step-3' | tail -1)
  cp2=$(printf '%s\n' "$all" | grep 'step-2' | tail -1)
  # Corrupt step 3 and step 2 (both latest and prior)
  printf 'not-json' > "$cp3"
  printf '{"schema' > "$cp2"
  run "$DISCOVERY" gaia-create-prd
  [ "$status" -eq 3 ]
  # All corrupted files reported
  [[ "$output" == *"$cp3"* ]]
  [[ "$output" == *"$cp2"* ]]
  [[ "$output" == *"corrupted checkpoint"* ]]
}

# ---------- Write-checkpoint post-write sanity check ----------

@test "write-checkpoint.sh: produced file always parses as valid JSON (post-write sanity)" {
  local f="$TEST_TMP/a.md"; printf 'x\n' > "$f"
  run "$WRITER" gaia-skill 1 --paths "$f"
  [ "$status" -eq 0 ]
  local cp
  cp=$(find "$CHECKPOINT_ROOT/gaia-skill" -name '*.json' -type f)
  # Round-trip via jq
  run jq . "$cp"
  [ "$status" -eq 0 ]
}

# ---------- No stack traces on any failure path ----------

@test "resume-discovery: no scenario emits an unhandled stack trace" {
  # Drop every kind of landmine
  mkdir -p "$CHECKPOINT_ROOT/gaia-skill"
  : > "$CHECKPOINT_ROOT/gaia-skill/2026-04-24T10:00:00.000000Z-step-1.json"
  printf '{"bad' > "$CHECKPOINT_ROOT/gaia-skill/2026-04-24T10:00:01.000000Z-step-2.json"
  head -c 32 /dev/urandom > "$CHECKPOINT_ROOT/gaia-skill/2026-04-24T10:00:02.000000Z-step-3.json"
  printf 'orphan' > "$CHECKPOINT_ROOT/gaia-skill/.tmp-2026-04-24T10:00:03.000000Z-step-4.json"
  printf 'noncanon' > "$CHECKPOINT_ROOT/gaia-skill/random.json"
  run "$DISCOVERY" gaia-skill
  # Exit non-zero but not 127/crash
  [ "$status" -ne 0 ]
  [ "$status" -le 3 ]
  ! [[ "$output" == *"Traceback"* ]]
  ! [[ "$output" == *"unbound variable"* ]]
  ! [[ "$output" == *"command not found"* ]]
}

# ---------- SKILL.md documents corruption + temp-file contract ----------

@test "SKILL.md documents the corruption-detection contract (exit 3)" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-resume/SKILL.md"
  grep -qE 'corrupt' "$skill"
  grep -qE 'exit[[:space:]]+3|exits?[[:space:]]*3' "$skill"
}

@test "SKILL.md documents temp-file filtering + cleanup guidance" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-resume/SKILL.md"
  grep -qiE 'temp[- ]file|orphan|\.tmp' "$skill"
  grep -qiE 'cleanup|safe to delete' "$skill"
}

@test "SKILL.md references resume-discovery.sh as the delegated script" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-resume/SKILL.md"
  grep -q 'resume-discovery.sh' "$skill"
}
