#!/usr/bin/env bash
# validate-epic-registry.sh — epic / story-key registry integrity audit
#
# Purpose:
#   Detect three classes of silent corruption that the framework had no
#   integrity check for:
#
#     (a) Story-key collisions — the same `E<N>-S<M>` key appearing in more
#         than one distinct source (an `### Story` entry in epics-and-stories.md,
#         a flat story file under implementation-artifacts/, or a nested
#         story.md under epic-*/<key>-*/story.md).
#
#     (b) Epic-number collisions — the same `E<N>` number mapped to more than
#         one distinct epic title (e.g. `## Epic 18: Cloud Deployment` in
#         epics-and-stories.md while materialized story files carry
#         `epic: "E18 — Action Items Management"` in their frontmatter).
#
#     (c) Orphan epic registration — a story file whose `epic:` frontmatter
#         names an epic key with no matching `## Epic <N>:` header in
#         epics-and-stories.md.
#
#   The audit is READ-ONLY and emits a structured report on stdout. It exits 0
#   when no issues are found and non-zero when any issue is detected, so it
#   composes cleanly with `set -e` in caller skills.
#
# Invocation:
#   validate-epic-registry.sh [--epics-file <path>]
#                              [--artifacts-dir <path>]
#                              [--format text|json]
#                              [--severity warn|halt]
#
# Inputs:
#   --epics-file        Path to the canonical epics-and-stories.md. Default:
#                       resolved from the standard artifact-path resolver
#                       (.gaia/artifacts/planning-artifacts/epics-and-stories.md
#                       with fallback to docs/planning-artifacts/...).
#   --artifacts-dir     Implementation-artifacts root that holds story files.
#                       Default: .gaia/artifacts/implementation-artifacts/ with
#                       fallback to docs/implementation-artifacts/.
#   --format            text (default — human-readable) | json (machine-readable).
#   --severity          warn (default — exit 0 with a warning even when issues
#                       found, suitable for advisory wiring) | halt (exit 1
#                       when any issue found, suitable for hard gates).
#
# Exit codes:
#   0 — no issues, or issues found in `--severity warn` mode.
#   1 — issues found in `--severity halt` mode, OR a usage/IO error in either
#       mode (an `errors:` section is emitted in addition to `issues:`).
#   2 — usage error (missing/unknown flag, unreadable required input).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="validate-epic-registry.sh"

die() {
  local rc="$1"; shift
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit "$rc"
}

usage() {
  cat >&2 <<'USAGE'
validate-epic-registry.sh — epic / story-key registry integrity audit

Detection classes:
  (A) story-key collisions    — same E<N>-S<M> in >1 source (duplicate file,
                                 or file disagreeing with epics-and-stories.md)
  (B) epic-number collisions  — same E<N> mapped to >1 distinct title
  (C) orphan epic registration — story file references an epic with no
                                  `## Epic <N>:` header in epics-and-stories.md

Usage:
  validate-epic-registry.sh [--epics-file <path>]
                             [--artifacts-dir <path>]
                             [--format text|json]
                             [--severity warn|halt]
  validate-epic-registry.sh --help

Defaults:
  --epics-file        Resolved from PROJECT_ROOT
                      (.gaia/artifacts/planning-artifacts/epics-and-stories.md
                       with docs/planning-artifacts/ fallback).
  --artifacts-dir     Implementation-artifacts dir under PROJECT_ROOT.
  --format            text
  --severity          warn (exit 0 even when issues found, advisory).
                      halt → exit 1 on any issue (hard gate).

Exit codes:
  0 — clean, OR issues found in `--severity warn` mode.
  1 — issues found in `--severity halt` mode.
  2 — usage error / unreadable input.
USAGE
}

EPICS_FILE=""
ARTIFACTS_DIR=""
FORMAT="text"
SEVERITY="warn"

