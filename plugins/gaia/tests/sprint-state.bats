#!/usr/bin/env bats
# sprint-state.bats — state-machine tests for sprint-state.sh
# Public functions covered: is_canonical_state, validate_transition,
# resolve_paths, locate_story_file, read_story_status,
# rewrite_story_status, rewrite_sprint_status_yaml,
# read_sprint_status_yaml_status, check_review_gate_all_passed,
# emit_lifecycle_event, cmd_get, cmd_validate, do_transition_locked,
# cmd_transition, main.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/sprint-state.sh"
  export MEMORY_PATH="$TEST_TMP/_memory"
  export PROJECT_PATH="$TEST_TMP"
  ART="$TEST_TMP/docs/implementation-artifacts"
  JSONL="$MEMORY_PATH/lifecycle-events.jsonl"
  mkdir -p "$ART"
}
teardown() { common_teardown; }

seed_story() {
  local key="$1" status="$2" verdict="${3:-PASSED}"
  cat > "$ART/${key}-fake.md" <<EOF
---
template: 'story'
key: "$key"
title: "Fake"
status: $status
---

# Story: Fake

> **Status:** $status

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | $verdict | — |
| QA Tests | $verdict | — |
| Security Review | $verdict | — |
| Test Automation | $verdict | — |
| Test Review | $verdict | — |
| Performance Review | $verdict | — |
EOF
}

seed_yaml() {
  cat > "$ART/sprint-status.yaml" <<EOF
sprint_id: "sprint-test"
stories:
  - key: "$1"
    title: "Fake"
    status: "$2"
EOF
}

@test "sprint-state.sh: --help lists the three subcommands" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"transition"* ]]
  [[ "$output" == *"get"* ]]
  [[ "$output" == *"validate"* ]]
}

# --- Legal transitions (AC6 — exercise every canonical edge) -----------------

@test "sprint-state.sh: legal transition backlog → validating" {
  seed_story L1 backlog; seed_yaml L1 backlog
  run "$SCRIPT" transition --story L1 --to validating
  [ "$status" -eq 0 ]
  grep -q '^status: validating' "$ART/L1-fake.md"
}

@test "sprint-state.sh: legal transition validating → ready-for-dev" {
  seed_story L2 validating; seed_yaml L2 validating
  run "$SCRIPT" transition --story L2 --to ready-for-dev
  [ "$status" -eq 0 ]
}

@test "sprint-state.sh: legal transition ready-for-dev → in-progress" {
  seed_story L3 ready-for-dev; seed_yaml L3 ready-for-dev
  run "$SCRIPT" transition --story L3 --to in-progress
  [ "$status" -eq 0 ]
}

@test "sprint-state.sh: legal transition in-progress → blocked" {
  seed_story L4 in-progress; seed_yaml L4 in-progress
  run "$SCRIPT" transition --story L4 --to blocked
  [ "$status" -eq 0 ]
}

@test "sprint-state.sh: legal transition blocked → in-progress" {
  seed_story L5 blocked; seed_yaml L5 blocked
  run "$SCRIPT" transition --story L5 --to in-progress
  [ "$status" -eq 0 ]
}

@test "sprint-state.sh: legal transition in-progress → review" {
  seed_story L6 in-progress; seed_yaml L6 in-progress
  run "$SCRIPT" transition --story L6 --to review
  [ "$status" -eq 0 ]
}

@test "sprint-state.sh: legal transition review → done (all PASSED)" {
  seed_story L7 review PASSED; seed_yaml L7 review
  run "$SCRIPT" transition --story L7 --to done
  [ "$status" -eq 0 ]
  grep -q '^status: done' "$ART/L7-fake.md"
}

@test "sprint-state.sh: review -> in-progress rejected per shared SSOT" {
  seed_story L8 review UNVERIFIED; seed_yaml L8 review
  run "$SCRIPT" transition --story L8 --to in-progress
  [ "$status" -ne 0 ]
  [[ "$output" == *"illegal transition"* ]]
}

# --- Illegal transitions (AC6 — sample of rejected edges) -------------------

@test "sprint-state.sh: illegal backlog → done rejected, file untouched" {
  seed_story I1 backlog; seed_yaml I1 backlog
  run "$SCRIPT" transition --story I1 --to done
  [ "$status" -ne 0 ]
  grep -q '^status: backlog' "$ART/I1-fake.md"
}

@test "sprint-state.sh: illegal done → in-progress rejected" {
  seed_story I2 done; seed_yaml I2 done
  run "$SCRIPT" transition --story I2 --to in-progress
  [ "$status" -ne 0 ]
}

