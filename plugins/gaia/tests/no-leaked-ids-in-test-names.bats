#!/usr/bin/env bats
# no-leaked-ids-in-test-names.bats — lint gate for shipped test names.
#
# Asserts that NO shipped bats test name contains an internal traceability-ID
# prefix (e.g. NFR-052:, AC1:, FR-401:, TC-FOO-1:, SR-3:, etc.).
# Shipped @test names must use plain product language.
#
# This file itself contains the regex literal as a grep argument, so it
# MUST be excluded from its own scan to avoid a tautological false positive.

load 'test_helper.bash'

setup() {
  common_setup
}

teardown() {
  common_teardown
}

@test "no shipped bats test name carries an internal-ID prefix" {
  # Scan every *.bats file in the tests directory EXCEPT this lint file.
  local tests_dir="$BATS_TEST_DIRNAME"
  local this_file
  this_file="$(basename "${BATS_TEST_FILENAME}")"

  # Build the file list, excluding this lint file.
  local -a targets=()
  for f in "$tests_dir"/*.bats; do
    [[ "$(basename "$f")" == "$this_file" ]] && continue
    targets+=("$f")
  done

  # If no other bats files exist (shouldn't happen), pass vacuously.
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
  local matches
  matches="$(grep -hoE '@test "[^"]*"' "${targets[@]}" 2>/dev/null \
    | grep -vE '(UTF-8|UTF-16|UTF-32|SHA-256|SHA-512|SHA-1|ISO-8601|RFC-822|BASE-64)' \
    | grep -E "$id_shape" || true)"

  if [[ -n "$matches" ]]; then
    local count
    count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
    printf 'FAIL: %s shipped @test name(s) still carry an internal traceability-ID:\n' "$count" >&2
    printf '%s\n' "$matches" >&2
    return 1
  fi
}
