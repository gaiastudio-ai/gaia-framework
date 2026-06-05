#!/usr/bin/env bash
# issue-1395-brownfield-walkthrough-tier2.bats
#
# The brownfield walkthrough (first-30-minutes-brownfield.html) omitted the
# entire Docker deterministic-tools / tier-2 setup — a user following it never
# learned how to enable the gaia-tools runner that powers the CVE/SBOM/dead-code
# battery. This guards the added "Enable deterministic tools (tier-2 via Docker)"
# step.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GAIA_PUBLIC_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
  WALKTHROUGH="$GAIA_PUBLIC_ROOT/documentation/tutorials/first-30-minutes-brownfield.html"
}
teardown() { common_teardown; }

@test "issue-1395: walkthrough file exists" {
  [ -f "$WALKTHROUGH" ]
}

@test "issue-1395: walkthrough now documents the Docker tier-2 deterministic-tools setup" {
  [ -f "$WALKTHROUGH" ]
  # The headline terms the issue flagged as entirely absent must now appear.
  grep -qiE 'tier-2' "$WALKTHROUGH"
  grep -qiF 'gaia-tools' "$WALKTHROUGH"
  grep -qiF 'tools.runner: docker' "$WALKTHROUGH"
  grep -qiF 'tools.image' "$WALKTHROUGH"
  grep -qiF 'gaia-config-brownfield' "$WALKTHROUGH"
}

@test "issue-1395: walkthrough names the tier-2 scanners (grype / syft / dead-code)" {
  grep -qiF 'grype' "$WALKTHROUGH"
  grep -qiF 'syft' "$WALKTHROUGH"
}

@test "issue-1395: the tier-2 step links to the config-brownfield command page (valid target)" {
  grep -qF 'gaia-config-brownfield.html' "$WALKTHROUGH"
  [ -f "$GAIA_PUBLIC_ROOT/documentation/commands/gaia-config-brownfield.html" ]
}

@test "issue-1395: the tier-2 step notes graceful degradation when skipped" {
  grep -qiE 'degrade|heuristic|skip this step' "$WALKTHROUGH"
}
