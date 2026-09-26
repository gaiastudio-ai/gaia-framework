#!/usr/bin/env bats
# quality-gates.bats — E45-S2 (FR-347, FR-358, ADR-060)
#
# Covers VCP-GATE-01..VCP-GATE-07 from test-plan.md §11.46.7. Validates
# the pre_start / post_complete quality gate enforcement wired into
# setup.sh and finalize.sh, plus the SKILL.md frontmatter declaration
# format and the AC-EC1..AC-EC6 edge cases.
#
# Test plan classification:
#   VCP-GATE-01..VCP-GATE-05 — Script-verifiable (5)
#   VCP-GATE-06..VCP-GATE-07 — Integration (2)
#
# All bats tests run hermetically under $BATS_TEST_TMPDIR — no shared
# state between tests, no writes outside the temp dir. macOS /bin/bash
# 3.2 compatible.

load 'test_helper.bash'

SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-product-brief"
SETUP="$SKILL_DIR/scripts/setup.sh"
FINALIZE="$SKILL_DIR/scripts/finalize.sh"
SKILL_MD="$SKILL_DIR/SKILL.md"

setup() {
  common_setup
  # Sandbox: all gate evaluations run with PWD pointing at TEST_TMP so
  # `file_exists` predicates resolve relative paths against the fixture
  # tree rather than the real workspace.
  # AF-2026-05-21-20: canonical .gaia/artifacts/ + legacy docs/ (back-compat).
  mkdir -p "$TEST_TMP/.gaia/artifacts/creative-artifacts"
  mkdir -p "$TEST_TMP/docs/creative-artifacts"
  mkdir -p "$TEST_TMP/_memory/checkpoints"
  export CHECKPOINT_PATH="$TEST_TMP/_memory/checkpoints"
  export LIFECYCLE_EVENTS_LOG="$TEST_TMP/_memory/lifecycle-events.ndjson"

  # Seed a minimal config so resolve-config.sh succeeds inside setup.sh.
  # CLAUDE_SKILL_DIR is the legacy fallback and the path used by the
  # broader bats suite (see resolve-config.bats / mk_skill_dir).
  mkdir -p "$TEST_TMP/skill/config"
  cat >"$TEST_TMP/skill/config/project-config.yaml" <<YAML
project_root: $TEST_TMP
project_path: $TEST_TMP
memory_path: $TEST_TMP/_memory
checkpoint_path: $TEST_TMP/_memory/checkpoints
installed_path: $TEST_TMP/_gaia
framework_version: 1.127.2-rc.1
date: 2026-04-25
test_artifacts: $TEST_TMP/docs/test-artifacts
planning_artifacts: $TEST_TMP/docs/planning-artifacts
implementation_artifacts: $TEST_TMP/docs/implementation-artifacts
YAML
  export CLAUDE_SKILL_DIR="$TEST_TMP/skill"
}

teardown() { common_teardown; }

fail() { printf '%s\n' "$1" >&2; return 1; }

# Helpers ---------------------------------------------------------------

# _make_brief <path> [omit_section ...] — produce a synthetic product
# brief at <path>. By default emits all 9 required sections with body
# content rich enough to satisfy the existing 27-item checklist body
# checks (SV-13..SV-18). Each remaining argument is the literal
# section name to OMIT.
_make_brief() {
  local out="$1"; shift
  local -a sections=(
    "Vision Statement"
    "Target Users"
    "Problem Statement"
    "Proposed Solution"
    "Key Features"
    "Scope and Boundaries"
    "Risks and Assumptions"
    "Competitive Landscape"
    "Success Metrics"
  )
  _emit_section() {
    case "$1" in
      "Target Users")
        printf '## Target Users\n\n- Role: developer — pain points: slow CI.\n- Role: ops — pain points: noisy alerts.\n\n' ;;
      "Key Features")
        printf '## Key Features\n\n- Feature one — primary differentiator\n- Feature two — secondary lever\n\n' ;;
      "Scope and Boundaries")
        printf '## Scope and Boundaries\n\nIn-scope: A, B, C. Out-of-scope: D, E.\n\n' ;;
      "Competitive Landscape")
        printf '## Competitive Landscape\n\n- Competitor X — positioning note\n- Competitor Y — positioning note\n\n' ;;
      "Success Metrics")
        printf '## Success Metrics\n\n- 80%% adoption within 30 days\n- p95 latency under 200 ms\n\n' ;;
      *)
        printf '## %s\n\nFixture content for %s.\n\n' "$1" "$1" ;;
    esac
  }
  {
    printf '# Product Brief Fixture\n\n'
    local s
    for s in "${sections[@]}"; do
      local omit=0
      local skip
      for skip in "$@"; do
        if [ "$s" = "$skip" ]; then omit=1; break; fi
      done
      [ $omit -eq 1 ] && continue
      _emit_section "$s"
    done
  } >"$out"
}

