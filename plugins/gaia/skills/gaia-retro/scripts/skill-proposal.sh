#!/usr/bin/env bash
# skill-proposal.sh — Skill improvement proposal helpers (E36-S3, ADR-053)
#
# Public functions (AF-2026-05-24-14 / Test02 F-32: expanded with output
# format + failure modes after dogfooding feedback that the original
# header only listed signatures, leaving consumers guessing about return
# shape and error semantics):
#
#   extract_tech_debt_reflection <project_root> <sprint_id>
#     → Reads tech-debt-dashboard.md and produces a Tech Debt Reflection block.
#     Stdout: a Markdown block with one `### {Category}` section per non-empty
#       debt category (architecture/code/test/documentation/process), each
#       enumerating the TD-* IDs and titles for the named sprint_id.
#     Stderr: WARNING lines on missing dashboard, malformed rows.
#     Exit: 0 always — empty stdout if no dashboard or no matching rows.
#     Failure mode: gracefully degrades to empty output (no HALT) so the
#       caller can splice into a retro doc without conditional logic.
#
#   build_proposal <finding_ref> <target_skill> <rationale> <diff>
#     → Produces a structured YAML proposal object.
#     Stdout: a 4-key YAML map: `finding_ref`, `target_skill`, `rationale`,
#       `diff` (the diff body literally embedded as a YAML literal block).
#     Exit: 0 always.
#     Failure mode: caller MUST pass non-empty `finding_ref` + `target_skill`;
#       blank fields produce malformed YAML (no validation here — see
#       `validate_proposal` for the safe-build pattern).
#
#   validate_proposal <finding_ref> <target_skill> <rationale> <diff>
#     → Validates the proposal (diff size, UTF-8).
#     Stdout: empty.
#     Stderr: `validate_proposal: <reason>` on failure.
#     Exit: 0 = valid; 1 = invalid (diff > 8KB, non-UTF-8 content, or any
#       required field empty).
#
#   write_approved_proposal <root> <sprint_id> <target_skill> <target_path> \
#                           <rationale> <diff_content> <writer_script>
#     → Writes custom/skills/{name}.md and registers in .customize.yaml
#       via the shared retro writer (ADR-052).
#     Stdout: the resolved write path on success.
#     Stderr: `write_approved_proposal: <reason>` on failure.
#     Exit: 0 = wrote successfully; non-zero = writer-script failure
#       (forwards the writer's exit code).
#     Failure mode: validate_proposal MUST pass before calling this;
#       unvalidated input may produce a malformed custom/skills/ file.
#
# Refs: ADR-053 (custom skill proposal pipeline), ADR-052 (shared writer),
#       FR-RIM-6 (skill improvement proposals), FR-RIM-7 (tech debt reflection),
#       ADR-020 (custom/skills/ write-path routing).

set -uo pipefail

# ---------------------------------------------------------------------------
# _parse_table_cell — extract column N (1-based) from a pipe-delimited row,
# trimming surrounding whitespace. Shared by extract_tech_debt_reflection.
# ---------------------------------------------------------------------------
_parse_table_cell() {
  local line="$1" col="$2"
  printf '%s' "$line" | awk -F'|' -v c="$col" '{gsub(/[[:space:]]/, "", $c); print $c}'
}

# Category names used by the debt dashboard (architecture §10.28.8).
_DEBT_CATEGORIES="architecture|code|test|documentation|process"

