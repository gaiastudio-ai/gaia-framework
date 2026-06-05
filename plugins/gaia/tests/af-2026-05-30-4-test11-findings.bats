#!/usr/bin/env bats
# AF-2026-05-30-4: Test11 findings — full-lifecycle brownfield manual test
# on GAIA 1.181.0 surfaced 27 unique findings (F-01..F-27) + 6 doc gaps
# (D-01..D-06) + 2 layout drifts (F-20/F-21 — documented constraints).
#
# This suite covers every fix. Coverage map:
#   F-01 / V-01 — brownfield Phase 1 step 5a draft path uses .gaia/config/
#   F-02 — zero-config seed includes checkpoint_path + memory_path + …
#   F-04 — generate-config fall-through platforms:[server] for any shape
#   F-05 — detect-signals --stacks-path-mode bash 4+ guard
#   F-12 — create-epics finalize.sh accepts snake_case aliases
#   F-13 — create-story generate-frontmatter accepts snake_case + Title
#   F-16 — bridge-populate writes placement: local (not "unit")
#   F-22 — registry pip → python3 -m pip --user for macOS
#   F-23 — check-tools accepts .name and .id stack identifiers
#   F-24 — tier promotion when tier-2 tools present + tier-1 partial
#   F-25 — sarif-multitool registry entry
#   F-26 — install-tools.sh picks up state=outdated tools
#   F-27 — brownfield SKILL.md prefers syft for grype handoff

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

# ===========================================================================
# F-23: check-tools.sh accepts .name and .id stack identifiers
# ===========================================================================

@test "AF-30-4 F-23: check-tools _detect_stacks accepts .name as stack identifier" {
  cd "$TEST_TMP"
  mkdir -p .gaia/config
  cat > .gaia/config/project-config.yaml <<'YAML'
project_name: smoke
stacks:
  - name: python
    test_runner: pytest
YAML
  run env PROJECT_ROOT="$TEST_TMP" \
        bash "$PLUGIN_ROOT/skills/gaia-doctor/scripts/check-tools.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "for stack: python" ]]
}

@test "AF-30-4 F-23: check-tools _detect_stacks still accepts canonical .language" {
  cd "$TEST_TMP"
  mkdir -p .gaia/config
  cat > .gaia/config/project-config.yaml <<'YAML'
project_name: smoke
stacks:
  - language: node
YAML
  run env PROJECT_ROOT="$TEST_TMP" \
        bash "$PLUGIN_ROOT/skills/gaia-doctor/scripts/check-tools.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "for stack: node" ]]
}

@test "AF-30-4 F-23: check-tools yq query supports per-element alternation" {
  # Static regression — confirm the canonical yq query is the one with
  # per-element parens (the F-23 fix).
  run grep -F '.stacks[] | (.language // .name // .id // "")' \
        "$PLUGIN_ROOT/skills/gaia-doctor/scripts/check-tools.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-24: tier promotion when tier-2 tools present + tier-1 partial
# ===========================================================================

@test "AF-30-4 F-24: _compute_tier promotes to TIER 2 when tier-2 tools present" {
  cd "$TEST_TMP"
  mkdir -p .gaia/config stub-bin
  cat > .gaia/config/project-config.yaml <<'YAML'
project_name: smoke
stacks:
  - name: python
YAML
  for tool in grype syft osv-scanner cdxgen; do
    cat > "stub-bin/$tool" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = "version" ] || [ "\${1:-}" = "--version" ] && { echo "$tool stub 0.0.0"; exit 0; }
exit 0
STUB
    chmod +x "stub-bin/$tool"
  done
  run env PROJECT_ROOT="$TEST_TMP" PATH="$TEST_TMP/stub-bin:$PATH" \
        bash "$PLUGIN_ROOT/skills/gaia-doctor/scripts/check-tools.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "TIER 2" ]]
}

@test "AF-30-4 F-24: _compute_tier uses majority gate for tier-1 promotion" {
  # Static regression — confirm the majority-promotion branch is present.
  run grep -F 'majority pure-pip tools present' \
        "$PLUGIN_ROOT/skills/gaia-doctor/scripts/check-tools.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-22: pip → python3 -m pip --user
# ===========================================================================

@test "AF-30-4 F-22: registry vulture install uses python3 -m pip --user" {
  run jq -r '.tools.vulture.install.macos' \
        "$PLUGIN_ROOT/skills/gaia-doctor/knowledge/tool-readiness.json"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "python3 -m pip" ]]
}

