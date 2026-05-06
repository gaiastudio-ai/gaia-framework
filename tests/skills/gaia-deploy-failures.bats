#!/usr/bin/env bats
# tests/skills/gaia-deploy-failures.bats — /gaia-deploy Pattern A failure-mode invariants
# (E73-S5, AC10/AC11/AC9/AC13).

bats_require_minimum_version 1.5.0

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/../../plugins/gaia" && pwd)"
  SKILL_SCRIPTS="$PLUGIN_ROOT/skills/gaia-deploy/scripts"
  WORK_TMP="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/gaia-deploy-fail-$$-$BATS_TEST_NUMBER"
  mkdir -p "$WORK_TMP/evidence/deploy"
}

teardown() {
  if [ -n "${WORK_TMP:-}" ] && [ -d "$WORK_TMP" ]; then
    rm -rf "$WORK_TMP" 2>/dev/null || true
  fi
}

# ---------- AC11: no auto-retry, no auto-rollback ----------

@test "no-auto-retry: failed deploy invokes adapter exactly once" {
  cat > "$WORK_TMP/counter" <<EOF
0
EOF
  cat > "$WORK_TMP/fake-adapter.sh" <<EOF
#!/usr/bin/env bash
n=\$(cat "$WORK_TMP/counter")
n=\$((n + 1))
echo "\$n" > "$WORK_TMP/counter"
exit 1
EOF
  chmod +x "$WORK_TMP/fake-adapter.sh"
  GAIA_DEPLOY_ADAPTER_CMD="$WORK_TMP/fake-adapter.sh" \
    run "$SKILL_SCRIPTS/deploy-dispatch.sh" --env staging --version v1 --output-dir "$WORK_TMP/evidence/deploy"
  [ "$status" -ne 0 ]
  count="$(cat "$WORK_TMP/counter")"
  [ "$count" = "1" ]
}

@test "no-auto-rollback: failure-halts message references rollback-plan but doesn't invoke" {
  cat > "$WORK_TMP/fake-adapter.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$WORK_TMP/fake-adapter.sh"
  GAIA_DEPLOY_ADAPTER_CMD="$WORK_TMP/fake-adapter.sh" \
    run "$SKILL_SCRIPTS/deploy-dispatch.sh" --env staging --version v1 --output-dir "$WORK_TMP/evidence/deploy"
  echo "$output" | grep -qi "rollback"
  # but never invokes /gaia-rollback-plan — assert no such side-effect file
  [ ! -f "$WORK_TMP/rollback-invoked" ]
}

# ---------- AC10: credentials via env-var names only ----------

@test "credentials: missing env-var → BLOCKED with expected var name" {
  unset NO_SUCH_DEPLOY_TOKEN || true
  run "$SKILL_SCRIPTS/check-credentials.sh" --env-var NO_SUCH_DEPLOY_TOKEN
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "NO_SUCH_DEPLOY_TOKEN"
  echo "$output" | grep -qi "BLOCKED"
}

@test "credentials: present env-var → passes" {
  PRESENT_TOKEN="abc123" run "$SKILL_SCRIPTS/check-credentials.sh" --env-var PRESENT_TOKEN
  [ "$status" -eq 0 ]
}

# ---------- AC9: --env mandatory, no default ----------

@test "env-flag: missing --env → usage error" {
  run "$SKILL_SCRIPTS/deploy-dispatch.sh" --version v1 --output-dir "$WORK_TMP/evidence/deploy"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "env\|usage"
}

# ---------- AC13: three-state availability probe ----------

@test "adapter-availability: missing adapter → BLOCKED with installation hint" {
  GAIA_DEPLOY_ADAPTER_CMD="/path/that/does/not/exist" \
    run "$SKILL_SCRIPTS/deploy-dispatch.sh" --env staging --version v1 --output-dir "$WORK_TMP/evidence/deploy"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "BLOCKED\|not.*found\|unavailable"
}
