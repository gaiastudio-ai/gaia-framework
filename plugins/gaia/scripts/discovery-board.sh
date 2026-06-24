#!/usr/bin/env bash
# discovery-board.sh — sole sanctioned writer of .gaia/state/discovery-board.yaml
#
# Validates discovery board state machine transitions, captures new items,
# and reads board entries. Mirrors the sprint-state.sh single-writer +
# flock + atomic-mv + enum-fail-fast pattern.
#
# Invocation contract:
#
#   discovery-board.sh capture      --title <text> --source <text>
#   discovery-board.sh transition   --id <id> --to <state>
#   discovery-board.sh get          --id <id>
#   discovery-board.sh validate
#   discovery-board.sh board        [--horizon <h>] [--priority <p>]
#   discovery-board.sh prioritize   --id <id> --priority <p> --horizon <h>
#   discovery-board.sh --help
#
# Board schema (15 fields per item):
#   id, title, source, status, research_type[], artifacts[],
#   value_signal, effort_signal, priority, horizon,
#   decision_link, graduated_feature_id,
#   created_at, last_activity, status_changed_at
#
# Canonical state set:
#   Captured | Researching | Evaluated | Graduated | Parked | Archived
#
# Allowed adjacency (edges):
#   Captured     -> Researching
#   Captured     -> Evaluated      (skip-research)
#   Captured     -> Graduated      (fast-track)
#   Captured     -> Parked
#   Captured     -> Archived
#   Researching  -> Evaluated
#   Researching  -> Parked
#   Researching  -> Archived
#   Evaluated    -> Graduated
#   Evaluated    -> Parked
#   Evaluated    -> Archived
#   Parked       -> (revive to parked_from)
#   Parked       -> Archived
#
# Terminal sinks: Graduated, Archived (no outbound edges).
#
# Config:
#   PROJECT_ROOT — defaults to "${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-.}}".
#
# Atomicity & concurrency:
#   All board writes are serialized by flock -x -w 5 on a sibling
#   .lock file. Every write is tempfile + atomic mv. The set -C
#   no-clobber spin-loop fallback covers macOS (no flock by default).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="discovery-board.sh"

# ---------- Script-level tmp cleanup trap ----------

_GAIA_TMP_PATHS=()
_cleanup_tmps() {
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
  "Captured"
  "Researching"
  "Evaluated"
  "Graduated"
  "Parked"
  "Archived"
)

TERMINAL_STATES=(
  "Graduated"
  "Archived"
)

# Allowed adjacency encoded as "from|to" strings.
# Parked revive is handled specially (Parked -> parked_from).
ALLOWED_EDGES=(
  "Captured|Researching"
  "Captured|Evaluated"
  "Captured|Graduated"
  "Captured|Parked"
  "Captured|Archived"
  "Researching|Evaluated"
  "Researching|Parked"
  "Researching|Archived"
  "Evaluated|Graduated"
  "Evaluated|Parked"
  "Evaluated|Archived"
  "Parked|Archived"
)

# ---------- Helpers ----------

die() {
  printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

_log_info() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
}

_log_warn() {
  printf '%s: warning: %s\n' "$SCRIPT_NAME" "$*" >&2
}

yaml_single_quote() {
  local s="$1"
  s="${s//\'/\'\'}"
  printf "'%s'" "$s"
}

# ---------- Sanitization helpers (AC4) ----------

# _sanitize_field — strip ALL ASCII control characters (0x00-0x1F, 0x7F)
# including newline, carriage-return, and tab, then length-cap.
# This is the SOLE defense against YAML multi-line scalar injection: if no
# persisted value ever contains a newline, the non-quote-aware awk readers
# are safe by construction.  Applied at EVERY write site (capture, prioritize,
# rewrite), not just the hydration bridge.
_sanitize_field() {
  local raw="$1" max_len="${2:-500}"
  # Strip every ASCII control char — no exceptions for \t, \n, \r.
  local cleaned
  cleaned=$(printf '%s' "$raw" | tr -d '\000-\037\177')
  # Length cap.
  if [ "${#cleaned}" -gt "$max_len" ]; then
    cleaned="${cleaned:0:$max_len}"
  fi
  printf '%s' "$cleaned"
}

