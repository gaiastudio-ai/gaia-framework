#!/usr/bin/env bats
# val-bridge-anti-pattern.bats — durable CI regression guard for E87 (Val Bridge Migration).
#
# Story: E87-S6 — Bats anti-pattern check + SKILL.md changelog cascade + AI audit-note resolution + memory closures (TAIL).
# Anchor: ADR-104 — Val Bridge Migration: Main-Turn Agent Dispatch Across Val-Consuming Skills.
#
# Coverage:
#   TC-VBR-5    — Anti-pattern: no `context: fork` Val-dispatch references in
#                 any of the 5 migrated SKILL.md files. Filter-allow legitimate
#                 historical / migration-callout / Changelog references via the
#                 same regex pattern stabilized progressively across E87-S2..S5.
#   TC-VBR-6    — Anti-pattern: no `inline Val` / `auto-judged` / `main-turn
#                 inline validation` self-judgment fallthrough prose in
#                 Val-dispatch contexts. Same filter-allow regex.
#   TC-VBR-meta — All 5 migrated SKILL.md files contain ADR-104 reference
#                 (Changelog entries landed by E87-S2..S5).
#
# Per memory rule `gaia-shell-idioms`: anti-pattern scans use awk state-machine
# extraction (not awk-range pattern) — extract the file content then grep
# within, applying the filter-allow regex line-by-line.
#
# The 5 migrated SKILL.md files (the canonical set per E87):
#   gaia-val-validate   — E87-S2 (entry point)
#   gaia-validate-story — E87-S3 (Component 4)
#   gaia-fix-story      — E87-S3 (Step 5 re-validation)
#   gaia-dev-story      — E87-S4 (Steps 4 + 7b)
#   gaia-add-feature    — E87-S5 (Step 2 Val gate, LAST self-referential)

load 'test_helper.bash'

PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

MIGRATED_SKILLS=(
  "gaia-val-validate"
  "gaia-validate-story"
  "gaia-fix-story"
  "gaia-dev-story"
  "gaia-add-feature"
)

# Filter-allow regex — exempts lines that legitimately reference the prior
# `context: fork` model: Changelog entries (dated `YYYY-MM-DD — E87-S*` rows),
# migration callouts, historical-ADR precedent notes, MUST-NOT prose, the
# "No inline Val" Critical Rule (negative prose that names the antipattern
# to forbid it). Pattern stabilized across E87-S2..S6 with progressive
# refinement (see TC-VBR-7b/9c/10b/11c filter regex history).
FILTER_ALLOW='Changelog|\(removed\)|Removed `context: fork`|from `context: fork`|removed the|no longer|MUST NOT|do NOT|migrated|prior to E87|prior model|historically|precedent|sequential `context: fork`|No inline Val|^- \*\*[0-9]{4}-[0-9]{2}-[0-9]{2}'

setup() { common_setup; }
teardown() { common_teardown; }

# ============================================================================
# TC-VBR-5 — context: fork anti-pattern absent from all 5 migrated SKILL.md
# ============================================================================
@test "TC-VBR-5: no 'context: fork' Val-dispatch refs in 5 migrated SKILL.md files" {
  local violations=""
  for slug in "${MIGRATED_SKILLS[@]}"; do
    local file="$PLUGIN_ROOT/skills/$slug/SKILL.md"
    [ -f "$file" ] || { echo "MISSING: $file"; return 1; }
    # Extract the full file content; grep for context:[space]*fork; filter-allow
    # known-legitimate callouts. Any remaining match is a violation.
    local hits
    hits=$(grep -E 'context:[[:space:]]*fork' "$file" 2>/dev/null | grep -v -E "$FILTER_ALLOW" || true)
    if [ -n "$hits" ]; then
      violations+="${file}:"$'\n'"$hits"$'\n'
    fi
  done
  if [ -n "$violations" ]; then
    printf 'TC-VBR-5 anti-pattern violations:\n%s\n' "$violations" >&2
    return 1
  fi
}

# ============================================================================
# TC-VBR-6 — self-judgment fallthrough prose absent from Val-dispatch contexts
# ============================================================================
@test "TC-VBR-6: no 'inline Val' / 'auto-judged' / 'main-turn inline validation' self-judgment prose in 5 migrated SKILL.md files" {
  local violations=""
  for slug in "${MIGRATED_SKILLS[@]}"; do
    local file="$PLUGIN_ROOT/skills/$slug/SKILL.md"
    [ -f "$file" ] || { echo "MISSING: $file"; return 1; }
    local hits
    hits=$(grep -E 'inline Val|auto-judged|main-turn inline validation' "$file" 2>/dev/null | grep -v -E "$FILTER_ALLOW" || true)
    if [ -n "$hits" ]; then
      violations+="${file}:"$'\n'"$hits"$'\n'
    fi
  done
  if [ -n "$violations" ]; then
    printf 'TC-VBR-6 anti-pattern violations:\n%s\n' "$violations" >&2
    return 1
  fi
}

# ============================================================================
# TC-VBR-meta — all 5 migrated SKILL.md files contain ADR-104 reference
# ============================================================================
@test "TC-VBR-meta: all 5 migrated SKILL.md files contain ADR-104 reference (Changelog cascade)" {
  local missing=""
  for slug in "${MIGRATED_SKILLS[@]}"; do
    local file="$PLUGIN_ROOT/skills/$slug/SKILL.md"
    [ -f "$file" ] || { echo "MISSING: $file"; return 1; }
    if ! grep -q 'ADR-104' "$file"; then
      missing+="$file "
    fi
  done
  if [ -n "$missing" ]; then
    printf 'TC-VBR-meta: SKILL.md files missing ADR-104 reference: %s\n' "$missing" >&2
    return 1
  fi
}
