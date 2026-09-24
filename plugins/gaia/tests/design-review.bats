#!/usr/bin/env bats
# design-review.bats — /gaia-design-review skill tests.
#
# Covers: read-back authority (AC1), severity-tagged findings (AC2),
# internal-first review ordering (AC3), verdict writes / state machine /
# convergence / delta sync (AC4), escalation firewall (AC5), edge cases
# (AC-EC1 through AC-EC6), and the verdict-provenance backstop (AC-EC7).
#
# Every test that needs a .gaia/ tree creates a temporary PROJECT_ROOT via
# mktemp -d and asserts only against files under that temp root.  The tests
# never read or write the real project-root .gaia/.

load 'test_helper.bash'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

fail() { printf 'FAIL: %s\n' "$1" >&2; return 1; }

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SKILL_DIR=""
SKILL_MD=""
PROVENANCE_SCRIPT=""
SYNC_SCRIPT=""
DESIGN_RECORD_SH=""
WORKFLOW_MANIFEST=""

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL_DIR="$PLUGIN_ROOT/skills/gaia-design-review"
  SKILL_MD="$SKILL_DIR/SKILL.md"
  PROVENANCE_SCRIPT="$SKILL_DIR/scripts/verdict-provenance-check.sh"
  SYNC_SCRIPT="$SKILL_DIR/scripts/sync-derived-artifacts.sh"
  DESIGN_RECORD_SH="$PLUGIN_ROOT/scripts/design-record.sh"
  WORKFLOW_MANIFEST="$PLUGIN_ROOT/knowledge/workflow-manifest.csv"
  SCHEMA="$PLUGIN_ROOT/schemas/design-record.schema.json"

  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT PROJECT_PATH CLAUDE_PLUGIN_ROOT 2>/dev/null || true
  command -v yq >/dev/null 2>&1 || fail "yq is required but not found on PATH"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# _seed_temp_project — create a temporary project root with the minimal
# state tree needed for design-review tests.  Sets PROJECT_ROOT.
_seed_temp_project() {
  local root
  root="$(mktemp -d)"
  mkdir -p "$root/.gaia/state"
  mkdir -p "$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$root/.gaia/custom/stakeholders"
  export PROJECT_ROOT="$root"
  echo "$root"
}

# _seed_record ROOT STATE — create a valid design record through the writer's
# own verbs (init + optional transition), never via direct YAML writes.
_seed_record() {
  local root="$1" state="${2:-draft}"
  export PROJECT_ROOT="$root"

  "$DESIGN_RECORD_SH" init \
    --reference "test-project-ref" \
    --discovered-via "created" \
    --questionnaire-record ".gaia/artifacts/planning-artifacts/ux-design/design-questionnaire.md" \
    --actor "test-seed" >/dev/null 2>&1 \
    || fail "_seed_record: init failed"

  if [ "$state" != "draft" ]; then
    "$DESIGN_RECORD_SH" transition --to "$state" --actor "test-seed" >/dev/null 2>&1 \
      || fail "_seed_record: transition to $state failed"
  fi
}

# _seed_stakeholder_roster ROOT — add two design/UX-tagged stakeholders.
_seed_stakeholder_roster() {
  local root="$1"
  local dir="$root/.gaia/custom/stakeholders"
  mkdir -p "$dir"
  cat > "$dir/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design, ux]
---
STAKE
  cat > "$dir/stakeholder-B.md" <<'STAKE'
---
name: "Stakeholder B"
slug: stakeholder-B
tags: [ux]
---
STAKE
}

# _seed_ux_design ROOT — create a stale ux-design.md missing "new-sidebar".
_seed_ux_design() {
  local root="$1"
  mkdir -p "$root/.gaia/artifacts/planning-artifacts"
  cat > "$root/.gaia/artifacts/planning-artifacts/ux-design.md" <<'UX'
---
template: ux-design
design_state: review
---

# UX Design

## Component Inventory

- header
- footer
- main-content

## Screen Specifications

### Home Screen

Standard landing page layout.

## Design Record Reference

Project reference: test-project-ref
UX
}


# =========================================================================
# (AC1) structural / registration tests
# =========================================================================

@test "(AC1) gaia-design-review skill exists and is registered in workflow manifest" {
  [ -d "$SKILL_DIR" ] || fail "skill directory does not exist: $SKILL_DIR"
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist: $SKILL_MD"

  [ -f "$WORKFLOW_MANIFEST" ] || fail "workflow-manifest.csv does not exist: $WORKFLOW_MANIFEST"
  grep -q 'gaia-design-review' "$WORKFLOW_MANIFEST" || \
    fail "workflow-manifest.csv has no gaia-design-review row"
}


# =========================================================================
# (AC1) read-back authority tests
# =========================================================================

@test "(AC1) review uses project content, not local derivation, as authoritative" {
  # This test requires the SKILL.md to exist and contain the read-back step
  # that treats project content (via the integration) as authoritative.
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist — cannot verify read-back authority"

  # The SKILL.md must reference get_project / list_files / get_file as the
  # authoritative source, not local file reads of ux-design.md.
  local readback_step
  readback_step="$(awk '/^### Step.*[Rr]ead.?back/{found=1} found && /^### Step/ && !/[Rr]ead.?back/{exit} found{print}' "$SKILL_MD" 2>/dev/null | head -50)"
  [ -n "$readback_step" ] || fail "SKILL.md has no read-back step"

  # The step must mention get_project or list_files as the source
  printf '%s' "$readback_step" | grep -qE 'get_project|list_files|get_file' || \
    fail "read-back step does not reference project integration tools as authoritative source"

  # The step must NOT treat local derivation (ux-design.md) as the primary source
  printf '%s' "$readback_step" | grep -qE 'authoritative|primary|source.of.truth' || \
    fail "read-back step does not mark project content as authoritative"
}

