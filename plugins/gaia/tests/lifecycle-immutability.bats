#!/usr/bin/env bats
# lifecycle-immutability.bats — assert that existing lifecycle-sequence.yaml
# nodes are unchanged and that the design gate registration does not disturb
# the solutioning entry-point set.
#
# No project-root .gaia/ access; all fixtures use mktemp.
# No internal identifiers in @test names.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LIFECYCLE_SEQ="$PLUGIN_ROOT/knowledge/lifecycle-sequence.yaml"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Pinned baseline: every pre-existing key with its phase and compact-JSON next
# ---------------------------------------------------------------------------
# Generated with:
#   for key in $(yq -r '.sequence | keys | .[]' <file>); do
#     phase=$(yq -r ".sequence.\"${key}\".phase // \"\"" <file>)
#     next=$(yq -o=json -I=0 ".sequence.\"${key}\".next" <file>)
#     printf '%s\t%s\t%s\n' "$key" "$phase" "$next"
#   done
# Any edit to a pre-existing node's phase or next edges will break T4.4/T4.5.
#
BASELINE_TSV=$(cat <<'BASELINE_END'
brainstorm-project	1-analysis	{"primary":"/gaia-market-research","alternatives":[{"command":"/gaia-domain-research","context":"If domain-specific research is needed first"},{"command":"/gaia-tech-research","context":"If technology evaluation is needed first"}]}
market-research	1-analysis	{"primary":"/gaia-domain-research","alternatives":[{"command":"/gaia-tech-research","context":"If technology evaluation is needed"},{"command":"/gaia-product-brief","context":"If all research is complete"}]}
domain-research	1-analysis	{"primary":"/gaia-tech-research","alternatives":[{"command":"/gaia-product-brief","context":"If all research is complete"}]}
technical-research	1-analysis	{"primary":"/gaia-advanced-elicitation","alternatives":[{"command":"/gaia-product-brief","context":"If skipping advanced elicitation — go directly to product brief"}]}
advanced-elicitation	1-analysis	{"primary":"/gaia-product-brief","alternatives":[{"command":"/gaia-create-prd","context":"If product brief already exists"}]}
create-product-brief	1-analysis	{"primary":"/gaia-create-prd"}
create-prd	2-planning	{"primary":"/gaia-val-validate"}
val-validate	2-planning	{"on_pass":"/gaia-create-ux","on_fail":"/gaia-edit-prd"}
edit-prd	2-planning	{"primary":"/gaia-val-validate"}
create-ux-design	2-planning	{"primary":"/gaia-review-a11y","alternatives":[{"command":"/gaia-create-arch","context":"If accessibility review will be done later"}]}
create-architecture	3-solutioning	{"primary":"/gaia-review-api","note":"Optional if APIs exist, otherwise skip to /gaia-adversarial","parallel":["/gaia-threat-model","/gaia-infra-design"]}
edit-architecture	3-solutioning	{"primary":"/gaia-adversarial","note":"Optional for MINOR edits, required for SIGNIFICANT","alternatives":[{"command":"/gaia-add-stories","context":"If cascade creates new stories"},{"command":"/gaia-test-design","context":"If cascade affects test plan"}]}
create-epics-stories	3-solutioning	{"primary":"/gaia-atdd","alternatives":[{"command":"/gaia-threat-model","context":"If threat modeling not yet done"}]}
security-threat-model	3-solutioning	{"primary":"/gaia-infra-design"}
infrastructure-design	3-solutioning	{"primary":"/gaia-trace"}
implementation-readiness	3-solutioning	{"primary":"/gaia-create-story","note":"Create and validate story files before sprint planning"}
create-story	4-implementation	{"primary":"/gaia-validate-story","alternatives":[{"command":"/gaia-create-story","context":"To create another story before validating"}]}
validate-story	4-implementation	{"on_pass":"/gaia-create-story","on_pass_note":"Create more stories, or run /gaia-sprint-plan when all stories are ready","on_fail":"/gaia-fix-story","alternatives":[{"command":"/gaia-sprint-plan","context":"When all stories are created and validated (ready-for-dev)"}]}
fix-story	4-implementation	{"primary":"/gaia-validate-story"}
sprint-planning	4-implementation	{"primary":"/gaia-dev-story","alternatives":[{"command":"/gaia-sprint-status","context":"To review current sprint state"}]}
dev-story	4-implementation	{"primary":"/gaia-check-dod","alternatives":[{"command":"/gaia-run-all-reviews","context":"If DoD was already verified"},{"command":"/gaia-code-review","context":"To run individual code review first"}]}
check-dod	4-implementation	{"on_pass":"/gaia-run-all-reviews","on_fail":"/gaia-dev-story"}
code-review	4-implementation	{"primary":"/gaia-run-all-reviews","alternatives":[{"command":"/gaia-dev-story","context":"If review found issues requiring code changes"}]}
qa-generate-tests	4-implementation	{"primary":"/gaia-run-all-reviews","alternatives":[{"command":"/gaia-dev-story","context":"If tests revealed implementation gaps"}]}
security-review	4-implementation	{"primary":"/gaia-run-all-reviews","alternatives":[{"command":"/gaia-dev-story","context":"If security issues require code changes"}]}
run-all-reviews	4-implementation	{"primary":"/gaia-check-review-gate","alternatives":[{"command":"/gaia-dev-story","context":"If any review failed and code changes are needed"}]}
check-review-gate	4-implementation	{"on_all_passed":"/gaia-sprint-status","on_failures":"/gaia-dev-story","on_pending":"/gaia-run-all-reviews"}
val-validate-artifact	4-implementation	{"standalone":true,"note":"Invoked inline by workflow engine at template-output checkpoints"}
val-validate-plan	4-implementation	{"standalone":true,"note":"Invoked inline by workflow engine at planning gate"}
val-refresh-ground-truth	4-implementation	{"standalone":true,"suggestions":[{"command":"/gaia-val-validate","context":"To validate an artifact using refreshed ground truth"}]}
change-request	4-implementation	{"primary":"/gaia-add-stories","alternatives":[{"command":"/gaia-correct-course","context":"If sprint scope needs adjustment"},{"command":"/gaia-edit-arch","context":"If architecture changes are needed"}]}
add-stories	4-implementation	{"primary":"/gaia-trace","note":"Update traceability matrix with new stories","alternatives":[{"command":"/gaia-sprint-plan","context":"To plan a sprint with the new stories"},{"command":"/gaia-correct-course","context":"If current sprint scope needs adjustment"}]}
sprint-status	4-implementation	{"context_dependent":true,"note":"Suggest based on sprint state — if stories in backlog: /gaia-create-story; if invalid: /gaia-correct-course; if all done: /gaia-retro"}
epic-status	4-implementation	{"primary":"/gaia-sprint-plan","alternatives":[{"command":"/gaia-sprint-status","context":"To check current sprint progress"}]}
correct-course	4-implementation	{"primary":"/gaia-sprint-status","alternatives":[{"command":"/gaia-sprint-plan","context":"If re-planning is needed"}]}
triage-findings	4-implementation	{"primary":"/gaia-add-stories","alternatives":[{"command":"/gaia-create-story","context":"To create individual stories from triaged findings"}]}
action-items	4-implementation	{"standalone":true}
retrospective	4-implementation	{"primary":"/gaia-sprint-plan","alternatives":[{"command":"/gaia-release-plan","context":"If all epics are complete and ready for deployment"}]}
release-plan	5-deployment	{"primary":"/gaia-rollback-plan","parallel":["/gaia-deploy-checklist"]}
rollback-plan	5-deployment	{"primary":"/gaia-deploy-checklist"}
deployment-checklist	5-deployment	{"primary":"/gaia-deploy-post","note":"Deploy to production first, then run post-deploy verification"}
post-deploy-verify	5-deployment	{"terminal":true,"note":"Lifecycle complete. Start new cycle with /gaia-retro for lessons learned."}
brainstorming		{"standalone":true,"note":"Return to current lifecycle phase"}
bridge-toggle		{"standalone":true,"note":"Run /gaia-build-configs to regenerate resolved configs after toggling"}
party-mode		{"standalone":true,"note":"Return to current lifecycle phase"}
add-feature		{"primary":"/gaia-sprint-plan","note":"Orchestrator cascades through PRD → architecture → test plan → stories → traceability → readiness","alternatives":[{"command":"/gaia-correct-course","context":"If new stories should enter current sprint"},{"command":"/gaia-create-story","context":"To elaborate individual stories before sprint planning"}]}
brownfield-onboarding		{"standalone":true,"suggestions":[{"command":"/gaia-create-arch","context":"To formalize the discovered architecture"},{"command":"/gaia-test-design","context":"To create a test plan for the existing project"}]}
document-project		{"standalone":true}
generate-project-context		{"standalone":true}
memory-hygiene		{"standalone":true,"note":"Run periodically to detect stale or contradicted decisions in agent memory sidecars"}
create-stakeholder		{"standalone":true,"suggestions":[{"command":"/gaia-party","context":"To start a Party Mode discussion with the new stakeholder"}]}
performance-review		{"standalone":true,"suggestions":[{"command":"/gaia-dev-story","context":"To implement performance fixes"}]}
validate-prd		{"standalone":true,"note":"Deprecated — superseded by /gaia-val-validate."}
edit-ux-design		{"standalone":true,"note":"Standalone UX design editor"}
quick-spec		{"primary":"/gaia-quick-dev"}
quick-dev		{"primary":"/gaia-code-review"}
edit-test-plan		{"standalone":true,"suggestions":[{"command":"/gaia-atdd","context":"To generate acceptance tests for high-risk stories"},{"command":"/gaia-trace","context":"To update traceability matrix with new test cases"}]}
test-design		{"primary":"/gaia-create-epics","note":"Test plan is required before creating epics"}
test-framework		{"standalone":true,"suggestions":[{"command":"/gaia-test-design","context":"To create a test plan using the framework"}]}
ci-setup		{"primary":"/gaia-readiness-check"}
ci-edit		{"standalone":true,"suggestions":[{"command":"/gaia-build-configs","context":"Regenerate resolved configs after editing the promotion chain"}]}
atdd		{"primary":"/gaia-threat-model","alternatives":[{"command":"/gaia-trace","context":"If threat model and infra design are already done"}]}
test-automation		{"standalone":true,"suggestions":[{"command":"/gaia-run-all-reviews","context":"To complete the review gate"}]}
test-review		{"standalone":true,"suggestions":[{"command":"/gaia-run-all-reviews","context":"To complete the review gate"}]}
test-gap-analysis		{"standalone":true,"suggestions":[{"command":"/gaia-sprint-plan","context":"To schedule remediation stories discovered by the gap analysis"},{"command":"/gaia-trace","context":"To update traceability matrix after closing coverage gaps"},{"command":"/gaia-test-design","context":"To redesign the test plan based on gap analysis findings"}]}
fill-test-gaps		{"standalone":true,"suggestions":[{"command":"/gaia-test-gap-analysis","context":"To regenerate the gap analysis report before triaging"},{"command":"/gaia-sprint-plan","context":"To schedule remediation stories from the triage table"}]}
traceability		{"primary":"/gaia-ci-setup"}
nfr-assessment		{"standalone":true,"suggestions":[{"command":"/gaia-test-design","context":"To design tests covering the assessed NFRs"}]}
accessibility-testing		{"standalone":true}
performance-testing		{"standalone":true}
mobile-testing		{"standalone":true}
teach-me-testing		{"standalone":true}
review-a11y		{"primary":"/gaia-create-arch","note":"When used in lifecycle flow (after UX design)"}
design-thinking		{"standalone":true,"suggestions":[{"command":"/gaia-create-ux","context":"To translate design thinking insights into UX specs"}]}
innovation-strategy		{"standalone":true}
problem-solving		{"standalone":true}
storytelling		{"standalone":true}
slide-deck		{"standalone":true}
pitch-deck		{"standalone":true}
creative-sprint		{"standalone":true,"suggestions":[{"command":"/gaia-product-brief","context":"To formalize creative sprint outputs"}]}
BASELINE_END
)

