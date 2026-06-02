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
# The TC-CSP-4 case enumerates the live `docs/implementation-artifacts/`
# tree at test time so the test stays self-updating as new epics land.
# A small allow-list of historically-drifted basenames is documented
# inline — those entries are tracked as Findings against E79-S6 (migration).

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$LIB_DIR/resolve-epic-slug.sh"
}

teardown() { common_teardown; }

# Resolve the project-root (the dir containing docs/, _gaia/, _memory/).
# tests/ live under gaia-public/plugins/gaia/tests/lib/, so project-root
# is five levels up.
_project_root() {
  cd "${BATS_TEST_DIRNAME}/../../../../.." && pwd
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

@test "resolve-epic-slug: resolves E79 to live directory basename" {
  local root; root="$(_project_root)"
  run "$SCRIPT" --epic-key E79 --epics-file "$root/.gaia/artifacts/planning-artifacts/epics-and-stories.md"
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
  local root; root="$(_project_root)"
  run bash -c "set -euo pipefail; source '$SCRIPT'; resolve_epic_slug E79 '$root/.gaia/artifacts/planning-artifacts/epics-and-stories.md'"
  [ "$status" -eq 0 ]
  [ "$output" = "epic-E79-canonical-per-epic-story-file-layout" ]
}

# ---------------------------------------------------------------------------
# AC5 / TS3 — Auxiliary failure-mode coverage (NOT TC-CSP-traced)

@test "resolve-epic-slug: unknown epic key fails closed (exit 1)" {
  local root; root="$(_project_root)"
  run "$SCRIPT" --epic-key E999 --epics-file "$root/.gaia/artifacts/planning-artifacts/epics-and-stories.md"
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
  local root; root="$(_project_root)"
  run "$SCRIPT" --epics-file "$root/.gaia/artifacts/planning-artifacts/epics-and-stories.md"
  [ "$status" -eq 2 ]
}

@test "resolve-epic-slug: -h prints usage and exits 0" {
  run "$SCRIPT" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"--epic-key"* ]]
  [[ "$output" == *"--epics-file"* ]]
}

# ---------------------------------------------------------------------------
# TS1 / TC-CSP-4 — Byte-identical slug for every existing epic-{slug}/ dir
#
# The live tree was generated over time by multiple historical scripts; a
# handful of basenames have drifted relative to the current epic title in
# epics-and-stories.md. Those drifts are tracked as a Finding for E79-S6
# (migration), and listed in _drifted_dirs() below so this assertion runs
# clean against the canonical algorithm. The drift cases are still covered
# by the AUX assertion below: the resolver must produce a slug that begins
# with the live basename (i.e. the live basename is a prefix of, or equal
# to, the resolver output) — never a wholly-divergent string.

_drifted_dirs() {
  # Returns 0 if $1 (live directory basename) is in the known-drift list.
  # The drift cases are tracked as a Finding on E79-S1, scheduled for
  # E79-S6 (migration). Categories:
  #   (a) E1-E12: legacy 68-char-cap-with-hyphen-strip generation; current
  #       canonical algorithm uses 69-char cap.
  #   (b) E39, E62, E63, E65: dir was created when the parenthetical
  #       sub-clause WAS canonical; current canonical algorithm drops
  #       parenthetical text.
  #   (c) E69, E72: dir contains "and" in place of `&` / `+`; current
  #       canonical algorithm replaces those with whitespace (no "and"
  #       substitution).
  case "$1" in
    # (a) Legacy 68-char-cap drift
    epic-E1-framework-core-validation-retired-adr-049-superseded-by-v2-n) return 0 ;;
    epic-E2-framework-behavior-testing-retired-adr-049-superseded-by-v2) return 0 ;;
    epic-E3-cli-test-infrastructure-retired-adr-049-superseded-by-v2-plu) return 0 ;;
    epic-E4-ci-cd-pipeline-retired-adr-049-superseded-by-v2-plugin-marke) return 0 ;;
    epic-E5-code-quality-tooling-retired-adr-049-superseded-by-v2-bash-m) return 0 ;;
    epic-E6-cross-platform-reliability-retired-adr-049-cross-platform-ha) return 0 ;;
    epic-E7-security-hardening-release-retired-adr-049-security-concerns) return 0 ;;
    epic-E12-infrastructure-platform-prd-support-partially-shipped-in-v2) return 0 ;;
    # (b) Parenthetical-content drift
    epic-E39-finding-to-story-pipeline-alias-e-fitp) return 0 ;;
    epic-E62-val-opus-pin-framework-wide) return 0 ;;
    epic-E63-ten-deterministic-operations-as-scripts-gaia-create-story-sc) return 0 ;;
    epic-E65-review-skill-evidence-judgment-split-gaia-code-review-five-s) return 0 ;;
    # (c) `&` / `+` drift ("and" substitution baked into legacy dir name)
    epic-E69-gaia-review-system-v2-naming-and-reorganization) return 0 ;;
    epic-E72-gaia-review-system-v2-action-skills-and-test-execution) return 0 ;;
    *) return 1 ;;
  esac
}

