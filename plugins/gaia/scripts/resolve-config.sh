#!/usr/bin/env bash
# resolve-config.sh — GAIA foundation script (E28-S9, extended by E28-S142, E28-S191)
set -euo pipefail
LC_ALL=C
export LC_ALL
#
# Reads up to two input files and merges them:
#   - team-shared:  .gaia/config/project-config.yaml  (canonical per ADR-111;
#                   legacy config/project-config.yaml retained as fallback
#                   on pre-migration installs — see precedence list below)
#   - machine-local: .gaia/config/global.yaml         (canonical per ADR-111;
#                   legacy config/global.yaml retained as fallback)
#
# Shared path discovery precedence (E28-S191 / AC1, extended by AI-2026-05-13-12;
# .gaia/config/ canonical added per ADR-111):
#   1. --shared <path>           explicit flag wins
#   2. --config <path>           legacy alias from E28-S9 single-file mode
#   3. $GAIA_SHARED_CONFIG       env override
#   4. $CLAUDE_PROJECT_ROOT/.gaia/config/project-config.yaml  (canonical, ADR-111)
#   4b. $CLAUDE_PROJECT_ROOT/config/project-config.yaml       (legacy fallback)
#   5. $PWD/.gaia/config/project-config.yaml                  (canonical, ADR-111)
#   5b. $PWD/config/project-config.yaml                       (legacy fallback)
#   5c. parent-of-$PWD/.gaia/config/project-config.yaml       (walk-up canonical)
#   5d. parent-of-$PWD/config/project-config.yaml             (walk-up legacy; stops at / or $HOME)
#   6. $CLAUDE_SKILL_DIR/config/project-config.yaml           (legacy, bats fixtures)
#
# Local overlay discovery precedence (E28-S191 / AC2, extended by AI-2026-05-13-12;
# .gaia/config/ canonical added per ADR-111):
#   1. --local <path>            explicit flag
#   2. $GAIA_LOCAL_CONFIG        env override
#   3. $CLAUDE_PROJECT_ROOT/.gaia/config/global.yaml          (canonical, ADR-111)
#   3b. $CLAUDE_PROJECT_ROOT/config/global.yaml               (legacy fallback)
#   4. $PWD/.gaia/config/global.yaml                          (canonical, ADR-111)
#   4b. $PWD/config/global.yaml                               (legacy fallback)
#   4c. parent-of-$PWD/.gaia/config/global.yaml               (walk-up canonical)
#   4d. parent-of-$PWD/config/global.yaml                     (walk-up legacy; stops at / or $HOME)
#   5. $CLAUDE_SKILL_DIR/config/global.yaml                   (legacy, bats fixtures)
#
# Applies GAIA_* environment overrides on top, validates required fields,
# and emits deterministic output on stdout:
#   - default:        KEY='VALUE' lines, single-quoted, alpha-sorted
#   - --format json:  a single JSON object with the same keys
#   - --field <key>:  prints ONLY the resolved scalar for that dotted key
#                     and exits 0. Currently scoped to E57-S1 lookup keys:
#                       dev_story.tdd_review.threshold
#                       dev_story.tdd_review.phases
#                       dev_story.tdd_review.qa_auto_in_yolo
#                       dev_story.tdd_review.qa_timeout_seconds
#   - --all:          E60-S5 batch mode. Emits the full flat-key surface
#                     (artifact paths, sizing_map.{S,M,L,XL},
#                     dev_story.tdd_review.*, val_integration.*) in a
#                     single fork, in shell-eval format. Recommended for
#                     skills that read 3+ keys — replaces N forks with 1.
#   - --cache:        E60-S5 opt-in session-scoped cache. Combined with
#                     --all, populates ${TMPDIR}/gaia-config-cache-<sid>.eval
#                     on first call and re-uses it on subsequent calls
#                     within the same session. Cache is invalidated when
#                     the source project-config.yaml or global.yaml mtime
#                     changes. Equivalent env: GAIA_CONFIG_CACHE=1.
#   - sizing_map:     positional block-query (E61-S1 / ADR-074 contract C1).
#                     Emits four canonical key=value lines: S=…, M=…, L=…,
#                     XL=… for the resolved sizing_map block (project >
#                     global per ADR-044 §10.26.3). Falls back to the
#                     framework defaults (S=2, M=5, L=8, XL=13) when the
#                     project layer does not declare a sizing_map block.
#
# =============================================================================
# Config Split Merge (ADR-044 / E28-S141 / E28-S142, post-ADR-111)
# =============================================================================
# Two-file merge with strict precedence: env > local > shared.
# 1. Load the team-shared file (.gaia/config/project-config.yaml — canonical
#    per ADR-111; legacy config/project-config.yaml as fallback) first as the
#    base layer. Missing → empty base layer (AC4 graceful fallback).
# 2. Overlay the machine-local file (.gaia/config/global.yaml — canonical per
#    ADR-111; legacy config/global.yaml as fallback). Missing → no overlay.
# 3. Apply GAIA_* environment variables last; env wins over both layers.
#
# Flat merge on top-level keys — the resolver already flattens nested keys
# (e.g., val_integration.template_output_review) to dotted form, so the
# overlay happens at the flattened-key level. No structural deep-merge.
#
# See:
#   - gaia-public/plugins/gaia/config/project-config.schema.yaml (schema)
#   - gaia-public/plugins/gaia/config/MIGRATION-from-global-yaml.md
#   - architecture.md §10.26.6 (Config Split Diagram), §Decision Log ADR-044
# =============================================================================
#
# POSIX discipline: the only non-POSIX constructs tolerated in this file are
# [[ ... ]] tests and Bash indexed arrays; every other construct stays POSIX.
# The shebang is bash because this project standardizes on bash foundation
# scripts (ADR-048). LC_ALL=C pins sort order and locale for determinism.
# Intentionally avoids associative arrays so macOS /bin/bash 3.2 can run it.
#
# Required fields (checked on the merged, post-env map):
#   project_root, project_path, memory_path, checkpoint_path,
#   installed_path, framework_version, date,
#   test_artifacts, planning_artifacts, implementation_artifacts,
#   creative_artifacts
#   Placeholder-detection guard (E29-S9, AF-2026-05-01-2 / AF-2026-05-01-1):
#     each of the 11 required fields above is also rejected if its resolved
#     value contains a literal `{...}` template token (e.g., `{project-root}`).
#     Shell-style `${VAR}` references are NOT rejected — they are a legitimate
#     fixture-config convention where env overrides supply the resolved value.
#     Defense-in-depth resolver-layer companion to E29-S8 (migrator-side fix).
#
# Artifact-dir keys (E28-S200 + E46-S9 — unblocks audit harnesses and
# the /gaia-product-brief pre_start gate):
#   test_artifacts, planning_artifacts, implementation_artifacts, and
#   creative_artifacts are the canonical docs/ subdirectory paths the
#   audit harness + skill setup.sh scripts expect. Defaults resolve
#   relative to project_root:
#     test_artifacts           = {project_root}/.gaia/artifacts/test-artifacts
#     planning_artifacts       = {project_root}/.gaia/artifacts/planning-artifacts
#     implementation_artifacts = {project_root}/.gaia/artifacts/implementation-artifacts
#     creative_artifacts       = {project_root}/.gaia/artifacts/creative-artifacts
#   project-config.yaml may override each; GAIA_* env vars win over both.
#   See E28-S197 triage §2a + E46-S9 for context.
#
# Environment overrides (env wins over file values):
#   GAIA_PROJECT_ROOT              → project_root
#   GAIA_PROJECT_PATH              → project_path
#   GAIA_MEMORY_PATH               → memory_path
#   GAIA_CHECKPOINT_PATH           → checkpoint_path
#   GAIA_TEST_ARTIFACTS            → test_artifacts
#   GAIA_PLANNING_ARTIFACTS        → planning_artifacts
#   GAIA_IMPLEMENTATION_ARTIFACTS  → implementation_artifacts
#   GAIA_CREATIVE_ARTIFACTS        → creative_artifacts
#
# Exit codes:
#   0 — success, all required fields resolved
#   2 — user/config error (missing file, missing field, parse error,
#       path traversal in project_path, no config path provided)
#
# Latency budget: <100ms on developer laptop (shell fast path; yq optional).
# Consumed by: every GAIA-native skill and downstream foundation script
# at startup — replaces the LLM-driven `.resolved/*.yaml` inheritance chain.

# ---------- Helpers ----------

die() {
  printf 'resolve-config: %s\n' "$1" >&2
  exit 2
}

shell_escape() {
  # Emit a single-quoted shell-safe literal. Embedded ' → '\''.
  local s="$1"
  local escaped
  escaped=$(printf '%s' "$s" | sed "s/'/'\\\\''/g")
  printf "'%s'" "$escaped"
}

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

