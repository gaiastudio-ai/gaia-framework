#!/usr/bin/env bats
# sprint-close-yq-fallback-and-dual-event.bats
#
# Pins two contracts:
#   1. The direct-yq fallback in close.sh fires when sprint-state.sh refuses
#      a non-sentinel transition (e.g. active->closed is not a legal edge).
#   2. The sprint-close ceremony emits two distinct lifecycle events:
#      sprint_closed (domain, from close.sh) and workflow_complete (generic,
#      from finalize.sh). Both are intentional and serve different consumers.

load 'test_helper.bash'

SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-sprint-close"
CLOSE_SH="$SKILL_DIR/scripts/close.sh"
FINALIZE_SH="$SKILL_DIR/scripts/finalize.sh"
SPRINT_CLOSE_SKILL="$SKILL_DIR/SKILL.md"

setup() {
  common_setup
  export PROJECT_PATH="$TEST_TMP"
  export MEMORY_PATH="$TEST_TMP/.gaia/memory"
  CKPT_DIR="$MEMORY_PATH/checkpoints"
  ART="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  ARCHIVE="$ART/sprint-archive"
  YAML="$TEST_TMP/.gaia/state/sprint-status.yaml"
  LIFECYCLE="$MEMORY_PATH/lifecycle-events.jsonl"
  export SPRINT_STATUS_YAML="$YAML"
  export GAIA_SPRINT_CLOSE_DATE="2026-06-25"
  mkdir -p "$(dirname "$YAML")" "$ART" "$MEMORY_PATH" "$CKPT_DIR"
}

teardown() { common_teardown; }

# ---------- Fixture helpers ----------

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
  touch "$ART/retrospective-${sprint_id}-2026-06-25.md"
}

_seed_sentinel() {
  local sprint_id="$1"
  mkdir -p "$CKPT_DIR"
  cat > "$CKPT_DIR/sprint-review-${sprint_id}-val-dispatched.json" <<EOF
{"agent":"val","status":"PASSED","summary":"ok","findings":[]}
EOF
}

_yaml_status() {
  grep '^status:' "$YAML" 2>/dev/null | head -1 | sed 's/^status:[[:space:]]*//' | tr -d '"' || true
}

# Build a fake plugin tree mirroring the real directory layout so finalize.sh's
# relative-path resolution (../../../scripts) works. Stubs out checkpoint.sh,
# lifecycle-event.sh, ground-truth-gate.sh, and brain-reindex.sh.
# Prints the path to the fake finalize.sh on stdout.
_build_finalize_harness() {
  local base="$TEST_TMP/fake-plugin/plugins/gaia"
  local skill_scripts="$base/skills/gaia-sprint-close/scripts"
  local plugin_scripts="$base/scripts"
  mkdir -p "$skill_scripts" "$plugin_scripts/lib" "$plugin_scripts/brain"

  cp "$FINALIZE_SH" "$skill_scripts/finalize.sh"
  chmod +x "$skill_scripts/finalize.sh"

  # checkpoint.sh — no-op.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$plugin_scripts/checkpoint.sh"
  chmod +x "$plugin_scripts/checkpoint.sh"

  # lifecycle-event.sh — write event to JSONL.
  cat > "$plugin_scripts/lifecycle-event.sh" <<'STUB'
#!/usr/bin/env bash
event_type="" workflow="" data="{}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --type) event_type="$2"; shift 2 ;;
    --workflow) workflow="$2"; shift 2 ;;
    --data) data="$2"; shift 2 ;;
    *) shift ;;
  esac
done
memory="${MEMORY_PATH:-.gaia/memory}"
mkdir -p "$memory"
printf '{"event_type":"%s","workflow":"%s","data":%s}\n' \
  "$event_type" "$workflow" "$data" >> "$memory/lifecycle-events.jsonl"
STUB
  chmod +x "$plugin_scripts/lifecycle-event.sh"

  # ground-truth-gate.sh — no-op function.
  printf 'gt_gate_best_effort() { return 0; }\n' > "$plugin_scripts/lib/ground-truth-gate.sh"

  # brain-reindex.sh — no-op.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$plugin_scripts/brain/gaia-brain-reindex.sh"
  chmod +x "$plugin_scripts/brain/gaia-brain-reindex.sh"

  printf '%s' "$skill_scripts/finalize.sh"
}

# ============================================================================
# Sub-item (c): direct-yq fallback contract
# ============================================================================

# -- Behavior pin: when sprint-state.sh refuses for a non-sentinel reason,
#    close.sh falls back to direct yq and produces a valid close. --