@test "(AC1) structural: SKILL.md wraps project content in boundary markers" {
  # The SKILL.md must contain boundary markers around project content so that
  # local derivation cannot silently substitute for the authoritative source.
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist — cannot verify boundary markers"

  grep -q 'boundary.marker\|BOUNDARY\|data.boundary' "$SKILL_MD" || \
    fail "SKILL.md does not wrap project content in boundary markers — local derivation could silently substitute"
}


# =========================================================================
# (AC2) severity-tagged findings
# =========================================================================

@test "(AC2) UX-required component absent from project produces a severity-tagged finding" {
  # The SKILL.md must define a findings step that checks project content
  # against the UX doc and emits severity-tagged findings.
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist — cannot verify findings step"

  local findings_step
  findings_step="$(awk '/^### Step.*[Ff]inding/{found=1} found && /^### Step/ && !/[Ff]inding/{exit} found{print}' "$SKILL_MD" 2>/dev/null | head -80)"
  [ -n "$findings_step" ] || fail "SKILL.md has no findings step"

  # The findings step must mention severity tags
  printf '%s' "$findings_step" | grep -qE 'severity|high|medium|low|info' || \
    fail "findings step does not mention severity tags"

  # Missing components must be findings (not a separate detection loop)
  printf '%s' "$findings_step" | grep -qiE 'missing.*component|component.*absent|component.*finding' || \
    fail "findings step does not treat missing UX-required components as findings"
}

@test "(AC2) severity tags are present on every finding" {
  # Structural: the SKILL.md must specify that every finding carries a severity tag
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist"

  grep -qiE 'every.*finding.*severity|severity.*tag.*each|severity.*(high|medium|low|info)' "$SKILL_MD" || \
    fail "SKILL.md does not require severity tags on every finding"
}


# =========================================================================
# (AC3) internal review before stakeholder delivery
# =========================================================================

@test "(AC3) internal review verdict exists before any stakeholder delivery" {
  # The skill must exist and enforce internal-first ordering
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist — internal-first ordering cannot be verified"
  [ -x "$DESIGN_RECORD_SH" ] || fail "design-record.sh does not exist or is not executable"

  local root
  root="$(_seed_temp_project)"
  _seed_record "$root" "review"
  _seed_stakeholder_roster "$root"
  export PROJECT_ROOT="$root"

  # Add internal review first
  run "$DESIGN_RECORD_SH" add-review \
    --verdict approved --reviewer "internal-reviewer" --kind internal
  [ "$status" -eq 0 ] || fail "internal add-review failed: $output"

  # Add stakeholder review second
  run "$DESIGN_RECORD_SH" add-review \
    --verdict approved --reviewer "stakeholder-A" --kind stakeholder
  [ "$status" -eq 0 ] || fail "stakeholder add-review failed: $output"

  # Assert: internal-kind entry at a LOWER array index than stakeholder-kind
  local internal_idx stakeholder_idx
  internal_idx="$(yq '[.reviews[] | .kind] | to_entries | map(select(.value == "internal")) | .[0].key' "$root/.gaia/state/design-record.yaml")"
  stakeholder_idx="$(yq '[.reviews[] | .kind] | to_entries | map(select(.value == "stakeholder")) | .[0].key' "$root/.gaia/state/design-record.yaml")"

  [ -n "$internal_idx" ] && [ "$internal_idx" != "null" ] || fail "no internal review entry found"
  [ -n "$stakeholder_idx" ] && [ "$stakeholder_idx" != "null" ] || fail "no stakeholder review entry found"
  [ "$internal_idx" -lt "$stakeholder_idx" ] || \
    fail "internal review (index $internal_idx) is NOT before stakeholder review (index $stakeholder_idx)"

  rm -rf "$root"
}

@test "(AC3) structural: SKILL.md enforces internal review before stakeholder delivery" {
  # The SKILL.md must have an explicit gate that blocks stakeholder delivery
  # until an internal review has been recorded.
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist"

  grep -qiE 'internal.*review.*before.*stakeholder|block.*stakeholder.*until.*internal|internal.*gate' "$SKILL_MD" || \
    fail "SKILL.md does not enforce internal review before stakeholder delivery"
}


# =========================================================================
# (AC4) verdict writes — field completeness
# =========================================================================

