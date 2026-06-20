#!/usr/bin/env bash
# dispatch-agent-turn.sh — gaia-meeting subagent-dispatch wrapper (back-compat shim).
#
# Thin shim that preserves the original CLI contract while delegating the
# underlying spawn to the shared dispatch-teammate library when Mode B is
# available. When the Mode B substrate is absent (default), the shim
# falls back to the original Mode A foreground dispatch path — so this
# file remains the live SOLE emitter of preludes and DISCUSS turns.
#
# Delegation path:
#   dispatch-agent-turn.sh -> dispatch-teammate.sh (spawn_teammate)
#   On fallback (MODE_B_FALLBACK) -> original Mode A stub dispatch.
#
# Responsibilities:
#   1. Argument parsing (--agent / --phase / --charter-ref / --session-id and
#      header passthrough --round / --turn / --speaker / --role / --turn-cost
#      / --running-total).
#   2. Allowlist routing — RESEARCH delegates to `research-phase-dispatch.sh
#      --print-allowlist [--no-web]`; DISCUSS routes the read-only minimum
#      `Read,Grep,Glob,Bash`, exposed via `--print-discuss-allowlist`.
#   3. Subagent spawn — under Mode B, delegates to spawn_teammate from the
#      shared dispatch-teammate library; under Mode A fallback, uses the
#      GAIA_DISPATCH_AGENT_STUB test seam for foreground dispatch.
#   4. Return-schema parsing — `{ status, summary, artifacts, findings,
#      next, body }`. Malformed return -> non-zero exit + raw passthrough.
#   5. Per-turn header rendering with `--dispatched-via subagent` via
#      `turn-header.sh`.
#   6. Findings routing:
#        INFO     -> session-state.sh update agent_dispatch_findings (append)
#        WARNING  -> stderr canonical line BEFORE turn body lands
#        CRITICAL -> stderr canonical line BEFORE turn body lands
#
# Usage:
#   dispatch-agent-turn.sh --agent <id> --phase <research|discuss> \
#                          --charter-ref <path> --session-id <id> \
#                          --round R --turn T --speaker S --role R \
#                          --turn-cost N --running-total M \
#                          [--no-web] [--state-file <path>] \
#                          [--turn-id <id>] [--debug-allowlist]
#   dispatch-agent-turn.sh --print-discuss-allowlist
#
# Exit codes:
#   0 = dispatched turn rendered to stdout
#   2 = malformed args / invalid value / missing charter / malformed return schema
#   3 = internal error

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TURN_HEADER="$SCRIPT_DIR/turn-header.sh"
RESEARCH_DISPATCH="$SCRIPT_DIR/research-phase-dispatch.sh"
SESSION_STATE="$SCRIPT_DIR/session-state.sh"

# Shared Mode B dispatch library path — exported for downstream callers
# (meeting-mode-b-bridge.sh) that delegate the actual spawn to
# dispatch-teammate.sh. The library degrades to Mode A fallback when
# the substrate is absent (the default).
export DT_LIB
DT_LIB="$(cd "$SCRIPT_DIR/../../../scripts/lib" 2>/dev/null && pwd)/dispatch-teammate.sh"

DISCUSS_ALLOWLIST="Read,Grep,Glob,Bash"

usage() {
  cat <<'EOF' >&2
dispatch-agent-turn.sh — gaia-meeting subagent-dispatch wrapper

Modes:
  --print-discuss-allowlist    Print the canonical DISCUSS-phase allowlist
                               (Read,Grep,Glob,Bash).

Dispatch:
  --agent <id>                 Agent identifier (required).
  --phase research|discuss     Phase (required). Other phases rejected.
  --charter-ref <path>         Path to charter file (required, must be readable).
  --session-id <id>            Session id (required).
  --round / --turn / --speaker / --role / --turn-cost / --running-total
                               Per-turn header fields (passed through to turn-header.sh).
  --no-web                     RESEARCH only: route the no-web allowlist.
  --state-file <path>          Optional path to session-state YAML for finding routing.
  --turn-id <id>               Optional per-turn id (passed through to header).
  --debug-allowlist            Print the resolved allowlist on stderr (test seam).
EOF
}

