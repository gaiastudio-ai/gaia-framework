#!/usr/bin/env bash
# sprint-state.sh — GAIA foundation script (E28-S11)
#
# Validates sprint state machine transitions, updates the story file
# frontmatter + body `**Status:**` line and `sprint-status.yaml` atomically,
# and emits a lifecycle event on every successful transition. Replaces the
# LLM-interpreted status-sync protocol with a deterministic, race-safe
# script per ADR-042 / ADR-048.
#
# Refs: FR-325, FR-328, NFR-048, ADR-042, ADR-048
# Brief: P2-S3 (docs/creative-artifacts/gaia-native-conversion-feature-brief-2026-04-14.md)
#
# Invocation contract (stable for E28-S17 bats-core authors):
#
#   sprint-state.sh transition                 --story <key> --to <state>
#   sprint-state.sh get                        --story <key>
#   sprint-state.sh validate                   --story <key>
#   sprint-state.sh reconcile                  [--sprint-id <id>] [--dry-run]
#   sprint-state.sh lint-dependencies          [--sprint-id <id>] [--format json|text]
#   sprint-state.sh record-escalation-override --item-ids <ids> --user <name> --reason <text>
#   sprint-state.sh --help
#
# Reconcile (ADR-055 §10.29.1, E38-S1):
#   Scans story files under IMPLEMENTATION_ARTIFACTS to detect and correct
#   drift between authoritative story frontmatter (source of truth) and
#   the derivative sprint-status.yaml cache. Write boundary (NFR-SPQG-2):
#   reconcile NEVER modifies story-file frontmatter — yaml only, routed
#   through the same allowlisted writer the transition path uses.
#   Exit codes: 0 = no drift or drift corrected; 2 = drift detected in
#   --dry-run; 1 = error (missing file / parse error / write failure).
#
# Canonical state set (from CLAUDE.md#Sprint State Machine):
#   backlog | validating | ready-for-dev | in-progress | blocked | review | done
#
# Allowed adjacency (edges encoded verbatim from CLAUDE.md):
#   backlog        -> validating
#   validating     -> ready-for-dev
#   ready-for-dev  -> in-progress
#   in-progress    -> blocked
#   in-progress    -> review
#   blocked        -> in-progress
#   review         -> in-progress
#   review         -> done
#
# Sprint-Status Write Safety (CRITICAL, per CLAUDE.md):
#   The story file is the source of truth — sprint-status.yaml is a derived
#   cached view. This script ALWAYS re-reads sprint-status.yaml under flock
#   immediately before writing. It updates both locations inside the same
#   critical section so no concurrent reader sees a drifted pair.
#
# Review Gate check on -> done (AC6):
#   Transitions to 'done' shell out to review-gate.sh status and require all
#   six canonical rows to report PASSED. Any other verdict (UNVERIFIED or
#   FAILED) blocks the transition with the offending row names enumerated.
#
# Config:
#   PROJECT_PATH                — defaults to "." when unset. Story files and
#                                 sprint-status.yaml are located relative to it.
#   IMPLEMENTATION_ARTIFACTS    — defaults to "${PROJECT_PATH}/docs/implementation-artifacts".
#   SPRINT_STATE_SCRIPT_DIR     — internal. Directory of this script, used to
#                                 locate sibling scripts (lifecycle-event.sh,
#                                 review-gate.sh). Override only in tests.
#
# Atomicity & concurrency:
#   All sprint-status.yaml writes are serialized by `flock -x -w 5` on a
#   sibling `sprint-status.yaml.lock` file. Every write (story file AND
#   sprint-status.yaml) is tempfile + atomic `mv`. The same critical section
#   covers:
#     1. read current status from story file
#     2. validate adjacency
#     3. re-read sprint-status.yaml
#     4. rewrite story file via tempfile + mv
#     5. rewrite sprint-status.yaml via tempfile + mv
#     6. emit lifecycle event
#   If step 6 fails the file writes are not rolled back, but the script exits
#   1 and surfaces the failure (AC-EC4: "event failure surfaced with exit 1").
#   Subsequent `validate` will detect drift if any downstream consumer cares.
#
# POSIX discipline: the only non-POSIX constructs are [[ ]] and bash indexed
# arrays. macOS /bin/bash 3.2 compatible. Uses `awk`, `sed`, `grep`, `mktemp`,
# and optionally `flock` (graceful mv-based fallback when absent, same
# pattern as checkpoint.sh / lifecycle-event.sh / review-gate.sh).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="sprint-state.sh"

# E64-S5 — script-level EXIT/INT/TERM trap for atomic-write tmp cleanup.
# Every tempfile-creating call site appends the resulting path to
# _GAIA_TMP_PATHS and captures its index. After a successful rename the slot
# is cleared so the cleanup is idempotent. Covers SIGINT, SIGTERM, OOM, and
# signal-during-awk paths the function-scoped RETURN traps and inline rm
# paths miss. bash 3.2 compatible.
_GAIA_TMP_PATHS=()
_cleanup_tmps() {
  # Guard against bash 3.2 / `set -u` "unbound variable" on empty arrays.
  if [ "${#_GAIA_TMP_PATHS[@]}" -eq 0 ]; then return 0; fi
  local p
  for p in "${_GAIA_TMP_PATHS[@]}"; do
    if [ -n "$p" ] && [ -e "$p" ]; then
      rm -f "$p" 2>/dev/null || true
    fi
  done
}
trap '_cleanup_tmps' EXIT INT TERM

# ---------- Canonical state machine ----------

CANONICAL_STATES=(
  "backlog"
  "validating"
  "ready-for-dev"
  "in-progress"
  "blocked"
  "review"
  "done"
)

# Allowed adjacency encoded as "from|to" strings (CLAUDE.md verbatim).
ALLOWED_EDGES=(
  "backlog|validating"
  "validating|ready-for-dev"
  "ready-for-dev|in-progress"
  "in-progress|blocked"
  "in-progress|review"
  "blocked|in-progress"
  "review|in-progress"
  "review|done"
)

# ---------- Helpers ----------

die() {
  printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  sprint-state.sh transition                 --story <key> --to <state>
  sprint-state.sh inject                     --story <key> [--sprint-id <id>]
  sprint-state.sh get                        --story <key>
  sprint-state.sh validate                   --story <key>
  sprint-state.sh reconcile                  [--sprint-id <id>] [--dry-run]
  sprint-state.sh lint-dependencies          [--sprint-id <id>] [--format json|text]
  sprint-state.sh record-escalation-override --item-ids <ids> --user <name> --reason <text>
  sprint-state.sh --help

Subcommands:
  transition        Atomically transition a story to <state>. Validates
                    adjacency, re-reads sprint-status.yaml under flock,
                    rewrites story file frontmatter + body Status line +
                    sprint-status.yaml, and emits one lifecycle event.
                    Transitions to 'done' require all six Review Gate rows
                    to report PASSED (via review-gate.sh status).
  inject            Append a backlog story to the active sprint's
                    sprint-status.yaml. Requires the story file's
                    frontmatter sprint_id to match the yaml sprint_id
                    (drift guard). Idempotent — re-running on an already-
                    injected key is a no-op. Bumps total_points and
                    recomputes capacity_utilization. Emits one
                    story_injected lifecycle event. Used by
                    /gaia-correct-course story-injection (E38-S10,
                    AF-2026-05-01-4, ADR-055 §10.29).
  get               Print the story's current status (from the story file)
                    to stdout and exit 0.
  validate          Compare story file status to sprint-status.yaml. Exit 0
                    if they agree, exit 1 with a drift description on stderr
                    if not.
  reconcile         Scan the target sprint's story files and reconcile
                    sprint-status.yaml to match authoritative frontmatter
                    per ADR-055 §10.29.1. NEVER modifies story files
                    (NFR-SPQG-2). Exit 0 on no-drift or drift-corrected,
                    2 on dry-run drift, 1 on error.
  lint-dependencies Read-only analysis of the selected sprint's dependency
                    graph. Detects forward-references (dependency inversions)
                    where a story depends on a resource created by a later
                    story in the sprint order. Per ADR-055 §10.29.2.
                    Exit 0 = clean, 2 = inversions detected (advisory),
                    1 = error.

Canonical states (CLAUDE.md):
  backlog | validating | ready-for-dev | in-progress | blocked | review | done

Config:
  PROJECT_PATH                defaults to "."
  IMPLEMENTATION_ARTIFACTS    defaults to "${PROJECT_PATH}/docs/implementation-artifacts"
  SPRINT_STATUS_YAML          overrides the default yaml path (tests).

Exit codes:
  0  success
  1  usage error, invalid state, illegal transition, missing file, lock
     failure, review gate failure, glob mismatch, drift (validate), or
     reconcile/lint-dependencies error (missing story file, parse failure)
  2  reconcile --dry-run detected drift but wrote nothing, OR
     lint-dependencies detected inversions (advisory, non-blocking)
USAGE
}

is_canonical_state() {
  local candidate="$1"
  local s
  for s in "${CANONICAL_STATES[@]}"; do
    [ "$s" = "$candidate" ] && return 0
  done
  return 1
}

# Render the canonical enum as a "value | value | value" string for use in
# error messages. Centralised so every fail-fast path emits the same hint
# (E38-S8, AC2). Operators reading the rejection see exactly which values
# the lifecycle accepts and can fix the call site without reading source.
canonical_states_hint() {
  local s out=""
  for s in "${CANONICAL_STATES[@]}"; do
    if [ -z "$out" ]; then
      out="$s"
    else
      out="${out} | ${s}"
    fi
  done
  printf '%s' "$out"
}

# Fail-fast guard for any value about to be written into a lifecycle
# `status:` field. Any non-canonical value (e.g. the review-gate display
# strings 'PASSED' / 'FAILED' / 'UNVERIFIED' that triggered the sprint-27
# F2 finding) MUST be rejected before any tempfile rewrite touches disk —
# yaml and story file are left byte-identical (E38-S8 AC1, AC2). The error
# names BOTH the offending value and the allowed enum so the caller can
# correct the invocation without reading source.
assert_canonical_state() {
  local candidate="$1" context="${2:-write}"
  if ! is_canonical_state "$candidate"; then
    die "refusing to ${context} non-canonical lifecycle status: '${candidate}' — allowed values: $(canonical_states_hint)"
  fi
}

# Exit 1 unless "from -> to" is in ALLOWED_EDGES.
validate_transition() {
  local from="$1" to="$2"
  local edge
  for edge in "${ALLOWED_EDGES[@]}"; do
    if [ "$edge" = "${from}|${to}" ]; then
      return 0
    fi
  done
  die "illegal transition: '${from}' -> '${to}' is not in the allowed adjacency list"
}

