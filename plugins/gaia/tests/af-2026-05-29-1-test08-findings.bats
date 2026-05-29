#!/usr/bin/env bats
# AF-2026-05-29-1: Test08 findings — 10 real code bugs surfaced during the
# GAIA 1.180.7 end-to-end lifecycle test.
#
# - F-012 HIGH: gaia-dev-story dod-check.sh does not exercise the Test Execution
#   Bridge — even with bridge_enabled: true + populated test-environment.yaml,
#   the DoD test gate reported "tests: SKIPPED". Stories transitioned to
#   review without anything actually running.
# - F-016 HIGH: review-summary-gen.sh _locate_story_file missing the E105-S1
#   per-story layout. Every story created on a current-framework project
#   failed summary generation with "story not found".
# - F-001 MED: /gaia-init generate-config.sh rejected the documented list-form
#   environments answer-bundle and silently dropped operator input.
# - F-004 MED: same script dropped per-stack `excludes` entirely.
# - F-005 MED: /gaia-threat-model SV-07/SV-09 brittle awk patterns rejected
#   numbered H2 headings (## 3. STRIDE Analysis) — internally inconsistent
#   with SV-06's shared heading_present lib.
# - F-013 LOW: backlog -> in-progress edge missing from the story state machine
#   adjacency table, contradicting /gaia-dev-story SKILL.md Step 2.
# - F-014 LOW: detect-mode.sh classified backlog stories as RESUME (fallback)
#   instead of FRESH.
# - F-015 MED: atdd-gate had no escape hatch for high-risk stories on
#   greenfield projects where ATDD is not yet set up.
# - F-017 MED: load-stack-persona.sh rejected --story-file flag that
#   gaia-test-automate SKILL.md documents as the canonical invocation.
# - F-019 MED: /gaia-retro finalize expected `retrospective.yaml` but
#   write-checkpoint.sh emits `retrospective/<ts>-step-N.json`.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

# ===========================================================================
# F-012 HIGH — dod-check.sh exercises the Test Execution Bridge
# ===========================================================================

@test "AF-29-1 F-12: dod-check resolves bridge tier-1 runner when bridge_enabled=true" {
  cd "$TEST_TMP"
  mkdir -p .gaia/config .gaia/artifacts/test-artifacts
  cat > .gaia/config/project-config.yaml <<'EOF'
project_name: smoke
test_execution_bridge:
  bridge_enabled: true
EOF
  cat > .gaia/artifacts/test-artifacts/test-environment.yaml <<'EOF'
version: 2
runners:
  - name: unit
    command: "echo BRIDGE_TIER_1"
    tier: 1
  - name: integration
    command: "echo BRIDGE_TIER_2"
    tier: 2
EOF
  awk '/^_resolve_test_cmd\(\)/,/^}/' "$PLUGIN_ROOT/skills/gaia-dev-story/scripts/dod-check.sh" > rt.sh
  echo '_resolve_test_cmd' >> rt.sh
  run bash rt.sh
  [ "$status" -eq 0 ]
  [ "$output" = "echo BRIDGE_TIER_1" ]
}

@test "AF-29-1 F-12: bridge disabled falls through to legacy test_cmd tier" {
  cd "$TEST_TMP"
  mkdir -p .gaia/config
  cat > .gaia/config/project-config.yaml <<'EOF'
project_name: smoke
test_execution_bridge:
  bridge_enabled: false
test_cmd: "echo LEGACY"
EOF
  awk '/^_resolve_test_cmd\(\)/,/^}/' "$PLUGIN_ROOT/skills/gaia-dev-story/scripts/dod-check.sh" > rt.sh
  echo '_resolve_test_cmd' >> rt.sh
  run bash rt.sh
  [ "$status" -eq 0 ]
  [ "$output" = "echo LEGACY" ]
}

@test "AF-29-1 F-12: bridge enabled but manifest absent falls through cleanly" {
  cd "$TEST_TMP"
  mkdir -p .gaia/config
  cat > .gaia/config/project-config.yaml <<'EOF'
project_name: smoke
test_execution_bridge:
  bridge_enabled: true
test_cmd: "echo FALLBACK"
EOF
  awk '/^_resolve_test_cmd\(\)/,/^}/' "$PLUGIN_ROOT/skills/gaia-dev-story/scripts/dod-check.sh" > rt.sh
  echo '_resolve_test_cmd' >> rt.sh
  run bash rt.sh
  [ "$status" -eq 0 ]
  [ "$output" = "echo FALLBACK" ]
}

# ===========================================================================
# F-016 HIGH — review-summary-gen.sh locates E105-S1 per-story layout
# ===========================================================================

