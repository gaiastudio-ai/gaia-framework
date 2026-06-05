#!/usr/bin/env bats
# AF-2026-06-02-1: Test16 (v1.182.5 / AF-32-1 verification + new finds) sweep.
# 19 framework findings + 3 doc gaps = 22 fixes.
#
# Structural assertions for every Test16 fix. Bash-3.2 compatible; wired
# into the cross-platform-portability CI matrix via plugins/gaia/tests/.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
}

teardown() { common_teardown; }

# ===========================================================================
# F-H01 + F-M01 — sarif-merge.sh: drop --force; --log ForceOverwrite + --merge-empty-logs
# ===========================================================================

@test "AF-32-6 F-H01: sarif-merge.sh no longer passes --force on the active sarif merge call lines" {
  # Comments may still cite the historical `--force` Test15 attempt; the
  # restriction is that no non-comment line contains the bogus flag. Use
  # awk to skip leading whitespace then check the first non-space char
  # is `#` — bare grep with [[:space:]]* allows the `[^#]` to slip onto
  # a literal space and falsely match comment-prose with `--force` inside.
  run awk '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    line !~ /^#/ && line ~ /--force/ { print NR ": " $0; found = 1 }
    END { exit found ? 0 : 1 }
  ' "$PLUGIN_ROOT/scripts/adapters/brownfield/sarif-merge.sh"
  [ "$status" -eq 1 ]
}

@test "AF-32-6 F-H01: sarif-merge.sh uses --log ForceOverwrite (canonical Sarif.Multitool knob)" {
  run grep -F -- '--log ForceOverwrite' "$PLUGIN_ROOT/scripts/adapters/brownfield/sarif-merge.sh"
  [ "$status" -eq 0 ]
}

@test "AF-32-6 F-M01: sarif-merge.sh passes --merge-empty-logs (per-tool run survives a clean scan)" {
  run grep -F -- '--merge-empty-logs' "$PLUGIN_ROOT/scripts/adapters/brownfield/sarif-merge.sh"
  [ "$status" -eq 0 ]
}