# _confine_path — reject paths that escape the repo root.
# Returns 0 if path is safe (repo-relative, no traversal), 1 if hostile.
_confine_path() {
  local path="$1"
  # Reject absolute paths.
  if [[ "$path" == /* ]]; then
    return 1
  fi
  # Reject traversal sequences.
  if [[ "$path" == *".."* ]]; then
    return 1
  fi
  return 0
}

# ---------- Track detection (AC1) ----------

# _detect_track — auto-detect the graduation track from item fields.
# Outputs one of: fast, research, decision.
_detect_track() {
  local artifacts="$1" decision_link="$2"
  local trimmed_link
  trimmed_link=$(printf '%s' "$decision_link" | tr -d '[:space:]')

  # Decision track: non-null decision_link.
  if [ -n "$trimmed_link" ]; then
    printf 'decision'
    return 0
  fi

  # Research track: artifacts non-empty (not [] or empty string).
  local trimmed_artifacts
  trimmed_artifacts=$(printf '%s' "$artifacts" | tr -d '[:space:][]"'"'"'')
  if [ -n "$trimmed_artifacts" ]; then
    printf 'research'
    return 0
  fi

  # Fast track: no artifacts, no decision_link.
  printf 'fast'
  return 0
}

# ---------- Track bar validation (AC1) ----------

# _validate_track_bar — enforce per-track minimum evidence bar.
# Returns 0 if bar is met, dies on failure.
_validate_track_bar() {
  local item_id="$1" track="$2" title="$3" source="$4"
  local artifacts="$5" decision_link="$6"

  # Universal bar: title + source must be non-empty.
  local trimmed_title trimmed_source
  trimmed_title=$(printf '%s' "$title" | tr -d '[:space:]')
  trimmed_source=$(printf '%s' "$source" | tr -d '[:space:]')
  if [ -z "$trimmed_title" ]; then
    die "item '${item_id}': title must be non-empty to graduate"
  fi
  if [ -z "$trimmed_source" ]; then
    die "item '${item_id}': source must be non-empty to graduate"
  fi

  case "$track" in
    fast)
      # Fast track: title + source + priority + horizon — priority/horizon
      # is already enforced by _assert_priority_horizon, so nothing extra.
      ;;
    research)
      # Research track: additionally requires >=1 resolvable artifact.
      _validate_research_artifacts "$item_id" "$artifacts"
      ;;
    decision)
      # Decision track: additionally requires a valid AI-id.
      _validate_ai_id "$item_id" "$decision_link"
      ;;
  esac
}

# _validate_research_artifacts — verify that at least one cited artifact
# resolves on disk. Fails closed on all degenerate inputs.
_validate_research_artifacts() {
  local item_id="$1" artifacts_raw="$2"

  # Parse the YAML inline list. Strip brackets and split on comma.
  local stripped
  stripped=$(printf '%s' "$artifacts_raw" | tr -d '[]')
  if [ -z "$(printf '%s' "$stripped" | tr -d '[:space:]"'"'"'')" ]; then
    die "item '${item_id}': research track requires at least one cited artifact"
  fi

  # Check each artifact path resolves on disk.
  local IFS=','
  local found_resolvable=0
  local path
  # shellcheck disable=SC2086
  for path in $stripped; do
    # Trim quotes and whitespace.
    path=$(printf '%s' "$path" | sed 's/^[[:space:]"'"'"']*//; s/[[:space:]"'"'"']*$//')
    [ -z "$path" ] && continue

    # Path confinement (AC4).
    if ! _confine_path "$path"; then
      die "item '${item_id}': artifact path '${path}' escapes the repository root"
    fi

    if [ -f "${PROJECT_ROOT}/${path}" ]; then
      found_resolvable=1
    fi
  done

  if [ "$found_resolvable" -eq 0 ]; then
    die "item '${item_id}': no cited artifact resolves on disk -- research track requires at least one resolvable artifact"
  fi
}

# ---------- AI-id fail-closed validation (AC2) ----------

# _validate_ai_id — exact-key match against a successfully-parsed
# action-items.yaml. Fails CLOSED on every degenerate input.
_validate_ai_id() {
  local item_id="$1" ai_id="$2"

  local ai_file="${PROJECT_ROOT}/.gaia/state/action-items.yaml"

  # Fail closed: missing file.
  if [ ! -f "$ai_file" ]; then
    die "item '${item_id}': decision track requires action-items.yaml but the file is missing"
  fi

  # Fail closed: empty file.
  if [ ! -s "$ai_file" ]; then
    die "item '${item_id}': decision track requires action-items.yaml but the file is empty"
  fi

  # Fail closed: unparseable file. Check for schema_version or items: key
  # as a minimal parseable-YAML gate.
  if ! grep -qE '^(schema_version:|items:)' "$ai_file" 2>/dev/null; then
    die "item '${item_id}': action-items.yaml is unparseable or malformed"
  fi

  # Exact-key match — find the id and read its status.
  # Uses awk for exact matching (not substring).
  local match_status
  match_status=$(awk -v target="$ai_id" '
    BEGIN { found = 0 }
    {
      line = $0
      sub(/\r$/, "", line)
    }
    line ~ /^[[:space:]]*-[[:space:]]*id:[[:space:]]*/ {
      k = line
      sub(/^[[:space:]]*-[[:space:]]*id:[[:space:]]*/, "", k)
      gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", k)
      if (k == target) { found = 1; next }
      else if (found) { exit }
      next
    }
    found && line ~ /^[[:space:]]+status:[[:space:]]*/ {
      v = line
      sub(/^[[:space:]]+status:[[:space:]]*/, "", v)
      gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", v)
      print v
      exit
    }
  ' "$ai_file")

  # Fail closed: absent id.
  if [ -z "$match_status" ]; then
    die "item '${item_id}': action-item '${ai_id}' not found in action-items.yaml -- exact key match required"
  fi

  # Fail closed: soft-deleted statuses.
  case "$match_status" in
    invalid|resolved|deleted)
      die "item '${item_id}': action-item '${ai_id}' is soft-deleted (status=${match_status}) -- not graduatable"
      ;;
  esac
}

# ---------- Hydration (AC3, AC4) ----------

# _emit_hydrated_intake — emit hydrated intake fields for --from-discovery.
# Classification is NEVER emitted — it is RE-DERIVED by the caller.
_emit_hydrated_intake() {
  local title="$1" source="$2" priority="$3"

  # Sanitize all fields (AC4).
  local clean_title clean_source clean_priority
  clean_title=$(_sanitize_field "$title" 500)
  clean_source=$(_sanitize_field "$source" 200)
  clean_priority=$(_sanitize_field "$priority" 50)

  # Map priority to urgency vocabulary.
  local urgency="medium"
  case "$clean_priority" in
    critical|Critical|CRITICAL) urgency="critical" ;;
    high|High|HIGH)             urgency="high" ;;
    medium|Medium|MEDIUM)       urgency="medium" ;;
    low|Low|LOW)                urgency="low" ;;
  esac

  # Emit as parseable key-value pairs.
  printf 'description: %s\n' "$(yaml_single_quote "$clean_title")"
  printf 'urgency: %s\n' "$urgency"
  printf 'driver: %s\n' "$(yaml_single_quote "$clean_source")"
}

