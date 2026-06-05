#!/usr/bin/env bash
# lint-agent-frontmatter.sh
# Lints YAML frontmatter of every plugins/gaia/agents/**/*.md file.
# Required fields per _SCHEMA.md:
#   name, model, description, context, allowed-tools
# Also validates:
#   - context is one of: main | fork
#   - allowed-tools is a non-empty list (inline [..] or block list)
# Files starting with underscore (e.g. _SCHEMA.md) that do NOT contain
# frontmatter are skipped as documentation. Abstract template files
# (e.g. _base-dev.md) MUST still pass the schema.
# Empty tree is a valid, passing state.
#
# Pure bash + awk — no yq/jq dependency.

set -euo pipefail

REQUIRED_FIELDS=("name" "model" "description" "context" "allowed-tools")

count=0
errors=0

while IFS= read -r -d '' file; do
  # Extract frontmatter: everything between the first two `---` lines.
  frontmatter=$(awk '
    BEGIN { in_fm = 0; seen = 0 }
    /^---[[:space:]]*$/ {
      if (seen == 0) { in_fm = 1; seen = 1; next }
      else if (in_fm == 1) { in_fm = 0; exit }
    }
    in_fm == 1 { print }
  ' "$file")

  # Skip plain documentation files (no frontmatter) that start with `_`.
  base=$(basename "$file")
  if [ -z "$frontmatter" ]; then
    case "$base" in
      _*.md) continue ;;
    esac
    echo "ERROR: $file missing frontmatter entirely"
    for field in "${REQUIRED_FIELDS[@]}"; do
      echo "ERROR: $file missing required field: $field"
      errors=$((errors + 1))
    done
    count=$((count + 1))
    continue
  fi

  count=$((count + 1))

  for field in "${REQUIRED_FIELDS[@]}"; do
    if ! awk -v f="$field" '
      $0 ~ "^"f"[[:space:]]*:" {
        sub("^"f"[[:space:]]*:[[:space:]]*", "", $0)
        gsub(/^["'\'']|["'\'']$/, "", $0)
        if (length($0) > 0) { found = 1 }
      }
      END { exit (found ? 0 : 1) }
    ' <<< "$frontmatter"; then
      echo "ERROR: $file missing or empty required field: $field"
      errors=$((errors + 1))
    fi
  done

  # Validate context ∈ { main, fork }
  context_val=$(awk '
    /^context[[:space:]]*:/ {
      sub("^context[[:space:]]*:[[:space:]]*", "", $0)
      gsub(/^["'\'']|["'\'']$/, "", $0)
      print $0
      exit
    }
  ' <<< "$frontmatter")
  if [ -n "$context_val" ] && [ "$context_val" != "main" ] && [ "$context_val" != "fork" ]; then
    echo "ERROR: $file context must be 'main' or 'fork' (got: $context_val)"
    errors=$((errors + 1))
  fi

  # Validate allowed-tools is a non-empty inline list [..] with at least one entry.
  tools_val=$(awk '
    /^allowed-tools[[:space:]]*:/ {
      sub("^allowed-tools[[:space:]]*:[[:space:]]*", "", $0)
      print $0
      exit
    }
  ' <<< "$frontmatter")
  if [ -n "$tools_val" ]; then
    # Strip brackets and whitespace, check for at least one token.
    stripped=$(printf '%s' "$tools_val" | tr -d '[]' | tr ',' ' ' | xargs)
    if [ -z "$stripped" ]; then
      echo "ERROR: $file allowed-tools list is empty"
      errors=$((errors + 1))
    fi
  fi
done < <(find plugins/gaia/agents -type f -name '*.md' -print0 2>/dev/null)

if [ "$count" -eq 0 ]; then
  echo "0 agent files scanned — OK (empty tree)"
  exit 0
fi

if [ "$errors" -gt 0 ]; then
  exit 1
fi

echo "$count agent files scanned — OK"
