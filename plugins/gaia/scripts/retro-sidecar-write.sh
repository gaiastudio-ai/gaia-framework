#!/usr/bin/env bash
# retro-sidecar-write.sh — shared retro writer helper (ADR-052, architecture §10.28.2)
#
# Five-phase pipeline:
#   1. ALLOWLIST check (NFR-RIM-2) — realpath-resolved prefix/glob match against
#      the retro allowlist.
#   2. IDEMPOTENCY check (NFR-RIM-3) — composite dedup_key =
#      sha256("{sprint_id}\n{normalize(payload)}"), scan target for an existing
#      marker; skip on hit.
#   3. BACKUP — cp target target.bak; create parent dir and seed canonical
#      header if target missing.
#   4. ATOMIC APPEND — ADR-016-formatted entry with a dedup_key comment marker.
#   5. VERIFY — re-read last entry; on mismatch restore from .bak; on success
#      rm .bak so no orphan backups are left on disk.
#
# Concurrency: flock on the target file serializes writers (AC-EC1, AC-EC9).
# Oversized payloads (>100KB) are wrapped in <details> with a warning (AC-EC11).
# BOM / line-ending / trailing-ws normalized before hashing (AC-EC12).
#
# Usage:
#   retro-sidecar-write.sh --root <project-root> --sprint-id <id> \
#                          --target <absolute-path> --payload <string>
#
# Exit codes:
#   0 — entry written (or skipped_idempotent, or skipped per delegated no-op)
#   1 — error (unauthorized, missing_sprint_id, invalid args, IO failure)
#
# Output (stdout):
#   status=<ok|skipped_idempotent|unauthorized|missing_sprint_id|io_error>
#   reason=<human-readable detail>   (on non-ok exits)
#
# Refs: ADR-016 (memory sidecar format), ADR-052 (this helper), NFR-RIM-2/RIM-3.

set -uo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# E36-S5: helper functions are defined unconditionally so the shared writer
# can be sourced as a library by delegation wrappers (e.g.,
# action-items-increment.sh). The CLI body below only runs when this script
# is executed directly (BASH_SOURCE[0] == $0), preserving back-compat for
# the standalone invocation path used by /gaia-retro Steps 5, 5c, 5d, 7.

# resolve_real — resolve a path to its canonical absolute form without
# requiring the target to exist. Uses Python-style realpath semantics that
# resolve symlinks in intermediate components, mirroring `readlink -f`.
resolve_real() {
  # Resolve a path to its canonical absolute form using the deepest existing
  # ancestor directory. This handles the case where the target and several
  # intermediate components do not yet exist but the root does — common on
  # macOS where /tmp is itself a symlink to /private/tmp and fixtures create
  # non-existent subtrees under a realpath'd root.
  local p="$1"
  python3 - "$p" <<'PY'
import os, sys
p = sys.argv[1]
# Make absolute first so os.path.split works predictably.
if not os.path.isabs(p):
    p = os.path.abspath(p)
if os.path.lexists(p):
    print(os.path.realpath(p))
    sys.exit(0)
# Walk up until we find an existing ancestor.
parts = []
cur = p
while cur and cur != os.path.dirname(cur):
    if os.path.lexists(cur):
        break
    parts.append(os.path.basename(cur))
    cur = os.path.dirname(cur)
# cur is now the deepest existing ancestor (or '/').
real_ancestor = os.path.realpath(cur) if cur else '/'
# Re-attach the non-existent tail in original order.
tail = os.path.join(*reversed(parts)) if parts else ''
print(os.path.join(real_ancestor, tail) if tail else real_ancestor)
PY
}

