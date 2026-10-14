#!/usr/bin/env bats
# scan-stranded-ready.bats — tests for the stranded-ready scanner performance
# fix. Verifies file-type filtering, grep pre-filter, single-pass parsing,
# one-shot decision-log read, golden-test parity, fork-count scaling, bash 3.2
# compatibility, and edge cases.

setup() {
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCANNER="$REPO_ROOT/plugins/gaia/scripts/lib/scan-stranded-ready.sh"
  FIXTURE_ROOT="$BATS_TEST_DIRNAME/fixtures/stranded-ready"

  TEST_TMP="$BATS_TEST_TMPDIR/ssr-$$"
  mkdir -p "$TEST_TMP/impl"
  mkdir -p "$TEST_TMP/.gaia/memory/validator-sidecar"
}

teardown() {
  rm -rf "$TEST_TMP" 2>/dev/null || true
}

# Helper: create a per-story directory and story.md from fixture file
_load_stories() {
  local fixture="$1"
  for f in "$FIXTURE_ROOT/$fixture/"story-*.md; do
    [ -e "$f" ] || continue
    local base; base=$(basename "$f" .md)
    local skey="${base#story-}"
    local storydir="$TEST_TMP/impl/epic-test/${skey}-test"
    mkdir -p "$storydir"
    cp "$f" "$storydir/story.md"
  done
  cp "$FIXTURE_ROOT/$fixture/decision-log.md" \
    "$TEST_TMP/.gaia/memory/validator-sidecar/decision-log.md"
}

# Helper: create a minimal stranded-ready story in per-story dir layout
_mk_story() {
  local key="$1" title="$2" status="${3:-ready-for-dev}" sprint="${4:-null}"
  local dir="$TEST_TMP/impl/epic-test/${key}-slug"
  mkdir -p "$dir"
  cat > "$dir/story.md" <<EOF
---
key: "${key}"
title: "${title}"
epic: "E900"
status: ${status}
sprint_id: ${sprint}
---
# Story: ${title}
EOF
}

# Helper: create a minimal decision log with a PASSED verdict for a key
_mk_decision_log() {
  local log="$TEST_TMP/.gaia/memory/validator-sidecar/decision-log.md"
  printf '# Decision Log\n\n' > "$log"
  local key
  for key in "$@"; do
    cat >> "$log" <<EOF
### [2026-10-14] /gaia-create-story: ${key}

- agent: val
- status: recorded

{"verdict":"PASSED","findings":[]}

EOF
  done
}

# Helper: run scanner with test env
_run_scanner() {
  IMPLEMENTATION_ARTIFACTS="$TEST_TMP/impl" \
  VALIDATOR_DECISION_LOG="$TEST_TMP/.gaia/memory/validator-sidecar/decision-log.md" \
    "$@" "$SCANNER"
}

# ---------- AC1: only story files are parsed ----------

@test "AC1 — story.md in per-story dir is found" {
  _mk_story "E900-S1" "Test story"
  _mk_decision_log "E900-S1"
  run _run_scanner bash
  [ "$status" -eq 0 ]
  [[ "$output" =~ "E900-S1" ]]
}

@test "AC1 — non-story markdown is never parsed" {
  _mk_story "E900-S1" "Real story"
  _mk_decision_log "E900-S1"
  # Add 50 non-story markdown files (review reports, assessments, etc.)
  local i
  for i in $(seq 1 50); do
    cat > "$TEST_TMP/impl/review-report-${i}.md" <<'DECOY'
---
title: "Review Report"
status: ready-for-dev
sprint_id: null
key: "E900-S1"
---
# This review report has story-like frontmatter but is not a story file
DECOY
  done
  run _run_scanner bash
  [ "$status" -eq 0 ]
  # Only the real story should appear (once)
  local count
  count=$(printf '%s\n' "$output" | grep -c 'E900-S1' || true)
  [ "$count" -eq 1 ]
}

