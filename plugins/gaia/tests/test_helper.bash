#!/usr/bin/env bash
# test_helper.bash — shared setup/teardown for bats suites under the plugin
# test directory.
#
# Provides per-test temp dirs under $BATS_TMPDIR (never touches the working
# tree), a run_script helper that always invokes the real script from
# plugins/gaia/scripts/, and deterministic LC_ALL/TZ pinning.
#
# Strict mode (set -euo pipefail) is intentionally enabled and stays on for
# every suite that loads this helper.  Suites must be written to work under
# strict mode; pipelines whose first command may legitimately fail need an
# explicit `|| true` guard.

set -euo pipefail
LC_ALL=C
export LC_ALL
export TZ=UTC

# Suppress the post-mutation snapshot hook during tests
export GAIA_SNAPSHOT_HOOK_DISABLE=1

# Resolve SCRIPTS_DIR from the helper's own location.  Always overwrite any
# inherited or environment value so a stray SCRIPTS_DIR cannot leak in.
# Subdirectory local helpers that need a different SCRIPTS_DIR must re-export
# it AFTER sourcing this file.
if [ -d "$BATS_TEST_DIRNAME/../scripts" ]; then
  SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
else
  SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" 2>/dev/null && pwd 2>/dev/null || echo "")"
fi
export SCRIPTS_DIR

# ---------------------------------------------------------------------------
# Cross-platform helpers (detect once, use everywhere in tests)
# ---------------------------------------------------------------------------

if stat -c %Y / >/dev/null 2>&1; then
  _TEST_STAT_FMT="gnu"
else
  _TEST_STAT_FMT="bsd"
fi

if date -u -d @0 +%s >/dev/null 2>&1; then
  _TEST_DATE_FMT="gnu"
else
  _TEST_DATE_FMT="bsd"
fi

_stat_mtime() {
  if [ "$_TEST_STAT_FMT" = "gnu" ]; then
    stat -c %Y "$1"
  else
    stat -f %m "$1"
  fi
}

_epoch_to_touchdate() {
  if [ "$_TEST_DATE_FMT" = "gnu" ]; then
    date -u -d "@$1" +%Y%m%d%H%M
  else
    date -u -r "$1" +%Y%m%d%H%M
  fi
}

common_setup() {
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT PROJECT_PATH
  local slug
  slug="$(printf '%s' "${BATS_TEST_NAME:-unknown}" | tr -c '[:alnum:]' '_')"
  TEST_TMP="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/gaia-${slug}-$$"
  mkdir -p "$TEST_TMP"
  export TEST_TMP
}

common_teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Per-file litter guard (setup_file / teardown_file)
# ---------------------------------------------------------------------------
# Snapshots `git status` under the plugin tree before the first test in a
# .bats file, then diffs after the last test.  Any new untracked file or
# modification to a tracked file is caught — the teardown fails and names
# BATS_TEST_FILENAME + the offending paths.
#
# Works only inside a git work tree; silently skips (with a note) otherwise.
# Safe for parallel worktrees: each worktree has its own git index.
# Safe for CI Linux: no platform-specific commands.

_LITTER_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LITTER_REPO_ROOT="$(cd "$_LITTER_HELPER_DIR/../../.." 2>/dev/null && pwd 2>/dev/null || echo "")"
_LITTER_SNAPSHOT=""

_litter_snapshot_before() {
  [ -z "$_LITTER_SNAPSHOT" ] || return 0
  local repo_root="$_LITTER_REPO_ROOT"
  [ -n "$repo_root" ] || { _LITTER_SNAPSHOT="SKIP"; return 0; }
  if ! git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    _LITTER_SNAPSHOT="SKIP"
    return 0
  fi
  _LITTER_SNAPSHOT="${BATS_FILE_TMPDIR}/litter-before"
  git -C "$repo_root" status --porcelain --untracked-files=all -- plugins/gaia/ \
    | LC_ALL=C sort > "$_LITTER_SNAPSHOT" 2>/dev/null || true
}

_litter_check_after() {
  [ -n "$_LITTER_SNAPSHOT" ] && [ "$_LITTER_SNAPSHOT" != "SKIP" ] || return 0
  [ -f "$_LITTER_SNAPSHOT" ] || return 0
  local repo_root="$_LITTER_REPO_ROOT"
  local after="${BATS_FILE_TMPDIR}/litter-after"
  git -C "$repo_root" status --porcelain --untracked-files=all -- plugins/gaia/ \
    | LC_ALL=C sort > "$after" 2>/dev/null || return 0
  # Filter out transient CI artefacts that are not real litter:
  #   .last-validate-err.<PID> — validate-rubric.sh on SIGTERM
  #   zz-probe-dir/           — no-stray-gaia-dir.bats probe fixture
  local litter
  litter="$(comm -13 "$_LITTER_SNAPSHOT" "$after" \
    | grep -v '\.last-validate-err\.' \
    | grep -v 'zz-probe-dir/' \
    || true)"
  if [ -n "$litter" ]; then
    printf 'LITTER: %s left changes under the plugin tree:\n%s\n' \
      "${BATS_TEST_FILENAME##*/}" "$litter" >&2
    return 1
  fi
}

setup_file() {
  _litter_snapshot_before
}

teardown_file() {
  _litter_check_after
}

snapshot_script_under_test() {
  local real="$1"
  if [ -z "${SNAPSHOT_TEST_BASH:-}" ]; then printf '%s' "$real"; return 0; fi
  if [ ! -x "$SNAPSHOT_TEST_BASH" ]; then
    printf 'SNAPSHOT_TEST_BASH=%s is not an executable interpreter\n' "$SNAPSHOT_TEST_BASH" >&2
    return 1
  fi
  local dir="$TEST_TMP/snapshot-under-test"
  mkdir -p "$dir"
  [ -e "$dir/lib" ] || ln -s "$SCRIPTS_DIR/lib" "$dir/lib"
  { printf '#!%s\n' "$SNAPSHOT_TEST_BASH"; tail -n +2 "$real"; } > "$dir/sprint-progress-snapshot.sh"
  chmod +x "$dir/sprint-progress-snapshot.sh"
  printf '%s' "$dir/sprint-progress-snapshot.sh"
}

run_script() {
  local name="$1"; shift
  run "$SCRIPTS_DIR/$name" "$@"
}

# ---------------------------------------------------------------------------
# Non-vacuous negative assertions.
# ---------------------------------------------------------------------------

assert_file_excludes() {
  local file="$1" pattern="$2"
  if grep -qF -- "$pattern" "$file"; then
    printf 'assert_file_excludes: unexpected match for %s in %s\n' "$pattern" "$file" >&2
    return 1
  fi
  return 0
}

assert_file_contains() {
  local file="$1" pattern="$2"
  if ! grep -qF -- "$pattern" "$file"; then
    printf 'assert_file_contains: missing expected %s in %s\n' "$pattern" "$file" >&2
    return 1
  fi
  return 0
}