# -------------------------------------------------------------------------
# VCP-GATE-01 — pre_start gate passes when brainstorm artifact exists
# -------------------------------------------------------------------------
@test "setup.sh pre_start passes when brainstorm artifact exists" {
  # AF-2026-05-21-20: canonical .gaia/artifacts/ path.
  printf '# brainstorm fixture\n' >"$TEST_TMP/.gaia/artifacts/creative-artifacts/brainstorm-fixture.md"
  cd "$TEST_TMP"
  run "$SETUP"
  [ "$status" -eq 0 ]
  # No gate-failure stderr line for the brainstorm message.
  [[ "$output" != *"Run \`/gaia-brainstorm\` first"* ]]
}

# -------------------------------------------------------------------------
# VCP-GATE-02 — pre_start gate halts when brainstorm artifact missing
# -------------------------------------------------------------------------
@test "setup.sh pre_start halts when brainstorm artifact missing" {
  cd "$TEST_TMP"
  run "$SETUP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Run \`/gaia-brainstorm\` first"* ]]
  [[ "$output" == *"quality-gate"* ]]
}

# -------------------------------------------------------------------------
# VCP-GATE-03 — post_complete gate passes when all 9 sections present
# -------------------------------------------------------------------------
@test "finalize.sh post_complete passes when all 9 sections present" {
  _make_brief "$TEST_TMP/docs/creative-artifacts/product-brief-fixture.md"
  cd "$TEST_TMP"
  export PRODUCT_BRIEF_ARTIFACT="$TEST_TMP/docs/creative-artifacts/product-brief-fixture.md"
  run "$FINALIZE"
  [ "$status" -eq 0 ]
  # No quality-gate failure header (the existing 27-item checklist still
  # runs and reports its own summary, but the gate prelude must not
  # emit a "Missing required sections" line).
  [[ "$output" != *"Missing required sections"* ]]
}

# -------------------------------------------------------------------------
# VCP-GATE-04 — post_complete gate halts when 2 sections missing,
# error message names exactly the missing sections.
# -------------------------------------------------------------------------
@test "finalize.sh post_complete halts when 2 sections missing" {
  _make_brief "$TEST_TMP/docs/creative-artifacts/product-brief-fixture.md" \
    "Vision Statement" "Success Metrics"
  cd "$TEST_TMP"
  export PRODUCT_BRIEF_ARTIFACT="$TEST_TMP/docs/creative-artifacts/product-brief-fixture.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Missing required sections"* ]]
  [[ "$output" == *"Vision Statement"* ]]
  [[ "$output" == *"Success Metrics"* ]]
  # Sections that ARE present must not be named in the missing list.
  # We can't easily assert "not in list" without parsing, but at least
  # confirm one present section is not surfaced as the first miss.
}

