#!/usr/bin/env bash
# detect-signals.sh — E71-S2 brownfield detection-driven config extension
#
# Scans a target project root for stack, platform, ci_platform, and
# tool-provider signals. Emits a structured JSON document with:
#   - stacks         (array)
#   - platforms      (array)
#   - ci_platform    (object | null)
#   - tool_providers (array)
#   - warnings       (array of advisory strings)
#   - verdict        (PASS | WARNING | CRITICAL)  — ADR-063
#
# When --merge-into and --output are provided, the detected sections are
# merged into the existing project-config.yaml using RFC 7396 JSON Merge
# Patch semantics — existing user values are preserved, only null/missing
# fields are filled. The merged YAML is written to --output.
#
# Story:   E71-S2
# Traces:  AF-2026-05-04-1, FR-RSV2-35, FR-RSV2-36, ADR-063, ADR-079, ADR-044
# Depends: E68-S1 (project-config.yaml schema extension).
#
# Usage:
#   detect-signals.sh --project-root <dir> [--format json]
#   detect-signals.sh --project-root <dir> \
#                     --merge-into <existing-config> \
#                     --output <draft-config> \
#                     [--schema <schema-path>] \
#                     [--format json]
#
# Exit codes:
#   0  success — detection complete; verdict in (PASS | WARNING).
#   1  generic / argument error.
#   2  CRITICAL — post-merge schema validation failed (when --schema given).
#
# Requires: jq, python3 (for YAML <-> JSON conversion + RFC 7396 merge).

set -euo pipefail
LC_ALL=C
export LC_ALL

prog="detect-signals.sh"
err() { printf '%s: %s\n' "$prog" "$*" >&2; }

PROJECT_ROOT=""
FORMAT="json"
MERGE_INTO=""
OUTPUT=""
SCHEMA=""

while [ $# -gt 0 ]; do
  case "$1" in
    --project-root)
      [ $# -ge 2 ] || { err "--project-root requires a path"; exit 1; }
      PROJECT_ROOT="$2"; shift 2 ;;
    --project-root=*)
      PROJECT_ROOT="${1#--project-root=}"; shift ;;
    --format)
      [ $# -ge 2 ] || { err "--format requires a value"; exit 1; }
      FORMAT="$2"; shift 2 ;;
    --format=*)
      FORMAT="${1#--format=}"; shift ;;
    --merge-into)
      [ $# -ge 2 ] || { err "--merge-into requires a path"; exit 1; }
      MERGE_INTO="$2"; shift 2 ;;
    --merge-into=*)
      MERGE_INTO="${1#--merge-into=}"; shift ;;
    --output)
      [ $# -ge 2 ] || { err "--output requires a path"; exit 1; }
      OUTPUT="$2"; shift 2 ;;
    --output=*)
      OUTPUT="${1#--output=}"; shift ;;
    --schema)
      [ $# -ge 2 ] || { err "--schema requires a path"; exit 1; }
      SCHEMA="$2"; shift 2 ;;
    --schema=*)
      SCHEMA="${1#--schema=}"; shift ;;
    -h|--help)
      sed -n '1,40p' "$0" >&2; exit 0 ;;
    *)
      err "unknown argument: $1"; exit 1 ;;
  esac
done

if [ -z "$PROJECT_ROOT" ]; then
  err "missing required --project-root <dir>"
  exit 1
fi
if [ ! -d "$PROJECT_ROOT" ]; then
  err "project root not a directory: $PROJECT_ROOT"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  err "jq is required but not found in PATH"
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  err "python3 is required but not found in PATH"
  exit 1
fi

# Make absolute for predictable behavior even after a future cd.
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# pkg_has_dep <package.json> <name>
pkg_has_dep() {
  local f="$1" name="$2"
  [ -f "$f" ] || return 1
  grep -qE "\"${name}\"[[:space:]]*:" "$f"
}

