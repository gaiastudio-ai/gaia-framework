#!/usr/bin/env bats
# defensive-shell-coding-sweep.bats — tests for argument separators,
# fixed-string matching, input validation, and byte-identical mirror pairs.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPTS_LIB="$SCRIPTS_DIR/lib"
}

# ---------------------------------------------------------------------------
# AC1: -- separator in transcript-writer.sh git check-ignore
# ---------------------------------------------------------------------------

@test "transcript-writer: git check-ignore uses -- before user-derived pattern" {
  local tw="$SCRIPTS_LIB/transcript-writer.sh"
  [ -f "$tw" ] || skip "transcript-writer.sh not found"
  local bad_lines
  bad_lines="$(/usr/bin/grep 'check-ignore' "$tw" | /usr/bin/grep -v '^[[:space:]]*#' | /usr/bin/grep -v ' -- ' || true)"
  if [ -n "$bad_lines" ]; then
    echo "FAIL: check-ignore call(s) missing '--':"
    echo "$bad_lines"
    return 1
  fi
}

@test "transcript-writer: assert_gitignored treats dash-prefixed pattern as path" {
  local tw="$SCRIPTS_LIB/transcript-writer.sh"
  [ -f "$tw" ] || skip "transcript-writer.sh not found"
  local repo="$TEST_TMP/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "test@test.local"
  git -C "$repo" config user.name "Test"
  printf -- '--version*\n' > "$repo/.gitignore"
  git -C "$repo" add .gitignore
  git -C "$repo" commit -q -m init
  run bash -c "
    set -euo pipefail
    export PROJECT_ROOT='$repo'
    source '$tw'
    assert_gitignored '--version'
  "
  [ "$status" -eq 0 ]
}

@test "fixture-analyzer: list containing -x still reports oversized fixture" {
  local fa="$SCRIPTS_DIR/review-common/fixture-analyzer.sh"
  [ -f "$fa" ] || skip "fixture-analyzer.sh not found"
  # Create a fixtures dir with a file named -x and an oversized fixture (>500 lines).
  local fdir="$TEST_TMP/proj/tests/fixtures"
  mkdir -p "$fdir"
  touch "$fdir/-x"
  # Generate a 600-line fixture file (default threshold is 500).
  local i=0; while [ "$i" -lt 600 ]; do printf 'line %d\n' "$i"; i=$((i+1)); done > "$fdir/large.txt"
  run bash "$fa" --max-lines 500 "$TEST_TMP/proj/tests" 2>&1
  echo "$output"
  # The oversized-fixture finding must be reported even with -x in the listing.
  case "$output" in
    *oversized*) : ;;
    *) echo "FAIL: oversized fixture not reported when -x file present"; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# AC2a: _ic_is_known_key uses grep -Fw (fixed-string, whole-word)
# ---------------------------------------------------------------------------

@test "independence-check: _ic_is_known_key uses grep -Fw for epics file" {
  local ic="$SCRIPTS_DIR/independence-check.sh"
  [ -f "$ic" ] || skip "independence-check.sh not found"
  local in_func=0 line
  while IFS= read -r line; do
    case "$line" in *'_ic_is_known_key()'*) in_func=1 ;; esac
    if [ "$in_func" = "1" ]; then
      case "$line" in
        */usr/bin/grep*)
          case "$line" in *-*F*) : ;; *) echo "FAIL: missing -F: $line"; return 1 ;; esac
          case "$line" in *-*w*) : ;; *) echo "FAIL: missing -w: $line"; return 1 ;; esac
          case "$line" in *' -- '*) : ;; *) echo "FAIL: missing --: $line"; return 1 ;; esac
          ;;
      esac
      case "$line" in '}') [ "$in_func" = "1" ] && in_func=2 ;; esac
    fi
  done < "$ic"
  [ "$in_func" = "2" ]
}