@test "(AC4) verdict writes kind, verdict, actor, timestamp, iteration via sole writer" {
  [ -x "$DESIGN_RECORD_SH" ] || fail "design-record.sh does not exist or is not executable"

  local root
  root="$(_seed_temp_project)"
  _seed_record "$root" "review"
  _seed_stakeholder_roster "$root"
  export PROJECT_ROOT="$root"

  run "$DESIGN_RECORD_SH" add-review \
    --verdict approved --reviewer "reviewer-A" --kind internal --notes-ref ".gaia/artifacts/review-notes.md"
  [ "$status" -eq 0 ] || fail "add-review failed: $output"

  local record="$root/.gaia/state/design-record.yaml"
  # All six fields must be present
  local iteration kind verdict actor at notes_ref
  iteration="$(yq '.reviews[-1].iteration' "$record")"
  kind="$(yq '.reviews[-1].kind' "$record")"
  verdict="$(yq '.reviews[-1].verdict' "$record")"
  actor="$(yq '.reviews[-1].actor' "$record")"
  at="$(yq '.reviews[-1].at' "$record")"
  notes_ref="$(yq '.reviews[-1].notes_ref' "$record")"

  [ "$iteration" != "null" ] && [ -n "$iteration" ] || fail "missing iteration field"
  [ "$kind" = "internal" ] || fail "kind=$kind, expected internal"
  [ "$verdict" = "approved" ] || fail "verdict=$verdict, expected approved"
  [ "$actor" = "reviewer-A" ] || fail "actor=$actor, expected reviewer-A"
  [ "$at" != "null" ] && [ -n "$at" ] || fail "missing at (timestamp) field"
  [ "$notes_ref" = ".gaia/artifacts/review-notes.md" ] || fail "notes_ref=$notes_ref, expected .gaia/artifacts/review-notes.md"

  rm -rf "$root"
}


# =========================================================================
# (AC4) state transitions
# =========================================================================

@test "(AC4) draft to review transition on first review" {
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist — transition flow cannot be verified"
  [ -x "$DESIGN_RECORD_SH" ] || fail "design-record.sh does not exist or is not executable"

  local root
  root="$(_seed_temp_project)"
  _seed_record "$root" "draft"
  _seed_stakeholder_roster "$root"
  export PROJECT_ROOT="$root"

  local record="$root/.gaia/state/design-record.yaml"

  # Transition draft -> review
  run "$DESIGN_RECORD_SH" transition --to review --actor "test-actor"
  [ "$status" -eq 0 ] || fail "draft->review transition failed: $output"

  local state
  state="$(yq '.design_state' "$record")"
  [ "$state" = "review" ] || fail "design_state=$state after draft->review, expected review"

  rm -rf "$root"
}

@test "(AC4) structural: SKILL.md transitions draft to review before stakeholder delivery" {
  # Guards that the SKILL.md explicitly instructs the draft-to-review
  # transition before the first stakeholder delivery.  Without this the
  # record stays in draft during stakeholder rounds, which is a state-machine
  # violation.
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist — draft-to-review instruction cannot be verified"

  # Extract the internal-review step (Step 3) where the instruction belongs
  local step3
  step3="$(awk '
    /^### Step 3/ { found=1 }
    found && /^### Step [^3]/ { exit }
    found { print }
  ' "$SKILL_MD" 2>/dev/null)"
  [ -n "$step3" ] || fail "SKILL.md has no Step 3 block"

  # The step must contain the writer invocation for transition --to review.
  # Match the writer call form (design-record.sh ... transition) to avoid
  # matching prose mentions of the word "transition".
  local invocation_pattern='design-record\.sh[[:space:]].*transition --to review\|design-record\.sh transition --to review'
  printf '%s\n' "$step3" | grep -qE 'design-record\.sh[^`]*transition --to review|design-record\.sh transition --to review' || \
    fail "Step 3 does not contain a writer invocation for transition --to review"

  # The transition must appear BEFORE any stakeholder delivery instruction.
  # Step 4 is the stakeholder step, so the transition must be in Step 3 (which
  # is entirely before Step 4).  Within Step 3, verify the transition appears
  # after the internal review verdict (add-review) so the ordering is:
  # internal verdict -> draft-to-review transition -> stakeholder delivery.
  local review_line trans_line
  review_line="$(printf '%s\n' "$step3" | grep -nE 'design-record\.sh[^`]*add-review|design-record\.sh add-review' | head -1 | cut -d: -f1)"
  trans_line="$(printf '%s\n' "$step3" | grep -nE 'design-record\.sh[^`]*transition --to review|design-record\.sh transition --to review' | head -1 | cut -d: -f1)"

  [ -n "$review_line" ] || fail "add-review writer invocation not found in Step 3"
  [ -n "$trans_line" ] || fail "transition --to review writer invocation not found in Step 3"
  [ "$review_line" -lt "$trans_line" ] || \
    fail "transition --to review (line $trans_line) does not follow add-review (line $review_line) in Step 3"
}

@test "(AC4) review to approved on convergence with stakeholder approvals" {
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist — convergence flow cannot be verified"
  [ -x "$DESIGN_RECORD_SH" ] || fail "design-record.sh does not exist or is not executable"

  local root
  root="$(_seed_temp_project)"
  _seed_record "$root" "review"
  _seed_stakeholder_roster "$root"
  export PROJECT_ROOT="$root"

  local record="$root/.gaia/state/design-record.yaml"

  # For each approving stakeholder: add-review AND approve
  local stakeholder
  for stakeholder in stakeholder-A stakeholder-B; do
    run "$DESIGN_RECORD_SH" add-review \
      --verdict approved --reviewer "$stakeholder" --kind stakeholder
    [ "$status" -eq 0 ] || fail "add-review for $stakeholder failed: $output"

    run "$DESIGN_RECORD_SH" approve \
      --stakeholder "$stakeholder" --recorded-by "test-actor"
    [ "$status" -eq 0 ] || fail "approve for $stakeholder failed: $output"
  done

  # Assert approvals[] length increased
  local approvals_len
  approvals_len="$(yq '.approvals | length' "$record")"
  [ "$approvals_len" -eq 2 ] || fail "expected 2 approvals, got $approvals_len"

  # Assert check-convergence reports converged
  run "$DESIGN_RECORD_SH" check-convergence
  [ "$status" -eq 0 ] || fail "check-convergence failed: $output"
  [[ "$output" == *"converged"* ]] || fail "expected converged, got: $output"

  # Assert transition review->approved succeeds
  run "$DESIGN_RECORD_SH" transition --to approved --actor "test-actor"
  [ "$status" -eq 0 ] || fail "review->approved transition failed: $output"

  local state
  state="$(yq '.design_state' "$record")"
  [ "$state" = "approved" ] || fail "design_state=$state, expected approved"

  rm -rf "$root"
}

