#!/usr/bin/env bash
# review-gate.sh — GAIA foundation script (E28-S14)
#
# Parses and atomically updates the `## Review Gate` table in a story markdown
# file. Consumed by the six review workflows (code-review, qa-tests,
# security-review, test-automate, test-review, review-perf) and their
# aggregator (run-all-reviews), which previously rewrote the table via LLM
# edits — one engine token-burn path per ADR-042 / NFR-048.
#
# Refs: FR-325, FR-328, NFR-048, ADR-042, ADR-048
# Brief: P2-S6 (.gaia/artifacts/creative-artifacts/gaia-native-conversion-feature-brief-2026-04-14.md)
#
# Invocation contract (stable for E28-S17 bats-core authors):
#
#   review-gate.sh check             --story <key>
#   review-gate.sh update            --story <key> --gate <name> --verdict <PASSED|FAILED|UNVERIFIED> [--plan-id <id>]
#   review-gate.sh status            --story <key> [--gate <name> --plan-id <id>]
#   review-gate.sh review-gate-check --story <key>
#   review-gate.sh --help
#
# Canonical gate names (case-sensitive, exact):
#   "Code Review" | "QA Tests" | "Security Review"
#   "Test Automation" | "Test Review" | "Performance Review"
#
# Fork-context read-only allowlist (NFR-CRG-2):
#   The `review-gate-check` sub-operation is a pure read and is safe to
#   invoke from a subagent whose tool allowlist is `Read`, `Grep`, `Bash`
#   only (no `Write`, no `Edit`). It never modifies the story file,
#   creates tempfiles / lockfiles / sidecar scratch files, or touches
#   sprint-status.yaml.
#
# Extended gate name (requires --plan-id, E35-S2):
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
#     convention as sprint-state.sh (E28-S11). Aligned by E28-S99.
#
# Story file location (flat layout — aligned with sprint-state.sh per E28-S99):
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
#   checkpoint.sh §E28-S10 and lifecycle-event.sh §E28-S12.
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

SCRIPT_NAME="review-gate.sh"

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

# Extended gate names — require --plan-id to be present (E35-S2, E33-S1).
# "story-validation" (E33-S1) records the terminal verdict of the Val +
# SM fix-loop pattern from ADR-050 without overwriting the six canonical
# Review Gate table rows (which belong to the six downstream review
# commands). Uses the same ledger-keyed path as test-automate-plan.
PLAN_ID_GATES=("test-automate-plan" "story-validation")

# plan_id canonical regex: alphanumerics plus ._:+- (AC-EC2 security guard).
# Permissive for UUIDs and timestamp-nonce fallbacks; strict against shell injection.
PLAN_ID_REGEX='^[A-Za-z0-9._:+-]+$'

# Ledger path: overridable via --ledger flag or $REVIEW_GATE_LEDGER env var.
# E96-S3 / ADR-111: default prefers .gaia/state/.review-gate-ledger
# (mutable-runtime-state tier) over the legacy <project-root>/.review-gate-ledger.
# Legacy fallback retained during the 1-sprint transition window (removed in E96-S5).
resolve_ledger_path() {
  if [ -n "${LEDGER_FLAG:-}" ]; then
    printf '%s' "$LEDGER_FLAG"
  elif [ -n "${REVIEW_GATE_LEDGER:-}" ]; then
    printf '%s' "$REVIEW_GATE_LEDGER"
  else
    local root="${PROJECT_PATH:-.}"
    if [ -f "$root/.gaia/state/.review-gate-ledger" ] || [ -d "$root/.gaia/state" ]; then
      printf '%s' "$root/.gaia/state/.review-gate-ledger"
    else
      printf '%s' "$root/.review-gate-ledger"
    fi
  fi
}

# ---------- Helpers ----------

