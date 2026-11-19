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
# Stopwords list (used by fallback matching)
# Stopwords are stripped so single-word phrases like "user" or "submit" do not
# produce false PARTIALLY MET matches against unrelated test identifiers.
# "when", "then", "given" are included because the G/W/T keywords themselves
# carry no semantic value once the phrase has been split.
# ---------------------------------------------------------------------------

_STOPWORDS=" a an the is are was were to of in on with for that it and or but not when then given should must can will be "

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
_TMPDIR="${TMPDIR:-/tmp}"
_AC_LIST="$(mktemp "$_TMPDIR/aclist-XXXXXX")"
_TEST_PAIRS="$(mktemp "$_TMPDIR/testpairs-XXXXXX")"
_UNATTR="$(mktemp "$_TMPDIR/unattr-XXXXXX")"
_FINDINGS="$(mktemp "$_TMPDIR/findings-XXXXXX")"
_AC_RESULTS="$(mktemp "$_TMPDIR/acresults-XXXXXX")"
_NDJSON_AC="$(mktemp "$_TMPDIR/ndjson-ac-XXXXXX")"
_NDJSON_FINDINGS="$(mktemp "$_TMPDIR/ndjson-find-XXXXXX")"
_NDJSON_UNATTR="$(mktemp "$_TMPDIR/ndjson-unattr-XXXXXX")"
trap 'rm -f "$_AC_LIST" "$_TEST_PAIRS" "$_UNATTR" "$_FINDINGS" "$_AC_RESULTS" "$_NDJSON_AC" "$_NDJSON_FINDINGS" "$_NDJSON_UNATTR"' EXIT

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

# Escape ERE metacharacters in a string
_ere_escape() {
  printf '%s' "$1" | sed 's/[][\.^$*+?(){}|/]/\\&/g'
}

# Extract ACs — accept both unchecked (- [ ]) and checked (- [x]/- [X]) forms
while IFS= read -r line; do
  # Extract AC id: token between first ** pair, strip trailing non-alphanumerics
  ac_id="$(printf '%s' "$line" | sed -n 's/^- \[[ xX]\] \*\*\([^*]*\)\*\*.*/\1/p' | sed 's/[^[:alnum:]]*$//')"
  [ -n "$ac_id" ] || continue

  # Validate AC id against allowlist
  if ! _valid_ac_id "$ac_id"; then
    # Malformed AC id: report as skipped with ac-quality finding, never silently dropped
    jq -nc --arg id "$ac_id" \
      '{"ac_id": $id, "matched": false, "test_count": 0, "status": "skipped", "skip_reason": "Malformed AC id (does not match allowlist)"}' \
      >> "$_NDJSON_AC"
    jq -nc --arg id "$ac_id" \
      '{"rule": "ac-quality", "severity": "warning", "blocking": false, "message": ("Malformed AC id: " + $id)}' \
      >> "$_NDJSON_FINDINGS"
    continue
  fi

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
# Build (file, identifier) pairs and separate attributed vs unattributed
# ---------------------------------------------------------------------------

_test_files="$(mktemp "$_TMPDIR/testfiles-XXXXXX")"
trap 'rm -f "$_AC_LIST" "$_TEST_PAIRS" "$_UNATTR" "$_FINDINGS" "$_AC_RESULTS" "$_test_files" "$_NDJSON_AC" "$_NDJSON_FINDINGS" "$_NDJSON_UNATTR"' EXIT

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

# Separate attributed vs unattributed.
# Attribution requires the story key to be bounded: preceded by a non-alnum or
# start, and followed by a non-digit or end.  This prevents a shorter key from
# matching a path/identifier that contains a longer key with the same prefix.
: > "$_UNATTR"
_ATTR_PAIRS="$(mktemp "$_TMPDIR/attrpairs-XXXXXX")"
trap 'rm -f "$_AC_LIST" "$_TEST_PAIRS" "$_UNATTR" "$_FINDINGS" "$_AC_RESULTS" "$_test_files" "$_ATTR_PAIRS" "$_NDJSON_AC" "$_NDJSON_FINDINGS" "$_NDJSON_UNATTR"' EXIT

_key_re="$(printf '%s' "$STORY_KEY" | sed 's/[][\.^$*+?(){}|/]/\\&/g')"
_attr_re="(^|[^[:alnum:]])${_key_re}([^0-9]|$)"

while IFS="$(printf '\t')" read -r tf ident; do
  [ -n "$tf" ] || continue
  if printf '%s' "$tf" | grep -qE "$_attr_re" 2>/dev/null || \
     printf '%s' "$ident" | grep -qE "$_attr_re" 2>/dev/null; then
    printf '%s\t%s\n' "$tf" "$ident" >> "$_ATTR_PAIRS"
  else
    printf '%s\t%s\n' "$tf" "$ident" >> "$_UNATTR"
  fi