@test "(AC4) approving round does not bump iteration" {
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist — iteration behavior cannot be verified"
  [ -x "$DESIGN_RECORD_SH" ] || fail "design-record.sh does not exist or is not executable"

  local root
  root="$(_seed_temp_project)"
  _seed_record "$root" "review"
  _seed_stakeholder_roster "$root"
  export PROJECT_ROOT="$root"

  local record="$root/.gaia/state/design-record.yaml"
  local pre_iter
  pre_iter="$(yq '.iteration' "$record")"

  # Approve all stakeholders
  for stakeholder in stakeholder-A stakeholder-B; do
    run "$DESIGN_RECORD_SH" add-review \
      --verdict approved --reviewer "$stakeholder" --kind stakeholder
    [ "$status" -eq 0 ] || fail "add-review for $stakeholder failed: $output"
    run "$DESIGN_RECORD_SH" approve \
      --stakeholder "$stakeholder" --recorded-by "test-actor"
    [ "$status" -eq 0 ] || fail "approve for $stakeholder failed: $output"
  done

  run "$DESIGN_RECORD_SH" transition --to approved --actor "test-actor"
  [ "$status" -eq 0 ] || fail "review->approved transition failed: $output"

  local post_iter
  post_iter="$(yq '.iteration' "$record")"
  [ "$pre_iter" -eq "$post_iter" ] || \
    fail "iteration bumped on approving round: $pre_iter -> $post_iter"

  rm -rf "$root"
}

@test "(AC4) three consecutive changes-requested rounds bump iteration exactly three times" {
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist — iteration counter cannot be verified"
  [ -x "$DESIGN_RECORD_SH" ] || fail "design-record.sh does not exist or is not executable"

  local root
  root="$(_seed_temp_project)"
  _seed_record "$root" "review"
  _seed_stakeholder_roster "$root"
  export PROJECT_ROOT="$root"

  local record="$root/.gaia/state/design-record.yaml"
  local pre_iter
  pre_iter="$(yq '.iteration' "$record")"

  # Three consecutive changes-requested rounds (review->review each time)
  local i
  for i in 1 2 3; do
    run "$DESIGN_RECORD_SH" add-review \
      --verdict changes-requested --reviewer "stakeholder-A" --kind stakeholder
    [ "$status" -eq 0 ] || fail "add-review round $i failed: $output"

    run "$DESIGN_RECORD_SH" transition --to review --actor "test-actor"
    [ "$status" -eq 0 ] || fail "review->review transition round $i failed: $output"
  done

  local post_iter
  post_iter="$(yq '.iteration' "$record")"
  local expected_iter=$(( pre_iter + 3 ))
  [ "$post_iter" -eq "$expected_iter" ] || \
    fail "iteration not bumped exactly 3 times: pre=$pre_iter post=$post_iter expected=$expected_iter"

  rm -rf "$root"
}

@test "(AC4) counter does not increment on internal-only round" {
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist — counter behavior cannot be verified"
  [ -x "$DESIGN_RECORD_SH" ] || fail "design-record.sh does not exist or is not executable"

  local root
  root="$(_seed_temp_project)"
  _seed_record "$root" "review"
  _seed_stakeholder_roster "$root"
  export PROJECT_ROOT="$root"

  local record="$root/.gaia/state/design-record.yaml"
  local pre_iter
  pre_iter="$(yq '.iteration' "$record")"

  # Internal-only review: add-review --kind internal, no transition
  run "$DESIGN_RECORD_SH" add-review \
    --verdict changes-requested --reviewer "internal-reviewer" --kind internal
  [ "$status" -eq 0 ] || fail "internal add-review failed: $output"

  local post_iter
  post_iter="$(yq '.iteration' "$record")"
  [ "$pre_iter" -eq "$post_iter" ] || \
    fail "iteration changed on internal-only round: $pre_iter -> $post_iter"

  rm -rf "$root"
}


# =========================================================================
# (AC4) delta sync — designer changes reconciled
# =========================================================================

