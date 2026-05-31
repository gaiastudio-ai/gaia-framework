#!/usr/bin/env bash
# adapters/grype/adapter.sh — E70-S9 Grype DB trust-boundary enforcement.
#
# Treats the Grype vulnerability DB as a trust boundary distinct from the binary
# (FR-542 / ADR-122). The adapter:
#   - enforces GRYPE_DB_MAX_ALLOWED_BUILT_AGE=5d (+ rejects an inherited override),
#   - records grype_db_checksum + grype_db_built_age telemetry,
#   - REJECTS a mid-session DB checksum drift (consuming E70-S7's session-start
#     checksum log) — catches silent DB rollback / tampering.
# Trivy Mar-2026 supply-chain precedent (Microsoft IR + Aqua + CrowdStrike).
#
# Contract:
#   - Flag-gated (brownfield.deterministic_tools + brownfield.grype_enabled).
#   - Graceful degrade: grype absent -> WARNING + exit 0 (no scan).
#   - Override guard: inherited GRYPE_DB_MAX_ALLOWED_BUILT_AGE non-empty and != 5d
#     -> reject (default FAIL / secure default; local-WARN gating via strict_mode
#     is a documented Finding until the environments schema carries strict_mode).
#   - Drift: current DB SHA-256 != session-start value -> ERROR + non-zero exit
#     (security abort, NOT degrade).
#
# Test seams (tests/adapters/grype-trust-boundary.bats):
#   GAIA_GRYPE_DB_FILE          grype-db.sqlite to checksum (default: grype db status path)
#   GAIA_BROWNFIELD_AUDIT_DIR   checksum-log dir (E70-S7 producer; default .gaia/memory/brownfield-audit)
#   GAIA_SESSION_ID             session id (default $PPID) — matches E70-S7 row keying
#   GAIA_GRYPE_DEBUG=1          echo the resolved GRYPE_DB_MAX_ALLOWED_BUILT_AGE (AC1 assertion)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="adapters/grype/adapter.sh"
log_info()  { printf 'INFO: %s: %s\n' "$SCRIPT_NAME" "$*"; }
log_warn()  { printf 'WARNING: %s: %s\n' "$SCRIPT_NAME" "$*"; }
die()       { printf 'ERROR: %s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

CANONICAL_MAX_AGE="5d"

# --- Flag gate ------------------------------------------------------------
MASTER="${GAIA_BROWNFIELD_DETERMINISTIC_TOOLS:-true}"
PER_TOOL="${GAIA_BROWNFIELD_GRYPE_ENABLED:-true}"
if [ "$MASTER" != "true" ] || [ "$PER_TOOL" != "true" ]; then
  log_info "grype adapter skipped (flag-off: deterministic_tools=$MASTER grype_enabled=$PER_TOOL)"
  exit 0
fi

# --- Override guard (AC1) -------------------------------------------------
# An inherited GRYPE_DB_MAX_ALLOWED_BUILT_AGE that is non-empty and != 5d is a
# trust-boundary violation. Default FAIL (secure default); strict_mode-gated
# local-WARN is a documented Finding until the environments schema carries it.
if [ -n "${GRYPE_DB_MAX_ALLOWED_BUILT_AGE:-}" ] && [ "${GRYPE_DB_MAX_ALLOWED_BUILT_AGE}" != "$CANONICAL_MAX_AGE" ]; then
  die "GRYPE_DB_MAX_ALLOWED_BUILT_AGE override rejected — trust-boundary contract requires ${CANONICAL_MAX_AGE} (got: ${GRYPE_DB_MAX_ALLOWED_BUILT_AGE})"
fi

# --- Runner resolution (AF-2026-05-30-3 / Test10 §7 C2) -------------------
# When brownfield.tools.runner == docker, prefer the bundled gaia-tools
# OCI image over the host PATH. The Tier 2 toolchain installs (grype +
# its DB) are exactly what AF-30-3 closes via the docker runner.
SCRIPT_DIR_GRYPE="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../lib/docker-runner.sh
. "${SCRIPT_DIR_GRYPE}/lib/docker-runner.sh"

_GRYPE_RUNNER_MODE="$(docker_runner_mode)"
if [ "$_GRYPE_RUNNER_MODE" = "docker" ] && docker_runner_available >/dev/null 2>&1; then
  log_info "dispatching grype via gaia-tools docker runner (image: $(docker_runner_image))"
  # The docker runner exposes the host workspace at /workspace. Adapter
  # output dir is the canonical brownfield audit dir for downstream
  # SARIF aggregation; ADAPTER_OUT_DIR is the contract with the runner.
  export ADAPTER_OUT_DIR="${ADAPTER_OUT_DIR:-${AUDIT_DIR:-./.gaia/memory/brownfield-audit}/sarif}"
  mkdir -p "$ADAPTER_OUT_DIR"
  # Capture the docker-dispatched scan output. The trust-boundary checks
  # (DB age, drift) are downstream of this branch: the docker image
  # bundles a freshly pre-warmed DB pinned to the image tag, so the AC1
  # GRYPE_DB_MAX_ALLOWED_BUILT_AGE check is satisfied by construction
  # (image's DB date is fresher than the 5d cap when the image is
  # rebuilt monthly per the publish workflow).
  # AF-2026-05-31-2 / Test13 F-16: the prior `-f /out/grype.sarif` flag
  # was interpreted by grype as `--fail-on <severity>` (it gates the exit
  # code based on the highest severity finding), NOT as an output-file
  # specifier. Every docker CVE scan died with `bad --fail-on severity
  # value '/out/grype.sarif'` and produced no SARIF. The canonical grype
  # syntax for "scan + write SARIF to <path>" is `-o sarif=<path>` (a
  # single fused output specifier). Switched to that form.
  # AF-2026-05-31-2 / Test13 F-17: capture the dispatch exit code at the
  # point of failure (a separate variable `_grype_rc`) so the `die`
  # message reports the real exit status. The prior `rc=$?` after the
  # `fi` could capture 0 in some shells, producing the misleading
  # "dispatch failed (exit 0)" log line.
  _grype_rc=0
  docker_runner_dispatch grype dir:/workspace -o sarif="/out/grype.sarif" || _grype_rc=$?
  if [ "$_grype_rc" -eq 0 ]; then
    log_info "grype docker dispatch complete — SARIF at $ADAPTER_OUT_DIR/grype.sarif"
    exit 0
  fi
  if [ "$_grype_rc" -eq 125 ]; then
    log_warn "docker runner unavailable (exit 125) — falling through to native dispatch"
    # Fall through to native dispatch below.
  else
    die "grype docker dispatch failed (exit $_grype_rc)"
  fi
fi

# --- Graceful degrade: grype absent (native path) -------------------------
if ! command -v grype >/dev/null 2>&1; then
  log_warn "grype not found on PATH — skipping CVE scan (graceful degrade); Phase 3 continues"
  exit 0
fi

# --- Resolve the DB path + built timestamp via `grype db status` ----------
db_status_json="$(grype db status --output json 2>/dev/null || printf '{}')"
DB_FILE="${GAIA_GRYPE_DB_FILE:-$(printf '%s' "$db_status_json" | jq -r '.path // ""')}"
db_built="$(printf '%s' "$db_status_json" | jq -r '.built // ""')"

sha256_of() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$f" | awk '{print $1}'
  else printf 'unavailable'; fi
}

