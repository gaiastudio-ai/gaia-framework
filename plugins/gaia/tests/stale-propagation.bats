#!/usr/bin/env bats
# stale-propagation.bats — stale-on-change propagation, gate consequence,
# edit-ux stale, dev-story refusal, removal sweep, and edge cases.
#
# Public functions covered: cmd_transition, design_gate_check,
# _gate_run_pre_start.

load 'test_helper.bash'

# ---------------------------------------------------------------------------
# Portable helpers
# ---------------------------------------------------------------------------

fail() { printf '%s\n' "$1" >&2; return 1; }

_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

_sha256_tree() {
  local dir="$1"
  find "$dir" -type f | LC_ALL=C sort | while IFS= read -r f; do
    _sha256_file "$f"
  done | _sha256_file /dev/stdin
}

# The eight solutioning entry points (from the merged design-gate-sites harness).
SITES=(
  gaia-create-arch
  gaia-edit-arch
  gaia-create-epics
  gaia-threat-model
  gaia-infra-design
  gaia-readiness-check
  gaia-review-api
  gaia-adversarial
)

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

seed_config() {
  local ui_present="${1:-true}"
  mkdir -p "$TEST_TMP/.gaia/config"
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<EOF
compliance:
  ui_present: $ui_present
EOF
}

# seed_full_config UI_PRESENT — create .gaia/config/project-config.yaml with
# all 11 required fields so resolve-config.sh passes. Used by setup.sh tests
# that need setup.sh to reach the quality-gate code path, not exit early in
# resolve-config. Modelled on design-gate-sites.bats.
seed_full_config() {
  local ui_present="${1:-true}"
  mkdir -p "$TEST_TMP/.gaia/config"
  mkdir -p "$TEST_TMP/.gaia/artifacts/planning-artifacts"
  mkdir -p "$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$TEST_TMP/.gaia/artifacts/test-artifacts"
  mkdir -p "$TEST_TMP/.gaia/artifacts/creative-artifacts"
  mkdir -p "$TEST_TMP/_memory/checkpoints"
  mkdir -p "$TEST_TMP/_gaia"
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<EOF
project_root: $TEST_TMP
project_path: $TEST_TMP
memory_path: $TEST_TMP/_memory
checkpoint_path: $TEST_TMP/_memory/checkpoints
installed_path: $TEST_TMP/_gaia
framework_version: 1.218.2
date: 2026-09-24
test_artifacts: $TEST_TMP/.gaia/artifacts/test-artifacts
planning_artifacts: $TEST_TMP/.gaia/artifacts/planning-artifacts
implementation_artifacts: $TEST_TMP/.gaia/artifacts/implementation-artifacts
creative_artifacts: $TEST_TMP/.gaia/artifacts/creative-artifacts
compliance:
  ui_present: $ui_present
ci_platform:
  provider: none
EOF
}

seed_roster() {
  local roster_dir="$TEST_TMP/.gaia/custom/stakeholders"
  mkdir -p "$roster_dir"
  cat > "$roster_dir/stakeholder-A.md" <<'STAKE'
---
name: "Stakeholder A"
slug: stakeholder-A
tags: [design]
---
STAKE
}

seed_sprint_status() {
  local sid="${1:-sprint-99}"
  mkdir -p "$TEST_TMP/.gaia/state"
  cat > "$TEST_TMP/.gaia/state/sprint-status.yaml" <<EOF
sprint_id: $sid
status: active
EOF
}

seed_lifecycle_overrides() {
  mkdir -p "$TEST_TMP/.gaia/state"
  printf 'bypasses: []\n' > "$TEST_TMP/.gaia/state/lifecycle-overrides.yaml"
}

_init_record() {
  env PROJECT_ROOT="$TEST_TMP" \
    "$DREC_SCRIPT" init \
      --reference "test-project-ref" \
      --discovered-via "created" \
      --questionnaire-record "not-applicable"
}

_build_approved_record() {
  _init_record
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor ci
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" add-review --verdict approved --reviewer stakeholder-A --actor ci
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" approve --stakeholder stakeholder-A --recorded-by ci
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to approved --actor ci
}

seed_probe_stub() {
  local state="${1:-available}"
  mkdir -p "$TEST_TMP/bin"
  cat > "$TEST_TMP/bin/design-probe.sh" <<STUBEOF
#!/usr/bin/env bash
set -euo pipefail
case "$state" in
  available) printf '%s\n' "available"; exit 0 ;;
  unauthorized) printf '%s\n' "unauthorized"; printf '%s\n' "Run /design-login to authorize." >&2; exit 1 ;;
  *) printf '%s\n' "missing"; printf '%s\n' "Enable the Claude Design integration." >&2; exit 1 ;;
esac
STUBEOF
  chmod +x "$TEST_TMP/bin/design-probe.sh"
}