@test "direct-yq fallback fires when sprint-state.sh refuses non-sentinel transition (AC1)" {
  # Create a stub sprint-state.sh that exits non-zero with benign stderr
  # (no sentinel-refusal substring).
  local stub_dir="$TEST_TMP/stubs"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/sprint-state.sh" <<'STUB'
#!/usr/bin/env bash
echo "transition refused: active to closed is not a legal edge" >&2
exit 1
STUB
  chmod +x "$stub_dir/sprint-state.sh"
  export SPRINT_STATE_SH="$stub_dir/sprint-state.sh"

  _seed_yaml "sprint-80" "active" 3 3
  _seed_retro "sprint-80"
  _seed_sentinel "sprint-80"

  run "$CLOSE_SH"
  [ "$status" -eq 0 ]
  [ "$(_yaml_status)" = "closed" ]
  # closed_at must be set.
  grep -q '^closed_at:' "$YAML"
  # Lifecycle event must still be emitted by close.sh itself.
  [ -f "$LIFECYCLE" ]
  grep -q '"event_type":"sprint_closed"' "$LIFECYCLE"
}

@test "direct-yq fallback fires when sprint-state.sh is absent (AC1)" {
  # Point at a non-existent path.
  export SPRINT_STATE_SH="/nonexistent/sprint-state.sh"

  _seed_yaml "sprint-80" "active" 3 3
  _seed_retro "sprint-80"
  _seed_sentinel "sprint-80"

  run "$CLOSE_SH"
  [ "$status" -eq 0 ]
  [ "$(_yaml_status)" = "closed" ]
  grep -q '^closed_at:' "$YAML"
}

# -- Documentation pin: SKILL.md documents the fallback conditions. --

@test "SKILL.md documents the direct-yq fallback contract (AC1)" {
  [ -f "$SPRINT_CLOSE_SKILL" ]
  # The SKILL.md must explain when the fallback fires.
  grep -qE 'fallback|direct.*yq|active.*closed' "$SPRINT_CLOSE_SKILL"
  # The SKILL.md must mention the sentinel gate passes before the fallback.
  grep -qE 'sentinel.*gate.*pass|sentinel.*already|sentinel.*before' "$SPRINT_CLOSE_SKILL"
}

# -- Code-comment pin: close.sh documents the fallback rationale inline. --

@test "close.sh documents the fallback rationale in code comments (AC1)" {
  [ -f "$CLOSE_SH" ]
  # The fallback section must explain the sentinel gate precondition.
  grep -qE 'sentinel.*gate.*already|sentinel.*already.*ran|sentinel.*passed' "$CLOSE_SH"
  # The fallback section must name the specific case (active->closed not legal).
  grep -qE 'active.*closed.*not.*legal|not.*legal.*edge' "$CLOSE_SH"
}

# ============================================================================
# Sub-item (e): dual terminal lifecycle event contract
# ============================================================================

# -- Behavior pin: close.sh emits sprint_closed. --

@test "close.sh emits sprint_closed event (AC2)" {
  export SPRINT_STATE_SH="/nonexistent/sprint-state.sh"

  _seed_yaml "sprint-80" "active" 3 3
  _seed_retro "sprint-80"
  _seed_sentinel "sprint-80"

  run "$CLOSE_SH"
  [ "$status" -eq 0 ]
  [ -f "$LIFECYCLE" ]
  grep -q '"event_type":"sprint_closed"' "$LIFECYCLE"
  grep -q '"workflow":"gaia-sprint-close"' "$LIFECYCLE"
}

# -- Behavior pin: finalize.sh emits workflow_complete. --

@test "finalize.sh emits workflow_complete event (AC2)" {
  local fake_finalize
  fake_finalize="$(_build_finalize_harness)"

  run bash "$fake_finalize"
  [ "$status" -eq 0 ]
  [ -f "$LIFECYCLE" ]
  grep -q '"event_type":"workflow_complete"' "$LIFECYCLE"
  grep -q '"workflow":"sprint-close"' "$LIFECYCLE"
}

# -- Behavior pin: both events fire in a full ceremony. --

@test "close ceremony emits both sprint_closed and workflow_complete (AC2)" {
  export SPRINT_STATE_SH="/nonexistent/sprint-state.sh"

  _seed_yaml "sprint-80" "active" 3 3
  _seed_retro "sprint-80"
  _seed_sentinel "sprint-80"

  # Run close.sh (emits sprint_closed).
  run "$CLOSE_SH"
  [ "$status" -eq 0 ]

  # Run finalize.sh via the harness (emits workflow_complete).
  local fake_finalize
  fake_finalize="$(_build_finalize_harness)"
  run bash "$fake_finalize"
  [ "$status" -eq 0 ]

  # Both events must be present.
  [ -f "$LIFECYCLE" ]
  local sprint_closed_count workflow_complete_count
  sprint_closed_count=$(grep -c '"event_type":"sprint_closed"' "$LIFECYCLE" || true)
  workflow_complete_count=$(grep -c '"event_type":"workflow_complete"' "$LIFECYCLE" || true)
  [ "$sprint_closed_count" -eq 1 ]
  [ "$workflow_complete_count" -eq 1 ]
}

