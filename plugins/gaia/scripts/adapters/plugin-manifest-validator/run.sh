#!/usr/bin/env bash
# adapters/plugin-manifest-validator/run.sh — FR-410 + ADR-078 contract entry.
#
# Validates Claude Code plugin manifest.yaml files against:
#   1. The `frontmatter_requirements.required_fields` list defined in the
#      claude-code-plugin stack file (E77-S2). Each missing required field
#      becomes one `severity: high` finding.
#   2. The `name == basename` byte-exact rule (LC_ALL=C). When the manifest
#      `name:` value differs from the parent directory basename, emit a single
#      finding naming both values.
#   3. Manifest drift against on-disk state — for now, missing manifest file
#      surfaces as a high-severity finding (the broader drift surface — declared
#      tools / commands / agents / skills referencing absent paths — is wired
#      in tandem with FR-421 plugin-aware /gaia-trace; this adapter ships the
#      required-fields + name/basename core).
#
# Round 1+2 calibration: ALL drift findings emit `severity: "high"` — never
# `"critical"`. Claude Code discovers components via filesystem walk rather
# than the manifest, so drift is recoverable.
#
# Honours the ADR-078 run.sh flag-form interface:
#
#   run.sh --input <file-list> [--config <stack.yaml>] [--output <path>]
#          [--runtime-profile subprocess|container|network] [--timeout <seconds>]
#
# stdout is the canonical analysis-results fragment:
#   { "name": "plugin-manifest-validator",
#     "status": "passed" | "failed",
#     "findings": [ { rule, severity, file, line, message, blocking }, ... ] }
#
# Exit code:
#   0  - run completed with zero findings.
#   1  - adapter execution error (bad input, jq/awk missing).
#   2  - run completed with one or more findings. Per ADR-078 §3 a tool with
#        blocking findings could exit 0 and rely on findings[].blocking; the
#        FR-409 sibling (plugin-frontmatter-validator) ships exit-2-on-findings
#        to keep the AC language ("exits non-zero on findings") intact, and
#        this adapter mirrors that contract for parity.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Arg parsing -----------------------------------------------------------

INPUT=""
CONFIG=""
OUTPUT=""
RUNTIME_PROFILE="subprocess"
TIMEOUT=60

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --runtime-profile) RUNTIME_PROFILE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
adapters/plugin-manifest-validator/run.sh — FR-410 + ADR-078 contract.
Usage:
  run.sh --input <file-list> [--config <stack.yaml>] [--output <path>]
         [--runtime-profile subprocess|container|network] [--timeout <seconds>]
EOF
      exit 0 ;;
    *) echo "run.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

[ -n "$INPUT" ] || { echo "run.sh: --input required" >&2; exit 1; }
[ -r "$INPUT" ] || { echo "run.sh: input file not readable: $INPUT" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "run.sh: jq is required but not on PATH" >&2; exit 1; }
command -v awk >/dev/null 2>&1 || { echo "run.sh: awk is required but not on PATH" >&2; exit 1; }

# --- Resolve required-fields list from the stack file ---------------------
# When --config is supplied, use it. Otherwise fall back to the in-tree
# claude-code-plugin stack file (E77-S2). When neither is reachable, fall
# back to the canonical FR-404 list of [name, description, version].

DEFAULT_STACK="$SCRIPT_DIR/../../../config/stacks/claude-code-plugin.yaml"
STACK_FILE=""
if [ -n "$CONFIG" ] && [ -r "$CONFIG" ]; then
  STACK_FILE="$CONFIG"
elif [ -r "$DEFAULT_STACK" ]; then
  STACK_FILE="$DEFAULT_STACK"
fi

