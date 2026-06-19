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

# ---------------------------------------------------------------------------
# Determinism — scan produces identical verdicts on repeated runs (AC2)
# ---------------------------------------------------------------------------

@test "scan produces identical output across two successive runs with scratch dirs present" {
  # Create a git-tracked fixture tree: a tracked file (clean) plus an
  # untracked scratch directory containing a legacy-pattern file.  Under the
  # old code, the scratch directory would be walked by grep -rEn in
  # filesystem order (non-deterministic), potentially perturbing the verdict.
  # After the fix, untracked scratch dirs inside SCAN_PATHS are excluded.

  # Initialize a git repo in the fixture so the scan can use git ls-files.
  git -C "$TMP" init --quiet
  git -C "$TMP" config user.email "test@test"
  git -C "$TMP" config user.name "test"

  # Tracked file: clean (no legacy references).
  echo '# clean skill' > "$TMP/plugins/gaia/skills/fake-skill/SKILL.md"
  git -C "$TMP" add plugins/gaia/skills/fake-skill/SKILL.md
  git -C "$TMP" commit --quiet -m "init"

  # Untracked scratch directory with a file that contains a legacy pattern.
  mkdir -p "$TMP/plugins/gaia/.scan-tmp"
  echo 'load _gaia/core/engine/workflow.xml now' \
    > "$TMP/plugins/gaia/.scan-tmp/scratch-ref.sh"
  mkdir -p "$TMP/plugins/gaia/.review"
  echo 'stale ref to workflow.xml engine' \
    > "$TMP/plugins/gaia/.review/review-notes.md"

  # Run 1
  run "$SCRIPT" --project-root "$TMP"
  local status1="$status"
  local output1="$output"

  # Run 2
  run "$SCRIPT" --project-root "$TMP"
  local status2="$status"
  local output2="$output"

  # Both runs must produce the same exit code and output.
  [ "$status1" -eq "$status2" ]
  [ "$output1" = "$output2" ]

  # The verdict should be CLEAN because the only tracked file is clean and
  # the untracked scratch files should be excluded from the scan.
  [ "$status1" -eq 0 ]
  [[ "$output1" == *"CLEAN"* ]]
}

@test "untracked scratch dirs inside scan roots do not change verdict from CLEAN to FAILED" {
  # Baseline: scan on a clean git tree produces CLEAN.
  git -C "$TMP" init --quiet
  git -C "$TMP" config user.email "test@test"
  git -C "$TMP" config user.name "test"

  echo '# nothing here' > "$TMP/plugins/gaia/skills/fake-skill/SKILL.md"
  git -C "$TMP" add plugins/gaia/skills/fake-skill/SKILL.md
  git -C "$TMP" commit --quiet -m "init"

  # Baseline run — must be CLEAN.
  run "$SCRIPT" --project-root "$TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLEAN"* ]]

  # Now add untracked scratch dirs with legacy-pattern files.
  mkdir -p "$TMP/plugins/gaia/.scan-tmp"
  echo 'load workflow.xml engine' > "$TMP/plugins/gaia/.scan-tmp/junk.sh"
  mkdir -p "$TMP/plugins/gaia/Source"
  echo 'core/protocols/old' > "$TMP/plugins/gaia/Source/leftover.txt"
  mkdir -p "$TMP/.github/workflows/.review"
  echo 'ref to instructions.xml' > "$TMP/.github/workflows/.review/tmp.yml"

  # After adding scratch dirs, verdict must still be CLEAN.
  run "$SCRIPT" --project-root "$TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLEAN"* ]]
}

@test "scan output is deterministically sorted across repeated runs" {
  # Create a fixture with multiple non-allowlisted files that all contain
  # legacy patterns.  The scan should report them in a stable sorted order.
  git -C "$TMP" init --quiet
  git -C "$TMP" config user.email "test@test"
  git -C "$TMP" config user.name "test"

  # Create several tracked files with legacy references (not allowlisted).
  mkdir -p "$TMP/plugins/gaia/scripts"
  echo 'load workflow.xml' > "$TMP/plugins/gaia/scripts/z-script.sh"
  echo 'load workflow.xml' > "$TMP/plugins/gaia/scripts/a-script.sh"
  echo 'load workflow.xml' > "$TMP/plugins/gaia/scripts/m-script.sh"
  git -C "$TMP" add .
  git -C "$TMP" commit --quiet -m "init"

  # Run the scan 5 times and collect outputs.
  local prev_output=""
  for i in 1 2 3 4 5; do
    run "$SCRIPT" --project-root "$TMP"
    [ "$status" -eq 1 ]  # FAILED expected
    if [ -n "$prev_output" ]; then
      [ "$output" = "$prev_output" ]
    fi
    prev_output="$output"
  done
}
