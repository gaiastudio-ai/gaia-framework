#!/usr/bin/env bash
# shellcheck disable=SC2329  # Functions are invoked via dynamic dispatch (_rule_*)
set -euo pipefail
LC_ALL=C; export LC_ALL

# lint-pack.sh — deterministic lint runner for known mechanical bug types.
#
# Scans a list of files (or a git diff range) against a registry of regex/awk
# rules. Each rule has a must-fire fixture and a must-not-fire fixture in the
# companion bats suite. No LLM calls; identical input always produces
# byte-identical output.
#
# Usage:
#   lint-pack.sh [--files <file>...] [--diff <range>] [--config <yaml>]
#                [--report <path>] [--exclude <rule-id>] [--workdir <dir>]
#
# Exit codes:
#   0 — no findings, or nothing to scan (report written with empty findings array)
#   1 — findings exist (report written with findings)
#   2 — usage error, configuration error, or file error (fail closed)

SCRIPT_NAME="$(basename "$0")"

# ---- Helpers ---------------------------------------------------------------

_usage() {
  cat >&2 <<EOF
${SCRIPT_NAME}: deterministic lint pack for known bug types

Usage:
  ${SCRIPT_NAME} [--files <file>...] [--diff <range>] [--config <yaml>]
                 [--report <path>] [--exclude <rule-id>] [--workdir <dir>]

Options:
  --files <f>...     Files to scan (terminates at next --)
  --diff <range>     Git diff range (e.g. origin/staging...HEAD)
  --config <yaml>    YAML config for the leaked-identifier rule
  --report <path>    JSON report output path (default: temp file)
  --exclude <id>     Skip rule <id> (repeatable)
  --workdir <dir>    Working directory (default: .)
  --rules-dir <dir>  Load rule.lint rules from <dir> (repeatable)

Exit codes:
  0  No findings, or nothing to scan
  1  Findings exist
  2  Usage error, configuration error, or file error
EOF
  exit 2
}

_die() { printf '%s: ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 2; }
_log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

# ---- Argument parsing ------------------------------------------------------

declare -a FILES=()
declare -a EXCLUDED_RULES=()
declare -a RULES_DIRS=()
DIFF_RANGE=""
CONFIG_PATH=""
REPORT_PATH=""
WORKDIR="."

while [ $# -gt 0 ]; do
  case "$1" in
    --files)
      shift
      while [ $# -gt 0 ] && [ "$1" != "--" ] && case "$1" in --*) false;; *) true;; esac; do
        FILES+=("$1"); shift
      done
      [ "${1:-}" = "--" ] && shift
      ;;
    --diff)       DIFF_RANGE="${2:-}"; [ -z "$DIFF_RANGE" ] && _die "--diff requires a range"; shift 2 ;;
    --config)     CONFIG_PATH="${2:-}"; [ -z "$CONFIG_PATH" ] && _die "--config requires a path"; shift 2 ;;
    --report)     REPORT_PATH="${2:-}"; [ -z "$REPORT_PATH" ] && _die "--report requires a path"; shift 2 ;;
    --exclude)    EXCLUDED_RULES+=("${2:-}"); [ -z "${2:-}" ] && _die "--exclude requires a rule id"; shift 2 ;;
    --workdir)    WORKDIR="${2:-}"; [ -z "$WORKDIR" ] && _die "--workdir requires a directory"; shift 2 ;;
    --rules-dir)  RULES_DIRS+=("${2:-}"); [ -z "${2:-}" ] && _die "--rules-dir requires a directory"; shift 2 ;;
    --help|-h) _usage ;;
    *) _die "unknown option: $1" ;;
  esac
done

cd "$WORKDIR" 2>/dev/null || _die "cannot cd to workdir: $WORKDIR"

# ---- Resolve file list -----------------------------------------------------

