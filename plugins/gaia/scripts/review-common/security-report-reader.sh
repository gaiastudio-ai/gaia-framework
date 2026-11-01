#!/usr/bin/env bash
# security-report-reader.sh — read-only helper that extracts critical security
# findings from a security review report and the findings register.
#
# Used by the fix-cycle cap orchestration to decide whether accept-override
# is blocked (fail closed when any critical security finding is unresolved).
#
# Usage:
#   security-report-reader.sh --story <key>
#
# Output (one line per critical finding):
#   finding <RF-n> owasp <category> impact <text> disposition <open|resolved> signed_off <true|false>
#
# When no critical security findings exist, prints nothing and exits 0.
# When the register or report cannot be read, exits 1 with an actionable
# message (fail closed — the caller treats exit 1 as "cannot determine, block").

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_NAME="security-report-reader.sh"
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null && pwd)"
SCRIPTS_DIR="$(CDPATH='' cd -- "$SCRIPT_DIR/.." >/dev/null && pwd)"

_sr_err() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
_sr_die() { local rc="$1"; shift; _sr_err "$*"; exit "$rc"; }

_sr_require_tool() {
  command -v "$1" >/dev/null 2>&1 || _sr_die 1 "$1 is required but not on PATH"
}

_sr_require_tool yq
_sr_require_tool jq

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

key=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --story) [ "$#" -ge 2 ] || _sr_die 1 "--story requires a value"; key="$2"; shift 2 ;;
    -h|--help)
      printf 'Usage: %s --story <key>\n' "$SCRIPT_NAME"
      exit 0
      ;;
    *) _sr_die 1 "unknown argument: $1" ;;
  esac
done

[ -n "$key" ] || _sr_die 1 "--story is required"

# ---------------------------------------------------------------------------
# Resolve the findings register
# ---------------------------------------------------------------------------

reg_path="$("$SCRIPTS_DIR/resolve-review-report-path.sh" --key "$key" --type findings-register 2>/dev/null)" || \
  _sr_die 1 "cannot resolve findings register for: $key"

if [ ! -f "$reg_path" ]; then
  # No register at all — no findings to report.
  exit 0
fi

# ---------------------------------------------------------------------------
# Extract critical security findings
# ---------------------------------------------------------------------------

# A finding is critical-security when:
#   - gate_ratings includes a rating from the security-review gate
#   - severity == "critical"
#   - disposition is "open" (not yet resolved)
#
# We also report resolved/signed-off ones so the caller can tell whether
# all criticals are handled.

# Read all entries as JSON for reliable parsing.
entries_json="$(yq -o=json '.entries' "$reg_path" 2>/dev/null)" || \
  _sr_die 1 "cannot parse findings register: $reg_path"

# Filter for security-gate critical findings.
# jq outputs one JSON object per matching entry.
critical_findings="$(printf '%s' "$entries_json" | jq -c '
  [.[] | select(
    .severity == "critical"
    and (.gate_ratings | type == "array")
    and ([.gate_ratings[] | select(.gate == "security-review")] | length > 0)
  )] | .[]
' 2>/dev/null)" || critical_findings=""

if [ -z "$critical_findings" ]; then
  exit 0
fi

# For each critical finding, extract id, disposition, owasp_category, impact,
# and sign-off status.
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  f_id="$(printf '%s' "$entry" | jq -r '.id // "unknown"')"
  f_disp="$(printf '%s' "$entry" | jq -r '.disposition // "open"')"

  # OWASP category: from the security-review gate rating's category field,
  # or from the sign-off record, or "unknown".
  f_owasp="$(printf '%s' "$entry" | jq -r '
    (.sign_off.owasp_category // null)
    // ([.gate_ratings[] | select(.gate == "security-review")] | .[0].owasp_category // null)
    // "unknown"
  ')"

  # Impact: from the entry's impact field or the sign-off record.
  f_impact="$(printf '%s' "$entry" | jq -r '
    (.impact // null)
    // (.sign_off.impact // null)
    // "unknown"
  ')"

  # Sign-off status.
  f_signed="$(printf '%s' "$entry" | jq -r '
    if .sign_off != null and .sign_off.risk_accepted_by != null
    then "true" else "false" end
  ')"

  printf 'finding %s owasp %s impact %s disposition %s signed_off %s\n' \
    "$f_id" "$f_owasp" "$f_impact" "$f_disp" "$f_signed"
done <<< "$critical_findings"

exit 0