# allowlist_match — return 0 if the resolved real path matches one of the
# NFR-RIM-2 allowlist patterns under $ROOT. Symlinks have already been
# resolved by the caller.
allowlist_match() {
  local real_root="$1" real_target="$2"
  case "$real_target" in
    "$real_root"/_memory/*-sidecar/*.md)                 return 0 ;;
    "$real_root"/.gaia/memory/*-sidecar/*.md)            return 0 ;;
    "$real_root"/docs/implementation-artifacts/retrospective-*.md) return 0 ;;
    "$real_root"/.gaia/artifacts/implementation-artifacts/retrospective-*.md) return 0 ;;
    "$real_root"/docs/planning-artifacts/action-items.yaml)        return 0 ;;
    "$real_root"/.gaia/state/action-items.yaml)                    return 0 ;;
    "$real_root"/custom/skills/*.md)                     return 0 ;;
    "$real_root"/custom/skills/*.customize.yaml)         return 0 ;;
    "$real_root"/.gaia/custom/skills/*.md)               return 0 ;;
    "$real_root"/.gaia/custom/skills/*.customize.yaml)   return 0 ;;
    "$real_root"/.customize.yaml)                        return 0 ;;
    *) return 1 ;;
  esac
}

# normalize_payload — strip BOM, trim trailing whitespace, normalize CRLF→LF.
# Writes normalized bytes to stdout.
normalize_payload() {
  # Strip UTF-8 BOM (0xEF 0xBB 0xBF) if present at start.
  local s="$1"
  s="${s#$'\xEF\xBB\xBF'}"
  # Normalize CRLF to LF.
  s="${s//$'\r\n'/$'\n'}"
  # Strip trailing whitespace per line.
  printf '%s' "$s" | awk '{ sub(/[[:space:]]+$/, ""); print }'
}

# sha256 — compute hex digest of stdin.
sha256() { shasum -a 256 | awk '{print $1}'; }

# canonical_header — emit the canonical header for a missing target file,
# chosen by target kind.
canonical_header() {
  local t="$1"
  case "$t" in
    */decision-log.md)
      cat <<'EOF'
# Decision Log

> ADR-016 decision log. Entries appended by /gaia-retro (ADR-052 shared writer)
> and other GAIA workflows. Each entry is tagged with the sprint ID and the
> dedup_key used to detect idempotent re-writes (NFR-RIM-3).

EOF
      ;;
    */conversation-context.md)
      cat <<'EOF'
# Conversation Context

> Rolling session context. Appended by /gaia-retro and peer Phase 4 commands.

EOF
      ;;
    */velocity-data.md)
      cat <<'EOF'
# SM Velocity Data

> Sprint-over-sprint velocity. One row per sprint (idempotency key: sprint_id).
> Appended unconditionally by /gaia-retro Step 5d (FR-RIM-4, architecture §10.28.5).

EOF
      ;;
    */action-items.yaml)
      cat <<'EOF'
# Action Items — architecture §10.28.6 schema
# Written by /gaia-retro (ADR-052 shared writer). Each entry:
#   id: AI-{n}            # auto-incremented
#   sprint_id: "..."
#   text: "..."
#   classification: clarification|implementation|process|automation
#   status: open|in-progress|resolved
#   escalation_count: 0    # bumped by cross-retro detection (FR-RIM-1)
#   created_at: "<ISO 8601>"
#   theme_hash: "sha256:<hex>"
items:
EOF
      ;;
    */retrospective-*.md)
      # The prose retro artifact is seeded lightly; /gaia-retro Step 6 owns
      # the full body.
      cat <<'EOF'
# Retrospective

EOF
      ;;
    */custom/skills/*.customize.yaml)
      cat <<'EOF'
# .customize.yaml — agent overrides registered by retro proposal pipeline (ADR-053).
# Location: custom/skills/ (ADR-020 §lines 1720-1722).
EOF
      ;;
    */.customize.yaml)
      cat <<'EOF'
# .customize.yaml — agent overrides registered by retro proposal pipeline (ADR-053).
EOF
      ;;
    *)
      cat <<'EOF'
# GAIA Retro Append Target

EOF
      ;;
  esac
}

# ---------------------------------------------------------------------------
# CLI body — runs only when this script is executed directly, not sourced.
# Delegation wrappers (E36-S5) `source` this file to reuse helpers above.
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
ROOT=""
SPRINT_ID=""
TARGET=""
PAYLOAD=""

