#!/usr/bin/env bash
# resume-checkpoint.sh — GAIA V2 checkpoint reader / validator / lister (E43-S6)
#
# Delegated shell helper that /gaia-resume's SKILL.md calls to read and
# validate ADR-059 v1 JSON checkpoints. Per ADR-042 (Scripts-over-LLM for
# Deterministic Operations), every deterministic checkpoint operation —
# listing candidates, parsing JSON, recomputing SHA-256 on referenced
# files, detecting SKILL.md version drift — lives here. The LLM layer
# (gaia-resume SKILL.md) only orchestrates the conversation.
#
# Invocation:
#   resume-checkpoint.sh read     --skill <name> --latest
#   resume-checkpoint.sh read     --path  <file>
#   resume-checkpoint.sh validate --path  <file> --skill-md <path>
#   resume-checkpoint.sh list     [--skill <name>]
#   resume-checkpoint.sh --help | -h
#
# Environment:
#   CHECKPOINT_ROOT   Directory where _memory/checkpoints/{skill}/ lives.
#                     Defaults to _memory/checkpoints (relative to CWD).
#
# Exit codes:
#   0   success
#   1   usage / invalid argument (generic failure exit)
#   2   checkpoint / file missing (list: no checkpoint for requested skill;
#       validate: one or more output_paths files deleted)
#   3   SKILL.md content-hash mismatch between checkpoint and on-disk file
#       (NEW — distinct from output-path drift)
#   4   corrupted checkpoint JSON (routes caller to E43-S7 corruption handler)
#
# Schema v1 (ADR-059 §10.31.3):
#   {
#     "schema_version":        1,
#     "step_number":           <int>,
#     "skill_name":            "<string>",
#     "timestamp":             "<ISO 8601 µs Z>",
#     "key_variables":         { ... },
#     "output_paths":          [ ... ],
#     "file_checksums":        { "<path>": "sha256:<64hex>", ... },
#     "skill_md_content_hash": "sha256:<64hex>"    // optional, E43-S6
#   }
#
# Companion scripts:
#   write-checkpoint.sh    — atomic v1 JSON writer (E43-S1)
#   resume-discovery.sh    — temp-file filtering + corruption classifier
#                            (E43-S7); called by list / read --latest
#
# NFR-052 coverage signal — every public function referenced below is
# exercised through the script's main entry point in e43-s6-resume-contract.bats:
#   cmd_read cmd_validate cmd_list sha256_of latest_for_skill
#   validate_file_checksums validate_skill_md_hash emit_drift_report
#   die usage read_json_field

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="resume-checkpoint.sh"

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
  resume-checkpoint.sh read     --skill <name> --latest
  resume-checkpoint.sh read     --path  <file>
  resume-checkpoint.sh validate --path  <file> --skill-md <path>
  resume-checkpoint.sh list     [--skill <name>]
  resume-checkpoint.sh --help | -h

Subcommands:
  read       Emit the JSON checkpoint on stdout. Pass --skill NAME
             --latest to look up the latest checkpoint for the skill,
             or --path FILE to read a specific checkpoint file.
             Exit 0 ok, 2 not-found, 4 corrupted (invalid JSON).
  validate   Recompute SHA-256 on every file in the checkpoint's
             file_checksums map and, when --skill-md is supplied, on
             the referenced SKILL.md. Exit 0 clean, 1 drift, 2 missing
             output file, 3 SKILL.md content-hash mismatch.
  list       Enumerate every skill under $CHECKPOINT_ROOT/ with a
             resumable checkpoint (excluding completed/). With --skill
             NAME, print only that skill's state; exit 2 + alternatives
             list if no checkpoint exists for NAME.

Environment:
  CHECKPOINT_ROOT   Directory containing _memory/checkpoints/{skill}/
                    subdirectories. Defaults to _memory/checkpoints
                    (relative to CWD).

Exit codes:
  0  success
  1  usage / invalid argument
  2  checkpoint / output file missing
  3  SKILL.md content-hash mismatch
  4  corrupted checkpoint JSON
USAGE
}

# ---------- argv ----------

