#!/usr/bin/env bash
# tool-availability-probe.sh — GAIA shared review-skill helper (E66-S2, ADR-078).
#
# Purpose
# -------
# Deterministic three-state probe that classifies every adapter invocation into
# one of four states, eliminating both silent downgrades (missing tools passing
# silently) and false-BLOCKEDs (inapplicable tools halting the pipeline):
#
#   - available           : tool installed, applicable files exist, run.sh exits 0
#   - expected_and_missing: tool declared in adapter.json but not on PATH
#   - ran_and_errored     : adapter run.sh exits non-zero or times out
#   - not_applicable      : no input files match the adapter's category extensions
#
# Output (stdout) is a single-line JSON object with exactly three keys:
#   {"state":"<state>","skip_reason":<string|null>,"error_detail":<string|null>}
#
# Exit codes
# ----------
#   0  — state == available OR not_applicable (no failure to report)
#   1  — state == expected_and_missing OR ran_and_errored OR caller error
#        (missing flag, missing/malformed adapter.json, etc.)
#
# Invocation
# ----------
#   tool-availability-probe.sh --adapter-dir <path> --file-list <path>
#                              [--timeout <seconds>]
#                              [--config <path>] [--runtime-profile <profile>]
#   tool-availability-probe.sh --help
#
# Determinism (NFR-RSV2-9)
# ------------------------
# `set -euo pipefail` + `LC_ALL=C` + per-stage strict ordering guarantee that
# identical inputs produce byte-identical output every invocation. The probe
# does not read environment beyond PATH and a single timeout binary lookup.
#
# Refs: ADR-077, ADR-078, FR-RSV2-18, FR-RSV2-19, NFR-RSV2-9, NFR-RSV2-11.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="tool-availability-probe.sh"

die() {
  # die <exit_code> <message>
  local rc="$1"; shift
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit "$rc"
}

usage() {
  cat <<EOF
$SCRIPT_NAME — three-state availability probe for GAIA adapters (ADR-078).

Usage:
  $SCRIPT_NAME --adapter-dir <path> --file-list <path>
               [--timeout <seconds>] [--config <path>]
               [--runtime-profile subprocess|container|network]
  $SCRIPT_NAME --help

Required:
  --adapter-dir <path>      Adapter directory containing adapter.json + run.sh.
  --file-list <path>        File list to feed the adapter (one path per line).

Optional:
  --timeout <seconds>       Override adapter.json default-timeout-seconds.
  --config <path>           Adapter config file (forwarded to run.sh).
  --runtime-profile <prof>  subprocess | container | network. Defaults to
                            adapter.json runtime-profile.
  --help                    Show this help and exit 0.

States (stdout JSON):
  available           Tool installed, files match, run.sh exits 0.
  expected_and_missing Tool declared in adapter.json but not on PATH.
  ran_and_errored     run.sh exits non-zero or times out (error_detail set).
  not_applicable      File list has no files matching adapter file-extensions
                      (or, for project-scope adapters, file list is empty).

Exit codes:
  0  available | not_applicable
  1  expected_and_missing | ran_and_errored | caller error
EOF
}

ADAPTER_DIR=""
FILE_LIST=""
TIMEOUT_OVERRIDE=""
CONFIG=""
RUNTIME_PROFILE_OVERRIDE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --adapter-dir)
      [ "$#" -ge 2 ] || die 1 "--adapter-dir requires a path"
      ADAPTER_DIR="$2"; shift 2 ;;
    --file-list)
      [ "$#" -ge 2 ] || die 1 "--file-list requires a path"
      FILE_LIST="$2"; shift 2 ;;
    --timeout)
      [ "$#" -ge 2 ] || die 1 "--timeout requires seconds"
      TIMEOUT_OVERRIDE="$2"; shift 2 ;;
    --config)
      [ "$#" -ge 2 ] || die 1 "--config requires a path"
      CONFIG="$2"; shift 2 ;;
    --runtime-profile)
      [ "$#" -ge 2 ] || die 1 "--runtime-profile requires a value"
      RUNTIME_PROFILE_OVERRIDE="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die 1 "unknown argument: $1" ;;
  esac
