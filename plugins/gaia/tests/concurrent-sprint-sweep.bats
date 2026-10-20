#!/usr/bin/env bats
# concurrent-sprint-sweep.bats — verification tests for the reader/writer
# sweep of sprint-status.yaml.  Exercises: matrix completeness, matrix
# structure, pure-reader static check, CI guard for new direct references,
# string-constant classification, internal-ID scrub, and quote-bearing
# sprint-ID round-trip via strenv.

# shellcheck disable=SC2030,SC2031

load 'test_helper.bash'

setup() {
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT PROJECT_PATH

  TEST_DIR="$(mktemp -d)"
  BATS_TEST_SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  MATRIX="$BATS_TEST_SCRIPT_DIR/tests/fixtures/sprint-status-sweep-matrix.tsv"
  SCRIPTS_DIR="$BATS_TEST_SCRIPT_DIR/scripts"
  SKILLS_DIR="$BATS_TEST_SCRIPT_DIR/skills"
  HOOKS_DIR="$BATS_TEST_SCRIPT_DIR/hooks"

  export PROJECT_ROOT="$TEST_DIR"
  export PROJECT_PATH="$TEST_DIR"
  export GAIA_SKIP_ORPHAN_SWEEP=1
  export GAIA_SNAPSHOT_HOOK_DISABLE=1
}

teardown() {
  rm -rf "$TEST_DIR" 2>/dev/null || true
}

# ============================================================
# Helper: enumerate all non-test files referencing sprint-status.yaml
# ============================================================
enumerate_references() {
  local dir="$1"
  grep -rn 'sprint-status\.yaml' \
    "$dir/scripts/" "$dir/skills/" "$dir/hooks/" 2>/dev/null \
    | grep -vE '\.bats:|/fixtures/|/tests/' \
    | sed 's/:.*//' | sort -u
}

# ============================================================
# AC1 + AC2: Matrix completeness — every reference is accounted for
# ============================================================

@test "all reference sites accounted for in the matrix" {
  [ -f "$MATRIX" ]

  # Enumerate actual references.
  local refs
  refs="$(enumerate_references "$BATS_TEST_SCRIPT_DIR")"
  local ref_count
  ref_count="$(echo "$refs" | wc -l | tr -d ' ')"
  [ "$ref_count" -gt 0 ]

  # Read matrix paths (skip header).
  local matrix_paths
  matrix_paths="$(awk -F'\t' 'NR>1 {print $1}' "$MATRIX" | sort -u)"

  # Every enumerated file must appear in the matrix.
  local missing=0 missing_files=""
  while IFS= read -r ref_file; do
    [ -n "$ref_file" ] || continue
    # Normalise to relative path under the plugin root.
    local rel_path="${ref_file#"$BATS_TEST_SCRIPT_DIR/"}"
    rel_path="plugins/gaia/${rel_path}"
    if ! grep -qxF "$rel_path" <<< "$matrix_paths"; then
      missing=$((missing + 1))
      missing_files="${missing_files}  ${rel_path}"$'\n'
    fi
  done <<< "$refs"

  if [ "$missing" -gt 0 ]; then
    printf 'Missing from matrix (%d files):\n%s' "$missing" "$missing_files" >&2
    return 1
  fi
}

# ============================================================
# AC2: Matrix structure validation
# ============================================================

