#!/usr/bin/env bash
# adapters/dead-code/jvm-spotbugs/adapter.sh — JVM dead-code adapter.
#
# Wraps SpotBugs `-xml -output <tmp>`, then filters BugInstance elements to
# priority=1 AND rank<=4 — a conservative "proven-dead-equivalent" default
# (UPM, NP_GUARANTEED_DEREF, and equivalent dead-code-adjacent detectors). JVM
# precision is an ordinal (priority x rank), NOT a confidence percentage; the
# qualifier preserves the SpotBugs method signature verbatim (per-stack
# precision — no synthesized cross-stack score).
#
# Emits TWO outputs:
#   - flat JSON  -> <out>/dead-code/jvm-spotbugs.json
#   - SARIF      -> <out>/sarif/jvm-spotbugs.sarif       (.properties.symbol; dedup)
# file_path = BugInstance SourceLine/@sourcepath (repo-relative; universal JOIN key).
# qualifier = "<FQCN>.<method>(<signature>)".
#
# XML parsed with awk (xmlstarlet NOT assumed — same convention as the SBOM/lock
# parsers). The SpotBugs XML is well-formed single-line-per-element in practice;
# the awk state machine tolerates attribute order.
#
# Flag-gated: deterministic_tools master + deadcode_jvm_enabled per-tool.
# Graceful degrade: spotbugs absent OR no *.java/*.class -> WARN/INFO + exit 0.
#
# Test seams (tests/adapters/dead-code-jvm.bats):
#   JVM_PROJECT_ROOT     repo to scan
#   JVM_OUT_DIR          output root
#   JVM_SPOTBUGS_FIXTURE pre-captured SpotBugs -xml output (test seam; else runs spotbugs)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="adapters/dead-code/jvm-spotbugs/adapter.sh"
log_info() { printf 'INFO: %s: %s\n' "$SCRIPT_NAME" "$*"; }
log_warn() { printf 'WARNING: %s: %s\n' "$SCRIPT_NAME" "$*"; }

MASTER="${GAIA_BROWNFIELD_DETERMINISTIC_TOOLS:-true}"
PER_TOOL="${GAIA_BROWNFIELD_DEADCODE_JVM_ENABLED:-true}"
if [ "$MASTER" != "true" ] || [ "$PER_TOOL" != "true" ]; then
  log_info "jvm-spotbugs skipped (flag-off: deterministic_tools=$MASTER deadcode_jvm_enabled=$PER_TOOL)"
  exit 0
fi

ROOT="${JVM_PROJECT_ROOT:-.}"
default_out() {
  if [ -n "${GAIA_MEMORY_DIR:-}" ]; then printf '%s/brownfield-audit' "$GAIA_MEMORY_DIR"
  else printf '%s' "./.gaia/memory/brownfield-audit"; fi
}
OUT="${JVM_OUT_DIR:-$(default_out)}"

# --- Runner resolution -------------------
# When brownfield.tools.runner == docker, prefer the bundled gaia-tools
# OCI image — operators no longer need a JVM + spotbugs JAR locally.
_SB_SCRIPTS_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../../../lib/docker-runner.sh
. "${_SB_SCRIPTS_DIR}/lib/docker-runner.sh"

_SB_RUNNER_MODE="$(docker_runner_mode)"
if [ "$_SB_RUNNER_MODE" = "docker" ] && docker_runner_available >/dev/null 2>&1; then
  log_info "dispatching spotbugs via gaia-tools docker runner (image: $(docker_runner_image))"
  mkdir -p "$OUT/dead-code" "$OUT/sarif"
  export ADAPTER_OUT_DIR="$OUT/sarif"
  # The bundled spotbugs entrypoint in gaia-tools accepts -sarif and
  # writes findings to /out/spotbugs.sarif inside the container, which
  # surfaces at $ADAPTER_OUT_DIR/spotbugs.sarif on the host.
  if docker_runner_dispatch spotbugs -textui -sarif -output /out/spotbugs.sarif /workspace; then
    log_info "spotbugs docker dispatch complete — SARIF at $ADAPTER_OUT_DIR/spotbugs.sarif"
    exit 0
  fi
  rc=$?
  if [ "$rc" -eq 125 ]; then
    log_warn "docker runner unavailable (exit 125) — falling through to native dispatch"
  else
    log_warn "spotbugs docker dispatch failed (exit $rc) — falling through to native dispatch"
  fi
fi

if ! command -v spotbugs >/dev/null 2>&1; then
  log_warn "spotbugs toolchain absent — jvm-spotbugs skipped (graceful degrade); Phase 3 continues"
  exit 0
