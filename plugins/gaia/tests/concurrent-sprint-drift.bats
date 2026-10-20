#!/usr/bin/env bats
# concurrent-sprint-drift.bats — runtime touch-set drift detection tests
#
# Tests drift-detect.sh: drift halt, absent/tampered checkpoint, non-git
# workspace, wildcard refuse, path mapping, sanitizer denylist, base
# fallback, and warm-cache performance.

# shellcheck disable=SC2030,SC2031

setup() {
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT PROJECT_PATH

  TEST_DIR="$(mktemp -d)"
  STATE_DIR="$TEST_DIR/.gaia/state"
  IMPL_DIR="$TEST_DIR/.gaia/artifacts/implementation-artifacts"
  CONFIG_DIR="$TEST_DIR/.gaia/config"
  PLANNING_DIR="$TEST_DIR/.gaia/artifacts/planning-artifacts"
  SHARDS_DIR="$PLANNING_DIR/epics"
  mkdir -p "$STATE_DIR" "$IMPL_DIR" "$CONFIG_DIR" "$PLANNING_DIR" "$SHARDS_DIR"

  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: "drift-test"
sprint:
  max_concurrent_active: 2
ci_cd:
  promotion_chain:
    - target: staging
stacks:
  - name: bash
    path: "."
YAML

  cat > "$PLANNING_DIR/epics-and-stories.md" <<'MD'
# Epics and Stories

## E900 — Test Alpha

## E901 — Test Beta
MD

  printf 'sprint-900 %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$STATE_DIR/.sprint-migration-complete"

  # Create a test git repo.
  GIT_DIR="$TEST_DIR/gaia-public"
  mkdir -p "$GIT_DIR/plugins/gaia/scripts/lib"
  (
    cd "$GIT_DIR"
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    git checkout -q -b staging
    echo '# sprint-state' > plugins/gaia/scripts/sprint-state.sh
    echo '# ic' > plugins/gaia/scripts/independence-check.sh
    echo '# resolve' > plugins/gaia/scripts/resolve-config.sh
    echo '# lifecycle' > plugins/gaia/scripts/lifecycle-event.sh
    git add -A
    git commit -q -m "initial"
  )

  export PROJECT_ROOT="$TEST_DIR"
  export PROJECT_PATH="$TEST_DIR"
  export IMPLEMENTATION_ARTIFACTS="$IMPL_DIR"
  export GAIA_SKIP_ORPHAN_SWEEP=1
  export GAIA_SNAPSHOT_HOOK_DISABLE=1

  BATS_TEST_SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  DRIFT_SCRIPT="$BATS_TEST_SCRIPT_DIR/scripts/drift-detect.sh"
  GATE_SCRIPT="$BATS_TEST_SCRIPT_DIR/scripts/independence-gate.sh"
  IC_SCRIPT="$BATS_TEST_SCRIPT_DIR/scripts/independence-check.sh"
}

teardown() {
  rm -rf "$TEST_DIR" 2>/dev/null || true
}

_create_sprint() {
  local sid="$1" status="$2"
  shift 2
  local f="$STATE_DIR/sprint-status-${sid}.yaml"
  {
    printf 'sprint_id: "%s"\nstatus: %s\ntotal_points: 0\ngoals: []\nstories:\n' "$sid" "$status"
  } > "$f"
  local arg
  for arg in "$@"; do
    local key="${arg%%:*}"; local rest="${arg#*:}"; local epic="${rest%%:*}"; local touch="${rest#*:}"
    printf '  - key: "%s"\n    title: "Story %s"\n    status: "in-progress"\n    points: 3\n    risk: "medium"\n' "$key" "$key" >> "$f"
    _mk_drift_story "$key" "$epic" "$touch" "$sid"
  done
}