# Resolve configuration — PROJECT_PATH, IMPLEMENTATION_ARTIFACTS, and yaml path.
# Honor pre-exported SPRINT_STATUS_YAML so tests can point the script at a
# temp-dir yaml that does not live under IMPLEMENTATION_ARTIFACTS (E38-S1).
# When SPRINT_STATUS_YAML is unset, resolve to the canonical location under
# IMPLEMENTATION_ARTIFACTS, then fall back to $PROJECT_PATH/sprint-status.yaml
# if the canonical path does not exist but the fallback does — supports the
# E38-S1 bats fixtures which place the yaml at $TEST_TMP root for test speed.
resolve_paths() {
  PROJECT_PATH="${PROJECT_PATH:-.}"
  IMPLEMENTATION_ARTIFACTS="${IMPLEMENTATION_ARTIFACTS:-${PROJECT_PATH}/docs/implementation-artifacts}"
  if [ -z "${SPRINT_STATUS_YAML:-}" ]; then
    local canonical="${IMPLEMENTATION_ARTIFACTS}/sprint-status.yaml"
    local fallback="${PROJECT_PATH}/sprint-status.yaml"
    if [ -e "$canonical" ] || [ ! -e "$fallback" ]; then
      SPRINT_STATUS_YAML="$canonical"
    else
      SPRINT_STATUS_YAML="$fallback"
    fi
  fi
  SPRINT_STATUS_LOCK="${SPRINT_STATUS_YAML}.lock"
}

# Check whether a file's YAML frontmatter contains `template: 'story'`.
# Reads only the frontmatter block (between the first two `---` lines).
# Returns 0 if the file is a canonical story file, 1 otherwise.
# Portable: bash 3.2+ compatible, uses awk only.
_is_story_file() {
  local f="$1"
  awk '
    /^---[[:space:]]*$/ { n++; if (n == 2) exit }
    n == 1 && /^template:[[:space:]]*["\x27]?story["\x27]?[[:space:]]*$/ { found = 1; exit }
    END { exit (found ? 0 : 1) }
  ' "$f"
}

# Locate the story file via glob `{story_key}-*.md` under IMPLEMENTATION_ARTIFACTS,
# then filter candidates by frontmatter `template: 'story'` to exclude review
# sibling files (-review.md, -qa-tests.md, -security-review.md, etc.).
# Returns via the STORY_FILE global. Exits 1 on zero or multiple canonical matches.
STORY_FILE=""
locate_story_file() {
  local key="$1"
  local pattern="${IMPLEMENTATION_ARTIFACTS}/${key}-*.md"
  local epic_pattern="${IMPLEMENTATION_ARTIFACTS}/epic-*/stories/${key}-*.md"

  local matches=()
  shopt -s nullglob
  # shellcheck disable=SC2206
  matches=( $pattern $epic_pattern )
  shopt -u nullglob

  if [ "${#matches[@]}" -eq 0 ]; then
    die "no story file found for key '$key' (glob: $pattern)"
  fi

  # Filter glob matches: keep only files whose frontmatter declares template: 'story'
  local canonical=()
  local m
  for m in "${matches[@]}"; do
    if _is_story_file "$m"; then
      canonical+=( "$m" )
    fi
  done

  if [ "${#canonical[@]}" -eq 0 ]; then
    die "no story file found for key '$key' (checked ${#matches[@]} candidates, none have template: 'story' frontmatter)"
  fi

  # Deduplicate by realpath. Symlinks at the flat layer pointing at the
  # epic-grouped real file (post-E53-S225 transition shims) produce two
  # canonical matches that are the same physical file. Prefer non-symlinks.
  if [ "${#canonical[@]}" -gt 1 ]; then
    local dedup=()
    local seen_realpaths=""
    local rp
    for m in "${canonical[@]}"; do
      [ -L "$m" ] && continue
      if command -v realpath >/dev/null 2>&1; then
        rp=$(realpath "$m")
      else
        rp=$(cd "$(dirname "$m")" && /bin/pwd -P)/$(basename "$m")
      fi
      case "$seen_realpaths" in
        *"|$rp|"*) ;;
        *) dedup+=( "$m" ); seen_realpaths="${seen_realpaths}|$rp|" ;;
      esac
    done
    for m in "${canonical[@]}"; do
      [ -L "$m" ] || continue
      if command -v realpath >/dev/null 2>&1; then
        rp=$(realpath "$m")
      else
        rp=$(cd "$(dirname "$(readlink "$m")")" 2>/dev/null && /bin/pwd -P)/$(basename "$(readlink "$m")")
      fi
      case "$seen_realpaths" in
        *"|$rp|"*) ;;
        *) dedup+=( "$m" ); seen_realpaths="${seen_realpaths}|$rp|" ;;
      esac
    done
    canonical=( "${dedup[@]}" )
  fi

  if [ "${#canonical[@]}" -gt 1 ]; then
    {
      printf '%s: error: ambiguous canonical story files for key %s:\n' \
        "$SCRIPT_NAME" "$key"
      printf '  %s\n' "${canonical[@]}"
    } >&2
    exit 1
  fi

  STORY_FILE="${canonical[0]}"
}

# Extract the current status from a story file's frontmatter. The story
# template uses `status: <value>` (unquoted or quoted). Returns via stdout.
# Exits 1 if the field is missing.
read_story_status() {
  local file="$1"
  # Only scan the frontmatter block (between the first two `---` lines).
  local status
  status=$(awk '
    BEGIN { in_fm = 0; seen = 0 }
    /^---[[:space:]]*$/ {
      if (!in_fm && !seen) { in_fm = 1; seen = 1; next }
      if (in_fm) { exit }
    }
    in_fm && /^status:[[:space:]]*/ {
      sub(/^status:[[:space:]]*/, "", $0)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", $0)
      print $0
      exit
    }
  ' "$file")

  if [ -z "$status" ]; then
    die "story file '$file' is missing 'status:' in frontmatter"
  fi
  printf '%s' "$status"
}

# Rewrite a story file so that (a) the frontmatter `status:` field and
# (b) the body `**Status:**` line both show $new_status. Preserves all
# other bytes. Tempfile + atomic mv.
rewrite_story_status() {
  local file="$1" new_status="$2"
  # Defense-in-depth (E38-S8 AC1): even if a future caller bypasses
  # cmd_transition's fail-fast guard, this writer refuses to stamp a
  # non-canonical value into the story file. Belt-and-braces against the
  # sprint-27 F2 class of bug.
  assert_canonical_state "$new_status" "write story status"
  local tmp
  tmp=$(mktemp "${file}.tmp.XXXXXX")
  # E64-S5: register tmp for script-level EXIT/INT/TERM cleanup.
  local _tmp_idx
  _GAIA_TMP_PATHS+=("$tmp")
  _tmp_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  awk -v new_status="$new_status" '
    BEGIN { in_fm = 0; seen = 0; fm_done = 0; rewrote_fm = 0; rewrote_body = 0 }
    {
      raw = $0
      line = $0
      sub(/\r$/, "", line)
    }
    !fm_done && line ~ /^---[[:space:]]*$/ {
      if (!in_fm && !seen) { in_fm = 1; seen = 1; print raw; next }
      if (in_fm) { in_fm = 0; fm_done = 1; print raw; next }
    }
    in_fm && !rewrote_fm && line ~ /^status:[[:space:]]*/ {
      crlf = ""
      if (raw ~ /\r$/) { crlf = "\r" }
      printf "status: %s%s\n", new_status, crlf
      rewrote_fm = 1
      next
    }
    fm_done && !rewrote_body && line ~ /^>[[:space:]]*\*\*Status:\*\*/ {
      crlf = ""
      if (raw ~ /\r$/) { crlf = "\r" }
      printf "> **Status:** %s%s\n", new_status, crlf
      rewrote_body = 1
      next
    }
    { print raw }
    END {
      if (!rewrote_fm)   { exit 2 }
      if (!rewrote_body) { exit 3 }
    }
  ' "$file" > "$tmp" || {
    local rc=$?
    rm -f "$tmp"
    trap - RETURN
    if [ $rc -eq 2 ]; then
      die "failed to locate frontmatter 'status:' field in '$file'"
    elif [ $rc -eq 3 ]; then
      die "failed to locate body '> **Status:**' line in '$file'"
    else
      die "awk rewrite of '$file' failed (rc=$rc)"
    fi
  }

  if ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    trap - RETURN
    die "failed to mv tempfile over '$file'"
  fi
  # E64-S5: mv succeeded — clear the slot.
  _GAIA_TMP_PATHS[$_tmp_idx]=""
  trap - RETURN
}

# Rewrite the matching story entry in sprint-status.yaml so its `status:`
# field reads $new_status. Preserves all other bytes. Tempfile + atomic mv.
# Exits 1 if the story entry is not found (so drift is loud, never silent).
rewrite_sprint_status_yaml() {
  local story_key="$1" new_status="$2"
  local file="$SPRINT_STATUS_YAML"

  # Defense-in-depth (E38-S8 AC1): refuse to stamp a non-canonical value
  # into sprint-status.yaml even if the caller bypassed the higher-level
  # guard. This is the same chokepoint that reconcile and the transition
  # path both flow through, so guarding here closes every write path.
  assert_canonical_state "$new_status" "write sprint-status.yaml status"

  if [ ! -s "$file" ]; then
    die "sprint-status.yaml is missing or empty: $file"
  fi

  local tmp
  tmp=$(mktemp "${file}.tmp.XXXXXX")
  # E64-S5: register tmp for script-level EXIT/INT/TERM cleanup.
  local _tmp_idx
  _GAIA_TMP_PATHS+=("$tmp")
  _tmp_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  awk -v target="$story_key" -v new_status="$new_status" '
    BEGIN { in_entry = 0; rewrote = 0 }
    {
      raw = $0
      line = $0
      sub(/\r$/, "", line)
    }
    # A new list entry starts with `  - key:` at two-space indent.
    line ~ /^[[:space:]]*-[[:space:]]*key:[[:space:]]*/ {
      # Extract the key value and strip quotes.
      k = line
      sub(/^[[:space:]]*-[[:space:]]*key:[[:space:]]*/, "", k)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", k)
      if (k == target) { in_entry = 1 } else { in_entry = 0 }
      print raw
      next
    }
    # Any subsequent list entry or top-level key closes the current entry.
    in_entry && line ~ /^[^[:space:]]/ {
      in_entry = 0
    }
    in_entry && !rewrote && line ~ /^[[:space:]]+status:[[:space:]]*/ {
      # Preserve the original indentation.
      match(raw, /^[[:space:]]+/)
      indent = substr(raw, RSTART, RLENGTH)
      crlf = ""
      if (raw ~ /\r$/) { crlf = "\r" }
      printf "%sstatus: \"%s\"%s\n", indent, new_status, crlf
      rewrote = 1
      next
    }
    { print raw }
    END {
      if (!rewrote) { exit 2 }
    }
  ' "$file" > "$tmp" || {
    local rc=$?
    rm -f "$tmp"
    trap - RETURN
    if [ $rc -eq 2 ]; then
      die "story '$story_key' not found in $file"
    fi
    die "awk rewrite of '$file' failed (rc=$rc)"
  }

  if ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    trap - RETURN
    die "failed to mv tempfile over '$file'"
  fi
  # E64-S5: mv succeeded — clear the slot.
  _GAIA_TMP_PATHS[$_tmp_idx]=""
  trap - RETURN
}

