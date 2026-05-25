#!/usr/bin/env bash
# adapters/brownfield/pre-warm.sh — E70-S7 brownfield Phase 3 adapter pre-flight.
#
# Runs `grype db check || grype db update` and primes cdxgen package-registry
# caches BEFORE the /gaia-brownfield Phase 3 scan timer starts, so cold-runner
# CI does not pay the 15-30s Grype DB cold-fetch + cdxgen warm-up against the
# NFR-84 120s WARNING budget. Logs the Grype DB SHA-256 checksum (producer for
# E70-S9's trust-boundary enforcement).
#
# Contract (ADR-078 / ADR-121):
#   - Gated behind the deterministic-tools master flag + per-tool override
#     (resolved by /gaia-brownfield via resolve-config.sh and exported as
#     GAIA_BROWNFIELD_DETERMINISTIC_TOOLS / GAIA_BROWNFIELD_PREWARM_ENABLED).
#   - Graceful degrade: missing grype/cdxgen -> WARNING + exit 0 (never abort
#     Phase 3). One network retry on `grype db update` failure.
#   - Idempotent warm path: DB present + age < 5d AND cdxgen sentinel marker
#     present + < 5d -> emit "cache warm", exit 0, ZERO network I/O.
#
# Exit code is ALWAYS 0 — pre-flight degrade must never block the scan cohort.
#
# Test seams (consumed by tests/pre-warm-script.bats):
#   GAIA_BROWNFIELD_AUDIT_DIR  checksum-log dir   (default .gaia/memory/brownfield-audit)
#   GAIA_PREWARM_CACHE_DIR     cdxgen marker dir  (default .gaia/memory/brownfield-audit/prewarm-cache)
#   GAIA_GRYPE_DB_FILE         grype-db.sqlite to checksum (default best-effort discovery)
#   GAIA_SESSION_ID            session id for the JSONL row (default $PPID)
#   GAIA_PREWARM_MAX_AGE_DAYS  warm-cache freshness threshold (default 5)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="adapters/brownfield/pre-warm.sh"
log_info()  { printf 'INFO: %s: %s\n' "$SCRIPT_NAME" "$*"; }
log_warn()  { printf 'WARNING: %s: %s\n' "$SCRIPT_NAME" "$*"; }

# --- Flag gate (ADR-121 master flag + ADR-078 per-tool override) ----------
# /gaia-brownfield resolves these via resolve-config.sh and exports them.
# Default-on when unset (the SKILL only invokes pre-warm when the gate is on,
# but the script defends itself when invoked directly).
MASTER="${GAIA_BROWNFIELD_DETERMINISTIC_TOOLS:-true}"
PER_TOOL="${GAIA_BROWNFIELD_PREWARM_ENABLED:-true}"
if [ "$MASTER" != "true" ] || [ "$PER_TOOL" != "true" ]; then
  log_info "pre-warm skipped (flag-off: deterministic_tools=$MASTER pre-warm.enabled=$PER_TOOL)"
  exit 0
fi

# --- Resolve runtime paths ------------------------------------------------
MAX_AGE_DAYS="${GAIA_PREWARM_MAX_AGE_DAYS:-5}"
MAX_AGE_SECONDS=$(( MAX_AGE_DAYS * 86400 ))
SESSION_ID="${GAIA_SESSION_ID:-$PPID}"

# Default audit dir under the canonical runtime memory tree (.gaia/memory).
default_audit_dir() {
  if [ -n "${GAIA_MEMORY_DIR:-}" ]; then
    printf '%s/brownfield-audit' "$GAIA_MEMORY_DIR"
  else
    printf '%s' "./.gaia/memory/brownfield-audit"
  fi
}
AUDIT_DIR="${GAIA_BROWNFIELD_AUDIT_DIR:-$(default_audit_dir)}"
CACHE_DIR="${GAIA_PREWARM_CACHE_DIR:-$AUDIT_DIR/prewarm-cache}"
CHECKSUM_LOG="$AUDIT_DIR/grype-db-checksum.log"