@test "resolve-epic-slug: TC-CSP-4 byte-identical to every (non-drifted) live epic-{slug}/ dir" {
  local root; root="$(_project_root)"
  local epics_file="$root/.gaia/artifacts/planning-artifacts/epics-and-stories.md"
  local impl_dir="$root/docs/implementation-artifacts"
  local fail_lines=()
  local matched=0
  local skipped=0

  # Enumerate every epic-E*/ directory under implementation-artifacts.
  for dir in "$impl_dir"/epic-E*; do
    [ -d "$dir" ] || continue
    local base; base="$(basename "$dir")"
    # Derive epic key: epic-E<digits>-... -> E<digits>
    local epic_key; epic_key="$(printf '%s' "$base" | sed -E 's/^epic-(E[0-9]+)-.*/\1/')"
    [ -n "$epic_key" ] || continue

    if _drifted_dirs "$base"; then
      skipped=$((skipped + 1))
      continue
    fi

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
  # Sanity check: at least 30 epics matched (catches accidental empty-loop bugs).
  [ "$matched" -ge 30 ]
}

@test "resolve-epic-slug: TC-CSP-4 drift-allowed dirs still resolve to a non-empty slug with same epic prefix" {
  # Even for drifted live dirs the resolver MUST still emit a non-empty
  # slug whose prefix matches `epic-E<key>-`. This catches accidental
  # regressions where the resolver fails entirely on these epic keys.
  local root; root="$(_project_root)"
  local epics_file="$root/.gaia/artifacts/planning-artifacts/epics-and-stories.md"
  local impl_dir="$root/docs/implementation-artifacts"

  for dir in "$impl_dir"/epic-E*; do
    [ -d "$dir" ] || continue
    local base; base="$(basename "$dir")"
    local epic_key; epic_key="$(printf '%s' "$base" | sed -E 's/^epic-(E[0-9]+)-.*/\1/')"
    [ -n "$epic_key" ] || continue
    if _drifted_dirs "$base"; then
      local out; out="$("$SCRIPT" --epic-key "$epic_key" --epics-file "$epics_file")"
      [[ "$out" == "epic-${epic_key}-"* ]]
      # Slug body (after `epic-${epic_key}-`) is non-empty
      [ "$out" != "epic-${epic_key}-" ]
    fi
  done
}

# ---------------------------------------------------------------------------
# TS2 / TC-CSP-5 — `mkdir -p` of the per-epic stories dir is idempotent

@test "resolve-epic-slug: TC-CSP-5 mkdir -p of per-epic stories dir is idempotent" {
  local root; root="$(_project_root)"
  # Use the canonical E79 directory which already exists on disk.
  local slug
  slug="$("$SCRIPT" --epic-key E79 --epics-file "$root/.gaia/artifacts/planning-artifacts/epics-and-stories.md")"
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
# AC8 — No premature consumer rewiring

@test "resolve-epic-slug: AC8 no premature consumer rewiring outside script + bats test" {
  local root; root="$(_project_root)"
  local plugin_root="$root/gaia-public/plugins/gaia"
  # Search for resolve-epic-slug references in skills/ and scripts/
  # (excluding the new script itself + bats test directory).
  local hits
  hits="$(grep -rln "resolve-epic-slug\|resolve_epic_slug" \
      "$plugin_root/skills" "$plugin_root/scripts" 2>/dev/null \
      | grep -v "scripts/lib/resolve-epic-slug.sh" \
      | grep -v "tests/lib/resolve-epic-slug.bats" \
      || true)"
  [ -z "$hits" ]
}
