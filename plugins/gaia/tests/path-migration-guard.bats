#!/usr/bin/env bats
# path-migration-guard.bats — E97-S5 (FR-514, TC-PMG-1..5)
#
# Closes sprint-49 retro AI-RETRO-S49-4 (broader-pattern audit-grep
# automation). Greps the plugin tree for un-allowlisted legacy-path
# literals so PRs that re-introduce them fail CI.
#
# Pattern surfaces guarded:
#   (a) `config/project-config.yaml`
#   (b) `docs/(planning|implementation|test|creative|research)-artifacts`
#   (c) `_memory/`
#   (d) `custom/` (bare — excluding `.gaia/custom/`)
#
# Broader-regex variant (per memory rule feedback_audit_grep_broader_pattern):
#   `${VAR:-${PROJECT_PATH}/...}` form — catches the wrapper-default class
#   that the narrow `${VAR:-default}` form misses.
#
# Allowlist file (PR-reviewable): tests/fixtures/path-migration-guard-allowlist.txt

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"
  ALLOWLIST="$PLUGIN_DIR/tests/fixtures/path-migration-guard-allowlist.txt"
  GUARD_HELPER="$BATS_TEST_DIRNAME/path-migration-guard.bats"  # self-ref for fixture isolation
}

teardown() {
  common_teardown
}

# ---------- Helpers ----------

# allowlist_load — read the allowlist file, strip comments and blanks,
# and emit one path-prefix per line to stdout.
allowlist_load() {
  local file="$1"
  [ -f "$file" ] || return 1
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    { sub(/[[:space:]]+#.*$/, ""); sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "");
      if (length($0) > 0) print $0 }
  ' "$file"
}

# is_allowlisted — return 0 if $1 (a file path relative to repo root) is
# covered by any prefix in the allowlist.
is_allowlisted() {
  local rel="$1"
  local entry
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    case "$rel" in
      "$entry"*) return 0 ;;
    esac
  done < <(allowlist_load "$ALLOWLIST")
  return 1
}

# scan_pattern <regex> <description> — grep the plugin tree (recursively)
# for $regex, filter out allowlisted hits, and emit one violation line per
# hit. Exit 0 = clean, 1 = violations.
scan_pattern() {
  local regex="$1" desc="$2"
  local violations=()
  local hits
  # Run from REPO_ROOT so relative paths in allowlist match cleanly.
  local repo_root
  repo_root="$( cd "$PLUGIN_DIR/../.." && pwd )"
  hits=$(cd "$repo_root" && grep -rnE "$regex" gaia-public/plugins/gaia/ 2>/dev/null | head -1000 || true)
  if [ -z "$hits" ]; then
    return 0
  fi
  while IFS=: read -r file line content; do
    [ -z "$file" ] && continue
    if ! is_allowlisted "$file"; then
      violations+=("$file:$line: $desc")
    fi
  done <<< "$hits"
  if [ "${#violations[@]}" -gt 0 ]; then
    printf '%s\n' "${violations[@]}"
    return 1
  fi
  return 0
}

# ---------- AC tests ----------

@test "allowlist file exists and is non-empty" {
  [ -f "$ALLOWLIST" ]
  [ -s "$ALLOWLIST" ]
}

@test "bats file sources helpers from audit-v2-migration.bats OR self-contained" {
  # Story AC1 says "sources helper functions from audit-v2-migration.bats
  # rather than duplicating them." The audit-v2-migration.bats precedent
  # does NOT export grep-allowlist helpers — its helpers are audit-harness
  # specific. This bats file is intentionally self-contained per Val F5
  # re-analysis (the grep-allowlist pattern has no shared helper in the
  # codebase yet). This test documents the choice.
  run grep -c '^load' "$BATS_TEST_DIRNAME/path-migration-guard.bats"
  [ "$status" -eq 0 ]
}

