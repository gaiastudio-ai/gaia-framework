#!/usr/bin/env bash
# mode-resolve.sh — per-skill dispatch-mode resolution.
# Sourceable, NOT executable.
#
# The framework's global dispatch mode (subagent | team) is resolved by
# detect-orchestration-mode.sh. This library adds an opt-in, per-skill
# override on top of that global decision:
#
#   A skill may declare `mode: A` in its SKILL.md frontmatter to pin itself
#   to foreground (subagent) dispatch even when the framework is running with
#   persistent teammates enabled globally. This is the per-skill backward-
#   compatibility knob — a skill that is not yet team-ready (or that must run
#   foreground for any reason) can keep the legacy behaviour without changing
#   the global setting.
#
# resolve_skill_mode SKILL_PATH GLOBAL_MODE
#   Prints the effective mode (subagent | team) on stdout, exit 0.
#   - GLOBAL_MODE subagent  -> always subagent (frontmatter cannot upgrade).
#   - GLOBAL_MODE team      -> team, UNLESS the skill declares `mode: A`,
#                              in which case it is pinned to subagent.
#   - A missing/unreadable SKILL.md degrades to GLOBAL_MODE (no error).
#
# bash 3.2-safe: no ${var,,}, no mapfile. Case folding is done with a small
# explicit case statement, not parameter-expansion case modification.

# ---------- Source guard ----------

if [ "${_MR_LOADED:-0}" = "1" ]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi

# _mr_read_mode_frontmatter SKILL_PATH
# Print the raw value of the top-level `mode:` key from the YAML frontmatter,
# or nothing if absent. Only the frontmatter block (between the first two
# `---` delimiters) is scanned, and only unindented top-level keys count.
_mr_read_mode_frontmatter() {
  local skill_path="$1"
  [ -f "$skill_path" ] || return 0
  [ -r "$skill_path" ] || return 0

  awk '
    NR == 1 && $0 != "---" { exit }
    NR == 1 { in_fm = 1; next }
    in_fm && $0 == "---" { exit }
    in_fm && /^mode:[[:space:]]*/ {
      sub(/^mode:[[:space:]]*/, "")
      sub(/[[:space:]]*#.*$/, "")
      sub(/^"/, ""); sub(/"$/, "")
      sub(/^'\''/, ""); sub(/'\''$/, "")
      sub(/[[:space:]]+$/, "")
      print
      exit
    }
  ' "$skill_path" 2>/dev/null || printf ''
}

# _mr_is_mode_a VALUE — return 0 if VALUE denotes the foreground (Mode A)
# override, case-insensitively. Accepts "A" and "a". bash 3.2-safe: explicit
# case fold, no ${var,,}.
_mr_is_mode_a() {
  case "$1" in
    A|a) return 0 ;;
    *)   return 1 ;;
  esac
}

# resolve_skill_mode SKILL_PATH GLOBAL_MODE — see header.
resolve_skill_mode() {
  local skill_path="${1:-}"
  local global_mode="${2:-subagent}"

  # A subagent (Mode A) framework can never be upgraded by a skill — the
  # frontmatter knob is an opt-OUT of team mode, never an opt-in.
  if [ "$global_mode" != "team" ]; then
    printf 'subagent\n'
    return 0
  fi

  # Global mode is team. Honour a per-skill foreground pin if present.
  local declared
  declared="$(_mr_read_mode_frontmatter "$skill_path")"
  if _mr_is_mode_a "$declared"; then
    printf 'subagent\n'
    return 0
  fi

  printf 'team\n'
  return 0
}

# ---------- Source guard — mark loaded ----------
_MR_LOADED=1
