#!/usr/bin/env bats
# audit-v2-migration.bats — regression tests for the enriched fixture mode
# added under E28-S200.
#
# Covers ACs:
#   AC6 — --fixture-mode enriched pre-creates required prereq artifacts
#   AC7 — default mode is still minimal (flag is opt-in)
#   AC8 — enriched mode exports TEST_ARTIFACTS / PLANNING_ARTIFACTS /
#         IMPLEMENTATION_ARTIFACTS before each skill invocation
#   AC9 — `--fixture-mode enriched` returns 0 failing rows on a /tmp fixture
#   AC10 — default minimal mode continues to surface FixtureGap residuals
#
# The audit harness lives at gaia-public/scripts/audit-v2-migration.sh — one
# level above plugins/gaia/. SCRIPTS_DIR (test_helper.bash) points at
# plugins/gaia/scripts; we resolve the harness path from BATS_TEST_DIRNAME.

load 'test_helper.bash'

setup() {
  common_setup
  HARNESS="$BATS_TEST_DIRNAME/../../../scripts/audit-v2-migration.sh"
  PLUGIN_CACHE="$TEST_TMP/plugin-cache"
  PROJECT_ROOT="$TEST_TMP/project-root"
  mkdir -p "$PLUGIN_CACHE" "$PROJECT_ROOT"
}
teardown() { common_teardown; }

# ---------- Helpers ----------

# mk_minimal_project — set up a bare /tmp project with NO prereq artifacts
# (no docs/{planning,test,implementation}-artifacts content). This is what
# the default minimal fixture mode looks like.
mk_minimal_project() {
  :
}

# mk_skill_requiring_test_plan — create a fake skill whose setup.sh calls
# validate-gate.sh test_plan_exists. In minimal mode the gate should fail
# (fixture gap); in enriched mode the gate should pass.
mk_skill_requiring_test_plan() {
  local skill_name="$1"
  local skill_dir="$PLUGIN_CACHE/$skill_name"
  mkdir -p "$skill_dir/scripts"

  # Minimal setup.sh: require TEST_ARTIFACTS env var and fail loudly if the
  # file at $TEST_ARTIFACTS/test-plan.md is missing. Mirrors the real
  # validate-gate contract without depending on validate-gate.sh being on
  # PATH in bats.
  cat > "$skill_dir/scripts/setup.sh" <<'SETUP_EOF'
#!/usr/bin/env bash
set -euo pipefail
TEST_ARTIFACTS="${TEST_ARTIFACTS:-docs/test-artifacts}"
plan="$TEST_ARTIFACTS/test-plan.md"
if [ ! -f "$plan" ] || [ ! -s "$plan" ]; then
  printf 'fake-skill: test_plan_exists failed — expected: %s\n' "$plan" >&2
  exit 1
fi
exit 0
SETUP_EOF
  chmod +x "$skill_dir/scripts/setup.sh"
}

# ---------- Harness argument surface ----------

@test "E28-S200 AC7: --fixture-mode flag accepts minimal|enriched values" {
  run "$HARNESS" --help
  # --help exits 0 and prints usage; the usage must document the new flag.
  [ "$status" -eq 0 ]
  [[ "$output" == *"--fixture-mode"* ]]
  [[ "$output" == *"minimal"* ]]
  [[ "$output" == *"enriched"* ]]
}

