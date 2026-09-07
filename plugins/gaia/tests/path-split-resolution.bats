#!/usr/bin/env bats
# path-split-resolution.bats — behavioural tests for the state/code path
# split contract. Every .gaia/ state access must resolve through the
# canonical PROJECT_ROOT chain; PROJECT_PATH names only the code tree.
#
# Tests run REAL scripts against scratch state + worktree directories and
# assert on FILESYSTEM state. Static greps are supplementary only.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

# Seed a realistic .gaia/ state tree with all the structures the chain needs.
_seed_state_tree() {
  local root="$1"
  mkdir -p "$root/.gaia/state"
  mkdir -p "$root/.gaia/memory/checkpoints"
  mkdir -p "$root/.gaia/memory/bash-dev-sidecar"
  mkdir -p "$root/.gaia/artifacts/implementation-artifacts/epic-E9-x/E9-S1-x"
  mkdir -p "$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$root/.gaia/config"

  # project-config.yaml
  cat > "$root/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
project_path: "."
YAML

  # story file with valid frontmatter (status ready-for-dev for chain test)
  cat > "$root/.gaia/artifacts/implementation-artifacts/epic-E9-x/E9-S1-x/story.md" <<'STORY'
---
template: 'story'
key: "E9-S1"
title: "Test story"
status: ready-for-dev
sprint_id: "sprint-test"
epic: "E9"
stack: "bash-dev"
priority: "P1"
size: "S"
points: 2
risk: "low"
date: "2026-01-01"
author: "Test"
delivered: false
---
# Story: Test story

## Review Gate
| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | - |
| QA Tests | UNVERIFIED | - |
| Security Review | UNVERIFIED | - |
| Test Automation | UNVERIFIED | - |
| Test Review | UNVERIFIED | - |
| Performance Review | UNVERIFIED | - |
STORY

  # sprint-status.yaml
  cat > "$root/.gaia/state/sprint-status.yaml" <<'YAML'
sprint_id: sprint-test
status: active
stories:
  E9-S1:
    status: ready-for-dev
    points: 2
YAML

  # epics-and-stories.md
  cat > "$root/.gaia/artifacts/planning-artifacts/epics-and-stories.md" <<'EPIC'
# Epics and Stories

## Epic 9: Test Epic

### Stories

- **E9-S1** — Test story
  - **Status:** ready-for-dev
  - **Priority:** P1
  - **Size:** S (2 pts)
EPIC

  # sidecar memory for AC2 reader tests
  cat > "$root/.gaia/memory/bash-dev-sidecar/ground-truth.md" <<'MEM'
# Ground Truth — bash-dev
This is test sidecar content for path-split verification.
MEM
}

setup() {
  common_setup
  STATE_TREE="$TEST_TMP/state-tree"
  WORKTREE="$TEST_TMP/worktree"
  _seed_state_tree "$STATE_TREE"
  mkdir -p "$WORKTREE"
  # Initialise WORKTREE as a git repo so scripts that check git context
  # do not fall back to the real repo's working tree.
  git init -q "$WORKTREE" 2>/dev/null || true

  # Seed a DECOY story under the worktree so resolve-story-file.sh tests
  # can verify which tree the resolution came from. The decoy has a distinct
  # title ("DECOY worktree story") vs the real one ("Test story").
  local wt_story_dir="$WORKTREE/.gaia/artifacts/implementation-artifacts/epic-E9-x/E9-S1-x"
  mkdir -p "$wt_story_dir"
  cat > "$wt_story_dir/story.md" <<'DECOY'
---
template: 'story'
key: "E9-S1"
title: "DECOY worktree story"
status: ready-for-dev
sprint_id: "sprint-test"
epic: "E9"
stack: "bash-dev"
priority: "P1"
size: "S"
points: 2
risk: "low"
date: "2026-01-01"
author: "Test"
delivered: false
---
# Story: DECOY worktree story

## Review Gate
| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | - |
| QA Tests | UNVERIFIED | - |
| Security Review | UNVERIFIED | - |
| Test Automation | UNVERIFIED | - |
| Test Review | UNVERIFIED | - |
| Performance Review | UNVERIFIED | - |
DECOY
}

teardown() { common_teardown; }

# ================================================================
# AC3 CHAIN: end-to-end resolve -> transition -> review-gate -> checkpoint
# All four steps run in sequence from CWD=$WORKTREE with
# PROJECT_ROOT=$STATE_TREE / PROJECT_PATH=$WORKTREE.
#
# Step 1 (resolve) does NOT export IMPLEMENTATION_ARTIFACTS — it must
# resolve through PROJECT_ROOT, not an env override that masks the
# CWD-relative default. Steps 2-4 export input-side overrides
# (IMPLEMENTATION_ARTIFACTS, PLANNING_ARTIFACTS, SPRINT_STATUS_YAML)
# so they can find their source files. State-OUTPUT paths
# (MEMORY_PATH, ledger) are NEVER overridden.
# ================================================================

