#!/usr/bin/env bats
# concurrent-sprint-recheck.bats — pre-mutation independence re-check gate
#
# Tests independence-gate.sh (default + edit modes), the inject gate in
# sprint-state.sh, and catch-all flag set/unset with audit trail.

# shellcheck disable=SC2030,SC2031

setup() {
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT PROJECT_PATH

  TEST_DIR="$(mktemp -d)"
  STATE_DIR="$TEST_DIR/.gaia/state"
  IMPL_DIR="$TEST_DIR/.gaia/artifacts/implementation-artifacts"
  CONFIG_DIR="$TEST_DIR/.gaia/config"
  PLANNING_DIR="$TEST_DIR/.gaia/artifacts/planning-artifacts"
  SHARDS_DIR="$PLANNING_DIR/epics"
  mkdir -p "$STATE_DIR" "$IMPL_DIR" "$CONFIG_DIR" "$PLANNING_DIR" "$SHARDS_DIR"
  mkdir -p "$TEST_DIR/gaia-public/plugins/gaia/scripts/lib"

  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: "recheck-test"
sprint:
  max_concurrent_active: 3
stacks:
  - name: bash
    path: "."
YAML

  cat > "$PLANNING_DIR/epics-and-stories.md" <<'MD'
# Epics and Stories

## E900 — Test Alpha

## E901 — Test Beta

## E902 — Test Gamma

## E28 — Bug Fixes
<!-- catch_all: true -->
MD

  printf 'sprint-900 %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$STATE_DIR/.sprint-migration-complete"

  export PROJECT_ROOT="$TEST_DIR"
  export PROJECT_PATH="$TEST_DIR"
  export IMPLEMENTATION_ARTIFACTS="$IMPL_DIR"
  export GAIA_SKIP_ORPHAN_SWEEP=1
  export GAIA_SNAPSHOT_HOOK_DISABLE=1

  BATS_TEST_SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  GATE_SCRIPT="$BATS_TEST_SCRIPT_DIR/scripts/independence-gate.sh"
  IC_SCRIPT="$BATS_TEST_SCRIPT_DIR/scripts/independence-check.sh"
  CAF_SCRIPT="$BATS_TEST_SCRIPT_DIR/scripts/lib/catch-all-flag.sh"
  export SPRINT_STATE_SCRIPT_DIR="$BATS_TEST_SCRIPT_DIR/scripts"
}

teardown() {
  rm -rf "$TEST_DIR" 2>/dev/null || true
}

# Helper: create a sprint state file with stories.
_create_sprint() {
  local sid="$1" status="$2"
  shift 2
  local f="$STATE_DIR/sprint-status-${sid}.yaml"
  {
    printf 'sprint_id: "%s"\n' "$sid"
    printf 'status: %s\n' "$status"
    printf 'total_points: 0\n'
    printf 'goals: []\n'
    printf 'stories:\n'
  } > "$f"
  local arg
  for arg in "$@"; do
    local key="${arg%%:*}"
    local rest="${arg#*:}"
    local epic="${rest%%:*}"
    local touch="${rest#*:}"
    printf '  - key: "%s"\n    title: "Story %s"\n    status: "in-progress"\n    points: 3\n    risk: "medium"\n' "$key" "$key" >> "$f"
    _mk_story "$key" "$epic" "$touch" "$sid"
  done
}

# Helper: create a story file with predicted_touch_set.
_mk_story() {
  local key="$1" epic="$2" touch="$3" sprint_id="${4:-sprint-900}"
  local epic_slug
  epic_slug="$(printf '%s' "$epic" | tr '[:upper:]' '[:lower:]')"
  local story_dir="$IMPL_DIR/epic-${epic_slug}/${key}-test-story"
  mkdir -p "$story_dir"
  if [ -n "$touch" ]; then
    mkdir -p "$TEST_DIR/$(dirname "$touch")" 2>/dev/null || true
    touch "$TEST_DIR/$touch" 2>/dev/null || true
  fi
  cat > "$story_dir/story.md" <<STORY
---
template: 'story'
key: "${key}"
epic: "${epic}"
status: in-progress
sprint_id: "${sprint_id}"
priority: "P2"
size: "M"
points: 3
risk: "medium"
predicted_touch_set: ["${touch}"]
depends_on: []
blocks: []
date: "2026-10-19"
author: "Test"
---
# Story: ${key}
STORY
}

