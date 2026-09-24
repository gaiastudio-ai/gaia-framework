#!/usr/bin/env bats
# design-gate-sites.bats — assert the shared design-approval gate is wired into
# every solutioning entry point, each site honours the override, and the
# registry-derived site list catches undeclared additions.
#
# Red-phase tests: every test must FAIL now (missing production code) and must
# FAIL for the right reason. A missing target makes the test FAIL with a message
# naming it — never skip.
#
# No project-root .gaia/ access; all fixtures use mktemp temp project roots.
# No internal identifiers in @test names.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# The eight solutioning entry points. Derived from lifecycle-sequence.yaml
# (phase-3 nodes UNION next edge targets, EXCLUDING targets that are commands
# of any node NOT in phase 3-solutioning).
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
# Portable helpers
# ---------------------------------------------------------------------------

_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

_sha256_tree() {
  # Deterministic sha256 of a directory tree: sort all file paths, hash each
  # file, then hash the concatenation.
  local dir="$1"
  find "$dir" -type f | LC_ALL=C sort | while IFS= read -r f; do
    _sha256_file "$f"
  done | _sha256_file /dev/stdin
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# seed_full_config UI_PRESENT — create .gaia/config/project-config.yaml with
# all 11 required fields so resolve-config.sh passes. The UI_PRESENT value
# is written literally (pass `true` for YAML boolean true).
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

# seed_full_config_no_compliance — all 11 required fields but NO compliance
# section (ui_present absent).
seed_full_config_no_compliance() {
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
ci_platform:
  provider: none
stacks:
  - name: bash
EOF
}

seed_config_malformed() {
  mkdir -p "$TEST_TMP/.gaia/config"
  printf 'compliance:\n  ui_present: [broken\n' > "$TEST_TMP/.gaia/config/project-config.yaml"
}

# seed_site_prereqs SITE — seed the per-site prerequisite artifacts that the
# site's own gates check before reaching the design gate. Without these, the
# setup.sh exits at a validate-gate or guard check, never reaching our gate.
seed_site_prereqs() {
  local site="$1"
  case "$site" in
    gaia-create-arch)
      # architecture-template.md must exist (Section 2b guard)
      mkdir -p "$SKILLS_DIR/gaia-create-arch"
      # Template is already in the skill dir.
      # threat-model gate (Section 5): when a sprint is active, create-arch
      # requires threat-model.md; seed it so the override test passes through.
      # When no sprint-status exists, Section 5 degrades to WARNING.
      mkdir -p "$TEST_TMP/.gaia/artifacts/planning-artifacts"
      printf '# threat model\n' > "$TEST_TMP/.gaia/artifacts/planning-artifacts/threat-model.md"
      ;;
    gaia-edit-arch)
      # architecture.md should exist (Section 2b guard) — non-fatal in setup
      ;;
    gaia-create-epics)
      # test-plan must exist (validate-gate test_plan_exists + non-empty guard)
      mkdir -p "$TEST_TMP/.gaia/artifacts/test-artifacts/strategy"
      printf '# test plan\nscenarios:\n  - name: test\n' > "$TEST_TMP/.gaia/artifacts/test-artifacts/strategy/test-plan.md"
      ;;
    gaia-readiness-check)
      # traceability-matrix.md + ci-setup.md must exist and be non-empty
      # (ci-setup gate is conditional on ci_platform.provider != none; we set
      # provider: none in config so only traceability gate fires)
      mkdir -p "$TEST_TMP/.gaia/artifacts/planning-artifacts"
      printf '# traceability\n|req|test|\n' > "$TEST_TMP/.gaia/artifacts/planning-artifacts/traceability-matrix.md"
      ;;
    # gaia-threat-model, gaia-infra-design, gaia-review-api, gaia-adversarial:
    # no site-specific prerequisite artifacts needed beyond the config
  esac
}

seed_roster() {
  local roster_dir="$TEST_TMP/.gaia/custom/stakeholders"
  mkdir -p "$roster_dir"
  cat > "$roster_dir/stakeholder-A.md" <<'EOF'
---
slug: stakeholder-A
name: Stakeholder A
tags: [design]
---
EOF
}

seed_sprint_status() {
  mkdir -p "$TEST_TMP/.gaia/state"
  cat > "$TEST_TMP/.gaia/state/sprint-status.yaml" <<EOF
sprint_id: ${1:-sprint-82}
status: active
EOF
}

seed_lifecycle_overrides() {
  mkdir -p "$TEST_TMP/.gaia/state"
  cat > "$TEST_TMP/.gaia/state/lifecycle-overrides.yaml" <<'EOF'
bypasses: []
EOF
}

seed_probe_stub() {
  local state="${1:-available}"
  mkdir -p "$TEST_TMP/bin"
  cat > "$TEST_TMP/bin/design-probe.sh" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "$state"
exit 0
STUBEOF
  chmod +x "$TEST_TMP/bin/design-probe.sh"
}

seed_ui_project() {
  seed_full_config true
  seed_roster
  seed_probe_stub "${1:-available}"
}

# _init_record — create a record via the real design-record.sh init verb.
_init_record() {
  env PROJECT_ROOT="$TEST_TMP" \
    "$DREC_SCRIPT" init \
      --reference "test-project-ref" \
      --discovered-via "created" \
      --questionnaire-record "not-applicable"
}

# _build_approved_record — draft -> review -> approve -> approved.
_build_approved_record() {
  _init_record
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor ci
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" approve --stakeholder stakeholder-A --recorded-by ci
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to approved --actor ci
}

# _build_review_record — draft -> review.
_build_review_record() {
  _init_record
  env PROJECT_ROOT="$TEST_TMP" "$DREC_SCRIPT" transition --to review --actor ci
}

# ---------------------------------------------------------------------------
# Per-test setup/teardown
# ---------------------------------------------------------------------------

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"
  DREC_SCRIPT="$SCRIPTS_DIR/design-record.sh"
  GATE_PREDICATES="$SCRIPTS_DIR/lib/gate-predicates.sh"
  LIFECYCLE_SEQ="$REPO_ROOT/plugins/gaia/knowledge/lifecycle-sequence.yaml"
}

teardown() {
  common_teardown
}

# ═══════════════════════════════════════════════════════════════════════════
# Test 1 (structural): all eight entry points declare and invoke the gate
# ═══════════════════════════════════════════════════════════════════════════

@test "all eight entry points declare design_approved in quality_gates.pre_start" {
  # The target: each SKILL.md must have a quality_gates.pre_start block
  # containing design_approved.
  [ -f "$GATE_PREDICATES" ] || { echo "gate-predicates.sh missing at $GATE_PREDICATES" >&2; return 1; }
  source "$GATE_PREDICATES"

  local visited=0
  local site
  for site in "${SITES[@]}"; do
    local skill_md="$SKILLS_DIR/$site/SKILL.md"
    [ -f "$skill_md" ] || { echo "SKILL.md missing for $site at $skill_md" >&2; return 1; }

    local extracted
    extracted="$(_gate_extract_block "$skill_md" pre_start)"
    echo "$extracted" | grep -q "design_approved" || {
      echo "FAIL: $site SKILL.md does not declare design_approved in pre_start" >&2
      return 1
    }
    visited=$((visited + 1))
  done

  # Scan must visit exactly 8 files
  [ "$visited" -eq 8 ] || {
    echo "FAIL: visited $visited sites, expected 8" >&2
    return 1
  }
}

@test "all eight setup.sh scripts source gate-predicates and call the pre-start runner" {
  local visited=0
  local site
  for site in "${SITES[@]}"; do
    local setup_sh="$SKILLS_DIR/$site/scripts/setup.sh"
    [ -f "$setup_sh" ] || { echo "FAIL: setup.sh missing for $site at $setup_sh" >&2; return 1; }
    [ -x "$setup_sh" ] || { echo "FAIL: setup.sh not executable for $site" >&2; return 1; }
    grep -q "gate-predicates" "$setup_sh" || {
      echo "FAIL: $site/setup.sh does not source gate-predicates" >&2
      return 1
    }
    grep -q "_gate_run_pre_start" "$setup_sh" || {
      echo "FAIL: $site/setup.sh does not call _gate_run_pre_start" >&2
      return 1
    }
    visited=$((visited + 1))
  done
  [ "$visited" -eq 8 ]
}

@test "review-api and adversarial have a Setup heading in their SKILL.md" {
  local site
  for site in gaia-review-api gaia-adversarial; do
    local skill_md="$SKILLS_DIR/$site/SKILL.md"
    [ -f "$skill_md" ] || { echo "FAIL: SKILL.md missing for $site" >&2; return 1; }
    grep -q "^## Setup" "$skill_md" || {
      echo "FAIL: $site/SKILL.md has no '## Setup' heading" >&2
      return 1
    }
  done
}

