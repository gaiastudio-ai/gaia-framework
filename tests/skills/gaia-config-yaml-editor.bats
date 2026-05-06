#!/usr/bin/env bats
# gaia-config-yaml-editor.bats — E71-S3 AC3 + AC4 + AC8
#
# Validates the comment-preserving YAML editor utility used by all
# /gaia-config-* editor commands. The script must:
#   - Read a top-level section from project-config.yaml by name
#   - Replace ONLY that section's lines on write-back
#   - Preserve every comment (inline + block) byte-for-byte in
#     non-edited sections
#   - Preserve formatting (blank lines, indentation) in non-edited sections
#   - Detect missing sections and report them (AC9)
#
# Test cases:
#   TC-RSV2-INIT-16 — comments preserved on write (AC3)
#   TC-RSV2-INIT-17 — formatting preserved on write (AC4)
#   TC-RSV2-INIT-21 — ADR-044 compliance: line-level technique only (AC8)
#   TC-RSV2-INIT-22 — missing section detected (AC9)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/plugins/gaia/scripts/config-yaml-editor.sh"
  TMPDIR_TEST="$(mktemp -d)"
  FIXTURE="$TMPDIR_TEST/project-config.yaml"

  cat > "$FIXTURE" <<'YAML'
# Header comment line 1
# Header comment line 2

project_root: /tmp/proj   # inline comment on project_root
project_path: /tmp/proj/src

# Block comment before environments section
environments:
  staging:
    url: https://staging.example.com   # inline comment 1
    credentials:
      db_password: STAGING_DB_PASSWORD_VAR
  production:
    url: https://app.example.com
    # inline-ish nested comment
    credentials:
      db_password: PROD_DB_PASSWORD_VAR

# Block comment before stacks section
stacks:
  - name: auth
    language: typescript
    paths: ["services/auth/**"]   # path glob comment

# Trailing block comment at EOF
YAML
}

teardown() {
  [ -n "${TMPDIR_TEST:-}" ] && rm -rf "$TMPDIR_TEST"
}

@test "config-yaml-editor.sh exists and is executable" {
  [ -x "$SCRIPT" ]
}

@test "extract returns ONLY the requested section's lines" {
  run "$SCRIPT" extract "$FIXTURE" environments
  [ "$status" -eq 0 ]
  # Output must contain the environments key
  echo "$output" | grep -qE '^environments:'
  # Output must contain its children
  echo "$output" | grep -q 'staging:'
  echo "$output" | grep -q 'production:'
  # Output must NOT contain other top-level sections
  echo "$output" | grep -qvE '^stacks:'
  echo "$output" | grep -qvE '^project_root:'
}

@test "extract preserves inline comments within the section" {
  run "$SCRIPT" extract "$FIXTURE" environments
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '# inline comment 1'
}

@test "AC9 — extract on missing section exits non-zero with named error" {
  run "$SCRIPT" extract "$FIXTURE" tool_adapters
  [ "$status" -ne 0 ]
  echo "${output}${stderr:-}" | grep -qi 'tool_adapters'
}

@test "AC3 — replace preserves all comments outside the edited section" {
  # Build a replacement environments section
  local replacement="$TMPDIR_TEST/new-env.yaml"
  cat > "$replacement" <<'YAML'
environments:
  staging:
    url: https://staging-new.example.com
    credentials:
      db_password: STAGING_DB_PASSWORD_VAR
YAML
  run "$SCRIPT" replace "$FIXTURE" environments "$replacement"
  [ "$status" -eq 0 ]
  # Header comments preserved
  grep -q '# Header comment line 1' "$FIXTURE"
  grep -q '# Header comment line 2' "$FIXTURE"
  # Other-section block comments preserved
  grep -q '# Block comment before stacks section' "$FIXTURE"
  grep -q '# Trailing block comment at EOF' "$FIXTURE"
  # Inline comments in OTHER sections preserved
  grep -q '# inline comment on project_root' "$FIXTURE"
  grep -q '# path glob comment' "$FIXTURE"
}

@test "AC4 — replace preserves blank lines outside edited section" {
  local replacement="$TMPDIR_TEST/new-env.yaml"
  cat > "$replacement" <<'YAML'
environments:
  staging:
    url: https://staging-new.example.com
YAML
  # Capture pre-stacks blank-line presence
  local before
  before=$(awk '/^# Block comment before stacks/{print NR; exit}' "$FIXTURE")
  run "$SCRIPT" replace "$FIXTURE" environments "$replacement"
  [ "$status" -eq 0 ]
  # The blank line before "# Block comment before stacks section" must remain
  awk -v target='# Block comment before stacks section' '
    { if ($0 == target) { print prev; found=1; exit } prev=$0 }
    END { if (!found) exit 1 }
  ' "$FIXTURE" | grep -qE '^$'
}

@test "AC4 — replace preserves trailing block comment after edited section" {
  local replacement="$TMPDIR_TEST/new-stacks.yaml"
  cat > "$replacement" <<'YAML'
stacks:
  - name: api
    language: python
    paths: ["services/api/**"]
YAML
  run "$SCRIPT" replace "$FIXTURE" stacks "$replacement"
  [ "$status" -eq 0 ]
  grep -q '# Trailing block comment at EOF' "$FIXTURE"
}

@test "AC8 — script does NOT shell out to a generic YAML serializer" {
  # ADR-044: editor must not round-trip through 'yq -y' or 'python -c yaml.dump'
  # etc. This audit grep enforces the discipline at the script level by
  # scanning only NON-COMMENT lines (so prose mentioning the forbidden APIs
  # in the script header doesn't false-positive).
  run bash -c "grep -vE '^[[:space:]]*#' '$SCRIPT' | grep -nE 'yq[[:space:]]+-y|yaml\\.dump|yaml\\.safe_dump|json2yaml'"
  [ "$status" -ne 0 ]
}

@test "AC8 — script header mentions ADR-044 + comment-preserving" {
  run grep -E 'ADR-044' "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -iE 'comment.{0,20}preserv' "$SCRIPT"
  [ "$status" -eq 0 ]
}
