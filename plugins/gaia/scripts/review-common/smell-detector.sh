#!/usr/bin/env bash
# smell-detector.sh — GAIA review-common Phase 3A test-smell detector.
#
# Purpose
# -------
# Deterministic scanner that flags three test-quality smells inside test files
# and emits a single `analysis-results.json`-shaped check fragment on stdout:
#
#   - test-name-says-too-much  : overly verbose "should ... and ... and ..." names
#   - mystery-guest            : test references external fixture paths without
#                                an explicit setup/import line in the same file
#   - conditional-assertion    : assertion (expect/assert/should) inside an
#                                if/else/switch branch
#
# Output (stdout): a JSON fragment of the canonical shape used by Phase 3A
# evidence merging — i.e., a single `checks[]` element:
#
#   {
#     "name": "smell-detector",
#     "scope": "file",
#     "status": "passed|failed",
#     "findings": [
#       {"file":"<path>","line":<int>,"severity":"<tier>",
#        "rule":"<smell-type>","message":"<text>","blocking":false,
#        "category":"test-quality"}
#     ]
#   }
#
# `status: failed` when ≥1 finding is emitted, `passed` otherwise. `blocking`
# is always `false` for this analyzer — Phase 3B (LLM judgment) tier-classifies
# Critical vs Warning vs Suggestion. Exit code is ALWAYS 0 on successful run
# (including when findings are non-empty) so that pipeline merging is shell-safe.
#
# Caller error (missing input, unreadable path) → exit 1, error on stderr.
#
# Invocation
# ----------
#   smell-detector.sh <path>...
#   smell-detector.sh --file-list <listfile>
#   smell-detector.sh --help
#
# Each <path> may be a file or directory; directories are walked for test files
# matching common test-name patterns (*.test.*, *.spec.*, test_*.py, *_test.py,
# *Test.java, *_test.go).
#
# POSIX discipline: bash + set -euo pipefail + LC_ALL=C; macOS bash 3.2 + BSD
# awk compatible (no 3-arg match, no associative arrays); no jq dependency.
#

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="smell-detector.sh"

die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
$SCRIPT_NAME — Phase 3A test-smell detector.

Usage:
  $SCRIPT_NAME <path>...
  $SCRIPT_NAME --file-list <listfile>
  $SCRIPT_NAME --help

Smell categories detected:
  test-name-says-too-much   it()/test() name with multiple "and" clauses
  mystery-guest             external fixture path used without explicit setup
  conditional-assertion     expect/assert/should inside if/else/switch

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