# Extract the status for $story_key from sprint-status.yaml. Stdout.
read_sprint_status_yaml_status() {
  local story_key="$1"
  local file="$SPRINT_STATUS_YAML"

  if [ ! -s "$file" ]; then
    die "sprint-status.yaml is missing or empty: $file"
  fi

  awk -v target="$story_key" '
    BEGIN { in_entry = 0; found = 0 }
    {
      line = $0
      sub(/\r$/, "", line)
    }
    line ~ /^[[:space:]]*-[[:space:]]*key:[[:space:]]*/ {
      k = line
      sub(/^[[:space:]]*-[[:space:]]*key:[[:space:]]*/, "", k)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", k)
      if (k == target) { in_entry = 1 } else { in_entry = 0 }
      next
    }
    in_entry && line ~ /^[^[:space:]]/ { in_entry = 0 }
    in_entry && line ~ /^[[:space:]]+status:[[:space:]]*/ {
      v = line
      sub(/^[[:space:]]+status:[[:space:]]*/, "", v)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
      print v
      found = 1
      exit
    }
    END {
      if (!found) { exit 2 }
    }
  ' "$file" || die "story '$story_key' not found in sprint-status.yaml"
}

# Check the Review Gate for the story. Returns 0 if all six canonical rows
# report PASSED; otherwise exits 1 with the non-PASSED rows listed.
check_review_gate_all_passed() {
  local story_key="$1"
  local review_gate_sh="${SPRINT_STATE_SCRIPT_DIR}/review-gate.sh"
  if [ ! -x "$review_gate_sh" ]; then
    die "review-gate.sh not found or not executable at $review_gate_sh (required for ' -> done' transitions)"
  fi
  # Call with an isolated PROJECT_PATH if review-gate.sh lays out story files
  # under docs/implementation-artifacts/stories/ — our layout is flat, so we
  # instead call `check` directly and rely on its own locator. review-gate.sh
  # uses `${PROJECT_PATH}/docs/implementation-artifacts/stories/<key>-*.md`;
  # fall back to a thin parser that reads the Review Gate table from the
  # story file we already resolved. This keeps E28-S11 independent of any
  # later refactor to review-gate.sh's layout assumptions.
  local missing
  missing=$(awk '
    BEGIN { in_section = 0; in_table = 0; saw_sep = 0 }
    /^## Review Gate[[:space:]]*$/ { in_section = 1; in_table = 0; saw_sep = 0; next }
    in_section && /^## / { in_section = 0; in_table = 0; next }
    !in_section { next }
    { sub(/\r$/, "", $0) }
    in_section && !in_table {
      if ($0 ~ /^[[:space:]]*\|/) { in_table = 1; saw_sep = 0; next }
      next
    }
    in_table {
      if ($0 !~ /^[[:space:]]*\|/) { in_table = 0; in_section = 0; next }
      if (!saw_sep && $0 ~ /^[[:space:]]*\|[[:space:]]*-+/) { saw_sep = 1; next }
      line = $0
      sub(/^[[:space:]]*\|/, "", line)
      sub(/\|[[:space:]]*$/, "", line)
      n = split(line, cells, /\|/)
      if (n < 2) next
      gate = cells[1]; status = cells[2]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", gate)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", status)
      if (status != "PASSED") {
        printf "%s=%s\n", gate, status
      }
    }
  ' "$STORY_FILE")

  if [ -n "$missing" ]; then
    {
      printf '%s: error: Review Gate not fully PASSED for story %s — transition to done rejected:\n' \
        "$SCRIPT_NAME" "$story_key"
      printf '%s\n' "$missing" | sed 's/^/  /'
    } >&2
    exit 1
  fi
}

# Emit one state_transition lifecycle event. Shells out to lifecycle-event.sh
# as a separate process per Technical Notes. If the script is missing or
# exits non-zero, we surface the failure (AC-EC4).
emit_lifecycle_event() {
  local story_key="$1" from="$2" to="$3"
  local lifecycle_sh="${SPRINT_STATE_SCRIPT_DIR}/lifecycle-event.sh"
  if [ ! -x "$lifecycle_sh" ]; then
    die "lifecycle-event.sh not found or not executable at $lifecycle_sh (required by AC3)"
  fi
  local data
  data=$(printf '{"from":"%s","to":"%s"}' "$from" "$to")
  if ! "$lifecycle_sh" \
        --type state_transition \
        --workflow sprint-state \
        --story "$story_key" \
        --data "$data"; then
    die "lifecycle-event.sh failed for $story_key ($from -> $to) — story file and sprint-status.yaml updates completed but event log write failed; run sprint-state.sh validate --story $story_key to check for drift"
  fi
}

# ---------- Subcommand: get ----------

cmd_get() {
  local story_key="$1"
  locate_story_file "$story_key"
  read_story_status "$STORY_FILE"
  printf '\n'
}

# ---------- Subcommand: validate ----------

cmd_validate() {
  local story_key="$1"
  locate_story_file "$story_key"
  local story_status yaml_status
  story_status=$(read_story_status "$STORY_FILE")
  yaml_status=$(read_sprint_status_yaml_status "$story_key")
  if [ "$story_status" != "$yaml_status" ]; then
    printf '%s: drift detected for %s: story file says %q, sprint-status.yaml says %q\n' \
      "$SCRIPT_NAME" "$story_key" "$story_status" "$yaml_status" >&2
    exit 1
  fi
  return 0
}

# ---------- Subcommand: transition ----------

# The core of the transition logic — runs inside the flock critical section.
do_transition_locked() {
  local story_key="$1" to_state="$2"

  # (a) Re-read sprint-status.yaml immediately before writing (Sprint-Status
  # Write Safety). If the file is missing/empty, fail before touching the
  # story file (AC-EC1).
  if [ ! -s "$SPRINT_STATUS_YAML" ]; then
    die "sprint-status.yaml is missing or empty: $SPRINT_STATUS_YAML"
  fi

  # Locate the story file now that we hold the lock.
  locate_story_file "$story_key"

  # Read current status from the story file (source of truth).
  local from_state
  from_state=$(read_story_status "$STORY_FILE")

  # No-op guard: identical transitions are not legal adjacency edges and
  # would be caught below, but surface a clearer message.
  if [ "$from_state" = "$to_state" ]; then
    die "story $story_key is already in state '$to_state'"
  fi

  # Validate adjacency (AC2, AC-EC2).
  validate_transition "$from_state" "$to_state"

  # Review Gate enforcement for -> done (AC6, AC-EC7).
  if [ "$to_state" = "done" ]; then
    check_review_gate_all_passed "$story_key"
  fi

  # (b, c) Atomic updates: story file first (source of truth), then yaml.
  rewrite_story_status "$STORY_FILE" "$to_state"
  rewrite_sprint_status_yaml "$story_key" "$to_state"

  # (d) Emit exactly one lifecycle event. Any failure exits 1; file writes
  # are NOT rolled back — callers MUST treat a non-zero exit from transition
  # as "run validate and fix drift". AC-EC4 explicitly permits this
  # "surfaced with exit 1" branch of the OR.
  emit_lifecycle_event "$story_key" "$from_state" "$to_state"

  printf '%s: %s transitioned %s -> %s\n' "$SCRIPT_NAME" "$story_key" "$from_state" "$to_state"
}

cmd_transition() {
  local story_key="$1" to_state="$2"

  # Fail-fast (E38-S8 AC2): refuse any --to value that is not in the
  # canonical lifecycle enum. The rejection happens BEFORE the flock and
  # BEFORE any tempfile is created, so sprint-status.yaml and the story
  # file are guaranteed byte-identical on a non-canonical input. The error
  # names both the offending value and the allowed enum so the caller can
  # correct the invocation without reading source. This is the primary
  # fix for the sprint-27 F2 root cause where 'PASSED' was passed as the
  # lifecycle target instead of 'done'.
  assert_canonical_state "$to_state" "transition --to"

  local flock_bin
  flock_bin=$(command -v flock || true)

  if [ -n "$flock_bin" ]; then
    (
      exec 9>"$SPRINT_STATUS_LOCK"
      if ! "$flock_bin" -x -w 5 9; then
        die "flock timeout acquiring $SPRINT_STATUS_LOCK"
      fi
      do_transition_locked "$story_key" "$to_state"
    )
  else
    # mv-based spin-loop fallback — same pattern as sibling foundation
    # scripts (checkpoint.sh, lifecycle-event.sh, review-gate.sh).
    local tries=0
    while ! ( set -C; : > "$SPRINT_STATUS_LOCK" ) 2>/dev/null; do
      tries=$((tries + 1))
      if [ "$tries" -ge 50 ]; then
        die "lock timeout acquiring $SPRINT_STATUS_LOCK"
      fi
      sleep 0.1 2>/dev/null || sleep 1
    done
    # shellcheck disable=SC2064
    trap "rm -f '$SPRINT_STATUS_LOCK'" EXIT INT TERM
    do_transition_locked "$story_key" "$to_state"
    rm -f "$SPRINT_STATUS_LOCK"
    trap - EXIT INT TERM
  fi
}