while [ $# -gt 0 ]; do
  case "$1" in
    --epics-file)    [ $# -ge 2 ] || die 2 "--epics-file requires a value"; EPICS_FILE="$2";    shift 2 ;;
    --artifacts-dir) [ $# -ge 2 ] || die 2 "--artifacts-dir requires a value"; ARTIFACTS_DIR="$2"; shift 2 ;;
    --format)        [ $# -ge 2 ] || die 2 "--format requires a value"; FORMAT="$2";        shift 2 ;;
    --severity)      [ $# -ge 2 ] || die 2 "--severity requires a value"; SEVERITY="$2";    shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *)               die 2 "unknown argument: $1" ;;
  esac
done

case "$FORMAT"   in text|json) : ;; *) die 2 "--format must be 'text' or 'json'" ;; esac
case "$SEVERITY" in warn|halt) : ;; *) die 2 "--severity must be 'warn' or 'halt'" ;; esac

# ----- Defaults: resolve epics-file + artifacts-dir from PROJECT_ROOT -----

PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-.}}}"

resolve_default_epics_file() {
  local p
  for p in \
    "${PROJECT_ROOT}/.gaia/artifacts/planning-artifacts/epics-and-stories.md" \
    "${PROJECT_ROOT}/docs/planning-artifacts/epics-and-stories.md"; do
    [ -f "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

resolve_default_artifacts_dir() {
  local d
  for d in \
    "${PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts" \
    "${PROJECT_ROOT}/docs/implementation-artifacts"; do
    [ -d "$d" ] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

if [ -z "$EPICS_FILE" ]; then
  EPICS_FILE="$(resolve_default_epics_file || true)"
  [ -n "$EPICS_FILE" ] || die 2 "epics-and-stories.md not found under \$PROJECT_ROOT; pass --epics-file"
fi
[ -r "$EPICS_FILE" ] || die 2 "epics-file unreadable: $EPICS_FILE"

if [ -z "$ARTIFACTS_DIR" ]; then
  ARTIFACTS_DIR="$(resolve_default_artifacts_dir || true)"
  # An empty artifacts dir is OK (greenfield project pre-create-story) — only
  # the epics-and-stories.md scan happens in that case.
fi

# ----- Build lookups -----
# epic_titles : N <TAB> title         (every `## Epic N: Title` heading)
# epic_story_keys : <KEY>             (every `### Story EN-SM: Title` heading)
# file_story_keys : <KEY> <TAB> path  (every story file's <KEY>)
# file_epic_refs  : <KEY> <TAB> <epic_title_from_frontmatter> <TAB> path

TMPDIR_RUN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT

EPIC_TITLES="$TMPDIR_RUN/epic_titles.tsv"
EPIC_STORY_KEYS="$TMPDIR_RUN/epic_story_keys.tsv"
FILE_STORY_KEYS="$TMPDIR_RUN/file_story_keys.tsv"
FILE_EPIC_REFS="$TMPDIR_RUN/file_epic_refs.tsv"

# Parse `## Epic N: Title` headers from epics-and-stories.md (portable awk —
# no GNU `match($0,re,arr)` capture-group form; BSD awk does not support it).
awk '
  /^## Epic [0-9]+:/ {
    n=$3
    sub(/:$/,"",n)
    title=$0
    sub(/^## Epic [0-9]+:[[:space:]]*/,"",title)
    printf "%s\t%s\n", n, title
  }
' "$EPICS_FILE" > "$EPIC_TITLES" 2>/dev/null || true

# Parse `### Story EN-SM: Title` headers from epics-and-stories.md
awk '
  /^### Story E[0-9]+-S[0-9]+:/ {
    key=$3
    sub(/:$/,"",key)
    print key
  }
' "$EPICS_FILE" > "$EPIC_STORY_KEYS" 2>/dev/null || true

# Walk artifacts-dir for materialized story files. The framework supports three
# layouts (per CLAUDE.md): flat `${dir}/<KEY>-*.md`, nested per-story-dir
# `${dir}/epic-*/<KEY>-*/story.md`, and per-epic-stories `${dir}/epic-*/stories/<KEY>-*.md`.
if [ -n "$ARTIFACTS_DIR" ] && [ -d "$ARTIFACTS_DIR" ]; then
  # shellcheck disable=SC2044
  find "$ARTIFACTS_DIR" -type f \( -name 'E*-S*.md' -o -name 'story.md' \) \
    \( -path "*/epic-*/stories/*" -o -path "*/epic-*/E*-S*-*/*" -o -path "${ARTIFACTS_DIR}/E*-S*-*.md" \) \
    2>/dev/null | while IFS= read -r f; do
      # Extract key from filename — `E<N>-S<M>` prefix. Use a pure-shell
      # extraction so we don't depend on `awk match(...)` capture-group syntax
      # that differs between GNU and BSD awk.
      base="$(basename "$f" .md)"
      key=""
      case "$base" in
        story)
          # nested layout — read parent dir name
          base="$(basename "$(dirname "$f")")"
          ;;
      esac
      # Strip everything after the EN-SM prefix.
      if printf '%s' "$base" | grep -qE '^E[0-9]+-S[0-9]+'; then
        key="$(printf '%s' "$base" | sed -E 's/^(E[0-9]+-S[0-9]+).*$/\1/')"
      fi
      [ -n "$key" ] || continue
      printf '%s\t%s\n' "$key" "$f" >> "$FILE_STORY_KEYS"
      # Extract `epic:` frontmatter value (best-effort — quoted or bare)
      epic_ref="$(awk '
        /^---[[:space:]]*$/ { n++; if (n==2) exit }
        n==1 && /^epic:[[:space:]]*/ {
          v=$0; sub(/^epic:[[:space:]]*/,"",v); gsub(/^["\x27]|["\x27]$/,"",v); print v; exit
        }
      ' "$f" 2>/dev/null || true)"
      [ -n "$epic_ref" ] && printf '%s\t%s\t%s\n' "$key" "$epic_ref" "$f" >> "$FILE_EPIC_REFS"
    done
fi

# Ensure the files exist even when empty (subsequent grep loops would error).
: >> "$FILE_STORY_KEYS"
: >> "$FILE_EPIC_REFS"

# ----- Audit (a): story-key collision ------------------------------------
# A real collision is one of:
#   (a1) the same key materialized at >1 distinct file path, OR
#   (a2) the key is registered in epics-and-stories.md AND a materialized
#        file with the same key has an `epic:` frontmatter whose epic number
#        differs from the registered epic for that key (silent content
#        divergence — the incident shape).
# Note: a key appearing in epics-and-stories.md PLUS exactly one materialized
# file with a matching epic is the NORMAL case and never a collision.

A_ISSUES="$TMPDIR_RUN/a.tsv"
: > "$A_ISSUES"

# Build (key, registered_epic_n) from epics-and-stories.md story headers.
KEY_TO_REGISTERED_N="$TMPDIR_RUN/key_registered_n.tsv"
awk '
  /^### Story E[0-9]+-S[0-9]+:/ {
    key=$3; sub(/:$/,"",key)
    n=key; sub(/^E/,"",n); sub(/-S[0-9]+$/,"",n)
    printf "%s\t%s\n", key, n
  }
