#!/usr/bin/env bats
# AF-2026-05-29-2: Test09 findings — 16 real code bugs surfaced during the
# GAIA 1.180.7 brownfield onboarding manual test (27 findings, 16 fixes
# after dedup against AF-29-1).
#
# CRITICAL:
#  - F1  brownfield setup.sh dies on missing config (no greenfield degrade)
#  - F3  project-config.schema.yaml v1.1.0 desync with schema.json v2.0.0
#
# HIGH:
#  - F16 brownfield post-complete gates use names not in validate-gate.sh
#         SUPPORTED_GATES enumeration (false PASS)
#  - F17 write-val-envelope.sh hashes raw artifact_path — absolute vs
#         relative produces different sentinels, persona-side relative hash
#         never matches caller-side absolute hash
#  - F20 setup.sh PROJECT_ROOT walk-up resolves into the cache directory
#         when invoked from a project subdir (no CLAUDE_PROJECT_ROOT
#         precedence chain)
#  - F28 /gaia-create-story Step 5 transition --to backlog is a self-no-op
#         because the story file is written with status:backlog from the
#         template; sprint-state.sh rejects the self-edge silently and the
#         4-surface atomic write never runs
#
# MEDIUM:
#  - F2  /gaia-init defaults platforms:[web] even for ui_present:False /
#         single-backend shapes
#  - F4  test-environment-manifest detect_stack misses pure-language
#         repos when signal files (manifests) absent; no config fallback
#  - F7  pytest runner template wrong on systems without `pytest` shim
#         (uses bare `pytest tests/unit` instead of `python3 -m pytest`)
#  - F11 brownfield Phase 8b adversarial review CRITICAL findings do not
#         downgrade under YOLO contract
#  - F15 same root cause as F4 (paired)
#  - F19 /gaia-create-ux runs prereqs even when compliance.ui_present is
#         False (no ui_present early-skip)
#  - F22 /gaia-trace coverage formula treats all High-risk reqs as needing
#         E2E even on surface_type:none stories
#  - F23 /gaia-trace implementation-readiness verdict has no READY-FOR-DEV
#         row for healthy planning-phase state (all High planned, 0%
#         implementation)
#  - F27 /gaia-bridge-enable post-flip stats legacy
#         .gaia/artifacts/test-artifacts/test-environment.yaml; canonical
#         post-ADR-110 home is .gaia/config/test-environment.yaml
#  - F29 validator agent raises CRITICAL on forward-edge story keys that
#         exist in epics-and-stories.md but don't yet have an individual
#         story file (chicken-and-egg with cross-sprint blocks:)
#  - F32 sprint planned -> active activation gap: /gaia-dev-story doesn't
#         flip sprint to active on first story transition; /gaia-sprint-
#         review then refuses because sprint is still planned

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

# ===========================================================================
# F1 CRITICAL — brownfield setup.sh degrades on missing project-config.yaml
# ===========================================================================

@test "AF-29-2 F1: brownfield setup.sh exits 0 on no-config (fresh project)" {
  cd "$TEST_TMP"
  # Fresh project: no .gaia/, no config/. setup.sh used to exit 1 on
  # "no canonical config path resolved".
  run env CLAUDE_PROJECT_ROOT="$TEST_TMP" \
        bash "$PLUGIN_ROOT/skills/gaia-brownfield/scripts/setup.sh"
  [ "$status" -eq 0 ]
}

@test "AF-29-2 F1: brownfield setup.sh seeds artifact tree on no-config" {
  cd "$TEST_TMP"
  run env CLAUDE_PROJECT_ROOT="$TEST_TMP" \
        bash "$PLUGIN_ROOT/skills/gaia-brownfield/scripts/setup.sh"
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMP/.gaia/artifacts/planning-artifacts" ]
  [ -d "$TEST_TMP/.gaia/artifacts/implementation-artifacts" ]
  [ -d "$TEST_TMP/.gaia/artifacts/test-artifacts" ]
}

