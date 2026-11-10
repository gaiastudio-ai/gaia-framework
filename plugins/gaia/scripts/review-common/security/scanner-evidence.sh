#!/usr/bin/env bash
# scanner-evidence.sh — scanner-first evidence collection for security reviews.
#
# Runs every configured security scanner adapter and writes the round's
# scanner evidence into a stable per-story, per-run directory. Other review
# steps (the security gate, the review-packet builder) read this evidence
# through the interface documented below.
#
# Stable interface (breaking changes require a coordination story):
#   Directory:  {story_dir}/scanner-evidence/{run-id}/
#   Manifest:   evidence-manifest.json
#     Fields: version, story, run_id, head_sha, enabled, complete,
#             adapters[{name, category, state, failure_kind, skip_reason,
#                       fragment, sha256}]
#   Fragments:  {adapter}.json (analysis-results shape)
#   Exit codes: 0 = complete or turned off
#               1 = caller/config error
#               2 = incomplete (missing/errored scanners)
#   Stdout:     manifest path (on exit 0 or 2)
#
# Usage:
#   scanner-evidence.sh --story <key> --run-id <id> --repo <code-tree>

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="scanner-evidence.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Navigate to the plugin scripts root: review-common/security -> scripts
PLUGIN_SCRIPTS="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE="$PLUGIN_SCRIPTS/tool-availability-probe.sh"
BUILTIN_ADAPTERS="${BUILTIN_ADAPTERS_DIR:-$PLUGIN_SCRIPTS/adapters}"

die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

STORY_KEY=""
RUN_ID=""
REPO_PATH=""
FILE_LIST_OVERRIDE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --story)     STORY_KEY="$2"; shift 2 ;;
    --run-id)    RUN_ID="$2"; shift 2 ;;
    --repo)      REPO_PATH="$2"; shift 2 ;;
    --file-list) FILE_LIST_OVERRIDE="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
$SCRIPT_NAME — scanner-first evidence collection.
Usage:
  $SCRIPT_NAME --story <key> --run-id <id> --repo <code-tree>
               [--file-list <path>]
EOF
      exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$STORY_KEY" ] || die "--story required"
[ -n "$RUN_ID" ]    || die "--run-id required"
[ -n "$REPO_PATH" ] || die "--repo required"

# Validate run-id: safe directory name. Reject path separators, .., and empty.
[ -n "$RUN_ID" ] || die "run-id must not be empty"
case "$RUN_ID" in
  */*|*..*) die "invalid run-id (must not contain / or ..): $RUN_ID" ;;
esac
_safe_id="$(printf '%s' "$RUN_ID" | tr -d 'a-zA-Z0-9._-')"
[ -z "$_safe_id" ] || die "invalid run-id (must match [a-zA-Z0-9._-]+): $RUN_ID"

# Resolve the story directory.
PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-$(pwd)}}}"
export PROJECT_ROOT

story_dir=""
if [ -x "$PLUGIN_SCRIPTS/resolve-story-file.sh" ]; then
  story_file="$("$PLUGIN_SCRIPTS/resolve-story-file.sh" "$STORY_KEY" 2>/dev/null)" || true
  if [ -n "$story_file" ] && [ -f "$story_file" ]; then
    story_dir="$(dirname "$story_file")"
  fi
fi
if [ -z "$story_dir" ]; then
  for candidate in \
    "$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts"/epic-*/"$STORY_KEY"-*/story.md \
    "$PROJECT_ROOT/docs/implementation-artifacts/$STORY_KEY"-*.md; do
    if [ -f "$candidate" ]; then
      story_dir="$(dirname "$candidate")"
      break
    fi
  done
fi
[ -n "$story_dir" ] && [ -d "$story_dir" ] || die "cannot resolve story directory for $STORY_KEY"

# Evidence output directory.
EVIDENCE_DIR="$story_dir/scanner-evidence/$RUN_ID"

# ---------------------------------------------------------------------------
# Read the scanner-first config key at point of use.
# Only boolean false turns it off; absent or any other value means on.
# ---------------------------------------------------------------------------
_config_file="${PROJECT_CONFIG:-${PROJECT_ROOT}/.gaia/config/project-config.yaml}"
scanner_first_enabled="true"
if [ -f "$_config_file" ] && command -v yq >/dev/null 2>&1; then
  # Use yq -o=json to distinguish boolean false from string "false".
  _raw="$(yq -o=json '.review.scanner_first_enabled' "$_config_file" 2>/dev/null)" || _raw="null"
  # In JSON output, boolean false is the literal "false" (no quotes);
  # string "false" is "\"false\"". Only accept the boolean.
  if [ "$_raw" = "false" ]; then
    scanner_first_enabled="false"
  fi
