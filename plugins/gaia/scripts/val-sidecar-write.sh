#!/usr/bin/env bash
# val-sidecar-write.sh — shared Val sidecar writer helper
# Architecture §10.10 (FR-VSP-1, FR-VSP-2, NFR-VSP-1, NFR-VSP-2). Story E34-S1.
#
# Restores the V1 auto-persistence behavior for 5 Phase 4 commands:
#   /gaia-create-story, /gaia-validate-story, /gaia-sprint-plan,
#   /gaia-triage-findings, /gaia-retro
# (/gaia-tech-debt-review keeps its existing inline Step 7 write as the
# gold-standard reference; it is NOT a consumer of this helper.)
#
# Contract:
#   val-sidecar-write.sh \
#     --command-name <name>       e.g. /gaia-create-story
#     --input-id <id>             e.g. E99-S1 / sprint-26 / triage-id
#     --decision-payload <json>   JSON object: {verdict, findings[], artifact_path, ...}
#     [--sprint-id <id>]          read by caller; degrade to N/A if unset
#     [--root <project-root>]     defaults to $CLAUDE_PROJECT_ROOT or $(pwd)
#     [--target <absolute-path>]  DEBUG override — must still pass allowlist
#
# Exit codes:
#   0 — entry written OR skipped_duplicate
#   1 — rejected (allowlist) OR missing required args OR IO error
#
# Output (stdout):
#   status=<written|skipped_duplicate|rejected>
#   [dedup_key=<hex>]                  (on written)
#   [reason=<human-readable detail>]   (on skipped_duplicate / rejected)
#
# Allowlist (NFR-VSP-2) — exactly two paths, validator-sidecar only:
#   <root>/_memory/validator-sidecar/decision-log.md
#   <root>/_memory/validator-sidecar/conversation-context.md
#
# Idempotency (FR-VSP-2):
#   decision_hash = SHA-256(canonical_payload)
#   canonical_payload = json.dumps({verdict, findings sorted by id, artifact_path}, sort_keys=True)
#   composite dedup_key = SHA-256(command_name\ninput_id\ndecision_hash)
#   If <!-- dedup_key: {composite} --> already appears in decision-log.md, skip.
#
# Refs: ADR-016 (version-controlled agent memory format), ADR-042 (scripts-over-LLM),
#       ADR-052 (retro writer — parallel pattern).

set -uo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
COMMAND_NAME=""
INPUT_ID=""
DECISION_PAYLOAD=""
SPRINT_ID=""
ROOT=""
TARGET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --command-name)     COMMAND_NAME="$2"; shift 2 ;;
    --input-id)         INPUT_ID="$2"; shift 2 ;;
    --decision-payload) DECISION_PAYLOAD="$2"; shift 2 ;;
    --sprint-id)        SPRINT_ID="$2"; shift 2 ;;
    --root)             ROOT="$2"; shift 2 ;;
    --target)           TARGET="$2"; shift 2 ;;
    --help|-h)
      sed -n '1,45p' "$0"
      exit 0
      ;;
    *)
      printf 'status=rejected\nreason=unknown arg: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$ROOT" ]; then
  ROOT="${CLAUDE_PROJECT_ROOT:-$(pwd)}"
fi
if [ -z "$COMMAND_NAME" ]; then
  printf 'status=rejected\nreason=--command-name is required\n' >&2
  exit 1
fi
if [ -z "$INPUT_ID" ]; then
  printf 'status=rejected\nreason=--input-id is required\n' >&2
  exit 1
fi
if [ -z "$DECISION_PAYLOAD" ]; then
  printf 'status=rejected\nreason=--decision-payload is required\n' >&2
  exit 1
fi
if [ -z "$SPRINT_ID" ]; then
  SPRINT_ID="N/A"
fi