@test "sprint-state.sh: illegal review → backlog rejected" {
  seed_story I3 review; seed_yaml I3 review
  run "$SCRIPT" transition --story I3 --to backlog
  [ "$status" -ne 0 ]
}

# --- review gate guard -------------------------------------------------------

@test "sprint-state.sh: review → done blocked when gate not all PASSED" {
  seed_story G1 review UNVERIFIED; seed_yaml G1 review
  run "$SCRIPT" transition --story G1 --to done
  [ "$status" -ne 0 ]
  [[ "$output" == *"Review Gate"* ]] || [[ "$output" == *"review"* ]]
}

# --- get / validate ----------------------------------------------------------

@test "sprint-state.sh: get returns current status" {
  seed_story V1 in-progress; seed_yaml V1 in-progress
  run "$SCRIPT" get --story V1
  [ "$status" -eq 0 ]
  [ "$output" = "in-progress" ]
}

@test "sprint-state.sh: validate detects drift between story and sprint-status.yaml" {
  seed_story V2 in-progress; seed_yaml V2 in-progress
  run "$SCRIPT" validate --story V2
  [ "$status" -eq 0 ]
  # induce drift
  sed -i.bak 's/status: "in-progress"/status: "done"/' "$ART/sprint-status.yaml"
  rm -f "$ART/sprint-status.yaml.bak"
  run "$SCRIPT" validate --story V2
  [ "$status" -ne 0 ]
}

@test "sprint-state.sh: get with zero-match key fails with clear message" {
  run "$SCRIPT" get --story NOPE-S999
  [ "$status" -ne 0 ]
  [[ "$output" == *"no story file found"* ]]
}

# --- glob collision tests (E28-S76) ------------------------------------------

# Helper: create review sibling files (no template: 'story' frontmatter)
seed_review_siblings() {
  local key="$1"
  for suffix in review qa-tests security-review performance-review review-summary; do
    cat > "$ART/${key}-${suffix}.md" <<SIBLING
---
key: "$key"
title: "Review report"
---

# Review: $suffix for $key
SIBLING
  done
}

@test "sprint-state.sh: locate_story_file ignores review sibling files" {
  seed_story C1 in-progress
  seed_review_siblings C1
  seed_yaml C1 in-progress
  run "$SCRIPT" get --story C1
  [ "$status" -eq 0 ]
  [ "$output" = "in-progress" ]
}

@test "sprint-state.sh: transition --to done succeeds with review siblings present" {
  seed_story C2 review PASSED
  seed_review_siblings C2
  seed_yaml C2 review
  run "$SCRIPT" transition --story C2 --to done
  [ "$status" -eq 0 ]
  grep -q '^status: done' "$ART/C2-fake.md"
}

@test "sprint-state.sh: locate_story_file errors when only review siblings exist" {
  seed_review_siblings C3
  run "$SCRIPT" get --story C3
  [ "$status" -ne 0 ]
  [[ "$output" == *"no story file found"* ]]
}

# --- Canonical status enum guard (E38-S8, AC1/AC2/AC3/AC5) -------------------

# Helper: enumerate every canonical status name the script accepts. Mirrors
# the CANONICAL_STATES array in sprint-state.sh — keep in sync.
CANONICAL_STATES_LIST=(backlog validating ready-for-dev in-progress blocked review done)

@test "sprint-state.sh: AC1 review → done writes canonical 'done' (never 'PASSED') in yaml" {
  # Direct AC1: even when the composite Review Gate is fully PASSED, the
  # status field written into sprint-status.yaml must be the canonical
  # lifecycle enum value 'done' — never the review-gate display string.
  seed_story AC1A review PASSED; seed_yaml AC1A review
  run "$SCRIPT" transition --story AC1A --to done
  [ "$status" -eq 0 ] || { echo "transition failed; output=$output"; false; }
  # The yaml MUST contain status: "done", and MUST NOT contain status: "PASSED".
  grep -qE '^[[:space:]]+status:[[:space:]]*"done"[[:space:]]*$'   "$ART/sprint-status.yaml" \
    || { echo "yaml missing 'done'";    cat "$ART/sprint-status.yaml"; false; }
  ! grep -qE '^[[:space:]]+status:[[:space:]]*"PASSED"[[:space:]]*$' "$ART/sprint-status.yaml" \
    || { echo "yaml leaked 'PASSED'";   cat "$ART/sprint-status.yaml"; false; }
  # And the story file frontmatter agrees.
  grep -q '^status: done' "$ART/AC1A-fake.md"
}

