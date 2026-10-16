#!/usr/bin/env bash
# verdict.sh — gaia-test-dast Phase 4 verdict + Review Gate update.
#
# Reads the Phase 3A analysis-results.json and the Phase 3B llm-findings.json,
# invokes verdict-resolver.sh to compute the verdict (APPROVE | REQUEST_CHANGES
# | BLOCKED), and (when --story-key is provided AND --gate is provided) updates
# the corresponding Review Gate row via review-gate.sh.
#
# Verdict to gate-row mapping:
#   APPROVE          -> PASSED
#   REQUEST_CHANGES  -> FAILED
#   BLOCKED          -> FAILED
#
# Default --gate is "Security Review" — DAST findings update the Security
# Review row of the canonical six-row Review Gate seeded by init-review-gate.sh.
#
# When --register is given (with --story-key), findings from the llm-findings
# file are written to the shared findings register via register-write.sh,
# a run record is created, and the verdict is resolved against the register
# instead of the raw llm-findings file. In register mode, --llm-findings must
# still point to a readable, non-empty JSON file with a .findings array;
# omitted, unreadable, empty, or malformed input blocks the gate (never
# silently approves).
#
# Contract:
#   verdict.sh --analysis-results <path> --llm-findings <path>
#               [--story-key <key>] [--gate <name>]
#   verdict.sh --analysis-results <path> --llm-findings <path>
#               --story-key <key> --register [--run-id <id>] [--gate <name>]
#
# Stdout: emits the verdict on the last line. Exit 0 on success, 1 on caller error.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-test-dast/verdict.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Prefer the review-common location and fall back to the top-level
# scripts/verdict-resolver.sh for backward compatibility.
if [ -x "$PLUGIN_ROOT/scripts/review-common/verdict-resolver.sh" ]; then
  RESOLVER="$PLUGIN_ROOT/scripts/review-common/verdict-resolver.sh"
else
  RESOLVER="$PLUGIN_ROOT/scripts/verdict-resolver.sh"
fi
GATE="$PLUGIN_ROOT/scripts/review-gate.sh"
REGISTER_WRITER="$PLUGIN_ROOT/scripts/review-common/register-write.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

ANALYSIS=""
LLM=""
STORY_KEY=""
GATE_NAME="Security Review"
REGISTER_MODE=0
RUN_ID=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --analysis-results) ANALYSIS="$2"; shift 2 ;;
    --llm-findings)     LLM="$2"; shift 2 ;;
    --story-key)        STORY_KEY="$2"; shift 2 ;;
    --gate)             GATE_NAME="$2"; shift 2 ;;
    --register)         REGISTER_MODE=1; shift ;;
    --run-id)           [ "$#" -ge 2 ] || die "--run-id requires a value"
                        RUN_ID="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
$SCRIPT_NAME — verdict resolution + Review Gate update for /gaia-test-dast.
Usage:
  verdict.sh --analysis-results <path> --llm-findings <path>
              [--story-key <key>] [--gate <name>]
  verdict.sh --analysis-results <path> --llm-findings <path>
              --story-key <key> --register [--run-id <id>]
EOF
      exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[ -n "$ANALYSIS" ] || die "--analysis-results required"
[ -r "$ANALYSIS" ] || die "analysis-results not readable: $ANALYSIS"
[ -x "$RESOLVER" ] || die "verdict-resolver.sh not found at $RESOLVER"

# Register gate ID for DAST: maps "Security Review" -> "security-review"
REGISTER_GATE="security-review"

# A story key implies register mode: the register is the default path
# whenever a story is identified, so the prose and the code stay aligned.
if [ -n "$STORY_KEY" ] && [ "$REGISTER_MODE" -eq 0 ]; then
  REGISTER_MODE=1
fi

