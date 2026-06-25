#!/usr/bin/env bats
# bash32-portability-lint.bats — CI lint for Bash 4+ constructs in host-facing scripts
#
# Validates:
#   AC1: cross-refs-walk.sh contains no Bash 4+ constructs (associative arrays,
#        declare -g, mapfile/readarray, case-modification expansions, negative indices).
#   AC2: Tree-wide scan of scripts/ and scripts/lib/ catches all violations.
#   AC3: The CI lint scanner correctly identifies Bash 4+ constructs.
#   AC4: A planted violation in a fixture is caught (negative test).
#
# Usage:
#   bats tests/skills/bash32-portability-lint.bats
#
# Dependencies: bats-core 1.10+

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCANNER="$REPO_ROOT/.github/scripts/lint-bash32-portability.sh"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"
  FIXTURE_DIR="$(mktemp -d -t bash32lint.XXXXXX)"
}

teardown() {
  rm -rf "$FIXTURE_DIR"
}

# ---------- cross-refs-walk.sh contains no associative arrays (AC1) ----------

@test "cross-refs-walk.sh contains no declare -gA (AC1)" {
  run grep -n 'declare -gA' "$SCRIPTS_DIR/cross-refs-walk.sh"
  [ "$status" -ne 0 ]
}

@test "cross-refs-walk.sh contains no declare -A (AC1)" {
  # Exclude comment lines (lines starting with optional whitespace then #)
  run bash -c 'grep -n "declare -A" "$1" | grep -v "^[[:space:]]*#" | grep -v "^[0-9]*:[[:space:]]*#"' _ "$SCRIPTS_DIR/cross-refs-walk.sh"
  [ "$status" -ne 0 ]
}

# ---------- discovery-firewall-guard.sh contains no associative arrays (AC2) ----------

@test "discovery-firewall-guard.sh contains no declare -A (AC2)" {
  run bash -c 'grep -n "declare -A" "$1" | grep -v "^[[:space:]]*#" | grep -v "^[0-9]*:[[:space:]]*#"' _ "$SCRIPTS_DIR/discovery-firewall-guard.sh"
  [ "$status" -ne 0 ]
}

# ---------- Tree-wide scanner catches violations (AC3) ----------

@test "scanner passes on a clean scripts tree (AC3)" {
  # Create a minimal fixture tree with clean scripts
  mkdir -p "$FIXTURE_DIR/scripts/lib"
  cat > "$FIXTURE_DIR/scripts/clean.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
my_var="hello"
echo "$my_var"
SH
  cat > "$FIXTURE_DIR/scripts/lib/helper.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "helper"
SH
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -eq 0 ]
}

@test "scanner rejects declare -gA in a script (AC3)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  cat > "$FIXTURE_DIR/scripts/bad.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
declare -gA mymap=()
echo "${mymap[key]}"
SH
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"declare -gA"* ]]
}

@test "scanner rejects declare -A in a script (AC3)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  cat > "$FIXTURE_DIR/scripts/bad2.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
declare -A mymap=()
SH
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"declare -A"* ]]
}

@test "scanner rejects mapfile usage (AC3)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  cat > "$FIXTURE_DIR/scripts/mapfile-bad.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
mapfile -t lines < somefile.txt
SH
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mapfile"* ]]
}

@test "scanner rejects readarray usage (AC3)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  cat > "$FIXTURE_DIR/scripts/readarray-bad.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
readarray -t lines < somefile.txt
SH
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"readarray"* ]]
}

@test "scanner rejects case-modification expansion (AC3)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  # Use printf to avoid shell interpreting the expansion at write time
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho "${var,,}"\n' \
    > "$FIXTURE_DIR/scripts/case-bad.sh"
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -ne 0 ]
}

@test "scanner ignores violations inside comments (AC3)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  cat > "$FIXTURE_DIR/scripts/commented.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# Note: we avoid declare -A for bash 3.2 compatibility
# Previously used: declare -gA _map=()
# Compat: no mapfile, no ${var,,}.
echo "clean"
SH
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -eq 0 ]
}