# ---------------------------------------------------------------------------
# Backend capability cache
# ---------------------------------------------------------------------------
# Detect external helpers exactly once per process to avoid per-call
# `command -v` forks. Every public function that needs a backend choice
# will fall back to a lazy detect (see `_init_backends`) so unit tests
# that source individual functions keep working.
_init_backends() {
  if [ -z "${_VS_HASH_BACKEND:-}" ]; then
    if command -v openssl >/dev/null 2>&1; then _VS_HASH_BACKEND=openssl
    else _VS_HASH_BACKEND=shasum; fi
  fi
  if [ -z "${_VS_JQ_AVAILABLE:-}" ]; then
    if command -v jq >/dev/null 2>&1; then _VS_JQ_AVAILABLE=1
    else _VS_JQ_AVAILABLE=0; fi
  fi
  if [ -z "${_VS_FLOCK_AVAILABLE:-}" ]; then
    if command -v flock >/dev/null 2>&1; then _VS_FLOCK_AVAILABLE=1
    else _VS_FLOCK_AVAILABLE=0; fi
  fi
}
_init_backends

# ---------------------------------------------------------------------------
# Helpers — exposed as public functions for unit tests (NFR-052)
# ---------------------------------------------------------------------------

# resolve_real — canonical absolute path using deepest-existing-ancestor
# semantics. Matches the retro-sidecar-write.sh behavior so tests that rely
# on /tmp → /private/tmp realpath drift stay consistent across the two
# helpers. Fast path uses pure bash (`cd -P`) to avoid python3 spawn on
# macOS — NFR-VSP-1 requires 50ms median; python3 startup alone costs
# ~40ms, so the main pipeline is structured to spawn python3 at most once
# (inside canonicalize_payload).
resolve_real() {
  local p="$1"
  # Make absolute so splits are predictable.
  case "$p" in
    /*) ;;
    *)  p="$(pwd)/$p" ;;
  esac
  # Walk up to the deepest existing ancestor using bash-native primitives.
  local cur="$p" tail=""
  while [ -n "$cur" ] && [ "$cur" != "$(dirname "$cur")" ]; do
    if [ -e "$cur" ] || [ -L "$cur" ]; then break; fi
    if [ -z "$tail" ]; then tail="$(basename "$cur")"; else tail="$(basename "$cur")/$tail"; fi
    cur="$(dirname "$cur")"
  done
  # Canonicalize the existing ancestor via `cd -P` (follows symlinks) if it
  # is a directory, or use its parent and re-attach the basename otherwise.
  # If `cur` is itself a symlink (to a file or dir outside validator-sidecar
  # — the TC-VSP-3c attack path), follow one step of the symlink chain so
  # the allowlist check sees the final destination.
  local real_ancestor
  if [ -L "$cur" ]; then
    local lnk; lnk="$(readlink -- "$cur" 2>/dev/null || true)"
    case "$lnk" in
      /*) cur="$lnk" ;;
      *)  cur="$(dirname "$cur")/$lnk" ;;
    esac
  fi
  if [ -d "$cur" ]; then
    real_ancestor="$(cd -P -- "$cur" 2>/dev/null && pwd)"
  elif [ -e "$cur" ]; then
    local pd bn
    pd="$(dirname "$cur")"; bn="$(basename "$cur")"
    real_ancestor="$(cd -P -- "$pd" 2>/dev/null && pwd)/$bn"
  else
    # Broken symlink or non-existent path — re-attach parent's real path.
    local pd bn
    pd="$(dirname "$cur")"; bn="$(basename "$cur")"
    if [ -d "$pd" ]; then
      real_ancestor="$(cd -P -- "$pd" 2>/dev/null && pwd)/$bn"
    else
      real_ancestor="$cur"
    fi
  fi
  if [ -z "$real_ancestor" ]; then real_ancestor="$cur"; fi
  if [ -n "$tail" ]; then
    printf '%s/%s\n' "$real_ancestor" "$tail"
  else
    printf '%s\n' "$real_ancestor"
  fi
}

# allowlist_match — NFR-VSP-2: the helper writes to exactly two files and
# no others. Paths are matched by suffix against the resolved real root.
allowlist_match() {
  local real_root="$1" real_target="$2"
  case "$real_target" in
    "$real_root"/_memory/validator-sidecar/decision-log.md)         return 0 ;;
    "$real_root"/_memory/validator-sidecar/conversation-context.md) return 0 ;;
    "$real_root"/.gaia/memory/validator-sidecar/decision-log.md)         return 0 ;;
    "$real_root"/.gaia/memory/validator-sidecar/conversation-context.md) return 0 ;;
    *) return 1 ;;
  esac
}

# sha256 — return the hex SHA-256 digest of stdin.
#
# Performance: prefers openssl (native binary, ~12ms) over shasum (Perl
# script, ~33ms on macOS) when available. Fallback keeps behavior identical
# on systems without openssl. NFR-VSP-1 target: 50ms median.
sha256() {
  _init_backends
  if [ "$_VS_HASH_BACKEND" = "openssl" ]; then
    openssl dgst -sha256 -r 2>/dev/null | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# canonicalize_payload — produce a deterministic minified JSON form used
# as input to the decision-hash. Contract per architecture §10.10:
#   { verdict, findings[] sorted by id, artifact_path }
# Timestamps and any session metadata are explicitly excluded.
#
# Performance: prefers jq (~7ms) over python3 (~40ms spawn) to keep the
# hot pipeline inside the NFR-VSP-1 50ms budget. python3 is the fallback
# when jq is not on PATH.
canonicalize_payload() {
  local raw="$1"
  _init_backends
  if [ "$_VS_JQ_AVAILABLE" = "1" ]; then
    # jq -cS: compact, sorted keys. Project onto the contract triple and
    # sort findings by id; fall back to tostring for findings missing id.
    # E63-S14 type-guard: handle the array-of-strings shape that triage
    # sometimes passes — `.id` on a string element throws `Cannot index
    # string with string "id"`. Same fix as the fast-path at L261.
    printf '%s' "$raw" | jq -cS '
      {
        artifact_path: (.artifact_path // ""),
        findings: ((.findings // []) | sort_by(if type == "object" then (.id // tostring) else tostring end)),
        verdict: (.verdict // "")
      }
    '
    return $?
  fi
  python3 - "$raw" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    obj = json.loads(raw)
except Exception as e:
    print(f"canonicalize: invalid json: {e}", file=sys.stderr)
    sys.exit(2)
verdict = obj.get("verdict", "")
artifact_path = obj.get("artifact_path", "")
findings = obj.get("findings", []) or []
try:
    findings = sorted(findings, key=lambda f: f.get("id", "") if isinstance(f, dict) else repr(f))
except Exception:
    findings = sorted(findings, key=repr)
canonical = {"artifact_path": artifact_path, "findings": findings, "verdict": verdict}
sys.stdout.write(json.dumps(canonical, sort_keys=True, separators=(",", ":")))
PY
}

# compute_dedup_key — composite key over (command_name, input_id, decision_hash).
# decision_hash = SHA-256(canonical_payload). Returns the 64-char hex of
# SHA-256(command_name \n input_id \n decision_hash).
#
# Performance: uses jq (native binary, ~7ms) for canonicalization and
# shasum (native binary) for hashing so the hot path avoids spawning
# python3 entirely when jq is present. NFR-VSP-1 target: 50ms median.
compute_dedup_key() {
  local cmd="$1" iid="$2" payload="$3"
  _init_backends
  # Fast path: jq canonicalize | openssl sha256 | awk-compose | openssl sha256.
  # All processes in the pipeline start concurrently, so wall time is
  # dominated by the slowest single process (~12ms openssl) rather than
  # 2x serial openssl startups.
  if [ "$_VS_JQ_AVAILABLE" = "1" ] && [ "$_VS_HASH_BACKEND" = "openssl" ]; then
    printf '%s' "$payload" \
      | jq -cS '{artifact_path: (.artifact_path // ""), findings: ((.findings // []) | sort_by(if type == "object" then (.id // tostring) else tostring end)), verdict: (.verdict // "")}' \
      | openssl dgst -sha256 -r 2>/dev/null \
      | awk -v cmd="$cmd" -v iid="$iid" '{printf "%s\n%s\n%s", cmd, iid, $1}' \
      | openssl dgst -sha256 -r 2>/dev/null \
      | awk '{print $1}'
    return
  fi
  # Fallback path — used when jq or openssl is unavailable. Retains the
  # same canonicalization semantics via python3 / shasum.
  local canonical decision_hash
  canonical="$(canonicalize_payload "$payload")"
  decision_hash="$(printf '%s' "$canonical" | sha256)"
  printf '%s\n%s\n%s' "$cmd" "$iid" "$decision_hash" | sha256
}

# ensure_header — seed a canonical header at the target if the file is
# missing. Never rewrites an existing file.
ensure_header() {
  local tgt="$1"
  [ -e "$tgt" ] && return 0
  mkdir -p "$(dirname "$tgt")"
  case "$tgt" in
    */decision-log.md)
      cat > "$tgt" <<'EOF'
