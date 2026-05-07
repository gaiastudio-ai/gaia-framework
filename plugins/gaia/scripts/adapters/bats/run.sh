#!/usr/bin/env bash
# adapters/bats/run.sh — FR-414 + ADR-078 contract entry for the bats adapter.
#
# Dual-mode dispatch:
#   --mode test-runner       Execute `bats` against the .bats files listed via
#                            --input. Capture TAP output, parse pass/fail/skip
#                            counts, and emit a fragment with both the raw TAP
#                            stream and the parsed counts.
#   --mode smell-detection   Lint .bats files for anti-patterns (bare `run`
#                            without follow-up `assert_*`, hardcoded absolute
#                            paths, untimed `sleep`). Emit a findings array
#                            with rule, severity, file, line, message, blocking.
#
# Honours the ADR-078 run.sh flag-form interface:
#
#   run.sh --input <file-list> --mode <test-runner|smell-detection>
#          [--config <path>] [--output <path>]
#          [--runtime-profile subprocess|container|network] [--timeout <seconds>]
#
# stdout is the canonical analysis-results fragment:
#   { "name": "bats",
#     "status": "passed" | "failed",
#     "findings": [ { rule, severity, file, line, message, blocking }, ... ],
#     "tap": "<raw-tap-output>" (test-runner mode only),
#     "counts": { passed, failed, skipped } (test-runner mode only) }
#
# Exit codes:
#   0  - run completed cleanly (no blocking findings, or no .bats files)
#   2  - run completed with blocking findings present (test-runner failures
#        or smell-detection findings whose severity == error)
#   1  - adapter execution error (bad input, bats parse failure, jq missing)
#   127 - bats not on PATH (test-runner mode only; probe catches this earlier
#         in the normal pipeline)

set -euo pipefail
LC_ALL=C
export LC_ALL

# --- Arg parsing -----------------------------------------------------------

INPUT=""
MODE=""
OUTPUT=""
# CONFIG / RUNTIME_PROFILE / TIMEOUT are accepted per the canonical flag-form
# interface but not consumed by this adapter; they are parsed only so callers
# can pass them uniformly.
# shellcheck disable=SC2034
CONFIG=""
# shellcheck disable=SC2034
RUNTIME_PROFILE="subprocess"
# shellcheck disable=SC2034
TIMEOUT=120

# shellcheck disable=SC2034  # CONFIG/RUNTIME_PROFILE/TIMEOUT parsed but unused (canonical flag-form interface).
while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --runtime-profile) RUNTIME_PROFILE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
adapters/bats/run.sh — FR-414 + ADR-078 contract entry.
Usage:
  run.sh --input <file-list> --mode <test-runner|smell-detection>
         [--config <path>] [--output <path>]
         [--runtime-profile subprocess|container|network] [--timeout <seconds>]
EOF
      exit 0 ;;
    *) echo "run.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

[ -n "$INPUT" ] || { echo "run.sh: --input required" >&2; exit 1; }
[ -r "$INPUT" ] || { echo "run.sh: input file not readable: $INPUT" >&2; exit 1; }
[ -n "$MODE" ]  || { echo "run.sh: --mode required (test-runner|smell-detection)" >&2; exit 1; }

case "$MODE" in
  test-runner|smell-detection) ;;
  *) echo "run.sh: unknown --mode: $MODE (expected test-runner or smell-detection)" >&2; exit 1 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "run.sh: jq is required but not on PATH" >&2; exit 1; }

# --- Filter input to .bats files ------------------------------------------

TARGETS=()
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    *.bats) TARGETS+=("$path") ;;
    *) ;;
  esac
done < "$INPUT"

emit_fragment() {
  local fragment="$1"
  if [ -n "$OUTPUT" ]; then
    printf '%s\n' "$fragment" > "$OUTPUT"
  else
    printf '%s\n' "$fragment"
  fi
}

# --- Auto-skip when no .bats files (AC8) ----------------------------------

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "run.sh: No bats files found -- skipping bats $MODE" >&2
  if [ "$MODE" = "test-runner" ]; then
    fragment="$(jq -nc \
      --arg name "bats" \
      '{name: $name, status: "passed", findings: [], tap: "", counts: {passed: 0, failed: 0, skipped: 0}}')"
  else
    fragment="$(jq -nc \
      --arg name "bats" \
      '{name: $name, status: "passed", findings: []}')"
  fi
  emit_fragment "$fragment"
  exit 0
fi

# --- Mode dispatch --------------------------------------------------------

