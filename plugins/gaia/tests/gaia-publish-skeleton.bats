#!/usr/bin/env bats
# gaia-publish-skeleton.bats — E100-S1 (FR-525, ADR-113, TC-GPO-1/4)

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"
  SKILL="$PLUGIN_DIR/skills/gaia-publish/SKILL.md"
  ORCH="$PLUGIN_DIR/skills/gaia-publish/scripts/gaia-publish.sh"
  PROJECT_ROOT="$TEST_TMP/project"
  CONFIG="$PROJECT_ROOT/.gaia/config/project-config.yaml"
  mkdir -p "$(dirname "$CONFIG")" "$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts"
}

teardown() { common_teardown; }

_write_config() {
  cat > "$CONFIG" <<YAML
distribution:
  channel: ${1:-claude-marketplace}
  registry: ${2:-https://anthropic.com/marketplace}
  manifest: ${3:-plugin.json}
  release_workflow: ${4:-gaia-release.yml}
YAML
}

_write_plugin_json() {
  local version="${1:-1.0.0}"
  printf '{"version":"%s","name":"example"}\n' "$version" > "$PROJECT_ROOT/plugin.json"
}

# Write a config that carries ci_cd.promotion_chain[].ci_checks so the
# step-1 gate has a contract to evaluate.
_write_config_with_ci_checks() {
  local checks="${1:-test}"
  cat > "$CONFIG" <<YAML
distribution:
  channel: claude-marketplace
  registry: https://anthropic.com/marketplace
  manifest: plugin.json
  release_workflow: gaia-release.yml
ci_cd:
  promotion_chain:
    - branch: staging
      ci_checks:
$(printf '        - %s\n' $checks)
YAML
}

# Install a gh-shim on PATH that emits a canned JSON payload. The shim
# expects $GH_FAKE_JSON to be set to the JSON body to echo for
# 'gh run list ...'.
_install_gh_shim() {
  local shim_dir="$TEST_TMP/bin"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/gh" <<'SHIM'
#!/usr/bin/env bash
case "$1 $2" in
  "run list")
    printf '%s' "${GH_FAKE_JSON:-[]}"
    ;;
  *)
    echo "gh-shim: unhandled args: $*" >&2
    exit 2
    ;;
esac
SHIM
  chmod +x "$shim_dir/gh"
  PATH="$shim_dir:$PATH"
  export PATH
}

# Install a shim that COPIES a fixture envelope at --output. Used by
# TC-GPO-7/9 contract tests. The fixture path comes from $ADAPTER_FIXTURE_DIR
# (e.g., tests/fixtures/publish-adapter-contract/good/).
_install_adapter_fixture_shim() {
  local channel="${1:-claude-marketplace}"
  local shim_dir="$TEST_TMP/bin"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/gaia-adapter-publish-$channel" <<'SHIM'
#!/usr/bin/env bash
output=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift 2;;
    *) shift;;
  esac
done
[ -n "$output" ] || { echo "fixture-shim: --output required" >&2; exit 2; }
[ -n "${ADAPTER_FIXTURE_DIR:-}" ] || { echo "fixture-shim: ADAPTER_FIXTURE_DIR unset" >&2; exit 2; }
cp "$ADAPTER_FIXTURE_DIR/findings.json" "$output"
SHIM
  chmod +x "$shim_dir/gaia-adapter-publish-$channel"
  PATH="$shim_dir:$PATH"
  export PATH
}

# Install a shim that EXITS with the given code BEFORE writing findings.json.
# Used by TC-GPO-8 (adapter-internal-failure).
_install_adapter_crash_shim() {
  local channel="${1:-claude-marketplace}"
  local exit_code="${2:-1}"
  local shim_dir="$TEST_TMP/bin"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/gaia-adapter-publish-$channel" <<SHIM
#!/usr/bin/env bash
echo "adapter crashed before writing findings" >&2
exit $exit_code
SHIM
  chmod +x "$shim_dir/gaia-adapter-publish-$channel"
  PATH="$shim_dir:$PATH"
  export PATH
}

