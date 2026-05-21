#!/usr/bin/env bash
# resume-discovery.sh — GAIA V2 checkpoint discovery + corruption classifier (E43-S7)
#
# Lists candidate checkpoint files for a given skill, filters out temp files
# and non-canonical filenames, then validates that the latest remaining
# candidate parses as JSON. Prints the path of the resume target on success
# and emits a classified, user-visible error message with cleanup guidance
# on any failure path.
#
# Delegated to by the gaia-resume skill (SKILL.md) per ADR-042
# (Scripts-over-LLM for Deterministic Operations). The skill body remains
# the LLM-controlled orchestrator; this script is the deterministic primitive.
#
# Invocation:
#   resume-discovery.sh <skill_name>
#   resume-discovery.sh --help | -h
#
# Environment:
#   CHECKPOINT_ROOT   Directory where _memory/checkpoints/{skill}/ lives.
#                     Defaults to _memory/checkpoints (relative to CWD).
#
# Exit codes (aligned with story E43-S7 Dev Notes):
#   0   success — latest valid checkpoint found; path printed to stdout.
#   1   generic failure (usage error, malformed argument).
#   2   no checkpoint found for skill (after temp/non-canonical filtering).
#   3   corrupted checkpoint — latest candidate fails to parse as JSON.
#
# Canonical filename pattern (from E43-S1):
#   {ISO8601-microseconds-Z}-step-{N}.json
#   Example: 2026-04-24T14:30:00.123456Z-step-3.json
#
# Temp-file patterns filtered from discovery:
#   {canonical}.tmp.{pid}     — write-checkpoint.sh atomic-write temp
#   .tmp-*.json               — leading-dot alternate convention (defensive)
#   *.partial                 — alternate convention (defensive)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="resume-discovery.sh"

emit() { printf '%s\n' "$*"; }
emit_err() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

die() {
  local rc="$1"; shift
  emit_err "$*"
  exit "$rc"
}

usage() {
  cat <<'USAGE'
Usage:
  resume-discovery.sh <skill_name>
  resume-discovery.sh --help | -h

Lists candidate checkpoints under $CHECKPOINT_ROOT/<skill_name>/, filters
temp files and non-canonical filenames, selects the latest surviving
candidate, and validates it parses as JSON. Prints the selected path on
success; emits a classified error with cleanup guidance on any failure.

Environment:
  CHECKPOINT_ROOT   Directory containing _memory/checkpoints/{skill}/ sub-
                    directories. Defaults to _memory/checkpoints (relative
                    to CWD).

Exit codes:
  0   success — path to selected checkpoint on stdout.
  1   usage / invalid argument (generic failure exit).
  2   no checkpoint found for skill (after filtering, exit 2).
  3   corrupted checkpoint — latest candidate fails to parse as JSON (exit 3).
USAGE
}

# ---------- arg parsing ----------

if [ $# -eq 0 ]; then
  usage >&2
  exit 1
fi

case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
  --*)
    die 1 "unknown flag: $1"
    ;;
esac

SKILL_NAME="$1"
shift || true