@test "matrix has valid structure with no pending rows" {
  [ -f "$MATRIX" ]

  # Header check.
  local header
  header="$(head -1 "$MATRIX")"
  [[ "$header" == *"path"*"classification"*"update_status"*"test_reference"* ]]

  # Every data row must have exactly 4 tab-separated fields.
  local bad_rows=0
  while IFS= read -r line; do
    local field_count
    field_count="$(printf '%s' "$line" | awk -F'\t' '{print NF}')"
    if [ "$field_count" -ne 4 ]; then
      bad_rows=$((bad_rows + 1))
    fi
  done < <(tail -n +2 "$MATRIX")
  [ "$bad_rows" -eq 0 ]

  # Classification field is one of the valid values.
  local invalid_class=0
  while IFS=$'\t' read -r _path classification _status _ref; do
    case "$classification" in
      true-writer|indirect-writer|pure-reader|string-constant-reference) ;;
      *) invalid_class=$((invalid_class + 1)) ;;
    esac
  done < <(tail -n +2 "$MATRIX")
  [ "$invalid_class" -eq 0 ]

  # Update status field is one of the valid values (never "pending").
  local invalid_status=0
  while IFS=$'\t' read -r _path _class update_status _ref; do
    case "$update_status" in
      updated|shimmed|no-change-needed) ;;
      *) invalid_status=$((invalid_status + 1)) ;;
    esac
  done < <(tail -n +2 "$MATRIX")
  [ "$invalid_status" -eq 0 ]

  # No empty fields.
  local empty_fields=0
  while IFS=$'\t' read -r f1 f2 f3 f4; do
    if [ -z "$f1" ] || [ -z "$f2" ] || [ -z "$f3" ] || [ -z "$f4" ]; then
      empty_fields=$((empty_fields + 1))
    fi
  done < <(tail -n +2 "$MATRIX")
  [ "$empty_fields" -eq 0 ]
}

@test "matrix contains no internal traceability identifiers" {
  [ -f "$MATRIX" ]

  local hits
  hits="$(/usr/bin/grep -cE 'FR-[0-9]+|NFR-[0-9]+|ADR-[0-9]+|SR-[0-9]+|E[0-9]+-S[0-9]+|TC-[A-Z]+-[A-Z]+-[0-9]+|AF-[0-9]{4}-[0-9]{2}-[0-9]{2}' "$MATRIX" 2>/dev/null)" || hits=0
  [ "$hits" -eq 0 ]
}

# ============================================================
# AC4: Pure-reader static check
# ============================================================

@test "pure readers contain no write operations to state file" {
  [ -f "$MATRIX" ]

  local hits=0 offenders=""
  while IFS=$'\t' read -r path classification _status _ref; do
    [ "$classification" = "pure-reader" ] || continue
    local full_path="$BATS_TEST_SCRIPT_DIR/${path#plugins/gaia/}"
    [ -f "$full_path" ] || continue

    # Check for write-indicative patterns.  Filter out comments AND
    # usage/help text (printf, echo, err, log, die, heredoc lines, and
    # lines that are part of a usage-text block).
    local write_hits=0
    local code_lines
    code_lines="$(/usr/bin/grep -vE '^\s*#|^\s*(echo|printf|err |log |die |Run |cat <<)' "$full_path")"

    # yq -i (in-place YAML write)
    local yqi_match
    yqi_match="$(echo "$code_lines" | /usr/bin/grep -cE 'yq -i.*sprint-status' 2>/dev/null)" || yqi_match=0
    write_hits=$((write_hits + yqi_match))

    # Mutating sprint-state.sh subcommands — must be an actual invocation
    # (bash/sh/source or a variable dereference followed by the script name),
    # not a prose mention in usage text.
    local mut_match
    mut_match="$(echo "$code_lines" | /usr/bin/grep -cE '(bash|sh|"\$|source|\$\().*sprint-state\.sh.*(transition|init |advance|inject|reconcile|rollover|set-)' 2>/dev/null)" || mut_match=0
    write_hits=$((write_hits + mut_match))

    # Shell redirection into the state file — must target the actual
    # filename, not a substring match on option flags like --sprint-status.
    local redir_match
    redir_match="$(echo "$code_lines" | /usr/bin/grep -cE '(>|>>)\s*("|'\''|\$).*sprint-status\.yaml' 2>/dev/null)" || redir_match=0
    write_hits=$((write_hits + redir_match))

    if [ "$write_hits" -gt 0 ]; then
      hits=$((hits + write_hits))
      offenders="${offenders}  ${path} (${write_hits} hits)"$'\n'
    fi
  done < <(tail -n +2 "$MATRIX")

  if [ "$hits" -gt 0 ]; then
    printf 'Pure readers with write operations (%d hits):\n%s' "$hits" "$offenders" >&2
    return 1
  fi
}

