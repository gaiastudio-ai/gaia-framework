#!/usr/bin/env bash
# adapters/dead-code/go-deadcode/adapter.sh — Go dead-code adapter.
#
# Wraps golang.org/x/tools/cmd/deadcode (Rapid Type Analysis whole-program
# reachability — a BINARY verdict, zero false positives by construction). The
# adapter normalizes deadcode's reported position to a repo-root-relative
# file_path (the universal cross-stack JOIN key) and emits TWO outputs:
#   - flat normalized JSON   -> <out>/dead-code/go-deadcode.json   (report-rendering)
#   - a SARIF run            -> <out>/sarif/go-deadcode.sarif      (qualifier in
#       .properties.symbol so the dedup precision ladder applies).
# qualifier = "<package>.<Function>". severity = "warning". source_tool = "go-deadcode".
#
# Per-stack precision is the design intent: Go reports a binary reachability
# verdict — there is NO confidence score, and we do NOT synthesize one.
#
# Flag-gated: brownfield.deterministic_tools master + brownfield.deadcode_go_enabled
# per-tool (default true at this consumer layer). Graceful degrade: `go`
# absent OR no *.go files -> WARN/INFO + exit 0 (never aborts Phase 3).
#
# Test seams (tests/adapters/dead-code-go.bats):
#   DEADCODE_PROJECT_ROOT  repo to scan                       (default .)
#   DEADCODE_OUT_DIR       output root for dead-code/+sarif/  (default .gaia/memory/brownfield-audit)
#   DEADCODE_JSON_FIXTURE  pre-captured `deadcode -json` JSON (test seam; else runs deadcode)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="adapters/dead-code/go-deadcode/adapter.sh"
log_info() { printf 'INFO: %s: %s\n' "$SCRIPT_NAME" "$*"; }
log_warn() { printf 'WARNING: %s: %s\n' "$SCRIPT_NAME" "$*"; }

# --- Flag gate (deterministic_tools master + per-tool override) -----------
MASTER="${GAIA_BROWNFIELD_DETERMINISTIC_TOOLS:-true}"
PER_TOOL="${GAIA_BROWNFIELD_DEADCODE_GO_ENABLED:-true}"
if [ "$MASTER" != "true" ] || [ "$PER_TOOL" != "true" ]; then
  log_info "go-deadcode skipped (flag-off: deterministic_tools=$MASTER deadcode_go_enabled=$PER_TOOL)"
  exit 0
fi

ROOT="${DEADCODE_PROJECT_ROOT:-.}"
default_out() {
  if [ -n "${GAIA_MEMORY_DIR:-}" ]; then printf '%s/brownfield-audit' "$GAIA_MEMORY_DIR"
  else printf '%s' "./.gaia/memory/brownfield-audit"; fi
}
OUT="${DEADCODE_OUT_DIR:-$(default_out)}"

# --- Graceful degrade: toolchain / source absent --------------------------
if ! command -v go >/dev/null 2>&1; then
  log_warn "go toolchain absent — go-deadcode skipped (graceful degrade); Phase 3 continues"
  exit 0
fi
# Any *.go under the root? (no find-recursion cost beyond the scan itself).
if ! find "$ROOT" -type f -name '*.go' -print -quit 2>/dev/null | grep -q .; then
  log_info "no *.go files under $ROOT — go-deadcode no-op"
  exit 0
fi
command -v jq >/dev/null 2>&1 || { log_warn "jq not found — go-deadcode skipped"; exit 0; }

mkdir -p "$OUT/dead-code" "$OUT/sarif"

# --- Acquire deadcode JSON ------------------------------------------------
# deadcode -json emits an array of {name: "<pkg>.<Func>", posn: "<file>:<line>:<col>"}.
# The test seam supplies a captured payload; otherwise invoke the real binary in
# module-aware mode. We resolve posn -> repo-root-relative file_path below.
start=$(date +%s)
raw=""
# Probe the docker runner alongside the host-PATH check. The go-deadcode
# (golang.org/x/tools/cmd/deadcode) binary is NOT bundled in the gaia-tools
# image yet — Go's toolchain is heavier than the image's mission allows. When
# runner=docker we still fall through to host-PATH so a developer with Go
# installed can run the scan; when neither is present we INFO-degrade with a
# clear message pointing at the remediation. Mirrors the python-vulture wiring.
_DEADCODE_DOCKER_RUNNER=""
_DEADCODE_DOCKER_RUNNER_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../" && pwd)/lib/docker-runner.sh"
if [ -f "$_DEADCODE_DOCKER_RUNNER_LIB" ]; then
  . "$_DEADCODE_DOCKER_RUNNER_LIB"
  if [ "$(docker_runner_mode 2>/dev/null)" = "docker" ] && docker_runner_available >/dev/null 2>&1; then
    _DEADCODE_DOCKER_RUNNER="docker"
  fi
