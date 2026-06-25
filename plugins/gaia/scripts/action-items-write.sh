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
#   - aiw_validate_classification — enforce explicit classification enum
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
# aiw_bootstrap_file — create action-items.yaml with §10.28.6 schema header
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
    done < <(grep -oE 'id: "AI-([0-9]+)"' "$target" | grep -oE '[0-9]+')
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
    /^  - id:/ {
      # Flush previous entry if all three fields matched.
      if (in_entry && s_match && c_match && r_match) { print "MATCH"; exit }
      in_entry=1; s_match=0; c_match=0; r_match=0; next
    }
    in_entry && /^[^ ]/ {
      if (s_match && c_match && r_match) { print "MATCH"; exit }
      in_entry=0; next
    }
    in_entry && /sprint_id:/ {
      gsub(/.*sprint_id:[[:space:]]*"?/, ""); gsub(/".*/, "");
      if ($0 == sid) s_match=1
    }
    in_entry && /classification:/ {
      gsub(/.*classification:[[:space:]]*"?/, ""); gsub(/".*/, "");
      if ($0 == cls) c_match=1
    }
    in_entry {
      pat = rk ":[[:space:]]*\"?" rv "\"?"
      if ($0 ~ pat) r_match=1
    }
    END { if (in_entry && s_match && c_match && r_match) print "MATCH" }
  ' "$target")"
  if [ "$found" = "MATCH" ]; then
    return 0
  fi
  return 1
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
# aiw_build_entry — build a YAML entry string
# Args: id sprint_id classification text ref_key ref_value
# ---------------------------------------------------------------------------
aiw_build_entry() {
  local id="$1" sprint_id="$2" classification="$3" text="$4" ref_key="$5" ref_value="$6"
  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  local theme_hash
  theme_hash="$(printf '%s' "$text" | shasum -a 256 | awk '{print $1}')"

  printf '  - id: "%s"\n' "$id"
  printf '    sprint_id: "%s"\n' "$sprint_id"
  printf '    text: "%s"\n' "$text"
  printf '    classification: "%s"\n' "$classification"
  printf '    status: "open"\n'
  printf '    escalation_count: 0\n'
  printf '    created_at: "%s"\n' "$timestamp"
  printf '    theme_hash: "sha256:%s"\n' "$theme_hash"
  printf '    %s: "%s"\n' "$ref_key" "$ref_value"
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

  # Validate classification BEFORE any file writes (scenario 7)
  if ! aiw_validate_classification "$classification"; then
    return 1
  fi

  # Bootstrap file if missing (AC3)
  aiw_bootstrap_file "$target"

  # Idempotency check (scenarios 5, 6)
  if aiw_check_dedup "$target" "$sprint_id" "$classification" "$ref_key" "$ref_value"; then
    printf 'status=skipped_idempotent\nreason=entry with matching composite key already exists\n'
    return 0
  fi

  # Compute next id
  local next_id
  next_id="$(aiw_next_id "$target")"

  # Build entry
  local entry
  entry="$(aiw_build_entry "$next_id" "$sprint_id" "$classification" "$text" "$ref_key" "$ref_value")"

  # Atomic append
  aiw_append_entry "$target" "$entry"

  printf 'status=ok\nid=%s\ntarget=%s\n' "$next_id" "$target"
  return 0
}