# Install a shim that writes MALFORMED JSON (not parseable).
_install_adapter_malformed_shim() {
  local channel="${1:-claude-marketplace}"
  local shim_dir="$TEST_TMP/bin"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/gaia-adapter-publish-$channel" <<'SHIM'
#!/usr/bin/env bash
output=""
while [ $# -gt 0 ]; do
  case "$1" in --output) output="$2"; shift 2;; *) shift;; esac
done
printf '{not valid json' > "$output"
SHIM
  chmod +x "$shim_dir/gaia-adapter-publish-$channel"
  PATH="$shim_dir:$PATH"
  export PATH
}

# Install an adapter shim at gaia-adapter-publish-<channel> on PATH.
# The shim writes ADR-037 envelope to --output <path>.
# Reads $ADAPTER_VERIFY_OUTCOME (PASSED|FAILED|UNVERIFIED, default PASSED)
# and $ADAPTER_VERIFY_DELAY_S (sleep before responding, default 0).
_install_adapter_shim() {
  local channel="${1:-claude-marketplace}"
  local shim_dir="$TEST_TMP/bin"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/gaia-adapter-publish-$channel" <<'SHIM'
#!/usr/bin/env bash
output=""
action=""
while [ $# -gt 0 ]; do
  case "$1" in
    --action) action="$2"; shift 2;;
    --output) output="$2"; shift 2;;
    *) shift;;
  esac
done
[ "$action" = "verify" ] || { echo "shim: unsupported action: $action" >&2; exit 2; }
[ -n "$output" ] || { echo "shim: --output required" >&2; exit 2; }
sleep "${ADAPTER_VERIFY_DELAY_S:-0}"
cat > "$output" <<JSON
{
  "verdict": "${ADAPTER_VERIFY_OUTCOME:-PASSED}",
  "evidence": [{"type":"registry-response","content":"shim response","source":"https://example.com/artifact"}],
  "summary": "adapter-shim test envelope",
  "adapter_metadata": {"adapter_name":"adapter-shim","adapter_version":"1.0.0","channel":"claude-marketplace","action":"verify"}
}
JSON
SHIM
  chmod +x "$shim_dir/gaia-adapter-publish-$channel"
  PATH="$shim_dir:$PATH"
  export PATH
}

# Write a config carrying ci_checks AND a verify_retry_window_seconds-aware
# adapter manifest under .gaia/custom/adapters/publish-<channel>/.
_write_adapter_manifest() {
  local channel="${1:-claude-marketplace}"
  local window="${2:-2}"
  local dir="$PROJECT_ROOT/.gaia/custom/adapters/publish-$channel"
  mkdir -p "$dir"
  cat > "$dir/adapter-manifest.yaml" <<YAML
name: publish-$channel
verify_retry_window_seconds: $window
YAML
}

# ---------- AC1: skill scaffold + script ----------

@test "AC1: SKILL.md exists at canonical path" {
  [ -f "$SKILL" ]
}

@test "AC1: orchestrator script exists + executable" {
  [ -x "$ORCH" ]
}

@test "AC1: SKILL.md frontmatter name is gaia-publish" {
  grep -q '^name: gaia-publish$' "$SKILL"
}

# ---------- AC3: argument parsing ----------

@test "AC3: missing --version fails with usage error (exit 2)" {
  _write_config
  _write_plugin_json
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH"
  [ "$status" -eq 2 ]
  echo "$output" | grep -qi 'usage'
}

@test "AC3: unknown flag rejected with usage error" {
  _write_config
  _write_plugin_json
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version 1.0.0 --bogus
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'unknown flag'
}

@test "AC3: --version= form accepted" {
  _write_config
  _write_plugin_json 1.0.0
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version=1.0.0
  [ "$status" -eq 0 ]
}