@test "E28-S200 AC7: default fixture mode is minimal (no pre-created artifacts)" {
  mk_skill_requiring_test_plan fake-skill
  # Explicit CI=false — without it, the E28-S195 AC7 change would default
  # to enriched mode when the test runner itself runs under CI=true.
  CI="" run "$HARNESS" \
    --plugin-cache "$PLUGIN_CACHE" \
    --project-root "$PROJECT_ROOT" \
    --out "$TEST_TMP/audit.csv"
  # Under E28-S195 AC8 the harness now exits 1 when any skill fails.
  # fake-skill fails in minimal mode because test-plan.md is absent, so
  # exit 1 is the expected signal. (Pre-E28-S195 the harness exited 0.)
  [ "$status" -eq 1 ]
  # fake-skill's setup.sh must have failed because no test-plan.md exists.
  run grep -c '^fake-skill,' "$TEST_TMP/audit.csv"
  [ "$status" -eq 0 ]
  # The CSV row for fake-skill must NOT be in OK bucket — minimal mode does
  # not create the prereq artifact.
  run grep '^fake-skill,' "$TEST_TMP/audit.csv"
  [ "$status" -eq 0 ]
  [[ "$output" != *",OK"* ]]
}

# ---------- AC6 — enriched mode pre-creates prereq artifacts ----------

@test "E28-S200 AC6: --fixture-mode enriched creates prereq artifact files" {
  run "$HARNESS" \
    --plugin-cache "$PLUGIN_CACHE" \
    --project-root "$PROJECT_ROOT" \
    --fixture-mode enriched \
    --out "$TEST_TMP/audit.csv"
  [ "$status" -eq 0 ]
  # The 5 required prereq artifacts must now exist under the project root.
  [ -s "$PROJECT_ROOT/docs/planning-artifacts/prd.md" ]
  [ -s "$PROJECT_ROOT/docs/planning-artifacts/epics-and-stories.md" ]
  [ -s "$PROJECT_ROOT/docs/test-artifacts/test-plan.md" ]
  [ -s "$PROJECT_ROOT/docs/test-artifacts/traceability-matrix.md" ]
  [ -s "$PROJECT_ROOT/docs/test-artifacts/ci-setup.md" ]
}

# ---------- AC8 — enriched mode exports uppercase env vars ----------

@test "E28-S200 AC8: enriched mode exports TEST_ARTIFACTS so skills see the prereqs" {
  mk_skill_requiring_test_plan fake-skill
  run "$HARNESS" \
    --plugin-cache "$PLUGIN_CACHE" \
    --project-root "$PROJECT_ROOT" \
    --fixture-mode enriched \
    --out "$TEST_TMP/audit.csv"
  [ "$status" -eq 0 ]
  # fake-skill's setup.sh must now succeed — TEST_ARTIFACTS points at the
  # enriched-fixture path and test-plan.md exists there.
  run grep '^fake-skill,' "$TEST_TMP/audit.csv"
  [ "$status" -eq 0 ]
  [[ "$output" == *",OK"* ]]
}

# ---------- AC9 — enriched mode returns 0 failing rows ----------

@test "E28-S200 AC9: enriched mode — multi-prereq fake skill produces no B5 residuals" {
  # Seed two skills: one needs test-plan.md, one needs prd.md. Both should
  # pass under enriched mode because the harness pre-creates both and
  # exports the env vars.
  mk_skill_requiring_test_plan fake-skill-1

  local skill_dir="$PLUGIN_CACHE/fake-skill-2"
  mkdir -p "$skill_dir/scripts"
  cat > "$skill_dir/scripts/setup.sh" <<'SETUP_EOF'
#!/usr/bin/env bash
set -euo pipefail
PLANNING_ARTIFACTS="${PLANNING_ARTIFACTS:-docs/planning-artifacts}"
prd="$PLANNING_ARTIFACTS/prd.md"
if [ ! -f "$prd" ] || [ ! -s "$prd" ]; then
  printf 'fake-skill-2: prd_exists failed — expected: %s\n' "$prd" >&2
  exit 1
fi
exit 0
SETUP_EOF
  chmod +x "$skill_dir/scripts/setup.sh"

  run "$HARNESS" \
    --plugin-cache "$PLUGIN_CACHE" \
    --project-root "$PROJECT_ROOT" \
    --fixture-mode enriched \
    --out "$TEST_TMP/audit.csv"
  [ "$status" -eq 0 ]
  # No B5 rows (no "FixtureGap" residuals) — both skills OK.
  run grep -c ',B5$' "$TEST_TMP/audit.csv"
  # grep -c outputs 0 and exits 1 when no matches — accept that as "no B5".
  [[ "$output" == "0" ]]
  # Both rows must land in the OK bucket.
  run grep '^fake-skill-1,' "$TEST_TMP/audit.csv"
  [ "$status" -eq 0 ]
  [[ "$output" == *",OK"* ]]
  run grep '^fake-skill-2,' "$TEST_TMP/audit.csv"
  [ "$status" -eq 0 ]
  [[ "$output" == *",OK"* ]]
}

