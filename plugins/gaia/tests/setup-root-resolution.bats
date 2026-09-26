#!/usr/bin/env bats
# setup-root-resolution.bats — verify that skill setup scripts resolve the
# project root from the working directory instead of walking up from the
# plugin install location.
#
# Coverage:
#   (AC1)    walk-up from subdirectory finds config anchor (8 scripts)
#   (AC2)    regression scan: no executable five-level walk-up in any setup.sh
#   (AC-EC1) subdirectory resolution (covered by the 8 functional tests)
#   (AC-EC2) walk-up stops at $HOME boundary
#   (AC-EC3) resolve-config absolute-only guard (edit-prd, edit-arch)

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  REAL_SCRIPTS_DIR="$PLUGIN_ROOT/scripts"
  REAL_LIB_DIR="$REAL_SCRIPTS_DIR/lib"
  SKILLS_DIR="$PLUGIN_ROOT/skills"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Helper: seed a fixture project with the config anchor.
# ---------------------------------------------------------------------------
_seed_fixture_project() {
  local root="$1"
  mkdir -p "$root/.gaia/config"
  mkdir -p "$root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$root/.gaia/state"
  mkdir -p "$root/subdir"
  cat > "$root/.gaia/config/project-config.yaml" << 'YAML'
project_name: fixture-project
compliance:
  ui_present: false
stacks:
  - identifier: bash
    path: "."
YAML
}

# ---------------------------------------------------------------------------
# Helper: create a fake PLUGIN_SCRIPTS_DIR with stub top-level scripts
# and a lib/ symlink to the real lib/ directory.
#
# For the six scripts without a design gate, the real lib/ is never sourced.
# For create-arch and edit-arch, the real lib/ provides gate-predicates.sh,
# design-gate.sh, parse-force-design.sh, acquire-lock.sh, and
# lifecycle-overrides.sh.
# ---------------------------------------------------------------------------
_seed_fake_scripts_dir() {
  local fake_dir="$1"
  mkdir -p "$fake_dir"

  # Stub resolve-config.sh — echoes lowercase keys so the section-1
  # eval-export loop picks them up harmlessly. Uppercase keys like
  # PROJECT_ROOT= would be exported and would mask the walk-up under test.
  cat > "$fake_dir/resolve-config.sh" << 'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "project_name='fixture-project'"
STUB
  chmod +x "$fake_dir/resolve-config.sh"

  # Stub validate-gate.sh
  cat > "$fake_dir/validate-gate.sh" << 'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$fake_dir/validate-gate.sh"

  # Stub checkpoint.sh — exit 2 = fresh run
  cat > "$fake_dir/checkpoint.sh" << 'STUB'
#!/usr/bin/env bash
exit 2
STUB
  chmod +x "$fake_dir/checkpoint.sh"

  # Stub design-record.sh — init-not-applicable is called with || true
  cat > "$fake_dir/design-record.sh" << 'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$fake_dir/design-record.sh"

  # lib/ symlink to the REAL lib directory
  ln -sf "$REAL_LIB_DIR" "$fake_dir/lib"
}

