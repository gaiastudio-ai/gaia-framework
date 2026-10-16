#!/usr/bin/env bash
# retirement-sweep.sh -- provider-neutral retirement inventory sweep.
#
# Produces a markdown inventory of all word-bounded, case-insensitive hits
# for a named provider across the full public and enterprise trees.  The
# sweep is inventory-only: it never modifies any file in the scanned trees.
#
# Frozen definition (do not change without updating the closing proof):
#   - Pattern: word-bounded, case-insensitive match for the provider name
#   - Roots: whole gaia-public tree + whole gaia-enterprise tree
#   - Excludes: .git directories
#
# Usage:
#   retirement-sweep.sh --provider <name> \
#     --public-root <path> \
#     --enterprise-root <path> \
#     [--carve-out-file <path>] \
#     [--exclusion-file <path>] \
#     [--unowned-glob <colon-separated-patterns>] \
#     [--label-expected] \
#     [--output <path>]

set -euo pipefail
LC_ALL=C; export LC_ALL

# ---------- Source guard (allow bats to source for declare -F) ----------
_RETIREMENT_SWEEP_SOURCED=0
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  _RETIREMENT_SWEEP_SOURCED=1
fi

# ---------- Globals parsed from args ------------------------------------
_PROVIDER=""
_PUBLIC_ROOT=""
_ENTERPRISE_ROOT=""
_CARVEOUT_FILE=""
_EXCLUSION_FILE=""
_UNOWNED_GLOB="*/node_modules/*:*/vendor/*:*/third_party/*"
_LABEL_EXPECTED=0
_OUTPUT=""

# ---------- Exclusion / carve-out lookup arrays -------------------------
# Parallel arrays: _EX_PATHS[i] -> _EX_REASONS[i]
_EX_PATHS=()
_EX_REASONS=()
_CO_PATHS=()
_CO_REASONS=()

# ---------- Internal helpers --------------------------------------------

_trim() {
  local v="$1"
  v="${v%"${v##*[![:space:]]}"}"
  v="${v#"${v%%[![:space:]]*}"}"
  printf '%s' "$v"
}

# _load_path_reason_list <file> <path-array-name> <reason-array-name>
#
# Parses a pipe-delimited "path | reason" file into two parallel arrays.
# Shared by load_exclusion_list and _load_carveout_list.
_load_path_reason_list() {
  local file="$1"
  local -n _paths="$2"
  local -n _reasons="$3"
  [ -f "$file" ] || return 0
  _paths=()
  _reasons=()
  local line
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    local path reason
    path="$(_trim "${line%%|*}")"
    reason="$(_trim "${line#*|}")"
    _paths+=("$path")
    _reasons+=("$reason")
  done < "$file"
}

# _match_unowned_globs <filepath>
#
# Returns 0 and prints the matching glob if filepath matches an unowned
# pattern; returns 1 otherwise.
_match_unowned_globs() {
  local filepath="$1"
  local IFS=':'
  local patterns
  # shellcheck disable=SC2206
  patterns=($_UNOWNED_GLOB)
  unset IFS
  local pat
  for pat in "${patterns[@]}"; do
    # shellcheck disable=SC2254
    case "$filepath" in
      $pat)
        printf '%s' "$pat"
        return 0
        ;;
    esac
    # Also match without leading */ for root-level paths.
    local bare="${pat#\*/}"
    if [ "$bare" != "$pat" ]; then
      # shellcheck disable=SC2254
      case "$filepath" in
        $bare)
          printf '%s' "$pat"
          return 0
          ;;
      esac
    fi
  done
  return 1
}

# _resolve_commit <dir>
#
# Prints the HEAD commit of the git repo at <dir>, or "non-git" if not a
# git work tree.
_resolve_commit() {
  local dir="$1"
  if [ -d "$dir/.git" ] || git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$dir" rev-parse HEAD 2>/dev/null || printf 'non-git'
  else
    printf 'non-git'
  fi
}

# ---------- Public functions (column 0) ---------------------------------

load_exclusion_list() {
  _load_path_reason_list "$1" _EX_PATHS _EX_REASONS
}

annotate_hit() {
  local relpath="$1"

  # Extract file path (before first colon -- grep output is path:line:content).
  local filepath="${relpath%%:*}"

  # Check carve-out list.
  # Entries are root-relative paths (e.g. "plugins/gaia-enterprise/hooks/session-start.sh").
  # Match by exact equality against the file path portion -- never unanchored
  # substring -- so decoy/<carve-out-path> and <carve-out-path>.bak do not inherit.
  local i
  for i in "${!_CO_PATHS[@]}"; do
    if [[ "$filepath" == "${_CO_PATHS[$i]}" ]]; then
      printf '[CARVE-OUT: %s]' "${_CO_REASONS[$i]}"
      return 0
    fi
  done

  # Check exclusion list (same anchored-equality contract).
  for i in "${!_EX_PATHS[@]}"; do
    if [[ "$filepath" == "${_EX_PATHS[$i]}" ]]; then
      printf '[EXCLUDED: %s]' "${_EX_REASONS[$i]}"
      return 0
    fi
  done

  # Check unowned globs.
  local matched_glob
  if matched_glob="$(_match_unowned_globs "$filepath")"; then
    printf '[UNOWNED: path matches unowned-glob %s]' "$matched_glob"
    return 0
  fi

  # Label-expected mode.
  if [ "$_LABEL_EXPECTED" -eq 1 ]; then
    printf '[EXPECTED-STILL-PRESENT]'
    return 0
  fi

  printf ''
}

