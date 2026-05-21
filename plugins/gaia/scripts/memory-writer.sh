#!/usr/bin/env bash
# memory-writer.sh — GAIA foundation script (E28-S146)
#
# Writes an agent's sidecar memory: appends decision-log entries and
# overwrites (or creates) named sections of ground-truth. This is the
# write-side counterpart to memory-loader.sh (E28-S13); together they
# close the two-path hybrid memory model (ADR-046).
#
# Refs: FR-331, NFR-048, ADR-042, ADR-046, ADR-048, ADR-014
# Brief: P21-S1 (docs/creative-artifacts/gaia-native-conversion-feature-brief-2026-04-14.md)
#
# Invocation contract:
#
#   memory-writer.sh --agent <id> --type <decision|ground-truth>
#                    --content <text> --source <workflow_name>
#                    [--section <heading>] [--lock-timeout <seconds>] [--help]
#
# --section is MANDATORY when --type=ground-truth.
#
# Exit codes (sysexits.h conventions):
#   0   success
#   64  usage / parameter error (EX_USAGE)
#   74  write failure — disk full, read-only FS, permission denied (EX_IOERR)
#   75  lock held — timeout waiting for advisory lock (EX_TEMPFAIL)
#
# Concurrency: writes are serialized via POSIX advisory lock (flock when
# available) or a mkdir-based lock-file fallback. Both paths honour
# --lock-timeout (default 10s).
#
# Atomic write: content is written to a temp file inside the sidecar
# directory and moved over the target inside the held lock, so a reader
# using memory-loader.sh never observes a partially-written file.

set -euo pipefail
LC_ALL=C
export LC_ALL

readonly EX_OK=0
readonly EX_USAGE=64
readonly EX_IOERR=74
readonly EX_TEMPFAIL=75
readonly DEFAULT_LOCK_TIMEOUT=10

# E64-S5 — script-level EXIT/INT/TERM trap for atomic-write tmp cleanup.
# Every tempfile-creating call site appends the resulting path to
# _GAIA_TMP_PATHS and captures its index. After a successful rename or rm
# the slot is cleared so cleanup is idempotent. Covers SIGINT, SIGTERM, OOM,
# and signal-during-awk paths the inline rm paths miss. bash 3.2 compatible.
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

# AF-2026-05-21-7: canonical .gaia/memory default, legacy _memory fallback
# only on positive pre-ADR-111 evidence (legacy dir exists AND canonical doesn't).
if [ -z "${MEMORY_PATH:-}" ]; then
  if [ -d "_memory" ] && [ ! -d ".gaia/memory" ]; then
    MEMORY_PATH="_memory"
  else
    MEMORY_PATH=".gaia/memory"
  fi
fi
CONFIG="${MEMORY_PATH}/config.yaml"

# ---------- Startup orphan-tmp sweep (E64-S6) ----------
#
# Garbage-collect *.tmp.?????? files older than 60 minutes under
# ${MEMORY_PATH}. Catches orphans left by kill -9 / OOM / power loss
# (which bypass E64-S5's EXIT/INT/TERM trap). Bounded to the documented
# allowlist (memory tree). Never /tmp, never $HOME, never ${PROJECT_PATH}
# root. Set GAIA_SKIP_ORPHAN_SWEEP=1 to disable. Errors swallowed;
# zero stdout (silent GC).
if [ "${GAIA_SKIP_ORPHAN_SWEEP:-0}" != "1" ]; then
  find "${MEMORY_PATH}" \
    -maxdepth 2 -name '*.tmp.??????' -mmin +60 -delete 2>/dev/null || true
fi

die() {
  local code="$1"; shift
  printf 'error: %s\n' "$*" >&2
  exit "$code"
}

usage() {
  cat <<'EOF'
Usage: memory-writer.sh --agent <id> --type <decision|ground-truth>
                        --content <text> --source <workflow_name>
                        [--section <heading>] [--lock-timeout <seconds>] [--help]

Required flags:
  --agent <id>          Agent id (e.g. sm, architect, val)
  --type <kind>         decision | ground-truth
  --content <text>      Body text to write (verbatim; may contain newlines)
  --source <workflow>   Originating workflow name (e.g. dev-story)

Conditional flags:
  --section <heading>   Markdown heading of the ground-truth section to
                        overwrite. REQUIRED when --type=ground-truth.

Optional flags:
  --lock-timeout <s>    Seconds to wait for the advisory lock (default 10).
  --help                Print this help and exit 0.

Behavior:
  decision     → appends a timestamped entry to
                 ${MEMORY_PATH}/<sidecar>/decision-log.md
  ground-truth → overwrites (or creates) the named section of
                 ${MEMORY_PATH}/<sidecar>/ground-truth.md with a
                 _last_updated_ marker; other sections are preserved
                 byte-for-byte.

Exit codes:
  0   success
  64  usage / parameter error
  74  write failure (disk full, read-only, permission denied)
  75  lock held — timeout waiting for advisory lock

Refs: FR-331, NFR-048, ADR-042, ADR-046 (brief P21-S1)
EOF
}