# ---------------------------------------------------------------------------
# Helper: run a setup script with a controlled PLUGIN_SCRIPTS_DIR.
#
# The real setup.sh computes PLUGIN_SCRIPTS_DIR from SCRIPT_DIR (dirname $0).
# We cannot override that directly, so we create a wrapper script that
# overrides the three path variables (SCRIPT_DIR, SKILL_DIR,
# PLUGIN_SCRIPTS_DIR) and then sources the real setup.sh body.
#
# Instead of that fragile approach, we create a shim at the expected
# relative location so the setup.sh's own path arithmetic arrives at our
# fake scripts dir.
#
# Layout:
#   $TEST_TMP/shim-tree/skills/<skill>/scripts/setup.sh  (copy of real)
#   $TEST_TMP/shim-tree/scripts/                          (fake scripts dir)
#
# The setup.sh does: PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"
# From shim-tree/skills/<skill>/scripts/, ../../.. is shim-tree/, so
# ../../../scripts is shim-tree/scripts/ — our fake.
# ---------------------------------------------------------------------------
_build_shim_tree() {
  local skill_name="$1"
  local shim_root="$TEST_TMP/shim-tree"
  local skill_src="$SKILLS_DIR/$skill_name"
  local skill_shim="$shim_root/skills/$skill_name"

  mkdir -p "$skill_shim/scripts"

  # Copy the real setup.sh
  cp "$skill_src/scripts/setup.sh" "$skill_shim/scripts/setup.sh"
  chmod +x "$skill_shim/scripts/setup.sh"

  # Copy the SKILL.md (needed by gate-predicates for quality_gates block)
  if [ -f "$skill_src/SKILL.md" ]; then
    cp "$skill_src/SKILL.md" "$skill_shim/SKILL.md"
  fi

  # Copy any template files the script checks for
  for tmpl in "$skill_src"/*.md; do
    [ -f "$tmpl" ] || continue
    local base
    base="$(basename "$tmpl")"
    [ "$base" = "SKILL.md" ] && continue
    cp "$tmpl" "$skill_shim/$base"
  done

  # Create the fake scripts dir
  _seed_fake_scripts_dir "$shim_root/scripts"

  printf '%s' "$skill_shim/scripts/setup.sh"
}

# ---------------------------------------------------------------------------
# Helper: extract the project_root= value from captured output.
# Returns empty string (not failure) when no match is found, so the test
# fails at the assertion, not at extraction.
# ---------------------------------------------------------------------------
_extract_project_root() {
  local text="$1"
  local match
  match="$(printf '%s\n' "$text" | grep -o 'project_root=[^ )]*' | head -1 || true)"
  if [ -n "$match" ]; then
    printf '%s' "${match#project_root=}"
  fi
}

# ===========================================================================
# (AC2) Regression scan
# ===========================================================================

@test "(AC2) no setup.sh under skills/ has an uncommented five-level walk-up" {
  local file_count=0
  local hit_count=0
  local hits=""
  while IFS= read -r f; do
    file_count=$((file_count + 1))
    local result
    result="$(awk '
      { line = $0; sub(/^[[:space:]]+/, "", line) }
      line !~ /^#/ && line ~ /SKILL_DIR\/\.\.\/\.\.\/\.\.\/\.\.\/\.\./ {
        print FILENAME ":" NR ": " $0; found = 1
      }
      END { exit found ? 0 : 1 }
    ' "$f" 2>&1)" || continue
    if [ -n "$result" ]; then
      hit_count=$((hit_count + 1))
      hits="${hits}${result}"$'\n'
    fi
  done < <(find "$PLUGIN_ROOT/skills" -path '*/scripts/setup.sh' -type f)
  # Scan must find files (non-vacuous)
  [ "$file_count" -gt 0 ]
  # No executable walk-up lines
  if [ "$hit_count" -gt 0 ]; then
    printf 'Found %d setup.sh file(s) with an uncommented five-level walk-up:\n%s' \
      "$hit_count" "$hits" >&2
    return 1
  fi
}

# ===========================================================================
# (AC1) Functional tests — one per affected script
# ===========================================================================

# --- create-arch (Task 5: resolution before design gate) ---

@test "(AC1) create-arch walk-up from subdirectory finds config anchor" {
  _seed_fixture_project "$TEST_TMP/project"
  local setup_sh
  setup_sh="$(_build_shim_tree gaia-create-arch)"

  cd "$TEST_TMP/project/subdir"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u GAIA_PROJECT_ROOT -u PROJECT_PATH \
    bash "$setup_sh" 2>&1
  printf '%s\n' "$output" >&2
  [ "$status" -eq 0 ]
  local resolved
  resolved="$(_extract_project_root "$output")"
  [ "$resolved" = "$TEST_TMP/project" ]
}

# --- create-prd ---

@test "(AC1) create-prd walk-up from subdirectory finds config anchor" {
  _seed_fixture_project "$TEST_TMP/project"
  local setup_sh
  setup_sh="$(_build_shim_tree gaia-create-prd)"

  cd "$TEST_TMP/project/subdir"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u GAIA_PROJECT_ROOT -u PROJECT_PATH \
    bash "$setup_sh" 2>&1
  printf '%s\n' "$output" >&2
  [ "$status" -eq 0 ]
  local resolved
  resolved="$(_extract_project_root "$output")"
  [ "$resolved" = "$TEST_TMP/project" ]
}

# --- create-ux ---

