#!/usr/bin/env bash
# test-validate-subagents.sh — unit tests for validate-subagents.sh (E28-S23)
#
# Exercises validate-subagents.sh against a synthetic fixture directory
# (temp MEMORY_PATH + temp agents dir) to assert AC1..AC6 without mutating
# the real _memory/ or plugins/gaia/agents/ trees.
#
# Usage: bash gaia-framework/tests/test-validate-subagents.sh
# Exit 0 when all assertions pass, 1 on any failure.

set -uo pipefail
LC_ALL=C

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VAL="$REPO_ROOT/tests/validate-subagents.sh"
LOADER="$REPO_ROOT/plugins/gaia/scripts/memory-loader.sh"

if [ ! -f "$VAL" ]; then
  echo "NOTE: $VAL not found yet (expected during RED phase)" >&2
fi

PASS=0
FAIL=0
ok()   { printf "  ok  %s\n" "$1"; PASS=$((PASS + 1)); }
fail() { printf "  FAIL %s\n     %s\n" "$1" "$2"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Build a fixture: 3 agents (1 tier-1, 1 tier-2, 1 tier-3) under a fake plugin dir
FAKE_AGENTS="$TMP/plugins/gaia/agents"
FAKE_MEMORY="$TMP/_memory"
mkdir -p "$FAKE_AGENTS" "$FAKE_MEMORY"

# Minimal _memory/config.yaml — validator is Tier 1, orchestrator Tier 2, typescript-dev Tier 3
cat > "$FAKE_MEMORY/config.yaml" <<'YAML'
tiers:
  tier_1:
    label: Rich
    agents: [validator]
  tier_2:
    label: Standard
    agents: [orchestrator]
  tier_3:
    label: Simple
    agents: [typescript-dev]
agents:
  validator:
    sidecar: validator-sidecar
  orchestrator:
    sidecar: orchestrator-sidecar
  typescript-dev:
    sidecar: typescript-dev-sidecar
YAML

# Seed agent .md files with canonical frontmatter + persona marker
mk_agent() {
  local id="$1" persona="$2"
  cat > "$FAKE_AGENTS/${id}.md" <<EOF
---
name: $id
model: claude-opus-4-6
description: $persona — fixture agent for E28-S23 tests.
context: main
allowed-tools: [Read]
---

## Memory

!\${PLUGIN_DIR}/scripts/memory-loader.sh $id all

## Persona

You are **$persona**, the fixture.

## Rules

- Be deterministic for tests.
EOF
}

mk_agent validator "Val"
mk_agent orchestrator "Gaia"
mk_agent typescript-dev "Cleo"

# Seed sidecars with canary phrases
mkdir -p "$FAKE_MEMORY/validator-sidecar"
printf 'GT-CANARY-VALIDATOR-%s\n' "$$" > "$FAKE_MEMORY/validator-sidecar/ground-truth.md"
printf 'DL-CANARY-VALIDATOR-%s\n' "$$" > "$FAKE_MEMORY/validator-sidecar/decision-log.md"

mkdir -p "$FAKE_MEMORY/orchestrator-sidecar"
printf 'DL-CANARY-ORCH-%s\n' "$$" > "$FAKE_MEMORY/orchestrator-sidecar/decision-log.md"

mkdir -p "$FAKE_MEMORY/typescript-dev-sidecar"
printf 'DL-CANARY-TS-%s\n' "$$" > "$FAKE_MEMORY/typescript-dev-sidecar/decision-log.md"

OUT_MATRIX="$TMP/out-matrix.md"

# --------------------------------------------------------------------------
echo "== AC1/AC4: happy path — all fixture agents load, exit 0, matrix emitted =="
rc=0
AGENTS_DIR="$FAKE_AGENTS" \
MEMORY_PATH="$FAKE_MEMORY" \
MEMORY_LOADER="$LOADER" \
MATRIX_OUT="$OUT_MATRIX" \
  bash "$VAL" > "$TMP/happy.log" 2>&1 || rc=$?

if [ "$rc" = "0" ]; then ok "happy path exit 0"; else fail "happy path exit 0" "rc=$rc; log=$(cat "$TMP/happy.log")"; fi
if [ -f "$OUT_MATRIX" ]; then ok "matrix file written"; else fail "matrix file written" "not found at $OUT_MATRIX"; fi
if grep -q '^| agent ' "$OUT_MATRIX" 2>/dev/null; then ok "matrix has header row"; else fail "matrix has header row" "$(head "$OUT_MATRIX" 2>/dev/null)"; fi
for a in validator orchestrator typescript-dev; do
  if grep -q "| $a " "$OUT_MATRIX" 2>/dev/null; then ok "matrix row: $a"; else fail "matrix row: $a" "$(cat "$OUT_MATRIX")"; fi
done
# in-persona column shows PASS (persona marker check via frontmatter name)
if grep -E '^\| validator .*PASS' "$OUT_MATRIX" >/dev/null; then ok "validator row PASS"; else fail "validator row PASS" "$(grep validator "$OUT_MATRIX")"; fi

# --------------------------------------------------------------------------
echo "== AC2: canary phrase surfaces via memory-loader =="
# The matrix memory column should be PASS for all three (canaries seeded).
if grep -E '^\| validator .*\| PASS .*\| PASS' "$OUT_MATRIX" >/dev/null; then ok "validator memory PASS"; else fail "validator memory PASS" "$(grep validator "$OUT_MATRIX")"; fi

# --------------------------------------------------------------------------
echo "== AC3: Tier-1 hybrid — ground-truth + decision-log both present =="
# validator row tier-1-ground-truth column PASS
if grep -E '^\| validator .*\| PASS +\|' "$OUT_MATRIX" >/dev/null; then ok "validator tier-1 hybrid PASS"; else fail "validator tier-1 hybrid PASS" "$(grep validator "$OUT_MATRIX")"; fi

# --------------------------------------------------------------------------
echo "== AC3 FAIL path: Tier-1 missing ground-truth.md => row FAIL and non-zero exit =="
rm -f "$FAKE_MEMORY/validator-sidecar/ground-truth.md"
rc=0
AGENTS_DIR="$FAKE_AGENTS" \
MEMORY_PATH="$FAKE_MEMORY" \
MEMORY_LOADER="$LOADER" \
MATRIX_OUT="$TMP/out-missing-gt.md" \
  bash "$VAL" > "$TMP/missing-gt.log" 2>&1 || rc=$?
if [ "$rc" != "0" ]; then ok "missing-gt exit non-zero"; else fail "missing-gt exit non-zero" "rc=0"; fi
if grep -E '^\| validator .*FAIL' "$TMP/out-missing-gt.md" >/dev/null; then ok "validator row FAIL on missing gt"; else fail "validator row FAIL on missing gt" "$(cat "$TMP/out-missing-gt.md")"; fi
# restore
printf 'GT-CANARY-VALIDATOR-RESTORED\n' > "$FAKE_MEMORY/validator-sidecar/ground-truth.md"

# --------------------------------------------------------------------------
echo "== Load fail: malformed frontmatter => load column FAIL, non-zero exit =="
cp "$FAKE_AGENTS/typescript-dev.md" "$TMP/ts-good.bak"
# remove closing frontmatter delimiter
sed -i.bak '2,6d' "$FAKE_AGENTS/typescript-dev.md"
rc=0
AGENTS_DIR="$FAKE_AGENTS" \
MEMORY_PATH="$FAKE_MEMORY" \
MEMORY_LOADER="$LOADER" \
MATRIX_OUT="$TMP/out-malformed.md" \
  bash "$VAL" > "$TMP/malformed.log" 2>&1 || rc=$?
if [ "$rc" != "0" ]; then ok "malformed exit non-zero"; else fail "malformed exit non-zero" "rc=0"; fi
if grep -E '^\| typescript-dev .*FAIL' "$TMP/out-malformed.md" >/dev/null; then ok "malformed load FAIL"; else fail "malformed load FAIL" "$(cat "$TMP/out-malformed.md")"; fi
# restore
cp "$TMP/ts-good.bak" "$FAKE_AGENTS/typescript-dev.md"

# --------------------------------------------------------------------------
echo "== AC4: matrix header columns present =="
AGENTS_DIR="$FAKE_AGENTS" \
MEMORY_PATH="$FAKE_MEMORY" \
MEMORY_LOADER="$LOADER" \
MATRIX_OUT="$OUT_MATRIX" \
  bash "$VAL" > /dev/null 2>&1 || true
for col in agent load in-persona memory tier-1-ground-truth status; do
  if grep -q "$col" "$OUT_MATRIX" 2>/dev/null; then ok "matrix col: $col"; else fail "matrix col: $col" "$(head -3 "$OUT_MATRIX")"; fi
done

# --------------------------------------------------------------------------
echo
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
