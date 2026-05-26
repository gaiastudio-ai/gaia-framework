#!/usr/bin/env bats
# e106-s2-dual-track-estimation.bats — E106-S2
#
# Dual-track estimation: points (relative complexity, unchanged) PLUS a parallel
# agent_wall_clock_estimate (~Xh) = E106-S1 median minutes/point × story points.
# Cold-start (no closed-sprint telemetry) renders "uncalibrated", never a
# fabricated number (AC4 / NFR-90). Estimates render in agent-hours/days, never
# calendar-months (AC3).
#
# Maps to AC1-AC5 and TS1-TS4. Per Val W2: cold-start keys on
# median_minutes_per_point==null (stories_counted==0), NOT on mpp==0 (integer
# division can yield 0 in a calibrated state for a fast story).
#
# Refs: AC1-AC5, TS1-TS4, ADR-128, ADR-042, NFR-90, FR-549, FR-550

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/plugins/gaia/scripts/dual-track-estimate.sh"
  FIXTURE_DIR="$BATS_TEST_DIRNAME/fixtures/dual-track-estimation"
  EVENTS_CAL="$FIXTURE_DIR/events-calibrated.jsonl"
  EVENTS_EMPTY="$FIXTURE_DIR/events-empty.jsonl"
  SPRINT_YAML="$FIXTURE_DIR/sprint-status.yaml"
  # calibrated fixture median minutes/point = 20 (from the E106-S1 fixture)
}

# ---------- AC2 / TS1: calibrated dual-track render ----------

@test "AC2/TS1: calibrated render emits points + numeric agent-hours estimate" {
  run bash "$SCRIPT" --events "$EVENTS_CAL" --sprint-yaml "$SPRINT_YAML" --points 5
  [ "$status" -eq 0 ]
  # 20 min/pt * 5 pt = 100 min ≈ 1.7h
  echo "$output" | grep -Eq 'points:[[:space:]]*5' \
    || { echo "expected points: 5, got:" >&2; echo "$output" >&2; false; }
  echo "$output" | grep -Eiq 'agent_wall_clock_estimate|~[0-9.]+h' \
    || { echo "expected an agent-wall-clock estimate, got:" >&2; echo "$output" >&2; false; }
  echo "$output" | grep -Eq '1\.7h|~1\.7|100 ?min|~2h' \
    || { echo "expected ~1.7h (100 min) estimate, got:" >&2; echo "$output" >&2; false; }
}

@test "AC2/TS1: json output carries both tracks" {
  run bash "$SCRIPT" --events "$EVENTS_CAL" --sprint-yaml "$SPRINT_YAML" --points 5 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.points == 5' >/dev/null
  echo "$output" | jq -e '.agent_wall_clock_minutes == 100' >/dev/null
  echo "$output" | jq -e '.calibrated == true' >/dev/null
}

# ---------- AC1 / TS4: points unchanged (additive) ----------

@test "AC1/TS4: points value is echoed unchanged regardless of telemetry" {
  run bash "$SCRIPT" --events "$EVENTS_CAL" --sprint-yaml "$SPRINT_YAML" --points 8 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.points == 8' >/dev/null
}

# ---------- AC4 / TS2: cold-start uncalibrated, no fabricated number ----------

@test "AC4/TS2: cold-start (no telemetry) renders uncalibrated marker" {
  run bash "$SCRIPT" --events "$EVENTS_EMPTY" --sprint-yaml "$SPRINT_YAML" --points 5
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eiq 'uncalibrated' \
    || { echo "expected uncalibrated marker, got:" >&2; echo "$output" >&2; false; }
  echo "$output" | grep -Eiq 'no closed-sprint telemetry' \
    || { echo "expected the 'no closed-sprint telemetry' reason, got:" >&2; echo "$output" >&2; false; }
}

@test "AC4/TS2: cold-start emits NO fabricated wall-clock number" {
  run bash "$SCRIPT" --events "$EVENTS_EMPTY" --sprint-yaml "$SPRINT_YAML" --points 5
  [ "$status" -eq 0 ]
  # the agent-wall-clock line must NOT carry a numeric hour/minute figure
  awc_line=$(echo "$output" | grep -i 'agent_wall_clock\|estimate' || true)
  ! echo "$awc_line" | grep -Eq '~?[0-9]+(\.[0-9]+)?[hmd]\b' \
    || { echo "cold-start must not fabricate a number, got: $awc_line" >&2; false; }
}

@test "AC4/TS2: cold-start json marks calibrated=false, null estimate" {
  run bash "$SCRIPT" --events "$EVENTS_EMPTY" --sprint-yaml "$SPRINT_YAML" --points 5 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.calibrated == false' >/dev/null
  echo "$output" | jq -e '.agent_wall_clock_minutes == null' >/dev/null
  echo "$output" | jq -e '.points == 5' >/dev/null
}

# ---------- AC3 / TS3: agent-hours/days, never months ----------

@test "AC3/TS3: render never emits calendar-month units" {
  run bash "$SCRIPT" --events "$EVENTS_CAL" --sprint-yaml "$SPRINT_YAML" --points 5
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -Eiq '\bmonths?\b' \
    || { echo "render must not emit month units, got:" >&2; echo "$output" >&2; false; }
}

@test "AC3/TS3: large estimate rolls up to agent-days, not months" {
  # 20 min/pt * 100 pt = 2000 min = 33.3h -> should render as days (~4.2d), never months
  run bash "$SCRIPT" --events "$EVENTS_CAL" --sprint-yaml "$SPRINT_YAML" --points 100
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eiq '[0-9.]+d\b|days' \
    || { echo "expected agent-days for a large estimate, got:" >&2; echo "$output" >&2; false; }
  ! echo "$output" | grep -Eiq '\bmonths?\b'
}

# ---------- robustness ----------

@test "missing --points fails with usage error" {
  run bash "$SCRIPT" --events "$EVENTS_CAL" --sprint-yaml "$SPRINT_YAML"
  [ "$status" -ne 0 ]
}

@test "--help prints usage and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eiq 'dual-track'
}

# ---------- AC5: both render paths asserted (calibrated + cold-start) ----------

@test "AC5: both calibrated and cold-start paths are exercised above" {
  # meta-assertion: the calibrated (TS1) and cold-start (TS2) tests above both run.
  run bash "$SCRIPT" --events "$EVENTS_CAL" --sprint-yaml "$SPRINT_YAML" --points 5 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.calibrated == true' >/dev/null
  run bash "$SCRIPT" --events "$EVENTS_EMPTY" --sprint-yaml "$SPRINT_YAML" --points 5 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.calibrated == false' >/dev/null
}
