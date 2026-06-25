#!/usr/bin/env bats
# backlog-select-lint-detail-block-deps.bats
#
# Validates that backlog-select-lint.sh correctly extracts hard dependencies
# from the bold-label detail-block form (- **Depends on:** ...) used for
# non-materialized stories in epics-and-stories.md.  The lint must union
# three extraction paths: pipe-table roster row, story-file frontmatter,
# AND the bold-label detail block -- with no silent-empty fallback.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LINT="$REPO_ROOT/plugins/gaia/scripts/backlog-select-lint.sh"
  FX="$BATS_TEST_DIRNAME/fixtures/backlog-selection"
  DETAIL_EPICS="$FX/epics-detail-block-deps.md"
}

# ---------- bold-label dep, open, not co-selected -> HARD-BLOCK ----------

@test "detail-block-only candidate with open hard dep is HARD-BLOCKED (AC1)" {
  # E900-S10 depends on E900-S1 via bold-label block only (no pipe-table row).
  # E900-S1 is NOT in --done or --candidates -> must block.
  run bash "$LINT" --epics "$DETAIL_EPICS" --candidates "E900-S10" --done "" --json
  [ "$status" -eq 2 ] \
    || { echo "expected exit 2 (HARD-BLOCKED), got $status: $output" >&2; false; }
  echo "$output" | jq -e '.blocked | length > 0' >/dev/null \
    || { echo "blocked array should be non-empty, got: $output" >&2; false; }
  echo "$output" | jq -e '.blocked[] | select(.candidate=="E900-S10" and .unmet_dep=="E900-S1")' >/dev/null \
    || { echo "expected E900-S10 blocked on E900-S1, got: $output" >&2; false; }
}

# ---------- bold-label dep, satisfied via --done -> no block ----------

@test "detail-block dep satisfied via --done passes cleanly (AC1)" {
  # E900-S10 depends on E900-S1; E900-S1 is in --done -> not blocked.
  run bash "$LINT" --epics "$DETAIL_EPICS" --candidates "E900-S10" --done "E900-S1" --json
  [ "$status" -eq 0 ] \
    || { echo "dep satisfied via --done should pass, got $status: $output" >&2; false; }
  echo "$output" | jq -e '.blocked == []' >/dev/null \
    || { echo "blocked should be empty, got: $output" >&2; false; }
}

# ---------- bold-label dep, satisfied via co-selection -> no block ----------

@test "detail-block dep satisfied via co-selection passes cleanly (AC1)" {
  run bash "$LINT" --epics "$DETAIL_EPICS" --candidates "E900-S1,E900-S10" --done "" --json
  [ "$status" -eq 0 ] \
    || { echo "dep co-selected should pass, got $status: $output" >&2; false; }
  echo "$output" | jq -e '.blocked == []' >/dev/null
}

# ---------- soft-dep tail in bold-label never blocks (AC3) ----------

@test "detail-block soft-dep tail does not block on the soft target (AC3)" {
  # E900-S11: hard on E900-S1 (co-selected), soft on E902-S2 (absent).
  # Only the hard dep matters; the soft dep must not block.
  run bash "$LINT" --epics "$DETAIL_EPICS" --candidates "E900-S1,E900-S11" --done "" --json
  [ "$status" -eq 0 ] \
    || { echo "soft dep on absent E902-S2 must not block, got $status: $output" >&2; false; }
  echo "$output" | jq -e '.blocked == []' >/dev/null \
    || { echo "expected no blocks, got: $output" >&2; false; }
}

@test "detail-block soft-dep: hard part still blocks when open (AC2)" {
  # E900-S11: hard on E900-S1. S1 NOT co-selected or done -> hard dep blocks.
  run bash "$LINT" --epics "$DETAIL_EPICS" --candidates "E900-S11" --done "" --json
  [ "$status" -eq 2 ] \
    || { echo "hard dep E900-S1 is open, should block, got $status: $output" >&2; false; }
  echo "$output" | jq -e '.blocked[] | select(.unmet_dep=="E900-S1")' >/dev/null \
    || { echo "expected block on E900-S1, got: $output" >&2; false; }
}

# ---------- parenthetical annotation stripped (AC3) ----------

@test "detail-block parenthetical annotation is stripped, bare key blocks when open (AC2)" {
  # E900-S12: depends on "E900-S1 (Step 4 hook)". S1 NOT co-selected -> blocks.
  run bash "$LINT" --epics "$DETAIL_EPICS" --candidates "E900-S12" --done "" --json
  [ "$status" -eq 2 ] \
    || { echo "parenthetical-annotated dep should block when open, got $status: $output" >&2; false; }
  echo "$output" | jq -e '.blocked[] | select(.unmet_dep=="E900-S1")' >/dev/null \
    || { echo "expected block on bare key E900-S1, got: $output" >&2; false; }
}

@test "detail-block parenthetical dep satisfied via co-selection passes (AC3)" {
  run bash "$LINT" --epics "$DETAIL_EPICS" --candidates "E900-S1,E900-S12" --done "" --json
  [ "$status" -eq 0 ] \
    || { echo "annotated dep satisfied by co-selection should pass, got $status: $output" >&2; false; }
  echo "$output" | jq -e '.blocked == []' >/dev/null
}

# ---------- none / empty list -> no block ----------

@test "detail-block 'none' dep yields no dependencies (AC1)" {
  run bash "$LINT" --epics "$DETAIL_EPICS" --candidates "E900-S13" --done "" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.blocked == []' >/dev/null
}

@test "detail-block empty list dep yields no dependencies (AC1)" {
  run bash "$LINT" --epics "$DETAIL_EPICS" --candidates "E900-S15" --done "" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.blocked == []' >/dev/null
}

# ---------- comma-separated deps in bold-label ----------

@test "detail-block comma-separated deps: both open -> both block (AC2)" {
  # E900-S14 depends on E900-S1, E901-S9. Neither is done or co-selected.
  run bash "$LINT" --epics "$DETAIL_EPICS" --candidates "E900-S14" --done "" --json
  [ "$status" -eq 2 ] \
    || { echo "two open deps should block, got $status: $output" >&2; false; }
  echo "$output" | jq -e '[.blocked[] | .unmet_dep] | sort == ["E900-S1","E901-S9"]' >/dev/null \
    || { echo "expected blocks on E900-S1 and E901-S9, got: $output" >&2; false; }
}

@test "detail-block comma-separated deps: one satisfied, one open -> still blocks (AC2)" {
  # E900-S14 depends on E900-S1 (done) + E901-S9 (open).
  run bash "$LINT" --epics "$DETAIL_EPICS" --candidates "E900-S14" --done "E900-S1" --json
  [ "$status" -eq 2 ] \
    || { echo "one open dep should still block, got $status: $output" >&2; false; }
  echo "$output" | jq -e '.blocked[] | select(.unmet_dep=="E901-S9")' >/dev/null
}

# ---------- pipe-table regression: existing behavior preserved ----------

@test "pipe-table dep still blocks when open (regression) (AC1)" {
  # E900-S1 is in the pipe table with "none" deps, so it passes alone.
  # Use the original fixture which has pipe-table rows.
  run bash "$LINT" --epics "$BATS_TEST_DIRNAME/fixtures/backlog-selection/epics-and-stories.md" \
    --candidates "E900-S3" --done "" --json
  [ "$status" -eq 2 ] \
    || { echo "pipe-table dep should still block, got $status: $output" >&2; false; }
  echo "$output" | jq -e '.blocked[] | select(.unmet_dep=="E901-S9")' >/dev/null
}