# Pinned key order (document order, extracted via yq keys)
BASELINE_KEYS=(
  brainstorm-project
  market-research
  domain-research
  technical-research
  advanced-elicitation
  create-product-brief
  create-prd
  val-validate
  edit-prd
  create-ux-design
  create-architecture
  edit-architecture
  create-epics-stories
  security-threat-model
  infrastructure-design
  implementation-readiness
  create-story
  validate-story
  fix-story
  sprint-planning
  dev-story
  check-dod
  code-review
  qa-generate-tests
  security-review
  run-all-reviews
  check-review-gate
  val-validate-artifact
  val-validate-plan
  val-refresh-ground-truth
  change-request
  add-stories
  sprint-status
  epic-status
  correct-course
  triage-findings
  action-items
  retrospective
  release-plan
  rollback-plan
  deployment-checklist
  post-deploy-verify
  brainstorming
  bridge-toggle
  party-mode
  add-feature
  brownfield-onboarding
  document-project
  generate-project-context
  memory-hygiene
  create-stakeholder
  performance-review
  validate-prd
  edit-ux-design
  quick-spec
  quick-dev
  edit-test-plan
  test-design
  test-framework
  ci-setup
  ci-edit
  atdd
  test-automation
  test-review
  test-gap-analysis
  fill-test-gaps
  traceability
  nfr-assessment
  accessibility-testing
  performance-testing
  mobile-testing
  teach-me-testing
  review-a11y
  design-thinking
  innovation-strategy
  problem-solving
  storytelling
  slide-deck
  pitch-deck
  creative-sprint
)

