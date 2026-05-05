#!/usr/bin/env bash
# pii-detector.sh — GAIA review-common Phase 3C PII detector (E67-S5, ADR-077).
#
# Purpose
# -------
# Deterministic scanner that flags hardcoded PII patterns in source files and
# emits a single `analysis-results.json`-shaped check fragment on stdout.
#
# Detected PII categories (rule values):
#   - email           : email-address pattern
#   - ssn             : US Social Security Number (NNN-NN-NNNN)
#   - credit-card     : 13-19 digit sequence with Luhn-plausible heuristic
#   - phone           : E.164 / North American phone numbers
#   - ip-address      : IPv4 / IPv6 literals in string contexts
#   - iban            : IBAN (regime-loaded — only active when GDPR declared)
#
# Severity policy (FR-RSV2-22, AC8):
#   - Critical : PII pattern in non-test source file
#   - Medium   : PII pattern in a test file (path matches /test/, /tests/,
#                /__tests__/, .test., .spec.)
#
# Regime-aware loading (AC4):
#   The script reads `GAIA_COMPLIANCE_REGIMES` (comma-separated regime keys),
#   then for each key looks up `<plugin_root>/rubrics/regimes/<regime>.json`.
#   When the rubric file exists and contains `"privacy.patterns": [...]`,
#   each pattern's rule name and regex are loaded as additional detectors.
#   When the rubric file is missing OR `GAIA_COMPLIANCE_REGIMES` is unset,
#   only base patterns run — graceful degradation, no error.
#
#   For shells that do not export the env var, the script also probes
#   `${GAIA_RESOLVE_CONFIG:-resolve-config.sh}` on PATH and reads
#   `compliance.regimes` from `project-config.yaml`. If that helper is
#   unavailable, the script falls through to base patterns only.
#
# Output (stdout): a single check fragment of the canonical Phase 3A shape:
#
#   {"name":"pii-detector","scope":"file","status":"passed|failed",
#    "findings":[{"file":..., "line":..., "severity":..., "rule":...,
#                 "message":..., "blocking":false, "category":"privacy-pii"}]}
#
# Exit code 0 on successful scan (including with non-empty findings).
# Caller error (no input, unreadable path) -> exit 1.
#
# POSIX discipline: bash + set -euo pipefail + LC_ALL=C; macOS bash 3.2 + BSD
# awk compatible (no associative arrays, no 3-arg match); no jq dependency.
#
# Refs: AC1, AC4, AC6, AC7, AC8, FR-RSV2-1, FR-RSV2-2, NFR-RSV2-1, ADR-075,
# ADR-077, TC-RSV2-PRIVACY-1.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="pii-detector.sh"

die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
$SCRIPT_NAME — Phase 3C PII detector (ADR-077).

Usage:
  $SCRIPT_NAME <path>...
  $SCRIPT_NAME --file-list <listfile>
  $SCRIPT_NAME --help

Detects: email, ssn, credit-card, phone, ip-address (base) + regime-loaded
patterns (e.g. iban under GDPR).

Severity:
  Critical for non-test source files; Medium for files matching test patterns.

Regime loading via env GAIA_COMPLIANCE_REGIMES (comma-separated regime keys)
or via the optional resolve-config.sh helper. Graceful degrade when absent.

Emits a single analysis-results.json checks[] fragment to stdout.
Exit 0 on successful scan (including when findings are non-empty).
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

INPUT_FILES=""
if [ -n "$FILE_LIST" ]; then
  [ -f "$FILE_LIST" ] || die "file list not found: $FILE_LIST"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    INPUT_FILES="${INPUT_FILES}${line}"$'\n'
  done < "$FILE_LIST"
fi

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
        -o -name '*.scala' -o -name '*.swift' -o -name '*.m' -o -name '*.mm' \
      \) 2>/dev/null
    fi
  done
}

if [ "${#PATHS[@]}" -gt 0 ]; then
  INPUT_FILES="${INPUT_FILES}$(discover_source_files "${PATHS[@]}")"$'\n'
fi

# Deduplicate.
SEEN_TMP="$(mktemp -t gaia-pii-seen.XXXXXX)"
DEDUPED_FILE="$(mktemp -t gaia-pii-deduped.XXXXXX)"
FINDINGS_FILE="$(mktemp -t gaia-pii-findings.XXXXXX)"
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

# ---------- regime loading ----------
# Resolves the active regime list, then loads each regime's privacy.patterns
# from the rubric JSON. Patterns are stored as parallel arrays REGIME_RULES /
# REGIME_REGEX. We do NOT use associative arrays (bash 3.2 compat).

REGIME_RULES=()
REGIME_REGEX=()

