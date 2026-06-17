#!/usr/bin/env bats
# e71-s7-config-section-cluster.bats — E71-S7
#
# Wrong-section-name cluster fix for /gaia-config-* skill suite:
#   AC1 — /gaia-config-tool retargeted from `tool_adapters` to `tools`
#   AC2 — /gaia-config-rubric retired as deprecation-redirect stub
#   AC3 — /gaia-config-severity skill created
#   AC4 — /gaia-config-gates skill created
#   AC5 — config-yaml-editor.sh insert schema-aware fail-safe
#   AC6 — stale "eleven top-level sections" enumeration reconciled
#   AC7 — invariant + behavior + reverse coverage

load 'test_helper.bash'
bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPTS="$PLUGIN_DIR/scripts"
SKILLS="$PLUGIN_DIR/skills"
SCHEMA="$PLUGIN_DIR/schemas/project-config.schema.json"
EDITOR="$SCRIPTS/config-yaml-editor.sh"
SEVERITY_EDIT="$SCRIPTS/gaia-config-severity-edit.sh"
GATES_EDIT="$SCRIPTS/gaia-config-gates-edit.sh"

setup() {
  common_setup
  CFG="$TEST_TMP/project-config.yaml"
  cat > "$CFG" <<'YAML'
project_root: /tmp/x
project_path: /tmp/x
memory_path: /tmp/x/_memory
checkpoint_path: /tmp/x/_memory/checkpoints
installed_path: /tmp/x
framework_version: 0.0.0
date: 2026-05-14

stacks:
  - name: app
    language: swift
    paths: ["src/**"]
YAML
}
teardown() { common_teardown; }

# ───────────────────────── AC1 — /gaia-config-tool retargeted ─────────────────────────

# TC-CFGS7-1
@test "gaia-config-tool SKILL.md contains zero tool_adapters tokens" {
  run grep -c 'tool_adapters' "$SKILLS/gaia-config-tool/SKILL.md"
  [ "$status" -ne 0 ] || [ "$output" = "0" ]
}

@test "gaia-config-tool SKILL.md uses the canonical tools section name" {
  run grep -c '\btools\b' "$SKILLS/gaia-config-tool/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 3 ]
}

# TC-CFGS7-2
@test "gaia-config-tool default scaffold uses adapter-inventory category names" {
  # Per Val F-2: scaffold category names must match list-adapters.sh inventory.
  # Canonical names: sast / secret-scan / dep-audit (NOT sast/secrets/sca).
  grep -qE '\bsecret-scan\b' "$SKILLS/gaia-config-tool/SKILL.md"
  grep -qE '\bdep-audit\b' "$SKILLS/gaia-config-tool/SKILL.md"
}

# ───────────────────────── AC2 — /gaia-config-rubric retirement ─────────────────────────

# TC-CFGS7-3
@test "gaia-config-rubric SKILL.md is a deprecation-redirect stub" {
  # Stub must reference both replacement skills.
  grep -qE 'gaia-config-severity' "$SKILLS/gaia-config-rubric/SKILL.md"
  grep -qE 'gaia-config-gates' "$SKILLS/gaia-config-rubric/SKILL.md"
}

@test "gaia-config-rubric SKILL.md mentions DEPRECATED" {
  grep -qE 'DEPRECATED|deprecated|retired|redirect' "$SKILLS/gaia-config-rubric/SKILL.md"
}

# TC-CFGS7-4
@test "gaia-config-rubric retirement rationale names the schema reason" {
  # Per Val F-6: rationale must say schema v2.0.0 has no rubrics top-level property —
  # NOT "validate-rubric already does this".
  grep -qE 'no `?rubrics`? top-level property|no rubrics top-level property' \
    "$SKILLS/gaia-config-rubric/SKILL.md"
  ! grep -qE 'validate-rubric already does this' "$SKILLS/gaia-config-rubric/SKILL.md"
}

# ───────────────────────── AC3 — /gaia-config-severity skill ─────────────────────────

@test "gaia-config-severity SKILL.md exists" {
  [ -f "$SKILLS/gaia-config-severity/SKILL.md" ]
}

@test "gaia-config-severity-edit.sh helper exists and is executable" {
  [ -x "$SEVERITY_EDIT" ]
}

# TC-CFGS7-5
@test "severity edit set Critical BLOCKED writes severity.Critical: BLOCKED" {
  run "$SEVERITY_EDIT" --config "$CFG" set Critical BLOCKED
  [ "$status" -eq 0 ]
  grep -qE '^severity:' "$CFG"
  grep -qE '^[[:space:]]+Critical:[[:space:]]+BLOCKED' "$CFG"
}

