#!/usr/bin/env bash
# adapters/brownfield/sarif-merge.sh — E104-S4 Phase 7 SARIF Multitool merge pre-step.
#
# Merges all scanner SARIF outputs (Grype, Semgrep, CodeQL, gitleaks, gosec,
# SpotBugs) into a single merged SARIF so the existing 6-step gap-consolidation
# recipe consumes ONE uniform interchange format instead of bespoke per-tool
# JSON (FR-544 / ADR-125). Downstream dedup (E104-S1) operates on the merge.
#
# Contract (ADR-078 / ADR-125):
#   - Gated behind brownfield.deterministic_tools master flag + the
#     brownfield.sarif_merge_enabled per-tool override (resolved by
#     /gaia-brownfield and exported as GAIA_BROWNFIELD_*). Flag-off -> INFO skip.
#   - Migration shim: 0 SARIF inputs -> WARN + exit 0 (the 6-step recipe falls
#     back to its prior per-tool JSON consumption; 1-sprint deprecation).
#   - Graceful degrade: `sarif` CLI absent -> WARN + exit 0 (Phase 7 continues).
#   - Deterministic: merged `runs` sorted alphabetically by tool.driver.name.
#   - Malformed SARIF input -> non-zero exit (schema validation surfaced).
#
# Test seams (tests/sarif-multitool-merge.bats):
#   SARIF_INPUT_DIR   input dir  (default .gaia/memory/brownfield-audit/sarif)
#   SARIF_MERGED_OUT  output file(default .gaia/artifacts/planning-artifacts/brownfield-sarif-merged.json)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="adapters/brownfield/sarif-merge.sh"
log_info() { printf 'INFO: %s: %s\n' "$SCRIPT_NAME" "$*"; }
log_warn() { printf 'WARNING: %s: %s\n' "$SCRIPT_NAME" "$*"; }
die()      { printf 'ERROR: %s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

# --- Flag gate ------------------------------------------------------------
MASTER="${GAIA_BROWNFIELD_DETERMINISTIC_TOOLS:-true}"
PER_TOOL="${GAIA_BROWNFIELD_SARIF_MERGE_ENABLED:-true}"
if [ "$MASTER" != "true" ] || [ "$PER_TOOL" != "true" ]; then
  log_info "SARIF merge skipped (flag-off: deterministic_tools=$MASTER sarif_merge_enabled=$PER_TOOL); 6-step recipe falls back to per-tool JSON"
  exit 0
fi

# --- Resolve paths --------------------------------------------------------
default_input_dir() {
  if [ -n "${GAIA_MEMORY_DIR:-}" ]; then printf '%s/brownfield-audit/sarif' "$GAIA_MEMORY_DIR"
  else printf '%s' "./.gaia/memory/brownfield-audit/sarif"; fi
}
default_merged_out() {
  if [ -n "${GAIA_ARTIFACTS_DIR:-}" ]; then printf '%s/planning-artifacts/brownfield-sarif-merged.json' "$GAIA_ARTIFACTS_DIR"
  else printf '%s' "./.gaia/artifacts/planning-artifacts/brownfield-sarif-merged.json"; fi
}
INPUT_DIR="${SARIF_INPUT_DIR:-$(default_input_dir)}"
MERGED_OUT="${SARIF_MERGED_OUT:-$(default_merged_out)}"

# --- Migration shim: no SARIF inputs -> fall back ------------------------
# Collect input files (nullglob-safe).
inputs=()
if [ -d "$INPUT_DIR" ]; then
  for f in "$INPUT_DIR"/*.sarif; do
    [ -e "$f" ] || continue
    inputs+=("$f")
  done
fi
if [ "${#inputs[@]}" -eq 0 ]; then
  log_warn "no SARIF inputs detected in $INPUT_DIR; falling back to per-tool JSON consumption (deprecation: 1 sprint)"
  exit 0
fi

# --- Graceful degrade: sarif CLI absent ----------------------------------
if ! command -v sarif >/dev/null 2>&1; then
  log_warn "Sarif.Multitool 'sarif' CLI not found on PATH; skipping merge (graceful degrade) — 6-step recipe falls back to per-tool JSON"
  exit 0
fi

# --- Merge ----------------------------------------------------------------
out_dir="$(dirname "$MERGED_OUT")"
out_file="$(basename "$MERGED_OUT")"
mkdir -p "$out_dir"

# `sarif merge` concatenates one `run` per input (preserving tool.driver.name).
# Propagate a non-zero exit (e.g. malformed input -> schema-validation error).
if ! sarif merge --output-directory "$out_dir" --output-file "$out_file" "${inputs[@]}"; then
  die "sarif merge failed (non-conformant input or CLI error)"
fi

# --- Path canonicalization (repo-root-relative URIs) ----------------------
# Scanners emit physicalLocation.artifactLocation.uri as absolute, file://, or
# already-relative. Downstream dedup (E104-S1) + reconciliation (E104-S2) assume
# repo-root-relative paths. Normalize every artifactLocation.uri: strip a
# leading `file://` scheme, then strip the repo-root prefix (REPO_ROOT, default
# $PWD) so the remainder is repo-root-relative. Already-relative uris pass through.
REPO_ROOT="${GAIA_REPO_ROOT:-$PWD}"
# Ensure a single trailing slash on the prefix we strip.
case "$REPO_ROOT" in */) ;; *) REPO_ROOT="$REPO_ROOT/" ;; esac
tmp_canon="$(mktemp)"
if jq --arg root "$REPO_ROOT" '
      def canon(u):
        (u | sub("^file://"; ""))            # drop file:// scheme
        | sub("^" + ($root | gsub("[.*+?(){}|^$\\[\\]\\\\]"; "\\\\\\(.)")); "")  # strip repo-root prefix (regex-escaped)
        | sub("^/"; "");                      # drop any residual leading slash
      walk(
        if type == "object" and has("uri") then .uri |= canon(.) else . end
      )
    ' "$MERGED_OUT" > "$tmp_canon" 2>/dev/null; then
  mv "$tmp_canon" "$MERGED_OUT"
else
  rm -f "$tmp_canon"
  die "post-merge jq path-canonicalization failed on $MERGED_OUT"
fi

# --- Deterministic ordering (alpha by driver name) ------------------------
# Sarif.Multitool does not guarantee run ordering; enforce it for reproducibility.
tmp="$(mktemp)"
if jq '.runs |= sort_by(.tool.driver.name)' "$MERGED_OUT" > "$tmp" 2>/dev/null; then
  mv "$tmp" "$MERGED_OUT"
else
  rm -f "$tmp"
  die "post-merge jq sort failed on $MERGED_OUT"
fi

run_count="$(jq -r '.runs | length' "$MERGED_OUT" 2>/dev/null || printf '0')"
finding_count="$(jq -r '[.runs[].results // [] | length] | add // 0' "$MERGED_OUT" 2>/dev/null || printf '0')"
log_info "merged $run_count scanner run(s), $finding_count finding(s) -> $MERGED_OUT (gap_count_before_dedup=$finding_count)"
# NOTE (AC-X3): gap_count_before_dedup = $finding_count is computed here at
# merge time (E104-S4-owned), but the report-frontmatter WRITER does not exist
# yet — population is deferred to the telemetry writer (E104-S1/S2). See Findings.

exit 0