# ---------- Subcommand: inject (E38-S10, AF-2026-05-01-4, ADR-055 §10.29) ----------
#
# Append a backlog story's metadata to the active sprint's sprint-status.yaml
# entry list. Closes the F-CC-INJECT placeholder cited in
# docs/implementation-artifacts/sprint-status.yaml — until this subcommand
# landed, /gaia-correct-course story-injection had no canonical write path
# and operators had to hand-edit sprint-status.yaml (CLAUDE.md hard-rule
# violation).
#
# Contract (mirrors cmd_transition's invariants):
#   * Acquires the same flock used by cmd_transition (no new lock primitive).
#   * Story file frontmatter is the source of truth — yaml is the cache.
#   * Validates four required frontmatter fields BEFORE the lock.
#   * Idempotent: re-running on an already-injected key is a no-op.
#   * Drift guard: refuses if frontmatter.sprint_id != yaml.sprint_id.
#   * Bumps total_points and recomputes capacity_utilization.
#   * Emits exactly one story_injected lifecycle event on success.
#
# Exit codes (overlay on the script-wide table):
#   0 — success OR no-op (idempotent re-run)
#   1 — usage error, missing required field, sprint-id drift, lock failure,
#       yaml parse failure, lifecycle event write failure

# Read a single scalar frontmatter field from a story file. Stdout = value
# (quotes stripped). Exit 1 if the field is missing.
read_story_frontmatter_field() {
  local file="$1" field="$2"
  awk -v target="$field" '
    BEGIN { in_fm = 0; seen = 0; found = 0 }
    /^---[[:space:]]*$/ {
      if (!in_fm && !seen) { in_fm = 1; seen = 1; next }
      if (in_fm) { exit }
    }
    in_fm {
      line = $0
      sub(/\r$/, "", line)
      pat = "^" target ":[[:space:]]*"
      if (line ~ pat) {
        v = line
        sub(pat, "", v)
        gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
        print v
        found = 1
        exit
      }
    }
    END { if (!found) exit 1 }
  ' "$file"
}

# Read the top-level sprint_id field from sprint-status.yaml. Stdout = value.
# Exit 1 if absent.
read_yaml_sprint_id() {
  local file="$1"
  awk '
    BEGIN { found = 0 }
    /^sprint_id:[[:space:]]*/ {
      v = $0
      sub(/^sprint_id:[[:space:]]*/, "", v)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
      print v
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  ' "$file"
}

# Read top-level scalar field <name> from sprint-status.yaml. Stdout = value.
# Exit 1 if absent.
read_yaml_scalar_field() {
  local file="$1" field="$2"
  awk -v target="$field" '
    BEGIN { found = 0 }
    {
      line = $0
      sub(/\r$/, "", line)
      pat = "^" target ":[[:space:]]*"
      if (line ~ pat) {
        v = line
        sub(pat, "", v)
        gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
        print v
        found = 1
        exit
      }
    }
    END { if (!found) exit 1 }
  ' "$file"
}

# Check whether a story key already appears in sprint-status.yaml's stories[]
# block. Returns 0 if present, 1 otherwise. No stdout.
yaml_has_story_key() {
  local file="$1" target="$2"
  awk -v target="$target" '
    BEGIN { found = 0 }
    /^[[:space:]]*-[[:space:]]*key:[[:space:]]*/ {
      k = $0
      sub(/^[[:space:]]*-[[:space:]]*key:[[:space:]]*/, "", k)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", k)
      if (k == target) { found = 1; exit }
    }
    END { if (!found) exit 1 }
  ' "$file"
}

# Append a story entry to sprint-status.yaml's stories: block. Updates
# total_points by $points_delta and recomputes capacity_utilization using
# velocity_capacity (when present). Tempfile + atomic mv. Exit 1 on failure.
append_story_to_yaml() {
  local file="$1" key="$2" title="$3" status="$4" points="$5" risk="$6"
  local today
  today=$(date -u +%Y-%m-%d)

  if [ ! -s "$file" ]; then
    die "sprint-status.yaml is missing or empty: $file"
  fi

  # Read current scalars to compute new totals.
  local cur_total cur_velocity new_total new_capacity_pct
  cur_total=$(read_yaml_scalar_field "$file" total_points 2>/dev/null || printf '0')
  cur_velocity=$(read_yaml_scalar_field "$file" velocity_capacity 2>/dev/null || printf '')

  # Validate numeric inputs — guard non-numeric strings.
  case "$cur_total" in
    ''|*[!0-9]*) cur_total=0 ;;
  esac
  case "$points" in
    ''|*[!0-9]*) die "inject: story 'points' must be a non-negative integer, got: '$points'" ;;
  esac
  new_total=$((cur_total + points))

  if [ -n "$cur_velocity" ] && printf '%s' "$cur_velocity" | grep -Eq '^[0-9]+$' && [ "$cur_velocity" -gt 0 ]; then
    # Round half-up: (a*100 + v/2) / v.
    new_capacity_pct=$(( (new_total * 100 + cur_velocity / 2) / cur_velocity ))
  else
    new_capacity_pct=""
  fi

  local tmp
  tmp=$(mktemp "${file}.tmp.XXXXXX")
  # E64-S5: register tmp for script-level EXIT/INT/TERM cleanup.
  local _tmp_idx
  _GAIA_TMP_PATHS+=("$tmp")
  _tmp_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  awk -v key="$key" -v title="$title" -v status="$status" -v points="$points" \
      -v risk="$risk" -v today="$today" -v new_total="$new_total" \
      -v new_capacity_pct="$new_capacity_pct" '
    function emit_entry() {
      printf "  - key: \"%s\"\n", key
      printf "    title: \"%s\"\n", title
      printf "    status: \"%s\"\n", status
      printf "    points: %s\n", points
      printf "    risk_level: \"%s\"\n", risk
      printf "    assignee: null\n"
      printf "    blocked_by: null\n"
      printf "    updated: \"%s\"\n", today
    }
    BEGIN { in_stories = 0; appended = 0; saw_stories_key = 0 }
    {
      raw = $0
      line = $0
      sub(/\r$/, "", line)
    }
    # Top-level total_points: rewrite.
    !in_stories && line ~ /^total_points:[[:space:]]*/ {
      printf "total_points: %s\n", new_total
      next
    }
    # Top-level capacity_utilization: rewrite (only when we computed one).
    !in_stories && line ~ /^capacity_utilization:[[:space:]]*/ {
      if (new_capacity_pct != "") {
        printf "capacity_utilization: \"%s%%\"\n", new_capacity_pct
        next
      }
      print raw
      next
    }
    # Detect empty stories: [] marker — convert to a populated list.
    line ~ /^stories:[[:space:]]*\[\][[:space:]]*$/ {
      print "stories:"
      emit_entry()
      appended = 1
      saw_stories_key = 1
      next
    }
    # Detect entering the stories: block.
    line ~ /^stories:[[:space:]]*$/ {
      in_stories = 1
      saw_stories_key = 1
      print raw
      next
    }
    # Inside stories — append our entry just before the first top-level
    # non-indented key that closes the block.
    in_stories && line ~ /^[^[:space:]-]/ {
      if (!appended) { emit_entry(); appended = 1 }
      in_stories = 0
      print raw
      next
    }
    { print raw }
    END {
      # stories: block ran to EOF — append at the bottom.
      if (saw_stories_key && !appended) { emit_entry(); appended = 1 }
      # No stories: block at all — emit one with our entry.
      if (!saw_stories_key) {
        printf "stories:\n"
        emit_entry()
        appended = 1
      }
      if (!appended) exit 2
    }
  ' "$file" > "$tmp" || {
    local rc=$?
    rm -f "$tmp"
    trap - RETURN
    die "awk rewrite of '$file' failed (rc=$rc)"
  }

  if ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    trap - RETURN
    die "failed to mv tempfile over '$file'"
  fi
  # E64-S5: mv succeeded — clear the slot.
  _GAIA_TMP_PATHS[$_tmp_idx]=""
  trap - RETURN
}

# Emit a story_injected lifecycle event. Failure surfaces as exit 1.
emit_inject_event() {
  local story_key="$1" total_points="$2"
  local lifecycle_sh="${SPRINT_STATE_SCRIPT_DIR}/lifecycle-event.sh"
  if [ ! -x "$lifecycle_sh" ]; then
    die "lifecycle-event.sh not found or not executable at $lifecycle_sh (required for inject lifecycle event)"
  fi
  local data
  data=$(printf '{"key":"%s","source":"sprint-state.sh inject","total_points":%s}' \
    "$story_key" "$total_points")
  if ! "$lifecycle_sh" \
        --type story_injected \
        --workflow sprint-state \
        --story "$story_key" \
        --data "$data"; then
    die "lifecycle-event.sh failed for $story_key inject — sprint-status.yaml updated but event log write failed; run sprint-state.sh validate --story $story_key to check for drift"
  fi
}

# Inject locked critical section. Mirrors do_transition_locked structure.
do_inject_locked() {
  local story_key="$1"

  if [ ! -s "$SPRINT_STATUS_YAML" ]; then
    die "sprint-status.yaml is missing or empty: $SPRINT_STATUS_YAML"
  fi

  # Idempotency check (under lock so concurrent injects of the same key
  # serialize correctly — second one sees the first one's append).
  if yaml_has_story_key "$SPRINT_STATUS_YAML" "$story_key"; then
    printf '%s: %s already injected — no-op\n' "$SCRIPT_NAME" "$story_key"
    return 0
  fi

  # Re-locate story file under lock.
  locate_story_file "$story_key"

  # Validate four required frontmatter fields. Collect every missing field
  # for a single error message (AC4).
  local missing=""
  local fm_sprint_id fm_status fm_points fm_risk fm_title
  fm_sprint_id=$(read_story_frontmatter_field "$STORY_FILE" sprint_id 2>/dev/null || true)
  fm_status=$(read_story_frontmatter_field "$STORY_FILE" status 2>/dev/null || true)
  fm_points=$(read_story_frontmatter_field "$STORY_FILE" points 2>/dev/null || true)
  fm_risk=$(read_story_frontmatter_field "$STORY_FILE" risk 2>/dev/null || true)
  fm_title=$(read_story_frontmatter_field "$STORY_FILE" title 2>/dev/null || true)

  [ -n "$fm_sprint_id" ] || missing="${missing} sprint_id"
  [ -n "$fm_status" ]    || missing="${missing} status"
  [ -n "$fm_points" ]    || missing="${missing} points"
  [ -n "$fm_risk" ]      || missing="${missing} risk"

  if [ -n "$missing" ]; then
    die "inject: story file '$STORY_FILE' is missing required frontmatter field(s):${missing}"
  fi

  # Defense-in-depth: status from frontmatter must be canonical.
  assert_canonical_state "$fm_status" "inject story status"

  # Drift guard (AC3): frontmatter sprint_id MUST match yaml sprint_id.
  local yaml_sprint_id
  yaml_sprint_id=$(read_yaml_sprint_id "$SPRINT_STATUS_YAML") \
    || die "inject: sprint-status.yaml at $SPRINT_STATUS_YAML missing top-level sprint_id"

  if [ "$fm_sprint_id" != "$yaml_sprint_id" ]; then
    die "inject: sprint-id mismatch — story file frontmatter sprint_id='$fm_sprint_id' but sprint-status.yaml sprint_id='$yaml_sprint_id'; refusing to write"
  fi

  # Title is optional for the validation step but required for a useful yaml
  # entry — fall back to the story key when frontmatter omits it.
  if [ -z "$fm_title" ]; then
    fm_title="$story_key"
  fi

  # Append to yaml (also rewrites total_points and capacity_utilization).
  append_story_to_yaml "$SPRINT_STATUS_YAML" "$story_key" "$fm_title" "$fm_status" "$fm_points" "$fm_risk"

  # Re-read total_points for the lifecycle event payload.
  local new_total
  new_total=$(read_yaml_scalar_field "$SPRINT_STATUS_YAML" total_points 2>/dev/null || printf '0')

  emit_inject_event "$story_key" "$new_total"

  printf '%s: %s injected into sprint %s — total_points=%s\n' \
    "$SCRIPT_NAME" "$story_key" "$yaml_sprint_id" "$new_total"
}

