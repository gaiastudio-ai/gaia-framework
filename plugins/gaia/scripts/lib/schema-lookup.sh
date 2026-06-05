#!/usr/bin/env bash
# schema-lookup.sh — Schema-awareness lookup primitive.
#
# Input
#   --target <file-path>    Required. .csv or .md (SKILL.md frontmatter).
#   --name <name>           Required. Column name (CSV) or frontmatter key (MD).
#
# Behavior
#   - For `.csv` targets: read line 1 (header), split on commas, check
#     whether <name> appears as a column.
#   - For `.md` targets (typically SKILL.md): extract the YAML frontmatter
#     block between the first two `---` lines, parse top-level keys, check
#     whether <name> appears as a key.
#   - Trim whitespace from both header columns and the input name.
#
# Output
#   - Exit 0 if name exists in the resolved schema. No stdout emission.
#   - Exit 1 if name does NOT exist. Stderr lists the valid names from
#     the resolved schema (one per line, prefixed with the canonical
#     `schema-lookup.sh: valid <kind>:` header for downstream parsing).
#   - Exit 2 for usage errors (missing flag, missing target file).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="schema-lookup.sh"
die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit "${2:-2}"; }

TARGET=""
NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target)
      [ $# -ge 2 ] || die "missing value for --target"
      TARGET="$2"; shift 2
      ;;
    --target=*)
      TARGET="${1#*=}"; shift
      ;;
    --name)
      [ $# -ge 2 ] || die "missing value for --name"
      NAME="$2"; shift 2
      ;;
    --name=*)
      NAME="${1#*=}"; shift
      ;;
    -h|--help)
      sed -n '1,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      die "unknown flag: $1"
      ;;
  esac
done

[ -n "$TARGET" ] || die "missing required flag: --target <file-path>"
[ -n "$NAME" ] || die "missing required flag: --name <column-or-field-name>"
[ -f "$TARGET" ] || die "target file not found: $TARGET"

# Trim whitespace from the input name.
NAME_TRIMMED="$(printf '%s' "$NAME" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

case "$TARGET" in
  *.csv)
    # Read line 1 (header), split on commas.
    HEADER="$(head -n1 "$TARGET")"
    [ -n "$HEADER" ] || die "empty CSV: no header line in $TARGET"

    valid_names=()
    IFS=',' read -ra cols <<< "$HEADER"
    for col in "${cols[@]}"; do
      col_trimmed="$(printf '%s' "$col" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$col_trimmed" ] && valid_names+=("$col_trimmed")
    done

    # Membership check.
    for v in "${valid_names[@]+"${valid_names[@]}"}"; do
      if [ "$v" = "$NAME_TRIMMED" ]; then
        exit 0
      fi
    done

    # Miss. List valid names.
    {
      printf 'schema-lookup.sh: valid columns in %s:\n' "$TARGET"
      for v in "${valid_names[@]+"${valid_names[@]}"}"; do
        printf '  %s\n' "$v"
      done
    } >&2
    exit 1
    ;;
  *.md)
    # Extract frontmatter block between first two ^---$ lines, parse
    # top-level YAML keys via awk.
    valid_names_str="$(awk '
      BEGIN { in_fm = 0; depth = 0 }
      /^---[[:space:]]*$/ {
        depth++
        if (depth == 1) { in_fm = 1; next }
        if (depth == 2) { exit }
      }
      in_fm && /^[a-zA-Z_][a-zA-Z0-9_-]*:/ {
        # Strip the colon and anything after.
        key = $0
        sub(/:.*$/, "", key)
        gsub(/[[:space:]]/, "", key)
        print key
      }
    ' "$TARGET")"

    if [ -z "$valid_names_str" ]; then
      printf 'schema-lookup.sh: no YAML frontmatter found in %s\n' "$TARGET" >&2
      exit 1
    fi

    # Membership check.
    while IFS= read -r v; do
      [ -z "$v" ] && continue
      if [ "$v" = "$NAME_TRIMMED" ]; then
        exit 0
      fi
    done <<<"$valid_names_str"

    {
      printf 'schema-lookup.sh: valid frontmatter keys in %s:\n' "$TARGET"
      printf '%s\n' "$valid_names_str" | sed 's/^/  /'
    } >&2
    exit 1
    ;;
  *)
    die "unsupported target extension: $TARGET (expected .csv or .md)"
    ;;
esac
