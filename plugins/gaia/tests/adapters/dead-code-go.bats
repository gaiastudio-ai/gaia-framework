#!/usr/bin/env bats
# dead-code-go.bats — E70-S8 Go deadcode adapter.
#
# Story: E70-S8. FR-545 / NFR-87 / ADR-078 (master flag + per-tool override).
#
# adapter.sh wraps `golang.org/x/tools/cmd/deadcode` (Rapid Type Analysis whole-
# program reachability — binary verdict, zero false positives by construction).
# It normalizes deadcode's Position.Filename to a repo-root-relative file_path
# (the universal cross-stack JOIN key) and emits:
#   - flat normalized JSON to <out>/dead-code/go-deadcode.json (report-rendering, AC1/AC4)
#   - a SARIF run to <out>/sarif/go-deadcode.sarif with qualifier in
#     .properties.symbol (the E104-S1 dedup precision ladder, Val F1 fix)
# qualifier = "<package>.<Function>".
#
# Offline + deterministic: a fake `deadcode` shim emits the fixture's captured
# `deadcode -json ./...` output; `go` is stubbed (so `command -v go` succeeds
# and the *.go gate passes) but never actually compiles.
#
# Test seams:
#   DEADCODE_PROJECT_ROOT  repo to scan (default .)
#   DEADCODE_OUT_DIR       output root for dead-code/ + sarif/ (default .gaia/memory/brownfield-audit)
#   DEADCODE_JSON_FIXTURE  pre-captured `deadcode -json` output the shim emits

load '../test_helper.bash'

setup() {
  common_setup
  ADAPTER="$(cd "$BATS_TEST_DIRNAME/../../scripts/adapters/dead-code/go-deadcode" && pwd 2>/dev/null || echo "$BATS_TEST_DIRNAME/../../scripts/adapters/dead-code/go-deadcode")/adapter.sh"
  FX="$BATS_TEST_DIRNAME/../fixtures/dead-code-go"
  export ADAPTER FX
  FAKE_BIN="$TEST_TMP/bin"; mkdir -p "$FAKE_BIN"; export FAKE_BIN
  OUT="$TEST_TMP/audit"; mkdir -p "$OUT"; export OUT
  # Stub `deadcode` (emits captured JSON) + `go` (list/version no-op).
  cat > "$FAKE_BIN/deadcode" <<EOF
#!/usr/bin/env bash
cat "$FX/deadcode-output.json"
EOF
  cat > "$FAKE_BIN/go" <<'EOF'
#!/usr/bin/env bash
# `go list -json ./...` not needed by the test (the shim returns posn relative
# to root already); `go version` succeeds so command -v go is true.
exit 0
EOF
  chmod +x "$FAKE_BIN/deadcode" "$FAKE_BIN/go"
}
teardown() { common_teardown; }

run_adapter() {
  PATH="$FAKE_BIN:$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_DEADCODE_GO_ENABLED=true \
    DEADCODE_PROJECT_ROOT="$FX" DEADCODE_OUT_DIR="$OUT" \
    DEADCODE_JSON_FIXTURE="$FX/deadcode-output.json" run bash "$ADAPTER"
}

# --- AC1 / scenario 1 — emits normalized JSON with file_path + qualifier -----
@test "E70-S8 go (scenario 1): dead function → JSON file_path JOIN key + qualifier <pkg>.<Func>" {
  run_adapter
  [ "$status" -eq 0 ]
  [ -f "$OUT/dead-code/go-deadcode.json" ]
  run jq -r '.[0].file_path' "$OUT/dead-code/go-deadcode.json"
  [ "$output" = "unused_pkg/lib.go" ]
  run jq -r '.[0].qualifier' "$OUT/dead-code/go-deadcode.json"
  [ "$output" = "unused_pkg.UnusedFunc" ]
  run jq -r '.[0].source_tool' "$OUT/dead-code/go-deadcode.json"
  [ "$output" = "go-deadcode" ]
  run jq -r '.[0].severity' "$OUT/dead-code/go-deadcode.json"
  [ "$output" = "warning" ]
}

# --- Val F1 fix — also emits SARIF into sarif/ so dedup ladder applies --------
@test "E70-S8 go: emits SARIF with qualifier in .properties.symbol (dedup ladder JOIN)" {
  run_adapter
  [ "$status" -eq 0 ]
  [ -f "$OUT/sarif/go-deadcode.sarif" ]
  run jq -r '.runs[0].results[0].properties.symbol' "$OUT/sarif/go-deadcode.sarif"
  [ "$output" = "unused_pkg.UnusedFunc" ]
  run jq -r '.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri' "$OUT/sarif/go-deadcode.sarif"
  [ "$output" = "unused_pkg/lib.go" ]
  run jq -r '.runs[0].tool.driver.name' "$OUT/sarif/go-deadcode.sarif"
  [ "$output" = "go-deadcode" ]
}