parse_yaml_key() {
  # parse_yaml_key <file> <key> — print top-level flat key value, or empty.
  local file="$1" key="$2" line value
  [ -f "$file" ] || return 0
  line=$(grep -E "^${key}[[:space:]]*:" "$file" 2>/dev/null | head -n1 || true)
  [ -z "$line" ] && return 0
  value=${line#*:}
  # trim leading whitespace
  value=${value#"${value%%[![:space:]]*}"}
  # trim trailing whitespace
  value=${value%"${value##*[![:space:]]}"}
  # strip balanced surrounding quotes
  case "$value" in
    \"*\") value=${value#\"}; value=${value%\"} ;;
    \'*\') value=${value#\'}; value=${value%\'} ;;
  esac
  printf '%s' "$value"
}

parse_yaml_nested_key() {
  # parse_yaml_nested_key <file> <parent> <child> — print the value of
  # `parent.child` where the YAML looks like:
  #   parent:
  #     child: value
  # Prints empty if the key is absent. Handles single-line comments.
  local file="$1" parent="$2" child="$3"
  [ -f "$file" ] || return 0
  awk -v P="$parent" -v C="$child" '
    BEGIN { in_parent=0 }
    # End of the parent block: a new non-indented key line.
    /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:/ {
      if (in_parent) { in_parent=0 }
    }
    $0 ~ "^"P"[[:space:]]*:[[:space:]]*$" { in_parent=1; next }
    in_parent && $0 ~ "^[[:space:]]+"C"[[:space:]]*:" {
      line=$0
      sub(/^[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:[[:space:]]*/, "", line)
      sub(/[[:space:]]+$/, "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      # strip balanced surrounding quotes
      if (line ~ /^".*"$/) { line=substr(line, 2, length(line)-2) }
      else if (line ~ /^\x27.*\x27$/) { line=substr(line, 2, length(line)-2) }
      print line
      exit
    }
  ' "$file"
}

parse_yaml_inline_list() {
  # parse_yaml_inline_list <file> <key> — print a top-level inline-list value
  # (e.g., `key: [a, b, c]`) as a comma-separated string with no brackets.
  # Prints empty if the key is absent or not an inline list. Used by E68-S1
  # for sections like `platforms: [web, ios]` and `compliance.regimes: [...]`.
  local file="$1" key="$2" line value
  [ -f "$file" ] || return 0
  line=$(grep -E "^${key}[[:space:]]*:[[:space:]]*\[" "$file" 2>/dev/null | head -n1 || true)
  [ -z "$line" ] && return 0
  # Extract content between [ and ]
  value=${line#*[}
  value=${value%%]*}
  # trim whitespace around commas: turn ", " into "," for stable joining
  value=$(printf '%s' "$value" | sed 's/[[:space:]]*,[[:space:]]*/,/g; s/^[[:space:]]*//; s/[[:space:]]*$//')
  printf '%s' "$value"
}

parse_yaml_nested_inline_list() {
  # parse_yaml_nested_inline_list <file> <parent> <child> — read an inline
  # list value at parent.child level: parent: \n   child: [a, b, c]
  local file="$1" parent="$2" child="$3"
  [ -f "$file" ] || return 0
  awk -v P="$parent" -v C="$child" '
    BEGIN { in_parent=0 }
    /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:/ {
      if (in_parent) { in_parent=0 }
    }
    $0 ~ "^"P"[[:space:]]*:[[:space:]]*$" { in_parent=1; next }
    in_parent && $0 ~ "^[[:space:]]+"C"[[:space:]]*:[[:space:]]*\\[" {
      line=$0
      sub(/^[^\[]*\[/, "", line)
      sub(/\].*$/, "", line)
      gsub(/[[:space:]]*,[[:space:]]*/, ",", line)
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      print line
      exit
    }
  ' "$file"
}

parse_yaml_doubly_nested_key() {
  # parse_yaml_doubly_nested_key <file> <grandparent> <parent> <child>
  # Prints the value of grandparent.parent.child where the YAML looks like:
  #   grandparent:
  #     parent:
  #       child: value
  # Prints empty if absent. Handles single-line comments. E57-S1.
  local file="$1" grandparent="$2" parent="$3" child="$4"
  [ -f "$file" ] || return 0
  awk -v G="$grandparent" -v P="$parent" -v C="$child" '
    BEGIN { in_grand=0; in_parent=0 }
    # New zero-indent key — close any open grand block (and parent inside it).
    /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:/ {
      if (in_grand) { in_grand=0; in_parent=0 }
    }
    $0 ~ "^"G"[[:space:]]*:[[:space:]]*$" { in_grand=1; in_parent=0; next }
    in_grand && $0 ~ "^[[:space:]]+"P"[[:space:]]*:[[:space:]]*$" { in_parent=1; next }
    # Two-space-indent (parent-level) key that is not P closes any open parent.
    in_grand && in_parent && /^[[:space:]]{1,2}[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:/ {
      # Close parent only if this is at the parent indent level (<=2 leading spaces).
      lead = match($0, /[^[:space:]]/) - 1
      if (lead <= 2) { in_parent=0 }
    }
    in_grand && in_parent && $0 ~ "^[[:space:]]+"C"[[:space:]]*:" {
      line=$0
      sub(/^[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:[[:space:]]*/, "", line)
      sub(/[[:space:]]+$/, "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      if (line ~ /^".*"$/) { line=substr(line, 2, length(line)-2) }
      else if (line ~ /^\x27.*\x27$/) { line=substr(line, 2, length(line)-2) }
      print line
      exit
    }
  ' "$file"
}

validate_yaml_basic() {
  local file="$1"
  [ -f "$file" ] || return 0
  # Reject unclosed bracket on a value line.
  if grep -qE '^[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*:[[:space:]]*\[[^]]*$' "$file"; then
    return 1
  fi
  # Reject lines with multiple bare colons — breaks flat-key invariant.
  if grep -qE '^[[:space:]]*[^#[:space:]].*:[[:space:]]*:[[:space:]]*:' "$file"; then
    return 1
  fi
  return 0
}

# validate_schema — E28-S18 / ADR-044 enforcement.
# Reads project-config.schema.yaml (sibling of the config file by default,
# or overridden via --schema) and rejects any top-level key in the config
# file that is not declared under `fields:` in the schema. Unknown keys
# exit with code 2 and a clear stderr message per AC5.
validate_schema() {
  local config="$1" schema="$2"
  [ -f "$config" ] || return 0  # no config → nothing to validate
  [ -f "$schema" ] || return 0  # schema optional — silent no-op if absent
  # Extract declared field names from schema: lines matching "  <name>:"
  # exactly two-space-indented inside the fields: block.
  local allowed
  allowed=$(awk '
    /^fields:[[:space:]]*$/ { in_fields=1; next }
    in_fields && /^[^[:space:]]/ { in_fields=0 }
    in_fields && /^  [a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*$/ {
      gsub(/^  /,""); gsub(/:.*/,""); print
    }
  ' "$schema")
  # Extract top-level keys from config: zero-indent "<name>:" lines,
  # skipping comments and blanks.
  local config_keys
  config_keys=$(awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /^[a-zA-Z_][a-zA-Z0-9_]*:/ {
      k=$0; sub(/:.*/,"",k); print k
    }
  ' "$config")
  local key
  for key in $config_keys; do
    if ! printf '%s\n' "$allowed" | grep -qx "$key"; then
      printf 'resolve-config: unknown field in %s: %s (not declared in %s)\n' \
        "$config" "$key" "$schema" >&2
      exit 2
    fi
  done
}

# ---------- Argument parsing ----------
#
# New in E28-S142 — two-file merge:
#   --shared <path>   team-shared project-config.yaml (default: CLAUDE_SKILL_DIR/config/project-config.yaml)
#   --local <path>    machine-local global.yaml (no default — omitted when absent)
#
# Legacy alias (E28-S9 single-file mode):
#   --config <path>   equivalent to --shared <path>; kept for backward compat.

SHARED_PATH=""
SHARED_PATH_VIA_SHARED=""   # populated by --shared only (L1 precedence)
SHARED_PATH_VIA_CONFIG=""   # populated by --config only (L2 legacy alias)
LOCAL_PATH=""
SCHEMA_PATH=""
FORMAT="shell"
FIELD=""                    # E57-S1 — single-field lookup mode
POSITIONAL_QUERY=""         # E61-S1 — positional block-query mode (e.g. `sizing_map`)
EMIT_ALL=0                  # E60-S5 — --all batch mode
USE_CACHE=0                 # E60-S5 — opt-in session-scoped cache

while [ $# -gt 0 ]; do
  case "$1" in
    --shared)
      [ $# -ge 2 ] || die "flag --shared requires a path argument"
      SHARED_PATH_VIA_SHARED="$2"; shift 2 ;;
    --shared=*)
      SHARED_PATH_VIA_SHARED="${1#--shared=}"; shift ;;
    --local)
      [ $# -ge 2 ] || die "flag --local requires a path argument"
      LOCAL_PATH="$2"; shift 2 ;;
    --local=*)
      LOCAL_PATH="${1#--local=}"; shift ;;
    --config)
      [ $# -ge 2 ] || die "flag --config requires a path argument"
      SHARED_PATH_VIA_CONFIG="$2"; shift 2 ;;
    --config=*)
      SHARED_PATH_VIA_CONFIG="${1#--config=}"; shift ;;
    --schema)
      [ $# -ge 2 ] || die "flag --schema requires a path argument"
      SCHEMA_PATH="$2"; shift 2 ;;
    --schema=*)
      SCHEMA_PATH="${1#--schema=}"; shift ;;
    --format)
      [ $# -ge 2 ] || die "flag --format requires shell|json"
      FORMAT="$2"; shift 2 ;;
    --format=*)
      FORMAT="${1#--format=}"; shift ;;
    --field)
      [ $# -ge 2 ] || die "flag --field requires a dotted-key argument"
      FIELD="$2"; shift 2 ;;
    --field=*)
      FIELD="${1#--field=}"; shift ;;
    --all)
      # E60-S5 — batch mode: emit the full flat-key surface in a single
      # fork. Output mirrors the default `shell` format but is gated by an
      # explicit flag so the default CLI is byte-stable for legacy callers.
      EMIT_ALL=1; shift ;;
    --cache)
      # E60-S5 — opt-in session-scoped cache. Cache file path:
      #   ${TMPDIR:-/tmp}/gaia-config-cache-${session_id}.eval
      # session_id derives from $GAIA_SESSION_ID then $PPID. Cache is
      # invalidated when the source config files' mtimes change.
      USE_CACHE=1; shift ;;
    -h|--help)
      sed -n '1,101p' "$0" >&2; exit 0 ;;
    sizing_map)
      # E61-S1 — positional block-query: emit four S/M/L/XL key=value lines
      # for the resolved sizing_map block (project > global precedence per
      # ADR-074 contract C1 / ADR-044 §10.26.3).
      POSITIONAL_QUERY="sizing_map"; shift ;;
    planning_artifacts|implementation_artifacts|test_artifacts|creative_artifacts|project_config_path)
      # E60-S2 — positional flat-key query for the four artifact-path
      # keys added by E60-S1. Emits ONLY the resolved scalar to stdout
      # with exit 0 (per Work Item 2 AC2 / story Test Scenarios #1–#5).
      # Project-config.yaml override beats the framework default per
      # ADR-044 §10.26.3 (project > global). Mirrors the sizing_map
      # positional-query pattern but returns a single value (flat key,
      # not a block).
      #
      # E71-S8 (AC1) extends the positional-key set with `project_config_path`
      # — a synthetic key (no schema backing) that resolves to
      # `<project_root>/config/project-config.yaml`. Pattern mirrors the
      # `memory_path` / `checkpoint_path` synthetic-key convention emitted
      # under --all. The synthetic-key value backs the documented happy-path
      # command in every /gaia-config-* SKILL.md Step 1.
      POSITIONAL_QUERY="$1"; shift ;;
    *)
      die "unknown argument: $1" ;;
  esac
done

case "$FORMAT" in
  shell|json) ;;
  *) die "unsupported --format '$FORMAT' (expected shell|json)" ;;
esac

# E60-S5 — env override to opt into the cache without passing --cache.
if [ "${GAIA_CONFIG_CACHE:-}" = "1" ]; then
  USE_CACHE=1
fi

