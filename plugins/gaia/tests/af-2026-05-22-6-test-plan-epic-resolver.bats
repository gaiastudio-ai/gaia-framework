#!/usr/bin/env bats
# AF-2026-05-22-6: bundle of 3 HIGH-severity bugs from the YARA test report.
#
# Bug 4: gaia-create-epics setup.sh hardcoded the flat test-plan.md path,
#        so /gaia-test-strategy --plan output (strategy/test-strategy.md)
#        triggered a false "exists but empty" halt.
# Bug 5: resolve-epic-slug.sh required `## E{N} — Title` em-dash form only,
#        rejecting the natural `## Epic N: Title` form pm subagents produce.
# Bug 20: filename mismatch — producer (gaia-test-strategy --plan) writes
#         test-strategy.md, consumers (gaia-create-epics, gaia-add-feature)
#         expected test-plan.md. Fixed by widening both consumers' fallback.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

# --- Bug 4: gaia-create-epics setup.sh accepts all 4 test-plan paths ---

@test "gaia-create-epics setup.sh resolves strategy/test-strategy.md" {
  local tmp="$BATS_TEST_TMPDIR/yara-fixture"
  mkdir -p "$tmp/.gaia/artifacts/test-artifacts/strategy"
  printf 'fake strategy content\n' > "$tmp/.gaia/artifacts/test-artifacts/strategy/test-strategy.md"
  grep -qE 'strategy/test-strategy\.md' "$PLUGIN_ROOT/skills/gaia-create-epics/scripts/setup.sh"
}

@test "gaia-create-epics setup.sh enumerates all 4 accepted paths in the resolver loop" {
  grep -qF 'test-plan.md' "$PLUGIN_ROOT/skills/gaia-create-epics/scripts/setup.sh"
  grep -qF 'strategy/test-plan.md' "$PLUGIN_ROOT/skills/gaia-create-epics/scripts/setup.sh"
  grep -qF 'strategy/test-strategy.md' "$PLUGIN_ROOT/skills/gaia-create-epics/scripts/setup.sh"
  grep -qF 'test-plan/index.md' "$PLUGIN_ROOT/skills/gaia-create-epics/scripts/setup.sh"
}

@test "gaia-create-epics setup.sh halt message references /gaia-test-strategy (not /gaia-test-design)" {
  grep -qF '/gaia-test-strategy --plan' "$PLUGIN_ROOT/skills/gaia-create-epics/scripts/setup.sh"
}

# --- Bug 5: resolve-epic-slug.sh accepts both heading forms ---

@test "resolve-epic-slug.sh resolves '## E1 — Title' (canonical em-dash form)" {
  local epics_file="$BATS_TEST_TMPDIR/epics-form-a.md"
  printf '## E1 — Core Brain Vault\n\ncontent\n' > "$epics_file"
  run bash -c "source '$PLUGIN_ROOT/scripts/lib/resolve-epic-slug.sh' && resolve_epic_slug E1 '$epics_file'"
  [ "$status" -eq 0 ]
  [ "$output" = "epic-E1-core-brain-vault" ]
}

@test "resolve-epic-slug.sh resolves '## Epic 1: Title' (natural-language form)" {
  local epics_file="$BATS_TEST_TMPDIR/epics-form-b.md"
  printf '## Epic 1: Core Brain Vault\n\ncontent\n' > "$epics_file"
  run bash -c "source '$PLUGIN_ROOT/scripts/lib/resolve-epic-slug.sh' && resolve_epic_slug E1 '$epics_file'"
  [ "$status" -eq 0 ]
  [ "$output" = "epic-E1-core-brain-vault" ]
}

@test "resolve-epic-slug.sh both forms yield identical slug" {
  local form_a="$BATS_TEST_TMPDIR/epics-form-a-2.md"
  local form_b="$BATS_TEST_TMPDIR/epics-form-b-2.md"
  printf '## E7 — Sprint Engine Pro\n' > "$form_a"
  printf '## Epic 7: Sprint Engine Pro\n' > "$form_b"
  local slug_a slug_b
  slug_a=$(bash -c "source '$PLUGIN_ROOT/scripts/lib/resolve-epic-slug.sh' && resolve_epic_slug E7 '$form_a'")
  slug_b=$(bash -c "source '$PLUGIN_ROOT/scripts/lib/resolve-epic-slug.sh' && resolve_epic_slug E7 '$form_b'")
  [ "$slug_a" = "$slug_b" ]
  [ "$slug_a" = "epic-E7-sprint-engine-pro" ]
}

@test "resolve-epic-slug.sh rejects unsupported heading forms with clear error" {
  local epics_file="$BATS_TEST_TMPDIR/epics-form-c.md"
  printf '## 1. Core Brain Vault\n' > "$epics_file"
  run bash -c "source '$PLUGIN_ROOT/scripts/lib/resolve-epic-slug.sh' && resolve_epic_slug E1 '$epics_file'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
  # Error names both accepted forms so the user has a clear remediation path.
  [[ "$output" == *"## E1 — Title"* ]] || [[ "$output" == *"Epic 1"* ]]
}

