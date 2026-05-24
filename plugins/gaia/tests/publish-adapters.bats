#!/usr/bin/env bats
# publish-adapters.bats — E100-S5 TC-PUB-1/2/3/4
#
# Tests the four first-class publish adapters' FR-526 + ADR-037 envelope
# conformance + NFR-081 credential-isolation + dry-run + exit-code matrix.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"
  ENVELOPE_VAL="$PLUGIN_DIR/scripts/lib/validate-adr037-envelope.sh"
  OUTPUT="$TEST_TMP/findings.json"
}

teardown() { common_teardown; }

_run_adapter() {
  local channel="$1"; shift
  local adapter="$PLUGIN_DIR/scripts/adapters/publish-$channel/run.sh"
  [ -x "$adapter" ] || { echo "adapter missing or not executable: $adapter" >&2; return 1; }
  "$adapter" "$@" --output "$OUTPUT"
}

_assert_envelope_well_formed() {
  [ -f "$OUTPUT" ]
  bash "$ENVELOPE_VAL" "$OUTPUT"
}

# ---------- TC-PUB-1: claude-marketplace trigger + verify happy path ----------

@test "TC-PUB-1: claude-marketplace trigger emits PASSED envelope (credentials via env only)" {
  MARKETPLACE_PUBLISH_MOCK=1 run _run_adapter claude-marketplace \
    --action trigger --manifest plugin.json --version 1.0.0 \
    --registry https://anthropic.com/marketplace
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "PASSED" ]
  [ "$(jq -r '.adapter_metadata.channel' "$OUTPUT")" = "claude-marketplace" ]
}

@test "TC-PUB-1: claude-marketplace verify emits PASSED envelope on success" {
  MARKETPLACE_VERIFY_MOCK_OUTCOME=PASSED run _run_adapter claude-marketplace \
    --action verify --manifest plugin.json --version 1.0.0 \
    --registry https://anthropic.com/marketplace
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "PASSED" ]
  [ "$(jq -r '.adapter_metadata.action' "$OUTPUT")" = "verify" ]
}

@test "TC-PUB-1: claude-marketplace verify emits FAILED envelope on 404" {
  MARKETPLACE_VERIFY_MOCK_OUTCOME=FAILED run _run_adapter claude-marketplace \
    --action verify --manifest plugin.json --version 1.0.0 \
    --registry https://anthropic.com/marketplace
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "FAILED" ]
}

@test "TC-PUB-1 (NFR-081): missing CLAUDE_MARKETPLACE_TOKEN → trigger FAILED" {
  # No mock, no token → adapter MUST refuse to publish.
  unset CLAUDE_MARKETPLACE_TOKEN MARKETPLACE_PUBLISH_MOCK
  run _run_adapter claude-marketplace \
    --action trigger --manifest plugin.json --version 1.0.0 \
    --registry https://anthropic.com/marketplace
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "FAILED" ]
  jq -r '.summary' "$OUTPUT" | grep -qi 'CLAUDE_MARKETPLACE_TOKEN missing'
}

# ---------- TC-PUB-2: npm NPM_TOKEN + dry-run ----------

@test "TC-PUB-2: npm dry-run with NPM_TOKEN reads token from env (NFR-081)" {
  NPM_PUBLISH_MOCK=1 NPM_TOKEN=test-token-value run _run_adapter npm \
    --action trigger --manifest package.json --version 1.0.0 \
    --registry https://registry.npmjs.org/ --dry-run
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "PASSED" ]
  jq -r '.summary' "$OUTPUT" | grep -qi 'dry-run'
  jq -r '.summary' "$OUTPUT" | grep -qi 'env'
}

@test "TC-PUB-2 (NFR-081): missing NPM_TOKEN → trigger FAILED (refuses ~/.npmrc fallback)" {
  unset NPM_TOKEN NPM_PUBLISH_MOCK
  run _run_adapter npm \
    --action trigger --manifest package.json --version 1.0.0 \
    --registry https://registry.npmjs.org/
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "FAILED" ]
  jq -r '.summary' "$OUTPUT" | grep -qiE 'NPM_TOKEN missing|.npmrc'
}

# ---------- TC-PUB-3: pypi twine exit-code matrix ----------

