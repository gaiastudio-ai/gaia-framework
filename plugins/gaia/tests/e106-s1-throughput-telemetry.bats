#!/usr/bin/env bats
# e106-s1-throughput-telemetry.bats — E106-S1
#
# Covers the throughput-telemetry derivation layer + /gaia-history read-only skill.
# Maps to story Test Scenarios TS1-TS7 and acceptance criteria AC1-AC6 + AC-INT1.
#
# Derivation is from .gaia/memory/lifecycle-events.jsonl `state_transition` events:
# wall-clock per story is DERIVED by differencing consecutive transition timestamps
# (there is NO duration field on events). Per-sprint medians (minutes/story,
# minutes/point) resist outliers. Read-only /gaia-history surfaces trend.
#
# Refs: AC1-AC6, AC-INT1, TS1-TS7, ADR-128, ADR-042, FR-549, FR-550

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/plugins/gaia/scripts/throughput-telemetry.sh"
  HISTORY="$REPO_ROOT/plugins/gaia/skills/gaia-history/scripts/history-render.sh"
  FIXTURE_DIR="$BATS_TEST_DIRNAME/fixtures/throughput-telemetry"
  EVENTS="$FIXTURE_DIR/lifecycle-events.jsonl"
  SPRINT_YAML="$FIXTURE_DIR/sprint-status.yaml"
  ARCHIVE_DIR="$FIXTURE_DIR/sprint-archive"
  RETROS_DIR="$FIXTURE_DIR/retros"

  TEST_TMP="$BATS_TEST_TMPDIR/tt-$$"
  mkdir -p "$TEST_TMP"
}

teardown() {
  rm -rf "$TEST_TMP" 2>/dev/null || true
}

# ---------- AC1 / TS1: per-story wall-clock + per-sprint median ----------

@test "AC1/TS1: derives median minutes/story from differenced transition timestamps" {
  run bash "$SCRIPT" --events "$EVENTS" --sprint-yaml "$SPRINT_YAML"
  [ "$status" -eq 0 ]
  # E900-S1 = 10:00->10:40 = 40, E900-S2 = 11:00->12:00 = 60 ; median{40,60} = 50
  echo "$output" | grep -Eq 'median_minutes_per_story:[[:space:]]*50' \
    || { echo "expected median_minutes_per_story: 50, got:" >&2; echo "$output" >&2; false; }
}

@test "AC1/TS1: derives median minutes/point joining story points" {
  run bash "$SCRIPT" --events "$EVENTS" --sprint-yaml "$SPRINT_YAML"
  [ "$status" -eq 0 ]
  # E900-S1 = 40min/4pt = 10 ; E900-S2 = 60min/2pt = 30 ; median{10,30} = 20
  echo "$output" | grep -Eq 'median_minutes_per_point:[[:space:]]*20' \
    || { echo "expected median_minutes_per_point: 20, got:" >&2; echo "$output" >&2; false; }
}

@test "AC1/TS1: emits per-story wall-clock for a clean multi-transition story" {
  run bash "$SCRIPT" --events "$EVENTS" --sprint-yaml "$SPRINT_YAML"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq 'E900-S1.*40'
}

# ---------- AC2 / TS2: rework loop, no double-count ----------

@test "AC2/TS2: rework loop yields a single coherent wall-clock (no double-count)" {
  run bash "$SCRIPT" --events "$EVENTS" --sprint-yaml "$SPRINT_YAML"
  [ "$status" -eq 0 ]
  # E900-S2 has review->in-progress->review loop; total span 11:00->12:00 = 60 (not 30+20+10 summed twice)
  echo "$output" | grep -Eq 'E900-S2.*60'
}

# ---------- AC3 / TS3: missing/partial pair -> skip + note ----------

@test "AC3/TS3: single-transition story is skipped with a recorded note, not crash" {
  run bash "$SCRIPT" --events "$EVENTS" --sprint-yaml "$SPRINT_YAML"
  [ "$status" -eq 0 ]
  # E900-S3 has only review->done (1 transition) -> skipped with note
  echo "$output" | grep -Eq 'E900-S3.*(skip|note|insufficient)'
}