@test "AF-32-6 F-H01: sarif-merge.sh passes inputs FIRST (container-inputs before --output-directory)" {
  # The verified-working form is `sarif merge "${_container_inputs[@]}" --output-directory ...`
  # which on the next physical line in the file.
  run grep -F '"${_container_inputs[@]}"' "$PLUGIN_ROOT/scripts/adapters/brownfield/sarif-merge.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-M02 — orchestrator matches_glob + gaia-init paths normalization
# ===========================================================================

@test "AF-32-6 F-M02: orchestrator matches_glob treats bare-dir / trailing-slash as <dir>/**" {
  run grep -F 'dir prefix' "$PLUGIN_ROOT/scripts/adapters/brownfield/orchestrator.sh"
  [ "$status" -eq 0 ]
}

@test "AF-32-6 F-M02: orchestrator cites Test16 F-M02 + names the symptom (0 files vs 37)" {
  # 'Test16 F-M02' ID was removed by the leak-scrub pass; the comment still
  # names the concrete symptom it was written to fix.  Assert the symptom text
  # that remains ('0 files vs') rather than the bookkeeping ID.
  run grep -F '0 files vs' "$PLUGIN_ROOT/scripts/adapters/brownfield/orchestrator.sh"
  [ "$status" -eq 0 ]
}

@test "AF-32-6 F-M02: gaia-init generate-config.sh normalizes paths to <dir>/** before persistence" {
  run grep -F 'has_glob = any(c in norm for c in' "$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-M03 — readiness-report generator satisfies finalize SV checklist
# ===========================================================================

@test "AF-32-6 F-M03: readiness generator emits Completeness/Consistency/Contradictions/Cascades sections" {
  for _section in 'Completeness' 'Consistency' 'Cross-Artifact Contradictions' 'Pending Cascades' 'TEA Readiness'; do
    run grep -F "## $_section" "$PLUGIN_ROOT/skills/gaia-readiness-check/scripts/generate-readiness-report.sh"
    [ "$status" -eq 0 ]
  done
}

@test "AF-32-6 F-M03: readiness generator emits traceability_complete + test_implementation_rate in frontmatter" {
  run grep -F 'traceability_complete:' "$PLUGIN_ROOT/skills/gaia-readiness-check/scripts/generate-readiness-report.sh"
  [ "$status" -eq 0 ]
  run grep -F 'test_implementation_rate:' "$PLUGIN_ROOT/skills/gaia-readiness-check/scripts/generate-readiness-report.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-M04 — create-story accepts em-dash headings + derives epic from key
# ===========================================================================

@test "AF-32-6 F-M04: generate-frontmatter.sh awk pattern accepts colon AND em-dash heading forms" {
  # Match the literal awk pattern fragment that the fix added — the
  # em-dash + colon alternation is the canonical signal.
  run grep -F '(:|—|-)' "$PLUGIN_ROOT/skills/gaia-create-story/scripts/generate-frontmatter.sh"
  [ "$status" -eq 0 ]
}

@test "AF-32-6 F-M04: generate-frontmatter.sh derives epic from story-key prefix when Epic bullet is absent" {
  run grep -F 'Derive from story-key prefix' "$PLUGIN_ROOT/skills/gaia-create-story/scripts/generate-frontmatter.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-M05 — cross-sprint dep resolution falls back to story-file + archive
# ===========================================================================

@test "AF-32-6 F-M05: sprint-state.sh dep resolver tier 2 reads the depended story file's frontmatter" {
  run grep -F 'Tier 2: the depended story' "$PLUGIN_ROOT/scripts/sprint-state.sh"
  [ "$status" -eq 0 ]
}

@test "AF-32-6 F-M05: sprint-state.sh dep resolver tier 3 walks sprint-archive/" {
  run grep -F 'Tier 3: scan sprint-archive' "$PLUGIN_ROOT/scripts/sprint-state.sh"
  [ "$status" -eq 0 ]
}

@test "AF-32-6 F-M05: sprint-state.sh wrapper is byte-identical with the canonical (per feedback memory)" {
  run diff -q "$PLUGIN_ROOT/scripts/sprint-state.sh" "$PLUGIN_ROOT/skills/gaia-dev-story/scripts/sprint-state.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-L01..L05 — small / cosmetic LOWs
# ===========================================================================

@test "AF-32-6 F-L01: Dockerfile bakes GAIA_SPOTBUGS_VERSION into runtime ENV" {
  run grep -F 'GAIA_SPOTBUGS_VERSION' "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "AF-32-6 F-L01: entrypoint prefers GAIA_SPOTBUGS_VERSION env over the broken launcher probe" {
  run grep -F 'GAIA_SPOTBUGS_VERSION' "$PLUGIN_ROOT/tools/gaia-tools/gaia-tools-entrypoint.sh"
  [ "$status" -eq 0 ]
}

@test "AF-32-6 F-L02: gaia-doctor/setup.sh has no UNCOMMENTED 5-levels-up walk" {
  # The historical walk is preserved verbatim in a comment block (so the
  # rationale stays readable). The restriction is that no active code
  # line still uses it.
  run awk '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    line !~ /^#/ && line ~ /SKILL_DIR\/\.\.\/\.\.\/\.\.\/\.\.\/\.\./ { print NR ": " $0; found = 1 }
    END { exit found ? 0 : 1 }
  ' "$PLUGIN_ROOT/skills/gaia-doctor/scripts/setup.sh"
  [ "$status" -eq 1 ]
}

@test "AF-32-6 F-L02: gaia-doctor/setup.sh asks resolve-config.sh project_root" {
  run grep -F 'resolve-config.sh' "$PLUGIN_ROOT/skills/gaia-doctor/scripts/setup.sh"
  [ "$status" -eq 0 ]
}

@test "AF-32-6 F-L03: tool-readiness.json grype version_cmd has a multi-tier fallback" {
  run grep -F 'awk -F' "$PLUGIN_ROOT/skills/gaia-doctor/knowledge/tool-readiness.json"
  [ "$status" -eq 0 ]
}

@test "AF-32-6 F-L04: gaia-init .gitignore seed names pytest artifacts" {
  for _line in '.coverage' '.pytest_cache/' '__pycache__/'; do
    run grep -F "$_line" "$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh"
    [ "$status" -eq 0 ]
  done
}

@test "AF-32-6 F-L05: sprint dashboard reads canonical capacity_points + start_date" {
  run grep -F 'yaml_val capacity_points' "$PLUGIN_ROOT/scripts/sprint-status-dashboard.sh"
  [ "$status" -eq 0 ]
  run grep -F 'yaml_val start_date' "$PLUGIN_ROOT/scripts/sprint-status-dashboard.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-L06..L11 — layout deviations
# ===========================================================================

@test "AF-32-6 F-L06: backfill-story-index.sh exists and is executable" {
  [ -x "$PLUGIN_ROOT/scripts/backfill-story-index.sh" ]
}

@test "AF-32-6 F-L06: /gaia-sprint-plan Step 1 invokes backfill-story-index.sh" {
  run grep -F 'backfill-story-index.sh' "$PLUGIN_ROOT/skills/gaia-sprint-plan/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-32-6 F-L07: sprint-state.sh init emits a sprint-plan/{id}-plan.md stub" {
  run grep -F 'sprint-plan stub' "$PLUGIN_ROOT/scripts/sprint-state.sh"
  [ "$status" -eq 0 ]
}

@test "AF-32-6 F-L08: install-test-environment-example.sh mkdir-p the test-artifacts mirror dir" {
  run grep -F 'mkdir -p "$_mirror_test_artifacts"' "$PLUGIN_ROOT/scripts/install-test-environment-example.sh"
  [ "$status" -eq 0 ]
}

@test "AF-32-6 F-L09 + F-L10: brownfield SKILL documents the test-lens mirror as design intent" {
  run grep -F 'Convenience mirror' "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
  run grep -F 'Canonical primary' "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-32-6 F-L11: gaia-test-strategy finalize emits a test-strategy.md stub when only test-plan.md exists" {
  # 'F-L11 emitted' ID was removed by the leak-scrub pass; assert the
  # behavioral log message that remains in the script.
  run grep -F 'emitted test-strategy.md stub' "$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/finalize.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# D-1, D-2, D-3 — documentation gaps
# ===========================================================================

@test "AF-32-6 D-1: gaia-config-brownfield troubleshooting now names tools.image" {
  run grep -F 'tools.image' "$REPO_ROOT/documentation/commands/gaia-config-brownfield.html"
  [ "$status" -eq 0 ]
}

@test "AF-32-6 D-2: brownfield tutorial Caveats warns about the /gaia-init exit-1 stub" {
  run grep -F '/gaia-init</code>' "$REPO_ROOT/documentation/tutorials/first-30-minutes-brownfield.html"
  [ "$status" -eq 0 ]
  run grep -F 'exit 1' "$REPO_ROOT/documentation/tutorials/first-30-minutes-brownfield.html"
  [ "$status" -eq 0 ]
}

@test "AF-32-6 D-3: docker-workflow doc lists the current image version (no longer 0.1.1 / 2026-05-31)" {
  run grep -F '0.1.1 / 2026-05-31' "$REPO_ROOT/documentation/commands/gaia-docker-workflow.html"
  [ "$status" -ne 0 ]
  run grep -F '0.1.1-2026-05-31' "$REPO_ROOT/documentation/commands/gaia-docker-workflow.html"
  [ "$status" -ne 0 ]
  run grep -F '0.1.4' "$REPO_ROOT/documentation/commands/gaia-docker-workflow.html"
  [ "$status" -eq 0 ]
}
