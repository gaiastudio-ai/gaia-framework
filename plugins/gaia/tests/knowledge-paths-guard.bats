#!/usr/bin/env bats
# knowledge-paths-guard.bats — E28-S194 + E28-S196 regression guard for
# plugin-shipped reference data.
#
# Stories:
#   - E28-S194 — Retire `_gaia/_config/*.csv` literal paths from 15 SKILL.md
#     files and ship CSVs inside the plugin's knowledge/ tree.
#   - E28-S196 — Retire remaining `_gaia/_config/*` paths from 12 SKILL.md
#     files, ship 4 additional files (manifest.yaml, adversarial-triggers.yaml,
#     agent-manifest.csv, lifecycle-sequence.yaml) to plugin knowledge/, and
#     drop the `_gaia/_config/global.yaml` reference entirely in favor of
#     ADR-044 targets (project-config.yaml keys, resolve-config.sh output).
#
# After E28-S190 audit bucket B3, every non-project/non-machine-local v1 config
# file MUST live inside plugins/gaia/knowledge/ so the affected skills resolve
# them via ${CLAUDE_PLUGIN_ROOT}/knowledge/<file> instead of the legacy v1
# path _gaia/_config/<file> — which disappears after /gaia-migrate apply
# deletes _gaia/.

load test_helper

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  KNOWLEDGE_DIR="$PLUGIN_ROOT/knowledge"
  SKILLS_DIR="$PLUGIN_ROOT/skills"
  export PLUGIN_ROOT KNOWLEDGE_DIR SKILLS_DIR
}

teardown() { common_teardown; }

# ---------- AC1, AC2: CSVs ship inside the plugin ----------

@test "plugins/gaia/knowledge/gaia-help.csv exists" {
  [ -f "$KNOWLEDGE_DIR/gaia-help.csv" ]
}

@test "plugins/gaia/knowledge/workflow-manifest.csv exists" {
  [ -f "$KNOWLEDGE_DIR/workflow-manifest.csv" ]
}

@test "AC9a: gaia-help.csv is non-empty" {
  [ -s "$KNOWLEDGE_DIR/gaia-help.csv" ]
}

@test "AC9b: workflow-manifest.csv is non-empty" {
  [ -s "$KNOWLEDGE_DIR/workflow-manifest.csv" ]
}

# ---------- AC6: SKILL.md prose drops legacy CSV literal paths ----------
#
# Scope note: the story (E28-S194) targets the two CSVs that bucket B3 of the
# E28-S190 audit flagged — gaia-help.csv and workflow-manifest.csv. AC6's
# "grep returns 0 matches" reads broadly, but its intent (per the story title
# "Retire _gaia/_config/*.csv literal paths") and the AC4/AC5 specificity
# constrain the scope to CSV references. Non-CSV references (global.yaml,
# manifest.yaml, adversarial-triggers.yaml, lifecycle-sequence.yaml,
# agent-manifest.csv) remain out of scope for this story and are flagged in
# Findings for a follow-up cleanup pass.

@test "no SKILL.md contains an unprefixed _gaia/_config/<csv> path for the two B3 CSVs" {
  # The two B3 CSVs MUST NOT appear under the legacy _gaia/_config/ path.
  # Any other _gaia/_config/* reference is deliberately out of scope here.
  local hits remaining
  hits="$(grep -rn -E '_gaia/_config/(gaia-help|workflow-manifest)\.csv' "$SKILLS_DIR"/*/SKILL.md 2>/dev/null || true)"
  if [ -z "$hits" ]; then
    return 0
  fi
  remaining="$(printf '%s\n' "$hits" | grep -viE 'legacy v1|no longer used|historical|legacy location|pre-migration' || true)"
  if [ -n "$remaining" ]; then
    echo "SKILL.md still references the legacy v1 path _gaia/_config/<csv> outside a 'legacy' qualifier:"
    printf '  %s\n' "$remaining"
    return 1
  fi
}