usage() {
  cat <<'USAGE'
Usage:
  discovery-board.sh capture      --title <text> --source <text>
  discovery-board.sh transition   --id <id> --to <state>
  discovery-board.sh get          --id <id>
  discovery-board.sh validate
  discovery-board.sh board        [--horizon <h>] [--priority <p>]
  discovery-board.sh prioritize   --id <id> --priority <p> --horizon <h>
  discovery-board.sh graduate     --id <id> [--from-discovery] [--feature-id <fid>]
  discovery-board.sh --help

Subcommands:
  capture       Add a new item to the board in Captured state. Mints a
                unique id, writes all 15 required fields, and stamps
                creation timestamps.
  transition    Move an existing item to a new state. Validates adjacency,
                enforces the priority+horizon gate for Evaluated/Graduated,
                records parked_from on park, and updates timestamps.
  get           Print the item's YAML block to stdout (read-only).
  validate      Read-validate every item on the board. Rejects unknown
                status values with a diagnostic. Read-only.
  board         Render the board to stdout with optional --horizon and
                --priority filters. Shows read-only idle advisories at
                30/60/90 days. Never mutates state.
  prioritize    Set priority and horizon on an item. Both --priority and
                --horizon are required. Updates last_activity timestamp.
  graduate      Graduate an Evaluated item to the backlog. Auto-detects
                the graduation track (fast / research / decision) and
                enforces the per-track minimum evidence bar. Graduate is
                the sole backlog edge.
                --from-discovery  Emit hydrated intake fields for
                  /gaia-add-feature Step 1 pre-fill (description, urgency,
                  driver). Classification is RE-DERIVED, never hydrated.
                --feature-id <fid>  Stamp the backlog feature id on the
                  board item after successful graduation.

Canonical states:
  Captured | Researching | Evaluated | Graduated | Parked | Archived

Config:
  PROJECT_ROOT  defaults to "${CLAUDE_PROJECT_ROOT:-.}". Anchors the
                .gaia/ tree.

Exit codes:
  0  success
  1  usage error, invalid state, illegal transition, missing field,
     lock failure, or validation failure
USAGE
}

is_canonical_board_state() {
  local candidate="$1"
  local s
  for s in "${CANONICAL_STATES[@]}"; do
    [ "$s" = "$candidate" ] && return 0
  done
  return 1
}

canonical_board_states_hint() {
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

assert_canonical_board_state() {
  local candidate="$1" context="${2:-write}"
  if ! is_canonical_board_state "$candidate"; then
    die "refusing to ${context} non-canonical board status: '${candidate}' -- allowed values: $(canonical_board_states_hint)"
  fi
}

_is_terminal_state() {
  local candidate="$1"
  local s
  for s in "${TERMINAL_STATES[@]}"; do
    [ "$s" = "$candidate" ] && return 0
  done
  return 1
}

validate_board_transition() {
  local from="$1" to="$2"

  # Terminal sinks have no outbound edges.
  if _is_terminal_state "$from"; then
    die "illegal transition: '${from}' is a terminal state -- no outbound transitions allowed"
  fi

  # Parked revive: Parked -> X is legal only when X matches parked_from.
  # The caller must validate the parked_from match separately for revive.
  # The ALLOWED_EDGES table handles Parked -> Archived.
  if [ "$from" = "Parked" ] && [ "$to" != "Archived" ]; then
    # This is a revive attempt -- the caller handles the parked_from check.
    return 0
  fi

  local edge
  for edge in "${ALLOWED_EDGES[@]}"; do
    if [ "$edge" = "${from}|${to}" ]; then
      return 0
    fi
  done
  die "illegal transition: '${from}' -> '${to}' is not in the allowed adjacency list"
}

# ---------- Path resolution ----------

resolve_board_paths() {
  PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-.}}}"
  BOARD_STATE_DIR="${PROJECT_ROOT}/.gaia/state"
  BOARD_FILE="${BOARD_STATE_DIR}/discovery-board.yaml"
  BOARD_LOCK="${BOARD_FILE}.lock"
  mkdir -p "$BOARD_STATE_DIR"
}

# ---------- ID minting ----------

_mint_id() {
  local today
  today=$(date -u +%Y-%m-%d)
  local seq=1
  if [ -f "$BOARD_FILE" ]; then
    local max_seq
    max_seq=$(awk -v d="$today" '
      /^[[:space:]]*- id:/ || /^[[:space:]]*id:/ {
        gsub(/["'"'"']/, "", $0)
        sub(/.*id:[[:space:]]*/, "")
        # Match the date portion
        split($0, parts, "-")
        if (length(parts) >= 5) {
          dt = parts[2] "-" parts[3] "-" parts[4]
          if (dt == d) {
            n = parts[5] + 0
            if (n > max) max = n
          }
        }
      }
      END { print (max > 0 ? max : 0) }
    ' "$BOARD_FILE")
    seq=$((max_seq + 1))
  fi
  printf 'DISC-%s-%d' "$today" "$seq"
}

# ---------- Board read helpers ----------

# Read a single field from a specific item block.
_read_item_field() {
  local file="$1" target_id="$2" field="$3"
  awk -v target="$target_id" -v field="$field" '
    BEGIN { in_item = 0; found = 0 }
    {
      line = $0
      sub(/\r$/, "", line)
    }
    line ~ /^[[:space:]]*- id:[[:space:]]*/ {
      k = line
      sub(/^[[:space:]]*- id:[[:space:]]*/, "", k)
      gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", k)
      if (k == target) { in_item = 1 } else { in_item = 0 }
      if (in_item && field == "id") { print k; found = 1; exit }
      next
    }
    # A new list entry or top-level key closes the current item.
    in_item && (line ~ /^[[:space:]]*- id:/ || line ~ /^[^[:space:]]/) {
      in_item = 0
    }
    in_item {
      pat = "^[[:space:]]+" field ":[[:space:]]*"
      if (line ~ pat) {
        v = line
        sub(pat, "", v)
        gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", v)
        print v
        found = 1
        exit
      }
    }
    END { if (!found) exit 1 }
  ' "$file"
}

# Print the full YAML block for an item to stdout.
_print_item_block() {
  local file="$1" target_id="$2"
  awk -v target="$target_id" '
    BEGIN { in_item = 0; found = 0 }
    {
      line = $0
      sub(/\r$/, "", line)
    }
    line ~ /^[[:space:]]*- id:[[:space:]]*/ {
      k = line
      sub(/^[[:space:]]*- id:[[:space:]]*/, "", k)
      gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", k)
      if (k == target) { in_item = 1; found = 1; print $0; next }
      if (in_item) { in_item = 0 }
      next
    }
    in_item && (line ~ /^[[:space:]]*- id:/ || line ~ /^[^[:space:]]/) {
      in_item = 0
      next
    }
    in_item { print $0 }
    END { if (!found) exit 1 }
  ' "$file"
}

# ---------- Priority+Horizon gate (AC5) ----------

_assert_priority_horizon() {
  local item_id="$1" target_state="$2"

  # Gate applies only to Evaluated and Graduated.
  case "$target_state" in
    Evaluated|Graduated) ;;
    *) return 0 ;;
  esac

  local priority horizon
  priority=$(_read_item_field "$BOARD_FILE" "$item_id" "priority" 2>/dev/null || true)
  horizon=$(_read_item_field "$BOARD_FILE" "$item_id" "horizon" 2>/dev/null || true)

  # Strip whitespace for trimmed-empty check.
  local trimmed_priority trimmed_horizon
  trimmed_priority=$(printf '%s' "$priority" | tr -d '[:space:]')
  trimmed_horizon=$(printf '%s' "$horizon" | tr -d '[:space:]')

  if [ -z "$trimmed_priority" ] || [ -z "$trimmed_horizon" ]; then
    local missing=""
    [ -z "$trimmed_priority" ] && missing="priority"
    [ -z "$trimmed_horizon" ] && { [ -n "$missing" ] && missing="${missing} and horizon" || missing="horizon"; }
    die "item '${item_id}': ${missing} must be set before transitioning to ${target_state} -- never auto-filled"
  fi
}