done < "$_TEST_PAIRS"

# ---------------------------------------------------------------------------
# Fallback helper: extract content words from a phrase
# ---------------------------------------------------------------------------

_content_words() {
  # Input: phrase text on stdin; output: space-separated content words
  tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' ' ' | tr -s ' ' | sed 's/^ *//;s/ *$//' | {
    local result=""
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
    printf '%s' "$result"
  }
}

# ---------------------------------------------------------------------------
# Fallback helper: normalize an identifier for phrase matching
# Applies camelCase split, lowercasing, separator normalization, and
# stopword removal — same normalization as _content_words applies to phrases.
# ---------------------------------------------------------------------------

_normalize_identifier() {
  # Insert space at lower->upper transitions, lowercase, _ and - -> space,
  # then remove stopwords for symmetric matching with AC phrases.
  printf '%s' "$1" \
    | sed 's/\([a-z]\)\([A-Z]\)/\1 \2/g' \
    | tr '[:upper:]' '[:lower:]' \
    | tr '_-' '  ' \
    | tr -s ' ' | {
    local result="" w
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
    printf '%s' "$result"
  }
}

# ---------------------------------------------------------------------------
# Fallback helper: check if a phrase matches in a normalized identifier
# A phrase matches when at least one consecutive content-word pair (w1, w2)
# matches grep -qE "${w1}[^[:alnum:]]+${w2}" in the normalized identifier.
# ---------------------------------------------------------------------------

_phrase_matches_in_ident() {
  local phrase_words="$1" norm_ident="$2"
  # phrase_words is space-separated content words
  local prev="" w
  for w in $phrase_words; do
    if [ -n "$prev" ]; then
      if printf '%s' "$norm_ident" | grep -qE "${prev}[^[:alnum:]]+${w}" 2>/dev/null; then
        return 0
      fi
    fi
    prev="$w"
  done
  return 1
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
  local count=0 w
  for w in $1; do
    count=$((count + 1))
  done
  printf '%s' "$count"
}

# ---------------------------------------------------------------------------
# Per-AC matching
# ---------------------------------------------------------------------------

: > "$_FINDINGS"
: > "$_AC_RESULTS"

_any_not_met=0
_all_skipped=1  # becomes 0 when at least one AC is not skipped

