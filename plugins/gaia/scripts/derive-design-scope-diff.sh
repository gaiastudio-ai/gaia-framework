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
#       but not in local). Published artboard paths (project/<name>.dc.html
#       only) map to screens/<name>.spec.html. Non-artboard published paths
#       are ignored. Flows have no published mapping and are tracked by
#       --edited and by the added-screen check only.
#   (c) Token rule: when any tokens/ path changed in (a), also mark the
#       product design project changed.
#
# Exit codes:
#   0 — success, scope printed on stdout
#   2 — usage error (missing/invalid argument or malformed input)
#
# Output: one word on stdout (design-system, product-design, or both).

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Test seam: honoured only when running under bats (BATS_TEST_FILENAME set).
# Production always resolves the helper next to this script.
if [ -n "${BATS_TEST_FILENAME:-}" ] && [ -n "${_DERIVE_SCOPE_HELPER_OVERRIDE:-}" ]; then
  SCOPE_HELPER="$_DERIVE_SCOPE_HELPER_OVERRIDE"
else
  SCOPE_HELPER="$SCRIPT_DIR/derive-design-scope.sh"
fi

# ---------------------------------------------------------------------------
# Path normalisation helper
# ---------------------------------------------------------------------------

# _normalise_path PATH SPEC_ROOT — strip leading ./, remove spec-root prefix.
# Paths containing .. segments are treated as unclassified (passed through
# literally; derive-design-scope.sh will map them to "both").
_normalise_path() {
  local p="$1" sr="$2"
  # Strip leading ./
  p="${p#./}"
  # Remove spec-root prefix (strip trailing slash from root for matching)
  if [ -n "$sr" ]; then
    local sr_clean="${sr%/}"
    case "$p" in
      "${sr_clean}/"*) p="${p#"${sr_clean}/"}" ;;
    esac
  fi
  printf '%s\n' "$p"
}

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------

_last_published=""
_local_manifest=""
_spec_root=""

# Collect --edited paths into a newline-delimited string (bash 3.2 safe)
_edited_paths=""

while [ $# -gt 0 ]; do
  case "$1" in
    --last-published)
      if [ $# -lt 2 ]; then
        printf 'derive-design-scope-diff.sh: --last-published requires a value\n' >&2
        exit 2
      fi
      _last_published="$2"; shift 2 ;;
    --local-manifest)
      if [ $# -lt 2 ]; then
        printf 'derive-design-scope-diff.sh: --local-manifest requires a value\n' >&2
        exit 2
      fi
      _local_manifest="$2"; shift 2 ;;
    --spec-root)
      if [ $# -lt 2 ]; then
        printf 'derive-design-scope-diff.sh: --spec-root requires a value\n' >&2
        exit 2
      fi
      _spec_root="$2"; shift 2 ;;
    --edited)
      shift
      while [ $# -gt 0 ]; do
        case "$1" in
          --*) break ;;
          *)
            # Normalise each edited path before storing
            _norm="$(_normalise_path "$1" "$_spec_root")"
            if [ -n "$_edited_paths" ]; then
              _edited_paths="${_edited_paths}
${_norm}"
            else
              _edited_paths="$_norm"
            fi
            shift
            ;;
        esac
      done
      ;;
    *)
      printf 'derive-design-scope-diff.sh: unknown flag: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$_local_manifest" ]; then
  printf 'derive-design-scope-diff.sh: --local-manifest required\n' >&2
  exit 2
fi

if [ ! -f "$_local_manifest" ]; then
  printf 'derive-design-scope-diff.sh: --local-manifest file not found: %s\n' "$_local_manifest" >&2
  exit 2
fi

# Validate the local manifest is valid JSON
if ! jq '.' "$_local_manifest" >/dev/null 2>&1; then
  printf 'derive-design-scope-diff.sh: --local-manifest is not valid JSON: %s\n' "$_local_manifest" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Read the last-published baseline
