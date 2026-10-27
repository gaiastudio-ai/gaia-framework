#!/usr/bin/env bash
# action-items-write.sh — inline action-items writer
#
# Writes structured entries to .gaia/state/action-items.yaml (canonical)
# following the Action Items Schema.
#
# NOTE: The classification enum lists {clarification|implementation|process|automation}.
# Triage entries additionally use {bug|task|research}. This script
# accepts all seven values as authoritative.
#
# Public functions (each has a direct unit test):
#   - aiw_bootstrap_file         — create file with schema header if absent
#   - aiw_next_id                — compute next AI-{n} id
#   - aiw_check_dedup            — idempotent dedup by composite key
#   - aiw_detect_indent          — detect list-entry indent of existing file
#   - aiw_validate_classification — enforce explicit classification enum
#   - _aiw_yaml_escape           — escape a string for double-quoted YAML
#   - aiw_build_entry            — build a YAML entry string
#   - aiw_append_entry           — atomic append with flock
#   - aiw_write                  — top-level orchestrator
#
# Usage (as library — sourced by SKILL.md steps):
#   source action-items-write.sh
#   aiw_write --target <path> --sprint-id <id> --classification <cls> \
#             --text <text> --ref-key <story_key|finding_id> --ref-value <val>
#
# Exit codes:
#   0 — entry written or skipped (idempotent)
#   1 — error (validation failure, IO error)
#
# Output (stdout):
#   status=ok              — entry appended
#   status=skipped_idempotent — dedup hit, no write
#   status=error           — on failure (with reason=)

set -uo pipefail

