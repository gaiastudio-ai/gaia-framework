#!/usr/bin/env bash
# memory-loader.sh — GAIA foundation script (E28-S13)
#
# Loads an agent's sidecar memory (decision-log and/or ground-truth) and prints
# it to stdout for direct inline-embedding in subagent prompts via `!` bash.
# This script is READ-ONLY with respect to _memory/ contents.
#
# Refs: FR-325, FR-328, NFR-048, ADR-042, ADR-048
# Brief: P2-S5 (docs/creative-artifacts/gaia-native-conversion-feature-brief-2026-04-14.md)
#
# Invocation contract (stable for E28-S17 bats-core authors):
#
#   memory-loader.sh <agent_name> <tier>
#                    [--max-tokens <n>] [--format inline] [--help]
#
#   <tier> ∈ { decision-log, ground-truth, all }
#
# Exit codes:
#   0 — success (content printed, or empty-on-missing, or --help)
#   1 — usage error (missing/invalid positional args, invalid tier)
#
# Consumers: every subagent that needs memory context, via `!` inline bash in
# the subagent prompt's `## Memory` section (brief Cluster 3 pattern).
#
# Missing memory contract: a missing sidecar directory or missing files is NOT
# an error. The script prints empty stdout and exits 0. This is intentional so
# that `!` bash inlines never break subagent activation on fresh projects.
#
# Performance budget (NFR-048): < 50ms wall-clock on a developer workstation.
# The script resolves config once, reads files once, and avoids forking more
# than necessary to meet the every-subagent-activation budget.

set -euo pipefail

# E96-S4 / ADR-111: prefer .gaia/memory/ over legacy _memory/. Resolution order:
#   1. ${MEMORY_PATH} env override (highest priority, unchanged contract).
#   2. ${PROJECT_PATH}/.gaia/memory/ when the dir exists.
#   3. ${PROJECT_PATH}/_memory/ legacy fallback during the 1-sprint deprecation
#      window (removed in E96-S5).
_gaia_resolve_memory_path() {
  if [ -n "${MEMORY_PATH:-}" ]; then
    printf '%s' "$MEMORY_PATH"
    return 0
  fi
  local root="${PROJECT_PATH:-.}"
  if [ -d "$root/.gaia/memory" ]; then
    printf '%s' "$root/.gaia/memory"
  else
    printf '%s' "$root/_memory"
  fi
}
MEMORY_PATH="$(_gaia_resolve_memory_path)"
CONFIG="${MEMORY_PATH}/config.yaml"

# E96-S4 / AC6: session-load 4-case migration-manifest sentinel check.
# Emits a single-line WARN to stderr in cases (A) and (D); HALT in case (B).
# Sets _GAIA_SESSION_LOAD_READ_ONLY=1 to signal downstream writers to refuse
# in cases (A) and (D). Case (C) (clean match) is silent.
_gaia_session_load_sentinel_check() {
  local manifest="${MEMORY_PATH}/.migration-manifest"
  if [ ! -f "$manifest" ]; then
    # Case (A): manifest absent. If the legacy path is in use, this is normal.
    # If we're already on .gaia/memory/, this signals an incomplete migration.
    case "$MEMORY_PATH" in
      *"/.gaia/memory"|".gaia/memory")
        printf 'session-load: .migration-manifest missing — operating read-only until migration completes\n' >&2
        _GAIA_SESSION_LOAD_READ_ONLY=1
        export _GAIA_SESSION_LOAD_READ_ONLY
        ;;
    esac
    return 0
  fi
  # Manifest present. Verify known schema fields.
  # Case (D): unknown fields → WARN + read-only.
  if awk -F'"' '
    BEGIN { unknown = 0 }
    /"phase":/ {
      # Allowed phases 1-4
      match($0, /"phase":[[:space:]]*[0-9]+/)
      val = substr($0, RSTART+8, RLENGTH-8)
      gsub(/[[:space:]]/, "", val)
      if (val+0 > 4 || val+0 < 1) unknown = 1
    }
    /"schema_version":/ { unknown = 1 }
    END { exit(unknown ? 0 : 1) }
  ' "$manifest" 2>/dev/null; then
    printf 'session-load: unknown manifest record fields — operating read-only for forward-compat safety\n' >&2
    _GAIA_SESSION_LOAD_READ_ONLY=1
    export _GAIA_SESSION_LOAD_READ_ONLY
    return 0
  fi
  # Case (B) per-file sha256 mismatch is checked at write-time per file by
  # consumers; the loader itself does not spot-check every recorded file
  # (would blow NFR-048's 50ms budget). The downstream writers (write-checkpoint.sh,
  # action-items-write.sh, retro-sidecar-write.sh) verify per their own contracts.
  # Case (C): silent success.
  return 0
}
_gaia_session_load_sentinel_check || true

