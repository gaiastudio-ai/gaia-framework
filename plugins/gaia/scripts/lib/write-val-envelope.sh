#!/usr/bin/env bash
# write-val-envelope.sh — orchestrator-side Val envelope sentinel writer.
#
# Story: E87-S7 — Sentinel-Write Writer Shift — move Val envelope sentinel
#                 write from sub-agent to orchestrator.
# Anchor: ADR-105 — Sentinel-Write Writer Shift (amends ADR-104).
# Trace: FR-482, FR-483, FR-484, NFR-064 (forgery resistance), NFR-066.
#
# Background:
#   ADR-104 (E87) migrated Val dispatch to the main-turn Agent tool and
#   moved the sentinel write into the Val sub-agent's context (E87-S2
#   Sentinel-Write Contract). The Claude Code substrate's content-integrity
#   guard subsequently false-fires on sub-agent writes to
#   `_memory/checkpoints/val-envelope-*.json`, blocking the cascade even
#   when Val behaved correctly (AI-2026-05-13-13 incident, 2026-05-13).
#
#   This helper closes the regression by shifting the write back to the
#   orchestrator's main turn. Val now RETURNS the sentinel content as a
#   `sentinel_envelope` field inside its ADR-037 envelope; the orchestrator
#   parses the envelope and invokes this helper to write the sentinel.
#
# Forgery resistance (NFR-064 preserved):
#   The `persona_sig` field is computed by Val from validator.md's on-disk
#   sha256 — the orchestrator cannot fabricate a valid sig without reading
#   validator.md at the same revision. The orchestrator is a write-through,
#   not a source of trust.
#
# Contract:
#   write-val-envelope.sh --envelope <json>          # JSON literal as arg
#   write-val-envelope.sh --envelope-stdin           # JSON read from stdin
#
#   The JSON must contain ALL FIVE required keys:
#     agent          — MUST equal the literal string "val"
#     persona_sig    — non-empty string (forgery-resistance anchor)
#     timestamp      — ISO-8601 UTC timestamp (string)
#     artifact_path  — string; used to compute sentinel path
#     verdict        — one of PASSED|FAILED|UNVERIFIED
#
#   The sentinel path is computed as
#     ${CHECKPOINT_PATH}/val-envelope-${HASH}.json
#   where HASH is the first 16 hex characters of sha256(artifact_path).
#
#   CHECKPOINT_PATH defaults to "_memory/checkpoints" (resolved relative to
#   $PWD) when not set. Tests may override via the environment.
#
# Exit codes:
#   0 — sentinel written; path printed to stdout
#   1 — malformed JSON, missing required field, wrong agent value, write
#       failure
#   2 — usage error (no envelope provided)
#
# Atomic write idiom: sibling tempfile + mv (POSIX-atomic on the same
# filesystem). No partial sentinel ever lands on disk.
#
# POSIX discipline: bash with [[ ]] only. macOS /bin/bash 3.2 compatible.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="write-val-envelope.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit "${2:-1}"; }

usage() {
  cat >&2 <<'USAGE'
Usage:
  write-val-envelope.sh --envelope <json>
  write-val-envelope.sh --envelope-stdin

The envelope JSON MUST contain all five keys:
  agent (== "val"), persona_sig, timestamp, artifact_path, verdict.

CHECKPOINT_PATH env var sets the checkpoint directory (default:
_memory/checkpoints relative to PWD).
USAGE
}

# ---------- Arg parse ----------
ENVELOPE=""
ENVELOPE_STDIN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --envelope)
      [ $# -ge 2 ] || { usage; exit 2; }
      ENVELOPE="$2"
      shift 2
      ;;
    --envelope-stdin)
      ENVELOPE_STDIN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log "unknown flag: $1"
      usage
      exit 2
      ;;
  esac
done

if [ "$ENVELOPE_STDIN" -eq 1 ]; then
  ENVELOPE="$(cat)"
fi

if [ -z "$ENVELOPE" ]; then
  log "no envelope provided (use --envelope <json> or --envelope-stdin)"
  exit 2
fi

# ---------- Validate JSON shape ----------
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

# Validate JSON parses
if ! printf '%s' "$ENVELOPE" | jq -e . >/dev/null 2>&1; then
  die "envelope is not valid JSON"
fi

# Check required keys exist
for key in agent persona_sig timestamp artifact_path verdict; do
  value=$(printf '%s' "$ENVELOPE" | jq -r --arg k "$key" '.[$k] // empty')
  if [ -z "$value" ]; then
    die "envelope missing required field: $key"
  fi
done

# Check agent == "val" (forgery resistance check #1)
AGENT=$(printf '%s' "$ENVELOPE" | jq -r '.agent')
if [ "$AGENT" != "val" ]; then
  die "envelope agent field must be 'val', got '$AGENT'"
fi

# Check persona_sig is non-empty (forgery resistance check #2)
PERSONA_SIG=$(printf '%s' "$ENVELOPE" | jq -r '.persona_sig')
if [ -z "$PERSONA_SIG" ]; then
  die "envelope persona_sig field must be non-empty"
fi

# ---------- Compute sentinel path ----------
ARTIFACT_PATH=$(printf '%s' "$ENVELOPE" | jq -r '.artifact_path')

