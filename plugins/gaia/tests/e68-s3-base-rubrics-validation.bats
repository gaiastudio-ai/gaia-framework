#!/usr/bin/env bats
# e68-s3-base-rubrics-validation.bats — E68-S3 base rubric file coverage.
#
# Asserts that the six base rubric files shipped under
# `gaia-public/plugins/gaia/rubrics/base/` (code, qa, test, security, perf,
# a11y) conform to `rubric.schema.json` (delivered by E68-S2) and meet the
# story-level acceptance criteria:
#
#   AC1  six files exist at canonical paths
#   AC2  each file passes JSON-schema validation (validate-rubric.sh)
#   AC3  each file declares schema_version "1.0" and a skill matching its stem
#   AC4  each file has >= 5 severity rules with required fields
#   AC5  code.json covers solid-violations / complexity / naming-conventions /
#        error-handling / code-duplication
#   AC6  security.json covers injection / authentication (Critical) / sensitive-
#        data-exposure / access-control / security-misconfiguration
#   AC7  perf.json covers n-plus-one-queries / bundle-size / caching /
#        algorithmic-complexity / memory-management
#   AC8  a11y.json covers keyboard-navigation (Critical) / color-contrast
#        (Critical) / semantic-html / aria-usage / screen-reader-support
#   AC9  qa.json covers assertion-quality / test-isolation / test-coverage /
#        flaky-test-patterns / test-naming
#   AC10 test.json covers test-structure / mock-usage / fixture-management /
#        test-data / integration-test-isolation
#   AC11 no rule-id collisions across the six files; IDs match
#        ^{skill}-[a-z-]+-[0-9]{3}$
#   AC12 base-only loading via rubric-loader.sh produces the base rubric
#        byte-for-byte (identity merge)
#
# Story: E68-S3
# ADR:   ADR-079 (Layered Rubric Loading), ADR-042 (Scripts-over-LLM)

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
RUBRICS_BASE="$PLUGIN_DIR/rubrics/base"
SCHEMA="$PLUGIN_DIR/schemas/rubric.schema.json"
VALIDATOR="$PLUGIN_DIR/scripts/validate-rubric.sh"
LOADER="$PLUGIN_DIR/scripts/rubric-loader.sh"
MERGER="$PLUGIN_DIR/scripts/rubric-merger.sh"

SKILLS=(code qa test security perf a11y)