# The eight solutioning entry points (same derivation and pin as
# design-gate-sites.bats).
EIGHT_SITES=(
  gaia-adversarial
  gaia-create-arch
  gaia-create-epics
  gaia-edit-arch
  gaia-infra-design
  gaia-readiness-check
  gaia-review-api
  gaia-threat-model
)

# ===========================================================================
# T4.1: design-review node exists with correct command and next
# ===========================================================================

@test "lifecycle-sequence.yaml contains design-review node" {
  [ -f "$LIFECYCLE_SEQ" ] || {
    echo "FAIL: lifecycle-sequence.yaml not found at $LIFECYCLE_SEQ" >&2
    return 1
  }
  local cmd
  cmd="$(yq -r '.sequence."design-review".command // ""' "$LIFECYCLE_SEQ")"
  [ "$cmd" = "/gaia-design-review" ] || {
    echo "FAIL: design-review node missing or has wrong command (got: '$cmd')" >&2
    return 1
  }
  local next_primary
  next_primary="$(yq -r '.sequence."design-review".next.primary // ""' "$LIFECYCLE_SEQ")"
  [ "$next_primary" = "/gaia-create-arch" ] || {
    echo "FAIL: design-review next.primary should be /gaia-create-arch (got: '$next_primary')" >&2
    return 1
  }
}

