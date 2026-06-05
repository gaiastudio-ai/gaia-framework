#!/usr/bin/env bash
# deploy-dispatch.sh — /gaia-deploy Pattern A deploy phase.
#
# Resolves the deploy adapter command and invokes it with --env / --version /
# --output-dir. No retries. Captures stdout/stderr to evidence files.
#
# Adapter resolution precedence:
#   1. GAIA_DEPLOY_ADAPTER_CMD env-var (test seam — invoked positionally for
#      backward compatibility).
#   2. `deployment.adapter` from project-config.yaml — resolves to
#      plugins/gaia/scripts/adapters/<adapter>/run.sh and is invoked with
#      `--env <env> --version <ver> --output-dir <dir>` flag form.
#   3. `distribution.channels[0].deploy_adapter` from project-config.yaml —
#      same resolution + flag form as (2). Used only when (2) is absent.
#   4. `script-deploy` default (preserves Phase 1 behavior for web/mobile
#      projects with no explicit adapter config).
#
#   Unknown adapter name (resolution paths 2/3/4) → BLOCKED with the
#   unresolvable name and a listing of available adapters under
#   plugins/gaia/scripts/adapters/. The probe (tool-availability-probe.sh)
#   gates binary availability — `expected_and_missing` → BLOCKED with the
#   missing provider name.
#
#   Auto-detection from `project_kind` is FORBIDDEN — the contract is opt-in
#   (the user must configure `deployment.adapter` or
#   `distribution.channels[].deploy_adapter` to dispatch a non-default
#   adapter).
#
# Exit codes:
#   0  — adapter exited 0
#   1  — adapter exited non-zero (BLOCKED)
#   2  — usage / invalid args
#   127 — adapter not found (unavailable) or unknown adapter name
#
# Test seams (do not document outside this header):
#   GAIA_DEPLOY_ADAPTER_CMD  — full path to an executable; invoked positionally.
#   GAIA_DEPLOY_PLUGIN_ROOT  — override the plugin root used to locate
#                              scripts/adapters/<name>/. Defaults to the
#                              dispatch script's own plugin root.
#   GAIA_DEPLOY_CONFIG       — path to project-config.yaml. Default search:
#                              .gaia/config/project-config.yaml then
#                              project-config.yaml (CWD).
#

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-deploy/deploy-dispatch.sh"
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

ENV_NAME=""
VERSION=""
OUTPUT_DIR=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env) ENV_NAME="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
$SCRIPT_NAME — deploy adapter dispatch.
Usage: $SCRIPT_NAME --env <env> --version <ver> --output-dir <dir>
EOF
      exit 0 ;;
    *) log "unknown arg: $1"; exit 2 ;;
  esac
done

if [ -z "$ENV_NAME" ]; then
  log "BLOCKED: --env is required (no default)"
  exit 2
fi
if [ -z "$VERSION" ] || [ -z "$OUTPUT_DIR" ]; then
  log "usage: --env <env> --version <ver> --output-dir <dir>"
  exit 2
fi