@test "story chain: all four steps land state under PROJECT_ROOT, nothing under worktree (AC3)" {
  export PROJECT_ROOT="$STATE_TREE"
  export PROJECT_PATH="$WORKTREE"
  export CLAUDE_PROJECT_ROOT=""
  export REVIEW_GATE_PROOF_OF_EXECUTION=off
  # Do NOT export IMPLEMENTATION_ARTIFACTS, MEMORY_PATH, or REVIEW_GATE_LEDGER.

  # Step 1: resolve-story-file.sh — no IMPLEMENTATION_ARTIFACTS override.
  # A decoy story is seeded under $WORKTREE by setup(). The script must
  # resolve through PROJECT_ROOT to find the STATE_TREE copy, not the decoy.
  run bash -c 'cd "$1" && bash "$2" E9-S1' \
    _ "$WORKTREE" "$PLUGIN_ROOT/scripts/resolve-story-file.sh"
  [ "$status" -eq 0 ] || {
    printf 'FAIL(resolve): exit=%d output=%s\n' "$status" "$output" >&2
    return 1
  }
  # stdout must be an absolute path under STATE_TREE, not the worktree decoy.
  case "$output" in
    "$STATE_TREE"*) : ;;
    *) printf 'FAIL(resolve): resolved path not under STATE_TREE: %s\n' "$output" >&2; return 1 ;;
  esac

  # Steps 2-4 need input-side overrides to find source files.
  export IMPLEMENTATION_ARTIFACTS="$STATE_TREE/.gaia/artifacts/implementation-artifacts"
  export PLANNING_ARTIFACTS="$STATE_TREE/.gaia/artifacts/planning-artifacts"
  export SPRINT_STATUS_YAML="$STATE_TREE/.gaia/state/sprint-status.yaml"

  # Step 2: transition-story-status.sh (ready-for-dev -> in-progress)
  run bash -c 'cd "$1" && bash "$2" E9-S1 --to in-progress' \
    _ "$WORKTREE" "$PLUGIN_ROOT/scripts/transition-story-status.sh"
  [ "$status" -eq 0 ] || {
    printf 'FAIL(transition): exit=%d output=%s\n' "$status" "$output" >&2
    return 1
  }
  # Story file under STATE_TREE must now say in-progress
  local story="$STATE_TREE/.gaia/artifacts/implementation-artifacts/epic-E9-x/E9-S1-x/story.md"
  grep -q 'status: in-progress' "$story" || {
    printf 'FAIL(transition): story status not updated. Content:\n%s\n' "$(head -20 "$story")" >&2
    return 1
  }
  # Lock file must be under STATE_TREE (not worktree)
  [ -f "$STATE_TREE/.gaia/memory/.story-status.lock" ] || {
    printf 'FAIL(transition): lock file not under STATE_TREE/.gaia/memory/\n' >&2
    # Show where it actually went
    local wt_lock
    wt_lock=$(find "$WORKTREE" -name '.story-status.lock' 2>/dev/null || true)
    [ -z "$wt_lock" ] || printf '  lock leaked to worktree: %s\n' "$wt_lock" >&2
    return 1
  }

  # Step 3: review-gate.sh update (writes ledger via --plan-id)
  run bash -c 'cd "$1" && bash "$2" update --story E9-S1 --gate "Code Review" --verdict PASSED --plan-id chain-test' \
    _ "$WORKTREE" "$PLUGIN_ROOT/scripts/review-gate.sh"
  [ "$status" -eq 0 ] || {
    printf 'FAIL(review-gate): exit=%d output=%s\n' "$status" "$output" >&2
    return 1
  }
  # Ledger must exist under STATE_TREE
  [ -f "$STATE_TREE/.gaia/state/.review-gate-ledger" ] || {
    printf 'FAIL(review-gate): ledger not under STATE_TREE/.gaia/state/\n' >&2
    return 1
  }

  # Step 4: write-checkpoint.sh
  run bash -c 'cd "$1" && bash "$2" chain-skill 1 key=val' \
    _ "$WORKTREE" "$PLUGIN_ROOT/scripts/write-checkpoint.sh"
  [ "$status" -eq 0 ] || {
    printf 'FAIL(checkpoint): exit=%d output=%s\n' "$status" "$output" >&2
    return 1
  }
  local ckpt_dir="$STATE_TREE/.gaia/memory/checkpoints/chain-skill"
  [ -d "$ckpt_dir" ] || {
    printf 'FAIL(checkpoint): dir not under STATE_TREE: %s\noutput: %s\n' "$ckpt_dir" "$output" >&2
    return 1
  }

  # NEGATIVE: no script-created state artifacts under WORKTREE.
  # (The decoy story .gaia/artifacts/ is pre-seeded by setup and excluded.)
  local wt_state
  wt_state=$(find "$WORKTREE/.gaia" -path '*/memory/*' -o -path '*/state/*' -o -name '.story-status.lock' 2>/dev/null | head -1 || true)
  [ -z "$wt_state" ] || {
    printf 'FAIL: state artifact leaked into worktree: %s\n' "$wt_state" >&2
    return 1
  }
}

# ================================================================
# Per-script behavioural tests (AC3 — individual step coverage)
# ================================================================

