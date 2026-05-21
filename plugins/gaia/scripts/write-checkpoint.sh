#!/usr/bin/env bash
# write-checkpoint.sh — GAIA V2 checkpoint writer (E43-S1)
#
# Writes a schema v1 JSON checkpoint atomically to:
#   ${CHECKPOINT_ROOT:-_memory/checkpoints}/{skill_name}/{ts}-step-{N}.json
#
# This is the foundation helper that the 24 Phase 1-3 V2 skills (E43-S2..S5)
# call to record their progress; /gaia-resume (E43-S6) consumes these files
# to recover an interrupted session.
#
# Invocation:
#   write-checkpoint.sh <skill_name> <step_number> [key=value ...]
#                       [--paths <path> ...] [--custom <path-to-json>]
#
# Schema v1 JSON (ADR-059 §10.31.3):
#   {
#     "schema_version": 1,
#     "step_number":    <int>,
#     "skill_name":     "<string>",
#     "timestamp":      "<ISO 8601 µs Z>",
#     "key_variables":  { ... },
#     "output_paths":   [ ... ],
#     "file_checksums": { "<path>": "sha256:<64hex>", ... },
#     "skill_md_content_hash": "sha256:<64hex>",   // optional, ADR-059 §10.31.3
#     "custom":         { ... }            // optional
#   }
#
# Boundary vs. scripts/checkpoint.sh:
#   scripts/checkpoint.sh is the YAML-shaped workflow checkpoint writer used
#   by V1-era tooling. write-checkpoint.sh is the V2 per-skill JSON writer
#   (ADR-059). The two scripts coexist during the V1→V2 transition; do NOT
#   retrofit the old script to the new schema — each consumer targets one
#   shape (/gaia-resume for V2 JSON; the older engine for V1 YAML).
#
# Exit codes:
#   0   success
#   1   validation error (bad skill_name, step_number, malformed inputs)
#   2   environment error (sha256 tool missing, custom file unparseable)
#   3   IO error (mkdir/mv/rename failures)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="write-checkpoint.sh"

die() {
  local rc="$1"; shift
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit "$rc"
}

usage() {
  cat <<'USAGE'
Usage:
  write-checkpoint.sh <skill_name> <step_number> [key=value ...]
                      [--paths <path> ...] [--custom <path-to-json>]

Positional arguments:
  skill_name     Skill identifier; must match [a-z0-9][a-z0-9-]{0,63}
  step_number    Non-negative integer

Optional flags:
  --paths ...    One or more output paths to checksum (sha256)
  --custom FILE  Path to a JSON file whose contents are nested under the
                 "custom" key of the final checkpoint JSON
  --skill-md FILE  Path to the owning SKILL.md. The script computes a
                 SHA-256 over the file bytes and writes it as a top-level
                 "skill_md_content_hash" field (ADR-059 §10.31.3). Used by
                 /gaia-resume (E43-S6) to detect SKILL.md version drift
                 between checkpoint write and resume.

Environment:
  CHECKPOINT_ROOT  Directory where _memory/checkpoints/{skill}/ lives.
                   Defaults to _memory/checkpoints (relative to CWD).

Writes a schema v1 JSON file atomically to:
  $CHECKPOINT_ROOT/<skill_name>/<ISO8601-microseconds-Z>-step-<N>.json

Exit codes:
  0 ok | 1 validation error | 2 environment error | 3 IO error
USAGE
}

