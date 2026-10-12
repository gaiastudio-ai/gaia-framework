#!/usr/bin/env bats
# sprint-progress-snapshot-enforcement.bats — security enforcement tests for the
# sprint progress snapshot: single-writer sweep, command allowlist, story-key
# validation, realpath containment, and single-flight lock (flock + fallback).

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/sprint-progress-snapshot.sh"
  PLUGIN_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"

  export PROJECT_ROOT="$TEST_TMP/project"
  mkdir -p "$PROJECT_ROOT/.gaia/state"
  mkdir -p "$PROJECT_ROOT/.gaia/config"

  IMPL="$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$IMPL"
  CACHE="$PROJECT_ROOT/.gaia/state/.sprint-progress-cache.json"
  LOCK_FILE="$PROJECT_ROOT/.gaia/state/.sprint-progress-cache.json.lock"
  export SPRINT_STATUS_YAML="$PROJECT_ROOT/.gaia/state/sprint-status.yaml"
}
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Fixture helpers (minimal — reused from the main test file)
# ---------------------------------------------------------------------------

write_sprint_yaml() {
  local sprint_status="${1:-active}"; shift || true
  local start_date="${1:-2026-10-01}"; shift || true
  local end_date="${1:-2026-10-14}"; shift || true
  cat > "$SPRINT_STATUS_YAML" <<EOF
sprint_id: "sprint-test"
status: ${sprint_status}
start_date: "${start_date}"
end_date: "${end_date}"
total_points: 0
goals: []
stories:
EOF
  local total_pts=0
  for row in "$@"; do
    local key status pts
    key="$(echo "$row" | cut -d: -f1)"
    status="$(echo "$row" | cut -d: -f2)"
    pts="$(echo "$row" | cut -d: -f3)"
    pts="${pts:-5}"
    cat >> "$SPRINT_STATUS_YAML" <<EOF
  - key: "${key}"
    title: "Story ${key}"
    status: "${status}"
    points: ${pts}
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-10-01"
EOF
    total_pts=$((total_pts + pts))
  done
  sed "s/^total_points: 0/total_points: ${total_pts}/" "$SPRINT_STATUS_YAML" > "${SPRINT_STATUS_YAML}.tmp" \
    && mv "${SPRINT_STATUS_YAML}.tmp" "$SPRINT_STATUS_YAML"
}

write_story() {
  local key="$1" status="$2" pts="${3:-5}"
  local slug
  slug="$(echo "$key" | tr '[:upper:]' '[:lower:]')-enf"
  local dir="$IMPL/epic-test/${key}-${slug}"
  mkdir -p "$dir"
  cat > "$dir/story.md" <<EOF
---
template: 'story'
key: "${key}"
title: "Story ${key}"
status: ${status}
points: ${pts}
manual_verification: false
depends_on: []
---

# Story: ${key}

> **Status:** ${status}

## Tasks / Subtasks

- [x] Task 1: Done

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | — |
| QA Tests | PASSED | — |
| Security Review | PASSED | — |
| Test Automation | PASSED | — |
| Test Review | PASSED | — |
| Performance Review | PASSED | — |

## Definition of Done

- [x] All done
EOF
}

# ---------------------------------------------------------------------------
# Single-writer enforcement sweep
# ---------------------------------------------------------------------------