fi

# ---------------------------------------------------------------------------
# Off switch: write disabled manifest and exit 0.
# ---------------------------------------------------------------------------
if [ "$scanner_first_enabled" = "false" ]; then
  mkdir -p "$EVIDENCE_DIR"
  manifest="$(jq -nc \
    --argjson version 1 \
    --arg story "$STORY_KEY" \
    --arg run_id "$RUN_ID" \
    --arg head_sha "" \
    '{version: $version, story: $story, run_id: $run_id, head_sha: $head_sha,
      enabled: false, complete: true, adapters: []}')"
  _tmp="$(mktemp "$EVIDENCE_DIR/evidence-manifest.json.XXXXXX")"
  printf '%s\n' "$manifest" > "$_tmp"
  mv "$_tmp" "$EVIDENCE_DIR/evidence-manifest.json"
  printf '%s\n' "$EVIDENCE_DIR/evidence-manifest.json"
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolve the current head SHA.
# ---------------------------------------------------------------------------
head_sha=""
if command -v git >/dev/null 2>&1 && [ -d "$REPO_PATH/.git" ] || git -C "$REPO_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  head_sha="$(git -C "$REPO_PATH" rev-parse HEAD 2>/dev/null)" || head_sha=""
fi

# ---------------------------------------------------------------------------
# Check for reusable evidence: same run-id, matching head_sha, all
# fragment hashes verify, and every adapter has a valid fragment.
# ---------------------------------------------------------------------------
_check_reusable() {
  local manifest_file="$EVIDENCE_DIR/evidence-manifest.json"
  [ -f "$manifest_file" ] || return 1
  local m_sha; m_sha="$(jq -r '.head_sha // ""' "$manifest_file" 2>/dev/null)" || return 1
  [ "$m_sha" = "$head_sha" ] && [ -n "$head_sha" ] || return 1
  local m_complete; m_complete="$(jq -r '.complete // false' "$manifest_file" 2>/dev/null)" || return 1
  [ "$m_complete" = "true" ] || return 1
  # Verify every fragment hash.
  local frag_name frag_sha256
  while IFS=$'\t' read -r frag_name frag_sha256; do
    [ -n "$frag_name" ] || continue
    local frag_path="$EVIDENCE_DIR/$frag_name"
    [ -f "$frag_path" ] || return 1
    local actual_sha; actual_sha="$(shasum -a 256 "$frag_path" | awk '{print $1}')"
    [ "$actual_sha" = "$frag_sha256" ] || return 1
  done < <(jq -r '.adapters[] | select(.fragment != null) | [.fragment, .sha256] | @tsv' "$manifest_file" 2>/dev/null)
  return 0
}

if _check_reusable; then
  printf '%s\n' "$EVIDENCE_DIR/evidence-manifest.json"
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolve the scanner set (AC3).
# ---------------------------------------------------------------------------
_scanner_categories="sast secret-scan dep-audit"

