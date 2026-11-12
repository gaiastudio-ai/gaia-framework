#!/usr/bin/env bats
# lint-pack.bats — tests for the deterministic lint pack (scripts/lint-pack.sh).
# Each rule has a must-fire fixture and a must-not-fire fixture.
# Fixtures for the leaked-identifier and credential rules are assembled at
# runtime from pieces, so no internal identifiers or token-shaped literals
# appear in the committed test file.

load 'test_helper.bash'

setup() {
  export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
  SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/lint-pack.sh"
  WORKDIR="$BATS_TEST_TMPDIR/workdir"
  mkdir -p "$WORKDIR"
  REPORT="$BATS_TEST_TMPDIR/report.json"
}

teardown() {
  rm -rf "$BATS_TEST_TMPDIR"
}

# ---- Helper: build leaked-identifier config fixture -------------------------

_write_leak_config() {
  local cfg="$1"
  # Pattern assembled from pieces to avoid self-flagging
  local prefix="FR"
  local sep="-"
  local suffix='[0-9]+'
  cat > "$cfg" <<YAML
lint_pack:
  leaked_identifiers:
    patterns:
      - "${prefix}${sep}${suffix}"
      - "E[0-9]+${sep}S[0-9]+"
    published_paths:
      - "pub/"
YAML
}

# ---- Helper: build credential fixture at runtime ---------------------------

_write_credential_file() {
  local dest="$1"
  # Assemble a token-shaped literal from pieces
  local part1="AKIA"
  local part2="IOSFODNN7EXAMPLE"
  printf 'api_key = "%s%s"\n' "$part1" "$part2" > "$dest"
}

# ============================================================================
# Cross-stack rule: leaked-identifiers
# ============================================================================

@test "leaked-identifiers: fires on internal identifier in published file" {
  mkdir -p "$WORKDIR/pub"
  # Assemble the identifier from pieces at runtime
  local prefix="FR"
  local sep="-"
  local num="927"
  printf 'This references %s%s%s which is internal.\n' "$prefix" "$sep" "$num" > "$WORKDIR/pub/SKILL.md"

  local cfg="$BATS_TEST_TMPDIR/lint-pack.yaml"
  _write_leak_config "$cfg"

  run bash "$SCRIPT" --files "pub/SKILL.md" --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  # Verify the finding appears in the JSON report
  jq -e '.findings | length > 0' "$REPORT"
  jq -e '.findings[0].rule == "leaked-identifiers"' "$REPORT"
  jq -e '.findings[0].file == "pub/SKILL.md"' "$REPORT"
  jq -e '.findings[0].line == 1' "$REPORT"
}

@test "leaked-identifiers: does not fire on non-published file" {
  mkdir -p "$WORKDIR/internal"
  local prefix="FR"
  local sep="-"
  local num="927"
  printf 'This references %s%s%s which is internal.\n' "$prefix" "$sep" "$num" > "$WORKDIR/internal/doc.md"

  local cfg="$BATS_TEST_TMPDIR/lint-pack.yaml"
  _write_leak_config "$cfg"

  run bash "$SCRIPT" --files "internal/doc.md" --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
}

@test "leaked-identifiers: carve-out for grep -E pattern argument" {
  mkdir -p "$WORKDIR/pub"
  local cfg="$BATS_TEST_TMPDIR/lint-pack.yaml"
  _write_leak_config "$cfg"

  # Identifier in the pattern argument of grep -E — should be carved out.
  local prefix="FR"
  local sep="-"
  local num="42"
  printf 'grep -E "%s%s%s" file.txt\n' "$prefix" "$sep" "$num" > "$WORKDIR/pub/script.sh"

  run bash "$SCRIPT" --files "pub/script.sh" --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
}

@test "leaked-identifiers: carve-out does NOT skip prose mentioning sed" {
  mkdir -p "$WORKDIR/pub"
  local cfg="$BATS_TEST_TMPDIR/lint-pack.yaml"
  _write_leak_config "$cfg"

  # Identifier in prose that happens to mention "sed" — NOT a regex context
  local prefix="FR"
  local sep="-"
  local num="123"
  printf 'echo "see %s%s%s; then use sed to fix"\n' "$prefix" "$sep" "$num" > "$WORKDIR/pub/a.md"

  run bash "$SCRIPT" --files "pub/a.md" --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length > 0' "$REPORT"
  jq -e '.findings[0].rule == "leaked-identifiers"' "$REPORT"
}

@test "leaked-identifiers: carve-out does NOT skip prose mentioning awk" {
  mkdir -p "$WORKDIR/pub"
  local cfg="$BATS_TEST_TMPDIR/lint-pack.yaml"
  _write_leak_config "$cfg"

  local prefix="FR"
  local sep="-"
  local num="456"
  printf 'Run awk later. %s%s%s ships to users.\n' "$prefix" "$sep" "$num" > "$WORKDIR/pub/b.md"

  run bash "$SCRIPT" --files "pub/b.md" --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length > 0' "$REPORT"
}

@test "leaked-identifiers: carve-out does NOT skip grep -E inside echo" {
  mkdir -p "$WORKDIR/pub"
  local cfg="$BATS_TEST_TMPDIR/lint-pack.yaml"
  _write_leak_config "$cfg"

  local prefix="FR"
  local sep="-"
  local num="789"
  printf 'echo "grep -E is used for %s%s%s"\n' "$prefix" "$sep" "$num" > "$WORKDIR/pub/c.md"

  run bash "$SCRIPT" --files "pub/c.md" --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length > 0' "$REPORT"
}

@test "leaked-identifiers: carve-out does NOT skip pattern= when ID is not in RHS" {
  mkdir -p "$WORKDIR/pub"
  local cfg="$BATS_TEST_TMPDIR/lint-pack.yaml"
  _write_leak_config "$cfg"

  local prefix="FR"
  local sep="-"
  local num="321"
  printf 'The pattern=foo option, %s%s%s\n' "$prefix" "$sep" "$num" > "$WORKDIR/pub/d.md"

  run bash "$SCRIPT" --files "pub/d.md" --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length > 0' "$REPORT"
}

@test "leaked-identifiers: skipped when not configured" {
  mkdir -p "$WORKDIR/pub"
  local prefix="FR"
  local sep="-"
  local num="100"
  printf '%s%s%s in published file\n' "$prefix" "$sep" "$num" > "$WORKDIR/pub/doc.md"

  # No --config: leaked-identifiers should be skipped
  run bash "$SCRIPT" --files "pub/doc.md" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.skipped_rules | index("leaked-identifiers")' "$REPORT"
}

@test "leaked-identifiers: config with bracket-containing pattern parses correctly" {
  mkdir -p "$WORKDIR/pub"
  # Pattern that contains ] and , (the reason we use yq, not inline splitting)
  local cfg="$BATS_TEST_TMPDIR/lint-pack.yaml"
  cat > "$cfg" <<'YAML'
lint_pack:
  leaked_identifiers:
    patterns:
      - "TC-[A-Z]+-[A-Z]+-[0-9]+"
    published_paths:
      - "pub/"
YAML
  # Assemble match from pieces
  local p1="TC"
  local p2="-RSH-LINT-"
  local p3="1"
  printf 'This has %s%s%s in it.\n' "$p1" "$p2" "$p3" > "$WORKDIR/pub/doc.md"

  run bash "$SCRIPT" --files "pub/doc.md" --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length > 0' "$REPORT"
  jq -e '.findings[0].rule == "leaked-identifiers"' "$REPORT"
}

@test "leaked-identifiers: backslash patterns work after yq -r parsing" {
  mkdir -p "$WORKDIR/pub"
  local cfg="$BATS_TEST_TMPDIR/lint-pack.yaml"
  # Pattern with word boundaries — requires yq -r (not JSON-quoted)
  cat > "$cfg" <<'YAML'
lint_pack:
  leaked_identifiers:
    patterns:
      - '\bFOO-[0-9]+\b'
    published_paths:
      - "pub/"
YAML
  printf 'x FOO-42 y\n' > "$WORKDIR/pub/doc.md"

  run bash "$SCRIPT" --files "pub/doc.md" --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length > 0' "$REPORT"
}

@test "leaked-identifiers: carve-out for awk quoted program" {
  mkdir -p "$WORKDIR/pub"
  local cfg="$BATS_TEST_TMPDIR/lint-pack.yaml"
  _write_leak_config "$cfg"

  local prefix="FR"
  local sep="-"
  local num="99"
  printf 'awk "/%s%s%s/ { print }" file.txt\n' "$prefix" "$sep" "$num" > "$WORKDIR/pub/script.sh"

  run bash "$SCRIPT" --files "pub/script.sh" --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
}

@test "leaked-identifiers: carve-out for bash =~ operator" {
  mkdir -p "$WORKDIR/pub"
  local cfg="$BATS_TEST_TMPDIR/lint-pack.yaml"
  _write_leak_config "$cfg"

  local prefix="FR"
  local sep="-"
  local num="77"
  printf '[[ "$line" =~ %s%s%s ]] && echo match\n' "$prefix" "$sep" "$num" > "$WORKDIR/pub/script.sh"

  run bash "$SCRIPT" --files "pub/script.sh" --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
}

@test "leaked-identifiers: carve-out for PATTERN variable assignment" {
  mkdir -p "$WORKDIR/pub"
  local cfg="$BATS_TEST_TMPDIR/lint-pack.yaml"
  _write_leak_config "$cfg"

  local prefix="FR"
  local sep="-"
  local num="55"
  printf 'STORY_PATTERN="%s%s%s"\n' "$prefix" "$sep" "$num" > "$WORKDIR/pub/script.sh"

  run bash "$SCRIPT" --files "pub/script.sh" --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
}

# ============================================================================
# Cross-stack rule: spliced-yq-jq
# ============================================================================

