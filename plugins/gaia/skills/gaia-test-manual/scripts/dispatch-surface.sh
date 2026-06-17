#!/usr/bin/env bash
# dispatch-surface.sh — dispatch a manual test for a specific surface
#
# Calls surface-adapter.sh to check configuration, then:
#   - SKIPPED (exit 2) → emit JSON {"surface","verdict":"SKIPPED","reason":"not configured"}
#   - CONFIGURED + api → run target command, capture transcript + exit code,
#     pipe run-record through write-evidence.sh, verdict = PASSED if exit 0
#     else FAILED.
#   - CONFIGURED + browser/mobile/desktop → emit JSON
#     {"surface","verdict":"PENDING","reason":"dispatch ready"} (agent dispatch
#     stays in SKILL.md; pixel-diff is deferred to a later story).
#
# Usage:
#   dispatch-surface.sh --surface <browser|api|mobile|desktop> \
#                       --target <command-or-slug> \
#                       --evidence-dir <path> \
#                       [--config <path-to-project-config.yaml>]
#
# Exit codes:
#   0 — dispatch completed (regardless of test verdict)
#   1 — usage error or adapter failure

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="dispatch-surface.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- Argument parsing ----------
SURFACE=""
TARGET=""
EVIDENCE_DIR=""
CONFIG_ARG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --surface)      [ $# -ge 2 ] || die "flag --surface requires a value"; SURFACE="$2"; shift 2 ;;
    --target)       [ $# -ge 2 ] || die "flag --target requires a value"; TARGET="$2"; shift 2 ;;
    --evidence-dir) [ $# -ge 2 ] || die "flag --evidence-dir requires a path"; EVIDENCE_DIR="$2"; shift 2 ;;
    --config)       [ $# -ge 2 ] || die "flag --config requires a path"; CONFIG_ARG="$2"; shift 2 ;;
    *)              die "unknown argument: $1" ;;
  esac
done

[ -n "$SURFACE" ]      || die "usage: --surface is required"
[ -n "$TARGET" ]       || die "usage: --target is required"
[ -n "$EVIDENCE_DIR" ] || die "usage: --evidence-dir is required"

# Locate sibling scripts via this script's directory.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ADAPTER="$SCRIPT_DIR/surface-adapter.sh"
WRITE_EVIDENCE="$SCRIPT_DIR/write-evidence.sh"

[ -f "$ADAPTER" ]        || die "surface-adapter.sh not found at $ADAPTER"
[ -f "$WRITE_EVIDENCE" ] || die "write-evidence.sh not found at $WRITE_EVIDENCE"

# ---------- Build config argument ----------
config_flags=""
if [ -n "$CONFIG_ARG" ]; then
  config_flags="--config $CONFIG_ARG"
fi

# ---------- Call surface-adapter.sh ----------
set +e
# shellcheck disable=SC2086
adapter_output="$(bash "$ADAPTER" --surface "$SURFACE" $config_flags 2>&1)"
adapter_rc=$?
set -e

# ---------- Handle adapter result ----------
case "$adapter_rc" in
  2)
    # SKIPPED — dormant surface
    printf '{"surface":"%s","verdict":"SKIPPED","reason":"not configured"}\n' "$SURFACE"
    exit 0
    ;;
  0)
    # CONFIGURED — proceed with dispatch
    ;;
  *)
    # Error from adapter
    die "surface-adapter.sh failed (exit $adapter_rc): $adapter_output"
    ;;
esac

# ---------- Dispatch by surface type ----------
case "$SURFACE" in
  api)
    # Execute the target command, capture transcript and exit code.
    mkdir -p "$EVIDENCE_DIR"
    set +e
    transcript="$(bash -c "$TARGET" 2>&1)"
    cmd_exit=$?
    set -e

    if [ "$cmd_exit" -eq 0 ]; then
      verdict="PASSED"
    else
      verdict="FAILED"
    fi

    # Format run-record content.
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    run_record="$(cat <<EOF
# Manual Test Run Record

- **Target:** $TARGET
- **Surface:** api
- **Timestamp:** $timestamp
- **Verdict:** $verdict

## Command Output

