#!/usr/bin/env bats
# e105-s4-single-source-review-paths.bats — E105-S4
#
# (1) Single-source review-report path resolution: review-summary-gen.sh's
#     CANONICAL_REPORT_RELPATHS table reflects the per-story reviews/ subdir
#     (E105-S1) with the flat implementation-artifacts/ form as read-side
#     fallback, FR-402 type-first names preserved.
# (2) AI-99 verdict-line fix: /gaia-retro review-extract.sh extract_verdict
#     tolerates ALL real-world verdict-line shapes so reports never parse
#     UNKNOWN when a verdict is present:
#       **Verdict:** V   |   **Verdict: V**   |   ## Verdict: V   |   Verdict: V
#       |   **Verdict: X -> V**  (arrow-override: POST-arrow value wins)
#
# Maps to AC1-AC5, AC-INT1. Refs: ADR-127 §7.4, FR-402, FR-556, retro AI-99, Test02 #2.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  EXTRACT="$REPO_ROOT/plugins/gaia/skills/gaia-retro/scripts/review-extract.sh"
  SUMMARY="$REPO_ROOT/plugins/gaia/scripts/review-summary-gen.sh"
  TABLE="$REPO_ROOT/plugins/gaia/skills/gaia-run-all-reviews/SKILL.md"
  FX="$BATS_TEST_DIRNAME/fixtures/review-verdict-shapes"
  TEST_TMP="$BATS_TEST_TMPDIR/ssr-$$"; mkdir -p "$TEST_TMP"
}
teardown() { rm -rf "$TEST_TMP" 2>/dev/null || true; }

# helper: source review-extract.sh and call extract_verdict on a file
verdict_of() { bash -c '
  source "'"$EXTRACT"'" 2>/dev/null || true
  extract_verdict "'"$1"'"
' 2>/dev/null; }

# ---------- AC3 / TS3: verdict-line parse tolerates ALL real shapes ----------

@test "**Verdict:** V (colon-outside-bold) parses to the value" {
  [ "$(verdict_of "$FX/shape-bold-colon-outside.md")" = "PASSED" ]
}

@test "**Verdict: V** (colon-inside-bold, the dominant form) parses to the value" {
  [ "$(verdict_of "$FX/shape-bold-colon-inside.md")" = "PASSED" ] \
    || { echo "got: $(verdict_of "$FX/shape-bold-colon-inside.md")" >&2; false; }
}

@test "## Verdict: V (H2 heading form, e.g. ) parses to the value" {
  [ "$(verdict_of "$FX/shape-heading.md")" = "PASSED" ] \
    || { echo "got: $(verdict_of "$FX/shape-heading.md")" >&2; false; }
}

@test "plain Verdict: V parses to the value" {
  [ "$(verdict_of "$FX/shape-plain.md")" = "PASSED" ] \
    || { echo "got: $(verdict_of "$FX/shape-plain.md")" >&2; false; }
}

@test "arrow-override **Verdict: X -> V** takes the POST-arrow value" {
  v="$(verdict_of "$FX/shape-arrow-override.md")"
  [ "$v" = "PASSED" ] \
    || { echo "arrow-override should yield the post-arrow PASSED, got: $v" >&2; false; }
}

@test "a value-vocabulary variant (REQUEST_CHANGES) parses (not UNKNOWN)" {
  v="$(verdict_of "$FX/shape-vocab-request-changes.md")"
  [ "$v" = "REQUEST_CHANGES" ] \
    || { echo "expected REQUEST_CHANGES, got: $v" >&2; false; }
}

@test "a genuinely missing verdict still yields UNKNOWN" {
  [ "$(verdict_of "$FX/shape-missing.md")" = "UNKNOWN" ]
}

@test "F1: gate-row annotation (APPROVE -> Review Gate row = PASSED) keeps the BASE verdict, not the post-arrow word" {
  # Val F1: the arrow here is a gate-row mapping annotation, NOT a verdict
  # override — the verdict is APPROVE, not the annotation's trailing PASSED.
  v="$(verdict_of "$FX/shape-gate-row-annotation.md")"
  [ "$v" = "APPROVE" ] \
    || { echo "gate-row annotation should keep APPROVE (base), got: $v" >&2; false; }
}

# ---------- AC3 regression: the original **Verdict:** parse still works ----------

@test "regression: pre-existing **Verdict:** V branch is preserved (no regression)" {
  d="$TEST_TMP/r"; mkdir -p "$d"
  printf '**Verdict:** FAILED\n' > "$d/code-review-EX-S1.md"
  [ "$(verdict_of "$d/code-review-EX-S1.md")" = "FAILED" ]
}

# ---------- AC3 / TS3: round-trip — extract over a dir of mixed-shape reports ----------

@test "review-extract over a dir of mixed-shape reports yields real verdicts, no UNKNOWN" {
  d="$TEST_TMP/mix"; mkdir -p "$d"
  cp "$FX/shape-bold-colon-inside.md" "$d/code-review-EX-S1.md"
  cp "$FX/shape-heading.md" "$d/qa-tests-EX-S1.md"
  cp "$FX/shape-plain.md" "$d/security-review-EX-S1.md"
  for f in "$d"/*.md; do
    v="$(verdict_of "$f")"
    [ "$v" != "UNKNOWN" ] || { echo "report $f parsed UNKNOWN (AI-99 regression)" >&2; false; }
  done
}

# ---------- AC1 / AC2 / AC4: single-source canonical table reflects reviews/ ----------

@test "gaia-run-all-reviews SKILL.md is the declared single-source path table" {
  [ -f "$TABLE" ]
  grep -Eiq 'canonical (report )?(path )?table|single source' "$TABLE" \
    || { echo "gaia-run-all-reviews SKILL.md should declare the canonical path table as single source" >&2; false; }
}

@test "the canonical table references the per-story reviews/ subdir ( layout)" {
  [ -f "$TABLE" ]
  grep -Eq 'reviews/' "$TABLE" \
    || { echo "canonical table should reference the per-story reviews/ subdir" >&2; grep -n 'review.*\.md' "$TABLE" | head >&2; false; }
}

@test "review-summary-gen.sh resolves report paths reflecting reviews/ (no flat-only divergence)" {
  [ -f "$SUMMARY" ]
  # the relpath table must include the per-story reviews/ home (E105-S1)
  grep -Eq 'reviews/' "$SUMMARY" \
    || { echo "review-summary-gen.sh CANONICAL_REPORT_RELPATHS should include the reviews/ home" >&2; grep -n 'RELPATH\|reviews\|<type>-' "$SUMMARY" | head >&2; false; }
}

@test "review reports keep type-FIRST names (no {key}-<type> reversal)" {
  # the table must use <type>-{key}.md, never {key}-<type>.md (check-deps glob collision)
  grep -Eq 'code-review-' "$TABLE" \
    || { echo "canonical table should use FR-402 type-first names (code-review-{key}.md)" >&2; false; }
  ! grep -Eq '\{key\}-code-review|\{story_key\}-code-review' "$TABLE" \
    || { echo "must not use the reversed {key}-<type> form" >&2; false; }
}
