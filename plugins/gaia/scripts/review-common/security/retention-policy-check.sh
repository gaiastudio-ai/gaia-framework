#!/usr/bin/env bash
# retention-policy-check.sh — GAIA review-common Phase 3C retention check.
#
# Purpose
# -------
# Deterministic check that flags retention-policy gaps for PII-bearing fields
# and session/token stores.
#
# Detected rules:
#   - pii-field-no-ttl              : ORM/schema field whose name matches a
#                                     PII pattern (email, phone, ssn, ...)
#                                     and which has NO @ttl/@expiry/expires_at
#                                     annotation in the same file.
#   - session-no-ttl                : session/cookie/token store config with
#                                     no max-age / ttl / expires_in / expiry.
#   - retention-exceeds-threshold   : any explicit `retention*: <N>` (days) in
#                                     YAML/JSON/.env exceeding --max-retention-days
#                                     (default 365).
#
# All findings carry severity Medium and category `privacy-retention`.
#
# Exit 0 on successful scan (incl. with non-empty findings). Caller error -> 1.
#
# POSIX discipline: bash + set -euo pipefail + LC_ALL=C; macOS bash 3.2 + BSD
# awk compatible; no jq dependency.
#

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="retention-policy-check.sh"

die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
$SCRIPT_NAME — Phase 3C retention-policy check.

Usage:
  $SCRIPT_NAME [--max-retention-days N] <path>...
  $SCRIPT_NAME --file-list <listfile>
  $SCRIPT_NAME --help

Detects: pii-field-no-ttl, session-no-ttl, retention-exceeds-threshold.
All findings Medium severity, category privacy-retention.

Default --max-retention-days is 365.

Emits a single analysis-results.json checks[] fragment to stdout.
Exit 0 on successful scan (incl. with non-empty findings).
EOF
}

# ---------- arg parsing ----------

PATHS=()
FILE_LIST=""
MAX_DAYS=365
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --max-retention-days)
      [ $# -ge 2 ] || die "--max-retention-days requires a value"
      MAX_DAYS="$2"; shift 2 ;;
    --file-list)
      [ $# -ge 2 ] || die "--file-list requires a path"
      FILE_LIST="$2"; shift 2 ;;
    --) shift; while [ $# -gt 0 ]; do PATHS+=("$1"); shift; done ;;
    -*) die "unknown flag: $1" ;;
    *) PATHS+=("$1"); shift ;;
  esac
done

case "$MAX_DAYS" in
  ''|*[!0-9]*) die "--max-retention-days must be a positive integer (got: $MAX_DAYS)" ;;
esac

# ---------- discover input files ----------

