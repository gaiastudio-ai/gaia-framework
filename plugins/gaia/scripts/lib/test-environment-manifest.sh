#!/usr/bin/env bash
# test-environment-manifest.sh — E17-S33 (ADR-110)
#
# Shared library helper: extracts /gaia-brownfield Phase 5 manifest-generation
# logic into a callable shell helper. Detects project stack via detect-signals.sh
# (gaia-public/plugins/gaia/scripts/) and emits a stack-specific
# test-environment.yaml on stdout or writes it to config/test-environment.yaml
# at the target project root.
#
# This helper is the SINGLE canonical generator for test-environment.yaml going
# forward. /gaia-brownfield Phase 5 delegates here; /gaia-bridge-enable Step 4
# (via E17-S34) also delegates here for the inline auto-generate path.
#
# Semantics:
#   - --target alone:           emit yaml on stdout (no write)
#   - --target --write:         write to <target>/config/test-environment.yaml
#                               (copy-if-absent: preserve user-edited file)
#   - Detected stack:           emit stack-specific runners[] (no GAIA-MANIFEST-TEMPLATE sentinel)
#   - No-stack project:         emit generic single-runner tier-1 placeholder
#                               (E17-S35 will add sentinel emission to this branch)
#
# Output is BYTE-STABLE: re-running on the same project produces identical
# output. Runners are emitted in canonical order (sorted by tier, then name).
#
# Usage:
#   test-environment-manifest.sh --target <project-root> [--write]
#   test-environment-manifest.sh --help
#
# Exit codes:
#   0  success
#   1  filesystem / detect-signals failure
#   2  usage error
#
# Traces: E17-S33, FR-496, FR-497, ADR-110.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="test-environment-manifest.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DETECT_SIGNALS="${PLUGIN_ROOT}/scripts/detect-signals.sh"

MANIFEST_REL="config/test-environment.yaml"

target=""
write_mode=0

usage() {
  cat <<'USAGE'
Usage: test-environment-manifest.sh --target <project-root> [--write]

Detect project stack and emit a test-environment.yaml manifest. With --write,
the manifest is written to config/test-environment.yaml at the target root
(copy-if-absent: preserves user-edited file).

Exit codes:
  0  success
  1  detect-signals / filesystem failure
  2  usage error
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target)
      [ $# -ge 2 ] || { printf '%s: --target requires a value\n' "$SCRIPT_NAME" >&2; exit 2; }
      target="$2"; shift 2 ;;
    --write)
      write_mode=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf '%s: unexpected argument: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 2 ;;
  esac
done

[ -n "${target}" ] || { printf '%s: --target is required\n' "$SCRIPT_NAME" >&2; usage >&2; exit 2; }
[ -d "${target}" ] || { printf '%s: target directory does not exist: %s\n' "$SCRIPT_NAME" "${target}" >&2; exit 2; }

# --write copy-if-absent: short-circuit if the manifest already exists
manifest_path="${target}/${MANIFEST_REL}"
if [ "${write_mode}" -eq 1 ] && [ -f "${manifest_path}" ]; then
  exit 0
fi

# Run detect-signals to identify stack
if [ ! -x "${DETECT_SIGNALS}" ]; then
  printf '%s: ERROR: detect-signals.sh not found at %s\n' "$SCRIPT_NAME" "${DETECT_SIGNALS}" >&2
  exit 1
fi

detection=$("${DETECT_SIGNALS}" --project-root "${target}" --format json 2>/dev/null || echo '{"stacks":[],"warnings":["detect-signals failed"]}')
stacks=$(echo "${detection}" | jq -r '.stacks[]?.name // empty' 2>/dev/null | sort -u || echo "")

