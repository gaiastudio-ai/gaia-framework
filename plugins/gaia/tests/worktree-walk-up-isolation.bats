#!/usr/bin/env bats
# worktree-walk-up-isolation.bats — regression tests for walk-up boundary
# isolation in gaia-paths.sh and resolve-config.sh.

load 'test_helper.bash'

setup() {
  common_setup
  LIB="$SCRIPTS_DIR/lib/gaia-paths.sh"
  RESOLVE_CONFIG="$SCRIPTS_DIR/resolve-config.sh"
}

teardown() {
  common_teardown
}

_write_min_config() {
  local dir="$1"
  mkdir -p "$dir/.gaia/config"
  cat > "$dir/.gaia/config/project-config.yaml" <<'YAML'
project:
  name: test-proj
  shape: greenfield
  type: web-application
project_root: .
project_path: .
memory_path: .gaia/memory
checkpoint_path: .gaia/memory/checkpoints
installed_path: original
framework_version: "0.0.0"
date: "2026-01-01"
test_artifacts: .gaia/artifacts/test-artifacts
planning_artifacts: .gaia/artifacts/planning-artifacts
implementation_artifacts: .gaia/artifacts/implementation-artifacts
creative_artifacts: .gaia/artifacts/creative-artifacts
YAML
}

# The env preamble that clears all resolution signals
_E='unset _GAIA_PATHS_LOADED CLAUDE_PROJECT_ROOT PROJECT_ROOT CLAUDE_SKILL_DIR GAIA_NO_PROJECT_WALKUP 2>/dev/null;'

# ---------------------------------------------------------------------------
# AC1: linked worktree resolves to project root, never main checkout
# ---------------------------------------------------------------------------

@test "linked worktree resolves to project root above it" {
  local fh="$TEST_TMP/home"; local root="$fh/proj"; local main="$root/product"
  mkdir -p "$root/.gaia/config" "$main/.gaia/state"
  printf 'project:\n  name: proj\n' > "$root/.gaia/config/project-config.yaml"
  git -C "$main" init -q 2>/dev/null
  git -C "$main" -c user.name=t -c user.email=t commit --allow-empty -m i -q 2>/dev/null
  local wt="$root/.gaia-worktrees/wt-s"
  git -C "$main" worktree add "$wt" -b wb -q 2>/dev/null
  mkdir -p "$wt/src/deep"
  local rc; rc="$(cd "$root" && pwd -P)"
  local mc; mc="$(cd "$main" && pwd -P)"
  local hc; hc="$(cd "$fh" && pwd -P)"

  run bash -c "export HOME='$hc'; $_E cd '$wt/src/deep' && . '$LIB' && printf '%s' \"\$_GAIA_ROOT_CANON\""
  [ "$status" -eq 0 ]; [ "$output" = "$rc" ]; [ "$output" != "$mc" ]
  git -C "$main" worktree remove "$wt" --force 2>/dev/null || true
}

# Kills M1: worktree nested INSIDE a config-bearing main checkout.
# The main checkout's config is added AFTER the worktree is created (untracked)
# so the worktree does not inherit it — matching the real layout where .gaia/
# is project-root state, not committed to the product repo.
@test "worktree inside config-bearing main checkout resolves to project root" {
  local fh="$TEST_TMP/home"; local root="$fh/proj"; local main="$root/product"
  mkdir -p "$root/.gaia/config" "$main"
  printf 'project:\n  name: proj\n' > "$root/.gaia/config/project-config.yaml"
  git -C "$main" init -q 2>/dev/null
  git -C "$main" -c user.name=t -c user.email=t commit --allow-empty -m i -q 2>/dev/null
  # Create worktree BEFORE adding .gaia/ to main checkout
  local wt="$main/.gaia-worktrees/wt-s"
  git -C "$main" worktree add "$wt" -b wb -q 2>/dev/null
  mkdir -p "$wt/src"
  # NOW add untracked .gaia/config to the main checkout (worktree won't have it)
  mkdir -p "$main/.gaia/config"
  printf 'project:\n  name: main\n' > "$main/.gaia/config/project-config.yaml"
  local rc; rc="$(cd "$root" && pwd -P)"
  local mc; mc="$(cd "$main" && pwd -P)"
  local hc; hc="$(cd "$fh" && pwd -P)"

  run bash -c "export HOME='$hc'; $_E cd '$wt/src' && . '$LIB' && printf '%s' \"\$_GAIA_ROOT_CANON\""
  [ "$status" -eq 0 ]; [ "$output" = "$rc" ]; [ "$output" != "$mc" ]
  git -C "$main" worktree remove "$wt" --force 2>/dev/null || true
}