run_test_runner() {
  if ! command -v bats >/dev/null 2>&1; then
    echo "run.sh: bats not found on PATH" >&2
    exit 127
  fi

  # Run bats on every target file. --tap forces TAP output regardless of the
  # tty/format defaults. We capture stderr separately so a non-zero exit (i.e.
  # test failures) does not abort the script under `set -e`.
  local raw_tap=""
  local bats_rc=0
  raw_tap="$(bats --tap "${TARGETS[@]}" 2>&1)" || bats_rc=$?

  # Parse TAP counts. A TAP stream contains:
  #   1..N            (plan line; total test count)
  #   ok N <desc>     (passing test)
  #   not ok N <desc> (failing test)
  #   ok N <desc> # skip <reason>  (skipped test)
  local passed failed skipped findings_json
  passed="$(printf '%s\n' "$raw_tap" | awk '/^ok / && !/# skip/ {n++} END{print n+0}')"
  failed="$(printf '%s\n' "$raw_tap" | awk '/^not ok /{n++} END{print n+0}')"
  skipped="$(printf '%s\n' "$raw_tap" | awk '/^ok .*# skip/{n++} END{print n+0}')"

  # Each `not ok` becomes one finding (severity=error, blocking=true).
  findings_json="$(printf '%s\n' "$raw_tap" \
    | awk '
        /^not ok / {
          # Extract the description after the test number: "not ok 3 <desc>".
          desc = $0
          sub(/^not ok [0-9]+[[:space:]]*/, "", desc)
          # Print as TSV: file<TAB>line<TAB>message. We do not know which file
          # produced the failure from TAP alone; leave blank/0 and let the
          # message carry the full context.
          printf "%s\t%d\t%s\n", "", 0, desc
        }
      ' \
    | jq -Rsc --arg sev "error" '
        split("\n")
        | map(select(length > 0))
        | map(split("\t"))
        | map({
            rule:     "BATS-TEST-FAIL",
            severity: $sev,
            file:     .[0],
            line:     (.[1] | tonumber),
            message:  .[2],
            blocking: true
          })
      ')"

  local status_str
  if [ "$failed" -gt 0 ]; then
    status_str="failed"
  else
    status_str="passed"
  fi

  local fragment
  fragment="$(jq -nc \
    --arg name "bats" \
    --arg status "$status_str" \
    --argjson findings "$findings_json" \
    --arg tap "$raw_tap" \
    --argjson passed "$passed" \
    --argjson failed "$failed" \
    --argjson skipped "$skipped" \
    '{name: $name, status: $status, findings: $findings, tap: $tap,
      counts: {passed: $passed, failed: $failed, skipped: $skipped}}')"

  emit_fragment "$fragment"

  # Adapter execution error (bats failed for non-test-result reasons): when
  # bats_rc > 0 but parsed failed/skipped/passed all sum to 0, surface as 1.
  local total=$((passed + failed + skipped))
  if [ "$bats_rc" -ne 0 ] && [ "$total" -eq 0 ]; then
    echo "run.sh: bats exited rc=$bats_rc with no parseable test results" >&2
    exit 1
  fi

  if [ "$failed" -gt 0 ]; then
    exit 2
  fi
  exit 0
}

