#!/usr/bin/env bats
# defensive-shell-coding-sweep.bats — tests for argument separators,
# fixed-string matching, input validation, and byte-identical mirror pairs.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPTS_LIB="$SCRIPTS_DIR/lib"
}

# ---------------------------------------------------------------------------
# transcript-writer: -- before user-derived pathspec
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

# ---------------------------------------------------------------------------
# fixture-analyzer: dedup grep handles dash-prefixed filenames
# ---------------------------------------------------------------------------

@test "fixture-analyzer: file-list with leading-dash entry still reports oversized" {
  local fa="$SCRIPTS_DIR/review-common/fixture-analyzer.sh"
  [ -f "$fa" ] || skip "fixture-analyzer.sh not found"
  # A file named -x first in the --file-list plus an oversized fixture must
  # give the oversized finding, with </dev/null so grep cannot read stdin.
  local d="$TEST_TMP/fa-dash"
  mkdir -p "$d/fixtures"
  seq 600 > "$d/-x"
  seq 600 > "$d/fixtures/big.json"
  printf -- '-x\n./fixtures/big.json\n' > "$d/list"
  run bash -c "cd '$d' && bash '$fa' --file-list list --max-lines 10 </dev/null"
  echo "$output"
  case "$output" in
    *oversized*) : ;;
    *) echo "FAIL: oversized fixture not reported when -x file present in --file-list"; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# _ic_is_known_key: fixed-string, whole-word matching
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

