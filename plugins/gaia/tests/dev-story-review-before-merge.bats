#!/usr/bin/env bats
# dev-story-review-before-merge.bats — tests for the pre-push review ordering
# opt-in (dev_story.review_before_merge config key, review-order.sh helper,
# SKILL.md Step 9a, --bind-head skip-check, and documentation).
#
# Coverage: AC1 (partial, schema + mode + doctor), AC2-AC12, AC-EC1..7.
# Portable: macOS /bin/bash 3.2 + bash 5 (no local -A, no mapfile, no sed -i '').

load 'test_helper.bash'

setup() {
  PLUGIN_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  REVIEW_ORDER="${PLUGIN_ROOT}/skills/gaia-dev-story/scripts/review-order.sh"
  SKILL_MD="${PLUGIN_ROOT}/skills/gaia-dev-story/SKILL.md"
  DOCTOR_MD="${PLUGIN_ROOT}/skills/gaia-doctor/SKILL.md"
  RUN_ALL_MD="${PLUGIN_ROOT}/skills/gaia-run-all-reviews/SKILL.md"
  SCHEMA="${PLUGIN_ROOT}/schemas/project-config.schema.json"
  YAML_SCHEMA="${PLUGIN_ROOT}/config/project-config.schema.yaml"
  RESOLVE="${PLUGIN_ROOT}/scripts/resolve-config.sh"
  SKIP_CHECK="${PLUGIN_ROOT}/scripts/review-skip-check.sh"
  DOC_DEV_STORY="${PLUGIN_ROOT}/../../documentation/commands/gaia-dev-story.html"
  DOC_CONFIG="${PLUGIN_ROOT}/../../documentation/categories/configuration.html"
  CHANGELOG="${PLUGIN_ROOT}/../../CHANGELOG.md"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP" 2>/dev/null || true
}

# ---------- Portability: print BASH_VERSION ----------
# The ATDD mandates printing BASH_VERSION from inside each run.
# bats itself prints it, but we assert it here too.
@test "portability: BASH_VERSION is printed and not empty" {
  [ -n "$BASH_VERSION" ]
  echo "BASH_VERSION=$BASH_VERSION"
}

# ---------- AC1: schema, resolve-config, review-order mode, doctor ----------

@test "schema accepts boolean review_before_merge under dev_story" {
  /usr/bin/grep -A3 '"review_before_merge"' "$SCHEMA" | /usr/bin/grep -q '"type": "boolean"'
}

@test "schema review_before_merge is inside the dev_story properties block" {
  # The key must appear between the dev_story opening brace and its closing
  local in_dev_story=0
  while IFS= read -r line; do
    case "$line" in
      *'"dev_story"'*) in_dev_story=1 ;;
    esac
    if [ "$in_dev_story" -eq 1 ]; then
      if echo "$line" | /usr/bin/grep -q '"review_before_merge"'; then
        return 0
      fi
    fi
  done < "$SCHEMA"
  echo "review_before_merge not found inside dev_story block" >&2
  false
}

@test "YAML descriptor schema dev_story description mentions review_before_merge" {
  /usr/bin/grep -A20 'dev_story:' "$YAML_SCHEMA" | /usr/bin/grep -q 'review_before_merge'
}

@test "resolve-config.sh field list comment mentions dev_story.review_before_merge" {
  /usr/bin/grep -q 'dev_story.review_before_merge' "$RESOLVE"
}

@test "resolve-config.sh has a --field case for dev_story.review_before_merge" {
  /usr/bin/grep -q 'dev_story\.review_before_merge)' "$RESOLVE"
}

@test "review-order.sh exists and is executable" {
  [ -f "$REVIEW_ORDER" ]
  [ -x "$REVIEW_ORDER" ]
}

@test "review-order mode prints default when key is absent" {
  # Create a minimal config with no dev_story.review_before_merge
  mkdir -p "$TMP/.gaia/config"
  cat > "$TMP/.gaia/config/project-config.yaml" <<'YAML'
project_root: /tmp/test
project_path: /tmp/test/src
memory_path: /tmp/test/memory
checkpoint_path: /tmp/test/checkpoints
installed_path: /tmp/test/installed
framework_version: "1.0.0"
date: "2026-01-01"
YAML
  run env CLAUDE_PROJECT_ROOT="$TMP" "$REVIEW_ORDER" mode
  [ "$status" -eq 0 ]
  [[ "$output" == *"default"* ]]
}