@test "spliced-yq-jq: fires on variable spliced into yq program" {
  local f="$WORKDIR/bad.sh"
  printf '#!/usr/bin/env bash\nyq ".a = \\"$X\\"" file.yaml\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings[] | select(.rule == "spliced-yq-jq")' "$REPORT"
}

@test "spliced-yq-jq: does not fire on strenv usage" {
  local f="$WORKDIR/good.sh"
  printf '#!/usr/bin/env bash\nyq ".a = strenv(X)" file.yaml\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
}

@test "spliced-yq-jq: fires on jq variable splice" {
  local f="$WORKDIR/bad-jq.sh"
  printf '#!/usr/bin/env bash\njq ".items[] | select(.name == \\"${NAME}\\")" data.json\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings[] | select(.rule == "spliced-yq-jq")' "$REPORT"
}

@test "spliced-yq-jq: does not fire on jq --arg" {
  local f="$WORKDIR/good-jq.sh"
  printf '#!/usr/bin/env bash\njq --arg name "$NAME" '"'"'.items[] | select(.name == $name)'"'"' data.json\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
}

@test "spliced-yq-jq: does not fire on file argument" {
  local f="$WORKDIR/safe.sh"
  printf '#!/usr/bin/env bash\njq -r '"'"'.a'"'"' "$file"\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
}

@test "spliced-yq-jq: does not fire on stdin pipe" {
  local f="$WORKDIR/pipe.sh"
  printf '#!/usr/bin/env bash\nprintf '"'"'%%s'"'"' "$x" | jq .\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
}

@test "spliced-yq-jq: fires when --arg coexists with a real splice" {
  local f="$WORKDIR/mixed.sh"
  printf '#!/usr/bin/env bash\njq --arg a "$A" ".x = \\"$B\\"" f\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings[] | select(.rule == "spliced-yq-jq")' "$REPORT"
}

# ============================================================================
# Cross-stack rule: hardcoded-credentials
# ============================================================================

@test "hardcoded-credentials: fires on hardcoded API key" {
  local f="$WORKDIR/creds.sh"
  _write_credential_file "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings[] | select(.rule == "hardcoded-credentials")' "$REPORT"
}

@test "hardcoded-credentials: does not fire on env var reference" {
  local f="$WORKDIR/safe.sh"
  # The env-var expansion ${LONG_API_KEY_VALUE} is NOT a hardcoded credential
  printf 'api_key = "${LONG_API_KEY_VALUE_FROM_VAULT}"\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
}

# ============================================================================
# Bash rule: bash4-constructs
# ============================================================================

@test "bash4-constructs: fires on local -A" { # lint-pack:allow bash4-constructs
  local f="$WORKDIR/bash4.sh"
  printf '#!/usr/bin/env bash\nlocal -A mymap\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings[] | select(.rule == "bash4-constructs")' "$REPORT"
  jq -e '.findings[] | select(.rule == "bash4-constructs") | .fix_hint | test("indexed arrays")' "$REPORT"
}

@test "bash4-constructs: fires on declare -A" { # lint-pack:allow bash4-constructs
  local f="$WORKDIR/bash4b.sh"
  printf '#!/usr/bin/env bash\ndeclare -A mymap\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings[] | select(.rule == "bash4-constructs")' "$REPORT"
}

@test "bash4-constructs: fires on mapfile" {
  local f="$WORKDIR/bash4c.sh"
  printf '#!/usr/bin/env bash\nmapfile -t lines < input.txt\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings[] | select(.rule == "bash4-constructs") | .message | test("mapfile")' "$REPORT"
}

@test "bash4-constructs: fires on case modification" {
  local f="$WORKDIR/bash4d.sh"
  printf '#!/usr/bin/env bash\necho "${var,,}"\n' > "$f"  # lint-pack:allow bash4-constructs

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings[] | select(.rule == "bash4-constructs") | .message | test("case modification")' "$REPORT"
}

@test "bash4-constructs: does not fire on local -r (bash 3.2 safe)" {
  local f="$WORKDIR/safe.sh"
  printf '#!/usr/bin/env bash\nlocal -r readonly_var="val"\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
}

@test "bash4-constructs: does not fire on non-shell file" {
  local f="$WORKDIR/code.go"
  printf 'package main\nvar localA = "test"\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
}

# ============================================================================
# Bash rule: sed-inplace
# ============================================================================

@test "sed-inplace: fires on sed -i with empty string" {
  local f="$WORKDIR/sedi.sh"
  printf "#!/usr/bin/env bash\nsed -i '' 's/a/b/' file.txt\n" > "$f"  # lint-pack:allow sed-inplace

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings[] | select(.rule == "sed-inplace")' "$REPORT"
}

@test "sed-inplace: does not fire on portable sed-to-temp pattern" {
  local f="$WORKDIR/safe-sed.sh"
  printf '#!/usr/bin/env bash\nsed "s/a/b/" file.txt > tmp && mv tmp file.txt\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
}

# ============================================================================
# Bash rule: skip-in-red-test
# ============================================================================

@test "skip-in-red-test: fires on || skip in bats file" { # lint-pack:allow skip-in-red-test
  local f="$WORKDIR/red.bats"
  printf '@test "missing dep" {\n  command -v foobar || skip\n  run foobar\n}\n' > "$f"  # lint-pack:allow skip-in-red-test

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings[] | select(.rule == "skip-in-red-test")' "$REPORT"
}

@test "skip-in-red-test: does not fire with lint-pack:allow-skip marker" {
  local f="$WORKDIR/ok.bats"
  printf '@test "optional dep" {\n  command -v opt || skip  # lint-pack:allow-skip\n}\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
}

@test "skip-in-red-test: does not fire in non-bats shell file" {
  local f="$WORKDIR/script.sh"
  printf '#!/usr/bin/env bash\ncommand -v foobar || skip\n' > "$f"  # lint-pack:allow skip-in-red-test

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  # skip-in-red-test only runs on .bats files
  jq -e '[.findings[] | select(.rule == "skip-in-red-test")] | length == 0' "$REPORT"
}

# ============================================================================
# Bash rule: bash-syntax
# ============================================================================

@test "bash-syntax: fires on syntax error in shell file" {
  local f="$WORKDIR/broken.sh"
  printf '#!/usr/bin/env bash\nif [[ true ]]\n  echo ok\nfi\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings[] | select(.rule == "bash-syntax")' "$REPORT"
}

@test "bash-syntax: does not fire on valid shell file" {
  local f="$WORKDIR/good.sh"
  printf '#!/usr/bin/env bash\nif [ true ]; then\n  echo ok\nfi\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '[.findings[] | select(.rule == "bash-syntax")] | length == 0' "$REPORT"
}

@test "bash-syntax: skips bats files (bats syntax is not valid bash)" {
  local f="$WORKDIR/test.bats"
  printf '@test "hello" {\n  true\n}\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  # bats files are skipped by bash-syntax rule
  jq -e '[.findings[] | select(.rule == "bash-syntax")] | length == 0' "$REPORT"
}

# ============================================================================
# Exclusion flag (--exclude)
# ============================================================================

@test "exclude flag skips the named rule and notes it in the report" {
  local f="$WORKDIR/bash4.sh"
  printf '#!/usr/bin/env bash\nlocal -A mymap\n' > "$f"

  run bash "$SCRIPT" --files "$f" --exclude bash4-constructs --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.excluded_rules | index("bash4-constructs")' "$REPORT"
  jq -e '.findings | length == 0' "$REPORT"
}

@test "exclude flag: multiple rules can be excluded" {
  local f="$WORKDIR/multi.sh"
  printf '#!/usr/bin/env bash\nlocal -A mymap\nyq ".a = \\"$X\\"" f.yaml\n' > "$f"

  run bash "$SCRIPT" --files "$f" \
    --exclude bash4-constructs --exclude spliced-yq-jq \
    --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.excluded_rules | length == 2' "$REPORT"
  jq -e '.findings | length == 0' "$REPORT"
}

# ============================================================================
# Report shape (AC5)
# ============================================================================

@test "report has correct JSON shape with findings" {
  local f="$WORKDIR/bash4.sh"
  printf '#!/usr/bin/env bash\nlocal -A mymap\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]

  # Verify all required top-level keys
  jq -e '.version == 1' "$REPORT"
  jq -e '.findings | type == "array"' "$REPORT"
  jq -e '.excluded_rules | type == "array"' "$REPORT"
  jq -e '.files_scanned == 1' "$REPORT"

  # Verify finding shape
  jq -e '.findings[0] | has("rule", "file", "line", "message", "fix_hint")' "$REPORT"
  jq -e '.findings[0].line | type == "number"' "$REPORT"
}

@test "report has correct JSON shape with no findings" {
  local f="$WORKDIR/clean.sh"
  printf '#!/usr/bin/env bash\necho hello\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]

  jq -e '.version == 1' "$REPORT"
  jq -e '.findings | length == 0' "$REPORT"
  jq -e '.files_scanned == 1' "$REPORT"
}

@test "report default path is outside the working tree" {
  local f="$WORKDIR/clean.sh"
  printf '#!/usr/bin/env bash\necho hello\n' > "$f"

  run bash "$SCRIPT" --files "$f" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  # The report path is printed to stderr; capture it
  local report_path
  report_path="$(printf '%s\n' "$output" | grep 'report:' | sed 's/.*report: //')"
  [ -f "$report_path" ]
  # Must not be under the workdir
  case "$report_path" in
    "${WORKDIR}"*) return 1 ;;
  esac
}

# ============================================================================
# Go-only diff: only cross-stack rules, no bash false positives
# ============================================================================

@test "go-only diff: only cross-stack rules run, no bash false positives" {
  local f="$WORKDIR/main.go"
  printf 'package main\nfunc main() { println("hello") }\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
  # Verify bash rules did not fire (no shell files in scope)
  grep -q 'no shell files in scope' <<< "$output"
}

# ============================================================================
# Determinism (AC4): same input yields byte-identical output
# ============================================================================

