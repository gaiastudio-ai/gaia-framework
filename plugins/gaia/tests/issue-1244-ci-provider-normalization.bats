#!/usr/bin/env bash
# issue-1244-ci-provider-normalization.bats
#
# generate-config.sh wrote ci_platform.provider verbatim, so a natural
# underscore answer (`github_actions`) was emitted as-is and then REJECTED by
# the schema's ciProvider enum, which uses hyphens (`github-actions`,
# `gitlab-ci`, `azure-pipelines`, `bitbucket-pipelines`). The fix normalizes
# the provider underscore->hyphen so the documented-but-naturally-typed forms
# validate.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GEN="$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh"
}
teardown() { common_teardown; }

_gen() {
  # Fresh, unique output dir per call — generate-config.sh refuses to clobber
  # an existing config, so reusing a dir would return stale content.
  local out; out="$(mktemp -d "$BATS_TEST_TMPDIR/gen.XXXXXX")"
  printf '%s' "$1" | bash "$GEN" --path "$out" --name X --phase "${2:-full}" >/dev/null 2>&1 || true
  find "$out" -name 'project-config.yaml' -exec cat {} \; 2>/dev/null
}

@test "issue-1244: ci_platform.provider 'github_actions' is normalized to 'github-actions'" {
  local json='{"project_name":"X","project_shape":"web-app","project_kind":"web-app","ci_platform":{"provider":"github_actions"},"stacks":[{"name":"b","language":"python","paths":["b/"]}]}'
  local cfg; cfg="$(_gen "$json" full)"
  printf '%s\n' "$cfg" | grep -qE '^[[:space:]]+provider:[[:space:]]*"?github-actions"?'
  ! printf '%s\n' "$cfg" | grep -qE 'provider:.*github_actions'
}

@test "issue-1244: an already-hyphenated provider passes through unchanged" {
  local json='{"project_name":"X","project_shape":"web-app","project_kind":"web-app","ci_platform":{"provider":"gitlab-ci"},"stacks":[{"name":"b","language":"python","paths":["b/"]}]}'
  local cfg; cfg="$(_gen "$json" full)"
  printf '%s\n' "$cfg" | grep -qE '^[[:space:]]+provider:[[:space:]]*"?gitlab-ci"?'
}

@test "issue-1244: azure_pipelines and bitbucket_pipelines normalize too" {
  for p in azure_pipelines bitbucket_pipelines; do
    local json="{\"project_name\":\"X\",\"project_shape\":\"web-app\",\"project_kind\":\"web-app\",\"ci_platform\":{\"provider\":\"$p\"},\"stacks\":[{\"name\":\"b\",\"language\":\"python\",\"paths\":[\"b/\"]}]}"
    local cfg; cfg="$(_gen "$json" full)"
    local want="${p//_/-}"
    printf '%s\n' "$cfg" | grep -qE "provider:[[:space:]]*\"?${want}\"?" \
      || { echo "no normalization for $p -> $want"; printf '%s\n' "$cfg" | grep provider; false; }
  done
}
