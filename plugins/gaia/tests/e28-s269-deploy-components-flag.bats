#!/usr/bin/env bats
# /gaia-deploy --components surface.
#
# The deploy dispatch script supports a --components flag for component-scoped
# deploys, but the skill's documented CLI surface did not expose it, so an
# operator using the sanctioned command could not scope a deploy to the
# changed components. These tests pin the flag onto the skill's argument-hint,
# CLI-flags table, and the deploy-phase invocation, and confirm the underlying
# dispatch script still accepts it.

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL="$PLUGIN_ROOT/skills/gaia-deploy/SKILL.md"
  DISPATCH="$PLUGIN_ROOT/skills/gaia-deploy/scripts/deploy-dispatch.sh"
}

@test "deploy skill argument-hint exposes --components (AC1)" {
  [ -f "$SKILL" ]
  run grep -E '^argument-hint:.*\[--components <list>\]' "$SKILL"
  [ "$status" -eq 0 ]
}

@test "deploy skill CLI-flags table documents --components (AC1)" {
  run grep -E '^\| `--components <list>` \|' "$SKILL"
  [ "$status" -eq 0 ]
}

@test "deploy phase prose forwards --components to the dispatch (AC2)" {
  run grep -E 'deploy-dispatch\.sh .*\[--components <list>\]' "$SKILL"
  [ "$status" -eq 0 ]
}

@test "deploy-dispatch.sh still parses --components (AC3)" {
  [ -f "$DISPATCH" ]
  run grep -E '\-\-components\)' "$DISPATCH"
  [ "$status" -eq 0 ]
}

@test "deploy-dispatch.sh propagates adapter exit 3 as dormant, not exit 1 (AC-dormant)" {
  local tmpdir="${BATS_TEST_TMPDIR}/dormant-$$"
  mkdir -p "$tmpdir/out"

  # Adapter shim that exits 3 (dormant)
  cat > "$tmpdir/dormant-adapter.sh" <<'SHIM'
#!/usr/bin/env bash
exit 3
SHIM
  chmod +x "$tmpdir/dormant-adapter.sh"

  GAIA_DEPLOY_ADAPTER_CMD="$tmpdir/dormant-adapter.sh" \
    run "$DISPATCH" --env staging --version v1.0.0 --output-dir "$tmpdir/out"
  [ "$status" -eq 3 ]
  [[ "$output" == *"dormant"* ]]
}

@test "deploy-dispatch.sh generic non-zero adapter exit still exits 1 (AC-generic-fail)" {
  local tmpdir="${BATS_TEST_TMPDIR}/fail-$$"
  mkdir -p "$tmpdir/out"

  # Adapter shim that exits 42 (generic failure)
  cat > "$tmpdir/fail-adapter.sh" <<'SHIM'
#!/usr/bin/env bash
exit 42
SHIM
  chmod +x "$tmpdir/fail-adapter.sh"

  GAIA_DEPLOY_ADAPTER_CMD="$tmpdir/fail-adapter.sh" \
    run "$DISPATCH" --env staging --version v1.0.0 --output-dir "$tmpdir/out"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKED"* ]]
}