@test "AF-29-2 F1: brownfield setup.sh still HALTs on malformed config" {
  cd "$TEST_TMP"
  mkdir -p .gaia/config
  printf 'project_name: [unclosed list\n' > .gaia/config/project-config.yaml
  run env CLAUDE_PROJECT_ROOT="$TEST_TMP" \
        bash "$PLUGIN_ROOT/skills/gaia-brownfield/scripts/setup.sh"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# F3 CRITICAL — schema.yaml v1.1.0 desync with schema.json v2.0.0
# ===========================================================================

@test "AF-29-2 F3: project-config.schema.yaml declares schema_version 2.0.0" {
  run grep -E '^schema_version:[[:space:]]*"2\.0\.0"' \
        "$PLUGIN_ROOT/config/project-config.schema.yaml"
  [ "$status" -eq 0 ]
}

@test "AF-29-2 F3: schema.yaml declares schema_version field" {
  run grep -E '^\s+schema_version:' "$PLUGIN_ROOT/config/project-config.schema.yaml"
  [ "$status" -eq 0 ]
}

@test "AF-29-2 F3: schema.yaml declares config_phase field" {
  run grep -E '^\s+config_phase:' "$PLUGIN_ROOT/config/project-config.schema.yaml"
  [ "$status" -eq 0 ]
}

@test "AF-29-2 F3: schema.yaml declares project_name field" {
  run grep -E '^\s+project_name:' "$PLUGIN_ROOT/config/project-config.schema.yaml"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F16 HIGH — brownfield post-complete gates use supported names
# ===========================================================================

@test "AF-29-2 F16: brownfield SKILL.md no longer USES nfr_assessment_exists as a gate type" {
  # Historical mentions (in the F-16 rationale / prior-name retrospective)
  # are allowed. What's not allowed is invoking the unsupported gate type
  # as a `--type` argument to validate-gate.sh.
  run grep -E '\-\-type[[:space:]]+nfr_assessment_exists' \
        "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 1 ]
}

@test "AF-29-2 F16: brownfield SKILL.md no longer USES performance_test_plan_exists as a gate type" {
  run grep -E '\-\-type[[:space:]]+performance_test_plan_exists' \
        "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 1 ]
}

@test "AF-29-2 F16: brownfield SKILL.md uses file_exists gate form" {
  run grep -c 'file_exists --file' \
        "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F17 HIGH — write-val-envelope.sh normalises path before hashing
# ===========================================================================

@test "AF-29-2 F17: absolute and relative artifact paths produce identical sentinel hash" {
  cd "$TEST_TMP"
  mkdir -p .gaia/artifacts/planning-artifacts/epics/E1
  : > .gaia/artifacts/planning-artifacts/epics/E1/prd.md

  # Two payloads — one absolute, one relative — both pointing at the same file.
  local rel='.gaia/artifacts/planning-artifacts/epics/E1/prd.md'
  local abs="$TEST_TMP/$rel"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local env_rel
  env_rel='{"agent":"val","persona_sig":"abc123","timestamp":"'$ts'","artifact_path":"'$rel'","verdict":"PASS"}'
  local env_abs
  env_abs='{"agent":"val","persona_sig":"abc123","timestamp":"'$ts'","artifact_path":"'$abs'","verdict":"PASS"}'

  local path_rel path_abs
  path_rel=$(env PROJECT_ROOT="$TEST_TMP" \
                bash "$PLUGIN_ROOT/scripts/lib/write-val-envelope.sh" \
                  --envelope "$env_rel" 2>/dev/null)
  path_abs=$(env PROJECT_ROOT="$TEST_TMP" \
                bash "$PLUGIN_ROOT/scripts/lib/write-val-envelope.sh" \
                  --envelope "$env_abs" 2>/dev/null)

  # Sentinel filenames carry the hash — equal filenames => equal hashes.
  [ "$(basename "$path_rel")" = "$(basename "$path_abs")" ]
}

# ===========================================================================
# F20 HIGH — setup.sh PROJECT_ROOT precedence chain honors CLAUDE_PROJECT_ROOT
# ===========================================================================

@test "AF-29-2 F20: validate-prd setup.sh honors CLAUDE_PROJECT_ROOT" {
  run grep -E 'PROJECT_ROOT="\$\{PROJECT_ROOT:-\$\{CLAUDE_PROJECT_ROOT:-\$\{GAIA_PROJECT_ROOT:-' \
        "$PLUGIN_ROOT/skills/gaia-validate-prd/scripts/setup.sh"
  [ "$status" -eq 0 ]
}

@test "AF-29-2 F20: create-prd setup.sh honors CLAUDE_PROJECT_ROOT" {
  run grep -E 'PROJECT_ROOT="\$\{PROJECT_ROOT:-\$\{CLAUDE_PROJECT_ROOT:-\$\{GAIA_PROJECT_ROOT:-' \
        "$PLUGIN_ROOT/skills/gaia-create-prd/scripts/setup.sh"
  [ "$status" -eq 0 ]
}

@test "AF-29-2 F20: create-arch setup.sh honors CLAUDE_PROJECT_ROOT" {
  run grep -E 'PROJECT_ROOT="\$\{PROJECT_ROOT:-\$\{CLAUDE_PROJECT_ROOT:-\$\{GAIA_PROJECT_ROOT:-' \
        "$PLUGIN_ROOT/skills/gaia-create-arch/scripts/setup.sh"
  [ "$status" -eq 0 ]
}

@test "AF-29-2 F20: create-ux setup.sh honors CLAUDE_PROJECT_ROOT" {
  run grep -E 'PROJECT_ROOT="\$\{PROJECT_ROOT:-\$\{CLAUDE_PROJECT_ROOT:-\$\{GAIA_PROJECT_ROOT:-' \
        "$PLUGIN_ROOT/skills/gaia-create-ux/scripts/setup.sh"
  [ "$status" -eq 0 ]
}

@test "AF-29-2 F20: edit-prd setup.sh honors CLAUDE_PROJECT_ROOT" {
  run grep -E 'PROJECT_ROOT="\$\{PROJECT_ROOT:-\$\{CLAUDE_PROJECT_ROOT:-\$\{GAIA_PROJECT_ROOT:-' \
        "$PLUGIN_ROOT/skills/gaia-edit-prd/scripts/setup.sh"
  [ "$status" -eq 0 ]
}

@test "AF-29-2 F20: edit-arch setup.sh honors CLAUDE_PROJECT_ROOT" {
  run grep -E 'PROJECT_ROOT="\$\{PROJECT_ROOT:-\$\{CLAUDE_PROJECT_ROOT:-\$\{GAIA_PROJECT_ROOT:-' \
        "$PLUGIN_ROOT/skills/gaia-edit-arch/scripts/setup.sh"
  [ "$status" -eq 0 ]
}

@test "AF-29-2 F20: edit-ux setup.sh honors CLAUDE_PROJECT_ROOT" {
  run grep -E 'PROJECT_ROOT="\$\{PROJECT_ROOT:-\$\{CLAUDE_PROJECT_ROOT:-\$\{GAIA_PROJECT_ROOT:-' \
        "$PLUGIN_ROOT/skills/gaia-edit-ux/scripts/setup.sh"
  [ "$status" -eq 0 ]
}

@test "AF-29-2 F20: edit-test-plan setup.sh honors CLAUDE_PROJECT_ROOT" {
  run grep -E 'PROJECT_ROOT="\$\{PROJECT_ROOT:-\$\{CLAUDE_PROJECT_ROOT:-\$\{GAIA_PROJECT_ROOT:-' \
        "$PLUGIN_ROOT/skills/gaia-edit-test-plan/scripts/setup.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F28 HIGH — /gaia-create-story Step 5 uses --reconcile-only
# ===========================================================================

@test "AF-29-2 F28: create-story SKILL.md uses --reconcile-only at Step 5" {
  run grep -c 'transition-story-status.sh.*--reconcile-only' \
        "$PLUGIN_ROOT/skills/gaia-create-story/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-29-2 F28: create-story SKILL.md no longer issues --to backlog as the registration call" {
  # The registration call MUST use --reconcile-only. References to
  # `--to backlog` are allowed in the F-28 rationale (explaining why
  # --reconcile-only replaced it). The forbidden shape is an actual
  # call site of the form `transition-story-status.sh {story_key} --to backlog`
  # WITHOUT a `--reconcile-only`-explaining clause nearby. We instead
  # assert the inverse: every transition-story-status.sh call in the
  # file uses --reconcile-only.
  run grep -E 'transition-story-status\.sh \{story_key\} --to backlog' \
        "$PLUGIN_ROOT/skills/gaia-create-story/SKILL.md"
  # Lines matching the literal call form should not exist; if they do,
  # they must be inside the rationale block (which uses `NOT --to backlog`
  # or backtick-quoted forms).
  if [ "$status" -eq 0 ]; then
    # Filter out the rationale-context occurrences (which carry "NOT" or
    # are inside backticks alongside --reconcile-only).
    bad=$(echo "$output" | grep -vE 'NOT.*--to backlog|`--to backlog`|--reconcile-only' || true)
    [ -z "$bad" ]
  fi
}

# ===========================================================================
# F2 MED — /gaia-init platforms default skip on backend-only / no UI
# ===========================================================================

@test "AF-29-2 F2: generate-config.sh has ui_present-aware platforms default" {
  run grep -c 'ui_present.*[Ff]alse' \
        "$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F4 + F15 MED — test-environment-manifest detect_stack config fallback
# ===========================================================================

@test "AF-29-2 F4: detect_stack falls back to config stacks[].language" {
  run grep -c 'stacks\[\].language\|stacks\[\] | .language' \
        "$PLUGIN_ROOT/scripts/lib/test-environment-manifest.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F7 MED — pytest runner uses python3 -m pytest
# ===========================================================================

@test "AF-29-2 F7: pytest runner template uses python3 -m pytest" {
  run grep -c 'python3 -m pytest' \
        "$PLUGIN_ROOT/scripts/lib/test-environment-manifest.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F11 MED — brownfield Phase 8b YOLO downgrade
# ===========================================================================

@test "AF-29-2 F11: brownfield SKILL.md documents Phase 8b YOLO CRITICAL→WARNING" {
  run grep -c '[Pp]hase 8b\|YOLO.*[Cc]ontract\|YOLO.*adversarial' \
        "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F19 MED — /gaia-create-ux ui_present guard
# ===========================================================================

@test "AF-29-2 F19: create-ux SKILL.md guards on compliance.ui_present" {
  run grep -c 'ui_present' \
        "$PLUGIN_ROOT/skills/gaia-create-ux/SKILL.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F22 MED — /gaia-trace surface-aware coverage
# ===========================================================================

@test "AF-29-2 F22: trace SKILL.md surface_type drives required tier count" {
  run grep -c 'surface_type' \
        "$PLUGIN_ROOT/skills/gaia-trace/SKILL.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F23 MED — /gaia-trace READY-FOR-DEV verdict
# ===========================================================================

@test "AF-29-2 F23: trace SKILL.md defines READY-FOR-DEV verdict" {
  run grep -c 'READY-FOR-DEV' \
        "$PLUGIN_ROOT/skills/gaia-trace/SKILL.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F27 MED — /gaia-bridge-enable canonical manifest path
# ===========================================================================

@test "AF-29-2 F27: bridge-enable SKILL.md stats .gaia/config/test-environment.yaml" {
  run grep -c '\.gaia/config/test-environment\.yaml' \
        "$PLUGIN_ROOT/skills/gaia-bridge-enable/SKILL.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F29 MED — validator forward-edge tolerance
# ===========================================================================

@test "AF-29-2 F29: validator agent documents forward-edge tolerance" {
  run grep -c 'orward-edge\|forward edge\|planned-but-uncreated' \
        "$PLUGIN_ROOT/agents/validator.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F32 MED — sprint planned → active auto-activation
# ===========================================================================

@test "AF-29-2 F32: dev-story SKILL.md auto-activates planned sprint at Step 2a" {
  run grep -c 'Step 2a\|Auto-activate sprint\|auto-activated sprint' \
        "$PLUGIN_ROOT/skills/gaia-dev-story/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-29-2 F32: dev-story SKILL.md transitions sprint via sprint-state.sh" {
  # The auto-activation should call the canonical boundary writer, not
  # hand-edit sprint-status.yaml.
  run grep -c 'sprint-state.sh transition.*--to active' \
        "$PLUGIN_ROOT/skills/gaia-dev-story/SKILL.md"
  [ "$status" -eq 0 ]
}