@test "write-checkpoint.sh creates checkpoint under PROJECT_ROOT, not worktree (AC3)" {
  export PROJECT_ROOT="$STATE_TREE"
  export PROJECT_PATH="$WORKTREE"
  unset CLAUDE_PROJECT_ROOT

  run bash -c 'cd "$1" && bash "$2" test-skill 1 key=value' \
    _ "$WORKTREE" "$PLUGIN_ROOT/scripts/write-checkpoint.sh"

  local ckpt_dir="$STATE_TREE/.gaia/memory/checkpoints/test-skill"
  [ -d "$ckpt_dir" ] || {
    printf 'FAIL: checkpoint dir not created under STATE_TREE: %s\nscript output: %s\n' "$ckpt_dir" "$output" >&2
    return 1
  }
  local ckpt_files
  ckpt_files=$(find "$ckpt_dir" -name '*.json' 2>/dev/null || true)
  [ -n "$ckpt_files" ] || {
    printf 'FAIL: no checkpoint JSON under %s\nscript output: %s\n' "$ckpt_dir" "$output" >&2
    return 1
  }

  # No script-created state artifacts under worktree (decoy story is pre-seeded).
  local wt_state
  wt_state=$(find "$WORKTREE/.gaia" -path '*/memory/*' -o -path '*/state/*' 2>/dev/null | head -1 || true)
  [ -z "$wt_state" ] || {
    printf 'FAIL: state artifact leaked into worktree: %s\n' "$wt_state" >&2
    return 1
  }
}

@test "resolve-story-file.sh resolves path under PROJECT_ROOT, not worktree decoy (AC3)" {
  export PROJECT_ROOT="$STATE_TREE"
  export PROJECT_PATH="$WORKTREE"
  unset CLAUDE_PROJECT_ROOT
  unset IMPLEMENTATION_ARTIFACTS
  # Do NOT export IMPLEMENTATION_ARTIFACTS — the script must resolve
  # through PROJECT_ROOT, not an env override. A decoy story with a
  # distinct title is seeded under $WORKTREE by setup().

  run bash -c 'cd "$1" && bash "$2" E9-S1' \
    _ "$WORKTREE" "$PLUGIN_ROOT/scripts/resolve-story-file.sh"

  [ "$status" -eq 0 ] || {
    printf 'FAIL: resolve-story-file exit=%d output=%s\n' "$status" "$output" >&2
    return 1
  }
  # Resolved path must be absolute and under STATE_TREE.
  case "$output" in
    "$STATE_TREE"*)
      : ;;
    *)
      printf 'FAIL: resolved path not under STATE_TREE: %s\n' "$output" >&2
      return 1
      ;;
  esac
  # Must NOT be the worktree decoy.
  case "$output" in
    "$WORKTREE"*)
      printf 'FAIL: resolved to worktree decoy: %s\n' "$output" >&2
      return 1
      ;;
  esac
}

@test "transition-story-status.sh lock and state land under PROJECT_ROOT (AC3)" {
  export PROJECT_ROOT="$STATE_TREE"
  export PROJECT_PATH="$WORKTREE"
  export CLAUDE_PROJECT_ROOT=""
  export IMPLEMENTATION_ARTIFACTS="$STATE_TREE/.gaia/artifacts/implementation-artifacts"
  export PLANNING_ARTIFACTS="$STATE_TREE/.gaia/artifacts/planning-artifacts"
  export SPRINT_STATUS_YAML="$STATE_TREE/.gaia/state/sprint-status.yaml"
  # Do NOT export MEMORY_PATH — let the script resolve it.

  run bash -c 'cd "$1" && bash "$2" E9-S1 --to in-progress' \
    _ "$WORKTREE" "$PLUGIN_ROOT/scripts/transition-story-status.sh"

  [ "$status" -eq 0 ] || {
    printf 'FAIL: transition exit=%d output=%s\n' "$status" "$output" >&2
    return 1
  }
  # Lock file under STATE_TREE (proves MEMORY_PATH resolved via PROJECT_ROOT)
  [ -f "$STATE_TREE/.gaia/memory/.story-status.lock" ] || {
    printf 'FAIL: lock file not under STATE_TREE\n' >&2
    local wt_lock
    wt_lock=$(find "$WORKTREE" -name '.story-status.lock' 2>/dev/null || true)
    [ -z "$wt_lock" ] || printf '  lock leaked to worktree: %s\n' "$wt_lock" >&2
    return 1
  }
  # No script-created state artifacts under worktree (decoy story is pre-seeded).
  local wt_state
  wt_state=$(find "$WORKTREE/.gaia" -path '*/memory/*' -o -path '*/state/*' 2>/dev/null | head -1 || true)
  [ -z "$wt_state" ] || {
    printf 'FAIL: state artifact leaked into worktree: %s\n' "$wt_state" >&2
    return 1
  }
}