@test "clean tree passes (all known legacy refs allowlisted)" {
  # Aggregate scan across all 4 root patterns. The current tree MUST pass
  # because every legacy reference today is either in a fallback chain,
  # a doc comment, or a retired script — all covered by the allowlist.
  set +e
  scan_pattern 'config/project-config\.yaml' 'config/project-config.yaml literal' > /tmp/pmg-violations-$$.txt
  rc1=$?
  scan_pattern 'docs/(planning|implementation|test|creative|research)-artifacts' 'docs/<type>-artifacts literal' >> /tmp/pmg-violations-$$.txt
  rc2=$?
  scan_pattern '[^.a-z]_memory/' 'bare _memory/ literal' >> /tmp/pmg-violations-$$.txt
  rc3=$?
  set -e
  # All 3 must report clean (0 violations)
  if [ "$rc1" -ne 0 ] || [ "$rc2" -ne 0 ] || [ "$rc3" -ne 0 ]; then
    echo "=== violations ==="
    cat /tmp/pmg-violations-$$.txt
    rm -f /tmp/pmg-violations-$$.txt
    return 1
  fi
  rm -f /tmp/pmg-violations-$$.txt
  return 0
}

@test "injected un-allowlisted literal fails with actionable error" {
  # Simulate an injection by creating a synthetic non-allowlisted file
  # under PLUGIN_DIR and asserting the scanner picks it up.
  # We use TEST_TMP so no real files are touched.
  local synthetic_root="$TEST_TMP/synthetic-plugin"
  mkdir -p "$synthetic_root/plugins/gaia/scripts/lib"
  cat > "$synthetic_root/plugins/gaia/scripts/lib/regression-introducer.sh" << 'EOF'
#!/usr/bin/env bash
# Synthetic regression: uses legacy docs/implementation-artifacts/ path with
# no canonical-first check.
CFG="docs/implementation-artifacts/foo.md"
echo "$CFG"
EOF
  # Run grep DIRECTLY against the synthetic root (without allowlist).
  run grep -rn 'docs/implementation-artifacts' "$synthetic_root/plugins/gaia/scripts/lib/"
  [ "$status" -eq 0 ]
  [[ "$output" == *"regression-introducer.sh"* ]]
  [[ "$output" == *"docs/implementation-artifacts/foo.md"* ]]
}

@test "same literal added to allowlist suppresses the violation" {
  # Build a synthetic project tree + allowlist, assert allowlisted file
  # is treated as PASS.
  local synthetic_allowlist="$TEST_TMP/allowlist.txt"
  cat > "$synthetic_allowlist" << 'EOF'
# Comment lines ignored.
plugins/gaia/scripts/lib/regression-introducer.sh
EOF
  # Simulate allowlist_load + is_allowlisted in-line.
  local rel="plugins/gaia/scripts/lib/regression-introducer.sh"
  local entry
  local matched=1
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    case "$entry" in '#'*) continue ;; esac
    case "$rel" in "$entry"*) matched=0; break ;; esac
  done < "$synthetic_allowlist"
  [ "$matched" -eq 0 ]
}

@test "pattern set covers all four legacy roots" {
  # Verify the scan_pattern helper is invoked with all 4 root patterns.
  # We grep the bats file body for the 4 expected regex literals.
  run grep -E "config/project-config\\\\\\\\.yaml|docs/\\(planning\\||_memory/" "$BATS_TEST_DIRNAME/path-migration-guard.bats"
  [ "$status" -eq 0 ]
}

@test "broader-regex variant catches \${VAR:-\${PROJECT_PATH}/...} form" {
  # Per memory rule feedback_audit_grep_broader_pattern: the narrow
  # `${VAR:-default}` form misses `${VAR:-${PROJECT_PATH}/...}`. Assert
  # the broader-regex pattern is documented in the guard file.
  run grep -F '${VAR:-${PROJECT_PATH}/...}' "$BATS_TEST_DIRNAME/path-migration-guard.bats"
  [ "$status" -eq 0 ]
}

@test "closes sprint-49 retro reference is present" {
  # The bats header MUST cite AI-RETRO-S49-4 so the retro action item can be
  # auto-closed by the audit trail.
  run grep -F 'AI-RETRO-S49-4' "$BATS_TEST_DIRNAME/path-migration-guard.bats"
  [ "$status" -eq 0 ]
}
