#!/usr/bin/env bash
# qa-test-runner.sh — E67-S4 project-config-driven test execution for
# /gaia-review-qa. Resolves tier placement against GAIA_EXECUTION_CONTEXT,
# runs the configured per-tier command (with timeout enforcement), and writes
# execution-evidence.json into the per-story workdir.
#
# Public API:
#   qa-test-runner.sh --story-key <key> --workdir <dir> --config <yaml> [--context <ctx>]
#   qa-test-runner.sh --help
#
# Output:
#   <workdir>/execution-evidence.json validating against
#   plugins/gaia/schemas/execution-evidence.schema.json.
#
# Exit codes:
#   0  evidence written (regardless of suite pass/fail — verdict resolution
#      is done by verdict-resolver.sh consuming the evidence)
#   1  caller error (missing required flag, unparseable config)
#
# Refs: AC3, AC4, AC5, AC6, AC7, AC8, AC10, FR-RSV2-2, FR-RSV2-11,
#       ADR-044, ADR-075, ADR-077.
#
# POSIX discipline: bash 3.2 (macOS), set -euo pipefail, LC_ALL=C, no
# associative arrays. jq is optional (used only for the bridge JSON parse
# path and for the final evidence emission); the YAML parsing is awk/grep
# based to keep the runtime free of jq for the core read path.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="qa-test-runner.sh"

err() { printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { err "$*"; exit 1; }
info() { printf '%s: INFO: %s\n' "$SCRIPT_NAME" "$*" >&2; }

usage() {
  cat <<EOF
$SCRIPT_NAME — project-config-driven test execution for /gaia-review-qa.

Usage:
  $SCRIPT_NAME --story-key <key> --workdir <dir> --config <yaml> [--context <ctx>]
  $SCRIPT_NAME --help

Required:
  --story-key <key>   Story key (e.g., E67-S4) — used for the audit trail.
  --workdir <dir>     Output directory (writes execution-evidence.json here).
  --config <yaml>     Path to project-config.yaml (or a merged equivalent).

Optional:
  --context <ctx>     Override GAIA_EXECUTION_CONTEXT
                      (local | ci_pre_merge | ci_post_merge | deployment | post_deploy).

Behavior:
  - Parses test_execution.tier_{1,2,3}.placement and matches against the
    active context.
  - Runs each matching tier's "command" with "timeout_seconds" enforcement
    (POSIX-portable timeout — perl alarm fallback for macOS bash 3.2).
  - When test_execution_bridge.bridge_enabled=true, delegates execution to
    the configured run_tests_path (Test Execution Bridge / E17 / ADR-044).
  - When test_execution is absent, writes a skipped=true evidence document
    and returns exit 0 with an INFO diagnostic.
EOF
}

# ---------- arg parsing ----------

STORY_KEY=""
WORKDIR=""
CONFIG=""
CONTEXT_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --story-key)
      [ $# -ge 2 ] || die "--story-key requires a value"
      STORY_KEY="$2"; shift 2 ;;
    --workdir)
      [ $# -ge 2 ] || die "--workdir requires a path"
      WORKDIR="$2"; shift 2 ;;
    --config)
      [ $# -ge 2 ] || die "--config requires a path"
      CONFIG="$2"; shift 2 ;;
    --context)
      [ $# -ge 2 ] || die "--context requires a value"
      CONTEXT_OVERRIDE="$2"; shift 2 ;;
    *) die "unknown flag: $1" ;;
  esac
done

[ -n "$STORY_KEY" ] || die "missing --story-key"
[ -n "$WORKDIR" ] || die "missing --workdir"
[ -n "$CONFIG" ] || die "missing --config"

# Validate story_key shape (T-37 mitigation — keys flow into workdir paths).
case "$STORY_KEY" in
  E*[0-9]*-S*[0-9]*) : ;;
  *) die "invalid --story-key shape '$STORY_KEY' (expected E<N>-S<N>)" ;;
esac

mkdir -p "$WORKDIR"
EVIDENCE="$WORKDIR/execution-evidence.json"

# Resolve context.
CONTEXT="${CONTEXT_OVERRIDE:-${GAIA_EXECUTION_CONTEXT:-local}}"
case "$CONTEXT" in
  local|ci_pre_merge|ci_post_merge|deployment|post_deploy) : ;;
  *) die "invalid context '$CONTEXT' (expected one of: local, ci_pre_merge, ci_post_merge, deployment, post_deploy)" ;;
esac

# ---------- YAML helpers (awk-based, bash 3.2 portable) ----------

