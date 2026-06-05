#!/usr/bin/env bash
# sprint-state.sh — GAIA foundation script
#
# Validates sprint state machine transitions, updates the story file
# frontmatter + body `**Status:**` line and `sprint-status.yaml` atomically,
# and emits a lifecycle event on every successful transition. Replaces the
# LLM-interpreted status-sync protocol with a deterministic, race-safe
# script.
#
# Invocation contract:
#
#   sprint-state.sh transition                 --story <key> --to <state>
#   sprint-state.sh get                        --story <key>
#   sprint-state.sh validate                   --story <key>
#   sprint-state.sh reconcile                  [--sprint-id <id>] [--dry-run]
#   sprint-state.sh lint-dependencies          [--sprint-id <id>] [--format json|text]
#   sprint-state.sh record-escalation-override --item-ids <ids> --user <name> --reason <text>
#   sprint-state.sh --help
#
# Reconcile:
#   Scans story files under IMPLEMENTATION_ARTIFACTS to detect and correct
#   drift between authoritative story frontmatter (source of truth) and
#   the derivative sprint-status.yaml cache. Write boundary:
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
# Review Gate check on -> done:
#   Transitions to 'done' shell out to review-gate.sh status and require all
#   six canonical rows to report PASSED. Any other verdict (UNVERIFIED or
#   FAILED) blocks the transition with the offending row names enumerated.
#
# Config:
#   PROJECT_PATH                — defaults to "." when unset. Story files and
#                                 sprint-status.yaml are located relative to it.
#   IMPLEMENTATION_ARTIFACTS    — defaults to "${PROJECT_PATH}/.gaia/artifacts/implementation-artifacts".
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
#   1 and surfaces the failure ("event failure surfaced with exit 1").
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

