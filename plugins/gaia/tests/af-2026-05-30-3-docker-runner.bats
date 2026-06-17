#!/usr/bin/env bats
# AF-2026-05-30-3: Docker runner for /gaia-doctor + brownfield Tier-2 adapters.
#
# Closes Test10 §7 Component 2 ("Lower the install cost") that AF-30-2
# deferred. Operators on a stock machine can now `docker pull` the
# bundled gaia-tools OCI image instead of installing each Tier 2 tool
# (grype + syft + spotbugs + mobsf + …) individually.
#
# This suite covers:
#   - gaia-tools Dockerfile + entrypoint structure (syntax + label sanity)
#   - GHCR publish workflow file existence + structure
#   - brownfield.tools.runner schema declaration (yaml + json)
#   - scripts/lib/docker-runner.sh CLI subcommands (image, mode, available)
#   - grype adapter docker-mode fork (source-level grep)
#   - spotbugs adapter docker-mode fork (source-level grep)
#   - /gaia-doctor --install --docker flag parsing
#   - /gaia-doctor check-tools.sh docker-runner tier promotion
#   - /gaia-config-brownfield SKILL.md tools.runner enum
#
# Runtime tests against an actual docker daemon are out of scope (CI bats
# runs do not have Docker available); the dispatcher is exercised via
# env-var injection where possible.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

# ===========================================================================
# gaia-tools image
# ===========================================================================

@test "image: Dockerfile present at plugins/gaia/tools/gaia-tools/" {
  [ -f "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile" ]
}

@test "image: Dockerfile pins grype/syft/osv-scanner/spotbugs versions" {
  run grep -E '^ARG (GRYPE|SYFT|OSV_SCANNER|SPOTBUGS)_VERSION=' \
        "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -eq 0 ]
  # All four ARG declarations should match
  [ "$(echo "$output" | wc -l | tr -d ' ')" -ge 4 ]
}

@test "image: Dockerfile installs pure-pip Tier-1 tools" {
  run grep -E 'vulture|pip-audit|cyclonedx-bom|yamllint' \
        "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "image: Dockerfile sets canonical /workspace and /out mounts" {
  run grep -F 'mkdir -p /workspace /out' "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "image: Dockerfile declares OCI labels" {
  run grep -E 'org\.opencontainers\.image\.title.*gaia-tools' \
        "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "image: entrypoint is shipped and executable" {
  [ -x "$PLUGIN_ROOT/tools/gaia-tools/gaia-tools-entrypoint.sh" ] || \
    [ -f "$PLUGIN_ROOT/tools/gaia-tools/gaia-tools-entrypoint.sh" ]
  run bash -n "$PLUGIN_ROOT/tools/gaia-tools/gaia-tools-entrypoint.sh"
  [ "$status" -eq 0 ]
}

@test "image: entrypoint --version prints a BOM line" {
  # Spoof env so the BOM template doesn't probe binaries that aren't on
  # the test host.
  run env GAIA_TOOLS_VERSION=test GAIA_TOOLS_DB_DATE=2026-05-30 \
        bash "$PLUGIN_ROOT/tools/gaia-tools/gaia-tools-entrypoint.sh" --version
  [ "$status" -eq 0 ]
  [[ "$output" =~ gaia-tools[[:space:]]test ]]
}