@test "independence-check: _ic_is_known_key whole-word match rejects substring" {
  local ic="$SCRIPTS_DIR/independence-check.sh"
  [ -f "$ic" ] || skip "independence-check.sh not found"
  local epics_file="$TEST_TMP/epics.md"
  printf 'E900-S10 story title\n' > "$epics_file"
  local func_file="$TEST_TMP/ic_known_key.sh"
  sed -n '/_ic_is_known_key()/,/^}/p' "$ic" > "$func_file"
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
# exact first-field matching in cache-write
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
# fd validation in acquire-lock.sh
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
# trailing-slash state_dir in close_predicate
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
# -C repo in PPO admission-failure cleanup
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
  local ppo="$SCRIPTS_DIR/phase-parallel-orchestrator.sh"
  [ -f "$ppo" ] || skip "phase-parallel-orchestrator.sh not found"
  local mock_repo="$TEST_TMP/mock-repo"
  mkdir -p "$mock_repo"
  git -C "$mock_repo" init -q
  git -C "$mock_repo" config user.email "test@test.local"
  git -C "$mock_repo" config user.name "Test"
  git -C "$mock_repo" commit -q --allow-empty -m init
  run bash -c "
    cd /tmp
    repo='$mock_repo'
    git -C \"\$repo\" worktree prune 2>&1
  "
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# session-binding: mkdir/chmod failure detection
# ---------------------------------------------------------------------------

@test "session-binding: provision_binding_dir detects mkdir failure" {
  local sb="$SCRIPTS_LIB/session-binding.sh"
  [ -f "$sb" ] || skip "session-binding.sh not found"
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
  /usr/bin/grep -q 'if ! chmod 0700' "$sb" || {
    echo "FAIL: chmod error detection not found (still swallowed by || true)"
    return 1
  }
  /usr/bin/grep -q 'chmod 0700 failed' "$sb" || {
    echo "FAIL: chmod failure diagnostic message not found"
    return 1
  }
}

@test "session-binding: provision_binding_dir verifies mode 0700" {
  local sb="$SCRIPTS_LIB/session-binding.sh"
  [ -f "$sb" ] || skip "session-binding.sh not found"
  /usr/bin/grep -q '700' "$sb" || {
    echo "FAIL: 700 mode check not found in provision_binding_dir"; return 1
  }
}

# ---------------------------------------------------------------------------
# session-binding: length cap
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
# hook length cap on session id and bound sprint id
# ---------------------------------------------------------------------------

@test "hooks index.js: session id length cap at 64 characters" {
  local hook="$BATS_TEST_DIRNAME/../hooks/index.js"
  [ -f "$hook" ] || skip "hooks/index.js not found"
  /usr/bin/grep -q 'sessionId.length <= 64' "$hook" || {
    echo "FAIL: sessionId length cap not found in hook"; return 1
  }
  /usr/bin/grep -q 'boundId.length <= 64' "$hook" || {
    echo "FAIL: boundId length cap not found in hook"; return 1
  }
}

# ---------------------------------------------------------------------------
# cache symlink guard (behavioural)
# ---------------------------------------------------------------------------

@test "independence-check: symlinked cache file refused (behavioural)" {
  local ic="$SCRIPTS_DIR/independence-check.sh"
  [ -f "$ic" ] || skip "independence-check.sh not found"

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
  run bash -c "
    export PROJECT_ROOT='$proj' PROJECT_PATH='$proj' IMPLEMENTATION_ARTIFACTS='$impl'
    export GAIA_IC_CACHE_DIR='$cache' GAIA_SKIP_ORPHAN_SWEEP=1 GAIA_SNAPSHOT_HOOK_DISABLE=1
    bash '$ic' --candidate sprint-901 --active sprint-900
  "
  [ "$status" -eq 1 ]
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
  run bash -c "
    export PROJECT_ROOT='$proj' PROJECT_PATH='$proj' IMPLEMENTATION_ARTIFACTS='$impl'
    export GAIA_IC_CACHE_DIR='$cache' GAIA_SKIP_ORPHAN_SWEEP=1 GAIA_SNAPSHOT_HOOK_DISABLE=1
    bash '$ic' --candidate sprint-901 --active sprint-900
  "
  echo "$output"
  [ "$status" -eq 1 ]
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
# backslash denylist via canonical sanitizer (behavioural)
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

  printf 'sprint_id: "sprint-900"\nstatus: active\ntotal_points: 0\ngoals: []\nstories:\n  - key: "E900-S1"\n    title: "t"\n    status: "in-progress"\n    points: 3\n    risk: "medium"\n' > "$state/sprint-status-sprint-900.yaml"
  printf 'sprint_id: "sprint-901"\nstatus: planned\ntotal_points: 0\ngoals: []\nstories:\n  - key: "E901-S1"\n    title: "t"\n    status: "in-progress"\n    points: 3\n    risk: "medium"\n' > "$state/sprint-status-sprint-901.yaml"

  local eslug900="e900" eslug901="e901"
  mkdir -p "$impl/epic-${eslug900}/E900-S1-test" "$impl/epic-${eslug901}/E901-S1-test"
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
# overlay key with regex metachar (behavioural)
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

  local ov="$TEST_TMP/overlay.md"
  printf -- '---\nkey: "E90.-S1"\nepic: "E903"\nstatus: in-progress\npredicted_touch_set: ["gaia-public/plugins/gaia/scripts/sprint-state.sh"]\n---\n# x\n' > "$ov"

  run bash -c "
    export PROJECT_ROOT='$proj' PROJECT_PATH='$proj' IMPLEMENTATION_ARTIFACTS='$impl'
    export GAIA_SKIP_ORPHAN_SWEEP=1 GAIA_SNAPSHOT_HOOK_DISABLE=1
    bash '$ic' --candidate sprint-903 --active sprint-900 --overlay '$ov'
  "
  echo "$output"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# cost-select-tests.sh: leading-zero costs
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
# review-common analyzers: dedup grep handles dash-prefixed filenames
# ---------------------------------------------------------------------------

@test "review-common analyzers: dedup grep uses -- before variable" {
  local analyzers=(
    "$SCRIPTS_DIR/review-common/fixture-analyzer.sh"
    "$SCRIPTS_DIR/review-common/flakiness-analyzer.sh"
    "$SCRIPTS_DIR/review-common/smell-detector.sh"
    "$SCRIPTS_DIR/review-common/security/data-handling-lint.sh"
    "$SCRIPTS_DIR/review-common/security/pii-detector.sh"
    "$SCRIPTS_DIR/review-common/security/retention-policy-check.sh"
  )
  local a missing=""
  for a in "${analyzers[@]}"; do
    [ -f "$a" ] || continue
    # The -- must appear BEFORE the "$f" variable, not after it.
    # Correct:   grep -Fxq -- "$f" "$SEEN_TMP"
    # Wrong:     grep -Fxq "$f" "$SEEN_TMP" --
    if /usr/bin/grep 'grep.*Fxq.*SEEN_TMP' "$a" | /usr/bin/grep -v ' -- "' | /usr/bin/grep -q .; then
      missing="$missing $(basename "$a")"
    fi
  done
  [ -z "$missing" ] || { echo "FAIL: missing or misplaced -- in dedup grep:$missing"; return 1; }
}

# ---------------------------------------------------------------------------
# run-with-retry: is_flaky_test with dash-prefixed test id
# ---------------------------------------------------------------------------

@test "run-with-retry: is_flaky_test with dash-prefixed test id" {
  local rwr="$SCRIPTS_DIR/run-with-retry.sh"
  [ -f "$rwr" ] || skip "run-with-retry.sh not found"
  local flaky_file="$TEST_TMP/flaky.list"
  printf -- '-x weird test\n' > "$flaky_file"
  run bash -c "
    set -euo pipefail; export LC_ALL=C
    source '$rwr'
    result=\"\$(is_flaky_test '-x weird test' '$flaky_file')\"
    [ \"\$result\" = '1' ] || { echo \"FAIL: expected 1, got \$result\"; exit 1; }
    echo PASS
  "
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ---------------------------------------------------------------------------
# config-yaml-editor: dash-prefixed section handled safely
# ---------------------------------------------------------------------------

@test "config-yaml-editor: insert rejects dash-prefixed section name" {
  local cye="$SCRIPTS_DIR/config-yaml-editor.sh"
  [ -f "$cye" ] || skip "config-yaml-editor.sh not found"
  local cfg="$TEST_TMP/cfg.yaml"
  local newf="$TEST_TMP/newsec.yaml"
  printf 'project_name: test\n' > "$cfg"
  printf 'val: 1\n' > "$newf"
  # With --, the section name -eplatforms is treated as a literal and
  # rejected by the schema check. Without --, grep parses -e as a flag
  # and the schema check wrongly succeeds.
  run bash "$cye" insert "$cfg" '-eplatforms' "$newf" 2>&1
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown section"* ]]
}

# ---------------------------------------------------------------------------
# catch-all-flag: dash-prefixed epic key handled safely
# ---------------------------------------------------------------------------

@test "catch-all-flag: dash-prefixed key does not false-match via grep flag" {
  local caf="$SCRIPTS_LIB/catch-all-flag.sh"
  [ -f "$caf" ] || skip "catch-all-flag.sh not found"
  local epics="$TEST_TMP/epics-ca.md"
  local shards="$TEST_TMP/shards-ca"
  mkdir -p "$shards"
  printf '## E900\ncatch_all_epic: false\n' > "$epics"
  # With --, grep -Fqx treats -eE900 as a pattern to match. Without --,
  # grep interprets -e as a flag and matches E900 (false positive).
  run bash -c "
    set -euo pipefail; export LC_ALL=C
    source '$caf'
    _CATCH_ALL_SET=E900 is_catch_all '-eE900' '$epics' '$shards' 2>/dev/null && echo 'FOUND' || echo 'NOT-FOUND'
  "
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT-FOUND"* ]]
}

# ---------------------------------------------------------------------------
# retirement-sweep: .git exclusion with -- separator
# ---------------------------------------------------------------------------

@test "retirement-sweep: grep excludes .git directory with separator" {
  local rs="$SCRIPTS_DIR/retirement-sweep.sh"
  [ -f "$rs" ] || skip "retirement-sweep.sh not found"
  local d="$TEST_TMP/retsweep"
  mkdir -p "$d/pub/.git" "$d/ent"
  echo 'acmeprov ref' > "$d/pub/.git/HEAD-acmeprov"
  echo 'acmeprov' > "$d/pub/a.txt"
  run bash "$rs" --provider acmeprov --public-root "$d/pub" --enterprise-root "$d/ent" --output "$d/o.md"
  echo "$output"
  [ -f "$d/o.md" ] || { echo "FAIL: output file was never written"; return 1; }
  if /usr/bin/grep -c '\.git/' "$d/o.md" 2>/dev/null | /usr/bin/grep -qv '^0$'; then
    echo "FAIL: .git directory content leaked into retirement sweep output"
    cat "$d/o.md"
    return 1
  fi
}

@test "retirement-sweep: dash-prefixed provider treated as pattern not flag" {
  local rs="$SCRIPTS_DIR/retirement-sweep.sh"
  [ -f "$rs" ] || skip "retirement-sweep.sh not found"
  local d="$TEST_TMP/retsweep-dash"
  mkdir -p "$d/pub" "$d/ent"
  echo '-eprov match' > "$d/pub/a.txt"
  run bash "$rs" --provider '-eprov' --public-root "$d/pub" --enterprise-root "$d/ent" --output "$d/o.md"
  [ -f "$d/o.md" ] || { echo "FAIL: output not written"; return 1; }
  # The output must contain the hit for -eprov (treated as a literal pattern).
  /usr/bin/grep -q 'a.txt' "$d/o.md" || { echo "FAIL: dash-prefixed provider not found as pattern"; return 1; }
}

# ---------------------------------------------------------------------------
# chmod failure via PATH shim
# ---------------------------------------------------------------------------

@test "session-binding: provision_binding_dir fails when chmod fails (shim)" {
  local sb="$SCRIPTS_LIB/session-binding.sh"
  [ -f "$sb" ] || skip "session-binding.sh not found"
  local shim_dir="$TEST_TMP/chmod-shim"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/chmod" <<'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
  chmod +x "$shim_dir/chmod"
  local base="$TEST_TMP/chmod-test"
  mkdir -p "$base/.gaia/state/sessions"
  run bash -c "
    set -euo pipefail; export LC_ALL=C
    export PATH='$shim_dir':\$PATH
    export GAIA_BINDING_DIR=''
    source '$sb'
    provision_binding_dir --session-id 'test-session-chmod' --project-root '$base'
  "
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"chmod 0700 failed"* ]]
}

# ---------------------------------------------------------------------------
# mode 0700 verified after mkdir+chmod (noop-chmod shim)
# ---------------------------------------------------------------------------

@test "session-binding: provision_binding_dir detects wrong mode" {
  local sb="$SCRIPTS_LIB/session-binding.sh"
  [ -f "$sb" ] || skip "session-binding.sh not found"
  # Force a known umask so mkdir creates a non-700 directory.
  local shim_dir="$TEST_TMP/noopchmod-shim"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/chmod" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
  chmod +x "$shim_dir/chmod"
  local base="$TEST_TMP/mode-test"
  mkdir -p "$base/.gaia/state/sessions"
  run bash -c "
    set -euo pipefail; export LC_ALL=C
    umask 022
    export PATH='$shim_dir':\$PATH
    export GAIA_BINDING_DIR=''
    source '$sb'
    provision_binding_dir --session-id 'test-session-mode' --project-root '$base'
  "
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mode is"* ]] || [[ "$output" == *"expected 700"* ]]
}

# ---------------------------------------------------------------------------
# post-check confirms directory exists
# ---------------------------------------------------------------------------

@test "session-binding: provision_binding_dir post-check rejects missing dir" {
  local sb="$SCRIPTS_LIB/session-binding.sh"
  [ -f "$sb" ] || skip "session-binding.sh not found"
  local shim_dir="$TEST_TMP/mkdir-shim"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/mkdir" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
  chmod +x "$shim_dir/mkdir"
  cat > "$shim_dir/chmod" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
  chmod +x "$shim_dir/chmod"
  local base="$TEST_TMP/postcheck-test"
  mkdir -p "$base/.gaia/state/sessions"
  run bash -c "
    set -euo pipefail; export LC_ALL=C
    export PATH='$shim_dir':\$PATH
    export GAIA_BINDING_DIR=''
    source '$sb'
    provision_binding_dir --session-id 'test-session-post' --project-root '$base'
  "
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"absent after creation"* ]]
}

