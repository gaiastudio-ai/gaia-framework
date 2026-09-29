#!/usr/bin/env bats
# changelog-retirement.bats -- validates the changelog carries no retired-
# provider terminology, no leaked internal identifiers, and that the
# rewritten entry preserves what the release actually shipped.

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CHANGELOG="$PLUGIN_ROOT/CHANGELOG.md"
  # Split-fragment provider literal -- never contiguous in this file
  _PROVIDER="$(printf '%s%s' 'fig' 'ma')"
}

# ---------------------------------------------------------------------------
# AC2 — changelog has zero word-bounded provider hits
# ---------------------------------------------------------------------------

@test "(AC2) changelog has zero word-bounded provider hits" {
  [ -f "$CHANGELOG" ]
  run grep -wiF "$_PROVIDER" "$CHANGELOG"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC-EC1 — rewritten entry preserves what the release shipped
# ---------------------------------------------------------------------------

@test "(AC-EC1) rewritten entry preserves what the release shipped" {
  [ -f "$CHANGELOG" ]
  # The rewritten line under [1.131.0] must name the three features the
  # release genuinely shipped and cite the PR number.  We locate the line
  # by its stable anchor: (#321).
  local line
  line="$(grep -F '(#321)' "$CHANGELOG" || true)"
  [ -n "$line" ]

  # Assert each shipped feature name is present.
  printf '%s' "$line" | grep -qF 'atdd gate'
  printf '%s' "$line" | grep -qF 'plan-structure validator'
  printf '%s' "$line" | grep -qF 'graceful-degrade'
  # Assert the PR number is cited.
  printf '%s' "$line" | grep -qF '#321'
}

# ---------------------------------------------------------------------------
# AC-EC7 — rewritten entry carries no internal identifier patterns
# ---------------------------------------------------------------------------

@test "(AC-EC7) rewritten entry carries no internal identifier patterns" {
  [ -f "$CHANGELOG" ]
  # Narrow scope: only the rewritten line (anchored by #321).
  local line
  line="$(grep -F '(#321)' "$CHANGELOG" || true)"
  [ -n "$line" ]
  # Regex matches FR-nnn, ADR-nnn, or E<digits>-S<digits> shapes.
  run bash -c "printf '%s' \"\$1\" | grep -E '\bFR-[0-9]+\b|\bADR-[0-9]+\b|\bE[0-9]+-S[0-9]+\b'" _ "$line"
  [ "$status" -ne 0 ]
}