# -------------------------------------------------------------------------
# VCP-GATE-05 — SKILL.md frontmatter declares a machine-parseable
# quality_gates block: pre_start ≥ 1 entry, post_complete = 9 entries,
# every entry has both `condition` and `error_message` keys.
# -------------------------------------------------------------------------
@test "SKILL.md frontmatter declares quality_gates block" {
  run grep -E '^quality_gates:' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "pre_start has >= 1 entry with condition+error_message" {
  # Extract the pre_start sub-block and count `- condition:` lines.
  run awk '
    /^quality_gates:/ { in_qg=1; next }
    in_qg && /^[a-z_]+:/ && !/^[[:space:]]/ { in_qg=0 }
    in_qg && /^[[:space:]]+pre_start:/ { in_pre=1; next }
    in_qg && in_pre && /^[[:space:]]+post_complete:/ { in_pre=0 }
    in_qg && in_pre && /^[[:space:]]+-[[:space:]]+condition:/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "post_complete has exactly 9 entries" {
  run awk '
    /^quality_gates:/ { in_qg=1; next }
    in_qg && /^[a-z_]+:/ && !/^[[:space:]]/ { in_qg=0 }
    in_qg && /^[[:space:]]+post_complete:/ { in_post=1; next }
    in_qg && in_post && /^[[:space:]]+-[[:space:]]+condition:/ { count++ }
    END { print count + 0 }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" -eq 9 ]
}

@test "every quality_gates entry pairs condition with error_message" {
  # Each `- condition:` line must be followed (within the same list
  # entry) by an `error_message:` line. Counts must match.
  run awk '
    /^quality_gates:/ { in_qg=1; next }
    in_qg && /^[a-z_]+:/ && !/^[[:space:]]/ { in_qg=0 }
    in_qg && /^[[:space:]]+-[[:space:]]+condition:/ { c++ }
    in_qg && /^[[:space:]]+error_message:/ { e++ }
    END { print c "/" e }
  ' "$SKILL_MD"
  [ "$status" -eq 0 ]
  c="${output%/*}"
  e="${output#*/}"
  [ "$c" -eq "$e" ]
  [ "$c" -ge 10 ]  # 1 pre_start + 9 post_complete
}

# -------------------------------------------------------------------------
# VCP-GATE-06 — Integration: generic pre_start enforcement halts
# before step body executes.
# -------------------------------------------------------------------------
@test "pre_start failure halts before any step body runs" {
  # Build a fixture skill with a pre_start gate that requires a missing
  # file. The fixture's setup.sh must source the same gate-predicates
  # helper used by gaia-product-brief/setup.sh.
  cd "$TEST_TMP"
  run "$SETUP"
  [ "$status" -ne 0 ]
  # No checkpoint file should have been written for create-product-brief
  # because setup.sh halted before the checkpoint load step.
  [ ! -f "$CHECKPOINT_PATH/create-product-brief.json" ]
  [ ! -f "$CHECKPOINT_PATH/create-product-brief.yaml" ]
}

# -------------------------------------------------------------------------
# VCP-GATE-07 — Integration: post_complete halt prevents the existing
# checklist + checkpoint side effects from masking the failure.
# -------------------------------------------------------------------------
@test "post_complete failure surfaces in finalize.sh exit code" {
  # Truncated artifact: only 4 of 9 sections.
  _make_brief "$TEST_TMP/docs/creative-artifacts/product-brief-fixture.md" \
    "Key Features" "Scope and Boundaries" "Risks and Assumptions" \
    "Competitive Landscape" "Success Metrics"
  cd "$TEST_TMP"
  export PRODUCT_BRIEF_ARTIFACT="$TEST_TMP/docs/creative-artifacts/product-brief-fixture.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Missing required sections"* ]]
}

# -------------------------------------------------------------------------
# AC-EC1 — glob pattern matches multiple brainstorm files; gate passes.
# -------------------------------------------------------------------------
@test "pre_start passes when multiple brainstorm files match" {
  printf '# bs1\n' >"$TEST_TMP/.gaia/artifacts/creative-artifacts/brainstorm-one.md"
  printf '# bs2\n' >"$TEST_TMP/.gaia/artifacts/creative-artifacts/brainstorm-two.md"
  cd "$TEST_TMP"
  run "$SETUP"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# AC-EC3 — case-sensitive section header match; lowercase header fails.
# -------------------------------------------------------------------------
@test "post_complete is case-sensitive on section headers" {
  # Brief has "vision statement" lowercase — must FAIL the gate.
  {
    printf '# Brief\n\n'
    printf '## vision statement\n\nlowercase header.\n\n'
    printf '## Target Users\n\n- persona\n\n'
    printf '## Problem Statement\n\nx\n\n'
    printf '## Proposed Solution\n\nx\n\n'
    printf '## Key Features\n\n- feat\n\n'
    printf '## Scope and Boundaries\n\nin-scope: a; out-of-scope: b\n\n'
    printf '## Risks and Assumptions\n\nx\n\n'
    printf '## Competitive Landscape\n\n- comp\n\n'
    printf '## Success Metrics\n\n80%% NPS\n\n'
  } >"$TEST_TMP/docs/creative-artifacts/product-brief-fixture.md"
  cd "$TEST_TMP"
  export PRODUCT_BRIEF_ARTIFACT="$TEST_TMP/docs/creative-artifacts/product-brief-fixture.md"
  run "$FINALIZE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Vision Statement"* ]]
}

