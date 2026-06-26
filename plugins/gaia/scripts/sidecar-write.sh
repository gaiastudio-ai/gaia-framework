#!/usr/bin/env bash
# sidecar-write.sh — general-purpose agent sidecar decision-log writer
#
# Appends a timestamped decision entry to an agent's sidecar decision-log
# at .gaia/memory/<agent>-sidecar/decision-log.md, creating the sidecar
# directory and file if absent. Uses atomic tmp+mv writes.
#
# Usage:
#   sidecar-write.sh --agent <agent> --slug <slug> [--decision <text>]
#                    [--root <project-root>]
#
# Arguments:
#   --agent     Agent name (e.g. zara, val, nate). Determines the sidecar
#               subdirectory: .gaia/memory/<agent>-sidecar/
#   --slug      Short identifier for the decision (e.g. threat-model-review).
#   --decision  Decision text to record. If omitted, reads from stdin.
#   --root      Project root. Defaults to CLAUDE_PROJECT_ROOT or PWD.
#
# Exit codes:
#   0 — entry written (or skipped if duplicate slug+decision already present)
#   1 — missing required arguments or IO failure
#
# Output (stdout):
#   status=written   target=<path>
#   status=skipped    reason=duplicate entry
#   status=error      reason=<detail>
#
# Atomic write discipline:
#   Appends are performed via a tmp file + cat-append + mv pattern so a
#   concurrent reader never sees a partial entry. The sidecar directory and
#   decision-log file are created on first use.
#

set -euo pipefail
LC_ALL=C; export LC_ALL

# ---------------------------------------------------------------------------
# usage — print help and exit.
# ---------------------------------------------------------------------------
usage() {
  cat <<'USAGE_EOF'
sidecar-write.sh — general-purpose agent sidecar decision-log writer

Usage:
  sidecar-write.sh --agent <agent> --slug <slug> [--decision <text>]
                   [--root <project-root>]

Arguments:
  --agent     Agent name (e.g. zara, val, nate). Required.
  --slug      Short identifier for the decision. Required.
  --decision  Decision text. If omitted, reads from stdin.
  --root      Project root (default: $CLAUDE_PROJECT_ROOT or $PWD).

Exit codes:
  0 — entry written or duplicate skipped
  1 — missing args or IO failure
USAGE_EOF
}

# ---------------------------------------------------------------------------
# resolve_project_root — determine the project root path.
# ---------------------------------------------------------------------------
resolve_project_root() {
  printf '%s' "${CLAUDE_PROJECT_ROOT:-${GAIA_PROJECT_ROOT:-$(pwd)}}"
}

# ---------------------------------------------------------------------------
# sidecar_write — append a decision entry to the agent's sidecar log.
#
# Arguments: agent slug decision_text root
# ---------------------------------------------------------------------------
sidecar_write() {
  local agent="$1"
  local slug="$2"
  local decision_text="$3"
  local root="$4"

  # Input validation: reject agent/slug containing /, .., newline, or whitespace.
  # Mirrors the path-traversal mitigation in run.sh for --env.
  case "$agent" in
    */*|*..*|*$'\n'*|*' '*|*$'\t'*)
      printf 'status=error\nreason=invalid --agent value (no slashes, dot-dot, or whitespace allowed): %s\n' "$agent" >&2
      return 1 ;;
  esac
  case "$slug" in
    */*|*..*|*$'\n'*|*' '*|*$'\t'*)
      printf 'status=error\nreason=invalid --slug value (no slashes, dot-dot, or whitespace allowed): %s\n' "$slug" >&2
      return 1 ;;
  esac

  local sidecar_dir="${root}/.gaia/memory/${agent}-sidecar"
  local decision_log="${sidecar_dir}/decision-log.md"

  # Prefix check: resolved sidecar_dir must live under ${root}/.gaia/memory/.
  local resolved_root resolved_prefix
  resolved_root="$(cd "$root" 2>/dev/null && pwd -P)"
  resolved_prefix="${resolved_root}/.gaia/memory/"
  # Resolve sidecar_dir (it may not exist yet, so build from resolved root).
  local resolved_sidecar="${resolved_root}/.gaia/memory/${agent}-sidecar"
  case "$resolved_sidecar" in
    "${resolved_prefix}"*)
      : ;; # OK — inside the expected prefix
    *)
      printf 'status=error\nreason=sidecar path escapes .gaia/memory/: %s\n' "$resolved_sidecar" >&2
      return 1 ;;
  esac

  # Create sidecar dir if absent.
  if [ ! -d "$sidecar_dir" ]; then
    mkdir -p "$sidecar_dir"
  fi

  # Seed the decision-log with a header if it does not exist.
  if [ ! -f "$decision_log" ]; then
    cat > "$decision_log" <<'HEADER'
