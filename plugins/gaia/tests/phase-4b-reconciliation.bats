#!/usr/bin/env bats
# phase-4b-reconciliation.bats — E104-S2 Phase 4b reconciliation pass.
#
# Story: E104-S2. FR-540 / ADR-124. ADR-078 (master flag + per-tool override).
#
# reconcile.sh is a PURE JSON-join: it reads the E104-S1 deduped finding stream +
# per-stack call-graph outputs, builds an entry-point reachable-set, and DEMOTES
# (never removes) Phase 3 file-only findings to severity INFO when the file is
# reachable from >=1 entry point — annotating reconciled:true, original_severity,
# entry_points[], reconciliation_reason. Identity fields (file_path, qualifier,
# source_tool, ruleId, start_line) are preserved verbatim (AC4/AC7). Files NOT
# reachable retain their original severity. Empty/missing call-graph -> WARN +
# passthrough unchanged (findings_demoted_by_reconciliation:0). <5s on 1M-line
# monorepo (no tool re-invocation). Pure bash + jq; offline; deterministic.
#
# Env seams:
#   RECON_FINDINGS      deduped-findings.json (E104-S1 output)
#   RECON_CALLGRAPH_DIR dir holding callgraph-{js,go,python}.json
#   RECON_OUTPUT        reconciled-findings.json
#   RECON_REPORT        telemetry report frontmatter (optional)

load 'test_helper.bash'

setup() {
  common_setup
  ADAPTER="$(cd "$BATS_TEST_DIRNAME/../scripts/adapters/brownfield" && pwd 2>/dev/null || echo "$BATS_TEST_DIRNAME/../scripts/adapters/brownfield")/reconcile.sh"
  FX="$BATS_TEST_DIRNAME/fixtures/phase-4b-reconciliation"
  export ADAPTER FX
  OUT="$TEST_TMP/reconciled.json"; export OUT
}
teardown() { common_teardown; }

run_recon() {
  local fixture="$1"
  GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_PHASE_4B_ENABLED=true \
    RECON_FINDINGS="$FX/$fixture/deduped-findings.json" RECON_CALLGRAPH_DIR="$FX/$fixture" \
    RECON_OUTPUT="$OUT" run bash "$ADAPTER"
}

# --- AC3 / AC6 / scenario 1 — barrel-file demotion to INFO --------------------
@test "E104-S2 (scenario 1): barrel src/index.ts reachable → demoted to INFO + entry_points" {
  run_recon barrel
  [ "$status" -eq 0 ]
  [ -f "$OUT" ]
  run jq -r '.[] | select(.file_path=="src/index.ts") | .severity' "$OUT"
  [ "$output" = "info" ]
  run jq -r '.[] | select(.file_path=="src/index.ts") | .reconciled' "$OUT"
  [ "$output" = "true" ]
  run jq -r '.[] | select(.file_path=="src/index.ts") | .original_severity' "$OUT"
  [ "$output" = "warning" ]
  run jq -e '.[] | select(.file_path=="src/index.ts") | .entry_points | index("src/app.tsx")' "$OUT"
  [ "$status" -eq 0 ]
  run jq -r '.[] | select(.file_path=="src/index.ts") | .reconciliation_reason' "$OUT"
  [[ "$output" == *"reference"* ]]
}

# --- AC3 / scenario 2 — truly-unreferenced file: severity UNCHANGED -----------
@test "E104-S2 (scenario 2): orphan src/orphan.ts not reachable → severity unchanged" {
  run_recon barrel
  [ "$status" -eq 0 ]
  run jq -r '.[] | select(.file_path=="src/orphan.ts") | .severity' "$OUT"
  [ "$output" = "warning" ]
  run jq -r '.[] | select(.file_path=="src/orphan.ts") | .reconciled // "absent"' "$OUT"
  [ "$output" = "false" ] || [ "$output" = "absent" ]
}

# --- AC4 / AC7 / scenario 7 — identity fields preserved verbatim --------------
@test "E104-S2 (scenario 7): identity fields (file_path,qualifier,source_tool,ruleId,start_line) preserved" {
  run_recon barrel
  [ "$status" -eq 0 ]
  run jq -r '.[] | select(.file_path=="src/index.ts") | "\(.ruleId)|\(.source_tool)|\(.qualifier)|\(.start_line)"' "$OUT"
  [ "$output" = "dead-code/js|dead-exports|default|1" ]
}

