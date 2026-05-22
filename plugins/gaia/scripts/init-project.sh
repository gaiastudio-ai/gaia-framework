#!/usr/bin/env bash
# init-project.sh — GAIA foundation script (E28-S16, E28-S151)
#
# Bootstraps a new GAIA-native project by creating the baseline directory
# skeleton, a starter config/project-config.yaml, a minimal CLAUDE.md, and
# the full hybrid `_memory/` layout (per-agent sidecars + canonical headers
# per ADR-046). Fully replaces the legacy gaia-install.sh for project
# initialization.
#
# Refs: FR-325, FR-328, FR-331, NFR-048, ADR-042, ADR-046, ADR-048
# Brief: P2-S8, P21-S6 (.gaia/artifacts/creative-artifacts/gaia-native-conversion-feature-brief-2026-04-14.md)
#
# Invocation contract:
#
#   init-project.sh --name <project> [--path <dir>] [--force] [--help]
#
# Flags:
#   --name <project>   REQUIRED. Project name (used in project-config.yaml
#                      and CLAUDE.md).
#   --path <dir>       Optional. Target directory. Defaults to "./<name>".
#                      Created if it does not exist. Spaces/unicode allowed.
#   --force            Override the non-empty-target safety rails. Required
#                      when <dir> is a non-empty git repo, contains any
#                      non-empty file that would be clobbered, or already
#                      contains a partial skeleton. Still NEVER clobbers a
#                      sidecar file with user content below the `---` header
#                      separator (see `_memory/` init behavior below).
#   --help             Print usage and exit 0.
#
# `_memory/` init behavior (E28-S151, ADR-046):
#   * Seeds `_memory/config.yaml` (tiers + per-agent sidecar mapping) on a
#     fresh target. Idempotent: an already-populated config.yaml is left
#     alone unless --force is passed.
#   * For every agent listed under `agents:` in the seeded config.yaml,
#     creates `_memory/<sidecar_name>/` (e.g. `validator-sidecar/`) and
#     writes canonical header-only files per tier:
#       - Tier 1: ground-truth.md + decision-log.md + conversation-context.md
#       - Tier 2: decision-log.md + conversation-context.md
#       - Tier 3: decision-log.md
#   * Each file ends with a `---` separator and no body content, so
#     `memory-loader.sh` returns empty stdout and exits 0 on fresh projects
#     (the "missing memory contract").
#   * Re-running without --force preserves every non-empty sidecar file
#     byte-for-byte (idempotency). Zero-byte files and missing sidecar dirs
#     are gap-filled.
#   * Under --force, files with user content below the `---` separator are
#     still preserved — --force only rewrites header-only / empty files.
#   * A one-line `_memory/ init: N created, M preserved, K gap-filled`
#     summary is written to stderr for observability.
#
# Safety rails (rejected without --force):
#   * Target is a non-empty git repository.
#   * Target already contains a non-empty CLAUDE.md or project-config.yaml.
#   * Target has a partial skeleton in progress (.gaia-init.lock present).
#
# Concurrency:
#   A `.gaia-init.lock` sentinel file is created early under the target
#   directory and removed on successful completion. A second concurrent
#   invocation seeing the lock exits 1 cleanly without modifying anything
#   beyond its own refusal, even without --force.
#
# Exit codes:
#   0 success — skeleton created (or already present & idempotent with --force)
#   1 user error (missing flags, clobber refusal, concurrency refusal,
#     non-empty git repo without --force)
#   2 internal/contract violation (unable to create directories / write files)
#
set -euo pipefail
LC_ALL=C
export LC_ALL

readonly SELF="init-project.sh"

err() { printf "[%s] ERROR: %s\n" "$SELF" "$*" >&2; }

usage() {
  cat <<'USAGE'
Usage: init-project.sh --name <project> [--path <dir>] [--force] [--help]

Creates the GAIA-native .gaia/ baseline (config/, artifacts/, state/,
memory/, custom/), a starter .gaia/config/project-config.yaml, and a
minimal CLAUDE.md. Layout follows ADR-111 / E96-S1.

Flags:
  --name <project>   Required. Project name.
  --path <dir>       Target directory. Defaults to "./<name>".
  --force            Override the non-empty-target safety rails.
  --help             Print this message and exit 0.

Exit codes:
  0 success
  1 user error (clobber refusal, concurrency refusal, non-empty git repo)
  2 internal/contract violation
USAGE
}