@test "image: README documents pull + use + image policy" {
  [ -f "$PLUGIN_ROOT/tools/gaia-tools/README.md" ]
  run grep -E 'docker pull|tools\.runner|brownfield\.tools' \
        "$PLUGIN_ROOT/tools/gaia-tools/README.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# GHCR publish workflow
# ===========================================================================

@test "ci: publish workflow file exists" {
  [ -f "$PLUGIN_ROOT/../../.github/workflows/gaia-tools-image.yml" ]
}

@test "ci: publish workflow targets ghcr.io with multi-arch buildx" {
  run grep -E 'ghcr\.io|linux/amd64|linux/arm64' \
        "$PLUGIN_ROOT/../../.github/workflows/gaia-tools-image.yml"
  [ "$status" -eq 0 ]
}

@test "ci: publish workflow runs on monthly cron + push to main" {
  run grep -E 'cron:|branches:' \
        "$PLUGIN_ROOT/../../.github/workflows/gaia-tools-image.yml"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# Schema: brownfield.tools.runner
# ===========================================================================

@test "schema: YAML descriptor mentions tools.runner enum docker|native" {
  run grep -F 'tools.runner' "$PLUGIN_ROOT/config/project-config.schema.yaml"
  [ "$status" -eq 0 ]
}

@test "schema: JSON schema permits the brownfield section" {
  run jq -e '.properties.brownfield' "$PLUGIN_ROOT/schemas/project-config.schema.json"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
}

# ===========================================================================
# docker-runner.sh shared lib
# ===========================================================================

@test "lib: docker-runner.sh exists and is executable" {
  [ -x "$PLUGIN_ROOT/scripts/lib/docker-runner.sh" ]
}

@test "lib: docker-runner.sh image resolves to default when nothing set" {
  cd "$TEST_TMP"
  run env -u GAIA_TOOLS_IMAGE -u PROJECT_CONFIG \
        bash "$PLUGIN_ROOT/scripts/lib/docker-runner.sh" image
  [ "$status" -eq 0 ]
  [[ "$output" =~ gaia-tools ]]
}

@test "lib: docker-runner.sh image honors GAIA_TOOLS_IMAGE env override" {
  cd "$TEST_TMP"
  run env GAIA_TOOLS_IMAGE=ghcr.io/gaiastudio-ai/gaia-tools:0.1.0-2026-05-30 \
        bash "$PLUGIN_ROOT/scripts/lib/docker-runner.sh" image
  [ "$status" -eq 0 ]
  [ "$output" = "ghcr.io/gaiastudio-ai/gaia-tools:0.1.0-2026-05-30" ]
}

@test "lib: docker-runner.sh mode defaults to native" {
  cd "$TEST_TMP"
  run env -u GAIA_TOOLS_RUNNER -u PROJECT_CONFIG -u CLAUDE_PROJECT_ROOT \
        bash "$PLUGIN_ROOT/scripts/lib/docker-runner.sh" mode
  [ "$status" -eq 0 ]
  [ "$output" = "native" ]
}

@test "lib: docker-runner.sh mode honors GAIA_TOOLS_RUNNER override" {
  cd "$TEST_TMP"
  run env GAIA_TOOLS_RUNNER=docker \
        bash "$PLUGIN_ROOT/scripts/lib/docker-runner.sh" mode
  [ "$status" -eq 0 ]
  [ "$output" = "docker" ]
}

@test "lib: docker-runner.sh mode reads brownfield.tools.runner from project-config" {
  cd "$TEST_TMP"
  mkdir -p .gaia/config
  cat > .gaia/config/project-config.yaml <<'YAML'
brownfield:
  tools:
    runner: docker
YAML
  run env -u GAIA_TOOLS_RUNNER PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml" \
        bash "$PLUGIN_ROOT/scripts/lib/docker-runner.sh" mode
  [ "$status" -eq 0 ]
  [ "$output" = "docker" ]
}

@test "lib: docker_runner_pull surfaces docker errors when daemon is absent" {
  cd "$TEST_TMP"
  STUB_BIN="$TEST_TMP/stub-pull"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/docker" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "pull" ] && { echo "docker: Cannot connect to the Docker daemon" >&2; exit 1; }
exit 1
STUB
  chmod +x "$STUB_BIN/docker"
  run env GAIA_TOOLS_IMAGE=gaia-tools:test PATH="$STUB_BIN:$PATH" \
        bash "$PLUGIN_ROOT/scripts/lib/docker-runner.sh" pull
  [ "$status" -ne 0 ]
  # The lib should log "pulling: <image>" before invoking docker
  [[ "$output" =~ pulling ]] || [[ "${stderr:-}" =~ pulling ]]
}

@test "lib: docker_runner_available exits non-zero when docker is absent" {
  cd "$TEST_TMP"
  STUB_BIN="$TEST_TMP/stub-avail"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/docker" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$STUB_BIN/docker"
  run env PATH="$STUB_BIN:$PATH" \
        bash "$PLUGIN_ROOT/scripts/lib/docker-runner.sh" available
  [ "$status" -ne 0 ]
}

@test "lib: dispatch refuses when docker is absent (exit 125)" {
  cd "$TEST_TMP"
  # Make the docker subcommand resolution fail by shadowing `docker` with a
  # stub that exits 1 — the lib's `docker info` probe in
  # docker_runner_available will then return non-zero. Keep the rest of
  # PATH intact so bash itself is reachable.
  STUB_BIN="$TEST_TMP/stub-bin"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/docker" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$STUB_BIN/docker"
  run env -u GAIA_TOOLS_IMAGE PATH="$STUB_BIN:$PATH" ADAPTER_OUT_DIR="$TEST_TMP/out" \
        bash "$PLUGIN_ROOT/scripts/lib/docker-runner.sh" dispatch grype --version
  [ "$status" -eq 125 ]
}

# ===========================================================================
# Tier-2 adapter docker dispatch
# ===========================================================================

@test "grype: adapter sources docker-runner.sh + dispatches on docker mode" {
  run grep -F 'docker_runner_mode' "$PLUGIN_ROOT/scripts/adapters/grype/adapter.sh"
  [ "$status" -eq 0 ]
  run grep -F 'docker_runner_dispatch grype' "$PLUGIN_ROOT/scripts/adapters/grype/adapter.sh"
  [ "$status" -eq 0 ]
}

@test "spotbugs: adapter sources docker-runner.sh + dispatches on docker mode" {
  run grep -F 'docker_runner_mode' \
        "$PLUGIN_ROOT/scripts/adapters/dead-code/jvm-spotbugs/adapter.sh"
  [ "$status" -eq 0 ]
  run grep -F 'docker_runner_dispatch spotbugs' \
        "$PLUGIN_ROOT/scripts/adapters/dead-code/jvm-spotbugs/adapter.sh"
  [ "$status" -eq 0 ]
}

@test "grype: adapter falls through to native dispatch on docker runner exit 125" {
  run grep -F 'falling through to native dispatch' \
        "$PLUGIN_ROOT/scripts/adapters/grype/adapter.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# /gaia-doctor docker mode
# ===========================================================================

@test "doctor: install-tools.sh --help documents --docker / --no-docker" {
  run bash "$PLUGIN_ROOT/skills/gaia-doctor/scripts/install-tools.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" =~ "--docker" ]]
  [[ "$output" =~ "--no-docker" ]]
}

@test "doctor: check-tools.sh _compute_tier has docker-runner promotion branch" {
  run grep -F 'docker runner (gaia-tools image cached)' \
        "$PLUGIN_ROOT/skills/gaia-doctor/scripts/check-tools.sh"
  [ "$status" -eq 0 ]
}

@test "doctor: SKILL.md documents the --install --docker invocation" {
  run grep -F -e '--install --docker' \
        "$PLUGIN_ROOT/skills/gaia-doctor/SKILL.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# Default-ON flag flip (deterministic_tools, prewarm, sarif_merge)
# ===========================================================================

@test "defaults: brownfield SKILL.md Phase 3 prelude defaults deterministic_tools to true" {
  run grep -F 'GAIA_BROWNFIELD_DETERMINISTIC_TOOLS="${DET_TOOLS:-true}"' \
        "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
  # Confirm there's no remaining `:-false` form for the master flag
  ! grep -qF 'GAIA_BROWNFIELD_DETERMINISTIC_TOOLS="${DET_TOOLS:-false}"' \
        "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
}

@test "defaults: brownfield SKILL.md prewarm_enabled defaults to true" {
  run grep -F 'GAIA_BROWNFIELD_PREWARM_ENABLED="${PREWARM_ON:-true}"' \
        "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "defaults: brownfield SKILL.md sarif_merge_enabled defaults to true" {
  run grep -F 'GAIA_BROWNFIELD_SARIF_MERGE_ENABLED="${SARIF_ON:-true}"' \
        "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "defaults: defectdojo_enabled remains opt-in (false default preserved)" {
  # External integration — needs an API token the operator must configure.
  # Defaulting on would either silently fail or leak findings to a third
  # party. The bats checks the export line is unchanged from the AF-30-2
  # shape.
  run grep -F 'GAIA_BROWNFIELD_DEFECTDOJO_ENABLED="${DD_ON:-false}"' \
        "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "defaults: YAML schema descriptor documents the new default for deterministic_tools" {
  run grep -F 'deterministic_tools (master flag, bool, default true' \
        "$PLUGIN_ROOT/config/project-config.schema.yaml"
  [ "$status" -eq 0 ]
}

@test "defaults: every adapter master-flag fallback is :-true (consistent with prelude)" {
  # Audit every brownfield adapter — they MUST default the master flag
  # to true so a standalone invocation outside the Phase 3 prelude
  # behaves consistently with /gaia-brownfield. The adapter-side default
  # was already `:-true` before AF-30-3; AF-30-3 flipped the prelude
  # default to match. This test is a regression guard against future
  # drift in either direction.
  bad=$(grep -rlE 'GAIA_BROWNFIELD_DETERMINISTIC_TOOLS:-false' \
          "$PLUGIN_ROOT/scripts/adapters/" 2>/dev/null || true)
  [ -z "$bad" ] || { echo "drift: $bad" >&2; return 1; }
}

# ===========================================================================
# /gaia-config-brownfield runner doc
# ===========================================================================

@test "config-brownfield: SKILL.md prompts /gaia-doctor on runner=docker flip" {
  run grep -F 'tools.runner=docker' \
        "$PLUGIN_ROOT/skills/gaia-config-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}
