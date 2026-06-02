#!/usr/bin/env bash
# validate-canonical-filename.sh — gaia-create-story Step 6 deterministic
#                                  filename-drift check (E63-S4 / Work Item 6.10)
#
# Purpose:
#   Verify a story file's basename equals `{key}-{slugify(title)}.md` by
#   reading frontmatter (`key`, `title`) and slugifying the title via the
#   sibling `slugify.sh` (E63-S1). Surfaces filename drift deterministically
#   BEFORE Val dispatch in Step 6 of /gaia-create-story, saving Val tokens
#   on the trivial mismatch class.
#
# Consumers:
#   - /gaia-create-story Step 6 — pre-Val deterministic sweep
#   - E63-S5 validate-frontmatter.sh — folds this check in per source spec
#     6.10 integration note (rather than duplicating slug-comparison logic).
#
# Contract source:
#   - .gaia/artifacts/planning-artifacts/feature-create-story-hardening.md#Work-Item-6.10
#   - .gaia/artifacts/planning-artifacts/architecture.md §Decision Log — ADR-074
#     (deterministic-script lift)
#   - Sibling: gaia-framework/plugins/gaia/skills/gaia-create-story/scripts/slugify.sh
#
# Algorithm (in order):
#   1. Parse CLI: `--file <path>` (single required flag).
#   2. Resolve sibling `slugify.sh` via `$(dirname BASH_SOURCE)/slugify.sh`.
#      Error if missing or non-executable.
#   3. Verify the target file is readable.
#   4. Extract YAML frontmatter (block between the first two `---` lines).
#      Error 1 if no frontmatter is present.
#   5. Parse `key` and `title` from frontmatter (quote-tolerant: handles
#      `"x"`, `'x'`, and bare `x`). Error 1 if either is missing.
#   6. Compute `expected_basename = ${key}-$(slugify --title ${title}).md`.
#   7. Compare to the actual basename. Exit 0 on match.
#   8. On mismatch, emit one stderr line and exit 2.
#
# Exit codes:
#   0 — basename matches the canonical form
#   1 — usage error, missing file, missing frontmatter, missing required
#       field, or sibling-script resolution failure
#   2 — filename drift (canonical "validation found issue" code)
#
# Stderr discipline:
#   Emit ONE single-line message and exit. The caller decides whether to
#   aggregate findings.
#
# Locale invariance:
#   `LC_ALL=C` is set so awk/grep/sed character classes are byte-level and
#   identical on macOS BSD and Linux GNU.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="validate-canonical-filename.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLUGIFY="${SCRIPT_DIR}/slugify.sh"

usage() {
  cat >&2 <<'USAGE'
Usage: validate-canonical-filename.sh --file <story-file>
       validate-canonical-filename.sh <story-file>          (deprecated positional form — emits NOTICE)

  --file <path>  Path to a story file. Required.

Verifies that basename(<story-file>) equals "{key}-{slug(title)}.md", where
key and title are parsed from YAML frontmatter and slug is computed by the
sibling slugify.sh script.

Exit codes:
  0 — basename matches
  1 — usage error, missing file, missing frontmatter / required field,
      or sibling slugify.sh missing
  2 — filename drift (basename does not match the canonical form)
USAGE
}

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die_usage() { log "$*"; usage; exit 1; }
die_input() { log "$*"; exit 1; }
die_drift() { log "$*"; exit 2; }

# ---------- CLI parsing ----------

file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      [ $# -ge 2 ] || die_usage "--file requires a value"
      file="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    --*)
      die_usage "unknown argument: $1" ;;
    *)
      # AF-2026-05-30-4 D-05 — positional path form is accepted with a
      # deprecation NOTICE. Canonical form is `--file <path>`.
      if [ -n "$file" ]; then
        die_usage "positional path '$1' supplied after --file '$file' — use only one form"
      fi
      log "NOTICE: positional path is deprecated; prefer '--file $1' (AF-2026-05-30-4 D-05)"
      file="$1"; shift ;;
  esac
done

[ -n "$file" ] || die_usage "--file is required (or pass a positional path; --file is canonical)"
[ -r "$file" ] || die_input "file not readable: $file"

# ---------- Sibling slugify.sh resolution ----------

if [ ! -f "$SLUGIFY" ]; then
  die_input "sibling script slugify.sh not found at: $SLUGIFY"
fi
if [ ! -x "$SLUGIFY" ]; then
  die_input "sibling script slugify.sh is not executable: $SLUGIFY"