# Kills M2: single repo with config at its root
@test "single repo resolves from src/deep to repo root" {
  local fh="$TEST_TMP/home"; local repo="$fh/repo"
  mkdir -p "$repo/.gaia/config" "$repo/src/deep"
  printf 'project:\n  name: r\n' > "$repo/.gaia/config/project-config.yaml"
  git -C "$repo" init -q 2>/dev/null
  git -C "$repo" -c user.name=t -c user.email=t commit --allow-empty -m i -q 2>/dev/null
  local rpc; rpc="$(cd "$repo" && pwd -P)"
  local hc; hc="$(cd "$fh" && pwd -P)"

  run bash -c "export HOME='$hc'; $_E cd '$repo/src/deep' && . '$LIB' && printf '%s' \"\$_GAIA_ROOT_CANON\""
  [ "$status" -eq 0 ]; [ "$output" = "$rpc" ]
}

@test "walk-up crosses regular git repo to find project root above it" {
  local fh="$TEST_TMP/home"; local proj="$fh/workspace"
  mkdir -p "$proj/.gaia/config"
  printf 'project:\n  name: proj\n' > "$proj/.gaia/config/project-config.yaml"
  local subrepo="$proj/product"
  mkdir -p "$subrepo/.gaia/state" "$subrepo/src"
  git -C "$subrepo" init -q 2>/dev/null
  git -C "$subrepo" -c user.name=t -c user.email=t commit --allow-empty -m i -q 2>/dev/null
  local pc; pc="$(cd "$proj" && pwd -P)"
  local hc; hc="$(cd "$fh" && pwd -P)"

  run bash -c "export HOME='$hc'; $_E cd '$subrepo/src' && . '$LIB' && printf '%s' \"\$_GAIA_ROOT_CANON\""
  [ "$status" -eq 0 ]; [ "$output" = "$pc" ]
}

# ---------------------------------------------------------------------------
# Outside HOME / HOME unset / HOME=/  (git-bounded walk-up)
# ---------------------------------------------------------------------------

@test "codespaces-style outside HOME resolves from subdir" {
  local fh="$TEST_TMP/home"; mkdir -p "$fh"
  local repo="$TEST_TMP/workspaces/repo"
  mkdir -p "$repo/.gaia/config" "$repo/src/deep"
  printf 'project:\n  name: r\n' > "$repo/.gaia/config/project-config.yaml"
  git -C "$repo" init -q 2>/dev/null
  git -C "$repo" -c user.name=t -c user.email=t commit --allow-empty -m i -q 2>/dev/null
  local rpc; rpc="$(cd "$repo" && pwd -P)"
  local hc; hc="$(cd "$fh" && pwd -P)"

  run bash -c "export HOME='$hc'; $_E cd '$repo/src/deep' && . '$LIB' && printf '%s' \"\$_GAIA_ROOT_CANON\""
  [ "$status" -eq 0 ]; [ "$output" = "$rpc" ]
}

@test "linked worktree outside HOME resolves to project root" {
  local fh="$TEST_TMP/home"; mkdir -p "$fh"
  local root="$TEST_TMP/root"; local main="$root/product"
  mkdir -p "$root/.gaia/config" "$main/.gaia/state"
  printf 'project:\n  name: r\n' > "$root/.gaia/config/project-config.yaml"
  git -C "$main" init -q 2>/dev/null
  git -C "$main" -c user.name=t -c user.email=t commit --allow-empty -m i -q 2>/dev/null
  local wt="$root/.gaia-worktrees/wt-s"
  git -C "$main" worktree add "$wt" -b wb -q 2>/dev/null
  mkdir -p "$wt/src"
  local rc; rc="$(cd "$root" && pwd -P)"
  local mc; mc="$(cd "$main" && pwd -P)"
  local hc; hc="$(cd "$fh" && pwd -P)"

  run bash -c "export HOME='$hc'; $_E cd '$wt/src' && . '$LIB' && printf '%s' \"\$_GAIA_ROOT_CANON\""
  [ "$status" -eq 0 ]; [ "$output" = "$rc" ]; [ "$output" != "$mc" ]
  git -C "$main" worktree remove "$wt" --force 2>/dev/null || true
}