emit_provenance() {
  local provider="$1"
  local pub_root="$2"
  local ent_root="$3"
  local cmd_line="$4"

  local pub_commit ent_commit now
  pub_commit="$(_resolve_commit "$pub_root")"
  ent_commit="$(_resolve_commit "$ent_root")"
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  echo "# Retirement Sweep Inventory"
  echo ""
  echo "- Provider: ${provider}"
  echo "- Timestamp: ${now}"
  echo "- Public tree commit: ${pub_commit}"
  echo "- Enterprise tree commit: ${ent_commit}"
  echo "- Command: ${cmd_line}"
  echo ""
}

scan_root() {
  local root="$1"
  local label="$2"
  local provider="$3"

  echo "## ${label}"
  echo ""

  # Word-bounded, case-insensitive grep excluding .git.
  local hits
  hits="$(grep -rniIw "$provider" "$root" --exclude-dir=.git 2>/dev/null || true)"

  if [ -z "$hits" ]; then
    echo "No hits found."
    echo ""
    return 0
  fi

  local line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local relpath="${line#"$root"/}"
    local annotation
    annotation="$(annotate_hit "$relpath")"

    if [ -n "$annotation" ]; then
      echo "- ${relpath} ${annotation}"
    else
      echo "- ${relpath}"
    fi
  done <<< "$hits"

  echo ""
}

retirement_sweep_main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --provider)          _PROVIDER="$2";         shift 2 ;;
      --public-root)       _PUBLIC_ROOT="$2";      shift 2 ;;
      --enterprise-root)   _ENTERPRISE_ROOT="$2";  shift 2 ;;
      --carve-out-file)    _CARVEOUT_FILE="$2";    shift 2 ;;
      --exclusion-file)    _EXCLUSION_FILE="$2";   shift 2 ;;
      --unowned-glob)      _UNOWNED_GLOB="$2";     shift 2 ;;
      --label-expected)    _LABEL_EXPECTED=1;       shift   ;;
      --output)            _OUTPUT="$2";           shift 2 ;;
      *) printf 'Error: unknown flag: %s\n' "$1" >&2; return 2 ;;
    esac
  done

  [ -n "$_PROVIDER" ]        || { printf 'Error: --provider is required\n' >&2; return 2; }
  [ -n "$_PUBLIC_ROOT" ]     || { printf 'Error: --public-root is required\n' >&2; return 2; }
  [ -n "$_ENTERPRISE_ROOT" ] || { printf 'Error: --enterprise-root is required\n' >&2; return 2; }

  # Absent root checks -- print to stdout so bats $output captures it.
  if [ ! -d "$_PUBLIC_ROOT" ]; then
    echo "ABSENT: ${_PUBLIC_ROOT} -- public tree not present"
    return 1
  fi
  if [ ! -d "$_ENTERPRISE_ROOT" ]; then
    echo "ABSENT: ${_ENTERPRISE_ROOT} -- enterprise tree not present"
    return 1
  fi

  # Load annotation lists.
  [ -n "$_CARVEOUT_FILE" ]  && _load_path_reason_list "$_CARVEOUT_FILE" _CO_PATHS _CO_REASONS
  [ -n "$_EXCLUSION_FILE" ] && load_exclusion_list "$_EXCLUSION_FILE"

  # Reconstruct the full command line for provenance -- a reader must be
  # able to re-run the exact invocation from the recorded line.
  local cmd_line="retirement-sweep.sh --provider ${_PROVIDER} --public-root ${_PUBLIC_ROOT} --enterprise-root ${_ENTERPRISE_ROOT}"
  [ -n "$_CARVEOUT_FILE" ]     && cmd_line="${cmd_line} --carve-out-file ${_CARVEOUT_FILE}"
  [ -n "$_EXCLUSION_FILE" ]    && cmd_line="${cmd_line} --exclusion-file ${_EXCLUSION_FILE}"
  [ "$_LABEL_EXPECTED" -eq 1 ] && cmd_line="${cmd_line} --label-expected"
  [ -n "$_OUTPUT" ]            && cmd_line="${cmd_line} --output ${_OUTPUT}"

  _emit_all() {
    emit_provenance "$_PROVIDER" "$_PUBLIC_ROOT" "$_ENTERPRISE_ROOT" "$cmd_line"
    scan_root "$_PUBLIC_ROOT" "Public tree" "$_PROVIDER"
    scan_root "$_ENTERPRISE_ROOT" "Enterprise tree" "$_PROVIDER"
    echo "---"
    echo "- Status: complete"
    echo "- Warnings: 0"
  }

  if [ -n "$_OUTPUT" ]; then
    mkdir -p "$(dirname "$_OUTPUT")"
    _emit_all > "$_OUTPUT"
  else
    _emit_all
  fi
}

# ---------- Entry point (skip when sourced) -----------------------------

if [ "$_RETIREMENT_SWEEP_SOURCED" -eq 0 ]; then
  retirement_sweep_main "$@"
fi
