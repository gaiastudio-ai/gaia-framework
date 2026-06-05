#!/usr/bin/env bash
# checkpoint.sh — GAIA foundation script
#
# Read/write/validate workflow checkpoints in YAML format with sha256 checksums
# for every touched file. Replaces the LLM-driven checkpoint discipline that
# workflow.xml rule n="13" currently enforces.
#
# Invocation contract:
#
#   checkpoint.sh write    --workflow <name> --step <n>
#                          [--var key=val ...] [--file <path> ...]
#   checkpoint.sh read     --workflow <name>
#   checkpoint.sh validate --workflow <name>
#
# Config:
#   CHECKPOINT_PATH — required. Either set in the environment, or resolved at
#     runtime via `resolve-config.sh` (sourced from the sibling scripts dir) if
#     a project-config.yaml can be located. Never hardcoded.
#
# Exit codes:
#   0 — success
#   1 — usage error, validation drift, concurrency timeout, unreadable --file,
#       path traversal, or other caller-facing error
#   2 — missing checkpoint (read) or missing referenced file (validate)
#
# Output schema (YAML, deterministic field order):
#   workflow:      <string>
#   step:          <int>
#   timestamp:     <ISO 8601 UTC, second precision>
#   variables:
#     <key>: <val>          # omitted block when there are no --var flags
#   files_touched: []       # OR a list of {path, sha256, last_modified}
#
# POSIX discipline: the only non-POSIX constructs are [[ ]] and bash indexed
# arrays. macOS /bin/bash 3.2 compatible. Uses `shasum -a 256` (GAIA standard)
# and never shells out to `yq` on the write path.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="checkpoint.sh"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# ---------- Helpers ----------

die() {
  # exit_code message…
  local rc="$1"; shift
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit "$rc"
}

usage() {
  cat >&2 <<'USAGE'
Usage:
  checkpoint.sh write    --workflow <name> --step <n> [--var key=val ...] [--file <path> ...]
  checkpoint.sh read     --workflow <name>
  checkpoint.sh validate --workflow <name>

Exit codes: 0 ok | 1 usage/drift/error | 2 missing checkpoint or missing file
USAGE
}

# ISO 8601 UTC with second precision. Must match lifecycle spec (no ms).
iso_utc_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Cross-platform file mtime in ISO 8601 UTC.
file_mtime_utc() {
  local p="$1"
  # macOS (BSD stat)
  if stat -f %m "$p" >/dev/null 2>&1; then
    date -u -r "$(stat -f %m "$p")" +%Y-%m-%dT%H:%M:%SZ
    return
  fi
  # GNU stat
  if stat -c %Y "$p" >/dev/null 2>&1; then
    date -u -d "@$(stat -c %Y "$p")" +%Y-%m-%dT%H:%M:%SZ
    return
  fi
  iso_utc_now
}

# Compute sha256 for a file using `shasum -a 256` (GAIA standard). Falls back
# to `sha256sum` on Linux minimal images where shasum is absent.
file_sha256() {
  local p="$1" out
  if command -v shasum >/dev/null 2>&1; then
    out=$(shasum -a 256 "$p") || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    out=$(sha256sum "$p") || return 1
  else
    die 1 "neither shasum nor sha256sum available on PATH"
  fi
  printf '%s' "${out%% *}"
}

