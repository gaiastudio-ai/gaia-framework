#!/usr/bin/env bash
# ac-coverage-analyzer.sh — deterministic AC-to-test coverage analyzer.
#
# Analyses a story's acceptance criteria against discovered test files and
# produces a single JSON check object (name: "ac-coverage") suitable for
# inclusion in analysis-results.json.
#
# Usage:
#   ac-coverage-analyzer.sh --story-file <path> --story-key <key> \
#     [--test-dir <dir>] [--stack <stack>]
#
# Exit codes:
#   0 — success (JSON check on stdout)
#   1 — missing required argument or unrecoverable error (unknown stack,
#       discovery timeout)

set -euo pipefail
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

STORY_FILE=""
STORY_KEY=""
TEST_DIR="."
STACK="ts-dev"
_STACK_DEFAULTED=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --story-file)
      [ "$#" -ge 2 ] || { printf 'ac-coverage-analyzer.sh: --story-file requires a path\n' >&2; exit 1; }
      STORY_FILE="$2"; shift 2 ;;
    --story-key)
      [ "$#" -ge 2 ] || { printf 'ac-coverage-analyzer.sh: --story-key requires a value\n' >&2; exit 1; }
      STORY_KEY="$2"; shift 2 ;;
    --test-dir)
      [ "$#" -ge 2 ] || { printf 'ac-coverage-analyzer.sh: --test-dir requires a path\n' >&2; exit 1; }
      TEST_DIR="$2"; shift 2 ;;
    --stack)
      [ "$#" -ge 2 ] || { printf 'ac-coverage-analyzer.sh: --stack requires a value\n' >&2; exit 1; }
      STACK="$2"; _STACK_DEFAULTED=0; shift 2 ;;
    *)
      printf 'ac-coverage-analyzer.sh: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

[ -n "$STORY_FILE" ] || { printf 'ac-coverage-analyzer.sh: missing required --story-file\n' >&2; exit 1; }
[ -n "$STORY_KEY" ]  || { printf 'ac-coverage-analyzer.sh: missing required --story-key\n' >&2; exit 1; }

# ---------------------------------------------------------------------------
# Single work directory — cleaned by one EXIT trap
# ---------------------------------------------------------------------------

_TMPDIR="${TMPDIR:-/tmp}"
_WORKDIR="$(mktemp -d "$_TMPDIR/ac-cov-XXXXXX")"
trap 'rm -rf "$_WORKDIR"' EXIT

_AC_LIST="$_WORKDIR/aclist"
_TEST_PAIRS="$_WORKDIR/testpairs"
_FINDINGS="$_WORKDIR/findings"
_AC_RESULTS="$_WORKDIR/acresults"
_NDJSON_AC="$_WORKDIR/ndjson-ac"
_NDJSON_FINDINGS="$_WORKDIR/ndjson-find"
_NDJSON_UNATTR="$_WORKDIR/ndjson-unattr"
_PATTERNS="$_WORKDIR/patterns"
_MATCH_OUT="$_WORKDIR/matchout"

# ---------------------------------------------------------------------------
# Stopwords list (shared between shell and awk)
# Stopwords are stripped so single-word phrases like "user" or "submit" do not
# produce false PARTIALLY MET matches against unrelated test identifiers.
# "when", "then", "given" are included because the G/W/T keywords themselves
# carry no semantic value once the phrase has been split.
# ---------------------------------------------------------------------------

_STOPWORDS_LIST="a an the is are was were to of in on with for that it and or but not when then given should must can will be"
_STOPWORDS=" $_STOPWORDS_LIST "

_is_stopword() {
  case "$_STOPWORDS" in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Read story priority from YAML frontmatter (default P1)
# Priority determines severity of NOT MET findings: P0 stories get "critical"
# severity on primary AC gaps; P1/P2 get "warning". The resolver's blocking
# decision uses the finding's `blocking` flag (always true for primary NOT MET),
# not severity, so the severity difference is informational for triage ordering.
# ---------------------------------------------------------------------------

_read_priority() {
  local prio
  prio="$(sed -n '/^---/,/^---/{ s/^priority:[[:space:]]*["'"'"']*\([^"'"'"']*\)["'"'"']*/\1/p; }' "$STORY_FILE" 2>/dev/null | head -1 | tr -d '[:space:]')"
  case "$prio" in
    P0|P1|P2|P3) printf '%s' "$prio" ;;
    *) printf 'P1' ;;
  esac
}

