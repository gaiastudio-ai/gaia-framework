#!/usr/bin/env bash
# tag-conformance-detector.sh — GAIA review-common Phase 3A per-stack tag detector (E67-S1, ADR-077).
#
# Purpose
# -------
# Per-stack scanner that checks whether each test file declares at least one
# tag using the canonical mechanism for its stack. Stacks supported:
#
#   ts-dev       Vitest / Jest             — describe.each / it.each / .each / tagged it()
#   angular-dev  Karma / Jasmine / Jest    — same as ts-dev
#   java-dev     JUnit 5                   — @Tag annotation on class or method
#   python-dev   pytest                    — @pytest.mark.<name> decorator
#   go-dev       Go testing                — //go:build <tag> directive
#   flutter-dev  dart test                 — @Tags(['name'])
#   mobile-dev   Maestro / XCTest / Espresso — Maestro flow front-matter `tags:`
#                                            (defers to JUnit for Android, XCTest tagging
#                                            via @MainActor / @available currently
#                                            treated as missing — story scope)
#
# Output (stdout): a JSON fragment of the canonical Phase 3A check shape:
#
#   {
#     "name": "tag-conformance-detector",
#     "scope": "file",
#     "status": "passed|failed",
#     "findings": [
#       {"file":"<path>","line":<int>,"severity":"warning",
#        "rule":"missing-tag",
#        "message":"<text>","blocking":false,"category":"tag-conformance",
#        "stack":"<canonical-stack>"}
#     ]
#   }
#
# Status `failed` whenever ≥1 finding is emitted. Exit code is ALWAYS 0 on
# successful run (caller-error-only exit 1).
#
# Invocation
# ----------
#   tag-conformance-detector.sh --stack <stack> <path>...
#   tag-conformance-detector.sh --stack <stack> --file-list <listfile>
#   tag-conformance-detector.sh --help
#
# `--stack` is required and must be one of the canonical stack vocabulary.
#
# POSIX discipline: bash + set -euo pipefail + LC_ALL=C; macOS bash 3.2 + BSD
# awk compatible (no 3-arg match, no associative arrays); no jq dependency.
#
# Refs: AC4, AC6, AC7, FR-RSV2-1, FR-RSV2-2, NFR-RSV2-1, ADR-075, ADR-077.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="tag-conformance-detector.sh"

die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
$SCRIPT_NAME — Phase 3A per-stack tag-conformance detector (ADR-077).

Usage:
  $SCRIPT_NAME --stack <stack> <path>...
  $SCRIPT_NAME --stack <stack> --file-list <listfile>
  $SCRIPT_NAME --help

<stack> is one of: ts-dev | angular-dev | java-dev | python-dev | go-dev |
                   flutter-dev | mobile-dev

Emits a single analysis-results.json checks[] fragment to stdout.
Exit 0 on successful scan.
EOF
}

# ---------- arg parsing ----------

STACK=""
PATHS=()
FILE_LIST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --stack)
      [ $# -ge 2 ] || die "--stack requires a value"
      STACK="$2"; shift 2 ;;
    --file-list)
      [ $# -ge 2 ] || die "--file-list requires a path"
      FILE_LIST="$2"; shift 2 ;;
    --) shift; while [ $# -gt 0 ]; do PATHS+=("$1"); shift; done ;;
    -*) die "unknown flag: $1" ;;
    *) PATHS+=("$1"); shift ;;
  esac
done

[ -n "$STACK" ] || die "--stack is required"
case "$STACK" in
  ts-dev|angular-dev|java-dev|python-dev|go-dev|flutter-dev|mobile-dev) ;;
  *) die "unknown stack: '$STACK' (expected ts-dev|angular-dev|java-dev|python-dev|go-dev|flutter-dev|mobile-dev)" ;;
esac

# ---------- discover input files ----------

discover_test_files_for_stack() {
  local p stack="$1"; shift
  for p in "$@"; do
    if [ -f "$p" ]; then
      printf '%s\n' "$p"
    elif [ -d "$p" ]; then
      case "$stack" in
        ts-dev|angular-dev)
          find "$p" -type f \( \
            -name '*.test.ts' -o -name '*.test.tsx' -o -name '*.test.js' -o -name '*.test.jsx' \
            -o -name '*.spec.ts' -o -name '*.spec.tsx' -o -name '*.spec.js' -o -name '*.spec.jsx' \
          \) 2>/dev/null ;;
        java-dev)
          find "$p" -type f \( -name '*Test.java' -o -name '*Tests.java' -o -name '*IT.java' \) 2>/dev/null ;;
        python-dev)
          find "$p" -type f \( -name 'test_*.py' -o -name '*_test.py' \) 2>/dev/null ;;
        go-dev)
          find "$p" -type f -name '*_test.go' 2>/dev/null ;;
        flutter-dev)
          find "$p" -type f \( -name '*_test.dart' -o -name '*.test.dart' \) 2>/dev/null ;;
        mobile-dev)
          find "$p" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*Test.kt' -o -name '*Tests.kt' -o -name '*Test.java' -o -name '*Tests.java' \) 2>/dev/null ;;
      esac
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
  INPUT_FILES="${INPUT_FILES}$(discover_test_files_for_stack "$STACK" "${PATHS[@]}")"$'\n'
