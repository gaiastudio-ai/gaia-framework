#!/usr/bin/env bats
# e107-s2-sprint-plan-backlog-selection.bats — E107-S2
#
# sprint-plan selects from the backlog (epics-and-stories.md ROSTER columns)
# without requiring pre-materialized ready-for-dev files. backlog-select-lint.sh
# is the net-new column-sourced dependency lint: it parses the pipe-delimited
# roster row (| Story | Title | Size | Points | Risk | Depends on | Blocks |),
# extracts HARD deps from the `Depends on` cell (ignoring soft-deps and
# parenthetical annotations), and HARD-BLOCKS a candidate whose hard-dep target
# is neither in --done nor co-selected in --candidates.
#
# Refs: ADR-128, Test02 F-9, E106-S3, E107-S1, FR-558. Val W1/W2: parse the
# roster row (not the bold-label **Depends on:** block); soft-deps don't block.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LINT="$REPO_ROOT/plugins/gaia/scripts/backlog-select-lint.sh"
  PLAN_SKILL="$REPO_ROOT/plugins/gaia/skills/gaia-sprint-plan/SKILL.md"
  FX="$BATS_TEST_DIRNAME/fixtures/backlog-selection"
  EPICS="$FX/epics-and-stories.md"
}

# ---------- AC1 / TS1: enumerate backlog candidates from columns (no files) ----------

@test "AC1/TS1: lint enumerates backlog candidates from the roster columns (no story files)" {
  run bash "$LINT" --epics "$EPICS" --candidates "E900-S1,E900-S2" --done "" --json
  [ "$status" -eq 0 ] \
    || { echo "lint should enumerate column candidates with no files, got $status: $output" >&2; false; }
  echo "$output" | jq -e '.candidates | index("E900-S1")' >/dev/null
}

# ---------- AC2 / TS2: dependency lint reads the Depends on COLUMN ----------

@test "AC2/TS2: lint reads Depends on from the roster column, not the bold-label block" {
  # E900-S2 deps E900-S1 (column). With E900-S1 co-selected, S2 is satisfied.
  run bash "$LINT" --epics "$EPICS" --candidates "E900-S1,E900-S2" --done "" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.blocked == []' >/dev/null \
    || { echo "S2's column dep E900-S1 is co-selected -> not blocked, got:" >&2; echo "$output" >&2; false; }
}

# ---------- AC3 / TS3: cross-sprint dep hard-block ----------

@test "AC3/TS3: cross-sprint dep (target not done, not co-selected) HARD-BLOCKS with a message" {
  # E900-S3 deps E901-S9 which is neither done nor co-selected.
  run bash "$LINT" --epics "$EPICS" --candidates "E900-S3" --done ""
  [ "$status" -ne 0 ] \
    || { echo "E900-S3 with unmet cross-sprint dep E901-S9 should hard-block, got status $status" >&2; echo "$output" >&2; false; }
  echo "$output" | grep -Eq 'E901-S9' \
    || { echo "hard-block message should name the unmet dep E901-S9, got:" >&2; echo "$output" >&2; false; }
  echo "$output" | grep -Eiq 'block|unmet|not (done|selected)'
}

# ---------- AC3b / TS4: co-selected dep allowed ----------

@test "AC3b/TS4: dep target co-selected in the same sprint is allowed (intra-sprint ordering)" {
  run bash "$LINT" --epics "$EPICS" --candidates "E900-S1,E900-S2,E900-S3" --done "E901-S9" --json
  [ "$status" -eq 0 ] \
    || { echo "with E901-S9 done + S1 co-selected, nothing should block, got:" >&2; echo "$output" >&2; false; }
  echo "$output" | jq -e '.blocked == []' >/dev/null
}

@test "AC3: a hard dep satisfied by --done (not co-selected) is allowed" {
  run bash "$LINT" --epics "$EPICS" --candidates "E900-S2" --done "E900-S1" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.blocked == []' >/dev/null
}

# ---------- Val W2: soft-deps + parenthetical annotations do NOT hard-block ----------

@test "W2: a soft dep (E900-S1; soft on E902-S2) does not hard-block on the soft target" {
  # E900-S4 hard-deps E900-S1 (co-selected) + softly E902-S2 (absent). Soft must not block.
  run bash "$LINT" --epics "$EPICS" --candidates "E900-S1,E900-S4" --done "" --json
  [ "$status" -eq 0 ] \
    || { echo "soft dep on absent E902-S2 must not block, got:" >&2; echo "$output" >&2; false; }
  echo "$output" | jq -e '.blocked == []' >/dev/null
}

@test "W2: a parenthetical-annotated dep (E900-S1 (Step 4 hook)) parses the bare key" {
  # E900-S5 hard-deps E900-S1 with a parenthetical annotation; with S1 co-selected, allowed.
  run bash "$LINT" --epics "$EPICS" --candidates "E900-S1,E900-S5" --done "" --json
  [ "$status" -eq 0 ] \
    || { echo "parenthetical-annotated dep should parse the bare key E900-S1, got:" >&2; echo "$output" >&2; false; }
  echo "$output" | jq -e '.blocked == []' >/dev/null
}

@test "W2: a 'none' dep cell yields no dependencies (E900-S1 is selectable alone)" {
  run bash "$LINT" --epics "$EPICS" --candidates "E900-S1" --done "" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.blocked == []' >/dev/null
}

@test "W1: the Depends on column index is sniffed from the header (robust to column reorder)" {
  # reordered fixture: Depends on is column 3, not 6. The lint must still find
  # E900-S2's unmet hard dep E901-S9 via the header sniff (not a positional $7).
  run bash "$LINT" --epics "$FX/epics-and-stories-reordered.md" --candidates "E900-S2" --done ""
  [ "$status" -ne 0 ] \
    || { echo "reordered-column dep must still hard-block via header sniff, got: $output" >&2; false; }
  echo "$output" | grep -Eq 'E901-S9'
}

# ---------- robustness ----------

@test "missing --epics fails with usage error" {
  run bash "$LINT" --candidates "E900-S1"
  [ "$status" -ne 0 ]
}

@test "--help prints usage and exits 0" {
  run bash "$LINT" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eiq 'backlog|lint|depends'
}

# ---------- AC4 / TS5: SKILL.md commits as planned + inverts selectability ----------

@test "AC1/AC4: sprint-plan SKILL.md selects from backlog (no ready-for-dev-file precondition) + commits planned" {
  [ -f "$PLAN_SKILL" ]
  # the inverted contract: backlog selection from epics-and-stories columns
  grep -Eiq 'backlog|epics-and-stories.*column|backlog-select-lint' "$PLAN_SKILL" \
    || { echo "SKILL.md should document backlog selection from epics-and-stories columns" >&2; false; }
  # committed as planned (E107-S1), not active
  grep -Eiq 'status:?[[:space:]]*planned|state:?[[:space:]]*planned|planned sprint' "$PLAN_SKILL" \
    || { echo "SKILL.md should commit the sprint as planned (E107-S1)" >&2; false; }
}

@test "I2 backward-compat: SKILL.md still resolves materialized ready-for-dev files when present" {
  [ -f "$PLAN_SKILL" ]
  # the files-present path (resolve-story-file.sh) must remain reachable
  grep -Eq 'resolve-story-file|ready-for-dev' "$PLAN_SKILL" \
    || { echo "SKILL.md should still handle the materialized files-present path" >&2; false; }
}
