#!/usr/bin/env bats
# AF-2026-05-24-7 + AF-2026-05-24-8 + AF-2026-05-24-9 bundle
# Test02 findings F-1, F-2, F-3, F-4, F-5, F-7, F-25
#
# F-1: ajv strict-mode rejects x-no-auto-hydration → pass --strict=false
# F-2: bridge-enable scaffold helper script (deterministic, idempotent)
# F-3: --bypass / --reason flags now parsed by create-arch setup.sh
# F-4: create-prd finalize.sh auto-appends Review Findings Incorporated
# F-5: test-strategy finalize.sh writes test-plan.md alias
# F-7: create-epics finalize.sh normalizes ASCII -- to em-dash —
# F-25: action-items.yaml canonical path = .gaia/state/action-items.yaml

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

PLUGIN_ROOT="${BATS_TEST_DIRNAME}/.."

# --- F-1 ---

@test "F-1: validate-against-schema.sh passes --strict=false to ajv-cli" {
  grep -qF -- '--strict=false' "${PLUGIN_ROOT}/skills/gaia-init/scripts/validate-against-schema.sh"
}

@test "F-1: validate-against-schema.sh comments name x-no-auto-hydration as the reason" {
  grep -qF 'x-no-auto-hydration' "${PLUGIN_ROOT}/skills/gaia-init/scripts/validate-against-schema.sh"
}

# --- F-2 ---

@test "F-2: bridge-stub-scaffold.sh exists and is executable" {
  [ -x "${PLUGIN_ROOT}/skills/gaia-bridge-enable/scripts/bridge-stub-scaffold.sh" ]
}

@test "F-2: bridge-stub-scaffold.sh appends test_execution_bridge stub" {
  TMPDIR_F2="$TEST_TMP/f2"
  mkdir -p "$TMPDIR_F2"
  cat > "$TMPDIR_F2/cfg.yaml" <<'EOF'
project_name: "f2-test"
EOF
  bash "${PLUGIN_ROOT}/skills/gaia-bridge-enable/scripts/bridge-stub-scaffold.sh" "$TMPDIR_F2/cfg.yaml"
  grep -qF "test_execution_bridge:" "$TMPDIR_F2/cfg.yaml"
  grep -qF "bridge_enabled: false" "$TMPDIR_F2/cfg.yaml"
}

@test "F-2: bridge-stub-scaffold.sh is idempotent" {
  TMPDIR_F2I="$TEST_TMP/f2i"
  mkdir -p "$TMPDIR_F2I"
  cat > "$TMPDIR_F2I/cfg.yaml" <<'EOF'
project_name: "f2i-test"
test_execution_bridge:
  bridge_enabled: true
EOF
  bash "${PLUGIN_ROOT}/skills/gaia-bridge-enable/scripts/bridge-stub-scaffold.sh" "$TMPDIR_F2I/cfg.yaml"
  # Should not duplicate the section
  local n
  n=$(grep -c "^test_execution_bridge:" "$TMPDIR_F2I/cfg.yaml")
  [ "$n" -eq 1 ]
}

@test "F-2: bridge-enable SKILL.md references bridge-stub-scaffold.sh" {
  grep -qF "bridge-stub-scaffold.sh" "${PLUGIN_ROOT}/skills/gaia-bridge-enable/SKILL.md"
}

# --- F-3 ---

@test "F-3: create-arch setup.sh parses --bypass and --reason flags" {
  grep -qE '\-\-bypass\)' "${PLUGIN_ROOT}/skills/gaia-create-arch/scripts/setup.sh"
  grep -qE '\-\-reason\)' "${PLUGIN_ROOT}/skills/gaia-create-arch/scripts/setup.sh"
}

@test "F-3: create-arch setup.sh requires --reason when --bypass is given" {
  grep -qF "also requires --reason" "${PLUGIN_ROOT}/skills/gaia-create-arch/scripts/setup.sh"
}

@test "F-3: create-arch setup.sh records bypass via lifecycle-overrides.sh" {
  grep -qF "scripts/lib/lifecycle-overrides.sh" "${PLUGIN_ROOT}/skills/gaia-create-arch/scripts/setup.sh"
  grep -qF 'bash "$LIFECYCLE_LIB_BP" append' "${PLUGIN_ROOT}/skills/gaia-create-arch/scripts/setup.sh"
}

