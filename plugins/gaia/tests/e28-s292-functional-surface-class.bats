#!/usr/bin/env bats
# e28-s292-functional-surface-class.bats — functional-vs-visual surface class +
# the no-functional-coverage signal + the un-auto-approvable env-limited skip.
#
# These tests drive the REAL dispatch-surface.sh (class field) and the REAL
# track-b-dispatch.sh reducer (functional_exercised / no_functional_surface /
# env_limited_surfaces). The env-limited path uses a stub dispatch-surface that
# returns a non-2 non-zero exit (configured-but-env-unavailable) so the tracked
# skip is exercised without mocking the reducer itself.

load 'test_helper.bash'

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DISPATCH="$REPO_ROOT/plugins/gaia/skills/gaia-test-manual/scripts/dispatch-surface.sh"
  TRACKB="$REPO_ROOT/plugins/gaia/skills/gaia-sprint-review/scripts/track-b-dispatch.sh"

  WORK="$TEST_TMP/work"
  mkdir -p "$WORK/.gaia/memory/checkpoints"
  printf '%s\n' '.gaia/memory/checkpoints/sprint-review-*' > "$WORK/.gitignore"
}

teardown() { common_teardown; }

have_jq() { command -v jq >/dev/null 2>&1; }

# extract the JSON object the runner mixes with log lines
_json() { sed -n '/^{/,/^}/p'; }

# =====================================================================
# AC1: each surface emits its verification class
# =====================================================================

@test "api surface emits class: functional" {
  cat > "$WORK/cfg.yaml" <<'EOF'
project_name: p
platforms: [server]
EOF
  run bash "$DISPATCH" --surface api --target "echo ok" \
    --evidence-dir "$WORK/ev" --config "$WORK/cfg.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"class":"functional"'* ]]
}

@test "browser surface emits class: visual" {
  cat > "$WORK/cfg.yaml" <<'EOF'
project_name: p
platforms: [web]
EOF
  run bash "$DISPATCH" --surface browser --target "story-slug" \
    --evidence-dir "$WORK/ev" --config "$WORK/cfg.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"class":"visual"'* ]]
}

@test "mobile + desktop surfaces emit class: visual" {
  cat > "$WORK/cfg.yaml" <<'EOF'
project_name: p
platforms: [ios]
sprint_review:
  desktop_commands:
    app: "echo x"
EOF
  run bash "$DISPATCH" --surface mobile --target t --evidence-dir "$WORK/ev" --config "$WORK/cfg.yaml"
  [[ "$output" == *'"class":"visual"'* ]]
  run bash "$DISPATCH" --surface desktop --target t --evidence-dir "$WORK/ev" --config "$WORK/cfg.yaml"
  [[ "$output" == *'"class":"visual"'* ]]
}

@test "a dormant (not configured) surface still emits its class on the SKIPPED envelope" {
  cat > "$WORK/cfg.yaml" <<'EOF'
project_name: p
platforms: [web]
EOF
  # server is absent → api SKIPPED, but the envelope still carries class.
  run bash "$DISPATCH" --surface api --target "echo ok" \
    --evidence-dir "$WORK/ev" --config "$WORK/cfg.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"verdict":"SKIPPED"'* ]]
  [[ "$output" == *'"class":"functional"'* ]]
}

# A realistic stub mirrors the REAL dispatch-surface.sh exit contract: it ALWAYS
# exits 0 for a dispatched outcome (the verdict rides in the JSON); a dormant
# surface is exit 0 + a SKIPPED JSON envelope. $1 = the api verdict to emit.
_write_realistic_stub() {
  local api_verdict="$1"
  cat > "$WORK/stub.sh" <<STUBEOF
#!/usr/bin/env bash
SURF=""
while [ \$# -gt 0 ]; do case "\$1" in --surface) SURF="\$2"; shift 2;; *) shift;; esac; done
case "\$SURF" in
  api) echo '{"surface":"api","class":"functional","verdict":"$api_verdict"}'; exit 0 ;;
  *)   echo "{\"surface\":\"\$SURF\",\"class\":\"visual\",\"verdict\":\"SKIPPED\",\"reason\":\"not configured\"}"; exit 0 ;;
esac
STUBEOF
  chmod +x "$WORK/stub.sh"
}

# =====================================================================
# AC2: no-functional-coverage signal — fail-closed to UNVERIFIED
# =====================================================================