# seed_site_prereqs SITE — seed the per-site prerequisite artifacts that the
# site's own gates check before reaching the design gate. Without these, the
# setup.sh exits at a validate-gate or guard check, never reaching the design
# gate. Mirrors design-gate-sites.bats.
seed_site_prereqs() {
  local site="$1"
  case "$site" in
    gaia-create-arch)
      mkdir -p "$TEST_TMP/.gaia/artifacts/planning-artifacts"
      printf '# threat model\n' > "$TEST_TMP/.gaia/artifacts/planning-artifacts/threat-model.md"
      ;;
    gaia-create-epics)
      mkdir -p "$TEST_TMP/.gaia/artifacts/test-artifacts/strategy"
      printf '# test plan\nscenarios:\n  - name: test\n' > "$TEST_TMP/.gaia/artifacts/test-artifacts/strategy/test-plan.md"
      ;;
    gaia-readiness-check)
      mkdir -p "$TEST_TMP/.gaia/artifacts/planning-artifacts"
      printf '# traceability\n|req|test|\n' > "$TEST_TMP/.gaia/artifacts/planning-artifacts/traceability-matrix.md"
      ;;
    # gaia-edit-arch, gaia-threat-model, gaia-infra-design, gaia-review-api,
    # gaia-adversarial: no site-specific prerequisite artifacts needed
  esac
}

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS_DIR="$PLUGIN_ROOT/scripts"
  SKILLS_DIR="$PLUGIN_ROOT/skills"
  DREC_SCRIPT="$SCRIPTS_DIR/design-record.sh"
  GATE_SCRIPT="$SCRIPTS_DIR/lib/design-gate.sh"
  PREDICATES_SCRIPT="$SCRIPTS_DIR/lib/gate-predicates.sh"

  SKILL_DIR_AF="$PLUGIN_ROOT/skills/gaia-add-feature"
  SKILL_DIR_UX="$PLUGIN_ROOT/skills/gaia-edit-ux"
  SKILL_DIR_DS="$PLUGIN_ROOT/skills/gaia-dev-story"
  SKILL_MD_AF="$SKILL_DIR_AF/SKILL.md"
  SKILL_MD_UX="$SKILL_DIR_UX/SKILL.md"
  SKILL_MD_DS="$SKILL_DIR_DS/SKILL.md"
  SETUP_SH_DS="$SKILL_DIR_DS/scripts/setup.sh"

  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT PROJECT_PATH CLAUDE_PLUGIN_ROOT 2>/dev/null || true
  mkdir -p "$TEST_TMP/.gaia/state"

  command -v yq >/dev/null 2>&1 || fail "yq is required but not found on PATH"
}

teardown() { common_teardown; }

# ===========================================================================
# AC1 — Stale-on-change in add-feature
# ===========================================================================

@test "(AC1) stale transition fires on design-affecting feature" {
  seed_config true
  seed_roster
  _build_approved_record

  local state_before
  state_before="$(yq '.design_state' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$state_before" = "approved" ]

  # Transition to stale with add-feature actor
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to stale --actor gaia-add-feature

  local state_after
  state_after="$(yq '.design_state' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$state_after" = "stale" ]

  # Verify audit entry records the actor
  local last_event last_actor last_to
  last_event="$(yq '.audit[-1].event' "$TEST_TMP/.gaia/state/design-record.yaml")"
  last_actor="$(yq '.audit[-1].actor' "$TEST_TMP/.gaia/state/design-record.yaml")"
  last_to="$(yq '.audit[-1].to' "$TEST_TMP/.gaia/state/design-record.yaml")"

  [ "$last_event" = "state-transition" ]
  [ "$last_actor" = "gaia-add-feature" ]
  [ "$last_to" = "stale" ]
}

@test "(AC1) stale-transition marker region precedes Step 8 in SKILL.md" {
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found at $SKILL_MD_AF"

  local marker_line step8_line
  marker_line="$(grep -nF '<!-- design-stale-transition begin -->' "$SKILL_MD_AF" | head -1 | cut -d: -f1)"
  [ -n "$marker_line" ] || fail "design-stale-transition begin marker missing from add-feature SKILL.md"

  step8_line="$(grep -n 'Step 8' "$SKILL_MD_AF" | head -1 | cut -d: -f1)"
  [ -n "$step8_line" ] || fail "Step 8 heading missing from add-feature SKILL.md"

  [ "$marker_line" -lt "$step8_line" ] || fail "design-stale-transition marker (line $marker_line) does not precede Step 8 (line $step8_line)"
}

@test "(AC1) SKILL.md design-stale-transition anchors present in add-feature" {
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found at $SKILL_MD_AF"

  grep -qF '<!-- design-stale-transition begin -->' "$SKILL_MD_AF" \
    || fail "begin marker missing from add-feature SKILL.md"
  grep -qF '<!-- design-stale-transition end -->' "$SKILL_MD_AF" \
    || fail "end marker missing from add-feature SKILL.md"
}

# ===========================================================================
# AC-EC1 — Ambiguous triage defaults to stale (structural anchor)
# ===========================================================================