if [ -n "$DIFF_RANGE" ]; then
  # A range git cannot read is an error.  A valid range with no text changes
  # (empty, deletions only, binary only) is not: there is simply nothing to scan.
  # -c core.quotePath=false: emit raw filenames (no quoting for spaces/non-ASCII).
  _diff_names="$(git -c core.quotePath=false diff --name-only --diff-filter=ACMR "$DIFF_RANGE" 2>/dev/null)" \
    || _die "cannot read git range: ${DIFF_RANGE}"
  if [ ${#FILES[@]} -eq 0 ] && [ -n "$_diff_names" ]; then
    while IFS= read -r f; do
      [ -f "$f" ] && FILES+=("$f")
    done <<< "$_diff_names"
    # Changes exist but none can be read from here, for example from a
    # subdirectory of the repository: passing would hide them.
    if [ ${#FILES[@]} -eq 0 ]; then
      _die "no changed file of ${DIFF_RANGE} exists under the working directory"
    fi
  fi
elif [ ${#FILES[@]} -eq 0 ]; then
  _die "no files to scan (pass --files or --diff)"
fi

# ---- Diff-mode added-line tracking -----------------------------------------
# In --diff mode, findings are reported only for ADDED lines (per-file ranges
# from git diff -U0), not whole files.  --files mode scans whole files.  Two
# exceptions: a syntax error belongs to the file rather than to a line, and a
# file git treats as binary has no line data, so all of it counts as added.

_DIFF_ADDED_FILE=""
if [ -n "$DIFF_RANGE" ]; then
  _DIFF_ADDED_FILE="$(mktemp)" || _die "cannot create temp file for diff ranges"
  # Force b/ prefix (immune to diff.noprefix=true) and raw paths.
  # Parse "+++ b/<path>" for filenames (more robust than "diff --git" $4).
  # The output must not depend on color, external-diff or textconv settings:
  # those would hide added lines.
  git -c core.quotePath=false diff -U0 --no-color --no-ext-diff --no-textconv \
    --src-prefix=a/ --dst-prefix=b/ "$DIFF_RANGE" 2>/dev/null | awk '
    /^\+\+\+ b\// {
      file = substr($0, 7)  # Remove "+++ b/" prefix
      sub(/\t$/, "", file)  # git appends a tab to paths containing whitespace
    }
    /^@@/ {
      plus = substr($3, 2)  # Remove leading +
      n = split(plus, sc, ",")
      start = sc[1] + 0
      count = (n > 1) ? sc[2] + 0 : 1
      for (j = start; j < start + count; j++) {
        print file "\t" j
      }
    }
  ' > "$_DIFF_ADDED_FILE"
  # Binary entries read "-<TAB>-<TAB><path>", or for a rename "-<TAB>-<TAB>" then
  # the old and new paths as separate fields.  They are recorded as <path><TAB>*.
  git -c core.quotePath=false diff --numstat -z --no-color --no-ext-diff --no-textconv \
    "$DIFF_RANGE" 2>/dev/null | while IFS=$'\t' read -r -d '' _ns_added _ns_deleted _ns_path; do
    if [ -z "$_ns_path" ]; then
      IFS= read -r -d '' _ns_path
      IFS= read -r -d '' _ns_path
    fi
    if [ "$_ns_added" = "-" ]; then
      printf '%s\t*\n' "$_ns_path"
    fi
  done >> "$_DIFF_ADDED_FILE"
fi

# ---- File validation -------------------------------------------------------
# Validate each input file before scanning.  Missing, unreadable or non-regular
# files are errors that must not silence rules for the remaining files.  Binary
# files are skipped with a note.

_FILE_ERROR_COUNT=0
declare -a VALID_FILES=()

_escape_filename() {
  # Escape control characters for safe JSON/text output.
  printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

for _vf in "${FILES[@]+"${FILES[@]}"}"; do
  if [ ! -e "$_vf" ]; then
    _log "ERROR: file not found: $(_escape_filename "$_vf")"
    _FILE_ERROR_COUNT=$((_FILE_ERROR_COUNT + 1))
    continue
  fi
  if [ ! -f "$_vf" ]; then
    _log "ERROR: not a regular file: $(_escape_filename "$_vf")"
    _FILE_ERROR_COUNT=$((_FILE_ERROR_COUNT + 1))
    continue
  fi
  if [ ! -r "$_vf" ]; then
    _log "ERROR: file not readable: $(_escape_filename "$_vf")"
    _FILE_ERROR_COUNT=$((_FILE_ERROR_COUNT + 1))
    continue
  fi
  # Skip binary files (use file(1), not grep -P which is unavailable on macOS).
  # If file(1) is absent, assume text — it is a convenience filter, not a gate.
  _file_type=""
  _file_type="$(file -b "$_vf" 2>/dev/null)" || _file_type=""
  if [ -n "$_file_type" ]; then
    case "$_file_type" in
      *text*|*script*|*empty*|*ASCII*|*UTF-8*|*JSON*|*YAML*|*XML*|*HTML*|*csv*) ;;
      *) _log "NOTE: skipping binary file: $(_escape_filename "$_vf")"; continue ;;
    esac
  fi
  VALID_FILES+=("$_vf")
done

# Replace FILES with validated list; keep original count for the report.
_ORIGINAL_FILE_COUNT=${#FILES[@]}
FILES=("${VALID_FILES[@]+"${VALID_FILES[@]}"}")

if [ ${#FILES[@]} -eq 0 ] && [ "$_FILE_ERROR_COUNT" -gt 0 ]; then
  _die "no valid files to scan ($_FILE_ERROR_COUNT file error(s))"
fi
# Only binary files were given: nothing was scanned.
if [ ${#FILES[@]} -eq 0 ]; then
  _ORIGINAL_FILE_COUNT=0
fi

# ---- Report output path ---------------------------------------------------

if [ -z "$REPORT_PATH" ]; then
  _tmp_dir="$(mktemp -d)" || _die "cannot create temp dir for report"
  REPORT_PATH="${_tmp_dir}/lint-pack-report.json"
fi

# ---- Exclusion check -------------------------------------------------------

_is_excluded() {
  local rule_id="$1"
  local ex
  for ex in "${EXCLUDED_RULES[@]+"${EXCLUDED_RULES[@]}"}"; do
    [ "$ex" = "$rule_id" ] && return 0
  done
  return 1
}

# ---- Per-line suppression marker -------------------------------------------
# lint-pack:allow <rule-id> on any line suppresses that rule for that line.

_is_suppressed() {
  local rule_id="$1" line_text="$2"
  case "$line_text" in
    *"lint-pack:allow ${rule_id}"*) return 0 ;;
  esac
  return 1
}

# ---- Load leaked-identifier config -----------------------------------------
# Parsed with yq (a real YAML parser) because identifier regexes can contain
# ], commas, and other characters that break naive inline-list splitting.
#
# When --config is given, it MUST be readable and parseable (fail closed).
# When --config is absent but the project config has the lint_pack key,
# the same fail-closed behaviour applies: if the key exists but the file is
# unreadable, malformed, or yq is absent, the pack halts.  Only when the
# key is entirely absent is the rule silently skipped.

declare -a LEAK_PATTERNS=()
declare -a LEAK_PUBLISHED_PATHS=()
LEAK_RULE_CONFIGURED=false

_load_leak_config() {
  local cfg="$1"
  local explicit="$2"  # "true" when user passed --config, "auto-key" when key was found in project config, "false" for auto-discovered without key

  if [ ! -f "$cfg" ]; then
    if [ "$explicit" = "true" ]; then
      _die "--config file not found: ${cfg}"
    fi
    if [ "$explicit" = "auto-key" ]; then
      _die "project config not readable: ${cfg} (lint_pack key is present — remove the key or fix the file)"
    fi
    return 0
  fi

  if [ ! -r "$cfg" ]; then
    if [ "$explicit" = "true" ]; then
      _die "--config file not readable: ${cfg}"
    fi
    if [ "$explicit" = "auto-key" ]; then
      _die "project config not readable: ${cfg} (lint_pack key is present)"
    fi
    return 0
  fi

  if ! command -v yq >/dev/null 2>&1; then
    if [ "$explicit" = "true" ] || [ "$explicit" = "auto-key" ]; then
      _die "yq is required to parse config but not found on PATH"
    fi
    _log "WARN: yq not found; leaked-identifier rule skipped (cannot parse config)"
    return 0
  fi

  # Validate the YAML is parseable (fail closed when config is explicit or key-present).
  local yq_err=""
  if ! yq_err="$(yq '.' "$cfg" 2>&1 >/dev/null)"; then
    if [ "$explicit" = "true" ]; then
      _die "--config file is not valid YAML: ${cfg}: ${yq_err}"
    fi
    if [ "$explicit" = "auto-key" ]; then
      _die "project config is not valid YAML: ${cfg}: ${yq_err}"
    fi
    _log "WARN: config is not valid YAML: ${cfg}; leaked-identifier rule skipped"
    return 0
  fi

  # Read patterns using yq -r (raw output, no JSON quoting — preserves backslashes).
  local pat_count
  pat_count="$(yq '.lint_pack.leaked_identifiers.patterns // [] | length' "$cfg" 2>/dev/null)" || pat_count=0
  if [ "$pat_count" -gt 0 ]; then
    local i=0
    while [ "$i" -lt "$pat_count" ]; do
      local p
      p="$(yq -r ".lint_pack.leaked_identifiers.patterns[$i]" "$cfg" 2>/dev/null)" || p=""  # lint-pack:allow spliced-yq-jq
      if [ -n "$p" ]; then
        # Validate the pattern is a legal extended regex (fail closed on bad regex).
        local grep_rc=0
        printf '' | grep -E -e "$p" >/dev/null 2>&1 || grep_rc=$?
        if [ "$grep_rc" -eq 2 ]; then
          _die "invalid regex in config pattern[$i]: ${p}"
        fi
        LEAK_PATTERNS+=("$p")
      fi
      i=$((i + 1))
    done
  fi

  local pub_count
  pub_count="$(yq '.lint_pack.leaked_identifiers.published_paths // [] | length' "$cfg" 2>/dev/null)" || pub_count=0
  if [ "$pub_count" -gt 0 ]; then
    local i=0
    while [ "$i" -lt "$pub_count" ]; do
      local p
      p="$(yq -r ".lint_pack.leaked_identifiers.published_paths[$i]" "$cfg" 2>/dev/null)" || p=""  # lint-pack:allow spliced-yq-jq
      [ -n "$p" ] && LEAK_PUBLISHED_PATHS+=("$p")
      i=$((i + 1))
    done
  fi

  if [ ${#LEAK_PATTERNS[@]} -gt 0 ] && [ ${#LEAK_PUBLISHED_PATHS[@]} -gt 0 ]; then
    LEAK_RULE_CONFIGURED=true
  fi
}

# Auto-discover project config when --config is not given.
_discover_project_config() {
  if [ -n "${PROJECT_CONFIG:-}" ] && [ -f "${PROJECT_CONFIG:-}" ]; then
    printf '%s\n' "$PROJECT_CONFIG"
    return 0
  fi
  if [ -n "${CLAUDE_PROJECT_ROOT:-}" ]; then
    if [ -f "${CLAUDE_PROJECT_ROOT}/.gaia/config/project-config.yaml" ]; then
      printf '%s\n' "${CLAUDE_PROJECT_ROOT}/.gaia/config/project-config.yaml"
      return 0
    fi
  fi
  local dir depth=0
  dir="$(pwd -P 2>/dev/null || pwd)"
  while [ -n "$dir" ] && [ "$depth" -lt 8 ]; do
    if [ -f "${dir}/.gaia/config/project-config.yaml" ]; then
      printf '%s\n' "${dir}/.gaia/config/project-config.yaml"
      return 0
    fi
    [ "$dir" = "/" ] && break
    dir="$(dirname "$dir")"
    depth=$((depth + 1))
  done
  return 0
}

if [ -n "$CONFIG_PATH" ]; then
  _load_leak_config "$CONFIG_PATH" "true"
else
  # Try project config (auto-discovery).
  _auto_cfg=""
  _auto_cfg="$(_discover_project_config)" || true
  if [ -n "$_auto_cfg" ]; then
    # Check if the lint_pack key is present.  When the key exists, fail closed
    # on read/parse errors (the user configured the rule but the config is
    # broken).  When the key is absent, silently skip the rule.
    #
    # Strategy: try yq first; if yq fails (absent or YAML broken), fall back to
    # a simple grep for "lint_pack" — if the text appears, the user intended to
    # configure it and the config is broken, so fail closed.
    _auto_key_present=false
    if [ ! -r "$_auto_cfg" ]; then
      # Unreadable: we cannot determine if lint_pack is configured.
      # Fail closed — the project has a config file but we cannot read it.
      _die "project config not readable: ${_auto_cfg} (cannot determine lint_pack state — fix file permissions)"
    elif ! command -v yq >/dev/null 2>&1; then
      # yq absent: grep for the key hint; fail closed if present.
      if grep -q 'lint_pack' "$_auto_cfg" 2>/dev/null; then
        _die "yq is required to parse project config lint_pack settings but not found on PATH"
      fi
    else
      # yq available: try to parse.
      local_key_type=""
      local_key_type="$(yq '.lint_pack.leaked_identifiers | type' "$_auto_cfg" 2>/dev/null)" || local_key_type=""
      if [ -n "$local_key_type" ] && [ "$local_key_type" != "!!null" ]; then
        _auto_key_present=true
      elif [ -z "$local_key_type" ]; then
        # yq returned empty — likely a parse error.  Check if the key text
        # exists in the file (rough heuristic); fail closed if so.
        if grep -q 'lint_pack' "$_auto_cfg" 2>/dev/null; then
          # Verify it's actually a parse error, not just a missing key.
          if ! yq '.' "$_auto_cfg" >/dev/null 2>&1; then
            _die "project config is not valid YAML: ${_auto_cfg} (lint_pack key appears present)"
          fi
        fi
      fi
    fi
    if [ "$_auto_key_present" = "true" ]; then
      _load_leak_config "$_auto_cfg" "auto-key"
    fi
  fi
fi

# ---- Findings accumulator --------------------------------------------------

# Findings stored as tab-separated lines for deterministic sorting.
# Format: rule\tfile\tline\tmessage\tfix_hint
_FINDINGS_FILE=""
FINDING_COUNT=0

_init_findings() {
  _FINDINGS_FILE="$(mktemp)" || _die "cannot create temp findings file"
}
_init_findings

# Clean up temp files on exit.
trap 'rm -f "$_FINDINGS_FILE" "${_DIFF_ADDED_FILE:-}"' EXIT

_add_finding() {
  local rule="$1" file="$2" line="$3" message="$4" fix_hint="$5"
  FINDING_COUNT=$((FINDING_COUNT + 1))
  printf '%s\t%s\t%s\t%s\t%s\n' "$rule" "$file" "$line" "$message" "$fix_hint" >> "$_FINDINGS_FILE"
}

# ---- Diff-mode batch filter -------------------------------------------------
# In diff mode, instead of checking each finding against the added-lines list
# one at a time (which is O(findings * added-lines)), we apply the filter as a
# single pass AFTER all rules have run. This replaces the per-finding grep
# with a single awk join, keeping the 500-file case under 30 seconds.

_filter_findings_for_diff() {
  if [ -z "${_DIFF_ADDED_FILE:-}" ]; then
    return 0
  fi
  if [ ! -s "$_FINDINGS_FILE" ]; then
    return 0
  fi
  local filtered
  filtered="$(mktemp)" || _die "cannot create temp file for filtered findings"
  # awk join: load added-lines into a set, then emit only findings whose
  # file+line is in the set, plus the two exceptions noted above.  The first
  # file is told apart by name because it is empty on a deletion-only change.
  awk -F'\t' '
    FILENAME == ARGV[1] { added[$1 "\t" $2] = 1; next }
    $1 == "bash-syntax" || (($2 "\t*") in added) || (($2 "\t" $3) in added)
  ' "$_DIFF_ADDED_FILE" "$_FINDINGS_FILE" > "$filtered"
  # Replace findings file with filtered version and recount.
  mv "$filtered" "$_FINDINGS_FILE"
  FINDING_COUNT=0
  if [ -s "$_FINDINGS_FILE" ]; then
    FINDING_COUNT="$(wc -l < "$_FINDINGS_FILE" | tr -d ' ')"
  fi
}

# ---- Context-aware carve-out for matching-logic literals -------------------
# Returns 0 (true = skip this match) when the identifier-shaped match appears
# inside the PATTERN ARGUMENT of a regex command, not just anywhere on the
# same line.  Content AFTER the pattern argument is NOT carved out: a leak
# there is still flagged.
#
# Performance: uses bash string operations (case/parameter expansion) to avoid
# subprocess spawns on hot paths — the function is called once per matched
# identifier across all published files.

_is_matching_logic() {
  local line_text="$1"
  local match_text="$2"  # The specific identifier that matched

  # 1. grep with -E / -P flags (any position: if grep, while grep, ! grep, piped, etc.)
  #    Carve out only the pattern argument, not content after it.
  case "$line_text" in
    *grep*-*[EP]* | *grep*--extended* | *grep*--perl* | *egrep\ *)
      # Extract text after "grep" and its flags to find the pattern argument.
      local after_grep=""
      # Remove everything up to and including the grep command with its flags.
      # Handle: grep -E, grep -qE, grep -Eq, grep -E -o, egrep, grep --extended-regexp
      after_grep="$line_text"
      case "$after_grep" in
        *egrep\ *)
          after_grep="${after_grep#*egrep }"
          # Skip any remaining flags
          while :; do
            case "$after_grep" in
              -[a-zA-Z]*)
                after_grep="${after_grep#-[a-zA-Z]*}"
                after_grep="${after_grep# }"
                ;;
              *) break ;;
            esac
          done
          ;;
        *)
          # Remove up to grep and its flags
          after_grep="${after_grep#*grep }"
          # Skip all flag groups (e.g., -qE, -n, -E, -o, --extended-regexp, etc.)
          while :; do
            case "$after_grep" in
              -[a-zA-Z]*)
                after_grep="${after_grep#-}"
                # Consume the flag letters
                while :; do
                  case "$after_grep" in
                    [a-zA-Z]*) after_grep="${after_grep#?}" ;;
                    *) break ;;
                  esac
                done
                after_grep="${after_grep# }"
                ;;
              --*) # Long option like --extended-regexp
                after_grep="${after_grep#--}"
                after_grep="${after_grep#*[!a-zA-Z-]}"
                after_grep="${after_grep# }"
                ;;
              *) break ;;
            esac
          done
          ;;
      esac
      # Handle -e flag before the pattern
      case "$after_grep" in
        -e\ *) after_grep="${after_grep#-e }"; after_grep="${after_grep# }" ;;
        -e"'"*) after_grep="${after_grep#-e}" ;;
        -e'"'*) after_grep="${after_grep#-e}" ;;
      esac
      # Extract the pattern argument (first quoted or bare word)
      local pat_arg=""
      case "$after_grep" in
        "'"*) pat_arg="${after_grep#\'}"; pat_arg="${pat_arg%%\'*}" ;;
        '"'*) pat_arg="${after_grep#\"}"; pat_arg="${pat_arg%%\"*}" ;;
        *)    pat_arg="${after_grep%% *}" ;;
      esac
      # Carve out only if the match is in the pattern argument
      case "$pat_arg" in *"$match_text"*) return 0 ;; esac
      ;;
  esac

  # 2. [[ =~ ]]: carve out only the regex operand between =~ and ]].
  # Only trigger when [[ actually precedes =~ (not prose mentioning =~).
  case "$line_text" in
    *'[['*'=~'*)
      local after_tilde="${line_text#*=~}"
      # Limit to the content before ]]
      local carve_region="${after_tilde%%]]*}"
      case "$carve_region" in *"$match_text"*) return 0 ;; esac
      ;;
  esac

  # 3. sed / awk / gawk at command position: carve out only the FIRST quoted
  #    program argument, not surrounding prose or later arguments.
  local cmd
  for cmd in sed awk gawk; do
    case "$line_text" in
      *"${cmd} "*)
        # Check command position: at line start (after whitespace) or after a
        # shell operator — not just a word in prose.
        local before_cmd="${line_text%%"${cmd} "*}"
        local last_char=""
        if [ -n "$before_cmd" ]; then
          last_char="${before_cmd##*[! ]}"
          [ -z "$last_char" ] && last_char=" "
          last_char="${before_cmd: -1}"
        fi
        case "$last_char" in
          ""|" "|"	"|"|"|";"|"&"|"("|"!") ;;  # Command position
          *) continue ;;  # Prose — not a command invocation
        esac

        local after_cmd="${line_text#*"${cmd} "}"
        # Skip flags
        while :; do
          case "$after_cmd" in
            -[a-zA-Z]*) after_cmd="${after_cmd#-[a-zA-Z]*}"; after_cmd="${after_cmd# }" ;;
            *) break ;;
          esac
        done
        # Take only the FIRST quoted segment as the program.
        local prog_arg=""
        case "$after_cmd" in
          "'"*)
            prog_arg="${after_cmd#\'}"
            prog_arg="${prog_arg%%\'*}"
            ;;
          '"'*)
            prog_arg="${after_cmd#\"}"
            prog_arg="${prog_arg%%\"*}"
            ;;
        esac
        case "$prog_arg" in
          *"$match_text"*) return 0 ;;
        esac
        ;;
    esac
  done

  # 4. _PATTERN= / _REGEX= / _RE= / pattern= / regex= assignment:
  #    Carve out only when the keyword is at variable-assignment position
  #    (not inside a quoted string or an echo/printf argument) and the match
  #    is in the RHS VALUE.
  local kw
  for kw in "_PATTERN=" "_REGEX=" "_RE=" "pattern=" "regex="; do
    case "$line_text" in
      *"$kw"*)
        # Check that the keyword is at assignment position, not inside a string.
        local before_kw="${line_text%%"$kw"*}"
        case "$before_kw" in
          *echo*|*printf*|*'"'*"$kw") continue ;;  # Inside a print command or quotes
        esac
        local after_kw="${line_text#*"$kw"}"
        local rhs=""
        case "$after_kw" in
          '"'*) rhs="${after_kw#\"}"; rhs="${rhs%%\"*}" ;;
          "'"*) rhs="${after_kw#\'}"; rhs="${rhs%%\'*}" ;;
          *)    rhs="${after_kw%% *}" ;;
        esac
        case "$rhs" in *"$match_text"*) return 0 ;; esac
        ;;
    esac
  done

  return 1
}