_mk_drift_story() {
  local key="$1" epic="$2" touch="$3" sprint_id="$4"
  local epic_slug; epic_slug="$(printf '%s' "$epic" | tr '[:upper:]' '[:lower:]')"
  local sd="$IMPL_DIR/epic-${epic_slug}/${key}-test-story"
  mkdir -p "$sd"
  cat > "$sd/story.md" <<STORY
---
template: 'story'
key: "${key}"
epic: "${epic}"
status: in-progress
sprint_id: "${sprint_id}"
priority: "P2"
size: "M"
points: 3
risk: "medium"
predicted_touch_set: ["${touch}"]
depends_on: []
blocks: []
date: "2026-10-19"
author: "Test"
---
# Story: ${key}

## Findings

| # | Type | Severity | Finding | Suggested Action |
|---|------|----------|---------|-----------------|
STORY
}

# ---- AC2: drift halt from git diff ----

@test "drift halt from git diff: file outside touch-set detected" {
  _create_sprint "sprint-900" "active" "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  _create_sprint "sprint-901" "active" "E901-S1:E901:gaia-public/plugins/gaia/scripts/independence-check.sh"
  local sf="$IMPL_DIR/epic-e900/E900-S1-test-story/story.md"
  ( cd "$GIT_DIR" && echo '# modified' >> plugins/gaia/scripts/resolve-config.sh )
  run bash -c "cd '$GIT_DIR' && bash '$DRIFT_SCRIPT' --story '$sf'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"resolve-config"* ]]
}

# ---- AC2: tampered checkpoint does not suppress drift ----

@test "tampered checkpoint does not suppress drift detection" {
  _create_sprint "sprint-900" "active" "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  local sf="$IMPL_DIR/epic-e900/E900-S1-test-story/story.md"
  local ckpt_dir="$TEST_DIR/.gaia/memory/checkpoints"
  mkdir -p "$ckpt_dir"
  cat > "$ckpt_dir/E900-S1.yaml" <<'CKPT'
files_touched:
  - gaia-public/plugins/gaia/scripts/sprint-state.sh
CKPT
  ( cd "$GIT_DIR" && echo '# modified' >> plugins/gaia/scripts/resolve-config.sh )
  run bash -c "cd '$GIT_DIR' && bash '$DRIFT_SCRIPT' --story '$sf'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"resolve-config"* ]]
}

# ---- AC2: absent checkpoint does not suppress drift ----

@test "absent checkpoint does not suppress drift detection" {
  _create_sprint "sprint-900" "active" "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  local sf="$IMPL_DIR/epic-e900/E900-S1-test-story/story.md"
  ( cd "$GIT_DIR" && echo '# untracked' > plugins/gaia/scripts/test-fixture-untracked.txt && git add plugins/gaia/scripts/test-fixture-untracked.txt )
  run bash -c "cd '$GIT_DIR' && bash '$DRIFT_SCRIPT' --story '$sf'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"test-fixture-untracked"* ]]
}

# ---- AC6: non-git workspace drift halt ----

@test "non-git workspace halts drift check fail-closed in concurrent mode" {
  _create_sprint "sprint-900" "active" "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  _create_sprint "sprint-901" "active" "E901-S1:E901:gaia-public/plugins/gaia/scripts/independence-check.sh"
  local sf="$IMPL_DIR/epic-e900/E900-S1-test-story/story.md"
  local non_git; non_git="$(mktemp -d)"
  run bash -c "cd '$non_git' && bash '$DRIFT_SCRIPT' --story '$sf'"
  rm -rf "$non_git"
  [ "$status" -eq 2 ]
  [[ "$output" == *"drift check unavailable (non-git workspace)"* ]]
}

# ---- AC7: single-sprint mode no drift ----