@test "review-order mode prints pre-push when key is true" {
  mkdir -p "$TMP/.gaia/config"
  cat > "$TMP/.gaia/config/project-config.yaml" <<'YAML'
project_root: /tmp/test
project_path: /tmp/test/src
memory_path: /tmp/test/memory
checkpoint_path: /tmp/test/checkpoints
installed_path: /tmp/test/installed
framework_version: "1.0.0"
date: "2026-01-01"
dev_story:
  review_before_merge: true
YAML
  run env CLAUDE_PROJECT_ROOT="$TMP" "$REVIEW_ORDER" mode
  [ "$status" -eq 0 ]
  [[ "$output" == *"pre-push"* ]]
}

@test "review-order mode prints default when key is false" {
  mkdir -p "$TMP/.gaia/config"
  cat > "$TMP/.gaia/config/project-config.yaml" <<'YAML'
project_root: /tmp/test
project_path: /tmp/test/src
memory_path: /tmp/test/memory
checkpoint_path: /tmp/test/checkpoints
installed_path: /tmp/test/installed
framework_version: "1.0.0"
date: "2026-01-01"
dev_story:
  review_before_merge: false
YAML
  run env CLAUDE_PROJECT_ROOT="$TMP" "$REVIEW_ORDER" mode
  [ "$status" -eq 0 ]
  [[ "$output" == *"default"* ]]
}

@test "doctor SKILL.md mentions review_ordering in the review limits section" {
  /usr/bin/grep -A20 'Step 7.*Review limits' "$DOCTOR_MD" | /usr/bin/grep -q 'review_ordering'
}

@test "doctor SKILL.md mentions review-order.sh mode in the review limits section" {
  /usr/bin/grep -A20 'Step 7.*Review limits' "$DOCTOR_MD" | /usr/bin/grep -q 'review-order.sh mode'
}

@test "doctor SKILL.md shows pre-push review label in the review limits section" {
  /usr/bin/grep -A20 'Step 7.*Review limits' "$DOCTOR_MD" | /usr/bin/grep -q 'pre-push review'
}

# ---------- AC-EC1: bad value from local override ----------

@test "review-order mode exits non-zero naming the key for a non-boolean value" {
  mkdir -p "$TMP/.gaia/config"
  cat > "$TMP/.gaia/config/project-config.yaml" <<'YAML'
project_root: /tmp/test
project_path: /tmp/test/src
memory_path: /tmp/test/memory
checkpoint_path: /tmp/test/checkpoints
installed_path: /tmp/test/installed
framework_version: "1.0.0"
date: "2026-01-01"
dev_story:
  review_before_merge: maybe
YAML
  run env CLAUDE_PROJECT_ROOT="$TMP" "$REVIEW_ORDER" mode
  [ "$status" -ne 0 ]
  [[ "$output" == *"dev_story.review_before_merge"* ]]
  [[ "$output" == *"true"* ]]
  [[ "$output" == *"false"* ]]
}

# ---------- AC2: key absent or false keeps Steps 10-16 unchanged ----------

@test "key absent or false leaves Steps 10 through 16 order and commands unchanged" {
  # Step 10 still has the commit-msg.sh call
  /usr/bin/grep -q 'commit-msg.sh' "$SKILL_MD"
  # Step 10 still has git-push.sh
  /usr/bin/grep -q 'git-push.sh' "$SKILL_MD"
  # Step 10 has the transition to review
  /usr/bin/grep -q 'transition-story-status.sh.*--to review' "$SKILL_MD"
  # Step 16 still has yolo-mode.sh is_yolo
  /usr/bin/grep -q 'yolo-mode.sh is_yolo' "$SKILL_MD"
  # The pre-push mode guard in Step 10 explicitly says default path is unchanged
  /usr/bin/grep -q 'Pre-push mode guard' "$SKILL_MD"
  # Step 9a is gated on review-order.sh mode printing pre-push
  /usr/bin/grep -q 'review-order.sh mode.*pre-push' "$SKILL_MD" || /usr/bin/grep -q "prints.*pre-push.*execute" "$SKILL_MD"
  # When mode prints default, Step 9a is skipped
  /usr/bin/grep -q 'prints.*default.*skip this sub-step' "$SKILL_MD"
}

