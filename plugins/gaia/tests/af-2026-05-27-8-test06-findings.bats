#!/usr/bin/env bats
# AF-2026-05-27-8: Test06 findings — artifact-path resolution class (3rd
# recurrence), heading_present centralization, create-arch lifecycle gate, and
# three misc finalize fixes.
#
# Path class (the user's stated priority):
#   F-007 gaia-create-epics setup.sh resolved test-plan via dead ${PLANNING_ARTIFACTS}
#   F-008 gaia-create-epics finalize.sh TEST_PLAN precedence omitted planning-artifacts/
#   F-011 gaia-readiness-check setup.sh trace re-probe omitted planning-artifacts/
#   F-014 sprint-state.sh init wrote impl-artifacts; dashboard read .gaia/state/ only
#   → all routed through the new shared scripts/lib/resolve-artifact-path.sh
# heading class:
#   F-001 PRD heading_present rejected letter-suffix numbering (11b)
#   F-004 UX SV-06 checked "Wireframes", failed on "Wireframe Descriptions"
#   F-009 17 divergent heading_present copies → one shared scripts/lib/heading-present.sh
# lifecycle:
#   F-005/F-006 create-arch threat-model gate hard-blocked greenfield UI in Phase 3
# misc:
#   F-010 ci-setup finalize silently skipped checklist when CI_SETUP_ARTIFACT unset
#   F-012 create-story generate-frontmatter defaulted delivered: true on a backlog story
#   F-013 dod-check build/lint resolved PATH-only while tests used a richer resolver

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RESOLVER="$PLUGIN_ROOT/scripts/lib/resolve-artifact-path.sh"
  HEADING_LIB="$PLUGIN_ROOT/scripts/lib/heading-present.sh"
}

teardown() { common_teardown; }

# ===========================================================================
# Shared resolver — scripts/lib/resolve-artifact-path.sh
# ===========================================================================

@test "AF-27-8 F-008: resolver puts .gaia/artifacts/planning-artifacts/ at rung 1 for test_plan" {
  [ -x "$RESOLVER" ]
  run "$RESOLVER" test_plan --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/.gaia/artifacts/planning-artifacts/test-plan.md" ]]
}

@test "AF-27-8 F-007/F-008: test-strategy.md under planning-artifacts resolves for test_plan" {
  mkdir -p "$TEST_TMP/.gaia/artifacts/planning-artifacts"
  printf '# strategy\nbody\n' > "$TEST_TMP/.gaia/artifacts/planning-artifacts/test-strategy.md"
  run "$RESOLVER" test_plan --project-root "$TEST_TMP" --existing-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"/.gaia/artifacts/planning-artifacts/test-strategy.md" ]]
}

@test "AF-27-8 F-011: traceability resolves planning-artifacts canonical first" {
  mkdir -p "$TEST_TMP/.gaia/artifacts/planning-artifacts"
  printf '# trace\n| FR | t |\n' > "$TEST_TMP/.gaia/artifacts/planning-artifacts/traceability-matrix.md"
  run "$RESOLVER" traceability --project-root "$TEST_TMP" --existing-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"/.gaia/artifacts/planning-artifacts/traceability-matrix.md" ]]
}

@test "AF-27-8: --existing-only exits 1 with no stdout when nothing exists" {
  run "$RESOLVER" test_plan --project-root "$TEST_TMP" --existing-only
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "AF-27-8: print-mode returns canonical rung-1 path when nothing exists" {
  run "$RESOLVER" traceability --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/.gaia/artifacts/planning-artifacts/traceability-matrix.md" ]]
}

@test "AF-27-8 F-014: sprint_status canonical rung is .gaia/state/" {
  run "$RESOLVER" sprint_status --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/.gaia/state/sprint-status.yaml" ]]
}

@test "AF-27-8 F-014: sprint_status read-compat finds impl-artifacts copy" {
  mkdir -p "$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  printf 'sprint_id: s1\n' > "$TEST_TMP/.gaia/artifacts/implementation-artifacts/sprint-status.yaml"
  run "$RESOLVER" sprint_status --project-root "$TEST_TMP" --existing-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"/.gaia/artifacts/implementation-artifacts/sprint-status.yaml" ]]
}

@test "AF-27-8: unknown kind exits non-zero" {
  run "$RESOLVER" bogus --project-root "$TEST_TMP"
  [ "$status" -ne 0 ]
}

@test "AF-27-8: project root resolves via PROJECT_ROOT/GAIA_PROJECT_ROOT env (cluster-6 fixture pattern)" {
  # The cluster-6 e2e fixture runs from the repo root while exporting
  # PROJECT_ROOT/GAIA_PROJECT_ROOT to a temp workspace + seeding the test-plan
  # under that workspace's legacy docs/test-artifacts/. The resolver must honor
  # those env-vars (not just CLAUDE_PROJECT_ROOT/PWD) and find the legacy rung.
  mkdir -p "$TEST_TMP/docs/test-artifacts"
  printf '# tp\nbody\n' > "$TEST_TMP/docs/test-artifacts/test-plan.md"
  run env -u CLAUDE_PROJECT_ROOT PROJECT_ROOT="$TEST_TMP" GAIA_PROJECT_ROOT="$TEST_TMP" \
    bash -c "cd / && '$RESOLVER' test_plan --existing-only"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$TEST_TMP/docs/test-artifacts/test-plan.md" ]]
}

