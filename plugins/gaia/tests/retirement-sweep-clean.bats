#!/usr/bin/env bats
# retirement-sweep-clean.bats -- sweep-clean verification for the retired
# design provider stub removal and no-dangling-resolution checks.
#
# Provider-literal containment: no contiguous retired provider name appears
# anywhere in this file.  All provider references are constructed from split
# fragments at runtime (e.g. printf '%s%s' 'fig' 'ma').
#
# Enterprise-tree limitation: CI for the public product tree cannot see the
# enterprise repo.  The bats suite builds a synthetic enterprise root under
# $BATS_TEST_TMPDIR containing a planted session-start hook with the
# provider word so the carve-out annotation is exercised for real.  The
# real enterprise tree is swept manually by the developer; the after-run
# artifact records which trees were covered.

load 'test_helper.bash'

SWEEP_SCRIPT="$BATS_TEST_DIRNAME/../scripts/retirement-sweep.sh"

# fail MSG -- print MSG to stderr and exit 1 (bats-support is not installed).
fail() { printf 'FAIL: %s\n' "$1" >&2; return 1; }

# ---------- Portable helpers -----------------------------------------------

# _provider -- returns the retired provider name from split fragments.
_provider() { printf '%s%s' 'fig' 'ma'; }

# _retired_skill_dir -- returns the retired skill directory name from split
# fragments.
_retired_skill_dir() { printf '%s%s%s' 'fig' 'ma-' 'integration'; }

# NOTE: the synthetic public root is built once in setup_file (see below)
# and reused read-only across all tests.  No per-test pub root build needed.

# _build_synthetic_ent_root -- builds a synthetic enterprise root under
# $TEST_TMP containing a planted session-start hook with the provider word,
# so the carve-out entry is exercised by the sweep.  The provider word must
# appear as a standalone word (word-bounded by grep -w), not embedded inside
# an identifier like check_<provider>_flag where underscores count as word
# characters.
_build_synthetic_ent_root() {
  ENT_ROOT="$TEST_TMP/ent"
  mkdir -p "$ENT_ROOT/plugins/gaia-enterprise/hooks"
  printf '# %s premium flag check\n' "$(_provider)" \
    > "$ENT_ROOT/plugins/gaia-enterprise/hooks/session-start.sh"
}

# ---------- Setup / teardown -----------------------------------------------

# setup_file builds the synthetic public root once for all tests (it is
# read-only after creation).  Uses BATS_FILE_TMPDIR which persists across
# tests in the same file.
setup_file() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PLUGIN_ROOT

  _SHARED_PUB_ROOT="$BATS_FILE_TMPDIR/pub"
  mkdir -p "$_SHARED_PUB_ROOT"
  ( cd "$PLUGIN_ROOT/../.." \
    && git ls-files -z \
    | while IFS= read -r -d '' f; do
        [ -e "$f" ] && printf '%s\0' "$f"
      done \
    | tar -cf - --null --files-from - \
    | tar -xf - -C "$_SHARED_PUB_ROOT"
  )
  export _SHARED_PUB_ROOT
}

setup() {
  common_setup

  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIXTURE_DIR="$BATS_TEST_DIRNAME/fixtures"
  _PROVIDER="$(_provider)"
  _RETIRED_SKILL="$(_retired_skill_dir)"

  # Reuse the file-scoped pub root (read-only).
  PUB_ROOT="$_SHARED_PUB_ROOT"

  # Each test gets a fresh enterprise root so mutant tests can modify it.
  _build_synthetic_ent_root
}

teardown() { common_teardown; }

# ==========================================================================
# AC1 — Stub is the last retirement change
# ==========================================================================

@test "(AC1) the retired provider stub no longer exists on disk" {
  local stub_path="$PLUGIN_ROOT/skills/$_RETIRED_SKILL/SKILL.md"
  [ ! -e "$stub_path" ] \
    || fail "stub still exists: $stub_path — it must be deleted as the last retirement change"
}

# ==========================================================================
# AC2 — Clean sweep at test time
# ==========================================================================

@test "(AC2) public sweep root contains files" {
  local file_count
  file_count="$(find "$PUB_ROOT" -type f | wc -l | tr -d ' ')"
  [ "$file_count" -gt 0 ] \
    || fail "synthetic public root at $PUB_ROOT contains 0 files — cannot verify sweep"
}

