#!/usr/bin/env bats
# adapters/marketplace-publish/test/contract.bats — ADR-078 deploy-adapter contract (E78-S1, FR-423).
#
# marketplace-publish is the first adapter to implement the full ADR-078 four-file
# contract: adapter.json (metadata) + probe.sh (availability, three-state 0/1/2) +
# run.sh (execution, --env/--version/--output-dir + optional --repository/--draft) +
# normalize.sh (stdin JSON -> normalized {release_url, tag, draft} on stdout).
#
# Tests cover:
#   - AC1  adapter.json schema conformance (7 required fields)
#   - AC2  probe.sh three-state exit-code contract (0/1/2)
#   - AC3  run.sh required-flag validation (missing --env/--version/--output-dir)
#   - AC4  run.sh optional flags (--repository, --draft) accepted
#   - AC7  normalize.sh emits release_url, tag, draft
#   - AC10 adapter.schema.json category enum includes "deploy"

bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ADAPTER_DIR="$(cd "$TEST_DIR/.." && pwd)"
  ADAPTERS_ROOT="$(cd "$ADAPTER_DIR/.." && pwd)"
  SCHEMA_FILE="$ADAPTERS_ROOT/_schema/adapter.schema.json"
  ADAPTER_JSON="$ADAPTER_DIR/adapter.json"
  PROBE_SH="$ADAPTER_DIR/probe.sh"
  RUN_SH="$ADAPTER_DIR/run.sh"
  NORMALIZE_SH="$ADAPTER_DIR/normalize.sh"
  CONTRACT_HELPER="$ADAPTERS_ROOT/_contract-helper.bash"
  WORK_TMP="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/marketplace-publish-$$-$BATS_TEST_NUMBER"
  mkdir -p "$WORK_TMP/out" "$WORK_TMP/fakebin"
}

teardown() {
  if [ -n "${WORK_TMP:-}" ] && [ -d "$WORK_TMP" ]; then
    rm -rf "$WORK_TMP" 2>/dev/null || true
  fi
}

# --- AC1, AC10: adapter.json + schema ----------------------------------------

@test "AC1: adapter.json exists and is valid JSON" {
  [ -f "$ADAPTER_JSON" ]
  jq -e . "$ADAPTER_JSON" >/dev/null
}

@test "AC1: adapter.json has all 7 required fields with correct values" {
  run jq -e '
    .provider == "gh"
    and .category == "deploy"
    and .["runtime-profile"] == "subprocess"
    and (.["default-timeout-seconds"] | type == "number")
    and (.["file-extensions"] | type == "array")
    and (.["version-range"] | type == "string" and length > 0)
    and (.description | type == "string" and length > 0)
  ' "$ADAPTER_JSON"
  [ "$status" -eq 0 ]
}

@test "AC1: adapter.json declares scope: project" {
  run jq -e '.scope == "project"' "$ADAPTER_JSON"
  [ "$status" -eq 0 ]
}

@test "AC10: adapter.schema.json category enum includes 'deploy'" {
  run jq -e '.properties.category.enum | index("deploy") != null' "$SCHEMA_FILE"
  [ "$status" -eq 0 ]
}

@test "AC10: marketplace-publish adapter.json validates against adapter.schema.json" {
  if ! command -v jsonschema >/dev/null 2>&1 && ! python3 -c 'import jsonschema' 2>/dev/null; then
    skip "jsonschema CLI/library not available"
  fi
  run python3 - <<EOF
import json, sys
import jsonschema
with open("$SCHEMA_FILE") as f: schema = json.load(f)
with open("$ADAPTER_JSON") as f: doc = json.load(f)
jsonschema.validate(doc, schema)
EOF
  [ "$status" -eq 0 ]
}

# --- AC2: probe.sh ----------------------------------------------------------

@test "AC2: probe.sh exists and is executable" {
  [ -f "$PROBE_SH" ]
  [ -x "$PROBE_SH" ]
}

@test "AC2: probe.sh exits 1 when gh CLI is not on PATH" {
  # Use a fully-isolated PATH that does NOT include any system bin dirs where
  # gh might be installed. We must keep /bin and /usr/bin so probe.sh can find
  # its own coreutils (grep, command, etc.); we just guarantee no `gh`.
  ISOLATED_PATH="$WORK_TMP/fakebin"
  for d in /bin /usr/bin; do
    if [ -d "$d" ] && [ ! -x "$d/gh" ]; then
      ISOLATED_PATH="${ISOLATED_PATH}:${d}"
    fi
  done
  if command -v gh >/dev/null 2>&1; then
    real_gh="$(command -v gh)"
    real_gh_dir="$(dirname "$real_gh")"
    case ":${ISOLATED_PATH}:" in
      *":${real_gh_dir}:"*) skip "cannot isolate gh — installed in /bin or /usr/bin" ;;
    esac
  fi
  PATH="$ISOLATED_PATH" run "$PROBE_SH"
  [ "$status" -eq 1 ]
}

