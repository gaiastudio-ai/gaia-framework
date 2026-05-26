#!/usr/bin/env bats
# e105-s2-planning-vs-test-taxonomy.bats — E105-S2
#
# Migration that moves docs-ABOUT-testing (test-plan, test-strategy,
# traceability-matrix, nfr-assessment, performance-test-plan) from
# test-artifacts/(strategy/) to planning-artifacts/, leaving only
# test-EXECUTION outputs under test-artifacts/. Ships with --dry-run /
# idempotency / per-file rollback (NEVER rm -rf SOURCE_DIR) + a
# manifest-iterating phase-exit gate, plus a validate-gate.sh read-side
# fallback to the new planning-artifacts/ home.
#
# ALL tests run against FIXTURE temp trees — they NEVER touch the live .gaia tree.
#
# Maps to AC1-AC5, AC-INT1 and TS1-TS6.
# Refs: ADR-127 §7.2/§7.6, ADR-070, FR-554, NFR-91, feedback_cumulative_target_gate_bug_class

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  MIGRATE="$REPO_ROOT/plugins/gaia/scripts/migrate-planning-vs-test.sh"
  VGATE="$REPO_ROOT/plugins/gaia/scripts/validate-gate.sh"
  SRC="$BATS_TEST_DIRNAME/fixtures/planning-vs-test/source"

  TEST_TMP="$BATS_TEST_TMPDIR/pvt-$$"
  mkdir -p "$TEST_TMP"
}
teardown() { rm -rf "$TEST_TMP" 2>/dev/null || true; }

# fresh temp copy of the source fixture (a strategy/-placement project)
mktree() {
  local t="$TEST_TMP/t$RANDOM"
  mkdir -p "$t"
  cp -R "$SRC/." "$t/"
  printf '%s' "$t"
}

treehash() { find "$1" -type f -exec shasum -a 256 {} \; | sort | shasum -a 256 | awk '{print $1}'; }

# ---------- AC2 / TS1: --dry-run reports, mutates nothing ----------

@test "AC2/TS1: --dry-run reports planned moves + rewrites and mutates nothing" {
  t="$(mktree)"
  before="$(treehash "$t")"
  run bash "$MIGRATE" --test-artifacts "$t/test-artifacts" --planning-artifacts "$t/planning-artifacts" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eiq 'dry.run|would move|plan' \
    || { echo "dry-run should report planned moves, got:" >&2; echo "$output" >&2; false; }
  echo "$output" | grep -Eq 'test-plan|traceability-matrix' \
    || { echo "dry-run should name the moved docs, got:" >&2; echo "$output" >&2; false; }
  after="$(treehash "$t")"
  [ "$before" = "$after" ] || { echo "--dry-run mutated the tree" >&2; false; }
}

# ---------- AC1 / TS2: migrate moves docs + rewrites refs ----------

@test "AC1/TS2: migrate moves the docs-about-testing to planning-artifacts/" {
  t="$(mktree)"
  run bash "$MIGRATE" --test-artifacts "$t/test-artifacts" --planning-artifacts "$t/planning-artifacts" --migrate
  [ "$status" -eq 0 ]
  for d in test-plan traceability-matrix nfr-assessment performance-test-plan test-strategy; do
    [ -f "$t/planning-artifacts/$d.md" ] || { echo "$d.md not moved to planning-artifacts/" >&2; false; }
  done
  # test-EXECUTION outputs STAY in test-artifacts/
  [ -f "$t/test-artifacts/atdd-E900-S1.md" ] || { echo "atdd must stay in test-artifacts/" >&2; false; }
  [ -f "$t/test-artifacts/qa-tests-E900-S1-execution-evidence.json" ] || { echo "execution-evidence must stay" >&2; false; }
}

@test "AC1/TS2: migrate rewrites cross-references to the new home" {
  t="$(mktree)"
  run bash "$MIGRATE" --test-artifacts "$t/test-artifacts" --planning-artifacts "$t/planning-artifacts" --migrate
  [ "$status" -eq 0 ]
  # the epics doc referenced test-artifacts/strategy/test-plan.md -> should now point at planning-artifacts/
  grep -q 'planning-artifacts/test-plan.md' "$t/planning-artifacts/epics-and-stories.md" \
    || { echo "cross-reference not rewritten:" >&2; cat "$t/planning-artifacts/epics-and-stories.md" >&2; false; }
  ! grep -q 'test-artifacts/strategy/test-plan.md' "$t/planning-artifacts/epics-and-stories.md" \
    || { echo "old reference still present" >&2; false; }
}

# ---------- AC2 / TS2: idempotent re-run ----------

@test "AC2/TS2: a second migrate run is an idempotent no-op" {
  t="$(mktree)"
  bash "$MIGRATE" --test-artifacts "$t/test-artifacts" --planning-artifacts "$t/planning-artifacts" --migrate
  after1="$(treehash "$t")"
  run bash "$MIGRATE" --test-artifacts "$t/test-artifacts" --planning-artifacts "$t/planning-artifacts" --migrate
  [ "$status" -eq 0 ]
  after2="$(treehash "$t")"
  [ "$after1" = "$after2" ] || { echo "second migrate run was not a no-op" >&2; false; }
}

# ---------- AC3 / TS3: per-file rollback, NEVER rm -rf SOURCE_DIR ----------

@test "AC3/TS3: the script never uses rm -rf against a source directory" {
  # static guard: the migration script must not rm -rf the source tree
  ! grep -Eq 'rm -rf "?\$\{?(TEST_ARTIFACTS|SOURCE_DIR|src)' "$MIGRATE" \
    || { echo "script must not rm -rf the source dir" >&2; grep -n 'rm -rf' "$MIGRATE" >&2; false; }
}