@test "determinism: two runs on same input produce byte-identical reports" {
  # Create multiple files with findings to exercise sort order
  printf '#!/usr/bin/env bash\nlocal -A mymap\n' > "$WORKDIR/b.sh"
  printf '#!/usr/bin/env bash\nlocal -A mymap\n' > "$WORKDIR/a.sh"

  local r1="$BATS_TEST_TMPDIR/r1.json"
  local r2="$BATS_TEST_TMPDIR/r2.json"

  bash "$SCRIPT" --files "$WORKDIR/b.sh" "$WORKDIR/a.sh" --report "$r1" 2>/dev/null || true
  bash "$SCRIPT" --files "$WORKDIR/b.sh" "$WORKDIR/a.sh" --report "$r2" 2>/dev/null || true

  diff "$r1" "$r2"
}

@test "determinism: reversed file order produces same report" {
  printf '#!/usr/bin/env bash\nlocal -A mymap\n' > "$WORKDIR/a.sh"
  printf '#!/usr/bin/env bash\nlocal -A mymap\n' > "$WORKDIR/b.sh"

  local r1="$BATS_TEST_TMPDIR/r1.json"
  local r2="$BATS_TEST_TMPDIR/r2.json"

  bash "$SCRIPT" --files "$WORKDIR/a.sh" "$WORKDIR/b.sh" --report "$r1" 2>/dev/null || true
  bash "$SCRIPT" --files "$WORKDIR/b.sh" "$WORKDIR/a.sh" --report "$r2" 2>/dev/null || true

  diff "$r1" "$r2"
}

# ============================================================================
# Performance (AC4): 500-file scan completes within 30 seconds
# ============================================================================

@test "performance: 500-file scan completes within 30 seconds" {
  # Generate 500 small shell files
  local i=0
  while [ "$i" -lt 500 ]; do
    printf '#!/usr/bin/env bash\necho "file %d"\n' "$i" > "$WORKDIR/gen_${i}.sh"
    i=$((i + 1))
  done

  local args=()
  i=0
  while [ "$i" -lt 500 ]; do
    args+=("gen_${i}.sh")
    i=$((i + 1))
  done

  local start end elapsed
  start="$(date +%s)"
  run bash "$SCRIPT" --files "${args[@]}" --report "$REPORT" --workdir "$WORKDIR"
  end="$(date +%s)"
  elapsed=$((end - start))

  printf 'timing: %ds for 500 trivial files (load %s)\n' "$elapsed" "$(uptime | sed 's/.*averages: //')" >&3
  [ "$status" -eq 0 ]
  jq -e '.files_scanned == 500' "$REPORT"
  [ "$elapsed" -lt 30 ]
}

@test "performance: 500-file scan with findings within 30 seconds" {
  local i=0
  while [ "$i" -lt 500 ]; do
    printf '#!/usr/bin/env bash\nlocal -A map%d\n' "$i" > "$WORKDIR/gen_${i}.sh"
    i=$((i + 1))
  done

  local args=()
  i=0
  while [ "$i" -lt 500 ]; do
    args+=("gen_${i}.sh")
    i=$((i + 1))
  done

  local start end elapsed
  start="$(date +%s)"
  run bash "$SCRIPT" --files "${args[@]}" --report "$REPORT" --workdir "$WORKDIR"
  end="$(date +%s)"
  elapsed=$((end - start))

  printf 'timing: %ds for 500 files with findings (load %s)\n' "$elapsed" "$(uptime | sed 's/.*averages: //')" >&3
  [ "$status" -eq 1 ]
  jq -e '.findings | length == 500' "$REPORT"
  [ "$elapsed" -lt 30 ]
}

# ============================================================================
# Fail-closed: config errors exit non-zero
# ============================================================================

@test "fail-closed: missing --config file exits 2" {
  printf '#!/usr/bin/env bash\necho ok\n' > "$WORKDIR/f.sh"

  run bash "$SCRIPT" --files "$WORKDIR/f.sh" --config "$BATS_TEST_TMPDIR/nope.yaml" --report "$REPORT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--config file not found"* ]]
}

@test "fail-closed: malformed YAML config exits 2" {
  printf '#!/usr/bin/env bash\necho ok\n' > "$WORKDIR/f.sh"
  printf 'lint_pack: [unclosed\n' > "$BATS_TEST_TMPDIR/bad.yaml"

  run bash "$SCRIPT" --files "$WORKDIR/f.sh" --config "$BATS_TEST_TMPDIR/bad.yaml" --report "$REPORT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not valid YAML"* ]]
}

@test "fail-closed: missing yq with explicit --config exits 2" {
  printf '#!/usr/bin/env bash\necho ok\n' > "$WORKDIR/f.sh"
  _write_leak_config "$BATS_TEST_TMPDIR/cfg.yaml"

  # Build a minimal PATH with essential tools but NOT yq.
  # PATH=/usr/bin:/bin is insufficient because CI may have yq there.
  local no_yq="$BATS_TEST_TMPDIR/no-yq-bin"
  mkdir -p "$no_yq"
  local cmd
  for cmd in bash grep sed awk head cat jq mktemp rm sort date basename dirname printf wc tr file; do
    local cpath
    cpath="$(command -v "$cmd" 2>/dev/null)" || true
    [ -n "$cpath" ] && ln -sf "$cpath" "$no_yq/$cmd"
  done
  # yq is intentionally omitted

  run env PATH="$no_yq" bash "$SCRIPT" --files "$WORKDIR/f.sh" --config "$BATS_TEST_TMPDIR/cfg.yaml" --report "$REPORT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"yq is required"* ]]
}

@test "fail-closed: invalid regex in config exits 2" {
  printf '#!/usr/bin/env bash\necho ok\n' > "$WORKDIR/f.sh"
  cat > "$BATS_TEST_TMPDIR/badpat.yaml" <<'YAML'
lint_pack:
  leaked_identifiers:
    patterns:
      - "FR-[0-9"
    published_paths:
      - "pub/"
YAML

  run bash "$SCRIPT" --files "$WORKDIR/f.sh" --config "$BATS_TEST_TMPDIR/badpat.yaml" --report "$REPORT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid regex"* ]]
}

# ============================================================================
# Error handling
# ============================================================================

@test "no files provided: exits with usage error" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "unknown option: exits with usage error" {
  run bash "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
}

# ============================================================================
# Fail-closed: file errors do not disable rules for valid files
# ============================================================================

@test "fail-closed: missing file does not disable rules for other files" {
  printf '#!/usr/bin/env bash\nlocal -A mymap\n' > "$WORKDIR/real.sh"

  run bash "$SCRIPT" --files "$WORKDIR/real.sh" "$WORKDIR/gone.sh" --report "$REPORT"
  [ "$status" -eq 2 ]
  # Findings from the real file must still appear
  jq -e '.findings | length > 0' "$REPORT"
  jq -e '.findings[0].rule == "bash4-constructs"' "$REPORT"
  # The error is reported in stderr
  [[ "$output" == *"file not found"* ]]
}

@test "fail-closed: unreadable file does not disable rules for other files" {
  printf '#!/usr/bin/env bash\nlocal -A mymap\n' > "$WORKDIR/real.sh"
  touch "$WORKDIR/locked.sh"
  chmod 000 "$WORKDIR/locked.sh"

  run bash "$SCRIPT" --files "$WORKDIR/real.sh" "$WORKDIR/locked.sh" --report "$REPORT"
  [ "$status" -eq 2 ]
  jq -e '.findings | length > 0' "$REPORT"
  [[ "$output" == *"not readable"* ]]
  chmod 644 "$WORKDIR/locked.sh"
}

# ============================================================================
# Auto-discovered project config: fail-closed when lint_pack key exists
# ============================================================================

_build_no_yq_path() {
  local no_yq="$1"
  mkdir -p "$no_yq"
  local cmd
  for cmd in bash grep sed awk head cat jq mktemp rm sort date basename dirname printf wc tr file; do
    local cpath
    cpath="$(command -v "$cmd" 2>/dev/null)" || true
    [ -n "$cpath" ] && ln -sf "$cpath" "$no_yq/$cmd"
  done
}

@test "project-config: auto-discovered valid config with lint_pack key is read" {
  mkdir -p "$WORKDIR/.gaia/config" "$WORKDIR/pub"
  cat > "$WORKDIR/.gaia/config/project-config.yaml" << 'YAML'
lint_pack:
  leaked_identifiers:
    patterns:
      - "PROJ-[0-9]+"
    published_paths:
      - "pub/"
YAML
  # Assemble identifier at runtime
  local p1="PROJ" p2="-42"
  printf 'see %s%s\n' "$p1" "$p2" > "$WORKDIR/pub/a.md"

  run env -u PROJECT_CONFIG -u CLAUDE_PROJECT_ROOT bash "$SCRIPT" --files pub/a.md --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length > 0' "$REPORT"
  jq -e '.findings[0].rule == "leaked-identifiers"' "$REPORT"
}

@test "project-config: malformed YAML with lint_pack key exits 2" {
  mkdir -p "$WORKDIR/.gaia/config" "$WORKDIR/pub"
  printf 'lint_pack: [unclosed\n' > "$WORKDIR/.gaia/config/project-config.yaml"
  printf 'clean file\n' > "$WORKDIR/pub/a.md"

  run env -u PROJECT_CONFIG -u CLAUDE_PROJECT_ROOT bash "$SCRIPT" --files pub/a.md --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not valid YAML"* ]]
}

@test "project-config: no yq with lint_pack key exits 2" {
  mkdir -p "$WORKDIR/.gaia/config" "$WORKDIR/pub"
  cat > "$WORKDIR/.gaia/config/project-config.yaml" << 'YAML'
lint_pack:
  leaked_identifiers:
    patterns:
      - "PROJ-[0-9]+"
    published_paths:
      - "pub/"
YAML
  printf 'clean file\n' > "$WORKDIR/pub/a.md"

  local no_yq="$BATS_TEST_TMPDIR/no-yq-bin2"
  _build_no_yq_path "$no_yq"

  run env -u PROJECT_CONFIG -u CLAUDE_PROJECT_ROOT PATH="$no_yq" bash "$SCRIPT" --files pub/a.md --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"yq is required"* ]]
}