# Reject workflow names that would escape CHECKPOINT_PATH. Keep the ruleset
# conservative: no slashes, no "..", no leading dot, non-empty.
validate_workflow_name() {
  local name="$1"
  [ -n "$name" ] || die 1 "path traversal rejected: workflow name is empty"
  case "$name" in
    */*|*..*|.*)
      die 1 "path traversal rejected in --workflow: $name" ;;
  esac
}

# Emit a YAML scalar value. Quote with double quotes when the value contains
# characters that would trip a naive parser (space, :, #, leading -, quotes,
# non-ASCII). Otherwise emit bare. Always safe for `yq` round-trip.
yaml_scalar() {
  local v="$1"
  if [ -z "$v" ]; then
    printf '""'
    return
  fi
  case "$v" in
    *[:\#\"\'\\]* | *\ * | -*| \[*|\{*)
      local esc
      esc=$(printf '%s' "$v" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
      printf '"%s"' "$esc" ;;
    *)
      # Treat anything outside printable ASCII as needing quoting for safety.
      if printf '%s' "$v" | LC_ALL=C grep -q '[^[:print:]]\|[^[:ascii:]]' 2>/dev/null; then
        local esc
        esc=$(printf '%s' "$v" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
        printf '"%s"' "$esc"
      else
        # Also quote if the bytes include non-ASCII (multi-byte characters).
        case "$v" in
          *$'\xc2'*|*$'\xc3'*|*$'\xe2'*|*$'\xef'*)
            local esc
            esc=$(printf '%s' "$v" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
            printf '"%s"' "$esc" ;;
          *)
            printf '%s' "$v" ;;
        esac
      fi
      ;;
  esac
}

# ---------- CHECKPOINT_PATH resolution ----------

resolve_checkpoint_path() {
  if [ -n "${CHECKPOINT_PATH:-}" ]; then
    return 0
  fi
  # Try sibling resolve-config.sh. The resolver owns its own
  # 6-level precedence ladder (--shared / --config / $GAIA_SHARED_CONFIG /
  # $CLAUDE_PROJECT_ROOT/config / $PWD/config / $CLAUDE_SKILL_DIR/config),
  # so we no longer pre-check ${CLAUDE_SKILL_DIR:-}: gating on it here would
  # short-circuit every caller that now resolves via CLAUDE_PROJECT_ROOT
  # (i.e. every Claude Code skill invocation). If the
  # resolver cannot locate a usable config it exits non-zero and emits no
  # 'checkpoint_path=' line, so the loop below falls through to die 1 and
  # the fail-hard contract is preserved.
  local resolver="$SCRIPT_DIR/resolve-config.sh"
  if [ -x "$resolver" ]; then
    local line
    # shellcheck disable=SC2016
    while IFS= read -r line; do
      case "$line" in
        checkpoint_path=*)
          # Strip leading "checkpoint_path='" and trailing "'".
          local v="${line#checkpoint_path=}"
          v="${v#\'}"; v="${v%\'}"
          CHECKPOINT_PATH="$v"
          export CHECKPOINT_PATH
          return 0
          ;;
      esac
    done < <("$resolver" 2>/dev/null || true)
  fi
  die 1 "CHECKPOINT_PATH not resolved"
}

# ---------- Subcommand: write ----------

cmd_write() {
  local workflow="" step=""
  # Parallel arrays: var_keys[i] / var_vals[i]; file_paths[i]
  local -a var_keys=() var_vals=() file_paths=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --workflow)
        [ $# -ge 2 ] || die 1 "--workflow requires an argument"
        workflow="$2"; shift 2 ;;
      --workflow=*)
        workflow="${1#--workflow=}"; shift ;;
      --step)
        [ $# -ge 2 ] || die 1 "--step requires an argument"
        step="$2"; shift 2 ;;
      --step=*)
        step="${1#--step=}"; shift ;;
      --var)
        [ $# -ge 2 ] || die 1 "--var requires key=val"
        case "$2" in
          *=*) var_keys+=("${2%%=*}"); var_vals+=("${2#*=}") ;;
          *)   die 1 "--var requires key=val (got: $2)" ;;
        esac
        shift 2 ;;
      --var=*)
        local kv="${1#--var=}"
        case "$kv" in
          *=*) var_keys+=("${kv%%=*}"); var_vals+=("${kv#*=}") ;;
          *)   die 1 "--var requires key=val (got: $kv)" ;;
        esac
        shift ;;
      --file)
        [ $# -ge 2 ] || die 1 "--file requires a path"
        file_paths+=("$2"); shift 2 ;;
      --file=*)
        file_paths+=("${1#--file=}"); shift ;;
      *)
        die 1 "unknown flag to write: $1" ;;
    esac
  done

  [ -n "$workflow" ] || die 1 "--workflow is required"
  [ -n "$step" ]     || die 1 "--step is required"
  case "$step" in
    ''|*[!0-9]*) die 1 "--step must be a non-negative integer (got: $step)" ;;
  esac
  validate_workflow_name "$workflow"

  # Validate every --file is readable BEFORE opening any output — EC2.
  local p
  for p in "${file_paths[@]:-}"; do
    [ -n "$p" ] || continue
    if [ ! -e "$p" ]; then
      die 1 "cannot read $p: no such file"
    fi
    if [ ! -r "$p" ]; then
      die 1 "cannot read $p: permission denied"
    fi
  done

  resolve_checkpoint_path
  mkdir -p "$CHECKPOINT_PATH"

  local target="$CHECKPOINT_PATH/$workflow.yaml"
  local lockfile="$CHECKPOINT_PATH/$workflow.yaml.lock"
  local tmpfile="$target.tmp.$$"

  # Acquire flock on the lockfile. Serializes concurrent writers — AC6.
  # `flock -w 5` waits up to 5 seconds; timeout exits 1 per spec.
  local flock_bin
  flock_bin=$(command -v flock || true)

  write_body() {
    local ts; ts=$(iso_utc_now)
    {
      printf 'workflow: '; yaml_scalar "$workflow"; printf '\n'
      printf 'step: %s\n' "$step"
      printf 'timestamp: %s\n' "$ts"
      if [ "${#var_keys[@]}" -gt 0 ]; then
        printf 'variables:\n'
        local i=0
        while [ $i -lt "${#var_keys[@]}" ]; do
          printf '  %s: ' "${var_keys[$i]}"
          yaml_scalar "${var_vals[$i]}"
          printf '\n'
          i=$((i + 1))
        done
      else
        printf 'variables: {}\n'
      fi
      if [ "${#file_paths[@]}" -gt 0 ] && [ -n "${file_paths[0]:-}" ]; then
        printf 'files_touched:\n'
        local fp hex mt
        for fp in "${file_paths[@]}"; do
          [ -n "$fp" ] || continue
          hex=$(file_sha256 "$fp")
          mt=$(file_mtime_utc "$fp")
          printf '  - path: '; yaml_scalar "$fp"; printf '\n'
          printf '    sha256: "sha256:%s"\n' "$hex"
          printf '    last_modified: %s\n' "$mt"
        done
      else
        printf 'files_touched: []\n'
      fi
    } > "$tmpfile"
    mv -f "$tmpfile" "$target"
  }

  if [ -n "$flock_bin" ]; then
    # Use a subshell with FD 9 bound to the lockfile.
    (
      exec 9>"$lockfile"
      if ! "$flock_bin" -w 5 9; then
        die 1 "flock timeout acquiring $lockfile"
      fi
      write_body
    )
  else
    # Fallback for systems without flock (rare on macOS — ships via util-linux
    # on Linux; macOS 10.15+ via Homebrew). Best-effort exclusive create lock.
    local tries=0
    while ! ( set -C; : > "$lockfile" ) 2>/dev/null; do
      tries=$((tries + 1))
      [ $tries -ge 50 ] && die 1 "lock timeout acquiring $lockfile"
      sleep 0.1 2>/dev/null || sleep 1
    done
    # shellcheck disable=SC2064
    trap "rm -f '$lockfile'" EXIT
    write_body
    rm -f "$lockfile"
    trap - EXIT
  fi
}

# ---------- Subcommand: read ----------

cmd_read() {
  local workflow=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --workflow)    [ $# -ge 2 ] || die 1 "--workflow requires an argument"; workflow="$2"; shift 2 ;;
      --workflow=*)  workflow="${1#--workflow=}"; shift ;;
      *) die 1 "unknown flag to read: $1" ;;
    esac
  done
  [ -n "$workflow" ] || die 1 "--workflow is required"
  validate_workflow_name "$workflow"
  resolve_checkpoint_path
  local target="$CHECKPOINT_PATH/$workflow.yaml"
  if [ ! -f "$target" ]; then
    printf '%s: checkpoint not found: %s\n' "$SCRIPT_NAME" "$target" >&2
    exit 2
  fi
  cat "$target"
}

# ---------- Subcommand: validate ----------

# Extract files_touched entries from a checkpoint file. Prints one path per line
# followed by a tab and the recorded sha256 hex (without the "sha256:" prefix).
parse_files_touched() {
  local file="$1"
  # shellcheck disable=SC2016
  awk '
    BEGIN { in_ft = 0; path = ""; sha = "" }
    /^files_touched:[[:space:]]*\[\][[:space:]]*$/ { in_ft = 0; next }
    /^files_touched:[[:space:]]*$/ { in_ft = 1; next }
    /^[a-zA-Z_]/ { in_ft = 0 }
    in_ft && /^[[:space:]]*-[[:space:]]*path:[[:space:]]*/ {
      # flush previous
      if (path != "" && sha != "") { print path "\t" sha; path = ""; sha = "" }
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*path:[[:space:]]*/, "", line)
      # strip surrounding quotes
      if (line ~ /^".*"$/) { line = substr(line, 2, length(line)-2); gsub(/\\"/, "\"", line); gsub(/\\\\/, "\\", line) }
      path = line
    }
    in_ft && /^[[:space:]]*sha256:[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*sha256:[[:space:]]*/, "", line)
      if (line ~ /^".*"$/) { line = substr(line, 2, length(line)-2) }
      sub(/^sha256:/, "", line)
      sha = line
    }
    END { if (path != "" && sha != "") print path "\t" sha }
  ' "$file"
}

