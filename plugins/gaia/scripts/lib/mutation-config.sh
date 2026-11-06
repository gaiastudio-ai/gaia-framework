#!/usr/bin/env bash
# mutation-config.sh — shared reads for mutation testing: thresholds from the
# project config, the evidence path, a story's priority and its File List.
#
# Sourceable, sets no shell options, keeps no state. Every producer and
# consumer goes through these functions so they cannot disagree on where the
# evidence lives or on what "thresholds configured" means.
#
# Provides:
#   mutation_read_thresholds <config>   compact JSON object on stdout, nothing
#                                       when the key is absent; `{}` counts as
#                                       present; non-zero with a message naming
#                                       yq when the key cannot be read
#   mutation_config_path                path of the project config, if any
#   mutation_evidence_path <story_key>  path of the story's mutation evidence
#   mutation_story_priority <story>     P0..P3 from the story frontmatter
#   mutation_story_file_list <story>    one path per line from the File List
#
# bash 3.2 compatible.

_MC_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null && pwd)"

mutation_read_thresholds() {
  local config="$1" raw
  [ -f "$config" ] || return 0
  # awk rather than two greps: under pipefail a `grep -q` closing the pipe
  # early can read as "no match" and quietly turn the feature off.
  awk '!/^[[:space:]]*#/ && /mutation_thresholds/ { found = 1 } END { exit !found }' "$config" || return 0
  if ! command -v yq >/dev/null 2>&1; then
    printf 'error: yq is required to read test_execution.mutation_thresholds from %s but is not installed\n' "$config" >&2
    return 1
  fi
  if ! raw="$(yq -o=json -I=0 '.test_execution.mutation_thresholds' "$config" 2>&1)"; then
    printf 'error: yq failed to read test_execution.mutation_thresholds from %s: %s\n' "$config" "$raw" >&2
    return 1
  fi
  case "$raw" in
    ''|null) return 0 ;;
  esac
  printf '%s\n' "$raw"
}

mutation_config_path() {
  local PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-}}"
  if [ -z "$PROJECT_ROOT" ]; then
    PROJECT_ROOT="$("$_MC_LIB_DIR/../resolve-config.sh" --field project_root 2>/dev/null)" || PROJECT_ROOT=""
  fi
  local candidate
  for candidate in \
    "${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/config/project-config.yaml" \
    "${PROJECT_ROOT:+${PROJECT_ROOT%/}/}config/project-config.yaml"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
}

mutation_evidence_path() {
  local story_key="$1" artifacts="${GAIA_TEST_ARTIFACTS:-}"
  if [ -z "$artifacts" ]; then
    artifacts="$("$_MC_LIB_DIR/../resolve-config.sh" --field test_artifacts 2>/dev/null)" || artifacts=""
  fi
  if [ -z "$artifacts" ]; then
    local PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-}}"
    artifacts="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/artifacts/test-artifacts"
  fi
  printf '%s/test-results/%s-mutation.json\n' "${artifacts%/}" "$story_key"
}

mutation_story_priority() {
  awk '
    NR > 1 && /^---[[:space:]]*$/ { exit }
    /^priority:/ {
      value = $2
      gsub(/["'"'"']/, "", value)
      if (value ~ /^P[0-3]$/) print value
      exit
    }
  ' "$1"
}

# Handles `- \`path\` — note`, `| \`path\` | note |` and bare `- path` entries.
# The first backticked token on a line is the path; later ones are prose.
mutation_story_file_list() {
  awk '
    /^##+[[:space:]]+[Ff]ile [Ll]ist/ { in_list = 1; next }
    in_list && /^#+[[:space:]]/       { exit }
    !in_list                          { next }
    {
      line = $0
      first = index(line, "`")
      if (first > 0) {
        rest = substr(line, first + 1)
        close_at = index(rest, "`")
        if (close_at > 1) print substr(rest, 1, close_at - 1)
        next
      }
      if (line ~ /^[[:space:]]*([-*|])[[:space:]]+/) {
        sub(/^[[:space:]]*[-*|][[:space:]]+/, "", line)
        split(line, parts, /[[:space:]]+/)
        if (parts[1] ~ /[.\/]/ && parts[1] !~ /^-+$/) print parts[1]
      }
    }
  ' "$1"
}