# ---------- E60-S5 — cache fast-path ----------
#
# Session-scoped cache that holds the last `--all` shell-eval output keyed on
# the project + global config file mtimes. Read-side fast path: when --all and
# --cache (or GAIA_CONFIG_CACHE=1) are set AND a valid cache file exists, emit
# its body directly and exit — skipping every parse/merge step below. Saves
# ~140ms cold-fork tax per call on a standard host (per ADR-044 / E60-S3).
#
# Format: a header line `# mtime=<digest>` followed by the shell-eval body.
# The digest combines mtimes of every input file the resolver actually read,
# so touching either project-config.yaml or global.yaml busts the cache.
#
# Path traversal mitigation: the session id is sanitized to alphanumerics +
# hyphens before being interpolated into the cache file path.

stat_mtime() {
  # Portable mtime read: BSD stat (-f %m) on macOS, GNU stat (-c %Y) elsewhere.
  local f="$1"
  [ -f "$f" ] || { printf '%s' ""; return; }
  stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || printf '%s' ""
}

cache_session_id() {
  # Sanitize to a safe filename token (alnum + dash). Falls back to PPID.
  local raw="${GAIA_SESSION_ID:-$PPID}"
  printf '%s' "$raw" | tr -c 'A-Za-z0-9-' '_'
}

cache_file_path() {
  local tmp="${TMPDIR:-/tmp}"
  # Strip trailing slash to keep the joined path deterministic.
  tmp="${tmp%/}"
  printf '%s/gaia-config-cache-%s.eval' "$tmp" "$(cache_session_id)"
}

cache_digest() {
  # Combine mtimes of the discovered input files into a single digest line.
  local s_mt l_mt
  s_mt=$(stat_mtime "${SHARED_PATH:-}")
  l_mt=$(stat_mtime "${LOCAL_PATH:-}")
  printf 's=%s;l=%s' "$s_mt" "$l_mt"
}

# ---------- Shared-file discovery (E28-S191 / AC1) ----------
#
# 6-level precedence ladder. A flag or env wins unconditionally (levels 1-3);
# the file-system fallbacks (levels 4-6) only win if the candidate file is
# actually present, so missing project-level configs never mask the legacy
# CLAUDE_SKILL_DIR fallback used by the bats fixture suite.

# L1 / L2: --shared wins over --config (legacy alias), irrespective of order
# on the command line. Early-returns before any env/fs fallback runs.
if [ -n "$SHARED_PATH_VIA_SHARED" ]; then
  SHARED_PATH="$SHARED_PATH_VIA_SHARED"
elif [ -n "$SHARED_PATH_VIA_CONFIG" ]; then
  SHARED_PATH="$SHARED_PATH_VIA_CONFIG"
fi

if [ -z "$SHARED_PATH" ] && [ -n "${GAIA_SHARED_CONFIG:-}" ]; then
  SHARED_PATH="$GAIA_SHARED_CONFIG"
fi
# E96-S1 (ADR-111): prefer `.gaia/config/project-config.yaml` over legacy
# `config/project-config.yaml`. When the legacy path is the only one present,
# we still resolve to it (transition window) but emit a one-time deprecation
# WARNING on stderr suggesting the migration command.
_gaia_legacy_warn() {
  if [ -z "${_GAIA_LEGACY_CONFIG_WARNED:-}" ]; then
    printf 'resolve-config: DEPRECATION WARNING: %s\n' \
      "legacy config/project-config.yaml in use — run plugins/gaia/scripts/migrate/migrate-phase-1.sh to relocate to .gaia/config/ (ADR-111)" >&2
    _GAIA_LEGACY_CONFIG_WARNED=1
    export _GAIA_LEGACY_CONFIG_WARNED
  fi
}

if [ -z "$SHARED_PATH" ] && [ -n "${CLAUDE_PROJECT_ROOT:-}" ]; then
  if [ -f "${CLAUDE_PROJECT_ROOT}/.gaia/config/project-config.yaml" ]; then
    SHARED_PATH="${CLAUDE_PROJECT_ROOT}/.gaia/config/project-config.yaml"
  elif [ -f "${CLAUDE_PROJECT_ROOT}/config/project-config.yaml" ]; then
    SHARED_PATH="${CLAUDE_PROJECT_ROOT}/config/project-config.yaml"
    _gaia_legacy_warn
  fi
fi
if [ -z "$SHARED_PATH" ]; then
  if [ -f "${PWD}/.gaia/config/project-config.yaml" ]; then
    SHARED_PATH="${PWD}/.gaia/config/project-config.yaml"
  elif [ -f "${PWD}/config/project-config.yaml" ]; then
    SHARED_PATH="${PWD}/config/project-config.yaml"
    _gaia_legacy_warn
  fi
fi
# L4b (AI-2026-05-13-12): walk-up discovery when CWD is a sub-directory of
# project root. The Claude Code skill harness invokes `!setup.sh` from a CWD
# that may drift below project root (e.g., the dev runs a command from a
# nested workspace folder). Walk parent directories from $PWD until we hit a
# config/project-config.yaml or the filesystem root. Stops at $HOME and / to
# avoid traversing system paths.
#
# Skipped when CLAUDE_SKILL_DIR or GAIA_NO_PROJECT_WALKUP is set so unit
# tests and legacy bats-fixture flows can deterministically exercise the
# CLAUDE_SKILL_DIR fallback path without leaking the real project config
# from a bats-runner CWD that happens to live inside a real project tree.
if [ -z "$SHARED_PATH" ] && [ -z "${CLAUDE_SKILL_DIR:-}" ] && [ -z "${GAIA_NO_PROJECT_WALKUP:-}" ]; then
  _gaia_walk_dir="$PWD"
  while [ "$_gaia_walk_dir" != "/" ] && [ "$_gaia_walk_dir" != "${HOME:-/nonexistent}" ]; do
    _gaia_walk_dir="$(dirname "$_gaia_walk_dir")"
    if [ -f "${_gaia_walk_dir}/.gaia/config/project-config.yaml" ]; then
      SHARED_PATH="${_gaia_walk_dir}/.gaia/config/project-config.yaml"
      break
    elif [ -f "${_gaia_walk_dir}/config/project-config.yaml" ]; then
      SHARED_PATH="${_gaia_walk_dir}/config/project-config.yaml"
      _gaia_legacy_warn
      break
    fi
  done
  unset _gaia_walk_dir
fi
if [ -z "$SHARED_PATH" ] && [ -n "${CLAUDE_SKILL_DIR:-}" ]; then
  SHARED_PATH="${CLAUDE_SKILL_DIR}/config/project-config.yaml"
fi

# ---------- Local-overlay discovery (E28-S191 / AC2) ----------
#
# Mirrors the shared ladder minus the --config legacy alias (which has always
# been shared-only). A missing overlay is a soft no-op per E28-S142 / AC4.

if [ -z "$LOCAL_PATH" ] && [ -n "${GAIA_LOCAL_CONFIG:-}" ]; then
  LOCAL_PATH="$GAIA_LOCAL_CONFIG"
fi
if [ -z "$LOCAL_PATH" ] \
   && [ -n "${CLAUDE_PROJECT_ROOT:-}" ] \
   && [ -f "${CLAUDE_PROJECT_ROOT}/config/global.yaml" ]; then
  LOCAL_PATH="${CLAUDE_PROJECT_ROOT}/config/global.yaml"
fi
if [ -z "$LOCAL_PATH" ] && [ -f "${PWD}/config/global.yaml" ]; then
  LOCAL_PATH="${PWD}/config/global.yaml"
fi
# Walk-up discovery for global.yaml mirrors the shared-path walk above
# (AI-2026-05-13-12). Soft-fails if no global.yaml is found — overlay is
# optional per E28-S142 / AC4. Skipped when CLAUDE_SKILL_DIR or
# GAIA_NO_PROJECT_WALKUP is set for the same test-isolation reason.
if [ -z "$LOCAL_PATH" ] && [ -z "${CLAUDE_SKILL_DIR:-}" ] && [ -z "${GAIA_NO_PROJECT_WALKUP:-}" ]; then
  _gaia_walk_dir="$PWD"
  while [ "$_gaia_walk_dir" != "/" ] && [ "$_gaia_walk_dir" != "${HOME:-/nonexistent}" ]; do
    _gaia_walk_dir="$(dirname "$_gaia_walk_dir")"
    if [ -f "${_gaia_walk_dir}/config/global.yaml" ]; then
      LOCAL_PATH="${_gaia_walk_dir}/config/global.yaml"
      break
    fi
  done
  unset _gaia_walk_dir
fi
if [ -z "$LOCAL_PATH" ] \
   && [ -n "${CLAUDE_SKILL_DIR:-}" ] \
   && [ -f "${CLAUDE_SKILL_DIR}/config/global.yaml" ]; then
  LOCAL_PATH="${CLAUDE_SKILL_DIR}/config/global.yaml"
fi

# ---------- Detect "at least one input is present" ----------
#
# When both inputs are absent, fall back to the legacy AC-EC6 error so
# existing behavior is preserved (required CLAUDE_SKILL_DIR or --config).

SHARED_EXISTS=0
LOCAL_EXISTS=0
[ -n "$SHARED_PATH" ] && [ -f "$SHARED_PATH" ] && SHARED_EXISTS=1
[ -n "$LOCAL_PATH" ]  && [ -f "$LOCAL_PATH" ]  && LOCAL_EXISTS=1

if [ "$SHARED_EXISTS" -eq 0 ] && [ "$LOCAL_EXISTS" -eq 0 ]; then
  # Neither input resolvable — preserve existing error semantics.
  if [ -n "$SHARED_PATH" ]; then
    die "config file not found: $SHARED_PATH"
  elif [ -n "$LOCAL_PATH" ]; then
    die "config file not found: $LOCAL_PATH"
  else
    die "no config path — set CLAUDE_SKILL_DIR or pass --config <path>"
  fi
fi

# ---------- E60-S5 cache read fast-path ----------
#
# Only --all + --cache use the cache (single-key callers retain byte-stable
# legacy behavior). When a fresh cache file matches the source mtimes, dump
# its body and exit — bypassing parse, merge, env-override, and emit.
if [ "$EMIT_ALL" -eq 1 ] && [ "$USE_CACHE" -eq 1 ]; then
  CACHE_FILE=$(cache_file_path)
  if [ -f "$CACHE_FILE" ]; then
    expected_digest=$(cache_digest)
    cached_digest=$(head -n1 "$CACHE_FILE" 2>/dev/null | sed -n 's/^# mtime=//p')
    if [ -n "$cached_digest" ] && [ "$cached_digest" = "$expected_digest" ]; then
      # Skip the header line, emit the body. Hot path — minimal work.
      tail -n +2 "$CACHE_FILE"
      exit 0
    fi
  fi
