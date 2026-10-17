#!/usr/bin/env bash
# diff-select-tests.sh — Identify the bats test files that should run in the
# fast-feedback phase based on which files changed in the PR.
#
# Mapping rules (in priority order):
#   1. A changed .bats file is always selected.
#   2. A changed .sh script under plugins/gaia/scripts/ selects its companion
#      .bats file (same basename, .sh -> .bats) if one exists.
#   3. A changed .sh script under plugins/gaia/skills/*/scripts/ selects
#      every .bats file under the matching tests/skills/*/ directory.
#   4. A changed SKILL.md selects every .bats file that references the skill
#      directory name.
#   5. A changed workflow file (.github/workflows/*.yml) selects any .bats
#      file whose name contains "ci" or "workflow".
#
# Output: one .bats file path per line (relative to repo root), deduplicated.
# Exit 0 with empty output means no test files are diff-selected.
#
# Usage:
#   diff-select-tests.sh [BASE_REF]
#   BASE_REF defaults to origin/staging.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

BASE_REF="${1:-origin/staging}"
TESTS_DIR="plugins/gaia/tests"

# Collect changed files relative to the base ref.
changed=$(git diff --name-only "$BASE_REF"...HEAD 2>/dev/null || git diff --name-only HEAD~1 2>/dev/null || echo "")

if [ -z "$changed" ]; then
  exit 0
fi

selected=()

while IFS= read -r f; do
  [ -z "$f" ] && continue

  # Rule 1: changed .bats file
  if [[ "$f" == *.bats ]]; then
    if [ -f "$f" ]; then
      selected+=("$f")
    fi
    continue
  fi

  # Rule 2: changed script -> companion bats
  if [[ "$f" == plugins/gaia/scripts/*.sh ]]; then
    bname="$(basename "$f" .sh).bats"
    companion="$TESTS_DIR/$bname"
    if [ -f "$companion" ]; then
      selected+=("$companion")
    fi
    continue
  fi

  # Rule 3: changed skill script -> skill test dir
  if [[ "$f" == plugins/gaia/skills/*/scripts/*.sh ]]; then
    skill_name=$(echo "$f" | sed 's|plugins/gaia/skills/\([^/]*\)/.*|\1|')
    if [ -d "$TESTS_DIR/skills/$skill_name" ]; then
      while IFS= read -r bt; do
        selected+=("$bt")
      done < <(find "$TESTS_DIR/skills/$skill_name" -name '*.bats' 2>/dev/null)
    fi
    # Also check for top-level bats files matching the skill name.
    while IFS= read -r bt; do
      selected+=("$bt")
    done < <(find "$TESTS_DIR" -maxdepth 1 -name "${skill_name}*.bats" 2>/dev/null)
    continue
  fi

  # Rule 4: changed SKILL.md -> bats files referencing the skill
  if [[ "$f" == plugins/gaia/skills/*/SKILL.md ]]; then
    skill_name=$(echo "$f" | sed 's|plugins/gaia/skills/\([^/]*\)/.*|\1|')
    if [ -d "$TESTS_DIR/skills/$skill_name" ]; then
      while IFS= read -r bt; do
        selected+=("$bt")
      done < <(find "$TESTS_DIR/skills/$skill_name" -name '*.bats' 2>/dev/null)
    fi
    while IFS= read -r bt; do
      selected+=("$bt")
    done < <(find "$TESTS_DIR" -maxdepth 1 -name "${skill_name}*.bats" 2>/dev/null)
    continue
  fi

  # Rule 5: changed workflow -> CI-related bats
  if [[ "$f" == .github/workflows/*.yml ]]; then
    while IFS= read -r bt; do
      selected+=("$bt")
    done < <(find "$TESTS_DIR" -maxdepth 1 -name '*ci*' -o -name '*workflow*' 2>/dev/null)
    continue
  fi
done <<< "$changed"

# Deduplicate and print.
if [ ${#selected[@]} -gt 0 ]; then
  printf '%s\n' "${selected[@]}" | sort -u
fi