@test "review-gate.sh ledger materialises under PROJECT_ROOT, not worktree (AC3)" {
  export PROJECT_ROOT="$STATE_TREE"
  export PROJECT_PATH="$WORKTREE"
  export CLAUDE_PROJECT_ROOT=""
  export IMPLEMENTATION_ARTIFACTS="$STATE_TREE/.gaia/artifacts/implementation-artifacts"
  export REVIEW_GATE_PROOF_OF_EXECUTION=off
  # Do NOT export REVIEW_GATE_LEDGER — let the script resolve its own path.

  run bash -c 'cd "$1" && bash "$2" update --story E9-S1 --gate "Code Review" --verdict PASSED --plan-id ledger-test' \
    _ "$WORKTREE" "$PLUGIN_ROOT/scripts/review-gate.sh"

  [ "$status" -eq 0 ] || {
    printf 'FAIL: review-gate exit=%d output=%s\n' "$status" "$output" >&2
    return 1
  }
  [ -f "$STATE_TREE/.gaia/state/.review-gate-ledger" ] || {
    printf 'FAIL: ledger not under STATE_TREE/.gaia/state/\noutput: %s\n' "$output" >&2
    return 1
  }
  # Worktree must be clean
  local wt_ledger
  wt_ledger=$(find "$WORKTREE" -path '*/.gaia/state/*' -o -name '.review-gate-ledger' 2>/dev/null || true)
  [ -z "$wt_ledger" ]
}

# ================================================================
# Hostile-input matrix over real write-checkpoint.sh (AC3)
# ================================================================

@test "PROJECT_ROOT with embedded space: checkpoint lands at spaced path (AC3)" {
  local spaced="$TEST_TMP/my state tree"
  _seed_state_tree "$spaced"
  export PROJECT_ROOT="$spaced"
  export PROJECT_PATH="$WORKTREE"
  unset CLAUDE_PROJECT_ROOT

  run bash -c 'cd "$1" && bash "$2" space-test 1 key=val' \
    _ "$WORKTREE" "$PLUGIN_ROOT/scripts/write-checkpoint.sh"

  local ckpt_dir="$spaced/.gaia/memory/checkpoints/space-test"
  [ -d "$ckpt_dir" ] || {
    printf 'FAIL: checkpoint not at spaced path: %s\noutput: %s\n' "$ckpt_dir" "$output" >&2
    return 1
  }
}

@test "empty PROJECT_ROOT falls through to CLAUDE_PROJECT_ROOT: checkpoint under fallback (AC3)" {
  export PROJECT_ROOT=""
  export CLAUDE_PROJECT_ROOT="$STATE_TREE"
  export PROJECT_PATH="$WORKTREE"

  run bash -c 'cd "$1" && bash "$2" fallback-test 1 key=val' \
    _ "$WORKTREE" "$PLUGIN_ROOT/scripts/write-checkpoint.sh"

  local ckpt_dir="$STATE_TREE/.gaia/memory/checkpoints/fallback-test"
  [ -d "$ckpt_dir" ] || {
    printf 'FAIL: checkpoint not under CLAUDE_PROJECT_ROOT fallback: %s\noutput: %s\n' "$ckpt_dir" "$output" >&2
    return 1
  }
}

@test "trailing slash on PROJECT_ROOT: checkpoint at normalised path, no double-slash dirs (AC3)" {
  export PROJECT_ROOT="$STATE_TREE/"
  export PROJECT_PATH="$WORKTREE"
  unset CLAUDE_PROJECT_ROOT

  run bash -c 'cd "$1" && bash "$2" trailing-test 1 key=val' \
    _ "$WORKTREE" "$PLUGIN_ROOT/scripts/write-checkpoint.sh"

  # Checkpoint must be reachable at the normalised path
  local ckpt_dir="$STATE_TREE/.gaia/memory/checkpoints/trailing-test"
  [ -d "$ckpt_dir" ] || {
    printf 'FAIL: checkpoint not at normalised path: %s\noutput: %s\n' "$ckpt_dir" "$output" >&2
    return 1
  }
  # The script's emitted output path must not contain a doubled separator.
  # (POSIX collapses '//' on directory creation, so the filesystem check
  # is a tautology — the defect only surfaces in emitted path strings.)
  case "$output" in
    *//*) printf 'FAIL: script output contains doubled separator: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "relative PROJECT_ROOT: checkpoint relative to CWD (AC3)" {
  local rel_root="$TEST_TMP/rel-state"
  _seed_state_tree "$rel_root"
  export PROJECT_ROOT="rel-state"
  export PROJECT_PATH="$WORKTREE"
  unset CLAUDE_PROJECT_ROOT

  run bash -c 'cd "$1" && bash "$2" relpath-test 1 key=val' \
    _ "$TEST_TMP" "$PLUGIN_ROOT/scripts/write-checkpoint.sh"

  local ckpt_dir="$rel_root/.gaia/memory/checkpoints/relpath-test"
  [ -d "$ckpt_dir" ] || {
    printf 'FAIL: checkpoint not at relative-resolved path: %s\noutput: %s\n' "$ckpt_dir" "$output" >&2
    return 1
  }
}