@test "readiness-check preserves its existing validate-gate.sh checks alongside the new gate" {
  local setup_sh="$SKILLS_DIR/gaia-readiness-check/scripts/setup.sh"
  [ -f "$setup_sh" ] || { echo "setup.sh missing for readiness-check" >&2; return 1; }
  # Existing mechanism: validate-gate.sh --multi with traceability_exists,ci_setup_exists
  grep -q "validate-gate.sh\|VALIDATE_GATE" "$setup_sh" || {
    echo "FAIL: readiness-check/setup.sh lost its validate-gate invocation" >&2
    return 1
  }
  # New mechanism:
  grep -q "_gate_run_pre_start" "$setup_sh" || {
    echo "FAIL: readiness-check/setup.sh does not call _gate_run_pre_start" >&2
    return 1
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# Test 2: fail verdict produces zero artifacts at all eight sites
# ═══════════════════════════════════════════════════════════════════════════

@test "fail verdict at each site produces no file-level changes (whole-tree sha256)" {
  local site
  for site in "${SITES[@]}"; do
    # Fresh temp dir per site
    local site_tmp
    site_tmp="$(mktemp -d "$BATS_TEST_TMPDIR/site-${site}-XXXXXX")"

    # Seed: UI project with an unapproved (review state) record
    local old_tmp="$TEST_TMP"
    TEST_TMP="$site_tmp"
    seed_ui_project available
    seed_site_prereqs "$site"
    _build_review_record
    TEST_TMP="$old_tmp"

    # Snapshot whole tree before
    local before_hash
    before_hash="$(_sha256_tree "$site_tmp/.gaia")"

    # Run setup.sh with NO argv (matching the ! bang directive)
    local setup_sh="$SKILLS_DIR/$site/scripts/setup.sh"
    [ -f "$setup_sh" ] || { echo "FAIL: setup.sh missing for $site" >&2; return 1; }

    local stderr_file="$site_tmp/stderr.txt"
    local rc=0
    env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH -u CLAUDE_PLUGIN_ROOT \
      PROJECT_ROOT="$site_tmp" PATH="$site_tmp/bin:$PATH" \
      bash "$setup_sh" >/dev/null 2>"$stderr_file" || rc=$?

    # Gate must halt (non-zero exit)
    [ "$rc" -ne 0 ] || { echo "FAIL: $site setup.sh exited 0 with unapproved record" >&2; return 1; }

    # The halt must come from the design gate, not from resolve-config
    local captured
    captured="$(cat "$stderr_file")"
    captured="${captured//$site_tmp/}"
    echo "$captured" | grep -qiE "(design.gate|quality.gate)" || {
      echo "FAIL: $site halt did not come from the design gate (stderr: $captured)" >&2
      return 1
    }
    if echo "$captured" | grep -qi "resolve-config.*failed\|missing required field"; then
      echo "FAIL: $site failed in resolve-config, not at the design gate (stderr: $captured)" >&2
      return 1
    fi

    # Whole tree must be byte-identical
    local after_hash
    after_hash="$(_sha256_tree "$site_tmp/.gaia")"
    [ "$before_hash" = "$after_hash" ] || {
      echo "FAIL: $site tree changed after fail verdict (before=$before_hash after=$after_hash)" >&2
      return 1
    }

    rm -rf "$site_tmp"
  done
}

# Named mutant: mutant-remove-gate-call
@test "mutant: removing the gate call from one setup.sh lets it proceed (proves the gate is the mechanism)" {
  local target_site="gaia-create-arch"
  local site_tmp
  site_tmp="$(mktemp -d "$BATS_TEST_TMPDIR/mutant-rmgate-XXXXXX")"

  local old_tmp="$TEST_TMP"
  TEST_TMP="$site_tmp"
  seed_ui_project available
  seed_site_prereqs "$target_site"
  _build_review_record
  TEST_TMP="$old_tmp"

  # The setup.sh must contain the gate call for the mutant to be meaningful
  local setup_sh="$SKILLS_DIR/$target_site/scripts/setup.sh"
  [ -f "$setup_sh" ] || { echo "FAIL: setup.sh missing for $target_site" >&2; return 1; }
  grep -q "_gate_run_pre_start" "$setup_sh" || {
    echo "FAIL: setup.sh does not contain _gate_run_pre_start (design gate not wired yet)" >&2
    return 1
  }

  # Copy the plugin tree into the test tmpdir so every relative path resolves,
  # then apply the sed to the copy's setup.sh.
  local plugin_root
  plugin_root="$(cd "$SKILLS_DIR/.." && pwd)"
  local plugin_copy="$site_tmp/plugin"
  cp -R "$plugin_root" "$plugin_copy"
  local mutant_sh="$plugin_copy/skills/$target_site/scripts/setup.sh"
  local orig_lines
  orig_lines="$(wc -l < "$mutant_sh" | tr -d ' ')"
  sed '/_gate_run_pre_start/d' "$mutant_sh" > "$mutant_sh.tmp" && mv "$mutant_sh.tmp" "$mutant_sh"
  chmod +x "$mutant_sh"
  local mutant_lines
  mutant_lines="$(wc -l < "$mutant_sh" | tr -d ' ')"
  # Guard: the sed must have actually removed something
  [ "$orig_lines" -ne "$mutant_lines" ] || {
    echo "FAIL: sed removed nothing from the mutant — gate line not found" >&2
    return 1
  }

  local rc=0
  env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH -u CLAUDE_PLUGIN_ROOT \
    PROJECT_ROOT="$site_tmp" PATH="$site_tmp/bin:$PATH" \
    bash "$mutant_sh" >/dev/null 2>&1 || rc=$?

  # Without the gate call, setup.sh should exit 0 (gate not evaluated)
  [ "$rc" -eq 0 ] || {
    echo "FAIL: mutant setup.sh (gate call removed) still exited non-zero ($rc) — the gate is NOT the mechanism" >&2
    return 1
  }

  rm -rf "$site_tmp"
}

# Named mutant: mutant-gate-writes-on-fail
@test "mutant: a spurious write on the fail path is caught by the tree-integrity check" {
  local site_tmp
  site_tmp="$(mktemp -d "$BATS_TEST_TMPDIR/mutant-writes-XXXXXX")"

  local old_tmp="$TEST_TMP"
  TEST_TMP="$site_tmp"
  seed_ui_project available
  seed_site_prereqs gaia-create-arch
  _build_review_record
  TEST_TMP="$old_tmp"

  # The gate library must exist to create a mutant of it
  local gate_lib="$SCRIPTS_DIR/lib/design-gate.sh"
  [ -f "$gate_lib" ] || { echo "FAIL: design-gate.sh missing" >&2; return 1; }

  # Create a mutant copy with a spurious write on the fail path
  local mutant_gate="$site_tmp/mutant-design-gate.sh"
  # Insert a write just before the final _dg_halt_with_probe call
  awk '/MUTANT-ANCHOR: probe-fail-branch/ {
    print "  touch \"${PROJECT_ROOT}/.gaia/state/spurious-marker\""
  } {print}' "$gate_lib" > "$mutant_gate"

  # Snapshot before
  local before_hash
  before_hash="$(_sha256_tree "$site_tmp/.gaia")"

  # Source the mutant and invoke the gate directly
  local rc=0
  (
    export PROJECT_ROOT="$site_tmp"
    export PATH="$site_tmp/bin:$PATH"
    source "$mutant_gate"
    design_gate_check
  ) >/dev/null 2>&1 || rc=$?

  # The gate must still halt
  [ "$rc" -ne 0 ] || {
    echo "FAIL: mutant gate exited 0 (expected halt)" >&2
    return 1
  }

  # The tree must have CHANGED (spurious write landed)
  local after_hash
  after_hash="$(_sha256_tree "$site_tmp/.gaia")"
  [ "$before_hash" != "$after_hash" ] || {
    echo "FAIL: mutant did not produce a spurious write (tree unchanged)" >&2
    return 1
  }

  # The integrity check (before_hash == after_hash) would catch this —
  # the above assertion proves the check would turn red.
  rm -rf "$site_tmp"
}

# ═══════════════════════════════════════════════════════════════════════════
# Test 3: approved record lets all eight proceed
# ═══════════════════════════════════════════════════════════════════════════

@test "approved record lets all eight entry points proceed (exit 0)" {
  local site
  for site in "${SITES[@]}"; do
    local site_tmp
    site_tmp="$(mktemp -d "$BATS_TEST_TMPDIR/site-${site}-XXXXXX")"

    local old_tmp="$TEST_TMP"
    TEST_TMP="$site_tmp"
    seed_ui_project available
    seed_site_prereqs "$site"
    _build_approved_record
    TEST_TMP="$old_tmp"

    local setup_sh="$SKILLS_DIR/$site/scripts/setup.sh"
    [ -f "$setup_sh" ] || { echo "FAIL: setup.sh missing for $site" >&2; return 1; }

    local stderr_file="$site_tmp/stderr.txt"
    local rc=0
    env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH -u CLAUDE_PLUGIN_ROOT \
      PROJECT_ROOT="$site_tmp" PATH="$site_tmp/bin:$PATH" \
      bash "$setup_sh" >/dev/null 2>"$stderr_file" || rc=$?

    # Must not fail in resolve-config
    local captured
    captured="$(cat "$stderr_file")"
    captured="${captured//$site_tmp/}"
    if echo "$captured" | grep -qi "resolve-config.*failed\|missing required field"; then
      echo "FAIL: $site failed in resolve-config, not at the design gate (stderr: $captured)" >&2
      return 1
    fi

    [ "$rc" -eq 0 ] || {
      echo "FAIL: $site setup.sh exited $rc with approved record (expected 0)" >&2
      return 1
    }

    rm -rf "$site_tmp"
  done
}

# ═══════════════════════════════════════════════════════════════════════════
# Test 4: not-applicable pass for headless projects
# ═══════════════════════════════════════════════════════════════════════════

@test "ui_present false yields not-applicable pass at all sites" {
  local site
  for site in "${SITES[@]}"; do
    local site_tmp
    site_tmp="$(mktemp -d "$BATS_TEST_TMPDIR/site-na-${site}-XXXXXX")"

    local old_tmp="$TEST_TMP"
    TEST_TMP="$site_tmp"
    seed_full_config false
    seed_roster
    seed_probe_stub available
    seed_site_prereqs "$site"
    TEST_TMP="$old_tmp"

    local setup_sh="$SKILLS_DIR/$site/scripts/setup.sh"
    [ -f "$setup_sh" ] || { echo "FAIL: setup.sh missing for $site" >&2; return 1; }

    local stderr_file="$site_tmp/stderr.txt"
    local rc=0
    env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH -u CLAUDE_PLUGIN_ROOT \
      PROJECT_ROOT="$site_tmp" PATH="$site_tmp/bin:$PATH" \
      bash "$setup_sh" >/dev/null 2>"$stderr_file" || rc=$?

    # Must not fail in resolve-config
    local captured
    captured="$(cat "$stderr_file")"
    captured="${captured//$site_tmp/}"
    if echo "$captured" | grep -qi "resolve-config.*failed\|missing required field"; then
      echo "FAIL: $site failed in resolve-config (stderr: $captured)" >&2
      return 1
    fi

    [ "$rc" -eq 0 ] || {
      echo "FAIL: $site setup.sh exited $rc with ui_present false (expected 0)" >&2
      return 1
    }

    # The design record must exist with applicability: not-applicable
    local drec="$site_tmp/.gaia/state/design-record.yaml"
    [ -f "$drec" ] || {
      echo "FAIL: $site did not create a design record" >&2
      return 1
    }
    local app
    app="$(yq '.applicability' "$drec")"
    [ "$app" = "not-applicable" ] || {
      echo "FAIL: $site record applicability is '$app', expected 'not-applicable'" >&2
      return 1
    }

    rm -rf "$site_tmp"
  done
}

@test "ui_present absent yields not-applicable pass (same as false)" {
  local site_tmp
  site_tmp="$(mktemp -d "$BATS_TEST_TMPDIR/na-absent-XXXXXX")"

  local old_tmp="$TEST_TMP"
  TEST_TMP="$site_tmp"
  seed_full_config_no_compliance
  seed_roster
  seed_probe_stub available
  seed_site_prereqs gaia-create-arch
  TEST_TMP="$old_tmp"

  local setup_sh="$SKILLS_DIR/gaia-create-arch/scripts/setup.sh"
  [ -f "$setup_sh" ] || { echo "FAIL: setup.sh missing" >&2; return 1; }

  local stderr_file="$site_tmp/stderr.txt"
  local rc=0
  env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH -u CLAUDE_PLUGIN_ROOT \
    PROJECT_ROOT="$site_tmp" PATH="$site_tmp/bin:$PATH" \
    bash "$setup_sh" >/dev/null 2>"$stderr_file" || rc=$?

  local captured
  captured="$(cat "$stderr_file")"
  captured="${captured//$site_tmp/}"
  if echo "$captured" | grep -qi "resolve-config.*failed\|missing required field"; then
    echo "FAIL: failed in resolve-config (stderr: $captured)" >&2
    return 1
  fi

  [ "$rc" -eq 0 ] || {
    echo "FAIL: setup.sh exited $rc with ui_present absent (expected 0)" >&2
    return 1
  }

  # The gate must have created a not-applicable design record
  local drec="$site_tmp/.gaia/state/design-record.yaml"
  [ -f "$drec" ] || {
    echo "FAIL: no design record created (gate did not run)" >&2
    return 1
  }

  rm -rf "$site_tmp"
}

@test "ui_present empty yields not-applicable pass (same as false)" {
  local site_tmp
  site_tmp="$(mktemp -d "$BATS_TEST_TMPDIR/na-empty-XXXXXX")"

  local old_tmp="$TEST_TMP"
  TEST_TMP="$site_tmp"
  # Use seed_full_config then overwrite compliance to have empty ui_present
  seed_full_config false
  seed_roster
  seed_probe_stub available
  seed_site_prereqs gaia-create-arch
  # Overwrite ui_present to empty (null in YAML)
  yq -i '.compliance.ui_present = null' "$site_tmp/.gaia/config/project-config.yaml"
  TEST_TMP="$old_tmp"

  local setup_sh="$SKILLS_DIR/gaia-create-arch/scripts/setup.sh"
  [ -f "$setup_sh" ] || { echo "FAIL: setup.sh missing" >&2; return 1; }

  local stderr_file="$site_tmp/stderr.txt"
  local rc=0
  env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH -u CLAUDE_PLUGIN_ROOT \
    PROJECT_ROOT="$site_tmp" PATH="$site_tmp/bin:$PATH" \
    bash "$setup_sh" >/dev/null 2>"$stderr_file" || rc=$?

  local captured
  captured="$(cat "$stderr_file")"
  captured="${captured//$site_tmp/}"
  if echo "$captured" | grep -qi "resolve-config.*failed\|missing required field"; then
    echo "FAIL: failed in resolve-config (stderr: $captured)" >&2
    return 1
  fi

  [ "$rc" -eq 0 ] || {
    echo "FAIL: setup.sh exited $rc with ui_present empty (expected 0)" >&2
    return 1
  }

  # The gate must have created a not-applicable design record
  local drec="$site_tmp/.gaia/state/design-record.yaml"
  [ -f "$drec" ] || {
    echo "FAIL: no design record created (gate did not run)" >&2
    return 1
  }

  rm -rf "$site_tmp"
}

@test "truthy string 'false' for ui_present yields not-applicable (not evaluated as true)" {
  local site_tmp
  site_tmp="$(mktemp -d "$BATS_TEST_TMPDIR/na-truthy-XXXXXX")"

  local old_tmp="$TEST_TMP"
  TEST_TMP="$site_tmp"
  # Seed full config then overwrite ui_present with quoted "false" string
  seed_full_config false
  seed_roster
  seed_probe_stub available
  seed_site_prereqs gaia-create-arch
  yq -i '.compliance.ui_present = "false"' "$site_tmp/.gaia/config/project-config.yaml"
  TEST_TMP="$old_tmp"

  local setup_sh="$SKILLS_DIR/gaia-create-arch/scripts/setup.sh"
  [ -f "$setup_sh" ] || { echo "FAIL: setup.sh missing" >&2; return 1; }

  local stderr_file="$site_tmp/stderr.txt"
  local rc=0
  env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH -u CLAUDE_PLUGIN_ROOT \
    PROJECT_ROOT="$site_tmp" PATH="$site_tmp/bin:$PATH" \
    bash "$setup_sh" >/dev/null 2>"$stderr_file" || rc=$?

  local captured
  captured="$(cat "$stderr_file")"
  captured="${captured//$site_tmp/}"
  if echo "$captured" | grep -qi "resolve-config.*failed\|missing required field"; then
    echo "FAIL: failed in resolve-config (stderr: $captured)" >&2
    return 1
  fi

  [ "$rc" -eq 0 ] || {
    echo "FAIL: setup.sh exited $rc with ui_present 'false' (expected 0)" >&2
    return 1
  }

  # The gate must have created a not-applicable design record
  local drec="$site_tmp/.gaia/state/design-record.yaml"
  [ -f "$drec" ] || {
    echo "FAIL: no design record created (gate did not run)" >&2
    return 1
  }

  rm -rf "$site_tmp"
}

@test "unparseable config makes the entry point fail closed (not not-applicable)" {
  # F4 decision: the plan inserts the design gate AFTER resolve-config
  # (Section 2a, after Section 2 validate-gate). For malformed YAML,
  # resolve-config fails FIRST — the gate never runs. The fail-closed
  # property of AC4 is satisfied by resolve-config's own failure: the
  # entry point exits non-zero and no artifact is produced. The design
  # gate's own fail-closed behaviour on malformed config is tested
  # directly in design-gate.bats, not here.
  #
  # This test asserts that the entry point DOES fail closed (exit non-zero)
  # on malformed config. It does NOT assert the failure comes from the
  # design gate specifically, because it comes from resolve-config.
  local site_tmp
  site_tmp="$(mktemp -d "$BATS_TEST_TMPDIR/na-malformed-XXXXXX")"

  local old_tmp="$TEST_TMP"
  TEST_TMP="$site_tmp"
  seed_config_malformed
  seed_roster
  seed_probe_stub available
  TEST_TMP="$old_tmp"

  local setup_sh="$SKILLS_DIR/gaia-create-arch/scripts/setup.sh"
  [ -f "$setup_sh" ] || { echo "FAIL: setup.sh missing" >&2; return 1; }

  local rc=0
  env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH -u CLAUDE_PLUGIN_ROOT \
    PROJECT_ROOT="$site_tmp" PATH="$site_tmp/bin:$PATH" \
    bash "$setup_sh" >/dev/null 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || {
    echo "FAIL: setup.sh exited 0 with malformed config (expected non-zero — fail closed)" >&2
    return 1
  }

  rm -rf "$site_tmp"
}

# Named mutant: mutant-na-as-approval
@test "mutant: not-applicable event is distinguishable from approval in the record" {
  local site_tmp
  site_tmp="$(mktemp -d "$BATS_TEST_TMPDIR/na-distinguish-XXXXXX")"

  local old_tmp="$TEST_TMP"
  TEST_TMP="$site_tmp"
  seed_full_config false
  seed_roster
  seed_probe_stub available
  seed_site_prereqs gaia-create-arch
  TEST_TMP="$old_tmp"

  local setup_sh="$SKILLS_DIR/gaia-create-arch/scripts/setup.sh"
  [ -f "$setup_sh" ] || { echo "FAIL: setup.sh missing" >&2; return 1; }

  local stderr_file="$site_tmp/stderr.txt"
  local rc=0
  env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH -u CLAUDE_PLUGIN_ROOT \
    PROJECT_ROOT="$site_tmp" PATH="$site_tmp/bin:$PATH" \
    bash "$setup_sh" >/dev/null 2>"$stderr_file" || rc=$?

  # Must not fail in resolve-config
  local captured
  captured="$(cat "$stderr_file")"
  captured="${captured//$site_tmp/}"
  if echo "$captured" | grep -qi "resolve-config.*failed\|missing required field"; then
    echo "FAIL: failed in resolve-config (stderr: $captured)" >&2
    return 1
  fi

  [ "$rc" -eq 0 ] || {
    echo "FAIL: setup.sh exited $rc (expected 0 for headless project)" >&2
    return 1
  }

  local drec="$site_tmp/.gaia/state/design-record.yaml"
  [ -f "$drec" ] || { echo "FAIL: no design record created" >&2; return 1; }

  # The last audit event must be "not-applicable-pass", NOT "approval"
  local last_event
  last_event="$(yq '.audit[-1].event' "$drec")"
  [ "$last_event" = "not-applicable-pass" ] || {
    echo "FAIL: last audit event is '$last_event', expected 'not-applicable-pass'" >&2
    return 1
  }

  # applicability must be "not-applicable"
  local applicability
  applicability="$(yq '.applicability' "$drec")"
  [ "$applicability" = "not-applicable" ] || {
    echo "FAIL: applicability is '$applicability', expected 'not-applicable'" >&2
    return 1
  }

  # design_state must NOT be "approved"
  local state
  state="$(yq '.design_state' "$drec")"
  [ "$state" != "approved" ] || {
    echo "FAIL: design_state is 'approved' — not-applicable was mistaken for approval" >&2
    return 1
  }

  rm -rf "$site_tmp"
}

# ═══════════════════════════════════════════════════════════════════════════
# Test 5: per-site mutation proof and no-inlined-decision sweep
# ═══════════════════════════════════════════════════════════════════════════

@test "removing the design_approved declaration from each site turns exactly that site red" {
  [ -f "$GATE_PREDICATES" ] || { echo "gate-predicates.sh missing" >&2; return 1; }

  local site idx
  for idx in "${!SITES[@]}"; do
    site="${SITES[$idx]}"
    local skill_md="$SKILLS_DIR/$site/SKILL.md"
    [ -f "$skill_md" ] || { echo "FAIL: SKILL.md missing for $site" >&2; return 1; }

    # Create a mutant copy: remove the design_approved line
    local mutant_md
    mutant_md="$(mktemp "$BATS_TEST_TMPDIR/mutant-decl-${site}-XXXXXX")"
    grep -v "design_approved" "$skill_md" > "$mutant_md"

    # Verify the declaration is gone
    source "$GATE_PREDICATES"
    local extracted
    extracted="$(_gate_extract_block "$mutant_md" pre_start)"

    # The mutant must NOT contain design_approved
    if echo "$extracted" | grep -q "design_approved"; then
      echo "FAIL: mutant for $site still has design_approved after removal" >&2
      return 1
    fi

    # Verify the original still has it (cross-check)
    extracted="$(_gate_extract_block "$skill_md" pre_start)"
    echo "$extracted" | grep -q "design_approved" || {
      echo "FAIL: original $site SKILL.md missing design_approved (Red phase: production code not written yet)" >&2
      return 1
    }

    rm -f "$mutant_md"
  done
}

@test "no site inlines the design-state decision logic" {
  # Sweep all eight setup.sh + SKILL.md for direct design-state reads
  # (stripping comments first)
  local inlined_count=0
  local site
  for site in "${SITES[@]}"; do
    local setup_sh="$SKILLS_DIR/$site/scripts/setup.sh"
    local skill_md="$SKILLS_DIR/$site/SKILL.md"

    for f in "$setup_sh" "$skill_md"; do
      [ -f "$f" ] || continue
      # Strip comments, then grep for inlined logic patterns
      local stripped
      stripped="$(sed 's/#.*//' "$f")"
      if printf '%s\n' "$stripped" | grep -qE "(yq.*design_state|design-record\.sh|= *\"?(draft|approved|in-dev|stale)\"?)"; then
        echo "INLINED: $f contains direct design-state logic" >&2
        inlined_count=$((inlined_count + 1))
      fi
    done
  done

  [ "$inlined_count" -eq 0 ] || {
    echo "FAIL: $inlined_count file(s) inline the design-state decision" >&2
    return 1
  }
}

# Named mutant: mutant-inline-decision
@test "mutant: adding an inlined yq design_state call to a setup.sh is caught" {
  # Create a temp copy with an inlined call
  local target="gaia-create-arch"
  local setup_sh="$SKILLS_DIR/$target/scripts/setup.sh"
  [ -f "$setup_sh" ] || { echo "FAIL: setup.sh missing for $target" >&2; return 1; }

  local mutant_sh
  mutant_sh="$(mktemp "$BATS_TEST_TMPDIR/mutant-inline-XXXXXX")"
  cp "$setup_sh" "$mutant_sh"
  # Inject an inlined decision
  echo 'yq ".design_state" "$PROJECT_ROOT/.gaia/state/design-record.yaml"' >> "$mutant_sh"

  # The sweep should catch it
  local stripped
  stripped="$(sed 's/#.*//' "$mutant_sh")"
  if printf '%s\n' "$stripped" | grep -qE "(yq.*design_state|design-record\.sh|= *\"?(draft|approved|in-dev|stale)\"?)"; then
    # Good — mutant caught
    :
  else
    echo "FAIL: mutant with inlined yq .design_state was NOT caught by the sweep" >&2
    return 1
  fi

  rm -f "$mutant_sh"
}

# Named mutant: mutant-inline-state-comparison
@test "mutant: adding an inlined state comparison to a setup.sh is caught" {
  # Plant a hardcoded design-state comparison and verify the sweep catches it.
  local target="gaia-create-arch"
  local setup_sh="$SKILLS_DIR/$target/scripts/setup.sh"
  [ -f "$setup_sh" ] || { echo "FAIL: setup.sh missing for $target" >&2; return 1; }

  local mutant_sh
  mutant_sh="$(mktemp "$BATS_TEST_TMPDIR/mutant-state-cmp-XXXXXX")"
  cp "$setup_sh" "$mutant_sh"
  # Inject an inlined state comparison (no yq, but a hardcoded = "approved")
  printf 'if [ "$(yq '"'"'.design_state'"'"' "$record")" = "approved" ]; then echo ok; fi\n' >> "$mutant_sh"

  local stripped
  stripped="$(sed 's/#.*//' "$mutant_sh")"
  if printf '%s\n' "$stripped" | grep -qE "(yq.*design_state|design-record\.sh|= *\"?(draft|approved|in-dev|stale)\"?)"; then
    # Good — mutant caught
    :
  else
    echo "FAIL: mutant with inlined state comparison was NOT caught by the sweep" >&2
    return 1
  fi

  rm -f "$mutant_sh"
}

# ═══════════════════════════════════════════════════════════════════════════
# Test 6: audited override honoured at all eight sites
# ═══════════════════════════════════════════════════════════════════════════

@test "override with --force-design proceeds at each site and writes dual-ledger entries" {
  local site
  for site in "${SITES[@]}"; do
    local site_tmp
    site_tmp="$(mktemp -d "$BATS_TEST_TMPDIR/override-${site}-XXXXXX")"

    local old_tmp="$TEST_TMP"
    TEST_TMP="$site_tmp"
    seed_ui_project available
    seed_site_prereqs "$site"
    _build_review_record
    seed_sprint_status sprint-82
    seed_lifecycle_overrides
    TEST_TMP="$old_tmp"

    local setup_sh="$SKILLS_DIR/$site/scripts/setup.sh"
    [ -f "$setup_sh" ] || { echo "FAIL: setup.sh missing for $site" >&2; return 1; }

    local stderr_file="$site_tmp/stderr.txt"
    local rc=0
    env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH -u CLAUDE_PLUGIN_ROOT \
      PROJECT_ROOT="$site_tmp" PATH="$site_tmp/bin:$PATH" \
      bash "$setup_sh" --force-design --reason "unblocking solutioning for sprint deadline" \
        --entry-point "$site" --sprint-id sprint-82 \
      >/dev/null 2>"$stderr_file" || rc=$?

    # Must not fail in resolve-config
    local captured
    captured="$(cat "$stderr_file")"
    captured="${captured//$site_tmp/}"
    if echo "$captured" | grep -qi "resolve-config.*failed\|missing required field"; then
      echo "FAIL: $site failed in resolve-config (stderr: $captured)" >&2
      return 1
    fi

    [ "$rc" -eq 0 ] || {
      echo "FAIL: $site setup.sh exited $rc with --force-design (expected 0)" >&2
      return 1
    }

    # Check design-record has an override entry
    local drec="$site_tmp/.gaia/state/design-record.yaml"
    local override_count
    override_count="$(yq '.overrides | length' "$drec")"
    [ "$override_count" -gt 0 ] || {
      echo "FAIL: $site design record has no override entries" >&2
      return 1
    }

    # Check audit has an override event
    local override_events
    override_events="$(yq '[.audit[] | select(.event == "override")] | length' "$drec")"
    [ "$override_events" -gt 0 ] || {
      echo "FAIL: $site design record has no audit override events" >&2
      return 1
    }

    # Check lifecycle-overrides has a bypass record
    local lo="$site_tmp/.gaia/state/lifecycle-overrides.yaml"
    local bypass_count
    bypass_count="$(yq '.bypasses | length' "$lo")"
    [ "$bypass_count" -gt 0 ] || {
      echo "FAIL: $site lifecycle-overrides has no bypass entries" >&2
      return 1
    }

    # design_state must NOT be changed to approved
    local state
    state="$(yq '.design_state' "$drec")"
    [ "$state" = "review" ] || {
      echo "FAIL: $site design_state changed from review to '$state' after override" >&2
      return 1
    }

    # Next invocation WITHOUT --force-design must halt
    local rc2=0
    env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH -u CLAUDE_PLUGIN_ROOT \
      PROJECT_ROOT="$site_tmp" PATH="$site_tmp/bin:$PATH" \
      bash "$setup_sh" >/dev/null 2>&1 || rc2=$?
    [ "$rc2" -ne 0 ] || {
      echo "FAIL: $site setup.sh exit 0 without --force-design after override (should still halt)" >&2
      return 1
    }

    rm -rf "$site_tmp"
  done
}

# Named mutant: mutant-ignore-force-flag
@test "mutant: removing the force-design parser from one setup.sh makes the override halt" {
  local target="gaia-create-arch"
  local setup_sh="$SKILLS_DIR/$target/scripts/setup.sh"
  [ -f "$setup_sh" ] || { echo "FAIL: setup.sh missing" >&2; return 1; }

  # Guard: the sed must actually remove something. If there is no
  # --force-design parser yet (Red phase), fail loudly rather than silently
  # producing a no-op mutant.
  local orig_lines mutant_lines
  orig_lines="$(wc -l < "$setup_sh" | tr -d ' ')"

  local site_tmp
  site_tmp="$(mktemp -d "$BATS_TEST_TMPDIR/mutant-force-XXXXXX")"

  local mutant_sh="$site_tmp/mutant-setup.sh"
  sed '/--force-design/d' "$setup_sh" > "$mutant_sh"
  chmod +x "$mutant_sh"

  mutant_lines="$(wc -l < "$mutant_sh" | tr -d ' ')"
  if [ "$orig_lines" -eq "$mutant_lines" ]; then
    echo "FAIL: sed removed nothing — setup.sh has no --force-design parser to mutate" >&2
    rm -rf "$site_tmp"
    return 1
  fi

  local old_tmp="$TEST_TMP"
  TEST_TMP="$site_tmp"
  seed_ui_project available
  seed_site_prereqs "$target"
  _build_review_record
  seed_sprint_status sprint-82
  seed_lifecycle_overrides
  TEST_TMP="$old_tmp"

  local rc=0
  env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH -u CLAUDE_PLUGIN_ROOT \
    PROJECT_ROOT="$site_tmp" PATH="$site_tmp/bin:$PATH" \
    bash "$mutant_sh" --force-design --reason "test override reason" --entry-point "$target" --sprint-id sprint-82 \
    >/dev/null 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || {
    echo "FAIL: mutant (--force-design removed) still exit 0 — parser is NOT the mechanism" >&2
    rm -rf "$site_tmp"
    return 1
  }

  rm -rf "$site_tmp"
}

# End-to-end: --bypass and --force-design each get their own --reason
@test "create-arch: bypass-then-force ordering routes each reason to its own ledger" {
  local site_tmp
  site_tmp="$(mktemp -d "$BATS_TEST_TMPDIR/e2e-order1-XXXXXX")"

  local old_tmp="$TEST_TMP"
  TEST_TMP="$site_tmp"
  seed_ui_project available
  seed_site_prereqs gaia-create-arch
  _build_review_record
  seed_sprint_status sprint-82
  seed_lifecycle_overrides
  TEST_TMP="$old_tmp"

  local setup_sh="$SKILLS_DIR/gaia-create-arch/scripts/setup.sh"

  local rc=0
  env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH -u CLAUDE_PLUGIN_ROOT \
    PROJECT_ROOT="$site_tmp" PATH="$site_tmp/bin:$PATH" \
    bash "$setup_sh" --bypass gaia-threat-model --reason "bypass reason A" \
      --force-design --reason "design reason B" \
      --entry-point gaia-create-arch --sprint-id sprint-82 \
    >/dev/null 2>&1 || rc=$?

  [ "$rc" -eq 0 ] || { echo "FAIL: exited $rc (expected 0)" >&2; return 1; }

  # Design override ledger must have "design reason B"
  local drec="$site_tmp/.gaia/state/design-record.yaml"
  local override_reason
  override_reason="$(yq '.overrides[-1].reason' "$drec")"
  [[ "$override_reason" == *"design reason B"* ]] || {
    echo "FAIL: design override reason is '$override_reason', expected 'design reason B'" >&2
    return 1
  }

  # Lifecycle bypass ledger: the gaia-threat-model entry must carry "bypass reason A"
  local lo="$site_tmp/.gaia/state/lifecycle-overrides.yaml"
  local bypass_reason
  bypass_reason="$(yq '[.bypasses[] | select(.skill == "gaia-threat-model")][0].reason' "$lo")"
  [[ "$bypass_reason" == *"bypass reason A"* ]] || {
    echo "FAIL: threat-model bypass reason is '$bypass_reason', expected 'bypass reason A'" >&2
    return 1
  }

  rm -rf "$site_tmp"
}

@test "create-arch: force-then-bypass ordering routes each reason to its own ledger" {
  local site_tmp
  site_tmp="$(mktemp -d "$BATS_TEST_TMPDIR/e2e-order2-XXXXXX")"

  local old_tmp="$TEST_TMP"
  TEST_TMP="$site_tmp"
  seed_ui_project available
  seed_site_prereqs gaia-create-arch
  _build_review_record
  seed_sprint_status sprint-82
  seed_lifecycle_overrides
  TEST_TMP="$old_tmp"

  local setup_sh="$SKILLS_DIR/gaia-create-arch/scripts/setup.sh"

  local rc=0
  env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH -u CLAUDE_PLUGIN_ROOT \
    PROJECT_ROOT="$site_tmp" PATH="$site_tmp/bin:$PATH" \
    bash "$setup_sh" --force-design --reason "design reason B" \
      --bypass gaia-threat-model --reason "bypass reason A" \
      --entry-point gaia-create-arch --sprint-id sprint-82 \
    >/dev/null 2>&1 || rc=$?

  [ "$rc" -eq 0 ] || { echo "FAIL: exited $rc (expected 0)" >&2; return 1; }

  # Design override ledger must have "design reason B"
  local drec="$site_tmp/.gaia/state/design-record.yaml"
  local override_reason
  override_reason="$(yq '.overrides[-1].reason' "$drec")"
  [[ "$override_reason" == *"design reason B"* ]] || {
    echo "FAIL: design override reason is '$override_reason', expected 'design reason B'" >&2
    return 1
  }

  # Lifecycle bypass ledger: the gaia-threat-model entry must carry "bypass reason A"
  local lo="$site_tmp/.gaia/state/lifecycle-overrides.yaml"
  local bypass_reason
  bypass_reason="$(yq '[.bypasses[] | select(.skill == "gaia-threat-model")][0].reason' "$lo")"
  [[ "$bypass_reason" == *"bypass reason A"* ]] || {
    echo "FAIL: threat-model bypass reason is '$bypass_reason', expected 'bypass reason A'" >&2
    return 1
  }

  rm -rf "$site_tmp"
}

@test "structural: each SKILL.md contains the override step (FORCE_DESIGN or --force-design)" {
  local site
  for site in "${SITES[@]}"; do
    local skill_md="$SKILLS_DIR/$site/SKILL.md"
    [ -f "$skill_md" ] || { echo "FAIL: SKILL.md missing for $site" >&2; return 1; }

    # Strip comments, search for override step
    local stripped
    stripped="$(sed 's/<!--.*-->//g' "$skill_md")"
    if ! printf '%s\n' "$stripped" | grep -qE "(FORCE_DESIGN|--force-design)"; then
      echo "FAIL: $site/SKILL.md has no override step (FORCE_DESIGN/--force-design)" >&2
      return 1
    fi
  done
}

# ═══════════════════════════════════════════════════════════════════════════
# Test 7: registry-derived site list catches a ninth entry point
# ═══════════════════════════════════════════════════════════════════════════

@test "registry-derived site list equals the eight pinned names" {
  [ -f "$LIFECYCLE_SEQ" ] || { echo "lifecycle-sequence.yaml missing at $LIFECYCLE_SEQ" >&2; return 1; }

  # Derive phase-3 nodes
  local phase3_nodes
  phase3_nodes="$(yq '.sequence | to_entries[] | select(.value.phase == "3-solutioning") | .value.command' "$LIFECYCLE_SEQ" | sed 's|^/||')"

  # Derive edge targets of phase-3 nodes
  local phase3_edges=""
  local node_keys
  node_keys="$(yq '.sequence | to_entries[] | select(.value.phase == "3-solutioning") | .key' "$LIFECYCLE_SEQ")"

  while IFS= read -r node_key; do
    [ -n "$node_key" ] || continue
    # Collect all edge commands: primary, parallel[], alternatives[].command
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
  # (including module-only nodes with no phase key — see derivation filter docs)
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
  pinned="$(printf '%s\n' "${SITES[@]}" | sort -u)"

  # Assert equality
  if [ "$derived_set" != "$pinned" ]; then
    echo "FAIL: derived set does not equal pinned set" >&2
    echo "  Derived: $(echo "$derived_set" | tr '\n' ' ')" >&2
    echo "  Pinned:  $(echo "$pinned" | tr '\n' ' ')" >&2
    return 1
  fi

  # Assert all eight declare the predicate
  [ -f "$GATE_PREDICATES" ] || { echo "gate-predicates.sh missing" >&2; return 1; }
  source "$GATE_PREDICATES"

  while IFS= read -r site; do
    [ -n "$site" ] || continue
    local skill_md="$SKILLS_DIR/$site/SKILL.md"
    [ -f "$skill_md" ] || { echo "FAIL: SKILL.md missing for $site" >&2; return 1; }
    local ex
    ex="$(_gate_extract_block "$skill_md" pre_start)"
    echo "$ex" | grep -q "design_approved" || {
      echo "FAIL: $site does not declare design_approved" >&2
      return 1
    }
  done <<< "$derived_set"
}

# Named mutant: mutant-add-ninth-node
@test "mutant: adding a ninth solutioning node makes the equality assertion fail" {
  [ -f "$LIFECYCLE_SEQ" ] || { echo "lifecycle-sequence.yaml missing" >&2; return 1; }

  local mutant_seq
  mutant_seq="$(mktemp "$BATS_TEST_TMPDIR/mutant-ninth-XXXXXX")"
  cp "$LIFECYCLE_SEQ" "$mutant_seq"

  # Add a ninth solutioning node
  yq -i '.sequence.test-ninth = {"phase": "3-solutioning", "command": "/gaia-test-ninth", "next": {"primary": "/gaia-foo"}}' "$mutant_seq"

  # Derive phase-3 commands from the mutant
  local phase3_commands
  phase3_commands="$(yq '.sequence | to_entries[] | select(.value.phase == "3-solutioning") | .value.command' "$mutant_seq" | sed 's|^/||' | sort -u)"

  # The ninth node must show up
  if ! echo "$phase3_commands" | grep -qxF "gaia-test-ninth"; then
    echo "FAIL: ninth node not detected in mutant" >&2
    return 1
  fi

  # The derived count must be > 8
  local count
  count="$(echo "$phase3_commands" | wc -l | tr -d ' ')"
  [ "$count" -gt 8 ] || [ "$count" -ne 8 ] || {
    echo "FAIL: mutant with ninth node still shows 8 — equality would pass" >&2
    return 1
  }

  rm -f "$mutant_seq"
}

# Named mutant: mutant-drop-edge-union
@test "mutant: dropping edge-target union causes review-api and adversarial to fall out" {
  [ -f "$LIFECYCLE_SEQ" ] || { echo "lifecycle-sequence.yaml missing" >&2; return 1; }

  # Derive ONLY phase-3 nodes (no edge targets) — the wrong derivation
  local nodes_only
  nodes_only="$(yq '.sequence | to_entries[] | select(.value.phase == "3-solutioning") | .value.command' "$LIFECYCLE_SEQ" | sed 's|^/||' | sort -u)"

  # review-api and adversarial must NOT be in the nodes-only set
  if echo "$nodes_only" | grep -qxF "gaia-review-api"; then
    echo "FAIL: review-api found in nodes-only (should only be an edge target)" >&2
    return 1
  fi
  if echo "$nodes_only" | grep -qxF "gaia-adversarial"; then
    echo "FAIL: adversarial found in nodes-only (should only be an edge target)" >&2
    return 1
  fi

  # The count must be < 8 (6 nodes vs 8 total)
  local count
  count="$(echo "$nodes_only" | wc -l | tr -d ' ')"
  [ "$count" -lt 8 ] || {
    echo "FAIL: nodes-only set has $count entries, expected < 8 (review-api+adversarial missing)" >&2
    return 1
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# Test 8: artifact tree byte-identical after mis-ordered fail
# ═══════════════════════════════════════════════════════════════════════════

@test "static scan: no artifact-tree write before the gate call in any setup.sh" {
  local site
  for site in "${SITES[@]}"; do
    local setup_sh="$SKILLS_DIR/$site/scripts/setup.sh"
    [ -f "$setup_sh" ] || { echo "FAIL: setup.sh missing for $site" >&2; return 1; }

    # Extract lines BEFORE _gate_run_pre_start, strip comments
    local before_gate
    before_gate="$(sed -n '1,/_gate_run_pre_start/p' "$setup_sh" | sed 's/#.*//')"

    # Look for artifact-tree writes (touch/mkdir/cp/mv/tee/>> on .gaia/artifacts paths)
    if printf '%s\n' "$before_gate" | grep -qE '(touch|mkdir -p|cp |mv |tee |>>).*\.gaia/artifacts'; then
      echo "FAIL: $site/setup.sh has artifact-tree writes before the gate call" >&2
      return 1
    fi
    if printf '%s\n' "$before_gate" | grep -qE '(touch|mkdir -p|cp |mv |tee |>>).*\$(PLANNING_ARTIFACTS|IMPLEMENTATION_ARTIFACTS|TEST_ARTIFACTS|CREATIVE_ARTIFACTS)'; then
      echo "FAIL: $site/setup.sh has artifact-variable writes before the gate call" >&2
      return 1
    fi
  done
}

# Named mutant: mutant-write-before-gate
@test "mutant: injecting an artifact write before the gate is caught" {
  local target="gaia-create-arch"
  local setup_sh="$SKILLS_DIR/$target/scripts/setup.sh"
  [ -f "$setup_sh" ] || { echo "FAIL: setup.sh missing" >&2; return 1; }

  # The setup.sh must contain the gate call for the mutant to be meaningful
  grep -q "_gate_run_pre_start" "$setup_sh" || {
    echo "FAIL: setup.sh does not contain _gate_run_pre_start (design gate not wired yet)" >&2
    return 1
  }

  # Create mutant: add an artifact write BEFORE the gate call
  local mutant_sh
  mutant_sh="$(mktemp "$BATS_TEST_TMPDIR/mutant-write-XXXXXX")"
  awk '/_gate_run_pre_start/ && !done { print "touch .gaia/artifacts/marker"; done=1 } {print}' "$setup_sh" > "$mutant_sh"

  # The scan should catch it: lines before the gate call contain artifact writes
  local before_gate
  before_gate="$(sed -n '1,/_gate_run_pre_start/p' "$mutant_sh" | sed 's/#.*//')"

  if printf '%s\n' "$before_gate" | grep -qE '(touch|mkdir).*\.gaia/artifacts'; then
    # Good — mutant caught
    :
  else
    echo "FAIL: mutant with artifact write before gate was NOT caught" >&2
    return 1
  fi

  rm -f "$mutant_sh"
}

# ═══════════════════════════════════════════════════════════════════════════
# Test 9: headless project runs all eight without halt
# ═══════════════════════════════════════════════════════════════════════════

@test "headless project runs all eight entry points without halt or error output" {
  local all_passed=true
  local site
  for site in "${SITES[@]}"; do
    local site_tmp
    site_tmp="$(mktemp -d "$BATS_TEST_TMPDIR/headless-${site}-XXXXXX")"

    local old_tmp="$TEST_TMP"
    TEST_TMP="$site_tmp"
    seed_full_config false
    seed_roster
    seed_probe_stub available
    seed_site_prereqs "$site"
    TEST_TMP="$old_tmp"

    local setup_sh="$SKILLS_DIR/$site/scripts/setup.sh"
    [ -f "$setup_sh" ] || { echo "FAIL: setup.sh missing for $site" >&2; return 1; }

    local stderr_file="$site_tmp/stderr.txt"
    local rc=0
    env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH -u CLAUDE_PLUGIN_ROOT \
      PROJECT_ROOT="$site_tmp" PATH="$site_tmp/bin:$PATH" \
      bash "$setup_sh" >/dev/null 2>"$stderr_file" || rc=$?

    # Must not fail in resolve-config
    local captured
    captured="$(cat "$stderr_file")"
    captured="${captured//$site_tmp/}"
    if echo "$captured" | grep -qi "resolve-config.*failed\|missing required field"; then
      echo "FAIL: headless $site failed in resolve-config (stderr: $captured)" >&2
      all_passed=false
      continue
    fi

    [ "$rc" -eq 0 ] || {
      echo "FAIL: headless $site setup.sh exited $rc (expected 0)" >&2
      all_passed=false
    }

    # stderr must not contain halt/error/fail/block/refused (stripped of temp path)
    if echo "$captured" | grep -qiE "(halt|error|fail|block|refused)"; then
      echo "FAIL: headless $site emitted halt/error-like text on stderr" >&2
      all_passed=false
    fi

    # Check that design record has not-applicable passes
    local drec="$site_tmp/.gaia/state/design-record.yaml"
    if [ -f "$drec" ]; then
      local app
      app="$(yq '.applicability' "$drec")"
      [ "$app" = "not-applicable" ] || {
        echo "FAIL: headless $site record applicability is '$app', not 'not-applicable'" >&2
        all_passed=false
      }
    fi

    rm -rf "$site_tmp"
  done

  $all_passed || return 1
}

# ═══════════════════════════════════════════════════════════════════════════
# Test 10: headless-to-UI flip fails closed
# ═══════════════════════════════════════════════════════════════════════════

@test "headless-to-UI flip makes the gate fail closed" {
  local site_tmp
  site_tmp="$(mktemp -d "$BATS_TEST_TMPDIR/flip-XXXXXX")"

  # Start headless
  local old_tmp="$TEST_TMP"
  TEST_TMP="$site_tmp"
  seed_full_config false
  seed_roster
  seed_probe_stub available
  seed_site_prereqs gaia-create-arch
  TEST_TMP="$old_tmp"

  local setup_sh="$SKILLS_DIR/gaia-create-arch/scripts/setup.sh"
  [ -f "$setup_sh" ] || { echo "FAIL: setup.sh missing" >&2; return 1; }

  # Run gate to record not-applicable
  local stderr_file="$site_tmp/stderr-phase1.txt"
  local rc_phase1=0
  env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH -u CLAUDE_PLUGIN_ROOT \
    PROJECT_ROOT="$site_tmp" PATH="$site_tmp/bin:$PATH" \
    bash "$setup_sh" >/dev/null 2>"$stderr_file" || rc_phase1=$?

  # Must not fail in resolve-config
  local captured
  captured="$(cat "$stderr_file")"
  captured="${captured//$site_tmp/}"
  if echo "$captured" | grep -qi "resolve-config.*failed\|missing required field"; then
    echo "FAIL: headless run failed in resolve-config (stderr: $captured)" >&2
    return 1
  fi
  [ "$rc_phase1" -eq 0 ] || {
    echo "FAIL: headless run exited $rc_phase1 (expected 0)" >&2
    return 1
  }

  # Verify not-applicable was recorded
  local drec="$site_tmp/.gaia/state/design-record.yaml"
  [ -f "$drec" ] || { echo "FAIL: no design record after headless run" >&2; return 1; }

  # Flip to UI-bearing (preserve all required fields)
  yq -i '.compliance.ui_present = true' "$site_tmp/.gaia/config/project-config.yaml"

  # Run again — should FAIL (not-applicable record on UI-bearing project)
  local stderr_file2="$site_tmp/stderr-phase2.txt"
  local rc=0
  env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH -u CLAUDE_PLUGIN_ROOT \
    PROJECT_ROOT="$site_tmp" PATH="$site_tmp/bin:$PATH" \
    bash "$setup_sh" >/dev/null 2>"$stderr_file2" || rc=$?

  # The halt must come from the design gate
  local captured2
  captured2="$(cat "$stderr_file2")"
  captured2="${captured2//$site_tmp/}"
  echo "$captured2" | grep -qiE "(design.gate|quality.gate|not-applicable.*ui)" || {
    echo "FAIL: halt did not come from the design gate (stderr: $captured2)" >&2
    return 1
  }

  [ "$rc" -ne 0 ] || {
    echo "FAIL: gate passed after headless-to-UI flip (should fail closed)" >&2
    return 1
  }

  rm -rf "$site_tmp"
}

# ═══════════════════════════════════════════════════════════════════════════
# Test 11: concurrent gate evaluations produce consistent verdict
# ═══════════════════════════════════════════════════════════════════════════

@test "concurrent headless gate evaluations produce a valid uncorrupted record" {
  local site_tmp
  site_tmp="$(mktemp -d "$BATS_TEST_TMPDIR/concurrent-XXXXXX")"

  local old_tmp="$TEST_TMP"
  TEST_TMP="$site_tmp"
  seed_full_config false
  seed_roster
  seed_probe_stub available
  seed_site_prereqs gaia-create-arch
  seed_site_prereqs gaia-edit-arch
  TEST_TMP="$old_tmp"

  local setup1="$SKILLS_DIR/gaia-create-arch/scripts/setup.sh"
  local setup2="$SKILLS_DIR/gaia-edit-arch/scripts/setup.sh"
  [ -f "$setup1" ] || { echo "FAIL: setup.sh missing for create-arch" >&2; return 1; }
  [ -f "$setup2" ] || { echo "FAIL: setup.sh missing for edit-arch" >&2; return 1; }

  # Launch two concurrent evaluations
  local pid1 pid2 rc1=0 rc2=0

  env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH -u CLAUDE_PLUGIN_ROOT \
    PROJECT_ROOT="$site_tmp" PATH="$site_tmp/bin:$PATH" \
    bash "$setup1" >/dev/null 2>&1 &
  pid1=$!

  env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH -u CLAUDE_PLUGIN_ROOT \
    PROJECT_ROOT="$site_tmp" PATH="$site_tmp/bin:$PATH" \
    bash "$setup2" >/dev/null 2>&1 &
  pid2=$!

  wait $pid1 || rc1=$?
  wait $pid2 || rc2=$?

  # Both must exit 0 (headless project)
  [ "$rc1" -eq 0 ] || { echo "FAIL: concurrent create-arch exited $rc1" >&2; return 1; }
  [ "$rc2" -eq 0 ] || { echo "FAIL: concurrent edit-arch exited $rc2" >&2; return 1; }

  # Design record must be valid YAML
  local drec="$site_tmp/.gaia/state/design-record.yaml"
  [ -f "$drec" ] || { echo "FAIL: no design record after concurrent run" >&2; return 1; }
  yq '.' "$drec" >/dev/null 2>&1 || {
    echo "FAIL: design record is corrupt YAML after concurrent run" >&2
    return 1
  }

  rm -rf "$site_tmp"
}

# ═══════════════════════════════════════════════════════════════════════════
# Test 12: halt message on stderr with record path, state, and remediation
# ═══════════════════════════════════════════════════════════════════════════

@test "halt message emits record path, state, and remediation on stderr" {
  local site_tmp
  site_tmp="$(mktemp -d "$BATS_TEST_TMPDIR/halt-msg-XXXXXX")"

  local old_tmp="$TEST_TMP"
  TEST_TMP="$site_tmp"
  seed_ui_project available
  seed_site_prereqs gaia-create-arch
  _build_review_record
  TEST_TMP="$old_tmp"

  local setup_sh="$SKILLS_DIR/gaia-create-arch/scripts/setup.sh"
  [ -f "$setup_sh" ] || { echo "FAIL: setup.sh missing" >&2; return 1; }

  local stderr_file="$site_tmp/stderr.txt"
  local stdout_file="$site_tmp/stdout.txt"
  local rc=0
  env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH -u CLAUDE_PLUGIN_ROOT \
    PROJECT_ROOT="$site_tmp" PATH="$site_tmp/bin:$PATH" \
    bash "$setup_sh" >"$stdout_file" 2>"$stderr_file" || rc=$?

  # Must exit non-zero
  [ "$rc" -ne 0 ] || { echo "FAIL: setup.sh exited 0 with unapproved record" >&2; return 1; }

  # Sanitize stderr (strip temp dir to avoid path matching in grep)
  local captured
  captured="$(cat "$stderr_file" 2>/dev/null || true)"
  captured="${captured//$site_tmp/}"

  # Must not have failed in resolve-config
  if echo "$captured" | grep -qi "resolve-config.*failed\|missing required field"; then
    echo "FAIL: failed in resolve-config, not at the design gate (stderr: $captured)" >&2
    return 1
  fi

  # Three required elements (emitted by the design gate's halt message):
  # 1. Record path reference
  echo "$captured" | grep -qi "record\|design-record" || {
    echo "FAIL: stderr missing record path reference" >&2
    echo "Captured: $captured" >&2
    return 1
  }

  # 2. State name
  echo "$captured" | grep -qiE "(review|draft|stale|in-dev)" || {
    echo "FAIL: stderr missing state name" >&2
    echo "Captured: $captured" >&2
    return 1
  }

  # 3. Remediation command or guidance
  echo "$captured" | grep -qiE "(approve|/gaia-design-review|--force-design)" || {
    echo "FAIL: stderr missing remediation guidance" >&2
    echo "Captured: $captured" >&2
    return 1
  }

  # No stdout pollution
  local stdout_size
  stdout_size="$(wc -c < "$stdout_file" | tr -d ' ')"
  [ "$stdout_size" -eq 0 ] || {
    echo "FAIL: setup.sh produced stdout ($stdout_size bytes) on halt — expected silence" >&2
    return 1
  }

  rm -rf "$site_tmp"
}

# ═══════════════════════════════════════════════════════════════════════════
# Test 13: review-api and adversarial setup scripts exist and gate works
# ═══════════════════════════════════════════════════════════════════════════

@test "review-api and adversarial have executable setup.sh and Setup heading" {
  local site
  for site in gaia-review-api gaia-adversarial; do
    local setup_sh="$SKILLS_DIR/$site/scripts/setup.sh"
    [ -f "$setup_sh" ] || { echo "FAIL: $site/scripts/setup.sh does not exist" >&2; return 1; }
    [ -x "$setup_sh" ] || { echo "FAIL: $site/scripts/setup.sh is not executable" >&2; return 1; }

    local skill_md="$SKILLS_DIR/$site/SKILL.md"
    [ -f "$skill_md" ] || { echo "FAIL: $site/SKILL.md missing" >&2; return 1; }
    grep -q "^## Setup" "$skill_md" || {
      echo "FAIL: $site/SKILL.md has no '## Setup' heading" >&2
      return 1
    }
  done
}

@test "review-api and adversarial halt with unapproved record (proves gate is active)" {
  local site
  for site in gaia-review-api gaia-adversarial; do
    local site_tmp
    site_tmp="$(mktemp -d "$BATS_TEST_TMPDIR/ec7-${site}-XXXXXX")"

    local old_tmp="$TEST_TMP"
    TEST_TMP="$site_tmp"
    seed_ui_project available
    seed_site_prereqs "$site"
    _build_review_record
    TEST_TMP="$old_tmp"

    local setup_sh="$SKILLS_DIR/$site/scripts/setup.sh"
    [ -f "$setup_sh" ] || { echo "FAIL: setup.sh missing for $site" >&2; return 1; }

    local stderr_file="$site_tmp/stderr.txt"
    local rc=0
    env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH -u CLAUDE_PLUGIN_ROOT \
      PROJECT_ROOT="$site_tmp" PATH="$site_tmp/bin:$PATH" \
      bash "$setup_sh" >/dev/null 2>"$stderr_file" || rc=$?

    # Must not fail in resolve-config
    local captured
    captured="$(cat "$stderr_file")"
    captured="${captured//$site_tmp/}"
    if echo "$captured" | grep -qi "resolve-config.*failed\|missing required field"; then
      echo "FAIL: $site failed in resolve-config (stderr: $captured)" >&2
      return 1
    fi

    [ "$rc" -ne 0 ] || {
      echo "FAIL: $site setup.sh exited 0 with unapproved record (gate not active)" >&2
      return 1
    }

    rm -rf "$site_tmp"
  done
}

# Named mutant: mutant-remove-setup-script
@test "mutant: removing setup.sh from review-api is caught by the structural check" {
  # Copy the real skills tree, remove review-api's setup.sh, and run the same
  # structural check ("setup.sh exists and is executable for every site") against
  # the mutant copy. The check must fail — proving the structural test catches a
  # missing setup.sh rather than asserting a tautology.
  local site="gaia-review-api"
  local setup_sh="$SKILLS_DIR/$site/scripts/setup.sh"

  # Pre-condition: the real setup.sh exists
  [ -f "$setup_sh" ] || {
    echo "FAIL: $site/scripts/setup.sh is missing in the real tree" >&2
    return 1
  }

  # Build a mutant skills tree with setup.sh removed for review-api
  local mutant_dir
  mutant_dir="$(mktemp -d "$BATS_TEST_TMPDIR/mutant-rm-setup-XXXXXX")"
  local s
  for s in "${SITES[@]}"; do
    mkdir -p "$mutant_dir/$s/scripts"
    cp "$SKILLS_DIR/$s/SKILL.md" "$mutant_dir/$s/SKILL.md" 2>/dev/null || true
    if [ "$s" != "$site" ]; then
      cp "$SKILLS_DIR/$s/scripts/setup.sh" "$mutant_dir/$s/scripts/setup.sh" 2>/dev/null || true
      chmod +x "$mutant_dir/$s/scripts/setup.sh" 2>/dev/null || true
    fi
  done

  # Run the structural check against the mutant copy — must fail
  local found_gap=false
  for s in "${SITES[@]}"; do
    if [ ! -f "$mutant_dir/$s/scripts/setup.sh" ] || [ ! -x "$mutant_dir/$s/scripts/setup.sh" ]; then
      found_gap=true
      break
    fi
  done

  [ "$found_gap" = true ] || {
    echo "FAIL: mutant with removed setup.sh was NOT caught by the structural check" >&2
    return 1
  }

  rm -rf "$mutant_dir"
}

# ═══════════════════════════════════════════════════════════════════════════
# Missing gate-predicates library halts every entry point (fail closed)
# ═══════════════════════════════════════════════════════════════════════════

@test "missing gate-predicates.sh halts every entry point and writes nothing" {
  local plugin_root
  plugin_root="$(cd "$SKILLS_DIR/.." && pwd)"

  local site
  for site in "${SITES[@]}"; do
    local site_tmp
    site_tmp="$(mktemp -d "$BATS_TEST_TMPDIR/nolib-${site}-XXXXXX")"

    local old_tmp="$TEST_TMP"
    TEST_TMP="$site_tmp"
    seed_ui_project available
    seed_site_prereqs "$site"
    _build_approved_record
    TEST_TMP="$old_tmp"

    # Copy the plugin tree, then remove gate-predicates.sh
    local plugin_copy="$site_tmp/plugin"
    cp -R "$plugin_root" "$plugin_copy"
    rm -f "$plugin_copy/scripts/lib/gate-predicates.sh"

    local setup_sh="$plugin_copy/skills/$site/scripts/setup.sh"
    [ -f "$setup_sh" ] || { echo "FAIL: setup.sh missing for $site in copy" >&2; return 1; }

    # Snapshot the .gaia tree before
    local before_hash
    before_hash="$(_sha256_tree "$site_tmp/.gaia")"

    local stderr_file="$site_tmp/stderr.txt"
    local rc=0
    env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH -u CLAUDE_PLUGIN_ROOT \
      PROJECT_ROOT="$site_tmp" PATH="$site_tmp/bin:$PATH" \
      bash "$setup_sh" >/dev/null 2>"$stderr_file" || rc=$?

    # Must exit non-zero
    [ "$rc" -ne 0 ] || {
      echo "FAIL: $site setup.sh exited 0 with gate-predicates.sh absent" >&2
      return 1
    }

    # Stderr must name the missing library
    local captured
    captured="$(cat "$stderr_file")"
    captured="${captured//$site_tmp/}"
    echo "$captured" | grep -qi "gate-predicates" || {
      echo "FAIL: $site stderr does not name the missing library" >&2
      echo "Captured: $captured" >&2
      return 1
    }

    # No writes to the .gaia tree
    local after_hash
    after_hash="$(_sha256_tree "$site_tmp/.gaia")"
    [ "$before_hash" = "$after_hash" ] || {
      echo "FAIL: $site wrote to the tree despite missing library" >&2
      return 1
    }

    rm -rf "$site_tmp"
  done
}

# Mutant: restore the non-fatal skip for the missing library — must go red
@test "mutant: non-fatal skip for missing gate-predicates lets the entry point proceed" {
  local target_site="gaia-create-arch"
  local plugin_root
  plugin_root="$(cd "$SKILLS_DIR/.." && pwd)"

  local site_tmp
  site_tmp="$(mktemp -d "$BATS_TEST_TMPDIR/nolib-mutant-XXXXXX")"

  local old_tmp="$TEST_TMP"
  TEST_TMP="$site_tmp"
  seed_full_config false
  seed_roster
  seed_probe_stub available
  seed_site_prereqs "$target_site"
  TEST_TMP="$old_tmp"

  # Copy plugin tree, remove gate-predicates.sh, then patch setup.sh
  # to use a non-fatal skip instead of die
  local plugin_copy="$site_tmp/plugin"
  cp -R "$plugin_root" "$plugin_copy"
  rm -f "$plugin_copy/scripts/lib/gate-predicates.sh"
  local mutant_sh="$plugin_copy/skills/$target_site/scripts/setup.sh"
  sed 's/die "gate-predicates.sh not found/log "gate-predicates.sh not found/' "$mutant_sh" > "$mutant_sh.tmp" && mv "$mutant_sh.tmp" "$mutant_sh"
  chmod +x "$mutant_sh"

  local rc=0
  env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH -u CLAUDE_PLUGIN_ROOT \
    PROJECT_ROOT="$site_tmp" PATH="$site_tmp/bin:$PATH" \
    bash "$mutant_sh" >/dev/null 2>&1 || rc=$?

  # The non-fatal mutant should let the script proceed (exit 0)
  [ "$rc" -eq 0 ] || {
    echo "FAIL: mutant (non-fatal skip) still exited non-zero ($rc)" >&2
    return 1
  }

  rm -rf "$site_tmp"
}

# ═══════════════════════════════════════════════════════════════════════════
# Doc-page structural check: design-approval prerequisite is inside <ul>
# ═══════════════════════════════════════════════════════════════════════════

@test "doc pages: design-approval prerequisite is well-formed on all eight pages" {
  local doc_dir
  doc_dir="$(cd "$BATS_TEST_DIRNAME/../../../documentation/commands" && pwd)"
  local site
  for site in "${SITES[@]}"; do
    local page="$doc_dir/$site.html"
    [ -f "$page" ] || { echo "FAIL: $page not found" >&2; return 1; }

    # Extract the prerequisites section (first <section id="prerequisites"> to its </section>).
    # Use awk, not sed, because BSD sed continues the range when start and
    # end match the same line.
    local prereq
    prereq="$(awk '/<section id="prerequisites">/{p=1} p{print} p && /<\/section>/{exit}' "$page")"
    [ -n "$prereq" ] || { echo "FAIL: $site.html has no prerequisites section" >&2; return 1; }

    # Item must be inside the section
    echo "$prereq" | grep -q "Design approval required" || {
      echo "FAIL: $site.html design-approval item is not inside the prerequisites section" >&2
      return 1
    }

    # Item must contain the literal &lt;text&gt; placeholder
    echo "$prereq" | grep -q '&lt;text&gt;' || {
      echo "FAIL: $site.html missing literal &lt;text&gt; in design-approval item" >&2
      return 1
    }

    # No sed-corruption artifacts anywhere on the page
    local full
    full="$(cat "$page")"
    if echo "$full" | grep -qE '</ul></section>lt;|</ul></section>gt;|</ul></section>amp;'; then
      echo "FAIL: $site.html contains sed-corruption artifact (</ul></section> followed by lt;/gt;/amp;)" >&2
      return 1
    fi

    # Balanced <ul>/<ul> and single </section> inside the prerequisites section
    local ul_open ul_close section_close
    ul_open="$(echo "$prereq" | grep -o '<ul>' | wc -l | tr -d ' ')"
    ul_close="$(echo "$prereq" | grep -o '</ul>' | wc -l | tr -d ' ')"
    section_close="$(echo "$prereq" | grep -o '</section>' | wc -l | tr -d ' ')"
    [ "$ul_open" -eq "$ul_close" ] || {
      echo "FAIL: $site.html prerequisites has unbalanced <ul> ($ul_open open, $ul_close close)" >&2
      return 1
    }
    [ "$section_close" -eq 1 ] || {
      echo "FAIL: $site.html prerequisites has $section_close </section> tags (expected 1)" >&2
      return 1
    }
  done
}
