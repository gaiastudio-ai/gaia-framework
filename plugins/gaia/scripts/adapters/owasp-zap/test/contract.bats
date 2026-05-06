#!/usr/bin/env bats
# adapters/owasp-zap/test/contract.bats — ADR-078 adapter parity (E73-S3).
# Exercises all four probe states plus env-allowlist enforcement
# (T-RSV2-1 mitigation) and the timeout exit-code contract.
#
# AC mapping (from E73-S3):
#   AC2 — adapter.json fields
#   AC3 — run.sh exit codes + JSON finding output
#   AC4 — env-allowlist enforcement
#   AC7 — contract.bats coverage
#   AC8 — three-state availability probe integration

load '../../_contract-helper.bash'
bats_require_minimum_version 1.5.0

setup() { contract_setup; }
teardown() { contract_teardown; }

@test "owasp-zap contract: adapter.json + run.sh present and well-formed" {
  assert_files_exist
}

@test "owasp-zap contract: adapter.json declares env-allowlist (T-RSV2-1)" {
  # AC2 — env-allowlist array present and non-empty (T-RSV2-1 mitigation).
  run jq -e '.["env-allowlist"] | type == "array" and length > 0' \
    "$ADAPTER_DIR/adapter.json"
  [ "$status" -eq 0 ]
}

@test "owasp-zap contract: adapter.json category is dast" {
  run jq -er '.category' "$ADAPTER_DIR/adapter.json"
  [ "$status" -eq 0 ]
  [ "$output" = "dast" ]
}

@test "owasp-zap contract: state=available when tool on PATH and matching files" {
  local ext; ext="$(_contract_first_ext)"
  if [ -z "$ext" ]; then
    ext=".html"
  fi
  assert_state "$(_contract_provider)" available "$ext" 0 "" 0
  assert_fragment_shape
}

@test "owasp-zap contract: state=expected_and_missing when tool absent from PATH" {
  local ext; ext="$(_contract_first_ext)"
  if [ -z "$ext" ]; then
    ext=".html"
  fi
  assert_state "$(_contract_provider)" expected_and_missing "$ext" 0 "" 0
  assert_fragment_shape
}

@test "owasp-zap contract: state=ran_and_errored when run.sh exits non-zero" {
  local ext; ext="$(_contract_first_ext)"
  if [ -z "$ext" ]; then
    ext=".html"
  fi
  assert_state "$(_contract_provider)" ran_and_errored "$ext" 1 "zap crashed" 0
  assert_fragment_shape
}

@test "owasp-zap contract: state=not_applicable when file-list empty (project-scope)" {
  assert_state "$(_contract_provider)" not_applicable "EMPTY_FILE_LIST" 0 "" 0
  assert_fragment_shape
}

# --- Env-allowlist enforcement (AC4 / T-RSV2-1) ---------------------------

@test "run.sh: env-allowlist scrubs non-allowlisted parent env vars" {
  # Stage a fake `zap-cli` that prints its own environment to a sentinel
  # file. If the scrub works, SECRET_KEY (NOT in the allowlist) must be
  # absent from the subprocess env.
  local fake_dir="$WORK_TMP/fakebin"
  mkdir -p "$fake_dir"
  local sentinel="$WORK_TMP/zap-env.txt"
  cat > "$fake_dir/zap-cli" <<EOF
#!/usr/bin/env bash
env > "$sentinel"
# Emit a minimal ZAP-shaped JSON so run.sh has something to normalize.
printf '{"site":[{"alerts":[]}]}\n'
exit 0
EOF
  chmod +x "$fake_dir/zap-cli"

  PATH="$fake_dir:$PATH" \
    SECRET_KEY="leaky-value-$$" \
    TARGET_URL="http://example.test" \
    run "$ADAPTER_DIR/run.sh" --target-url "http://example.test" --output "$WORK_TMP/out.json"
  [ "$status" -eq 0 ] || { echo "run.sh status=$status output=$output" >&2; false; }
  [ -r "$sentinel" ]
  # SECRET_KEY MUST NOT leak into the ZAP subprocess environment.
  ! grep -qE '^SECRET_KEY=' "$sentinel"
  # TARGET_URL is in the allowlist — it MUST be present.
  grep -qE '^TARGET_URL=http://example.test$' "$sentinel"
}