@test "AC3/TS3: skipped story does not count as zero in the median" {
  run bash "$SCRIPT" --events "$EVENTS" --sprint-yaml "$SPRINT_YAML"
  [ "$status" -eq 0 ]
  # if E900-S3 counted as 0, median{0,40,60} = 40, not 50
  echo "$output" | grep -Eq 'median_minutes_per_story:[[:space:]]*50'
}

# ---------- AC4 / TS4: pre-log story excluded from median ----------

@test "AC4/TS4: story with no events is excluded from the median" {
  run bash "$SCRIPT" --events "$EVENTS" --sprint-yaml "$SPRINT_YAML"
  [ "$status" -eq 0 ]
  # E900-S4 (5pt) has zero events; if counted as 0 the medians would shift
  echo "$output" | grep -Eq 'median_minutes_per_story:[[:space:]]*50'
  echo "$output" | grep -Eq 'median_minutes_per_point:[[:space:]]*20'
}

# ---------- TS5: single-transition handling (distinct from AC3 skip) ----------

@test "TS5: single-transition story is NOT counted in the per-story median set" {
  run bash "$SCRIPT" --events "$EVENTS" --sprint-yaml "$SPRINT_YAML"
  [ "$status" -eq 0 ]
  # E900-S3 (single transition) must not contribute a wall-clock figure:
  # the only counted stories are S1 (40) and S2 (60). Assert S3 carries no
  # numeric wall-clock on its line (skip/note marker instead).
  s3_line=$(echo "$output" | grep -E 'E900-S3' || true)
  [ -n "$s3_line" ]
  ! echo "$s3_line" | grep -Eq '\b(40|60|[0-9]+ min)\b' \
    || { echo "E900-S3 should carry no wall-clock, got: $s3_line" >&2; false; }
}

# ---------- --json contract ----------

@test "json output is valid JSON with median fields" {
  run bash "$SCRIPT" --events "$EVENTS" --sprint-yaml "$SPRINT_YAML" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.median_minutes_per_story == 50' >/dev/null
  echo "$output" | jq -e '.median_minutes_per_point == 20' >/dev/null
}

# ---------- robustness ----------

@test "empty events file does not crash (exit 0, no median)" {
  : > "$TEST_TMP/empty.jsonl"
  run bash "$SCRIPT" --events "$TEST_TMP/empty.jsonl" --sprint-yaml "$SPRINT_YAML"
  [ "$status" -eq 0 ]
}

@test "missing events file fails loudly (nonzero exit)" {
  run bash "$SCRIPT" --events "$TEST_TMP/nope.jsonl" --sprint-yaml "$SPRINT_YAML"
  [ "$status" -ne 0 ]
}

@test "--help prints usage and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq 'throughput-telemetry'
}

# ---------- AC5: /gaia-history renders trend, accuracy, recurring findings ----------

@test "AC5: history-render surfaces velocity trend across closed sprints" {
  run bash "$HISTORY" --archive-dir "$ARCHIVE_DIR" --retros-dir "$RETROS_DIR" \
    --events "$EVENTS"
  [ "$status" -eq 0 ]
  # three archived sprints (898=30pt, 899=45pt, 900=14pt) must appear in a trend section
  echo "$output" | grep -Eiq 'velocity trend' \
    || { echo "expected a velocity trend section, got:" >&2; echo "$output" >&2; false; }
  echo "$output" | grep -Eq 'sprint-898' && echo "$output" | grep -Eq 'sprint-900'
}

@test "AC5: history-render surfaces estimate-accuracy (estimated vs measured)" {
  run bash "$HISTORY" --archive-dir "$ARCHIVE_DIR" --retros-dir "$RETROS_DIR" \
    --events "$EVENTS"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eiq 'estimate.accuracy|estimated vs measured|measured' \
    || { echo "expected an estimate-accuracy section, got:" >&2; echo "$output" >&2; false; }
}

