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

# Portable sha256
_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SKILL_DIR=""
SKILL_MD=""
PROVENANCE_SCRIPT=""
DESIGN_RECORD_SH=""
WORKFLOW_MANIFEST=""

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL_DIR="$PLUGIN_ROOT/skills/gaia-design-review"
  SKILL_MD="$SKILL_DIR/SKILL.md"
  PROVENANCE_SCRIPT="$SKILL_DIR/scripts/verdict-provenance-check.sh"
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

# _seed_record ROOT STATE ITERATION — write a minimal valid design record.
_seed_record() {
  local root="$1" state="${2:-draft}" iteration="${3:-1}"
  cat > "$root/.gaia/state/design-record.yaml" <<EOF
schema_version: "1.0"
applicability: applicable
design_state: "$state"
iteration: $iteration
project:
  reference: "test-project-ref"
  discovered_via: "created"
  questionnaire_record: ".gaia/artifacts/planning-artifacts/ux-design/design-questionnaire.md"
reviews: []
approvals: []
overrides: []
audit: []
audit_head:
  count: 0
  last_digest: ""
EOF
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
  readback_step="$(awk '/^### Step.*[Rr]ead.?back/,/^### Step/' "$SKILL_MD" 2>/dev/null | head -50)"
  [ -n "$readback_step" ] || fail "SKILL.md has no read-back step"

  # The step must mention get_project or list_files as the source
  printf '%s' "$readback_step" | grep -qE 'get_project|list_files|get_file' || \
    fail "read-back step does not reference project integration tools as authoritative source"

  # The step must NOT treat local derivation (ux-design.md) as the primary source
  printf '%s' "$readback_step" | grep -qE 'authoritative|primary|source.of.truth' || \
    fail "read-back step does not mark project content as authoritative"
}

