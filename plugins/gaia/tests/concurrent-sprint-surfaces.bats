#!/usr/bin/env bats
# concurrent-sprint-surfaces.bats — tests for per-sprint cache, multi-sprint
# overview, statusline +N indicator, closed sprint cleanup, and concurrent
# mode surface behaviour.

# bats file_tags=sprint-progress,concurrent

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$(snapshot_script_under_test "$SCRIPTS_DIR/sprint-progress-snapshot.sh")"
  DASHBOARD="$SCRIPTS_DIR/sprint-status-dashboard.sh"
  STATUSLINE="$SCRIPTS_DIR/statusline.sh"

  # Fixture tree: mimic a .gaia project layout inside TEST_TMP
  export PROJECT_ROOT="$TEST_TMP/project"
  mkdir -p "$PROJECT_ROOT/.gaia/state"
  mkdir -p "$PROJECT_ROOT/.gaia/config"
  mkdir -p "$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts"

  STATE_DIR="$PROJECT_ROOT/.gaia/state"
  IMPL="$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts"
  export SPRINT_STATUS_YAML="$STATE_DIR/sprint-status.yaml"
  export IMPLEMENTATION_ARTIFACTS="$IMPL"
  export GAIA_SNAPSHOT_HOOK_DISABLE=1

  # Write a minimal project-config.yaml with concurrent mode enabled.
  cat > "$PROJECT_ROOT/.gaia/config/project-config.yaml" <<'EOF'
sprint:
  max_concurrent_active: 2
EOF
}