PRIORITY="$(_read_priority)"

# ---------------------------------------------------------------------------
# Parse ACs from the story file
# ---------------------------------------------------------------------------

# Each line: AC_ID<TAB>IS_EDGE<TAB>HAS_GWT<TAB>AC_TEXT_AFTER_COLON

# AC id allowlist: must match ^AC[A-Za-z0-9_-]*$
_valid_ac_id() {
  case "$1" in
    AC*) ;;
    *) return 1 ;;
  esac
  # Check that the remaining chars (after AC) are only alphanumerics, underscore, hyphen
  local rest
  rest="$(printf '%s' "$1" | sed 's/^AC//')"
  case "$rest" in
    *[!A-Za-z0-9_-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Extract ACs — accept both unchecked (- [ ]) and checked (- [x]/- [X]) forms
: > "$_AC_LIST"
: > "$_NDJSON_AC"
: > "$_NDJSON_FINDINGS"

# Track seen AC ids for duplicate detection
_seen_ac_ids=""

while IFS= read -r line; do
  # Extract the text between the first ** pair (the bold label).
  _bold_text="$(printf '%s' "$line" | sed -n 's/^- \[[ xX]\] \*\*\([^*]*\)\*\*.*/\1/p')"
  [ -n "$_bold_text" ] || continue

  # Take the leading token matching AC followed by at least one id character
  # as the id. Decorated forms like "AC2 — Export works:" or "AC1 (P0):"
  # yield AC2 / AC1. Bare "AC" without a suffix is treated as malformed.
  ac_id="$(printf '%s' "$_bold_text" | sed -n 's/^\(AC[A-Za-z0-9_-][A-Za-z0-9_-]*\).*/\1/p')"

  # A line whose bold label has no leading AC token is malformed.
  if [ -z "$ac_id" ] || ! _valid_ac_id "$ac_id"; then
    # Malformed AC id: report as skipped with ac-quality finding, never silently dropped
    _malformed_label="$(printf '%s' "$_bold_text" | sed 's/[^[:alnum:]]*$//')"
    jq -nc --arg id "$_malformed_label" \
      '{"ac_id": $id, "matched": false, "test_count": 0, "status": "skipped", "skip_reason": "Malformed AC id (does not match allowlist)"}' \
      >> "$_NDJSON_AC"
    jq -nc --arg id "$_malformed_label" \
      '{"rule": "ac-quality", "severity": "warning", "blocking": false, "message": ("Malformed AC id: " + $id)}' \
      >> "$_NDJSON_FINDINGS"
    continue
  fi

  # Duplicate AC id detection: emit a non-blocking warning
  case "$_seen_ac_ids" in
    *"|$ac_id|"*)
      jq -nc --arg id "$ac_id" \
        '{"rule": "ac-quality", "severity": "warning", "blocking": false, "message": ("Duplicate AC id: " + $id)}' \
        >> "$_NDJSON_FINDINGS"
      # Skip the duplicate — the first occurrence is authoritative
      continue
      ;;
  esac
  _seen_ac_ids="${_seen_ac_ids}|${ac_id}|"

  # Edge-case detection: id contains "EC" (case-insensitive)
  is_edge=0
  case "$(printf '%s' "$ac_id" | tr '[:lower:]' '[:upper:]')" in
    *EC*) is_edge=1 ;;
  esac

  # Text after `:**` (the AC body)
  ac_text="$(printf '%s' "$line" | sed 's/^[^*]*\*\*[^*]*\*\*[[:space:]]*//')"

  # Check for Given/When/Then structure (case-insensitive) in ac_text.
  # Keywords must be followed by a space (actual clause content), not just
  # present as substrings in a compound like "Given/When/Then".
  has_gwt=0
  ac_lower="$(printf '%s' "$ac_text" | tr '[:upper:]' '[:lower:]')"
  if printf '%s' " $ac_lower" | grep -qE '[[:space:]]given[[:space:]]' 2>/dev/null && \
     printf '%s' " $ac_lower" | grep -qE '[[:space:]]when[[:space:]]' 2>/dev/null && \
     printf '%s' " $ac_lower" | grep -qE '[[:space:]]then[[:space:]]' 2>/dev/null; then
    has_gwt=1
  fi

  printf '%s\t%s\t%s\t%s\n' "$ac_id" "$is_edge" "$has_gwt" "$ac_text" >> "$_AC_LIST"
