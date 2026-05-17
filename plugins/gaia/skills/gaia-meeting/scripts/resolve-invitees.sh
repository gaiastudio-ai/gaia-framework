#!/usr/bin/env bash
# resolve-invitees.sh — gaia-meeting INVITE-phase invitee resolver (E76-S5)
#
# FR-MTG-17 (mode-default invitees) / FR-MTG-18 (graceful degradation)
#
# Reads the resolved mode (canonical) and the user-supplied invitee CSV, looks
# up the mode registry for the mode's `default_invitees`, checks each default
# against an "installed" index file (one identifier per line), and emits the
# resolved set, the missing list (when any), the canonical mode name, the
# bias, and an `invitees_override` flag.
#
# When `--invitees-override` is set, the override path bypasses default-
# invitee lookup entirely — the user-supplied CSV is authoritative and no
# WARNING fires. (Per AC14 / Open Question #2 resolution: override REPLACES,
# not extends.)
#
# Usage:
#   resolve-invitees.sh \
#     --mode <canonical-mode> \
#     --invitees "<csv>" \
#     --installed <path-to-line-list> \
#     [--invitees-override] \
#     [--session-file <path-to-session-state.yaml>]
#
# When `--session-file` is supplied (E76-S21 / AF-2026-05-10-2 user-as-first-
# class-attendee path), the resolver detects user-tokens (`me` / `user` /
# resolved-user-name; case-insensitive) in the user CSV, PRESERVES them in the
# resolved CSV, emits NO WARNING for user-tokens, and updates the session-
# state file via `session-state.sh update --field user_attendance --value
# true|false` exactly once. When `--session-file` is OMITTED, the legacy
# behavior is preserved bit-for-bit (drops user-tokens with the FR-MTG-10 /
# AC4 WARNING) so non-meeting callers and pre-S21 fixtures continue to work.
#
# Stdout (one key=value per line, in fixed order):
#   resolved=<csv>
#   missing=<csv-or-empty>
#   bias=<bias-name>
#   canonical_mode=<mode>
#   invitees_override=<true|false>
#   default_invitees_resolved=<csv-or-empty>
#
# Stderr:
#   WARNING line per FR-MTG-18 when default invitees are missing (override
#   path emits no WARNING).
#
# Exit codes:
#   0 = success (including the missing-default-invitees graceful-degradation
#       path — AC11/AC12/AC13 require exit 0)
#   2 = invalid args
#   3 = unknown mode (registry miss)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/load-mode-registry.sh
. "$SCRIPT_DIR/lib/load-mode-registry.sh"

# Locale invariance — see "Determinism + locale" note in the gaia-meeting
# framework convention. BSD vs GNU character-class differences are pinned out.
export LC_ALL=C

MODE=""
INVITEES_CSV=""
INSTALLED=""
OVERRIDE="false"
SESSION_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)              MODE="$2"; shift 2 ;;
    --invitees)          INVITEES_CSV="$2"; shift 2 ;;
    --installed)         INSTALLED="$2"; shift 2 ;;
    --invitees-override) OVERRIDE="true"; shift ;;
    --session-file)      SESSION_FILE="$2"; shift 2 ;;
    *) echo "resolve-invitees.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$MODE" ]]; then
  echo "resolve-invitees.sh: --mode is required" >&2
  exit 2
fi

# Canonicalise the mode (also handles the ux -> design alias).
canonical="$(mode_registry_canonical "$MODE" || true)"
if [[ -z "$canonical" ]]; then
  echo "resolve-invitees.sh: unknown mode '$MODE'" >&2
  exit 3
fi

bias="$(mode_registry_field "$canonical" closing_artifact_bias)"

# Parse user CSV preserving order, dropping empty entries and dedup-trimmed
# whitespace. We do NOT lowercase or otherwise transform identifiers — they
# must round-trip verbatim.
user_invitees=()
if [[ -n "$INVITEES_CSV" ]]; then
  IFS=',' read -ra _user_raw <<< "$INVITEES_CSV"
  for entry in "${_user_raw[@]}"; do
    trimmed="${entry#"${entry%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ -z "$trimmed" ]] && continue
    user_invitees+=("$trimmed")
  done
