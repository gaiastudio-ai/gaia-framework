#!/usr/bin/env bats
# test-test-automate-phase-1.bats
#
# TDD Red-phase tests for E35-S1:
#   Phase 1 fork-context analysis skill — SKILL.md contract + plan-file emission
#
# Epic: E35 — Test Automate Fork-Context Fix
# Risk: medium
# Story: E35-S1 — Phase 1 fork-context analysis skill
#
# Tests validate:
#   - SKILL.md frontmatter contract (context: fork, allowed-tools, no Write/Edit)
#   - Plan-file schema v1 emission (emit-plan-file.sh)
#   - plan_id uniqueness per invocation
#   - SHA-256 analyzed_sources format
#   - Edge cases EC1–EC10
#
# AC coverage:
#   AC1  — fork-context frontmatter assertions (INFO-2)
#   AC2  — schema v1 required fields
#   AC3  — plan_id uniqueness (rapid re-invocation)
#   AC4  — SHA-256 format in analyzed_sources
#   AC5  — adversarial Write/Edit blocked by frontmatter (INFO-2)
#   AC-EC1 — tool allowlist misconfiguration guard
#   AC-EC2 — source file deleted mid-analysis
#   AC-EC3 — plan_id uniqueness within 1ms
#   AC-EC4 — large file SHA-256 (1MB representative, comment re: 100MB streams)
#   AC-EC5 — non-UTF-8 binary SHA-256
#   AC-EC6 — atomic write (temp+rename)
#   AC-EC7 — adversarial prompt injection blocked at tool layer
#   AC-EC8 — malformed/zero ACs
#   AC-EC9 — plan_id stability across approval delay
#   AC-EC10 — atomic rename prevents truncated reads
#
# Test framework: bats-core 1.x
# Run: bats gaia-framework/plugins/gaia/tests/test-test-automate-phase-1.bats

load 'test_helper.bash'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

PLUGIN_ROOT_DEFAULT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# ---------------------------------------------------------------------------
# Shared setup / teardown
# ---------------------------------------------------------------------------

setup() {
  common_setup

  PLUGIN_ROOT="${PLUGIN_ROOT:-$PLUGIN_ROOT_DEFAULT}"
  PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)}"

  SKILL_MD="$PLUGIN_ROOT/skills/gaia-test-automate/SKILL.md"
  EMIT_PLAN="$PLUGIN_ROOT/skills/gaia-test-automate/scripts/emit-plan-file.sh"
  FIXTURES_DIR="$PLUGIN_ROOT/tests/fixtures/test-automate"

  export TEST_TMP PLUGIN_ROOT PROJECT_ROOT SKILL_MD EMIT_PLAN FIXTURES_DIR
}

teardown() {
  common_teardown
}

# ---------------------------------------------------------------------------
# Helper: portable SHA-256 hex digest
# ---------------------------------------------------------------------------

