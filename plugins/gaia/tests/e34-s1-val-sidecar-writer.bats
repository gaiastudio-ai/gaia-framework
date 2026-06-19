#!/usr/bin/env bats
# e34-s1-val-sidecar-writer.bats
#
# Integration coverage for val-sidecar-write.sh (Shared Val Sidecar Writer,
# architecture §10.10, FR-VSP-1, FR-VSP-2, NFR-VSP-2).
#
# Covers TC-VSP-1 (happy path ADR-016 entry), TC-VSP-2 (idempotency),
# TC-VSP-3 (allowlist rejection), AC5 (cross-file tagging), plus guard tests
# for symlink traversal and sprint degradation.
#
# Perf (TC-VSP-7) lives in e34-s1-val-sidecar-perf.bats.
# Unit coverage (NFR-052 gate) lives in e34-s1-val-sidecar-writer-units.bats.

load 'test_helper.bash'

setup() {
  common_setup
  # Build a fake project root with the required directories.
  PROJECT_ROOT="$TEST_TMP/proj"
  mkdir -p "$PROJECT_ROOT/.gaia/memory/validator-sidecar"
  export PROJECT_ROOT
}

teardown() { common_teardown; }

SCRIPT="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/val-sidecar-write.sh"

# ---------------------------------------------------------------------------
# TC-VSP-1 — Happy path ADR-016 entry
# ---------------------------------------------------------------------------

@test "writes entry with standardized header" {
  local payload='{"verdict":"passed","findings":[],"artifact_path":"docs/x.md"}'
  run "$SCRIPT" \
    --root "$PROJECT_ROOT" \
    --command-name "/gaia-create-story" \
    --input-id "E99-S1" \
    --decision-payload "$payload" \
    --sprint-id "sprint-26"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=written"* ]]
  # Entry body contains ADR-016 header fields.
  local log="$PROJECT_ROOT/.gaia/memory/validator-sidecar/decision-log.md"
  [ -f "$log" ]
  grep -q "agent: val" "$log"
  grep -q "sprint: sprint-26" "$log"
  grep -q "status: recorded" "$log"
  grep -q "command: /gaia-create-story" "$log"
  grep -q "input_id: E99-S1" "$log"
  grep -q "<!-- dedup_key: " "$log"
}

# ---------------------------------------------------------------------------
# TC-VSP-2 — Idempotency: identical payload produces no duplicate
# ---------------------------------------------------------------------------

@test "identical command+input+decision_hash does not duplicate" {
  local payload='{"verdict":"passed","findings":[{"id":"F1","msg":"ok"}],"artifact_path":"docs/y.md"}'
  run "$SCRIPT" --root "$PROJECT_ROOT" --command-name "/gaia-validate-story" \
    --input-id "E99-S2" --decision-payload "$payload" --sprint-id "sprint-26"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=written"* ]]
  local before; before=$(wc -c <"$PROJECT_ROOT/.gaia/memory/validator-sidecar/decision-log.md")
  run "$SCRIPT" --root "$PROJECT_ROOT" --command-name "/gaia-validate-story" \
    --input-id "E99-S2" --decision-payload "$payload" --sprint-id "sprint-26"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=skipped_duplicate"* ]]
  local after; after=$(wc -c <"$PROJECT_ROOT/.gaia/memory/validator-sidecar/decision-log.md")
  [ "$before" -eq "$after" ]
}

@test "findings order independence — same set, different order, same dedup_key" {
  local p1='{"verdict":"passed","findings":[{"id":"F1","msg":"a"},{"id":"F2","msg":"b"}],"artifact_path":"docs/z.md"}'
  local p2='{"verdict":"passed","findings":[{"id":"F2","msg":"b"},{"id":"F1","msg":"a"}],"artifact_path":"docs/z.md"}'
  run "$SCRIPT" --root "$PROJECT_ROOT" --command-name "/gaia-retro" \
    --input-id "sprint-26" --decision-payload "$p1" --sprint-id "sprint-26"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=written"* ]]
  run "$SCRIPT" --root "$PROJECT_ROOT" --command-name "/gaia-retro" \
    --input-id "sprint-26" --decision-payload "$p2" --sprint-id "sprint-26"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=skipped_duplicate"* ]]
}

# ---------------------------------------------------------------------------
# TC-VSP-3 — Allowlist rejection
# ---------------------------------------------------------------------------

@test "rejects write to path outside 2-file allowlist" {
  local payload='{"verdict":"passed","findings":[],"artifact_path":"x"}'
  run "$SCRIPT" --root "$PROJECT_ROOT" --command-name "/gaia-create-story" \
    --input-id "E99-S3" --decision-payload "$payload" --sprint-id "sprint-26" \
    --target "$PROJECT_ROOT/evil.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"status=rejected"* || "$stderr" == *"status=rejected"* ]]
  [ ! -e "$PROJECT_ROOT/evil.md" ]
}