@test "project-config: absent lint_pack key skips rule silently" {
  mkdir -p "$WORKDIR/.gaia/config" "$WORKDIR/pub"
  printf 'some_other_key: true\n' > "$WORKDIR/.gaia/config/project-config.yaml"
  printf 'clean file\n' > "$WORKDIR/pub/a.md"

  run env -u PROJECT_CONFIG -u CLAUDE_PROJECT_ROOT bash "$SCRIPT" --files pub/a.md --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.skipped_rules | index("leaked-identifiers")' "$REPORT"
}

@test "project-config: unreadable config file exits 2 (fail closed)" {
  mkdir -p "$WORKDIR/.gaia/config" "$WORKDIR/pub"
  printf 'lint_pack:\n  leaked_identifiers:\n    patterns: ["X"]\n' > "$WORKDIR/.gaia/config/project-config.yaml"
  chmod 000 "$WORKDIR/.gaia/config/project-config.yaml"
  printf 'clean file\n' > "$WORKDIR/pub/a.md"

  run env -u PROJECT_CONFIG -u CLAUDE_PROJECT_ROOT bash "$SCRIPT" --files pub/a.md --report "$REPORT" --workdir "$WORKDIR"
  chmod 644 "$WORKDIR/.gaia/config/project-config.yaml"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not readable"* ]]
}

# ============================================================================
# JSON file scanning
# ============================================================================

@test "file detection: JSON files are scanned, not skipped as binary" {
  local f="$WORKDIR/schema.json"
  # Create a proper JSON file that file(1) reports as "JSON data"
  printf '{"name": "test"}\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  # The file must be scanned (not skipped as binary), exit 0 = no findings
  [ "$status" -eq 0 ]
  jq -e '.files_scanned == 1' "$REPORT"
}

# ============================================================================
# Single-file splice parsing
# ============================================================================

@test "spliced-yq-jq: single-file mode reports correct file and line" {
  local f="$WORKDIR/only.sh"
  printf '#!/usr/bin/env bash\nyq ".a = \\"$X\\"" file.yaml\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings[0].rule == "spliced-yq-jq"' "$REPORT"
  jq -e '.findings[0].line == 2' "$REPORT"
}

# ============================================================================
# Splice rule: safe forms and must-fire forms
# ============================================================================

@test "spliced-yq-jq: does not fire on jq -e . with file argument" {
  local f="$WORKDIR/safe-dot.sh"
  printf '#!/usr/bin/env bash\njq -e . "$f"\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
}

@test "spliced-yq-jq: does not fire on file path with dots and slashes" {
  local f="$WORKDIR/safe-path.sh"
  cat > "$f" << 'EOF'
#!/usr/bin/env bash
yq -r '.a' "${CFG_DIR}/project-config.yaml"
EOF

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
}

@test "spliced-yq-jq: does not fire on jq inside command substitution with --arg" {
  local f="$WORKDIR/safe-subst.sh"
  cat > "$f" << 'SEOF'
#!/usr/bin/env bash
v="$(jq -r --arg k "$sid" '.sessions[$k].pid' "$f")"
SEOF

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
}

@test "spliced-yq-jq: does not fire on escaped dollar in double quotes" {
  local f="$WORKDIR/safe-esc.sh"
  cat > "$f" << 'EOF'
#!/usr/bin/env bash
jq -n --arg k "$k" ".[\$k]"
EOF

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
}

@test "spliced-yq-jq: fires on quote-break splice pattern" {
  local f="$WORKDIR/qbreak.sh"
  # Build the fixture (a yq command with a quote-break splice) from
  # assembled parts so the lint pack does not flag this test file.
  local dq='"' sq="'"
  printf 'yq -i %s.a = %s%s%s$X%s%s%s%s f.yaml\n' \
    "$sq" "$dq" "$sq" "$dq" "$dq" "$sq" "$dq" "$sq" > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings[] | select(.rule == "spliced-yq-jq")' "$REPORT"
}

# ============================================================================
# Matching-logic carve-out: grep variants and post-pattern leaks
# ============================================================================

_write_fr_config() {
  local cfg="$1"
  local prefix="FR"
  local sep="-"
  cat > "$cfg" <<YAML
lint_pack:
  leaked_identifiers:
    patterns:
      - "${prefix}${sep}[0-9]+"
    published_paths:
      - "pub/"
YAML
}

@test "carve-out: if grep -qE does not fire on pattern argument" {
  mkdir -p "$WORKDIR/pub"
  local cfg="$BATS_TEST_TMPDIR/lp.yaml"
  _write_fr_config "$cfg"
  local p="FR" s="-" n="42"
  printf 'if grep -qE '"'"'%s%s%s'"'"' "$f"; then echo match; fi\n' "$p" "$s" "$n" > "$WORKDIR/pub/s.sh"

  run bash "$SCRIPT" --files "pub/s.sh" --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
}

@test "carve-out: grep -Eq does not fire on pattern argument" {
  mkdir -p "$WORKDIR/pub"
  local cfg="$BATS_TEST_TMPDIR/lp.yaml"
  _write_fr_config "$cfg"
  local p="FR" s="-" n="42"
  printf 'grep -Eq '"'"'%s%s%s'"'"' f\n' "$p" "$s" "$n" > "$WORKDIR/pub/s.sh"

  run bash "$SCRIPT" --files "pub/s.sh" --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
}

@test "carve-out: while grep -E does not fire on pattern argument" {
  mkdir -p "$WORKDIR/pub"
  local cfg="$BATS_TEST_TMPDIR/lp.yaml"
  _write_fr_config "$cfg"
  local p="FR" s="-" n="42"
  printf 'while grep -E '"'"'%s%s%s'"'"' f; do break; done\n' "$p" "$s" "$n" > "$WORKDIR/pub/s.sh"

  run bash "$SCRIPT" --files "pub/s.sh" --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
}

@test "carve-out: leak after =~ is NOT carved out" {
  mkdir -p "$WORKDIR/pub"
  local cfg="$BATS_TEST_TMPDIR/lp.yaml"
  _write_fr_config "$cfg"
  local p="FR" s="-" n="123"
  printf '[[ $x =~ ^a ]] && echo "see %s%s%s"\n' "$p" "$s" "$n" > "$WORKDIR/pub/s.sh"

  run bash "$SCRIPT" --files "pub/s.sh" --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length > 0' "$REPORT"
}

@test "carve-out: leak after sed program is NOT carved out" {
  mkdir -p "$WORKDIR/pub"
  local cfg="$BATS_TEST_TMPDIR/lp.yaml"
  _write_fr_config "$cfg"
  local p="FR" s="-" n="123"
  printf 'sed '"'"'s/a/b/'"'"' f && echo "see %s%s%s"\n' "$p" "$s" "$n" > "$WORKDIR/pub/s.sh"

  run bash "$SCRIPT" --files "pub/s.sh" --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length > 0' "$REPORT"
}

# ============================================================================
# Carve-out: dual-occurrence on same line
# ============================================================================

@test "carve-out: same ID in grep pattern AND prose is still flagged" {
  mkdir -p "$WORKDIR/pub"
  local cfg="$BATS_TEST_TMPDIR/lp.yaml"
  _write_fr_config "$cfg"
  # Build from parts: grep for an identifier then echo it in prose
  local p="FR" s="-" n="42"
  printf 'grep -qE '"'"'%s%s%s'"'"' f || echo "missing %s%s%s"\n' "$p" "$s" "$n" "$p" "$s" "$n" > "$WORKDIR/pub/dual.sh"

  run bash "$SCRIPT" --files "pub/dual.sh" --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  # The ID in the grep pattern is carved out, but the one in echo is a real leak.
  [ "$status" -eq 1 ]
  jq -e '.findings | length > 0' "$REPORT"
  jq -e '.findings[0].rule == "leaked-identifiers"' "$REPORT"
}

@test "carve-out: echo mentioning =~ with ID is NOT carved out" {
  mkdir -p "$WORKDIR/pub"
  local cfg="$BATS_TEST_TMPDIR/lp.yaml"
  _write_fr_config "$cfg"
  local p="FR" s="-" n="55"
  printf 'echo "Use =~ to match, see %s%s%s for details"\n' "$p" "$s" "$n" > "$WORKDIR/pub/eqtilde.sh"

  run bash "$SCRIPT" --files "pub/eqtilde.sh" --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length > 0' "$REPORT"
}

@test "carve-out: ID after grep pattern comment is NOT carved out" {
  mkdir -p "$WORKDIR/pub"
  local cfg="$BATS_TEST_TMPDIR/lp.yaml"
  _write_fr_config "$cfg"
  local p="FR" s="-" n="77"
  printf 'echo "see %s%s%s" # grep -E '"'"'%s%s%s'"'"'\n' "$p" "$s" "$n" "$p" "$s" "$n" > "$WORKDIR/pub/comment.sh"

  run bash "$SCRIPT" --files "pub/comment.sh" --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  # The ID in the echo string is a leak; the one in the comment grep pattern is carve-out.
  [ "$status" -eq 1 ]
  jq -e '.findings | length > 0' "$REPORT"
}

# ============================================================================
# Splice rule: command substitution and .$KEY patterns
# ============================================================================

@test "spliced-yq-jq: fires on splice inside command substitution" {
  local f="$WORKDIR/cmdsub.sh"
  printf '#!/usr/bin/env bash\nv="$(yq ".a = \\"$X\\"" f)"\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings[] | select(.rule == "spliced-yq-jq")' "$REPORT"
}