@test "non-existent PROJECT_ROOT: script creates .gaia/ under it (AC3)" {
  local nexist="$TEST_TMP/does-not-exist-yet"
  export PROJECT_ROOT="$nexist"
  export PROJECT_PATH="$WORKTREE"
  unset CLAUDE_PROJECT_ROOT

  run bash -c 'cd "$1" && bash "$2" nexist-test 1 key=val' \
    _ "$WORKTREE" "$PLUGIN_ROOT/scripts/write-checkpoint.sh"

  local ckpt_dir="$nexist/.gaia/memory/checkpoints/nexist-test"
  [ -d "$ckpt_dir" ] || {
    printf 'FAIL: checkpoint not created under non-existent root: %s\noutput: %s\n' "$ckpt_dir" "$output" >&2
    return 1
  }
}

# ================================================================
# AC-EC4: symlink escape must be detectable
# Place real_dir OUTSIDE link_root so physical and logical paths diverge.
# ================================================================

@test "symlinked .gaia/: checkpoint at logical path, target outside link_root, no physical escape (AC-EC4)" {
  local real_dir="$TEST_TMP/outside/real-gaia-state"
  local link_root="$TEST_TMP/link-root"
  mkdir -p "$real_dir/memory/checkpoints" "$real_dir/state" "$real_dir/config"
  mkdir -p "$link_root"
  ln -s "$real_dir" "$link_root/.gaia"

  cat > "$link_root/.gaia/config/project-config.yaml" <<'YAML'
project_name: symlink-test
YAML

  export PROJECT_ROOT="$link_root"
  export PROJECT_PATH="$WORKTREE"
  unset CLAUDE_PROJECT_ROOT

  run bash -c 'cd "$1" && bash "$2" symlink-test 1 key=val' \
    _ "$WORKTREE" "$PLUGIN_ROOT/scripts/write-checkpoint.sh"

  # POSITIVE: checkpoint reachable at the logical path under link_root.
  [ -d "$link_root/.gaia/memory/checkpoints/symlink-test" ] || {
    printf 'FAIL: checkpoint not at logical path: %s/.gaia/memory/checkpoints/symlink-test\noutput: %s\n' "$link_root" "$output" >&2
    return 1
  }
  # PHYSICAL: the data also exists at the real target (proves the write happened).
  [ -d "$real_dir/memory/checkpoints/symlink-test" ] || {
    printf 'FAIL: checkpoint not at physical location: %s/memory/checkpoints/symlink-test\n' "$real_dir" >&2
    return 1
  }
  # CONTAINMENT: no stray path written under siblings of real_dir.
  local decoy
  decoy=$(find "$TEST_TMP/outside" -maxdepth 1 -not -name 'real-gaia-state' -not -name 'outside' -type d 2>/dev/null || true)
  [ -z "$decoy" ] || {
    printf 'FAIL: stray directory written alongside real_dir: %s\n' "$decoy" >&2
    return 1
  }
  # If the script emitted a path, assert it is prefixed by link_root, not real_dir.
  if [ -n "$output" ]; then
    local escaped
    escaped=$(printf '%s\n' "$output" | grep -F "$real_dir" | grep -vF "$link_root" || true)
    [ -z "$escaped" ] || {
      printf 'FAIL: script output references physical path outside link_root: %s\n' "$escaped" >&2
      return 1
    }
  fi
}

# ================================================================
# AC-EC3: byte-identity — subdirectory CWD with all vars unset
# Both baseline (git HEAD) and working-tree script must produce the
# checkpoint at the same CWD-relative directory path.
# ================================================================

@test "from subdirectory with all vars unset, script behaviour is byte-identical to baseline (AC-EC3)" {
  local baseline="$TEST_TMP/baseline.sh"
  # Try both possible git-relative paths for the script.
  git -C "$PLUGIN_ROOT" show HEAD:plugins/gaia/scripts/write-checkpoint.sh > "$baseline" 2>/dev/null || {
    git -C "$PLUGIN_ROOT" show HEAD:scripts/write-checkpoint.sh > "$baseline" 2>/dev/null || {
      skip 'cannot extract baseline write-checkpoint.sh from git'
    }
  }

  local scratch_baseline="$TEST_TMP/scratch-baseline"
  local scratch_working="$TEST_TMP/scratch-working"
  mkdir -p "$scratch_baseline/sub" "$scratch_working/sub"

  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT PROJECT_PATH

  # Run baseline from sub/ using a common skill name.
  run bash -c 'cd "$1/sub" && bash "$2" identity-test 1 key=val 2>&1' \
    _ "$scratch_baseline" "$baseline"

  # Run working-tree version from sub/ with the same skill name.
  run bash -c 'cd "$1/sub" && bash "$2" identity-test 1 key=val 2>&1' \
    _ "$scratch_working" "$PLUGIN_ROOT/scripts/write-checkpoint.sh"

  # Exclusive positive assertion: checkpoint MUST be under sub/.
  [ -d "$scratch_working/sub/.gaia/memory/checkpoints/identity-test" ] || {
    printf 'FAIL: checkpoint not under CWD/sub/ (working tree). Found:\n' >&2
    find "$scratch_working" -name 'identity-test' -type d >&2 || true
    return 1
  }
  # Negative: checkpoint must NOT be at the parent level.
  [ ! -d "$scratch_working/.gaia/memory/checkpoints/identity-test" ] || {
    printf 'FAIL: checkpoint escaped to parent directory (working tree)\n' >&2
    return 1
  }

  # Byte-identity: the DIRECTORY structure must match (ignore JSON filenames
  # which contain per-run timestamps). Compare the path from CWD to the
  # checkpoint directory.
  local baseline_dir working_dir
  baseline_dir=$(find "$scratch_baseline/sub" -type d -name 'identity-test' \
    | sed "s|^$scratch_baseline/sub/||" || true)
  working_dir=$(find "$scratch_working/sub" -type d -name 'identity-test' \
    | sed "s|^$scratch_working/sub/||" || true)

  [ "$baseline_dir" = "$working_dir" ] || {
    printf 'FAIL: .gaia/ directory paths differ from baseline\nbaseline: %s\nworking:  %s\n' \
      "$baseline_dir" "$working_dir" >&2
    return 1
  }
}