# Decision Log

> Decision log for agent sidecar. Entries appended by sidecar-write.sh.

HEADER
  fi

  # Idempotency check — skip if slug+decision hash already present.
  # Uses a sha256 of slug+decision_text for reliable dedup on long decisions.
  local decision_hash
  decision_hash="$(printf '%s\n%s' "$slug" "$decision_text" | shasum -a 256 | awk '{print $1}')"
  local dedup_marker="<!-- dedup: ${decision_hash} -->"
  if grep -Fq "$dedup_marker" "$decision_log" 2>/dev/null; then
    printf 'status=skipped\nreason=duplicate entry\n'
    return 0
  fi

  # Build the entry.
  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  local entry
  entry="$(cat <<ENTRY_EOF

${dedup_marker}
### ${timestamp} — ${slug}

- agent: ${agent}
- slug: ${slug}
- recorded_at: ${timestamp}

${decision_text}

ENTRY_EOF
)"

  # Atomic append: write to tmp, then cat-append to the log.
  local tmpfile
  tmpfile="$(mktemp "${decision_log}.tmp.XXXXXX")"
  if ! cat "$decision_log" > "$tmpfile" 2>/dev/null; then
    printf 'status=error\nreason=failed to create temp file: %s\n' "$tmpfile" >&2
    rm -f "$tmpfile"
    return 1
  fi

  printf '%s\n' "$entry" >> "$tmpfile"

  if ! mv -f "$tmpfile" "$decision_log" 2>/dev/null; then
    printf 'status=error\nreason=atomic mv failed: %s -> %s\n' "$tmpfile" "$decision_log" >&2
    rm -f "$tmpfile"
    return 1
  fi

  printf 'status=written\ntarget=%s\n' "$decision_log"
  return 0
}

# ---------------------------------------------------------------------------
# CLI entry point — runs only when executed directly, not sourced.
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ] 2>/dev/null; then

  AGENT=""
  SLUG=""
  DECISION=""
  ROOT=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --agent)    AGENT="${2:-}"; shift 2 ;;
      --slug)     SLUG="${2:-}"; shift 2 ;;
      --decision) DECISION="${2:-}"; shift 2 ;;
      --root)     ROOT="${2:-}"; shift 2 ;;
      --help|-h)  usage; exit 0 ;;
      *)
        printf 'status=error\nreason=unknown argument: %s\n' "$1" >&2
        exit 1
        ;;
    esac
  done

  if [ -z "$AGENT" ]; then
    printf 'status=error\nreason=--agent is required\n' >&2
    exit 1
  fi
  if [ -z "$SLUG" ]; then
    printf 'status=error\nreason=--slug is required\n' >&2
    exit 1
  fi

  # Read decision from stdin if not provided via --decision.
  if [ -z "$DECISION" ]; then
    DECISION="$(cat)"
  fi

  if [ -z "$ROOT" ]; then
    ROOT="$(resolve_project_root)"
  fi

  sidecar_write "$AGENT" "$SLUG" "$DECISION" "$ROOT"
  exit $?

fi