# Print the indented value of test_execution.<tier>.<key> from $CONFIG.
# Returns empty string when not present.
yaml_get_tier_field() {
  local tier="$1" field="$2"
  awk -v T="$tier" -v F="$field" '
    BEGIN { in_te=0; in_tier=0; in_subtier=0 }
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function strip_quotes(s) {
      if (length(s) >= 2) {
        first=substr(s,1,1); last=substr(s,length(s),1)
        if ((first=="\"" && last=="\"") || (first=="'\''" && last=="'\''")) {
          return substr(s, 2, length(s)-2)
        }
      }
      return s
    }
    /^[^[:space:]#]/ {
      # top-level key; reset.
      if ($0 ~ /^test_execution[[:space:]]*:/) { in_te=1; in_tier=0; next }
      in_te=0; in_tier=0; next
    }
    in_te && /^[[:space:]]+[A-Za-z0-9_]+:/ {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      indent=length($0) - length(line)
      if (indent == 2) {
        # tier line
        key=line; sub(/:.*$/, "", key)
        if (key == T) { in_tier=1 } else { in_tier=0 }
        next
      }
      if (indent == 4 && in_tier) {
        key=line; sub(/:.*$/, "", key)
        val=line; sub(/^[^:]*:[[:space:]]*/, "", val)
        if (key == F) {
          val=trim(val)
          val=strip_quotes(val)
          print val
          exit
        }
      }
    }
  ' "$CONFIG"
}

# Print the value of test_execution_bridge.<key> from $CONFIG.
yaml_get_bridge_field() {
  local field="$1"
  awk -v F="$field" '
    BEGIN { in_b=0 }
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function strip_quotes(s) {
      if (length(s) >= 2) {
        first=substr(s,1,1); last=substr(s,length(s),1)
        if ((first=="\"" && last=="\"") || (first=="'\''" && last=="'\''")) {
          return substr(s, 2, length(s)-2)
        }
      }
      return s
    }
    /^[^[:space:]#]/ {
      if ($0 ~ /^test_execution_bridge[[:space:]]*:/) { in_b=1; next }
      in_b=0; next
    }
    in_b && /^[[:space:]]+[A-Za-z0-9_]+:/ {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      indent=length($0) - length(line)
      if (indent == 2) {
        key=line; sub(/:.*$/, "", key)
        val=line; sub(/^[^:]*:[[:space:]]*/, "", val)
        if (key == F) {
          val=trim(val)
          val=strip_quotes(val)
          print val
          exit
        }
      }
    }
  ' "$CONFIG"
}

# Map placement (config dialect "ci-pre-merge") to context (env dialect
# "ci_pre_merge"). Done so a single equality check decides if a tier runs.
placement_matches_context() {
  local placement="$1" context="$2"
  local norm
  norm="$(printf '%s' "$placement" | tr '-' '_')"
  [ "$norm" = "$context" ]
}

# ---------- timeout helper (POSIX-portable) ----------

# Run "$1" (full command string) with a wall-clock cap of "$2" seconds.
# Records into globals: RT_EXIT, RT_DURATION, RT_TIMEOUT, RT_OUTPUT.
run_with_timeout() {
  local cmd="$1" timeout_seconds="$2"
  local start_ns end_ns out_file
  out_file="$(mktemp 2>/dev/null || mktemp -t qatestrun)"

  # Prefer GNU/BSD `timeout` when present; fall back to perl alarm.
  start_ns="$(perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time()' 2>/dev/null \
              || awk 'BEGIN{srand(); print systime()}')"

  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout --preserve-status "${timeout_seconds}" sh -c "$cmd" >"$out_file" 2>&1
    RT_EXIT=$?
  else
    perl -e '
      $SIG{ALRM}=sub{ kill(9, -$$); exit 124 };
      alarm($ARGV[0]);
      exec("/bin/sh","-c",$ARGV[1]);
    ' "$timeout_seconds" "$cmd" >"$out_file" 2>&1
    RT_EXIT=$?
  fi
  set -e

  end_ns="$(perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time()' 2>/dev/null \
            || awk 'BEGIN{srand(); print systime()}')"
  RT_DURATION="$(awk -v a="$start_ns" -v b="$end_ns" 'BEGIN{ d=b-a; if (d<0) d=0; printf "%.3f", d }')"

  # `timeout` exits 124 on timeout; perl alarm path also returns 124.
  if [ "$RT_EXIT" = "124" ] || [ "$RT_EXIT" = "137" ] || [ "$RT_EXIT" = "143" ]; then
    RT_TIMEOUT=true
  else
    RT_TIMEOUT=false
  fi
  RT_OUTPUT_FILE="$out_file"
}

# ---------- bridge delegation ----------