# --- Argument parsing -------------------------------------------------------
agent=""
wtype=""
content=""
source_workflow=""
section=""
lock_timeout="$DEFAULT_LOCK_TIMEOUT"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit "$EX_OK"
      ;;
    --agent)
      [[ $# -ge 2 ]] || die "$EX_USAGE" "--agent requires a value"
      agent="$2"; shift 2 ;;
    --agent=*) agent="${1#*=}"; shift ;;
    --type)
      [[ $# -ge 2 ]] || die "$EX_USAGE" "--type requires a value"
      wtype="$2"; shift 2 ;;
    --type=*) wtype="${1#*=}"; shift ;;
    --content)
      [[ $# -ge 2 ]] || die "$EX_USAGE" "--content requires a value"
      content="$2"; shift 2 ;;
    --content=*) content="${1#*=}"; shift ;;
    --source)
      [[ $# -ge 2 ]] || die "$EX_USAGE" "--source requires a value"
      source_workflow="$2"; shift 2 ;;
    --source=*) source_workflow="${1#*=}"; shift ;;
    --section)
      [[ $# -ge 2 ]] || die "$EX_USAGE" "--section requires a value"
      section="$2"; shift 2 ;;
    --section=*) section="${1#*=}"; shift ;;
    --lock-timeout)
      [[ $# -ge 2 ]] || die "$EX_USAGE" "--lock-timeout requires a value"
      lock_timeout="$2"; shift 2 ;;
    --lock-timeout=*) lock_timeout="${1#*=}"; shift ;;
    --)
      shift
      break
      ;;
    -*)
      usage >&2
      die "$EX_USAGE" "unknown flag: $1"
      ;;
    *)
      usage >&2
      die "$EX_USAGE" "unexpected positional argument: $1"
      ;;
  esac
done

# --- Validation -------------------------------------------------------------
[[ -n "$agent" ]]           || { usage >&2; die "$EX_USAGE" "missing required flag: --agent"; }
[[ -n "$wtype" ]]           || { usage >&2; die "$EX_USAGE" "missing required flag: --type"; }
[[ -n "$content" ]]         || { usage >&2; die "$EX_USAGE" "missing required flag: --content"; }
[[ -n "$source_workflow" ]] || { usage >&2; die "$EX_USAGE" "missing required flag: --source"; }

case "$wtype" in
  decision|ground-truth) ;;
  *) die "$EX_USAGE" "invalid --type: $wtype (expected decision | ground-truth)" ;;
esac

if [[ "$wtype" == "ground-truth" && -z "$section" ]]; then
  die "$EX_USAGE" "--section is required when --type=ground-truth"
fi

if ! [[ "$lock_timeout" =~ ^[0-9]+$ ]] || [[ "$lock_timeout" -le 0 ]]; then
  die "$EX_USAGE" "--lock-timeout must be a positive integer (got '$lock_timeout')"
fi