# ================================================================
# AC-EC5: mixed script — state via PROJECT_ROOT, code tree via PROJECT_PATH
# review-gate.sh reads story from IMPLEMENTATION_ARTIFACTS (code side)
# and writes ledger to .gaia/state/ (state side).
# ================================================================

@test "review-gate.sh reads code tree via PROJECT_PATH and writes state via PROJECT_ROOT (AC-EC5)" {
  export PROJECT_ROOT="$STATE_TREE"
  export PROJECT_PATH="$WORKTREE"
  export CLAUDE_PROJECT_ROOT=""
  export REVIEW_GATE_PROOF_OF_EXECUTION=off

  # Remove the STATE_TREE story copy so the WORKTREE decoy (seeded by
  # setup) is the ONLY resolvable story. A run that exits 0 proves the
  # read came from the code tree (PROJECT_PATH / WORKTREE), not the
  # state tree.
  rm -rf "$STATE_TREE/.gaia/artifacts/implementation-artifacts/epic-E9-x"

  # Point IMPLEMENTATION_ARTIFACTS at the WORKTREE (code-tree side).
  export IMPLEMENTATION_ARTIFACTS="$WORKTREE/.gaia/artifacts/implementation-artifacts"

  run bash -c 'cd "$1" && bash "$2" update --story E9-S1 --gate "Code Review" --verdict PASSED --plan-id split-test' \
    _ "$WORKTREE" "$PLUGIN_ROOT/scripts/review-gate.sh"

  [ "$status" -eq 0 ] || {
    printf 'FAIL: review-gate exit=%d output=%s\n' "$status" "$output" >&2
    return 1
  }
  # STATE side: ledger must be under STATE_TREE (resolved via PROJECT_ROOT).
  [ -f "$STATE_TREE/.gaia/state/.review-gate-ledger" ] || {
    printf 'FAIL: ledger not under STATE_TREE (state side not split)\n' >&2
    return 1
  }
  # CODE side negative: no ledger under the worktree.
  local wt_ledger
  wt_ledger=$(find "$WORKTREE" -name '.review-gate-ledger' 2>/dev/null || true)
  [ -z "$wt_ledger" ] || {
    printf 'FAIL: ledger leaked to worktree (state side not separated): %s\n' "$wt_ledger" >&2
    return 1
  }
}

# ================================================================
# Caller preservation at recompute sites (AC-EC1)
# ================================================================

@test "tdd-review-gate.sh chain starts with PROJECT_ROOT preservation (AC-EC1)" {
  local tdd_gate="$PLUGIN_ROOT/skills/gaia-dev-story/scripts/tdd-review-gate.sh"
  run grep -cF '${PROJECT_ROOT:-' "$tdd_gate"
  [ "$status" -eq 0 ] || {
    printf 'FAIL: tdd-review-gate.sh missing ${PROJECT_ROOT:- chain\n' >&2
    return 1
  }
  [ "$output" -gt 0 ]
}

@test "gaia-publish.sh chain starts with PROJECT_ROOT preservation (AC-EC1)" {
  local gaia_pub="$PLUGIN_ROOT/skills/gaia-publish/scripts/gaia-publish.sh"
  run grep -cF '${PROJECT_ROOT:-' "$gaia_pub"
  [ "$status" -eq 0 ] || {
    printf 'FAIL: gaia-publish.sh missing ${PROJECT_ROOT:- chain\n' >&2
    return 1
  }
  [ "$output" -gt 0 ]
}

@test "write-val-envelope.sh has no bare .gaia/ checkpoint path (AC-EC1)" {
  local envelope="$PLUGIN_ROOT/scripts/lib/write-val-envelope.sh"
  local bare_gaia
  bare_gaia=$(grep -v '^\s*#' "$envelope" \
    | grep 'CHECKPOINT_DIR=.*\.gaia' \
    | grep -v 'PROJECT_ROOT' || true)
  [ -z "$bare_gaia" ] || {
    printf 'FAIL: write-val-envelope.sh has bare .gaia/ checkpoint path: %s\n' "$bare_gaia" >&2
    return 1
  }
}

