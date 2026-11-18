#!/usr/bin/env bash
# ci-junit-fetch.sh — fetch JUnit evidence from CI for a commit.
#
# Downloads JUnit artifacts from completed CI runs for a given HEAD
# commit, validates that they contain JUnit XML, and writes metadata
# about each run (URL, SHA, attempt, duration) alongside the artifacts.
#
# Usage:
#   ci-junit-fetch.sh --repo <code-tree> --out <dir>
#
# Environment:
#   CJF_MAX_ARTIFACTS — maximum number of artifact downloads per
#     invocation (default 50).  Must be a positive integer; invalid
#     values fall back to the default with a warning.
#
# Exit codes:
#   0 — evidence fetched (run-records.json and JUnit XML in --out)
#   1 — caller / argument error
#   2 — unavailable (reason on stdout); caller should fall back to local tiers

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_cjf_log() { printf 'ci-junit-fetch: %s\n' "$*" >&2; }
_cjf_die() { local rc="$1"; shift; _cjf_log "$@"; exit "$rc"; }

# _cjf_unavailable — print a reason and exit 2.
_cjf_unavailable() {
  printf '%s\n' "$1"
  exit 2
}

# _cjf_glob_to_regex — convert a simple glob pattern to a regex.
# Supports * (zero or more characters) and ? (single character).
# All other regex metacharacters are escaped to match literally.
# shellcheck disable=SC1003
_cjf_glob_to_regex() {
  local glob="$1"
  local i=0 c="" regex=""
  while [ "$i" -lt "${#glob}" ]; do
    c="${glob:$i:1}"
    case "$c" in
      '*') regex="${regex}.*" ;;
      '?') regex="${regex}." ;;
      '.'|'+'|'^'|'$'|'{'|'}'|'('|')'|'|'|'['|']'|'\\')
        regex="${regex}\\${c}" ;;
      *) regex="${regex}${c}" ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$regex"
}

# _cjf_resolve_ci_provider — read ci_platform.provider from config.
# Prints the provider string. Returns 1 when absent.
_cjf_resolve_ci_provider() {
  local provider=""
  if [ -x "$SCRIPT_DIR/resolve-config.sh" ]; then
    provider="$(bash "$SCRIPT_DIR/resolve-config.sh" --field ci_platform.provider 2>/dev/null)" || true
  fi
  if [ -z "$provider" ] || [ "$provider" = "null" ]; then
    return 1
  fi
  printf '%s\n' "$provider"
}

# _cjf_resolve_artifact_pattern — read ci_cd.junit_artifact_pattern
# from project-config.yaml.  Returns the pattern on stdout (empty when
# absent or unreadable).  Uses the framework path helper (gaia-paths.sh)
# as the single source for config-dir resolution — no hard-coded paths.
_cjf_resolve_artifact_pattern() {
  local config_file=""
  local paths_lib="$SCRIPT_DIR/lib/gaia-paths.sh"

  if [ ! -f "$paths_lib" ]; then
    _cjf_log "warning: gaia-paths.sh not found; config pattern unavailable"
    return 0
  fi

  # Source in a subshell so gaia-paths.sh side-effects (exported vars,
  # source guard, potential die on metachar rejection) stay contained.
  config_file="$(
    # Reset the idempotent source guard so the helper re-evaluates
    # inside this subshell rather than returning as a cached no-op.
    _GAIA_PATHS_LOADED=0

    # Propagate PROJECT_ROOT (preferred by resolve-config.sh) into
    # the env var that gaia-paths.sh consults for project-root
    # resolution, keeping both discovery paths consistent.
    if [ -n "${PROJECT_ROOT:-}" ]; then
      CLAUDE_PROJECT_ROOT="$PROJECT_ROOT"
      export CLAUDE_PROJECT_ROOT
    fi

    # shellcheck disable=SC1090
    if source "$paths_lib" 2>/dev/null; then
      printf '%s' "${GAIA_CONFIG_DIR:-}/project-config.yaml"
    else
      exit 1
    fi
  )" || {
    _cjf_log "warning: gaia-paths.sh failed to source; config pattern unavailable"
    return 0
  }

  if [ -z "$config_file" ] || [ ! -f "$config_file" ]; then
    return 0
  fi

  # Read ci_cd.junit_artifact_pattern — yq preferred, awk fallback.
  # Values are never spliced into the program string.
  local val=""
  if command -v yq >/dev/null 2>&1; then
    val="$(yq -r '.ci_cd.junit_artifact_pattern // ""' "$config_file" 2>/dev/null)" || val=""
  else
    val="$(awk '
      /^ci_cd:/ { in_ci=1; next }
      in_ci && /^[^ ]/ { in_ci=0 }
      in_ci && /junit_artifact_pattern:/ {
        sub(/.*junit_artifact_pattern:[ \t]*/, "")
        gsub(/^["'"'"']|["'"'"']$/, "")
        print
        exit
      }
    ' "$config_file" 2>/dev/null)" || val=""
  fi

  if [ "$val" = "null" ]; then val=""; fi
  printf '%s' "$val"
}

