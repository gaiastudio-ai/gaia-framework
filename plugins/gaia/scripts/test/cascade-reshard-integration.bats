#!/usr/bin/env bats
# cascade-reshard-integration.bats — coverage for E53-S244.
#
# Story: E53-S244 — Auto-invoke /gaia-shard-doc from cascade skills after
#                   monolith edits.
# Refs:  AC1, AC2, AC3, AC4, AC5, AC6, AC7, AC8.
#
# This fixture verifies the prose contract added to the cascade SKILL.md
# files (the auto-invocation step is a documented post-step in the LLM
# skill, not a runtime program), and end-to-ends the existing
# `check-monolith-shard-sync.sh` advisory check (E53-S243) against a
# synced and a desynced fixture so AC5 and AC6 land together.

bats_require_minimum_version 1.5.0

# Local-only setup — we cannot load tests/test_helper.bash because its
# resolution of SCRIPTS_DIR (BATS_TEST_DIRNAME/../scripts) does not match
# this fixture's location at plugins/gaia/scripts/test/. We replicate just
# the per-test temp-dir convention here.
setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$PLUGIN_ROOT/skills"
  PLUGIN_SCRIPTS_DIR="$PLUGIN_ROOT/scripts"
  CHECK_SCRIPT="$PLUGIN_SCRIPTS_DIR/check-monolith-shard-sync.sh"
  BOUNDARIES_DOC="$PLUGIN_SCRIPTS_DIR/adapters/BOUNDARIES.md"

  local slug
  slug="$(printf '%s' "${BATS_TEST_NAME:-unknown}" | tr -c '[:alnum:]' '_')"
  TEST_TMP="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/cascade-reshard-${slug}-$$"
  mkdir -p "$TEST_TMP"
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP" 2>/dev/null || true
  fi
}

# Cascade skills under contract — name => SKILL.md path.
_cascade_skills=(
  "gaia-add-feature"
  "gaia-edit-prd"
  "gaia-edit-arch"
  "gaia-add-stories"
  "gaia-create-story"
)

# ---------------------------------------------------------------------------
# AC1 + AC2 — every cascade skill SKILL.md has a "Re-shard touched documents"
# post-step that names /gaia-shard-doc.
# ---------------------------------------------------------------------------

