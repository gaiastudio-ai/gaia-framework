#!/usr/bin/env bash
# data-handling-lint.sh — GAIA review-common Phase 3C data-handling lint (E67-S5, ADR-077).
#
# Purpose
# -------
# Deterministic lint that flags PII-shaped variables flowing into logging,
# URL construction, error-message strings, and analytics/telemetry calls.
#
# Detected rules:
#   - logging-pii          : console.log / logger.* / print / logging.* with a
#                            PII-named variable in the argument list
#   - pii-in-url           : URL/query-string interpolation with a PII-named
#                            variable (template-string or string concat)
#   - unmasked-pii-error   : Error/Exception message interpolating a PII-named
#                            variable (e.g., `Invalid email: ${email}`)
#   - pii-in-analytics     : analytics.track / segment.track / mixpanel.track
#                            / amplitude.logEvent with a PII-named argument
#
# All findings carry severity High (FR-RSV2-22, AC8) and category
# `privacy-data-handling`.
#
# Output (stdout): a single check fragment with status passed|failed.
# Exit 0 on successful scan (incl. with non-empty findings).
#
# POSIX discipline: bash + set -euo pipefail + LC_ALL=C; macOS bash 3.2 + BSD
# awk compatible; no jq dependency.
#
# Refs: AC2, AC6, AC7, AC8, FR-RSV2-1, FR-RSV2-2, NFR-RSV2-1, ADR-075, ADR-077.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="data-handling-lint.sh"

die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
$SCRIPT_NAME — Phase 3C data-handling lint (ADR-077).

Usage:
  $SCRIPT_NAME <path>...
  $SCRIPT_NAME --file-list <listfile>
  $SCRIPT_NAME --help

Detects: logging-pii, pii-in-url, unmasked-pii-error, pii-in-analytics.
All findings High severity, category privacy-data-handling.

Emits a single analysis-results.json checks[] fragment to stdout.
Exit 0 on successful scan (incl. with non-empty findings).
EOF
}

# ---------- arg parsing ----------

PATHS=()
FILE_LIST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --file-list)
      [ $# -ge 2 ] || die "--file-list requires a path"
      FILE_LIST="$2"; shift 2 ;;
    --) shift; while [ $# -gt 0 ]; do PATHS+=("$1"); shift; done ;;
    -*) die "unknown flag: $1" ;;
    *) PATHS+=("$1"); shift ;;
  esac
done

# ---------- discover input files ----------

discover_source_files() {
  local p
  for p in "$@"; do
    if [ -f "$p" ]; then
      printf '%s\n' "$p"
    elif [ -d "$p" ]; then
      find "$p" -type f \( \
        -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \
        -o -name '*.py' -o -name '*.go' -o -name '*.java' -o -name '*.kt' \
        -o -name '*.rb' -o -name '*.rs' -o -name '*.php' -o -name '*.cs' \
      \) 2>/dev/null
    fi
  done
}

INPUT_FILES=""
if [ -n "$FILE_LIST" ]; then
  [ -f "$FILE_LIST" ] || die "file list not found: $FILE_LIST"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    INPUT_FILES="${INPUT_FILES}${line}"$'\n'
  done < "$FILE_LIST"
fi
if [ "${#PATHS[@]}" -gt 0 ]; then
  INPUT_FILES="${INPUT_FILES}$(discover_source_files "${PATHS[@]}")"$'\n'
fi

SEEN_TMP="$(mktemp -t gaia-dhl-seen.XXXXXX)"
DEDUPED_FILE="$(mktemp -t gaia-dhl-deduped.XXXXXX)"
FINDINGS_FILE="$(mktemp -t gaia-dhl-findings.XXXXXX)"
trap 'rm -f "$SEEN_TMP" "$DEDUPED_FILE" "$FINDINGS_FILE"' EXIT

while IFS= read -r f || [ -n "$f" ]; do
  [ -z "$f" ] && continue
  [ ! -f "$f" ] && continue
  if ! grep -Fxq "$f" "$SEEN_TMP" 2>/dev/null; then
    printf '%s\n' "$f" >> "$SEEN_TMP"
    printf '%s\n' "$f" >> "$DEDUPED_FILE"
  fi
done <<EOF
${INPUT_FILES}
EOF

# ---------- PII variable name list ----------
# Order matters — longer names first to avoid substring matches eating shorter
# ones (BSD awk has no lookarounds). Pattern is conservative — matches identifier
# tokens or property accesses ending in a PII-name token.

