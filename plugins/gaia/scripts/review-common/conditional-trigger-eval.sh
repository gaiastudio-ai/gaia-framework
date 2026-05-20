#!/usr/bin/env bash
# conditional-trigger-eval.sh — GAIA review-common conditional-skip evaluator (E69-S4).
#
# Purpose
# -------
# Deterministic helper invoked by `/gaia-review-all` (Step 4 / ADR-082) to
# decide whether the conditional review gates (a11y, mobile) should be
# included in the composite verdict or skipped. Reads project-config via
# `resolve-config.sh --field` (single source of truth) and emits a structured
# result that the orchestrator translates into the canonical
# `composite-verdict-aggregator.sh` argv fragment.
#
# Trigger conditions (ADR-082, FR-RSV2-44):
#   - a11y    : included when compliance.ui_present is true (or unset).
#               skipped when compliance.ui_present is false.
#   - mobile  : included when platforms[] contains 'ios', 'android', or
#               'mobile'. skipped when platforms[] is empty or excludes mobile.
#
# Inputs
# ------
#   --shared <path>    explicit project-config.yaml path (forwarded to
#                       resolve-config.sh as --shared).
#   --help             usage and exit 0.
#
# Output (stdout, multi-line key=value)
# -------------------------------------
#   a11y=<included|skipped>
#   a11y_reason=<verbatim reason when skipped, else empty>
#   mobile=<included|skipped>
#   mobile_reason=<verbatim reason when skipped, else empty>
#   --skip-a11y "<reason>"     (only when a11y is skipped — drop-in argv fragment)
#   --skip-mobile "<reason>"   (only when mobile is skipped — drop-in argv fragment)
#
# The two trailing argv-fragment lines are emitted ONLY when the corresponding
# gate is skipped — the orchestrator forwards them verbatim into the
# `composite-verdict-aggregator.sh` invocation. Included gates expect the
# orchestrator to supply the verdict via `--a11y <verdict>` / `--mobile <verdict>`.
#
# Determinism
# -----------
# Pure shell. No timestamps. No randomness. YOLO_MODE has no effect on output
# (ADR-067 invariance). Byte-identical output for byte-identical project-config.
#
# Refs: E69-S4, FR-RSV2-44, ADR-082, ADR-067.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="conditional-trigger-eval.sh"

die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
$SCRIPT_NAME — conditional-trigger-eval (E69-S4, ADR-082)

Usage:
  $SCRIPT_NAME [--shared <project-config.yaml>]
  $SCRIPT_NAME --help

Reads compliance.ui_present and platforms[] from project-config.yaml via
resolve-config.sh --field. Emits a deterministic key=value report and (when
applicable) drop-in --skip-<gate> argv fragments for
composite-verdict-aggregator.sh.
EOF
}

SHARED=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --shared) [ "$#" -ge 2 ] || die "--shared requires a path"; SHARED="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# We deliberately parse the two narrow keys we need
# (compliance.ui_present + platforms[]) directly with awk rather than
# round-tripping through resolve-config.sh — resolve-config.sh validates 11+
# required project-shell fields (checkpoint_path, project_root, ...) that are
# orthogonal to this evaluator and would force callers to ship a full project
# fixture. Parsing the two narrow keys keeps the evaluator self-contained and
# matches the single-responsibility shape of other review-common helpers.
if [ -z "$SHARED" ]; then
  # E96-S7 partial-4c: prefer .gaia/config/project-config.yaml over the legacy
  # config/project-config.yaml at both CLAUDE_PROJECT_ROOT and CWD candidates.
  for candidate in \
    "${CLAUDE_PROJECT_ROOT:-}/.gaia/config/project-config.yaml" \
    "${CLAUDE_PROJECT_ROOT:-}/config/project-config.yaml" \
    "$PWD/.gaia/config/project-config.yaml" \
    "$PWD/config/project-config.yaml"; do
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then
      SHARED="$candidate"
      break
    fi
  done
fi

ui_present=""
platforms=""
if [ -n "$SHARED" ] && [ -f "$SHARED" ]; then
  # compliance.ui_present — nested key under the top-level `compliance:` block.
  ui_present="$(awk '
    /^compliance:[[:space:]]*$/ { in_compliance = 1; next }
    /^[A-Za-z_]/                 { in_compliance = 0 }
    in_compliance && /^[[:space:]]+ui_present:/ {
      sub(/^[[:space:]]+ui_present:[[:space:]]*/, "")
      sub(/[[:space:]]*#.*$/, "")
      sub(/[[:space:]]+$/, "")
      print
      exit
    }
  ' "$SHARED")"

  # platforms — top-level inline list `platforms: [web, ios, ...]` (matches the
  # canonical shape resolve-config.sh consumes via merge_inline_list).
  platforms="$(awk '
    /^platforms:[[:space:]]*\[/ {
      sub(/^platforms:[[:space:]]*\[/, "")
      sub(/\].*$/, "")
      print
      exit
    }
  ' "$SHARED")"
fi

# a11y verdict: skipped iff compliance.ui_present is exactly 'false'. Treat
# unset / empty / true as included (failsafe — we'd rather over-include than
# silently skip a11y for an unflagged config).
a11y_status="included"
a11y_reason=""
if [ "$ui_present" = "false" ]; then
  a11y_status="skipped"
  a11y_reason="compliance.ui_present: false"
fi

# mobile verdict: included iff platforms list contains a mobile token.
# resolve-config.sh emits the inline list as a comma-separated string with
# square brackets retained when the source uses inline-list syntax — strip
# brackets/whitespace before tokenizing.
mobile_status="skipped"
mobile_reason="platforms[] excludes mobile"
clean_platforms="$(printf '%s' "$platforms" | tr -d '[]" ' | tr ',' '\n')"
while IFS= read -r tok; do
  case "$tok" in
    ios|android|mobile)
      mobile_status="included"
      mobile_reason=""
      break
      ;;
  esac
done <<EOF
$clean_platforms
EOF

printf 'a11y=%s\n' "$a11y_status"
printf 'a11y_reason=%s\n' "$a11y_reason"
printf 'mobile=%s\n' "$mobile_status"
printf 'mobile_reason=%s\n' "$mobile_reason"

if [ "$a11y_status" = "skipped" ]; then
  printf -- '--skip-a11y "%s"\n' "$a11y_reason"
fi
if [ "$mobile_status" = "skipped" ]; then
  printf -- '--skip-mobile "%s"\n' "$mobile_reason"
fi

exit 0
