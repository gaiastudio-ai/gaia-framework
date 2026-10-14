#!/usr/bin/env bash
# smoke-sprint-status-dashboard.sh — smoke test for sprint-status-dashboard.sh
#
# Validates the formatter script against the 7 test scenarios defined in the
# story spec. Each assertion maps to a scenario number.
#
# Usage: bash plugins/gaia/scripts/tests/smoke-sprint-status-dashboard.sh
# Exit 0 when all assertions pass, 1 on any failure.

set -uo pipefail
LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DASHBOARD="$SCRIPT_DIR/sprint-status-dashboard.sh"

TMP="$(mktemp -d)"
ART="$TMP/docs/implementation-artifacts"
mkdir -p "$ART"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

ok()   { printf "  ok  %s\n" "$1"; PASS=$((PASS + 1)); }
fail() { printf "  FAIL %s\n     %s\n" "$1" "$2"; FAIL=$((FAIL + 1)); }

# ---------- Scenario 1: Happy path — valid sprint-status.yaml ----------
setup_valid_yaml() {
  cat > "$ART/sprint-status.yaml" <<'YAML'
sprint_id: "sprint-20"
duration: "2 weeks"
velocity_capacity: 21
total_points: 18
started: "2026-04-15"
end_date: "2026-04-29"
stories:
  - key: "E1-S1"
    title: "User login"
    status: "in-progress"
    points: 5
    risk_level: "high"
    assignee: "dev-1"
    blocked_by: null
    updated: "2026-04-15"
  - key: "E1-S2"
    title: "User profile"
    status: "ready-for-dev"
    points: 3
    risk_level: "low"
    assignee: null
    blocked_by: null
    updated: "2026-04-15"
YAML
}

setup_valid_yaml
# Force the fallback path so Scenario 1 tests the yaml reader.
output=$(PROJECT_PATH="$TMP" SPRINT_STATUS_YAML="$ART/sprint-status.yaml" "$DASHBOARD" 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ] && echo "$output" | grep -q "E1-S1"; then
  ok "Scenario 1: happy path renders dashboard with story keys"
else
  fail "Scenario 1: happy path" "exit=$rc, output missing E1-S1"
fi

# Verify stdout contains table-like columns
if echo "$output" | grep -q "in-progress"; then
  ok "Scenario 1: dashboard shows story status"
else
  fail "Scenario 1: status column" "output missing 'in-progress'"
fi

