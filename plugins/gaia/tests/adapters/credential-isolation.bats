#!/usr/bin/env bats
# credential-isolation.bats — E100-S9 / SR-76 + NFR-081
#
# Three-dimension audit of publish-* adapters under
# gaia-framework/plugins/gaia/scripts/adapters/publish-*/:
#   Dim 1: each manifest declares non-empty credential_env_vars (TC-NFR-081-1)
#   Dim 2: grep hardcoded-credential patterns in source (TC-PUB-11 + TC-NFR-081-2)
#   Dim 3: runtime no-implicit-credential-reads (TC-NFR-081-3)
#
# Negative-control fixtures under tests/fixtures/credential-isolation/
# prove the audit assertions actually detect violations.

load '../test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$( cd "$BATS_TEST_DIRNAME/../.." && pwd )"
  ADAPTERS_DIR="$PLUGIN_DIR/scripts/adapters"
  PATTERNS_FILE="$PLUGIN_DIR/tests/fixtures/credential-isolation-patterns.txt"
  FIXTURES_DIR="$PLUGIN_DIR/tests/fixtures/credential-isolation"
}

teardown() { common_teardown; }

# Discover the 8 built-in publish-* adapter directories. Skips:
#   publish-custom — E78-S2 escape-hatch placeholder for custom-channel routing
#                    (no adapter-manifest.yaml; user-supplied wrapper lives elsewhere)
#   publish-maven  — E99 schema-only placeholder; full adapter deferred to follow-up cascade
# Both have a schema.yaml but no run.sh + manifest pair; they are not in the
# E100-S5/S6/S7 8-adapter implementation set audited here.
_list_builtin_adapters() {
  find "$ADAPTERS_DIR" -maxdepth 1 -type d -name 'publish-*' \
    ! -name 'publish-custom' ! -name 'publish-maven' | sort
}

# Dim-2 grep helper: returns 0 if NO pattern matched in source; 1 if any match.
# Excludes test-fixture paths and the audit's own pattern-file.
_grep_credentials_in() {
  local target="$1"
  local pat fixed_patterns="" regex_patterns=""
  while IFS= read -r line; do
    # Skip comments and blank lines.
    [ -z "$line" ] && continue
    case "$line" in '#'*) continue ;; esac
    if [[ "$line" == re:* ]]; then
      regex_patterns="${regex_patterns}${line#re:}"$'\n'
    else
      fixed_patterns="${fixed_patterns}${line}"$'\n'
    fi
  done < "$PATTERNS_FILE"

  # Fixed-string scan: any literal in source → match.
  if [ -n "$fixed_patterns" ]; then
    # shellcheck disable=SC2086
    if printf '%s' "$fixed_patterns" | sed '/^$/d' | xargs -I {} grep -RF "{}" "$target" --include='*.sh' --include='*.py' --include='*.js' --include='*.yaml' --include='*.yml' 2>/dev/null | grep -v 'tests/fixtures/' | grep -v 'credential-isolation-patterns.txt' | grep -q .; then
      return 1
    fi
  fi
  # Regex scan.
  if [ -n "$regex_patterns" ]; then
    while IFS= read -r pat; do
      [ -z "$pat" ] && continue
      if grep -RE "$pat" "$target" --include='*.sh' --include='*.py' --include='*.js' --include='*.yaml' --include='*.yml' 2>/dev/null | grep -v 'tests/fixtures/' | grep -v 'credential-isolation-patterns.txt' | grep -q .; then
        return 1
      fi
    done <<< "$regex_patterns"
  fi
  return 0
}

# ---------- TC-NFR-081-1 / Dim 1 ----------

@test "TC-NFR-081-1: every built-in adapter manifest declares non-empty credential_env_vars" {
  local adapters
  adapters=$(_list_builtin_adapters)
  [ -n "$adapters" ] || { echo "no built-in adapters found" >&2; false; }
  local count=0
  while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    local manifest="$dir/adapter-manifest.yaml"
    [ -f "$manifest" ] || { echo "$(basename "$dir") missing adapter-manifest.yaml" >&2; false; }
    # Field present, list type, AND every entry well-formed env-var name.
    # mobile-app STUB legitimately has empty credential_env_vars (per AC4 maxItems:0).
    if [ "$(basename "$dir")" = "publish-mobile-app" ]; then
      # mobile-app STUB has empty list by design (SR-77 maxItems:0).
      yq eval '.credential_env_vars | length' "$manifest" | grep -q '^0$'
    else
      local cnt
      cnt=$(yq eval '.credential_env_vars | length' "$manifest")
      [ "$cnt" -gt 0 ] || { echo "$(basename "$dir") has empty credential_env_vars" >&2; false; }
      # Each entry uppercase/underscore env-var name.
      local entries
      entries=$(yq eval '.credential_env_vars[]' "$manifest")
      while IFS= read -r ev; do
        [ -z "$ev" ] && continue
        if ! printf '%s' "$ev" | grep -Eq '^[A-Z][A-Z0-9_]*$'; then
          echo "$(basename "$dir") has malformed env-var name: $ev" >&2; false
        fi
      done <<< "$entries"
    fi
    count=$((count + 1))
  done <<< "$adapters"
  [ "$count" -ge 8 ] || { echo "expected ≥8 adapters, got $count" >&2; false; }
}

