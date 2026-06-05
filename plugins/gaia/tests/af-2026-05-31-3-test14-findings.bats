#!/usr/bin/env bats
# AF-2026-05-31-3: Test14 findings sweep (21 F + 0 V + 5 D).
#
# Structural assertions for every Test14 fix. Bash-3.2 compatible — wired
# into the cross-platform-portability CI matrix.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

# ===========================================================================
# F-02 + F-06 — Sarif.Multitool bundled + sarif entrypoint route
# ===========================================================================

@test "AF-31-3 F-02: Dockerfile installs .NET SDK channel 8.0 (not runtime-only)" {
  run grep -F -e '--channel 8.0' "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "AF-31-3 F-02: Dockerfile drops the silent || echo WARNING swallow on sarif install" {
  # The fix removed the || echo line; build now fails loud if install fails.
  run grep -F 'sarif-multitool install failed' "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -ne 0 ]
}

@test "AF-31-3 F-02: Dockerfile verifies sarif --version after install" {
  run grep -F '/usr/local/bin/sarif --version' "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "AF-31-3 F-06: entrypoint help text lists sarif" {
  run grep -F 'yamllint, yq, sarif' "$PLUGIN_ROOT/tools/gaia-tools/gaia-tools-entrypoint.sh"
  [ "$status" -eq 0 ]
}

@test "AF-31-3 F-06: entrypoint error vocabulary lists sarif" {
  run grep -F 'yq | sarif | --version' "$PLUGIN_ROOT/tools/gaia-tools/gaia-tools-entrypoint.sh"
  [ "$status" -eq 0 ]
}

@test "AF-31-3 F-06: entrypoint BOM probes sarif" {
  run grep -F 'sarif --version' "$PLUGIN_ROOT/tools/gaia-tools/gaia-tools-entrypoint.sh"
  [ "$status" -eq 0 ]
}

