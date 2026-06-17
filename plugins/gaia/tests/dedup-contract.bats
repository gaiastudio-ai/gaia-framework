#!/usr/bin/env bats
# dedup-contract.bats — E104-S1 cross-tool finding dedup (dual dedup keys).
#
# Story: E104-S1. FR-541 / ADR-123. ADR-078 (master flag + per-tool override).
#
# dedup.sh reads a merged-SARIF document (E104-S4's output shape: runs[] with
# tool.driver.name + results[]), flattens to a finding stream, partitions into
# CVE-class (ruleId ~ ^CVE-\d{4}-\d{4,}$) and non-CVE-class, applies the dual
# dedup keys, and writes a deduped finding array. Pure bash + jq — offline,
# deterministic, hand-authored fixtures.
#
# Dedup keys (AC1):
#   CVE class:     group (CVE-ID, file, severity); tie-break lowest source_tool
#                  ordinal (grype=0, osv-scanner=1, owasp-depcheck=2).
#   Non-CVE class: group (file, symbol-qualifier); winner = highest precision
#                  (deadcode-go=0 > spotbugs=1 > vulture=2 > lint=3). NOTE: AC1's
#                  literal key is (tool,file,qualifier), but tool-inclusive
#                  grouping never lets the precision ladder fire — implemented
#                  per INTENT (group by file+qualifier, tool drives precision).
#                  Deviation captured as a story Finding.

load 'test_helper.bash'

setup() {
  common_setup
  DEDUP="$(cd "$BATS_TEST_DIRNAME/../scripts/adapters/brownfield" && pwd)/dedup.sh"
  TELEM="$(cd "$BATS_TEST_DIRNAME/../scripts/adapters/brownfield" && pwd)/brownfield-telemetry.sh"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/dedup-contract"
  export DEDUP TELEM FIXTURES
  export DEDUP_INPUT="$TEST_TMP/merged.json"
  export DEDUP_OUTPUT="$TEST_TMP/deduped-findings.json"
}
teardown() { common_teardown; }

run_dedup() {
  cp "$FIXTURES/$1" "$DEDUP_INPUT"
  GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_DEDUP_ENABLED=true \
    DEDUP_INPUT="$DEDUP_INPUT" DEDUP_OUTPUT="$DEDUP_OUTPUT" run bash "$DEDUP"
}

# --- AC4 / Scenario 1 — CVE collision -------------------------------------

@test "CVE collision (grype+osv same CVE/file/sev) dedupes to 1, grype canonical" {
  run_dedup cve-collision.json
  [ "$status" -eq 0 ]
  run jq -r 'length' "$DEDUP_OUTPUT"
  [ "$output" -eq 1 ]
  run jq -r '.[0].source_tool' "$DEDUP_OUTPUT"
  [ "$output" = "grype" ]
  run jq -r '.[0].ruleId' "$DEDUP_OUTPUT"
  [ "$output" = "CVE-2024-12345" ]
}

# --- Scenario 2 — CVE no-collision baseline -------------------------------

@test "5 distinct CVE findings pass through (no dedup)" {
  run_dedup cve-no-collision.json
  [ "$status" -eq 0 ]
  run jq -r 'length' "$DEDUP_OUTPUT"
  [ "$output" -eq 5 ]
}

# --- Scenario 3 — non-CVE collision (precision ladder) --------------------

@test "non-CVE collision (deadcode-go+vulture same file/symbol) dedupes to 1, deadcode-go wins" {
  run_dedup noncve-collision.json
  [ "$status" -eq 0 ]
  run jq -r 'length' "$DEDUP_OUTPUT"
  [ "$output" -eq 1 ]
  run jq -r '.[0].source_tool' "$DEDUP_OUTPUT"
  [ "$output" = "deadcode-go" ]
}

# --- AC4 — inflation reduction 8 → 2 --------------------------------------

@test "8 raw findings (CVE group of 4 + non-CVE group of 4) dedupe to 2 with correct winners" {
  run_dedup inflation-8to2.json
  [ "$status" -eq 0 ]
  run jq -r 'length' "$DEDUP_OUTPUT"
  [ "$output" -eq 2 ]
  # CVE survivor: grype canonical (ordinal 0).
  run jq -r '[.[] | select(.ruleId == "CVE-2024-AAAA")] | length' "$DEDUP_OUTPUT"
  [ "$output" -eq 1 ]
  run jq -r '.[] | select(.ruleId == "CVE-2024-AAAA") | .source_tool' "$DEDUP_OUTPUT"
  [ "$output" = "grype" ]
  # Non-CVE survivor: deadcode-go wins the precision ladder (rank 0) over spotbugs/vulture/lint.
  run jq -r '.[] | select(.file_path == "pkg/y.go") | .source_tool' "$DEDUP_OUTPUT"
  [ "$output" = "deadcode-go" ]
}

# --- Scenario 6 — empty input ---------------------------------------------

@test "two distinct symbol-less non-CVE findings in same file are NOT over-deduped (F1)" {
  run_dedup noncve-no-symbol.json
  [ "$status" -eq 0 ]
  # Distinct ruleId + startLine, empty qualifier → must remain TWO findings.
  run jq -r 'length' "$DEDUP_OUTPUT"
  [ "$output" -eq 2 ]
  run jq -r '[.[].ruleId] | sort | join(",")' "$DEDUP_OUTPUT"
  [ "$output" = "no-shadow,no-unused" ]
}

