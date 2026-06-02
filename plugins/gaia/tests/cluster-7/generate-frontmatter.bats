#!/usr/bin/env bats
# generate-frontmatter.bats — E63-S3 / Work Item 6.1
#
# Verifies the deterministic contract of
# gaia-public/plugins/gaia/skills/gaia-create-story/scripts/generate-frontmatter.sh.
#
# Test scenarios trace back to the story Test Scenarios table:
#   #1 Happy path — 15 fields populated         (AC1)
#   #2 Sizing_map override M=3                  (AC2)
#   #3 Empty-array defaults                     (AC3)
#   #4 Malformed input — missing size           (AC4)
#   #5 Malformed input — missing title          (AC4)
#   #6 Origin flags populated                   (AC6)
#   #7 Origin flags omitted                     (AC6)
#   #9 Unknown size value                       (AC4)
#   header invariants — shebang, set -euo pipefail, LC_ALL=C, mode 0755

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SKILLS_DIR/gaia-create-story/scripts/generate-frontmatter.sh"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures"
}
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC1 — 15 fields populated (happy path)
# ---------------------------------------------------------------------------

@test "AC1: happy path emits all 15 required fields and exits 0 (Scenario 1)" {
  run "$SCRIPT" \
    --story-key E99-S1 \
    --epics-file "$FIXTURES/epics-frontmatter-happy.md" \
    --project-config "$FIXTURES/project-config-frontmatter-default.yaml"
  [ "$status" -eq 0 ]
  # 15 required fields per story-template.md
  [[ "$output" == *"key: \"E99-S1\""* ]]
  [[ "$output" == *"title: \"Happy path frontmatter generation\""* ]]
  [[ "$output" == *"epic: \"E99\""* ]]
  [[ "$output" == *"status: backlog"* ]]
  [[ "$output" == *"priority: \"P1\""* ]]
  [[ "$output" == *"size: \"M\""* ]]
  [[ "$output" == *"points: 5"* ]]
  [[ "$output" == *"risk: \"medium\""* ]]
  [[ "$output" == *"sprint_id: null"* ]]
  [[ "$output" == *"priority_flag: null"* ]]
  [[ "$output" == *"origin: null"* ]]
  [[ "$output" == *"origin_ref: null"* ]]
  [[ "$output" == *"depends_on:"* ]]
  [[ "$output" == *"blocks:"* ]]
  [[ "$output" == *"traces_to:"* ]]
  [[ "$output" == *"date:"* ]]
  [[ "$output" == *"author:"* ]]
}

@test "AC1: happy path emits opening and closing YAML delimiters" {
  run "$SCRIPT" \
    --story-key E99-S1 \
    --epics-file "$FIXTURES/epics-frontmatter-happy.md" \
    --project-config "$FIXTURES/project-config-frontmatter-default.yaml"
  [ "$status" -eq 0 ]
  # Must contain opening --- on its own line and closing --- on its own line.
  # Use awk (rather than grep -Fxq '---') because BSD grep on macOS treats the
  # literal `---` token as an unknown flag.
  printf '%s\n' "$output" | awk '$0=="---"{found=1} END{exit !found}'
}

@test "AC1: happy path parses depends_on as a YAML flow array" {
  run "$SCRIPT" \
    --story-key E99-S1 \
    --epics-file "$FIXTURES/epics-frontmatter-happy.md" \
    --project-config "$FIXTURES/project-config-frontmatter-default.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"depends_on: [\"E99-S0\", \"E10-S2\"]"* ]]
  [[ "$output" == *"blocks: [\"E99-S2\"]"* ]]
}

# ---------------------------------------------------------------------------
# AC2 — sizing_map override
# ---------------------------------------------------------------------------

@test "AC2: sizing_map override M=3 emits points: 3 (not 5) (Scenario 2)" {
  run "$SCRIPT" \
    --story-key E99-S1 \
    --epics-file "$FIXTURES/epics-frontmatter-happy.md" \
    --project-config "$FIXTURES/project-config-frontmatter-override.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"points: 3"* ]]
  ! [[ "$output" == *"points: 5"* ]]
}

# ---------------------------------------------------------------------------
# AC3 — empty-array defaults
# ---------------------------------------------------------------------------

@test "AC3: missing depends_on/blocks/traces_to render as [] (Scenario 3)" {
  run "$SCRIPT" \
    --story-key E99-S1 \
    --epics-file "$FIXTURES/epics-frontmatter-empty-arrays.md" \
    --project-config "$FIXTURES/project-config-frontmatter-default.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"depends_on: []"* ]]
  [[ "$output" == *"blocks: []"* ]]
  [[ "$output" == *"traces_to: []"* ]]
}

# ---------------------------------------------------------------------------
# AC4 — malformed input error path
# ---------------------------------------------------------------------------

@test "AC4: missing **Size:** line exits 1 with stderr naming size and key (Scenario 4)" {
  run "$SCRIPT" \
    --story-key E99-S1 \
    --epics-file "$FIXTURES/epics-frontmatter-malformed-no-size.md" \
    --project-config "$FIXTURES/project-config-frontmatter-default.yaml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing field 'size'"* ]]
  [[ "$output" == *"E99-S1"* ]]
}

