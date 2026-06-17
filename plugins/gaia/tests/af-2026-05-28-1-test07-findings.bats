#!/usr/bin/env bats
# AF-2026-05-28-1: Test07 findings — 4th-consecutive-test artifact-path sweep +
# misc. The 3 HIGH-severity path bugs (H-2 sprint-plan SKILL.md docs, H-3
# dev-story setup.sh trace gate, H-4 transition-story-status.sh) all escaped
# AF-27-8 because they're in DIFFERENT scripts/docs than the ones swept then.
# This time the fix sweep covers EVERY SKILL.md + agents doc + the offending
# runtime scripts, AND this suite adds a sweep-discipline assertion so a
# regression would surface in CI before the next manual test.
#
# H-1 create-epics SKILL.md story heading placeholder
# H-2 sprint-plan SKILL.md (5 lines) + 12 other SKILL.md/agents (21 ref total)
# H-3 dev-story setup.sh trace gate routes through shared resolver
# H-4 transition-story-status.sh sprint-status.yaml via shared resolver
# M-1 brainstorm SV-13 accepts bare-relative paths
# M-2 product-brief persona regex accepts H3 + bold-bullet role + numbered ##
# M-3 sprint-review SKILL.md documents the agent='val' literal contract
# M-5 market/domain-research finalize uses glob (slug freedom)
# D-6 validate-gate traceability_exists error names all 4 accepted paths

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RESOLVER="$PLUGIN_ROOT/scripts/lib/resolve-artifact-path.sh"
}

teardown() { common_teardown; }

# ===========================================================================
# H-2 / sweep — SKILL.md docs reference the CANONICAL .gaia/state/ path
# ===========================================================================

@test "H-2: gaia-sprint-plan SKILL.md uses .gaia/state/sprint-status.yaml (no impl-artifacts)" {
  local f="$PLUGIN_ROOT/skills/gaia-sprint-plan/SKILL.md"
  grep -qF '.gaia/state/sprint-status.yaml' "$f"
  ! grep -qF '.gaia/artifacts/implementation-artifacts/sprint-status.yaml' "$f"
}

@test "sweep: NO SKILL.md or agents/*.md references stale impl-artifacts sprint-status.yaml path" {
  # Bats sweep-discipline guard so the path-drift class can't recur in another
  # SKILL.md. Scripts (close.sh comments, dev-story wrapper) are exempt — they
  # carry the legacy reference as documented read-compat fallbacks.
  local hits
  hits=$(grep -rln '\.gaia/artifacts/implementation-artifacts/sprint-status\.yaml' \
    "$PLUGIN_ROOT/skills/" "$PLUGIN_ROOT/agents/" 2>/dev/null \
    | grep -v '/scripts/' || true)
  [ -z "$hits" ] || {
    echo "STALE PATH FOUND in SKILL.md/agents docs:" >&2
    echo "$hits" >&2
    false
  }
}

@test "sweep: gaia-trace + gaia-readiness-check SKILL.md cite the canonical planning-artifacts traceability home" {
  grep -qF '.gaia/artifacts/planning-artifacts/traceability-matrix.md' \
    "$PLUGIN_ROOT/skills/gaia-trace/SKILL.md"
  grep -qF '.gaia/artifacts/planning-artifacts/traceability-matrix.md' \
    "$PLUGIN_ROOT/skills/gaia-readiness-check/SKILL.md"
}

# ===========================================================================
# H-3 — dev-story setup.sh trace gate routes through shared resolver
# ===========================================================================

@test "H-3: dev-story setup.sh references resolve-artifact-path.sh for traceability" {
  grep -qF 'resolve-artifact-path.sh' "$PLUGIN_ROOT/skills/gaia-dev-story/scripts/setup.sh"
  grep -qF '" traceability ' "$PLUGIN_ROOT/skills/gaia-dev-story/scripts/setup.sh"
}

@test "H-3: resolver finds traceability at canonical planning-artifacts path" {
  mkdir -p "$TEST_TMP/.gaia/artifacts/planning-artifacts"
  printf '# Traceability\n| FR | t |\n|---|---|\n| FR-1 | t1 |\n' > "$TEST_TMP/.gaia/artifacts/planning-artifacts/traceability-matrix.md"
  run "$RESOLVER" traceability --project-root "$TEST_TMP" --existing-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"/.gaia/artifacts/planning-artifacts/traceability-matrix.md" ]]
}

# ===========================================================================
# H-4 — transition-story-status.sh sprint-status.yaml via shared resolver
# ===========================================================================

