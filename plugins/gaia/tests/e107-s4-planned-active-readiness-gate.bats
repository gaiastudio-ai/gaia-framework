#!/usr/bin/env bats
# e107-s4-planned-active-readiness-gate.bats
#
# planned-active-gate.sh is the HARD GATE on the planned->active sprint edge.
# It refuses activation unless EVERY sprint story has a materialized file AND is
# ready-for-dev, every high-risk story has an ATDD artifact, and the elaborated
# batch passes the agent-native capacity check (sm-capacity-check.sh, parsed
# via --json .flagged — NOT exit code). The refusal message names EXACTLY which
# stories fail which check.
#
# ALL tests build a temp impl-root + test-artifacts; they NEVER touch the live tree.

load 'test_helper.bash'

setup_file() {
  _litter_snapshot_before
  printf 'BASH_VERSION=%s\n' "$BASH_VERSION" >&3
}

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

# create a nested per-story ATDD at the resolver's canonical path
mk_atdd_nested() { # $1=key
  local key="$1"
  local d="$TA/epic-E900-fixture/${key}-slug"
  mkdir -p "$d"
  printf '# atdd %s (nested)\n' "$key" > "$d/atdd.md"
}

# the three sprint stories all materialized + ready-for-dev (E900-S2 is high-risk)
all_ready() {
  mk_story E900-S1 ready-for-dev low
  mk_story E900-S2 ready-for-dev high
  mk_story E900-S3 ready-for-dev low
  mk_atdd E900-S2   # the high-risk story has its ATDD
}

# ---------- all-ready (materialized + ready + ATDD) passes ----------

@test "gate PASSES when all stories are materialized, ready-for-dev, and ATDD'd" {
  all_ready
  run bash "$GATE" --sprint-yaml "$SPRINT_YAML" --impl-root "$IMPL" --test-artifacts "$TA"
  [ "$status" -eq 0 ] \
    || { echo "all-ready sprint should pass the gate, got $status: $output" >&2; false; }
}

# ---------- an unmaterialized story blocks ----------

@test "an unmaterialized story REFUSES activation and is named" {
  all_ready
  rm -rf "$IMPL/epic-E900-fixture/E900-S3-slug"   # remove S3's file
  run bash "$GATE" --sprint-yaml "$SPRINT_YAML" --impl-root "$IMPL" --test-artifacts "$TA"
  [ "$status" -ne 0 ] \
    || { echo "an unmaterialized story should refuse activation" >&2; echo "$output" >&2; false; }
  grep -Eq 'E900-S3' <<<"$output" \
    || { echo "refusal should name the unmaterialized story E900-S3, got:" >&2; echo "$output" >&2; false; }
  grep -Eiq 'unmaterialized|no file|missing file' <<<"$output"
}

# ---------- a not-ready story blocks ----------

@test "a not-ready (in-progress) story REFUSES activation and is named" {
  all_ready
  mk_story E900-S1 in-progress low   # flip S1 to in-progress
  run bash "$GATE" --sprint-yaml "$SPRINT_YAML" --impl-root "$IMPL" --test-artifacts "$TA"
  [ "$status" -ne 0 ]
  grep -Eq 'E900-S1' <<<"$output" \
    || { echo "refusal should name the not-ready story E900-S1, got:" >&2; echo "$output" >&2; false; }
  grep -Eiq 'not.ready|not ready-for-dev|in-progress' <<<"$output"
}

# ---------- a high-risk story missing ATDD blocks ----------

@test "a high-risk story missing its ATDD artifact REFUSES activation and is named" {
  all_ready
  rm -f "$TA/atdd-E900-S2.md"   # remove the high-risk story's ATDD
  run bash "$GATE" --sprint-yaml "$SPRINT_YAML" --impl-root "$IMPL" --test-artifacts "$TA"
  [ "$status" -ne 0 ] \
    || { echo "high-risk story missing ATDD should refuse, got $status" >&2; echo "$output" >&2; false; }
  grep -Eq 'E900-S2' <<<"$output" \
    || { echo "refusal should name the missing-ATDD story E900-S2, got:" >&2; echo "$output" >&2; false; }
  grep -Eiq 'atdd' <<<"$output"
}

@test "a low-risk story with no ATDD does NOT block (ATDD only required for high-risk)" {
  all_ready
  # S1/S3 are low-risk with no ATDD; only S2 (high) needs one and has it -> pass
  run bash "$GATE" --sprint-yaml "$SPRINT_YAML" --impl-root "$IMPL" --test-artifacts "$TA"
  [ "$status" -eq 0 ] \
    || { echo "low-risk stories should not require ATDD, got $status: $output" >&2; false; }
}

# ---------- nested ATDD discovered via resolver ----------

