#!/usr/bin/env bats
# generate-config.sh ci_platform scalar coercion.
#
# An operator who answers the init questionnaire with a bare provider string
# (`ci_platform: github-actions`) rather than the documented object form
# (`{ provider: ... }`) previously crashed config generation with
# `AttributeError: 'str' object has no attribute 'get'`. The sibling
# compliance and environments blocks already coerce their list/scalar forms;
# this pins the matching scalar-coercion guard on the ci_platform block.

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GEN="$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh"
}

@test "generate-config declares the ci_platform non-object coercion guard (AC4)" {
  grep -qF 'isinstance(ci, str)' "$GEN"
  # The guard must also collapse non-str, non-dict forms (list/int/bool) — the
  # str-only guard left those crashing identically.
  grep -qF 'elif not isinstance(ci, dict)' "$GEN"
}

@test "non-object ci_platform forms (list/int/bool) no longer crash (AC1)" {
  cd "$BATS_TEST_TMPDIR"
  for val in '[]' '123' 'true'; do
    cat > bundle.json <<EOF
{
  "project_name": "test",
  "project_kind": "service",
  "stacks": [{"name": "backend", "language": "python", "paths": ["src/"]}],
  "ci_platform": $val,
  "platforms": ["github-actions"]
}
EOF
    run bash "$GEN" --path "./out-$val" --name test --phase full < bundle.json
    [ "$status" -eq 0 ]
    [[ "$output" != *"AttributeError"* ]]
    [[ "$output" != *"has no attribute"* ]]
    # Non-coercible form → block omitted (no provider to write).
    cfg="$(cat "./out-$val/.gaia/config/project-config.yaml")"
    [[ "$cfg" != *"ci_platform:"* ]]
  done
}

@test "scalar ci_platform no longer crashes — exits 0 with provider set (AC1)" {
  cd "$BATS_TEST_TMPDIR"
  cat > bundle.json <<'EOF'
{
  "project_name": "test",
  "project_kind": "service",
  "stacks": [{"name": "backend", "language": "python", "paths": ["src/"]}],
  "ci_platform": "github-actions",
  "platforms": ["github-actions"]
}
EOF
  run bash "$GEN" --path . --name test --phase full < bundle.json
  [ "$status" -eq 0 ]
  cfg="$(cat .gaia/config/project-config.yaml)"
  [[ "$cfg" == *"ci_platform:"* ]]
  [[ "$cfg" == *"provider: github-actions"* ]]
  # No Python traceback leaked to the output.
  [[ "$output" != *"AttributeError"* ]]
  [[ "$output" != *"has no attribute"* ]]
}

@test "scalar ci_platform underscore form normalizes to hyphen (AC1)" {
  cd "$BATS_TEST_TMPDIR"
  cat > bundle.json <<'EOF'
{
  "project_name": "test",
  "project_kind": "service",
  "stacks": [{"name": "backend", "language": "python", "paths": ["src/"]}],
  "ci_platform": "github_actions",
  "platforms": ["github-actions"]
}
EOF
  run bash "$GEN" --path . --name test --phase full < bundle.json
  [ "$status" -eq 0 ]
  cfg="$(cat .gaia/config/project-config.yaml)"
  # underscore->hyphen normalization (issue-1244) still applies to the
  # coerced scalar provider.
  [[ "$cfg" == *"provider: github-actions"* ]]
}

@test "object-form ci_platform is unchanged — no regression (AC2)" {
  cd "$BATS_TEST_TMPDIR"
  cat > bundle.json <<'EOF'
{
  "project_name": "test",
  "project_kind": "service",
  "stacks": [{"name": "backend", "language": "python", "paths": ["src/"]}],
  "ci_platform": {"provider": "github-actions", "pipeline": "ci.yml"},
  "platforms": ["github-actions"]
}
EOF
  run bash "$GEN" --path . --name test --phase full < bundle.json
  [ "$status" -eq 0 ]
  cfg="$(cat .gaia/config/project-config.yaml)"
  [[ "$cfg" == *"provider: github-actions"* ]]
  [[ "$cfg" == *"pipeline: ci.yml"* ]]
}

@test "absent ci_platform is unchanged — block omitted (AC3)" {
  cd "$BATS_TEST_TMPDIR"
  cat > bundle.json <<'EOF'
{
  "project_name": "test",
  "project_kind": "service",
  "stacks": [{"name": "backend", "language": "python", "paths": ["src/"]}],
  "platforms": ["github-actions"]
}
EOF
  run bash "$GEN" --path . --name test --phase full < bundle.json
  [ "$status" -eq 0 ]
  cfg="$(cat .gaia/config/project-config.yaml)"
  [[ "$cfg" != *"ci_platform:"* ]]
}

@test "empty-string ci_platform coerces to omitted block, no crash (AC1)" {
  cd "$BATS_TEST_TMPDIR"
  cat > bundle.json <<'EOF'
{
  "project_name": "test",
  "project_kind": "service",
  "stacks": [{"name": "backend", "language": "python", "paths": ["src/"]}],
  "ci_platform": "",
  "platforms": ["github-actions"]
}
EOF
  run bash "$GEN" --path . --name test --phase full < bundle.json
  [ "$status" -eq 0 ]
  cfg="$(cat .gaia/config/project-config.yaml)"
  [[ "$cfg" != *"ci_platform:"* ]]
  [[ "$output" != *"AttributeError"* ]]
}
