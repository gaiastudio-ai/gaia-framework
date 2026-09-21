# runtime-paths.bash — resolve the runtime tree the way production resolves it.
#
# The meeting scripts take project-root-RELATIVE paths (write-boundary.sh) or
# emit them (research-phase-dispatch.sh --sidecar-path). Tests must not carry a
# second hard-coded copy of the tree layout: when the tree moves, a literal in a
# fixture silently keeps asserting the old shape. Instead we source the same
# path helper the shipped scripts use and derive the relative prefixes from it,
# so a future tree move is picked up here automatically.
#
# Exports (all project-root-relative, no leading slash):
#   GAIA_REL_ARTIFACTS   e.g. .gaia/artifacts
#   GAIA_REL_STATE       e.g. .gaia/state
#   GAIA_REL_MEMORY      e.g. .gaia/memory
#   GAIA_REL_CUSTOM      e.g. .gaia/custom

# shellcheck shell=bash

gaia_load_runtime_paths() {
  local repo_root="$1"
  local helper="$repo_root/plugins/gaia/scripts/lib/gaia-paths.sh"

  [ -r "$helper" ] || return 1

  # Resolve against a scratch project root so the helper never walks up into
  # the developer's real tree and picks up an unrelated .gaia/ directory.
  local probe
  probe="$(mktemp -d)" || return 1
  mkdir -p "$probe/.gaia"

  local out
  # The inner script is deliberately single-quoted: it must expand in the
  # child shell, after gaia-paths.sh has been sourced there, not here.
  # shellcheck disable=SC2016
  out="$(
    env -u PROJECT_ROOT -u PROJECT_PATH -u GAIA_CONFIG_PATH -u GAIA_ARTIFACTS_PATH \
        -u GAIA_STATE_PATH -u GAIA_MEMORY_PATH -u GAIA_CUSTOM_PATH -u GAIA_KNOWLEDGE_PATH \
        CLAUDE_PROJECT_ROOT="$probe" bash -c '
      . "$1" || exit 1
      # gaia-paths.sh canonicalises through symlinks (/tmp -> /private/tmp on
      # macOS); canonicalise the root the same way before stripping it, or the
      # prefix will not match and the strip silently no-ops.
      root="$(cd "$CLAUDE_PROJECT_ROOT" && pwd -P)"
      printf "%s\n%s\n%s\n%s\n" \
        "${GAIA_ARTIFACTS_DIR#"$root"/}" \
        "${GAIA_STATE_DIR#"$root"/}" \
        "${GAIA_MEMORY_DIR#"$root"/}" \
        "${GAIA_CUSTOM_DIR#"$root"/}"
    ' _ "$helper"
  )" || { rm -rf "$probe"; return 1; }

  rm -rf "$probe"

  GAIA_REL_ARTIFACTS="$(printf '%s\n' "$out" | sed -n '1p')"
  GAIA_REL_STATE="$(printf '%s\n' "$out" | sed -n '2p')"
  GAIA_REL_MEMORY="$(printf '%s\n' "$out" | sed -n '3p')"
  GAIA_REL_CUSTOM="$(printf '%s\n' "$out" | sed -n '4p')"

  # A resolution that came back absolute (or empty) means the strip failed and
  # every downstream assertion would be meaningless. Fail loudly instead.
  case "$GAIA_REL_ARTIFACTS" in ""|/*) return 1 ;; esac
  case "$GAIA_REL_STATE" in ""|/*) return 1 ;; esac
  case "$GAIA_REL_MEMORY" in ""|/*) return 1 ;; esac
  case "$GAIA_REL_CUSTOM" in ""|/*) return 1 ;; esac

  export GAIA_REL_ARTIFACTS GAIA_REL_STATE GAIA_REL_MEMORY GAIA_REL_CUSTOM
}