@test "(AC4) designer changes reconciled into UX design document after sync" {
  # Behavioral test: run the sync script against a stale ux-design.md
  # and assert the designer-added component appears.
  [ -x "$SYNC_SCRIPT" ] || \
    fail "sync-derived-artifacts.sh does not exist or is not executable: $SYNC_SCRIPT"

  local root
  root="$(_seed_temp_project)"
  _seed_ux_design "$root"
  export PROJECT_ROOT="$root"

  local ux_doc="$root/.gaia/artifacts/planning-artifacts/ux-design.md"
  [ -f "$ux_doc" ] || fail "ux-design.md fixture not created"

  # Verify initial state: "new-sidebar" is NOT in the fixture
  ! grep -q 'new-sidebar' "$ux_doc" || \
    fail "fixture already contains new-sidebar — test is vacuous"

  # Create a snapshot with the designer-added component
  local snapshot="$root/snapshot.json"
  printf '{"components":["header","footer","main-content","new-sidebar"]}\n' > "$snapshot"

  # Run the sync script
  run "$SYNC_SCRIPT" "$snapshot" "$ux_doc"
  [ "$status" -eq 0 ] || fail "sync failed: $output"

  # Assert the component now appears in the doc
  grep -q 'new-sidebar' "$ux_doc" || \
    fail "ux-design.md does not contain new-sidebar after sync"

  rm -rf "$root"
}

@test "(AC4) structural: SKILL.md calls sync-derived-artifacts.sh in its sync step" {
  # The SKILL.md must reference the sync script in its delta-sync step
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist — cannot verify sync wiring"

  grep -q 'sync-derived-artifacts' "$SKILL_MD" || \
    fail "SKILL.md does not reference sync-derived-artifacts.sh"
}


# =========================================================================
# (AC4) vacuous convergence
# =========================================================================

@test "(AC4) vacuous-convergence roster surfaces a warning to the user" {
  [ -x "$DESIGN_RECORD_SH" ] || fail "design-record.sh does not exist or is not executable"

  local root
  root="$(_seed_temp_project)"
  _seed_record "$root" "review"
  # Do NOT seed a stakeholder roster — empty roster triggers vacuous convergence
  export PROJECT_ROOT="$root"

  run "$DESIGN_RECORD_SH" check-convergence
  [[ "$output" == *"vacuous"* ]] || \
    fail "expected vacuous-convergence warning when roster is empty, got: $output"

  # The SKILL.md must relay the vacuous-convergence warning to the user
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist"
  grep -qiE 'vacuous.convergence|relay.*warning|surface.*warning' "$SKILL_MD" || \
    fail "SKILL.md does not relay the vacuous-convergence warning to the user"

  rm -rf "$root"
}


# =========================================================================
# (AC5) escalation firewall
# =========================================================================

@test "(AC5) requirement-change comment halts loop and routes to feature intake" {
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist — cannot verify escalation firewall"

  # The SKILL.md must contain the escalation halt / route logic
  grep -qiE 'halt.*loop|loop.*halt|escalat.*halt' "$SKILL_MD" || \
    fail "SKILL.md does not halt the loop on requirement-change comments"

  # It must route to /gaia-add-feature
  grep -qF 'gaia-add-feature' "$SKILL_MD" || \
    fail "SKILL.md does not route escalated comments to feature intake"

  # It must invoke design-record.sh add-review --verdict escalated
  grep -qE 'add-review.*--verdict.*escalated|verdict.*escalated' "$SKILL_MD" || \
    fail "SKILL.md does not record an escalated verdict"

  # NO state transition on escalation
  grep -qiE 'no.*state.*transition.*escalat|escalat.*no.*transition|no.*iteration.*bump.*escalat' "$SKILL_MD" || \
    fail "SKILL.md does not prevent state transition on escalation"
}

@test "(AC5) structural: SKILL.md does not absorb requirement comments as design changes" {
  # The SKILL.md must NOT contain language that applies requirement-change
  # comments as design changes — the escalation firewall must halt instead.
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist"

  local absorb_patterns
  absorb_patterns="$(grep -inE 'apply.*requirement.*change.*design|absorb.*requirement.*comment' "$SKILL_MD" || true)"
  [ -z "$absorb_patterns" ] || \
    fail "SKILL.md absorbs requirement comments as design changes: $absorb_patterns"
}

@test "(AC5) escalation tells the stakeholder what happened" {
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist"

  # The SKILL.md must include user-facing explanation of the escalation
  grep -qiE 'explain.*stakeholder|tell.*stakeholder|inform.*stakeholder|user.facing.*escalat' "$SKILL_MD" || \
    fail "SKILL.md does not explain the escalation to the stakeholder"
}


# =========================================================================
# Edge cases
# =========================================================================

@test "(AC-EC1) high-severity internal findings block stakeholder delivery" {
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist"

  # The SKILL.md must gate stakeholder delivery on internal findings severity
  grep -qiE 'high.*severity.*block|block.*stakeholder.*high|internal.*finding.*block' "$SKILL_MD" || \
    fail "SKILL.md does not block stakeholder delivery on high-severity internal findings"
}

@test "(AC-EC1) user can explicitly accept internal findings and proceed" {
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist"

  # The SKILL.md must allow user override of the internal-findings gate
  grep -qiE 'accept.*finding.*proceed|override.*internal|user.*accept.*proceed|add-override' "$SKILL_MD" || \
    fail "SKILL.md does not allow user to accept internal findings and proceed"
}

@test "(AC-EC2) no stakeholder response keeps record in review and gate halting" {
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist"

  # The SKILL.md must handle the no-response scenario
  grep -qiE 'no.*response.*review|no.*stakeholder.*response|remain.*review|stay.*review' "$SKILL_MD" || \
    fail "SKILL.md does not handle absent stakeholder responses"
}