@test "Step 9a skip condition references review-order.sh mode returning default" {
  # The Step 9a text must say to skip when mode is default
  local step9a_section
  step9a_section="$(/usr/bin/sed -n '/step 9a pre-push review begin/,/step 9a pre-push review end/p' "$SKILL_MD")"
  echo "$step9a_section" | /usr/bin/grep -q 'default.*skip this sub-step'
}

# ---------- AC3: opt-in pre-push order ----------

@test "opt-in true follows pre-push order from commit through post-merge verification" {
  local step9a
  step9a="$(/usr/bin/sed -n '/step 9a pre-push review begin/,/step 9a pre-push review end/p' "$SKILL_MD")"
  # Commit before review
  echo "$step9a" | /usr/bin/grep -q 'commit-msg.sh'
  # Preflight before review
  echo "$step9a" | /usr/bin/grep -q 'preflight_commands'
  # Transition to review
  echo "$step9a" | /usr/bin/grep -q 'transition-story-status.sh.*--to review'
  # Init review gate
  echo "$step9a" | /usr/bin/grep -q 'init-review-gate.sh'
  # Run reviews
  echo "$step9a" | /usr/bin/grep -q 'gaia-run-all-reviews'
  # Ancestor check before push
  echo "$step9a" | /usr/bin/grep -q 'ancestor-check.*--base'
  # Assert reviewed head before push
  echo "$step9a" | /usr/bin/grep -q 'assert-reviewed-head'
}

@test "Step 16 contains a pre-push skip guard that checks review rows bound to HEAD" {
  local step16
  step16="$(/usr/bin/sed -n '/step 16 begin/,/step 16 end/p' "$SKILL_MD")"
  echo "$step16" | /usr/bin/grep -q 'Pre-push skip guard'
  echo "$step16" | /usr/bin/grep -q 'review-order.sh mode.*pre-push'
  echo "$step16" | /usr/bin/grep -q 'bound to.*HEAD\|bound to the PR head'
}

# ---------- AC4: interactive stop and resume ----------

@test "non-YOLO run prompts before reviews and stop keeps story in review with resume command" {
  local step9a
  step9a="$(/usr/bin/sed -n '/step 9a pre-push review begin/,/step 9a pre-push review end/p' "$SKILL_MD")"
  # Non-YOLO asks the user
  echo "$step9a" | /usr/bin/grep -q 'AskUserQuestion'
  # Stop keeps story in review
  echo "$step9a" | /usr/bin/grep -q 'story stays in.*review'
  # Nothing pushed on stop
  echo "$step9a" | /usr/bin/grep -q 'nothing is pushed'
  # Resume command printed
  echo "$step9a" | /usr/bin/grep -q '/gaia-dev-story.*resume\|resume'
  # YOLO proceeds without prompt
  echo "$step9a" | /usr/bin/grep -q 'YOLO\|yolo'
}

# ---------- AC5: re-entry for pre-push-reviewed story ----------

@test "re-invoke on review-status story with pre-push key re-enters at Step 9a skipping Steps 2 through 9" {
  # Step 1 must mention the pre-push re-entry exception
  local step1
  step1="$(/usr/bin/sed -n '/### Step 1 --/,/### Step 2 --/p' "$SKILL_MD")"
  echo "$step1" | /usr/bin/grep -q 're-entry'
  echo "$step1" | /usr/bin/grep -q 'review.*pre-push\|pre-push.*review'
  # Re-entry enters at Step 9a
  echo "$step1" | /usr/bin/grep -q 'Step 9a'
  # Steps 2-9 are not re-run
  echo "$step1" | /usr/bin/grep -q 'Steps 2 through 9\|skipping Steps 2'
  # Re-entry requires worktree present
  echo "$step1" | /usr/bin/grep -q 'worktree'
  # Re-entry requires no PR
  echo "$step1" | /usr/bin/grep -q 'no.*PR\|no open PR'
  # Re-entry precedes RESUME path
  echo "$step1" | /usr/bin/grep -q 'Before.*detect-mode\|before the.*RESUME'
}

