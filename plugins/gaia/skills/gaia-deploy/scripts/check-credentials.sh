#!/usr/bin/env bash
# check-credentials.sh — /gaia-deploy credential gate.
#
# Per the credential contract, /gaia-deploy receives credential ENV-VAR NAMES
# (never values, never paths) and verifies that each named env-var is set in
# the current environment. Missing env-var → BLOCKED with the expected name.
#
# Usage:
#   check-credentials.sh --env-var NAME [--env-var NAME ...]

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-deploy/check-credentials.sh"
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

NAMES=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --env-var) NAMES+=("$2"); shift 2 ;;
    -h|--help)
      cat <<EOF
$SCRIPT_NAME — credential env-var presence check.
Usage: $SCRIPT_NAME --env-var NAME [--env-var NAME ...]
EOF
      exit 0 ;;
    *) log "unknown arg: $1"; exit 2 ;;
  esac
done

if [ "${#NAMES[@]}" -eq 0 ]; then
  log "no --env-var names provided"
  exit 0
fi

missing=()
for name in "${NAMES[@]}"; do
  # Validate the name itself is a legal env-var identifier (defensive).
  case "$name" in
    [A-Za-z_][A-Za-z0-9_]*) ;;
    *) log "BLOCKED: invalid env-var name: $name"; exit 1 ;;
  esac
  # Use indirect expansion to read the env-var.
  val="${!name:-}"
  if [ -z "$val" ]; then
    missing+=("$name")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  log "BLOCKED: required credential env-var(s) not set:"
  for n in "${missing[@]}"; do
    log "  $n"
  done
  exit 1
fi

log "credentials present: ${NAMES[*]}"
exit 0