# pkg_dep_version <package.json> <name> — emits the resolved version string,
# stripping leading ^ ~ >= < etc. Empty if not found.
pkg_dep_version() {
  local f="$1" name="$2"
  [ -f "$f" ] || return 0
  # Capture the first quoted value following "name":
  python3 - "$f" "$name" <<'PY'
import json, sys
path, name = sys.argv[1], sys.argv[2]
try:
    with open(path) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
for section in ("dependencies", "devDependencies", "peerDependencies"):
    block = data.get(section) or {}
    if name in block:
        v = str(block[name])
        # Strip leading semver range tokens.
        for tok in ("^", "~", ">=", "<=", ">", "<", "="):
            if v.startswith(tok):
                v = v[len(tok):]
                break
        print(v.strip())
        sys.exit(0)
PY
}

# ---------------------------------------------------------------------------
# Stack detection
# ---------------------------------------------------------------------------

STACKS_JSON='[]'
WARNINGS_JSON='[]'

add_warning() {
  local msg="$1"
  WARNINGS_JSON="$(jq --arg m "$msg" '. + [$m]' <<<"$WARNINGS_JSON")"
}

push_stack() {
  # push_stack <json_object>
  local obj="$1"
  STACKS_JSON="$(jq --argjson o "$obj" '. + [$o]' <<<"$STACKS_JSON")"
}

# Detect Node-family stack from package.json (emit at most one stack object).
detect_node_family() {
  local pj="$PROJECT_ROOT/package.json"
  [ -f "$pj" ] || return 0

  local name="node" version=""
  if pkg_has_dep "$pj" "react"; then
    name="react"
    version="$(pkg_dep_version "$pj" "react" || true)"
  elif pkg_has_dep "$pj" "vue"; then
    name="vue"
    version="$(pkg_dep_version "$pj" "vue" || true)"
  elif pkg_has_dep "$pj" "@angular/core"; then
    name="angular"
    version="$(pkg_dep_version "$pj" "@angular/core" || true)"
  elif pkg_has_dep "$pj" "svelte"; then
    name="svelte"
    version="$(pkg_dep_version "$pj" "svelte" || true)"
  fi

  # Detect test runners — both manifest deps AND filesystem config files count.
  local runners=()
  local has_vitest=0 has_jest=0 has_mocha=0 has_karma=0
  if pkg_has_dep "$pj" "vitest" \
    || [ -f "$PROJECT_ROOT/vitest.config.js" ] \
    || [ -f "$PROJECT_ROOT/vitest.config.ts" ] \
    || [ -f "$PROJECT_ROOT/vitest.config.mjs" ]; then
    has_vitest=1
  fi
  if pkg_has_dep "$pj" "jest" \
    || [ -f "$PROJECT_ROOT/jest.config.js" ] \
    || [ -f "$PROJECT_ROOT/jest.config.ts" ] \
    || [ -f "$PROJECT_ROOT/jest.config.cjs" ]; then
    has_jest=1
  fi
  if pkg_has_dep "$pj" "mocha" \
    || [ -f "$PROJECT_ROOT/.mocharc.js" ] \
    || [ -f "$PROJECT_ROOT/.mocharc.json" ]; then
    has_mocha=1
  fi
  if pkg_has_dep "$pj" "karma" \
    || [ -f "$PROJECT_ROOT/karma.conf.js" ]; then
    has_karma=1
  fi
  [ "$has_vitest" -eq 1 ] && runners+=("vitest")
  [ "$has_jest" -eq 1 ] && runners+=("jest")
  [ "$has_mocha" -eq 1 ] && runners+=("mocha")
  [ "$has_karma" -eq 1 ] && runners+=("karma")

  # Build the stack object.
  local obj
  if [ "${#runners[@]}" -eq 0 ]; then
    obj="$(jq -nc --arg n "$name" --arg v "$version" \
      '{name: $n} + (if $v == "" then {} else {version: $v} end)')"
  elif [ "${#runners[@]}" -eq 1 ]; then
    obj="$(jq -nc --arg n "$name" --arg v "$version" --arg r "${runners[0]}" \
      '{name: $n} + (if $v == "" then {} else {version: $v} end) + {test_runner: $r}')"
  else
    # Multiple runners — emit as array + WARNING advisory.
    local runners_json
    runners_json="$(printf '%s\n' "${runners[@]}" | jq -R . | jq -s .)"
    obj="$(jq -nc --arg n "$name" --arg v "$version" --argjson r "$runners_json" \
      '{name: $n} + (if $v == "" then {} else {version: $v} end) + {test_runner: $r}')"
    add_warning "Conflicting test_runner candidates detected (${runners[*]}) — confirm primary runner via /gaia-config-test."
  fi
  push_stack "$obj"
}