' "$EPICS_FILE" > "$KEY_TO_REGISTERED_N" 2>/dev/null || true

# (a1) more than one file for the same key
sort "$FILE_STORY_KEYS" | awk -F'\t' '
  { c[$1]++; paths[$1]=(paths[$1] ? paths[$1] ";" $2 : $2) }
  END { for (k in c) if (c[k]>1) printf "%s\t%s\n", k, paths[k] }
' > "$TMPDIR_RUN/dup_file_keys.tsv"

while IFS=$'\t' read -r key paths; do
  [ -z "$key" ] && continue
  printf 'A\t%s\t%s\n' "$key" "$paths" >> "$A_ISSUES"
done < "$TMPDIR_RUN/dup_file_keys.tsv"

# (a2) registered key whose file's epic-number disagrees with the registered N
while IFS=$'\t' read -r key reg_n; do
  [ -z "$key" ] && continue
  # Walk every file claiming this key
  awk -F'\t' -v k="$key" '$1==k {print $0}' "$FILE_EPIC_REFS" | while IFS=$'\t' read -r fkey fref ffile; do
    [ -z "$fref" ] && continue
    fn="$(printf '%s' "$fref" | sed -E 's/^E?([0-9]+).*$/\1/')"
    case "$fn" in *[!0-9]*) continue ;; esac
    if [ -n "$fn" ] && [ "$fn" != "$reg_n" ]; then
      printf 'A\t%s\tepics-and-stories.md(E%s);%s(E%s)\n' "$key" "$reg_n" "$ffile" "$fn" >> "$A_ISSUES"
    fi
  done
