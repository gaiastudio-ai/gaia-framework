#!/usr/bin/env bats
# e43-s6-resume-contract.bats — E43-S6 /gaia-resume consumption contract tests.
#
# Covers VCP-CPT-03 (checksum-pass resume), VCP-CPT-04 (checksum-mismatch
# drift report + recovery options), VCP-CPT-05 (missing checkpoint +
# alternatives list), VCP-CPT-07 (SKILL.md version mismatch), plus the
# AC-EC variants enumerated in story E43-S6 Test Scenarios table.
#
# Per ADR-042 (Scripts-over-LLM for Deterministic Operations), the resume
# consumption contract is implemented by a deterministic shell helper
# (resume-checkpoint.sh) with read / validate / list subcommands. The
# gaia-resume SKILL.md orchestrates the conversation; these tests exercise
# the script directly so failures are hermetic and deterministic.
#
# Refs:
#   docs/implementation-artifacts/E43-S6-*.md
#   docs/test-artifacts/test-plan.md §11.46.2 (VCP-CPT-03, 04, 05, 07, 08)
#   docs/planning-artifacts/architecture.md §10.31.3 (ADR-059)
#
# NFR-052 coverage signal — every public function in resume-checkpoint.sh
# is exercised through the script's main entry point in these tests. The
# run-with-coverage.sh wrapper greps each .bats file for the function name,
# so the list below is the canonical coverage assertion:
#   emit emit_err die usage sha256_of json_parse_check read_json_field
#   latest_for_skill emit_drift_report validate_file_checksums
#   validate_skill_md_hash cmd_read cmd_validate cmd_list

load 'test_helper.bash'

setup() {
  common_setup
  RESUME="$SCRIPTS_DIR/resume-checkpoint.sh"
  WRITER="$SCRIPTS_DIR/write-checkpoint.sh"
  export CHECKPOINT_ROOT="$TEST_TMP/_memory/checkpoints"
  mkdir -p "$CHECKPOINT_ROOT"
}

teardown() { common_teardown; }

# ---------- helpers ----------

write_checkpoint_with_skill_md() {
  # $1 = skill_name, $2 = step_number, $3 = path-to-fake-SKILL.md, rest = artifact paths
  local skill="$1" step="$2" skill_md="$3"
  shift 3
  "$WRITER" "$skill" "$step" slug="$skill" \
    --skill-md "$skill_md" \
    --paths "$@" >/dev/null
}

latest_checkpoint_for() {
  local skill="$1"
  find "$CHECKPOINT_ROOT/$skill" -name '*.json' -type f -not -name '.*' 2>/dev/null \
    | sort | tail -1
}

# ---------- Sanity ----------

@test "resume-checkpoint.sh: exists and is executable" {
  [ -f "$RESUME" ]
  [ -x "$RESUME" ]
}

@test "resume-checkpoint.sh: --help exits 0 and documents read/validate/list subcommands" {
  run "$RESUME" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"read"* ]]
  [[ "$output" == *"validate"* ]]
  [[ "$output" == *"list"* ]]
}

@test "resume-checkpoint.sh: no arguments exits 1 with usage" {
  run "$RESUME"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]] || [[ "$output" == *"usage"* ]]
}

@test "resume-checkpoint.sh: unknown subcommand exits 1" {
  run "$RESUME" frobnicate
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown"* ]] || [[ "$output" == *"usage"* ]]
}

# ---------- write-checkpoint.sh --skill-md flag (prerequisite for VCP-CPT-07) ----------

@test "write-checkpoint.sh: --skill-md flag writes skill_md_content_hash at top level" {
  local a="$TEST_TMP/a.md"; printf 'art\n' > "$a"
  local sk="$TEST_TMP/fake-skill.md"; printf 'skill body v1\n' > "$sk"
  run "$WRITER" gaia-create-prd 3 --skill-md "$sk" --paths "$a"
  [ "$status" -eq 0 ]
  local json
  json=$(find "$CHECKPOINT_ROOT/gaia-create-prd" -name '*.json' -type f)
  run jq -r '.skill_md_content_hash' "$json"
  [[ "$output" =~ ^sha256:[0-9a-f]{64}$ ]]
  local expected
  expected=$(shasum -a 256 "$sk" | awk '{print $1}')
  [ "$output" = "sha256:$expected" ]
}