@test "(AC-EC1) stale-transition region documents the ambiguity fail-safe" {
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found at $SKILL_MD_AF"

  # Extract the region between the two markers
  local region
  region="$(awk '/<!-- design-stale-transition begin -->/{p=1;next} /<!-- design-stale-transition end -->/{p=0} p' "$SKILL_MD_AF")"
  [ -n "$region" ] || fail "design-stale-transition region is empty or markers missing"

  # Must mention both ambiguity/uncertainty AND stale
  grep -qiE 'ambigu|uncertain' <<< "$region" \
    || fail "stale-transition region does not mention ambiguity or uncertainty"
  grep -qi 'stale' <<< "$region" \
    || fail "stale-transition region does not mention stale"
}

# ===========================================================================
# AC2 — Gate consequence (confirming, not new logic)
# ===========================================================================

@test "(AC2) stale record fails design_gate_check" {
  seed_config true
  seed_roster
  seed_probe_stub available
  _init_record

  # Transition to stale (any -> stale is legal)
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to stale --actor test

  local state
  state="$(yq '.design_state' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$state" = "stale" ]

  # Source design-gate and run the check
  local stderr_file="$TEST_TMP/gate-stderr.txt"
  local rc=0
  (
    export PROJECT_ROOT="$TEST_TMP"
    export PATH="$TEST_TMP/bin:$PATH"
    source "$GATE_SCRIPT"
    design_gate_check 2>"$stderr_file"
  ) || rc=$?

  [ "$rc" -ne 0 ] || fail "design_gate_check should fail on stale record but returned 0"
  grep -qi 'state:.*stale' "$stderr_file" || fail "gate stderr should contain the stale state diagnostic"
}

# This test is gated on the concurrent S8 branch merging. Until that branch
# lands, the eight SKILL.md files lack the design_approved declaration and
# this test correctly fails. Leave as-is.
@test "(AC2) all eight solutioning entry points declare design_approved predicate" {
  local -a sites=(
    gaia-adversarial
    gaia-create-arch
    gaia-create-epics
    gaia-edit-arch
    gaia-infra-design
    gaia-readiness-check
    gaia-review-api
    gaia-threat-model
  )
  local file_count=0
  local site skill_md
  for site in "${sites[@]}"; do
    skill_md="$PLUGIN_ROOT/skills/$site/SKILL.md"
    [ -f "$skill_md" ] || fail "SKILL.md not found for entry point $site at $skill_md"
    grep -qF 'design_approved' "$skill_md" \
      || fail "$site SKILL.md does not declare design_approved predicate"
    file_count=$((file_count + 1))
  done
  [ "$file_count" -eq 8 ] || fail "expected 8 entry points, found $file_count"
}

@test "(AC2) a stale record halts all eight solutioning entry points" {
  local visited=0
  local site
  for site in "${SITES[@]}"; do
    # Fresh temp dir per site so fixtures do not leak between iterations
    local site_tmp
    site_tmp="$(mktemp -d "$BATS_TEST_TMPDIR/stale-site-${site}-XXXXXX")"

    local old_tmp="$TEST_TMP"
    TEST_TMP="$site_tmp"
    seed_full_config true
    seed_roster
    seed_probe_stub available
    seed_site_prereqs "$site"

    # Build an approved record, then transition to stale
    _init_record
    env PROJECT_ROOT="$site_tmp" "$DREC_SCRIPT" transition --to review --actor ci
    env PROJECT_ROOT="$site_tmp" "$DREC_SCRIPT" add-review --verdict approved --reviewer stakeholder-A --actor ci
    env PROJECT_ROOT="$site_tmp" "$DREC_SCRIPT" approve --stakeholder stakeholder-A --recorded-by ci
    env PROJECT_ROOT="$site_tmp" "$DREC_SCRIPT" transition --to approved --actor ci
    env PROJECT_ROOT="$site_tmp" "$DREC_SCRIPT" transition --to stale --actor test

    TEST_TMP="$old_tmp"

    # Snapshot the artifact tree before
    local before_hash
    before_hash="$(_sha256_tree "$site_tmp/.gaia")"

    local setup_sh="$SKILLS_DIR/$site/scripts/setup.sh"
    [ -f "$setup_sh" ] || fail "setup.sh missing for $site at $setup_sh"

    local stderr_file="$site_tmp/stderr.txt"
    local rc=0
    env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH -u CLAUDE_PLUGIN_ROOT \
      PROJECT_ROOT="$site_tmp" PATH="$site_tmp/bin:$PATH" \
      bash "$setup_sh" >/dev/null 2>"$stderr_file" || rc=$?

    # Must halt (non-zero exit)
    [ "$rc" -ne 0 ] || fail "$site setup.sh exited 0 with stale record"

    # Halt must come from the design gate, not from resolve-config or
    # any other non-gate pre-flight failure
    local stripped
    stripped="$(sed "s|${site_tmp}||g" "$stderr_file")"
    if grep -qiE 'missing required field|^resolve-config:' <<< "$stripped"; then
      fail "$site failed in resolve-config, not at the design gate"
    fi
    grep -qi 'State:.*stale' <<< "$stripped" \
      || fail "$site halt stderr does not carry State: stale diagnostic"

    # Artifact tree must be unchanged
    local after_hash
    after_hash="$(_sha256_tree "$site_tmp/.gaia")"
    [ "$before_hash" = "$after_hash" ] \
      || fail "$site tree changed after stale halt"

    visited=$((visited + 1))
    rm -rf "$site_tmp"
  done

  [ "$visited" -eq 8 ] || fail "expected 8 sites visited, got $visited"
}