done < "$KEY_TO_REGISTERED_N"

# ----- Audit (b): epic-number → multiple titles --------------------------
# Combine titles from epics-and-stories.md `## Epic N:` AND from story-file
# `epic:` frontmatter (best-effort parse: extract a number from the value).

B_ISSUES="$TMPDIR_RUN/b.tsv"
: > "$B_ISSUES"

EPIC_N_TITLES="$TMPDIR_RUN/epic_n_titles.tsv"
{
  awk -F'\t' '{ printf "%s\t%s\n", $1, $2 }' "$EPIC_TITLES"
  # From file_epic_refs, derive (N, title) pairs. Patterns we accept:
  #   "E18 — Action Items Management"
  #   "E18 - Action Items Management"
  #   "E18: Action Items Management"
  #   "18 — Action Items Management"
  # Use sed (portable) to extract N and title from the second TSV field.
  awk -F'\t' '{ print $2 }' "$FILE_EPIC_REFS" | while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    n="$(printf '%s' "$ref" | sed -E 's/^E?([0-9]+).*$/\1/')"
    # Title extraction needs to preserve multi-byte separators (e.g. em-dash).
    # Run this sed under the host's natural UTF-8 locale, not LC_ALL=C, or
    # byte-class character refs munge multi-byte chars on macOS BSD sed.
    title="$(LC_ALL="${LANG:-en_US.UTF-8}" printf '%s' "$ref" \
              | LC_ALL="${LANG:-en_US.UTF-8}" sed -E 's/^E?[0-9]+[[:space:]]*([—:-]|--)[[:space:]]*//')"
    [ -n "$n" ] && [ "$n" != "$ref" ] && printf '%s\t%s\n' "$n" "$title"
  done
} | sort -u > "$EPIC_N_TITLES"

# An epic-number collision is N → >1 distinct title.
awk -F'\t' '{ c[$1]++ } END { for (n in c) if (c[n]>1) print n }' "$EPIC_N_TITLES" \
  | sort -n > "$TMPDIR_RUN/colliding_epic_ns.txt"

while IFS= read -r n; do
  [ -z "$n" ] && continue
  titles="$(awk -F'\t' -v n="$n" '$1==n {print $2}' "$EPIC_N_TITLES" | sort -u | paste -sd';' -)"
  printf 'B\t%s\t%s\n' "E$n" "$titles" >> "$B_ISSUES"
done < "$TMPDIR_RUN/colliding_epic_ns.txt"

# ----- Audit (c): orphan epic ---------------------------------------------
# A story file whose `epic:` references epic E<N> for which there is NO
# `## Epic <N>:` header in epics-and-stories.md.

C_ISSUES="$TMPDIR_RUN/c.tsv"
: > "$C_ISSUES"

REGISTERED_NS="$TMPDIR_RUN/registered_ns.txt"
awk -F'\t' '{ print $1 }' "$EPIC_TITLES" | sort -u > "$REGISTERED_NS"

