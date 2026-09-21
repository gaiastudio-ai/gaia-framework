#!/usr/bin/env bats
# no-leaked-ids-in-test-names.bats — lint gate for shipped test names
# AND header/section comment prose.
#
# Asserts that NO shipped bats test name or comment line contains an
# internal traceability-ID (e.g. NFR-052, AC1:, FR-401, TC-FOO-1:,
# SR-3, E99-S1, (E3-S7), etc.).  Shipped @test names and header
# comments must use plain product language.
#
# This file itself contains regex literals as grep arguments, so it
# MUST be excluded from its own scan to avoid a tautological false positive.

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

# _build_target_list — populates the `targets` array with every *.bats file
# in the tests directory EXCEPT this lint file itself.
#
# The scan is recursive. A flat glob only sees files sitting directly in the
# tests directory, so a suite one directory down was invisible to this gate —
# the same blind spot that let nested suites run in no CI job at all. Anything
# that ships as a .bats file is in scope for the gate no matter how deep it
# sits.
_build_target_list() {
  local tests_dir="$BATS_TEST_DIRNAME"
  local this_file f
  this_file="$(basename "${BATS_TEST_FILENAME}")"

  targets=()
  while IFS= read -r f; do
    [[ "$(basename "$f")" == "$this_file" ]] && continue
    targets+=("$f")
  done < <(find "$tests_dir" -type f -name '*.bats' | sort)
}

# Tech-token allowlist — encodings/standards that share the [A-Z]{2,}-[0-9]
# shape but are NOT internal traceability identifiers.
_tech_token_filter='(UTF-8|UTF-16|UTF-32|SHA-256|SHA-512|SHA-1|ISO-8601|RFC-822|BASE-64)'

# ---------------------------------------------------------------------------
# Tracked naming debt
# ---------------------------------------------------------------------------
#
# Widening the scan to the whole tests tree brought long-standing suites into
# view that were written before this gate existed and name their cases after
# internal identifiers. Those names are debt, not new leaks, and renaming them
# is its own tracked work — a rename churns every case name in the file at
# once and deserves to be reviewed on its own.
#
# The allowance is deliberately per-file and not a pattern. A file earns a
# place on this list only by already being on disk with the debt; a NEWLY
# added file, at any depth, is not on the list and so fails the gate. That
# asymmetry is the point: the list can only ever shrink.
#
# Removing an entry is the goal. When a file's case names are rewritten in
# plain product language, delete its line — the gate then holds it to the
# clean standard permanently.
_debt_paths=(
  "adapters"
  "cluster-1"
  "cluster-14"
  "cluster-7"
  "cluster-9"
  "lib"
  "scripts/review-common/action"
  "scripts/review-common/qa"
  "skills"
  "statusline"
)

