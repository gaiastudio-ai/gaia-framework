#!/usr/bin/env bats
# tests/skills/e117-s5-stack-dev-parity.bats
# Guard tests for stack-dev documentation parity (bash/embedded knowledge files,
# namespace-convention docs, and 9-stack SKILL enumeration sweep).

PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

# ---------------------------------------------------------------------------
# knowledge files exist and are non-empty (AC1)
# ---------------------------------------------------------------------------

@test "bash-patterns.md exists and is non-empty (AC1)" {
  local f="$PLUGIN_ROOT/knowledge/bash/bash-patterns.md"
  [ -f "$f" ]
  [ -s "$f" ]
}

@test "posix-portability.md exists and is non-empty (AC1)" {
  local f="$PLUGIN_ROOT/knowledge/bash/posix-portability.md"
  [ -f "$f" ]
  [ -s "$f" ]
}

@test "bats-testing.md exists and is non-empty (AC1)" {
  local f="$PLUGIN_ROOT/knowledge/bash/bats-testing.md"
  [ -f "$f" ]
  [ -s "$f" ]
}

@test "ci-scripting.md exists and is non-empty (AC1)" {
  local f="$PLUGIN_ROOT/knowledge/bash/ci-scripting.md"
  [ -f "$f" ]
  [ -s "$f" ]
}

@test "esp-idf-patterns.md exists and is non-empty (AC1)" {
  local f="$PLUGIN_ROOT/knowledge/embedded/esp-idf-patterns.md"
  [ -f "$f" ]
  [ -s "$f" ]
}

@test "freertos-patterns.md exists and is non-empty (AC1)" {
  local f="$PLUGIN_ROOT/knowledge/embedded/freertos-patterns.md"
  [ -f "$f" ]
  [ -s "$f" ]
}

@test "driver-patterns.md exists and is non-empty (AC1)" {
  local f="$PLUGIN_ROOT/knowledge/embedded/driver-patterns.md"
  [ -f "$f" ]
  [ -s "$f" ]
}

@test "embedded-conventions.md exists and is non-empty (AC1)" {
  local f="$PLUGIN_ROOT/knowledge/embedded/embedded-conventions.md"
  [ -f "$f" ]
  [ -s "$f" ]
}

# ---------------------------------------------------------------------------
# namespace-convention knowledge doc and script header comment (AC2)
# ---------------------------------------------------------------------------

@test "stack-detection-namespaces.md exists and is non-empty (AC2)" {
  local f="$PLUGIN_ROOT/knowledge/stack-detection-namespaces.md"
  [ -f "$f" ]
  [ -s "$f" ]
}

@test "detect-signals.sh contains namespace-convention comment (AC2)" {
  grep -qE 'namespace|persona.token|canonical.token|-dev' \
    "$PLUGIN_ROOT/scripts/detect-signals.sh"
}

# ---------------------------------------------------------------------------
# 7 shared SKILL.md files enumerate all 9 stacks (AC3)
# ---------------------------------------------------------------------------

@test "edge-cases SKILL.md mentions bash, go, and embedded (AC3)" {
  local f="$PLUGIN_ROOT/skills/edge-cases/SKILL.md"
  grep -qi 'bash' "$f"
  grep -qi 'go'   "$f"
  grep -qi 'embedded' "$f"
}

@test "gaia-code-review-standards SKILL.md mentions bash, go, and embedded (AC3)" {
  local f="$PLUGIN_ROOT/skills/gaia-code-review-standards/SKILL.md"
  grep -qi 'bash' "$f"
  grep -qi 'go'   "$f"
  grep -qi 'embedded' "$f"
}

@test "gaia-api-design SKILL.md mentions bash, go, and embedded (AC3)" {
  local f="$PLUGIN_ROOT/skills/gaia-api-design/SKILL.md"
  grep -qi 'bash' "$f"
  grep -qi 'go'   "$f"
  grep -qi 'embedded' "$f"
}

@test "gaia-documentation-standards SKILL.md mentions bash, go, and embedded (AC3)" {
  local f="$PLUGIN_ROOT/skills/gaia-documentation-standards/SKILL.md"
  grep -qi 'bash' "$f"
  grep -qi 'go'   "$f"
  grep -qi 'embedded' "$f"
}

@test "gaia-git-workflow SKILL.md mentions bash, go, and embedded (AC3)" {
  local f="$PLUGIN_ROOT/skills/gaia-git-workflow/SKILL.md"
  grep -qi 'bash' "$f"
  grep -qi 'go'   "$f"
  grep -qi 'embedded' "$f"
}

@test "gaia-testing-patterns SKILL.md mentions bash, go, and embedded (AC3)" {
  local f="$PLUGIN_ROOT/skills/gaia-testing-patterns/SKILL.md"
  grep -qi 'bash' "$f"
  grep -qi 'go'   "$f"
  grep -qi 'embedded' "$f"
}

@test "gaia-security-basics SKILL.md mentions bash, go, and embedded (AC3)" {
  local f="$PLUGIN_ROOT/skills/gaia-security-basics/SKILL.md"
  grep -qi 'bash' "$f"
  grep -qi 'go'   "$f"
  grep -qi 'embedded' "$f"
}
