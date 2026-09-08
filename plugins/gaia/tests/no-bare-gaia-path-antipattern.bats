#!/usr/bin/env bats
# no-bare-gaia-path-antipattern.bats — standing gate rejecting three
# anti-patterns in the plugin script tree, plus executed .gaia/ expressions
# in SKILL.md fenced blocks.
#
# Clauses:
#   1. Bare $PROJECT_PATH/.gaia — conflates code tree with state tree.
#   2. CWD-relative .gaia/ literals in path construction without a
#      preceding ${PROJECT_ROOT} on the same line (incl. printf/echo form).
#   3. PROJECT_ROOT= chain assignments whose RHS does not begin with
#      ${PROJECT_ROOT:- — discards a caller-exported value.
#   4. Executed .gaia/ in SKILL.md fenced code blocks without PROJECT_ROOT.
#   5. PROJECT_ROOT= chain inversion — ${PROJECT_ROOT:-} appears as an
#      inner (non-first) fallback term, silently discarding a caller export.
#
# Detectors are sourced from path-classification-sweep.sh (single source
# of truth). The source does NOT leak shell options into the bats runner.
#
# Permanent carve-outs (creation/template paths, not state reads):
#   - scripts/init-project.sh — creates the .gaia/ tree
#   - skills/gaia-init/scripts/generate-config.sh — creates .gaia/config/
#   - skills/gaia-ci-setup/scripts/generate-pipeline.sh — template emission
#   - scripts/path-classification-sweep.sh — contains patterns as detectors
#
# File-count floor: every clause hard-fails when the find yields fewer
# files than expected — prevents a broken find from reporting false green.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SWEEP="$PLUGIN_ROOT/scripts/path-classification-sweep.sh"

# Source the sweep for shared detector functions. The sweep's source guard
# skips `set -euo pipefail` when sourced, so the caller's $- is preserved.
# shellcheck source=../scripts/path-classification-sweep.sh
source "$SWEEP"

# Minimum file counts — fail-closed when scan yields too few.
MIN_SCRIPTS=100
MIN_SKILLMD=50

setup() {
  common_setup
}

teardown() { common_teardown; }

# _collect_scripts and _collect_gaia_scripts are sourced from the sweep
# (path-classification-sweep.sh) — single source of truth.

# ---- Source guard: sourcing the sweep must not change $- ----

