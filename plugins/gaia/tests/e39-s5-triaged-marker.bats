#!/usr/bin/env bats
# e39-s5-triaged-marker.bats — TC-STCL-4 (CRITICAL): the TRIAGED marker the
# triage phase WRITES is byte-identical to the pattern the merged tech-debt
# phase READS. Guards against the Unicode-arrow vs ASCII-arrow homoglyph drift
# that would silently break the merge's target-validation handoff.

setup() {
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  MARKER_LIB="$PLUGIN/skills/gaia-triage-findings/scripts/triaged-marker.sh"
  . "$MARKER_LIB"
}

# TC-STCL-4 — the writer's marker uses the canonical ASCII '->' (bytes 2d 3e),
# never the Unicode arrow (bytes e2 86 92).
@test "TC-STCL-4: written marker uses ASCII '->' not the Unicode arrow" {
  local m; m="$(triaged_marker E12-S3)"
  [ "$m" = "[TRIAGED -> E12-S3]" ]
  # Byte assertion: the arrow is 2d 3e, and e2 86 92 (→) never appears.
  run bash -c "printf '%s' '$m' | xxd -p"
  [[ "$output" == *"2d3e"* ]]      # ASCII '->'
  [[ "$output" != *"e28692"* ]]    # NOT the Unicode arrow
}

# TC-STCL-4b — the reader's regex matches a marker the writer produced, and
# extracts the target key. This is the byte-equality handoff: writer output
# feeds reader pattern with zero glyph drift.
@test "TC-STCL-4b: reader regex matches the writer's marker and captures the key" {
  local line; line="finding text $(triaged_marker E40-S7) trailing"
  run bash -c "printf '%s\n' '$line' | grep -E '$(triaged_match_regex)'"
  [ "$status" -eq 0 ]
  # Capture the key via sed using the same regex.
  key="$(printf '%s\n' "$line" | sed -E 's/.*'"$(triaged_match_regex)"'.*/\1/')"
  [ "$key" = "E40-S7" ]
}

# TC-STCL-4c — a Unicode-arrow marker (the retired form) is NOT matched by the
# reader regex, proving the two forms are not silently interchangeable and the
# canonical form is enforced.
@test "TC-STCL-4c: the retired Unicode-arrow form is not matched" {
  # Construct the retired form explicitly with the Unicode arrow.
  local retired
  retired="$(printf '[TRIAGED \xe2\x86\x92 E1-S1]')"
  run bash -c "printf '%s\n' '$retired' | grep -E '$(triaged_match_regex)'"
  [ "$status" -ne 0 ]
}