# Count non-overlapping occurrences of a literal string.  Result in
# _LITERAL_COUNT.  This runs for every hit in the leak rule, so short text uses
# builtins only.  A shell pattern removal costs the square of the text length,
# so long text goes to one grep instead.
_LITERAL_BUILTIN_MAX=4096
_count_literal() {
  local hay="$1" needle="$2"
  _LITERAL_COUNT=0
  [ -n "$needle" ] || return 0
  if [ "${#hay}" -gt "$_LITERAL_BUILTIN_MAX" ]; then
    _LITERAL_COUNT="$(printf '%s\n' "$hay" | { grep -oF -e "$needle" || [ $? -eq 1 ]; } | wc -l | tr -d ' ')" \
      || _die "cannot count identifier occurrences on a long line"
    return 0
  fi
  while :; do
    case "$hay" in
      *"$needle"*) hay="${hay#*"$needle"}"; _LITERAL_COUNT=$((_LITERAL_COUNT + 1)) ;;
      *) return 0 ;;
    esac
  done
}

# Count how many times match_text appears in carve-out regions on a line.
# Uses the same extraction logic as _is_matching_logic but counts instead
# of returning early.  Result in _CARVED_COUNT (no subshell on the hot path).
_count_carved_occurrences() {
  local line_text="$1" match_text="$2"
  local count=0

  # grep pattern argument
  case "$line_text" in
    *grep*-*[EP]* | *grep*--extended* | *grep*--perl* | *egrep\ *)
      local after_grep="$line_text" pat_arg=""
      case "$after_grep" in
        *egrep\ *) after_grep="${after_grep#*egrep }"
          while :; do case "$after_grep" in -*) after_grep="${after_grep#-[a-zA-Z]*}"; after_grep="${after_grep# }" ;; *) break ;; esac; done ;;
        *) after_grep="${after_grep#*grep }"
          while :; do case "$after_grep" in -[a-zA-Z]*) after_grep="${after_grep#-}"; while :; do case "$after_grep" in [a-zA-Z]*) after_grep="${after_grep#?}" ;; *) break ;; esac; done; after_grep="${after_grep# }" ;; --*) after_grep="${after_grep#--}"; after_grep="${after_grep#*[!a-zA-Z-]}"; after_grep="${after_grep# }" ;; *) break ;; esac; done ;;
      esac
      case "$after_grep" in -e\ *) after_grep="${after_grep#-e }"; after_grep="${after_grep# }" ;; -e"'"*) after_grep="${after_grep#-e}" ;; -e'"'*) after_grep="${after_grep#-e}" ;; esac
      case "$after_grep" in
        "'"*) pat_arg="${after_grep#\'}"; pat_arg="${pat_arg%%\'*}" ;;
        '"'*) pat_arg="${after_grep#\"}"; pat_arg="${pat_arg%%\"*}" ;;
        *)    pat_arg="${after_grep%% *}" ;;
      esac
      if [ -n "$pat_arg" ]; then
        _count_literal "$pat_arg" "$match_text"
        count=$((count + _LITERAL_COUNT))
      fi
      ;;
  esac

  # [[ =~ ]] region
  case "$line_text" in
    *'[['*'=~'*)
      local carve_region="${line_text#*=~}"
      carve_region="${carve_region%%]]*}"
      if [ -n "$carve_region" ]; then
        _count_literal "$carve_region" "$match_text"
        count=$((count + _LITERAL_COUNT))
      fi
      ;;
  esac

  # sed/awk/gawk program argument
  local cmd
  for cmd in sed awk gawk; do
    case "$line_text" in
      *"${cmd} "*)
        local before_cmd="${line_text%%"${cmd} "*}"
        local last_char=""
        if [ -n "$before_cmd" ]; then last_char="${before_cmd: -1}"; fi
        case "$last_char" in ""|" "|"	"|"|"|";"|"&"|"("|"!") ;; *) continue ;; esac
        local after_cmd="${line_text#*"${cmd} "}"
        while :; do case "$after_cmd" in -[a-zA-Z]*) after_cmd="${after_cmd#-[a-zA-Z]*}"; after_cmd="${after_cmd# }" ;; *) break ;; esac; done
        local prog_arg=""
        case "$after_cmd" in "'"*) prog_arg="${after_cmd#\'}"; prog_arg="${prog_arg%%\'*}" ;; '"'*) prog_arg="${after_cmd#\"}"; prog_arg="${prog_arg%%\"*}" ;; esac
        if [ -n "$prog_arg" ]; then
          _count_literal "$prog_arg" "$match_text"
          count=$((count + _LITERAL_COUNT))
        fi
        ;;
    esac
  done

  # PATTERN=/REGEX= variable assignment RHS
  local kw
  for kw in "_PATTERN=" "_REGEX=" "_RE=" "pattern=" "regex="; do
    case "$line_text" in
      *"$kw"*)
        local before_kw="${line_text%%"$kw"*}"
        case "$before_kw" in *echo*|*printf*|*'"'*"$kw") continue ;; esac
        local after_kw="${line_text#*"$kw"}"
        local rhs=""
        case "$after_kw" in '"'*) rhs="${after_kw#\"}"; rhs="${rhs%%\"*}" ;; "'"*) rhs="${after_kw#\'}"; rhs="${rhs%%\'*}" ;; *) rhs="${after_kw%% *}" ;; esac
        if [ -n "$rhs" ]; then
          _count_literal "$rhs" "$match_text"
          count=$((count + _LITERAL_COUNT))
        fi
        ;;
    esac
  done

  _CARVED_COUNT="$count"
}