# Val Validator — Decision Log

> Chronological record of validation decisions. ADR-016 format.
> Entries appended by the Shared Val Sidecar Writer (architecture §10.10).
> Idempotency keyed on `command_name + input_id + decision_hash` (NFR-VSP-2).

EOF
      ;;
    */conversation-context.md)
      cat > "$tgt" <<'EOF'
# Val Validator — Conversation Context

> Rolling summary of the most recent validation session.

EOF
      ;;
    *)
      : > "$tgt"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------

REAL_ROOT="$(resolve_real "$ROOT")"
[ -z "$REAL_ROOT" ] && REAL_ROOT="$ROOT"

# E96-S8 partial-fix: smart-fallback for validator-sidecar location.
# Prefer .gaia/memory/validator-sidecar/ when the .gaia/ tree is present;
# fall back to legacy _memory/validator-sidecar/ for in-deprecation-window
# consumers and bats fixtures.
if [ -d "$REAL_ROOT/.gaia/memory" ]; then
  DECISION_LOG="$REAL_ROOT/.gaia/memory/validator-sidecar/decision-log.md"
  CONTEXT_FILE="$REAL_ROOT/.gaia/memory/validator-sidecar/conversation-context.md"
else
  DECISION_LOG="$REAL_ROOT/_memory/validator-sidecar/decision-log.md"
  CONTEXT_FILE="$REAL_ROOT/_memory/validator-sidecar/conversation-context.md"