# ================================================================
# Chain collapse (AC4)
# ================================================================

@test "chain collapses to PROJECT_PATH when PROJECT_ROOT and CLAUDE_PROJECT_ROOT unset (AC4)" {
  local transition="$PLUGIN_ROOT/scripts/transition-story-status.sh"
  run grep -cF 'PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH' "$transition"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "write-checkpoint.sh resolves via chain, not bare .gaia/ (AC4)" {
  local ckpt="$PLUGIN_ROOT/scripts/write-checkpoint.sh"
  run grep -cF '${PROJECT_ROOT' "$ckpt"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

# ================================================================
# AC2 readers: behavioural tests asserting state landing zone
# Each runs with PROJECT_ROOT=$STATE_TREE / PROJECT_PATH=$WORKTREE
# and asserts the script reads state from STATE_TREE, not WORKTREE.
# ================================================================

@test "memory-loader.sh reads sidecar from PROJECT_ROOT state tree, not worktree (AC2)" {
  export PROJECT_ROOT="$STATE_TREE"
  export PROJECT_PATH="$WORKTREE"
  unset CLAUDE_PROJECT_ROOT
  unset MEMORY_PATH

  run bash "$PLUGIN_ROOT/scripts/memory-loader.sh" bash-dev ground-truth

  [ -n "$output" ] || {
    printf 'FAIL: memory-loader.sh produced empty output (did not read from STATE_TREE)\n' >&2
    return 1
  }
  case "$output" in
    *"path-split verification"*)
      : ;;
    *)
      printf 'FAIL: memory-loader.sh output does not contain seeded content\noutput: %s\n' "$output" >&2
      return 1
      ;;
  esac
}

@test "sprint-status-dashboard.sh reads yaml from PROJECT_ROOT state tree (AC2)" {
  export PROJECT_ROOT="$STATE_TREE"
  export PROJECT_PATH="$WORKTREE"
  unset CLAUDE_PROJECT_ROOT
  unset SPRINT_STATUS_YAML

  run bash "$PLUGIN_ROOT/scripts/sprint-status-dashboard.sh"

  [ "$status" -eq 0 ] || {
    printf 'FAIL: sprint-status-dashboard.sh failed (did not find yaml via PROJECT_ROOT)\nexit=%d output=%s\n' \
      "$status" "$output" >&2
    return 1
  }
  case "$output" in
    *"sprint-test"*)
      : ;;
    *)
      printf 'FAIL: dashboard output does not contain sprint-test\noutput: %s\n' "$output" >&2
      return 1
      ;;
  esac
}

@test "statusline.sh resolves sprint state from PROJECT_ROOT, not PROJECT_PATH (AC2)" {
  export PROJECT_ROOT="$STATE_TREE"
  export PROJECT_PATH="$WORKTREE"
  unset CLAUDE_PROJECT_ROOT

  # statusline.sh reads JSON from stdin for workspace info.
  # Set GAIA_THEME to force rich theme (sprint status read).
  local stdin_json='{"model":{"id":"test","display_name":"test"},"workspace":{"current_dir":"'"$WORKTREE"'"}}'
  export GAIA_THEME="rich"

  run bash -c 'printf "%s" "$1" | bash "$2"' _ "$stdin_json" "$PLUGIN_ROOT/scripts/statusline.sh"

  # statusline always exits 0.
  [ "$status" -eq 0 ]
  # On remediated tree: upward walk starts from PROJECT_ROOT → finds sprint
  # yaml at STATE_TREE → sprint info in output.
  # On unremediated: walk starts from PROJECT_PATH (WORKTREE) → no yaml → no sprint info.
  case "$output" in
    *"sprint-test"*)
      : ;;
    *)
      printf 'FAIL: statusline output does not contain sprint-test (walk did not start from PROJECT_ROOT)\noutput: %s\n' "$output" >&2
      return 1
      ;;
  esac
}

# ================================================================
# Critical path scripts have the chain (supplementary static, AC2)
# ================================================================

@test "dod-check.sh has PROJECT_ROOT chain for .gaia/ (AC2)" {
  local dod="$PLUGIN_ROOT/skills/gaia-dev-story/scripts/dod-check.sh"
  run grep -cF '${PROJECT_ROOT' "$dod"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "yolo-mode.sh sentinel resolves via CLAUDE_PROJECT_ROOT fallback (AC2)" {
  local yolo="$PLUGIN_ROOT/scripts/yolo-mode.sh"
  # Source the script and call the sentinel resolver with only CLAUDE_PROJECT_ROOT set.
  local sentinel
  sentinel=$(CLAUDE_PROJECT_ROOT="$STATE_TREE" PROJECT_ROOT="" PROJECT_PATH="" \
    bash -c 'source "'"$yolo"'" 2>/dev/null; _yolo_resolve_sentinel')
  case "$sentinel" in
    "$STATE_TREE"*) : ;;
    *) printf 'FAIL: sentinel not under CLAUDE_PROJECT_ROOT: %s\n' "$sentinel" >&2; return 1 ;;
  esac
  # With only PROJECT_PATH set.
  sentinel=$(PROJECT_PATH="$STATE_TREE" PROJECT_ROOT="" CLAUDE_PROJECT_ROOT="" \
    bash -c 'source "'"$yolo"'" 2>/dev/null; _yolo_resolve_sentinel')
  case "$sentinel" in
    "$STATE_TREE"*) : ;;
    *) printf 'FAIL: sentinel not under PROJECT_PATH: %s\n' "$sentinel" >&2; return 1 ;;
  esac
  # With all unset — CWD-relative (byte-identical to staging).
  sentinel=$(PROJECT_ROOT="" CLAUDE_PROJECT_ROOT="" PROJECT_PATH="" \
    bash -c 'source "'"$yolo"'" 2>/dev/null; _yolo_resolve_sentinel')
  [ "$sentinel" = ".gaia/state/.yolo-active" ] || {
    printf 'FAIL: unset sentinel not CWD-relative: %s\n' "$sentinel" >&2; return 1
  }
}