\`\`\`
$transcript
\`\`\`

## Exit Code

$cmd_exit
EOF
)"

    # Pipe run-record through write-evidence.sh (CMD_EXIT_CODE lets it
    # record the actual command exit code in exit-code.log).
    export CMD_EXIT_CODE="$cmd_exit"
    printf '%s\n' "$run_record" | bash "$WRITE_EVIDENCE" "$EVIDENCE_DIR" "$verdict"

    printf '{"surface":"api","verdict":"%s","exit_code":%d}\n' "$verdict" "$cmd_exit"
    exit 0
    ;;

  browser)
    # Browser surface: run pixel-diff visual regression if baselines exist.
    # Source config reader and pixel-diff library.
    PIXEL_DIFF="$SCRIPT_DIR/pixel-diff.sh"
    READ_CONFIG="$SCRIPT_DIR/read-visual-diff-config.sh"

    if [ ! -f "$PIXEL_DIFF" ] || [ ! -f "$READ_CONFIG" ]; then
      printf '{"surface":"browser","verdict":"PENDING","reason":"dispatch ready"}\n'
      exit 0
    fi

    # Derive story slug from target
    story_slug="$(echo "$TARGET" | sed 's/[^a-zA-Z0-9_-]/-/g' | tr '[:upper:]' '[:lower:]')"

    # Source the pixel-diff library
    # shellcheck source=pixel-diff.sh
    source "$PIXEL_DIFF"

    # Read config for breakpoints and capture screenshots
    # shellcheck source=read-visual-diff-config.sh
    source "$READ_CONFIG"
    config="${CONFIG_ARG:-}"

    # Determine project root
    pr="${CLAUDE_PROJECT_ROOT:-${GAIA_PROJECT_ROOT:-${PROJECT_ROOT:-${PROJECT_PATH:-${PWD}}}}}"
    if [ -z "$config" ]; then
      config="${pr}/.gaia/config/project-config.yaml"
    fi

    # Run pixel-diff (captures are expected to already be in evidence dir)
    screenshot_dir="$EVIDENCE_DIR/screenshots"
    mkdir -p "$screenshot_dir"

    # Attempt to capture screenshots if a browser is available
    CAPTURE="$SCRIPT_DIR/capture-screenshot.sh"
    if [ -f "$CAPTURE" ]; then
      breakpoints_raw="$(read_breakpoints "$config")"
      while IFS= read -r bp; do
        [ -n "$bp" ] || continue
        bash "$CAPTURE" --url "$TARGET" --breakpoint "$bp" \
          --output "$screenshot_dir/screenshot-${bp}.png" 2>/dev/null || true
      done <<< "$breakpoints_raw"
    fi

    # Run the pixel diff
    set +e
    diff_output="$(run_pixel_diff "$story_slug" "$screenshot_dir" \
      --project-root "$pr" --config "$config" 2>&1)"
    set -e

    # Determine verdict from pixel-diff output
    pixel_verdict="UNVERIFIED"
    if echo "$diff_output" | tail -1 | grep -qi "^PASSED"; then
      pixel_verdict="PASSED"
    elif echo "$diff_output" | tail -1 | grep -qi "^FAILED"; then
      pixel_verdict="FAILED"
    fi

    # Write evidence
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    run_record="$(cat <<DIFFEOF
# Visual Regression Run Record

- **Target:** $TARGET
- **Surface:** browser
- **Timestamp:** $timestamp
- **Verdict:** $pixel_verdict

## Pixel-Diff Output

\`\`\`
$diff_output
\`\`\`
DIFFEOF
)"

    printf '%s\n' "$run_record" | bash "$WRITE_EVIDENCE" "$EVIDENCE_DIR" "$pixel_verdict"

    printf '{"surface":"browser","verdict":"%s","reason":"pixel-diff"}\n' "$pixel_verdict"
    exit 0
    ;;

  mobile|desktop)
    # Non-browser visual surfaces: agent dispatch is handled by SKILL.md.
    # Emit PENDING so the orchestrator knows the surface is ready for
    # agent-driven walkthrough.
    printf '{"surface":"%s","verdict":"PENDING","reason":"dispatch ready"}\n' "$SURFACE"
    exit 0
    ;;

  *)
    die "unexpected surface after adapter: $SURFACE"
    ;;
esac