fi

if [ -n "${DEADCODE_JSON_FIXTURE:-}" ] && [ -f "$DEADCODE_JSON_FIXTURE" ]; then
  raw="$(cat "$DEADCODE_JSON_FIXTURE")"
elif [ "$_DEADCODE_DOCKER_RUNNER" = "docker" ] && docker_runner_dispatch deadcode -h >/dev/null 2>&1; then
  # The image bundles deadcode (added in a later cycle); dispatch through it.
  raw="$( docker_runner_dispatch deadcode -json ./... 2>/dev/null || printf '[]' )"
elif command -v deadcode >/dev/null 2>&1; then
  raw="$( cd "$ROOT" && GO111MODULE=on deadcode -json ./... 2>/dev/null || printf '[]' )"
else
  if [ "$_DEADCODE_DOCKER_RUNNER" = "docker" ]; then
    log_warn "deadcode binary absent (runner=docker; gaia-tools image does not yet bundle deadcode) — go-deadcode skipped (graceful degrade); install via 'go install golang.org/x/tools/cmd/deadcode@latest'"
  else
    log_warn "deadcode binary absent — go-deadcode skipped (graceful degrade)"
  fi
  exit 0
fi
[ -n "$raw" ] || raw='[]'

# --- Normalize -> flat JSON ------------------------------------------------
# file_path = posn with trailing :line:col stripped (already repo-root-relative
# under module-aware invocation from the module root).
# qualifier = "<short-package>.<Function>": deadcode's `name` carries the FULL
# import path (e.g. example.com/mod/unused_pkg.UnusedFunc); strip everything up
# to the last '/' to yield the short-package-qualified name the AC specifies.
findings="$(printf '%s' "$raw" | jq -c '
  [ .[] | {
      file_path: (.posn | sub(":[0-9]+:[0-9]+$"; "")),
      qualifier: (.name | sub("^.*/"; "")),
      severity: "warning",
      source_tool: "go-deadcode"
    } ]
' 2>/dev/null || printf '[]')"
printf '%s\n' "$findings" > "$OUT/dead-code/go-deadcode.json"

# --- SARIF (feeds the dedup precision ladder) -----------------------------
printf '%s' "$findings" | jq '{
  version: "2.1.0",
  "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
  runs: [ {
    tool: { driver: { name: "go-deadcode", rules: [] } },
    results: [ .[] | {
      ruleId: "dead-code/go",
      level: "warning",
      message: { text: ("unused: " + .qualifier) },
      locations: [ { physicalLocation: { artifactLocation: { uri: .file_path } } } ],
      properties: { symbol: .qualifier, source_tool: "go-deadcode" }
    } ]
  } ]
}' > "$OUT/sarif/go-deadcode.sarif"

seconds=$(( $(date +%s) - start ))
count="$(printf '%s' "$findings" | jq 'length')"
log_info "go-deadcode: $count dead symbol(s); file_path JOIN key emitted; runtime=${seconds}s"

# --- Telemetry (single-author per field: deadcode_go) ---------------------
REPORT="${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/planning-artifacts/consolidated-gaps.md"
TELEM="$(cd "$(dirname "$0")/../../brownfield" 2>/dev/null && pwd)/brownfield-telemetry.sh"
if [ -f "$REPORT" ] && [ -x "$TELEM" ]; then
  bash "$TELEM" --report "$REPORT" --field phase_runtime_seconds.deadcode_go --value "$seconds" || true
  bash "$TELEM" --report "$REPORT" --field deterministic_tool_seconds.deadcode_go --value "$seconds" || true
  bash "$TELEM" --report "$REPORT" --field llm_token_count --value 0 || true
fi

exit 0