@test "load-stack-persona.sh preserves caller-exported PROJECT_ROOT (AC-EC1)" {
  local lsp="$PLUGIN_ROOT/scripts/load-stack-persona.sh"
  # Extract the PROJECT_ROOT assignment block and verify it preserves the exported value.
  local resolved
  resolved=$(PROJECT_ROOT="$STATE_TREE" bash -c '
    eval "$(sed -n "/^PROJECT_ROOT=/p" "'"$lsp"'")"
    printf "%s" "$PROJECT_ROOT"
  ')
  [ "$resolved" = "$STATE_TREE" ] || {
    printf 'FAIL: PROJECT_ROOT clobbered to: %s\n' "$resolved" >&2; return 1
  }
}

@test "gaia-paths.sh resolves constants via PROJECT_ROOT when set (AC2)" {
  local gp="$PLUGIN_ROOT/scripts/lib/gaia-paths.sh"
  # Canonicalize STATE_TREE to match pwd -P output (macOS /var → /private/var).
  local canon_state
  canon_state=$(cd "$STATE_TREE" && pwd -P)
  local result
  result=$(PROJECT_ROOT="$STATE_TREE" CLAUDE_PROJECT_ROOT="" \
    bash -c 'source "'"$gp"'" 2>/dev/null; printf "%s\n%s\n%s\n%s" "$GAIA_CONFIG_DIR" "$GAIA_ARTIFACTS_DIR" "$GAIA_MEMORY_DIR" "$GAIA_STATE_DIR"' 2>/dev/null || true)
  local config
  config=$(echo "$result" | sed -n '1p')
  case "$config" in "$canon_state"*) : ;; *) printf 'FAIL: GAIA_CONFIG_DIR not under STATE_TREE: %s (expected prefix: %s)\n' "$config" "$canon_state" >&2; return 1 ;; esac
}

# ================================================================
# AC-EC6: atomicity enforcement — genuine if/else on tree state
# ================================================================

@test "atomicity: gate detects unremediated tree or commit-equality holds (AC-EC6)" {
  # Compute tree state FIRST: are there bare PROJECT_PATH/.gaia refs?
  local bare
  bare=$(grep -rlF 'PROJECT_PATH/.gaia' "$PLUGIN_ROOT/scripts/" \
    | grep -v '\.bats$' | grep -v 'path-classification-sweep.sh' | head -1 || true)

  if [ -n "$bare" ]; then
    # Branch A: tree is unremediated. The anti-pattern gate must detect it.
    local sweep="$PLUGIN_ROOT/scripts/path-classification-sweep.sh"
    local content
    content=$(cat "$bare")
    # shellcheck source=/dev/null
    source "$sweep"
    _has_bare_pp_gaia "$content" || {
      printf 'FAIL: gate does not detect bare PROJECT_PATH/.gaia in %s\n' "$bare" >&2
      return 1
    }
  else
    # Branch B: tree is remediated. Check commit-equality via git.
    # Skip in shallow clones or detached HEAD where history is unavailable.
    local is_shallow
    is_shallow=$(cd "$PLUGIN_ROOT" && git rev-parse --is-shallow-repository 2>/dev/null || echo true)
    if [ "$is_shallow" = "true" ]; then
      skip 'commit-equality needs full history (shallow clone)'
    fi
    local bats_sha
    bats_sha=$(cd "$PLUGIN_ROOT" && git log --diff-filter=A --format=%H -1 \
      -- tests/path-split-resolution.bats 2>/dev/null || true)
    if [ -z "$bats_sha" ]; then
      skip 'commit-equality half runs post-commit (bats files are untracked or history unavailable)'
    fi
    local scripts_in_commit
    scripts_in_commit=$(cd "$PLUGIN_ROOT" && git diff-tree --no-commit-id --name-only -r "$bats_sha" \
      -- 'scripts/*.sh' 'skills/*/scripts/*.sh' 2>/dev/null || true)
    [ -n "$scripts_in_commit" ] || {
      printf 'FAIL: bats file commit %s does not touch any remediated script — atomicity violated\n' "$bats_sha" >&2
      return 1
    }
  fi
}
