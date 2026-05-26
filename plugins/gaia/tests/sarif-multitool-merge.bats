#!/usr/bin/env bats
# sarif-multitool-merge.bats — E104-S4 coverage for the Phase 7 SARIF merge
# pre-step (sarif-merge.sh + defectdojo-export.sh).
#
# Story: E104-S4. FR-544 / ADR-125. ADR-078 (master flag + per-tool override).
#
# The Microsoft Sarif.Multitool CLI is NOT assumed present — a fake `sarif`
# shim on a private PATH mimics `sarif merge` (concatenates input `runs`),
# so the suite is deterministic and offline. The script then applies the jq
# alphabetical sort by tool.driver.name and writes the merged artifact.

load 'test_helper.bash'

setup() {
  common_setup
  MERGE="$(cd "$BATS_TEST_DIRNAME/../scripts/adapters/brownfield" && pwd)/sarif-merge.sh"
  DDEXPORT="$(cd "$BATS_TEST_DIRNAME/../scripts/adapters/brownfield" && pwd)/defectdojo-export.sh"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/sarif-merge"
  export MERGE DDEXPORT FIXTURES
  FAKE_BIN="$TEST_TMP/bin"; mkdir -p "$FAKE_BIN"; export FAKE_BIN
  # Isolated input + output dirs (the script reads SARIF_INPUT_DIR, writes SARIF_MERGED_OUT).
  export SARIF_INPUT_DIR="$TEST_TMP/sarif-in"
  export SARIF_MERGED_OUT="$TEST_TMP/brownfield-sarif-merged.json"
  mkdir -p "$SARIF_INPUT_DIR"
  NET_LOG="$TEST_TMP/net.log"; export NET_LOG
  _mk_sarif_shim
  _mk_net_shims
}
teardown() { common_teardown; }

# Fake `sarif` CLI: implements `sarif merge --output-directory D --output-file F <inputs...>`
# by concatenating the .runs arrays of all input files into D/F.
_mk_sarif_shim() {
  cat > "$FAKE_BIN/sarif" <<'EOF'
#!/usr/bin/env bash
# Minimal fake of Microsoft Sarif.Multitool `sarif merge`.
sub="$1"; shift || true
[ "$sub" = "merge" ] || { echo "fake-sarif: unsupported subcommand $sub" >&2; exit 2; }
OUTDIR="."; OUTFILE="merged.sarif"; inputs=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-directory) OUTDIR="$2"; shift 2 ;;
    --output-file) OUTFILE="$2"; shift 2 ;;
    *) inputs+=("$1"); shift ;;
  esac
done
# Expand any globs already expanded by caller; concatenate runs.
runs="[]"
for f in "${inputs[@]}"; do
  [ -f "$f" ] || continue
  # Validate each input is SARIF-shaped; non-conformant → error exit (AC: schema validation).
  if ! jq -e '.version=="2.1.0" and (.runs|type=="array")' "$f" >/dev/null 2>&1; then
    echo "fake-sarif: non-conformant SARIF: $f" >&2
    exit 3
  fi
  runs="$(jq -s '.[0] + .[1]' <(printf '%s' "$runs") <(jq '.runs' "$f"))"
done
mkdir -p "$OUTDIR"
jq -n --argjson runs "$runs" '{"$schema":"https://json.schemastore.org/sarif-2.1.0.json","version":"2.1.0","runs":$runs}' > "$OUTDIR/$OUTFILE"
EOF
  chmod +x "$FAKE_BIN/sarif"
}

_mk_net_shims() {
  for t in curl wget; do
    cat > "$FAKE_BIN/$t" <<EOF
#!/usr/bin/env bash
echo "$t \$*" >> "$NET_LOG"
exit 0
EOF
    chmod +x "$FAKE_BIN/$t"
  done
}

