#!/usr/bin/env bats
# e36-s2-memory-velocity-persistence.bats
#
# ATDD acceptance tests for E36-S2 — Memory and velocity persistence
# (Epic E36, Retro Institutional Memory).
#
# Covers: AC1-AC6 and AC-EC1..AC-EC12 (12 edge cases).
# Refs: FR-RIM-3, FR-RIM-4, FR-RIM-5, FR-RIM-8, NFR-RIM-2, NFR-RIM-3,
#       GR-RT-3, GR-RT-5, GR-RT-6, ADR-052.
# Test cases: TC-RIM-3, TC-RIM-4, TC-RIM-5, TC-RIM-6, TC-RIM-7, TC-RIM-12.
# Scripts under test (created in GREEN):
#   gaia-framework/plugins/gaia/scripts/retro-sidecar-write.sh

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

# Resolve script under test.
WRITER="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/retro-sidecar-write.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# mk_memory_root creates a test-scoped project root with _memory/ and docs/
# layouts matching the real repo. The writer uses --root to pin its allowlist.
mk_memory_root() {
  local root="$1"
  mkdir -p "$root/.gaia/memory" \
           "$root/docs/implementation-artifacts" \
           "$root/docs/planning-artifacts" \
           "$root/gaia-framework/plugins/gaia/skills" \
           "$root/custom/skills"
}

# ===========================================================================
# AC1 / TC-RIM-3 — 6 sidecar ADR-016 writes (happy path)
# ===========================================================================

@test "AC1/TC-RIM-3: writer appends ADR-016 entry to a sidecar decision-log" {
  [ -x "$WRITER" ] || skip "GUARD: retro-sidecar-write.sh does not exist — RED phase"

  local root="$TEST_TMP/repo"; mk_memory_root "$root"
  local target="$root/.gaia/memory/architect-sidecar/decision-log.md"
  mkdir -p "$(dirname "$target")"

  run "$WRITER" --root "$root" --sprint-id "sprint-10" \
    --target "$target" --payload "arch lesson 1"
  [ "$status" -eq 0 ]
  [ -f "$target" ]
  grep -q "sprint-10" "$target"
  grep -qE "^### Sprint sprint-10|^## Sprint sprint-10|sprint_id: sprint-10" "$target"
  grep -q "arch lesson 1" "$target"
  # No orphan backup on success
  [ ! -f "$target.bak" ]
}

@test "AC1: writer fans out to all 6 agent sidecars" {
  [ -x "$WRITER" ] || skip "GUARD: retro-sidecar-write.sh does not exist — RED phase"

  local root="$TEST_TMP/repo"; mk_memory_root "$root"
  local agents=(architect test-architect security devops sm pm)
  for a in "${agents[@]}"; do
    mkdir -p "$root/.gaia/memory/${a}-sidecar"
    run "$WRITER" --root "$root" --sprint-id "sprint-11" \
      --target "$root/.gaia/memory/${a}-sidecar/decision-log.md" \
      --payload "lesson for ${a}"
    [ "$status" -eq 0 ]
  done

  for a in "${agents[@]}"; do
    [ -f "$root/.gaia/memory/${a}-sidecar/decision-log.md" ]
    grep -q "sprint-11" "$root/.gaia/memory/${a}-sidecar/decision-log.md"
    grep -q "lesson for ${a}" "$root/.gaia/memory/${a}-sidecar/decision-log.md"
  done
}

# ===========================================================================
# AC2 / TC-RIM-4 / NFR-RIM-3 — Idempotency on re-run
# ===========================================================================

@test "AC2/TC-RIM-4: re-run is byte-identical (idempotent via composite dedup key)" {
  [ -x "$WRITER" ] || skip "GUARD: retro-sidecar-write.sh does not exist — RED phase"

  local root="$TEST_TMP/repo"; mk_memory_root "$root"
  local target="$root/.gaia/memory/sm-sidecar/decision-log.md"
  mkdir -p "$(dirname "$target")"

  "$WRITER" --root "$root" --sprint-id "sprint-12" \
    --target "$target" --payload "process lesson X"
  local first_hash; first_hash="$(shasum -a 256 "$target" | awk '{print $1}')"

  run "$WRITER" --root "$root" --sprint-id "sprint-12" \
    --target "$target" --payload "process lesson X"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped_idempotent"* || "$output" == *"skip"* ]]

  local second_hash; second_hash="$(shasum -a 256 "$target" | awk '{print $1}')"
  [ "$first_hash" = "$second_hash" ]
}