# ---------- AC10 — minimal mode still surfaces FixtureGap ----------

@test "E28-S200 AC10: minimal mode still surfaces the FixtureGap signal" {
  # Seed a skill that requires test-plan.md. In minimal mode there is no
  # prereq artifact and the harness must NOT pre-create one. The bucket
  # must be a failure bucket (not OK), proving the bug-detection mode was
  # not silently "fixed" by this story.
  mk_skill_requiring_test_plan fake-skill

  run "$HARNESS" \
    --plugin-cache "$PLUGIN_CACHE" \
    --project-root "$PROJECT_ROOT" \
    --fixture-mode minimal \
    --out "$TEST_TMP/audit.csv"
  # Under E28-S195 AC8 the harness now exits 1 on any skill failure.
  [ "$status" -eq 1 ]
  # Prereq artifacts must NOT be auto-created by minimal mode.
  [ ! -f "$PROJECT_ROOT/docs/test-artifacts/test-plan.md" ]
  [ ! -f "$PROJECT_ROOT/docs/planning-artifacts/prd.md" ]
  # fake-skill must have failed — land in a bucket other than OK.
  run grep '^fake-skill,' "$TEST_TMP/audit.csv"
  [ "$status" -eq 0 ]
  [[ "$output" != *",OK"* ]]
}

@test "E28-S200 AC7: explicit --fixture-mode minimal matches default behavior" {
  mk_skill_requiring_test_plan fake-skill
  # Run with --fixture-mode minimal and confirm the project root stays
  # bare of prereq artifacts. The skill failure causes exit 1 under
  # E28-S195 AC8 — the fixture semantics under test are independent of
  # the exit code signal.
  run "$HARNESS" \
    --plugin-cache "$PLUGIN_CACHE" \
    --project-root "$PROJECT_ROOT" \
    --fixture-mode minimal \
    --out "$TEST_TMP/audit-explicit.csv"
  [ "$status" -eq 1 ]
  [ ! -f "$PROJECT_ROOT/docs/test-artifacts/test-plan.md" ]
  [ ! -f "$PROJECT_ROOT/docs/planning-artifacts/prd.md" ]
}

@test "E28-S200: unknown --fixture-mode value rejected with exit 2" {
  run "$HARNESS" \
    --plugin-cache "$PLUGIN_CACHE" \
    --project-root "$PROJECT_ROOT" \
    --fixture-mode bogus \
    --out "$TEST_TMP/audit.csv"
  [ "$status" -eq 2 ]
  [[ "$output" == *"fixture-mode"* ]]
}

# ---------- E28-S195 — CI hardening regression tests ----------

# AC9 #1 — machine-readable summary line at end of every run.
# Format contract: `audit-v2-migration: result=<PASS|FAIL> total=<N> ok=<N> no_scripts=<N> failed=<N>`
# Emitted to stderr as the final summary line so CI can parse it with a grep.
@test "E28-S195 AC6/AC9: harness emits machine-readable summary line to stderr" {
  run "$HARNESS" \
    --plugin-cache "$PLUGIN_CACHE" \
    --project-root "$PROJECT_ROOT" \
    --fixture-mode enriched \
    --out "$TEST_TMP/audit.csv"
  # Empty plugin cache means 0 skills — should exit 0 (no failures).
  [ "$status" -eq 0 ]
  # stderr (merged into $output by bats `run`) must contain the summary line.
  [[ "$output" == *"audit-v2-migration: result="* ]]
  [[ "$output" == *"total="* ]]
  [[ "$output" == *"ok="* ]]
  [[ "$output" == *"no_scripts="* ]]
  [[ "$output" == *"failed="* ]]
  # With zero skills, result must be PASS.
  [[ "$output" == *"result=PASS"* ]]
}

