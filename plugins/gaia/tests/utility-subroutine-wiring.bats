#!/usr/bin/env bats
# utility-subroutine-wiring.bats — E69-S4 utility-review sub-routine wiring
#
# Tests the deterministic sub-routine helpers that wire `/gaia-review-deps`
# into `/gaia-review-security` Phase 3A (dep-audit-subroutine.sh) and
# `/gaia-review-api` into `/gaia-review-code` Phase 3A (api-design-subroutine.sh).
#
# Coverage:
#   - AC1   dep-audit invoked when dependency manifests present
#   - AC2   api-design invoked when API endpoints detected
#   - AC3   conditional skip with diagnostic note (no manifests / no endpoints)
#   - AC-EC1 sub-routine failure does not cascade (WARNING-only)
#   - AC4   evidence merging: emits `analysis-results.json`-shaped checks[] fragment
#
# Refs: E69-S4, source-report §2.2 + §5.4 + §15 Phase 4 items 20-21,
#       FR-RSV2-23, ADR-077, ADR-082.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  DEP_SUB="$SCRIPTS_DIR/review-common/security/dep-audit-subroutine.sh"
  API_SUB="$SCRIPTS_DIR/review-common/code/api-design-subroutine.sh"
}
teardown() { common_teardown; }

# ---------- AC1: dep-audit-subroutine invoked when manifests present ----------

@test "dep-audit invoked when package.json present -> emits checks fragment" {
  mkdir -p "$TEST_TMP/proj"
  printf '{"name":"x","version":"0.0.1","dependencies":{}}\n' > "$TEST_TMP/proj/package.json"
  run --separate-stderr "$DEP_SUB" --target "$TEST_TMP/proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"name":"dependency-audit"'* ]]
  [[ "$output" == *'"category":"dependency_audit"'* ]]
}

@test "dep-audit invoked for requirements.txt" {
  mkdir -p "$TEST_TMP/proj"
  printf 'requests==2.0.0\n' > "$TEST_TMP/proj/requirements.txt"
  run --separate-stderr "$DEP_SUB" --target "$TEST_TMP/proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"name":"dependency-audit"'* ]]
}

@test "dep-audit invoked for pom.xml / pubspec.yaml / go.mod / Gemfile / Cargo.toml" {
  for manifest in pom.xml pubspec.yaml go.mod Gemfile Cargo.toml; do
    rm -rf "$TEST_TMP/m"
    mkdir -p "$TEST_TMP/m"
    : > "$TEST_TMP/m/$manifest"
    run --separate-stderr "$DEP_SUB" --target "$TEST_TMP/m"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"name":"dependency-audit"'* ]] || \
      { echo "manifest $manifest did not trigger dep-audit"; return 1; }
  done
}

# ---------- AC3: dep-audit skipped when no manifests ----------

@test "dep-audit skipped when no manifests -> emits skipped status with reason" {
  mkdir -p "$TEST_TMP/proj"
  printf 'hello\n' > "$TEST_TMP/proj/README.md"
  run --separate-stderr "$DEP_SUB" --target "$TEST_TMP/proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"skipped"'* ]]
  [[ "$output" == *"No dependency manifests found"* ]]
}

# ---------- AC2: api-design-subroutine invoked when endpoints detected ----------

@test "api-design invoked when routes/ directory present -> emits checks fragment" {
  mkdir -p "$TEST_TMP/proj/routes"
  printf 'router.get("/users", h);\n' > "$TEST_TMP/proj/routes/users.ts"
  run --separate-stderr "$API_SUB" --target "$TEST_TMP/proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"name":"api-design-audit"'* ]]
  [[ "$output" == *'"category":"api_design_audit"'* ]]
}

@test "api-design invoked when controllers/ directory present" {
  mkdir -p "$TEST_TMP/proj/src/controllers"
  : > "$TEST_TMP/proj/src/controllers/users_controller.py"
  run --separate-stderr "$API_SUB" --target "$TEST_TMP/proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"name":"api-design-audit"'* ]]
}

@test "api-design invoked when openapi.yaml present" {
  mkdir -p "$TEST_TMP/proj"
  : > "$TEST_TMP/proj/openapi.yaml"
  run --separate-stderr "$API_SUB" --target "$TEST_TMP/proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"name":"api-design-audit"'* ]]
}

# ---------- AC3: api-design skipped when no endpoints ----------

@test "api-design skipped when no endpoints -> emits skipped status with reason" {
  mkdir -p "$TEST_TMP/proj"
  : > "$TEST_TMP/proj/README.md"
  run --separate-stderr "$API_SUB" --target "$TEST_TMP/proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"skipped"'* ]]
  [[ "$output" == *"No API endpoints detected"* ]]
}

# ---------- AC-EC1: sub-routine failure does not cascade as parent BLOCKED ----------

@test "dep-audit reports failure as WARNING when audit tool errors" {
  mkdir -p "$TEST_TMP/proj"
  : > "$TEST_TMP/proj/package.json"
  # Force a simulated audit-tool failure via env override; the subroutine MUST
  # capture this as a warning-severity finding (not BLOCKED) and exit 0.
  GAIA_DEP_AUDIT_FORCE_FAIL=1 run --separate-stderr "$DEP_SUB" --target "$TEST_TMP/proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"severity":"warning"'* ]]
  [[ "$output" == *"Dependency audit unavailable"* ]]
}

@test "api-design reports failure as WARNING on tool error" {
  mkdir -p "$TEST_TMP/proj"
  : > "$TEST_TMP/proj/openapi.yaml"
  GAIA_API_AUDIT_FORCE_FAIL=1 run --separate-stderr "$API_SUB" --target "$TEST_TMP/proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"severity":"warning"'* ]]
  [[ "$output" == *"API design audit unavailable"* ]]
}

# ---------- usage ----------

@test "usage: dep-audit --help exits 0" {
  run --separate-stderr "$DEP_SUB" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"dep-audit-subroutine"* ]]
}

@test "usage: api-design --help exits 0" {
  run --separate-stderr "$API_SUB" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"api-design-subroutine"* ]]
}

@test "usage: dep-audit missing --target exits 1" {
  run --separate-stderr "$DEP_SUB"
  [ "$status" -eq 1 ]
}

@test "usage: api-design missing --target exits 1" {
  run --separate-stderr "$API_SUB"
  [ "$status" -eq 1 ]
}

# ---------- determinism ----------

@test "determinism: dep-audit byte-identical output on identical input" {
  mkdir -p "$TEST_TMP/proj"
  : > "$TEST_TMP/proj/package.json"
  local h1 h2
  h1="$("$DEP_SUB" --target "$TEST_TMP/proj" 2>/dev/null | shasum -a 256 | awk '{print $1}')"
  h2="$("$DEP_SUB" --target "$TEST_TMP/proj" 2>/dev/null | shasum -a 256 | awk '{print $1}')"
  [ "$h1" = "$h2" ]
}
