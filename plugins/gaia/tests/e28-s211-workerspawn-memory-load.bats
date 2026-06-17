#!/usr/bin/env bats
# E28-S211 — WorkerSpawn memory-load check
#
# Asserts that each of the 20 WorkerSpawn skills (Bucket 3 from E28-S206
# audit) embeds a canonical `memory-loader.sh {agent-id} {tier}` invocation
# inside its SKILL.md body. This operationalizes FR-331 (Hybrid memory
# loading) for the WorkerSpawn bucket per story E28-S211.
#
# AC1 — All 20 SKILL.md files include the canonical memory-loader invocation
#       with a valid agent-id + tier argument (tier ∈ {decision-log,
#       ground-truth, all}).
# AC3 — The validator check script (scripts/validate-workerspawn-memory.sh)
#       exists and exits 0 when every skill complies; exits non-zero when a
#       deliberate corruption is introduced. This bats file drives AC3 via
#       direct grep-level assertions so the CI gate does not depend on the
#       validator script being wired into a larger validate-framework entry
#       point (see plan v4 note: validator check is standalone for E28-S211).

setup() {
  PLUGIN_ROOT="${BATS_TEST_DIRNAME}/.."
  SKILLS_DIR="${PLUGIN_ROOT}/skills"
  MANIFEST="${PLUGIN_ROOT}/skills/_workerspawn-manifest.yaml"
  VALIDATOR="${PLUGIN_ROOT}/scripts/validate-workerspawn-memory.sh"
}

# Canonical skill → expected persona(s) + tier(s) mapping for the 20
# WorkerSpawn skills. Derived from E28-S206 Bucket 3 audit and the story's
# Task 3.x per-skill persona/tier assignments, with two deviations documented
# in the PR description:
#   - gaia-readiness-check uses architect + devops (matches skill code) rather
#     than the story's Task 3.15 shorthand "architect + pm".
#   - gaia-brownfield currently has only a prose mention of memory-loader;
#     the canonical block uses architect (the primary persona brownfield
#     delegates its architecture-generation phase to).
@test "each WorkerSpawn skill contains canonical memory-loader invocation" {
  # skill:agent:tier triples; multi-dispatch skills have multiple entries.
  declare -a expected=(
    "gaia-add-feature:pm:decision-log"
    "gaia-add-stories:pm:all"
    "gaia-add-stories:architect:all"
    "gaia-brownfield:architect:all"
    "gaia-create-arch:architect:all"
    "gaia-create-epics:architect:all"
    "gaia-create-epics:pm:all"
    "gaia-create-prd:pm:all"
    "gaia-create-ux:ux-designer:decision-log"
    "gaia-creative-sprint:design-thinking-coach:decision-log"
    "gaia-creative-sprint:problem-solver:decision-log"
    "gaia-creative-sprint:innovation-strategist:decision-log"
    "gaia-edit-arch:architect:all"
    "gaia-edit-prd:pm:all"
    "gaia-edit-ux:ux-designer:decision-log"
    "gaia-infra-design:devops:decision-log"
    "gaia-pitch-deck:presentation-designer:decision-log"
    "gaia-problem-solving:problem-solver:decision-log"
    "gaia-readiness-check:architect:all"
    "gaia-readiness-check:devops:decision-log"
    "gaia-slide-deck:presentation-designer:decision-log"
    "gaia-storytelling:storyteller:decision-log"
    "gaia-test-design:test-architect:all"
    "gaia-threat-model:security:decision-log"
    "gaia-validate-prd:validator:all"
  )

  for triple in "${expected[@]}"; do
    IFS=':' read -r skill agent tier <<< "$triple"
    skill_md="${SKILLS_DIR}/${skill}/SKILL.md"
    [ -f "$skill_md" ] || { echo "missing: $skill_md"; false; }
    # Look for the canonical block: memory-loader.sh <agent> <tier>
    pattern="memory-loader\\.sh ${agent} ${tier}"
    if ! grep -Eq "$pattern" "$skill_md"; then
      echo "FAIL: ${skill} missing canonical memory-loader invocation"
      echo "  expected: ${pattern}"
      echo "  agent:    ${agent}"
      echo "  tier:     ${tier}"
      false
    fi
  done
}