done < <(grep '^- \[[ xX]\] \*\*AC' "$STORY_FILE" 2>/dev/null || true)

AC_COUNT=0
# Count both valid ACs (in _AC_LIST) and malformed ones (in _NDJSON_AC)
while IFS= read -r _; do
  AC_COUNT=$((AC_COUNT + 1))
done < "$_AC_LIST"
_malformed_count=0
if [ -s "$_NDJSON_AC" ]; then
  while IFS= read -r _; do
    _malformed_count=$((_malformed_count + 1))
  done < "$_NDJSON_AC"
fi
AC_COUNT=$((AC_COUNT + _malformed_count))

# ---------------------------------------------------------------------------
# Discover test files
# ---------------------------------------------------------------------------

_find_tests() {
  local dir="$1" stack="$2"
  local find_cmd="find"
  local use_timeout=0
  if command -v timeout >/dev/null 2>&1; then
    find_cmd="timeout 30 find"
    use_timeout=1
  else
    printf 'ac-coverage-analyzer.sh: timeout command not found; running find uncapped (bounded by --test-dir)\n' >&2
  fi

  local find_rc=0
  case "$stack" in
    ts-dev)
      $find_cmd "$dir" -type f \( \
        -name '*.test.ts' -o -name '*.test.tsx' -o -name '*.test.js' -o -name '*.test.jsx' \
        -o -name '*.spec.ts' -o -name '*.spec.tsx' -o -name '*.spec.js' -o -name '*.spec.jsx' \
      \) 2>/dev/null || find_rc=$?
      ;;
    java-dev)
      $find_cmd "$dir" -type f -path '*/src/test/*' -name '*Test.java' 2>/dev/null || find_rc=$?
      ;;
    python-dev)
      $find_cmd "$dir" -type f \( -name 'test_*.py' -o -name '*_test.py' \) 2>/dev/null || find_rc=$?
      ;;
    go-dev)
      $find_cmd "$dir" -type f -name '*_test.go' 2>/dev/null || find_rc=$?
      ;;
    flutter-dev)
      $find_cmd "$dir" -type f -path '*/test/*' -name '*_test.dart' 2>/dev/null || find_rc=$?
      ;;
    mobile-dev)
      $find_cmd "$dir" -type f \( -name '*Tests.swift' -o -name '*Test.kt' \) 2>/dev/null || find_rc=$?
      ;;
    angular-dev)
      $find_cmd "$dir" -type f \( \
        -name '*.spec.ts' -o -name '*.spec.js' -o -name '*.test.ts' -o -name '*.test.js' \
      \) 2>/dev/null || find_rc=$?
      ;;
    bash-dev)
      $find_cmd "$dir" -type f -name '*.bats' 2>/dev/null || find_rc=$?
      ;;
    embedded-dev)
      $find_cmd "$dir" -type f \( -name '*_test.c' -o -name '*_test.cpp' \) 2>/dev/null || find_rc=$?
      ;;
    *)
      printf 'ac-coverage-analyzer.sh: unknown stack: %s (exit 1)\n' "$stack" >&2
      exit 1
      ;;
  esac
  # Exit 124 from timeout means discovery timed out — do not silently return
  # partial results as that would mark untested ACs as NOT MET.
  if [ "$find_rc" -eq 124 ] && [ "$use_timeout" -eq 1 ]; then
    printf 'ac-coverage-analyzer.sh: test discovery timed out (exit 1)\n' >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Extract test identifiers from a file
# ---------------------------------------------------------------------------

