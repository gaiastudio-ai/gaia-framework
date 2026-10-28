#!/usr/bin/env bash
# review-gate.sh — GAIA foundation script
#
# Parses and atomically updates the `## Review Gate` table in a story markdown
# file. Consumed by the six review workflows (code-review, qa-tests,
# security-review, test-automate, test-review, review-perf) and their
# aggregator (run-all-reviews), which previously rewrote the table via LLM
# edits — one engine token-burn path.
#
# Invocation contract (stable for bats-core authors):
#
#   review-gate.sh check             --story <key>
#   review-gate.sh update            --story <key> --gate <name> --verdict <PASSED|FAILED|UNVERIFIED> [--sha <sha>] [--plan-id <id>]
#   review-gate.sh status            --story <key> [--gate <name> --plan-id <id>]
#   review-gate.sh review-gate-check --story <key>
#   review-gate.sh --help
#
# Canonical gate names (case-sensitive, exact):
#   "Code Review" | "QA Tests" | "Security Review"
#   "Test Automation" | "Test Review" | "Performance Review"
#
# Fork-context read-only allowlist:
#   The `review-gate-check` sub-operation is a pure read and is safe to
#   invoke from a subagent whose tool allowlist is `Read`, `Grep`, `Bash`
#   only (no `Write`, no `Edit`). It never modifies the story file,
#   creates tempfiles / lockfiles / sidecar scratch files, or touches
#   sprint-status.yaml.
#
# Extended gate name (requires --plan-id):
#   "test-automate-plan" — ledger-only gate for approval-gate verdict keying
#
# Canonical verdict vocabulary (case-sensitive, exact — per CLAUDE.md):
#   UNVERIFIED | PASSED | FAILED
#
# Any deviation (case, typo, shell metacharacters, extra whitespace in the
# --verdict value) exits 1 with a clear stderr message. The script never maps
# keywords — callers (e.g. code-review mapping APPROVE→PASSED) are responsible
# for the translation.
#
# Config:
#   PROJECT_PATH — optional. Defaults to "." when unset. If resolve-config.sh
#     becomes available on PATH later, callers may pre-export PROJECT_PATH from
#     it; review-gate.sh does NOT source resolve-config.sh directly so the two
#     foundation scripts can land in any order (soft dependency per story
#     notes / Task 1 Subtask 1.3).
#   IMPLEMENTATION_ARTIFACTS — optional. Defaults to
#     "${PROJECT_PATH}/.gaia/artifacts/implementation-artifacts" when unset. Same env var
#     convention as sprint-state.sh.
#
# Story file location (flat layout):
#   ${IMPLEMENTATION_ARTIFACTS}/<key>-*.md
#
# Exit codes:
#   0 — success (check: all PASSED; update: row rewritten; status: JSON emitted;
#       --help)
#   1 — usage error, unknown subcommand, invalid verdict or gate name, story
#       glob zero-match / multi-match, missing `## Review Gate` section, fewer
#       than six canonical rows, concurrency timeout, rewrite failure, or
#       (check) any row not PASSED
#
# Atomicity & concurrency:
#   Writes go to a tempfile next to the story file (same filesystem so `mv`
#   is atomic POSIX rename), then `mv` over the original inside a `flock -x`
#   on a sibling `.lock`. On systems without util-linux `flock(1)` (macOS
#   /bin/bash 3.2 without Homebrew util-linux), the script degrades to a
#   bounded spin-loop mv-based advisory lockfile — same fallback as
#   checkpoint.sh and lifecycle-event.sh.
#
# POSIX discipline: the only non-POSIX constructs are [[ ]] and bash indexed
# arrays. macOS /bin/bash 3.2 compatible. Uses `awk` (POSIX), `jq` (required
# for `status`), and `flock` (optional — graceful fallback).
#
# Sprint-Status Write Safety (CRITICAL, per CLAUDE.md):
#   This script NEVER writes to sprint-status.yaml. The Review Gate table
#   lives only in the story file. sprint-status.yaml is a derived view and
#   is reconciled by /gaia-sprint-status — never by review workflows.

set -euo pipefail
LC_ALL=C
export LC_ALL

# Canonical state-tree root. Code-tree paths use PROJECT_PATH.
PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-}}}"

SCRIPT_NAME="review-gate.sh"

_RG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/acquire-lock.sh
. "${_RG_DIR}/lib/acquire-lock.sh"
# shellcheck source=lib/review-gate-table.sh
. "${_RG_DIR}/lib/review-gate-table.sh"

# ---------- Canonical vocabulary ----------

# Six canonical gate names (exact case, exact spelling).
CANONICAL_GATES=(
  "Code Review"
  "QA Tests"
  "Security Review"
  "Test Automation"
  "Test Review"
  "Performance Review"
)

# Three canonical verdict values (exact case).
CANONICAL_VERDICTS=("UNVERIFIED" "PASSED" "FAILED")

# Extended gate names — require --plan-id to be present.
# "story-validation" records the terminal verdict of the Val + SM fix-loop
# pattern without overwriting the six canonical Review Gate table rows
# (which belong to the six downstream review commands). Uses the same
# ledger-keyed path as test-automate-plan.
PLAN_ID_GATES=("test-automate-plan" "story-validation" "manual-test" "sprint-review")

# plan_id canonical regex: alphanumerics plus ._:+- (security guard).
# Permissive for UUIDs and timestamp-nonce fallbacks; strict against shell injection.
PLAN_ID_REGEX='^[A-Za-z0-9._:+-]+$'

# Ledger path: overridable via --ledger flag or $REVIEW_GATE_LEDGER env var.
# Default prefers .gaia/state/.review-gate-ledger
# (mutable-runtime-state tier) over the legacy <project-root>/.review-gate-ledger.
# Always prefer .gaia/state/ on a project root that has a .gaia/ tree.
# The prior conditional required EITHER an existing ledger OR a
# pre-seeded .gaia/state/ dir — on a fresh project (where setup.sh seeded
# .gaia/artifacts/ but not .gaia/state/) the resolver fell through to repo
# root, scattering .review-gate-ledger outside the canonical .gaia/ tree.
# This change mkdir -p's .gaia/state/ at the first write so the canonical
# branch is always taken when .gaia/ exists on disk.
resolve_ledger_path() {
  if [ -n "${LEDGER_FLAG:-}" ]; then
    printf '%s' "$LEDGER_FLAG"
  elif [ -n "${REVIEW_GATE_LEDGER:-}" ]; then
    printf '%s' "$REVIEW_GATE_LEDGER"
  else
    local root="${PROJECT_ROOT:-${PROJECT_PATH:-.}}"
    if [ -d "$root/.gaia" ]; then
      # Canonical ledger path. Seed .gaia/state/ on first write so
      # subsequent reads find it.
      mkdir -p "$root/.gaia/state" 2>/dev/null || true
      printf '%s' "$root/.gaia/state/.review-gate-ledger"
    else
      # Pre-.gaia/ legacy project — fall back to repo root for back-compat.
      printf '%s' "$root/.review-gate-ledger"
    fi
  fi
}

# ---------- Helpers ----------

# Resolve the project-config.yaml path by walking up from a given directory.
# Checks PROJECT_CONFIG, then PROJECT_ROOT/CLAUDE_PROJECT_ROOT, then walks
# up from the given path looking for .gaia/config/project-config.yaml.
# Prints the resolved path or empty if not found.
_resolve_config_path() {
  local from="${1:-.}"
  # Explicit env wins.
  if [ -n "${PROJECT_CONFIG:-}" ] && [ -f "${PROJECT_CONFIG}" ]; then
    printf '%s' "$PROJECT_CONFIG"
    return 0
  fi
  # Try the roots.
  local root
  for root in "${PROJECT_ROOT:-}" "${CLAUDE_PROJECT_ROOT:-}"; do
    if [ -n "$root" ] && [ -f "$root/.gaia/config/project-config.yaml" ]; then
      printf '%s' "$root/.gaia/config/project-config.yaml"
      return 0
    fi
  done
  # Walk up from the given directory.
  local dir
  dir="$(cd "$from" 2>/dev/null && pwd)" || dir=""
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/.gaia/config/project-config.yaml" ]; then
      printf '%s' "$dir/.gaia/config/project-config.yaml"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}