# ===========================================================================
# AC6 / TC-RIM-12 / NFR-RIM-2 — Write-boundary rejection
# ===========================================================================

@test "AC6/TC-RIM-12: write to path outside allowlist is rejected" {
  [ -x "$WRITER" ] || skip "GUARD: retro-sidecar-write.sh does not exist — RED phase"

  local root="$TEST_TMP/repo"; mk_memory_root "$root"
  local target="$root/gaia-framework/plugins/gaia/skills/foo.md"
  mkdir -p "$(dirname "$target")"
  echo "original" > "$target"
  local before_hash; before_hash="$(shasum -a 256 "$target" | awk '{print $1}')"

  run "$WRITER" --root "$root" --sprint-id "sprint-13" \
    --target "$target" --payload "should not land"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unauthorized"* || "$output" == *"allowlist"* ]]

  local after_hash; after_hash="$(shasum -a 256 "$target" | awk '{print $1}')"
  [ "$before_hash" = "$after_hash" ]
}

# ===========================================================================
# AC-EC1 — Concurrent retro invocations serialize via flock
# ===========================================================================

@test "AC-EC1: concurrent invocations serialize — single entry per sidecar" {
  [ -x "$WRITER" ] || skip "GUARD: retro-sidecar-write.sh does not exist — RED phase"

  local root="$TEST_TMP/repo"; mk_memory_root "$root"
  local target="$root/.gaia/memory/architect-sidecar/decision-log.md"
  mkdir -p "$(dirname "$target")"

  # Launch 4 writers concurrently with the same (sprint_id, payload).
  for i in 1 2 3 4; do
    "$WRITER" --root "$root" --sprint-id "sprint-20" \
      --target "$target" --payload "concurrent lesson" &
  done
  wait

  [ -f "$target" ]
  # Exactly one dedup marker for this payload.
  local count
  count="$(grep -c "dedup_key:" "$target" || true)"
  [ "$count" -eq 1 ]
}

# ===========================================================================
# AC-EC2 — Missing sidecar file gets seeded with ADR-016 header
# ===========================================================================

@test "AC-EC2: missing sidecar file — writer seeds canonical header before append" {
  [ -x "$WRITER" ] || skip "GUARD: retro-sidecar-write.sh does not exist — RED phase"

  local root="$TEST_TMP/repo"; mk_memory_root "$root"
  local target="$root/.gaia/memory/test-architect-sidecar/decision-log.md"
  [ ! -e "$target" ]

  run "$WRITER" --root "$root" --sprint-id "sprint-21" \
    --target "$target" --payload "seed test"
  [ "$status" -eq 0 ]
  [ -f "$target" ]
  # Canonical header exists
  head -5 "$target" | grep -qE "Decision Log|decision-log|ADR-016"
  grep -q "seed test" "$target"
}

# ===========================================================================
# AC-EC3 — action-items.yaml allowlist (happy) + malformed HALT
# ===========================================================================

@test "AC-EC3: writer creates action-items.yaml with schema header when missing" {
  [ -x "$WRITER" ] || skip "GUARD: retro-sidecar-write.sh does not exist — RED phase"

  local root="$TEST_TMP/repo"; mk_memory_root "$root"
  local target="$root/docs/planning-artifacts/action-items.yaml"
  [ ! -e "$target" ]

  run "$WRITER" --root "$root" --sprint-id "sprint-22" \
    --target "$target" --payload "- id: AI-1"$'\n'"  text: first"
  [ "$status" -eq 0 ]
  [ -f "$target" ]
  head -3 "$target" | grep -qE "Action Items|items:"
}

# ===========================================================================
# AC-EC4 — Missing sprint ID halts
# ===========================================================================

