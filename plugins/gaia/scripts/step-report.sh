#!/usr/bin/env bash
# step-report.sh — per-story step report (timing + token rollup)
#
# Reads `step_boundary` events from lifecycle-events.jsonl, groups them by
# story_key, orders by step number, and derives per-step wall-clock durations
# (timestamp diff to next step) and per-step token estimates (consecutive
# tokens_snapshot diff, with negatives clamped to n/a). Emits a per-story
# table of (step, step_name, duration, token_estimate) rows plus per-story
# totals. The last step in each story is open-ended (no duration, no token
# estimate) and is excluded from the table — matching the upstream convention.
#
# Token estimates are inherently approximate — derived from cumulative
# context-window snapshots, never exact per-step counts. The report labels
# every token number as approximate and renders n/a where data is unavailable.
#
# READ-ONLY: this script NEVER writes any artifact, config, or state file.
# Output is produced exclusively on stdout.
#
# Invocation:
#   step-report.sh --events <jsonl> [--story <key>] [--json]
#   step-report.sh --help
#
# Environment:
#   LIFECYCLE_EVENTS    default events path (overridden by --events)
#   MAX_BYTES           bounded tail read of the events log (default 5242880)
#
# Exit codes:
#   0 — derived successfully (possibly empty)
#   1 — bad args, or events file missing/unreadable

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="step-report.sh"
MAX_BYTES="${MAX_BYTES:-5242880}"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'USAGE'
step-report.sh — per-story step report (timing + token rollup)

Usage:
  step-report.sh --events <jsonl> [--story <key>] [--json]

Derives per-step wall-clock durations and per-step token estimates from
step_boundary events, then emits per-story tables with rollup totals.
READ-ONLY — writes nothing; output on stdout.

Token estimates are approximate — derived from cumulative context-window
snapshots, not exact per-step counts.

Options:
  --events <path>   lifecycle-events.jsonl to read (or $LIFECYCLE_EVENTS)
  --story <key>     filter to a single story key
  --json            emit a JSON object instead of the text report
  --help            this help
USAGE
  exit 0
fi

EVENTS="${LIFECYCLE_EVENTS:-}"
STORY_FILTER=""
JSON_OUT=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --events) EVENTS="${2:-}"; shift 2 ;;
    --story) STORY_FILTER="${2:-}"; shift 2 ;;
    --json) JSON_OUT=1; shift ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -n "$EVENTS" ] || die "no events file given (--events or \$LIFECYCLE_EVENTS)"
[ -e "$EVENTS" ] || die "events file not found: $EVENTS"
[ -r "$EVENTS" ] || die "events file not readable: $EVENTS"

# ---------- ISO timestamp to epoch (reuse from throughput-telemetry.sh) ----------
iso_to_epoch_awk='
  function iso2epoch(ts,    y,mo,d,h,mi,s,days,leap,i,mdays,total) {
    y =substr(ts,1,4)+0;  mo=substr(ts,6,2)+0; d=substr(ts,9,2)+0
    h =substr(ts,12,2)+0; mi=substr(ts,15,2)+0; s=substr(ts,18,2)+0
    split("31 28 31 30 31 30 31 31 30 31 30 31", mdays, " ")
    days=0
    for (i=1970; i<y; i++) { leap=((i%4==0&&i%100!=0)||i%400==0); days += leap?366:365 }
    for (i=1; i<mo; i++) { days += mdays[i]; if (i==2 && ((y%4==0&&y%100!=0)||y%400==0)) days++ }
    days += d-1
    total = days*86400 + h*3600 + mi*60 + s
    return total
  }
'

# ---------- Extract step_boundary events ----------
# Produce: story_key <TAB> step <TAB> epoch <TAB> step_name <TAB> tokens_json
if command -v jq >/dev/null 2>&1; then
  STEP_ROWS="$(head -c "$MAX_BYTES" "$EVENTS" \
    | jq -r 'select(.event_type=="step_boundary") | "\(.story_key)\t\(.step)\t\(.timestamp)\t\(.data.step_name // "")\t\(.data.tokens_snapshot // "null" | tostring)"' 2>/dev/null \
    | awk -F'\t' "$iso_to_epoch_awk"'{ print $1 "\t" $2 "\t" iso2epoch($3) "\t" $4 "\t" $5 }')" || true
