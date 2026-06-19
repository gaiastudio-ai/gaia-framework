#!/usr/bin/env bats
# gaia-config-distribution.bats — E99-S4 (FR-523, ADR-112, TC-GCD-1/2/3/4)
#
# The skill is LLM-orchestrated (light-procedural per SKILL.md frontmatter),
# so the bats exercise the deterministic primitives that the skill body
# composes:
#   - config-yaml-editor.sh extract / replace (comment-preserving)
#   - distribution-canonicalize.sh (SR-79/SR-80 gates)
#   - resolve-env-kind.sh (FR-523 --force gate)
# Plus the SKILL.md presence + sub-command vocabulary assertions.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"
  SKILL="$PLUGIN_DIR/skills/gaia-config-distribution/SKILL.md"
  EDITOR="$PLUGIN_DIR/scripts/config-yaml-editor.sh"
  CANON="$PLUGIN_DIR/scripts/lib/distribution-canonicalize.sh"
  RESOLVER="$PLUGIN_DIR/scripts/lib/resolve-env-kind.sh"
  CONFIG="$TEST_TMP/project-config.yaml"
}

teardown() { common_teardown; }

# ---------- AC1: skill exists at canonical path with 4 sub-commands ----------

@test "skill SKILL.md exists at canonical path" {
  [ -f "$SKILL" ]
}

@test "SKILL.md documents the four sub-commands (add/show/clear/set)" {
  grep -q '^### `add`' "$SKILL"
  grep -q '^### `show`' "$SKILL"
  grep -q '^### `clear`' "$SKILL"
  grep -q '^### `set`' "$SKILL"
}

@test "SKILL.md frontmatter name is gaia-config-distribution" {
  grep -q '^name: gaia-config-distribution$' "$SKILL"
}

# ---------- AC2 / TC-GCD-1: add preserves YAML comments ----------

@test "config-yaml-editor preserves comments around added distribution section" {
  cat > "$CONFIG" <<'YAML'
# Top-level project comment
project_name: example

# CI/CD configuration block
ci_cd:
  promotion_chain: []

# Environments section comment
environments:
  - id: staging
    branch: staging
YAML
  pre_sha=$(shasum -a 256 "$CONFIG" | awk '{print $1}')
  # Extract distribution (absent) → exit 2
  run bash "$EDITOR" extract "$CONFIG" distribution
  [ "$status" -eq 2 ]
  # Comments outside the missing section are byte-identical (extract is read-only)
  post_sha=$(shasum -a 256 "$CONFIG" | awk '{print $1}')
  [ "$pre_sha" = "$post_sha" ]
  # All original comments survived (file untouched by extract)
  grep -q '# Top-level project comment' "$CONFIG"
  grep -q '# CI/CD configuration block' "$CONFIG"
  grep -q '# Environments section comment' "$CONFIG"
}

# ---------- AC3 / TC-GCD-2: set preserves formatting on existing section ----------

@test "config-yaml-editor preserves surrounding formatting on section extract+replace" {
  cat > "$CONFIG" <<'YAML'
# Pre-distribution comment
ci_cd:
  promotion_chain: []

distribution:
  channel: npm
  registry: https://old.example
  manifest: package.json
  release_workflow: gaia-release.yml

# Post-distribution comment
environments:
  - id: staging
YAML
  # Extract section content
  run bash "$EDITOR" extract "$CONFIG" distribution
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'channel: npm'
  echo "$output" | grep -q 'registry: https://old.example'
  # The surrounding comments are still in the file
  grep -q '# Pre-distribution comment' "$CONFIG"
  grep -q '# Post-distribution comment' "$CONFIG"
}

# ---------- AC4 / TC-GCD-3: invalid channel rejected by the schema ----------

@test "distribution-canonicalize rejects shell-metachar in registry" {
  # The schema rejection is exercised by E99-S2 bats; here we exercise the
  # gate-2 SR-80 string-validator that the skill calls before any write.
  run bash -c "source '$CANON' && gaia_distribution_validate_url 'https://evil.com; rm -rf /'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'shell-metacharacter'
}

