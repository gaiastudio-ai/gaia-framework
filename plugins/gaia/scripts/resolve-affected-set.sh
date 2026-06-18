#!/usr/bin/env bash
# resolve-affected-set.sh — three-tier fallback resolver for affected-set
#
# Resolves which components are affected by a change, using a deterministic
# fallback chain:
#
#   1. CI artifact file (primary)   — the affected-set JSON uploaded by the
#      selective-test pipeline's plan job.
#   2. Commit trailer (secondary)   — an "Affected-Set:" or
#      "Affected-Components:" trailer on the HEAD commit.
#   3. Full-deploy sentinel (safety net) — deploy everything. NEVER empty.
#
# The resolver emits a JSON object on stdout naming the resolving channel:
#   {"stacks":["api","web"],"channel":"ci-artifact"}
#   {"stacks":["worker"],"channel":"commit-trailer"}
#   {"stacks":["*"],"channel":"full-deploy"}
#
# When --config is given and the full-deploy path is taken, the resolver
# resolves all stack names from the config instead of the wildcard sentinel.
#
# Usage:
#   resolve-affected-set.sh [--artifact <path>] [--git-dir <path>] [--config <path>]
#   resolve-affected-set.sh --help
#
# Exit codes:
#   0 — success (always resolves to something; never empty)
#   1 — caller error (invalid flags)

set -euo pipefail
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# Internal helpers (underscore prefix — exempt from public-fn coverage gate)
# ---------------------------------------------------------------------------
_log_info() {
  printf '[resolve-affected-set] INFO: %s\n' "$*" >&2
}

_log_warn() {
  printf '[resolve-affected-set] WARN: %s\n' "$*" >&2
}

# ---------------------------------------------------------------------------
# usage — print help to stdout and exit 0
# ---------------------------------------------------------------------------
usage() {
  cat <<'USAGE'
Usage:
  resolve-affected-set.sh [--artifact <path>] [--git-dir <path>] [--config <path>]

Options:
  --artifact PATH    Path to the CI-artifact affected-set JSON file.
  --git-dir PATH     Path to the git repository for commit-trailer parsing.
  --config PATH      Path to project-config.yaml (enables named-stack
                     full-deploy instead of the wildcard sentinel).
  --help             Print this message and exit 0.

Output:
  JSON object on stdout: {"stacks":[...],"channel":"<source>"}
  Channel is one of: ci-artifact, commit-trailer, full-deploy.

Exit codes:
  0  Success (always resolves; never empty).
  1  Caller error.
USAGE
}

# ---------------------------------------------------------------------------
# parse_args — populate _ARTIFACT_PATH, _GIT_DIR, _CONFIG
# ---------------------------------------------------------------------------
parse_args() {
  _ARTIFACT_PATH=""
  _GIT_DIR=""
  _CONFIG=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --artifact)  _ARTIFACT_PATH="$2"; shift 2 ;;
      --git-dir)   _GIT_DIR="$2"; shift 2 ;;
      --config)    _CONFIG="$2"; shift 2 ;;
      --help|-h)   usage; exit 0 ;;
      *)
        printf 'resolve-affected-set.sh: unknown option: %s\n' "$1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# _emit_json CHANNEL STACKS_JSON — print the resolver output object.
#
# STACKS_JSON is a bare JSON array string, e.g. '["api","web"]'.
# ---------------------------------------------------------------------------
_emit_json() {
  local channel="$1"
  local stacks_json="$2"
  printf '{"stacks":%s,"channel":"%s"}\n' "$stacks_json" "$channel"
}

# ---------------------------------------------------------------------------
# _validate_artifact_json FILE — check that the file is valid affected-set
# JSON with a "stacks" key containing an array.
#
# Returns 0 if valid, 1 if not.
# On success, prints the stacks JSON array to stdout.
# ---------------------------------------------------------------------------
_validate_artifact_json() {
  local file="$1"
  python3 -c "
import sys, json
try:
    data = json.load(open(sys.argv[1]))
    stacks = data.get('stacks')
    if not isinstance(stacks, list):
        sys.exit(1)
    # Validate each entry is a string
    for s in stacks:
        if not isinstance(s, str):
            sys.exit(1)
    print(json.dumps(stacks, separators=(',', ':')))
except (json.JSONDecodeError, KeyError, TypeError, ValueError):
    sys.exit(1)
" "$file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# resolve_from_artifact — attempt to read from the CI artifact file.
#
# Args: $1 — path to the artifact file.
# Prints the stacks JSON array on stdout if successful.
# Returns 0 on success, 1 on failure (file missing, malformed, etc.).
# ---------------------------------------------------------------------------
resolve_from_artifact() {
  local artifact_path="$1"

  if [[ -z "$artifact_path" ]]; then
    return 1
  fi

  if [[ ! -f "$artifact_path" ]]; then
    _log_info "CI artifact not found at $artifact_path — falling through"
    return 1
  fi

  local stacks_json
  stacks_json="$(_validate_artifact_json "$artifact_path")" || {
    _log_warn "CI artifact at $artifact_path is malformed — falling through"
    return 1
  }

  printf '%s' "$stacks_json"
  return 0
}

# ---------------------------------------------------------------------------
# resolve_from_trailer — parse an affected-set from the HEAD commit trailer.
#
# Looks for either "Affected-Set:" or "Affected-Components:" trailers.
# Args: $1 — path to the git repository (optional; uses cwd if empty).
# Prints the stacks JSON array on stdout if successful.
# Returns 0 on success, 1 on failure (no trailer, not a git repo, etc.).
# ---------------------------------------------------------------------------
resolve_from_trailer() {
  local git_dir="${1:-}"

  local -a git_cmd=(git)
  if [[ -n "$git_dir" ]]; then
    git_cmd+=(-C "$git_dir")
  fi

  # Check if we're in a git repo
  if ! "${git_cmd[@]}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    _log_info "not in a git repo — skipping commit-trailer channel"
    return 1
  fi

  # Get the full commit message of HEAD
  local commit_msg
  commit_msg="$("${git_cmd[@]}" log -1 --format='%B' 2>/dev/null)" || return 1

  # Look for Affected-Set or Affected-Components trailer
  local trailer_value=""
  local line
  while IFS= read -r line; do
    case "$line" in
      Affected-Set:*)
        trailer_value="${line#Affected-Set:}"
        trailer_value="${trailer_value#"${trailer_value%%[![:space:]]*}"}"
        break
        ;;
      Affected-Components:*)
        trailer_value="${line#Affected-Components:}"
        trailer_value="${trailer_value#"${trailer_value%%[![:space:]]*}"}"
        break
        ;;
    esac
  done <<< "$commit_msg"

  if [[ -z "$trailer_value" ]]; then
    _log_info "no affected-set trailer found on HEAD commit — falling through"
    return 1
  fi

  # Validate the trailer value is a JSON array of strings
  local stacks_json
  stacks_json="$(python3 -c "