die() {
  # message…  (always exit 1)
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

# Validate a value is safe for table-cell insertion: reject pipe, newline, CR.
# Used for --sha, --report and any other value written into the markdown table.
_validate_table_value() {
  local label="$1" value="$2"
  case "$value" in
    *'|'*)
      die "$label contains a pipe character ('|') which would corrupt the table — refusing"
      ;;
  esac
  case "$value" in
    *$'\n'*|*$'\r'*)
      die "$label contains a newline or carriage-return which would forge a table row — refusing"
      ;;
  esac
}

# Validate a commit SHA argument: must be 4-40 hex chars, no leading dash.
# Optionally resolves to a full SHA via git rev-parse --verify when a git
# work tree is available. Returns the (possibly resolved) SHA on stdout.
# Arguments: label value [project_path]
_validate_sha_arg() {
  local label="$1" value="$2" pp="${3:-${PROJECT_PATH:-.}}"
  # Reject leading dash (argument injection via git).
  case "$value" in
    -*)
      die "$label starts with '-' — potential argument injection; refusing"
      ;;
  esac
  # Reject non-hex characters (must be 4-40 hex chars).
  if ! printf '%s' "$value" | grep -qE '^[0-9a-fA-F]{4,40}$'; then
    die "$label must be a hex SHA (4-40 hex chars), got '$value'"
  fi
  # Resolve to full SHA when in a git work tree.
  if git -C "$pp" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local full_sha
    full_sha="$(git -C "$pp" rev-parse --verify "${value}^{commit}" 2>/dev/null)" \
      || die "$label '$value' does not resolve to a valid commit"
    printf '%s' "$full_sha"
  else
    printf '%s' "$value"
  fi
}

usage() {
  cat <<'USAGE'
Usage:
  review-gate.sh check             --story <key>
  review-gate.sh update            --story <key> --gate <name> --verdict <PASSED|FAILED|UNVERIFIED> [--sha <sha>] [--plan-id <id>]
  review-gate.sh status            --story <key> [--gate <name> --plan-id <id>]
  review-gate.sh review-gate-check --story <key>
  review-gate.sh carry-forward     --story <key> --row <gate> --from <sha> --to <sha>
  review-gate.sh --help

Subcommands:
  check             Exit 0 iff all six Review Gate rows are PASSED. Otherwise
                    exit 1 and list the non-PASSED gate names on stderr (one
                    per line).
  update            Atomically rewrite exactly one row of the Review Gate
                    table. The Status, Report and Reviewed SHA cells of the
                    matched gate are changed. When a three-column table is
                    updated, the header and separator are upgraded to the
                    four-column format. All other bytes of the story file
                    are preserved (blank lines, other rows, trailing
                    content). The fourth column (Reviewed SHA) is bound to
                    the worktree HEAD by default, or to an explicit --sha
                    value. Writes are serialized via flock. When --plan-id
                    is provided, the verdict is written to the ledger file
                    instead (tab-separated: story_key gate plan_id verdict).
  status            Print a single JSON object to stdout via jq -nc. Without
                    --plan-id, returns the full Review Gate table. With
                    --gate and --plan-id, queries the ledger for the
                    (story_key, gate, plan_id) tuple.
  review-gate-check Composite Review Gate check. Reads the six Review Gate
                    rows and prints the table followed by a summary line:
                      Review Gate: COMPLETE   (exit 0) — all six PASSED
                      Review Gate: BLOCKED    (exit 1) — any FAILED
                                              (FAILED dominates over PENDING)
                      Review Gate: PENDING    (exit 2) — any UNVERIFIED or
                                              NOT STARTED and no FAILED
                    On BLOCKED, a "Blocking gates:" list names each FAILED
                    row. On PENDING, a "Pending gates:" list names each
                    UNVERIFIED / NOT STARTED row. On COMPLETE no list is
                    emitted. Stderr is empty on all three success paths.
                    Read-only: zero file writes, zero lockfile or tempfile
                    creation. Safe to invoke under a subagent read-only
                    allowlist of Read, Grep, Bash.
  carry-forward     Re-bind a PASSED review verdict from one commit to
                    another when the diff has no files in the row's configured
                    scope globs. Evidence is self-computed from the git diff;
                    caller-supplied evidence is refused. Writes a sidecar
                    record (review-gate-carry.jsonl) with the carry evidence
                    before rebinding the row. Requires scope_globs to be
                    configured for the row in project-config.yaml.

Flags:
  --story <key>      Story key (required for all subcommands).
  --gate <name>      Gate name (required for update; optional for status).
  --verdict <V>      Verdict value (required for update).
  --sha <sha>        Commit SHA to bind the verdict to (update only).
                     Defaults to the worktree HEAD; 'none' outside a git
                     work tree.
  --row <gate>       Gate name for carry-forward.
  --from <sha>       Source SHA for carry-forward (must match the row's
                     current Reviewed SHA).
  --to <sha>         Target SHA for carry-forward.
  --plan-id <id>     Plan identifier for ledger-keyed verdicts.
                     Must match [A-Za-z0-9._:+-]+. Required for the
                     "test-automate-plan" gate; optional for canonical gates.
  --ledger <path>    Override ledger file path (default: $PROJECT_PATH/.review-gate-ledger
                     or $REVIEW_GATE_LEDGER env var).
  --report <path>    Proof-of-execution: path to the per-review report file
                     written by the dispatched skill. Required for PASSED /
                     FAILED verdicts (refused if file does not exist). Not
                     required for UNVERIFIED (seed).
  --execution-evidence <path>
                     Proof-of-execution: path to execution-evidence.json.
                     Required (in addition to --report) for test-execution
                     gates: "QA Tests", "Test Automation", "Test Review".
  --report-missing-reason <reason>
                     Explicit escape hatch when no report exists (e.g. FAILED
                     verdict with no salvageable report). Suppresses the
                     --report / --execution-evidence checks and records the
                     reason in the audit log.

  Proof-of-execution can be disabled via REVIEW_GATE_PROOF_OF_EXECUTION=off
  for bats fixtures that exercise verdict mechanics without dispatching real
  review skills.

Canonical gate names (case-sensitive):
  "Code Review" | "QA Tests" | "Security Review"
  "Test Automation" | "Test Review" | "Performance Review"

Extended gate names (require --plan-id):
  "test-automate-plan"

Canonical verdicts (case-sensitive, per CLAUDE.md):
  UNVERIFIED | PASSED | FAILED

Story file is located via the glob
  ${IMPLEMENTATION_ARTIFACTS}/<key>-*.md
IMPLEMENTATION_ARTIFACTS defaults to "${PROJECT_PATH}/docs/implementation-artifacts".
PROJECT_PATH defaults to "." when unset.

Exit codes:
  0 — success (check: all PASSED; review-gate-check: COMPLETE)
  1 — usage error, invalid input, missing file/section, (check) any non-PASSED
      row, or (review-gate-check) BLOCKED — any FAILED row
  2 — (review-gate-check) PENDING — any UNVERIFIED / NOT STARTED row and no
      FAILED. Distinct from the exit-1 error path so callers can distinguish
      "still in progress" from "explicitly failed".
USAGE
}

# Validate a candidate gate name against the canonical six.
is_canonical_gate() {
  local candidate="$1"
  local g
  for g in "${CANONICAL_GATES[@]}"; do
    if [ "$g" = "$candidate" ]; then
      return 0
    fi
  done
  return 1
}

# Validate a candidate verdict against the canonical three.
is_canonical_verdict() {
  local candidate="$1"
  local v
  for v in "${CANONICAL_VERDICTS[@]}"; do
    if [ "$v" = "$candidate" ]; then
      return 0
    fi
  done
  return 1
}

# Check whether a candidate gate is a plan-id-only gate.
is_plan_id_gate() {
  local candidate="$1"
  local g
  for g in "${PLAN_ID_GATES[@]}"; do
    if [ "$g" = "$candidate" ]; then
      return 0
    fi
  done
  return 1
}

# Validate a plan_id value against the canonical regex.
# Returns 0 if valid, 1 if invalid. Empty values are rejected.
validate_plan_id() {
  local value="$1"
  if [ -z "$value" ]; then
    die "--plan-id requires a value"
  fi
  if [[ ! "$value" =~ $PLAN_ID_REGEX ]]; then
    die "invalid --plan-id value '$value' — must match $PLAN_ID_REGEX (alphanumerics plus ._:+-)"
  fi
}

# Join an array with a separator — used for error messages listing the
# canonical vocabulary.
join_by() {
  local sep="$1"; shift
  local out="" first=1
  local item
  for item in "$@"; do
    if [ $first -eq 1 ]; then
      out="$item"
      first=0
    else
      out="$out$sep$item"
    fi
  done
  printf '%s' "$out"
}

