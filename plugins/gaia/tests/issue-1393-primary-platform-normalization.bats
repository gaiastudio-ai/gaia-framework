#!/usr/bin/env bash
# issue-1393-primary-platform-normalization.bats
#
# gaia-init wrote `primary_platform: backend` verbatim while normalizing the
# same "backend" answer to `[server]` on the platforms[] write path — an
# internal contradiction in a framework-generated config (a scanner sees
# backend ∉ [server]). The fix applies the same backend→server normalization
# to primary_platform so the two vocabularies agree.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GEN="$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh"
}
teardown() { common_teardown; }

_gen() {
  # $1 = answers JSON, $2 = phase. Emits the generated config to stdout-located file.
  local out="$BATS_TEST_TMPDIR/p"; mkdir -p "$out"
  printf '%s' "$1" | bash "$GEN" --path "$out" --name X --phase "${2:-full}" >/dev/null 2>&1 || true
  cat "$out/.gaia/config/project-config.yaml" 2>/dev/null \
    || cat "$out/project-config.yaml" 2>/dev/null \
    || find "$out" -name 'project-config.yaml' -exec cat {} \; 2>/dev/null
}

@test "issue-1393: primary_platform 'backend' is normalized to 'server' (matches platforms[])" {
  local json='{"project_name":"X","project_shape":"backend","project_kind":"backend","primary_platform":"backend","platforms":["backend"],"stacks":[{"name":"b","language":"python","paths":["b/"]}]}'
  local cfg; cfg="$(_gen "$json" full)"
  # primary_platform must NOT be the un-normalized 'backend'.
  ! printf '%s\n' "$cfg" | grep -qE '^primary_platform:[[:space:]]*"?backend"?[[:space:]]*$'
  # It should be 'server', the same vocab as platforms[].
  printf '%s\n' "$cfg" | grep -qE '^primary_platform:[[:space:]]*"?server"?[[:space:]]*$'
}

@test "issue-1393: a non-backend primary_platform passes through unchanged" {
  local json='{"project_name":"X","project_shape":"web-app","project_kind":"web-app","primary_platform":"web","platforms":["web"],"stacks":[{"name":"b","language":"python","paths":["b/"]}]}'
  local cfg; cfg="$(_gen "$json" full)"
  printf '%s\n' "$cfg" | grep -qE '^primary_platform:[[:space:]]*"?web"?[[:space:]]*$'
}

@test "issue-1393: primary_platform and platforms[] agree on the backend→server vocab" {
  local json='{"project_name":"X","project_shape":"backend","project_kind":"backend","primary_platform":"backend","platforms":["backend"],"stacks":[{"name":"b","language":"python","paths":["b/"]}]}'
  local cfg; cfg="$(_gen "$json" full)"
  # platforms[] already normalizes to server; primary_platform must match.
  printf '%s\n' "$cfg" | grep -qE '^primary_platform:[[:space:]]*"?server"?'
  printf '%s\n' "$cfg" | grep -qE 'server'
}
