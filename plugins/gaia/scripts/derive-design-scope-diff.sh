#!/usr/bin/env bash
# derive-design-scope-diff.sh — per-project manifest diff for scope derivation.
#
# Compares the current local spec manifest against the persisted
# design-last-published.json and classifies the changed paths into a
# publication scope via derive-design-scope.sh.
#
# The script never renders anything and never sees rendered artboard
# hashes. It operates on spec-side paths only.
#
# Usage:
#   derive-design-scope-diff.sh --last-published <path> --local-manifest <path> \
#     [--edited <path>...] [--spec-root <dir>]
#
# Flags:
#   --last-published <path>  — path to design-last-published.json (or /dev/null)
#   --local-manifest <path>  — JSON {spec_path: source_hash, ...}
#   --edited <path>...       — spec paths this run edited (zero or more)
#   --spec-root <dir>        — for absolute-path normalisation (passed through)
#
# Diff rules (spec-side, no rendering):
#   (a) Design-system: diff tokens/, components/, templates/ entries
#       by path and source-content hash.
#   (b) Product design: a screen or flow counts as changed when edited,
#       added (in local but not in published), or removed (in published
#       but not in local). Published keys map from project/<name>.dc.html
#       to screens/<name>.spec.html. Emits spec-side paths only.
#   (c) Token rule: when any tokens/ path changed in (a), also mark the
#       product design project changed.
#
# Output: one word on stdout (design-system, product-design, or both).

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Append SCRIPT_DIR so derive-design-scope.sh is reachable by bare name.
# A test shim prepended to PATH takes priority over the real script.
PATH="${PATH:+${PATH}:}${SCRIPT_DIR}"

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------

_last_published=""
_local_manifest=""
_spec_root=""
_edited_count=0

# Collect --edited paths into a newline-delimited string (bash 3.2 safe)
_edited_paths=""

while [ $# -gt 0 ]; do
  case "$1" in
    --last-published) _last_published="$2"; shift 2 ;;
    --local-manifest) _local_manifest="$2"; shift 2 ;;
    --spec-root)      _spec_root="$2";      shift 2 ;;
    --edited)
      shift
      while [ $# -gt 0 ]; do
        case "$1" in
          --*) break ;;
          *)
            if [ -n "$_edited_paths" ]; then
              _edited_paths="${_edited_paths}
${1}"
            else
              _edited_paths="$1"
            fi
            _edited_count=$(( _edited_count + 1 ))
            shift
            ;;
        esac
      done
      ;;
    *) shift ;;
  esac
done

[ -n "$_local_manifest" ] || { printf 'derive-design-scope-diff.sh: --local-manifest required\n' >&2; exit 2; }

# ---------------------------------------------------------------------------
# Read the last-published baseline
# ---------------------------------------------------------------------------

# When /dev/null or a non-existent file is given, treat as empty baseline.
_lp_json="{}"
if [ -n "$_last_published" ] && [ -f "$_last_published" ] && [ -s "$_last_published" ]; then
  _lp_json="$(cat "$_last_published")"
fi

# ---------------------------------------------------------------------------
# (a) Design-system diff: tokens/, components/, templates/
# ---------------------------------------------------------------------------

_changed_paths=""
_has_token_change=0

