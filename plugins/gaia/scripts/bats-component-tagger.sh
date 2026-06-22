#!/usr/bin/env bash
# bats-component-tagger.sh — derive a component -> bats[] manifest for the
# plugin test suite, so the broad gaia-core test stack can be decomposed into
# finer component stacks that a selective-test run can narrow against.
#
# Why this exists
#   The full bats suite is one undifferentiated pile: a change to any component
#   re-runs everything. Splitting it requires knowing, per test file, which
#   component(s) it exercises. Most bats reach their code under test NOT by a
#   literal `plugins/gaia/scripts/foo.sh` path but through the test-helper
#   exports (SCRIPTS_DIR / LIB_DIR / SKILLS_DIR / CLAUDE_PLUGIN_ROOT /
#   PLUGIN_ROOT) plus a path suffix, e.g. `SCRIPTS_DIR/brain/reindex.sh`. This
#   tagger resolves those references to component AREAS and emits the manifest.
#
# Conservatism (no false-greens)
#   A test is assigned to a single component ONLY when every code reference it
#   makes resolves to that one component. Any test that
#     - makes NO resolvable code reference, OR
#     - references MORE THAN ONE component (cross-cutting), OR
#     - references something outside the known areas
#   is assigned to the catch-all component `core`, which a consuming stack runs
#   on EVERY change. Mis-assigning a test to too-narrow a component would let a
#   real break slip through (a false-green); defaulting the uncertain cases to
#   `core` cannot. The count of core-assigned (unresolved/cross-cutting) tests
#   is reported so the conservatism is visible, never silent.
#
# Component areas (the partition unit)
#   scripts-lib            scripts/lib/**            (shared library helpers)
#   scripts-brain          scripts/brain/**          (the Brain knowledge layer)
#   scripts-adapters       scripts/adapters/**       (deploy/publish/brownfield)
#   scripts-review-common  scripts/review-common/**  (review skill shared code)
#   scripts-sprint         scripts/*.sh (sprint set)  (sprint state-machine family)
#   scripts-core           scripts/*.sh (the rest)    (top-level foundation scripts)
#   skills                 skills/**                 (any SKILL.md / skill script)
#   core                   catch-all (unresolved / cross-cutting / multi-area)
#
# Usage:
#   bats-component-tagger.sh [--tests-dir <dir>] [--format tsv|summary]
#                            [--manifest <path>]
#
#   --tests-dir   Directory of .bats files (default: this script's ../tests).
#   --format      tsv (default): `component<TAB>bats-basename` rows, sorted.
#                 summary: per-component counts + the core (unresolved) count.
#   --manifest    Also write the tsv manifest to this path (atomic).
#
# Exit codes: 0 success; 1 usage / no tests found.

set -euo pipefail
LC_ALL=C
export LC_ALL

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${_SELF_DIR}/../tests"
FORMAT="tsv"
MANIFEST=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tests-dir) TESTS_DIR="${2:?--tests-dir needs a value}"; shift 2 ;;
    --format)    FORMAT="${2:?--format needs a value}"; shift 2 ;;
    --manifest)  MANIFEST="${2:?--manifest needs a value}"; shift 2 ;;
    -h|--help)
      sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) printf 'bats-component-tagger.sh: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

[ -d "$TESTS_DIR" ] || { printf 'bats-component-tagger.sh: tests dir not found: %s\n' "$TESTS_DIR" >&2; exit 1; }

