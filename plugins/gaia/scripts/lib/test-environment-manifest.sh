#!/usr/bin/env bash
# test-environment-manifest.sh — E17-S33 + E17-S35 (ADR-110, FR-496, FR-497, FR-499)
#
# Shared library helper: detect project stack and emit a stack-specific
# .gaia/config/test-environment.yaml on stdout, or write it to the canonical path
# with --write (copy-if-absent semantics).
#
# Single canonical generator for test-environment.yaml — both /gaia-brownfield
# Phase 5 and /gaia-bridge-enable Step 4 invoke this helper.
#
# Sentinel emission (E17-S35):
#   - Stack DETECTED  → no sentinel (manifest is presumed-customized for the stack).
#   - Stack NOT MATCHED → GAIA-MANIFEST-TEMPLATE sentinel IS included so Layer 0
#     readiness will fail until the user customizes the placeholder runners.
#
# Output is BYTE-STABLE: no timestamps, no random IDs.
#
# Usage:
#   test-environment-manifest.sh --target <project-root> [--write]
#   test-environment-manifest.sh --help
#
# Exit codes:
#   0  success
#   1  detect-signals / filesystem failure
#   2  usage error
#
# Traces: E17-S33, E17-S35, FR-496, FR-497, FR-499, ADR-110.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="test-environment-manifest.sh"
SENTINEL_LINE='# GAIA-MANIFEST-TEMPLATE: edit this file before enabling the bridge -- bridge will fail Layer 0 readiness check until this line is removed'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DETECT_SIGNALS="${PLUGIN_ROOT}/scripts/detect-signals.sh"

# AF-2026-05-21-7/8: resolved after $target is validated.
MANIFEST_REL=""

target=""
write_mode=0