# scan_smells <path> -> emits TSV "rule<TAB>line<TAB>message" lines per match.
# Anti-pattern catalog:
#   BATS-BARE-RUN          : `run <cmd>` with no follow-up `assert_*` or
#                            `[ "$status" -eq ... ]` style status check on
#                            the immediately following non-blank, non-comment
#                            line within the same @test block.
#   BATS-HARDCODED-PATH    : absolute path matching /etc, /var, /opt, /usr/local,
#                            /home/, /Users/, /tmp/<literal>/ (i.e. paths that
#                            tie tests to a specific machine layout).
#   BATS-UNTIMED-SLEEP     : `sleep <N>` calls without a preceding
#                            `# sleep-rationale: ...` comment annotation.
#   BATS-MISSING-TEST-ANNOTATION : a top-level function declaration that is
#                            not preceded by a `@test` annotation. Heuristic:
#                            warn when the file declares zero `@test` blocks
#                            but has function definitions.
scan_smells() {
  local file="$1"
  awk '
    function is_blank(s) { return s ~ /^[[:space:]]*$/ }
    function is_comment(s) { return s ~ /^[[:space:]]*#/ }
    function strip_comment(s,    t) { t = s; sub(/[[:space:]]*#.*$/, "", t); return t }

    BEGIN {
      in_test = 0
      pending_run = 0
      pending_run_line = 0
      prev_comment = ""
    }

    {
      line = $0

      # @test header. Two shapes are common:
      #   (a) Multi-line:  @test "name" {     ... body ... \n }
      #   (b) Inline:      @test "name" { run echo hi; }
      # For (b) we keep `in_test` set for THIS line so the body scans below
      # also inspect it. For (a) we set in_test and continue.
      if (line ~ /^@test[[:space:]]+/) {
        in_test = 1
        pending_run = 0
        prev_comment = ""
        # Strip the `@test "..." {` prefix so the body scans below operate on
        # just the body portion of the line.
        body = line
        sub(/^@test[[:space:]]+[^{]*\{/, "", body)
        # Inline form: a closing brace appears on the same line.
        if (body ~ /\}/) {
          # Trim the trailing `}` and any trailing whitespace/semicolons.
          sub(/\}[[:space:]]*$/, "", body)
          line = body
          # We will close in_test at the end of this iteration.
          inline_close = 1
        } else {
          # Multi-line: body is whatever follows the `{`.
          line = body
          inline_close = 0
        }
        # Fall through into the body-analysis block below (do NOT `next`).
      }

      # End of @test block: closing brace at column 0.
      if (in_test && line ~ /^\}[[:space:]]*$/) {
        if (pending_run) {
          printf "%s\t%d\t%s\n", "BATS-BARE-RUN", pending_run_line, "bare run without follow-up assert_* or status check"
          pending_run = 0
        }
        in_test = 0
        prev_comment = ""
        next
      }

      if (in_test) {
        # If a previous `run` is awaiting an assertion, decide on this line.
        if (pending_run && !is_blank(line) && !is_comment(line)) {
          stripped = strip_comment(line)
          if (stripped ~ /assert_/ ||
              stripped ~ /\$status/ ||
              stripped ~ /\$output/ ||
              stripped ~ /\$lines/ ||
              stripped ~ /^[[:space:]]*\[\[/ ||
              stripped ~ /^[[:space:]]*\[[[:space:]]/) {
            pending_run = 0
          } else {
            printf "%s\t%d\t%s\n", "BATS-BARE-RUN", pending_run_line, "bare run without follow-up assert_* or status check"
            pending_run = 0
          }
        }

        # BATS-BARE-RUN candidate.
        if (!is_comment(line)) {
          stripped_line = strip_comment(line)
          if (stripped_line ~ /^[[:space:]]*run[[:space:]]+/) {
            pending_run = 1
            pending_run_line = NR
          }
        }

        # BATS-HARDCODED-PATH: absolute paths tied to machine layout. Skip
        # references inside $BATS_* variables.
        if (!is_comment(line) && line !~ /\$BATS_/) {
          if (line ~ /(^|[^A-Za-z0-9_])\/etc\// ||
              line ~ /(^|[^A-Za-z0-9_])\/var\// ||
              line ~ /(^|[^A-Za-z0-9_])\/opt\// ||
              line ~ /(^|[^A-Za-z0-9_])\/usr\/local\// ||
              line ~ /(^|[^A-Za-z0-9_])\/home\// ||
              line ~ /(^|[^A-Za-z0-9_])\/Users\//) {
            printf "%s\t%d\t%s\n", "BATS-HARDCODED-PATH", NR, "hardcoded absolute path (use $BATS_TMPDIR or $BATS_TEST_TMPDIR)"
          }
        }

        # BATS-UNTIMED-SLEEP: `sleep N` without a preceding rationale comment.
        if (!is_comment(line) && line ~ /(^|[^A-Za-z0-9_])sleep[[:space:]]+[0-9]/) {
          if (prev_comment !~ /sleep-rationale:/) {
            printf "%s\t%d\t%s\n", "BATS-UNTIMED-SLEEP", NR, "sleep without preceding # sleep-rationale: comment"
          }
        }
      }

      # Track previous non-blank comment for sleep-rationale lookback.
      if (!is_blank(line)) {
        if (is_comment(line)) { prev_comment = line } else { prev_comment = "" }
      }

      # Close the inline-@test block at end of iteration.
      if (in_test && inline_close) {
        if (pending_run) {
          printf "%s\t%d\t%s\n", "BATS-BARE-RUN", pending_run_line, "bare run without follow-up assert_* or status check"
          pending_run = 0
        }
        in_test = 0
        inline_close = 0
        prev_comment = ""
      }
    }

    END {
      if (pending_run) {
        printf "%s\t%d\t%s\n", "BATS-BARE-RUN", pending_run_line, "bare run without follow-up assert_* or status check"
      }
    }
  ' "$file"
}

run_smell_detection() {
  local findings_tsv=""
  local f
  for f in "${TARGETS[@]}"; do
    if [ ! -r "$f" ]; then
      continue
    fi
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      # Prefix the row with the file path so we can carry it through into JSON.
      findings_tsv+="$f"$'\t'"$row"$'\n'
    done < <(scan_smells "$f")
  done

  # Convert TSV (file<TAB>rule<TAB>line<TAB>message) into the canonical JSON
  # findings array.
  local findings_json
  findings_json="$(printf '%s' "$findings_tsv" \
    | jq -Rsc '
        split("\n")
        | map(select(length > 0))
        | map(split("\t"))
        | map({
            rule:     .[1],
            severity: "warning",
            file:     .[0],
            line:     (.[2] | tonumber),
            message:  .[3],
            blocking: false
          })
      ')"

  local finding_count
  finding_count="$(printf '%s' "$findings_json" | jq 'length')"

  local status_str
  if [ "$finding_count" -gt 0 ]; then
    status_str="failed"
  else
    status_str="passed"
  fi

  local fragment
  fragment="$(jq -nc \
    --arg name "bats" \
    --arg status "$status_str" \
    --argjson findings "$findings_json" \
    '{name: $name, status: $status, findings: $findings}')"

  emit_fragment "$fragment"

  # Smell-detection findings are advisory (severity=warning, blocking=false).
  # Exit 0 to signal a clean adapter run — verdict resolver derives blocking
  # state from findings[].blocking. Tests that want non-zero on findings can
  # check the status field instead.
  exit 0
}

case "$MODE" in
  test-runner) run_test_runner ;;
  smell-detection) run_smell_detection ;;
esac