@test "AF-29-1 F-16: _locate_story_file finds E105-S1 per-story story.md" {
  IA="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$IA/epic-E1-vault/E1-S1-scaffold"
  cat > "$IA/epic-E1-vault/E1-S1-scaffold/story.md" <<'EOF'
---
template: 'story'
key: E1-S1
status: in-progress
---
body
EOF
  awk '/^_locate_story_file\(\)/,/^}/' "$PLUGIN_ROOT/scripts/review-summary-gen.sh" > "$TEST_TMP/loc.sh"
  cat >> "$TEST_TMP/loc.sh" <<'EOF'
_die_not_found() { echo "DIE: $*" >&2; exit 1; }
STORY_FILE=""
_locate_story_file "$1"
echo "$STORY_FILE"
EOF
  cd "$TEST_TMP"
  run bash loc.sh E1-S1
  [ "$status" -eq 0 ]
  [[ "$output" == *"epic-E1-vault/E1-S1-scaffold/story.md" ]]
}

@test "AF-29-1 F-16: boundary guard — E1-S2 does NOT match E1-S21" {
  IA="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$IA/epic-E1-x/E1-S21-other"
  cat > "$IA/epic-E1-x/E1-S21-other/story.md" <<'EOF'
---
template: 'story'
key: E1-S21
---
body
EOF
  awk '/^_locate_story_file\(\)/,/^}/' "$PLUGIN_ROOT/scripts/review-summary-gen.sh" > "$TEST_TMP/loc.sh"
  cat >> "$TEST_TMP/loc.sh" <<'EOF'
_die_not_found() { echo "DIE: $*" >&2; exit 1; }
STORY_FILE=""
_locate_story_file "$1"
echo "$STORY_FILE"
EOF
  cd "$TEST_TMP"
  run bash loc.sh E1-S2
  [ "$status" -ne 0 ]
  [[ "$output" == *"story not found: E1-S2"* ]] || [[ "$output" == *"DIE"* ]]
}

@test "AF-29-1 F-16: legacy nested layout still resolves" {
  IA="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$IA/epic-E2-bar/stories"
  cat > "$IA/epic-E2-bar/stories/E2-S1-legacy.md" <<'EOF'
---
template: 'story'
key: E2-S1
---
body
EOF
  awk '/^_locate_story_file\(\)/,/^}/' "$PLUGIN_ROOT/scripts/review-summary-gen.sh" > "$TEST_TMP/loc.sh"
  cat >> "$TEST_TMP/loc.sh" <<'EOF'
_die_not_found() { echo "DIE: $*" >&2; exit 1; }
STORY_FILE=""
_locate_story_file "$1"
echo "$STORY_FILE"
EOF
  cd "$TEST_TMP"
  run bash loc.sh E2-S1
  [ "$status" -eq 0 ]
  [[ "$output" == *"epic-E2-bar/stories/E2-S1-legacy.md" ]]
}

# ===========================================================================
# F-001 + F-004 — generate-config.sh accepts list-form environments + preserves
# per-stack excludes
# ===========================================================================

@test "AF-29-1 F-1: generate-config transforms list-form environments to mapping" {
  cd "$TEST_TMP"
  cat > bundle.json <<'EOF'
{
  "project_name": "test",
  "project_kind": "service",
  "stacks": [{"name": "backend", "language": "python", "paths": ["src/"]}],
  "ci_platform": {"provider": "github-actions"},
  "platforms": ["github-actions"],
  "environments": [
    {"name": "staging", "url": "https://stg.example.com", "auth_type": "STAGING_TOKEN"}
  ]
}
EOF
  run bash "$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh" --path . --name test --phase full < bundle.json
  [ "$status" -eq 0 ]
  cfg="$(cat .gaia/config/project-config.yaml)"
  [[ "$cfg" == *"staging:"* ]]
  [[ "$cfg" == *"url: \"https://stg.example.com\""* ]]
  [[ "$cfg" == *"token: STAGING_TOKEN"* ]]
}

@test "AF-29-1 F-4: generate-config preserves per-stack excludes" {
  cd "$TEST_TMP"
  cat > bundle.json <<'EOF'
{
  "project_name": "test",
  "project_kind": "service",
  "stacks": [{
    "name": "backend",
    "language": "python",
    "paths": ["src/"],
    "excludes": [".env", "secrets/", ".venv/"]
  }],
  "ci_platform": {"provider": "github-actions"},
  "platforms": ["github-actions"]
}
EOF
  run bash "$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh" --path . --name test --phase full < bundle.json
  [ "$status" -eq 0 ]
  cfg="$(cat .gaia/config/project-config.yaml)"
  [[ "$cfg" == *"excludes:"* ]]
  [[ "$cfg" == *"- .env"* ]]
  [[ "$cfg" == *"- secrets/"* ]]
  [[ "$cfg" == *"- .venv/"* ]]
}

# ===========================================================================
# F-005 — threat-model SV-07/SV-09 accept numbered H2 headings
# ===========================================================================