# ---------- Locked write helpers ----------

# Rewrite a single item's fields via awk. Tempfile + atomic mv.
_rewrite_item_field() {
  local target_id="$1" field="$2" new_value="$3"
  local file="$BOARD_FILE"

  # Sanitize the value at the write boundary — defense-in-depth.
  new_value=$(_sanitize_field "$new_value" 500)

  local tmp
  tmp=$(mktemp "${file}.tmp.XXXXXX")
  local _tmp_idx
  _GAIA_TMP_PATHS+=("$tmp")
  _tmp_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))

  # Escape val for single-quoted YAML: double every internal single-quote.
  local sq_value="${new_value//\'/\'\'}"

  awk -v target="$target_id" -v field="$field" -v val="$sq_value" '
    BEGIN { in_item = 0; rewrote = 0 }
    {
      raw = $0
      line = $0
      sub(/\r$/, "", line)
    }
    line ~ /^[[:space:]]*- id:[[:space:]]*/ {
      k = line
      sub(/^[[:space:]]*- id:[[:space:]]*/, "", k)
      gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", k)
      if (k == target) { in_item = 1 } else { in_item = 0 }
      print raw
      next
    }
    in_item && (line ~ /^[[:space:]]*- id:/ || line ~ /^[^[:space:]]/) {
      in_item = 0
    }
    in_item && !rewrote {
      pat = "^[[:space:]]+" field ":"
      if (line ~ pat) {
        match(raw, /^[[:space:]]+/)
        indent = substr(raw, RSTART, RLENGTH)
        printf "%s%s: '"'"'%s'"'"'\n", indent, field, val
        rewrote = 1
        next
      }
    }
    { print raw }
    END { if (!rewrote) exit 2 }
  ' "$file" > "$tmp" || {
    local rc=$?
    rm -f "$tmp"
    _GAIA_TMP_PATHS[$_tmp_idx]=""
    if [ "$rc" -eq 2 ]; then
      die "field '${field}' not found for item '${target_id}'"
    fi
    die "awk rewrite failed (rc=$rc)"
  }

  if ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    _GAIA_TMP_PATHS[$_tmp_idx]=""
    die "failed to mv tempfile over board file"
  fi
  _GAIA_TMP_PATHS[$_tmp_idx]=""
}

# Rewrite multiple fields on one item in a single pass.
_rewrite_item_fields() {
  local target_id="$1"
  shift
  # Remaining args are field=value pairs.
  local file="$BOARD_FILE"

  local tmp
  tmp=$(mktemp "${file}.tmp.XXXXXX")
  local _tmp_idx
  _GAIA_TMP_PATHS+=("$tmp")
  _tmp_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))

  # Build awk field-value assignments from the pairs.
  # Escape each value for single-quoted YAML: double every internal single-quote.
  # Use ASCII Unit Separator (0x1F) as field/value delimiter — it cannot appear
  # in YAML scalar text, so values containing '|' round-trip correctly.
  local us
  us=$(printf '\037')
  local awk_fields=""
  local pair
  for pair in "$@"; do
    local f="${pair%%=*}"
    local v="${pair#*=}"
    # Sanitize the value at the write boundary — defense-in-depth.
    v=$(_sanitize_field "$v" 500)
    v="${v//\'/\'\'}"
    awk_fields="${awk_fields}${f}${us}${v}\n"
  done

  awk -v target="$target_id" -v field_pairs="$awk_fields" -v sep="$(printf '\037')" '
    BEGIN {
      in_item = 0
      n = split(field_pairs, raw_pairs, "\n")
      for (i = 1; i <= n; i++) {
        if (raw_pairs[i] == "") continue
        split(raw_pairs[i], kv, sep)
        fields[kv[1]] = kv[2]
        field_count++
      }
    }
    {
      raw = $0
      line = $0
      sub(/\r$/, "", line)
    }
    line ~ /^[[:space:]]*- id:[[:space:]]*/ {
      k = line
      sub(/^[[:space:]]*- id:[[:space:]]*/, "", k)
      gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", k)
      if (k == target) { in_item = 1 } else { in_item = 0 }
      print raw
      next
    }
    in_item && (line ~ /^[[:space:]]*- id:/ || line ~ /^[^[:space:]]/) {
      in_item = 0
    }
    in_item {
      for (f in fields) {
        pat = "^[[:space:]]+" f ":"
        if (line ~ pat) {
          match(raw, /^[[:space:]]+/)
          indent = substr(raw, RSTART, RLENGTH)
          printf "%s%s: '"'"'%s'"'"'\n", indent, f, fields[f]
          next
        }
      }
    }
    { print raw }
  ' "$file" > "$tmp" || {
    local rc=$?
    rm -f "$tmp"
    _GAIA_TMP_PATHS[$_tmp_idx]=""
    die "awk multi-field rewrite failed (rc=$rc)"
  }

  if ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    _GAIA_TMP_PATHS[$_tmp_idx]=""
    die "failed to mv tempfile over board file"
  fi
  _GAIA_TMP_PATHS[$_tmp_idx]=""
}

# ---------- Locking ----------