@test "sprint-state.sh: AC2 transition --to PASSED rejected, yaml unchanged, error names enum" {
  # Sprint-27 root cause: a caller passed the review-gate display string
  # 'PASSED' as the lifecycle target. The script MUST refuse it, exit
  # non-zero, leave sprint-status.yaml byte-identical, and emit an error
  # that names BOTH the offending value AND the allowed enum values so the
  # operator can see the correct alternative.
  seed_story AC2A review PASSED; seed_yaml AC2A review
  local before_yaml before_story
  before_yaml=$(shasum -a 256 "$ART/sprint-status.yaml" | awk '{print $1}')
  before_story=$(shasum -a 256 "$ART/AC2A-fake.md"      | awk '{print $1}')

  # Bats `run` only captures stdout by default — merge stderr so the die
  # message (which is emitted to stderr) shows up in $output.
  run bash -c "'$SCRIPT' transition --story AC2A --to PASSED 2>&1"
  [ "$status" -ne 0 ] || { echo "expected non-zero exit, got 0; output=$output"; false; }
  [[ "$output" == *"PASSED"*    ]] || { echo "output missing PASSED:    $output"; false; }
  # Error must name at least three canonical states so the user sees the enum.
  [[ "$output" == *"backlog"*   ]] || { echo "output missing backlog:   $output"; false; }
  [[ "$output" == *"done"*      ]] || { echo "output missing done:      $output"; false; }
  [[ "$output" == *"review"*    ]] || { echo "output missing review:    $output"; false; }

  local after_yaml after_story
  after_yaml=$(shasum -a 256 "$ART/sprint-status.yaml" | awk '{print $1}')
  after_story=$(shasum -a 256 "$ART/AC2A-fake.md"      | awk '{print $1}')
  [ "$before_yaml"  = "$after_yaml"  ] || { echo "yaml changed";  false; }
  [ "$before_story" = "$after_story" ] || { echo "story changed"; false; }
}

@test "sprint-state.sh: AC2 transition --to FAILED rejected, yaml unchanged, error names enum" {
  seed_story AC2B review PASSED; seed_yaml AC2B review
  local before_yaml
  before_yaml=$(shasum -a 256 "$ART/sprint-status.yaml" | awk '{print $1}')

  run bash -c "'$SCRIPT' transition --story AC2B --to FAILED 2>&1"
  [ "$status" -ne 0 ]                || { echo "expected non-zero exit; output=$output"; false; }
  [[ "$output" == *"FAILED"* ]]      || { echo "output missing FAILED: $output"; false; }
  [[ "$output" == *"done"*   ]]      || { echo "output missing done:   $output"; false; }

  local after_yaml
  after_yaml=$(shasum -a 256 "$ART/sprint-status.yaml" | awk '{print $1}')
  [ "$before_yaml" = "$after_yaml" ] || { echo "yaml changed"; false; }
}

@test "sprint-state.sh: AC2 transition --to UNVERIFIED rejected with enum hint" {
  seed_story AC2C review PASSED; seed_yaml AC2C review
  run bash -c "'$SCRIPT' transition --story AC2C --to UNVERIFIED 2>&1"
  [ "$status" -ne 0 ]                  || { echo "expected non-zero exit; output=$output"; false; }
  [[ "$output" == *"UNVERIFIED"* ]]    || { echo "output missing UNVERIFIED: $output"; false; }
  # Allowed enum hint must accompany the rejection.
  { [[ "$output" == *"in-progress"* ]] || [[ "$output" == *"validating"* ]]; } \
    || { echo "output missing enum hint: $output"; false; }
}

