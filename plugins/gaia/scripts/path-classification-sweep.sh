#!/usr/bin/env bash
# path-classification-sweep.sh — classify every plugin script and SKILL.md
# by how it resolves .gaia/ state paths.
#
# Categories for scripts:
#   code-path       — no .gaia/ access, or only comments/logging/template-emission
#   state-path      — already uses PROJECT_ROOT for all .gaia/ access
#   mixed           — uses both PROJECT_ROOT and PROJECT_PATH for .gaia/
#   heuristic       — CWD-relative .gaia/, bare $PROJECT_PATH/.gaia, or
#                     two-stage chain omitting PROJECT_ROOT
#   heuristic(shape4-recompute) — PROJECT_ROOT unconditionally recomputed
#   heuristic(shape4-clobber)   — PROJECT_ROOT="" init discards caller export
#
# Categories for SKILL.md:
#   executed-heuristic  — .gaia/ in a shell assignment, test, or command
#                         inside a fenced code block, without PROJECT_ROOT
#   prose/documentation — .gaia/ in narrative prose only
#
# Symlink disposition: .gaia/ reached via symlink is SUPPORTED. The logical
# path under PROJECT_ROOT is used consistently; no realpath canonicalisation
# is applied. The chain resolves PROJECT_ROOT as-supplied by the caller.
#
# Usage (standalone):
#   path-classification-sweep.sh <plugin-root>
#
# Usage (sourced — exposes detector functions for the anti-pattern gate):
#   source path-classification-sweep.sh
#   _has_bare_pp_gaia "$file_content"     # clause 1
#   _has_cwd_gaia "$file_content"         # clause 2
#   _is_shape4_chain_missing_pr "$content" # clause 3
#
# Output (standalone): Markdown classification table on stdout.

# When sourced by the anti-pattern gate, skip shell-option changes so the
# caller's $- is preserved. When executed directly, main() sets its own.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  LC_ALL=C; export LC_ALL
fi

# ---------------------------------------------------------------------------
# Shared detector functions — used by both the sweep and the anti-pattern gate.
# Prefixed with _ to stay out of the public-function coverage gate.
# ---------------------------------------------------------------------------

# Shape-3 pattern: CWD-relative .gaia/ in path construction, including
# assignment forms, test forms, AND emitter forms (printf/echo).
_SHAPE3_PATTERN='=.*\.gaia/|[[:space:]]-[fd][[:space:]].*\.gaia/|\[.*\.gaia/|mkdir.*\.gaia/|printf.*\.gaia/|echo.*\.gaia/'

_has_bare_pp_gaia() {
  # Clause 1: bare $PROJECT_PATH/.gaia in non-comment lines.
  local content="$1"
  local out
  out=$(printf '%s\n' "$content" | grep -v '^\s*#' | grep -E 'PROJECT_PATH.*\.gaia|PROJECT_PATH\}.*\.gaia' || true)
  [ -n "$out" ]
}

_has_cwd_gaia() {
  # Clause 2: CWD-relative .gaia/ in path construction without PROJECT_ROOT.
  # Exclusions (not violations):
  #   - .gaia/ preceded by / — rooted through a variable ($var/.gaia/)
  #   - .gaia/ inside single-quoted strings — literal text, not expanded paths
  #   - .gaia/ in [[ pattern matches (== .gaia/ or =~ .gaia/)
  # The shape-1 clause separately catches $PROJECT_PATH/.gaia.
  local content="$1"
  local out
  out=$(printf '%s\n' "$content" | grep -v '^\s*#' | grep '\.gaia/' \
    | grep -v 'PROJECT_ROOT.*\.gaia' \
    | grep -v 'PROJECT_PATH.*\.gaia' \
    | grep -v 'CLAUDE_PROJECT_ROOT.*\.gaia' \
    | grep -v '/\.gaia/' \
    | grep -v '}\.gaia/' \
    | grep -v "^[^']*'[^']*\.gaia/[^']*'" \
    | grep -v '== .*\.gaia/' \
    | grep -v '=~ .*\.gaia/' \
    | grep -v 'echo ".*\.gaia/.*>&2' \
    | grep -v "printf '.*\.gaia/.*>&2" \
    | grep -v 'log ".*\.gaia/' \
    | grep -v 'die ".*\.gaia/' \
    | grep -v 'err ".*\.gaia/' \
    | grep -v 'warn ".*\.gaia/' \
    | grep -E "$_SHAPE3_PATTERN" \
    || true)
  [ -n "$out" ]
}