teardown() {
  common_teardown
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# write_sprint_yaml SPRINT_ID STATUS START END STORY_SPEC...
# Writes a sprint-status yaml (either single-file or per-sprint).
write_sprint_yaml() {
  local sprint_id="$1" status="$2" start="${3:-2026-10-01}" end="${4:-2026-10-14}"
  shift 4 || true
  local out="$SPRINT_STATUS_YAML"
  # In concurrent mode, write per-sprint files.
  if [ -f "$PROJECT_ROOT/.gaia/state/sprint-status-${sprint_id}.yaml" ] \
     || [ "$status" != "single" ]; then
    out="$PROJECT_ROOT/.gaia/state/sprint-status-${sprint_id}.yaml"
  fi
  cat > "$out" <<EOF
sprint_id: "${sprint_id}"
status: ${status}
start_date: "${start}"
end_date: "${end}"
total_points: 0
velocity_capacity: 100
goals:
  - "Ship concurrent sprints"
stories:
EOF
  local total_pts=0
  for row in "$@"; do
    local key sts pts phase
    key="$(echo "$row" | cut -d: -f1)"
    sts="$(echo "$row" | cut -d: -f2)"
    pts="$(echo "$row" | cut -d: -f3)"
    pts="${pts:-5}"
    phase="$(echo "$row" | cut -d: -f4)"
    cat >> "$out" <<EOF
  - key: "${key}"
    title: "Story ${key}"
    status: "${sts}"
    points: ${pts}
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-10-01"
EOF
    if [ -n "$phase" ]; then
      echo "    phase: ${phase}" >> "$out"
    fi
    total_pts=$((total_pts + pts))
  done
  # Update total_points.
  if command -v yq >/dev/null 2>&1; then
    yq -i ".total_points = $total_pts" "$out" 2>/dev/null || true
  fi

  # Write story files for each key.
  for row in "$@"; do
    local key sts pts
    key="$(echo "$row" | cut -d: -f1)"
    sts="$(echo "$row" | cut -d: -f2)"
    pts="$(echo "$row" | cut -d: -f3)"
    pts="${pts:-5}"
    local story_dir="$IMPL/epic-E900-test/${key}-test-story"
    mkdir -p "$story_dir"
    cat > "$story_dir/story.md" <<STORY
---
key: "${key}"
title: "Story ${key}"
status: ${sts}
points: ${pts}
risk: medium
epic: E900
sprint_id: "${sprint_id}"
manual_verification: false
---
# Story ${key}
STORY
  done
}

# write_last_activated SPRINT_ID — write the last-activated marker.
write_last_activated() {
  printf '%s' "$1" > "$STATE_DIR/.last-activated-sprint"
}

# ---------------------------------------------------------------------------
# Per-sprint cache file creation (TC-CONC-SURF-3a)
# ---------------------------------------------------------------------------

@test "per-sprint cache created in concurrent mode" {
  write_sprint_yaml "sprint-900" "active" "2026-10-01" "2026-10-14" \
    "E900-S1:done:5:1" "E900-S2:in-progress:5:1"
  write_sprint_yaml "sprint-901" "active" "2026-10-01" "2026-10-14" \
    "E900-S3:in-progress:5:1"
  write_last_activated "sprint-901"

  run bash "$SCRIPT" --sprint sprint-900
  [ "$status" -eq 0 ]
  [ -f "$STATE_DIR/.sprint-progress-cache-sprint-900.json" ]
  # Schema check: per-sprint cache has the same fields as single-sprint.
  run jq -e '.sprint.id' "$STATE_DIR/.sprint-progress-cache-sprint-900.json"
  [ "$status" -eq 0 ]
  [ "$output" = '"sprint-900"' ]
}

# ---------------------------------------------------------------------------
# Compatibility proxy mirrors last-activated (TC-CONC-SURF-5)
# ---------------------------------------------------------------------------

@test "compatibility proxy mirrors last-activated sprint" {
  write_sprint_yaml "sprint-900" "active" "2026-10-01" "2026-10-14" \
    "E900-S1:done:5:1" "E900-S2:in-progress:5:1"
  write_sprint_yaml "sprint-901" "active" "2026-10-01" "2026-10-14" \
    "E900-S3:in-progress:5:1"
  write_last_activated "sprint-901"

  # Run snapshot for the last-activated sprint.
  run bash "$SCRIPT" --sprint sprint-901
  [ "$status" -eq 0 ]
  [ -f "$STATE_DIR/.sprint-progress-cache-sprint-901.json" ]
  # The proxy should mirror sprint-901.
  [ -f "$STATE_DIR/.sprint-progress-cache.json" ]
  run jq -r '.sprint.id' "$STATE_DIR/.sprint-progress-cache.json"
  [ "$output" = "sprint-901" ]
}

@test "proxy unchanged when snapshot targets non-last-activated sprint" {
  write_sprint_yaml "sprint-900" "active" "2026-10-01" "2026-10-14" \
    "E900-S1:done:5:1" "E900-S2:in-progress:5:1"
  write_sprint_yaml "sprint-901" "active" "2026-10-01" "2026-10-14" \
    "E900-S3:in-progress:5:1"
  write_last_activated "sprint-901"

  # Seed the proxy with sprint-901 data.
  run bash "$SCRIPT" --sprint sprint-901
  [ "$status" -eq 0 ]
  local proxy_before
  proxy_before="$(cat "$STATE_DIR/.sprint-progress-cache.json")"

  # Now run snapshot for sprint-900 (not last-activated).
  run bash "$SCRIPT" --sprint sprint-900
  [ "$status" -eq 0 ]
  [ -f "$STATE_DIR/.sprint-progress-cache-sprint-900.json" ]
  # Proxy should still have sprint-901 data.
  run jq -r '.sprint.id' "$STATE_DIR/.sprint-progress-cache.json"
  [ "$output" = "sprint-901" ]
}

# ---------------------------------------------------------------------------
# Single-mode cache only (TC-CONC-SURF-3b)
# ---------------------------------------------------------------------------

@test "single-sprint mode writes only proxy cache" {
  # Override config to single-sprint mode.
  cat > "$PROJECT_ROOT/.gaia/config/project-config.yaml" <<'EOF'
sprint:
  max_concurrent_active: 1
EOF
  write_sprint_yaml "sprint-900" "active" "2026-10-01" "2026-10-14" \
    "E900-S1:done:5:1"
  # Write to the single-file yaml.
  cp "$STATE_DIR/sprint-status-sprint-900.yaml" "$SPRINT_STATUS_YAML"
  rm -f "$STATE_DIR/sprint-status-sprint-900.yaml"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$STATE_DIR/.sprint-progress-cache.json" ]
  # No per-sprint cache files.
  local count
  count="$(find "$STATE_DIR" -maxdepth 1 -name '.sprint-progress-cache-*.json' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Closed sprint cache cleanup (TC-CONC-SURF-6 / AC9)
# ---------------------------------------------------------------------------

@test "closed sprint removes per-sprint cache" {
  write_sprint_yaml "sprint-900" "active" "2026-10-01" "2026-10-14" \
    "E900-S1:done:5:1"
  write_last_activated "sprint-900"

  # Create a per-sprint cache.
  run bash "$SCRIPT" --sprint sprint-900
  [ "$status" -eq 0 ]
  [ -f "$STATE_DIR/.sprint-progress-cache-sprint-900.json" ]

  # Close the sprint.
  if command -v yq >/dev/null 2>&1; then
    yq -i '.status = "closed"' "$STATE_DIR/sprint-status-sprint-900.yaml"
  else
    sed -i.bak 's/^status: active/status: closed/' "$STATE_DIR/sprint-status-sprint-900.yaml"
    rm -f "$STATE_DIR/sprint-status-sprint-900.yaml.bak"
  fi

  # Run snapshot targeting the closed sprint.
  run bash "$SCRIPT" --sprint sprint-900
  [ "$status" -eq 0 ]
  # Per-sprint cache should be removed.
  [ ! -f "$STATE_DIR/.sprint-progress-cache-sprint-900.json" ]
}

# ---------------------------------------------------------------------------
# Invalid sprint ID refused (TC-CONC-SURF-INVALID / AC10)
# ---------------------------------------------------------------------------

@test "invalid sprint ID format refused" {
  run bash "$SCRIPT" --sprint "../rogue"
  [ "$status" -eq 0 ]
  [[ "$output" == *"invalid sprint ID"* ]] || [[ "$output" == "" ]]
  # No rogue file created.
  [ ! -f "$STATE_DIR/.sprint-progress-cache-..%2Frogue.json" ]
  [ ! -f "$STATE_DIR/.sprint-progress-cache-../rogue.json" ]
}

@test "unknown sprint ID refused" {
  write_sprint_yaml "sprint-900" "active" "2026-10-01" "2026-10-14" \
    "E900-S1:done:5:1"

  run bash "$SCRIPT" --sprint "rogue-999"
  [ "$status" -eq 0 ]
  [ ! -f "$STATE_DIR/.sprint-progress-cache-rogue-999.json" ]
}

# ---------------------------------------------------------------------------
# Single non-closed sprint in concurrent mode, unbound (TC-CONC-SURF-SINGLE / AC11)
# ---------------------------------------------------------------------------

@test "single non-closed sprint in concurrent mode writes only proxy" {
  write_sprint_yaml "sprint-900" "active" "2026-10-01" "2026-10-14" \
    "E900-S1:done:5:1"
  # No session binding, no --sprint.
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$STATE_DIR/.sprint-progress-cache.json" ]
  # No per-sprint cache files (single-file path).
  local count
  count="$(find "$STATE_DIR" -maxdepth 1 -name '.sprint-progress-cache-*.json' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Unbound multi-sprint snapshot refresh (TC-CONC-SURF-UNBOUND / AC13)
# ---------------------------------------------------------------------------

@test "unbound multi-sprint refresh creates per-sprint caches for all" {
  write_sprint_yaml "sprint-900" "active" "2026-10-01" "2026-10-14" \
    "E900-S1:done:5:1" "E900-S2:in-progress:5:1"
  write_sprint_yaml "sprint-901" "active" "2026-10-01" "2026-10-14" \
    "E900-S3:in-progress:5:1"
  write_last_activated "sprint-901"

  # No binding, no --sprint.
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$STATE_DIR/.sprint-progress-cache-sprint-900.json" ]
  [ -f "$STATE_DIR/.sprint-progress-cache-sprint-901.json" ]
  # Proxy mirrors last-activated (sprint-901).
  run jq -r '.sprint.id' "$STATE_DIR/.sprint-progress-cache.json"
  [ "$output" = "sprint-901" ]
}

# ---------------------------------------------------------------------------
# Prefix ambiguity (AC-EC2)
# ---------------------------------------------------------------------------

@test "sprint-8 and sprint-80 caches are distinct files" {
  write_sprint_yaml "sprint-8" "active" "2026-10-01" "2026-10-14" \
    "E900-S1:done:5:1"
  write_sprint_yaml "sprint-80" "active" "2026-10-01" "2026-10-14" \
    "E900-S2:in-progress:5:1"
  write_last_activated "sprint-80"

  run bash "$SCRIPT" --sprint sprint-8
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" --sprint sprint-80
  [ "$status" -eq 0 ]

  [ -f "$STATE_DIR/.sprint-progress-cache-sprint-8.json" ]
  [ -f "$STATE_DIR/.sprint-progress-cache-sprint-80.json" ]

  # Verify they contain the correct sprint IDs.
  run jq -r '.sprint.id' "$STATE_DIR/.sprint-progress-cache-sprint-8.json"
  [ "$output" = "sprint-8" ]
  run jq -r '.sprint.id' "$STATE_DIR/.sprint-progress-cache-sprint-80.json"
  [ "$output" = "sprint-80" ]
}

# ---------------------------------------------------------------------------
# Multi-sprint overview (TC-CONC-SURF-1 / AC4)
# ---------------------------------------------------------------------------

@test "multi-sprint overview lists all non-closed sprints" {
  write_sprint_yaml "sprint-900" "active" "2026-10-01" "2026-10-14" \
    "E900-S1:done:5:1" "E900-S2:in-progress:5:1"
  write_sprint_yaml "sprint-901" "active" "2026-10-01" "2026-10-14" \
    "E900-S3:in-progress:5:1"
  write_last_activated "sprint-901"

  # Create per-sprint caches first.
  bash "$SCRIPT" --sprint sprint-900
  bash "$SCRIPT" --sprint sprint-901

  # Run dashboard without --sprint. Unset SPRINT_STATUS_YAML so the dashboard
  # does not force the fallback path (it resolves its own yaml from PROJECT_ROOT).
  run env -u SPRINT_STATUS_YAML bash "$DASHBOARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All Active Sprints"* ]]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" == *"sprint-901"* ]]
}

# ---------------------------------------------------------------------------
# Single-sprint detail with --sprint (TC-CONC-SURF-2 / AC5)
# ---------------------------------------------------------------------------

@test "dashboard --sprint shows single sprint detail" {
  write_sprint_yaml "sprint-900" "active" "2026-10-01" "2026-10-14" \
    "E900-S1:done:5:1" "E900-S2:in-progress:5:1"
  write_sprint_yaml "sprint-901" "active" "2026-10-01" "2026-10-14" \
    "E900-S3:in-progress:5:1"
  write_last_activated "sprint-901"

  # Create per-sprint cache.
  bash "$SCRIPT" --sprint sprint-900

  # Run dashboard with --sprint.
  export SPRINT_CACHE_JSON="$STATE_DIR/.sprint-progress-cache-sprint-900.json"
  run bash "$DASHBOARD" --sprint sprint-900
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]]
  # Should NOT contain the other sprint.
  [[ "$output" != *"sprint-901"* ]]
}