while IFS=$'\t' read -r key ref file; do
  [ -z "$key" ] && continue
  n="$(printf '%s' "$ref" | sed -E 's/^E?([0-9]+).*$/\1/')"
  [ -z "$n" ] && continue
  # Sed will leave $n equal to $ref when the pattern doesn't match — skip those.
  case "$n" in *[!0-9]*) continue ;; esac
  if ! grep -qxF "$n" "$REGISTERED_NS"; then
    printf 'C\t%s\t%s\t%s\n' "$key" "E$n" "$file" >> "$C_ISSUES"
  fi
done < "$FILE_EPIC_REFS"

# ----- Report -------------------------------------------------------------

A_COUNT=$(wc -l < "$A_ISSUES" | tr -d ' ')
B_COUNT=$(wc -l < "$B_ISSUES" | tr -d ' ')
C_COUNT=$(wc -l < "$C_ISSUES" | tr -d ' ')
TOTAL=$((A_COUNT + B_COUNT + C_COUNT))

emit_text() {
  if [ "$TOTAL" -eq 0 ]; then
    printf 'validate-epic-registry: OK (0 collisions, 0 orphans)\n'
    return 0
  fi
  printf 'validate-epic-registry: %d issue(s) found\n' "$TOTAL"
  if [ "$A_COUNT" -gt 0 ]; then
    printf '\n[A] story-key collisions — same E<N>-S<M> key in >1 source (%d):\n' "$A_COUNT"
    while IFS=$'\t' read -r _ key srcs; do
      printf '  - %s  in: %s\n' "$key" "$srcs"
    done < "$A_ISSUES"
  fi
  if [ "$B_COUNT" -gt 0 ]; then
    printf '\n[B] epic-number collisions — same E<N> mapped to >1 distinct title (%d):\n' "$B_COUNT"
    while IFS=$'\t' read -r _ ek titles; do
      printf '  - %s  titles: %s\n' "$ek" "$titles"
    done < "$B_ISSUES"
  fi
  if [ "$C_COUNT" -gt 0 ]; then
    printf '\n[C] orphan epic registration — story files reference an epic with no `## Epic <N>:` header (%d):\n' "$C_COUNT"
    while IFS=$'\t' read -r _ key ek file; do
      printf '  - %s -> %s  (file: %s)\n' "$key" "$ek" "$file"
    done < "$C_ISSUES"
  fi
}

emit_json() {
  printf '{"summary":{"total":%d,"collisions_story_key":%d,"collisions_epic_number":%d,"orphans":%d},"issues":[' \
    "$TOTAL" "$A_COUNT" "$B_COUNT" "$C_COUNT"
  local first=1
  while IFS=$'\t' read -r _ key srcs; do
    [ -z "$key" ] && continue
    [ $first -eq 1 ] && first=0 || printf ','
    printf '{"class":"story_key_collision","key":"%s","sources":"%s"}' "$key" "$srcs"
  done < "$A_ISSUES"
  while IFS=$'\t' read -r _ ek titles; do
    [ -z "$ek" ] && continue
    [ $first -eq 1 ] && first=0 || printf ','
    printf '{"class":"epic_number_collision","epic":"%s","titles":"%s"}' "$ek" "$titles"
  done < "$B_ISSUES"
  while IFS=$'\t' read -r _ key ek file; do
    [ -z "$key" ] && continue
    [ $first -eq 1 ] && first=0 || printf ','
    printf '{"class":"orphan_epic","key":"%s","epic":"%s","file":"%s"}' "$key" "$ek" "$file"
  done < "$C_ISSUES"
  printf ']}\n'
}

case "$FORMAT" in
  text) emit_text ;;
  json) emit_json ;;
esac

# Exit code by severity:
#   warn — always 0 (the report is advisory; caller decides what to do).
#   halt — non-zero when TOTAL > 0.
if [ "$SEVERITY" = "halt" ] && [ "$TOTAL" -gt 0 ]; then
  exit 1
fi
exit 0