_count_cwd_gaia() {
  local content="$1"
  local out
  out=$(printf '%s\n' "$content" | grep -v '^\s*#' | grep '\.gaia/' \
    | grep -v 'PROJECT_ROOT.*\.gaia' \
    | grep -v 'PROJECT_PATH.*\.gaia' \
    | grep -v 'CLAUDE_PROJECT_ROOT.*\.gaia' \
    | grep -v '/\.gaia/' \
    | grep -v '}\.gaia/' \
    | grep -v "^[^']*'[^']*\.gaia/[^']*'" \
    | grep -v '== .*\.gaia/' \
    | grep -v '=~ .*\.gaia/' \
    | grep -v 'echo ".*\.gaia/.*>&2' \
    | grep -v "printf '.*\.gaia/.*>&2" \
    | grep -v 'log ".*\.gaia/' \
    | grep -v 'die ".*\.gaia/' \
    | grep -v 'err ".*\.gaia/' \
    | grep -v 'warn ".*\.gaia/' \
    | grep -E "$_SHAPE3_PATTERN" \
    || true)
  if [ -n "$out" ]; then
    printf '%s\n' "$out" | grep -c '.' || printf '0'
  else
    printf '0'
  fi
}

_is_shape4_chain_missing_pr() {
  # Clause 3: PROJECT_ROOT= chain assignment whose RHS does not start
  # with ${PROJECT_ROOT:- — discards a caller-exported value.
  # Carve-outs: argparse ($2), $(cd..) immediate subshell, empty (""),
  # $PWD direct, $_walk, --project-root flag handler.
  local content="$1"
  local chain_lines
  chain_lines=$(printf '%s\n' "$content" | grep -v '^\s*#' \
    | grep -E '(^|[[:space:]])PROJECT_ROOT="' \
    | grep -v -- '--project-root' \
    | grep -v -F 'PROJECT_ROOT=""' \
    | grep -v -F 'PROJECT_ROOT="$2' \
    | grep -v -F 'PROJECT_ROOT="$_' \
    | grep -v -F 'PROJECT_ROOT="$PWD' \
    || true)
  # Remove lines where the IMMEDIATE RHS is a subshell: PROJECT_ROOT="$(cd ..."
  if [ -n "$chain_lines" ]; then
    chain_lines=$(printf '%s\n' "$chain_lines" | grep -v 'PROJECT_ROOT="\$([^{]' || true)
  fi
  # Keep only lines whose RHS does NOT contain ${PROJECT_ROOT:-
  if [ -n "$chain_lines" ]; then
    local no_pr
    no_pr=$(printf '%s\n' "$chain_lines" | grep -v -F '${PROJECT_ROOT:-' || true)
    if [ -n "$no_pr" ]; then
      # Exclude lines inside an `if [ -z "$PROJECT_ROOT" ]` guard
      local unguarded
      unguarded=$(printf '%s\n' "$no_pr" | grep -v 'if \[ -z' || true)
      [ -n "$unguarded" ]
      return $?
    fi
  fi
  return 1
}