run_bridge() {
  local run_tests_path="$1"
  if [ ! -x "$run_tests_path" ]; then
    info "bridge enabled but run_tests_path not executable: $run_tests_path — falling back to direct execution"
    BRIDGE_USED=false
    return 1
  fi
  BRIDGE_USED=true
  local start_ns end_ns out_file
  out_file="$(mktemp 2>/dev/null || mktemp -t qabridge)"
  start_ns="$(perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time()' 2>/dev/null || date +%s)"
  set +e
  "$run_tests_path" --story-key "$STORY_KEY" --context "$CONTEXT" >"$out_file" 2>&1
  local rc=$?
  set -e
  end_ns="$(perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time()' 2>/dev/null || date +%s)"
  local dur
  dur="$(awk -v a="$start_ns" -v b="$end_ns" 'BEGIN{ d=b-a; if (d<0) d=0; printf "%.3f", d }')"

  # Try to parse the bridge's stdout as JSON; fall back to a synthetic suite.
  if command -v jq >/dev/null 2>&1 && jq empty "$out_file" >/dev/null 2>&1; then
    BRIDGE_SUITES_JSON="$(jq -c '.suites // []' "$out_file" 2>/dev/null || printf '[]')"
  else
    BRIDGE_SUITES_JSON='[]'
  fi
  BRIDGE_EXIT="$rc"
  BRIDGE_DURATION="$dur"
  rm -f "$out_file"
  return 0
}

# ---------- main ----------

run_start_ns="$(perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time()' 2>/dev/null || date +%s)"

# Detect bridge.
BRIDGE_ENABLED="$(yaml_get_bridge_field bridge_enabled || true)"
BRIDGE_PATH="$(yaml_get_bridge_field run_tests_path || true)"
BRIDGE_USED=false

# Detect test_execution presence.
TIER1_PLACEMENT="$(yaml_get_tier_field tier_1 placement || true)"
TIER2_PLACEMENT="$(yaml_get_tier_field tier_2 placement || true)"
TIER3_PLACEMENT="$(yaml_get_tier_field tier_3 placement || true)"

# Helper to build a JSON-string-safe value.
json_escape() {
  # %s through python? No — keep it bash 3.2 + awk. Escape backslash, quote,
  # newline, tab, CR.
  awk 'BEGIN{ ORS="" }
    {
      gsub(/\\/, "\\\\")
      gsub(/"/, "\\\"")
      gsub(/\t/, "\\t")
      gsub(/\r/, "\\r")
      print
      if (NR < n) print "\\n"
    }
  ' n="$(printf '%s' "$1" | wc -l | awk '{print $1+1}')" <<<"$1"
}

# Simpler escaper avoiding here-string portability concerns:
json_str() {
  printf '%s' "$1" | awk '
    BEGIN { ORS=""; printf "\"" }
    {
      line=$0
      gsub(/\\/, "\\\\", line)
      gsub(/"/, "\\\"", line)
      gsub(/\t/, "\\t", line)
      gsub(/\r/, "\\r", line)
      if (NR>1) printf "\\n"
      printf "%s", line
    }
    END { printf "\"" }
  '
}

emit_skipped_evidence() {
  local reason="$1"
  cat > "$EVIDENCE" <<EOF
{
  "tier": "none",
  "context": $(json_str "$CONTEXT"),
  "wall_clock_seconds": 0,
  "skipped": true,
  "bridge_used": false,
  "suites": [],
  "diagnostics": [$(json_str "$reason")]
}
EOF
}

# Test execution absent? — AC7 graceful skip.
if [ -z "$TIER1_PLACEMENT" ] && [ -z "$TIER2_PLACEMENT" ] && [ -z "$TIER3_PLACEMENT" ]; then
  info "test_execution not configured; skipping test execution"
  emit_skipped_evidence "test_execution not configured; skipping test execution"
  exit 0
fi

# Build the list of tiers whose placement matches the active context.
ACTIVE_TIERS=()
ACTIVE_PLACEMENTS=()
for tier in tier_1 tier_2 tier_3; do
  case "$tier" in
    tier_1) plc="$TIER1_PLACEMENT" ;;
    tier_2) plc="$TIER2_PLACEMENT" ;;
    tier_3) plc="$TIER3_PLACEMENT" ;;
  esac
  if [ -n "$plc" ] && placement_matches_context "$plc" "$CONTEXT"; then
    ACTIVE_TIERS+=("$tier")
    ACTIVE_PLACEMENTS+=("$plc")
  fi
done

# No tier matched the context — INFO + skipped.
if [ "${#ACTIVE_TIERS[@]}" -eq 0 ]; then
  info "no test tier matches context '$CONTEXT'; skipping"
  emit_skipped_evidence "no test tier matches context '$CONTEXT'"
  exit 0