# read_required_fields <stack-yaml> -> newline-delimited field names.
# Pure-awk minimal parser tracking the `frontmatter_requirements:` >
# `required_fields:` block. Bullet lines `  - <field>` (with optional comment
# after the field name) are emitted; the block ends at the next sibling key.
read_required_fields() {
  local yaml="$1"
  awk '
    function strip_comment(s) { sub(/[[:space:]]*#.*$/, "", s); return s }
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    BEGIN { in_fm = 0; in_req = 0 }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    # Enter / leave the frontmatter_requirements block (column 0 key).
    /^frontmatter_requirements[[:space:]]*:/ { in_fm = 1; in_req = 0; next }
    /^[^[:space:]]/ { in_fm = 0; in_req = 0; next }
    in_fm {
      if (match($0, /^[[:space:]]+required_fields[[:space:]]*:[[:space:]]*$/)) {
        in_req = 1; next
      }
      # Sibling key inside frontmatter_requirements (e.g. name_equals_basename:)
      # ends the required_fields list scan.
      if (in_req && match($0, /^[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:/)) {
        in_req = 0
      }
      if (in_req) {
        # Bullet line: "  - <field>" possibly with trailing "# comment".
        if (match($0, /^[[:space:]]+-[[:space:]]+/)) {
          val = $0
          sub(/^[[:space:]]+-[[:space:]]+/, "", val)
          val = trim(strip_comment(val))
          if (length(val) > 0) print val
        }
      }
    }
  ' "$yaml"
}

REQUIRED_FIELDS=()
if [ -n "$STACK_FILE" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] && REQUIRED_FIELDS+=("$f")
  done < <(read_required_fields "$STACK_FILE")
fi
# Fallback to canonical FR-404 list when the stack file did not yield anything.
if [ "${#REQUIRED_FIELDS[@]}" -eq 0 ]; then
  REQUIRED_FIELDS=(name description version)
fi

# --- Manifest-YAML parse helpers ------------------------------------------
# These mirror the frontmatter helpers in the sibling plugin-frontmatter-validator
# adapter, but operate on the entire YAML body of a manifest.yaml (no `---`
# fence). The manifest is a flat top-level mapping for the fields we check
# (name, description, version) — nested keys (e.g. commands:, agents:) are
# out of scope for the required-field/name-basename rules.

# field_present <manifest-body> <field>  -> exit 0 iff `<field>:` appears at column 0.
field_present() {
  printf '%s\n' "$1" | awk -v f="$2" '
    BEGIN { rc = 1 }
    $0 ~ "^"f"[[:space:]]*:" { rc = 0; exit 0 }
    END { exit rc }
  '
}

# field_value <manifest-body> <field>  -> stdout the trimmed top-level value.
# Portable awk only — no gawk-specific 3-arg match(). Uses sub() to strip the
# leading "<field>:" prefix in place, then trim/dequote/strip-comment.
field_value() {
  printf '%s\n' "$1" | awk -v f="$2" '
    function strip_comment(s) { sub(/[[:space:]]*#.*$/, "", s); return s }
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function dequote(s,    first, last) {
      if (length(s) >= 2) {
        first = substr(s, 1, 1); last = substr(s, length(s), 1)
        if ((first == "\"" && last == "\"") || (first == "'\''" && last == "'\''")) {
          return substr(s, 2, length(s) - 2)
        }
      }
      return s
    }
    $0 ~ ("^"f"[[:space:]]*:") {
      v = $0
      sub("^"f"[[:space:]]*:[[:space:]]*", "", v)
      v = trim(strip_comment(v))
      v = dequote(v)
      print v
      exit
    }
  '
}

# append_finding <rule> <severity> <file> <line> <message>
# Mutates the outer findings_json variable by appending one canonical finding
# object. Centralises the jq -c append so call sites read as five-arg calls
# instead of a nine-line inline jq expression each.
append_finding() {
  local rule="$1" severity="$2" file="$3" line="$4" message="$5"
  findings_json="$(jq -c \
    --arg rule "$rule" \
    --arg severity "$severity" \
    --arg file "$file" \
    --argjson line "$line" \
    --arg message "$message" \
    '. + [{rule: $rule, severity: $severity, file: $file, line: $line, message: $message, blocking: true}]' \
    <<< "$findings_json")"
}

# --- Walk the file list, accumulate findings ------------------------------

# Build a JSON array of findings using jq. We seed with an empty array and
# append one finding per rule violation via append_finding.
findings_json="[]"

while IFS= read -r manifest_path; do
  [ -n "$manifest_path" ] || continue
  case "$manifest_path" in
    *.yaml|*.yml) ;;
    *) continue ;;
  esac

  if [ ! -r "$manifest_path" ]; then
    # Round 1+2 calibration: missing manifest is a "high" finding, never critical.
    append_finding "manifest-not-found" "high" "$manifest_path" 0 \
      "Manifest file not found or unreadable: $manifest_path"
    continue
  fi

  basename_actual="$(basename "$(dirname "$manifest_path")")"
  manifest_body="$(cat "$manifest_path")"

  # Per-required-field check: emit one finding per missing field.
  for field in "${REQUIRED_FIELDS[@]}"; do
    if ! field_present "$manifest_body" "$field"; then
      append_finding "missing-required-field" "high" "$manifest_path" 1 \
        "Missing required manifest field: $field"
    fi
  done

  # Name == basename rule. Only check when the `name` field is present;
  # absence is already reported by the missing-field rule above and re-flagging
  # would double-count.
  if field_present "$manifest_body" "name"; then
    declared_name="$(field_value "$manifest_body" "name")"
    if [ "$declared_name" != "$basename_actual" ]; then
      append_finding "name-equals-basename" "high" "$manifest_path" 1 \
        "Manifest name \"$declared_name\" does not match directory basename \"$basename_actual\""
    fi
  fi
done < "$INPUT"

# --- Emit fragment --------------------------------------------------------

finding_count="$(jq 'length' <<< "$findings_json")"
if [ "$finding_count" -gt 0 ]; then
  status="failed"
else
  status="passed"
fi

fragment="$(jq -nc \
  --arg name "plugin-manifest-validator" \
  --arg status "$status" \
  --argjson findings "$findings_json" \
  '{ name: $name, status: $status, findings: $findings }')"

if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$fragment" > "$OUTPUT"
else
  printf '%s\n' "$fragment"
fi

if [ "$finding_count" -gt 0 ]; then
  exit 2
fi
exit 0