fi

# User-token detection (FR-MTG-10, originally landed by E76-S8 as a drop-with-
# WARNING gate; reworked under AF-2026-05-10-2 / E76-S21 / AI-2026-05-09-9 to
# the user-as-first-class-attendee carve-out).
#
# Three case-insensitive checks resolve a CSV token to "the user":
#   - literal "me"
#   - literal "user"
#   - equality with the resolved user name from scripts/resolve-user-name.sh
#     (case-insensitive, expanded by S21 — was case-sensitive under S8).
#     Best-effort: if the resolver is missing or fails, the user-name check
#     is silently skipped (the literal-token checks still fire). Skipping
#     the resolver step is intentional: a CI runner without git config +
#     settings.json must not block invitee resolution.
#
# Behavior under the two modes:
#   1. `--session-file <path>` PRESENT (canonical /gaia-meeting flow per
#      E76-S21 carve-out): user-tokens are PRESERVED in the resolved CSV;
#      no WARNING is emitted; session-state `user_attendance` is updated
#      exactly once (`true` if any user-token was detected, `false`
#      otherwise). The user is treated as a non-LLM attendee with a turn
#      slot at every yield boundary (composes with E76-S18 AskUserQuestion
#      mechanism). Existing TC-MTG-NOFAB-3a (PRIMARY E76-S21) covers this.
#   2. `--session-file` ABSENT (legacy callers + non-meeting fixtures):
#      user-tokens are DROPPED with the FR-MTG-10 / AC4 WARNING preserved
#      bit-for-bit. Existing TC-MTG-NOFAB-3 (now split as 3b, PRIMARY
#      E76-S8) covers this — the no-fabricated-user-turns invariant fires
#      when the user is NOT explicitly invited.
#
# `set -e` requires the user_token_seen counter to be set even when no
# tokens were processed, so we initialize before the loop.
USER_RESOLVED_NAME=""
USER_NAME_RESOLVER="$SCRIPT_DIR/resolve-user-name.sh"
if [[ -x "$USER_NAME_RESOLVER" ]]; then
  USER_RESOLVED_NAME="$("$USER_NAME_RESOLVER" 2>/dev/null || true)"
fi

# Lowercase the resolved user-name once for cheap case-insensitive comparison
# inside the loop. Empty string when the resolver could not produce a name.
USER_RESOLVED_NAME_LOWER=""
if [[ -n "$USER_RESOLVED_NAME" ]]; then
  USER_RESOLVED_NAME_LOWER="$(printf '%s' "$USER_RESOLVED_NAME" | tr '[:upper:]' '[:lower:]')"
fi