@test "(AC-EC3) contradictory stakeholder verdicts treated as changes-requested" {
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist — contradictory verdict handling cannot be verified"
  [ -x "$DESIGN_RECORD_SH" ] || fail "design-record.sh does not exist or is not executable"

  local root
  root="$(_seed_temp_project)"
  _seed_record "$root" "review"
  _seed_stakeholder_roster "$root"
  export PROJECT_ROOT="$root"

  local record="$root/.gaia/state/design-record.yaml"
  local pre_iter
  pre_iter="$(yq '.iteration' "$record")"

  # Stakeholder A approves (add-review AND approve)
  run "$DESIGN_RECORD_SH" add-review \
    --verdict approved --reviewer "stakeholder-A" --kind stakeholder
  [ "$status" -eq 0 ] || fail "add-review for A failed: $output"
  run "$DESIGN_RECORD_SH" approve \
    --stakeholder "stakeholder-A" --recorded-by "test-actor"
  [ "$status" -eq 0 ] || fail "approve for A failed: $output"

  # Stakeholder B requests changes (add-review only, NO approve call)
  run "$DESIGN_RECORD_SH" add-review \
    --verdict changes-requested --reviewer "stakeholder-B" --kind stakeholder
  [ "$status" -eq 0 ] || fail "add-review for B failed: $output"

  # (a) reviews[] length increased by 2
  local reviews_len
  reviews_len="$(yq '.reviews | length' "$record")"
  [ "$reviews_len" -eq 2 ] || fail "expected 2 reviews, got $reviews_len"

  # (b) approvals[] length increased by 1 (only A's approve)
  local approvals_len
  approvals_len="$(yq '.approvals | length' "$record")"
  [ "$approvals_len" -eq 1 ] || fail "expected 1 approval (only A), got $approvals_len"

  # (c) check-convergence reports not-converged with B missing
  run "$DESIGN_RECORD_SH" check-convergence
  [ "$status" -eq 1 ] || fail "check-convergence should exit 1 when not converged — got $status"
  [[ "$output" == *"not-converged"* ]] || \
    fail "convergence should report not-converged with B missing — got: $output"

  # (d) transition review->review (iteration bumps)
  run "$DESIGN_RECORD_SH" transition --to review --actor "test-actor"
  [ "$status" -eq 0 ] || fail "review->review transition failed: $output"

  local post_iter
  post_iter="$(yq '.iteration' "$record")"
  [ "$post_iter" -eq $(( pre_iter + 1 )) ] || \
    fail "iteration not bumped exactly once: pre=$pre_iter post=$post_iter"

  # (e) A's approval still present at old iteration; both missing at new iteration
  local a_approval_iter
  a_approval_iter="$(yq '.approvals[0].iteration' "$record")"
  [ "$a_approval_iter" -eq "$pre_iter" ] || \
    fail "A's approval iteration is $a_approval_iter, expected $pre_iter"

  run "$DESIGN_RECORD_SH" check-convergence
  [ "$status" -eq 1 ] || fail "check-convergence should exit 1 at new iteration — got $status"
  [[ "$output" == *"not-converged"* ]] || \
    fail "convergence at new iteration should report both A and B as missing — got: $output"

  rm -rf "$root"
}

@test "(AC-EC4) mixed comment halts on requirement part, does not apply design part" {
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist"

  # The SKILL.md must handle mixed comments by halting on the requirement part
  grep -qiE 'mixed.*comment|requirement.*part.*halt|design.*part.*not.*appl' "$SKILL_MD" || \
    fail "SKILL.md does not handle mixed comments (part requirement, part design)"
}

@test "(AC-EC5) divergent project re-read at delivery shows current state" {
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist"

  # The SKILL.md must re-read the project before stakeholder delivery
  local delivery_step
  delivery_step="$(awk '/^### Step.*[Dd]eliver/{found=1} found && /^### Step/ && !/[Dd]eliver/{exit} found{print}' "$SKILL_MD" 2>/dev/null | head -80)"
  [ -n "$delivery_step" ] || fail "SKILL.md has no stakeholder delivery step"

  printf '%s' "$delivery_step" | grep -qE 're-read|get_project|list_files|current.state|fresh.*read' || \
    fail "stakeholder delivery step does not re-read project for current state"
}

@test "(AC-EC6) abandoned round does not increment iteration" {
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist — abandoned round handling cannot be verified"
  [ -x "$DESIGN_RECORD_SH" ] || fail "design-record.sh does not exist or is not executable"

  local root
  root="$(_seed_temp_project)"
  _seed_record "$root" "review"
  _seed_stakeholder_roster "$root"
  export PROJECT_ROOT="$root"

  local record="$root/.gaia/state/design-record.yaml"
  local pre_iter
  pre_iter="$(yq '.iteration' "$record")"

  # Add a review but do NOT transition — round abandoned
  run "$DESIGN_RECORD_SH" add-review \
    --verdict changes-requested --reviewer "stakeholder-A" --kind stakeholder
  [ "$status" -eq 0 ] || fail "add-review failed: $output"

  # No transition call — round is abandoned
  local post_iter
  post_iter="$(yq '.iteration' "$record")"
  [ "$pre_iter" -eq "$post_iter" ] || \
    fail "iteration changed on abandoned round: $pre_iter -> $post_iter"

  # Prior approvals not stranded
  local approvals_len
  approvals_len="$(yq '.approvals | length' "$record")"
  [ "$approvals_len" -eq 0 ] || \
    fail "expected 0 approvals (nothing was approved), got $approvals_len"

  rm -rf "$root"
}


# =========================================================================
# (AC-EC7 backstop) verdict-provenance check
# =========================================================================