done

[ -n "$ADAPTER_DIR" ] || die 1 "missing required --adapter-dir <path>"
[ -n "$FILE_LIST" ]   || die 1 "missing required --file-list <path>"

[ -d "$ADAPTER_DIR" ] || die 1 "adapter-dir not found: $ADAPTER_DIR"

ADAPTER_JSON="$ADAPTER_DIR/adapter.json"
[ -f "$ADAPTER_JSON" ] || die 1 "adapter.json not found in: $ADAPTER_DIR"

command -v jq >/dev/null 2>&1 || die 1 "jq is required but not on PATH"

# Validate adapter.json shape.
if ! jq -e . "$ADAPTER_JSON" >/dev/null 2>&1; then
  die 1 "malformed adapter.json: invalid JSON"
fi

PROVIDER="$(jq -r '.provider // ""' "$ADAPTER_JSON")"
[ -n "$PROVIDER" ] || die 1 "adapter.json missing required field: provider"

DEFAULT_TIMEOUT="$(jq -r '."default-timeout-seconds" // 300' "$ADAPTER_JSON")"
RUNTIME_PROFILE="$(jq -r '."runtime-profile" // "subprocess"' "$ADAPTER_JSON")"
if [ -n "$RUNTIME_PROFILE_OVERRIDE" ]; then
  RUNTIME_PROFILE="$RUNTIME_PROFILE_OVERRIDE"
fi

EFFECTIVE_TIMEOUT="${TIMEOUT_OVERRIDE:-$DEFAULT_TIMEOUT}"

[ -f "$FILE_LIST" ] || die 1 "file-list not found: $FILE_LIST"

# emit <state> <skip_reason-or-empty> <error_detail-or-empty> <exit-code>
emit() {
  local state="$1" skip_reason="$2" error_detail="$3" rc="$4"
  jq -nc \
    --arg state "$state" \
    --arg skip "$skip_reason" \
    --arg err "$error_detail" \
    '{
      state: $state,
      skip_reason: (if $skip == "" then null else $skip end),
      error_detail: (if $err == "" then null else $err end)
    }'
  exit "$rc"
}

# ---------------------------------------------------------------------------
# Stage 1: not-applicable check (file-extension match).
# Project-scope adapters declare file-extensions: [] -> applicable iff file
# list is non-empty. Otherwise: applicable iff at least one line in the file
# list ends with one of the declared extensions.
# ---------------------------------------------------------------------------

EXT_COUNT="$(jq -r '
  if has("file-extensions") then (.["file-extensions"] | length) else 0 end
' "$ADAPTER_JSON")"

# Count file-list entries (excluding empty trailing newlines).
NONEMPTY_LINES="$(awk 'NF > 0 { c++ } END { print c+0 }' "$FILE_LIST")"

if [ "$EXT_COUNT" = "0" ]; then
  # Project-scope adapter: not-applicable when file-list has zero non-empty lines.
  if [ "$NONEMPTY_LINES" = "0" ]; then
    emit "not_applicable" "no files in file list (project-scope adapter)" "" 0
  fi
