#!/usr/bin/env bats
# af-2026-05-27-4-doc-clarity.bats
#
# AF-2026-05-27-4 / Test05 F-018, F-024, F-017, F-021, F-019, F-022, F-039,
# F-035, F-001 (doc-clarity bundle). F-044 banner reword is covered by
# sprint-status-dashboard-auto-close-banner.bats.

load 'test_helper.bash'

setup() {
  common_setup
  P="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}
teardown() { common_teardown; }

# ---------- F-018: a11y duplicate Mission removed ----------

@test "F-018: gaia-review-a11y SKILL.md has exactly ONE ## Mission heading" {
  local n
  n=$(grep -cE '^## Mission$' "$P/skills/gaia-review-a11y/SKILL.md")
  [ "$n" -eq 1 ]
}

# ---------- F-024: deprecation warning text codified ----------

@test "F-024: gaia-test-design SKILL.md codifies the deprecation warning text" {
  grep -qiF 'deprecated' "$P/skills/gaia-test-design/SKILL.md"
  grep -qF '/gaia-test-strategy --plan' "$P/skills/gaia-test-design/SKILL.md"
  grep -qiE 'VERBATIM|first line of output|FIRST line' "$P/skills/gaia-test-design/SKILL.md"
}

@test "F-024: gaia-test-framework SKILL.md codifies the deprecation warning text" {
  grep -qF '/gaia-test-strategy --scaffold' "$P/skills/gaia-test-framework/SKILL.md"
  grep -qiE 'VERBATIM|FIRST line' "$P/skills/gaia-test-framework/SKILL.md"
}

# ---------- F-017 / F-021: --output override documented ----------

@test "F-017: gaia-review-a11y documents an --output override + precedence" {
  grep -qF -- '--output' "$P/skills/gaia-review-a11y/SKILL.md"
  grep -qF 'GAIA_A11Y_REPORT_PATH' "$P/skills/gaia-review-a11y/SKILL.md"
}

@test "F-021: gaia-review-api documents an --output override + precedence" {
  grep -qF -- '--output' "$P/skills/gaia-review-api/SKILL.md"
  grep -qF 'GAIA_API_REVIEW_REPORT_PATH' "$P/skills/gaia-review-api/SKILL.md"
}

# ---------- F-019 / F-022: create-arch subagent checkpoint advisory ----------

@test "F-019/F-022: gaia-create-arch documents checkpoint-advisory + Step 10-13 handoff in subagent mode" {
  grep -qiE 'advisory in subagent|best-effort' "$P/skills/gaia-create-arch/SKILL.md"
  grep -qiE 'exit after Step 9|Steps 10.13' "$P/skills/gaia-create-arch/SKILL.md"
}

# ---------- F-039: security-review tool-availability note ----------

@test "F-039: gaia-review-security states the no-hard-dependency on Semgrep/gitleaks + loud-skip" {
  grep -qiF 'no hard dependency' "$P/skills/gaia-review-security/SKILL.md"
  grep -qiE 'Static scan tool unavailable|ran LLM-pattern scan only' "$P/skills/gaia-review-security/SKILL.md"
}

# ---------- F-035: dev-story documents GAIA_YOLO_MODE subagent export ----------

@test "F-035: gaia-dev-story documents exporting GAIA_YOLO_MODE for subagent dispatch" {
  grep -qF 'GAIA_YOLO_MODE=1' "$P/skills/gaia-dev-story/SKILL.md"
  grep -qiE 'subagent.*inherit|inherit.*yolo|export it explicitly|set it explicitly per dispatch' "$P/skills/gaia-dev-story/SKILL.md"
}

# ---------- F-001: orchestration-warning once-per-session rationale ----------

@test "F-001: orchestration-warning.sh documents the once-per-session by-design rationale" {
  grep -qiE 'once per session|per-session' "$P/scripts/orchestration-warning.sh"
}