@test "(AC-EC7 backstop) verdict text matching boundary-marker content is rejected" {
  [ -x "$PROVENANCE_SCRIPT" ] || \
    fail "verdict-provenance-check.sh does not exist or is not executable: $PROVENANCE_SCRIPT"

  local root
  root="$(_seed_temp_project)"
  _seed_record "$root" "review"
  _seed_stakeholder_roster "$root"
  export PROJECT_ROOT="$root"

  local record="$root/.gaia/state/design-record.yaml"

  # Create boundary-marker-wrapped project content containing a sentinel
  local boundary_content
  boundary_content="$(cat <<'BOUNDARY'
<<<DESIGN_PROJECT_BOUNDARY>>>
This is the project read-back content.
It contains the distinctive literal MARKER_SENTINEL_e9f2a7 which should never appear in a verdict notes text under any circumstances.
<<<END_DESIGN_PROJECT_BOUNDARY>>>
BOUNDARY
)"

  # Candidate notes echoing a 40+ char substring from the boundary — should be rejected
  local candidate_notes="The review found distinctive literal MARKER_SENTINEL_e9f2a7 which should never appear"

  # Enable tracing
  export DESIGN_REVIEW_VERDICT_TRACE=1

  # Run the provenance check — should fail (non-zero exit)
  run "$PROVENANCE_SCRIPT" "$candidate_notes" "$boundary_content"
  [ "$status" -ne 0 ] || \
    fail "provenance check should reject verdict matching boundary-marker content"

  # stderr should contain a diagnostic naming the matched content
  [[ "$output" == *"MARKER_SENTINEL"* ]] || [[ "$output" == *"verbatim"* ]] || [[ "$output" == *"provenance"* ]] || \
    fail "provenance check should emit a diagnostic about the matched content"

  # The reviews[] length should be unchanged (no write occurred)
  local reviews_len
  reviews_len="$(yq '.reviews | length' "$record")"
  [ "$reviews_len" -eq 0 ] || fail "reviews[] should be empty — provenance check should have blocked the write"

  rm -rf "$root"
}

@test "(AC-EC7 backstop) provenance check accepts verdict with no boundary match" {
  [ -x "$PROVENANCE_SCRIPT" ] || \
    fail "verdict-provenance-check.sh does not exist or is not executable: $PROVENANCE_SCRIPT"

  local boundary_content
  boundary_content="$(cat <<'BOUNDARY'
<<<DESIGN_PROJECT_BOUNDARY>>>
This is the project read-back content with specific project terms.
<<<END_DESIGN_PROJECT_BOUNDARY>>>
BOUNDARY
)"

  # Candidate notes with no verbatim overlap — should pass
  local candidate_notes="The overall design quality is excellent with minor spacing issues"

  run "$PROVENANCE_SCRIPT" "$candidate_notes" "$boundary_content"
  [ "$status" -eq 0 ] || \
    fail "provenance check should accept verdict with no boundary-marker match: $output"
}

@test "(AC-EC7 backstop) provenance check rejects with argument errors" {
  [ -x "$PROVENANCE_SCRIPT" ] || \
    fail "verdict-provenance-check.sh does not exist or is not executable: $PROVENANCE_SCRIPT"

  # Missing arguments
  run "$PROVENANCE_SCRIPT"
  [ "$status" -ne 0 ] || fail "provenance check should fail on missing arguments"

  # Only one argument
  run "$PROVENANCE_SCRIPT" "some notes"
  [ "$status" -ne 0 ] || fail "provenance check should fail on single argument"
}


# =========================================================================
# Missing mutant tests
# =========================================================================

@test "(AC-EC3) mutant: skipping approve call leaves approvals unchanged" {
  # Proves the approve verb is load-bearing for convergence.
  # If the skill only calls add-review but skips the approve verb,
  # approvals[] does not grow and convergence stays false.
  [ -x "$DESIGN_RECORD_SH" ] || fail "design-record.sh does not exist or is not executable"

  local root
  root="$(_seed_temp_project)"
  _seed_record "$root" "review"
  _seed_stakeholder_roster "$root"
  export PROJECT_ROOT="$root"

  local record="$root/.gaia/state/design-record.yaml"

  # Stakeholder A: add-review only, skip the approve call (mutant behaviour)
  run "$DESIGN_RECORD_SH" add-review \
    --verdict approved --reviewer "stakeholder-A" --kind stakeholder
  [ "$status" -eq 0 ] || fail "add-review for A failed: $output"

  # Approvals[] must be empty — the approve verb was never called
  local approvals_len
  approvals_len="$(yq '.approvals | length' "$record")"
  [ "$approvals_len" -eq 0 ] || \
    fail "mutant: approvals[] grew to $approvals_len without calling the approve verb"

  # Convergence must report not-converged
  run "$DESIGN_RECORD_SH" check-convergence
  [ "$status" -eq 1 ] || fail "mutant: check-convergence should exit 1 — got $status"
  [[ "$output" == *"not-converged"* ]] || \
    fail "mutant: convergence reports converged without any approve calls — got: $output"

  rm -rf "$root"
}