# ---------- Help ----------
if [ $# -eq 1 ] && { [ "$1" = "--help" ] || [ "$1" = "-h" ]; }; then
  usage
  exit 0
fi

# ---------- sha256 preflight (AC-EC7) ----------
# Must run BEFORE we create any temp files so a missing tool never leaves
# stray files on disk.
SHA_TOOL=""
if command -v shasum >/dev/null 2>&1; then
  SHA_TOOL="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
  SHA_TOOL="sha256sum"
fi

sha256_of() {
  # Requires SHA_TOOL to be set. Prints the 64-hex digest only.
  local p="$1" out
  # shellcheck disable=SC2086  # intentional word-split for $SHA_TOOL
  out=$($SHA_TOOL "$p") || return 1
  printf '%s' "${out%% *}"
}

# ---------- Positional skill_name + step_number ----------
[ $# -ge 2 ] || { usage >&2; die 1 "skill_name and step_number are required"; }

SKILL_NAME="$1"
STEP_NUMBER="$2"
shift 2

# Validate skill_name — AC-EC5. Regex: ^[a-z0-9][a-z0-9-]{0,63}$
case "$SKILL_NAME" in
  ''|*/*|*..*|.*|*\\*|*\ *)
    die 1 "invalid skill_name: $SKILL_NAME" ;;
esac
if ! printf '%s' "$SKILL_NAME" | grep -Eq '^[a-z0-9][a-z0-9-]{0,63}$'; then
  die 1 "invalid skill_name: $SKILL_NAME"
fi

# Validate step_number — AC-EC9. Must be a non-negative integer.
case "$STEP_NUMBER" in
  ''|*[!0-9]*)
    die 1 "step_number must be a non-negative integer (got: $STEP_NUMBER)" ;;
esac

# ---------- Parse remaining args: key=val pairs, --paths, --custom ----------
KEY_VAR_KEYS=()
KEY_VAR_VALS=()
PATHS=()
CUSTOM_FILE=""
SKILL_MD_FILE=""

parsing_paths=0
while [ $# -gt 0 ]; do
  case "$1" in
    --paths)
      parsing_paths=1
      shift
      ;;
    --custom)
      parsing_paths=0
      [ $# -ge 2 ] || die 1 "--custom requires a file path"
      CUSTOM_FILE="$2"
      shift 2
      ;;
    --custom=*)
      parsing_paths=0
      CUSTOM_FILE="${1#--custom=}"
      shift
      ;;
    --skill-md)
      parsing_paths=0
      [ $# -ge 2 ] || die 1 "--skill-md requires a file path"
      SKILL_MD_FILE="$2"
      shift 2
      ;;
    --skill-md=*)
      parsing_paths=0
      SKILL_MD_FILE="${1#--skill-md=}"
      shift
      ;;
    --*)
      die 1 "unknown flag: $1"
      ;;
    *)
      if [ "$parsing_paths" -eq 1 ]; then
        PATHS+=("$1")
      else
        case "$1" in
          *=*)
            KEY_VAR_KEYS+=("${1%%=*}")
            KEY_VAR_VALS+=("${1#*=}")
            ;;
          *)
            die 1 "positional argument must be key=value (got: $1)"
            ;;
        esac
      fi
      shift
      ;;
  esac
done

# ---------- Validate paths exist (AC-EC2) BEFORE creating any files ----------
if [ "${#PATHS[@]}" -gt 0 ]; then
  for p in "${PATHS[@]}"; do
    if [ ! -e "$p" ]; then
      die 1 "output path not found: $p"
    fi
  done
fi

# ---------- sha256 tool presence check (AC-EC7) ----------
# Only required if we have paths to checksum. If zero paths, skip the check.
if [ "${#PATHS[@]}" -gt 0 ] && [ -z "$SHA_TOOL" ]; then
  die 2 "sha256 tool not found (need shasum or sha256sum on PATH)"
fi

# ---------- Validate --skill-md (if provided) ----------
SKILL_MD_HASH=""
if [ -n "$SKILL_MD_FILE" ]; then
  [ -f "$SKILL_MD_FILE" ] || die 1 "--skill-md file not found: $SKILL_MD_FILE"
  [ -n "$SHA_TOOL" ] || die 2 "sha256 tool not found (need shasum or sha256sum on PATH)"
  SKILL_MD_HASH=$(sha256_of "$SKILL_MD_FILE") || die 2 "sha256 failed on --skill-md file: $SKILL_MD_FILE"
fi

# ---------- Validate custom file (if provided) ----------
CUSTOM_CONTENT=""
if [ -n "$CUSTOM_FILE" ]; then
  [ -f "$CUSTOM_FILE" ] || die 1 "--custom file not found: $CUSTOM_FILE"
  # Must be parseable JSON. Prefer jq; fall back to python -c.
  if command -v jq >/dev/null 2>&1; then
    jq . "$CUSTOM_FILE" >/dev/null 2>&1 || die 2 "--custom file is not valid JSON: $CUSTOM_FILE"
    CUSTOM_CONTENT=$(cat "$CUSTOM_FILE")
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CUSTOM_FILE" >/dev/null 2>&1 \
      || die 2 "--custom file is not valid JSON: $CUSTOM_FILE"
    CUSTOM_CONTENT=$(cat "$CUSTOM_FILE")
  else
    # Last-resort: accept raw contents unchecked. Document in script header.
    CUSTOM_CONTENT=$(cat "$CUSTOM_FILE")
  fi
fi

# ---------- Resolve CHECKPOINT_ROOT (AF-2026-05-21-7 inverted precedence) ----------
# Canonical .gaia/memory/checkpoints is the default for greenfield AND
# post-ADR-111 projects. Legacy _memory/checkpoints fires ONLY when there's
# positive pre-migration evidence: legacy dir exists AND canonical doesn't.
# Env CHECKPOINT_ROOT override wins.
if [ -z "${CHECKPOINT_ROOT:-}" ]; then
  if [ -d "_memory/checkpoints" ] && [ ! -d ".gaia/memory" ]; then
    CHECKPOINT_ROOT="_memory/checkpoints"
  else
    CHECKPOINT_ROOT=".gaia/memory/checkpoints"
  fi
fi
SKILL_DIR="$CHECKPOINT_ROOT/$SKILL_NAME"

mkdir -p "$SKILL_DIR" 2>/dev/null \
  || die 3 "cannot create checkpoint directory: $SKILL_DIR"

# ---------- Timestamp with microsecond precision (AC-EC4) ----------
iso8601_us() {
  # Prefer Python for portable microsecond UTC timestamps — available on all
  # supported macOS/Linux targets (bats, CI).
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import datetime as d; print(d.datetime.now(d.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"))'
    return
  fi
  # Fallback: GNU date supports %N for nanoseconds; BSD date does not.
  local ns
  if ns=$(date -u +%N 2>/dev/null) && [ "$ns" != "N" ] && [ "$ns" != "%N" ]; then
    # Truncate nanoseconds to microseconds.
    local us="${ns%???}"
    date -u +"%Y-%m-%dT%H:%M:%S.${us}Z"
    return
  fi
  # Last-resort: second precision + PID-based disambiguator.
  printf '%s.%06dZ' "$(date -u +%Y-%m-%dT%H:%M:%S)" "$$"
}

TIMESTAMP=$(iso8601_us)

# Guarantee uniqueness: if a file with this name somehow already exists
# (same-microsecond concurrent write on slow sha256), append pid.
FINAL="$SKILL_DIR/${TIMESTAMP}-step-${STEP_NUMBER}.json"
if [ -e "$FINAL" ]; then
  FINAL="$SKILL_DIR/${TIMESTAMP}-pid${$}-step-${STEP_NUMBER}.json"
fi
TMP="${FINAL}.tmp.$$"

# ---------- JSON builder ----------
# Uses jq when available for escape-safe emission (AC-EC6). Falls back to a
# deterministic hand-rolled emitter that escapes backslash, double-quote,
# and control characters per JSON spec.

json_escape() {
  # Escape a string for JSON per RFC 8259. Handles the six mandatory
  # escapes (\\ \" \b \f \n \r \t). Remaining C0 controls (0x00-0x1f) are
  # extremely rare in GAIA key=value payloads; if they appear, the final
  # `jq -c .` re-normalization pass below catches any non-strict output.
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\b'/\\b}
  s=${s//$'\f'/\\f}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '"%s"' "$s"
}

emit_key_variables_obj() {
  local n="${#KEY_VAR_KEYS[@]}"
  if [ "$n" -eq 0 ]; then
    printf '{}'
    return
  fi
  printf '{'
  local i=0
  while [ "$i" -lt "$n" ]; do
    [ "$i" -gt 0 ] && printf ','
    json_escape "${KEY_VAR_KEYS[$i]}"; printf ':'
    json_escape "${KEY_VAR_VALS[$i]}"
    i=$((i+1))
  done
  printf '}'
}

emit_output_paths_arr() {
  local n="${#PATHS[@]}"
  if [ "$n" -eq 0 ]; then
    printf '[]'
    return
  fi
  printf '['
  local i=0
  while [ "$i" -lt "$n" ]; do
    [ "$i" -gt 0 ] && printf ','
    json_escape "${PATHS[$i]}"
    i=$((i+1))
  done
  printf ']'
}

emit_file_checksums_obj() {
  local n="${#PATHS[@]}"
  if [ "$n" -eq 0 ]; then
    printf '{}'
    return
  fi
  printf '{'
  local i=0 hex
  while [ "$i" -lt "$n" ]; do
    [ "$i" -gt 0 ] && printf ','
    hex=$(sha256_of "${PATHS[$i]}") || die 2 "sha256 failed on ${PATHS[$i]}"
    json_escape "${PATHS[$i]}"; printf ':'
    json_escape "sha256:$hex"
    i=$((i+1))
  done
  printf '}'
}

build_json() {
  # Build in memory so we fail BEFORE opening the tmp file if a checksum
  # errors out (atomic guarantee).
  local kv paths_arr checksums custom_block="" skill_md_block=""
  kv=$(emit_key_variables_obj)
  paths_arr=$(emit_output_paths_arr)
  checksums=$(emit_file_checksums_obj)
  if [ -n "$SKILL_MD_HASH" ]; then
    skill_md_block=",\"skill_md_content_hash\":$(json_escape "sha256:$SKILL_MD_HASH")"
  fi
  if [ -n "$CUSTOM_CONTENT" ]; then
    custom_block=",\"custom\":$CUSTOM_CONTENT"
  fi
  printf '{"schema_version":1,"step_number":%s,"skill_name":%s,"timestamp":%s,"key_variables":%s,"output_paths":%s,"file_checksums":%s%s%s}' \
    "$STEP_NUMBER" \
    "$(json_escape "$SKILL_NAME")" \
    "$(json_escape "$TIMESTAMP")" \
    "$kv" \
    "$paths_arr" \
    "$checksums" \
    "$skill_md_block" \
    "$custom_block"
}

JSON=$(build_json)

# Re-normalize via jq (if available) so output is always valid, pretty-ish
# JSON. If jq is absent, the hand-rolled output is already spec-compliant.
if command -v jq >/dev/null 2>&1; then
  JSON=$(printf '%s' "$JSON" | jq -c .) || die 2 "generated JSON failed jq validation"
fi

# ---------- Atomic write: tmp → mv ----------
cleanup_tmp() {
  [ -n "${TMP:-}" ] && rm -f "$TMP" 2>/dev/null || true
}
trap cleanup_tmp EXIT

printf '%s\n' "$JSON" > "$TMP" || die 3 "failed to write tmp file: $TMP"

# fsync where available (best-effort; not critical for POSIX rename atomicity).
if command -v sync >/dev/null 2>&1; then
  sync 2>/dev/null || true
fi

mv -f "$TMP" "$FINAL" || die 3 "failed to rename $TMP to $FINAL"

# Successful write — disarm the trap so we don't delete the final file.
trap - EXIT

printf '%s\n' "$FINAL"
exit 0