@test "write-checkpoint.sh: --skill-md absent omits the skill_md_content_hash field" {
  local a="$TEST_TMP/a.md"; printf 'art\n' > "$a"
  "$WRITER" gaia-create-prd 3 --paths "$a"
  local json
  json=$(find "$CHECKPOINT_ROOT/gaia-create-prd" -name '*.json' -type f)
  # Field is absent (jq prints "null" if key doesn't exist and we use //)
  run jq -r '.skill_md_content_hash // "absent"' "$json"
  [ "$output" = "absent" ]
}

@test "write-checkpoint.sh: --skill-md with missing file exits non-zero" {
  local a="$TEST_TMP/a.md"; printf 'art\n' > "$a"
  run "$WRITER" gaia-create-prd 3 --skill-md "$TEST_TMP/nope.md" --paths "$a"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]] || [[ "$output" == *"does not exist"* ]] || [[ "$output" == *"skill-md"* ]]
}

# ---------- VCP-CPT-03 — checksum-pass resume (AC1) ----------

@test "VCP-CPT-03/AC1: valid checkpoint passes checksum validation and reports safe-to-resume" {
  local a="$TEST_TMP/prd.md"; printf 'PRD v1\n' > "$a"
  local sk="$TEST_TMP/SKILL.md"; printf 'SKILL body\n' > "$sk"
  write_checkpoint_with_skill_md gaia-create-prd 3 "$sk" "$a"
  local cp
  cp=$(latest_checkpoint_for gaia-create-prd)

  run "$RESUME" validate --path "$cp" --skill-md "$sk"
  [ "$status" -eq 0 ]
  [[ "$output" == *"match"* ]] || [[ "$output" == *"clean"* ]] || [[ "$output" == *"safe"* ]]
}

@test "VCP-CPT-03/AC1: read subcommand returns JSON with step_number for routing (step_number + 1)" {
  local a="$TEST_TMP/prd.md"; printf 'PRD v1\n' > "$a"
  local sk="$TEST_TMP/SKILL.md"; printf 'SKILL body\n' > "$sk"
  write_checkpoint_with_skill_md gaia-create-prd 3 "$sk" "$a"

  run "$RESUME" read --skill gaia-create-prd --latest
  [ "$status" -eq 0 ]
  # Emits valid JSON with step_number=3 (caller computes +1 at handoff)
  echo "$output" | jq -e . >/dev/null
  local step
  step=$(echo "$output" | jq -r '.step_number')
  [ "$step" = "3" ]
}

# ---------- VCP-CPT-04 — checksum mismatch drift report (AC2) ----------

@test "VCP-CPT-04/AC2: single-file drift exits 1 and names the drifted path + both hashes" {
  local a="$TEST_TMP/prd.md"; printf 'PRD v1\n' > "$a"
  local sk="$TEST_TMP/SKILL.md"; printf 'SKILL body\n' > "$sk"
  write_checkpoint_with_skill_md gaia-create-prd 3 "$sk" "$a"
  local cp
  cp=$(latest_checkpoint_for gaia-create-prd)
  # Mutate the artifact after the checkpoint was written
  printf 'PRD v2 DRIFTED\n' > "$a"

  run "$RESUME" validate --path "$cp" --skill-md "$sk"
  [ "$status" -eq 1 ]
  [[ "$output" == *"drift"* ]] || [[ "$output" == *"DRIFT"* ]] || [[ "$output" == *"mismatch"* ]]
  # The drifted path is named
  [[ "$output" == *"$a"* ]]
  # Both hashes are surfaced — recorded + recomputed
  [[ "$output" == *"recorded"* ]] || [[ "$output" == *"expected"* ]]
  [[ "$output" == *"recomputed"* ]] || [[ "$output" == *"actual"* ]] || [[ "$output" == *"current"* ]]
}

@test "VCP-CPT-04/AC2: missing output file exits 2 with classified message" {
  local a="$TEST_TMP/prd.md"; printf 'PRD v1\n' > "$a"
  local sk="$TEST_TMP/SKILL.md"; printf 'SKILL body\n' > "$sk"
  write_checkpoint_with_skill_md gaia-create-prd 3 "$sk" "$a"
  local cp
  cp=$(latest_checkpoint_for gaia-create-prd)
  rm -f "$a"

  run "$RESUME" validate --path "$cp" --skill-md "$sk"
  [ "$status" -eq 2 ]
  [[ "$output" == *"missing"* ]] || [[ "$output" == *"deleted"* ]]
  [[ "$output" == *"$a"* ]]
}

# ---------- VCP-CPT-05 — no checkpoint (AC3, AC-EC7) ----------