# Top-level script allowlist. A literal `scripts/<name>.sh` reference only
# denotes the top-level foundation script `plugins/gaia/scripts/<name>.sh` when
# that file actually exists there. Many bats reference a skill-relative
# `scripts/<name>.sh` via a var the tagger does not track (e.g. $SKILL_DIR,
# $SCRIPTS, $ADD_FEATURE_SCRIPTS) whose suffix `scripts/finalize.sh` LOOKS like
# a top-level ref but resolves to `skills/<skill>/scripts/<name>.sh` at run
# time — `finalize.sh`/`setup.sh` are the common cases (no top-level
# `scripts/finalize.sh` exists; 80 skill-local copies do). Classifying those as
# `scripts-core` over-counts it. We resolve the ambiguity by membership in this
# allowlist: a `scripts/<name>.sh` ref whose basename is NOT a real top-level
# script is treated as non-top-level (→ no scripts-core contribution; the
# catch-all `core` claims the test unless another ref resolves it).
#
# The allowlist is derived from the in-repo top-level scripts dir, which is the
# tagger's own directory (this script lives at plugins/gaia/scripts/). That
# tree is always present in a gaia-public checkout, so the derivation is
# hermetic and deterministic for the drift-guard — it does not depend on the
# operator's runtime layout.
_TOPLEVEL_SCRIPTS_DIR="$_SELF_DIR"
TOPLEVEL_ALLOWLIST=""
if [ -d "$_TOPLEVEL_SCRIPTS_DIR" ]; then
  for _s in "$_TOPLEVEL_SCRIPTS_DIR"/*.sh; do
    [ -e "$_s" ] || continue
    TOPLEVEL_ALLOWLIST="${TOPLEVEL_ALLOWLIST} $(basename "$_s")"
  done
fi

# _is_toplevel_script <basename.sh> -> 0 if a real top-level script, else 1
_is_toplevel_script() {
  case " $TOPLEVEL_ALLOWLIST " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Sprint state-machine script family. These flat top-level scripts form a
# genuine domain boundary (the sprint/story lifecycle state machine and its
# read-only dashboards). They live at scripts/*.sh with no scripts/sprint/
# subdir, so the component is defined by this basename membership rather than a
# path prefix. A bats that references ONLY scripts in this set is a pure
# sprint-lifecycle test → component `scripts-sprint`; a bats that mixes a sprint
# script with a non-sprint top-level script is cross-cutting → the `core`
# catch-all (the tagger's existing >1-component rule). This keeps the carve-out
# conservative: no false-green, because gaia-core cross_refs the sprint stack so
# a sprint change still runs the full core suite.
SPRINT_SCRIPT_FAMILY="\
sprint-state.sh transition-story-status.sh set-story-sprint.sh \
sprint-status-dashboard.sh epic-status-dashboard.sh sprint-progress-audit.sh \
resolve-story-file.sh materialize-sprint-stories.sh backfill-story-index.sh \
check-status-discipline.sh priority-flag.sh validate-epic-registry.sh"

# _is_sprint_script <basename.sh> -> 0 if in the sprint family, else 1
_is_sprint_script() {
  case " $SPRINT_SCRIPT_FAMILY " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# _component_of_suffix <path-suffix-under-plugin> -> component area on stdout
# The suffix is whatever follows the resolved root, e.g. for SCRIPTS_DIR the
# suffix is relative to scripts/, for a literal it is relative to plugins/gaia/.
_component_of_path() {
  # $1: a path normalised to be relative to plugins/gaia/ (e.g. scripts/brain/x.sh)
  case "$1" in
    # A path that contains skills/ anywhere is skill-owned, even when a
    # skill-local scripts/ subdir appears later in it (skills/<skill>/scripts/...).
    # This MUST be tested before the scripts/* cases so a skill-local script is
    # never mistaken for a top-level foundation script.
    skills/*)                 printf 'skills' ;;
    scripts/lib/*)            printf 'scripts-lib' ;;
    scripts/brain/*)          printf 'scripts-brain' ;;
    scripts/review-common/*)  printf 'scripts-review-common' ;;
    # scripts/adapters/* folds into scripts-core: there is no gaia-adapters
    # stack to consume a separate bucket, and scripts/** (gaia-core) already
    # covers scripts/adapters/, so a distinct label would be a name with no
    # runner — fold it rather than leave a manifest-vs-config asymmetry.
    scripts/*)
      # Top-level foundation script ONLY when the basename is a REAL top-level
      # script. A skill-relative `scripts/<name>.sh` (referenced via a var the
      # tagger does not track, e.g. $SKILL_DIR/scripts/finalize.sh) has a
      # suffix that LOOKS top-level but is not — classifying it scripts-core
      # over-counts the bucket. Unknown basenames return empty so the caller
      # treats the ref as unresolved (→ core catch-all unless another ref
      # resolves the test).
      _bn="${1##*/}"
      if _is_sprint_script "$_bn"; then
        printf 'scripts-sprint'
      elif _is_toplevel_script "$_bn"; then
        printf 'scripts-core'
      else
        printf ''
      fi
      ;;
    *)                        printf '' ;;               # unknown -> caller -> core
  esac
}