_with_lock() {
  local callback="$1"
  shift

  local flock_bin
  flock_bin=$(command -v flock || true)

  if [ -n "$flock_bin" ]; then
    (
      exec 9>"$BOARD_LOCK"
      if ! "$flock_bin" -x -w 5 9; then
        die "flock timeout acquiring $BOARD_LOCK"
      fi
      "$callback" "$@"
    )
  else
    # set -C no-clobber spin-loop fallback.
    local tries=0
    while ! ( set -C; : > "$BOARD_LOCK" ) 2>/dev/null; do
      tries=$((tries + 1))
      if [ "$tries" -ge 50 ]; then
        die "lock timeout acquiring $BOARD_LOCK"
      fi
      sleep 0.1 2>/dev/null || sleep 1
    done
    # shellcheck disable=SC2064
    trap "rm -f '${BOARD_LOCK}'; _cleanup_tmps" EXIT INT TERM
    "$callback" "$@"
    rm -f "$BOARD_LOCK"
    trap '_cleanup_tmps' EXIT INT TERM
  fi
}

# ---------- Subcommand: capture ----------

_do_capture_locked() {
  local title="$1" source_text="$2"

  # Sanitize free-text inputs: strip all control chars (including newlines)
  # to prevent YAML multi-line scalar injection into the non-quote-aware
  # awk readers.  Applied here — the write boundary — so no injected
  # newline ever reaches the board file.
  title=$(_sanitize_field "$title" 500)
  source_text=$(_sanitize_field "$source_text" 200)

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local new_id
  new_id=$(_mint_id)

  if [ -f "$BOARD_FILE" ] && [ -s "$BOARD_FILE" ]; then
    # Append a new item to the existing items: list.
    local tmp
    tmp=$(mktemp "${BOARD_FILE}.tmp.XXXXXX")
    local _tmp_idx
    _GAIA_TMP_PATHS+=("$tmp")
    _tmp_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))

    local title_yaml source_yaml
    title_yaml=$(yaml_single_quote "$title")
    source_yaml=$(yaml_single_quote "$source_text")

    {
      cat "$BOARD_FILE"
      printf '  - id: "%s"\n' "$new_id"
      printf '    title: %s\n' "$title_yaml"
      printf '    source: %s\n' "$source_yaml"
      printf '    status: "Captured"\n'
      printf '    research_type: []\n'
      printf '    artifacts: []\n'
      printf '    value_signal: ""\n'
      printf '    effort_signal: ""\n'
      printf '    priority: ""\n'
      printf '    horizon: ""\n'
      printf '    decision_link: ""\n'
      printf '    graduated_feature_id: ""\n'
      printf '    created_at: "%s"\n' "$now"
      printf '    last_activity: "%s"\n' "$now"
      printf '    status_changed_at: "%s"\n' "$now"
    } > "$tmp"

    if ! mv -f "$tmp" "$BOARD_FILE"; then
      rm -f "$tmp"
      _GAIA_TMP_PATHS[$_tmp_idx]=""
      die "failed to mv tempfile over board file"
    fi
    _GAIA_TMP_PATHS[$_tmp_idx]=""
  else
    # Fresh board -- write the initial structure.
    local tmp
    tmp=$(mktemp "${BOARD_FILE}.tmp.XXXXXX")
    local _tmp_idx
    _GAIA_TMP_PATHS+=("$tmp")
    _tmp_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))

    local title_yaml source_yaml
    title_yaml=$(yaml_single_quote "$title")
    source_yaml=$(yaml_single_quote "$source_text")

    {
      printf 'items:\n'
      printf '  - id: "%s"\n' "$new_id"
      printf '    title: %s\n' "$title_yaml"
      printf '    source: %s\n' "$source_yaml"
      printf '    status: "Captured"\n'
      printf '    research_type: []\n'
      printf '    artifacts: []\n'
      printf '    value_signal: ""\n'
      printf '    effort_signal: ""\n'
      printf '    priority: ""\n'
      printf '    horizon: ""\n'
      printf '    decision_link: ""\n'
      printf '    graduated_feature_id: ""\n'
      printf '    created_at: "%s"\n' "$now"
      printf '    last_activity: "%s"\n' "$now"
      printf '    status_changed_at: "%s"\n' "$now"
    } > "$tmp"

    if ! mv -f "$tmp" "$BOARD_FILE"; then
      rm -f "$tmp"
      _GAIA_TMP_PATHS[$_tmp_idx]=""
      die "failed to mv tempfile over board file"
    fi
    _GAIA_TMP_PATHS[$_tmp_idx]=""
  fi

  printf '%s: captured item %s\n' "$SCRIPT_NAME" "$new_id"
}

cmd_capture() {
  local title="$1" source_text="$2"
  _with_lock _do_capture_locked "$title" "$source_text"
}

# ---------- Subcommand: transition ----------

