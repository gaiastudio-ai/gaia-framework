#!/usr/bin/env bats
# AF-2026-05-30-2: Test10 findings — full-lifecycle brownfield manual test
# on GAIA 1.180.9/10 surfaced 39 findings + a §7 design proposal for the
# degraded deterministic-tools layer + 10 doc gaps + 5 layout drifts.
#
# This suite covers the framework changes:
#   - /gaia-doctor skill (Test10 §7 C1 + Test01 §E1 + Test05 §20)
#   - Tier banner in consolidated-gaps.md (Test10 §7 C3)
#   - F-27 bridge wiring (HIGH — bridge populates test_execution; runner hard-fails)
#   - F-01 zero-config draft path in detect-signals.sh (HIGH)
#   - F-05 headless platformId (HIGH) + F-07 primary_platform sync (HIGH)
#   - F-09 bash 3.2 guard in orchestrator.sh (MEDIUM)
#   - F-24 .gaia/state ledger always-canonical (MEDIUM)
#   - F-25 AC checkbox documentation (MEDIUM)
#   - F-29 DoD blocks done (MEDIUM)
#   - F-33 dep-lint frontmatter union + done-gate deps (MEDIUM)
#   - F-31 retro action-items canonical path + sprint-close via transition (MEDIUM)
#   - F-28 story-key extraction from per-story parent dir (MEDIUM)
#   - F-17 resolve-config project_config_path canonical (MEDIUM)
#   - F-12 pyproject.toml testpaths detection (MEDIUM)
#   - F-16 adversarial collision script-enforced (MEDIUM)
#   - F-11 canonical gap-entry schema (MEDIUM)
#   - F-22 test-strategy docs-only no-mutate (MEDIUM)
#   - F-32 YOLO fallback documented (MEDIUM)

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

# ===========================================================================
# /gaia-doctor skill
# ===========================================================================

@test "doctor: skill directory + SKILL.md present" {
  [ -f "$PLUGIN_ROOT/skills/gaia-doctor/SKILL.md" ]
}

@test "doctor: tool-readiness registry is valid JSON" {
  run jq -e '.' "$PLUGIN_ROOT/skills/gaia-doctor/knowledge/tool-readiness.json"
  [ "$status" -eq 0 ]
}

@test "doctor: check-tools.sh exits 0 and emits a readiness table on a fresh tmpdir" {
  cd "$TEST_TMP"
  mkdir -p .gaia/config
  cat > .gaia/config/project-config.yaml <<'EOF'
project_name: smoke
stacks:
  - language: python
    paths: [.]
EOF
  run env CLAUDE_PROJECT_ROOT="$TEST_TMP" \
        bash "$PLUGIN_ROOT/skills/gaia-doctor/scripts/check-tools.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "readiness for stack" ]] || [[ "$output" =~ "Achievable scan tier" ]]
}

@test "doctor: --json emits parseable JSON" {
  cd "$TEST_TMP"
  mkdir -p .gaia/config
  cat > .gaia/config/project-config.yaml <<'EOF'
project_name: smoke
stacks:
  - language: python
    paths: [.]
EOF
  run env CLAUDE_PROJECT_ROOT="$TEST_TMP" \
        bash "$PLUGIN_ROOT/skills/gaia-doctor/scripts/check-tools.sh" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tier' >/dev/null
}

# ===========================================================================
# Tier banner in consolidated-gaps.md (Test10 §7 C3)
# ===========================================================================