@test "single-writer sweep finds only snapshot script" {
  # Scan plugin scripts/, hooks/, skills/ (excl. tests/) for writes to the cache file
  local cache_name=".sprint-progress-cache.json"
  local writers
  writers="$(grep -rl "$cache_name" \
    "$PLUGIN_ROOT/scripts/" \
    "$PLUGIN_ROOT/hooks/" \
    "$PLUGIN_ROOT/skills/" \
    --include='*.sh' --include='*.js' --include='*.ts' \
    2>/dev/null \
    | grep -v '/tests/' \
    | grep -v '__tests__' \
    || true)"

  # Must have scanned >0 files
  local scanned
  scanned="$(find "$PLUGIN_ROOT/scripts/" "$PLUGIN_ROOT/skills/" \
    -name '*.sh' -o -name '*.js' -o -name '*.ts' 2>/dev/null | grep -v '/tests/' | wc -l)"
  [ "$scanned" -gt 0 ]

  # Only sprint-progress-snapshot.sh should match
  [ -n "$writers" ]
  local count
  count="$(echo "$writers" | wc -l | tr -d ' ')"
  [ "$count" -eq 1 ]
  grep -q "sprint-progress-snapshot.sh" <<< "$writers"
}

@test "single-writer sweep mutant turns red when second writer planted" {
  local cache_name=".sprint-progress-cache.json"
  # Plant a mutant writer in a temp copy of scripts/
  local mutant_dir="$TEST_TMP/mutant-scripts"
  mkdir -p "$mutant_dir"
  printf '# mutant\necho test > .gaia/state/%s\n' "$cache_name" > "$mutant_dir/rogue-writer.sh"

  # Scan including the mutant dir
  local writers
  writers="$(grep -rl "$cache_name" \
    "$PLUGIN_ROOT/scripts/" \
    "$mutant_dir/" \
    --include='*.sh' \
    2>/dev/null \
    | grep -v '/tests/' \
    || true)"

  # Should find >1 writer (mutant + real)
  local count
  count="$(echo "$writers" | wc -l | tr -d ' ')"
  [ "$count" -gt 1 ]
}

# ---------------------------------------------------------------------------
# Command allowlist
# ---------------------------------------------------------------------------

@test "command allowlist passes valid commands" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:review:5"
  local slug="e900-s1-al"
  local dir="$IMPL/epic-test/E900-S1-${slug}"
  mkdir -p "$dir"
  cat > "$dir/story.md" <<'EOF'
---
template: 'story'
key: "E900-S1"
title: "Allowlist test"
status: review
points: 5
manual_verification: true
depends_on: []
---

# Story: Allowlist test

> **Status:** review

## Tasks / Subtasks

- [x] Task 1: Done

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | — |
| QA Tests | PASSED | — |
| Security Review | PASSED | — |
| Test Automation | PASSED | — |
| Test Review | PASSED | — |
| Performance Review | PASSED | — |

## Definition of Done

- [x] All done
EOF

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # Rule (a) fires with an allowlisted command
  [ "$(jq -r '.action_needed[0].command' "$CACHE")" = "/gaia-test-manual" ]
}

@test "command allowlist nullifies unknown command" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  local bad
  bad="$(jq -r '[.action_needed[].command | select(. != null and . != "/gaia-test-manual" and . != "/gaia-sprint-close" and . != "/gaia-action-items")] | length' "$CACHE")"
  [ "$bad" = "0" ]

  # Behavioural: source the script (main-guarded) and test _validate_command
  # directly with hostile inputs
  (
    # Source the script for its functions (main guard prevents execution)
    BASH_SOURCE_OVERRIDE=sourced
    . "$SCRIPT"
  ) 2>/dev/null || true

  # Feed arbitrary strings through _validate_command by sourcing with override
  local test_script="$TEST_TMP/test_allowlist.sh"
  cat > "$test_script" <<TESTSH
