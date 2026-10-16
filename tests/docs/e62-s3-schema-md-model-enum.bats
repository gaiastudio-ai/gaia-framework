#!/usr/bin/env bats
# E62-S3 — Update agent-frontmatter-schema.md model enum to include claude-opus-4-7 + refresh stale prose
#
# Coverage:
#   - AC1: claude-opus-4-7 appears in the model enum row of agent-frontmatter-schema.md.
#   - AC2: prose row mentions ADR-074 and Val's claude-opus-4-7 exception.
#   - Test scenario 1: grep "claude-opus-4-7" agent-frontmatter-schema.md returns >= 1 hit.
#   - Test scenario 2 (regression): lint-agent-frontmatter.sh passes against validator.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCHEMA_FILE="$REPO_ROOT/plugins/gaia/knowledge/agent-frontmatter-schema.md"
  LINTER="$REPO_ROOT/.github/scripts/lint-agent-frontmatter.sh"
  VALIDATOR_FILE="$REPO_ROOT/plugins/gaia/agents/validator.md"
}

@test "E62-S3 AC1: agent-frontmatter-schema.md model enum row includes claude-opus-4-7" {
  [ -f "$SCHEMA_FILE" ]

  # The model row enumerates allowed values inline. We require the literal
  # token claude-opus-4-7 to appear on the same line as the existing
  # claude-opus-4-6 enum entry.
  run grep -F 'claude-opus-4-7' "$SCHEMA_FILE"
  [ "$status" -eq 0 ]

  # AC1 sanity: the enum row should still list all the legacy entries plus
  # the new opus-4-7 token.
  run grep -E 'claude-opus-4-6.*claude-opus-4-7|claude-opus-4-7.*claude-opus-4-6' "$SCHEMA_FILE"
  [ "$status" -eq 0 ]
  run grep -F 'claude-sonnet-4-5' "$SCHEMA_FILE"
  [ "$status" -eq 0 ]
  run grep -F 'claude-haiku-4-5' "$SCHEMA_FILE"
  [ "$status" -eq 0 ]
  run grep -F 'inherit' "$SCHEMA_FILE"
  [ "$status" -eq 0 ]
}

@test "E62-S3 AC2: agent-frontmatter-schema.md prose mentions ADR-074 and Val opus-4-7 exception" {
  [ -f "$SCHEMA_FILE" ]

  # The prose update must call out ADR-074 explicitly.
  run grep -F 'ADR-074' "$SCHEMA_FILE"
  [ "$status" -eq 0 ]

  # The prose update must mention Val (the validator agent) by name in the
  # context of the opus-4-7 pin so the exception is discoverable.
  run grep -E 'Val.*claude-opus-4-7|claude-opus-4-7.*Val|validator.*claude-opus-4-7' "$SCHEMA_FILE"
  [ "$status" -eq 0 ]
}

@test "E62-S3 test scenario 1: grep claude-opus-4-7 agent-frontmatter-schema.md returns >= 1 hit" {
  run grep -c 'claude-opus-4-7' "$SCHEMA_FILE"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "E62-S3 test scenario 2: agent-frontmatter linter still passes against validator.md (regression)" {
  [ -f "$LINTER" ]
  [ -f "$VALIDATOR_FILE" ]

  # The linter scans plugins/gaia/agents/**/*.md when run from repo root.
  # validator.md is part of that scan. Linter only checks presence; the enum
  # bump should not cause it to flag the validator file.
  cd "$REPO_ROOT"
  run bash "$LINTER"
  [ "$status" -eq 0 ]
}