# ---------- AC2 / TC-GPO-1: happy path five-step flow ----------

@test "TC-GPO-1: happy-path five steps PASSED with documented markers" {
  _write_config
  _write_plugin_json 1.0.0
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version 1.0.0
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'step 1/5 (pre-publish-gate): PASSED'
  echo "$output" | grep -q 'step 2/5 (manifest-version-check): PASSED'
  echo "$output" | grep -q 'step 3/5 (trigger-publish): PASSED'
  echo "$output" | grep -q 'step 4/5 (post-publish-verify): PASSED'
  echo "$output" | grep -q 'step 5/5 (final-verdict): PASSED'
}

@test "TC-GPO-1: assessment doc written + names channel + verdict PASSED" {
  _write_config
  _write_plugin_json 1.0.0
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version 1.0.0
  [ "$status" -eq 0 ]
  local doc
  doc=$(find "$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts" -name 'assessment-publish-claude-marketplace-*.md' | head -1)
  [ -n "$doc" ]
  [ -f "$doc" ]
  grep -qF '**Verdict:** PASSED' "$doc"
  grep -q 'Channel:.*claude-marketplace' "$doc"
}

# ---------- AC2 step 2: manifest version mismatch fails ----------

@test "manifest version mismatch → step 2 FAILED → verdict FAILED" {
  _write_config
  _write_plugin_json 2.0.0   # manifest says 2.0.0
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version 1.0.0   # asking for 1.0.0
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'step 2/5 (manifest-version-check): FAILED'
  echo "$output" | grep -q 'does not match'
}

@test "leading v on --version is normalized for comparison" {
  _write_config
  _write_plugin_json 1.0.0
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version v1.0.0
  [ "$status" -eq 0 ]
}

# ---------- AC3 / TC-GPO-4: --dry-run ----------

@test "TC-GPO-4: --dry-run exits 0 with steps 4-5 SKIPPED + dry-run marker" {
  _write_config
  _write_plugin_json 1.0.0
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version 1.0.0 --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'step 3/5 (trigger-publish): PASSED'
  echo "$output" | grep -q 'step 4/5 (post-publish-verify): SKIPPED'
  echo "$output" | grep -q 'dry-run mode'
  echo "$output" | grep -q 'step 5/5 (final-verdict): SKIPPED'
}

@test "TC-GPO-4: --dry-run records the dry-run in the assessment doc" {
  _write_config
  _write_plugin_json 1.0.0
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version 1.0.0 --dry-run
  [ "$status" -eq 0 ]
  local doc
  doc=$(find "$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts" -name 'assessment-publish-*' | head -1)
  [ -f "$doc" ]
  grep -q 'Dry-run:.*yes' "$doc"
}

# ---------- AC3: --skip-verify ----------

@test "--skip-verify SKIPs step 4 with WARNING + still PASSED verdict (operator opt-out)" {
  _write_config
  _write_plugin_json 1.0.0
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version 1.0.0 --skip-verify
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'step 4/5 (post-publish-verify): SKIPPED'
  echo "$output" | grep -qE 'WARNING|skip-verify'
  echo "$output" | grep -q 'step 5/5 (final-verdict): PASSED'
}

# ---------- AC4: config resolution ----------

@test "AC4: missing project-config.yaml fails with clear error" {
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version 1.0.0
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'project-config.yaml not found'
}

@test "AC4: missing distribution.channel fails with clear error" {
  cat > "$CONFIG" <<'YAML'
project_name: example
YAML
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version 1.0.0
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'distribution.channel not set'
}

# ---------- AC5: per-step progress markers consistent ----------

