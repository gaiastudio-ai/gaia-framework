#!/usr/bin/env bats
# gaia-sprint-close.bats — TC-SPRINT-CLOSE-1..8 (E81-S5).
#
# End-to-end coverage for the /gaia-sprint-close skill's finalize.sh:
# close + archive + lifecycle event + refuse paths + idempotency + backward-compat.
#
# Stories: TC-SPRINT-CLOSE-1..8 mapping to E81-S5 ACs 1-7 + ADR-095 backward-compat.
# All Tier 1 (bats). All MUST-PASS.
#
# Bats file co-located per test-plan §11.65.1.
# Lifecycle event schema follows the nested-`data` convention enforced by
# lifecycle-event.sh (ADR-095 §Component 5, amended in this story).

load 'test_helper.bash'

SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-sprint-close"
FINALIZE="$SKILL_DIR/scripts/close.sh"

setup() {
  common_setup
  export PROJECT_PATH="$TEST_TMP"
  export MEMORY_PATH="$TEST_TMP/_memory"
  ART="$TEST_TMP/docs/implementation-artifacts"
  ARCHIVE="$ART/sprint-archive"
  YAML="$ART/sprint-status.yaml"
  LIFECYCLE="$MEMORY_PATH/lifecycle-events.jsonl"
  # Point sprint-state.sh's canonical lookup at the test yaml.
  export SPRINT_STATUS_YAML="$YAML"
  # Force a stable close-date for predictable archive filenames in tests.
  export GAIA_SPRINT_CLOSE_DATE="2026-05-11"
  mkdir -p "$ART" "$MEMORY_PATH"
}
teardown() { common_teardown; }

# ---------- Fixture helpers ----------

# Seed a sprint-status.yaml with the given status field and story entries.
# Usage: seed_yaml <sprint_id> <status|""> <stories_done> <stories_total>
seed_yaml() {
  local sprint_id="$1" status="$2" stories_done="$3" total="$4"
  mkdir -p "$(dirname "$YAML")"
  {
    echo "sprint_id: \"$sprint_id\""
    if [ -n "$status" ]; then
      echo "status: $status"
      if [ "$status" = "closed" ]; then
        echo "closed_at: \"2026-05-11T10:00:00Z\""
      fi
    fi
    echo "total_points: $((total * 3))"
    echo "stories:"
    local i
    for i in $(seq 1 "$total"); do
      local s="done"
      [ "$i" -gt "$stories_done" ] && s="in-progress"
      echo "  - key: \"E81-S$i\""
      echo "    status: $s"
      echo "    points: 3"
      echo "    risk: medium"
    done
  } > "$YAML"
}

seed_retro() {
  local sprint_id="$1"
  touch "$ART/retrospective-${sprint_id}-2026-05-11.md"
}

# Read the top-level yaml `status:` field (or empty string).
yaml_status() { grep '^status:' "$YAML" 2>/dev/null | head -1 | sed 's/^status:[[:space:]]*//' | tr -d '"' || true; }

# Cross-platform mtime probe (macOS BSD stat vs GNU stat).
mtime() {
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null
}

# ---------- TC-SPRINT-CLOSE-1: Happy-path close (AC1) ----------

@test "TC-SPRINT-CLOSE-1: happy-path close writes status:closed + closed_at to yaml" {
  seed_yaml "sprint-41" "active" 3 3
  seed_retro "sprint-41"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
  [ "$(yaml_status)" = "closed" ]
  run grep '^closed_at:' "$YAML"
  [ "$status" -eq 0 ]
}

# ---------- TC-SPRINT-CLOSE-2: Archive copy at canonical path (AC2) ----------

@test "TC-SPRINT-CLOSE-2: archive copy lands at sprint-archive/{id}-closed-{date}.yaml" {
  seed_yaml "sprint-41" "active" 3 3
  seed_retro "sprint-41"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
  local expected="$ARCHIVE/sprint-41-closed-2026-05-11.yaml"
  [ -f "$expected" ]
  run grep '^status: closed' "$expected"
  [ "$status" -eq 0 ]
}