while [ $# -gt 0 ]; do
  case "$1" in
    --root)      ROOT="$2"; shift 2 ;;
    --sprint-id) SPRINT_ID="$2"; shift 2 ;;
    --target)    TARGET="$2"; shift 2 ;;
    --payload)   PAYLOAD="$2"; shift 2 ;;
    --help|-h)
      sed -n '1,40p' "$0"
      exit 0
      ;;
    *) printf 'status=io_error\nreason=unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Required-arg validation
# ---------------------------------------------------------------------------
if [ -z "$ROOT" ]; then
  ROOT="${CLAUDE_PROJECT_ROOT:-$(pwd)}"
fi
if [ -z "$SPRINT_ID" ]; then
  printf 'status=missing_sprint_id\nreason=--sprint-id is required\n'
  exit 1
fi
if [ -z "$TARGET" ]; then
  printf 'status=io_error\nreason=--target is required\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. ALLOWLIST CHECK (NFR-RIM-2)
# ---------------------------------------------------------------------------
REAL_ROOT="$(resolve_real "$ROOT")"
if [ -z "$REAL_ROOT" ]; then REAL_ROOT="$ROOT"; fi

# Resolve target via its parent so missing files still map to real paths; if
# the target is a symlink we want its final destination.
if [ -L "$TARGET" ]; then
  REAL_TARGET="$(resolve_real "$TARGET")"
elif [ -e "$TARGET" ]; then
  REAL_TARGET="$(resolve_real "$TARGET")"
else
  REAL_TARGET="$(resolve_real "$TARGET")"
fi
if [ -z "$REAL_TARGET" ]; then REAL_TARGET="$TARGET"; fi

if ! allowlist_match "$REAL_ROOT" "$REAL_TARGET"; then
  printf 'status=unauthorized\nreason=path outside allowlist: %s\n' "$REAL_TARGET"
  exit 1
fi

# ---------------------------------------------------------------------------
# Prepare the real target directory; seed header if absent.
# ---------------------------------------------------------------------------
REAL_DIR="$(dirname "$REAL_TARGET")"
mkdir -p "$REAL_DIR"

# If we are writing conversation-context.md for the first time, seed it;
# that file is not always written by the retro pipeline but may be created
# here on first use.
if [ ! -e "$REAL_TARGET" ]; then
  canonical_header "$REAL_TARGET" > "$REAL_TARGET"
fi

# For validator-sidecar bootstrapping (AC-EC10): if we are writing to
# validator-sidecar/decision-log.md, also seed conversation-context.md so
# downstream workflows find both.
case "$REAL_TARGET" in
  */validator-sidecar/decision-log.md)
    peer="${REAL_DIR}/conversation-context.md"
    [ -e "$peer" ] || canonical_header "$peer" > "$peer"
    ;;
esac

# ---------------------------------------------------------------------------
# 2. IDEMPOTENCY CHECK (NFR-RIM-3)
# ---------------------------------------------------------------------------
NORM_PAYLOAD="$(normalize_payload "$PAYLOAD")"
DEDUP_KEY="$(printf '%s\n%s' "$SPRINT_ID" "$NORM_PAYLOAD" | sha256)"

# Normalize existing file bytes before scanning so a BOM prefix (AC-EC12) or
# a CRLF/trailing-ws drift does not defeat the scan.
NORM_EXISTING="$(normalize_payload "$(cat "$REAL_TARGET" 2>/dev/null || true)")"

# Velocity schema special case: idempotency key is sprint_id alone
# (one velocity row per sprint — architecture §10.28.5).
case "$REAL_TARGET" in
  */velocity-data.md)
    if printf '%s' "$NORM_EXISTING" | grep -qE "^### Sprint ${SPRINT_ID}( |$)"; then
      printf 'status=skipped_idempotent\nreason=velocity row already present for %s\n' "$SPRINT_ID"
      exit 0
    fi
    ;;
  *)
    if printf '%s' "$NORM_EXISTING" | grep -Fq "dedup_key: ${DEDUP_KEY}"; then
      printf 'status=skipped_idempotent\nreason=entry with dedup_key already present\n'
      exit 0
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# 3. BACKUP
# ---------------------------------------------------------------------------
BACKUP="${REAL_TARGET}.bak"
cp -p "$REAL_TARGET" "$BACKUP"