usage() {
  cat <<'USAGE'
Usage: test-environment-manifest.sh --target <project-root> [--write]

Detect project stack and emit a test-environment.yaml manifest. With --write,
the manifest is written to .gaia/config/test-environment.yaml at the target
root (canonical post-ADR-111) or config/test-environment.yaml (legacy pre-
ADR-111). copy-if-absent: preserves user-edited file.

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

# AF-2026-05-21-7/8 (CRITICAL SEQUENCING): the canonical-default guard MUST
# resolve MANIFEST_REL BEFORE the copy-if-absent short-circuit below — a
# pre-ADR-111 user with an existing config/test-environment.yaml would
# otherwise be silently shadowed by a fresh .gaia/config/ write.
if [ -d "${target}/config" ] && [ ! -d "${target}/.gaia/config" ]; then
  MANIFEST_REL="config/test-environment.yaml"
else
  MANIFEST_REL=".gaia/config/test-environment.yaml"
fi

# --write copy-if-absent: short-circuit if the manifest already exists
manifest_path="${target}/${MANIFEST_REL}"
if [ "${write_mode}" -eq 1 ] && [ -f "${manifest_path}" ]; then
  exit 0
fi

# Detect stack
detect_stack() {
  local detection stacks
  if [ -x "${DETECT_SIGNALS}" ]; then
    detection=$("${DETECT_SIGNALS}" --project-root "${target}" --format json 2>/dev/null || echo '{}')
    stacks=$(echo "${detection}" | jq -r '.stacks[]?.name // empty' 2>/dev/null | sort -u || echo "")

    while IFS= read -r s; do
      case "$s" in
        react|vue|angular|svelte|node|typescript) echo "node"; return 0 ;;
        python) echo "python"; return 0 ;;
        go) echo "go"; return 0 ;;
        java|kotlin) echo "java"; return 0 ;;
        flutter|dart) echo "flutter"; return 0 ;;
        rust) echo "rust"; return 0 ;;
      esac
    done <<< "${stacks}"
  fi

  # Bash/bats detection: presence of *.bats files when no package.json
  if [ ! -f "${target}/package.json" ]; then
    if find "${target}" -maxdepth 3 -name "*.bats" -print -quit 2>/dev/null | grep -q .; then
      echo "bash"
      return 0
    fi
  fi

  # AF-2026-05-29-2 / Test09 F-4 + F-15: config fallback. detect-signals.sh
  # only detects Python (and other stacks) from ROOT-level manifests
  # (pyproject.toml, requirements.txt, etc.). On projects where those files
  # live in a subdir (e.g. `core/pyproject.toml`) detect-signals returns []
  # and the manifest generator falls through to the `generic` template with a
  # nonsensical `make test` runner. When the operator has already declared the
  # stack via `/gaia-init` (project-config.yaml stacks[].language: python), we
  # should TRUST that declaration rather than mis-tag a real Python project as
  # `generic`. Read declared stacks from project-config and return the first
  # supported language. Honors both .gaia/config/ (canonical post-ADR-111) and
  # legacy config/ for in-migration projects.
  local _cfg=""
  if [ -f "${target}/.gaia/config/project-config.yaml" ]; then
    _cfg="${target}/.gaia/config/project-config.yaml"
  elif [ -f "${target}/config/project-config.yaml" ]; then
    _cfg="${target}/config/project-config.yaml"
  fi
  if [ -n "$_cfg" ] && command -v yq >/dev/null 2>&1; then
    local _declared
    _declared="$(yq eval '.stacks[]?.language // ""' "$_cfg" 2>/dev/null | grep -v '^$' | head -1 || true)"
    case "$_declared" in
      python)        echo "python";  return 0 ;;
      typescript|js|javascript|node) echo "node"; return 0 ;;
      go|golang)     echo "go";      return 0 ;;
      java|kotlin)   echo "java";    return 0 ;;
      dart|flutter)  echo "flutter"; return 0 ;;
      rust)          echo "rust";    return 0 ;;
    esac
  fi

  # AF-2026-05-29-2 / Test09 F-4 fallback #2: scan for *.py files in
  # subdirectories when no config declaration is available. Catches the common
  # case of a project under active brownfield onboarding (no config yet) that
  # has its Python sources in a subdir (`core/`, `src/`, etc.).
  if find "${target}" -maxdepth 4 -type f -name '*.py' -not -path '*/.gaia/*' -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/.venv/*' -print -quit 2>/dev/null | grep -q .; then
    echo "python"
    return 0
  fi

  echo ""
  return 0
}

# Emit stack-specific runners YAML body
runners_for_stack() {
  local stack="$1"
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
      # AF-2026-05-29-2 / Test09 F-7: use `python3 -m pytest` (the canonical
      # module-invocation form) instead of bare `pytest`. On many environments
      # (some CI runners, Python installations without `--user` shims) bare
      # `pytest` is not on PATH but `python3 -m pytest` works. Module form is
      # also the recommended invocation per the pytest project docs because it
      # adds the current directory to sys.path, matching the import semantics
      # users typically expect.
      cat <<'EOF'
runners:
  - name: unit
    command: "python3 -m pytest tests/unit"
    tier: 1
    test_pattern: "tests/unit/**/test_*.py"
    timeout_seconds: 120
  - name: integration
    command: "python3 -m pytest tests/integration"
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
      # No-stack fallback (FR-497 generic placeholder). Sentinel is added by the caller.
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
}

# Build the full manifest
stack=$(detect_stack)
runners_body=$(runners_for_stack "${stack}")

# Header — stack-detected manifests get a friendly comment; no-stack manifests
# get the canonical GAIA-MANIFEST-TEMPLATE sentinel so Layer 0 readiness fails
# until the user customizes (E17-S35 / FR-499).
if [ -n "${stack}" ]; then
  header="# test-environment.yaml — Test Execution Bridge Manifest
# Auto-generated by /gaia-bridge-enable (E17-S33 helper).
# Edit this file to fine-tune for your project.
#
# detected-stack: ${stack}
# Reference: architecture.md Section 10.20.5"
else
  header="# test-environment.yaml — Test Execution Bridge Manifest
# Auto-generated by /gaia-bridge-enable (E17-S33 helper).
# No stack detected — generic placeholder runners. CUSTOMIZE for your project.
#
# detected-stack: generic
# Reference: architecture.md Section 10.20.5

${SENTINEL_LINE}"
fi

manifest="${header}

version: 2

${runners_body}

primary_runner: unit

tiers:
  1:
    gates: [qa-tests, test-automate, test-review]
  2:
    gates: [review-perf]
  3:
    gates: []"

if [ "${write_mode}" -eq 1 ]; then
  mkdir -p "$(dirname "${manifest_path}")"
  printf '%s\n' "${manifest}" > "${manifest_path}"
  printf '%s: installed %s (detected-stack=%s)\n' "$SCRIPT_NAME" "${MANIFEST_REL}" "${stack:-generic}" >&2
  exit 0
fi

printf '%s\n' "${manifest}"
exit 0