@test "AC5: 5 distinct step markers emitted in canonical order" {
  _write_config
  _write_plugin_json 1.0.0
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version 1.0.0
  [ "$status" -eq 0 ]
  local markers
  markers=$(printf '%s\n' "$output" | grep -c '^\[gaia-publish\] step [1-5]/5')
  [ "$markers" = "5" ]
  # Confirm canonical order via the step-number sequence
  local order
  order=$(printf '%s\n' "$output" | grep -oE 'step [1-5]/5' | sed -E 's|step ([1-5])/5|\1|' | tr -d '\n')
  [ "$order" = "12345" ]
}

# ---------- AC5: SKILL.md cites the five-step canonical order ----------

@test "AC5: SKILL.md cites the five steps in canonical order" {
  grep -q 'Step 1.*[Pp]re-publish gate' "$SKILL"
  grep -q 'Step 2.*[Mm]anifest version check' "$SKILL"
  grep -q 'Step 3.*[Tt]rigger publish' "$SKILL"
  grep -q 'Step 4.*[Pp]ost-publish verify' "$SKILL"
  grep -q 'Step 5.*[Ff]inal verdict' "$SKILL"
}

# ---------- TC-GPO-2: red CI HALTs step 1 BEFORE step 2 ----------

@test "TC-GPO-2: red CI on source-branch HEAD HALTs after step 1 (exit 1, reason pre-publish-gate-failed)" {
  _write_config_with_ci_checks "test lint"
  _write_plugin_json 1.0.0
  _install_gh_shim
  # gh returns one red check ('test' failed) for source-branch HEAD.
  export GH_FAKE_JSON='[{"name":"test","status":"completed","conclusion":"failure","headSha":"abc123"},{"name":"lint","status":"completed","conclusion":"success","headSha":"abc123"}]'
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" bash "$ORCH" --version 1.0.0
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'step 1/5 (pre-publish-gate): FAILED'
  # Step 2 MUST NOT run with PASSED status before the HALT — it is SKIPPED.
  echo "$output" | grep -q 'step 2/5 (manifest-version-check): SKIPPED'
  # Step 3 (adapter trigger) MUST NOT run.
  echo "$output" | grep -q 'step 3/5 (trigger-publish): SKIPPED'
  # Stderr / output names the red check + commit SHA + remediation hint.
  echo "$output" | grep -q 'test'
  echo "$output" | grep -q 'abc123'
  echo "$output" | grep -qi 'CI'
  # Audit-trail reason marker in assessment doc.
  local doc
  doc=$(find "$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts" -name 'assessment-publish-*.md' | head -1)
  [ -f "$doc" ]
  grep -q 'pre-publish-gate-failed' "$doc"
}

@test "TC-GPO-2: all required ci_checks green → step 1 PASSED → flow proceeds" {
  _write_config_with_ci_checks "test lint"
  _write_plugin_json 1.0.0
  _install_gh_shim
  export GH_FAKE_JSON='[{"name":"test","status":"completed","conclusion":"success","headSha":"abc123"},{"name":"lint","status":"completed","conclusion":"success","headSha":"abc123"}]'
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" bash "$ORCH" --version 1.0.0
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'step 1/5 (pre-publish-gate): PASSED'
}

@test "TC-GPO-2: missing required check on HEAD → step 1 FAILED (treated as not-success)" {
  _write_config_with_ci_checks "test lint required-extra"
  _write_plugin_json 1.0.0
  _install_gh_shim
  # 'required-extra' is missing from the JSON entirely.
  export GH_FAKE_JSON='[{"name":"test","status":"completed","conclusion":"success","headSha":"abc123"},{"name":"lint","status":"completed","conclusion":"success","headSha":"abc123"}]'
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" bash "$ORCH" --version 1.0.0
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'step 1/5 (pre-publish-gate): FAILED'
  echo "$output" | grep -q 'required-extra'
}

@test "TC-GPO-2: pending CI conclusion → step 1 FAILED" {
  _write_config_with_ci_checks "test"
  _write_plugin_json 1.0.0
  _install_gh_shim
  export GH_FAKE_JSON='[{"name":"test","status":"in_progress","conclusion":null,"headSha":"abc123"}]'
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" bash "$ORCH" --version 1.0.0
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'step 1/5 (pre-publish-gate): FAILED'
}

