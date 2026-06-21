#!/usr/bin/env bats
# resolve-epic-slug.bats — E79-S1 / TC-CSP-4 + TC-CSP-5
#
# Verifies the byte-deterministic contract of
# gaia-public/plugins/gaia/scripts/lib/resolve-epic-slug.sh — the shared
# helper that derives the canonical per-epic directory name
# (`epic-{epic-slug}/`) byte-identically from `epics-and-stories.md`.
#
# Test scenarios traced to story Test Scenarios table:
#   TS1 (TC-CSP-4) — Byte-identical slug for every existing epic-{slug}/ dir
#   TS2 (TC-CSP-5) — `mkdir -p` of the per-epic stories dir is idempotent
#   TS3 (AC5)      — Unknown epic key fails closed (auxiliary; not TC-CSP-traced)
#   TS4            — Sourceable invocation has no top-level side effects
#   AC1            — Script header invariants (shebang, set -euo pipefail, LC_ALL=C)
#   AC2            — Resolves E79 to live directory basename
#   AC4            — Sourceable + sourceable-function returns slug
#
# The TC-CSP-4 case runs against a hermetic in-repo fixture
# (tests/fixtures/resolve-epic-slug/) rather than the operator's live tree, so
# it is deterministic and passes in a published-source CI checkout (which has no
# .gaia/artifacts/ epics). Live-tree drift tolerance is the resolver's own
# runtime concern, not this test's.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$LIB_DIR/resolve-epic-slug.sh"
}

teardown() { common_teardown; }

# Hermetic fixture: a curated in-repo epics file + epic dirs so the resolver
# tests are deterministic and do NOT read the operator's live .gaia/ tree —
# which is absent in a published-source (gaia-public-only) CI checkout, where
# the live-tree form failed. The fixture lives next to the tests under
# tests/fixtures/resolve-epic-slug/.
_fixture_dir() {
  cd "${BATS_TEST_DIRNAME}/../fixtures/resolve-epic-slug" && pwd
}
_fixture_epics_file() {
  printf '%s/epics-and-stories.md' "$(_fixture_dir)"
}
_fixture_impl_dir() {
  printf '%s/implementation-artifacts' "$(_fixture_dir)"
}

# ---------------------------------------------------------------------------
# AC1 — Script header invariants

@test "resolve-epic-slug: file exists and is executable" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
}

@test "resolve-epic-slug: has bash shebang" {
  run head -1 "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "#!/usr/bin/env bash" ]
}

@test "resolve-epic-slug: prelude has set -euo pipefail" {
  run grep -F 'set -euo pipefail' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "resolve-epic-slug: prelude pins LC_ALL=C" {
  run grep -F 'LC_ALL=C' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC2 — Resolves E79 to canonical live directory basename

@test "resolve-epic-slug: resolves E79 to canonical directory basename" {
  run "$SCRIPT" --epic-key E79 --epics-file "$(_fixture_epics_file)"
  [ "$status" -eq 0 ]
  [ "$output" = "epic-E79-canonical-per-epic-story-file-layout" ]
}

# ---------------------------------------------------------------------------
# AC4 — Sourceable invocation, single exposed function

@test "resolve-epic-slug: sourceable with zero side effects" {
  # Source the script in a clean subshell; verify zero stdout/stderr.
  run bash -c "set -euo pipefail; source '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "resolve-epic-slug: sourced function resolves E79 slug" {
  local epics; epics="$(_fixture_epics_file)"
  run bash -c "set -euo pipefail; source '$SCRIPT'; resolve_epic_slug E79 '$epics'"
  [ "$status" -eq 0 ]
  [ "$output" = "epic-E79-canonical-per-epic-story-file-layout" ]
}

# ---------------------------------------------------------------------------
# AC5 / TS3 — Auxiliary failure-mode coverage (NOT TC-CSP-traced)

@test "resolve-epic-slug: unknown epic key fails closed (exit 1)" {
  run "$SCRIPT" --epic-key E999 --epics-file "$(_fixture_epics_file)"
  [ "$status" -eq 1 ]
  # stderr names both the missing key and the resolved file path
  [[ "$output" == *"E999"* ]]
  [[ "$output" == *"epics-and-stories.md"* ]]
}

@test "resolve-epic-slug: missing --epics-file flag is usage error (exit 2)" {
  run "$SCRIPT" --epic-key E79
  [ "$status" -eq 2 ]
}

@test "resolve-epic-slug: missing --epic-key flag is usage error (exit 2)" {
  run "$SCRIPT" --epics-file "$(_fixture_epics_file)"
  [ "$status" -eq 2 ]
}

@test "resolve-epic-slug: -h prints usage and exits 0" {
  run "$SCRIPT" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"--epic-key"* ]]
  [[ "$output" == *"--epics-file"* ]]
}

# ---------------------------------------------------------------------------
# TS1 / TC-CSP-4 — Byte-identical slug for every fixture epic-{slug}/ dir
#
# This used to enumerate the operator's LIVE epic tree, which is absent in a
# published-source (gaia-public-only) CI checkout — so the live form could not
# pass in CI. It now runs against a hermetic in-repo fixture
# (tests/fixtures/resolve-epic-slug/) with clean, non-drifted slugs, making the
# assertion deterministic and CI-safe. Live-tree drift tolerance is a separate
# concern handled at runtime by the resolver's own logic, not by this test.