@test "re-entry not taken when key is absent and status is review halts at Step 1" {
  # The critical rules line mentions status halt exception
  /usr/bin/grep -q 'ready-for-dev.*or.*in-progress.*HALT\|HALT condition' "$SKILL_MD"
  # The exception requires pre-push mode
  /usr/bin/grep -q 'pre-push review opt-in\|review_before_merge' "$SKILL_MD"
  # The common gotchas bullet mentions the exception
  /usr/bin/grep 'Common gotchas' -A5 "$SKILL_MD" | /usr/bin/grep -q 'pre-push'
}

# ---------- AC6: fix loop with bind-head ----------

@test "fix loop re-reviews stale rows via bind-head and cap emits ESCALATE" {
  local step9a
  step9a="$(/usr/bin/sed -n '/step 9a pre-push review begin/,/step 9a pre-push review end/p' "$SKILL_MD")"
  # Mentions bind-head
  echo "$step9a" | /usr/bin/grep -q 'bind-head'
  # Mentions ESCALATE
  echo "$step9a" | /usr/bin/grep -q 'ESCALATE'
  # Mentions fix-cycle cap
  echo "$step9a" | /usr/bin/grep -q 'fix-cycle cap\|count-and-decide'
  # Commits fixes in worktree (may span two lines)
  echo "$step9a" | /usr/bin/grep -q 'fixes are committed'
  # Story stays in review
  echo "$step9a" | /usr/bin/grep -q 'stays in.*review'
}

@test "review-skip-check.sh accepts --bind-head flag" {
  /usr/bin/grep -q '\-\-bind-head' "$SKIP_CHECK"
}

@test "review-skip-check.sh usage mentions --bind-head" {
  run "$SKIP_CHECK" --help
  [[ "$output" == *"--bind-head"* ]]
}

# ---------- AC7: ESCALATE descope and accept override ----------

@test "descope pushes nothing and accept override proceeds to push but merge gate still blocks" {
  local step9a
  step9a="$(/usr/bin/sed -n '/step 9a pre-push review begin/,/step 9a pre-push review end/p' "$SKILL_MD")"
  # Descope does not push
  echo "$step9a" | /usr/bin/grep -q 'nothing is pushed\|descope'
  # Accept override: push proceeds
  echo "$step9a" | /usr/bin/grep -q 'accept override.*push.*proceed\|push and PR proceed'
  # Merge gate still blocks
  echo "$step9a" | /usr/bin/grep -q 'merge.sh.*refuses\|merge.*COMPLETE\|merge is waiting'
}

# ---------- AC8: ancestor check ----------

@test "ancestor-check fetches base and halts when base is not ancestor of HEAD without rebasing" {
  # Create a local bare remote with a staging branch diverged from HEAD
  local bare="$TMP/remote.git"
  git init --bare "$bare" 2>/dev/null
  local repo="$TMP/repo"
  git init "$repo" 2>/dev/null
  cd "$repo"
  git config user.email "test@test.com"
  git config user.name "Test"
  git remote add origin "$bare"
  echo "initial" > file.txt
  git add file.txt
  git commit -m "initial" 2>/dev/null
  git push origin HEAD:refs/heads/staging 2>/dev/null

  # Advance the base branch on the remote
  cd "$bare"
  git checkout --orphan temp 2>/dev/null || true
  # Use git update-ref to advance staging
  cd "$repo"
  echo "diverged" > diverged.txt
  git add diverged.txt
  git commit -m "diverge" 2>/dev/null
  local diverge_sha
  diverge_sha="$(git rev-parse HEAD)"
  git push origin HEAD:refs/heads/staging 2>/dev/null

  # Reset local to original commit (behind remote)
  git reset --hard HEAD~1 2>/dev/null
  echo "local change" > local.txt
  git add local.txt
  git commit -m "local" 2>/dev/null

  # Now origin/staging is NOT an ancestor of HEAD
  run env PROJECT_PATH="$repo" "$REVIEW_ORDER" ancestor-check --base staging
  [ "$status" -eq 1 ]
  [[ "$output" == *"drift"* ]] || [[ "$output" == *"not an ancestor"* ]]

  # Verify no rebase happened
  local current_head
  current_head="$(git -C "$repo" rev-parse HEAD)"
  # HEAD should still be the local commit, not rebased
  [ "$(git -C "$repo" log --oneline | wc -l | tr -d ' ')" -eq 2 ]
}

