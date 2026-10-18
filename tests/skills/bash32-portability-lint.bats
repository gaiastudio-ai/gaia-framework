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
  BASELINE="$REPO_ROOT/.github/scripts/bash32-portability-baseline.tsv"
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

# ---------- New construct fixture tests: local -A (AC3) ----------

@test "scanner rejects local -A in a function (AC3)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  cat > "$FIXTURE_DIR/scripts/local-a.sh" <<'SH'
#!/usr/bin/env bash
my_func() {
  local -A myarray
  myarray[key]="val"
}
SH
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"local -A"* ]]
}

# ---------- New construct fixture tests: typeset -A (AC3) ----------

@test "scanner rejects typeset -A (AC3)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  cat > "$FIXTURE_DIR/scripts/typeset-a.sh" <<'SH'
#!/usr/bin/env bash
my_func() {
  typeset -A myarray
  myarray[key]="val"
}
SH
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"typeset -A"* ]]
}

# ---------- New construct fixture tests: local -n (AC3) ----------

@test "scanner rejects local -n (AC3)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  cat > "$FIXTURE_DIR/scripts/local-n.sh" <<'SH'
#!/usr/bin/env bash
my_func() {
  local -n ref=target
  echo "$ref"
}
SH
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"local -n"* ]]
}

# ---------- New construct fixture tests: local -g (AC3) ----------

@test "scanner rejects local -g (AC3)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  cat > "$FIXTURE_DIR/scripts/local-g.sh" <<'SH'
#!/usr/bin/env bash
my_func() {
  local -g myvar="hello"
  echo "$myvar"
}
SH
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"local -g"* ]]
}

# ---------- New construct fixture tests: [[ -v (AC3) ----------

@test "scanner rejects [[ -v variable-set test (AC3)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  cat > "$FIXTURE_DIR/scripts/test-v.sh" <<'SH'
#!/usr/bin/env bash
if [[ -v MY_VAR ]]; then
  echo "set"
fi
SH
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"[[ -v"* ]]
}

# ---------- New construct fixture tests: &>> (AC3) ----------

@test "scanner rejects &>> append-redirect (AC3)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  cat > "$FIXTURE_DIR/scripts/append-redir.sh" <<'SH'
#!/usr/bin/env bash
echo "hello" &>> /tmp/log.txt
SH
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"&>>"* ]]
}

# ---------- New construct fixture tests: |& (AC3) ----------

@test "scanner rejects |& pipe-stderr (AC3)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  cat > "$FIXTURE_DIR/scripts/pipe-stderr.sh" <<'SH'
#!/usr/bin/env bash
some_cmd |& grep "error"
SH
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"|&"* ]]
}

# ---------- New construct fixture tests: coproc (AC3) ----------

@test "scanner rejects coproc (AC3)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  cat > "$FIXTURE_DIR/scripts/coproc.sh" <<'SH'
#!/usr/bin/env bash
coproc mycoproc { cat; }
SH
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"coproc"* ]]
}

# ---------- New construct fixture tests: $BASHPID (AC3) ----------

@test "scanner rejects BASHPID variable (AC3)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\necho "pid=$BASHPID"\n' \
    > "$FIXTURE_DIR/scripts/bashpid.sh"
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"BASHPID"* ]]
}

# ---------- New construct fixture tests: read -i (AC3) ----------

@test "scanner rejects read -i (AC3)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  cat > "$FIXTURE_DIR/scripts/read-i.sh" <<'SH'
#!/usr/bin/env bash
read -e -i "default" -p "Enter: " val
SH
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"read"* ]]
}

# ---------- New construct fixture tests: read -N (AC3) ----------

@test "scanner rejects read -N (AC3)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  cat > "$FIXTURE_DIR/scripts/read-n.sh" <<'SH'
#!/usr/bin/env bash
read -N 5 chars
SH
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"read"* ]]
}

# ---------- New construct fixture tests: {var}> named-fd (AC3) ----------

@test "scanner rejects {var}> named-fd redirection (AC3)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  cat > "$FIXTURE_DIR/scripts/named-fd.sh" <<'SH'
#!/usr/bin/env bash
exec {myfd}>/tmp/out.txt
echo "hello" >&${myfd}
SH
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"{myfd}>"* ]]
}

# ---------- False positive: comment with local -A is ignored (AC-EC1) ----------

@test "scanner ignores local -A inside a comment (AC-EC1)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  cat > "$FIXTURE_DIR/scripts/comment-local-a.sh" <<'SH'
#!/usr/bin/env bash
# We avoid local -A for bash 3.2 compat
echo "clean"
SH
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -eq 0 ]
}

@test "scanner flags local -A in code but not on a comment line in same file (AC-EC1)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  cat > "$FIXTURE_DIR/scripts/mixed.sh" <<'SH'
#!/usr/bin/env bash
# We used to use: local -A mymap
my_func() {
  local -A actual_violation
}
SH
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -ne 0 ]
  # Only the code line is flagged — count violation lines (file:line: format),
  # not the summary on stderr which also mentions construct names.
  line_count="$(echo "$output" | grep -c 'mixed\.sh:[0-9]*:.*local -A')"
  [ "$line_count" -eq 1 ]
}

# ---------- False positive: variable expansion ${fd}>> is not named-fd (AC3) ----------

@test "scanner ignores variable expansion followed by redirect (AC3)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\neval "exec ${fd}>>\"${lock_file}\""\n' \
    > "$FIXTURE_DIR/scripts/var-redir.sh"
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -eq 0 ]
}

# ---------- False positive: |& inside regex strings is not pipe-stderr (AC3) ----------