PII_VAR_REGEX='(creditCard|credit_card|apiKey|api_key|email|ssn|phone|password|secret|token|userEmail|user_email)'

# ---------- finding emitter ----------

json_escape() {
  awk 'BEGIN{ORS=""} {
    gsub(/\\/, "\\\\");
    gsub(/"/,  "\\\"");
    gsub(/\t/, "\\t");
    gsub(/\r/, "\\r");
    if (NR>1) printf "\\n";
    printf "%s", $0;
  }'
}

FINDING_COUNT=0
emit_finding() {
  local file="$1" line="$2" rule="$3" msg="$4"
  local file_esc msg_esc
  file_esc="$(printf '%s' "$file" | json_escape)"
  msg_esc="$(printf '%s' "$msg"  | json_escape)"
  if [ "$FINDING_COUNT" -gt 0 ]; then
    printf ',' >> "$FINDINGS_FILE"
  fi
  printf '{"file":"%s","line":%s,"severity":"high","rule":"%s","message":"%s","blocking":false,"category":"privacy-data-handling"}' \
    "$file_esc" "$line" "$rule" "$msg_esc" >> "$FINDINGS_FILE"
  FINDING_COUNT=$((FINDING_COUNT + 1))
}

# ---------- per-file scan ----------

scan_file() {
  local file="$1"
  awk -v file="$file" -v vre="$PII_VAR_REGEX" '
    BEGIN { IGNORECASE = 0 }
    {
      raw = $0

      # logging: console.log / logger.<level> / print( / logging.<level>
      if (raw ~ /(console\.(log|info|warn|error|debug)|logger\.(log|info|warn|error|debug|trace)|^[[:space:]]*print[[:space:]]*\(|logging\.(info|warn|error|debug))/) {
        if (match(raw, vre)) {
          token = substr(raw, RSTART, RLENGTH)
          printf "%s\t%d\tlogging-pii\tlogging call interpolates PII-named variable %s\n", file, NR, token
        }
      }

      # PII in URL: any literal URL-ish substring with `?...=${name}` or
      # query-string assembly with PII-named variable.
      if (raw ~ /(\?|&)[A-Za-z_][A-Za-z0-9_-]*=\$\{[A-Za-z_][A-Za-z0-9_]*\}/ ||
          raw ~ /(\?|&)[A-Za-z_][A-Za-z0-9_-]*=["\x27][[:space:]]*\+/) {
        if (match(raw, vre)) {
          token = substr(raw, RSTART, RLENGTH)
          printf "%s\t%d\tpii-in-url\tquery-string interpolates PII-named variable %s\n", file, NR, token
        }
      }

      # Unmasked PII in error/exception messages.
      if (raw ~ /(throw[[:space:]]+new[[:space:]]+(Error|TypeError|RangeError|Exception)|raise[[:space:]]+[A-Z][A-Za-z]*Error|raise[[:space:]]+Exception)/) {
        if (match(raw, vre)) {
          token = substr(raw, RSTART, RLENGTH)
          printf "%s\t%d\tunmasked-pii-error\terror message interpolates PII-named variable %s\n", file, NR, token
        }
      }

      # Analytics / telemetry SDKs.
      if (raw ~ /(analytics\.track|analytics\.identify|segment\.track|mixpanel\.track|amplitude\.logEvent|posthog\.capture|datadog\.event|sentry\.captureMessage)/) {
        if (match(raw, vre)) {
          token = substr(raw, RSTART, RLENGTH)
          printf "%s\t%d\tpii-in-analytics\tanalytics call references PII-named variable %s\n", file, NR, token
        }
      }
    }
  ' "$file" 2>/dev/null || true
}

# ---------- main scan ----------

while IFS= read -r f || [ -n "$f" ]; do
  [ -z "$f" ] && continue
  [ ! -f "$f" ] && continue
  while IFS=$'\t' read -r ff fl rr mm; do
    [ -z "$ff" ] && continue
    emit_finding "$ff" "$fl" "$rr" "$mm"
  done < <(scan_file "$f")
done < "$DEDUPED_FILE"

# ---------- emit ----------

if [ "$FINDING_COUNT" -gt 0 ]; then
  STATUS="failed"
else
  STATUS="passed"
fi

printf '{"name":"data-handling-lint","scope":"file","status":"%s","findings":[' "$STATUS"
cat "$FINDINGS_FILE"
printf ']}\n'

exit 0
