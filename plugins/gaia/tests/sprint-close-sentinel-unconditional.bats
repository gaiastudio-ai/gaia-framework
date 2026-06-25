#!/usr/bin/env bats
# sprint-close-sentinel-unconditional.bats
#
# Regression tests: the sprint-review sentinel check in close.sh must fire
# unconditionally (both `active` and `review` source states). Previously the
# sentinel gate was only reached via the review->closed edge in
# sprint-state.sh; an active sprint bypassed it entirely via a direct yq
# fallback. The `--force` flag is the sole documented bypass for a missing
# sentinel.

load 'test_helper.bash'

SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-sprint-close"
CLOSE_SH="$SKILL_DIR/scripts/close.sh"

setup() {
  common_setup
  export PROJECT_PATH="$TEST_TMP"
  export MEMORY_PATH="$TEST_TMP/.gaia/memory"
  CKPT_DIR="$MEMORY_PATH/checkpoints"
  ART="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  ARCHIVE="$ART/sprint-archive"
  YAML="$TEST_TMP/.gaia/state/sprint-status.yaml"
  export SPRINT_STATUS_YAML="$YAML"
  export GAIA_SPRINT_CLOSE_DATE="2026-06-24"
  # Disable sprint-state.sh routing — we test close.sh's own sentinel logic,
  # not the sprint-state.sh layer (which is unchanged by this fix).
  export SPRINT_STATE_SH="/nonexistent/sprint-state.sh"
  mkdir -p "$(dirname "$YAML")" "$ART" "$MEMORY_PATH" "$CKPT_DIR"
}

teardown() { common_teardown; }

# ---------- Fixture helpers ----------

# Seed a minimal sprint-status.yaml.
# Usage: _seed_yaml <sprint_id> <status> <stories_done> <stories_total>
_seed_yaml() {
  local sprint_id="$1" status="$2" done="$3" total="$4"
  mkdir -p "$(dirname "$YAML")"
  {
    printf 'sprint_id: "%s"\n' "$sprint_id"
    printf 'status: %s\n' "$status"
    printf 'total_points: %d\n' "$((total * 3))"
    printf 'stories:\n'
    local i
    for i in $(seq 1 "$total"); do
      local s="done"
      [ "$i" -gt "$done" ] && s="in-progress"
      printf '  - key: "S%d"\n' "$i"
      printf '    status: %s\n' "$s"
      printf '    points: 3\n'
      printf '    risk: medium\n'
    done
  } > "$YAML"
}

_seed_retro() {
  local sprint_id="$1"
  touch "$ART/retrospective-${sprint_id}-2026-06-24.md"
}

# Plant a dispatch sentinel for the given sprint.
_seed_sentinel() {
  local sprint_id="$1"
  mkdir -p "$CKPT_DIR"
  cat > "$CKPT_DIR/sprint-review-${sprint_id}-val-dispatched.json" <<EOF
{"agent":"val","status":"PASSED","summary":"ok","findings":[]}
EOF
}

# Read the top-level yaml status field.
_yaml_status() {
  grep '^status:' "$YAML" 2>/dev/null | head -1 | sed 's/^status:[[:space:]]*//' | tr -d '"' || true
}

# ---------- Tests ----------

# -- AC1: active sprint, no sentinel, no --force => refused (AC1) --

@test "active sprint with no sentinel refuses close without --force (AC1)" {
  _seed_yaml "sprint-70" "active" 3 3
  _seed_retro "sprint-70"
  run "$CLOSE_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sprint-review"* ]]
  [[ "$output" == *"sentinel"* ]]
  # Yaml must NOT have been mutated to closed.
  [ "$(_yaml_status)" = "active" ]
}

# -- AC1: review sprint, no sentinel, no --force => refused (AC1) --

@test "review sprint with no sentinel refuses close without --force (AC1)" {
  _seed_yaml "sprint-70" "review" 3 3
  _seed_retro "sprint-70"
  run "$CLOSE_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sprint-review"* ]]
  [ "$(_yaml_status)" = "review" ]
}

# -- AC2: sentinel check is NOT gated on status value (structural) (AC2) --

@test "sentinel check in close.sh is not gated on status value (AC2)" {
  # Structural assertion: the sentinel probe must NOT be inside a
  # status-conditional block. Grep for the sentinel refusal message and verify
  # there is no 'if.*status.*review' guard wrapping it within 10 lines above.
  [ -f "$CLOSE_SH" ]
  # The unconditional sentinel section should contain the refusal message.
  grep -qF "no sprint-review sentinel" "$CLOSE_SH"
  # There must be no review-gated conditional wrapping the sentinel check.
  # If the sentinel probe were inside `if [ "$current_status" = "review" ]`,
  # we would find that pattern near the sentinel code. Assert it is absent.
  run grep -B10 "no sprint-review sentinel" "$CLOSE_SH"
  [ "$status" -eq 0 ]
  # shellcheck disable=SC2154
  run grep -E 'if.*current_status.*review|status.*=.*review.*then' <<<"$output"
  [ "$status" -ne 0 ]
}

# -- AC3: active sprint, no sentinel, --force => closes + records bypass (AC3) --

@test "active sprint with no sentinel closes with --force and records bypass (AC3)" {
  _seed_yaml "sprint-70" "active" 3 3
  _seed_retro "sprint-70"
  run "$CLOSE_SH" --force
  [ "$status" -eq 0 ]
  [ "$(_yaml_status)" = "closed" ]
  # The bypass must be recorded in the close-summary file.
  local summary
  summary="$(find "$ARCHIVE" -name '*close-summary*' -type f 2>/dev/null | head -1)"
  [ -n "$summary" ]
  [[ "$(cat "$summary")" == *"--force"* ]]
}

# -- AC4: active sprint, sentinel present, no --force => closes normally (AC4) --

@test "active sprint with sentinel present closes without --force (AC4)" {
  _seed_yaml "sprint-70" "active" 3 3
  _seed_retro "sprint-70"
  _seed_sentinel "sprint-70"
  run "$CLOSE_SH"
  [ "$status" -eq 0 ]
  [ "$(_yaml_status)" = "closed" ]
}

# -- Review sprint, sentinel present, no --force => closes normally --

@test "review sprint with sentinel present closes without --force" {
  _seed_yaml "sprint-70" "review" 3 3
  _seed_retro "sprint-70"
  _seed_sentinel "sprint-70"
  run "$CLOSE_SH"
  [ "$status" -eq 0 ]
  [ "$(_yaml_status)" = "closed" ]
}

# -- --force and --force-with-rollover coexist independently --

@test "--force and --force-with-rollover coexist independently" {
  _seed_yaml "sprint-70" "active" 2 3
  _seed_retro "sprint-70"
  run "$CLOSE_SH" --force --force-with-rollover "S3"
  [ "$status" -eq 0 ]
  [ "$(_yaml_status)" = "closed" ]
}

# -- --force on a review sprint with no sentinel also closes --

@test "review sprint with no sentinel closes with --force and records bypass" {
  _seed_yaml "sprint-70" "review" 3 3
  _seed_retro "sprint-70"
  run "$CLOSE_SH" --force
  [ "$status" -eq 0 ]
  [ "$(_yaml_status)" = "closed" ]
  local summary
  summary="$(find "$ARCHIVE" -name '*close-summary*' -type f 2>/dev/null | head -1)"
  [ -n "$summary" ]
  [[ "$(cat "$summary")" == *"--force"* ]]
}
