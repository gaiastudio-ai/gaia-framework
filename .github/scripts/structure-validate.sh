#!/usr/bin/env bash
# structure-validate.sh
# Validates the gaia-framework plugin directory skeleton.
# Asserts required dirs exist, required JSON files exist and parse cleanly.
# Fails loudly on the first offending path.

set -euo pipefail

required_dirs=(
  "plugins/gaia/agents"
  "plugins/gaia/skills"
  "plugins/gaia/hooks"
  "plugins/gaia/scripts"
  ".github/workflows"
)

required_json=(
  ".claude-plugin/marketplace.json"
  "plugins/gaia/.claude-plugin/plugin.json"
)

for d in "${required_dirs[@]}"; do
  if [ ! -d "$d" ]; then
    echo "ERROR: missing directory: $d"
    exit 1
  fi
done

for f in "${required_json[@]}"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: missing file: $f"
    exit 1
  fi
  if ! jq empty "$f" 2>/tmp/jq-err; then
    echo "ERROR: invalid JSON: $f"
    head -1 /tmp/jq-err || true
    exit 1
  fi
done

echo "plugin structure OK"