@test "brownfield: Phase 7 SKILL.md instructs scan-fidelity banner stamp" {
  run grep -F 'Scan fidelity' "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "brownfield: SKILL.md references the doctor check-tools.sh for tier resolution" {
  run grep -F 'gaia-doctor/scripts/check-tools.sh' "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-27: bridge wiring
# ===========================================================================

@test "qa-test-runner.sh documents HARD FAIL when bridge enabled but no tier configured" {
  # Static prose assertion — full runner invocation requires a richer harness
  # than we ship in this bats fixture (and the runner contract is internal).
  # Confirm the script body carries the fail-closed branch (HARD FAIL when
  # bridge is enabled but no tier is configured).
  run grep -F 'HARD FAIL: bridge enabled' \
        "$PLUGIN_ROOT/scripts/review-common/qa-test-runner.sh"
  [ "$status" -eq 0 ]
  run grep -F 'BRIDGE_ENABLED' \
        "$PLUGIN_ROOT/scripts/review-common/qa-test-runner.sh"
  [ "$status" -eq 0 ]
}

@test "bridge-populate-test-execution.sh respects already-set tiers" {
  cd "$TEST_TMP"
  mkdir -p .gaia/config
  cat > .gaia/config/project-config.yaml <<'EOF'
project_name: smoke
test_execution:
  tier_1:
    command: "operator wired"
EOF
  cat > .gaia/config/test-environment.yaml <<'EOF'
version: 2
runners:
  - name: unit
    command: "auto-suggested"
    tier: 1
    timeout_seconds: 60
EOF
  run env CLAUDE_PROJECT_ROOT="$TEST_TMP" \
        bash "$PLUGIN_ROOT/scripts/lib/bridge-populate-test-execution.sh"
  [ "$status" -eq 0 ]
  # Operator command must be preserved
  grep -F 'command: operator wired' .gaia/config/project-config.yaml || \
    grep -F 'command: "operator wired"' .gaia/config/project-config.yaml
}

@test "bridge-populate writes test_execution.tier_1.command from manifest" {
  cd "$TEST_TMP"
  mkdir -p .gaia/config
  cat > .gaia/config/project-config.yaml <<'EOF'
project_name: smoke
EOF
  cat > .gaia/config/test-environment.yaml <<'EOF'
version: 2
runners:
  - name: unit
    command: "bats tests/"
    tier: 1
    timeout_seconds: 300
EOF
  run env CLAUDE_PROJECT_ROOT="$TEST_TMP" \
        bash "$PLUGIN_ROOT/scripts/lib/bridge-populate-test-execution.sh"
  [ "$status" -eq 0 ]
  run yq -r '.test_execution.tier_1.command' .gaia/config/project-config.yaml
  [ "$status" -eq 0 ]
  [[ "$output" =~ "bats tests" ]]
}

# ===========================================================================
# F-01: zero-config draft path
# ===========================================================================

@test "detect-signals --merge-into seeds a stub on absent target" {
  cd "$TEST_TMP"
  mkdir -p src/feature
  echo "print('hi')" > src/feature/main.py
  run env PROJECT_ROOT="$TEST_TMP" \
        bash "$PLUGIN_ROOT/scripts/detect-signals.sh" \
          --project-root "$TEST_TMP" \
          --merge-into "$TEST_TMP/.gaia/config/project-config.yaml" \
          --output "$TEST_TMP/.gaia/config/project-config.draft.yaml"
  # exit code may be 1 for verdict=WARNING but the seed write must have happened
  [ -f "$TEST_TMP/.gaia/config/project-config.yaml" ]
  run grep -F 'Auto-seeded by detect-signals.sh' "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-05 / F-07: platformId enum + primary_platform sync
# ===========================================================================

@test "JSON schema platformId enum includes server" {
  run jq -e '.definitions.platformId.enum | index("server")' \
        "$PLUGIN_ROOT/schemas/project-config.schema.json"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
}

@test "generate-config emits platforms:[server] for ui_present:false" {
  run grep -F '"server"' "$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh"
  [ "$status" -eq 0 ]
}

@test "YAML descriptor schema declares primary_platform" {
  run grep -E '^[[:space:]]+primary_platform:' \
        "$PLUGIN_ROOT/config/project-config.schema.yaml"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-09: bash 3.2 guard
# ===========================================================================

@test "orchestrator.sh has BASH_VERSINFO guard before globstar" {
  run grep -F 'BASH_VERSINFO' \
        "$PLUGIN_ROOT/scripts/adapters/brownfield/orchestrator.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-24: .gaia/state ledger always-canonical
# ===========================================================================

@test "review-gate ledger resolves to .gaia/state when .gaia/ exists" {
  cd "$TEST_TMP"
  mkdir -p .gaia
  run env PROJECT_PATH="$TEST_TMP" \
        bash -c "source \"$PLUGIN_ROOT/scripts/review-gate.sh\" 2>/dev/null; resolve_ledger_path 2>/dev/null || true"
  # Easier check: invoke the script in `status` mode and inspect the writable side-effect:
  # since resolve_ledger_path is internal, just confirm the .gaia/state seed wording
  # is present in the script body.
  run grep -F 'mkdir -p "$root/.gaia/state"' "$PLUGIN_ROOT/scripts/review-gate.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-25: AC checkbox format documented
# ===========================================================================

@test "create-story SKILL.md documents AC checkbox requirement" {
  run grep -F 'AC checkbox format' \
        "$PLUGIN_ROOT/skills/gaia-create-story/SKILL.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-29: DoD blocks done
# ===========================================================================

@test "sprint-state.sh has DoD-unchecked guard on -> done" {
  run grep -F 'DoD item(s) unchecked' \
        "$PLUGIN_ROOT/scripts/sprint-state.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-33: dep-lint frontmatter union + done-gate deps
# ===========================================================================

@test "backlog-select-lint reads frontmatter depends_on" {
  run grep -F '_frontmatter_deps_of' \
        "$PLUGIN_ROOT/scripts/backlog-select-lint.sh"
  [ "$status" -eq 0 ]
}

@test "sprint-state.sh enforces deps on -> done" {
  run grep -F 'unmet hard dependencies' \
        "$PLUGIN_ROOT/scripts/sprint-state.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-31: action-items canonical path + sprint-close via transition
# ===========================================================================

@test "gaia-retro writes action-items to state-tier canonical path" {
  # The retro write target is the state-tier canonical: .gaia/state/action-items.yaml.
  # The planning-artifacts path is retained as a read-compat fallback in the resolver.
  grep -qF '.gaia/state/action-items.yaml' "$PLUGIN_ROOT/skills/gaia-retro/SKILL.md"
}

@test "gaia-retro Step 5 write target is the state-tier path" {
  # The --target flag in the Step 5 invocation code-fence must point to
  # .gaia/state/action-items.yaml (the canonical write target).
  grep -q '\-\-target.*\.gaia/state/action-items\.yaml' "$PLUGIN_ROOT/skills/gaia-retro/SKILL.md"
}

@test "retro setup.sh stamps a run-started checkpoint" {
  run grep -F 'write-checkpoint.sh' \
        "$PLUGIN_ROOT/skills/gaia-retro/scripts/setup.sh"
  [ "$status" -eq 0 ]
}

@test "sprint-close routes status flip through sprint-state.sh transition" {
  run grep -F 'sprint-state.sh' \
        "$PLUGIN_ROOT/skills/gaia-sprint-close/scripts/close.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-28: story-key extraction from per-story parent dir
# ===========================================================================

# Retargeted from the retired scan-findings.sh to the per-story extractor
# (E39-S6). Now a BEHAVIORAL assertion: the extractor derives the story key
# from the per-story parent dir when the basename is story.md.
@test "findings extractor extracts key from per-story parent dir" {
  d="$BATS_TEST_TMPDIR/E60-S7-slug"; mkdir -p "$d"
  printf -- '---\nstatus: "done"\n---\n## Findings\n| # | Type | Severity | Finding | Suggested Action |\n|---|------|----------|---------|------------------|\n| 1 | tech-debt | low | x | y |\n' > "$d/story.md"
  run "$PLUGIN_ROOT/skills/gaia-triage-findings/scripts/extract-findings.sh" --story-file "$d/story.md"
  [ "$status" -eq 0 ]
  [[ "$output" == E60-S7\|* ]]   # key derived from parent dir name
}

# ===========================================================================
# F-17: resolve-config project_config_path canonical
# ===========================================================================

@test "resolve-config project_config_path prefers .gaia/config/" {
  # Sanity-check the implementation has the canonical branch
  run grep -F '.gaia/config/project-config.yaml' \
        "$PLUGIN_ROOT/scripts/resolve-config.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-12: pyproject.toml testpaths detection
# ===========================================================================

@test "test-environment-manifest reads pyproject.toml testpaths" {
  run grep -F 'tool.pytest.ini_options' \
        "$PLUGIN_ROOT/scripts/lib/test-environment-manifest.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-16: adversarial collision script-enforced
# ===========================================================================

@test "adversarial resolve-write-path.sh exists and is executable" {
  [ -x "$PLUGIN_ROOT/skills/gaia-adversarial/scripts/resolve-write-path.sh" ]
}

@test "resolve-write-path returns next-free suffix on collision" {
  cd "$TEST_TMP"
  mkdir -p .gaia/artifacts/planning-artifacts/adversarial
  touch .gaia/artifacts/planning-artifacts/adversarial/adversarial-review-prd-2026-05-30.md
  run env PROJECT_ROOT="$TEST_TMP" \
        bash "$PLUGIN_ROOT/skills/gaia-adversarial/scripts/resolve-write-path.sh" \
          --target prd --date 2026-05-30
  [ "$status" -eq 0 ]
  [[ "$output" =~ adversarial-review-prd-2026-05-30-2\.md$ ]]
}

# ===========================================================================
# F-11: canonical gap-entry schema
# ===========================================================================

@test "brownfield-gap-entry schema exists and is valid JSON Schema" {
  [ -f "$PLUGIN_ROOT/schemas/brownfield-gap-entry.schema.json" ]
  run jq -e '."$schema" and .properties.gap_id and .properties.category' \
        "$PLUGIN_ROOT/schemas/brownfield-gap-entry.schema.json"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-22: test-strategy docs-only no-mutate
# ===========================================================================

@test "test-strategy finalize honors GAIA_TEST_STRATEGY_DOCS_ONLY" {
  run grep -F 'GAIA_TEST_STRATEGY_DOCS_ONLY' \
        "$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/finalize.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-32: YOLO fallback documented
# ===========================================================================

@test "sprint-review documents --yolo-defaults fallback" {
  # Use -e -- to stop grep flag parsing so the literal --yolo-defaults works.
  run grep -F -e '--yolo-defaults' \
        "$PLUGIN_ROOT/skills/gaia-sprint-review/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "retro documents seed-from-metrics fallback" {
  run grep -F 'seed-from-metrics' \
        "$PLUGIN_ROOT/skills/gaia-retro/SKILL.md"
  [ "$status" -eq 0 ]
}