# AF-2026-05-29-2 / Test09 F-17: resolve project_root FIRST (the canonical
# anchor for project-relative paths) so we can normalize artifact_path before
# hashing. Without the normalization the hash is non-deterministic across
# caller conventions — a Val agent that writes an absolute path
# (`/Users/.../prd.md`) hashes differently from a consumer that asserts on a
# relative path (`.gaia/artifacts/planning-artifacts/prd.md`), and the
# security gate falsely HALTs on a perfectly valid Val run. The convention is
# "project-relative-from-project-root, never absolute"; the writer enforces it
# below by stripping any leading project_root prefix and any leading "./".
# Non-path artifact_path values (e.g. a literal feature_id like
# "AF-2026-05-29-1") have no leading "/" or "./", so they pass through unchanged.
_PROJECT_ROOT_FOR_HASH=""
if [ -n "${PROJECT_ROOT:-}" ]; then
  _PROJECT_ROOT_FOR_HASH="$PROJECT_ROOT"
elif [ -n "${CLAUDE_PROJECT_ROOT:-}" ]; then
  _PROJECT_ROOT_FOR_HASH="$CLAUDE_PROJECT_ROOT"
elif [ -n "${GAIA_PROJECT_ROOT:-}" ]; then
  _PROJECT_ROOT_FOR_HASH="$GAIA_PROJECT_ROOT"
else
  # Last resort — resolve from resolve-config.sh. Cheap one-shot read just for
  # the project_root field; we read it again below for the CHECKPOINT_DIR path
  # but the duplicate read is intentional (the hash MUST happen before that
  # block to keep the writer/asserter contract honest).
  _own_dir_h="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _resolver_h="$_own_dir_h/../resolve-config.sh"
  if [ -x "$_resolver_h" ]; then
    _PROJECT_ROOT_FOR_HASH="$("$_resolver_h" project_root 2>/dev/null || true)"
    _PROJECT_ROOT_FOR_HASH="${_PROJECT_ROOT_FOR_HASH#\'}"
    _PROJECT_ROOT_FOR_HASH="${_PROJECT_ROOT_FOR_HASH%\'}"
  fi
  unset _own_dir_h _resolver_h
fi
case "$ARTIFACT_PATH" in
  /*)
    if [ -n "$_PROJECT_ROOT_FOR_HASH" ]; then
      case "$ARTIFACT_PATH" in
        "$_PROJECT_ROOT_FOR_HASH"/*) ARTIFACT_PATH="${ARTIFACT_PATH#"$_PROJECT_ROOT_FOR_HASH"/}" ;;
        "$_PROJECT_ROOT_FOR_HASH")   ARTIFACT_PATH="." ;;
      esac
    fi
    ;;
  ./*)
    ARTIFACT_PATH="${ARTIFACT_PATH#./}"
    ;;
esac
unset _PROJECT_ROOT_FOR_HASH
HASH=$(printf '%s' "$ARTIFACT_PATH" | shasum -a 256 | cut -c1-16)

# E55-S13 D4 — when CHECKPOINT_PATH env-var is unset, resolve the canonical
# checkpoint dir via resolve-config.sh instead of falling back to a CWD-
# relative `_memory/checkpoints` literal. This keeps sentinels at the
# project-root path regardless of the orchestrator's CWD, so
# assert_agent_envelope (which itself runs from project root) can find
# them. The CHECKPOINT_PATH env-var override path remains the highest
# precedence — test fixtures and explicit-override callers are unaffected.
if [ -n "${CHECKPOINT_PATH:-}" ]; then
  CHECKPOINT_DIR="$CHECKPOINT_PATH"
else
  _own_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _resolver="$_own_dir/../resolve-config.sh"
  if [ -x "$_resolver" ]; then
    # Read project_root + checkpoint_path off a single resolver invocation.
    _resolver_out=""
    _resolver_out=$("$_resolver" 2>/dev/null) || _resolver_out=""
    _project_root=""
    _checkpoint_path=""
    while IFS= read -r _line; do
      case "$_line" in
        project_root=*)
          _project_root="${_line#project_root=}"
          _project_root="${_project_root#\'}"; _project_root="${_project_root%\'}"
          ;;
        checkpoint_path=*)
          _checkpoint_path="${_line#checkpoint_path=}"
          _checkpoint_path="${_checkpoint_path#\'}"; _checkpoint_path="${_checkpoint_path%\'}"
          ;;
      esac
    done <<< "$_resolver_out"
    if [ -n "$_checkpoint_path" ]; then
      case "$_checkpoint_path" in
        /*) CHECKPOINT_DIR="$_checkpoint_path" ;;
        *)  CHECKPOINT_DIR="${_project_root:-.}/$_checkpoint_path" ;;
      esac
    else
      # AF-2026-05-27-3 (ADR-111): .gaia/memory/checkpoints is the only
      # location — the legacy _memory/checkpoints fallback was removed with the
      # consolidation migration.
      CHECKPOINT_DIR="${_project_root:-.}/.gaia/memory/checkpoints"
    fi
    unset _own_dir _resolver _resolver_out _project_root _checkpoint_path _line
  else
    # CWD-relative branch when resolve-config.sh is missing (ADR-111 canonical).
    CHECKPOINT_DIR=".gaia/memory/checkpoints"
  fi
fi

SENTINEL_PATH="${CHECKPOINT_DIR}/val-envelope-${HASH}.json"

# ---------- Atomic write (tempfile + mv) ----------
mkdir -p "$CHECKPOINT_DIR" || die "failed to create checkpoint dir: $CHECKPOINT_DIR"

TMP_PATH="${SENTINEL_PATH}.tmp.$$"
printf '%s\n' "$ENVELOPE" > "$TMP_PATH" || die "failed to write tempfile: $TMP_PATH"
mv "$TMP_PATH" "$SENTINEL_PATH" || die "failed to mv tempfile to sentinel path: $SENTINEL_PATH"

# Print sentinel path on stdout for caller consumption
printf '%s\n' "$SENTINEL_PATH"
exit 0