cmd_inject() {
  local story_key="$1" sprint_id_override="${2:-}"
  # sprint_id_override is accepted for forward-compat (multi-sprint yaml,
  # mirror of cmd_reconcile's --sprint-id posture). Today the drift guard
  # uses the yaml's own sprint_id; an explicit override is silently ignored
  # unless it disagrees with the yaml — in which case we surface that as a
  # clear error rather than write to a non-active sprint.
  if [ -n "$sprint_id_override" ]; then
    local yaml_sid
    yaml_sid=$(read_yaml_sprint_id "$SPRINT_STATUS_YAML" 2>/dev/null || true)
    if [ -n "$yaml_sid" ] && [ "$yaml_sid" != "$sprint_id_override" ]; then
      die "inject: --sprint-id '$sprint_id_override' does not match active sprint-status.yaml sprint_id '$yaml_sid'"
    fi
  fi

  local flock_bin
  flock_bin=$(command -v flock || true)

  if [ -n "$flock_bin" ]; then
    (
      exec 9>"$SPRINT_STATUS_LOCK"
      if ! "$flock_bin" -x -w 5 9; then
        die "flock timeout acquiring $SPRINT_STATUS_LOCK"
      fi
      do_inject_locked "$story_key"
    )
  else
    local tries=0
    while ! ( set -C; : > "$SPRINT_STATUS_LOCK" ) 2>/dev/null; do
      tries=$((tries + 1))
      if [ "$tries" -ge 50 ]; then
        die "lock timeout acquiring $SPRINT_STATUS_LOCK"
      fi
      sleep 0.1 2>/dev/null || sleep 1
    done
    # shellcheck disable=SC2064
    trap "rm -f '$SPRINT_STATUS_LOCK'" EXIT INT TERM
    do_inject_locked "$story_key"
    rm -f "$SPRINT_STATUS_LOCK"
    trap - EXIT INT TERM
  fi
}

# ---------- Subcommand: reconcile (E38-S1, ADR-055 §10.29.1) ----------

# Locate a story file for reconcile (E38-S7, FR-SPQG-4, ADR-055).
#
# Filter the {key}-*.md glob to canonical story files (those whose YAML
# frontmatter declares `template: 'story'`). This eliminates the prior
# behaviour where co-located review / qa-tests / security / performance
# reports could be picked up as the "story" file and trigger spurious
# parse errors during reconcile.
#
# For each glob candidate that is rejected (missing or non-'story' template),
# emit a structured warning to stderr that names the candidate file:
#
#   RECONCILE: {key} candidate {file} skipped — no `template: 'story'` frontmatter
#
# This satisfies E38-S7 AC2 / Val WARNING #1: skips are observable, not silent.
#
# Case-insensitive glob via nocaseglob so {slug}-story.md fixtures match
# upper-cased keys on Linux. Returns the first canonical match via stdout.
# Returns non-zero (return 1) if no canonical story file is found — caller
# handles the missing-file error.
reconcile_locate_story_file() {
  local key="$1"
  local matches=()
  shopt -s nullglob nocaseglob
  # shellcheck disable=SC2206
  matches=( "${IMPLEMENTATION_ARTIFACTS}/${key}-"*.md "${IMPLEMENTATION_ARTIFACTS}"/epic-*/stories/"${key}-"*.md )
  shopt -u nullglob nocaseglob

  if [ "${#matches[@]}" -eq 0 ]; then
    return 1
  fi

  local m
  for m in "${matches[@]}"; do
    if _is_story_file "$m"; then
      printf '%s' "$m"
      return 0
    fi
    # Per-candidate structured warning naming the skipped file (Val WARNING #1).
    printf "RECONCILE: %s candidate %s skipped — no \`template: 'story'\` frontmatter\n" \
      "$key" "$m" >&2
  done

  return 1
}

# Read story-file frontmatter status; prints to stdout. Reuses the stricter
# read_story_status() when the file has a canonical frontmatter block; falls
# back to exit 2 (via awk END) when the field is missing or the frontmatter
# is unparseable. Return codes: 0 = ok, 2 = parse error / missing status.
reconcile_read_story_status() {
  local file="$1"
  awk '
    BEGIN { in_fm = 0; seen = 0; found = 0 }
    /^---[[:space:]]*$/ {
      if (!in_fm && !seen) { in_fm = 1; seen = 1; next }
      if (in_fm) { exit }
    }
    in_fm && /^[[:space:]]*status:[[:space:]]*/ {
      v = $0
      sub(/^[[:space:]]*status:[[:space:]]*/, "", v)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
      # Reject malformed values containing colons (e.g. "status: : : malformed").
      if (v ~ /:/) { exit 2 }
      print v
      found = 1
      exit
    }
    END { if (!found) exit 2 }
  ' "$file"
}

# Read all (key, status) pairs from sprint-status.yaml for the active sprint.
# Emits `<key>\t<status>` lines to stdout. Uses pure awk — no yq dependency.
# If the yaml is absent or unreadable, returns 1 so callers can HALT.
reconcile_list_yaml_stories() {
  local file="$1"
  if [ ! -r "$file" ]; then
    return 1
  fi
  awk '
    BEGIN { in_stories = 0; key = ""; status = "" }
    {
      line = $0
      sub(/\r$/, "", line)
    }
    line ~ /^stories:[[:space:]]*$/ { in_stories = 1; next }
    # Stories section ends at an empty list marker or a new top-level key.
    line ~ /^stories:[[:space:]]*\[\][[:space:]]*$/ { in_stories = 0; next }
    in_stories && line ~ /^[^[:space:]-]/ { in_stories = 0; next }
    !in_stories { next }
    # A new entry starts with "  - key: ...".
    line ~ /^[[:space:]]+-[[:space:]]+key:[[:space:]]*/ {
      # Flush any previous entry.
      if (key != "") { printf "%s\t%s\n", key, status; }
      key = line
      sub(/^[[:space:]]+-[[:space:]]+key:[[:space:]]*/, "", key)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", key)
      status = ""
      next
    }
    # Subsequent lines of the same entry.
    line ~ /^[[:space:]]+status:[[:space:]]*/ {
      v = line
      sub(/^[[:space:]]+status:[[:space:]]*/, "", v)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
      status = v
      next
    }
    END {
      if (key != "") { printf "%s\t%s\n", key, status; }
    }
  ' "$file"
}

# Allowlisted yaml writer — the single chokepoint for every reconcile write.
# Enforces NFR-SPQG-2: story files are OFF-LIMITS; this helper only accepts
# SPRINT_STATUS_YAML as the target. Runs the inner rewrite in a subshell so
# that die() inside rewrite_sprint_status_yaml (e.g., on read-only yaml) is
# caught as a non-zero return code instead of killing the whole reconcile.
write_sprint_status_yaml() {
  local target="$1" story_key="$2" new_status="$3"
  # Allowlist check — NFR-SPQG-2 write boundary.
  case "$target" in
    "$SPRINT_STATUS_YAML") ;;
    *)
      printf '%s: error: write_sprint_status_yaml refused non-allowlisted path: %s\n' \
        "$SCRIPT_NAME" "$target" >&2
      return 1
      ;;
  esac
  # Pre-check writability to catch read-only / full-disk before awk rewrite.
  if [ ! -w "$target" ]; then
    printf '%s: error: sprint-status.yaml is not writable: %s\n' \
      "$SCRIPT_NAME" "$target" >&2
    return 1
  fi
  ( rewrite_sprint_status_yaml "$story_key" "$new_status" ) || return 1
}

# Core reconcile algorithm — runs inside the lock critical section.
# Sets RECONCILE_CHECKED, RECONCILE_DIVERGENCES, RECONCILE_ERRORS globals.
RECONCILE_CHECKED=0
RECONCILE_DIVERGENCES=0
RECONCILE_ERRORS=0
do_reconcile_locked() {
  local dry_run="$1"
  local yaml="$SPRINT_STATUS_YAML"

  if [ ! -r "$yaml" ]; then
    printf '%s: error: sprint-status.yaml not readable: %s\n' "$SCRIPT_NAME" "$yaml" >&2
    RECONCILE_ERRORS=$((RECONCILE_ERRORS + 1))
    return
  fi

  local pairs
  pairs="$(reconcile_list_yaml_stories "$yaml")" || {
    printf '%s: error: could not parse %s\n' "$SCRIPT_NAME" "$yaml" >&2
    RECONCILE_ERRORS=$((RECONCILE_ERRORS + 1))
    return
  }

  # No stories → fast path (AC-EC1).
  if [ -z "$pairs" ]; then
    return
  fi

  local key yaml_status story_file story_status tag
  while IFS=$'\t' read -r key yaml_status; do
    [ -n "$key" ] || continue
    RECONCILE_CHECKED=$((RECONCILE_CHECKED + 1))

    story_file="$(reconcile_locate_story_file "$key")" || {
      printf 'RECONCILE: %s missing story file — skipped\n' "$key"
      printf '%s: error: story file not found for %s under %s\n' \
        "$SCRIPT_NAME" "$key" "$IMPLEMENTATION_ARTIFACTS" >&2
      RECONCILE_ERRORS=$((RECONCILE_ERRORS + 1))
      continue
    }

    story_status="$(reconcile_read_story_status "$story_file")" || {
      printf 'RECONCILE: %s parse error — skipped (%s)\n' "$key" "$story_file"
      printf '%s: error: malformed frontmatter in %s (key=%s)\n' \
        "$SCRIPT_NAME" "$story_file" "$key" >&2
      RECONCILE_ERRORS=$((RECONCILE_ERRORS + 1))
      continue
    }

    if [ "$story_status" = "$yaml_status" ]; then
      continue
    fi

    RECONCILE_DIVERGENCES=$((RECONCILE_DIVERGENCES + 1))
    if [ "$dry_run" = "1" ]; then
      tag="DRY-RUN"
      printf 'RECONCILE: %s %s -> %s [%s]\n' "$key" "$yaml_status" "$story_status" "$tag"
    else
      tag="UPDATED"
      if ! write_sprint_status_yaml "$SPRINT_STATUS_YAML" "$key" "$story_status" 2>/tmp/.reconcile-werr.$$; then
        local werr=""
        werr="$(cat /tmp/.reconcile-werr.$$ 2>/dev/null || true)"
        rm -f /tmp/.reconcile-werr.$$ 2>/dev/null || true
        printf 'RECONCILE: %s %s -> %s [WRITE-FAILED]\n' "$key" "$yaml_status" "$story_status"
        printf '%s: error: write failed for %s: %s\n' "$SCRIPT_NAME" "$SPRINT_STATUS_YAML" "$werr" >&2
        RECONCILE_ERRORS=$((RECONCILE_ERRORS + 1))
        continue
      fi
      rm -f /tmp/.reconcile-werr.$$ 2>/dev/null || true
      printf 'RECONCILE: %s %s -> %s [%s]\n' "$key" "$yaml_status" "$story_status" "$tag"
    fi
  done <<EOF
$pairs
EOF
}