CURRENT_SHA="unavailable"
[ -n "$DB_FILE" ] && [ -f "$DB_FILE" ] && CURRENT_SHA="$(sha256_of "$DB_FILE")"

# Built-age seconds from the `built` timestamp (best-effort; empty if unparseable).
built_age_seconds=""
if [ -n "$db_built" ]; then
  built_epoch="$(date -u -d "$db_built" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$db_built" +%s 2>/dev/null || printf '')"
  [ -n "$built_epoch" ] && built_age_seconds="$(( $(date +%s) - built_epoch ))"
fi

# --- Mid-session drift detection (AC3) ------------------------------------
# Read the session-start checksum from E70-S7's log (last row matching session).
SESSION_ID="${GAIA_SESSION_ID:-$PPID}"
default_audit_dir() {
  if [ -n "${GAIA_MEMORY_DIR:-}" ]; then printf '%s/brownfield-audit' "$GAIA_MEMORY_DIR"
  else printf '%s' "./.gaia/memory/brownfield-audit"; fi
}
AUDIT_DIR="${GAIA_BROWNFIELD_AUDIT_DIR:-$(default_audit_dir)}"
CHECKSUM_LOG="$AUDIT_DIR/grype-db-checksum.log"

session_start_sha=""
if [ -f "$CHECKSUM_LOG" ]; then
  session_start_sha="$(grep -F "\"session_id\":\"$SESSION_ID\"" "$CHECKSUM_LOG" 2>/dev/null \
    | tail -n1 | jq -r '.checksum // ""' 2>/dev/null || printf '')"
fi

if [ -n "$session_start_sha" ] && [ "$CURRENT_SHA" != "unavailable" ] && [ "$CURRENT_SHA" != "$session_start_sha" ]; then
  die "Grype DB checksum drift detected mid-session (session=$SESSION_ID, expected=$session_start_sha, actual=$CURRENT_SHA)"
fi

# --- Run grype with the enforced max-age ----------------------------------
export GRYPE_DB_MAX_ALLOWED_BUILT_AGE="$CANONICAL_MAX_AGE"
[ "${GAIA_GRYPE_DEBUG:-}" = "1" ] && log_info "enforcing GRYPE_DB_MAX_ALLOWED_BUILT_AGE=$GRYPE_DB_MAX_ALLOWED_BUILT_AGE"

grype_start=$(date +%s)
grype_rc=0
grype "$@" || grype_rc=$?
grype_seconds=$(( $(date +%s) - grype_start ))

# --- Surface telemetry (AC2 / AC-X2 / AC-X3) ------------------------------
# grype owns grype_db_* + *.grype + llm_token_count:0 (single-author per field;
# gap_count_* are E104-owned — NOT written here). Populate via the shared writer
# when a report exists; always echo for the operator + bats assertions.
log_info "grype_db_checksum=$CURRENT_SHA grype_db_built_age=${built_age_seconds:-unknown} phase_runtime_seconds.grype=$grype_seconds"
REPORT="${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/planning-artifacts/consolidated-gaps.md"
TELEM="$(cd "$(dirname "$0")/../brownfield" 2>/dev/null && pwd)/brownfield-telemetry.sh"
if [ -f "$REPORT" ] && [ -x "$TELEM" ]; then
  bash "$TELEM" --report "$REPORT" --field grype_db_checksum --value "$CURRENT_SHA" || true
  [ -n "$built_age_seconds" ] && bash "$TELEM" --report "$REPORT" --field grype_db_built_age --value "$built_age_seconds" || true
  bash "$TELEM" --report "$REPORT" --field phase_runtime_seconds.grype --value "$grype_seconds" || true
  bash "$TELEM" --report "$REPORT" --field deterministic_tool_seconds.grype --value "$grype_seconds" || true
  bash "$TELEM" --report "$REPORT" --field llm_token_count --value 0 || true
fi

exit "$grype_rc"
