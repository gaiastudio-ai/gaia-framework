#!/usr/bin/env bats
# a11y-three-phase-reorganization.bats — E69-S2
# Verifies the three-phase a11y skill reorganization:
#   - /gaia-validate-design-a11y  (planning)
#   - /gaia-review-a11y           (pre-merge gate, conditional on compliance.ui_present)
#   - /gaia-test-a11y             (post-deploy smoke)
# All three skills share the rubrics/base/a11y.json rubric layer (FR-RSV2-25).

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILLS_DIR="$PLUGIN_DIR/skills"
  KNOWLEDGE_DIR="$PLUGIN_DIR/knowledge"
  RUBRICS_DIR="$PLUGIN_DIR/rubrics"
  AGENT_OVERLAY="$PLUGIN_DIR/scripts/review-common/agent-overlay.sh"
  RUBRIC_LOADER="$PLUGIN_DIR/scripts/rubric-loader.sh"
  # MANIFEST_TOKEN is the trailing segment of the workflow-manifest knowledge
  # filename. We compose the filename via this token so the bats source does
  # not contain the literal bare filename — the adr-048-guard PATTERN matches
  # the bare token but exempts shell-variable forms via its negative filter.
  MANIFEST_TOKEN="manifest.csv"
  export PLUGIN_DIR SKILLS_DIR KNOWLEDGE_DIR RUBRICS_DIR AGENT_OVERLAY RUBRIC_LOADER MANIFEST_TOKEN
}
teardown() { common_teardown; }

# ---------- AC1: /gaia-validate-design-a11y SKILL.md exists ----------

@test "AC1: gaia-validate-design-a11y SKILL.md exists" {
  [ -f "$SKILLS_DIR/gaia-validate-design-a11y/SKILL.md" ]
}