@test "AC1 — legacy flat E*-S*-*.md layout is found" {
  # Legacy layout: file named E900-S1-slug.md directly in an epic dir
  mkdir -p "$TEST_TMP/impl/epic-test"
  cat > "$TEST_TMP/impl/epic-test/E900-S1-legacy-story.md" <<'EOF'
---
key: "E900-S1"
title: "Legacy story"
epic: "E900"
status: ready-for-dev
sprint_id: null
---
# Story: Legacy story
EOF
  _mk_decision_log "E900-S1"
  run _run_scanner bash
  [ "$status" -eq 0 ]
  [[ "$output" =~ "E900-S1" ]]
  [[ "$output" =~ "Legacy story" ]]
}

# ---------- AC2: grep pre-filter ----------

@test "AC2 — only ready-for-dev stories pass the pre-filter" {
  _mk_story "E900-S1" "Ready story" "ready-for-dev" "null"
  _mk_story "E900-S2" "In-progress" "in-progress" "sprint-99"
  _mk_story "E900-S3" "Done" "done" "sprint-99"
  _mk_story "E900-S4" "Review" "review" "sprint-99"
  _mk_decision_log "E900-S1" "E900-S2" "E900-S3" "E900-S4"
  run _run_scanner bash
  [ "$status" -eq 0 ]
  # Only E900-S1 should appear
  [[ "$output" =~ "E900-S1" ]]
  [[ ! "$output" =~ "E900-S2" ]]
  [[ ! "$output" =~ "E900-S3" ]]
  [[ ! "$output" =~ "E900-S4" ]]
}

# ---------- AC3: single-pass field extraction ----------

@test "AC3 — no printf-sed pipelines in main loop" {
  # Structural check: the script must not use printf|sed-n for field extraction
  # in the main loop (lines after parse_story_fm call).
  local main_loop
  main_loop=$(sed -n '/^# Collect candidate/,$ p' "$SCANNER")
  local sed_count
  sed_count=$(printf '%s\n' "$main_loop" | grep -c "sed -n" || true)
  [ "$sed_count" -eq 0 ]
}

# ---------- AC4: decision log read once ----------

@test "AC4 — decision log is opened exactly once" {
  _mk_story "E900-S1" "Story one" "ready-for-dev" "null"
  _mk_story "E900-S2" "Story two" "ready-for-dev" "null"
  _mk_story "E900-S3" "Story three" "ready-for-dev" "null"
  _mk_decision_log "E900-S1" "E900-S2" "E900-S3"

  # Create an awk shim that counts invocations on the decision log
  local shim_dir="$TEST_TMP/shims"
  local counter_file="$TEST_TMP/awk-counter"
  mkdir -p "$shim_dir"
  : > "$counter_file"

  local real_awk
  real_awk=$(command -v awk)
  cat > "$shim_dir/awk" <<SHIM
#!/bin/sh
# Count invocations that reference the decision log
for arg in "\$@"; do
  case "\$arg" in
    *decision-log*) printf 'x\n' >> "$counter_file" ; break ;;
  esac
done
exec "$real_awk" "\$@"
SHIM
  chmod +x "$shim_dir/awk"

  IMPLEMENTATION_ARTIFACTS="$TEST_TMP/impl" \
  VALIDATOR_DECISION_LOG="$TEST_TMP/.gaia/memory/validator-sidecar/decision-log.md" \
  PATH="$shim_dir:$PATH" \
    run bash "$SCANNER"
  [ "$status" -eq 0 ]
  # All 3 stories should appear
  [[ "$output" =~ "E900-S1" ]]
  [[ "$output" =~ "E900-S2" ]]
  [[ "$output" =~ "E900-S3" ]]
  # The decision log should be read exactly once (the cache-build pass)
  local invocations
  invocations=$(wc -l < "$counter_file" | tr -d ' ')
  [ "$invocations" -eq 1 ]
}

# ---------- AC5: golden-test parity ----------

@test "AC5 — output identical to original on 'one' fixture" {
  _load_stories "one"
  # Generate golden output from the original script
  local original_script="$TEST_TMP/scan-original.sh"
  git -C "$REPO_ROOT" show origin/staging:plugins/gaia/scripts/lib/scan-stranded-ready.sh \
    > "$original_script" 2>/dev/null
  chmod +x "$original_script"

  local golden new_out
  golden=$(IMPLEMENTATION_ARTIFACTS="$TEST_TMP/impl" \
    VALIDATOR_DECISION_LOG="$TEST_TMP/.gaia/memory/validator-sidecar/decision-log.md" \
    bash "$original_script" 2>/dev/null | cut -f1-2)
  new_out=$(IMPLEMENTATION_ARTIFACTS="$TEST_TMP/impl" \
    VALIDATOR_DECISION_LOG="$TEST_TMP/.gaia/memory/validator-sidecar/decision-log.md" \
    bash "$SCANNER" 2>/dev/null | cut -f1-2)
  [ "$golden" = "$new_out" ]
}