# Read configured providers from tools section, filtering to scanner categories.
_scanner_set=()
_has_tools_section=false
if [ -f "$_config_file" ] && command -v yq >/dev/null 2>&1; then
  _configured_providers="$(yq -o=json '.tools // {}' "$_config_file" 2>/dev/null | \
    jq -r 'to_entries[] | select(.key != "aggregation") | .value.provider // empty' 2>/dev/null)" || _configured_providers=""
  if [ -n "$_configured_providers" ]; then
    _has_tools_section=true
    _custom_root="${GAIA_CUSTOM_DIR:-${PROJECT_ROOT}/.gaia/custom}/adapters"
    while IFS= read -r _prov; do
      [ -n "$_prov" ] || continue
      # Validate provider name: reject / and .. explicitly (exit 1).
      case "$_prov" in
        */*) die "provider name must not contain /: $_prov" ;;
        *..*) die "provider name must not contain ..: $_prov" ;;
      esac
      # Also reject any unsafe character.
      case "$_prov" in
        *[!a-z0-9._-]*)
          die "bad provider name in config: $_prov" ;;
      esac
      # Find the adapter directory.
      _adapter_dir=""
      if [ -d "$_custom_root/$_prov" ]; then
        _adapter_dir="$_custom_root/$_prov"
      elif [ -d "$BUILTIN_ADAPTERS/$_prov" ]; then
        _adapter_dir="$BUILTIN_ADAPTERS/$_prov"
      fi
      if [ -z "$_adapter_dir" ]; then
        die "configured provider resolves to no adapter directory: $_prov"
      fi
      # Check category — only scanner categories are included.
      _cat="$(jq -r '.category // ""' "$_adapter_dir/adapter.json" 2>/dev/null)" || _cat=""
      case " $_scanner_categories " in
        *" $_cat "*) _scanner_set+=("$_prov") ;;
      esac
    done <<< "$_configured_providers"
  fi
fi

# If no scanner-category providers were resolved (whether there is a tools
# section or not), fall back to the hardening defaults.
if [ "${#_scanner_set[@]}" -eq 0 ]; then
  _scanner_set=(semgrep osv-scanner)
fi

# Custom adapter root (for the loop below).
_custom_root="${GAIA_CUSTOM_DIR:-${PROJECT_ROOT}/.gaia/custom}/adapters"

# ---------------------------------------------------------------------------
# Resolve the runtime profile.
# ---------------------------------------------------------------------------
_runtime_profile="subprocess"
if [ -f "$_config_file" ] && command -v yq >/dev/null 2>&1; then
  _runner="$(yq -r '.brownfield.tools.runner // "native"' "$_config_file" 2>/dev/null)" || _runner="native"
  [ "$_runner" = "docker" ] && _runtime_profile="container"
fi

# ---------------------------------------------------------------------------
# Build the file list from the story diff (not the whole repo).
# ---------------------------------------------------------------------------
_file_list_tmp="$(mktemp -t scanner-files-XXXXXX)"
_cleanup_files=("$_file_list_tmp")
_cleanup() {
  for f in "${_cleanup_files[@]}"; do
    rm -f "$f" 2>/dev/null || true
  done
}
trap _cleanup EXIT

if [ -n "$FILE_LIST_OVERRIDE" ] && [ -r "$FILE_LIST_OVERRIDE" ]; then
  cp "$FILE_LIST_OVERRIDE" "$_file_list_tmp"
elif [ -d "$REPO_PATH" ]; then
  # Use the story's File List section from the story file, or fall back to
  # the diff against the merge base. The file list contains only the files
  # this story changed, not the whole repository.
  _story_file="$story_dir/story.md"
  if command -v git >/dev/null 2>&1 && git -C "$REPO_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # Diff from merge base to HEAD — the story's changed files.
    _base="$(git -C "$REPO_PATH" merge-base HEAD origin/staging 2>/dev/null)" || _base=""
    if [ -n "$_base" ]; then
      git -C "$REPO_PATH" diff --name-only "$_base"..HEAD 2>/dev/null > "$_file_list_tmp"
    fi
    # If the diff is empty (no merge base, or HEAD==staging), fall back to
    # tracked files — but only as a last resort.
    if [ ! -s "$_file_list_tmp" ]; then
      git -C "$REPO_PATH" ls-files --cached --others --exclude-standard 2>/dev/null > "$_file_list_tmp"
    fi
  else
    find "$REPO_PATH" -type f 2>/dev/null | sed "s|^${REPO_PATH}/||" > "$_file_list_tmp"
  fi
fi

# ---------------------------------------------------------------------------
# Collect evidence: run each adapter from the repo directory.
# ---------------------------------------------------------------------------
mkdir -p "$EVIDENCE_DIR"
adapters_json="[]"
all_complete=true

for _adapter_name in "${_scanner_set[@]}"; do
  # Resolve adapter directory.
  _adapter_dir=""
  if [ -d "$_custom_root/$_adapter_name" ]; then
    _adapter_dir="$_custom_root/$_adapter_name"
  elif [ -d "$BUILTIN_ADAPTERS/$_adapter_name" ]; then
    _adapter_dir="$BUILTIN_ADAPTERS/$_adapter_name"
  fi
  if [ -z "$_adapter_dir" ] || [ ! -f "$_adapter_dir/adapter.json" ]; then
    printf '%s: adapter directory not found: %s\n' "$SCRIPT_NAME" "$_adapter_name" >&2
    exit 1
  fi

  _category="$(jq -r '.category // ""' "$_adapter_dir/adapter.json" 2>/dev/null)" || _category=""

  # Fragment output file.
  _frag_file="$EVIDENCE_DIR/${_adapter_name}.json"

  # Run the probe with --output passthrough, from the repo directory.
  _probe_json=""
  _probe_rc=0
  if _probe_json="$(cd "$REPO_PATH" && "$PROBE" --adapter-dir "$_adapter_dir" --file-list "$_file_list_tmp" \
                     --runtime-profile "$_runtime_profile" --output "$_frag_file" 2>/dev/null)"; then
    _probe_rc=0
  else
    _probe_rc=$?
  fi

  _state="$(printf '%s' "$_probe_json" | jq -r '.state // "ran_and_errored"' 2>/dev/null)" || _state="ran_and_errored"
  _failure_kind="$(printf '%s' "$_probe_json" | jq -r '.failure_kind // null' 2>/dev/null)" || _failure_kind="null"
  _skip_reason="$(printf '%s' "$_probe_json" | jq -r '.skip_reason // null' 2>/dev/null)" || _skip_reason="null"

  # For not_applicable: check if the adapter wrote a skip fragment.
  if [ "$_state" = "not_applicable" ] && [ ! -f "$_frag_file" ]; then
    jq -nc --arg name "$_adapter_name" --arg reason "$_skip_reason" \
      '{name: $name, status: "not_applicable", reason: $reason, findings: []}' > "$_frag_file"
  fi

  # Compute fragment hash — only if fragment exists and is valid JSON.
  _frag_sha256=""
  _frag_basename=""
  if [ -f "$_frag_file" ]; then
    if jq . "$_frag_file" >/dev/null 2>&1; then
      _frag_sha256="$(shasum -a 256 "$_frag_file" | awk '{print $1}')"
      _frag_basename="${_adapter_name}.json"
    else
      # Fragment is present but not valid JSON — treat as incomplete.
      _state="ran_and_errored"
      _failure_kind="invalid_fragment"
    fi
  elif [ "$_state" = "available" ]; then
    # Available adapter but no fragment — incomplete.
    _state="ran_and_errored"
    _failure_kind="missing_fragment"
  fi

  # Completeness: available and not_applicable with valid fragment are complete.
  case "$_state" in
    available|not_applicable) ;;
    *)
      all_complete=false
      printf '%s: HALT — adapter %s: state=%s' "$SCRIPT_NAME" "$_adapter_name" "$_state" >&2
      if [ "$_failure_kind" != "null" ] && [ -n "$_failure_kind" ]; then
        printf ', failure_kind=%s' "$_failure_kind" >&2
      fi
      printf '\n' >&2
      printf '  remediation: install %s, set brownfield.tools.runner: docker, change tools.<category>.provider, or turn scanner-first off with review.scanner_first_enabled: false\n' "$_adapter_name" >&2
      ;;
  esac

  # Append to adapters array.
  adapters_json="$(printf '%s' "$adapters_json" | jq -c \
    --arg name "$_adapter_name" \
    --arg category "$_category" \
    --arg state "$_state" \
    --arg fk "$_failure_kind" \
    --arg sr "$_skip_reason" \
    --arg frag "$_frag_basename" \
    --arg sha "$_frag_sha256" \
    '. + [{
      name: $name,
      category: $category,
      state: $state,
      failure_kind: (if $fk == "null" or $fk == "" then null else $fk end),
      skip_reason: (if $sr == "null" or $sr == "" then null else $sr end),
      fragment: (if $frag == "" then null else $frag end),
      sha256: (if $sha == "" then null else $sha end)
    }]')"
done

# ---------------------------------------------------------------------------
# Write the manifest atomically with a unique temp file (concurrency-safe).
# ---------------------------------------------------------------------------
complete_bool="true"
exit_code=0
if [ "$all_complete" = "false" ]; then
  complete_bool="false"
  exit_code=2
fi

manifest="$(jq -nc \
  --argjson version 1 \
  --arg story "$STORY_KEY" \
  --arg run_id "$RUN_ID" \
  --arg head_sha "$head_sha" \
  --argjson enabled true \
  --argjson complete "$complete_bool" \
  --argjson adapters "$adapters_json" \
  '{version: $version, story: $story, run_id: $run_id, head_sha: $head_sha,
    enabled: $enabled, complete: $complete, adapters: $adapters}')"

_tmp="$(mktemp "$EVIDENCE_DIR/evidence-manifest.json.XXXXXX")"
printf '%s\n' "$manifest" > "$_tmp"
mv "$_tmp" "$EVIDENCE_DIR/evidence-manifest.json"
printf '%s\n' "$EVIDENCE_DIR/evidence-manifest.json"
exit "$exit_code"