@test "scanner ignores pipe-ampersand inside regex character class (AC3)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  cat > "$FIXTURE_DIR/scripts/regex-pipe.sh" <<'SH'
#!/usr/bin/env bash
pattern='(^|[;|&=`($])[[:space:]]*security'
echo "$pattern"
SH
  run bash "$SCANNER" "$FIXTURE_DIR/scripts"
  [ "$status" -eq 0 ]
}

# ---------- Multi-directory scanning (AC3) ----------

@test "scanner accepts multiple directory arguments (AC3)" {
  mkdir -p "$FIXTURE_DIR/dir1" "$FIXTURE_DIR/dir2"
  cat > "$FIXTURE_DIR/dir1/clean1.sh" <<'SH'
#!/usr/bin/env bash
echo "clean"
SH
  cat > "$FIXTURE_DIR/dir2/clean2.sh" <<'SH'
#!/usr/bin/env bash
echo "also clean"
SH
  run bash "$SCANNER" "$FIXTURE_DIR/dir1" "$FIXTURE_DIR/dir2"
  [ "$status" -eq 0 ]
}

@test "scanner catches violations across multiple directories (AC3)" {
  mkdir -p "$FIXTURE_DIR/dir1" "$FIXTURE_DIR/dir2"
  cat > "$FIXTURE_DIR/dir1/clean.sh" <<'SH'
#!/usr/bin/env bash
echo "clean"
SH
  cat > "$FIXTURE_DIR/dir2/bad.sh" <<'SH'
#!/usr/bin/env bash
my_func() {
  local -A badmap
}
SH
  run bash "$SCANNER" "$FIXTURE_DIR/dir1" "$FIXTURE_DIR/dir2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dir2/bad.sh"* ]]
}

# ---------- Skill scripts directory scanning (AC3) ----------

@test "scanner catches violations in skill scripts directory (AC3)" {
  mkdir -p "$FIXTURE_DIR/skills/myfoo/scripts"
  cat > "$FIXTURE_DIR/skills/myfoo/scripts/bar.sh" <<'SH'
#!/usr/bin/env bash
my_func() {
  local -A badmap
}
SH
  run bash "$SCANNER" "$FIXTURE_DIR/skills/myfoo/scripts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bar.sh"* ]]
}

# ---------- Tree-wide: actual directory trees pass the lint (AC4) ----------

@test "scripts tree passes bash-3.2 portability lint with baseline (AC4)" {
  # Run from REPO_ROOT so find produces relative paths matching the baseline.
  cd "$REPO_ROOT"
  run bash "$SCANNER" --baseline "$BASELINE" plugins/gaia/scripts
  [ "$status" -eq 0 ]
}

@test "skills scripts trees pass bash-3.2 portability lint with baseline (AC4)" {
  cd "$REPO_ROOT"
  # Collect all skills/*/scripts/ directories that exist
  local -a skill_dirs=()
  while IFS= read -r d; do
    [ -d "$d" ] && skill_dirs+=("$d")
  done < <(find plugins/gaia/skills -mindepth 2 -maxdepth 2 -name scripts -type d 2>/dev/null | sort)
  # Only run if there are skill scripts directories
  [ "${#skill_dirs[@]}" -gt 0 ] || return 0
  run bash "$SCANNER" --baseline "$BASELINE" "${skill_dirs[@]}"
  [ "$status" -eq 0 ]
}

# ---------- Baseline enforcement: new violations exceed ceiling (AC4) ----------

@test "baseline ceiling blocks a new violation in a baselined file (AC4)" {
  # Create a fixture with a baselined file that EXCEEDS its ceiling.
  mkdir -p "$FIXTURE_DIR/scripts"
  cat > "$FIXTURE_DIR/scripts/baselined.sh" <<'SH'
#!/usr/bin/env bash
my_func() {
  local -A first_violation
  local -A second_violation
}
SH
  # Baseline allows 1 violation, but the file has 2.
  printf '%s\t%s\n' "$FIXTURE_DIR/scripts/baselined.sh" "1" \
    > "$FIXTURE_DIR/baseline.tsv"
  run bash "$SCANNER" --baseline "$FIXTURE_DIR/baseline.tsv" "$FIXTURE_DIR/scripts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exceeds baseline ceiling"* ]]
}

@test "baseline ceiling allows violations at or below the ceiling (AC4)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  cat > "$FIXTURE_DIR/scripts/baselined.sh" <<'SH'
#!/usr/bin/env bash
my_func() {
  local -A one_violation
}
SH
  # Baseline allows 1 violation, file has exactly 1.
  printf '%s\t%s\n' "$FIXTURE_DIR/scripts/baselined.sh" "1" \
    > "$FIXTURE_DIR/baseline.tsv"
  run bash "$SCANNER" --baseline "$FIXTURE_DIR/baseline.tsv" "$FIXTURE_DIR/scripts"
  [ "$status" -eq 0 ]
}

@test "non-baselined file with violations fails even with a baseline file (AC4)" {
  mkdir -p "$FIXTURE_DIR/scripts"
  cat > "$FIXTURE_DIR/scripts/other.sh" <<'SH'
#!/usr/bin/env bash
my_func() {
  local -A unbaselined
}
SH
  # Baseline does not include this file.
  printf '%s\t%s\n' "some/other/file.sh" "1" \
    > "$FIXTURE_DIR/baseline.tsv"
  run bash "$SCANNER" --baseline "$FIXTURE_DIR/baseline.tsv" "$FIXTURE_DIR/scripts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no baseline; expected 0"* ]]
}