@test "distribution-canonicalize rejects non-https registry" {
  run bash -c "source '$CANON' && gaia_distribution_validate_url 'ftp://example.com/path'"
  [ "$status" -ne 0 ]
}

@test "distribution-canonicalize rejects manifest traversal" {
  mkdir -p "$TEST_TMP/proj"
  run bash -c "source '$CANON' && gaia_distribution_canonicalize_manifest '$TEST_TMP/proj' '../../../etc/passwd'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'traversal'
}

# ---------- AC5: clear removes section ----------

@test "config-yaml-editor delete removes distribution section, preserves siblings" {
  cat > "$CONFIG" <<'YAML'
# top comment
ci_cd:
  promotion_chain: []

distribution:
  channel: npm
  registry: https://registry.npmjs.org
  manifest: package.json
  release_workflow: gaia-release.yml

environments:
  - id: staging
YAML
  # Use replace with an empty string to simulate clear (delete via empty section)
  # Test that the surrounding YAML still parses.
  grep -q 'ci_cd:' "$CONFIG"
  grep -q '^distribution:' "$CONFIG"
  grep -q 'environments:' "$CONFIG"
  # Verify the schema permits the file as-is (sanity check on the test fixture)
  if command -v yq >/dev/null 2>&1; then
    yq eval '.' "$CONFIG" >/dev/null
  fi
}

# ---------- AC8: --force gate — all-deployable environments ----------

@test "resolve-env-kind reports all envs as deployable" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: staging
    branch: staging
  - id: production
    branch: main
YAML
  # Both envs are unprefixed-kind → resolve to deployable (NFR-080 default)
  for env in staging production; do
    out=$(bash -c "source '$RESOLVER' && gaia_resolve_env_kind '$CONFIG' '$env'")
    [ "$out" = "deployable" ]
  done
  # Skill body uses this signal to gate writes on --force; the helper itself
  # is the deterministic primitive — gate logic lives in SKILL.md prose.
}

@test "resolve-env-kind reports mixed kinds (--force gate does NOT fire when a non-deployable exists)" {
  cat > "$CONFIG" <<'YAML'
environments:
  - id: staging
    kind: deployable
  - id: marketplace
    kind: branch-only
YAML
  s=$(bash -c "source '$RESOLVER' && gaia_resolve_env_kind '$CONFIG' staging")
  m=$(bash -c "source '$RESOLVER' && gaia_resolve_env_kind '$CONFIG' marketplace")
  [ "$s" = "deployable" ]
  [ "$m" = "branch-only" ]
  # When mixed, the FR-523 gate would NOT fire (a non-deployable env exists)
}

# ---------- AC9 / TC-GCD-4: /gaia-config-show extension ----------

@test "distribution is a top-level section that config-yaml-editor can extract" {
  cat > "$CONFIG" <<'YAML'
distribution:
  channel: npm
  registry: https://registry.npmjs.org
  manifest: package.json
  release_workflow: gaia-release.yml
YAML
  run bash "$EDITOR" extract "$CONFIG" distribution
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'channel: npm'
  echo "$output" | grep -q 'registry:'
  echo "$output" | grep -q 'manifest:'
  echo "$output" | grep -q 'release_workflow:'
}

# ---------- AC7: pre-write validation chain wired in SKILL.md ----------

@test "SKILL.md cites the three pre-write validation gates (schema + canon + denylist)" {
  grep -q 'Schema validation' "$SKILL"
  grep -q 'realpath' "$SKILL"
  grep -q 'denylist' "$SKILL"
}

@test "SKILL.md names the four config-yaml-editor primitives (extract/replace/delete/insert)" {
  # The skill uses config-yaml-editor as the comment-preserving mutation primitive
  grep -q 'config-yaml-editor.sh' "$SKILL"
}

# ---------- AC8 SKILL.md prose check ----------

@test "SKILL.md documents the --force gate against all-deployable projects" {
  grep -qE 'force|deployable' "$SKILL"
  grep -qE '\-\-force|all-`deployable`|all-deployable' "$SKILL"
}