# _cjf_is_junit_xml — check if a file is a JUnit XML file.
# Returns 0 when the root element is testsuites or testsuite.
_cjf_is_junit_xml() {
  local file="$1"
  # Size cap: 50 MB
  local max_bytes=52428800
  local file_size
  if stat -f '%z' "$file" >/dev/null 2>&1; then
    file_size="$(stat -f '%z' "$file")"
  elif stat -c '%s' "$file" >/dev/null 2>&1; then
    file_size="$(stat -c '%s' "$file")"
  else
    file_size=0
  fi
  if [ "$file_size" -gt "$max_bytes" ]; then
    return 1
  fi

  [ -f "$file" ] || return 1
  # Check for XML and a JUnit root element in the first 5 lines
  local head_lines
  head_lines="$(head -5 "$file" 2>/dev/null)" || return 1
  case "$head_lines" in
    *"<testsuites"*|*"<testsuite"*) return 0 ;;
  esac
  return 1
}

# _cjf_epoch_from_iso — convert ISO 8601 timestamp to epoch seconds.
# Portable across macOS and Linux.
_cjf_epoch_from_iso() {
  local ts="$1"
  if date -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" '+%s' 2>/dev/null; then
    return 0
  fi
  # Try GNU date
  date -d "$ts" '+%s' 2>/dev/null && return 0
  # Fallback: python
  python3 -I -c "import datetime,sys; print(int(datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).timestamp()))" "$ts" 2>/dev/null && return 0
  printf '0\n'
}