_extract_identifiers() {
  local file="$1" stack="$2"
  case "$stack" in
    ts-dev|angular-dev)
      grep -oE '(it|test|describe)[[:space:]]*\([[:space:]]*['"'"'"]([^'"'"'"]+)' "$file" 2>/dev/null \
        | sed "s/^[^'\"]*['\"]//; s/['\"]$//" || true
      ;;
    java-dev)
      grep -oE '(public|private|protected)?[[:space:]]*void[[:space:]]+(test[A-Za-z0-9_]+)' "$file" 2>/dev/null \
        | sed 's/.*[[:space:]]//' || true
      ;;
    python-dev)
      grep -oE 'def[[:space:]]+(test_[A-Za-z0-9_]+)' "$file" 2>/dev/null \
        | sed 's/^def[[:space:]]*//' || true
      ;;
    go-dev)
      grep -oE 'func[[:space:]]+(Test[A-Za-z0-9_]+)' "$file" 2>/dev/null \
        | sed 's/^func[[:space:]]*//' || true
      ;;
    flutter-dev)
      grep -oE '(test|testWidgets)[[:space:]]*\([[:space:]]*['"'"'"]([^'"'"'"]+)' "$file" 2>/dev/null \
        | sed "s/^[^'\"]*['\"]//; s/['\"]$//" || true
      ;;
    bash-dev)
      grep -oE '@test[[:space:]]+"([^"]+)"' "$file" 2>/dev/null \
        | sed 's/^@test[[:space:]]*"//; s/"$//' || true
      ;;
    mobile-dev)
      grep -oE 'func[[:space:]]+(test[A-Za-z0-9_]+)' "$file" 2>/dev/null \
        | sed 's/^func[[:space:]]*//' || true
      ;;
    embedded-dev)
      grep -oE 'void[[:space:]]+(test_[A-Za-z0-9_]+)' "$file" 2>/dev/null \
        | sed 's/^void[[:space:]]*//' || true
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Build (file, identifier) pairs
# ---------------------------------------------------------------------------

_test_files="$_WORKDIR/testfiles"

_find_tests "$TEST_DIR" "$STACK" | sort > "$_test_files"

_test_file_count=0
while IFS= read -r _; do
  _test_file_count=$((_test_file_count + 1))
done < "$_test_files"

# Warn on defaulted stack with 0 files
if [ "$_STACK_DEFAULTED" = "1" ] && [ "$_test_file_count" -eq 0 ]; then
  printf 'ac-coverage-analyzer.sh: --stack defaulted to ts-dev and found 0 test files; pass --stack explicitly\n' >&2
fi

# Build pairs: file<TAB>identifier (one per line), sorted for determinism
while IFS= read -r tf; do
  [ -n "$tf" ] || continue
  while IFS= read -r ident; do
    [ -n "$ident" ] || continue
    printf '%s\t%s\n' "$tf" "$ident"
  done < <(_extract_identifiers "$tf" "$STACK")
done < "$_test_files" | sort > "$_TEST_PAIRS"

# ---------------------------------------------------------------------------
# Fallback helper: extract content words from a phrase
# ---------------------------------------------------------------------------

_content_words() {
  # Input: phrase text on stdin; output: space-separated content words
  tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' ' ' | tr -s ' ' | sed 's/^ *//;s/ *$//' | {
    local result="" _cw_save_glob
    _cw_save_glob="$(set +o | grep noglob)" || true
    set -f
    read -r line
    for w in $line; do
      if ! _is_stopword "$w"; then
        if [ -n "$result" ]; then
          result="$result $w"
        else
          result="$w"
        fi
      fi
    done
    eval "$_cw_save_glob" 2>/dev/null || true
    printf '%s' "$result"
  }
}

# ---------------------------------------------------------------------------
# Fallback helper: split AC text into Given/When/Then phrases (positional)
# Returns 3 lines: given_words, when_words, then_words
# ---------------------------------------------------------------------------

