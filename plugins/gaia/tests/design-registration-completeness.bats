#!/usr/bin/env bats
# design-registration-completeness.bats — assert that design-review is
# registered across all four surfaces: lifecycle-sequence node, help CSV
# row, workflow-manifest CSV row, and skills README entry.
#
# No project-root .gaia/ access; all fixtures use mktemp.
# No internal identifiers in @test names.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  KNOWLEDGE_DIR="$PLUGIN_ROOT/knowledge"
  LIFECYCLE_SEQ="$KNOWLEDGE_DIR/lifecycle-sequence.yaml"
  HELP_CSV="$KNOWLEDGE_DIR/gaia-help.csv"
  MANIFEST_CSV="$KNOWLEDGE_DIR/workflow-manifest.csv"
  SKILLS_README="$PLUGIN_ROOT/skills/README.md"
}

teardown() { common_teardown; }

# ===========================================================================
# T4.7: help-routing row exists for gaia-design-review
# ===========================================================================

@test "help-routing row exists for gaia-design-review" {
  [ -f "$HELP_CSV" ] || {
    echo "FAIL: gaia-help.csv not found at $HELP_CSV" >&2
    return 1
  }
  run grep 'gaia-design-review' "$HELP_CSV"
  [ "$status" -eq 0 ] || {
    echo "FAIL: no help CSV row for gaia-design-review" >&2
    return 1
  }
}

# ===========================================================================
# T4.8: symptom phrase "architecture will not start"
# ===========================================================================

@test "help row description contains symptom phrase architecture will not start" {
  [ -f "$HELP_CSV" ] || {
    echo "FAIL: gaia-help.csv not found" >&2
    return 1
  }
  local row
  row="$(grep 'gaia-design-review' "$HELP_CSV" || true)"
  [ -n "$row" ] || {
    echo "FAIL: no help CSV row for gaia-design-review" >&2
    return 1
  }
  echo "$row" | grep -qi 'architecture will not start' || {
    echo "FAIL: help row description missing symptom phrase 'architecture will not start'" >&2
    return 1
  }
}

# ===========================================================================
# T4.9: symptom phrase "design not approved"
# ===========================================================================

@test "help row description contains symptom phrase design not approved" {
  [ -f "$HELP_CSV" ] || {
    echo "FAIL: gaia-help.csv not found" >&2
    return 1
  }
  local row
  row="$(grep 'gaia-design-review' "$HELP_CSV" || true)"
  [ -n "$row" ] || {
    echo "FAIL: no help CSV row for gaia-design-review" >&2
    return 1
  }
  echo "$row" | grep -qi 'design not approved' || {
    echo "FAIL: help row description missing symptom phrase 'design not approved'" >&2
    return 1
  }
}

# ===========================================================================
# T4.10: symptom phrase "solutioning blocked"
# ===========================================================================

@test "help row description contains symptom phrase solutioning blocked" {
  [ -f "$HELP_CSV" ] || {
    echo "FAIL: gaia-help.csv not found" >&2
    return 1
  }
  local row
  row="$(grep 'gaia-design-review' "$HELP_CSV" || true)"
  [ -n "$row" ] || {
    echo "FAIL: no help CSV row for gaia-design-review" >&2
    return 1
  }
  echo "$row" | grep -qi 'solutioning blocked' || {
    echo "FAIL: help row description missing symptom phrase 'solutioning blocked'" >&2
    return 1
  }
}

# ===========================================================================
# T4.11: workflow manifest row phase is 2-planning for design-review
# ===========================================================================

@test "workflow manifest row phase is 2-planning for design-review" {
  [ -f "$MANIFEST_CSV" ] || {
    echo "FAIL: workflow-manifest.csv not found at $MANIFEST_CSV" >&2
    return 1
  }
  local row
  row="$(grep 'design-review' "$MANIFEST_CSV" || true)"
  [ -n "$row" ] || {
    echo "FAIL: no manifest row for design-review" >&2
    return 1
  }
  # The phase column is the 5th field in the CSV (module, phase_col, name, ...)
  # The actual CSV columns per the header are:
  #   name,title,description,module,phase,path,command,agent
  # So phase is field 5. Extract it.
  echo "$row" | grep -q '"2-planning"' || {
    echo "FAIL: manifest row phase for design-review should be 2-planning" >&2
    echo "  row: $row" >&2
    return 1
  }
}

# ===========================================================================
# T4.12: skills README contains design-review entry
# ===========================================================================

@test "skills README contains design-review entry" {
  [ -f "$SKILLS_README" ] || {
    echo "FAIL: skills/README.md not found at $SKILLS_README" >&2
    return 1
  }
  run grep '/gaia-design-review' "$SKILLS_README"
  [ "$status" -eq 0 ] || {
    echo "FAIL: skills README.md has no entry for /gaia-design-review" >&2
    return 1
  }
}

# ===========================================================================
# T4.13: four registration surfaces all present for design-review
# ===========================================================================

@test "four registration surfaces all present for design-review" {
  local missing=0

  # 1. Lifecycle node
  if [ -f "$LIFECYCLE_SEQ" ]; then
    local cmd
    cmd="$(yq -r '.sequence."design-review".command // ""' "$LIFECYCLE_SEQ")"
    if [ "$cmd" != "/gaia-design-review" ]; then
      echo "MISSING: lifecycle-sequence node" >&2
      missing=$((missing + 1))
    fi
  else
    echo "MISSING: lifecycle-sequence.yaml not found" >&2
    missing=$((missing + 1))
  fi

  # 2. Help CSV row
  if [ -f "$HELP_CSV" ]; then
    if ! grep -q 'gaia-design-review' "$HELP_CSV"; then
      echo "MISSING: gaia-help.csv row" >&2
      missing=$((missing + 1))
    fi
  else
    echo "MISSING: gaia-help.csv not found" >&2
    missing=$((missing + 1))
  fi

  # 3. Manifest row
  if [ -f "$MANIFEST_CSV" ]; then
    if ! grep -q 'design-review' "$MANIFEST_CSV"; then
      echo "MISSING: workflow-manifest.csv row" >&2
      missing=$((missing + 1))
    fi
  else
    echo "MISSING: workflow-manifest.csv not found" >&2
    missing=$((missing + 1))
  fi

  # 4. README entry
  if [ -f "$SKILLS_README" ]; then
    if ! grep -q '/gaia-design-review' "$SKILLS_README"; then
      echo "MISSING: skills/README.md entry" >&2
      missing=$((missing + 1))
    fi
  else
    echo "MISSING: skills/README.md not found" >&2
    missing=$((missing + 1))
  fi

  [ "$missing" -eq 0 ] || {
    echo "FAIL: $missing of 4 registration surfaces missing for design-review" >&2
    return 1
  }
}
