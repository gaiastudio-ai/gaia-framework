#!/usr/bin/env bats
# dead-reference-scan.bats — coverage for the extended allowlist that exempts
# skill scripts/finalize.sh and scripts/setup.sh as permitted homes for
# v1-origin provenance comments.
#
# Story: E29-S6 — Extend dead-reference-scan.sh allowlist for finalize.sh
#                 provenance comments
#
# AC2 of E29-S6: positive cases (finalize.sh / setup.sh provenance comments
# allowed) and negative cases (the same content in a non-allowlisted file
# still fails).
# AC3 of E29-S6: existing SKILL.md allowlist behavior unchanged.

setup() {
  PLUGIN_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$PLUGIN_DIR/scripts/dead-reference-scan.sh"

  TMP="$(mktemp -d)"
  mkdir -p "$TMP/plugins/gaia/skills/fake-skill/scripts" \
           "$TMP/plugins/gaia/scripts" \
           "$TMP/docs"
}

teardown() {
  [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"
}

# ---------------------------------------------------------------------------
# Positive cases — skill scripts/finalize.sh and scripts/setup.sh are exempt
# ---------------------------------------------------------------------------

@test "skill scripts/finalize.sh with _gaia/...instructions.xml provenance comment is allowlisted" {
  cat > "$TMP/plugins/gaia/skills/fake-skill/scripts/finalize.sh" <<'EOF'
#!/usr/bin/env bash
# Native conversion of _gaia/lifecycle/workflows/fake/instructions.xml — see ADR-048.
echo "fake finalize"
EOF
  run "$SCRIPT" --project-root "$TMP"
  [ "$status" -eq 0 ]
}

@test "skill scripts/finalize.sh referencing checklist.md in a comment is allowlisted" {
  cat > "$TMP/plugins/gaia/skills/fake-skill/scripts/finalize.sh" <<'EOF'
#!/usr/bin/env bash
# Ports the checklist.md gates from the v1 workflow.
echo "fake finalize"
EOF
  run "$SCRIPT" --project-root "$TMP"
  [ "$status" -eq 0 ]
}

@test "skill scripts/setup.sh with _gaia/...instructions.xml provenance comment is allowlisted" {
  cat > "$TMP/plugins/gaia/skills/fake-skill/scripts/setup.sh" <<'EOF'
#!/usr/bin/env bash
# Native conversion of _gaia/lifecycle/workflows/fake/instructions.xml — see ADR-048.
echo "fake setup"
EOF
  run "$SCRIPT" --project-root "$TMP"
  [ "$status" -eq 0 ]
}

@test "skill scripts/setup.sh referencing workflow.yaml in a comment is allowlisted" {
  cat > "$TMP/plugins/gaia/skills/fake-skill/scripts/setup.sh" <<'EOF'
#!/usr/bin/env bash
# Replaces the legacy workflow.yaml driver from v1.
echo "fake setup"
EOF
  run "$SCRIPT" --project-root "$TMP"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Negative cases — same content elsewhere still fails
# ---------------------------------------------------------------------------

@test "instructions.xml in a non-allowlisted skill script (other.sh) still triggers failure" {
  cat > "$TMP/plugins/gaia/skills/fake-skill/scripts/other.sh" <<'EOF'
#!/usr/bin/env bash
# Native conversion of _gaia/lifecycle/workflows/fake/instructions.xml — see ADR-048.
echo "other"
EOF
  run "$SCRIPT" --project-root "$TMP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"instructions.xml"* ]]
}

@test "checklist.md in a top-level plugins/gaia/scripts/ file still triggers failure" {
  cat > "$TMP/plugins/gaia/scripts/random.sh" <<'EOF'
#!/usr/bin/env bash
# Refers to checklist.md from the legacy workflow.
echo "random"
EOF
  run "$SCRIPT" --project-root "$TMP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"checklist.md"* ]]
}

@test "a file named finalize.sh outside plugins/gaia/skills/<skill>/scripts/ is NOT allowlisted" {
  # finalize.sh sitting directly under plugins/gaia/scripts/ (not inside a skill's scripts/ dir)
  # must NOT be allowlisted by the new rule — the rule scopes to skills only.
  cat > "$TMP/plugins/gaia/scripts/finalize.sh" <<'EOF'
#!/usr/bin/env bash
# Mentions instructions.xml from a non-skill location — should still fail.
echo "top-level finalize"
EOF
  run "$SCRIPT" --project-root "$TMP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"instructions.xml"* ]]
}

# ---------------------------------------------------------------------------
# Regression — existing allowlist behavior unchanged (AC3)
# ---------------------------------------------------------------------------

@test "existing SKILL.md allowlist still works (gaia-memory-management)" {
  mkdir -p "$TMP/plugins/gaia/skills/gaia-memory-management"
  cat > "$TMP/plugins/gaia/skills/gaia-memory-management/SKILL.md" <<'EOF'
# Memory management
Historical note: prior version used workflow.yaml for orchestration.
EOF
  run "$SCRIPT" --project-root "$TMP"
  [ "$status" -eq 0 ]
}

@test "arbitrary skill SKILL.md (not in case allowlist) still triggers failure" {
  cat > "$TMP/plugins/gaia/skills/fake-skill/SKILL.md" <<'EOF'
# Fake skill
Load _gaia/core/engine/workflow.xml before running.
EOF
  run "$SCRIPT" --project-root "$TMP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"workflow.xml"* ]]
}

@test "clean tree (no v1 tokens) returns exit 0" {
  echo '# clean skill' > "$TMP/plugins/gaia/skills/fake-skill/SKILL.md"
  run "$SCRIPT" --project-root "$TMP"
  [ "$status" -eq 0 ]
}