# ---- AC1: inject blocked by re-check ----

@test "inject blocked by re-check when touch-set overlaps another sprint" {
  _create_sprint "sprint-900" "active" "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  _create_sprint "sprint-901" "active" "E901-S1:E901:gaia-public/plugins/gaia/scripts/independence-check.sh"
  _mk_story "E900-S2" "E900" "gaia-public/plugins/gaia/scripts/independence-check.sh" "sprint-900"
  local sf="$IMPL_DIR/epic-e900/E900-S2-test-story/story.md"
  run bash "$GATE_SCRIPT" "$sf" --candidate sprint-900
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
}

# ---- AC1: non-conflicting inject succeeds ----

@test "inject succeeds when touch-set is disjoint" {
  _create_sprint "sprint-900" "active" "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  _create_sprint "sprint-901" "active" "E901-S1:E901:gaia-public/plugins/gaia/scripts/independence-check.sh"
  _mk_story "E900-S3" "E900" "gaia-public/plugins/gaia/scripts/lifecycle-event.sh" "sprint-900"
  local sf="$IMPL_DIR/epic-e900/E900-S3-test-story/story.md"
  run bash "$GATE_SCRIPT" "$sf" --candidate sprint-900
  [ "$status" -eq 0 ]
}

# ---- AC1: touch-set edit overlap rolled back ----

@test "touch-set edit creating overlap rolled back and story byte-unchanged" {
  _create_sprint "sprint-900" "active" "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  _create_sprint "sprint-901" "active" "E901-S1:E901:gaia-public/plugins/gaia/scripts/independence-check.sh"
  local sf="$IMPL_DIR/epic-e900/E900-S1-test-story/story.md"
  local before; before="$(cat "$sf")"
  run bash "$GATE_SCRIPT" edit --story "$sf" \
    --set "predicted_touch_set=gaia-public/plugins/gaia/scripts/independence-check.sh"
  [ "$status" -ne 0 ]
  local after; after="$(cat "$sf")"
  [ "$before" = "$after" ]
}

# ---- AC1: dependency edge edit cross-sprint rolled back ----

@test "dependency edge edit creating cross-sprint edge rolled back" {
  _create_sprint "sprint-900" "active" "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  _create_sprint "sprint-901" "active" "E901-S1:E901:gaia-public/plugins/gaia/scripts/independence-check.sh"
  local sf="$IMPL_DIR/epic-e900/E900-S1-test-story/story.md"
  local before; before="$(cat "$sf")"
  run bash "$GATE_SCRIPT" edit --story "$sf" --set "depends_on=E901-S1"
  [ "$status" -ne 0 ]
  local after; after="$(cat "$sf")"
  [ "$before" = "$after" ]
}

# ---- AC1: edit round-trip succeeds on non-conflicting value ----

@test "edit round-trip: non-conflicting depends_on succeeds and applies" {
  _create_sprint "sprint-900" "active" \
    "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh" \
    "E900-S99:E900:gaia-public/plugins/gaia/scripts/lifecycle-event.sh"
  _create_sprint "sprint-901" "active" "E901-S1:E901:gaia-public/plugins/gaia/scripts/independence-check.sh"
  local sf="$IMPL_DIR/epic-e900/E900-S1-test-story/story.md"
  run bash "$GATE_SCRIPT" edit --story "$sf" --set "depends_on=E900-S99"
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "E900-S99" "$sf"
}

# ---- AC1: prewrite hook refuses denied character ----