cmd_reconcile() {
  local dry_run="$1"

  local flock_bin
  flock_bin=$(command -v flock || true)

  mkdir -p "$(dirname "$SPRINT_STATUS_LOCK")" 2>/dev/null || true

  # Counters persisted across the flock subshell via a side-channel file.
  # The subshell writes counters on successful run; the outer shell reads
  # them back tolerantly (a missing or partial file yields zero counters
  # rather than a `set -e` abort). The `|| true` on `read` is load-bearing:
  # printf without a trailing newline makes `read` return non-zero at EOF,
  # which under `set -e` would kill the whole reconcile on Linux/bash 5.
  if [ -n "$flock_bin" ]; then
    set +e
    (
      exec 9>"$SPRINT_STATUS_LOCK" || exit 1
      "$flock_bin" -x -w 10 9 || exit 1
      do_reconcile_locked "$dry_run"
      printf '%s %s %s\n' "$RECONCILE_CHECKED" "$RECONCILE_DIVERGENCES" "$RECONCILE_ERRORS" \
        > "${SPRINT_STATUS_LOCK}.result"
    )
    local sub_rc=$?
    set -e
    if [ "$sub_rc" -ne 0 ] && [ ! -f "${SPRINT_STATUS_LOCK}.result" ]; then
      die "reconcile failed inside flock critical section (rc=$sub_rc)"
    fi
    if [ -f "${SPRINT_STATUS_LOCK}.result" ]; then
      # shellcheck disable=SC2034
      read -r RECONCILE_CHECKED RECONCILE_DIVERGENCES RECONCILE_ERRORS \
        < "${SPRINT_STATUS_LOCK}.result" || true
      rm -f "${SPRINT_STATUS_LOCK}.result"
    fi
  else
    local tries=0
    while ! ( set -C; : > "$SPRINT_STATUS_LOCK" ) 2>/dev/null; do
      tries=$((tries + 1))
      if [ "$tries" -ge 50 ]; then
        die "lock timeout acquiring $SPRINT_STATUS_LOCK"
      fi
      sleep 0.1 2>/dev/null || sleep 1
    done
    # shellcheck disable=SC2064
    trap "rm -f '$SPRINT_STATUS_LOCK'" EXIT INT TERM
    do_reconcile_locked "$dry_run"
    rm -f "$SPRINT_STATUS_LOCK"
    trap - EXIT INT TERM
  fi

  # Summary line.
  local verb="CORRECTED"
  if [ "$dry_run" = "1" ]; then
    verb="DETECTED"
  fi
  if [ "$RECONCILE_DIVERGENCES" -eq 0 ] && [ "$RECONCILE_ERRORS" -eq 0 ]; then
    printf 'RECONCILE SUMMARY: %s stories checked, 0 divergences — no drift\n' "$RECONCILE_CHECKED"
  else
    printf 'RECONCILE SUMMARY: %s stories checked, %s divergences %s\n' \
      "$RECONCILE_CHECKED" "$RECONCILE_DIVERGENCES" "$verb"
  fi

  # Exit-code contract (ADR-055 §10.29.1):
  #   1 = any error (missing file, parse failure, write failure)
  #   2 = dry-run drift detected but nothing written
  #   0 = no drift, or drift corrected successfully
  if [ "$RECONCILE_ERRORS" -gt 0 ]; then
    exit 1
  fi
  if [ "$dry_run" = "1" ] && [ "$RECONCILE_DIVERGENCES" -gt 0 ]; then
    exit 2
  fi
  exit 0
}

# ---------- Subcommand: lint-dependencies (E38-S3, ADR-055 §10.29.2) ----------
#
# Read-only analysis of the selected sprint's story dependency graph.
# Detects forward-references (dependency inversions) where a story depends
# on a resource created by a later story in the sprint order.
#
# The AC text regex uses an 80-char co-occurrence window for trigger verb +
# target resource name matching. This bounds false positives from long-range
# coincidental matches while still catching same-sentence references. The
# window size is a design choice documented per Val INFO #2.
#
# Read-only guarantee: lint-dependencies MUST NOT write to any file.
# It reads story files and sprint-status.yaml only. Safe for context:fork
# subagent invocation and parallel CI pipelines (AC-EC7, AC-EC13).
#
# Exit codes: 0 = clean, 2 = inversions detected (advisory), 1 = error.

# Extract the depends_on list from a story file's YAML frontmatter.
# Outputs one dependency key per line. Returns empty for missing or empty
# depends_on. Does not error on missing field (AC-EC2).
lint_read_depends_on() {
  local file="$1"
  awk '
    BEGIN { in_fm = 0; seen = 0 }
    /^---[[:space:]]*$/ {
      if (!in_fm && !seen) { in_fm = 1; seen = 1; next }
      if (in_fm) { exit }
    }
    in_fm && /^depends_on:/ {
      line = $0
      sub(/^depends_on:[[:space:]]*/, "", line)
      # Remove brackets
      gsub(/[\[\]]/, "", line)
      # Split on comma
      n = split(line, items, /,/)
      for (i = 1; i <= n; i++) {
        v = items[i]
        # Strip quotes and whitespace
        gsub(/^[[:space:]"'\'']+|[[:space:]"'\'']+$/, "", v)
        if (v != "") print v
      }
      exit
    }
  ' "$file"
}