# _cjf_fetch_github_actions — fetch JUnit from GitHub Actions.
# Args: repo, out_dir
_cjf_fetch_github_actions() {
  local repo="$1" out_dir="$2"

  # Require gh CLI
  if ! command -v gh >/dev/null 2>&1; then
    _cjf_unavailable "gh CLI not installed"
  fi

  # Check gh auth
  if ! gh auth status >/dev/null 2>&1; then
    _cjf_unavailable "gh CLI not authenticated"
  fi

  # Get HEAD SHA from the code tree
  local head_sha
  head_sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || \
    _cjf_die 1 "could not resolve HEAD in $repo"

  # Derive owner/repo from the code tree's origin remote, computed once
  # before any gh call.  Used as --repo on gh run list / gh run download.
  # gh api has no --repo flag; it uses an explicit repos/<owner>/<repo>/…
  # endpoint path instead.
  local owner_repo
  owner_repo="$(git -C "$repo" remote get-url origin 2>/dev/null \
    | sed -E 's|.*github\.com[:/]||; s|\.git$||')" || true
  if [ -z "$owner_repo" ]; then
    _cjf_die 1 "could not determine owner/repo from origin remote in $repo"
  fi

  # List runs for this commit
  local runs_json
  runs_json="$(gh run list --repo "$owner_repo" --commit "$head_sha" \
    --json databaseId,url,headSha,status,conclusion,attempt,startedAt,updatedAt \
    2>/dev/null)" || _cjf_unavailable "gh run list failed for commit $head_sha"

  if [ -z "$runs_json" ] || [ "$runs_json" = "null" ] || [ "$runs_json" = "[]" ]; then
    _cjf_unavailable "no CI runs found for commit $head_sha"
  fi

  # Filter to completed runs only
  local completed_json
  completed_json="$(printf '%s' "$runs_json" | jq '[.[] | select(.status == "completed")]')" || \
    _cjf_die 1 "jq filter failed"

  local completed_count
  completed_count="$(printf '%s' "$completed_json" | jq 'length')"
  if [ "$completed_count" = "0" ]; then
    _cjf_unavailable "CI not complete for head commit"
  fi

  # Resolve configurable artifact-name pattern (additive with default).
  local artifact_pattern
  artifact_pattern="$(_cjf_resolve_artifact_pattern)" || artifact_pattern=""

  # Build the jq name-match regex: always includes the default "junit"
  # (case-insensitive substring match).  When a custom glob pattern is
  # configured, it is converted to regex and ORed in so both the default
  # and custom names match.
  local name_regex="junit"
  if [ -n "$artifact_pattern" ]; then
    local lc_pattern pattern_regex
    lc_pattern="$(printf '%s' "$artifact_pattern" | tr '[:upper:]' '[:lower:]')"
    pattern_regex="$(_cjf_glob_to_regex "$lc_pattern")"
    name_regex="junit|${pattern_regex}"
  fi

  # Download bound (defense against runaway artifact downloads).
  local max_artifacts="${CJF_MAX_ARTIFACTS:-50}"
  case "$max_artifacts" in
    ''|*[!0-9]*|0)
      _cjf_log "CJF_MAX_ARTIFACTS='$max_artifacts' is not a positive integer; using default 50"
      max_artifacts=50
      ;;
  esac
  local artifacts_downloaded=0
  local bound_warned=false

  # Iterate runs and find JUnit artifacts
  local run_records="[]"
  local found_junit=false
  local total_duration=0
  local i=0
  local private_tmp
  private_tmp="$(mktemp -d)"

  while [ "$i" -lt "$completed_count" ]; do
    # Stop processing runs once the download bound is reached.
    if [ "$artifacts_downloaded" -ge "$max_artifacts" ]; then
      break
    fi

    local run
    run="$(printf '%s' "$completed_json" | jq -c --argjson idx "$i" '.[$idx]')"
    local run_id run_url run_head_sha run_attempt run_conclusion run_started run_updated
    run_id="$(printf '%s' "$run" | jq -r '.databaseId')"
    run_url="$(printf '%s' "$run" | jq -r '.url')"
    run_head_sha="$(printf '%s' "$run" | jq -r '.headSha')"
    run_attempt="$(printf '%s' "$run" | jq -r '.attempt')"
    run_conclusion="$(printf '%s' "$run" | jq -r '.conclusion')"
    run_started="$(printf '%s' "$run" | jq -r '.startedAt')"
    run_updated="$(printf '%s' "$run" | jq -r '.updatedAt')"

    # Compute duration
    local start_epoch end_epoch duration=0
    start_epoch="$(_cjf_epoch_from_iso "$run_started")"
    end_epoch="$(_cjf_epoch_from_iso "$run_updated")"
    if [ "$start_epoch" -gt 0 ] && [ "$end_epoch" -gt 0 ]; then
      duration=$((end_epoch - start_epoch))
    fi

    # Validate run URL is HTTPS
    case "$run_url" in
      https://*) ;;
      *)
        _cjf_log "skipping run $run_id: no HTTPS URL"
        i=$((i + 1))
        continue
        ;;
    esac

    # List artifacts for this run (gh api has no --repo flag; the
    # owner/repo is embedded in the endpoint path instead).
    local artifacts_json
    artifacts_json="$(gh api "repos/${owner_repo}/actions/runs/${run_id}/artifacts" \
      --jq '.artifacts' 2>/dev/null)" || {
      _cjf_log "could not list artifacts for run $run_id"
      i=$((i + 1))
      continue
    }

    if [ -z "$artifacts_json" ] || [ "$artifacts_json" = "null" ]; then
      i=$((i + 1))
      continue
    fi

    # Find artifacts whose name matches the default or configured pattern
    # (case-insensitive substring match).  The regex is passed via --arg
    # so no value is spliced into the jq program.
    local junit_artifacts
    junit_artifacts="$(printf '%s' "$artifacts_json" | \
      jq -r --arg re "$name_regex" \
        '[.[] | select(.name | ascii_downcase | test($re))] | .[] | .name')" || true

    if [ -z "$junit_artifacts" ]; then
      i=$((i + 1))
      continue
    fi

    # Download each matching artifact
    while IFS= read -r artifact_name; do
      [ -n "$artifact_name" ] || continue

      # Enforce download bound
      if [ "$artifacts_downloaded" -ge "$max_artifacts" ]; then
        if [ "$bound_warned" = "false" ]; then
          _cjf_log "artifact bound reached: limited to $max_artifacts downloads; skipping remaining matches"
          bound_warned=true
        fi
        break
      fi

      local dl_dir="$private_tmp/run-${run_id}/${artifact_name}"
      mkdir -p "$dl_dir"
      if ! gh run download "$run_id" --repo "$owner_repo" \
           --name "$artifact_name" --dir "$dl_dir" 2>/dev/null; then
        _cjf_log "download failed: run=$run_id artifact=$artifact_name"
        continue
      fi

      # Copy only valid JUnit XML files to output
      local xml_file
      while IFS= read -r xml_file; do
        [ -n "$xml_file" ] || continue
        if _cjf_is_junit_xml "$xml_file"; then
          local dest_name
          dest_name="run-${run_id}-$(basename "$xml_file")"
          cp "$xml_file" "$out_dir/$dest_name"
          found_junit=true
        else
          _cjf_log "discarded non-JUnit file: $(basename "$xml_file")"
        fi
      done < <(find "$dl_dir" -name '*.xml' -type f 2>/dev/null)

      artifacts_downloaded=$((artifacts_downloaded + 1))
    done <<< "$junit_artifacts"

    # Add run record
    run_records="$(printf '%s' "$run_records" | jq \
      --arg url "$run_url" \
      --arg sha "$run_head_sha" \
      --argjson attempt "$run_attempt" \
      --arg conclusion "$run_conclusion" \
      --argjson duration "$duration" \
      '. + [{"url": $url, "head_sha": $sha, "attempt": $attempt, "conclusion": $conclusion, "duration_seconds": $duration}]')"

    total_duration=$((total_duration + duration))
    i=$((i + 1))
  done

  rm -rf "$private_tmp"

  if [ "$found_junit" = "false" ]; then
    _cjf_unavailable "no JUnit artifacts found on CI runs for commit $head_sha"
  fi

  # Write run records
  printf '%s' "$run_records" | jq --argjson total "$total_duration" \
    '{runs: ., wall_clock_seconds: $total}' > "$out_dir/run-records.json"
}