# ---------------------------------------------------------------------------

_lp_file="/dev/null"
if [ -n "$_last_published" ] && [ -f "$_last_published" ] && [ -s "$_last_published" ]; then
  if ! jq '.' "$_last_published" >/dev/null 2>&1; then
    printf 'derive-design-scope-diff.sh: --last-published is not valid JSON: %s\n' "$_last_published" >&2
    exit 2
  fi
  _lp_file="$_last_published"
fi

# ---------------------------------------------------------------------------
# Single-pass jq diff: compute changed paths
# ---------------------------------------------------------------------------

# The jq program computes the full diff in one invocation using two files.
# It reads last-published from --slurpfile and local-manifest from stdin.
_changed_output="$(jq -r --arg edited "$_edited_paths" \
  --slurpfile lp "$_lp_file" '
  # Use first element of slurpfile (or empty object for /dev/null)
  ($lp[0] // {}) as $pub |

  # Parse edited paths (newline-delimited, already normalised)
  ($edited | split("\n") | map(select(length > 0))) as $edited_list |

  # Build published design-system lookup: {path: hash}
  (($pub.design_system.files // [])
    | map({key: .path, value: .hash}) | from_entries) as $ds_pub |

  # Build published product-design lookup: ONLY project/*.dc.html artboards
  # map to screens/*.spec.html. Non-artboard paths are ignored.
  (($pub.product_design.files // [])
    | map(select(.path | test("^project/[^/]+\\.dc\\.html$")))
    | map({key: (.path | sub("^project/"; "screens/") | sub("\\.dc\\.html$"; ".spec.html")),
           value: .hash})
    | from_entries) as $pd_pub |

  # Read local manifest from stdin
  . as $local |

  # (a) Design-system diff: changed or added entries
  ([$local | to_entries[]
    | select(.key | test("^(tokens|components|templates)/"))
    | select(($ds_pub[.key] // null) != .value)
    | .key]) as $ds_changed |

  # (a) Design-system removed: in published but not in local
  ([$ds_pub | to_entries[]
    | select(.key | test("^(tokens|components|templates)/"))
    | select($local[.key] == null)
    | .key]) as $ds_removed |

  # All design-system changes
  ($ds_changed + $ds_removed) as $all_ds |

  # Token change flag
  ([$all_ds[] | select(startswith("tokens/"))] | length > 0) as $has_token |

  # (b-i) Edited screens/flows (already normalised)
  ([$edited_list[] | select(test("^(screens|flows)/"))]) as $edited_pd |

  # (b-ii) Added screens: in local manifest but not in published.
  # Only screens/ are checked against the published artboard set.
  # Flows have no published artboard mapping and are tracked by --edited only.
  ([$local | keys[] | select(test("^screens/"))
    | select(. as $k | $pd_pub[$k] == null)]) as $added_pd |

  # (b-iii) Removed screens: in published artboard set but not in local
  ([$pd_pub | keys[] | select(. as $k | $local[$k] == null)]) as $removed_pd |

  # (c) Token rule marker
  (if $has_token then ["screens/__token_change__"] else [] end) as $token_marker |

  # Combine all changed paths (deduplicated)
  ($all_ds + $edited_pd + $added_pd + $removed_pd + $token_marker | unique | .[])
' "$_local_manifest" 2>/dev/null)" || {
  printf 'derive-design-scope-diff.sh: jq diff failed\n' >&2
  exit 2
}

# ---------------------------------------------------------------------------
# Classify via derive-design-scope.sh
# ---------------------------------------------------------------------------

# Build args array (bash 3.2 safe: use set --)
set --
if [ -n "$_spec_root" ]; then
  set -- --spec-root "$_spec_root"
fi

if [ -n "$_changed_output" ]; then
  while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    set -- "$@" "$_p"
  done <<CPEOF
$_changed_output
CPEOF
fi

exec bash "$SCOPE_HELPER" "$@"