# Script-level EXIT/INT/TERM trap for atomic-write tmp cleanup.
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
# The `ready-for-dev|backlog` defer edge restores the path documented by
# /gaia-correct-course Step 5 ("removed stories transition --to backlog").
# Without this edge the state machine rejects the correct-course defer path
# and operators must fall back to sprint-close `--force-with-rollover`. The
# edge is semantically clean: a story selected for development but not yet
# in-progress can be returned to the backlog without traversing the full
# `in-progress → review → done` arc.
ALLOWED_EDGES=(
  "backlog|validating"
  "validating|ready-for-dev"
  "ready-for-dev|in-progress"
  "ready-for-dev|backlog"
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
  sprint-state.sh transition                 --sprint <id> --to <state>
  sprint-state.sh inject                     --story <key> [--sprint-id <id>]
  sprint-state.sh get                        --story <key>
  sprint-state.sh validate                   --story <key>
  sprint-state.sh get-goals                  --sprint <id>
  sprint-state.sh set-goals                  --sprint <id> --goals "<g1|g2|..>"
  sprint-state.sh update-goals               --sprint <id> --goals "<g1|g2|..>"
  sprint-state.sh set-review-justification   --sprint <id> --file <path>
  sprint-state.sh set-shape                  --sprint <id> --shape <thrust|completion-pass>
  sprint-state.sh set-story-sprint           --story <key> --sprint <id>
  sprint-state.sh reconcile                  [--sprint-id <id>] [--dry-run]
  sprint-state.sh lint-dependencies          [--sprint-id <id>] [--format json|text]
  sprint-state.sh record-escalation-override --item-ids <ids> --user <name> --reason <text>
  sprint-state.sh detect-auto-close
  sprint-state.sh --help

Subcommands:
  init              Bootstrap a fresh sprint-status.yaml when none exists yet.
                    Seeds the canonical shape (sprint_id / status=planned /
                    total_points=0 / goals=[] / items=[]) under flock — a fresh
                    sprint starts in the `planned` state (planned → active →
                    review → closed). Idempotent — refuses to overwrite
                    an existing yaml. Required before the first `inject` in a
                    new project. Usage: sprint-state.sh init --sprint-id <id>.
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
                    injected key is a no-op.
                    total_points: accumulated from the injected story's
                    frontmatter `points:` field — no --points CLI flag
                    is needed or accepted. Recomputes capacity_utilization
                    and emits one story_injected lifecycle event.
                    Boundary-write seed rule: when boundary-writing a
                    fresh sprint, seed total_points=0 — inject accumulates
                    onto the existing total; a non-zero seed produces
                    double-counted totals.
                    Used by /gaia-correct-course story-injection.
  get               Print the story's current status (from the story file)
                    to stdout and exit 0.
  validate          Compare story file status to sprint-status.yaml. Exit 0
                    if they agree, exit 1 with a drift description on stderr
                    if not.
  reconcile         Scan the target sprint's story files and reconcile
                    sprint-status.yaml to match authoritative frontmatter.
                    NEVER modifies story files. Exit 0 on no-drift or
                    drift-corrected, 2 on dry-run drift, 1 on error.
  lint-dependencies Read-only analysis of the selected sprint's dependency
                    graph. Detects forward-references (dependency inversions)
                    where a story depends on a resource created by a later
                    story in the sprint order.
                    Exit 0 = clean, 2 = inversions detected (advisory),
                    1 = error.
  detect-auto-close Read-only advisory probe. Emits a single-line JSON
                    payload on stdout when the active sprint has every story
                    at status=done with total_count>0 and top-level
                    status=active. Empty stdout when the auto-close
                    condition is not met. ALWAYS exits 0. NEVER mutates
                    sprint-status.yaml — the boundary write
                    (status=closed + next-sprint seed) remains a manual
                    operator action.

  transition --sprint  Sprint-level state-machine transitions. Edges:
                    active→review (gated on all-stories-done), review→closed,
                    review→correction, correction→active.
                    Refuses any other edge with `illegal sprint-level
                    transition: <from>→<to>`. Uses atomic mktemp + mv so
                    YAML comments and formatting are preserved.

  get-goals         Print the sprint's `goals[]` list (one per line) to
                    stdout. Empty output + exit 0 when no goals set.

  set-goals         REPLACE the sprint's `goals[]` list with the
                    pipe-delimited string passed via --goals "<g1|g2|...>".
                    Each goal is capped at 280 chars. Lossless round-trip
                    with get-goals.

  update-goals      Alias for set-goals (REPLACES; does not append).

  set-review-justification
                    Write the `review_justification:` block from a YAML
                    payload file (--file <path>) into sprint-status.yaml.
                    Required payload fields: primary_criterion ∈ {C1, C2, C3},
                    qualifying_story_points (int), total_story_points (int),
                    qualifying_ratio ≥ 0.80, explanation (200-1000 chars block
                    scalar). Existing block is replaced atomically.

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
  2  reconcile --dry-run detected drift but wrote nothing, or
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
# error messages. Centralised so every fail-fast path emits the same hint.
# Operators reading the rejection see exactly which values the lifecycle
# accepts and can fix the call site without reading source.
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
# strings 'PASSED' / 'FAILED' / 'UNVERIFIED') MUST be rejected before any
# tempfile rewrite touches disk — yaml and story file are left byte-identical.
# The error names BOTH the offending value and the allowed enum so the caller
# can correct the invocation without reading source.
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
# temp-dir yaml that does not live under IMPLEMENTATION_ARTIFACTS.
# When SPRINT_STATUS_YAML is unset, resolve to the canonical location under
# IMPLEMENTATION_ARTIFACTS, then fall back to $PROJECT_PATH/sprint-status.yaml
# if the canonical path does not exist but the fallback does — supports bats
# fixtures which place the yaml at $TEST_TMP root for test speed.
resolve_paths() {
  PROJECT_PATH="${PROJECT_PATH:-.}"
  # Smart-fallback for IMPLEMENTATION_ARTIFACTS — prefer
  # .gaia/artifacts/implementation-artifacts/ when present on disk, fall back
  # to legacy docs/implementation-artifacts/ for in-deprecation-window
  # consumers and bats fixtures. Env-var override still wins.
  if [ -z "${IMPLEMENTATION_ARTIFACTS:-}" ]; then
    if [ -d "${PROJECT_PATH}/.gaia/artifacts/implementation-artifacts" ]; then
      IMPLEMENTATION_ARTIFACTS="${PROJECT_PATH}/.gaia/artifacts/implementation-artifacts"
    else
      IMPLEMENTATION_ARTIFACTS="${PROJECT_PATH}/docs/implementation-artifacts"
    fi
  fi
  # Prefer `.gaia/state/sprint-status.yaml` (mutable-runtime-state tier) over
  # the legacy `docs/implementation-artifacts/sprint-status.yaml`
  # (artifacts-tier). Legacy fallback retained during the transition window.
  if [ -z "${SPRINT_STATUS_YAML:-}" ]; then
    local gaia_state="${PROJECT_PATH}/.gaia/state/sprint-status.yaml"
    local canonical="${IMPLEMENTATION_ARTIFACTS}/sprint-status.yaml"
    local fallback="${PROJECT_PATH}/sprint-status.yaml"
    # .gaia/state/ is the canonical home for sprint-status.yaml and is what
    # sprint-status-dashboard.sh reads first. Resolution order:
    #   1. existing .gaia/state/   yaml — canonical, already seeded
    #   2. existing impl-artifacts yaml — read-compat for projects seeded there
    #      before this fix (the prior default write target)
    #   3. existing project-root fallback (bats fixtures)
    #   4. fresh write → canonical .gaia/state/ default
    # Previously fresh writes (rung 4) defaulted to impl-artifacts, a path the
    # dashboard never looked at — so `init` succeeded but `/gaia-sprint-status`
    # then errored "not found". Defaulting fresh writes to .gaia/state/ aligns
    # the writer with the canonical reader.
    if [ -e "$gaia_state" ]; then
      SPRINT_STATUS_YAML="$gaia_state"
      # When the canonical .gaia/state/ copy wins but a LEGACY impl-artifacts
      # copy is also present, the two can silently diverge (the legacy one
      # freezes at its pre-migration state because every writer now targets
      # .gaia/state/). Surface it loudly so the operator can remove the stale
      # shadow — and so a later transient absence of .gaia/state/ cannot fall
      # through to rung 2 (the stale copy) unnoticed. Non-fatal: the canonical
      # copy is still used; we only warn.
      #
      # issue-1392: gate on CONTENT divergence, not mere co-existence. This
      # skill itself mirrors .gaia/state/ → impl-artifacts/ on every mutation
      # (the layout-conformance mirror), so the two are routinely byte-identical
      # — warning on co-existence alone fired on every command against a fresh
      # project where the files were identical (and "removing" the shadow just
      # regenerated it on the next mutation). `cmp -s` is true (exit 0) when the
      # files match, so we warn only when they actually differ.
      if [ -e "$canonical" ] && [ "$canonical" != "$gaia_state" ] \
         && ! cmp -s "$gaia_state" "$canonical" 2>/dev/null; then
        printf '%s: WARNING: stale legacy sprint-status.yaml at %s shadows the canonical .gaia/state/ copy — remove it to avoid divergence\n' \
          "${SCRIPT_NAME:-sprint-state.sh}" "$canonical" >&2
      fi
    elif [ -e "$canonical" ]; then
      SPRINT_STATUS_YAML="$canonical"
    elif [ -e "$fallback" ]; then
      SPRINT_STATUS_YAML="$fallback"
    else
      SPRINT_STATUS_YAML="$gaia_state"
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

# Locate the story file under IMPLEMENTATION_ARTIFACTS across all three layout
# tiers, then filter candidates by frontmatter `template: 'story'` to exclude
# review sibling files (-review.md, -qa-tests.md, -security-review.md, etc.).
# Returns via the STORY_FILE global. Exits 1 on zero or multiple canonical
# matches.
#
# Layout tiers globbed (precedence handled downstream by the template filter +
# realpath dedup, mirroring resolve-story-file.sh):
#   0. NEW per-story nested:  epic-{slug}/{key}-{slug}/story.md
#   1. Legacy nested:         epic-{slug}/stories/{key}-{slug}.md
#   2. Legacy flat:           {key}-{slug}.md
STORY_FILE=""
locate_story_file() {
  local key="$1"
  local pattern="${IMPLEMENTATION_ARTIFACTS}/${key}-*.md"
  local epic_pattern="${IMPLEMENTATION_ARTIFACTS}/epic-*/stories/${key}-*.md"
  # NEW per-story layout: the story's own directory carries the key; basename is
  # literally story.md. The `/stories/` segment (legacy tier-1) is excluded below
  # so a bare-glob `epic-*/${key}-*/story.md` cannot also pick up the tier-1 tree.
  local perstory_pattern="${IMPLEMENTATION_ARTIFACTS}/epic-*/${key}-*/story.md"

  local matches=()
  shopt -s nullglob
  # shellcheck disable=SC2206
  matches=( $pattern $epic_pattern $perstory_pattern )
  shopt -u nullglob

  # Drop any perstory_pattern hit that actually lives under a legacy `stories/`
  # segment — that path belongs to the tier-1 epic_pattern, not tier-0, and the
  # `*` in the glob would otherwise let `epic-*/stories/{key}-*/story.md`
  # (per-story evidence dirs) leak in (mirrors resolve-story-file.sh guard).
  if [ "${#matches[@]}" -gt 0 ]; then
    local _filtered=()
    local _mm
    for _mm in "${matches[@]}"; do
      case "$_mm" in
        */stories/*/story.md) continue ;;
      esac
      _filtered+=( "$_mm" )
    done
    matches=( "${_filtered[@]}" )
  fi

  if [ "${#matches[@]}" -eq 0 ]; then
    die "no story file found for key '$key' (globs: $pattern | $epic_pattern | $perstory_pattern)"
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
  # epic-grouped real file (transition shims) produce two canonical matches
  # that are the same physical file. Prefer non-symlinks.
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
  # Defense-in-depth: even if a future caller bypasses cmd_transition's
  # fail-fast guard, this writer refuses to stamp a non-canonical value into
  # the story file. Belt-and-braces against non-canonical status writes.
  assert_canonical_state "$new_status" "write story status"
  local tmp
  tmp=$(mktemp "${file}.tmp.XXXXXX")
  # Register tmp for script-level EXIT/INT/TERM cleanup.
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
  # mv succeeded — clear the slot.
  _GAIA_TMP_PATHS[$_tmp_idx]=""
  trap - RETURN
}

# Rewrite the matching story entry in sprint-status.yaml so its `status:`
# field reads $new_status. Preserves all other bytes. Tempfile + atomic mv.
# Exits 1 if the story entry is not found (so drift is loud, never silent).
rewrite_sprint_status_yaml() {
  local story_key="$1" new_status="$2"
  local file="$SPRINT_STATUS_YAML"

  # Defense-in-depth: refuse to stamp a non-canonical value into
  # sprint-status.yaml even if the caller bypassed the higher-level guard.
  # This is the same chokepoint that reconcile and the transition path both
  # flow through, so guarding here closes every write path.
  assert_canonical_state "$new_status" "write sprint-status.yaml status"

  if [ ! -s "$file" ]; then
    die "sprint-status.yaml is missing or empty: $file"
  fi

  local tmp
  tmp=$(mktemp "${file}.tmp.XXXXXX")
  # Register tmp for script-level EXIT/INT/TERM cleanup.
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
  # mv succeeded — clear the slot.
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
  # under .gaia/artifacts/implementation-artifacts/stories/ — our layout is flat, so we
  # instead call `check` directly and rely on its own locator. review-gate.sh
  # uses `${PROJECT_PATH}/.gaia/artifacts/implementation-artifacts/stories/<key>-*.md`;
  # fall back to a thin parser that reads the Review Gate table from the
  # story file we already resolved. This keeps this function independent of any
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
  # story file.
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

  # Validate adjacency.
  validate_transition "$from_state" "$to_state"

  # Review Gate enforcement for -> done.
  if [ "$to_state" = "done" ]; then
    check_review_gate_all_passed "$story_key"

    # DoD completeness gate. Prior behavior allowed `review -> done` when the
    # Review Gate was all-PASSED even if the story's Definition of Done section
    # was 0/N checked. Block the transition when any DoD checkbox is unchecked.
    if [ -n "${STORY_FILE:-}" ] && [ -f "$STORY_FILE" ]; then
      _dod_unchecked=$(awk '
        BEGIN { in_section=0; unchecked=0 }
        /^## Definition of Done[[:space:]]*$/ { in_section=1; next }
        in_section && /^## / { in_section=0 }
        in_section && /^[[:space:]]*-[[:space:]]*\[[[:space:]]\][[:space:]]/ { unchecked++ }
        END { print unchecked }
      ' "$STORY_FILE")
      if [ -n "$_dod_unchecked" ] && [ "$_dod_unchecked" -gt 0 ]; then
        die "story $story_key: refuse review -> done — $_dod_unchecked DoD item(s) unchecked (run /gaia-check-dod and tick each box before transitioning to done)"
      fi

      # Dependency gate on done. Prior behavior: backlog-select-lint
      # enforced deps at sprint selection time, but the done transition
      # ignored deps entirely. Block done when any depends_on key is non-done.
      _fm_deps=$(awk '
        BEGIN { in_fm=0; in_deps=0 }
        /^---[[:space:]]*$/ { if (in_fm==0) { in_fm=1; next } else { exit } }
        !in_fm { next }
        /^depends_on:[[:space:]]*\[/ {
          line=$0; sub(/^depends_on:[[:space:]]*\[/, "", line); sub(/\].*$/, "", line)
          n=split(line, parts, ",")
          for (i=1;i<=n;i++) { gsub(/[[:space:]"]/, "", parts[i]); if (parts[i] ~ /^E[0-9]+-S[0-9]+$/) print parts[i] }
          next
        }
        /^depends_on:[[:space:]]*$/ { in_deps=1; next }
        in_deps && /^[[:space:]]*-[[:space:]]*[Ee][0-9]+-[Ss][0-9]+/ {
          t=$0; gsub(/[[:space:]"-]/, "", t); if (t ~ /^E[0-9]+-S[0-9]+$/) print t
        }
        in_deps && /^[^[:space:]-]/ { in_deps=0 }
      ' "$STORY_FILE")
      if [ -n "$_fm_deps" ]; then
        _unmet=""
        for _dep in $_fm_deps; do
          # Cross-sprint dep resolution. The dep status is consulted in three
          # sources in order — (1) live yaml, (2) the depended story's file
          # frontmatter, (3) the most-recent sprint-archive entry — and the
          # first non-empty answer wins. This handles predecessor stories from
          # closed sprints that have dropped out of the live yaml.
          # Try BOTH yaml shapes — init/inject seeds a top-level `.stories[]`
          # shape (no `.sprints[]` wrapper). Try the canonical top-level shape
          # first, then fall back to the legacy `.sprints[].stories[]` shape
          # for any vestigial multi-sprint roll-ups.
          _dep_status=$(yq -r ".stories[] | select(.key == \"${_dep}\") | .status" "${SPRINT_STATUS_YAML:-${PROJECT_ROOT:-.}/.gaia/state/sprint-status.yaml}" 2>/dev/null | head -1 || true)
          if [ -z "$_dep_status" ] || [ "$_dep_status" = "null" ]; then
            _dep_status=$(yq -r ".sprints[].stories[] | select(.key == \"${_dep}\") | .status" "${SPRINT_STATUS_YAML:-${PROJECT_ROOT:-.}/.gaia/state/sprint-status.yaml}" 2>/dev/null | head -1 || true)
          fi
          if [ -z "$_dep_status" ] || [ "$_dep_status" = "null" ]; then
            # Tier 2: the depended story's file frontmatter (source of truth).
            # Try BOTH layouts (canonical first, legacy as fallback). The
            # canonical layout is `epic-*/{key}-*/story.md` (per-story
            # directory); legacy layout was `epic-*/stories/{key}-*.md`
            # (per-story file under stories/).
            for _dep_sf in "${IMPLEMENTATION_ARTIFACTS:-${PROJECT_ROOT:-.}/.gaia/artifacts/implementation-artifacts}"/epic-*/"${_dep}-"*/story.md "${IMPLEMENTATION_ARTIFACTS:-${PROJECT_ROOT:-.}/.gaia/artifacts/implementation-artifacts}"/epic-*/stories/"${_dep}-"*.md "${IMPLEMENTATION_ARTIFACTS:-${PROJECT_ROOT:-.}/.gaia/artifacts/implementation-artifacts}"/epic-*/"${_dep}-"*.md; do
              if [ -f "$_dep_sf" ]; then
                _dep_status=$(awk '
                  BEGIN { in_fm=0 }
                  /^---[[:space:]]*$/ { if (in_fm==0) { in_fm=1; next } else { exit } }
                  !in_fm { next }
                  /^status:[[:space:]]*/ { sub(/^status:[[:space:]]*/, ""); gsub(/[[:space:]"]/, ""); print; exit }
                ' "$_dep_sf")
                [ -n "$_dep_status" ] && break
              fi
            done
          fi
          if [ -z "$_dep_status" ] || [ "$_dep_status" = "null" ]; then
            # Tier 3: scan sprint-archive/. Pick the most-recent archive that
            # mentions the dep key. Archives are named sprint-N-closed-<ts>.yaml.
            for _archive in $(ls -1t "${IMPLEMENTATION_ARTIFACTS:-${PROJECT_ROOT:-.}/.gaia/artifacts/implementation-artifacts}"/sprint-archive/sprint-*-closed-*.yaml 2>/dev/null); do
              # Try both yaml shapes — sprint archives may be either top-level
              # `.stories[]` (canonical) or rolled-up `.sprints[].stories[]` (legacy).
              _arch_status=$(yq -r ".stories[]? | select(.key == \"${_dep}\") | .status" "$_archive" 2>/dev/null | head -1 || true)
              if [ -z "$_arch_status" ] || [ "$_arch_status" = "null" ]; then
                _arch_status=$(yq -r ".sprints[].stories[]? | select(.key == \"${_dep}\") | .status" "$_archive" 2>/dev/null | head -1 || true)
              fi
              if [ -n "$_arch_status" ] && [ "$_arch_status" != "null" ]; then
                _dep_status="$_arch_status"
                break
              fi
            done
          fi
          if [ "$_dep_status" != "done" ]; then
            _unmet="${_unmet} ${_dep}(${_dep_status:-unknown})"
          fi
        done
        if [ -n "$_unmet" ]; then
          die "story $story_key: refuse review -> done — unmet hard dependencies:${_unmet} (complete those stories first, or remove the depends_on entry if the dependency no longer applies)"
        fi
      fi
    fi
  fi

  # (b, c) Atomic updates: story file first (source of truth), then yaml.
  rewrite_story_status "$STORY_FILE" "$to_state"
  rewrite_sprint_status_yaml "$story_key" "$to_state"

  # (d) Emit exactly one lifecycle event. Any failure exits 1; file writes
  # are NOT rolled back — callers MUST treat a non-zero exit from transition
  # as "run validate and fix drift". "event failure surfaced with exit 1" is
  # an explicitly permitted outcome.
  emit_lifecycle_event "$story_key" "$from_state" "$to_state"

  printf '%s: %s transitioned %s -> %s\n' "$SCRIPT_NAME" "$story_key" "$from_state" "$to_state"
}

cmd_transition() {
  local story_key="$1" to_state="$2"

  # Fail-fast: refuse any --to value that is not in the canonical lifecycle
  # enum. The rejection happens BEFORE the flock and BEFORE any tempfile is
  # created, so sprint-status.yaml and the story file are guaranteed
  # byte-identical on a non-canonical input. The error names both the
  # offending value and the allowed enum so the caller can correct the
  # invocation without reading source.
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

# ---------- Subcommand: inject ----------
#
# Append a backlog story's metadata to the active sprint's sprint-status.yaml
# entry list. Until this subcommand landed, /gaia-correct-course
# story-injection had no canonical write path and operators had to hand-edit
# sprint-status.yaml (a hard-rule violation).
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
# Exit codes:
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
  # Register tmp for script-level EXIT/INT/TERM cleanup.
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
  # mv succeeded — clear the slot.
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

  # Drift guard: frontmatter sprint_id MUST match yaml sprint_id.
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

# ---------- Subcommand: reconcile ----------

# Locate a story file for reconcile.
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
# Skips are observable, not silent.
#
# Case-insensitive glob via nocaseglob so {slug}-story.md fixtures match
# upper-cased keys on Linux. Returns the first canonical match via stdout.
# Returns non-zero (return 1) if no canonical story file is found — caller
# handles the missing-file error.
reconcile_locate_story_file() {
  local key="$1"
  local matches=()
  shopt -s nullglob nocaseglob
  # Tiers globbed: flat, legacy-nested, and the per-story layout
  # epic-{slug}/{key}-{slug}/story.md (basename story.md).
  # shellcheck disable=SC2206
  matches=( "${IMPLEMENTATION_ARTIFACTS}/${key}-"*.md \
            "${IMPLEMENTATION_ARTIFACTS}"/epic-*/stories/"${key}-"*.md \
            "${IMPLEMENTATION_ARTIFACTS}"/epic-*/"${key}-"*/story.md )
  shopt -u nullglob nocaseglob

  if [ "${#matches[@]}" -eq 0 ]; then
    return 1
  fi

  local m
  for m in "${matches[@]}"; do
    # Exclude per-story evidence dirs that live under a legacy `stories/`
    # segment — those belong to the tier-1 layer, not the new tier-0 layout.
    case "$m" in
      */stories/*/story.md) continue ;;
    esac
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
# Story files are OFF-LIMITS; this helper only accepts SPRINT_STATUS_YAML as
# the target. Runs the inner rewrite in a subshell so that die() inside
# rewrite_sprint_status_yaml (e.g., on read-only yaml) is caught as a
# non-zero return code instead of killing the whole reconcile.
write_sprint_status_yaml() {
  local target="$1" story_key="$2" new_status="$3"
  # Allowlist check — write boundary.
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

  # Exit-code contract:
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

# ---------- Subcommand: lint-dependencies ----------
#
# Read-only analysis of the selected sprint's story dependency graph.
# Detects forward-references (dependency inversions) where a story depends
# on a resource created by a later story in the sprint order.
#
# The AC text regex uses an 80-char co-occurrence window for trigger verb +
# target resource name matching. This bounds false positives from long-range
# coincidental matches while still catching same-sentence references.
#
# Read-only guarantee: lint-dependencies MUST NOT write to any file.
# It reads story files and sprint-status.yaml only. Safe for parallel CI
# pipelines and subagent invocation.
#
# Exit codes: 0 = clean, 2 = inversions detected (advisory), 1 = error.

# Extract the depends_on list from a story file's YAML frontmatter.
# Outputs one dependency key per line. Returns empty for missing or empty
# depends_on. Does not error on missing field.
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
# mentions without a trigger verb.
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
  # long-range coincidental matches.
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

  # Fast path: zero stories
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
  # stdout is being captured by a command substitution.
  local inversions lint_err_file
  lint_err_file="$(mktemp "${SPRINT_STATUS_YAML}.lint-err.XXXXXX" 2>/dev/null || mktemp)"
  # Register lint_err_file for script-level EXIT/INT/TERM cleanup.
  # Without this, interrupting lint-dependencies between mktemp and the
  # inline rm -f leaks an orphan *.lint-err.?????? file. Mirrors the
  # register-then-clear pattern used at all atomic-write mktemp call sites.
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

# ---------- Subcommand: record-escalation-override ----------
#
# Append an escalation-halt override entry to sprint-status.yaml under the
# `overrides:` block. Atomic under flock (same critical section discipline as
# transition). Idempotent on (sprint_id, sorted-unique(ids), override_type) —
# if an entry with the same override_type and the same sorted id set already
# exists, the call is a no-op (zero bytes written, exit 0).
#
# This is the ONLY path the sprint-plan skill uses to record
# escalation-halt overrides. The skill MUST NOT write overrides inline via
# yq or sed.
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
  # Register tmp for script-level EXIT/INT/TERM cleanup.
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
  # mv succeeded — clear the slot.
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

# ---------- Subcommand: detect-auto-close ----------
#
# Advisory detection — emits a single line of JSON on stdout when the active
# sprint has reached the auto-close-eligible condition:
#
#   top-level `status: active`
#   AND every story has `status: done`
#   AND total story count > 0   (vacuous "all done" guard)
#
# When the condition is met, stdout is exactly one line:
#
#   {"sprint_id":"<id>","done":<N>,"total":<N>,"status":"active","end_date":"<iso>"}
#
# Otherwise stdout is empty. Exit code is always 0 (advisory only, never
# blocking). end_date is rendered as "(unset)" if the field is missing.
#
# READ-ONLY: This subcommand NEVER opens sprint-status.yaml for write. The
# boundary write (flipping `status: closed` and seeding the next sprint)
# remains an operator-driven manual action — auto-flipping would create
# false confidence that the next sprint was scaffolded too.
cmd_detect_auto_close() {
  # Honor pre-exported SPRINT_STATUS_YAML; otherwise fall back to the same
  # canonical/fallback lookup used by sprint-status-dashboard.sh lines 54-64.
  local yaml_path="${SPRINT_STATUS_YAML:-}"
  if [ -z "$yaml_path" ]; then
    local canonical="${IMPLEMENTATION_ARTIFACTS}/sprint-status.yaml"
    local fallback="${PROJECT_PATH}/sprint-status.yaml"
    if [ -f "$canonical" ]; then
      yaml_path="$canonical"
    elif [ -f "$fallback" ]; then
      yaml_path="$fallback"
    else
      # Missing yaml: emit nothing, exit 0 (advisory).
      return 0
    fi
  fi
  [ -f "$yaml_path" ] || return 0

  # Helper: extract top-level YAML scalar (same convention as dashboard).
  # `|| true` swallows the grep-no-match-exit-1 + pipefail combination so a
  # missing top-level `status:` (or `end_date:`) reads as empty string rather
  # than tripping `set -e` and exiting non-zero from the whole script.
  local sprint_id end_date status
  sprint_id=$(grep '^sprint_id:' "$yaml_path" 2>/dev/null | head -1 | sed 's/^sprint_id:[[:space:]]*//' | tr -d '"' || true)
  end_date=$(grep '^end_date:' "$yaml_path" 2>/dev/null | head -1 | sed 's/^end_date:[[:space:]]*//' | tr -d '"' || true)
  status=$(grep '^status:' "$yaml_path" 2>/dev/null | head -1 | sed 's/^status:[[:space:]]*//' | tr -d '"' || true)

  # Fast-fail: not active → suppress output.
  [ "$status" = "active" ] || return 0

  # Walk stories[] using the same bash-regex parser pattern the dashboard
  # uses (lines 230-261). No yq / awk dependency. Counts story keys + their
  # status field; classifies done vs. non-done.
  local in_stories=false
  local total_count=0 done_count=0
  local s_key="" s_status=""

  # Inline story flush — accumulates one story's counters.
  # Named with _dac_ prefix so it never collides with the dashboard's
  # global flush_story() (different signature, same logical purpose).
  _dac_flush() {
    if [ -n "$s_key" ]; then
      total_count=$((total_count + 1))
      [ "$s_status" = "done" ] && done_count=$((done_count + 1))
    fi
    s_key=""; s_status=""
  }

  while IFS= read -r line; do
    if [[ "$line" =~ ^stories: ]]; then
      in_stories=true
      continue
    fi
    if [ "$in_stories" = true ]; then
      # A new top-level key (not indented) ends the stories block.
      if [[ "$line" =~ ^[a-z_] ]]; then
        in_stories=false
        _dac_flush
        continue
      fi
      if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*key:[[:space:]]* ]]; then
        _dac_flush
        s_key=$(printf '%s' "$line" | sed 's/.*key:[[:space:]]*//' | tr -d '"')
        continue
      fi
      if [[ "$line" =~ ^[[:space:]]+status:[[:space:]]* ]]; then
        s_status=$(printf '%s' "$line" | sed 's/.*status:[[:space:]]*//' | tr -d '"')
      fi
    fi
  done < "$yaml_path"
  # Flush final story
  if [ "$in_stories" = true ]; then
    _dac_flush
  fi

  # Vacuous "all done" guard — empty sprint MUST NOT trigger detection.
  [ "$total_count" -gt 0 ] || return 0
  # All stories must be done.
  [ "$done_count" -eq "$total_count" ] || return 0

  # Render end_date field — preserve "(unset)" when missing.
  local end_field="${end_date:-(unset)}"
  # Emit single-line JSON payload.
  printf '{"sprint_id":"%s","done":%d,"total":%d,"status":"active","end_date":"%s"}\n' \
    "$sprint_id" "$done_count" "$total_count" "$end_field"
  return 0
}

# ---------- Subcommand: rollover ----------
#
# Migrate one or more stories from sprint-N to sprint-M. Per-story atomic
# (story-file flock); whole-batch best-effort with partial-failure semantics
# (some keys committed + some rolled back, non-zero exit + summary).
#
# Per-key flow:
#   1. Locate story file via scan of .gaia/artifacts/implementation-artifacts/**/stories/*.md
#   2. Read frontmatter `sprint_id` field
#   3. Verify it matches --from value OR is `null`. Otherwise refuse this key.
#   4. Rewrite `sprint_id:` line to the --to value.
#   5. Call cmd_inject to register the story in the target sprint yaml.
#   6. On any step failure within steps 4-5, roll back the story-file
#      `sprint_id` to its original value before releasing the lock.
cmd_rollover() {
  local from_sprint="$1" to_sprint="$2" keys_raw="$3"
  [ -n "$from_sprint" ] || die "rollover requires --from <sprint-id>"
  [ -n "$to_sprint" ] || die "rollover requires --to <sprint-id>"
  [ -n "$keys_raw" ] || die "rollover requires --keys <key1,key2,...>"

  # Split comma-separated keys.
  local OLDIFS="$IFS"
  IFS=','
  set -f
  # shellcheck disable=SC2206
  local keys=( $keys_raw )
  set +f
  IFS="$OLDIFS"

  local succeeded=() failed=()
  local key
  for key in "${keys[@]}"; do
    key="${key# }"; key="${key% }"  # trim
    [ -n "$key" ] || continue
    if _rollover_one "$key" "$from_sprint" "$to_sprint"; then
      succeeded+=("$key")
    else
      failed+=("$key")
    fi
  done

  printf 'sprint-state.sh rollover: from=%s to=%s\n' "$from_sprint" "$to_sprint" >&2
  printf 'sprint-state.sh rollover: succeeded: %s\n' "${succeeded[*]:-(none)}" >&2
  printf 'sprint-state.sh rollover: failed:    %s\n' "${failed[*]:-(none)}" >&2

  if [ "${#failed[@]}" -gt 0 ]; then
    return 1
  fi
  return 0
}

# Internal: process one story key. Returns 0 on success, non-zero on refusal
# or write failure (caller logs failure and continues to next key).
_rollover_one() {
  local key="$1" from_sprint="$2" to_sprint="$3"

  # Locate the story file. Pattern: .gaia/artifacts/implementation-artifacts/**/stories/<key>-*.md
  local story_file
  story_file=$(find "${IMPLEMENTATION_ARTIFACTS}" -type f -name "${key}-*.md" 2>/dev/null | head -1)
  if [ -z "$story_file" ] || [ ! -f "$story_file" ]; then
    printf 'sprint-state.sh rollover: story file not found for %s\n' "$key" >&2
    return 1
  fi

  # Read current sprint_id from frontmatter.
  local current_sid
  current_sid=$(grep '^sprint_id:' "$story_file" | head -1 | sed 's/^sprint_id:[[:space:]]*//' | tr -d '"')
  # Empty after stripping quotes -> empty literal. `null` -> the YAML null.
  local accept=0
  if [ "$current_sid" = "$from_sprint" ]; then
    accept=1
  elif [ "$current_sid" = "null" ] || [ -z "$current_sid" ]; then
    accept=1
  fi
  if [ "$accept" -eq 0 ]; then
    printf 'sprint-state.sh rollover: %s sprint_id=%s does not match --from %s and is not null; refusing\n' \
      "$key" "$current_sid" "$from_sprint" >&2
    return 1
  fi

  # Per-story flock. Reuse the same .lock suffix pattern as transition.
  local lock_file="${story_file}.rollover.lock"
  local flock_bin
  flock_bin=$(command -v flock || true)

  _rollover_with_lock() {
    # Rewrite sprint_id in-place. Two cases:
    #   1. sprint_id: "<from>"  -> sprint_id: "<to>"
    #   2. sprint_id: null      -> sprint_id: "<to>"
    # Use a sibling tempfile + mv for atomicity.
    local tmp
    tmp=$(mktemp "${story_file}.XXXXXX") || return 1
    # Match either quoted "from" or null literal.
    awk -v from="$from_sprint" -v to="$to_sprint" '
      /^sprint_id:/ {
        # Normalize all matching forms to: sprint_id: "<to>"
        if ($0 ~ ("^sprint_id:[[:space:]]*\"" from "\"") || $0 ~ /^sprint_id:[[:space:]]*null[[:space:]]*$/) {
          print "sprint_id: \"" to "\""
          next
        }
      }
      { print }
    ' "$story_file" > "$tmp" || { rm -f "$tmp"; return 1; }

    # Sanity: confirm the rewrite happened (we should see the to value now).
    if ! grep -q "^sprint_id:[[:space:]]*\"$to_sprint\"" "$tmp"; then
      rm -f "$tmp"
      return 1
    fi

    # Snapshot the original for rollback.
    local backup
    backup=$(mktemp "${story_file}.rollback-XXXXXX") || { rm -f "$tmp"; return 1; }
    cp "$story_file" "$backup"

    # Commit the rewrite.
    if ! mv -f "$tmp" "$story_file"; then
      rm -f "$tmp" "$backup"
      return 1
    fi

    # Now inject the story into the target sprint yaml.
    if ! cmd_inject "$key" "" >/dev/null 2>&1; then
      # Rollback the story file.
      mv -f "$backup" "$story_file" 2>/dev/null || true
      rm -f "$backup"
      return 1
    fi

    rm -f "$backup"
    return 0
  }

  local rc=0
  if [ -n "$flock_bin" ]; then
    (
      exec 9>"$lock_file"
      if ! "$flock_bin" -x -w 5 9; then
        die "flock timeout acquiring $lock_file"
      fi
      _rollover_with_lock
    )
    rc=$?
  else
    _rollover_with_lock
    rc=$?
  fi

  rm -f "$lock_file"
  return $rc
}

# ============================================================
# Sprint goals + sprint-level state machine
# ============================================================

# Resolve the path of the active sprint yaml. Caller has already called
# resolve_paths(). We honor SPRINT_STATUS_YAML if pre-set; else default to
# ${IMPLEMENTATION_ARTIFACTS}/sprint-status.yaml. Read-only — does not write.
_resolve_active_yaml() {
  if [ -n "${SPRINT_STATUS_YAML:-}" ]; then
    # resolve_paths() is the single source of truth for this value — it applies
    # the canonical-state-tier resolution order (.gaia/state/ first,
    # impl-artifacts read-compat, fresh writes → state).
    printf '%s' "$SPRINT_STATUS_YAML"
  else
    # Safety net for callers that invoke this without resolve_paths() first.
    printf '%s/.gaia/state/sprint-status.yaml' "${PROJECT_PATH:-.}"
  fi
}

# cmd_init — bootstrap a sprint-status.yaml when none exists yet.
# Seeds the canonical shape (sprint id/state/total_points=0/items=[]/goals=[]),
# under flock to remain consistent with all other writers, and is
# idempotent: re-init against an existing yaml is rejected.
cmd_init() {
  local sprint_id="$1"
  [ -n "$sprint_id" ] || die "init: --sprint-id is required"
  # Optional `--start-date`, `--end-date`, `--capacity-points` flags.
  # When any of these flags is provided, the seed includes the field. When
  # all three are absent the seed carries only the minimal shape (sprint_id /
  # status / total_points / goals / items). The end-date can also be derived
  # from start + length.
  local start_date="" end_date="" capacity_points="" sprint_length=""
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --start-date)      start_date="${2:-}"; shift 2 ;;
      --end-date)        end_date="${2:-}"; shift 2 ;;
      --capacity-points) capacity_points="${2:-}"; shift 2 ;;
      --sprint-length-days) sprint_length="${2:-}"; shift 2 ;;
      *) die "init: unknown flag: $1" ;;
    esac
  done
  local yaml
  yaml="$(_resolve_active_yaml)"
  if [ -e "$yaml" ]; then
    # After /gaia-sprint-close the live yaml persists with `status: closed`
    # (the close ceremony archives a COPY, it does not remove the live file).
    # The next sprint's `init` previously hard-refused on that residual,
    # forcing a manual `rm sprint-status.yaml` between sprints. A CLOSED
    # predecessor is a sanctioned hand-off point: re-seed over it (the closed
    # state is already preserved in sprint-archive/). Any OTHER existing status
    # (planned/active/review) is still refused — overwriting a live sprint
    # would lose in-flight state.
    local existing_status
    existing_status="$(_yaml_sprint_status "$yaml" 2>/dev/null || true)"
    if [ "$existing_status" = "closed" ]; then
      printf '%s: init: re-seeding over closed predecessor sprint (%s, status=closed) — prior state preserved in sprint-archive/\n' \
        "$SCRIPT_NAME" "$yaml" >&2
    else
      die "init: $yaml already exists (status=${existing_status:-unknown}) — refusing to overwrite a non-closed sprint (close it first via /gaia-sprint-close)"
    fi
  fi
  mkdir -p "$(dirname "$yaml")"
  # No flock here: the init path is the FIRST writer (it refuses to overwrite
  # an existing yaml), so there is no concurrent reader/writer to coordinate
  # with. Subsequent writes route through transition/inject/set-goals which
  # already acquire the canonical sprint-status.yaml.lock under flock.
  local tmp
  tmp="$(mktemp "${yaml}.XXXXXX")"
  # Derive end_date from start + length when end-date wasn't passed but length was.
  if [ -n "$start_date" ] && [ -z "$end_date" ] && [ -n "$sprint_length" ]; then
    # Try gnu-date first (Linux), fall back to BSD-date (macOS).
    end_date="$(date -u -d "$start_date + $sprint_length days" +%Y-%m-%d 2>/dev/null || \
                date -u -j -f '%Y-%m-%d' -v +"${sprint_length}d" "$start_date" +%Y-%m-%d 2>/dev/null || \
                printf '')"
  fi
  # Seed the canonical top-level `status:` field. A fresh sprint starts in the
  # `planned` state (planned → active → review → closed). The `status: planned`
  # seed is what makes the sprint transitionable (a status:-less seed could not
  # be transitioned at all).
  {
    printf 'sprint_id: "%s"\n' "$sprint_id"
    printf 'status: planned\n'
    [ -n "$start_date" ]      && printf 'start_date: "%s"\n' "$start_date"
    [ -n "$end_date" ]        && printf 'end_date: "%s"\n' "$end_date"
    [ -n "$capacity_points" ] && printf 'capacity_points: %s\n' "$capacity_points"
    printf 'total_points: 0\n'
    printf 'goals: []\n'
    printf 'items: []\n'
  } > "$tmp"
  mv "$tmp" "$yaml"
  printf 'init: seeded %s for sprint %s\n' "$yaml" "$sprint_id"

  # Emit a sprint-plan/{id}-plan.md stub so the documented sprint-plan layout
  # is non-empty even when the operator drove sprint commit via direct
  # `sprint-state.sh init`/`inject` rather than the /gaia-sprint-plan SKILL
  # Step 7 LLM-write path. The stub carries the canonical frontmatter + a
  # planning-intent body the LLM authoring path can overwrite with the richer
  # narrative on the next /gaia-sprint-plan invocation. Idempotent: skip when
  # the file already exists (preserves any LLM-enrichment work done already).
  _plan_dir="${IMPLEMENTATION_ARTIFACTS:-${PROJECT_ROOT:-.}/.gaia/artifacts/implementation-artifacts}/sprint-plan"
  _plan_file="${_plan_dir}/${sprint_id}-plan.md"
  if [ ! -e "$_plan_file" ]; then
    mkdir -p "$_plan_dir" 2>/dev/null || true
    {
      printf -- '---\n'
      printf 'artifact_type: sprint-plan\n'
      printf 'sprint_id: "%s"\n' "$sprint_id"
      printf 'generated_by: sprint-state.sh init\n'
      printf 'generated_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      [ -n "$start_date" ]      && printf 'start_date: "%s"\n' "$start_date"
      [ -n "$end_date" ]        && printf 'end_date: "%s"\n' "$end_date"
      [ -n "$capacity_points" ] && printf 'capacity_points: %s\n' "$capacity_points"
      printf -- '---\n\n'
      printf '# Sprint plan: %s\n\n' "$sprint_id"
      printf 'This stub was emitted by `sprint-state.sh init` so the sprint-plan/\n'
      printf 'directory has a non-empty entry per the canonical layout. The\n'
      printf '`/gaia-sprint-plan` SKILL.md Step 7 LLM-write path enriches this\n'
      printf 'file with the goals, selected stories, dependency notes, and\n'
      printf 'capacity calculation on the next invocation.\n\n'
      printf '## Goals\n\n_(populated by /gaia-sprint-plan Step 4)_\n\n'
      printf '## Selected stories\n\n_(populated by /gaia-sprint-plan Step 5)_\n\n'
      printf '## Notes\n\n_(populated by /gaia-sprint-plan Step 6)_\n'
    } > "$_plan_file" 2>/dev/null || true
    printf 'init: emitted sprint-plan stub at %s\n' "$_plan_file" >&2
  fi
}

# cmd_get_goals — read goals[] from sprint-status.yaml and emit verbatim.
# Backward-compatible: missing goals: key → empty stdout, exit 0.
cmd_get_goals() {
  local sprint_id="$1"
  local yaml
  yaml="$(_resolve_active_yaml)"
  [ -r "$yaml" ] || die "get-goals: yaml not readable: $yaml"
  # Parse the top-level goals: list. Line-based extraction (no yaml lib).
  awk '
    /^goals:[[:space:]]*$/ { in_goals=1; next }
    in_goals && /^[[:space:]]*-[[:space:]]/ {
      # Strip leading "  - ", optional surrounding quotes
      sub(/^[[:space:]]*-[[:space:]]*/, "", $0)
      sub(/^"/, "", $0); sub(/"$/, "", $0)
      sub(/^'\''/, "", $0); sub(/'\''$/, "", $0)
      print
      next
    }
    in_goals && /^[^[:space:]]/ { in_goals=0 }
  ' "$yaml"
}

# cmd_set_goals — REPLACE the goals: list with pipe-delimited goals.
# Each goal is capped at 280 chars.
cmd_set_goals() {
  local sprint_id="$1" goals_str="$2"
  local yaml
  yaml="$(_resolve_active_yaml)"
  [ -r "$yaml" ] || die "set-goals: yaml not readable: $yaml"
  [ -n "$goals_str" ] || die "set-goals: --goals must be non-empty (pipe-delimited)"
  # Validate each goal: 1..280 chars
  local IFS='|'
  local g
  for g in $goals_str; do
    local len="${#g}"
    if [ "$len" -lt 1 ] || [ "$len" -gt 280 ]; then
      die "set-goals: goal length $len exceeds 280-char limit: $g"
    fi
  done
  IFS=$' \t\n'
  # Build the new goals: block
  local new_block
  new_block="goals:"$'\n'
  IFS='|'
  for g in $goals_str; do
    # Escape internal double quotes by switching to single-quoted literal
    new_block+="  - \"${g//\"/\\\"}\""$'\n'
  done
  IFS=$' \t\n'
  # Replace or insert goals: block. Use python for surgical line-based edit
  # (preserves comments + non-goals fields byte-for-byte).
  python3 - "$yaml" "$new_block" <<'PY'
import sys, re
yaml_path = sys.argv[1]
new_block = sys.argv[2]
text = open(yaml_path).read()
# Find existing goals: block (lines starting with `goals:` followed by
# `  - ...` items, until next top-level key)
lines = text.splitlines(keepends=True)
out = []
i = 0
replaced = False
while i < len(lines):
    line = lines[i]
    # Also match the empty-list seed form `goals: []`. The match accepts
    # either an empty-list inline form OR an end-of-line form followed by
    # indented `- ...` items.
    if not replaced and re.match(r'^goals:\s*(\[\s*\]\s*)?$', line):
        # Skip the existing block: the goals: line + every following `  - ...` line
        i += 1
        while i < len(lines) and re.match(r'^\s*-\s', lines[i]):
            i += 1
        # Insert new block
        out.append(new_block)
        replaced = True
        continue
    out.append(line)
    i += 1
if not replaced:
    # No existing goals: key. Insert before stories: if present, else append.
    new_out = []
    inserted = False
    for line in out:
        if not inserted and re.match(r'^stories:\s*$', line):
            new_out.append(new_block)
            inserted = True
        new_out.append(line)
    if not inserted:
        new_out.append(new_block)
    out = new_out
with open(yaml_path, 'w') as f:
    f.write(''.join(out))
PY
}

# cmd_update_goals — alias for set-goals (REPLACES, does not append).
cmd_update_goals() {
  cmd_set_goals "$@"
}

# cmd_set_shape — Set the optional `sprint_shape:` field on sprint-status.yaml.
# Enum values: `thrust` (default; not normally written — absence implies thrust)
# or `completion-pass`. Used by the rubric evaluator to scale the
# incidental-goal floor.
cmd_set_shape() {
  local sprint_id="$1" shape="$2"
  local yaml
  yaml="$(_resolve_active_yaml)"
  [ -r "$yaml" ] || die "set-shape: yaml not readable: $yaml"
  case "$shape" in
    thrust|completion-pass) ;;
    *) die "sprint_shape must be one of: thrust, completion-pass — got: $shape" ;;
  esac
  # Boundary-write pattern: write to a sibling tempfile, then mv into place
  # atomically. Closes the crash-safety gap on direct truncate+write.
  local tmp
  tmp=$(mktemp "${yaml}.tmp.XXXXXX")
  python3 - "$yaml" "$tmp" "$shape" <<'PY'
import sys, re
yaml_path = sys.argv[1]
tmp_path = sys.argv[2]
shape = sys.argv[3]
text = open(yaml_path).read()
new_line = f"sprint_shape: {shape}\n"
lines = text.splitlines(keepends=True)
out = []
i = 0
replaced = False
while i < len(lines):
    line = lines[i]
    if not replaced and re.match(r'^sprint_shape:\s', line):
        out.append(new_line)
        replaced = True
        i += 1
        continue
    out.append(line)
    i += 1
if not replaced:
    new_out = []
    inserted = False
    for line in out:
        if not inserted and re.match(r'^stories:\s*$', line):
            new_out.append(new_line)
            inserted = True
        new_out.append(line)
    if not inserted:
        new_out.append(new_line)
    out = new_out
with open(tmp_path, 'w') as f:
    f.write(''.join(out))
PY
  mv -f "$tmp" "$yaml"
}

# Helper: read top-level `status:` from the active-sprint yaml.
_yaml_sprint_status() {
  local yaml="$1"
  # Strip leading `status:` prefix, trailing whitespace, AND surrounding
  # double/single quotes — quoted YAML values like `status: "active"` must
  # return `active`, not `"active"`, to avoid silent case-match failures.
  awk '/^status:[[:space:]]*/ {
    sub(/^status:[[:space:]]*/, "");
    sub(/[[:space:]]+$/, "");
    gsub(/^["'\'']|["'\'']$/, "");
    print; exit
  }' "$yaml"
}

# Helper: check whether ALL stories in the yaml have status: done.
_yaml_all_stories_done() {
  local yaml="$1"
  # List all story statuses under stories:; non-done ones short-circuit.
  awk '
    /^stories:[[:space:]]*$/ { in_stories=1; next }
    in_stories && /^[[:space:]]+status:[[:space:]]*/ {
      sub(/^[[:space:]]+status:[[:space:]]*/, "")
      gsub(/"/, ""); gsub(/[[:space:]]+$/, "")
      print
    }
    in_stories && /^[^[:space:]]/ { in_stories=0 }
  ' "$yaml"
}

# cmd_transition_sprint — sprint-level state-machine transitions. Edges:
#   active → review        (gated on all-stories-done)
#   review → closed
#   review → correction
#   correction → active
# Any other edge refuses.
cmd_transition_sprint() {
  local sprint_id="$1" target="$2"
  local yaml
  yaml="$(_resolve_active_yaml)"
  [ -r "$yaml" ] || die "transition --sprint: yaml not readable: $yaml"
  local current
  current="$(_yaml_sprint_status "$yaml")"
  [ -n "$current" ] || die "transition --sprint: cannot read current status from $yaml"

  # Validate edge. Edges: planned → active → review → closed; the
  # planned → active edge is unconditional here.
  local legal=0
  case "${current}→${target}" in
    "planned→active"|"active→review"|"review→closed"|"review→correction"|"correction→active")
      legal=1 ;;
  esac
  if [ "$legal" -ne 1 ]; then
    printf '%s: illegal sprint-level transition: %s→%s\n' "$SCRIPT_NAME" "$current" "$target" >&2
    return 1
  fi

  # Gate: review → closed requires a Val sentinel proving /gaia-sprint-review ran.
  # Closing a `review`-status sprint MUST verify the sprint-review Val sentinel
  # (either the dispatch sentinel `sprint-review-{id}-val-dispatched.json` OR
  # the envelope sentinel `val-envelope-<sha>.json` keyed off the sprint id),
  # and REFUSE with "run /gaia-sprint-review first" on a missing sentinel.
  # This check is folded into the transition primitive so any caller is refused
  # uniformly. Escape hatch: `GAIA_ALLOW_SPRINT_REVIEW_TO_CLOSED_WITHOUT_SENTINEL=1`
  # for the documented /gaia-correct-course bypass.
  if [ "$current" = "review" ] && [ "$target" = "closed" ] \
     && [ "${GAIA_ALLOW_SPRINT_REVIEW_TO_CLOSED_WITHOUT_SENTINEL:-0}" != "1" ]; then
    local _ckpt_dir="${CLAUDE_PROJECT_ROOT:-.}/.gaia/memory/checkpoints"
    local _dispatch_sentinel="${_ckpt_dir}/sprint-review-${sprint_id}-val-dispatched.json"
    local _envelope_glob="${_ckpt_dir}/val-envelope-*.json"
    local _found=0
    if [ -f "$_dispatch_sentinel" ]; then
      _found=1
    else
      # E87 envelope sentinel: any val-envelope-<hash>.json whose
      # artifact_path matches the sprint id satisfies the gate.
      for _env in $_envelope_glob; do
        [ -f "$_env" ] || continue
        if grep -F "\"artifact_path\":\"${sprint_id}\"" "$_env" >/dev/null 2>&1; then
          _found=1
          break
        fi
      done
    fi
    if [ "$_found" -ne 1 ]; then
      printf '%s: refuse review→closed for sprint %s: no Val sentinel at %s (run /gaia-sprint-review first, OR set GAIA_ALLOW_SPRINT_REVIEW_TO_CLOSED_WITHOUT_SENTINEL=1 for the documented bypass)\n' \
        "$SCRIPT_NAME" "$sprint_id" "$_dispatch_sentinel" >&2
      return 1
    fi
  fi

  # Gate: active → review requires ALL stories done
  if [ "$current" = "active" ] && [ "$target" = "review" ]; then
    local non_done_keys=""
    local non_done_count=0
    # Read story keys + statuses
    while IFS='|' read -r k s; do
      [ -n "$k" ] || continue
      if [ "$s" != "done" ]; then
        non_done_keys+="${non_done_keys:+, }${k}"
        non_done_count=$((non_done_count + 1))
      fi
    done < <(awk '
      /^stories:[[:space:]]*$/ { in_stories=1; next }
      in_stories && /^[[:space:]]+-[[:space:]]+key:[[:space:]]*/ {
        sub(/^[[:space:]]+-[[:space:]]+key:[[:space:]]*/, "")
        gsub(/"/, "")
        cur_key=$0
        next
      }
      in_stories && /^[[:space:]]+status:[[:space:]]*/ {
        sub(/^[[:space:]]+status:[[:space:]]*/, "")
        gsub(/"/, "")
        printf "%s|%s\n", cur_key, $0
        next
      }
      in_stories && /^[^[:space:]]/ { in_stories=0 }
    ' "$yaml")
    if [ "$non_done_count" -gt 0 ]; then
      printf '%s: refuse active→review: %d sprint stories are non-done (%s)\n' \
        "$SCRIPT_NAME" "$non_done_count" "$non_done_keys" >&2
      return 1
    fi
  fi

  # Write new status — atomic rewrite via mktemp → awk → mv. Register in
  # _GAIA_TMP_PATHS for trap-based cleanup; fallback to mktemp -t when the
  # sibling template is rejected on stricter GNU mktemp implementations.
  local tmp
  tmp=$(mktemp "${yaml}.tmp.XXXXXX" 2>/dev/null || mktemp -t sprint-state-yaml.XXXXXX)
  _GAIA_TMP_PATHS+=("$tmp")
  local _tmp_idx
  _tmp_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  awk -v new="$target" '
    !done_replace && /^status:[[:space:]]*/ {
      print "status: " new
      done_replace=1
      next
    }
    { print }
  ' "$yaml" > "$tmp"
  mv "$tmp" "$yaml"
  _GAIA_TMP_PATHS[$_tmp_idx]=""

  # Emit a sprint-level lifecycle event directly via lifecycle-event.sh.
  # The emit_lifecycle_event() helper is story-scoped — sprint-level
  # transitions need a different payload shape so we call the helper directly.
  local lifecycle_sh="${SPRINT_STATE_SCRIPT_DIR}/lifecycle-event.sh"
  if [ -x "$lifecycle_sh" ]; then
    local data
    data=$(printf '{"sprint_id":"%s","from":"%s","to":"%s"}' "$sprint_id" "$current" "$target")
    "$lifecycle_sh" \
      --type sprint_transitioned \
      --workflow sprint-state \
      --story "$sprint_id" \
      --data "$data" >/dev/null 2>&1 || true
  fi
}

# cmd_set_review_justification — write review_justification: block from
# a yaml payload file.
cmd_set_review_justification() {
  local sprint_id="$1" file="$2"
  local yaml
  yaml="$(_resolve_active_yaml)"
  [ -r "$yaml" ] || die "set-review-justification: yaml not readable: $yaml"
  [ -r "$file" ] || die "set-review-justification: payload file not readable: $file"

  # Schema validation via python (single deterministic pass).
  python3 - "$file" <<'PY'
import sys, re
path = sys.argv[1]
text = open(path).read()
required = {
    'primary_criterion': r'^primary_criterion:\s*(C1|C2|C3)\s*$',
    'qualifying_story_points': r'^qualifying_story_points:\s*\d+\s*$',
    'total_story_points': r'^total_story_points:\s*\d+\s*$',
    'qualifying_ratio': r'^qualifying_ratio:\s*0\.[8-9]\d*|^qualifying_ratio:\s*1(\.0+)?\s*$',
    'explanation': r'^explanation:\s*',
}
for k, pat in required.items():
    if not re.search(pat, text, re.MULTILINE):
        sys.stderr.write(f'set-review-justification: schema violation — missing or invalid {k}\n')
        sys.exit(1)
# Explanation length 200-1000 chars (heuristic: block-scalar body)
m = re.search(r'explanation:\s*\|?\s*\n((?:\s+.+\n)+)', text)
if m:
    body = ''.join(l.lstrip() for l in m.group(1).splitlines() if l.strip())
    if len(body) < 200 or len(body) > 1000:
        sys.stderr.write(f'set-review-justification: schema violation — explanation length {len(body)} not in [200, 1000]\n')
        sys.exit(1)
sys.exit(0)
PY
  [ $? -eq 0 ] || return 1

  # Append the review_justification block to the yaml (line-based)
  python3 - "$yaml" "$file" <<'PY'
import sys, re
yaml_path, payload_path = sys.argv[1], sys.argv[2]
payload = open(payload_path).read().rstrip() + '\n'
text = open(yaml_path).read()
# Strip any existing review_justification: block
lines = text.splitlines(keepends=True)
out = []
i = 0
while i < len(lines):
    if re.match(r'^review_justification:', lines[i]):
        i += 1
        while i < len(lines) and re.match(r'^\s', lines[i]):
            i += 1
        continue
    out.append(lines[i])
    i += 1
# Append new block, ensure trailing newline
if out and not out[-1].endswith('\n'):
    out.append('\n')
out.append('review_justification:\n')
for line in payload.splitlines(keepends=True):
    out.append('  ' + line if line.strip() else line)
with open(yaml_path, 'w') as f:
    f.write(''.join(out))
PY
}

# ============================================================
# set-story-sprint
# ============================================================
#
# Bind a pre-materialized backlog story's `sprint_id:` to a target sprint
# when the story file frontmatter currently carries `sprint_id: null`.
#
# A story materialized via plain `/gaia-create-story` (not `--for-sprint`)
# lands with `sprint_id: null`. The subsequent `sprint-state.sh inject` then
# refuses with `sprint-id mismatch ... refusing to write` because no listed
# verb binds sprint_id without going through the `--for-sprint` path. This
# verb is the sanctioned binder: it rewrites ONLY the `sprint_id:` line in
# the story file's frontmatter (null → "<sprint>"), atomically (mktemp + mv),
# under a per-story flock.
#
# Refuses (exit 1):
#   - story file's current sprint_id is already a non-null value that
#     disagrees with the requested target (operator must explicitly
#     `sprint-state.sh rollover` between sprints).
#   - target sprint does not match the active sprint-status.yaml
#     sprint_id (we will not bind a story to an inactive sprint).
#
# Idempotent — re-running with a story already bound to the target sprint
# is a no-op (exit 0).
#
# Leading-underscore name marks this as an internal helper.
_cmd_set_story_sprint() {
  local story_key="$1" target_sprint="$2"
  [ -n "$story_key" ] || die "set-story-sprint: --story is required"
  [ -n "$target_sprint" ] || die "set-story-sprint: --sprint is required"

  # Resolve the story file via the standard locator.
  locate_story_file "$story_key"
  [ -n "$STORY_FILE" ] && [ -f "$STORY_FILE" ] \
    || die "set-story-sprint: no story file found for key '$story_key'"

  # Verify target sprint matches the active sprint-status.yaml sprint_id.
  # We will not bind to an inactive or absent sprint.
  local yaml_sid
  yaml_sid=$(read_yaml_sprint_id "$SPRINT_STATUS_YAML" 2>/dev/null || true)
  if [ -z "$yaml_sid" ]; then
    die "set-story-sprint: sprint-status.yaml at $SPRINT_STATUS_YAML missing top-level sprint_id — run 'sprint-state.sh init --sprint-id $target_sprint' first"
  fi
  if [ "$yaml_sid" != "$target_sprint" ]; then
    die "set-story-sprint: target sprint '$target_sprint' does not match active sprint-status.yaml sprint_id '$yaml_sid'; refusing to bind"
  fi

  # Read current frontmatter sprint_id.
  local current_sid
  current_sid=$(read_story_frontmatter_field "$STORY_FILE" sprint_id 2>/dev/null || true)

  # Idempotency: already bound to the right sprint.
  if [ "$current_sid" = "$target_sprint" ]; then
    printf '%s: %s already bound to sprint %s — no-op\n' \
      "$SCRIPT_NAME" "$story_key" "$target_sprint"
    return 0
  fi

  # Safety: refuse to silently retarget a story bound to a different sprint.
  # The `rollover` verb is the sanctioned cross-sprint mover.
  case "$current_sid" in
    ""|"null")
      : ;; # bindable
    *)
      die "set-story-sprint: $story_key already bound to sprint '$current_sid'; use 'sprint-state.sh rollover --from $current_sid --keys $story_key' to move between sprints"
      ;;
  esac

  # Acquire a per-story flock and rewrite ONLY the sprint_id: line.
  local lock_file="${STORY_FILE}.set-sprint.lock"
  local flock_bin
  flock_bin=$(command -v flock || true)

  _rewrite_sprint_id() {
    local tmp
    tmp=$(mktemp "${STORY_FILE}.XXXXXX") || return 1
    awk -v to="$target_sprint" '
      BEGIN { in_fm = 0; rewritten = 0 }
      /^---[[:space:]]*$/ {
        if (in_fm == 0) { in_fm = 1; print; next }
        else { in_fm = 2; print; next }
      }
      {
        if (in_fm == 1 && rewritten == 0 && $0 ~ /^sprint_id:[[:space:]]*(null|"")?[[:space:]]*$/) {
          print "sprint_id: \"" to "\""
          rewritten = 1
          next
        }
        print
      }
    ' "$STORY_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }

    # Sanity check: confirm rewrite landed.
    if ! grep -q "^sprint_id:[[:space:]]*\"$target_sprint\"" "$tmp"; then
      rm -f "$tmp"
      return 1
    fi

    mv -f "$tmp" "$STORY_FILE" || { rm -f "$tmp"; return 1; }
    return 0
  }

  local rc=0
  if [ -n "$flock_bin" ]; then
    (
      exec 9>"$lock_file"
      if ! "$flock_bin" -x -w 5 9; then
        die "flock timeout acquiring $lock_file"
      fi
      _rewrite_sprint_id
    )
    rc=$?
  else
    _rewrite_sprint_id
    rc=$?
  fi

  rm -f "$lock_file"
  if [ "$rc" -ne 0 ]; then
    die "set-story-sprint: failed to rewrite sprint_id in $STORY_FILE"
  fi

  printf '%s: %s sprint_id bound to %s\n' \
    "$SCRIPT_NAME" "$story_key" "$target_sprint"
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
    init|transition|inject|get|validate|reconcile|lint-dependencies|record-escalation-override|detect-auto-close|rollover|get-goals|set-goals|update-goals|set-review-justification|set-shape|set-story-sprint)
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
  local rollover_from="" rollover_keys=""
  # Sprint-level subcommands (get-goals / set-goals / update-goals /
  # set-review-justification + transition --sprint).
  # set-shape subcommand for sprint_shape modifier (thrust | completion-pass).
  local goals_arg="" justification_file="" shape_arg=""
  # Optional init-only fields.
  local init_start_date="" init_end_date="" init_capacity_points="" init_sprint_length=""
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
      --from)
        [ $# -ge 2 ] || die "--from requires a value"
        rollover_from="$2"; shift 2 ;;
      --from=*)
        rollover_from="${1#--from=}"; shift ;;
      --keys)
        [ $# -ge 2 ] || die "--keys requires a value"
        rollover_keys="$2"; shift 2 ;;
      --keys=*)
        rollover_keys="${1#--keys=}"; shift ;;
      --sprint)
        # --sprint is an alias for --sprint-id on sprint-level subcommands
        # (get-goals / set-goals / update-goals / set-review-justification /
        # transition --sprint).
        [ $# -ge 2 ] || die "--sprint requires a value"
        reconcile_sprint_id="$2"; shift 2 ;;
      --sprint=*)
        reconcile_sprint_id="${1#--sprint=}"; shift ;;
      --goals)
        # Pipe-delimited goal list for set-goals / update-goals.
        [ $# -ge 2 ] || die "--goals requires a value"
        goals_arg="$2"; shift 2 ;;
      --goals=*)
        goals_arg="${1#--goals=}"; shift ;;
      --file)
        # Review-justification yaml payload path for set-review-justification.
        [ $# -ge 2 ] || die "--file requires a value"
        justification_file="$2"; shift 2 ;;
      --file=*)
        justification_file="${1#--file=}"; shift ;;
      --shape)
        # sprint_shape enum value for set-shape (thrust | completion-pass).
        [ $# -ge 2 ] || die "--shape requires a value"
        shape_arg="$2"; shift 2 ;;
      --shape=*)
        shape_arg="${1#--shape=}"; shift ;;
      --start-date)
        # Optional sprint metadata.
        [ $# -ge 2 ] || die "--start-date requires a value"
        init_start_date="$2"; shift 2 ;;
      --start-date=*)
        init_start_date="${1#--start-date=}"; shift ;;
      --end-date)
        [ $# -ge 2 ] || die "--end-date requires a value"
        init_end_date="$2"; shift 2 ;;
      --end-date=*)
        init_end_date="${1#--end-date=}"; shift ;;
      --capacity-points)
        [ $# -ge 2 ] || die "--capacity-points requires a value"
        init_capacity_points="$2"; shift 2 ;;
      --capacity-points=*)
        init_capacity_points="${1#--capacity-points=}"; shift ;;
      --sprint-length-days)
        [ $# -ge 2 ] || die "--sprint-length-days requires a value"
        init_sprint_length="$2"; shift 2 ;;
      --sprint-length-days=*)
        init_sprint_length="${1#--sprint-length-days=}"; shift ;;
      --help|-h)
        usage
        exit 0 ;;
      --points|--points=*)
        # --points is a common-but-wrong attempt. Emit a helpful redirect
        # instead of the bare "unknown flag" rejection. total_points is
        # accumulated from the injected story's frontmatter `points:` field.
        die "--points is not a valid flag for inject. total_points is accumulated from the injected story's frontmatter points: field. See --help for the inject contract." ;;
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

  # ---------- Startup orphan-tmp sweep ----------
  #
  # Garbage-collect *.tmp.?????? files older than 60 minutes under
  # ${IMPLEMENTATION_ARTIFACTS}. Catches orphans left by kill -9 / OOM /
  # power loss (which bypass the EXIT/INT/TERM trap). Bounded to the
  # allowlist (sprint-status.yaml directory). Never /tmp, never $HOME, never
  # ${PROJECT_PATH} root. Set GAIA_SKIP_ORPHAN_SWEEP=1 to disable.
  # Errors swallowed; zero stdout (silent GC).
  if [ "${GAIA_SKIP_ORPHAN_SWEEP:-0}" != "1" ]; then
    find "${IMPLEMENTATION_ARTIFACTS}" \
      -maxdepth 2 -name '*.tmp.??????' -mmin +60 -delete 2>/dev/null || true
  fi

  case "$subcmd" in
    init)
      # Bootstrap a fresh sprint-status.yaml.
      [ -n "$reconcile_sprint_id" ] || die "init requires --sprint-id <id>"
      # Forward optional date / capacity / length flags only when non-empty,
      # so the minimal seed shape is preserved on zero-flag invocations.
      # Branch on array length: bash 3.2 + `set -u` rejects an empty-array
      # expansion, so the empty case calls cmd_init without trailing args.
      _init_args=()
      [ -n "$init_start_date" ]      && _init_args+=(--start-date "$init_start_date")
      [ -n "$init_end_date" ]        && _init_args+=(--end-date "$init_end_date")
      [ -n "$init_capacity_points" ] && _init_args+=(--capacity-points "$init_capacity_points")
      [ -n "$init_sprint_length" ]   && _init_args+=(--sprint-length-days "$init_sprint_length")
      if [ "${#_init_args[@]}" -gt 0 ]; then
        cmd_init "$reconcile_sprint_id" "${_init_args[@]}"
      else
        cmd_init "$reconcile_sprint_id"
      fi ;;
    get)
      [ -n "$story_key" ] || die "get requires --story <key>"
      cmd_get "$story_key" ;;
    validate)
      [ -n "$story_key" ] || die "validate requires --story <key>"
      cmd_validate "$story_key" ;;
    transition)
      # Supports both story-level (--story) and sprint-level (--sprint) edges.
      # Sprint-level edges: active↔correction, active→review, review→closed,
      # review→correction.
      if [ -n "$reconcile_sprint_id" ] && [ -z "$story_key" ]; then
        [ -n "$to_state" ] || die "transition --sprint requires --to <state>"
        cmd_transition_sprint "$reconcile_sprint_id" "$to_state"
      else
        [ -n "$story_key" ] || die "transition requires --story <key> or --sprint <id>"
        [ -n "$to_state" ] || die "transition requires --to <state>"
        cmd_transition "$story_key" "$to_state"
      fi ;;
    get-goals)
      [ -n "$reconcile_sprint_id" ] || die "get-goals requires --sprint <id>"
      cmd_get_goals "$reconcile_sprint_id" ;;
    set-goals)
      [ -n "$reconcile_sprint_id" ] || die "set-goals requires --sprint <id>"
      cmd_set_goals "$reconcile_sprint_id" "$goals_arg" ;;
    update-goals)
      [ -n "$reconcile_sprint_id" ] || die "update-goals requires --sprint <id>"
      cmd_update_goals "$reconcile_sprint_id" "$goals_arg" ;;
    set-review-justification)
      [ -n "$reconcile_sprint_id" ] || die "set-review-justification requires --sprint <id>"
      [ -n "$justification_file" ] || die "set-review-justification requires --file <path>"
      cmd_set_review_justification "$reconcile_sprint_id" "$justification_file" ;;
    set-shape)
      [ -n "$reconcile_sprint_id" ] || die "set-shape requires --sprint <id>"
      [ -n "$shape_arg" ] || die "set-shape requires --shape <thrust|completion-pass>"
      cmd_set_shape "$reconcile_sprint_id" "$shape_arg" ;;
    inject)
      [ -n "$story_key" ] || die "inject requires --story <key>"
      cmd_inject "$story_key" "${reconcile_sprint_id:-}" ;;
    set-story-sprint)
      # Bind a pre-materialized backlog story's sprint_id (currently null)
      # to the active sprint without going through `--for-sprint`
      # materialization.
      [ -n "$story_key" ] || die "set-story-sprint requires --story <key>"
      [ -n "$reconcile_sprint_id" ] || die "set-story-sprint requires --sprint <id>"
      _cmd_set_story_sprint "$story_key" "$reconcile_sprint_id" ;;
    reconcile)
      # reconcile_sprint_id currently scopes to the active sprint implicitly
      # since the yaml holds one sprint at a time. Accepted for
      # forward-compatibility but not yet consulted.
      : "${reconcile_sprint_id:=}"
      cmd_reconcile "$reconcile_dry_run" ;;
    lint-dependencies)
      # lint_sprint_id reuses reconcile_sprint_id from shared --sprint-id flag.
      cmd_lint_dependencies "$lint_format" "${reconcile_sprint_id:-}" ;;
    record-escalation-override)
      cmd_record_escalation_override "$override_item_ids" "$override_user" "$override_reason" ;;
    detect-auto-close)
      cmd_detect_auto_close ;;
    rollover)
      cmd_rollover "$rollover_from" "$to_state" "$rollover_keys" ;;
  esac

  # Implementation-artifacts/ mirror. Target layout co-locates
  # sprint-status.yaml with sprint-plan/, sprint-archive/, retrospective/
  # under implementation-artifacts/. The canonical write home stays at
  # .gaia/state/; after every successful mutation we additionally mirror
  # the file to implementation-artifacts/sprint-status.yaml so the target
  # layout has it too. The mirror is best-effort (copy errors are non-fatal):
  # the canonical write is the source of truth.
  #
  # Non-creating mirror semantics: we only copy when the
  # implementation-artifacts/ dir ALREADY exists. Creating it on every state
  # mutation would shadow legacy fixtures and confuse validate-locate glob
  # resolution in any project that hasn't migrated to the canonical tree.
  case "$subcmd" in
    init|transition|inject|reconcile|rollover|set-story-sprint|set-goals|update-goals|set-review-justification|set-shape|record-escalation-override)
      _canonical_yaml="$(_resolve_active_yaml)"
      _proj_root="${PROJECT_PATH:-${CLAUDE_PROJECT_ROOT:-.}}"
      _mirror_dir="$_proj_root/.gaia/artifacts/implementation-artifacts"
      _mirror_yaml="$_mirror_dir/sprint-status.yaml"
      if [ -f "$_canonical_yaml" ] \
         && [ "$_canonical_yaml" != "$_mirror_yaml" ] \
         && [ -d "$_mirror_dir" ]; then
        cp "$_canonical_yaml" "$_mirror_yaml" 2>/dev/null || true
      fi
      ;;
  esac
}

main "$@"