user_token_seen=0
filtered_user_invitees=()
if (( ${#user_invitees[@]} > 0 )); then
  for u in "${user_invitees[@]}"; do
    # Case-insensitive comparison via lowercased copy (LC_ALL=C is pinned at
    # script entry, so [a-z]/[A-Z] match ASCII only — no UTF-8 surprises).
    u_lower="$(printf '%s' "$u" | tr '[:upper:]' '[:lower:]')"
    is_user_token=0
    if [[ "$u_lower" == "me" || "$u_lower" == "user" ]]; then
      is_user_token=1
    elif [[ -n "$USER_RESOLVED_NAME_LOWER" && "$u_lower" == "$USER_RESOLVED_NAME_LOWER" ]]; then
      is_user_token=1
    fi
    if (( is_user_token == 1 )); then
      if [[ -n "$SESSION_FILE" ]]; then
        # E76-S21 carve-out path: PRESERVE the FIRST user-token verbatim,
        # then collapse any subsequent user-tokens into the same single
        # attendee slot. The user is one human regardless of how many
        # aliases (`me`, `user`, `<resolved-name>`) appear in --invitees —
        # emitting multiple slots would produce duplicate AskUserQuestion
        # yields at each turn boundary. The first token wins so the
        # caller's intended label round-trips into downstream artifacts.
        if (( user_token_seen == 0 )); then
          filtered_user_invitees+=("$u")
        fi
        user_token_seen=1
        continue
      fi
      user_token_seen=1
      # Legacy E76-S8 path (no --session-file): drop with WARNING. Single-
      # line WARNING — exact wording preserved character-identical with the
      # original FR-MTG-10 / AC4 implementation.
      echo "[gaia-meeting] WARNING: invitee token \"${u}\" resolves to the user — the user is not an agent and is not auto-included; user authoring uses --charter / [i]nterject only" >&2
      continue
    fi
    filtered_user_invitees+=("$u")
  done
fi
user_invitees=("${filtered_user_invitees[@]}")

# E76-S21 / FR-MTG-33 schema extension — set session-state user_attendance
# exactly once. Only fires when the caller passed `--session-file` (canonical
# /gaia-meeting flow); legacy callers without a session file see no schema
# coupling, preserving backward compatibility.
if [[ -n "$SESSION_FILE" ]]; then
  SESSION_STATE_HELPER="$SCRIPT_DIR/session-state.sh"
  if [[ -x "$SESSION_STATE_HELPER" && -f "$SESSION_FILE" ]]; then
    if (( user_token_seen == 1 )); then
      "$SESSION_STATE_HELPER" update --file "$SESSION_FILE" \
        --field user_attendance --value "true"
    else
      "$SESSION_STATE_HELPER" update --file "$SESSION_FILE" \
        --field user_attendance --value "false"
    fi
  fi
fi

resolved=()
missing=()
default_resolved=()

if [[ "$OVERRIDE" == "true" ]]; then
  # Override path — user CSV is authoritative; no default-invitee lookup.
  if (( ${#user_invitees[@]} > 0 )); then
    for u in "${user_invitees[@]}"; do
      resolved+=("$u")
    done
  fi
else
  # First add the user-specified set (preserve order).
  if (( ${#user_invitees[@]} > 0 )); then
    for u in "${user_invitees[@]}"; do
      resolved+=("$u")
    done
  fi

  # Then resolve mode defaults against the installed index.
  if [[ -n "$INSTALLED" && ! -f "$INSTALLED" ]]; then
    echo "resolve-invitees.sh: --installed path not found: $INSTALLED" >&2
    exit 2
  fi

  while IFS= read -r dflt; do
    [[ -z "$dflt" ]] && continue
    if [[ -n "$INSTALLED" ]] && grep -qxF "$dflt" "$INSTALLED"; then
      # Avoid duplicating an identifier the user already specified.
      already=0
      if (( ${#resolved[@]} > 0 )); then
        for r in "${resolved[@]}"; do
          if [[ "$r" == "$dflt" ]]; then already=1; break; fi
        done
      fi
      if [[ "$already" -eq 0 ]]; then
        resolved+=("$dflt")
        default_resolved+=("$dflt")
      fi
    else
      missing+=("$dflt")
    fi
  done < <(mode_registry_list_field "$canonical" default_invitees)

  if (( ${#missing[@]} > 0 )); then
    # FR-MTG-18 WARNING — single-line, stable prefix per SKILL.md.
    missing_csv="$(IFS=,; echo "${missing[*]}")"
    resolved_csv="$(IFS=,; echo "${resolved[*]}")"
    echo "[gaia-meeting] WARNING: missing default invitee(s) for mode ${canonical}: ${missing_csv} (resolved subset: ${resolved_csv})" >&2
  fi
fi

# Empty-array safe under `set -u`.
resolved_csv=""
if (( ${#resolved[@]} > 0 )); then
  resolved_csv="$(IFS=,; echo "${resolved[*]}")"
fi
missing_csv=""
if (( ${#missing[@]} > 0 )); then
  missing_csv="$(IFS=,; echo "${missing[*]}")"
fi
default_resolved_csv=""
if (( ${#default_resolved[@]} > 0 )); then
  default_resolved_csv="$(IFS=,; echo "${default_resolved[*]}")"
fi

cat <<EOF
resolved=${resolved_csv}
missing=${missing_csv}
bias=${bias}
canonical_mode=${canonical}
invitees_override=${OVERRIDE}
default_invitees_resolved=${default_resolved_csv}
EOF

exit 0