@test "(AC4) mutant: vacuous-convergence warning absent when stderr is swallowed" {
  # Proves the SKILL.md must call check-convergence BEFORE transition,
  # because transition silences the vacuous-convergence stderr.
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist — convergence ordering cannot be verified"
  [ -x "$DESIGN_RECORD_SH" ] || fail "design-record.sh does not exist or is not executable"

  local root
  root="$(_seed_temp_project)"
  _seed_record "$root" "review"
  # No stakeholders — vacuous convergence
  export PROJECT_ROOT="$root"

  # check-convergence emits the vacuous warning on stderr
  run "$DESIGN_RECORD_SH" check-convergence
  [[ "$output" == *"vacuous"* ]] || \
    fail "precondition: check-convergence should emit vacuous warning"

  # transition silences convergence stderr — the warning is lost.
  # Vacuous convergence allows the transition, so it must succeed.
  run "$DESIGN_RECORD_SH" transition --to approved --actor "test-actor"
  [ "$status" -eq 0 ] || \
    fail "transition should succeed with vacuous convergence, but exit=$status: $output"

  # The vacuous-convergence warning must NOT appear in the transition output.
  # This proves: if the SKILL.md calls transition instead of check-convergence,
  # the user never sees the vacuous-convergence warning.
  [[ "$output" != *"vacuous"* ]] || \
    fail "mutant is vacuous: transition surfaces the vacuous warning (should be silent)"

  rm -rf "$root"
}

@test "(AC4) structural: SKILL.md orders check-convergence before transition in the approval path" {
  # Guards the SKILL.md ordering rule: check-convergence MUST appear on an
  # earlier line than transition in the "all approved" block of Step 5.
  # Without this, transition silences convergence stderr and the user never
  # sees the vacuous-convergence warning.
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist — ordering rule cannot be verified"

  # Extract Step 5 (the convergence and transition step)
  local step5
  step5="$(awk '
    /^### Step 5/ { found=1 }
    found && /^### Step [^5]/ { exit }
    found { print }
  ' "$SKILL_MD" 2>/dev/null)"
  [ -n "$step5" ] || fail "SKILL.md has no Step 5 block"

  # Within Step 5, find the "all approved" sub-block (bullet 3)
  local approved_block
  approved_block="$(printf '%s\n' "$step5" | awk '
    /all.*approved|If all.*approved/ { found=1 }
    found && /^[0-9]+\.\s/ && !/all.*approved|If all.*approved/ { exit }
    found { print }
  ')"
  [ -n "$approved_block" ] || fail "Step 5 has no 'all approved' sub-block"

  # Match the writer INVOCATION forms only (design-record.sh ... verb), not
  # prose mentions like "check-convergence reports" or "(before transition)".
  local conv_line trans_line
  conv_line="$(printf '%s\n' "$approved_block" | grep -nE 'design-record\.sh[^`]*check-convergence|design-record\.sh check-convergence' | head -1 | cut -d: -f1)"
  trans_line="$(printf '%s\n' "$approved_block" | grep -nE 'design-record\.sh[^`]*transition --to|design-record\.sh transition --to' | head -1 | cut -d: -f1)"

  [ -n "$conv_line" ] || fail "check-convergence writer invocation not found in the approval path"
  [ -n "$trans_line" ] || fail "transition writer invocation not found in the approval path"
  [ "$conv_line" -lt "$trans_line" ] || \
    fail "check-convergence (line $conv_line) does not precede transition (line $trans_line) in the approval path"
}

@test "(AC-EC7 backstop) structural: SKILL.md calls verdict-provenance-check before add-review" {
  # The verdict-write step in the SKILL.md must invoke
  # verdict-provenance-check.sh BEFORE design-record.sh add-review.
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist — cannot verify provenance wiring"

  # Find the step block that contains add-review (capture the full block)
  local step_block
  step_block="$(awk '
    /^### Step/ { if (buf ~ /add-review/) print buf; buf="" }
    { buf = buf $0 "\n" }
    END { if (buf ~ /add-review/) print buf }
  ' "$SKILL_MD" 2>/dev/null)"
  [ -n "$step_block" ] || fail "SKILL.md has no step block containing add-review"

  # Within that block, verdict-provenance-check must appear
  printf '%s' "$step_block" | grep -q 'verdict-provenance-check' || \
    fail "SKILL.md does not call verdict-provenance-check.sh in the add-review step"

  # Provenance check must appear BEFORE add-review in the step block
  local prov_line add_line
  prov_line="$(printf '%s' "$step_block" | grep -n 'verdict-provenance-check' | head -1 | cut -d: -f1)"
  add_line="$(printf '%s' "$step_block" | grep -n 'add-review' | head -1 | cut -d: -f1)"
  [ -n "$prov_line" ] && [ -n "$add_line" ] || \
    fail "could not locate both provenance-check and add-review in the step block"
  [ "$prov_line" -lt "$add_line" ] || \
    fail "verdict-provenance-check appears AFTER add-review (line $prov_line vs $add_line) — must come before"
}


# =========================================================================
# Documentation site integration
# =========================================================================

@test "(AC1) documentation page exists for design-review command" {
  local doc_page="$PLUGIN_ROOT/../../documentation/commands/gaia-design-review.html"
  [ -f "$doc_page" ] || \
    fail "documentation page does not exist: documentation/commands/gaia-design-review.html"
}

@test "(AC1) documentation page is linked from reviews category" {
  local category_page="$PLUGIN_ROOT/../../documentation/categories/reviews.html"
  [ -f "$category_page" ] || fail "reviews.html category page does not exist"

  grep -q 'gaia-design-review' "$category_page" || \
    fail "reviews.html does not link to the gaia-design-review command page"
}