detect_python_stack() {
  local found=0 framework="" tr=""
  if [ -f "$PROJECT_ROOT/pyproject.toml" ]; then
    found=1
    grep -qE 'fastapi'  "$PROJECT_ROOT/pyproject.toml" 2>/dev/null && framework="fastapi"
    grep -qE 'flask'    "$PROJECT_ROOT/pyproject.toml" 2>/dev/null && framework="${framework:-flask}"
    grep -qE 'django'   "$PROJECT_ROOT/pyproject.toml" 2>/dev/null && framework="${framework:-django}"
    grep -qE 'pytest'   "$PROJECT_ROOT/pyproject.toml" 2>/dev/null && tr="pytest"
  elif [ -f "$PROJECT_ROOT/requirements.txt" ]; then
    found=1
    grep -qiE '^fastapi' "$PROJECT_ROOT/requirements.txt" 2>/dev/null && framework="fastapi"
    grep -qiE '^flask'   "$PROJECT_ROOT/requirements.txt" 2>/dev/null && framework="${framework:-flask}"
    grep -qiE '^django'  "$PROJECT_ROOT/requirements.txt" 2>/dev/null && framework="${framework:-django}"
    grep -qiE '^pytest'  "$PROJECT_ROOT/requirements.txt" 2>/dev/null && tr="pytest"
  elif [ -f "$PROJECT_ROOT/Pipfile" ]; then
    found=1
  fi
  [ "$found" -eq 0 ] && return 0
  [ -f "$PROJECT_ROOT/pytest.ini" ] && tr="pytest"
  local obj
  obj="$(jq -nc --arg fw "$framework" --arg tr "$tr" \
    '{name: "python"} + (if $fw == "" then {} else {framework: $fw} end) + (if $tr == "" then {} else {test_runner: $tr} end)')"
  push_stack "$obj"
}

detect_java_stack() {
  if [ -f "$PROJECT_ROOT/pom.xml" ] || [ -f "$PROJECT_ROOT/build.gradle" ] || [ -f "$PROJECT_ROOT/build.gradle.kts" ]; then
    push_stack '{"name":"java","test_runner":"junit"}'
  fi
}

detect_go_stack() {
  if [ -f "$PROJECT_ROOT/go.mod" ]; then
    push_stack '{"name":"go","test_runner":"go-test"}'
  fi
}

detect_rust_stack() {
  if [ -f "$PROJECT_ROOT/Cargo.toml" ]; then
    push_stack '{"name":"rust","test_runner":"cargo-test"}'
  fi
}

detect_ruby_stack() {
  if [ -f "$PROJECT_ROOT/Gemfile" ]; then
    local obj='{"name":"ruby"}'
    if grep -qE 'rspec' "$PROJECT_ROOT/Gemfile" 2>/dev/null || [ -f "$PROJECT_ROOT/.rspec" ]; then
      obj='{"name":"ruby","test_runner":"rspec"}'
    fi
    push_stack "$obj"
  fi
}

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------

PLATFORMS_JSON='[]'

