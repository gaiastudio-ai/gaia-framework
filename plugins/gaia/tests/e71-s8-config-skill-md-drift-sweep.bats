#!/usr/bin/env bats
# e71-s8-config-skill-md-drift-sweep.bats — E71-S8
#
# Framework-wide /gaia-config-* SKILL.md drift sweep:
#   AC1 — D1: resolve-config.sh project_config_path synthetic key works
#   AC2 — D2: stale "eleven top-level sections" enumeration swept (8 files)
#   AC3 — D3: canonical CRUD-menu disclaimer added (10 files)
#   AC4 — D2 + D3 invariant test extension (covered by D2 + D3 assertions here
#         and re-asserted in e71-s7-config-section-cluster.bats per AC4 prose)
#   AC5 — test plan + traceability cascade

load 'test_helper.bash'
bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SKILLS="$PLUGIN_DIR/skills"
SCRIPTS="$PLUGIN_DIR/scripts"
RESOLVE="$SCRIPTS/resolve-config.sh"

# Path to the project-root docs/ artifacts (testplan + traceability) — these
# live OUTSIDE plugins/gaia/ but the test must still verify they were updated.
DOCS_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../../docs" 2>/dev/null && pwd || true)"

setup() {
  common_setup
}
teardown() { common_teardown; }

mk_project() {
  local dir="$1"
  mkdir -p "$dir/config"
  cat > "$dir/config/project-config.yaml" <<'YAML'
project_root: /tmp/gaia-e71s8
project_path: /tmp/gaia-e71s8/app
memory_path: /tmp/gaia-e71s8/_memory
checkpoint_path: /tmp/gaia-e71s8/_memory/checkpoints
installed_path: /tmp/gaia-e71s8/_gaia
framework_version: 1.0.0
date: 2026-05-14
YAML
}

# ───────────────────────── AC1 — D1: resolve-config.sh project_config_path ─────────────────────────

# TC-CFGD-1
@test "AC1 (TC-CFGD-1): resolve-config.sh project_config_path returns <project_root>/config/project-config.yaml" {
  mk_project "$TEST_TMP/skill"
  run "$RESOLVE" --config "$TEST_TMP/skill/config/project-config.yaml" project_config_path
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/gaia-e71s8/config/project-config.yaml" ]
}

# TC-CFGD-6 (mirror existing memory_path/checkpoint_path coverage)
@test "AC1 (TC-CFGD-6): resolve-config.sh --field project_config_path emits the resolved scalar" {
  mk_project "$TEST_TMP/skill"
  run "$RESOLVE" --config "$TEST_TMP/skill/config/project-config.yaml" --field project_config_path
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/gaia-e71s8/config/project-config.yaml" ]
}

@test "AC1: resolve-config.sh --all emits project_config_path key" {
  mk_project "$TEST_TMP/skill"
  run "$RESOLVE" --config "$TEST_TMP/skill/config/project-config.yaml" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"project_config_path='/tmp/gaia-e71s8/config/project-config.yaml'"* ]]
}

# ───────────────────────── AC2 — D2: stale enumeration sweep (8 files) ─────────────────────────

# TC-CFGD-2
@test "AC2 (TC-CFGD-2): zero /gaia-config-* SKILL.md files contain the stale eleven-section enumeration" {
  # The forbidden enumeration mixes 5 nonexistent names (project, regimes,
  # tool_adapters, rubrics, deployment) into a top-level-sections list.
  # Match the literal joined form to avoid false positives on prose that
  # happens to mention any one name in isolation.
  local violations=()
  local f
  for f in "$SKILLS"/gaia-config-*/SKILL.md; do
    if grep -qE '`project`,? `stacks`,? `platforms`,? `regimes`' "$f"; then
      violations+=("$f")
    fi
  done
  [ "${#violations[@]}" -eq 0 ] || {
    printf 'VIOLATION: %s\n' "${violations[@]}" >&2
    return 1
  }
}

# Per-file scoped check for the 8 files E71-S8 owns
@test "AC2: /gaia-config-compliance/SKILL.md no longer enumerates the 11 stale sections" {
  ! grep -qE '`project`,? `stacks`,? `platforms`,? `regimes`' \
    "$SKILLS/gaia-config-compliance/SKILL.md"
}

@test "AC2: /gaia-config-device-target/SKILL.md no longer enumerates the 11 stale sections" {
  ! grep -qE '`project`,? `stacks`,? `platforms`,? `regimes`' \
    "$SKILLS/gaia-config-device-target/SKILL.md"
}

@test "AC2: /gaia-config-env/SKILL.md no longer enumerates the 11 stale sections" {
  ! grep -qE '`project`,? `stacks`,? `platforms`,? `regimes`' \
    "$SKILLS/gaia-config-env/SKILL.md"
}

