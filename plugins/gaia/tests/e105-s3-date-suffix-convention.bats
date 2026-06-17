#!/usr/bin/env bats
# e105-s3-date-suffix-convention.bats — E105-S3
#
# The latest-by-date resolver for dated artifacts: glob `{base}-{YYYY-MM-DD}.md`
# in a (optionally grouped) dir, sort descending, return the newest; read-side
# fallback to an undated `{base}.md` when no dated form exists. Formalizes the
# three-class date-suffix rule (living / periodically-reassessed / per-event)
# without re-deciding or relocating the ADR-119-grouped families.
#
# Maps to AC1-AC5, TS1-TS5. Refs: ADR-127 Pillar 3, ADR-119, FR-555.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  RESOLVER="$REPO_ROOT/plugins/gaia/scripts/lib/resolve-latest-dated.sh"
  FX="$BATS_TEST_DIRNAME/fixtures/date-suffix"
  TEST_TMP="$BATS_TEST_TMPDIR/ds-$$"
  mkdir -p "$TEST_TMP"
}
teardown() { rm -rf "$TEST_TMP" 2>/dev/null || true; }

# ---------- AC4 / TS4: resolve latest dated artifact ----------

@test "resolver returns the newest dated artifact (glob + sort)" {
  run bash "$RESOLVER" --dir "$FX/dated/nfr-assessment" --base nfr-assessment
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq 'nfr-assessment-2026-05-26\.md$' \
    || { echo "expected newest dated (2026-05-26), got: $output" >&2; false; }
  ! echo "$output" | grep -Eq '2026-04-01|2026-05-10' \
    || { echo "must not return an older dated file, got: $output" >&2; false; }
}

# ---------- AC4 / TS5: undated-legacy read-side fallback ----------

@test "resolver falls back to the undated legacy file when no dated form exists" {
  run bash "$RESOLVER" --dir "$FX/undated" --base nfr-assessment
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq 'nfr-assessment\.md$' \
    || { echo "expected undated fallback, got: $output" >&2; false; }
}

@test "a dated file wins over an undated sibling for the same base" {
  d="$TEST_TMP/both"; mkdir -p "$d"
  printf 'x\n' > "$d/nfr-assessment.md"
  printf 'x\n' > "$d/nfr-assessment-2026-05-20.md"
  run bash "$RESOLVER" --dir "$d" --base nfr-assessment
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq 'nfr-assessment-2026-05-20\.md$' \
    || { echo "dated must win over undated when both exist, got: $output" >&2; false; }
}

@test "not-found (neither dated nor undated) exits non-zero with actionable error" {
  d="$TEST_TMP/empty"; mkdir -p "$d"
  run bash "$RESOLVER" --dir "$d" --base nfr-assessment
  [ "$status" -ne 0 ]
  echo "$output" | grep -Eiq 'not found|no .*artifact' \
    || { echo "expected an actionable not-found error, got: $output" >&2; false; }
}

# ---------- robustness ----------

@test "missing --base fails with usage error" {
  run bash "$RESOLVER" --dir "$FX/undated"
  [ "$status" -ne 0 ]
}

@test "--help prints usage and exits 0" {
  run bash "$RESOLVER" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eiq 'latest|dated'
}

# ---------- AC1 / AC2 / AC3: convention documented + producers + conformance ----------

@test "Pillar 3 documents the three-class date-suffix rule" {
  # ADR-127 is a PROJECT-ROOT artifact (.gaia/artifacts/planning-artifacts/), which
  # is NOT part of the gaia-public checkout that CI runs against. Per
  # feedback_no_project_root_artifact_assert_in_gaia_public_bats, this test must
  # SKIP when the ADR is absent (CI) rather than hard-fail on an absolute path.
  ADR="$REPO_ROOT/../.gaia/artifacts/planning-artifacts/architecture/27-adr-127-consolidated-artifact-layout.md"
  [ -f "$ADR" ] || skip "ADR-127 is a project-root artifact not present in the gaia-public checkout"
  # the three classes named in the date-suffix rule (living / periodically re-assessed / per-event)
  grep -Eiq 'living' "$ADR" && grep -Eiq 'periodically re-?assess' "$ADR" && grep -Eiq 'per-event' "$ADR" \
    || { echo "ADR-127 should name the three date-suffix classes" >&2; grep -in 'date-suffix\|living\|per-event' "$ADR" | head >&2; false; }
}

@test "gaia-nfr + gaia-perf-testing producers write the dated + grouped form" {
  NFR="$REPO_ROOT/plugins/gaia/skills/gaia-nfr/SKILL.md"
  PERF="$REPO_ROOT/plugins/gaia/skills/gaia-perf-testing/SKILL.md"
  [ -f "$NFR" ] && [ -f "$PERF" ]
  # nfr-assessment: dated + grouped under a named subdir
  grep -Eq 'nfr-assessment/nfr-assessment-\{?(date|YYYY-MM-DD)' "$NFR" \
    || { echo "gaia-nfr SKILL.md should write the dated + grouped nfr-assessment form" >&2; grep -n 'nfr-assessment' "$NFR" | head >&2; false; }
  # performance-test-plan: dated + grouped under a named subdir (W1 parity)
  grep -Eq 'performance-test-plan/performance-test-plan-\{?(date|YYYY-MM-DD)' "$PERF" \
    || { echo "gaia-perf-testing SKILL.md should write the dated + grouped performance-test-plan form" >&2; grep -n 'performance-test-plan' "$PERF" | head >&2; false; }
}

@test "retrospective producer writes the grouped+dated subdir; adversarial is dated (grouping caller-side) — confirm, no relocation" {
  ADV="$REPO_ROOT/plugins/gaia/skills/gaia-adversarial/SKILL.md"
  RETRO="$REPO_ROOT/plugins/gaia/skills/gaia-retro/SKILL.md"
  [ -f "$ADV" ] && [ -f "$RETRO" ]
  # retrospective: the grouped subdir + dated form is in-skill (E102 / ADR-119) — assert it directly
  grep -Eq 'retrospective/retrospective-\{?(sprint_id)?[^}]*\}?-\{?(date|YYYY-MM-DD)' "$RETRO" \
    || grep -Eq 'retrospective/retrospective-' "$RETRO" \
    || { echo "gaia-retro should write the grouped retrospective/ subdir form" >&2; grep -n 'retrospective' "$RETRO" | head >&2; false; }
  # adversarial: the producer writes the DATED form (adversarial-review-{target}-{date}.md); the
  # planning-artifacts/adversarial/ subdir grouping is caller-supplied per ADR-119/E102-S2 (W2 note).
  # Confirm-only: this story does NOT relocate either family.
  grep -Eq 'adversarial-review-\{?target\}?-\{?(date|YYYY-MM-DD)' "$ADV" \
    || { echo "gaia-adversarial should write the dated adversarial-review form (grouping is caller-side)" >&2; grep -n 'adversarial-review' "$ADV" | head >&2; false; }
}