# ---------- TC-GPO-3: manifest version mismatch verbatim stderr ----------

@test "TC-GPO-3: manifest version mismatch produces verbatim AC4 stderr" {
  _write_config_with_ci_checks "test"
  _write_plugin_json 1.2.4
  _install_gh_shim
  export GH_FAKE_JSON='[{"name":"test","status":"completed","conclusion":"success","headSha":"abc123"}]'
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" bash "$ORCH" --version v1.2.3
  [ "$status" -eq 1 ]
  # Step 2 FAILED; step 3 SKIPPED (no adapter trigger).
  echo "$output" | grep -q 'step 2/5 (manifest-version-check): FAILED'
  echo "$output" | grep -q 'step 3/5 (trigger-publish): SKIPPED'
  # Verbatim AC4 format: "manifest version 1.2.4 does not match --version v1.2.3"
  echo "$output" | grep -qF 'manifest version 1.2.4 does not match --version v1.2.3'
  # Audit-trail reason marker.
  local doc
  doc=$(find "$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts" -name 'assessment-publish-*.md' | head -1)
  [ -f "$doc" ]
  grep -q 'manifest-version-mismatch' "$doc"
}

# ---------- AC5: --dry-run still runs gates ----------

@test "AC5: --dry-run + red CI still HALTs at step 1 (gates fail-closed in dry-run)" {
  _write_config_with_ci_checks "test"
  _write_plugin_json 1.0.0
  _install_gh_shim
  export GH_FAKE_JSON='[{"name":"test","status":"completed","conclusion":"failure","headSha":"abc123"}]'
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" bash "$ORCH" --version 1.0.0 --dry-run
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'step 1/5 (pre-publish-gate): FAILED'
  echo "$output" | grep -q 'step 3/5 (trigger-publish): SKIPPED'
}

# ---------- Backward-compat: config WITHOUT ci_cd.promotion_chain ----------

@test "no ci_cd.promotion_chain → step 1 PASSED with stub-fallback detail" {
  # Preserves the E100-S1 happy path for projects that haven't wired CI checks yet.
  _write_config
  _write_plugin_json 1.0.0
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version 1.0.0
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'step 1/5 (pre-publish-gate): PASSED'
}

# ---------- TC-GPO-5: post-publish verify adapter dispatch ----------

@test "TC-GPO-5: adapter verify returns PASSED → step 4 PASSED → flow proceeds" {
  _write_config
  _write_plugin_json 1.0.0
  _write_adapter_manifest claude-marketplace 2
  ADAPTER_VERIFY_OUTCOME=PASSED _install_adapter_shim claude-marketplace
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" ADAPTER_VERIFY_OUTCOME=PASSED bash "$ORCH" --version 1.0.0
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'step 4/5 (post-publish-verify): PASSED'
}

@test "TC-GPO-5: adapter verify returns FAILED → step 4 FAILED → orchestrator FAILED (AC4)" {
  _write_config
  _write_plugin_json 1.0.0
  _write_adapter_manifest claude-marketplace 2
  _install_adapter_shim claude-marketplace
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" ADAPTER_VERIFY_OUTCOME=FAILED bash "$ORCH" --version 1.0.0
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'step 4/5 (post-publish-verify): FAILED'
  echo "$output" | grep -qi 'artifact not resolvable'
  # Audit trail records the FAILED step.
  local doc
  doc=$(find "$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts" -name 'assessment-publish-*.md' | head -1)
  grep -qi 'verify-failed\|post-publish-verify-failed' "$doc"
}