# AC9 #2 — harness error (e.g., missing fixture dir) exits 2, not 1.
# Split exit code contract: 2 = harness itself erred.
@test "E28-S195 AC8/AC9: missing plugin-cache dir exits 2 (harness bug, not plugin regression)" {
  run "$HARNESS" \
    --plugin-cache "/nonexistent/path/does/not/exist-$$" \
    --project-root "$PROJECT_ROOT" \
    --fixture-mode enriched \
    --out "$TEST_TMP/audit.csv"
  [ "$status" -eq 2 ]
  # Error must mention plugin-cache so CI diagnostics are clear.
  [[ "$output" == *"plugin-cache"* ]]
}

# AC9 #3 — CI=true + no --fixture-mode flag defaults to enriched.
# When CI is set, harness behaves like the CI gate: enriched fixture,
# summary line, step-summary markdown. This test only asserts the
# default-to-enriched behaviour.
@test "E28-S195 AC7/AC9: CI=true + no flag defaults to --fixture-mode enriched" {
  CI=true run "$HARNESS" \
    --plugin-cache "$PLUGIN_CACHE" \
    --project-root "$PROJECT_ROOT" \
    --out "$TEST_TMP/audit.csv"
  [ "$status" -eq 0 ]
  # Enriched mode pre-creates prereq artifacts — assert side-effect.
  [ -s "$PROJECT_ROOT/docs/test-artifacts/test-plan.md" ]
  [ -s "$PROJECT_ROOT/docs/planning-artifacts/prd.md" ]
  # Summary line must report enriched fixture mode.
  [[ "$output" == *"fixture_mode: enriched"* ]]
}

# AC8 — split exit codes: one or more B1-B5 failures => exit 1 (plugin
# regression), not 0. Covers the transition from "conflate 1 and 2" to
# distinct regression vs. harness-bug semantics.
@test "E28-S195 AC8: skill failure (B1-B5 bucket) triggers exit 1 (plugin regression)" {
  # Seed a skill that fails in enriched mode even though prereqs exist.
  local skill_dir="$PLUGIN_CACHE/regress-skill"
  mkdir -p "$skill_dir/scripts"
  cat > "$skill_dir/scripts/setup.sh" <<'SETUP_EOF'
#!/usr/bin/env bash
# Simulate a B5 regression — skill exits non-zero with unrecognised stderr.
printf 'regress-skill: simulated regression\n' >&2
exit 1
SETUP_EOF
  chmod +x "$skill_dir/scripts/setup.sh"

  run "$HARNESS" \
    --plugin-cache "$PLUGIN_CACHE" \
    --project-root "$PROJECT_ROOT" \
    --fixture-mode enriched \
    --out "$TEST_TMP/audit.csv"
  # Plugin regression now exits 1 (not 0, not 2).
  [ "$status" -eq 1 ]
  # Summary line must report FAIL and at least one failed skill.
  [[ "$output" == *"result=FAIL"* ]]
}

# AC7 — when GITHUB_STEP_SUMMARY is set, harness appends a markdown block.
# ---------- E28-S213 — config/project-config.yaml seeding in enriched fixture ----------