if [ $# -eq 0 ]; then
  usage >&2
  exit 1
fi

case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
esac

SUBCMD="$1"
shift

# ---------- shared helpers ----------

# E96-S7 partial-4b: smart-fallback for CHECKPOINT_ROOT
if [ -z "${CHECKPOINT_ROOT:-}" ]; then
  if [ -d ".gaia/memory/checkpoints" ]; then
    CHECKPOINT_ROOT=".gaia/memory/checkpoints"
  else
    CHECKPOINT_ROOT="_memory/checkpoints"
  fi
fi

SHA_TOOL=""
if command -v shasum >/dev/null 2>&1; then
  SHA_TOOL="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
  SHA_TOOL="sha256sum"
fi

sha256_of() {
  local p="$1" out
  [ -n "$SHA_TOOL" ] || { emit_err "sha256 tool not found"; return 2; }
  # shellcheck disable=SC2086
  out=$($SHA_TOOL "$p") || return 1
  printf '%s' "${out%% *}"
}

# Validate that a file parses as JSON. Returns 0 iff valid. Consumers
# classify "not valid" as corruption (exit 4).
json_parse_check() {
  local f="$1"
  [ -s "$f" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -e . "$f" >/dev/null 2>&1 && return 0 || return 1
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" >/dev/null 2>&1 \
      && return 0 || return 1
  fi
  # No parser available — err on permissive side; downstream consumer will
  # fail on parse attempt.
  return 0
}

# Read a top-level field from a checkpoint JSON. Uses jq when available
# (preferred), falls back to python3. Returns empty string for missing.
read_json_field() {
  local file="$1" field="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r "(.${field} // empty)" "$file" 2>/dev/null
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" "$field" <<'PY' 2>/dev/null
import json, sys
data = json.load(open(sys.argv[1]))
val = data.get(sys.argv[2], "")
if isinstance(val, (dict, list)):
    print(json.dumps(val))
else:
    print(val if val is not None else "")
PY
    return 0
  fi
  # No JSON parser available — emit nothing; caller treats absence as "not recorded".
  return 0
}

# Discover the latest checkpoint for a skill. Delegates to
# resume-discovery.sh when available (handles temp-file filtering,
# non-canonical filtering, and corruption classification per E43-S7).
# Returns the path on stdout, exit 0 / 2 / 4 to mirror discovery semantics.
latest_for_skill() {
  local skill="$1" discovery
  discovery="$(dirname "$0")/resume-discovery.sh"
  if [ -x "$discovery" ]; then
    local out rc
    # Capture the last line (path) plus exit code; pass-through stderr.
    set +e
    out=$("$discovery" "$skill" 2>&1)
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      # The discovery script emits cleanup guidance BEFORE the resume
      # path — the last non-empty line is the canonical checkpoint path.
      printf '%s\n' "$out" | awk 'NF{last=$0} END{print last}'
      return 0
    fi
    # Propagate discovery exit codes: 2 (no checkpoint) → 2; 3 (corrupted) → 4.
    if [ "$rc" -eq 3 ]; then
      # Emit the discovery output so the caller sees the classified message.
      printf '%s\n' "$out" >&2
      return 4
    fi
    if [ "$rc" -eq 2 ]; then
      return 2
    fi
    return 1
  fi
  # Fallback: plain filesystem scan (no corruption / temp-file handling).
  local dir="$CHECKPOINT_ROOT/$skill"
  [ -d "$dir" ] || return 2
  local latest
  latest=$(find "$dir" -maxdepth 1 -mindepth 1 -type f -name '*.json' \
             -not -name '.*' 2>/dev/null | sort | tail -1)
  if [ -z "$latest" ]; then
    return 2
  fi
  printf '%s\n' "$latest"
  return 0
}

emit_drift_report() {
  # $1 = path, $2 = recorded hash, $3 = actual hash
  emit "drift: $1"
  emit "  recorded: $2"
  emit "  recomputed: $3"
}

# ---------- validate_file_checksums ----------
# Walks the checkpoint's file_checksums object. Returns:
#   0 — every file matches
#   1 — one or more files exist but hash has drifted
#   2 — one or more files have been deleted (missing)
# Drift + missing both possible: reports both, returns 1 (drift) only if no
# files are missing; returns 2 if any are missing.
validate_file_checksums() {
  local cp="$1"
  local missing=0 drift=0
  # Declare loop-local variables up front so `read -r` inside the while
  # does NOT mutate the caller's shadowed variables via bash dynamic
  # scoping (the caller of validate_file_checksums is cmd_validate, which
  # has its own `local path` holding the checkpoint file argument).
  local fc_path fc_recorded actual want

  if command -v jq >/dev/null 2>&1; then
    # Extract path → recorded_hash pairs, tab-separated.
    while IFS=$'\t' read -r fc_path fc_recorded; do
      [ -z "$fc_path" ] && continue
      if [ ! -e "$fc_path" ]; then
        emit "missing file: $fc_path"
        missing=$((missing+1))
        continue
      fi
      actual=$(sha256_of "$fc_path") || { emit_err "sha256 failed on $fc_path"; return 2; }
      want="${fc_recorded#sha256:}"
      if [ "$actual" != "$want" ]; then
        emit_drift_report "$fc_path" "$fc_recorded" "sha256:$actual"
        drift=$((drift+1))
      fi
    done < <(jq -r '.file_checksums | to_entries[] | "\(.key)\t\(.value)"' "$cp" 2>/dev/null)
  else
    # python3 fallback
    while IFS=$'\t' read -r fc_path fc_recorded; do
      [ -z "$fc_path" ] && continue
      if [ ! -e "$fc_path" ]; then
        emit "missing file: $fc_path"
        missing=$((missing+1))
        continue
      fi
      actual=$(sha256_of "$fc_path") || { emit_err "sha256 failed on $fc_path"; return 2; }
      want="${fc_recorded#sha256:}"
      if [ "$actual" != "$want" ]; then
        emit_drift_report "$fc_path" "$fc_recorded" "sha256:$actual"
        drift=$((drift+1))
      fi
    done < <(python3 - "$cp" <<'PY' 2>/dev/null
import json, sys
data = json.load(open(sys.argv[1]))
for p, h in (data.get('file_checksums') or {}).items():
    print(f"{p}\t{h}")
PY
    )
  fi

  if [ "$missing" -gt 0 ]; then
    return 2
  fi
  if [ "$drift" -gt 0 ]; then
    return 1
  fi
  return 0
}

validate_skill_md_hash() {
  # $1 = checkpoint path, $2 = on-disk SKILL.md path (may be /dev/null)
  local cp="$1" sk="$2"
  local recorded
  recorded=$(read_json_field "$cp" "skill_md_content_hash")
  if [ -z "$recorded" ] || [ "$recorded" = "null" ]; then
    # Back-compat: checkpoints written without --skill-md have no hash.
    # Not a mismatch — treat as "skipped".
    return 0
  fi
  if [ ! -f "$sk" ]; then
    # Missing SKILL.md — treat as mismatch (skill definition gone).
    emit "SKILL.md file not found: $sk"
    emit "  recorded hash: $recorded"
    return 3
  fi
  local actual
  actual=$(sha256_of "$sk") || { emit_err "sha256 failed on $sk"; return 2; }
  local want="${recorded#sha256:}"
  if [ "$actual" != "$want" ]; then
    emit "SKILL.md content-hash mismatch — steps and contracts may differ since checkpoint was written."
    emit "  recorded: $recorded"
    emit "  recomputed: sha256:$actual"
    emit "  SKILL.md path: $sk"
    return 3
  fi
  return 0
}

# ---------- cmd_read ----------
# Usage:
#   cmd_read --path FILE
#   cmd_read --skill NAME --latest
cmd_read() {
  local path="" skill="" use_latest=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --path)    [ $# -ge 2 ] || die 1 "--path requires a file"; path="$2"; shift 2 ;;
      --path=*)  path="${1#--path=}"; shift ;;
      --skill)   [ $# -ge 2 ] || die 1 "--skill requires a name"; skill="$2"; shift 2 ;;
      --skill=*) skill="${1#--skill=}"; shift ;;
      --latest)  use_latest=1; shift ;;
      *)         die 1 "unknown argument to read: $1" ;;
    esac
  done

  if [ -z "$path" ] && [ -n "$skill" ] && [ "$use_latest" -eq 1 ]; then
    local resolved rc
    set +e
    resolved=$(latest_for_skill "$skill")
    rc=$?
    set -e
    if [ "$rc" -eq 2 ]; then
      emit "No checkpoint found for skill: $skill"
      emit "Checkpoint directory does not exist or is empty: $CHECKPOINT_ROOT/$skill"
      exit 2
    fi
    if [ "$rc" -eq 4 ]; then
      # resume-discovery already emitted the classified message to stderr.
      emit "corrupted checkpoint for skill $skill — see classification above."
      exit 4
    fi
    [ "$rc" -eq 0 ] || die 1 "failed to resolve latest checkpoint for $skill"
    path="$resolved"
  fi

  if [ -z "$path" ]; then
    die 1 "read requires --path FILE or --skill NAME --latest"
  fi

  if [ ! -f "$path" ]; then
    emit "checkpoint not found: $path"
    exit 2
  fi

  # Enforce extension: ADR-059 is strictly JSON. Legacy .yaml files are
  # rejected here (AC6 — no LLM YAML parser, no silent fallback).
  case "$path" in
    *.json) ;;
    *)
      die 1 "not an ADR-059 JSON checkpoint (expected .json): $path" ;;
  esac

  if ! json_parse_check "$path"; then
    emit "corrupted checkpoint: $path — invalid JSON. Suggestion: re-run the owning skill from scratch, or select a different checkpoint."
    exit 4
  fi

  # Emit the JSON verbatim on stdout. Use jq -c . when available for
  # canonical single-line output; else cat.
  if command -v jq >/dev/null 2>&1; then
    jq -c . "$path"
  else
    cat "$path"
  fi
  exit 0
}

