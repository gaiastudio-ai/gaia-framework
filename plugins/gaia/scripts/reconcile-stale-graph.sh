#!/usr/bin/env bash
# reconcile-stale-graph.sh — stale cross_refs graph reconciliation
#
# Purpose:
#   Reconciles the declared cross_refs graph (in project-config.yaml) against
#   actual import edges detected by the existing reconcile-cross-stack detector
#   (adapters/brownfield/reconcile-cross-stack.sh).
#
#   If any actual import edge is NOT declared in cross_refs (an "undeclared"
#   edge), the affected-set is escalated to ["*"] (full-suite run) as a
#   fail-safe. An actionable report naming each undeclared edge (source stack,
#   target stack, import path) is emitted so the developer can fix the
#   cross_refs declaration.
#
#   If all actual edges are sanctioned (or no dep-graph is present), the
#   affected-set is passed through unmodified.
#
# Usage:
#   reconcile-stale-graph.sh \
#     --affected-set <json-array> \
#     [--config <project-config.yaml>] \
#     [--detected-edges-file <path>] \
#     [--report-file <path>] \
#     [--help]
#
# Flags:
#   --affected-set JSON    Required. JSON array of affected stack names, e.g.
#                          '["stack-a","stack-b"]' or '["*"]'.
#   --config PATH          Path to project-config.yaml. Required for detector
#                          invocation; graceful passthrough if absent.
#   --detected-edges-file  Test seam: path to a dep-graph JSON file
#                          {"edges":[{"source","target"}]} fed directly to the
#                          detector as XSTACK_DEPGRAPH.  When absent the default
#                          brownfield depgraph path is used.
#   --report-file PATH     Write the escalation report here instead of stderr.
#   --help                 Print usage and exit 0.
#
# Output:
#   stdout — well-formed JSON array: either the original affected-set or ["*"].
#   stderr / --report-file — actionable escalation report (undeclared edges).
#
# Exit codes:
#   0 — success
#   1 — caller error (missing required args)
#
# Design notes:
#   - Reuses adapters/brownfield/reconcile-cross-stack.sh for edge detection;
#     does NOT reimplement edge detection logic (AC5).
#   - The detector's WARNING lines are on STDOUT (not stderr) — they are
#     captured via command substitution with stderr redirected to /dev/null.
#   - ["*"] input passes through immediately; no detector call is made.
#   - Missing dep-graph, missing config, or absent yq/jq → graceful passthrough
#     (outputs the affected-set unmodified, exits 0).
#   - POSIX awk-compatible (no gensub, no 3-arg match).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="reconcile-stale-graph.sh"
log_info()  { printf 'INFO: %s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
log_warn()  { printf 'WARNING: %s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
DETECTOR_PATH="${HERE}/adapters/brownfield/reconcile-cross-stack.sh"

# Global state — initialized empty; populated by parse_unsanctioned_edges.
XSTACK_VIOLATIONS=()

# ---------------------------------------------------------------------------
# usage — print help to stdout and exit 0
# ---------------------------------------------------------------------------
usage() {
  cat <<'USAGE'
Usage:
  reconcile-stale-graph.sh \
    --affected-set <json-array> \
    [--config <project-config.yaml>] \
    [--detected-edges-file <path>] \
    [--report-file <path>] \
    [--help]

Options:
  --affected-set JSON    Required. JSON array of affected stacks (or ["*"]).
  --config PATH          Path to project-config.yaml.
  --detected-edges-file  Test seam: dep-graph JSON used as XSTACK_DEPGRAPH.
  --report-file PATH     Write escalation report to this file (default: stderr).
  --help                 Print this message and exit.

Exit codes:
  0  Success.
  1  Caller error (missing required args).
USAGE
}

# ---------------------------------------------------------------------------
# parse_args — populate CONFIG, AFFECTED_SET_JSON, DETECTED_EDGES_FILE,
#              REPORT_FILE
# ---------------------------------------------------------------------------
parse_args() {
  CONFIG=""
  AFFECTED_SET_JSON=""
  DETECTED_EDGES_FILE=""
  REPORT_FILE=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --config)
        CONFIG="$2"; shift 2 ;;
      --affected-set)
        AFFECTED_SET_JSON="$2"; shift 2 ;;
      --detected-edges-file)
        DETECTED_EDGES_FILE="$2"; shift 2 ;;
      --report-file)
        REPORT_FILE="$2"; shift 2 ;;
      --help|-h)
        usage; exit 0 ;;
      *)
        printf '%s: unknown option: %s\n' "$SCRIPT_NAME" "$1" >&2
        exit 1 ;;
    esac
  done

  if [ -z "$AFFECTED_SET_JSON" ]; then
    printf '%s: --affected-set is required\n' "$SCRIPT_NAME" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# parse_affected_set — check for ["*"] wildcard and handle early passthrough