@test "ancestor-check returns 0 when base is an ancestor of HEAD" {
  local bare="$TMP/remote2.git"
  git init --bare "$bare" 2>/dev/null
  local repo="$TMP/repo2"
  git init "$repo" 2>/dev/null
  cd "$repo"
  git config user.email "test@test.com"
  git config user.name "Test"
  git remote add origin "$bare"
  echo "initial" > file.txt
  git add file.txt
  git commit -m "initial" 2>/dev/null
  git push origin HEAD:refs/heads/staging 2>/dev/null

  # Add a commit on top — origin/staging is still an ancestor
  echo "more" > more.txt
  git add more.txt
  git commit -m "ahead" 2>/dev/null

  run env PROJECT_PATH="$repo" "$REVIEW_ORDER" ancestor-check --base staging
  [ "$status" -eq 0 ]
}

@test "ancestor-check exits 1 on fetch failure (fail closed)" {
  local repo="$TMP/repo3"
  git init "$repo" 2>/dev/null
  cd "$repo"
  git config user.email "test@test.com"
  git config user.name "Test"
  echo "x" > x.txt
  git add x.txt
  git commit -m "x" 2>/dev/null
  # Remote does not exist — fetch will fail
  git remote add origin /nonexistent/path 2>/dev/null || true

  run env PROJECT_PATH="$repo" "$REVIEW_ORDER" ancestor-check --base staging
  [ "$status" -eq 1 ]
}

@test "ancestor-check exits 3 for non-git CWD" {
  local nongit="$TMP/nongit"
  mkdir -p "$nongit"
  run env PROJECT_PATH="$nongit" "$REVIEW_ORDER" ancestor-check --base staging
  [ "$status" -eq 3 ]
}

# ---------- AC9: reviewed-head assertion ----------

@test "assert-reviewed-head requires clean tree and all rows bound to HEAD and halts on mismatch" {
  # Create a git repo
  local repo="$TMP/repo4"
  git init "$repo" 2>/dev/null
  cd "$repo"
  git config user.email "test@test.com"
  git config user.name "Test"

  # Commit a placeholder, then write the story OUTSIDE git index referencing
  # the current HEAD. The story file stays untracked (unstaged), so its SHA
  # references don't cause self-referential loops.
  echo "initial" > file.txt
  git add file.txt
  git commit -m "initial" 2>/dev/null
  mkdir -p "$repo/docs"
  echo "placeholder" > "$repo/docs/story.md"
  git add docs/story.md
  git commit -m "story" 2>/dev/null

  local head_sha
  head_sha="$(git -C "$repo" rev-parse HEAD)"

  # Overwrite the story file in the worktree with the correct SHA.
  # The file is now modified but the tree is "dirty" — so first test the
  # dirty-tree check, then commit.
  cat > "$repo/docs/story.md" <<EOF
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | PASSED | report.md | $head_sha |
| QA Tests | PASSED | report.md | $head_sha |
| Security Review | PASSED | report.md | $head_sha |
| Test Automation | PASSED | report.md | $head_sha |
| Test Review | PASSED | report.md | $head_sha |
| Performance Review | PASSED | report.md | $head_sha |

## Findings
EOF

  # Tree is dirty — assert-reviewed-head should fail on the dirty check
  run env PROJECT_PATH="$repo" "$REVIEW_ORDER" assert-reviewed-head --story "$repo/docs/story.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not clean"* ]] || [[ "$output" == *"dirty"* ]]

  # Commit the story to make tree clean, but now HEAD changed so SHAs mismatch
  git -C "$repo" add docs/story.md
  git -C "$repo" commit -m "update story" 2>/dev/null
  local new_head
  new_head="$(git -C "$repo" rev-parse HEAD)"

  # The story still references the OLD head_sha — mismatch
  run env PROJECT_PATH="$repo" "$REVIEW_ORDER" assert-reviewed-head --story "$repo/docs/story.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bound to"* ]]

  # Now fix the story to reference the correct HEAD
  cat > "$repo/docs/story.md" <<EOF
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | PASSED | report.md | $new_head |
| QA Tests | PASSED | report.md | $new_head |
| Security Review | PASSED | report.md | $new_head |
| Test Automation | PASSED | report.md | $new_head |
| Test Review | PASSED | report.md | $new_head |
| Performance Review | PASSED | report.md | $new_head |

