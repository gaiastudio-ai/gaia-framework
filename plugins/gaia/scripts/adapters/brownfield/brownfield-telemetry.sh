#!/usr/bin/env bash
# adapters/brownfield/brownfield-telemetry.sh — E104-S1 shared brownfield-report
# frontmatter telemetry writer (NFR-85).
#
# A single, field-parametrized writer for the brownfield gap-consolidation
# report frontmatter. Built by E104-S1 and REUSED by E70-S7 (pre_warm fields)
# and E104-S4 (sarif_merge fields) — those stories deferred their telemetry
# population precisely because this writer did not exist yet.
#
# Single-author-per-field contract (SKILL.md / AF-2026-05-09-12): each field is
# written by exactly ONE owning phase. This script is the mechanism; callers
# must not fan out the same field from multiple phases. Supported fields:
#   gap_count_before_dedup, gap_count_after_dedup   (E104-S1 dedup phase)
#   phase_runtime_seconds.<phase>                   (each phase, its own key)
#   deterministic_tool_seconds.<phase>              (each phase, its own key)
#   llm_token_count                                 (deterministic phases set 0)
#   cross_stack_warnings (array), cross_stack_bypass_applied (bool)  (E104-S5)
#   (array + bool value-typing added by E104-S3; phase keys incl. deadcode_{go,
#    python,jvm} from E70-S8 and phase_4b_cross_stack from E104-S5)
#
# Operates ONLY on the YAML frontmatter block (between the leading `---`
# fences); the markdown body is preserved byte-for-byte. yq v4 drives the edit.
#
# Usage:
#   brownfield-telemetry.sh --report <path> --field <dotted-key> --value <v>
#   brownfield-telemetry.sh --report <path> --get <dotted-key>     # prints value
#
# Numeric values (all-digits) are written as YAML numbers; everything else as
# a string. Exit 0 on success; 1 on usage error / missing report / no frontmatter.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="adapters/brownfield/brownfield-telemetry.sh"
die() { printf 'ERROR: %s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

REPORT="" FIELD="" VALUE="" GET="" VALUE_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --report) REPORT="$2"; shift 2 ;;
    --field)  FIELD="$2"; shift 2 ;;
    --value)  VALUE="$2"; VALUE_SET=1; shift 2 ;;
    --get)    GET="$2"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[ -n "$REPORT" ] || die "--report <path> required"
[ -f "$REPORT" ] || die "report not found: $REPORT"
command -v yq >/dev/null 2>&1 || die "yq not found on PATH"

# Split the file into frontmatter (between the first two `---` fences) and body.
# Fails if there is no leading frontmatter block.
first_fence="$(grep -n '^---[[:space:]]*$' "$REPORT" | sed -n '1p' | cut -d: -f1)"
second_fence="$(grep -n '^---[[:space:]]*$' "$REPORT" | sed -n '2p' | cut -d: -f1)"
[ "${first_fence:-}" = "1" ] || die "no leading YAML frontmatter in $REPORT"
[ -n "${second_fence:-}" ] || die "unterminated YAML frontmatter in $REPORT"

fm_tmp="$(mktemp)"; body_tmp="$(mktemp)"; out_tmp=""
# Clean up all temp files on any exit (incl. a mid-edit yq failure under set -e).
trap 'rm -f "$fm_tmp" "$body_tmp" ${out_tmp:+"$out_tmp"}' EXIT
sed -n "2,$((second_fence-1))p" "$REPORT" > "$fm_tmp"
sed -n "$((second_fence+1)),\$p" "$REPORT" > "$body_tmp"

# --get short-circuit: print the resolved value (empty string if absent).
if [ -n "$GET" ]; then
  v="$(yq eval ".${GET} // \"\"" "$fm_tmp" 2>/dev/null || printf '')"
  printf '%s\n' "$v"
  rm -f "$fm_tmp" "$body_tmp"
  exit 0
fi

[ -n "$FIELD" ] || die "--field <dotted-key> required (or use --get)"
# --value is required for a set; an explicitly-passed empty value is allowed
# (VALUE_SET sentinel distinguishes "omitted" from "passed empty string").
[ "$VALUE_SET" -eq 1 ] || die "--value required with --field"

# Value typing:
#   - integers            -> YAML number   (e.g. 11)
#   - true|false          -> YAML boolean   (e.g. sbom_completeness_warning: true)
#   - [..] JSON array     -> YAML sequence  (e.g. detected_carve_outs: [a, b])
#   - everything else     -> quoted string
if printf '%s' "$VALUE" | grep -Eq '^-?[0-9]+$'; then
  yq eval -i ".${FIELD} = ${VALUE}" "$fm_tmp"
elif [ "$VALUE" = "true" ] || [ "$VALUE" = "false" ]; then
  yq eval -i ".${FIELD} = ${VALUE}" "$fm_tmp"
elif printf '%s' "$VALUE" | grep -Eq '^\[.*\]$'; then
  # Parse the JSON array into a native YAML sequence (flow style preserved by yq).
  yq eval -i ".${FIELD} = ${VALUE}" "$fm_tmp"
else
  yq eval -i ".${FIELD} = \"${VALUE}\"" "$fm_tmp"
fi

# Reassemble: --- + edited frontmatter + --- + original body (byte-preserved).
out_tmp="$(mktemp)"
{
  printf '%s\n' "---"
  cat "$fm_tmp"
  printf '%s\n' "---"
  cat "$body_tmp"
} > "$out_tmp"
mv "$out_tmp" "$REPORT"
rm -f "$fm_tmp" "$body_tmp"
exit 0