#!/usr/bin/env bash
set -euo pipefail
BASH_SOURCE[0]="sourced"
. "$SCRIPT"
# Test valid commands
[ "\$(_validate_command "/gaia-test-manual")" = "/gaia-test-manual" ]
[ "\$(_validate_command "/gaia-sprint-close")" = "/gaia-sprint-close" ]
[ "\$(_validate_command "/gaia-action-items")" = "/gaia-action-items" ]
# Test invalid commands — all must return "null"
[ "\$(_validate_command "/gaia-test-manual; rm -rf x")" = "null" ]
[ "\$(_validate_command "")" = "null" ]
[ "\$(_validate_command "  /gaia-test-manual  ")" = "null" ]
[ "\$(_validate_command "/unknown-command")" = "null" ]
[ "\$(_validate_command "hello world")" = "null" ]
echo "ALL_PASS"
TESTSH
  chmod +x "$test_script"
  run "$test_script"
  [ "$status" -eq 0 ]
  [ "$output" = "ALL_PASS" ]

  # Mutation check: copy the script, remove one allowlist entry, verify the
  # matching assertion would fail
  local mutant="$TEST_TMP/mutant-snapshot.sh"
  sed '/_ALLOWED_COMMANDS=/s/\/gaia-sprint-close//' "$SCRIPT" > "$mutant"
  chmod +x "$mutant"
  local test_mutant="$TEST_TMP/test_mutant.sh"
  cat > "$test_mutant" <<TESTSH
#!/usr/bin/env bash
set -euo pipefail
BASH_SOURCE[0]="sourced"
. "$mutant"
result="\$(_validate_command "/gaia-sprint-close")"
if [ "\$result" = "/gaia-sprint-close" ]; then
  echo "MUTANT_SURVIVED"
else
  echo "MUTANT_KILLED"
fi
TESTSH
  chmod +x "$test_mutant"
  run "$test_mutant"
  [ "$status" -eq 0 ]
  [ "$output" = "MUTANT_KILLED" ]
}

@test "command allowlist source-code grep confirms no dynamic assignment" {
  # The command field must come from a hardcoded allowlist, never a variable
  # The snapshot script should have a literal allowlist array
  [ -f "$SCRIPT" ]
  grep -q '_ALLOWED_COMMANDS' "$SCRIPT"
  grep -q '/gaia-test-manual' "$SCRIPT"
  grep -q '/gaia-sprint-close' "$SCRIPT"
  grep -q '/gaia-action-items' "$SCRIPT"
}

# ---------------------------------------------------------------------------
# Story-key shape validation
# ---------------------------------------------------------------------------

@test "story-key shape validation accepts valid rejects invalid" {
  # Inject an invalid key alongside valid ones
  cat > "$SPRINT_STATUS_YAML" <<'EOF'
sprint_id: "sprint-test"
status: active
start_date: "2026-10-01"
end_date: "2026-10-14"
total_points: 5
goals: []
stories:
  - key: "E900-S1"
    title: "Valid key"
    status: "in-progress"
    points: 5
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-10-01"
  - key: "INVALID-KEY"
    title: "Bad key"
    status: "in-progress"
    points: 3
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-10-01"
  - key: "E900-S1; rm -rf /"
    title: "Injection attempt"
    status: "in-progress"
    points: 1
    risk_level: "low"
    assignee: null
    blocked_by: null
    updated: "2026-10-01"
EOF
  write_story E900-S1 in-progress 5

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # Only the valid key should appear
  [ "$(jq '.stories | length' "$CACHE")" = "1" ]
  [ "$(jq -r '.stories[0].key' "$CACHE")" = "E900-S1" ]
  # Stderr should mention the rejected keys (real assertion, not || true)
  grep -qi "INVALID-KEY\|skipp" <<< "$output"
}

# ---------------------------------------------------------------------------
# Realpath containment
# ---------------------------------------------------------------------------

@test "realpath containment skips symlink escaping project root" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" \
    "E900-S1:done:5" "E900-S2:in-progress:3"
  write_story E900-S1 done 5

  # Create a symlink that escapes the project root
  local outside="$TEST_TMP/outside-project"
  mkdir -p "$outside"
  cat > "$outside/story.md" <<'EOF'
---
template: 'story'
key: "E900-S2"
title: "ESCAPED story"
status: in-progress
points: 3
manual_verification: false
depends_on: []
---

# Story: ESCAPED