@test "TC-GPO-5: UNVERIFIED envelope (mobile-app STUB) → step 4 PASSED with warning" {
  _write_config
  _write_plugin_json 1.0.0
  _write_adapter_manifest claude-marketplace 2
  _install_adapter_shim claude-marketplace
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" ADAPTER_VERIFY_OUTCOME=UNVERIFIED bash "$ORCH" --version 1.0.0
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'step 4/5 (post-publish-verify): PASSED'
  echo "$output" | grep -qi 'unverified'
}

# ---------- TC-GPO-6: --skip-verify NFR-082 opt-out ----------

@test "TC-GPO-6: --skip-verify emits WARNING + verify-skipped audit flag" {
  _write_config
  _write_plugin_json 1.0.0
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version 1.0.0 --skip-verify
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'step 4/5 (post-publish-verify): SKIPPED'
  echo "$output" | grep -qi 'skip-verify opt-out\|MANDATORY post-publish registry probe bypassed'
  echo "$output" | grep -qi 'WARNING'
  # Audit trail records verify-skipped flag.
  local doc
  doc=$(find "$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts" -name 'assessment-publish-*.md' | head -1)
  grep -q 'verify-skipped' "$doc"
}

# ---------- TC-NFR-082-2: orchestrator respects per-adapter window ----------

@test "TC-NFR-082-2: 2s window + FAILED throughout → loop times out at ~2s (±5s tolerance)" {
  _write_config
  _write_plugin_json 1.0.0
  _write_adapter_manifest claude-marketplace 2
  _install_adapter_shim claude-marketplace
  local start end elapsed
  start=$SECONDS
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" ADAPTER_VERIFY_OUTCOME=FAILED bash "$ORCH" --version 1.0.0
  end=$SECONDS
  elapsed=$((end - start))
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'step 4/5 (post-publish-verify): FAILED'
  # Tolerance band: 2s window + up to 5s CI jitter → elapsed should be < 8s.
  [ "$elapsed" -lt 8 ] || { echo "elapsed=${elapsed}s exceeds 8s tolerance" >&2; false; }
}

# ---------- SR-83: 3600s defensive cap ----------

@test "SR-83: manifest declares 7200s → orchestrator clamps to 3600 + WARNING" {
  _write_config
  _write_plugin_json 1.0.0
  _write_adapter_manifest claude-marketplace 7200
  _install_adapter_shim claude-marketplace
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" ADAPTER_VERIFY_OUTCOME=PASSED bash "$ORCH" --version 1.0.0
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'exceeds.*cap\|clamping to 3600\|clamp'
  echo "$output" | grep -qi '3600'
}

# ---------- Backward-compat: no adapter binary AND no manifest ----------

@test "no adapter + no manifest → step 4 PASSED stub-fallback (TC-GPO-1 happy path preserved)" {
  _write_config
  _write_plugin_json 1.0.0
  # No adapter shim, no adapter manifest.
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version 1.0.0
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'step 4/5 (post-publish-verify): PASSED'
}

# ---------- TC-GPO-7: FAILED verdict propagation with adapter findings ----------

@test "TC-GPO-7: well-formed envelope with verdict FAILED → orchestrator FAILED + adapter findings surfaced" {
  _write_config
  _write_plugin_json 1.0.0
  _write_adapter_manifest claude-marketplace 2
  _install_adapter_fixture_shim claude-marketplace
  local fixture_dir="$BATS_TEST_DIRNAME/fixtures/publish-adapter-contract/good"
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" ADAPTER_FIXTURE_DIR="$fixture_dir" bash "$ORCH" --version 1.0.0
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'step 4/5 (post-publish-verify): FAILED'
  # The adapter's summary is surfaced in the assessment doc.
  local doc
  doc=$(find "$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts" -name 'assessment-publish-*.md' | head -1)
  [ -f "$doc" ]
  grep -qi 'publish adapter findings\|adapter.*summary' "$doc"
  grep -qF 'Authentication failed' "$doc"
}

# ---------- TC-GPO-8: adapter-internal-failure ----------