# --- Sidecar resolution -----------------------------------------------------
resolve_sidecar_rel() {
  local agent_name="$1"
  local sidecar_rel=""
  [[ -f "$CONFIG" ]] || { printf ''; return 0; }
  if command -v yq >/dev/null 2>&1; then
    sidecar_rel="$(yq -r ".agents.\"${agent_name}\".sidecar // \"\"" "$CONFIG" 2>/dev/null || true)"
    [[ "$sidecar_rel" == "null" ]] && sidecar_rel=""
  else
    sidecar_rel="$(awk -v agent="$agent_name" '
      BEGIN { in_agents = 0; in_agent = 0; agent_indent = -1 }
      /^[[:space:]]*#/ { next }
      {
        if ($0 ~ /^agents:[[:space:]]*$/) { in_agents = 1; next }
        if (!in_agents) { next }
        if ($0 ~ /^[^[:space:]#]/) { in_agents = 0; in_agent = 0; next }
        if ($0 ~ /^[[:space:]]+[^[:space:]:#]+:[[:space:]]*$/) {
          line = $0
          indent_str = line
          sub(/[^[:space:]].*$/, "", indent_str)
          indent = length(indent_str)
          name = line
          sub(/^[[:space:]]+/, "", name)
          sub(/:.*$/, "", name)
          if (agent_indent < 0) agent_indent = indent
          if (indent == agent_indent) {
            in_agent = (name == agent) ? 1 : 0
          }
          next
        }
        if (in_agent && $0 ~ /^[[:space:]]+sidecar:[[:space:]]*/) {
          val = $0
          sub(/^[[:space:]]+sidecar:[[:space:]]*/, "", val)
          sub(/[[:space:]]*(#.*)?$/, "", val)
          sub(/^"/, "", val); sub(/"$/, "", val)
          sub(/^'"'"'/, "", val); sub(/'"'"'$/, "", val)
          print val
          exit
        }
      }
    ' "$CONFIG" 2>/dev/null || true)"
  fi
  printf '%s' "$sidecar_rel"
}

sidecar_rel="$(resolve_sidecar_rel "$agent")"
if [[ -z "$sidecar_rel" ]]; then
  sidecar_dir="${MEMORY_PATH}/${agent}-sidecar"
else
  sidecar_dir="${MEMORY_PATH}/${sidecar_rel}"
fi

mkdir -p "$sidecar_dir" || die "$EX_IOERR" "failed to create sidecar directory: $sidecar_dir"

# --- Target file and lock path ---------------------------------------------
case "$wtype" in
  decision)     target_file="${sidecar_dir}/decision-log.md" ;;
  ground-truth) target_file="${sidecar_dir}/ground-truth.md" ;;
esac

lock_path="${sidecar_dir}/.$(basename "$target_file").lock"

# --- Locking ----------------------------------------------------------------
# Acquire advisory lock. Use flock when available; otherwise fall back to
# mkdir-based spin. Both paths respect --lock-timeout (integer seconds).
acquire_lock_flock() {
  exec 9>"$lock_path" 2>/dev/null || return 1
  # shellcheck disable=SC2086
  if flock -w "$lock_timeout" 9 2>/dev/null; then
    return 0
  fi
  return 1
}

acquire_lock_mkdir() {
  local deadline=$(( $(date +%s) + lock_timeout ))
  while :; do
    if mkdir "$lock_path" 2>/dev/null; then
      # Record holder pid for debugging / stale detection.
      printf '%d\n' "$$" > "$lock_path/pid" 2>/dev/null || true
      return 0
    fi
    # Stale-lock detection: if the holder pid no longer exists, reclaim.
    if [[ -f "$lock_path/pid" ]]; then
      local holder
      holder="$(cat "$lock_path/pid" 2>/dev/null || echo '')"
      if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null; then
        rm -rf "$lock_path" 2>/dev/null || true
        continue
      fi
    fi
    [[ $(date +%s) -ge $deadline ]] && return 1
    sleep 0.2
  done
}

# shellcheck disable=SC2329  # invoked indirectly via `trap ... EXIT`
release_lock() {
  if [[ "${lock_mode:-}" == "flock" ]]; then
    exec 9>&- 2>/dev/null || true
    rm -f "$lock_path" 2>/dev/null || true
  elif [[ "${lock_mode:-}" == "mkdir" ]]; then
    rm -rf "$lock_path" 2>/dev/null || true
  fi
}
trap 'release_lock; _cleanup_tmps' EXIT

lock_mode=""
if command -v flock >/dev/null 2>&1; then
  if acquire_lock_flock; then
    lock_mode="flock"
  else
    die "$EX_TEMPFAIL" "lock held on $target_file, timeout after ${lock_timeout}s"
  fi
else
  if acquire_lock_mkdir; then
    lock_mode="mkdir"
  else
    die "$EX_TEMPFAIL" "lock held on $target_file, timeout after ${lock_timeout}s"
  fi
fi

# --- Timestamp helper -------------------------------------------------------
now_iso8601() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# --- Write helpers ----------------------------------------------------------
atomic_replace() {
  local dest="$1" payload="$2"
  local tmp
  tmp="$(mktemp "${dest}.tmp.XXXXXX")" || die "$EX_IOERR" "failed to create temp file near $dest"
  # E64-S5: register tmp for script-level EXIT/INT/TERM cleanup.
  local _tmp_idx
  _GAIA_TMP_PATHS+=("$tmp")
  _tmp_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))
  printf '%s' "$payload" > "$tmp" || { rm -f "$tmp"; die "$EX_IOERR" "failed to write temp file $tmp"; }
  mv "$tmp" "$dest" || { rm -f "$tmp"; die "$EX_IOERR" "failed to move temp file into place: $dest"; }
  # E64-S5: mv succeeded — clear the slot.
  _GAIA_TMP_PATHS[$_tmp_idx]=""
}