@test "AF-29-1 F-5: stride_six_categories_per_component accepts '## 3. STRIDE Analysis' + numbered DREAD section" {
  cat > "$TEST_TMP/tm.md" <<'EOF'
## 1. Executive Summary

## 3. STRIDE Analysis

### Web frontend
- Spoofing: covered
- Tampering: covered
- Repudiation: covered
- Information Disclosure: covered
- Denial of Service: covered
- Elevation of Privilege: covered

## 4. DREAD Scoring

| Threat | Damage | Reproducibility | Exploitability | Affected Users | Discoverability |
|---|---|---|---|---|---|
| T-1 | 5 | 5 | 5 | 5 | 5 |

## 5. Mitigations
EOF
  awk '/^stride_six_categories_per_component\(\)/,/^}/' "$PLUGIN_ROOT/skills/gaia-threat-model/scripts/finalize.sh" > "$TEST_TMP/sv7.sh"
  echo 'stride_six_categories_per_component "$1"' >> "$TEST_TMP/sv7.sh"
  run bash "$TEST_TMP/sv7.sh" "$TEST_TMP/tm.md"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "AF-29-1 F-5: unnumbered STRIDE/DREAD headings still pass (regression)" {
  cat > "$TEST_TMP/tm.md" <<'EOF'
## STRIDE Analysis
### Web frontend
- Spoofing: x
- Tampering: x
- Repudiation: x
- Information Disclosure: x
- Denial of Service: x
- Elevation of Privilege: x
EOF
  awk '/^stride_six_categories_per_component\(\)/,/^}/' "$PLUGIN_ROOT/skills/gaia-threat-model/scripts/finalize.sh" > "$TEST_TMP/sv7.sh"
  echo 'stride_six_categories_per_component "$1"' >> "$TEST_TMP/sv7.sh"
  run bash "$TEST_TMP/sv7.sh" "$TEST_TMP/tm.md"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

# ===========================================================================
# F-013 + F-014 — backlog story flow
# ===========================================================================

@test "AF-29-1 F-13: backlog -> in-progress edge is now in the adjacency table" {
  grep -qF '"backlog|in-progress"' "$PLUGIN_ROOT/scripts/lib/story-state-machine.sh"
  # validate_story_transition should accept it
  ( source "$PLUGIN_ROOT/scripts/lib/story-state-machine.sh"
    validate_story_transition backlog in-progress ) >/dev/null 2>&1
}

@test "AF-29-1 F-13: invalid edges still rejected (regression)" {
  ! ( source "$PLUGIN_ROOT/scripts/lib/story-state-machine.sh"
      validate_story_transition backlog done ) >/dev/null 2>&1
}

@test "AF-29-1 F-14: detect-mode classifies status:backlog as FRESH" {
  cat > "$TEST_TMP/story.md" <<'EOF'
---
key: E1-S1
status: backlog
---
body
EOF
  run bash "$PLUGIN_ROOT/skills/gaia-dev-story/scripts/detect-mode.sh" "$TEST_TMP/story.md"
  [ "$status" -eq 0 ]
  [ "$output" = "FRESH" ]
}

@test "AF-29-1 F-14: status:in-progress without FAILED rows still classifies RESUME (regression)" {
  cat > "$TEST_TMP/story.md" <<'EOF'
---
key: E1-S1
status: in-progress
---
body
EOF
  run bash "$PLUGIN_ROOT/skills/gaia-dev-story/scripts/detect-mode.sh" "$TEST_TMP/story.md"
  [ "$status" -eq 0 ]
  [ "$output" = "RESUME" ]
}

# ===========================================================================
# F-015 — atdd-gate.sh honors GAIA_SKIP_ATDD=1
# ===========================================================================

@test "AF-29-1 F-15: GAIA_SKIP_ATDD=1 bypasses the high-risk ATDD halt" {
  grep -qF 'GAIA_SKIP_ATDD' "$PLUGIN_ROOT/skills/gaia-dev-story/scripts/atdd-gate.sh"
  # WARN line in the script body
  grep -qF "ATDD gate skipped via GAIA_SKIP_ATDD=1" "$PLUGIN_ROOT/skills/gaia-dev-story/scripts/atdd-gate.sh"
}

# ===========================================================================
# F-017 — load-stack-persona.sh accepts --story-file
# ===========================================================================

@test "AF-29-1 F-17: load-stack-persona.sh accepts --story-file and derives stack from frontmatter" {
  mkdir -p "$TEST_TMP/.gaia/artifacts/implementation-artifacts/epic-E1/E1-S1-x"
  cat > "$TEST_TMP/.gaia/artifacts/implementation-artifacts/epic-E1/E1-S1-x/story.md" <<'EOF'
---
template: 'story'
key: E1-S1
stack: python-dev
status: in-progress
---
body
EOF
  cd "$TEST_TMP"
  run bash "$PLUGIN_ROOT/scripts/load-stack-persona.sh" --story-file ".gaia/artifacts/implementation-artifacts/epic-E1/E1-S1-x/story.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stack='python-dev'"* ]]
}

