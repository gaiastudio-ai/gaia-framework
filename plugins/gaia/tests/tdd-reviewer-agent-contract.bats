#!/usr/bin/env bats
# tdd-reviewer-agent-contract.bats — bats coverage for E57-S3
#
# Story: E57-S3 — TDD review subagent contract (new tdd-reviewer.md)
#
# Acceptance Criteria covered:
#   AC1 — ADR memo at docs/planning-artifacts/adr-memo-tdd-reviewer-subagent.md
#         documents Option A vs Option B and records the chosen path
#         with rationale.
#   AC2 — Chosen subagent file frontmatter has `context: fork` and
#         `allowed-tools` exactly [Read, Grep, Glob, Bash].
#   AC3 — Persona text contains exactly 7 after-Red, 4 after-Green, and
#         3 after-Refactor checklist items (total 14).
#   AC4 — Agent body documents ADR-067 hard-CRITICAL clause: any CRITICAL
#         finding HALTs dev-story regardless of YOLO mode; halt record
#         lands in _memory/checkpoints/{story_key}-tdd-review-findings.md
#         (TC-TDR-05).
#   AC5 — Agent body documents WARNING surfacing contract: WARNING-only
#         findings surface line-by-line and dev-story continues; persisted
#         to the same audit-file path (TC-TDR-06).
#   AC6 — Agent body documents INFO suppression contract: INFO findings
#         are written to the audit log but suppressed from user-visible
#         transcript (TC-TDR-07).
#   AC7 — Agent body documents the qa_timeout_seconds config key it
#         consumes and the SKIP-with-audit fallback contract that
#         preserves the read-only allowlist on timeout (TC-TDR-08).
#
# Contract observability rationale:
#   This story locks the agent contract surface. Runtime behaviors
#   (HALT exit code, transcript line shape, audit-file write) land in
#   the downstream E57-S4 SKILL.md gate-wiring story per the dependency
#   graph (blocks: ["E57-S4"]). Tests below assert that the agent
#   documentation pins the contract markers consumed by E57-S4.

load 'test_helper.bash'

setup() {
  common_setup
  # PUBLIC_ROOT (gaia-public) — owns plugins/gaia/agents/. Walks up
  # tests/ -> plugins/gaia/ -> plugins/ -> gaia-public/.
  PUBLIC_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  AGENT_FILE="$PUBLIC_ROOT/plugins/gaia/agents/tdd-reviewer.md"

  # ADR memo locations — the canonical authored location is the workspace
  # path docs/planning-artifacts/adr-memo-tdd-reviewer-subagent.md (one
  # level above gaia-public/). On CI the workspace tree is not present;
  # the fixture under tests/fixtures/ is the CI-stable mirror so the same
  # content checks run in both environments. Resolution order:
  #   1. Workspace path (when running inside GAIA-Framework/).
  #   2. Fixture under tests/fixtures/e57-s3-adr-memo/ (CI-stable).
  WORKSPACE_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd 2>/dev/null || echo "")"
  WORKSPACE_MEMO="$WORKSPACE_ROOT/docs/planning-artifacts/adr-memo-tdd-reviewer-subagent.md"
  FIXTURE_MEMO="$BATS_TEST_DIRNAME/fixtures/e57-s3-adr-memo/adr-memo-tdd-reviewer-subagent.md"
  if [ -f "$WORKSPACE_MEMO" ]; then
    ADR_MEMO="$WORKSPACE_MEMO"
  else
    ADR_MEMO="$FIXTURE_MEMO"
  fi
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC1 — ADR memo on disk records Option A vs B and the chosen path.
# ---------------------------------------------------------------------------

@test "ADR memo records Option A vs Option B and the chosen path" {
  [ -f "$ADR_MEMO" ]
  grep -F "Option A" "$ADR_MEMO"
  grep -F "Option B" "$ADR_MEMO"
  # Chosen marker — case-insensitive to allow 'Chosen:' or '## Chosen'.
  grep -i "chosen" "$ADR_MEMO"
  # Rationale section MUST follow the choice marker.
  grep -i "rationale" "$ADR_MEMO"
}

# ---------------------------------------------------------------------------
# AC2 — Frontmatter contract: context=fork, allowed-tools exact list.
# ---------------------------------------------------------------------------

@test "agent frontmatter has context: fork and the read-only allowlist" {
  [ -f "$AGENT_FILE" ]
  # Extract the YAML frontmatter block (between the first two '---' lines).
  awk 'BEGIN{n=0} /^---$/{n++; next} n==1{print}' "$AGENT_FILE" > "$TEST_TMP/frontmatter.yaml"

  grep -E '^context:[[:space:]]+fork[[:space:]]*$' "$TEST_TMP/frontmatter.yaml"

  # allowed-tools MUST be exactly [Read, Grep, Glob, Bash] — order matches
  # the ATDD spec; ordering is asserted strictly to lock the contract.
  grep -E '^allowed-tools:[[:space:]]+\[Read,[[:space:]]*Grep,[[:space:]]*Glob,[[:space:]]*Bash\][[:space:]]*$' \
    "$TEST_TMP/frontmatter.yaml"

  # Negative assertions: forbidden write tools MUST NOT appear in the list.
  ! grep -E '^allowed-tools:.*\bWrite\b' "$TEST_TMP/frontmatter.yaml"
  ! grep -E '^allowed-tools:.*\bEdit\b' "$TEST_TMP/frontmatter.yaml"
}