setup() { common_setup; }
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC1 — six base rubric files exist at canonical paths.
# ---------------------------------------------------------------------------
@test "AC1: all six base rubric files exist" {
  for s in "${SKILLS[@]}"; do
    [ -f "$RUBRICS_BASE/${s}.json" ] || {
      echo "missing rubric: $RUBRICS_BASE/${s}.json" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC2 — every base rubric validates against rubric.schema.json.
# ---------------------------------------------------------------------------
@test "AC2: each base rubric passes schema validation" {
  for s in "${SKILLS[@]}"; do
    run "$VALIDATOR" "$RUBRICS_BASE/${s}.json"
    [ "$status" -eq 0 ] || {
      echo "validate-rubric.sh failed for $s.json:" >&2
      echo "$output" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC3 — each rubric declares schema_version "1.0" and skill matching its stem.
# ---------------------------------------------------------------------------
@test "AC3: each rubric declares schema_version 1.0 and matching skill" {
  for s in "${SKILLS[@]}"; do
    sv=$(jq -r '.schema_version' "$RUBRICS_BASE/${s}.json")
    skill=$(jq -r '.skill' "$RUBRICS_BASE/${s}.json")
    [ "$sv" = "1.0" ] || {
      echo "$s.json schema_version='$sv' (expected '1.0')" >&2
      return 1
    }
    [ "$skill" = "$s" ] || {
      echo "$s.json skill='$skill' (expected '$s')" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC4 — each rubric contains >= 5 severity rules with required fields.
# ---------------------------------------------------------------------------
@test "AC4: each rubric has at least five severity rules" {
  for s in "${SKILLS[@]}"; do
    n=$(jq '.severity_rules | length' "$RUBRICS_BASE/${s}.json")
    [ "$n" -ge 5 ] || {
      echo "$s.json has $n rules (expected >= 5)" >&2
      return 1
    }
  done
}

@test "AC4: every rule has required fields with correct types" {
  for s in "${SKILLS[@]}"; do
    bad=$(jq '[.severity_rules[]
              | select(
                  (has("id")          | not) or (.id          | type != "string") or (.id          | length == 0) or
                  (has("category")    | not) or (.category    | type != "string") or (.category    | length == 0) or
                  (has("pattern")     | not) or (.pattern     | type != "string") or (.pattern     | length < 4)  or
                  (has("severity")    | not) or ([.severity] | inside(["Critical","High","Medium","Low","Info"] | [.[]]) | not) or
                  (has("description") | not) or (.description | type != "string") or (.description | length == 0)
                )
              ] | length' "$RUBRICS_BASE/${s}.json")
    [ "$bad" -eq 0 ] || {
      echo "$s.json has $bad rule(s) with missing/invalid required fields" >&2
      jq '.severity_rules[]
          | select(
              (has("id")          | not) or (.id          | type != "string") or (.id          | length == 0) or
              (has("category")    | not) or (.category    | type != "string") or (.category    | length == 0) or
              (has("pattern")     | not) or (.pattern     | type != "string") or (.pattern     | length < 4)  or
              (has("description") | not) or (.description | type != "string") or (.description | length == 0)
            )' "$RUBRICS_BASE/${s}.json" >&2 || true
      return 1
    }
  done
}

@test "AC4: every rule pattern is >= 4 characters" {
  for s in "${SKILLS[@]}"; do
    bad=$(jq '[.severity_rules[].pattern | select(length < 4)] | length' "$RUBRICS_BASE/${s}.json")
    [ "$bad" -eq 0 ] || {
      echo "$s.json has $bad pattern(s) shorter than 4 chars (T-RSV2-6)" >&2
      return 1
    }
  done
}

@test "AC4: severity values match the schema enum" {
  for s in "${SKILLS[@]}"; do
    bad=$(jq '[.severity_rules[].severity
              | select(. != "Critical" and . != "High" and . != "Medium" and . != "Low" and . != "Info")
              ] | length' "$RUBRICS_BASE/${s}.json")
    [ "$bad" -eq 0 ] || {
      echo "$s.json has $bad rule(s) with severity outside the enum" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC5 — code.json covers required categories.
# ---------------------------------------------------------------------------
@test "AC5: code.json covers solid/complexity/naming/error-handling/duplication" {
  required=(solid-violations complexity naming-conventions error-handling code-duplication)
  cats=$(jq -r '.severity_rules[].category' "$RUBRICS_BASE/code.json" | sort -u)
  for c in "${required[@]}"; do
    grep -Fxq "$c" <<<"$cats" || {
      echo "code.json missing required category: $c" >&2
      echo "categories present:" >&2
      echo "$cats" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC6 — security.json covers OWASP categories with Critical severities.
# ---------------------------------------------------------------------------
@test "AC6: security.json covers OWASP Top 10 categories" {
  required=(injection authentication sensitive-data-exposure access-control security-misconfiguration)
  cats=$(jq -r '.severity_rules[].category' "$RUBRICS_BASE/security.json" | sort -u)
  for c in "${required[@]}"; do
    grep -Fxq "$c" <<<"$cats" || {
      echo "security.json missing required category: $c" >&2
      return 1
    }
  done
}

@test "AC6: security.json marks injection and authentication Critical" {
  for cat in injection authentication; do
    n=$(jq --arg c "$cat" \
        '[.severity_rules[] | select(.category == $c and .severity == "Critical")] | length' \
        "$RUBRICS_BASE/security.json")
    [ "$n" -ge 1 ] || {
      echo "security.json: no Critical-severity rule for category '$cat'" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC7 — perf.json covers required categories.
# ---------------------------------------------------------------------------
@test "AC7: perf.json covers n+1/bundle/caching/complexity/memory" {
  required=(n-plus-one-queries bundle-size caching algorithmic-complexity memory-management)
  cats=$(jq -r '.severity_rules[].category' "$RUBRICS_BASE/perf.json" | sort -u)
  for c in "${required[@]}"; do
    grep -Fxq "$c" <<<"$cats" || {
      echo "perf.json missing required category: $c" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC8 — a11y.json covers WCAG categories with Critical Level-A severities.
# ---------------------------------------------------------------------------
@test "AC8: a11y.json covers WCAG 2.1 A/AA categories" {
  required=(semantic-html aria-usage keyboard-navigation color-contrast screen-reader-support)
  cats=$(jq -r '.severity_rules[].category' "$RUBRICS_BASE/a11y.json" | sort -u)
  for c in "${required[@]}"; do
    grep -Fxq "$c" <<<"$cats" || {
      echo "a11y.json missing required category: $c" >&2
      return 1
    }
  done
}

@test "AC8: a11y.json marks keyboard-navigation and color-contrast Critical" {
  for cat in keyboard-navigation color-contrast; do
    n=$(jq --arg c "$cat" \
        '[.severity_rules[] | select(.category == $c and .severity == "Critical")] | length' \
        "$RUBRICS_BASE/a11y.json")
    [ "$n" -ge 1 ] || {
      echo "a11y.json: no Critical-severity rule for category '$cat'" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC9 — qa.json covers test-quality categories.
# ---------------------------------------------------------------------------
@test "AC9: qa.json covers assertion/isolation/coverage/flakiness/naming" {
  required=(assertion-quality test-isolation test-coverage flaky-test-patterns test-naming)
  cats=$(jq -r '.severity_rules[].category' "$RUBRICS_BASE/qa.json" | sort -u)
  for c in "${required[@]}"; do
    grep -Fxq "$c" <<<"$cats" || {
      echo "qa.json missing required category: $c" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC10 — test.json covers test-framework categories.
# ---------------------------------------------------------------------------
@test "AC10: test.json covers structure/mocks/fixtures/data/integration" {
  required=(test-structure mock-usage fixture-management test-data integration-test-isolation)
  cats=$(jq -r '.severity_rules[].category' "$RUBRICS_BASE/test.json" | sort -u)
  for c in "${required[@]}"; do
    grep -Fxq "$c" <<<"$cats" || {
      echo "test.json missing required category: $c" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC11 — globally-unique rule IDs that follow the {skill}-{category}-{NNN}
# convention.
# ---------------------------------------------------------------------------
@test "AC11: rule IDs follow {skill}-{category}-{NNN} convention" {
  for s in "${SKILLS[@]}"; do
    bad=$(jq -r --arg s "$s" \
          '[.severity_rules[].id
            | select(test("^" + $s + "-[a-z][a-z0-9-]*-[0-9]{3}$") | not)
           ] | .[]' "$RUBRICS_BASE/${s}.json")
    [ -z "$bad" ] || {
      echo "$s.json has rule ids that do not match {skill}-{category}-{NNN}:" >&2
      echo "$bad" >&2
      return 1
    }
  done
}

@test "AC11: no rule-id collisions across the six base rubrics" {
  ids_file="$TEST_TMP/all-ids.txt"
  : > "$ids_file"
  for s in "${SKILLS[@]}"; do
    jq -r '.severity_rules[].id' "$RUBRICS_BASE/${s}.json" >> "$ids_file"
  done
  total=$(wc -l < "$ids_file")
  unique=$(sort -u "$ids_file" | wc -l)
  [ "$total" -eq "$unique" ] || {
    echo "rule-id collisions detected: total=$total unique=$unique" >&2
    sort "$ids_file" | uniq -d >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# AC12 — base-only loading via rubric-loader.sh produces identity-merge
# output: when no regimes / domain / project layer is supplied, the merged
# JSON equals jq --sort-keys on the base file (the merger normalises through
# --sort-keys per NFR-RSV2-10).
# ---------------------------------------------------------------------------
@test "AC12: base-only rubric loader produces identity-merge output" {
  if [ ! -x "$LOADER" ] || [ ! -x "$MERGER" ]; then
    skip "depends on E68-S2 rubric-loader.sh / rubric-merger.sh"
  fi
  for s in "${SKILLS[@]}"; do
    expected=$(jq --sort-keys . "$RUBRICS_BASE/${s}.json")
    actual=$("$LOADER" --skill "$s" \
                       --rubrics-root "$PLUGIN_DIR/rubrics" \
                       --regimes "" \
                       --no-domain \
                       --no-project) || {
      echo "rubric-loader.sh failed for skill=$s" >&2
      return 1
    }
    [ "$actual" = "$expected" ] || {
      echo "identity-merge mismatch for $s.json" >&2
      diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
      return 1
    }
  done
}