@test "(AC1) create-ux walk-up from subdirectory finds config anchor" {
  _seed_fixture_project "$TEST_TMP/project"
  local setup_sh
  setup_sh="$(_build_shim_tree gaia-create-ux)"

  cd "$TEST_TMP/project/subdir"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u GAIA_PROJECT_ROOT -u PROJECT_PATH \
    bash "$setup_sh" 2>&1
  printf '%s\n' "$output" >&2
  [ "$status" -eq 0 ]
  local resolved
  resolved="$(_extract_project_root "$output")"
  [ "$resolved" = "$TEST_TMP/project" ]
}

# --- edit-arch (Task 5: resolution before design gate) ---

@test "(AC1) edit-arch walk-up from subdirectory finds config anchor" {
  _seed_fixture_project "$TEST_TMP/project"
  local setup_sh
  setup_sh="$(_build_shim_tree gaia-edit-arch)"

  cd "$TEST_TMP/project/subdir"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u GAIA_PROJECT_ROOT -u PROJECT_PATH \
    bash "$setup_sh" 2>&1
  printf '%s\n' "$output" >&2
  [ "$status" -eq 0 ]
  local resolved
  resolved="$(_extract_project_root "$output")"
  [ "$resolved" = "$TEST_TMP/project" ]
}

# --- edit-prd ---

@test "(AC1) edit-prd walk-up from subdirectory finds config anchor" {
  _seed_fixture_project "$TEST_TMP/project"
  local setup_sh
  setup_sh="$(_build_shim_tree gaia-edit-prd)"

  cd "$TEST_TMP/project/subdir"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u GAIA_PROJECT_ROOT -u PROJECT_PATH \
    bash "$setup_sh" 2>&1
  printf '%s\n' "$output" >&2
  [ "$status" -eq 0 ]
  local resolved
  resolved="$(_extract_project_root "$output")"
  [ "$resolved" = "$TEST_TMP/project" ]
}

# --- edit-test-plan ---

@test "(AC1) edit-test-plan walk-up from subdirectory finds config anchor" {
  _seed_fixture_project "$TEST_TMP/project"
  local setup_sh
  setup_sh="$(_build_shim_tree gaia-edit-test-plan)"

  cd "$TEST_TMP/project/subdir"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u GAIA_PROJECT_ROOT -u PROJECT_PATH \
    bash "$setup_sh" 2>&1
  printf '%s\n' "$output" >&2
  [ "$status" -eq 0 ]
  local resolved
  resolved="$(_extract_project_root "$output")"
  [ "$resolved" = "$TEST_TMP/project" ]
}

# --- edit-ux ---

@test "(AC1) edit-ux walk-up from subdirectory finds config anchor" {
  _seed_fixture_project "$TEST_TMP/project"
  local setup_sh
  setup_sh="$(_build_shim_tree gaia-edit-ux)"

  cd "$TEST_TMP/project/subdir"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u GAIA_PROJECT_ROOT -u PROJECT_PATH \
    bash "$setup_sh" 2>&1
  printf '%s\n' "$output" >&2
  [ "$status" -eq 0 ]
  local resolved
  resolved="$(_extract_project_root "$output")"
  [ "$resolved" = "$TEST_TMP/project" ]
}

# --- validate-prd ---

@test "(AC1) validate-prd walk-up from subdirectory finds config anchor" {
  _seed_fixture_project "$TEST_TMP/project"
  local setup_sh
  setup_sh="$(_build_shim_tree gaia-validate-prd)"

  cd "$TEST_TMP/project/subdir"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u GAIA_PROJECT_ROOT -u PROJECT_PATH \
    bash "$setup_sh" 2>&1
  printf '%s\n' "$output" >&2
  [ "$status" -eq 0 ]
  local resolved
  resolved="$(_extract_project_root "$output")"
  [ "$resolved" = "$TEST_TMP/project" ]
}

# ===========================================================================
# (AC-EC3) resolve-config absolute-only guard
# ===========================================================================