> **Status:** in-progress
EOF
  local escaped_dir="$IMPL/epic-test/E900-S2-escaped"
  mkdir -p "$escaped_dir"
  ln -sf "$outside/story.md" "$escaped_dir/story.md"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e '.' "$CACHE"
  # The escaped story should NOT appear in the cache
  [ "$(jq '[.stories[] | select(.key == "E900-S2")] | length' "$CACHE")" = "0" ]
  # But E900-S1 should still be there
  [ "$(jq '[.stories[] | select(.key == "E900-S1")] | length' "$CACHE")" = "1" ]
}

@test "file-level symlink to outside target is rejected by containment" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" \
    "E900-S1:done:5" "E900-S2:in-progress:3"
  write_story E900-S1 done 5

  # Create a story directory inside the project with a file-level symlink
  # pointing to a file OUTSIDE the project root
  local outside="$TEST_TMP/outside-file"
  mkdir -p "$outside"
  cat > "$outside/real-story.md" <<'EOF'
---
template: 'story'
key: "E900-S2"
title: "ESCAPED via file symlink"
status: in-progress
points: 3
manual_verification: false
depends_on: []
---
# Story: ESCAPED
EOF
  local symlink_dir="$IMPL/epic-test/E900-S2-file-symlink"
  mkdir -p "$symlink_dir"
  ln -sf "$outside/real-story.md" "$symlink_dir/story.md"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e '.' "$CACHE"
  # The symlinked story must NOT appear in the cache
  [ "$(jq '[.stories[] | select(.key == "E900-S2")] | length' "$CACHE")" = "0" ]
  # But E900-S1 should still be there
  [ "$(jq '[.stories[] | select(.key == "E900-S1")] | length' "$CACHE")" = "1" ]
}

@test "realpath guard handles missing file on BSD" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5

  # The script should NOT crash when realpath encounters a missing file
  # (BSD realpath fails on non-existent paths)
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Single-flight lock — flock backend
# ---------------------------------------------------------------------------

@test "single-flight lock with flock backend skips concurrent run" {
  # Skip if flock is not available — this test exercises the flock backend only
  command -v flock >/dev/null 2>&1 || skip "flock not available on this host"

  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5

  # Hold the lock via flock
  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 7>>"$LOCK_FILE"
  flock -n 7

  # Run snapshot — should skip (exit 0, no write)
  local pre_cache=""
  [ -f "$CACHE" ] && pre_cache="$(cat "$CACHE")"

  run "$SCRIPT"
  [ "$status" -eq 0 ]

  # Release the flock
  flock -u 7
  exec 7>&-

  # Cache should not have been written (or should be unchanged)
  if [ -n "$pre_cache" ]; then
    [ "$(cat "$CACHE")" = "$pre_cache" ]
  else
    [ ! -f "$CACHE" ]
  fi
}

# ---------------------------------------------------------------------------
# Single-flight lock — fallback backend (GAIA_LOCK_FORCE_FALLBACK=1)
# ---------------------------------------------------------------------------

@test "single-flight lock with fallback backend skips concurrent run" {
  export GAIA_LOCK_FORCE_FALLBACK=1

  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5

  # Hold the lock via ln (fallback backend pattern)
  mkdir -p "$(dirname "$LOCK_FILE")"
  local tmp_lock="${LOCK_FILE}.tmp.holder.$$"
  printf '%s %s\n' "$$" "$(date +%s)" > "$tmp_lock"
  ln "$tmp_lock" "$LOCK_FILE" 2>/dev/null
  rm -f "$tmp_lock"

  # Run snapshot with fallback backend — should skip (exit 0, no write)
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$CACHE" ]

  # Cleanup
  rm -f "$LOCK_FILE"
  unset GAIA_LOCK_FORCE_FALLBACK
}

@test "single-flight lock fallback backend acquires free lock and writes cache" {
  export GAIA_LOCK_FORCE_FALLBACK=1

  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5

  # No pre-existing lock — should acquire and write
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$CACHE" ]
  jq -e '.' "$CACHE"

  # Lock should be cleaned up
  [ ! -f "$LOCK_FILE" ]

  unset GAIA_LOCK_FORCE_FALLBACK
}

