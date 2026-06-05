#!/usr/bin/env bash
# tool-availability-probe.sh — GAIA shared review-skill helper.
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
# Output (stdout) is a single-line JSON object with exactly four keys:
#   {"state":"<state>",
#    "skip_reason":<string|null>,
#    "error_detail":<string|null>,
#    "failure_kind":<enum|null>}
#
# failure_kind enum:
#   - "tool_missing"      — emitted when state == expected_and_missing
#   - "version_mismatch"  — reserved for a future version-check stage; not
#                           currently emitted by this probe
#   - "runtime_crash"     — emitted when state == ran_and_errored and the
#                           failure is a non-timeout non-zero exit
#   - "timeout"           — emitted when state == ran_and_errored and the
#                           failure is a timeout (rc 124 / 143)
#   - null                — emitted when state == available or not_applicable
#
# The field is additive: callers reading state/skip_reason/error_detail
# continue to work unchanged. New callers can branch on failure_kind to make
# structured decisions without parsing free-text error_detail.
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
# Determinism
# -----------
# `set -euo pipefail` + `LC_ALL=C` + per-stage strict ordering guarantee that
# identical inputs produce byte-identical output every invocation. The probe
# does not read environment beyond PATH and a single timeout binary lookup.

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
$SCRIPT_NAME — tool-availability probe for GAIA adapters.

Two operating modes:

(1) Adapter-dir mode (legacy / per-adapter probe):
  $SCRIPT_NAME --adapter-dir <path> --file-list <path>
               [--timeout <seconds>] [--config <path>]
               [--runtime-profile subprocess|container|network]

(2) Tri-state mode:
  $SCRIPT_NAME --tool <name> --config <project-config.yaml>

  $SCRIPT_NAME --help

Required (mode 1):
  --adapter-dir <path>      Adapter directory containing adapter.json + run.sh.
  --file-list <path>        File list to feed the adapter (one path per line).

Required (mode 2):
  --tool <name>             Tool key as it appears under tool_adapters: in
                            project-config.yaml.
  --config <path>           Path to project-config.yaml (mode 2) or adapter
                            config file (mode 1).

Optional (mode 1):
  --timeout <seconds>       Override adapter.json default-timeout-seconds.
  --runtime-profile <prof>  subprocess | container | network. Defaults to
                            adapter.json runtime-profile.
  --help                    Show this help and exit 0.

Mode-1 states (stdout JSON):
  available             Tool installed, files match, run.sh exits 0.
  expected_and_missing  Tool declared in adapter.json but not on PATH.
  ran_and_errored       run.sh exits non-zero or times out.
  not_applicable        File list has no files matching adapter file-extensions.

Mode-2 tri-state classification:
  omitted   No tool_adapters.<name> entry. Skip — exit 0, no output.
  null      Entry present, value null. Probe; on missing binary emit
            advisory WARNING. Recoverable; never CRITICAL.
  declared  Entry present, value is a map. Probe; on missing binary emit
            WARNING (downgrade from CRITICAL).

Exit codes (mode 1):
  0  available | not_applicable
  1  expected_and_missing | ran_and_errored | caller error

Exit codes (mode 2):
  0  All tri-state outcomes (omitted / null / declared / available / missing).
  1  Caller error (missing flag, malformed YAML, etc.).
EOF
}

ADAPTER_DIR=""
FILE_LIST=""
TIMEOUT_OVERRIDE=""
CONFIG=""
RUNTIME_PROFILE_OVERRIDE=""
TOOL_NAME=""

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
    --tool)
      [ "$#" -ge 2 ] || die 1 "--tool requires a name"
      TOOL_NAME="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die 1 "unknown argument: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Mode dispatch.
# --tool selects tri-state mode; --adapter-dir selects legacy single-adapter
# mode. They are mutually exclusive — passing both is a caller error.
# ---------------------------------------------------------------------------

if [ -n "$TOOL_NAME" ] && [ -n "$ADAPTER_DIR" ]; then
  die 1 "--tool and --adapter-dir are mutually exclusive"
fi