fi

SEEN_TMP="$(mktemp -t gaia-tag-seen.XXXXXX)"
FINDINGS_FILE="$(mktemp -t gaia-tag-findings.XXXXXX)"
DEDUPED_FILE="$(mktemp -t gaia-tag-deduped.XXXXXX)"
trap 'rm -f "$SEEN_TMP" "$FINDINGS_FILE" "$DEDUPED_FILE"' EXIT

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
  printf '{"file":"%s","line":%s,"severity":"warning","rule":"%s","message":"%s","blocking":false,"category":"tag-conformance","stack":"%s"}' \
    "$file_esc" "$line" "$rule" "$msg_esc" "$STACK" >> "$FINDINGS_FILE"
  FINDING_COUNT=$((FINDING_COUNT + 1))
}

# ---------- per-stack tag presence checks ----------

has_tag_ts() {
  # Vitest/Jest: any of describe.each / it.each / .each / tagged it() with @category-style flags.
  local f="$1"
  grep -Eq '(describe|it|test)\.each|@[A-Za-z][A-Za-z0-9_-]*[[:space:]]*$|tags:[[:space:]]*\[' "$f" 2>/dev/null
}

has_tag_java() {
  local f="$1"
  grep -Eq '@Tag[[:space:]]*\(' "$f" 2>/dev/null
}

has_tag_python() {
  local f="$1"
  grep -Eq '@pytest\.mark\.[A-Za-z_][A-Za-z0-9_]*' "$f" 2>/dev/null
}

has_tag_go() {
  local f="$1"
  # Build tag must be in the first 10 lines of the file (Go convention).
  head -n 10 "$f" 2>/dev/null | grep -Eq '^//go:build[[:space:]]+'
}

has_tag_flutter() {
  local f="$1"
  grep -Eq "@Tags\(\[" "$f" 2>/dev/null
}

has_tag_mobile() {
  # Maestro flows: front-matter `tags:` field at the top of the file.
  # JUnit-on-Android: @Tag on Kotlin/Java methods.
  local f="$1"
  case "$f" in
    *.yaml|*.yml)
      head -n 30 "$f" 2>/dev/null | grep -Eq '^[[:space:]]*tags:[[:space:]]*' ;;
    *.kt|*.java)
      grep -Eq '@Tag[[:space:]]*\(' "$f" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

# ---------- main scan ----------

while IFS= read -r f || [ -n "$f" ]; do
  [ -z "$f" ] && continue
  [ ! -f "$f" ] && continue
  ok=1
  case "$STACK" in
    ts-dev|angular-dev) has_tag_ts "$f" || ok=0 ;;
    java-dev)           has_tag_java "$f" || ok=0 ;;
    python-dev)         has_tag_python "$f" || ok=0 ;;
    go-dev)             has_tag_go "$f" || ok=0 ;;
    flutter-dev)        has_tag_flutter "$f" || ok=0 ;;
    mobile-dev)         has_tag_mobile "$f" || ok=0 ;;
  esac
  if [ "$ok" = "0" ]; then
    case "$STACK" in
      ts-dev|angular-dev)
        emit_finding "$f" 1 "missing-tag" \
          "no Vitest/Jest tag mechanism (describe.each / it.each / tagged it()) found in test file" ;;
      java-dev)
        emit_finding "$f" 1 "missing-tag" \
          "no JUnit @Tag annotation found in test file" ;;
      python-dev)
        emit_finding "$f" 1 "missing-tag" \
          "no @pytest.mark.<name> decorator found in test file" ;;
      go-dev)
        emit_finding "$f" 1 "missing-tag" \
          "no //go:build directive found in first 10 lines of test file" ;;
      flutter-dev)
        emit_finding "$f" 1 "missing-tag" \
          "no @Tags(['…']) annotation found in test file" ;;
      mobile-dev)
        emit_finding "$f" 1 "missing-tag" \
          "no Maestro front-matter tags: field (or JUnit @Tag) found in test file" ;;
    esac
  fi
done < "$DEDUPED_FILE"

# ---------- emit check fragment ----------

if [ "$FINDING_COUNT" -gt 0 ]; then
  STATUS="failed"
else
  STATUS="passed"
fi

printf '{"name":"tag-conformance-detector","scope":"file","status":"%s","findings":[' "$STATUS"
cat "$FINDINGS_FILE"
printf ']}\n'

exit 0