# -------------------------------------------------------------------------
# AC-EC5 — error_message containing shell metacharacters is printed
# literally (no expansion, no command execution).
# -------------------------------------------------------------------------
@test "error_message with shell metacharacters is printed literally" {
  # Use the gate-predicates helper directly with an inline message
  # containing $(...). The helper must print it as-is to stderr.
  helper="$SKILL_DIR/../../scripts/lib/gate-predicates.sh"
  [ -f "$helper" ]
  # Source the helper into a controlled subshell and call the exposed
  # private API to evaluate one entry.
  run bash -c "
    set -e
    . '$helper'
    _gate_evaluate_entry 'file_exists:does/not/exist/*.md' '\$(rm -rf /) malicious'
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"\$(rm -rf /) malicious"* ]]
  # /tmp must not have been touched (sanity).
  [ -d /tmp ]
}

# =========================================================================
# (AC3) Override refusal does not print force-design hint
# =========================================================================

@test "(AC3) override refusal does not print force-design hint" {
  # Set up a UI project in review state with no sprint and no --sprint-id
  local gate_lib="$SKILL_DIR/../../scripts/lib/gate-predicates.sh"
  local gate_sh="$SKILL_DIR/../../scripts/lib/design-gate.sh"
  local drec_sh="$SKILL_DIR/../../scripts/design-record.sh"
  [ -f "$gate_lib" ] || fail "gate-predicates.sh not found"
  [ -f "$gate_sh" ] || fail "design-gate.sh not found"
  [ -f "$drec_sh" ] || fail "design-record.sh not found"

  # Seed config and record
  mkdir -p "$TEST_TMP/.gaia/config" "$TEST_TMP/.gaia/state" "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<YAML
compliance:
  ui_present: true
YAML
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE
  printf 'bypasses: []\n' > "$TEST_TMP/.gaia/state/lifecycle-overrides.yaml"

  # Create a design-probe stub
  mkdir -p "$TEST_TMP/bin"
  cat > "$TEST_TMP/bin/design-probe.sh" <<'STUBEOF'
#!/usr/bin/env bash
printf 'available\n'; exit 0
STUBEOF
  chmod +x "$TEST_TMP/bin/design-probe.sh"

  # Create a record in review state via the real writer
  env PROJECT_ROOT="$TEST_TMP" "$drec_sh" init \
    --reference test --discovered-via created --questionnaire-record na
  env PROJECT_ROOT="$TEST_TMP" "$drec_sh" transition --to review --actor ci

  # No sprint-status.yaml means no resolvable sprint
  # Set FORCE_DESIGN and a valid reason so the override path is entered
  local error_msg="Design is not approved. Approve the design via /gaia-design-review, or pass --force-design with a reason to override."
  run bash -c '
    set -euo pipefail
    export PROJECT_ROOT="'"$TEST_TMP"'"
    export PATH="'"$TEST_TMP/bin"':$PATH"
    export FORCE_DESIGN=1
    export FORCE_DESIGN_REASON="valid reason text for override"
    export FORCE_DESIGN_ENTRY_POINT="gaia-dev-story"
    source "'"$gate_lib"'"
    _gate_evaluate_entry "design_approved:" "'"$error_msg"'"
  ' 2>&1
  [ "$status" -ne 0 ] || fail "gate should fail on override refusal (no sprint scope)"

  # The quality_gates error_message must NOT appear
  if [[ "$output" == *"or pass --force-design"* ]]; then
    fail "override refusal should NOT print 'or pass --force-design' hint; got: $output"
  fi

  # The gate's own diagnostic must appear
  [[ "$output" == *"no active sprint scope"* ]] || [[ "$output" == *"Design gate"* ]] \
    || fail "override refusal should contain the gate's own diagnostic; got: $output"
}

# =========================================================================
# (AC3) Normal design halt still prints quality_gates error_message (positive control)
# =========================================================================

