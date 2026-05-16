#!/usr/bin/env bats

# E55-S11 — regression sentinel for plugin-ci.yml coverage of tests/skills/*.bats.
#
# Origin: triage finding E55-S2-F1. Two skill bats files (planning-gate,
# yolo-plan-loop) were added by E55-S1 / E55-S2 but never wired into CI; the
# regression vector is "test exists on disk, has no CI signal." E55-S5 wired
# in the first batch of /gaia-dev-story V2 hardening files. This story
# (E55-S11) closes the broader gap: every currently-passing bats file under
# `tests/skills/` MUST be exercised by `plugin-ci.yml` on every push and PR.
#
# This file is the regression sentinel. Each test is a one-liner that checks
# the workflow YAML contains the file path under the `skills-bats-tests` job.
# A future refactor that silently un-wires any of these files (move, rename,
# or removal of the bats invocation) will fail this suite — the sentinel grep
# in AC4 of the story spec is a one-liner, but this bats file enumerates every
# currently-passing file individually so the failure message names the
# specific file that lost coverage.
#
# Coverage policy:
#   - PASSING files (run cleanly today on staging) are REQUIRED to be wired.
#   - KNOWN-FAILING files (pre-existing fixture drift, listed below) are
#     EXEMPT and tracked as Findings on E55-S11. Each EXEMPT file has a
#     companion follow-up story to repair the assertions and re-wire it.
#
# Maintenance: when a file moves from EXEMPT to PASSING, append it to the
# PASSING list AND remove it from the EXEMPT list. The two lists must stay
# disjoint and together cover every `tests/skills/*.bats` file on staging.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  WORKFLOW="$REPO_ROOT/.github/workflows/plugin-ci.yml"
}

# ---------- Required (PASSING today) ----------
#
# Generated 2026-05-10 by running `bats <file>` against each tests/skills/*.bats
# on the E55-S11 feature branch base (staging @ 8c5f94e). Every file in this
# list passed cleanly. The list is enumerated rather than globbed because the
# bats invocation in plugin-ci.yml is also enumerated — keeping the two
# representations literal makes drift trivially detectable.

REQUIRED_FILES=(
  "tests/skills/E28-S227-td74-gaia-config-csv-cleanup.bats"
  "tests/skills/E55-S11-plugin-ci-bats-coverage.bats"
  "tests/skills/E69-S1-rename-map.bats"
  "tests/skills/E69-S3-test-strategy-collapse.bats"
  "tests/skills/conditional-check-hints.bats"
  "tests/skills/e28-s113-edge-cases-figma-conversion.bats"
  "tests/skills/e28-s117-quick-dev-conversion.bats"
  "tests/skills/e64-s3-transition-script-path-refs.bats"
  "tests/skills/gaia-a11y-testing.bats"
  "tests/skills/gaia-atdd-batch.bats"
  "tests/skills/gaia-atdd.bats"
  "tests/skills/gaia-ci-edit-hints.bats"
  "tests/skills/gaia-config-ci-regenerate.bats"
  "tests/skills/gaia-config-section-scope.bats"
  "tests/skills/gaia-config-validate-schema.bats"
  "tests/skills/gaia-config-yaml-editor.bats"
  "tests/skills/gaia-deploy-adapter-dispatch.bats"
  "tests/skills/gaia-deploy-checklist.bats"
  "tests/skills/gaia-deploy-failures.bats"
  "tests/skills/gaia-deploy.bats"
  "tests/skills/gaia-dev-story-e41-s3-yolo-val-on-tdd-phases.bats"
  "tests/skills/gaia-dev-story-figma-degrade.bats"
  "tests/skills/gaia-dev-story-planning-gate.bats"
  "tests/skills/gaia-dev-story-step2b-atdd.bats"
  "tests/skills/gaia-dev-story-step7b-val.bats"
  "tests/skills/gaia-dev-story-three-option-prompt.bats"
  "tests/skills/gaia-dev-story-yolo-plan-loop.bats"
  "tests/skills/gaia-edit-test-plan.bats"
  "tests/skills/gaia-editorial-prose.bats"
  "tests/skills/gaia-editorial-structure.bats"
  "tests/skills/gaia-fill-test-gaps.bats"
  "tests/skills/gaia-memory-hygiene-hints.bats"
  "tests/skills/gaia-mobile-testing.bats"
  "tests/skills/gaia-nfr.bats"
  "tests/skills/gaia-perf-testing-hints.bats"
  "tests/skills/gaia-perf-testing.bats"
  "tests/skills/gaia-post-deploy.bats"
  "tests/skills/gaia-refresh-ground-truth-hints.bats"
  "tests/skills/gaia-release-plan.bats"
  "tests/skills/gaia-review-deps-hints.bats"
  "tests/skills/gaia-review-mobile.bats"
  "tests/skills/gaia-rollback-plan.bats"
  "tests/skills/gaia-shell-idioms.bats"
  "tests/skills/gaia-teach-testing-hints.bats"
  "tests/skills/gaia-teach-testing.bats"
  "tests/skills/gaia-test-framework.bats"
  "tests/skills/gaia-triage-findings-e41-s5-yolo-auto-apply.bats"
  "tests/skills/gaia-triage-findings-reproduction-policy.bats"
  "tests/skills/lint-skill-frontmatter.bats"
  "tests/skills/validate-plan-structure.bats"
)

