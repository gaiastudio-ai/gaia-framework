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
# E70-S11 — opt-in stacks[].path proposal/audit mode (default OFF; the legacy
# E71-S2 root-only detection path is byte-stable when this is unset).
STACKS_PATH_MODE=""
DRAFT_OUT=""
AUDIT_OUT=""
DECLARED_PATHS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --project-root)
      [ $# -ge 2 ] || { err "--project-root requires a path"; exit 1; }
      PROJECT_ROOT="$2"; shift 2 ;;
    --project-root=*)
      PROJECT_ROOT="${1#--project-root=}"; shift ;;
    --stacks-path-mode)
      [ $# -ge 2 ] || { err "--stacks-path-mode requires proposal|audit|auto"; exit 1; }
      STACKS_PATH_MODE="$2"; shift 2 ;;
    --stacks-path-mode=*)
      STACKS_PATH_MODE="${1#--stacks-path-mode=}"; shift ;;
    --draft-out)
      [ $# -ge 2 ] || { err "--draft-out requires a path"; exit 1; }
      DRAFT_OUT="$2"; shift 2 ;;
    --draft-out=*)
      DRAFT_OUT="${1#--draft-out=}"; shift ;;
    --audit-out)
      [ $# -ge 2 ] || { err "--audit-out requires a path"; exit 1; }
      AUDIT_OUT="$2"; shift 2 ;;
    --audit-out=*)
      AUDIT_OUT="${1#--audit-out=}"; shift ;;
    --declared-paths)
      [ $# -ge 2 ] || { err "--declared-paths requires a comma-list"; exit 1; }
      DECLARED_PATHS="$2"; shift 2 ;;
    --declared-paths=*)
      DECLARED_PATHS="${1#--declared-paths=}"; shift ;;
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
# E70-S11 — stacks[].path proposal / audit mode (opt-in; FR-548 / NFR-88 / ADR-126)
# ---------------------------------------------------------------------------
# When --stacks-path-mode is set, run the multi-stack path-partitioning logic
# and EXIT before the legacy E71-S2 root-only detection. This keeps the legacy
# invocation (no flag) byte-identical (zero-regression).
#
#   proposal : no stack declares `path` -> scan ecosystem manifests, propose a
#              stacks[].path mapping to --draft-out. Single-stack -> no draft.
#   audit    : `path` declared (--declared-paths) -> compare declared vs detected,
#              write disagreement to --audit-out; do NOT regenerate the draft.
#   auto     : audit when --declared-paths non-empty, else proposal.
#
# Nested manifests (a manifest with a strict-ancestor manifest) scope to the
# ancestor stack — `ignore_nested_manifests: true` default per E85-S14 / FR-546.
if [ -n "$STACKS_PATH_MODE" ]; then
  # Canonical ecosystem manifest filenames (explicit -name; not regex — faster).
  _MANIFESTS=(go.mod package.json pyproject.toml pom.xml build.gradle build.gradle.kts \
              Cargo.toml Gemfile composer.json Pipfile requirements.txt env.yml environment.yml)

  # Single cached find pass over all manifest names (NFR-88: one traversal).
  _find_args=()
  for m in "${_MANIFESTS[@]}"; do _find_args+=(-name "$m" -o); done
  unset '_find_args[${#_find_args[@]}-1]'   # drop trailing -o
  mapfile -t _hits < <(cd "$PROJECT_ROOT" && find . -type f \( "${_find_args[@]}" \) 2>/dev/null \
                         | sed 's#^\./##' | sort)

  # Candidate path = parent dir of each manifest ('.' for a root manifest).
  declare -A _cand=()
  for f in "${_hits[@]}"; do
    d="$(dirname "$f")"
    _cand["$d"]=1
  done

  # Nested-manifest scoping: drop a candidate dir if a STRICT-ANCESTOR dir is
  # also a candidate (the nested manifest is tooling inside the parent stack).
  declare -a _paths=()
  for d in "${!_cand[@]}"; do
    nested=0
    for a in "${!_cand[@]}"; do
      [ "$a" = "$d" ] && continue
      case "$d/" in "$a/"*) nested=1; break ;; esac
    done
    [ "$nested" -eq 0 ] && _paths+=("$d")
  done
  # Sort the partitions — but guard the empty case: a bare
  # `printf '%s\n' "${_paths[@]}"` on an empty array emits one blank line, which
  # mapfile would turn into a 1-element empty-string array and defeat the
  # zero-partition degenerate guard below (Val F1). Only re-sort when non-empty.
  if [ "${#_paths[@]}" -gt 0 ]; then
    mapfile -t _paths < <(printf '%s\n' "${_paths[@]}" | sort)
  fi

  # Mode resolution + ecosystem inference for the draft.
  _eco_of() {
    case "$1" in
      go.mod) printf 'go' ;;
      package.json) printf 'node' ;;
      pyproject.toml|Pipfile|requirements.txt) printf 'python' ;;
      pom.xml) printf 'java-maven' ;;
      build.gradle|build.gradle.kts) printf 'java-gradle' ;;
      Cargo.toml) printf 'rust' ;;
      Gemfile) printf 'ruby' ;;
      composer.json) printf 'php' ;;
      env.yml|environment.yml) printf 'conda' ;;
      *) printf 'unknown' ;;
    esac
  }
  # First manifest filename seen under a candidate path -> its ecosystem.
  _eco_for_path() {
    local p="$1" f
    for f in "${_hits[@]}"; do
      if [ "$(dirname "$f")" = "$p" ]; then _eco_of "$(basename "$f")"; return; fi
    done
    printf 'unknown'
  }

  _effective_mode="$STACKS_PATH_MODE"
  if [ "$_effective_mode" = "auto" ]; then
    if [ -n "$DECLARED_PATHS" ]; then _effective_mode="audit"; else _effective_mode="proposal"; fi
  fi

  if [ "$_effective_mode" = "audit" ]; then
    # Compare declared (CSV) vs detected; symmetric-difference count.
    # `grep -v '^$'` exits 1 when ALL lines are blank (empty declared/detected),
    # which would abort under `set -e` — `|| true` keeps an empty list as []
    # (Val F2: audit with empty --declared-paths must still emit a valid audit).
    declared_json="$(printf '%s' "$DECLARED_PATHS" | tr ',' '\n' | { grep -v '^$' || true; } | sort -u | jq -R . | jq -s .)"
    detected_json="$(printf '%s\n' "${_paths[@]}" | { grep -v '^$' || true; } | sort -u | jq -R . | jq -s .)"
    disagree="$(jq -n --argjson d "$declared_json" --argjson a "$detected_json" \
      '(($d - $a) + ($a - $d)) | length')"
    [ -n "$AUDIT_OUT" ] && mkdir -p "$(dirname "$AUDIT_OUT")"
    jq -n --argjson auto "$detected_json" --argjson decl "$declared_json" --argjson n "$disagree" \
      '{auto_detected_partitioning:$auto, declared_partitioning:$decl, disagreement_count:$n}' \
      > "${AUDIT_OUT:-/dev/stdout}"
    err "detect-signals: audit mode — disagreement_count=$disagree (declared not overridden; no draft regenerated)"
    printf '{"detect_signals_mode":"audit","disagreement_count":%s}\n' "$disagree"
    exit 0
  fi

  # proposal mode
  # Degenerate "nothing to propose" = zero partitions, OR a single partition that
  # IS the repo root '.' (a flat single-stack repo with only a root manifest —
  # there is no path structure to propose). A single NON-root partition (e.g. a
  # Go stack at services/api with a nested manifest scoped into it) IS proposed,
  # so AC4's nested-scoping case yields a 1-stack draft (proving no phantom stack).
  if [ "${#_paths[@]}" -eq 0 ] || { [ "${#_paths[@]}" -eq 1 ] && [ "${_paths[0]}" = "." ]; }; then
    err "detect-signals: nothing to propose (single root-level stack) — no draft written"
    printf '{"detect_signals_mode":"proposal","stacks_proposed":%s}\n' "${#_paths[@]}"
    exit 0
  fi
  [ -n "$DRAFT_OUT" ] || { err "--draft-out required in proposal mode"; exit 1; }
  mkdir -p "$(dirname "$DRAFT_OUT")"
  {
    printf '# project-config.draft.yaml — E70-S11 auto-detected stacks[].path proposal.\n'
    printf '# Advisory only. To accept: rename to project-config.yaml OR merge the\n'
    printf '# stacks[].path entries via /gaia-config-stack. Declared truth always wins.\n'
    printf 'stacks:\n'
    for p in "${_paths[@]}"; do
      eco="$(_eco_for_path "$p")"
      printf '  - name: %s\n    language: %s\n    path: %s\n' "$(basename "$p")" "$eco" "$p"
    done
  } > "$DRAFT_OUT"
  err "detect-signals: proposal written to $DRAFT_OUT (${#_paths[@]} stacks)"
  printf '{"detect_signals_mode":"proposal","stacks_proposed":%s}\n' "${#_paths[@]}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# _pkg_has_dep <package.json> <name>