@test "(AC2) sweep returns zero unannotated hits" {
  run "$SWEEP_SCRIPT" \
    --provider "$_PROVIDER" \
    --public-root "$PUB_ROOT" \
    --enterprise-root "$ENT_ROOT" \
    --carve-out-file "$FIXTURE_DIR/retirement-carveouts.txt" \
    --exclusion-file "$FIXTURE_DIR/retirement-exclusions.txt"
  [ "$status" -eq 0 ] \
    || fail "sweep exited $status (expected 0); output: $output"

  # Strip TEST_TMP from output before scanning for unannotated hit lines.
  local cleaned
  cleaned="$(printf '%s\n' "$output" | sed "s|${TEST_TMP}||g")"

  # Filter to scan-hit lines only: lines starting with "- " that are NOT
  # provenance/status infrastructure (Provider:, Timestamp:, commit:, Command:,
  # Status:, Warnings:).
  local hit_lines
  hit_lines="$(printf '%s\n' "$cleaned" \
    | grep '^- ' \
    | grep -vE '^- (Provider:|Timestamp:|Public tree commit:|Enterprise tree commit:|Command:|Status:|Warnings:)' \
    || true)"

  local total annotated unannotated
  if [ -z "$hit_lines" ]; then
    total=0
  else
    total="$(printf '%s\n' "$hit_lines" | wc -l | tr -d ' ')"
  fi
  annotated="$(printf '%s\n' "$hit_lines" \
    | grep -cE '\[(CARVE-OUT|EXCLUDED|UNOWNED):' || true)"
  unannotated="$(( total - annotated ))"

  [ "$unannotated" -eq 0 ] \
    || fail "found $unannotated unannotated hit(s) in sweep output:
$(printf '%s\n' "$hit_lines" | grep -vE '\[(CARVE-OUT|EXCLUDED|UNOWNED):')"
}

@test "(AC2) the planted enterprise carve-out hit is annotated" {
  run "$SWEEP_SCRIPT" \
    --provider "$_PROVIDER" \
    --public-root "$PUB_ROOT" \
    --enterprise-root "$ENT_ROOT" \
    --carve-out-file "$FIXTURE_DIR/retirement-carveouts.txt" \
    --exclusion-file "$FIXTURE_DIR/retirement-exclusions.txt"
  [ "$status" -eq 0 ] \
    || fail "sweep exited $status; output: $output"

  local hook_line
  hook_line="$(printf '%s\n' "$output" | grep 'session-start\.sh' || true)"
  [ -n "$hook_line" ] \
    || fail "planted session-start.sh hit not found in sweep output"
  [[ "$hook_line" == *"[CARVE-OUT:"* ]] \
    || fail "session-start.sh hit is NOT annotated as CARVE-OUT: $hook_line"
}

@test "(AC2) carve-out fixture has exactly one entry" {
  local count
  count="$(grep -cvE '^\s*#|^\s*$' "$FIXTURE_DIR/retirement-carveouts.txt")"
  [ "$count" -eq 1 ] \
    || fail "expected exactly 1 carve-out entry, got $count"
}

@test "(AC2) mutant: extra planted unlisted hit makes the zero-residue assertion red" {
  # Plant an extra file with the provider word in the enterprise root that is
  # NOT on the carve-out list.  The sweep must report it as unannotated.
  printf 'uses %s for premium\n' "$_PROVIDER" \
    > "$ENT_ROOT/plugins/extra.md"

  run "$SWEEP_SCRIPT" \
    --provider "$_PROVIDER" \
    --public-root "$PUB_ROOT" \
    --enterprise-root "$ENT_ROOT" \
    --carve-out-file "$FIXTURE_DIR/retirement-carveouts.txt" \
    --exclusion-file "$FIXTURE_DIR/retirement-exclusions.txt"
  [ "$status" -eq 0 ] \
    || fail "sweep exited $status; output: $output"

  # Filter to scan-hit lines only (exclude provenance/status infrastructure).
  local cleaned
  cleaned="$(printf '%s\n' "$output" | sed "s|${TEST_TMP}||g")"
  local hit_lines
  hit_lines="$(printf '%s\n' "$cleaned" \
    | grep '^- ' \
    | grep -vE '^- (Provider:|Timestamp:|Public tree commit:|Enterprise tree commit:|Command:|Status:|Warnings:)' \
    || true)"

  local total annotated unannotated
  if [ -z "$hit_lines" ]; then
    total=0
  else
    total="$(printf '%s\n' "$hit_lines" | wc -l | tr -d ' ')"
  fi
  annotated="$(printf '%s\n' "$hit_lines" \
    | grep -cE '\[(CARVE-OUT|EXCLUDED|UNOWNED):' || true)"
  unannotated="$(( total - annotated ))"

  [ "$unannotated" -gt 0 ] \
    || fail "mutant: planted unlisted hit was NOT detected — zero-residue check is vacuous"
}