fi

# ---------- Parse validation (runs per-file so errors name the file) ----------

if [ "$SHARED_EXISTS" -eq 1 ] && ! validate_yaml_basic "$SHARED_PATH"; then
  die "parse error in $SHARED_PATH"
fi
if [ "$LOCAL_EXISTS" -eq 1 ] && ! validate_yaml_basic "$LOCAL_PATH"; then
  die "parse error in $LOCAL_PATH"
fi

# Schema enforcement on the shared file (authoritative schema surface).
# Default schema lives next to the shared file as project-config.schema.yaml.
if [ "$SHARED_EXISTS" -eq 1 ]; then
  if [ -z "$SCHEMA_PATH" ]; then
    SCHEMA_PATH="$(dirname "$SHARED_PATH")/project-config.schema.yaml"
  fi
  validate_schema "$SHARED_PATH" "$SCHEMA_PATH"
fi

# ---------- Merge layers: shared first, local overlays ----------
#
# Helper: read a flat top-level key from shared first, then prefer local if
# local defines it. Implemented as sequential reads because bash 3.2 has no
# associative arrays and the resolver's key surface is small & fixed.

merge_key() {
  local key="$1" v=""
  if [ "$SHARED_EXISTS" -eq 1 ]; then
    v=$(parse_yaml_key "$SHARED_PATH" "$key")
  fi
  if [ "$LOCAL_EXISTS" -eq 1 ]; then
    local lv
    lv=$(parse_yaml_key "$LOCAL_PATH" "$key")
    [ -n "$lv" ] && v="$lv"
  fi
  printf '%s' "$v"
}

merge_nested_key() {
  # merge_nested_key <parent> <child> — merge a YAML-nested key with the
  # same precedence rule as merge_key. Uses parse_yaml_nested_key so a
  # `parent:` block with `child: value` resolves correctly.
  local parent="$1" child="$2" v=""
  if [ "$SHARED_EXISTS" -eq 1 ]; then
    v=$(parse_yaml_nested_key "$SHARED_PATH" "$parent" "$child")
  fi
  if [ "$LOCAL_EXISTS" -eq 1 ]; then
    local lv
    lv=$(parse_yaml_nested_key "$LOCAL_PATH" "$parent" "$child")
    [ -n "$lv" ] && v="$lv"
  fi
  printf '%s' "$v"
}

v_checkpoint_path=$(merge_key checkpoint_path)
v_date=$(merge_key date)
v_framework_version=$(merge_key framework_version)
v_installed_path=$(merge_key installed_path)
v_memory_path=$(merge_key memory_path)
v_project_path=$(merge_key project_path)
v_project_root=$(merge_key project_root)

# E28-S200 — artifact-dir keys (unblocks E28-S195 audit-harness gating).
# These must be resolved after project_root so the default-relative-to-root
# resolution below has a value to work with.
v_test_artifacts=$(merge_key test_artifacts)
v_planning_artifacts=$(merge_key planning_artifacts)
v_implementation_artifacts=$(merge_key implementation_artifacts)
v_creative_artifacts=$(merge_key creative_artifacts)

# Flattened nested keys — emitted as dotted keys so shell eval-friendly.
# Only val_integration.template_output_review is surfaced today; adding
# more flattened keys is a one-liner (future-proof).
v_val_integration_template_output_review=$(merge_nested_key val_integration template_output_review)

# E61-S1 / ADR-074 contract C1 — sizing_map at the project layer with
# project > global precedence per ADR-044 §10.26.3.
#
# Resolution: read each S/M/L/XL key from the shared (project-config.yaml)
# layer only; if absent, fall back to the canonical Fibonacci defaults
# (S=2, M=5, L=8, XL=13) that match the legacy framework global.yaml.
#
# The local overlay (config/global.yaml) is intentionally NOT consulted for
# sizing_map — sizing_map is a project-level concern, not a machine-local
# one. This is what "project > global" means in ADR-074 contract C1: the
# project-config.yaml block supersedes the framework-shipped defaults.
sizing_map_default_S=2
sizing_map_default_M=5
sizing_map_default_L=8
sizing_map_default_XL=13

v_sizing_map_S=""
v_sizing_map_M=""
v_sizing_map_L=""
v_sizing_map_XL=""
SIZING_MAP_PROJECT_SET=0
if [ "$SHARED_EXISTS" -eq 1 ]; then
  v_sizing_map_S=$(parse_yaml_nested_key  "$SHARED_PATH" sizing_map S)
  v_sizing_map_M=$(parse_yaml_nested_key  "$SHARED_PATH" sizing_map M)
  v_sizing_map_L=$(parse_yaml_nested_key  "$SHARED_PATH" sizing_map L)
  v_sizing_map_XL=$(parse_yaml_nested_key "$SHARED_PATH" sizing_map XL)
fi
if [ -n "$v_sizing_map_S" ] || [ -n "$v_sizing_map_M" ] \
   || [ -n "$v_sizing_map_L" ] || [ -n "$v_sizing_map_XL" ]; then
  SIZING_MAP_PROJECT_SET=1
fi
[ -z "$v_sizing_map_S" ]  && v_sizing_map_S="$sizing_map_default_S"
[ -z "$v_sizing_map_M" ]  && v_sizing_map_M="$sizing_map_default_M"
[ -z "$v_sizing_map_L" ]  && v_sizing_map_L="$sizing_map_default_L"
[ -z "$v_sizing_map_XL" ] && v_sizing_map_XL="$sizing_map_default_XL"

# E57-S1 — dev_story.tdd_review.* doubly-nested resolution.
# Reads the user-set value (if any) from shared then local, then applies
# the schema-declared default when neither layer set the key. Defaults:
#   threshold: medium     (enum off|low|medium|high)
#   phases: [red]         (array)
#   qa_auto_in_yolo: true (bool)
#   qa_timeout_seconds: 600 (int)

merge_doubly_nested_key() {
  # merge_doubly_nested_key <grandparent> <parent> <child>
  local grandparent="$1" parent="$2" child="$3" v=""
  if [ "$SHARED_EXISTS" -eq 1 ]; then
    v=$(parse_yaml_doubly_nested_key "$SHARED_PATH" "$grandparent" "$parent" "$child")
  fi
  if [ "$LOCAL_EXISTS" -eq 1 ]; then
    local lv
    lv=$(parse_yaml_doubly_nested_key "$LOCAL_PATH" "$grandparent" "$parent" "$child")
    [ -n "$lv" ] && v="$lv"
  fi
  printf '%s' "$v"
}

v_dev_story_tdd_review_threshold=$(merge_doubly_nested_key dev_story tdd_review threshold)
v_dev_story_tdd_review_phases=$(merge_doubly_nested_key dev_story tdd_review phases)
v_dev_story_tdd_review_qa_auto_in_yolo=$(merge_doubly_nested_key dev_story tdd_review qa_auto_in_yolo)
v_dev_story_tdd_review_qa_timeout_seconds=$(merge_doubly_nested_key dev_story tdd_review qa_timeout_seconds)

# Defaults (applied when no layer set a value).
[ -z "$v_dev_story_tdd_review_threshold" ]          && v_dev_story_tdd_review_threshold="medium"
[ -z "$v_dev_story_tdd_review_phases" ]             && v_dev_story_tdd_review_phases="[red]"
[ -z "$v_dev_story_tdd_review_qa_auto_in_yolo" ]    && v_dev_story_tdd_review_qa_auto_in_yolo="true"
[ -z "$v_dev_story_tdd_review_qa_timeout_seconds" ] && v_dev_story_tdd_review_qa_timeout_seconds="600"

# Enum validation for threshold (AC3). Allowed: off|low|medium|high.
case "$v_dev_story_tdd_review_threshold" in
  off|low|medium|high) ;;
  *) die "invalid value for dev_story.tdd_review.threshold: '$v_dev_story_tdd_review_threshold' (allowed: off|low|medium|high)" ;;
esac

# =============================================================================
# E68-S1 — Eleven new top-level sections (FR-RSV2-5..22)
# =============================================================================
# compliance, tools, test_execution, severity, gates, stacks,
# cross_service_tests, environments, ci_platform, platforms, device_targets.
#
# Resolution surfaces only the most-used scalar / list paths so downstream
# consumers can call `--field <path>` for the keys they actually need. All
# sections are absence-tolerant — when a section is not declared in either
# layer, the resolver emits nothing (preserves byte-stability for legacy
# callers per ADR-074 contract C1).
#
# The merge precedence mirrors the existing pattern (env > local > shared).
# No GAIA_* env overrides are wired for these sections in E68-S1; downstream
# stories may add per-section overrides as they need them.

merge_inline_list() {
  # merge_inline_list <key> — top-level inline-list, project > global precedence.
  local key="$1" v=""
  if [ "$SHARED_EXISTS" -eq 1 ]; then
    v=$(parse_yaml_inline_list "$SHARED_PATH" "$key")
  fi
  if [ "$LOCAL_EXISTS" -eq 1 ]; then
    local lv
    lv=$(parse_yaml_inline_list "$LOCAL_PATH" "$key")
    [ -n "$lv" ] && v="$lv"
  fi
  printf '%s' "$v"
}

merge_nested_inline_list() {
  # merge_nested_inline_list <parent> <child>
  local parent="$1" child="$2" v=""
  if [ "$SHARED_EXISTS" -eq 1 ]; then
    v=$(parse_yaml_nested_inline_list "$SHARED_PATH" "$parent" "$child")
  fi
  if [ "$LOCAL_EXISTS" -eq 1 ]; then
    local lv
    lv=$(parse_yaml_nested_inline_list "$LOCAL_PATH" "$parent" "$child")
    [ -n "$lv" ] && v="$lv"
  fi
  printf '%s' "$v"
}

# compliance.* — regimes (list), domain (scalar), ui_present (bool).
v_compliance_regimes=$(merge_nested_inline_list compliance regimes)
v_compliance_domain=$(merge_nested_key compliance domain)
v_compliance_ui_present=$(merge_nested_key compliance ui_present)

# test_execution_bridge.bridge_enabled — toggle read by /gaia-bridge-enable
# and /gaia-bridge-disable per gaia-bridge-toggle SKILL.md Step 1. The key
# may be absent when test_execution_bridge: was hydrated by reconcile-v2
# with only a comment block; consumers should treat empty output as `false`
# per the SKILL.md AC-EC3 contract (AF-2026-05-17-6).
v_test_execution_bridge_bridge_enabled=$(merge_nested_key test_execution_bridge bridge_enabled)

