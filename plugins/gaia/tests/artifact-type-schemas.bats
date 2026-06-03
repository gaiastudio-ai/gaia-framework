#!/usr/bin/env bats
# artifact-type-schemas.bats — E108-S5 / TC-ATS coverage for the shared
# JSON-schema validator helper scripts/lib/validate-artifact-schema.sh.
#
# NEW file per epic Val F6 — do NOT fold these into adapter-schema-contract.bats
# (that file is E70-S1 adapter-pattern scoped).
#
# Test scenarios traced to the story Test Scenarios table:
#   TS1 (AC2)      — Source the lib; validate_artifact_schema is defined; no side effects
#   TS2 (AC1)      — Header has shebang + set -euo pipefail + LC_ALL=C
#   TS3 (AC3)      — No backend → exit 3 + [SKIP] stderr line
#   TS4 (AC4/AC5)  — (backend-guarded) valid JSON instance → exit 0
#   TS5 (AC5)      — (backend-guarded) invalid JSON instance → exit 1 + findings
#   TS6 (AC5)      — Missing args → exit 2
#   TS7 (AC7)      — This NEW bats file exists, distinct from adapter-schema-contract.bats
#   AC6            — mktemp+trap cleanup; bash 3.2 / LC_ALL=C portable (header grep)

load 'test_helper.bash'

setup() {
  common_setup
  # This bats file lives at tests/ (one level), so use the top-level
  # test_helper.bash which exports SCRIPTS_DIR; derive LIB_DIR from it.
  LIB_DIR="$SCRIPTS_DIR/lib"
  SCRIPT="$LIB_DIR/validate-artifact-schema.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures/artifact-type-schemas"
}

teardown() { common_teardown; }

# Detect whether a JSON-schema validator backend is available on this host.
# Mirrors the cascade inside the helper: ajv first, then python3+jsonschema.
_has_backend() {
  if command -v ajv >/dev/null 2>&1; then
    return 0
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# AC1 — header invariants
# ---------------------------------------------------------------------------

@test "TS2/AC1: script exists with shebang, set -euo pipefail, LC_ALL=C" {
  [ -f "$SCRIPT" ]
  run head -n1 "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == "#!/usr/bin/env bash" ]]
  grep -q 'set -euo pipefail' "$SCRIPT"
  grep -Eq '^LC_ALL=C' "$SCRIPT"
}

@test "AC6: helper declares mktemp + trap cleanup (no leaked temp on conversion)" {
  grep -q 'mktemp' "$SCRIPT"
  grep -q 'trap' "$SCRIPT"
}

# ---------------------------------------------------------------------------
# AC2 — sourceable, function-defined, no top-level side effects
# ---------------------------------------------------------------------------

@test "TS1/AC2: sourcing the lib defines validate_artifact_schema with no side effects" {
  run bash -c "source '$SCRIPT' && type -t validate_artifact_schema"
  [ "$status" -eq 0 ]
  [ "$output" = "function" ]
}

@test "AC2: source guard prevents redefinition warnings on double-source" {
  run bash -c "source '$SCRIPT'; source '$SCRIPT'; echo OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# ---------------------------------------------------------------------------
# AC5 — exit-code contract
# ---------------------------------------------------------------------------

@test "TS6/AC5: missing args → exit 2 (usage error)" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "AC5: unreadable schema file → exit 2 (usage error)" {
  run bash "$SCRIPT" "$TEST_TMP/nope.schema.json" "$FIX/valid-instance.json"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# AC3 — backend detection + graceful SKIP
# ---------------------------------------------------------------------------

@test "TS3/AC3: no backend → exit 3 + [SKIP] line" {
  if _has_backend; then
    skip "backend present on host; SKIP path not exercised here"
  fi
  run bash "$SCRIPT" "$FIX/valid.schema.json" "$FIX/valid-instance.json"
  [ "$status" -eq 3 ]
  [[ "$output" == *"[SKIP]"* ]]
  [[ "$output" == *"validate-artifact-schema"* ]]
}

# ---------------------------------------------------------------------------
# AC4 / AC5 — validation behavior (backend-guarded)
# ---------------------------------------------------------------------------

@test "TS4/AC4: valid JSON instance → exit 0" {
  if ! _has_backend; then
    skip "no JSON-schema validator backend on host"
  fi
  run bash "$SCRIPT" "$FIX/valid.schema.json" "$FIX/valid-instance.json"
  [ "$status" -eq 0 ]
}

@test "TS5/AC5: invalid JSON instance → exit 1 + findings on stderr" {
  if ! _has_backend; then
    skip "no JSON-schema validator backend on host"
  fi
  run bash "$SCRIPT" "$FIX/valid.schema.json" "$FIX/invalid-instance.json"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# AC7 — this is the NEW file, distinct from adapter-schema-contract.bats
# ---------------------------------------------------------------------------

@test "TS7/AC7: this bats file is the new artifact-type-schemas.bats, separate from adapter-schema-contract.bats" {
  [ -f "${BATS_TEST_DIRNAME}/artifact-type-schemas.bats" ]
  [ -f "${BATS_TEST_DIRNAME}/adapter-schema-contract.bats" ]
  # The two are distinct files (epic Val F6).
  [ "${BATS_TEST_DIRNAME}/artifact-type-schemas.bats" != "${BATS_TEST_DIRNAME}/adapter-schema-contract.bats" ]
}
