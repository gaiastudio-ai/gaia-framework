#!/usr/bin/env bats
# discovery-leak-gate.bats — CI gate ensuring no concrete discovery-board
# identifier leaks into published source.
#
# The discovery-board mints identifiers with a date-serial shape. These
# identifiers are private project bookkeeping and must never appear as
# concrete literals in shipped files. Load-bearing regex shapes (character
# classes like [0-9]) and format strings (printf patterns) are carved out.

load 'test_helper.bash'

setup() {
  common_setup
}

teardown() {
  common_teardown
}

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

# Concrete discovery-id pattern: a date-serial literal (year-month-day
# followed by a serial number).  The regex requires four literal digits
# for the year, two for month, two for day, and one-or-more for the
# serial — so a regex character-class shape like DISC-[0-9]{4}-... does
# NOT match (it contains brackets, not digits).
_DISC_CONCRETE='DISC-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9]+'

# Shared include list for grep — single source so the main scan and the
# diagnostic re-grep can never drift.  Covers every text extension present
# in the published tree (scripts, tests, docs, configs, and source files).
_DISC_INCLUDES=(
  --include='*.sh'   --include='*.bats'
  --include='*.md'   --include='*.html'
  --include='*.yaml' --include='*.yml'
  --include='*.json' --include='*.txt' --include='*.csv'
  --include='*.py'   --include='*.js'  --include='*.ts'
)

# _scan_published_tree — find concrete discovery-id leaks in the published
# source tree. Returns the count of offending lines via stdout.
# Carve-outs:
#   1. Lines containing regex character-class brackets ([0-9]) — these are
#      load-bearing regex literals, not concrete identifiers.
#   2. The tests/fixtures/ directory — exempt fixture tree.
#   3. The .git/ directory.
#   4. Binary files.
_scan_published_tree() {
  local root="${1:-$BATS_TEST_DIRNAME/..}"
  local repo_root
  repo_root="$(cd "$root" && git rev-parse --show-toplevel 2>/dev/null || echo "$root")"

  local raw
  raw="$(grep -rin "${_DISC_INCLUDES[@]}" \
              -E "$_DISC_CONCRETE" "$repo_root" 2>/dev/null \
    | grep -v '\.git/' \
    | grep -v 'tests/fixtures/' \
    || true)"

  [[ -z "$raw" ]] && { echo 0; return; }

  # Carve-out: lines with regex character-class brackets are load-bearing.
  local filtered
  filtered="$(printf '%s\n' "$raw" \
    | grep -vE '\[0-9\]' \
    || true)"

  [[ -z "$filtered" ]] && { echo 0; return; }

  # Carve-out: printf format strings (DISC-%s-%d) are not concrete.
  filtered="$(printf '%s\n' "$filtered" \
    | grep -viE 'DISC-%[sd]' \
    || true)"

  [[ -z "$filtered" ]] && { echo 0; return; }

  printf '%s\n' "$filtered" | wc -l | tr -d ' '
}

# ---------------------------------------------------------------------------
# Gate: no concrete discovery-id in the published tree (AC1)
# ---------------------------------------------------------------------------