@test "TC-PUB-3: pypi twine exit 0 → PASSED" {
  TWINE_MOCK_EXIT=0 run _run_adapter pypi \
    --action trigger --manifest pyproject.toml --version 1.0.0 \
    --registry https://upload.pypi.org/legacy/
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "PASSED" ]
}

@test "TC-PUB-3: pypi twine exit 1 → FAILED with stderr in evidence" {
  TWINE_MOCK_EXIT=1 TWINE_MOCK_STDERR="auth failure: HTTPError 401" run _run_adapter pypi \
    --action trigger --manifest pyproject.toml --version 1.0.0 \
    --registry https://upload.pypi.org/legacy/
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "FAILED" ]
  jq -r '.evidence[0].content' "$OUTPUT" | grep -qF '401'
}

@test "TC-PUB-3: pypi twine exit 2 → FAILED distinguishable (usage/argument error)" {
  TWINE_MOCK_EXIT=2 TWINE_MOCK_STDERR="twine: argument error" run _run_adapter pypi \
    --action trigger --manifest pyproject.toml --version 1.0.0 \
    --registry https://upload.pypi.org/legacy/
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "FAILED" ]
  jq -r '.summary' "$OUTPUT" | grep -qF 'exit 2'
}

@test "TC-PUB-3: NO silent coercion to PASSED on twine exit 1" {
  TWINE_MOCK_EXIT=1 TWINE_MOCK_STDERR="x" run _run_adapter pypi \
    --action trigger --manifest pyproject.toml --version 1.0.0 \
    --registry https://upload.pypi.org/legacy/
  [ "$(jq -r '.verdict' "$OUTPUT")" != "PASSED" ]
}

# ---------- TC-PUB-4: homebrew 600s window declared ----------

@test "TC-PUB-4: homebrew adapter-manifest declares verify_retry_window_seconds: 600" {
  local manifest="$PLUGIN_DIR/scripts/adapters/publish-homebrew/adapter-manifest.yaml"
  [ -f "$manifest" ]
  local window
  window=$(yq eval '.verify_retry_window_seconds' "$manifest")
  [ "$window" = "600" ]
}

@test "TC-PUB-4: homebrew verify single-shot returns PASSED on tap-200 mock" {
  HOMEBREW_VERIFY_MOCK_OUTCOME=PASSED run _run_adapter homebrew \
    --action verify --manifest Formula/mytool.rb --version 1.0.0 \
    --registry https://github.com/myorg/homebrew-tap
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "PASSED" ]
}

@test "TC-PUB-4: homebrew verify single-shot returns FAILED on tap-404 (orchestrator handles retry)" {
  # NOTE: orchestrator step-4 owns the 600s retry-window loop per E100-S3.
  # The adapter itself is single-shot — a single 404 from the tap probe.
  HOMEBREW_VERIFY_MOCK_OUTCOME=FAILED run _run_adapter homebrew \
    --action verify --manifest Formula/mytool.rb --version 1.0.0 \
    --registry https://github.com/myorg/homebrew-tap
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "FAILED" ]
}

# ---------- TC-PUB-5: github-releases ----------

@test "TC-PUB-5: github-releases trigger emits PASSED envelope with release URL in summary" {
  GH_PUBLISH_MOCK=1 GH_TOKEN=test run _run_adapter github-releases \
    --action trigger --manifest x --version 1.0.0 --registry https://github.com/myorg/myrepo
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "PASSED" ]
  jq -r '.summary' "$OUTPUT" | grep -qF 'releases/tag/v1.0.0'
}

@test "TC-PUB-5: github-releases trigger FAILED → stderr surfaced in evidence" {
  GH_PUBLISH_MOCK=1 GH_TOKEN=test GH_PUBLISH_OUTCOME=FAILED GH_PUBLISH_STDERR="tag v1.0.0 already exists" \
    run _run_adapter github-releases \
    --action trigger --manifest x --version 1.0.0 --registry https://github.com/myorg/myrepo
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "FAILED" ]
  jq -r '.evidence[0].content' "$OUTPUT" | grep -qF 'already exists'
}

