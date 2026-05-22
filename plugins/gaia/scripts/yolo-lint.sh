#!/usr/bin/env bash
# yolo-lint.sh — Framework lint for SKILL.md `yolo_steps:` declarations.
#
# Story: E41-S1 (YOLO Mode Contract + Helper)
# ADR: ADR-057 (YOLO Mode Contract for V2 Phase 4 Commands)
# Architecture: .gaia/artifacts/planning-artifacts/architecture.md §10.30.3 + §10.30.8
#
# Purpose
# -------
# Per FR-YOLO-2 the framework MUST reject at load time any SKILL.md whose
# `yolo_steps:` frontmatter declaration covers a hard-gate step. Hard gates
# are invariants V1 enforced through engine-level wiring; in V2 they live
# inside individual SKILL.md files, so a misdeclared `yolo_steps:` would
# silently bypass them.
#
# Hard-gate categories (architecture §10.30.3):
#   (a) Pre-start quality gates    — frontmatter `quality_gates.pre_start`
#                                    OR step title matching pre-start patterns
#   (b) Status guards              — step body containing "HALT unless status"
#                                    or step title containing "Status Guard"
#   (c) Allowlist rejections       — step body referencing path-traversal,
#                                    write-scope, or allowlist enforcement
#   (d) Destructive-write approvals — step body mentioning writes to
#                                    custom/skills/, plugins/gaia/skills/
#   (e) Validation-failure cap     — step title/body referencing the
#                                    3-attempt cap on Val auto-fix loop
#   (f) Memory-save prompts        — E9-S8 sidecar write [y]/[n]/[e] prompt
#
# Behavior:
#   - Hard-gate violation                 -> stdout FAIL line, exit non-zero
#   - Out-of-range step number (ECI-499)  -> stdout WARN line, exit 0
#   - Empty `yolo_steps: []` (ECI-498)    -> silent no-op, exit 0
#   - Missing `yolo_steps:` key           -> silent no-op, exit 0
#
# Usage:
#   yolo-lint.sh [--skills-root <dir>]    # default: plugins/gaia/skills
#   yolo-lint.sh --help
#
# Shellcheck: clean.

set -uo pipefail
LC_ALL=C
export LC_ALL

# Resolve default skills root relative to this script:
#   plugins/gaia/scripts/yolo-lint.sh -> plugins/gaia/skills
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEFAULT_SKILLS_ROOT="$(cd "$SCRIPT_DIR/../skills" 2>/dev/null && pwd || echo "")"

usage() {
    cat <<EOF
yolo-lint.sh — Framework lint for SKILL.md \`yolo_steps:\` declarations.

Usage:
  yolo-lint.sh [--skills-root <dir>]
  yolo-lint.sh --help

Default skills root: ${DEFAULT_SKILLS_ROOT:-plugins/gaia/skills}

Exit codes:
  0  — no hard-gate violations (warnings allowed)
  1  — at least one hard-gate violation
  2  — usage error
EOF
}

# extract_frontmatter <skill_md_path>
# ----------------------------------
# Print the YAML frontmatter (everything between the first two '---' lines)
# to stdout. Empty if no frontmatter.
_extract_frontmatter() {
    local f="$1"
    awk '
        BEGIN { in_fm = 0; seen = 0 }
        /^---[[:space:]]*$/ {
            if (!seen) { seen = 1; in_fm = 1; next }
            else if (in_fm) { in_fm = 0; exit }
        }
        in_fm { print }
    ' "$f"
}

# extract_yolo_steps <frontmatter_text>
# -------------------------------------
# Print the comma-separated list of step numbers declared in `yolo_steps:`,
# or empty string if the key is absent or the array is empty.
# Supports inline form: `yolo_steps: [1, 3, 5]` or `yolo_steps: []`.
_extract_yolo_steps() {
    local fm="$1"
    printf '%s\n' "$fm" | awk '
        /^yolo_steps:[[:space:]]*\[/ {
            line = $0
            sub(/^yolo_steps:[[:space:]]*\[/, "", line)
            sub(/\].*$/, "", line)
            gsub(/[[:space:]]/, "", line)
            print line
            exit
        }
    '
}

# count_steps <skill_md_path>
# --------------------------
# Print the highest step number declared in the SKILL.md body. Recognizes
# headings of the form `## Step N:` or `### Step N:` (case-insensitive on
# "Step"). Returns 0 if no step headings found.
_count_steps() {
    local f="$1"
    awk '
        BEGIN { max = 0 }
        /^#{2,3}[[:space:]]+[Ss]tep[[:space:]]+[0-9]+/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9]+/) {
                    n = $i + 0
                    if (n > max) max = n
                    break
                }
            }
        }
        END { print max }
    ' "$f"
}