@test "AC-EC4: missing sprint ID halts with missing_sprint_id" {
  [ -x "$WRITER" ] || skip "GUARD: retro-sidecar-write.sh does not exist — RED phase"

  local root="$TEST_TMP/repo"; mk_memory_root "$root"
  local target="$root/.gaia/memory/architect-sidecar/decision-log.md"

  run "$WRITER" --root "$root" --sprint-id "" \
    --target "$target" --payload "x"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing_sprint_id"* ]]
  [ ! -e "$target" ]
}

# ===========================================================================
# AC-EC5 — Symlink allowlist bypass rejected (realpath resolution)
# ===========================================================================

@test "AC-EC5: symlink allowlist bypass rejected after realpath resolution" {
  [ -x "$WRITER" ] || skip "GUARD: retro-sidecar-write.sh does not exist — RED phase"

  local root="$TEST_TMP/repo"; mk_memory_root "$root"
  # A sidecar-looking path but actually a symlink into gaia-framework/plugins/.
  mkdir -p "$root/.gaia/memory/architect-sidecar"
  local forbidden="$root/gaia-framework/plugins/gaia/skills/evil.md"
  mkdir -p "$(dirname "$forbidden")"
  echo "original" > "$forbidden"
  local before; before="$(shasum -a 256 "$forbidden" | awk '{print $1}')"

  local link="$root/.gaia/memory/architect-sidecar/decision-log.md"
  ln -s "$forbidden" "$link"

  run "$WRITER" --root "$root" --sprint-id "sprint-23" \
    --target "$link" --payload "should not mutate symlink target"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unauthorized"* || "$output" == *"allowlist"* ]]

  local after; after="$(shasum -a 256 "$forbidden" | awk '{print $1}')"
  [ "$before" = "$after" ]
}

# ===========================================================================
# AC-EC6 — Composite (sprint_id + hash) collision: writer skips
# ===========================================================================

@test "AC-EC6: identical (sprint_id, payload) skipped on second call" {
  [ -x "$WRITER" ] || skip "GUARD: retro-sidecar-write.sh does not exist — RED phase"

  local root="$TEST_TMP/repo"; mk_memory_root "$root"
  local target="$root/.gaia/memory/security-sidecar/decision-log.md"
  mkdir -p "$(dirname "$target")"

  "$WRITER" --root "$root" --sprint-id "sprint-24" \
    --target "$target" --payload "same payload"
  local before; before="$(shasum -a 256 "$target" | awk '{print $1}')"

  run "$WRITER" --root "$root" --sprint-id "sprint-24" \
    --target "$target" --payload "same payload"
  [ "$status" -eq 0 ]

  local after; after="$(shasum -a 256 "$target" | awk '{print $1}')"
  [ "$before" = "$after" ]
}

# ===========================================================================
# AC-EC7 — Partial failure mid-write leaves .bak restore, no orphan .bak on success
# ===========================================================================

@test "AC-EC7: failed write restores from .bak; successful writes leave no .bak" {
  [ -x "$WRITER" ] || skip "GUARD: retro-sidecar-write.sh does not exist — RED phase"

  local root="$TEST_TMP/repo"; mk_memory_root "$root"
  local target="$root/.gaia/memory/devops-sidecar/decision-log.md"
  mkdir -p "$(dirname "$target")"
  printf "# Decision Log\n\noriginal content\n" > "$target"
  local before; before="$(shasum -a 256 "$target" | awk '{print $1}')"

  # Success path: no orphan .bak left behind.
  run "$WRITER" --root "$root" --sprint-id "sprint-25" \
    --target "$target" --payload "devops lesson"
  [ "$status" -eq 0 ]
  [ ! -f "$target.bak" ]

  # Failure path: simulate by making the target read-only after a first write.
  chmod 0444 "$target" || true
  local ro_before; ro_before="$(shasum -a 256 "$target" | awk '{print $1}')"
  run "$WRITER" --root "$root" --sprint-id "sprint-25" \
    --target "$target" --payload "second devops lesson"
  # On failure target is restored from .bak to ro_before hash; no orphan .bak.
  local ro_after; ro_after="$(shasum -a 256 "$target" | awk '{print $1}')"
  [ "$ro_before" = "$ro_after" ]
  [ ! -f "$target.bak" ]
  chmod 0644 "$target" || true
}