@test "every PATH reference to gaia-help.csv or workflow-manifest.csv inside SKILL.md uses the plugin knowledge path" {
  # Scope: only LITERAL PATH references — i.e., the CSV filename appears with
  # a directory prefix like `_gaia/_config/<csv>` or `${CLAUDE_PLUGIN_ROOT}/knowledge/<csv>`.
  # Bare filename mentions ("see workflow-manifest.csv", "the gaia-help.csv columns")
  # are conceptual references — the LLM does not Read them. They are NOT path
  # references and so are out of scope for AC4/AC5.
  #
  # A "path reference" is a match where the CSV filename is preceded by a `/`
  # in the same word (i.e., the filename has at least one path segment to its left).
  local bad
  bad="$(grep -rnE '[A-Za-z_/\$\{\}]+/(gaia-help|workflow-manifest)\.csv' "$SKILLS_DIR"/*/SKILL.md 2>/dev/null \
         | grep -v 'knowledge/' \
         | grep -viE 'legacy v1|no longer used|historical|legacy location|pre-migration' \
         || true)"
  if [ -n "$bad" ]; then
    echo "SKILL.md path reference to one of the two CSVs without the plugin knowledge/ path:"
    printf '  %s\n' "$bad"
    return 1
  fi
}

# =============================================================================
# E28-S196 — 4 additional files + global.yaml drop
# =============================================================================
#
# Scope:
#   - AC1..AC4: 4 new files present and non-empty in plugins/gaia/knowledge/.
#   - AC14: no SKILL.md contains a literal _gaia/_config/(global|manifest|
#           adversarial-triggers|agent-manifest|lifecycle-sequence) path
#           outside a "legacy v1"-qualified prose block.
#   - AC15 consistency guard: every agent-id in agent-manifest.csv has a
#           matching plugins/gaia/agents/{id}.md.
#   - AC6..AC9: each consuming SKILL.md resolves the retargeted file via
#           ${CLAUDE_PLUGIN_ROOT}/knowledge/<file>.

# ---------- AC1..AC4: 4 new files ship inside the plugin ----------

@test "S196 AC1: plugins/gaia/knowledge/manifest.yaml exists and is non-empty" {
  [ -f "$KNOWLEDGE_DIR/manifest.yaml" ]
  [ -s "$KNOWLEDGE_DIR/manifest.yaml" ]
}

@test "S196 AC2: plugins/gaia/knowledge/adversarial-triggers.yaml exists and is non-empty" {
  [ -f "$KNOWLEDGE_DIR/adversarial-triggers.yaml" ]
  [ -s "$KNOWLEDGE_DIR/adversarial-triggers.yaml" ]
}

@test "S196 AC3: plugins/gaia/knowledge/agent-manifest.csv exists and is non-empty" {
  [ -f "$KNOWLEDGE_DIR/agent-manifest.csv" ]
  [ -s "$KNOWLEDGE_DIR/agent-manifest.csv" ]
}

@test "S196 AC4: plugins/gaia/knowledge/lifecycle-sequence.yaml exists and is non-empty" {
  [ -f "$KNOWLEDGE_DIR/lifecycle-sequence.yaml" ]
  [ -s "$KNOWLEDGE_DIR/lifecycle-sequence.yaml" ]
}

# ---------- AC14: the 5 residual legacy literal paths are scrubbed ----------

@test "S196 AC14: no SKILL.md references a legacy _gaia/_config/<file> path for the 5 residuals (outside legacy-qualified prose)" {
  # Pattern covers the 5 files E28-S196 targets: global.yaml, manifest.yaml,
  # adversarial-triggers.yaml, agent-manifest.csv, lifecycle-sequence.yaml.
  #
  # Carve-out: gaia-migrate/SKILL.md is the migration tool itself — it
  # documents how v1 directories (including _gaia/_config/global.yaml) are
  # backed up and deleted. These references are contractual descriptions of
  # what /gaia-migrate apply does to a v1 install, NOT active reads. The
  # dead-reference-scan.sh already allowlists gaia-migrate for the same
  # reason; the S196 guard inherits that carve-out.
  local hits remaining
  hits="$(grep -rnE '_gaia/_config/(global|manifest|adversarial-triggers|agent-manifest|lifecycle-sequence)' "$SKILLS_DIR"/*/SKILL.md 2>/dev/null \
          | grep -v '/gaia-migrate/SKILL\.md:' \
          || true)"
  if [ -z "$hits" ]; then
    return 0
  fi
  remaining="$(printf '%s\n' "$hits" | grep -viE 'legacy v1|no longer used|historical|legacy location|pre-migration|v1 marker|retired' || true)"
  if [ -n "$remaining" ]; then
    echo "SKILL.md still references a legacy v1 _gaia/_config/<residual> path outside a 'legacy' qualifier:"
    printf '  %s\n' "$remaining"
    return 1
  fi
}

# ---------- AC15 consistency guard: agent-id ↔ plugin agent file ----------