# extract_step_block <skill_md_path> <step_number>
# ------------------------------------------------
# Print the block of text from "## Step N:" (or "### Step N:") through to
# the next "## Step" (or "### Step") heading or EOF. Empty if step not
# found.
_extract_step_block() {
    local f="$1" n="$2"
    awk -v want="$n" '
        BEGIN { capture = 0 }
        /^#{2,3}[[:space:]]+[Ss]tep[[:space:]]+[0-9]+/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9]+/) {
                    cur = $i + 0
                    break
                }
            }
            if (cur == want) { capture = 1; print; next }
            else if (capture) { exit }
        }
        capture { print }
    ' "$f"
}

# has_pre_start_gate <frontmatter_text>
# -------------------------------------
# Return 0 if the frontmatter declares `quality_gates.pre_start` (any
# non-empty form), else 1.
_has_pre_start_gate() {
    local fm="$1"
    printf '%s\n' "$fm" | awk '
        /^quality_gates:/ { in_qg = 1; next }
        in_qg && /^[a-zA-Z_]/ && !/^[[:space:]]/ { in_qg = 0 }
        in_qg && /^[[:space:]]+pre_start:/ { found = 1; exit }
        END { exit (found ? 0 : 1) }
    '
}

# classify_step_hard_gate <step_block>
# ------------------------------------
# Echo a hard-gate category code (b|c|d|e|f) and return 0 if the step block
# matches a hard gate; return 1 otherwise. (Category 'a' is handled at the
# frontmatter level via has_pre_start_gate against step number 1.)
_classify_step_hard_gate() {
    local block="$1"
    local lower
    lower=$(printf '%s' "$block" | tr '[:upper:]' '[:lower:]')

    # (b) Status guards — title or body
    if printf '%s' "$lower" | grep -qE 'status[[:space:]]+guard|halt[[:space:]]+unless[[:space:]]+status|status[[:space:]]+==|status[[:space:]]+must[[:space:]]+be'; then
        echo 'b'
        return 0
    fi

    # (f) Memory-save prompt — handle BEFORE (d) so 'memory save' wins over
    #     a generic destructive-write match if both could apply.
    if printf '%s' "$lower" | grep -qE 'memory[[:space:]]*save|memory-save|sidecar[[:space:]]+write|\[y\]/\[n\]/\[e\]|e9-s8'; then
        echo 'f'
        return 0
    fi

    # (e) Validation-failure cap (3-attempt)
    if printf '%s' "$lower" | grep -qE '3[[:space:]]*[-]?[[:space:]]*attempt|attempt[[:space:]]*cap|val[[:space:]]+fix[[:space:]]+loop|3[[:space:]]+iterations|after[[:space:]]+3[[:space:]]+unresolved'; then
        echo 'e'
        return 0
    fi

    # (d) Destructive-write approvals
    if printf '%s' "$lower" | grep -qE 'destructive[[:space:]]+write|write[[:space:]]+to[[:space:]]+(plugins/gaia/skills|custom/skills)|skill[[:space:]]+proposal|writes[[:space:]]+to[[:space:]]+plugins/gaia/skills'; then
        echo 'd'
        return 0
    fi

    # (c) Allowlist rejections
    if printf '%s' "$lower" | grep -qE 'allowlist|path[[:space:]]*-?[[:space:]]*traversal|write[[:space:]]*-?[[:space:]]*scope|spawn[[:space:]]*-?[[:space:]]*guard|reject[[:space:]]+path'; then
        echo 'c'
        return 0
    fi

    return 1
}