# Extract design-system files from last-published as path\thash lines
_ds_published=""
_ds_published="$(printf '%s' "$_lp_json" | jq -r '
  (.design_system.files // [])[] |
  "\(.path)\t\(.hash)"
' 2>/dev/null || true)"

# For each local manifest entry with a design-system prefix, check
# whether it is new or changed vs the published baseline.
while IFS= read -r _line; do
  [ -n "$_line" ] || continue
  _lpath="$(printf '%s' "$_line" | jq -r '.key' 2>/dev/null)"
  _lhash="$(printf '%s' "$_line" | jq -r '.value' 2>/dev/null)"

  case "$_lpath" in
    tokens/*|components/*|templates/*) ;;
    *) continue ;;
  esac

  # Look up the path in the published baseline
  _pub_hash=""
  if [ -n "$_ds_published" ]; then
    _pub_hash="$(printf '%s\n' "$_ds_published" | while IFS='	' read -r _pp _ph; do
      if [ "$_pp" = "$_lpath" ]; then
        printf '%s' "$_ph"
        break
      fi
    done)"
  fi

  if [ "$_pub_hash" != "$_lhash" ]; then
    # New or changed
    _changed_paths="${_changed_paths:+${_changed_paths} }${_lpath}"
    case "$_lpath" in
      tokens/*) _has_token_change=1 ;;
    esac
  fi
done <<EOF
$(jq -c 'to_entries[] | {key, value}' "$_local_manifest" 2>/dev/null)
EOF

# Check for removed design-system files (in published but not in local)
if [ -n "$_ds_published" ]; then
  while IFS='	' read -r _pp _ph; do
    [ -n "$_pp" ] || continue
    case "$_pp" in
      tokens/*|components/*|templates/*) ;;
      *) continue ;;
    esac
    # Check if path exists in local manifest
    _in_local="$(jq -r --arg p "$_pp" 'has($p)' "$_local_manifest" 2>/dev/null || printf 'false')"
    if [ "$_in_local" != "true" ]; then
      _changed_paths="${_changed_paths:+${_changed_paths} }${_pp}"
      case "$_pp" in
        tokens/*) _has_token_change=1 ;;
      esac
    fi
  done <<DSEOF
$_ds_published
DSEOF
fi

# ---------------------------------------------------------------------------
# (b) Product-design diff: screens/, flows/ via edited/added/removed
# ---------------------------------------------------------------------------

# Build the set of published screen spec paths (mapped from project/<name>.dc.html)
_pd_published_specs=""
_pd_published_specs="$(printf '%s' "$_lp_json" | jq -r '
  (.product_design.files // [])[] | .path
' 2>/dev/null | while IFS= read -r _artboard; do
  [ -n "$_artboard" ] || continue
  # Map project/<name>.dc.html to screens/<name>.spec.html
  _base="${_artboard#project/}"
  _base="${_base%.dc.html}"
  if [ "$_artboard" != "$_base" ] && [ -n "$_base" ]; then
    printf 'screens/%s.spec.html\n' "$_base"
  fi
done || true)"

# (i) Edited screens/flows
if [ -n "$_edited_paths" ]; then
  while IFS= read -r _ep; do
    [ -n "$_ep" ] || continue
    case "$_ep" in
      screens/*|flows/*) _changed_paths="${_changed_paths:+${_changed_paths} }${_ep}" ;;
    esac
  done <<EDEOF
$_edited_paths
EDEOF
fi

# (ii) Added screens/flows: in local manifest but not in published
while IFS= read -r _line; do
  [ -n "$_line" ] || continue
  _lpath="$(printf '%s' "$_line" | jq -r '.key' 2>/dev/null)"
  case "$_lpath" in
    screens/*|flows/*) ;;
    *) continue ;;
  esac
  # Check if this spec is in the published set
  _found=0
  if [ -n "$_pd_published_specs" ]; then
    while IFS= read -r _ps; do
      if [ "$_ps" = "$_lpath" ]; then
        _found=1
        break
      fi
    done <<PSEOF
$_pd_published_specs
PSEOF
  fi
  if [ "$_found" -eq 0 ]; then
    _changed_paths="${_changed_paths:+${_changed_paths} }${_lpath}"
  fi
done <<LMEOF
$(jq -c 'to_entries[] | {key, value}' "$_local_manifest" 2>/dev/null)
LMEOF

# (iii) Removed screens/flows: in published but not in local manifest
if [ -n "$_pd_published_specs" ]; then
  while IFS= read -r _ps; do
    [ -n "$_ps" ] || continue
    _in_local="$(jq -r --arg p "$_ps" 'has($p)' "$_local_manifest" 2>/dev/null || printf 'false')"
    if [ "$_in_local" != "true" ]; then
      _changed_paths="${_changed_paths:+${_changed_paths} }${_ps}"
    fi
  done <<RMEOF
$_pd_published_specs
RMEOF
fi

# ---------------------------------------------------------------------------
# (c) Token rule: any tokens/ change also marks product-design changed
# ---------------------------------------------------------------------------

if [ "$_has_token_change" -eq 1 ]; then
  _changed_paths="${_changed_paths:+${_changed_paths} }screens/__token_change__"
fi

# ---------------------------------------------------------------------------
# Classify via derive-design-scope.sh
# ---------------------------------------------------------------------------

_spec_root_args=""
if [ -n "$_spec_root" ]; then
  _spec_root_args="--spec-root ${_spec_root}"
fi

if [ -z "$_changed_paths" ]; then
  # No changes — pass no args to derive-design-scope.sh (returns both)
  # shellcheck disable=SC2086
  exec bash derive-design-scope.sh $_spec_root_args
else
  # shellcheck disable=SC2086
  exec bash derive-design-scope.sh $_spec_root_args $_changed_paths
fi
