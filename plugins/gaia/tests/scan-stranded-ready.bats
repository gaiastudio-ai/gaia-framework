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

# Helper: create PATH shims that count invocations of awk/grep/sed/cat.
# Sets FORK_SHIM_DIR and FORK_COUNTER_FILE. Run scanner with
# PATH="$FORK_SHIM_DIR:$PATH" then read: wc -l < "$FORK_COUNTER_FILE"
_mk_fork_counter() {
  FORK_SHIM_DIR="$TEST_TMP/fork-shims"
  FORK_COUNTER_FILE="$TEST_TMP/fork-counter"
  mkdir -p "$FORK_SHIM_DIR"
  : > "$FORK_COUNTER_FILE"

  local tool real_path
  for tool in awk grep sed cat; do
    real_path=$(command -v "$tool")
    cat > "$FORK_SHIM_DIR/$tool" <<SHIM
#!/bin/sh
printf '%s\n' "$tool" >> "$FORK_COUNTER_FILE"
exec "$real_path" "\$@"
SHIM
    chmod +x "$FORK_SHIM_DIR/$tool"
  done
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

@test "AC1 — reviews dir, report files, and review-summary files never opened" {
  # Four story layouts + four decoy types, with a grep-logging shim.
  _mk_story "E900-S1" "Modern story"

  # Legacy nested under stories/
  mkdir -p "$TEST_TMP/impl/epic-test/stories"
  cat > "$TEST_TMP/impl/epic-test/stories/E900-S2-legacy-slug.md" <<'EOF'
---
key: "E900-S2"
title: "Legacy nested story"
epic: "E900"
status: ready-for-dev
sprint_id: null
---
# Story: Legacy nested story
EOF

  # Legacy flat at impl root
  cat > "$TEST_TMP/impl/E900-S3-flat-story.md" <<'EOF'
---
key: "E900-S3"
title: "Legacy flat story"
epic: "E900"
status: ready-for-dev
sprint_id: null
---
# Story: Legacy flat story
EOF

  # Decoy: file under reviews/ — has ready-for-dev to lure grep
  mkdir -p "$TEST_TMP/impl/epic-test/reviews"
  cat > "$TEST_TMP/impl/epic-test/reviews/E900-S10-review.md" <<'EOF'
---
key: "E900-S10"
title: "Review decoy"
status: ready-for-dev
sprint_id: null
---
# Decoy in reviews dir
EOF

  # Decoy: story.md inside reviews/ (tests reviews/ exclusion for story.md)
  mkdir -p "$TEST_TMP/impl/epic-test/reviews/E900-S11-rogue"
  cat > "$TEST_TMP/impl/epic-test/reviews/E900-S11-rogue/story.md" <<'EOF'
---
key: "E900-S11"
title: "Story in reviews decoy"
status: ready-for-dev
sprint_id: null
---
# story.md inside reviews
EOF

  # Decoy: review-summary at impl root (suffix-filtered, not opened)
  cat > "$TEST_TMP/impl/E900-S12-review-summary.md" <<'EOF'
---
key: "E900-S12"
title: "Review summary decoy"
status: ready-for-dev
sprint_id: null
---
# Decoy review summary
EOF

  # Decoy: plan file under stories/ (suffix-filtered, not opened)
  cat > "$TEST_TMP/impl/epic-test/stories/E900-S13-plan.md" <<'EOF'
---
key: "E900-S13"
title: "Plan decoy"
status: ready-for-dev
sprint_id: null
---
# Decoy plan
EOF

  # Non-decoy: story whose slug ENDS in a report suffix — must still be scanned
  cat > "$TEST_TMP/impl/epic-test/stories/E900-S4-check-deps-glob-excludes-review-summary.md" <<'EOF'
---
key: "E900-S4"
title: "Story with review-summary in slug"
epic: "E900"
status: ready-for-dev
sprint_id: null
---
# A legitimate story with a slug ending in review-summary
EOF

  _mk_decision_log "E900-S1" "E900-S2" "E900-S3" "E900-S4" \
    "E900-S10" "E900-S11" "E900-S12" "E900-S13"

  # Shim grep to log which files it receives
  local shim_dir="$TEST_TMP/grep-shim"
  local opened_log="$TEST_TMP/grep-opened"
  mkdir -p "$shim_dir"
  : > "$opened_log"
  local real_grep
  real_grep=$(command -v grep)
  cat > "$shim_dir/grep" <<SHIM
#!/bin/sh
# Log every file argument passed to grep
for arg in "\$@"; do
  case "\$arg" in
    -*) ;; # skip flags
    *)
      if [ -f "\$arg" ]; then
        printf '%s\n' "\$arg" >> "$opened_log"
      fi
      ;;
  esac
