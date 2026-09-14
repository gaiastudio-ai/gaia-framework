#!/usr/bin/env bats
#
# Doc-guard tests for the git-workflow skill's story-worktree section, the
# story-branch prefix, and the documentation-site pages that mirror them.
#
# Three things are asserted here, and the third is the reason they share a file:
#
#   1. The skill's worktree section exists, sits before the terminal Test
#      Scenarios section, and carries its own named loader marker without
#      disturbing the four that already exist.
#   2. Every clause of that section is TRUE of the shipped library. These are
#      contract-fidelity pins: each one greps the prose AND the code behind it,
#      so a later change to the library that invalidates the prose fails here
#      rather than misleading a reader.
#   3. The documentation-site pages that describe the same thing carry the same
#      clauses. The repository's prose leak gate scans only *.md under the
#      plugin tree, so the HTML pages get their explicit leak assertion here.
#
# Style: prose pins are keyword pairs scoped to a section slice, never whole
# sentences -- a pinned sentence turns every editorial pass into a failure.
#
# Portability: Bash 3.2 (no associative arrays, no mapfile/readarray, no
# ${var,,}). POSIX awk and BSD/GNU-neutral grep only -- no grep -P, no sed -i.
# grep -c output is trimmed with tr -d ' ' because BSD grep pads it.

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DOC_ROOT="$REPO_ROOT/documentation"

  SKILL="$PLUGIN_ROOT/skills/gaia-git-workflow/SKILL.md"
  LIB="$PLUGIN_ROOT/scripts/lib/story-worktree.sh"
  BRANCH_SCRIPT="$PLUGIN_ROOT/skills/gaia-dev-story/scripts/git-branch.sh"

  DOC_SKILL_PAGE="$DOC_ROOT/commands/gaia-git-workflow.html"
  DOC_GLOSSARY="$DOC_ROOT/glossary.html"
  DOC_LIFECYCLE="$DOC_ROOT/lifecycle-diagram.html"

  SKILL_REL="plugins/gaia/skills/gaia-git-workflow/SKILL.md"

  # The pre-change content the marker-integrity and commit-table pins compare
  # against, committed as a fixture rather than resolved from git.
  #
  # A revision-based baseline cannot be trusted here: CI checks out with
  # fetch-depth 1, so a hardcoded SHA (or a merge-base against a remote branch)
  # stops resolving as soon as the trunk advances. A pin that SKIPS when its
  # baseline is unresolvable is worse than no pin -- the two assertions
  # protecting the loader markers and the commit table would go quiet exactly
  # when a regression could land unseen. The fixture is always present, so
  # these pins can never silently stand down; if it is missing, they FAIL.
  BASELINE="$PLUGIN_ROOT/tests/fixtures/git-workflow-baseline/SKILL.md.baseline"

  # The named marker this story adds.
  MARKER='<!-- SECTION: worktrees -->'
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# section_slice — the worktrees section body: from its marker up to (but not
# including) the next level-2 heading. Scoping every content pin to this slice
# is what stops a keyword that happens to exist elsewhere in the file from
# satisfying a test about the new section.
#
# Each SECTION marker sits directly above its OWN level-2 heading, so the slice
# must keep that first heading and stop at the SECOND one -- exiting on the
# first would return an empty body and make every content pin vacuous.
section_slice() {
  awk '
    index($0, "<!-- SECTION: worktrees -->") { inside = 1; seen = 0; next }
    inside && /^## / { if (seen) exit; seen = 1 }
    inside { print }
  ' "$SKILL"
}