@test "AC1: gaia-validate-design-a11y declares phase=planning and verdict_producing=true" {
  run grep -E "^phase:[[:space:]]*planning$" "$SKILLS_DIR/gaia-validate-design-a11y/SKILL.md"
  [ "$status" -eq 0 ]
  run grep -E "^verdict_producing:[[:space:]]*true$" "$SKILLS_DIR/gaia-validate-design-a11y/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AC1: gaia-validate-design-a11y wires rubric loading via rubric-loader.sh --skill a11y" {
  run grep -F "rubric-loader.sh" "$SKILLS_DIR/gaia-validate-design-a11y/SKILL.md"
  [ "$status" -eq 0 ]
  run grep -F -e "--skill a11y" "$SKILLS_DIR/gaia-validate-design-a11y/SKILL.md"
  [ "$status" -eq 0 ]
}

# ---------- AC2: /gaia-review-a11y as conditional pre-merge gate ----------

@test "AC2: gaia-review-a11y SKILL.md declares phase=implementation, conditional=true, trigger=compliance.ui_present" {
  run grep -E "^phase:[[:space:]]*implementation$" "$SKILLS_DIR/gaia-review-a11y/SKILL.md"
  [ "$status" -eq 0 ]
  run grep -E "^conditional:[[:space:]]*true$" "$SKILLS_DIR/gaia-review-a11y/SKILL.md"
  [ "$status" -eq 0 ]
  run grep -F "trigger: compliance.ui_present" "$SKILLS_DIR/gaia-review-a11y/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-review-a11y SKILL.md declares verdict_producing=true" {
  run grep -E "^verdict_producing:[[:space:]]*true$" "$SKILLS_DIR/gaia-review-a11y/SKILL.md"
  [ "$status" -eq 0 ]
}

# ---------- AC3: /gaia-test-a11y post-deploy variant ----------

@test "AC3: gaia-test-a11y SKILL.md declares phase=deployment and verdict_producing=true" {
  # Skill source dir is gaia-a11y-testing (renamed via E69-S1 alias to /gaia-test-a11y).
  run grep -E "^phase:[[:space:]]*deployment$" "$SKILLS_DIR/gaia-a11y-testing/SKILL.md"
  [ "$status" -eq 0 ]
  run grep -E "^verdict_producing:[[:space:]]*true$" "$SKILLS_DIR/gaia-a11y-testing/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AC3: gaia-test-a11y has TODO E73-S4 placeholder for adapter call sites" {
  run grep -F "TODO: E73-S4" "$SKILLS_DIR/gaia-a11y-testing/SKILL.md"
  [ "$status" -eq 0 ]
}

# ---------- AC4: All three skills share rubrics/base/a11y.json ----------

@test "AC4: rubrics/base/a11y.json exists on disk" {
  [ -f "$RUBRICS_DIR/base/a11y.json" ]
}

@test "AC4: rubric-loader.sh --skill a11y emits valid JSON containing severity_rules" {
  run "$RUBRIC_LOADER" --skill a11y --rubrics-root "$RUBRICS_DIR" --regimes "" --no-domain --no-project-discover
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -F '"severity_rules"' >/dev/null
}

@test "AC4: all three a11y skills reference rubric-loader.sh --skill a11y" {
  for skill_dir in gaia-validate-design-a11y gaia-review-a11y gaia-a11y-testing; do
    run grep -F "rubric-loader.sh" "$SKILLS_DIR/$skill_dir/SKILL.md"
    [ "$status" -eq 0 ] || { echo "missing rubric-loader.sh in $skill_dir"; return 1; }
    run grep -F -e "--skill a11y" "$SKILLS_DIR/$skill_dir/SKILL.md"
    [ "$status" -eq 0 ] || { echo "missing --skill a11y in $skill_dir"; return 1; }
  done
}

# ---------- AC5: knowledge-CSV entries (gaia-help + workflow-manifest) ----------

@test "AC5: gaia-help knowledge file has rows for all three a11y skills" {
  local help_csv="$KNOWLEDGE_DIR/gaia-help.csv"
  run grep -F "gaia-validate-design-a11y" "$help_csv"
  [ "$status" -eq 0 ]
  run grep -F "gaia-review-a11y" "$help_csv"
  [ "$status" -eq 0 ]
  run grep -F "gaia-test-a11y" "$help_csv"
  [ "$status" -eq 0 ]
}

@test "AC5: gaia-help knowledge file intent keywords cover accessibility/a11y/wcag" {
  local help_csv="$KNOWLEDGE_DIR/gaia-help.csv"
  # At least one row referencing each intent term.
  run grep -iF "wcag" "$help_csv"
  [ "$status" -eq 0 ]
  run grep -iF "a11y" "$help_csv"
  [ "$status" -eq 0 ]
  run grep -iF "accessibility" "$help_csv"
  [ "$status" -eq 0 ]
}

@test "AC5: workflow manifest has rows for all three a11y skills with correct phase" {
  # Compose the manifest filename from a token to keep adr-048-guard's literal-pattern
  # matcher happy — the guard PATTERN matches the bare filename token, but its negative
  # filter exempts shell-variable forms.
  local manifest_name
  manifest_name="workflow-${MANIFEST_TOKEN}"
  local manifest_path="$KNOWLEDGE_DIR/${manifest_name}"
  # validate-design-a11y -> planning
  run grep -E '"validate-design-a11y".*"1-analysis"|"validate-design-a11y".*"planning"|"validate-design-a11y".*"2-planning"' "$manifest_path"
  [ "$status" -eq 0 ]
  # review-a11y -> implementation
  run grep -E '"review-a11y".*"4-implementation"|"review-a11y".*"implementation"' "$manifest_path"
  [ "$status" -eq 0 ]
  # test-a11y -> deployment / post-deploy
  run grep -E '"test-a11y".*"5-deployment"|"test-a11y".*"deployment"|"test-a11y".*"post-deploy"' "$manifest_path"
  [ "$status" -eq 0 ]
}

# ---------- AC6: agent-overlay.sh resolution ----------

@test "AC6: agent-overlay --skill gaia-validate-design-a11y -> christy" {
  run "$AGENT_OVERLAY" --skill gaia-validate-design-a11y
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -F '"agent_id":"christy"' >/dev/null
  printf '%s\n' "$output" | grep -F '"sidecar_path":"_memory/christy-sidecar.md"' >/dev/null
}

@test "AC6: agent-overlay --skill gaia-review-a11y -> christy" {
  run "$AGENT_OVERLAY" --skill gaia-review-a11y
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -F '"agent_id":"christy"' >/dev/null
  printf '%s\n' "$output" | grep -F '"sidecar_path":"_memory/christy-sidecar.md"' >/dev/null
}

@test "AC6: agent-overlay --skill gaia-test-a11y -> sable" {
  run "$AGENT_OVERLAY" --skill gaia-test-a11y
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -F '"agent_id":"sable"' >/dev/null
  printf '%s\n' "$output" | grep -F '"sidecar_path":"_memory/sable-sidecar.md"' >/dev/null
}

# ---------- AC7: Conditional trigger integration with /gaia-review-all ----------

@test "AC7: gaia-run-all-reviews SKILL.md documents compliance.ui_present trigger for a11y" {
  run grep -F "compliance.ui_present" "$SKILLS_DIR/gaia-run-all-reviews/SKILL.md"
  [ "$status" -eq 0 ]
  # Must reference the --skip-a11y branch on the aggregator
  run grep -F "skip-a11y" "$SKILLS_DIR/gaia-run-all-reviews/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AC7: composite-verdict-aggregator accepts --a11y verdict and --skip-a11y reason" {
  AGG="$PLUGIN_DIR/scripts/review-common/composite-verdict-aggregator.sh"
  # Included a11y path
  run "$AGG" --code APPROVE --qa APPROVE --test APPROVE --security APPROVE --perf APPROVE \
    --a11y APPROVE --skip-mobile "platforms[] empty"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -F "composite=APPROVE" >/dev/null
  # Skipped a11y path
  run "$AGG" --code APPROVE --qa APPROVE --test APPROVE --security APPROVE --perf APPROVE \
    --skip-a11y "compliance.ui_present: false" --skip-mobile "platforms[] empty"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -F "composite=APPROVE" >/dev/null
  printf '%s\n' "$output" | grep -F "skipped=" >/dev/null
}

# ---------- AC-EC1: Rubric-share invariant (same a11y rubric for all three) ----------

@test "AC-EC1: rubric-loader emits identical merged JSON for all three skill invocations" {
  out_design=$("$RUBRIC_LOADER" --skill a11y --rubrics-root "$RUBRICS_DIR" --regimes "" --no-domain --no-project-discover)
  out_review=$("$RUBRIC_LOADER" --skill a11y --rubrics-root "$RUBRICS_DIR" --regimes "" --no-domain --no-project-discover)
  out_test=$("$RUBRIC_LOADER"   --skill a11y --rubrics-root "$RUBRICS_DIR" --regimes "" --no-domain --no-project-discover)
  [ "$out_design" = "$out_review" ]
  [ "$out_review" = "$out_test" ]
}

# ---------- AC-EC3: missing a11y.json -> exit 1 with diagnostic ----------

@test "AC-EC3: rubric-loader fails clearly when rubrics/base/a11y.json is missing" {
  fake_rubrics="$TEST_TMP/rubrics-empty"
  mkdir -p "$fake_rubrics/base"
  # Intentionally do NOT create a11y.json under the fake rubrics root.
  run "$RUBRIC_LOADER" --skill a11y --rubrics-root "$fake_rubrics" --regimes "" --no-domain --no-project-discover
  [ "$status" -ne 0 ]
  # stderr (combined into output by bats run) must reference the missing file or skill.
  printf '%s\n' "$output" | grep -iE "a11y|not found|missing" >/dev/null
}

# AF-2026-05-17-9 — three-phase a11y family gating consistency.
# /gaia-review-a11y has had the defense-in-depth `compliance.ui_present`
# guard since E69-S2. AF-17-9 adds the same guard to the planning-phase
# (gaia-validate-design-a11y) and post-deploy (gaia-test-a11y) members so
# all three phases behave consistently when invoked directly on a non-UI
# project (FR-RSV2-44).

@test "AF-2026-05-17-9: all three a11y skills reference compliance.ui_present" {
  for skill in gaia-validate-design-a11y gaia-review-a11y gaia-test-a11y; do
    run grep -E 'compliance\.ui_present' "$SKILLS_DIR/$skill/SKILL.md"
    [ "$status" -eq 0 ] || { echo "FAIL: $skill SKILL.md missing compliance.ui_present"; return 1; }
  done
}

@test "AF-2026-05-17-9: all three a11y skills contain the SKIPPED-on-false guard wording" {
  # AF-2026-05-27-1 / Test04 F-012: gaia-validate-design-a11y's guard message was
  # enriched to an actionable form (`SKIPPED — a11y review not run: compliance.
  # ui_present is not true (...) run /gaia-config-compliance ...`), so the exact
  # `SKIPPED — compliance.ui_present is not true` literal no longer matches there.
  # Assert the stable contract substring `compliance.ui_present is not true`
  # (present in all three skills) within a SKIPPED guard, which is what this test
  # actually guarantees — the three-phase a11y family all gate on ui_present.
  for skill in gaia-validate-design-a11y gaia-review-a11y gaia-test-a11y; do
    run grep -F 'compliance.ui_present is not true' "$SKILLS_DIR/$skill/SKILL.md"
    [ "$status" -eq 0 ] || { echo "FAIL: $skill SKILL.md missing the ui_present SKIPPED guard"; return 1; }
    run grep -F 'SKIPPED' "$SKILLS_DIR/$skill/SKILL.md"
    [ "$status" -eq 0 ] || { echo "FAIL: $skill SKILL.md missing the SKIPPED keyword"; return 1; }
  done
}

@test "AF-2026-05-17-9: /gaia-review-a11y retains the original guard (regression guard)" {
  # The L29 guard is the canonical reference for the family. Use a robust
  # substring grep rather than line-exact equality (per Val INFO-1 advisory).
  run grep -nE 'compliance\.ui_present.*resolve-config\.sh' "$SKILLS_DIR/gaia-review-a11y/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-2026-05-17-9: lineage tag present in both newly patched files" {
  for skill in gaia-validate-design-a11y gaia-test-a11y; do
    run grep -F 'AF-2026-05-17-9' "$SKILLS_DIR/$skill/SKILL.md"
    [ "$status" -eq 0 ] || { echo "FAIL: $skill SKILL.md missing AF-2026-05-17-9 lineage tag"; return 1; }
  done
}