# _is_debt_file PATH — true when PATH sits in a directory carrying tracked
# naming debt. Paths are relative to the tests directory. Matching is on the
# directory holding the file, so a new file dropped into a debt directory
# would inherit the allowance; the file-count assertion below is what stops
# that from becoming a loophole.
_is_debt_file() {
  local rel="${1#"${BATS_TEST_DIRNAME}/"}"
  local d
  for d in "${_debt_paths[@]}"; do
    [[ "$rel" == "$d"/* ]] && return 0
  done
  return 1
}

# Leaked-ID pattern for comment lines.  Same families as the test-name gate,
# adapted for free-form prose (no leading-quote anchor):
#   - parenthesized story key  (E<n>-S<n>)
#   - bare story key            E<n>-S<n>  (not regex shapes like E[0-9]+)
#   - requirement/decision IDs  NFR-<n>, FR-<n>, ADR-<n>, SR-<n>
#   - test-case IDs             TC-<ALPHA>-<n>
#   - discovery-board IDs       DISC-<date>-<serial>
# Carve-outs: regex [0-9] character classes, tech tokens, generic AC<n>.
_comment_id_shape='\(E[0-9]+-S[0-9]+\)|[^[a-zA-Z]E[0-9]+-S[0-9]+|^E[0-9]+-S[0-9]+|(NFR|ADR|SR)-[0-9]+[^])]|^#.*(FR-[0-9]+[^])])|TC-[A-Z]+-[A-Z0-9]+-[A-Z]*[0-9]|TC-[A-Z]+-[0-9]|DISC-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]+'

# _scan_comments FILE... — count comment lines with leaked IDs.
# Prints the match count to stdout. Applies carve-outs (regex-literal
# character classes and tech-token allowlist).
_scan_comments() {
  local comment_lines filtered matches
  comment_lines="$(grep -hn '^#' "$@" 2>/dev/null || true)"
  [[ -z "$comment_lines" ]] && { echo 0; return; }

  # Strip lines with regex character-class brackets and tech tokens.
  filtered="$(printf '%s\n' "$comment_lines" \
    | grep -vE '\[0-9\]' \
    | grep -vE "$_tech_token_filter" \
    || true)"
  [[ -z "$filtered" ]] && { echo 0; return; }

  matches="$(printf '%s\n' "$filtered" \
    | grep -E "$_comment_id_shape" || true)"

  if [[ -n "$matches" ]]; then
    printf '%s\n' "$matches" | wc -l | tr -d ' '
  else
    echo 0
  fi
}

# ---------------------------------------------------------------------------
# Gate 1: @test name strings
# ---------------------------------------------------------------------------

@test "no shipped bats test name carries an internal-ID prefix" {
  local -a targets
  _build_target_list

  if [[ ${#targets[@]} -eq 0 ]]; then
    return 0
  fi

  # Internal traceability-ID families that must never appear in a shipped
  # @test name. Each alternative below is anchored at the start of the name
  # (a leading cite prefix) OR matches the requirement-shape anywhere:
  #   - requirement/decision shape  [A-Z]{2,}-[0-9]   (NFR-052, FR-3, ADR-111, AF-29-1, SR-2, GR-VS-1)
  #   - leading requirement cite     AC<n>: / AC-EC<n>: / EC<n>:
  #   - leading acronym test-case     TC-DEJ-RUBRIC-S7: / TC-RV2-55: / AC-INT1:
  #   - story keys                    E<n>-S<n>
  #   - lowercase ids                 adr-051: / nfr-052:
  #
  # Legitimate technical tokens share the requirement shape (UTF-8, SHA-256,
  # ISO-8601, UTF-16, SHA-512, SHA-1) — they are encodings/standards, NOT
  # internal traceability identifiers, and are explicitly allowed in prose.
  # A line that matches ONLY via such a token is not a leak.
  local id_shape='[A-Z]{2,}-[0-9]|"\(?(AC[0-9]+|AC-EC[0-9]+|EC[0-9]+|AC-INT[0-9]+):|"[A-Z]{2,}(-[A-Z0-9]+)+:|[Ee][0-9]+-[Ss][0-9]+|"(adr|nfr|fr|sr)-[0-9]+:'

  # Files carrying tracked naming debt are scanned but not gated; every other
  # file — including any newly added one — is held to the clean standard.
  local -a scanned=()
  local t
  for t in "${targets[@]}"; do
    _is_debt_file "$t" || scanned+=("$t")
  done
  if [[ ${#scanned[@]} -eq 0 ]]; then
    return 0
  fi

  local matches
  matches="$(grep -hoE '@test "[^"]*"' "${scanned[@]}" 2>/dev/null \
    | grep -vE "$_tech_token_filter" \
    | grep -E "$id_shape" || true)"

  if [[ -n "$matches" ]]; then
    local count
    count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
    printf 'FAIL: %s shipped @test name(s) still carry an internal traceability-ID:\n' "$count" >&2
    printf '%s\n' "$matches" >&2
    return 1
  fi
}

@test "the naming-debt allowance covers a fixed set of files that may only shrink" {
  # The allowance is granted per directory, so on its own it would let a new
  # file be dropped into one of those directories and inherit the exemption.
  # Pinning the count closes that: adding a file to a debt directory fails
  # here until the count is updated deliberately, and the number may only be
  # revised downward as files are renamed and directories leave the list.
  local -a targets
  _build_target_list

  local n=0 t
  for t in "${targets[@]}"; do
    _is_debt_file "$t" && n=$((n + 1))
  done

  local expected=66
  if [[ "$n" -ne "$expected" ]]; then
    printf 'naming-debt file count is %s, expected %s.\n' "$n" "$expected" >&2
    printf 'If a file was renamed to plain language, lower the expected count.\n' >&2
    printf 'If a file was ADDED, do not raise it — give the new file clean names.\n' >&2
    return 1
  fi
}

@test "a newly added nested test file with a leaked name is caught" {
  # Proves the recursive scan actually reaches below the top level: a file
  # planted one directory down, outside any debt directory, must be seen.
  local nested="$BATS_TEST_DIRNAME/zz-probe-dir"
  mkdir -p "$nested"
  local fixture="$nested/planted.bats"
  printf '#!/usr/bin/env bats\n' > "$fixture"
  # The planted name is assembled at runtime so this source file never carries
  # an identifier literal of its own.
  printf '@test "%s-1: a planted name that must be caught" {\n  true\n}\n' \
    "XX" >> "$fixture"

  local -a targets
  _build_target_list
  local found=0 t
  for t in "${targets[@]}"; do
    [[ "$t" == "$fixture" ]] && found=1
  done

  # The planted file must be in scope and must NOT be treated as tracked debt.
  local is_debt=0
  _is_debt_file "$fixture" && is_debt=1

  rm -rf "$nested"

  [[ "$found" -eq 1 ]]
  [[ "$is_debt" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# Gate 2: header/section comment prose (#-prefixed lines)
# ---------------------------------------------------------------------------

@test "no shipped bats header/section comment carries a leaked internal-ID" {
  local -a targets
  _build_target_list

  if [[ ${#targets[@]} -eq 0 ]]; then
    return 0
  fi

  # Scan comment lines for the same ID families checked by _scan_comments().
  # Currently ADVISORY only — emits a count to stderr but exits 0.
  # A mass-scrub follow-up story will flip this to a hard gate once the
  # existing comment headers across ~130 bats files are cleaned up.
  local count
  count="$(_scan_comments "${targets[@]}")"

  if [[ "$count" -gt 0 ]]; then
    printf 'ADVISORY: %s shipped bats comment line(s) carry a leaked internal-ID (not yet gating)\n' "$count" >&2
  fi
}

# ---------------------------------------------------------------------------
# Negative fixture test: prove the header-comment gate actually bites
# ---------------------------------------------------------------------------

@test "header-comment lint catches a planted leaked story-key in a fixture" {
  # Generate a fixture bats file at runtime (never committed) with a leaked
  # story key in a header comment.
  # NOTE: the fixture's own `@test` line is written via printf, NOT inside the
  # heredoc — bats' test-discovery parser scans raw lines for a leading
  # `@test ` and does not understand heredocs, so a literal `@test` at column 0
  # inside a heredoc would be miscounted as a real (but never-executed) test in
  # this file, inflating the TAP plan and failing the suite on a count
  # mismatch. Keeping the token out of column-0 source avoids that.
  local fixture="$TEST_TMP/planted-leak.bats"
  cat > "$fixture" <<'FIXTURE'
#!/usr/bin/env bats
# This header leaks (E1-S2) which must be caught.

FIXTURE
  printf '@test "clean test name" {\n  true\n}\n' >> "$fixture"

  local count
  count="$(_scan_comments "$fixture")"
  # The fixture SHOULD be caught — assert non-zero match count.
  [[ "$count" -gt 0 ]]
}

@test "header-comment lint passes on clean headers and regex-literal carve-outs" {
  # Generate a fixture bats file with only clean content and legitimate
  # regex-literal character classes that share the story-key shape.
  # The fixture's `@test` line is appended via printf (see the note in the
  # planted-leak test) so it never appears at column 0 in this source file.
  local fixture="$TEST_TMP/clean-headers.bats"
  cat > "$fixture" <<'FIXTURE'
#!/usr/bin/env bats
# Clean header with no leaked IDs.
# This file tests the E[0-9]+-S[0-9]+ regex shape — NOT a leak.
# Uses SHA-256 and UTF-8 tech tokens — also not leaks.
# Generic AC1 label example — carve-out, not a leak.

FIXTURE
  printf '@test "clean test" {\n  true\n}\n' >> "$fixture"

  local count
  count="$(_scan_comments "$fixture")"
  # Clean fixture — should produce zero matches.
  [[ "$count" -eq 0 ]]
}
