#!/usr/bin/env bats
# phase-4b-cross-stack.bats — E104-S5 Phase 4b cross-stack WARNING emission + scope respect.
#
# Story: E104-S5. FR-547 / NFR-89 / ADR-063 (WARNING vocab) / ADR-120 (bypass) / ADR-126.
#
# reconcile-cross-stack.sh partitions Phase 4b input by stacks[].path, builds a
# {file->stack} reverse-index, and for each dependency-graph edge that crosses a
# stack boundary checks the source stack's cross_refs[] allowlist. Unsanctioned
# edges emit the canonical ADR-063 WARNING:
#   unsanctioned-cross-stack-reference: <src_stack>:<file> -> <tgt_stack>:<file>
# `--bypass cross-stack-refs --reason "<text>"` (ADR-120, reusing E85-S14's
# parse-bypass-flag.sh) suppresses + logs. SR-86 allowlist ^[A-Za-z0-9 ._-]+$ rejects
# shell-metachar reasons. NEVER aborts. Pure bash + jq + yq; offline; deterministic.
#
# Env seams:
#   XSTACK_CONFIG     project-config.yaml (stacks[].path + cross_refs[])
#   XSTACK_DEPGRAPH   dep-graph JSON {edges:[{source,target}]}
#   XSTACK_REPORT     telemetry report frontmatter (optional)
#   XSTACK_BYPASS_LOG bypass-log JSONL path (default .gaia/memory/brownfield-audit/bypass-log.json)

load 'test_helper.bash'

setup() {
  common_setup
  ADAPTER="$(cd "$BATS_TEST_DIRNAME/../scripts/adapters/brownfield" && pwd 2>/dev/null || echo "$BATS_TEST_DIRNAME/../scripts/adapters/brownfield")/reconcile-cross-stack.sh"
  FX="$BATS_TEST_DIRNAME/fixtures/phase-4b-cross-stack"
  export ADAPTER FX
  BLOG="$TEST_TMP/bypass-log.json"; export BLOG
}
teardown() { common_teardown; }

run_xstack() {
  local fixture="$1"; shift
  GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_PHASE_4B_CROSS_STACK_ENABLED=true \
    XSTACK_CONFIG="$FX/$fixture/project-config.yaml" XSTACK_DEPGRAPH="$FX/$fixture/depgraph.json" \
    XSTACK_BYPASS_LOG="$BLOG" run bash "$ADAPTER" "$@"
}

# --- AC2 / TC-MSP-4 — WARNING on unsanctioned cross-stack edge ----------------
@test "E104-S5 (TC-MSP-4 emission): api→web with empty cross_refs → canonical WARNING" {
  run_xstack three-stack
  [ "$status" -eq 0 ]
  [[ "$output" == *"unsanctioned-cross-stack-reference: api:services/api/main.go -> web:services/web/handler.ts"* ]]
}

# --- AC1 / TC-MSP-4 — scoping isolation: intra-stack edges never warn ---------
@test "E104-S5 (TC-MSP-4 scoping): intra-stack edges do NOT warn (no cross-contamination)" {
  run_xstack three-stack
  [ "$status" -eq 0 ]
  # exactly ONE warning (the api→web edge); the two intra-stack edges are silent.
  [ "$(printf '%s\n' "$output" | grep -c 'unsanctioned-cross-stack-reference')" -eq 1 ]
  [[ "$output" != *"api/util.go"* ]]
  [[ "$output" != *"worker/job.py"* ]]
}

# --- AC3 — cross_stack_warnings[] telemetry detail rows -----------------------
@test "E104-S5 AC3: cross_stack_warnings[] populated with stack+file pair detail" {
  cat > "$TEST_TMP/report.md" <<'MD'
---
title: gaps
---
body
MD
  GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_PHASE_4B_CROSS_STACK_ENABLED=true \
    XSTACK_CONFIG="$FX/three-stack/project-config.yaml" XSTACK_DEPGRAPH="$FX/three-stack/depgraph.json" \
    XSTACK_REPORT="$TEST_TMP/report.md" XSTACK_BYPASS_LOG="$BLOG" run bash "$ADAPTER"
  [ "$status" -eq 0 ]
  run grep -E '^cross_stack_warnings:' "$TEST_TMP/report.md"
  [ "$status" -eq 0 ]
  run grep -E 'source_stack|api' "$TEST_TMP/report.md"
  [ "$status" -eq 0 ]
}

