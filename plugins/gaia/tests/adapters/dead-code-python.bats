#!/usr/bin/env bats
# dead-code-python.bats — E70-S8 Python vulture adapter.
#
# Story: E70-S8. FR-545 / NFR-87 / ADR-078.
#
# adapter.sh wraps `vulture --min-confidence 80 <root>`, parses the
# `<file>:<line>: unused <kind> '<symbol>' (<confidence>% confidence)` output
# with a robust regex (NOT awk -F: — paths may contain colons), and emits:
#   - flat JSON to <out>/dead-code/python-vulture.json (AC2/AC4)
#   - SARIF to <out>/sarif/python-vulture.sarif (.properties.symbol, dedup ladder)
# qualifier = "<line>:<symbol>@<confidence>".
# Findings below the 80% threshold are NOT emitted (vulture filters them).
#
# Test seams:
#   PY_PROJECT_ROOT     repo to scan
#   PY_OUT_DIR          output root
#   PY_VULTURE_FIXTURE  pre-captured vulture stdout the shim emits

load '../test_helper.bash'

setup() {
  common_setup
  ADAPTER="$(cd "$BATS_TEST_DIRNAME/../../scripts/adapters/dead-code/python-vulture" && pwd 2>/dev/null || echo "$BATS_TEST_DIRNAME/../../scripts/adapters/dead-code/python-vulture")/adapter.sh"
  FX="$BATS_TEST_DIRNAME/../fixtures/dead-code-python"
  export ADAPTER FX
  FAKE_BIN="$TEST_TMP/bin"; mkdir -p "$FAKE_BIN"; export FAKE_BIN
  OUT="$TEST_TMP/audit"; mkdir -p "$OUT"; export OUT
  cat > "$FAKE_BIN/vulture" <<EOF
#!/usr/bin/env bash
cat "$FX/vulture-output.txt"
EOF
  chmod +x "$FAKE_BIN/vulture"
}
teardown() { common_teardown; }

run_adapter() {
  PATH="$FAKE_BIN:$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_DEADCODE_PYTHON_ENABLED=true \
    PY_PROJECT_ROOT="$FX" PY_OUT_DIR="$OUT" PY_VULTURE_FIXTURE="$FX/vulture-output.txt" run bash "$ADAPTER"
}

# --- AC2 / scenario 2 — only ≥80% surfaces; qualifier <line>:<sym>@<conf> -----
@test "E70-S8 python (scenario 2): 95% dead symbol → JSON file_path + qualifier <line>:<sym>@95" {
  run_adapter
  [ "$status" -eq 0 ]
  [ -f "$OUT/dead-code/python-vulture.json" ]
  run jq 'length' "$OUT/dead-code/python-vulture.json"
  [ "$output" = "1" ]   # the 70% symbol was filtered by vulture's threshold
  run jq -r '.[0].file_path' "$OUT/dead-code/python-vulture.json"
  [ "$output" = "app.py" ]
  run jq -r '.[0].qualifier' "$OUT/dead-code/python-vulture.json"
  [ "$output" = "5:unused_high@95" ]
  run jq -r '.[0].source_tool' "$OUT/dead-code/python-vulture.json"
  [ "$output" = "python-vulture" ]
}

# --- Val F1 fix — SARIF emission ---------------------------------------------
@test "E70-S8 python: emits SARIF with qualifier in .properties.symbol" {
  run_adapter
  [ "$status" -eq 0 ]
  [ -f "$OUT/sarif/python-vulture.sarif" ]
  run jq -r '.runs[0].results[0].properties.symbol' "$OUT/sarif/python-vulture.sarif"
  [ "$output" = "5:unused_high@95" ]
  run jq -r '.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri' "$OUT/sarif/python-vulture.sarif"
  [ "$output" = "app.py" ]
}

# --- AC5 / scenario 5 — vulture absent → graceful degrade --------------------
@test "E70-S8 python (scenario 5): vulture absent → WARNING + exit 0" {
  rm -f "$FAKE_BIN/vulture"
  # Empty system PATH (FAKE_BIN only) so `command -v vulture` genuinely fails
  # regardless of what the runner has installed; absolute /bin/bash because an
  # empty PATH cannot resolve `bash`. The absence branch exits before any other
  # tool is needed.
  run env PATH="$FAKE_BIN" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_DEADCODE_PYTHON_ENABLED=true \
    PY_PROJECT_ROOT="$FX" PY_OUT_DIR="$OUT" /bin/bash "$ADAPTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"vulture"* ]]
}

@test "python adapter degrade emits a language-aware install hint" {
  rm -f "$FAKE_BIN/vulture"
  run env PATH="$FAKE_BIN" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_DEADCODE_PYTHON_ENABLED=true \
    PY_PROJECT_ROOT="$FX" PY_OUT_DIR="$OUT" /bin/bash "$ADAPTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pip install vulture"* ]]
}

# --- AC5 — no *.py files → no-op ---------------------------------------------
@test "E70-S8 python: no .py files → idempotent no-op, exit 0" {
  emptyroot="$TEST_TMP/empty"; mkdir -p "$emptyroot"
  PATH="$FAKE_BIN:$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_DEADCODE_PYTHON_ENABLED=true \
    PY_PROJECT_ROOT="$emptyroot" PY_OUT_DIR="$OUT" run bash "$ADAPTER"
  [ "$status" -eq 0 ]
  [ ! -f "$OUT/dead-code/python-vulture.json" ] || [ "$(jq 'length' "$OUT/dead-code/python-vulture.json")" = "0" ]
}

# --- AC-X1 / scenario 6 — per-tool flag-off ----------------------------------
@test "E70-S8 python (scenario 6): deadcode_python_enabled=false → skip" {
  PATH="$FAKE_BIN:$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_DEADCODE_PYTHON_ENABLED=false \
    PY_PROJECT_ROOT="$FX" PY_OUT_DIR="$OUT" run bash "$ADAPTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]] || [[ "$output" == *"INFO"* ]]
  [ ! -f "$OUT/dead-code/python-vulture.json" ]
}

# --- Hygiene -----------------------------------------------------------------
@test "E70-S8 python: adapter.sh + adapter.json exist; bash -n clean" {
  [ -x "$ADAPTER" ]
  [ -f "$(dirname "$ADAPTER")/adapter.json" ]
  run bash -n "$ADAPTER"
  [ "$status" -eq 0 ]
  run jq -e '.provider' "$(dirname "$ADAPTER")/adapter.json"
  [ "$status" -eq 0 ]
}
