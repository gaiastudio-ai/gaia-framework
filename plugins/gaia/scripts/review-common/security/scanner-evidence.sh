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

while [ "$#" -gt 0 ]; do
  case "$1" in
    --story)  STORY_KEY="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --repo)   REPO_PATH="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
$SCRIPT_NAME — scanner-first evidence collection.
Usage:
  $SCRIPT_NAME --story <key> --run-id <id> --repo <code-tree>
EOF
      exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$STORY_KEY" ] || die "--story required"
[ -n "$RUN_ID" ]    || die "--run-id required"
[ -n "$REPO_PATH" ] || die "--repo required"

# Validate run-id: safe directory name. Reject path separators and ..
case "$RUN_ID" in
  */*|*..*) die "invalid run-id (must not contain / or ..): $RUN_ID" ;;
esac
# Also reject any character outside the safe set.
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
  # Fallback: search common locations.
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
  # Note: yq's // (alternative) treats false as falsy, so use plain read
  # and check explicitly. Only boolean false turns scanner-first off.
  _raw="$(yq '.review.scanner_first_enabled' "$_config_file" 2>/dev/null)" || _raw="null"
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
  printf '%s\n' "$manifest" > "$EVIDENCE_DIR/evidence-manifest.json.tmp"
  mv "$EVIDENCE_DIR/evidence-manifest.json.tmp" "$EVIDENCE_DIR/evidence-manifest.json"
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
# fragment hashes verify.
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
# Scanners are adapters whose adapter.json category is sast, secret-scan
# or dep-audit that match a tools.<category>.provider config entry (when
# the tools section exists) or the hardening defaults (semgrep + osv-scanner).
_scanner_categories="sast secret-scan dep-audit"

# Read configured providers from tools section.
_configured_providers=""
if [ -f "$_config_file" ] && command -v yq >/dev/null 2>&1; then
  # Read all tools.*.provider values (excluding tools.aggregation).
  _configured_providers="$(yq -o=json '.tools // {}' "$_config_file" 2>/dev/null | \
    jq -r 'to_entries[] | select(.key != "aggregation") | .value.provider // empty' 2>/dev/null)" || _configured_providers=""
fi

# Custom adapter root.
_custom_root="${GAIA_CUSTOM_DIR:-${PROJECT_ROOT}/.gaia/custom}/adapters"

# Build the resolved scanner set.
_scanner_set=()
if [ -n "$_configured_providers" ]; then
  # Use configured providers filtered to scanner categories.
  while IFS= read -r _prov; do
    [ -n "$_prov" ] || continue
    # Validate provider name: safe characters only.
    case "$_prov" in
      *[!/a-z0-9._-]*|..*|*..*)
        printf '%s: bad provider name in config: %s\n' "$SCRIPT_NAME" "$_prov" >&2
        exit 1 ;;
    esac
    # Find the adapter directory.
    _adapter_dir=""
    if [ -d "$_custom_root/$_prov" ]; then
      _adapter_dir="$_custom_root/$_prov"
    elif [ -d "$BUILTIN_ADAPTERS/$_prov" ]; then
      _adapter_dir="$BUILTIN_ADAPTERS/$_prov"
    fi
    if [ -z "$_adapter_dir" ]; then
      printf '%s: configured provider resolves to no adapter directory: %s\n' "$SCRIPT_NAME" "$_prov" >&2
      exit 1
    fi
    # Check category.
    _cat="$(jq -r '.category // ""' "$_adapter_dir/adapter.json" 2>/dev/null)" || _cat=""
    case " $_scanner_categories " in
      *" $_cat "*) _scanner_set+=("$_prov") ;;
    esac
  done <<< "$_configured_providers"
else
  # Hardening defaults: semgrep + osv-scanner.
  _scanner_set=(semgrep osv-scanner)
fi

# ---------------------------------------------------------------------------
# Resolve the runtime profile. When brownfield.tools.runner is "docker",
# use container profile.
# ---------------------------------------------------------------------------
_runtime_profile="subprocess"
if [ -f "$_config_file" ] && command -v yq >/dev/null 2>&1; then
  _runner="$(yq -r '.brownfield.tools.runner // "native"' "$_config_file" 2>/dev/null)" || _runner="native"
  [ "$_runner" = "docker" ] && _runtime_profile="container"
fi

# ---------------------------------------------------------------------------
# Build the file list from the repo tree.
# ---------------------------------------------------------------------------
_file_list_tmp="$(mktemp -t scanner-files-XXXXXX)"
_cleanup_files=("$_file_list_tmp")
_cleanup() {
  for f in "${_cleanup_files[@]}"; do
    rm -f "$f" 2>/dev/null || true
  done
}
trap _cleanup EXIT

if [ -d "$REPO_PATH" ]; then
  # List tracked files (or all files if not a git repo).
  if command -v git >/dev/null 2>&1 && git -C "$REPO_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$REPO_PATH" ls-files --cached --others --exclude-standard 2>/dev/null > "$_file_list_tmp"
  else
    find "$REPO_PATH" -type f 2>/dev/null | sed "s|^${REPO_PATH}/||" > "$_file_list_tmp"
  fi
fi

# ---------------------------------------------------------------------------
# Collect evidence: run each adapter through the probe.
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

  # Run the probe with --output passthrough.
  _probe_json=""
  if _probe_json="$("$PROBE" --adapter-dir "$_adapter_dir" --file-list "$_file_list_tmp" \
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
    # Write a skip fragment.
    jq -nc --arg name "$_adapter_name" --arg reason "$_skip_reason" \
      '{name: $name, status: "skipped", reason: $reason, findings: []}' > "$_frag_file"
  fi

  # Compute fragment hash.
  _frag_sha256=""
  _frag_basename=""
  if [ -f "$_frag_file" ]; then
    _frag_sha256="$(shasum -a 256 "$_frag_file" | awk '{print $1}')"
    _frag_basename="${_adapter_name}.json"
  fi

  # Completeness: available and not_applicable are complete. Others are not.
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
# Write the manifest atomically.
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

printf '%s\n' "$manifest" > "$EVIDENCE_DIR/evidence-manifest.json.tmp"
mv "$EVIDENCE_DIR/evidence-manifest.json.tmp" "$EVIDENCE_DIR/evidence-manifest.json"
printf '%s\n' "$EVIDENCE_DIR/evidence-manifest.json"
exit "$exit_code"