# ---------- cmd_validate ----------
# Usage:
#   cmd_validate --path FILE --skill-md PATH
cmd_validate() {
  local path="" skill_md=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --path)       [ $# -ge 2 ] || die 1 "--path requires a file"; path="$2"; shift 2 ;;
      --path=*)     path="${1#--path=}"; shift ;;
      --skill-md)   [ $# -ge 2 ] || die 1 "--skill-md requires a path"; skill_md="$2"; shift 2 ;;
      --skill-md=*) skill_md="${1#--skill-md=}"; shift ;;
      *)            die 1 "unknown argument to validate: $1" ;;
    esac
  done

  [ -n "$path" ] || die 1 "validate requires --path FILE"
  [ -f "$path" ] || die 1 "checkpoint file not found: $path"

  # Enforce JSON extension — AC6.
  case "$path" in
    *.json) ;;
    *)
      die 1 "not an ADR-059 JSON checkpoint (expected .json): $path" ;;
  esac

  if ! json_parse_check "$path"; then
    emit "corrupted checkpoint: $path — invalid JSON."
    exit 4
  fi

  # File checksums first. Exit 1 (drift) or 2 (missing) takes precedence
  # over SKILL.md drift — the resume contract reports the most immediate
  # recovery action first.
  local file_rc=0
  set +e
  validate_file_checksums "$path"
  file_rc=$?
  set -e

  local skill_md_rc=0
  if [ -n "$skill_md" ] && [ "$skill_md" != "/dev/null" ]; then
    set +e
    validate_skill_md_hash "$path" "$skill_md"
    skill_md_rc=$?
    set -e
  fi

  # Precedence: missing (2) > drift (1) > skill_md mismatch (3) > clean (0).
  if [ "$file_rc" -eq 2 ]; then
    emit "One or more output files missing — safe to [Start fresh]."
    exit 2
  fi
  if [ "$file_rc" -eq 1 ]; then
    emit "One or more output files drifted — options: [Proceed] [Start fresh] [Review]."
    exit 1
  fi
  if [ "$skill_md_rc" -eq 3 ]; then
    emit "SKILL.md has changed since this checkpoint was written. Options: [Proceed with acknowledgment] [Abort]."
    exit 3
  fi
  emit "All file_checksums match — safe to resume."
  exit 0
}