# tools.{category}.provider — common categories surfaced; others reachable
# via ad-hoc dotted-key lookup if needed by future callers.
v_tools_sast_provider=$(merge_doubly_nested_key tools sast provider)
v_tools_secrets_provider=$(merge_doubly_nested_key tools secrets provider)
v_tools_sca_provider=$(merge_doubly_nested_key tools sca provider)

# test_execution.tier_{1,2,3}.placement
v_test_execution_tier_1_placement=$(merge_doubly_nested_key test_execution tier_1 placement)
v_test_execution_tier_2_placement=$(merge_doubly_nested_key test_execution tier_2 placement)
v_test_execution_tier_3_placement=$(merge_doubly_nested_key test_execution tier_3 placement)

# severity.{Critical,High,Medium,Low,Info}
v_severity_Critical=$(merge_nested_key severity Critical)
v_severity_High=$(merge_nested_key severity High)
v_severity_Medium=$(merge_nested_key severity Medium)
v_severity_Low=$(merge_nested_key severity Low)
v_severity_Info=$(merge_nested_key severity Info)

# cross_service_tests scalars
v_cross_service_tests_contract_dir=$(merge_nested_key cross_service_tests contract_dir)
v_cross_service_tests_integration_dir=$(merge_nested_key cross_service_tests integration_dir)

# ci_platform.{provider,pipeline}
v_ci_platform_provider=$(merge_nested_key ci_platform provider)
v_ci_platform_pipeline=$(merge_nested_key ci_platform pipeline)

# platforms — top-level inline list.
v_platforms=$(merge_inline_list platforms)

# E77-S1 / FR-403 / ADR-087 — project_kind top-level scalar. Open-vocabulary
# string with project > global precedence. Soft-warn on unknown values (does
# NOT block); silent when the field is omitted (backward compat).
v_project_kind=$(merge_key project_kind)
if [ -n "$v_project_kind" ]; then
  case "$v_project_kind" in
    claude-code-plugin|web-app|mobile-app|api|library) : ;;
    *)
      printf 'resolve-config.sh: warning: unknown project_kind "%s" — recognized values: claude-code-plugin, web-app, mobile-app, api, library (accepted as extensible per ADR-087)\n' "$v_project_kind" >&2
      ;;
  esac
fi

# E74-S1 / AC6 — soft-warn on unknown platform identifiers. The schema
# enforces the strict enum (web|ios|android), but a project on a stale
# schema-version that uses a newer identifier (e.g., `harmonyos`) MUST NOT
# be blocked by the resolver. Emit a single-line stderr warning per
# unknown identifier and continue. Documented identifiers stay silent.
if [ -n "$v_platforms" ]; then
  IFS=',' read -r -a _gaia_pl_arr <<< "$v_platforms"
  for _pl in "${_gaia_pl_arr[@]}"; do
    [ -z "$_pl" ] && continue
    case "$_pl" in
      web|ios|android) : ;;
      *) printf 'resolve-config.sh: warning: unknown platform identifier "%s" — accepted as extensible per ADR-081\n' "$_pl" >&2 ;;
    esac
  done
  unset _gaia_pl_arr _pl
fi

# device_targets — full structural section (E74-S1 / FR-RSV2-27).
# Bash regex parsing is the wrong tool for an arbitrarily-nested YAML object;
# `device_targets.<platform>.{os_versions,screen_sizes,form_factors}` is
# read structurally via python3 + PyYAML when available and emitted into the
# `--format json` output as `$.device_targets`. The section is *structural*
# (not flattened), so `--field device_targets` and `--all` deliberately do
# NOT surface it — downstream callers consume the JSON form. When python3
# or PyYAML are missing, the helper returns an empty string and the JSON
# emitter omits the key — backward-compat with E68-S1's stub behavior is
# preserved (no key in resolved JSON when nothing surfaceable).
#
# Precedence mirrors the rest of the resolver: project layer (LOCAL) wins
# over the team-shared layer (SHARED) on the entire `device_targets` block.
extract_device_targets_json() {
  local file="$1"
  [ -f "$file" ] || return 0
  # Fast path: cheap grep before paying python-import cost. The grep matches
  # a top-level `device_targets:` line — false positives (e.g., the same
  # token inside a quoted string) are rare in practice and the python parser
  # rejects them gracefully via the `doc.get('device_targets')` lookup.
  grep -qE '^device_targets:' "$file" 2>/dev/null || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -c "import yaml" 2>/dev/null || return 0
  python3 - "$file" <<'PY' 2>/dev/null || true
import sys, json, yaml
try:
    with open(sys.argv[1], 'r') as f:
        doc = yaml.safe_load(f) or {}
except Exception:
    sys.exit(0)
dt = doc.get('device_targets')
if dt is None:
    sys.exit(0)
print(json.dumps(dt, default=str))
PY
}
v_device_targets_json=""
if [ "$LOCAL_EXISTS" -eq 1 ]; then
  v_device_targets_json=$(extract_device_targets_json "$LOCAL_PATH")
fi
if [ -z "$v_device_targets_json" ] && [ "$SHARED_EXISTS" -eq 1 ]; then
  v_device_targets_json=$(extract_device_targets_json "$SHARED_PATH")
fi

# stacks / environments / gates are structural sections; we do not flatten
# them in v1. Downstream callers requiring full structural access should
# consume the YAML directly or use --format json.

# ---------- Apply environment overrides (env wins) ----------

[ -n "${GAIA_PROJECT_ROOT:-}" ]    && v_project_root="$GAIA_PROJECT_ROOT"
[ -n "${GAIA_PROJECT_PATH:-}" ]    && v_project_path="$GAIA_PROJECT_PATH"
[ -n "${GAIA_MEMORY_PATH:-}" ]     && v_memory_path="$GAIA_MEMORY_PATH"
[ -n "${GAIA_CHECKPOINT_PATH:-}" ] && v_checkpoint_path="$GAIA_CHECKPOINT_PATH"

# E28-S200 — artifact-dir env overrides. Applied BEFORE default resolution
# so an env-provided value wins over the generated {project_root}/docs/…
# fallback below.
[ -n "${GAIA_TEST_ARTIFACTS:-}" ]            && v_test_artifacts="$GAIA_TEST_ARTIFACTS"
[ -n "${GAIA_PLANNING_ARTIFACTS:-}" ]        && v_planning_artifacts="$GAIA_PLANNING_ARTIFACTS"
[ -n "${GAIA_IMPLEMENTATION_ARTIFACTS:-}" ]  && v_implementation_artifacts="$GAIA_IMPLEMENTATION_ARTIFACTS"
[ -n "${GAIA_CREATIVE_ARTIFACTS:-}" ]        && v_creative_artifacts="$GAIA_CREATIVE_ARTIFACTS"

# E28-S200 — default each artifact-dir key to {project_root}/docs/<dir>
# when neither a config file value nor a GAIA_* env override supplied one.
# Runs AFTER env overrides so an explicit empty value from env never falls
# through to the default (env overrides use -n so only non-empty wins).
#
# E96-S6 hotfix (ADR-111): prefer .gaia/artifacts/<subdir>/ over the legacy
# docs/<subdir>/ default whenever the .gaia/ layout is present on disk.
# Sweeps every downstream consumer to the new layout without per-script changes.
_artifact_default() {
  local subdir="$1"
  if [ -d "${v_project_root}/.gaia/artifacts/${subdir}" ]; then
    printf '%s' "${v_project_root}/.gaia/artifacts/${subdir}"
  else
    printf '%s' "${v_project_root}/docs/${subdir}"
  fi
}
[ -z "$v_test_artifacts" ]           && v_test_artifacts="$(_artifact_default test-artifacts)"
[ -z "$v_planning_artifacts" ]       && v_planning_artifacts="$(_artifact_default planning-artifacts)"
[ -z "$v_implementation_artifacts" ] && v_implementation_artifacts="$(_artifact_default implementation-artifacts)"
[ -z "$v_creative_artifacts" ]       && v_creative_artifacts="$(_artifact_default creative-artifacts)"

# ---------- Required-field check (post-merge, post-env) ----------

[ -z "$v_checkpoint_path" ]          && die "missing required field: checkpoint_path"
[ -z "$v_date" ]                     && die "missing required field: date"
[ -z "$v_framework_version" ]        && die "missing required field: framework_version"
[ -z "$v_installed_path" ]           && die "missing required field: installed_path"
[ -z "$v_memory_path" ]              && die "missing required field: memory_path"
[ -z "$v_project_path" ]             && die "missing required field: project_path"
[ -z "$v_project_root" ]             && die "missing required field: project_root"
# E28-S200 — artifact-dir required fields. These always resolve because the
# default block above populates them from {project_root}/docs/… when nothing
# else supplied a value. The explicit checks stay for parity with the rest
# of the required-field surface and to catch any future regression where
# the default block is bypassed (e.g., someone sets them to empty string).
[ -z "$v_test_artifacts" ]           && die "missing required field: test_artifacts"
[ -z "$v_planning_artifacts" ]       && die "missing required field: planning_artifacts"
[ -z "$v_implementation_artifacts" ] && die "missing required field: implementation_artifacts"
[ -z "$v_creative_artifacts" ]       && die "missing required field: creative_artifacts"

# ---------- Framework version drift detection (E86-S2) ----------
#
# FR-470, FR-473, NFR-063, ADR-102, SR-55, SR-57.
#
# Compare the resolved `$v_framework_version` (project-config.yaml) against
# the installed plugin's version (from `.claude-plugin/plugin.json`, via the
# E86-S1 shared library `lib/framework-version.sh`). When they differ, write
# an atomic stale marker at `_memory/.framework-version-stale` and emit a
# single stderr WARNING. The marker is advisory — `/gaia-help` (E86-S4)
# reads it to render the post-update state; nothing here gates execution.
#
# Performance budget (NFR-063): warm-cache path is a single `stat` on the
# session-keyed sentinel `_memory/.framework-version-checked-{plugin_ver}`.
# Cold-cache path: resolve_framework_version (cached after first source) +
# one sentinel stat + one atomic marker write. Target: ≤5ms warm, ≤50ms cold.
#
# Failure tolerance (SR-57): `_memory/` may not exist (first run, CI ephemeral
# env). All writes are wrapped in failure-tolerant guards. The hook MUST NOT
# cause `resolve-config.sh` to exit non-zero.
_RC_SCRIPT_DIR_E86="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$_RC_SCRIPT_DIR_E86/lib/framework-version.sh"

