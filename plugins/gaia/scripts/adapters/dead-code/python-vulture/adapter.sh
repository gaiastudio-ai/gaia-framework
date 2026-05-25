#!/usr/bin/env bash
# adapters/dead-code/python-vulture/adapter.sh — E70-S8 Python dead-code adapter.
#
# Wraps `vulture --min-confidence 80 <root>`. vulture is CONFIDENCE-scored (not a
# binary verdict): the per-stack qualifier carries the confidence verbatim —
# "<line>:<symbol>@<confidence>". Per-stack precision is the design intent (NFR-87);
# we do NOT normalize vulture's confidence onto a synthesized cross-stack scale.
#
# Emits TWO outputs:
#   - flat JSON  -> <out>/dead-code/python-vulture.json  (AC2/AC4)
#   - SARIF      -> <out>/sarif/python-vulture.sarif      (.properties.symbol; dedup, Val F1)
# file_path = repo-relative path from vulture output (universal JOIN key).
#
# vulture's own --min-confidence 80 filters sub-threshold findings BEFORE we parse,
# so the adapter emits exactly what vulture surfaces (the 70% case never appears).
#
# Flag-gated (ADR-078): deterministic_tools master + deadcode_python_enabled per-tool.
# Graceful degrade (NFR-84): vulture absent OR no *.py -> WARN/INFO + exit 0.
#
# Test seams (tests/adapters/dead-code-python.bats):
#   PY_PROJECT_ROOT     repo to scan
#   PY_OUT_DIR          output root
#   PY_VULTURE_FIXTURE  pre-captured vulture stdout (test seam; else runs vulture)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="adapters/dead-code/python-vulture/adapter.sh"
log_info() { printf 'INFO: %s: %s\n' "$SCRIPT_NAME" "$*"; }
log_warn() { printf 'WARNING: %s: %s\n' "$SCRIPT_NAME" "$*"; }

MASTER="${GAIA_BROWNFIELD_DETERMINISTIC_TOOLS:-true}"
PER_TOOL="${GAIA_BROWNFIELD_DEADCODE_PYTHON_ENABLED:-true}"
if [ "$MASTER" != "true" ] || [ "$PER_TOOL" != "true" ]; then
  log_info "python-vulture skipped (flag-off: deterministic_tools=$MASTER deadcode_python_enabled=$PER_TOOL)"
  exit 0
fi

ROOT="${PY_PROJECT_ROOT:-.}"
default_out() {
  if [ -n "${GAIA_MEMORY_DIR:-}" ]; then printf '%s/brownfield-audit' "$GAIA_MEMORY_DIR"
  else printf '%s' "./.gaia/memory/brownfield-audit"; fi
}
OUT="${PY_OUT_DIR:-$(default_out)}"

if ! command -v vulture >/dev/null 2>&1; then
  log_warn "vulture toolchain absent — python-vulture skipped (graceful degrade); Phase 3 continues"
  exit 0
fi
if ! find "$ROOT" -type f -name '*.py' -print -quit 2>/dev/null | grep -q .; then
  log_info "no *.py files under $ROOT — python-vulture no-op"
  exit 0
fi
command -v jq >/dev/null 2>&1 || { log_warn "jq not found — python-vulture skipped"; exit 0; }

mkdir -p "$OUT/dead-code" "$OUT/sarif"

start=$(date +%s)
raw=""
if [ -n "${PY_VULTURE_FIXTURE:-}" ] && [ -f "$PY_VULTURE_FIXTURE" ]; then
  raw="$(cat "$PY_VULTURE_FIXTURE")"
else
  # vulture exits non-zero when it finds dead code; tolerate via `|| true`.
  raw="$( vulture --min-confidence 80 "$ROOT" 2>/dev/null || true )"
fi

# --- Parse: "<file>:<line>: unused <kind> '<symbol>' (<confidence>% confidence)"
# Robust parse via a single regex through jq's capture (NOT awk -F: — file paths
# can contain colons on some platforms). Lines that don't match are skipped.
findings="$(printf '%s\n' "$raw" | jq -R -s -c '
  [ split("\n")[]
    | select(length > 0)
    | capture("^(?<file>.+):(?<line>[0-9]+): unused (?<kind>[a-z ]+) '"'"'(?<symbol>[^'"'"']+)'"'"' \\((?<conf>[0-9]+)% confidence\\)$")
    | {
        file_path: .file,
        qualifier: (.line + ":" + .symbol + "@" + .conf),
        severity: "warning",
        source_tool: "python-vulture"
      }
  ]
' 2>/dev/null || printf '[]')"
[ -n "$findings" ] || findings='[]'
printf '%s\n' "$findings" > "$OUT/dead-code/python-vulture.json"

printf '%s' "$findings" | jq '{
  version: "2.1.0",
  "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
  runs: [ {
    tool: { driver: { name: "python-vulture", rules: [] } },
    results: [ .[] | {
      ruleId: "dead-code/python",
      level: "warning",
      message: { text: ("unused: " + .qualifier) },
      locations: [ { physicalLocation: { artifactLocation: { uri: .file_path } } } ],
      properties: { symbol: .qualifier, source_tool: "python-vulture" }
    } ]
  } ]
}' > "$OUT/sarif/python-vulture.sarif"

seconds=$(( $(date +%s) - start ))
count="$(printf '%s' "$findings" | jq 'length')"
log_info "python-vulture: $count dead symbol(s) (>=80% confidence); file_path JOIN key emitted; runtime=${seconds}s"

REPORT="${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/planning-artifacts/consolidated-gaps.md"
TELEM="$(cd "$(dirname "$0")/../../brownfield" 2>/dev/null && pwd)/brownfield-telemetry.sh"
if [ -f "$REPORT" ] && [ -x "$TELEM" ]; then
  bash "$TELEM" --report "$REPORT" --field phase_runtime_seconds.deadcode_python --value "$seconds" || true
  bash "$TELEM" --report "$REPORT" --field deterministic_tool_seconds.deadcode_python --value "$seconds" || true
  bash "$TELEM" --report "$REPORT" --field llm_token_count --value 0 || true
fi

exit 0