usage() {
  cat <<'EOF'
Usage: memory-loader.sh <agent_name> <tier> [--max-tokens <n>] [--format inline] [--help]

Positional arguments:
  <agent_name>      Agent id (e.g. nate, val, cleo)
  <tier>            One of: decision-log | ground-truth | all

Flags:
  --max-tokens <n>  Truncate output to approximately <n> tokens using
                    archival.token_approximation from _memory/config.yaml
                    (default 4 chars/token). Coarse char-based truncation.
  --format inline   Wrap output in a single Markdown fenced code block
                    suitable for direct embedding in a subagent prompt.
  --help            Print this help and exit 0.

Behavior:
  - Sidecar directory resolves via _memory/config.yaml agents.<agent>.sidecar;
    falls back to _memory/<agent_name>-sidecar/ when unmapped or config missing.
  - Missing sidecar dir or files → empty stdout, exit 0 (no error).
  - Read-only. Never writes to _memory/ contents.

Refs: FR-325, FR-328, NFR-048, ADR-042, ADR-048 (brief P2-S5)
EOF
}

# --- Argument parsing -------------------------------------------------------
agent_name=""
tier=""
max_tokens=""
format=""

positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --max-tokens)
      if [[ $# -lt 2 ]]; then
        echo "error: --max-tokens requires a value" >&2
        exit 1
      fi
      max_tokens="$2"
      shift 2
      ;;
    --max-tokens=*)
      max_tokens="${1#*=}"
      shift
      ;;
    --format)
      if [[ $# -lt 2 ]]; then
        echo "error: --format requires a value" >&2
        exit 1
      fi
      format="$2"
      shift 2
      ;;
    --format=*)
      format="${1#*=}"
      shift
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        positional+=("$1")
        shift
      done
      ;;
    -*)
      echo "error: unknown flag: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