@test "TC-PUB-5 (NFR-081): missing GH_TOKEN → trigger FAILED" {
  unset GH_TOKEN GH_PUBLISH_MOCK
  run _run_adapter github-releases \
    --action trigger --manifest x --version 1.0.0 --registry https://github.com/myorg/myrepo
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "FAILED" ]
  jq -r '.summary' "$OUTPUT" | grep -qi 'GH_TOKEN missing'
}

# ---------- TC-PUB-6: mobile-app STUB returns UNVERIFIED ----------

@test "TC-PUB-6: mobile-app STUB trigger returns UNVERIFIED with next_step marker" {
  run _run_adapter mobile-app \
    --action trigger --manifest x --version 1.0.0 --registry app-store \
    --platform ios --store-id 12345
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "UNVERIFIED" ]
  [ "$(jq -r '.next_step' "$OUTPUT")" = "human-review-required" ]
  jq -r '.summary' "$OUTPUT" | grep -qi 'human review required'
}

@test "TC-PUB-6: mobile-app STUB verify also returns UNVERIFIED" {
  run _run_adapter mobile-app \
    --action verify --manifest x --version 1.0.0 --registry app-store \
    --platform android --store-id com.foo.bar
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "UNVERIFIED" ]
}

@test "TC-PUB-6 (AC3): mobile-app adapter-manifest verify_retry_window_seconds is null" {
  local manifest="$PLUGIN_DIR/scripts/adapters/publish-mobile-app/adapter-manifest.yaml"
  [ -f "$manifest" ]
  local window
  window=$(yq eval '.verify_retry_window_seconds' "$manifest")
  [ "$window" = "null" ]
}

# ---------- TC-PUB-7: container-registry matrix ----------

@test "TC-PUB-7: container-registry docker.io + semver tag strategy" {
  CONTAINER_PUSH_MOCK=1 DOCKER_TOKEN=t run _run_adapter container-registry \
    --action trigger --manifest x --version 1.2.3 --registry docker.io \
    --image-name myorg/myimg --tag-strategy semver
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "PASSED" ]
  # semver strategy produces v1.2.3, v1.2, latest
  jq -r '.summary' "$OUTPUT" | grep -qF 'v1.2.3'
  jq -r '.summary' "$OUTPUT" | grep -qF 'v1.2'
  jq -r '.summary' "$OUTPUT" | grep -qF 'latest'
}

@test "TC-PUB-7: container-registry ghcr.io + commit-sha strategy" {
  CONTAINER_PUSH_MOCK=1 GH_TOKEN=t run _run_adapter container-registry \
    --action trigger --manifest x --version 1.0.0 --registry ghcr.io \
    --image-name myorg/myimg --tag-strategy commit-sha --commit-sha abc123def
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "PASSED" ]
  jq -r '.summary' "$OUTPUT" | grep -qF 'abc123def'
}

@test "TC-PUB-7 (NFR-081): container-registry docker.io requires DOCKER_TOKEN" {
  unset DOCKER_TOKEN GH_TOKEN CONTAINER_PUSH_MOCK
  run _run_adapter container-registry \
    --action trigger --manifest x --version 1.0.0 --registry docker.io \
    --image-name myorg/myimg --tag-strategy semver
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "FAILED" ]
  jq -r '.summary' "$OUTPUT" | grep -qi 'credential.*docker'
}

@test "TC-PUB-7 (NFR-081): container-registry ghcr.io requires GH_TOKEN" {
  unset DOCKER_TOKEN GH_TOKEN CONTAINER_PUSH_MOCK
  run _run_adapter container-registry \
    --action trigger --manifest x --version 1.0.0 --registry ghcr.io \
    --image-name myorg/myimg --tag-strategy semver
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "FAILED" ]
  jq -r '.summary' "$OUTPUT" | grep -qi 'credential.*ghcr'
}

# ---------- TC-PUB-8: static-site 6-provider dispatch + cdn_invalidation ----------

_run_static_site() {
  local provider="$1"; shift
  STATIC_SITE_MOCK=1 "$PLUGIN_DIR/scripts/adapters/publish-static-site/run.sh" \
    --action trigger --manifest x --version 1.0.0 --registry https://example.com \
    --output "$OUTPUT" --provider "$provider" --domain example.com --dry-run "$@"
}

