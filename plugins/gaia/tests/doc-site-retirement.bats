#!/usr/bin/env bats
# doc-site-retirement.bats -- regression guards for documentation site
# provider-retirement edits: removed command page, rewritten pages,
# navigation link cleanup, and scoped provider-term sweep.

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
  DOC_DIR="$REPO_ROOT/documentation"
  # Split-fragment provider literal -- never contiguous in this file
  _PROVIDER="$(printf '%s%s' 'fig' 'ma')"
  # Retired skill name (reused by page-deletion and nav-link tests)
  _RETIRED_SKILL="$(printf '%s%s%s' 'fig' 'ma-' 'integration')"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# _filter_exclusions <raw_hits> <exclusion1> [exclusion2 ...]
# Prints lines from raw_hits that do NOT match any exclusion suffix.
_filter_exclusions() {
  local raw="$1"; shift
  local -a excl=("$@")
  [ -z "$raw" ] && return 0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local excluded=0
    for ex in "${excl[@]}"; do
      if printf '%s' "$line" | grep -qF "$ex"; then
        excluded=1; break
      fi
    done
    [ "$excluded" -eq 0 ] && printf '%s\n' "$line"
  done <<< "$raw"
}

# ---------------------------------------------------------------------------
# AC1 — removed command page
# ---------------------------------------------------------------------------

@test "(AC1) removed command page does not exist" {
  local page="$DOC_DIR/commands/gaia-${_RETIRED_SKILL}.html"
  run test -f "$page"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC1 — recipes page carries no retired-provider name
# ---------------------------------------------------------------------------

@test "(AC1) recipes page carries no retired-provider row" {
  run grep -wiF "$_PROVIDER" "$DOC_DIR/recipes.html"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC1 — create-ux page describes the design lifecycle
# ---------------------------------------------------------------------------

@test "(AC1) create-ux page describes the design lifecycle" {
  local page="$DOC_DIR/commands/gaia-create-ux.html"
  [ -f "$page" ] || { printf 'Missing: %s\n' "$page"; return 1; }
  run grep -ciE 'Claude Design|design-record|design system' "$page"
  [ "$status" -eq 0 ] || { printf 'No design-lifecycle language in %s\n' "$page"; return 1; }
  [ "$output" -gt 0 ]
}

# ---------------------------------------------------------------------------
# AC1 — design-a11y page carries no retired provider
# ---------------------------------------------------------------------------

@test "(AC1) design-a11y page carries no retired provider" {
  local page="$DOC_DIR/commands/gaia-validate-design-a11y.html"
  [ -f "$page" ] || { printf 'Missing: %s\n' "$page"; return 1; }
  run grep -wiF "$_PROVIDER" "$page"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC-EC2 — no navigation entry links to removed page
# ---------------------------------------------------------------------------

@test "(AC-EC2) no navigation entry links to removed page" {
  run grep -rlF "gaia-${_RETIRED_SKILL}" "$DOC_DIR/"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC-EC3 — no surviving test file name contains retired provider
# ---------------------------------------------------------------------------

@test "(AC-EC3) no surviving test file name contains retired provider" {
  run find "$PLUGIN_ROOT/tests" "$REPO_ROOT/tests/skills" \
    -iname "*${_PROVIDER}*" -type f 2>/dev/null
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# AC-EC6 — recipes page preserves the working recipe row
# ---------------------------------------------------------------------------

@test "(AC-EC6) recipes page preserves the working recipe row" {
  run grep -F '/gaia-create-ux' "$DOC_DIR/recipes.html"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC5 — scoped provider-term sweep (self-contained, no external deps)
# ---------------------------------------------------------------------------

@test "(AC5) zero provider-term hits in scoped paths outside exclusions" {
  # Scope: documentation/, plugin tests, repo tests, CHANGELOG.
  # All paths inside gaia-public -- no project-root or sibling-repo deps.
  local -a SCOPE_DIRS=( "$DOC_DIR" "$PLUGIN_ROOT/tests" "$REPO_ROOT/tests" )
  local CHANGELOG="$PLUGIN_ROOT/CHANGELOG.md"

  # Guard: scope directories must exist so an empty scan is never vacuous.
  for d in "${SCOPE_DIRS[@]}"; do
    [ -d "$d" ] || { printf 'FATAL: scope directory missing: %s\n' "$d"; return 1; }
  done
  [ -f "$CHANGELOG" ] || { printf 'FATAL: CHANGELOG missing: %s\n' "$CHANGELOG"; return 1; }

  # Guard: scan must visit files.
  local file_count=0
  for d in "${SCOPE_DIRS[@]}"; do
    file_count=$(( file_count + $(find "$d" -type f 2>/dev/null | wc -l) ))
  done
  file_count=$(( file_count + 1 ))  # CHANGELOG
  [ "$file_count" -gt 0 ] || { printf 'FATAL: scan visited 0 files\n'; return 1; }

  # In-test exclusion list (path suffixes with reasons):
  #   - market-research fixtures: competitor/comparison prose
  #   - this test file: split-fragment construction
  local self_basename
  self_basename="$(basename "${BATS_TEST_FILENAME:-doc-site-retirement.bats}")"
  local -a EXCLUSIONS=(
    "fixtures/market-research-complete.md"
    "fixtures/market-research-missing-tam-assumptions.md"
    "$self_basename"
  )

  # Word-bounded, case-insensitive grep across scope.
  local raw_hits=""
  for d in "${SCOPE_DIRS[@]}"; do
    local h
    h="$(grep -rwiF "$_PROVIDER" "$d" 2>/dev/null || true)"
    [ -n "$h" ] && raw_hits="${raw_hits}${h}"$'\n'
  done
  local ch
  ch="$(grep -wiF "$_PROVIDER" "$CHANGELOG" 2>/dev/null || true)"
  [ -n "$ch" ] && raw_hits="${raw_hits}${ch}"$'\n'

  # Filter exclusions and assert zero remaining hits.
  local bare_hits
  bare_hits="$(_filter_exclusions "$raw_hits" "${EXCLUSIONS[@]}")"

  if [ -n "$bare_hits" ]; then
    printf 'Unexcluded provider hits (%d files scanned). Fix these or add to exclusion list with reason:\n%s' \
      "$file_count" "$bare_hits"
    return 1
  fi
}