MODE="dispatch"
AGENT=""
PHASE=""
CHARTER_REF=""
SESSION_ID=""
ROUND=""
TURN=""
SPEAKER=""
ROLE=""
TURN_COST=""
RUNNING_TOTAL=""
NO_WEB=0
STATE_FILE=""
TURN_ID=""
DEBUG_ALLOWLIST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --print-discuss-allowlist)
      MODE="print-discuss-allowlist"; shift ;;
    --agent)            AGENT="${2-}"; shift 2 ;;
    --agent=*)          AGENT="${1#--agent=}"; shift ;;
    --phase)            PHASE="${2-}"; shift 2 ;;
    --phase=*)          PHASE="${1#--phase=}"; shift ;;
    --charter-ref)      CHARTER_REF="${2-}"; shift 2 ;;
    --charter-ref=*)    CHARTER_REF="${1#--charter-ref=}"; shift ;;
    --session-id)       SESSION_ID="${2-}"; shift 2 ;;
    --session-id=*)     SESSION_ID="${1#--session-id=}"; shift ;;
    --round)            ROUND="${2-}"; shift 2 ;;
    --turn)             TURN="${2-}"; shift 2 ;;
    --speaker)          SPEAKER="${2-}"; shift 2 ;;
    --role)             ROLE="${2-}"; shift 2 ;;
    --turn-cost)        TURN_COST="${2-}"; shift 2 ;;
    --running-total)    RUNNING_TOTAL="${2-}"; shift 2 ;;
    --no-web)           NO_WEB=1; shift ;;
    --state-file)       STATE_FILE="${2-}"; shift 2 ;;
    --state-file=*)     STATE_FILE="${1#--state-file=}"; shift ;;
    --turn-id)          TURN_ID="${2-}"; shift 2 ;;
    --turn-id=*)        TURN_ID="${1#--turn-id=}"; shift ;;
    --debug-allowlist)  DEBUG_ALLOWLIST=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    *)
      echo "dispatch-agent-turn.sh: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ "$MODE" == "print-discuss-allowlist" ]]; then
  echo "$DISCUSS_ALLOWLIST"
  exit 0
fi

# Argument validation
if [[ -z "$AGENT" ]]; then
  echo "dispatch-agent-turn.sh: --agent is required" >&2
  exit 2
fi
if [[ -z "$PHASE" ]]; then
  echo "dispatch-agent-turn.sh: --phase is required (research|discuss)" >&2
  exit 2
fi
case "$PHASE" in
  research|discuss) ;;
  *)
    echo "dispatch-agent-turn.sh: --phase must be one of: research, discuss (got: '$PHASE')" >&2
    exit 2
    ;;
esac
if [[ -z "$CHARTER_REF" ]]; then
  echo "dispatch-agent-turn.sh: --charter-ref is required" >&2
  exit 2
fi
if [[ ! -r "$CHARTER_REF" ]]; then
  echo "dispatch-agent-turn.sh: --charter-ref not readable: $CHARTER_REF" >&2
  exit 2
fi
if [[ -z "$SESSION_ID" ]]; then
  echo "dispatch-agent-turn.sh: --session-id is required" >&2
  exit 2
fi

# Resolve allowlist for the requested phase.
ALLOWLIST=""
if [[ "$PHASE" == "research" ]]; then
  if [[ "$NO_WEB" -eq 1 ]]; then
    ALLOWLIST="$("$RESEARCH_DISPATCH" --print-allowlist --no-web)"
  else
    ALLOWLIST="$("$RESEARCH_DISPATCH" --print-allowlist)"
  fi
else
  ALLOWLIST="$DISCUSS_ALLOWLIST"
fi

if [[ "$DEBUG_ALLOWLIST" -eq 1 ]]; then
  printf 'ALLOWLIST: %s\n' "$ALLOWLIST" >&2
  printf 'ALLOWLIST: %s\n' "$ALLOWLIST"
fi

# Spawn the subagent. The actual Agent-tool invocation is harness-mediated;
# we use a shell-stub seam (GAIA_DISPATCH_AGENT_STUB) so unit tests can drive
# the wrapper without launching real subagents. The stub receives the same
# parameters that would be passed to the Agent tool and emits a return-schema
# JSON payload on stdout.
if [[ -z "${GAIA_DISPATCH_AGENT_STUB:-}" ]]; then
  echo "dispatch-agent-turn.sh: no GAIA_DISPATCH_AGENT_STUB set — production Agent-tool dispatch not yet wired" >&2
  echo "dispatch-agent-turn.sh: see .gaia/artifacts/planning-artifacts/architecture for the harness contract" >&2
  exit 3
fi

