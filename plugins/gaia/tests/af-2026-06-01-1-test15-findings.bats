#!/usr/bin/env bats
# AF-2026-06-01-1: Test15 (v1.182.4) findings sweep — 22 F + 3 D.
#
# Structural assertions for every Test15 fix. Bash-3.2 compatible — wired
# into the cross-platform-portability CI matrix. Each block names the
# finding ID + one-line semantics so a future bisect can map a CI failure
# back to its origin defect without re-reading the assessment doc.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
}

teardown() { common_teardown; }

# ===========================================================================
# F-01 — libicu72 added to runtime apt install (.NET globalization init dep)
# ===========================================================================

@test "AF-32-1 F-01: Dockerfile runtime stage apt-installs libicu72" {
  run grep -F 'libicu72' "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-02 — Sarif.Multitool (NOT Microsoft.Sarif.Multitool) is the tool package
# ===========================================================================

@test "AF-32-1 F-02: Dockerfile installs Sarif.Multitool (not Microsoft.Sarif.Multitool)" {
  run grep -F 'dotnet tool install --tool-path /usr/local/bin Sarif.Multitool' \
    "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "AF-32-1 F-02: Dockerfile dotnet tool install line does not name Microsoft.Sarif.Multitool" {
  # Comment prose explaining the bug class may name the wrong package; only
  # the active `dotnet tool install` line must be free of the Microsoft. prefix.
  run grep -E '^\s*RUN.*dotnet tool install.*Microsoft\.Sarif\.Multitool' \
    "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# F-03 — DOTNET_ROOT set so sarif apphost can resolve libhostfxr.so
# ===========================================================================

@test "AF-32-1 F-03: Dockerfile sets ENV DOTNET_ROOT=/opt/dotnet" {
  run grep -E '^ENV DOTNET_ROOT=/opt/dotnet|DOTNET_ROOT=/opt/dotnet' \
    "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-04 — grype DB checksum parsed from plain-text, not --output json
# ===========================================================================

@test "AF-32-1 F-04: grype adapter docker dispatch does not use --output json on db status" {
  # The native-host grype branch (>=0.80) can use --output json safely.
  # The docker branch ships grype 0.79.5 which rejects --output, so the
  # docker dispatch MUST parse plain-text instead. Grep is scoped to the
  # docker branch by requiring the docker_runner_dispatch wrapper on the line.
  run grep -E 'docker_runner_dispatch grype db status.*--output json' \
    "$PLUGIN_ROOT/scripts/adapters/grype/adapter.sh"
  [ "$status" -ne 0 ]
}

@test "AF-32-1 F-04: grype adapter parses Checksum: from plain-text db status" {
  run grep -F '/^Checksum:/' "$PLUGIN_ROOT/scripts/adapters/grype/adapter.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-05 — SARIF merge stages inputs into a container-mapped subdir + grype
#        adapter out dir is the merge-input dir (sarif/)
# ===========================================================================

@test "AF-32-1 F-05: sarif-merge.sh stages inputs into /out/.merge-in-\$\$/" {
  run grep -F '.merge-in-$' "$PLUGIN_ROOT/scripts/adapters/brownfield/sarif-merge.sh"
  [ "$status" -eq 0 ]
}

@test "AF-32-1 F-05: sarif-merge.sh passes container-relative /out paths to sarif merge" {
  run grep -F '/out/.merge-in-' "$PLUGIN_ROOT/scripts/adapters/brownfield/sarif-merge.sh"
  [ "$status" -eq 0 ]
}

@test "AF-32-1 F-05: brownfield SKILL Phase-3 grype call sets ADAPTER_OUT_DIR=\$AUDIT/sarif" {
  run grep -F 'ADAPTER_OUT_DIR="$AUDIT/sarif"' "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-06 — sarif merge --force flag for idempotency
# ===========================================================================

@test "AF-32-1 F-06: sarif merge invoked with --force (idempotent re-runs)" {
  run grep -F -- '--force' "$PLUGIN_ROOT/scripts/adapters/brownfield/sarif-merge.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-07 — brownfield-assessment template carries project_type frontmatter
# ===========================================================================

@test "AF-32-1 F-07: brownfield-assessment template frontmatter has project_type" {
  run grep -F 'project_type:' "$PLUGIN_ROOT/templates/brownfield-assessment-template.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-08 — readiness-report generator output satisfies its own SV-23/SV-25
# ===========================================================================

@test "AF-32-1 F-08: readiness-report generator emits contradictions_found in frontmatter" {
  run grep -F 'contradictions_found' \
    "$PLUGIN_ROOT/skills/gaia-readiness-check/scripts/generate-readiness-report.sh"
  [ "$status" -eq 0 ]
}

@test "AF-32-1 F-08: readiness-report generator emits ## Output Verification body section" {
  run grep -F '## Output Verification' \
    "$PLUGIN_ROOT/skills/gaia-readiness-check/scripts/generate-readiness-report.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-09 — test-plan.md canonical-home contradiction reconciled in brownfield
# ===========================================================================

@test "AF-32-1 F-09: brownfield SKILL Known constraint cites planning-artifacts home for test-plan" {
  run grep -F 'Test15 F-09' "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-10 — review-gate parses execution-evidence JSON (refuses RED → PASSED)
# ===========================================================================

@test "AF-32-1 F-10: review-gate.sh inspects exit_code on execution-evidence" {
  run grep -F 'exit_code' "$PLUGIN_ROOT/scripts/review-gate.sh"
  [ "$status" -eq 0 ]
}

@test "AF-32-1 F-10: review-gate.sh inspects fail_count on execution-evidence" {
  run grep -F 'fail_count' "$PLUGIN_ROOT/scripts/review-gate.sh"
  [ "$status" -eq 0 ]
}

@test "AF-32-1 F-10: review-gate.sh refuses PASSED verdict when execution-evidence is RED" {
  run grep -F 'proof-of-execution: refusing PASSED' "$PLUGIN_ROOT/scripts/review-gate.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-11 — sprint-close FATAL on review→closed refusal (no yq fallback bypass)
# ===========================================================================

@test "AF-32-1 F-11: sprint-close.sh recognises the canonical refuse review→closed substring" {
  run grep -F 'refuse review' "$PLUGIN_ROOT/skills/gaia-sprint-close/scripts/close.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-PRD-1/2/3 — PRD template gaps
# ===========================================================================

@test "AF-32-1 F-PRD-1: prd-template carries Scan-prefix → heading legend" {
  run grep -F 'Scan-prefix' "$PLUGIN_ROOT/skills/gaia-create-prd/prd-template.md"
  [ "$status" -eq 0 ]
}

@test "AF-32-1 F-PRD-2: prd-template anchors a severity-vocabulary table" {
  run grep -iF 'severity vocabulary' "$PLUGIN_ROOT/skills/gaia-create-prd/prd-template.md"
  [ "$status" -eq 0 ]
}

@test "AF-32-1 F-PRD-3: prd-template carries an output_path frontmatter line" {
  run grep -F 'output_path:' "$PLUGIN_ROOT/skills/gaia-create-prd/prd-template.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# L-01 — docker-runner.sh BASH_SOURCE guarded under bash 3.2 + set -u
# ===========================================================================

@test "AF-32-1 L-01: docker-runner.sh BASH_SOURCE has :- default guard" {
  run grep -F '${BASH_SOURCE[0]:-}' "$PLUGIN_ROOT/scripts/lib/docker-runner.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# L-02 — entrypoint --version probes for spotbugs + sarif
# ===========================================================================

@test "AF-32-1 L-02: entrypoint spotbugs --version awk parses last field" {
  run grep -F 'spotbugs' "$PLUGIN_ROOT/tools/gaia-tools/gaia-tools-entrypoint.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# L-03 — doctor check-tools.sh --json reports runner field
# ===========================================================================

@test "AF-32-1 L-03: check-tools.sh --json emits a runner field" {
  run grep -F 'runner' "$PLUGIN_ROOT/skills/gaia-doctor/scripts/check-tools.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-16-L — review-gate.sh auto-emits review-summary.md
# ===========================================================================

@test "AF-32-1 F-16-L: review-gate.sh references review-summary.md emission" {
  run grep -F 'review-summary.md' "$PLUGIN_ROOT/scripts/review-gate.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-17-L — brownfield SKILL documents .gaia/state/ sprint-status.yaml home
# ===========================================================================

@test "AF-32-1 F-17-L: brownfield SKILL documents .gaia/state/ as sprint-status canonical home" {
  run grep -F 'Test15 F-17-L' "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-18-L — review-perf SKILL documents FR-402 type-first file naming
# ===========================================================================

@test "AF-32-1 F-18-L: review-perf SKILL documents performance-review-{key}.md file naming" {
  run grep -F 'performance-review-{story_key}.md' "$PLUGIN_ROOT/skills/gaia-review-perf/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-32-1 F-18-L: review-perf SKILL clarifies SKILL slug vs FILE name distinction" {
  run grep -F 'NOT `review-perf-' "$PLUGIN_ROOT/skills/gaia-review-perf/SKILL.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-19-L — install-test-environment-example.sh mirrors into test-artifacts/
# ===========================================================================

@test "AF-32-1 F-19-L: install-test-environment-example.sh mirrors into test-artifacts/" {
  # AF-2026-06-02-1 / Test16 F-L08 broadened the log marker to
  # `F-19-L/F-L08 mirror` to cover the unconditional-mkdir case. Match
  # either form so the contract stays asserted across the AF history.
  run grep -E 'F-19-L( mirror|/F-L08 mirror)' "$PLUGIN_ROOT/scripts/install-test-environment-example.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-20-L — resolve-test-artifact-per-story.sh drops stories/ middle level
# ===========================================================================

@test "AF-32-1 F-20-L: resolver new path is epic-{slug}/{key}-{slug}/{type}.md (no stories/)" {
  run grep -F 'epic-{slug}/{key}-{slug}/{type}.md' \
    "$PLUGIN_ROOT/scripts/lib/resolve-test-artifact-per-story.sh"
  [ "$status" -eq 0 ]
}

@test "AF-32-1 F-20-L: resolver retains legacy stories/ path as read-compat fallback" {
  run grep -F 'LEGACY_STORIES_PATH' "$PLUGIN_ROOT/scripts/lib/resolve-test-artifact-per-story.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# D-1 — docker-workflow doc has .NET build prerequisites section
# ===========================================================================

@test "AF-32-1 D-1: docker-workflow doc names libicu72 in build prerequisites" {
  run grep -F 'libicu72' \
    "$REPO_ROOT/documentation/commands/gaia-docker-workflow.html"
  [ "$status" -eq 0 ]
}

@test "AF-32-1 D-1: docker-workflow doc names DOTNET_ROOT in build prerequisites" {
  run grep -F 'DOTNET_ROOT' \
    "$REPO_ROOT/documentation/commands/gaia-docker-workflow.html"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# D-2 — docker-workflow doc Sarif.Multitool row notes AF-32-1 fixes landed
# ===========================================================================

@test "AF-32-1 D-2: docker-workflow doc Sarif.Multitool row cites AF-32-1 F-02/F-05" {
  run grep -F 'AF-32-1 F-02/F-05' \
    "$REPO_ROOT/documentation/commands/gaia-docker-workflow.html"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# D-3 — init CI scaffold stub onboarding doc exists at referenced path
# ===========================================================================

@test "AF-32-1 D-3: init CI scaffold stub onboarding doc exists" {
  [ -f "$PLUGIN_ROOT/skills/gaia-init/docs/ci-scaffold-stub.html" ]
}

@test "AF-32-1 D-3: init CI scaffold stub onboarding doc names /gaia-ci-setup" {
  run grep -F '/gaia-ci-setup' "$PLUGIN_ROOT/skills/gaia-init/docs/ci-scaffold-stub.html"
  [ "$status" -eq 0 ]
}