die() {
  # message…  (always exit 1)
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  review-gate.sh check             --story <key>
  review-gate.sh update            --story <key> --gate <name> --verdict <PASSED|FAILED|UNVERIFIED> [--plan-id <id>]
  review-gate.sh status            --story <key> [--gate <name> --plan-id <id>]
  review-gate.sh review-gate-check --story <key>
  review-gate.sh --help

Subcommands:
  check             Exit 0 iff all six Review Gate rows are PASSED. Otherwise
                    exit 1 and list the non-PASSED gate names on stderr (one
                    per line).
  update            Atomically rewrite exactly one row of the Review Gate
                    table. Only the Status and Report cells of the matched
                    gate are changed — all other bytes of the story file are
                    preserved (headers, blank lines, other rows, trailing
                    content). Writes are serialized via flock. When --plan-id
                    is provided, the verdict is written to the ledger file
                    instead (tab-separated: story_key gate plan_id verdict).
  status            Print a single JSON object to stdout via jq -nc. Without
                    --plan-id, returns the full Review Gate table. With
                    --gate and --plan-id, queries the ledger for the
                    (story_key, gate, plan_id) tuple.
  review-gate-check Composite Review Gate check (E37-S1, ADR-054, FR-CRG-2).
                    Reads the six Review Gate rows and prints the table
                    followed by a summary line:
                      Review Gate: COMPLETE   (exit 0) — all six PASSED
                      Review Gate: BLOCKED    (exit 1) — any FAILED
                                              (FAILED dominates over PENDING)
                      Review Gate: PENDING    (exit 2) — any UNVERIFIED or
                                              NOT STARTED and no FAILED
                    On BLOCKED, a "Blocking gates:" list names each FAILED
                    row. On PENDING, a "Pending gates:" list names each
                    UNVERIFIED / NOT STARTED row. On COMPLETE no list is
                    emitted. Stderr is empty on all three success paths.
                    Read-only (NFR-CRG-1): zero file writes, zero lockfile
                    or tempfile creation. Safe to invoke under a subagent
                    read-only allowlist of Read, Grep, Bash (NFR-CRG-2).

Flags:
  --story <key>      Story key (required for all subcommands).
  --gate <name>      Gate name (required for update; optional for status).
  --verdict <V>      Verdict value (required for update).
  --plan-id <id>     Plan identifier for ledger-keyed verdicts (E35-S2).
                     Must match [A-Za-z0-9._:+-]+. Required for the
                     "test-automate-plan" gate; optional for canonical gates.
  --ledger <path>    Override ledger file path (default: $PROJECT_PATH/.review-gate-ledger
                     or $REVIEW_GATE_LEDGER env var).
  --report <path>    AF-2026-05-20-1 proof-of-execution: path to the
                     per-review report file written by the dispatched skill.
                     Required for PASSED / FAILED verdicts (refused if file
                     does not exist). Not required for UNVERIFIED (seed).
  --execution-evidence <path>
                     AF-2026-05-20-1 proof-of-execution: path to
                     execution-evidence.json. Required (in addition to
                     --report) for test-execution gates: "QA Tests",
                     "Test Automation", "Test Review".
  --report-missing-reason <reason>
                     AF-2026-05-20-1 explicit escape hatch when no report
                     exists (e.g. FAILED verdict with no salvageable report).
                     Suppresses the --report / --execution-evidence checks
                     and records the reason in the audit log.

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
# Adopted from sprint-state.sh (E28-S11) per E28-S99.
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
# Aligned with sprint-state.sh (E28-S11) per E28-S99: uses flat
# IMPLEMENTATION_ARTIFACTS directory, not a stories/ subdirectory.
STORY_FILE=""
locate_story_file() {
  local key="$1"
  local project_path="${PROJECT_PATH:-.}"
  # E96-S6 (ADR-111): prefer .gaia/artifacts/implementation-artifacts/ when
  # present on disk; fall back to legacy docs/ during the deprecation window.
  # IMPLEMENTATION_ARTIFACTS env-var override wins over both.
  local impl_artifacts
  if [ -n "${IMPLEMENTATION_ARTIFACTS:-}" ]; then
    impl_artifacts="$IMPLEMENTATION_ARTIFACTS"
  elif [ -d "${project_path}/.gaia/artifacts/implementation-artifacts" ]; then
    impl_artifacts="${project_path}/.gaia/artifacts/implementation-artifacts"
  else
    impl_artifacts="${project_path}/docs/implementation-artifacts"
  fi
  local pattern="${impl_artifacts}/${key}-*.md"
  local epic_pattern="${impl_artifacts}/epic-*/stories/${key}-*.md"
  # NEW per-story layout (E105-S1 / ADR-127): epic-{slug}/{key}-{slug}/story.md.
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
# Unknown gate names are preserved in the file (AC-EC3: spurious rows are
# left untouched on update) but ignored for check/status vocabulary checks.

# Stream parsed rows to stdout as TSV `GATE\tSTATUS\tREPORT`.
# Exits 1 (via die) if the `## Review Gate` header is absent.
parse_gate_rows() {
  local file="$1"

  # First: confirm the `## Review Gate` header exists. awk-only detection is
  # cheaper and gives a precise error message per AC8.
  if ! grep -q '^## Review Gate[[:space:]]*$' "$file"; then
    die "story file '$file' is missing the '## Review Gate' section"
  fi

  awk '
    BEGIN { in_section = 0; in_table = 0; saw_sep = 0 }
    /^## Review Gate[[:space:]]*$/ { in_section = 1; in_table = 0; saw_sep = 0; next }
    in_section && /^## / {
      # A new h2 header terminates the section.
      in_section = 0; in_table = 0; next
    }
    !in_section { next }

    # Inside the section. Look for the first pipe-table.
    {
      # Strip trailing \r so CRLF files parse correctly (AC-EC7).
      sub(/\r$/, "", $0)
    }

    in_section && !in_table {
      # Header row starts the table (first line beginning with |).
      if ($0 ~ /^[[:space:]]*\|/) {
        in_table = 1
        saw_sep = 0
        next
      }
      next
    }

    in_table {
      # End of table: blank line or non-pipe line.
      if ($0 !~ /^[[:space:]]*\|/) {
        in_table = 0
        in_section = 0
        next
      }

      # Separator row (| --- | --- | --- |) — skip exactly one.
      if (!saw_sep && $0 ~ /^[[:space:]]*\|[[:space:]]*-+/) {
        saw_sep = 1
        next
      }

      # Data row. Strip leading/trailing pipe and whitespace, split on |.
      line = $0
      sub(/^[[:space:]]*\|/, "", line)
      sub(/\|[[:space:]]*$/, "", line)
      n = split(line, cells, /\|/)
      if (n < 3) next

      # Trim each cell.
      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", cells[i])
      }

      # Emit TSV: GATE \t STATUS \t REPORT
      printf "%s\t%s\t%s\n", cells[1], cells[2], cells[3]
    }
  ' "$file"
}