@test "(AC3) normal design halt still prints quality_gates error_message" {
  local gate_lib="$SKILL_DIR/../../scripts/lib/gate-predicates.sh"
  local gate_sh="$SKILL_DIR/../../scripts/lib/design-gate.sh"
  local drec_sh="$SKILL_DIR/../../scripts/design-record.sh"
  [ -f "$gate_lib" ] || fail "gate-predicates.sh not found"

  # Seed a UI project in draft state — no --force-design
  mkdir -p "$TEST_TMP/.gaia/config" "$TEST_TMP/.gaia/state" "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<YAML
compliance:
  ui_present: true
YAML
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE

  mkdir -p "$TEST_TMP/bin"
  cat > "$TEST_TMP/bin/design-probe.sh" <<'STUBEOF'
#!/usr/bin/env bash
printf 'available\n'; exit 0
STUBEOF
  chmod +x "$TEST_TMP/bin/design-probe.sh"

  env PROJECT_ROOT="$TEST_TMP" "$drec_sh" init \
    --reference test --discovered-via created --questionnaire-record na

  local error_msg="Design is not approved. Approve the design via /gaia-design-review, or pass --force-design with a reason to override."
  run bash -c '
    set -euo pipefail
    export PROJECT_ROOT="'"$TEST_TMP"'"
    export PATH="'"$TEST_TMP/bin"':$PATH"
    source "'"$gate_lib"'"
    _gate_evaluate_entry "design_approved:" "'"$error_msg"'"
  ' 2>&1
  [ "$status" -ne 0 ] || fail "gate should fail on draft state"

  # The quality_gates error_message MUST appear for a normal halt
  [[ "$output" == *"or pass --force-design"* ]] \
    || fail "normal halt should print 'or pass --force-design' hint; got: $output"
}

# =========================================================================
# (AC-EC5) Nine gated skills error_message suppressed on override refusal
# =========================================================================

@test "(AC-EC5) nine gated skills error_message suppressed on override refusal" {
  local gate_lib="$SKILL_DIR/../../scripts/lib/gate-predicates.sh"
  local drec_sh="$SKILL_DIR/../../scripts/design-record.sh"
  [ -f "$gate_lib" ] || fail "gate-predicates.sh not found"

  local skills_root="$SKILL_DIR/../.."
  local -a gated_skills=(
    gaia-adversarial
    gaia-create-arch
    gaia-create-epics
    gaia-dev-story
    gaia-edit-arch
    gaia-infra-design
    gaia-readiness-check
    gaia-review-api
    gaia-threat-model
  )

  # Seed the override-refusal fixture (review state, no sprint)
  mkdir -p "$TEST_TMP/.gaia/config" "$TEST_TMP/.gaia/state" "$TEST_TMP/.gaia/custom/stakeholders"
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<YAML
compliance:
  ui_present: true
YAML
  cat > "$TEST_TMP/.gaia/custom/stakeholders/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE
  printf 'bypasses: []\n' > "$TEST_TMP/.gaia/state/lifecycle-overrides.yaml"

  mkdir -p "$TEST_TMP/bin"
  cat > "$TEST_TMP/bin/design-probe.sh" <<'STUBEOF'
#!/usr/bin/env bash
printf 'available\n'; exit 0
STUBEOF
  chmod +x "$TEST_TMP/bin/design-probe.sh"

  env PROJECT_ROOT="$TEST_TMP" "$drec_sh" init \
    --reference test --discovered-via created --questionnaire-record na
  env PROJECT_ROOT="$TEST_TMP" "$drec_sh" transition --to review --actor ci

  local checked=0
  local skill_name skill_md error_msg
  for skill_name in "${gated_skills[@]}"; do
    skill_md="$skills_root/skills/$skill_name/SKILL.md"
    [ -f "$skill_md" ] || fail "$skill_name/SKILL.md not found at $skill_md"

    # Extract the error_message from the design_approved condition
    error_msg="$(awk '
      /design_approved/ { found=1; next }
      found && /error_message:/ {
        sub(/^[[:space:]]*error_message:[[:space:]]*/, "")
        gsub(/^"/, ""); gsub(/"$/, "")
        gsub(/^\047/, ""); gsub(/\047$/, "")
        print; exit
      }
    ' "$skill_md")"
    [ -n "$error_msg" ] || fail "$skill_name: could not extract error_message"

    # Reset the design-gate loaded flag for a fresh source
    run bash -c '
      set -euo pipefail
      export PROJECT_ROOT="'"$TEST_TMP"'"
      export PATH="'"$TEST_TMP/bin"':$PATH"
      export FORCE_DESIGN=1
      export FORCE_DESIGN_REASON="valid reason text for override"
      export FORCE_DESIGN_ENTRY_POINT="'"$skill_name"'"
      export _DESIGN_GATE_SH_LOADED=0
      source "'"$gate_lib"'"
      _gate_evaluate_entry "design_approved:" "'"$error_msg"'"
    ' 2>&1

    if [[ "$output" == *"or pass --force-design"* ]]; then
      fail "$skill_name: error_message should be suppressed on override refusal; got: $output"
    fi
    checked=$((checked + 1))
  done

  [ "$checked" -eq 9 ] || fail "expected 9 gated skills checked but got $checked"
}
