# CI Scripting Patterns

<!-- SECTION: exit-codes -->
## Exit Codes

CI interprets exit code 0 as success and any non-zero as failure. Propagate
errors explicitly — never swallow them:

```bash
# BAD: error from jq is silently ignored
result=$(jq '.verdict' "$file")

# GOOD: the pipeline fails fast
result="$(jq -e '.verdict' "$file")"   # jq -e exits 1 when value is null/false

# BAD: composite command masks the failing step
validate && deploy || echo "something failed"

# GOOD: check each step
if ! validate; then
  printf 'validation failed\n' >&2
  exit 1
fi
deploy
```

<!-- SECTION: idempotency -->
## Idempotency

CI jobs run again on retry. Every script that creates state must be safe to
re-execute against an already-complete run:

```bash
# Idempotent directory creation
mkdir -p "$OUT_DIR"

# Idempotent git tag — skip if already exists
if ! git rev-parse "refs/tags/$TAG" >/dev/null 2>&1; then
  git tag -a "$TAG" -m "Release $TAG"
fi

# Idempotent file write — use atomic rename
TMP="$(mktemp)"
generate_content > "$TMP"
mv "$TMP" "$OUTPUT_FILE"
```

<!-- SECTION: secrets-hygiene -->
## Secrets Hygiene

Never echo or log secret values. Use environment variables; never embed secrets
in scripts committed to source control:

```bash
# BAD: secret visible in process list and CI logs
curl -H "Authorization: Bearer $TOKEN" "$URL"

# BAD: logged by set -x
set -x
curl -H "Authorization: Bearer supersecret123" ...

# GOOD: value comes from environment; never echoed
: "${API_TOKEN:?API_TOKEN must be set}"
curl -H "Authorization: Bearer $API_TOKEN" "$URL"

# Mask secrets in GitHub Actions
echo "::add-mask::$API_TOKEN"
```

<!-- SECTION: parallel-safe -->
## Parallel-Safe Patterns

When CI runs matrix jobs or parallel steps that write shared state, use atomic
operations:

```bash
# Atomic write — mv is atomic within the same filesystem
TMP="$(mktemp -p "$(dirname "$DEST")")"
build_artifact > "$TMP"
mv "$TMP" "$DEST"

# Lock file with timeout (Linux — flock not available on macOS default PATH)
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE"
  flock -w 30 9
fi
```

<!-- SECTION: job-summaries -->
## GitHub Actions Job Summaries

Write structured output to `$GITHUB_STEP_SUMMARY` for human-readable CI reports:

```bash
write_summary() {
  local verdict="$1" details="$2"
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] && return 0
  {
    printf '## Result: %s\n\n' "$verdict"
    printf '%s\n' "$details"
  } >> "$GITHUB_STEP_SUMMARY"
}

# Guard against missing env (local runs)
: "${GITHUB_STEP_SUMMARY:=/dev/null}"
```

<!-- SECTION: deterministic-toolchain -->
## Deterministic Toolchain

Pin tool versions in CI to avoid drift between runs:

```yaml
# .github/workflows/ci.yml excerpt
- uses: actions/setup-python@v5
  with:
    python-version: '3.12'

- name: Install bats
  run: |
    npm install -g bats@1.10.0
    bats --version
```

In scripts, assert minimum versions when the behavior differs across releases:

```bash
_require_jq_version() {
  local need="$1"
  local have
  have="$(jq --version 2>&1 | grep -oE '[0-9]+\.[0-9]+')"
  # Simple major.minor comparison
  [ "$(printf '%s\n%s\n' "$need" "$have" | sort -V | head -1)" = "$need" ] \
    || { printf 'jq >= %s required, found %s\n' "$need" "$have" >&2; exit 1; }
}
_require_jq_version "1.6"
```