@test "touch-set edit gate refuses denied character via prewrite hook" {
  _create_sprint "sprint-900" "active" "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  local sf="$IMPL_DIR/epic-e900/E900-S1-test-story/story.md"
  run bash "$GATE_SCRIPT" edit --story "$sf" \
    --set 'predicted_touch_set=gaia-public/plugins/gaia/scripts/`evil`.sh'
  [ "$status" -ne 0 ]
}

# ---- AC1: overlay replaces on-disk story ----

@test "overlay replaces on-disk story in independence check" {
  _create_sprint "sprint-900" "active" "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  _create_sprint "sprint-901" "active" "E901-S1:E901:gaia-public/plugins/gaia/scripts/independence-check.sh"
  local overlay_dir="$TEST_DIR/_overlay"
  mkdir -p "$overlay_dir"
  cat > "$overlay_dir/overlay.md" <<'OV'
---
template: 'story'
key: "E900-S1"
epic: "E900"
status: in-progress
sprint_id: "sprint-900"
predicted_touch_set: ["gaia-public/plugins/gaia/scripts/independence-check.sh"]
depends_on: []
blocks: []
date: "2026-10-19"
author: "Test"
---
# Story: E900-S1
OV
  run bash "$IC_SCRIPT" --candidate sprint-900 --overlay "$overlay_dir/overlay.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
}

# ---- AC1: rollover carry-over key succeeds (R77) ----

@test "concurrent rollover of passing key succeeds through inject gate" {
  _create_sprint "sprint-900" "active" "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  _create_sprint "sprint-901" "active" "E901-S1:E901:gaia-public/plugins/gaia/scripts/independence-check.sh"
  # Add E900-S1 to sprint-901 (carry-over in flight).
  printf '  - key: "E900-S1"\n    title: "Story E900-S1"\n    status: "in-progress"\n    points: 3\n    risk: "medium"\n' \
    >> "$STATE_DIR/sprint-status-sprint-901.yaml"
  local sf="$IMPL_DIR/epic-e900/E900-S1-test-story/story.md"
  run bash "$GATE_SCRIPT" "$sf" --candidate sprint-900
  [ "$status" -eq 0 ]
}

# ---- AC1: different story in source sprint still blocks despite carry-over ----

@test "different story in source sprint blocks despite carry-over key skip" {
  _create_sprint "sprint-900" "active" \
    "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh" \
    "E900-S2:E900:gaia-public/plugins/gaia/scripts/independence-check.sh"
  _create_sprint "sprint-901" "active" "E901-S1:E901:gaia-public/plugins/gaia/scripts/independence-check.sh"
  # E900-S1 is in both sprints (carry-over), but E900-S2 overlaps.
  printf '  - key: "E900-S1"\n    title: "Story E900-S1"\n    status: "in-progress"\n    points: 3\n    risk: "medium"\n' \
    >> "$STATE_DIR/sprint-status-sprint-901.yaml"
  local sf="$IMPL_DIR/epic-e900/E900-S1-test-story/story.md"
  run bash "$GATE_SCRIPT" "$sf" --candidate sprint-900
  [ "$status" -ne 0 ]
}

# ---- AC3: catch-all story blocked by rule c ----

@test "catch-all epic story with touch-set overlap blocked by rule c" {
  _create_sprint "sprint-900" "active" "E28-S500:E28:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  _create_sprint "sprint-901" "active" "E901-S1:E901:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  local sf="$IMPL_DIR/epic-e28/E28-S500-test-story/story.md"
  run bash "$GATE_SCRIPT" "$sf" --candidate sprint-900
  [ "$status" -ne 0 ]
}

# ---- AC4: integration - conflicting blocked, non-conflicting succeeds ----

@test "integration: conflicting inject blocked, non-conflicting succeeds" {
  _create_sprint "sprint-900" "active" "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  _create_sprint "sprint-901" "active" "E901-S1:E901:gaia-public/plugins/gaia/scripts/independence-check.sh"
  _mk_story "E900-S2" "E900" "gaia-public/plugins/gaia/scripts/independence-check.sh" "sprint-900"
  run bash "$GATE_SCRIPT" "$IMPL_DIR/epic-e900/E900-S2-test-story/story.md" --candidate sprint-900
  [ "$status" -ne 0 ]
  _mk_story "E900-S3" "E900" "gaia-public/plugins/gaia/scripts/lifecycle-event.sh" "sprint-900"
  run bash "$GATE_SCRIPT" "$IMPL_DIR/epic-e900/E900-S3-test-story/story.md" --candidate sprint-900
  [ "$status" -eq 0 ]
}