# sentences_of <text> — one sentence per line.
#
# Sentence boundary is ". " / ".\n" / "! " / "? ", with markdown list items and
# table rows treated as their own sentences. Kept deliberately simple: this is a
# scoping device, not a natural-language parser. Over-splitting is safe (a claim
# still lands in one of the pieces); under-splitting is what must be avoided,
# because a too-large window is how an unrelated positive word "satisfies" a
# claim that the surrounding text actually contradicts.
sentences_of() {
  # Markdown prose is hard-wrapped, so a sentence routinely spans several source
  # lines. Reflow each paragraph onto one line FIRST -- splitting the raw text
  # would cut sentences at the wrap point and hide half of every claim from the
  # regex that has to judge it. Blank lines, table rows and fenced lines stay as
  # their own units.
  printf '%s\n' "$1" \
    | awk '
        /^[[:space:]]*$/ { if (buf != "") { print buf; buf = "" } ; next }
        /^[[:space:]]*\|/ || /^[[:space:]]*```/ {
          if (buf != "") { print buf; buf = "" }
          print
          next
        }
        {
          line = $0
          sub(/^[[:space:]]+/, "", line)
          buf = (buf == "" ? line : buf " " line)
        }
        END { if (buf != "") print buf }
      ' \
    | sed 's/\([.!?]\)[[:space:]][[:space:]]*/\1\
/g' \
    | sed 's/^[[:space:]]*[-*][[:space:]]*//' \
    | grep -v '^[[:space:]]*$'
}

# claim_sentence <text> <keyword-ere> — the sentence(s) of <text> that carry the
# keyword. Empty output means the claim is not made at all.
claim_sentence() {
  sentences_of "$1" | grep -iE "$2" || true
}

# prose_subsection <heading-ere> — the PROSE of one "### ..." subsection of the
# worktrees section: everything from that heading to the next heading of any
# level, with table rows and fenced blocks removed.
#
# Two things make this necessary. A scenario-table row carrying a keyword keeps
# a pin green after the entire prose subsection it describes has been deleted;
# and a single run-on paragraph of keywords satisfies co-occurrence checks that
# only ever look at one sentence. Requiring each claim to live in its own prose
# subsection defeats both: the structure has to exist, not just the vocabulary.
prose_subsection() {
  section_slice | awk -v want="$1" '
    /^###[[:space:]]/ {
      inside = (tolower($0) ~ tolower(want)) ? 1 : 0
      next
    }
    /^##[[:space:]]/ { inside = 0 }
    inside && /^[[:space:]]*\|/ { next }
    inside && /^[[:space:]]*```/ { fence = !fence; next }
    inside && !fence { print }
  '
}

# subsection_with_code <heading-ere> — as prose_subsection, but KEEPS fenced
# blocks. Used by the recovery-command pin, whose subject is the command itself.
subsection_with_code() {
  section_slice | awk -v want="$1" '
    /^###[[:space:]]/ {
      inside = (tolower($0) ~ tolower(want)) ? 1 : 0
      next
    }
    /^##[[:space:]]/ { inside = 0 }
    inside && /^[[:space:]]*\|/ { next }
    inside { print }
  '
}

# require_prose_subsection <heading-ere> <label> — the subsection must exist and
# carry real prose, not just a heading.
require_prose_subsection() {
  local text
  text="$(prose_subsection "$1")"
  if [ -z "$(printf '%s' "$text" | tr -d '[:space:]')" ]; then
    printf 'missing prose subsection (%s): no "### ... %s ..." body\n' "$2" "$1" >&2
    return 1
  fi
  printf '%s' "$text"
}

# assert_claim <text> <keyword-ere> <required-ere> <forbidden-ere> <label>
#
# THE core check of this file. A documentation pin must prove the section makes
# the RIGHT claim, not merely that the right words appear somewhere in it.
#
# Two independent existence checks ("keyword somewhere in the section" AND
# "literal somewhere in the library") are satisfied by prose asserting the exact
# opposite of the library, and by a paragraph of keywords containing no true
# statement at all. So the claim is located first -- the sentence carrying the
# keyword -- and then judged in place:
#
#   1. the claim must be made      (a sentence carries the keyword)
#   2. it must say the right thing (that sentence matches <required-ere>)
#   3. it must not say the opposite (that sentence does not match <forbidden-ere>)
#
# Pass an empty <forbidden-ere> to skip step 3.
assert_claim() {
  local text="$1" keyword="$2" required="$3" forbidden="$4" label="$5"
  local found

  found="$(claim_sentence "$text" "$keyword")"
  if [ -z "$found" ]; then
    printf 'claim not made (%s): no sentence matches %s\n' "$label" "$keyword" >&2
    return 1
  fi

  if ! printf '%s' "$found" | grep -qiE "$required"; then
    printf 'claim present but wrong (%s).\n' "$label" >&2
    printf '  expected the sentence to match: %s\n' "$required" >&2
    printf '  actual sentence(s):\n%s\n' "$found" >&2
    return 1
  fi

  if [ -n "$forbidden" ] && printf '%s' "$found" | grep -qiE "$forbidden"; then
    printf 'claim contradicted (%s): sentence matches the negation %s\n' "$label" "$forbidden" >&2
    printf '  actual sentence(s):\n%s\n' "$found" >&2
    return 1
  fi
}