# Emit stack-specific runners. Order matters for byte-stability: sort by tier then name.
generate_runners() {
  local stack=""
  while IFS= read -r s; do
    case "$s" in
      react|vue|angular|svelte|node|typescript)
        stack="node"
        break ;;
      python)
        stack="python"
        break ;;
      go)
        stack="go"
        break ;;
      java|kotlin)
        stack="java"
        break ;;
      flutter|dart)
        stack="flutter"
        break ;;
      rust)
        stack="rust"
        break ;;
    esac
  done <<< "${stacks}"

  # Bash/bats detection: presence of *.bats files when no package.json
  if [ -z "$stack" ] && [ ! -f "${target}/package.json" ]; then
    if find "${target}" -maxdepth 3 -name "*.bats" -print -quit 2>/dev/null | grep -q .; then
      stack="bash"
    fi
  fi

  case "$stack" in
    node)
      cat <<'EOF'
runners:
  - name: unit
    command: "npm test"
    tier: 1
    test_pattern: "test/unit/**/*.test.js"
    timeout_seconds: 120
  - name: integration
    command: "npm run test:integration"
    tier: 2
    test_pattern: "test/integration/**/*.test.js"
    timeout_seconds: 300
EOF
      ;;
    python)
      cat <<'EOF'
runners:
  - name: unit
    command: "pytest tests/unit"
    tier: 1
    test_pattern: "tests/unit/**/test_*.py"
    timeout_seconds: 120
  - name: integration
    command: "pytest tests/integration"
    tier: 2
    test_pattern: "tests/integration/**/test_*.py"
    timeout_seconds: 300
EOF
      ;;
    go)
      cat <<'EOF'
runners:
  - name: unit
    command: "go test ./..."
    tier: 1
    test_pattern: "**/*_test.go"
    timeout_seconds: 120
EOF
      ;;
    java)
      cat <<'EOF'
runners:
  - name: unit
    command: "mvn test"
    tier: 1
    test_pattern: "src/test/java/**/*Test.java"
    timeout_seconds: 300
EOF
      ;;
    flutter)
      cat <<'EOF'
runners:
  - name: unit
    command: "flutter test"
    tier: 1
    test_pattern: "test/**/*_test.dart"
    timeout_seconds: 300
  - name: integration
    command: "flutter test integration_test"
    tier: 2
    test_pattern: "integration_test/**/*_test.dart"
    timeout_seconds: 600
EOF
      ;;
    bash)
      cat <<'EOF'
runners:
  - name: unit
    command: "bats tests/"
    tier: 1
    test_pattern: "tests/**/*.bats"
    timeout_seconds: 600
EOF
      ;;
    rust)
      cat <<'EOF'
runners:
  - name: unit
    command: "cargo test"
    tier: 1
    test_pattern: "src/**/*.rs"
    timeout_seconds: 300
EOF
      ;;
    *)
      # No-stack fallback (FR-497 generic placeholder)
      cat <<'EOF'
runners:
  - name: unit
    command: "make test"
    tier: 1
    test_pattern: ""
    timeout_seconds: 120
EOF
      ;;
  esac

  printf '%s\n' "$stack"
}

# Build the full manifest
runners_out=$(generate_runners)
stack=$(printf '%s' "$runners_out" | tail -n 1)
runners_body=$(printf '%s' "$runners_out" | sed '$d')

# Compose the full manifest. Byte-stable: no timestamps, no random IDs.
manifest=$(cat <<EOF
# test-environment.yaml — Test Execution Bridge Manifest
# Auto-generated by /gaia-bridge-enable (E17-S33 helper).
# Edit this file to fine-tune for your project.
#
# detected-stack: ${stack:-generic}
# Reference: architecture.md Section 10.20.5

version: 2

${runners_body}

primary_runner: unit

tiers:
  1:
    gates: [qa-tests, test-automate, test-review]
  2:
    gates: [review-perf]
  3:
    gates: []
EOF
)

if [ "${write_mode}" -eq 1 ]; then
  mkdir -p "$(dirname "${manifest_path}")"
  printf '%s\n' "${manifest}" > "${manifest_path}"
  printf '%s: installed %s (detected-stack=%s)\n' "$SCRIPT_NAME" "${MANIFEST_REL}" "${stack:-generic}" >&2
  exit 0
fi

printf '%s\n' "${manifest}"
exit 0