_pkg_has_dep() {
  local f="$1" name="$2"
  [ -f "$f" ] || return 1
  grep -qE "\"${name}\"[[:space:]]*:" "$f"
}

# _pkg_dep_version <package.json> <name> — emits the resolved version string,
# stripping leading ^ ~ >= < etc. Empty if not found.
_pkg_dep_version() {
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

_add_warning() {
  local msg="$1"
  WARNINGS_JSON="$(jq --arg m "$msg" '. + [$m]' <<<"$WARNINGS_JSON")"
}

_push_stack() {
  # _push_stack <json_object>
  local obj="$1"
  STACKS_JSON="$(jq --argjson o "$obj" '. + [$o]' <<<"$STACKS_JSON")"
}

# Detect Node-family stack from package.json (emit at most one stack object).
_detect_node_family() {
  local pj="$PROJECT_ROOT/package.json"
  [ -f "$pj" ] || return 0

  local name="node" version=""
  if _pkg_has_dep "$pj" "react"; then
    name="react"
    version="$(_pkg_dep_version "$pj" "react" || true)"
  elif _pkg_has_dep "$pj" "vue"; then
    name="vue"
    version="$(_pkg_dep_version "$pj" "vue" || true)"
  elif _pkg_has_dep "$pj" "@angular/core"; then
    name="angular"
    version="$(_pkg_dep_version "$pj" "@angular/core" || true)"
  elif _pkg_has_dep "$pj" "svelte"; then
    name="svelte"
    version="$(_pkg_dep_version "$pj" "svelte" || true)"
  fi

  # Detect test runners — both manifest deps AND filesystem config files count.
  local runners=()
  local has_vitest=0 has_jest=0 has_mocha=0 has_karma=0
  if _pkg_has_dep "$pj" "vitest" \
    || [ -f "$PROJECT_ROOT/vitest.config.js" ] \
    || [ -f "$PROJECT_ROOT/vitest.config.ts" ] \
    || [ -f "$PROJECT_ROOT/vitest.config.mjs" ]; then
    has_vitest=1
  fi
  if _pkg_has_dep "$pj" "jest" \
    || [ -f "$PROJECT_ROOT/jest.config.js" ] \
    || [ -f "$PROJECT_ROOT/jest.config.ts" ] \
    || [ -f "$PROJECT_ROOT/jest.config.cjs" ]; then
    has_jest=1
  fi
  if _pkg_has_dep "$pj" "mocha" \
    || [ -f "$PROJECT_ROOT/.mocharc.js" ] \
    || [ -f "$PROJECT_ROOT/.mocharc.json" ]; then
    has_mocha=1
  fi
  if _pkg_has_dep "$pj" "karma" \
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
    _add_warning "Conflicting test_runner candidates detected (${runners[*]}) — confirm primary runner via /gaia-config-test."
  fi
  _push_stack "$obj"
}

_detect_python_stack() {
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
  _push_stack "$obj"
}

_detect_java_stack() {
  if [ -f "$PROJECT_ROOT/pom.xml" ] || [ -f "$PROJECT_ROOT/build.gradle" ] || [ -f "$PROJECT_ROOT/build.gradle.kts" ]; then
    _push_stack '{"name":"java","test_runner":"junit"}'
  fi
}

_detect_go_stack() {
  if [ -f "$PROJECT_ROOT/go.mod" ]; then
    _push_stack '{"name":"go","test_runner":"go-test"}'
  fi
}

_detect_rust_stack() {
  if [ -f "$PROJECT_ROOT/Cargo.toml" ]; then
    _push_stack '{"name":"rust","test_runner":"cargo-test"}'
  fi
}

_detect_ruby_stack() {
  if [ -f "$PROJECT_ROOT/Gemfile" ]; then
    local obj='{"name":"ruby"}'
    if grep -qE 'rspec' "$PROJECT_ROOT/Gemfile" 2>/dev/null || [ -f "$PROJECT_ROOT/.rspec" ]; then
      obj='{"name":"ruby","test_runner":"rspec"}'
    fi
    _push_stack "$obj"
  fi
}

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------

PLATFORMS_JSON='[]'
DEVICE_TARGETS_JSON='{}'

_push_platform() {
  local name="$1"
  # Avoid duplicates (idempotent on repeated detections).
  local exists
  exists="$(jq -r --arg n "$name" 'map(.name) | index($n)' <<<"$PLATFORMS_JSON")"
  if [ "$exists" = "null" ]; then
    PLATFORMS_JSON="$(jq --arg n "$name" '. + [{name: $n}]' <<<"$PLATFORMS_JSON")"
  fi
}

# E74-S11 — invoke the mobile-detection helper and union its findings into
# the platform set + seed device_targets.
_detect_mobile_signals() {
  local self_dir mobile
  self_dir="$(cd "$(dirname "$0")" && pwd)"
  if [ ! -x "$self_dir/mobile-detection.sh" ]; then
    return 0
  fi
  if ! mobile="$("$self_dir/mobile-detection.sh" --project-root "$PROJECT_ROOT" --format json 2>/dev/null)"; then
    return 0
  fi
  # Union platforms.
  local mobile_plats
  mobile_plats="$(jq -r '.platforms[]?' <<<"$mobile")"
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    _push_platform "$p"
  done <<< "$mobile_plats"
  # Merge device_targets (overwrite if absent — these are detection defaults).
  DEVICE_TARGETS_JSON="$(jq -c --argjson m "$(jq -c '.device_targets // {}' <<<"$mobile")" \
    '. * $m' <<<"$DEVICE_TARGETS_JSON")"
}

_detect_platforms() {
  if [ -f "$PROJECT_ROOT/Dockerfile" ] \
    || [ -f "$PROJECT_ROOT/docker-compose.yml" ] \
    || [ -f "$PROJECT_ROOT/docker-compose.yaml" ]; then
    _push_platform "docker"
  fi
  # Kubernetes signals: Helm Chart.yaml, k8s/ or kubernetes/ dir, or kubectl/helm
  # references in a Makefile.
  if [ -f "$PROJECT_ROOT/Chart.yaml" ] \
    || [ -d "$PROJECT_ROOT/k8s" ] \
    || [ -d "$PROJECT_ROOT/kubernetes" ]; then
    _push_platform "kubernetes"
  elif [ -f "$PROJECT_ROOT/Makefile" ] && grep -qE 'kubectl|helm' "$PROJECT_ROOT/Makefile" 2>/dev/null; then
    _push_platform "kubernetes"
  fi
  # Terraform: any *.tf file at any depth.
  if find "$PROJECT_ROOT" -maxdepth 4 -name '*.tf' -type f 2>/dev/null | grep -q .; then
    _push_platform "terraform"
  fi
  if [ -f "$PROJECT_ROOT/Pulumi.yaml" ] || [ -f "$PROJECT_ROOT/Pulumi.yml" ]; then
    _push_platform "pulumi"
  fi
  if [ -f "$PROJECT_ROOT/serverless.yml" ] || [ -f "$PROJECT_ROOT/serverless.yaml" ]; then
    _push_platform "serverless"
  fi
}

# ---------------------------------------------------------------------------
# CI platform detection (first match wins)
# ---------------------------------------------------------------------------

CI_PLATFORM_JSON='null'

_detect_ci_platform() {
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

_push_tool_provider() {
  local name="$1"
  local exists
  exists="$(jq -r --arg n "$name" 'map(.name) | index($n)' <<<"$TOOL_PROVIDERS_JSON")"
  if [ "$exists" = "null" ]; then
    TOOL_PROVIDERS_JSON="$(jq --arg n "$name" '. + [{name: $n}]' <<<"$TOOL_PROVIDERS_JSON")"
  fi
}

_detect_tool_providers() {
  if [ -f "$PROJECT_ROOT/sonar-project.properties" ]; then
    _push_tool_provider "sonarqube"
  fi
  for f in eslint.config.js eslint.config.mjs eslint.config.cjs eslint.config.ts \
           .eslintrc .eslintrc.js .eslintrc.json .eslintrc.yml .eslintrc.yaml; do
    if [ -f "$PROJECT_ROOT/$f" ]; then
      _push_tool_provider "eslint"
      break
    fi
  done
  for f in .prettierrc .prettierrc.json .prettierrc.js .prettierrc.yml prettier.config.js; do
    if [ -f "$PROJECT_ROOT/$f" ]; then
      _push_tool_provider "prettier"
      break
    fi
  done
  for f in .stylelintrc .stylelintrc.json .stylelintrc.js; do
    if [ -f "$PROJECT_ROOT/$f" ]; then
      _push_tool_provider "stylelint"
      break
    fi
  done
  for f in jest.config.js jest.config.ts jest.config.cjs; do
    if [ -f "$PROJECT_ROOT/$f" ]; then
      _push_tool_provider "jest"
      break
    fi
  done
  for f in vitest.config.js vitest.config.ts vitest.config.mjs; do
    if [ -f "$PROJECT_ROOT/$f" ]; then
      _push_tool_provider "vitest"
      break
    fi
  done
  if [ -f "$PROJECT_ROOT/pytest.ini" ]; then
    _push_tool_provider "pytest"
  fi
}

# ---------------------------------------------------------------------------
# Run all detectors
# ---------------------------------------------------------------------------

_detect_node_family
_detect_python_stack
_detect_java_stack
_detect_go_stack
_detect_rust_stack
_detect_ruby_stack
_detect_platforms
_detect_mobile_signals
_detect_ci_platform
_detect_tool_providers

# E77-S16 / FR-420 — plugin signal detection. Defers to plugin-detection.sh
# (3+ co-occurring signals classifies the project as claude-code-plugin).
PROJECT_KIND_JSON='null'
_detect_plugin_project() {
  local self_dir plugin
  self_dir="$(cd "$(dirname "$0")" && pwd)"
  if [ ! -x "$self_dir/plugin-detection.sh" ]; then
    return 0
  fi
  if ! plugin="$("$self_dir/plugin-detection.sh" --project-root "$PROJECT_ROOT" --format json 2>/dev/null)"; then
    return 0
  fi
  local is_plugin
  is_plugin="$(jq -r '.is_plugin // false' <<<"$plugin")"
  if [ "$is_plugin" = "true" ]; then
    PROJECT_KIND_JSON='"claude-code-plugin"'
  fi
}
_detect_plugin_project

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
  _add_warning "No signals detected — configure manually via /gaia-config-stack, /gaia-config-platform, /gaia-config-ci, /gaia-config-tools."
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
  --argjson device_targets "$DEVICE_TARGETS_JSON" \
  --argjson ci_platform "$CI_PLATFORM_JSON" \
  --argjson tool_providers "$TOOL_PROVIDERS_JSON" \
  --argjson project_kind "$PROJECT_KIND_JSON" \
  --argjson warnings "$WARNINGS_JSON" \
  --arg verdict "$VERDICT" \
  '{stacks: $stacks, platforms: $platforms, device_targets: $device_targets, ci_platform: $ci_platform, tool_providers: $tool_providers, project_kind: $project_kind, warnings: $warnings, verdict: $verdict}')"

# ---------------------------------------------------------------------------
# Optional merge into existing project-config.yaml (RFC 7396)
# ---------------------------------------------------------------------------

if [ -n "$MERGE_INTO" ] && [ -n "$OUTPUT" ]; then
  if [ ! -f "$MERGE_INTO" ]; then
    # AF-2026-05-30-2 / Test10 F-01 zero-config draft path:
    # When --merge-into points at a non-existent file, treat it as an empty
    # base (zero-config seed). Prior to this fix, brownfield Phase 1 on a
    # fresh repo HALTed here because setup.sh's greenfield-degrade seeded
    # the artifact tree but NOT a starter project-config.yaml — so
    # `--merge-into .gaia/config/project-config.yaml` errored even though
    # the greenfield-degrade was the canonical entry path.
    # Seeded base: minimal valid project-config.yaml scaffolding. The
    # downstream RFC 7396 merge then fills in stacks/platforms/ci_platform
    # from detection; the operator runs /gaia-init later to populate the
    # full questionnaire.
    err "merge-into target absent — seeding zero-config base at: $MERGE_INTO"
    mkdir -p "$(dirname "$MERGE_INTO")"
    cat > "$MERGE_INTO" <<'SEED'
# Auto-seeded by detect-signals.sh (AF-2026-05-30-2 / Test10 F-01 zero-config draft path).
# Minimal placeholder created because brownfield Phase 1 found no existing
# project-config.yaml. Detection-driven fields will be merged in below.
# Run /gaia-init to populate the full questionnaire when ready.
schema_version: "2.0.0"
config_phase: minimal
project_name: ""
project_kind: ""
SEED
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
if detection.get("device_targets"):
    fill_if_absent("device_targets", detection["device_targets"])

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