@test "sprint-state.sh: AC3 every canonical enum value is accepted by is_canonical_state" {
  # Negative-side coverage of AC3 — a forbidden value rejected — is in the
  # PASSED/FAILED/UNVERIFIED tests above. This test pins the positive side:
  # all canonical states must round-trip through the script's --to validator.
  # We exercise this via legal seed states that adjacency permits, ensuring
  # is_canonical_state never spuriously rejects a canonical value.
  seed_story AC3A backlog;       seed_yaml AC3A backlog
  run "$SCRIPT" transition --story AC3A --to validating
  [ "$status" -eq 0 ] || { echo "AC3A failed: $output"; false; }

  seed_story AC3B validating;    seed_yaml AC3B validating
  run "$SCRIPT" transition --story AC3B --to ready-for-dev
  [ "$status" -eq 0 ] || { echo "AC3B failed: $output"; false; }

  seed_story AC3C ready-for-dev; seed_yaml AC3C ready-for-dev
  run "$SCRIPT" transition --story AC3C --to in-progress
  [ "$status" -eq 0 ] || { echo "AC3C failed: $output"; false; }

  seed_story AC3D in-progress;   seed_yaml AC3D in-progress
  run "$SCRIPT" transition --story AC3D --to blocked
  [ "$status" -eq 0 ] || { echo "AC3D failed: $output"; false; }

  seed_story AC3E in-progress;   seed_yaml AC3E in-progress
  run "$SCRIPT" transition --story AC3E --to review
  [ "$status" -eq 0 ] || { echo "AC3E failed: $output"; false; }

  seed_story AC3F review PASSED; seed_yaml AC3F review
  run "$SCRIPT" transition --story AC3F --to done
  [ "$status" -eq 0 ] || { echo "AC3F failed: $output"; false; }
}

@test "sprint-state.sh: sprint-27 regression — // all write 'done', never 'PASSED'" {
  # Mirrors the sprint-27 close-out finding (F2): three stories had their
  # sprint-status.yaml entries written as status: "PASSED" instead of "done"
  # and required manual sed cleanup. This test stamps that exact scenario:
  # three stories sitting in 'review' with all reviews PASSED, transitioned
  # one by one to 'done'. After each transition, the yaml must read 'done'
  # for that story and never 'PASSED' anywhere.
  cat > "$ART/sprint-status.yaml" <<EOF
sprint_id: "sprint-27"
stories:
  - key: "E42-S5"
    title: "Fake S5"
    status: "review"
  - key: "E42-S6"
    title: "Fake S6"
    status: "review"
  - key: "E42-S7"
    title: "Fake S7"
    status: "review"
EOF
  seed_story E42-S5 review PASSED
  seed_story E42-S6 review PASSED
  seed_story E42-S7 review PASSED

  run "$SCRIPT" transition --story E42-S5 --to done
  [ "$status" -eq 0 ] || { echo "E42-S5 transition failed: $output"; false; }
  run "$SCRIPT" transition --story E42-S6 --to done
  [ "$status" -eq 0 ] || { echo "E42-S6 transition failed: $output"; false; }
  run "$SCRIPT" transition --story E42-S7 --to done
  [ "$status" -eq 0 ] || { echo "E42-S7 transition failed: $output"; false; }

  # No 'PASSED' may appear as a status value anywhere in the yaml.
  ! grep -qE '^[[:space:]]+status:[[:space:]]*"PASSED"' "$ART/sprint-status.yaml" \
    || { echo "yaml leaked PASSED:"; cat "$ART/sprint-status.yaml"; false; }
  # All three stories must read status: "done".
  local done_count
  done_count=$(grep -cE '^[[:space:]]+status:[[:space:]]*"done"[[:space:]]*$' "$ART/sprint-status.yaml")
  [ "$done_count" -eq 3 ] || { echo "expected 3 done entries, got $done_count:"; cat "$ART/sprint-status.yaml"; false; }
}

# --- Direct unit tests for canonical_states_hint and assert_canonical_state -
# These tests extract the two new helpers and the prerequisites from the
# canonical script and execute them in isolation. Avoids sourcing the whole
# script (which would trigger main "$@" at file end). The function names
# referenced here also satisfy the NFR-052 textual coverage gate in
# run-with-coverage.sh.

# Build a minimal harness: write a small bash script that defines die()
# and CANONICAL_STATES, then sources only the helper definitions extracted
# from sprint-state.sh by sed range, then runs the requested call.
_run_helper() {
  local call="$1"
  # Source the shared SSOT lib first. sprint-state.sh delegates
  # is_canonical_state -> is_canonical_story_state and
  # canonical_states_hint -> canonical_story_states_hint, so the SSOT
  # provides all the underlying plumbing. We add the thin delegating
  # wrappers + die() + assert_canonical_state on top.
  local ssot_lib="$SCRIPTS_DIR/lib/story-state-machine.sh"
  local harness_script
  harness_script=$(cat <<OUTER
#!/usr/bin/env bash
set -uo pipefail
die() { printf 'sprint-state.sh: error: %s\n' "\$*" >&2; exit 1; }
. "${ssot_lib}"
CANONICAL_STATES=( "\${STORY_CANONICAL_STATES[@]}" )
is_canonical_state() { is_canonical_story_state "\$1"; }
canonical_states_hint() { canonical_story_states_hint; }
OUTER
)
  # Extract assert_canonical_state from the canonical script. Uses
  # sed -n with anchors so the test fails loudly if the function is
  # renamed or removed.
  local extracted
  extracted=$(sed -n '/^assert_canonical_state() {/,/^}/p' "$SCRIPT")
  [ -n "$extracted" ] || { echo "extraction failed — assert_canonical_state not found in $SCRIPT"; return 1; }
  printf '%s\n%s\n%s\n' "$harness_script" "$extracted" "$call"
}