# ---- Located grep hits -----------------------------------------------------
# A colon is legal in a file name, so grep's usual file:line:text cannot be split
# reliably.  grep --null ends the name with a zero byte, which a shell variable
# cannot hold, so it becomes a unit separator: <file><US><line>:<text>.

_HIT_SEP=$'\037'

_grep_hits() {
  grep -Hn --null "$@" | tr '\000' "$_HIT_SEP"
}

# Split one located hit into HIT_FILE, HIT_LINE and HIT_TEXT.
_split_hit() {
  local rest="${1#*"$_HIT_SEP"}"
  HIT_FILE="${1%%"$_HIT_SEP"*}"
  HIT_LINE="${rest%%:*}"
  HIT_TEXT="${rest#*:}"
}

# ---- Rule: leaked-identifiers (cross-stack, configurable) ------------------
# Batched: one grep per pattern across ALL published files at once.
# Checks every identifier on a line (not only the first).

_rule_leaked_identifiers() {
  if _is_excluded "leaked-identifiers"; then return 0; fi
  if [ "$LEAK_RULE_CONFIGURED" != "true" ]; then
    _log "leaked-identifiers: skipped (not configured)"
    return 0
  fi

  # Build the list of published files.
  declare -a pub_files=()
  local file
  for file in "${FILES[@]}"; do
    local is_published=false
    local pp
    for pp in "${LEAK_PUBLISHED_PATHS[@]}"; do
      case "$file" in
        "${pp}"*|*"/${pp}"*) is_published=true; break ;;
      esac
    done
    [ "$is_published" = "true" ] && pub_files+=("$file")
  done

  [ ${#pub_files[@]} -eq 0 ] && return 0

  local pat
  for pat in "${LEAK_PATTERNS[@]}"; do
    # Batch grep: one grep across all published files.
    local grep_out grep_rc=0
    grep_out="$(_grep_hits -E -e "$pat" "${pub_files[@]}" 2>/dev/null)" || grep_rc=$?
    if [ "$grep_rc" -eq 2 ]; then
      _log "ERROR: grep error scanning for pattern: ${pat}"
      _FILE_ERROR_COUNT=$((_FILE_ERROR_COUNT + 1))
      continue
    fi
    [ -z "$grep_out" ] && continue

    # Extract every identifier on every hit with ONE grep: feed it the hit
    # texts, so its line numbers index the hits, whatever the file names are.
    local hit_ids=() id_line id_idx
    while IFS= read -r id_line; do
      [ -n "$id_line" ] || continue
      id_idx="${id_line%%:*}"
      hit_ids[id_idx]="${hit_ids[id_idx]:-}${id_line#*:}"$'\n'
    done < <(
      while IFS= read -r match_line; do
        _split_hit "$match_line"
        printf '%s\n' "$HIT_TEXT"
      done <<< "$grep_out" | { grep -noE -e "$pat" 2>/dev/null || true; }
    )

    local hit_idx=0
    while IFS= read -r match_line; do
      hit_idx=$((hit_idx + 1))
      local line_text
      _split_hit "$match_line"
      line_text="$HIT_TEXT"

      # Suppression marker
      if _is_suppressed "leaked-identifiers" "$line_text"; then
        continue
      fi

      # Extract ALL matches on this line and count occurrences per
      # unique identifier.  Then count how many of each appear in
      # matching-logic carve-out regions.  If total > carved, flag.
      local all_matches reported=false
      all_matches="${hit_ids[hit_idx]:-}"
      [ -z "$all_matches" ] && continue

      # Collect unique identifiers from all matches.
      local seen_ids=""
      while IFS= read -r matched_id; do
        [ -z "$matched_id" ] && continue
        # Skip if already processed this identifier on this line.
        case "$seen_ids" in *"|${matched_id}|"*) continue ;; esac
        seen_ids="${seen_ids}|${matched_id}|"

        # Count total occurrences of this identifier on the line.
        local total_count carved_count
        _count_literal "$line_text" "$matched_id"
        total_count="$_LITERAL_COUNT"
        carved_count=0

        # Count how many are in carve-out regions.
        if _is_matching_logic "$line_text" "$matched_id"; then
          # _is_matching_logic found the identifier in at least one
          # carve-out region.  Count occurrences in that region.
          _count_carved_occurrences "$line_text" "$matched_id"
          carved_count="$_CARVED_COUNT"
        fi

        if [ "$total_count" -gt "$carved_count" ] && [ "$reported" = "false" ]; then
          _add_finding "leaked-identifiers" "$HIT_FILE" "$HIT_LINE" \
            "internal identifier matches pattern ${pat}" \
            "remove the identifier from published source; describe in plain product language"
          reported=true
        fi
      done <<< "$all_matches"
    done <<< "$grep_out"
  done
}