@test "no concrete discovery-board identifier leaks into published source (AC1)" {
  local count
  count="$(_scan_published_tree)"

  if [[ "$count" -gt 0 ]]; then
    printf 'FAIL: %s line(s) contain a concrete discovery-board identifier in published source\n' "$count" >&2
    # Re-run to show the offending lines on stderr for diagnosis.
    local root="$BATS_TEST_DIRNAME/.."
    local repo_root
    repo_root="$(cd "$root" && git rev-parse --show-toplevel 2>/dev/null || echo "$root")"
    grep -rin "${_DISC_INCLUDES[@]}" \
             -E "$_DISC_CONCRETE" "$repo_root" 2>/dev/null \
      | grep -v '\.git/' \
      | grep -v 'tests/fixtures/' \
      | grep -vE '\[0-9\]' \
      | grep -viE 'DISC-%[sd]' \
      >&2 || true
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Positive-violation fixture: planted id trips the gate (AC1)
# ---------------------------------------------------------------------------

@test "discovery-id leak gate catches a planted concrete identifier in a fixture (AC1)" {
  # Create a fixture file OUTSIDE the exempt tests/fixtures/ tree to
  # simulate a leak.  This file lives in TEST_TMP (cleaned up by teardown).
  local fixture="$TEST_TMP/leaked-disc-id.md"
  # The planted identifier uses printf to avoid this source file itself
  # containing a concrete literal that would trip the gate.
  printf '# This prose contains a leaked identifier: DISC-%s-%s-%s-%s\n' \
    "2026" "06" "23" "1" > "$fixture"

  local raw
  raw="$(grep -iE "$_DISC_CONCRETE" "$fixture" 2>/dev/null || true)"
  [[ -n "$raw" ]]

  # After carve-outs, at least one line must remain (proving detection works).
  local filtered
  filtered="$(printf '%s\n' "$raw" \
    | grep -vE '\[0-9\]' \
    | grep -viE 'DISC-%[sd]' \
    || true)"
  [[ -n "$filtered" ]]
}

# ---------------------------------------------------------------------------
# Carve-out proof: regex-literal lines are NOT flagged (AC1)
# ---------------------------------------------------------------------------

@test "discovery-id gate does not flag load-bearing regex literals (AC1)" {
  # Build a MIXED fixture line that DOES match the concrete DISC pattern
  # AND contains the [0-9] regex literal.  This forces the full filter
  # pipeline to run (the grep -vE '\[0-9\]' carve-out must exempt it).
  # The concrete literal is assembled via printf to keep this source clean.
  local fixture="$TEST_TMP/regex-carveout.sh"
  printf '#!/usr/bin/env bash\n' > "$fixture"
  printf '# DISC-%s-%s-%s-%s matches the [0-9] class\n' \
    "2026" "06" "23" "1" >> "$fixture"

  local raw
  raw="$(grep -iE "$_DISC_CONCRETE" "$fixture" 2>/dev/null || true)"
  # The concrete literal IS present — raw must be non-empty.
  [[ -n "$raw" ]]

  # The [0-9] carve-out filter must remove it.
  local filtered
  filtered="$(printf '%s\n' "$raw" | grep -vE '\[0-9\]' || true)"
  [[ -z "$filtered" ]]
}

# ---------------------------------------------------------------------------
# Carve-out proof: printf format strings are NOT flagged (AC1)
# ---------------------------------------------------------------------------

@test "discovery-id gate does not flag printf format strings (AC1)" {
  # Build a MIXED fixture line that DOES match the concrete DISC pattern
  # AND contains a DISC-%s format token.  This forces the full filter
  # pipeline to run (the grep -viE 'DISC-%[sd]' carve-out must exempt it).
  local fixture="$TEST_TMP/printf-carveout.sh"
  printf '#!/usr/bin/env bash\n' > "$fixture"
  printf "printf 'DISC-%%s-%%d' but also DISC-%s-%s-%s-%s\n" \
    "2026" "06" "23" "1" >> "$fixture"

  local raw
  raw="$(grep -iE "$_DISC_CONCRETE" "$fixture" 2>/dev/null || true)"
  # The concrete literal IS present — raw must be non-empty.
  [[ -n "$raw" ]]

  # First carve-out ([0-9]) does NOT apply — no brackets in this line.
  local after_regex_filter
  after_regex_filter="$(printf '%s\n' "$raw" | grep -vE '\[0-9\]' || true)"
  [[ -n "$after_regex_filter" ]]

  # Second carve-out (DISC-%s/%d format) MUST remove it.
  local filtered
  filtered="$(printf '%s\n' "$after_regex_filter" | grep -viE 'DISC-%[sd]' || true)"
  [[ -z "$filtered" ]]
}

# ---------------------------------------------------------------------------
# Integration: @test name gate in no-leaked-ids catches DISC shape (AC1)
# ---------------------------------------------------------------------------

@test "no-leaked-ids comment gate catches a planted discovery-id in a header comment (AC1)" {
  # Build a fixture bats file with a DISC-id in a header comment.
  local fixture="$TEST_TMP/disc-leak-comment.bats"
  printf '#!/usr/bin/env bats\n' > "$fixture"
  printf '# This header references DISC-%s-%s-%s-%s which is a leak.\n' \
    "2026" "06" "23" "1" >> "$fixture"
  printf '@test "clean test" {\n  true\n}\n' >> "$fixture"

  # Import the _scan_comments helper and _comment_id_shape from the
  # no-leaked-ids gate.
  local gate_file="$BATS_TEST_DIRNAME/no-leaked-ids-in-test-names.bats"
  # Source the variable and helper — they are defined at file scope in the
  # gate file, so we extract them.
  local _comment_id_shape
  _comment_id_shape="$(grep '^_comment_id_shape=' "$gate_file" | head -1 | sed "s/^_comment_id_shape='//" | sed "s/'$//")"

  local comment_lines filtered matches
  comment_lines="$(grep -hn '^#' "$fixture" 2>/dev/null || true)"
  [[ -n "$comment_lines" ]] || return 1

  local _tech_token_filter='(UTF-8|UTF-16|UTF-32|SHA-256|SHA-512|SHA-1|ISO-8601|RFC-822|BASE-64)'
  filtered="$(printf '%s\n' "$comment_lines" \
    | grep -vE '\[0-9\]' \
    | grep -vE "$_tech_token_filter" \
    || true)"
  [[ -n "$filtered" ]] || return 1

  matches="$(printf '%s\n' "$filtered" \
    | grep -E "$_comment_id_shape" || true)"
  [[ -n "$matches" ]]
}

@test "no-leaked-ids test-name gate catches a planted discovery-id in an at-test name (AC1)" {
  # Build a fixture bats file with a DISC-id in the @test name.
  # The planted id is assembled via printf to avoid a concrete literal here.
  local fixture="$TEST_TMP/disc-leak-testname.bats"
  printf '#!/usr/bin/env bats\n' > "$fixture"
  printf '@test "verify DISC-%s-%s-%s-%s handling" {\n  true\n}\n' \
    "2026" "06" "23" "1" >> "$fixture"

  # The id_shape regex from the no-leaked-ids gate should match.
  # We replicate the gate's test-name extraction + filtering here.
  local id_shape='[A-Z]{2,}-[0-9]'
  local _tech_token_filter='(UTF-8|UTF-16|UTF-32|SHA-256|SHA-512|SHA-1|ISO-8601|RFC-822|BASE-64)'

  local matches
  matches="$(grep -hoE '@test "[^"]*"' "$fixture" 2>/dev/null \
    | grep -vE "$_tech_token_filter" \
    | grep -E "$id_shape" || true)"

  [[ -n "$matches" ]]
}