# ── Main ────────────────────────────────────────────────────────────

main() {
  local repo="" out_dir=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) [ "$#" -ge 2 ] || _cjf_die 1 "--repo requires a value"; repo="$2"; shift 2 ;;
      --out)  [ "$#" -ge 2 ] || _cjf_die 1 "--out requires a value"; out_dir="$2"; shift 2 ;;
      --help) printf 'Usage: ci-junit-fetch.sh --repo <code-tree> --out <dir>\n'; exit 0 ;;
      *)      _cjf_die 1 "unknown argument: $1" ;;
    esac
  done

  [ -n "$repo" ]    || _cjf_die 1 "--repo is required"
  [ -d "$repo" ]    || _cjf_die 1 "repo directory not found: $repo"
  [ -n "$out_dir" ] || _cjf_die 1 "--out is required"
  mkdir -p "$out_dir"

  command -v jq >/dev/null 2>&1 || _cjf_die 1 "jq is required but not found"

  # Resolve CI provider
  local provider
  provider="$(_cjf_resolve_ci_provider)" || _cjf_unavailable "no ci_platform configured"

  case "$provider" in
    github-actions)
      _cjf_fetch_github_actions "$repo" "$out_dir"
      ;;
    *)
      _cjf_unavailable "provider not supported: $provider"
      ;;
  esac
}

main "$@"
