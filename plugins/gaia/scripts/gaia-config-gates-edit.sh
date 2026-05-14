#!/usr/bin/env bash
# gaia-config-gates-edit.sh — E71-S7
#
# Comment-preserving editor for the top-level `gates:` map in
# project-config.yaml. Implements FR-RSV2-12 per-gate severity overrides:
#
#   gates:
#     <gate-name>:
#       severity:
#         Critical: BLOCKED
#         High: REQUEST_CHANGES
#         ...
#
# Fall-through semantics: when a per-gate override is absent for a given
# internal severity, the global `severity:` map wins. When the global is
# also absent, the system default applies.
#
# Subcommands:
#   set <gate> <internal> <verdict>   — set / replace a per-gate mapping
#   show <gate>                       — print the per-gate map
#   clear <gate>                      — remove that gate's overrides
#
# Exit codes:
#   0 success
#   1 invalid argument, unknown internal/verdict, or I/O error

set -euo pipefail
LC_ALL=C
export LC_ALL

prog="gaia-config-gates-edit.sh"
err() { printf '%s: %s\n' "$prog" "$*" >&2; }

CFG=""
CMD=""
GATE=""
ARG_INT=""
ARG_VER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      [ $# -ge 2 ] || { err "--config requires a path"; exit 1; }
      CFG="$2"; shift 2 ;;
    --config=*)
      CFG="${1#--config=}"; shift ;;
    set|show|clear)
      CMD="$1"; shift
      if [ $# -ge 1 ]; then GATE="$1"; shift; fi
      if [ "$CMD" = "set" ]; then
        if [ $# -ge 1 ]; then ARG_INT="$1"; shift; fi
        if [ $# -ge 1 ]; then ARG_VER="$1"; shift; fi
      fi
      ;;
    -h|--help)
      sed -n '1,30p' "$0" >&2; exit 0 ;;
    *)
      err "unexpected argument: $1"; exit 1 ;;
  esac
done

[ -n "$CFG" ] || { err "missing --config"; exit 1; }
[ -f "$CFG" ] || { err "config not found: $CFG"; exit 1; }
[ -n "$CMD" ] || { err "missing subcommand (set|show|clear)"; exit 1; }
[ -n "$GATE" ] || { err "$CMD requires <gate>"; exit 1; }

VALID_GATE_RE='^[a-z][a-z0-9-]*$'
VALID_INTERNALS_RE='^(Critical|High|Medium|Low|Info)$'
VALID_VERDICTS_RE='^(BLOCKED|REQUEST_CHANGES|APPROVE)$'

if ! printf '%s' "$GATE" | grep -Eq "$VALID_GATE_RE"; then
  err "invalid gate name: '$GATE' (expected kebab-case ^[a-z][a-z0-9-]*\$)"
  exit 1
fi

EDITOR_SH="$(dirname "$0")/config-yaml-editor.sh"

# Read the entire gates section into a flat structure:
#   <gate>\t<internal>\t<verdict>\n
# preserving order of appearance.
#
# Uses POSIX-portable awk (no gawk-specific `match(s, r, arr)` captures).
_read_gates_flat() {
  awk '
    BEGIN { in_gates=0; cur_gate=""; in_sev=0 }
    /^gates:[[:space:]]*$/ { in_gates=1; next }
    in_gates && /^[^[:space:]]/ { in_gates=0; cur_gate=""; in_sev=0 }
    in_gates {
      # Match "  <gate>:" (two-space indent for gate name).
      if ($0 ~ /^  [a-z][a-z0-9-]*:[[:space:]]*$/) {
        g = $0
        sub(/^  /, "", g)
        sub(/:.*$/, "", g)
        cur_gate = g
        in_sev = 0
        next
      }
      # Match "    severity:" (four-space indent).
      if (cur_gate != "" && $0 ~ /^    severity:[[:space:]]*$/) {
        in_sev = 1
        next
      }
      # Match "      <Internal>: <Verdict>" (six-space indent).
      if (cur_gate != "" && in_sev) {
        if ($0 ~ /^      [A-Z][a-zA-Z]+:[[:space:]]+[A-Z_]+/) {
          line = $0
          sub(/^      /, "", line)
          name = line
          sub(/:.*$/, "", name)
          val = line
          sub(/^[^:]+:[[:space:]]*/, "", val)
          sub(/[[:space:]]*(#.*)?$/, "", val)
          gsub(/"/, "", val)
          printf "%s\t%s\t%s\n", cur_gate, name, val
        } else if ($0 !~ /^[[:space:]]*$/ && $0 !~ /^[[:space:]]*#/) {
          # End of severity block within current gate.
          in_sev = 0
        }
      }
    }
  ' "$CFG"
}

# Render a `gates:` section body (starting with `gates:` header) from flat input.
# Input: tab-separated <gate>\t<internal>\t<verdict>\n lines on stdin.
_render_gates_section() {
  awk -F'\t' '
    BEGIN { last_gate=""; print "gates:" }
    NF == 3 {
      if ($1 != last_gate) {
        printf "  %s:\n    severity:\n", $1
        last_gate=$1
      }
      printf "      %s: %s\n", $2, $3
    }
  '
}

_write_gates_section() {
  local body="$1"
  local tmp; tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT

  if [ -z "$body" ]; then
    # Empty -> remove the gates section entirely.
    if grep -qE '^gates:[[:space:]]*$' "$CFG"; then
      local out; out="$(mktemp)"
      awk '
        BEGIN { in_section=0 }
        /^gates:[[:space:]]*$/ { in_section=1; next }
        in_section {
          if ($0 ~ /^[a-z_][a-z0-9_]*:/) { in_section=0; print }
          next
        }
        { print }
      ' "$CFG" > "$out"
      mv "$out" "$CFG"
    fi
  else
    printf '%s\n' "$body" | _render_gates_section > "$tmp"
    if grep -qE '^gates:[[:space:]]*$' "$CFG"; then
      "$EDITOR_SH" replace "$CFG" gates "$tmp"
    else
      "$EDITOR_SH" insert "$CFG" gates "$tmp"
    fi
  fi

  trap - EXIT
  rm -f "$tmp"
}

case "$CMD" in
  show)
    cur="$(_read_gates_flat || true)"
    matches="$(printf '%s\n' "$cur" | awk -F'\t' -v g="$GATE" '$1 == g { print $2, $3 }')"
    if [ -z "$matches" ]; then
      echo "no overrides"
    else
      printf '%s\n' "$matches"
    fi
    ;;

  clear)
    cur="$(_read_gates_flat || true)"
    new="$(printf '%s\n' "$cur" | awk -F'\t' -v g="$GATE" '$1 != g && NF == 3')"
    _write_gates_section "$new"
    ;;

  set)
    [ -n "$ARG_INT" ] || { err "set requires <gate> <internal> <verdict>"; exit 1; }
    [ -n "$ARG_VER" ] || { err "set requires <gate> <internal> <verdict>"; exit 1; }
    if ! printf '%s' "$ARG_INT" | grep -Eq "$VALID_INTERNALS_RE"; then
      err "unknown internal severity: '$ARG_INT' (expected one of Critical|High|Medium|Low|Info)"
      exit 1
    fi
    if ! printf '%s' "$ARG_VER" | grep -Eq "$VALID_VERDICTS_RE"; then
      err "unknown verdict: '$ARG_VER' (expected one of BLOCKED|REQUEST_CHANGES|APPROVE)"
      exit 1
    fi
    cur="$(_read_gates_flat || true)"
    # Replace or append the entry. Group by gate, deduplicate by (gate, internal).
    new="$(
      {
        printf '%s\n' "$cur"
        printf '%s\t%s\t%s\n' "$GATE" "$ARG_INT" "$ARG_VER"
      } | awk -F'\t' 'NF == 3 { last[$1 "\t" $2] = $3; ord[$1 "\t" $2] = NR }
         END {
           # Re-emit preserving first-seen order by key.
           n = 0
           for (k in ord) { keys[++n] = k; pos[k] = ord[k] }
           # Sort keys by their pos value (insertion order).
           for (i = 1; i <= n; i++) {
             for (j = i+1; j <= n; j++) {
               if (pos[keys[j]] < pos[keys[i]]) {
                 t = keys[i]; keys[i] = keys[j]; keys[j] = t
               }
             }
           }
           for (i = 1; i <= n; i++) {
             split(keys[i], parts, "\t")
             printf "%s\t%s\t%s\n", parts[1], parts[2], last[keys[i]]
           }
         }' \
      | sort -t$'\t' -k1,1 -s
    )"
    _write_gates_section "$new"
    ;;

  *)
    err "unknown subcommand: $CMD"; exit 1 ;;
esac