_split_gwt() {
  local text="$1"

  # Extract given/when/then phrases using awk (positional keyword order).
  # All keyword matching uses tolower() for portability across awk
  # implementations (gawk, mawk, BSD awk).
  local result
  result="$(printf '%s' "$text" | awk '
  {
    s = $0
    sl = tolower(s)
    # Find first "given"
    gi = index(sl, "given")
    if (gi == 0) { print ""; print ""; print ""; exit }
    rest_after_given = substr(sl, gi + 5)
    orig_after_given = substr(s, gi + 5)
    # Find first "when" after given
    wi = index(rest_after_given, "when")
    if (wi == 0) { print ""; print ""; print ""; exit }
    given_phrase = substr(orig_after_given, 1, wi - 1)
    rest_after_when = substr(rest_after_given, wi + 4)
    orig_after_when = substr(orig_after_given, wi + 4)
    # Find first "then" after when
    ti = index(rest_after_when, "then")
    if (ti == 0) { print ""; print ""; print ""; exit }
    when_phrase = substr(orig_after_when, 1, ti - 1)
    then_phrase = substr(orig_after_when, ti + 4)
    print given_phrase
    print when_phrase
    print then_phrase
  }
  ')"

  local given_phrase when_phrase then_phrase
  given_phrase="$(printf '%s' "$result" | sed -n '1p')"
  when_phrase="$(printf '%s' "$result" | sed -n '2p')"
  then_phrase="$(printf '%s' "$result" | sed -n '3p')"

  local gw ww tw
  gw="$(printf '%s' "$given_phrase" | _content_words)"
  ww="$(printf '%s' "$when_phrase" | _content_words)"
  tw="$(printf '%s' "$then_phrase" | _content_words)"

  printf '%s\n%s\n%s\n' "$gw" "$ww" "$tw"
}

# ---------------------------------------------------------------------------
# Count words in a space-separated string
# ---------------------------------------------------------------------------

_word_count() {
  local count=0 w _wc_save_glob
  _wc_save_glob="$(set +o | grep noglob)" || true
  set -f
  for w in $1; do
    count=$((count + 1))
  done
  eval "$_wc_save_glob" 2>/dev/null || true
  printf '%s' "$count"
}

# ---------------------------------------------------------------------------
# Per-AC matching — single awk pass over all test pairs
#
# Phase 1 (shell): pre-compute per-AC data (O(ACs) subprocesses — bounded).
#   - Skip no-G/W/T ACs with their findings.
#   - Build primary regex and fallback phrase words for each matchable AC.
#   - Write a patterns file: ac_id<TAB>primary_re<TAB>fb_possible<TAB>is_edge<TAB>gw<TAB>ww<TAB>tw
#
# Phase 2 (one awk invocation): read patterns, then read ALL test pairs.
#   - For each pair, check attribution against the story key (bounded regex).
#   - For attributed pairs, test path and identifier against every AC primary regex.
#   - For ACs with no primary match, normalize identifiers and do fallback
#     word-pair matching entirely inside awk (no per-pair subprocesses).
#   - Collect unattributed pairs and emit their NDJSON in the END block.
#   - Output: ac_id<TAB>primary_count<TAB>fallback_count<TAB>is_edge per AC,
#     plus NDJSON lines for unattributed tests written to a separate file.
#
# Phase 3 (shell): read awk output and write results/findings.
#
# Process count is O(ACs) for shell pre-computation + O(1) for the awk pass,
# independent of the number of test pairs.
# ---------------------------------------------------------------------------

: > "$_FINDINGS"
: > "$_AC_RESULTS"
: > "$_PATTERNS"

_any_not_met=0
_all_skipped=1  # becomes 0 when at least one AC is not skipped

