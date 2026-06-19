#!/usr/bin/env bats
# AF-2026-05-31-2: Test13 findings sweep (29 F + 0 V + 3 D).
#
# Scope: every fix landed in the AF-31-2 branch. Tests the structural shape
# of each fix (file content, script behaviour) plus end-to-end repros of the
# 3 bash-3.2 regressions I introduced in AF-31-1 (F-14, F-24, F-28) so the
# coverage doesn't drift back when a future sprint touches these files.
#
# Portability: every test is bash-3.2 compatible — wired into the
# cross-platform-portability CI matrix.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DOC_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../documentation" && pwd)"
}

teardown() { common_teardown; }

# ===========================================================================
# Docker bundle — F-01..F-11
# ===========================================================================

@test "Dockerfile grype RUN uses tar -C /opt/fetch (no same-file mv)" {
  run grep -F 'tar -xzf grype.tar.gz -C /opt/fetch grype' "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "Dockerfile syft RUN uses tar -C /opt/fetch (no same-file mv)" {
  run grep -F 'tar -xzf syft.tar.gz -C /opt/fetch syft' "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "Dockerfile .arch_osv emits underscore (linux_amd64), not dash" {
  run grep -F 'echo "linux_amd64" > /opt/fetch/.arch_osv' "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "Dockerfile .arch_osv arm64 uses underscore" {
  run grep -F 'echo "linux_arm64" > /opt/fetch/.arch_osv' "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "Dockerfile pins cdxgen to a real version (10.11.0)" {
  run grep -F '@cyclonedx/cdxgen@10.11.0' "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "Dockerfile installs Node 20 from NodeSource (not the Debian 18)" {
  run grep -F 'node_20.x' "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "Dockerfile cdxgen install is non-fatal (|| echo WARNING)" {
  run grep -F 'cdxgen install failed' "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "Dockerfile grype db update + status tolerate non-zero" {
  run grep -F 'grype db update || true' "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -eq 0 ]
  run grep -F 'grype db status || true' "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "Dockerfile chmod +x spotbugs bin/" {
  run grep -F -e 'chmod -R +x "spotbugs-${SPOTBUGS_VERSION}/bin/"' "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "entrypoint.sh calls cyclonedx-py --version (not cyclonedx-bom)" {
  run grep -F -e 'cyclonedx-py --version' "$PLUGIN_ROOT/tools/gaia-tools/gaia-tools-entrypoint.sh"
  [ "$status" -eq 0 ]
}

@test "entrypoint.sh grype awk pattern is ^Version: (not Application:)" {
  run grep -F -e "'/^Version:/ {print" "$PLUGIN_ROOT/tools/gaia-tools/gaia-tools-entrypoint.sh"
  [ "$status" -eq 0 ]
}

@test "Dockerfile bakes ENV GRYPE_DB_VALIDATE_AGE=false" {
  run grep -F 'ENV GRYPE_DB_VALIDATE_AGE=false' "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "CHANGELOG --docker line is qualified (install only)" {
  run grep -F -e '/gaia-doctor --install --docker' "$PLUGIN_ROOT/CHANGELOG.md"
  [ "$status" -eq 0 ]
}