done
exec "$real_grep" "\$@"
SHIM
  chmod +x "$shim_dir/grep"

  IMPLEMENTATION_ARTIFACTS="$TEST_TMP/impl" \
  VALIDATOR_DECISION_LOG="$TEST_TMP/.gaia/memory/validator-sidecar/decision-log.md" \
  PATH="$shim_dir:$PATH" \
    run bash "$SCANNER"
  [ "$status" -eq 0 ]

  # All four story types found
  [[ "$output" =~ "E900-S1" ]]
  [[ "$output" =~ "E900-S2" ]]
  [[ "$output" =~ "E900-S3" ]]
  [[ "$output" =~ "E900-S4" ]]

  # reviews/ files never opened
  local reviews_opened
  reviews_opened=$(grep -c 'reviews/' "$opened_log" || true)
  [ "$reviews_opened" -eq 0 ]

  # review-summary report file never opened
  local summary_opened
  summary_opened=$(grep -c 'E900-S12-review-summary' "$opened_log" || true)
  [ "$summary_opened" -eq 0 ]

  # plan report file never opened
  local plan_opened
  plan_opened=$(grep -c 'E900-S13-plan' "$opened_log" || true)
  [ "$plan_opened" -eq 0 ]

  # Story with slug ending in review-summary WAS opened (not false-excluded)
  local slug_story_opened
  slug_story_opened=$(grep -c 'excludes-review-summary' "$opened_log" || true)
  [ "$slug_story_opened" -ge 1 ]

  # Decoy keys must NOT appear in output
  [[ ! "$output" =~ "E900-S10" ]]
  [[ ! "$output" =~ "E900-S11" ]]
  [[ ! "$output" =~ "E900-S12" ]]
  [[ ! "$output" =~ "E900-S13" ]]
}

@test "AC1 — legacy flat E*-S*-*.md under stories/ is found" {
  # Legacy nested layout under the stories/ subdirectory
  mkdir -p "$TEST_TMP/impl/epic-test/stories"
  cat > "$TEST_TMP/impl/epic-test/stories/E900-S1-legacy-story.md" <<'EOF'
---
key: "E900-S1"
title: "Legacy nested story"
epic: "E900"
status: ready-for-dev
sprint_id: null
---
# Story: Legacy nested story
EOF
  _mk_decision_log "E900-S1"
  run _run_scanner bash
  [ "$status" -eq 0 ]
  [[ "$output" =~ "E900-S1" ]]
  [[ "$output" =~ "Legacy nested story" ]]
}

@test "AC1 — legacy flat E*-S*-*.md at root is found" {
  # Legacy flat layout at the implementation-artifacts root (maxdepth 1)
  cat > "$TEST_TMP/impl/E900-S1-root-story.md" <<'EOF'
---
key: "E900-S1"
title: "Root flat story"
epic: "E900"
status: ready-for-dev
sprint_id: null
---
# Story: Root flat story
EOF
  _mk_decision_log "E900-S1"
  run _run_scanner bash
  [ "$status" -eq 0 ]
  [[ "$output" =~ "E900-S1" ]]
  [[ "$output" =~ "Root flat story" ]]
}

# ---------- AC2: grep pre-filter ----------