@test "spliced-yq-jq: fires on jq dot-variable pattern" {
  local f="$WORKDIR/dotkey.sh"
  printf '#!/usr/bin/env bash\njq ".$KEY" f.json\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings[] | select(.rule == "spliced-yq-jq")' "$REPORT"
}

@test "spliced-yq-jq: fires on nested key splice inside command substitution" {
  local f="$WORKDIR/nested.sh"
  printf '#!/usr/bin/env bash\nraw="$(yq -o=json ".${parent}.${child}" "$cfg")"\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings[] | select(.rule == "spliced-yq-jq")' "$REPORT"
}

@test "spliced-yq-jq: fires on cat subcommand inside program" {
  local f="$WORKDIR/catsub.sh"
  printf '#!/usr/bin/env bash\njq ".a = $(cat x)" f\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings[] | select(.rule == "spliced-yq-jq")' "$REPORT"
}

@test "spliced-yq-jq: does not fire on safe --arg inside command substitution" {
  local f="$WORKDIR/safesub.sh"
  printf '#!/usr/bin/env bash\nv="$(jq -r --arg k "$sid" '"'"'.sessions[$k].pid'"'"' "$f")"\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
}

# ============================================================================
# Suppression marker (lint-pack:allow)
# ============================================================================

@test "suppression marker: lint-pack:allow suppresses a specific rule" {
  local f="$WORKDIR/suppressed.sh"
  printf '#!/usr/bin/env bash\nlocal -A mymap  # lint-pack:allow bash4-constructs\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
}

@test "suppression marker: lint-pack:allow does not suppress other rules" {
  local f="$WORKDIR/not-suppressed.sh"
  printf '#!/usr/bin/env bash\nlocal -A mymap  # lint-pack:allow sed-inplace\n' > "$f"

  run bash "$SCRIPT" --files "$f" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings[] | select(.rule == "bash4-constructs")' "$REPORT"
}

# ============================================================================
# Diff-mode filtering
# ============================================================================

@test "diff mode: only added lines are reported" {
  # Create a git repo to test diff mode
  local gitdir="$BATS_TEST_TMPDIR/difftest"
  mkdir -p "$gitdir"
  cd "$gitdir"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"

  # Create initial file with a bash4 construct
  printf '#!/usr/bin/env bash\nlocal -A existing_map\n' > "a.sh"
  git add a.sh
  git commit -q -m "initial"

  # Add a new bash4 construct on a new line
  printf '#!/usr/bin/env bash\nlocal -A existing_map\nlocal -A new_map\n' > "a.sh"
  git add a.sh
  git commit -q -m "add new construct"

  run bash "$SCRIPT" --diff "HEAD~1...HEAD" --report "$REPORT" --workdir "$gitdir"
  # Only the NEW line (line 3) should be reported, not the existing line (line 2)
  [ "$status" -eq 1 ]
  jq -e '.findings | length == 1' "$REPORT"
  jq -e '.findings[0].line == 3' "$REPORT"
  cd "$WORKDIR"
}

# ============================================================================
# Splice rule: inside a command substitution only yq/jq programs count
# ============================================================================

_splice_rc() {
  # Writes the given lines to a fixture and scans it; sets status via run.
  printf '%s\n' "$@" > "$WORKDIR/s.sh"
  run bash "$SCRIPT" --files s.sh --exclude bash-syntax --report "$REPORT" --workdir "$WORKDIR"
}

@test "spliced-yq-jq: file path argument inside command substitution is not a splice" {
  _splice_rc 'n="$(jq '"'"'.a'"'"' "$ROOT/x.json")"'
  [ "$status" -eq 0 ]
}

@test "spliced-yq-jq: variable-free program inside command substitution is not a splice" {
  _splice_rc 'v="$(yq ".a.b" f)"'
  [ "$status" -eq 0 ]
}

@test "spliced-yq-jq: named jq argument inside command substitution is not a splice" {
  _splice_rc 'o="$(jq -nc --arg r "${runners[0]}" '"'"'{r: $r}'"'"')"'
  [ "$status" -eq 0 ]
}

@test "spliced-yq-jq: key splice with the alternative operator inside command substitution fires" {
  _splice_rc 'v="$(yq eval ".${k} // \"\"" f)"'
  [ "$status" -eq 1 ]
}

@test "spliced-yq-jq: argument of an earlier pipeline stage inside command substitution is not a splice" {
  _splice_rc 'j="$(printf '"'"'%s\n'"'"' "${arr[@]}" | jq -R .)"'
  [ "$status" -eq 0 ]
}

@test "spliced-yq-jq: argument of a later pipeline stage inside command substitution is not a splice" {
  _splice_rc 'j="$(jq -r .a f | tr -d "[$x]")"'
  [ "$status" -eq 0 ]
}

@test "spliced-yq-jq: message that merely embeds a command substitution is not a splice" {
  _splice_rc 'log "result = $(jq -r .a f)"'
  [ "$status" -eq 0 ]
}

@test "spliced-yq-jq: subscript splice inside command substitution fires" {
  _splice_rc 'x="$(jq ".a[$k]" f)"'
  [ "$status" -eq 1 ]
  jq -e '.findings[0].rule == "spliced-yq-jq"' "$REPORT"
}

@test "spliced-yq-jq: command substitution spliced into a program nested in a command substitution fires" {
  _splice_rc 'x="$(jq ".a[$(cat k)]" f)"'
  [ "$status" -eq 1 ]
}

# ============================================================================
# Splice rule: backslash-continued commands
# ============================================================================

@test "spliced-yq-jq: splice on a continuation line fires on that line" {
  _splice_rc 'jq \' '  ".a[$x]" f'
  [ "$status" -eq 1 ]
  jq -e '.findings | length == 1' "$REPORT"
  jq -e '.findings[0].rule == "spliced-yq-jq" and .findings[0].line == 2' "$REPORT"
}

@test "spliced-yq-jq: splice several continuation lines down fires" {
  _splice_rc 'jq -r \' '  --arg a "$a" \' '  ".a[$x]" f'
  [ "$status" -eq 1 ]
  jq -e '.findings[0].line == 3' "$REPORT"
}

@test "spliced-yq-jq: command substitution spliced on a continuation line fires" {
  _splice_rc 'jq \' '  ".a[$(cat k)]" f'
  [ "$status" -eq 1 ]
}

@test "spliced-yq-jq: continuation program with no splice does not fire" {
  _splice_rc 'jq \' '  ".a.b" f'
  [ "$status" -eq 0 ]
  _splice_rc 'jq -r \' "  --arg k \"\$k\" \\" "  '.a[\$k]' \"\$dir/f.json\""
  [ "$status" -eq 0 ]
}

@test "spliced-yq-jq: a command after the continued yq/jq command is not scanned" {
  _splice_rc 'jq .a f | \' '  tr -d "[$x]"'
  [ "$status" -eq 0 ]
  _splice_rc 'jq .a f \' '  | tr -d "[$x]"'
  [ "$status" -eq 0 ]
  _splice_rc 'jq .a f' 'tr -d "[$x]"'
  [ "$status" -eq 0 ]
}

@test "spliced-yq-jq: named argument and redirection on continuation lines do not fire" {
  _splice_rc 'jq -nc \' '  --arg a "${arr[0]}" \' "  '{a: \$a}' f"
  [ "$status" -eq 0 ]
  _splice_rc 'jq .a \' '  "$f" > "$f.new" && mv "$f.new" "$f"'
  [ "$status" -eq 0 ]
}

@test "spliced-yq-jq: a continued last line does not leak into the next file" {
  printf 'jq \\\n' > "$WORKDIR/a.sh"
  printf 'tr -d "[$x]"\n' > "$WORKDIR/b.sh"
  run bash "$SCRIPT" --files a.sh b.sh --exclude bash-syntax --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
}

# ============================================================================
# Splice rule: strenv() does not excuse another splice in the same program
# ============================================================================

@test "spliced-yq-jq: key splice next to strenv fires" {
  _splice_rc 'yq ".a.\"$k\" = strenv(V)" f'
  [ "$status" -eq 1 ]
}

@test "spliced-yq-jq: strenv with no splice does not fire in either quoting" {
  _splice_rc "yq '.a = strenv(V)' f"
  [ "$status" -eq 0 ]
  _splice_rc 'yq ".a = strenv(V)" f'
  [ "$status" -eq 0 ]
}

# ============================================================================
# Self-check: the pack passes over its own source
# ============================================================================

@test "self-check: the pack reports nothing on its own source, whole-file and as a diff" {
  local repo_root src="$BATS_TEST_TMPDIR/self"
  repo_root="$(cd "$(dirname "$SCRIPT")/../../.." && pwd)"
  mkdir -p "$src/plugins/gaia/scripts"
  git -C "$src" init -q
  git -C "$src" config user.email t@example.invalid
  git -C "$src" config user.name t
  git -C "$src" commit -q --allow-empty -m base
  cp "$SCRIPT" "$src/plugins/gaia/scripts/lint-pack.sh"
  git -C "$src" add -A
  git -C "$src" commit -q -m add

  run bash "$SCRIPT" --files plugins/gaia/scripts/lint-pack.sh \
    --config "$repo_root/.gaia/lint-pack.yaml" --report "$REPORT" --workdir "$src"
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" --diff 'HEAD~1...HEAD' \
    --config "$repo_root/.gaia/lint-pack.yaml" --report "$REPORT" --workdir "$src"
  [ "$status" -eq 0 ]
  jq -e '.files_scanned == 1' "$REPORT"
}

# ============================================================================
# --diff: paths containing whitespace
# ============================================================================