# Scan AC text in a story file for heuristic dependency references.
# Looks for trigger verbs (uses|consumes|reads from) co-occurring with
# a sprint story key within an 80-char window. Outputs pipe-delimited
# records: target_key|match_text
#
# Parameters:
#   $1 — story file path
#   $2 — space-separated list of sprint story keys to check against
#
# Returns empty if no heuristic matches found. Does not match bare key
# mentions without a trigger verb (AC-EC6). Marks "reads from stdout"
# style false positives as non-matches by requiring a story key or
# resource name in the same window (AC-EC5).
lint_scan_ac_text() {
  local file="$1"
  local sprint_keys="$2"

  # Build a pipe-delimited alternation of sprint story keys for awk.
  local key_pattern=""
  local k
  for k in $sprint_keys; do
    key_pattern="${key_pattern:+${key_pattern}|}${k}"
  done
  [ -n "$key_pattern" ] || return 0

  # Scan AC section for trigger verbs co-occurring with a sprint story key
  # inside an 80-char window. The window size bounds false positives from
  # long-range coincidental matches (INFO #2 design choice).
  awk -v keys="$key_pattern" '
    BEGIN { in_ac = 0 }
    /^## Acceptance Criteria/ { in_ac = 1; next }
    /^## / && in_ac { exit }
    !in_ac { next }
    {
      line = $0
      # Use match() to find trigger verbs; iterate via substring slicing.
      pos = 1
      while (pos <= length(line)) {
        rest = substr(line, pos)
        if (match(rest, /(uses|consumes|reads from)/)) {
          start = pos + RSTART - 1
          window = substr(line, start, 80)
          nk = split(keys, karr, /\|/)
          for (j = 1; j <= nk; j++) {
            if (index(window, karr[j]) > 0) {
              snippet = substr(line, start, 60)
              gsub(/["\\\n\r\t]/, " ", snippet)
              printf "%s|%s\n", karr[j], snippet
            }
          }
          pos = start + RLENGTH
        } else {
          break
        }
      }
    }
  ' "$file"
}

# Build an order map from sprint-status.yaml: outputs key\tindex lines
# where index is the 0-based position in the sprint story order.
lint_build_order_map() {
  reconcile_list_yaml_stories "$SPRINT_STATUS_YAML" | awk -F'\t' '
    { printf "%s\t%d\n", $1, NR-1 }
  '
}

# Look up a story key's 0-based sprint order index from the order map.
# Outputs the index if found, empty if the key is not in the sprint.
# Parameters:
#   $1 — order_map (key\tindex lines)
#   $2 — story key to look up
lint_lookup_order() {
  printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1 == k { print $2; exit }'
}

# Emit a single inversion record. Centralises the forward-ref vs external
# classification so both the explicit and heuristic paths share the logic.
# Parameters:
#   $1 — story_key (dependent)
#   $2 — dep_key (dependency)
#   $3 — source (depends_on | ac_text_scan)
#   $4 — story_idx (dependent's sprint position)
#   $5 — order_map
#   $6 — match_text (optional, for heuristic hits)
_lint_emit_if_inversion() {
  local story_key="$1" dep_key="$2" source="$3"
  local story_idx="$4" order_map="$5" match_text="${6:-}"
  local dep_idx confidence

  dep_idx="$(lint_lookup_order "$order_map" "$dep_key")"
  if [ -z "$dep_idx" ]; then
    # External dependency — not in sprint (AC-EC3)
    confidence="heuristic"
    printf '%s|%s|%s|%s|%s|External dependency — %s not in current sprint\n' \
      "$story_key" "$dep_key" "$source" "$confidence" "$match_text" "$dep_key"
  elif [ "$dep_idx" -gt "$story_idx" ]; then
    # Forward reference — inversion detected
    if [ "$source" = "depends_on" ]; then
      confidence="explicit"
    else
      confidence="heuristic"
    fi
    printf '%s|%s|%s|%s|%s|Move %s before %s\n' \
      "$story_key" "$dep_key" "$source" "$confidence" "$match_text" "$dep_key" "$story_key"
  fi
}

# Detect dependency inversions. Reads sprint-status.yaml and story files.
# Outputs pipe-delimited inversion records:
#   dependent|dependency|source|confidence|match_text|suggested_reorder
# Returns empty if no inversions found.
lint_detect_inversions() {
  local order_map
  order_map="$(lint_build_order_map)" || return 1
  [ -n "$order_map" ] || return 0

  # Collect all sprint keys for the AC text scanner.
  local sprint_keys=""
  local key idx
  while IFS=$'\t' read -r key idx; do
    [ -n "$key" ] || continue
    sprint_keys="${sprint_keys:+${sprint_keys} }${key}"
  done <<EOF
$order_map
EOF

  # For each story, check depends_on and AC text.
  local story_key story_idx dep_key story_file
  while IFS=$'\t' read -r story_key story_idx; do
    [ -n "$story_key" ] || continue

    story_file="$(reconcile_locate_story_file "$story_key")" || {
      printf '%s: error: story file not found: %s\n' "$SCRIPT_NAME" "$story_key" >&2
      return 1
    }

    # Explicit depends_on edges.
    local deps
    deps="$(lint_read_depends_on "$story_file")"
    if [ -n "$deps" ]; then
      while IFS= read -r dep_key; do
        [ -n "$dep_key" ] || continue
        _lint_emit_if_inversion "$story_key" "$dep_key" "depends_on" \
          "$story_idx" "$order_map"
      done <<DEPS
$deps
DEPS
    fi

    # Heuristic AC text scan edges.
    local ac_matches match_text
    ac_matches="$(lint_scan_ac_text "$story_file" "$sprint_keys")"
    if [ -n "$ac_matches" ]; then
      while IFS='|' read -r dep_key match_text; do
        [ -n "$dep_key" ] || continue
        [ "$dep_key" != "$story_key" ] || continue
        _lint_emit_if_inversion "$story_key" "$dep_key" "ac_text_scan" \
          "$story_idx" "$order_map" "$match_text"
      done <<AC_MATCHES
$ac_matches
AC_MATCHES
    fi
  done <<ORDER
$order_map
ORDER
}

# Format inversions as JSON. Parameters:
#   $1 — sprint_id
#   $2 — stories_analyzed count
#   $3 — pipe-delimited inversions string (may be empty)
lint_format_json() {
  local sprint_id="$1" count="$2" inversions="$3"

  if [ -z "$inversions" ]; then
    printf '{\n'
    printf '  "sprint_id": "%s",\n' "$sprint_id"
    printf '  "stories_analyzed": %s,\n' "$count"
    printf '  "inversions": [],\n'
    printf '  "status": "clean"\n'
    printf '}\n'
    return 0
  fi

  printf '{\n'
  printf '  "sprint_id": "%s",\n' "$sprint_id"
  printf '  "stories_analyzed": %s,\n' "$count"
  printf '  "inversions": [\n'

  local first=1
  local dependent dependency source confidence match_text suggested_reorder
  while IFS='|' read -r dependent dependency source confidence match_text suggested_reorder; do
    [ -n "$dependent" ] || continue
    if [ "$first" -eq 1 ]; then
      first=0
    else
      printf ',\n'
    fi
    printf '    {\n'
    printf '      "dependent": "%s",\n' "$dependent"
    printf '      "dependency": "%s",\n' "$dependency"
    printf '      "source": "%s",\n' "$source"
    printf '      "confidence": "%s",\n' "$confidence"
    if [ -n "$match_text" ]; then
      printf '      "match_text": "%s",\n' "$match_text"
    fi
    printf '      "suggested_reorder": "%s"\n' "$suggested_reorder"
    printf '    }'
  done <<INV
$inversions
INV
  printf '\n  ],\n'
  printf '  "status": "inversions_detected"\n'
  printf '}\n'
}

# Format inversions as human-readable text. Parameters:
#   $1 — sprint_id
#   $2 — stories_analyzed count
#   $3 — pipe-delimited inversions string (may be empty)
lint_format_text() {
  local sprint_id="$1" count="$2" inversions="$3"

  printf 'Dependency Inversion Lint — %s\n' "$sprint_id"
  printf 'Stories analyzed: %s\n\n' "$count"

  if [ -z "$inversions" ]; then
    printf 'Result: CLEAN — no dependency inversions detected.\n'
    return 0
  fi

  printf 'INVERSIONS DETECTED:\n\n'
  printf '%-12s %-12s %-15s %-12s %s\n' "Dependent" "Dependency" "Source" "Confidence" "Suggested Reorder"
  printf '%-12s %-12s %-15s %-12s %s\n' "----------" "----------" "-------------" "----------" "-----------------"

  local dependent dependency source confidence match_text suggested_reorder
  while IFS='|' read -r dependent dependency source confidence match_text suggested_reorder; do
    [ -n "$dependent" ] || continue
    printf '%-12s %-12s %-15s %-12s %s\n' "$dependent" "$dependency" "$source" "$confidence" "$suggested_reorder"
  done <<INV
$inversions
INV
}

# Main entry point for lint-dependencies subcommand.
# Parameters:
#   $1 — output format (json|text), defaults to json
#   $2 — sprint_id filter (currently unused; accepted for forward-compat)
cmd_lint_dependencies() {
  local format="${1:-json}"
  local sprint_id_filter="${2:-}"

  # Validate format
  case "$format" in
    json|text) ;;
    *) die "invalid --format value: '$format'. Allowed: json, text" ;;
  esac

  # Read sprint-status.yaml
  if [ ! -r "$SPRINT_STATUS_YAML" ]; then
    die "sprint-status.yaml not readable: $SPRINT_STATUS_YAML"
  fi

  # Validate basic yaml structure: must contain sprint_id or stories section.
  # A file with neither is treated as malformed (AC-EC8).
  if ! grep -qE '^(sprint_id:|stories:)' "$SPRINT_STATUS_YAML" 2>/dev/null; then
    die "malformed sprint-status.yaml: no sprint_id or stories section found in $SPRINT_STATUS_YAML"
  fi

  # Extract sprint_id from yaml
  local sprint_id
  sprint_id="$(awk '
    /^sprint_id:/ {
      v = $0
      sub(/^sprint_id:[[:space:]]*/, "", v)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
      print v
      exit
    }
  ' "$SPRINT_STATUS_YAML")"
  sprint_id="${sprint_id:-unknown}"

  # Count stories
  local pairs
  pairs="$(reconcile_list_yaml_stories "$SPRINT_STATUS_YAML")" || {
    die "could not parse sprint-status.yaml: $SPRINT_STATUS_YAML"
  }

  local story_count=0
  if [ -n "$pairs" ]; then
    story_count="$(printf '%s\n' "$pairs" | grep -c . || true)"
  fi

  # Fast path: zero stories (AC-EC1)
  if [ "$story_count" -eq 0 ]; then
    if [ "$format" = "json" ]; then
      lint_format_json "$sprint_id" 0 ""
    else
      lint_format_text "$sprint_id" 0 ""
    fi
    exit 0
  fi

  # Detect inversions. Capture stderr separately so error messages
  # (e.g., "story file not found") surface to the caller even when
  # stdout is being captured by a command substitution (AC-EC10).
  local inversions lint_err_file
  lint_err_file="$(mktemp "${SPRINT_STATUS_YAML}.lint-err.XXXXXX" 2>/dev/null || mktemp)"
  # E64-S7: register lint_err_file for script-level EXIT/INT/TERM cleanup.
  # Without this, interrupting lint-dependencies between mktemp and the
  # inline rm -f leaks an orphan *.lint-err.?????? file. Mirrors the
  # register-then-clear pattern E64-S5 wired into the four atomic-write
  # mktemp call sites.
  local _lint_err_idx
  _GAIA_TMP_PATHS+=("$lint_err_file")
  _lint_err_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))
  inversions="$(lint_detect_inversions 2>"$lint_err_file")" || {
    local lint_err
    lint_err="$(cat "$lint_err_file" 2>/dev/null)"
    rm -f "$lint_err_file"
    _GAIA_TMP_PATHS[$_lint_err_idx]=""
    if [ -n "$lint_err" ]; then
      printf '%s\n' "$lint_err" >&2
    fi
    die "lint-dependencies analysis failed"
  }
  rm -f "$lint_err_file"
  _GAIA_TMP_PATHS[$_lint_err_idx]=""

  # Output
  if [ "$format" = "json" ]; then
    lint_format_json "$sprint_id" "$story_count" "$inversions"
  else
    lint_format_text "$sprint_id" "$story_count" "$inversions"
  fi

  # Exit code contract: 0 clean, 2 inversions, 1 error (already handled above)
  if [ -n "$inversions" ]; then
    exit 2
  fi
  exit 0
}

# ---------- Subcommand: record-escalation-override (E38-S2, FR-SPQG-1) ----------
#
# Append an escalation-halt override entry to sprint-status.yaml under the
# `overrides:` block. Atomic under flock (same critical section discipline as
# transition). Idempotent on (sprint_id, sorted-unique(ids), override_type) —
# if an entry with the same override_type and the same sorted id set already
# exists, the call is a no-op (zero bytes written, exit 0).
#
# Write boundary (ADR-042): this is the ONLY path the sprint-plan skill uses
# to record escalation-halt overrides. The skill MUST NOT write overrides
# inline via yq or sed.
#
# Usage:
#   sprint-state.sh record-escalation-override \
#     --item-ids "AI-42,AI-77" --user alice --reason "Acknowledged by lead"

# Sort and deduplicate a comma-or-space-separated id list. Echoes a single
# comma-joined sorted-unique line.
_override_normalize_ids() {
  local raw="$1"
  printf '%s' "$raw" \
    | tr ',' '\n' \
    | awk '{ gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if ($0 != "") print }' \
    | sort -u \
    | awk 'BEGIN{first=1} { if (!first) printf ","; printf "%s", $0; first=0 } END { printf "\n" }'
}

# Source escalation-halt.sh to get esch_check_override_recorded for idempotency.
# Library-only script — no side effects on source.
_override_load_esch() {
  local esch="${SPRINT_STATE_SCRIPT_DIR}/escalation-halt.sh"
  if [ ! -r "$esch" ]; then
    die "escalation-halt.sh not found at $esch (required for record-escalation-override)"
  fi
  # shellcheck disable=SC1090
  source "$esch"
}

