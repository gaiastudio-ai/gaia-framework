#!/usr/bin/env bash
# flakiness-analyzer.sh — GAIA review-common Phase 3A flakiness detector (E67-S1, ADR-077).
#
# Purpose
# -------
# Static-source flakiness signal source per FR-DEJ-3 / ADR-077. Detects three
# patterns that strongly correlate with flaky tests:
#
#   - retry-heuristic           : `.retry(`, `retries:`, `flaky:`, `@RepeatedTest`,
#                                 `@Retry`, `pytest.mark.flaky`
#   - time-dependent-assertion  : `Date.now()`, `setTimeout(`, `sleep(`,
#                                 `time.sleep(`, `Thread.sleep(`,
#                                 `System.currentTimeMillis()` within 5 lines
#                                 of an expect/assert/should call
#   - shared-state-mutation     : write to a module-level/global variable inside
#                                 `beforeAll` / `beforeEach` / `setUp` / `setUpClass`
#                                 with no matching `afterAll`/`afterEach`/
#                                 `tearDown` reset
#
# Output (stdout): a JSON fragment of the canonical Phase 3A check shape:
#
#   {
#     "name": "flakiness-analyzer",
#     "scope": "file",
#     "status": "passed|failed",
#     "findings": [
#       {"file":"<path>","line":<int>,"severity":"warning",
#        "rule":"<retry-heuristic|time-dependent-assertion|shared-state-mutation>",
#        "message":"<text>","blocking":false,"category":"flakiness"}
#     ]
#   }
#
# Status `failed` whenever ≥1 finding is emitted. Exit code is ALWAYS 0 on
# successful run (caller-error-only exit 1).
#
# Invocation
# ----------
#   flakiness-analyzer.sh <path>...
#   flakiness-analyzer.sh --file-list <listfile>
#   flakiness-analyzer.sh --help
#
# POSIX discipline: bash + set -euo pipefail + LC_ALL=C; macOS bash 3.2 + BSD
# awk compatible (no 3-arg match, no associative arrays); no jq dependency.
#
# Refs: AC2, AC6, AC7, FR-RSV2-1, FR-RSV2-2, NFR-RSV2-1, ADR-075, ADR-077.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="flakiness-analyzer.sh"

die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
$SCRIPT_NAME — Phase 3A flakiness analyzer (ADR-077).

Usage:
  $SCRIPT_NAME <path>...
  $SCRIPT_NAME --file-list <listfile>
  $SCRIPT_NAME --help

Detects retry heuristics, time-dependent assertions, shared-state mutations.
Emits a single analysis-results.json checks[] fragment to stdout.
Exit 0 on successful scan.
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

SEEN_TMP="$(mktemp -t gaia-flake-seen.XXXXXX)"
FINDINGS_FILE="$(mktemp -t gaia-flake-findings.XXXXXX)"
DEDUPED_FILE="$(mktemp -t gaia-flake-deduped.XXXXXX)"
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
  printf '{"file":"%s","line":%s,"severity":"warning","rule":"%s","message":"%s","blocking":false,"category":"flakiness"}' \
    "$file_esc" "$line" "$rule" "$msg_esc" >> "$FINDINGS_FILE"
  FINDING_COUNT=$((FINDING_COUNT + 1))
}

# ---------- detector: retry-heuristic ----------