# Check whether a file's YAML frontmatter contains `template: 'story'`.
# Reads only the frontmatter block (between the first two `---` lines).
# Returns 0 if the file is a canonical story file, 1 otherwise.
# Portable: bash 3.2+ compatible, uses awk only.
# Adopted from sprint-state.sh.
_is_story_file() {
  local f="$1"
  awk '
    /^---[[:space:]]*$/ { n++; if (n == 2) exit }
    n == 1 && /^template:[[:space:]]*["\x27]?story["\x27]?[[:space:]]*$/ { found = 1; exit }
    END { exit (found ? 0 : 1) }
  ' "$f"
}

# Locate the story file via glob `{key}-*.md` under IMPLEMENTATION_ARTIFACTS,
# then filter candidates by frontmatter `template: 'story'` to exclude review
# sibling files (-review.md, -qa-tests.md, -security-review.md, etc.).
# Result is returned via STORY_FILE global. Exits 1 on zero or multiple
# canonical matches.
# Uses the flat IMPLEMENTATION_ARTIFACTS directory, not a stories/ subdirectory.
STORY_FILE=""
locate_story_file() {
  local key="$1"
  local project_path="${PROJECT_PATH:-.}"
  # Prefer .gaia/artifacts/implementation-artifacts/ when present on disk;
  # fall back to legacy docs/ during the deprecation window.
  # IMPLEMENTATION_ARTIFACTS env-var override wins over both.
  local impl_artifacts
  if [ -n "${IMPLEMENTATION_ARTIFACTS:-}" ]; then
    impl_artifacts="$IMPLEMENTATION_ARTIFACTS"
  elif [ -d "${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/artifacts/implementation-artifacts" ]; then
    impl_artifacts="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/artifacts/implementation-artifacts"
  else
    impl_artifacts="${project_path}/docs/implementation-artifacts"
  fi
  local pattern="${impl_artifacts}/${key}-*.md"
  local epic_pattern="${impl_artifacts}/epic-*/stories/${key}-*.md"
  # NEW per-story layout: epic-{slug}/{key}-{slug}/story.md.
  local perstory_pattern="${impl_artifacts}/epic-*/${key}-*/story.md"

  # shopt -s nullglob so zero-match produces an empty array rather than the
  # literal pattern string.
  local matches=()
  # The glob expansion happens in an isolated context so nullglob doesn't
  # leak to the rest of the script.
  shopt -s nullglob
  # shellcheck disable=SC2206
  matches=( $pattern $epic_pattern $perstory_pattern )
  shopt -u nullglob

  # Drop per-story evidence dirs under a legacy `stories/` segment — tier-1, not
  # the new tier-0 layout (the `*` in perstory_pattern would otherwise let them in).
  if [ "${#matches[@]}" -gt 0 ]; then
    local _filtered=() _mm
    for _mm in "${matches[@]}"; do
      case "$_mm" in */stories/*/story.md) continue ;; esac
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
    local listed
    listed=$(printf '  %s\n' "${canonical[@]}")
    printf '%s: multiple story files matched key %s (glob: %s)\n%s\n' \
      "$SCRIPT_NAME" "$key" "$pattern" "$listed" >&2
    exit 1
  fi

  STORY_FILE="${canonical[0]}"
}

# ---------- Review Gate table parser ----------
#
# The parser is a single awk pass that:
#   1. Locates the `## Review Gate` header line.
#   2. Finds the first pipe table after the header (header row `| Review | …`
#      followed by a separator row `|---|---|---|`).
#   3. Emits `GATE<TAB>STATUS<TAB>REPORT` for each data row until the table
#      ends (blank line, new header, or EOF).
#
# The awk output is then filtered in bash to enforce the canonical six gates.
# Unknown gate names are preserved in the file (spurious rows are left
# untouched on update) but ignored for check/status vocabulary checks.

# Stream parsed rows to stdout as TSV `GATE\tSTATUS\tREPORT\tSHA`.
# Delegates to the shared dual-shape parser (review-gate-table.sh).
# Three-column rows emit SHA as "absent".
# Exits 1 (via die) if the `## Review Gate` header is absent.
parse_gate_rows() {
  local file="$1"

  if ! grep -q '^## Review Gate[[:space:]]*$' "$file"; then
    die "story file '$file' is missing the '## Review Gate' section"
  fi

  parse_review_gate_table "$file"
}

# Populate three parallel global arrays ROW_GATES / ROW_STATUSES / ROW_SHAS
# from the parsed table, keeping only the canonical six gates (in canonical
# order). Exits 1 if any canonical gate is missing from the table.
ROW_GATES=()
ROW_STATUSES=()
ROW_SHAS=()
load_canonical_rows() {
  local file="$1"

  # Reset globals.
  ROW_GATES=()
  ROW_STATUSES=()
  ROW_SHAS=()

  # Collect parsed rows into temp arrays keyed by gate name.
  local -a parsed_gates=()
  local -a parsed_statuses=()
  local -a parsed_shas=()

  local gate status _report _sha
  while IFS=$'\t' read -r gate status _report _sha; do
    [ -z "$gate" ] && continue
    parsed_gates+=("$gate")
    parsed_statuses+=("$status")
    parsed_shas+=("${_sha:-}")
  done < <(parse_gate_rows "$file")

  # For each canonical gate (in order), find its row.
  local cg i found
  for cg in "${CANONICAL_GATES[@]}"; do
    found=0
    i=0
    while [ $i -lt "${#parsed_gates[@]}" ]; do
      if [ "${parsed_gates[$i]}" = "$cg" ]; then
        ROW_GATES+=("$cg")
        ROW_STATUSES+=("${parsed_statuses[$i]}")
        ROW_SHAS+=("${parsed_shas[$i]:-}")
        found=1
        break
      fi
      i=$((i + 1))
    done
    if [ $found -eq 0 ]; then
      die "story file '$file' is missing canonical gate row '$cg' in '## Review Gate'"
    fi
  done
}

# ---------- Ledger operations ----------
#
# The ledger is a separate tab-separated file (.review-gate-ledger) used for
# plan-id-keyed verdict records. It does NOT mutate the Review Gate table.
# Row format: story_key<TAB>gate<TAB>plan_id<TAB>verdict
# Atomic write: tempfile + mv (same pattern as cmd_update for story files).

# Write a ledger row. Appends a new record; does not dedup.
# Arguments: story_key gate plan_id verdict
ledger_write() {
  local story_key="$1" gate="$2" plan_id="$3" verdict="$4"
  local ledger_path
  ledger_path="$(resolve_ledger_path)"

  local ledger_dir
  ledger_dir="$(dirname "$ledger_path")"
  mkdir -p "$ledger_dir"

  local ledger_lock="${ledger_path}.lock"

  # Subshell isolates the lock: any die() or set -e abort releases the fd
  # on process exit, preventing a leaked PID-bearing lock.
  (
    if ! acquire_lock "$ledger_lock" 5 8; then
      die "lock timeout acquiring $ledger_lock"
    fi
    trap 'release_lock 8 2>/dev/null || true' EXIT

    local tmpfile="${ledger_path}.tmp.$$"

    # Atomic append: copy existing content + new row -> tmpfile, then mv.
    {
      if [ -f "$ledger_path" ]; then
        cat "$ledger_path"
      fi
      printf '%s\t%s\t%s\t%s\n' "$story_key" "$gate" "$plan_id" "$verdict"
    } > "$tmpfile"

    if ! mv -f "$tmpfile" "$ledger_path"; then
      rm -f "$tmpfile"
      exit 1
    fi
    # No trailing release_lock: it would be the subshell's last statement and
    # its always-zero status would become the subshell's exit status, masking
    # a failure in the critical section above and defeating the `|| die`
    # below. The EXIT trap releases idempotently on every path.
  ) || die "failed to write ledger at '$ledger_path'"
}

# Read a ledger verdict for (story_key, gate, plan_id) tuple.
# Prints the verdict if found, "UNVERIFIED" if no match.
# Arguments: story_key gate plan_id
ledger_read() {
  local story_key="$1" gate="$2" plan_id="$3"
  local ledger_path
  ledger_path="$(resolve_ledger_path)"

  if [ ! -f "$ledger_path" ]; then
    printf 'UNVERIFIED'
    return 0
  fi

  local found_verdict=""
  local l_story l_gate l_plan l_verdict
  while IFS=$'\t' read -r l_story l_gate l_plan l_verdict; do
    if [ "$l_story" = "$story_key" ] && \
       [ "$l_gate" = "$gate" ] && \
       [ "$l_plan" = "$plan_id" ]; then
      found_verdict="$l_verdict"
    fi
  done < "$ledger_path"

  if [ -n "$found_verdict" ]; then
    printf '%s' "$found_verdict"
  else
    printf 'UNVERIFIED'
  fi
}

# ---------- Subcommand: status ----------

cmd_status() {
  local file="$1"
  local story_key="$2"
  local gate_name="${3:-}"
  local plan_id="${4:-}"

  # If --gate and --plan-id are both provided, query the ledger instead of
  # the story file's Review Gate table.
  if [ -n "$gate_name" ] && [ -n "$plan_id" ]; then
    local verdict
    verdict="$(ledger_read "$story_key" "$gate_name" "$plan_id")"
    jq -nc \
      --arg story "$story_key" \
      --arg gate "$gate_name" \
      --arg plan_id "$plan_id" \
      --arg verdict "$verdict" \
      '{story: $story, gate: $gate, plan_id: $plan_id, verdict: $verdict}'
    return 0
  fi

  load_canonical_rows "$file"

  # Build jq arg list: --arg story <key> --arg cr <v> --arg qa <v> ...
  # Positional mapping matches CANONICAL_GATES order.
  jq -nc \
    --arg story "$story_key" \
    --arg cr  "${ROW_STATUSES[0]}" \
    --arg qa  "${ROW_STATUSES[1]}" \
    --arg sec "${ROW_STATUSES[2]}" \
    --arg ta  "${ROW_STATUSES[3]}" \
    --arg tr  "${ROW_STATUSES[4]}" \
    --arg pr  "${ROW_STATUSES[5]}" \
    '{
      story: $story,
      gates: {
        "Code Review":        $cr,
        "QA Tests":           $qa,
        "Security Review":    $sec,
        "Test Automation":    $ta,
        "Test Review":        $tr,
        "Performance Review": $pr
      }
    }'
}

# ---------- Subcommand: review-gate-check ----------
#
# Composite Review Gate check. Emits the six-row Review Gate table verbatim
# followed by a summary line and — on the BLOCKED or PENDING paths — a list
# of the offending gate names. Exit codes are deterministic:
#
#   0 — COMPLETE: all six gates have verdict PASSED
#   1 — BLOCKED:  at least one gate is FAILED (FAILED dominates PENDING)
#   2 — PENDING:  at least one gate is UNVERIFIED / NOT STARTED and
#                 no gate is FAILED
#
# Read-only: zero file writes, zero tempfile / mv / flock. The sub-operation
# only parses the story file — it never creates, modifies, or deletes any
# file or sidecar. Before/after shasum -a 256 of the story file is
# byte-identical across all three verdict paths.
#
# Fork-context: safe to invoke under a subagent whose tool allowlist is
# Read, Grep, Bash only — the execution path uses awk / grep / bash
# built-ins and the existing locate_story_file helper.

# Classify the six canonical verdicts into a composite status. Used as a
# standalone helper so callers and unit tests can exercise the decision
# logic independently of I/O. Echoes exactly one of: COMPLETE | BLOCKED |
# PENDING. This helper is pure — no side effects — and is the canonical
# source of the FAILED-dominates-PENDING dominance rules.
#
# Arguments: six verdict strings in canonical gate order.
classify_review_gate() {
  local v
  # FAILED dominates over everything else.
  for v in "$@"; do
    if [ "$v" = "FAILED" ]; then
      printf 'BLOCKED'
      return 0
    fi
  done
  # No FAILED — any UNVERIFIED / NOT STARTED is PENDING.
  for v in "$@"; do
    if [ "$v" = "UNVERIFIED" ] || [ "$v" = "NOT STARTED" ]; then
      printf 'PENDING'
      return 0
    fi
  done
  # All rows are PASSED (or a non-canonical verdict equivalent to PASSED
  # as ruled canonical elsewhere). Treat as COMPLETE only if every row is
  # exactly PASSED — any other value is a data-integrity issue the caller
  # is expected to catch via load_canonical_rows's row presence check.
  for v in "$@"; do
    if [ "$v" != "PASSED" ]; then
      # Unknown verdict — treat as PENDING (safe fallback; non-canonical
      # text is treated as equivalent to UNVERIFIED).
      printf 'PENDING'
      return 0
    fi
  done
  printf 'COMPLETE'
  return 0
}

cmd_review_gate_check() {
  local file="$1"

  # Reuse the existing canonical-row loader. This populates two parallel
  # global arrays — ROW_GATES[i] / ROW_STATUSES[i] — in canonical order,
  # and exits 1 via die() if any canonical gate is missing from the table.
  load_canonical_rows "$file"

  # Parse the six Report and SHA cells out of the parsed TSV stream so
  # the table we render preserves whatever the story author wrote.
  local -a report_for_gate=()
  local -a sha_for_gate=()
  local parsed_gate _parsed_status parsed_report parsed_sha i found
  local cg
  for cg in "${CANONICAL_GATES[@]}"; do
    found=0
    while IFS=$'\t' read -r parsed_gate _parsed_status parsed_report parsed_sha; do
      if [ "$parsed_gate" = "$cg" ]; then
        report_for_gate+=("$parsed_report")
        sha_for_gate+=("${parsed_sha:-}")
        found=1
        break
      fi
    done < <(parse_gate_rows "$file")
    if [ $found -eq 0 ]; then
      report_for_gate+=("—")
      sha_for_gate+=("")
    fi
  done

  # Render the six-row markdown table. Use four columns when any row has
  # a SHA; otherwise preserve the legacy three-column format.
  local has_sha=0
  for i in "${sha_for_gate[@]}"; do
    if [ -n "$i" ]; then has_sha=1; break; fi
  done

  if [ "$has_sha" -eq 1 ]; then
    printf '| Review | Status | Report | Reviewed SHA |\n'
    printf '|--------|--------|--------|--------------|\n'
    i=0
    while [ $i -lt "${#ROW_GATES[@]}" ]; do
      printf '| %s | %s | %s | %s |\n' \
        "${ROW_GATES[$i]}" "${ROW_STATUSES[$i]}" "${report_for_gate[$i]}" "${sha_for_gate[$i]:-}"
      i=$((i + 1))
    done
  else
    printf '| Review | Status | Report |\n'
    printf '|--------|--------|--------|\n'
    i=0
    while [ $i -lt "${#ROW_GATES[@]}" ]; do
      printf '| %s | %s | %s |\n' \
        "${ROW_GATES[$i]}" "${ROW_STATUSES[$i]}" "${report_for_gate[$i]}"
      i=$((i + 1))
    done
  fi

  # Classify.
  local composite
  composite="$(classify_review_gate "${ROW_STATUSES[@]}")"

  printf '\nReview Gate: %s\n' "$composite"

  case "$composite" in
    COMPLETE)
      return 0
      ;;
    BLOCKED)
      printf 'Blocking gates:\n'
      i=0
      while [ $i -lt "${#ROW_GATES[@]}" ]; do
        if [ "${ROW_STATUSES[$i]}" = "FAILED" ]; then
          printf '  - %s\n' "${ROW_GATES[$i]}"
        fi
        i=$((i + 1))
      done
      exit 1
      ;;
    PENDING)
      printf 'Pending gates:\n'
      i=0
      while [ $i -lt "${#ROW_GATES[@]}" ]; do
        case "${ROW_STATUSES[$i]}" in
          UNVERIFIED|"NOT STARTED")
            printf '  - %s\n' "${ROW_GATES[$i]}"
            ;;
          PASSED|FAILED)
            : # skip
            ;;
          *)
            # Non-canonical verdicts are treated as PENDING per
            # classify_review_gate's fallback; surface them so the caller
            # can see which row(s) forced PENDING.
            printf '  - %s\n' "${ROW_GATES[$i]}"
            ;;
        esac
        i=$((i + 1))
      done
      exit 2
      ;;
  esac
}

# ---------- Subcommand: check ----------

cmd_check() {
  local file="$1"

  load_canonical_rows "$file"

  local i ok=1
  local -a bad=()
  i=0
  while [ $i -lt "${#ROW_GATES[@]}" ]; do
    if [ "${ROW_STATUSES[$i]}" != "PASSED" ]; then
      bad+=("${ROW_GATES[$i]}")
      ok=0
    fi
    i=$((i + 1))
  done

  if [ $ok -eq 1 ]; then
    return 0
  fi

  local g
  for g in "${bad[@]}"; do
    printf '%s\n' "$g" >&2
  done
  exit 1
}

# ---------- Subcommand: update ----------

# Rewrite exactly one row of the Review Gate table in $file, replacing the
# Status cell of the matched gate with $new_verdict, the Report cell with
# the provided report path (or "—" when none is given), and the Reviewed SHA
# cell with the provided SHA. All other bytes are preserved. Runs under flock
# and uses tempfile + atomic mv.
cmd_update() {
  local file="$1"
  local gate_name="$2"
  local new_verdict="$3"
  local report_value="${4:-—}"
  local sha_value="${5:-}"

  # Data-integrity guard: reject report paths that would corrupt the
  # markdown table or allow row injection. Pipe characters add cells,
  # newlines (CR/LF) forge rows. Fail closed with an actionable message.
  case "$report_value" in
    *'|'*)
      die "report path contains a pipe character ('|') which would corrupt the Review Gate table — refusing update for gate '$gate_name'"
      ;;
  esac
  case "$report_value" in
    *$'\n'*|*$'\r'*)
      die "report path contains a newline or carriage-return which would forge a Review Gate row — refusing update for gate '$gate_name'"
      ;;
  esac

  # Validate the section exists (produces a precise error).
  # We also validate by loading canonical rows.
  load_canonical_rows "$file"

  local lockfile="${file}.lock"
  local tmpfile="${file}.tmp.$$"

  rewrite_body() {
    # Stream $file through awk, rewriting only the first data row of the
    # first pipe-table under `## Review Gate` whose first cell matches
    # $gate_name. Preserve CRLF and all surrounding bytes.
    # The report value is passed via ENVIRON to avoid awk -v backslash
    # expansion (awk -v interprets \t, \n etc. in the value).
    GAIA_RG_REPORT="$report_value" GAIA_RG_SHA="$sha_value" awk -v target="$gate_name" -v new_status="$new_verdict" '
      BEGIN {
        in_section = 0; in_table = 0; saw_sep = 0; rewritten = 0
        header_upgraded = 0
        new_report = ENVIRON["GAIA_RG_REPORT"]
        new_sha = ENVIRON["GAIA_RG_SHA"]
      }

      {
        raw = $0
        line = $0
        sub(/\r$/, "", line)
      }

      line ~ /^## Review Gate[[:space:]]*$/ {
        in_section = 1; in_table = 0; saw_sep = 0
        print raw
        next
      }

      in_section && line ~ /^## / {
        in_section = 0; in_table = 0
        print raw
        next
      }

      !in_section {
        print raw
        next
      }

      in_section && !in_table {
        if (line ~ /^[[:space:]]*\|/) {
          in_table = 1
          saw_sep = 0

          # Check if this is a 3-column header that needs upgrading.
          # Count pipe-delimited cells in the header row.
          tmp_h = line
          sub(/^[[:space:]]*\|/, "", tmp_h)
          sub(/\|[[:space:]]*$/, "", tmp_h)
          h_cols = split(tmp_h, hcells, /\|/)
          if (h_cols == 3 && new_sha != "") {
            # Upgrade to 4-column header.
            crlf = ""
            if (raw ~ /\r$/) { crlf = "\r" }
            printf "| Review | Status | Report | Reviewed SHA |%s\n", crlf
            header_upgraded = 1
            next
          }
        }
        print raw
        next
      }

      in_table {
        if (line !~ /^[[:space:]]*\|/) {
          in_table = 0
          in_section = 0
          print raw
          next
        }

        if (!saw_sep && line ~ /^[[:space:]]*\|[[:space:]]*-+/) {
          saw_sep = 1
          if (header_upgraded) {
            # Upgrade separator to 4 columns.
            crlf = ""
            if (raw ~ /\r$/) { crlf = "\r" }
            printf "|--------|--------|--------|--------------|%s\n", crlf
            next
          }
          print raw
          next
        }

        if (rewritten) {
          # Upgrade non-target rows to 4 columns if header was upgraded.
          if (header_upgraded) {
            tmp2 = line
            sub(/^[[:space:]]*\|/, "", tmp2)
            sub(/\|[[:space:]]*$/, "", tmp2)
            n2 = split(tmp2, c2, /\|/)
            if (n2 == 3) {
              for (j = 1; j <= 3; j++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", c2[j])
              crlf = ""
              if (raw ~ /\r$/) { crlf = "\r" }
              printf "| %s | %s | %s |  |%s\n", c2[1], c2[2], c2[3], crlf
              next
            }
          }
          print raw
          next
        }

        # Parse the stripped line into cells for comparison.
        tmp = line
        sub(/^[[:space:]]*\|/, "", tmp)
        sub(/\|[[:space:]]*$/, "", tmp)
        n = split(tmp, cells, /\|/)
        if (n < 3) {
          print raw
          next
        }
        gate = cells[1]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", gate)

        if (gate != target) {
          # Upgrade non-target rows to 4 columns if header was upgraded.
          if (header_upgraded && n == 3) {
            for (j = 1; j <= 3; j++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", cells[j])
            crlf = ""
            if (raw ~ /\r$/) { crlf = "\r" }
            printf "| %s | %s | %s |  |%s\n", cells[1], cells[2], cells[3], crlf
            next
          }
          print raw
          next
        }

        # Rewrite this row — always four columns.
        crlf = ""
        if (raw ~ /\r$/) { crlf = "\r" }
        printf "| %s | %s | %s | %s |%s\n", target, new_status, new_report, new_sha, crlf
        rewritten = 1
        next
      }

      { print raw }

      END {
        if (!rewritten) {
          exit 2
        }
      }
    ' "$file" > "$tmpfile"
  }

  do_update() {
    local awk_rc=0
    rewrite_body || awk_rc=$?
    if [ "$awk_rc" -ne 0 ]; then
      rm -f "$tmpfile"
      die "failed to rewrite row for gate '$gate_name' in '$file' (no matching row found)"
    fi
    # Atomic rename — same filesystem so mv is a rename(2).
    if ! mv -f "$tmpfile" "$file"; then
      rm -f "$tmpfile"
      die "failed to mv tempfile over '$file'"
    fi
  }

  (
    if ! acquire_lock "$lockfile" 5 9; then
      die "lock timeout acquiring $lockfile"
    fi
    # Install the releasing trap on the very next line after a successful
    # acquire: do_update dies on a missing target row or a failed rename, and
    # both exit the subshell without reaching any trailing release, leaving a
    # PID-bearing lock file that blocks later updates for this story until it
    # ages past the reap floor.
    trap 'release_lock 9 2>/dev/null || true' EXIT
    # No trailing release_lock: it would mask do_update's exit status.
    do_update
  )
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
    check|update|status|review-gate-check|carry-forward)
      ;;
    *)
      printf '%s: unknown subcommand: %s\n' "$SCRIPT_NAME" "$subcmd" >&2
      usage >&2
      exit 1
      ;;
  esac

  local story_key="" gate_name="" verdict="" plan_id="" sprint_id=""
  local sha_arg="" carry_from="" carry_to="" carry_row="" carry_evidence=""
  # Proof-of-execution flags:
  # --report <path> — path to the per-review report file written by the dispatched skill.
  # --execution-evidence <path> — path to execution-evidence.json (required for test-execution gates).
  # --report-missing-reason <reason> — explicit escape hatch for cases where no report exists
  #   (e.g. UNVERIFIED seed rows, FAILED verdicts with no salvageable report).
  # The `--sprint` flag handles sprint-scoped gates (sprint-review, sprint-close
  # handoffs). When `--sprint` is set and `--story` is not, the helper treats the
  # invocation as sprint-scoped: it reads/writes a ledger entry keyed by
  # `sprint-${id}-${gate}` rather than locating a story file. The plan-id-by-default
  # fallback keeps the entry uniquely addressable per sprint so the dispatcher
  # (gaia-sprint-close Step 3a) can query the sentinel without referencing a story key.
  local report_path="" execution_evidence="" report_missing_reason=""
  local sprint_scoped=""
  LEDGER_FLAG=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --story)
        [ $# -ge 2 ] || die "--story requires a value"
        story_key="$2"; shift 2
        ;;
      --sprint)
        [ $# -ge 2 ] || die "--sprint requires a value"
        sprint_id="$2"; shift 2
        ;;
      --gate)
        [ $# -ge 2 ] || die "--gate requires a value"
        gate_name="$2"; shift 2
        ;;
      --verdict)
        [ $# -ge 2 ] || die "--verdict requires a value"
        verdict="$2"; shift 2
        ;;
      --plan-id)
        [ $# -ge 2 ] || die "--plan-id requires a value"
        plan_id="$2"; shift 2
        ;;
      --plan-id=*)
        plan_id="${1#--plan-id=}"; shift
        ;;
      --ledger)
        [ $# -ge 2 ] || die "--ledger requires a value"
        LEDGER_FLAG="$2"; shift 2
        ;;
      --report)
        [ $# -ge 2 ] || die "--report requires a value"
        report_path="$2"; shift 2
        ;;
      --execution-evidence)
        [ $# -ge 2 ] || die "--execution-evidence requires a value"
        execution_evidence="$2"; shift 2
        ;;
      --report-missing-reason)
        [ $# -ge 2 ] || die "--report-missing-reason requires a value"
        report_missing_reason="$2"; shift 2
        ;;
      --sha)
        [ $# -ge 2 ] || die "--sha requires a value"
        sha_arg="$2"; shift 2
        ;;
      --row)
        [ $# -ge 2 ] || die "--row requires a value"
        carry_row="$2"; shift 2
        ;;
      --from)
        [ $# -ge 2 ] || die "--from requires a value"
        carry_from="$2"; shift 2
        ;;
      --to)
        [ $# -ge 2 ] || die "--to requires a value"
        carry_to="$2"; shift 2
        ;;
      --evidence)
        [ $# -ge 2 ] || die "--evidence requires a value"
        carry_evidence="$2"; shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown flag: $1"
        ;;
    esac
  done

  # Validate plan_id if provided (security guards).
  if [ -n "$plan_id" ]; then
    validate_plan_id "$plan_id"
  fi

  # Sprint-scoped invocation short-circuit.
  # When `--sprint` is provided WITHOUT `--story`, this is a sprint-level
  # gate (sprint-review, sprint-close handoff). Synthesize a story-key
  # sentinel of the form `sprint:<sprint-id>` so the downstream ledger
  # path keys the entry stably, default the plan-id to
  # `<gate>-<sprint-id>` when one isn't given, and skip locate_story_file
  # (there's no per-story file to find). Forward to the ledger path the
  # same way story-keyed gates do.
  if [ -z "$story_key" ] && [ -n "$sprint_id" ]; then
    story_key="sprint:${sprint_id}"
    if [ -z "$plan_id" ] && [ -n "$gate_name" ]; then
      plan_id="${gate_name}-${sprint_id}"
    fi
    # Ledger path is the only valid sink for sprint-scoped gates — they do
    # NOT touch a per-story Review Gate table. Mark sprint-scoped so
    # downstream dispatch skips locate_story_file without polluting
    # resolve_ledger_path (which consumes LEDGER_FLAG as a literal path).
    # Intent flag; downstream guards use sprint_id + STORY_FILE.
    # shellcheck disable=SC2034
    sprint_scoped=true
    # Skip locate_story_file (no story file exists for a sprint sentinel).
  else
    [ -n "$story_key" ] || die "$subcmd requires --story <key> or --sprint <id>"

    # For plan-id-only gates (ledger path), locate_story_file is still required
    # to ensure the story exists before recording any verdict.
    locate_story_file "$story_key"
  fi

  case "$subcmd" in
    check)
      # Sprint-scoped invocations are ledger-only by contract — there's no
      # per-sprint Review Gate table to scan.
      if [ -n "$sprint_id" ] && [ -z "$STORY_FILE" ]; then
        die "check subcommand requires a story file; --sprint-scoped checks should query the ledger via status"
      fi
      cmd_check "$STORY_FILE"
      ;;
    review-gate-check)
      if [ -n "$sprint_id" ] && [ -z "$STORY_FILE" ]; then
        die "review-gate-check requires a story file; --sprint-scoped composite checks are not defined"
      fi
      cmd_review_gate_check "$STORY_FILE"
      ;;
    status)
      cmd_status "$STORY_FILE" "$story_key" "$gate_name" "$plan_id"
      ;;
    update)
      [ -n "$gate_name" ] || die "update requires --gate <name>"
      [ -n "$verdict" ]   || die "update requires --verdict <PASSED|FAILED|UNVERIFIED>"

      # Gate-name validation: plan-id-only gates require --plan-id.
      if is_plan_id_gate "$gate_name"; then
        if [ -z "$plan_id" ]; then
          die "gate '$gate_name' requires --plan-id"
        fi
      elif ! is_canonical_gate "$gate_name"; then
        local allowed_gates
        allowed_gates=$(join_by ', ' "${CANONICAL_GATES[@]}")
        die "invalid gate name '$gate_name' — allowed: $allowed_gates"
      fi

      if ! is_canonical_verdict "$verdict"; then
        local allowed_verdicts
        allowed_verdicts=$(join_by ', ' "${CANONICAL_VERDICTS[@]}")
        die "invalid verdict '$verdict' — allowed: $allowed_verdicts"
      fi

      # Proof-of-execution gate.
      # Disabled when REVIEW_GATE_PROOF_OF_EXECUTION=off (e.g. inside the
      # script's own bats fixtures that exercise the verdict mechanics
      # without dispatching real review skills). Enforced by default.
      if [ "${REVIEW_GATE_PROOF_OF_EXECUTION:-on}" != "off" ] && [ -z "$plan_id" ]; then
        # UNVERIFIED is the seed-state — no proof required.
        case "$verdict" in
          PASSED|FAILED)
            if [ -n "$report_path" ]; then
              if [ ! -f "$report_path" ]; then
                die "proof-of-execution: --report '$report_path' does not exist on disk — refusing $verdict verdict for gate '$gate_name'"
              fi
            elif [ -n "$report_missing_reason" ]; then
              : # explicit escape hatch — operator accepts the gap.
            else
              die "proof-of-execution: $verdict verdict for gate '$gate_name' requires --report <path> or --report-missing-reason <reason>"
            fi
            # Test-execution gates additionally require execution evidence.
            case "$gate_name" in
              "QA Tests"|"Test Automation"|"Test Review")
                if [ -z "$execution_evidence" ] && [ -z "$report_missing_reason" ]; then
                  die "proof-of-execution: gate '$gate_name' is a test-execution gate; $verdict verdict requires --execution-evidence <path> (or --report-missing-reason <reason>)"
                fi
                if [ -n "$execution_evidence" ] && [ ! -f "$execution_evidence" ]; then
                  die "proof-of-execution: --execution-evidence '$execution_evidence' does not exist on disk — refusing $verdict verdict for gate '$gate_name'"
                fi
                # Content check on the execution-evidence JSON. The prior
                # implementation verified the file EXISTED but never inspected
                # its contents, so a PASSED verdict against evidence with
                # `exit_code: 1` + `fail_count: N` was accepted and the
                # review-gate-check composite returned COMPLETE. A story with
                # a RED suite reached `done` with all six gates "PASSED" —
                # exactly the gate-integrity hole this proof-of-execution rule
                # was added to prevent. Refuse PASSED when the evidence shows
                # a failed suite.
                #
                # Triggers (any of these → refuse PASSED):
                #   exit_code != 0
                #   fail_count > 0 (when present)
                #   skipped == true AND the tier is required (the bridge
                #   stamps skipped:false for a real run; skipped:true is
                #   "tier not exercised", which is not a PASSED signal)
                #
                # FAILED verdict is ALLOWED against red evidence — the
                # operator is correctly recording that the gate failed.
                if [ "$verdict" = "PASSED" ] \
                   && [ -n "$execution_evidence" ] \
                   && [ -f "$execution_evidence" ] \
                   && command -v jq >/dev/null 2>&1; then
                  # Validate the evidence is well-formed JSON with a
                  # top-level object before reading fields. Malformed JSON
                  # or a non-object top level must fail closed — a silent
                  # fall-through to 0 would let a broken capture pass.
                  if ! jq -e 'type == "object"' "$execution_evidence" >/dev/null 2>&1; then
                    die "proof-of-execution: refusing PASSED verdict for '$gate_name' — execution-evidence is not valid JSON or is not an object. Fix the evidence file and retry."
                  fi
                  _ev_exit="$(jq -r '[.suites[]? | select(.required != false) | .exit_code // 0] | max // 0' "$execution_evidence" 2>/dev/null)" || _ev_exit=""
                  _ev_fails="$(jq -r '[.suites[]? | select(.required != false) | .fail_count // 0] | add // 0' "$execution_evidence" 2>/dev/null)" || _ev_fails=""
                  _ev_skipped="$(jq -r '.skipped // false' "$execution_evidence" 2>/dev/null)" || _ev_skipped=""
                  # If any jq extraction failed (empty), fail closed.
                  if [ -z "$_ev_exit" ] || [ -z "$_ev_fails" ] || [ -z "$_ev_skipped" ]; then
                    die "proof-of-execution: refusing PASSED verdict for '$gate_name' — failed to read execution-evidence fields (malformed JSON structure). Fix the evidence file and retry."
                  fi
                  if [ "${_ev_exit:-0}" != "0" ]; then
                    die "proof-of-execution: refusing PASSED verdict for '$gate_name' — execution-evidence reports exit_code=${_ev_exit} (red suite). Either fix the failing tests and re-capture evidence, or record verdict=FAILED."
                  fi
                  if [ "${_ev_fails:-0}" != "0" ] && [ "${_ev_fails:-0}" != "null" ]; then
                    die "proof-of-execution: refusing PASSED verdict for '$gate_name' — execution-evidence reports fail_count=${_ev_fails} across suites. Either fix the failing tests and re-capture evidence, or record verdict=FAILED."
                  fi
                  if [ "$_ev_skipped" = "true" ]; then
                    die "proof-of-execution: refusing PASSED verdict for '$gate_name' — execution-evidence reports skipped:true (suite did not run). Either run the suite and re-capture evidence, or record verdict=UNVERIFIED."
                  fi
                fi
                ;;
            esac
            ;;
        esac
      fi

      # Resolve the SHA for the Reviewed SHA column. Default to the
      # worktree HEAD when not explicitly provided; "none" outside a git
      # work tree. This preserves backward compatibility — existing callers
      # that omit --sha get automatic HEAD binding.
      local resolved_sha="$sha_arg"
      if [ -z "$resolved_sha" ]; then
        local pp="${PROJECT_PATH:-.}"
        if git -C "$pp" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
          resolved_sha="$(git -C "$pp" rev-parse HEAD 2>/dev/null)" || resolved_sha="none"
        else
          resolved_sha="none"
        fi
      else
        # Explicit --sha: validate table-safety and hex format.
        _validate_table_value "--sha" "$resolved_sha"
        if [ "$resolved_sha" != "none" ]; then
          local pp="${PROJECT_PATH:-.}"
          resolved_sha="$(_validate_sha_arg "--sha" "$resolved_sha" "$pp")"
        fi
      fi

      # If --plan-id is present, write to the ledger (NOT the Review Gate table).
      if [ -n "$plan_id" ]; then
        ledger_write "$story_key" "$gate_name" "$plan_id" "$verdict"
      else
        # Update the story file's Review Gate table (byte-identical).
        cmd_update "$STORY_FILE" "$gate_name" "$verdict" "${report_path:-}" "$resolved_sha"
      fi

      # Test-artifacts mirror hook.
      # When the gate update carries a `--report <path>` AND the gate is
      # one of the three test-lens reviewers (QA Tests / Test Automation
      # / Test Review), mirror the report + execution-evidence under
      # .gaia/artifacts/test-artifacts/{epic}/{key}/ so the target layout's
      # symmetric test-lens mirror exists. The implementation-artifacts/
      # copy is unaffected — this hook is purely additive.
      if [ -n "$report_path" ] && [ -f "$report_path" ]; then
        _mirror_lib="$(cd "$(dirname "$0")" && pwd)/lib/test-artifacts-mirror.sh"
        if [ -f "$_mirror_lib" ]; then
          _mirror_type=""
          case "$gate_name" in
            "QA Tests")           _mirror_type="qa-tests" ;;
            "Test Automation")    _mirror_type="test-automation" ;;
            "Test Review")        _mirror_type="test-review" ;;
          esac
          if [ -n "$_mirror_type" ]; then
            # shellcheck source=/dev/null
            . "$_mirror_lib"
            test_artifacts_mirror_report "$story_key" "$report_path" "$_mirror_type" || true
            if [ -n "$execution_evidence" ] && [ -f "$execution_evidence" ]; then
              test_artifacts_mirror_evidence "$story_key" "$execution_evidence" "$_mirror_type" || true
            fi
          fi
        fi
      fi

      # Auto-emit review-summary.md.
      # Hook the per-story aggregator (review-summary-gen.sh) so EVERY gate
      # update (regardless of which review skill dispatched it) refreshes
      # the aggregator. The generator is idempotent (it's a render off the
      # current Review Gate table state) and treats a missing dispatched
      # skill stack as best-effort — failures don't break the gate write.
      if [ -z "$plan_id" ] && [ -n "$STORY_FILE" ]; then
        _summary_gen="$(cd "$(dirname "$0")" && pwd)/review-summary-gen.sh"
        if [ -x "$_summary_gen" ]; then
          # Default --output to the per-story reviews/ aggregator path so
          # Default --output to the per-story reviews/ aggregator path.
          _story_dir="$(dirname "$STORY_FILE")"
          _summary_out="$_story_dir/reviews/review-summary.md"
          mkdir -p "$_story_dir/reviews" 2>/dev/null || true
          STORY_FILE="$STORY_FILE" bash "$_summary_gen" \
            --story "$story_key" --output "$_summary_out" \
            >/dev/null 2>&1 || true
        fi
      fi

      # Brain knowledge-layer freshness hook: append a reviewed-in edge to the
      # story node in the brain-index manifest when a review lands with a
      # PASSED or FAILED verdict. UNVERIFIED is the seed state — nothing was
      # reviewed, so no edge is created. Best-effort — never fails the gate
      # write. Guarded by -x so it no-ops when the writer is absent.
      case "$verdict" in
        PASSED|FAILED)
          if [ -z "$plan_id" ] && [ -n "$story_key" ]; then
            _brain_update_sh="$(cd "$(dirname "$0")" && pwd)/brain/update-brain-index.sh"
            if [ -x "$_brain_update_sh" ]; then
              _brain_slug="$(printf '%s' "$gate_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
              _brain_edge_target="${_brain_slug}-${story_key}"
              _brain_manifest="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/knowledge/brain-index.yaml"
              "$_brain_update_sh" --manifest "$_brain_manifest" --add-edge \
                --target-key "$story_key" \
                --edge-type "reviewed-in" \
                --edge-target "$_brain_edge_target" >/dev/null 2>&1 || true
            fi
          fi
          ;;
      esac
      ;;
    carry-forward)
      # Carry-forward: re-bind a PASSED review verdict from one SHA to another
      # when the diff between the two SHAs has no files in the row's configured
      # scope globs. Evidence is ALWAYS self-computed from the diff — caller-
      # supplied evidence is refused (security: self-computed only).
      #
      # Pre-conditions (all must hold or the carry is refused):
      #   1. Row must currently be PASSED
      #   2. Row's recorded SHA must equal --from
      #   3. Configured scope globs must exist for the row (fail closed)
      #   4. Diff between --from and --to must have zero overlap with scope
      [ -n "$carry_row" ]  || die "carry-forward requires --row <name>"
      [ -n "$carry_from" ] || die "carry-forward requires --from <sha>"
      [ -n "$carry_to" ]   || die "carry-forward requires --to <sha>"

      # Refuse caller-supplied evidence (security: self-computed only).
      if [ -n "$carry_evidence" ]; then
        die "carry-forward: caller-supplied evidence is refused — evidence is self-computed from the diff (security policy)"
      fi

      # Use --gate if --row not provided via separate flag.
      if [ -z "$carry_row" ] && [ -n "$gate_name" ]; then
        carry_row="$gate_name"
      fi

      # Validate the gate name.
      if ! is_canonical_gate "$carry_row"; then
        local allowed_gates
        allowed_gates=$(join_by ', ' "${CANONICAL_GATES[@]}")
        die "carry-forward: invalid gate name '$carry_row' — allowed: $allowed_gates"
      fi

      local pp="${PROJECT_PATH:-.}"
      if ! git -C "$pp" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        die "carry-forward requires a git work tree (PROJECT_PATH=$pp is not inside one)"
      fi

      # Validate --from and --to as hex SHAs (security: prevent argument injection).
      carry_from="$(_validate_sha_arg "--from" "$carry_from" "$pp")"
      carry_to="$(_validate_sha_arg "--to" "$carry_to" "$pp")"

      # Pre-condition 1+2: verify the row is currently PASSED and bound to --from.
      load_canonical_rows "$STORY_FILE"
      local row_idx=-1 ci
      ci=0
      while [ "$ci" -lt "${#ROW_GATES[@]}" ]; do
        if [ "${ROW_GATES[$ci]}" = "$carry_row" ]; then
          row_idx=$ci
          break
        fi
        ci=$((ci + 1))
      done
      if [ "$row_idx" -eq -1 ]; then
        die "carry-forward: row '$carry_row' not found in Review Gate table"
      fi
      if [ "${ROW_STATUSES[$row_idx]}" != "PASSED" ]; then
        die "carry-forward: row '$carry_row' is ${ROW_STATUSES[$row_idx]}, not PASSED — only PASSED rows can be carried forward"
      fi
      local recorded_sha="${ROW_SHAS[$row_idx]:-}"
      if [ -z "$recorded_sha" ] || [ "$recorded_sha" = "absent" ]; then
        die "carry-forward: row '$carry_row' has no recorded SHA — cannot verify it matches --from"
      fi
      if [ "$recorded_sha" != "$carry_from" ]; then
        die "carry-forward: row '$carry_row' was reviewed on $recorded_sha, not $carry_from — SHA mismatch"
      fi

      # Pre-condition 3: read configured scope globs for this row.
      # Scope globs are configured under review_gate.scope_globs.<gate-slug>
      # in project-config.yaml. If no scope is configured, refuse (fail closed).
      local gate_slug
      gate_slug="$(printf '%s' "$carry_row" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
      local config_scope=""
      # Read scope globs from the shared config resolver (resolve-config.sh).
      # This honours GAIA_SHARED_CONFIG, local overrides and YAML escapes —
      # the same precedence as every other config key. The config path is
      # resolved here (walk-up + PROJECT_CONFIG + env roots) and passed via
      # --shared so the resolver does not need to re-discover it.
      local resolver="${_RG_DIR}/resolve-config.sh"
      if [ ! -f "$resolver" ]; then
        die "carry-forward: cannot locate resolve-config.sh — refusing (fail closed)"
      fi
      local config_file
      config_file="$(_resolve_config_path "$pp")"
      if [ -z "$config_file" ] || [ ! -f "$config_file" ]; then
        die "carry-forward: cannot locate project-config.yaml — refusing (fail closed)"
      fi
      config_scope="$(bash "$resolver" --shared "$config_file" \
        --field "review_gate.scope_globs.${gate_slug}" 2>/dev/null)" \
        || config_scope=""
      if [ -z "$config_scope" ]; then
        die "carry-forward: no scope globs configured for row '$carry_row' (gate slug: $gate_slug) — cannot determine file overlap; refusing (fail closed)"
      fi

      # Pre-condition 4: compute the diff and check for scope overlap.
      # Uses git diff with :(glob) pathspecs for correct glob semantics:
      # ** matches zero or more directories, * doesn't cross /, ? matches
      # one char, [abc] is a character class. --no-renames ensures renamed
      # files appear as delete + add (a file moved out of scope is caught).
      # -z avoids C-quoting of non-ASCII / special chars.

      # Build the pathspec arguments from scope globs.
      # Validate each glob: refuse patterns with unclosed brackets (which
      # git silently treats as matching nothing, causing a fail-open).
      local -a pathspec_args=()
      local scope_line
      while IFS= read -r scope_line; do
        [ -z "$scope_line" ] && continue
        # Detect unclosed bracket: count unescaped '[' and ']'.
        local _open _close
        _open="$(printf '%s' "$scope_line" | tr -cd '[' | wc -c)"
        _close="$(printf '%s' "$scope_line" | tr -cd ']' | wc -c)"
        _open="${_open##* }"
        _close="${_close##* }"
        if [ "$_open" -ne "$_close" ]; then
          die "carry-forward: invalid scope glob pattern '$scope_line' (unclosed bracket) — refusing (fail closed)"
        fi
        pathspec_args+=(":(glob)${scope_line}")
      done <<< "$config_scope"

      # Check for overlap: if git diff with the scope pathspecs returns any
      # paths, there is an overlap and the carry-forward must be refused.
      # Unset pathspec-mode env vars that would disable :(glob) magic.
      local overlap_output overlap_rc
      overlap_output="$(env -u GIT_LITERAL_PATHSPECS -u GIT_NOGLOB_PATHSPECS \
        -u GIT_ICASE_PATHSPECS -u GIT_GLOB_PATHSPECS \
        git -C "$pp" diff -z --no-renames --name-only \
        "$carry_from" "$carry_to" -- "${pathspec_args[@]}" 2>&1)" \
        && overlap_rc=0 || overlap_rc=$?
      if [ "$overlap_rc" -ne 0 ] && [ "$overlap_rc" -ne 1 ]; then
        # rc=1 means no diff (empty output); rc > 1 or error text → tool failure.
        # Any tool error → refuse (fail closed).
        die "carry-forward: git diff with scope pathspecs failed (rc=$overlap_rc) — refusing (fail closed)"
      fi
      if [ -n "$overlap_output" ]; then
        die "carry-forward: diff between $carry_from and $carry_to includes files in scope — review must be re-run"
      fi

      # Get the full diff (all paths, no pathspec filter) for evidence.
      # Read via process substitution with NUL delimiter to preserve paths
      # that contain spaces, tabs, newlines or non-ASCII characters.
      # Command substitution drops NUL bytes, so we use read -d '' instead.
      local -a diff_paths=()
      while IFS= read -r -d '' p; do
        diff_paths+=("$p")
      done < <(git -C "$pp" diff -z --no-renames --name-only \
        "$carry_from" "$carry_to" 2>/dev/null)

      # Build the evidence JSON arrays.
      local changed_json="[]"
      if [ "${#diff_paths[@]}" -gt 0 ]; then
        changed_json="["
        local _i
        for _i in "${!diff_paths[@]}"; do
          [ "$_i" -gt 0 ] && changed_json="${changed_json},"
          local _escaped="${diff_paths[$_i]}"
          _escaped="${_escaped//\\/\\\\}"
          _escaped="${_escaped//\"/\\\"}"
          changed_json="${changed_json}\"${_escaped}\""
        done
        changed_json="${changed_json}]"
      fi
      local globs_json
      globs_json="$(printf '%s\n' "$config_scope" | awk '
        BEGIN { printf "[" }
        /^[[:space:]]*$/ { next }
        c++ > 0 { printf "," }
        { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); printf "\"%s\"", $0 }
        END { printf "]" }
      ')"

      # Write carry-forward sidecar record FIRST (before rebinding the row).
      # If the sidecar write fails, the row keeps its old SHA — no binding
      # without a record.
      local story_dir
      story_dir="$(dirname "$STORY_FILE")"
      local sidecar="${story_dir}/review-gate-carry.jsonl"

      # Refuse to write through a symlink (the sidecar must be a regular file).
      if [ -L "$sidecar" ]; then
        die "carry-forward: sidecar path is a symlink — refusing (security policy)"
      fi

      local ts
      ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      local record
      record="$(printf '{"row":"%s","from_sha":"%s","to_sha":"%s","evidence":{"changed_paths":%s,"scope_globs":%s},"timestamp":"%s"}' \
        "$carry_row" "$carry_from" "$carry_to" "$changed_json" "$globs_json" "$ts")"
      # Atomic append via temp file + cat (safe on concurrent appends).
      local sidecar_tmp
      sidecar_tmp="$(mktemp "${story_dir}/.carry-tmp.XXXXXX")"
      printf '%s\n' "$record" > "$sidecar_tmp"
      cat "$sidecar_tmp" >> "$sidecar" || {
        rm -f "$sidecar_tmp"
        die "carry-forward: failed to write sidecar record — refusing to rebind row"
      }
      rm -f "$sidecar_tmp"

      # Now rebind the row's SHA to the to-SHA. Keep the existing report path.
      local current_report="—"
      local parsed_gate _parsed_status parsed_report parsed_sha
      while IFS=$'\t' read -r parsed_gate _parsed_status parsed_report parsed_sha; do
        if [ "$parsed_gate" = "$carry_row" ]; then
          current_report="$parsed_report"
          break
        fi
      done < <(parse_gate_rows "$STORY_FILE")

      cmd_update "$STORY_FILE" "$carry_row" "PASSED" "$current_report" "$carry_to"

      printf 'carry-forward: %s bound from %s to %s\n' \
        "$carry_row" "$carry_from" "$carry_to"
      ;;
  esac
}

main "$@"