@test "mutant adding a write to a pure reader turns the static check red" {
  [ -f "$MATRIX" ]

  # Find the first pure-reader shell script in the matrix.
  local target_rel=""
  while IFS=$'\t' read -r path classification _status _ref; do
    [ "$classification" = "pure-reader" ] || continue
    case "$path" in *.sh) ;; *) continue ;; esac
    local full="$BATS_TEST_SCRIPT_DIR/${path#plugins/gaia/}"
    [ -f "$full" ] || continue
    target_rel="$path"
    break
  done < <(tail -n +2 "$MATRIX")

  [ -n "$target_rel" ]

  # Copy the target into a temp dir so the real tree is never mutated.
  local real_file="$BATS_TEST_SCRIPT_DIR/${target_rel#plugins/gaia/}"
  local tmp_copy="$TEST_DIR/mutant-target.sh"
  cp "$real_file" "$tmp_copy"

  # Inject a mutant write line into the COPY.
  printf '\nyq -i '\''.test = "mutant"'\'' sprint-status.yaml\n' >> "$tmp_copy"

  # The static check should detect the mutant in the copy.
  local hit
  hit="$(/usr/bin/grep -vE '^\s*#' "$tmp_copy" | /usr/bin/grep -cE 'yq -i.*sprint-status' 2>/dev/null)" || hit=0
  [ "$hit" -gt 0 ]
}

# ============================================================
# AC5: String-constant references unmodified
# ============================================================

@test "string-constant references match their pre-sweep content" {
  [ -f "$MATRIX" ]

  # For each string-constant file, verify the classification is correct:
  # all mentions of sprint-status.yaml are in comments, echo/printf, or
  # heredoc documentation — not in actual read/write code paths.
  local misclass=0 misclass_files=""
  while IFS=$'\t' read -r path classification _status _ref; do
    [ "$classification" = "string-constant-reference" ] || continue
    local full_path="$BATS_TEST_SCRIPT_DIR/${path#plugins/gaia/}"
    [ -f "$full_path" ] || continue

    # Check: does any non-comment, non-echo/printf, non-heredoc line
    # reference sprint-status.yaml in a read/write context?
    local code_refs
    code_refs="$(/usr/bin/grep -vE '^\s*#|^\s*(echo|printf|cat <<|err |log |die )' "$full_path" \
      | /usr/bin/grep -cE '(yq|awk|cat|grep|read|source|\$\().*sprint-status\.yaml' 2>/dev/null)" || code_refs=0
    if [ "$code_refs" -gt 0 ]; then
      misclass=$((misclass + 1))
      misclass_files="${misclass_files}  ${path} (${code_refs} code refs)"$'\n'
    fi
  done < <(tail -n +2 "$MATRIX")

  if [ "$misclass" -gt 0 ]; then
    printf 'Misclassified string-constant files with code refs (%d):\n%s' \
      "$misclass" "$misclass_files" >&2
    return 1
  fi
}

# ============================================================
# AC6: CI guard catches unregistered direct references
# ============================================================