# -- Documentation pin: SKILL.md documents the two-event contract. --

@test "SKILL.md documents the two-event lifecycle contract (AC2)" {
  [ -f "$SPRINT_CLOSE_SKILL" ]
  # Must document that sprint_closed is the domain event.
  grep -qE 'sprint_closed.*domain|domain.*sprint_closed' "$SPRINT_CLOSE_SKILL"
  # Must document that workflow_complete is the generic lifecycle event.
  grep -qE 'workflow_complete.*generic|generic.*workflow_complete' "$SPRINT_CLOSE_SKILL"
  # Must state they are intentionally distinct.
  grep -qiE 'intentionally.*distinct|two.*event|dual.*event|both.*event' "$SPRINT_CLOSE_SKILL"
}

# ============================================================================
# Sprint-id mismatch dispatch in close.sh
# ============================================================================

@test "close.sh stops on a sprint-id mismatch refusal (exit 2 with mismatch phrase)" {
  local stub_dir="$TEST_TMP/stubs"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/sprint-state.sh" <<'STUB'
#!/usr/bin/env bash
printf "transition: --sprint 'sprint-1' does not match active sprint-status.yaml sprint_id 'sprint-80'\n" >&2
exit 2
STUB
  chmod +x "$stub_dir/sprint-state.sh"
  export SPRINT_STATE_SH="$stub_dir/sprint-state.sh"

  _seed_yaml "sprint-80" "review" 3 3
  _seed_retro "sprint-80"
  _seed_sentinel "sprint-80"

  run "$CLOSE_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sprint-1"* ]]
  [[ "$output" == *"sprint-80"* ]]
  [[ "$output" == *"does not match active sprint-status.yaml sprint_id"* ]]
  # Must NOT contain the generic "transition failed" message — the mismatch
  # branch propagates the writer's message directly, not via die().
  local tf_count
  tf_count="$(printf '%s\n' "$output" | grep -c 'transition failed' || true)"
  [ "$tf_count" -eq 0 ]
  # Status must stay review — close.sh must not write anything
  [ "$(_yaml_status)" = "review" ]
  # No archive should have been written
  if [ -d "${ARCHIVE:-$ART/sprint-archive}" ]; then
    local archive_count
    archive_count="$(find "${ARCHIVE:-$ART/sprint-archive}" -type f | wc -l)"
    [ "$archive_count" -eq 0 ]
  fi
}

@test "close.sh stops on exit 2 without the mismatch phrase (generic message)" {
  local stub_dir="$TEST_TMP/stubs"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/sprint-state.sh" <<'STUB'
#!/usr/bin/env bash
printf 'syntax error near line 42\n' >&2
exit 2
STUB
  chmod +x "$stub_dir/sprint-state.sh"
  export SPRINT_STATE_SH="$stub_dir/sprint-state.sh"

  _seed_yaml "sprint-80" "review" 3 3
  _seed_retro "sprint-80"
  _seed_sentinel "sprint-80"

  run "$CLOSE_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"transition failed"* ]]
  # Must NOT contain the mismatch phrase
  local mismatch_count
  mismatch_count="$(printf '%s\n' "$output" | grep -c 'does not match' || true)"
  [ "$mismatch_count" -eq 0 ]
  # Status must stay review
  [ "$(_yaml_status)" = "review" ]
}

@test "close.sh closes a single-quoted sprint_id yaml without mismatch" {
  # Seed yaml with single-quoted sprint_id — close.sh must strip single
  # quotes so the id matches what sprint-state.sh reads.
  mkdir -p "$(dirname "$YAML")"
  {
    printf "sprint_id: 'sprint-80'\n"
    printf 'status: review\n'
    printf 'total_points: 9\n'
    printf 'stories:\n'
    printf '  - key: "S1"\n    status: done\n    points: 3\n    risk: medium\n'
    printf '  - key: "S2"\n    status: done\n    points: 3\n    risk: medium\n'
    printf '  - key: "S3"\n    status: done\n    points: 3\n    risk: medium\n'
  } > "$YAML"
  _seed_retro "sprint-80"
  _seed_sentinel "sprint-80"

  export SPRINT_STATE_SH="$BATS_TEST_DIRNAME/../scripts/sprint-state.sh"
  run "$CLOSE_SH" --force
  [ "$status" -eq 0 ]
  [ "$(_yaml_status)" = "closed" ]
  grep -q '^closed_at:' "$YAML"
}

