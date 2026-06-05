#!/usr/bin/env bash
# plugin-detection.sh — plugin signal detector.
#
# Scans a project root for Claude Code plugin signals and emits a JSON
# document with `is_plugin`, `signal_count`, and `signals[]`. A project is
# classified as a plugin when 3 or more co-occurring signals are present
# (single-signal detection is rejected to avoid false positives on stray
# SKILL.md or manifest.yaml files).
#
# Signal registry:
#   skill_md         — any plugins/*/SKILL.md or **/SKILL.md file
#   adapter_json     — any scripts/adapters/*/adapter.json or
#                      **/adapters/*/adapter.json file
#   plugin_manifest  — .claude-plugin/plugin.json OR manifest.yaml at
#                      project root
#   commands_dir     — commands/ directory containing at least one .md
#   settings_hooks   — settings.json with a `hooks` or `permissions` key
#   dot_claude_dir   — .claude/ directory present at project root
#
# Usage:
#   plugin-detection.sh --project-root <dir> [--format json]
#
# Exit codes:
#   0 success
#   1 argument error or missing dependency
#
# Requires: python3 (json emit). jq is NOT required.

set -euo pipefail
LC_ALL=C
export LC_ALL

prog="plugin-detection.sh"
err() { printf '%s: %s\n' "$prog" "$*" >&2; }

PROJECT_ROOT=""
FORMAT="json"

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
    -h|--help)
      sed -n '1,32p' "$0" >&2; exit 0 ;;
    *)
      err "unknown argument: $1"; exit 1 ;;
  esac
done

[ -n "$PROJECT_ROOT" ] || { err "missing required --project-root <dir>"; exit 1; }
[ -d "$PROJECT_ROOT" ] || { err "project root not a directory: $PROJECT_ROOT"; exit 1; }
command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found in PATH"; exit 1; }

PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"

# ---------------------------------------------------------------------------
# Signal probes — each function returns 0 on hit, 1 on miss. We constrain
# searches to depth <= 5 to keep the scan bounded on large monorepos.
# ---------------------------------------------------------------------------

_has_skill_md() {
  find "$PROJECT_ROOT" -maxdepth 5 -name 'SKILL.md' -print 2>/dev/null | grep -q .
}

_has_adapter_json() {
  find "$PROJECT_ROOT" -maxdepth 6 -path '*/adapters/*/adapter.json' -print 2>/dev/null | grep -q .
}

_has_plugin_manifest() {
  [ -f "$PROJECT_ROOT/.claude-plugin/plugin.json" ] && return 0
  [ -f "$PROJECT_ROOT/manifest.yaml" ] && return 0
  [ -f "$PROJECT_ROOT/manifest.json" ] && return 0
  return 1
}

_has_commands_dir() {
  [ -d "$PROJECT_ROOT/commands" ] || return 1
  find "$PROJECT_ROOT/commands" -maxdepth 1 -name '*.md' -print 2>/dev/null | grep -q .
}

_has_settings_hooks() {
  local f="$PROJECT_ROOT/settings.json"
  [ -f "$f" ] || f="$PROJECT_ROOT/.claude/settings.json"
  [ -f "$f" ] || return 1
  python3 - "$f" <<'PY' >/dev/null 2>&1
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
if isinstance(d, dict) and ("hooks" in d or "permissions" in d):
    sys.exit(0)
sys.exit(1)
PY
}

_has_dot_claude_dir() {
  [ -d "$PROJECT_ROOT/.claude" ]
}

# ---------------------------------------------------------------------------
# Run probes — collect matched signals.
# ---------------------------------------------------------------------------
signals=()
_has_skill_md         && signals+=("skill_md")
_has_adapter_json     && signals+=("adapter_json")
_has_plugin_manifest  && signals+=("plugin_manifest")
_has_commands_dir     && signals+=("commands_dir")
_has_settings_hooks   && signals+=("settings_hooks")
_has_dot_claude_dir   && signals+=("dot_claude_dir")

count="${#signals[@]}"

# ---------------------------------------------------------------------------
# Emit JSON — is_plugin true iff signal_count >= 3.
# ---------------------------------------------------------------------------
case "$FORMAT" in
  json) ;;
  *) err "unsupported --format '$FORMAT' (expected json)"; exit 1 ;;
esac

# Pass signals as args; python3 builds the canonical JSON.
# Guard for empty `signals` array — `set -u` (nounset) + `${signals[@]}` on
# bash<4.4 unbinds; the `+x` form expands to nothing safely on empty arrays.
python3 - "$count" ${signals[@]+"${signals[@]}"} <<'PY'
import json, sys
count = int(sys.argv[1])
signals = sys.argv[2:]
out = {
    "is_plugin": count >= 3,
    "signal_count": count,
    "signals": signals,
}
print(json.dumps(out, indent=2))
PY