# ---------------------------------------------------------------------------
# Oversized payload handling (AC-EC11)
# ---------------------------------------------------------------------------
PAYLOAD_BYTES=${#NORM_PAYLOAD}
OVERSIZED=0
if [ "$PAYLOAD_BYTES" -gt 100000 ]; then
  OVERSIZED=1
  printf 'WARN: payload %d bytes > 100KB — truncating preview and wrapping full body in <details>\n' "$PAYLOAD_BYTES" >&2
fi

# ---------------------------------------------------------------------------
# 4. ATOMIC APPEND (ADR-016 format with dedup marker)
# ---------------------------------------------------------------------------
LOCKFILE="${REAL_TARGET}.lock"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Obtain exclusive flock on the target; portable flock is installed on macOS
# via coreutils but we fall back to a best-effort mkdir lock if not.
_append() {
  case "$REAL_TARGET" in
    */velocity-data.md)
      {
        printf '\n### Sprint %s — %s\n\n' "$SPRINT_ID" "$TIMESTAMP"
        printf '%s\n' "$NORM_PAYLOAD"
        printf '\n<!-- dedup_key: %s -->\n' "$DEDUP_KEY"
      } >> "$REAL_TARGET"
      ;;
    */action-items.yaml)
      # AF-2026-05-24-14 / Test02 F-26: substitute `AI-{auto}` placeholders
      # with the next sequential `AI-{n}` value. Previously the writer
      # treated the payload as opaque and wrote `AI-{auto}` literally,
      # leaving callers with duplicate-placeholder IDs that broke
      # downstream consumers (escalation-halt.sh, /gaia-action-items
      # reader). The substitution scans the existing file for the highest
      # numeric AI-N and assigns the next integer to each occurrence in
      # the payload, in order.
      local _highest _next _resolved_payload
      _highest=0
      if [ -s "$REAL_TARGET" ]; then
        _highest="$(grep -oE 'AI-[0-9]+' "$REAL_TARGET" 2>/dev/null | sed 's/^AI-//' | sort -n | tail -1 || echo 0)"
        [ -z "$_highest" ] && _highest=0
      fi
      _resolved_payload="$NORM_PAYLOAD"
      while printf '%s' "$_resolved_payload" | grep -qF 'AI-{auto}'; do
        _next=$((_highest + 1))
        # Substitute the FIRST remaining `AI-{auto}` with AI-N
        _resolved_payload="$(printf '%s' "$_resolved_payload" | awk -v repl="AI-${_next}" '
          !done && /AI-\{auto\}/ {
            sub(/AI-\{auto\}/, repl)
            done=1
          }
          { print }
        ')"
        _highest=$_next
      done
      {
        printf '\n%s\n' "$_resolved_payload"
        printf '# dedup_key: %s\n' "$DEDUP_KEY"
      } >> "$REAL_TARGET"
      ;;
    *)
      if [ "$OVERSIZED" -eq 1 ]; then
        local preview
        preview="$(printf '%s' "$NORM_PAYLOAD" | head -c 512)"
        {
          printf '\n### Sprint %s — %s\n\n' "$SPRINT_ID" "$TIMESTAMP"
          printf 'Preview (truncated — full payload in details fold):\n\n'
          printf '%s...\n\n' "$preview"
          printf '<details><summary>Full payload (%d bytes)</summary>\n\n' "$PAYLOAD_BYTES"
          printf '%s\n' "$NORM_PAYLOAD"
          printf '\n</details>\n'
          printf '\n<!-- dedup_key: %s -->\n' "$DEDUP_KEY"
        } >> "$REAL_TARGET"
      else
        {
          printf '\n### Sprint %s — %s\n\n' "$SPRINT_ID" "$TIMESTAMP"
          printf '%s\n' "$NORM_PAYLOAD"
          printf '\n<!-- dedup_key: %s -->\n' "$DEDUP_KEY"
        } >> "$REAL_TARGET"
      fi
      ;;
  esac
}