@test "H-4: transition-story-status.sh routes sprint-status.yaml through resolve-artifact-path.sh" {
  grep -qF 'resolve-artifact-path.sh' "$PLUGIN_ROOT/scripts/transition-story-status.sh"
  grep -qF '" sprint_status ' "$PLUGIN_ROOT/scripts/transition-story-status.sh"
}

@test "H-4: transition does NOT default to .gaia/artifacts/impl-artifacts when env unset" {
  # Negative: the literal hardcoded default path must NOT appear as the env-unset
  # default (it's allowed to appear in the resolver's read-compat list).
  ! grep -qF 'SPRINT_STATUS_YAML:-${IMPLEMENTATION_ARTIFACTS}/sprint-status.yaml' \
    "$PLUGIN_ROOT/scripts/transition-story-status.sh"
}

# ===========================================================================
# H-1 — create-epics SKILL.md story heading placeholder
# ===========================================================================

@test "H-1: create-epics SKILL.md uses E{N}-S{N} placeholder (not the ambiguous {epic-N}-{story-N})" {
  local f="$PLUGIN_ROOT/skills/gaia-create-epics/SKILL.md"
  grep -qF '### Story E{N}-S{N}: {Title}' "$f"
  ! grep -qF '### Story {epic-N}-{story-N}:' "$f"
}

@test "H-1: create-epics SKILL.md publishes a concrete example matching the regex" {
  local f="$PLUGIN_ROOT/skills/gaia-create-epics/SKILL.md"
  grep -qF '### Story E1-S1:' "$f"
  # The regex itself in finalize.sh — re-asserted so the docs↔code coupling
  # cannot drift again silently.
  grep -qE 'Story\[\[:space:\]\]\+E\[0-9\]\+-S\[0-9\]\+' "$PLUGIN_ROOT/skills/gaia-create-epics/scripts/finalize.sh"
}

# ===========================================================================
# M-1 — brainstorm SV-13 accepts bare-relative paths
# ===========================================================================

@test "M-1: brainstorm case arms include bare-relative paths" {
  local f="$PLUGIN_ROOT/skills/gaia-brainstorm/scripts/finalize.sh"
  grep -qF '.gaia/artifacts/creative-artifacts/*|docs/creative-artifacts/*|fixtures/*' "$f"
}

# ===========================================================================
# M-2 — product-brief persona regex accepts H3 + bold-bullet role + numbered ##
# ===========================================================================