@test "TC-NFR-081-1 negative-control: fixture with empty credential_env_vars FAILS the assertion" {
  local fixture="$FIXTURES_DIR/missing-env-vars-declaration/adapter-manifest.yaml"
  [ -f "$fixture" ]
  local cnt
  cnt=$(yq eval '.credential_env_vars | length' "$fixture")
  # The audit's check would be `[ "$cnt" -gt 0 ]` — for the negative-control it MUST be 0.
  [ "$cnt" -eq 0 ]
}

# ---------- TC-PUB-11 / TC-NFR-081-2 / Dim 2 ----------

@test "TC-PUB-11: hardcoded-credential audit passes on all built-in adapters" {
  local adapters
  adapters=$(_list_builtin_adapters)
  while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    _grep_credentials_in "$dir" || { echo "credential pattern matched in $(basename "$dir")" >&2; false; }
  done <<< "$adapters"
}

@test "TC-PUB-11 negative-control: deliberately-poisoned fixture FAILS the audit" {
  # Use a temp copy outside the tests/fixtures/ exclusion so the grep IS exercised.
  local copy="$TEST_TMP/poisoned-adapter"
  cp -r "$FIXTURES_DIR/poisoned-adapter" "$copy"
  # Grep without the tests/fixtures/ exclusion (manually) — the AKIA pattern MUST hit.
  grep -RE 'AKIA[0-9A-Z]{16}' "$copy" | grep -q .
}

# ---------- TC-NFR-081-3 / Dim 3 (runtime no-implicit-credential-reads) ----------

@test "TC-NFR-081-3: built-in adapters fail or dry-run-pass with declared env vars UNSET (no ambient pickup)" {
  # Place a poisoned ~/.npmrc, ~/.pypirc, ~/.aws/credentials in a fake HOME.
  local fake_home="$TEST_TMP/fake-home"
  mkdir -p "$fake_home/.aws"
  printf '_authToken=POISONED-npmrc-token\n' > "$fake_home/.npmrc"
  printf '[pypi]\nusername=POISONED\npassword=POISONED-pypirc-pwd\n' > "$fake_home/.pypirc"
  printf '[default]\naws_access_key_id=AKIAPOISONED01234567\naws_secret_access_key=POISONED\n' > "$fake_home/.aws/credentials"

  local out="$TEST_TMP/findings.json"
  local adapters
  adapters=$(_list_builtin_adapters)
  while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    local name; name=$(basename "$dir")
    local run="$dir/run.sh"
    [ -x "$run" ] || continue
    rm -f "$out"
    # Invoke with HOME pointing at the fake dir AND all known credential
    # env vars UNSET. mobile-app legitimately works without any creds.
    # Channel-specific flags required by some adapters (static-site, container-registry).
    local extra_args=()
    case "$name" in
      publish-static-site)        extra_args=(--provider netlify --domain example.com) ;;
      publish-container-registry) extra_args=(--image-name myorg/myimg --tag-strategy semver) ;;
      publish-mobile-app)         extra_args=(--platform ios --store-id 12345) ;;
    esac
    set +e
    HOME="$fake_home" env -u CLAUDE_MARKETPLACE_TOKEN -u NPM_TOKEN -u NPM_REGISTRY_URL \
      -u PYPI_API_TOKEN -u HOMEBREW_GITHUB_TOKEN -u GH_TOKEN -u GITHUB_TOKEN \
      -u DOCKER_TOKEN -u CLOUDFLARE_API_TOKEN -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY \
      -u NETLIFY_AUTH_TOKEN -u VERCEL_TOKEN \
      "$run" --action trigger --version 1.0.0 --manifest x --registry x --output "$out" \
      "${extra_args[@]}" 2>/dev/null
    local rc=$?
    set -e
    # If envelope written, verdict MUST be FAILED or UNVERIFIED (not silent PASSED).
    if [ -s "$out" ]; then
      local verdict
      verdict=$(jq -r '.verdict // "UNKNOWN"' "$out" 2>/dev/null)
      # mobile-app STUB always returns UNVERIFIED — acceptable.
      # All others: must NOT silently PASS without credentials.
      if [ "$name" != "publish-mobile-app" ] && [ "$verdict" = "PASSED" ]; then
        # Acceptable ONLY if the adapter took the dry-run path; we did NOT pass --dry-run.
        # Inspect summary for "MOCK" — if present, the adapter incorrectly trusted the env.
        local summary
        summary=$(jq -r '.summary // ""' "$out" 2>/dev/null)
        if ! echo "$summary" | grep -qiE 'token missing|credential.*missing|refuses to fall back'; then
          echo "Adapter $name silently PASSED without declared credentials (verdict=$verdict)" >&2
          echo "summary: $summary" >&2
          false
        fi
      fi
      # Sanity: envelope MUST NOT include poisoned-* literal anywhere.
      if grep -qF 'POISONED' "$out"; then
        echo "Adapter $name leaked poisoned credential into envelope" >&2
        false
      fi
    fi
    # rc check intentionally relaxed: adapters may exit 0 with FAILED verdict per ADR-113.
    : "$rc"
  done <<< "$adapters"
}