@test "--diff: an added finding in a file whose name has a space is reported" {
  git -C "$WORKDIR" init -q
  git -C "$WORKDIR" config user.email t@example.invalid
  git -C "$WORKDIR" config user.name t
  git -C "$WORKDIR" commit -q --allow-empty -m base
  # Built from pieces so this suite does not flag itself.
  printf 'h() { local -%s m; }\n' A > "$WORKDIR/sp ace.sh"
  git -C "$WORKDIR" add -A
  git -C "$WORKDIR" commit -q -m add

  run bash "$SCRIPT" --diff 'HEAD~1...HEAD' --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings[0].rule == "bash4-constructs" and .findings[0].file == "sp ace.sh" and .findings[0].line == 1' "$REPORT"
}

# ============================================================================
# Documented preflight commands: the config file is optional
# ============================================================================

# Prints a documented preflight command, decoded, for the branch "main".
_decode_doc_cmd() {
  sed -e 's/^ *- .//' -e 's|</code></pre>$||' -e 's/.$//' \
      -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g' \
      -e 's/<base-branch>/main/g'
}

# The discovery form for projects using the plugin cache.
_documented_cmd() {
  grep -F 'gaiastudio-ai-gaia-framework/gaia/*/scripts/lint-pack.sh' "$1" | _decode_doc_cmd
}

# The form for projects containing the plugin source tree.
_documented_tree_cmd() {
  grep -E 'bash plugins/gaia/scripts/lint-pack.sh.*--diff' "$1" | _decode_doc_cmd
}

# A project on a feature branch, no .gaia/lint-pack.yaml, with the given line
# added on the branch; a fake plugin cache and a plugin-source copy of the pack.
_doc_project() {
  local line="$1" home="$BATS_TEST_TMPDIR/home"
  git -C "$WORKDIR" init -q -b main
  git -C "$WORKDIR" config user.email t@example.invalid
  git -C "$WORKDIR" config user.name t
  git -C "$WORKDIR" commit -q --allow-empty -m base
  git -C "$WORKDIR" update-ref refs/remotes/origin/main HEAD
  printf '%s\n' "$line" > "$WORKDIR/a.sh"
  mkdir -p "$WORKDIR/plugins/gaia/scripts"
  cp "$SCRIPT" "$WORKDIR/plugins/gaia/scripts/lint-pack.sh"
  git -C "$WORKDIR" add a.sh
  git -C "$WORKDIR" commit -q -m add
  mkdir -p "$home/.claude/plugins/cache/gaiastudio-ai-gaia-framework/gaia/9.9.9/scripts"
  cp "$SCRIPT" "$home/.claude/plugins/cache/gaiastudio-ai-gaia-framework/gaia/9.9.9/scripts/lint-pack.sh"
}

_run_documented() {
  local cmd="$1"
  [ -n "$cmd" ]
  run bash -c "cd \"\$1\" && export HOME=\"\$2\" && eval \"\$3\"" _ "$WORKDIR" "$BATS_TEST_TMPDIR/home" "$cmd"
}

@test "documented preflight commands pass on a clean change with no optional config" {
  local repo_root doc
  repo_root="$(cd "$(dirname "$SCRIPT")/../../.." && pwd)"
  _doc_project 'echo ok'
  for doc in "$repo_root/documentation/recipes.html" "$repo_root/plugins/gaia/skills/gaia-dev-story/SKILL.md"; do
    _run_documented "$(_documented_cmd "$doc")"
    [ "$status" -eq 0 ]
    _run_documented "$(_documented_tree_cmd "$doc")"
    [ "$status" -eq 0 ]
  done
}

@test "documented preflight commands report findings as findings with no optional config" {
  local repo_root doc
  repo_root="$(cd "$(dirname "$SCRIPT")/../../.." && pwd)"
  _doc_project "h() { local -""A m; }"
  for doc in "$repo_root/documentation/recipes.html" "$repo_root/plugins/gaia/skills/gaia-dev-story/SKILL.md"; do
    _run_documented "$(_documented_cmd "$doc")"
    [ "$status" -eq 1 ]
    if grep -qF 'plugin not installed' <<<"$output"; then return 1; fi
    _run_documented "$(_documented_tree_cmd "$doc")"
    [ "$status" -eq 1 ]
  done
}

@test "documented preflight commands pass the optional config when it exists" {
  local repo_root doc
  repo_root="$(cd "$(dirname "$SCRIPT")/../../.." && pwd)"
  _doc_project 'echo ok'
  mkdir -p "$WORKDIR/.gaia"
  printf 'not: [valid\n' > "$WORKDIR/.gaia/lint-pack.yaml"
  for doc in "$repo_root/documentation/recipes.html" "$repo_root/plugins/gaia/skills/gaia-dev-story/SKILL.md"; do
    _run_documented "$(_documented_cmd "$doc")"
    [ "$status" -eq 2 ]
    grep -qF 'not valid YAML' <<<"$output"
  done
}

# ============================================================================
# Leak rule: process count does not grow with the number of hits
# ============================================================================

@test "leaked-identifiers: grep invocations do not grow with the number of hits" {
  local cfg="$BATS_TEST_TMPDIR/lint-pack.yaml" shim="$BATS_TEST_TMPDIR/shim" log="$BATS_TEST_TMPDIR/grep.log"
  _write_leak_config "$cfg"
  mkdir -p "$WORKDIR/pub" "$shim"
  awk -v id="FR-""1" 'BEGIN { for (i = 0; i < 300; i++) print "see " id i " and " id i }' > "$WORKDIR/pub/dense.md"
  local real_grep
  real_grep="$(command -v grep)"
  printf '#!/bin/sh\necho x >> "%s"\nexec "%s" "$@"\n' "$log" "$real_grep" > "$shim/grep"
  chmod +x "$shim/grep"

  PATH="$shim:$PATH" run bash "$SCRIPT" --files pub/dense.md --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length == 300' "$REPORT"
  local calls
  calls="$(wc -l < "$log" | tr -d ' ')"
  printf 'grep invocations: %s\n' "$calls" >&3
  [ "$calls" -lt 60 ]
}

@test "leaked-identifiers: occurrence counts treat the identifier as a literal string" {
  local cfg="$BATS_TEST_TMPDIR/lint-pack.yaml"
  cat > "$cfg" <<'YAML'
lint_pack:
  leaked_identifiers:
    patterns:
      - "x[*?][0-9]+"
    published_paths:
      - "pub/"
YAML
  mkdir -p "$WORKDIR/pub"
  # One carved occurrence and one in prose: flagged.
  printf '%s\n' "grep -E 'x*12' f # see x*12" > "$WORKDIR/pub/both.sh"
  # Carved only: not flagged, although a glob reading of the identifier would
  # also match the unrelated text that follows.
  printf '%s\n' "grep -E 'x*12' f # see xAB12" > "$WORKDIR/pub/carved.sh"
  run bash "$SCRIPT" --files pub/both.sh pub/carved.sh --exclude bash-syntax --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length == 1 and .[0].file == "pub/both.sh"' "$REPORT"
}

# ============================================================================
# Report: large finding sets
# ============================================================================

@test "report: a finding set far above the single-argument limit is written complete" {
  awk 'BEGIN { q = sprintf("%c", 39); for (i = 0; i < 6000; i++) print "sed -i " q q " s/a/b/ f" }' > "$WORKDIR/big.sh"
  run bash "$SCRIPT" --files big.sh --exclude bash-syntax --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  [ "$(wc -c < "$REPORT")" -gt 131072 ]
  jq -e '(.findings | length == 6000) and .files_scanned == 1 and .version == 1' "$REPORT"
  jq -e '[.findings[].line] == ([range(1; 6001)])' "$REPORT"
}

# ============================================================================
# --diff: nothing to scan
# ============================================================================

# A repository whose last commit is the given change, on top of a base commit
# holding a.sh (one splice line and one clean line) and keep.sh.
_diff_repo() {
  git -C "$WORKDIR" init -q -b main
  git -C "$WORKDIR" config user.email t@example.invalid
  git -C "$WORKDIR" config user.name t
  printf '%s\n' 'jq ".a[$k]" f' 'echo two' > "$WORKDIR/a.sh"
  printf 'echo keep\n' > "$WORKDIR/keep.sh"
  git -C "$WORKDIR" add -A
  git -C "$WORKDIR" commit -q -m base
}

_commit_all() {
  git -C "$WORKDIR" add -A
  git -C "$WORKDIR" commit -q -m change
}

_assert_empty_report() {
  jq -e '.version == 1 and .findings == [] and .files_scanned == 0 and (.excluded_rules | type == "array")' "$REPORT"
}

@test "--diff: a change that only deletes a file exits 0 with an empty report" {
  _diff_repo
  git -C "$WORKDIR" rm -q a.sh
  _commit_all
  run bash "$SCRIPT" --diff 'HEAD~1...HEAD' --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  _assert_empty_report
}

@test "--diff: an empty range exits 0 with an empty report" {
  _diff_repo
  run bash "$SCRIPT" --diff 'HEAD...HEAD' --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  _assert_empty_report
}

@test "--diff: a change that only touches a binary file exits 0 with an empty report" {
  _diff_repo
  printf '\000\001\002\377\376' > "$WORKDIR/blob.dat"
  _commit_all
  run bash "$SCRIPT" --diff 'HEAD~1...HEAD' --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  _assert_empty_report
}

@test "--files: a list holding only binary files exits 0 with an empty report" {
  printf '\000\001\002\377\376' > "$WORKDIR/blob.dat"
  run bash "$SCRIPT" --files blob.dat --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  _assert_empty_report
}

@test "--diff: a range git cannot resolve exits 2" {
  _diff_repo
  run bash "$SCRIPT" --diff 'no-such-ref...HEAD' --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no-such-ref...HEAD"* ]]
  [ ! -e "$REPORT" ]
}

@test "--diff: a range git cannot resolve exits 2 when --files is also given" {
  _diff_repo
  run bash "$SCRIPT" --files a.sh --diff 'no-such-ref...HEAD' --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 2 ]
}

@test "--diff: outside a git repository exits 2" {
  run bash "$SCRIPT" --diff 'HEAD~1...HEAD' --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 2 ]
}