@test "single-sprint mode: drift detection does not run" {
  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: "single-sprint"
stacks:
  - name: bash
    path: "."
YAML
  rm -f "$STATE_DIR"/sprint-status-*.yaml
  _mk_drift_story "E900-S1" "E900" "gaia-public/plugins/gaia/scripts/sprint-state.sh" "sprint-900"
  local sf="$IMPL_DIR/epic-e900/E900-S1-test-story/story.md"
  ( cd "$GIT_DIR" && echo '# outside' >> plugins/gaia/scripts/resolve-config.sh )
  run bash -c "cd '$GIT_DIR' && bash '$DRIFT_SCRIPT' --story '$sf'"
  [ "$status" -eq 0 ]
}

# ---- AC2: drift base fallback to origin/HEAD ----

@test "drift base fallback to origin/HEAD when promotion_chain unset" {
  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: "drift-no-pc"
sprint:
  max_concurrent_active: 2
stacks:
  - name: bash
    path: "."
YAML
  _create_sprint "sprint-900" "active" "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  _create_sprint "sprint-901" "active" "E901-S1:E901:gaia-public/plugins/gaia/scripts/independence-check.sh"
  local sf="$IMPL_DIR/epic-e900/E900-S1-test-story/story.md"
  (
    cd "$GIT_DIR"
    git update-ref refs/remotes/origin/HEAD HEAD
    echo '# outside' >> plugins/gaia/scripts/resolve-config.sh
  )
  run bash -c "cd '$GIT_DIR' && bash '$DRIFT_SCRIPT' --story '$sf' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"resolve-config"* ]]
}

# ---- AC2: drift base fail-closed when neither resolves ----

@test "drift base fail-closed when neither promotion_chain nor origin/HEAD resolve" {
  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: "drift-no-base"
sprint:
  max_concurrent_active: 2
stacks:
  - name: bash
    path: "."
YAML
  _create_sprint "sprint-900" "active" "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  local sf="$IMPL_DIR/epic-e900/E900-S1-test-story/story.md"
  # Remove origin/HEAD if present.
  ( cd "$GIT_DIR" && git update-ref -d refs/remotes/origin/HEAD 2>/dev/null || true )
  run bash -c "cd '$GIT_DIR' && bash '$DRIFT_SCRIPT' --story '$sf'"
  [ "$status" -eq 2 ]
}

# ---- AC2: sanitizer denylist fail-closed ----

@test "drift halt reads through sanitizer; denied character fails closed" {
  _create_sprint "sprint-900" "active" "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  local sf="$IMPL_DIR/epic-e900/E900-S1-test-story/story.md"
  # Inject a backtick into predicted_touch_set (bypassing the writer).
  local tmp_sf="${sf}.tmp"
  sed "s|predicted_touch_set:.*|predicted_touch_set: [\"\`evil\`\"]|" "$sf" > "$tmp_sf"
  mv -f "$tmp_sf" "$sf"
  run bash -c "cd '$GIT_DIR' && bash '$DRIFT_SCRIPT' --story '$sf'"
  [ "$status" -eq 2 ]
}

# ---- AC-EC1: generated file drift ----

@test "tracked generated file drift; no exclusion list" {
  _create_sprint "sprint-900" "active" "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  local sf="$IMPL_DIR/epic-e900/E900-S1-test-story/story.md"
  ( cd "$GIT_DIR" && echo '// generated' > plugins/gaia/scripts/generated-output.js && git add plugins/gaia/scripts/generated-output.js )
  run bash -c "cd '$GIT_DIR' && bash '$DRIFT_SCRIPT' --story '$sf'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"generated-output.js"* ]]
}

# ---- AC-EC6: conflict markers count as modifications ----

@test "conflict markers in git diff treated as modifications for drift" {
  _create_sprint "sprint-900" "active" "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  local sf="$IMPL_DIR/epic-e900/E900-S1-test-story/story.md"
  (
    cd "$GIT_DIR"
    printf '<<<<<<< HEAD\nlocal\n=======\nremote\n>>>>>>> other\n' >> plugins/gaia/scripts/resolve-config.sh
  )
  run bash -c "cd '$GIT_DIR' && bash '$DRIFT_SCRIPT' --story '$sf'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"resolve-config"* ]]
}