# ---------------------------------------------------------------------------
# aiw_bootstrap_file — create action-items.yaml with canonical schema header
# ---------------------------------------------------------------------------
aiw_bootstrap_file() {
  local target="$1"
  if [ -e "$target" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$target")"
  cat > "$target" <<'EOF'
# Action Items schema
# Written by /gaia-retro shared writer. Each entry:
#   id: AI-{n}            # auto-incremented
#   sprint_id: "..."
#   text: "..."
#   classification: clarification|implementation|process|automation
#   status: open|in-progress|resolved
#   escalation_count: 0    # bumped by cross-retro detection
#   created_at: "<ISO 8601>"
#   theme_hash: "sha256:<hex>"
items:
EOF
}

# ---------------------------------------------------------------------------
# aiw_next_id — compute next AI-{n} from existing entries
# Handles both quoted (id: "AI-6") and unquoted (id: AI-6) id values.
# Anchored to item id lines only: ignores dated ids (AI-YYYY-MM-DD-N),
# embedded text, and non-item fields like parent_id.
# ---------------------------------------------------------------------------
aiw_next_id() {
  local target="$1"
  local max_n=0
  if [ -f "$target" ]; then
    max_n="$(awk '
      /^[[:space:]]*-[[:space:]]+id:[[:space:]]+"?AI-[0-9]+"?[[:space:]]*$/ {
        match($0, /AI-[0-9]+/)
        n = substr($0, RSTART + 3, RLENGTH - 3) + 0
        if (n > max) max = n
      }
      END { print max + 0 }
    ' "$target")"
  fi
  printf 'AI-%d\n' "$((max_n + 1))"
}

# ---------------------------------------------------------------------------
# aiw_check_dedup — idempotent dedup by composite key
# Args: target sprint_id classification ref_key ref_value
# Returns: 0 if duplicate found, 1 if no match
# ---------------------------------------------------------------------------
aiw_check_dedup() {
  local target="$1" sprint_id="$2" classification="$3" ref_key="$4" ref_value="$5"
  if [ ! -f "$target" ]; then
    return 1
  fi
  # Use awk to scan YAML entries for matching composite key.
  # An entry matches when sprint_id, classification, and ref_key=ref_value all match.
  # Compare against escaped values so dedup works for values containing
  # quotes, backslashes or newlines. Pass via ENVIRON to avoid awk -v
  # backslash interpretation.
  local _esc_sid _esc_rv
  _esc_sid="$(_aiw_yaml_escape "$sprint_id")"
  _esc_rv="$(_aiw_yaml_escape "$ref_value")"
  local found
  found="$(AIW_SID="$_esc_sid" AIW_CLS="$classification" AIW_RK="$ref_key" AIW_RV="$_esc_rv" \
    awk '
    BEGIN { sid=ENVIRON["AIW_SID"]; cls=ENVIRON["AIW_CLS"]; rk=ENVIRON["AIW_RK"]; rv=ENVIRON["AIW_RV"] }
    /^[[:space:]]*- id:/ {
      if (in_entry && s_match && c_match && r_match) { matched=1; exit }
      in_entry=1; s_match=0; c_match=0; r_match=0
      # Record the field indent: indent of "- " plus 2
      match($0, /^[[:space:]]*/)
      field_indent = RLENGTH + 2
      next
    }
    in_entry {
      # Skip blank / whitespace-only lines (not an entry boundary)
      if ($0 ~ /^[[:space:]]*$/) next
      # Detect end-of-entry: non-blank line with less indent than fields
      # (new entries handled above; comments at column 0 end the entry)
      match($0, /^[[:space:]]*/)
      li = RLENGTH
      if (li < field_indent) {
        if (s_match && c_match && r_match) { matched=1; exit }
        in_entry=0; next
      }
      # Skip nested-map lines (deeper indent than entry fields)
      if (li > field_indent) next

      line = $0; sub(/^[[:space:]]+/, "", line); sub(/\r$/, "", line)
      colon = index(line, ":")
      if (colon > 0) {
        fk = substr(line, 1, colon - 1)
        # Only extract values for the three compared keys (performance)
        if (fk != "sprint_id" && fk != "classification" && fk != rk) next
        raw = substr(line, colon + 1)
        sub(/^[[:space:]]+/, "", raw)
        # Extract value: handle quoted and unquoted forms.
        # Only reached for compared keys (3 per entry), so the walk is cheap.
        if (substr(raw, 1, 1) == "\"") {
          # Quoted: walk to find unescaped closing quote
          fv = ""; rest = substr(raw, 2); j = 1
          while (j <= length(rest)) {
            ch = substr(rest, j, 1)
            if (ch == "\\" && j < length(rest)) {
              fv = fv substr(rest, j, 2); j += 2; continue
            }
            if (ch == "\"") break
            fv = fv ch; j++
          }
        } else {
          # Unquoted: strip inline YAML comment
          fv = raw
          sub(/[[:space:]]+#.*$/, "", fv)
          sub(/[[:space:]]+$/, "", fv)
        }
        if (fk == "sprint_id" && fv == sid) s_match=1
        if (fk == "classification" && fv == cls) c_match=1
        if (fk == rk && fv == rv) r_match=1
      }
    }
    END {
      if (!matched && in_entry && s_match && c_match && r_match) matched=1
      if (matched) print "MATCH"
    }
  ' "$target")"
  if [ "$found" = "MATCH" ]; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# aiw_detect_indent — detect the indent prefix of existing list entries
# Returns the whitespace before the LAST "- id:" item line (append
# position). Skips comment lines; defaults to "  " (2-space) when no
# entries exist.
# ---------------------------------------------------------------------------
aiw_detect_indent() {
  local target="$1"
  if [ -f "$target" ]; then
    local line
    # Match only real item lines (skip comments), take the last one
    line="$(grep '^[[:space:]]*- id:' "$target" | tail -1)"
    if [ -n "$line" ]; then
      printf '%s' "${line%%- id:*}"
      return
    fi
  fi
  printf '  '
}

# ---------------------------------------------------------------------------
# aiw_validate_classification — enforce explicit classification enum
# ---------------------------------------------------------------------------
aiw_validate_classification() {
  local cls="$1"
  case "$cls" in
    clarification|implementation|process|automation|bug|task|research)
      return 0
      ;;
    *)
      printf 'HALT: Unknown classification "%s". Allowed: clarification, implementation, process, automation, bug, task, research.\n' "$cls"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# _aiw_yaml_escape — escape a string for use inside double-quoted YAML scalar.
# Escapes backslash, double-quote, newline and carriage return.
# ---------------------------------------------------------------------------
_aiw_yaml_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# _aiw_has_control_chars — return 0 if string contains C0 control characters
# (0x00-0x08, 0x0B-0x0C, 0x0E-0x1F) or DEL (0x7F). Tab, LF and CR are
# allowed (escaped by _aiw_yaml_escape). All bytes >= 0x80 (non-ASCII /
# UTF-8) pass through.
# Uses LC_ALL=C tr to strip every ALLOWED byte, then checks if anything
# remains. Fails closed: if tr or grep error, the string is rejected.
# ---------------------------------------------------------------------------
_aiw_has_control_chars() {
  local remainder
  # Keep only disallowed bytes: delete tab, LF, CR, printable ASCII (0x20-0x7E)
  # and all high bytes (0x80-0xFF). Anything left is a C0 control or DEL.
  remainder="$(printf '%s' "$1" | LC_ALL=C tr -d '\011\012\015\040-\176\200-\377')" || return 0
  if [ -n "$remainder" ]; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# _aiw_check_unicode_safety — return 0 (unsafe) if string contains NEL
# (U+0085), non-character codepoints U+FFFE/U+FFFF, or invalid UTF-8 byte
# sequences. Prints the character class to stdout on match. Fails closed:
# if od or awk is unavailable, the string is rejected.
# ---------------------------------------------------------------------------
_aiw_check_unicode_safety() {
  local s="$1"
  [ -z "$s" ] && return 1
  local LC_ALL=C
  # NEL (U+0085): UTF-8 bytes 0xC2 0x85
  case "$s" in *$'\xc2\x85'*)
    printf 'NEL (U+0085)\n'; return 0 ;; esac
  # U+FFFE: UTF-8 bytes 0xEF 0xBF 0xBE
  case "$s" in *$'\xef\xbf\xbe'*)
    printf 'non-character U+FFFE\n'; return 0 ;; esac
  # U+FFFF: UTF-8 bytes 0xEF 0xBF 0xBF
  case "$s" in *$'\xef\xbf\xbf'*)
    printf 'non-character U+FFFF\n'; return 0 ;; esac
  # Structural UTF-8 validation via od + awk byte-level state machine.
  # Rejects overlongs (C0-C1, E0 80-9F, F0 80-8F), surrogates (ED A0-BF),
  # codepoints > U+10FFFF (F4 90+), F5-FF lead bytes, truncated sequences,
  # and 5+ byte forms. Portable: od and awk are POSIX; no strtonum needed.
  # Fails closed: if od or awk is absent, the pipeline errors and we reject.
  # The -v flag prevents od from collapsing repeated 16-byte lines to '*',
  # which would hide invalid bytes and cause false rejections of valid text.
  # Explicit exit-status capture ensures fail-closed even without pipefail.
  local _od_out _od_rc=0
  _od_out="$(printf '%s' "$s" | LC_ALL=C od -v -An -tx1)" || _od_rc=$?
  if [ "$_od_rc" -ne 0 ]; then
    printf 'invalid UTF-8 byte sequence\n'; return 0
  fi
  if ! printf '%s\n' "$_od_out" | awk '
    function hv(h,  a,b) {
      a = index("0123456789abcdef", substr(h,1,1)) - 1
      b = index("0123456789abcdef", substr(h,2,1)) - 1
      return a * 16 + b
    }
    { for (i = 1; i <= NF; i++) {
        b = hv($i)
        if (need > 0) {
          if (b < 128 || b > 191) exit 1
          need--
          if (need == fn - 1) {
            if (blo > 0 && b < blo) exit 1
            if (bhi > 0 && b > bhi) exit 1
          }
        } else if (b <= 127) {
          ;
        } else if (b >= 194 && b <= 223) {
          need = 1; fn = 1; blo = 0; bhi = 0
        } else if (b == 224) {
          need = 2; fn = 2; blo = 160; bhi = 0
        } else if (b >= 225 && b <= 236) {
          need = 2; fn = 2; blo = 0; bhi = 0
        } else if (b == 237) {
          need = 2; fn = 2; blo = 0; bhi = 159
        } else if (b >= 238 && b <= 239) {
          need = 2; fn = 2; blo = 0; bhi = 0
        } else if (b == 240) {
          need = 3; fn = 3; blo = 144; bhi = 0
        } else if (b >= 241 && b <= 243) {
          need = 3; fn = 3; blo = 0; bhi = 0
        } else if (b == 244) {
          need = 3; fn = 3; blo = 0; bhi = 143
        } else { exit 1 }
    } }
    END { if (need > 0) exit 1 }
  '; then
    printf 'invalid UTF-8 byte sequence\n'; return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# aiw_build_entry — build a YAML entry string
# Args: id sprint_id classification text ref_key ref_value [list_prefix]
# list_prefix defaults to "  " (2-space); pass "" for 0-indent entries.
# All values are escaped for safe inclusion in double-quoted YAML scalars.
# ---------------------------------------------------------------------------
aiw_build_entry() {
  local id="$1" sprint_id="$2" classification="$3" text="$4" ref_key="$5" ref_value="$6"
  local list_prefix="${7-  }"
  local field_prefix="${list_prefix}  "
  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  local theme_hash
  theme_hash="$(printf '%s' "$text" | shasum -a 256 | awk '{print $1}')"

  local safe_text safe_value safe_sprint
  safe_text="$(_aiw_yaml_escape "$text")"
  safe_value="$(_aiw_yaml_escape "$ref_value")"
  safe_sprint="$(_aiw_yaml_escape "$sprint_id")"

  printf '%s' "${list_prefix}"
  printf -- '- id: "%s"\n' "$id"
  printf '%ssprint_id: "%s"\n' "$field_prefix" "$safe_sprint"
  printf '%stext: "%s"\n' "$field_prefix" "$safe_text"
  printf '%sclassification: "%s"\n' "$field_prefix" "$classification"
  printf '%sstatus: "open"\n' "$field_prefix"
  printf '%sescalation_count: 0\n' "$field_prefix"
  printf '%screated_at: "%s"\n' "$field_prefix" "$timestamp"
  printf '%stheme_hash: "sha256:%s"\n' "$field_prefix" "$theme_hash"
  printf '%s%s: "%s"\n' "$field_prefix" "$ref_key" "$safe_value"
}

# ---------------------------------------------------------------------------
# aiw_append_entry — atomic append with flock
# Args: target entry_text
# ---------------------------------------------------------------------------
aiw_append_entry() {
  local target="$1" entry_text="$2"
  local lockdir="${target}.lockdir"

  _do_append() {
    printf '\n%s\n' "$entry_text" >> "$target"
  }

  if command -v flock >/dev/null 2>&1; then
    local lockfile="${target}.lock"
    (
      flock -x 9
      _do_append
    ) 9>"$lockfile"
    rm -f "$lockfile"
  else
    # macOS fallback — mkdir-based mutex
    local tries=0
    while ! mkdir "$lockdir" 2>/dev/null; do
      tries=$((tries + 1))
      [ "$tries" -gt 600 ] && { rmdir "$lockdir" 2>/dev/null || true; break; }
      sleep 0.02
    done
    _do_append
    rmdir "$lockdir" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# aiw_write — top-level orchestrator
# ---------------------------------------------------------------------------
aiw_write() {
  local target="" sprint_id="" classification="" text="" ref_key="" ref_value=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --target)         target="$2"; shift 2 ;;
      --sprint-id)      sprint_id="$2"; shift 2 ;;
      --classification) classification="$2"; shift 2 ;;
      --text)           text="$2"; shift 2 ;;
      --ref-key)        ref_key="$2"; shift 2 ;;
      --ref-value)      ref_value="$2"; shift 2 ;;
      *) printf 'status=error\nreason=unknown arg: %s\n' "$1"; return 1 ;;
    esac
  done

  # Validate required args
  if [ -z "$target" ]; then
    printf 'status=error\nreason=--target is required\n'
    return 1
  fi
  if [ -z "$sprint_id" ]; then
    printf 'status=error\nreason=--sprint-id is required\n'
    return 1
  fi
  if [ -z "$classification" ]; then
    printf 'status=error\nreason=--classification is required\n'
    return 1
  fi
  if [ -z "$ref_key" ]; then
    printf 'status=error\nreason=--ref-key is required\n'
    return 1
  fi
  if [ -z "$ref_value" ]; then
    printf 'status=error\nreason=--ref-value is required\n'
    return 1
  fi

  # Validate ref_key is a plain identifier (no newlines, spaces, or special chars)
  case "$ref_key" in
    ''|*[!A-Za-z0-9_]*)
      printf 'status=error\nreason=--ref-key must be a plain identifier (letters, digits, underscore)\n'
      return 1
      ;;
  esac

  # Reject ref_key that duplicates a built-in entry field name
  case "$ref_key" in
    id|status|sprint_id|classification|text|created_at|escalation_count|theme_hash)
      printf 'status=error\nreason=--ref-key must not be a built-in field name (%s)\n' "$ref_key"
      return 1
      ;;
  esac

  # Reject control characters (below 0x20 except tab, plus 0x7F) in any value
  local _val
  for _val in "$text" "$ref_value" "$sprint_id"; do
    if _aiw_has_control_chars "$_val"; then
      printf 'status=error\nreason=value contains disallowed control characters\n'
      return 1
    fi
  done

  # Reject unsafe Unicode: NEL, non-character codepoints, invalid UTF-8
  local _unicode_reason
  for _val in "$text" "$ref_value" "$sprint_id"; do
    if _unicode_reason="$(_aiw_check_unicode_safety "$_val")"; then
      printf 'status=error\nreason=value contains disallowed character: %s\n' "$_unicode_reason"
      return 1
    fi
  done

  # Validate classification before any file writes
  if ! aiw_validate_classification "$classification"; then
    return 1
  fi

  # Bootstrap file if missing
  aiw_bootstrap_file "$target"

  # Idempotency check
  if aiw_check_dedup "$target" "$sprint_id" "$classification" "$ref_key" "$ref_value"; then
    printf 'status=skipped_idempotent\nreason=entry with matching composite key already exists\n'
    return 0
  fi

  # Compute next id
  local next_id
  next_id="$(aiw_next_id "$target")"

  # Detect indent of existing entries and match it (uses last entry's indent)
  local indent
  indent="$(aiw_detect_indent "$target")"

  # Build entry
  local entry
  entry="$(aiw_build_entry "$next_id" "$sprint_id" "$classification" "$text" "$ref_key" "$ref_value" "$indent")"

  # Refuse to write through a symlink (planted-symlink attack surface)
  if [ -L "$target" ]; then
    printf 'status=error\nreason=target is a symlink; refusing to write\n'
    return 1
  fi

  # Atomic append
  aiw_append_entry "$target" "$entry"

  printf 'status=ok\nid=%s\ntarget=%s\n' "$next_id" "$target"
  return 0
}