@test "run.sh: env-allowlist passes through allowlisted vars" {
  local fake_dir="$WORK_TMP/fakebin"
  mkdir -p "$fake_dir"
  local sentinel="$WORK_TMP/zap-env.txt"
  cat > "$fake_dir/zap-cli" <<EOF
#!/usr/bin/env bash
env > "$sentinel"
printf '{"site":[{"alerts":[]}]}\n'
exit 0
EOF
  chmod +x "$fake_dir/zap-cli"

  PATH="$fake_dir:$PATH" \
    ZAP_API_KEY="apikey-$$" \
    TARGET_URL="http://example.test" \
    run "$ADAPTER_DIR/run.sh" --target-url "http://example.test"
  [ "$status" -eq 0 ]
  [ -r "$sentinel" ]
  grep -qE '^ZAP_API_KEY=apikey-' "$sentinel"
}

# --- Exit code contract (AC3) --------------------------------------------

@test "run.sh: exits 127 when zap-cli not on PATH" {
  # Strip PATH of any binary we don't need; the helper guarantees jq is
  # available via the system PATH so we keep that.
  PATH="/usr/bin:/bin" run "$ADAPTER_DIR/run.sh" --target-url "http://example.test"
  [ "$status" -eq 127 ]
}

@test "run.sh: exits 0 with valid JSON finding array on clean scan" {
  local fake_dir="$WORK_TMP/fakebin"
  mkdir -p "$fake_dir"
  cat > "$fake_dir/zap-cli" <<'EOF'
#!/usr/bin/env bash
printf '{"site":[{"alerts":[]}]}\n'
exit 0
EOF
  chmod +x "$fake_dir/zap-cli"

  PATH="$fake_dir:$PATH" \
    TARGET_URL="http://example.test" \
    run "$ADAPTER_DIR/run.sh" --target-url "http://example.test" --output "$WORK_TMP/out.json"
  [ "$status" -eq 0 ]
  # The output file must be a valid JSON document with the canonical
  # adapter fragment shape.
  run jq -e '.name == "owasp-zap" and (.findings | type == "array")' "$WORK_TMP/out.json"
  [ "$status" -eq 0 ]
}

@test "run.sh: exits 1 when --target-url missing" {
  local fake_dir="$WORK_TMP/fakebin"
  mkdir -p "$fake_dir"
  cat > "$fake_dir/zap-cli" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$fake_dir/zap-cli"
  PATH="$fake_dir:$PATH" run "$ADAPTER_DIR/run.sh"
  [ "$status" -eq 1 ]
}

# --- ZAP finding normalization (severity mapping) -------------------------

@test "run.sh: normalizes ZAP alerts to canonical finding objects" {
  local fake_dir="$WORK_TMP/fakebin"
  mkdir -p "$fake_dir"
  cat > "$fake_dir/zap-cli" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"site":[{"@name":"http://example.test","alerts":[
  {"pluginid":"40012","name":"Cross Site Scripting (Reflected)","riskdesc":"High (Medium)","desc":"XSS","instances":[{"uri":"http://example.test/q","method":"GET"}]},
  {"pluginid":"10202","name":"Absence of Anti-CSRF Tokens","riskdesc":"Medium (Low)","desc":"CSRF","instances":[{"uri":"http://example.test/login","method":"POST"}]},
  {"pluginid":"10038","name":"Content Security Policy Header Not Set","riskdesc":"Low (Medium)","desc":"CSP","instances":[{"uri":"http://example.test/","method":"GET"}]},
  {"pluginid":"10049","name":"Storable and Cacheable Content","riskdesc":"Informational (Low)","desc":"cache","instances":[{"uri":"http://example.test/","method":"GET"}]}
]}]}
JSON
exit 0
EOF
  chmod +x "$fake_dir/zap-cli"

  PATH="$fake_dir:$PATH" \
    TARGET_URL="http://example.test" \
    run "$ADAPTER_DIR/run.sh" --target-url "http://example.test" --output "$WORK_TMP/out.json"
  [ "$status" -eq 0 ]
  # Must have findings; severities must be normalized to high/medium/low/info.
  run jq -e '.findings | length == 4' "$WORK_TMP/out.json"
  [ "$status" -eq 0 ]
  run jq -er '.findings[0].severity' "$WORK_TMP/out.json"
  [ "$output" = "high" ]
  run jq -er '.findings[1].severity' "$WORK_TMP/out.json"
  [ "$output" = "medium" ]
  run jq -er '.findings[2].severity' "$WORK_TMP/out.json"
  [ "$output" = "low" ]
  run jq -er '.findings[3].severity' "$WORK_TMP/out.json"
  [ "$output" = "info" ]
  # Each finding must have rule_id and url.
  run jq -e 'all(.findings[]; has("rule_id") and has("url") and has("message"))' "$WORK_TMP/out.json"
  [ "$status" -eq 0 ]
}