discover_config_files() {
  local p
  for p in "$@"; do
    if [ -f "$p" ]; then
      printf '%s\n' "$p"
    elif [ -d "$p" ]; then
      find "$p" -type f \( \
        -name '*.prisma' \
        -o -name '*.py' \
        -o -name '*.ts' -o -name '*.js' \
        -o -name '*.go' -o -name '*.java' -o -name '*.kt' \
        -o -name '*.yaml' -o -name '*.yml' \
        -o -name '*.json' \
        -o -name '*.toml' \
        -o -name '*.env' -o -name '.env.*' \
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
  INPUT_FILES="${INPUT_FILES}$(discover_config_files "${PATHS[@]}")"$'\n'
fi

SEEN_TMP="$(mktemp -t gaia-rpc-seen.XXXXXX)"
DEDUPED_FILE="$(mktemp -t gaia-rpc-deduped.XXXXXX)"
FINDINGS_FILE="$(mktemp -t gaia-rpc-findings.XXXXXX)"
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

# ---------- helpers ----------

PII_FIELD_REGEX='(email|phone|ssn|password|secret|token|apiKey|api_key|userEmail|user_email|creditCard|credit_card)'
TTL_HINT_REGEX='(@ttl|@expiry|@expires|expires_at|expiresAt|ttl[[:space:]]*[=:]|max_age|maxAge|expires_in)'

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
  printf '{"file":"%s","line":%s,"severity":"medium","rule":"%s","message":"%s","blocking":false,"category":"privacy-retention"}' \
    "$file_esc" "$line" "$rule" "$msg_esc" >> "$FINDINGS_FILE"
  FINDING_COUNT=$((FINDING_COUNT + 1))
}

# ---------- scanners ----------

scan_pii_field_no_ttl() {
  local file="$1"
  # Determine whether the file has any TTL-hint anywhere — if not, every PII
  # field declaration without an annotation on its own line is flagged.
  local has_ttl=0
  if grep -Eq "$TTL_HINT_REGEX" "$file" 2>/dev/null; then
    has_ttl=1
  fi
  awk -v file="$file" -v has_ttl="$has_ttl" -v fre="$PII_FIELD_REGEX" -v tre="$TTL_HINT_REGEX" '
    BEGIN { IGNORECASE = 1 }
    {
      ln = NR
      raw = $0
      # Skip lines that themselves contain a TTL hint (per-line annotation).
      if (raw ~ tre) next

      # Schema-shaped declarations:
      #   - Prisma:        "<name>  <Type>  <attrs?>"
      #   - SQLAlchemy/ORM:"<name> = Column(<Type>...)"
      #   - Django models: "<name> = models.<Type>(...)"
      #   - JS/TS schema:  "<name>: <Type>" / "<name> String"
      # Single-line `model U { email String }` schemas: scan the contents
      # inside the braces directly (BSD awk: no /m regex modifier, so we
      # extract the inner block via a simple substring split).
      if (raw ~ /^[[:space:]]*(model|class)[[:space:]].*\{.*\}/) {
        s2 = raw
        sub(/^[^{]*\{[[:space:]]*/, "", s2)
        sub(/[[:space:]]*\}.*$/, "", s2)
        # Split inner block on `;` or `,` separators (semicolons in some Prisma
        # variants; commas in TS-shaped schemas) — falls back to whole-block
        # scan when no separator is present.
        gsub(/[;,]/, "\n", s2)
        nlines = split(s2, parts, "\n")
        for (k = 1; k <= nlines; k++) {
          piece = parts[k]
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", piece)
          if (piece == "") continue
          if (piece ~ tre) continue
          if (piece ~ /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]+[A-Z][A-Za-z0-9_]*/) {
            # Extract leading identifier.
            ident = ""
            for (i = 1; i <= length(piece); i++) {
              c = substr(piece, i, 1)
              if (c ~ /[A-Za-z0-9_]/) ident = ident c; else break
            }
            if (ident != "" && tolower(ident) ~ "^" tolower(fre) "$") {
              printf "%s\t%d\tpii-field-no-ttl\tPII-named field \"%s\" has no TTL/expiry annotation\n", file, ln, ident
            }
          }
        }
        next
      }
      if (raw ~ /^[[:space:]]*(model|class)[[:space:]]/) next
      if (raw ~ /^[[:space:]]*(\/\/|#)/) next  # comment lines

      # Look for an identifier followed by a type-shape on the same line.
      # Patterns covered (add cautiously — false positives lower trust):
      #   - Prisma           : `email String`           → /<id> +<Type>/
      #   - SQLAlchemy ORM   : `email = Column(...)`    → /<id> = Column/
      #   - Django models    : `email = CharField(...)` → /<id> = <Type>(/
      #   - Django/SQLAlchemy: `email = models.X(...)`  → /<id> = models.<Type>/
      #   - TypeScript schema: `email: string`          → /<id>: <Type>/
      if (raw ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]+[A-Z][A-Za-z0-9_]*/ ||
          raw ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*(Column|models\.[A-Z])/ ||
          raw ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*[A-Z][A-Za-z0-9_]*Field[[:space:]]*\(/ ||
          raw ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:[[:space:]]*[A-Z][A-Za-z0-9_]*/) {
        # Extract the leading identifier.
        s = raw
        sub(/^[[:space:]]+/, "", s)
        ident = ""
        for (i = 1; i <= length(s); i++) {
          c = substr(s, i, 1)
          if (c ~ /[A-Za-z0-9_]/) ident = ident c; else break
        }
        if (ident != "" && tolower(ident) ~ "^" tolower(fre) "$") {
          printf "%s\t%d\tpii-field-no-ttl\tPII-named field \"%s\" has no TTL/expiry annotation\n", file, ln, ident
        }
      }
    }
  ' "$file" 2>/dev/null || true
}

scan_session_no_ttl() {
  local file="$1"
  # Heuristic: file mentions a session/cookie/token store keyword and
  # does NOT mention any TTL/maxAge/expires_in token.
  local mentions_session=0 mentions_ttl=0
  if grep -Eiq '(session|cookie|jwt[[:space:]]*token|access[[:space:]]*token|refresh[[:space:]]*token|redis[[:space:]]*store|memcached)' "$file" 2>/dev/null; then
    mentions_session=1
  fi
  if grep -Eq "$TTL_HINT_REGEX" "$file" 2>/dev/null; then
    mentions_ttl=1
  fi
  if [ "$mentions_session" = "1" ] && [ "$mentions_ttl" = "0" ]; then
    # Locate the first session-mentioning line for the line-number hint.
    local ln
    ln="$(grep -niE 'session|cookie|jwt|token|redis|memcached' "$file" 2>/dev/null | head -1 | cut -d: -f1)"
    [ -z "$ln" ] && ln=1
    printf "%s\t%d\tsession-no-ttl\tsession/token store config has no TTL/maxAge/expires_in annotation\n" \
      "$file" "$ln"
  fi
}

scan_retention_exceeds_threshold() {
  local file="$1" max_days="$2"
  # Two-pass strategy:
  #   (1) flag lines where a `retention*` key is on the same line as a number
  #       greater than threshold;
  #   (2) when the file mentions `retention` (anywhere), also flag indented
  #       `*days*: <N>` / `*days* = <N>` / `*_days*: <N>` lines whose number
  #       exceeds the threshold (YAML retention blocks have the number on a
  #       sub-key line indented under the `retention:` parent).
  local mentions_retention=0
  if grep -Eiq 'retention' "$file" 2>/dev/null; then
    mentions_retention=1
  fi
  awk -v file="$file" -v max="$max_days" -v ret="$mentions_retention" '
    BEGIN { IGNORECASE = 1 }
    {
      ln = NR
      raw = $0
      s = raw

      # Pass 1: same-line "retention*" + number.
      if (s ~ /retention/) {
        if (match(s, /retention[A-Za-z_]*[[:space:]]*[:=][[:space:]]*[0-9]+/)) {
          tok = substr(s, RSTART, RLENGTH)
          n = tok; sub(/^[^0-9]+/, "", n); sub(/[^0-9].*$/, "", n)
          if (n != "" && n + 0 > max + 0) {
            printf "%s\t%d\tretention-exceeds-threshold\tretention duration %s exceeds threshold %s days\n", file, ln, n, max
            next
          }
        }
      }

      # Pass 2: file mentions retention -> any "<key>: <N>" or "<key>_days = <N>"
      # whose key contains "day" is treated as a retention duration.
      if (ret == 1) {
        if (match(s, /[A-Za-z_]*day[A-Za-z_]*[[:space:]]*[:=][[:space:]]*[0-9]+/)) {
          tok = substr(s, RSTART, RLENGTH)
          n = tok; sub(/^[^0-9]+/, "", n); sub(/[^0-9].*$/, "", n)
          if (n != "" && n + 0 > max + 0) {
            printf "%s\t%d\tretention-exceeds-threshold\tretention duration %s (days) exceeds threshold %s days\n", file, ln, n, max
          }
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
  done < <( scan_pii_field_no_ttl "$f"; scan_session_no_ttl "$f"; scan_retention_exceeds_threshold "$f" "$MAX_DAYS" )
done < "$DEDUPED_FILE"

# ---------- emit ----------

if [ "$FINDING_COUNT" -gt 0 ]; then
  STATUS="failed"
else
  STATUS="passed"
fi

printf '{"name":"retention-policy-check","scope":"file","status":"%s","findings":[' "$STATUS"
cat "$FINDINGS_FILE"
printf ']}\n'

exit 0