# ---------- TC-SPRINT-CLOSE-3: Lifecycle event new-file + append (AC3) ----------

@test "TC-SPRINT-CLOSE-3a: lifecycle event creates the jsonl when absent" {
  seed_yaml "sprint-41" "active" 3 3
  seed_retro "sprint-41"
  [ ! -f "$LIFECYCLE" ]
  run "$FINALIZE"
  [ "$status" -eq 0 ]
  [ -f "$LIFECYCLE" ]
  run grep -c '"event_type":"sprint_closed"' "$LIFECYCLE"
  [ "$output" -eq 1 ]
}

@test "TC-SPRINT-CLOSE-3b: lifecycle event appends to existing jsonl preserving prior lines" {
  printf '%s\n' '{"event_type":"story_created","story_key":"E1-S1"}' > "$LIFECYCLE"
  printf '%s\n' '{"event_type":"sprint_started","sprint_id":"sprint-41"}' >> "$LIFECYCLE"
  seed_yaml "sprint-41" "active" 3 3
  seed_retro "sprint-41"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
  run wc -l < "$LIFECYCLE"
  [ "$output" -eq 3 ]
  run tail -1 "$LIFECYCLE"
  [[ "$output" == *'"event_type":"sprint_closed"'* ]]
}

@test "TC-SPRINT-CLOSE-3c: lifecycle event nested-data carries all required fields" {
  seed_yaml "sprint-41" "active" 3 3
  seed_retro "sprint-41"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
  local line
  line=$(tail -1 "$LIFECYCLE")
  # Required fields per AC3 (nested under data per ADR-095 §Component 5 amendment).
  [[ "$line" == *'"event_type":"sprint_closed"'* ]]
  [[ "$line" == *'"sprint_id":"sprint-41"'* ]]
  [[ "$line" == *'"closed_at":'* ]]
  [[ "$line" == *'"total_points":9'* ]]
  [[ "$line" == *'"stories_done":3'* ]]
  [[ "$line" == *'"stories_rolled_over":[]'* ]]
  [[ "$line" == *'"rollover_target_sprint":null'* ]]
}

# ---------- TC-SPRINT-CLOSE-4: Refuse without retro (AC4) ----------

@test "TC-SPRINT-CLOSE-4: refuses when retro doc absent, no yaml mutation" {
  seed_yaml "sprint-41" "active" 3 3
  # Deliberately do NOT seed_retro
  local mtime_before
  mtime_before=$(mtime "$YAML")
  [ -x "$FINALIZE" ]
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  # $output captures stdout+stderr combined under default `run`.
  [[ "$output" == *"retro doc not found for sprint-41"* ]]
  [[ "$output" == *"/gaia-retro"* ]]
  [ "$(yaml_status)" = "active" ]
  local mtime_after
  mtime_after=$(mtime "$YAML")
  [ "$mtime_before" = "$mtime_after" ]
  [ ! -f "$LIFECYCLE" ]
}

# ---------- TC-SPRINT-CLOSE-5: Refuse non-done without force (AC5) ----------

@test "TC-SPRINT-CLOSE-5: refuses when non-done stories present without --force-with-rollover" {
  seed_yaml "sprint-41" "active" 2 3
  seed_retro "sprint-41"
  local mtime_before
  mtime_before=$(mtime "$YAML")
  [ -x "$FINALIZE" ]
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  # Must list the non-done story key.
  [[ "$output" == *"E81-S3"* ]]
  [ "$(yaml_status)" = "active" ]
  local mtime_after
  mtime_after=$(mtime "$YAML")
  [ "$mtime_before" = "$mtime_after" ]
}

# ---------- TC-SPRINT-CLOSE-6: Force-with-rollover (AC6) ----------