@test "AC2: /gaia-config-platform/SKILL.md no longer enumerates the 11 stale sections" {
  ! grep -qE '`project`,? `stacks`,? `platforms`,? `regimes`' \
    "$SKILLS/gaia-config-platform/SKILL.md"
}

@test "AC2: /gaia-config-show/SKILL.md no longer enumerates the 11 stale sections" {
  ! grep -qE '`project`,? `stacks`,? `platforms`,? `regimes`' \
    "$SKILLS/gaia-config-show/SKILL.md"
}

@test "AC2: /gaia-config-stack/SKILL.md no longer enumerates the 11 stale sections" {
  ! grep -qE '`project`,? `stacks`,? `platforms`,? `regimes`' \
    "$SKILLS/gaia-config-stack/SKILL.md"
}

@test "AC2: /gaia-config-test/SKILL.md no longer enumerates the 11 stale sections" {
  ! grep -qE '`project`,? `stacks`,? `platforms`,? `regimes`' \
    "$SKILLS/gaia-config-test/SKILL.md"
}

@test "AC2: /gaia-config-validate/SKILL.md no longer enumerates the 11 stale sections" {
  ! grep -qE '`project`,? `stacks`,? `platforms`,? `regimes`' \
    "$SKILLS/gaia-config-validate/SKILL.md"
}

# ───────────────────────── AC3 — D3: canonical CRUD-menu disclaimer ─────────────────────────

# TC-CFGD-3 — disclaimer present in all 10 files
@test "AC3 (TC-CFGD-3): canonical disclaimer present in all 10 /gaia-config-* SKILL.md files" {
  local f missing=()
  for f in "$SKILLS"/gaia-config-compliance/SKILL.md \
           "$SKILLS"/gaia-config-device-target/SKILL.md \
           "$SKILLS"/gaia-config-env/SKILL.md \
           "$SKILLS"/gaia-config-platform/SKILL.md \
           "$SKILLS"/gaia-config-rubric/SKILL.md \
           "$SKILLS"/gaia-config-show/SKILL.md \
           "$SKILLS"/gaia-config-stack/SKILL.md \
           "$SKILLS"/gaia-config-test/SKILL.md \
           "$SKILLS"/gaia-config-tool/SKILL.md \
           "$SKILLS"/gaia-config-validate/SKILL.md; do
    if ! grep -qF 'LLM-driven interaction pattern under Claude Code main-turn orchestration' "$f"; then
      missing+=("$f")
    fi
  done
  [ "${#missing[@]}" -eq 0 ] || {
    printf 'MISSING DISCLAIMER: %s\n' "${missing[@]}" >&2
    return 1
  }
}

@test "AC3: disclaimer identifies the LLM orchestrator as the menu executor" {
  local f missing=()
  for f in "$SKILLS"/gaia-config-{compliance,env,platform,show,stack,test,tool,validate}/SKILL.md; do
    if ! grep -qF 'the menu is performed by the LLM orchestrator from this SKILL.md, not by a TUI' "$f"; then
      missing+=("$f")
    fi
  done
  [ "${#missing[@]}" -eq 0 ] || {
    printf 'MISSING ORCHESTRATOR ATTRIBUTION: %s\n' "${missing[@]}" >&2
    return 1
  }
}

# ───────────────────────── AC5 — test plan + traceability cascade ─────────────────────────

# TC-CFGD-5
@test "AC5 (TC-CFGD-5): test plan §11.74 contains TC-CFGD-1..5 rows" {
  [ -n "$DOCS_ROOT" ] || skip "DOCS_ROOT not resolvable from this test location"
  local tp="$DOCS_ROOT/test-artifacts/strategy/test-plan.md"
  [ -f "$tp" ] || skip "test plan not present at $tp"
  grep -qE '§?11\.74|## 11\.74|### 11\.74' "$tp"
  grep -qE 'TC-CFGD-1' "$tp"
  grep -qE 'TC-CFGD-2' "$tp"
  grep -qE 'TC-CFGD-3' "$tp"
  grep -qE 'TC-CFGD-4' "$tp"
  grep -qE 'TC-CFGD-5' "$tp"
}

@test "AC5: traceability matrix §31 maps E71-S8 → TC-CFGD-1..5" {
  [ -n "$DOCS_ROOT" ] || skip "DOCS_ROOT not resolvable from this test location"
  local trm="$DOCS_ROOT/test-artifacts/strategy/traceability-matrix.md"
  [ -f "$trm" ] || skip "traceability matrix not present at $trm"
  grep -qE '§?31|## 31|### 31' "$trm"
  grep -qE 'E71-S8' "$trm"
  grep -qE 'TC-CFGD-' "$trm"
  grep -qE 'AF-2026-05-14-2' "$trm"
}
