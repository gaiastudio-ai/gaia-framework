#!/usr/bin/env bats
# checkpoint-yields-skill-md.bats — gaia-meeting SKILL.md procedure rewrite
# (E76-S7, AC2, TC-MTG-CHKPT-2)
#
# These are static checks against the rewritten SKILL.md. They assert that
# the canonical user-prompt block and the five mandatory yield boundaries
# are documented. The runtime invocation of the yields is exercised in
# parse-resume-flags.bats and substrate-invariance.bats.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SKILL_MD="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/SKILL.md"
}

@test "SKILL.md exists" {
  [ -f "$SKILL_MD" ]
}

@test "the canonical user-prompt block is documented" {
  grep -F '[c]ontinue / [p]ause / [i]nterject "..." / [w]rap-up / [a]bort' "$SKILL_MD"
}

@test "the post-CHARTER yield is documented" {
  grep -E -i 'post-CHARTER (checkpoint )?yield' "$SKILL_MD"
}

@test "the post-RESEARCH yield is documented" {
  grep -E -i 'post-RESEARCH (checkpoint )?yield' "$SKILL_MD"
}

@test "the every-N DISCUSS-turn yield is documented" {
  grep -F 'meeting.checkpoint_every_n_turns' "$SKILL_MD"
}

@test "the pre-CLOSE yield is documented" {
  grep -E -i 'pre-CLOSE (checkpoint )?yield' "$SKILL_MD"
}

@test "the pre-SAVE yield is documented" {
  grep -E -i 'pre-SAVE (checkpoint )?yield' "$SKILL_MD"
}

@test "the --resume / --continue / --interject / --wrap-up flags are documented" {
  grep -F -- '--resume' "$SKILL_MD"
  grep -F -- '--continue' "$SKILL_MD"
  grep -F -- '--interject' "$SKILL_MD"
  grep -F -- '--wrap-up' "$SKILL_MD"
}

# A case here asserted that the skill names the decision record amending the
# write boundary. Published source must no longer carry internal traceability
# identifiers, so that reference was removed deliberately — the behaviour is
# gone rather than drifted, and the case is deleted rather than re-pinned.
# The amended invariant itself is asserted below.

@test "session state persists under the canonical meeting-sessions location" {
  # The tree moved from the legacy memory directory to the .gaia/ runtime
  # tree; assert the location the shipped helper actually writes.
  grep -F '.gaia/memory/meeting-sessions/' "$SKILL_MD"
}

@test "every session-state persist routes through the write boundary" {
  grep -E -i 'persist call MUST first pass' "$SKILL_MD"
  grep -F 'scripts/write-boundary.sh' "$SKILL_MD"
}

@test "the --no-web note for sensitive contexts appears alongside the post-CHARTER yield" {
  # The post-CHARTER section MUST surface a one-line note about --no-web for
  # sensitive contexts (T-MTG-4 mitigation c).
  grep -F -- '--no-web' "$SKILL_MD"
}