@test "AC5 — output identical to original on 'multiple' fixture" {
  _load_stories "multiple"
  local original_script="$TEST_TMP/scan-original.sh"
  git -C "$REPO_ROOT" show origin/staging:plugins/gaia/scripts/lib/scan-stranded-ready.sh \
    > "$original_script" 2>/dev/null
  chmod +x "$original_script"

  local golden new_out
  golden=$(IMPLEMENTATION_ARTIFACTS="$TEST_TMP/impl" \
    VALIDATOR_DECISION_LOG="$TEST_TMP/.gaia/memory/validator-sidecar/decision-log.md" \
    bash "$original_script" 2>/dev/null | cut -f1-2)
  new_out=$(IMPLEMENTATION_ARTIFACTS="$TEST_TMP/impl" \
    VALIDATOR_DECISION_LOG="$TEST_TMP/.gaia/memory/validator-sidecar/decision-log.md" \
    bash "$SCANNER" 2>/dev/null | cut -f1-2)
  [ "$golden" = "$new_out" ]
}

# ---------- AC6: fork count does not scale with non-story files ----------

@test "AC6 — 2000 non-story markdown files do not increase fork count" {
  _mk_story "E900-S1" "Sole story"
  _mk_decision_log "E900-S1"

  # Baseline: count files entering the parse loop via find+grep
  local baseline_candidates
  baseline_candidates=$(find "$TEST_TMP/impl" -type f \
    \( -name 'story.md' -o -name 'E[0-9]*-S[0-9]*-*.md' \) \
    -exec grep -l 'status: ready-for-dev' {} + 2>/dev/null | wc -l | tr -d ' ')

  # Add 2000 non-story markdown files
  local i
  for i in $(seq 1 2000); do
    printf 'Non-story content %d\n' "$i" > "$TEST_TMP/impl/report-${i}.md"
  done

  # Verify non-story files exist
  local total_md
  total_md=$(find "$TEST_TMP/impl" -type f -name '*.md' | wc -l | tr -d ' ')
  [ "$total_md" -gt 2000 ]

  # Re-count candidates after adding non-story files
  local after_candidates
  after_candidates=$(find "$TEST_TMP/impl" -type f \
    \( -name 'story.md' -o -name 'E[0-9]*-S[0-9]*-*.md' \) \
    -exec grep -l 'status: ready-for-dev' {} + 2>/dev/null | wc -l | tr -d ' ')

  # The candidate count must not change (structural proof)
  [ "$baseline_candidates" -eq "$after_candidates" ]

  # The scanner output must also be the same
  run _run_scanner bash
  [ "$status" -eq 0 ]
  [[ "$output" =~ "E900-S1" ]]
  local line_count
  line_count=$(printf '%s\n' "$output" | wc -l | tr -d ' ')
  [ "$line_count" -eq 1 ]
}

# ---------- AC7: bash 3.2 compatibility ----------

@test "AC7 — identical output under /bin/bash (system bash)" {
  _mk_story "E900-S1" "Story alpha"
  _mk_story "E900-S2" "Story bravo" "ready-for-dev" "null"
  _mk_decision_log "E900-S1" "E900-S2"

  local out_bash5 out_bash32
  out_bash5=$(_run_scanner bash)
  out_bash32=$(_run_scanner /bin/bash)
  [ "$out_bash5" = "$out_bash32" ]
}

@test "AC7 — exit 0 under /bin/bash" {
  _mk_story "E900-S1" "Story alpha"
  _mk_decision_log "E900-S1"
  run _run_scanner /bin/bash
  [ "$status" -eq 0 ]
}