# AC1 / Subtask 2.1 — enriched mode seeds config/project-config.yaml with all 10 required fields.
@test "E28-S213 AC1: --fixture-mode enriched creates config/project-config.yaml with all 10 required fields" {
  run "$HARNESS" \
    --plugin-cache "$PLUGIN_CACHE" \
    --project-root "$PROJECT_ROOT" \
    --fixture-mode enriched \
    --out "$TEST_TMP/audit.csv"
  [ "$status" -eq 0 ]
  # The config file must exist and be non-empty.
  [ -s "$PROJECT_ROOT/config/project-config.yaml" ]
  # All 10 required fields must be present as keys in the file.
  local cfg="$PROJECT_ROOT/config/project-config.yaml"
  grep -q '^project_root:' "$cfg"
  grep -q '^project_path:' "$cfg"
  grep -q '^memory_path:' "$cfg"
  grep -q '^checkpoint_path:' "$cfg"
  grep -q '^installed_path:' "$cfg"
  grep -q '^framework_version:' "$cfg"
  grep -q '^date:' "$cfg"
  grep -q '^test_artifacts:' "$cfg"
  grep -q '^planning_artifacts:' "$cfg"
  grep -q '^implementation_artifacts:' "$cfg"
}

# AC3 / Subtask 2.2 — minimal mode must NOT create config/project-config.yaml.
@test "E28-S213 AC3: --fixture-mode minimal does NOT create config/project-config.yaml" {
  mk_skill_requiring_test_plan fake-skill
  run "$HARNESS" \
    --plugin-cache "$PLUGIN_CACHE" \
    --project-root "$PROJECT_ROOT" \
    --fixture-mode minimal \
    --out "$TEST_TMP/audit.csv"
  # Exit 1 expected (fake-skill fails in minimal mode — no prereqs).
  [ "$status" -eq 1 ]
  # config/project-config.yaml must NOT be created in minimal mode.
  [ ! -f "$PROJECT_ROOT/config/project-config.yaml" ]
}

# AC4 / Subtask 2.3 — calling prepare_enriched_fixture twice is idempotent (file not overwritten).
@test "E28-S213 AC4: enriched fixture idempotent — project-config.yaml not overwritten on second run" {
  run "$HARNESS" \
    --plugin-cache "$PLUGIN_CACHE" \
    --project-root "$PROJECT_ROOT" \
    --fixture-mode enriched \
    --out "$TEST_TMP/audit-first.csv"
  [ "$status" -eq 0 ]
  [ -s "$PROJECT_ROOT/config/project-config.yaml" ]
  # Capture checksum after first run.
  local cksum1
  cksum1=$(shasum -a 256 "$PROJECT_ROOT/config/project-config.yaml" | awk '{print $1}')
  # Run the harness again (simulates a re-run on the same PROJECT_ROOT).
  run "$HARNESS" \
    --plugin-cache "$PLUGIN_CACHE" \
    --project-root "$PROJECT_ROOT" \
    --fixture-mode enriched \
    --out "$TEST_TMP/audit-second.csv"
  [ "$status" -eq 0 ]
  local cksum2
  cksum2=$(shasum -a 256 "$PROJECT_ROOT/config/project-config.yaml" | awk '{print $1}')
  # Checksums must be equal — file was not overwritten.
  [ "$cksum1" = "$cksum2" ]
}

@test "E28-S195 AC7: GITHUB_STEP_SUMMARY receives a markdown summary block" {
  local summary_file="$TEST_TMP/step-summary.md"
  : > "$summary_file"
  GITHUB_STEP_SUMMARY="$summary_file" run "$HARNESS" \
    --plugin-cache "$PLUGIN_CACHE" \
    --project-root "$PROJECT_ROOT" \
    --fixture-mode enriched \
    --out "$TEST_TMP/audit.csv"
  [ "$status" -eq 0 ]
  # The file must now contain the markdown summary block.
  [ -s "$summary_file" ]
  run cat "$summary_file"
  [[ "$output" == *"audit-v2-migration"* ]]
  [[ "$output" == *"| "* ]]  # at least one markdown table row
}