# --- arg parsing -------------------------------------------------------------
name=""
target=""
force=0

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --name)
      [ $# -ge 2 ] || { err "--name requires a value"; exit 1; }
      name="$2"; shift 2 ;;
    --path)
      [ $# -ge 2 ] || { err "--path requires a value"; exit 1; }
      target="$2"; shift 2 ;;
    --force) force=1; shift ;;
    --*) err "unknown flag: $1"; exit 1 ;;
    *)   err "unexpected positional argument: $1"; exit 1 ;;
  esac
done

if [ -z "$name" ]; then err "--name is required"; exit 1; fi
if ! printf "%s" "$name" | grep -Eq '^[A-Za-z0-9_.-]+$'; then
  err "--name '$name' contains invalid characters (allowed: [A-Za-z0-9_.-])"
  exit 1
fi

if [ -z "$target" ]; then target="./$name"; fi

# --- safety rails ------------------------------------------------------------
# Resolve target absolute path without requiring it to exist yet.
abs_target=""
if [ -d "$target" ]; then
  abs_target="$(cd "$target" && pwd)"
else
  parent="$(dirname -- "$target")"
  base="$(basename -- "$target")"
  mkdir -p -- "$parent" || { err "cannot create parent directory: $parent"; exit 2; }
  abs_target="$(cd "$parent" && pwd)/$base"
fi

lock_file="$abs_target/.gaia-init.lock"

if [ -d "$abs_target" ]; then
  # Concurrency guard — lock file wins even over --force to prevent
  # stomping on a running sibling invocation.
  if [ -e "$lock_file" ]; then
    err "target '$abs_target' has a .gaia-init.lock — another init-project.sh is in progress (or left a stale lock)"
    exit 1
  fi

  # Non-empty git repo guard (AC5).
  if [ -d "$abs_target/.git" ]; then
    # Consider "non-empty" = .git exists AND there is any tracked file.
    if [ "$force" -ne 1 ]; then
      err "target is a non-empty git repo; pass --force to override"
      exit 1
    fi
  fi

  # Clobber guard (AC4, AC-EC7): refuse to rewrite an existing non-empty
  # CLAUDE.md or .gaia/config/project-config.yaml UNLESS the file is already a
  # prior init-project.sh output (detected by a signature marker) — that
  # branch yields idempotent re-runs as required by AC4. With --force we
  # always overwrite. Per ADR-111 / E96-S1 the canonical config location is
  # .gaia/config/; legacy config/ from pre-migration installs is also checked
  # so re-running init-project.sh on an unmigrated tree is a no-op rather than
  # silently writing a duplicate config at the new location.
  for f in \
      "$abs_target/CLAUDE.md" \
      "$abs_target/.gaia/config/project-config.yaml" \
      "$abs_target/config/project-config.yaml"; do
    if [ -s "$f" ] && [ "$force" -ne 1 ]; then
      if grep -q 'generated by init-project.sh\|GAIA Project' "$f" 2>/dev/null; then
        # Prior init-project.sh output — treat as idempotent no-op.
        continue
      fi
      err "refusing to clobber existing non-empty file: $f (pass --force to override)"
      exit 1
    fi
  done
fi

# --- create target + lock ----------------------------------------------------
mkdir -p -- "$abs_target" || { err "cannot create target: $abs_target"; exit 2; }

# Atomic lock creation — set -C makes `>` fail if the file exists.
if ! (set -C; : > "$lock_file") 2>/dev/null; then
  err "failed to create lock file: $lock_file"
  exit 1
fi

cleanup_lock() { rm -f -- "$lock_file" 2>/dev/null || true; }
trap cleanup_lock EXIT

# --- create skeleton directories --------------------------------------------
# Per ADR-111 / E96-S1 the canonical runtime tree is .gaia/ with five
# subdirectories: config, artifacts, state, memory, custom. New projects
# scaffolded here use the .gaia/ layout from day one.
for d in \
  ".gaia/config" \
  ".gaia/artifacts/planning-artifacts" \
  ".gaia/artifacts/implementation-artifacts" \
  ".gaia/artifacts/test-artifacts" \
  ".gaia/artifacts/creative-artifacts" \
  ".gaia/state" \
  ".gaia/memory/checkpoints" \
  ".gaia/custom"