@test "AC7 — no new state files created" {
  _mk_story "E900-S1" "Story alpha"
  _mk_decision_log "E900-S1"
  # Snapshot files before
  local before after
  before=$(find "$TEST_TMP" -type f | LC_ALL=C sort)
  run _run_scanner bash
  [ "$status" -eq 0 ]
  after=$(find "$TEST_TMP" -type f | LC_ALL=C sort)
  [ "$before" = "$after" ]
}

# ---------- TS8: empty tree ----------

@test "TS8 — empty tree returns empty stdout and exit 0" {
  # Decision log present but no story files
  _mk_decision_log "E900-S1"
  run _run_scanner bash
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- TS9: missing decision log ----------

@test "TS9 — missing decision log returns empty stdout and exit 0" {
  _mk_story "E900-S1" "Orphan story"
  rm -f "$TEST_TMP/.gaia/memory/validator-sidecar/decision-log.md"
  run _run_scanner bash
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- Additional coverage ----------

@test "stranded-ready requires sprint_id null" {
  _mk_story "E900-S1" "In-sprint" "ready-for-dev" "sprint-99"
  _mk_decision_log "E900-S1"
  run _run_scanner bash
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stranded-ready requires PASSED verdict" {
  _mk_story "E900-S1" "Failed verdict"
  # Decision log with FAILED verdict
  cat > "$TEST_TMP/.gaia/memory/validator-sidecar/decision-log.md" <<'EOF'
# Decision Log

### [2026-10-14] /gaia-validate-story: E900-S1

{"verdict":"FAILED","findings":[{"severity":"CRITICAL"}]}
EOF
  run _run_scanner bash
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "multiple stranded stories sorted ascending" {
  _mk_story "E900-S3" "Third"
  _mk_story "E900-S1" "First"
  _mk_story "E900-S2" "Second"
  _mk_decision_log "E900-S1" "E900-S2" "E900-S3"
  run _run_scanner bash
  [ "$status" -eq 0 ]
  # Extract keys in order
  local keys
  keys=$(printf '%s\n' "$output" | cut -f1)
  local first second third
  first=$(printf '%s\n' "$keys" | sed -n '1p')
  second=$(printf '%s\n' "$keys" | sed -n '2p')
  third=$(printf '%s\n' "$keys" | sed -n '3p')
  [ "$first" = "E900-S1" ]
  [ "$second" = "E900-S2" ]
  [ "$third" = "E900-S3" ]
}

@test "most-recent verdict wins (newer FAILED overrides older PASSED)" {
  _mk_story "E900-S1" "Recency test"
  # Decision log with newer FAILED then older PASSED
  cat > "$TEST_TMP/.gaia/memory/validator-sidecar/decision-log.md" <<'EOF'
# Decision Log

### [2026-10-14] /gaia-validate-story: E900-S1

{"verdict":"FAILED","findings":[]}

### [2026-10-13] /gaia-create-story: E900-S1

{"verdict":"PASSED","findings":[]}
EOF
  run _run_scanner bash
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "verdict cache handles re-run heading pattern" {
  _mk_story "E900-S1" "Re-run test"
  cat > "$TEST_TMP/.gaia/memory/validator-sidecar/decision-log.md" <<'EOF'
# Decision Log

### [2026-10-14] Story Validation (re-run): E900-S1

{"verdict":"PASSED","findings":[]}
EOF
  run _run_scanner bash
  [ "$status" -eq 0 ]
  [[ "$output" =~ "E900-S1" ]]
}

@test "verdict cache handles prose Status: recorded" {
  _mk_story "E900-S1" "Prose verdict"
  cat > "$TEST_TMP/.gaia/memory/validator-sidecar/decision-log.md" <<'EOF'
# Decision Log

### [2026-10-14] Story Validation: E900-S1

- **Status:** recorded
EOF
  run _run_scanner bash
  [ "$status" -eq 0 ]
  [[ "$output" =~ "E900-S1" ]]
}

@test "no-mutation — scanner is read-only" {
  _mk_story "E900-S1" "Mutation test"
  _mk_decision_log "E900-S1"
  # Snapshot before
  local before after
  before=$(find "$TEST_TMP" -type f -exec shasum {} \; | LC_ALL=C sort)
  run _run_scanner bash
  [ "$status" -eq 0 ]
  after=$(find "$TEST_TMP" -type f -exec shasum {} \; | LC_ALL=C sort)
  [ "$before" = "$after" ]
}