_classify_skillmd_content() {
  # Classifies a SKILL.md file's content for executed heuristic .gaia/ paths.
  # Returns via stdout: "executed-heuristic" or "prose" with site count.
  local f="$1"
  local exec_lines
  exec_lines=$(awk '
    /^```(bash|sh|shell)[[:space:]]*$/ { in_code=1; next }
    /^```[[:space:]]*$/ { if (in_code) { in_code=0 } else { in_code=1 }; next }
    in_code && /\.gaia\// && !/^[[:space:]]*#/ && !/PROJECT_ROOT/ && !/CLAUDE_PROJECT_ROOT/ && !/GAIA_ARTIFACTS_DIR/ && !/GAIA_CONFIG_DIR/ && !/GAIA_MEMORY_DIR/ && !/GAIA_STATE_DIR/ {
      if (length($0) > 200) next
      if (/[A-Z_]+="[^"]*\.gaia/ || /[A-Z_]+=\047[^\047]*\.gaia/ || /[A-Z_]+=\$.*\.gaia/ || /\$[A-Z_]+[^[:space:]]*\.gaia/ || /-[fd] .*\.gaia/ || /if \[.*\.gaia/ || /\[\[.*\.gaia/ || /yq .*\.gaia/ || /awk .*\.gaia/ || /cat .*\.gaia/ || /MEMORY_PATH:-.*\.gaia/ || /PROJECT_PATH:-.*\.gaia/) {
        if (/--paths /) next
        print NR": "$0
      }
    }
  ' "$f" || true)
  if [ -n "$exec_lines" ]; then
    local n
    n=$(printf '%s\n' "$exec_lines" | grep -c '.' || printf '0')
    printf 'executed-heuristic:%d' "$n"
  else
    printf 'prose:0'
  fi
}

# ---------------------------------------------------------------------------
# Internal sweep helpers (not shared with gate).
# ---------------------------------------------------------------------------

_has_pr_gaia() {
  local out
  out=$(printf '%s\n' "$1" | grep -v '^\s*#' | grep -E 'PROJECT_ROOT.*\.gaia|PROJECT_ROOT\}.*\.gaia' || true)
  [ -n "$out" ]
}

_count_pr_gaia() {
  local out
  out=$(printf '%s\n' "$1" | grep -v '^\s*#' | grep -E 'PROJECT_ROOT.*\.gaia|PROJECT_ROOT\}.*\.gaia' || true)
  if [ -n "$out" ]; then printf '%s\n' "$out" | grep -c '.' || printf '0'; else printf '0'; fi
}

_count_pp_gaia() {
  local out
  out=$(printf '%s\n' "$1" | grep -v '^\s*#' | grep -E 'PROJECT_PATH.*\.gaia|PROJECT_PATH\}.*\.gaia' || true)
  if [ -n "$out" ]; then printf '%s\n' "$out" | grep -c '.' || printf '0'; else printf '0'; fi
}

_has_shape2() {
  local out
  out=$(printf '%s\n' "$1" | grep -v '^\s*#' \
    | grep -E '(CLAUDE_PROJECT_ROOT|PWD).*\.gaia' \
    | grep -v 'PROJECT_ROOT' || true)
  [ -n "$out" ]
}

_has_shape4_recompute() {
  local out
  out=$(printf '%s\n' "$1" | grep -v '^\s*#' \
    | grep -E 'PROJECT_ROOT="\$\(cd |PROJECT_ROOT="\$\{?PWD\}?"' \
    | grep -v 'PROJECT_ROOT:-' || true)
  [ -n "$out" ]
}

_has_shape4_clobber() {
  local content="$1"
  local init_empty
  init_empty=$(printf '%s\n' "$content" | grep -v '^\s*#' \
    | grep -E '^[[:space:]]*PROJECT_ROOT=""' || true)
  if [ -n "$init_empty" ]; then
    local has_guard
    has_guard=$(printf '%s\n' "$content" | grep -E '\[ -n "\$PROJECT_ROOT" \] \|\|' || true)
    local has_fallback
    has_fallback=$(printf '%s\n' "$content" | grep -F 'PROJECT_ROOT="${PROJECT_ROOT:-' || true)
    [ -z "$has_guard" ] && [ -z "$has_fallback" ]
    return $?
  fi
  return 1
}

# Counters (global for the sweep; not used by the gate).
_total_scripts=0
_cat_code_path=0
_cat_state_path=0
_cat_mixed=0
_cat_heuristic=0
_cat_recompute=0
_cat_clobber=0
_cat_skill_exec_heur=0
_cat_skill_prose=0

_classify_script() {
  local f="$1"
  local rel="${f#"$PLUGIN_ROOT"/}"
  case "$f" in *.bats|*.md) return 0 ;; esac
  case "$rel" in scripts/path-classification-sweep.sh) return 0 ;; esac
  [ -f "$f" ] || return 0

  local content
  content="$(cat "$f")"

  local h_pr=0 h_pp=0 h_cwd=0 h_s2=0 h_s4r=0 h_s4c=0
  local pr_n=0 pp_n=0 cwd_n=0

  _has_pr_gaia "$content" && { h_pr=1; pr_n=$(_count_pr_gaia "$content"); }
  _has_bare_pp_gaia "$content" && { h_pp=1; pp_n=$(_count_pp_gaia "$content"); }
  _has_shape2 "$content" && h_s2=1
  _has_cwd_gaia "$content" && { h_cwd=1; cwd_n=$(_count_cwd_gaia "$content"); }
  _has_shape4_recompute "$content" && h_s4r=1
  _is_shape4_chain_missing_pr "$content" && h_s4r=1
  _has_shape4_clobber "$content" && h_s4c=1

  local category="" shapes=""
  if [ "$h_s4r" -eq 1 ]; then
    category="heuristic(shape4-recompute)"; _cat_recompute=$((_cat_recompute + 1))
  elif [ "$h_s4c" -eq 1 ]; then
    category="heuristic(shape4-clobber)"; _cat_clobber=$((_cat_clobber + 1))
  elif [ "$h_pp" -eq 1 ] && [ "$h_pr" -eq 1 ]; then
    category="mixed"; _cat_mixed=$((_cat_mixed + 1))
  elif [ "$h_pp" -eq 1 ] || [ "$h_cwd" -eq 1 ] || [ "$h_s2" -eq 1 ]; then
    category="heuristic"; _cat_heuristic=$((_cat_heuristic + 1))
  elif [ "$h_pr" -eq 1 ]; then
    category="state-path"; _cat_state_path=$((_cat_state_path + 1))
  else
    category="code-path"; _cat_code_path=$((_cat_code_path + 1))
  fi

  [ "$h_pp" -eq 1 ] && shapes="${shapes}S1($pp_n) "
  [ "$h_s2" -eq 1 ] && shapes="${shapes}S2 "
  [ "$h_cwd" -eq 1 ] && shapes="${shapes}S3($cwd_n) "
  [ "$h_s4r" -eq 1 ] && shapes="${shapes}S4-recompute "
  [ "$h_s4c" -eq 1 ] && shapes="${shapes}S4-clobber "
  [ "$h_pr" -eq 1 ] && shapes="${shapes}PR($pr_n) "

  _total_scripts=$((_total_scripts + 1))
  printf '| `%s` | %s | %s |\n' "$rel" "$category" "${shapes:-none}"
}