do
  mkdir -p -- "$abs_target/$d" || { err "failed to create $abs_target/$d"; exit 2; }
done

# --- write starter project-config.yaml --------------------------------------
# Shape aligns with the canonical project-config schema; this generator writes
# the minimal viable config under .gaia/config/project-config.yaml (ADR-111).
cfg_path="$abs_target/.gaia/config/project-config.yaml"
if [ ! -s "$cfg_path" ] || [ "$force" -eq 1 ]; then
  cat > "$cfg_path" <<CONFIG
# project-config.yaml — generated by init-project.sh
# Project: $name

project_root: $abs_target
project_path: $abs_target
memory_path: $abs_target/.gaia/memory
checkpoint_path: $abs_target/.gaia/memory/checkpoints
installed_path: $abs_target
framework_version: 0.0.0
date: $(date -u +"%Y-%m-%d")
CONFIG
fi

# --- write minimal CLAUDE.md (<= 60 lines) ----------------------------------
claude_md="$abs_target/CLAUDE.md"
if [ ! -s "$claude_md" ] || [ "$force" -eq 1 ]; then
  cat > "$claude_md" <<'CLAUDEMD'
# GAIA Project

This project uses the GAIA Framework plugin for Claude Code. Workflows,
agents, and scripts are delivered by the `gaia` plugin — nothing is vendored
into the repository.

## How to Start

- Run `/gaia` to activate the orchestrator.
- Run `/gaia:gaia-help` for context-sensitive guidance. The `gaia:` prefix
  targets the plugin's `gaia-help` skill directly.

## Directory Layout

- `.gaia/config/project-config.yaml` — project settings consumed by
  `plugins/gaia/scripts/resolve-config.sh`
- `.gaia/artifacts/planning-artifacts/` — PRDs, UX, architecture, epics
- `.gaia/artifacts/implementation-artifacts/` — sprint status, stories, changelogs
- `.gaia/artifacts/test-artifacts/` — test plans, traceability
- `.gaia/artifacts/creative-artifacts/` — design thinking, innovation outputs
- `.gaia/state/` — mutable runtime state (sprint-status.yaml, action-items.yaml)
- `.gaia/memory/checkpoints/` — workflow checkpoints
- `.gaia/custom/` — user extensions

## Execution Model

Foundation scripts run natively in bash — no LLM involvement for deterministic
tasks (checkpointing, gate updates, template headers, lifecycle events).
LLM agents orchestrate the creative and judgment-heavy steps.

## Do Not

- Commit secrets or `.env` files.
- Rewrite plugin scripts in place — file bugs or send PRs upstream.
- Skip workflow steps or quality gates.
CLAUDEMD
fi

# --- seed _memory/config.yaml + per-agent sidecars (E28-S151, ADR-046) ------
# The heredoc below mirrors the shape of the in-repo `_memory/config.yaml`
# — it is the single source of truth for tier lists and per-agent sidecar
# names consumed by `memory-loader.sh` and `memory-writer.sh`. A future
# story may extract this to `plugins/gaia/config/_memory-config.yaml` for
# reuse; until then, keep this heredoc in lockstep with the framework's
# own `_memory/config.yaml`.

memory_cfg="$abs_target/.gaia/memory/config.yaml"
if [ ! -s "$memory_cfg" ] || [ "$force" -eq 1 ]; then
  cat > "$memory_cfg" <<'MEMCFG'
# GAIA Agent Memory Configuration
# Source of truth for token budgets, cross-agent access, and archival thresholds.
# Reference: architecture.md Section 10.10, ADR-014, ADR-015, ADR-046

tiers:
  tier_1:
    label: "Rich"
    files: 3  # ground-truth.md, decision-log.md, conversation-context.md
    session_budget: 300000
    has_ground_truth: true
    agents: [validator, architect, pm, sm]
  tier_2:
    label: "Standard"
    files: 2  # decision-log.md, conversation-context.md
    session_budget: 100000
    has_ground_truth: false
    agents: [orchestrator, security, devops, test-architect]
  tier_3:
    label: "Simple"
    files: 1  # decision-log.md
    session_budget: null
    has_ground_truth: false
    agents: [typescript-dev, angular-dev, flutter-dev, java-dev, python-dev, mobile-dev, storyteller, tech-writer, qa, analyst, brainstorming-coach, data-engineer, design-thinking-coach, innovation-strategist, performance, presentation-designer, problem-solver, ux-designer]

