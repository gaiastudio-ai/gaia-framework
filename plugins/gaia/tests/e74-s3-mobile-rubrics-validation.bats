#!/usr/bin/env bats
# e74-s3-mobile-rubrics-validation.bats — E74-S3 mobile rubric file coverage.
#
# Asserts that the five mobile rubric files shipped under
# `gaia-framework/plugins/gaia/rubrics/base/` (mobile, mobile-code, mobile-perf,
# mobile-security, mobile-a11y) conform to `rubric.schema.json` (E68-S2) and
# meet the story-level acceptance criteria E74-S3 AC1..AC8.
#
#   AC1  Base mobile.json exists and is valid JSON / passes schema validation
#        with skill="mobile" plus the ADR-081 mobile metadata (type, platform,
#        category coverage)
#   AC2  mobile-code.json declares extends="code", platform="mobile",
#        type="sub" and carries mobile-specific code criteria
#   AC3  mobile-perf.json declares extends="perf", platform="mobile",
#        type="sub" with mobile perf criteria including binary-size budget
#   AC4  mobile-security.json declares extends="security", platform="mobile",
#        type="sub" with mobile security criteria
#   AC5  mobile-a11y.json declares extends="a11y", platform="mobile",
#        type="sub" with touch-target sizing >= 44pt iOS / >= 48dp Android
#   AC6  All five rubric files pass rubric.schema.json validation
#   AC7  rubric-merger.sh correctly merges sub-rubric atop base via RFC 7396
#        (deterministic, valid JSON output)
#   AC8  Documentation: weight normalization is captured via the merger
#        contract; weight model itself is out of scope (see Findings).
#
# Story: E74-S3
# ADR:   ADR-079 (Layered Rubric Loading), ADR-081 (Mobile-as-Platform
#        Extension), ADR-042 (Scripts-over-LLM)

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
RUBRICS_BASE="$PLUGIN_DIR/rubrics/base"
SCHEMA="$PLUGIN_DIR/schemas/rubric.schema.json"
VALIDATOR="$PLUGIN_DIR/scripts/validate-rubric.sh"
MERGER="$PLUGIN_DIR/scripts/rubric-merger.sh"

MOBILE_FILES=(mobile mobile-code mobile-perf mobile-security mobile-a11y)

