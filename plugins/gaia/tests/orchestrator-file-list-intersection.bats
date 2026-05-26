#!/usr/bin/env bats
# orchestrator-file-list-intersection.bats — E70-S10 per-stack file-list
# intersection (path × paths × excludes) before adapter dispatch.
#
# Story: E70-S10. FR-546 / ADR-126. ADR-078 (adapter run.sh --input contract,
# byte-stable). ADR-121 (master flag).
#
# orchestrator.sh, for each stacks[] entry, computes:
#   (path_root ∩ paths[]) − excludes[]   where path_root = stack.path || '.'
# and writes a per-stack file-list to $ORCH_OUT_DIR/<stack>.files (repo-root-
# relative paths, sorted). Single-stack (path:null) collapses to '.' ∩ paths −
# excludes, byte-identical to pre-deploy. Pure bash globstar + find; offline.
#
# Env seams: ORCH_CONFIG (project-config path), ORCH_ROOT (source tree root),
# ORCH_OUT_DIR (per-stack file-list output dir).

load 'test_helper.bash'

setup() {
  common_setup
  ORCH="$(cd "$BATS_TEST_DIRNAME/../scripts/adapters/brownfield" && pwd 2>/dev/null || echo "$BATS_TEST_DIRNAME/../scripts/adapters/brownfield")/orchestrator.sh"
  FX="$BATS_TEST_DIRNAME/fixtures/orchestrator-intersection"
  export ORCH FX
  export ORCH_OUT_DIR="$TEST_TMP/out"
  mkdir -p "$ORCH_OUT_DIR"
}
teardown() { common_teardown; }

run_orch() {
  local fixture="$1"
  PATH="$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
    ORCH_CONFIG="$FX/$fixture/project-config.yaml" ORCH_ROOT="$FX/$fixture" \
    ORCH_OUT_DIR="$ORCH_OUT_DIR" run bash "$ORCH"
}

# --- AC3 / AC6(a) — TC-MSP-9 single-stack zero-regression -----------------

@test "E70-S10 AC3 (TC-MSP-9): single-stack (path:null) file-list excludes *.min.js, lists src/**" {
  run_orch single-stack
  [ "$status" -eq 0 ]
  [ -f "$ORCH_OUT_DIR/root.files" ]
  run cat "$ORCH_OUT_DIR/root.files"
  [[ "$output" == *"src/app.py"* ]]
  [[ "$output" == *"src/sub/util.py"* ]]
  # excludes win: the .min.js must be absent.
  [[ "$output" != *"vendor.min.js"* ]]
}

@test "E70-S10 AC3 (TC-MSP-9): single-stack file-list is deterministic (byte-identical across runs)" {
  run_orch single-stack; [ "$status" -eq 0 ]; cp "$ORCH_OUT_DIR/root.files" "$TEST_TMP/first"
  run_orch single-stack; [ "$status" -eq 0 ]
  run diff "$TEST_TMP/first" "$ORCH_OUT_DIR/root.files"
  [ "$status" -eq 0 ]
}

# --- AC4 / AC6(b) — TC-MSP-4 3-stack dispatch-scoping ---------------------

@test "E70-S10 AC4 (TC-MSP-4): 3-stack scoping — each stack's file-list contains only its language" {
  run_orch three-stack
  [ "$status" -eq 0 ]
  # api (Go): only .go
  run cat "$ORCH_OUT_DIR/api.files"; [[ "$output" == *"main.go"* ]]; [[ "$output" != *".ts"* ]]; [[ "$output" != *".py"* ]]
  # web (TS): only .ts
  run cat "$ORCH_OUT_DIR/web.files"; [[ "$output" == *"app.ts"* ]]; [[ "$output" != *".go"* ]]; [[ "$output" != *".py"* ]]
  # batch (Python): only .py
  run cat "$ORCH_OUT_DIR/batch.files"; [[ "$output" == *"job.py"* ]]; [[ "$output" != *".go"* ]]; [[ "$output" != *".ts"* ]]
}

@test "E70-S10 AC4: 3-stack paths are scoped under each stack's path_root (no cross-contamination)" {
  run_orch three-stack
  [ "$status" -eq 0 ]
  # api's file-list paths must all be under services/api
  run cat "$ORCH_OUT_DIR/api.files"
  [[ "$output" == *"services/api/"* ]]
  [[ "$output" != *"services/web/"* ]]
}