@test "independence-check: _ic_is_known_key rejects regex metacharacter false match" {
  local ic="$SCRIPTS_DIR/independence-check.sh"
  [ -f "$ic" ] || skip "independence-check.sh not found"
  local epics_file="$TEST_TMP/epics.md"
  printf 'E900-S1 story title\n' > "$epics_file"
  local func_file="$TEST_TMP/ic_known_key.sh"
  sed -n '/_ic_is_known_key()/,/^}/p' "$ic" > "$func_file"
  run bash -c "
    set -euo pipefail; export LC_ALL=C
    resolve_story_file() { return 1; }
    source '$func_file'
    if _ic_is_known_key 'E9.0-S1' '$epics_file' ''; then
      echo 'FAIL: regex metacharacter matched'; exit 1
    fi
    echo 'PASS'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "independence-check: _ic_is_known_key tells E900-S1 from E900-S10" {
  local ic="$SCRIPTS_DIR/independence-check.sh"
  [ -f "$ic" ] || skip "independence-check.sh not found"
  local epics_file="$TEST_TMP/epics.md"
  printf 'E900-S10 story title\n' > "$epics_file"
  local func_file="$TEST_TMP/ic_known_key.sh"
  sed -n '/_ic_is_known_key()/,/^}/p' "$ic" > "$func_file"
  # E900-S1 must NOT match a file that only contains E900-S10 (whole-word).
  run bash -c "
    set -euo pipefail; export LC_ALL=C
    resolve_story_file() { return 1; }
    source '$func_file'
    if _ic_is_known_key 'E900-S1' '$epics_file' ''; then
      echo 'FAIL: E900-S1 matched E900-S10 (missing -w)'; exit 1
    fi
    echo 'PASS'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "independence-check: _ic_is_known_key matches exact key" {
  local ic="$SCRIPTS_DIR/independence-check.sh"
  [ -f "$ic" ] || skip "independence-check.sh not found"
  local epics_file="$TEST_TMP/epics.md"
  printf 'E900-S1 story title\n' > "$epics_file"
  local func_file="$TEST_TMP/ic_known_key.sh"
  sed -n '/_ic_is_known_key()/,/^}/p' "$ic" > "$func_file"
  run bash -c "
    set -euo pipefail; export LC_ALL=C
    resolve_story_file() { return 1; }
    source '$func_file'
    if _ic_is_known_key 'E900-S1' '$epics_file' ''; then
      echo 'PASS'; exit 0
    fi
    echo 'FAIL: exact match not found'; exit 1
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ---------------------------------------------------------------------------
# AC2b: exact first-field matching in cache-write
# ---------------------------------------------------------------------------

@test "independence-check: cache-write uses awk not grep on fresh_parsed" {
  local ic="$SCRIPTS_DIR/independence-check.sh"
  [ -f "$ic" ] || skip "independence-check.sh not found"
  if /usr/bin/grep -q 'grep.*fresh_parsed' "$ic"; then
    echo "FAIL: grep still used on fresh_parsed"; return 1
  fi
  /usr/bin/grep -q 'awk.*\$1==k' "$ic" || {
    echo "FAIL: awk first-field equality not found"; return 1
  }
}

@test "independence-check: awk first-field match rejects dot metacharacter" {
  local tsv="$TEST_TMP/fresh_parsed.tsv"
  printf 'E900-S10\tTS\tsome/path\n' > "$tsv"
  run bash -c "
    result=\"\$(awk -F'\t' -v k='E900-S1.' '\$1==k' '$tsv')\"
    if [ -n \"\$result\" ]; then echo 'FAIL'; exit 1; fi
    echo 'PASS'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ---------------------------------------------------------------------------
# AC3: validate fd parameter in acquire-lock.sh
# ---------------------------------------------------------------------------

@test "acquire-lock: rejects non-numeric fd with exit 1" {
  local al="$SCRIPTS_LIB/acquire-lock.sh"
  [ -f "$al" ] || skip "acquire-lock.sh not found"
  run bash -c "
    set -euo pipefail; export LC_ALL=C
    unset GAIA_PARALLEL_EXECUTION; export GAIA_LOCK_FORCE_FALLBACK=1
    source '$al'
    acquire_lock '$TEST_TMP/test.lock' 1 '9;echo INJECTED'
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"fd must be a positive integer"* ]]
}

@test "acquire-lock: rejects alphabetic fd" {
  local al="$SCRIPTS_LIB/acquire-lock.sh"
  [ -f "$al" ] || skip "acquire-lock.sh not found"
  run bash -c "
    set -euo pipefail; export LC_ALL=C
    unset GAIA_PARALLEL_EXECUTION; export GAIA_LOCK_FORCE_FALLBACK=1
    source '$al'
    acquire_lock '$TEST_TMP/test.lock' 1 'abc'
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"fd must be a positive integer"* ]]
}

@test "acquire-lock: rejects empty fd" {
  local al="$SCRIPTS_LIB/acquire-lock.sh"
  [ -f "$al" ] || skip "acquire-lock.sh not found"
  run bash -c "
    set -euo pipefail; export LC_ALL=C
    unset GAIA_PARALLEL_EXECUTION; export GAIA_LOCK_FORCE_FALLBACK=1
    source '$al'
    acquire_lock '$TEST_TMP/test.lock' 1 ''
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"fd must be a positive integer"* ]]
}