@test "AC3/TS3: mid-migration failure rolls back per-file (origins restored)" {
  t="$(mktree)"
  before="$(treehash "$t")"
  # inject failure: make planning-artifacts/ read-only after the first move would land,
  # by pointing --planning-artifacts at a non-writable path mid-run is hard portably;
  # instead use the script's --simulate-fail-after N hook (test affordance).
  run bash "$MIGRATE" --test-artifacts "$t/test-artifacts" --planning-artifacts "$t/planning-artifacts" --migrate --simulate-fail-after 2
  [ "$status" -ne 0 ]
  after="$(treehash "$t")"
  # per-file rollback must restore the original tree exactly
  [ "$before" = "$after" ] || { echo "rollback did not restore origins exactly" >&2; false; }
}

# ---------- AC4 / TS4: manifest-iterating phase-exit gate ----------

@test "AC4/TS4: phase-exit gate iterates the manifest, not find|wc cumulative" {
  # static guard: no cumulative find|wc-l gate in the script
  ! grep -Eq 'find .*\| *wc -l' "$MIGRATE" \
    || { echo "gate must not use find|wc -l cumulative target" >&2; grep -n 'wc -l' "$MIGRATE" >&2; false; }
  # positive: a migrate run reports a per-manifest completion check
  t="$(mktree)"
  run bash "$MIGRATE" --test-artifacts "$t/test-artifacts" --planning-artifacts "$t/planning-artifacts" --migrate
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eiq 'manifest|verified [0-9]+ of [0-9]+|gate' \
    || { echo "migrate should report a manifest-based completion gate, got:" >&2; echo "$output" >&2; false; }
}

# ---------- AC5 / TS5: consumer resolution at planning-artifacts/ with fallback ----------

@test "AC5/TS5: validate-gate resolves test-plan at planning-artifacts/ (new home)" {
  t="$(mktree)"
  # migrate, then point validate-gate at the project; test_plan must resolve at planning-artifacts/
  bash "$MIGRATE" --test-artifacts "$t/test-artifacts" --planning-artifacts "$t/planning-artifacts" --migrate
  run env TEST_ARTIFACTS="$t/test-artifacts" PLANNING_ARTIFACTS="$t/planning-artifacts" bash "$VGATE" test_plan_exists
  [ "$status" -eq 0 ] \
    || { echo "validate-gate test_plan_exists should resolve at planning-artifacts/ post-migration, got status $status: $output" >&2; false; }
}

@test "AC5/TS5: validate-gate still resolves legacy strategy/ test-plan (read-compat fallback)" {
  t="$(mktree)"
  # NO migration — legacy strategy/ layout must still resolve
  run env TEST_ARTIFACTS="$t/test-artifacts" PLANNING_ARTIFACTS="$t/planning-artifacts" bash "$VGATE" test_plan_exists
  [ "$status" -eq 0 ] \
    || { echo "validate-gate must still resolve legacy strategy/test-plan.md, got status $status: $output" >&2; false; }
}

# ---------- AC-INT1 / TS6: consumer round-trip post-migration ----------

@test "AC-INT1/TS6: gaia-create-epics setup resolver finds test-plan at planning-artifacts/ post-migration" {
  t="$(mktree)"
  bash "$MIGRATE" --test-artifacts "$t/test-artifacts" --planning-artifacts "$t/planning-artifacts" --migrate
  # mirror the create-epics setup.sh candidate loop precedence (planning-artifacts first)
  resolved=""
  for c in "$t/planning-artifacts/test-plan.md" "$t/planning-artifacts/test-strategy.md" \
           "$t/test-artifacts/test-plan.md" "$t/test-artifacts/strategy/test-plan.md"; do
    [ -s "$c" ] && { resolved="$c"; break; }
  done
  [ -n "$resolved" ] || { echo "create-epics resolver found no test-plan post-migration" >&2; false; }
  echo "$resolved" | grep -Eq 'planning-artifacts/(test-plan|test-strategy)\.md$' \
    || { echo "create-epics must resolve test-plan at planning-artifacts/, got: $resolved" >&2; false; }
  # the setup.sh script must actually carry the planning-artifacts/ candidate
  grep -Eq '\$\{PLANNING_ARTIFACTS:-\}/test-plan\.md' "$REPO_ROOT/plugins/gaia/skills/gaia-create-epics/scripts/setup.sh" \
    || { echo "create-epics setup.sh missing the planning-artifacts/ test-plan candidate" >&2; false; }
}

@test "AC-INT1/TS6: gaia-trace finalize TM_PATHS resolves traceability at planning-artifacts/ post-migration" {
  TRACE_FIN="$REPO_ROOT/plugins/gaia/skills/gaia-trace/scripts/finalize.sh"
  # the finalize TM_PATHS must include the planning-artifacts/ home as a resolution path
  grep -Eq 'planning-artifacts/traceability-matrix\.md' "$TRACE_FIN" \
    || { echo "gaia-trace finalize TM_PATHS missing the planning-artifacts/ home" >&2; false; }
  # functional: a migrated fixture's traceability resolves at planning-artifacts/
  t="$(mktree)"
  bash "$MIGRATE" --test-artifacts "$t/test-artifacts" --planning-artifacts "$t/planning-artifacts" --migrate
  [ -f "$t/planning-artifacts/traceability-matrix.md" ] \
    || { echo "traceability-matrix not at planning-artifacts/ post-migration" >&2; false; }
}

# ---------- robustness ----------

@test "missing --test-artifacts fails with usage error" {
  run bash "$MIGRATE" --planning-artifacts /tmp/x
  [ "$status" -ne 0 ]
}

@test "--help prints usage and exits 0" {
  run bash "$MIGRATE" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eiq 'migrat'
}