# refute_wording <text> <basic-regex> — fail, loudly, when <text> contains the
# forbidden wording.
#
# Every negative assertion in this file goes through here rather than through a
# bare `! grep`. Bash exempts a !-inverted command from errexit, so under `set -e`
# (which bats applies to test bodies) a failing `! grep` in the MIDDLE of a test
# does not fail it -- execution simply continues. Only the final negated command
# decides the outcome, silently disarming every negative check above it. Writing
# the failure explicitly makes each one live, and names the offending phrase.
refute_wording() {
  if printf '%s' "$1" | grep -qi "$2"; then
    printf 'forbidden wording present (matches: %s):\n' "$2" >&2
    printf '%s' "$1" | grep -in "$2" >&2
    return 1
  fi
}

# refute_wording_ere — same contract, extended-regex flavour.
refute_wording_ere() {
  if printf '%s' "$1" | grep -qiE "$2"; then
    printf 'forbidden wording present (matches: %s):\n' "$2" >&2
    printf '%s' "$1" | grep -inE "$2" >&2
    return 1
  fi
}

# require_baseline — hard-fail (never skip) when the baseline fixture is
# missing. A missing baseline means these pins cannot do their job, and that
# must be loud.
require_baseline() {
  if [ ! -f "$BASELINE" ]; then
    printf 'baseline fixture missing: %s\n' "$BASELINE" >&2
    printf 'it pins the loader markers and the commit-type table; restore it.\n' >&2
    return 1
  fi
}

# commit_table_slice FILE — the Conventional Commits section of a given file,
# from its marker to the next level-2 heading. Reads stdin when FILE is "-".
commit_table_slice() {
  awk '
    index($0, "<!-- SECTION: commits -->") { inside = 1; seen = 0; next }
    inside && /^## / { if (seen) exit; seen = 1 }
    inside { print }
  ' "$1"
}

# leak_patterns — the internal traceability-ID shapes that must never appear in
# published prose. Kept as one alternation so every call checks the same set.
# Written with character classes so this file does not itself contain a literal
# identifier for the repo-wide gates to find.
leak_regex() {
  printf '%s' 'E[0-9]+-S[0-9]+|FR-[0-9]+|NFR-[0-9]+|SR-[0-9]+|ADR-[0-9]+|(AF|AI)-[0-9]{4}-[0-9]{2}|TC-[A-Z]|T-[0-9]+ |F-[0-9]+ '
}

# ---------------------------------------------------------------------------
# Group A -- SKILL.md structure and section pins (AC1)
# ---------------------------------------------------------------------------

@test "gaia-git-workflow SKILL.md carries the worktrees section marker (AC1)" {
  grep -qF "$MARKER" "$SKILL"
}

@test "the worktrees marker is spelled exactly as the four existing markers (AC1)" {
  # The four shipped markers all use the exact form "<!-- SECTION: name -->".
  # A loader matching that shape sees nothing if the new one is spelled
  # "<!--SECTION: worktrees-->" or with different casing.
  run grep -cE '^<!-- SECTION: worktrees -->$' "$SKILL"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | tr -d ' ')" = "1" ]
}

@test "the four pre-existing SECTION markers are byte-identical to the baseline (AC1)" {
  require_baseline

  local before after
  before="$(grep -n 'SECTION:' "$BASELINE" | grep -v 'SECTION: worktrees')"
  after="$(grep -n 'SECTION:' "$SKILL" | grep -v 'SECTION: worktrees')"

  # The baseline must really contain the four markers, or an emptied fixture
  # would make this pass by comparing nothing to nothing.
  local base_count
  base_count="$(printf '%s\n' "$before" | grep -c 'SECTION:' || true)"
  [ "$(printf '%s' "$base_count" | tr -d ' ')" -eq 4 ]

  # Compare the marker lines themselves, not their line numbers: inserting a
  # section legitimately shifts later markers down, but must not alter one.
  local before_text after_text
  before_text="$(printf '%s\n' "$before" | sed 's/^[0-9]*://')"
  after_text="$(printf '%s\n' "$after" | sed 's/^[0-9]*://')"
  [ "$before_text" = "$after_text" ]
}