# --- AC3 / scenario 3 — multi-stack: Go + JS both demoted ---------------------
@test "E104-S2 (scenario 3): multi-stack Go + JS both reachable → both demoted to INFO" {
  run_recon multi-stack
  [ "$status" -eq 0 ]
  run jq -r '.[] | select(.file_path=="pkg/util/helper.go") | .severity' "$OUT"
  [ "$output" = "info" ]
  run jq -r '.[] | select(.file_path=="web/src/api.ts") | .severity' "$OUT"
  [ "$output" = "info" ]
  # per-stack qualifiers preserved
  run jq -r '.[] | select(.file_path=="pkg/util/helper.go") | .qualifier' "$OUT"
  [ "$output" = "util.Helper" ]
}

# --- multi-callgraph overlap → entry_points UNIONed (not last-write-wins) -----
@test "E104-S2: same file across two call-graphs → entry_points unioned" {
  ov="$TEST_TMP/overlap"; mkdir -p "$ov"
  cat > "$ov/deduped-findings.json" <<'JSON'
[ { "ruleId": "dead-code/js", "file_path": "src/shared.ts", "severity": "warning", "source_tool": "dead-exports", "qualifier": "x", "start_line": 1 } ]
JSON
  cat > "$ov/callgraph-js.json" <<'JSON'
{ "entry_points": ["a"], "reachable": [ { "file": "src/shared.ts", "referenced_by": ["src/a.tsx"] } ] }
JSON
  cat > "$ov/callgraph-go.json" <<'JSON'
{ "entry_points": ["b"], "reachable": [ { "file": "src/shared.ts", "referenced_by": ["src/b.go"] } ] }
JSON
  GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_PHASE_4B_ENABLED=true \
    RECON_FINDINGS="$ov/deduped-findings.json" RECON_CALLGRAPH_DIR="$ov" RECON_OUTPUT="$OUT" run bash "$ADAPTER"
  [ "$status" -eq 0 ]
  # both referencing files present (union across the two call-graphs), not just one
  run jq -e '.[0].entry_points | (index("src/a.tsx") and index("src/b.go"))' "$OUT"
  [ "$status" -eq 0 ]
}

# --- scenario 4 — empty call-graph → passthrough unchanged + WARN -------------
@test "E104-S2 (scenario 4): empty call-graph → no demotion, findings pass through + WARN" {
  run_recon empty-callgraph
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"* ]] || [[ "$output" == *"WARNING"* ]]
  run jq -r '.[] | select(.file_path=="src/index.ts") | .severity' "$OUT"
  [ "$output" = "warning" ]   # unchanged
}

# --- AC-X3 — telemetry: findings_demoted_by_reconciliation + phase_4b runtime -
@test "E104-S2 AC-X3: telemetry frontmatter populated (demoted count + runtime + llm 0)" {
  cat > "$TEST_TMP/report.md" <<'MD'
---
title: gaps
gap_count_after_dedup: 2
---
body
MD
  GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_PHASE_4B_ENABLED=true \
    RECON_FINDINGS="$FX/barrel/deduped-findings.json" RECON_CALLGRAPH_DIR="$FX/barrel" \
    RECON_OUTPUT="$OUT" RECON_REPORT="$TEST_TMP/report.md" run bash "$ADAPTER"
  [ "$status" -eq 0 ]
  run grep -E '^findings_demoted_by_reconciliation: 1$' "$TEST_TMP/report.md"
  [ "$status" -eq 0 ]
  run grep -E '^llm_token_count: 0$' "$TEST_TMP/report.md"
  [ "$status" -eq 0 ]
  run grep -E '^phase_runtime_seconds:' "$TEST_TMP/report.md"
  [ "$status" -eq 0 ]
  # gap_count_after_dedup (dedup-owned) preserved read-through, NOT re-authored
  run grep -E '^gap_count_after_dedup: 2$' "$TEST_TMP/report.md"
  [ "$status" -eq 0 ]
}

