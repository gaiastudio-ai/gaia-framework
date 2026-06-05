#!/usr/bin/env bash
# adapters/brownfield/sarif-merge.sh — SARIF Multitool merge pre-step.
#
# Merges all scanner SARIF outputs (Grype, Semgrep, CodeQL, gitleaks, gosec,
# SpotBugs) into a single merged SARIF so the existing 6-step gap-consolidation
# recipe consumes ONE uniform interchange format instead of bespoke per-tool
# JSON. Downstream dedup operates on the merge.
#
# Contract:
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
# Collect input files (nullglob-safe), filtering out empty / non-conformant
# files BEFORE staging (issue-1389). A single 0-byte or invalid-JSON .sarif
# would otherwise NullRef Sarif.Multitool and abort the ENTIRE merge, dropping
# all deterministic findings (grype CVE + dead-code). The dominant trigger is
# the 0-byte spotbugs.sarif emitted on non-JVM projects (issue-1390). Skip any
# input failing the non-empty (`-s`) OR JSON-validity (`jq -e .`) check, log
# each skip as INFO, and merge the remaining valid inputs.
inputs=()
if [ -d "$INPUT_DIR" ]; then
  for f in "$INPUT_DIR"/*.sarif; do
    [ -e "$f" ] || continue
    if [ ! -s "$f" ]; then
      log_info "skipping empty SARIF input: $f (0 bytes)"
      continue
    fi
    if ! jq -e . "$f" >/dev/null 2>&1; then
      log_info "skipping non-conformant SARIF input: $f (invalid JSON)"
      continue
    fi
    inputs+=("$f")
  done
fi
if [ "${#inputs[@]}" -eq 0 ]; then
  log_warn "no SARIF inputs detected in $INPUT_DIR; falling back to per-tool JSON consumption (deprecation: 1 sprint)"
  exit 0
fi

# --- Graceful degrade: sarif CLI absent ----------------------------------
# Probe the docker runner as a fallback when the host PATH doesn't carry
# `sarif`. The gaia-tools image bundles Microsoft.Sarif.Multitool — so when
# `brownfield.tools.runner: docker` is set the merge step now runs via
# `docker_runner_dispatch sarif merge ...` instead of degrading. Without this
# fix the Phase-7 pipeline (grype SARIF → merge → dedup → reconcile) was
# inert on docker-runner hosts — the grype SARIF was never merged so dedup
# got an empty stream.
_SARIF_DOCKER_RUNNER=""
_SARIF_DOCKER_RUNNER_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/docker-runner.sh"
if [ -f "$_SARIF_DOCKER_RUNNER_LIB" ]; then
  . "$_SARIF_DOCKER_RUNNER_LIB"
  if [ "$(docker_runner_mode 2>/dev/null)" = "docker" ] && docker_runner_available >/dev/null 2>&1; then
    _SARIF_DOCKER_RUNNER="docker"
  fi
fi

if [ -z "$_SARIF_DOCKER_RUNNER" ] && ! command -v sarif >/dev/null 2>&1; then
  log_warn "Sarif.Multitool 'sarif' CLI not found on PATH and runner != docker; skipping merge (graceful degrade) — 6-step recipe falls back to per-tool JSON"
  exit 0
fi

# --- Merge ----------------------------------------------------------------
out_dir="$(dirname "$MERGED_OUT")"
out_file="$(basename "$MERGED_OUT")"
mkdir -p "$out_dir"

# `sarif merge` concatenates one `run` per input (preserving tool.driver.name).
# Propagate a non-zero exit (e.g. malformed input -> schema-validation error).
#
# Properly stage inputs into the mounted /out before calling `sarif merge`
# so the container actually sees them. The container has /workspace
# (PROJECT_ROOT:ro) and /out (ADAPTER_OUT_DIR) mounted, but the host paths
# (typically `.gaia/memory/brownfield-audit/sarif/*.sarif`) are not at
# either mount, so the merge silently saw 0 inputs and wrote `runs: []`.
# Stage each host input as `/out/.merge-in/<basename>` so the merge sees
# real files at container-visible paths, then clean up the staging dir
# after the merge completes. The output still lands at /out/<out_file>.
#
# Pass a `--force`-equivalent flag so a re-run overwrites an existing merged
# file. `sarif merge` defaults to refuse-on-exist; brownfield Phase 7 can
# re-run (resume, retries), so non-idempotent behaviour breaks the workflow.
if [ "$_SARIF_DOCKER_RUNNER" = "docker" ]; then
  _stage_dir="$out_dir/.merge-in-$$"
  mkdir -p "$_stage_dir" 2>/dev/null || true
  _container_inputs=()
  _stage_idx=0
  for _src in "${inputs[@]}"; do
    [ -f "$_src" ] || continue
    _stage_idx=$((_stage_idx + 1))
    _staged="$_stage_dir/$(printf '%04d-%s' "$_stage_idx" "$(basename "$_src")")"
    cp "$_src" "$_staged" 2>/dev/null || continue
    # docker-runner mounts ADAPTER_OUT_DIR (= $out_dir) at /out, so the
    # container path is /out/.merge-in-$$/<file>.
    _container_inputs+=("/out/.merge-in-$$/$(basename "$_staged")")
  done
  if [ "${#_container_inputs[@]}" -eq 0 ]; then
    log_warn "sarif merge: no readable inputs to stage; merged output will be empty"
    rm -rf "$_stage_dir" 2>/dev/null || true
  else
    # Sarif.Multitool 5.0.2 has NO `--force` flag (the attempt failed live:
    # CLI parser printed help + exit 1, so the merge silently died and
    # downstream `consolidated-gaps.md` saw 0 deterministic findings).
    # Verified-working invocation form:
    #   sarif merge <inputs...> --output-directory ... --output-file ... \
    #       --log ForceOverwrite --merge-empty-logs
    # Three changes vs the broken form:
    #   1. Inputs go FIRST (positional argument; options-before-positionals
    #      mis-binds the <files> positional on the Sarif.Multitool parser).
    #   2. `--force` → `--log ForceOverwrite` (canonical Sarif.Multitool
    #      overwrite knob; preserves idempotency intent).
    #   3. `--merge-empty-logs` is passed but Sarif.Multitool 5.0.2 drops
    #      runs whose results[] is empty regardless of this flag (verified
    #      live). The flag is retained for forward-compatibility with future
    #      Sarif.Multitool versions that may honor it, but callers MUST NOT
    #      rely on clean-scan tool provenance reaching the merged SARIF — a
    #      passing deterministic scan currently merges as `runs:[]` (zero
    #      runs). REAL findings survive merge (a run with results[] non-empty
    #      IS preserved — verified with a synthetic SARIF containing one
    #      finding). Phase-7 grading uses the `grype_db_checksum` provenance
    #      field (independent of merged runs[]) so the practical impact on
    #      consolidated-gaps grading is bounded to clean-scan tool attribution
    #      loss, not real-finding loss.
    rm -f "$out_dir/$out_file" 2>/dev/null || true
    if ! ADAPTER_OUT_DIR="$out_dir" \
        docker_runner_dispatch sarif merge \
          "${_container_inputs[@]}" \
          --output-directory "/out" --output-file "$out_file" \
          --log ForceOverwrite --merge-empty-logs; then
      rm -rf "$_stage_dir" 2>/dev/null || true
      die "sarif merge (docker) failed (non-conformant input or CLI error)"
    fi
    rm -rf "$_stage_dir" 2>/dev/null || true
  fi
else
  # Same invocation fix applied to the native branch.
  rm -f "$out_dir/$out_file" 2>/dev/null || true
  if ! sarif merge "${inputs[@]}" \
        --output-directory "$out_dir" --output-file "$out_file" \
        --log ForceOverwrite --merge-empty-logs; then
    die "sarif merge failed (non-conformant input or CLI error)"
  fi
fi

# --- Path canonicalization (repo-root-relative URIs) ----------------------
# Scanners emit physicalLocation.artifactLocation.uri as absolute, file://, or
# already-relative. Downstream dedup and reconciliation assume repo-root-relative
# paths. Normalize every artifactLocation.uri: strip a
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
# NOTE: gap_count_before_dedup = $finding_count is computed here at merge time,
# but the report-frontmatter WRITER does not exist yet — population is deferred
# to the telemetry writer. See Findings.

exit 0
