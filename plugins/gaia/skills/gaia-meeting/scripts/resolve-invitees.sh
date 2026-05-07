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
#     [--invitees-override]
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

MODE=""
INVITEES_CSV=""
INSTALLED=""
OVERRIDE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)              MODE="$2"; shift 2 ;;
    --invitees)          INVITEES_CSV="$2"; shift 2 ;;
    --installed)         INSTALLED="$2"; shift 2 ;;
    --invitees-override) OVERRIDE="true"; shift ;;
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