# --- AC4 / TC-MSP-5 — bypass with reason suppresses + logs --------------------
@test "E104-S5 (TC-MSP-5 bypass): --bypass cross-stack-refs --reason suppresses + logs" {
  run_xstack three-stack --bypass cross-stack-refs --reason "needed for migration step"
  [ "$status" -eq 0 ]
  [[ "$output" != *"unsanctioned-cross-stack-reference"* ]]
  [[ "$output" == *"Bypass applied"* ]] || [[ "$output" == *"bypass"* ]]
  [ -f "$BLOG" ]
  run jq -r '.bypass' "$BLOG"
  [ "$output" = "cross-stack-refs" ]
  run jq -r '.reason' "$BLOG"
  [ "$output" = "needed for migration step" ]
  run jq -r '.suppressed_count' "$BLOG"
  [ "$output" = "1" ]
}

# --- AC4 / scenario 4 — bypass missing reason REJECTED ------------------------
@test "E104-S5 (scenario 4): --bypass without --reason → REJECTED (ADR-120)" {
  run_xstack three-stack --bypass cross-stack-refs
  [ "$status" -ne 0 ]
  [[ "$output" == *"reason"* ]]
}

# --- AC4 / scenario 5 — malformed (shell-metachar) reason REJECTED (SR-86) ----
@test "E104-S5 (scenario 5): --reason with shell metachars → REJECTED (SR-86 allowlist)" {
  run_xstack three-stack --bypass cross-stack-refs --reason "; rm -rf /"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SR-86"* ]] || [[ "$output" == *"reason"* ]] || [[ "$output" == *"invalid"* ]]
  # No deletion, no suppression-log written for a rejected bypass.
  [ ! -f "$BLOG" ] || [ "$(jq -s 'length' "$BLOG" 2>/dev/null || echo 0)" = "0" ]
}

# --- AC6 / TC-MSP-11 — shared-subdir: both allowlist → no WARNING -------------
@test "E104-S5 (TC-MSP-11 symmetric): both stacks cross_refs:[shared] → no WARNING" {
  run_xstack shared-subdir
  [ "$status" -eq 0 ]
  [[ "$output" != *"unsanctioned-cross-stack-reference"* ]]
}

# --- AC6 / TC-MSP-11 — asymmetric: web drops shared → only web→shared warns ---
@test "E104-S5 (TC-MSP-11 asymmetric): web missing cross_refs → one WARNING (web→shared only)" {
  cfg="$TEST_TMP/asym-config.yaml"
  # Copy shared-subdir config but strip `shared` from web's cross_refs.
  yq eval '(.stacks[] | select(.name == "web") | .cross_refs) = []' "$FX/shared-subdir/project-config.yaml" > "$cfg"
  GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_PHASE_4B_CROSS_STACK_ENABLED=true \
    XSTACK_CONFIG="$cfg" XSTACK_DEPGRAPH="$FX/shared-subdir/depgraph.json" XSTACK_BYPASS_LOG="$BLOG" run bash "$ADAPTER"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'unsanctioned-cross-stack-reference')" -eq 1 ]
  [[ "$output" == *"web:services/web/index.ts -> shared:shared/util.go"* ]]
  [[ "$output" != *"api:services/api/main.go -> shared"* ]]
}