if [ -n "$TOOL_NAME" ]; then
  # Tri-state mode.
  [ -n "$CONFIG" ] || die 1 "--tool requires --config <project-config.yaml>"
  [ -f "$CONFIG" ] || die 1 "config not found: $CONFIG"

  # classify_tool_adapter_entry <yaml-path> <tool-name>
  # Stdout: one of "omitted", "null", "declared".
  # Pure-bash deterministic parser for the narrow shape we care about:
  #
  #   tool_adapters:
  #     <name>: null     # null state
  #     <name>:          # null state (bare key, empty value)
  #     <name>:          # declared state when followed by an indented map
  #       path: ...
  #
  # The parser is intentionally minimal — yq is not assumed on PATH (determinism
  # guarantee: no extra runtime deps). Comments and blank lines are skipped.
  # Bracketed inline maps `<name>: { path: ... }` are treated as declared.
  # Classifier. Recognised value forms for the tool key:
  #   "<name>: null" | "<name>: ~" | "<name>:"           -> null   (unless a
  #                                                                  deeper-
  #                                                                  indented
  #                                                                  child
  #                                                                  follows;
  #                                                                  then declared)
  #   "<name>: { ... }"                                  -> declared
  #   "<name>: <scalar>" (path, version-spec, etc.)      -> declared
  #
  # YAML trailing-comment handling: we strip "# ..." from the value side.
  # Block-scope handling: the first column-0 key after `tool_adapters:` ends
  # the block. Sibling keys at the same two-space indent end the current
  # entry's child-scan window.
  classify_tool_adapter_entry() {
    local yaml="$1" tool="$2"
    awk -v tool="$tool" '
      function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
      function strip_comment(s) { sub(/[[:space:]]*#.*$/, "", s); return s }
      BEGIN { in_block = 0; verdict = "omitted" }
      # Skip pure-comment and blank lines.
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*$/ { next }
      # Enter the tool_adapters: block.
      /^tool_adapters[[:space:]]*:/ { in_block = 1; next }
      # New top-level key ends the block.
      in_block && /^[^[:space:]]/ { in_block = 0 }
      in_block {
        re = "^[[:space:]]+" tool "[[:space:]]*:[[:space:]]*(.*)$"
        if (match($0, re)) {
          val = $0
          sub("^[[:space:]]+" tool "[[:space:]]*:[[:space:]]*", "", val)
          val = trim(strip_comment(val))
          if (val == "" || val == "null" || val == "~") {
            verdict = "null"
          } else {
            # { ... } inline map OR any scalar (path, version, etc.) -> declared.
            verdict = "declared"
          }
          # Promote null -> declared if a deeper-indented child follows before
          # the next sibling or end-of-block.
          while ((getline next_line) > 0) {
            if (next_line ~ /^[[:space:]]*#/) continue
            if (next_line ~ /^[[:space:]]*$/) continue
            if (next_line ~ /^[^[:space:]]/) break              # column-0 -> end of block
            if (next_line ~ /^[[:space:]]{2}[^[:space:]]/) break # sibling at 2-space indent
            if (next_line ~ /^[[:space:]]{3,}/) { verdict = "declared" }
          }
          exit
        }
      }
      END { print verdict }
    ' "$yaml"
  }

  STATE="$(classify_tool_adapter_entry "$CONFIG" "$TOOL_NAME")"

  case "$STATE" in
    omitted)
      # AC1: no probe call, no advisory output.
      exit 0
      ;;
    null|declared)
      # Probe binary on PATH.
      if command -v "$TOOL_NAME" >/dev/null 2>&1; then
        AVAILABLE=true
        SEVERITY=""
        if [ "$STATE" = "null" ]; then
          MSG="tool $TOOL_NAME present (null-tolerated; advisory)"
        else
          MSG="tool $TOOL_NAME present"
        fi
      else
        AVAILABLE=false
        SEVERITY="WARNING"
        if [ "$STATE" = "null" ]; then
          MSG="advisory: declared-unknown tool $TOOL_NAME not on PATH (null-tolerated; install to enable)"
        else
          MSG="declared tool $TOOL_NAME not on PATH (recoverable; install to enable)"
        fi
      fi
      jq -nc \
        --arg ps "$STATE" \
        --argjson avail "$AVAILABLE" \
        --arg sev "$SEVERITY" \
        --arg msg "$MSG" \
        --arg tool "$TOOL_NAME" \
        '{
          tool: $tool,
          probe_state: $ps,
          available: $avail,
          severity: (if $sev == "" then null else $sev end),
          message: $msg
        }'
      exit 0
      ;;
    *)
      die 1 "internal: classify_tool_adapter_entry returned unknown state: $STATE"
      ;;
  esac
fi

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

# emit <state> <skip_reason-or-empty> <error_detail-or-empty> <failure_kind-or-empty> <exit-code>
#
# failure_kind is the fifth positional arg. Pass empty string ("") to
# emit JSON null. Valid non-null values: tool_missing, version_mismatch,
# runtime_crash, timeout. The field is required in every emit() call so each
# state has an explicit failure_kind decision.
emit() {
  local state="$1" skip_reason="$2" error_detail="$3" failure_kind="$4" rc="$5"
  jq -nc \
    --arg state "$state" \
    --arg skip "$skip_reason" \
    --arg err "$error_detail" \
    --arg fk "$failure_kind" \
    '{
      state: $state,
      skip_reason: (if $skip == "" then null else $skip end),
      error_detail: (if $err == "" then null else $err end),
      failure_kind: (if $fk == "" then null else $fk end)
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
    emit "not_applicable" "no files in file list (project-scope adapter)" "" "" 0
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
    emit "not_applicable" "$skip" "" "" 0
  fi
fi

# ---------------------------------------------------------------------------
# Stage 2: availability check (binary on PATH for subprocess profile).
# ---------------------------------------------------------------------------

if [ "$RUNTIME_PROFILE" = "subprocess" ]; then
  if ! command -v "$PROVIDER" >/dev/null 2>&1; then
    printf '%s: tool not on PATH: %s (install hint: see adapter.json or your package manager)\n' \
      "$SCRIPT_NAME" "$PROVIDER" >&2
    emit "expected_and_missing" "" "" "tool_missing" 1
  fi
elif [ "$RUNTIME_PROFILE" = "container" ]; then
  if ! command -v docker >/dev/null 2>&1; then
    printf '%s: tool not on PATH: docker (required for container runtime-profile of %s)\n' \
      "$SCRIPT_NAME" "$PROVIDER" >&2
    emit "expected_and_missing" "" "" "tool_missing" 1
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
  # Classify the failure_kind based on the rc returned by the timeout wrapper
  # or run.sh itself. timeout(1) / gtimeout(1) exits 124;
  # signal-terminated children commonly surface as 128+15 = 143.
  if [ "$rc" = "124" ] || [ "$rc" = "143" ]; then
    err_msg="timeout: run.sh exceeded ${EFFECTIVE_TIMEOUT}s"
    failure_kind="timeout"
  else
    failure_kind="runtime_crash"
  fi
  if [ -z "$err_msg" ]; then
    err_msg="run.sh exited with code $rc"
  fi
  emit "ran_and_errored" "" "$err_msg" "$failure_kind" 1
fi

# ---------------------------------------------------------------------------
# Stage 4: success.
# ---------------------------------------------------------------------------

emit "available" "" "" "" 0