detect_retry() {
  local file="$1"
  awk -v file="$file" '
    {
      ln = NR
      # JS/TS / Mocha / Vitest / Jest
      if ($0 ~ /(\.retry[[:space:]]*\(|retries[[:space:]]*:[[:space:]]*[0-9]+|flaky[[:space:]]*:[[:space:]]*true)/) {
        printf "%s\t%d\tretry-heuristic\tretry/flaky configuration in test file\n", file, ln
        next
      }
      # Java JUnit
      if ($0 ~ /(@RepeatedTest|@Retry|@Flaky)/) {
        printf "%s\t%d\tretry-heuristic\tJUnit retry/flaky annotation\n", file, ln
        next
      }
      # Python pytest
      if ($0 ~ /(@pytest\.mark\.flaky|pytest\.mark\.flaky)/) {
        printf "%s\t%d\tretry-heuristic\tpytest flaky marker\n", file, ln
        next
      }
      # Go testify
      if ($0 ~ /(retry\.Do|require\.Eventually|assert\.Eventually)/) {
        printf "%s\t%d\tretry-heuristic\teventually/retry helper in Go test\n", file, ln
        next
      }
    }
  ' "$file" 2>/dev/null || true
}

# ---------- detector: time-dependent-assertion ----------
# Heuristic: a time-API call within 5 lines of an assertion call.

detect_time_dependent() {
  local file="$1"
  awk -v file="$file" '
    BEGIN { window = 5 }
    {
      ln = NR
      # Track last seen time-API call.
      if ($0 ~ /(Date\.now[[:space:]]*\(|setTimeout[[:space:]]*\(|setInterval[[:space:]]*\(|sleep[[:space:]]*\(|time\.sleep[[:space:]]*\(|Thread\.sleep[[:space:]]*\(|System\.currentTimeMillis[[:space:]]*\(|performance\.now[[:space:]]*\(|new[[:space:]]+Date[[:space:]]*\()/) {
        time_open = ln
        time_until = ln + window
        # Capture description for message.
        time_desc = $0
        sub(/^[[:space:]]+/, "", time_desc)
      }
      # Detect assertion within window after a time-API call.
      if ($0 ~ /(expect[[:space:]]*\(|^[[:space:]]*assert[[:space:]]*\(|[[:space:]]assert[[:space:]]*\(|assertTrue|assertFalse|assertEquals|assertThat|self\.assert|should\.|\.should[[:space:]]*\()/) {
        if (time_until && ln <= time_until) {
          printf "%s\t%d\ttime-dependent-assertion\tassertion within %d lines of time-API call (line %d)\n", file, ln, window, time_open
        }
      }
      # Direct time-in-assertion (single-line forms like `expect(Date.now() - start)`).
      if ($0 ~ /expect[[:space:]]*\([^)]*(Date\.now|performance\.now|System\.currentTimeMillis)/) {
        printf "%s\t%d\ttime-dependent-assertion\ttime API used directly in assertion expression\n", file, ln
      }
    }
  ' "$file" 2>/dev/null || true
}

# ---------- detector: shared-state-mutation ----------
# A write inside beforeAll/beforeEach/setUp/setUpClass to a name that has no
# corresponding reset in afterAll/afterEach/tearDown/tearDownClass within
# the same file. Heuristic — names of variables assigned in the setup block
# are tracked, then we search for the same name being re-assigned (or
# reset to a literal) in a teardown block.

detect_shared_state() {
  local file="$1"
  awk -v file="$file" '
    BEGIN {
      in_setup = 0; setup_block = ""; setup_line = 0
      in_teardown = 0; teardown_block = ""
      n_assign = 0
    }
    function flush_setup(   i, name, line, found, t) {
      # For each name assigned in setup_block, check if same name is in
      # teardown_block (as a re-assignment).
      for (i = 1; i <= n_assign; i++) {
        name = assign_name[i]
        line = assign_line[i]
        found = 0
        # Reset all teardown_block lines and look for "name ="
        if (teardown_block ~ ("[[:space:]]" name "[[:space:]]*=") ||
            teardown_block ~ ("^" name "[[:space:]]*=")) {
          found = 1
        }
        if (!found) {
          printf "%s\t%d\tshared-state-mutation\tsetup block writes to '%s' without reset in teardown\n", file, line, name
        }
      }
      n_assign = 0
      delete assign_name
      delete assign_line
    }
    {
      ln = NR
      raw = $0
      # Detect entry to setup block.
      if (raw ~ /(beforeAll|beforeEach|setUp[[:space:]]*\(|setUpClass[[:space:]]*\(|@BeforeAll|@BeforeEach|@Before)[[:space:]]*[\(\{:]/ ||
          raw ~ /^[[:space:]]*def[[:space:]]+(setUp|setUpClass)[[:space:]]*\(/ ||
          raw ~ /^[[:space:]]*(beforeAll|beforeEach)[[:space:]]*\(/ ) {
        in_setup = 1; depth = 0; setup_line = ln
      }
      # Detect entry to teardown block.
      if (raw ~ /(afterAll|afterEach|tearDown[[:space:]]*\(|tearDownClass[[:space:]]*\(|@AfterAll|@AfterEach|@After)[[:space:]]*[\(\{:]/ ||
          raw ~ /^[[:space:]]*def[[:space:]]+(tearDown|tearDownClass)[[:space:]]*\(/ ||
          raw ~ /^[[:space:]]*(afterAll|afterEach)[[:space:]]*\(/ ) {
        in_teardown = 1
      }
      # Inside setup: capture variable assignments at module scope (no leading "let|const|var" keyword in the LHS context).
      if (in_setup) {
        setup_block = setup_block "\n" raw
        # Pattern: `<NAME> = <something>` or `<NAME>.push(...)` or `<NAME>.<key> = ...`
        if (raw ~ /^[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*(\.[A-Za-z_][A-Za-z0-9_]*[[:space:]]*)?(=|\.push[[:space:]]*\(|\.append[[:space:]]*\(|\.add[[:space:]]*\()/ ) {
          # Extract the leading identifier.
          s = raw
          sub(/^[[:space:]]+/, "", s)
          # Take chars up to first non-name char.
          name = ""
          for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (c ~ /[A-Za-z0-9_]/) name = name c; else break
          }
          # Skip declared-locals: `let foo`, `const foo`, `var foo`.
          if (name != "" && name != "let" && name != "const" && name != "var" && name != "this" && name != "self") {
            n_assign++
            assign_name[n_assign] = name
            assign_line[n_assign] = ln
          }
        }
        # End-of-block heuristic: closing brace at column 0/1/2 OR `})` at start.
        if (raw ~ /^[[:space:]]{0,4}(\}\)|\})[[:space:]]*$/) {
          in_setup = 0
        }
      }
      if (in_teardown) {
        teardown_block = teardown_block "\n" raw
        if (raw ~ /^[[:space:]]{0,4}(\}\)|\})[[:space:]]*$/) {
          in_teardown = 0
        }
      }
    }
    END {
      flush_setup()
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
  done < <( detect_retry "$f"; detect_time_dependent "$f"; detect_shared_state "$f" )
done < "$DEDUPED_FILE"

# ---------- emit check fragment ----------

if [ "$FINDING_COUNT" -gt 0 ]; then
  STATUS="failed"
else
  STATUS="passed"
fi

printf '{"name":"flakiness-analyzer","scope":"file","status":"%s","findings":[' "$STATUS"
cat "$FINDINGS_FILE"
printf ']}\n'

exit 0