# ---------- Exempt (pre-existing fixture drift; tracked as Findings) ----------
#
# Each entry has a companion follow-up story. When the assertions are repaired,
# move the entry from this list into REQUIRED_FILES and add the corresponding
# bats invocation to plugin-ci.yml.

EXEMPT_FILES=(
  "tests/skills/e28-s114-lifecycle-skills-conversion.bats"           # SECTION-marker count drift in document-rulesets SKILL.md
  "tests/skills/e28-s116-quick-spec-conversion.bats"                 # asserts retired _gaia/lifecycle/ XML source still exists
  "tests/skills/e59-s1-skill-readme-call-site-migration.bats"        # README.md drift in gaia-dev-story
  "tests/skills/e60-s1-flat-artifact-path-keys.bats"                 # asserts ${PROJECT_ROOT}/config/project-config.yaml — that file lives outside gaia-public/ checkout (project-root non-git workspace per CLAUDE.md); passes locally, fails in CI
  "tests/skills/gaia-config-skills-exist.bats"                       # AC10 asserts gaia-config-platform / -device-target NOT present; both shipped (E74-S11)
  "tests/skills/gaia-performance-review-hints.bats"                  # 10 failures — significant skill drift since fixture authored
)

# ---------- Tests ----------

@test "AC4 regression sentinel: grep for tests/skills/ in plugin-ci.yml returns >=1" {
  run grep -c 'tests/skills' "$WORKFLOW"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "AC1: every REQUIRED tests/skills/*.bats file is referenced in plugin-ci.yml" {
  local missing=()
  for f in "${REQUIRED_FILES[@]}"; do
    if ! grep -qF "$f" "$WORKFLOW"; then
      missing+=("$f")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    printf 'plugin-ci.yml does not reference required bats files:\n' >&2
    printf '  %s\n' "${missing[@]}" >&2
    return 1
  fi
}

@test "AC1: REQUIRED and EXEMPT lists cover every tests/skills/*.bats file on disk" {
  local on_disk=()
  while IFS= read -r f; do
    on_disk+=("$f")
  done < <(cd "$REPO_ROOT" && find tests/skills -maxdepth 1 -type f -name '*.bats' | sort)

  local known=("${REQUIRED_FILES[@]}" "${EXEMPT_FILES[@]}")
  local unknown=()
  for f in "${on_disk[@]}"; do
    local found=0
    for k in "${known[@]}"; do
      [ "$f" = "$k" ] && { found=1; break; }
    done
    [ $found -eq 0 ] && unknown+=("$f")
  done
  if [ ${#unknown[@]} -gt 0 ]; then
    printf 'tests/skills/*.bats file(s) not classified as REQUIRED or EXEMPT:\n' >&2
    printf '  %s\n' "${unknown[@]}" >&2
    printf 'Add each file to REQUIRED_FILES (and to plugin-ci.yml) once it passes,\n' >&2
    printf 'or to EXEMPT_FILES with a brief reason if a fixture-repair story is queued.\n' >&2
    return 1
  fi
}

@test "AC1: REQUIRED and EXEMPT lists are disjoint" {
  for r in "${REQUIRED_FILES[@]}"; do
    for e in "${EXEMPT_FILES[@]}"; do
      if [ "$r" = "$e" ]; then
        echo "file appears in both REQUIRED_FILES and EXEMPT_FILES: $r" >&2
        return 1
      fi
    done
  done
}

@test "AC3: existing bats-tests job (run-with-coverage) is unchanged by this story" {
  # The existing `bats-tests` job invokes plugins/gaia/scripts/bats-budget-watch.sh
  # wrapping plugins/gaia/tests/run-with-coverage.sh. Both invocations must
  # remain present so the pre-existing coverage signal is not regressed.
  run grep -F 'plugins/gaia/scripts/bats-budget-watch.sh' "$WORKFLOW"
  [ "$status" -eq 0 ]
  run grep -F 'plugins/gaia/tests/run-with-coverage.sh' "$WORKFLOW"
  [ "$status" -eq 0 ]
}

@test "AC3: skills-bats-tests job has identical on-trigger parity with bats-tests" {
  # Both jobs share the same workflow-level `on:` block (push + pull_request to
  # main and staging). This test asserts the workflow-level on-trigger block
  # contains both events; per-job triggers are not used, so parity is implied
  # by the single shared block.
  run grep -E '^\s*pull_request:' "$WORKFLOW"
  [ "$status" -eq 0 ]
  run grep -E '^\s*push:' "$WORKFLOW"
  [ "$status" -eq 0 ]
}