if [ "$REGISTER_MODE" -eq 1 ]; then
  [ -n "$STORY_KEY" ] || die "--story-key required when --register is given"
  [ -x "$REGISTER_WRITER" ] || die "register-write.sh not found at $REGISTER_WRITER"

  # Derive register path from the canonical resolver.
  REGISTER_PATH="$("$PLUGIN_ROOT/scripts/resolve-review-report-path.sh" --key "$STORY_KEY" --type findings-register)"

  # Mint a standalone run-id when not orchestrated.
  RUN_ID="${RUN_ID:-standalone-$(date -u +%Y%m%dT%H%M%SZ)-$$}"

  # Validate and write each LLM finding to the register.
  # In register mode every failure path must set _write_failed=1 so the
  # gate becomes BLOCKED — a silently skipped findings file must never
  # produce APPROVE.
  _write_failed=0
  if [ -z "$LLM" ]; then
    log "llm findings path not provided; gate will be BLOCKED"
    _write_failed=1
  elif [ ! -r "$LLM" ]; then
    log "llm findings not readable: $LLM; gate will be BLOCKED"
    _write_failed=1
  elif [ ! -s "$LLM" ]; then
    log "llm findings file is empty: $LLM; gate will be BLOCKED"
    _write_failed=1
  elif ! jq -e -s 'length == 1 and (.[0] | type == "object") and (.[0].findings | type == "array") and all(.[0].findings[]; type == "object")' "$LLM" >/dev/null 2>&1; then
    log "llm findings malformed (must be a single JSON object with an array of objects in .findings): $LLM; gate will be BLOCKED"
    _write_failed=1
  else
    finding_count="$(jq '.findings | length' "$LLM")"
    # Guard: finding_count must be a non-negative integer.
    case "$finding_count" in
      ''|*[!0-9]*) log "finding_count is not a valid integer: $finding_count; gate will be BLOCKED"; _write_failed=1 ;;
    esac
    i=0
    while [ "$_write_failed" -eq 0 ] && [ "$i" -lt "$finding_count" ]; do
      msg="$(jq -r ".findings[$i].message // .findings[$i].title // \"\"" "$LLM")"
      sev="$(jq -r ".findings[$i].severity // \"medium\"" "$LLM")"
      cat_val="$(jq -r ".findings[$i].category // \"\"" "$LLM")"
      file_val="$(jq -r ".findings[$i].file // \"\"" "$LLM")"
      line_val="$(jq -r ".findings[$i].line // 0" "$LLM")"
      rule_val="$(jq -r ".findings[$i].rule // \"\"" "$LLM")"

      # Build evidence string.
      evidence=""
      if [ -n "$rule_val" ]; then evidence="$rule_val"; fi
      if [ -n "$file_val" ] && [ "$file_val" != "null" ]; then
        if [ -n "$evidence" ]; then
          evidence="$evidence at ${file_val}:${line_val}"
        else
          evidence="${file_val}:${line_val}"
        fi
      fi

      # Build dedup key.
      if [ -n "$file_val" ] && [ "$file_val" != "null" ]; then
        dedup="${file_val}:${line_val}:${cat_val}"
      else
        msg_hash="$(printf '%s' "$msg" | shasum -a 256 | cut -c1-16)"
        dedup="${REGISTER_GATE}:${rule_val:-$cat_val}:${msg_hash}"
      fi

      # Normalise non-standard severity labels (e.g. "Critical Risk",
      # "Informational") to the rubric scale before writing.
      case "$(printf '%s' "$sev" | tr '[:upper:]' '[:lower:]')" in
        critical*) sev="critical" ;;
        high*)     sev="high" ;;
        medium*|moderate*) sev="medium" ;;
        low*|informational*|info*|none*) sev="low" ;;
      esac

      # DAST findings are always type "security". A failed write means a
      # finding was lost; the gate must be BLOCKED, never APPROVE.
      if ! "$REGISTER_WRITER" add \
        --story "$STORY_KEY" --defect "$msg" --type security \
        --severity "$sev" --gate "$REGISTER_GATE" \
        --evidence "$evidence" --dedup-key "$dedup" 2>>"$ANALYSIS.register-err.log"; then
        log "register-write add failed for finding $i (severity=$sev); gate will be BLOCKED"
        _write_failed=1
        break  # stop immediately — remaining writes would each wait the full lock timeout
      fi

      i=$((i + 1))
    done
  fi

  # When any register write failed, record the run as errored so the gate
  # stays BLOCKED; a lost finding must never produce APPROVE.
  _run_outcome="completed"
  if [ "${_write_failed:-0}" = "1" ]; then
    _run_outcome="errored"
  fi

  # Record this gate's run.
  if ! "$REGISTER_WRITER" record-run \
    --story "$STORY_KEY" --run-id "$RUN_ID" \
    --gate "$REGISTER_GATE" --outcome "$_run_outcome" 2>>"$ANALYSIS.register-err.log"; then
    log "record-run failed; gate is BLOCKED"
    verdict="BLOCKED"
  elif [ "${_write_failed:-0}" = "1" ]; then
    verdict="BLOCKED"
  else
    # Resolve verdict from the register.
    verdict="$("$RESOLVER" --skill gaia-test-dast --register "$REGISTER_PATH" --analysis-results "$ANALYSIS")" \
      || die "verdict-resolver.sh failed"
  fi
else
  # Legacy path: --llm-findings required.
  [ -n "$LLM" ]  || die "--llm-findings required"
  [ -r "$LLM" ]  || die "llm-findings not readable: $LLM"

  verdict="$("$RESOLVER" --skill gaia-test-dast --analysis-results "$ANALYSIS" --llm-findings "$LLM")" \
    || die "verdict-resolver.sh failed"
fi

if [ -n "$STORY_KEY" ] && [ -n "$GATE_NAME" ] && [ -x "$GATE" ]; then
  case "$verdict" in
    APPROVE)         gate_status="PASSED" ;;
    REQUEST_CHANGES) gate_status="FAILED" ;;
    BLOCKED)         gate_status="FAILED" ;;
    *)               gate_status="UNVERIFIED" ;;
  esac
  _gate_args=""
  case "$gate_status" in
    FAILED)
      _gate_args="--report-missing-reason verdict-only:${verdict}"
      ;;
  esac
  # shellcheck disable=SC2086
  if "$GATE" update --story "$STORY_KEY" --gate "$GATE_NAME" --verdict "$gate_status" $_gate_args 2>>"$ANALYSIS.gate.log"; then
    log "review-gate updated: story=$STORY_KEY gate=$GATE_NAME verdict=$gate_status"
  else
    log "WARN: review-gate update failed (see $ANALYSIS.gate.log)"
  fi
fi

printf '%s\n' "$verdict"
exit 0