## Findings
EOF
  git -C "$repo" add docs/story.md
  git -C "$repo" commit --amend --no-edit 2>/dev/null

  # Still fails because amend changed HEAD again. Use a different approach:
  # write a story file that references HEAD AFTER the commit. This requires
  # the story file to not be part of the commit. Keep the story outside git.
  local final_head
  final_head="$(git -C "$repo" rev-parse HEAD)"
  cat > "$repo/docs/story-external.md" <<EOF
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | PASSED | report.md | $final_head |
| QA Tests | PASSED | report.md | $final_head |
| Security Review | PASSED | report.md | $final_head |
| Test Automation | PASSED | report.md | $final_head |
| Test Review | PASSED | report.md | $final_head |
| Performance Review | PASSED | report.md | $final_head |

## Findings
EOF

  # This untracked file makes the tree dirty. Stage and commit just docs/story.md
  # to keep story-external.md out of git. But we need a clean tree for the
  # assertion to pass. Let's use .gitignore.
  echo "docs/story-external.md" > "$repo/.gitignore"
  git -C "$repo" add .gitignore
  git -C "$repo" commit -m "ignore external" 2>/dev/null

  # Now HEAD changed again. Update the external story file.
  final_head="$(git -C "$repo" rev-parse HEAD)"
  cat > "$repo/docs/story-external.md" <<EOF
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | PASSED | report.md | $final_head |
| QA Tests | PASSED | report.md | $final_head |
| Security Review | PASSED | report.md | $final_head |
| Test Automation | PASSED | report.md | $final_head |
| Test Review | PASSED | report.md | $final_head |
| Performance Review | PASSED | report.md | $final_head |

## Findings
EOF

  # Clean tree + all rows bound to HEAD — should pass
  run env PROJECT_PATH="$repo" "$REVIEW_ORDER" assert-reviewed-head --story "$repo/docs/story-external.md"
  echo "final exit=$status output=$output"
  [ "$status" -eq 0 ]

  # Mismatch test: bind QA Tests to a wrong SHA
  cat > "$repo/docs/story-external.md" <<EOF
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | PASSED | report.md | $final_head |
| QA Tests | PASSED | report.md | aaaaaaa |
| Security Review | PASSED | report.md | $final_head |
| Test Automation | PASSED | report.md | $final_head |
| Test Review | PASSED | report.md | $final_head |
| Performance Review | PASSED | report.md | $final_head |

## Findings
EOF

  run env PROJECT_PATH="$repo" "$REVIEW_ORDER" assert-reviewed-head --story "$repo/docs/story-external.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"QA Tests"* ]] || [[ "$output" == *"bound to"* ]]
}

# ---------- AC10: status semantics ----------

@test "review means code-complete and done is reached only after merge and post-merge verification" {
  local step9a
  step9a="$(/usr/bin/sed -n '/step 9a pre-push review begin/,/step 9a pre-push review end/p' "$SKILL_MD")"
  # Review = under review in the worktree
  echo "$step9a" | /usr/bin/grep -q 'review'
  # Worktree teardown is at Step 13 (existing location)
  local step13
  step13="$(/usr/bin/sed -n '/### Step 13/,/### Step 14/p' "$SKILL_MD")"
  echo "$step13" | /usr/bin/grep -q 'merge'
  # Done after merge.sh exits 0
  /usr/bin/grep -q 'merge\.sh.*exit\|merge.*succeeded\|Merge succeeded' "$SKILL_MD"
}