@test "the About text agrees with the number of section markers in the file (AC1)" {
  # The About section tells a reader how many loadable sections exist. Adding a
  # marker without updating it leaves the file self-contradicting, so the count
  # is pinned to the markers actually present rather than to a fixed number.
  local marker_count
  marker_count="$(grep -c '^<!-- SECTION: .* -->$' "$SKILL" || true)"
  marker_count="$(printf '%s' "$marker_count" | tr -d ' ')"
  [ "$marker_count" -eq 5 ]

  # The four originals are described as preserved, and the fifth is NAMED on
  # that same About line. Scoped to the line: an unscoped file-wide grep for
  # "worktrees" is satisfied by the section marker itself, so deleting the
  # ", and adds a fifth (`worktrees`)" clause would not be noticed.
  local about
  about="$(grep -n 'sectioned-loading IDs' "$SKILL" | head -1 | cut -d: -f2-)"
  [ -n "$about" ]
  printf '%s' "$about" | grep -qF 'four original sectioned-loading IDs'
  printf '%s' "$about" | grep -qF 'worktrees'
}

@test "the worktrees section appears before the terminal Test Scenarios heading (AC1)" {
  local marker_line scenarios_line
  marker_line="$(grep -nF "$MARKER" "$SKILL" | head -1 | cut -d: -f1)"
  scenarios_line="$(grep -n '^## Test Scenarios' "$SKILL" | tail -1 | cut -d: -f1)"

  [ -n "$marker_line" ]
  [ -n "$scenarios_line" ]
  [ "$marker_line" -lt "$scenarios_line" ]
}

@test "the worktrees section documents creation (AC1)" {
  local body
  body="$(require_prose_subsection "creating" "creation")"
  # The parent is a SIBLING of the git top level, not a child of it. Prose
  # putting it inside the repository would be wrong about where to look, and a
  # bare "sibling" keyword elsewhere in the section would hide that.
  assert_claim "$body" '\.gaia-worktrees' \
    'sibling|beside|alongside|next to' \
    'inside the (repository|repo|code tree)|within the repository|subdirectory of the repo' \
    'the worktree parent is a sibling of the repository'

  # A new worktree starts from HEAD; the primary tree's work stays put.
  # The negation is directional: "reported rather than moved" is the CORRECT
  # statement, so the forbidden pattern must match only prose that actually
  # claims the work IS moved.
  assert_claim "$body" 'HEAD' \
    'starts from|stays|remains' \
    '(is|are|will be|gets?) (moved|relocated|transferred)|moves? (it|them|the work)' \
    'a new worktree starts from HEAD'
}

@test "the worktrees section documents branch resolution (AC1)" {
  local body
  body="$(require_prose_subsection "branch resolution" "branch resolution")"
  assert_claim "$body" 'feat/' \
    'feat/\{story_key\}|story branch|branch is' \
    '' \
    'the story branch carries the feat/ prefix'

  # The slug is trimmed; the story key never is.
  assert_claim "$body" 'trimmed' \
    'story key is never (trimmed|truncated)|slug is trimmed|over-long slug' \
    'story key is (trimmed|truncated)' \
    'the slug is trimmed, never the story key'
}

@test "the worktrees section documents the PROJECT_PATH working-directory contract (AC1)" {
  local body
  body="$(require_prose_subsection "working-directory contract" "PROJECT_PATH contract")"

  assert_claim "$body" 'PROJECT_PATH' \
    'resolve|points at|restored' \
    '' \
    'scripts resolve their working directory from PROJECT_PATH'

  # Restoration is conditional on the removal having succeeded. Stating it
  # unconditionally would misdescribe the one case that matters.
  assert_claim "$body" 'restored' \
    'only.*(succeed|success)|if.*(succeed|success)|iff' \
    'always restored|restored regardless|unconditionally restored' \
    'PROJECT_PATH is restored only when removal succeeded'
}

@test "the worktrees section documents the teardown and prune lifecycle (AC1)" {
  local body
  body="$(require_prose_subsection "teardown and prune" "teardown and prune")"
  assert_claim "$body" 'teardown' \
    'removes|remove|idempotent|never forces' \
    '' \
    'teardown removes the worktree'

  # Pruning is conservative -- it must be described as vetoed by a live owner /
  # foreign lock / unpushed work, not as an unconditional sweep.
  assert_claim "$body" 'prune' \
    'conservative|only when|left alone|clears a record' \
    'always clears|clears every|regardless' \
    'prune is conservative'
}

@test "the worktrees section carries its own scenario table (AC1)" {
  # A markdown table row inside the section body -- AC1 requires the section to
  # carry test scenarios of its own, not to borrow the file's terminal table.
  local rows
  rows="$(section_slice | grep -cE '^\|.*\|' || true)"
  [ "$(printf '%s' "$rows" | tr -d ' ')" -ge 3 ]
}

# ---------------------------------------------------------------------------
# Group B -- contract-fidelity pins: the docs match the code (AC1)
# ---------------------------------------------------------------------------