# ---------------------------------------------------------------------------
# aiw_resolve — update an existing action item's status fields in place
# ---------------------------------------------------------------------------
#
# Public function (direct unit test required).
#
# Uses awk-based field-level editing to modify ONLY the target item's lines,
# preserving all other bytes (comments, blank lines, formatting). Never
# re-serialises the file. All values are escaped via _aiw_yaml_escape.
#
# Usage:
#   aiw_resolve --target <path> --item <id> --status <status> \
#     [--resolution <text>] [--resolved-date <YYYY-MM-DD>] \
#     [--resolved-in <sprint-id>] [--related-stories <key,...>]
#
# Exit codes:
#   0 — resolved
#   1 — error (missing arg, item not found, write failure)
aiw_resolve() {
  local target="" item="" _resolve_status="" resolution="" resolved_date=""
  local resolved_in="" related_stories=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --target)           target="$2"; shift 2 ;;
      --item)             item="$2"; shift 2 ;;
      --status)           _resolve_status="$2"; shift 2 ;;
      --resolution)       resolution="$2"; shift 2 ;;
      --resolved-date)    resolved_date="$2"; shift 2 ;;
      --resolved-in)      resolved_in="$2"; shift 2 ;;
      --related-stories)  related_stories="$2"; shift 2 ;;
      *) printf 'status=error\nreason=aiw_resolve: unknown arg: %s\n' "$1"; return 1 ;;
    esac
  done

  # Validate required args.
  if [ -z "$target" ]; then
    printf 'status=error\nreason=aiw_resolve: --target is required\n'; return 1
  fi
  if [ -z "$item" ]; then
    printf 'status=error\nreason=aiw_resolve: --item is required\n'; return 1
  fi
  if [ -z "$_resolve_status" ]; then
    printf 'status=error\nreason=aiw_resolve: --status is required\n'; return 1
  fi

  # Validate status vocabulary.
  case "$_resolve_status" in
    done|invalid|resolved|deferred|in-progress|dismissed) : ;;
    *)
      printf 'status=error\nreason=aiw_resolve: invalid status "%s"; allowed: done, invalid, resolved, deferred, in-progress, dismissed\n' "$_resolve_status"
      return 1 ;;
  esac

  # Validate target file exists and is not a symlink.
  if [ ! -f "$target" ]; then
    printf 'status=error\nreason=aiw_resolve: target file not found: %s\n' "$target"; return 1
  fi
  if [ -L "$target" ]; then
    printf 'status=error\nreason=aiw_resolve: target is a symlink; refusing\n'; return 1
  fi

  # Reject control characters in values.
  local _val
  for _val in "$_resolve_status" "$resolution" "$resolved_date" "$resolved_in" "$related_stories"; do
    if _aiw_has_control_chars "$_val"; then
      printf 'status=error\nreason=aiw_resolve: value contains disallowed control characters\n'; return 1
    fi
  done

  # Escape values for double-quoted YAML scalars.
  local safe_status safe_resolution safe_rd safe_ri
  safe_status="$(_aiw_yaml_escape "$_resolve_status")"
  safe_resolution="$(_aiw_yaml_escape "$resolution")"
  safe_ri="$(_aiw_yaml_escape "$resolved_in")"

  # Resolved date: only for done/invalid/resolved.
  local rd=""
  case "$_resolve_status" in
    done|invalid|resolved) rd="${resolved_date:-$(date -u +%Y-%m-%d)}" ;;
  esac
  safe_rd="$(_aiw_yaml_escape "$rd")"

  # Build related_stories as a YAML inline sequence: ["k1", "k2"].
  local safe_rs=""
  if [ -n "$related_stories" ]; then
    local _rs_build=""
    local OLDIFS="$IFS"; IFS=','
    for _rk in $related_stories; do
      _rk="${_rk# }"; _rk="${_rk% }"
      [ -n "$_rk" ] || continue
      local _erk
      _erk="$(_aiw_yaml_escape "$_rk")"
      if [ -n "$_rs_build" ]; then
        _rs_build="${_rs_build}, \"${_erk}\""
      else
        _rs_build="\"${_erk}\""
      fi
    done
    IFS="$OLDIFS"
    safe_rs="[${_rs_build}]"
  fi

  # Awk-based in-place edit: only the target item's fields are changed.
  # Every other byte in the file is preserved verbatim. Fields that don't
  # exist on the item are appended after the last field in that item block.
  local tmp
  tmp="$(mktemp "${target}.XXXXXX")" || {
    printf 'status=error\nreason=aiw_resolve: mktemp failed\n'; return 1
  }

  # Pass values via ENVIRON to avoid awk -v backslash interpretation.
  local awk_rc=0
  AIW_ITEM="$item" \
  AIW_STATUS="$safe_status" \
  AIW_RESOLUTION="$safe_resolution" \
  AIW_RD="$safe_rd" \
  AIW_RI="$safe_ri" \
  AIW_RS="$safe_rs" \
  awk '
    BEGIN {
      item = ENVIRON["AIW_ITEM"]
      new_status = ENVIRON["AIW_STATUS"]
      new_resolution = ENVIRON["AIW_RESOLUTION"]
      new_rd = ENVIRON["AIW_RD"]
      new_ri = ENVIRON["AIW_RI"]
      new_rs = ENVIRON["AIW_RS"]
      in_target = 0; found = 0; done_editing = 0
      wrote_status = 0; wrote_resolution = 0; wrote_rd = 0
      wrote_ri = 0; wrote_rs = 0
      indent = "  "  # default field indent
    }

    # Detect start of an item block: line starting with "- id:"
    /^[[:space:]]*-[[:space:]]+id:[[:space:]]/ {
      # Flush pending fields from previous target block.
      if (in_target) { _flush_pending(); done_editing = 1 }
      in_target = 0

      # Check if this is our target item (first match only).
      if (!done_editing) {
        line = $0
        sub(/^[[:space:]]*-[[:space:]]+id:[[:space:]]*/, "", line)
        gsub(/^["'"'"']+|["'"'"']+$/, "", line)
        if (line == item) {
          in_target = 1; found = 1
          wrote_status = 0; wrote_resolution = 0; wrote_rd = 0
          wrote_ri = 0; wrote_rs = 0
          # Detect indent from this line.
          match($0, /^[[:space:]]*/)
          indent = substr($0, 1, RLENGTH) "  "
        }
      }
      print; next
    }

    # Inside the target item: replace or note existing fields.
    in_target && /^[[:space:]]+status:[[:space:]]/ {
      printf "%sstatus: \"%s\"\n", indent, new_status
      wrote_status = 1; next
    }
    in_target && /^[[:space:]]+resolution:[[:space:]]/ {
      if (new_resolution != "") {
        printf "%sresolution: \"%s\"\n", indent, new_resolution
        wrote_resolution = 1
      } else { print }
      next
    }
    in_target && /^[[:space:]]+resolved_date:[[:space:]]/ {
      if (new_rd != "") {
        printf "%sresolved_date: \"%s\"\n", indent, new_rd
        wrote_rd = 1
      } else { print }
      next
    }
    in_target && /^[[:space:]]+resolved_in:[[:space:]]/ {
      if (new_ri != "") {
        printf "%sresolved_in: \"%s\"\n", indent, new_ri
        wrote_ri = 1
      } else { print }
      next
    }
    in_target && /^[[:space:]]+related_stories:[[:space:]]/ {
      if (new_rs != "") {
        printf "%srelated_stories: %s\n", indent, new_rs
        wrote_rs = 1
      } else { print }
      next
    }

    # End of target item block: next item or non-indented line.
    in_target && (/^[[:space:]]*-[[:space:]]+id:/ || /^[^[:space:]#]/) {
      _flush_pending()
      in_target = 0
    }

    { print }

    END {
      if (in_target) _flush_pending()
      if (!found) { printf "NOTFOUND\n" > "/dev/stderr"; exit 1 }
    }

    function _flush_pending() {
      if (!wrote_status) printf "%sstatus: \"%s\"\n", indent, new_status
      if (new_resolution != "" && !wrote_resolution) printf "%sresolution: \"%s\"\n", indent, new_resolution
      if (new_rd != "" && !wrote_rd) printf "%sresolved_date: \"%s\"\n", indent, new_rd
      if (new_ri != "" && !wrote_ri) printf "%sresolved_in: \"%s\"\n", indent, new_ri
      if (new_rs != "" && !wrote_rs) printf "%srelated_stories: %s\n", indent, new_rs
    }
  ' "$target" > "$tmp" || awk_rc=$?

  if [ "$awk_rc" -ne 0 ]; then
    rm -f "$tmp"
    printf 'status=error\nreason=aiw_resolve: item %s not found in %s\n' "$item" "$target"
    return 1
  fi

  # Sanity: the output must contain the item id and the new status.
  if ! /usr/bin/grep -q "id:.*${item}" "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    printf 'status=error\nreason=aiw_resolve: sanity check failed — item missing from output\n'
    return 1
  fi

  # Take the action-items lock (same lock as aiw_write uses).
  local lockdir="${target}.lockdir"
  _do_mv() { mv -f "$tmp" "$target"; }

  if command -v flock >/dev/null 2>&1; then
    local lockfile="${target}.lock"
    (
      flock -x 9
      _do_mv
    ) 9>"$lockfile"
    rm -f "$lockfile"
  else
    local tries=0
    while ! mkdir "$lockdir" 2>/dev/null; do
      tries=$((tries + 1))
      [ "$tries" -gt 600 ] && { rmdir "$lockdir" 2>/dev/null || true; break; }
      sleep 0.02
    done
    _do_mv
    rmdir "$lockdir" 2>/dev/null || true
  fi

  printf 'status=ok\nitem=%s\ntarget=%s\n' "$item" "$target"
  return 0
}

# ---------------------------------------------------------------------------
# Sourced-versus-executed dispatch guard
# ---------------------------------------------------------------------------
# When this script is executed directly (not sourced), parse CLI and dispatch.
# Existing aiw_write callers that source this file keep working — they call
# aiw_write / aiw_resolve directly after sourcing.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ] 2>/dev/null; then
  _aiw_subcmd="${1:-}"
  case "$_aiw_subcmd" in
    resolve)
      shift
      aiw_resolve "$@"
      exit $?
      ;;
    write)
      shift
      aiw_write "$@"
      exit $?
      ;;
    *)
      printf 'action-items-write.sh: usage: action-items-write.sh <resolve|write> [args...]\n' >&2
      printf 'action-items-write.sh: when sourced, call aiw_write / aiw_resolve directly.\n' >&2
      exit 1
      ;;
  esac
fi