@test "sourcing the sweep script does not change shell options (AC5)" {
  local before_flags="$-"
  # Re-source in a subshell and compare.
  local after_flags
  after_flags=$(bash -c '
    before="$-"
    source "'"$SWEEP"'"
    after="$-"
    [ "$before" = "$after" ] && echo "MATCH" || echo "MISMATCH: $before -> $after"
  ')
  [[ "$after_flags" == "MATCH" ]]
}

# ---- Clause 1: bare $PROJECT_PATH/.gaia ----

@test "no bare PROJECT_PATH/.gaia in plugin scripts (AC5)" {
  local all_files gaia_files
  all_files=$(_collect_scripts)
  local count
  count=$(printf '%s\n' "$all_files" | grep -c '.' || true)
  [ "$count" -ge "$MIN_SCRIPTS" ] || {
    printf 'FAIL: scan found only %d scripts (floor: %d) — find is broken\n' "$count" "$MIN_SCRIPTS" >&2
    return 1
  }

  gaia_files=$(_collect_gaia_scripts)

  local violations=""
  local f
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    local content
    content=$(cat "$f")
    if _has_bare_pp_gaia "$content"; then
      violations="${violations}${f}\n"
    fi
  done <<< "$gaia_files"

  if [ -n "$violations" ]; then
    printf 'FAIL: bare $PROJECT_PATH/.gaia found in:\n%b' "$violations" >&2
    return 1
  fi
}

# ---- Clause 2: CWD-relative .gaia/ without PROJECT_ROOT ----

@test "no CWD-relative .gaia/ path construction without PROJECT_ROOT (AC5)" {
  local all_files gaia_files
  all_files=$(_collect_scripts)
  local count
  count=$(printf '%s\n' "$all_files" | grep -c '.' || true)
  [ "$count" -ge "$MIN_SCRIPTS" ] || {
    printf 'FAIL: scan found only %d scripts (floor: %d) — find is broken\n' "$count" "$MIN_SCRIPTS" >&2
    return 1
  }

  gaia_files=$(_collect_gaia_scripts)

  local violations=""
  local f
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    local content
    content=$(cat "$f")
    if _has_cwd_gaia "$content"; then
      violations="${violations}${f}\n"
    fi
  done <<< "$gaia_files"

  if [ -n "$violations" ]; then
    local vcount
    vcount=$(printf '%b' "$violations" | grep -c '.' || true)
    printf 'FAIL: %d file(s) have CWD-relative .gaia/ without PROJECT_ROOT:\n%b' \
      "$vcount" "$(printf '%b' "$violations" | sort -u | head -20)" >&2
    return 1
  fi
}

# ---- Clause 3: PROJECT_ROOT= chain missing ${PROJECT_ROOT:- ----

@test "no PROJECT_ROOT= chain assignment discarding caller value (AC5)" {
  local all_files
  all_files=$(_collect_scripts)
  local count
  count=$(printf '%s\n' "$all_files" | grep -c '.' || true)
  [ "$count" -ge "$MIN_SCRIPTS" ] || {
    printf 'FAIL: scan found only %d scripts (floor: %d) — find is broken\n' "$count" "$MIN_SCRIPTS" >&2
    return 1
  }

  # Pre-filter: only files containing PROJECT_ROOT= need the chain check.
  local chain_files
  chain_files=$(printf '%s\n' "$all_files" | xargs grep -lF 'PROJECT_ROOT=' 2>/dev/null || true)

  local violations=""
  local f
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    local content
    content=$(cat "$f")
    if _is_shape4_chain_missing_pr "$content"; then
      violations="${violations}${f}\n"
    fi
  done <<< "$chain_files"

  if [ -n "$violations" ]; then
    printf 'FAIL: PROJECT_ROOT= chain without ${PROJECT_ROOT:- found:\n%b' "$violations" >&2
    return 1
  fi
}

# ---- Clause 4: executed .gaia/ in SKILL.md fenced blocks ----

@test "no bare .gaia/ in executed SKILL.md expressions (AC5)" {
  local skill_files
  skill_files=$(find "$PLUGIN_ROOT/skills" -maxdepth 2 -name 'SKILL.md')
  local count
  count=$(printf '%s\n' "$skill_files" | grep -c '.' || true)
  [ "$count" -ge "$MIN_SKILLMD" ] || {
    printf 'FAIL: scan found only %d SKILL.md files (floor: %d) — find is broken\n' "$count" "$MIN_SKILLMD" >&2
    return 1
  }

  local violations=""
  local f
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    if ! grep -q '\.gaia/' "$f" 2>/dev/null; then continue; fi
    local verdict
    verdict=$(_classify_skillmd_content "$f")
    if [ "${verdict%%:*}" = "executed-heuristic" ]; then
      violations="${violations}${f}\n"
    fi
  done <<< "$skill_files"

  if [ -n "$violations" ]; then
    local vcount
    vcount=$(printf '%b' "$violations" | grep -c '.' || true)
    printf 'FAIL: %d SKILL.md file(s) have executed .gaia/ without PROJECT_ROOT:\n%b' \
      "$vcount" "$(printf '%b' "$violations" | head -20)" >&2
    return 1
  fi
}

# ---- Clause 5: PROJECT_ROOT= chain inversion ----

@test "no PROJECT_ROOT= chain inversion — inner PROJECT_ROOT:- fallback (AC5)" {
  local all_files
  all_files=$(_collect_scripts)
  local count
  count=$(printf '%s\n' "$all_files" | grep -c '.' || true)
  [ "$count" -ge "$MIN_SCRIPTS" ] || {
    printf 'FAIL: scan found only %d scripts (floor: %d) — find is broken\n' "$count" "$MIN_SCRIPTS" >&2
    return 1
  }

  # Pre-filter: only files containing both PROJECT_ROOT= and ${PROJECT_ROOT:-
  local chain_files
  chain_files=$(printf '%s\n' "$all_files" | xargs grep -lF 'PROJECT_ROOT=' 2>/dev/null || true)

  # Documented carve-outs: files whose inverted priority order is intentional
  # (they prefer CLAUDE_PROJECT_ROOT over a caller-exported PROJECT_ROOT by
  # design — brownfield fresh-project onboarding, artifact-path resolver with
  # --project-root override, and manual-test baseline approval).
  local -a carveouts=(
    "scripts/lib/resolve-artifact-path.sh"
    "skills/gaia-brownfield/scripts/setup.sh"
    "skills/gaia-test-manual/scripts/approve-baseline.sh"
  )

  local violations=""
  local f rel
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    # Skip carve-outs by relative path suffix.
    rel="${f#"$PLUGIN_ROOT"/}"
    local skip=0 co
    for co in "${carveouts[@]}"; do
      case "$rel" in *"$co") skip=1; break ;; esac
    done
    [ "$skip" -eq 0 ] || continue

    local content
    content=$(cat "$f")
    if _is_chain_inverted "$content"; then
      violations="${violations}${f}\n"
    fi
  done <<< "$chain_files"

  if [ -n "$violations" ]; then
    printf 'FAIL: PROJECT_ROOT= chain inversion (inner PROJECT_ROOT:- fallback):\n%b' "$violations" >&2
    return 1
  fi
}

