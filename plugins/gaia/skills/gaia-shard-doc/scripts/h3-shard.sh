#!/usr/bin/env bash
# h3-shard.sh — H3 sharder for gaia-shard-doc.
#
# Splits a Markdown source file at every H3 (`### `) heading into a sibling
# directory of per-section shards plus a `_preamble.md` (content above the
# first H3) and an `index.md` table of contents.
#
# Usage (flag form, preferred):
#   h3-shard.sh --input <source-file> --output-dir <output-dir>
#
# Usage (positional form, retained for backward compatibility):
#   h3-shard.sh <source-file> [<output-dir>]
#
# Default <output-dir> is the source path with `.md` stripped, plus a
# `-shards` suffix (e.g. `04-functional-requirements.md` ->
# `04-functional-requirements-shards/`). The `-shards` suffix avoids name
# collisions with neighbouring numbered shards already present in the
# directory.
#
# Behavioural contract (output is byte-identical for the same input):
#   - one shard per H3.
#   - index.md emitted alongside shards.
#   - repeated runs produce byte-identical output (idempotency).
#
# Exit codes:
#   0 — success
#   1 — source file not found OR no H3 boundaries detected
#   2 — usage error (bad flag, wrong number of positional args)
#
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: h3-shard.sh --input <source-file> --output-dir <output-dir>
       h3-shard.sh <source-file> [<output-dir>]
USAGE
}

SRC=""
OUT_DIR=""

# Argument parser: support both flag (--input/--output-dir) and positional
# forms. Flag form takes precedence — once we see a flag, we expect ALL
# arguments to be flag-formatted.
positional=()
saw_flag=0
while [ $# -gt 0 ]; do
  case "$1" in
    --input)
      saw_flag=1
      [ $# -ge 2 ] || { usage; exit 2; }
      SRC="$2"
      shift 2
      ;;
    --input=*)
      saw_flag=1
      SRC="${1#--input=}"
      shift
      ;;
    --output-dir)
      saw_flag=1
      [ $# -ge 2 ] || { usage; exit 2; }
      OUT_DIR="$2"
      shift 2
      ;;
    --output-dir=*)
      saw_flag=1
      OUT_DIR="${1#--output-dir=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do
        positional+=("$1")
        shift
      done
      ;;
    -*)
      printf 'h3-shard: unknown flag: %s\n' "$1" >&2
      usage
      exit 2
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

if [ "$saw_flag" -eq 1 ]; then
  if [ -z "$SRC" ]; then
    printf 'h3-shard: --input is required\n' >&2
    usage
    exit 2
  fi
  if [ "${#positional[@]}" -gt 0 ]; then
    printf 'h3-shard: cannot mix flag and positional arguments\n' >&2
    usage
    exit 2
  fi
else
  # Positional form: 1 or 2 args.
  if [ "${#positional[@]}" -lt 1 ] || [ "${#positional[@]}" -gt 2 ]; then
    usage
    exit 2
  fi
  SRC="${positional[0]}"
  if [ "${#positional[@]}" -eq 2 ]; then
    OUT_DIR="${positional[1]}"
  fi
fi

if [ ! -f "$SRC" ]; then
  printf 'h3-shard: source not found: %s\n' "$SRC" >&2
  exit 1
fi

if [ -z "$OUT_DIR" ]; then
  base="${SRC%.md}"
  OUT_DIR="${base}-shards"
fi

# Slugify a heading text into a filesystem-safe basename component.
slugify() {
  local s="$1"
  s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')"
  # Replace any non-alphanumeric run with a single hyphen.
  s="$(printf '%s' "$s" | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g')"
  # Trim leading / trailing hyphens.
  s="$(printf '%s' "$s" | sed -E 's/^-+//; s/-+$//')"
  if [ -z "$s" ]; then
    s="section"
  fi
  printf '%s' "$s"
}

mkdir -p "$OUT_DIR"

# Single awk pass: emit per-section payloads to a manifest, then post-process
# in shell. The manifest format is:
#   <section_index>\t<heading_text>\t<line_offset>
# plus the preamble length.
MANIFEST="$(mktemp)"
trap 'rm -f "$MANIFEST"' EXIT