_do_transition_locked() {
  local item_id="$1" to_state="$2"

  if [ ! -f "$BOARD_FILE" ] || [ ! -s "$BOARD_FILE" ]; then
    die "board file missing or empty: $BOARD_FILE"
  fi

  # Read current status.
  local from_state
  from_state=$(_read_item_field "$BOARD_FILE" "$item_id" "status" 2>/dev/null) || \
    die "item '${item_id}' not found in board"

  # No-op guard.
  if [ "$from_state" = "$to_state" ]; then
    die "item ${item_id} is already in state '${to_state}'"
  fi

  # Parked revive: validate against parked_from.
  if [ "$from_state" = "Parked" ] && [ "$to_state" != "Archived" ]; then
    local parked_from
    parked_from=$(_read_item_field "$BOARD_FILE" "$item_id" "parked_from" 2>/dev/null || true)
    if [ -z "$parked_from" ]; then
      die "illegal transition: cannot revive item '${item_id}' from Parked -- no parked_from recorded"
    fi
    if [ "$parked_from" != "$to_state" ]; then
      die "illegal transition: revive from Parked must go to '${parked_from}' (parked_from), not '${to_state}'"
    fi
  else
    validate_board_transition "$from_state" "$to_state"
  fi

  # Priority+horizon gate (AC5).
  _assert_priority_horizon "$item_id" "$to_state"

  # Perform the mutation.
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Build the list of fields to update.
  local update_fields=()
  update_fields+=("status=${to_state}")
  update_fields+=("last_activity=${now}")
  update_fields+=("status_changed_at=${now}")

  # On park, write status+timestamps+parked_from in a SINGLE atomic pass
  # so a crash between two sequential mvs cannot leave the board with
  # status=Parked but no parked_from (which would break revive).
  if [ "$to_state" = "Parked" ]; then
    local file="$BOARD_FILE"
    local tmp
    tmp=$(mktemp "${file}.tmp.XXXXXX")
    local _tmp_idx
    _GAIA_TMP_PATHS+=("$tmp")
    _tmp_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))

    awk -v target="$item_id" -v new_status="$to_state" \
        -v new_activity="$now" -v new_changed="$now" \
        -v park_from="$from_state" '
      BEGIN { in_item = 0; wrote_parked_from = 0 }
      {
        raw = $0
        line = $0
        sub(/\r$/, "", line)
      }
      line ~ /^[[:space:]]*- id:[[:space:]]*/ {
        k = line
        sub(/^[[:space:]]*- id:[[:space:]]*/, "", k)
        gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", k)
        if (k == target) { in_item = 1; wrote_parked_from = 0 }
        else             { in_item = 0 }
        print raw
        next
      }
      in_item && (line ~ /^[[:space:]]*- id:/ || line ~ /^[^[:space:]]/) {
        in_item = 0
      }
      in_item && line ~ /^[[:space:]]+status:/ {
        match(raw, /^[[:space:]]+/)
        indent = substr(raw, RSTART, RLENGTH)
        printf "%sstatus: '"'"'%s'"'"'\n", indent, new_status
        next
      }
      in_item && line ~ /^[[:space:]]+last_activity:/ {
        match(raw, /^[[:space:]]+/)
        indent = substr(raw, RSTART, RLENGTH)
        printf "%slast_activity: '"'"'%s'"'"'\n", indent, new_activity
        next
      }
      in_item && line ~ /^[[:space:]]+status_changed_at:/ {
        match(raw, /^[[:space:]]+/)
        indent = substr(raw, RSTART, RLENGTH)
        printf "%sstatus_changed_at: '"'"'%s'"'"'\n", indent, new_changed
        # Insert parked_from right after status_changed_at when absent.
        if (!wrote_parked_from) {
          printf "%sparked_from: '"'"'%s'"'"'\n", indent, park_from
          wrote_parked_from = 1
        }
        next
      }
      in_item && line ~ /^[[:space:]]+parked_from:/ {
        match(raw, /^[[:space:]]+/)
        indent = substr(raw, RSTART, RLENGTH)
        printf "%sparked_from: '"'"'%s'"'"'\n", indent, park_from
        wrote_parked_from = 1
        next
      }
      { print raw }
    ' "$file" > "$tmp" || {
      local rc=$?
      rm -f "$tmp"
      _GAIA_TMP_PATHS[$_tmp_idx]=""
      die "awk park rewrite failed (rc=$rc)"
    }

    if ! mv -f "$tmp" "$file"; then
      rm -f "$tmp"
      _GAIA_TMP_PATHS[$_tmp_idx]=""
      die "failed to mv tempfile over board file"
    fi
    _GAIA_TMP_PATHS[$_tmp_idx]=""
  else
    _rewrite_item_fields "$item_id" "${update_fields[@]}"
  fi

  printf '%s: %s transitioned %s -> %s\n' "$SCRIPT_NAME" "$item_id" "$from_state" "$to_state"
}

cmd_transition() {
  local item_id="$1" to_state="$2"

  # Fail-fast: refuse non-canonical target BEFORE the flock and BEFORE any
  # tempfile -- board is guaranteed byte-identical on rejection.
  assert_canonical_board_state "$to_state" "transition --to"

  _with_lock _do_transition_locked "$item_id" "$to_state"
}

# ---------- Subcommand: get ----------

cmd_get() {
  local item_id="$1"

  if [ ! -f "$BOARD_FILE" ] || [ ! -s "$BOARD_FILE" ]; then
    die "board file missing or empty: $BOARD_FILE"
  fi

  _print_item_block "$BOARD_FILE" "$item_id" || \
    die "item '${item_id}' not found in board"
}

# ---------- Subcommand: validate ----------