# ===========================================================================
# T4.2: design-review node has phase 2-planning
# ===========================================================================

@test "design-review node has phase 2-planning" {
  [ -f "$LIFECYCLE_SEQ" ] || {
    echo "FAIL: lifecycle-sequence.yaml not found" >&2
    return 1
  }
  local phase
  phase="$(yq -r '.sequence."design-review".phase // ""' "$LIFECYCLE_SEQ")"
  [ "$phase" = "2-planning" ] || {
    echo "FAIL: design-review phase should be 2-planning (got: '$phase')" >&2
    return 1
  }
}

# ===========================================================================
# T4.3: pre-existing keys are in the same order
# ===========================================================================

@test "pre-existing nodes keys are in the same order" {
  [ -f "$LIFECYCLE_SEQ" ] || {
    echo "FAIL: lifecycle-sequence.yaml not found" >&2
    return 1
  }
  local current_keys
  current_keys="$(yq -r '.sequence | keys | .[]' "$LIFECYCLE_SEQ")"

  # Every baseline key must appear in current_keys in the same relative order
  local prev_idx=-1
  for bk in "${BASELINE_KEYS[@]}"; do
    local idx=0 found=false
    while IFS= read -r ck; do
      if [ "$ck" = "$bk" ]; then
        found=true
        break
      fi
      idx=$((idx + 1))
    done <<< "$current_keys"
    if ! $found; then
      echo "FAIL: baseline key '$bk' missing from lifecycle-sequence.yaml" >&2
      return 1
    fi
    if [ "$idx" -le "$prev_idx" ]; then
      echo "FAIL: baseline key '$bk' is out of order (idx $idx <= prev $prev_idx)" >&2
      return 1
    fi
    prev_idx=$idx
  done
}

# ===========================================================================
# T4.4: pre-existing nodes phases unchanged
# ===========================================================================

@test "pre-existing nodes phases unchanged" {
  [ -f "$LIFECYCLE_SEQ" ] || {
    echo "FAIL: lifecycle-sequence.yaml not found" >&2
    return 1
  }
  # Use awk to split on tab (handles empty fields properly, unlike bash read)
  local line_count
  line_count="$(printf '%s\n' "$BASELINE_TSV" | grep -c '.' || true)"
  [ "$line_count" -gt 0 ] || {
    echo "FAIL: baseline is empty" >&2
    return 1
  }
  local i=1
  while [ "$i" -le "$line_count" ]; do
    local key expected_phase
    key="$(printf '%s\n' "$BASELINE_TSV" | awk -F'\t' "NR==$i{print \$1}")"
    expected_phase="$(printf '%s\n' "$BASELINE_TSV" | awk -F'\t' "NR==$i{print \$2}")"
    [ -n "$key" ] || { i=$((i+1)); continue; }
    local actual_phase
    actual_phase="$(yq -r ".sequence.\"${key}\".phase // \"\"" "$LIFECYCLE_SEQ")"
    [ "$actual_phase" = "$expected_phase" ] || {
      echo "FAIL: node '$key' phase changed from '$expected_phase' to '$actual_phase'" >&2
      return 1
    }
    i=$((i+1))
  done
}