@test "(AC2) mutant: treating stale as approved lets all eight entry points proceed" {
  # In a copied plugin tree, make the gate treat stale like approved.
  # Then drive all eight sites with a stale record — all must exit 0.
  local plugin_copy="$TEST_TMP/mutant-plugin"
  cp -R "$PLUGIN_ROOT" "$plugin_copy"

  # Portable sed: write to .tmp then mv (never sed -i '')
  local gate_lib="$plugin_copy/scripts/lib/design-gate.sh"
  [ -f "$gate_lib" ] || fail "design-gate.sh not found in plugin copy"

  # Replace the stale branch: change 'return 1' after the stale-fail-branch
  # anchor to 'return 0', making the gate pass on stale.
  awk '
    /MUTANT-ANCHOR: stale-fail-branch/ { anchor=1 }
    anchor && /return 1/ { sub(/return 1/, "return 0"); anchor=0 }
    { print }
  ' "$gate_lib" > "$gate_lib.tmp" && mv "$gate_lib.tmp" "$gate_lib"

  local mutant_skills="$plugin_copy/skills"
  local mutant_scripts="$plugin_copy/scripts"
  local mutant_drec="$mutant_scripts/design-record.sh"

  local visited=0
  local site
  for site in "${SITES[@]}"; do
    local site_tmp
    site_tmp="$(mktemp -d "$BATS_TEST_TMPDIR/mutant-stale-${site}-XXXXXX")"

    local old_tmp="$TEST_TMP"
    TEST_TMP="$site_tmp"
    seed_full_config true
    seed_roster
    seed_probe_stub available
    seed_site_prereqs "$site"
    TEST_TMP="$old_tmp"

    # Build stale record using the mutant's design-record.sh
    env PROJECT_ROOT="$site_tmp" "$mutant_drec" init \
      --reference "test-ref" --discovered-via "created" --questionnaire-record "na" >/dev/null
    env PROJECT_ROOT="$site_tmp" "$mutant_drec" transition --to review --actor ci >/dev/null
    env PROJECT_ROOT="$site_tmp" "$mutant_drec" add-review --verdict approved --reviewer stakeholder-A --actor ci >/dev/null
    env PROJECT_ROOT="$site_tmp" "$mutant_drec" approve --stakeholder stakeholder-A --recorded-by ci >/dev/null
    env PROJECT_ROOT="$site_tmp" "$mutant_drec" transition --to approved --actor ci >/dev/null
    env PROJECT_ROOT="$site_tmp" "$mutant_drec" transition --to stale --actor test >/dev/null

    local setup_sh="$mutant_skills/$site/scripts/setup.sh"
    [ -f "$setup_sh" ] || fail "mutant setup.sh missing for $site"

    local rc=0
    env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH -u CLAUDE_PLUGIN_ROOT \
      PROJECT_ROOT="$site_tmp" PATH="$site_tmp/bin:$PATH" \
      bash "$setup_sh" >/dev/null 2>&1 || rc=$?

    [ "$rc" -eq 0 ] \
      || fail "$site mutant setup.sh exited $rc — stale-as-approved mutation did not let it through"

    visited=$((visited + 1))
    rm -rf "$site_tmp"
  done

  [ "$visited" -eq 8 ] || fail "expected 8 mutant sites visited, got $visited"
}

# ===========================================================================
# AC3 — edit-ux stale transition
# ===========================================================================

@test "(AC3) edit-ux records the same stale transition" {
  seed_config true
  seed_roster
  _build_approved_record

  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to stale --actor gaia-edit-ux

  local state_after
  state_after="$(yq '.design_state' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$state_after" = "stale" ]

  local last_actor
  last_actor="$(yq '.audit[-1].actor' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$last_actor" = "gaia-edit-ux" ]
}

@test "(AC3) SKILL.md design-stale-transition anchors present in edit-ux" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found at $SKILL_MD_UX"

  grep -qF '<!-- design-stale-transition begin -->' "$SKILL_MD_UX" \
    || fail "begin marker missing from edit-ux SKILL.md"
  grep -qF '<!-- design-stale-transition end -->' "$SKILL_MD_UX" \
    || fail "end marker missing from edit-ux SKILL.md"
}

# ===========================================================================
# AC-EC2 — Concurrent stale transitions serialize through the writer
# ===========================================================================

