#!/usr/bin/env bats

# Doc-guard tests for the sprint-execution command's user documentation and its
# command-surface registration.
#
# A slash command is only discoverable if four things agree: the skill exists,
# the intent map lists it, the workflow manifest lists it (the help skill
# cross-checks the manifest before suggesting anything, so a help row without a
# manifest row would suggest a command the check rejects), and the doc site
# both carries the page and links to it. Each is asserted separately so a
# failure names the surface that drifted.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PLUGIN_ROOT
  DOC_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../documentation" && pwd)"
  PAGE="$DOC_ROOT/gaia-run-sprint.html"
  INDEX="$DOC_ROOT/index.html"
  HELP_CSV="$PLUGIN_ROOT/knowledge/gaia-help.csv"
  MANIFEST_CSV="$PLUGIN_ROOT/knowledge/workflow-manifest.csv"
  SKILL="$PLUGIN_ROOT/skills/gaia-run-sprint/SKILL.md"
}

teardown() { common_teardown; }

@test "the sprint-execution page exists in the documentation site (AC3)" {
  [ -f "$PAGE" ] \
    || { echo "missing documentation page: $PAGE"; return 1; }
}

@test "the sprint-execution page carries the standard site chrome (AC3)" {
  [ -f "$PAGE" ] || { echo "missing documentation page: $PAGE"; return 1; }
  grep -q 'href="styles.css"' "$PAGE" \
    || { echo "page does not load the site stylesheet"; return 1; }
  grep -q 'class="sidebar"' "$PAGE" \
    || { echo "page does not carry the site sidebar"; return 1; }
}

@test "the sprint-execution page is linked from the doc-site index (AC3)" {
  grep -q 'href="gaia-run-sprint.html"' "$INDEX" \
    || { echo "no sidebar link to the page in $INDEX"; return 1; }
}

@test "the page documents the opt-in and the sequential fallback (AC3)" {
  [ -f "$PAGE" ] || { echo "missing documentation page: $PAGE"; return 1; }
  # A reader who enables parallel execution without learning that it silently
  # degrades will read a sequential run as a broken feature.
  grep -qi 'opt-in' "$PAGE" \
    || { echo "page does not document that parallel execution is opt-in"; return 1; }
  grep -qi 'sequential' "$PAGE" \
    || { echo "page does not document the sequential fallback"; return 1; }
  grep -qi 'worktree' "$PAGE" \
    || { echo "page does not document the worktree requirement"; return 1; }
}

@test "the command is registered in both the intent map and the manifest (AC3)" {
  grep -q 'gaia-run-sprint' "$HELP_CSV" \
    || { echo "no intent-map row in $HELP_CSV"; return 1; }
  # The help skill validates every suggestion against the manifest, so an
  # intent-map row alone would name a command the cross-check rejects.
  grep -q 'gaia-run-sprint' "$MANIFEST_CSV" \
    || { echo "no manifest row in $MANIFEST_CSV"; return 1; }
}

@test "the new published surfaces carry no internal traceability identifiers (AC3)" {
  local f offenders="" missing=""
  # Fail closed on absence. Skipping a missing file would let this pass before
  # either surface exists, reporting "no leaks" about nothing.
  for f in "$PAGE" "$SKILL"; do
    [ -f "$f" ] || { missing="$missing $f"; continue; }
    # Story keys, requirement ids and decision-record ids are private
    # bookkeeping and must never reach a published file.
    if LC_ALL=C grep -Eq '\b(FR|NFR|SR|ADR)-[0-9]+\b|\bE[0-9]+-S[0-9]+\b' "$f"; then
      offenders="$offenders $f"
    fi
  done
  [ -z "$missing" ] \
    || { echo "surfaces not created yet, so nothing was scanned:$missing"; return 1; }
  [ -z "$offenders" ] \
    || { echo "leaked internal identifiers in:$offenders"; return 1; }
}

@test "every degradation reason the orchestrator emits is documented (AC3)" {
  local orch="$PLUGIN_ROOT/scripts/phase-parallel-orchestrator.sh"
  [ -f "$orch" ] || { echo "missing orchestrator: $orch"; return 1; }
  [ -f "$PAGE" ] || { echo "missing documentation page: $PAGE"; return 1; }
  [ -f "$SKILL" ] || { echo "missing skill: $SKILL"; return 1; }

  # The doc guards above pin that the page EXISTS, carries the chrome and is
  # linked. None of them looks inside the reason table, so a reason could be
  # added to the code and the operator-facing list would silently fall behind --
  # which is how this table came to be missing one. Pin the contents against the
  # code that emits them.
  #
  # `mode=sequential reason=<token>` is the discriminator: it selects the
  # degradation reasons an operator can actually be shown, and excludes
  # `reason=none` (the parallel path succeeded) and the `no-stories` phase-skip
  # event, neither of which belongs in a degradation table.
  local reasons
  reasons="$(grep -oE 'mode=sequential reason=[a-z0-9-]+' "$orch" \
    | sed 's/.*reason=//' | sort -u)"
  [ -n "$reasons" ] \
    || { echo "no degradation reasons found in $orch"; return 1; }

  local r missing_page="" missing_skill=""
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    grep -qF "<code>${r}</code>" "$PAGE" \
      || missing_page="${missing_page}${missing_page:+, }${r}"
    grep -qF "\`${r}\`" "$SKILL" \
      || missing_skill="${missing_skill}${missing_skill:+, }${r}"
  done <<< "$reasons"

  [ -z "$missing_page" ] \
    || { echo "reasons emitted by the orchestrator but absent from the documentation page: $missing_page"; return 1; }
  [ -z "$missing_skill" ] \
    || { echo "reasons emitted by the orchestrator but absent from the skill table: $missing_skill"; return 1; }
}