# --- AC-X1 / scenario 8 — per-tool flag off → passthrough, no reconciliation --
@test "E104-S2 (scenario 8): phase_4b_enabled=false → skip, raw stream passes through" {
  GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_PHASE_4B_ENABLED=false \
    RECON_FINDINGS="$FX/barrel/deduped-findings.json" RECON_CALLGRAPH_DIR="$FX/barrel" \
    RECON_OUTPUT="$OUT" run bash "$ADAPTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]] || [[ "$output" == *"INFO"* ]]
  # raw stream passes through unchanged (no demotion)
  if [ -f "$OUT" ]; then
    run jq -r '.[] | select(.file_path=="src/index.ts") | .severity' "$OUT"
    [ "$output" = "warning" ]
  fi
}

# --- AC-X1 — master flag off → skip -------------------------------------------
@test "E104-S2: master flag off → skipped regardless of per-tool" {
  GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=false GAIA_BROWNFIELD_PHASE_4B_ENABLED=true \
    RECON_FINDINGS="$FX/barrel/deduped-findings.json" RECON_CALLGRAPH_DIR="$FX/barrel" \
    RECON_OUTPUT="$OUT" run bash "$ADAPTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]] || [[ "$output" == *"INFO"* ]]
}

# --- AC5 / scenario 5 — wall-clock budget on a large synthesized fixture ------
@test "E104-S2 (scenario 5): 5k findings + reachable-set → reconcile under 5s" {
  big="$TEST_TMP/big"; mkdir -p "$big"
  # 5000 findings; even index reachable, odd not.
  jq -n '[range(0;5000) | {ruleId:"dead-code/js", file_path:("src/f\(.)" + ".ts"), severity:"warning", source_tool:"dead-exports", qualifier:"x", start_line:1}]' > "$big/deduped-findings.json"
  jq -n '{entry_points:["src/app.tsx"], reachable:[range(0;5000;2) | {file:("src/f\(.)" + ".ts"), referenced_by:["src/app.tsx"]}]}' > "$big/callgraph-js.json"
  start=$(date +%s)
  GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_PHASE_4B_ENABLED=true \
    RECON_FINDINGS="$big/deduped-findings.json" RECON_CALLGRAPH_DIR="$big" RECON_OUTPUT="$OUT" run bash "$ADAPTER"
  end=$(date +%s)
  [ "$status" -eq 0 ]
  [ $(( end - start )) -lt 5 ]
  # 2500 demoted (even indices reachable)
  run jq '[.[] | select(.reconciled==true)] | length' "$OUT"
  [ "$output" = "2500" ]
}

# --- degrade — missing findings input → empty output, exit 0 ------------------
@test "E104-S2: missing deduped-findings input → empty stream, exit 0 (degrade)" {
  GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_PHASE_4B_ENABLED=true \
    RECON_FINDINGS="$TEST_TMP/nope.json" RECON_CALLGRAPH_DIR="$FX/barrel" RECON_OUTPUT="$OUT" run bash "$ADAPTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"INFO"* ]] || [[ "$output" == *"WARN"* ]]
}

# --- AC-X1 — resolve-config exposes the flag ----------------------------------
@test "E104-S2 AC-X1: resolve-config.sh --field brownfield.phase_4b_enabled whitelisted" {
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
  phase_4b_enabled: true
YAML
  cp "$(cd "$BATS_TEST_DIRNAME/../config" && pwd)/project-config.schema.yaml" "$TEST_TMP/schema.yaml"
  RC="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/resolve-config.sh"
  run bash "$RC" --shared "$TEST_TMP/pc.yaml" --schema "$TEST_TMP/schema.yaml" --field brownfield.phase_4b_enabled
  [ "$status" -eq 0 ]; [ "$output" = "true" ]
}

# --- Hygiene ------------------------------------------------------------------
# NOTE: the ADR-124 shard lives at project-root .gaia/ (a planning artifact, NOT in
# the gaia-framework git repo), so it is intentionally NOT asserted here — CI checks out
# only gaia-framework. Shard existence is verified by Val at review time.
@test "E104-S2: reconcile.sh exists, executable, bash -n clean" {
  [ -x "$ADAPTER" ]
  run bash -n "$ADAPTER"
  [ "$status" -eq 0 ]
}