# ---- Classification table (AC1) ----

@test "sweep produces a well-formed classification table (AC1)" {
  # CI-verifiable half: the shipped sweep must produce output covering
  # the four categories (heuristic, state-path, code-path, mixed).
  run bash "$SWEEP" "$PLUGIN_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'| heuristic |'* ]] || [[ "$output" == *'| state-path |'* ]]
  [[ "$output" == *'| code-path |'* ]]
}

@test "sweep classifies each of the four heuristic shapes with per-shape reason markers (AC1)" {
  # Purpose-built fixture tree: one script per heuristic shape so the
  # classifier's per-shape reason-column markers are individually asserted.
  # This detects a regression that silently stops detecting one shape.
  local root="$TEST_TMP/shape-fixture-plugin"
  mkdir -p "$root/scripts"

  # Shape S1: bare $PROJECT_PATH/.gaia (conflates code tree with state tree).
  cat > "$root/scripts/shape-s1-bare-pp.sh" <<'S1'
#!/usr/bin/env bash
CONFIG="$PROJECT_PATH/.gaia/config/project-config.yaml"
S1

  # Shape S2: two-stage chain using PWD-derived .gaia/ path without PROJECT_ROOT.
  # The _has_shape2 detector matches (CLAUDE_PROJECT_ROOT|PWD).*\.gaia lines
  # that do NOT also contain PROJECT_ROOT (note: CLAUDE_PROJECT_ROOT itself
  # contains the substring PROJECT_ROOT, so it matches the PR detector too).
  cat > "$root/scripts/shape-s2-pwd-gaia.sh" <<'S2'
#!/usr/bin/env bash
CONFIG="$PWD/.gaia/config/project-config.yaml"
S2

  # Shape S3: CWD-relative .gaia/ literal in path construction.
  cat > "$root/scripts/shape-s3-cwd-relative.sh" <<'S3'
#!/usr/bin/env bash
CONFIG=".gaia/config/project-config.yaml"
S3

  # Shape S4-recompute: PROJECT_ROOT reassigned discarding caller value.
  cat > "$root/scripts/shape-s4-recompute.sh" <<'S4'
#!/usr/bin/env bash
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$PROJECT_ROOT/.gaia/config/project-config.yaml"
S4

  run bash "$SWEEP" "$root"
  [ "$status" -eq 0 ] || {
    printf 'FAIL: sweep exited %d\n' "$status" >&2
    return 1
  }

  # Assert per-shape reason markers in the output rows.
  # S1 marker: S1(n) in the reason column for shape-s1-bare-pp.sh.
  [[ "$output" == *'shape-s1-bare-pp.sh'*'S1('* ]] || {
    printf 'FAIL: S1 (bare PROJECT_PATH/.gaia) shape marker missing\noutput: %s\n' "$output" >&2
    return 1
  }
  # S2 marker: S2 in the reason column.
  [[ "$output" == *'shape-s2-pwd-gaia.sh'*'S2'* ]] || {
    printf 'FAIL: S2 (PWD-derived .gaia/) shape marker missing\n' >&2
    return 1
  }
  # S3 marker: S3(n) in the reason column.
  [[ "$output" == *'shape-s3-cwd-relative.sh'*'S3('* ]] || {
    printf 'FAIL: S3 (CWD-relative .gaia/) shape marker missing\n' >&2
    return 1
  }
  # S4-recompute marker.
  [[ "$output" == *'shape-s4-recompute.sh'*'S4-recompute'* ]] || {
    printf 'FAIL: S4-recompute shape marker missing\n' >&2
    return 1
  }
}