@test "web-only, no api_command → no_functional_surface true AND composite UNVERIFIED (fail-closed, not silent PASSED)" {
  have_jq || skip "jq required"
  cat > "$WORK/cfg.yaml" <<'EOF'
project_name: p
platforms: [web]
sprint_review:
  backend_commands:
    node: "echo backend"
EOF
  run bash -c "cd '$WORK' && bash '$TRACKB' --sprint sprint-99 --config '$WORK/cfg.yaml'"
  [ "$status" -eq 0 ]
  json=$(printf '%s\n' "$output" | _json)
  [ "$(printf '%s' "$json" | jq -r '.no_functional_surface')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.functional_exercised')" = "false" ]
  # ENFORCEMENT: a visual-only run cannot auto-approve to PASSED.
  [ "$(printf '%s' "$json" | jq -r '.track_b_verdict')" = "UNVERIFIED" ]
}

@test "web + api_command (smoke PASSES) → functional_exercised true, composite PASSED" {
  have_jq || skip "jq required"
  cat > "$WORK/cfg.yaml" <<'EOF'
project_name: p
platforms: [web, server]
sprint_review:
  manual_test:
    api_command: "echo functional-ok"
EOF
  run bash -c "cd '$WORK' && bash '$TRACKB' --sprint sprint-99 --config '$WORK/cfg.yaml'"
  [ "$status" -eq 0 ]
  json=$(printf '%s\n' "$output" | _json)
  [ "$(printf '%s' "$json" | jq -r '.functional_exercised')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.no_functional_surface')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.track_b_verdict')" = "PASSED" ]
}

@test "api smoke that RUNS and FAILS still counts as functional_exercised (composite FAILED, not no_functional)" {
  have_jq || skip "jq required"
  # Regression guard: a functional smoke that ran and failed exercised the
  # functional surface — it must NOT also report no_functional_surface, and the
  # composite is the hard FAILED (not the UNVERIFIED tracked-skip).
  cat > "$WORK/cfg.yaml" <<'EOF'
project_name: p
platforms: [web, server]
sprint_review:
  manual_test:
    api_command: "exit 1"
EOF
  run bash -c "cd '$WORK' && bash '$TRACKB' --sprint sprint-99 --config '$WORK/cfg.yaml'"
  [ "$status" -eq 0 ]
  json=$(printf '%s\n' "$output" | _json)
  [ "$(printf '%s' "$json" | jq -r '.functional_exercised')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.no_functional_surface')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.track_b_verdict')" = "FAILED" ]
}

@test "no user-facing surface at all → no_functional_surface false, composite PASSED (benign)" {
  have_jq || skip "jq required"
  cat > "$WORK/cfg.yaml" <<'EOF'
project_name: p
platforms: [server]
sprint_review:
  backend_commands:
    node: "echo backend"
EOF
  run bash -c "cd '$WORK' && bash '$TRACKB' --sprint sprint-99 --config '$WORK/cfg.yaml'"
  [ "$status" -eq 0 ]
  json=$(printf '%s\n' "$output" | _json)
  [ "$(printf '%s' "$json" | jq -r '.no_functional_surface')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.track_b_verdict')" = "PASSED" ]
}

# =====================================================================
# AC3: un-auto-approvable env-limited tracked skip — fail-closed to UNVERIFIED
# =====================================================================

@test "configured functional smoke that is UNVERIFIED → tracked env_limited AND composite UNVERIFIED (un-auto-approvable)" {
  have_jq || skip "jq required"
  # Realistic stub (exit 0; verdict UNVERIFIED in JSON) mirrors a smoke that ran
  # but could not be verified (env/tooling gap reported as UNVERIFIED).
  _write_realistic_stub "UNVERIFIED"
  cat > "$WORK/cfg.yaml" <<'EOF'
project_name: p
platforms: [server]
sprint_review:
  manual_test:
    api_command: "curl -fsS http://localhost:9/health"
EOF
  run bash -c "cd '$WORK' && DISPATCH_SURFACE_BIN='$WORK/stub.sh' bash '$TRACKB' --sprint sprint-99 --config '$WORK/cfg.yaml'"
  [ "$status" -eq 0 ]
  json=$(printf '%s\n' "$output" | _json)
  [ "$(printf '%s' "$json" | jq -r '.env_limited_surfaces | index("api") != null')" = "true" ]
  # ENFORCEMENT: the tracked skip CANNOT auto-approve to PASSED.
  [ "$(printf '%s' "$json" | jq -r '.track_b_verdict')" = "UNVERIFIED" ]
  [[ "$output" == *"not auto-approved"* ]] || [[ "$output" == *"UNVERIFIED"* ]]
}