push_platform() {
  local name="$1"
  # Avoid duplicates (idempotent on repeated detections).
  local exists
  exists="$(jq -r --arg n "$name" 'map(.name) | index($n)' <<<"$PLATFORMS_JSON")"
  if [ "$exists" = "null" ]; then
    PLATFORMS_JSON="$(jq --arg n "$name" '. + [{name: $n}]' <<<"$PLATFORMS_JSON")"
  fi
}

detect_platforms() {
  if [ -f "$PROJECT_ROOT/Dockerfile" ] \
    || [ -f "$PROJECT_ROOT/docker-compose.yml" ] \
    || [ -f "$PROJECT_ROOT/docker-compose.yaml" ]; then
    push_platform "docker"
  fi
  # Kubernetes signals: Helm Chart.yaml, k8s/ or kubernetes/ dir, or kubectl/helm
  # references in a Makefile.
  if [ -f "$PROJECT_ROOT/Chart.yaml" ] \
    || [ -d "$PROJECT_ROOT/k8s" ] \
    || [ -d "$PROJECT_ROOT/kubernetes" ]; then
    push_platform "kubernetes"
  elif [ -f "$PROJECT_ROOT/Makefile" ] && grep -qE 'kubectl|helm' "$PROJECT_ROOT/Makefile" 2>/dev/null; then
    push_platform "kubernetes"
  fi
  # Terraform: any *.tf file at any depth.
  if find "$PROJECT_ROOT" -maxdepth 4 -name '*.tf' -type f 2>/dev/null | grep -q .; then
    push_platform "terraform"
  fi
  if [ -f "$PROJECT_ROOT/Pulumi.yaml" ] || [ -f "$PROJECT_ROOT/Pulumi.yml" ]; then
    push_platform "pulumi"
  fi
  if [ -f "$PROJECT_ROOT/serverless.yml" ] || [ -f "$PROJECT_ROOT/serverless.yaml" ]; then
    push_platform "serverless"
  fi
}

# ---------------------------------------------------------------------------
# CI platform detection (first match wins)
# ---------------------------------------------------------------------------

CI_PLATFORM_JSON='null'

detect_ci_platform() {
  if [ -d "$PROJECT_ROOT/.github/workflows" ] \
    && find "$PROJECT_ROOT/.github/workflows" -maxdepth 1 -name '*.yml' -o -name '*.yaml' 2>/dev/null | grep -q .; then
    CI_PLATFORM_JSON='{"provider":"github-actions","config_path":".github/workflows/"}'
    return
  fi
  if [ -d "$PROJECT_ROOT/.github/workflows" ]; then
    # Workflows dir present but empty — still acceptable as github-actions signal.
    CI_PLATFORM_JSON='{"provider":"github-actions","config_path":".github/workflows/"}'
    return
  fi
  if [ -f "$PROJECT_ROOT/.gitlab-ci.yml" ]; then
    CI_PLATFORM_JSON='{"provider":"gitlab-ci","config_path":".gitlab-ci.yml"}'
    return
  fi
  if [ -f "$PROJECT_ROOT/.circleci/config.yml" ]; then
    CI_PLATFORM_JSON='{"provider":"circleci","config_path":".circleci/config.yml"}'
    return
  fi
  if [ -f "$PROJECT_ROOT/Jenkinsfile" ]; then
    CI_PLATFORM_JSON='{"provider":"jenkins","config_path":"Jenkinsfile"}'
    return
  fi
  if [ -f "$PROJECT_ROOT/azure-pipelines.yml" ]; then
    CI_PLATFORM_JSON='{"provider":"azure-pipelines","config_path":"azure-pipelines.yml"}'
    return
  fi
  if [ -f "$PROJECT_ROOT/bitbucket-pipelines.yml" ]; then
    CI_PLATFORM_JSON='{"provider":"bitbucket-pipelines","config_path":"bitbucket-pipelines.yml"}'
    return
  fi
}