@test "AC2: probe.sh exits 1 when gh exists but auth status fails" {
  cat > "$WORK_TMP/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  auth)  exit 1 ;;
  *)     exit 0 ;;
esac
EOF
  chmod +x "$WORK_TMP/fakebin/gh"
  PATH="$WORK_TMP/fakebin:$PATH" run "$PROBE_SH"
  [ "$status" -eq 1 ]
}

@test "AC2: probe.sh exits 1 when token lacks repo write scope" {
  cat > "$WORK_TMP/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  auth)
    if [ "${2:-}" = "status" ]; then
      # auth ok, but no repo scope listed
      echo "Token scopes: read:org, read:user" >&2
      exit 0
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$WORK_TMP/fakebin/gh"
  PATH="$WORK_TMP/fakebin:$PATH" run "$PROBE_SH"
  [ "$status" -eq 1 ]
}

@test "AC2: probe.sh exits 0 when all prerequisites met and no tag conflict" {
  cat > "$WORK_TMP/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  auth)
    if [ "${2:-}" = "status" ]; then
      echo "Token scopes: repo, read:org" >&2
      exit 0
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$WORK_TMP/fakebin/gh"
  cat > "$WORK_TMP/fakebin/git" <<'EOF'
#!/usr/bin/env bash
# stub: ls-remote returns empty (no tag conflict)
exit 0
EOF
  chmod +x "$WORK_TMP/fakebin/git"
  PATH="$WORK_TMP/fakebin:$PATH" MARKETPLACE_PUBLISH_VERSION="9.9.9" run "$PROBE_SH"
  [ "$status" -eq 0 ]
}

@test "AC2: probe.sh exits 2 when target tag already exists on remote" {
  cat > "$WORK_TMP/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  auth)
    if [ "${2:-}" = "status" ]; then
      echo "Token scopes: repo, read:org" >&2
      exit 0
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$WORK_TMP/fakebin/gh"
  cat > "$WORK_TMP/fakebin/git" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "ls-remote" ]; then
  # Simulate tag conflict: print one ref
  echo "abc123 refs/tags/9.9.9"
  exit 0
fi
exit 0
EOF
  chmod +x "$WORK_TMP/fakebin/git"
  PATH="$WORK_TMP/fakebin:$PATH" MARKETPLACE_PUBLISH_VERSION="9.9.9" run "$PROBE_SH"
  [ "$status" -eq 2 ]
}

# --- AC3: run.sh required flags --------------------------------------------

@test "AC3: run.sh exists and is executable" {
  [ -f "$RUN_SH" ]
  [ -x "$RUN_SH" ]
}

@test "AC3: run.sh missing --env produces non-zero exit + usage error" {
  run "$RUN_SH" --version 1.0.0 --output-dir "$WORK_TMP/out"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "env"
}

@test "AC3: run.sh missing --version produces non-zero exit + usage error" {
  run "$RUN_SH" --env staging --output-dir "$WORK_TMP/out"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "version"
}

@test "AC3: run.sh missing --output-dir produces non-zero exit + usage error" {
  run "$RUN_SH" --env staging --version 1.0.0
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "output-dir"
}

# --- AC4: run.sh optional flags ---------------------------------------------

@test "AC4: run.sh accepts --repository optional flag" {
  # Stub gh + git so run.sh can complete a happy-path execution.
  cat > "$WORK_TMP/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
# capture invocation
echo "$@" >> "${MARKETPLACE_PUBLISH_GH_LOG:-/tmp/gh.log}"
if [ "$1" = "release" ] && [ "$2" = "create" ]; then
  echo '{"url":"https://example.test/r","tag_name":"1.0.0","isDraft":false}'
  exit 0
fi
exit 0
EOF
  chmod +x "$WORK_TMP/fakebin/gh"
  cat > "$WORK_TMP/fakebin/git" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$WORK_TMP/fakebin/git"
  export MARKETPLACE_PUBLISH_GH_LOG="$WORK_TMP/gh.log"
  : > "$MARKETPLACE_PUBLISH_GH_LOG"
  PATH="$WORK_TMP/fakebin:$PATH" MARKETPLACE_PUBLISH_SKIP_VERSION_FILE=1 \
    run "$RUN_SH" --env staging --version 1.0.0 --output-dir "$WORK_TMP/out" --repository owner/repo
  [ "$status" -eq 0 ]
  grep -q -- "--repo" "$MARKETPLACE_PUBLISH_GH_LOG" || grep -q "owner/repo" "$MARKETPLACE_PUBLISH_GH_LOG"
}

