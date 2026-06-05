#!/usr/bin/env bash
# adapters/brownfield/dedup.sh — cross-tool finding dedup (dual keys).
#
# Reads the merged SARIF and emits a deduplicated finding stream so downstream
# consumers see one finding per real issue instead of 2-4x inflated counts.
#
# Dual dedup keys:
#   CVE class (ruleId ~ ^CVE-\d{4}-\d{4,}$):
#     group (CVE-ID, file_path, severity); winner = lowest source_tool ordinal
#     (grype=0, osv-scanner=1, owasp-depcheck=2 — Grype canonical).
#   Non-CVE class:
#     group (file_path, symbol-qualifier); winner = highest precision per the
#     ladder (deadcode-go=0 > spotbugs=1 > vulture=2 > lint=3 > unknown=99).
#     NOTE: The literal key is (tool, file, qualifier), but tool-inclusive
#     grouping makes the precision ladder unreachable — implemented per intent
#     (group file+qualifier, tool drives precision).
#
# Pure bash + jq (no external binary). Exit 0 on the happy and degrade paths;
# the deduped array (possibly empty) is always written.
#
# Test seams (tests/dedup-contract.bats):
#   DEDUP_INPUT   merged-SARIF path  (default: brownfield-sarif-merged.json under GAIA_ARTIFACTS_DIR)
#   DEDUP_OUTPUT  deduped-stream path(default: GAIA_MEMORY_DIR/brownfield-audit/deduped-findings.json)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="adapters/brownfield/dedup.sh"
log_info() { printf 'INFO: %s: %s\n' "$SCRIPT_NAME" "$*"; }
log_warn() { printf 'WARNING: %s: %s\n' "$SCRIPT_NAME" "$*"; }

# --- Flag gate ------------------------------------------------------------
MASTER="${GAIA_BROWNFIELD_DETERMINISTIC_TOOLS:-true}"
# Per-tool override defaults to true (dedup is on by default).
PER_TOOL="${GAIA_BROWNFIELD_DEDUP_ENABLED:-true}"

# --- Resolve paths --------------------------------------------------------
default_input() {
  if [ -n "${GAIA_ARTIFACTS_DIR:-}" ]; then printf '%s/planning-artifacts/brownfield-sarif-merged.json' "$GAIA_ARTIFACTS_DIR"
  else printf '%s' "./.gaia/artifacts/planning-artifacts/brownfield-sarif-merged.json"; fi
}
default_output() {
  if [ -n "${GAIA_MEMORY_DIR:-}" ]; then printf '%s/brownfield-audit/deduped-findings.json' "$GAIA_MEMORY_DIR"
  else printf '%s' "./.gaia/memory/brownfield-audit/deduped-findings.json"; fi
}
INPUT="${DEDUP_INPUT:-$(default_input)}"
OUTPUT="${DEDUP_OUTPUT:-$(default_output)}"
mkdir -p "$(dirname "$OUTPUT")"

# Flatten merged-SARIF runs[].results[] into a uniform finding stream:
#   {ruleId, file_path, severity, source_tool, qualifier}
flatten() {
  jq '[ .runs[]? as $r | ($r.results[]? |
        { ruleId: .ruleId,
          file_path: (.locations[0].physicalLocation.artifactLocation.uri // ""),
          severity: (.properties.severity // .level // ""),
          source_tool: ($r.tool.driver.name // ""),
          qualifier: (.properties.symbol // ""),
          start_line: (.locations[0].physicalLocation.region.startLine // null) }) ]' "$INPUT"
}

# --- Flag-off / missing-input passthrough ---------------------------------
if [ "$MASTER" != "true" ] || [ "$PER_TOOL" != "true" ]; then
  log_info "dedup skipped (flag-off: deterministic_tools=$MASTER dedup_enabled=$PER_TOOL); raw stream passes through (gap_count_before==after)"
  if [ -f "$INPUT" ]; then flatten > "$OUTPUT"; else printf '[]\n' > "$OUTPUT"; fi
  exit 0
fi

if [ ! -f "$INPUT" ]; then
  log_warn "merged SARIF not found at $INPUT; emitting empty deduped stream (counters 0)"
  printf '[]\n' > "$OUTPUT"
  exit 0
fi

# --- Dedup (pure jq) ------------------------------------------------------
# CVE-class: group (ruleId, file_path, severity); winner = min source_tool ordinal.
# Non-CVE:   group (file_path, qualifier);        winner = min precision rank.
findings="$(flatten)"
before="$(printf '%s' "$findings" | jq 'length')"

deduped="$(printf '%s' "$findings" | jq '
  def cve_ord:
    { "grype":0, "osv-scanner":1, "owasp-depcheck":2 }[.] // 99;
  def prec_rank:
    { "deadcode-go":0, "spotbugs":1, "vulture":2, "lint":3 }[.] // 99;
  def is_cve: (.ruleId // "") | test("^CVE-[0-9]{4}-[0-9]{4,}$");

  ( [ .[] | select(is_cve) ]
    | group_by([.ruleId, .file_path, .severity])
    | map( sort_by(.source_tool | cve_ord) | .[0] ) ) as $cve
  |
  # Non-CVE grouping key: (file_path, qualifier) when a symbol is present;
  # when the qualifier is empty (line-located lint/complexity findings with no
  # symbol), fall back to (file_path, ruleId, start_line) so two genuinely
  # distinct symbol-less findings in the same file do NOT over-dedup.
  ( [ .[] | select(is_cve | not) ]
    | group_by(
        if (.qualifier // "") == ""
        then [.file_path, "", .ruleId, (.start_line | tostring)]
        else [.file_path, .qualifier]
        end )
    | map( sort_by(.source_tool | prec_rank) | .[0] ) ) as $noncve
  |
  ($cve + $noncve)
')"

printf '%s\n' "$deduped" > "$OUTPUT"
after="$(printf '%s' "$deduped" | jq 'length')"
log_info "dedup: $before raw finding(s) -> $after deduped (gap_count_before_dedup=$before gap_count_after_dedup=$after) -> $OUTPUT"

exit 0