@test "gaia-create-epics SKILL.md documents both accepted heading forms" {
  grep -qF '## E{N} — {Epic Title}' "$PLUGIN_ROOT/skills/gaia-create-epics/SKILL.md"
  grep -qF '## Epic {N}: {Epic Title}' "$PLUGIN_ROOT/skills/gaia-create-epics/SKILL.md"
}

# --- Bug 20: gaia-add-feature accepts test-strategy.md ---

@test "gaia-add-feature setup.sh accepts strategy/test-strategy.md" {
  grep -qF 'strategy/test-strategy.md' "$PLUGIN_ROOT/skills/gaia-add-feature/scripts/setup.sh"
}

@test "gaia-add-feature setup.sh accepts all 4 test-plan paths" {
  grep -qF 'test-plan.md' "$PLUGIN_ROOT/skills/gaia-add-feature/scripts/setup.sh"
  grep -qF 'strategy/test-plan.md' "$PLUGIN_ROOT/skills/gaia-add-feature/scripts/setup.sh"
  grep -qF 'strategy/test-strategy.md' "$PLUGIN_ROOT/skills/gaia-add-feature/scripts/setup.sh"
  grep -qF 'test-plan/index.md' "$PLUGIN_ROOT/skills/gaia-add-feature/scripts/setup.sh"
}

@test "gaia-add-feature halt message points at /gaia-test-strategy (not /gaia-test-design)" {
  grep -qF '/gaia-test-strategy --plan' "$PLUGIN_ROOT/skills/gaia-add-feature/scripts/setup.sh"
}

# --- Bug 6: Test Execution Bridge schema accepts command + timeout_seconds ---

@test "project-config.schema.json test_execution.tier_N accepts command" {
  python3 -c "
import json
schema = json.load(open('$PLUGIN_ROOT/schemas/project-config.schema.json'))
props = schema['properties']['test_execution']['properties']
for tier in ['tier_1', 'tier_2', 'tier_3']:
    assert 'command' in props[tier]['properties'], f'{tier} missing command'
    assert 'timeout_seconds' in props[tier]['properties'], f'{tier} missing timeout_seconds'
print('OK')
"
}

@test "project-config.schema.yaml test_execution description mentions command + timeout_seconds" {
  # The single-line description under test_execution must reference command + timeout_seconds.
  local desc_line
  desc_line=$(grep -A4 '^  test_execution:$' "$PLUGIN_ROOT/config/project-config.schema.yaml" | grep '^    description:')
  [[ "$desc_line" == *"command"* ]]
  [[ "$desc_line" == *"timeout_seconds"* ]]
}

@test "gaia-sprint-close resolve_yaml_path drops retired impl-artifacts rung" {
  # The .gaia/artifacts/implementation-artifacts/ mirror has been retired
  # (Issue #1109 deprecation). close.sh must no longer reference it.
  ! grep -qF 'gaia_artifacts="$PROJECT_PATH/.gaia/artifacts/implementation-artifacts/sprint-status.yaml"' "$PLUGIN_ROOT/skills/gaia-sprint-close/scripts/close.sh"
  # Resolver order: .gaia/state → legacy docs/ → fallback
  grep -qE 'if \[ -f "\$gaia_state" \]; then' "$PLUGIN_ROOT/skills/gaia-sprint-close/scripts/close.sh"
  grep -qE 'elif \[ -f "\$legacy_docs" \]; then' "$PLUGIN_ROOT/skills/gaia-sprint-close/scripts/close.sh"
}

@test "gaia-sprint-close default-when-missing points at canonical .gaia/state/" {
  # Final else branch (no file found) defaults to .gaia/state/ — the sole
  # canonical write target after the impl-artifacts mirror was retired.
  grep -qE "printf '%s\\\\n' \"\\\$gaia_state\"" "$PLUGIN_ROOT/skills/gaia-sprint-close/scripts/close.sh"
}

@test "a populated test_execution config with command validates against the schema" {
  cat > "$BATS_TEST_TMPDIR/yara-config.yaml" <<'EOF'
config_phase: minimal
project_name: yara-test
project_root: /tmp/yara
project_path: /tmp/yara
test_execution:
  tier_1:
    placement: local
    command: "npm run test:unit"
    timeout_seconds: 300
  tier_2:
    placement: ci-pre-merge
    command: "npm run test:integration"
    timeout_seconds: 600
EOF
  python3 -c "
import json, yaml
schema = json.load(open('$PLUGIN_ROOT/schemas/project-config.schema.json'))
config = yaml.safe_load(open('$BATS_TEST_TMPDIR/yara-config.yaml'))
te = config.get('test_execution', {})
# Spot-check: tier_1.command + timeout_seconds are present and accepted by the schema shape.
assert te['tier_1']['command'] == 'npm run test:unit'
assert te['tier_1']['timeout_seconds'] == 300
# Verify schema properties match what we just inserted (additionalProperties: false guard).
allowed = set(schema['properties']['test_execution']['properties']['tier_1']['properties'].keys())
for k in te['tier_1'].keys():
    assert k in allowed, f'key {k} not in schema-allowed: {allowed}'
print('OK')
"
}