# ---------------------------------------------------------------------------
# AC3 — Persona contains exactly 7+4+3 = 14 checklist items.
# ---------------------------------------------------------------------------

@test "persona contains 7 after-Red + 4 after-Green + 3 after-Refactor items" {
  [ -f "$AGENT_FILE" ]

  # Section headers — locked literals so the contract is greppable.
  grep -F "After-Red Checklist (7 items)"      "$AGENT_FILE"
  grep -F "After-Green Checklist (4 items)"    "$AGENT_FILE"
  grep -F "After-Refactor Checklist (3 items)" "$AGENT_FILE"

  # Count list items under each section. We extract each section body
  # between its header and the next '### ' or top-level heading, then
  # count lines beginning with '- ' (the canonical checklist bullet).
  red_count="$(awk '
    /^### After-Red Checklist/   {inblock=1; next}
    inblock && /^(### |## )/      {inblock=0}
    inblock && /^- /              {n++}
    END {print n+0}
  ' "$AGENT_FILE")"

  green_count="$(awk '
    /^### After-Green Checklist/  {inblock=1; next}
    inblock && /^(### |## )/      {inblock=0}
    inblock && /^- /              {n++}
    END {print n+0}
  ' "$AGENT_FILE")"

  refactor_count="$(awk '
    /^### After-Refactor Checklist/ {inblock=1; next}
    inblock && /^(### |## )/        {inblock=0}
    inblock && /^- /                {n++}
    END {print n+0}
  ' "$AGENT_FILE")"

  [ "$red_count" -eq 7 ]
  [ "$green_count" -eq 4 ]
  [ "$refactor_count" -eq 3 ]
}

# ---------------------------------------------------------------------------
# AC4 — ADR-067 hard-CRITICAL clause documented.
# ---------------------------------------------------------------------------

@test "agent documents hard-CRITICAL halt clause for both YOLO modes" {
  [ -f "$AGENT_FILE" ]

  # Hard-CRITICAL halt contract — behavioral phrase must name the halt clause.
  grep -iE "hard.CRITICAL halt|YOLO MUST NOT auto.resolve CRITICAL" "$AGENT_FILE"
  # CRITICAL severity vocabulary present.
  grep -F "CRITICAL" "$AGENT_FILE"
  # Halt clause spanning both modes (case-insensitive on YOLO/non-YOLO so
  # the clause can phrase it either way).
  grep -iE "halt.*both|both.*halt|regardless of yolo|yolo.*non-yolo" "$AGENT_FILE"
  # Audit file path is the canonical checkpoint location (.gaia/memory).
  grep -F ".gaia/memory/checkpoints/" "$AGENT_FILE"
  grep -F "tdd-review-findings.md" "$AGENT_FILE"
}

# ---------------------------------------------------------------------------
# AC5 — WARNING surfacing contract documented.
# ---------------------------------------------------------------------------

@test "agent documents WARNING surfacing + continue contract" {
  [ -f "$AGENT_FILE" ]

  grep -F "WARNING" "$AGENT_FILE"
  # Per-finding surfacing contract — line-by-line transcript output.
  grep -iE "line.by.line|one line per finding|per.finding" "$AGENT_FILE"
  # Continue-after-WARNING semantics.
  grep -iE "continue|proceed" "$AGENT_FILE"
  # Verdict surfacing contract — parent skill renders findings to the user.
  grep -iE "verdict surfacing|parent skill renders findings|renders findings to the user" "$AGENT_FILE"
}

# ---------------------------------------------------------------------------
# AC6 — INFO suppression contract documented.
# ---------------------------------------------------------------------------

@test "agent documents INFO suppression from user-visible transcript" {
  [ -f "$AGENT_FILE" ]

  grep -F "INFO" "$AGENT_FILE"
  # Suppression vocabulary — INFO findings go to the audit log, not stdout.
  grep -iE "suppress|not surface|audit.*not|silent" "$AGENT_FILE"
  # Severity vocabulary declaration — canonical finding-shape contract.
  grep -iE "Severity vocabulary|No other severities are emitted" "$AGENT_FILE"
}

# ---------------------------------------------------------------------------
# AC7 — Timeout SKIP-with-audit + allowlist preservation documented.
# ---------------------------------------------------------------------------

@test "agent documents qa_timeout_seconds + SKIP-with-audit fallback" {
  [ -f "$AGENT_FILE" ]

  # The timeout config key the agent consumes.
  grep -F "dev_story.tdd_review.qa_timeout_seconds" "$AGENT_FILE"
  # SKIP-with-audit fallback contract.
  grep -iE "SKIP.with.audit|skip.*audit" "$AGENT_FILE"
  # Allowlist preservation clause across the timeout.
  grep -iE "allowlist.*preserv|preserv.*allowlist|read.only.*preserv|preserv.*read.only" "$AGENT_FILE"
}
