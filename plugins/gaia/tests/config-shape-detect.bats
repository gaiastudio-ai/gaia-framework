#!/usr/bin/env bats
# config-shape-detect.bats — E99-S5 (FR-524, ADR-112 §(f), TC-PR5-1..5)
#
# Bats coverage for the config-shape detector that drives /gaia-help Phase 5
# routing + /gaia-deploy-checklist publish-readiness mode. The detector reads
# environments[*].kind (with E99-S1 read-time default to deployable) and
# distribution: presence; emits the canonical 4-state classification.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"
  DETECT="$PLUGIN_DIR/scripts/lib/config-shape-detect.sh"
  CONFIG="$TEST_TMP/project-config.yaml"
  GAIA_HELP_SKILL="$PLUGIN_DIR/skills/gaia-help/SKILL.md"
  CHECKLIST_SKILL="$PLUGIN_DIR/skills/gaia-deploy-checklist/SKILL.md"
}

teardown() { common_teardown; }

# ---------- TC-PR5-1: all branch-only + distribution → publish-primary shape ----------

@test "all envs branch-only + distribution: present → publish-primary" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: marketplace
    kind: branch-only
distribution:
  channel: claude-marketplace
  registry: https://anthropic.com/marketplace
  manifest: plugin.json
  release_workflow: gaia-release.yml
YAML
  run bash -c "source '$DETECT' && gaia_config_shape_detect '$CONFIG'"
  [ "$status" -eq 0 ]
  [ "$output" = "publish-primary" ]
}

# ---------- TC-PR5-2: mixed envs + distribution → deploy-and-publish ----------

@test "mixed envs + distribution: → deploy-and-publish" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: staging
    kind: deployable
  - id: marketplace
    kind: branch-only
distribution:
  channel: npm
  registry: https://registry.npmjs.org
  manifest: package.json
  release_workflow: gaia-release.yml
YAML
  run bash -c "source '$DETECT' && gaia_config_shape_detect '$CONFIG'"
  [ "$status" -eq 0 ]
  [ "$output" = "deploy-and-publish" ]
}

# ---------- TC-PR5-3: all deployable + no distribution → deploy-only (back-compat baseline) ----------

@test "all deployable + no distribution: → deploy-only" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: staging
    kind: deployable
  - id: production
    kind: deployable
YAML
  run bash -c "source '$DETECT' && gaia_config_shape_detect '$CONFIG'"
  [ "$status" -eq 0 ]
  [ "$output" = "deploy-only" ]
}

@test "variant: legacy fixture (no kind field) → deploy-only" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: staging
    branch: staging
  - id: production
    branch: main
YAML
  run bash -c "source '$DETECT' && gaia_config_shape_detect '$CONFIG'"
  [ "$status" -eq 0 ]
  [ "$output" = "deploy-only" ]
}

# ---------- TC-PR5-4 (publish-readiness): no deployable + distribution → publish-readiness mode ----------

@test "no deployable envs + distribution: present → publish-readiness mode" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: marketplace
    kind: branch-only
  - id: cdn
    kind: distribution-only
distribution:
  channel: static-site
  registry: https://example.com
  manifest: site.config.json
  release_workflow: gaia-release.yml
  provider: s3
  domain: example.com
YAML
  run bash -c "source '$DETECT' && gaia_config_shape_detect '$CONFIG'"
  [ "$status" -eq 0 ]
  # publish-primary covers TC-PR5-1 AND TC-PR5-4 (both are no-deployable cases)
  [ "$output" = "publish-primary" ]
}

# ---------- TC-PR5-5 meta: 5-case decision table coverage ----------

@test "meta: 5-case decision table all reachable by detector" {
  # (i) all-deployable + no-dist → deploy-only
  cat > "$CONFIG" <<'YAML'
environments:
  - id: a
    kind: deployable
YAML
  s1=$(bash -c "source '$DETECT' && gaia_config_shape_detect '$CONFIG'")
  [ "$s1" = "deploy-only" ]

  # (ii) all-deployable + dist → hybrid (rare but legal)
  cat > "$CONFIG" <<'YAML'
environments:
  - id: a
    kind: deployable
distribution:
  channel: npm
  registry: https://registry.npmjs.org
  manifest: package.json
  release_workflow: gaia-release.yml
YAML
  s2=$(bash -c "source '$DETECT' && gaia_config_shape_detect '$CONFIG'")
  [ "$s2" = "deploy-and-publish" ]

  # (iii) all-branch-only + dist → publish-primary
  cat > "$CONFIG" <<'YAML'
environments:
  - id: a
    kind: branch-only
distribution:
  channel: npm
  registry: https://registry.npmjs.org
  manifest: package.json
  release_workflow: gaia-release.yml
YAML
  s3=$(bash -c "source '$DETECT' && gaia_config_shape_detect '$CONFIG'")
  [ "$s3" = "publish-primary" ]

  # (iv) all-distribution-only + dist → publish-primary
  cat > "$CONFIG" <<'YAML'
environments:
  - id: a
    kind: distribution-only
distribution:
  channel: static-site
  registry: https://example.com
  manifest: site.config.json
  release_workflow: gaia-release.yml
  provider: s3
  domain: example.com
YAML
  s4=$(bash -c "source '$DETECT' && gaia_config_shape_detect '$CONFIG'")
  [ "$s4" = "publish-primary" ]

  # (v) mixed + dist → deploy-and-publish
  cat > "$CONFIG" <<'YAML'
environments:
  - id: a
    kind: deployable
  - id: b
    kind: branch-only
distribution:
  channel: npm
  registry: https://registry.npmjs.org
  manifest: package.json
  release_workflow: gaia-release.yml
YAML
  s5=$(bash -c "source '$DETECT' && gaia_config_shape_detect '$CONFIG'")
  [ "$s5" = "deploy-and-publish" ]
}

# ---------- Edge cases ----------

@test "edge: no environments[] at all → unknown shape (caller decides)" {
  cat > "$CONFIG" <<'YAML'
project_name: example
YAML
  run bash -c "source '$DETECT' && gaia_config_shape_detect '$CONFIG'"
  # No environments to classify; emit a stable token so caller can fall back.
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

@test "edge: distribution: present but environments[] empty → publish-primary" {
  cat > "$CONFIG" <<'YAML'
environments: []
distribution:
  channel: npm
  registry: https://registry.npmjs.org
  manifest: package.json
  release_workflow: gaia-release.yml
YAML
  run bash -c "source '$DETECT' && gaia_config_shape_detect '$CONFIG'"
  [ "$status" -eq 0 ]
  [ "$output" = "publish-primary" ]
}

# ---------- SKILL.md citations (AC1, AC5) ----------

@test "gaia-help SKILL.md cites the config-shape detector and Phase 5 routing" {
  grep -qF 'config-shape-detect.sh' "$GAIA_HELP_SKILL"
  grep -qE 'Phase 5|FR-524|ADR-112' "$GAIA_HELP_SKILL"
}

@test "gaia-deploy-checklist SKILL.md documents publish-readiness mode" {
  grep -qE 'publish.readiness|publish-shape' "$CHECKLIST_SKILL"
  grep -qF 'config-shape-detect.sh' "$CHECKLIST_SKILL"
}

# ---------- Source-guard ----------

@test "source-guard: double-source is idempotent" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: a
    kind: deployable
YAML
  run bash -c "source '$DETECT' && source '$DETECT' && declare -F gaia_config_shape_detect >/dev/null && echo OK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------- Usage ----------

@test "usage: missing config arg fails" {
  run bash -c "source '$DETECT' && gaia_config_shape_detect"
  [ "$status" -ne 0 ]
}