#
# Side-effects: sets AFFECTED_SET_IS_WILDCARD=1 if input is ["*"].
# ---------------------------------------------------------------------------
parse_affected_set() {
  AFFECTED_SET_IS_WILDCARD=0
  # Strip outer whitespace and brackets to check for wildcard.
  local inner="$AFFECTED_SET_JSON"
  inner="${inner#"${inner%%[! ]*}"}"
  inner="${inner%"${inner##*[! ]}"}"
  inner="${inner#\[}"
  inner="${inner%\]}"
  inner="${inner#"${inner%%[! ]*}"}"
  inner="${inner%"${inner##*[! ]}"}"
  # Strip quotes around * if present
  inner="${inner#\"}"
  inner="${inner%\"}"
  inner="${inner#\'}"
  inner="${inner%\'}"
  if [ "$inner" = "*" ]; then
    AFFECTED_SET_IS_WILDCARD=1
  fi
}

# ---------------------------------------------------------------------------
# build_depgraph_for_detector — resolve XSTACK_DEPGRAPH path
#
# If --detected-edges-file was given, uses that path directly.
# If the resolved path does not exist, sets DEPGRAPH_MISSING=1.
# ---------------------------------------------------------------------------
build_depgraph_for_detector() {
  DEPGRAPH_PATH=""
  DEPGRAPH_MISSING=0

  if [ -n "$DETECTED_EDGES_FILE" ]; then
    DEPGRAPH_PATH="$DETECTED_EDGES_FILE"
  else
    # Resolve default brownfield depgraph path.
    if [ -n "${GAIA_MEMORY_DIR:-}" ]; then
      DEPGRAPH_PATH="${GAIA_MEMORY_DIR}/brownfield-audit/depgraph.json"
    else
      DEPGRAPH_PATH="./.gaia/memory/brownfield-audit/depgraph.json"
    fi
  fi

  if [ ! -f "$DEPGRAPH_PATH" ]; then
    DEPGRAPH_MISSING=1
  fi
}

# ---------------------------------------------------------------------------
# invoke_detector — run reconcile-cross-stack.sh and CAPTURE STDOUT
#
# The detector's WARNING lines are on STDOUT (not stderr).  We capture stdout
# and discard stderr (telemetry / INFO lines) to avoid noise.
#
# Populates: DETECTOR_OUTPUT (captured stdout)
# ---------------------------------------------------------------------------
invoke_detector() {
  DETECTOR_OUTPUT=""

  if [ ! -f "$DETECTOR_PATH" ]; then
    log_warn "detector not found at $DETECTOR_PATH — passthrough"
    return 0
  fi

  # CAPTURE STDOUT — WARNING lines from the detector appear on stdout, not stderr.
  DETECTOR_OUTPUT="$(
    XSTACK_CONFIG="${CONFIG:-}" \
    XSTACK_DEPGRAPH="$DEPGRAPH_PATH" \
    GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
    GAIA_BROWNFIELD_PHASE_4B_CROSS_STACK_ENABLED=true \
    bash "$DETECTOR_PATH" 2>/dev/null
  )" || true
}

# ---------------------------------------------------------------------------
# parse_unsanctioned_edges — extract undeclared edges from detector output
#
# The detector emits lines of the form:
#   WARNING: <SCRIPT_NAME>: unsanctioned-cross-stack-reference: <src_stack>:<src_file> -> <tgt_stack>:<tgt_file>
#
# We grep for the key phrase 'unsanctioned-cross-stack-reference:' (anchored
# after a SCRIPT_NAME field, not directly after "WARNING: "), then use POSIX
# awk to extract the TSV: src_stack, src_file, tgt_stack, tgt_file.
#
# Populates: XSTACK_VIOLATIONS (array of lines "src_stack:src_file -> tgt_stack:tgt_file")
# ---------------------------------------------------------------------------
parse_unsanctioned_edges() {
  XSTACK_VIOLATIONS=()

  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Extract the "src_stack:src_file -> tgt_stack:tgt_file" fragment.
    local fragment
    fragment="$(printf '%s' "$line" | awk '
      /unsanctioned-cross-stack-reference:/ {
        # Find the last occurrence of "unsanctioned-cross-stack-reference: "
        idx = index($0, "unsanctioned-cross-stack-reference: ")
        if (idx > 0) {
          frag = substr($0, idx + length("unsanctioned-cross-stack-reference: "))
          # Trim leading/trailing whitespace
          gsub(/^[[:space:]]+/, "", frag)
          gsub(/[[:space:]]+$/, "", frag)
          print frag
        }
      }
    ')" || true
    if [ -n "$fragment" ]; then XSTACK_VIOLATIONS+=("$fragment"); fi
  done <<EOF
$DETECTOR_OUTPUT
EOF
}

# ---------------------------------------------------------------------------
# emit_report — write an actionable report for each undeclared edge
#
# Writes to --report-file if set; otherwise to stderr.
# ---------------------------------------------------------------------------
emit_report() {
  local target_fd
  if [ -n "$REPORT_FILE" ]; then
    # Write to file.
    {
      printf 'reconcile-stale-graph: undeclared cross-stack edges detected — escalating to full suite\n'
      local v
      for v in "${XSTACK_VIOLATIONS[@]+"${XSTACK_VIOLATIONS[@]}"}"; do
        # Parse "src_stack:src_file -> tgt_stack:tgt_file"
        local src_part tgt_part src_stack src_file tgt_stack tgt_file
        src_part="${v%% -> *}"
        tgt_part="${v##* -> }"
        src_stack="${src_part%%:*}"
        src_file="${src_part#*:}"
        tgt_stack="${tgt_part%%:*}"
        tgt_file="${tgt_part#*:}"
        printf '  UNDECLARED: source_stack=%s source_file=%s target_stack=%s target_file=%s\n' \
          "$src_stack" "$src_file" "$tgt_stack" "$tgt_file"
      done
      printf 'Fix: add the missing cross_refs entry in project-config.yaml or remove the import.\n'
    } > "$REPORT_FILE"
  else
    # Write to stderr.
    printf 'reconcile-stale-graph: undeclared cross-stack edges detected — escalating to full suite\n' >&2
    local v
    for v in "${XSTACK_VIOLATIONS[@]+"${XSTACK_VIOLATIONS[@]}"}"; do
      local src_part tgt_part src_stack src_file tgt_stack tgt_file
      src_part="${v%% -> *}"
      tgt_part="${v##* -> }"
      src_stack="${src_part%%:*}"
      src_file="${src_part#*:}"
      tgt_stack="${tgt_part%%:*}"
      tgt_file="${tgt_part#*:}"
      printf '  UNDECLARED: source_stack=%s source_file=%s target_stack=%s target_file=%s\n' \
        "$src_stack" "$src_file" "$tgt_stack" "$tgt_file" >&2
    done
    printf 'Fix: add the missing cross_refs entry in project-config.yaml or remove the import.\n' >&2
  fi
}

# ---------------------------------------------------------------------------
# reconcile — orchestrate the full reconciliation flow
# ---------------------------------------------------------------------------
reconcile() {
  # AC4 pre-flight: if yq or jq are absent, degrade gracefully.
  if ! command -v yq >/dev/null 2>&1; then
    log_warn "yq not found — stale-graph reconciliation skipped (passthrough)"
    printf '%s\n' "$AFFECTED_SET_JSON"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    log_warn "jq not found — stale-graph reconciliation skipped (passthrough)"
    printf '%s\n' "$AFFECTED_SET_JSON"
    return 0
  fi

  build_depgraph_for_detector

  if [ "$DEPGRAPH_MISSING" -eq 1 ]; then
    log_info "dep-graph not found at $DEPGRAPH_PATH — stale-graph reconciliation skipped (passthrough)"
    printf '%s\n' "$AFFECTED_SET_JSON"
    return 0
  fi

  if [ -z "$CONFIG" ] || [ ! -f "$CONFIG" ]; then
    log_info "no project-config — stale-graph reconciliation skipped (passthrough)"
    printf '%s\n' "$AFFECTED_SET_JSON"
    return 0
  fi

  invoke_detector
  parse_unsanctioned_edges

  if [ "${#XSTACK_VIOLATIONS[@]}" -eq 0 ]; then
    # AC4: no undeclared edges — pass through unmodified.
    printf '%s\n' "$AFFECTED_SET_JSON"
    return 0
  fi

  # AC2+AC3: undeclared edge found — escalate + report.
  emit_report
  printf '["*"]\n'
}

# ---------------------------------------------------------------------------
# main — entry point
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  parse_affected_set

  # AC2 early passthrough: ["*"] input passes through immediately.
  if [ "$AFFECTED_SET_IS_WILDCARD" -eq 1 ]; then
    printf '["*"]\n'
    return 0
  fi

  reconcile
}

# Main-guard: only invoke main when executed directly (not when sourced).
# Required for NFR-052 — sourcing must expose public functions without side-effects.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
