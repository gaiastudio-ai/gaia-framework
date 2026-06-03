#!/usr/bin/env bats
# AF-2026-06-03-3 / E87-S12: downstream adversarial-sidecar consumer migration.
#
# Covers:
#   - read-adversarial-sidecar.sh: PREFER the .json sidecar (jq extraction of
#       status + findings[].{severity,id,title,location}); emit source=json.
#   - read-adversarial-sidecar.sh: FALL BACK to a .md regex-parse when the
#       sidecar is absent (back-compat for pre-E87-S11 reports); emit source=md.
#   - neither sidecar nor report → exit 1.
#   - CRITICAL extraction (risk-tier lift signal).
#   - the four consumers' docs name the helper + the sidecar-prefer/.md-fallback
#       contract:
#         1. agents/test-architect.md           (risk-tier mapping)
#         2. skills/gaia-sprint-review/SKILL.md  (aggregator)
#         3. skills/gaia-retro/SKILL.md          (pattern-detector, Step 5b)
#         4. skills/gaia-action-items/SKILL.md   (auto-file router)
#
# PLUGIN_ROOT is derived from $BATS_TEST_DIRNAME so the suite is resilient to a
# repo-rename flipping the CI checkout dir name. Only in-tree gaia-public
# artifacts are asserted.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  READER="$PLUGIN_ROOT/scripts/lib/read-adversarial-sidecar.sh"
  TEST_ARCH="$PLUGIN_ROOT/agents/test-architect.md"
  SPRINT_REVIEW="$PLUGIN_ROOT/skills/gaia-sprint-review/SKILL.md"
  RETRO="$PLUGIN_ROOT/skills/gaia-retro/SKILL.md"
  ACTION_ITEMS="$PLUGIN_ROOT/skills/gaia-action-items/SKILL.md"
  MD="$TEST_TMP/adversarial-review-prd-2026-06-03.md"
  JSON="$TEST_TMP/adversarial-review-prd-2026-06-03.json"
}

teardown() { common_teardown; }

_write_sidecar() {
  cat > "$JSON" <<'JSON'
{
  "review_type": "adversarial",
  "status": "CRITICAL",
  "target": "adversarial-review-prd-2026-06-03",
  "summary": "PRD sound but carries 1 critical assumption gap and 1 warning.",
  "findings": [
    {"severity": "CRITICAL", "id": "F-C1", "title": "Auth assumption", "location": "§3.2"},
    {"severity": "WARNING", "id": "F-W1", "title": "Scope creep", "location": "§4"}
  ],
  "next": "Incorporate F-C1 into PRD §3.2 before /gaia-create-arch."
}
JSON
}

_write_md() {
  cat > "$MD" <<'MD'
# Adversarial Review — PRD (2026-06-03)

**Reviewer:** Sage (adversarial-reviewer)
**Review date:** 2026-06-03

## Summary

PRD sound but carries 1 critical assumption gap and 1 warning.

## Findings

### CRITICAL

#### F-C1 — Auth assumption

- **Location:** §3.2 / line ~40
- **Risk:** auth blows up under adversarial conditions

### WARNING

#### F-W1 — Scope creep

- **Location:** §4
- **Risk:** rework

## Verdict

`CRITICAL` — per the highest-severity finding above.
MD
}

# ---------- AC1 / TS1: sidecar present → source=json, jq extraction ----------

@test "reader prefers the .json sidecar (source=json) and extracts status" {
  _write_sidecar
  run "$READER" --md-path "$MD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"source=json"* ]]
  [[ "$output" == *"status=CRITICAL"* ]]
}

@test "reader extracts each finding from the sidecar via jq" {
  _write_sidecar
  run "$READER" --md-path "$MD"
  [ "$status" -eq 0 ]
  # tab-separated severity/id/title/location, one per finding.
  [[ "$output" == *$'finding=CRITICAL\tF-C1\tAuth assumption\t§3.2'* ]]
  [[ "$output" == *$'finding=WARNING\tF-W1\tScope creep\t§4'* ]]
}

# ---------- AC4 / TS4: CRITICAL status extracted (risk-tier lift signal) ----------

@test "reader surfaces a CRITICAL status + finding for the risk-tier lift" {
  _write_sidecar
  run "$READER" --md-path "$MD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=CRITICAL"* ]]
  [[ "$output" == *$'finding=CRITICAL\t'* ]]
}

# ---------- AC6 / TS2: sidecar absent → .md regex-parse fallback ----------

@test "reader falls back to the .md parse when the sidecar is absent (source=md)" {
  _write_md   # NO sidecar written
  [ ! -f "$JSON" ]
  run "$READER" --md-path "$MD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"source=md"* ]]
  [[ "$output" == *"status=CRITICAL"* ]]
}

@test "reader .md fallback reconstructs findings from the prose" {
  _write_md
  run "$READER" --md-path "$MD"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'finding=CRITICAL\tF-C1\tAuth assumption\t'* ]]
  [[ "$output" == *$'finding=WARNING\tF-W1\tScope creep\t'* ]]
}

# ---------- TS3: neither report nor sidecar → exit 1 ----------

@test "reader exits 1 when neither the .md nor the .json exists" {
  [ ! -f "$MD" ] && [ ! -f "$JSON" ]
  run "$READER" --md-path "$MD"
  [ "$status" -eq 1 ]
}

@test "reader rejects a non-.md --md-path (usage error)" {
  run "$READER" --md-path "$TEST_TMP/foo.txt"
  [ "$status" -eq 2 ]
}

@test "reader exits 2 with no --md-path" {
  run "$READER"
  [ "$status" -eq 2 ]
}

# ---------- determinism: same sidecar → byte-identical reader output ----------

@test "reader output is deterministic across repeated runs (sidecar branch)" {
  _write_sidecar
  run "$READER" --md-path "$MD"; first="$output"
  run "$READER" --md-path "$MD"; second="$output"
  [ "$first" = "$second" ]
}

# ---------- AC2: test-architect consumer prose ----------

@test "test-architect.md names the reader helper + sidecar-prefer/.md-fallback" {
  grep -q "read-adversarial-sidecar.sh" "$TEST_ARCH"
  grep -q "Adversarial-Findings Intake" "$TEST_ARCH"
  grep -qi "risk.tier" "$TEST_ARCH"
  grep -qi "fall" "$TEST_ARCH"
}

# ---------- AC3: sprint-review consumer prose ----------

@test "gaia-sprint-review SKILL.md names the reader helper + fallback" {
  grep -q "read-adversarial-sidecar.sh" "$SPRINT_REVIEW"
  grep -qi "adversarial" "$SPRINT_REVIEW"
  grep -q "source=json" "$SPRINT_REVIEW"
}

# ---------- AC4: retro consumer prose ----------

@test "gaia-retro SKILL.md names the reader helper in pattern detection" {
  grep -q "read-adversarial-sidecar.sh" "$RETRO"
  grep -qi "Adversarial-findings input" "$RETRO"
}

# ---------- AC5: action-items consumer prose ----------

@test "gaia-action-items SKILL.md names the reader helper in the auto-file router" {
  grep -q "read-adversarial-sidecar.sh" "$ACTION_ITEMS"
  grep -qi "auto-file router" "$ACTION_ITEMS"
}