# TC-CFGS7-6
@test "severity show prints current map; clear removes the section" {
  "$SEVERITY_EDIT" --config "$CFG" set Critical BLOCKED
  "$SEVERITY_EDIT" --config "$CFG" set High REQUEST_CHANGES
  run "$SEVERITY_EDIT" --config "$CFG" show
  [ "$status" -eq 0 ]
  [[ "$output" == *"Critical"* ]]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"High"* ]]
  run "$SEVERITY_EDIT" --config "$CFG" clear
  [ "$status" -eq 0 ]
  ! grep -qE '^severity:' "$CFG"
}

@test "severity rejects internals outside {Critical, High, Medium, Low, Info}" {
  run "$SEVERITY_EDIT" --config "$CFG" set BOGUS BLOCKED
  [ "$status" -ne 0 ]
}

@test "severity rejects verdicts outside {BLOCKED, REQUEST_CHANGES, APPROVE}" {
  run "$SEVERITY_EDIT" --config "$CFG" set Critical FOO
  [ "$status" -ne 0 ]
}

# ───────────────────────── AC4 — /gaia-config-gates skill ─────────────────────────

@test "gaia-config-gates SKILL.md exists" {
  [ -f "$SKILLS/gaia-config-gates/SKILL.md" ]
}

@test "gaia-config-gates-edit.sh helper exists and is executable" {
  [ -x "$GATES_EDIT" ]
}

# TC-CFGS7-7
@test "gates set <gate> High REQUEST_CHANGES writes gates.<gate>.severity.High" {
  run "$GATES_EDIT" --config "$CFG" set code-review High REQUEST_CHANGES
  [ "$status" -eq 0 ]
  grep -qE '^gates:' "$CFG"
  grep -qE 'code-review:' "$CFG"
  grep -qE 'High:[[:space:]]+REQUEST_CHANGES' "$CFG"
}

# TC-CFGS7-8
@test "gates SKILL.md documents per-gate-over-global fall-through" {
  grep -qE 'per-gate|fall.through|fall-through|global.*severity|absent.*global' \
    "$SKILLS/gaia-config-gates/SKILL.md"
}

@test "gates show <gate> prints the current per-gate map" {
  "$GATES_EDIT" --config "$CFG" set code-review High REQUEST_CHANGES
  run "$GATES_EDIT" --config "$CFG" show code-review
  [ "$status" -eq 0 ]
  [[ "$output" == *"High"* ]]
  [[ "$output" == *"REQUEST_CHANGES"* ]]
}

@test "gates clear <gate> removes that gate's overrides" {
  "$GATES_EDIT" --config "$CFG" set code-review High REQUEST_CHANGES
  "$GATES_EDIT" --config "$CFG" set qa-tests Critical BLOCKED
  run "$GATES_EDIT" --config "$CFG" clear code-review
  [ "$status" -eq 0 ]
  ! grep -qE 'code-review:' "$CFG"
  grep -qE 'qa-tests:' "$CFG"
}

@test "gates rejects internal severity outside the 5-name set" {
  run "$GATES_EDIT" --config "$CFG" set code-review BOGUS BLOCKED
  [ "$status" -ne 0 ]
}

@test "gates rejects verdict outside the 3-name set" {
  run "$GATES_EDIT" --config "$CFG" set code-review High FOO
  [ "$status" -ne 0 ]
}

# ───────────────────────── AC5 — config-yaml-editor.sh insert fail-safe ─────────────────────────

# TC-CFGS7-9
@test "config-yaml-editor.sh insert tool_adapters exits 1 with diagnostic" {
  echo "tool_adapters:" > "$TEST_TMP/new.yaml"
  echo "  foo: bar" >> "$TEST_TMP/new.yaml"
  run --separate-stderr "$EDITOR" insert "$CFG" tool_adapters "$TEST_TMP/new.yaml"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"tool_adapters"* ]]
}

# TC-CFGS7-10
@test "config-yaml-editor.sh insert rubrics exits 1 with diagnostic" {
  echo "rubrics:" > "$TEST_TMP/new.yaml"
  echo "  foo: bar" >> "$TEST_TMP/new.yaml"
  run --separate-stderr "$EDITOR" insert "$CFG" rubrics "$TEST_TMP/new.yaml"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"rubrics"* ]]
}

@test "config-yaml-editor.sh insert tools (declared) succeeds" {
  echo "tools:" > "$TEST_TMP/new.yaml"
  echo "  sast:" >> "$TEST_TMP/new.yaml"
  echo "    provider: semgrep" >> "$TEST_TMP/new.yaml"
  run "$EDITOR" insert "$CFG" tools "$TEST_TMP/new.yaml"
  [ "$status" -eq 0 ]
  grep -qE '^tools:' "$CFG"
}