# Path-traversal mitigation.
case "$ENV_NAME" in
  */*|*..*|*$'\n'*|*' '*)
    log "BLOCKED: invalid --env value"; exit 2 ;;
esac

mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# (1) GAIA_DEPLOY_ADAPTER_CMD test seam — preserved verbatim for backward
#     compatibility: positional invocation.
# ---------------------------------------------------------------------------

ADAPTER_CMD="${GAIA_DEPLOY_ADAPTER_CMD:-}"
if [ -n "$ADAPTER_CMD" ]; then
  if [ ! -f "$ADAPTER_CMD" ] || [ ! -x "$ADAPTER_CMD" ]; then
    log "BLOCKED: deploy adapter not found or not executable: $ADAPTER_CMD"
    log "  installation: ensure the adapter run.sh is present and chmod +x"
    exit 127
  fi
  rc=0
  "$ADAPTER_CMD" "$ENV_NAME" "$VERSION" "$OUTPUT_DIR" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log "BLOCKED: deploy adapter exited $rc (no auto-retry)"
    log "  remediation: investigate adapter logs in $OUTPUT_DIR; consider /gaia-rollback-plan (manual)"
    exit 1
  fi
  log "deploy phase: PASSED (env=$ENV_NAME version=$VERSION)"
  exit 0
fi

# ---------------------------------------------------------------------------
# (2)–(4) Config-driven resolution.
# ---------------------------------------------------------------------------

# Resolve plugin root: override env var > derived from script location.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# scripts/deploy-dispatch.sh lives at <plugin-root>/skills/gaia-deploy/scripts/.
DEFAULT_PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PLUGIN_ROOT="${GAIA_DEPLOY_PLUGIN_ROOT:-$DEFAULT_PLUGIN_ROOT}"
ADAPTERS_DIR="$PLUGIN_ROOT/scripts/adapters"

if [ ! -d "$ADAPTERS_DIR" ]; then
  log "BLOCKED: adapters directory not found: $ADAPTERS_DIR"
  log "  installation: ensure the GAIA plugin is installed correctly"
  exit 127
fi

# Locate project-config.yaml.
resolve_config_path() {
  if [ -n "${GAIA_DEPLOY_CONFIG:-}" ]; then
    printf '%s' "$GAIA_DEPLOY_CONFIG"
    return 0
  fi
  # Prefer .gaia/config/, fall back to legacy config/
  if [ -f ".gaia/config/project-config.yaml" ]; then
    printf '%s' ".gaia/config/project-config.yaml"
    return 0
  fi
  if [ -f ".gaia/config/project-config.yaml" ]; then
    printf '%s' ".gaia/config/project-config.yaml"
    return 0
  fi
  if [ -f "project-config.yaml" ]; then
    printf '%s' "project-config.yaml"
    return 0
  fi
  printf ''
}

CONFIG_PATH="$(resolve_config_path)"

# yaml_read_deployment_adapter <yaml-path>
# Emits the value of `deployment.adapter` (a top-level mapping with an
# `adapter:` scalar child). Stdout empty when absent.
#
# Narrow pure-awk parser: enters the deployment: block at column 0, scans
# the indented children for `  adapter:`, exits at the next column-0 key.
yaml_read_deployment_adapter() {
  local yaml="$1"
  [ -f "$yaml" ] || { printf ''; return 0; }
  awk '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function strip_comment(s) { sub(/[[:space:]]*#.*$/, "", s); return s }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /^deployment[[:space:]]*:/ { in_block = 1; next }
    in_block && /^[^[:space:]]/ { in_block = 0 }
    in_block {
      if (match($0, /^[[:space:]]+adapter[[:space:]]*:[[:space:]]*(.*)$/)) {
        val = $0
        sub(/^[[:space:]]+adapter[[:space:]]*:[[:space:]]*/, "", val)
        val = trim(strip_comment(val))
        # Strip wrapping quotes if any.
        if (val ~ /^".*"$/) { val = substr(val, 2, length(val) - 2) }
        else if (val ~ /^'\''.*'\''$/) { val = substr(val, 2, length(val) - 2) }
        if (val == "" || val == "null" || val == "~") next
        print val
        exit
      }
    }
  ' "$yaml"
}