# ---- AC5: catch-all flag change re-check ----

@test "catch-all flag change violation blocked with audit trail result=fail" {
  _create_sprint "sprint-900" "active" "E28-S500:E28:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  _create_sprint "sprint-901" "active" "E28-S501:E28:gaia-public/plugins/gaia/scripts/independence-check.sh"
  run bash "$CAF_SCRIPT" --unset E28 \
    --epics-file "$PLANNING_DIR/epics-and-stories.md" --shards-dir "$SHARDS_DIR"
  [ "$status" -ne 0 ]
  [ -f "$STATE_DIR/catch-all-audit.log" ]
  /usr/bin/grep -q "result=fail" "$STATE_DIR/catch-all-audit.log"
}

@test "catch-all flag change non-violation accepted with audit trail result=pass" {
  _create_sprint "sprint-900" "active" "E28-S500:E28:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  _create_sprint "sprint-901" "active" "E901-S1:E901:gaia-public/plugins/gaia/scripts/independence-check.sh"
  run bash "$CAF_SCRIPT" --unset E28 \
    --epics-file "$PLANNING_DIR/epics-and-stories.md" --shards-dir "$SHARDS_DIR"
  [ "$status" -eq 0 ]
  [ -f "$STATE_DIR/catch-all-audit.log" ]
  /usr/bin/grep -q "result=pass" "$STATE_DIR/catch-all-audit.log"
}

@test "out-of-band catch-all flag edit detected via snapshot diff" {
  _create_sprint "sprint-900" "active" "E28-S500:E28:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  bash "$CAF_SCRIPT" --audit \
    --epics-file "$PLANNING_DIR/epics-and-stories.md" --shards-dir "$SHARDS_DIR" \
    > "$STATE_DIR/catch-all-audit.snapshot" 2>/dev/null
  # Hand-edit the flag directly (bypassing catch-all-flag.sh).
  sed 's/catch_all: true/catch_all: false/' \
    "$PLANNING_DIR/epics-and-stories.md" > "$PLANNING_DIR/epics-and-stories.md.tmp"
  mv -f "$PLANNING_DIR/epics-and-stories.md.tmp" "$PLANNING_DIR/epics-and-stories.md"
  local live_audit snapshot
  live_audit="$(bash "$CAF_SCRIPT" --audit \
    --epics-file "$PLANNING_DIR/epics-and-stories.md" --shards-dir "$SHARDS_DIR" 2>/dev/null)"
  snapshot="$(cat "$STATE_DIR/catch-all-audit.snapshot")"
  [ "$live_audit" != "$snapshot" ]
}

# ---- AC7: single-sprint mode ----

@test "single-sprint mode: no re-check, gate exits 0" {
  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: "single-sprint-test"
stacks:
  - name: bash
    path: "."
YAML
  rm -f "$STATE_DIR"/sprint-status-*.yaml
  _mk_story "E900-S1" "E900" "gaia-public/plugins/gaia/scripts/sprint-state.sh" "sprint-900"
  local sf="$IMPL_DIR/epic-e900/E900-S1-test-story/story.md"
  run bash "$GATE_SCRIPT" "$sf" --candidate sprint-900
  [ "$status" -eq 0 ]
}

# ---- AC-EC3: touch-set update re-checks against later-activated sprint ----