@test "TC-PUB-8 (cloudflare-pages): provider dispatch + envelope PASSED" {
  run _run_static_site cloudflare-pages
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "PASSED" ]
  [ "$(jq -r '.adapter_metadata.provider' "$OUTPUT")" = "cloudflare-pages" ]
  jq -r '.summary' "$OUTPUT" | grep -qi 'wrangler\|cloudflare'
}

@test "TC-PUB-8 (s3 no cdn): aws s3 sync invoked, NO CloudFront invalidation" {
  run _run_static_site s3 --cdn-invalidation false
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "PASSED" ]
  jq -r '.summary' "$OUTPUT" | grep -qi 'cdn_invalidation=false\|no CDN invalidation\|s3 sync'
  # Verify NO cloudfront in evidence (dry-run output)
  ! jq -r '.evidence[].content' "$OUTPUT" | grep -qi 'cloudfront'
}

@test "TC-PUB-8 (s3 + cdn): aws s3 sync THEN cloudfront create-invalidation" {
  # Non-dry-run path to exercise the CDN branch.
  STATIC_SITE_MOCK=1 run "$PLUGIN_DIR/scripts/adapters/publish-static-site/run.sh" \
    --action trigger --manifest x --version 1.0.0 --registry https://s3.example.com \
    --output "$OUTPUT" --provider s3 --domain example.com --cdn-invalidation true
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "PASSED" ]
  jq -r '.evidence[].content' "$OUTPUT" | grep -qF 'aws s3 sync'
  jq -r '.evidence[].content' "$OUTPUT" | grep -qF 'cloudfront create-invalidation'
}

@test "TC-PUB-8 (netlify): provider dispatch" {
  run _run_static_site netlify
  [ "$status" -eq 0 ]
  [ "$(jq -r '.verdict' "$OUTPUT")" = "PASSED" ]
  jq -r '.summary' "$OUTPUT" | grep -qi 'netlify'
}

@test "TC-PUB-8 (vercel): provider dispatch" {
  run _run_static_site vercel
  [ "$status" -eq 0 ]
  [ "$(jq -r '.verdict' "$OUTPUT")" = "PASSED" ]
  jq -r '.summary' "$OUTPUT" | grep -qi 'vercel'
}

@test "TC-PUB-8 (github-pages): provider dispatch" {
  run _run_static_site github-pages
  [ "$status" -eq 0 ]
  [ "$(jq -r '.verdict' "$OUTPUT")" = "PASSED" ]
  jq -r '.summary' "$OUTPUT" | grep -qi 'gh-pages\|github pages'
}

@test "TC-PUB-8 (custom): escape-hatch returns UNVERIFIED with deferred-to-wrapper marker" {
  run _run_static_site custom
  [ "$status" -eq 0 ]
  [ "$(jq -r '.verdict' "$OUTPUT")" = "UNVERIFIED" ]
  jq -r '.summary' "$OUTPUT" | grep -qi 'user-supplied\|custom'
}

@test "TC-PUB-8 (unknown provider): closed-enum rejection with documented error" {
  run "$PLUGIN_DIR/scripts/adapters/publish-static-site/run.sh" \
    --action trigger --manifest x --version 1.0.0 --registry x \
    --output "$OUTPUT" --provider invalid --domain x
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "unknown static-site provider 'invalid'"
  echo "$output" | grep -qF 'must be one of {cloudflare-pages, s3, netlify, vercel, github-pages, custom}'
}

@test "TC-PUB-8 (NFR-081): netlify non-mock without NETLIFY_AUTH_TOKEN → FAILED" {
  unset NETLIFY_AUTH_TOKEN
  unset STATIC_SITE_MOCK
  run "$PLUGIN_DIR/scripts/adapters/publish-static-site/run.sh" \
    --action trigger --manifest x --version 1.0.0 --registry https://example.com \
    --output "$OUTPUT" --provider netlify --domain example.com
  [ "$status" -eq 0 ]
  _assert_envelope_well_formed
  [ "$(jq -r '.verdict' "$OUTPUT")" = "FAILED" ]
  jq -r '.summary' "$OUTPUT" | grep -qF 'NETLIFY_AUTH_TOKEN'
}