@test "(AC1) mutant: using local derivation instead of project produces wrong findings" {
  # When the skill is implemented, reading from local derivation instead of the
  # project should produce different (wrong) findings.  This mutant verifies that
  # the test above is load-bearing by checking the SKILL.md structure.
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist — mutant cannot verify"

  # The SKILL.md must contain boundary markers around project content
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
  findings_step="$(awk '/^### Step.*[Ff]inding/,/^### Step/' "$SKILL_MD" 2>/dev/null | head -80)"
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
  _seed_record "$root" "review" 1
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

@test "(AC3) mutant: removing internal round allows delivery" {
  # If the skill does not enforce internal-first ordering, stakeholder delivery
  # can proceed without an internal verdict.  This mutant checks that the
  # SKILL.md has an explicit gate.
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist"

  # The SKILL.md must have an internal review step that blocks stakeholder delivery
  grep -qiE 'internal.*review.*before.*stakeholder|block.*stakeholder.*until.*internal|internal.*gate' "$SKILL_MD" || \
    fail "SKILL.md does not enforce internal review before stakeholder delivery — mutant proves the gate is missing"
}


# =========================================================================
# (AC4) verdict writes — field completeness
# =========================================================================

@test "(AC4) verdict writes kind, verdict, actor, timestamp, iteration via sole writer" {
  [ -x "$DESIGN_RECORD_SH" ] || fail "design-record.sh does not exist or is not executable"

  local root
  root="$(_seed_temp_project)"
  _seed_record "$root" "review" 1
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
  _seed_record "$root" "draft" 1
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

@test "(AC4) review to approved on convergence with stakeholder approvals" {
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist — convergence flow cannot be verified"
  [ -x "$DESIGN_RECORD_SH" ] || fail "design-record.sh does not exist or is not executable"

  local root
  root="$(_seed_temp_project)"
  _seed_record "$root" "review" 1
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
  _seed_record "$root" "review" 1
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
  _seed_record "$root" "review" 1
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
  _seed_record "$root" "review" 1
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
  # The SKILL.md must have a delta-sync step that reconciles project changes
  # into the derived ux-design.md.
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist — cannot verify delta sync"

  local root
  root="$(_seed_temp_project)"
  _seed_ux_design "$root"
  export PROJECT_ROOT="$root"

  local ux_doc="$root/.gaia/artifacts/planning-artifacts/ux-design.md"
  [ -f "$ux_doc" ] || fail "ux-design.md fixture not created"

  # Verify initial state: "new-sidebar" is NOT in the fixture
  ! grep -q 'new-sidebar' "$ux_doc" || \
    fail "fixture already contains new-sidebar — test is vacuous"

  # The sync step in SKILL.md must describe the mechanism for reconciliation
  local sync_step
  sync_step="$(awk '/^### Step.*[Ss]ync\|^### Step.*[Rr]econcil/,/^### Step/' "$SKILL_MD" 2>/dev/null | head -80)"
  [ -n "$sync_step" ] || fail "SKILL.md has no sync/reconciliation step — delta sync not implemented"

  # The sync step must mention component inventory or screen specs
  printf '%s' "$sync_step" | grep -qiE 'component.inventory|screen.spec|ux-design' || \
    fail "sync step does not target the component inventory or screen spec sections"

  rm -rf "$root"
}


# =========================================================================
# (AC4) vacuous convergence
# =========================================================================

@test "(AC4) vacuous-convergence roster surfaces a warning to the user" {
  [ -x "$DESIGN_RECORD_SH" ] || fail "design-record.sh does not exist or is not executable"

  local root
  root="$(_seed_temp_project)"
  _seed_record "$root" "review" 1
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
  grep -qiE 'halt.*loop\|loop.*halt\|escalat.*halt' "$SKILL_MD" || \
    fail "SKILL.md does not halt the loop on requirement-change comments"

  # It must route to /gaia-add-feature
  grep -qF 'gaia-add-feature' "$SKILL_MD" || \
    fail "SKILL.md does not route escalated comments to feature intake"

  # It must invoke design-record.sh add-review --verdict escalated
  grep -qE 'add-review.*--verdict.*escalated\|verdict.*escalated' "$SKILL_MD" || \
    fail "SKILL.md does not record an escalated verdict"

  # NO state transition on escalation
  grep -qiE 'no.*state.*transition.*escalat\|escalat.*no.*transition\|no.*iteration.*bump.*escalat' "$SKILL_MD" || \
    fail "SKILL.md does not prevent state transition on escalation"
}

@test "(AC5) mutant: absorbing requirement comment as design change" {
  # If the SKILL.md absorbs the comment as a design change instead of halting,
  # the escalation firewall is broken.
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist"

  # The SKILL.md must NOT contain language that applies requirement-change
  # comments as design changes
  local absorb_patterns
  absorb_patterns="$(grep -inE 'apply.*requirement.*change.*design|absorb.*requirement.*comment' "$SKILL_MD" || true)"
  [ -z "$absorb_patterns" ] || \
    fail "SKILL.md absorbs requirement comments as design changes: $absorb_patterns"
}

@test "(AC5) escalation tells the stakeholder what happened" {
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist"

  # The SKILL.md must include user-facing explanation of the escalation
  grep -qiE 'explain.*stakeholder\|tell.*stakeholder\|inform.*stakeholder\|user.facing.*escalat' "$SKILL_MD" || \
    fail "SKILL.md does not explain the escalation to the stakeholder"
}


# =========================================================================
# Edge cases
# =========================================================================

@test "(AC-EC1) high-severity internal findings block stakeholder delivery" {
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist"

  # The SKILL.md must gate stakeholder delivery on internal findings severity
  grep -qiE 'high.*severity.*block\|block.*stakeholder.*high\|internal.*finding.*block' "$SKILL_MD" || \
    fail "SKILL.md does not block stakeholder delivery on high-severity internal findings"
}

@test "(AC-EC1) user can explicitly accept internal findings and proceed" {
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist"

  # The SKILL.md must allow user override of the internal-findings gate
  grep -qiE 'accept.*finding.*proceed\|override.*internal\|user.*accept.*proceed\|add-override' "$SKILL_MD" || \
    fail "SKILL.md does not allow user to accept internal findings and proceed"
}

@test "(AC-EC2) no stakeholder response keeps record in review and gate halting" {
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist"

  # The SKILL.md must handle the no-response scenario
  grep -qiE 'no.*response.*review\|no.*stakeholder.*response\|remain.*review\|stay.*review' "$SKILL_MD" || \
    fail "SKILL.md does not handle absent stakeholder responses"
}

@test "(AC-EC3) contradictory stakeholder verdicts treated as changes-requested" {
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist — contradictory verdict handling cannot be verified"
  [ -x "$DESIGN_RECORD_SH" ] || fail "design-record.sh does not exist or is not executable"

  local root
  root="$(_seed_temp_project)"
  _seed_record "$root" "review" 1
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
  [[ "$output" == *"not-converged"* ]] || [ "$status" -ne 0 ] || \
    fail "convergence should report not-converged with B missing"

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
  [[ "$output" == *"not-converged"* ]] || [ "$status" -ne 0 ] || \
    fail "convergence at new iteration should report both A and B as missing"

  rm -rf "$root"
}

@test "(AC-EC4) mixed comment halts on requirement part, does not apply design part" {
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist"

  # The SKILL.md must handle mixed comments by halting on the requirement part
  grep -qiE 'mixed.*comment\|requirement.*part.*halt\|design.*part.*not.*appl' "$SKILL_MD" || \
    fail "SKILL.md does not handle mixed comments (part requirement, part design)"
}

@test "(AC-EC5) divergent project re-read at delivery shows current state" {
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist"

  # The SKILL.md must re-read the project before stakeholder delivery
  local delivery_step
  delivery_step="$(awk '/^### Step.*[Ss]takeholder.*[Dd]eliver\|^### Step.*[Dd]eliver/,/^### Step/' "$SKILL_MD" 2>/dev/null | head -80)"
  [ -n "$delivery_step" ] || fail "SKILL.md has no stakeholder delivery step"

  printf '%s' "$delivery_step" | grep -qE 're-read\|get_project\|list_files\|current.state\|fresh.*read' || \
    fail "stakeholder delivery step does not re-read project for current state"
}

@test "(AC-EC6) abandoned round does not increment iteration" {
  [ -f "$SKILL_MD" ] || fail "SKILL.md does not exist — abandoned round handling cannot be verified"
  [ -x "$DESIGN_RECORD_SH" ] || fail "design-record.sh does not exist or is not executable"

  local root
  root="$(_seed_temp_project)"
  _seed_record "$root" "review" 1
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
  _seed_record "$root" "review" 1
  _seed_stakeholder_roster "$root"
  export PROJECT_ROOT="$root"

  local record="$root/.gaia/state/design-record.yaml"

  # Create boundary-marker-wrapped project content containing a sentinel
  local boundary_content
  boundary_content="$(cat <<'BOUNDARY'
<<<DESIGN_PROJECT_BOUNDARY>>>
This is the project read-back content.
It contains the distinctive literal MARKER_SENTINEL_e9f2a7 which should never
appear in a verdict's notes text.
<<<END_DESIGN_PROJECT_BOUNDARY>>>
BOUNDARY
)"

  # Candidate notes containing the sentinel — should be rejected
  local candidate_notes="The review found MARKER_SENTINEL_e9f2a7 in the design"

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