# ===========================================================================
# T4.5: pre-existing nodes next edges unchanged
# ===========================================================================

@test "pre-existing nodes next edges unchanged" {
  [ -f "$LIFECYCLE_SEQ" ] || {
    echo "FAIL: lifecycle-sequence.yaml not found" >&2
    return 1
  }
  # Use awk to split on tab (handles empty fields properly, unlike bash read)
  local line_count
  line_count="$(printf '%s\n' "$BASELINE_TSV" | grep -c '.' || true)"
  [ "$line_count" -gt 0 ] || {
    echo "FAIL: baseline is empty" >&2
    return 1
  }
  local i=1
  while [ "$i" -le "$line_count" ]; do
    local key expected_next
    key="$(printf '%s\n' "$BASELINE_TSV" | awk -F'\t' "NR==$i{print \$1}")"
    expected_next="$(printf '%s\n' "$BASELINE_TSV" | awk -F'\t' "NR==$i{print \$3}")"
    [ -n "$key" ] || { i=$((i+1)); continue; }
    local actual_next
    actual_next="$(yq -o=json -I=0 ".sequence.\"${key}\".next" "$LIFECYCLE_SEQ")"
    [ "$actual_next" = "$expected_next" ] || {
      echo "FAIL: node '$key' next edges changed" >&2
      echo "  expected: $expected_next" >&2
      echo "  actual:   $actual_next" >&2
      return 1
    }
    i=$((i+1))
  done
}

# ===========================================================================
# T4.6: the solutioning entry-point set is still exactly eight
# ===========================================================================

@test "design-gate-sites derived set is still exactly eight" {
  [ -f "$LIFECYCLE_SEQ" ] || {
    echo "FAIL: lifecycle-sequence.yaml not found" >&2
    return 1
  }

  # Derive phase-3 node commands
  local phase3_nodes
  phase3_nodes="$(yq '.sequence | to_entries[] | select(.value.phase == "3-solutioning") | .value.command' "$LIFECYCLE_SEQ" | sed 's|^/||')"

  # Derive edge targets of phase-3 nodes
  local phase3_edges=""
  local node_keys
  node_keys="$(yq '.sequence | to_entries[] | select(.value.phase == "3-solutioning") | .key' "$LIFECYCLE_SEQ")"

  while IFS= read -r node_key; do
    [ -n "$node_key" ] || continue
    local edges
    edges="$(yq ".sequence.\"$node_key\".next | .. | select(tag == \"!!str\") | select(test(\"^/gaia-\"))" "$LIFECYCLE_SEQ" 2>/dev/null | sed 's|^/||' || true)"
    if [ -n "$edges" ]; then
      phase3_edges="${phase3_edges}${phase3_edges:+
}${edges}"
    fi
  done <<< "$node_keys"

  # Union nodes + edges
  local all_candidates
  all_candidates="$(printf '%s\n%s\n' "$phase3_nodes" "$phase3_edges" | sort -u)"

  # Exclude edge targets that are commands of any node NOT in phase 3-solutioning
  local non_phase3_commands
  non_phase3_commands="$(yq '.sequence | to_entries[] | select(.value.phase != "3-solutioning" or .value.phase == null) | .value.command // ""' "$LIFECYCLE_SEQ" | sed 's|^/||' | grep -v '^$' | sort -u)"

  local derived_set=""
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    if ! echo "$non_phase3_commands" | grep -qxF "$cand"; then
      derived_set="${derived_set}${derived_set:+
}${cand}"
    fi
  done <<< "$all_candidates"

  derived_set="$(echo "$derived_set" | sort -u)"

  # The pinned set
  local pinned
  pinned="$(printf '%s\n' "${EIGHT_SITES[@]}" | sort -u)"

  if [ "$derived_set" != "$pinned" ]; then
    echo "FAIL: derived solutioning set does not equal pinned eight" >&2
    echo "  Derived: $(echo "$derived_set" | tr '\n' ' ')" >&2
    echo "  Pinned:  $(echo "$pinned" | tr '\n' ' ')" >&2
    return 1
  fi
}