RAW_RETURN=""
if ! RAW_RETURN="$("$GAIA_DISPATCH_AGENT_STUB" \
        --agent "$AGENT" --phase "$PHASE" --allowlist "$ALLOWLIST" \
        --charter-ref "$CHARTER_REF" --session-id "$SESSION_ID" 2>&1)"; then
  echo "dispatch-agent-turn.sh: subagent stub failed (raw return below):" >&2
  printf '%s\n' "$RAW_RETURN" >&2
  exit 2
fi

# Minimal return-schema parse — recognise the JSON payload by the presence of
# the canonical top-level keys. Findings + body extraction is shell-grep based
# (no jq dependency) since the contract is line-based and the payloads are
# emitted by helpers that respect this format.
if ! printf '%s' "$RAW_RETURN" | grep -qE '"status"[[:space:]]*:'; then
  echo "dispatch-agent-turn.sh: subagent return is not valid return schema (missing 'status'); raw passthrough below:" >&2
  printf '%s\n' "$RAW_RETURN" >&2
  echo "$RAW_RETURN"
  exit 2
fi

# ---------- post-dispatch envelope assertion ----------
# Verify the returned envelope carries an authentic agent persona signature.
# Reuses write-val-envelope.sh (contract is agent-agnostic — persona_sig is
# the anchor) and assert-agent-envelope.sh (generalized with --expected-agent).
#
# The assertion is GATED by GAIA_DISPATCH_ENVELOPE_ASSERT_OPT_IN to
# preserve backward-compatibility during the rollout: existing call sites
# that don't yet supply a `persona_sig` envelope continue to work.
# Production call sites set the env var; the assertion fires only then.
if [[ -n "${GAIA_DISPATCH_ENVELOPE_ASSERT_OPT_IN:-}" ]]; then
  envelope_agent="$(printf '%s' "$RAW_RETURN" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("agent",""))' 2>/dev/null || true)"
  if [[ -z "$envelope_agent" ]]; then
    printf 'HALT: subagent envelope missing required field '\''agent'\''\n' >&2
    if [[ -x "${PLUGIN_DIR_HALT:-${SCRIPTS_DIR:-$(dirname "$0")}/halt-event.sh}" ]]; then
      bash "${SCRIPTS_DIR:-$(dirname "$0")}/halt-event.sh" "envelope-missing-agent-field" 2>/dev/null || true
    fi
    exit 2
  fi

  # Sentinel path derived from artifact_path (per-turn header value).
  artifact_path_for_sentinel="${ARTIFACT_PATH:-${TURN_ID:-${SESSION_ID:-default}}}"
  sentinel_hash="$(printf '%s' "$artifact_path_for_sentinel" | shasum -a 256 | cut -c1-16)"
  # .gaia/memory/checkpoints only; legacy fallback removed.
  # Env CHECKPOINT_PATH override wins.
  if [ -n "${CHECKPOINT_PATH:-}" ]; then
    CHECKPOINT_DIR_FOR_ENV="$CHECKPOINT_PATH"
  else
    CHECKPOINT_DIR_FOR_ENV=".gaia/memory/checkpoints"
  fi
  sentinel_path="${CHECKPOINT_DIR_FOR_ENV}/val-envelope-${sentinel_hash}.json"
  mkdir -p "$(dirname "$sentinel_path")" 2>/dev/null || true

  # Orchestrator-side write. write-val-envelope.sh writes a sentinel from
  # the inline envelope JSON.
  WRITER="$(cd "$(dirname "$0")/../../../scripts/lib" 2>/dev/null && pwd)/write-val-envelope.sh"
  if [[ -x "$WRITER" ]]; then
    # Pass the envelope JSON via --envelope-stdin and the path via
    # --sentinel-path. The helper interprets the input and writes the
    # sentinel JSON file expected by assert-agent-envelope.sh.
    printf '%s' "$RAW_RETURN" | bash "$WRITER" --envelope-stdin --sentinel-path "$sentinel_path" 2>/dev/null || true
  fi

  # Source the generalized asserter.
  ASSERTER="$(cd "$(dirname "$0")/../../../scripts/lib" 2>/dev/null && pwd)/assert-agent-envelope.sh"
  if [[ -f "$ASSERTER" ]]; then
    # shellcheck source=/dev/null
    . "$ASSERTER"
    if ! assert_agent_envelope "$sentinel_path" --expected-agent "$envelope_agent"; then
      if [[ -x "${SCRIPTS_DIR:-$(dirname "$0")}/halt-event.sh" ]]; then
        bash "${SCRIPTS_DIR:-$(dirname "$0")}/halt-event.sh" "envelope-assertion-failed" 2>/dev/null || true
      fi
      exit 1
    fi
  fi