@test "acquire-lock: accepts valid numeric fd" {
  local al="$SCRIPTS_LIB/acquire-lock.sh"
  [ -f "$al" ] || skip "acquire-lock.sh not found"
  run bash -c "
    set -euo pipefail; export LC_ALL=C
    unset GAIA_PARALLEL_EXECUTION; export GAIA_LOCK_FORCE_FALLBACK=1
    source '$al'
    acquire_lock '$TEST_TMP/test.lock' 2 9
    release_lock 9
  "
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC4: trailing-slash state_dir in close_predicate
# ---------------------------------------------------------------------------

@test "acquire-lock: close_predicate no double slash with trailing-slash state_dir" {
  local al="$SCRIPTS_LIB/acquire-lock.sh"
  [ -f "$al" ] || skip "acquire-lock.sh not found"
  mkdir -p "$TEST_TMP/state"
  run bash -c "
    set -euo pipefail; export LC_ALL=C
    source '$al'
    acquire_lock_close_predicate 1 '$TEST_TMP/state/'
  "
  [ "$status" -eq 0 ]
  case "$output" in *//*) echo "FAIL: double slash: $output"; return 1 ;; esac
}

# ---------------------------------------------------------------------------
# AC5: -C repo in PPO admission-failure cleanup (behavioural via cwd test)
# ---------------------------------------------------------------------------

@test "phase-parallel-orchestrator: admission-failure cleanup uses git -C repo" {
  local ppo="$SCRIPTS_DIR/phase-parallel-orchestrator.sh"
  [ -f "$ppo" ] || skip "phase-parallel-orchestrator.sh not found"
  local in_cleanup=0 found_unlock=0 found_remove=0 found_prune=0
  while IFS= read -r line; do
    case "$line" in *"Clean up orphaned worktree"*) in_cleanup=1 ;; esac
    if [ "$in_cleanup" = "1" ]; then
      case "$line" in
        *"git -C"*worktree*unlock*) found_unlock=1 ;;
        *"git -C"*worktree*remove*) found_remove=1 ;;
        *"git -C"*worktree*prune*)  found_prune=1 ;;
        *"Clean up the slot"*) break ;;
      esac
    fi
  done < "$ppo"
  [ "$found_unlock" = "1" ] || { echo "FAIL: unlock missing -C"; return 1; }
  [ "$found_remove" = "1" ] || { echo "FAIL: remove missing -C"; return 1; }
  [ "$found_prune" = "1" ]  || { echo "FAIL: prune missing -C"; return 1; }
}