@test "--diff: changed files that do not exist under the working directory exit 2" {
  _diff_repo
  mkdir -p "$WORKDIR/sub"
  printf 'echo sub\n' > "$WORKDIR/sub/keep"
  _commit_all
  printf 'jq ".b[$k]" f\n' >> "$WORKDIR/a.sh"
  _commit_all
  run bash "$SCRIPT" --diff 'HEAD~1...HEAD' --report "$REPORT" --workdir "$WORKDIR/sub"
  [ "$status" -eq 2 ]
}

@test "--diff: an invalid config still exits 2 when there is nothing to scan" {
  _diff_repo
  printf 'not: [valid\n' > "$BATS_TEST_TMPDIR/bad.yaml"
  run bash "$SCRIPT" --diff 'HEAD...HEAD' --config "$BATS_TEST_TMPDIR/bad.yaml" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 2 ]
}

@test "preflight runner: a deletion-only change passes the documented command" {
  local runner doc repo_root
  repo_root="$(cd "$(dirname "$SCRIPT")/../../.." && pwd)"
  runner="$(dirname "$SCRIPT")/../skills/gaia-dev-story/scripts/run-configured-commands.sh"
  doc="$repo_root/documentation/recipes.html"
  _doc_project 'echo ok'
  git -C "$WORKDIR" update-ref refs/remotes/origin/main HEAD
  git -C "$WORKDIR" rm -q a.sh
  git -C "$WORKDIR" commit -q -m remove
  CMD="$(_documented_cmd "$doc")" yq -n '.preflight_commands = [strenv(CMD)]' > "$BATS_TEST_TMPDIR/cfg.yaml"
  run env HOME="$BATS_TEST_TMPDIR/home" bash "$runner" --key preflight_commands --config "$BATS_TEST_TMPDIR/cfg.yaml" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
}

# ============================================================================
# --diff: only added lines are reported
# ============================================================================

@test "--diff: deleting a line does not report the unchanged lines of the file" {
  _diff_repo
  printf '%s\n' 'jq ".a[$k]" f' > "$WORKDIR/a.sh"
  _commit_all
  run bash "$SCRIPT" --diff 'HEAD~1...HEAD' --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings == [] and .files_scanned == 1' "$REPORT"
}

@test "--diff: a finding on an added line is reported with color.diff=always set" {
  _diff_repo
  git -C "$WORKDIR" config color.diff always
  printf '%s\n' 'jq ".b[$k]" f' >> "$WORKDIR/a.sh"
  _commit_all
  run bash "$SCRIPT" --diff 'HEAD~1...HEAD' --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length == 1 and .[0].file == "a.sh" and .[0].line == 3' "$REPORT"
}

@test "--diff: a finding on an added line is reported with an external diff tool set" {
  _diff_repo
  git -C "$WORKDIR" config diff.external /usr/bin/true
  printf '%s\n' 'jq ".b[$k]" f' >> "$WORKDIR/a.sh"
  _commit_all
  run bash "$SCRIPT" --diff 'HEAD~1...HEAD' --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length == 1 and .[0].line == 3' "$REPORT"
}

@test "--diff: a finding on an added line is reported with a textconv filter set" {
  _diff_repo
  printf '*.sh diff=blank\n' > "$WORKDIR/.gitattributes"
  _commit_all
  git -C "$WORKDIR" config diff.blank.textconv /usr/bin/true
  printf '%s\n' 'jq ".b[$k]" f' >> "$WORKDIR/a.sh"
  _commit_all
  run bash "$SCRIPT" --diff 'HEAD~1...HEAD' --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length == 1 and .[0].line == 3' "$REPORT"
}

# ============================================================================
# File names containing colons
# ============================================================================

@test "file name with a colon: --diff reports the finding against the right file" {
  git -C "$WORKDIR" init -q -b main
  git -C "$WORKDIR" config user.email t@example.invalid
  git -C "$WORKDIR" config user.name t
  git -C "$WORKDIR" commit -q --allow-empty -m base
  printf '%s\n' 'jq ".a[$k]" f' > "$WORKDIR/a:b.sh"
  _commit_all
  run bash "$SCRIPT" --diff 'HEAD~1...HEAD' --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length == 1 and .[0].file == "a:b.sh" and .[0].line == 1' "$REPORT"
}

@test "file name with a colon: --files with two files writes a valid report" {
  printf '%s\n' 'echo ok' 'jq ".a[$k]" f' > "$WORKDIR/a:b.sh"
  printf '%s\n' 'jq ".c[$k]" f' > "$WORKDIR/c.sh"
  run bash "$SCRIPT" --files a:b.sh c.sh --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '[.findings[] | [.file, .line]] == [["a:b.sh", 2], ["c.sh", 1]]' "$REPORT"
}

@test "file name with a colon and digits: --files reports the whole name" {
  printf '%s\n' 'jq ".a[$k]" f' > "$WORKDIR/a:1:b.sh"
  run bash "$SCRIPT" --files a:1:b.sh --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length == 1 and .[0].file == "a:1:b.sh" and .[0].line == 1' "$REPORT"
}

@test "file name with a colon: a continuation-line program is reported against the right file" {
  printf '%s\n' 'jq \' '  ".a[$x]" f' > "$WORKDIR/a:1:b.sh"
  run bash "$SCRIPT" --files a:1:b.sh --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length == 1 and .[0].file == "a:1:b.sh" and .[0].line == 2' "$REPORT"
}

# Every rule that parses located grep output, in one-file and two-file form.
_colon_fixtures() {
  local cfg="$1" q="'"
  _write_leak_config "$cfg"
  mkdir -p "$WORKDIR/pub"
  {
    printf 'echo first\n'
    printf 'api_key = "%s%s"\n' 'abcdefgh' '0123456789abcdef'
    printf 'h() { local -''A m; }\n'
    printf 'map''file arr < f\n'
    printf 'echo "${v,'',}"\n'
    printf 'sed -i %s%s s/a/b/ f\n' "$q" "$q"
    printf 'echo see %s\n' "FR-""7"
  } > "$WORKDIR/pub/x:1:y.sh"
  printf 'run thing |''| skip\n' > "$WORKDIR/pub/t:2:z.bats"
}

_assert_colon_findings() {
  jq -e '[.findings[] | select(.file == "pub/x:1:y.sh") | [.rule, .line]] | sort ==
    [["bash4-constructs",3],["bash4-constructs",4],["bash4-constructs",5],
     ["hardcoded-credentials",2],["leaked-identifiers",7],["sed-inplace",6]]' "$REPORT"
}

@test "file name with a colon: every rule reports the right file and line for several files" {
  local cfg="$BATS_TEST_TMPDIR/lp.yaml"
  _colon_fixtures "$cfg"
  run bash "$SCRIPT" --files pub/x:1:y.sh pub/t:2:z.bats --config "$cfg" --exclude bash-syntax --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  _assert_colon_findings
  jq -e '[.findings[] | select(.file == "pub/t:2:z.bats") | [.rule, .line]] == [["skip-in-red-test",1]]' "$REPORT"
}

@test "file name with a colon: every rule reports the right file and line for one file" {
  local cfg="$BATS_TEST_TMPDIR/lp.yaml"
  _colon_fixtures "$cfg"
  run bash "$SCRIPT" --files pub/x:1:y.sh --config "$cfg" --exclude bash-syntax --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  _assert_colon_findings
  run bash "$SCRIPT" --files pub/t:2:z.bats --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length == 1 and .[0].file == "pub/t:2:z.bats" and .[0].line == 1' "$REPORT"
}

@test "suppression marker still applies to a located hit" {
  printf '%s\n' 'jq ".a[$k]" f # lint-pack:allow spliced-yq-jq' > "$WORKDIR/a:b.sh"
  printf '%s\n' 'echo ok' > "$WORKDIR/c.sh"
  run bash "$SCRIPT" --files a:b.sh c.sh --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
}

# ============================================================================
# Leak rule: long lines
# ============================================================================

# Cost is bounded in CPU seconds, not wall-clock time, so other work on the
# machine does not decide the result.  A scan that grows with the square of the
# line length needs many minutes for this input and is killed by the limit.
@test "leaked-identifiers: a 1 MB line with a hit stays within the CPU limit" {
  local cfg="$BATS_TEST_TMPDIR/lp.yaml"
  _write_leak_config "$cfg"
  mkdir -p "$WORKDIR/pub"
  awk -v id="FR-""1" 'BEGIN { for (i = 0; i < 500000; i++) printf "a "; print id " tail" }' > "$WORKDIR/pub/m.js"
  run bash -c 'ulimit -t 30; exec bash "$@"' _ "$SCRIPT" --files pub/m.js --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length == 1 and .[0].file == "pub/m.js" and .[0].line == 1' "$REPORT"
}

@test "leaked-identifiers: occurrence counts on a long line match those on a short line" {
  local cfg="$BATS_TEST_TMPDIR/lp.yaml" id="FR-""9" pad
  _write_leak_config "$cfg"
  mkdir -p "$WORKDIR/pub"
  pad="$(awk 'BEGIN { for (i = 0; i < 40000; i++) printf "a " }')"
  # The identifier only in the grep pattern: carved out.
  printf "grep -E '%s' f # %s\n" "$id" "$pad" > "$WORKDIR/pub/carved.sh"
  # The same identifier again after the pattern: flagged.
  printf "grep -E '%s' f # %s %s\n" "$id" "$pad" "$id" > "$WORKDIR/pub/both.sh"
  run bash "$SCRIPT" --files pub/both.sh pub/carved.sh --exclude bash-syntax --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length == 1 and .[0].file == "pub/both.sh"' "$REPORT"
}

