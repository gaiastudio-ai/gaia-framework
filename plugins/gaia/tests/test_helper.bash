#!/usr/bin/env bash
# test_helper.bash — shared setup/teardown for the E28-S17 bats suite.
#
# Provides per-test temp dirs under $BATS_TMPDIR (never touches the working
# tree), a run_script helper that always invokes the real script from
# plugins/gaia/scripts/, and deterministic LC_ALL/TZ pinning.

set -euo pipefail
LC_ALL=C
export LC_ALL
export TZ=UTC

# Suppress the post-mutation snapshot hook during tests
export GAIA_SNAPSHOT_HOOK_DISABLE=1

# Resolve SCRIPTS_DIR once. Prefer the .bats file's relative path (tests/ ->
# scripts/); fall back to the helper's own path (BASH_SOURCE) for synthetic
# suites loaded from outside the repo tree.
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

# _stat_mtime FILE — portable single-file mtime (epoch seconds)
_stat_mtime() {
  if [ "$_TEST_STAT_FMT" = "gnu" ]; then
    stat -c %Y "$1"
  else
    stat -f %m "$1"
  fi
}

# _epoch_to_touchdate EPOCH — print YYYYMMDDHHmm for touch -t
_epoch_to_touchdate() {
  if [ "$_TEST_DATE_FMT" = "gnu" ]; then
    date -u -d "@$1" +%Y%m%d%H%M
  else
    date -u -r "$1" +%Y%m%d%H%M
  fi
}

# common_setup — called from every test's setup(). Creates a per-test temp
# dir, namespaces it by $BATS_TEST_NAME, and exports TEST_TMP.
common_setup() {
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT PROJECT_PATH
  local slug
  slug="$(printf '%s' "${BATS_TEST_NAME:-unknown}" | tr -c '[:alnum:]' '_')"
  TEST_TMP="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/gaia-${slug}-$$"
  mkdir -p "$TEST_TMP"
  export TEST_TMP
}

# common_teardown — called from every test's teardown(). Removes the temp
# dir. Safe to call twice; failures are swallowed so teardown never masks
# the real test failure.
common_teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Per-file litter guard (setup_file / teardown_file)
# ---------------------------------------------------------------------------
# Snapshots `git status` under the plugin tree before the first test in a
# .bats file, then diffs after the last test. Any new untracked file is
# litter — the teardown fails and names BATS_TEST_FILENAME + the offending
# paths.
#
# Works only inside a git work tree; silently skips (with a note) otherwise.
# Safe for parallel worktrees: each worktree has its own git index.
# Safe for CI Linux: no platform-specific commands.

# Resolve once from the helper's own path (BASH_SOURCE), not from
# BATS_TEST_DIRNAME — the latter points at the .bats file which may live
# outside the repo (e.g. a synthetic suite in /tmp that loads this helper
# by absolute path).
_LITTER_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LITTER_REPO_ROOT="$(cd "$_LITTER_HELPER_DIR/../../.." 2>/dev/null && pwd 2>/dev/null || echo "")"
_LITTER_SNAPSHOT=""

# _litter_snapshot_before — call from setup_file (or the first test) to
# record the baseline. Idempotent: only the first call per file takes effect.
_litter_snapshot_before() {
  [ -z "$_LITTER_SNAPSHOT" ] || return 0
  local repo_root="$_LITTER_REPO_ROOT"
  [ -n "$repo_root" ] || { _LITTER_SNAPSHOT="SKIP"; return 0; }
  if ! git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # Not a git worktree (e.g. extracted tarball); skip with a note.
    _LITTER_SNAPSHOT="SKIP"
    return 0
  fi
  _LITTER_SNAPSHOT="${BATS_FILE_TMPDIR}/litter-before"
  git -C "$repo_root" status --porcelain --untracked-files=all -- plugins/gaia/ \
    | LC_ALL=C sort > "$_LITTER_SNAPSHOT" 2>/dev/null || true
}

# _litter_check_after — call from teardown_file to diff the snapshot.
# Fails if new files appeared under the plugin tree.
_litter_check_after() {
  [ -n "$_LITTER_SNAPSHOT" ] && [ "$_LITTER_SNAPSHOT" != "SKIP" ] || return 0
  [ -f "$_LITTER_SNAPSHOT" ] || return 0
  local repo_root="$_LITTER_REPO_ROOT"
  local after="${BATS_FILE_TMPDIR}/litter-after"
  git -C "$repo_root" status --porcelain --untracked-files=all -- plugins/gaia/ \
    | LC_ALL=C sort > "$after" 2>/dev/null || return 0
  # Filter out transient CI artefacts that are not real litter (each filed
  # as a Finding for upstream fix):
  #   .last-validate-err.<PID> — validate-rubric.sh on SIGTERM (Finding #4)
  #   zz-probe-dir/           — no-stray-gaia-dir.bats probe fixture (Finding #5)
  local litter
  litter="$(comm -13 "$_LITTER_SNAPSHOT" "$after" \
    | grep -v '\.last-validate-err\.' \
    | grep -v 'zz-probe-dir/' \
    || true)"
  if [ -n "$litter" ]; then
    printf 'LITTER: %s left files under the plugin tree:\n%s\n' \
      "${BATS_TEST_FILENAME##*/}" "$litter" >&2
    return 1
  fi
}

# Default setup_file / teardown_file — run for every .bats file that loads
# this helper and does not define its own.
setup_file() {
  _litter_snapshot_before
}

teardown_file() {
  _litter_check_after
}

# snapshot_script_under_test SCRIPT — print the path of the snapshot script a
# suite runs.  Normally that is SCRIPT itself.  When SNAPSHOT_TEST_BASH names
# an interpreter (for example /bin/bash, which is bash 3.2 on macOS), it is a
# copy whose first line names that interpreter, placed next to a link to the
# real lib/ directory, so every direct run of the script uses that shell.
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

# run_script <basename> [args...] — run a foundation script by basename
# (e.g. "resolve-config.sh") with $status, $output, $stderr populated by
# bats' `run` built-in.
run_script() {
  local name="$1"; shift
  run "$SCRIPTS_DIR/$name" "$@"
}

# ---------------------------------------------------------------------------
# Non-vacuous negative assertions.
#
# A bare `! grep -q PATTERN file` does NOT fail a bats test: the `!` prefix
# exempts the command from the set -e that bats relies on to detect a failed
# assertion, so the negation can never abort the test. Every such line is a
# silently vacuous assertion. These helpers run the match WITHOUT a `!`
# prefix and assert on the captured status, so a violated expectation aborts
# the test as intended.
# ---------------------------------------------------------------------------

# assert_file_excludes FILE PATTERN — fail if PATTERN (fixed string) is present.
assert_file_excludes() {
  local file="$1" pattern="$2"
  if grep -qF -- "$pattern" "$file"; then
    printf 'assert_file_excludes: unexpected match for %s in %s\n' "$pattern" "$file" >&2
    return 1
  fi
  return 0
}

# assert_file_contains FILE PATTERN — fail if PATTERN (fixed string) is absent.
assert_file_contains() {
  local file="$1" pattern="$2"
  if ! grep -qF -- "$pattern" "$file"; then
    printf 'assert_file_contains: missing expected %s in %s\n' "$pattern" "$file" >&2
    return 1
  fi
  return 0
}