@test "AC3 planted config above git repo is ignored outside HOME" {
  local fh="$TEST_TMP/home"; mkdir -p "$fh"
  local shared="$TEST_TMP/shared"; local proj="$shared/work/proj"
  mkdir -p "$shared/.gaia/config" "$proj/.gaia/config" "$proj/sub"
  printf 'project:\n  n: planted\n' > "$shared/.gaia/config/project-config.yaml"
  printf 'project:\n  n: real\n' > "$proj/.gaia/config/project-config.yaml"
  git -C "$proj" init -q 2>/dev/null
  git -C "$proj" -c user.name=t -c user.email=t commit --allow-empty -m i -q 2>/dev/null
  local pc; pc="$(cd "$proj" && pwd -P)"
  local sc; sc="$(cd "$shared" && pwd -P)"
  local hc; hc="$(cd "$fh" && pwd -P)"

  run bash -c "export HOME='$hc'; $_E cd '$proj/sub' && . '$LIB' && printf '%s' \"\$_GAIA_ROOT_CANON\""
  [ "$status" -eq 0 ]; [ "$output" = "$pc" ]; [ "$output" != "$sc" ]
}

@test "HOME unset with git repo resolves from subdir" {
  local repo="$TEST_TMP/proj"
  mkdir -p "$repo/.gaia/config" "$repo/sub"
  printf 'project:\n  n: r\n' > "$repo/.gaia/config/project-config.yaml"
  git -C "$repo" init -q 2>/dev/null
  git -C "$repo" -c user.name=t -c user.email=t commit --allow-empty -m i -q 2>/dev/null
  local rpc; rpc="$(cd "$repo" && pwd -P)"

  run bash -c "unset HOME; $_E cd '$repo/sub' && . '$LIB' && printf '%s' \"\$_GAIA_ROOT_CANON\""
  [ "$status" -eq 0 ]; [ "$output" = "$rpc" ]
}

@test "HOME=/ with git repo resolves from subdir" {
  local repo="$TEST_TMP/proj2"
  mkdir -p "$repo/.gaia/config" "$repo/sub"
  printf 'project:\n  n: r\n' > "$repo/.gaia/config/project-config.yaml"
  git -C "$repo" init -q 2>/dev/null
  git -C "$repo" -c user.name=t -c user.email=t commit --allow-empty -m i -q 2>/dev/null
  local rpc; rpc="$(cd "$repo" && pwd -P)"

  run bash -c "export HOME=/; $_E cd '$repo/sub' && . '$LIB' && printf '%s' \"\$_GAIA_ROOT_CANON\""
  [ "$status" -eq 0 ]; [ "$output" = "$rpc" ]
}

@test "HOME unset, no git: CWD fallback" {
  local deep="$TEST_TMP/deep/nested/dir"; mkdir -p "$deep"
  mkdir -p "$TEST_TMP/.gaia/config"
  printf 'project:\n  n: a\n' > "$TEST_TMP/.gaia/config/project-config.yaml"
  local dc; dc="$(cd "$deep" && pwd -P)"

  run bash -c "unset HOME; $_E cd '$deep' && . '$LIB' && printf '%s' \"\$_GAIA_ROOT_CANON\""
  [ "$status" -eq 0 ]; [ "$output" = "$dc" ]
}

# ---------------------------------------------------------------------------
# AC2: resolve-config discovers canonical .gaia/config/global.yaml
# ---------------------------------------------------------------------------

@test "resolve-config discovers global.yaml via CLAUDE_PROJECT_ROOT" {
  _write_min_config "$TEST_TMP/proj"
  printf 'installed_path: cpr-overlay\n' > "$TEST_TMP/proj/.gaia/config/global.yaml"
  local pc; pc="$(cd "$TEST_TMP/proj" && pwd -P)"
  run bash -c "export CLAUDE_PROJECT_ROOT='$pc' GAIA_NO_PROJECT_WALKUP=1; cd '$pc'; bash '$RESOLVE_CONFIG' --shared '$pc/.gaia/config/project-config.yaml' --format json"
  [ "$status" -eq 0 ]; [[ "$output" == *"cpr-overlay"* ]]
}

@test "resolve-config discovers global.yaml via PWD" {
  _write_min_config "$TEST_TMP/proj"
  printf 'installed_path: pwd-overlay\n' > "$TEST_TMP/proj/.gaia/config/global.yaml"
  local pc; pc="$(cd "$TEST_TMP/proj" && pwd -P)"
  run bash -c "unset CLAUDE_PROJECT_ROOT GAIA_LOCAL_CONFIG; export GAIA_NO_PROJECT_WALKUP=1; cd '$pc'; bash '$RESOLVE_CONFIG' --shared '$pc/.gaia/config/project-config.yaml' --format json"
  [ "$status" -eq 0 ]; [[ "$output" == *"pwd-overlay"* ]]
}