fi
if ! find "$ROOT" -type f \( -name '*.java' -o -name '*.class' \) -print -quit 2>/dev/null | grep -q .; then
  log_info "no *.java/*.class files under $ROOT — jvm-spotbugs no-op"
  exit 0
fi
command -v jq >/dev/null 2>&1 || { log_warn "jq not found — jvm-spotbugs skipped"; exit 0; }

mkdir -p "$OUT/dead-code" "$OUT/sarif"

start=$(date +%s)
xml_tmp="$(mktemp)"
trap 'rm -f "$xml_tmp"' EXIT

if [ -n "${JVM_SPOTBUGS_FIXTURE:-}" ] && [ -f "$JVM_SPOTBUGS_FIXTURE" ]; then
  cat "$JVM_SPOTBUGS_FIXTURE" > "$xml_tmp"
else
  spotbugs -textui -xml -output "$xml_tmp" "$ROOT" >/dev/null 2>&1 || true
fi

# --- Parse BugInstance -> NDJSON, filter priority=1 AND rank<=4 -------------
# awk state machine: each BugInstance opens; capture its priority/rank, the
# Method (classname/name/signature), and the SourceLine sourcepath; on close,
# emit a tab-separated row if it passes the filter. attr() pulls attr="val".
ndjson="$(awk '
  # attr(): pull attr="val". The regex requires a word boundary (start-of-string
  # or a non-word char) BEFORE the attribute name so a short name like "name"
  # does NOT match inside a longer one like "classname=" (SpotBugs Method element
  # carries both classname= and name=).
  function attr(line, name,   re, s) {
    re = "(^|[^A-Za-z_])" name "=\"[^\"]*\""
    if (match(line, re)) {
      s = substr(line, RSTART, RLENGTH)
      sub("^.*" name "=\"", "", s); sub("\"$", "", s); return s
    }
    return ""
  }
  /<BugInstance/ { inbug=1; pr=attr($0,"priority"); rk=attr($0,"rank"); cls=""; meth=""; sig=""; path="" }
  inbug && /<Method/ {
    if (meth=="") { mcls=attr($0,"classname"); meth=attr($0,"name"); sig=attr($0,"signature") ; if (cls=="") cls=mcls }
  }
  inbug && /<Class / { if (cls=="") cls=attr($0,"classname") }
  inbug && /<SourceLine/ { if (path=="") path=attr($0,"sourcepath") }
  /<\/BugInstance>/ {
    inbug=0
    if (pr=="1" && rk!="" && rk+0<=4 && cls!="" && meth!="" && path!="") {
      printf "%s\t%s.%s%s\n", path, cls, meth, sig
    }
  }
' "$xml_tmp")"

# Build the flat JSON array from the TSV rows.
findings='[]'
if [ -n "$ndjson" ]; then
  findings="$(printf '%s\n' "$ndjson" | jq -R -s -c '
    [ split("\n")[] | select(length>0) | split("\t") | {
        file_path: .[0],
        qualifier: .[1],
        severity: "warning",
        source_tool: "jvm-spotbugs"
      } ]
  ' 2>/dev/null || printf '[]')"
fi
printf '%s\n' "$findings" > "$OUT/dead-code/jvm-spotbugs.json"

printf '%s' "$findings" | jq '{
  version: "2.1.0",
  "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
  runs: [ {
    tool: { driver: { name: "jvm-spotbugs", rules: [] } },
    results: [ .[] | {
      ruleId: "dead-code/jvm",
      level: "warning",
      message: { text: ("unused: " + .qualifier) },
      locations: [ { physicalLocation: { artifactLocation: { uri: .file_path } } } ],
      properties: { symbol: .qualifier, source_tool: "jvm-spotbugs" }
    } ]
  } ]
}' > "$OUT/sarif/jvm-spotbugs.sarif"

seconds=$(( $(date +%s) - start ))
count="$(printf '%s' "$findings" | jq 'length')"
log_info "jvm-spotbugs: $count finding(s) (priority=1 rank<=4); file_path JOIN key emitted; runtime=${seconds}s"

REPORT="${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/planning-artifacts/consolidated-gaps.md"
TELEM="$(cd "$(dirname "$0")/../../brownfield" 2>/dev/null && pwd)/brownfield-telemetry.sh"
if [ -f "$REPORT" ] && [ -x "$TELEM" ]; then
  bash "$TELEM" --report "$REPORT" --field phase_runtime_seconds.deadcode_jvm --value "$seconds" || true
  bash "$TELEM" --report "$REPORT" --field deterministic_tool_seconds.deadcode_jvm --value "$seconds" || true
  bash "$TELEM" --report "$REPORT" --field llm_token_count --value 0 || true
fi

exit 0