@test "the section names the exact opt-in variable and its exact value (AC1)" {
  # The gate compares against the literal 1: GAIA_WORKTREE_MODE=true leaves
  # worktree mode OFF. Prose that says "set it to true" is actively wrong, so
  # the documented form must carry the value, not just the variable name.
  local body
  body="$(section_slice)"

  # The sentence naming the variable must require the literal 1 AND must not
  # tell the reader that any other value works. Checking only that the string
  # "GAIA_WORKTREE_MODE=1" appears somewhere lets a following sentence say
  # "any truthy value enables it" with the pin still green.
  assert_claim "$body" 'GAIA_WORKTREE_MODE' \
    'GAIA_WORKTREE_MODE=1|= *"?1"?|literal|exactly' \
    'truthy|any value|also turns the mode (on|off)|=true.*(enable|turns? .*on)' \
    'opt-in variable requires the literal 1'

  # The prose must not claim =true enables the mode. If it mentions =true at
  # all, that sentence has to say it leaves the mode OFF.
  local true_sentence
  true_sentence="$(claim_sentence "$body" 'GAIA_WORKTREE_MODE=true')"
  if [ -n "$true_sentence" ]; then
    if ! printf '%s' "$true_sentence" | grep -qiE '\boff\b|does not enable|not enabled|leaves? the mode off'; then
      printf 'the =true sentence does not say the mode stays off:\n%s\n' "$true_sentence" >&2
      return 1
    fi
  fi

  # Oracle half: the variable and the literal 1 are compared on ONE line of the
  # library, so the doc claim is checked against the real gate.
  grep -qE '\$\{GAIA_WORKTREE_MODE:-\}"?[[:space:]]*=[[:space:]]*"1"' "$LIB"
}

@test "the section states worktree mode is off by default (AC1)" {
  local body
  body="$(section_slice)"

  # The default-state claim must say OFF, in the sentence that makes it. Prose
  # saying "on by default" contains the word "default" and would satisfy a bare
  # keyword check.
  assert_claim "$body" 'default' \
    'off by default|default.*\boff\b|disabled by default|opt-in' \
    'on by default|enabled by default|default.*\bon\b' \
    'worktree mode is off by default'

  assert_claim "$body" 'opt-in|opt in' \
    'opt-in|opt in' \
    'opt-out|always active|cannot be disabled' \
    'worktree mode is opt-in'
}

@test "the section documents non-git degradation as skip-not-failure (AC1)" {
  local body
  body="$(require_prose_subsection "no git work tree" "non-git degradation")"

  # The sentence about running in place must present it as a degradation, and
  # must not simultaneously call it an error or a halt.
  assert_claim "$body" 'in place' \
    'degrad|not a failure|rather than a failure|skip|continues' \
    'treated as an error|is an error|halts the run|aborts' \
    'non-git roots degrade rather than fail'

  # And the library really does treat it that way.
  grep -qF 'running in place' "$LIB"
}

@test "the section states that a worktree holding uncommitted or ignored files is kept (AC1)" {
  # The zero-orphan property is narrower than an unqualified reading suggests:
  # a gitignored file left by tooling keeps the worktree on a NORMAL successful
  # run. The prose has to say so, and name ignored files specifically.
  local body
  body="$(require_prose_subsection "teardown and prune" "teardown and prune")"

  # Locate the sentence that names ignored files and judge THAT sentence. A
  # bare "kept" anywhere in the section is satisfied even when the sentence
  # about ignored files says such a worktree is deleted anyway.
  assert_claim "$body" 'ignored' \
    'kept|preserved|left in place|not removed|survives' \
    'deleted anyway|nothing is kept|removed anyway|is deleted|are deleted' \
    'a worktree holding ignored files is kept'

  # The same claim from the other direction: wherever the section says a
  # worktree is kept, that sentence must not also say it is deleted.
  assert_claim "$body" 'kept|preserved' \
    'kept|preserved' \
    'nothing is kept|deleted anyway|removed anyway' \
    'the kept-worktree claim is not contradicted'

  # The library's own refusal considers ignored state.
  grep -qF -- '--ignored' "$LIB"
}

@test "the documented recovery command unlocks before removing (AC1)" {
  # A kept worktree stays LOCKED, so a bare "worktree remove --force" fails
  # with "cannot remove a locked working tree". The published recovery must
  # unlock first or it does not work.
  local body
  body="$(subsection_with_code "teardown and prune")"; [ -n "$body" ]
  printf '%s' "$body" | grep -qF 'worktree unlock'
  printf '%s' "$body" | grep -qE 'worktree unlock.*&&.*worktree remove'
}