fi

# Bridge delegation — single bridge call covers all active tiers per ADR-044.
if [ "$BRIDGE_ENABLED" = "true" ] && [ -n "$BRIDGE_PATH" ]; then
  if run_bridge "$BRIDGE_PATH"; then
    # Build evidence from bridge response.
    run_end_ns="$(perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time()' 2>/dev/null || date +%s)"
    wall="$(awk -v a="$run_start_ns" -v b="$run_end_ns" 'BEGIN{ d=b-a; if (d<0) d=0; printf "%.3f", d }')"
    # Use the suites the bridge returned; if empty, synthesize one from the bridge exit.
    if [ "$BRIDGE_SUITES_JSON" = "[]" ] || [ -z "$BRIDGE_SUITES_JSON" ]; then
      BRIDGE_SUITES_JSON="$(printf '[{"name":"bridge","command":"%s","exit_code":%s,"duration_seconds":%s,"pass_count":0,"fail_count":0,"timeout":false,"required":true}]' \
        "$BRIDGE_PATH" "$BRIDGE_EXIT" "$BRIDGE_DURATION")"
    fi
    tier_label="bridge"
    cat > "$EVIDENCE" <<EOF
{
  "tier": $(json_str "$tier_label"),
  "context": $(json_str "$CONTEXT"),
  "wall_clock_seconds": $wall,
  "skipped": false,
  "bridge_used": true,
  "suites": $BRIDGE_SUITES_JSON,
  "diagnostics": []
}
EOF
    exit 0
  fi
fi

# Direct execution path — run each active tier with its own timeout.
SUITES_JSON_PARTS=()
overall_required_failure=false
for i in $(seq 0 $((${#ACTIVE_TIERS[@]} - 1))); do
  tier="${ACTIVE_TIERS[$i]}"
  cmd="$(yaml_get_tier_field "$tier" command || true)"
  to="$(yaml_get_tier_field "$tier" timeout_seconds || true)"
  required="$(yaml_get_tier_field "$tier" required || true)"
  [ -n "$to" ] || to=300
  [ -n "$required" ] || required=true
  if [ -z "$cmd" ]; then
    # No command declared for an active tier — record as skipped suite.
    suite_json="$(printf '{"name":%s,"command":"","exit_code":0,"duration_seconds":0,"pass_count":0,"fail_count":0,"timeout":false,"required":%s,"skip_reason":"no command declared"}' \
      "$(json_str "$tier")" "$required")"
    SUITES_JSON_PARTS+=("$suite_json")
    continue
  fi
  run_with_timeout "$cmd" "$to"
  rm -f "$RT_OUTPUT_FILE" || true
  pass_count=0
  fail_count=0
  if [ "$RT_EXIT" -ne 0 ] && [ "$RT_TIMEOUT" = "false" ]; then
    fail_count=1
  elif [ "$RT_EXIT" -eq 0 ]; then
    pass_count=1
  fi
  suite_json="$(printf '{"name":%s,"command":%s,"exit_code":%s,"duration_seconds":%s,"pass_count":%s,"fail_count":%s,"timeout":%s,"required":%s}' \
    "$(json_str "$tier")" \
    "$(json_str "$cmd")" \
    "$RT_EXIT" \
    "$RT_DURATION" \
    "$pass_count" \
    "$fail_count" \
    "$RT_TIMEOUT" \
    "$required")"
  SUITES_JSON_PARTS+=("$suite_json")
done

# Wall clock.
run_end_ns="$(perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time()' 2>/dev/null || date +%s)"
wall="$(awk -v a="$run_start_ns" -v b="$run_end_ns" 'BEGIN{ d=b-a; if (d<0) d=0; printf "%.3f", d }')"

# Resolve the "tier" top-level field — single-tier label, multi-tier "multi".
if [ "${#ACTIVE_TIERS[@]}" -eq 1 ]; then
  TIER_LABEL="${ACTIVE_TIERS[0]}"
else
  TIER_LABEL="multi"
fi

# Join suites JSON parts.
suites_json="["
for i in $(seq 0 $((${#SUITES_JSON_PARTS[@]} - 1))); do
  if [ "$i" -gt 0 ]; then suites_json="${suites_json},"; fi
  suites_json="${suites_json}${SUITES_JSON_PARTS[$i]}"
done
suites_json="${suites_json}]"

cat > "$EVIDENCE" <<EOF
{
  "tier": $(json_str "$TIER_LABEL"),
  "context": $(json_str "$CONTEXT"),
  "wall_clock_seconds": $wall,
  "skipped": false,
  "bridge_used": false,
  "suites": $suites_json,
  "diagnostics": []
}
EOF

exit 0