@test "leaked-identifiers: a long-line count treats the identifier as a literal string" {
  local cfg="$BATS_TEST_TMPDIR/lint-pack.yaml" pad
  cat > "$cfg" <<'YAML'
lint_pack:
  leaked_identifiers:
    patterns:
      - "x[*?][0-9]+"
    published_paths:
      - "pub/"
YAML
  mkdir -p "$WORKDIR/pub"
  pad="$(awk 'BEGIN { for (i = 0; i < 40000; i++) printf "a " }')"
  # Carved only: a pattern reading of x*12 would also count the text after it.
  printf "grep -E 'x*12' f # %s xAB12\n" "$pad" > "$WORKDIR/pub/carved.sh"
  run bash "$SCRIPT" --files pub/carved.sh --exclude bash-syntax --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
}

# ============================================================================
# --diff: a syntax error belongs to the file, not to a line
# ============================================================================

_syntax_repo() {
  git -C "$WORKDIR" init -q -b main
  git -C "$WORKDIR" config user.email t@example.invalid
  git -C "$WORKDIR" config user.name t
  printf '%s\n' "$@" > "$WORKDIR/a.sh"
  _commit_all
}

@test "--diff: a syntax error caused by deleting a line fires" {
  _syntax_repo '#!/bin/bash' 'if true; then' 'echo a' 'fi' 'echo done'
  printf '%s\n' '#!/bin/bash' 'if true; then' 'echo a' 'echo done' > "$WORKDIR/a.sh"
  _commit_all
  run bash "$SCRIPT" --diff 'HEAD~1...HEAD' --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length == 1 and .[0].rule == "bash-syntax" and .[0].file == "a.sh"' "$REPORT"
}

@test "--diff: an added unterminated block, reported at end of file, fires" {
  _syntax_repo '#!/bin/bash' 'echo a' 'echo b'
  printf '%s\n' 'if true; then' >> "$WORKDIR/a.sh"
  _commit_all
  run bash "$SCRIPT" --diff 'HEAD~1...HEAD' --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length == 1 and .[0].rule == "bash-syntax" and .[0].file == "a.sh"' "$REPORT"
}

@test "--diff: a syntax error on an added line still fires" {
  _syntax_repo '#!/bin/bash' 'echo a' 'echo b'
  printf '%s\n' '#!/bin/bash' 'echo a' ')' 'echo b' > "$WORKDIR/a.sh"
  _commit_all
  run bash "$SCRIPT" --diff 'HEAD~1...HEAD' --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length == 1 and .[0].rule == "bash-syntax" and .[0].file == "a.sh" and .[0].line == 3' "$REPORT"
}

# ============================================================================
# --diff: a file git treats as binary has no line data, so all of it is scanned
# ============================================================================

_credential_line() {
  local value="abcdefghij""0123456789"
  printf 'token="%s"%s\n' "$value" "${1:-}"
}

_binary_attr_repo() {
  git -C "$WORKDIR" init -q -b main
  git -C "$WORKDIR" config user.email t@example.invalid
  git -C "$WORKDIR" config user.name t
  printf '*.json -diff\n' > "$WORKDIR/.gitattributes"
  printf '{}\n' > "$WORKDIR/a.json"
  printf '%s\n' 'jq ".a[$k]" f' 'echo two' > "$WORKDIR/n.sh"
  _commit_all
}

@test "--diff: a credential on an added line of a file git treats as binary fires" {
  _binary_attr_repo
  _credential_line >> "$WORKDIR/a.json"
  _commit_all
  run bash "$SCRIPT" --diff 'HEAD~1...HEAD' --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length == 1 and .[0].rule == "hardcoded-credentials" and .[0].file == "a.json" and .[0].line == 2' "$REPORT"
}

@test "--diff: the same with a second, normal changed file fires" {
  _binary_attr_repo
  _credential_line >> "$WORKDIR/a.json"
  printf 'echo three\n' >> "$WORKDIR/n.sh"
  _commit_all
  run bash "$SCRIPT" --diff 'HEAD~1...HEAD' --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  # The normal file keeps the added-lines filter: its old splice stays out.
  jq -e '.files_scanned == 2 and (.findings | length == 1 and .[0].file == "a.json" and .[0].line == 2)' "$REPORT"
}

@test "--diff: a deletion-only change in a normal file stays rc 0" {
  _binary_attr_repo
  printf '%s\n' 'jq ".a[$k]" f' > "$WORKDIR/n.sh"
  _commit_all
  run bash "$SCRIPT" --diff 'HEAD~1...HEAD' --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings == [] and .files_scanned == 1' "$REPORT"
}

# ============================================================================
# Behaviour no other test pins
# ============================================================================

@test "--files with --diff scans only the listed files" {
  _diff_repo
  printf '%s\n' 'jq ".a[$k]" f' > "$WORKDIR/z.sh"
  _commit_all
  run bash "$SCRIPT" --files keep.sh --diff 'HEAD~1...HEAD' --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings == [] and .files_scanned == 1' "$REPORT"
}

@test "leaked-identifiers: a long carve-out region without the identifier does not exit 2" {
  local cfg="$BATS_TEST_TMPDIR/lp.yaml" id="FR-""1" program
  _write_leak_config "$cfg"
  mkdir -p "$WORKDIR/pub"
  program="$(awk 'BEGIN { for (i = 0; i < 2500; i++) printf "a " }')"
  # Longer than the builtin count allows, and holds no occurrence to count.
  printf "pattern=%s; sed 's/%s/b/' f\n" "$id" "$program" > "$WORKDIR/pub/s.sh"
  run bash "$SCRIPT" --files pub/s.sh --exclude bash-syntax --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  jq -e '.findings == []' "$REPORT"
}

@test "spliced-yq-jq: a colon in the source before the splice fires" {
  printf '%s\n' 'jq ".a:b[$k]" f' > "$WORKDIR/c.sh"
  run bash "$SCRIPT" --files c.sh --exclude bash-syntax --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length == 1 and .[0].rule == "spliced-yq-jq" and .[0].file == "c.sh" and .[0].line == 1' "$REPORT"
}

@test "leaked-identifiers: an anchored pattern fires with a file name before the text" {
  local cfg="$BATS_TEST_TMPDIR/lp.yaml" prefix="FR" sep="-"
  cat > "$cfg" <<YAML
lint_pack:
  leaked_identifiers:
    patterns:
      - "^${prefix}${sep}[0-9]+"
    published_paths:
      - "pub/"
YAML
  mkdir -p "$WORKDIR/pub"
  printf '%s%s1 x\n' "$prefix" "$sep" > "$WORKDIR/pub/a.md"
  run bash "$SCRIPT" --files pub/a.md --config "$cfg" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length == 1 and .[0].rule == "leaked-identifiers" and .[0].file == "pub/a.md" and .[0].line == 1' "$REPORT"
}

@test "hardcoded-credentials: allow marker suppresses a hit" {
  _credential_line ' # lint-pack:allow hardcoded-credentials' > "$WORKDIR/a.txt"
  _credential_line > "$WORKDIR/b.txt"
  run bash "$SCRIPT" --files a.txt b.txt --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length == 1 and .[0].rule == "hardcoded-credentials" and .[0].file == "b.txt"' "$REPORT"
}

@test "sed-inplace: allow marker suppresses a hit" {
  local q="'"
  printf 'sed -i %s%s s/a/b/ f # lint-pack:%s sed-inplace\n' "$q" "$q" allow > "$WORKDIR/a.sh"
  printf 'sed -i %s%s s/a/b/ f\n' "$q" "$q" > "$WORKDIR/b.sh"
  run bash "$SCRIPT" --files a.sh b.sh --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length == 1 and .[0].rule == "sed-inplace" and .[0].file == "b.sh"' "$REPORT"
}

# --- Containment: --rules-dir refuses symlinked rules outside library ---

@test "--rules-dir: symlinked rule dir outside library is skipped" {
  local outside; outside="$(mktemp -d "$BATS_TEST_TMPDIR/outside-XXXXXX")"
  cat > "$outside/rule.lint" <<'LINT'
id: escape-dir
message: "escaped dir"
severity: high
languages: [".sh"]
pattern: "ESCAPED"
LINT
  local lib="$BATS_TEST_TMPDIR/rules"
  mkdir -p "$lib"
  ln -s "$outside" "$lib/escape-dir"
  printf 'ESCAPED\n' > "$WORKDIR/target.sh"
  run bash "$SCRIPT" --files target.sh --rules-dir "$lib" --report "$REPORT" --workdir "$WORKDIR"
  # The symlinked rule should NOT fire because it resolves outside the library.
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
}

@test "--rules-dir: symlinked rule.lint file outside library is skipped" {
  local outside; outside="$(mktemp -d "$BATS_TEST_TMPDIR/outside-XXXXXX")"
  cat > "$outside/rule.lint" <<'LINT'
id: escape-file
message: "escaped file"
severity: high
languages: [".sh"]
pattern: "ESCAPED"
LINT
  local lib="$BATS_TEST_TMPDIR/rules2"
  mkdir -p "$lib/escape-file"
  ln -s "$outside/rule.lint" "$lib/escape-file/rule.lint"
  printf 'ESCAPED\n' > "$WORKDIR/target.sh"
  run bash "$SCRIPT" --files target.sh --rules-dir "$lib" --report "$REPORT" --workdir "$WORKDIR"
  # The symlinked rule file should NOT fire.
  [ "$status" -eq 0 ]
  jq -e '.findings | length == 0' "$REPORT"
}

@test "--rules-dir: rule inside library fires normally" {
  local lib="$BATS_TEST_TMPDIR/rules3"
  mkdir -p "$lib/normal-rule"
  cat > "$lib/normal-rule/rule.lint" <<'LINT'
id: normal-rule
message: "normal rule fired"
severity: high
languages: [".sh"]
pattern: "FLAGGED_TOKEN"
LINT
  printf 'FLAGGED_TOKEN\n' > "$WORKDIR/target.sh"
  run bash "$SCRIPT" --files target.sh --rules-dir "$lib" --report "$REPORT" --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  jq -e '.findings | length == 1 and .[0].rule == "normal-rule"' "$REPORT"
}