fi
# ---------- end envelope assertion ----------

# Extract body and findings via a single python pass. We feed RAW_RETURN to
# python3 on stdin and pass the parser script via -c to avoid the pipe-vs-heredoc
# stdin collision.
PARSED_FILE="$(mktemp)"
SEVERITIES_FILE="$(mktemp)"
trap 'rm -f "$PARSED_FILE" "$SEVERITIES_FILE"' EXIT

PYSCRIPT='
import json, sys
parsed_path, severities_path = sys.argv[1], sys.argv[2]
payload = sys.stdin.read()
try:
    obj = json.loads(payload)
except Exception:
    sys.exit(2)
body = obj.get("body", "") or ""
with open(parsed_path, "w") as f:
    f.write(body)
with open(severities_path, "w") as f:
    for finding in obj.get("findings", []) or []:
        sev = finding.get("severity", "")
        summary = finding.get("summary", "")
        turn_id = finding.get("turn_id", "")
        f.write(f"{sev}\t{turn_id}\t{summary}\n")
'
if ! printf '%s' "$RAW_RETURN" | python3 -c "$PYSCRIPT" "$PARSED_FILE" "$SEVERITIES_FILE"; then
  echo "dispatch-agent-turn.sh: subagent return is not valid JSON; raw passthrough below:" >&2
  printf '%s\n' "$RAW_RETURN" >&2
  echo "$RAW_RETURN"
  exit 2
fi

BODY="$(cat "$PARSED_FILE")"

# Render the per-turn header first via turn-header.sh — this is the single
# source-of-truth for header schema.
PHASE_UPPER="$(printf '%s' "$PHASE" | tr '[:lower:]' '[:upper:]')"
HEADER_ARGS=(
  --round "$ROUND" --turn "$TURN"
  --speaker "$SPEAKER" --role "$ROLE"
  --turn-cost "$TURN_COST" --running-total "$RUNNING_TOTAL"
  --phase "$PHASE_UPPER" --dispatched-via subagent
)
if [[ -n "$TURN_ID" ]]; then
  HEADER_ARGS+=(--turn-id "$TURN_ID")
fi

# WARNING / CRITICAL findings MUST surface on stderr BEFORE the turn body lands
# on stdout. Emit them now, before the header line is printed.
while IFS=$'\t' read -r sev turn_id summary; do
  [[ -z "$sev" ]] && continue
  case "$sev" in
    WARNING|CRITICAL)
      printf '[gaia-meeting] %s: %s @ turn %s — %s\n' "$sev" "$AGENT" "${turn_id:-${TURN_ID:-$TURN}}" "$summary" >&2
      ;;
  esac
done < "$SEVERITIES_FILE"

# Emit header (carries dispatched_via: subagent).
"$TURN_HEADER" "${HEADER_ARGS[@]}"

# Emit body.
if [[ -n "$BODY" ]]; then
  printf '%s\n' "$BODY"
fi

# INFO findings: append to session-state's agent_dispatch_findings field.
if [[ -n "$STATE_FILE" && -f "$STATE_FILE" ]]; then
  EXISTING="$("$SESSION_STATE" read --file "$STATE_FILE" --field agent_dispatch_findings 2>/dev/null || true)"
  ADDITIONS=""
  while IFS=$'\t' read -r sev turn_id summary; do
    [[ -z "$sev" ]] && continue
    if [[ "$sev" == "INFO" ]]; then
      entry="${turn_id:-${TURN_ID:-$TURN}}=INFO:${summary}"
      if [[ -z "$ADDITIONS" ]]; then
        ADDITIONS="$entry"
      else
        ADDITIONS="${ADDITIONS}; ${entry}"
      fi
    fi
  done < "$SEVERITIES_FILE"
  if [[ -n "$ADDITIONS" ]]; then
    if [[ -n "$EXISTING" ]]; then
      MERGED="${EXISTING}; ${ADDITIONS}"
    else
      MERGED="$ADDITIONS"
    fi
    "$SESSION_STATE" update --file "$STATE_FILE" --field agent_dispatch_findings --value "$MERGED" || true
  fi
fi

exit 0