@test "AC5: history-render surfaces recurring-finding patterns from retros" {
  run bash "$HISTORY" --archive-dir "$ARCHIVE_DIR" --retros-dir "$RETROS_DIR" \
    --events "$EVENTS"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eiq 'recurring' \
    || { echo "expected a recurring-finding section, got:" >&2; echo "$output" >&2; false; }
  # 'CI checkout flake' appears in BOTH retro fixtures -> must be flagged as recurring
  echo "$output" | grep -Eiq 'checkout' \
    || { echo "expected the recurring 'checkout flake' theme, got:" >&2; echo "$output" >&2; false; }
}

# ---------- AC6 / TS6: /gaia-history read-only contract ----------

@test "AC6/TS6: throughput-telemetry.sh writes nothing (read-only)" {
  # Broadened guard: snapshot the whole REPO_ROOT working tree state + the
  # project .gaia/ runtime dirs, not just the fixture dir (TDD WARNING bats:123).
  before=$(cd "$REPO_ROOT" && git status --porcelain=v1 2>/dev/null | sort)
  fbefore=$(find "$FIXTURE_DIR" -type f -exec shasum -a 256 {} \; | sort | shasum -a 256 | awk '{print $1}')
  run bash "$SCRIPT" --events "$EVENTS" --sprint-yaml "$SPRINT_YAML"
  [ "$status" -eq 0 ]
  after=$(cd "$REPO_ROOT" && git status --porcelain=v1 2>/dev/null | sort)
  fafter=$(find "$FIXTURE_DIR" -type f -exec shasum -a 256 {} \; | sort | shasum -a 256 | awk '{print $1}')
  [ "$fbefore" = "$fafter" ] || { echo "fixture files mutated" >&2; false; }
  [ "$before" = "$after" ] || { echo "working tree mutated:" >&2; diff <(echo "$before") <(echo "$after") >&2; false; }
}

@test "AC6/TS6: history-render writes nothing (read-only)" {
  before=$(cd "$REPO_ROOT" && git status --porcelain=v1 2>/dev/null | sort)
  run bash "$HISTORY" --archive-dir "$ARCHIVE_DIR" --retros-dir "$RETROS_DIR" --events "$EVENTS"
  [ "$status" -eq 0 ]
  after=$(cd "$REPO_ROOT" && git status --porcelain=v1 2>/dev/null | sort)
  [ "$before" = "$after" ] || { echo "history-render mutated working tree" >&2; false; }
}

@test "AC6/TS6: gaia-history skill is read-only (allowed-tools has no Write/Edit)" {
  SKILL="$REPO_ROOT/plugins/gaia/skills/gaia-history/SKILL.md"
  [ -f "$SKILL" ]
  # allowed-tools must not grant Write or Edit
  run grep -E '^allowed-tools:' "$SKILL"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -Eq '(Write|Edit|NotebookEdit)'
}

# ---------- AC-INT1 / TS7: integration round-trip ----------

@test "AC-INT1/TS7: gaia-history skill + scripts present (read-then-render dispatch)" {
  [ -f "$REPO_ROOT/plugins/gaia/skills/gaia-history/SKILL.md" ]
  [ -x "$REPO_ROOT/plugins/gaia/skills/gaia-history/scripts/setup.sh" ]
  [ -x "$REPO_ROOT/plugins/gaia/skills/gaia-history/scripts/finalize.sh" ]
  [ -x "$HISTORY" ]
}

@test "AC-INT1/TS7: end-to-end fixture median matches hand-computed timestamps" {
  run bash "$SCRIPT" --events "$EVENTS" --sprint-yaml "$SPRINT_YAML" --json
  [ "$status" -eq 0 ]
  # hand-computed: stories {40,60} -> median 50 ; points {10,30} -> median 20
  echo "$output" | jq -e '.median_minutes_per_story == 50 and .median_minutes_per_point == 20' >/dev/null
}

@test "AC-INT1/TS7: history-render consumes derivation output end-to-end" {
  run bash "$HISTORY" --archive-dir "$ARCHIVE_DIR" --retros-dir "$RETROS_DIR" \
    --events "$EVENTS" --sprint-yaml "$SPRINT_YAML"
  [ "$status" -eq 0 ]
  # the rendered history must reflect the derived median for the active fixture sprint
  echo "$output" | grep -Eq '50' \
    || { echo "expected derived median 50 to appear in history render, got:" >&2; echo "$output" >&2; false; }
}