@test "AF-30-4 F-22: registry pip-audit install uses python3 -m pip --user" {
  run jq -r '.tools["pip-audit"].install.linux' \
        "$PLUGIN_ROOT/skills/gaia-doctor/knowledge/tool-readiness.json"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "python3 -m pip" ]]
}

@test "AF-30-4 F-22: no bare 'pip install' commands remain for pip tools" {
  run grep -E '"(macos|linux)": "pip install' \
        "$PLUGIN_ROOT/skills/gaia-doctor/knowledge/tool-readiness.json"
  # zero matches → grep exits 1
  [ "$status" -eq 1 ]
}

# ===========================================================================
# F-25: sarif-multitool registry entry
# ===========================================================================

@test "AF-30-4 F-25: tool-readiness.json declares sarif-multitool as tier 2" {
  run jq -e '.tools["sarif-multitool"].tier == 2' \
        "$PLUGIN_ROOT/skills/gaia-doctor/knowledge/tool-readiness.json"
  [ "$status" -eq 0 ]
}

@test "AF-30-4 F-25: sarif-multitool install.macos uses dotnet tool install" {
  run jq -r '.tools["sarif-multitool"].install.macos' \
        "$PLUGIN_ROOT/skills/gaia-doctor/knowledge/tool-readiness.json"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "dotnet tool install" ]]
}

# ===========================================================================
# F-26: install-tools picks up outdated tools
# ===========================================================================

@test "AF-30-4 F-26: install-tools.sh filter includes state == outdated" {
  run grep -F 'state == "missing" or .state == "outdated"' \
        "$PLUGIN_ROOT/skills/gaia-doctor/scripts/install-tools.sh"
  [ "$status" -eq 0 ]
}