now_epoch() { date +%s; }
iso_now()   { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Age in seconds of a file (portable: GNU stat -c, BSD stat -f). Empty if absent.
file_age_seconds() {
  local f="$1"
  [ -e "$f" ] || { printf ''; return; }
  local mtime
  mtime="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || printf '')"
  [ -n "$mtime" ] || { printf ''; return; }
  printf '%s' "$(( $(now_epoch) - mtime ))"
}

# --- Discover the grype-db.sqlite to checksum -----------------------------
discover_grype_db() {
  if [ -n "${GAIA_GRYPE_DB_FILE:-}" ] && [ -f "$GAIA_GRYPE_DB_FILE" ]; then
    printf '%s' "$GAIA_GRYPE_DB_FILE"; return
  fi
  # Best-effort: the canonical grype cache location.
  local cand="${HOME:-/root}/.cache/grype/db"
  if [ -d "$cand" ]; then
    find "$cand" -name 'grype-db.sqlite' -o -name '*.sqlite' 2>/dev/null | head -n1
    return
  fi
  printf ''
}

sha256_of() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    printf 'unavailable'
  fi
}

append_checksum_row() {
  local db_file="$1" db_age="$2" checksum="unavailable"
  mkdir -p "$AUDIT_DIR"
  if [ -n "$db_file" ] && [ -f "$db_file" ]; then
    checksum="$(sha256_of "$db_file")"
  fi
  # JSONL row (one per invocation). jq for safe encoding; fall back to printf.
  if command -v jq >/dev/null 2>&1; then
    jq -nc \
      --arg ts "$(iso_now)" \
      --arg sid "$SESSION_ID" \
      --arg ck "$checksum" \
      --argjson age "${db_age:-0}" \
      '{ts:$ts, session_id:$sid, checksum:$ck, db_built_age_seconds:$age}' \
      >> "$CHECKSUM_LOG"
  else
    printf '{"ts":"%s","session_id":"%s","checksum":"%s","db_built_age_seconds":%s}\n' \
      "$(iso_now)" "$SESSION_ID" "$checksum" "${db_age:-0}" >> "$CHECKSUM_LOG"
  fi
}

# --- cdxgen warm-up -------------------------------------------------------
cdxgen_warm() {
  command -v cdxgen >/dev/null 2>&1 || { log_warn "cdxgen not found on PATH — skipping registry warm-up (graceful degrade)"; return 0; }
  mkdir -p "$CACHE_DIR"
  # Prime package-registry caches; discard the SBOM (we only want the warm-up).
  cdxgen --no-recurse --print >/dev/null 2>&1 || log_warn "cdxgen warm-up returned non-zero — continuing (graceful degrade)"
  : > "$CACHE_DIR/cdxgen-warm.marker"
}

# --- Idempotent warm-cache short-circuit ----------------------------------
# Warm iff: grype reports DB present+fresh (client-side, no network) AND the
# cdxgen sentinel marker exists and is younger than the threshold.
is_warm() {
  command -v grype >/dev/null 2>&1 || return 1
  # Client-side DB status check — must NOT hit the network.
  grype db status --output json >/dev/null 2>&1 || return 1
  local marker="$CACHE_DIR/cdxgen-warm.marker"
  [ -f "$marker" ] || return 1
  local age; age="$(file_age_seconds "$marker")"
  [ -n "$age" ] && [ "$age" -lt "$MAX_AGE_SECONDS" ] || return 1
  return 0
}

# --- grype DB check/update with one retry ---------------------------------
grype_db_refresh() {
  command -v grype >/dev/null 2>&1 || { log_warn "grype not found on PATH — skipping DB refresh (graceful degrade)"; return 1; }
  if grype db check >/dev/null 2>&1; then
    return 0   # DB present and current; no update needed.
  fi
  # Cold or stale: update, with a single retry on (likely network) failure.
  if grype db update >/dev/null 2>&1; then
    return 0
  fi
  log_warn "grype db update failed on first attempt — retrying once"
  if grype db update >/dev/null 2>&1; then
    return 0
  fi
  log_warn "grype db update failed after retry — continuing without fresh DB (graceful degrade)"
  return 1
}

# --- Main -----------------------------------------------------------------
main() {
  if is_warm; then
    printf 'cache warm\n'
    exit 0
  fi

  grype_db_refresh || true   # graceful degrade — never abort.
  cdxgen_warm || true

  # Log the checksum of the (possibly freshly updated) Grype DB.
  local db_file db_age
  db_file="$(discover_grype_db)"
  db_age="$(file_age_seconds "$db_file")"
  append_checksum_row "$db_file" "$db_age"

  exit 0
}

main "$@"
