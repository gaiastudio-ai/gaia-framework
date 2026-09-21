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
#     EXEMPT and tracked as Findings. Each EXEMPT file has a companion
#     follow-up story to repair the assertions and re-wire it.
#
# Maintenance: when a file moves from EXEMPT to PASSING, append it to the
# PASSING list AND remove it from the EXEMPT list. The two lists must stay
# disjoint and together cover every `*.bats` file under `tests/skills/` on
# staging.
#
# Depth: the classification covers the WHOLE tree under `tests/skills/`, not
# just its top level. Skill-scoped suites live one directory down (for example
# `tests/skills/<skill-name>/<case>.bats`), and an earlier version of this
# sentinel enumerated candidates with `-maxdepth 1`. That narrowing put every
# nested file into a third state — neither required, nor exempt, nor flagged —
# which is exactly the "test exists on disk, has no CI signal" condition this
# file was written to make loud. The find below is therefore full-depth, and
# must stay at least as deep as the workflow's reach.

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
  "tests/skills/bash32-portability-lint.bats"
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
  "tests/skills/gaia-deploy-post.bats"
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

  # Skill-scoped suites (one directory down). These run clean — verified with
  # the four inherited path variables cleared, which is how CI invokes them.
  "tests/skills/gaia-atdd/setup-finalize-quirks.bats"
  "tests/skills/gaia-dev-story/e41-s4-yolo-auto-run-reviews.bats"
  "tests/skills/gaia-meeting/mode-registry.bats"
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
  "tests/skills/e60-s1-flat-artifact-path-keys.bats"                 # asserts ${PROJECT_ROOT}/config/project-config.yaml — that file lives outside gaia-framework/ checkout (project-root non-git workspace per CLAUDE.md); passes locally, fails in CI
  "tests/skills/gaia-config-skills-exist.bats"                       # AC10 asserts gaia-config-platform / -device-target NOT present; both shipped (E74-S11)
  "tests/skills/gaia-performance-review-hints.bats"                  # 10 failures — significant skill drift since fixture authored

  # ---- Skill-scoped suites: the meeting skill ----
  #
  # 53 files / 439 cases, of which 61 cases across the 21 files listed here
  # fail against the current skill. These suites were authored alongside an
  # earlier shape of the meeting skill and were never run by CI, so the skill
  # moved and the fixtures did not. Repair is tracked follow-on work, one
  # cluster at a time; each file re-joins REQUIRED_FILES as it is repaired.
  # The per-file counts below are measured, not estimated.
  #
  # A second, independent blocker applies to this whole directory: 365 of its
  # 439 test names carry internal traceability identifiers, so the files
  # cannot be published-tree clean until they are renamed. Repair and rename
  # must land together.
  "tests/skills/gaia-meeting/anti-amnesia-contract.bats"             # 2 failures — context-retention assertions predate the current prompt contract
  "tests/skills/gaia-meeting/cadence-roundtrip.bats"                 # 1 failure — cadence round-trip fixture expects a retired field ordering
  "tests/skills/gaia-meeting/checkpoint-cadence-byte-identity.bats"  # 1 failure — byte-identity baseline captured before the checkpoint writer changed
  "tests/skills/gaia-meeting/checkpoint-reaper.bats"                 # 3 failures — reaper retention arithmetic changed since the fixture was authored
  "tests/skills/gaia-meeting/checkpoint-write-boundary.bats"         # 3 failures — write-boundary path assertions predate the runtime-tree move
  "tests/skills/gaia-meeting/checkpoint-yields-skill-md.bats"        # 2 failures — expects checkpoint prose that the skill no longer emits verbatim
  "tests/skills/gaia-meeting/cite-or-flag-check.bats"                # 1 failure — citation-marker wording drifted in the skill
  "tests/skills/gaia-meeting/frontmatter-mode-bias.bats"             # 4 failures — mode-bias frontmatter keys renamed since the fixture was written
  "tests/skills/gaia-meeting/max-turns-cap.bats"                     # 2 failures — turn-cap default changed; fixture pins the old number
  "tests/skills/gaia-meeting/meeting-notes-writer.bats"              # 8 failures — notes-template section set diverged from the fixture's expected headings
  "tests/skills/gaia-meeting/memory-writethrough.bats"               # 5 failures — write-through target paths predate the runtime-tree move
  "tests/skills/gaia-meeting/research-phase-dispatch.bats"           # 1 failure — research dispatch wording drifted in the skill
  "tests/skills/gaia-meeting/scratchpad-extractor.bats"              # 7 failures — extractor output shape changed since the fixture was authored
  "tests/skills/gaia-meeting/scratchpad-resolve-path.bats"           # 1 failure — resolved scratchpad path predates the runtime-tree move
  "tests/skills/gaia-meeting/single-mode-invariant.bats"             # 1 failure — invariant assertion pins a retired mode name
  "tests/skills/gaia-meeting/write-boundary-fixture.bats"            # 1 failure — boundary fixture expects a path the writer no longer produces
  "tests/skills/gaia-meeting/write-boundary-halt-event.bats"         # 1 failure — halt-event payload shape changed since the fixture was written
  "tests/skills/gaia-meeting/write-boundary.bats"                    # 3 failures — boundary allowlist diverged from the fixture's expected set
  "tests/skills/gaia-meeting/yield-gate-auq.bats"                    # 2 failures — yield-gate question flow reshaped since the fixture was authored
  "tests/skills/gaia-meeting/yield-gate-resume.bats"                 # 5 failures — resume path through the yield gate changed
  "tests/skills/gaia-meeting/yield-gate.bats"                        # 7 failures — core yield-gate assertions predate the current gate contract

  # The remaining 32 meeting files pass today but stay exempt for the naming
  # blocker above: their test names carry internal identifiers, and gating
  # them would publish those names through CI output. They move to REQUIRED
  # as part of the same rename work.
  "tests/skills/gaia-meeting/action-items-writer.bats"               # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/charter-required.bats"                  # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/checkpoint-cadence.bats"                # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/cost-cadence.bats"                      # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/default-mode.bats"                      # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/dual-schema-routing.bats"               # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/halt-event.bats"                        # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/lifecycle-markers.bats"                 # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/loop-detector.bats"                     # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/no-fabricated-user-invitee.bats"        # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/parse-resume-flags.bats"                # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/per-agent-cap.bats"                     # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/prelude-format.bats"                    # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/raise-hand-arbiter.bats"                # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/research-gate.bats"                     # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/resolve-invitees.bats"                  # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/resume-integration.bats"                # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/review-gate.bats"                       # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/scratchpad-allocate.bats"               # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/scratchpad-detect-type.bats"            # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/scratchpad-disposition.bats"            # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/secret-scrubber.bats"                   # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/select-notes-template.bats"             # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/session-state.bats"                     # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/stream-header.bats"                     # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/substrate-invariance.bats"              # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/turn-order.bats"                        # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/type-target-resolver.bats"              # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/yield-gate-cadence.bats"                # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/yield-gate-regression-2026-05-08.bats"  # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-meeting/yield-gate-skill-md.bats"               # passes; blocked on internal identifiers in its test names

  # ---- Skill-scoped suites: the story-creation skill ----
  #
  # 5 files / 91 cases, of which 10 cases across the 2 files listed here fail.
  # Same cause as the meeting suites: authored against an earlier shape of the
  # skill and never exercised by CI. 63 of the 91 names also carry internal
  # identifiers, so the same rename blocker applies to the directory.
  "tests/skills/gaia-create-story/edge-case-pipeline.bats"           # 8 failures — edge-case pipeline output shape changed since the fixture was authored
  "tests/skills/gaia-create-story/yolo-mode.bats"                    # 2 failures — unattended-mode step list diverged from the fixture's expected steps
  "tests/skills/gaia-create-story/e41-s2-yolo-wire-up.bats"          # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-create-story/scaffold-frontmatter-tokens.bats"  # passes; blocked on internal identifiers in its test names
  "tests/skills/gaia-create-story/ux-detection.bats"                 # passes; blocked on internal identifiers in its test names
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
  local unknown=()
  while IFS= read -r f; do
    [ -n "$f" ] && unknown+=("$f")
  done < <(_classify_tree "$REPO_ROOT")

  if [ ${#unknown[@]} -gt 0 ]; then
    printf 'tests/skills/*.bats file(s) not classified as REQUIRED or EXEMPT:\n' >&2
    printf '  %s\n' "${unknown[@]}" >&2
    printf 'Add each file to REQUIRED_FILES (and to plugin-ci.yml) once it passes,\n' >&2
    printf 'or to EXEMPT_FILES with a brief reason if a fixture-repair story is queued.\n' >&2
    return 1
  fi
}

# _classify_tree — echoes every *.bats path under tests/skills/ that appears
# in neither list. Shared by the coverage test and the new-file drift probe so
# both exercise the same classification logic.
_classify_tree() {
  local root="$1"
  local on_disk=() known=("${REQUIRED_FILES[@]}" "${EXEMPT_FILES[@]}")
  local f k found
  while IFS= read -r f; do
    on_disk+=("$f")
  done < <(cd "$root" && find tests/skills -type f -name '*.bats' | sort)

  for f in "${on_disk[@]}"; do
    found=0
    for k in "${known[@]}"; do
      [ "$f" = "$k" ] && { found=1; break; }
    done
    [ $found -eq 0 ] && printf '%s\n' "$f"
  done
  return 0
}

@test "an unclassified bats file added below the top level fails classification" {
  # The regression this sentinel exists to catch: a suite lands on disk at a
  # nested path, no CI job names it, and nothing goes red. Plant one, prove the
  # classification flags it by exact path, then remove it.
  local probe="$REPO_ROOT/tests/skills/gaia-meeting/zz-unclassified-probe.bats"
  printf '#!/usr/bin/env bats\n' > "$probe"
  printf '@test "probe" {\n  true\n}\n' >> "$probe"

  local unclassified
  unclassified="$(_classify_tree "$REPO_ROOT")"
  rm -f "$probe"

  # The planted file must be named, and nothing else may be unclassified.
  [ "$unclassified" = "tests/skills/gaia-meeting/zz-unclassified-probe.bats" ]
}

@test "every required file is reached by the workflow and no exempt file is" {
  # The sentinel's lists and the workflow's bats invocation are two literal
  # representations of one classification. They drifted apart once before —
  # this asserts agreement in both directions.
  local invocation missing=() executed=()
  # The bats invocation is the contiguous run of backslash-continued lines in
  # the skills coverage step; matching `tests/skills/...bats` tokens is enough
  # to know which paths that step actually hands to bats.
  invocation="$(grep -oE 'tests/skills/[A-Za-z0-9._/-]+\.bats' "$WORKFLOW" | sort -u)"

  local f
  for f in "${REQUIRED_FILES[@]}"; do
    printf '%s\n' "$invocation" | grep -qxF "$f" || missing+=("$f")
  done
  for f in "${EXEMPT_FILES[@]}"; do
    printf '%s\n' "$invocation" | grep -qxF "$f" && executed+=("$f")
  done

  if [ ${#missing[@]} -gt 0 ]; then
    printf 'required but never invoked by the workflow:\n' >&2
    printf '  %s\n' "${missing[@]}" >&2
  fi
  if [ ${#executed[@]} -gt 0 ]; then
    printf 'exempt but still invoked by the workflow:\n' >&2
    printf '  %s\n' "${executed[@]}" >&2
  fi
  [ ${#missing[@]} -eq 0 ] && [ ${#executed[@]} -eq 0 ]
}

@test "every exempt entry carries a stated reason" {
  # An exemption with no reason is the defect this file guards against wearing
  # a different hat: the file is off the gate and nobody knows why.
  local src="$BATS_TEST_FILENAME"
  local body reasonless
  body="$(sed -n '/^EXEMPT_FILES=(/,/^)/p' "$src" | grep -E '^\s*"tests/skills/')"
  reasonless="$(printf '%s\n' "$body" | grep -vE '#\s*\S' || true)"

  if [ -n "$reasonless" ]; then
    printf 'exempt entries with no stated reason:\n' >&2
    printf '%s\n' "$reasonless" >&2
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

@test "AC3: skills-bats-tests job shares the workflow on-trigger with bats-tests (PR-only)" {
  # Both jobs share the single workflow-level `on:` block, so they trigger
  # identically (parity is implied by the shared block; per-job triggers are not
  # used). The workflow is PR-only: it triggers on pull_request to main/staging
  # and intentionally NOT on push — the post-merge push re-ran the full suite a
  # second time per change (feature->staging AND staging->main) with no added
  # safety on a squash-merge flow. The pull_request event already gates every
  # change, including the staging->main promotion full-suite escalation.
  run grep -E '^\s*pull_request:' "$WORKFLOW"
  [ "$status" -eq 0 ]
  run grep -E '^\s*push:' "$WORKFLOW"
  [ "$status" -ne 0 ]
}