_classify_skillmd() {
  local f="$1"
  local rel="${f#"$PLUGIN_ROOT"/}"
  [ -f "$f" ] || return 0
  if ! grep -q '\.gaia/' "$f" 2>/dev/null; then return 0; fi

  local verdict
  verdict=$(_classify_skillmd_content "$f")
  local kind="${verdict%%:*}"
  local n="${verdict#*:}"

  if [ "$kind" = "executed-heuristic" ]; then
    _cat_skill_exec_heur=$((_cat_skill_exec_heur + 1))
    printf '| `%s` | executed-heuristic | %d site(s) |\n' "$rel" "$n"
  else
    _cat_skill_prose=$((_cat_skill_prose + 1))
    printf '| `%s` | prose/documentation | .gaia/ in prose only |\n' "$rel"
  fi
}

# ---------------------------------------------------------------------------
# main — the only public entry point. Guarded so the file can be sourced.
# ---------------------------------------------------------------------------

main() {
  PLUGIN_ROOT="${1:-.}"

  printf '# Path Classification Table\n\n'
  printf 'Generated: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'Plugin root: %s\n\n' "$PLUGIN_ROOT"
  printf '## Symlink Disposition\n\n'
  printf 'A `.gaia/` directory reached via symlink is **supported**. The logical\n'
  printf 'path under PROJECT_ROOT is used consistently; no `realpath`\n'
  printf 'canonicalisation is applied. The chain resolves PROJECT_ROOT as\n'
  printf 'supplied by the caller.\n\n'

  local _script_arr=()
  while IFS= read -r _line; do
    [ -n "$_line" ] && _script_arr+=("$_line")
  done < <(find "$PLUGIN_ROOT/scripts" "$PLUGIN_ROOT/skills" \
    -name '*.sh' -not -name '*.bats' -not -path '*/tests/*' | sort)

  local _skill_arr=()
  while IFS= read -r _line; do
    [ -n "$_line" ] && _skill_arr+=("$_line")
  done < <(find "$PLUGIN_ROOT/skills" -maxdepth 2 -name 'SKILL.md' | sort)

  printf '## Shell Scripts\n\n'
  printf '| File | Category | Shapes |\n'
  printf '|------|----------|--------|\n'
  local _i
  for _i in "${_script_arr[@]}"; do
    _classify_script "$_i"
  done

  printf '\n### Script Totals\n\n'
  printf -- '- **code-path:** %d\n' "$_cat_code_path"
  printf -- '- **state-path:** %d\n' "$_cat_state_path"
  printf -- '- **mixed:** %d\n' "$_cat_mixed"
  printf -- '- **heuristic:** %d\n' "$_cat_heuristic"
  printf -- '- **heuristic(shape4-recompute):** %d\n' "$_cat_recompute"
  printf -- '- **heuristic(shape4-clobber):** %d\n' "$_cat_clobber"
  printf -- '- **Total scripts scanned:** %d\n' "$_total_scripts"
  printf -- '- **Total needing remediation:** %d\n' \
    "$((_cat_heuristic + _cat_mixed + _cat_recompute + _cat_clobber))"
  printf '\n'

  printf '## SKILL.md Files\n\n'
  printf '| File | Category | Detail |\n'
  printf '|------|----------|--------|\n'
  for _i in "${_skill_arr[@]}"; do
    _classify_skillmd "$_i"
  done

  printf '\n### SKILL.md Totals\n\n'
  printf -- '- **executed-heuristic:** %d\n' "$_cat_skill_exec_heur"
  printf -- '- **prose/documentation:** %d\n' "$_cat_skill_prose"
  printf -- '- **Total SKILL.md with .gaia/:** %d\n' \
    "$((_cat_skill_exec_heur + _cat_skill_prose))"
}

# Source guard: when executed directly, run main. When sourced, only
# expose functions (the gate sources this for the shared detectors).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