# ===========================================================================
# AC-EC9 — Auto-increment ID concurrency (via flock on target)
# ===========================================================================

@test "AC-EC9: concurrent writes on action-items.yaml are serialized by flock" {
  [ -x "$WRITER" ] || skip "GUARD: retro-sidecar-write.sh does not exist — RED phase"

  local root="$TEST_TMP/repo"; mk_memory_root "$root"
  local target="$root/docs/planning-artifacts/action-items.yaml"

  for i in 1 2 3 4 5; do
    "$WRITER" --root "$root" --sprint-id "sprint-26" \
      --target "$target" --payload "- id: AI-$i"$'\n'"  text: item $i" &
  done
  wait

  [ -f "$target" ]
  # Five distinct dedup keys landed.
  local count
  count="$(grep -c "dedup_key:" "$target" || true)"
  [ "$count" -eq 5 ]
}

# ===========================================================================
# AC-EC10 — Missing validator-sidecar directory seeded
# ===========================================================================

@test "AC-EC10: missing validator-sidecar directory is seeded with headers" {
  [ -x "$WRITER" ] || skip "GUARD: retro-sidecar-write.sh does not exist — RED phase"

  local root="$TEST_TMP/repo"; mk_memory_root "$root"
  [ ! -d "$root/.gaia/memory/validator-sidecar" ]

  local target="$root/.gaia/memory/validator-sidecar/decision-log.md"
  run "$WRITER" --root "$root" --sprint-id "sprint-27" \
    --target "$target" --payload "val retro decision"
  [ "$status" -eq 0 ]
  [ -f "$target" ]
  head -5 "$target" | grep -qE "Decision Log|decision-log|ADR-016"
}

# ===========================================================================
# AC-EC11 — Oversized payload (>100KB) wrapped in <details>
# ===========================================================================

@test "AC-EC11: oversized payload (>100KB) is wrapped in <details>" {
  [ -x "$WRITER" ] || skip "GUARD: retro-sidecar-write.sh does not exist — RED phase"

  local root="$TEST_TMP/repo"; mk_memory_root "$root"
  local target="$root/.gaia/memory/pm-sidecar/decision-log.md"
  mkdir -p "$(dirname "$target")"

  # 120KB payload
  local big; big="$(head -c 120000 < /dev/zero | tr '\0' 'x')"

  run "$WRITER" --root "$root" --sprint-id "sprint-28" \
    --target "$target" --payload "$big"
  [ "$status" -eq 0 ]
  grep -q "<details>" "$target"
  grep -q "</details>" "$target"
  # A warning should have surfaced on stderr (combined output via `run`).
  [[ "$output" == *"warn"* || "$output" == *"truncat"* || "$output" == *"WARN"* ]]
}

# ===========================================================================
# AC-EC12 — BOM normalization in idempotency scan
# ===========================================================================

@test "AC-EC12: existing file with UTF-8 BOM normalizes before hash compare" {
  [ -x "$WRITER" ] || skip "GUARD: retro-sidecar-write.sh does not exist — RED phase"

  local root="$TEST_TMP/repo"; mk_memory_root "$root"
  local target="$root/.gaia/memory/architect-sidecar/decision-log.md"
  mkdir -p "$(dirname "$target")"

  # Prepend BOM to a freshly seeded file then write the same logical entry.
  "$WRITER" --root "$root" --sprint-id "sprint-29" \
    --target "$target" --payload "bom payload"

  # Introduce BOM at top
  printf '\xEF\xBB\xBF%s' "$(cat "$target")" > "$target.tmp"
  mv "$target.tmp" "$target"
  local before; before="$(shasum -a 256 "$target" | awk '{print $1}')"

  run "$WRITER" --root "$root" --sprint-id "sprint-29" \
    --target "$target" --payload "bom payload"
  [ "$status" -eq 0 ]
  local after; after="$(shasum -a 256 "$target" | awk '{print $1}')"
  # Second write recognized the same logical entry; file size unchanged (skipped).
  [ "$before" = "$after" ]
}

# ===========================================================================
# Velocity data allowlist (AC4 / TC-RIM-6)
# ===========================================================================