@test "AF-31-3 F-02 + F-06: image version bumped (0.1.2+; AF-32-1 bumped to 0.1.3 for F-01/02/03/F-05/F-06)" {
  # The 0.1.2 bump was the AF-31-3 deliverable; AF-32-1 bumped to 0.1.3 again
  # because its F-01/02/03/F-05/F-06 fixes change image contents. Either is
  # acceptable evidence that the F-02 + F-06 bundling change went through a
  # versioned rebuild — assert the floor (>=0.1.2).
  run grep -E '^ARG GAIA_TOOLS_VERSION=0\.1\.(2|3|4|5|6|7|8|9|[1-9][0-9])' \
    "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-05 — check-tools.sh fallback extracts canonical name
# ===========================================================================

@test "AF-31-3 F-05: check-tools.sh fallback projects .language//.name//.id" {
  run grep -F '.language // .name // .id // ""' "$PLUGIN_ROOT/skills/gaia-doctor/scripts/check-tools.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-10 — brownfield-assessment template schema_version
# ===========================================================================

@test "AF-31-3 F-10: brownfield-assessment-template uses schema_version 2.0.0" {
  run grep -F 'schema_version: "2.0.0"' "$PLUGIN_ROOT/templates/brownfield-assessment-template.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-11 — ci-setup deterministic generator
# ===========================================================================

@test "AF-31-3 F-11: gaia-ci-setup generate-pipeline.sh exists + is executable" {
  [ -x "$PLUGIN_ROOT/skills/gaia-ci-setup/scripts/generate-pipeline.sh" ]
}

@test "AF-31-3 F-11: ci-setup SKILL.md wires the generator before LLM authoring" {
  run grep -F 'generate-pipeline.sh' "$PLUGIN_ROOT/skills/gaia-ci-setup/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-31-3 F-11: generate-pipeline.sh supports python stack" {
  cd "$TEST_TMP"
  mkdir -p .github/workflows
  echo "GAIA pre-merge gate is not yet configured" > .github/workflows/gaia-pre-merge.yml
  run bash "$PLUGIN_ROOT/skills/gaia-ci-setup/scripts/generate-pipeline.sh" \
    --provider github-actions --stack python --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  run grep -F 'setup-python@v5' "$TEST_TMP/.github/workflows/gaia-pre-merge.yml"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-13 — sprint-state.sh review→closed Val-sentinel gate
# ===========================================================================

@test "AF-31-3 F-13: sprint-state.sh has review→closed Val-sentinel guard" {
  run grep -F 'refuse review→closed' "$PLUGIN_ROOT/scripts/sprint-state.sh"
  [ "$status" -eq 0 ]
}

@test "AF-31-3 F-13: GAIA_ALLOW_SPRINT_REVIEW_TO_CLOSED_WITHOUT_SENTINEL escape hatch documented" {
  run grep -F 'GAIA_ALLOW_SPRINT_REVIEW_TO_CLOSED_WITHOUT_SENTINEL' "$PLUGIN_ROOT/scripts/sprint-state.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-01 — gaia-init SKILL.md path-not-content
# ===========================================================================

@test "AF-31-3 F-01: gaia-init SKILL.md materialises the bundle to a tempfile first" {
  run grep -F 'mktemp -t gaia-init-bundle' "$PLUGIN_ROOT/skills/gaia-init/SKILL.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-03 — spotbugs version awk
# ===========================================================================

@test "AF-31-3 F-03: entrypoint spotbugs row uses SpotBugs awk pattern" {
  run grep -F "'/SpotBugs/ {print" "$PLUGIN_ROOT/tools/gaia-tools/gaia-tools-entrypoint.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-04 — config-yaml-editor.sh wrapper validation
# ===========================================================================

@test "AF-31-3 F-04: insert refuses wrapper/section mismatch" {
  run grep -F 'wrapper mismatch' "$PLUGIN_ROOT/scripts/config-yaml-editor.sh"
  [ "$status" -eq 0 ]
}

@test "AF-31-3 F-04: insert end-to-end refuses unwrapped content" {
  cd "$TEST_TMP"
  cat > base.yaml <<'EOF'
project_root: /tmp/x
EOF
  cat > bad.yaml <<'EOF'
some_key: value
EOF
  run bash "$PLUGIN_ROOT/scripts/config-yaml-editor.sh" insert base.yaml brownfield bad.yaml
  [ "$status" -ne 0 ]
}

# ===========================================================================
# F-07 — grype docker dispatch checksum
# ===========================================================================

@test "AF-31-3 F-07: grype adapter captures DB checksum from inside the container" {
  # AF-31-3 captured checksum via a _docker_db_meta JSON ladder that called
  # `grype db status --output json`. AF-32-1 F-04 replaced that with a
  # plain-text parse (`_docker_db_text` + `awk '/^Checksum:/'`) because
  # bundled grype 0.79.5 rejects --output. Either implementation satisfies
  # the F-07 contract: a docker-side checksum is captured.
  run grep -E '_docker_db_(meta|text|sha)' "$PLUGIN_ROOT/scripts/adapters/grype/adapter.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-08 — resolve-config.sh 3-deep tools.runner / tools.image
# ===========================================================================

@test "AF-31-3 F-08: resolve-config.sh has parse_yaml_3deep" {
  run grep -F 'parse_yaml_3deep' "$PLUGIN_ROOT/scripts/resolve-config.sh"
  [ "$status" -eq 0 ]
}

@test "AF-31-3 F-08: resolve-config.sh --field brownfield.tools.runner case" {
  run grep -F 'brownfield.tools.runner)' "$PLUGIN_ROOT/scripts/resolve-config.sh"
  [ "$status" -eq 0 ]
}

@test "AF-31-3 F-08: resolve-config.sh --field brownfield.tools.image case" {
  run grep -F 'brownfield.tools.image)' "$PLUGIN_ROOT/scripts/resolve-config.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-09 — render-test-quality.sh degrades on missing report
# ===========================================================================

@test "AF-31-3 F-09: render-test-quality.sh INFO-skips on missing report" {
  run grep -F 'does not exist yet — skipping Test Quality render' "$PLUGIN_ROOT/scripts/adapters/dead-code/render-test-quality.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-12 — validate-canonical-filename strict slug check
# ===========================================================================

@test "AF-31-3 F-12: validate-canonical-filename.sh computes slugify(title)" {
  run grep -F '_expected_slug' "$PLUGIN_ROOT/skills/gaia-create-story/scripts/validate-canonical-filename.sh"
  [ "$status" -eq 0 ]
}

@test "AF-31-3 F-12: validate-canonical-filename rejects slug drift" {
  run grep -F 'new-layout slug drift' "$PLUGIN_ROOT/skills/gaia-create-story/scripts/validate-canonical-filename.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-14 — gaia-sprint-review SKILL.md fully-qualified paths
# ===========================================================================

@test "AF-31-3 F-14: gaia-sprint-review SKILL.md uses fully-qualified write-val-sentinel path" {
  run grep -F 'skills/gaia-sprint-review/scripts/write-val-sentinel.sh' "$PLUGIN_ROOT/skills/gaia-sprint-review/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-31-3 F-14: path-disambiguation note added at top of SKILL.md" {
  run grep -F 'path disambiguation' "$PLUGIN_ROOT/skills/gaia-sprint-review/SKILL.md"
  # Match the section text; the title uses "Path disambiguation" with capital P.
  if [ "$status" -ne 0 ]; then
    run grep -Fi 'path disambiguation' "$PLUGIN_ROOT/skills/gaia-sprint-review/SKILL.md"
  fi
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-15 — test-artifacts/ mirror + per-tier evidence
# ===========================================================================

@test "AF-31-3 F-15: test-artifacts-mirror.sh helper exists + is executable" {
  [ -x "$PLUGIN_ROOT/scripts/lib/test-artifacts-mirror.sh" ]
}

@test "AF-31-3 F-15: review-gate.sh hooks the mirror for test-lens gates" {
  run grep -F 'test-artifacts-mirror.sh' "$PLUGIN_ROOT/scripts/review-gate.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-16 — sprint-state.sh implementation-artifacts mirror
# ===========================================================================

@test "AF-31-3 F-16: sprint-state.sh mirrors yaml to implementation-artifacts/" {
  run grep -F 'implementation-artifacts/sprint-status.yaml' "$PLUGIN_ROOT/scripts/sprint-state.sh"
  [ "$status" -eq 0 ]
}

@test "AF-31-3 F-16: sprint-state.sh wrapper byte-identical to canonical" {
  src="$PLUGIN_ROOT/scripts/sprint-state.sh"
  dst="$PLUGIN_ROOT/skills/gaia-dev-story/scripts/sprint-state.sh"
  diff -q "$src" "$dst"
}

@test "AF-31-3 F-16: end-to-end mirror writes when target dir exists" {
  # Pre-create the impl-artifacts dir so the non-creating mirror engages.
  mkdir -p "$TEST_TMP/.gaia/state" "$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  run bash -c "cd '$TEST_TMP' && PROJECT_PATH='$TEST_TMP' bash '$PLUGIN_ROOT/scripts/sprint-state.sh' init --sprint-id sprint-1"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/.gaia/state/sprint-status.yaml" ]
  [ -f "$TEST_TMP/.gaia/artifacts/implementation-artifacts/sprint-status.yaml" ]
}

@test "AF-31-3 F-16: end-to-end mirror NO-OPS when target dir absent (legacy projects)" {
  # Don't create the impl-artifacts dir; mirror must NOT auto-create it.
  mkdir -p "$TEST_TMP/.gaia/state"
  run bash -c "cd '$TEST_TMP' && PROJECT_PATH='$TEST_TMP' bash '$PLUGIN_ROOT/scripts/sprint-state.sh' init --sprint-id sprint-1"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/.gaia/state/sprint-status.yaml" ]
  [ ! -d "$TEST_TMP/.gaia/artifacts/implementation-artifacts" ]
}

# ===========================================================================
# F-17 — test-environment-manifest.sh test-artifacts/ mirror
# ===========================================================================

@test "AF-31-3 F-17: test-environment-manifest.sh mirrors to test-artifacts/" {
  run grep -F 'test-artifacts/test-environment.yaml' "$PLUGIN_ROOT/scripts/lib/test-environment-manifest.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-18 — review-summary.md per-story aggregator
# ===========================================================================

@test "AF-31-3 F-18: review-summary-gen.sh writes per-story reviews/ aggregator" {
  run grep -F 'reviews/review-summary.md' "$PLUGIN_ROOT/scripts/review-summary-gen.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-19 — test-plan.md canonical home in planning-artifacts
# ===========================================================================

@test "AF-31-3 F-19: gaia-trace SKILL.md routes test-plan reads through planning-artifacts first" {
  run grep -F -e 'Do NOT write' "$PLUGIN_ROOT/skills/gaia-trace/SKILL.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-20 — architecture adversarial standalone file
# ===========================================================================

@test "AF-31-3 F-20: brownfield Phase 9b documents standalone architecture adversarial" {
  run grep -F 'adversarial-review-architecture-{YYYY-MM-DD}.md' "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-21 — readiness-report generator
# ===========================================================================

@test "AF-31-3 F-21: generate-readiness-report.sh exists + is executable" {
  [ -x "$PLUGIN_ROOT/skills/gaia-readiness-check/scripts/generate-readiness-report.sh" ]
}

@test "AF-31-3 F-21: readiness-check SKILL.md wires the generator" {
  run grep -F 'generate-readiness-report.sh' "$PLUGIN_ROOT/skills/gaia-readiness-check/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-31-3 F-21: generator writes a canonical-shape report" {
  mkdir -p "$TEST_TMP/.gaia/artifacts/planning-artifacts"
  run bash "$PLUGIN_ROOT/skills/gaia-readiness-check/scripts/generate-readiness-report.sh" \
    --status PASS --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/.gaia/artifacts/planning-artifacts/readiness-report.md" ]
  run grep -F 'artifact_type: readiness-report' "$TEST_TMP/.gaia/artifacts/planning-artifacts/readiness-report.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# D-01..D-05 — documentation gaps
# ===========================================================================

@test "AF-31-3 D-01: brownfield SKILL.md spells out per-artifact destination split" {
  run grep -F 'Per-artifact destination split' "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-31-3 D-02: brownfield Phase 6 routes headless projects at phase-5-for-non-deployable-projects" {
  run grep -F 'phase-5-for-non-deployable-projects.md' "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-31-3 D-03: brownfield SKILL.md documents Phase 7 empty-scan grading + id-prefix convention" {
  run grep -F 'Empty-but-UNVERIFIED scan' "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-31-3 D-04: brownfield SKILL.md names the PRD template plugin-relative location" {
  run grep -F 'skills/gaia-create-prd/prd-template.md' "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-31-3 D-04: brownfield SKILL.md documents the 5-tier / 3-tier severity mapping" {
  run grep -F 'config-severity bucket' "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-31-3 D-05: test-strategy SKILL.md documents the two-artifact expectation + frontmatter" {
  run grep -F 'Two-artifact expectation' "$PLUGIN_ROOT/skills/gaia-test-strategy/SKILL.md"
  [ "$status" -eq 0 ]
}