# Append one override entry under the `overrides:` top-level key. If the key
# does not exist, append it at EOF with the entry as its first child.
# Assumes caller holds the flock.
_override_append_entry() {
  local ids_sorted="$1" user="$2" reason="$3"
  local file="$SPRINT_STATUS_YAML"
  local today
  today="$(date -u +%Y-%m-%d)"

  # Escape reason for YAML double-quoted string
  local reason_escaped
  reason_escaped=$(printf '%s' "$reason" | awk '{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); print }')

  local tmp
  tmp=$(mktemp "${file}.tmp.XXXXXX")
  # E64-S5: register tmp for script-level EXIT/INT/TERM cleanup.
  local _tmp_idx
  _GAIA_TMP_PATHS+=("$tmp")
  _tmp_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  # First pass: does the file contain an `overrides:` key at column 0?
  local has_overrides=0
  if grep -qE '^overrides:[[:space:]]*$' "$file" 2>/dev/null; then
    has_overrides=1
  fi

  if [ "$has_overrides" = "1" ]; then
    # Append the new entry at the END of the overrides section (before any
    # subsequent top-level key). Use awk to find the section boundary.
    awk -v ids="$ids_sorted" -v user="$user" -v reason="$reason_escaped" -v today="$today" '
      BEGIN { in_over = 0; inserted = 0 }
      {
        raw = $0
        sub(/\r$/, "", raw)
      }
      function emit_entry() {
        printf "  - date: \"%s\"\n", today
        printf "    user: \"%s\"\n", user
        printf "    override_type: escalation_halt\n"
        printf "    overridden_item_ids:\n"
        n = split(ids, arr, /,/)
        for (i = 1; i <= n; i++) {
          if (arr[i] != "") printf "      - \"%s\"\n", arr[i]
        }
        printf "    reason: \"%s\"\n", reason
        inserted = 1
      }
      raw ~ /^overrides:[[:space:]]*$/ { in_over = 1; print raw; next }
      # Another top-level key closes the section
      in_over && raw ~ /^[^[:space:]]/ {
        emit_entry()
        in_over = 0
        print raw
        next
      }
      { print raw }
      END {
        if (in_over && !inserted) emit_entry()
      }
    ' "$file" > "$tmp"
  else
    # No overrides section exists — append one at EOF with this entry.
    cat "$file" > "$tmp"
    # Ensure file ends with a newline before appending
    if [ -s "$tmp" ] && [ "$(tail -c1 "$tmp" | wc -l | awk '{print $1}')" = "0" ]; then
      printf '\n' >> "$tmp"
    fi
    {
      printf 'overrides:\n'
      printf '  - date: "%s"\n' "$today"
      printf '    user: "%s"\n' "$user"
      printf '    override_type: escalation_halt\n'
      printf '    overridden_item_ids:\n'
      # shellcheck disable=SC2001
      local id
      # Split on comma
      local IFS=','
      for id in $ids_sorted; do
        [ -n "$id" ] || continue
        printf '      - "%s"\n' "$id"
      done
      printf '    reason: "%s"\n' "$reason_escaped"
    } >> "$tmp"
  fi

  if ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    trap - RETURN
    die "failed to mv tempfile over '$file'"
  fi
  # E64-S5: mv succeeded — clear the slot.
  _GAIA_TMP_PATHS[$_tmp_idx]=""
  trap - RETURN
}

do_record_override_locked() {
  local ids_raw="$1" user="$2" reason="$3"

  if [ ! -s "$SPRINT_STATUS_YAML" ]; then
    die "sprint-status.yaml is missing or empty: $SPRINT_STATUS_YAML"
  fi

  local ids_sorted
  ids_sorted="$(_override_normalize_ids "$ids_raw")"
  if [ -z "$ids_sorted" ]; then
    die "record-escalation-override: --item-ids resolved to an empty list after normalization"
  fi

  # Idempotency check via the escalation-halt sibling library.
  _override_load_esch
  if esch_check_override_recorded "$SPRINT_STATUS_YAML" "$ids_sorted"; then
    printf '%s: override already recorded for ids=[%s] — no-op\n' \
      "$SCRIPT_NAME" "$ids_sorted"
    return 0
  fi

  _override_append_entry "$ids_sorted" "$user" "$reason"
  printf '%s: recorded escalation_halt override for ids=[%s] user=%s\n' \
    "$SCRIPT_NAME" "$ids_sorted" "$user"
}

cmd_record_escalation_override() {
  local ids_raw="$1" user="$2" reason="$3"

  [ -n "$ids_raw" ] || die "record-escalation-override requires --item-ids <ids>"
  [ -n "$user" ]    || die "record-escalation-override requires --user <name>"
  [ -n "$reason" ]  || die "record-escalation-override requires --reason <text>"

  local flock_bin
  flock_bin=$(command -v flock || true)

  if [ -n "$flock_bin" ]; then
    (
      exec 9>"$SPRINT_STATUS_LOCK"
      if ! "$flock_bin" -x -w 5 9; then
        die "flock timeout acquiring $SPRINT_STATUS_LOCK"
      fi
      do_record_override_locked "$ids_raw" "$user" "$reason"
    )
  else
    local tries=0
    while ! ( set -C; : > "$SPRINT_STATUS_LOCK" ) 2>/dev/null; do
      tries=$((tries + 1))
      if [ "$tries" -ge 50 ]; then
        die "lock timeout acquiring $SPRINT_STATUS_LOCK"
      fi
      sleep 0.1 2>/dev/null || sleep 1
    done
    # shellcheck disable=SC2064
    trap "rm -f '$SPRINT_STATUS_LOCK'" EXIT INT TERM
    do_record_override_locked "$ids_raw" "$user" "$reason"
    rm -f "$SPRINT_STATUS_LOCK"
    trap - EXIT INT TERM
  fi
}

# ---------- Argument parsing ----------

main() {
  local subcmd="${1:-}"
  if [ -z "$subcmd" ]; then
    usage >&2
    exit 1
  fi
  shift || true

  case "$subcmd" in
    --help|-h)
      usage
      exit 0
      ;;
    transition|inject|get|validate|reconcile|lint-dependencies|record-escalation-override)
      ;;
    *)
      printf '%s: error: unknown subcommand: %s\n' "$SCRIPT_NAME" "$subcmd" >&2
      usage >&2
      exit 1
      ;;
  esac

  local story_key="" to_state=""
  local reconcile_sprint_id="" reconcile_dry_run=0
  local lint_format="json" lint_sprint_id=""
  local override_item_ids="" override_user="" override_reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --story)
        [ $# -ge 2 ] || die "--story requires a value"
        story_key="$2"; shift 2 ;;
      --story=*)
        story_key="${1#--story=}"; shift ;;
      --to)
        [ $# -ge 2 ] || die "--to requires a value"
        to_state="$2"; shift 2 ;;
      --to=*)
        to_state="${1#--to=}"; shift ;;
      --sprint-id)
        [ $# -ge 2 ] || die "--sprint-id requires a value"
        reconcile_sprint_id="$2"; shift 2 ;;
      --sprint-id=*)
        reconcile_sprint_id="${1#--sprint-id=}"; shift ;;
      --dry-run)
        reconcile_dry_run=1; shift ;;
      --format)
        [ $# -ge 2 ] || die "--format requires a value"
        lint_format="$2"; shift 2 ;;
      --format=*)
        lint_format="${1#--format=}"; shift ;;
      --item-ids)
        [ $# -ge 2 ] || die "--item-ids requires a value"
        override_item_ids="$2"; shift 2 ;;
      --item-ids=*)
        override_item_ids="${1#--item-ids=}"; shift ;;
      --user)
        [ $# -ge 2 ] || die "--user requires a value"
        override_user="$2"; shift 2 ;;
      --user=*)
        override_user="${1#--user=}"; shift ;;
      --reason)
        [ $# -ge 2 ] || die "--reason requires a value"
        override_reason="$2"; shift 2 ;;
      --reason=*)
        override_reason="${1#--reason=}"; shift ;;
      --help|-h)
        usage
        exit 0 ;;
      *)
        die "unknown flag: $1" ;;
    esac
  done

  # Resolve SPRINT_STATE_SCRIPT_DIR (directory containing this script) for
  # sibling script lookups. Respect a pre-exported override for tests.
  if [ -z "${SPRINT_STATE_SCRIPT_DIR:-}" ]; then
    SPRINT_STATE_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
  fi
  resolve_paths

  # ---------- Startup orphan-tmp sweep (E64-S6) ----------
  #
  # Garbage-collect *.tmp.?????? files older than 60 minutes under
  # ${IMPLEMENTATION_ARTIFACTS}. Catches orphans left by kill -9 / OOM /
  # power loss (which bypass E64-S5's EXIT/INT/TERM trap). Bounded to the
  # documented allowlist (sprint-status.yaml directory). Never /tmp, never
  # $HOME, never ${PROJECT_PATH} root. Set GAIA_SKIP_ORPHAN_SWEEP=1 to
  # disable. Errors swallowed; zero stdout (silent GC).
  if [ "${GAIA_SKIP_ORPHAN_SWEEP:-0}" != "1" ]; then
    find "${IMPLEMENTATION_ARTIFACTS}" \
      -maxdepth 2 -name '*.tmp.??????' -mmin +60 -delete 2>/dev/null || true
  fi

  case "$subcmd" in
    get)
      [ -n "$story_key" ] || die "get requires --story <key>"
      cmd_get "$story_key" ;;
    validate)
      [ -n "$story_key" ] || die "validate requires --story <key>"
      cmd_validate "$story_key" ;;
    transition)
      [ -n "$story_key" ] || die "transition requires --story <key>"
      [ -n "$to_state" ] || die "transition requires --to <state>"
      cmd_transition "$story_key" "$to_state" ;;
    inject)
      [ -n "$story_key" ] || die "inject requires --story <key>"
      cmd_inject "$story_key" "${reconcile_sprint_id:-}" ;;
    reconcile)
      # reconcile_sprint_id currently scopes to the active sprint implicitly
      # since the yaml holds one sprint at a time (ADR-055 §10.29.1 default).
      # Accepted for forward-compatibility but not yet consulted.
      : "${reconcile_sprint_id:=}"
      cmd_reconcile "$reconcile_dry_run" ;;
    lint-dependencies)
      # lint_sprint_id reuses reconcile_sprint_id from shared --sprint-id flag.
      cmd_lint_dependencies "$lint_format" "${reconcile_sprint_id:-}" ;;
    record-escalation-override)
      cmd_record_escalation_override "$override_item_ids" "$override_user" "$override_reason" ;;
  esac
}

main "$@"