@test "sprint-state.sh: canonical_states_hint renders the enum as 'a | b | c | ...'" {
  local prog
  prog=$(_run_helper 'canonical_states_hint')
  run bash -c "$prog"
  [ "$status" -eq 0 ]                      || { echo "canonical_states_hint exit=$status output=$output"; false; }
  [[ "$output" == *"backlog"*       ]]     || { echo "missing backlog: $output";       false; }
  [[ "$output" == *"validating"*    ]]     || { echo "missing validating: $output";    false; }
  [[ "$output" == *"ready-for-dev"* ]]     || { echo "missing ready-for-dev: $output"; false; }
  [[ "$output" == *"in-progress"*   ]]     || { echo "missing in-progress: $output";   false; }
  [[ "$output" == *"review"*        ]]     || { echo "missing review: $output";        false; }
  [[ "$output" == *"done"*          ]]     || { echo "missing done: $output";          false; }
  [[ "$output" == *"|"*             ]]     || { echo "missing separator: $output";     false; }
}

@test "sprint-state.sh: assert_canonical_state accepts every canonical value" {
  for s in backlog validating ready-for-dev in-progress blocked review done; do
    local prog
    prog=$(_run_helper "assert_canonical_state '$s' 'test'")
    run bash -c "$prog"
    [ "$status" -eq 0 ] || { echo "assert_canonical_state rejected canonical '$s': $output"; false; }
  done
}

@test "sprint-state.sh: assert_canonical_state rejects non-canonical with enum hint" {
  local prog
  prog=$(_run_helper "assert_canonical_state PASSED 'test write' 2>&1")
  run bash -c "$prog"
  [ "$status" -ne 0 ]                  || { echo "expected die() on PASSED, got 0; output=$output"; false; }
  [[ "$output" == *"PASSED"*  ]]       || { echo "missing offending value: $output"; false; }
  [[ "$output" == *"backlog"* ]]       || { echo "missing enum hint: $output";      false; }
  [[ "$output" == *"done"*    ]]       || { echo "missing enum hint: $output";      false; }
  [[ "$output" == *"test write"* ]]    || { echo "missing context label: $output";  false; }
}

# --- Wrapper-sync invariant (E38-S8, AC4 / ADR-055 §10.29.3) -----------------

@test "sprint-state.sh: AC4 wrapper copy is byte-identical to canonical script" {
  # The dev-story skill ships a wrapper copy at
  # plugins/gaia/skills/gaia-dev-story/scripts/sprint-state.sh that MUST stay
  # byte-identical to plugins/gaia/scripts/sprint-state.sh per ADR-055 §10.29.3.
  # This test pins the invariant — if the diff is non-empty, the sync step in
  # the dev workflow was missed.
  local CANON="$SCRIPTS_DIR/sprint-state.sh"
  local WRAPPER
  WRAPPER="$(cd "$SCRIPTS_DIR/../skills/gaia-dev-story/scripts" && pwd)/sprint-state.sh"
  [ -r "$CANON" ]
  [ -r "$WRAPPER" ]
  run diff -q "$CANON" "$WRAPPER"
  [ "$status" -eq 0 ]
}

@test "sprint-state.sh: locate_story_file errors on genuine duplicate canonical files" {
  # Create two files that both have template: 'story' frontmatter
  cat > "$ART/C4-first.md" <<EOF
---
template: 'story'
key: "C4"
title: "First"
status: in-progress
---
# Story: First
> **Status:** in-progress
EOF
  cat > "$ART/C4-second.md" <<EOF
---
template: 'story'
key: "C4"
title: "Second"
status: in-progress
---
# Story: Second
> **Status:** in-progress
EOF
  seed_yaml C4 in-progress
  run "$SCRIPT" get --story C4
  [ "$status" -ne 0 ]
  [[ "$output" == *"ambiguous"* ]] || [[ "$output" == *"multiple"* ]]
}