# Per-agent ground truth budgets (Tier 1 only) and sidecar directory mapping.
agents:
  validator:
    ground_truth_budget: 200000
    sidecar: validator-sidecar
  architect:
    ground_truth_budget: 150000
    sidecar: architect-sidecar
  pm:
    ground_truth_budget: 100000
    sidecar: pm-sidecar
  sm:
    ground_truth_budget: 100000
    sidecar: sm-sidecar
  orchestrator:
    sidecar: orchestrator-sidecar
  security:
    sidecar: security-sidecar
  devops:
    sidecar: devops-sidecar
  test-architect:
    sidecar: test-architect-sidecar
  storyteller:
    sidecar: storyteller-sidecar
  tech-writer:
    sidecar: tech-writer-sidecar
  angular-dev:
    sidecar: angular-dev-sidecar
  typescript-dev:
    sidecar: typescript-dev-sidecar
  flutter-dev:
    sidecar: flutter-dev-sidecar
  java-dev:
    sidecar: java-dev-sidecar
  python-dev:
    sidecar: python-dev-sidecar
  mobile-dev:
    sidecar: mobile-dev-sidecar
  qa:
    sidecar: qa-sidecar
  analyst:
    sidecar: analyst-sidecar
  brainstorming-coach:
    sidecar: brainstorming-coach-sidecar
  data-engineer:
    sidecar: data-engineer-sidecar
  design-thinking-coach:
    sidecar: design-thinking-coach-sidecar
  innovation-strategist:
    sidecar: innovation-strategist-sidecar
  performance:
    sidecar: performance-sidecar
  presentation-designer:
    sidecar: presentation-designer-sidecar
  problem-solver:
    sidecar: problem-solver-sidecar
  ux-designer:
    sidecar: ux-designer-sidecar

# Cross-agent read access matrix (ADR-015). All cross-references are
# read-only and loaded JIT. Modes: recent (last 2 sprints), full, summary.
cross_references:
  architect:
    reads_from:
      - agent: pm
        file: decision-log
        mode: recent
      - agent: validator
        file: ground-truth
        mode: recent
  pm:
    reads_from:
      - agent: architect
        file: decision-log
        mode: recent
      - agent: sm
        file: ground-truth
        mode: recent
  sm:
    reads_from:
      - agent: architect
        file: decision-log
        mode: recent
      - agent: pm
        file: decision-log
        mode: recent
      - agent: validator
        file: ground-truth
        mode: recent
  orchestrator:
    reads_from:
      - agent: validator
        file: conversation-context
        mode: summary
      - agent: architect
        file: conversation-context
        mode: summary
      - agent: pm
        file: conversation-context
        mode: summary
      - agent: sm
        file: conversation-context
        mode: summary
  security:
    reads_from:
      - agent: architect
        file: decision-log
        mode: recent
      - agent: validator
        file: ground-truth
        mode: recent
  devops:
    reads_from:
      - agent: architect
        file: decision-log
        mode: recent
  test-architect:
    reads_from:
      - agent: architect
        file: decision-log
        mode: recent
      - agent: validator
        file: ground-truth
        mode: recent
  validator:
    reads_from:
      - agent: architect
        file: decision-log
        mode: full
      - agent: pm
        file: decision-log
        mode: full
      - agent: sm
        file: decision-log
        mode: full
    cross_ref_budget_cap: 0.5
  dev-agents:
    reads_from:
      - agent: validator
        file: ground-truth
        mode: recent
      - agent: architect
        file: decision-log
        mode: recent

archival:
  budget_warn_at: 0.8
  budget_alert_at: 0.9
  budget_archive_at: 1.0
  token_approximation: 4
  archive_subdir: "archive"
MEMCFG
fi