cmd_validate() {
  local workflow=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --workflow)    [ $# -ge 2 ] || die 1 "--workflow requires an argument"; workflow="$2"; shift 2 ;;
      --workflow=*)  workflow="${1#--workflow=}"; shift ;;
      *) die 1 "unknown flag to validate: $1" ;;
    esac
  done
  [ -n "$workflow" ] || die 1 "--workflow is required"
  validate_workflow_name "$workflow"
  resolve_checkpoint_path
  local target="$CHECKPOINT_PATH/$workflow.yaml"
  if [ ! -f "$target" ]; then
    printf '%s: checkpoint not found: %s\n' "$SCRIPT_NAME" "$target" >&2
    exit 2
  fi

  local entries drift missing
  entries=$(parse_files_touched "$target") || true
  drift=""
  missing=""

  if [ -n "$entries" ]; then
    # Read entries line by line — tab-separated path \t sha.
    while IFS=$'\t' read -r path recorded; do
      [ -n "$path" ] || continue
      if [ ! -e "$path" ]; then
        missing="${missing}${path}"$'\n'
        continue
      fi
      local actual
      actual=$(file_sha256 "$path" || printf '')
      if [ "$actual" != "$recorded" ]; then
        drift="${drift}${path}"$'\n'
      fi
    done <<EOF
$entries
EOF
  fi

  # Missing takes precedence (exit 2) per AC4.
  if [ -n "$missing" ]; then
    printf '%s' "$missing" | while IFS= read -r p; do
      [ -n "$p" ] && printf '%s: missing file: %s\n' "$SCRIPT_NAME" "$p" >&2
    done
    exit 2
  fi
  if [ -n "$drift" ]; then
    printf '%s' "$drift" | while IFS= read -r p; do
      [ -n "$p" ] && printf '%s: drift: %s\n' "$SCRIPT_NAME" "$p" >&2
    done
    exit 1
  fi
  exit 0
}

# ---------- Dispatcher ----------

main() {
  if [ $# -eq 0 ]; then
    usage
    exit 1
  fi
  local sub="$1"; shift
  case "$sub" in
    write)    cmd_write    "$@" ;;
    read)     cmd_read     "$@" ;;
    validate) cmd_validate "$@" ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      printf '%s: unknown subcommand: %s\n' "$SCRIPT_NAME" "$sub" >&2
      usage
      exit 1 ;;
  esac
}

main "$@"