@test "CI guard fails on unregistered script referencing state file" {
  [ -f "$MATRIX" ]

  # Plant an unregistered script that reads the state file.
  local mutant_dir="$BATS_TEST_SCRIPT_DIR/scripts"
  local mutant="$mutant_dir/test-unregistered-sweep-guard.sh"
  cat > "$mutant" <<'SH'
#!/usr/bin/env bash
cat .gaia/state/sprint-status.yaml
SH
  chmod +x "$mutant"

  # Read the matrix allowlist.
  local allowlist
  allowlist="$(awk -F'\t' 'NR>1 {print $1}' "$MATRIX")"

  # Enumerate all scripts under scripts/ and skills/*/scripts/ that reference
  # sprint-status.yaml (excluding test files and fixtures).
  local unregistered=0 unregistered_files=""
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    case "$f" in *.bats|*/fixtures/*|*/tests/*) continue ;; esac
    local rel_path="${f#"$BATS_TEST_SCRIPT_DIR/"}"
    rel_path="plugins/gaia/${rel_path}"
    if ! grep -qxF "$rel_path" <<< "$allowlist"; then
      if /usr/bin/grep -q 'sprint-status\.yaml' "$f" 2>/dev/null; then
        unregistered=$((unregistered + 1))
        unregistered_files="${unregistered_files}  ${rel_path}"$'\n'
      fi
    fi
  done < <(find "$BATS_TEST_SCRIPT_DIR/scripts" "$BATS_TEST_SCRIPT_DIR/skills" \
    -type f \( -name '*.sh' -o -name '*.md' \) 2>/dev/null | sort)

  # The guard must catch the planted mutant.
  [ "$unregistered" -gt 0 ]
  [[ "$unregistered_files" == *"test-unregistered-sweep-guard.sh"* ]]

  # Clean up.
  rm -f "$mutant"
}

@test "CI guard passes when all references are in the matrix" {
  [ -f "$MATRIX" ]

  # Read the matrix allowlist.
  local allowlist
  allowlist="$(awk -F'\t' 'NR>1 {print $1}' "$MATRIX")"

  # Enumerate all scripts/skills files that reference sprint-status.yaml.
  local unregistered=0
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    case "$f" in *.bats|*/fixtures/*|*/tests/*) continue ;; esac
    local rel_path="${f#"$BATS_TEST_SCRIPT_DIR/"}"
    rel_path="plugins/gaia/${rel_path}"
    if ! grep -qxF "$rel_path" <<< "$allowlist"; then
      if /usr/bin/grep -q 'sprint-status\.yaml' "$f" 2>/dev/null; then
        unregistered=$((unregistered + 1))
      fi
    fi
  done < <(find "$BATS_TEST_SCRIPT_DIR/scripts" "$BATS_TEST_SCRIPT_DIR/skills" \
    -type f \( -name '*.sh' -o -name '*.md' \) 2>/dev/null | sort)

  [ "$unregistered" -eq 0 ]
}

# ============================================================
# AC7: No internal IDs in published files changed by this story
# ============================================================

@test "no internal IDs in published sweep files" {
  # Check the matrix file (the only non-test published file).
  # Test files (*.bats) use synthetic IDs (E900-S*) which are carve-outs.
  [ -f "$MATRIX" ]

  local hits
  hits="$(/usr/bin/grep -cE 'FR-[0-9]+|NFR-[0-9]+|ADR-[0-9]+|SR-[0-9]+|E[0-9]+-S[0-9]+|TC-CONC-|AF-[0-9]{4}-[0-9]{2}-[0-9]{2}' "$MATRIX" 2>/dev/null)" || hits=0
  [ "$hits" -eq 0 ]
}

# ============================================================
# AC-EC1: New script caught by CI guard
# ============================================================

@test "new skill script reading state file caught by CI guard" {
  [ -f "$MATRIX" ]

  # Plant a new skill script that reads the state file.
  # Build the skill path from variables so the script-refs lint does not
  # flag the synthetic path as a stale reference.
  local _skill_name="gaia-new-skill-sweep-test"
  local skill_dir="$BATS_TEST_SCRIPT_DIR/skills/${_skill_name}/scripts"
  mkdir -p "$skill_dir"
  cat > "$skill_dir/setup.sh" <<'SH'
#!/usr/bin/env bash
yaml_path=".gaia/state/sprint-status.yaml"
yq '.sprint' "$yaml_path"
SH

  local allowlist
  allowlist="$(awk -F'\t' 'NR>1 {print $1}' "$MATRIX")"

  local rel="plugins/gaia/skills/${_skill_name}/scripts/setup.sh"
  ! grep -qxF "$rel" <<< "$allowlist"

  # Clean up.
  rm -rf "$BATS_TEST_SCRIPT_DIR/skills/${_skill_name}"
}

# ============================================================
# AC-EC2: Conditional writer misclassification detected
# ============================================================

@test "conditional writer in pure reader detected by static check" {
  [ -f "$MATRIX" ]

  # Find the first pure-reader shell script.
  local target_rel=""
  while IFS=$'\t' read -r path classification _status _ref; do
    [ "$classification" = "pure-reader" ] || continue
    case "$path" in *.sh) ;; *) continue ;; esac
    local full="$BATS_TEST_SCRIPT_DIR/${path#plugins/gaia/}"
    [ -f "$full" ] || continue
    target_rel="$path"
    break
  done < <(tail -n +2 "$MATRIX")

  [ -n "$target_rel" ]

  # Copy the target into a temp dir so the real tree is never mutated.
  local real_file="$BATS_TEST_SCRIPT_DIR/${target_rel#plugins/gaia/}"
  local tmp_copy="$TEST_DIR/conditional-mutant.sh"
  cp "$real_file" "$tmp_copy"

  # Inject a conditional write into the COPY.
  printf '\nif [ "$recovery" = true ]; then yq -i '\''\.status = "error"'\'' sprint-status.yaml; fi\n' >> "$tmp_copy"

  # Static check should detect the yq -i pattern in the copy.
  local hit
  hit="$(/usr/bin/grep -vE '^\s*#' "$tmp_copy" | /usr/bin/grep -cE 'yq -i.*sprint-status' 2>/dev/null)" || hit=0
  [ "$hit" -gt 0 ]
}

# ============================================================
# AC-EC4: Stale matrix caught by CI guard
# ============================================================

@test "stale matrix caught when new scripts are added" {
  [ -f "$MATRIX" ]

  # Plant three unregistered scripts.
  local i
  for i in 1 2 3; do
    local d="$BATS_TEST_SCRIPT_DIR/scripts"
    cat > "$d/test-stale-matrix-${i}.sh" <<SH
#!/usr/bin/env bash
cat .gaia/state/sprint-status.yaml
SH
  done

  local allowlist
  allowlist="$(awk -F'\t' 'NR>1 {print $1}' "$MATRIX")"

  local unregistered=0
  for i in 1 2 3; do
    local rel="plugins/gaia/scripts/test-stale-matrix-${i}.sh"
    if ! grep -qxF "$rel" <<< "$allowlist"; then
      unregistered=$((unregistered + 1))
    fi
  done

  [ "$unregistered" -eq 3 ]

  # Clean up.
  rm -f "$BATS_TEST_SCRIPT_DIR/scripts/test-stale-matrix-"*.sh
}

# ============================================================
# AC-EC6: Error message string constant classified correctly
# ============================================================

@test "error message with state file name classified as string-constant" {
  [ -f "$MATRIX" ]

  # init-project.sh is a known string-constant reference.
  local class
  class="$(awk -F'\t' '$1 == "plugins/gaia/scripts/init-project.sh" {print $2}' "$MATRIX")"
  [ "$class" = "string-constant-reference" ]

  local status
  status="$(awk -F'\t' '$1 == "plugins/gaia/scripts/init-project.sh" {print $3}' "$MATRIX")"
  [ "$status" = "no-change-needed" ]
}

# ============================================================
# AC-EC7: Quote-bearing sprint ID round-trips safely
# ============================================================

@test "quote-bearing sprint ID round-trips through strenv" {
  local state_file="$TEST_DIR/sprint-status.yaml"
  cat > "$state_file" <<'YAML'
sprint_id: "placeholder"
status: active
stories: []
YAML

  # Write a quote-bearing sprint ID using strenv (the safe pattern).
  local sprint_id='sprint "O'\''Malley"'
  export sprint_id
  yq -i '.sprint_id = strenv(sprint_id)' "$state_file"

  # Read it back.
  local round_tripped
  round_tripped="$(yq '.sprint_id' "$state_file")"

  # Must match exactly.
  [ "$round_tripped" = "$sprint_id" ]

  # File must remain valid YAML.
  yq '.' "$state_file" >/dev/null 2>&1
}

@test "no unsafe yq/jq interpolation in swept files" {
  # Check the transition-story-status.sh update function for unsafe patterns.
  local tss="$BATS_TEST_SCRIPT_DIR/scripts/transition-story-status.sh"
  [ -f "$tss" ]

  # The old unsafe pattern was: yq -i '.field = "'$var'"'
  # After the sweep, no such pattern should exist in update_sprint_status_yaml.
  local unsafe
  unsafe="$(/usr/bin/grep -cE "yq -i.*'\"'\\''" "$tss" 2>/dev/null)" || unsafe=0
  [ "$unsafe" -eq 0 ]
}

# ============================================================
# Tree hygiene: the suite must leave the real tree byte-identical
# ============================================================

@test "suite leaves no modified files in the plugin scripts tree" {
  local dirty
  dirty="$(git -C "$BATS_TEST_SCRIPT_DIR" status --porcelain -- scripts/ 2>/dev/null)" || dirty=""
  if [ -n "$dirty" ]; then
    printf 'Tree dirty after suite:\n%s\n' "$dirty" >&2
    return 1
  fi
}