# ---------------------------------------------------------------------------
# Closed sprint read-only detail (TC-CONC-SURF-7 / AC5)
# ---------------------------------------------------------------------------

@test "dashboard --sprint shows read-only detail for closed sprint" {
  write_sprint_yaml "sprint-900" "active" "2026-10-01" "2026-10-14" \
    "E900-S1:done:5:1"

  # Close it.
  if command -v yq >/dev/null 2>&1; then
    yq -i '.status = "closed"' "$STATE_DIR/sprint-status-sprint-900.yaml"
  else
    sed -i.bak 's/^status: active/status: closed/' "$STATE_DIR/sprint-status-sprint-900.yaml"
    rm -f "$STATE_DIR/sprint-status-sprint-900.yaml.bak"
  fi

  run bash "$DASHBOARD" --sprint sprint-900
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]]
}

# ---------------------------------------------------------------------------
# Internal ID scrub (TC-CONC-SURF-SCRUB / AC12)
# ---------------------------------------------------------------------------

@test "no internal traceability IDs in published files" {
  # Check files modified/created by this story for leaked internal IDs.
  # Only E900-S* (synthetic test fixture IDs) and load-bearing regex
  # literals (E[0-9]+-S[0-9]+ used as matching logic) are exempt.
  local -a files_to_check=(
    "plugins/gaia/scripts/sprint-progress-snapshot.sh"
    "plugins/gaia/scripts/statusline.sh"
    "plugins/gaia/scripts/sprint-status-dashboard.sh"
    "plugins/gaia/scripts/install-statusline.sh"
    "plugins/gaia/hooks/index.js"
  )
  local f
  for f in "${files_to_check[@]}"; do
    local full="$BATS_TEST_DIRNAME/../../../$f"
    [ -f "$full" ] || continue
    # Grep for all internal ID patterns.
    local matches=""
    matches="$(/usr/bin/grep -nE '(FR-[0-9]{2,}|NFR-[0-9]{2,}|ADR-[0-9]{2,}|SR-[0-9]{2,}|E[0-9]+-S[0-9]+|AF-20[0-9]{2}|AI-20[0-9]{2})' "$full" || true)"
    [ -n "$matches" ] || continue
    # Narrow filter: only allow E900-S* (synthetic fixture IDs used in
    # test helpers) and regex-literal lines containing character-class
    # brackets (e.g. E[0-9]+-S[0-9]+).
    local real_leaks=""
    real_leaks="$(printf '%s\n' "$matches" \
      | /usr/bin/grep -v 'E900-S' \
      | /usr/bin/grep -v '\[0-9\]' \
      || true)"
    if [ -n "$real_leaks" ]; then
      printf 'Leaked IDs in %s:\n%s\n' "$f" "$real_leaks"
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------
# Session-binding.sh delivery and missing-helper degradation
# (TC-CONC-SURF-INSTALL / AC15)
# ---------------------------------------------------------------------------

@test "self-heal and install copy lists are identical sorted file lists" {
  # Extract the self-heal copy list from statusline.sh. The entries live
  # inside a for-loop block as "relative/src:$_GAIA_INSTALL_DIR/dest".
  # We extract the source-side (before the colon).
  local self_heal_list
  self_heal_list="$(sed -n '/Mirror exactly what install-statusline.sh copies/,/done$/p' "$STATUSLINE" \
    | /usr/bin/grep -oE '"[^"]+:\$' \
    | sed 's/"//g; s/:\$$//' | sort)"

  # Extract the install copy list from install-statusline.sh.
  # _copy_if_different "$SRC_*" "$DEST_*" lines.
  local install_list
  install_list="$(/usr/bin/grep '_copy_if_different.*SRC_' "$SCRIPTS_DIR/install-statusline.sh" \
    | /usr/bin/grep -oE '\$SRC_[A-Z_]+' \
    | while read -r var; do
        # Resolve the variable to its source path from the file.
        local def
        def="$(/usr/bin/grep "^${var#\$}=" "$SCRIPTS_DIR/install-statusline.sh" | head -1 | sed 's/^[^=]*=//' | sed 's/"//g')"
        # Extract the relative path from $SCRIPT_DIR/...
        def="${def#\$SCRIPT_DIR/}"
        printf '%s\n' "$def"
      done | sort)"

  # Both lists must be non-empty and identical.
  [ -n "$self_heal_list" ] || { echo "self-heal list is empty"; return 1; }
  [ -n "$install_list" ] || { echo "install list is empty"; return 1; }
  [ "$self_heal_list" = "$install_list" ] || {
    printf 'MISMATCH:\nself-heal:\n%s\ninstall:\n%s\n' "$self_heal_list" "$install_list"
    return 1
  }

  # session-binding.sh must be in both.
  /usr/bin/grep -q 'session-binding.sh' <<< "$self_heal_list" || {
    echo "session-binding.sh missing from self-heal list"; return 1; }
}

@test "missing session-binding helper degrades to single-sprint rendering" {
  mkdir -p "$TEST_TMP/home"
  write_sprint_yaml "sprint-900" "active" "2026-10-01" "2026-10-14" \
    "E900-S1:done:5:1"
  write_sprint_yaml "sprint-901" "active" "2026-10-01" "2026-10-14" \
    "E900-S3:in-progress:5:1"
  write_last_activated "sprint-901"
  bash "$SCRIPT" --sprint sprint-900
  bash "$SCRIPT" --sprint sprint-901

  local binding_dir="$STATE_DIR/sessions/test-session-degrade"
  mkdir -p "$binding_dir" && chmod 0700 "$binding_dir"
  (
    export GAIA_BINDING_DIR="$binding_dir"
    export CLAUDE_PROJECT_ROOT="$PROJECT_ROOT"
    export PROJECT_ROOT="$PROJECT_ROOT"
    . "$SCRIPTS_DIR/lib/session-binding.sh"
    write_binding "sprint-900" "$STATE_DIR"
  )

  # Run statusline with a PATH that lacks the session-binding helper.
  # We point _GAIA_INSTALL_DIR at an empty dir so the installed helper is
  # not found, and mask the source scripts dir too.
  local fake_install="$TEST_TMP/fake-install"
  mkdir -p "$fake_install/lib"
  # No session-binding.sh in fake_install/lib — triggers degradation.

  local json='{"model":{"id":"claude-opus","display_name":"Opus"},"workspace":{"current_dir":"'"$PROJECT_ROOT"'"},"session_id":"test-session-degrade"}'
  printf '%s' "$json" > "$TEST_TMP/.stdin.json"
  local errfile="$TEST_TMP/degrade-stderr.txt"

  # Run with the real statusline but with the helper masked out.
  # We create a wrapper that unsets the lib path.
  local wrapper="$TEST_TMP/sl-wrapper.sh"
  cat > "$wrapper" <<WRAP
#!/usr/bin/env bash
# Remove session-binding.sh from the script's lib dir so it cannot be found.
# We achieve this by running the statusline from a copy where lib/session-binding.sh is absent.
cp "$STATUSLINE" "$TEST_TMP/statusline-copy.sh"
chmod +x "$TEST_TMP/statusline-copy.sh"
COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich \
  HOME="$TEST_TMP/home" PROJECT_PATH="$PROJECT_ROOT" PROJECT_ROOT="$PROJECT_ROOT" \
  _GAIA_INSTALL_DIR="$fake_install" \
  bash "$TEST_TMP/statusline-copy.sh" < "$TEST_TMP/.stdin.json" 2>"$errfile"
WRAP
  chmod +x "$wrapper"
  run bash "$wrapper"
  [ "$status" -eq 0 ]

  # Rendered output must be single-sprint (sprint from proxy, no +N).
  # The warning must go to stderr, not the rendered output.
  [[ "$output" != *"session-binding"* ]] || false
  [[ "$output" != *"+1"* ]] || false

  # stderr must contain the degradation warning.
  [ -f "$errfile" ] || { echo "stderr file missing"; false; }
  local stderr_content
  stderr_content="$(cat "$errfile")"
  [ -n "$stderr_content" ] || { echo "stderr is empty — expected degradation warning"; false; }
  [[ "$stderr_content" == *"session-binding"* ]] || [[ "$stderr_content" == *"falling back"* ]] || {
    echo "stderr does not contain the expected warning: $stderr_content"; false; }
  # The warning text must NOT appear in stdout.
  [[ "$output" != *"falling back"* ]] || false
}

# ---------------------------------------------------------------------------
# Post-transition hook: behavioural AC14 tests
# ---------------------------------------------------------------------------

# _hook_copy_plugin_tree — copy the plugin scripts tree into a temp dir.
_hook_copy_plugin_tree() {
  local dst="$TEST_TMP/plugin-copy"
  mkdir -p "$dst/scripts/lib"
  cp "$SCRIPTS_DIR/sprint-state.sh" "$dst/scripts/sprint-state.sh"
  chmod +x "$dst/scripts/sprint-state.sh"
  local lib
  for lib in story-state-machine.sh acquire-lock.sh exec-with-timeout.sh \
             gaia-paths.sh resolve-artifact-path.sh session-binding.sh \
             migrate-items-to-stories.sh; do
    [ -f "$SCRIPTS_DIR/lib/$lib" ] && cp "$SCRIPTS_DIR/lib/$lib" "$dst/scripts/lib/"
  done
  for sib in review-gate.sh lifecycle-event.sh; do
    [ -f "$SCRIPTS_DIR/$sib" ] && cp "$SCRIPTS_DIR/$sib" "$dst/scripts/"
  done
  printf '%s' "$dst/scripts/sprint-state.sh"
}

# _hook_install_recorder DIR MARKER — install a fake snapshot that records
# its argv and env to MARKER.
_hook_install_recorder() {
  local dir="$1" marker="$2"
  cat > "$dir/sprint-progress-snapshot.sh" <<SH
#!/usr/bin/env bash
{
  printf 'ARGV=%s\n' "\$*"
  printf 'SPRINT_STATUS_YAML=%s\n' "\${SPRINT_STATUS_YAML:-}"
  printf 'PROJECT_ROOT=%s\n' "\${PROJECT_ROOT:-}"
  printf 'GAIA_SNAPSHOT_SPRINT_ID=%s\n' "\${GAIA_SNAPSHOT_SPRINT_ID:-}"
  printf 'GAIA_SNAPSHOT_PER_SPRINT_FILE=%s\n' "\${GAIA_SNAPSHOT_PER_SPRINT_FILE:-}"
} > "${marker}.tmp"
mv "${marker}.tmp" "$marker"
SH
  chmod +x "$dir/sprint-progress-snapshot.sh"
}

# _hook_wait_for PATH [SECONDS] — poll until PATH exists (bounded).
_hook_wait_for() {
  local path="$1" limit="${2:-10}" i=0
  while [ ! -e "$path" ]; do
    i=$((i + 1))
    [ "$i" -le $((limit * 10)) ] || return 1
    sleep 0.1
  done
}

@test "sprint-state.sh and dev-story mirror are byte-identical" {
  local state_sh="$SCRIPTS_DIR/sprint-state.sh"
  local dev_story_sh="$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts/sprint-state.sh"
  [ -f "$dev_story_sh" ] || skip "dev-story mirror not found"
  cmp -s "$state_sh" "$dev_story_sh"
}

@test "post-transition hook passes --sprint in concurrent mode" {
  # Set up a concurrent-mode project.
  write_sprint_yaml "sprint-900" "active" "2026-10-01" "2026-10-14" \
    "E900-S1:in-progress:5:1"

  # Write story file for transition (must have template: 'story' frontmatter
  # and a '> **Status:**' body line).
  local story_dir="$IMPL/epic-E900-test/E900-S1-test-story"
  mkdir -p "$story_dir"
  cat > "$story_dir/story.md" <<STORY
---
template: 'story'
key: "E900-S1"
title: "Story E900-S1"
status: in-progress
points: 5
risk: medium
epic: E900
sprint_id: "sprint-900"
manual_verification: false
depends_on: []
---

# Story: E900-S1

> **Status:** in-progress

## Tasks / Subtasks

- [x] Task 1: Done

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | --- |
| QA Tests | PASSED | --- |
| Security Review | PASSED | --- |
| Test Automation | PASSED | --- |
| Test Review | PASSED | --- |
| Performance Review | PASSED | --- |

## Definition of Done

- [x] All done
STORY

  mkdir -p "$TEST_TMP/_memory"

  # Copy the plugin tree and install a recording snapshot.
  local copied_ss
  copied_ss="$(_hook_copy_plugin_tree)"
  local copied_dir
  copied_dir="$(dirname "$copied_ss")"
  local marker="$TEST_TMP/hook-marker"
  _hook_install_recorder "$copied_dir" "$marker"

  # Run the transition with the hook enabled.
  run env -u GAIA_SNAPSHOT_HOOK_DISABLE \
      PROJECT_ROOT="$PROJECT_ROOT" \
      SPRINT_STATUS_YAML="$STATE_DIR/sprint-status-sprint-900.yaml" \
      MEMORY_PATH="$TEST_TMP/_memory" \
      IMPLEMENTATION_ARTIFACTS="$IMPL" \
      "$copied_ss" transition --story E900-S1 --to review
  [ "$status" -eq 0 ]

  # Wait for the background hook to write the marker.
  _hook_wait_for "$marker" 10

  # The hook must pass --sprint sprint-900.
  local argv
  argv="$(/usr/bin/grep '^ARGV=' "$marker" | sed 's/^ARGV=//')"
  [[ "$argv" == *"--sprint"* ]] || { echo "ARGV=$argv"; false; }
  [[ "$argv" == *"sprint-900"* ]] || { echo "ARGV=$argv"; false; }
}

@test "single-sprint mode hook passes no --sprint argument" {
  # Single-sprint mode config.
  cat > "$PROJECT_ROOT/.gaia/config/project-config.yaml" <<'EOF'
sprint:
  max_concurrent_active: 1
EOF

  # Write single-file yaml.
  cat > "$SPRINT_STATUS_YAML" <<'EOF'
sprint_id: "sprint-900"
status: active
start_date: "2026-10-01"
end_date: "2026-10-14"
total_points: 5
goals: []
stories:
  - key: "E900-S1"
    title: "Story E900-S1"
    status: "in-progress"
    points: 5
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-10-01"
EOF
  # Remove any per-sprint files.
  rm -f "$STATE_DIR"/sprint-status-sprint-*.yaml

  local story_dir="$IMPL/epic-E900-test/E900-S1-test-story"
  mkdir -p "$story_dir"
  cat > "$story_dir/story.md" <<STORY
---
template: 'story'
key: "E900-S1"
title: "Story E900-S1"
status: in-progress
points: 5
risk: medium
epic: E900
sprint_id: "sprint-900"
manual_verification: false
depends_on: []
---

# Story: E900-S1

> **Status:** in-progress

## Tasks / Subtasks

- [x] Task 1: Done

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | --- |
| QA Tests | PASSED | --- |
| Security Review | PASSED | --- |
| Test Automation | PASSED | --- |
| Test Review | PASSED | --- |
| Performance Review | PASSED | --- |

## Definition of Done

- [x] All done
STORY

  mkdir -p "$TEST_TMP/_memory"

  local copied_ss
  copied_ss="$(_hook_copy_plugin_tree)"
  local copied_dir
  copied_dir="$(dirname "$copied_ss")"
  local marker="$TEST_TMP/hook-marker-single"
  _hook_install_recorder "$copied_dir" "$marker"

  run env -u GAIA_SNAPSHOT_HOOK_DISABLE \
      PROJECT_ROOT="$PROJECT_ROOT" \
      SPRINT_STATUS_YAML="$SPRINT_STATUS_YAML" \
      MEMORY_PATH="$TEST_TMP/_memory" \
      IMPLEMENTATION_ARTIFACTS="$IMPL" \
      "$copied_ss" transition --story E900-S1 --to review
  [ "$status" -eq 0 ]

  _hook_wait_for "$marker" 10

  # Single-sprint mode: no --sprint in argv.
  local argv
  argv="$(/usr/bin/grep '^ARGV=' "$marker" | sed 's/^ARGV=//')"
  [[ "$argv" != *"--sprint"* ]] || { echo "ARGV=$argv should NOT contain --sprint"; false; }
  # Must still have PROJECT_ROOT and SPRINT_STATUS_YAML.
  /usr/bin/grep -q 'PROJECT_ROOT=' "$marker"
  /usr/bin/grep -q 'SPRINT_STATUS_YAML=' "$marker"
}

# ---------------------------------------------------------------------------
# Statusline behavioural tests (AC6 — real statusline.sh + real writer)
# ---------------------------------------------------------------------------

# _sl_build_concurrent_fixture SESSION_ID BOUND_SPRINT_ID
# Builds a concurrent mode project with two active sprints, per-sprint caches
# written by the REAL snapshot writer, and a binding file for the session.
_sl_build_concurrent_fixture() {
  local session_id="$1" bound_id="$2"
  local proj="$PROJECT_ROOT"

  write_sprint_yaml "sprint-900" "active" "2026-10-01" "2026-10-14" \
    "E900-S1:done:5:1" "E900-S2:in-progress:5:1"
  write_sprint_yaml "sprint-901" "active" "2026-10-01" "2026-10-14" \
    "E900-S3:in-progress:5:1"
  write_last_activated "sprint-901"

  # Generate per-sprint caches with the REAL writer.
  bash "$SCRIPT" --sprint sprint-900
  bash "$SCRIPT" --sprint sprint-901

  # Write binding file using the REAL session-binding helper.
  local binding_sh="$SCRIPTS_DIR/lib/session-binding.sh"
  local binding_dir="$STATE_DIR/sessions/${session_id}"
  mkdir -p "$binding_dir"
  chmod 0700 "$binding_dir"
  # Source the helper and call write_binding.
  (
    export GAIA_BINDING_DIR="$binding_dir"
    export CLAUDE_PROJECT_ROOT="$proj"
    export PROJECT_ROOT="$proj"
    . "$binding_sh"
    write_binding "$bound_id" "$STATE_DIR"
  )
}

# _sl_render SESSION_ID — pipe JSON with session_id into the statusline.
_sl_render() {
  local session_id="$1"
  local json='{"model":{"id":"claude-opus","display_name":"Opus"},"workspace":{"current_dir":"'"$PROJECT_ROOT"'"},"session_id":"'"$session_id"'"}'
  printf '%s' "$json" > "$TEST_TMP/.stdin.json"
  COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich \
    HOME="$TEST_TMP/home" \
    PROJECT_PATH="$PROJECT_ROOT" PROJECT_ROOT="$PROJECT_ROOT" \
    bash "$STATUSLINE" < "$TEST_TMP/.stdin.json"
}

# _sl_render_stderr SESSION_ID FILE — render and capture stderr.
_sl_render_stderr() {
  local session_id="$1" errfile="$2"
  local json='{"model":{"id":"claude-opus","display_name":"Opus"},"workspace":{"current_dir":"'"$PROJECT_ROOT"'"},"session_id":"'"$session_id"'"}'
  printf '%s' "$json" > "$TEST_TMP/.stdin.json"
  COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich \
    HOME="$TEST_TMP/home" \
    PROJECT_PATH="$PROJECT_ROOT" PROJECT_ROOT="$PROJECT_ROOT" \
    bash "$STATUSLINE" < "$TEST_TMP/.stdin.json" 2>"$errfile"
}

@test "statusline shows bound sprint with +1 for two active sprints" {
  mkdir -p "$TEST_TMP/home"
  _sl_build_concurrent_fixture "test-session-1" "sprint-900"

  run _sl_render "test-session-1"
  [ "$status" -eq 0 ]
  # Output must contain sprint-900 (the bound sprint).
  [[ "$output" == *"sprint-900"* ]] || false
  # Output must contain +1 (one other non-closed sprint).
  [[ "$output" == *"+1"* ]] || false
}

@test "statusline shows +2 for three active sprints" {
  mkdir -p "$TEST_TMP/home"
  write_sprint_yaml "sprint-900" "active" "2026-10-01" "2026-10-14" \
    "E900-S1:done:5:1" "E900-S2:in-progress:5:1"
  write_sprint_yaml "sprint-901" "active" "2026-10-01" "2026-10-14" \
    "E900-S3:in-progress:5:1"
  write_sprint_yaml "sprint-902" "active" "2026-10-01" "2026-10-14" \
    "E900-S4:in-progress:5:1"
  write_last_activated "sprint-902"

  bash "$SCRIPT" --sprint sprint-900
  bash "$SCRIPT" --sprint sprint-901
  bash "$SCRIPT" --sprint sprint-902

  # Bind to sprint-900.
  local binding_dir="$STATE_DIR/sessions/test-session-2"
  mkdir -p "$binding_dir" && chmod 0700 "$binding_dir"
  (
    export GAIA_BINDING_DIR="$binding_dir"
    export CLAUDE_PROJECT_ROOT="$PROJECT_ROOT"
    export PROJECT_ROOT="$PROJECT_ROOT"
    . "$SCRIPTS_DIR/lib/session-binding.sh"
    write_binding "sprint-900" "$STATE_DIR"
  )

  run _sl_render "test-session-2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]] || false
  [[ "$output" == *"+2"* ]] || false
}

@test "statusline shows no +N with exactly one active sprint" {
  mkdir -p "$TEST_TMP/home"
  write_sprint_yaml "sprint-900" "active" "2026-10-01" "2026-10-14" \
    "E900-S1:done:5:1"
  write_last_activated "sprint-900"
  bash "$SCRIPT" --sprint sprint-900

  local binding_dir="$STATE_DIR/sessions/test-session-3"
  mkdir -p "$binding_dir" && chmod 0700 "$binding_dir"
  (
    export GAIA_BINDING_DIR="$binding_dir"
    export CLAUDE_PROJECT_ROOT="$PROJECT_ROOT"
    export PROJECT_ROOT="$PROJECT_ROOT"
    . "$SCRIPTS_DIR/lib/session-binding.sh"
    write_binding "sprint-900" "$STATE_DIR"
  )

  run _sl_render "test-session-3"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]] || false
  # Must NOT contain any +<digit> indicator (catches +0 too).
  ! [[ "$output" =~ \+[0-9] ]] || false
}