# Phase 1: pre-compute patterns (bounded subprocess count, one per AC)
while IFS="$(printf '\t')" read -r ac_id is_edge has_gwt ac_text; do
  [ -n "$ac_id" ] || continue

  # --- No G/W/T structure -> skipped ---
  if [ "$has_gwt" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\n' "$ac_id" "false" "0" "skipped" >> "$_AC_RESULTS"
    jq -nc --arg id "$ac_id" \
      '{"rule": "ac-quality", "severity": "warning", "blocking": false, "message": ("AC " + $id + " has no Given/When/Then structure")}' \
      >> "$_FINDINGS"
    continue
  fi

  _all_skipped=0

  # Build primary match regex with hyphen/underscore equivalence.
  ac_id_re="$(printf '%s' "$ac_id" | sed 's/-/[-_]/g')"
  primary_re="(^|[^[:alnum:]]|[a-z])${ac_id_re}([^[:alnum:]]|[A-Z]|$)"

  # Compute fallback phrase words (G/W/T content words)
  gwt_output="$(_split_gwt "$ac_text")"
  given_words="$(printf '%s' "$gwt_output" | sed -n '1p')"
  when_words="$(printf '%s' "$gwt_output" | sed -n '2p')"
  then_words="$(printf '%s' "$gwt_output" | sed -n '3p')"

  # Minimum-pair gate: each phrase must have >= 2 content words.
  gw_count="$(_word_count "$given_words")"
  ww_count="$(_word_count "$when_words")"
  tw_count="$(_word_count "$then_words")"

  _fb_possible=1
  if [ "$gw_count" -lt 2 ] || [ "$ww_count" -lt 2 ] || [ "$tw_count" -lt 2 ]; then
    _fb_possible=0
    given_words=""
    when_words=""
    then_words=""
  fi

  # patterns file: ac_id<TAB>primary_re<TAB>fb_possible<TAB>is_edge<TAB>gw<TAB>ww<TAB>tw
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ac_id" "$primary_re" "$_fb_possible" "$is_edge" "$given_words" "$when_words" "$then_words" \
    >> "$_PATTERNS"
done < "$_AC_LIST"

# Build the attribution regex for the story key (ERE).
# A story key is attributed when it is preceded by start or non-alphanumeric
# and followed by end or a non-digit.
_key_re="$(printf '%s' "$STORY_KEY" | sed 's/[][\.^$*+?(){}|/]/\\&/g')"
_attr_re="(^|[^[:alnum:]])${_key_re}([^0-9]|$)"

# Phase 2: single awk pass — attribution check, primary + fallback matching,
# and unattributed NDJSON emission.  Reads the patterns file first (ARGV[1]),
# then all test pairs (ARGV[2]).
: > "$_NDJSON_UNATTR"

awk -F '\t' \
    -v attr_re="$_attr_re" \
    -v sw_str="$_STOPWORDS_LIST" \
    -v unattr_file="$_NDJSON_UNATTR" \
'
# --- Stopwords table (single source, shared with the shell) ---
BEGIN {
  _swn = split(sw_str, _sw, " ")
  for (_i = 1; _i <= _swn; _i++) stopwords[_sw[_i]] = 1
}

# --- Helper: JSON-escape a string (backslash, double quote, control chars) ---
function json_esc(s) {
  gsub(/\\/, "\\\\", s)
  gsub(/"/, "\\\"", s)
  gsub(/\t/, "\\t", s)
  gsub(/\n/, "\\n", s)
  gsub(/\r/, "\\r", s)
  return s
}

# --- Helper: normalize an identifier (camelCase split, lowercase, _ - to space, strip stopwords) ---
# Uses gsub and substr-chunk building to avoid O(len^2) char-by-char concatenation.
function norm_ident(s,    out, i, n, start, ch, prev_lower, _words) {
  # Replace _ and - with space (gsub is O(n))
  gsub(/[_-]/, " ", s)
  # CamelCase split: insert space before uppercase preceded by lowercase.
  # Build result from substrings between transition points.
  n = length(s)
  out = ""
  start = 1
  prev_lower = 0
  for (i = 1; i <= n; i++) {
    ch = substr(s, i, 1)
    if (prev_lower && ch ~ /[A-Z]/) {
      out = out substr(s, start, i - start) " "
      start = i
    }
    prev_lower = (ch ~ /[a-z]/)
  }
  out = out substr(s, start)
  # Lowercase
  out = tolower(out)
  # Collapse spaces, strip leading/trailing
  gsub(/  +/, " ", out)
  gsub(/^ +| +$/, "", out)
  # Remove stopwords
  n = split(out, _words, " ")
  out = ""
  for (i = 1; i <= n; i++) {
    if (!(_words[i] in stopwords)) {
      out = (out == "" ? _words[i] : out " " _words[i])
    }
  }
  return out
}

# --- Helper: check if a phrase (space-separated words) has a consecutive
#     word-pair match in a normalized identifier ---
function phrase_match(phrase, nident,    n, _pw, i, pair_re) {
  n = split(phrase, _pw, " ")
  for (i = 2; i <= n; i++) {
    pair_re = _pw[i-1] "[^a-zA-Z0-9]+" _pw[i]
    if (match(nident, pair_re)) return 1
  }
  return 0
}

# Phase 1: read patterns file (first file argument)
FILENAME == ARGV[1] {
  ac_count++
  ac_ids[ac_count] = $1
  ac_res[ac_count] = $2   # primary regex
  ac_fb[ac_count] = $3    # fallback possible (0/1)
  ac_edge[ac_count] = $4  # is_edge (0/1)
  ac_gw[ac_count] = $5    # given words
  ac_ww[ac_count] = $6    # when words
  ac_tw[ac_count] = $7    # then words
  prim_count[ac_count] = 0
  fb_count[ac_count] = 0
  next
}

# Phase 2: read ALL test pairs (second file argument)
{
  tf = $1
  ident = $2
  if (tf == "") next

  # Attribution check: story key bounded by non-alnum start and non-digit end
  if (match(tf, attr_re) || match(ident, attr_re)) {
    # Attributed pair — match against AC patterns
    nident_done = 0
    nident = ""

    for (a = 1; a <= ac_count; a++) {
      # Primary match: test path and identifier against AC regex
      if (match(tf, ac_res[a]) || match(ident, ac_res[a])) {
        prim_count[a]++
      } else if (ac_fb[a] == "1" && prim_count[a] == 0) {
        # Fallback: only if no primary match yet
        if (!nident_done) {
          nident = norm_ident(ident)
          nident_done = 1
        }
        if (phrase_match(ac_gw[a], nident) &&
            phrase_match(ac_ww[a], nident) &&
            phrase_match(ac_tw[a], nident)) {
          fb_count[a]++
        }
      }
    }
  } else {
    # Unattributed pair — emit NDJSON directly (no per-pair jq subprocess)
    printf "{\"file\":\"%s\",\"identifier\":\"%s\"}\n", json_esc(tf), json_esc(ident) > unattr_file
  }
}

END {
  for (a = 1; a <= ac_count; a++) {
    print ac_ids[a] "\t" prim_count[a] "\t" fb_count[a] "\t" ac_edge[a]
  }
}
' "$_PATTERNS" "$_TEST_PAIRS" > "$_MATCH_OUT"

# Phase 3: read awk output and write results/findings.
# is_edge is carried in the awk output — no re-read of _AC_LIST needed.
while IFS="$(printf '\t')" read -r _mid _mpc _mfc _mis_edge; do
  [ -n "$_mid" ] || continue

  if [ "$_mpc" -gt 0 ]; then
    # MET
    printf '%s\t%s\t%s\t%s\n' "$_mid" "true" "$_mpc" "MET" >> "$_AC_RESULTS"
  elif [ "$_mfc" -gt 0 ]; then
    # PARTIALLY MET
    printf '%s\t%s\t%s\t%s\n' "$_mid" "true" "$_mfc" "PARTIALLY MET" >> "$_AC_RESULTS"
    jq -nc --arg id "$_mid" --argjson cnt "$_mfc" \
      '{"rule": ("ac-partial-" + $id), "severity": "warning", "blocking": false, "message": ("AC " + $id + " is PARTIALLY MET via fallback matching: " + ($cnt | tostring) + " tests")}' \
      >> "$_FINDINGS"
  else
    # NOT MET
    _any_not_met=1
    printf '%s\t%s\t%s\t%s\n' "$_mid" "false" "0" "NOT MET" >> "$_AC_RESULTS"
    if [ "$_mis_edge" -eq 1 ]; then
      jq -nc --arg id "$_mid" \
        '{"rule": ("ac-coverage-" + $id), "severity": "warning", "blocking": false, "message": ("Edge-case AC " + $id + " is NOT MET: 0 matching tests")}' \
        >> "$_FINDINGS"
    else
      _sev="warning"
      if [ "$PRIORITY" = "P0" ]; then
        _sev="critical"
      fi
      jq -nc --arg id "$_mid" --arg sev "$_sev" \
        '{"rule": ("ac-coverage-" + $id), "severity": $sev, "blocking": true, "message": ("Primary AC " + $id + " is NOT MET: 0 matching tests")}' \
        >> "$_FINDINGS"
    fi
  fi
done < "$_MATCH_OUT"

# ---------------------------------------------------------------------------
# Aggregate status and special-case findings
# ---------------------------------------------------------------------------

# Count valid (non-malformed) ACs for the all-skipped check
_valid_ac_count=0
while IFS= read -r _; do
  _valid_ac_count=$((_valid_ac_count + 1))
done < "$_AC_LIST"

if [ "$AC_COUNT" -eq 0 ]; then
  _status="failed"
  jq -nc '{"rule": "ac-coverage-empty", "severity": "critical", "blocking": true, "message": "No acceptance criteria found in story"}' >> "$_FINDINGS"
elif [ "$_valid_ac_count" -eq 0 ] && [ "$_malformed_count" -gt 0 ]; then
  # All ACs were malformed (failed id validation) — treat as all-malformed
  _status="failed"
  jq -nc '{"rule": "ac-coverage-all-malformed", "severity": "critical", "blocking": true, "message": "All acceptance criteria are malformed (no Given/When/Then structure or invalid AC id)"}' >> "$_FINDINGS"
elif [ "$_all_skipped" -eq 1 ] && [ "$_valid_ac_count" -gt 0 ]; then
  _status="failed"
  jq -nc '{"rule": "ac-coverage-all-malformed", "severity": "critical", "blocking": true, "message": "All acceptance criteria are malformed (no Given/When/Then structure)"}' >> "$_FINDINGS"
elif [ "$_any_not_met" -eq 1 ]; then
  _status="failed"
else
  _status="passed"
fi

# ---------------------------------------------------------------------------
# Build JSON output via NDJSON temp files + jq -s (no large argv payloads)
# ---------------------------------------------------------------------------

# Build ac_results NDJSON from TSV
while IFS="$(printf '\t')" read -r ac_id matched test_count status; do
  [ -n "$ac_id" ] || continue
  _matched_bool="false"
  if [ "$matched" = "true" ]; then _matched_bool="true"; fi
  if [ "$status" = "skipped" ]; then
    jq -nc --arg id "$ac_id" --argjson tc "$test_count" --arg st "$status" \
      '{"ac_id": $id, "matched": false, "test_count": $tc, "status": $st, "skip_reason": "No Given/When/Then structure"}' \
      >> "$_NDJSON_AC"
  else
    jq -nc --arg id "$ac_id" --argjson m "$_matched_bool" --argjson tc "$test_count" --arg st "$status" \
      '{"ac_id": $id, "matched": $m, "test_count": $tc, "status": $st}' \
      >> "$_NDJSON_AC"
  fi
done < "$_AC_RESULTS"

# Findings NDJSON already written to $_FINDINGS by the per-AC loop (via jq -nc)
# Copy to the NDJSON temp file
if [ -s "$_FINDINGS" ]; then
  cat "$_FINDINGS" >> "$_NDJSON_FINDINGS"
fi

# Unattributed NDJSON already written by the awk pass to $_NDJSON_UNATTR

# Ensure NDJSON files exist (may be empty)
[ -f "$_NDJSON_AC" ] || : > "$_NDJSON_AC"
[ -f "$_NDJSON_FINDINGS" ] || : > "$_NDJSON_FINDINGS"
[ -f "$_NDJSON_UNATTR" ] || : > "$_NDJSON_UNATTR"

# Assemble and sort the final check object using --slurpfile.
# Empty NDJSON files produce empty arrays via jq -s.
# No fallback: a corrupt NDJSON stream must fail the script (exit non-zero)
# so the collector writes an errored check and the resolver returns BLOCKED.
_ac_arr="$(jq -s '.' "$_NDJSON_AC")"
_find_arr="$(jq -s '.' "$_NDJSON_FINDINGS")"
_unattr_arr="$(jq -s '.' "$_NDJSON_UNATTR")"

# Write arrays to temp files for --slurpfile (avoids large argv)
_tmp_ac_arr="$_WORKDIR/ac-arr"
_tmp_find_arr="$_WORKDIR/find-arr"
_tmp_unattr_arr="$_WORKDIR/unattr-arr"

printf '%s' "$_ac_arr" > "$_tmp_ac_arr"
printf '%s' "$_find_arr" > "$_tmp_find_arr"
printf '%s' "$_unattr_arr" > "$_tmp_unattr_arr"

jq -n \
  --arg status "$_status" \
  --slurpfile findings "$_tmp_find_arr" \
  --slurpfile ac_results "$_tmp_ac_arr" \
  --slurpfile unattributed "$_tmp_unattr_arr" \
  '{
    name: "ac-coverage",
    status: $status,
    findings: ($findings[0] | sort_by(.rule, .severity)),
    ac_results: ($ac_results[0] | sort_by(.ac_id)),
    unattributed_tests: ($unattributed[0] | sort_by(.file, .identifier))
  }'

exit 0