setup() { common_setup; }
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC1, AC6 — all five mobile rubric files exist at canonical paths.
# ---------------------------------------------------------------------------
@test "AC1/AC6: all five mobile rubric files exist" {
  for f in "${MOBILE_FILES[@]}"; do
    [ -f "$RUBRICS_BASE/${f}.json" ] || {
      echo "missing rubric: $RUBRICS_BASE/${f}.json" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC6 — every mobile rubric validates against rubric.schema.json.
# ---------------------------------------------------------------------------
@test "AC6: each mobile rubric passes schema validation" {
  for f in "${MOBILE_FILES[@]}"; do
    run "$VALIDATOR" "$RUBRICS_BASE/${f}.json"
    [ "$status" -eq 0 ] || {
      echo "validate-rubric.sh failed for ${f}.json:" >&2
      echo "$output" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC1..AC5 — schema_version is "1.0" and skill matches the file stem.
# ---------------------------------------------------------------------------
@test "AC1..AC5: each mobile rubric declares schema_version 1.0 and matching skill" {
  for f in "${MOBILE_FILES[@]}"; do
    sv=$(jq -r '.schema_version' "$RUBRICS_BASE/${f}.json")
    skill=$(jq -r '.skill' "$RUBRICS_BASE/${f}.json")
    [ "$sv" = "1.0" ] || {
      echo "${f}.json schema_version='$sv' (expected '1.0')" >&2
      return 1
    }
    [ "$skill" = "$f" ] || {
      echo "${f}.json skill='$skill' (expected '$f')" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC1 — mobile.json declares type="base" and platform="mobile".
# ---------------------------------------------------------------------------
@test "AC1: mobile.json declares type=base and platform=mobile" {
  ty=$(jq -r '.type' "$RUBRICS_BASE/mobile.json")
  pf=$(jq -r '.platform' "$RUBRICS_BASE/mobile.json")
  [ "$ty" = "base" ] || { echo "mobile.json type='$ty' (expected 'base')" >&2; return 1; }
  [ "$pf" = "mobile" ] || { echo "mobile.json platform='$pf' (expected 'mobile')" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC2..AC5 — sub-rubrics declare extends, platform="mobile", type="sub".
# ---------------------------------------------------------------------------
@test "AC2: mobile-code.json declares extends=code, platform=mobile, type=sub" {
  ext=$(jq -r '.extends' "$RUBRICS_BASE/mobile-code.json")
  pf=$(jq -r '.platform' "$RUBRICS_BASE/mobile-code.json")
  ty=$(jq -r '.type' "$RUBRICS_BASE/mobile-code.json")
  [ "$ext" = "code" ] || { echo "mobile-code.json extends='$ext' (expected 'code')" >&2; return 1; }
  [ "$pf" = "mobile" ] || { echo "mobile-code.json platform='$pf' (expected 'mobile')" >&2; return 1; }
  [ "$ty" = "sub" ] || { echo "mobile-code.json type='$ty' (expected 'sub')" >&2; return 1; }
}

@test "AC3: mobile-perf.json declares extends=perf, platform=mobile, type=sub" {
  ext=$(jq -r '.extends' "$RUBRICS_BASE/mobile-perf.json")
  pf=$(jq -r '.platform' "$RUBRICS_BASE/mobile-perf.json")
  ty=$(jq -r '.type' "$RUBRICS_BASE/mobile-perf.json")
  [ "$ext" = "perf" ] || { echo "mobile-perf.json extends='$ext' (expected 'perf')" >&2; return 1; }
  [ "$pf" = "mobile" ] || { echo "mobile-perf.json platform='$pf' (expected 'mobile')" >&2; return 1; }
  [ "$ty" = "sub" ] || { echo "mobile-perf.json type='$ty' (expected 'sub')" >&2; return 1; }
}

@test "AC4: mobile-security.json declares extends=security, platform=mobile, type=sub" {
  ext=$(jq -r '.extends' "$RUBRICS_BASE/mobile-security.json")
  pf=$(jq -r '.platform' "$RUBRICS_BASE/mobile-security.json")
  ty=$(jq -r '.type' "$RUBRICS_BASE/mobile-security.json")
  [ "$ext" = "security" ] || { echo "mobile-security.json extends='$ext' (expected 'security')" >&2; return 1; }
  [ "$pf" = "mobile" ] || { echo "mobile-security.json platform='$pf' (expected 'mobile')" >&2; return 1; }
  [ "$ty" = "sub" ] || { echo "mobile-security.json type='$ty' (expected 'sub')" >&2; return 1; }
}

@test "AC5: mobile-a11y.json declares extends=a11y, platform=mobile, type=sub" {
  ext=$(jq -r '.extends' "$RUBRICS_BASE/mobile-a11y.json")
  pf=$(jq -r '.platform' "$RUBRICS_BASE/mobile-a11y.json")
  ty=$(jq -r '.type' "$RUBRICS_BASE/mobile-a11y.json")
  [ "$ext" = "a11y" ] || { echo "mobile-a11y.json extends='$ext' (expected 'a11y')" >&2; return 1; }
  [ "$pf" = "mobile" ] || { echo "mobile-a11y.json platform='$pf' (expected 'mobile')" >&2; return 1; }
  [ "$ty" = "sub" ] || { echo "mobile-a11y.json type='$ty' (expected 'sub')" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC1..AC5 — each rubric contains >= 5 severity rules with required fields.
# ---------------------------------------------------------------------------
@test "AC1..AC5: each mobile rubric has at least five severity rules" {
  for f in "${MOBILE_FILES[@]}"; do
    n=$(jq '.severity_rules | length' "$RUBRICS_BASE/${f}.json")
    [ "$n" -ge 5 ] || {
      echo "${f}.json has $n rules (expected >= 5)" >&2
      return 1
    }
  done
}

@test "AC1..AC5: every rule has required fields with correct types" {
  for f in "${MOBILE_FILES[@]}"; do
    bad=$(jq '[.severity_rules[]
              | select(
                  (has("id")          | not) or (.id          | type != "string") or (.id          | length == 0) or
                  (has("category")    | not) or (.category    | type != "string") or (.category    | length == 0) or
                  (has("pattern")     | not) or (.pattern     | type != "string") or (.pattern     | length < 4)  or
                  (has("severity")    | not) or ([.severity] | inside(["Critical","High","Medium","Low","Info"] | [.[]]) | not) or
                  (has("description") | not) or (.description | type != "string") or (.description | length == 0)
                )
              ] | length' "$RUBRICS_BASE/${f}.json")
    [ "$bad" -eq 0 ] || {
      echo "${f}.json has $bad rule(s) with missing/invalid required fields" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC2 — mobile-code categories cover memory/lifecycle/platform-api/threading.
# ---------------------------------------------------------------------------
@test "AC2: mobile-code.json covers memory/lifecycle/platform-api/threading" {
  required=(memory-management lifecycle-handling platform-api-usage threading-concurrency)
  cats=$(jq -r '.severity_rules[].category' "$RUBRICS_BASE/mobile-code.json" | sort -u)
  for c in "${required[@]}"; do
    grep -Fxq "$c" <<<"$cats" || {
      echo "mobile-code.json missing required category: $c" >&2
      echo "categories present:" >&2
      echo "$cats" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC3 — mobile-perf categories cover startup/frame-rate/battery/binary-size/
#       network-efficiency. Binary-size budget thresholds documented.
# ---------------------------------------------------------------------------
@test "AC3: mobile-perf.json covers startup/frame-rate/battery/binary-size/network" {
  required=(startup-time frame-rate battery binary-size network-efficiency)
  cats=$(jq -r '.severity_rules[].category' "$RUBRICS_BASE/mobile-perf.json" | sort -u)
  for c in "${required[@]}"; do
    grep -Fxq "$c" <<<"$cats" || {
      echo "mobile-perf.json missing required category: $c" >&2
      return 1
    }
  done
}

@test "AC3: mobile-perf.json documents APK <50MB and IPA <100MB binary-size budgets" {
  rules=$(jq -r '[.severity_rules[] | select(.category == "binary-size")] | .[] | .pattern + " " + .description + " " + (.remediation // "")' "$RUBRICS_BASE/mobile-perf.json")
  grep -F "50" <<<"$rules" >/dev/null || { echo "binary-size rule(s) missing 50 MB threshold" >&2; echo "$rules" >&2; return 1; }
  grep -F "100" <<<"$rules" >/dev/null || { echo "binary-size rule(s) missing 100 MB threshold" >&2; echo "$rules" >&2; return 1; }
  grep -Fi "APK" <<<"$rules" >/dev/null || { echo "binary-size rule(s) missing APK reference" >&2; echo "$rules" >&2; return 1; }
  grep -Fi "IPA" <<<"$rules" >/dev/null || { echo "binary-size rule(s) missing IPA reference" >&2; echo "$rules" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC4 — mobile-security categories cover certificate-pinning, secure-storage,
#       root-detection, code-obfuscation, local-encryption, ipc-security.
# ---------------------------------------------------------------------------
@test "AC4: mobile-security.json covers cert-pinning/secure-storage/root-detection/obfuscation/encryption/ipc" {
  required=(certificate-pinning secure-storage root-detection code-obfuscation local-encryption ipc-security)
  cats=$(jq -r '.severity_rules[].category' "$RUBRICS_BASE/mobile-security.json" | sort -u)
  for c in "${required[@]}"; do
    grep -Fxq "$c" <<<"$cats" || {
      echo "mobile-security.json missing required category: $c" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC5 — mobile-a11y categories cover voiceover-talkback / dynamic-type /
#       touch-targets / reduced-motion / haptic-feedback. Touch-target
#       thresholds 44pt iOS / 48dp Android documented.
# ---------------------------------------------------------------------------
@test "AC5: mobile-a11y.json covers voiceover-talkback/dynamic-type/touch-targets/reduced-motion/haptic" {
  required=(voiceover-talkback dynamic-type touch-targets reduced-motion haptic-feedback)
  cats=$(jq -r '.severity_rules[].category' "$RUBRICS_BASE/mobile-a11y.json" | sort -u)
  for c in "${required[@]}"; do
    grep -Fxq "$c" <<<"$cats" || {
      echo "mobile-a11y.json missing required category: $c" >&2
      return 1
    }
  done
}

@test "AC5: mobile-a11y.json documents 44pt iOS / 48dp Android touch-target threshold" {
  rules=$(jq -r '[.severity_rules[] | select(.category == "touch-targets")] | .[] | .pattern + " " + .description + " " + (.remediation // "")' "$RUBRICS_BASE/mobile-a11y.json")
  grep -F "44" <<<"$rules" >/dev/null || { echo "touch-targets rule(s) missing 44pt threshold" >&2; echo "$rules" >&2; return 1; }
  grep -F "48" <<<"$rules" >/dev/null || { echo "touch-targets rule(s) missing 48dp threshold" >&2; echo "$rules" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Rule-id convention and uniqueness across the five mobile rubrics.
# ---------------------------------------------------------------------------
@test "rule IDs follow {skill}-{category}-{NNN} convention" {
  for f in "${MOBILE_FILES[@]}"; do
    bad=$(jq -r --arg s "$f" \
          '[.severity_rules[].id
            | select(test("^" + $s + "-[a-z][a-z0-9-]*-[0-9]{3}$") | not)
           ] | .[]' "$RUBRICS_BASE/${f}.json")
    [ -z "$bad" ] || {
      echo "${f}.json has rule ids that do not match {skill}-{category}-{NNN}:" >&2
      echo "$bad" >&2
      return 1
    }
  done
}

@test "no rule-id collisions across the five mobile rubrics" {
  ids_file="$TEST_TMP/all-mobile-ids.txt"
  : > "$ids_file"
  for f in "${MOBILE_FILES[@]}"; do
    jq -r '.severity_rules[].id' "$RUBRICS_BASE/${f}.json" >> "$ids_file"
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
# AC7 — rubric-merger.sh successfully merges code.json + mobile-code.json
# producing valid JSON. RFC 7396 array-replace semantics mean the sub-rubric's
# severity_rules array REPLACES the base's (per the merger contract); the
# merged metadata picks up the sub-rubric overrides for skill/extends/etc.
# ---------------------------------------------------------------------------
@test "AC7: rubric-merger.sh merges code.json + mobile-code.json successfully" {
  if [ ! -x "$MERGER" ]; then
    skip "depends on E68-S2 rubric-merger.sh"
  fi
  run "$MERGER" "$RUBRICS_BASE/code.json" "$RUBRICS_BASE/mobile-code.json"
  [ "$status" -eq 0 ] || {
    echo "merger failed:" >&2
    echo "$output" >&2
    return 1
  }
  # Output must be valid JSON.
  echo "$output" | jq -e . >/dev/null || {
    echo "merger output is not valid JSON" >&2
    return 1
  }
  # Merged result carries the sub-rubric's skill identity.
  merged_skill=$(echo "$output" | jq -r '.skill')
  [ "$merged_skill" = "mobile-code" ] || {
    echo "merged skill='$merged_skill' (expected 'mobile-code')" >&2
    return 1
  }
}

@test "AC7: rubric-merger.sh produces deterministic byte-identical output" {
  if [ ! -x "$MERGER" ]; then
    skip "depends on E68-S2 rubric-merger.sh"
  fi
  out1=$("$MERGER" "$RUBRICS_BASE/code.json" "$RUBRICS_BASE/mobile-code.json")
  out2=$("$MERGER" "$RUBRICS_BASE/code.json" "$RUBRICS_BASE/mobile-code.json")
  [ "$out1" = "$out2" ] || {
    echo "merger output is not deterministic" >&2
    diff <(echo "$out1") <(echo "$out2") >&2 || true
    return 1
  }
}
