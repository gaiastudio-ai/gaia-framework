#!/usr/bin/env bash
# plugin-shellcheck-advisory.sh — Tier 1 shellcheck advisory helper.
#
# Purpose
# -------
# Emits the canonical advisory string "Shell scripts detected — shellcheck
# validation deferred to Tier 2" when:
#   1. The plugin tree contains one or more .sh files, AND
#   2. The shellcheck adapter is absent from project-config.yaml tool_adapters
#      (tri-state probe classifies it as `omitted` or `null`).
#
# Delegates silently (no advisory output, exit 0) when the shellcheck adapter
# is `declared` — Tier 2 install in place.
#
# Adapter availability is determined ONLY via
# scripts/tool-availability-probe.sh in tri-state mode (--tool shellcheck).
# Hardcoded path checks (e.g., test -x /usr/local/bin/shellcheck) are
# explicitly forbidden — they bypass the probe contract and break the
# omitted/null/declared classification.
#
# Usage
# -----
#   plugin-shellcheck-advisory.sh --plugin-dir <path> --config <path>
#   plugin-shellcheck-advisory.sh --help
#
# Exit codes
# ----------
#   0 — Always (advisory is non-failing; the rubric must not block on it).
#   1 — Caller error (missing required flag, missing config).
#
# Output (stdout)
# ---------------
#   Either nothing (no .sh files, OR adapter declared, OR plugin-dir absent),
#   or exactly the canonical advisory string on a single line.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="plugin-shellcheck-advisory.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$SCRIPT_DIR/tool-availability-probe.sh"
ADVISORY_TEXT='Shell scripts detected — shellcheck validation deferred to Tier 2'

die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
$SCRIPT_NAME — Tier 1 shellcheck advisory helper.

Emits a single advisory line when shell scripts are present and the shellcheck
adapter is not declared. Delegates silently when the adapter is declared.

Usage:
  $SCRIPT_NAME --plugin-dir <path> --config <project-config.yaml>
  $SCRIPT_NAME --help

Required:
  --plugin-dir <path>   Root of the plugin tree to scan for .sh files.
  --config <path>       Path to project-config.yaml (passed verbatim to
                        tool-availability-probe.sh --tool shellcheck).

Exit codes:
  0   Always (advisory never fails the rubric).
  1   Caller error.
EOF
}

PLUGIN_DIR=""
CONFIG=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --plugin-dir)
      [ "$#" -ge 2 ] || die "--plugin-dir requires a path"
      PLUGIN_DIR="$2"; shift 2 ;;
    --config)
      [ "$#" -ge 2 ] || die "--config requires a path"
      CONFIG="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "unknown argument: $1" ;;
  esac
done

[ -n "$PLUGIN_DIR" ] || die "missing required --plugin-dir <path>"
[ -n "$CONFIG" ]     || die "missing required --config <path>"
[ -d "$PLUGIN_DIR" ] || die "plugin-dir not found: $PLUGIN_DIR"
[ -f "$CONFIG" ]     || die "config not found: $CONFIG"
[ -x "$PROBE" ]      || die "tool-availability-probe.sh missing or not executable: $PROBE"

# ---------------------------------------------------------------------------
# Stage 1: detect .sh files. No .sh files -> no advisory, exit 0 (edge case).
# ---------------------------------------------------------------------------

shell_count=$(find "$PLUGIN_DIR" -type f -name '*.sh' 2>/dev/null | head -n 1 | wc -l | tr -d ' ')
if [ "$shell_count" = "0" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Stage 2: query the tri-state probe for the shellcheck adapter.
# omitted state -> probe exits 0 with no stdout. null/declared -> JSON on stdout.
# ---------------------------------------------------------------------------

probe_out="$("$PROBE" --tool shellcheck --config "$CONFIG" 2>/dev/null || true)"

if [ -z "$probe_out" ]; then
  # State == omitted (no tool_adapters.shellcheck entry). Emit advisory.
  printf '%s\n' "$ADVISORY_TEXT"
  exit 0
fi

# State == null OR declared. Parse probe_state from JSON.
probe_state="$(printf '%s' "$probe_out" | jq -r '.probe_state // ""' 2>/dev/null || echo "")"

case "$probe_state" in
  declared)
    # Tier 2 install — defer to the shellcheck adapter. No advisory.
    exit 0
    ;;
  null|"")
    # Tier 1 install with explicit null entry — still emit the advisory so the
    # user sees the upgrade path.
    printf '%s\n' "$ADVISORY_TEXT"
    exit 0
    ;;
  *)
    # Unknown state — be safe and emit the advisory rather than silently skip.
    printf '%s\n' "$ADVISORY_TEXT"
    exit 0
    ;;
esac