while IFS="$(printf '\t')" read -r ac_id is_edge has_gwt ac_text; do
  [ -n "$ac_id" ] || continue

  # --- No G/W/T structure -> skipped ---
  if [ "$has_gwt" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\n' "$ac_id" "false" "0" "skipped" >> "$_AC_RESULTS"
    # ac-quality finding (built safely via jq)
    jq -nc --arg id "$ac_id" \
      '{"rule": "ac-quality", "severity": "warning", "blocking": false, "message": ("AC " + $id + " has no Given/When/Then structure")}' \
      >> "$_FINDINGS"
    continue
  fi

  _all_skipped=0

  # --- Build primary match regex ---
  # Hyphen/underscore equivalence: AC-EC3 matches AC_EC3 in test identifiers.
  # Word-boundary anchoring prevents AC1 from matching AC10 or AC1b — the regex
  # requires a non-alphanumeric (or casing transition) on both sides.
  # Escape ERE metacharacters first so ids like AC1.2 match literally.
  ac_id_escaped="$(_ere_escape "$ac_id")"
  ac_id_re="$(printf '%s' "$ac_id_escaped" | sed 's/\\-/[-_]/g; s/-/[-_]/g')"
  primary_re="(^|[^[:alnum:]]|[a-z])${ac_id_re}([^[:alnum:]]|[A-Z]|$)"

  # --- Primary match against attributed pairs ---
  primary_count=0
  while IFS="$(printf '\t')" read -r tf ident; do
    [ -n "$tf" ] || continue
    matched=0
    if printf '%s' "$tf" | grep -qE "$primary_re" 2>/dev/null; then
      matched=1
    elif printf '%s' "$ident" | grep -qE "$primary_re" 2>/dev/null; then
      matched=1
    fi
    if [ "$matched" -eq 1 ]; then
      primary_count=$((primary_count + 1))
    fi
  done < "$_ATTR_PAIRS"

  if [ "$primary_count" -gt 0 ]; then
    # MET
    printf '%s\t%s\t%s\t%s\n' "$ac_id" "true" "$primary_count" "MET" >> "$_AC_RESULTS"
    continue
  fi

  # --- Fallback match (only with G/W/T) ---
  gwt_output="$(_split_gwt "$ac_text")"
  given_words="$(printf '%s' "$gwt_output" | sed -n '1p')"
  when_words="$(printf '%s' "$gwt_output" | sed -n '2p')"
  then_words="$(printf '%s' "$gwt_output" | sed -n '3p')"

  # Minimum-pair gate: each G/W/T phrase must have >= 2 content words.
  # Single-word phrases like "user" or "save" match too broadly in test
  # identifiers and would inflate false PARTIALLY MET results.
  gw_count="$(_word_count "$given_words")"
  ww_count="$(_word_count "$when_words")"
  tw_count="$(_word_count "$then_words")"

  fallback_possible=1
  if [ "$gw_count" -lt 2 ] || [ "$ww_count" -lt 2 ] || [ "$tw_count" -lt 2 ]; then
    fallback_possible=0
  fi

  fallback_count=0
  if [ "$fallback_possible" -eq 1 ]; then
    while IFS="$(printf '\t')" read -r tf ident; do
      [ -n "$tf" ] || continue
      norm="$(_normalize_identifier "$ident")"
      # All three phrases must match in this one identifier
      if _phrase_matches_in_ident "$given_words" "$norm" && \
         _phrase_matches_in_ident "$when_words" "$norm" && \
         _phrase_matches_in_ident "$then_words" "$norm"; then
        fallback_count=$((fallback_count + 1))
      fi
    done < "$_ATTR_PAIRS"
  fi

  if [ "$fallback_count" -gt 0 ]; then
    # PARTIALLY MET
    printf '%s\t%s\t%s\t%s\n' "$ac_id" "true" "$fallback_count" "PARTIALLY MET" >> "$_AC_RESULTS"
    # Non-blocking finding (built safely via jq)
    jq -nc --arg id "$ac_id" --argjson cnt "$fallback_count" \
      '{"rule": ("ac-partial-" + $id), "severity": "warning", "blocking": false, "message": ("AC " + $id + " is PARTIALLY MET via fallback matching: " + ($cnt | tostring) + " tests")}' \
      >> "$_FINDINGS"
    continue
  fi

  # --- NOT MET ---
  _any_not_met=1
  printf '%s\t%s\t%s\t%s\n' "$ac_id" "false" "0" "NOT MET" >> "$_AC_RESULTS"

  if [ "$is_edge" -eq 1 ]; then
    # Edge-case NOT MET: non-blocking, warning
    jq -nc --arg id "$ac_id" \
      '{"rule": ("ac-coverage-" + $id), "severity": "warning", "blocking": false, "message": ("Edge-case AC " + $id + " is NOT MET: 0 matching tests")}' \
      >> "$_FINDINGS"
  else
    # Primary NOT MET: blocking true, severity based on priority
    _sev="warning"
    if [ "$PRIORITY" = "P0" ]; then
      _sev="critical"
    fi
    jq -nc --arg id "$ac_id" --arg sev "$_sev" \
      '{"rule": ("ac-coverage-" + $id), "severity": $sev, "blocking": true, "message": ("Primary AC " + $id + " is NOT MET: 0 matching tests")}' \
      >> "$_FINDINGS"
  fi

done < "$_AC_LIST"

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

# Build unattributed_tests NDJSON
while IFS="$(printf '\t')" read -r tf ident; do
  [ -n "$tf" ] || continue
  jq -nc --arg f "$tf" --arg i "$ident" '{"file": $f, "identifier": $i}' >> "$_NDJSON_UNATTR"
done < "$_UNATTR"

# Ensure NDJSON files exist (may be empty)
[ -f "$_NDJSON_AC" ] || : > "$_NDJSON_AC"
[ -f "$_NDJSON_FINDINGS" ] || : > "$_NDJSON_FINDINGS"
[ -f "$_NDJSON_UNATTR" ] || : > "$_NDJSON_UNATTR"

# Assemble and sort the final check object using --slurpfile
# Empty NDJSON files produce empty arrays via jq -s.
_ac_arr="$(jq -s '.' "$_NDJSON_AC" 2>/dev/null || echo '[]')"
_find_arr="$(jq -s '.' "$_NDJSON_FINDINGS" 2>/dev/null || echo '[]')"
_unattr_arr="$(jq -s '.' "$_NDJSON_UNATTR" 2>/dev/null || echo '[]')"

# Write arrays to temp files for --slurpfile (avoids large argv)
_tmp_ac_arr="$(mktemp "$_TMPDIR/ac-arr-XXXXXX")"
_tmp_find_arr="$(mktemp "$_TMPDIR/find-arr-XXXXXX")"
_tmp_unattr_arr="$(mktemp "$_TMPDIR/unattr-arr-XXXXXX")"
trap 'rm -f "$_AC_LIST" "$_TEST_PAIRS" "$_UNATTR" "$_FINDINGS" "$_AC_RESULTS" "$_test_files" "$_ATTR_PAIRS" "$_NDJSON_AC" "$_NDJSON_FINDINGS" "$_NDJSON_UNATTR" "$_tmp_ac_arr" "$_tmp_find_arr" "$_tmp_unattr_arr"' EXIT

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