seed_inputs() { for tool in "$@"; do cp "$FIXTURES/$tool/$tool.sarif" "$SARIF_INPUT_DIR/$tool.sarif"; done; }
run_merge() { PATH="$FAKE_BIN:$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_SARIF_MERGE_ENABLED=true run bash "$MERGE" "$@"; }

# --- AC5 / Scenario 1 — three-tool merge ----------------------------------

@test "E104-S4 AC5: three-tool merge preserves each tool.driver.name + all findings" {
  seed_inputs grype semgrep gitleaks
  run_merge
  [ "$status" -eq 0 ]
  [ -f "$SARIF_MERGED_OUT" ]
  run jq -r '.runs | length' "$SARIF_MERGED_OUT"
  [ "$output" -eq 3 ]
  run jq -r '[.runs[].tool.driver.name] | sort | join(",")' "$SARIF_MERGED_OUT"
  [ "$output" = "gitleaks,grype,semgrep" ]
  # original ruleIds preserved
  run jq -r '[.runs[].results[0].ruleId] | sort | join(",")' "$SARIF_MERGED_OUT"
  [[ "$output" == *"CVE-2024-0001"* ]]
  [[ "$output" == *"generic-api-key"* ]]
  [[ "$output" == *"py.lang.security.audit"* ]]
}

# --- AC2 / Scenario 2 — six-tool deterministic ordering -------------------

@test "E104-S4 AC2: six-tool merge is deterministically sorted alpha by driver name" {
  seed_inputs grype semgrep codeql gitleaks gosec spotbugs
  run_merge
  [ "$status" -eq 0 ]
  run jq -r '[.runs[].tool.driver.name] | join(",")' "$SARIF_MERGED_OUT"
  [ "$output" = "codeql,gitleaks,gosec,grype,semgrep,spotbugs" ]
}

@test "E104-S4 AC2: merge output is byte-identical across two runs (determinism)" {
  seed_inputs grype semgrep gitleaks
  run_merge; [ "$status" -eq 0 ]; cp "$SARIF_MERGED_OUT" "$TEST_TMP/first.json"
  run_merge; [ "$status" -eq 0 ]
  run diff "$TEST_TMP/first.json" "$SARIF_MERGED_OUT"
  [ "$status" -eq 0 ]
}

# --- AC3 / AC-X1 / Scenario 3 — empty input → migration-shim fallback -----

@test "E104-S4 AC3: zero SARIF inputs emits WARN fallback and exits 0 (legacy path)" {
  # No inputs seeded.
  run_merge
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"* ]]
  [[ "$output" == *"no SARIF inputs"* ]] || [[ "$output" == *"fall"* ]]
  # No merged artifact written on the fallback path.
  [ ! -f "$SARIF_MERGED_OUT" ]
}

# --- AC-X1 / Scenario 4 — flag-off skip -----------------------------------

@test "E104-S4 AC-X1: master flag off skips merge with INFO and exits 0" {
  seed_inputs grype semgrep
  PATH="$FAKE_BIN:$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=false run bash "$MERGE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]] || [[ "$output" == *"INFO"* ]]
  [ ! -f "$SARIF_MERGED_OUT" ]
}

@test "E104-S4 AC-X1: per-tool override off skips merge with INFO and exits 0" {
  seed_inputs grype semgrep
  PATH="$FAKE_BIN:$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_SARIF_MERGE_ENABLED=false run bash "$MERGE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]] || [[ "$output" == *"INFO"* ]]
}

# --- Scenario 8 — malformed SARIF input → error ---------------------------

@test "E104-S4: malformed SARIF input causes non-zero exit (schema validation)" {
  # Non-vacuous guard: only meaningful once the script exists (F1 — Tex red review).
  [ -x "$MERGE" ]
  seed_inputs grype
  printf '{ not valid sarif }\n' > "$SARIF_INPUT_DIR/broken.sarif"
  run_merge
  [ "$status" -ne 0 ]
}

# --- AC4 / Scenario 5 — DefectDojo opt-in disabled (default) → no network --

@test "E104-S4 AC4: DefectDojo export disabled by default makes zero network calls" {
  seed_inputs grype
  PATH="$FAKE_BIN:$PATH" GAIA_BROWNFIELD_DEFECTDOJO_ENABLED=false run bash "$DDEXPORT" "$SARIF_MERGED_OUT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]] || [[ "$output" == *"disabled"* ]] || [[ "$output" == *"INFO"* ]]
  [ ! -s "$NET_LOG" ]
}

@test "E104-S4 AC4 / Scenario 7: DefectDojo enabled but missing api_url WARNs and skips (no failure)" {
  seed_inputs grype
  PATH="$FAKE_BIN:$PATH" GAIA_BROWNFIELD_DEFECTDOJO_ENABLED=true run bash "$DDEXPORT" "$SARIF_MERGED_OUT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"* ]]
  [ ! -s "$NET_LOG" ]
}

# --- Scenario 9 — path canonicalization to repo-root-relative -------------