import sys, json
try:
    data = json.loads(sys.argv[1])
    if not isinstance(data, list):
        sys.exit(1)
    for s in data:
        if not isinstance(s, str):
            sys.exit(1)
    print(json.dumps(data, separators=(',', ':')))
except (json.JSONDecodeError, TypeError, ValueError):
    sys.exit(1)
" "$trailer_value" 2>/dev/null)" || {
    _log_warn "commit trailer value is not a valid JSON array — falling through"
    return 1
  }

  printf '%s' "$stacks_json"
  return 0
}

# ---------------------------------------------------------------------------
# _parse_stack_names CONFIG — extract stacks[].name from project-config.yaml.
#
# Emits a JSON array of stack names on stdout.
# Uses POSIX awk only (no gensub, no 3-arg match).
# ---------------------------------------------------------------------------
_parse_stack_names() {
  local config="$1"
  local -a names=()
  local name

  while IFS= read -r name; do
    [[ -n "$name" ]] && names+=("$name")
  done < <(awk '
  BEGIN { in_stacks = 0 }
  /^stacks:/ { in_stacks = 1; next }
  in_stacks && /^[a-zA-Z_]/ { in_stacks = 0; next }
  in_stacks && /^[[:space:]]+-[[:space:]]+name:/ {
    val = $0
    sub(/.*name:[[:space:]]*/, "", val)
    gsub(/^[[:space:]]+/, "", val)
    gsub(/[[:space:]]+$/, "", val)
    gsub(/^"/, "", val); gsub(/"$/, "", val)
    gsub(/^'"'"'/, "", val); gsub(/'"'"'$/, "", val)
    if (val != "") print val
  }
  ' "$config")

  # Build JSON array
  local json="["
  local first=true
  for name in "${names[@]}"; do
    $first || json+=","
    json+="\"$name\""
    first=false
  done
  json+="]"
  printf '%s' "$json"
}

# ---------------------------------------------------------------------------
# resolve_full_deploy — emit the full-deploy sentinel.
#
# When --config is provided and exists, resolves all stack names.
# Otherwise, emits ["*"] as the wildcard sentinel.
# Args: $1 — path to project-config.yaml (optional).
# Always succeeds. Prints the stacks JSON array on stdout.
# ---------------------------------------------------------------------------
resolve_full_deploy() {
  local config="${1:-}"

  if [[ -n "$config" ]] && [[ -f "$config" ]]; then
    local names_json
    names_json="$(_parse_stack_names "$config")"
    if [[ -n "$names_json" ]] && [[ "$names_json" != "[]" ]]; then
      printf '%s' "$names_json"
      return 0
    fi
  fi

  # Wildcard sentinel — consumer must expand to all stacks
  printf '["*"]'
}

# ---------------------------------------------------------------------------
# resolve_affected_set — run the three-tier fallback chain.
#
# Uses the module-level _ARTIFACT_PATH, _GIT_DIR, _CONFIG variables
# populated by parse_args.
# Prints the final JSON object (with channel) on stdout.
# ---------------------------------------------------------------------------
resolve_affected_set() {
  local stacks_json

  # Tier 1: CI artifact (primary)
  if stacks_json="$(resolve_from_artifact "${_ARTIFACT_PATH:-}")"; then
    _log_info "resolved via CI artifact"
    _emit_json "ci-artifact" "$stacks_json"
    return 0
  fi

  # Tier 2: Commit trailer (secondary)
  if stacks_json="$(resolve_from_trailer "${_GIT_DIR:-}")"; then
    _log_info "resolved via commit trailer"
    _emit_json "commit-trailer" "$stacks_json"
    return 0
  fi

  # Tier 3: Full deploy (safety net — never empty)
  _log_info "no selective source available — falling back to full deploy"
  stacks_json="$(resolve_full_deploy "${_CONFIG:-}")"
  _emit_json "full-deploy" "$stacks_json"
}

# ---------------------------------------------------------------------------
# main — entry point
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  resolve_affected_set
}

# Main-guard: sourcing must expose public functions without side-effects.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
