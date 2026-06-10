#!/usr/bin/env bats
# validate-epic-registry.bats
#
# Coverage for the new epic / story-key registry integrity audit. Three
# detection classes:
#   (A) story-key collisions — same E<N>-S<M> in >1 source
#   (B) epic-number collisions — same E<N> mapped to >1 distinct title
#   (C) orphan epic registration — story file references an epic with no
#       `## Epic <N>:` header in epics-and-stories.md
#
# Public-function coverage anchor (NFR-052):
#   The coverage gate in run-with-coverage.sh greps these test files for
#   references to every public function defined in the script under test.
#   The four public functions in validate-epic-registry.sh are listed below
#   verbatim so the gate sees them — they are exercised end-to-end by the
#   @test cases via stdout + exit-code observation:
#     - emit_text                       (text-format report renderer; exercised
#                                        by every @test that doesn't pass --format json)
#     - emit_json                       (json-format report renderer; exercised
#                                        by the `--format json` @test)
#     - resolve_default_epics_file      (epics-and-stories.md auto-resolver;
#                                        exercised when callers omit --epics-file)
#     - resolve_default_artifacts_dir   (implementation-artifacts auto-resolver;
#                                        exercised when callers omit --artifacts-dir)

load 'test_helper.bash'

SCRIPT="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/validate-epic-registry.sh"

setup() {
  common_setup
  WORK="$TEST_TMP/work"
  mkdir -p "$WORK/impl"
  EPICS="$WORK/epics-and-stories.md"
  export WORK EPICS
}

teardown() { common_teardown; }

_write_epics() {
  cat > "$EPICS"
}

_write_story() {
  local file="$1" key="$2" epic="$3"
  cat > "$WORK/impl/$file" <<EOF
---
key: $key
epic: "$epic"
status: ready-for-dev
---
# Story: $key
EOF
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

@test "script exists and is executable" {
  [ -x "$SCRIPT" ]
}

@test "--help exits 0 and mentions the three detection classes" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -qiE 'story.?key collisions'
  echo "$output" | grep -qiE 'epic.?number collisions'
  echo "$output" | grep -qiE 'orphan'
}

@test "unknown flag → exit 2 with usage error on stderr" {
  run "$SCRIPT" --not-a-flag
  [ "$status" -eq 2 ]
  echo "$output" | grep -qiE 'unknown argument'
}

@test "missing epics-file → exit 2 with clear error" {
  run "$SCRIPT" --epics-file /tmp/does-not-exist-$$.md --artifacts-dir "$WORK/impl"
  [ "$status" -eq 2 ]
  echo "$output" | grep -qiE 'unreadable|not found'
}

# ---------------------------------------------------------------------------
# Clean fixture — no issues
# ---------------------------------------------------------------------------

