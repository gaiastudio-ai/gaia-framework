#!/usr/bin/env bats
# e107-s4-planned-active-readiness-gate.bats — E107-S4
#
# planned-active-gate.sh is the HARD GATE on the E107-S1 planned→active edge.
# It refuses activation unless EVERY sprint story has a materialized file AND is
# ready-for-dev, every ATDD-required (high-risk) story has an ATDD artifact, and
# the elaborated batch passes E106-S3's agent-native capacity check
# (sm-capacity-check.sh, parsed via --json .flagged per Val W1 — NOT exit code).
# The refusal message names EXACTLY which stories fail which check.
#
# ALL tests build a temp impl-root + test-artifacts; they NEVER touch the live tree.
#
# Maps to AC1-AC5, AC-INT1. Refs: ADR-128, E107-S1/S3, E106-S3, FR-560, NFR-92.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  GATE="$REPO_ROOT/plugins/gaia/scripts/planned-active-gate.sh"
  FX="$BATS_TEST_DIRNAME/fixtures/planned-active-gate"
  SPRINT_YAML="$FX/sprint-status.yaml"
  TEST_TMP="$BATS_TEST_TMPDIR/e107s4-$$"
  IMPL="$TEST_TMP/impl"
  TA="$TEST_TMP/test-artifacts"
  mkdir -p "$IMPL" "$TA"
}
teardown() { rm -rf "$TEST_TMP" 2>/dev/null || true; }

# materialize a story file at a given status + risk under the per-story layout
mk_story() { # $1=key $2=status $3=risk
  local key="$1" st="$2" risk="$3"
  local d="$IMPL/epic-E900-fixture/${key}-slug"
  mkdir -p "$d/reviews"
  cat > "$d/story.md" <<EOF
---
template: 'story'
key: "$key"
title: "$key story"
status: $st
risk: $risk
sprint_id: sprint-900
---
# Story $key
EOF
}

mk_atdd() { printf '# atdd %s\n' "$1" > "$TA/atdd-$1.md"; }

# the three sprint stories all materialized + ready-for-dev (E900-S2 is high-risk)
all_ready() {
  mk_story E900-S1 ready-for-dev low
  mk_story E900-S2 ready-for-dev high
  mk_story E900-S3 ready-for-dev low
  mk_atdd E900-S2   # the high-risk story has its ATDD
}

# ---------- AC1 / AC2 / TS1: all-ready (materialized + ready + ATDD) passes ----------

@test "gate PASSES when all stories are materialized, ready-for-dev, and ATDD'd" {
  all_ready
  run bash "$GATE" --sprint-yaml "$SPRINT_YAML" --impl-root "$IMPL" --test-artifacts "$TA"
  [ "$status" -eq 0 ] \
    || { echo "all-ready sprint should pass the gate, got $status: $output" >&2; false; }
}

# ---------- AC1 / TS2: an unmaterialized story blocks ----------

@test "TS2/: an unmaterialized story REFUSES activation and is named" {
  all_ready
  rm -rf "$IMPL/epic-E900-fixture/E900-S3-slug"   # remove S3's file
  run bash "$GATE" --sprint-yaml "$SPRINT_YAML" --impl-root "$IMPL" --test-artifacts "$TA"
  [ "$status" -ne 0 ] \
    || { echo "an unmaterialized story should refuse activation" >&2; echo "$output" >&2; false; }
  echo "$output" | grep -Eq 'E900-S3' \
    || { echo "refusal should name the unmaterialized story E900-S3, got:" >&2; echo "$output" >&2; false; }
  echo "$output" | grep -Eiq 'unmaterialized|no file|missing file'
}

# ---------- AC1 / TS2: a not-ready story blocks ----------