@test "..F-11: GAIA_TOOLS_VERSION at or beyond 0.1.1" {
  # AF-2026-05-31-3 / Test14 F-02 bumped the version from 0.1.1 → 0.1.2 to
  # mark the image rebuild that actually bundles Sarif.Multitool. Accept
  # any 0.1.X ≥ 1 so future bumps don't require touching this test.
  run grep -E '^ARG GAIA_TOOLS_VERSION=0\.1\.[1-9][0-9]*' "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "Dockerfile installs Microsoft.Sarif.Multitool" {
  run grep -F 'Microsoft.Sarif.Multitool' "$PLUGIN_ROOT/tools/gaia-tools/Dockerfile"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-14 — orchestrator.sh excludes[@] unbound (regression I introduced)
# ===========================================================================

@test "orchestrator.sh length-guards excludes[@] iteration" {
  run grep -F '${#excludes[@]}' "$PLUGIN_ROOT/scripts/adapters/brownfield/orchestrator.sh"
  [ "$status" -eq 0 ]
}

@test "orchestrator.sh runs end-to-end on bash 3.2 with no excludes" {
  # End-to-end repro: 1 stack, no excludes, no paths — pure passthrough.
  cfg="$TEST_TMP/cfg.yaml"
  cat >"$cfg" <<EOF
stacks:
  - name: backend
    path: src
EOF
  mkdir -p "$TEST_TMP/src"
  echo "x" > "$TEST_TMP/src/a.py"
  run bash -c "ORCH_CONFIG='$cfg' ORCH_ROOT='$TEST_TMP' ORCH_OUT_DIR='$TEST_TMP/out' /bin/bash '$PLUGIN_ROOT/scripts/adapters/brownfield/orchestrator.sh'"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/out/backend.files" ]
}

# ===========================================================================
# F-24 — sprint-state.sh _init_args[@] unbound (regression I introduced)
# ===========================================================================

@test "sprint-state.sh init succeeds with zero optional flags" {
  mkdir -p "$TEST_TMP/.gaia/state"
  # sprint-state.sh resolves the yaml relative to cwd (not CLAUDE_PROJECT_ROOT
  # directly) — wrap the invocation in a subshell with cd so each test gets
  # an isolated working tree regardless of leftover state from a prior run.
  run bash -c "cd '$TEST_TMP' && CLAUDE_PROJECT_ROOT='$TEST_TMP' /bin/bash '$PLUGIN_ROOT/scripts/sprint-state.sh' init --sprint-id sprint-1"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/.gaia/state/sprint-status.yaml" ]
}

@test "sprint-state.sh wrapper byte-identical (regression guard)" {
  src="$PLUGIN_ROOT/scripts/sprint-state.sh"
  dst="$PLUGIN_ROOT/skills/gaia-dev-story/scripts/sprint-state.sh"
  diff -q "$src" "$dst"
}

# ===========================================================================
# F-28 — run-tests.sh green-suite crash (regression I introduced)
# ===========================================================================

@test "pytest grep pipelines terminated with || true" {
  # Both the pytest_pass and pytest_fail grep+tail+awk pipelines.
  count="$(grep -F '[0-9]+ passed' "$PLUGIN_ROOT/scripts/run-tests.sh" | grep -c '|| true' || true)"
  [ "$count" -ge 1 ]
  count="$(grep -F '[0-9]+ failed' "$PLUGIN_ROOT/scripts/run-tests.sh" | grep -c '|| true' || true)"
  [ "$count" -ge 1 ]
}

@test "bats + go-test grep pipelines also terminated with || true" {
  # The 4 framework-output greps in run-tests.sh (the patterns are literal in
  # the source — `^ok [0-9]+`, `^not ok [0-9]+`, `^--- PASS:`, `^--- FAIL:`).
  for pat in '^ok [0-9]+' '^not ok [0-9]+' '^--- PASS:' '^--- FAIL:'; do
    line="$(grep -F -e "$pat" "$PLUGIN_ROOT/scripts/run-tests.sh" || true)"
    case "$line" in
      *'|| true'*) : ;;
      *) echo "missing || true on $pat (matched: $line)" >&2; return 1 ;;
    esac
  done
}

# ===========================================================================
# F-15 + F-18 — docker-runner wiring (vulture / sbom / sarif-merge)
# ===========================================================================

@test "brownfield SKILL.md syft step probes docker_runner_mode" {
  run grep -F 'docker_runner_dispatch syft' "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "python-vulture adapter sources docker-runner.sh" {
  run grep -F '_VULTURE_DOCKER_RUNNER_LIB' "$PLUGIN_ROOT/scripts/adapters/dead-code/python-vulture/adapter.sh"
  [ "$status" -eq 0 ]
}

@test "python-vulture adapter dispatches via docker_runner" {
  run grep -F 'docker_runner_dispatch vulture' "$PLUGIN_ROOT/scripts/adapters/dead-code/python-vulture/adapter.sh"
  [ "$status" -eq 0 ]
}

@test "go-deadcode adapter probes docker runner first" {
  run grep -F '_DEADCODE_DOCKER_RUNNER' "$PLUGIN_ROOT/scripts/adapters/dead-code/go-deadcode/adapter.sh"
  [ "$status" -eq 0 ]
}