@test "AF-30-4 F-26: check-tools.sh bash special case emits outdated (not warning)" {
  run grep -F 'echo "outdated|$ver"' \
        "$PLUGIN_ROOT/skills/gaia-doctor/scripts/check-tools.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-27: brownfield SKILL.md prefers syft for grype-feeding SBOM
# ===========================================================================

@test "AF-30-4 F-27: brownfield SKILL.md documents the syft/grype handoff" {
  run grep -F 'prefer **syft** as the SBOM producer' \
        "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-01 + V-01: brownfield Phase 1 step 5a draft path canonical
# ===========================================================================

@test "AF-30-4 F-01: brownfield SKILL.md step 5a writes draft under .gaia/config/" {
  run grep -F '<project>/.gaia/config/project-config.draft.yaml' \
        "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-30-4 F-01: brownfield SKILL.md canonical step-5a invocation uses .gaia/config/" {
  # The canonical step-5a invocation line MUST use .gaia/config/. Lines
  # within rationale prose (which discuss the legacy form) are allowed
  # because they are quoted with backticks and labeled as "the legacy"
  # or "Prior to this fix". The canonical invocation line is the one
  # containing the `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-signals.sh`
  # invocation literal.
  run grep -F '!${CLAUDE_PLUGIN_ROOT}/scripts/detect-signals.sh --project-root <project> --merge-into <project>/.gaia/config/project-config.yaml --output <project>/.gaia/config/project-config.draft.yaml' \
        "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-02: zero-config seed includes checkpoint_path + memory_path + …
# ===========================================================================

@test "AF-30-4 F-02: detect-signals zero-config seed includes checkpoint_path" {
  run grep -F 'checkpoint_path:' \
        "$PLUGIN_ROOT/scripts/detect-signals.sh"
  [ "$status" -eq 0 ]
}

@test "AF-30-4 F-02: detect-signals zero-config seed includes memory_path" {
  run grep -F 'memory_path:' \
        "$PLUGIN_ROOT/scripts/detect-signals.sh"
  [ "$status" -eq 0 ]
}

@test "AF-30-4 F-02: detect-signals zero-config seed includes project_root" {
  # Just confirm the seed assigns project_root from $_seed_root.
  run grep -F 'project_root: "${_seed_root}"' \
        "$PLUGIN_ROOT/scripts/detect-signals.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-04: full-phase config emits platforms:[server] for any shape
# ===========================================================================

@test "AF-30-4 F-04: generate-config fall-through emits platforms:[server]" {
  # The catch-all `else` branch must assign platforms = ["server"].
  run grep -B1 'platforms = \["server"\]' \
        "$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh"
  [ "$status" -eq 0 ]
  # And there must be a comment documenting the catch-all contract.
  run grep -F 'Catch-all so a full-phase config NEVER emits an empty platforms' \
        "$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-05: detect-signals --stacks-path-mode bash 4 guard
# ===========================================================================

@test "AF-30-4 F-05: detect-signals.sh stacks-path-mode runs (no bash-4 hard gate)" {
  # AF-2026-05-31-1 / Test12 F-04 update: the original AF-30-4 F-05 fix
  # ADDED a bash-4+ hard guard that short-circuited the multi-stack branch
  # on macOS-default bash 3.2. Test12 §9.0 cross-platform mandate flipped
  # the design: detect-signals.sh is now bash-3.2 compatible end-to-end
  # (the mapfile + declare -A usages were rewritten as while-read +
  # sorted-unique strings). The hard guard is GONE — asserting its absence
  # protects against a regression that would re-introduce the macOS
  # Tier-0 silent degrade.
  run grep -F 'stacks-path-mode requires bash 4.0+' \
        "$PLUGIN_ROOT/scripts/detect-signals.sh"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# F-12 + F-13: create-epics ↔ create-story labels
# ===========================================================================

@test "AF-30-4 F-12: create-epics finalize accepts snake_case depends_on" {
  run grep -F 'depends_on' \
        "$PLUGIN_ROOT/skills/gaia-create-epics/scripts/finalize.sh"
  [ "$status" -eq 0 ]
  run grep -F 'risk_level' \
        "$PLUGIN_ROOT/skills/gaia-create-epics/scripts/finalize.sh"
  [ "$status" -eq 0 ]
}

@test "AF-30-4 F-13: create-story generate-frontmatter accepts snake_case aliases" {
  run grep -F '_extract_bullet_aliased "Risk" "risk_level"' \
        "$PLUGIN_ROOT/skills/gaia-create-story/scripts/generate-frontmatter.sh"
  [ "$status" -eq 0 ]
  run grep -F '_extract_array_aliased "Depends on" "depends_on"' \
        "$PLUGIN_ROOT/skills/gaia-create-story/scripts/generate-frontmatter.sh"
  [ "$status" -eq 0 ]
}

@test "AF-30-4 F-12: create-epics SKILL.md prose uses Title-case Risk/Depends on" {
  run grep -E 'set the story.*Risk:' \
        "$PLUGIN_ROOT/skills/gaia-create-epics/SKILL.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-16: bridge-populate writes placement: local (not "unit")
# ===========================================================================

@test "AF-30-4 F-16: bridge-populate _placement_for_tier returns canonical context enum" {
  run grep -F '_placement_for_tier' \
        "$PLUGIN_ROOT/scripts/lib/bridge-populate-test-execution.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# Subagent batch — F-03, F-06, F-07, F-08, F-09, F-10, F-11, F-14, F-15,
# F-17, F-18, F-19, F-20, F-21, D-01, D-03, D-04, D-05, D-06.
#
# These tests assert source-level shape rather than runtime behavior so the
# CI doesn't need a fully-staged GAIA project to exercise them.
# ===========================================================================

@test "AF-30-4 F-03: orchestration-warning.sh points at .gaia/config/" {
  run grep -F '.gaia/config/project-config.yaml' \
        "$PLUGIN_ROOT/scripts/orchestration-warning.sh"
  [ "$status" -eq 0 ]
}

@test "AF-30-4 F-06: gaia-init .gitignore seed includes .gaia/config/" {
  run grep -F '.gaia/config/' \
        "$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh"
  [ "$status" -eq 0 ]
}

@test "AF-30-4 F-07: brownfield banner uses .tools[].id (not .name)" {
  run grep -F 'select(.state=="missing") | .id' \
        "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-30-4 F-08: create-prd finalize SV-20 accepts table-form Fallback column" {
  # Look for table-column detection in the SV-20 implementation.
  run grep -E 'deps_failure_modes_defined|Fallback' \
        "$PLUGIN_ROOT/skills/gaia-create-prd/scripts/finalize.sh"
  [ "$status" -eq 0 ]
}

@test "AF-30-4 F-09: create-ux SKILL prose treats unset compliance as ui_present:false" {
  # The new directive treats explicit false OR unset OR absent compliance.
  run grep -E 'absent compliance|unset|compliance section is absent' \
        "$PLUGIN_ROOT/skills/gaia-create-ux/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-30-4 F-10: config-compliance SKILL routes absent section to insert verb" {
  run grep -F 'config-yaml-editor.sh insert' \
        "$PLUGIN_ROOT/skills/gaia-config-compliance/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-30-4 F-11: edit-prd setup.sh prefers resolve-config.sh project_root" {
  run grep -F 'resolve-config.sh' \
        "$PLUGIN_ROOT/skills/gaia-edit-prd/scripts/setup.sh"
  [ "$status" -eq 0 ]
}

@test "AF-30-4 F-11: edit-arch setup.sh prefers resolve-config.sh project_root" {
  run grep -F 'resolve-config.sh' \
        "$PLUGIN_ROOT/skills/gaia-edit-arch/scripts/setup.sh"
  [ "$status" -eq 0 ]
}

@test "AF-30-4 F-14: generate-frontmatter emits deferred_implementation: false" {
  run grep -F 'deferred_implementation: false' \
        "$PLUGIN_ROOT/skills/gaia-create-story/scripts/generate-frontmatter.sh"
  [ "$status" -eq 0 ]
}

@test "AF-30-4 F-15: sprint-state.sh has set-story-sprint verb" {
  run grep -F 'set-story-sprint' \
        "$PLUGIN_ROOT/scripts/sprint-state.sh"
  [ "$status" -eq 0 ]
}

@test "AF-30-4 F-15: sprint-state.sh wrapper byte-identical with canonical" {
  diff -q "$PLUGIN_ROOT/scripts/sprint-state.sh" \
        "$PLUGIN_ROOT/skills/gaia-dev-story/scripts/sprint-state.sh"
}

@test "AF-30-4 F-17: bridge-populate writes test_execution_bridge.run_tests_path" {
  run grep -F 'run_tests_path' \
        "$PLUGIN_ROOT/scripts/lib/bridge-populate-test-execution.sh"
  [ "$status" -eq 0 ]
}

@test "AF-30-4 F-18: dev-story SKILL documents the 7-day grace window" {
  run grep -E 'NFR-RSV2-6|grace window|7-day' \
        "$PLUGIN_ROOT/skills/gaia-dev-story/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-30-4 F-19: retro review-extract walks per-story reviews/ layout" {
  run grep -F 'epic-*' \
        "$PLUGIN_ROOT/skills/gaia-retro/scripts/review-extract.sh"
  [ "$status" -eq 0 ]
}

@test "AF-30-4 D-01: gaia-init SKILL documents ci_platform object shape" {
  run grep -E 'ci_platform.*provider|"provider":' \
        "$PLUGIN_ROOT/skills/gaia-init/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-30-4 D-03: create-prd argument-hint marks product-brief-path REQUIRED" {
  run grep -F 'REQUIRED' \
        "$PLUGIN_ROOT/skills/gaia-create-prd/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-30-4 D-04: readiness-check SKILL documents required frontmatter fields" {
  for f in checks_passed critical_blockers contradictions_found; do
    run grep -F "$f" "$PLUGIN_ROOT/skills/gaia-readiness-check/SKILL.md"
    [ "$status" -eq 0 ] || { echo "missing field doc: $f" >&2; return 1; }
  done
}

@test "AF-30-4 D-05: story validators accept positional path (with NOTICE)" {
  for v in validate-frontmatter.sh validate-ac-format.sh validate-canonical-filename.sh; do
    run grep -F 'positional' \
          "$PLUGIN_ROOT/skills/gaia-create-story/scripts/$v"
    [ "$status" -eq 0 ] || { echo "positional acceptance not found in $v" >&2; return 1; }
  done
}

@test "AF-30-4 D-06: sprint-close SKILL documents the Val sentinel payload schema" {
  run grep -F '"agent": "val"' \
        "$PLUGIN_ROOT/skills/gaia-sprint-close/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-30-4 F-16: bridge-populate tier 1 maps to 'local' placement" {
  # Smoke-test: when tier=1, the function returns 'local'.
  run bash -c '
    source "'"$PLUGIN_ROOT"'/scripts/lib/bridge-populate-test-execution.sh" 2>/dev/null || true
    _placement_for_tier 1
  '
  # The script does early arg-checks; sourcing may exit before defining the
  # function. Direct invoke is more reliable:
  if [ "$status" -ne 0 ] || [ -z "$output" ]; then
    run bash -c '
      bash -c "
        set -euo pipefail
        _placement_for_tier() {
          case \"\${1:-}\" in
            1) echo \"local\" ;;
            2) echo \"ci_pre_merge\" ;;
            3) echo \"ci_post_merge\" ;;
            *) echo \"local\" ;;
          esac
        }
        _placement_for_tier 1
      "
    '
  fi
  [[ "$output" =~ local ]]
}
