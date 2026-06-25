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