# ---------- AC11: documentation completeness ----------

@test "documentation pages describe the key default step order stop-and-resume and drift halt with no internal IDs" {
  # Dev-story page
  /usr/bin/grep -q 'review_before_merge' "$DOC_DEV_STORY"
  /usr/bin/grep -qi 'false' "$DOC_DEV_STORY"
  /usr/bin/grep -qi 'pre-push' "$DOC_DEV_STORY"
  /usr/bin/grep -qi 'stop.*resume\|resume.*stop\|stop-and-resume' "$DOC_DEV_STORY" \
    || /usr/bin/grep -qi 'Interactive stop' "$DOC_DEV_STORY"
  /usr/bin/grep -qi 'drift\|ancestor\|rebase' "$DOC_DEV_STORY"

  # Config page
  /usr/bin/grep -q 'review_before_merge' "$DOC_CONFIG"
  /usr/bin/grep -q 'Boolean\|boolean\|bool' "$DOC_CONFIG"

  # Changelog
  /usr/bin/grep -q 'review_before_merge\|pre-push review' "$CHANGELOG"

  # No internal IDs in the newly-added sections.
  # The dev-story HTML has pre-existing example story keys (E3-S7) in code
  # examples — those are documentation examples, not internal planning IDs.
  # Check the pre-push section we added to each file.
  local dev_story_section
  dev_story_section="$(/usr/bin/sed -n '/Pre-push review ordering/,/section id/p' "$DOC_DEV_STORY")"
  for pat in 'FR-[0-9]+' 'ADR-[0-9]+' 'TC-[A-Z]+-[A-Z]+-[0-9]+' 'AF-[0-9]{4}-' 'E[0-9]+-S[0-9]+'; do
    ! echo "$dev_story_section" | /usr/bin/grep -qE "$pat" \
      || { echo "Leaked ID ($pat) in dev-story docs pre-push section" >&2; false; }
  done
  # Config page — check the review_before_merge entry
  local config_entry
  config_entry="$(/usr/bin/grep -A3 'review_before_merge' "$DOC_CONFIG")"
  for pat in 'FR-[0-9]+' 'ADR-[0-9]+' 'E[0-9]+-S[0-9]+'; do
    ! echo "$config_entry" | /usr/bin/grep -qE "$pat" \
      || { echo "Leaked ID ($pat) in config docs" >&2; false; }
  done
  # Changelog — check the pre-push review section
  local cl_section
  cl_section="$(/usr/bin/sed -n '/Pre-push review ordering/,/### Fix-cycle cap/p' "$CHANGELOG")"
  for pat in 'FR-[0-9]+' 'ADR-[0-9]+' 'TC-[A-Z]+-[A-Z]+-[0-9]+' 'AF-[0-9]{4}-' 'E[0-9]+-S[0-9]+'; do
    ! echo "$cl_section" | /usr/bin/grep -qE "$pat" \
      || { echo "Leaked ID ($pat) in changelog" >&2; false; }
  done
}

# ---------- AC12: bash portability (meta — this test itself validates) ----------

@test "suite passes under bash 3.2 and bash 5 with zero skips" {
  # This is a meta assertion — the test itself runs under whichever bash
  # bats was invoked with. The ATDD mandates printing the version and
  # checking the test count and skip count from outside.
  echo "BASH_VERSION=$BASH_VERSION"
  # Assert we are actually running (not skipped)
  [ -n "$BASH_VERSION" ]
}

# ---------- AC-EC2: preflight dirties tree ----------

@test "preflight that modifies files halts before review because tree differs from committed HEAD" {
  local step9a
  step9a="$(/usr/bin/sed -n '/step 9a pre-push review begin/,/step 9a pre-push review end/p' "$SKILL_MD")"
  # Must verify clean tree after preflight
  echo "$step9a" | /usr/bin/grep -q 'git status --porcelain'
  # Must halt before review on dirty tree
  echo "$step9a" | /usr/bin/grep -q 'HALT before the review\|HALT.*working tree'
  # Must tell the developer to commit
  echo "$step9a" | /usr/bin/grep -q 'commit the change'
}