case "$SKILL_NAME" in
  ''|*/*|*..*|.*|*\\*|*\ *)
    die 1 "invalid skill_name: $SKILL_NAME" ;;
esac
if ! printf '%s' "$SKILL_NAME" | grep -Eq '^[a-z0-9][a-z0-9-]{0,63}$'; then
  die 1 "invalid skill_name: $SKILL_NAME"
fi

# AF-2026-05-21-7 inverted precedence: canonical default, legacy fallback
# only on positive pre-ADR-111 evidence (legacy dir exists AND canonical doesn't).
if [ -z "${CHECKPOINT_ROOT:-}" ]; then
  if [ -d "_memory/checkpoints" ] && [ ! -d ".gaia/memory" ]; then
    CHECKPOINT_ROOT="_memory/checkpoints"
  else
    CHECKPOINT_ROOT=".gaia/memory/checkpoints"
  fi
fi
SKILL_DIR="$CHECKPOINT_ROOT/$SKILL_NAME"

# ---------- Canonical / temp regexes ----------
# POSIX ERE for canonical filename:
#   YYYY-MM-DDTHH:MM:SS.ffffffZ-step-N.json
CANONICAL_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z(-pid[0-9]+)?-step-[0-9]+\.json$'
# Temp patterns (checked against basename):
#   *.tmp.{pid}    — write-checkpoint.sh convention
#   .tmp-*.json    — leading-dot alternate
#   *.partial      — alternate
is_temp_name() {
  local name="$1"
  case "$name" in
    .tmp-*.json)       return 0 ;;
    *.tmp.[0-9]*)      return 0 ;;
    *.partial)         return 0 ;;
  esac
  return 1
}

is_canonical_name() {
  local name="$1"
  printf '%s' "$name" | grep -Eq "$CANONICAL_RE"
}

# ---------- JSON validator ----------
# Prefer jq → python3 → none. Returns 0 iff file parses as JSON.
json_parse_check() {
  local f="$1"
  if [ ! -s "$f" ]; then
    return 1  # empty file → corrupted
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -e . "$f" >/dev/null 2>&1 && return 0 || return 1
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" >/dev/null 2>&1 \
      && return 0 || return 1
  fi
  # No parser available — treat as uncheckable but present. Non-empty file
  # with no parser is assumed parseable (will fail later when consumer parses
  # it). We err on the side of NOT blocking resume if we can't actually tell.
  return 0
}

# ---------- Listing ----------

# If the skill dir does not exist at all, treat as "no checkpoints".
if [ ! -d "$SKILL_DIR" ]; then
  emit "No checkpoint found for skill: $SKILL_NAME"
  emit "Checkpoint directory does not exist: $SKILL_DIR"
  exit 2
fi

# Collect every regular file under the skill dir (not recursive).
# Include dotfiles (temp files with leading dot).
ALL_FILES=()
# shellcheck disable=SC2044  # filenames here are controlled (no newlines)
while IFS= read -r -d '' f; do
  ALL_FILES+=("$f")
done < <(find "$SKILL_DIR" -maxdepth 1 -mindepth 1 -type f -print0 2>/dev/null)

CANDIDATES=()
TEMP_FILES=()
NONCANON_FILES=()

for f in "${ALL_FILES[@]:-}"; do
  [ -z "$f" ] && continue
  base=$(basename -- "$f")
  if is_temp_name "$base"; then
    TEMP_FILES+=("$f")
    continue
  fi
  if is_canonical_name "$base"; then
    CANDIDATES+=("$f")
  else
    NONCANON_FILES+=("$f")
  fi
done

# ---------- Cleanup guidance ----------
# Emit BEFORE the resume action (per story Dev Notes "Cleanup guidance shape").
emit_cleanup_guidance() {
  local n_temp="${#TEMP_FILES[@]}"
  local n_noncanon="${#NONCANON_FILES[@]}"
  if [ "$n_temp" -gt 0 ]; then
    emit "Found $n_temp orphan temp file(s) in $SKILL_DIR/ — safe to delete."
    for t in "${TEMP_FILES[@]}"; do
      local sz
      sz=$(wc -c < "$t" 2>/dev/null | tr -d ' ' || echo 0)
      emit "  - $t ($sz bytes)"
    done
    emit "Run: rm $SKILL_DIR/.tmp-*.json $SKILL_DIR/*.tmp.* 2>/dev/null"
  fi
  if [ "$n_noncanon" -gt 0 ]; then
    emit "Found $n_noncanon non-canonical file(s) in $SKILL_DIR/ — not a valid checkpoint name."
    for t in "${NONCANON_FILES[@]}"; do
      emit "  - $t (cleanup candidate)"
    done
  fi
}

# ---------- Exit 2: no candidates after filtering ----------
if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  emit "No checkpoint found for skill: $SKILL_NAME"
  emit_cleanup_guidance
  exit 2
fi

# ---------- Select latest candidate (sort by filename == sort by timestamp) ----------
# Sort ascending; last entry is the newest.
SORTED=()
while IFS= read -r line; do
  [ -n "$line" ] && SORTED+=("$line")
done < <(printf '%s\n' "${CANDIDATES[@]}" | sort)

LATEST="${SORTED[$((${#SORTED[@]} - 1))]}"

# ---------- Validate the latest, and any other candidates for multi-corruption report ----------
CORRUPTED=()
for c in "${SORTED[@]}"; do
  if ! json_parse_check "$c"; then
    CORRUPTED+=("$c")
  fi
done

# Non-blocking: cleanup guidance is printed FIRST so the user sees it even
# when the resume succeeds.
emit_cleanup_guidance

# If the latest candidate is corrupted, exit 3 with a structured multi-corruption report.
latest_is_corrupted=0
for c in "${CORRUPTED[@]:-}"; do
  [ -z "$c" ] && continue
  if [ "$c" = "$LATEST" ]; then
    latest_is_corrupted=1
    break
  fi
done

if [ "$latest_is_corrupted" -eq 1 ]; then
  # Classify the latest file: empty / syntax / binary
  reason="invalid JSON"
  if [ ! -s "$LATEST" ]; then
    reason="empty file"
  elif ! LC_ALL=C grep -aq . "$LATEST" 2>/dev/null; then
    reason="non-text / binary content"
  fi
  emit "corrupted checkpoint: $LATEST — $reason. Suggestion: re-run /gaia-$SKILL_NAME from scratch, or select a different checkpoint from $SKILL_DIR."
  if [ "${#CORRUPTED[@]}" -gt 1 ]; then
    emit "Additional corrupted checkpoint(s) in $SKILL_DIR/:"
    for c in "${CORRUPTED[@]}"; do
      [ "$c" = "$LATEST" ] && continue
      emit "  - corrupted checkpoint: $c"
    done
  fi
  # How many uncorrupted candidates remain (user may want to resume from an
  # earlier step rather than re-run from scratch).
  good=0
  for c in "${SORTED[@]}"; do
    c_is_corrupt=0
    for d in "${CORRUPTED[@]:-}"; do
      [ "$d" = "$c" ] && c_is_corrupt=1 && break
    done
    [ "$c_is_corrupt" -eq 0 ] && good=$((good+1))
  done
  if [ "$good" -gt 0 ]; then
    emit "Uncorrupted earlier checkpoint(s) available: $good — you may resume from an earlier step."
  fi
  exit 3
fi

# Latest is valid. Still report any OTHER corrupted checkpoints as info.
if [ "${#CORRUPTED[@]}" -gt 0 ]; then
  emit "Note: $SKILL_DIR/ contains ${#CORRUPTED[@]} corrupted checkpoint(s) older than the latest — safe to delete."
  for c in "${CORRUPTED[@]}"; do
    emit "  - corrupted checkpoint: $c"
  done
fi

emit "$LATEST"
exit 0