# Populate two parallel global arrays ROW_GATES / ROW_STATUSES from the parsed
# table, keeping only the canonical six gates (in canonical order). Exits 1
# if any canonical gate is missing from the table (per AC3 / Task 3.4).
ROW_GATES=()
ROW_STATUSES=()
load_canonical_rows() {
  local file="$1"

  # Reset globals.
  ROW_GATES=()
  ROW_STATUSES=()

  # Collect parsed rows into two temp arrays keyed by gate name.
  local -a parsed_gates=()
  local -a parsed_statuses=()

  local gate status _report
  while IFS=$'\t' read -r gate status _report; do
    [ -z "$gate" ] && continue
    parsed_gates+=("$gate")
    parsed_statuses+=("$status")
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

# ---------- Ledger operations (E35-S2) ----------
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

  local tmpfile="${ledger_path}.tmp.$$"

  # Atomic append: copy existing content + new row → tmpfile, then mv.
  {
    if [ -f "$ledger_path" ]; then
      cat "$ledger_path"
    fi
    printf '%s\t%s\t%s\t%s\n' "$story_key" "$gate" "$plan_id" "$verdict"
  } > "$tmpfile"

  if ! mv -f "$tmpfile" "$ledger_path"; then
    rm -f "$tmpfile"
    die "failed to write ledger at '$ledger_path'"
  fi
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

# ---------- Subcommand: review-gate-check (E37-S1) ----------
#
# Composite Review Gate check per ADR-054 / FR-CRG-2. Emits the six-row
# Review Gate table verbatim followed by a summary line and — on the
# BLOCKED or PENDING paths — a list of the offending gate names. Exit
# codes are deterministic:
#
#   0 — COMPLETE: all six gates have verdict PASSED
#   1 — BLOCKED:  at least one gate is FAILED (FAILED dominates PENDING)
#   2 — PENDING:  at least one gate is UNVERIFIED / NOT STARTED and
#                 no gate is FAILED
#
# Read-only (NFR-CRG-1): zero file writes, zero tempfile / mv / flock. The
# sub-operation only parses the story file — it never creates, modifies,
# or deletes any file or sidecar. Before/after shasum -a 256 of the story
# file is byte-identical across all three verdict paths.
#
# Fork-context (NFR-CRG-2): safe to invoke under a subagent whose tool
# allowlist is Read, Grep, Bash only — the execution path uses awk / grep
# / bash built-ins and the existing locate_story_file helper.

# Classify the six canonical verdicts into a composite status. Used as a
# standalone helper so callers and unit tests can exercise the decision
# logic independently of I/O. Echoes exactly one of: COMPLETE | BLOCKED |
# PENDING. This helper is pure — no side effects — and is the canonical
# source of ADR-054 dominance rules.
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
      # Unknown verdict — treat as PENDING (safe fallback; matches the
      # ADR-054 "UNVERIFIED equivalence" clause for non-canonical text).
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

  # Parse the six Report cells out of the parsed TSV stream so the table
  # we render preserves whatever the story author wrote in the Report
  # column (typically the em-dash placeholder, sometimes a review-file URL).
  local -a report_for_gate=()
  local parsed_gate parsed_status parsed_report i found
  local cg
  for cg in "${CANONICAL_GATES[@]}"; do
    found=0
    while IFS=$'\t' read -r parsed_gate parsed_status parsed_report; do
      if [ "$parsed_gate" = "$cg" ]; then
        report_for_gate+=("$parsed_report")
        found=1
        break
      fi
    done < <(parse_gate_rows "$file")
    if [ $found -eq 0 ]; then
      # Should be impossible — load_canonical_rows already enforced row
      # presence — but guard defensively so the read loop never leaves
      # report_for_gate short.
      report_for_gate+=("—")
    fi
  done

  # Render the six-row markdown table exactly as a story file stores it.
  printf '| Review | Status | Report |\n'
  printf '|--------|--------|--------|\n'
  i=0
  while [ $i -lt "${#ROW_GATES[@]}" ]; do
    printf '| %s | %s | %s |\n' \
      "${ROW_GATES[$i]}" "${ROW_STATUSES[$i]}" "${report_for_gate[$i]}"
    i=$((i + 1))
  done

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
# Status cell of the matched gate with $new_verdict and the Report cell with
# "—" (the canonical empty-report placeholder used by all six review
# workflows). All other bytes are preserved. Runs under flock and uses
# tempfile + atomic mv.
cmd_update() {
  local file="$1"
  local gate_name="$2"
  local new_verdict="$3"

  # Validate the section exists (produces a precise error per AC8).
  # We also validate by loading canonical rows — this enforces Task 3.4.
  load_canonical_rows "$file"

  local lockfile="${file}.lock"
  local tmpfile="${file}.tmp.$$"

  local flock_bin
  flock_bin=$(command -v flock || true)

  rewrite_body() {
    # Stream $file through awk, rewriting only the first data row of the
    # first pipe-table under `## Review Gate` whose first cell matches
    # $gate_name. Preserve CRLF (AC-EC7) and all surrounding bytes.
    awk -v target="$gate_name" -v new_status="$new_verdict" -v new_report="—" '
      BEGIN { in_section = 0; in_table = 0; saw_sep = 0; rewritten = 0 }

      # Detect `## Review Gate` header. We preserve the line verbatim
      # (including any trailing \r) and track state off a stripped copy.
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
        # New h2 terminates the section.
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
          print raw
          next
        }

        if (rewritten) {
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
          print raw
          next
        }

        # Rewrite this row. Preserve CRLF if the original had one.
        crlf = ""
        if (raw ~ /\r$/) { crlf = "\r" }
        printf "| %s | %s | %s |%s\n", target, new_status, new_report, crlf
        rewritten = 1
        next
      }

      { print raw }

      END {
        if (!rewritten) {
          # Signal failure to the caller via exit code 2.
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

  if [ -n "$flock_bin" ]; then
    (
      exec 9>"$lockfile"
      if ! "$flock_bin" -w 5 9; then
        die "flock timeout acquiring $lockfile"
      fi
      do_update
    )
  else
    # Fallback: bounded spin-loop with O_EXCL lockfile create. Same pattern
    # used in checkpoint.sh / lifecycle-event.sh for macOS /bin/bash 3.2
    # without Homebrew util-linux flock.
    local tries=0
    while ! ( set -C; : > "$lockfile" ) 2>/dev/null; do
      tries=$((tries + 1))
      if [ $tries -ge 50 ]; then
        die "lock timeout acquiring $lockfile"
      fi
      sleep 0.1
    done
    # shellcheck disable=SC2064
    trap "rm -f '$lockfile'" EXIT
    do_update
    rm -f "$lockfile"
    trap - EXIT
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
    check|update|status|review-gate-check)
      ;;
    *)
      printf '%s: unknown subcommand: %s\n' "$SCRIPT_NAME" "$subcmd" >&2
      usage >&2
      exit 1
      ;;
  esac

  local story_key="" gate_name="" verdict="" plan_id=""
  # AF-2026-05-20-1 proof-of-execution flags:
  # --report <path> — path to the per-review report file written by the dispatched skill.
  # --execution-evidence <path> — path to execution-evidence.json (required for test-execution gates).
  # --report-missing-reason <reason> — explicit escape hatch for cases where no report exists
  #   (e.g. UNVERIFIED seed rows, FAILED verdicts with no salvageable report).
  local report_path="" execution_evidence="" report_missing_reason=""
  LEDGER_FLAG=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --story)
        [ $# -ge 2 ] || die "--story requires a value"
        story_key="$2"; shift 2
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
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown flag: $1"
        ;;
    esac
  done

  # Validate plan_id if provided (AC-EC2, AC-EC3 security guards).
  if [ -n "$plan_id" ]; then
    validate_plan_id "$plan_id"
  fi

  [ -n "$story_key" ] || die "$subcmd requires --story <key>"

  # For plan-id-only gates (ledger path), locate_story_file is still required
  # to ensure the story exists before recording any verdict.
  locate_story_file "$story_key"

  case "$subcmd" in
    check)
      cmd_check "$STORY_FILE"
      ;;
    review-gate-check)
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

      # AF-2026-05-20-1 proof-of-execution gate.
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
                ;;
            esac
            ;;
        esac
      fi

      # If --plan-id is present, write to the ledger (NOT the Review Gate table).
      if [ -n "$plan_id" ]; then
        ledger_write "$story_key" "$gate_name" "$plan_id" "$verdict"
      else
        # Pre-E35 path: update the story file's Review Gate table (byte-identical).
        cmd_update "$STORY_FILE" "$gate_name" "$verdict"
      fi
      ;;
  esac
}

main "$@"