@test "AC2 — grep pre-filter prevents parsing non-ready files" {
  # 1 ready-for-dev story + 20 non-ready story files with valid names
  _mk_story "E900-S1" "Ready story" "ready-for-dev" "null"
  local i
  for i in $(seq 2 21); do
    _mk_story "E900-S${i}" "Non-ready ${i}" "in-progress" "sprint-99"
  done
  _mk_decision_log "E900-S1"
  _mk_fork_counter

  # Run scanner with fork-counting shims
  IMPLEMENTATION_ARTIFACTS="$TEST_TMP/impl" \
  VALIDATOR_DECISION_LOG="$TEST_TMP/.gaia/memory/validator-sidecar/decision-log.md" \
  PATH="$FORK_SHIM_DIR:$PATH" \
    run bash "$SCANNER"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "E900-S1" ]]
  # Count awk invocations: expect exactly 2 (1 verdict cache + 1 parse of the
  # sole ready-for-dev candidate). Without the grep pre-filter, all 21 story
  # files would be parsed (21 awk forks + 1 = 22).
  local awk_count
  awk_count=$(grep -c '^awk$' "$FORK_COUNTER_FILE" || true)
  [ "$awk_count" -le 2 ]
}

# ---------- AC3: single-pass field extraction ----------

@test "AC3 — no per-candidate forking for field extraction" {
  # Create 5 ready-for-dev stories that all reach the parse-and-extract phase
  local i
  for i in $(seq 1 5); do
    _mk_story "E900-S${i}" "Story ${i}" "ready-for-dev" "null"
  done
  _mk_decision_log "E900-S1" "E900-S2" "E900-S3" "E900-S4" "E900-S5"
  _mk_fork_counter

  IMPLEMENTATION_ARTIFACTS="$TEST_TMP/impl" \
  VALIDATOR_DECISION_LOG="$TEST_TMP/.gaia/memory/validator-sidecar/decision-log.md" \
  PATH="$FORK_SHIM_DIR:$PATH" \
    run bash "$SCANNER"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "E900-S1" ]]
  [[ "$output" =~ "E900-S5" ]]
  # Expected forks: 1 awk (verdict cache) + 1 grep (find pre-filter) +
  # 5 awk (parse_story_fm, one per candidate) = 7 total.
  # A per-candidate field-splitting pipeline (printf|sed, printf|awk, head|tail)
  # adds at least 4 extra forks per candidate = 20 more, pushing total >= 27.
  # Allow a small margin for platform differences in find/grep, but reject any
  # implementation that forks for field extraction.
  local total_forks
  total_forks=$(wc -l < "$FORK_COUNTER_FILE" | tr -d ' ')
  # 7 expected + margin of 3 = max 10
  [ "$total_forks" -le 10 ]
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
  # Golden output generated from the original script (pre-fix) on these fixtures
  local golden
  golden=$(cat "$FIXTURE_ROOT/one/golden-output.tsv")
  local new_out
  new_out=$(_run_scanner bash 2>/dev/null | cut -f1-2)
  [ "$golden" = "$new_out" ]
}

@test "AC5 — output identical to original on 'multiple' fixture" {
  _load_stories "multiple"
  local golden
  golden=$(cat "$FIXTURE_ROOT/multiple/golden-output.tsv")
  local new_out
  new_out=$(_run_scanner bash 2>/dev/null | cut -f1-2)
  [ "$golden" = "$new_out" ]
}

# ---------- AC6: fork count does not scale with non-story files ----------

@test "AC6 — fork count flat across 2000 decoy non-story files" {
  _mk_story "E900-S1" "Sole story"
  _mk_decision_log "E900-S1"
  _mk_fork_counter

  # Baseline run: 1 story, no decoys
  IMPLEMENTATION_ARTIFACTS="$TEST_TMP/impl" \
  VALIDATOR_DECISION_LOG="$TEST_TMP/.gaia/memory/validator-sidecar/decision-log.md" \
  PATH="$FORK_SHIM_DIR:$PATH" \
    run bash "$SCANNER"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "E900-S1" ]]
  local baseline_forks
  baseline_forks=$(wc -l < "$FORK_COUNTER_FILE" | tr -d ' ')

  # Add 2000 decoy files: plain non-story, legacy-named review summaries,
  # and files containing the status text
  local i
  for i in $(seq 1 1800); do
    printf 'Non-story content %d\n' "$i" > "$TEST_TMP/impl/report-${i}.md"
  done
  # 100 review-summary decoys with legacy naming matching the find pattern
  mkdir -p "$TEST_TMP/impl/epic-test"
  for i in $(seq 1 100); do
    printf 'Review findings for sprint %d\n' "$i" \
      > "$TEST_TMP/impl/epic-test/E900-S9-review-summary-${i}.md"
  done
  # 100 decoys containing the status text but with non-matching filenames
  for i in $(seq 1 100); do
    printf 'status: ready-for-dev\n' > "$TEST_TMP/impl/assessment-${i}.md"
  done

  local total_md
  total_md=$(find "$TEST_TMP/impl" -type f -name '*.md' | wc -l | tr -d ' ')
  [ "$total_md" -gt 2000 ]

  # Re-run with decoys
  : > "$FORK_COUNTER_FILE"
  IMPLEMENTATION_ARTIFACTS="$TEST_TMP/impl" \
  VALIDATOR_DECISION_LOG="$TEST_TMP/.gaia/memory/validator-sidecar/decision-log.md" \
  PATH="$FORK_SHIM_DIR:$PATH" \
    run bash "$SCANNER"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "E900-S1" ]]
  local after_forks
  after_forks=$(wc -l < "$FORK_COUNTER_FILE" | tr -d ' ')

  # Fork count must not grow (tolerance: at most 2 for minor find/grep overhead)
  local diff=$((after_forks - baseline_forks))
  [ "$diff" -le 2 ]
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