# ===========================================================================
# F-014: sprint-state.sh init writes .gaia/state/; dashboard reads it
# ===========================================================================

@test "AF-27-8 F-014: sprint-state.sh init seeds .gaia/state/sprint-status.yaml on a fresh project" {
  run env PROJECT_PATH="$TEST_TMP" bash "$PLUGIN_ROOT/scripts/sprint-state.sh" init --sprint-id sprint-1
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/.gaia/state/sprint-status.yaml" ]
  # AF-2026-05-31-3 / Test14 F-16: sprint-state.sh mirrors the canonical yaml
  # to implementation-artifacts/sprint-status.yaml ONLY when the target dir
  # ALREADY EXISTS (the mirror is non-creating to avoid shadowing legacy
  # fixtures). On a fresh project the dir doesn't exist yet, so the mirror
  # cleanly no-ops here. The F-16 mirror has its own dedicated coverage in
  # af-2026-05-31-3-test14-findings.bats that creates the dir first.
  [ ! -f "$TEST_TMP/.gaia/artifacts/implementation-artifacts/sprint-status.yaml" ]
}

@test "AF-27-8 F-014: dashboard reads what init seeded (no 'not found' error)" {
  env PROJECT_PATH="$TEST_TMP" bash "$PLUGIN_ROOT/scripts/sprint-state.sh" init --sprint-id sprint-1 >/dev/null 2>&1
  run env PROJECT_PATH="$TEST_TMP" bash "$PLUGIN_ROOT/scripts/sprint-status-dashboard.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-1"* ]]
  [[ "$output" != *"not found"* ]]
}

@test "AF-27-8 F-014: dashboard read-compat finds a project seeded at impl-artifacts" {
  mkdir -p "$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  printf 'sprint_id: "s9"\nstatus: active\ntotal_points: 5\ngoals: []\nitems: []\n' \
    > "$TEST_TMP/.gaia/artifacts/implementation-artifacts/sprint-status.yaml"
  run env PROJECT_PATH="$TEST_TMP" bash "$PLUGIN_ROOT/scripts/sprint-status-dashboard.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"s9"* ]]
}