else
  STEP_ROWS="$(head -c "$MAX_BYTES" "$EVENTS" \
    | awk "$iso_to_epoch_awk"'
      /"event_type":"step_boundary"/ {
        key=""; step=""; ts=""; sname=""
        if (match($0, /"story_key":"[^"]*"/)) { key=substr($0,RSTART+13,RLENGTH-14) }
        if (match($0, /"step":[0-9]+/)) { step=substr($0,RSTART+7,RLENGTH-7) }
        if (match($0, /"timestamp":"[^"]*"/)) { ts=substr($0,RSTART+13,RLENGTH-14) }
        if (match($0, /"step_name":"[^"]*"/)) { sname=substr($0,RSTART+13,RLENGTH-14) }
        if (key!="" && step!="" && ts!="") printf "%s\t%s\t%s\t%s\tnull\n", key, step, iso2epoch(ts), sname
      }')" || true
fi

# Apply story filter
if [ -n "$STORY_FILTER" ] && [ -n "$STEP_ROWS" ]; then
  STEP_ROWS="$(printf '%s\n' "$STEP_ROWS" | awk -F'\t' -v sk="$STORY_FILTER" '$1==sk')"
fi

# Empty input: emit empty report
if [ -z "$STEP_ROWS" ]; then
  if [ "$JSON_OUT" -eq 1 ]; then
    printf '{"stories":[]}\n'
  else
    printf 'step-report — derived from %s\n\n(no step_boundary events found)\n' "$EVENTS"
  fi
  exit 0
fi

# ---------- Dedup + sort + diff ----------
# Keep the FIRST occurrence of each (story_key, step), sort by story_key + step,
# then difference consecutive same-story steps.
# Output: story_key <TAB> step <TAB> duration_min <TAB> step_name <TAB> tokens_cur <TAB> tokens_next
STEP_DIFF_LINES="$(printf '%s\n' "$STEP_ROWS" | awk -F'\t' '
  NF>=4 {
    key = $1 SUBSEP $2
    if (!(key in seen)) {
      seen[key] = 1
      n++
      sk[n] = $1
      st[n] = $2 + 0
      ep[n] = $3 + 0
      nm[n] = $4
      tk[n] = (NF >= 5) ? $5 : "null"
    }
  }
  END {
    # sort by story_key then step
    for (i = 1; i <= n; i++)
      for (j = i + 1; j <= n; j++)
        if (sk[j] < sk[i] || (sk[j] == sk[i] && st[j] < st[i])) {
          t = sk[i]; sk[i] = sk[j]; sk[j] = t
          t = st[i]; st[i] = st[j]; st[j] = t
          t = ep[i]; ep[i] = ep[j]; ep[j] = t
          t = nm[i]; nm[i] = nm[j]; nm[j] = t
          t = tk[i]; tk[i] = tk[j]; tk[j] = t
        }
    # difference consecutive same-story steps
    for (i = 1; i < n; i++) {
      if (sk[i] == sk[i+1]) {
        dur = int((ep[i+1] - ep[i]) / 60)
        if (dur < 0) dur = 0
        printf "%s\t%d\t%d\t%s\t%s\t%s\n", sk[i], st[i], dur, nm[i], tk[i], tk[i+1]
      }
    }
  }
')"

# ---------- JSON output mode ----------
if [ "$JSON_OUT" -eq 1 ]; then
  # Build JSON via jq: process each diff line into step objects, group by story
  if [ -z "$STEP_DIFF_LINES" ]; then
    printf '{"stories":[]}\n'
    exit 0
  fi

  # Process diff lines into a JSONL stream of step objects, then aggregate
  printf '%s\n' "$STEP_DIFF_LINES" | while IFS=$'\t' read -r sk step dur sname tk_cur tk_next; do
    [ -n "$sk" ] || continue

    # Derive token estimate (same math as throughput-telemetry.sh)
    TOKEN_JSON="null"
    if [ "$tk_cur" != "null" ] && [ "$tk_next" != "null" ]; then
      TOKEN_JSON=$(printf '%s\n%s' "$tk_cur" "$tk_next" | jq -sc '
        if (.[0] | type) == "object" and (.[1] | type) == "object" then
          {
            input_tokens:  ((.[1].input_tokens // 0) - (.[0].input_tokens // 0)),
            output_tokens: ((.[1].output_tokens // 0) - (.[0].output_tokens // 0)),
            cache_creation_input_tokens: ((.[1].cache_creation_input_tokens // 0) - (.[0].cache_creation_input_tokens // 0)),
            cache_read_input_tokens: ((.[1].cache_read_input_tokens // 0) - (.[0].cache_read_input_tokens // 0))
          }
          | to_entries
          | map(if .value < 0 then .value = null else . end)
          | from_entries
        else null end
      ' 2>/dev/null) || TOKEN_JSON="null"
      [ "$TOKEN_JSON" = "null" ] || {
        # Check if ALL fields are null (all negative diffs) — treat as null
        all_null=$(printf '%s' "$TOKEN_JSON" | jq '[.[] | . == null] | all' 2>/dev/null || printf 'false')
        [ "$all_null" = "true" ] && TOKEN_JSON="null"
      }
    fi

    jq -nc \
      --arg sk "$sk" \
      --argjson step "$step" \
      --arg sname "$sname" \
      --argjson dur "$dur" \
      --argjson tokens "$TOKEN_JSON" \
      '{story_key: $sk, step: $step, step_name: $sname, duration_min: $dur, tokens: $tokens}'
  done | jq -sc '
    # Group by story_key and build the output structure
    group_by(.story_key) | map({
      story_key: .[0].story_key,
      steps: [.[] | {step, step_name, duration_min, tokens}],
      total_duration_min: ([.[].duration_min] | add // 0),
      total_tokens_approx: (
        [.[] | select(.tokens != null) | .tokens] |
        if length == 0 then null
        else reduce .[] as $t (
          {input_tokens: 0, output_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: 0};
          {
            input_tokens: (.input_tokens + ($t.input_tokens // 0)),
            output_tokens: (.output_tokens + ($t.output_tokens // 0)),
            cache_creation_input_tokens: (.cache_creation_input_tokens + ($t.cache_creation_input_tokens // 0)),
            cache_read_input_tokens: (.cache_read_input_tokens + ($t.cache_read_input_tokens // 0))
          }
        ) end
      )
    }) | {stories: .}
  '
  exit 0
fi

# ---------- Text output mode ----------

# Token field formatter (reuse pattern from throughput-telemetry.sh)
_fmt_token_field() {
  local val="$1" label="$2"
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    printf '%s: n/a' "$label"
  else
    printf '%s: ~%s tok (approx)' "$label" "$val"
  fi
}

printf 'step-report — derived from %s\n' "$EVENTS"

# Collect unique story keys in order
STORY_KEYS="$(printf '%s\n' "$STEP_DIFF_LINES" | awk -F'\t' '!seen[$1]++ { print $1 }')"

while IFS= read -r current_story; do
  [ -n "$current_story" ] || continue
  printf '\nStory: %s\n\n' "$current_story"
  printf '  %-6s %-20s %-12s %s\n' "Step" "Name" "Duration" "Token estimate (approx)"
  printf '  %-6s %-20s %-12s %s\n' "----" "----" "--------" "------------------------"

  total_dur=0
  total_input=0
  total_output=0
  total_cc=0
  total_cr=0
  has_any_tokens=0

  printf '%s\n' "$STEP_DIFF_LINES" | grep -E "^${current_story}	" | while IFS=$'\t' read -r sk step dur sname tk_cur tk_next; do
    [ -n "$sk" ] || continue
    total_dur=$(( total_dur + dur ))

    # Derive per-step token estimate
    TOKEN_EST=""
    if [ "$tk_cur" != "null" ] && [ "$tk_next" != "null" ] && command -v jq >/dev/null 2>&1; then
      TOKEN_EST=$(printf '%s\n%s' "$tk_cur" "$tk_next" | jq -sc '
        if (.[0] | type) == "object" and (.[1] | type) == "object" then
          {
            input_tokens:  ((.[1].input_tokens // 0) - (.[0].input_tokens // 0)),
            output_tokens: ((.[1].output_tokens // 0) - (.[0].output_tokens // 0)),
            cache_creation_input_tokens: ((.[1].cache_creation_input_tokens // 0) - (.[0].cache_creation_input_tokens // 0)),
            cache_read_input_tokens: ((.[1].cache_read_input_tokens // 0) - (.[0].cache_read_input_tokens // 0))
          }
          | to_entries
          | map(if .value < 0 then .value = null else . end)
          | from_entries
        else null end
      ' 2>/dev/null)
      [ "$TOKEN_EST" = "null" ] && TOKEN_EST=""
    fi

    if [ -n "$TOKEN_EST" ]; then
      _in=$(printf '%s' "$TOKEN_EST" | jq -r '.input_tokens // empty' 2>/dev/null)
      _out=$(printf '%s' "$TOKEN_EST" | jq -r '.output_tokens // empty' 2>/dev/null)
      _cc=$(printf '%s' "$TOKEN_EST" | jq -r '.cache_creation_input_tokens // empty' 2>/dev/null)
      _cr=$(printf '%s' "$TOKEN_EST" | jq -r '.cache_read_input_tokens // empty' 2>/dev/null)
      _in_f=$(_fmt_token_field "$_in" "input")
      _out_f=$(_fmt_token_field "$_out" "output")
      _cc_f=$(_fmt_token_field "$_cc" "cache_create")
      _cr_f=$(_fmt_token_field "$_cr" "cache_read")
      printf '  %-6s %-20s %-12s %s, %s, %s, %s\n' \
        "$step" "$sname" "${dur} min" "$_in_f" "$_out_f" "$_cc_f" "$_cr_f"
    else
      printf '  %-6s %-20s %-12s n/a\n' "$step" "$sname" "${dur} min"
    fi
  done

  # Compute totals (re-process since the while loop was in a subshell)
  total_dur=0
  has_any_tokens=0
  total_input=0
  total_output=0
  total_cc=0
  total_cr=0

  while IFS=$'\t' read -r sk step dur sname tk_cur tk_next; do
    [ -n "$sk" ] || continue
    [ "$sk" = "$current_story" ] || continue
    total_dur=$(( total_dur + dur ))

    if [ "$tk_cur" != "null" ] && [ "$tk_next" != "null" ] && command -v jq >/dev/null 2>&1; then
      TOKEN_EST=$(printf '%s\n%s' "$tk_cur" "$tk_next" | jq -sc '
        if (.[0] | type) == "object" and (.[1] | type) == "object" then
          {
            input_tokens:  ((.[1].input_tokens // 0) - (.[0].input_tokens // 0)),
            output_tokens: ((.[1].output_tokens // 0) - (.[0].output_tokens // 0)),
            cache_creation_input_tokens: ((.[1].cache_creation_input_tokens // 0) - (.[0].cache_creation_input_tokens // 0)),
            cache_read_input_tokens: ((.[1].cache_read_input_tokens // 0) - (.[0].cache_read_input_tokens // 0))
          }
          | to_entries
          | map(if .value < 0 then .value = null else . end)
          | from_entries
        else null end
      ' 2>/dev/null)
      if [ -n "$TOKEN_EST" ] && [ "$TOKEN_EST" != "null" ]; then
        _in=$(printf '%s' "$TOKEN_EST" | jq -r '.input_tokens // 0' 2>/dev/null)
        _out=$(printf '%s' "$TOKEN_EST" | jq -r '.output_tokens // 0' 2>/dev/null)
        _cc=$(printf '%s' "$TOKEN_EST" | jq -r '.cache_creation_input_tokens // 0' 2>/dev/null)
        _cr=$(printf '%s' "$TOKEN_EST" | jq -r '.cache_read_input_tokens // 0' 2>/dev/null)
        # Only count non-null fields (null fields from negative clamping = 0 contribution)
        [ "$_in" != "null" ] && total_input=$(( total_input + _in )) && has_any_tokens=1
        [ "$_out" != "null" ] && total_output=$(( total_output + _out )) && has_any_tokens=1
        [ "$_cc" != "null" ] && total_cc=$(( total_cc + _cc )) && has_any_tokens=1
        [ "$_cr" != "null" ] && total_cr=$(( total_cr + _cr )) && has_any_tokens=1
      fi
    fi
  done <<< "$(printf '%s\n' "$STEP_DIFF_LINES")"

  printf '\n  Total wall-clock: %d min (approx)\n' "$total_dur"
  if [ "$has_any_tokens" -eq 1 ]; then
    printf '  Total token estimate: ~%d tok input, ~%d tok output, ~%d tok cache_create, ~%d tok cache_read (approx)\n' \
      "$total_input" "$total_output" "$total_cc" "$total_cr"
  else
    printf '  Total token estimate: n/a\n'
  fi

done <<< "$STORY_KEYS"

exit 0