@test "TC-PUB-8 (manifest): static-site adapter-manifest declares verify_retry_window_seconds: 30" {
  local manifest="$PLUGIN_DIR/scripts/adapters/publish-static-site/adapter-manifest.yaml"
  [ -f "$manifest" ]
  local window
  window=$(yq eval '.verify_retry_window_seconds' "$manifest")
  [ "$window" = "30" ]
}

# ---------- Contract conformance: all 4 adapters ----------

@test "All 8 adapters comply with FR-526 (--action mandatory, fails on missing)" {
  for ch in claude-marketplace npm pypi homebrew github-releases container-registry mobile-app static-site; do
    run "$PLUGIN_DIR/scripts/adapters/publish-$ch/run.sh" --version 1.0.0 --manifest x --registry x --output "$TEST_TMP/o-$ch.json"
    [ "$status" -ne 0 ] || { echo "$ch did not fail on missing --action" >&2; false; }
  done
}

@test "All adapters accept --dry-run without crashing (FR-526)" {
  # Mobile-app STUB and container-registry need channel-specific flags; tested separately above.
  for ch in claude-marketplace npm pypi homebrew github-releases; do
    case "$ch" in
      claude-marketplace) MARKETPLACE_PUBLISH_MOCK=1 ;;
      npm) NPM_PUBLISH_MOCK=1; export NPM_TOKEN=test ;;
      pypi) export TWINE_MOCK_EXIT=0 ;;
      homebrew) HOMEBREW_MOCK=1 ;;
      github-releases) GH_PUBLISH_MOCK=1 ;;
    esac
    run env CLAUDE_MARKETPLACE_TOKEN=x NPM_TOKEN=x PYPI_API_TOKEN=x HOMEBREW_GITHUB_TOKEN=x GH_TOKEN=x \
        MARKETPLACE_PUBLISH_MOCK=1 NPM_PUBLISH_MOCK=1 HOMEBREW_MOCK=1 GH_PUBLISH_MOCK=1 \
        "$PLUGIN_DIR/scripts/adapters/publish-$ch/run.sh" \
        --action trigger --manifest m --version 1.0.0 --registry r --output "$TEST_TMP/dr-$ch.json" --dry-run
    [ "$status" -eq 0 ]
    bash "$ENVELOPE_VAL" "$TEST_TMP/dr-$ch.json"
  done
}

@test "All 8 adapters comply with FR-526 (unknown flag rejected — fail-closed AC2)" {
  # mobile-app STUB also rejects unknown flags via EXTRA_ARGS parse.
  for ch in claude-marketplace npm pypi homebrew github-releases container-registry mobile-app static-site; do
    run "$PLUGIN_DIR/scripts/adapters/publish-$ch/run.sh" \
      --action trigger --manifest m --version 1.0.0 --registry r --output "$TEST_TMP/uf-$ch.json" --bogus
    [ "$status" -ne 0 ] || { echo "$ch did not reject --bogus" >&2; false; }
    echo "$output" | grep -qF 'unknown flag'
  done
}

@test "All 8 adapter-manifest.yaml files validate against adapter-manifest.schema.json shape" {
  local schema="$PLUGIN_DIR/schemas/adapter-manifest.schema.json"
  [ -f "$schema" ]
  for ch in claude-marketplace npm pypi homebrew github-releases container-registry mobile-app static-site; do
    local manifest="$PLUGIN_DIR/scripts/adapters/publish-$ch/adapter-manifest.yaml"
    [ -f "$manifest" ]
    # Top-level required fields present (verify_retry_window_seconds may be null for mobile-app).
    for field in adapter_name adapter_version channel credential_env_vars description; do
      yq eval ".$field" "$manifest" | grep -qv '^null$' || { echo "$ch missing $field" >&2; false; }
    done
    # verify_retry_window_seconds must be present (either integer or null).
    yq eval 'has("verify_retry_window_seconds")' "$manifest" | grep -q '^true$' || { echo "$ch missing verify_retry_window_seconds key" >&2; false; }
    # SR-83 cap (skip for null/mobile-app).
    local window
    window=$(yq eval '.verify_retry_window_seconds' "$manifest")
    if [ "$window" != "null" ]; then
      [ "$window" -le 3600 ] || { echo "$ch window $window exceeds SR-83 cap" >&2; false; }
    fi
  done
}