# Display-name map for canonical header markers. Kept inline so the script
# stays single-file (no extra fixture to ship). Any agent not in this map
# falls back to a capitalized token-joined form of the agent id.
gaia_agent_display_name() {
  case "$1" in
    validator)              printf "Validator" ;;
    architect)              printf "Architect" ;;
    pm)                     printf "PM" ;;
    sm)                     printf "SM" ;;
    orchestrator)           printf "Orchestrator" ;;
    security)               printf "Security" ;;
    devops)                 printf "DevOps" ;;
    test-architect)         printf "Test Architect" ;;
    storyteller)            printf "Storyteller" ;;
    tech-writer)            printf "Tech Writer" ;;
    angular-dev)            printf "Angular Dev" ;;
    typescript-dev)         printf "TypeScript Dev" ;;
    flutter-dev)            printf "Flutter Dev" ;;
    java-dev)               printf "Java Dev" ;;
    python-dev)             printf "Python Dev" ;;
    mobile-dev)             printf "Mobile Dev" ;;
    qa)                     printf "QA" ;;
    analyst)                printf "Analyst" ;;
    brainstorming-coach)    printf "Brainstorming Coach" ;;
    data-engineer)          printf "Data Engineer" ;;
    design-thinking-coach)  printf "Design Thinking Coach" ;;
    innovation-strategist)  printf "Innovation Strategist" ;;
    performance)            printf "Performance" ;;
    presentation-designer)  printf "Presentation Designer" ;;
    problem-solver)         printf "Problem Solver" ;;
    ux-designer)            printf "UX Designer" ;;
    *)
      # Fallback: turn "foo-bar-baz" into "Foo Bar Baz".
      printf "%s" "$1" | awk -F'-' '{
        for (i=1; i<=NF; i++) { $i = toupper(substr($i,1,1)) substr($i,2) }
        OFS=" "; $1=$1; print
      }'
      ;;
  esac
}

# Return the canonical header (first line, purpose comment, `---` separator,
# trailing blank line) for a given (agent_id, file_kind) pair.
gaia_header_for() {
  local agent="$1" kind="$2" display
  display="$(gaia_agent_display_name "$agent")"
  case "$kind" in
    ground-truth)
      printf "# %s — Ground Truth\n\n> Persistent ground truth for %s. Loaded via ADR-046 Path 1 (embedded in parent-spawn prompt). Keep entries append-only.\n\n---\n" "$display" "$agent"
      ;;
    decision-log)
      printf "# %s — Decision Log\n\n> Per-session decisions for %s. Loaded via ADR-046 Path 2 (memory-loader.sh). Append-only.\n\n---\n" "$display" "$agent"
      ;;
    conversation-context)
      printf "# %s — Conversation Context\n\n> Recent conversation context for %s. Rolling summary — older entries are archived per archival.budget_archive_at.\n\n---\n" "$display" "$agent"
      ;;
  esac
}

# Return 0 (true) if the given file is safe to rewrite under --force —
# i.e. it is missing, empty, or contains only the canonical header (no
# user content below the `---` separator). Return 1 otherwise.
gaia_file_is_header_only() {
  local f="$1"
  [ ! -s "$f" ] && return 0
  # Extract everything after the first line matching ^---$. If any of
  # those lines contains a non-whitespace character, the file has user
  # content and must be preserved.
  if awk '
    /^---$/ { if (!seen) { seen=1; next } }
    seen && /[^[:space:]]/ { print "has_content"; exit }
  ' "$f" | grep -q "has_content"; then
    return 1
  fi
  return 0
}