# ---- AC-EC8: multiple rapid drifts halt independently ----

@test "each drift halts independently; no batch dismiss" {
  _create_sprint "sprint-900" "active" "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  local sf="$IMPL_DIR/epic-e900/E900-S1-test-story/story.md"
  (
    cd "$GIT_DIR"
    echo '# mod1' >> plugins/gaia/scripts/resolve-config.sh
    echo '# mod2' >> plugins/gaia/scripts/lifecycle-event.sh
    echo '# mod3' > plugins/gaia/scripts/write-checkpoint.sh
    git add plugins/gaia/scripts/write-checkpoint.sh
  )
  run bash -c "cd '$GIT_DIR' && bash '$DRIFT_SCRIPT' --story '$sf'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"resolve-config"* ]]
  [[ "$output" == *"lifecycle-event"* ]]
  [[ "$output" == *"write-checkpoint"* ]]
}

# ---- AC2: wildcard refuse on drift-resolving touch-set update ----

@test "drift-resolving touch-set update with new wildcard covering overlap" {
  # When the wildcard covers another sprint's touch-set, rule (c) blocks.
  _create_sprint "sprint-900" "active" "E900-S1:E900:gaia-public/plugins/gaia/scripts/sprint-state.sh"
  _create_sprint "sprint-901" "active" "E901-S1:E901:gaia-public/plugins/gaia/scripts/independence-check.sh"
  local sf="$IMPL_DIR/epic-e900/E900-S1-test-story/story.md"
  # The wildcard gaia-public/plugins/gaia/scripts/*.sh covers sprint-901's
  # independence-check.sh — the independence re-check catches this.
  run bash "$GATE_SCRIPT" edit --story "$sf" \
    --set "predicted_touch_set=gaia-public/plugins/gaia/scripts/*.sh"
  [ "$status" -ne 0 ]
}

# ---- AC9: warm cache performance (added by user ruling) ----

_perf_now() {
  python3 -c 'import time; print(time.time())' 2>/dev/null || date +%s
}
_perf_check() {
  local elapsed="$1" budget="$2"
  python3 -c "import sys; sys.exit(0 if float('$elapsed') <= float('$budget') else 1)" 2>/dev/null || {
    local e_int="${elapsed%%.*}"
    [ "${e_int:-0}" -le "$budget" ]
  }
}