# --- AC5 / TC-MSP-8 — NFR-89: 5-stack 8-edge, total well under budget ---------
@test "E104-S5 (TC-MSP-8 NFR-89): 5-stack 8-edge cross-stack detection under perf budget" {
  start=$(date +%s%N)
  run_xstack five-stack-eight-edge
  end=$(date +%s%N)
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'unsanctioned-cross-stack-reference')" -eq 8 ]
  elapsed_ms=$(( (end - start) / 1000000 ))
  # Worst case 5x5 pairs x 100ms = 2.5s; assert comfortably under that (whole run).
  [ "$elapsed_ms" -lt 2500 ]
}

# --- AC-X1 / scenario 9 — per-tool flag off → skip ----------------------------
@test "E104-S5 (scenario 9): phase_4b_cross_stack_enabled=false → INFO skip, no warnings" {
  GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_PHASE_4B_CROSS_STACK_ENABLED=false \
    XSTACK_CONFIG="$FX/three-stack/project-config.yaml" XSTACK_DEPGRAPH="$FX/three-stack/depgraph.json" \
    XSTACK_BYPASS_LOG="$BLOG" run bash "$ADAPTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]] || [[ "$output" == *"INFO"* ]]
  [[ "$output" != *"unsanctioned-cross-stack-reference"* ]]
}

# --- AC-X1 — master flag off → skip -------------------------------------------
@test "E104-S5: master flag off → skipped regardless of per-tool" {
  GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=false GAIA_BROWNFIELD_PHASE_4B_CROSS_STACK_ENABLED=true \
    XSTACK_CONFIG="$FX/three-stack/project-config.yaml" XSTACK_DEPGRAPH="$FX/three-stack/depgraph.json" \
    XSTACK_BYPASS_LOG="$BLOG" run bash "$ADAPTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]] || [[ "$output" == *"INFO"* ]]
}

# --- scenario 11 — single-stack (path:null) zero-regression -------------------
@test "E104-S5 (scenario 11): single-stack path:null → zero cross-edges, no WARNING" {
  run_xstack single-stack
  [ "$status" -eq 0 ]
  [[ "$output" != *"unsanctioned-cross-stack-reference"* ]]
}

# --- degrade — missing dep-graph → INFO skip, never abort ---------------------
@test "E104-S5: missing dep-graph → INFO skip, exit 0 (degrade; producer is E104-S2)" {
  GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_PHASE_4B_CROSS_STACK_ENABLED=true \
    XSTACK_CONFIG="$FX/three-stack/project-config.yaml" XSTACK_DEPGRAPH="$TEST_TMP/nope.json" \
    XSTACK_BYPASS_LOG="$BLOG" run bash "$ADAPTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"INFO"* ]]
  [[ "$output" != *"unsanctioned-cross-stack-reference"* ]]
}

# --- AC-X1 — resolve-config exposes the flag ----------------------------------
@test "E104-S5 AC-X1: resolve-config.sh --field brownfield.phase_4b_cross_stack_enabled whitelisted" {
  cat > "$TEST_TMP/pc.yaml" <<YAML
project_root: /tmp/gaia
project_path: /tmp/gaia/app
memory_path: /tmp/gaia/.gaia/memory
checkpoint_path: /tmp/gaia/.gaia/memory/checkpoints
installed_path: /tmp/gaia/_gaia
framework_version: 1.176.0
date: 2026-05-25
brownfield:
  deterministic_tools: true
  phase_4b_cross_stack_enabled: true
YAML
  cp "$(cd "$BATS_TEST_DIRNAME/../config" && pwd)/project-config.schema.yaml" "$TEST_TMP/schema.yaml"
  RC="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/resolve-config.sh"
  run bash "$RC" --shared "$TEST_TMP/pc.yaml" --schema "$TEST_TMP/schema.yaml" --field brownfield.phase_4b_cross_stack_enabled
  [ "$status" -eq 0 ]; [ "$output" = "true" ]
}

# --- Hygiene ------------------------------------------------------------------
@test "E104-S5: reconcile-cross-stack.sh exists, executable, bash -n clean" {
  [ -x "$ADAPTER" ]
  run bash -n "$ADAPTER"
  [ "$status" -eq 0 ]
}