fi

# --target overrides only the primary write path — it must still pass the
# allowlist. This exists so the allowlist guard itself can be exercised
# from integration tests.
PRIMARY_TARGET="$DECISION_LOG"
if [ -n "$TARGET" ]; then
  PRIMARY_TARGET="$TARGET"
fi

# Resolve the real target for allowlist verification. If the path is a
# symlink, resolve_real will follow it — so a decoy symlink inside
# validator-sidecar/ that points outside is caught here (TC-VSP-3c).
# Fast path: when the target is the default canonical DECISION_LOG under a
# REAL_ROOT we already realpath'd, and the file is not a symlink, the
# resolve is a no-op. Skipping the second resolve_real saves ~8ms on macOS
# and preserves the symlink-traversal check via the explicit -L branch.
if [ "$PRIMARY_TARGET" = "$DECISION_LOG" ] && [ ! -L "$DECISION_LOG" ] && [ ! -L "$(dirname "$DECISION_LOG")" ]; then
  REAL_PRIMARY="$DECISION_LOG"
else
  REAL_PRIMARY="$(resolve_real "$PRIMARY_TARGET")"
  [ -z "$REAL_PRIMARY" ] && REAL_PRIMARY="$PRIMARY_TARGET"
fi

if ! allowlist_match "$REAL_ROOT" "$REAL_PRIMARY"; then
  printf 'status=rejected\nreason=path outside validator-sidecar allowlist: %s\n' "$REAL_PRIMARY" >&2
  exit 1
fi

# Seed headers if missing.
ensure_header "$DECISION_LOG"
ensure_header "$CONTEXT_FILE"