else
  # Extension-filtered adapter: count files matching declared extensions.
  EXTS="$(jq -r '."file-extensions"[]' "$ADAPTER_JSON")"
  matched=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    for ext in $EXTS; do
      case "$line" in
        *"$ext")
          matched=$((matched + 1))
          break
          ;;
      esac
    done
  done < "$FILE_LIST"

  if [ "$matched" = "0" ]; then
    # Build a human-readable skip_reason naming the expected category.
    CATEGORY="$(jq -r '.category // ""' "$ADAPTER_JSON")"
    EXT_LIST="$(jq -r '."file-extensions" | join(", ")' "$ADAPTER_JSON")"
    case "$CATEGORY" in
      linter|formatter|type-checker|sast)
        skip="no $EXT_LIST files in file list"
        ;;
      *)
        skip="no files matching $EXT_LIST in file list"
        ;;
    esac
    # Match the AC3 wording for TS-specific cases.
    case "$EXT_LIST" in
      *.ts*) skip="no TypeScript files in file list" ;;
      *.py*) skip="no Python files in file list" ;;
      *.go*) skip="no Go files in file list" ;;
    esac
    emit "not_applicable" "$skip" "" 0
  fi
fi

# ---------------------------------------------------------------------------
# Stage 2: availability check (binary on PATH for subprocess profile).
# ---------------------------------------------------------------------------

if [ "$RUNTIME_PROFILE" = "subprocess" ]; then
  if ! command -v "$PROVIDER" >/dev/null 2>&1; then
    printf '%s: tool not on PATH: %s (install hint: see adapter.json or your package manager)\n' \
      "$SCRIPT_NAME" "$PROVIDER" >&2
    emit "expected_and_missing" "" "" 1
  fi
elif [ "$RUNTIME_PROFILE" = "container" ]; then
  if ! command -v docker >/dev/null 2>&1; then
    printf '%s: tool not on PATH: docker (required for container runtime-profile of %s)\n' \
      "$SCRIPT_NAME" "$PROVIDER" >&2
    emit "expected_and_missing" "" "" 1
  fi
fi
# network profile: no local binary required; skip availability check here.

# ---------------------------------------------------------------------------
# Stage 3: execution check via run.sh under timeout(1) / gtimeout(1).
# ---------------------------------------------------------------------------

RUN_SH="$ADAPTER_DIR/run.sh"
[ -x "$RUN_SH" ] || die 1 "run.sh missing or not executable: $RUN_SH"

# Pick the timeout binary: GNU coreutils 'timeout' on Linux; 'gtimeout' on macOS
# via Homebrew. If neither is available, skip the timeout wrapper (the adapter
# stays bounded by run.sh's own timeout handling).
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
fi

run_args=(--input "$FILE_LIST" --runtime-profile "$RUNTIME_PROFILE" --timeout "$EFFECTIVE_TIMEOUT")
if [ -n "$CONFIG" ]; then
  run_args+=(--config "$CONFIG")
fi

# Capture stderr + exit code in a temp file (no PIPESTATUS dependency for
# portability).
STDERR_TMP="$(mktemp -t probe-stderr-XXXXXX)"
trap 'rm -f "$STDERR_TMP" 2>/dev/null || true' EXIT

if [ -n "$TIMEOUT_BIN" ]; then
  if "$TIMEOUT_BIN" "$EFFECTIVE_TIMEOUT" "$RUN_SH" "${run_args[@]}" >/dev/null 2>"$STDERR_TMP"; then
    rc=0
  else
    rc=$?
  fi
else
  if "$RUN_SH" "${run_args[@]}" >/dev/null 2>"$STDERR_TMP"; then
    rc=0
  else
    rc=$?
  fi
fi

if [ "$rc" -ne 0 ]; then
  # GNU timeout exits 124 on timeout; some platforms 128+15 (143). Map both.
  err_msg="$(tr -d '\r' < "$STDERR_TMP" | tr '\n' ' ' | sed 's/ *$//')"
  if [ "$rc" = "124" ] || [ "$rc" = "143" ]; then
    err_msg="timeout: run.sh exceeded ${EFFECTIVE_TIMEOUT}s"
  fi
  if [ -z "$err_msg" ]; then
    err_msg="run.sh exited with code $rc"
  fi
  emit "ran_and_errored" "" "$err_msg" 1
fi

# ---------------------------------------------------------------------------
# Stage 4: success.
# ---------------------------------------------------------------------------

emit "available" "" "" 0
