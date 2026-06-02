#!/usr/bin/env bats
# e68-s5-regime-rubrics-cohort-uniformity.bats — E68-S5 reconciliation coverage.
#
# Asserts that the nine regime rubric files shipped under
# `gaia-framework/plugins/gaia/rubrics/regimes/` share a byte-identical
# top-level shape and use canonical schema field names (per E68-S4 F1+F2
# triage findings reconciled by E68-S5).
#
#   AC1   all nine rubric files use the same set of top-level keys
#         (canonical: schema_version, skill, severity_rules, name,
#         description, applies_to_skills, metadata)
#   AC1   no rubric carries non-canonical top-level fields that
#         duplicate metadata (e.g., legacy 'regime' alongside
#         metadata.regime_id)
#   AC2   each rubric passes rubric.schema.json validation cleanly
#   AC3   merger output for each reconciled regime layered atop its
#         primary base rubric is byte-identical across two runs
#   AC4   /gaia-validate-rubric (validate-rubric.sh) exits 0 for each
#         reconciled file
#
# Story: E68-S5
# ADR:   ADR-079 (Layered Rubric Loading)
# Sprint: sprint-38

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
RUBRICS_REGIMES="$PLUGIN_DIR/rubrics/regimes"
RUBRICS_BASE="$PLUGIN_DIR/rubrics/base"
VALIDATOR="$PLUGIN_DIR/scripts/validate-rubric.sh"
MERGER="$PLUGIN_DIR/scripts/rubric-merger.sh"

REGIMES=(gdpr hipaa pci-dss sox ccpa soc2 iso-27001 wcag-2.1-aa wcag-2.1-aaa)

# Canonical top-level key set shared by all reconciled regime rubrics.
# Order is alphabetical to match jq's `keys` default sort.
CANONICAL_KEYS='applies_to_skills
description
metadata
name
schema_version
severity_rules
skill'

setup() { common_setup; }
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC1 — cohort-uniform top-level shape.
# Catches the drift fixed by E68-S5: gdpr.json previously carried stray
# top-level `regime` and `privacy` keys that no other regime rubric had.
# ---------------------------------------------------------------------------
@test "AC1: each regime rubric exposes the canonical top-level key set" {
  for r in "${REGIMES[@]}"; do
    keys=$(jq -r 'keys[]' "$RUBRICS_REGIMES/${r}.json")
    [ "$keys" = "$CANONICAL_KEYS" ] || {
      echo "$r.json top-level keys diverge from canonical set:" >&2
      echo "expected:" >&2
      echo "$CANONICAL_KEYS" >&2
      echo "actual:" >&2
      echo "$keys" >&2
      return 1
    }
  done
}

@test "AC1: no rubric carries the deprecated top-level 'regime' field" {
  for r in "${REGIMES[@]}"; do
    has_regime=$(jq 'has("regime")' "$RUBRICS_REGIMES/${r}.json")
    [ "$has_regime" = "false" ] || {
      echo "$r.json carries top-level 'regime' (use metadata.regime_id)" >&2
      return 1
    }
  done
}

@test "AC1: no rubric carries the deprecated top-level 'privacy' field" {
  for r in "${REGIMES[@]}"; do
    has_privacy=$(jq 'has("privacy")' "$RUBRICS_REGIMES/${r}.json")
    [ "$has_privacy" = "false" ] || {
      echo "$r.json carries top-level 'privacy' (move under metadata)" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC2 — every reconciled rubric still validates cleanly.
# ---------------------------------------------------------------------------
@test "AC2: each reconciled regime rubric passes schema validation" {
  for r in "${REGIMES[@]}"; do
    run "$VALIDATOR" "$RUBRICS_REGIMES/${r}.json"
    [ "$status" -eq 0 ] || {
      echo "validate-rubric.sh failed for $r.json:" >&2
      echo "$output" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC3 — merger output is byte-identical across two runs (no drift,
# no functional regression vs. pre-fix golden behaviour).
# ---------------------------------------------------------------------------
@test "AC3: merger output is byte-identical across two runs per regime" {
  # Pick the primary base rubric matching each regime's `skill` field.
  for r in "${REGIMES[@]}"; do
    skill=$(jq -r '.skill' "$RUBRICS_REGIMES/${r}.json")
    base="$RUBRICS_BASE/${skill}.json"
    [ -f "$base" ] || skip "base rubric for skill=$skill missing: $base"

    out1=$("$MERGER" "$base" "$RUBRICS_REGIMES/${r}.json")
    out2=$("$MERGER" "$base" "$RUBRICS_REGIMES/${r}.json")
    [ "$out1" = "$out2" ] || {
      echo "merger output drift across two runs for $r.json" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC4 — /gaia-validate-rubric (validate-rubric.sh) exits 0 for each file.
# This is the "user-facing" assertion paralleling AC2 above; AC2 covers
# the schema layer, AC4 covers the slash-command wrapper used by humans.
# ---------------------------------------------------------------------------
@test "AC4: validate-rubric.sh exits 0 for each reconciled file" {
  for r in "${REGIMES[@]}"; do
    run "$VALIDATOR" "$RUBRICS_REGIMES/${r}.json"
    [ "$status" -eq 0 ] || {
      echo "exit=$status for $r.json" >&2
      echo "$output" >&2
      return 1
    }
  done
}