_drift_detect() {
  local _plugin_ver _sentinel_path _stale_path _tmp_path
  # E86-S5 / AC4-AC7 — full-skip guard via GAIA_SKIP_VERSION_CHECK=1.
  # This is the FIRST check in the hook — short-circuits before any I/O
  # (no version lookup, no sentinel stat, no marker write, no warning).
  # Per AC5 + AC6 the value MUST be exactly "1" — `0`/`false`/empty are
  # treated as unset. Per AC7 this takes precedence over CI suppression.
  [ "${GAIA_SKIP_VERSION_CHECK:-}" = "1" ] && return 0
  # Set the recursion-guard env var so resolve_framework_version (which
  # prefers resolve-config.sh when available) skips the preferred path
  # and falls back to plugin.json directly. Without this guard,
  # resolve-config.sh would recursively invoke itself.
  GAIA_FW_VER_IN_RESOLVER=1 _plugin_ver=$(resolve_framework_version 2>/dev/null) || return 0
  [ -z "$_plugin_ver" ] && return 0
  _sentinel_path="${v_memory_path:-.}/.framework-version-checked-${_plugin_ver}"
  # Warm-cache fast path (NFR-063): one stat, ≤5ms target.
  [ -f "$_sentinel_path" ] && return 0
  _stale_path="${v_memory_path:-.}/.framework-version-stale"
  # AC3 / defense-in-depth: empty config version → skip silently.
  # Today the L923 required-field die fires first, so this branch is
  # dead code in production. It stays as defense-in-depth for future
  # schema relaxation or env-override edge cases.
  if [ -z "$v_framework_version" ]; then
    touch "$_sentinel_path" 2>/dev/null || true
    return 0
  fi
  # AC2 (string inequality, not semver — story is explicit).
  if [ "$v_framework_version" != "$_plugin_ver" ]; then
    _tmp_path="${_stale_path}.tmp.$$"
    # AC6 (SR-55 atomic write): tempfile + mv.
    # NOTE: the redirection-failure error from `> "$_tmp_path"` is emitted by
    # the SHELL itself (not by printf), so `2>/dev/null` after printf does
    # NOT suppress it. Wrap the entire { ... > tmp; } block so the shell's
    # redirection-failure error is captured by the outer `2>/dev/null`.
    if { printf 'stale_since=%s installed=%s config=%s\n' \
           "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_plugin_ver" "$v_framework_version" \
           > "$_tmp_path"; } 2>/dev/null && mv "$_tmp_path" "$_stale_path" 2>/dev/null; then
      # AC10 (E86-S2): single-line WARNING to stderr, only on successful
      # marker write.
      # E86-S5 / AC1-AC3 — CI suppression: suppress the WARNING ONLY when
      # BOTH CI=true AND non-TTY (the canonical "CI build agent" context).
      # Marker still written; sentinel still touched. The suppression
      # affects ONLY the stderr emit line on this branch; non-CI scripts
      # (cron, batch shells) STILL see the warning.
      if ! { [ "${CI:-}" = "true" ] && [ ! -t 1 ]; }; then
        printf '[gaia] framework drift: config was generated by v%s, plugin is v%s. Run /gaia-help for guidance.\n' \
          "$v_framework_version" "$_plugin_ver" >&2
      fi
    else
      # AC7 / SR-57: tolerate failure SILENTLY. The marker's absence is
      # itself the signal — emitting a DEBUG line on stderr would (a) be
      # noise on every resolve-config.sh call from a stripped-down env
      # (e.g., CI without _memory/, test fixtures), and (b) pollute the
      # `$output` capture of `bats run` for tests that pre-existed E86-S2.
      rm -f "$_tmp_path" 2>/dev/null || true
    fi
  else
    # E86-S3 / FR-474 / AC1 — self-healing clear. When versions match
    # and a stale marker exists from a previous drifted run, remove it
    # so the user no longer sees the drift warning after fixing the
    # config (via /gaia-migrate, manual edit, or /gaia-init --full).
    # The `[ -f ]` guard is intent-revealing + observability-friendly
    # (the `rm` syscall fires only when there is real work to do).
    # AC2 idempotency is automatic via `rm -f`. AC5 (SR-57) tolerates
    # write failure: emit a DEBUG-level message to stderr on actual
    # failure (rare — requires e.g. chmod 000 on the marker file or a
    # read-only filesystem) and continue. The brace-group + outer
    # `2>/dev/null` captures any shell-level stderr (consistent with
    # the E86-S2 redirection-fix pattern); the `||` branch emits a
    # single explicit DEBUG line only on real failure.
    if [ -f "$_stale_path" ]; then
      if ! { rm -f "$_stale_path"; } 2>/dev/null; then
        printf '[gaia:debug] marker clear failed (permission denied or read-only filesystem)\n' >&2
      fi
    fi
  fi
  # AC9: touch sentinel at end (whether drift, clear, or no-op). Tolerate failure.
  touch "$_sentinel_path" 2>/dev/null || true
}
_drift_detect
unset -f _drift_detect

# ---------- E29-S9 placeholder-detection guard ----------
#
# AF-2026-05-01-2 / AF-2026-05-01-1 (defense-in-depth companion to E29-S8):
# reject any required field whose resolved value still contains a literal
# `{...}`-style template token. The non-empty checks above only catch absent
# values — a value that BE a literal placeholder
# (e.g., `project_root: "{project-root}"`) passes the non-empty check and
# silently flows into mkdir / sed / find / checkpoint.sh consumers, where the
# symptom shows up far from the cause (a literal `{project-root}/` directory
# in the wrong cwd, story files written under nonsensical paths — see PR #387
# commit `767b29e` and PR #404 cleanup).
#
# The pattern `*"{"*"}"*` is intentionally generic — any `{...}` token is
# caught, not just `{project-root}`. The migrator (E29-S8) keeps its detector
# narrow; the resolver (this guard) keeps it generic because it is the last
# line of defense before downstream consumers see the value. Runs AFTER env
# overrides AND AFTER artifact-dir defaulting so a placeholder introduced by
# ANY source layer (file, env, default) is caught.
#
# Shell-style `${VAR}` references are intentionally NOT rejected here — they
# are a legitimate convention in fixture configs where the field is supplied
# by an env override that has already resolved by this point. Only literal
# `{...}` template tokens (with no leading `$`) trigger the guard. The check
# runs against a copy with `${...}` segments stripped so braces inside a
# `${...}` reference cannot mask a real placeholder elsewhere in the value.
for ph_check in \
  "project_root|$v_project_root" \
  "project_path|$v_project_path" \
  "memory_path|$v_memory_path" \
  "checkpoint_path|$v_checkpoint_path" \
  "installed_path|$v_installed_path" \
  "framework_version|$v_framework_version" \
  "date|$v_date" \
  "test_artifacts|$v_test_artifacts" \
  "planning_artifacts|$v_planning_artifacts" \
  "implementation_artifacts|$v_implementation_artifacts" \
  "creative_artifacts|$v_creative_artifacts"
do
  ph_field="${ph_check%%|*}"
  ph_value="${ph_check#*|}"
  # Strip shell-style ${...} references before the pattern match so they
  # don't trigger the generic `{...}` guard. Bash extended pattern is OK
  # here — the script's POSIX-discipline header allows [[ ... ]] tests and
  # bash arrays; parameter substitution with patterns is in the same tier.
  ph_stripped="${ph_value//\$\{*\}/}"
  case "$ph_stripped" in
    *"{"*"}"*) die "unsubstituted placeholder in $ph_field: $ph_value" ;;
  esac
done
unset ph_check ph_field ph_value ph_stripped

# ---------- Path-traversal guard on project_path ----------

case "$v_project_path" in
  *..*) die "path traversal rejected in project_path: $v_project_path" ;;
esac

# ---------- --field short-circuit (E57-S1) ----------
#
# When --field <dotted-key> is set, print ONLY that key's resolved scalar
# value to stdout (no quoting, single line, trailing newline) and exit 0.
# Unknown fields exit 2 with a clear stderr message.

if [ -n "$FIELD" ]; then
  case "$FIELD" in
    dev_story.tdd_review.threshold)
      printf '%s\n' "$v_dev_story_tdd_review_threshold" ;;
    dev_story.tdd_review.phases)
      printf '%s\n' "$v_dev_story_tdd_review_phases" ;;
    dev_story.tdd_review.qa_auto_in_yolo)
      printf '%s\n' "$v_dev_story_tdd_review_qa_auto_in_yolo" ;;
    dev_story.tdd_review.qa_timeout_seconds)
      printf '%s\n' "$v_dev_story_tdd_review_qa_timeout_seconds" ;;
    # E68-S1 — eleven new sections (FR-RSV2-5..22)
    compliance.regimes)
      printf '%s\n' "$v_compliance_regimes" ;;
    compliance.domain)
      printf '%s\n' "$v_compliance_domain" ;;
    compliance.ui_present)
      printf '%s\n' "$v_compliance_ui_present" ;;
    tools.sast.provider)
      printf '%s\n' "$v_tools_sast_provider" ;;
    tools.secrets.provider)
      printf '%s\n' "$v_tools_secrets_provider" ;;
    tools.sca.provider)
      printf '%s\n' "$v_tools_sca_provider" ;;
    test_execution.tier_1.placement)
      printf '%s\n' "$v_test_execution_tier_1_placement" ;;
    test_execution.tier_2.placement)
      printf '%s\n' "$v_test_execution_tier_2_placement" ;;
    test_execution.tier_3.placement)
      printf '%s\n' "$v_test_execution_tier_3_placement" ;;
    # AF-2026-05-17-6 — bridge toggle key (consumers treat empty as `false`
    # per gaia-bridge-toggle SKILL.md AC-EC3).
    test_execution_bridge.bridge_enabled)
      printf '%s\n' "$v_test_execution_bridge_bridge_enabled" ;;
    severity.Critical)
      printf '%s\n' "$v_severity_Critical" ;;
    severity.High)
      printf '%s\n' "$v_severity_High" ;;
    severity.Medium)
      printf '%s\n' "$v_severity_Medium" ;;
    severity.Low)
      printf '%s\n' "$v_severity_Low" ;;
    severity.Info)
      printf '%s\n' "$v_severity_Info" ;;
    cross_service_tests.contract_dir)
      printf '%s\n' "$v_cross_service_tests_contract_dir" ;;
    cross_service_tests.integration_dir)
      printf '%s\n' "$v_cross_service_tests_integration_dir" ;;
    ci_platform.provider)
      printf '%s\n' "$v_ci_platform_provider" ;;
    ci_platform.pipeline)
      printf '%s\n' "$v_ci_platform_pipeline" ;;
    platforms)
      printf '%s\n' "$v_platforms" ;;
    project_kind)
      printf '%s\n' "$v_project_kind" ;;
    # E71-S8 (AC1) — synthetic key mirroring positional dispatch (see above).
    project_config_path)
      printf '%s\n' "${v_project_root}/config/project-config.yaml" ;;
    *)
      die "unknown field for --field: '$FIELD'" ;;
  esac
  exit 0