@test "the section does not promise that teardown always removes the worktree (AC1)" {
  # Negative pin: absolute wording would contradict the kept-worktree case.
  #
  # The non-empty guard is load-bearing. Without it this test passes while the
  # section does not exist at all -- a negative assertion over an empty body is
  # vacuously true, which is precisely the fail-open shape a gate like this
  # exists to prevent.
  local body
  body="$(section_slice)"
  [ -n "$body" ]
  # Each forbidden phrase gets its OWN reporting check rather than a bare
  # `! grep`. Bash exempts a !-inverted command from errexit, so a failing
  # `! grep` mid-body does NOT fail the test -- only the last one would be
  # live, silently disarming every check above it.
  # Scoped to claims about ORPHANS/removal specifically. A bare "never leaves"
  # would also match legitimate prose about what the working-directory variable
  # never leaves behind, so the object of the claim is part of the pattern.
  # The absolute claim can ride ANY cleanup verb, not just "remove": "always
  # deleted", "always pruned", "always cleaned up" are the same false promise.
  # Adverb on either side, verb in every common form.
  refute_wording_ere "$body" \
    '(always|invariably|in all cases) [a-z]* ?(delete|deletes|deleted|remove|removes|removed|prune|prunes|pruned|reap|reaps|reaped|clean|cleans|cleaned|purge|purges|purged|discard|discards|discarded|wipe|wipes|wiped)'
  refute_wording_ere "$body" \
    '(delete|deletes|deleted|remove|removes|removed|prune|prunes|pruned|reap|reaps|reaped|clean|cleans|cleaned|purge|purges|purged|discard|discards|discarded|wipe|wipes|wiped) (it |them |the worktree )?(always|invariably|in all cases)'
  refute_wording_ere "$body" 'guarantees no orphan|never leaves (a|an|any) (orphan|worktree)|no orphans'
  # "unconditionally" can lead or trail the verb ("unconditionally removed" /
  # "removed unconditionally"), so match the adverb next to any of the verbs in
  # either order rather than fixing one word order.
  refute_wording_ere "$body" \
    'unconditionally (removed|remove|removes|run|runs|deleted|deletes)|(removed|remove|removes|run|runs|deleted|deletes) unconditionally|unconditional cleanup guarantee|zero orphaned|zero orphans'
}

# ---------------------------------------------------------------------------
# Group C -- branch-prefix pins (AC2)
# ---------------------------------------------------------------------------

@test "the branch-type list includes the feat/ story-branch prefix (AC2)" {
  grep -qE '^Types: .*`feat/`' "$SKILL"
}

@test "the branch-type list still carries the generic feature/ prefix (AC2)" {
  # feat/ is ADDED alongside feature/, not a rename of it. This skill is shared
  # by every stack dev agent, including projects that do not use story keys.
  grep -qE '^Types: .*`feature/`' "$SKILL"
}

@test "the documented story-branch prefix matches what git-branch.sh emits (AC2)" {
  # Pins the PREFIX, not the whole construction. The two writers differ on slug
  # capping (the library caps at 60 characters, this script does not), so
  # asserting identical branch-name construction would encode a falsehood.
  grep -qF 'BRANCH_NAME="feat/${STORY_KEY}-${SLUG}"' "$BRANCH_SCRIPT"
  grep -qF 'feat/' "$SKILL"
}

@test "the documented prefix also matches what the worktree library emits (AC2)" {
  grep -qF 'branch="feat/${story_key}-${slug}"' "$LIB"
  section_slice | grep -qF 'feat/'
}

@test "the commit-type table is byte-identical to the baseline (AC2)" {
  require_baseline

  local before after
  before="$(commit_table_slice "$BASELINE")"
  after="$(commit_table_slice "$SKILL")"

  # A truncated or emptied baseline must not make this pass vacuously: the
  # slice has to carry the real table.
  [ -n "$before" ]
  printf '%s' "$before" | grep -qF '| `feat` |'
  printf '%s' "$before" | grep -qF '| `perf` |'

  [ "$before" = "$after" ]
}

# ---------------------------------------------------------------------------
# Group D -- doc-site sync guard (AC3)
# ---------------------------------------------------------------------------

@test "the git-workflow doc-site page states the feat/ story-branch prefix (AC3)" {
  [ -f "$DOC_SKILL_PAGE" ]
  grep -qF 'feat/' "$DOC_SKILL_PAGE"
}