cmd_validate() {
  if [ ! -f "$BOARD_FILE" ] || [ ! -s "$BOARD_FILE" ]; then
    die "board file missing or empty: $BOARD_FILE"
  fi

  # Read-validate every item's status field.
  local errors=0
  local all_statuses
  all_statuses=$(awk '
    {
      line = $0
      sub(/\r$/, "", line)
    }
    line ~ /^[[:space:]]+status:[[:space:]]*/ {
      v = line
      sub(/^[[:space:]]+status:[[:space:]]*/, "", v)
      gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", v)
      print v
    }
  ' "$BOARD_FILE")

  local s
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    if ! is_canonical_board_state "$s"; then
      printf '%s: error: invalid board status: %q -- allowed: %s\n' \
        "$SCRIPT_NAME" "$s" "$(canonical_board_states_hint)" >&2
      errors=$((errors + 1))
    fi
  done <<< "$all_statuses"

  if [ "$errors" -gt 0 ]; then
    exit 1
  fi
  return 0
}

# ---------- Subcommand: board ----------

# _get_now_epoch — return current time as epoch. Respects GAIA_DISCOVERY_NOW
# for deterministic testing.
_get_now_epoch() {
  if [ -n "${GAIA_DISCOVERY_NOW:-}" ]; then
    printf '%s' "$GAIA_DISCOVERY_NOW"
  else
    date -u +%s
  fi
}

cmd_board() {
  local filter_horizon="${1:-}" filter_priority="${2:-}"

  if [ ! -f "$BOARD_FILE" ] || [ ! -s "$BOARD_FILE" ]; then
    die "board file missing or empty: $BOARD_FILE"
  fi

  local now_epoch
  now_epoch=$(_get_now_epoch)

  # Read all items and render. Pure read path — no writes.
  awk -v f_horizon="$filter_horizon" -v f_priority="$filter_priority" \
      -v now_epoch="$now_epoch" '
    BEGIN {
      in_item = 0
      item_idx = 0
      # Terminal states get no idle advisory.
      terminal["Graduated"] = 1
      terminal["Archived"] = 1
    }
    {
      line = $0
      sub(/\r$/, "", line)
    }

    # Detect start of a new item.
    line ~ /^[[:space:]]*- id:[[:space:]]*/ {
      # Flush previous item if any.
      if (in_item) _flush_item()
      in_item = 1
      item_idx++
      cur_id = line
      sub(/^[[:space:]]*- id:[[:space:]]*/, "", cur_id)
      gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", cur_id)
      cur_title = ""
      cur_status = ""
      cur_priority = ""
      cur_horizon = ""
      cur_last_activity = ""
      next
    }

    # End of item (new list entry or top-level key).
    in_item && (line ~ /^[[:space:]]*- id:/ || line ~ /^[^[:space:]]/) {
      _flush_item()
      in_item = 0
    }

    in_item && line ~ /^[[:space:]]+title:/ {
      cur_title = line
      sub(/^[[:space:]]+title:[[:space:]]*/, "", cur_title)
      gsub(/^["'"'"']+|["'"'"']+$/, "", cur_title)
    }
    in_item && line ~ /^[[:space:]]+status:/ {
      cur_status = line
      sub(/^[[:space:]]+status:[[:space:]]*/, "", cur_status)
      gsub(/^["'"'"']+|["'"'"']+$/, "", cur_status)
    }
    in_item && line ~ /^[[:space:]]+priority:/ {
      cur_priority = line
      sub(/^[[:space:]]+priority:[[:space:]]*/, "", cur_priority)
      gsub(/^["'"'"']+|["'"'"']+$/, "", cur_priority)
    }
    in_item && line ~ /^[[:space:]]+horizon:/ {
      cur_horizon = line
      sub(/^[[:space:]]+horizon:[[:space:]]*/, "", cur_horizon)
      gsub(/^["'"'"']+|["'"'"']+$/, "", cur_horizon)
    }
    in_item && line ~ /^[[:space:]]+last_activity:/ {
      cur_last_activity = line
      sub(/^[[:space:]]+last_activity:[[:space:]]*/, "", cur_last_activity)
      gsub(/^["'"'"']+|["'"'"']+$/, "", cur_last_activity)
    }

    END {
      if (in_item) _flush_item()
    }

    function _flush_item() {
      # Apply filters.
      if (f_horizon != "" && cur_horizon != f_horizon) return
      if (f_priority != "" && cur_priority != f_priority) return

      # Compute idle advisory (presentation-only, never mutates).
      idle_label = ""
      if (!(cur_status in terminal) && cur_last_activity != "") {
        idle_label = _compute_idle(cur_last_activity, now_epoch)
      }

      # Render line.
      printf "%s  %-14s  %-8s  %-6s", cur_id, cur_status, cur_priority, cur_horizon
      if (idle_label != "") {
        printf "  [%s]", idle_label
      }
      printf "  %s\n", cur_title
    }

    function _compute_idle(ts, now,    epoch, delta_days) {
      # Parse ISO timestamp to epoch via shell date.
      # awk cannot parse ISO dates natively, so we use a pre-computed
      # formula: YYYY-MM-DDTHH:MM:SSZ -> epoch.
      # Since awk has limited date parsing, we use mktime if available
      # or fall back to a simplified calculation.
      epoch = _iso_to_epoch(ts)
      if (epoch == 0) return ""
      delta_days = int((now - epoch) / 86400)
      if (delta_days >= 90) return "idle >90d"
      if (delta_days >= 60) return "idle >60d"
      if (delta_days >= 30) return "idle >30d"
      return ""
    }

    function _iso_to_epoch(ts,    y, m, d, h, mi, s, epoch) {
      # Parse "YYYY-MM-DDTHH:MM:SSZ" into components.
      if (length(ts) < 19) return 0
      y = substr(ts, 1, 4) + 0
      m = substr(ts, 6, 2) + 0
      d = substr(ts, 9, 2) + 0
      h = substr(ts, 12, 2) + 0
      mi = substr(ts, 15, 2) + 0
      s = substr(ts, 18, 2) + 0
      # Use gawk mktime if available; fall back to manual calculation.
      epoch = _manual_epoch(y, m, d, h, mi, s)
      return epoch
    }

    function _manual_epoch(y, m, d, h, mi, s,    days, i, mdays) {
      # Days from Unix epoch (1970-01-01) to the given UTC date.
      # Simplified — accurate enough for idle-advisory thresholds.
      days = 0
      for (i = 1970; i < y; i++) {
        days += (_is_leap(i) ? 366 : 365)
      }
      split("31 28 31 30 31 30 31 31 30 31 30 31", mdays, " ")
      if (_is_leap(y)) mdays[2] = 29
      for (i = 1; i < m; i++) {
        days += mdays[i]
      }
      days += d - 1
      return days * 86400 + h * 3600 + mi * 60 + s
    }

    function _is_leap(y) {
      return (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0)
    }
  ' "$BOARD_FILE"
}

# ---------- Subcommand: prioritize ----------

_do_prioritize_locked() {
  local item_id="$1" priority="$2" horizon="$3"

  if [ ! -f "$BOARD_FILE" ] || [ ! -s "$BOARD_FILE" ]; then
    die "board file missing or empty: $BOARD_FILE"
  fi

  # Sanitize inputs: defense-in-depth — a newline in priority/horizon would
  # exploit the same non-quote-aware awk readers.
  priority=$(_sanitize_field "$priority" 50)
  horizon=$(_sanitize_field "$horizon" 50)

  # Verify item exists.
  _read_item_field "$BOARD_FILE" "$item_id" "id" >/dev/null 2>&1 || \
    die "item '${item_id}' not found in board"

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  _rewrite_item_fields "$item_id" \
    "priority=${priority}" \
    "horizon=${horizon}" \
    "last_activity=${now}"

  printf '%s: %s prioritized (priority=%s, horizon=%s)\n' \
    "$SCRIPT_NAME" "$item_id" "$priority" "$horizon"
}

cmd_prioritize() {
  local item_id="$1" priority="$2" horizon="$3"
  _with_lock _do_prioritize_locked "$item_id" "$priority" "$horizon"
}

# ---------- Subcommand: graduate ----------

_do_graduate_locked() {
  local item_id="$1" from_discovery="$2" feature_id="$3"

  if [ ! -f "$BOARD_FILE" ] || [ ! -s "$BOARD_FILE" ]; then
    die "board file missing or empty: $BOARD_FILE"
  fi

  # Verify item exists and read status.
  local cur_status
  cur_status=$(_read_item_field "$BOARD_FILE" "$item_id" "status" 2>/dev/null) || \
    die "item '${item_id}' not found in board"

  # Graduate is only allowed from Evaluated (or Captured for fast-track via
  # the transition adjacency). For the graduate subcommand, we require
  # Evaluated — the sole sanctioned graduation edge.
  if [ "$cur_status" = "Graduated" ]; then
    die "item '${item_id}' is already Graduated"
  fi
  if _is_terminal_state "$cur_status"; then
    die "item '${item_id}' is in terminal state '${cur_status}' -- cannot graduate"
  fi
  if [ "$cur_status" != "Evaluated" ]; then
    die "item '${item_id}' is in state '${cur_status}' -- must be Evaluated before graduation"
  fi

  # Read item fields for track detection + bar validation.
  local title source artifacts decision_link priority horizon
  title=$(_read_item_field "$BOARD_FILE" "$item_id" "title" 2>/dev/null || true)
  source=$(_read_item_field "$BOARD_FILE" "$item_id" "source" 2>/dev/null || true)
  artifacts=$(_read_item_field "$BOARD_FILE" "$item_id" "artifacts" 2>/dev/null || true)
  decision_link=$(_read_item_field "$BOARD_FILE" "$item_id" "decision_link" 2>/dev/null || true)
  priority=$(_read_item_field "$BOARD_FILE" "$item_id" "priority" 2>/dev/null || true)
  horizon=$(_read_item_field "$BOARD_FILE" "$item_id" "horizon" 2>/dev/null || true)

  # Priority+horizon gate (composing AND with track-specific bar).
  _assert_priority_horizon "$item_id" "Graduated"

  # Auto-detect track.
  local track
  track=$(_detect_track "$artifacts" "$decision_link")

  # Enforce per-track minimum bar (fails fast on unmet requirements).
  _validate_track_bar "$item_id" "$track" "$title" "$source" "$artifacts" "$decision_link"

  # ---- All gates passed ----

  # If --from-discovery: emit hydrated intake fields BEFORE transitioning.
  if [ "$from_discovery" = "true" ]; then
    _emit_hydrated_intake "$title" "$source" "$priority"
  fi

  # Perform the transition to Graduated (AC5: side-effect ordering —
  # transition happens AFTER all validation and hydration emission).
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local update_fields=()
  update_fields+=("status=Graduated")
  update_fields+=("last_activity=${now}")
  update_fields+=("status_changed_at=${now}")
  if [ -n "$feature_id" ]; then
    update_fields+=("graduated_feature_id=${feature_id}")
  fi

  _rewrite_item_fields "$item_id" "${update_fields[@]}"

  _log_info "${item_id} graduated via ${track} track"
}

cmd_graduate() {
  local item_id="$1" from_discovery="$2" feature_id="$3"
  _with_lock _do_graduate_locked "$item_id" "$from_discovery" "$feature_id"
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
    capture|transition|get|validate|board|prioritize|graduate)
      ;;
    *)
      printf '%s: error: unknown subcommand: %s\n' "$SCRIPT_NAME" "$subcmd" >&2
      usage >&2
      exit 1
      ;;
  esac

  local item_id="" to_state="" title="" source_text="" priority="" horizon=""
  local from_discovery="false" feature_id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --id)
        [ $# -ge 2 ] || die "--id requires a value"
        item_id="$2"; shift 2 ;;
      --id=*)
        item_id="${1#--id=}"; shift ;;
      --to)
        [ $# -ge 2 ] || die "--to requires a value"
        to_state="$2"; shift 2 ;;
      --to=*)
        to_state="${1#--to=}"; shift ;;
      --title)
        [ $# -ge 2 ] || die "--title requires a value"
        title="$2"; shift 2 ;;
      --title=*)
        title="${1#--title=}"; shift ;;
      --source)
        [ $# -ge 2 ] || die "--source requires a value"
        source_text="$2"; shift 2 ;;
      --source=*)
        source_text="${1#--source=}"; shift ;;
      --priority)
        [ $# -ge 2 ] || die "--priority requires a value"
        priority="$2"; shift 2 ;;
      --priority=*)
        priority="${1#--priority=}"; shift ;;
      --horizon)
        [ $# -ge 2 ] || die "--horizon requires a value"
        horizon="$2"; shift 2 ;;
      --horizon=*)
        horizon="${1#--horizon=}"; shift ;;
      --from-discovery)
        from_discovery="true"; shift ;;
      --feature-id)
        [ $# -ge 2 ] || die "--feature-id requires a value"
        feature_id="$2"; shift 2 ;;
      --feature-id=*)
        feature_id="${1#--feature-id=}"; shift ;;
      --help|-h)
        usage
        exit 0 ;;
      *)
        die "unknown flag: $1" ;;
    esac
  done

  resolve_board_paths

  case "$subcmd" in
    capture)
      [ -n "$title" ] || die "capture requires --title <text>"
      [ -n "$source_text" ] || die "capture requires --source <text>"
      cmd_capture "$title" "$source_text"
      ;;
    transition)
      [ -n "$item_id" ] || die "transition requires --id <id>"
      [ -n "$to_state" ] || die "transition requires --to <state>"
      cmd_transition "$item_id" "$to_state"
      ;;
    get)
      [ -n "$item_id" ] || die "get requires --id <id>"
      cmd_get "$item_id"
      ;;
    validate)
      cmd_validate
      ;;
    board)
      cmd_board "$horizon" "$priority"
      ;;
    prioritize)
      [ -n "$item_id" ] || die "prioritize requires --id <id>"
      [ -n "$priority" ] || die "prioritize requires --priority <p>"
      [ -n "$horizon" ] || die "prioritize requires --horizon <h>"
      cmd_prioritize "$item_id" "$priority" "$horizon"
      ;;
    graduate)
      [ -n "$item_id" ] || die "graduate requires --id <id>"
      cmd_graduate "$item_id" "$from_discovery" "$feature_id"
      ;;
  esac
}

main "$@"