# ---------------------------------------------------------------------------
# Tool-provider detection
# ---------------------------------------------------------------------------

TOOL_PROVIDERS_JSON='[]'

push_tool_provider() {
  local name="$1"
  local exists
  exists="$(jq -r --arg n "$name" 'map(.name) | index($n)' <<<"$TOOL_PROVIDERS_JSON")"
  if [ "$exists" = "null" ]; then
    TOOL_PROVIDERS_JSON="$(jq --arg n "$name" '. + [{name: $n}]' <<<"$TOOL_PROVIDERS_JSON")"
  fi
}

detect_tool_providers() {
  if [ -f "$PROJECT_ROOT/sonar-project.properties" ]; then
    push_tool_provider "sonarqube"
  fi
  for f in eslint.config.js eslint.config.mjs eslint.config.cjs eslint.config.ts \
           .eslintrc .eslintrc.js .eslintrc.json .eslintrc.yml .eslintrc.yaml; do
    if [ -f "$PROJECT_ROOT/$f" ]; then
      push_tool_provider "eslint"
      break
    fi
  done
  for f in .prettierrc .prettierrc.json .prettierrc.js .prettierrc.yml prettier.config.js; do
    if [ -f "$PROJECT_ROOT/$f" ]; then
      push_tool_provider "prettier"
      break
    fi
  done
  for f in .stylelintrc .stylelintrc.json .stylelintrc.js; do
    if [ -f "$PROJECT_ROOT/$f" ]; then
      push_tool_provider "stylelint"
      break
    fi
  done
  for f in jest.config.js jest.config.ts jest.config.cjs; do
    if [ -f "$PROJECT_ROOT/$f" ]; then
      push_tool_provider "jest"
      break
    fi
  done
  for f in vitest.config.js vitest.config.ts vitest.config.mjs; do
    if [ -f "$PROJECT_ROOT/$f" ]; then
      push_tool_provider "vitest"
      break
    fi
  done
  if [ -f "$PROJECT_ROOT/pytest.ini" ]; then
    push_tool_provider "pytest"
  fi
}

# ---------------------------------------------------------------------------
# Run all detectors
# ---------------------------------------------------------------------------

detect_node_family
detect_python_stack
detect_java_stack
detect_go_stack
detect_rust_stack
detect_ruby_stack
detect_platforms
detect_ci_platform
detect_tool_providers

# ---------------------------------------------------------------------------
# Verdict + advisory for empty project
# ---------------------------------------------------------------------------

stack_count="$(jq 'length' <<<"$STACKS_JSON")"
plat_count="$(jq 'length' <<<"$PLATFORMS_JSON")"
tp_count="$(jq 'length' <<<"$TOOL_PROVIDERS_JSON")"
has_ci="0"
[ "$CI_PLATFORM_JSON" != "null" ] && has_ci="1"

total_signals=$((stack_count + plat_count + tp_count + has_ci))
if [ "$total_signals" -eq 0 ]; then
  add_warning "No signals detected — configure manually via /gaia-config-stack, /gaia-config-platform, /gaia-config-ci, /gaia-config-tools."
fi

# Verdict computation: WARNING if any advisory is present, else PASS.
warn_count="$(jq 'length' <<<"$WARNINGS_JSON")"
if [ "$warn_count" -gt 0 ]; then
  VERDICT="WARNING"
else
  VERDICT="PASS"
fi

# ---------------------------------------------------------------------------
# Build the detection JSON
# ---------------------------------------------------------------------------

DETECTION_JSON="$(jq -nc \
  --argjson stacks "$STACKS_JSON" \
  --argjson platforms "$PLATFORMS_JSON" \
  --argjson ci_platform "$CI_PLATFORM_JSON" \
  --argjson tool_providers "$TOOL_PROVIDERS_JSON" \
  --argjson warnings "$WARNINGS_JSON" \
  --arg verdict "$VERDICT" \
  '{stacks: $stacks, platforms: $platforms, ci_platform: $ci_platform, tool_providers: $tool_providers, warnings: $warnings, verdict: $verdict}')"