# ---------- cmd_list ----------
# Usage:
#   cmd_list                 — list every skill with a checkpoint
#   cmd_list --skill NAME    — report NAME's state; exit 2 + alternatives
#                              if NAME has no checkpoint.
cmd_list() {
  local target_skill=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --skill)   [ $# -ge 2 ] || die 1 "--skill requires a name"; target_skill="$2"; shift 2 ;;
      --skill=*) target_skill="${1#--skill=}"; shift ;;
      *)         die 1 "unknown argument to list: $1" ;;
    esac
  done

  if [ ! -d "$CHECKPOINT_ROOT" ]; then
    if [ -n "$target_skill" ]; then
      emit "No checkpoint found for skill: $target_skill"
      emit "Checkpoint root does not exist: $CHECKPOINT_ROOT"
      exit 2
    fi
    emit "No checkpoints under: $CHECKPOINT_ROOT"
    exit 0
  fi

  # Enumerate skill directories (exclude 'completed'). Emit one record per
  # skill with a resumable checkpoint — each record is a tab-separated
  # line of "skill<TAB>step<TAB>ts<TAB>path". Parallel arrays rather than
  # associative arrays so the script runs under bash 3.x (macOS default).
  local skills=()
  local steps=()
  local tses=()
  local paths=()

  local skill_dirs=()
  while IFS= read -r -d '' d; do
    local dbase
    dbase=$(basename "$d")
    [ "$dbase" = "completed" ] && continue
    skill_dirs+=("$d")
  done < <(find "$CHECKPOINT_ROOT" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)

  local d
  for d in "${skill_dirs[@]:-}"; do
    [ -z "$d" ] && continue
    local base
    base=$(basename "$d")
    # Find latest *.json under d (non-recursive).
    local latest
    latest=$(find "$d" -maxdepth 1 -mindepth 1 -type f -name '*.json' -not -name '.*' 2>/dev/null \
              | sort | tail -1)
    if [ -z "$latest" ]; then
      continue
    fi
    # Extract step and timestamp from filename (canonical: {ts}-step-{N}.json).
    local fname step ts
    fname=$(basename "$latest")
    step=$(printf '%s' "$fname" | sed -n 's/.*-step-\([0-9][0-9]*\)\.json$/\1/p')
    ts=$(printf '%s' "$fname" | sed -n 's/^\([0-9T:\.Z-]\{1,\}\)-step-.*/\1/p')
    skills+=("$base")
    steps+=("${step:-?}")
    tses+=("${ts:-?}")
    paths+=("$latest")
  done

  local n="${#skills[@]}"

  # Helper: find index of target_skill in skills[] — echoes index or empty.
  find_idx() {
    local target="$1"
    local i=0
    while [ "$i" -lt "$n" ]; do
      if [ "${skills[$i]}" = "$target" ]; then
        printf '%s' "$i"
        return 0
      fi
      i=$((i+1))
    done
    return 1
  }

  if [ -n "$target_skill" ]; then
    local idx
    if idx=$(find_idx "$target_skill"); then
      emit "${target_skill}: step ${steps[$idx]} at ${tses[$idx]}"
      emit "  path: ${paths[$idx]}"
      exit 0
    fi
    emit "No checkpoint found for skill: $target_skill"
    if [ "$n" -gt 0 ]; then
      emit "Resumable alternatives:"
      local i=0
      while [ "$i" -lt "$n" ]; do
        emit "  - ${skills[$i]}: step ${steps[$i]} at ${tses[$i]}"
        i=$((i+1))
      done
    else
      emit "(no other resumable checkpoints under $CHECKPOINT_ROOT)"
    fi
    exit 2
  fi

  if [ "$n" -eq 0 ]; then
    emit "No resumable checkpoints under: $CHECKPOINT_ROOT"
    exit 0
  fi
  emit "Resumable checkpoints:"
  local i=0
  while [ "$i" -lt "$n" ]; do
    emit "  - ${skills[$i]}: step ${steps[$i]} at ${tses[$i]}"
    i=$((i+1))
  done
  exit 0
}

# ---------- dispatch ----------

case "$SUBCMD" in
  read)     cmd_read     "$@" ;;
  validate) cmd_validate "$@" ;;
  list)     cmd_list     "$@" ;;
  *)        die 1 "unknown subcommand: $SUBCMD (use --help)" ;;
esac
