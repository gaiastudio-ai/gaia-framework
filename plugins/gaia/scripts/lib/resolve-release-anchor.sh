#!/usr/bin/env bash
# resolve-release-anchor.sh — emit the commit-classification range anchor
# for release.yml.
#
# Story: E40-S2 — Anchor release.yml commit-classification range on
#                 most-recent v* tag.
# Origin: docs/creative-artifacts/meeting-2026-05-15-ci-review-section-deploy-versioning-redesign.md
# Traces to: ADR-025 (Model B version source of truth — preserved),
#            ADR-049 (v1 retirement — this story strengthens v2),
#            ADR-109 (wired-vs-implemented gate — out of scope for this
#                     helper; release.yml CI surface_type=none).
#
# Algorithm:
#   BEFORE = git describe --tags --abbrev=0 --match 'v*' 2>/dev/null
#            || git rev-list --max-parents=0 HEAD
#
# Rationale: the prior implementation used `${{ github.event.before }}`
# which is unreliable after squash-merges (collapses range to a single
# squash commit) and force-pushes (all-zeros falls back to HEAD~1, wrong
# after squash). The tag-based anchor is deterministic across all merge
# strategies.
#
# First-release fallback: when no v* tag exists, fall through to the root
# commit so the classifier sees the full history.
#
# CWD contract: release.yml runs with `gaia-public/` as the workflow CWD
# (verified by line 101: `node scripts/classify-commits.js` with no
# `gaia-public/` prefix). Invoke this helper as:
#   BEFORE=$(./plugins/gaia/scripts/lib/resolve-release-anchor.sh)
#
# Exit codes:
#   0 — anchor SHA printed to stdout
#   1 — git not available or repo not initialized

set -euo pipefail
LC_ALL=C
export LC_ALL

git describe --tags --abbrev=0 --match 'v*' 2>/dev/null \
  || git rev-list --max-parents=0 HEAD