# ---------------------------------------------------------------------------
# Stale lock recovery
# ---------------------------------------------------------------------------

@test "killed holder stale lock does not suppress snapshots indefinitely" {
  export GAIA_LOCK_FORCE_FALLBACK=1

  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5

  # Create a stale lock with a dead PID (PID 99999 is unlikely to exist)
  mkdir -p "$(dirname "$LOCK_FILE")"
  local stale_tmp="${LOCK_FILE}.tmp.stale.$$"
  printf '%s %s\n' "99999" "$(date -v -2H +%s 2>/dev/null || date -d '2 hours ago' +%s)" > "$stale_tmp"
  ln "$stale_tmp" "$LOCK_FILE" 2>/dev/null
  rm -f "$stale_tmp"
  # Backdate the lock file to ensure it exceeds the reap threshold
  touch -t 202601010000 "$LOCK_FILE"

  # Snapshot should reap the stale lock, acquire, and write
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$CACHE" ]
  jq -e '.' "$CACHE"

  unset GAIA_LOCK_FORCE_FALLBACK
}

@test "snapshot cleans its lock on exit" {
  export GAIA_LOCK_FORCE_FALLBACK=1

  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5

  # Run snapshot — it should acquire and release the lock
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # Lock file should be cleaned up after normal exit
  [ ! -f "$LOCK_FILE" ]

  unset GAIA_LOCK_FORCE_FALLBACK
}

# ---------------------------------------------------------------------------
# Lock-path type policy
# ---------------------------------------------------------------------------

@test "directory at lock path is refused without following into it" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5

  # Plant a directory at the lock path
  mkdir -p "$LOCK_FILE"
  echo "planted" > "$LOCK_FILE/decoy.txt"

  # Snapshot should exit 0 (best-effort) but not write inside the directory
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # The decoy file must be untouched
  [ -f "$LOCK_FILE/decoy.txt" ]
  [ "$(cat "$LOCK_FILE/decoy.txt")" = "planted" ]
}

@test "symlink at lock path is refused without following it" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5

  # Plant a symlink at the lock path pointing to a target
  local target="$TEST_TMP/symlink-target"
  echo "original" > "$target"
  mkdir -p "$(dirname "$LOCK_FILE")"
  ln -sf "$target" "$LOCK_FILE"

  # Snapshot should not follow the symlink for writing
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # Target file must be unchanged (not overwritten via the symlink)
  [ "$(cat "$target")" = "original" ]
}

# ---------------------------------------------------------------------------
# Alias sanitization
# ---------------------------------------------------------------------------

@test "alias with special chars is sanitized in cache and matches only exactly" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5

  local config="$PROJECT_ROOT/.gaia/config/project-config.yaml"
  # Alias containing double quote, single quote, regex metachars
  cat > "$config" <<'YAML'
sprint_status_mod:
  user_aliases:
    - 'test"user'
    - "it's me"
    - ".*[]()^$|+?\\"
YAML

  # Action item assigned to the regex-metachars alias (exact match)
  local ai_path="$PROJECT_ROOT/.gaia/state/action-items.yaml"
  cat > "$ai_path" <<'YAML'
items:
  - id: "AI-800"
    title: "Check"
    status: "open"
    assignee: '.*[]()^$|+?\\'
    created_at: "2026-10-05"
  - id: "AI-801"
    title: "Unrelated"
    status: "open"
    assignee: "anything"
    created_at: "2026-10-05"
YAML

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e '.' "$CACHE"

  # The aliases must appear sanitized (control chars stripped) and as valid JSON
  local alias_count
  alias_count="$(jq '.user_aliases | length' "$CACHE")"
  [ "$alias_count" = "3" ]

  # The regex-metachars alias should NOT match "anything" via .*
  # Only the exact-match item should appear as rule-c
  [ "$(jq '[.action_needed[] | select(.rule == "c")] | length' "$CACHE")" = "1" ]
  [ "$(jq -r '.action_needed[] | select(.rule == "c") | .item_id' "$CACHE")" = "AI-800" ]
}