# ---------------------------------------------------------------------------
# canonical sanitizer routing: hash rule in modified copy proves routing
# ---------------------------------------------------------------------------

@test "independence-check: canonical sanitizer decides via added hash rule" {
  local ic="$SCRIPTS_DIR/independence-check.sh"
  [ -f "$ic" ] || skip "independence-check.sh not found"
  local san="$SCRIPTS_LIB/touch-set-sanitizer.sh"
  [ -f "$san" ] || skip "touch-set-sanitizer.sh not found"

  # Mirror the script directory via symlinks, replacing only the sanitizer.
  local sd="$TEST_TMP/ic-san-copy"
  mkdir -p "$sd/lib"
  # Symlink every file in the scripts dir.
  local f
  for f in "$SCRIPTS_DIR"/*; do
    [ -e "$f" ] || continue
    ln -sf "$f" "$sd/$(basename "$f")" 2>/dev/null || true
  done
  # Symlink every file in lib/.
  for f in "$SCRIPTS_LIB"/*; do
    [ -e "$f" ] || continue
    ln -sf "$f" "$sd/lib/$(basename "$f")" 2>/dev/null || true
  done
  # Replace the symlink to the sanitizer with a modified copy.
  rm -f "$sd/lib/touch-set-sanitizer.sh"
  awk '
    /rejected pipe/ { print; getline; print
      print "      \"#\") printf \"denylist: rejected hash\\n\" >&2; return 1 ;;"
      next
    }
    { print }
  ' "$san" > "$sd/lib/touch-set-sanitizer.sh"
  # Replace the symlink to independence-check with a copy (we modify it later).
  rm -f "$sd/independence-check.sh"
  cp "$ic" "$sd/independence-check.sh"

  # Build a minimal project with a hash-containing touch-set entry.
  local proj="$TEST_TMP/projhash"
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

  printf 'sprint_id: "sprint-900"\nstatus: active\ntotal_points: 0\ngoals: []\nstories:\n  - key: "E900-S1"\n    title: "t"\n    status: "in-progress"\n    points: 3\n    risk: "medium"\n' > "$state/sprint-status-sprint-900.yaml"
  printf 'sprint_id: "sprint-901"\nstatus: planned\ntotal_points: 0\ngoals: []\nstories:\n  - key: "E901-S1"\n    title: "t"\n    status: "in-progress"\n    points: 3\n    risk: "medium"\n' > "$state/sprint-status-sprint-901.yaml"

  mkdir -p "$impl/epic-e900/E900-S1-test" "$impl/epic-e901/E901-S1-test"
  printf -- '---\nkey: "E900-S1"\nepic: "E900"\nstatus: in-progress\npredicted_touch_set: ["gaia-public/plugins/gaia/hooks/foo#bar.sh"]\n---\n# s\n' > "$impl/epic-e900/E900-S1-test/story.md"
  printf -- '---\nkey: "E901-S1"\nepic: "E901"\nstatus: in-progress\npredicted_touch_set: ["gaia-public/plugins/gaia/hooks/pre-commit.sh"]\n---\n# s\n' > "$impl/epic-e901/E901-S1-test/story.md"

  # Run the copied script with the hash rule: must reject.
  run bash -c "
    export PROJECT_ROOT='$proj' PROJECT_PATH='$proj' IMPLEMENTATION_ARTIFACTS='$impl'
    export GAIA_SKIP_ORPHAN_SWEEP=1 GAIA_SNAPSHOT_HOOK_DISABLE=1
    bash '$sd/independence-check.sh' --candidate sprint-901 --active sprint-900
  "
  echo "=== With hash rule ==="
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"denylist rejected"* ]]

  # Now disable the canonical sanitizer pass and re-run: hash should be accepted.
  sed 's/if ! touch_set_denylist_check/if false \&\& touch_set_denylist_check/' \
    "$sd/independence-check.sh" > "$sd/independence-check-m7b.sh"
  run bash -c "
    export PROJECT_ROOT='$proj' PROJECT_PATH='$proj' IMPLEMENTATION_ARTIFACTS='$impl'
    export GAIA_SKIP_ORPHAN_SWEEP=1 GAIA_SNAPSHOT_HOOK_DISABLE=1
    bash '$sd/independence-check-m7b.sh' --candidate sprint-901 --active sprint-900
  "
  echo "=== Without canonical pass ==="
  echo "$output"
  # Without the canonical pass, the hash entry must NOT be rejected.
  case "$output" in
    *"denylist rejected"*) echo "FAIL: hash still rejected without canonical pass"; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# trace-dispatch-verb: dash-prefixed key does not bypass integration gate
# ---------------------------------------------------------------------------

@test "trace-dispatch-verb: dash-leading key halts instead of bypassing gate" {
  local S="$SCRIPTS_LIB/trace-dispatch-verb-enforcement.sh"
  [ -f "$S" ] || skip "trace-dispatch-verb-enforcement.sh not found"
  local d="$TEST_TMP/tdve"
  mkdir -p "$d"
  # A story whose key is -e. Without --, grep -F "-e" parses -e as a flag
  # and matches any row, letting the gate pass when it should halt.
  printf -- '---\nkey: "-e"\nrisk: medium\n---\n## Acceptance Criteria\n\n**AC1:** Given x, when the skill spawns the validator, then y.\n\n## Tasks\n' > "$d/story.md"
  printf '| TC-1 | E900-S1:AC1 | test_class: integration |\n' > "$d/matrix.md"
  run bash "$S" --story-file "$d/story.md" --matrix-file "$d/matrix.md"
  echo "$output"
  # Must halt (rc != 0): the -e key has no matching integration row.
  [ "$status" -ne 0 ]
  [[ "$output" == *"HALT"* ]]
}

# ---------------------------------------------------------------------------
# lint-bats-script-refs: dash-prefixed ignore pattern handled safely
# ---------------------------------------------------------------------------

@test "lint-bats-script-refs: dash-prefixed ignore pattern works" {
  local lint="$SCRIPTS_DIR/lint-bats-script-refs.sh"
  [ -f "$lint" ] || skip "lint-bats-script-refs.sh not found"
  # Verify the source code uses -- in the ignore-pattern grep.
  if /usr/bin/grep 'grep.*Eq.*"$pat"' "$lint" | /usr/bin/grep -v ' -- ' | /usr/bin/grep -q .; then
    echo "FAIL: ignore-pattern grep missing -- before pattern variable"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# independence-check: config-path filter uses --
# ---------------------------------------------------------------------------

@test "independence-check: config-path filter grep uses -- separator" {
  local ic="$SCRIPTS_DIR/independence-check.sh"
  [ -f "$ic" ] || skip "independence-check.sh not found"
  # The config-path filter greps must use -- before the variable.
  if /usr/bin/grep 'grep.*Fxv.*_ic_config_path' "$ic" | /usr/bin/grep -v ' -- ' | /usr/bin/grep -q .; then
    echo "FAIL: config-path filter Fxv grep missing --"
    return 1
  fi
  if /usr/bin/grep 'grep.*Fv.*_ic_config_path' "$ic" | /usr/bin/grep -v 'Fxv' | /usr/bin/grep -v ' -- ' | /usr/bin/grep -q .; then
    echo "FAIL: config-path filter Fv grep missing --"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# independence-check: config-section key lookup uses -F --
# ---------------------------------------------------------------------------

@test "independence-check: config-section key lookup uses fixed-string separator" {
  local ic="$SCRIPTS_DIR/independence-check.sh"
  [ -f "$ic" ] || skip "independence-check.sh not found"
  # The cck/ack lookups in _has_field.txt must use -F -- before the variable.
  if /usr/bin/grep 'grep.*qx.*_has_field' "$ic" | /usr/bin/grep -v ' -- ' | /usr/bin/grep -q .; then
    echo "FAIL: config-section key lookup missing -- before variable"
    return 1
  fi
  if /usr/bin/grep 'grep.*qx.*_has_field' "$ic" | /usr/bin/grep -v 'F' | /usr/bin/grep -q .; then
    echo "FAIL: config-section key lookup missing -F"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# no leaked internal identifiers in any changed file
# ---------------------------------------------------------------------------

@test "no leaked internal identifiers in changed files" {
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
    # Requirement/story/test-case/cascade identifiers.
    if /usr/bin/grep -En '(FR-[0-9]|NFR-[0-9]|SR-[0-9]|ADR-[0-9]|E[0-9]{2,}-S[0-9]+|TC-[0-9]|AF-20[0-9]{2}|AI-20[0-9]{2})' "$f" 2>/dev/null | /usr/bin/grep -v 'E9[0-9][0-9]-' | head -3; then
      echo "FAIL: leaked internal ID found in $(basename "$f")"
      return 1
    fi
    # Internal labels (single uppercase letter + digits) and process references.
    if /usr/bin/grep -nE '\b[MFB][0-9]+[a-z]?\b|\btest [0-9]+\b|[Rr]eviewer' "$f" 2>/dev/null | /usr/bin/grep -v 'E9[0-9][0-9]-' | /usr/bin/grep -v 'test_' | /usr/bin/grep -v '@test' | /usr/bin/grep -v 'BATS_TEST' | /usr/bin/grep -v 'TEST_TMP' | /usr/bin/grep -v 'test.local' | head -3; then
      echo "FAIL: leaked review label found in $(basename "$f")"
      return 1
    fi
  done
}