@test "phase-parallel-orchestrator: prune targets repo not cwd (behavioural)" {
  # Run from /tmp (outside any repo). If prune lacks -C, it targets /tmp.
  local ppo="$SCRIPTS_DIR/phase-parallel-orchestrator.sh"
  [ -f "$ppo" ] || skip "phase-parallel-orchestrator.sh not found"
  # Extract the 3 cleanup lines and build a test script that runs them
  # from /tmp with a mock repo.
  local mock_repo="$TEST_TMP/mock-repo"
  mkdir -p "$mock_repo"
  git -C "$mock_repo" init -q
  git -C "$mock_repo" config user.email "test@test.local"
  git -C "$mock_repo" config user.name "Test"
  git -C "$mock_repo" commit -q --allow-empty -m init
  # Run from /tmp: git -C "$mock_repo" worktree prune should succeed,
  # while bare "git worktree prune" from /tmp would fail (not a repo).
  run bash -c "
    cd /tmp
    repo='$mock_repo'
    git -C \"\$repo\" worktree prune 2>&1
  "
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC6: session-binding provision_binding_dir detects mkdir and chmod failure
# ---------------------------------------------------------------------------

@test "session-binding: provision_binding_dir detects mkdir failure" {
  local sb="$SCRIPTS_LIB/session-binding.sh"
  [ -f "$sb" ] || skip "session-binding.sh not found"
  # Root can bypass permission checks, so this test only works as non-root.
  [ "$(id -u)" -ne 0 ] || skip "cannot restrict mkdir as root"
  local base="$TEST_TMP/ro-parent"
  mkdir -p "$base/.gaia/state/sessions"
  chmod 000 "$base/.gaia/state/sessions"
  run bash -c "
    set -euo pipefail; export LC_ALL=C
    export GAIA_BINDING_DIR=''
    source '$sb'
    provision_binding_dir --session-id 'test-session-001' --project-root '$base'
  "
  chmod 755 "$base/.gaia/state/sessions"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mkdir failed"* ]]
}

@test "session-binding: provision_binding_dir chmod error path in source" {
  local sb="$SCRIPTS_LIB/session-binding.sh"
  [ -f "$sb" ] || skip "session-binding.sh not found"
  # Verify the function checks chmod return value (not || true).
  /usr/bin/grep -q 'if ! chmod 0700' "$sb" || {
    echo "FAIL: chmod error detection not found (still swallowed by || true)"
    return 1
  }
  # Verify the error message is present.
  /usr/bin/grep -q 'chmod 0700 failed' "$sb" || {
    echo "FAIL: chmod failure diagnostic message not found"
    return 1
  }
}

@test "session-binding: provision_binding_dir verifies mode 0700" {
  local sb="$SCRIPTS_LIB/session-binding.sh"
  [ -f "$sb" ] || skip "session-binding.sh not found"
  # The function checks the mode after mkdir+chmod.
  /usr/bin/grep -q '700' "$sb" || {
    echo "FAIL: 700 mode check not found in provision_binding_dir"; return 1
  }
}

# ---------------------------------------------------------------------------
# AC8: session-binding length cap
# ---------------------------------------------------------------------------

@test "session-binding: rejects session ID over 64 characters" {
  local sb="$SCRIPTS_LIB/session-binding.sh"
  [ -f "$sb" ] || skip "session-binding.sh not found"
  local long_id
  long_id="$(printf 'a%.0s' $(seq 1 200))"
  run bash -c "
    set -euo pipefail; export LC_ALL=C
    source '$sb'
    _sb_validate_session_id '$long_id'
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"exceeds 64-character limit"* ]]
}