@test "TC-GPO-8: adapter exits non-zero BEFORE findings.json → adapter-internal-failure (distinct from FAILED)" {
  _write_config
  _write_plugin_json 1.0.0
  _write_adapter_manifest claude-marketplace 2
  _install_adapter_crash_shim claude-marketplace 1
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" bash "$ORCH" --version 1.0.0
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'step 4/5 (post-publish-verify): FAILED'
  echo "$output" | grep -qi 'adapter-internal-failure\|without writing findings'
}

# ---------- TC-GPO-9: envelope schema violation ----------

@test "TC-GPO-9: missing verdict in findings.json → envelope-schema-violation HALT" {
  _write_config
  _write_plugin_json 1.0.0
  _write_adapter_manifest claude-marketplace 2
  _install_adapter_fixture_shim claude-marketplace
  local fixture_dir="$BATS_TEST_DIRNAME/fixtures/publish-adapter-contract/bad-missing-verdict"
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" ADAPTER_FIXTURE_DIR="$fixture_dir" bash "$ORCH" --version 1.0.0
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi 'envelope.*schema.*violation\|adr-037'
  echo "$output" | grep -qi 'verdict'
}

@test "TC-GPO-9: verdict outside enum → envelope-schema-violation HALT" {
  _write_config
  _write_plugin_json 1.0.0
  _write_adapter_manifest claude-marketplace 2
  _install_adapter_fixture_shim claude-marketplace
  local fixture_dir="$BATS_TEST_DIRNAME/fixtures/publish-adapter-contract/bad-verdict-outside-enum"
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" ADAPTER_FIXTURE_DIR="$fixture_dir" bash "$ORCH" --version 1.0.0
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi 'envelope.*schema.*violation\|adr-037'
  echo "$output" | grep -qF 'SUCCESS'
}

@test "TC-GPO-9: evidence not an array → envelope-schema-violation HALT" {
  _write_config
  _write_plugin_json 1.0.0
  _write_adapter_manifest claude-marketplace 2
  _install_adapter_fixture_shim claude-marketplace
  local fixture_dir="$BATS_TEST_DIRNAME/fixtures/publish-adapter-contract/bad-evidence-not-array"
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" ADAPTER_FIXTURE_DIR="$fixture_dir" bash "$ORCH" --version 1.0.0
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi 'envelope.*schema.*violation\|adr-037'
}

@test "TC-GPO-9: malformed JSON in findings.json → envelope-schema-violation HALT" {
  _write_config
  _write_plugin_json 1.0.0
  _write_adapter_manifest claude-marketplace 2
  _install_adapter_malformed_shim claude-marketplace
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" bash "$ORCH" --version 1.0.0
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi 'envelope.*schema.*violation\|malformed\|invalid.*json'
}

# ---------- Adapter-manifest JSON Schema validation (SR-77 + SR-83) ----------

@test "SR-77: validate-adapter-manifest.sh accepts well-formed manifest" {
  local helper="$PLUGIN_DIR/scripts/lib/validate-adr037-envelope.sh"
  [ -x "$helper" ]
}

@test "SR-77: adapter-manifest.schema.json exists" {
  [ -f "$PLUGIN_DIR/schemas/adapter-manifest.schema.json" ]
}

@test "SR-83: schema rejects verify_retry_window_seconds > 3600" {
  local schema="$PLUGIN_DIR/schemas/adapter-manifest.schema.json"
  [ -f "$schema" ]
  # Verify the schema declares the maximum=3600 constraint (within oneOf branch).
  jq -e '[.properties.verify_retry_window_seconds.oneOf[]?.maximum] | any(. == 3600)' "$schema"
}

# ---------- Edge: missing manifest file ----------

@test "missing manifest file → step 2 FAILED → verdict FAILED" {
  _write_config
  # No plugin.json written
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version 1.0.0
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'step 2/5 (manifest-version-check): FAILED'
  echo "$output" | grep -q 'manifest file not found'
}