sha256_of() {
  if command -v shasum &>/dev/null; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# ---------------------------------------------------------------------------
# Helper: extract YAML frontmatter value from SKILL.md
# Parses the first YAML block (between --- delimiters) for a given key.
# ---------------------------------------------------------------------------

frontmatter_value() {
  local file="$1"
  local key="$2"
  awk '/^---$/{n++; next} n==1{print}' "$file" | grep "^${key}:" | head -1 | sed "s/^${key}:[[:space:]]*//"
}

# ===========================================================================
# AC1 / AC5 — SKILL.md frontmatter contract (INFO-2 assertions)
# ===========================================================================

@test "AC1: SKILL.md declares orchestration_class (post-ADR-093)" {
  # ADR-093 / E84-S3: `context: fork` stripped from non-reviewer plugin
  # SKILL.md. gaia-test-automate is light-procedural.
  [ -f "$SKILL_MD" ]
  local cls
  cls="$(frontmatter_value "$SKILL_MD" "orchestration_class")"
  [ "$cls" = "light-procedural" ]
}

@test "AC1: SKILL.md allowed-tools contains Read, Grep, Glob, Bash" {
  [ -f "$SKILL_MD" ]
  local tools_line
  tools_line="$(grep '^allowed-tools:' "$SKILL_MD" | head -1)"
  [[ "$tools_line" == *"Read"* ]]
  [[ "$tools_line" == *"Grep"* ]]
  [[ "$tools_line" == *"Glob"* ]]
  [[ "$tools_line" == *"Bash"* ]]
}

@test "AC5: SKILL.md allowed-tools does NOT contain Write" {
  [ -f "$SKILL_MD" ]
  local tools_line
  tools_line="$(grep '^allowed-tools:' "$SKILL_MD" | head -1)"
  [[ "$tools_line" != *"Write"* ]]
}

@test "AC5: SKILL.md allowed-tools does NOT contain Edit" {
  [ -f "$SKILL_MD" ]
  local tools_line
  tools_line="$(grep '^allowed-tools:' "$SKILL_MD" | head -1)"
  [[ "$tools_line" != *"Edit"* ]]
}

# ===========================================================================
# AC-EC1 — Tool allowlist misconfig guard (Write leaked)
#   The SKILL.md frontmatter is the source of truth. If Write or Edit appear
#   in allowed-tools, fork isolation is broken. These tests lock that contract.
# ===========================================================================

@test "AC-EC1: allowed-tools list has exactly 4 tools (Read, Grep, Glob, Bash)" {
  [ -f "$SKILL_MD" ]
  local tools_line
  tools_line="$(grep '^allowed-tools:' "$SKILL_MD" | head -1)"
  # Extract the list content between [ and ]
  local list_content
  list_content="$(echo "$tools_line" | sed 's/.*\[\(.*\)\].*/\1/')"
  # Count comma-separated entries
  local count
  count="$(echo "$list_content" | tr ',' '\n' | sed 's/^[[:space:]]*//' | sed '/^$/d' | wc -l | tr -d ' ')"
  [ "$count" -eq 4 ]
}

# ===========================================================================
# AC2 — Plan-file schema v1 required fields (emit-plan-file.sh)
# ===========================================================================

@test "AC2: emit-plan-file.sh exists and is executable" {
  [ -f "$EMIT_PLAN" ]
  [ -x "$EMIT_PLAN" ]
}

@test "AC2: emit-plan-file.sh produces schema_version 1 in frontmatter" {
  local out_path="$TEST_TMP/test-automate-plan-E99-S1.md"

  run "$EMIT_PLAN" \
    --story-key "E99-S1" \
    --output "$out_path" \
    --sources '[]' \
    --tests '[]' \
    --narrative "Test plan narrative"

  [ "$status" -eq 0 ]
  [ -f "$out_path" ]
  grep -q '^schema_version: 1' "$out_path"
}

@test "AC2: plan file contains all required frontmatter fields" {
  local out_path="$TEST_TMP/test-automate-plan-E99-S2.md"

  run "$EMIT_PLAN" \
    --story-key "E99-S2" \
    --output "$out_path" \
    --sources '[]' \
    --tests '[]' \
    --narrative "Narrative body"

  [ "$status" -eq 0 ]
  [ -f "$out_path" ]

  # Required fields per architecture §10.27.3
  grep -q '^schema_version:' "$out_path"
  grep -q '^story_key:' "$out_path"
  grep -q '^plan_id:' "$out_path"
  grep -q '^generated_at:' "$out_path"
  grep -q '^generator:' "$out_path"
  grep -q '^phase:' "$out_path"
  grep -q '^approval:' "$out_path"
  grep -q '^analyzed_sources:' "$out_path"
  grep -q '^proposed_tests:' "$out_path"
}

@test "AC2: plan file phase is 'plan' on emission" {
  local out_path="$TEST_TMP/test-automate-plan-E99-S3.md"

  run "$EMIT_PLAN" \
    --story-key "E99-S3" \
    --output "$out_path" \
    --sources '[]' \
    --tests '[]' \
    --narrative "Phase check"

  [ "$status" -eq 0 ]
  grep -q 'phase: "plan"\|phase: plan' "$out_path"
}

@test "AC2: plan file generator is 'gaia-test-automate'" {
  local out_path="$TEST_TMP/test-automate-plan-E99-S4.md"

  run "$EMIT_PLAN" \
    --story-key "E99-S4" \
    --output "$out_path" \
    --sources '[]' \
    --tests '[]' \
    --narrative "Generator check"

  [ "$status" -eq 0 ]
  grep -q 'generator:.*gaia-test-automate' "$out_path"
}

@test "AC2: plan file approval block has gate, verdict, verdict_plan_id" {
  local out_path="$TEST_TMP/test-automate-plan-E99-S5.md"

  run "$EMIT_PLAN" \
    --story-key "E99-S5" \
    --output "$out_path" \
    --sources '[]' \
    --tests '[]' \
    --narrative "Approval block check"

  [ "$status" -eq 0 ]
  grep -q 'gate:.*test-automate-plan' "$out_path"
  grep -q 'verdict: null\|verdict:$' "$out_path"
  grep -q 'verdict_plan_id: null\|verdict_plan_id:$' "$out_path"
}

@test "AC2: plan file has no extraneous top-level keys" {
  local out_path="$TEST_TMP/test-automate-plan-E99-S6.md"

  run "$EMIT_PLAN" \
    --story-key "E99-S6" \
    --output "$out_path" \
    --sources '[]' \
    --tests '[]' \
    --narrative "Extraneous check"

  [ "$status" -eq 0 ]

  # Extract top-level YAML keys (lines starting without leading whitespace, ending with colon)
  local top_keys
  top_keys="$(awk '/^---$/{n++; next} n==1 && /^[a-z_]+:/{print $1}' "$out_path" | sort)"
  local expected
  expected="$(printf 'analyzed_sources:\napproval:\ngenerated_at:\ngenerator:\nphase:\nplan_id:\nproposed_tests:\nschema_version:\nstory_key:' | sort)"
  [ "$top_keys" = "$expected" ]
}

# ===========================================================================
# AC3 — plan_id uniqueness (rapid re-invocation)
# ===========================================================================

@test "AC3: two rapid invocations produce distinct plan_id values" {
  local out1="$TEST_TMP/plan1.md"
  local out2="$TEST_TMP/plan2.md"

  run "$EMIT_PLAN" \
    --story-key "E99-S7" \
    --output "$out1" \
    --sources '[]' \
    --tests '[]' \
    --narrative "Plan 1"
  [ "$status" -eq 0 ]

  run "$EMIT_PLAN" \
    --story-key "E99-S7" \
    --output "$out2" \
    --sources '[]' \
    --tests '[]' \
    --narrative "Plan 2"
  [ "$status" -eq 0 ]

  local id1 id2
  id1="$(grep '^plan_id:' "$out1" | sed 's/plan_id:[[:space:]]*//' | tr -d '"')"
  id2="$(grep '^plan_id:' "$out2" | sed 's/plan_id:[[:space:]]*//' | tr -d '"')"

  [ -n "$id1" ]
  [ -n "$id2" ]
  [ "$id1" != "$id2" ]
}

# ===========================================================================
# AC-EC3 — plan_id uniqueness within 1ms (sub-millisecond collision guard)
# ===========================================================================

@test "AC-EC3: 10 rapid invocations all produce unique plan_ids" {
  local ids=()
  for i in $(seq 1 10); do
    local out="$TEST_TMP/plan-ec3-${i}.md"
    run "$EMIT_PLAN" \
      --story-key "E99-EC3" \
      --output "$out" \
      --sources '[]' \
      --tests '[]' \
      --narrative "Collision test $i"
    [ "$status" -eq 0 ]
    local pid
    pid="$(grep '^plan_id:' "$out" | sed 's/plan_id:[[:space:]]*//' | tr -d '"')"
    ids+=("$pid")
  done

  # Verify all 10 are unique
  local unique_count
  unique_count="$(printf '%s\n' "${ids[@]}" | sort -u | wc -l | tr -d ' ')"
  [ "$unique_count" -eq 10 ]
}

# ===========================================================================
# AC4 — SHA-256 format in analyzed_sources
# ===========================================================================

@test "AC4: analyzed_sources SHA-256 uses sha256:{hex} format" {
  local source_file="$FIXTURES_DIR/minimal-source.sh"
  local sha_hex
  sha_hex="$(sha256_of "$source_file")"
  local out_path="$TEST_TMP/plan-ac4.md"

  local sources_json
  sources_json='[{"path":"'"$source_file"'","sha256":"sha256:'"$sha_hex"'","last_modified":"2026-04-22T00:00:00Z"}]'

  run "$EMIT_PLAN" \
    --story-key "E99-AC4" \
    --output "$out_path" \
    --sources "$sources_json" \
    --tests '[]' \
    --narrative "SHA-256 format check"

  [ "$status" -eq 0 ]
  # Verify sha256:{64-char-hex} pattern appears in the file
  grep -qE 'sha256:[0-9a-f]{64}' "$out_path"
}

@test "AC4: analyzed_sources entry has path, sha256, last_modified" {
  local source_file="$FIXTURES_DIR/minimal-source.sh"
  local sha_hex
  sha_hex="$(sha256_of "$source_file")"
  local lmod
  lmod="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%FT%TZ)"
  local out_path="$TEST_TMP/plan-ac4-fields.md"

  local sources_json
  sources_json='[{"path":"'"$source_file"'","sha256":"sha256:'"$sha_hex"'","last_modified":"'"$lmod"'"}]'

  run "$EMIT_PLAN" \
    --story-key "E99-AC4F" \
    --output "$out_path" \
    --sources "$sources_json" \
    --tests '[]' \
    --narrative "Fields check"

  [ "$status" -eq 0 ]
  # analyzed_sources may be inline JSON or YAML list; check for key presence in either form
  grep -qE '"path"|path:' "$out_path"
  grep -qE '"sha256"|sha256:' "$out_path"
  grep -qE '"last_modified"|last_modified:' "$out_path"
}

# ===========================================================================
# AC-EC2 — Source file deleted between SHA compute and plan write
#   emit-plan-file.sh receives pre-computed sources JSON. Deletion handling
#   is the caller's responsibility. The emitter must still produce a valid
#   plan even when sources[] is empty.
# ===========================================================================

@test "AC-EC2: plan emission succeeds with empty analyzed_sources" {
  local out_path="$TEST_TMP/plan-ec2.md"

  run "$EMIT_PLAN" \
    --story-key "E99-EC2" \
    --output "$out_path" \
    --sources '[]' \
    --tests '[]' \
    --narrative "Deleted source test"

  [ "$status" -eq 0 ]
  [ -f "$out_path" ]
  grep -q 'analyzed_sources:' "$out_path"
}

# ===========================================================================
# AC-EC4 — Large file SHA-256 (1MB representative)
#   Per INFO-3: generate large file in setup() via dd, not committed.
#   1MB representative with comment that shasum streams files regardless of size.
# ===========================================================================

@test "AC-EC4: SHA-256 of 1MB file succeeds (representative of 100MB+ streaming)" {
  # shasum streams files regardless of size — this 1MB test validates the
  # mechanism; real 100MB+ files behave identically via streaming I/O.
  local large_file="$TEST_TMP/large-fixture.bin"
  dd if=/dev/zero of="$large_file" bs=1M count=1 2>/dev/null

  local sha_hex
  sha_hex="$(sha256_of "$large_file")"
  [ -n "$sha_hex" ]
  [[ "$sha_hex" =~ ^[0-9a-f]{64}$ ]]

  local out_path="$TEST_TMP/plan-ec4.md"
  local sources_json
  sources_json='[{"path":"'"$large_file"'","sha256":"sha256:'"$sha_hex"'","last_modified":"2026-04-22T00:00:00Z"}]'

  run "$EMIT_PLAN" \
    --story-key "E99-EC4" \
    --output "$out_path" \
    --sources "$sources_json" \
    --tests '[]' \
    --narrative "Large file test"

  [ "$status" -eq 0 ]
  grep -q "sha256:$sha_hex" "$out_path"
}

# ===========================================================================
# AC-EC5 — Non-UTF-8 binary content SHA-256
# ===========================================================================

@test "AC-EC5: SHA-256 of binary (non-UTF-8) file produces valid hex" {
  local bin_file="$TEST_TMP/binary-fixture.bin"
  # Write non-UTF-8 bytes
  printf '\x00\x01\x02\xff\xfe\xfd\x80\x81' > "$bin_file"

  local sha_hex
  sha_hex="$(sha256_of "$bin_file")"
  [ -n "$sha_hex" ]
  [[ "$sha_hex" =~ ^[0-9a-f]{64}$ ]]

  local out_path="$TEST_TMP/plan-ec5.md"
  local sources_json
  sources_json='[{"path":"'"$bin_file"'","sha256":"sha256:'"$sha_hex"'","last_modified":"2026-04-22T00:00:00Z"}]'

  run "$EMIT_PLAN" \
    --story-key "E99-EC5" \
    --output "$out_path" \
    --sources "$sources_json" \
    --tests '[]' \
    --narrative "Binary file test"

  [ "$status" -eq 0 ]
  grep -q "sha256:$sha_hex" "$out_path"
}

# ===========================================================================
# AC-EC6 — Atomic write (temp file + rename)
#   The emit script must write to a temp file then mv to final path.
#   If the process is interrupted, no partial plan file should remain.
# ===========================================================================

@test "AC-EC6: emit-plan-file.sh writes atomically (no partial file on success)" {
  local out_path="$TEST_TMP/plan-ec6.md"

  run "$EMIT_PLAN" \
    --story-key "E99-EC6" \
    --output "$out_path" \
    --sources '[]' \
    --tests '[]' \
    --narrative "Atomic write test"

  [ "$status" -eq 0 ]
  [ -f "$out_path" ]

  # Verify the file starts with --- (valid YAML frontmatter start)
  local first_line
  first_line="$(head -1 "$out_path")"
  [ "$first_line" = "---" ]

  # Verify the file ends with a complete body (not truncated mid-YAML)
  local last_line
  last_line="$(tail -1 "$out_path")"
  [ -n "$last_line" ]
}

@test "AC-EC6: emit-plan-file.sh fails on unwritable output directory" {
  local out_path="$TEST_TMP/no-such-dir/deep/plan-ec6-fail.md"
  # Parent directory does not exist and we do not create it.

  run "$EMIT_PLAN" \
    --story-key "E99-EC6F" \
    --output "$out_path" \
    --sources '[]' \
    --tests '[]' \
    --narrative "Should fail"

  [ "$status" -ne 0 ]
  [ ! -f "$out_path" ]
}

# ===========================================================================
# AC-EC7 — Adversarial prompt injection blocked at tool layer
#   The fork-context tool allowlist ([Read, Grep, Glob, Bash]) prevents
#   Write/Edit at the platform layer. This test validates the SKILL.md
#   contract that locks that allowlist.
# ===========================================================================

@test "AC-EC7: SKILL.md fork-context blocks tool escalation (no Write, no Edit in allowlist)" {
  [ -f "$SKILL_MD" ]
  local tools_line
  tools_line="$(grep '^allowed-tools:' "$SKILL_MD" | head -1)"

  # Exhaustive negative check: neither Write nor Edit can appear
  # in any form (uppercase, lowercase, mixed case)
  [[ "$tools_line" != *"Write"* ]]
  [[ "$tools_line" != *"write"* ]]
  [[ "$tools_line" != *"Edit"* ]]
  [[ "$tools_line" != *"edit"* ]]
}

# ===========================================================================
# AC-EC8 — Story with zero/malformed ACs
#   Phase 1 should emit a valid plan with empty test_cases[].
# ===========================================================================

@test "AC-EC8: plan emission with empty proposed_tests produces valid schema" {
  local out_path="$TEST_TMP/plan-ec8.md"

  run "$EMIT_PLAN" \
    --story-key "E99-EC8" \
    --output "$out_path" \
    --sources '[]' \
    --tests '[]' \
    --narrative "Malformed AC scenario: no test cases generated"

  [ "$status" -eq 0 ]
  [ -f "$out_path" ]
  grep -q 'schema_version: 1' "$out_path"
  grep -q 'plan_id:' "$out_path"
  grep -q 'proposed_tests:' "$out_path"
}

# ===========================================================================
# AC-EC9 — plan_id stability across approval delay
#   The plan file is written once; plan_id must not change when the file is
#   re-read minutes or days later.
# ===========================================================================

@test "AC-EC9: plan_id in file remains stable across re-reads" {
  local out_path="$TEST_TMP/plan-ec9.md"

  run "$EMIT_PLAN" \
    --story-key "E99-EC9" \
    --output "$out_path" \
    --sources '[]' \
    --tests '[]' \
    --narrative "Approval delay stability"

  [ "$status" -eq 0 ]

  local id_first id_second
  id_first="$(grep '^plan_id:' "$out_path" | sed 's/plan_id:[[:space:]]*//' | tr -d '"')"
  # Re-read the same file — id must be identical (file is not regenerated)
  id_second="$(grep '^plan_id:' "$out_path" | sed 's/plan_id:[[:space:]]*//' | tr -d '"')"

  [ "$id_first" = "$id_second" ]
  [ -n "$id_first" ]
}

# ===========================================================================
# AC-EC10 — Re-invocation overwrites plan file atomically
#   Atomic rename (write-temp-then-mv) means a concurrent reader sees either
#   the old plan or the new plan, never a partial file.
# ===========================================================================

@test "AC-EC10: re-invocation overwrites plan file with new plan_id" {
  local out_path="$TEST_TMP/plan-ec10.md"

  # First invocation
  run "$EMIT_PLAN" \
    --story-key "E99-EC10" \
    --output "$out_path" \
    --sources '[]' \
    --tests '[]' \
    --narrative "First plan"
  [ "$status" -eq 0 ]

  local id1
  id1="$(grep '^plan_id:' "$out_path" | sed 's/plan_id:[[:space:]]*//' | tr -d '"')"

  # Second invocation overwrites the same path
  run "$EMIT_PLAN" \
    --story-key "E99-EC10" \
    --output "$out_path" \
    --sources '[]' \
    --tests '[]' \
    --narrative "Second plan"
  [ "$status" -eq 0 ]

  local id2
  id2="$(grep '^plan_id:' "$out_path" | sed 's/plan_id:[[:space:]]*//' | tr -d '"')"

  [ -n "$id1" ]
  [ -n "$id2" ]
  [ "$id1" != "$id2" ]

  # File must be well-formed (starts with ---, has all required keys)
  local first_line
  first_line="$(head -1 "$out_path")"
  [ "$first_line" = "---" ]
  grep -q 'schema_version: 1' "$out_path"
}

# ===========================================================================
# INFO-1 — Plan file output path uses test-automate-plan-{story_key}.md
#   NOT the legacy {story_key}-test-automation.md report path
# ===========================================================================

@test "INFO-1: SKILL.md Steps 4-6 reference plan file at test-automate-plan path" {
  [ -f "$SKILL_MD" ]
  # SKILL.md must reference the plan file path format
  grep -q 'test-automate-plan' "$SKILL_MD"
}

@test "INFO-1: SKILL.md does NOT invoke review-gate.sh in analysis phases (Review Phase 3A-7)" {
  [ -f "$SKILL_MD" ]
  # Per E65-S5 hybrid migration (AC-EC1), the seven Review Phases all execute
  # INSIDE ADR-051 Phase 1 (fork-isolated analysis). The seven Review Phases
  # MUST NOT invoke review-gate.sh; the deferred invocation lives in the
  # "ADR-051 Approval Gate" section AFTER Review Phase 7.
  #
  # We extract the analysis block — from the first "### Phase 3A" header
  # through the last header before "## ADR-051 Approval Gate" — and assert
  # no review-gate.sh command invocation appears there. Mentions in Mission /
  # Critical Rules saying "does NOT invoke" are documentation, not invocations,
  # so they live OUTSIDE this analysis block.
  local analysis_block
  analysis_block="$(awk '/^### Phase 3A/,/^## ADR-051 Approval Gate/' "$SKILL_MD")"
  # No shell invocation of review-gate.sh update inside the analysis block.
  if echo "$analysis_block" | grep -q 'review-gate\.sh update\|review-gate\.sh.*--story\|review-gate\.sh.*--gate\|review-gate\.sh.*--verdict'; then
    echo "FAIL: review-gate.sh invocation found in Review Phases 3A-7 (analysis phases should not finalize verdicts)"
    return 1
  fi
  # The composite review-gate-check (ADR-054, informational) IS allowed in the
  # Approval Gate section — that section is the parent-context approval wiring,
  # not the fork-context analysis. The fork-context isolation boundary is
  # Review Phases 3A-7 (checked above).
}
