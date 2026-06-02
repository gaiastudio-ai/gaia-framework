#!/usr/bin/env bats
# AF-2026-06-02-2 — Repo rename `gaia-public` → `gaia-framework`.
#
# Verifies that every operational reference has been rewritten to the new
# slug, and that CHANGELOG history entries are intentionally preserved
# (per the AF's design — GitHub redirect keeps old links live).
#
# Bash-3.2 compatible; wired into the cross-platform-portability matrix.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
}

teardown() { common_teardown; }

# ===========================================================================
# F-01 — Critical operational items point at gaia-framework
# ===========================================================================

@test "AF-33-2 F-01: plugin.json homepage points at gaia-framework" {
  run grep -F '"homepage": "https://github.com/gaiastudio-ai/gaia-framework"' \
    "$PLUGIN_ROOT/.claude-plugin/plugin.json"
  [ "$status" -eq 0 ]
}

@test "AF-33-2 F-01: statusline-update-check.sh API endpoint targets gaia-framework" {
  run grep -F 'repos/gaiastudio-ai/gaia-framework/releases/latest' \
    "$PLUGIN_ROOT/scripts/statusline-update-check.sh"
  [ "$status" -eq 0 ]
}

@test "AF-33-2 F-01: statusline-update-check.sh https API endpoint targets gaia-framework" {
  run grep -F 'api.github.com/repos/gaiastudio-ai/gaia-framework/releases/latest' \
    "$PLUGIN_ROOT/scripts/statusline-update-check.sh"
  [ "$status" -eq 0 ]
}

@test "AF-33-2 F-01: statusline.sh OSC8 release-link targets gaia-framework" {
  run grep -F 'github.com/gaiastudio-ai/gaia-framework/releases/tag' \
    "$PLUGIN_ROOT/scripts/statusline.sh"
  [ "$status" -eq 0 ]
}

@test "AF-33-2 F-01: plugin-cache directory slug uses gaia-framework" {
  run grep -F 'gaiastudio-ai-gaia-framework' "$PLUGIN_ROOT/scripts/statusline-update-check.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-02 — User-facing install instructions
# ===========================================================================

@test "AF-33-2 F-02: README install command names gaia-framework" {
  run grep -F '/plugin marketplace add gaiastudio-ai/gaia-framework' "$REPO_ROOT/README.md"
  [ "$status" -eq 0 ]
}

@test "AF-33-2 F-02: CLAUDE.md install citation names gaia-framework" {
  run grep -F '/plugin marketplace add gaiastudio-ai/gaia-framework' "$REPO_ROOT/CLAUDE.md"
  [ "$status" -eq 0 ]
}

@test "AF-33-2 F-02: gaia-migrate SKILL.md install hint names gaia-framework" {
  run grep -F '/plugin marketplace add gaiastudio-ai/gaia-framework' \
    "$PLUGIN_ROOT/skills/gaia-migrate/SKILL.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-03 — Documentation site URL
# ===========================================================================

@test "AF-33-2 F-03: CLAUDE.md docs site URL points at gaia-framework Pages" {
  run grep -F 'gaiastudio-ai.github.io/gaia-framework' "$REPO_ROOT/CLAUDE.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-04 — CHANGELOG entry documents the rename
# ===========================================================================

@test "AF-33-2 F-04: CHANGELOG.md describes the rename + GitHub redirect contract" {
  run grep -F 'AF-2026-06-02-2' "$REPO_ROOT/CHANGELOG.md"
  [ "$status" -eq 0 ]
  run grep -F 'gaiastudio-ai/gaia-public' "$REPO_ROOT/CHANGELOG.md"
  [ "$status" -eq 0 ]
  run grep -F 'gaiastudio-ai/gaia-framework' "$REPO_ROOT/CHANGELOG.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-05 — Anti-regression: NO active operational reference still names gaia-public
# ===========================================================================

@test "AF-33-2 F-05: no active operational reference to gaiastudio-ai/gaia-public outside CHANGELOGs" {
  # The CHANGELOG files intentionally preserve historical URLs. The
  # AF-33-2 bats file itself names the old token in its anti-regression
  # grep patterns by necessity; exclude it. Every other tracked file MUST
  # point at gaia-framework.
  run bash -c "
    grep -rln 'gaiastudio-ai/gaia-public' '$REPO_ROOT' \
      --include='*.sh' --include='*.json' --include='*.yaml' --include='*.yml' \
      --include='*.html' --include='*.js' --include='*.mjs' --include='*.ts' \
      --include='*.py' --include='*.csv' --include='*.bats' --include='*.md' \
      2>/dev/null \
      | grep -v 'CHANGELOG\\.md$' \
      | grep -v 'af-2026-06-02-2-rename-gaia-public-to-gaia-framework\\.bats$' \
      | head -5
  "
  [ -z "$output" ]
}

@test "AF-33-2 F-05: no active operational reference to gaiastudio-ai-gaia-public outside CHANGELOGs" {
  run bash -c "
    grep -rln 'gaiastudio-ai-gaia-public' '$REPO_ROOT' \
      --include='*.sh' --include='*.json' --include='*.yaml' --include='*.yml' \
      --include='*.html' --include='*.js' --include='*.mjs' --include='*.ts' \
      --include='*.py' --include='*.csv' --include='*.bats' --include='*.md' \
      2>/dev/null \
      | grep -v 'CHANGELOG\\.md$' \
      | grep -v 'af-2026-06-02-2-rename-gaia-public-to-gaia-framework\\.bats$' \
      | head -5
  "
  [ -z "$output" ]
}

# ===========================================================================
# F-06 — Repo-name H1 heading updated in README
# ===========================================================================

@test "AF-33-2 F-06: README H1 names gaia-framework" {
  run grep -E '^# gaia-framework' "$REPO_ROOT/README.md"
  [ "$status" -eq 0 ]
}