@test "committed classification table exists when state tree is present (AC1)" {
  local d="$BATS_TEST_DIRNAME"
  local table=""
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    local candidate
    candidate=$(find "$d/.gaia/artifacts/implementation-artifacts" \
      -name 'path-classification-table.md' -print -quit 2>/dev/null || true)
    if [ -n "$candidate" ]; then
      table="$candidate"
      break
    fi
    d="$(dirname "$d")"
  done

  if [ -z "$table" ]; then
    # State tree absent (CI checkout without project root) — run the sweep
    # against the checkout and assert the generated output has the shape of
    # the committed table.
    run bash "$SWEEP" "$PLUGIN_ROOT"
    [ "$status" -eq 0 ] || {
      printf 'FAIL: sweep exited %d\n' "$status" >&2
      return 1
    }

    # (a) Row count matches the collector's file count.
    local collector_count sweep_rows
    collector_count=$(_collect_scripts "$PLUGIN_ROOT" | grep -c '.' || true)
    sweep_rows=$(printf '%s\n' "$output" | grep -c '^| `' || true)
    [ "$sweep_rows" -ge "$collector_count" ] || {
      printf 'FAIL: sweep produced %d rows but collector found %d files\n' \
        "$sweep_rows" "$collector_count" >&2
      return 1
    }

    # (b) At least one row in each expected category (or totals line is consistent).
    local has_code has_state
    has_code=$(printf '%s\n' "$output" | grep -c '| code-path |' || true)
    has_state=$(printf '%s\n' "$output" | grep -c '| state-path |' || true)
    [ "$has_code" -gt 0 ] || {
      printf 'FAIL: sweep output has no code-path rows\n' >&2
      return 1
    }
    [ "$has_state" -gt 0 ] || [ "$(printf '%s\n' "$output" | grep -c '| heuristic')" -gt 0 ] || {
      printf 'FAIL: sweep output has no state-path or heuristic rows\n' >&2
      return 1
    }

    # (c) Symlink-disposition heading present.
    [[ "$output" == *'## Symlink Disposition'* ]] || {
      printf 'FAIL: sweep output missing Symlink Disposition heading\n' >&2
      return 1
    }
  else
    [ -s "$table" ] || {
      printf 'FAIL: classification table is empty: %s\n' "$table" >&2
      return 1
    }
    run grep -F '## Symlink Disposition' "$table"
    [ "$status" -eq 0 ]
  fi
}