# ============================================================================
# Path resolution: close.sh finds sprint-state.sh via dirname "$0"
# ============================================================================

@test "close.sh finds sprint-state.sh from the source layout (no SPRINT_STATE_SH, no CLAUDE_PLUGIN_ROOT)" {
  # When both SPRINT_STATE_SH and CLAUDE_PLUGIN_ROOT are unset, close.sh
  # resolves sprint-state.sh via dirname "$0"/../../.. which must reach
  # plugins/gaia/ then /scripts/sprint-state.sh.  If the path is correct
  # the real transition runs and emits a sprint_transitioned lifecycle event.
  # The yq fallback does NOT emit that event.
  unset SPRINT_STATE_SH
  unset CLAUDE_PLUGIN_ROOT

  _seed_yaml "sprint-80" "review" 3 3
  _seed_retro "sprint-80"
  _seed_sentinel "sprint-80"

  run "$CLOSE_SH" --force
  [ "$status" -eq 0 ]
  [ "$(_yaml_status)" = "closed" ]
  grep -q '^closed_at:' "$YAML"

  # Observable: the real transition emits sprint_transitioned.
  # The yq fallback (broken path) would NOT produce this event.
  [ -f "$LIFECYCLE" ]
  grep -q '"event_type":"sprint_transitioned"' "$LIFECYCLE"
  grep -q '"from":"review"' "$LIFECYCLE"
  grep -q '"to":"closed"' "$LIFECYCLE"
}

@test "close.sh finds sprint-state.sh via CLAUDE_PLUGIN_ROOT when set" {
  # Run a COPY of close.sh from an isolated tree where the dirname-relative
  # path has lifecycle-event.sh (close.sh needs it) but NO sprint-state.sh.
  # CLAUDE_PLUGIN_ROOT must supply the sprint-state.sh scripts path.
  # Without the CLAUDE_PLUGIN_ROOT branch the dirname fallback finds no
  # sprint-state.sh and the test fails (the mutant the test kills).
  unset SPRINT_STATE_SH

  local real_scripts="$BATS_TEST_DIRNAME/../scripts"
  local real_skill_scripts="$BATS_TEST_DIRNAME/../skills/gaia-sprint-close/scripts"

  # 1. Build the isolated close.sh tree with its dirname-relative deps but
  #    WITHOUT sprint-state.sh — only lifecycle-event.sh (close.sh line 25-26).
  local iso_root="$TEST_TMP/isolated-root"
  local iso_skill="$iso_root/skills/gaia-sprint-close/scripts"
  mkdir -p "$iso_skill" "$iso_root/scripts"
  cp "$real_skill_scripts/close.sh" "$iso_skill/close.sh"
  chmod +x "$iso_skill/close.sh"
  # close.sh line 25: PLUGIN_SCRIPTS_DIR = dirname/$SCRIPT_DIR/../../../scripts
  cp "$real_scripts/lifecycle-event.sh" "$iso_root/scripts/"
  chmod +x "$iso_root/scripts/lifecycle-event.sh"

  # 2. Build a separate custom plugin root WITH the full scripts tree.
  local plugin_root="$TEST_TMP/custom-plugin-root"
  mkdir -p "$plugin_root/scripts/lib"
  cp "$real_scripts/sprint-state.sh"             "$plugin_root/scripts/"
  cp "$real_scripts/lifecycle-event.sh"           "$plugin_root/scripts/"
  cp "$real_scripts/lib/story-state-machine.sh"   "$plugin_root/scripts/lib/"
  cp "$real_scripts/lib/acquire-lock.sh"           "$plugin_root/scripts/lib/"
  chmod +x "$plugin_root/scripts/sprint-state.sh" \
           "$plugin_root/scripts/lifecycle-event.sh"

  # 3. Point CLAUDE_PLUGIN_ROOT at the custom root.
  export CLAUDE_PLUGIN_ROOT="$plugin_root"

  _seed_yaml "sprint-80" "review" 3 3
  _seed_retro "sprint-80"
  _seed_sentinel "sprint-80"

  run "$iso_skill/close.sh" --force
  [ "$status" -eq 0 ]
  [ "$(_yaml_status)" = "closed" ]
  grep -q '^closed_at:' "$YAML"

  # Observable: the real transition emits sprint_transitioned.
  [ -f "$LIFECYCLE" ]
  grep -q '"event_type":"sprint_transitioned"' "$LIFECYCLE"
  grep -q '"from":"review"' "$LIFECYCLE"
  grep -q '"to":"closed"' "$LIFECYCLE"
}