@test "touch-set update re-checks against all currently active sprints" {
  _create_sprint "sprint-900" "active" "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  _create_sprint "sprint-901" "active" "E901-S1:E901:gaia-public/plugins/gaia/scripts/independence-check.sh"
  _create_sprint "sprint-902" "active" "E902-S1:E902:gaia-public/plugins/gaia/scripts/lifecycle-event.sh"
  local sf="$IMPL_DIR/epic-e900/E900-S1-test-story/story.md"
  run bash "$GATE_SCRIPT" edit --story "$sf" \
    --set "predicted_touch_set=gaia-public/plugins/gaia/scripts/lifecycle-event.sh"
  [ "$status" -ne 0 ]
}

# ---- AC1: correct-course SKILL.md references independence-gate.sh edit ----

@test "correct-course SKILL.md references independence-gate.sh edit" {
  local skill_f="$BATS_TEST_SCRIPT_DIR/skills/gaia-correct-course/SKILL.md"
  [ -f "$skill_f" ]
  /usr/bin/grep -q "independence-gate.sh edit" "$skill_f"
}

# ---- AC8: no internal traceability identifiers ----

# ---- AC1: gate inside sprint-state.sh inject (through the REAL inject path) ----

@test "sprint-state.sh inject refuses overlapping story in concurrent mode" {
  _create_sprint "sprint-900" "active" "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  _create_sprint "sprint-901" "active" "E901-S1:E901:gaia-public/plugins/gaia/scripts/independence-check.sh"
  _mk_story "E900-S2" "E900" "gaia-public/plugins/gaia/scripts/independence-check.sh" "sprint-900"
  # Inject via the REAL sprint-state.sh inject subcommand.
  run bash -c "PROJECT_PATH='$TEST_DIR' IMPLEMENTATION_ARTIFACTS='$IMPL_DIR' \
    GAIA_SKIP_ORPHAN_SWEEP=1 GAIA_SNAPSHOT_HOOK_DISABLE=1 \
    bash '$BATS_TEST_SCRIPT_DIR/scripts/sprint-state.sh' inject \
      --story E900-S2 --sprint-id sprint-900 2>&1"
  [ "$status" -ne 0 ]
  # Must be refused by the independence gate (FAIL or refused message).
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"refused"* ]] || [[ "$output" == *"blocked"* ]]
  # State file must NOT contain E900-S2.
  ! /usr/bin/grep -q "E900-S2" "$STATE_DIR/sprint-status-sprint-900.yaml"
}

@test "sprint-state.sh inject succeeds for non-overlapping story in concurrent mode" {
  _create_sprint "sprint-900" "active" "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  _create_sprint "sprint-901" "active" "E901-S1:E901:gaia-public/plugins/gaia/scripts/independence-check.sh"
  _mk_story "E900-S3" "E900" "gaia-public/plugins/gaia/scripts/lifecycle-event.sh" "sprint-900"
  run bash -c "PROJECT_PATH='$TEST_DIR' IMPLEMENTATION_ARTIFACTS='$IMPL_DIR' \
    GAIA_SKIP_ORPHAN_SWEEP=1 GAIA_SNAPSHOT_HOOK_DISABLE=1 \
    bash '$BATS_TEST_SCRIPT_DIR/scripts/sprint-state.sh' inject \
      --story E900-S3 --sprint-id sprint-900 2>&1"
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "E900-S3" "$STATE_DIR/sprint-status-sprint-900.yaml"
}

@test "sprint-state.sh inject skips gate in single-sprint mode" {
  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: "single-sprint"
stacks:
  - name: bash
    path: "."
YAML
  rm -f "$STATE_DIR"/sprint-status-*.yaml
  # Create a single-sprint state file.
  cat > "$STATE_DIR/sprint-status.yaml" <<'YAML'
sprint_id: "sprint-900"
status: active
total_points: 0
goals: []
stories: []
YAML
  _mk_story "E900-S1" "E900" "gaia-public/plugins/gaia/scripts/sprint-state.sh" "sprint-900"
  PROJECT_PATH="$TEST_DIR" \
    bash "$BATS_TEST_SCRIPT_DIR/scripts/sprint-state.sh" inject \
      --story E900-S1 2>&1
  /usr/bin/grep -q "E900-S1" "$STATE_DIR/sprint-status.yaml"
}