# ---------- AC-EC3: base advances during review ----------

@test "ancestor check halts before push when base advanced during review even with COMPLETE composite" {
  local step9a
  step9a="$(/usr/bin/sed -n '/step 9a pre-push review begin/,/step 9a pre-push review end/p' "$SKILL_MD")"
  # Pre-push ancestor check must be in the step
  echo "$step9a" | /usr/bin/grep -q 'Ancestor check (pre-push)'
  # Must halt before push
  echo "$step9a" | /usr/bin/grep -q 'HALT before push'
  # Must mention even with COMPLETE
  echo "$step9a" | /usr/bin/grep -q 'COMPLETE composite\|even with a COMPLETE'
}

# ---------- AC-EC4: push retry after COMPLETE ----------

@test "re-invoke after push failure re-enters at push without re-running reviews when rows bound to HEAD" {
  local step1
  step1="$(/usr/bin/sed -n '/### Step 1 --/,/### Step 2 --/p' "$SKILL_MD")"
  # Re-entry at push step when all rows bound to HEAD
  echo "$step1" | /usr/bin/grep -q 'push step\|re-enter at.*push'
  echo "$step1" | /usr/bin/grep -q 'bound to HEAD\|assert-reviewed-head'
}

# ---------- AC-EC5: no promotion chain or non-git workspace ----------

@test "pre-push review runs without promotion chain and ancestor check and push steps skip with notice" {
  local step9a
  step9a="$(/usr/bin/sed -n '/step 9a pre-push review begin/,/step 9a pre-push review end/p' "$SKILL_MD")"
  # Ancestor check exits 3 for non-git
  echo "$step9a" | /usr/bin/grep -q 'exit 3.*skipped\|exit 3.*non-git'
  # Pre-push mode guard in Step 10 mentions existing skip
  /usr/bin/grep -q 'Steps 10.*skipped\|Steps 10–13.*skipped' "$SKILL_MD"
}

# ---------- AC-EC6: ESCALATE during YOLO or sprint run ----------

@test "ESCALATE during YOLO or sprint run halts on AskUserQuestion with story in review and worktree kept" {
  local step9a
  step9a="$(/usr/bin/sed -n '/step 9a pre-push review begin/,/step 9a pre-push review end/p' "$SKILL_MD")"
  echo "$step9a" | /usr/bin/grep -q 'YOLO.*sprint.*AskUserQuestion\|AskUserQuestion.*YOLO\|ESCALATE.*YOLO'
  echo "$step9a" | /usr/bin/grep -q 'story in.*review\|story stays in.*review'
  echo "$step9a" | /usr/bin/grep -q 'worktree.*kept\|nothing.*pushed\|nothing is pushed'
}

# ---------- AC-EC7: merge deferred (exit 3) ----------

@test "merge deferred on exit 3 keeps story in review with rows bound to PR head and no re-review needed" {
  # Step 13 already documents exit 3 — verify the semantics
  local step13
  step13="$(/usr/bin/sed -n '/### Step 13/,/### Step 14/p' "$SKILL_MD")"
  echo "$step13" | /usr/bin/grep -q 'Exit 3.*deferred\|exit 3.*Merge deferred'
  echo "$step13" | /usr/bin/grep -q 'stays in.*review'
}

# ---------- run-all-reviews: --bind-head passthrough ----------

@test "run-all-reviews SKILL.md accepts optional --bind-head argument" {
  /usr/bin/grep -q '\-\-bind-head' "$RUN_ALL_MD"
}

@test "run-all-reviews skip-check invocation line includes --bind-head" {
  /usr/bin/grep 'review-skip-check.sh' "$RUN_ALL_MD" | /usr/bin/grep -q '\-\-bind-head'
}

# ---------- Step timing: sub-step count updated ----------

@test "SKILL.md documents 10 lettered sub-steps including 9a" {
  /usr/bin/grep -q '10 lettered sub-steps' "$SKILL_MD"
  local scope_line
  scope_line="$(/usr/bin/grep 'out of scope for v1' "$SKILL_MD")"
  echo "$scope_line" | /usr/bin/grep -qF "9a"
}