# Parse the seeded _memory/config.yaml and emit one `<agent>:<tier>` line
# per agent to stdout. Tier is derived from the tiers.tier_{1,2,3}.agents
# flow-list in the config.
gaia_agents_with_tier() {
  awk '
    BEGIN { section = "" }
    /^[[:space:]]*#/ { next }
    /^tiers:[[:space:]]*$/ { section = "tiers"; tier = ""; next }
    /^[^[:space:]]/ {
      # Any other top-level key (no leading whitespace) closes the tiers section.
      if (!($0 ~ /^tiers:[[:space:]]*$/)) { section = ""; tier = "" }
      next
    }
    section == "tiers" && /^[[:space:]]+tier_[123]:[[:space:]]*$/ {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/:.*$/, "", line)
      tier = substr(line, length("tier_") + 1)
      next
    }
    section == "tiers" && /^[[:space:]]+agents:[[:space:]]*\[/ && tier != "" {
      line = $0
      sub(/^[^\[]*\[/, "", line)
      sub(/\].*$/, "", line)
      n = split(line, items, ",")
      for (i=1; i<=n; i++) {
        item = items[i]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
        if (item != "") print item ":" tier
      }
    }
  ' "$1"
}

# Resolve an agent id to its sidecar directory name as declared in the
# `agents:` block of config.yaml. Falls back to `<agent>-sidecar`.
gaia_sidecar_for() {
  local agent="$1" cfg="$2" val
  val="$(awk -v agent="$agent" '
    BEGIN { in_agents = 0; in_agent = 0; agent_indent = -1 }
    /^[^[:space:]#]/ { in_agents = ($0 ~ /^agents:[[:space:]]*$/) ? 1 : 0; in_agent = 0; next }
    in_agents && /^[[:space:]]+[^[:space:]:#]+:[[:space:]]*$/ {
      line = $0
      indent_str = line; sub(/[^[:space:]].*$/, "", indent_str)
      indent = length(indent_str)
      name = line; sub(/^[[:space:]]+/, "", name); sub(/:.*$/, "", name)
      if (agent_indent < 0) agent_indent = indent
      if (indent == agent_indent) { in_agent = (name == agent) ? 1 : 0 }
      next
    }
    in_agent && /^[[:space:]]+sidecar:[[:space:]]*/ {
      v = $0; sub(/^[[:space:]]+sidecar:[[:space:]]*/, "", v); sub(/[[:space:]]*(#.*)?$/, "", v)
      sub(/^"/, "", v); sub(/"$/, "", v)
      print v; exit
    }
  ' "$cfg" 2>/dev/null || true)"
  if [ -z "$val" ]; then val="${agent}-sidecar"; fi
  printf "%s" "$val"
}

# Write the canonical header for (agent, kind) into $sidecar_dir/<kind>.md,
# respecting idempotency and the --force semantics above. Updates the
# created/preserved/gap-filled counters (passed by name).
gaia_write_sidecar_file() {
  local agent="$1" kind="$2" sidecar_dir="$3" force_flag="$4"
  local file="$sidecar_dir/${kind}.md"

  if [ ! -e "$file" ]; then
    gaia_header_for "$agent" "$kind" > "$file"
    : $((init_created += 1))
    return 0
  fi

  if [ ! -s "$file" ]; then
    # Zero-byte gap: always fill.
    gaia_header_for "$agent" "$kind" > "$file"
    : $((init_gap_filled += 1))
    return 0
  fi

  if [ "$force_flag" -eq 1 ] && gaia_file_is_header_only "$file"; then
    # --force rewrites header-only files; never clobbers user content.
    gaia_header_for "$agent" "$kind" > "$file"
    : $((init_preserved += 1))
    return 0
  fi

  # Non-empty file with user content (or no --force): preserve byte-for-byte.
  : $((init_preserved += 1))
  return 0
}

# Initialize per-agent sidecars from the seeded config.yaml.
init_created=0
init_preserved=0
init_gap_filled=0

while IFS=: read -r agent tier; do
  [ -z "$agent" ] && continue
  sidecar_name="$(gaia_sidecar_for "$agent" "$memory_cfg")"
  sidecar_dir="$abs_target/.gaia/memory/$sidecar_name"

  if [ ! -d "$sidecar_dir" ]; then
    mkdir -p -- "$sidecar_dir" || { err "failed to create $sidecar_dir"; exit 2; }
  fi

  case "$tier" in
    1)
      gaia_write_sidecar_file "$agent" "ground-truth"          "$sidecar_dir" "$force"
      gaia_write_sidecar_file "$agent" "decision-log"          "$sidecar_dir" "$force"
      gaia_write_sidecar_file "$agent" "conversation-context"  "$sidecar_dir" "$force"
      ;;
    2)
      gaia_write_sidecar_file "$agent" "decision-log"          "$sidecar_dir" "$force"
      gaia_write_sidecar_file "$agent" "conversation-context"  "$sidecar_dir" "$force"
      ;;
    3)
      gaia_write_sidecar_file "$agent" "decision-log"          "$sidecar_dir" "$force"
      ;;
  esac
done < <(gaia_agents_with_tier "$memory_cfg")

printf "[%s] .gaia/memory/ init: %d created, %d preserved, %d gap-filled\n" \
  "$SELF" "$init_created" "$init_preserved" "$init_gap_filled" >&2

# --- done --------------------------------------------------------------------
cleanup_lock
trap - EXIT

exit 0