@test "scanner ignores non-.sh files (AC3)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  cat > "$FIXTURE_DIR/scripts/notes.txt" <<'TXT'
declare -gA mymap=()
mapfile -t lines < file
TXT
  cat > "$FIXTURE_DIR/scripts/clean.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "ok"
SH
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -eq 0 ]
}

# ---------- Negative test: planted fixture trips the check (AC4) ----------

@test "planted declare -gA fixture trips the scanner (AC4)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  cat > "$FIXTURE_DIR/scripts/planted-violation.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
declare -gA _FIXTURE_MAP=()
echo "this should fail the lint"
SH
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"planted-violation.sh"* ]]
  [[ "$output" == *"declare -gA"* ]]
}

# ---------- Scanner supports allowlist for guarded scripts (AC3) ----------

@test "scanner respects bash-version-guard allowlist (AC3)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  # A script with a proper bash-version guard should be allowlisted
  cat > "$FIXTURE_DIR/scripts/guarded.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# bash32-portability-lint: skip (requires bash >= 4.0; guarded by preflight check)
declare -A mymap=()
SH
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -eq 0 ]
}

# ---------- Functional: cross-refs-walk.sh cycle detection still works (AC1) ----------

@test "cross-refs-walk.sh cycle detection produces CYCLE DETECTED on circular config (AC1)" {
  mkdir -p "$FIXTURE_DIR"
  cat > "$FIXTURE_DIR/cycle-config.yaml" <<'YAML'
stacks:
  - name: alpha
    path: alpha/
    cross_refs: [beta]
  - name: beta
    path: beta/
    cross_refs: [alpha]
YAML
  run bash "$SCRIPTS_DIR/cross-refs-walk.sh" --config "$FIXTURE_DIR/cycle-config.yaml" --stacks '["alpha"]'
  [ "$status" -eq 0 ]
  # Cycle detected → escalated to full suite ["*"]
  [[ "$output" == *'["*"]'* ]]
}

@test "cross-refs-walk.sh transitive walk returns correct dependants (AC1)" {
  mkdir -p "$FIXTURE_DIR"
  cat > "$FIXTURE_DIR/walk-config.yaml" <<'YAML'
stacks:
  - name: core
    path: core/
  - name: api
    path: api/
    cross_refs: [core]
  - name: web
    path: web/
    cross_refs: [api]
YAML
  run bash "$SCRIPTS_DIR/cross-refs-walk.sh" --config "$FIXTURE_DIR/walk-config.yaml" --stacks '["core"]'
  [ "$status" -eq 0 ]
  # core → api (depends on core) → web (depends on api)
  [[ "$output" == *"core"* ]]
  [[ "$output" == *"api"* ]]
  [[ "$output" == *"web"* ]]
}

@test "cross-refs-walk.sh empty seed returns empty array (AC1)" {
  mkdir -p "$FIXTURE_DIR"
  cat > "$FIXTURE_DIR/empty-config.yaml" <<'YAML'
stacks:
  - name: core
    path: core/
YAML
  run bash "$SCRIPTS_DIR/cross-refs-walk.sh" --config "$FIXTURE_DIR/empty-config.yaml" --stacks '[]'
  [ "$status" -eq 0 ]
  [[ "$output" == "[]" ]]
}

@test "cross-refs-walk.sh wildcard seed passes through (AC1)" {
  mkdir -p "$FIXTURE_DIR"
  cat > "$FIXTURE_DIR/wildcard-config.yaml" <<'YAML'
stacks:
  - name: core
    path: core/
YAML
  run bash "$SCRIPTS_DIR/cross-refs-walk.sh" --config "$FIXTURE_DIR/wildcard-config.yaml" --stacks '["*"]'
  [ "$status" -eq 0 ]
  [[ "$output" == '["*"]' ]]
}

# ---------- Tree-wide: actual scripts tree passes the lint (AC2) ----------

@test "scripts tree passes bash-3.2 portability lint (AC2)" {
  run bash "$SCANNER" "$SCRIPTS_DIR"
  [ "$status" -eq 0 ]
}