awk -v manifest="$MANIFEST" '
  BEGIN { idx = 0; preamble_lines = 0; }
  /^### / {
    idx += 1
    heading = $0
    sub(/^### /, "", heading)
    print idx "\t" heading "\t" NR > manifest
    next
  }
  {
    if (idx == 0) preamble_lines = NR
  }
  END {
    print "PREAMBLE\t" preamble_lines > manifest
  }
' "$SRC"

total_sections="$(grep -c '^[0-9]' "$MANIFEST" || true)"
if [ "${total_sections:-0}" -eq 0 ]; then
  printf 'h3-shard: no H3 boundaries in %s\n' "$SRC" >&2
  exit 1
fi

# Width for zero-padded numeric prefix.
width=2
if [ "$total_sections" -ge 100 ]; then width=3; fi
if [ "$total_sections" -ge 1000 ]; then width=4; fi

# Read manifest into arrays.
declare -a S_IDX S_HEADING S_OFFSET
preamble_lines=0
while IFS=$'\t' read -r col1 col2 col3; do
  if [ "$col1" = "PREAMBLE" ]; then
    preamble_lines="$col2"
  else
    S_IDX+=("$col1")
    S_HEADING+=("$col2")
    S_OFFSET+=("$col3")
  fi
done < "$MANIFEST"

# Compute slug for each section, with collision disambiguation.
# Use a portable seen-slug list (bash 3 has no associative arrays).
declare -a S_SLUG
SEEN_SLUGS_FILE="$(mktemp)"
trap 'rm -f "$MANIFEST" "$SEEN_SLUGS_FILE"' EXIT
: > "$SEEN_SLUGS_FILE"
seen_slug() {
  grep -Fxq "$1" "$SEEN_SLUGS_FILE"
}
for i in "${!S_IDX[@]}"; do
  raw="$(slugify "${S_HEADING[$i]}")"
  # Cap raw at 80 chars to keep filenames reasonable before disambiguation.
  if [ "${#raw}" -gt 80 ]; then
    raw="${raw:0:80}"
    raw="${raw%-}"
  fi
  candidate="$raw"
  n=2
  while seen_slug "$candidate"; do
    candidate="${raw}-${n}"
    n=$((n + 1))
  done
  printf '%s\n' "$candidate" >> "$SEEN_SLUGS_FILE"
  S_SLUG+=("$candidate")
done

# Total lines in source (so we can compute the last section's end).
total_lines=$(wc -l < "$SRC" | tr -d '[:space:]')

# Emit preamble if any.
if [ "$preamble_lines" -gt 0 ]; then
  head -n "$preamble_lines" "$SRC" > "$OUT_DIR/_preamble.md"
fi

# Emit each section.
INDEX="$OUT_DIR/index.md"
{
  printf '# Index\n\n'
  printf '> Generated by gaia-shard-doc H3 sharder. Source: `%s`.\n\n' "$(basename "$SRC")"
  if [ "$preamble_lines" -gt 0 ]; then
    printf -- '- [_preamble.md](_preamble.md)\n'
  fi
} > "$INDEX"

n="${#S_IDX[@]}"
for i in "${!S_IDX[@]}"; do
  start="${S_OFFSET[$i]}"
  next=$((i + 1))
  if [ "$next" -lt "$n" ]; then
    end=$(( ${S_OFFSET[$next]} - 1 ))
  else
    end="$total_lines"
  fi

  # Zero-padded prefix.
  printf -v prefix "%0${width}d" "${S_IDX[$i]}"
  fname="${prefix}-${S_SLUG[$i]}.md"
  # Cap basename length to 120 chars (slug part) to avoid filesystem limits.
  slug_only="${S_SLUG[$i]}"
  if [ "${#slug_only}" -gt 120 ]; then
    slug_only="${slug_only:0:120}"
    fname="${prefix}-${slug_only}.md"
  fi

  awk -v s="$start" -v e="$end" 'NR >= s && NR <= e' "$SRC" > "$OUT_DIR/$fname"

  printf -- '- [%s](%s)\n' "${S_HEADING[$i]}" "$fname" >> "$INDEX"
done

printf 'h3-shard: wrote %d shards to %s (preamble lines=%d)\n' \
  "$n" "$OUT_DIR" "$preamble_lines" >&2
