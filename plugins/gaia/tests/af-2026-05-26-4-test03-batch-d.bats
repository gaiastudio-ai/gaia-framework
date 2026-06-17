#!/usr/bin/env bats
# AF-2026-05-26-4: Batch D — completions of PARTIAL AF-2026-05-24 fixes that
# the Test03 tester still hit on v1.176.2.
#
# F-1:  resolve-config.sh _artifact_default defaults to .gaia/artifacts/<subdir>
#       for greenfield + post-ADR-111 trees; falls back to docs/ ONLY when the
#       legacy dir exists AND no .gaia/ tree is present (canonical inverted
#       idiom per write-checkpoint.sh:236 / AF-2026-05-21-7).
# F-17: gaia-create-epics finalize.sh TEST_PLAN fallback includes the
#       strategy/ subdir (ADR-072 two-rung order).
# F-18: infra-design SV-08 networking allowlist includes firewall/loopback/localhost.
# F-19: infra-design SV-09 accepts `## Infrastructure as Code` heading.
# F-20: infra-design SV-10 IaC tool allowlist includes Chef/Puppet.
# F-22: gaia-retro review-extract.sh has a yq-less story-key extraction path.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

# --- F-1: greenfield-safe artifact default (inverted idiom) ---
# Test the _artifact_default branch logic directly (resolve-config requires a
# fully bootstrapped env for end-to-end; the branch is the unit of interest).

_artifact_default_probe() {
  # Mirrors resolve-config.sh _artifact_default exactly.
  local v_project_root="$1" subdir="$2"
  if [ -d "${v_project_root}/docs/${subdir}" ] && [ ! -d "${v_project_root}/.gaia" ]; then
    printf '%s' "${v_project_root}/docs/${subdir}"
  else
    printf '%s' "${v_project_root}/.gaia/artifacts/${subdir}"
  fi
}

@test "resolve-config.sh uses the inverted idiom (docs only when legacy && !.gaia)" {
  run grep -F 'docs/${subdir}" ] && [ ! -d "${v_project_root}/.gaia" ]' "$PLUGIN_ROOT/scripts/resolve-config.sh"
  [ "$status" -eq 0 ]
}

@test "greenfield (.gaia/config only, no artifacts subdir) → .gaia/artifacts" {
  local r="$BATS_TEST_TMPDIR/gf"; mkdir -p "$r/.gaia/config"
  run _artifact_default_probe "$r" implementation-artifacts
  [ "$output" = "$r/.gaia/artifacts/implementation-artifacts" ]
}

@test "legacy (docs/ exists, no .gaia/) → docs/ (back-compat)" {
  local r="$BATS_TEST_TMPDIR/lg"; mkdir -p "$r/docs/implementation-artifacts"
  run _artifact_default_probe "$r" implementation-artifacts
  [ "$output" = "$r/docs/implementation-artifacts" ]
}

@test "mixed (docs/ + stray .gaia/) → .gaia/ (no mis-route off populated docs/)" {
  local r="$BATS_TEST_TMPDIR/mix"; mkdir -p "$r/docs/implementation-artifacts" "$r/.gaia/memory"
  run _artifact_default_probe "$r" implementation-artifacts
  [ "$output" = "$r/.gaia/artifacts/implementation-artifacts" ]
}

# --- F-17: TEST_PLAN strategy/ fallback ---

@test "create-epics finalize TEST_PLAN chain includes the strategy/ subdir" {
  # finalize.sh now delegates to the shared resolver; the strategy/ rung lives there.
  run grep -F 'strategy/test-plan.md' \
    "$PLUGIN_ROOT/scripts/lib/resolve-artifact-path.sh"
  [ "$status" -eq 0 ]
}

@test "flat path is still tried before strategy/" {
  # AF-2026-05-27-8 / Test06 F-008: create-epics finalize.sh no longer carries an
  # inline TEST_PLAN precedence list — it delegates to the shared
  # scripts/lib/resolve-artifact-path.sh. The ADR-072 flat-before-strategy order
  # now lives in (and is asserted against) the resolver's test_plan candidates.
  local r="$PLUGIN_ROOT/scripts/lib/resolve-artifact-path.sh"
  [ -x "$r" ]
  # finalize.sh must route through the resolver (not an inline list).
  grep -qF 'resolve-artifact-path.sh' "$PLUGIN_ROOT/skills/gaia-create-epics/scripts/finalize.sh"
  # In the resolver's test_plan candidate list, the flat test-artifacts rung
  # precedes the strategy/ rung.
  local flat strat
  flat=$(grep -n '\${TA}/test-plan.md"' "$r" | head -1 | cut -d: -f1)
  strat=$(grep -n '\${TA}/strategy/test-plan.md"' "$r" | head -1 | cut -d: -f1)
  [ -n "$flat" ] && [ -n "$strat" ] && [ "$flat" -lt "$strat" ]
}

# --- F-18 / F-19 / F-20: infra-design SV checks ---

@test "networking regex includes firewall/loopback/localhost" {
  local f="$PLUGIN_ROOT/skills/gaia-infra-design/scripts/finalize.sh"
  grep -qF 'firewall' "$f"
  grep -qF 'loopback' "$f"
  grep -qF 'localhost' "$f"
}

@test "accepts Infrastructure as Code heading" {
  run grep -F '(IaC|Infrastructure as Code)' "$PLUGIN_ROOT/skills/gaia-infra-design/scripts/finalize.sh"
  [ "$status" -eq 0 ]
}

@test "'## Infrastructure as Code' matches the heading_present anchor" {
  run grep -Eiq "^##[[:space:]]+(IaC|Infrastructure as Code)([[:space:]]|\$|[[:punct:]])" <(echo "## Infrastructure as Code")
  [ "$status" -eq 0 ]
}

@test "IaC tool regex includes Chef and Puppet" {
  local f="$PLUGIN_ROOT/skills/gaia-infra-design/scripts/finalize.sh"
  grep -qF 'Chef' "$f"
  grep -qF 'Puppet' "$f"
}

# --- F-22: yq-less story-key extraction ---

@test "review-extract.sh has a yq-less key-extraction fallback" {
  run grep -F "grep -oE 'E[0-9]+-S[0-9]+'" "$PLUGIN_ROOT/skills/gaia-retro/scripts/review-extract.sh"
  [ "$status" -eq 0 ]
}

@test "yq-less extraction pulls keys from a sprint-status.yaml shape" {
  local yaml="$BATS_TEST_TMPDIR/sprint-status.yaml"
  cat > "$yaml" <<'YAML'
sprint_id: "sprint-1"
stories:
  - key: "E1-S1"
    status: ready-for-dev
  - key: "E101-S3"
    status: done
YAML
  run bash -c "grep -E '^[[:space:]]*-?[[:space:]]*key:' '$yaml' | grep -oE 'E[0-9]+-S[0-9]+' | tr '\n' ' '"
  [[ "$output" == *"E1-S1"* ]]
  [[ "$output" == *"E101-S3"* ]]
}