@test "the git-workflow doc-site page mentions worktree mode (AC3)" {
  [ -f "$DOC_SKILL_PAGE" ]
  grep -qi 'worktree' "$DOC_SKILL_PAGE"
  # Page chrome intact -- the mode-b-docs precedent.
  grep -qF 'href="../styles.css"' "$DOC_SKILL_PAGE"
}

@test "the doc-site page carries the same worktree claims as the skill (AC3)" {
  # A "sync" guard that only looks for the word `worktree` is satisfied by an
  # HTML page reduced to that one word, or by one that contradicts the skill
  # (publishing the known-wrong advice that any truthy value enables the mode).
  # The shared clause list below is applied to BOTH surfaces, so the two either
  # agree or the test fails.
  local page_text skill_text
  page_text="$(tr '\n' ' ' < "$DOC_SKILL_PAGE")"
  skill_text="$(section_slice)"

  # Clause 1 — opt-in / off by default, on both surfaces.
  assert_claim "$page_text" 'worktree mode' \
    'opt-in|opt in|off by default|disabled by default' \
    'on by default|enabled by default|any truthy|=true.*(enable|on)' \
    'doc-site: worktree mode is opt-in and off by default'
  assert_claim "$skill_text" 'opt-in|opt in|default' \
    'opt-in|opt in|off by default|disabled by default' \
    'on by default|enabled by default' \
    'skill: worktree mode is opt-in and off by default'

  # Clause 2 — a worktree holding uncommitted/ignored files is kept, not deleted.
  assert_claim "$page_text" 'ignored|uncommitted' \
    'kept|preserved|not deleted|left in place' \
    'deleted anyway|nothing is kept|removed anyway' \
    'doc-site: a worktree holding ignored files is kept'
  assert_claim "$skill_text" 'ignored' \
    'kept|preserved|left in place|not removed|survives' \
    'deleted anyway|nothing is kept|removed anyway' \
    'skill: a worktree holding ignored files is kept'

  # Clause 3 — the story-branch prefix agrees across surfaces.
  printf '%s' "$page_text" | grep -qF 'feat/'
  printf '%s' "$skill_text" | grep -qF 'feat/'
}

@test "the glossary promotion-chain definition mentions worktree mode (AC3)" {
  [ -f "$DOC_GLOSSARY" ]
  # Scoped to the promotion-chain definition itself: a worktree mention
  # elsewhere on the page must not satisfy this.
  local dd
  dd="$(awk '
    /id="promotion-chain"/ { inside = 1 }
    inside { print }
    inside && /<\/dd>/ { exit }
  ' "$DOC_GLOSSARY")"
  [ -n "$dd" ]
  printf '%s' "$dd" | grep -qi 'worktree'
}

@test "the lifecycle diagram's dev-story node mentions the worktree (AC3)" {
  [ -f "$DOC_LIFECYCLE" ]
  # Scoped to the dev-story node block, from its anchor to the closing tag.
  local node
  node="$(awk '
    /commands\/gaia-dev-story.html" class="ld-node"/ { inside = 1 }
    inside { print }
    inside && /<\/a>/ { exit }
  ' "$DOC_LIFECYCLE")"
  [ -n "$node" ]
  printf '%s' "$node" | grep -qi 'worktree'
}

# ---------------------------------------------------------------------------
# Group E -- negative pins (AC2, AC3)
# ---------------------------------------------------------------------------