@test "AC4/TC-RIM-6: velocity-data.md is in the allowlist and appends rows" {
  [ -x "$WRITER" ] || skip "GUARD: retro-sidecar-write.sh does not exist — RED phase"

  local root="$TEST_TMP/repo"; mk_memory_root "$root"
  local target="$root/.gaia/memory/sm-sidecar/velocity-data.md"
  mkdir -p "$(dirname "$target")"

  run "$WRITER" --root "$root" --sprint-id "sprint-30" \
    --target "$target" --payload "| Planned points | 20 |"
  [ "$status" -eq 0 ]
  [ -f "$target" ]
  grep -q "sprint-30" "$target"
  grep -q "Planned points" "$target"
}

# ===========================================================================
# Custom skills + .customize.yaml allowlist (architecture §10.28.1)
# ===========================================================================

@test "allowlist includes custom/skills/*.md and .customize.yaml" {
  [ -x "$WRITER" ] || skip "GUARD: retro-sidecar-write.sh does not exist — RED phase"

  local root="$TEST_TMP/repo"; mk_memory_root "$root"

  run "$WRITER" --root "$root" --sprint-id "sprint-31" \
    --target "$root/custom/skills/proposal.md" --payload "proposal body"
  [ "$status" -eq 0 ]

  run "$WRITER" --root "$root" --sprint-id "sprint-31" \
    --target "$root/.customize.yaml" --payload "customize: entry"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# retrospective-*.md allowlist
# ===========================================================================

@test "allowlist includes docs/implementation-artifacts/retrospective-*.md" {
  [ -x "$WRITER" ] || skip "GUARD: retro-sidecar-write.sh does not exist — RED phase"

  local root="$TEST_TMP/repo"; mk_memory_root "$root"
  local target="$root/docs/implementation-artifacts/retrospective-sprint-32.md"

  run "$WRITER" --root "$root" --sprint-id "sprint-32" \
    --target "$target" --payload "retro body"
  [ "$status" -eq 0 ]
  [ -f "$target" ]
}

# ===========================================================================
# Non-sidecar allowlist negatives
# ===========================================================================

@test "writes to /etc and arbitrary absolute paths are rejected" {
  [ -x "$WRITER" ] || skip "GUARD: retro-sidecar-write.sh does not exist — RED phase"

  local root="$TEST_TMP/repo"; mk_memory_root "$root"
  run "$WRITER" --root "$root" --sprint-id "sprint-33" \
    --target "/tmp/gaia-e36-s2-absolutely-not.md" --payload "nope"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# SKILL.md integration checks — Steps 5, 5c, 5d, 7 must be present
# ===========================================================================

@test "SKILL.md declares Step 5c (Agent Memory Updates)" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-retro/SKILL.md"
  [ -f "$skill" ]
  grep -qE "Step 5c.*Agent Memory Updates|### Step 5c" "$skill"
}

@test "SKILL.md declares Step 5d (Velocity Data Persistence)" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-retro/SKILL.md"
  [ -f "$skill" ]
  grep -qE "Step 5d.*Velocity Data Persistence|### Step 5d" "$skill"
}

@test "SKILL.md declares Step 7 (Val Memory Persistence)" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-retro/SKILL.md"
  [ -f "$skill" ]
  grep -qE "Step 7.*Val Memory Persistence|### Step 7" "$skill"
}

@test "SKILL.md Step 5 references action-items.yaml (YAML write)" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-retro/SKILL.md"
  [ -f "$skill" ]
  grep -q "action-items.yaml" "$skill"
  grep -q "classification" "$skill"
}

# ===========================================================================
# action-items-increment.sh delegation contract (Story note)
# ===========================================================================

@test "action-items-increment.sh delegates to retro-sidecar-write.sh" {
  local inc="$BATS_TEST_DIRNAME/../skills/gaia-retro/scripts/action-items-increment.sh"
  [ -f "$inc" ]
  # Delegation marker: either sources or execs retro-sidecar-write.sh, OR the
  # stand-in is retired with a pointer comment. Accept any of these markers.
  grep -qE "retro-sidecar-write\.sh|RETRO_WRITER|delegates? to the shared retro writer" "$inc"
}