@test "a not-ready (in-progress) story REFUSES activation and is named" {
  all_ready
  mk_story E900-S1 in-progress low   # flip S1 to in-progress
  run bash "$GATE" --sprint-yaml "$SPRINT_YAML" --impl-root "$IMPL" --test-artifacts "$TA"
  [ "$status" -ne 0 ]
  echo "$output" | grep -Eq 'E900-S1' \
    || { echo "refusal should name the not-ready story E900-S1, got:" >&2; echo "$output" >&2; false; }
  echo "$output" | grep -Eiq 'not.ready|not ready-for-dev|in-progress'
}

# ---------- AC2 / TS3: a high-risk story missing ATDD blocks ----------

@test "TS3/: a high-risk story missing its ATDD artifact REFUSES activation and is named" {
  all_ready
  rm -f "$TA/atdd-E900-S2.md"   # remove the high-risk story's ATDD
  run bash "$GATE" --sprint-yaml "$SPRINT_YAML" --impl-root "$IMPL" --test-artifacts "$TA"
  [ "$status" -ne 0 ] \
    || { echo "high-risk story missing ATDD should refuse, got $status" >&2; echo "$output" >&2; false; }
  echo "$output" | grep -Eq 'E900-S2' \
    || { echo "refusal should name the missing-ATDD story E900-S2, got:" >&2; echo "$output" >&2; false; }
  echo "$output" | grep -Eiq 'atdd'
}

@test "a low-risk story with no ATDD does NOT block (ATDD only required for high-risk)" {
  all_ready
  # S1/S3 are low-risk with no ATDD; only S2 (high) needs one and has it -> pass
  run bash "$GATE" --sprint-yaml "$SPRINT_YAML" --impl-root "$IMPL" --test-artifacts "$TA"
  [ "$status" -eq 0 ] \
    || { echo "low-risk stories should not require ATDD, got $status: $output" >&2; false; }
}

# ---------- AC3 / TS4: agent-native capacity overflow blocks ----------

@test "an agent-native capacity overflow REFUSES activation (sm-capacity-check via .flagged)" {
  all_ready
  # force a coherence overflow with a tiny ceiling (3 stories > ceiling 2)
  run bash "$GATE" --sprint-yaml "$SPRINT_YAML" --impl-root "$IMPL" --test-artifacts "$TA" --coherence-ceiling 2
  [ "$status" -ne 0 ] \
    || { echo "a capacity overflow (coherence > ceiling) should refuse, got $status: $output" >&2; false; }
  echo "$output" | grep -Eiq 'capacity|coherence|overflow'
}

# ---------- AC4: multi-failure message names each failing story ----------

@test "a multi-failure gate names each failing story per check" {
  all_ready
  rm -rf "$IMPL/epic-E900-fixture/E900-S3-slug"   # S3 unmaterialized
  rm -f "$TA/atdd-E900-S2.md"                      # S2 missing ATDD
  run bash "$GATE" --sprint-yaml "$SPRINT_YAML" --impl-root "$IMPL" --test-artifacts "$TA"
  [ "$status" -ne 0 ]
  echo "$output" | grep -Eq 'E900-S3' && echo "$output" | grep -Eq 'E900-S2' \
    || { echo "multi-failure message should name BOTH E900-S3 (unmaterialized) and E900-S2 (missing ATDD), got:" >&2; echo "$output" >&2; false; }
}

# ---------- robustness ----------

@test "missing --sprint-yaml fails with usage error" {
  run bash "$GATE" --impl-root "$IMPL" --test-artifacts "$TA"
  [ "$status" -ne 0 ]
}

@test "--help prints usage and exits 0" {
  run bash "$GATE" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eiq 'planned|active|readiness|gate'
}

# ---------- AC-INT1 / TS5: SKILL.md documents the gate-before-activate hook ----------

@test "sprint-plan SKILL.md documents the planned->active gate before the activate transition" {
  SKILL="$REPO_ROOT/plugins/gaia/skills/gaia-sprint-plan/SKILL.md"
  grep -Eiq 'planned-active-gate|planned.*active.*gate|readiness gate' "$SKILL" \
    || { echo "SKILL.md should document the planned->active readiness gate" >&2; false; }
}