@test "AF-29-1 F-17: --stack still works directly (regression)" {
  run bash "$PLUGIN_ROOT/scripts/load-stack-persona.sh" --stack ts-dev --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stack='ts-dev'"* ]]
}

@test "AF-29-1 F-17: unknown flags still rejected (regression)" {
  run bash "$PLUGIN_ROOT/scripts/load-stack-persona.sh" --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown argument: --bogus"* ]]
}

# ===========================================================================
# F-019 — retro finalize accepts JSON checkpoint form
# ===========================================================================

@test "AF-29-1 F-19: retro finalize accepts the canonical write-checkpoint.sh JSON form" {
  mkdir -p "$TEST_TMP/.gaia/memory/validator-sidecar" "$TEST_TMP/.gaia/memory/checkpoints/retrospective"
  echo "log" > "$TEST_TMP/.gaia/memory/validator-sidecar/decision-log.md"
  echo "{}" > "$TEST_TMP/.gaia/memory/checkpoints/retrospective/20260529-step-7.json"
  sleep 1
  touch "$TEST_TMP/.gaia/memory/validator-sidecar/decision-log.md"
  run env GAIA_FINALIZE_SENTINEL_REQUIRED=1 CLAUDE_PROJECT_ROOT="$TEST_TMP" PROJECT_PATH="$TEST_TMP" \
    bash "$PLUGIN_ROOT/skills/gaia-retro/scripts/finalize.sh"
  [[ "$output" == *"sentinel: PRESENT"* ]]
}

@test "AF-29-1 F-19: retro finalize ALSO accepts the legacy retrospective.yaml form (regression)" {
  mkdir -p "$TEST_TMP/.gaia/memory/validator-sidecar" "$TEST_TMP/.gaia/memory/checkpoints"
  echo "log" > "$TEST_TMP/.gaia/memory/validator-sidecar/decision-log.md"
  echo "---" > "$TEST_TMP/.gaia/memory/checkpoints/retrospective.yaml"
  sleep 1
  touch "$TEST_TMP/.gaia/memory/validator-sidecar/decision-log.md"
  run env GAIA_FINALIZE_SENTINEL_REQUIRED=1 CLAUDE_PROJECT_ROOT="$TEST_TMP" PROJECT_PATH="$TEST_TMP" \
    bash "$PLUGIN_ROOT/skills/gaia-retro/scripts/finalize.sh"
  [[ "$output" == *"sentinel: PRESENT"* ]]
}

# ===========================================================================
# Class-prevention: SKILL.md <-> script contract drift
# ===========================================================================
# Test08 surfaced a new recurring class — SKILL.md prose instructs a flag the
# script doesn't accept (F-001, F-005, F-010, F-017, F-019 all examples). This
# guard scans known SKILL.md script invocations and asserts the documented
# flags are accepted by the script's argv parser. Catches the class in CI
# before the next manual test.

@test "AF-29-1 sweep: documented load-stack-persona.sh flags are accepted by the script" {
  # The SKILL.md invocations across the plugin reference these flags. The
  # script's case-arm parser must list each one. Grep for the canonical case-arm
  # form (`--<flag>)`) so a flag named in a comment doesn't count.
  for f in --story-file --project-root --stack --agents-dir --memory-dir; do
    grep -qF -- "${f})" "$PLUGIN_ROOT/scripts/load-stack-persona.sh" \
      || { echo "load-stack-persona.sh does not accept $f"; false; }
  done
}

@test "AF-29-1 sweep: gaia-init SKILL.md environments shape matches generate-config.sh accepted form" {
  # SKILL.md Step 2.6 documents iterative {name, url, auth_type} entries.
  # generate-config.sh MUST handle a list of those objects (post-F-1 transform).
  grep -qF 'isinstance(envs, list)' "$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh"
  grep -qF '"name"' "$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh"
  grep -qF '"auth_type"' "$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh"
}

@test "AF-29-1 sweep: write-checkpoint.sh's output shape matches retro finalize.sh acceptance" {
  # write-checkpoint emits {skill_name}/{ts}-step-{N}.json; retro finalize MUST
  # accept that form (F-19). The legacy retrospective.yaml form is also accepted
  # as a back-compat allowance.
  grep -qF 'retrospective"/*-step-*.json' "$PLUGIN_ROOT/skills/gaia-retro/scripts/finalize.sh"
  grep -qF 'retrospective.yaml' "$PLUGIN_ROOT/skills/gaia-retro/scripts/finalize.sh"
}
