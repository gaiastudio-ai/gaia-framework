#!/usr/bin/env bash
# check-sub-shard-conflict.sh — guard against /gaia-shard-doc destroying an
# existing marker-shard + sibling-directory sub-shard layout.
#
# Option A — Preserve marker stub.
#
# Contract:
#
#   $1 = slug   — the canonical NN-slug for the H2 about to be sharded
#                 (e.g. "04-functional-requirements"). NO `.md` extension.
#   $2 = out_dir — the output directory where /gaia-shard-doc would write
#                  shards (e.g. ".gaia/artifacts/planning-artifacts/prd"). The sibling
#                  directory check looks at "$out_dir/$slug/".
#
# Behaviour:
#
#   - Exit 0 (safe to write) when the sibling directory does NOT exist, OR
#     when it exists but contains ONLY meta files (index.md, _preamble.md,
#     dotfiles). Meta-only directory == "user manually deleted all content
#     shards intending to re-shard" — proceed normally.
#
#   - Exit 2 (preserve — refusal advisory) when the sibling directory
#     exists AND contains ≥1 content shard matching the canonical pattern
#     `<NN>-*.md` where `<NN>` is a two-digit numeric prefix. Emits the
#     preserve signal on THREE channels:
#       1. stdout: `preserved: <slug> (sub-shard directory <dir> intact)`
#       2. stderr: `WARNING: preserved: <slug> (sub-shard directory <dir> intact)`
#       3. summary file (if --summary-file passed): append a
#          `Preserved sub-shards: <slug>` line to the file.
#     The caller (SKILL.md Step 4) SHOULD check exit code 2 and, when seen,
#     skip emitting that section's body — the existing marker shard at
#     `<out_dir>/<slug>.md` is preserved byte-identical.
#
#   - Exit 1 (usage error) when args are missing or malformed.
#
# Refusal is ABSOLUTE. There is NO `--force-destroy` flag. The only
# documented destruction path is the manual two-step workflow:
# `/gaia-merge-docs <dir> > <slug>.md && rm -rf <dir>`, then re-shard.
# See gaia-shard-doc/SKILL.md `## Sub-shard directories`.
#
# This helper performs NO writes under the sibling directory. Byte-equality
# of the sibling directory is preserved by construction (we only read it).
#
# h3-shard.sh and parse-h2-boundaries.sh are NOT modified. This is a new
# pre-emission gate, not a rewrite of the existing H2/H3 path.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-shard-doc/check-sub-shard-conflict.sh"

usage() {
  cat <<'USAGE' >&2
Usage:
  check-sub-shard-conflict.sh <slug> <out_dir> [--summary-file <path>]

Returns:
  0 — safe to write (sibling dir absent, or meta-only)
  2 — preserve (sibling dir exists with ≥1 content shard)
  1 — usage error
USAGE
}

die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  usage
  exit 1
}

# ---------- Argument parsing ----------

SLUG=""
OUT_DIR=""
SUMMARY_FILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --summary-file)
      [ "$#" -ge 2 ] || die "--summary-file requires a value"
      SUMMARY_FILE="$2"; shift 2
      ;;
    --summary-file=*)
      SUMMARY_FILE="${1#--summary-file=}"; shift
      ;;
    --help|-h)
      usage; exit 0
      ;;
    --*)
      die "unknown flag: $1"
      ;;
    *)
      if [ -z "$SLUG" ]; then
        SLUG="$1"
      elif [ -z "$OUT_DIR" ]; then
        OUT_DIR="$1"
      else
        die "unexpected positional argument: $1"
      fi
      shift
      ;;
  esac
done

[ -n "$SLUG" ] || die "slug argument is required"
[ -n "$OUT_DIR" ] || die "out_dir argument is required"

# Defensive: strip a trailing .md if the caller accidentally passed
# "04-functional-requirements.md" instead of the bare slug.
SLUG="${SLUG%.md}"

# ---------- Detection gate ----------

SIBLING_DIR="$OUT_DIR/$SLUG"

# Sibling dir doesn't exist -> safe.
if [ ! -d "$SIBLING_DIR" ]; then
  exit 0
fi

# Count CONTENT shards only — files matching `<NN>-*.md` where
# `<NN>` is a two-digit numeric prefix. Meta files (`index.md`,
# `_preamble.md`, anything starting with `_` or `.`) are ignored.
# A meta-only directory means the user manually deleted all content
# shards intending to re-shard — the gate is a no-op, proceed normally.
content_shard=$(find "$SIBLING_DIR" -maxdepth 1 -type f -name '[0-9][0-9]-*.md' 2>/dev/null | head -1)

if [ -z "$content_shard" ]; then
  # Meta-only or empty directory — re-shard is safe.
  exit 0
fi

# ---------- Preserve signal ----------

MSG="preserved: $SLUG (sub-shard directory $SIBLING_DIR intact)"

# Channel 1: stdout.
printf '%s\n' "$MSG"

# Channel 2: stderr WARNING (visible in CI logs / pipelines that drop stdout).
printf 'WARNING: %s\n' "$MSG" >&2

# Channel 3: summary file (Step-5 final summary report includes
# `Preserved sub-shards: <count>` aggregation). The caller
# concatenates the lines from this file and counts them.
if [ -n "$SUMMARY_FILE" ]; then
  printf 'Preserved sub-shards: %s\n' "$SLUG" >> "$SUMMARY_FILE"
fi

# Exit 2 — preserve advisory (distinct from exit 0 clean run and exit
# 1 usage error). The caller distinguishes the three states.
exit 2