# lint_skill <skill_md_path>
# --------------------------
# Lint a single SKILL.md and print FAIL / WARN lines. Returns 0 if no
# hard-gate violations; non-zero otherwise. Warnings do NOT affect exit.
_lint_skill() {
    local f="$1"
    local skill_id
    skill_id=$(basename "$(dirname "$f")")

    local fm steps_csv max_step block code
    fm=$(_extract_frontmatter "$f")
    steps_csv=$(_extract_yolo_steps "$fm")

    # Empty/missing yolo_steps -> silent no-op (ECI-498).
    if [ -z "$steps_csv" ]; then
        return 0
    fi

    max_step=$(_count_steps "$f")
    local violations=0

    local IFS=','
    # shellcheck disable=SC2206
    local steps=( $steps_csv )
    unset IFS

    local s
    for s in "${steps[@]}"; do
        # Strip whitespace (defensive).
        s="${s// /}"
        [ -z "$s" ] && continue

        # ECI-499 — out-of-range step number.
        if [ "$max_step" -gt 0 ] && [ "$s" -gt "$max_step" ]; then
            echo "WARN  $skill_id  yolo_steps step $s is out of range (skill has $max_step steps)"
            continue
        fi

        # Category (a) — declared at frontmatter level. If yolo_steps lists
        # step 1 AND the skill declares quality_gates.pre_start, this is a
        # pre-start-gate hard-gate violation regardless of step body text.
        if [ "$s" -eq 1 ] && _has_pre_start_gate "$fm"; then
            echo "FAIL  $skill_id  yolo_steps step 1 covers HARD-GATE category (a) pre-start quality gate"
            violations=$((violations + 1))
            continue
        fi

        # Categories (b..f) — inspect the step block.
        block=$(_extract_step_block "$f" "$s")
        if [ -z "$block" ]; then
            continue
        fi

        if code=$(_classify_step_hard_gate "$block"); then
            echo "FAIL  $skill_id  yolo_steps step $s covers HARD-GATE category ($code)"
            violations=$((violations + 1))
        fi
    done

    return "$violations"
}

# lint_yolo_steps [skills_root]
# -----------------------------
# Lint every SKILL.md under the given skills root. Aggregates exit codes:
# returns 0 only if every skill is clean (warnings allowed); returns 1 if
# any skill has at least one hard-gate violation.
lint_yolo_steps() {
    local root="${1:-${DEFAULT_SKILLS_ROOT}}"
    local total_fail=0

    if [ -z "$root" ] || [ ! -d "$root" ]; then
        echo "yolo-lint: skills root not found: $root" >&2
        return 2
    fi

    local f
    while IFS= read -r f; do
        _lint_skill "$f"
        total_fail=$((total_fail + $?))
    done < <(find "$root" -name 'SKILL.md' -type f 2>/dev/null | sort)

    if [ "$total_fail" -gt 0 ]; then
        return 1
    fi
    return 0
}

# Direct-invocation entry point.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    SKILLS_ROOT="$DEFAULT_SKILLS_ROOT"
    while [ $# -gt 0 ]; do
        case "$1" in
            --skills-root)
                shift
                SKILLS_ROOT="${1:-}"
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo "yolo-lint: unknown argument '$1'" >&2
                usage >&2
                exit 2
                ;;
        esac
        shift
    done

    lint_yolo_steps "$SKILLS_ROOT"
    exit $?
fi