@test "(AC-EC3) edit-prd uses absolute resolve-config result, ignores relative" {
  _seed_fixture_project "$TEST_TMP/project"
  local setup_sh
  setup_sh="$(_build_shim_tree gaia-edit-prd)"

  # Seed a resolve-config.sh that returns a DIFFERENT absolute path for
  # the project_root positional query, and a relative path for a second run.
  local fake_scripts="$TEST_TMP/shim-tree/scripts"
  local alt_root="$TEST_TMP/alt-root"
  mkdir -p "$alt_root"

  cat > "$fake_scripts/resolve-config.sh" << STUB
#!/usr/bin/env bash
set -euo pipefail
# Lowercase keys so section-1 export does not mask the walk-up.
if [ "\${1:-}" = "project_root" ]; then
  echo "$alt_root"
  exit 0
fi
echo "project_name='fixture-project'"
STUB
  chmod +x "$fake_scripts/resolve-config.sh"

  cd "$TEST_TMP/project/subdir"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u GAIA_PROJECT_ROOT -u PROJECT_PATH \
    bash "$setup_sh" 2>&1
  printf '%s\n' "$output" >&2
  [ "$status" -eq 0 ]
  local resolved
  resolved="$(_extract_project_root "$output")"
  # Must use the absolute path from resolve-config, not the walk-up anchor
  [ "$resolved" = "$alt_root" ]
}

@test "(AC-EC3) edit-arch uses absolute resolve-config result, ignores relative" {
  _seed_fixture_project "$TEST_TMP/project"
  local setup_sh
  setup_sh="$(_build_shim_tree gaia-edit-arch)"

  local fake_scripts="$TEST_TMP/shim-tree/scripts"
  local alt_root="$TEST_TMP/alt-root"
  # Seed a config at alt_root so the real design gate finds it and passes.
  _seed_fixture_project "$alt_root"

  cat > "$fake_scripts/resolve-config.sh" << STUB
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "project_root" ]; then
  echo "$alt_root"
  exit 0
fi
echo "project_name='fixture-project'"
STUB
  chmod +x "$fake_scripts/resolve-config.sh"

  cd "$TEST_TMP/project/subdir"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u GAIA_PROJECT_ROOT -u PROJECT_PATH \
    bash "$setup_sh" 2>&1
  printf '%s\n' "$output" >&2
  [ "$status" -eq 0 ]
  local resolved
  resolved="$(_extract_project_root "$output")"
  [ "$resolved" = "$alt_root" ]
}

@test "(AC-EC3) relative project_root from resolve-config is rejected by the absolute-only guard" {
  _seed_fixture_project "$TEST_TMP/project"
  local setup_sh
  setup_sh="$(_build_shim_tree gaia-edit-prd)"

  local fake_scripts="$TEST_TMP/shim-tree/scripts"
  # Return a relative path for the project_root query
  cat > "$fake_scripts/resolve-config.sh" << 'STUB'
#!/usr/bin/env bash
set -euo pipefail
# Lowercase keys so section-1 export does not mask the walk-up.
if [ "${1:-}" = "project_root" ]; then
  echo "relative/path"
  exit 0
fi
echo "project_name='fixture-project'"
STUB
  chmod +x "$fake_scripts/resolve-config.sh"

  cd "$TEST_TMP/project/subdir"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u GAIA_PROJECT_ROOT -u PROJECT_PATH \
    bash "$setup_sh" 2>&1
  printf '%s\n' "$output" >&2
  [ "$status" -eq 0 ]
  local resolved
  resolved="$(_extract_project_root "$output")"
  # The relative path must be rejected; walk-up should find the anchor instead
  [ "$resolved" = "$TEST_TMP/project" ]
}

# ===========================================================================
# (AC-EC2) $HOME boundary
# ===========================================================================

@test "(AC-EC2) walk-up stops at HOME boundary and falls back to PWD" {
  # Anchor ABOVE fake-home — the mutant trap
  mkdir -p "$TEST_TMP/.gaia/config"
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" << 'YAML'
project_name: trap-above-home
YAML

  mkdir -p "$TEST_TMP/fake-home"

  local setup_sh
  setup_sh="$(_build_shim_tree gaia-create-prd)"
  # Seed a template so create-prd does not die on missing template
  touch "$TEST_TMP/shim-tree/skills/gaia-create-prd/prd-template.md"

  cd "$TEST_TMP/fake-home"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u GAIA_PROJECT_ROOT -u PROJECT_PATH \
    HOME="$TEST_TMP/fake-home" \
    bash "$setup_sh" 2>&1
  printf '%s\n' "$output" >&2
  [ "$status" -eq 0 ]
  local resolved
  resolved="$(_extract_project_root "$output")"
  # The walk-up must stop at HOME and fall back to $PWD (fake-home),
  # NOT escape to $TEST_TMP where the anchor sits.
  [ "$resolved" = "$TEST_TMP/fake-home" ]
}