@test "AC1+AC2: every cascade skill SKILL.md has a Re-shard touched documents step" {
  for skill in "${_cascade_skills[@]}"; do
    f="$SKILLS_DIR/$skill/SKILL.md"
    [ -f "$f" ] || { echo "SKILL.md missing for $skill" >&2; return 1; }
    grep -F -q "Re-shard touched documents" "$f" || {
      echo "$skill: missing 'Re-shard touched documents' post-step" >&2
      return 1
    }
    grep -F -q "/gaia-shard-doc" "$f" || {
      echo "$skill: post-step does not reference /gaia-shard-doc" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC3 — every cascade skill documents the --monolith-only flag.
# ---------------------------------------------------------------------------

@test "AC3: every cascade skill documents --monolith-only flag" {
  for skill in "${_cascade_skills[@]}"; do
    f="$SKILLS_DIR/$skill/SKILL.md"
    grep -F -q -- "--monolith-only" "$f" || {
      echo "$skill: --monolith-only flag is not documented" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC4 — gaia-shard-doc SKILL.md is unchanged in this story (no new step,
# no --monolith-only, no E53-S244 references inside).
# ---------------------------------------------------------------------------

@test "AC4: gaia-shard-doc SKILL.md is unchanged by this story" {
  f="$SKILLS_DIR/gaia-shard-doc/SKILL.md"
  ! grep -F -q "Re-shard touched documents" "$f"
  ! grep -F -q -- "--monolith-only" "$f"
  ! grep -F -q "E53-S244" "$f"
}

# ---------------------------------------------------------------------------
# AC5 — fixture: pre-step monolith-only edit triggers the existing
# check-monolith-shard-sync.sh WARNING; post-step monolith+shards in sync
# produces no WARNING. The auto-invoke is a documented post-step, but the
# WARNING/no-WARNING outcomes are the observable invariant.
# ---------------------------------------------------------------------------

@test "AC5: pre-step monolith-only edit emits WARNING; synced fixture is silent" {
  cd "$TEST_TMP"
  mkdir -p docs/planning-artifacts/prd
  # Synced fixture — monolith and shards agree.
  cat > docs/planning-artifacts/prd/prd.md <<'EOF'
---
title: "PRD"
---

# PRD

## 1. Overview

Overview body.

## 2. Goals and Non-Goals

Goals body.
EOF
  cat > docs/planning-artifacts/prd/_preamble.md <<'EOF'
---
title: "PRD"
---
EOF
  cat > docs/planning-artifacts/prd/01-overview.md <<'EOF'
## 1. Overview

Overview body.
EOF
  cat > docs/planning-artifacts/prd/02-goals-and-non-goals.md <<'EOF'
## 2. Goals and Non-Goals

Goals body.
EOF

  # Synced run — must emit no WARNING lines (advisory script always exits 0).
  run "$CHECK_SCRIPT" --root "$TEST_TMP"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -F -q "WARNING"

  # Desynced run — edit monolith only and rerun. WARNING expected.
  cat >> docs/planning-artifacts/prd/prd.md <<'EOF'

## 3. Newly Added Section

Brand new content only in monolith.
EOF
  run "$CHECK_SCRIPT" --root "$TEST_TMP"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F -q "WARNING" || {
    echo "expected WARNING after monolith-only edit; got:" >&2
    echo "$output" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# AC6 — synced post-state passes the monolith-shard-sync check (E53-S243).
# Re-uses the synced fixture from AC5 verbatim.
# ---------------------------------------------------------------------------

@test "AC6: monolith-shard-sync check passes immediately after a synced cascade-skill run" {
  cd "$TEST_TMP"
  mkdir -p docs/planning-artifacts/prd
  cat > docs/planning-artifacts/prd/prd.md <<'EOF'
---
title: "PRD"
---

# PRD

## 1. Overview

Overview body.
EOF
  cat > docs/planning-artifacts/prd/_preamble.md <<'EOF'
---
title: "PRD"
---
EOF
  cat > docs/planning-artifacts/prd/01-overview.md <<'EOF'
## 1. Overview

Overview body.
EOF
  run "$CHECK_SCRIPT" --root "$TEST_TMP"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -F -q "WARNING"
}

# ---------------------------------------------------------------------------
# AC7 — BOUNDARIES.md documents the cascade-skill to re-shard contract.
# ---------------------------------------------------------------------------

@test "AC7: BOUNDARIES.md documents the cascade-skill to re-shard contract" {
  [ -f "$BOUNDARIES_DOC" ]
  grep -F -q "cascade-skill" "$BOUNDARIES_DOC" || {
    echo "BOUNDARIES.md does not mention 'cascade-skill'" >&2
    return 1
  }
  grep -F -q "/gaia-shard-doc" "$BOUNDARIES_DOC" || {
    echo "BOUNDARIES.md does not mention '/gaia-shard-doc'" >&2
    return 1
  }
  grep -F -q "E53-S244" "$BOUNDARIES_DOC" || {
    echo "BOUNDARIES.md does not anchor the contract to E53-S244" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# AC8 — Backwards compatibility: the post-step is additive. Skills that do
# NOT yet declare it (e.g., gaia-shard-doc) keep working as before. We
# verify that no cascade SKILL.md replaced or deleted the upstream section
# headings that existed before this change.
# ---------------------------------------------------------------------------

@test "AC8: cascade skill SKILL.md preserves prior anchor sections (additive change)" {
  for skill in "${_cascade_skills[@]}"; do
    f="$SKILLS_DIR/$skill/SKILL.md"
    grep -F -q "## Steps" "$f" || {
      echo "$skill: prior '## Steps' section was removed or renamed" >&2
      return 1
    }
  done
}