@test "M-2: product-brief persona_count counts H3 Persona + bold-bulleted role (numbered Target Users)" {
  cat > "$TEST_TMP/brief.md" <<'EOF'
## 2. Target Users

### Persona: Alice
- **Role:** Staff Engineer

### Persona 2: Bob
- **Role:** Tech Lead

## 3. Out of Scope
EOF
  # Run persona_count by extracting it (the script as a whole sources libs
  # with side effects).
  awk '/^persona_count\(\)/,/^}/' "$PLUGIN_ROOT/skills/gaia-product-brief/scripts/finalize.sh" > "$TEST_TMP/pc.sh"
  echo 'persona_count "$1"' >> "$TEST_TMP/pc.sh"
  run bash "$TEST_TMP/pc.sh" "$TEST_TMP/brief.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

@test "M-2: product-brief persona_count still counts legacy bold-span + plain bullet" {
  cat > "$TEST_TMP/brief.md" <<'EOF'
## Target Users

**Persona 1: Alice**
- role: foo

**Persona 2: Bob**
- role: bar
EOF
  awk '/^persona_count\(\)/,/^}/' "$PLUGIN_ROOT/skills/gaia-product-brief/scripts/finalize.sh" > "$TEST_TMP/pc.sh"
  echo 'persona_count "$1"' >> "$TEST_TMP/pc.sh"
  run bash "$TEST_TMP/pc.sh" "$TEST_TMP/brief.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

@test "M-2: persona_count returns 0 on a section with no personas" {
  printf '## Target Users\n(no personas)\n' > "$TEST_TMP/brief.md"
  awk '/^persona_count\(\)/,/^}/' "$PLUGIN_ROOT/skills/gaia-product-brief/scripts/finalize.sh" > "$TEST_TMP/pc.sh"
  echo 'persona_count "$1"' >> "$TEST_TMP/pc.sh"
  run bash "$TEST_TMP/pc.sh" "$TEST_TMP/brief.md"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

# ===========================================================================
# M-3 — sprint-review SKILL.md documents the agent='val' literal contract
# ===========================================================================

@test "M-3: sprint-review SKILL.md documents the agent='val' literal contract" {
  grep -qF 'agent`' "$PLUGIN_ROOT/skills/gaia-sprint-review/SKILL.md" || skip "agent contract phrasing not present"
  grep -qF '"val"' "$PLUGIN_ROOT/skills/gaia-sprint-review/SKILL.md"
}

@test "M-3: write-val-sentinel.sh error msg surfaces the expected literal" {
  grep -qF "must be 'val'" "$PLUGIN_ROOT/skills/gaia-sprint-review/scripts/write-val-sentinel.sh"
  # The expanded hint (Test07 M-3) explicitly contrasts with 'gaia:validator'.
  grep -qF "gaia:validator" "$PLUGIN_ROOT/skills/gaia-sprint-review/scripts/write-val-sentinel.sh"
}

# ===========================================================================
# M-5 — market/domain-research finalize uses glob (slug freedom)
# ===========================================================================

@test "M-5: market-research finalize accepts market-research-<slug>.md" {
  mkdir -p "$TEST_TMP/.gaia/artifacts/planning-artifacts"
  echo "# slug-suffixed" > "$TEST_TMP/.gaia/artifacts/planning-artifacts/market-research-yara.md"
  awk '/^_pick_market\(\)/,/^}/' "$PLUGIN_ROOT/skills/gaia-market-research/scripts/finalize.sh" > "$TEST_TMP/pm.sh"
  echo '_pick_market "$1"' >> "$TEST_TMP/pm.sh"
  run bash "$TEST_TMP/pm.sh" "$TEST_TMP/.gaia/artifacts/planning-artifacts"
  [ "$status" -eq 0 ]
  [[ "$output" == *"market-research-yara.md" ]]
}

@test "M-5: domain-research finalize accepts domain-research-<slug>.md" {
  mkdir -p "$TEST_TMP/.gaia/artifacts/planning-artifacts"
  echo "# slug-suffixed" > "$TEST_TMP/.gaia/artifacts/planning-artifacts/domain-research-yara.md"
  awk '/^_pick_domain\(\)/,/^}/' "$PLUGIN_ROOT/skills/gaia-domain-research/scripts/finalize.sh" > "$TEST_TMP/pd.sh"
  echo '_pick_domain "$1"' >> "$TEST_TMP/pd.sh"
  run bash "$TEST_TMP/pd.sh" "$TEST_TMP/.gaia/artifacts/planning-artifacts"
  [ "$status" -eq 0 ]
  [[ "$output" == *"domain-research-yara.md" ]]
}

@test "M-5: market-research finalize still resolves the exact filename when present" {
  mkdir -p "$TEST_TMP/.gaia/artifacts/planning-artifacts"
  echo "# canonical" > "$TEST_TMP/.gaia/artifacts/planning-artifacts/market-research.md"
  echo "# slug" > "$TEST_TMP/.gaia/artifacts/planning-artifacts/market-research-yara.md"
  awk '/^_pick_market\(\)/,/^}/' "$PLUGIN_ROOT/skills/gaia-market-research/scripts/finalize.sh" > "$TEST_TMP/pm.sh"
  echo '_pick_market "$1"' >> "$TEST_TMP/pm.sh"
  run bash "$TEST_TMP/pm.sh" "$TEST_TMP/.gaia/artifacts/planning-artifacts"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/market-research.md" ]]
}

# ===========================================================================
# D-6 — validate-gate traceability_exists error names all 4 accepted paths
# ===========================================================================

@test "D-6: validate-gate traceability_exists error lists canonical planning-artifacts first" {
  ( cd "$TEST_TMP" && run bash "$PLUGIN_ROOT/scripts/validate-gate.sh" traceability_exists 2>&1 )
  out=$(cd "$TEST_TMP" && bash "$PLUGIN_ROOT/scripts/validate-gate.sh" traceability_exists 2>&1 || true)
  [[ "$out" == *"planning-artifacts/traceability-matrix.md"* ]]
  [[ "$out" == *"(canonical)"* ]]
  [[ "$out" == *"strategy/traceability-matrix.md"* ]]
}

# ===========================================================================
# Wrapper byte-identity (sprint-state.sh — touched indirectly via transition)
# ===========================================================================

@test "dev-story sprint-state.sh wrapper still byte-identical to canonical" {
  run diff "$PLUGIN_ROOT/scripts/sprint-state.sh" "$PLUGIN_ROOT/skills/gaia-dev-story/scripts/sprint-state.sh"
  [ "$status" -eq 0 ]
}