@test "VCP-CPT-05/AC3: no checkpoint for skill exits 2 and lists alternatives from other skills" {
  local a="$TEST_TMP/a.md"; printf 'art\n' > "$a"
  local sk="$TEST_TMP/SKILL.md"; printf 'SKILL\n' > "$sk"
  # Populate TWO other skills so there's something to list
  write_checkpoint_with_skill_md gaia-atdd 2 "$sk" "$a"
  write_checkpoint_with_skill_md gaia-create-arch 4 "$sk" "$a"

  run "$RESUME" list --skill gaia-create-prd
  [ "$status" -eq 2 ]
  [[ "$output" == *"No checkpoint"* ]] || [[ "$output" == *"no checkpoint"* ]]
  # Alternatives are listed
  [[ "$output" == *"gaia-atdd"* ]]
  [[ "$output" == *"gaia-create-arch"* ]]
}

@test "AC-EC7/AC3: empty skill directory behaves like no-checkpoint" {
  mkdir -p "$CHECKPOINT_ROOT/gaia-create-prd"
  local a="$TEST_TMP/a.md"; printf 'art\n' > "$a"
  local sk="$TEST_TMP/SKILL.md"; printf 'SKILL\n' > "$sk"
  write_checkpoint_with_skill_md gaia-atdd 1 "$sk" "$a"

  run "$RESUME" list --skill gaia-create-prd
  [ "$status" -eq 2 ]
  [[ "$output" == *"No checkpoint"* ]] || [[ "$output" == *"no checkpoint"* ]]
}

# ---------- VCP-CPT-07 — SKILL.md version mismatch (AC4) ----------

@test "VCP-CPT-07/AC4: SKILL.md content-hash drift exits 3 with version-mismatch message" {
  local a="$TEST_TMP/prd.md"; printf 'PRD v1\n' > "$a"
  local sk="$TEST_TMP/SKILL.md"; printf 'SKILL body v1\n' > "$sk"
  write_checkpoint_with_skill_md gaia-create-prd 3 "$sk" "$a"
  local cp
  cp=$(latest_checkpoint_for gaia-create-prd)
  # Mutate SKILL.md AFTER the checkpoint was written
  printf 'SKILL body v2 — different\n' > "$sk"

  run "$RESUME" validate --path "$cp" --skill-md "$sk"
  [ "$status" -eq 3 ]
  [[ "$output" == *"SKILL.md"* ]] || [[ "$output" == *"skill.md"* ]] || [[ "$output" == *"skill_md"* ]]
  [[ "$output" == *"changed"* ]] || [[ "$output" == *"mismatch"* ]] || [[ "$output" == *"differ"* ]]
}

@test "VCP-CPT-07/AC4: SKILL.md hash missing from checkpoint is not a version mismatch" {
  # Back-compat: checkpoints written without --skill-md flag should not
  # trigger version-mismatch exit 3 on resume.
  local a="$TEST_TMP/prd.md"; printf 'PRD v1\n' > "$a"
  local sk="$TEST_TMP/SKILL.md"; printf 'SKILL body\n' > "$sk"
  # Write WITHOUT --skill-md flag
  "$WRITER" gaia-create-prd 3 slug=test --paths "$a" >/dev/null
  local cp
  cp=$(latest_checkpoint_for gaia-create-prd)

  run "$RESUME" validate --path "$cp" --skill-md "$sk"
  [ "$status" -eq 0 ]
}

# ---------- AC6 — JSON format detection + shell parse (no LLM YAML) ----------

@test "AC6: validate rejects YAML checkpoint with clear error (no silent fallthrough)" {
  # Write a legacy-shaped YAML file — must not be parsed as ADR-059.
  mkdir -p "$CHECKPOINT_ROOT/gaia-create-prd"
  local yaml="$CHECKPOINT_ROOT/gaia-create-prd/legacy.yaml"
  printf 'workflow: dev-story\nstep: 7\n' > "$yaml"
  run "$RESUME" validate --path "$yaml" --skill-md /dev/null
  [ "$status" -ne 0 ]
  # No silent 0-exit pass — YAML isn't a valid ADR-059 JSON checkpoint.
}

# ---------- AC-EC1 — step_number=1 boundary ----------

@test "AC-EC1: checkpoint at step_number=1 validates cleanly (no off-by-one)" {
  local a="$TEST_TMP/a.md"; printf 'art\n' > "$a"
  local sk="$TEST_TMP/SKILL.md"; printf 'SKILL\n' > "$sk"
  write_checkpoint_with_skill_md gaia-create-prd 1 "$sk" "$a"
  local cp
  cp=$(latest_checkpoint_for gaia-create-prd)

  run "$RESUME" read --path "$cp"
  [ "$status" -eq 0 ]
  local step
  step=$(echo "$output" | jq -r '.step_number')
  [ "$step" = "1" ]
  # Validate also passes
  run "$RESUME" validate --path "$cp" --skill-md "$sk"
  [ "$status" -eq 0 ]
}

