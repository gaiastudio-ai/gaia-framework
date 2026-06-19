#!/usr/bin/env bats
# classify-commits-squash-bump.bats — regression guard for the squash-promotion
# under-bump (a chore:/docs:/refactor: SUBJECT must not mask feat:/fix: body
# bullets). classifyCommitType returns max(subject_bump, body_bump).
#
# Before the fix, a `chore: promote …` subject short-circuited to "patch" and
# the body-bullet scan never ran, so a squash-promotion carrying feat: bullets
# under-bumped (patch instead of minor).

load 'test_helper.bash'

CLASSIFY_JS=""

setup() {
  common_setup
  CLASSIFY_JS="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/scripts/classify-commits.js"
}
teardown() { common_teardown; }

# classify <message> — print the bump for a single commit message.
classify() {
  CLASSIFY_JS="$CLASSIFY_JS" node -e '
    const {classifyCommitType} = require(process.env.CLASSIFY_JS);
    const fs = require("fs");
    process.stdout.write(String(classifyCommitType(fs.readFileSync(0, "utf8"))));
  ' <<<"$1"
}

@test "chore: subject + feat: body bullets => minor (the #1605 repro)" {
  run classify "chore: promote staging to main (#1603)
* feat(x): bash-dev agent (#1599)
* feat(y): embedded-dev agent (#1600)"
  [ "$output" = "minor" ]
}

@test "chore: subject + fix: body bullets => patch" {
  run classify "chore: promote staging to main
* fix(x): a bug fix"
  [ "$output" = "patch" ]
}

@test "chore: subject + chore/docs-only body bullets => patch (no escalation)" {
  run classify "chore: promote staging to main
* chore(x): housekeeping
* docs(y): tweak"
  [ "$output" = "patch" ]
}

@test "feat: subject => minor (unchanged)" {
  run classify "feat(x): a feature"
  [ "$output" = "minor" ]
}

@test "fix: subject => patch (unchanged)" {
  run classify "fix(x): a fix"
  [ "$output" = "patch" ]
}

@test "chore: subject + breaking feat body bullet => major" {
  run classify "chore: promote
* feat(x)!: breaking change"
  [ "$output" = "major" ]
}

@test "docs: subject + feat: body => minor (any non-bump subject escalates from feat body)" {
  run classify "docs: update changelog
* feat(z): real feature"
  [ "$output" = "minor" ]
}

@test "BREAKING CHANGE in body => major regardless of subject" {
  run classify "feat(a): big change

BREAKING CHANGE: removes the old API"
  [ "$output" = "major" ]
}

@test "chore-only squash (no feat/fix bullets) stays patch — squash-skip intent preserved" {
  run classify "chore: routine maintenance"
  [ "$output" = "patch" ]
}