write_decision() {
  local ts entry existing combined
  ts="$(now_iso8601)"
  entry="### [${ts}] ${source_workflow} — ${agent}"$'\n\n'"- **Agent:** ${agent}"$'\n'"- **Workflow:** ${source_workflow}"$'\n'"- **Status:** recorded"$'\n\n'"${content}"$'\n'
  if [[ -f "$target_file" ]]; then
    existing="$(cat "$target_file")"
    # Preserve a trailing newline between existing content and the new entry.
    combined="${existing}"$'\n\n'"${entry}"
  else
    # Seed the file with a standard header mirroring memory-loader.sh's fallback.
    combined="# Decision Log — ${agent}"$'\n\n'"${entry}"
  fi
  atomic_replace "$target_file" "$combined"
}

write_ground_truth() {
  local ts marker new_section existing
  ts="$(now_iso8601)"
  marker="_last_updated: ${ts}_"
  # The new section body: heading, blank line, marker, blank line, content, trailing newline.
  new_section="${section}"$'\n\n'"${marker}"$'\n\n'"${content}"$'\n'

  if [[ ! -f "$target_file" ]]; then
    # File does not exist — create it with just this section.
    atomic_replace "$target_file" "${new_section}"
    return 0
  fi

  existing="$(cat "$target_file")"

  # Does the section header already exist?
  # Match lines equal to the section heading exactly.
  if printf '%s\n' "$existing" | awk -v hdr="$section" 'BEGIN{found=0} $0==hdr{found=1} END{exit !found}'; then
    # Section exists — replace it in place, preserving other sections byte-for-byte.
    # awk -v cannot carry embedded newlines (BSD awk rejects them), so the
    # replacement body is written to a temp file and injected via `getline`.
    local new_section_file rewritten
    new_section_file="$(mktemp "${target_file}.newsec.XXXXXX")" \
      || die "$EX_IOERR" "failed to create temp file near $target_file"
    # E64-S5: register newsec tmp for script-level EXIT/INT/TERM cleanup.
    local _newsec_idx
    _GAIA_TMP_PATHS+=("$new_section_file")
    _newsec_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))
    printf '%s' "$new_section" > "$new_section_file" \
      || { rm -f "$new_section_file"; die "$EX_IOERR" "failed to stage new section body"; }
    rewritten="$(printf '%s\n' "$existing" | awk -v hdr="$section" -v new_body_file="$new_section_file" '
      BEGIN {
        in_section = 0
        # Compute heading level of the target section by counting leading # characters.
        level = 0
        h = hdr
        while (substr(h, 1, 1) == "#") { level++; h = substr(h, 2) }
        # Slurp replacement body from the sidecar temp file.
        new_body = ""
        while ((getline line_b < new_body_file) > 0) {
          new_body = new_body line_b "\n"
        }
        close(new_body_file)
      }
      {
        line = $0
        # Determine if this line is a markdown heading at level <= target level.
        is_same_or_higher_heading = 0
        cur_level = 0
        s = line
        while (substr(s, 1, 1) == "#") { cur_level++; s = substr(s, 2) }
        if (cur_level > 0 && cur_level <= level && substr(s, 1, 1) == " ") {
          is_same_or_higher_heading = 1
        }

        if (!in_section) {
          if (line == hdr) {
            # Replace this section with new_body (which already ends in \n).
            printf "%s", new_body
            in_section = 1
            next
          }
          print line
        } else {
          # Skip until we hit another heading of same-or-higher level.
          if (is_same_or_higher_heading) {
            in_section = 0
            print line
          }
          # Otherwise: skip (swallow the old section body).
        }
      }
    ')"
    rm -f "$new_section_file"
    # E64-S5: rm succeeded — clear the slot.
    _GAIA_TMP_PATHS[$_newsec_idx]=""
    # Ensure trailing newline for consistency.
    case "$rewritten" in
      *$'\n') : ;;
      *) rewritten="${rewritten}"$'\n' ;;
    esac
    atomic_replace "$target_file" "$rewritten"
  else
    # Section absent — append at end, ensuring a blank line separator.
    local sep=""
    case "$existing" in
      "") : ;;
      *$'\n') sep=$'\n' ;;
      *)      sep=$'\n\n' ;;
    esac
    atomic_replace "$target_file" "${existing}${sep}${new_section}"
  fi
}

# --- Dispatch ---------------------------------------------------------------
case "$wtype" in
  decision)     write_decision ;;
  ground-truth) write_ground_truth ;;
esac

exit "$EX_OK"
