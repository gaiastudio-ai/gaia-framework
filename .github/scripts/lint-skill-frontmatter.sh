#!/usr/bin/env bash
# lint-skill-frontmatter.sh
# Lints YAML frontmatter of every plugins/gaia/skills/**/SKILL.md file.
# Required fields: name, description.
# Empty tree is a valid, passing state.
#
# Pure bash — no yq/jq dependency. Extracts frontmatter between the leading
# `---` delimiters using awk, then greps for each required field.

set -euo pipefail

REQUIRED_FIELDS=("name" "description")

# Canonical tool set — the single source of truth for allowed-tools validation.
# To add a new tool, update this array only — no other code changes required.
CANONICAL_TOOLS=("Read" "Write" "Edit" "Bash" "Grep" "Glob" "WebFetch" "WebSearch" "Task" "Agent" "Skill")

# is_canonical_tool — returns 0 if the tool name is in CANONICAL_TOOLS, 1 otherwise.
is_canonical_tool() {
  local tool="$1"
  for canonical in "${CANONICAL_TOOLS[@]}"; do
    [ "$tool" = "$canonical" ] && return 0
  done
  return 1
}

count=0
errors=0

while IFS= read -r -d '' file; do
  count=$((count + 1))

  # Extract frontmatter: everything between the first two `---` lines.
  frontmatter=$(awk '
    BEGIN { in_fm = 0; seen = 0 }
    /^---[[:space:]]*$/ {
      if (seen == 0) { in_fm = 1; seen = 1; next }
      else if (in_fm == 1) { in_fm = 0; exit }
    }
    in_fm == 1 { print }
  ' "$file")

  if [ -z "$frontmatter" ]; then
    echo "ERROR: $file missing required field: name"
    echo "ERROR: $file missing required field: description"
    errors=$((errors + 2))
    continue
  fi

  for field in "${REQUIRED_FIELDS[@]}"; do
    # Match `field:` at line start, with a non-empty value after the colon.
    if ! awk -v f="$field" '
      $0 ~ "^"f"[[:space:]]*:" {
        # Strip "field:" prefix
        sub("^"f"[[:space:]]*:[[:space:]]*", "", $0)
        # Strip surrounding quotes
        gsub(/^["'\'']|["'\'']$/, "", $0)
        if (length($0) > 0) { found = 1 }
      }
      END { exit (found ? 0 : 1) }
    ' <<< "$frontmatter"; then
      echo "ERROR: $file missing required field: $field"
      errors=$((errors + 1))
    fi
  done

  # Validate allowed-tools field if present.
  # Extract the allowed-tools line from frontmatter.
  allowed_tools_line=$(echo "$frontmatter" | awk '/^allowed-tools[[:space:]]*:/ { sub(/^allowed-tools[[:space:]]*:[[:space:]]*/, ""); print; found=1 } END { if (!found) exit 1 }') || true

  if [ -n "$allowed_tools_line" ]; then
    # Normalize: strip brackets, commas, and extra whitespace.
    normalized=$(echo "$allowed_tools_line" | sed 's/\[//g; s/\]//g; s/,/ /g' | xargs)

    if [ -n "$normalized" ]; then
      for tool in $normalized; do
        if ! is_canonical_tool "$tool"; then
          echo "ERROR: $file invalid allowed-tool: $tool"
          errors=$((errors + 1))
        fi
      done
    fi
  fi

  # The `tools:` top-level key is retired. The canonical
  # Claude Code skills field is `allowed-tools:` (see
  # https://code.claude.com/docs/en/skills). Fail loudly if a skill
  # regresses to the `tools:` key.
  if echo "$frontmatter" | grep -qE '^tools[[:space:]]*:'; then
    echo "ERROR: $file uses retired frontmatter key 'tools:' — rename to 'allowed-tools:'"
    errors=$((errors + 1))
  fi

done < <(find plugins/gaia/skills -type f -name 'SKILL.md' -print0 2>/dev/null)

if [ "$count" -eq 0 ]; then
  echo "0 SKILL.md files scanned — OK (empty tree)"
  exit 0
fi

if [ "$errors" -gt 0 ]; then
  exit 1
fi

echo "$count SKILL.md files scanned — OK"