if [[ ${#positional[@]} -lt 2 ]]; then
  echo "error: <agent_name> and <tier> are required" >&2
  usage >&2
  exit 1
fi

agent_name="${positional[0]}"
tier="${positional[1]}"

case "$tier" in
  decision-log|ground-truth|all) ;;
  *)
    echo "error: tier must be one of: decision-log | ground-truth | all (got '$tier')" >&2
    usage >&2
    exit 1
    ;;
esac

if [[ -n "$max_tokens" ]]; then
  if ! [[ "$max_tokens" =~ ^[0-9]+$ ]] || [[ "$max_tokens" -le 0 ]]; then
    echo "error: --max-tokens must be a positive integer (got '$max_tokens')" >&2
    exit 1
  fi
fi

if [[ -n "$format" && "$format" != "inline" ]]; then
  echo "error: --format must be 'inline' (got '$format')" >&2
  exit 1
fi

# --- Resolve sidecar directory ---------------------------------------------
# Prefer yq; fall back to an awk parser that extracts the nested key
#   agents.<agent_name>.sidecar
# from the small, stable _memory/config.yaml schema.
sidecar_rel=""
if [[ -f "$CONFIG" ]]; then
  if command -v yq >/dev/null 2>&1; then
    sidecar_rel="$(yq -r ".agents.\"${agent_name}\".sidecar // \"\"" "$CONFIG" 2>/dev/null || true)"
    [[ "$sidecar_rel" == "null" ]] && sidecar_rel=""
  else
    # POSIX-awk-compatible fallback (no match()-with-array). Walks the
    # agents: block and prints the sidecar value for the requested agent.
    sidecar_rel="$(awk -v agent="$agent_name" '
      BEGIN { in_agents = 0; in_agent = 0; agent_indent = -1 }
      /^[[:space:]]*#/ { next }
      {
        if ($0 ~ /^agents:[[:space:]]*$/) { in_agents = 1; next }
        if (!in_agents) { next }
        # leaving the agents: block on another top-level key
        if ($0 ~ /^[^[:space:]#]/) { in_agents = 0; in_agent = 0; next }
        # agent entry: "<indent><name>:" (no value)
        if ($0 ~ /^[[:space:]]+[^[:space:]:#]+:[[:space:]]*$/) {
          line = $0
          # capture leading indent
          indent_str = line
          sub(/[^[:space:]].*$/, "", indent_str)
          indent = length(indent_str)
          # capture name
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
          # strip surrounding quotes
          sub(/^"/, "", val); sub(/"$/, "", val)
          sub(/^'"'"'/, "", val); sub(/'"'"'$/, "", val)
          print val
          exit
        }
      }
    ' "$CONFIG" 2>/dev/null || true)"
  fi
fi

if [[ -z "$sidecar_rel" ]]; then
  sidecar_dir="${MEMORY_PATH}/${agent_name}-sidecar"
else
  sidecar_dir="${MEMORY_PATH}/${sidecar_rel}"
fi

# --- Load content per tier --------------------------------------------------
out=""
gt_file="${sidecar_dir}/ground-truth.md"
dl_file="${sidecar_dir}/decision-log.md"

case "$tier" in
  decision-log)
    if [[ -f "$dl_file" ]]; then
      out="$(cat "$dl_file")"
    fi
    ;;
  ground-truth)
    if [[ -f "$gt_file" ]]; then
      out="$(cat "$gt_file")"
    fi
    ;;
  all)
    gt=""
    dl=""
    [[ -f "$gt_file" ]] && gt="$(cat "$gt_file")" || true
    [[ -f "$dl_file" ]] && dl="$(cat "$dl_file")" || true
    if [[ -n "$gt" || -n "$dl" ]]; then
      out="## Ground Truth"$'\n\n'"${gt}"$'\n\n'"## Decision Log"$'\n\n'"${dl}"
    fi
    ;;
esac

# --- --max-tokens truncation -----------------------------------------------
if [[ -n "$max_tokens" && -n "$out" ]]; then
  tok_approx=4
  if [[ -f "$CONFIG" ]]; then
    if command -v yq >/dev/null 2>&1; then
      val="$(yq -r '.archival.token_approximation // 4' "$CONFIG" 2>/dev/null || echo 4)"
      [[ "$val" =~ ^[0-9]+$ ]] && tok_approx="$val"
    else
      val="$(awk '
        /^[[:space:]]*#/ { next }
        /^archival:[[:space:]]*$/ { in_arch = 1; next }
        in_arch && /^[^[:space:]#]/ { in_arch = 0 }
        in_arch && /^[[:space:]]+token_approximation:[[:space:]]*[0-9]+/ {
          v = $0
          sub(/^[[:space:]]+token_approximation:[[:space:]]*/, "", v)
          sub(/[^0-9].*$/, "", v)
          print v
          exit
        }
      ' "$CONFIG" 2>/dev/null || true)"
      [[ -n "$val" && "$val" =~ ^[0-9]+$ ]] && tok_approx="$val"
    fi
  fi
  max_chars=$(( max_tokens * tok_approx ))
  out="$(printf '%s' "$out" | head -c "$max_chars")"
fi

# --- --format inline wrapper ------------------------------------------------
if [[ "$format" == "inline" ]]; then
  # Always emit the fenced block, even if empty, so the calling prompt has a
  # predictable shape. An empty inline block is still a valid no-op for `!`.
  # shellcheck disable=SC2016
  printf '```\n%s\n```\n' "$out"
else
  # Non-inline: plain content with no trailing newline added. If `out` is empty
  # (missing sidecar), stdout stays empty — AC4.
  printf '%s' "$out"
fi

exit 0