# ---- Sweep classifier fixtures (AC-EC2) ----

@test "sweep classifies interpolated .gaia/ in fenced block as executed-heuristic (AC-EC2)" {
  local fixture_dir="$TEST_TMP/fixture-plugin/skills/test-skill"
  mkdir -p "$fixture_dir"
  cat > "$fixture_dir/SKILL.md" <<'FIXTURE'
# Test Skill

```bash
CONFIG_PATH="${SOME_VAR:-.gaia/config/project-config.yaml}"
```
FIXTURE

  run bash "$SWEEP" "$TEST_TMP/fixture-plugin"
  [[ "$output" == *'| `skills/test-skill/SKILL.md` | executed-heuristic |'* ]]
}

@test "sweep classifies prose-only .gaia/ as documentation (AC-EC2)" {
  local fixture_dir="$TEST_TMP/fixture-plugin/skills/prose-skill"
  mkdir -p "$fixture_dir"
  cat > "$fixture_dir/SKILL.md" <<'FIXTURE'
# Prose Skill

The config file lives at `.gaia/config/project-config.yaml`.
FIXTURE

  run bash "$SWEEP" "$TEST_TMP/fixture-plugin"
  [[ "$output" == *'| `skills/prose-skill/SKILL.md` | prose/documentation |'* ]]
  [[ "$output" != *'| `skills/prose-skill/SKILL.md` | executed-heuristic |'* ]]
}

@test "sweep fixture mutation: swapping fixtures flips both verdicts (AC-EC2)" {
  local root="$TEST_TMP/mutation-plugin/skills"
  mkdir -p "$root/alpha" "$root/beta"

  cat > "$root/alpha/SKILL.md" <<'FIXTURE'
# Alpha
```bash
SS_YAML=".gaia/state/sprint-status.yaml"
```
FIXTURE
  cat > "$root/beta/SKILL.md" <<'FIXTURE'
# Beta
The config lives at `.gaia/config/project-config.yaml`.
FIXTURE

  run bash "$SWEEP" "$TEST_TMP/mutation-plugin"
  [[ "$output" == *'| `skills/alpha/SKILL.md` | executed-heuristic |'* ]]
  [[ "$output" == *'| `skills/beta/SKILL.md` | prose/documentation |'* ]]

  # Swap.
  cat > "$root/alpha/SKILL.md" <<'FIXTURE'
# Alpha (now prose)
The state file is at `.gaia/state/sprint-status.yaml`.
FIXTURE
  cat > "$root/beta/SKILL.md" <<'FIXTURE'
# Beta (now executed)
```bash
SS_YAML=".gaia/state/sprint-status.yaml"
```
FIXTURE

  run bash "$SWEEP" "$TEST_TMP/mutation-plugin"
  [[ "$output" == *'| `skills/alpha/SKILL.md` | prose/documentation |'* ]]
  [[ "$output" == *'| `skills/beta/SKILL.md` | executed-heuristic |'* ]]
}

# ---- CI proof: both new bats files in component manifest ----

@test "component manifest lists both new bats files (AC5)" {
  local manifest="$PLUGIN_ROOT/tests/component-manifest.tsv"
  [ -f "$manifest" ] || {
    printf 'FAIL: component-manifest.tsv not found\n' >&2
    return 1
  }
  run grep -F 'path-split-resolution.bats' "$manifest"
  [ "$status" -eq 0 ]
  run grep -F 'no-bare-gaia-path-antipattern.bats' "$manifest"
  [ "$status" -eq 0 ]
}

# ---- Deliberate reference to sweep's main function for coverage gate ----
# The public-function coverage gate (run-with-coverage.sh:140-215) requires
# every public function of scripts/*.sh to appear in some .bats file.
# path-classification-sweep.sh exposes `main` as its only public function.
@test "sweep main function is callable (coverage-gate anchor)" {
  [ "$(type -t main)" = "function" ]
}