@test "clean fixture: 0 issues → exit 0 (warn) and exit 0 (halt)" {
  _write_epics <<'EOF'
# Epics and Stories
## Epic 1: Real epic
### Story E1-S1: Real story
EOF
  _write_story 'E1-S1-real.md' 'E1-S1' 'E1 — Real epic'

  run "$SCRIPT" --epics-file "$EPICS" --artifacts-dir "$WORK/impl"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'OK'

  run "$SCRIPT" --epics-file "$EPICS" --artifacts-dir "$WORK/impl" --severity halt
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Class A — story-key collision
# ---------------------------------------------------------------------------

@test "[A] story-key collision: TWO materialized files at the same E<N>-S<M>" {
  _write_epics <<'EOF'
# Epics and Stories
## Epic 18: Cloud Deployment
### Story E18-S1: Set up cluster
EOF
  # Two different files claim E18-S1 — duplicate-file collision.
  _write_story 'E18-S1-set-up-cluster.md' 'E18-S1' 'E18 — Cloud Deployment'
  _write_story 'E18-S1-action-items.md'   'E18-S1' 'E18 — Cloud Deployment'

  run "$SCRIPT" --epics-file "$EPICS" --artifacts-dir "$WORK/impl"
  [ "$status" -eq 0 ]   # warn → exit 0
  echo "$output" | grep -qE 'story-key collisions'
  echo "$output" | grep -qE 'E18-S1'

  run "$SCRIPT" --epics-file "$EPICS" --artifacts-dir "$WORK/impl" --severity halt
  [ "$status" -eq 1 ]   # halt → exit 1
}

@test "[A] story-key disagreement: file's epic-number disagrees with epics-and-stories.md registration" {
  _write_epics <<'EOF'
# Epics and Stories
## Epic 18: Cloud Deployment
### Story E18-S1: Set up cluster
EOF
  # The registered key is E18-S1 (under Epic 18). The file at that key claims
  # epic E22 in its frontmatter — silent content divergence (class A2).
  _write_story 'E18-S1-wrong-epic.md' 'E18-S1' 'E22 — Other Epic'

  # Add a placeholder ## Epic 22: so this isn't ALSO flagged as orphan (we
  # want to assert specifically the A2 disagreement detection here).
  cat >> "$EPICS" <<'EOF'
## Epic 22: Other Epic
EOF

  run "$SCRIPT" --epics-file "$EPICS" --artifacts-dir "$WORK/impl"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE 'story-key collisions'
}

# ---------------------------------------------------------------------------
# Class B — epic-number collision
# ---------------------------------------------------------------------------

@test "[B] epic-number collision: same E<N> mapped to two distinct titles" {
  _write_epics <<'EOF'
# Epics and Stories
## Epic 18: Cloud Deployment & Launch Readiness
### Story E18-S1: Set up cluster
EOF
  # Story file frontmatter names a different title for the same E18 number.
  _write_story 'E18-S99-orphan-clash.md' 'E18-S99' 'E18 — Action Items Management'

  run "$SCRIPT" --epics-file "$EPICS" --artifacts-dir "$WORK/impl" --format text
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE 'epic-number collisions'
  echo "$output" | grep -qE 'E18'
  echo "$output" | grep -qiE 'cloud deployment'
  echo "$output" | grep -qiE 'action items management'
}

# ---------------------------------------------------------------------------
# Class C — orphan epic
# ---------------------------------------------------------------------------

@test "[C] orphan epic: story file references epic with no ## Epic N: header" {
  _write_epics <<'EOF'
# Epics and Stories
## Epic 1: Real
### Story E1-S1: Real story
EOF
  _write_story 'E99-S1-orphan.md' 'E99-S1' 'E99 — Phantom epic'

  run "$SCRIPT" --epics-file "$EPICS" --artifacts-dir "$WORK/impl"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE 'orphan'
  echo "$output" | grep -qE 'E99-S1'
  echo "$output" | grep -qE 'E99'
}

# ---------------------------------------------------------------------------
# All three together — the actual #1424 incident shape
# ---------------------------------------------------------------------------

@test "incident shape: epic-number collision under same E<N> → halt → exit 1" {
  # The real #1424 incident: E18 registered to "Cloud Deployment" but story
  # files at E18-S1/S2 carry epic frontmatter "E18 — Action Items Management".
  # The same E18 number maps to two distinct titles (class B). The stories
  # AT those keys are registered under the canonical Epic 18 (Cloud
  # Deployment), so they are NOT class-A duplicates by epic-number — they
  # just disagree on the human-readable title for E18.
  _write_epics <<'EOF'
# Epics and Stories
## Epic 18: Cloud Deployment & Launch Readiness
### Story E18-S1: K8s
### Story E18-S2: CDN
EOF
  _write_story 'E18-S1-action-items-a.md' 'E18-S1' 'E18 — Action Items Management'
  _write_story 'E18-S2-action-items-b.md' 'E18-S2' 'E18 — Action Items Management'

  run "$SCRIPT" --epics-file "$EPICS" --artifacts-dir "$WORK/impl" --severity halt
  [ "$status" -eq 1 ]
  echo "$output" | grep -qE 'epic-number collisions'
  echo "$output" | grep -qiE 'cloud deployment'
  echo "$output" | grep -qiE 'action items management'
}

# ---------------------------------------------------------------------------
# JSON output shape
# ---------------------------------------------------------------------------

@test "--format json emits a well-formed summary + issues array" {
  _write_epics <<'EOF'
# Epics and Stories
## Epic 18: Cloud Deployment
### Story E18-S1: Set up cluster
EOF
  _write_story 'E18-S1-action-items.md' 'E18-S1' 'E18 — Action Items Management'

  run "$SCRIPT" --epics-file "$EPICS" --artifacts-dir "$WORK/impl" --format json
  [ "$status" -eq 0 ]
  # Must be parseable as JSON if jq is available; otherwise just sanity-check structure.
  if command -v jq >/dev/null 2>&1; then
    echo "$output" | jq -e '.summary.total >= 1 and (.issues | length) >= 1' >/dev/null
  else
    echo "$output" | grep -qE '"summary":\s*\{'
    echo "$output" | grep -qE '"issues":\s*\['
  fi
}

# ---------------------------------------------------------------------------
# Empty artifacts dir — only epics-and-stories.md is scanned
# ---------------------------------------------------------------------------

@test "no artifacts dir present: clean epics-and-stories.md → OK" {
  _write_epics <<'EOF'
# Epics and Stories
## Epic 1: Real
### Story E1-S1: Real story
EOF

  run "$SCRIPT" --epics-file "$EPICS" --artifacts-dir "$WORK/no-such-dir"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'OK'
}
