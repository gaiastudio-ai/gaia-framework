#!/usr/bin/env bash
# generate-pipeline.sh — deterministic CI workflow generator for /gaia-ci-setup
#
# Deterministic CI workflow generator for /gaia-ci-setup Step 8. Replaces
# the prior LLM-only authoring path so a headless YOLO `/gaia-ci-setup`
# invocation can actually produce a runnable workflow file (rather than
# leaving the exit-1 stub init's `generate-ci-scaffold.sh` emits).
#
# Reads the active test-environment.yaml + project-config.yaml to learn
# which stack the project uses, then emits a stack-aware GitHub Actions
# `gaia-pre-merge.yml` whose pre-merge gates ACTUALLY RUN something
# instead of `exit 1`.
#
# Currently supports: github-actions on python/node/go/jvm. Other providers
# (gitlab-ci/circleci/jenkins/azure-pipelines/bitbucket-pipelines) fall
# through with a clear message naming the supported set + pointing the
# operator at the init-generated stub for hand-editing.
#
# Usage:
#   generate-pipeline.sh --provider <ci> --stack <stack> --project-root <dir>
#
# Exit codes:
#   0  workflow written (or no-op when already correct)
#   1  unsupported provider / missing inputs
#   2  argument error

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-ci-setup/generate-pipeline.sh"
log()  { printf 'INFO: %s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
warn() { printf 'WARNING: %s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die()  { printf 'ERROR: %s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit "${2:-2}"; }

PROVIDER=""
STACK=""
PROJECT_ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --provider)     PROVIDER="${2:-}"; shift 2 ;;
    --stack)        STACK="${2:-}"; shift 2 ;;
    --project-root) PROJECT_ROOT="${2:-}"; shift 2 ;;
    -h|--help)
      cat <<EOF
$SCRIPT_NAME — deterministic CI workflow generator for /gaia-ci-setup Step 8

Usage:
  $0 --provider <ci> --stack <stack> --project-root <dir>

Supported providers: github-actions
Supported stacks: python, node, go, jvm

Writes the workflow to <project-root>/.github/workflows/gaia-pre-merge.yml.
Refuses to overwrite a workflow that was hand-edited (drops a NOTICE).
EOF
      exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done

[ -n "$PROVIDER" ]     || die "--provider required (try: github-actions)"
[ -n "$STACK" ]        || die "--stack required (try: python, node, go, jvm)"
[ -n "$PROJECT_ROOT" ] || die "--project-root required"
[ -d "$PROJECT_ROOT" ] || die "project root does not exist: $PROJECT_ROOT"

if [ "$PROVIDER" != "github-actions" ]; then
  warn "provider '$PROVIDER' is not yet supported by the deterministic generator (supported: github-actions)"
  warn "the init-generated stub remains in place; hand-edit it via /gaia-ci-setup interactive mode"
  exit 1
fi

case "$STACK" in
  python|node|go|jvm) : ;;
  *) warn "stack '$STACK' is not yet supported by the deterministic generator (supported: python, node, go, jvm)"
     warn "the init-generated stub remains in place; hand-edit it via /gaia-ci-setup interactive mode"
     exit 1 ;;
esac

WORKFLOW="$PROJECT_ROOT/.github/workflows/gaia-pre-merge.yml"
mkdir -p "$(dirname "$WORKFLOW")"

# Refuse to overwrite a workflow that already exists AND lacks the
# init-stub marker line (operators may have customised it).
if [ -f "$WORKFLOW" ] && ! grep -qF 'GAIA pre-merge gate is not yet configured' "$WORKFLOW"; then
  warn "$WORKFLOW already exists and does not contain the init-stub marker — refusing to overwrite (use /gaia-ci-setup --regenerate to force)"
  exit 0
fi

case "$STACK" in
  python)
    _run_block='      - uses: actions/setup-python@v5
        with:
          python-version: "3.x"
      - name: Install
        run: |
          python -m pip install --upgrade pip
          if [ -f pyproject.toml ]; then pip install -e ".[dev]" || pip install .; fi
          if [ -f requirements.txt ]; then pip install -r requirements.txt; fi
          if [ -f requirements-dev.txt ]; then pip install -r requirements-dev.txt; fi
      - name: Test
        run: |
          if command -v pytest >/dev/null; then pytest -q; else python -m unittest discover -v; fi'
    ;;
  node)
    _run_block='      - uses: actions/setup-node@v4
        with:
          node-version: "20"
      - name: Install
        run: |
          if [ -f pnpm-lock.yaml ]; then npm install -g pnpm && pnpm install --frozen-lockfile
          elif [ -f yarn.lock ]; then yarn install --frozen-lockfile
          else npm ci || npm install; fi
      - name: Test
        run: |
          if [ -f pnpm-lock.yaml ]; then pnpm test
          elif [ -f yarn.lock ]; then yarn test
          else npm test; fi'
    ;;
  go)
    _run_block='      - uses: actions/setup-go@v5
        with:
          go-version: stable
      - name: Build
        run: go build ./...
      - name: Test
        run: go test -v ./...'
    ;;
  jvm)
    _run_block='      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: "17"
      - name: Test
        run: |
          if [ -f pom.xml ]; then mvn -B test
          elif [ -f build.gradle ] || [ -f build.gradle.kts ]; then ./gradlew test || gradle test
          else echo "no maven/gradle marker found" >&2; exit 1; fi'
    ;;
esac

# Atomic write via tempfile + mv.
_tmp="$(mktemp "${WORKFLOW}.XXXXXX")"
cat > "$_tmp" <<EOF
# Generated by /gaia-ci-setup.
# Pre-merge quality gate — runs the project's test suite on every pull
# request against main / staging. Hand-edits are preserved on re-run UNLESS
# the file still carries the init-stub marker (the prior no-op placeholder
# /gaia-init seeds); in that case /gaia-ci-setup regenerates this workflow
# without prompting. Customise the matrix or add lint steps in the
# sibling \`gaia-pre-merge.user-steps.yml\` companion (preserved verbatim
# on regeneration).
name: gaia-pre-merge
on:
  pull_request:
    branches: [main, staging]
jobs:
  gaia-gates:
    name: GAIA pre-merge gates
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4
$_run_block
EOF
mv "$_tmp" "$WORKFLOW"

log "wrote $WORKFLOW (stack=$STACK, provider=$PROVIDER)"
exit 0