@test "nested per-story ATDD at resolver canonical path satisfies the gate" {
  all_ready
  rm -f "$TA/atdd-E900-S2.md"   # remove the flat ATDD  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  mk_atdd_nested E900-S2         # create nested ATDD at resolver path  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  run bash "$GATE" --sprint-yaml "$SPRINT_YAML" --impl-root "$IMPL" --test-artifacts "$TA"
  [ "$status" -eq 0 ] \
    || { echo "nested per-story ATDD should satisfy the gate, got $status: $output" >&2; false; }
}

# ---------- epic-level ATDD accepted as shared coverage ----------

@test "epic-level atdd-{epic}.md accepted when no per-story ATDD exists" {
  all_ready
  rm -f "$TA/atdd-E900-S2.md"       # remove per-story ATDD  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  printf '# epic ATDD\n' > "$TA/atdd-E900.md"   # epic-level exact file
  run bash "$GATE" --sprint-yaml "$SPRINT_YAML" --impl-root "$IMPL" --test-artifacts "$TA"
  [ "$status" -eq 0 ] \
    || { echo "epic-level ATDD should satisfy the gate, got $status: $output" >&2; false; }
}

# ---------- sibling false-pass blocked ----------

@test "sibling flat ATDD file does not false-pass for a story with no ATDD" {
  all_ready
  rm -f "$TA/atdd-E900-S2.md"       # remove the high-risk story's ATDD  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  # low-risk story with a flat ATDD (should not satisfy the high-risk story)
  printf '# atdd fixture\n' > "$TA/atdd-E900-S1.md"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  run bash "$GATE" --sprint-yaml "$SPRINT_YAML" --impl-root "$IMPL" --test-artifacts "$TA"
  [ "$status" -eq 2 ] \
    || { echo "sibling flat file should not satisfy the high-risk story, got exit $status" >&2; echo "$output" >&2; false; }
  local _hr_key="E900-S2"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  grep -Eq "$_hr_key" <<<"$output" \
    || { echo "refusal should name the high-risk story, got:" >&2; echo "$output" >&2; false; }
}

# ---------- key-prefix boundary guard ----------

@test "key-prefix boundary: sibling prefix-collision file does not satisfy the high-risk story" {
  all_ready
  rm -f "$TA/atdd-E900-S2.md"       # remove the high-risk story's ATDD  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  printf '# atdd fixture\n' > "$TA/atdd-E900-S20.md"   # prefix collision  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  run bash "$GATE" --sprint-yaml "$SPRINT_YAML" --impl-root "$IMPL" --test-artifacts "$TA"
  [ "$status" -eq 2 ] \
    || { echo "prefix-collision file should not satisfy the high-risk story, got exit $status" >&2; echo "$output" >&2; false; }
  local _hr_key="E900-S2"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  grep -Eq "$_hr_key" <<<"$output" \
    || { echo "refusal should name the high-risk story in missing_atdd, got:" >&2; echo "$output" >&2; false; }
}

# ---------- agent-native capacity overflow blocks ----------

@test "an agent-native capacity overflow REFUSES activation (sm-capacity-check via .flagged)" {
  all_ready
  # force a coherence overflow with a tiny ceiling (3 stories > ceiling 2)
  run bash "$GATE" --sprint-yaml "$SPRINT_YAML" --impl-root "$IMPL" --test-artifacts "$TA" --coherence-ceiling 2
  [ "$status" -ne 0 ] \
    || { echo "a capacity overflow (coherence > ceiling) should refuse, got $status: $output" >&2; false; }
  grep -Eiq 'capacity|coherence|overflow' <<<"$output"
}

# ---------- multi-failure message names each failing story ----------

@test "a multi-failure gate names each failing story per check" {
  all_ready
  rm -rf "$IMPL/epic-E900-fixture/E900-S3-slug"   # S3 unmaterialized
  rm -f "$TA/atdd-E900-S2.md"                      # S2 missing ATDD
  run bash "$GATE" --sprint-yaml "$SPRINT_YAML" --impl-root "$IMPL" --test-artifacts "$TA"
  [ "$status" -ne 0 ]
  grep -Eq 'E900-S3' <<<"$output" && echo "$output" | grep -Eq 'E900-S2' \
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
  grep -Eiq 'planned|active|readiness|gate' <<<"$output"
}

# ---------- SKILL.md documents the gate-before-activate hook ----------

@test "sprint-plan SKILL.md documents the planned->active gate before the activate transition" {
  SKILL="$REPO_ROOT/plugins/gaia/skills/gaia-sprint-plan/SKILL.md"
  grep -Eiq 'planned-active-gate|planned.*active.*gate|readiness gate' "$SKILL" \
    || { echo "SKILL.md should document the planned->active readiness gate" >&2; false; }
}