@test "(AC-EC2) concurrent stale transitions serialize through the writer" {
  seed_config true
  seed_roster
  _build_approved_record

  # Launch two transitions in parallel with different actors
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to stale --actor actor-one &
  local pid1=$!
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to stale --actor actor-two &
  local pid2=$!

  local rc1=0 rc2=0
  wait "$pid1" || rc1=$?
  wait "$pid2" || rc2=$?

  # Both must succeed — the second call sees stale->stale which is legal (*:stale)
  [ "$rc1" -eq 0 ] || fail "first concurrent transition failed with exit $rc1"
  [ "$rc2" -eq 0 ] || fail "second concurrent transition failed with exit $rc2"

  # Final state is stale
  local state
  state="$(yq '.design_state' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$state" = "stale" ]

  # Both actors must appear in the audit trail
  local audit_actors
  audit_actors="$(yq '[.audit[].actor] | join(",")' "$TEST_TMP/.gaia/state/design-record.yaml")"
  grep -q 'actor-one' <<< "$audit_actors" \
    || fail "actor-one missing from audit trail"
  grep -q 'actor-two' <<< "$audit_actors" \
    || fail "actor-two missing from audit trail"
}

# ===========================================================================
# AC-EC3 — In-flight stories surface staleness
# ===========================================================================

@test "(AC-EC3) mid-development staleness surfaced by gate" {
  seed_config true
  seed_roster
  seed_probe_stub available
  _build_approved_record

  # Record was approved; now transition to stale (as if a new feature arrived)
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to stale --actor mid-sprint-change

  # The gate must fail on the newly-stale record
  local stderr_file="$TEST_TMP/ec3-gate-stderr.txt"
  local rc=0
  (
    export PROJECT_ROOT="$TEST_TMP"
    export PATH="$TEST_TMP/bin:$PATH"
    source "$GATE_SCRIPT"
    design_gate_check 2>"$stderr_file"
  ) || rc=$?

  [ "$rc" -ne 0 ] || fail "gate should fail after approved record transitions to stale"
}

# ===========================================================================
# AC4 — dev-story gate (setup.sh + quality_gates.pre_start)
# ===========================================================================

@test "(AC4) dev-story setup.sh sources gate-predicates and runs pre_start gate on stale" {
  [ -f "$SETUP_SH_DS" ] || fail "dev-story setup.sh not found at $SETUP_SH_DS"
  [ -f "$PREDICATES_SCRIPT" ] || fail "gate-predicates.sh not found at $PREDICATES_SCRIPT"

  seed_full_config true
  seed_roster
  seed_probe_stub available
  _init_record
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to stale --actor test

  # Seed traceability to pass the existing traceability gate
  printf '# Traceability Matrix\n| Req | Test |\n' > "$TEST_TMP/.gaia/artifacts/planning-artifacts/traceability-matrix.md"
  seed_sprint_status sprint-99
  seed_lifecycle_overrides

  local stderr_file="$TEST_TMP/ac4-setup-stderr.txt"
  local rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    PROJECT_PATH="$TEST_TMP" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    PATH="$TEST_TMP/bin:$PATH" \
    bash "$SETUP_SH_DS" 2>"$stderr_file" || rc=$?

  [ "$rc" -ne 0 ] || fail "dev-story setup.sh should exit non-zero on stale record but exited 0"

  # Verify resolve-config did NOT fail — the halt must come from the design gate
  local stripped_stderr
  stripped_stderr="$(sed "s|${TEST_TMP}|TMPDIR|g" "$stderr_file")"
  if grep -qE 'missing required field|^resolve-config:' <<< "$stripped_stderr"; then
    fail "setup.sh failed in resolve-config, not at the design gate: $(head -3 "$stderr_file")"
  fi

  # Verify the gate's structured diagnostic fields appear
  grep -q 'Record:' "$stderr_file" || fail "gate stderr should contain 'Record:' diagnostic"
  grep -qi 'state:.*stale' "$stderr_file" || fail "gate stderr should contain 'State:.*stale'"
}