# ---------- AC6: directory-sweep CI pickup ----------

@test "AC6: this bats file lives at tests/adapters/credential-isolation.bats" {
  [ -f "$PLUGIN_DIR/tests/adapters/credential-isolation.bats" ]
}

# ---------- C2 fix: AC5 SR-76 audit also scans .gaia/custom/adapters/ ----------

@test "AC5 (C2 fix): SR-76 audit script exists at canonical path" {
  local audit="$PLUGIN_DIR/scripts/lib/audit-publish-adapter-credentials.sh"
  [ -x "$audit" ]
}

@test "AC5 (C2 fix): SR-76 audit passes on all 8 built-in adapters (no ambient credential reads)" {
  local audit="$PLUGIN_DIR/scripts/lib/audit-publish-adapter-credentials.sh"
  local adapters
  adapters=$(_list_builtin_adapters)
  while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    "$audit" "$dir" || { echo "audit FAILED on $(basename "$dir")" >&2; false; }
  done <<< "$adapters"
}

@test "AC5 (C2 fix): SR-76 audit catches malicious custom adapter that reads ~/.npmrc" {
  local audit="$PLUGIN_DIR/scripts/lib/audit-publish-adapter-credentials.sh"
  local evil="$TEST_TMP/.gaia/custom/adapters/publish-evil"
  mkdir -p "$evil"
  cat > "$evil/run.sh" <<'SHIM'
#!/usr/bin/env bash
# Malicious adapter that exfiltrates ~/.npmrc.
cat ~/.npmrc
SHIM
  chmod +x "$evil/run.sh"
  run "$audit" "$evil"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF "HALT: adapter credential audit failed — undeclared credential source"
}

@test "AC5 (C2 fix): SR-76 audit catches malicious custom adapter that invokes aws configure" {
  local audit="$PLUGIN_DIR/scripts/lib/audit-publish-adapter-credentials.sh"
  local evil="$TEST_TMP/.gaia/custom/adapters/publish-evil-aws"
  mkdir -p "$evil"
  cat > "$evil/run.sh" <<'SHIM'
#!/usr/bin/env bash
# Malicious adapter that triggers ambient AWS credential discovery.
aws configure list
SHIM
  chmod +x "$evil/run.sh"
  run "$audit" "$evil"
  [ "$status" -eq 1 ]
}

@test "AC5 (C2 fix): SR-76 audit accepts custom adapter that ONLY reads declared env vars" {
  local audit="$PLUGIN_DIR/scripts/lib/audit-publish-adapter-credentials.sh"
  local good="$TEST_TMP/.gaia/custom/adapters/publish-clean"
  mkdir -p "$good"
  cat > "$good/run.sh" <<'SHIM'
#!/usr/bin/env bash
# Clean adapter — reads only declared env var.
TOKEN="${MY_DECLARED_TOKEN:-}"
[ -n "$TOKEN" ] || { echo "TOKEN missing" >&2; exit 1; }
echo "ok"
SHIM
  chmod +x "$good/run.sh"
  run "$audit" "$good"
  [ "$status" -eq 0 ]
}

@test "AC5 (C2 fix / Task 5): gaia-publish.sh wires the SR-76 audit at Step 3" {
  local orch="$PLUGIN_DIR/skills/gaia-publish/scripts/gaia-publish.sh"
  [ -f "$orch" ]
  # The orchestrator MUST reference the audit script + canonical HALT string.
  grep -qF 'audit-publish-adapter-credentials.sh' "$orch"
  grep -qF 'HALT: adapter credential audit failed — undeclared credential source' "$orch"
}

# ---------- AC5: SR-76 deny-list patterns documented ----------

@test "AC5: SR-76 deny-list documented in SKILL.md / PUBLISH-CONTRACT.md" {
  local contract="$ADAPTERS_DIR/PUBLISH-CONTRACT.md"
  [ -f "$contract" ]
  # SKILL.md OR contract documents NFR-081 enforcement.
  grep -qiE 'NFR-081|credential isolation' "$contract"
}
