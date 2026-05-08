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

@test "AC2: SKILL.md exists" {
  [ -f "$SKILL_MD" ]
}

@test "AC2: canonical user-prompt block is documented" {
  grep -F '[c]ontinue / [p]ause / [i]nterject "..." / [w]rap-up / [a]bort' "$SKILL_MD"
}

@test "AC2: post-CHARTER yield is documented" {
  grep -E -i 'post-CHARTER (checkpoint )?yield' "$SKILL_MD"
}

@test "AC2: post-RESEARCH yield is documented" {
  grep -E -i 'post-RESEARCH (checkpoint )?yield' "$SKILL_MD"
}

@test "AC2: every-N DISCUSS-turn yield is documented" {
  grep -F 'meeting.checkpoint_every_n_turns' "$SKILL_MD"
}

@test "AC2: pre-CLOSE yield is documented" {
  grep -E -i 'pre-CLOSE (checkpoint )?yield' "$SKILL_MD"
}

@test "AC2: pre-SAVE yield is documented" {
  grep -E -i 'pre-SAVE (checkpoint )?yield' "$SKILL_MD"
}

@test "AC2: --resume / --continue / --interject / --wrap-up flags are documented" {
  grep -F -- '--resume' "$SKILL_MD"
  grep -F -- '--continue' "$SKILL_MD"
  grep -F -- '--interject' "$SKILL_MD"
  grep -F -- '--wrap-up' "$SKILL_MD"
}

@test "AC2: ADR-083 amendment is referenced" {
  grep -E 'ADR-083.*amend|amend.*ADR-083' "$SKILL_MD"
}

@test "AC2: FR-MTG-31 amended write-boundary cites _memory/meeting-sessions/" {
  grep -F '_memory/meeting-sessions/' "$SKILL_MD"
}

@test "AC2: --no-web note appears alongside post-CHARTER yield (T-MTG-4 mitigation c)" {
  # The post-CHARTER section MUST surface a one-line note about --no-web for
  # sensitive contexts (T-MTG-4 mitigation c).
  grep -F -- '--no-web' "$SKILL_MD"
}