@test "resolve-config discovers global.yaml via walk-up" {
  _write_min_config "$TEST_TMP/proj"
  mkdir -p "$TEST_TMP/proj/sub/deep"
  printf 'installed_path: walkup-overlay\n' > "$TEST_TMP/proj/.gaia/config/global.yaml"
  local pc; pc="$(cd "$TEST_TMP/proj" && pwd -P)"
  local hc; hc="$(cd "$TEST_TMP" && pwd -P)"
  run bash -c "unset CLAUDE_PROJECT_ROOT GAIA_LOCAL_CONFIG; export HOME='$hc'; cd '$pc/sub/deep'; bash '$RESOLVE_CONFIG' --shared '$pc/.gaia/config/project-config.yaml' --format json"
  [ "$status" -eq 0 ]; [[ "$output" == *"walkup-overlay"* ]]
}

@test "resolve-config prefers canonical global.yaml over legacy" {
  _write_min_config "$TEST_TMP/proj"
  printf 'installed_path: canonical-wins\n' > "$TEST_TMP/proj/.gaia/config/global.yaml"
  mkdir -p "$TEST_TMP/proj/config"
  printf 'installed_path: legacy-loses\n' > "$TEST_TMP/proj/config/global.yaml"
  local pc; pc="$(cd "$TEST_TMP/proj" && pwd -P)"
  run bash -c "export CLAUDE_PROJECT_ROOT='$pc' GAIA_NO_PROJECT_WALKUP=1; cd '$pc'; bash '$RESOLVE_CONFIG' --shared '$pc/.gaia/config/project-config.yaml' --format json"
  [ "$status" -eq 0 ]; [[ "$output" == *"canonical-wins"* ]]; [[ "$output" != *"legacy-loses"* ]]
}

@test "resolve-config walk-up outside HOME uses git boundary" {
  _write_min_config "$TEST_TMP/repo"
  mkdir -p "$TEST_TMP/repo/sub" "$TEST_TMP/myhome"
  git -C "$TEST_TMP/repo" init -q 2>/dev/null
  git -C "$TEST_TMP/repo" -c user.name=t -c user.email=t commit --allow-empty -m i -q 2>/dev/null
  local hc; hc="$(cd "$TEST_TMP/myhome" && pwd -P)"
  run bash -c "unset CLAUDE_PROJECT_ROOT GAIA_SHARED_CONFIG CLAUDE_SKILL_DIR GAIA_NO_PROJECT_WALKUP; export HOME='$hc'; cd '$TEST_TMP/repo/sub'; bash '$RESOLVE_CONFIG'"
  [ "$status" -eq 0 ]
}

@test "resolve-config walk-up does not fire outside HOME without git" {
  _write_min_config "$TEST_TMP/shared"
  mkdir -p "$TEST_TMP/shared/sub" "$TEST_TMP/myhome"
  local hc; hc="$(cd "$TEST_TMP/myhome" && pwd -P)"
  run bash -c "unset CLAUDE_PROJECT_ROOT GAIA_SHARED_CONFIG CLAUDE_SKILL_DIR GAIA_NO_PROJECT_WALKUP; export HOME='$hc'; cd '$TEST_TMP/shared/sub'; bash '$RESOLVE_CONFIG' 2>&1; echo rc=\$?"
  [[ "$output" == *"no config path"* ]] || [[ "$output" == *"rc=2"* ]]
}

