#!/usr/bin/env bats
# never-built-commands.bats -- asserts the eight never-built design commands
# remain absent from the skill tree, workflow manifest, and help CSV.

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILLS_DIR="$PLUGIN_ROOT/skills"
  MANIFEST="$PLUGIN_ROOT/knowledge/workflow-manifest.csv"
  HELP_CSV="$PLUGIN_ROOT/knowledge/gaia-help.csv"

  # The eight never-built commands (command suffix after "gaia-").
  CMDS=(
    "design-upgrade"
    "design-rescan"
    "design-reverse"
    "design-component-edit"
    "design-screen-edit"
    "design-kit-new"
    "design-component-new"
    "design-screen-new"
  )
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# _find_commands_in <file> <label>
# Greps the file for each command in CMDS. Returns found names or empty.
_find_commands_in() {
  local file="$1" label="$2"
  [ -f "$file" ] || { printf 'Missing %s: %s\n' "$label" "$file"; return 1; }
  local found=()
  for cmd in "${CMDS[@]}"; do
    grep -qF "gaia-${cmd}" "$file" && found+=("gaia-${cmd}")
  done
  if [ ${#found[@]} -gt 0 ]; then
    printf 'Found in %s (should be absent): %s\n' "$label" "${found[*]}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# AC6 — none exists as a skill directory
# ---------------------------------------------------------------------------

@test "(AC6) none of eight commands exists as a skill directory" {
  local found=()
  for cmd in "${CMDS[@]}"; do
    [ -d "$SKILLS_DIR/gaia-${cmd}" ] && found+=("gaia-${cmd}")
  done
  if [ ${#found[@]} -gt 0 ]; then
    printf 'Skill directories found (should not exist): %s\n' "${found[*]}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# AC6 — none appears in workflow manifest
# ---------------------------------------------------------------------------

@test "(AC6) none of eight commands appears in workflow manifest" {
  _find_commands_in "$MANIFEST" "workflow manifest"
}

# ---------------------------------------------------------------------------
# AC6 — none appears in help CSV
# ---------------------------------------------------------------------------

@test "(AC6) none of eight commands appears in help CSV" {
  _find_commands_in "$HELP_CSV" "help CSV"
}
