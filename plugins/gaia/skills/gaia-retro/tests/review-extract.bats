#!/usr/bin/env bats
# E55-S12 — review-extract.sh empty-array set -u defensive guard.
#
# Verifies AC4, AC5, AC6, AC8: review-extract.sh exits 0 cleanly with the
# canonical AC-EC5 no-results note when zero review artifacts match, AND
# preserves the happy-path verdict block byte-identically when artifacts
# are present.

setup() {
  SKILL_DIR="${BATS_TEST_DIRNAME}/.."
  SCRIPT="${SKILL_DIR}/scripts/review-extract.sh"
  TMPDIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "review-extract.sh exists and is executable" {
  [ -x "$SCRIPT" ]
}

@test "AC4+AC8: zero artifacts under set -u exits 0 with canonical no-results note" {
  # Empty impl-dir — no review artifacts at all.
  run bash "$SCRIPT" --impl-dir "$TMPDIR" --sprint-id sprint-XX
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '_no review artifacts for sprint sprint-XX_ (empty findings)'
  # stderr must be free of unbound-variable error.
  ! printf '%s\n' "$stderr" | grep -q 'unbound variable'
}

@test "AC4: impl-dir populated with non-matching files still exits 0 cleanly" {
  # Stash a non-matching .md file — no review-* prefix.
  printf '# noise\n' > "$TMPDIR/random.md"
  run bash "$SCRIPT" --impl-dir "$TMPDIR" --sprint-id sprint-XX
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '_no review artifacts for sprint sprint-XX_'
}

@test "AC4: impl-dir populated with wrong-sprint files exits 0 cleanly" {
  cat >"$TMPDIR/code-review-Esrc-S1.md" <<EOF
---
sprint_id: sprint-OTHER
---
**Verdict:** PASSED
EOF
  run bash "$SCRIPT" --impl-dir "$TMPDIR" --sprint-id sprint-XX
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '_no review artifacts for sprint sprint-XX_'
}

@test "AC6: happy path with one matching artifact emits verdict block" {
  cat >"$TMPDIR/code-review-Esrc-S1.md" <<EOF
---
sprint_id: sprint-XX
---
**Verdict:** PASSED
EOF
  run bash "$SCRIPT" --impl-dir "$TMPDIR" --sprint-id sprint-XX
  [ "$status" -eq 0 ]
  # Family-name derivation: strip `-sprint-*\.md`. Without a sprint suffix the
  # filename is preserved verbatim. Either form is accepted by the verdict
  # column extraction.
  printf '%s\n' "$output" | grep -qE '\| code-review-Esrc-S1(\.md)? \| PASSED \|'
}

@test "AC4: missing impl-dir exits 0 with impl-dir-missing note (legacy behavior)" {
  run bash "$SCRIPT" --impl-dir "$TMPDIR/does-not-exist" --sprint-id sprint-XX
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'no review artifacts for sprint sprint-XX (impl-dir missing)'
}