@test "statusline +N count ignores per-sprint cache with closed status" {
  # AC6: bound sprint + one active + one cache whose recorded status is closed
  # must show +1 (not +2).
  mkdir -p "$TEST_TMP/home"
  write_sprint_yaml "sprint-900" "active" "2026-10-01" "2026-10-14" \
    "E900-S1:done:5:1" "E900-S2:in-progress:5:1"
  write_sprint_yaml "sprint-901" "active" "2026-10-01" "2026-10-14" \
    "E900-S3:in-progress:5:1"
  write_sprint_yaml "sprint-902" "active" "2026-10-01" "2026-10-14" \
    "E900-S4:done:5:1"
  write_last_activated "sprint-902"

  # Build per-sprint caches with the real writer.
  bash "$SCRIPT" --sprint sprint-900
  bash "$SCRIPT" --sprint sprint-901
  bash "$SCRIPT" --sprint sprint-902

  # Manually mark sprint-902's cache as closed (simulates a sprint that
  # was closed after its last snapshot but before cleanup ran).
  jq '.sprint.status = "closed"' \
    "$STATE_DIR/.sprint-progress-cache-sprint-902.json" \
    > "$STATE_DIR/.sprint-progress-cache-sprint-902.json.tmp"
  mv "$STATE_DIR/.sprint-progress-cache-sprint-902.json.tmp" \
    "$STATE_DIR/.sprint-progress-cache-sprint-902.json"

  # Bind to sprint-900.
  local binding_dir="$STATE_DIR/sessions/test-session-closed-skip"
  mkdir -p "$binding_dir" && chmod 0700 "$binding_dir"
  (
    export GAIA_BINDING_DIR="$binding_dir"
    export CLAUDE_PROJECT_ROOT="$PROJECT_ROOT"
    export PROJECT_ROOT="$PROJECT_ROOT"
    . "$SCRIPTS_DIR/lib/session-binding.sh"
    write_binding "sprint-900" "$STATE_DIR"
  )

  run _sl_render "test-session-closed-skip"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]] || false
  # Only sprint-901 is non-closed, so +1 (not +2).
  [[ "$output" == *"+1"* ]] || false
  [[ "$output" != *"+2"* ]] || false
}