fi

# ---------- Frontmatter extraction ----------
#
# Extract the block between the first two `---` lines using an awk state
# machine (not a range pattern — see gaia-shell-idioms for the awk range-bug
# rationale). The script tolerates leading blank lines before the opening
# fence but requires the fence to be `---` on its own line (the standard
# YAML frontmatter convention used by every story file in this repo).
#
# Single-pass design: stdout carries the frontmatter body, exit status
# carries the validity verdict (0 = closed cleanly, 4 = never opened or
# never closed). Bash's `set -e` would otherwise kill the script on the
# non-zero awk exit, so we capture the status via a `|| status=$?` idiom
# before evaluating it.

fm_status=0
frontmatter="$(awk '
  BEGIN { state = 0 }
  {
    if (state == 0) {
      if ($0 == "---") { state = 1; next }
      # Allow leading blank lines before the opening fence; any non-blank,
      # non-fence line means the file has no frontmatter.
      if ($0 ~ /^[[:space:]]*$/) next
      state = 2
      exit
    }
    if (state == 1) {
      if ($0 == "---") { state = 3; exit }
      print
    }
  }
  END {
    # state 3 = closed cleanly. state 1 = opened but never closed.
    # state 2 = never opened. state 0 = empty file. The script surfaces
    # everything except state 3 as "no frontmatter" — repairing malformed
    # files is out of scope.
    if (state == 3) exit 0
    exit 4
  }
' "$file")" || fm_status=$?

if [ "$fm_status" -ne 0 ]; then
  die_input "no frontmatter found in: $file"
fi

# ---------- Field extraction (quote-tolerant) ----------
#
# Match `^<label>:[[:space:]]+<value>$` (allowing optional whitespace).
# Strip a single pair of surrounding double or single quotes from the value.
# Trim trailing whitespace.

extract_field() {
  local label="$1" raw value
  raw="$(printf '%s\n' "$frontmatter" | awk -v lab="$label" '
    {
      pat = "^" lab ":[[:space:]]*"
      if (match($0, pat)) {
        v = substr($0, RSTART + RLENGTH)
        # Trim trailing whitespace.
        sub(/[[:space:]]+$/, "", v)
        print v
        exit
      }
    }
  ')"
  # Strip surrounding double or single quotes if present.
  case "$raw" in
    \"*\") value="${raw#\"}"; value="${value%\"}" ;;
    \'*\') value="${raw#\'}"; value="${value%\'}" ;;
    *) value="$raw" ;;
  esac
  printf '%s' "$value"
}

key="$(extract_field "key")"
title="$(extract_field "title")"

[ -n "$key" ]   || die_input "missing field 'key' in frontmatter of: $file"
[ -n "$title" ] || die_input "missing field 'title' in frontmatter of: $file"

# ---------- E105-S1 / ADR-127 — new per-story nested layout ----------
# In the new layout the file is `story.md` and the PARENT DIRECTORY carries the
# key + slug: `epic-{slug}/{key}-{story-slug}/story.md`.
#
# AF-2026-05-31-3 / Test14 F-12 — strict slug check.
#
# The prior implementation accepted ANY directory beginning with `${key}-`
# (case `"${key}-"*)`). That was looser than validate-frontmatter.sh, which
# CRITICAL-rejects unless the dir slug equals `slugify(title)`. The split
# was a latent footgun: a directory that passed validate-canonical-filename
# could still fail validate-frontmatter, surfacing as confusing CRITICAL
# verdicts deep in the review pipeline rather than as an actionable error
# at story-creation time. Compute slugify(title) HERE and require the dir
# to be exactly `${key}-${slug}` so both validators agree (closes the
# latent-footgun bug class documented in Test14 F-12).
actual_basename="$(basename "$file")"
if [ "$actual_basename" = "story.md" ]; then
  parent_dir="$(basename "$(dirname "$file")")"
  _expected_slug=""
  if ! _expected_slug="$("$SLUGIFY" --title "$title" 2>/dev/null)"; then
    die_input "slugify.sh failed for title: $title"
  fi
  _expected_dir="${key}-${_expected_slug}"
  if [ "$parent_dir" = "$_expected_dir" ]; then
    log "new per-story layout accepted — dir '${parent_dir}' matches slugify(title)"
    exit 0
  fi
  case "$parent_dir" in
    "${key}-"*)
      die_drift "new-layout slug drift -- expected dir '${_expected_dir}/' (key + slugify(title)), got '${parent_dir}/' — title='${title}'"
      ;;
    *)
      die_drift "new-layout key drift -- frontmatter key '${key}' does not match parent directory '${parent_dir}'"
      ;;
  esac