discover_test_files() {
  local p
  for p in "$@"; do
    if [ -f "$p" ]; then
      printf '%s\n' "$p"
    elif [ -d "$p" ]; then
      find "$p" -type f \( \
        -name '*.test.ts' -o -name '*.test.tsx' -o -name '*.test.js' -o -name '*.test.jsx' \
        -o -name '*.spec.ts' -o -name '*.spec.tsx' -o -name '*.spec.js' -o -name '*.spec.jsx' \
        -o -name 'test_*.py' -o -name '*_test.py' \
        -o -name '*Test.java' -o -name '*Tests.java' \
        -o -name '*_test.go' \
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
  INPUT_FILES="${INPUT_FILES}$(discover_test_files "${PATHS[@]}")"$'\n'
fi

# Deduplicate while preserving first-seen order.
SEEN_TMP="$(mktemp -t gaia-smell-seen.XXXXXX)"
FINDINGS_FILE="$(mktemp -t gaia-smell-findings.XXXXXX)"
DEDUPED_FILE="$(mktemp -t gaia-smell-deduped.XXXXXX)"
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

# JSON-escape a single-line string. Reads stdin, emits escaped string.
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
  printf '{"file":"%s","line":%s,"severity":"warning","rule":"%s","message":"%s","blocking":false,"category":"test-quality"}' \
    "$file_esc" "$line" "$rule" "$msg_esc" >> "$FINDINGS_FILE"
  FINDING_COUNT=$((FINDING_COUNT + 1))
}

# ---------- detector: test-name-says-too-much ----------
# Match it(...), test(...), describe(...) name and count " and " clauses.

detect_too_much_name() {
  local file="$1"
  # Use awk + multiple gsub passes (BSD-awk friendly: no 3-arg match).
  awk -v file="$file" '
    {
      ln = NR
      raw = $0
      # JS/TS: it("...") or test("...") or describe("...")
      if (raw ~ /^[[:space:]]*(it|test|describe)[[:space:]]*\([[:space:]]*["\x27]/) {
        # Extract the name string between the first quote and its matching quote.
        s = raw
        # Trim leading "<call>("
        sub(/^[[:space:]]*(it|test|describe)[[:space:]]*\([[:space:]]*/, "", s)
        q = substr(s, 1, 1)
        if (q == "\"" || q == "\x27") {
          rest = substr(s, 2)
          # Find next q
          idx = index(rest, q)
          if (idx > 0) {
            name = substr(rest, 1, idx - 1)
            n = gsub(/ and /, " and ", name)
            if (n >= 2) {
              esc = name
              gsub(/\t/, " ", esc)
              printf "%s\t%d\ttest-name-says-too-much\ttest name has %d \"and\" clauses: %s\n", file, ln, n, esc
            }
          }
        }
      }
      # Python: def test_name_says_x_and_y_and_z
      if (raw ~ /def[[:space:]]+test_/) {
        s = raw
        sub(/^.*def[[:space:]]+/, "", s)
        # Take up to first non-name char
        nm = ""
        for (i = 1; i <= length(s); i++) {
          c = substr(s, i, 1)
          if (c ~ /[A-Za-z0-9_]/) nm = nm c; else break
        }
        if (nm != "") {
          n = gsub(/_and_/, "_and_", nm)
          if (n >= 2) {
            printf "%s\t%d\ttest-name-says-too-much\ttest name has %d \"_and_\" segments: %s\n", file, ln, n, nm
          }
        }
      }
    }
  ' "$file" 2>/dev/null || true
}

# ---------- detector: mystery-guest ----------
# A fixture path string like ".../fixtures/...", "/test-data/...", "/testdata/...",
# or "/__fixtures__/..." appears in a test file that has no explicit setup/import
# call (require, import, readFile, fs.read, open, loadFixture, fixture(...) ).

detect_mystery_guest() {
  local file="$1"
  awk -v file="$file" '
    {
      ln = NR
      if ($0 ~ /(require[[:space:]]*\(|import[[:space:]]+|readFile|readFileSync|fs\.read|open[[:space:]]*\(|loadFixture|loadJson|fixture[[:space:]]*\(|Path[[:space:]]*\()/) {
        setup_seen = 1
      }
      if ($0 ~ /["\x27][^"\x27]*\/(fixtures|test-data|testdata|__fixtures__)\/[^"\x27]+["\x27]/) {
        # Scan every quoted string on the line; flag the first one that looks
        # like a fixture path. A line may contain unrelated quoted strings
        # (e.g. the test name) before the actual fixture path literal.
        s = $0
        i = 1
        slen = length(s)
        while (i <= slen) {
          c = substr(s, i, 1)
          if (c == "\"" || c == "\x27") {
            rest = substr(s, i + 1)
            j = index(rest, c)
            if (j > 0) {
              candidate = substr(rest, 1, j - 1)
              if (candidate ~ /\/(fixtures|test-data|testdata|__fixtures__)\//) {
                buf_n++
                buf_lines[buf_n] = ln
                buf_paths[buf_n] = candidate
                break
              }
              i = i + j + 1
            } else {
              i = slen + 1
            }
          } else {
            i++
          }
        }
      }
    }
    END {
      if (!setup_seen) {
        for (i = 1; i <= buf_n; i++) {
          esc = buf_paths[i]
          gsub(/\t/, " ", esc)
          printf "%s\t%d\tmystery-guest\treferences fixture path %s without explicit setup/import in same file\n", file, buf_lines[i], esc
        }
      }
    }
  ' "$file" 2>/dev/null || true
}

# ---------- detector: conditional-assertion ----------

detect_conditional_assertion() {
  local file="$1"
  awk -v file="$file" '
    BEGIN { window = 5 }
    {
      ln = NR
      # parameterized-block window opens
      if ($0 ~ /(it\.each|test\.each|describe\.each|@pytest\.mark\.parametrize|@ParameterizedTest)/) {
        param_until = ln + 30
      }
      # conditional-branch window opens
      if ($0 ~ /([[:space:]]if[[:space:]]*\(|^[[:space:]]*if[[:space:]]*\(|[[:space:]]else[[:space:]]*[\{:]|[[:space:]]else[[:space:]]+if|[[:space:]]switch[[:space:]]*\(|^[[:space:]]*case[[:space:]].*:|^[[:space:]]*if[[:space:]]+|^[[:space:]]*elif[[:space:]]+)/) {
        cond_open = ln
        cond_until = ln + window
      }
      # assertion call
      if ($0 ~ /(expect[[:space:]]*\(|[[:space:]]assert[[:space:]]*\(|^[[:space:]]*assert[[:space:]]*\(|assertTrue|assertFalse|assertEquals|assertThat|self\.assert|should\.|\.should[[:space:]]*\()/) {
        if (cond_until && ln <= cond_until && (!param_until || ln > param_until)) {
          printf "%s\t%d\tconditional-assertion\tassertion inside conditional branch (cond opened at line %d)\n", file, ln, cond_open
        }
      }
    }
  ' "$file" 2>/dev/null || true
}

# ---------- main scan ----------
# Process substitution is used so FINDING_COUNT mutates in the parent shell
# (a `while ... | while ...` pipe would create a subshell and lose state).

while IFS= read -r f || [ -n "$f" ]; do
  [ -z "$f" ] && continue
  [ ! -f "$f" ] && continue
  while IFS=$'\t' read -r ff fl rr mm; do
    [ -z "$ff" ] && continue
    emit_finding "$ff" "$fl" "$rr" "$mm"
  done < <( detect_too_much_name "$f"; detect_mystery_guest "$f"; detect_conditional_assertion "$f" )
done < "$DEDUPED_FILE"

# ---------- emit check fragment ----------

if [ "$FINDING_COUNT" -gt 0 ]; then
  STATUS="failed"
else
  STATUS="passed"
fi

printf '{"name":"smell-detector","scope":"file","status":"%s","findings":[' "$STATUS"
cat "$FINDINGS_FILE"
printf ']}\n'

exit 0