# --- AC5 / AC6(c) — TC-MSP-12 multi-language service ----------------------

@test "E70-S10 AC5 (TC-MSP-12): multi-language stack file-list is the union of .go + .py under the path_root" {
  run_orch multi-language-service
  [ "$status" -eq 0 ]
  run cat "$ORCH_OUT_DIR/ml.files"
  [[ "$output" == *"src/main.go"* ]]
  [[ "$output" == *"scripts/codegen.py"* ]]
}

# --- AC6(d) — excludes precedence -----------------------------------------

@test "E70-S10 AC6(d): a file matching BOTH paths and excludes is excluded (excludes win)" {
  # single-stack fixture: vendor.min.js matches src/** (paths) AND **/*.min.js (excludes).
  run_orch single-stack
  [ "$status" -eq 0 ]
  run grep -c "vendor.min.js" "$ORCH_OUT_DIR/root.files"
  [ "$output" -eq 0 ]
}

# --- AC-X1 — flag-off: orchestrator not invoked / no-op --------------------

@test "E70-S10 AC-X1: master flag off → orchestrator is a no-op (INFO, exit 0, no file-lists)" {
  PATH="$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=false \
    ORCH_CONFIG="$FX/single-stack/project-config.yaml" ORCH_ROOT="$FX/single-stack" \
    ORCH_OUT_DIR="$ORCH_OUT_DIR" run bash "$ORCH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]] || [[ "$output" == *"INFO"* ]]
  [ ! -f "$ORCH_OUT_DIR/root.files" ]
}

# --- Empty-stack — per_stack_file_counts explicit 0 -----------------------

@test "E70-S10: empty stack (overly-restrictive excludes) emits a file-list with 0 entries" {
  # Reuse single-stack but exclude everything via an extra config.
  cat > "$TEST_TMP/empty-config.yaml" <<'YAML'
project_root: /tmp/gaia
project_path: /tmp/gaia
memory_path: /tmp/gaia/.gaia/memory
checkpoint_path: /tmp/gaia/.gaia/memory/checkpoints
installed_path: /tmp/gaia/_gaia
framework_version: 1.176.0
date: 2026-05-25
stacks:
  - name: root
    language: python
    paths: ["src/**"]
    excludes: ["**"]
YAML
  PATH="$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
    ORCH_CONFIG="$TEST_TMP/empty-config.yaml" ORCH_ROOT="$FX/single-stack" \
    ORCH_OUT_DIR="$ORCH_OUT_DIR" run bash "$ORCH"
  [ "$status" -eq 0 ]
  [ -f "$ORCH_OUT_DIR/root.files" ]
  run wc -l < "$ORCH_OUT_DIR/root.files"
  [ "$output" -eq 0 ]
}

# --- F2 (Val) — nested-manifest under a stack path_root is not double-counted

@test "E70-S10: nested manifest under stack path_root does not double-count files (F2)" {
  run_orch nested-manifest
  [ "$status" -eq 0 ]
  # The Go stack at services/api lists its .go files (incl. nested scripts/build.go) ONCE each.
  run sort "$ORCH_OUT_DIR/api.files"
  local sorted="$output"
  run bash -c "sort '$ORCH_OUT_DIR/api.files' | uniq -d"
  [ -z "$output" ]   # no duplicate lines
  # package.json (non-.go) is not picked up by the **/*.go glob.
  run cat "$ORCH_OUT_DIR/api.files"
  [[ "$output" != *"package.json"* ]]
}

# --- Manifest / counts emission -------------------------------------------

@test "E70-S10 AC-X3: orchestrator emits per-stack file counts on stdout" {
  run_orch three-stack
  [ "$status" -eq 0 ]
  # counts surfaced for downstream telemetry (per_stack_file_counts).
  [[ "$output" == *"api"* ]]
  [[ "$output" == *"per_stack_file_counts"* ]] || [[ "$output" == *"file_count"* ]]
}

# --- Hygiene --------------------------------------------------------------

@test "E70-S10: orchestrator.sh exists, is executable, passes bash -n" {
  [ -x "$ORCH" ]
  run bash -n "$ORCH"
  [ "$status" -eq 0 ]
}