# ---------------------------------------------------------------------------
# Optional merge into existing project-config.yaml (RFC 7396)
# ---------------------------------------------------------------------------

if [ -n "$MERGE_INTO" ] && [ -n "$OUTPUT" ]; then
  if [ ! -f "$MERGE_INTO" ]; then
    err "merge-into file not found: $MERGE_INTO"
    exit 1
  fi
  python3 - "$MERGE_INTO" "$OUTPUT" "$DETECTION_JSON" <<'PY'
import json, sys, os

path_in, path_out, detection_str = sys.argv[1], sys.argv[2], sys.argv[3]

# YAML I/O: prefer PyYAML; fall back to a tiny pass-through if unavailable.
try:
    import yaml
except ImportError:
    sys.stderr.write("detect-signals.sh: PyYAML required for --merge-into; install with `pip install pyyaml`\n")
    sys.exit(1)

with open(path_in) as fh:
    existing = yaml.safe_load(fh) or {}
detection = json.loads(detection_str)

# Build the JSON-merge-patch payload from detection output. RFC 7396 semantics:
# we only fill in fields that are absent or null in `existing`. We never
# overwrite a non-null user value.
patch = {}

def fill_if_absent(key, value):
    if key not in existing or existing.get(key) is None:
        patch[key] = value

# stacks: list — user values preserved entirely if present.
if detection.get("stacks"):
    fill_if_absent("stacks", detection["stacks"])
if detection.get("platforms"):
    fill_if_absent("platforms", detection["platforms"])
if detection.get("ci_platform") is not None:
    fill_if_absent("ci_platform", detection["ci_platform"])
if detection.get("tool_providers"):
    fill_if_absent("tool_providers", detection["tool_providers"])

# Apply RFC 7396 merge: scalar/list replace, dict recursive.
def merge_patch(target, patch):
    if not isinstance(patch, dict):
        return patch
    if not isinstance(target, dict):
        target = {}
    for k, v in patch.items():
        if v is None:
            target.pop(k, None)
        elif isinstance(v, dict):
            target[k] = merge_patch(target.get(k), v)
        else:
            target[k] = v
    return target

merged = merge_patch(existing, patch)

with open(path_out, "w") as fh:
    yaml.safe_dump(merged, fh, default_flow_style=False, sort_keys=False)
PY
fi

# ---------------------------------------------------------------------------
# Optional schema validation of the merged draft
# ---------------------------------------------------------------------------

if [ -n "$SCHEMA" ] && [ -n "$OUTPUT" ] && [ -f "$OUTPUT" ]; then
  # Use resolve-config.sh as the validator (its --shared + --schema entry path
  # rejects unknown keys with exit code 2 per E28-S18 / ADR-044).
  self_dir="$(cd "$(dirname "$0")" && pwd)"
  if "$self_dir/resolve-config.sh" --shared "$OUTPUT" --schema "$SCHEMA" >/dev/null 2>&1; then
    : # validation passed
  else
    # Validation failure is CRITICAL per ADR-063.
    DETECTION_JSON="$(jq -c '.verdict = "CRITICAL"' <<<"$DETECTION_JSON")"
    case "$FORMAT" in
      json) jq . <<<"$DETECTION_JSON" ;;
      *)    jq -c . <<<"$DETECTION_JSON" ;;
    esac
    err "post-merge schema validation failed for $OUTPUT (verdict=CRITICAL)"
    exit 2
  fi
fi

# ---------------------------------------------------------------------------
# Emit the detection JSON on stdout
# ---------------------------------------------------------------------------

case "$FORMAT" in
  json) jq . <<<"$DETECTION_JSON" ;;
  *)    err "unsupported --format '$FORMAT' (expected json)"; exit 1 ;;
esac