@test "AC4: missing **Size:** emits no partial frontmatter on stdout" {
  # Capture stdout and stderr separately by running through a wrapper.
  out="$("$SCRIPT" \
    --story-key E99-S1 \
    --epics-file "$FIXTURES/epics-frontmatter-malformed-no-size.md" \
    --project-config "$FIXTURES/project-config-frontmatter-default.yaml" \
    2>/dev/null || true)"
  [ -z "$out" ]
}

@test "AC4: missing title in heading exits 1 with stderr naming title (Scenario 5)" {
  run "$SCRIPT" \
    --story-key E99-S1 \
    --epics-file "$FIXTURES/epics-frontmatter-malformed-no-title.md" \
    --project-config "$FIXTURES/project-config-frontmatter-default.yaml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing field 'title'"* ]]
}

# ---------------------------------------------------------------------------
# AC6 — origin flags
# ---------------------------------------------------------------------------

@test "AC6: --origin and --origin-ref populate frontmatter (Scenario 6)" {
  run "$SCRIPT" \
    --story-key E99-S1 \
    --epics-file "$FIXTURES/epics-frontmatter-happy.md" \
    --project-config "$FIXTURES/project-config-frontmatter-default.yaml" \
    --origin AF-2026-04-28-7 \
    --origin-ref "Work Item 6.1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"origin: \"AF-2026-04-28-7\""* ]]
  [[ "$output" == *"origin_ref: \"Work Item 6.1\""* ]]
}

@test "AC6: omitted origin flags emit null (Scenario 7)" {
  run "$SCRIPT" \
    --story-key E99-S1 \
    --epics-file "$FIXTURES/epics-frontmatter-happy.md" \
    --project-config "$FIXTURES/project-config-frontmatter-default.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"origin: null"* ]]
  [[ "$output" == *"origin_ref: null"* ]]
}

# ---------------------------------------------------------------------------
# AC4 — story key not found in epics-file
# ---------------------------------------------------------------------------

@test "AC4: nonexistent story key exits non-zero" {
  run "$SCRIPT" \
    --story-key E99-S999 \
    --epics-file "$FIXTURES/epics-frontmatter-happy.md" \
    --project-config "$FIXTURES/project-config-frontmatter-default.yaml"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC4 — usage errors (missing required flags)
# ---------------------------------------------------------------------------

@test "Usage: missing --story-key exits non-zero" {
  run "$SCRIPT" \
    --epics-file "$FIXTURES/epics-frontmatter-happy.md" \
    --project-config "$FIXTURES/project-config-frontmatter-default.yaml"
  [ "$status" -ne 0 ]
}

@test "Usage: missing --epics-file exits non-zero" {
  run "$SCRIPT" \
    --story-key E99-S1 \
    --project-config "$FIXTURES/project-config-frontmatter-default.yaml"
  [ "$status" -ne 0 ]
}

@test "Usage: missing --project-config exits non-zero" {
  run "$SCRIPT" \
    --story-key E99-S1 \
    --epics-file "$FIXTURES/epics-frontmatter-happy.md"
  [ "$status" -ne 0 ]
}

@test "Usage: unknown flag exits non-zero" {
  run "$SCRIPT" \
    --story-key E99-S1 \
    --epics-file "$FIXTURES/epics-frontmatter-happy.md" \
    --project-config "$FIXTURES/project-config-frontmatter-default.yaml" \
    --unknown-flag bogus
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Header invariants
# ---------------------------------------------------------------------------

@test "Header: script exists at canonical path" {
  [ -f "$SCRIPT" ]
}

@test "Header: script is executable (mode 0755)" {
  [ -x "$SCRIPT" ]
  local mode
  if mode="$(stat -f '%Lp' "$SCRIPT" 2>/dev/null)"; then
    :
  else
    mode="$(stat -c '%a' "$SCRIPT")"
  fi
  [ "$mode" = "755" ]
}

@test "Header: script begins with #!/usr/bin/env bash" {
  run head -n1 "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "#!/usr/bin/env bash" ]
}

@test "Header: script sets 'set -euo pipefail'" {
  run grep -E '^set -euo pipefail' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "Header: script sets 'LC_ALL=C'" {
  run grep -E '^LC_ALL=C|^export LC_ALL' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# DoD: no hardcoded sizing constants
# ---------------------------------------------------------------------------

@test "DoD: no hardcoded S=2 / M=5 / L=8 / XL=13 sizing constants" {
  [ -f "$SCRIPT" ]
  run grep -nE '(^|[^A-Za-z_])(S=2|M=5|L=8|XL=13)([^0-9]|$)' "$SCRIPT"
  # Status 1 = "no matches found" (clean). Status 2 = error (e.g. missing file)
  # would also pass `-ne 0` but the file-exists guard above prevents that.
  [ "$status" -eq 1 ]
}

@test "DoD: no direct reads of global.yaml or project-config.yaml as pipeline targets" {
  [ -f "$SCRIPT" ]
  # The script must not open these files directly — config flows through
  # resolve-config.sh. We allow doc/usage references and the --project-config
  # flag passthrough; we forbid `cat`/`grep`/`sed`/`awk`/`yq`/`head`/`tail`
  # invoked directly on the literal config filenames.
  run grep -nE '(cat|grep|sed|awk|yq|head|tail)[^|]*(global\.yaml|project-config\.yaml)' "$SCRIPT"
  [ "$status" -eq 1 ]
}