@test "resolve-epic-slug: TC-CSP-4 byte-identical to every fixture epic-{slug}/ dir" {
  # Hermetic: enumerate the fixture's epic-{slug}/ dirs and assert the resolver
  # reproduces each basename byte-for-byte from the fixture epics file. The
  # fixture carries clean (non-drifted) slugs only, so every dir must match.
  local epics_file; epics_file="$(_fixture_epics_file)"
  local impl_dir; impl_dir="$(_fixture_impl_dir)"
  local fail_lines=()
  local matched=0

  for dir in "$impl_dir"/epic-E*; do
    [ -d "$dir" ] || continue
    local base; base="$(basename "$dir")"
    local epic_key; epic_key="$(printf '%s' "$base" | sed -E 's/^epic-(E[0-9]+)-.*/\1/')"
    [ -n "$epic_key" ] || continue

    local out
    out="$("$SCRIPT" --epic-key "$epic_key" --epics-file "$epics_file" 2>&1)" || {
      fail_lines+=("$epic_key: resolver exited non-zero — $out")
      continue
    }
    if [ "$out" != "$base" ]; then
      fail_lines+=("$epic_key: expected='$base' got='$out'")
    else
      matched=$((matched + 1))
    fi
  done

  if [ "${#fail_lines[@]}" -gt 0 ]; then
    printf '%s\n' "${fail_lines[@]}" >&2
    return 1
  fi
  # The fixture has a known number of epic dirs; every one must match.
  local present; present="$(find "$impl_dir" -maxdepth 1 -type d -name 'epic-E*' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$matched" -eq "$present" ]
  [ "$matched" -ge 2 ]   # fixture carries at least two epics
}

@test "resolve-epic-slug: drift category — a name diverging from the title still resolves to a same-prefix slug" {
  # The drift categories (char-cap / parenthetical / &-substitution) are still
  # tolerated for LIVE trees via _drifted_dirs(); here we assert the resolver's
  # robustness property directly and hermetically: for a fixture epic, the
  # output is always `epic-<key>-<non-empty>`, never a wholly-divergent or
  # empty string — the property the live drift-allow-list relies on.
  local epics_file; epics_file="$(_fixture_epics_file)"
  local out
  out="$("$SCRIPT" --epic-key E79 --epics-file "$epics_file")"
  [[ "$out" == "epic-E79-"* ]]
  [ "$out" != "epic-E79-" ]
}

# ---------------------------------------------------------------------------
# TS2 / TC-CSP-5 — `mkdir -p` of the per-epic stories dir is idempotent

@test "resolve-epic-slug: TC-CSP-5 mkdir -p of per-epic stories dir is idempotent" {
  # Resolve the canonical E79 slug from the hermetic fixture.
  local slug
  slug="$("$SCRIPT" --epic-key E79 --epics-file "$(_fixture_epics_file)")"
  local target="$TEST_TMP/$slug/stories"

  # First mkdir -p — directory does not yet exist.
  run mkdir -p "$target"
  [ "$status" -eq 0 ]
  [ -d "$target" ]

  # Drop a marker file to detect any spurious recreation.
  : > "$target/.idempotency-marker"

  # Second mkdir -p — directory now exists. Must NOT raise an error
  # and MUST NOT remove or replace the marker.
  run mkdir -p "$target"
  [ "$status" -eq 0 ]
  [ -f "$target/.idempotency-marker" ]
}

# ---------------------------------------------------------------------------
# AC8 — Consumer adoption
#
# The original AC8 asserted NO consumer had been wired up yet (a "no premature
# rewiring" guard for the pre-adoption window). The resolver has since been
# adopted as the single source of truth for per-epic directory naming, so the
# inverted contract now holds: the canonical consumers MUST reference it. A
# zero-consumer result would now signal a regression (a consumer bypassing the
# resolver and re-deriving the slug inline).

@test "resolve-epic-slug: AC8 the resolver is wired into its canonical consumers" {
  # Plugin root derived from the test's own location (hermetic): tests live at
  # plugins/gaia/tests/lib/, so the plugin root is three levels up. This works
  # in a gaia-public-only CI checkout, unlike a project-root walk-up.
  local plugin_root; plugin_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  local hits
  hits="$(grep -rln "resolve-epic-slug\|resolve_epic_slug" \
      "$plugin_root/skills" "$plugin_root/scripts" 2>/dev/null \
      | grep -v "scripts/lib/resolve-epic-slug.sh" \
      | grep -v "tests/lib/resolve-epic-slug.bats" \
      || true)"
  # At least the story-writing path (create-story) and the status-transition
  # path must consume the resolver so they stay in sync on directory naming.
  printf '%s\n' "$hits" | grep -q "gaia-create-story"
  printf '%s\n' "$hits" | grep -q "transition-story-status.sh"
}