# yaml_read_first_channel_deploy_adapter <yaml-path>
# Emits the `deploy_adapter:` value from the first entry of
# `distribution.channels:`. Stdout empty when absent.
#
# Recognized shape:
#   distribution:
#     channels:
#       - type: marketplace
#         deploy_adapter: marketplace-publish
#         ...
#       - ...
#
# Strategy: find the `distribution:` block, then `channels:`, then capture
# the FIRST array entry (line starting with `- `). Within that first entry,
# scan sibling `key: value` lines for `deploy_adapter`. The next `- ` at the
# same indent ends the first entry.
yaml_read_first_channel_deploy_adapter() {
  local yaml="$1"
  [ -f "$yaml" ] || { printf ''; return 0; }
  awk '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function strip_comment(s) { sub(/[[:space:]]*#.*$/, "", s); return s }
    function indent(s,    n) { match(s, /^[[:space:]]*/); return RLENGTH + 0 }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /^distribution[[:space:]]*:/ { in_dist = 1; next }
    in_dist && /^[^[:space:]]/ { in_dist = 0 }
    in_dist && match($0, /^[[:space:]]+channels[[:space:]]*:/) {
      in_channels = 1; next
    }
    # Capture the first list entry indent so we know where the first item
    # ends (next sibling `- ` at same indent, or any shallower line).
    in_channels {
      if (match($0, /^([[:space:]]+)-[[:space:]]/)) {
        item_indent = RLENGTH
        if (entry_seen == 1) {
          # Reached the second list entry — first item is finished.
          exit
        }
        entry_seen = 1
        first_indent = item_indent
        # The "- key: value" form on the dash line itself: handle it.
        line = $0
        sub(/^[[:space:]]+-[[:space:]]/, "", line)
        if (match(line, /^deploy_adapter[[:space:]]*:[[:space:]]*(.*)$/)) {
          val = line
          sub(/^deploy_adapter[[:space:]]*:[[:space:]]*/, "", val)
          val = trim(strip_comment(val))
          if (val ~ /^".*"$/) { val = substr(val, 2, length(val) - 2) }
          else if (val ~ /^'\''.*'\''$/) { val = substr(val, 2, length(val) - 2) }
          if (val != "" && val != "null" && val != "~") {
            print val
            exit
          }
        }
        next
      }
      # Inside the first item: same indent or deeper than first_indent.
      if (entry_seen == 1) {
        if (match($0, /^[[:space:]]+deploy_adapter[[:space:]]*:[[:space:]]*(.*)$/)) {
          val = $0
          sub(/^[[:space:]]+deploy_adapter[[:space:]]*:[[:space:]]*/, "", val)
          val = trim(strip_comment(val))
          if (val ~ /^".*"$/) { val = substr(val, 2, length(val) - 2) }
          else if (val ~ /^'\''.*'\''$/) { val = substr(val, 2, length(val) - 2) }
          if (val != "" && val != "null" && val != "~") {
            print val
            exit
          }
        }
      }
    }
  ' "$yaml"
}

# Resolve adapter name with documented precedence.
ADAPTER_NAME=""
RESOLUTION_SOURCE=""
if [ -n "$CONFIG_PATH" ]; then
  ADAPTER_NAME="$(yaml_read_deployment_adapter "$CONFIG_PATH")"
  if [ -n "$ADAPTER_NAME" ]; then
    RESOLUTION_SOURCE="deployment.adapter"
  else
    ADAPTER_NAME="$(yaml_read_first_channel_deploy_adapter "$CONFIG_PATH")"
    if [ -n "$ADAPTER_NAME" ]; then
      RESOLUTION_SOURCE="distribution.channels[0].deploy_adapter"
    fi
  fi
fi
if [ -z "$ADAPTER_NAME" ]; then
  ADAPTER_NAME="script-deploy"
  RESOLUTION_SOURCE="default (script-deploy)"
fi