@test "AC4: run.sh --draft passes --draft to gh release create" {
  cat > "$WORK_TMP/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${MARKETPLACE_PUBLISH_GH_LOG:-/tmp/gh.log}"
if [ "$1" = "release" ] && [ "$2" = "create" ]; then
  echo '{"url":"https://example.test/r","tag_name":"1.0.0","isDraft":true}'
  exit 0
fi
exit 0
EOF
  chmod +x "$WORK_TMP/fakebin/gh"
  cat > "$WORK_TMP/fakebin/git" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$WORK_TMP/fakebin/git"
  export MARKETPLACE_PUBLISH_GH_LOG="$WORK_TMP/gh.log"
  : > "$MARKETPLACE_PUBLISH_GH_LOG"
  PATH="$WORK_TMP/fakebin:$PATH" MARKETPLACE_PUBLISH_SKIP_VERSION_FILE=1 \
    run "$RUN_SH" --env staging --version 1.0.0 --output-dir "$WORK_TMP/out" --draft
  [ "$status" -eq 0 ]
  grep -q -- "--draft" "$MARKETPLACE_PUBLISH_GH_LOG"
}

# --- AC5: version_file mismatch -------------------------------------------

@test "AC5: run.sh exits non-zero when version_file value mismatches --version" {
  cat > "$WORK_TMP/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$WORK_TMP/fakebin/gh"
  cat > "$WORK_TMP/fakebin/git" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$WORK_TMP/fakebin/git"
  echo '{"version": "1.0.0"}' > "$WORK_TMP/package.json"
  PATH="$WORK_TMP/fakebin:$PATH" \
    MARKETPLACE_PUBLISH_VERSION_FILE="$WORK_TMP/package.json" \
    MARKETPLACE_PUBLISH_VERSION_KEY="version" \
    run "$RUN_SH" --env staging --version 1.1.0 --output-dir "$WORK_TMP/out"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "mismatch\|does not match"
}

# --- AC7: normalize.sh ----------------------------------------------------

@test "AC7: normalize.sh exists and is executable" {
  [ -f "$NORMALIZE_SH" ]
  [ -x "$NORMALIZE_SH" ]
}

@test "AC7: normalize.sh emits release_url, tag, draft from gh release create JSON" {
  if ! command -v jq >/dev/null 2>&1; then
    skip "jq not installed"
  fi
  input='{"url":"https://example.test/releases/v1.0.0","tag_name":"1.0.0","isDraft":false,"name":"Release 1.0.0"}'
  run bash -c "printf '%s' '$input' | '$NORMALIZE_SH'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.release_url == "https://example.test/releases/v1.0.0"' >/dev/null
  echo "$output" | jq -e '.tag == "1.0.0"' >/dev/null
  echo "$output" | jq -e '.draft == false' >/dev/null
}

@test "AC7: normalize.sh handles draft=true case" {
  if ! command -v jq >/dev/null 2>&1; then
    skip "jq not installed"
  fi
  input='{"url":"https://example.test/r","tag_name":"v2","isDraft":true}'
  run bash -c "printf '%s' '$input' | '$NORMALIZE_SH'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.draft == true' >/dev/null
  echo "$output" | jq -e '.tag == "v2"' >/dev/null
}

# --- AC8: contract.bats sources _contract-helper.bash via path ------------

@test "AC8: _contract-helper.bash is reachable from adapter test/" {
  [ -f "$CONTRACT_HELPER" ]
}

# --- AC9: parity with script-deploy precedent ----------------------------

@test "AC9: directory layout includes adapter.json, run.sh, probe.sh, normalize.sh, test/" {
  [ -f "$ADAPTER_DIR/adapter.json" ]
  [ -f "$ADAPTER_DIR/run.sh" ]
  [ -f "$ADAPTER_DIR/probe.sh" ]
  [ -f "$ADAPTER_DIR/normalize.sh" ]
  [ -d "$ADAPTER_DIR/test" ]
}