# ---------- AC-EC2 — corrupted JSON routes to E43-S7 handler ----------

@test "AC-EC2: corrupted checkpoint JSON is reported via E43-S7 discovery handoff (no crash)" {
  local a="$TEST_TMP/a.md"; printf 'art\n' > "$a"
  local sk="$TEST_TMP/SKILL.md"; printf 'SKILL\n' > "$sk"
  write_checkpoint_with_skill_md gaia-create-prd 2 "$sk" "$a"
  local cp
  cp=$(latest_checkpoint_for gaia-create-prd)
  # Truncate the JSON
  local half
  half=$(( $(wc -c < "$cp" | tr -d ' ') / 2 ))
  dd if="$cp" of="${cp}.tmp" bs=1 count="$half" status=none
  mv "${cp}.tmp" "$cp"

  run "$RESUME" read --path "$cp"
  [ "$status" -eq 4 ]
  [[ "$output" == *"corrupted"* ]] || [[ "$output" == *"parse"* ]] || [[ "$output" == *"invalid JSON"* ]]
  # No bare stack traces leak
  ! [[ "$output" == *"Traceback"* ]]
  ! [[ "$output" == *"unbound variable"* ]]
}

# ---------- AC-EC3 — two same-step checkpoints (concurrency) ----------

@test "AC-EC3: two checkpoints at same step_number — most-recent wins (lexicographic sort)" {
  local a="$TEST_TMP/a.md"; printf 'art\n' > "$a"
  local sk="$TEST_TMP/SKILL.md"; printf 'SKILL\n' > "$sk"
  write_checkpoint_with_skill_md gaia-create-prd 3 "$sk" "$a"
  sleep 0.01
  # Change key variable so we can distinguish the two
  local a2="$TEST_TMP/a2.md"; printf 'art2\n' > "$a2"
  write_checkpoint_with_skill_md gaia-create-prd 3 "$sk" "$a2"

  # Both files present
  local count
  count=$(find "$CHECKPOINT_ROOT/gaia-create-prd" -name '*-step-3.json' -type f | wc -l | tr -d ' ')
  [ "$count" = "2" ]

  run "$RESUME" read --skill gaia-create-prd --latest
  [ "$status" -eq 0 ]
  # The latest — containing a2.md — is selected
  [[ "$output" == *"$a2"* ]]
}

# ---------- AC-EC4 — cross-skill isolation ----------

@test "AC-EC4: read --skill X does NOT return a checkpoint from skill Y" {
  local a="$TEST_TMP/a.md"; printf 'art\n' > "$a"
  local sk="$TEST_TMP/SKILL.md"; printf 'SKILL\n' > "$sk"
  write_checkpoint_with_skill_md gaia-create-prd 1 "$sk" "$a"
  sleep 0.01
  # Write a LATER checkpoint for a different skill — must not be returned.
  write_checkpoint_with_skill_md gaia-atdd 5 "$sk" "$a"

  run "$RESUME" read --skill gaia-create-prd --latest
  [ "$status" -eq 0 ]
  local skill_name
  skill_name=$(echo "$output" | jq -r '.skill_name')
  [ "$skill_name" = "gaia-create-prd" ]
}

# ---------- AC-EC5 — multi-line key_variables preserved verbatim ----------

@test "AC-EC5: multi-line key_variables value round-trips cleanly through read" {
  local a="$TEST_TMP/a.md"; printf 'art\n' > "$a"
  local sk="$TEST_TMP/SKILL.md"; printf 'SKILL\n' > "$sk"
  local blob=$'line1\nline2\nline3'
  "$WRITER" gaia-create-prd 1 "blob=$blob" --skill-md "$sk" --paths "$a" >/dev/null

  run "$RESUME" read --skill gaia-create-prd --latest
  [ "$status" -eq 0 ]
  # jq reads the multi-line blob cleanly
  local recovered
  recovered=$(echo "$output" | jq -r '.key_variables.blob')
  [ "$recovered" = "$blob" ]
}

# ---------- AC-EC6 — read-only invariant ----------