@test "TC-SPRINT-CLOSE-6a: --force-with-rollover with exact non-done keys proceeds and records rollover" {
  seed_yaml "sprint-41" "active" 2 3
  seed_retro "sprint-41"
  run "$FINALIZE" --force-with-rollover "E81-S3"
  [ "$status" -eq 0 ]
  [ "$(yaml_status)" = "closed" ]
  local archive="$ARCHIVE/sprint-41-closed-2026-05-11.yaml"
  [ -f "$archive" ]
  run grep -F 'E81-S3' "$archive"
  [ "$status" -eq 0 ]
  local line
  line=$(tail -1 "$LIFECYCLE")
  [[ "$line" == *'"stories_rolled_over":["E81-S3"]'* ]]
}

@test "TC-SPRINT-CLOSE-6b: --force-with-rollover with wrong key refuses with mismatch error" {
  seed_yaml "sprint-41" "active" 2 3
  seed_retro "sprint-41"
  local mtime_before
  mtime_before=$(mtime "$YAML")
  [ -x "$FINALIZE" ]
  run "$FINALIZE" --force-with-rollover "E81-S2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mismatch"* ]] || [[ "$output" == *"E81-S3"* ]]
  [ "$(yaml_status)" = "active" ]
  local mtime_after
  mtime_after=$(mtime "$YAML")
  [ "$mtime_before" = "$mtime_after" ]
}

# ---------- TC-SPRINT-CLOSE-7: Idempotent re-close (AC7) ----------

@test "TC-SPRINT-CLOSE-7: idempotent re-close on already-closed sprint emits warning, no mutation, no new event" {
  seed_yaml "sprint-41" "closed" 3 3
  seed_retro "sprint-41"
  # Pre-record state. Use both content hash AND mtime — content hash is the
  # cross-platform invariant (Linux + macOS); mtime is a belt-and-braces check
  # that may be flaky on filesystems with second-resolution timestamps under
  # fast test-suite execution.
  local hash_before
  hash_before=$(shasum -a 256 "$YAML" 2>/dev/null | awk '{print $1}')
  [ -z "$hash_before" ] && hash_before=$(sha256sum "$YAML" | awk '{print $1}')
  # Pre-seed lifecycle file with a prior unrelated event to verify NO new event is appended.
  printf '%s\n' '{"event_type":"unrelated"}' > "$LIFECYCLE"
  local lc_count_before
  lc_count_before=$(wc -l < "$LIFECYCLE")
  run "$FINALIZE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already closed"* ]]
  [ "$(yaml_status)" = "closed" ]
  # Content invariant — yaml bytes are byte-identical pre/post idempotent re-close.
  local hash_after
  hash_after=$(shasum -a 256 "$YAML" 2>/dev/null | awk '{print $1}')
  [ -z "$hash_after" ] && hash_after=$(sha256sum "$YAML" | awk '{print $1}')
  [ "$hash_before" = "$hash_after" ]
  local lc_count_after
  lc_count_after=$(wc -l < "$LIFECYCLE")
  [ "$lc_count_before" = "$lc_count_after" ]
  # No new archive copy. Idempotent short-circuit means the archive dir may
  # not even exist; both "absent dir" and "empty dir" satisfy the AC.
  if [ -d "$ARCHIVE" ]; then
    run find "$ARCHIVE" -name 'sprint-41-closed-*.yaml' -type f
    [ -z "$output" ]
  fi
}

# ---------- TC-SPRINT-CLOSE-8: Backward-compat missing status field ----------

@test "TC-SPRINT-CLOSE-8: missing status field is treated as active, close proceeds" {
  mkdir -p "$(dirname "$YAML")"
  cat > "$YAML" <<'EOF'
sprint_id: "sprint-41"
total_points: 9
stories:
  - key: "E81-S1"
    status: done
    points: 3
    risk: medium
  - key: "E81-S2"
    status: done
    points: 3
    risk: medium
  - key: "E81-S3"
    status: done
    points: 3
    risk: medium
EOF
  seed_retro "sprint-41"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
  [ "$(yaml_status)" = "closed" ]
}