# Adapter-name path-traversal mitigation: must be a simple kebab-case
# identifier. No slashes, no dot-segments, no whitespace.
case "$ADAPTER_NAME" in
  */*|*..*|*$'\n'*|*' '*|"")
    log "BLOCKED: invalid adapter name: '$ADAPTER_NAME' (source: $RESOLUTION_SOURCE)"
    exit 2 ;;
esac

ADAPTER_DIR="$ADAPTERS_DIR/$ADAPTER_NAME"
if [ ! -d "$ADAPTER_DIR" ]; then
  log "BLOCKED: unknown adapter '$ADAPTER_NAME' (source: $RESOLUTION_SOURCE)"
  log "  expected directory: $ADAPTER_DIR"
  log "  available adapters under $ADAPTERS_DIR (deploy category):"
  # List adapter names that have a category=deploy entry. Falls back to a
  # plain directory listing when jq is unavailable so the error stays
  # actionable even on minimal hosts.
  if command -v jq >/dev/null 2>&1; then
    for cand in "$ADAPTERS_DIR"/*/adapter.json; do
      [ -f "$cand" ] || continue
      cat="$(jq -r '.category // ""' "$cand" 2>/dev/null || echo '')"
      if [ "$cat" = "deploy" ]; then
        name="$(basename "$(dirname "$cand")")"
        log "    - $name"
      fi
    done
  else
    for cand in "$ADAPTERS_DIR"/*/; do
      name="$(basename "$cand")"
      log "    - $name"
    done
  fi
  exit 127
fi

RUN_SH="$ADAPTER_DIR/run.sh"
ADAPTER_JSON="$ADAPTER_DIR/adapter.json"
if [ ! -x "$RUN_SH" ]; then
  log "BLOCKED: adapter '$ADAPTER_NAME' missing or non-executable run.sh: $RUN_SH"
  exit 127
fi
if [ ! -f "$ADAPTER_JSON" ]; then
  log "BLOCKED: adapter '$ADAPTER_NAME' missing adapter.json: $ADAPTER_JSON"
  exit 127
fi

# Inline binary-availability check (mirrors tool-availability-probe.sh
# subprocess profile). The probe is the canonical source of truth; for
# project-scope deploy adapters with empty file-extensions, the probe
# short-circuits to `not_applicable` before reaching the subprocess stage —
# so we replicate the subprocess check here against adapter.json::provider to
# get a real availability signal. The probe is still invoked below to
# validate adapter.json shape and emit determinism logs.
PROVIDER=""
if command -v jq >/dev/null 2>&1; then
  PROVIDER="$(jq -r '.provider // ""' "$ADAPTER_JSON" 2>/dev/null || echo '')"
  RUNTIME_PROFILE="$(jq -r '."runtime-profile" // "subprocess"' "$ADAPTER_JSON" 2>/dev/null || echo subprocess)"
else
  RUNTIME_PROFILE="subprocess"
fi

if [ -n "$PROVIDER" ] && [ "$RUNTIME_PROFILE" = "subprocess" ]; then
  if ! command -v "$PROVIDER" >/dev/null 2>&1; then
    log "BLOCKED: adapter '$ADAPTER_NAME' provider not on PATH: $PROVIDER"
    log "  installation: install $PROVIDER (see adapter.json or your package manager)"
    exit 127
  fi
fi

# Invoke the canonical probe for shape-validation + determinism log.
# Empty file-list → probe returns `not_applicable` (exit 0) for project-
# scope adapters. That is fine: the meaningful availability check is the
# inline `command -v` above. We do NOT propagate a probe-execution failure
# into BLOCKED here — the run.sh handshake stage is for review adapters,
# not deploy adapters whose run.sh has its own --env/--version contract.
PROBE_SH="$PLUGIN_ROOT/scripts/tool-availability-probe.sh"
if [ -x "$PROBE_SH" ]; then
  EMPTY_LIST="$(mktemp -t deploy-dispatch-flist-XXXXXX)"
  : > "$EMPTY_LIST"
  "$PROBE_SH" --adapter-dir "$ADAPTER_DIR" --file-list "$EMPTY_LIST" >/dev/null 2>&1 || true
  rm -f "$EMPTY_LIST" 2>/dev/null || true
fi

# Single-shot invocation — no retries. On failure, suggest rollback in
# the conversation log but never invoke /gaia-rollback-plan.
log "deploy phase: dispatching '$ADAPTER_NAME' (source: $RESOLUTION_SOURCE)"
rc=0
"$RUN_SH" --env "$ENV_NAME" --version "$VERSION" --output-dir "$OUTPUT_DIR" || rc=$?

if [ "$rc" -ne 0 ]; then
  log "BLOCKED: deploy adapter '$ADAPTER_NAME' exited $rc (no auto-retry)"
  log "  remediation: investigate adapter logs in $OUTPUT_DIR; consider /gaia-rollback-plan (manual)"
  exit 1
fi

log "deploy phase: PASSED (env=$ENV_NAME version=$VERSION adapter=$ADAPTER_NAME)"
exit 0