fi

# ---------- Compute expected basename (legacy {key}-{slug}.md) ----------

slug=""
if ! slug="$("$SLUGIFY" --title "$title" 2>/dev/null)"; then
  die_input "slugify.sh failed for title: $title"
fi

expected_basename="${key}-${slug}.md"

# ---------- Compare ----------

if [ "$expected_basename" != "$actual_basename" ]; then
  die_drift "filename drift -- expected '${expected_basename}', got '${actual_basename}'"
fi

# ---------- E79-S4 — canonical-layout shadow / flat-fallback rules ----------
#
# Beyond the basename match, enforce the canonical-per-epic layout contract:
#
#   - nested + flat sibling for same {key}     -> REJECT (shadow ambiguity)
#   - nested only                              -> ACCEPT silently
#   - flat only (pre-migration legacy state)   -> ACCEPT with stderr WARNING
#
# Project root resolution: walk up from $file until we find a directory
# whose path ends in "/.gaia/artifacts/implementation-artifacts" — the parent of that
# dir is the project root. If we cannot locate the docs subtree, skip the
# shadow check (non-canonical layout context, e.g. unit-test fixtures
# without a docs/ tree).

resolve_impl_dir() {
  # AF-2026-05-21-25: also recognize canonical .gaia/artifacts/implementation-artifacts.
  local p
  p="$(cd "$(dirname "$1")" && pwd)"
  while [ "$p" != "/" ] && [ -n "$p" ]; do
    case "$p" in
      */.gaia/artifacts/implementation-artifacts) printf '%s' "$p"; return 0 ;;
      */.gaia/artifacts/implementation-artifacts/*) p="${p%/*}" ;;
      */docs/implementation-artifacts) printf '%s' "$p"; return 0 ;;
      */docs/implementation-artifacts/*) p="${p%/*}" ;;
      *) p="${p%/*}" ;;
    esac
  done
  return 1
}

impl_dir=""
if impl_dir="$(resolve_impl_dir "$file")"; then
  # Locate any flat-path sibling for the same key at the docs root.
  flat_sibling=""
  while IFS= read -r -d '' candidate; do
    [ -f "$candidate" ] || continue
    flat_sibling="$candidate"
    break
  done < <(find "$impl_dir" -maxdepth 1 -type f -name "${key}-*.md" -print0 2>/dev/null)

  # Determine whether the file under validation is itself the flat sibling
  # (basename-equal AND parent-dir-equal to impl_dir) — bash test by realpath.
  file_real="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
  flat_self=0
  if [ -n "$flat_sibling" ]; then
    sibling_real="$(cd "$(dirname "$flat_sibling")" && pwd)/$(basename "$flat_sibling")"
    if [ "$sibling_real" = "$file_real" ]; then
      flat_self=1
    fi
  fi

  # Locate any nested-path sibling for the same key under epic-*/stories/.
  nested_sibling=""
  while IFS= read -r -d '' candidate; do
    [ -f "$candidate" ] || continue
    case "$(basename "$candidate")" in
      "${key}-"*.md)
        nested_sibling="$candidate"
        break
        ;;
    esac
  done < <(find "$impl_dir" -path '*/stories/*.md' -type f -print0 2>/dev/null)

  if [ -n "$flat_sibling" ] && [ -n "$nested_sibling" ] && [ "$flat_self" -eq 0 ]; then
    # Shadow state: validating the nested file with a flat sibling for the
    # same key still on disk. Refuse — operator must migrate or delete the
    # flat sibling before the E79-S6 backfill runs.
    log "legacy-flat sibling detected for ${key}: ${flat_sibling} — refusing to validate while shadow exists"
    exit 2
  fi

  if [ "$flat_self" -eq 1 ] && [ -z "$nested_sibling" ]; then
    # Flat-only legacy state — accept with WARNING.
    log "legacy-flat path accepted (read-only fallback) — migrate via E79-S6"
    exit 0
  fi

  if [ "$flat_self" -eq 1 ] && [ -n "$nested_sibling" ]; then
    # User is validating the FLAT side of a shadow pair — same refusal.
    log "legacy-flat sibling detected for ${key}: ${flat_sibling} — refusing to validate while shadow exists"
    exit 2
  fi
fi

exit 0
