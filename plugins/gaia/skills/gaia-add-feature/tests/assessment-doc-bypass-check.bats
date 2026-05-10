#!/usr/bin/env bats
# assessment-doc-bypass-check.bats — E83-S3 anti-pattern check
#
# Scans `/gaia-add-feature` assessment-doc emissions for three Val-gate bypass
# smoking-gun strings:
#   1. "auto-judged in patch mode"                    (AF-3 pattern: skill self-licensed an undocumented patch-mode shortcut)
#   2. "inline, read-only verification"               (AF-4 pattern: skill performed Val "inline" instead of dispatching as a subagent)
#   3. /Agent.{0,2}tool subagent dispatch primitive not surfaced/  (AF-4 rationalization for the inline pattern; backtick-tolerant)
#
# Backtick-tolerance is load-bearing — three of four historical occurrences of
# string 3 are backtick variants (`Agent`-tool ...), and a literal-string grep
# would miss them. See E83-S3 Dev Notes "Why backtick-tolerance is load-bearing".
#
# Test cases (AC mapping):
#   AC #1 — TC-VFC-10 — corpus run with allowlist applied: exactly 3 violations
#   AC #2 — backtick-tolerant regex catches the four historical occurrences of string 3
#   AC #3 — TC-VFC-11 — clean fixture exits zero
#   AC #5 — output format `{file}:{line}:{matched-string}`
#   AC #6 — canary AF-2026-05-09-5.md exits zero (negative control)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../../.." && pwd)"
  SKILL_DIR="$REPO_ROOT/plugins/gaia/skills/gaia-add-feature"
  SCANNER="$SKILL_DIR/scripts/assessment-doc-bypass-check.sh"
  ALLOWLIST="$SKILL_DIR/tests/assessment-doc-bypass-allowlist.txt"
  FIXTURES_DIR="$SKILL_DIR/tests/fixtures"

  # The actual assessment-AF-*.md corpus sits at project-root, OUTSIDE the
  # in-tree gaia-public/ checkout. CI workflows that only check out
  # gaia-public/ cannot reach it; tests that depend on the live corpus must
  # be guarded by GAIA_PROJECT_ROOT_DOCS, which the developer/CI sets when
  # the project-root docs/ tree is mounted alongside the gaia-public/
  # checkout. Tests that work without it use synthetic fixtures in
  # `tests/fixtures/`.
  PROJECT_DOCS="${GAIA_PROJECT_ROOT_DOCS:-}"

  export LC_ALL=C

  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP"
}

# AC #5 — output format `{file}:{line}:{matched-string}`
@test "scanner emits {file}:{line}:{matched-string} format on a violating fixture" {
  cp "$FIXTURES_DIR/violating-string1.md" "$TMP/v1.md"
  run "$SCANNER" "$TMP/v1.md"
  [ "$status" -ne 0 ]
  # Format: file:line:matched-string (3 fields separated by ':')
  echo "$output" | grep -E "^.+:[0-9]+:auto-judged in patch mode$"
}

# Test 1 — String 1 detection
@test "scanner detects 'auto-judged in patch mode' (string 1)" {
  cp "$FIXTURES_DIR/violating-string1.md" "$TMP/v1.md"
  run "$SCANNER" "$TMP/v1.md"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F "auto-judged in patch mode"
}

# Test 2 — String 2 detection
@test "scanner detects 'inline, read-only verification' (string 2)" {
  cp "$FIXTURES_DIR/violating-string2.md" "$TMP/v2.md"
  run "$SCANNER" "$TMP/v2.md"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F "inline, read-only verification"
}

# Test 3 — String 3 detection (backtick-tolerant regex)
@test "scanner detects 'Agent-tool ... primitive not surfaced' (string 3, hyphen variant)" {
  cp "$FIXTURES_DIR/violating-string3-hyphen.md" "$TMP/v3h.md"
  run "$SCANNER" "$TMP/v3h.md"
  [ "$status" -ne 0 ]
  echo "$output" | grep -E "Agent.{0,2}tool subagent dispatch primitive not surfaced"
}

@test "scanner detects backtick-variant of string 3 (\`Agent\`-tool)" {
  cp "$FIXTURES_DIR/violating-string3-backtick.md" "$TMP/v3b.md"
  run "$SCANNER" "$TMP/v3b.md"
  [ "$status" -ne 0 ]
  # The match should fire on the backtick variant — a literal-string grep would miss it.
  echo "$output" | grep -E "Agent.{0,2}tool subagent dispatch primitive not surfaced"
}

# AC #2 — explicit verification that a literal-string grep would have missed
# the backtick variants (this is the load-bearing rationale for the regex).
@test "literal-string grep MISSES backtick variants (regression negative control)" {
  cp "$FIXTURES_DIR/violating-string3-backtick.md" "$TMP/v3b.md"
  # A naive literal-grep with the "plain text" version would fail to find the
  # backtick variant. This test asserts the naive form misses, proving the
  # regex form is necessary.
  run grep -nF "Agent-tool subagent dispatch primitive not surfaced" "$TMP/v3b.md"
  [ "$status" -ne 0 ]
}