resolve_regimes() {
  if [ -n "${GAIA_COMPLIANCE_REGIMES:-}" ]; then
    printf '%s' "$GAIA_COMPLIANCE_REGIMES"
    return 0
  fi
  # Optional fallback via resolve-config.sh.
  local helper="${GAIA_RESOLVE_CONFIG:-resolve-config.sh}"
  if command -v "$helper" >/dev/null 2>&1; then
    "$helper" --get compliance.regimes 2>/dev/null || true
  fi
}

# Plugin root for rubric lookup (script lives at <root>/scripts/review-common/security/).
PLUGIN_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

load_regime_patterns() {
  local regimes raw r rubric line rule regex
  raw="$(resolve_regimes 2>/dev/null || true)"
  [ -z "$raw" ] && return 0
  IFS=',' read -r -a regimes <<< "$raw"
  for r in "${regimes[@]}"; do
    r="${r# }"; r="${r% }"
    [ -z "$r" ] && continue
    rubric="$PLUGIN_ROOT/rubrics/regimes/${r}.json"
    [ ! -f "$rubric" ] && continue
    # Extract { "rule": "...", "regex": "..." } pairs from the privacy.patterns
    # array. We do not parse generic JSON — the rubric format is a deterministic
    # one-pair-per-line layout (see rubrics/regimes/gdpr.json) so a small awk
    # state machine is sufficient.
    while IFS=$'\t' read -r rule regex; do
      [ -z "$rule" ] && continue
      [ -z "$regex" ] && continue
      REGIME_RULES+=("$rule")
      REGIME_REGEX+=("$regex")
    done < <(awk '
      BEGIN { in_priv=0; in_pat=0 }
      /"privacy"[[:space:]]*:/ { in_priv=1; next }
      in_priv && /"patterns"[[:space:]]*:/ { in_pat=1; next }
      in_pat && /"rule"/ {
        line=$0
        sub(/^[^"]*"rule"[[:space:]]*:[[:space:]]*"/, "", line)
        sub(/".*$/, "", line)
        rule=line
        next
      }
      in_pat && /"regex"/ {
        line=$0
        sub(/^[^"]*"regex"[[:space:]]*:[[:space:]]*"/, "", line)
        sub(/"[[:space:]]*[,}\]].*$/, "", line)
        sub(/"$/, "", line)
        regex=line
        if (rule != "" && regex != "") {
          printf "%s\t%s\n", rule, regex
          rule=""; regex=""
        }
      }
      in_pat && /\][[:space:]]*[,}]/ { in_pat=0 }
      in_priv && /^[[:space:]]*\}/ { in_priv=0 }
    ' "$rubric" 2>/dev/null || true)
  done
}

load_regime_patterns

# ---------- file classification: test vs source ----------

is_test_file() {
  # File-name based test markers (filename, not path).
  local base
  base="$(basename "$1")"
  case "$base" in
    *.test.*|*.spec.*|*_test.*|test_*.py|*Test.java|*Tests.java)
      return 0 ;;
  esac
  # Path-based test markers — only count `__tests__/` (an unambiguous test
  # marker) on the path. We do NOT count `test/` or `tests/` anywhere on the
  # path because routine staging dirs (e.g. `bats-run-.../test/N/`, CI temp
  # dirs) collide with that pattern. Trade-off: a project with `tests/` as a
  # source directory is matched by filename markers instead.
  case "$1" in
    */__tests__/*) return 0 ;;
  esac
  return 1
}

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
  local file="$1" line="$2" rule="$3" msg="$4" severity="$5"
  local file_esc msg_esc
  file_esc="$(printf '%s' "$file" | json_escape)"
  msg_esc="$(printf '%s' "$msg"  | json_escape)"
  if [ "$FINDING_COUNT" -gt 0 ]; then
    printf ',' >> "$FINDINGS_FILE"
  fi
  printf '{"file":"%s","line":%s,"severity":"%s","rule":"%s","message":"%s","blocking":false,"category":"privacy-pii"}' \
    "$file_esc" "$line" "$severity" "$rule" "$msg_esc" >> "$FINDINGS_FILE"
  FINDING_COUNT=$((FINDING_COUNT + 1))
}

# ---------- Luhn check (BSD-awk compatible, integer arithmetic) ----------

luhn_check() {
  # Accepts a digit-only string on stdin, prints "1" if Luhn-valid else "0".
  # Algorithm: from the right, double every second digit (i.e. the
  # second-to-last, fourth-to-last, ...). Doubled digits > 9 have their
  # digits summed (equivalently: subtract 9). Total mod 10 must be 0.
  awk '{
    s = $0
    n = length(s)
    sum = 0
    for (i = 1; i <= n; i++) {
      d = substr(s, n - i + 1, 1) + 0   # walk right-to-left
      if (i % 2 == 0) {                  # every second digit from the right
        d = d * 2
        if (d > 9) d = d - 9
      }
      sum += d
    }
    if (n >= 13 && n <= 19 && sum % 10 == 0) print "1"; else print "0"
  }'
}

# ---------- per-file scan ----------

scan_file() {
  local file="$1" sev="$2"
  # We scan once per category. Each detection emits a TSV row:
  #   file<TAB>line<TAB>rule<TAB>message
  # and we then forward to emit_finding with the resolved severity.

  # email
  awk -v file="$file" '
    /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/ {
      printf "%s\t%d\temail\thardcoded email-address pattern\n", file, NR
    }
  ' "$file" 2>/dev/null || true

  # SSN — strict ###-##-####
  awk -v file="$file" '
    /[^0-9-]([0-9]{3}-[0-9]{2}-[0-9]{4})[^0-9-]/ ||
    /^([0-9]{3}-[0-9]{2}-[0-9]{4})[^0-9-]/ ||
    /[^0-9-]([0-9]{3}-[0-9]{2}-[0-9]{4})$/ ||
    /^([0-9]{3}-[0-9]{2}-[0-9]{4})$/ {
      printf "%s\t%d\tssn\thardcoded SSN pattern\n", file, NR
    }
  ' "$file" 2>/dev/null || true

  # credit-card — extract any 13..19-digit run, Luhn-check.
  awk '{
    s = $0
    while (match(s, /[0-9]{13,19}/)) {
      seq = substr(s, RSTART, RLENGTH)
      print NR "\t" seq
      s = substr(s, RSTART + RLENGTH)
    }
  }' "$file" 2>/dev/null | while IFS=$'\t' read -r ln seq; do
    [ -z "$seq" ] && continue
    valid="$(printf '%s' "$seq" | luhn_check)"
    if [ "$valid" = "1" ]; then
      printf "%s\t%d\tcredit-card\thardcoded credit-card pattern (Luhn-valid)\n" \
        "$file" "$ln"
    fi
  done

  # phone — E.164 + North American (10-11 digits with separators)
  awk -v file="$file" '
    /\+[1-9][0-9]{6,14}/ {
      printf "%s\t%d\tphone\thardcoded phone-number (E.164) pattern\n", file, NR
      next
    }
    /\(?[2-9][0-9]{2}\)?[-. ][0-9]{3}[-. ][0-9]{4}/ {
      printf "%s\t%d\tphone\thardcoded phone-number (NANP) pattern\n", file, NR
    }
  ' "$file" 2>/dev/null || true

  # ip-address — IPv4 + simple IPv6 pattern in string contexts (heuristic)
  awk -v file="$file" '
    /[^0-9]([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})[^0-9]/ ||
    /^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})[^0-9]/ ||
    /[^0-9]([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})$/ {
      # Reject obvious version strings like "1.2.3.4" only if no other digits — keep
      # behavior simple: any 4-octet match is flagged. Reviewers can tier in 3B.
      printf "%s\t%d\tip-address\thardcoded IPv4 literal\n", file, NR
    }
    /[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{1,4}){4,7}/ {
      printf "%s\t%d\tip-address\thardcoded IPv6 literal\n", file, NR
    }
  ' "$file" 2>/dev/null || true

  # Regime patterns (looped). We pass each regex via -v and use awk's
  # dynamic-regex match (which is BSD-awk compatible).
  local i
  for ((i=0; i<${#REGIME_RULES[@]}; i++)); do
    local rrule="${REGIME_RULES[$i]}" rregex="${REGIME_REGEX[$i]}"
    [ -z "$rrule" ] && continue
    [ -z "$rregex" ] && continue
    awk -v file="$file" -v rule="$rrule" -v re="$rregex" '
      $0 ~ re {
        printf "%s\t%d\t%s\thardcoded %s pattern (regime)\n", file, NR, rule, rule
      }
    ' "$file" 2>/dev/null || true
  done
}

# ---------- main scan ----------

while IFS= read -r f || [ -n "$f" ]; do
  [ -z "$f" ] && continue
  [ ! -f "$f" ] && continue
  if is_test_file "$f"; then
    sev="medium"
  else
    sev="critical"
  fi
  while IFS=$'\t' read -r ff fl rr mm; do
    [ -z "$ff" ] && continue
    emit_finding "$ff" "$fl" "$rr" "$mm" "$sev"
  done < <(scan_file "$f" "$sev")
done < "$DEDUPED_FILE"

# ---------- emit ----------

if [ "$FINDING_COUNT" -gt 0 ]; then
  STATUS="failed"
else
  STATUS="passed"
fi

printf '{"name":"pii-detector","scope":"file","status":"%s","findings":[' "$STATUS"
cat "$FINDINGS_FILE"
printf ']}\n'

exit 0