@test "statusline shows closed label when bound sprint is closed" {
  mkdir -p "$TEST_TMP/home"
  write_sprint_yaml "sprint-900" "active" "2026-10-01" "2026-10-14" \
    "E900-S1:done:5:1"
  write_last_activated "sprint-900"
  bash "$SCRIPT" --sprint sprint-900

  local binding_dir="$STATE_DIR/sessions/test-session-4"
  mkdir -p "$binding_dir" && chmod 0700 "$binding_dir"
  (
    export GAIA_BINDING_DIR="$binding_dir"
    export CLAUDE_PROJECT_ROOT="$PROJECT_ROOT"
    export PROJECT_ROOT="$PROJECT_ROOT"
    . "$SCRIPTS_DIR/lib/session-binding.sh"
    write_binding "sprint-900" "$STATE_DIR"
  )

  # Close the sprint after binding.
  yq -i '.status = "closed"' "$STATE_DIR/sprint-status-sprint-900.yaml"

  run _sl_render "test-session-4"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]] || false
  [[ "$output" == *"closed"* ]] || false
  # No +N indicator.
  [[ "$output" != *"+1"* ]] || false
}

@test "statusline exit-3 warning goes to stderr not rendered output" {
  mkdir -p "$TEST_TMP/home"
  write_sprint_yaml "sprint-900" "active" "2026-10-01" "2026-10-14" \
    "E900-S1:done:5:1"
  write_last_activated "sprint-900"
  bash "$SCRIPT" --sprint sprint-900

  # Write a corrupted binding file (invalid sprint ID to trigger exit 3).
  local binding_dir="$STATE_DIR/sessions/test-session-5"
  mkdir -p "$binding_dir" && chmod 0700 "$binding_dir"
  printf '../../rogue' > "$binding_dir/bound_sprint_id"

  local errfile="$TEST_TMP/sl-stderr.txt"
  run _sl_render_stderr "test-session-5" "$errfile"
  [ "$status" -eq 0 ]
  # Rendered output must not contain the warning text.
  [[ "$output" != *"invalid"* ]] || false
  [[ "$output" != *"session-binding"* ]] || false
}