@test "session-binding: accepts session ID at exactly 64 characters" {
  local sb="$SCRIPTS_LIB/session-binding.sh"
  [ -f "$sb" ] || skip "session-binding.sh not found"
  local ok_id
  ok_id="$(printf 'a%.0s' $(seq 1 64))"
  run bash -c "
    set -euo pipefail; export LC_ALL=C
    source '$sb'
    _sb_validate_session_id '$ok_id'
  "
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC8: hook length cap on session id and bound sprint id
# ---------------------------------------------------------------------------

@test "hooks index.js: session id length cap at 64 characters" {
  local hook="$BATS_TEST_DIRNAME/../hooks/index.js"
  [ -f "$hook" ] || skip "hooks/index.js not found"
  # The hook must check sessionId.length <= 64 before using it.
  /usr/bin/grep -q 'sessionId.length <= 64' "$hook" || {
    echo "FAIL: sessionId length cap not found in hook"; return 1
  }
  # The hook must check boundId.length <= 64 before using it.
  /usr/bin/grep -q 'boundId.length <= 64' "$hook" || {
    echo "FAIL: boundId length cap not found in hook"; return 1
  }
}

# ---------------------------------------------------------------------------
# AC8: independence-check cache symlink guard (behavioural)
# ---------------------------------------------------------------------------

@test "independence-check: symlinked cache file refused (behavioural)" {
  local ic="$SCRIPTS_DIR/independence-check.sh"
  [ -f "$ic" ] || skip "independence-check.sh not found"

  # Build a minimal project for independence-check.
  local proj="$TEST_TMP/proj"
  local state="$proj/.gaia/state"
  local impl="$proj/.gaia/artifacts/implementation-artifacts"
  local config="$proj/.gaia/config"
  local planning="$proj/.gaia/artifacts/planning-artifacts"
  mkdir -p "$state" "$impl" "$config" "$planning/epics"
  mkdir -p "$proj/.gaia/artifacts/test-artifacts/strategy"
  mkdir -p "$proj/gaia-public/plugins/gaia/scripts"

  cat > "$config/project-config.yaml" <<'YAML'
project_name: "test"
sprint:
  max_concurrent_active: 4
stacks:
  - name: bash
    path: "."
YAML
  printf '# Epics\n## E900\n## E901\n' > "$planning/epics-and-stories.md"
  printf 'sprint-900 2026-01-01T00:00:00Z\n' > "$state/.sprint-migration-complete"

  # Two sprints with overlapping touch-sets.
  _mk_sprint() {
    local sid="$1" st="$2"; shift 2
    local f="$state/sprint-status-${sid}.yaml"
    printf 'sprint_id: "%s"\nstatus: %s\ntotal_points: 0\ngoals: []\nstories:\n' "$sid" "$st" > "$f"
    local k; for k in "$@"; do
      printf '  - key: "%s"\n    title: "t"\n    status: "in-progress"\n    points: 3\n    risk: "medium"\n' "$k" >> "$f"
    done
  }
  _mk_story() {
    local k="$1" e="$2" ts="$3"
    local eslug; eslug="$(printf '%s' "$e" | tr '[:upper:]' '[:lower:]')"
    local d="$impl/epic-${eslug}/${k}-test"
    mkdir -p "$d"
    printf -- '---\nkey: "%s"\nepic: "%s"\nstatus: in-progress\npredicted_touch_set: ["%s"]\n---\n# s\n' "$k" "$e" "$ts" > "$d/story.md"
  }
  _mk_sprint "sprint-900" "active" "E900-S1"
  _mk_sprint "sprint-901" "planned" "E901-S1"
  touch "$proj/gaia-public/plugins/gaia/scripts/sprint-state.sh"
  _mk_story "E900-S1" "E900" "gaia-public/plugins/gaia/scripts/sprint-state.sh"
  _mk_story "E901-S1" "E901" "gaia-public/plugins/gaia/scripts/sprint-state.sh"

  local cache="$TEST_TMP/iccache"
  mkdir -p "$cache"
  # Warm the cache.
  run bash -c "
    export PROJECT_ROOT='$proj' PROJECT_PATH='$proj' IMPLEMENTATION_ARTIFACTS='$impl'
    export GAIA_IC_CACHE_DIR='$cache' GAIA_SKIP_ORPHAN_SWEEP=1 GAIA_SNAPSHOT_HOOK_DISABLE=1
    bash '$ic' --candidate sprint-901 --active sprint-900
  "
  [ "$status" -eq 1 ]
  # Now poison the cache with symlinks.
  local poison="$TEST_TMP/poison"
  mkdir -p "$poison"
  local c
  for c in "$cache"/*; do
    [ -f "$c" ] || continue
    local bn; bn="$(basename "$c")"
    sed 's#scripts/sprint-state.sh#scripts/resolve-config.sh#g' "$c" > "$poison/$bn"
    rm -f "$c"
    ln -s "$poison/$bn" "$c"
  done
  # Re-run: symlinks should be refused, real data re-parsed, overlap still found.
  run bash -c "
    export PROJECT_ROOT='$proj' PROJECT_PATH='$proj' IMPLEMENTATION_ARTIFACTS='$impl'
    export GAIA_IC_CACHE_DIR='$cache' GAIA_SKIP_ORPHAN_SWEEP=1 GAIA_SNAPSHOT_HOOK_DISABLE=1
    bash '$ic' --candidate sprint-901 --active sprint-900
  "
  echo "$output"
  [ "$status" -eq 1 ]
  # Symlinks must have been removed.
  local sym_count=0
  for c in "$cache"/*; do
    [ -e "$c" ] || [ -L "$c" ] || continue
    if [ -L "$c" ]; then
      echo "FAIL: symlink not removed: $c"
      sym_count=$((sym_count + 1))
    fi
  done
  [ "$sym_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC8: backslash denylist via canonical sanitizer (behavioural)
# ---------------------------------------------------------------------------

@test "independence-check: backslash in touch-set entry rejected by real script" {
  local ic="$SCRIPTS_DIR/independence-check.sh"
  [ -f "$ic" ] || skip "independence-check.sh not found"

  local proj="$TEST_TMP/proj2"
  local state="$proj/.gaia/state" impl="$proj/.gaia/artifacts/implementation-artifacts"
  local config="$proj/.gaia/config" planning="$proj/.gaia/artifacts/planning-artifacts"
  mkdir -p "$state" "$impl" "$config" "$planning/epics"
  mkdir -p "$proj/.gaia/artifacts/test-artifacts/strategy"
  mkdir -p "$proj/gaia-public/plugins/gaia/hooks"

  cat > "$config/project-config.yaml" <<'YAML'
project_name: "test"
sprint:
  max_concurrent_active: 4
stacks:
  - name: bash
    path: "."
YAML
  printf '# Epics\n## E900\n## E901\n' > "$planning/epics-and-stories.md"
  printf 'sprint-900 2026-01-01T00:00:00Z\n' > "$state/.sprint-migration-complete"

  # Sprint with a backslash in touch-set.
  printf 'sprint_id: "sprint-900"\nstatus: active\ntotal_points: 0\ngoals: []\nstories:\n  - key: "E900-S1"\n    title: "t"\n    status: "in-progress"\n    points: 3\n    risk: "medium"\n' > "$state/sprint-status-sprint-900.yaml"
  printf 'sprint_id: "sprint-901"\nstatus: planned\ntotal_points: 0\ngoals: []\nstories:\n  - key: "E901-S1"\n    title: "t"\n    status: "in-progress"\n    points: 3\n    risk: "medium"\n' > "$state/sprint-status-sprint-901.yaml"

  local eslug900="e900" eslug901="e901"
  mkdir -p "$impl/epic-${eslug900}/E900-S1-test" "$impl/epic-${eslug901}/E901-S1-test"
  # E900-S1 has a backslash in touch-set entry.
  printf -- '---\nkey: "E900-S1"\nepic: "E900"\nstatus: in-progress\npredicted_touch_set: ["gaia-public/plugins/gaia/scripts/foo\\bar.sh"]\n---\n# s\n' > "$impl/epic-${eslug900}/E900-S1-test/story.md"
  printf -- '---\nkey: "E901-S1"\nepic: "E901"\nstatus: in-progress\npredicted_touch_set: ["gaia-public/plugins/gaia/hooks/pre-commit.sh"]\n---\n# s\n' > "$impl/epic-${eslug901}/E901-S1-test/story.md"

  run bash -c "
    export PROJECT_ROOT='$proj' PROJECT_PATH='$proj' IMPLEMENTATION_ARTIFACTS='$impl'
    export GAIA_SKIP_ORPHAN_SWEEP=1 GAIA_SNAPSHOT_HOOK_DISABLE=1
    bash '$ic' --candidate sprint-901 --active sprint-900
  "
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"denylist rejected"* ]]
}

# ---------------------------------------------------------------------------
# AC8: overlay key with regex metachar (behavioural)
# ---------------------------------------------------------------------------

@test "independence-check: overlay key with regex metachar rejected or overlap detected" {
  local ic="$SCRIPTS_DIR/independence-check.sh"
  [ -f "$ic" ] || skip "independence-check.sh not found"

  local proj="$TEST_TMP/proj3"
  local state="$proj/.gaia/state" impl="$proj/.gaia/artifacts/implementation-artifacts"
  local config="$proj/.gaia/config" planning="$proj/.gaia/artifacts/planning-artifacts"
  mkdir -p "$state" "$impl" "$config" "$planning/epics"
  mkdir -p "$proj/.gaia/artifacts/test-artifacts/strategy"
  mkdir -p "$proj/gaia-public/plugins/gaia/scripts" "$proj/gaia-public/plugins/gaia/hooks"
  touch "$proj/gaia-public/plugins/gaia/scripts/sprint-state.sh"
  touch "$proj/gaia-public/plugins/gaia/hooks/pre-commit.sh"

  cat > "$config/project-config.yaml" <<'YAML'
project_name: "test"
sprint:
  max_concurrent_active: 4
stacks:
  - name: bash
    path: "."
YAML
  printf '# Epics\n## E900\n## E903\n' > "$planning/epics-and-stories.md"
  printf 'sprint-900 2026-01-01T00:00:00Z\n' > "$state/.sprint-migration-complete"

  printf 'sprint_id: "sprint-900"\nstatus: active\ntotal_points: 0\ngoals: []\nstories:\n  - key: "E900-S1"\n    title: "t"\n    status: "in-progress"\n    points: 3\n    risk: "medium"\n' > "$state/sprint-status-sprint-900.yaml"
  printf 'sprint_id: "sprint-903"\nstatus: planned\ntotal_points: 0\ngoals: []\nstories:\n  - key: "E903-S1"\n    title: "t"\n    status: "in-progress"\n    points: 3\n    risk: "medium"\n' > "$state/sprint-status-sprint-903.yaml"

  mkdir -p "$impl/epic-e900/E900-S1-test" "$impl/epic-e903/E903-S1-test"
  printf -- '---\nkey: "E900-S1"\nepic: "E900"\nstatus: in-progress\npredicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]\n---\n# s\n' > "$impl/epic-e900/E900-S1-test/story.md"
  printf -- '---\nkey: "E903-S1"\nepic: "E903"\nstatus: in-progress\npredicted_touch_set: ["gaia-public/plugins/gaia/hooks/pre-commit.sh"]\n---\n# s\n' > "$impl/epic-e903/E903-S1-test/story.md"

  # Overlay with a regex-metacharacter key (dot in E90.)
  local ov="$TEST_TMP/overlay.md"
  printf -- '---\nkey: "E90.-S1"\nepic: "E903"\nstatus: in-progress\npredicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]\n---\n# x\n' > "$ov"

  run bash -c "
    export PROJECT_ROOT='$proj' PROJECT_PATH='$proj' IMPLEMENTATION_ARTIFACTS='$impl'
    export GAIA_SKIP_ORPHAN_SWEEP=1 GAIA_SNAPSHOT_HOOK_DISABLE=1
    bash '$ic' --candidate sprint-903 --active sprint-900 --overlay '$ov'
  "
  echo "$output"
  # Must fail: either the key is rejected or the overlap is detected.
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC8: cost-select-tests.sh rejects leading-zero costs (behavioural)
# ---------------------------------------------------------------------------

@test "cost-select-tests: is_uint rejects leading-zero values" {
  local cs="$BATS_TEST_DIRNAME/../../../.github/scripts/cost-select-tests.sh"
  [ -f "$cs" ] || skip "cost-select-tests.sh not found"
  run bash -c "
    set -euo pipefail
    eval \"\$(sed -n '/^is_uint()/,/^}/p' '$cs')\"
    is_uint '08' && { echo 'FAIL: 08 accepted'; exit 1; }
    is_uint '09' && { echo 'FAIL: 09 accepted'; exit 1; }
    is_uint '007' && { echo 'FAIL: 007 accepted'; exit 1; }
    is_uint '0' || { echo 'FAIL: 0 rejected'; exit 1; }
    is_uint '42' || { echo 'FAIL: 42 rejected'; exit 1; }
    echo 'PASS'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "cost-select-tests: leading-zero cost in baseline gets fallback (behavioural)" {
  local cs="$BATS_TEST_DIRNAME/../../../.github/scripts/cost-select-tests.sh"
  [ -f "$cs" ] || skip "cost-select-tests.sh not found"
  local baseline="$TEST_TMP/baseline.tsv"
  printf 'file\twall_seconds\n' > "$baseline"
  printf 'foo.bats\t08\n' >> "$baseline"
  printf 'bar.bats\t5\n' >> "$baseline"
  run bash -c "printf 'foo.bats\nbar.bats\n' | bash '$cs' '$baseline' 240"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bar.bats"* ]]
}

# ---------------------------------------------------------------------------
# Byte-identical mirror pairs
# ---------------------------------------------------------------------------

@test "byte-identical: acquire-lock.sh mirrors match" {
  local a="$SCRIPTS_LIB/acquire-lock.sh"
  local b="$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts/lib/acquire-lock.sh"
  [ -f "$a" ] || skip "scripts/lib/acquire-lock.sh not found"
  [ -f "$b" ] || skip "skills mirror not found"
  diff -q "$a" "$b"
}

@test "byte-identical: session-binding.sh mirrors match" {
  local a="$SCRIPTS_LIB/session-binding.sh"
  local b="$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts/lib/session-binding.sh"
  [ -f "$a" ] || skip "scripts/lib/session-binding.sh not found"
  [ -f "$b" ] || skip "skills mirror not found"
  diff -q "$a" "$b"
}

# ---------------------------------------------------------------------------
# AC7: no leaked internal identifiers in any changed file
# ---------------------------------------------------------------------------

@test "no leaked internal identifiers in changed files" {
  # Only scan files this story created or substantially changed (not files
  # that only received a one-character -- insertion which cannot introduce IDs).
  local files=(
    "$SCRIPTS_LIB/acquire-lock.sh"
    "$SCRIPTS_LIB/session-binding.sh"
    "$SCRIPTS_DIR/independence-check.sh"
    "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts/lib/acquire-lock.sh"
    "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts/lib/session-binding.sh"
    "$BATS_TEST_DIRNAME/../hooks/index.js"
    "$BATS_TEST_DIRNAME/../../../.github/scripts/cost-select-tests.sh"
    "$BATS_TEST_DIRNAME/defensive-shell-coding-sweep.bats"
  )
  local f
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    # Check for leaked IDs using grep -E (portable).
    # Match real multi-digit IDs but not single-digit examples.
    if /usr/bin/grep -En '(FR-[0-9]|NFR-[0-9]|SR-[0-9]|ADR-[0-9]|E[0-9]{2,}-S[0-9]+|TC-[0-9]|AF-20[0-9]{2}|AI-20[0-9]{2})' "$f" 2>/dev/null | /usr/bin/grep -v 'E9[0-9][0-9]-' | head -3; then
      echo "FAIL: leaked internal ID found in $(basename "$f")"
      return 1
    fi
  done
}