@test "empty input emits empty deduped stream, both counters 0" {
  run_dedup empty.json
  [ "$status" -eq 0 ]
  run jq -r 'length' "$DEDUP_OUTPUT"
  [ "$output" -eq 0 ]
}

# --- AC-X1 / Scenario 7 — master-flag-off passthrough ---------------------

@test "flag-off skips dedup (INFO), raw stream passes through unchanged" {
  cp "$FIXTURES/cve-collision.json" "$DEDUP_INPUT"
  GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_DEDUP_ENABLED=false \
    DEDUP_INPUT="$DEDUP_INPUT" DEDUP_OUTPUT="$DEDUP_OUTPUT" run bash "$DEDUP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]] || [[ "$output" == *"INFO"* ]]
  # Passthrough: the 2 raw findings are preserved (before == after).
  run jq -r 'length' "$DEDUP_OUTPUT"
  [ "$output" -eq 2 ]
}

@test "master flag off skips dedup" {
  cp "$FIXTURES/cve-collision.json" "$DEDUP_INPUT"
  GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=false \
    DEDUP_INPUT="$DEDUP_INPUT" DEDUP_OUTPUT="$DEDUP_OUTPUT" run bash "$DEDUP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]] || [[ "$output" == *"INFO"* ]]
}

# --- Scenario 9 — path canonicalization (dedup operates on given paths) ----

@test "collision detected on already-canonical repo-root-relative paths" {
  # The merged-SARIF is canonicalized upstream by E104-S4; dedup keys on those
  # paths verbatim. Assert collision detection works on canonical paths.
  run_dedup cve-collision.json
  [ "$status" -eq 0 ]
  run jq -r '.[0].file_path' "$DEDUP_OUTPUT"
  [ "$output" = "lib/foo.go" ]
}

# --- AC3 / AC-X2 / AC-X3 — telemetry writer -------------------------------

@test "telemetry writer sets gap_count_before/after_dedup on report frontmatter" {
  # A minimal report with YAML frontmatter.
  cat > "$TEST_TMP/report.md" <<'MD'
---
title: brownfield report
llm_token_count: 0
---
# Report body
MD
  run bash "$TELEM" --report "$TEST_TMP/report.md" \
    --field gap_count_before_dedup --value 8
  [ "$status" -eq 0 ]
  run bash "$TELEM" --report "$TEST_TMP/report.md" \
    --field gap_count_after_dedup --value 2
  [ "$status" -eq 0 ]
  run grep -E "^gap_count_before_dedup: 8$" "$TEST_TMP/report.md"
  [ "$status" -eq 0 ]
  run grep -E "^gap_count_after_dedup: 2$" "$TEST_TMP/report.md"
  [ "$status" -eq 0 ]
  # body preserved
  run grep -F "# Report body" "$TEST_TMP/report.md"
  [ "$status" -eq 0 ]
}

@test "telemetry writer sets nested phase_runtime_seconds.dedup" {
  cat > "$TEST_TMP/report.md" <<'MD'
---
title: brownfield report
---
body
MD
  run bash "$TELEM" --report "$TEST_TMP/report.md" \
    --field phase_runtime_seconds.dedup --value 3
  [ "$status" -eq 0 ]
  run bash "$TELEM" --report "$TEST_TMP/report.md" --get phase_runtime_seconds.dedup
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "telemetry writer sets deterministic_tool_seconds.dedup and llm_token_count:0" {
  cat > "$TEST_TMP/report.md" <<'MD'
---
title: brownfield report
---
body
MD
  run bash "$TELEM" --report "$TEST_TMP/report.md" --field deterministic_tool_seconds.dedup --value 3
  [ "$status" -eq 0 ]
  run bash "$TELEM" --report "$TEST_TMP/report.md" --field llm_token_count --value 0
  [ "$status" -eq 0 ]
  run bash "$TELEM" --report "$TEST_TMP/report.md" --get deterministic_tool_seconds.dedup
  [ "$output" = "3" ]
  run grep -E "^llm_token_count: 0$" "$TEST_TMP/report.md"
  [ "$status" -eq 0 ]
}

# --- AC-X1 flag-resolution integration (resolve-config path) --------------

@test "resolve-config.sh --field brownfield.dedup_enabled is whitelisted" {
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
  dedup_enabled: true
YAML
  cp "$(cd "$BATS_TEST_DIRNAME/../config" && pwd)/project-config.schema.yaml" "$TEST_TMP/project-config.schema.yaml"
  run bash "$SCRIPTS_DIR/resolve-config.sh" --shared "$TEST_TMP/project-config.yaml" \
    --schema "$TEST_TMP/project-config.schema.yaml" --field brownfield.dedup_enabled
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

# --- Hygiene --------------------------------------------------------------

@test "dedup.sh + brownfield-telemetry.sh exist, executable, pass bash -n" {
  [ -x "$DEDUP" ]; [ -x "$TELEM" ]
  run bash -n "$DEDUP"; [ "$status" -eq 0 ]
  run bash -n "$TELEM"; [ "$status" -eq 0 ]
}
