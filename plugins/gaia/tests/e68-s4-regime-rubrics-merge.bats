#!/usr/bin/env bats
# e68-s4-regime-rubrics-merge.bats — E68-S4 regime + base merge coverage.
#
#   AC13  regime + base merge via rubric-merger.sh produces output containing
#         both layers; later-layer keys override earlier-layer keys per
#         RFC 7396 (the merger is array-replace, so we assert the merged
#         severity_rules came from the regime when both layers define them).
#   AC12  WCAG 2.1 AAA layers on top of WCAG 2.1 AA — declaring
#         [wcag-2.1-aa, wcag-2.1-aaa] in the merger replaces AA's
#         severity_rules with AAA's (array replace).
#
# Story: E68-S4
# ADR:   ADR-079 (Layered Rubric Loading), ADR-042 (Scripts-over-LLM)

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
RUBRICS_BASE="$PLUGIN_DIR/rubrics/base"
RUBRICS_REGIMES="$PLUGIN_DIR/rubrics/regimes"
MERGER="$PLUGIN_DIR/scripts/rubric-merger.sh"

setup() { common_setup; }
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC13 — base + GDPR regime merge.
# Note: the canonical merger uses RFC 7396 array-replace semantics, so the
# merged severity_rules array equals the LAST layer's array. The merge test
# therefore asserts that (a) the merger exits 0, (b) the merged top-level
# `name` field comes from the regime layer (proving the regime applied), and
# (c) the merged severity_rules contain GDPR-prefixed ids (proving the
# regime's rules landed). This is the documented behavior per ADR-079:
# regimes specialize the base by replacing the rule list, with metadata
# layered on top.
# ---------------------------------------------------------------------------
@test "GDPR + base/code merge succeeds and produces GDPR-prefixed rules" {
  if [ ! -x "$MERGER" ]; then
    skip "depends on E68-S2 rubric-merger.sh"
  fi
  out=$("$MERGER" "$RUBRICS_BASE/code.json" "$RUBRICS_REGIMES/gdpr.json")
  [ -n "$out" ] || {
    echo "merger produced no output" >&2
    return 1
  }
  name=$(printf '%s' "$out" | jq -r '.name // empty')
  [ "$name" = "gdpr" ] || {
    echo "merged name='$name' (expected 'gdpr')" >&2
    return 1
  }
  prefixed=$(printf '%s' "$out" | jq '[.severity_rules[].id | select(startswith("gdpr-"))] | length')
  [ "$prefixed" -ge 1 ] || {
    echo "merged severity_rules contain no gdpr-prefixed ids" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# AC13 — multi-regime merge (GDPR -> HIPAA): later layer overrides on
# conflicting keys, but since GDPR and HIPAA have no overlapping rule ids,
# we assert the final severity_rules array is HIPAA's (array replace per
# RFC 7396) and the regime `name` field came from HIPAA.
# ---------------------------------------------------------------------------
@test "GDPR -> HIPAA regime merge applies HIPAA as final layer" {
  if [ ! -x "$MERGER" ]; then
    skip "depends on E68-S2 rubric-merger.sh"
  fi
  out=$("$MERGER" "$RUBRICS_BASE/code.json" "$RUBRICS_REGIMES/gdpr.json" "$RUBRICS_REGIMES/hipaa.json")
  [ -n "$out" ]
  name=$(printf '%s' "$out" | jq -r '.name // empty')
  [ "$name" = "hipaa" ] || {
    echo "merged name='$name' (expected 'hipaa')" >&2
    return 1
  }
  hipaa_count=$(printf '%s' "$out" | jq '[.severity_rules[].id | select(startswith("hipaa-"))] | length')
  [ "$hipaa_count" -ge 1 ] || {
    echo "merged severity_rules contain no hipaa-prefixed ids" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# AC12 — WCAG AA + AAA layering.
# AAA layers on AA via declaration-order merge. With array-replace semantics,
# the merged severity_rules equal AAA's. We assert AAA prefix presence.
# ---------------------------------------------------------------------------
@test "WCAG AA -> AAA layering applies AAA rules in final merge" {
  if [ ! -x "$MERGER" ]; then
    skip "depends on E68-S2 rubric-merger.sh"
  fi
  out=$("$MERGER" "$RUBRICS_BASE/a11y.json" \
                  "$RUBRICS_REGIMES/wcag-2.1-aa.json" \
                  "$RUBRICS_REGIMES/wcag-2.1-aaa.json")
  [ -n "$out" ]
  name=$(printf '%s' "$out" | jq -r '.name // empty')
  [ "$name" = "wcag-2.1-aaa" ] || {
    echo "merged name='$name' (expected 'wcag-2.1-aaa')" >&2
    return 1
  }
  aaa_count=$(printf '%s' "$out" | jq '[.severity_rules[].id | select(startswith("wcag-aaa-"))] | length')
  [ "$aaa_count" -ge 1 ] || {
    echo "merged severity_rules contain no wcag-aaa- prefixed ids" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Sanity — solo regime (no base) still produces a valid merged document.
# ---------------------------------------------------------------------------
@test "solo GDPR regime through the merger emits valid JSON" {
  if [ ! -x "$MERGER" ]; then
    skip "depends on E68-S2 rubric-merger.sh"
  fi
  out=$("$MERGER" "$RUBRICS_REGIMES/gdpr.json")
  [ -n "$out" ]
  printf '%s' "$out" | jq -e . >/dev/null
}