@test "a dispatch hard error (exit 1) is FAILED, NOT a benign skip and NOT env_limited (no masking real failures)" {
  have_jq || skip "jq required"
  # The real dispatch-surface.sh exits 1 only on a hard error (usage / adapter
  # failure / missing sibling). That must surface as FAILED — never silently
  # downgraded to a benign skip, never relabeled as a benign env_limited.
  cat > "$WORK/stub.sh" <<'STUBEOF'
#!/usr/bin/env bash
echo "dispatch-surface.sh: missing sibling script" >&2
exit 1
STUBEOF
  chmod +x "$WORK/stub.sh"
  cat > "$WORK/cfg.yaml" <<'EOF'
project_name: p
platforms: [server]
sprint_review:
  manual_test:
    api_command: "x"
EOF
  run bash -c "cd '$WORK' && DISPATCH_SURFACE_BIN='$WORK/stub.sh' bash '$TRACKB' --sprint sprint-99 --config '$WORK/cfg.yaml'"
  [ "$status" -eq 0 ]
  json=$(printf '%s\n' "$output" | _json)
  [ "$(printf '%s' "$json" | jq -r '.track_b_verdict')" = "FAILED" ]
  [ "$(printf '%s' "$json" | jq -r '.env_limited_surfaces | length')" -eq 0 ]
}

@test "a genuinely dormant surface (real dispatch-surface, no api_command) is benign — composite PASSED, env_limited empty" {
  have_jq || skip "jq required"
  cat > "$WORK/cfg.yaml" <<'EOF'
project_name: p
platforms: [server]
sprint_review:
  backend_commands:
    node: "echo backend"
EOF
  run bash -c "cd '$WORK' && bash '$TRACKB' --sprint sprint-99 --config '$WORK/cfg.yaml'"
  [ "$status" -eq 0 ]
  json=$(printf '%s\n' "$output" | _json)
  [ "$(printf '%s' "$json" | jq -r '.env_limited_surfaces | length')" -eq 0 ]
  [ "$(printf '%s' "$json" | jq -r '.track_b_verdict')" = "PASSED" ]
}

@test "env-limited routes through compose-verdict to a composite UNVERIFIED (end-to-end enforcement)" {
  have_jq || skip "jq required"
  # Prove the Track-B UNVERIFIED actually composes to a non-PASSED composite via
  # the real reducer — the field is not write-only telemetry.
  COMPOSE="$REPO_ROOT/plugins/gaia/skills/gaia-sprint-review/scripts/compose-verdict.sh"
  run bash "$COMPOSE" --track-a PASSED --track-b UNVERIFIED
  [ "$status" -eq 0 ]
  [ "$output" = "UNVERIFIED" ]
}

# =====================================================================
# AC5: regression — verdict semantics unchanged
# =====================================================================

@test "configured api smoke: exit 0 → PASSED, non-zero → FAILED (verdict semantics intact)" {
  cat > "$WORK/cfg.yaml" <<'EOF'
project_name: p
platforms: [server]
EOF
  run bash "$DISPATCH" --surface api --target "exit 0" \
    --evidence-dir "$WORK/ev1" --config "$WORK/cfg.yaml"
  [[ "$output" == *'"verdict":"PASSED"'* ]]
  run bash "$DISPATCH" --surface api --target "exit 1" \
    --evidence-dir "$WORK/ev2" --config "$WORK/cfg.yaml"
  [[ "$output" == *'"verdict":"FAILED"'* ]]
}

@test "the class field is additive — it does not change the SKIPPED/PASSED verdict semantics" {
  cat > "$WORK/cfg.yaml" <<'EOF'
project_name: p
platforms: [web]
EOF
  # api dormant → still SKIPPED (PASSED-equivalent), now also carries class.
  run bash "$DISPATCH" --surface api --target "echo x" \
    --evidence-dir "$WORK/ev" --config "$WORK/cfg.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"verdict":"SKIPPED"'* ]]
}