@test "AF-27-8 F-014: dev-story sprint-state.sh wrapper stays byte-identical to canonical" {
  run diff "$PLUGIN_ROOT/scripts/sprint-state.sh" "$PLUGIN_ROOT/skills/gaia-dev-story/scripts/sprint-state.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# heading_present — scripts/lib/heading-present.sh (F-001/F-004/F-009)
# ===========================================================================

_mk_doc() {
  cat > "$TEST_TMP/doc.md" <<'EOF'
## 11. Technical Constraints
## 11b. Constraints and Assumptions
## 10. Review Findings Incorporated
## 5. Wireframe Descriptions
## Wireframes
## Constraints
## 1.2.3 Deep Section
## Personas
EOF
}

@test "AF-27-8 F-001: heading_present accepts letter-suffix numbering (11b)" {
  _mk_doc
  ( . "$HEADING_LIB"; [ "$(heading_present "$TEST_TMP/doc.md" "Constraints")" = "pass" ] )
}

@test "AF-27-8 F-009: '## 10. Review Findings Incorporated' passes the shared check" {
  _mk_doc
  ( . "$HEADING_LIB"; [ "$(heading_present "$TEST_TMP/doc.md" "Review Findings Incorporated")" = "pass" ] )
}

@test "AF-27-8 F-004: 'Wireframe' stem matches '## 5. Wireframe Descriptions' AND '## Wireframes'" {
  _mk_doc
  ( . "$HEADING_LIB"; [ "$(heading_present "$TEST_TMP/doc.md" "Wireframe")" = "pass" ] )
}

@test "AF-27-8: dotted outline prefix (1.2.3) is accepted" {
  _mk_doc
  ( . "$HEADING_LIB"; [ "$(heading_present "$TEST_TMP/doc.md" "Deep Section")" = "pass" ] )
}

@test "AF-27-8: absent section returns fail" {
  _mk_doc
  ( . "$HEADING_LIB"; [ "$(heading_present "$TEST_TMP/doc.md" "Glossary")" = "fail" ] )
}

@test "AF-27-8: a non-H2 inline occurrence does NOT match" {
  printf 'some Constraints inline text\n' > "$TEST_TMP/inline.md"
  ( . "$HEADING_LIB"; [ "$(heading_present "$TEST_TMP/inline.md" "Constraints")" = "fail" ] )
}

@test "AF-27-8 F-009: all skill finalize.sh source the shared heading lib (no inline copies remain)" {
  # Every finalize.sh that previously defined heading_present() must now source
  # the shared lib (it may keep a byte-equivalent inline fallback, but it MUST
  # reference the shared lib path).
  local n=0
  while IFS= read -r f; do
    grep -qF 'scripts/lib/heading-present.sh' "$f"
    n=$((n+1))
  done < <(grep -rl 'heading_present' "$PLUGIN_ROOT"/skills/*/scripts/finalize.sh)
  [ "$n" -ge 17 ]
}

@test "AF-27-8 F-004: create-ux SV-06 call site uses the 'Wireframe' stem" {
  grep -qF 'heading_present "$ARTIFACT" "Wireframe"' "$PLUGIN_ROOT/skills/gaia-create-ux/scripts/finalize.sh"
}

# ===========================================================================
# F-005/F-006: create-arch threat-model gate — pre-sprint WARN, active-sprint DIE
# ===========================================================================
# The gate's decision block is exercised in isolation (the full setup.sh has an
# upstream resolve-config dependency that needs a fully-hydrated config).

_run_gate() {
  # $1 ui_present, $2 sprint? (non-empty => active sprint), $3 GAIA_STRICT_LIFECYCLE
  local gh="$TEST_TMP/gate.sh"
  {
    echo 'set -uo pipefail'
    echo 'SCRIPT_NAME="gaia-create-arch/setup.sh"'
    echo 'log() { printf "%s: %s\n" "$SCRIPT_NAME" "$*" >&2; }'
    echo 'die() { log "$*"; exit 1; }'
    echo "STRICT_HELPER_S6=\"$PLUGIN_ROOT/scripts/lib/lifecycle-strict-mode.sh\""
    echo "LIFECYCLE_LIB_S6=\"$PLUGIN_ROOT/scripts/lib/lifecycle-overrides.sh\""
    echo 'ui_present="${UI_PRESENT:-false}"'
    sed -n '/if \[ "\$ui_present" != "true" \]; then/,/^fi$/p' "$PLUGIN_ROOT/skills/gaia-create-arch/scripts/setup.sh"
    echo 'log "gate-ok"; exit 0'
  } > "$gh"
  local proj="$TEST_TMP/proj"; rm -rf "$proj"; mkdir -p "$proj"
  if [ -n "$2" ]; then
    mkdir -p "$proj/.gaia/state"
    printf 'sprint_id: "sprint-1"\nstatus: active\n' > "$proj/.gaia/state/sprint-status.yaml"
  fi
  ( cd "$proj" && UI_PRESENT="$1" GAIA_ARTIFACTS_DIR="$proj/.gaia/artifacts" GAIA_STRICT_LIFECYCLE="$3" bash "$gh" )
}

@test "AF-27-8: gate is a no-op when ui_present is false" {
  run _run_gate false "" 1
  [ "$status" -eq 0 ]
}

@test "AF-27-8 F-005: greenfield UI in Phase 3 (no sprint) WARNs and proceeds (exit 0)" {
  run _run_gate true "" 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"no active sprint exists yet"* ]]
}

@test "AF-27-8 F-005: active sprint + strict + no threat-model still HALTs (exit 1)" {
  run _run_gate true yes 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"no threat-model.md found"* ]]
}

# ===========================================================================
# F-010 / F-012 / F-013 — misc
# ===========================================================================

@test "AF-27-8 F-010: ci-setup finalize runs the checklist when CI_SETUP_ARTIFACT is unset" {
  mkdir -p "$TEST_TMP/.gaia/artifacts/test-artifacts"
  printf '# CI Setup\n## Pipeline\nbody\n' > "$TEST_TMP/.gaia/artifacts/test-artifacts/ci-setup.md"
  run env -u CI_SETUP_ARTIFACT CLAUDE_PROJECT_ROOT="$TEST_TMP" \
    bash -c "cd '$TEST_TMP' && bash '$PLUGIN_ROOT/skills/gaia-ci-setup/scripts/finalize.sh'"
  [[ "$output" == *"defaulting to resolved artifact"* ]]
  [[ "$output" != *"skipping checklist run"* ]]
}

@test "AF-27-8 F-012: generate-frontmatter defaults delivered: false (not true)" {
  grep -qF 'delivered: false' "$PLUGIN_ROOT/skills/gaia-create-story/scripts/generate-frontmatter.sh"
  ! grep -qE '^delivered: true' "$PLUGIN_ROOT/skills/gaia-create-story/scripts/generate-frontmatter.sh"
}

@test "AF-27-8 F-013: dod-check build/lint route through _check_script (npm scripts parity)" {
  grep -qF '_check_script "build" "build"' "$PLUGIN_ROOT/skills/gaia-dev-story/scripts/dod-check.sh"
  grep -qF '_check_script "lint"  "lint"' "$PLUGIN_ROOT/skills/gaia-dev-story/scripts/dod-check.sh"
  grep -qF '_resolve_script_cmd' "$PLUGIN_ROOT/skills/gaia-dev-story/scripts/dod-check.sh"
}
