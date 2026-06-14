#!/usr/bin/env bats
# skill-dispatch-brain-load.bats
#
# Guard: every SKILL.md that is a consultation-required dispatching stage per
# the reliance map MUST also LOAD its brain context via a brain-reliance-loader
# line in the same SKILL.md. A consultation-required stage with no such loader
# line runs brain-blind, so a regression that drops the consultation wiring is
# a CI failure.
#
# Structural twin of skill-dispatch-memory-load.bats: same GAP-line + exit-code
# contract (0=clean / 1=gaps / 2=usage|build-error). The join key differs — the
# memory audit keys on dispatched sidecar agents, this audit keys on the
# consultation-required stages declared in the reliance-map source of truth.
#
# Fail direction is the explicit inverse of the runtime loader: the loader
# fails OPEN (warn + exit 0) on a malformed map; this CI gate fails CLOSED
# (exit 2 build error) on the identical input.
#
# Dir-rename-resilient: PLUGIN_ROOT derives from BATS_TEST_DIRNAME, never a
# hard-coded repo/owner literal.

setup() {
  PLUGIN_ROOT="${BATS_TEST_DIRNAME}/.."
  AUDIT="${PLUGIN_ROOT}/scripts/audit-skill-brain-load.sh"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP"
}

# Build a throwaway plugin tree at $1 with the given map body ($2) and one
# skill ($3) whose SKILL.md body is $4.
_make_tree() {
  local root="$1" map_body="$2" skill="$3" skill_body="$4"
  mkdir -p "$root/skills/$skill"
  mkdir -p "$root/map"
  printf '%s\n' "$skill_body" > "$root/skills/$skill/SKILL.md"
  printf '%s\n' "$map_body" > "$root/map/brain-reliance-map.yaml"
}

@test "audit script exists and is executable" {
  [ -f "$AUDIT" ]
  [ -x "$AUDIT" ]
}

# TC: a consultation-required dispatching skill that loads NO brain context is
# flagged with a GAP line and exits 1.
@test "consultation-required skill with no brain loader is flagged and exits 1" {
  _make_tree "$TMP" \
'stages:
  fixture-blind:entry:
    requires:
      - brain_node: some-node
        obligation: MANDATORY' \
    "fixture-blind" \
'---
name: fixture-blind
---
## Step 1
Dispatch via subagent_type: validator without loading any brain context.'

  run "$AUDIT" --plugin "$TMP" --map "$TMP/map/brain-reliance-map.yaml"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'GAP'
  echo "$output" | grep -q 'fixture-blind'
}

# TC: a clean repo where every consultation-required skill loads its brain
# context emits no GAP lines and exits 0.
@test "consultation-required skill that loads brain context exits 0 with no gaps" {
  _make_tree "$TMP" \
'stages:
  fixture-ok:entry:
    requires:
      - brain_node: some-node
        obligation: MANDATORY' \
    "fixture-ok" \
'---
name: fixture-ok
---
## Brain
!${CLAUDE_PLUGIN_ROOT}/scripts/brain/brain-reliance-loader.sh fixture-ok:entry
## Step 1
Dispatch via subagent_type: validator.'

  run "$AUDIT" --plugin "$TMP" --map "$TMP/map/brain-reliance-map.yaml"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'GAP'
}

# TC: a malformed reliance map at build time fails CLOSED with exit 2 — the
# explicit inverse of the runtime loader's fail-OPEN on identical input.
@test "malformed reliance map fails CLOSED with exit 2" {
  _make_tree "$TMP" \
'stages:
  fixture: [ this is not: valid: yaml : : :
    requires oops' \
    "fixture-ok" \
'---
name: fixture-ok
---
## Brain
!${CLAUDE_PLUGIN_ROOT}/scripts/brain/brain-reliance-loader.sh fixture-ok:entry'

  run "$AUDIT" --plugin "$TMP" --map "$TMP/map/brain-reliance-map.yaml"
  [ "$status" -eq 2 ]
}

# TC: an empty / seed-only map (no stages) declares no consultation-required
# scope, so there is nothing to audit — no gaps, exit 0.
@test "empty reliance map (no stages) is clean and exits 0" {
  _make_tree "$TMP" \
'stages: {}' \
    "fixture-blind" \
'---
name: fixture-blind
---
## Step 1
No brain loader here, but no stage declared so nothing to audit.'

  run "$AUDIT" --plugin "$TMP" --map "$TMP/map/brain-reliance-map.yaml"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'GAP'
}

# TC: scope is derived from the map, not a hard-coded list — adding a second
# consultation-required stage extends coverage without a code change, and the
# audit flags the one that is brain-blind while passing the one that loads.
@test "audit derives scope from the map and flags only the brain-blind stage" {
  mkdir -p "$TMP/skills/skill-loads" "$TMP/skills/skill-blind" "$TMP/map"
  printf '%s\n' \
'stages:
  skill-loads:entry:
    requires:
      - brain_node: node-a
        obligation: MANDATORY
  skill-blind:entry:
    requires:
      - brain_node: node-b
        obligation: MANDATORY' > "$TMP/map/brain-reliance-map.yaml"
  printf '%s\n' \
'---
name: skill-loads
---
!${CLAUDE_PLUGIN_ROOT}/scripts/brain/brain-reliance-loader.sh skill-loads:entry' \
    > "$TMP/skills/skill-loads/SKILL.md"
  printf '%s\n' \
'---
name: skill-blind
---
## Step 1
no brain loader' > "$TMP/skills/skill-blind/SKILL.md"

  run "$AUDIT" --plugin "$TMP" --map "$TMP/map/brain-reliance-map.yaml"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'skill-blind'
  ! echo "$output" | grep -q 'GAP  skill-loads'
}