@test "no internal traceability identifier appears in any touched HTML page (AC3)" {
  # The repository's prose leak gate scans only *.md under the plugin tree, so
  # the documentation-site pages this story edits are covered here or nowhere.
  #
  # Carve-out: EXACTLY the two pedagogical format-convention lines that predate
  # this story in the glossary, matched on their full content.
  #
  # A pattern-shaped carve-out such as "like <code>" would be too generous: it
  # also admits a real provenance citation (prose naming the story that
  # delivered a feature, phrased with the same "like <code>...</code>" shape),
  # which is precisely the leak this test exists to catch. Allowlisting the two
  # known lines verbatim means ANY new occurrence, in any of these files and in
  # any phrasing, is a failure.
  # Matched on NORMALISED content -- trimmed, inner whitespace collapsed -- so a
  # reindent or a rewrap of the surrounding paragraph does not turn a known
  # pedagogical line into a spurious failure. Still content-exact: any change to
  # the words themselves (including "like" -> "such as") drops out of the
  # allowlist and must be re-reviewed rather than silently exempted.
  local allow1 allow2
  allow1='artifacts by identifiers like <code>FR-001</code>.'
  allow2='by keys like <code>E3-S7</code> (Epic 3, Story 7).'

  local page line content hits
  for page in "$DOC_SKILL_PAGE" "$DOC_GLOSSARY" "$DOC_LIFECYCLE"; do
    [ -f "$page" ] || continue
    hits=""
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      content="${line#*:}"
      if [ "$page" = "$DOC_GLOSSARY" ]; then
        local norm
        norm="$(printf '%s' "$content" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]][[:space:]]*/ /g')"
        [ "$norm" = "$allow1" ] && continue
        [ "$norm" = "$allow2" ] && continue
      fi
      hits="$hits$line
"
    done <<EOF
$(grep -nE "$(leak_regex)" "$page" || true)
EOF
    if [ -n "$hits" ]; then
      printf 'leaked identifier in %s:\n%s\n' "$page" "$hits" >&2
      return 1
    fi
  done
}

@test "the SKILL.md worktrees section contains no internal traceability identifier (AC2)" {
  local hits
  hits="$(section_slice | grep -nE "$(leak_regex)" || true)"
  if [ -n "$hits" ]; then
    printf 'leaked identifier in the worktrees section:\n%s\n' "$hits" >&2
    return 1
  fi
  # The section must be non-empty, or this passes vacuously.
  [ -n "$(section_slice)" ]
}

@test "the new prose introduces no third dispatch verb (AC2)" {
  # Guards the drift this repository has hit before: prose inventing a third
  # spelling for an operation the tree already names one way, so a reader
  # cannot tell whether two spellings mean two things.
  #
  # Pinned to the worktree LIFECYCLE verbs, which this section actually owns and
  # the library already fixes the vocabulary for -- create / teardown / prune.
  # Deliberately NOT a list of invented synonyms for generic words like
  # "dispatch": legitimate prose uses those, and a test that forbids ordinary
  # English fails the next honest editorial pass instead of catching drift.
  local body
  body="$(section_slice)"
  [ -n "$body" ]

  # The library's own verbs must be the ones used.
  printf '%s' "$body" | grep -qi 'teardown\|tear down'
  printf '%s' "$body" | grep -qi 'prune'

  # Competing spellings for the same two operations.
  # Self-reporting, for the errexit reason documented on refute_wording.
  #
  # The optional `s` belongs on the VERB as well as the noun: "reap"/"reaps",
  # "sweep"/"sweeps", "vacuum"/"vacuums". Putting it only on the noun let every
  # third-person form through.
  refute_wording_ere "$body" \
    '\b(demolish|demolishes|destroy|destroys|dispose of|disposes of|reap|reaps) (the |a |an |any |stale )*worktrees?\b'
  refute_wording_ere "$body" \
    '\b(garbage[- ]collects?|sweeps?|vacuums?) (the |a |an |any |stale )*worktrees?\b'

  # Passive voice carries the same synonym past a verb-before-noun pattern:
  # "stale worktrees are garbage-collected", "is swept away", "are reaped by".
  refute_wording_ere "$body" \
    'worktrees?( [a-z]+)? (is|are|was|were|gets?|get) (being )?(demolished|destroyed|disposed of|reaped|garbage[- ]collected|swept|vacuumed|purged)'

  # …and with a pronoun subject ("They are reaped by the next run"), where the
  # noun is not adjacent to the verb at all.
  refute_wording_ere "$body" \
    '\b(it|they|these|those|each|both) (is|are|was|were|gets?|get) (being )?(demolished|destroyed|disposed of|reaped|garbage[- ]collected|swept|vacuumed|purged)'
}

@test "the rendered branch example sits only on a gate-carved-out line (AC2)" {
  # The prose leak gate rejects a bare story-key-shaped token. A fenced example
  # line is exactly the shape that fails it; the carve-outs are lines carrying
  # e.g. / Examples: / the {story_key} format marker.
  local offenders
  offenders="$(grep -nE 'E[0-9]+-S[0-9]+' "$SKILL" \
    | grep -vE 'e\.g\.' \
    | grep -vE 'Examples?:' \
    | grep -vE '\{story_key\}' \
    | grep -vE '\[0-9\]' \
    || true)"
  if [ -n "$offenders" ]; then
    printf 'story-key-shaped token outside a carve-out:\n%s\n' "$offenders" >&2
    return 1
  fi
}