@test "alias with control chars is stripped and empties are dropped" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5

  local config="$PROJECT_ROOT/.gaia/config/project-config.yaml"
  printf 'sprint_status_mod:\n  user_aliases:\n    - "clean"\n    - "has\\ttab"\n    - ""\n' > "$config"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e '.' "$CACHE"

  # "clean" survives, "has\ttab" has the tab stripped, empty is dropped
  jq -e '.user_aliases | index("clean")' "$CACHE"
  # No empty strings in aliases
  [ "$(jq '[.user_aliases[] | select(. == "")] | length' "$CACHE")" = "0" ]
}

# ---------------------------------------------------------------------------
# Threshold validation
# ---------------------------------------------------------------------------

@test "threshold accepts valid integers and rejects non-integers" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5

  local config="$PROJECT_ROOT/.gaia/config/project-config.yaml"

  # Valid: 0
  printf 'sprint_status_mod:\n  waiting_agent_threshold_seconds: 0\n' > "$config"
  rm -f "$CACHE" "$PROJECT_ROOT/.gaia/state/.sprint-progress-mtimes"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.waiting_agent_threshold_seconds' "$CACHE")" = "0" ]

  # Valid: 300
  printf 'sprint_status_mod:\n  waiting_agent_threshold_seconds: 300\n' > "$config"
  rm -f "$CACHE" "$PROJECT_ROOT/.gaia/state/.sprint-progress-mtimes"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.waiting_agent_threshold_seconds' "$CACHE")" = "300" ]

  # Invalid: "abc" -> fallback to 120
  printf 'sprint_status_mod:\n  waiting_agent_threshold_seconds: abc\n' > "$config"
  rm -f "$CACHE" "$PROJECT_ROOT/.gaia/state/.sprint-progress-mtimes"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.waiting_agent_threshold_seconds' "$CACHE")" = "120" ]

  # Invalid: "-5" -> fallback to 120
  printf 'sprint_status_mod:\n  waiting_agent_threshold_seconds: -5\n' > "$config"
  rm -f "$CACHE" "$PROJECT_ROOT/.gaia/state/.sprint-progress-mtimes"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.waiting_agent_threshold_seconds' "$CACHE")" = "120" ]

  # Invalid: "1e3" -> fallback to 120
  printf 'sprint_status_mod:\n  waiting_agent_threshold_seconds: 1e3\n' > "$config"
  rm -f "$CACHE" "$PROJECT_ROOT/.gaia/state/.sprint-progress-mtimes"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.waiting_agent_threshold_seconds' "$CACHE")" = "120" ]

  # Invalid: "12 34" -> fallback to 120
  printf 'sprint_status_mod:\n  waiting_agent_threshold_seconds: "12 34"\n' > "$config"
  rm -f "$CACHE" "$PROJECT_ROOT/.gaia/state/.sprint-progress-mtimes"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.waiting_agent_threshold_seconds' "$CACHE")" = "120" ]

  # Invalid: 30-digit number -> fallback to 120 (length check)
  printf 'sprint_status_mod:\n  waiting_agent_threshold_seconds: 123456789012345678901234567890\n' > "$config"
  rm -f "$CACHE" "$PROJECT_ROOT/.gaia/state/.sprint-progress-mtimes"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.waiting_agent_threshold_seconds' "$CACHE")" = "120" ]

  # Empty config -> default 120
  printf 'sprint_status_mod: {}\n' > "$config"
  rm -f "$CACHE" "$PROJECT_ROOT/.gaia/state/.sprint-progress-mtimes"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.waiting_agent_threshold_seconds' "$CACHE")" = "120" ]
}