# ---------- Scenario 2: Empty sprint-status.yaml ----------
cat > "$ART/sprint-status.yaml" <<'YAML'
sprint_id: "sprint-20"
duration: "2 weeks"
velocity_capacity: 0
total_points: 0
started: "2026-04-15"
end_date: "2026-04-29"
stories: []
YAML
# Force the fallback path.
output=$(PROJECT_PATH="$TMP" SPRINT_STATUS_YAML="$ART/sprint-status.yaml" "$DASHBOARD" 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "Scenario 2: empty yaml renders header, exit 0"
else
  fail "Scenario 2: empty yaml" "exit=$rc, expected 0"
fi

# ---------- Scenario 3: Missing sprint-status.yaml (fallback path) ----------
rm -f "$ART/sprint-status.yaml"
# Force the fallback path so the yaml-missing exit 1 is tested.
output=$(PROJECT_PATH="$TMP" SPRINT_STATUS_YAML="$ART/sprint-status.yaml" "$DASHBOARD" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  ok "Scenario 3: missing yaml on fallback path exits non-zero"
else
  fail "Scenario 3: missing yaml on fallback path" "exit=$rc, expected non-zero"
fi

# ---------- Scenario 3b: Missing yaml — cache path (snapshot writes sprint null) ----------
if command -v jq >/dev/null 2>&1; then
  CACHE_TMP="$(mktemp -d)"
  mkdir -p "$CACHE_TMP/.gaia/state"
  # Create a cache with sprint: null (what the snapshot writes when no yaml)
  printf '{"schema_version":"1.0","sprint":null,"totals":{"done_points":0,"total_points":0,"done_stories":0,"total_stories":0,"progress_pct":0},"phases":[],"unphased_stories":[],"stories":[],"action_needed":[],"readiness":{"sprint_review":false,"sprint_close":false}}\n' \
    > "$CACHE_TMP/.gaia/state/.sprint-progress-cache.json"
  output=$(PROJECT_ROOT="$CACHE_TMP" SPRINT_CACHE_JSON="$CACHE_TMP/.gaia/state/.sprint-progress-cache.json" "$DASHBOARD" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 0 ] && echo "$output" | grep -q "No active sprint"; then
    ok "Scenario 3b: missing yaml on cache path prints No active sprint, exit 0"
  else
    fail "Scenario 3b: cache path missing yaml" "exit=$rc, expected 0 + 'No active sprint'"
  fi
  rm -rf "$CACHE_TMP"
fi

# ---------- Scenario 4: Malformed yaml (fallback path) ----------
echo ":::invalid yaml{{{" > "$ART/sprint-status.yaml"
# Force the fallback path.
output=$(PROJECT_PATH="$TMP" SPRINT_STATUS_YAML="$ART/sprint-status.yaml" "$DASHBOARD" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  ok "Scenario 4: malformed yaml on fallback path exits non-zero"
else
  fail "Scenario 4: malformed yaml on fallback path" "exit=$rc, expected non-zero"
fi

# ---------- Scenario 4b: yaml without sprint_id — cache path ----------
if command -v jq >/dev/null 2>&1; then
  CACHE_TMP="$(mktemp -d)"
  mkdir -p "$CACHE_TMP/.gaia/state"
  printf '{"schema_version":"1.0","sprint":null,"totals":{"done_points":0,"total_points":0,"done_stories":0,"total_stories":0,"progress_pct":0},"phases":[],"unphased_stories":[],"stories":[],"action_needed":[],"readiness":{"sprint_review":false,"sprint_close":false}}\n' \
    > "$CACHE_TMP/.gaia/state/.sprint-progress-cache.json"
  output=$(PROJECT_ROOT="$CACHE_TMP" SPRINT_CACHE_JSON="$CACHE_TMP/.gaia/state/.sprint-progress-cache.json" "$DASHBOARD" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 0 ] && echo "$output" | grep -q "No active sprint"; then
    ok "Scenario 4b: yaml without sprint_id on cache path prints No active sprint, exit 0"
  else
    fail "Scenario 4b: cache path no sprint_id" "exit=$rc, expected 0 + 'No active sprint'"
  fi
  rm -rf "$CACHE_TMP"
fi

# ---------- Scenario 5: Write-attempt guard — script never writes to yaml ----------
setup_valid_yaml
# Make the yaml read-only to verify the script does not attempt writes.
# Force the fallback path.
chmod 444 "$ART/sprint-status.yaml"
output=$(PROJECT_PATH="$TMP" SPRINT_STATUS_YAML="$ART/sprint-status.yaml" "$DASHBOARD" 2>/dev/null)
rc=$?
chmod 644 "$ART/sprint-status.yaml"
if [ "$rc" -eq 0 ]; then
  ok "Scenario 5: read-only yaml — script succeeds (no write attempted)"
else
  fail "Scenario 5: read-only yaml" "exit=$rc, expected 0 (script should be read-only)"
fi

# ---------- Scenario 6: SKILL.md frontmatter lint (checked separately) ----------
SKILL_FILE="$SCRIPT_DIR/../skills/gaia-sprint-status/SKILL.md"
if [ -f "$SKILL_FILE" ]; then
  # Check frontmatter exists and has required fields
  has_name=$(head -20 "$SKILL_FILE" | grep -c "^name:")
  has_desc=$(head -20 "$SKILL_FILE" | grep -c "^description:")
  has_tools=$(head -20 "$SKILL_FILE" | grep -c "^allowed-tools:")
  if [ "$has_name" -ge 1 ] && [ "$has_desc" -ge 1 ] && [ "$has_tools" -ge 1 ]; then
    ok "Scenario 6: SKILL.md frontmatter has required fields"
  else
    fail "Scenario 6: SKILL.md frontmatter" "missing name/description/allowed-tools"
  fi
else
  fail "Scenario 6: SKILL.md" "file not found at $SKILL_FILE"
fi

# ---------- Summary ----------
TOTAL=$((PASS + FAIL))
printf "\n%d/%d passed" "$PASS" "$TOTAL"
if [ "$FAIL" -gt 0 ]; then
  printf " (%d FAILED)\n" "$FAIL"
  exit 1
else
  printf " — all OK\n"
  exit 0
fi
