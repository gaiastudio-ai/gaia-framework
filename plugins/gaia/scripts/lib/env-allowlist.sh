#!/usr/bin/env bash
# env-allowlist.sh — shared environment-variable allowlist helper
#
# Provides `build_env_args()` — given a curated allowlist of env-var names,
# emits the argv fragment for `env -i` so child processes inherit ONLY the
# allowlisted variables. Parent-shell secrets (AWS_SECRET_ACCESS_KEY,
# GITHUB_TOKEN, OPENAI_API_KEY, etc.) are stripped before the child sees them.
#
# Precedent: gaia-framework/plugins/gaia/scripts/adapters/owasp-zap/run.sh lines 98-146
# uses the same env-allowlist pattern; this helper extracts it into a shared
# library so the ZAP adapter can retrofit onto the same primitive (per the
# threat-model cross-reference note at threat-model.md line 537).
#
# POSIX discipline: bash with [[ ]] only. macOS /bin/bash 3.2 compatible.
# No declare -A, no ${var,,}, no [[ =~ ]] backreferences, no &>>.

# The canonical 7-variable explicit allowlist for foreground stakeholder demos.
# PATH:   tool resolution
# HOME:   ~/.npmrc, ~/.gradle/, etc.
# USER:   process ownership / login name
# TMPDIR: temp file location (macOS)
# TERM:   colored terminal output (headed demos are visual)
# LANG:   locale
# LC_ALL: locale override
#
# NOTE on bash-auto-set vars:
#   When the child subprocess runs `bash` or `sh`, that shell auto-sets a
#   small set of internal vars regardless of `env -i`:
#     PWD   — current working directory (set by the shell on startup)
#     SHLVL — shell nesting depth
#     _     — last executed command path
#   These are NOT secrets and NOT in this allowlist — they are set by the
#   spawned shell itself after env-stripping. The empirical subprocess env
#   therefore contains 7 explicit + 3 bash-auto = 10 vars. The 7-var
#   security guarantee is preserved: parent-shell secrets like
#   AWS_SECRET_ACCESS_KEY, GITHUB_TOKEN, OPENAI_API_KEY are still stripped.
GAIA_ENV_ALLOWLIST_DEFAULT="PATH HOME USER TMPDIR TERM LANG LC_ALL"

# build_env_args [allowlist_string]
#   Emits a space-separated sequence of NAME=value pairs suitable for use
#   immediately after `env -i`. Variables that are unset in the parent shell
#   are silently skipped (graceful degrade — no fallback to a stale value,
#   just omission).
#
#   Usage:
#     args=$(build_env_args)
#     eval env -i $args <child-command>
#
#   Optional first arg: a space-separated allowlist (defaults to the canonical
#   7-var list).
build_env_args() {
  local allowlist="${1:-$GAIA_ENV_ALLOWLIST_DEFAULT}"
  local name val out=""
  for name in $allowlist; do
    # Indirect expansion compatible with bash 3.2.
    eval "val=\${$name:-}"
    if [ -n "$val" ]; then
      # Single-quote the value to be safe with metacharacters; embedded
      # single-quotes are escaped via the standard '\'' idiom.
      out="$out ${name}='$(printf '%s' "$val" | sed "s/'/'\\\\''/g")'"
    fi
  done
  # Trim leading space.
  printf '%s' "${out# }"
}