# ---- Rule: spliced-yq-jq (cross-stack) ------------------------------------
# Detects shell variables SPLICED INTO the jq/yq program/expression string.
# Safe forms (file argument, stdin pipe, strenv(), --arg, escaped \$, single-
# quoted programs) are NOT flagged.
#
# Uses a proper quoting state machine: single-quote, double-quote, $(...) nesting.
# Quote-break splices (e.g. '.a = "'"$X"'"') are detected by tracking adjacent
# quoted regions.  All grep output is piped through ONE awk for performance.

_rule_spliced_yq_jq() {
  if _is_excluded "spliced-yq-jq"; then return 0; fi

  # Batch grep: find all lines with yq/jq invocations across all files.
  local grep_out grep_rc=0
  grep_out="$(_grep_hits -E '(^|[[:space:];|&(])(yq|jq)\s' "${FILES[@]}" 2>/dev/null)" || grep_rc=$?
  if [ "$grep_rc" -eq 2 ]; then
    _log "ERROR: grep error scanning for yq/jq invocations"
    _FILE_ERROR_COUNT=$((_FILE_ERROR_COUNT + 1))
    return 0
  fi
  [ -z "$grep_out" ] && return 0

  # A program can sit on a backslash-continued line of a yq/jq command, where
  # the grep above cannot see it.  Add those lines to the scan.  Files with no
  # continued yq/jq line are never re-read.  The chain stops at a pipeline or
  # list operator: what follows it belongs to another command.
  local cont_files=() cont_file
  while IFS= read -r cont_file; do
    [ -n "$cont_file" ] && cont_files+=("$cont_file")
  done < <(grep -lE '(^|[[:space:];|&(])(yq|jq)\s.*\\$' "${FILES[@]}" 2>/dev/null || true)
  if [ ${#cont_files[@]} -gt 0 ]; then
    local cont_lines
    cont_lines="$(_grep_hits '' "${cont_files[@]}" 2>/dev/null | awk -v sep="$_HIT_SEP" '
      {
        name_end = index($0, sep)
        file = substr($0, 1, name_end - 1)
        rest = substr($0, name_end + 1)
        src = substr(rest, index(rest, ":") + 1)
        if (file != prev_file) { following = 0; prev_file = file }
        is_tool = (src ~ /(^|[ \t;|&(])(yq|jq)[ \t]/)
        if (src ~ /^[ \t]*[|&;]/) following = 0
        if (following && !is_tool) print
        following = (following || is_tool) && src ~ /(^|[^\\])(\\\\)*\\$/ && src !~ /[|&;][ \t]*\\$/
      }
    ')" || true
    [ -n "$cont_lines" ] && grep_out="${grep_out}"$'\n'"${cont_lines}"
  fi

  # Batch awk: process all lines through one awk invocation.
  # Output lines that have a splice (pass-through); suppress clean lines.
  #
  # State machine tracks: single-quote, double-quote, $(...) nesting.
  # For each DQ segment, accumulates operator and variable flags across the
  # whole segment (not just from the $ position).  Adjacent SQ segments
  # contribute operators for quote-break detection.
  #
  # shellcheck disable=SC2016 # Intentional: matching literal $ in source
  local splice_lines
  splice_lines="$(printf '%s\n' "$grep_out" | awk -v sq="'" -v sep="$_HIT_SEP" '
    function is_tool_word(s, p) {
      if (substr(s, p + 1, 1) != "q") return 0
      if (substr(s, p, 1) != "j" && substr(s, p, 1) != "y") return 0
      if (p > 1 && substr(s, p - 1, 1) !~ /[ \t;|&(]/) return 0
      return substr(s, p + 2, 1) ~ /[ \t]/
    }
    # True when the quote at position p opens the value of a named jq argument.
    function is_arg_value(s, p) {
      return substr(s, 1, p - 1) ~ /--(arg|argjson|slurpfile|rawfile)[ \t]+[^ \t]+[ \t]+$/
    }
    {
      line = $0
      # Strip the file and line prefix to get the source text
      rest = substr(line, index(line, sep) + 1)
      colon2 = index(rest, ":")
      src = substr(rest, colon2 + 1)

      n = length(src)
      i = 1
      in_sq = 0
      in_dq = 0
      found = 0

      # Track operator presence in adjacent single-quoted segments
      sq_ops = 0
      prev_was_quote = 0

      # Per-DQ-segment accumulators (reset on entering/exiting DQ)
      dq_has_var = 0
      dq_has_struct = 0
      dq_has_path = 0
      dq_has_dot_alpha = 0  # deferred: .field only counts if no /
      dq_has_cmdsub = 0     # $(...) found inside DQ segment
      # yq/jq word seen in the current pipeline stage.  A line without the word
      # only gets here as a continuation of a yq/jq command.
      is_cont = (src !~ /(^|[ \t;|&(])(yq|jq)[ \t]/)
      tool_seen = is_cont

      while (i <= n && !found) {
        c = substr(src, i, 1)

        if (in_sq) {
          if (c == sq) {
            in_sq = 0
            prev_was_quote = 1
          } else {
            if (c == "." || c == "[" || c == "|" || c == "=") sq_ops = 1
          }
          i++
          continue
        }

        if (in_dq) {
          if (c == "\\" && i < n) {
            nc = substr(src, i + 1, 1)
            if (nc == "$") {
              # \$ — not a variable reference; skip both chars
              i += 2
              continue
            }
            i += 2
            continue
          }
          if (c == "$" && i < n) {
            nc = substr(src, i + 1, 1)
            if (nc == "(") {
              # $(...) subcommand — scan with inner quoting state.
              # Inside $(), quoting resets, so each inner DQ segment is judged
              # on its own, and only when it is an argument of yq/jq: a
              # file path or another command argument in there is no program.
              dq_has_cmdsub = 1
              dp = 1; i += 2
              inner_sq = 0; inner_dq = 0; inner_tool = 0
              while (i <= n && dp > 0) {
                sc = substr(src, i, 1)
                if (inner_sq) {
                  if (sc == sq) inner_sq = 0
                  i++; continue
                }
                if (inner_dq) {
                  if (sc == "\\" && i < n) { i += 2; continue }
                  if (sc == "\"") {
                    inner_dq = 0; i++
                    if (in_dot && !in_path) in_struct = 1
                    if (inner_tool && in_var && in_struct && !in_arg_value) found = 1
                    continue
                  }
                  if (sc == "$" && i < n && substr(src, i + 1, 1) ~ /[A-Za-z_{(]/) in_var = 1
                  if (sc == "[" || sc == "]" || sc == "|") in_struct = 1
                  if (sc == "." && i < n && substr(src, i + 1, 1) ~ /[a-zA-Z_$[]/) in_dot = 1
                  if (sc == "=" && i < n && substr(src, i + 1, 1) == " ") in_struct = 1
                  # A lone slash is a path; a double slash is the alternative operator.
                  if (sc == "/" && substr(src, i + 1, 1) != "/" && substr(src, i - 1, 1) != "/") in_path = 1
                  if (substr(src, i, 7) == "select(" || substr(src, i, 6) == "length" || substr(src, i, 4) == "keys") in_struct = 1
                  i++; continue
                }
                if (sc == "(") dp++
                else if (sc == ")") dp--
                else if (sc == sq) inner_sq = 1
                else if (sc == "\"") { inner_dq = 1; in_var = 0; in_struct = 0; in_dot = 0; in_path = 0; in_arg_value = is_arg_value(src, i) }
                else if (sc == "|" || sc == ";" || sc == "&" || sc == ">" || sc == "<") inner_tool = 0
                else if (is_tool_word(src, i)) inner_tool = 1
                i++
              }
              continue
            }
            if (nc ~ /[A-Za-z_{]/) {
              dq_has_var = 1
            }
          }
          if (c == "\"") {
            # End of DQ segment — resolve deferred flags and analyze
            in_dq = 0
            # .field only counts as structural if the segment has no /
            if (dq_has_dot_alpha && !dq_has_path) dq_has_struct = 1
            if (!dq_arg_value && (dq_has_var || (dq_has_cmdsub && dq_tool))) {
              is_path_only = (dq_has_path && !dq_has_struct)
              if ((dq_has_struct || (prev_was_quote && sq_ops)) && !is_path_only) {
                found = 1
              }
            }
            prev_was_quote = 1
            dq_has_var = 0; dq_has_struct = 0; dq_has_path = 0; dq_has_dot_alpha = 0; dq_has_cmdsub = 0
            i++
            continue
          }
          # Accumulate flags for the current DQ segment
          if (c == "[" || c == "]") dq_has_struct = 1
          if (c == "|") dq_has_struct = 1
          if (c == "." && i < n) {
            nc2 = substr(src, i + 1, 1)
            if (nc2 ~ /[a-zA-Z_$[]/) dq_has_dot_alpha = 1
          }
          if (c == "=" && i < n && substr(src, i + 1, 1) == " ") dq_has_struct = 1
          if (c == "/" ) dq_has_path = 1
          if (c == "s" && i + 6 <= n && substr(src, i, 7) == "select(") dq_has_struct = 1
          if (c == "l" && i + 5 <= n && substr(src, i, 6) == "length") dq_has_struct = 1
          if (c == "k" && i + 3 <= n && substr(src, i, 4) == "keys") dq_has_struct = 1
          i++
          continue
        }

        # Normal state
        # On a continuation line, anything after an operator or redirection
        # is no longer an argument of the yq/jq command.
        if (is_cont && (c == "|" || c == ";" || c == "&" || c == ">" || c == "<")) break
        if (c == sq) {
          in_sq = 1
          if (!prev_was_quote) sq_ops = 0
          i++
          continue
        }
        if (c == "\"") {
          in_dq = 1
          if (!prev_was_quote) sq_ops = 0
          dq_has_var = 0; dq_has_struct = 0; dq_has_path = 0; dq_has_dot_alpha = 0; dq_has_cmdsub = 0
          dq_tool = tool_seen
          dq_arg_value = (is_cont && is_arg_value(src, i))
          i++
          continue
        }
        # Any non-quote character (including whitespace) breaks adjacency.
        # Quote-break splices have IMMEDIATELY adjacent segments (no space).
        prev_was_quote = 0
        sq_ops = 0
        if (c == "|" || c == ";" || c == "&") tool_seen = 0
        else if (is_tool_word(src, i)) tool_seen = 1
        i++
      }

      if (found) print line
    }
  ')" || true

  # Process awk-detected splices.
  if [ -n "$splice_lines" ]; then
  while IFS= read -r match_line; do
    _split_hit "$match_line"

    # Suppression marker
    if _is_suppressed "spliced-yq-jq" "$HIT_TEXT"; then
      continue
    fi

    _add_finding "spliced-yq-jq" "$HIT_FILE" "$HIT_LINE" \
      "shell variable spliced into yq/jq program string" \
      "use strenv() for yq or --arg/--argjson for jq instead of splicing"
  done <<< "$splice_lines"
  fi
}

# ---- Rule: hardcoded-credentials (cross-stack) -----------------------------

_rule_hardcoded_credentials() {
  if _is_excluded "hardcoded-credentials"; then return 0; fi

  # Filter to non-binary files.
  declare -a text_files=()
  local file
  for file in "${FILES[@]}"; do
    case "$file" in
      *.png|*.jpg|*.gif|*.ico|*.woff|*.woff2|*.ttf|*.eot|*.zip|*.tar|*.gz) continue ;;
    esac
    [ -f "$file" ] && text_files+=("$file")
  done
  [ ${#text_files[@]} -eq 0 ] && return 0

  # Batch grep across all text files.
  local grep_out grep_rc=0
  grep_out="$(_grep_hits -iE '(password|secret|api_key|apikey|token|access_key)\s*=\s*["'"'"'][A-Za-z0-9+/=_-]{16,}' "${text_files[@]}" 2>/dev/null)" || grep_rc=$?
  if [ "$grep_rc" -eq 2 ]; then
    _log "ERROR: grep error scanning for credentials"
    _FILE_ERROR_COUNT=$((_FILE_ERROR_COUNT + 1))
    return 0
  fi
  [ -z "$grep_out" ] && return 0

  while IFS= read -r match_line; do
    _split_hit "$match_line"
    # Carve-out: env var references and known placeholders
    # shellcheck disable=SC2016 # Intentional: matching literal $ in source
    case "$HIT_TEXT" in
      *'${'*|*'$(('*) continue ;;
      *example*|*placeholder*|*changeme*|*CHANGE_ME*|*xxxx*|*TODO*|*fixture*) continue ;;
    esac
    # Suppression marker
    if _is_suppressed "hardcoded-credentials" "$HIT_TEXT"; then
      continue
    fi
    _add_finding "hardcoded-credentials" "$HIT_FILE" "$HIT_LINE" \
      "possible hardcoded credential" \
      "move the value to an environment variable or secrets manager"
  done <<< "$grep_out"
}

# ---- Shell file detection --------------------------------------------------

_is_shell_file() {
  local file="$1"
  case "$file" in
    *.sh|*.bash|*.bats) return 0 ;;
  esac
  if [ -f "$file" ] && head -1 "$file" 2>/dev/null | grep -qE '^#!.*\bbash\b' 2>/dev/null; then
    return 0
  fi
  return 1
}

# ---- Collect shell files once (used by all bash rules) --------------------

declare -a SHELL_FILES=()
declare -a NON_BATS_SHELL_FILES=()

_collect_shell_files() {
  local file
  for file in "${FILES[@]+"${FILES[@]}"}"; do
    if _is_shell_file "$file"; then
      SHELL_FILES+=("$file")
      case "$file" in
        *.bats) ;;
        *) NON_BATS_SHELL_FILES+=("$file") ;;
      esac
    elif [ "${file##*.}" = "bats" ]; then
      SHELL_FILES+=("$file")
    fi
  done
}
_collect_shell_files

# ---- Rule: bash4-constructs (bash-specific) --------------------------------
# Batched: one grep per sub-pattern across all shell files.

_rule_bash4_constructs() {
  if _is_excluded "bash4-constructs"; then return 0; fi
  [ ${#SHELL_FILES[@]} -eq 0 ] && return 0

  # 1. local -A / declare -A (not anchored at line start — catch after ; too) # lint-pack:allow bash4-constructs
  local grep_out grep_rc=0
  # lint-pack:allow bash4-constructs
  grep_out="$(_grep_hits -E '(^|[;[:space:]])(local|declare)\s+-[a-zA-Z]*A' "${SHELL_FILES[@]}" 2>/dev/null)" || grep_rc=$?
  if [ "$grep_rc" -eq 2 ]; then
    _log "ERROR: grep error scanning for bash4 constructs"
    _FILE_ERROR_COUNT=$((_FILE_ERROR_COUNT + 1))
  elif [ -n "$grep_out" ]; then
    while IFS= read -r match_line; do
      _split_hit "$match_line"
      # Suppression marker
      if _is_suppressed "bash4-constructs" "$HIT_TEXT"; then
        continue
      fi
      # Build the keyword string from parts to avoid tripping the
      # bash32-portability-lint scanner on this script's own source.
      local kw assoc_flag="-A"
      case "$HIT_TEXT" in
        *local*) kw="local ${assoc_flag}" ;;
        *) kw="declare ${assoc_flag}" ;;
      esac
      _add_finding "bash4-constructs" "$HIT_FILE" "$HIT_LINE" \
        "${kw} (associative array) requires bash 4+" \
        "use indexed arrays or separate variables for bash 3.2 compatibility"
    done <<< "$grep_out"
  fi

  # 2. mapfile / readarray (not anchored at line start) # lint-pack:allow bash4-constructs
  grep_rc=0
  # lint-pack:allow bash4-constructs
  grep_out="$(_grep_hits -E '(^|[;[:space:]])(mapfile|readarray)\s' "${SHELL_FILES[@]}" 2>/dev/null)" || grep_rc=$?
  if [ "$grep_rc" -eq 2 ]; then
    _log "ERROR: grep error scanning for bash4 constructs"
    _FILE_ERROR_COUNT=$((_FILE_ERROR_COUNT + 1))
  elif [ -n "$grep_out" ]; then
    while IFS= read -r match_line; do
      _split_hit "$match_line"
      # Suppression marker
      if _is_suppressed "bash4-constructs" "$HIT_TEXT"; then
        continue
      fi
      # Construct message from parts to avoid tripping the portability scanner.
      local mf_msg="map""file/read""array requires bash 4+"
      _add_finding "bash4-constructs" "$HIT_FILE" "$HIT_LINE" \
        "$mf_msg" \
        "use a while-read loop instead"
    done <<< "$grep_out"
  fi

  # 3. case modification ${var,,} / ${var^^}  # lint-pack:allow bash4-constructs
  grep_rc=0
  grep_out="$(_grep_hits -E '\$\{[a-zA-Z_][a-zA-Z0-9_]*(,,|[\^][\^])\}' "${SHELL_FILES[@]}" 2>/dev/null)" || grep_rc=$?
  if [ "$grep_rc" -eq 2 ]; then
    _log "ERROR: grep error scanning for case modification"
    _FILE_ERROR_COUNT=$((_FILE_ERROR_COUNT + 1))
  elif [ -n "$grep_out" ]; then
    while IFS= read -r match_line; do
      _split_hit "$match_line"
      # Suppression marker
      if _is_suppressed "bash4-constructs" "$HIT_TEXT"; then
        continue
      fi
      _add_finding "bash4-constructs" "$HIT_FILE" "$HIT_LINE" \
        "case modification operator requires bash 4+" \
        "use tr for case conversion: \$(echo \"\$var\" | tr '[:upper:]' '[:lower:]')"
    done <<< "$grep_out"
  fi
}

# ---- Rule: sed-inplace (bash-specific) -------------------------------------

_rule_sed_inplace() {
  if _is_excluded "sed-inplace"; then return 0; fi
  [ ${#SHELL_FILES[@]} -eq 0 ] && return 0

  # Match: sed with -i flag and empty backup suffix  # lint-pack:allow sed-inplace
  # lint-pack:allow sed-inplace
  local grep_out grep_rc=0
  grep_out="$(_grep_hits -E "sed\s+(-[a-zA-Z]+\s+)*-i\s+''|sed\s+-i\s+''" "${SHELL_FILES[@]}" 2>/dev/null)" || grep_rc=$?
  if [ "$grep_rc" -eq 2 ]; then
    _log "ERROR: grep error scanning for sed -i"
    _FILE_ERROR_COUNT=$((_FILE_ERROR_COUNT + 1))
    return 0
  fi
  [ -z "$grep_out" ] && return 0

  while IFS= read -r match_line; do
    _split_hit "$match_line"
    # Suppression marker
    if _is_suppressed "sed-inplace" "$HIT_TEXT"; then
      continue
    fi
    _add_finding "sed-inplace" "$HIT_FILE" "$HIT_LINE" \
      "macOS-only in-place sed edit (breaks on GNU sed)" \
      "write to a temp file and mv, or use a portable sed wrapper"
  done <<< "$grep_out"
}

# ---- Rule: skip-in-red-test (bash-specific) --------------------------------

_rule_skip_in_red_test() {
  if _is_excluded "skip-in-red-test"; then return 0; fi

  # Only .bats files.
  declare -a bats_files=()
  local file
  for file in "${FILES[@]}"; do
    case "$file" in *.bats) bats_files+=("$file") ;; esac
  done
  [ ${#bats_files[@]} -eq 0 ] && return 0

  local grep_out grep_rc=0
  grep_out="$(_grep_hits -E '\|\|\s*skip' "${bats_files[@]}" 2>/dev/null)" || grep_rc=$?
  if [ "$grep_rc" -eq 2 ]; then
    _log "ERROR: grep error scanning for || skip"
    _FILE_ERROR_COUNT=$((_FILE_ERROR_COUNT + 1))
    return 0
  fi
  [ -z "$grep_out" ] && return 0

  while IFS= read -r match_line; do
    _split_hit "$match_line"
    # Carve-out: explicit suppression markers (both old and new forms)
    case "$HIT_TEXT" in
      *"# lint-pack:allow-skip"*|*"# lint-pack:allow skip-in-red-test"*) continue ;;
    esac
    _add_finding "skip-in-red-test" "$HIT_FILE" "$HIT_LINE" \
      "|| skip masks a missing dependency — red-phase tests must fail, not skip" \
      "remove || skip; let the test fail when the target is missing"
  done <<< "$grep_out"
}

# ---- Rule: bash-syntax (bash-specific) -------------------------------------

_rule_bash_syntax() {
  if _is_excluded "bash-syntax"; then return 0; fi
  [ ${#NON_BATS_SHELL_FILES[@]} -eq 0 ] && return 0

  local file
  for file in "${NON_BATS_SHELL_FILES[@]}"; do
    if [ ! -f "$file" ] || [ ! -r "$file" ]; then
      continue
    fi
    local syntax_out
    if ! syntax_out="$(/bin/bash -n "$file" 2>&1)"; then
      local first_line
      first_line="$(printf '%s\n' "$syntax_out" | head -1)"
      local err_line="0"
      if printf '%s\n' "$first_line" | grep -qE 'line [0-9]+' 2>/dev/null; then
        err_line="$(printf '%s\n' "$first_line" | sed -E 's/.*line ([0-9]+).*/\1/')"
      fi
      _add_finding "bash-syntax" "$file" "$err_line" \
        "syntax error: ${first_line}" \
        "fix the syntax error reported by /bin/bash -n"
    fi
  done
}

# ---- External rule.lint loader (--rules-dir) --------------------------------
# Load rule.lint files from external directories (shipped and project libraries).
# Each rule.lint is a YAML file with id, message, severity, languages, pattern,
# and optional exclude.

declare -a EXTERNAL_RULES=()

_load_rules_dirs() {
  [ ${#RULES_DIRS[@]} -gt 0 ] || return 0
  command -v yq >/dev/null 2>&1 || { _log "WARN: yq not found; --rules-dir rules skipped"; return 0; }
  local dir
  for dir in "${RULES_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    # Containment: resolve the library root for symlink checking.
    local lib_real
    lib_real="$(cd "$dir" 2>/dev/null && pwd -P)" || continue
    local rule_dir
    for rule_dir in "$dir"/*/; do
      [ -d "$rule_dir" ] || continue
      # Containment: rule directory must resolve inside the library.
      local rd_real
      rd_real="$(cd "$rule_dir" 2>/dev/null && pwd -P)" || continue
      case "$rd_real" in "$lib_real"/*) ;; *) _log "WARN: rule dir resolves outside library, skipped: $rule_dir"; continue ;; esac
      local lint_file="$rule_dir/rule.lint"
      [ -f "$lint_file" ] || continue
      # Containment: rule file must not be a symlink escaping the library.
      if [ -L "$lint_file" ]; then
        local rf_real=""
        if command -v readlink >/dev/null 2>&1; then
          rf_real="$(readlink -f "$lint_file" 2>/dev/null)" || rf_real=""
        fi
        if [ -n "$rf_real" ]; then
          case "$rf_real" in "$lib_real"/*) ;; *) _log "WARN: rule.lint resolves outside library, skipped: $lint_file"; continue ;; esac
        fi
      fi
      local rule_id
      rule_id="$(yq -r '.id // ""' "$lint_file" 2>/dev/null)" || continue
      [ -n "$rule_id" ] || continue
      EXTERNAL_RULES+=("$lint_file")
    done
  done
}
_load_rules_dirs

_run_external_rules() {
  [ ${#EXTERNAL_RULES[@]} -gt 0 ] || return 0
  local lint_file
  for lint_file in "${EXTERNAL_RULES[@]}"; do
    local rule_id msg sev pattern exclude_pat
    rule_id="$(yq -r '.id // ""' "$lint_file" 2>/dev/null)" || continue
    [ -n "$rule_id" ] || continue
    if _is_excluded "$rule_id"; then
      _log "  external rule ${rule_id}: excluded"
      continue
    fi
    msg="$(yq -r '.message // "external rule violation"' "$lint_file" 2>/dev/null)" || msg="external rule violation"
    sev="$(yq -r '.severity // "high"' "$lint_file" 2>/dev/null)" || sev="high"
    pattern="$(yq -r '.pattern // ""' "$lint_file" 2>/dev/null)" || pattern=""
    exclude_pat="$(yq -r '.exclude // ""' "$lint_file" 2>/dev/null)" || exclude_pat=""
    [ -n "$pattern" ] || continue

    # Read languages as file extensions.
    local lang_count
    lang_count="$(yq '.languages // [] | length' "$lint_file" 2>/dev/null)" || lang_count=0
    declare -a lang_exts=()
    if [ "$lang_count" -gt 0 ]; then
      local li=0
      while [ "$li" -lt "$lang_count" ]; do
        local ext
        ext="$(yq -r ".languages[$li]" "$lint_file" 2>/dev/null)" || ext=""  # lint-pack:allow spliced-yq-jq
        [ -n "$ext" ] && lang_exts+=("$ext")
        li=$((li + 1))
      done
    fi

    # Filter files by language extensions.
    declare -a target_files=()
    local file
    for file in "${FILES[@]}"; do
      if [ ${#lang_exts[@]} -eq 0 ]; then
        target_files+=("$file")
      else
        local ext
        for ext in "${lang_exts[@]}"; do
          case "$file" in
            *"${ext}") target_files+=("$file"); break ;;
          esac
        done
      fi
    done
    [ ${#target_files[@]} -gt 0 ] || continue

    _log "  external rule ${rule_id}: running"
    local grep_out grep_rc=0
    grep_out="$(_grep_hits -E -e "$pattern" "${target_files[@]}" 2>/dev/null)" || grep_rc=$?
    [ "$grep_rc" -eq 2 ] && { _log "ERROR: grep error in external rule ${rule_id}"; continue; }
    [ -z "$grep_out" ] && continue

    while IFS= read -r match_line; do
      _split_hit "$match_line"
      # Apply exclude pattern.
      if [ -n "$exclude_pat" ]; then
        if printf '%s\n' "$HIT_TEXT" | grep -qE "$exclude_pat" 2>/dev/null; then
          continue
        fi
      fi
      if _is_suppressed "$rule_id" "$HIT_TEXT"; then
        continue
      fi
      _add_finding "$rule_id" "$HIT_FILE" "$HIT_LINE" "$msg" "fix the pattern flagged by rule ${rule_id}"
    done <<< "$grep_out"
  done
}

# ---- Rule registry and execution -------------------------------------------

# Deterministic order: cross-stack rules first (alphabetical), then bash rules.
CROSS_STACK_RULES="hardcoded-credentials leaked-identifiers spliced-yq-jq"
BASH_RULES="bash4-constructs bash-syntax sed-inplace skip-in-red-test"

_has_shell_files() {
  [ ${#SHELL_FILES[@]} -gt 0 ]
}

# Run all rules
_log "scanning ${#FILES[@]} file(s)"
if [ ${#FILES[@]} -eq 0 ]; then
  _log "nothing to scan"
  CROSS_STACK_RULES=""
fi

for rule in $CROSS_STACK_RULES; do
  if _is_excluded "$rule"; then
    _log "  rule ${rule}: excluded"
    continue
  fi
  _log "  rule ${rule}: running"
  "_rule_$(printf '%s' "$rule" | tr '-' '_')"
done

if _has_shell_files; then
  for rule in $BASH_RULES; do
    if _is_excluded "$rule"; then
      _log "  rule ${rule}: excluded"
      continue
    fi
    _log "  rule ${rule}: running"
    "_rule_$(printf '%s' "$rule" | tr '-' '_')"
  done
else
  _log "  no shell files in scope — bash rules skipped"
fi

# Run external rules loaded from --rules-dir.
_run_external_rules

# In diff mode, filter findings to only those on added lines (batch pass).
_filter_findings_for_diff

# ---- Report generation -----------------------------------------------------

# Build the excluded-rules JSON array
EXCLUDED_JSON="[]"
if [ ${#EXCLUDED_RULES[@]} -gt 0 ]; then
  EXCLUDED_JSON="$(printf '%s\n' "${EXCLUDED_RULES[@]}" | jq -R . | jq -s .)"
fi

# Determine skipped rules to include in summary
SKIPPED_JSON="[]"
declare -a SKIPPED_LIST=()
if [ "$LEAK_RULE_CONFIGURED" != "true" ] && ! _is_excluded "leaked-identifiers"; then
  SKIPPED_LIST+=("leaked-identifiers")
fi
if [ ${#SKIPPED_LIST[@]} -gt 0 ]; then
  SKIPPED_JSON="$(printf '%s\n' "${SKIPPED_LIST[@]}" | jq -R . | jq -s .)"
fi

# Build the findings array (sorted for determinism: by file, then line, then
# rule) and hand it to jq on stdin: a large array must never travel as a
# command-line argument, where the per-argument limit would truncate the report.
_findings_json() {
  if [ ! -s "$_FINDINGS_FILE" ]; then
    printf '[]'
    return 0
  fi
  sort -t"$(printf '\t')" -k2,2 -k3,3n -k1,1 "$_FINDINGS_FILE" | \
    awk -F'\t' '
    BEGIN { printf "[" }
    NR>1 { printf "," }
    {
      # JSON-escape each field (handle backslash, double-quote, control chars)
      for (i=1; i<=5; i++) {
        gsub(/\\/, "\\\\", $i)
        gsub(/"/, "\\\"", $i)
        gsub(/\t/, "\\t", $i)
        gsub(/\n/, "\\n", $i)
      }
      printf "{\"rule\":\"%s\",\"file\":\"%s\",\"line\":%s,\"message\":\"%s\",\"fix_hint\":\"%s\"}", $1, $2, $3, $4, $5
    }
    END { printf "]" }
  '
}

# Write report with jq --argjson (never splice values)
_findings_json | jq \
  --argjson version 1 \
  --argjson excluded_rules "$EXCLUDED_JSON" \
  --argjson skipped_rules "$SKIPPED_JSON" \
  --argjson files_scanned "${_ORIGINAL_FILE_COUNT}" \
  '{version:$version, findings:., excluded_rules:$excluded_rules, skipped_rules:$skipped_rules, files_scanned:$files_scanned}' \
  > "$REPORT_PATH"

# ---- Text summary ----------------------------------------------------------

_log "scan complete: ${FINDING_COUNT} finding(s) in ${#FILES[@]} file(s)"
if [ "$_FILE_ERROR_COUNT" -gt 0 ]; then
  _log "file errors: ${_FILE_ERROR_COUNT}"
fi
if [ ${#EXCLUDED_RULES[@]} -gt 0 ]; then
  _log "excluded rules: ${EXCLUDED_RULES[*]}"
fi
if [ ${#SKIPPED_LIST[@]} -gt 0 ]; then
  _log "skipped rules (not configured): ${SKIPPED_LIST[*]}"
fi
_log "report: ${REPORT_PATH}"

if [ "$FINDING_COUNT" -gt 0 ]; then
  _log ""
  _log "findings:"
  # Print findings sorted for determinism
  jq -r '.findings[] | "  \(.file):\(.line) [\(.rule)] \(.message) — \(.fix_hint)"' "$REPORT_PATH"
fi

# Exit code priority: file errors (2) > findings (1) > clean (0)
if [ "$_FILE_ERROR_COUNT" -gt 0 ]; then
  exit 2
fi
if [ "$FINDING_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