@test "S196 AC15: every agent-id in knowledge/agent-manifest.csv has a matching plugins/gaia/agents/{id}.md" {
  local csv="$KNOWLEDGE_DIR/agent-manifest.csv"
  [ -f "$csv" ]
  local missing=""
  # Parse first column (agent-id) from non-header rows, strip quotes.
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if [ ! -f "$PLUGIN_ROOT/agents/${id}.md" ]; then
      missing+="  $id (expected $PLUGIN_ROOT/agents/${id}.md)"$'\n'
    fi
  done < <(awk -F',' 'NR>1 { gsub(/"/,"",$1); print $1 }' "$csv")
  if [ -n "$missing" ]; then
    echo "Agent-id rows in agent-manifest.csv lack a matching plugins/gaia/agents/*.md:"
    printf '%s' "$missing"
    return 1
  fi
}

# ---------- AC6..AC9: SKILL.md consumers resolve via plugin knowledge path ----------

@test "S196 AC6: validate-framework SKILL.md resolves manifest.yaml via \${CLAUDE_PLUGIN_ROOT}/knowledge/" {
  run grep -q 'CLAUDE_PLUGIN_ROOT.*knowledge/manifest\.yaml' "$SKILLS_DIR/gaia-validate-framework/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "S196 AC7a: create-prd SKILL.md resolves adversarial-triggers.yaml via \${CLAUDE_PLUGIN_ROOT}/knowledge/" {
  run grep -q 'CLAUDE_PLUGIN_ROOT.*knowledge/adversarial-triggers\.yaml' "$SKILLS_DIR/gaia-create-prd/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "S196 AC7b: edit-prd SKILL.md resolves adversarial-triggers.yaml via \${CLAUDE_PLUGIN_ROOT}/knowledge/" {
  run grep -q 'CLAUDE_PLUGIN_ROOT.*knowledge/adversarial-triggers\.yaml' "$SKILLS_DIR/gaia-edit-prd/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "S196 AC7c: edit-arch SKILL.md resolves adversarial-triggers.yaml via \${CLAUDE_PLUGIN_ROOT}/knowledge/" {
  run grep -q 'CLAUDE_PLUGIN_ROOT.*knowledge/adversarial-triggers\.yaml' "$SKILLS_DIR/gaia-edit-arch/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "S196 AC7d: edit-ux SKILL.md resolves adversarial-triggers.yaml via \${CLAUDE_PLUGIN_ROOT}/knowledge/" {
  run grep -q 'CLAUDE_PLUGIN_ROOT.*knowledge/adversarial-triggers\.yaml' "$SKILLS_DIR/gaia-edit-ux/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "S196 AC8: party SKILL.md resolves agent-manifest.csv via \${CLAUDE_PLUGIN_ROOT}/knowledge/" {
  run grep -q 'CLAUDE_PLUGIN_ROOT.*knowledge/agent-manifest\.csv' "$SKILLS_DIR/gaia-party/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "S196 AC9a: brainstorm SKILL.md no longer references lifecycle-sequence.yaml" {
  # E28-S196 originally required gaia-brainstorm to resolve lifecycle-sequence.yaml
  # via ${CLAUDE_PLUGIN_ROOT}/knowledge/. ADR-060 / FR-348 (E45-S1) supersedes this:
  # the 10 lifecycle skills now ship a static `## Next Steps` H2 section instead of
  # any dynamic lifecycle-sequence.yaml lookup. The new contract is the inverse —
  # zero references to lifecycle-sequence.yaml in gaia-brainstorm/SKILL.md, plus a
  # `## Next Steps` section pointing at /gaia-product-brief.
  run grep -q 'lifecycle-sequence\.yaml' "$SKILLS_DIR/gaia-brainstorm/SKILL.md"
  [ "$status" -ne 0 ]
  run grep -qE '^## Next Steps[[:space:]]*$' "$SKILLS_DIR/gaia-brainstorm/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "S196 AC9b: product-brief SKILL.md resolves lifecycle-sequence.yaml via \${CLAUDE_PLUGIN_ROOT}/knowledge/" {
  run grep -q 'CLAUDE_PLUGIN_ROOT.*knowledge/lifecycle-sequence\.yaml' "$SKILLS_DIR/gaia-product-brief/SKILL.md"
  [ "$status" -eq 0 ]
}

# ---------- AC13: next-step.sh resolves lifecycle-sequence from plugin knowledge/ ----------

@test "S196 AC13: next-step.sh resolves lifecycle-sequence.yaml via plugin knowledge/ path" {
  local script="$PLUGIN_ROOT/scripts/next-step.sh"
  [ -f "$script" ]
  run grep -q 'knowledge/lifecycle-sequence\.yaml' "$script"
  [ "$status" -eq 0 ]
}