# Compute dedup key.
DEDUP_KEY="$(compute_dedup_key "$COMMAND_NAME" "$INPUT_ID" "$DECISION_PAYLOAD")"

# Idempotency scan — grep the decision log for the composite marker.
if grep -Fq "<!-- dedup_key: ${DEDUP_KEY} -->" "$DECISION_LOG" 2>/dev/null; then
  printf 'status=skipped_duplicate\nreason=entry with dedup_key already present\ndedup_key=%s\n' "$DEDUP_KEY"
  exit 0
fi

# Use bash parameter expansion for the preview substring to avoid the
# `head` fork. Date is taken via `date` to stay compatible with bash 3.2
# (macOS system bash) — %(...)T is bash 4.2+ only.
DATE_NOW="$(date -u +%Y-%m-%d)"
SUMMARY_PREVIEW="${DECISION_PAYLOAD:0:200}"

# Atomic-ish append with flock when available.
_append_decision() {
  {
    printf '\n### [%s] %s: %s\n\n' "$DATE_NOW" "$COMMAND_NAME" "$INPUT_ID"
    printf -- '- agent: val\n'
    printf -- '- command: %s\n' "$COMMAND_NAME"
    printf -- '- input_id: %s\n' "$INPUT_ID"
    printf -- '- sprint: %s\n' "$SPRINT_ID"
    printf -- '- status: recorded\n'
    printf -- '- related: %s\n' "$INPUT_ID"
    printf '\n%s\n\n' "$SUMMARY_PREVIEW"
    printf '<!-- dedup_key: %s -->\n' "$DEDUP_KEY"
  } >> "$DECISION_LOG"
}

_append_context() {
  {
    printf '\n### [%s] Session: %s — %s\n\n' "$DATE_NOW" "$COMMAND_NAME" "$INPUT_ID"
    printf -- '- command: %s\n' "$COMMAND_NAME"
    printf -- '- input_id: %s\n' "$INPUT_ID"
    printf -- '- sprint: %s\n' "$SPRINT_ID"
    printf '\nLast session: %s for %s.\n' "$COMMAND_NAME" "$INPUT_ID"
  } >> "$CONTEXT_FILE"
}

LOCKFILE="${DECISION_LOG}.lock"
APPEND_STATUS=0
if [ "$_VS_FLOCK_AVAILABLE" = "1" ]; then
  (
    flock -x 9
    # Re-check idempotency under the lock to neutralize races.
    if grep -Fq "<!-- dedup_key: ${DEDUP_KEY} -->" "$DECISION_LOG" 2>/dev/null; then
      exit 42
    fi
    _append_decision
    _append_context
  ) 9>"$LOCKFILE"
  APPEND_STATUS=$?
else
  # Fallback: coarse mkdir-based mutex (portable, atomic per POSIX).
  # Scanning the file is already done outside the mutex, and per-sprint
  # input_id writes are single-writer in practice (the composite key is a
  # function of caller identity), so we skip the in-lock re-scan for speed.
  LOCKDIR="${DECISION_LOG}.lockdir"
  tries=0
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -gt 600 ] && break
    sleep 0.02
  done
  _append_decision
  APPEND_STATUS=$?
  _append_context
  rmdir "$LOCKDIR" 2>/dev/null || true
fi

if [ "$APPEND_STATUS" -eq 42 ]; then
  rm -f "$LOCKFILE"
  printf 'status=skipped_duplicate\nreason=entry with dedup_key already present (race-resolved)\ndedup_key=%s\n' "$DEDUP_KEY"
  exit 0
fi

if [ "$APPEND_STATUS" -ne 0 ]; then
  rm -f "$LOCKFILE"
  printf 'status=rejected\nreason=append failed; partial write possible\n' >&2
  exit 1
fi

rm -f "$LOCKFILE"
printf 'status=written\ndedup_key=%s\ntarget=%s\n' "$DEDUP_KEY" "$DECISION_LOG"
exit 0