@test "sarif-merge.sh probes docker runner before host PATH" {
  run grep -F '_SARIF_DOCKER_RUNNER' "$PLUGIN_ROOT/scripts/adapters/brownfield/sarif-merge.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-16 + F-17 — grype adapter -o sarif=<path> + exit propagation
# ===========================================================================

@test "grype adapter uses -o sarif=<path>" {
  run grep -F -e '-o sarif="/out/grype.sarif"' "$PLUGIN_ROOT/scripts/adapters/grype/adapter.sh"
  [ "$status" -eq 0 ]
}

@test "grype adapter captures exit via _grype_rc variable" {
  run grep -F '_grype_rc' "$PLUGIN_ROOT/scripts/adapters/grype/adapter.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-06 — gaia-config-brownfield supports tools.image
# ===========================================================================

@test "gaia-config-brownfield SKILL.md lists tools.image" {
  run grep -F 'brownfield.tools.image' "$PLUGIN_ROOT/skills/gaia-config-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "gaia-config-brownfield preamble renders tools.image" {
  run grep -F 'tools.image:' "$PLUGIN_ROOT/skills/gaia-config-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-13 — brownfield SKILL.md uses integer --step
# ===========================================================================

@test "brownfield SKILL.md uses integer --step 1" {
  run grep -F -e '--step 1' "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "brownfield SKILL.md no longer says --step phase-1-discovery" {
  run grep -F -e '--step phase-1-discovery' "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# F-23 — materialize-sprint-stories.sh flag grammar in SKILL.md
# ===========================================================================

@test "create-story SKILL.md no longer documents --project-config" {
  # The SKILL.md prose should no longer document the bogus --project-config flag.
  count="$(grep -F -e '--project-config <yaml>' "$PLUGIN_ROOT/skills/gaia-create-story/SKILL.md" 2>/dev/null | wc -l | tr -d ' ' || true)"
  [ "${count:-0}" -eq 0 ]
}

@test "SKILL.md notes --keys is comma-separated" {
  run grep -F 'COMMA-separated' "$PLUGIN_ROOT/skills/gaia-create-story/SKILL.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-26 — materialize-sprint-stories.sh writes points
# ===========================================================================

@test "materialize-sprint-stories.sh emits points: field" {
  run grep -F 'points: %s' "$PLUGIN_ROOT/scripts/materialize-sprint-stories.sh"
  [ "$status" -eq 0 ]
}

@test "materialize-sprint-stories.sh derives points from size" {
  # The fallback sizing-map table.
  for sz in 'S|s' 'M|m' 'L|l' 'XL|xl|XXL|xxl'; do
    run grep -F "$sz" "$PLUGIN_ROOT/scripts/materialize-sprint-stories.sh"
    [ "$status" -eq 0 ]
  done
}

# ===========================================================================
# F-27 — transition-story-status.sh review→done gate
# ===========================================================================

@test "transition-story-status.sh has composite gate guard" {
  run grep -F 'review → done refused' "$PLUGIN_ROOT/scripts/transition-story-status.sh"
  [ "$status" -eq 0 ]
}

@test "GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE escape hatch documented" {
  run grep -F 'GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE' "$PLUGIN_ROOT/scripts/transition-story-status.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-19 — CI scaffold no longer silent-no-op
# ===========================================================================

@test "generate-ci-scaffold.sh stub exits 1 with error" {
  run grep -F '&& exit 1' "$PLUGIN_ROOT/skills/gaia-init/scripts/generate-ci-scaffold.sh"
  [ "$status" -eq 0 ]
}

@test "no remaining 'echo TODO' lines that exit 0" {
  run grep -F 'echo "TODO — wire up' "$PLUGIN_ROOT/skills/gaia-init/scripts/generate-ci-scaffold.sh"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# F-20 — test-environment-manifest.sh attribution uses caller
# ===========================================================================

@test "test-environment-manifest.sh reads GAIA_TEST_ENV_CALLER" {
  run grep -F 'GAIA_TEST_ENV_CALLER' "$PLUGIN_ROOT/scripts/lib/test-environment-manifest.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-29 — epic-status-dashboard.sh consults archived sprints
# ===========================================================================

@test "epic-status-dashboard.sh consults sprint-archive/" {
  run grep -F 'sprint-archive' "$PLUGIN_ROOT/scripts/epic-status-dashboard.sh"
  [ "$status" -eq 0 ]
}

@test "epic-status-dashboard.sh has _parse_sprint_yaml helper" {
  run grep -F '_parse_sprint_yaml' "$PLUGIN_ROOT/scripts/epic-status-dashboard.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-05c — compliance.ui_present documented in init SKILL.md
# ===========================================================================

@test "c: init SKILL.md documents compliance.ui_present encoding" {
  run grep -F 'compliance.ui_present' "$PLUGIN_ROOT/skills/gaia-init/SKILL.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# F-12 — orchestration-warning.sh stable session cookie
# ===========================================================================

@test "orchestration-warning.sh writes session cookie" {
  run grep -F '_cookie_file' "$PLUGIN_ROOT/scripts/orchestration-warning.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# D-01 — gaia-tools image documentation page
# ===========================================================================

@test "D-01: gaia-docker-workflow.html has gaia-tools-image section" {
  run grep -F -e 'id="gaia-tools-image"' "$DOC_ROOT/commands/gaia-docker-workflow.html"
  [ "$status" -eq 0 ]
}

@test "D-01: gaia-docker-workflow.html documents Sarif.Multitool" {
  run grep -F 'Sarif.Multitool' "$DOC_ROOT/commands/gaia-docker-workflow.html"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# D-02 — tools.image override env var documented
# ===========================================================================

@test "D-02: gaia-docker-workflow.html documents GAIA_TOOLS_IMAGE env" {
  run grep -F 'GAIA_TOOLS_IMAGE' "$DOC_ROOT/commands/gaia-docker-workflow.html"
  [ "$status" -eq 0 ]
}