@test "every invocation uses a valid tier argument" {
  # Scan each WorkerSpawn skill for memory-loader lines; every line must
  # use one of decision-log | ground-truth | all.
  skills="gaia-add-feature gaia-add-stories gaia-brownfield gaia-create-arch \
gaia-create-epics gaia-create-prd gaia-create-ux gaia-creative-sprint \
gaia-edit-arch gaia-edit-prd gaia-edit-ux gaia-infra-design gaia-pitch-deck \
gaia-problem-solving gaia-readiness-check gaia-slide-deck gaia-storytelling \
gaia-test-design gaia-threat-model gaia-validate-prd"

  for skill in $skills; do
    skill_md="${SKILLS_DIR}/${skill}/SKILL.md"
    [ -f "$skill_md" ] || { echo "missing: $skill_md"; false; }
    # Extract only the lines that execute memory-loader.sh via the `!` bash
    # convention. Comments and prose mentions are skipped.
    while IFS= read -r line; do
      # Parse out the tier argument (3rd whitespace-separated token after
      # the memory-loader.sh filename).
      tier=$(echo "$line" | sed -E 's|.*memory-loader\.sh[[:space:]]+[a-z][a-z0-9-]*[[:space:]]+([a-z-]+).*|\1|')
      case "$tier" in
        decision-log|ground-truth|all) ;;
        *)
          echo "FAIL: ${skill} has invalid tier '${tier}' in line: ${line}"
          false
          ;;
      esac
    done < <(grep -E '^!.*memory-loader\.sh' "$skill_md" || true)
  done
}

@test "validator script exists and is executable" {
  [ -f "$VALIDATOR" ]
  [ -x "$VALIDATOR" ]
}

@test "validator exits 0 when every WorkerSpawn skill complies" {
  run "$VALIDATOR" --plugin-root "$PLUGIN_ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "CLEAN"
}

@test "validator fails when a skill's memory-loader invocation is missing" {
  # Deliberately corrupt one skill in a temp copy of the plugin tree and
  # run the validator against the copy. This proves the check is not a
  # no-op.
  tmp_root="$(mktemp -d)"
  cp -R "$PLUGIN_ROOT/skills" "$tmp_root/skills"
  cp -R "$PLUGIN_ROOT/scripts" "$tmp_root/scripts"

  # Remove the memory-loader.sh line from gaia-create-arch
  target="${tmp_root}/skills/gaia-create-arch/SKILL.md"
  sed -i.bak '/memory-loader\.sh architect/d' "$target"
  rm -f "$target.bak"

  run "$VALIDATOR" --plugin-root "$tmp_root"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "gaia-create-arch"

  rm -rf "$tmp_root"
}

@test "validator fails when a skill's memory-loader tier is malformed" {
  tmp_root="$(mktemp -d)"
  cp -R "$PLUGIN_ROOT/skills" "$tmp_root/skills"
  cp -R "$PLUGIN_ROOT/scripts" "$tmp_root/scripts"

  # Corrupt the tier arg on gaia-threat-model
  target="${tmp_root}/skills/gaia-threat-model/SKILL.md"
  sed -i.bak 's|memory-loader\.sh security decision-log|memory-loader.sh security decsion-log|' "$target"
  rm -f "$target.bak"

  run "$VALIDATOR" --plugin-root "$tmp_root"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "gaia-threat-model"

  rm -rf "$tmp_root"
}

@test "WorkerSpawn manifest lists exactly 20 skills" {
  [ -f "$MANIFEST" ]
  # Count skill entries (lines beginning with "- name:").
  count=$(grep -c -E '^\s*-\s+name:' "$MANIFEST")
  [ "$count" -eq 20 ]
}

# NFR-052 coverage: parse_manifest is a public function in validate-workerspawn-memory.sh
# and must be exercised directly. Source the script with MANIFEST pointed at a
# minimal fixture and assert the tab-separated output is well-formed.
@test "parse_manifest emits tab-separated skill/agent/tier triples from manifest" {
  # Build a minimal manifest fixture with 2 skills, one multi-persona.
  tmp_dir="$(mktemp -d)"
  cat > "${tmp_dir}/manifest.yaml" <<'YAML'
skills:
  - name: fake-skill-a
    personas:
      - agent_id: validator
        tier: decision-log
  - name: fake-skill-b
    personas:
      - agent_id: architect
        tier: all
      - agent_id: pm
        tier: ground-truth
YAML

  # Extract parse_manifest function definition from the validator and call it
  # against our fixture. sed range '/^parse_manifest/,/^}/' isolates the
  # function body without sourcing the script's main execution path.
  func_def="$(sed -n '/^parse_manifest()/,/^}/p' "$VALIDATOR")"

  run bash -c "
    MANIFEST='${tmp_dir}/manifest.yaml'
    ${func_def}
    parse_manifest
  "
  [ "$status" -eq 0 ]
  # Must include all three expected triples.
  echo "$output" | grep -qF $'fake-skill-a\tvalidator\tdecision-log'
  echo "$output" | grep -qF $'fake-skill-b\tarchitect\tall'
  echo "$output" | grep -qF $'fake-skill-b\tpm\tground-truth'

  rm -rf "$tmp_dir"
}
