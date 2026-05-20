#!/usr/bin/env bash
# setup.sh — materialize a clean .gaia/-only project fixture for AC6 regression.
#
# Story: E96-S7 — Bulk Legacy-Path Sweep
# AC6: A bats regression suite runs an integration scenario against a tmpdir
#      fixture where ONLY .gaia/ exists (no legacy docs/, _memory/, config/, or
#      custom/ siblings). The core invariants — story-key resolution, sprint-
#      state transitions, review-gate UNVERIFIED block, and Val-bridge dispatch
#      sentinel writes — MUST PASS against this fixture.
#
# Contract:
#   setup.sh <target-tmpdir>
#
# Creates the canonical .gaia/ subtree under <target-tmpdir>:
#   .gaia/config/project-config.yaml
#   .gaia/artifacts/{planning,implementation,test,creative,research}-artifacts/
#   .gaia/artifacts/implementation-artifacts/epic-E1-fixture/stories/E1-S1-fixture-story.md
#   .gaia/state/sprint-status.yaml
#   .gaia/state/action-items.yaml
#   .gaia/memory/checkpoints/
#   .gaia/custom/
#
# Explicitly does NOT create any legacy sibling (docs/, _memory/, config/,
# custom/) — that is the invariant under test.

set -euo pipefail

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  echo "usage: setup.sh <target-tmpdir>" >&2
  exit 2
fi

mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd -P)"

# Five canonical .gaia/ subdirs
mkdir -p "$TARGET/.gaia/config"
mkdir -p "$TARGET/.gaia/artifacts/planning-artifacts"
mkdir -p "$TARGET/.gaia/artifacts/implementation-artifacts/epic-E1-fixture/stories"
mkdir -p "$TARGET/.gaia/artifacts/test-artifacts"
mkdir -p "$TARGET/.gaia/artifacts/creative-artifacts"
mkdir -p "$TARGET/.gaia/artifacts/research-artifacts"
mkdir -p "$TARGET/.gaia/state"
mkdir -p "$TARGET/.gaia/memory/checkpoints"
mkdir -p "$TARGET/.gaia/custom"

# project-config.yaml — .gaia/-aligned paths
cat >"$TARGET/.gaia/config/project-config.yaml" <<'YAML'
project_root: "."
project_path: "."
artifacts_path: "./.gaia/artifacts"
planning_artifacts: "./.gaia/artifacts/planning-artifacts"
implementation_artifacts: "./.gaia/artifacts/implementation-artifacts"
test_artifacts: "./.gaia/artifacts/test-artifacts"
creative_artifacts: "./.gaia/artifacts/creative-artifacts"
research_artifacts: "./.gaia/artifacts/research-artifacts"
memory_path: "./.gaia/memory"
checkpoint_path: "./.gaia/memory/checkpoints"
custom_path: "./.gaia/custom"
state_path: "./.gaia/state"
YAML

# Fixture story — minimal frontmatter to satisfy resolve-story-file + parsers
cat >"$TARGET/.gaia/artifacts/implementation-artifacts/epic-E1-fixture/stories/E1-S1-fixture-story.md" <<'STORY'
---
template: 'story'
version: 1
used_by: ['gaia-dev-story']
key: 'E1-S1'
title: 'Fixture story for gaia-only-layout regression'
epic: 'E1'
status: 'ready-for-dev'
priority: 'medium'
size: 'S'
points: 1
risk: 'low'
origin: 'fixture'
origin_ref: 'gaia-only-layout'
date: '2026-05-20'
author: 'fixture'
depends_on: []
blocks: []
traces_to: []
sprint_id: 'sprint-fixture-1'
---

## User Story

As a fixture, I want a minimal valid story so that AC6 regression can resolve and transition it.

## Acceptance Criteria

- AC1: fixture resolves via resolve-story-file.sh
- AC2: fixture transitions via sprint-state.sh

## Review Gate

| Gate | Verdict | Timestamp | Plan-ID |
|------|---------|-----------|---------|
| Code Review | UNVERIFIED | - | - |
| QA Tests | UNVERIFIED | - | - |
| Security Review | UNVERIFIED | - | - |
| Test Automation | UNVERIFIED | - | - |
| Test Review | UNVERIFIED | - | - |
| Performance Review | UNVERIFIED | - | - |
STORY

# sprint-status.yaml — minimal active sprint with the fixture story
cat >"$TARGET/.gaia/state/sprint-status.yaml" <<'YAML'
sprint_id: "sprint-fixture-1"
velocity_capacity: 10
total_points: 1
capacity_utilization: "10%"
status: active
goals:
  - id: G1
    text: "Validate gaia-only-layout invariants"
stories:
  - key: "E1-S1"
    title: "Fixture story for gaia-only-layout regression"
    epic: "E1"
    status: "ready-for-dev"
    points: 1
    risk: "low"
YAML

# action-items.yaml — empty but well-formed
cat >"$TARGET/.gaia/state/action-items.yaml" <<'YAML'
schema_version: 1
action_items: []
YAML

echo "fixture materialized at: $TARGET" >&2
printf '%s\n' "$TARGET"
exit 0