# AC #3 — TC-VFC-11 — clean fixture (Val Findings Summary, no smoking guns)
@test "TC-VFC-11: clean fixture exits zero with no output" {
  run "$SCANNER" "$FIXTURES_DIR/clean-assessment.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# AC #6 — canary AF-2026-05-09-5.md negative control
@test "canary fixture (paraphrased bypass discussion) exits zero" {
  run "$SCANNER" "$FIXTURES_DIR/canary-paraphrased.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# AC #1 — TC-VFC-10 — corpus run with allowlist applied
# Skipped when GAIA_PROJECT_ROOT_DOCS is not set (CI plugin-ci.yml only
# checks out gaia-public/, not the project-root docs/ corpus).
@test "TC-VFC-10: corpus run with allowlist reports exactly 3 violations" {
  [ -n "$PROJECT_DOCS" ] || skip "GAIA_PROJECT_ROOT_DOCS not set; skipping live-corpus test"
  [ -d "$PROJECT_DOCS/planning-artifacts" ] || skip "project-root planning-artifacts not present"

  run "$SCANNER" --allowlist "$ALLOWLIST" "$PROJECT_DOCS/planning-artifacts/assessment-AF-"*.md
  [ "$status" -ne 0 ]

  # Count exactly 3 violation lines (one per (pattern, file, line) tuple).
  count="$(echo "$output" | grep -cE "^.+:[0-9]+:" || true)"
  [ "$count" -eq 3 ]

  # Verify each expected (file, line) tuple appears.
  echo "$output" | grep -E "assessment-AF-2026-05-09-3\.md:50:auto-judged in patch mode"
  echo "$output" | grep -E "assessment-AF-2026-05-09-4\.md:34:inline, read-only verification"
  echo "$output" | grep -E "assessment-AF-2026-05-09-4\.md:34:.*Agent.{0,2}tool subagent dispatch primitive not surfaced"
}

# TC #6b — corpus run with --no-allowlist returns the full historical baseline (10 hits).
@test "TC-VFC-10 (--no-allowlist): corpus run reports 10 historical violation tuples" {
  [ -n "$PROJECT_DOCS" ] || skip "GAIA_PROJECT_ROOT_DOCS not set; skipping live-corpus test"
  [ -d "$PROJECT_DOCS/planning-artifacts" ] || skip "project-root planning-artifacts not present"

  run "$SCANNER" --no-allowlist "$PROJECT_DOCS/planning-artifacts/assessment-AF-"*.md
  [ "$status" -ne 0 ]

  count="$(echo "$output" | grep -cE "^.+:[0-9]+:" || true)"
  [ "$count" -eq 10 ]
}

# Allowlist mechanics — files in the allowlist are skipped.
@test "scanner respects allowlist (skips listed files)" {
  cp "$FIXTURES_DIR/violating-string1.md" "$TMP/assessment-AF-skipme.md"
  cp "$FIXTURES_DIR/violating-string2.md" "$TMP/assessment-AF-scanme.md"
  printf '%s\n' "assessment-AF-skipme.md" > "$TMP/allow.txt"
  printf '%s\n' "# REASON: test fixture" >> "$TMP/allow.txt"

  run "$SCANNER" --allowlist "$TMP/allow.txt" "$TMP/assessment-AF-skipme.md" "$TMP/assessment-AF-scanme.md"
  [ "$status" -ne 0 ]
  # Skipped file MUST NOT appear in output.
  ! echo "$output" | grep -F "assessment-AF-skipme.md"
  # Non-skipped file MUST appear.
  echo "$output" | grep -F "assessment-AF-scanme.md"
}

# Allowlist file must support `# REASON:` comment lines (skipped during parsing).
@test "scanner ignores comment lines and blank lines in allowlist" {
  cp "$FIXTURES_DIR/violating-string1.md" "$TMP/assessment-AF-keep.md"
  printf '%s\n' "# top-level comment" > "$TMP/allow.txt"
  printf '%s\n' "" >> "$TMP/allow.txt"
  printf '%s\n' "# REASON: paraphrase would erase audit-trail context" >> "$TMP/allow.txt"
  printf '%s\n' "assessment-AF-keep.md" >> "$TMP/allow.txt"

  run "$SCANNER" --allowlist "$TMP/allow.txt" "$TMP/assessment-AF-keep.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# AC #4 — CI step wiring (static check)
@test "TC-VFC-12 static: plugin-ci.yml references assessment-doc-bypass-check" {
  CI_FILE="$REPO_ROOT/.github/workflows/plugin-ci.yml"
  [ -f "$CI_FILE" ]
  grep -F "assessment-doc-bypass-check" "$CI_FILE"
}

# AC #4 — CI step wiring (build-fail behavior, synthetic local check)
@test "TC-VFC-12 behavioral: scanner exits non-zero on violating doc (build-fail signal)" {
  cp "$FIXTURES_DIR/violating-string1.md" "$TMP/v.md"
  run "$SCANNER" "$TMP/v.md"
  [ "$status" -ne 0 ]
}