# ---------- Malformed candidates must not abort the scan ----------

@test "malformed file with no key line is skipped, scan continues" {
  # A ready-for-dev story.md with no key: line — should be skipped
  local dir="$TEST_TMP/impl/epic-test/E900-S99-nokey"
  mkdir -p "$dir"
  cat > "$dir/story.md" <<'EOF'
---
title: "Missing key"
status: ready-for-dev
sprint_id: null
---
# Story without a key field
EOF
  # A valid stranded story alongside
  _mk_story "E900-S1" "Valid story"
  _mk_decision_log "E900-S1"
  run _run_scanner bash
  [ "$status" -eq 0 ]
  [[ "$output" =~ "E900-S1" ]]
  [[ ! "$output" =~ "Missing key" ]]
}

@test "review summary with no frontmatter is skipped, scan continues" {
  # A file matching the find pattern with status text but no YAML frontmatter
  mkdir -p "$TEST_TMP/impl/epic-test"
  cat > "$TEST_TMP/impl/epic-test/E900-S2-review-summary-pass1.md" <<'EOF'
# Review Summary

Findings from validation pass.

The story had status: ready-for-dev before implementation began.
EOF
  # A valid stranded story alongside
  _mk_story "E900-S1" "Valid story"
  _mk_decision_log "E900-S1"
  run _run_scanner bash
  [ "$status" -eq 0 ]
  [[ "$output" =~ "E900-S1" ]]
  local line_count
  line_count=$(printf '%s\n' "$output" | grep -c 'E900-S' || true)
  [ "$line_count" -eq 1 ]
}

# ---------- NUL-safe path handling ----------

@test "paths with embedded newlines are handled safely" {
  # Create a directory name containing a newline
  local nldir="$TEST_TMP/impl/epic-test/E900-S8-weird"$'\n'"dir-slug"
  mkdir -p "$nldir"
  cat > "$nldir/story.md" <<'EOF'
---
key: "E900-S8"
title: "Newline dir story"
status: ready-for-dev
sprint_id: null
---
# Newline directory test
EOF
  # A normal story alongside
  _mk_story "E900-S1" "Normal story"
  _mk_decision_log "E900-S1" "E900-S8"

  # Create a decoy file outside IMPLEMENTATION_ARTIFACTS
  mkdir -p "$TEST_TMP/outside"
  cat > "$TEST_TMP/outside/story.md" <<'EOF'
---
key: "E900-S99"
title: "Outside decoy"
status: ready-for-dev
sprint_id: null
---
# Should never appear
EOF

  # Capture only stdout (stderr may contain awk warnings on broken paths)
  local scanner_out
  scanner_out=$(_run_scanner bash 2>/dev/null)
  local rc=$?
  [ "$rc" -eq 0 ]
  # Check TSV output lines (tab-separated key, title, path)
  [[ "$scanner_out" =~ $'\t'"Normal story"$'\t' ]]
  [[ "$scanner_out" =~ $'\t'"Newline dir story"$'\t' ]]
  # Decoy outside the tree must not appear
  [[ ! "$scanner_out" =~ "E900-S99" ]]
}