fi

# ---------- Positional block-query short-circuit (E61-S1) ----------
#
# `resolve-config.sh sizing_map` emits four canonical key=value lines for
# the resolved sizing_map block (project > global precedence per ADR-074
# contract C1 / ADR-044 §10.26.3). Output is consumed by callers like
# `gaia-sprint-plan` and (in E61-S2) `gaia-create-story` to derive points
# from a story size. Order S, M, L, XL is canonical for the t-shirt scale,
# not lexicographic.

if [ -n "$POSITIONAL_QUERY" ]; then
  case "$POSITIONAL_QUERY" in
    sizing_map)
      printf 'S=%s\n' "$v_sizing_map_S"
      printf 'M=%s\n' "$v_sizing_map_M"
      printf 'L=%s\n' "$v_sizing_map_L"
      printf 'XL=%s\n' "$v_sizing_map_XL"
      ;;
    # E60-S2 — flat artifact-path keys emit ONLY the resolved scalar
    # (single line, trailing newline). Order matches the canonical
    # E60-S1 schema block: planning, implementation, test, creative.
    planning_artifacts)       printf '%s\n' "$v_planning_artifacts" ;;
    implementation_artifacts) printf '%s\n' "$v_implementation_artifacts" ;;
    test_artifacts)           printf '%s\n' "$v_test_artifacts" ;;
    creative_artifacts)       printf '%s\n' "$v_creative_artifacts" ;;
    # E71-S8 (AC1) — synthetic key, no schema backing. Resolves to
    # `<project_root>/config/project-config.yaml`. Backs the documented
    # happy-path command in every /gaia-config-* SKILL.md Step 1.
    project_config_path)      printf '%s\n' "${v_project_root}/config/project-config.yaml" ;;
    *)
      die "unknown positional query: '$POSITIONAL_QUERY'" ;;
  esac
  exit 0
fi

# ---------- Emit ----------

emit_pair_shell() {
  printf '%s=%s\n' "$1" "$(shell_escape "$2")"
}

# E60-S5 — when --all is set, capture the full shell-eval body to a buffer so
# we can both emit it on stdout and (optionally) write it to the cache file.
# When --all is NOT set, the legacy emit path runs unchanged below (FORMAT
# branch) — preserving byte-stability for every existing caller.

emit_all_body() {
  emit_pair_shell checkpoint_path          "$v_checkpoint_path"
  emit_pair_shell creative_artifacts       "$v_creative_artifacts"
  emit_pair_shell date                     "$v_date"
  emit_pair_shell framework_version        "$v_framework_version"
  emit_pair_shell implementation_artifacts "$v_implementation_artifacts"
  emit_pair_shell installed_path           "$v_installed_path"
  emit_pair_shell memory_path              "$v_memory_path"
  emit_pair_shell planning_artifacts       "$v_planning_artifacts"
  # E71-S8 (AC1) — synthetic key, no schema backing. Resolves to
  # `<project_root>/config/project-config.yaml`. Backs the documented
  # happy-path command in every /gaia-config-* SKILL.md Step 1.
  emit_pair_shell project_config_path      "${v_project_root}/config/project-config.yaml"
  emit_pair_shell project_path             "$v_project_path"
  emit_pair_shell project_root             "$v_project_root"
  # --all always emits sizing_map.{S,M,L,XL} so downstream batch consumers
  # have a complete key surface — even when the project layer did not
  # declare a sizing_map block. The default (non-batch) shell path still
  # gates these on SIZING_MAP_PROJECT_SET to preserve byte-stability.
  emit_pair_shell sizing_map.L  "$v_sizing_map_L"
  emit_pair_shell sizing_map.M  "$v_sizing_map_M"
  emit_pair_shell sizing_map.S  "$v_sizing_map_S"
  emit_pair_shell sizing_map.XL "$v_sizing_map_XL"
  emit_pair_shell test_artifacts           "$v_test_artifacts"
  if [ -n "$v_val_integration_template_output_review" ]; then
    emit_pair_shell val_integration.template_output_review \
      "$v_val_integration_template_output_review"
  fi
  # tdd_review.* — emitted under --all so dev-story consumers can read all
  # four keys from a single fork.
  emit_pair_shell dev_story.tdd_review.threshold          "$v_dev_story_tdd_review_threshold"
  emit_pair_shell dev_story.tdd_review.phases             "$v_dev_story_tdd_review_phases"
  emit_pair_shell dev_story.tdd_review.qa_auto_in_yolo    "$v_dev_story_tdd_review_qa_auto_in_yolo"
  emit_pair_shell dev_story.tdd_review.qa_timeout_seconds "$v_dev_story_tdd_review_qa_timeout_seconds"
  # E68-S1 — eleven new sections (FR-RSV2-5..22). Each key is emitted only
  # when the project actually set it; absent keys do not pollute the surface.
  [ -n "$v_compliance_regimes" ]                && emit_pair_shell compliance.regimes               "$v_compliance_regimes"
  [ -n "$v_compliance_domain" ]                 && emit_pair_shell compliance.domain                "$v_compliance_domain"
  [ -n "$v_compliance_ui_present" ]             && emit_pair_shell compliance.ui_present            "$v_compliance_ui_present"
  [ -n "$v_tools_sast_provider" ]               && emit_pair_shell tools.sast.provider              "$v_tools_sast_provider"
  [ -n "$v_tools_secrets_provider" ]            && emit_pair_shell tools.secrets.provider           "$v_tools_secrets_provider"
  [ -n "$v_tools_sca_provider" ]                && emit_pair_shell tools.sca.provider               "$v_tools_sca_provider"
  [ -n "$v_test_execution_tier_1_placement" ]   && emit_pair_shell test_execution.tier_1.placement  "$v_test_execution_tier_1_placement"
  [ -n "$v_test_execution_tier_2_placement" ]   && emit_pair_shell test_execution.tier_2.placement  "$v_test_execution_tier_2_placement"
  [ -n "$v_test_execution_tier_3_placement" ]   && emit_pair_shell test_execution.tier_3.placement  "$v_test_execution_tier_3_placement"
  [ -n "$v_severity_Critical" ]                 && emit_pair_shell severity.Critical                "$v_severity_Critical"
  [ -n "$v_severity_High" ]                     && emit_pair_shell severity.High                    "$v_severity_High"
  [ -n "$v_severity_Medium" ]                   && emit_pair_shell severity.Medium                  "$v_severity_Medium"
  [ -n "$v_severity_Low" ]                      && emit_pair_shell severity.Low                     "$v_severity_Low"
  [ -n "$v_severity_Info" ]                     && emit_pair_shell severity.Info                    "$v_severity_Info"
  [ -n "$v_cross_service_tests_contract_dir" ]  && emit_pair_shell cross_service_tests.contract_dir "$v_cross_service_tests_contract_dir"
  [ -n "$v_cross_service_tests_integration_dir" ] && emit_pair_shell cross_service_tests.integration_dir "$v_cross_service_tests_integration_dir"
  [ -n "$v_ci_platform_provider" ]              && emit_pair_shell ci_platform.provider             "$v_ci_platform_provider"
  [ -n "$v_ci_platform_pipeline" ]              && emit_pair_shell ci_platform.pipeline             "$v_ci_platform_pipeline"
  [ -n "$v_platforms" ]                         && emit_pair_shell platforms                        "$v_platforms"
  [ -n "$v_project_kind" ]                      && emit_pair_shell project_kind                     "$v_project_kind"
  # Guarantee the function exits with status 0 — `set -e` aborts the caller
  # when a command-substitution body returns non-zero (the chain above is
  # `[ -n ... ] && emit ...`, which exits 1 when the variable is empty).
  return 0
}

if [ "$EMIT_ALL" -eq 1 ]; then
  body=$(emit_all_body)
  printf '%s\n' "$body"
  if [ "$USE_CACHE" -eq 1 ]; then
    CACHE_FILE=$(cache_file_path)
    cache_dir=$(dirname "$CACHE_FILE")
    if mkdir -p "$cache_dir" 2>/dev/null; then
      tmp_cache="${CACHE_FILE}.tmp.$$"
      {
        printf '# mtime=%s\n' "$(cache_digest)"
        printf '%s\n' "$body"
      } > "$tmp_cache" 2>/dev/null && mv "$tmp_cache" "$CACHE_FILE" 2>/dev/null || \
        rm -f "$tmp_cache" 2>/dev/null
    fi
  fi
  exit 0
fi

if [ "$FORMAT" = "shell" ]; then
  # Alphabetical order, hard-coded to guarantee determinism. Flattened keys
  # are emitted only when they have a value so absent nested blocks do not
  # pollute the output surface.
  emit_pair_shell checkpoint_path          "$v_checkpoint_path"
  emit_pair_shell creative_artifacts       "$v_creative_artifacts"
  emit_pair_shell date                     "$v_date"
  emit_pair_shell framework_version        "$v_framework_version"
  emit_pair_shell implementation_artifacts "$v_implementation_artifacts"
  emit_pair_shell installed_path           "$v_installed_path"
  emit_pair_shell memory_path              "$v_memory_path"
  emit_pair_shell planning_artifacts       "$v_planning_artifacts"
  # E71-S8 (AC1) — synthetic key, no schema backing. Resolves to
  # `<project_root>/config/project-config.yaml`. Backs the documented
  # happy-path command in every /gaia-config-* SKILL.md Step 1.
  emit_pair_shell project_config_path      "${v_project_root}/config/project-config.yaml"
  emit_pair_shell project_path             "$v_project_path"
  emit_pair_shell project_root             "$v_project_root"
  # E61-S1 — sizing_map.{S,M,L,XL} emitted only when at least one sub-key
  # was set in the shared layer. Absent sizing_map blocks → no emission, so
  # the eval-friendly key surface stays clean for downstream consumers that
  # do not need the sizing map. Callers that need the sizing map should use
  # the positional `sizing_map` invocation form below (E61-S1 ADR-074 C1),
  # which always emits the four sub-keys (with defaults when unset).
  if [ "$SIZING_MAP_PROJECT_SET" -eq 1 ]; then
    emit_pair_shell sizing_map.L  "$v_sizing_map_L"
    emit_pair_shell sizing_map.M  "$v_sizing_map_M"
    emit_pair_shell sizing_map.S  "$v_sizing_map_S"
    emit_pair_shell sizing_map.XL "$v_sizing_map_XL"
  fi
  emit_pair_shell test_artifacts           "$v_test_artifacts"
  if [ -n "$v_val_integration_template_output_review" ]; then
    emit_pair_shell val_integration.template_output_review \
      "$v_val_integration_template_output_review"
  fi