@test "E104-S4: artifactLocation URIs are canonicalized to repo-root-relative (F1)" {
  # Build inputs with a mix of absolute, file://, and already-relative URIs
  # all under a known repo root.
  local root="$TEST_TMP/repo"
  mkdir -p "$SARIF_INPUT_DIR"
  cat > "$SARIF_INPUT_DIR/grype.sarif" <<JSON
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"grype"}},"results":[{"ruleId":"R1","locations":[{"physicalLocation":{"artifactLocation":{"uri":"$root/src/app.py"}}}]}]}]}
JSON
  cat > "$SARIF_INPUT_DIR/semgrep.sarif" <<JSON
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"semgrep"}},"results":[{"ruleId":"R2","locations":[{"physicalLocation":{"artifactLocation":{"uri":"file://$root/src/views.py"}}}]}]}]}
JSON
  cat > "$SARIF_INPUT_DIR/gitleaks.sarif" <<JSON
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"gitleaks"}},"results":[{"ruleId":"R3","locations":[{"physicalLocation":{"artifactLocation":{"uri":"config/settings.py"}}}]}]}]}
JSON
  PATH="$FAKE_BIN:$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_SARIF_MERGE_ENABLED=true \
    GAIA_REPO_ROOT="$root" run bash "$MERGE"
  [ "$status" -eq 0 ]
  run jq -r '[.runs[].results[0].locations[0].physicalLocation.artifactLocation.uri] | sort | join(",")' "$SARIF_MERGED_OUT"
  [ "$output" = "config/settings.py,src/app.py,src/views.py" ]
}

# --- AC-X1 flag-resolution integration (resolve-config.sh path) -----------
# Mirrors the E70-S7 F2 fix: exercise the REAL config-resolution path.

_mk_bf_config() {
  # $1 deterministic_tools, $2 sarif_merge_enabled
  cat > "$TEST_TMP/project-config.yaml" <<YAML
project_root: /tmp/gaia
project_path: /tmp/gaia/app
memory_path: /tmp/gaia/.gaia/memory
checkpoint_path: /tmp/gaia/.gaia/memory/checkpoints
installed_path: /tmp/gaia/_gaia
framework_version: 1.176.0
date: 2026-05-25
brownfield:
  deterministic_tools: $1
  sarif_merge_enabled: $2
YAML
  cp "$(cd "$BATS_TEST_DIRNAME/../config" && pwd)/project-config.schema.yaml" "$TEST_TMP/project-config.schema.yaml"
}

@test "E104-S4 AC-X1: resolve-config.sh --field brownfield.sarif_merge_enabled is whitelisted" {
  _mk_bf_config true true
  run bash "$SCRIPTS_DIR/resolve-config.sh" --shared "$TEST_TMP/project-config.yaml" \
    --schema "$TEST_TMP/project-config.schema.yaml" --field brownfield.sarif_merge_enabled
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "E104-S4 AC4: resolve-config.sh --field brownfield.defectdojo_enabled is whitelisted" {
  _mk_bf_config true true
  run bash "$SCRIPTS_DIR/resolve-config.sh" --shared "$TEST_TMP/project-config.yaml" \
    --schema "$TEST_TMP/project-config.schema.yaml" --field brownfield.defectdojo_enabled
  [ "$status" -eq 0 ]
}

# --- AC-X2/AC-X3 — sarif_merge telemetry via the shared writer (E104-S1) ----

@test "E104-S4 AC-X2/AC-X3: brownfield-telemetry.sh populates *.sarif_merge fields on the report" {
  TELEM="$(cd "$BATS_TEST_DIRNAME/../scripts/adapters/brownfield" && pwd)/brownfield-telemetry.sh"
  [ -x "$TELEM" ]
  cat > "$TEST_TMP/report.md" <<'MD'
---
title: brownfield report
---
body
MD
  run bash "$TELEM" --report "$TEST_TMP/report.md" --field phase_runtime_seconds.sarif_merge --value 5
  [ "$status" -eq 0 ]
  run bash "$TELEM" --report "$TEST_TMP/report.md" --field deterministic_tool_seconds.sarif_merge --value 5
  [ "$status" -eq 0 ]
  run bash "$TELEM" --report "$TEST_TMP/report.md" --get phase_runtime_seconds.sarif_merge
  [ "$output" = "5" ]
  run grep -F "body" "$TEST_TMP/report.md"
  [ "$status" -eq 0 ]
}

# --- Hygiene --------------------------------------------------------------

@test "E104-S4: sarif-merge.sh + defectdojo-export.sh exist, executable, pass bash -n" {
  [ -x "$MERGE" ]; [ -x "$DDEXPORT" ]
  run bash -n "$MERGE"; [ "$status" -eq 0 ]
  run bash -n "$DDEXPORT"; [ "$status" -eq 0 ]
}
