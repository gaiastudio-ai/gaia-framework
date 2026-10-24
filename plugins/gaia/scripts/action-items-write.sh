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
    local n
    while IFS= read -r n; do
      if [ "$n" -gt "$max_n" ] 2>/dev/null; then
        max_n="$n"
      fi
    done < <(grep -E '^[[:space:]]*-[[:space:]]+id:[[:space:]]+"?AI-[0-9]+"?[[:space:]]*$' "$target" | grep -oE 'AI-[0-9]+' | grep -oE '[0-9]+')
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
  local found
  found="$(awk -v sid="$sprint_id" -v cls="$classification" -v rk="$ref_key" -v rv="$ref_value" '
    /^[[:space:]]*- id:/ {
      if (in_entry && s_match && c_match && r_match) { matched=1; exit }
      in_entry=1; s_match=0; c_match=0; r_match=0; next
    }
    in_entry && /^[^[:space:]]/ && !/^[[:space:]]*- id:/ {
      if (s_match && c_match && r_match) { matched=1; exit }
      in_entry=0; next
    }
    in_entry {
      # Extract "key: value" from the line, stripping indent, quotes, and CR.
      line = $0; sub(/^[[:space:]]+/, "", line); sub(/\r$/, "", line)
      # Split on first ": " or ":" to get field name and value.
      colon = index(line, ":")
      if (colon > 0) {
        fk = substr(line, 1, colon - 1)
        fv = substr(line, colon + 1)
        sub(/^[[:space:]]*"?/, "", fv); sub(/"?[[:space:]]*$/, "", fv)
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