else
  if command -v jq >/dev/null 2>&1; then
    # Build the base object (existing surface) and post-merge any of the
    # eleven new E68-S1 sections that were actually set in the project layer.
    # Using `+` object merge keeps the legacy keys byte-stable when no new
    # section is present.
    base_jq_args=(
      --arg checkpoint_path          "$v_checkpoint_path"
      --arg creative_artifacts       "$v_creative_artifacts"
      --arg date                     "$v_date"
      --arg framework_version        "$v_framework_version"
      --arg implementation_artifacts "$v_implementation_artifacts"
      --arg installed_path           "$v_installed_path"
      --arg memory_path              "$v_memory_path"
      --arg planning_artifacts       "$v_planning_artifacts"
      --arg project_path             "$v_project_path"
      --arg project_root             "$v_project_root"
      --arg test_artifacts           "$v_test_artifacts"
    )
    base_jq_filter='{checkpoint_path: $checkpoint_path, creative_artifacts: $creative_artifacts, date: $date, framework_version: $framework_version, implementation_artifacts: $implementation_artifacts, installed_path: $installed_path, memory_path: $memory_path, planning_artifacts: $planning_artifacts, project_path: $project_path, project_root: $project_root, test_artifacts: $test_artifacts}'
    if [ -n "$v_val_integration_template_output_review" ]; then
      base_jq_args+=( --arg val_template_output_review "$v_val_integration_template_output_review" )
      base_jq_filter='{checkpoint_path: $checkpoint_path, creative_artifacts: $creative_artifacts, date: $date, framework_version: $framework_version, implementation_artifacts: $implementation_artifacts, installed_path: $installed_path, memory_path: $memory_path, planning_artifacts: $planning_artifacts, project_path: $project_path, project_root: $project_root, test_artifacts: $test_artifacts, "val_integration.template_output_review": $val_template_output_review}'
    fi

    # Build a JSON object for the new E68-S1 sections that are populated.
    # Each section appears under its top-level key only when at least one
    # of its sub-keys was set. Builds a jq filter dynamically so we can
    # use --argjson for arrays / booleans where needed.
    new_sections_jq='{}'
    new_sections_args=()
    if [ -n "$v_compliance_regimes" ] || [ -n "$v_compliance_domain" ] \
       || [ -n "$v_compliance_ui_present" ]; then
      compliance_obj='{}'
      if [ -n "$v_compliance_regimes" ]; then
        # Convert comma-separated list to JSON array via jq.
        regimes_json=$(printf '%s' "$v_compliance_regimes" | jq -R 'split(",") | map(select(length > 0))')
        new_sections_args+=( --argjson compliance_regimes "$regimes_json" )
        compliance_obj=$(printf '%s' "$compliance_obj" | jq '. + {regimes: $compliance_regimes}' --argjson compliance_regimes "$regimes_json")
      fi
      if [ -n "$v_compliance_domain" ]; then
        compliance_obj=$(printf '%s' "$compliance_obj" | jq --arg v "$v_compliance_domain" '. + {domain: $v}')
      fi
      if [ -n "$v_compliance_ui_present" ]; then
        compliance_obj=$(printf '%s' "$compliance_obj" | jq --arg v "$v_compliance_ui_present" '. + {ui_present: $v}')
      fi
      new_sections_jq=$(printf '%s' "$new_sections_jq" | jq --argjson v "$compliance_obj" '. + {compliance: $v}')
    fi
    if [ -n "$v_tools_sast_provider" ] || [ -n "$v_tools_secrets_provider" ] \
       || [ -n "$v_tools_sca_provider" ]; then
      tools_obj='{}'
      [ -n "$v_tools_sast_provider" ] && tools_obj=$(printf '%s' "$tools_obj" | jq --arg v "$v_tools_sast_provider" '. + {sast: {provider: $v}}')
      [ -n "$v_tools_secrets_provider" ] && tools_obj=$(printf '%s' "$tools_obj" | jq --arg v "$v_tools_secrets_provider" '. + {secrets: {provider: $v}}')
      [ -n "$v_tools_sca_provider" ] && tools_obj=$(printf '%s' "$tools_obj" | jq --arg v "$v_tools_sca_provider" '. + {sca: {provider: $v}}')
      new_sections_jq=$(printf '%s' "$new_sections_jq" | jq --argjson v "$tools_obj" '. + {tools: $v}')
    fi
    if [ -n "$v_test_execution_tier_1_placement" ] \
       || [ -n "$v_test_execution_tier_2_placement" ] \
       || [ -n "$v_test_execution_tier_3_placement" ]; then
      te_obj='{}'
      [ -n "$v_test_execution_tier_1_placement" ] && te_obj=$(printf '%s' "$te_obj" | jq --arg v "$v_test_execution_tier_1_placement" '. + {tier_1: {placement: $v}}')
      [ -n "$v_test_execution_tier_2_placement" ] && te_obj=$(printf '%s' "$te_obj" | jq --arg v "$v_test_execution_tier_2_placement" '. + {tier_2: {placement: $v}}')
      [ -n "$v_test_execution_tier_3_placement" ] && te_obj=$(printf '%s' "$te_obj" | jq --arg v "$v_test_execution_tier_3_placement" '. + {tier_3: {placement: $v}}')
      new_sections_jq=$(printf '%s' "$new_sections_jq" | jq --argjson v "$te_obj" '. + {test_execution: $v}')
    fi
    if [ -n "$v_severity_Critical" ] || [ -n "$v_severity_High" ] \
       || [ -n "$v_severity_Medium" ] || [ -n "$v_severity_Low" ] \
       || [ -n "$v_severity_Info" ]; then
      sev_obj='{}'
      [ -n "$v_severity_Critical" ] && sev_obj=$(printf '%s' "$sev_obj" | jq --arg v "$v_severity_Critical" '. + {Critical: $v}')
      [ -n "$v_severity_High" ]     && sev_obj=$(printf '%s' "$sev_obj" | jq --arg v "$v_severity_High"     '. + {High: $v}')
      [ -n "$v_severity_Medium" ]   && sev_obj=$(printf '%s' "$sev_obj" | jq --arg v "$v_severity_Medium"   '. + {Medium: $v}')
      [ -n "$v_severity_Low" ]      && sev_obj=$(printf '%s' "$sev_obj" | jq --arg v "$v_severity_Low"      '. + {Low: $v}')
      [ -n "$v_severity_Info" ]     && sev_obj=$(printf '%s' "$sev_obj" | jq --arg v "$v_severity_Info"     '. + {Info: $v}')
      new_sections_jq=$(printf '%s' "$new_sections_jq" | jq --argjson v "$sev_obj" '. + {severity: $v}')
    fi
    if [ -n "$v_cross_service_tests_contract_dir" ] \
       || [ -n "$v_cross_service_tests_integration_dir" ]; then
      cst_obj='{}'
      [ -n "$v_cross_service_tests_contract_dir" ]    && cst_obj=$(printf '%s' "$cst_obj" | jq --arg v "$v_cross_service_tests_contract_dir"    '. + {contract_dir: $v}')
      [ -n "$v_cross_service_tests_integration_dir" ] && cst_obj=$(printf '%s' "$cst_obj" | jq --arg v "$v_cross_service_tests_integration_dir" '. + {integration_dir: $v}')
      new_sections_jq=$(printf '%s' "$new_sections_jq" | jq --argjson v "$cst_obj" '. + {cross_service_tests: $v}')
    fi
    if [ -n "$v_ci_platform_provider" ] || [ -n "$v_ci_platform_pipeline" ]; then
      cip_obj='{}'
      [ -n "$v_ci_platform_provider" ] && cip_obj=$(printf '%s' "$cip_obj" | jq --arg v "$v_ci_platform_provider" '. + {provider: $v}')
      [ -n "$v_ci_platform_pipeline" ] && cip_obj=$(printf '%s' "$cip_obj" | jq --arg v "$v_ci_platform_pipeline" '. + {pipeline: $v}')
      new_sections_jq=$(printf '%s' "$new_sections_jq" | jq --argjson v "$cip_obj" '. + {ci_platform: $v}')
    fi
    if [ -n "$v_platforms" ]; then
      platforms_json=$(printf '%s' "$v_platforms" | jq -R 'split(",") | map(select(length > 0))')
      new_sections_jq=$(printf '%s' "$new_sections_jq" | jq --argjson v "$platforms_json" '. + {platforms: $v}')
    fi
    # E77-S1 / FR-403 — project_kind top-level scalar. Emitted only when set,
    # so absence preserves byte-stability for the legacy JSON surface.
    if [ -n "$v_project_kind" ]; then
      new_sections_jq=$(printf '%s' "$new_sections_jq" | jq --arg v "$v_project_kind" '. + {project_kind: $v}')
    fi
    # E74-S1 / FR-RSV2-27 — device_targets is structural; emit as nested
    # object when present. Read via python3 + PyYAML at the top of the
    # resolver; we just reuse the captured JSON string here.
    if [ -n "$v_device_targets_json" ]; then
      new_sections_jq=$(printf '%s' "$new_sections_jq" | jq --argjson v "$v_device_targets_json" '. + {device_targets: $v}')
    fi

    # Emit base + new-sections merge.
    jq -n "${base_jq_args[@]}" --argjson new_sections "$new_sections_jq" \
      "$base_jq_filter + \$new_sections"
  else
    # No-jq fallback retains the legacy surface only — new E68-S1 sections
    # require jq for safe JSON construction. Callers without jq will see
    # the legacy surface; this keeps the fallback path byte-stable.
    printf '{"checkpoint_path": "%s", "creative_artifacts": "%s", "date": "%s", "framework_version": "%s", "implementation_artifacts": "%s", "installed_path": "%s", "memory_path": "%s", "planning_artifacts": "%s", "project_path": "%s", "project_root": "%s", "test_artifacts": "%s"}\n' \
      "$(json_escape "$v_checkpoint_path")" \
      "$(json_escape "$v_creative_artifacts")" \
      "$(json_escape "$v_date")" \
      "$(json_escape "$v_framework_version")" \
      "$(json_escape "$v_implementation_artifacts")" \
      "$(json_escape "$v_installed_path")" \
      "$(json_escape "$v_memory_path")" \
      "$(json_escape "$v_planning_artifacts")" \
      "$(json_escape "$v_project_path")" \
      "$(json_escape "$v_project_root")" \
      "$(json_escape "$v_test_artifacts")"
  fi
fi