@test "warm re-check within 2 seconds for 3x15 stories with one change" {
  # Create 3 active sprints with 15 stories each.
  local s snum key sid epic
  for s in 900 901 902; do
    sid="sprint-${s}"; epic="E${s}"
    local epic_slug; epic_slug="$(printf '%s' "$epic" | tr '[:upper:]' '[:lower:]')"
    local f="$STATE_DIR/sprint-status-${sid}.yaml"
    printf 'sprint_id: "%s"\nstatus: active\ntotal_points: 0\ngoals: []\nstories:\n' "$sid" > "$f"
    for snum in $(seq 1 15); do
      key="${epic}-S${snum}"
      printf '  - key: "%s"\n    title: "Story %s"\n    status: "in-progress"\n    points: 3\n    risk: "medium"\n' "$key" "$key" >> "$f"
      local sd="$IMPL_DIR/epic-${epic_slug}/${key}-perf"
      mkdir -p "$sd"
      local dn="dir-${s}-${snum}"
      mkdir -p "$TEST_DIR/gaia-public/plugins/gaia/perf/${dn}"
      touch "$TEST_DIR/gaia-public/plugins/gaia/perf/${dn}/file.sh"
      cat > "$sd/story.md" <<STORY
---
key: "${key}"
epic: "${epic}"
status: in-progress
predicted_touch_set: ["gaia-public/plugins/gaia/perf/${dn}/file.sh"]
---
# Story: ${key}
STORY
    done
  done

  # Cold run (populates parse cache + realpath cache).
  local cache_dir; cache_dir="$(mktemp -d)"
  export GAIA_IC_CACHE_DIR="$cache_dir"
  bash "$IC_SCRIPT" --candidate sprint-900 > /dev/null 2>&1 || true

  # Verify cache populated (parse entries + realpath entries).
  local cache_count
  cache_count="$(find "$cache_dir" -type f | wc -l | tr -d ' ')"
  [ "$cache_count" -ge 45 ]

  # Change one story file so its cache entry is invalidated.
  echo "# changed" >> "$IMPL_DIR/epic-e900/E900-S1-perf/story.md"

  # Time ONLY the warm re-check (sub-second timer).
  local t0 t1 elapsed rc=0
  t0="$(_perf_now)"
  bash "$IC_SCRIPT" --candidate sprint-900 > /dev/null 2>&1 || rc=$?
  t1="$(_perf_now)"
  elapsed="$(python3 -c "print($t1-$t0)" 2>/dev/null || echo "$((${t1%%.*} - ${t0%%.*}))")"

  # Check passes (no overlap in disjoint fixture).
  [ "$rc" -eq 0 ]

  # Warm must complete within 2 seconds.
  _perf_check "$elapsed" 2

  # Verify cache invalidation: the changed story must have been re-parsed.
  # Its cache entry's stat line must reflect the NEW mtime+size (not the
  # original). Read the cache entry for E900-S1 and compare.
  local changed_sf="$IMPL_DIR/epic-e900/E900-S1-perf/story.md"
  local current_stat
  current_stat="$(stat -c '%Y %s' "$changed_sf" 2>/dev/null || stat -f '%m %z' "$changed_sf" 2>/dev/null)"
  local cid
  cid="$(printf '%s' "$changed_sf" | md5 2>/dev/null || printf '%s' "$changed_sf" | md5sum 2>/dev/null | cut -d' ' -f1)"
  local cached_stat
  cached_stat="$(head -1 "$cache_dir/$cid" 2>/dev/null || echo "MISSING")"
  [ "$cached_stat" = "$current_stat" ]

  rm -rf "$cache_dir"
}

@test "cold re-check within 5 seconds for 3x15 stories" {
  local s snum key sid epic
  for s in 900 901 902; do
    sid="sprint-${s}"; epic="E${s}"
    local epic_slug; epic_slug="$(printf '%s' "$epic" | tr '[:upper:]' '[:lower:]')"
    local f="$STATE_DIR/sprint-status-${sid}.yaml"
    printf 'sprint_id: "%s"\nstatus: active\ntotal_points: 0\ngoals: []\nstories:\n' "$sid" > "$f"
    for snum in $(seq 1 15); do
      key="${epic}-S${snum}"
      printf '  - key: "%s"\n    title: "Story %s"\n    status: "in-progress"\n    points: 3\n    risk: "medium"\n' "$key" "$key" >> "$f"
      local sd="$IMPL_DIR/epic-${epic_slug}/${key}-perf"
      mkdir -p "$sd"
      local dn="dir-${s}-${snum}"
      mkdir -p "$TEST_DIR/gaia-public/plugins/gaia/perf/${dn}"
      touch "$TEST_DIR/gaia-public/plugins/gaia/perf/${dn}/file.sh"
      cat > "$sd/story.md" <<STORY
---
key: "${key}"
epic: "${epic}"
status: in-progress
predicted_touch_set: ["gaia-public/plugins/gaia/perf/${dn}/file.sh"]
---
# Story: ${key}
STORY
    done
  done

  local t0 t1 elapsed rc=0
  t0="$(_perf_now)"
  bash "$IC_SCRIPT" --candidate sprint-900 > /dev/null 2>&1 || rc=$?
  t1="$(_perf_now)"
  elapsed="$(python3 -c "print($t1-$t0)" 2>/dev/null || echo "$((${t1%%.*} - ${t0%%.*}))")"
  _perf_check "$elapsed" 5
}