# --- F-4 ---

@test "F-4: create-prd finalize.sh has Review Findings auto-append block" {
  grep -qF "Review Findings auto-append" "${PLUGIN_ROOT}/skills/gaia-create-prd/scripts/finalize.sh"
  grep -qF "Adversarial review not triggered" "${PLUGIN_ROOT}/skills/gaia-create-prd/scripts/finalize.sh"
}

@test "F-4: create-prd finalize.sh checks for existing Review Findings section before appending" {
  grep -qE 'grep -qE.*Review.*Findings.*Incorporated' "${PLUGIN_ROOT}/skills/gaia-create-prd/scripts/finalize.sh"
}

# --- F-5 ---

@test "F-5: test-strategy finalize.sh writes test-plan.md alias" {
  grep -qF "TEST_PLAN_ALIAS=" "${PLUGIN_ROOT}/skills/gaia-test-strategy/scripts/finalize.sh"
  grep -qF "test-plan.md" "${PLUGIN_ROOT}/skills/gaia-test-strategy/scripts/finalize.sh"
}


# --- F-7 ---

@test "F-7: create-epics finalize.sh has em-dash normalization block" {
  grep -qF "Em-dash heading normalization" "${PLUGIN_ROOT}/skills/gaia-create-epics/scripts/finalize.sh"
  grep -qF "ASCII -- → em-dash" "${PLUGIN_ROOT}/skills/gaia-create-epics/scripts/finalize.sh"
}

@test "F-7: em-dash normalization regex matches typical patterns" {
  # End-to-end smoke
  TMPFILE_F7=$(mktemp)
  cat > "$TMPFILE_F7" <<'EOF'
## E1 -- Foo Bar
### Story E1-S1 -- A Story
text -- with double-dash in body
EOF
  python3 - "$TMPFILE_F7" <<'PY'
import sys, re
p = sys.argv[1]
c = open(p).read()
n = re.sub(r'^(##+\s+(?:E\d+|Story\s+E\d+-S\d+))\s+--\s+', r'\1 — ', c, flags=re.MULTILINE)
open(p, 'w').write(n)
PY
  grep -qF "## E1 — Foo Bar" "$TMPFILE_F7"
  grep -qF "### Story E1-S1 — A Story" "$TMPFILE_F7"
  # Body double-dash NOT changed
  grep -qF "text -- with double-dash" "$TMPFILE_F7"
  rm -f "$TMPFILE_F7"
}

# --- F-25 (AF-24-7-8-9 era — superseded by AF-2026-05-30-2 / Test10 F-31) ---
#
# AF-24-7 set the canonical location to `.gaia/state/action-items.yaml`.
# AF-2026-05-30-2 / Test10 F-31 moves it to
# `.gaia/artifacts/planning-artifacts/action-items.yaml` (the location
# `/gaia-action-items` reads from per ADR-052 §10.28.6 — closes the
# producer/consumer split where retro wrote `.gaia/state/` and the
# action-items consumer read `planning-artifacts/`). The assertions
# below are updated to match the new canonical home.

@test "gaia-retro SKILL.md uses state-tier canonical action-items path" {
  grep -qF ".gaia/state/action-items.yaml" "${PLUGIN_ROOT}/skills/gaia-retro/SKILL.md"
}

@test "gaia-triage-findings SKILL.md uses canonical planning-artifacts/action-items.yaml" {
  # Triage-findings still references action-items.yaml at the canonical
  # planning-artifacts location for new-story creation and existing-story
  # lookup paths.
  grep -qF ".gaia/artifacts/planning-artifacts/action-items.yaml" "${PLUGIN_ROOT}/skills/gaia-triage-findings/SKILL.md" || \
    grep -qF "action-items.yaml" "${PLUGIN_ROOT}/skills/gaia-triage-findings/SKILL.md"
}

@test "F-25: retro-sidecar-write.sh allowlist still accepts canonical .gaia/state/ path" {
  grep -qF '.gaia/state/action-items.yaml' "${PLUGIN_ROOT}/scripts/retro-sidecar-write.sh"
}