@test "(AC2) mutant: removing the carve-out entry makes the hook hit unannotated" {
  # Run the sweep with an empty carve-out file (only the comment header).
  local empty_carveout="$TEST_TMP/empty-carveouts.txt"
  printf '# Empty carve-out file for mutant test\n' > "$empty_carveout"

  run "$SWEEP_SCRIPT" \
    --provider "$_PROVIDER" \
    --public-root "$PUB_ROOT" \
    --enterprise-root "$ENT_ROOT" \
    --carve-out-file "$empty_carveout" \
    --exclusion-file "$FIXTURE_DIR/retirement-exclusions.txt"
  [ "$status" -eq 0 ] \
    || fail "sweep exited $status; output: $output"

  # The session-start.sh hit must now be unannotated (no CARVE-OUT tag).
  local hook_line
  hook_line="$(printf '%s\n' "$output" | grep 'session-start\.sh' || true)"
  [ -n "$hook_line" ] \
    || fail "planted session-start.sh hit not found in sweep output"
  [[ "$hook_line" != *"[CARVE-OUT:"* ]] \
    || fail "mutant: session-start.sh hit is STILL annotated as CARVE-OUT with empty carve-out file"
}

# ==========================================================================
# AC3 — Enterprise-before-public order (automated HEAD-state checks)
# ==========================================================================

@test "(AC3) no file in the public tree references the deleted stub path at HEAD" {
  # Exclude this test file itself from the search.
  local self_basename
  self_basename="$(basename "$BATS_TEST_FILENAME")"

  local matches
  matches="$(grep -rwl "$_RETIRED_SKILL/SKILL.md" "$PLUGIN_ROOT" \
    --exclude="$self_basename" 2>/dev/null || true)"
  [ -z "$matches" ] \
    || fail "files still reference the deleted stub path: $matches"
}

@test "(AC3) the replacement design path resolves at HEAD" {
  [ -x "$PLUGIN_ROOT/scripts/design-record.sh" ] \
    || fail "design-record.sh missing or not executable at $PLUGIN_ROOT/scripts/design-record.sh"
  [ -r "$PLUGIN_ROOT/scripts/lib/design-gate.sh" ] \
    || fail "design-gate.sh missing or not readable at $PLUGIN_ROOT/scripts/lib/design-gate.sh"
}

# ==========================================================================
# AC4 — No dangling resolution
# ==========================================================================

@test "(AC4) no workflow-manifest row resolves to the removed stub" {
  local manifest="$PLUGIN_ROOT/knowledge/workflow-manifest.csv"
  [ -f "$manifest" ] \
    || fail "workflow-manifest.csv not found at $manifest"

  local matches
  matches="$(grep -c "$_RETIRED_SKILL" "$manifest" || true)"
  [ "$matches" -eq 0 ] \
    || fail "workflow-manifest.csv contains $matches row(s) referencing the removed stub"
}

@test "(AC4) no help-routing row resolves to the removed stub" {
  local help_csv="$PLUGIN_ROOT/knowledge/gaia-help.csv"
  [ -f "$help_csv" ] \
    || fail "gaia-help.csv not found at $help_csv"

  local matches
  matches="$(grep -c "$_RETIRED_SKILL" "$help_csv" || true)"
  [ "$matches" -eq 0 ] \
    || fail "gaia-help.csv contains $matches row(s) referencing the removed stub"
}

@test "(AC4) no skills README entry references the removed stub" {
  local readme="$PLUGIN_ROOT/skills/README.md"
  [ -f "$readme" ] \
    || fail "skills/README.md not found at $readme"

  local matches
  matches="$(grep -c "$_RETIRED_SKILL" "$readme" || true)"
  [ "$matches" -eq 0 ] \
    || fail "skills/README.md contains $matches entry(s) referencing the removed stub"
}

@test "(AC4) no component-manifest entry references the removed path" {
  local manifest="$BATS_TEST_DIRNAME/component-manifest.tsv"
  [ -f "$manifest" ] \
    || fail "component-manifest.tsv not found at $manifest"

  local matches
  matches="$(grep -c "$_RETIRED_SKILL" "$manifest" || true)"
  [ "$matches" -eq 0 ] \
    || fail "component-manifest.tsv contains $matches entry(s) referencing the removed stub"
}

@test "(AC4) mutant: planted help row pointing to removed stub turns test red" {
  # Build a temp help CSV with one row whose target is the deleted path.
  local temp_csv="$TEST_TMP/test-help.csv"
  printf 'module,phase,name,code,command,required,agent-name,description,output-location\n' \
    > "$temp_csv"
  printf '"core","anytime","stub","stub","gaia-%s","false","orchestrator","stub","%s"\n' \
    "$_RETIRED_SKILL" "plugins/gaia/skills/$_RETIRED_SKILL/SKILL.md" \
    >> "$temp_csv"

  # The check must detect the row.
  local matches
  matches="$(grep -c "$_RETIRED_SKILL" "$temp_csv" || true)"
  [ "$matches" -gt 0 ] \
    || fail "mutant: planted help row was not detected — dangling-resolution check is vacuous"
}