# _refs_to_components <bats-file> -> sorted-unique component list (one per line)
# Resolves the VAR/suffix and literal forms to plugins/gaia-relative paths,
# then maps each to a component. Emits nothing when no code ref is found.
_refs_to_components() {
  local f="$1"
  {
    # VAR-rooted refs. SCRIPTS_DIR/LIB_DIR root at scripts/ (LIB_DIR == scripts/lib),
    # SKILLS_DIR roots at skills/, CLAUDE_PLUGIN_ROOT/PLUGIN_ROOT root at plugins/gaia/.
    # BATS_TEST_DIRNAME roots at the test file's dir (plugins/gaia/tests/), so a
    # `$BATS_TEST_DIRNAME/../scripts/x.sh` ref walks up via one-or-more `../`
    # segments to a plugins/gaia-relative path — ~54 bats use this idiom and were
    # previously invisible to the tagger (a whole reference class fell to the
    # no-ref catch-all). Both bare ($VAR/...) and braced (${VAR}/...) forms are
    # matched — the optional \{? / }? in the pattern admits the braced form.
    # Capture the path after the var, then normalise to a plugins/gaia-relative
    # path before classifying.
    grep -hoE '\{?(SCRIPTS_DIR|LIB_DIR|SKILLS_DIR|CLAUDE_PLUGIN_ROOT|PLUGIN_ROOT|BATS_TEST_DIRNAME)\}?[/"][A-Za-z0-9_./${}-]+\.sh' "$f" 2>/dev/null \
      | while IFS= read -r ref; do
          local var suffix rel
          # Normalise away ${ } so a braced ref reduces to the bare form.
          ref="$(printf '%s' "$ref" | tr -d '{}')"
          var="${ref%%[/\"]*}"
          suffix="${ref#"$var"}"; suffix="${suffix#[/\"]}"
          # strip any leftover ${} / quotes
          suffix="$(printf '%s' "$suffix" | tr -d '"${}')"
          case "$var" in
            LIB_DIR)                         rel="scripts/lib/$suffix" ;;
            SCRIPTS_DIR)                     rel="scripts/$suffix" ;;
            SKILLS_DIR)                      rel="skills/$suffix" ;;
            CLAUDE_PLUGIN_ROOT|PLUGIN_ROOT)
              # these root at plugins/gaia/, so the suffix already starts
              # scripts/... or skills/... in practice; pass through.
              rel="$suffix" ;;
            BATS_TEST_DIRNAME)
              # rooted at plugins/gaia/tests/. Collapse the leading `../`
              # walk-up segments; whatever remains is plugins/gaia-relative
              # (scripts/..., skills/..., or a non-component path like
              # .github/scripts/... which classifies to empty). Strip ALL
              # leading `../` (and any stray `./`).
              while case "$suffix" in ../*|./*) true ;; *) false ;; esac; do
                suffix="${suffix#../}"; suffix="${suffix#./}"
              done
              rel="$suffix" ;;
            *) rel="" ;;
          esac
          [ -n "$rel" ] && _component_of_path "$rel" && printf '\n'
        done
    # Literal plugins/gaia-relative refs (scripts/foo.sh, skills/x/y.sh).
    grep -hoE '(scripts|skills)/[A-Za-z0-9_./-]+\.sh' "$f" 2>/dev/null \
      | while IFS= read -r rel; do
          _component_of_path "$rel" && printf '\n'
        done
  } | grep -v '^$' | sort -u || true
}

# Build the assignments.
CORE_UNRESOLVED=0
CORE_CROSSCUT=0
TMP_OUT="$(mktemp "${TMPDIR:-/tmp}/bats-tagger.XXXXXX")"
trap 'rm -f "$TMP_OUT"' EXIT

shopt -s nullglob
files=("$TESTS_DIR"/*.bats)
shopt -u nullglob
[ "${#files[@]}" -gt 0 ] || { printf 'bats-component-tagger.sh: no .bats in %s\n' "$TESTS_DIR" >&2; exit 1; }

for f in "${files[@]}"; do
  base="$(basename "$f")"
  comps="$(_refs_to_components "$f" || true)"
  n="$(printf '%s' "$comps" | grep -c . || true)"
  if [ "$n" -eq 0 ]; then
    printf 'core\t%s\n' "$base" >> "$TMP_OUT"
    CORE_UNRESOLVED=$((CORE_UNRESOLVED + 1))
  elif [ "$n" -eq 1 ]; then
    printf '%s\t%s\n' "$comps" "$base" >> "$TMP_OUT"
  else
    # Cross-cutting: references >1 component. Conservatively -> core.
    printf 'core\t%s\n' "$base" >> "$TMP_OUT"
    CORE_CROSSCUT=$((CORE_CROSSCUT + 1))
  fi
done

sort -o "$TMP_OUT" "$TMP_OUT"

if [ -n "$MANIFEST" ]; then
  cp "$TMP_OUT" "${MANIFEST}.tmp" && mv "${MANIFEST}.tmp" "$MANIFEST"
fi

case "$FORMAT" in
  tsv)
    cat "$TMP_OUT" ;;
  summary)
    printf 'component\tbats_count\n'
    cut -f1 "$TMP_OUT" | sort | uniq -c | awk '{printf "%s\t%s\n", $2, $1}'
    printf '\n# core breakdown: %s unresolved (no code ref), %s cross-cutting (>1 component)\n' \
      "$CORE_UNRESOLVED" "$CORE_CROSSCUT"
    printf '# total bats: %s\n' "${#files[@]}" ;;
  *)
    printf 'bats-component-tagger.sh: unknown --format: %s\n' "$FORMAT" >&2; exit 1 ;;
esac