# Kills R1/R9/R10: resolve-config walk-up excludes the main checkout in a linked worktree
# Kills R1/R9: resolve-config excludes the main checkout in a linked worktree.
# The worktree is INSIDE the main checkout tree so the exclusion is exercised.
@test "resolve-config excludes main checkout in linked worktree walk-up" {
  local fh="$TEST_TMP/home"; local root="$fh/proj"; local main="$root/product"
  _write_min_config "$root"
  mkdir -p "$main"
  git -C "$main" init -q 2>/dev/null
  git -C "$main" -c user.name=t -c user.email=t commit --allow-empty -m i -q 2>/dev/null
  # Worktree INSIDE the main checkout tree
  local wt="$main/.gaia-worktrees/wt-s"
  git -C "$main" worktree add "$wt" -b wb -q 2>/dev/null
  mkdir -p "$wt/sub"
  # Add untracked config to main checkout AFTER worktree creation.
  # Use _write_min_config then overwrite the value portably (no sed -i).
  _write_min_config "$main"
  local tmp_cfg; tmp_cfg="$main/.gaia/config/.tmp-cfg"
  sed 's/installed_path: original/installed_path: main-install/' "$main/.gaia/config/project-config.yaml" > "$tmp_cfg"
  mv "$tmp_cfg" "$main/.gaia/config/project-config.yaml"
  local hc; hc="$(cd "$fh" && pwd -P)"
  run bash -c "unset CLAUDE_PROJECT_ROOT GAIA_SHARED_CONFIG CLAUDE_SKILL_DIR GAIA_NO_PROJECT_WALKUP; export HOME='$hc'; cd '$wt/sub'; bash '$RESOLVE_CONFIG'"
  [ "$status" -eq 0 ]
  # Must find the root's config (installed_path='original'), not the main checkout's
  [[ "$output" == *"installed_path='original'"* ]]
  [[ "$output" != *"main-install"* ]]
  git -C "$main" worktree remove "$wt" --force 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# AC3: walk-up bounded, planted config ignored
# ---------------------------------------------------------------------------

@test "walk-up stops at HOME boundary when CWD is outside HOME (no git)" {
  local myhome="$TEST_TMP/myhome"; mkdir -p "$myhome"
  local mc; mc="$(cd "$myhome" && pwd -P)"
  local shared="$TEST_TMP/shared"
  mkdir -p "$shared/work/proj/sub" "$shared/.gaia/config"
  printf 'project:\n  n: a\n' > "$shared/.gaia/config/project-config.yaml"
  local sc; sc="$(cd "$shared" && pwd -P)"
  local dc; dc="$(cd "$shared/work/proj/sub" && pwd -P)"

  run bash -c "export HOME='$mc'; $_E cd '$shared/work/proj/sub' && . '$LIB' && printf '%s' \"\$_GAIA_ROOT_CANON\""
  [ "$status" -eq 0 ]; [ "$output" != "$sc" ]; [ "$output" = "$dc" ]
}

@test "walk-up works with symlinked HOME" {
  local real_home="$TEST_TMP/realhome"
  mkdir -p "$real_home/proj/.gaia/config" "$real_home/proj/sub"
  printf 'project:\n  n: r\n' > "$real_home/proj/.gaia/config/project-config.yaml"
  ln -s "$real_home" "$TEST_TMP/linkhome"
  local pc; pc="$(cd "$real_home/proj" && pwd -P)"

  run bash -c "export HOME='$TEST_TMP/linkhome'; $_E cd '$TEST_TMP/linkhome/proj/sub' && . '$LIB' && printf '%s' \"\$_GAIA_ROOT_CANON\""
  [ "$status" -eq 0 ]; [ "$output" = "$pc" ]
}

# ---------------------------------------------------------------------------
# AC6: no internal traceability identifiers
# ---------------------------------------------------------------------------

@test "no internal identifiers in changed published files" {
  local files_to_scan=(
    "$SCRIPTS_DIR/lib/gaia-paths.sh"
    "$SCRIPTS_DIR/resolve-config.sh"
    "${BATS_TEST_FILENAME}"
  )
  local count=0
  for f in "${files_to_scan[@]}"; do
    [ -f "$f" ] || continue
    while IFS= read -r line; do
      count=$((count + 1))
      printf '  LEAK: %s: %s\n' "$(basename "$f")" "$line" >&2
    done < <(/usr/bin/grep -nE '(FR-[0-9]+|NFR-[0-9]+|SR-[0-9]+|ADR-[0-9]+|E[0-9]+-S[0-9]+|TC-[A-Z]+-[0-9]+|TC-[A-Z]+-[A-Z]+-[0-9]+|AF-[0-9]{4}-[0-9]{2}-[0-9]{2})' "$f" 2>/dev/null || true)
  done
  [ "$count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC7: test fixtures use temp dirs
# ---------------------------------------------------------------------------

@test "test fixtures use temp dirs, not real plugin tree" {
  local self="${BATS_TEST_FILENAME}"; [ -f "$self" ]
  local pw; pw="$(/usr/bin/grep -cE '(>|>>)\s*/[^ ]*plugins/gaia/' "$self" 2>/dev/null || true)"
  [ "${pw:-0}" -eq 0 ]
}