@test "config-yaml-editor.sh insert severity (declared) succeeds" {
  echo "severity:" > "$TEST_TMP/new.yaml"
  echo "  Critical: BLOCKED" >> "$TEST_TMP/new.yaml"
  run "$EDITOR" insert "$CFG" severity "$TEST_TMP/new.yaml"
  [ "$status" -eq 0 ]
  grep -qE '^severity:' "$CFG"
}

# ───────────────────────── AC6 — stale enumeration ─────────────────────────

# TC-CFGS7-12
@test "gaia-config-tool/SKILL.md no longer enumerates nonexistent rubrics section" {
  # The stale enumeration listed 5 names that have never existed in v2.0.0:
  #   project, regimes, tool_adapters, rubrics, deployment.
  # After reconciliation, the enumeration must not mix these into the canonical list.
  ! grep -qE '`project`.*`stacks`.*`platforms`.*`regimes`' \
    "$SKILLS/gaia-config-tool/SKILL.md"
}

# TC-CFGS7-13
@test "gaia-config-rubric/SKILL.md does not contain the stale 11-section enumeration after stub rewrite" {
  ! grep -qE '`project`.*`stacks`.*`platforms`.*`regimes`' \
    "$SKILLS/gaia-config-rubric/SKILL.md"
}

# ───────────────────────── AC7 — invariant + reverse ─────────────────────────

# TC-CFGS7-11 (invariant)
@test "every /gaia-config-* SKILL.md extract <section> uses a declared schema property" {
  # For each /gaia-config-* SKILL.md, find lines invoking `config-yaml-editor.sh extract <path> <section>`
  # and assert <section> is a declared property of project-config.schema.json.
  local declared
  declared="$(jq -r '.properties | keys[]' "$SCHEMA")"
  local violations=0
  local skill section
  for skill in "$SKILLS"/gaia-config-*/SKILL.md; do
    # Capture every `extract <path> <name>` and `replace <path> <name> <file>` invocation.
    while IFS= read -r section; do
      [ -z "$section" ] && continue
      if ! printf '%s\n' "$declared" | grep -Fxq "$section"; then
        echo "VIOLATION: $skill references section '$section' not in schema" >&2
        violations=$((violations + 1))
      fi
    done < <(
      grep -oE 'config-yaml-editor\.sh[[:space:]]+(extract|replace)[[:space:]]+(<[^>]+>|"\$[A-Z_]+"|[^ ]+)[[:space:]]+([a-z_][a-z0-9_]*)' \
        "$skill" 2>/dev/null \
        | awk '{print $NF}' \
        | sort -u
    )
  done
  [ "$violations" -eq 0 ]
}

# ───────────────────────── E71-S8 (Val F-8) — D2 + D3 regression net ─────────────────────────
#
# E71-S8 extends this invariant test (per AC4 / TC-CFGD-4) so that the same
# bats file guards BOTH the E71-S7 wrong-section-name defect class AND the
# E71-S8 doc-drift defect class. Two new assertions:
#   (a) D2 — no /gaia-config-* SKILL.md contains the stale 11-section
#       enumeration (5 nonexistent names: project, regimes, tool_adapters,
#       rubrics, deployment) as part of a top-level-sections list.
#   (b) D3 — the canonical CRUD-menu LLM-driven disclaimer is present in
#       every /gaia-config-* SKILL.md (uniformity check).

# TC-CFGD-4(a) — D2 regression net
@test "no /gaia-config-* SKILL.md contains the stale 11-section enumeration" {
  local f violations=()
  for f in "$SKILLS"/gaia-config-*/SKILL.md; do
    if grep -qE '`project`,? `stacks`,? `platforms`,? `regimes`' "$f"; then
      violations+=("$f")
    fi
  done
  [ "${#violations[@]}" -eq 0 ] || {
    printf 'STALE 11-SECTION ENUMERATION REINTRODUCED: %s\n' "${violations[@]}" >&2
    return 1
  }
}

# TC-CFGD-4(b) — D3 regression net
@test "canonical CRUD-menu disclaimer present in every /gaia-config-* SKILL.md" {
  local f missing=()
  for f in "$SKILLS"/gaia-config-*/SKILL.md; do
    if ! grep -qF 'LLM-driven interaction pattern under Claude Code main-turn orchestration' "$f"; then
      missing+=("$f")
    fi
  done
  [ "${#missing[@]}" -eq 0 ] || {
    printf 'DISCLAIMER MISSING: %s\n' "${missing[@]}" >&2
    return 1
  }
}