if command -v flock >/dev/null 2>&1; then
  (
    flock -x 9
    # Re-check idempotency under the lock so a racing writer's entry is
    # observed before we append a duplicate.
    RE_EXISTING="$(normalize_payload "$(cat "$REAL_TARGET" 2>/dev/null || true)")"
    case "$REAL_TARGET" in
      */velocity-data.md)
        if printf '%s' "$RE_EXISTING" | grep -qE "^### Sprint ${SPRINT_ID}( |$)"; then
          exit 42
        fi ;;
      *)
        if printf '%s' "$RE_EXISTING" | grep -Fq "dedup_key: ${DEDUP_KEY}"; then
          exit 42
        fi ;;
    esac
    _append
  ) 9>"$LOCKFILE"
  APPEND_STATUS=$?
else
  # macOS fallback — coarse mkdir-based mutex (atomic under POSIX).
  LOCKDIR="${REAL_TARGET}.lockdir"
  tries=0
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -gt 600 ] && { rmdir "$LOCKDIR" 2>/dev/null || true; break; }
    sleep 0.02
  done
  # Re-check idempotency under the mutex.
  RE_EXISTING="$(normalize_payload "$(cat "$REAL_TARGET" 2>/dev/null || true)")"
  case "$REAL_TARGET" in
    */velocity-data.md)
      if printf '%s' "$RE_EXISTING" | grep -qE "^### Sprint ${SPRINT_ID}( |$)"; then
        rmdir "$LOCKDIR" 2>/dev/null || true
        rm -f "$BACKUP"
        printf 'status=skipped_idempotent\nreason=velocity row already present for %s\n' "$SPRINT_ID"
        exit 0
      fi ;;
    *)
      if printf '%s' "$RE_EXISTING" | grep -Fq "dedup_key: ${DEDUP_KEY}"; then
        rmdir "$LOCKDIR" 2>/dev/null || true
        rm -f "$BACKUP"
        printf 'status=skipped_idempotent\nreason=entry with dedup_key already present\n'
        exit 0
      fi ;;
  esac
  _append
  APPEND_STATUS=$?
  rmdir "$LOCKDIR" 2>/dev/null || true
fi

# Treat exit 42 from the locked subshell as skipped_idempotent.
if [ "$APPEND_STATUS" -eq 42 ]; then
  rm -f "$BACKUP" "$LOCKFILE"
  printf 'status=skipped_idempotent\nreason=entry with dedup_key already present (race-resolved)\n'
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. VERIFY — on mismatch restore from .bak; on success rm .bak
# ---------------------------------------------------------------------------
append_succeeded=1
if [ "$APPEND_STATUS" -ne 0 ] || ! grep -Fq "dedup_key: ${DEDUP_KEY}" "$REAL_TARGET" 2>/dev/null; then
  append_succeeded=0
fi

if [ "$append_succeeded" -eq 0 ]; then
  # Restore from backup. On macOS chmod 0444 blocks overwrite via cp even with
  # -p; try to force-remove then re-create via cat to tolerate read-only targets
  # during test fixtures.
  if [ -f "$BACKUP" ]; then
    if ! cp -p "$BACKUP" "$REAL_TARGET" 2>/dev/null; then
      # Force restoration — remove the hostile target first.
      rm -f "$REAL_TARGET" 2>/dev/null || true
      if ! cp -p "$BACKUP" "$REAL_TARGET" 2>/dev/null; then
        # Final fallback — cat the backup bytes over the target path.
        cat "$BACKUP" > "$REAL_TARGET" 2>/dev/null || true
      fi
    fi
    rm -f "$BACKUP"
  fi
  rm -f "$LOCKFILE"
  printf 'status=io_error\nreason=append failed; target restored (or best-effort) from backup\n' >&2
  exit 1
fi

rm -f "$BACKUP" "$LOCKFILE"
printf 'status=ok\ndedup_key=%s\ntarget=%s\n' "$DEDUP_KEY" "$REAL_TARGET"
exit 0

fi  # end CLI body source-guard (E36-S5)