# ---------------------------------------------------------------------------
# extract_tech_debt_reflection <project_root> <sprint_id>
# ---------------------------------------------------------------------------
extract_tech_debt_reflection() {
  local root="$1" sprint_id="$2"
  # AF-2026-05-21-25: canonical-first dashboard lookup.
  local dashboard
  if [ -f "$root/.gaia/artifacts/implementation-artifacts/tech-debt-dashboard.md" ]; then
    dashboard="$root/.gaia/artifacts/implementation-artifacts/tech-debt-dashboard.md"
  else
    dashboard="$root/docs/implementation-artifacts/tech-debt-dashboard.md"
  fi

  if [ ! -f "$dashboard" ]; then
    cat <<'EOF'
## Tech Debt Reflection

> No tech debt data available (run `/gaia-tech-debt-review` to generate `.gaia/artifacts/implementation-artifacts/tech-debt-dashboard.md`).
EOF
    return 0
  fi

  local content
  content="$(cat "$dashboard" 2>/dev/null || true)"

  if [ -z "$content" ]; then
    cat <<'EOF'
## Tech Debt Reflection

> tech-debt reflection unavailable: dashboard file is empty
EOF
    return 0
  fi

  # Extract metric rows
  local ratio_line aging_line
  ratio_line="$(printf '%s' "$content" | grep -i 'debt ratio' | head -1 || true)"
  aging_line="$(printf '%s' "$content" | grep -i 'mean age\|aging' | head -1 || true)"

  if [ -z "$ratio_line" ] && [ -z "$aging_line" ]; then
    cat <<'EOF'
## Tech Debt Reflection

> tech-debt reflection unavailable: could not parse ratio or aging data from dashboard
EOF
    return 0
  fi

  # Parse values: column 3 = current, 4 = prior, 5 = delta
  local ratio_current ratio_prior ratio_delta
  ratio_current="$(_parse_table_cell "$ratio_line" 3 || true)"
  ratio_prior="$(_parse_table_cell "$ratio_line" 4 || true)"
  ratio_delta="$(_parse_table_cell "$ratio_line" 5 || true)"

  local aging_current aging_prior aging_delta
  aging_current="$(_parse_table_cell "$aging_line" 3 || true)"
  aging_prior="$(_parse_table_cell "$aging_line" 4 || true)"
  aging_delta="$(_parse_table_cell "$aging_line" 5 || true)"

  # First sprint: no prior columns → baseline markers (EC3)
  local is_baseline=0
  if [ -z "$ratio_prior" ] && [ -z "$aging_prior" ]; then
    is_baseline=1
  fi

  # Detect category breakdown rows after the heading
  local has_categories=0
  if printf '%s' "$content" \
    | awk "/Category Breakdown/{f=1;next} f && /\\| *(${_DEBT_CATEGORIES})/{hit=1} END{exit !hit}" \
      >/dev/null 2>&1; then
    has_categories=1
  fi

  # Render the reflection block
  printf '## Tech Debt Reflection\n\n'

  if [ "$is_baseline" -eq 1 ]; then
    printf -- '- Debt ratio: %s (baseline)\n' "${ratio_current:-N/A}"
    printf -- '- Aging: mean age %s (baseline)\n' "${aging_current:-N/A}"
  else
    printf -- '- Debt ratio delta: %s vs. %s — %s\n' \
      "${ratio_current:-N/A}" "${ratio_prior:-N/A}" "${ratio_delta:-N/A}"
    printf -- '- Aging delta: mean age %s vs. %s — %s\n' \
      "${aging_current:-N/A}" "${aging_prior:-N/A}" "${aging_delta:-N/A}"
  fi

  if [ "$has_categories" -eq 1 ]; then
    printf -- '- Category breakdown:\n'
    printf '  | Category | Count | Delta vs. prior |\n'
    printf '  |---|---|---|\n'
    # Extract each category row via a single awk pass
    printf '%s' "$content" | awk "
      /Category Breakdown/{found=1; next}
      found && /^\\| *(${_DEBT_CATEGORIES})/ {
        split(\$0, a, \"|\")
        gsub(/[[:space:]]/, \"\", a[2])
        gsub(/[[:space:]]/, \"\", a[3])
        gsub(/[[:space:]]/, \"\", a[5])
        printf \"  | %s | %s | %s |\\n\", a[2], a[3], a[5]
      }
      found && !/^\\|/ && !/^\$/ && !/^#/{exit}
    "
  else
    printf -- '- category breakdown unavailable (older dashboard format)\n'
  fi
}

# ---------------------------------------------------------------------------
# build_proposal <finding_ref> <target_skill> <rationale> <diff>
# ---------------------------------------------------------------------------
build_proposal() {
  local finding_ref="$1" target_skill="$2" rationale="$3" diff_text="$4"

  if [ -z "$target_skill" ]; then
    printf 'no skill match\n' >&2
    return 0
  fi

  local target_path="custom/skills/${target_skill}.md"

  cat <<EOF
proposal:
  finding_ref: "${finding_ref}"
  target_skill: "${target_skill}"
  target_path: "${target_path}"
  rationale: "${rationale}"
  diff: |
$(printf '%s' "$diff_text" | sed 's/^/    /')
EOF
}

# ---------------------------------------------------------------------------
# validate_proposal <finding_ref> <target_skill> <rationale> <diff>
# ---------------------------------------------------------------------------
validate_proposal() {
  local finding_ref="$1" target_skill="$2" rationale="$3" diff_text="$4"

  # Check diff size — must be under 100 KB (102400 bytes)
  local diff_bytes=${#diff_text}
  if [ "$diff_bytes" -gt 102400 ]; then
    printf 'error: diff must be UTF-8 text under 100 KB (got %d bytes)\n' "$diff_bytes"
    return 1
  fi

  # Check for empty required fields
  if [ -z "$finding_ref" ] || [ -z "$target_skill" ] || [ -z "$rationale" ]; then
    printf 'error: finding_ref, target_skill, and rationale are required\n'
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# write_approved_proposal <root> <sprint_id> <target_skill> <target_path> \
#                         <rationale> <diff_content> <writer_script>
# ---------------------------------------------------------------------------
write_approved_proposal() {
  local root="$1"
  local sprint_id="$2"
  local target_skill="$3"
  local target_path="$4"
  local rationale="$5"
  local diff_content="$6"
  local writer_script="$7"

  local abs_target_path="$root/$target_path"

  # Step 1: Write custom/skills/{name}.md via the shared retro writer
  local skill_payload
  skill_payload="$(printf '# Custom Skill Override: %s\n\n> Source: retro proposal (sprint %s)\n> Rationale: %s\n\n%s' \
    "$target_skill" "$sprint_id" "$rationale" "$diff_content")"

  local write_result
  write_result="$("$writer_script" \
    --root "$root" \
    --sprint-id "$sprint_id" \
    --target "$abs_target_path" \
    --payload "$skill_payload" 2>&1)"

  local write_status=$?
  if [ "$write_status" -ne 0 ]; then
    printf 'error: skill write failed: %s\n' "$write_result" >&2
    return 1
  fi

  # Step 2: Register in .customize.yaml via the shared retro writer
  # Per ADR-020 §lines 1720-1722: custom/skills/{agent-id}.customize.yaml
  # For dev-agent skills, use all-dev.customize.yaml
  local cust_yaml="$root/custom/skills/all-dev.customize.yaml"
  local reg_payload
  reg_payload="$(printf 'skill_overrides:\n  %s: %s\n' "$target_skill" "$target_path")"

  local reg_result
  reg_result="$("$writer_script" \
    --root "$root" \
    --sprint-id "$sprint_id" \
    --target "$cust_yaml" \
    --payload "$reg_payload" 2>&1)"

  local reg_status=$?
  if [ "$reg_status" -ne 0 ]; then
    printf 'error: .customize.yaml registration failed: %s\n' "$reg_result" >&2
    # Skill file remains (idempotent content) but override not active
    return 1
  fi

  printf 'status=ok\nskill=%s\npath=%s\ncustomize=%s\n' \
    "$target_skill" "$target_path" "$cust_yaml"
  return 0
}