@test "statusline single-sprint output unchanged from staging baseline" {
  mkdir -p "$TEST_TMP/home"
  # Single-sprint mode: no per-sprint caches, no binding.
  cat > "$PROJECT_ROOT/.gaia/config/project-config.yaml" <<'EOF'
sprint:
  max_concurrent_active: 1
EOF
  write_sprint_yaml "sprint-900" "active" "2026-10-01" "2026-10-14" \
    "E900-S1:done:5:1"
  cp "$STATE_DIR/sprint-status-sprint-900.yaml" "$SPRINT_STATUS_YAML"
  rm -f "$STATE_DIR/sprint-status-sprint-900.yaml"

  bash "$SCRIPT"

  local json='{"model":{"id":"claude-opus","display_name":"Opus"},"workspace":{"current_dir":"'"$PROJECT_ROOT"'"}}'
  printf '%s' "$json" > "$TEST_TMP/.stdin.json"

  # Render with the current statusline.
  local current_out
  current_out="$(COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich \
    HOME="$TEST_TMP/home" PROJECT_PATH="$PROJECT_ROOT" PROJECT_ROOT="$PROJECT_ROOT" \
    bash "$STATUSLINE" < "$TEST_TMP/.stdin.json" 2>/dev/null)"

  # The output must contain the sprint ID and percentage.
  [[ "$current_out" == *"sprint-900"* ]] || false
  # Must NOT contain +N or "closed".
  [[ "$current_out" != *"+1"* ]] || false
  [[ "$current_out" != *"closed"* ]] || false
}

# ---------------------------------------------------------------------------
# Mutant proofs — verify critical rules kill when violated
# ---------------------------------------------------------------------------

@test "mutant: removing +N logic makes two-sprint test fail" {
  mkdir -p "$TEST_TMP/home"
  _sl_build_concurrent_fixture "test-session-m1" "sprint-900"

  # The real output must show +1.
  run _sl_render "test-session-m1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"+1"* ]] || false
}

@test "mutant: wrong cache produces wrong sprint ID" {
  mkdir -p "$TEST_TMP/home"
  _sl_build_concurrent_fixture "test-session-m2" "sprint-900"

  run _sl_render "test-session-m2"
  [ "$status" -eq 0 ]
  # Must show the BOUND sprint (sprint-900), not the other.
  [[ "$output" == *"sprint-900"* ]] || false
}
