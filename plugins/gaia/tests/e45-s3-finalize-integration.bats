#!/usr/bin/env bats
# e45-s3-finalize-integration.bats — end-to-end finalize.sh + auto-save
#
# Story: E45-S3 (Auto-save session memory at finalize for 24 Phase 1-3 skills)
# AC1, AC3 — full Phase 1-3 finalize invocation produces session memory
# AC-EC1   — Phase 4 finalize does NOT produce auto-save memory entry
#
# Strategy:
#   - Build a temp project with a fake docs/creative-artifacts artifact.
#   - Invoke gaia-product-brief/scripts/finalize.sh from inside that dir.
#   - Confirm a decision-log.md was created in the analyst sidecar.
#   - Run gaia-dev-story finalize from the same tree, confirm no Phase 4
#     auto-save side effect.

load 'test_helper.bash'

setup() {
    common_setup
    PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SKILLS_DIR="$PLUGIN_DIR/skills"

    # Build an isolated workspace with a fake _memory tree and config.yaml.
    WORKSPACE="$TEST_TMP/workspace"
    mkdir -p "$WORKSPACE/_memory" "$WORKSPACE/docs/creative-artifacts"
    cat > "$WORKSPACE/_memory/config.yaml" <<'EOF'
agents:
  analyst:
    sidecar: analyst-sidecar
  pm:
    sidecar: pm-sidecar
EOF

    # Seed a minimal product-brief artifact so the 27-item checklist runs
    # but does not fail the script (we accept non-zero exit from the
    # checklist — observability + auto-save still must run).
    cat > "$WORKSPACE/docs/creative-artifacts/product-brief-test.md" <<'EOF'
---
title: Test Brief
---
# Test Brief

## Vision Statement

A vision.

## Target Users

- Role: persona

## Problem Statement

A problem.

## Proposed Solution

A solution.

## Key Features

- A feature.

## Scope and Boundaries

In-scope: x. Out-of-scope: y.

## Risks and Assumptions

- A risk.

## Competitive Landscape

- A competitor.

## Success Metrics

- 90% adoption.
EOF

    export MEMORY_PATH="$WORKSPACE/_memory"
    mkdir -p "$WORKSPACE/_memory/checkpoints"
    export CHECKPOINT_PATH="$WORKSPACE/_memory/checkpoints"
}

teardown() { common_teardown; }

@test "+: gaia-product-brief finalize auto-saves to analyst sidecar" {
    # Run from inside the workspace so docs/creative-artifacts is found.
    pushd "$WORKSPACE" >/dev/null
    run env MEMORY_PATH="$WORKSPACE/_memory" \
        CHECKPOINT_PATH="$WORKSPACE/_memory/checkpoints" \
        AUTO_SAVE_LATENCY_THRESHOLD=10 \
        "$SKILLS_DIR/gaia-product-brief/scripts/finalize.sh"
    local rc="$status"
    popd >/dev/null

    # Either 0 (clean) or 1 (some checklist item failed) is acceptable —
    # auto-save runs regardless per AC4 / AC-EC4.
    [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]

    # The analyst sidecar must contain a decision-log entry.
    local sidecar="$WORKSPACE/_memory/analyst-sidecar/decision-log.md"
    [ -f "$sidecar" ]
    grep -q 'gaia-product-brief Session Summary' "$sidecar"

    # No interactive prompt should have been emitted.
    printf '%s' "$output" | grep -q '\[y\]/\[n\]/\[e\]' && return 1
    return 0
}

@test "gaia-dev-story finalize does NOT write to a Phase 1-3 sidecar" {
    # Ensure the analyst sidecar is empty before we run dev-story finalize.
    rm -rf "$WORKSPACE/_memory/analyst-sidecar"

    pushd "$WORKSPACE" >/dev/null
    run env MEMORY_PATH="$WORKSPACE/_memory" \
        CHECKPOINT_PATH="$WORKSPACE/_memory/checkpoints" \
        AUTO_SAVE_LATENCY_THRESHOLD=10 \
        "$SKILLS_DIR/gaia-dev-story/scripts/finalize.sh"
    popd >/dev/null

    # We don't care about the dev-story exit code here — we only assert
    # that no Phase 1-3 sidecar was written by it.
    [ ! -f "$WORKSPACE/_memory/analyst-sidecar/decision-log.md" ]
    [ ! -f "$WORKSPACE/_memory/pm-sidecar/decision-log.md" ]
}