@test "(AC4) dev-story setup.sh fails closed when gate-predicates.sh is absent" {
  [ -f "$SETUP_SH_DS" ] || fail "dev-story setup.sh not found at $SETUP_SH_DS"

  seed_full_config true
  seed_roster
  _init_record

  seed_sprint_status sprint-99
  seed_lifecycle_overrides
  printf '# Traceability Matrix\n| Req | Test |\n' > "$TEST_TMP/.gaia/artifacts/planning-artifacts/traceability-matrix.md"

  # Point PLUGIN_SCRIPTS_DIR to a dir without gate-predicates.sh
  local fake_plugin_root="$TEST_TMP/fake-plugin"
  mkdir -p "$fake_plugin_root/scripts/lib"
  # Copy everything from real scripts/ EXCEPT gate-predicates.sh
  cp -R "$SCRIPTS_DIR"/* "$fake_plugin_root/scripts/" 2>/dev/null || true
  rm -f "$fake_plugin_root/scripts/lib/gate-predicates.sh"

  # Copy the skill tree so setup.sh can find its SKILL.md
  mkdir -p "$fake_plugin_root/skills/gaia-dev-story/scripts"
  cp "$SETUP_SH_DS" "$fake_plugin_root/skills/gaia-dev-story/scripts/setup.sh"
  [ -f "$SKILL_MD_DS" ] && cp "$SKILL_MD_DS" "$fake_plugin_root/skills/gaia-dev-story/SKILL.md"

  local stderr_file="$TEST_TMP/ac4-absent-stderr.txt"
  local rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    PROJECT_PATH="$TEST_TMP" \
    CLAUDE_PLUGIN_ROOT="$fake_plugin_root" \
    bash "$fake_plugin_root/skills/gaia-dev-story/scripts/setup.sh" 2>"$stderr_file" || rc=$?

  [ "$rc" -ne 0 ] || fail "setup.sh should exit non-zero when gate-predicates.sh is absent but exited 0"

  # Verify resolve-config did NOT fail
  if grep -qE 'missing required field|^resolve-config:' "$stderr_file"; then
    fail "setup.sh failed in resolve-config, not at the gate-predicates check: $(head -3 "$stderr_file")"
  fi

  grep -q 'gate-predicates.sh not found' "$stderr_file" \
    || fail "stderr should contain 'gate-predicates.sh not found'"
  grep -q 'cannot evaluate required quality gates' "$stderr_file" \
    || fail "stderr should contain 'cannot evaluate required quality gates'"
}

# Positive control: once gate wiring is added, this test PASSES in Red (the
# gate sees an approved record and proceeds). The other AC4 tests carry the
# failing-Red load; this one confirms the happy path does not regress.
@test "(AC4) dev-story setup.sh passes on approved design (positive control)" {
  [ -f "$SETUP_SH_DS" ] || fail "dev-story setup.sh not found at $SETUP_SH_DS"
  [ -f "$PREDICATES_SCRIPT" ] || fail "gate-predicates.sh not found at $PREDICATES_SCRIPT"

  seed_full_config true
  seed_roster
  seed_probe_stub available
  _build_approved_record

  seed_sprint_status sprint-99
  seed_lifecycle_overrides
  printf '# Traceability Matrix\n| Req | Test |\n' > "$TEST_TMP/.gaia/artifacts/planning-artifacts/traceability-matrix.md"

  local stderr_file="$TEST_TMP/ac4-approved-stderr.txt"
  local rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    PROJECT_PATH="$TEST_TMP" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    PATH="$TEST_TMP/bin:$PATH" \
    bash "$SETUP_SH_DS" 2>"$stderr_file" || rc=$?

  # Verify resolve-config did NOT fail
  if grep -qE 'missing required field|^resolve-config:' "$stderr_file"; then
    fail "setup.sh failed in resolve-config, not at the gate: $(head -3 "$stderr_file")"
  fi

  [ "$rc" -eq 0 ] || fail "dev-story setup.sh should pass on approved record but exited $rc"
}

@test "(AC4) dev-story override proceeds with two audit writes" {
  [ -f "$SETUP_SH_DS" ] || fail "dev-story setup.sh not found at $SETUP_SH_DS"
  [ -f "$PREDICATES_SCRIPT" ] || fail "gate-predicates.sh not found at $PREDICATES_SCRIPT"

  seed_full_config true
  seed_roster
  seed_probe_stub available
  _init_record
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to stale --actor test

  seed_sprint_status sprint-99
  seed_lifecycle_overrides
  printf '# Traceability Matrix\n| Req | Test |\n' > "$TEST_TMP/.gaia/artifacts/planning-artifacts/traceability-matrix.md"

  local stderr_file="$TEST_TMP/ac4-override-stderr.txt"
  local rc=0
  env PROJECT_ROOT="$TEST_TMP" \
    PROJECT_PATH="$TEST_TMP" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    PATH="$TEST_TMP/bin:$PATH" \
    bash "$SETUP_SH_DS" \
      --force-design \
      --reason "testing override for dev-story" \
      --entry-point gaia-dev-story \
      --sprint-id sprint-99 \
    2>"$stderr_file" || rc=$?

  # Verify resolve-config did NOT fail
  if grep -qE 'missing required field|^resolve-config:' "$stderr_file"; then
    fail "setup.sh failed in resolve-config, not at the gate: $(head -3 "$stderr_file")"
  fi

  [ "$rc" -eq 0 ] || fail "dev-story setup.sh with --force-design should succeed but exited $rc"

  # Verify the design record has an overrides[] entry
  local override_count
  override_count="$(yq '.overrides | length' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$override_count" -ge 1 ] || fail "expected at least 1 override entry, got $override_count"

  # Verify lifecycle-overrides has a bypass entry
  local bypass_count
  bypass_count="$(yq '.bypasses | length' "$TEST_TMP/.gaia/state/lifecycle-overrides.yaml")"
  [ "$bypass_count" -ge 1 ] || fail "expected at least 1 lifecycle bypass entry, got $bypass_count"
}

@test "(AC4) dev-story SKILL.md declares quality_gates.pre_start: design_approved" {
  [ -f "$SKILL_MD_DS" ] || fail "dev-story SKILL.md not found at $SKILL_MD_DS"

  grep -qF 'design_approved' "$SKILL_MD_DS" \
    || fail "dev-story SKILL.md does not declare design_approved predicate"
}

@test "(AC4) dev-story SKILL.md has design-gate anchor markers" {
  [ -f "$SKILL_MD_DS" ] || fail "dev-story SKILL.md not found at $SKILL_MD_DS"

  grep -qF '<!-- design-gate begin -->' "$SKILL_MD_DS" \
    || fail "design-gate begin marker missing from dev-story SKILL.md"
  grep -qF '<!-- design-gate end -->' "$SKILL_MD_DS" \
    || fail "design-gate end marker missing from dev-story SKILL.md"
}

@test "(AC4) dev-story SKILL.md contains the override re-invocation block" {
  [ -f "$SKILL_MD_DS" ] || fail "dev-story SKILL.md not found at $SKILL_MD_DS"

  # Strip HTML comments so we match the content, not just markers.
  # Write to a temp file to avoid SIGPIPE (141) when grep -q closes the pipe
  # early under set -o pipefail.
  local clean_file="$TEST_TMP/skill-md-clean.txt"
  sed 's/<!--.*-->//g' "$SKILL_MD_DS" > "$clean_file"

  grep -qE 'FORCE_DESIGN|--force-design' "$clean_file" \
    || fail "dev-story SKILL.md missing FORCE_DESIGN or --force-design reference in override block"
  grep -qF 'gaia-dev-story' "$clean_file" \
    || fail "dev-story SKILL.md override block missing gaia-dev-story entry-point value"
}

@test "(AC4) gate stderr surfaces the state string for stale" {
  seed_config true
  seed_roster
  seed_probe_stub available
  _init_record
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to stale --actor test

  local stderr_file="$TEST_TMP/ac4-state-stderr.txt"
  local rc=0
  (
    export PROJECT_ROOT="$TEST_TMP"
    export PATH="$TEST_TMP/bin:$PATH"
    source "$GATE_SCRIPT"
    design_gate_check 2>"$stderr_file"
  ) || rc=$?

  [ "$rc" -ne 0 ] || fail "gate should fail on stale"
  grep -q 'Record:' "$stderr_file" || fail "stderr should contain 'Record:' field"
  grep -qi 'state:.*stale' "$stderr_file" || fail "stderr should contain state: stale"
}

# ===========================================================================
# AC-EC5 — Override audit survives later approval
# ===========================================================================

@test "(AC-EC5) override entry persists after design returns to approved" {
  seed_config true
  seed_roster
  _build_approved_record

  # Go stale
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to stale --actor test

  # Add an override
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" add-override \
    --actor test-dev --reason "testing override persistence" --entry-point test

  local override_ds
  override_ds="$(yq '.overrides[-1].design_state_at_override' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$override_ds" = "stale" ]

  # Now re-approve: stale -> review -> approve -> approved
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor test
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" add-review --verdict approved --reviewer stakeholder-A --actor ci
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" approve --stakeholder stakeholder-A --recorded-by ci
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to approved --actor ci

  # The override entry must still be present with design_state_at_override: stale
  local final_override_ds
  final_override_ds="$(yq '.overrides[-1].design_state_at_override' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$final_override_ds" = "stale" ] || fail "override entry should persist with stale state but got: $final_override_ds"

  local override_count
  override_count="$(yq '.overrides | length' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$override_count" -ge 1 ] || fail "expected at least 1 override entry after re-approval, got $override_count"
}

# ===========================================================================
# AC-EC6 — Illegal stale-to-approved refused
# ===========================================================================

@test "(AC-EC6) stale-to-approved without review round is refused" {
  seed_config true
  seed_roster
  _init_record
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to stale --actor test

  local hash_before
  hash_before="$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")"

  local rc=0
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to approved --actor test 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "stale->approved should be refused but exited 0"

  # Record must be byte-identical (no I/O occurred)
  local hash_after
  hash_after="$(_sha256_file "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$hash_before" = "$hash_after" ] || fail "record was modified despite refused transition"
}

# ===========================================================================
# AC5 — Removal sweep (retired provider)
# ===========================================================================

@test "(AC5) zero retired-provider consumption paths in dev-story chain" {
  [ -f "$SKILL_MD_DS" ] || fail "dev-story SKILL.md not found at $SKILL_MD_DS"

  local _provider
  _provider="$(printf '%s%s' 'fig' 'ma')"

  # Sweep SKILL.md for retired provider metadata/cache/token/spec terms
  local hits=0 term
  for term in "${_provider}_mcp" "${_provider}_cache" "${_provider}:" "mcp__claude_ai_$(printf '%s' "$_provider" | sed 's/.*/\u&/')"; do
    if grep -qiF "$term" "$SKILL_MD_DS"; then
      hits=$((hits + 1))
    fi
  done

  # Also sweep all scripts under the dev-story skill
  local script_dir="$SKILL_DIR_DS/scripts"
  if [ -d "$script_dir" ]; then
    local f
    for f in "$script_dir"/*.sh; do
      [ -f "$f" ] || continue
      for term in "${_provider}" "${_provider}_mcp" "${_provider}_cache"; do
        if grep -qiF "$term" "$f"; then
          hits=$((hits + 1))
        fi
      done
    done
  fi

  [ "$hits" -eq 0 ] || fail "found $hits retired-provider references in dev-story chain"
}

@test "(AC5) graceful-degrade HTML markers are absent from dev-story SKILL.md" {
  [ -f "$SKILL_MD_DS" ] || fail "dev-story SKILL.md not found at $SKILL_MD_DS"

  local _provider
  _provider="$(printf '%s%s' 'fig' 'ma')"

  if grep -qF "<!-- ${_provider} graceful-degrade begin -->" "$SKILL_MD_DS"; then
    fail "graceful-degrade begin marker should be absent but was found"
  fi
  if grep -qF "<!-- ${_provider} graceful-degrade end -->" "$SKILL_MD_DS"; then
    fail "graceful-degrade end marker should be absent but was found"
  fi
}

@test "(AC5) no path in this story sets approved" {
  # Sweep the three SKILL.md files for write patterns that set approved,
  # excluding comments and test assertion contexts. Also assert that the
  # stale-transition regions exist in add-feature and edit-ux, so this test
  # does not pass vacuously when regions are absent.

  local -a targets=(
    "$SKILL_MD_AF"
    "$SKILL_MD_UX"
    "$SKILL_MD_DS"
  )

  # Precondition: the stale-transition regions must be present so we sweep
  # real content, not absent markers. This makes the test fail in Red for
  # the right reason (regions missing) rather than pass vacuously.
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found at $SKILL_MD_AF"
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found at $SKILL_MD_UX"
  [ -f "$SKILL_MD_DS" ] || fail "dev-story SKILL.md not found at $SKILL_MD_DS"
  grep -qF '<!-- design-stale-transition begin -->' "$SKILL_MD_AF" \
    || fail "add-feature SKILL.md missing stale-transition region — cannot sweep absent content"
  grep -qF '<!-- design-stale-transition begin -->' "$SKILL_MD_UX" \
    || fail "edit-ux SKILL.md missing stale-transition region — cannot sweep absent content"

  local file hits=0
  for file in "${targets[@]}"; do
    [ -f "$file" ] || continue
    # Look for transition --to approved as a write instruction (not assertion)
    if grep -v '^[[:space:]]*#' "$file" \
       | grep -v 'fail\|assert\|\[ ' \
       | grep -qi 'transition.*--to.*approved'; then
      hits=$((hits + 1))
    fi
  done

  [ "$hits" -eq 0 ] || fail "found $hits SKILL.md files containing a transition-to-approved write path"
}

# =========================================================================
# Shared attestation block identity (AC5)
# =========================================================================

@test "(AC5) shared attestation block present and byte-identical at both skill sites" {
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found at $SKILL_MD_AF"
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found at $SKILL_MD_UX"

  # Extract attestation block from add-feature
  local block_af
  block_af="$(awk '/<!-- design-attestation begin -->/{p=1;next} /<!-- design-attestation end -->/{p=0} p' "$SKILL_MD_AF")"
  [ -n "$block_af" ] || fail "attestation block missing from add-feature SKILL.md"

  # Extract attestation block from edit-ux
  local block_ux
  block_ux="$(awk '/<!-- design-attestation begin -->/{p=1;next} /<!-- design-attestation end -->/{p=0} p' "$SKILL_MD_UX")"
  [ -n "$block_ux" ] || fail "attestation block missing from edit-ux SKILL.md"

  # Byte-identical
  if ! diff <(printf '%s' "$block_af") <(printf '%s' "$block_ux") >/dev/null 2>&1; then
    fail "attestation blocks differ between add-feature and edit-ux"
  fi

  # Block mentions --integration and all three values
  echo "$block_af" | grep -q '\-\-integration' \
    || fail "attestation block should mention --integration"
  echo "$block_af" | grep -q 'available' \
    || fail "attestation block should mention 'available'"
  echo "$block_af" | grep -q 'missing' \
    || fail "attestation block should mention 'missing'"
  echo "$block_af" | grep -q 'unauthorized' \
    || fail "attestation block should mention 'unauthorized'"

  # Absent from all nine gate sites
  local gate_sites=(
    gaia-create-arch gaia-create-epics gaia-create-prd
    gaia-create-story gaia-create-ux gaia-nfr
    gaia-readiness-check gaia-test-strategy gaia-dev-story
  )
  local site checked=0
  for site in "${gate_sites[@]}"; do
    local skill_md="$SKILLS_DIR/$site/SKILL.md"
    [ -f "$skill_md" ] || continue
    checked=$((checked + 1))
    if grep -q '<!-- design-attestation begin -->' "$skill_md"; then
      fail "attestation block marker found in gate site $site"
    fi
  done
  [ "$checked" -gt 0 ] || fail "no gate-site SKILL.md files found — scan is vacuous"
}