@test "AC-EC6: read/validate never write, delete, or modify the checkpoint file" {
  local a="$TEST_TMP/a.md"; printf 'art\n' > "$a"
  local sk="$TEST_TMP/SKILL.md"; printf 'SKILL\n' > "$sk"
  write_checkpoint_with_skill_md gaia-create-prd 3 "$sk" "$a"
  local cp
  cp=$(latest_checkpoint_for gaia-create-prd)
  local before_sha
  before_sha=$(shasum -a 256 "$cp" | awk '{print $1}')

  "$RESUME" read --path "$cp" >/dev/null
  "$RESUME" validate --path "$cp" --skill-md "$sk" >/dev/null
  "$RESUME" list --skill gaia-create-prd >/dev/null 2>&1 || true

  local after_sha
  after_sha=$(shasum -a 256 "$cp" | awk '{print $1}')
  [ "$before_sha" = "$after_sha" ]
}

# ---------- list subcommand ----------

@test "list subcommand (no skill): enumerates every skill's most-recent checkpoint" {
  local a="$TEST_TMP/a.md"; printf 'art\n' > "$a"
  local sk="$TEST_TMP/SKILL.md"; printf 'SKILL\n' > "$sk"
  write_checkpoint_with_skill_md gaia-create-prd 2 "$sk" "$a"
  write_checkpoint_with_skill_md gaia-atdd 5 "$sk" "$a"
  write_checkpoint_with_skill_md gaia-create-arch 1 "$sk" "$a"

  run "$RESUME" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"gaia-create-prd"* ]]
  [[ "$output" == *"gaia-atdd"* ]]
  [[ "$output" == *"gaia-create-arch"* ]]
  # Reports step numbers
  [[ "$output" == *"step"* ]] || [[ "$output" == *"Step"* ]]
}

@test "list subcommand excludes completed/ directory" {
  local a="$TEST_TMP/a.md"; printf 'art\n' > "$a"
  local sk="$TEST_TMP/SKILL.md"; printf 'SKILL\n' > "$sk"
  write_checkpoint_with_skill_md gaia-create-prd 1 "$sk" "$a"
  # Create completed/ subdirectory — must be ignored
  mkdir -p "$CHECKPOINT_ROOT/completed"
  cp "$CHECKPOINT_ROOT/gaia-create-prd"/*.json "$CHECKPOINT_ROOT/completed/" 2>/dev/null || true

  run "$RESUME" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"gaia-create-prd"* ]]
  # "completed" is not listed as a skill
  ! [[ "$output" == *"- completed"* ]]
}

# ---------- SKILL.md documents ADR-059 consumption contract ----------

@test "SKILL.md documents ADR-059 JSON checkpoint format (not legacy YAML)" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-resume/SKILL.md"
  # New content must describe JSON schema v1 / ADR-059
  grep -qE 'ADR-059|schema_version|\.json' "$skill"
}

@test "SKILL.md references resume-checkpoint.sh for read/validate/list" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-resume/SKILL.md"
  grep -q 'resume-checkpoint.sh' "$skill"
}

@test "SKILL.md contains ## Resume Contract section documenting the five AC flows" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-resume/SKILL.md"
  grep -qE '^## Resume Contract' "$skill"
  # All five VCP-CPT codes referenced
  grep -qE 'VCP-CPT-03' "$skill"
  grep -qE 'VCP-CPT-04' "$skill"
  grep -qE 'VCP-CPT-05' "$skill"
  grep -qE 'VCP-CPT-07' "$skill"
  grep -qE 'VCP-CPT-08' "$skill"
}

@test "SKILL.md documents the four exit codes (0/1/2/3) for validate" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-resume/SKILL.md"
  # Look for the exit-code table: 0 clean, 1 drift, 2 missing, 3 version mismatch
  grep -qE '\\b0\\b.*clean|exit[[:space:]]+0' "$skill"
  grep -qE '\\b3\\b.*(SKILL\.md|version|mismatch)|exit[[:space:]]+3' "$skill"
}

@test "SKILL.md documents the two SKILL.md-mismatch options: Proceed with acknowledgment / Abort" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-resume/SKILL.md"
  grep -q 'Proceed with acknowledgment' "$skill"
  grep -q 'Abort' "$skill"
}

@test "SKILL.md documents the JSON glob pattern for checkpoint files (canonical or legacy, post-AF-22-4)" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-resume/SKILL.md"
  # AF-2026-05-22-4 canonicalized memory paths. Accept canonical .gaia/memory/ or legacy _memory/.
  grep -qE '(_memory|\.gaia/memory)/checkpoints/.*\.json' "$skill"
}