@test "rejects sidecar-file-sibling paths outside validator-sidecar" {
  local payload='{"verdict":"passed","findings":[],"artifact_path":"x"}'
  mkdir -p "$PROJECT_ROOT/.gaia/memory/sm-sidecar"
  run "$SCRIPT" --root "$PROJECT_ROOT" --command-name "/gaia-create-story" \
    --input-id "E99-S3" --decision-payload "$payload" --sprint-id "sprint-26" \
    --target "$PROJECT_ROOT/.gaia/memory/sm-sidecar/decision-log.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"status=rejected"* || "$stderr" == *"status=rejected"* ]]
}

@test "rejects symlink traversal escaping validator-sidecar" {
  local payload='{"verdict":"passed","findings":[],"artifact_path":"x"}'
  local outside="$TEST_TMP/outside.md"; : > "$outside"
  # Create a symlink inside validator-sidecar/ that points outside.
  ln -s "$outside" "$PROJECT_ROOT/.gaia/memory/validator-sidecar/decision-log.md"
  run "$SCRIPT" --root "$PROJECT_ROOT" --command-name "/gaia-create-story" \
    --input-id "E99-S3" --decision-payload "$payload" --sprint-id "sprint-26"
  [ "$status" -ne 0 ]
  [[ "$output" == *"status=rejected"* || "$stderr" == *"status=rejected"* ]]
  # The decoy file outside the allowlist must be unchanged (still empty).
  [ ! -s "$outside" ]
}

# ---------------------------------------------------------------------------
# AC5 — Cross-file tagging between decision-log and conversation-context
# ---------------------------------------------------------------------------

@test "conversation-context gains a session block tagged with command_name + input_id" {
  local payload='{"verdict":"passed","findings":[],"artifact_path":"docs/ctx.md"}'
  run "$SCRIPT" --root "$PROJECT_ROOT" --command-name "/gaia-create-story" \
    --input-id "E99-S4" --decision-payload "$payload" --sprint-id "sprint-26"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=written"* ]]
  local ctx="$PROJECT_ROOT/.gaia/memory/validator-sidecar/conversation-context.md"
  [ -f "$ctx" ]
  grep -q "command: /gaia-create-story" "$ctx"
  grep -q "input_id: E99-S4" "$ctx"
}

@test "conversation-context header above first --- is preserved on subsequent writes" {
  local ctx="$PROJECT_ROOT/.gaia/memory/validator-sidecar/conversation-context.md"
  cat > "$ctx" <<'EOF'
# Val Validator — Conversation Context

> Rolling summary of the most recent validation session.

---

(old body)
EOF
  local header_before
  header_before="$(awk '/^---$/{exit} {print}' "$ctx")"
  local payload='{"verdict":"passed","findings":[],"artifact_path":"docs/ctx.md"}'
  run "$SCRIPT" --root "$PROJECT_ROOT" --command-name "/gaia-retro" \
    --input-id "sprint-26" --decision-payload "$payload" --sprint-id "sprint-26"
  [ "$status" -eq 0 ]
  local header_after
  header_after="$(awk '/^---$/{exit} {print}' "$ctx")"
  [ "$header_before" = "$header_after" ]
}

# ---------------------------------------------------------------------------
# Sprint degradation
# ---------------------------------------------------------------------------

@test "sprint degradation: missing --sprint-id records sprint: N/A" {
  local payload='{"verdict":"passed","findings":[],"artifact_path":"docs/x.md"}'
  run "$SCRIPT" --root "$PROJECT_ROOT" --command-name "/gaia-sprint-plan" \
    --input-id "sprint-nil" --decision-payload "$payload"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=written"* ]]
  grep -q "sprint: N/A" "$PROJECT_ROOT/.gaia/memory/validator-sidecar/decision-log.md"
}

# ---------------------------------------------------------------------------
# Contract — stdout protocol
# ---------------------------------------------------------------------------

@test "stdout includes dedup_key on successful write" {
  local payload='{"verdict":"passed","findings":[],"artifact_path":"docs/x.md"}'
  run "$SCRIPT" --root "$PROJECT_ROOT" --command-name "/gaia-triage-findings" \
    --input-id "TR-1" --decision-payload "$payload" --sprint-id "sprint-26"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dedup_key="* ]]
}

@test "rejects missing required args with clear error" {
  run "$SCRIPT" --root "$PROJECT_ROOT" --command-name "/gaia-create-story"
  [ "$status" -ne 0 ]
  [[ "$output" == *"required"* || "$stderr" == *"required"* ]]
}
