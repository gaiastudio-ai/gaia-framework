#!/usr/bin/env bats
# e101-s3-document-architecture-location.bats
#
# Story: E101-S3 — DOCUMENT path: README clarifies architecture lives
#   under planning-artifacts/architecture/ (not under architecture-artifacts/).
# Origin: AF-2026-05-24-1; supersedes E101-S2 per ADR-118 DOCUMENT decision.
# Traces to: FR-530, ADR-118, TC-AAT-3.

load 'test_helper.bash'

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  # Project-root-evidence fixture; skip outside the project-root workspace.
  if [ ! -f "$REPO_ROOT/.gaia/artifacts/README.md" ]; then
    skip "project-root .gaia/artifacts/README.md not present — skipping story-evidence fixture"
  fi
  README="$REPO_ROOT/.gaia/artifacts/README.md"
  PLUGIN_ROOT="$REPO_ROOT/gaia-framework/plugins/gaia"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# TC-AAT-3a — README exists at .gaia/artifacts/README.md
# ---------------------------------------------------------------------------

@test "TC-AAT-3a: .gaia/artifacts/README.md exists" {
  [ -f "$README" ]
}

# ---------------------------------------------------------------------------
# TC-AAT-3b — README contains the explicit "no architecture-artifacts/ phase"
# statement (semantic equivalent — pattern allows minor phrasing variation).
# ---------------------------------------------------------------------------

@test "TC-AAT-3b: README states there is no architecture-artifacts/ phase directory" {
  [ -f "$README" ]
  grep -qE "no \`?architecture-artifacts/?\`? phase" "$README"
}

# ---------------------------------------------------------------------------
# TC-AAT-3c — README names planning-artifacts/architecture/ as the
# architecture root.
# ---------------------------------------------------------------------------

@test "TC-AAT-3c: README names planning-artifacts/architecture/ as architecture root" {
  [ -f "$README" ]
  grep -q "planning-artifacts/architecture/" "$README"
}

# ---------------------------------------------------------------------------
# TC-AAT-3d — README cross-references ADR-118
# ---------------------------------------------------------------------------

@test "TC-AAT-3d: README references ADR-118" {
  [ -f "$README" ]
  grep -q "ADR-118" "$README"
}

# ---------------------------------------------------------------------------
# TC-AAT-3e — grep sweep across the plugin returns only allowlisted hits.
# Allowlist: anything under tests/ (bats fixtures for E101-S1 and E101-S3)
# is allowed because those fixtures legitimately reference the
# architecture-artifacts string in test names and assertion patterns.
# ---------------------------------------------------------------------------

@test "TC-AAT-3e: plugin grep sweep for architecture-artifacts has only allowlisted hits" {
  cd "$REPO_ROOT"
  # Get all hits, then exclude allowlisted paths.
  hits="$(grep -rln "architecture-artifacts" gaia-framework/plugins/gaia/ 2>/dev/null || true)"
  if [ -z "$hits" ]; then
    return 0
  fi
  # Filter: drop files under tests/ (allowlisted).
  unexpected="$(printf '%s\n' "$hits" | grep -v "^gaia-framework/plugins/gaia/tests/" || true)"
  if [ -n "$unexpected" ]; then
    echo "Unexpected architecture-artifacts hits outside the test allowlist:" >&2
    printf '%s\n' "$unexpected" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# TC-AAT-3f — none of the four audited SKILL.md files contain prose implying
# architecture-artifacts/ is a real phase.
# ---------------------------------------------------------------------------

@test "TC-AAT-3f: four audited SKILL.md files free of architecture-artifacts implication" {
  for skill in gaia-create-arch gaia-create-epics gaia-test-strategy gaia-adversarial; do
    skill_md="$PLUGIN_ROOT/skills/$skill/SKILL.md"
    [ -f "$skill_md" ] || continue
    ! grep -qE "architecture-artifacts/|architecture-artifacts phase" "$skill_md"
  done
}