# --- AC5 / scenario 5 — graceful degrade: go absent --------------------------
@test "E70-S8 go (scenario 5): go binary absent → WARNING + exit 0 (no findings)" {
  # Simulate `go` genuinely absent. PATH must NOT include /usr/bin:/bin — CI
  # runners ship a real `go` there (or via setup-go), so a system-PATH suffix
  # would let `command -v go` succeed and the degrade-WARNING would never fire
  # (a CI-only false failure). The adapter's go-absence branch exits before it
  # needs any other tool, so an empty system PATH (FAKE_BIN only, with go
  # removed) is sufficient and is the portable absent-tool idiom.
  rm -f "$FAKE_BIN/go"
  # Empty system PATH (FAKE_BIN only, go removed) so `command -v go` genuinely
  # fails. Invoke via absolute /bin/bash because an empty PATH cannot resolve
  # `bash` itself. The go-absence branch exits before needing any other tool.
  run env PATH="$FAKE_BIN" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_DEADCODE_GO_ENABLED=true \
    DEADCODE_PROJECT_ROOT="$FX" DEADCODE_OUT_DIR="$OUT" /bin/bash "$ADAPTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"go"* ]]
}

# --- AC5 — graceful degrade: no *.go files -----------------------------------
@test "E70-S8 go: no .go files in project root → idempotent no-op, exit 0" {
  emptyroot="$TEST_TMP/empty"; mkdir -p "$emptyroot"
  PATH="$FAKE_BIN:$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_DEADCODE_GO_ENABLED=true \
    DEADCODE_PROJECT_ROOT="$emptyroot" DEADCODE_OUT_DIR="$OUT" run bash "$ADAPTER"
  [ "$status" -eq 0 ]
  [ ! -f "$OUT/dead-code/go-deadcode.json" ] || [ "$(jq 'length' "$OUT/dead-code/go-deadcode.json")" = "0" ]
}

# --- AC-X1 / scenario 6 — per-tool flag-off skip -----------------------------
@test "E70-S8 go (scenario 6): brownfield.deadcode_go_enabled=false → INFO skip, not invoked" {
  PATH="$FAKE_BIN:$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_DEADCODE_GO_ENABLED=false \
    DEADCODE_PROJECT_ROOT="$FX" DEADCODE_OUT_DIR="$OUT" run bash "$ADAPTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]] || [[ "$output" == *"INFO"* ]]
  [ ! -f "$OUT/dead-code/go-deadcode.json" ]
}

# --- AC-X1 / scenario 7 — master flag off ------------------------------------
@test "E70-S8 go (scenario 7): master flag off → skipped regardless of per-tool" {
  PATH="$FAKE_BIN:$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=false GAIA_BROWNFIELD_DEADCODE_GO_ENABLED=true \
    DEADCODE_PROJECT_ROOT="$FX" DEADCODE_OUT_DIR="$OUT" run bash "$ADAPTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]] || [[ "$output" == *"INFO"* ]]
  [ ! -f "$OUT/dead-code/go-deadcode.json" ]
}

# --- AC5/AC-X1 — resolve-config exposes the three per-tool flags -------------
@test "E70-S8 go: resolve-config.sh --field brownfield.deadcode_{go,python,jvm}_enabled whitelisted" {
  cat > "$TEST_TMP/project-config.yaml" <<YAML
project_root: /tmp/gaia
project_path: /tmp/gaia/app
memory_path: /tmp/gaia/.gaia/memory
checkpoint_path: /tmp/gaia/.gaia/memory/checkpoints
installed_path: /tmp/gaia/_gaia
framework_version: 1.176.0
date: 2026-05-25
brownfield:
  deterministic_tools: true
  deadcode_go_enabled: true
  deadcode_python_enabled: false
  deadcode_jvm_enabled: true
YAML
  cp "$(cd "$BATS_TEST_DIRNAME/../../config" && pwd)/project-config.schema.yaml" "$TEST_TMP/schema.yaml"
  RC="$(cd "$BATS_TEST_DIRNAME/../../scripts" && pwd)/resolve-config.sh"
  run bash "$RC" --shared "$TEST_TMP/project-config.yaml" --schema "$TEST_TMP/schema.yaml" --field brownfield.deadcode_go_enabled
  [ "$status" -eq 0 ]; [ "$output" = "true" ]
  run bash "$RC" --shared "$TEST_TMP/project-config.yaml" --schema "$TEST_TMP/schema.yaml" --field brownfield.deadcode_python_enabled
  [ "$status" -eq 0 ]; [ "$output" = "false" ]
  run bash "$RC" --shared "$TEST_TMP/project-config.yaml" --schema "$TEST_TMP/schema.yaml" --field brownfield.deadcode_jvm_enabled
  [ "$status" -eq 0 ]; [ "$output" = "true" ]
}

# --- Hygiene -----------------------------------------------------------------
@test "E70-S8 go: adapter.sh + adapter.json exist; bash -n clean" {
  [ -x "$ADAPTER" ]
  [ -f "$(dirname "$ADAPTER")/adapter.json" ]
  run bash -n "$ADAPTER"
  [ "$status" -eq 0 ]
  run jq -e '.provider' "$(dirname "$ADAPTER")/adapter.json"
  [ "$status" -eq 0 ]
}