# ---- Fail-closed: gate refuses when story file not found ----

@test "inject gate refuses when story file resolution fails in concurrent mode" {
  _create_sprint "sprint-900" "active" "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  _create_sprint "sprint-901" "active" "E901-S1:E901:gaia-public/plugins/gaia/scripts/independence-check.sh"
  # Try to inject a key with no story file.
  local out
  out="$(PROJECT_PATH="$TEST_DIR" \
    bash "$BATS_TEST_SCRIPT_DIR/scripts/sprint-state.sh" inject \
      --story E900-S99 --sprint-id sprint-900 2>&1)" || true
  [[ "$out" == *"fail-closed"* ]] || [[ "$out" == *"not found"* ]]
}

# ---- Fail-closed: catch-all refuses when independence-check.sh absent ----

@test "catch-all flag change refuses when independence-check.sh absent in concurrent mode" {
  _create_sprint "sprint-900" "active" "E28-S500:E28:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  _create_sprint "sprint-901" "active" "E28-S501:E28:gaia-public/plugins/gaia/scripts/independence-check.sh"
  # Rename independence-check.sh to simulate absence.
  local ic="$BATS_TEST_SCRIPT_DIR/scripts/independence-check.sh"
  mv "$ic" "${ic}.bak"
  local before
  before="$(cat "$PLANNING_DIR/epics-and-stories.md")"
  run bash "$CAF_SCRIPT" --unset E28 \
    --epics-file "$PLANNING_DIR/epics-and-stories.md" --shards-dir "$SHARDS_DIR"
  mv "${ic}.bak" "$ic"
  [ "$status" -ne 0 ]
  # Epics file must be byte-identical (no change applied).
  local after
  after="$(cat "$PLANNING_DIR/epics-and-stories.md")"
  [ "$before" = "$after" ]
}

# ---- Injection prevention: malicious key rejected ----

@test "independence-gate.sh rejects malicious story key format" {
  _create_sprint "sprint-900" "active" "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  # Create a story file with a malicious key.
  local evil_dir="$IMPL_DIR/epic-e900/evil-test-story"
  mkdir -p "$evil_dir"
  cat > "$evil_dir/story.md" <<'STORY'
---
template: 'story'
key: "E900-S1;rm -rf /"
epic: "E900"
status: in-progress
sprint_id: "sprint-900"
predicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]
depends_on: []
blocks: []
---
# Story
STORY
  run bash "$GATE_SCRIPT" "$evil_dir/story.md" --candidate sprint-900
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid story key format"* ]]
}

# ---- Catch-all flag refusal leaves epics file byte-identical ----

@test "catch-all flag violation refusal leaves epics file byte-identical" {
  _create_sprint "sprint-900" "active" "E28-S500:E28:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  _create_sprint "sprint-901" "active" "E28-S501:E28:gaia-public/plugins/gaia/scripts/independence-check.sh"
  local before
  before="$(cat "$PLANNING_DIR/epics-and-stories.md")"
  run bash "$CAF_SCRIPT" --unset E28 \
    --epics-file "$PLANNING_DIR/epics-and-stories.md" --shards-dir "$SHARDS_DIR"
  [ "$status" -ne 0 ]
  local after
  after="$(cat "$PLANNING_DIR/epics-and-stories.md")"
  [ "$before" = "$after" ]
}

# ---- AC8: no internal traceability identifiers ----

@test "no internal traceability identifiers in published gate script" {
  [ -f "$GATE_SCRIPT" ]
  # Scan for leaked IDs; exclude load-bearing regex patterns and test fixtures.
  local found=0
  if /usr/bin/grep -EnH '(FR|NFR|SR|ADR)-[0-9]' "$GATE_SCRIPT" 2>/dev/null | \
     /usr/bin/grep -v 'E\[0-9\]' | /usr/bin/grep -qv 'regex\|match\|scan\|pattern'; then
    found=1
  fi
  [ "$found" -eq 0 ]
}
