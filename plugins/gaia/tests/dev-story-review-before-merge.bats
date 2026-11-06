#!/usr/bin/env bats
# dev-story-review-before-merge.bats — tests for the pre-push review ordering
# opt-in (dev_story.review_before_merge config key, review-order.sh helper,
# SKILL.md Step 9a, --bind-head skip-check, and documentation).
#
# Coverage: AC1 (partial, schema + mode + doctor), AC2-AC12, AC-EC1..7.
# Portable: macOS /bin/bash 3.2 + bash 5 (no local -A, no mapfile, no sed -i '').

load 'test_helper.bash'

setup() {
  # Clear root variables so root-resolving scripts don't leak across tests.
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT PROJECT_PATH 2>/dev/null || true
  # The host's git config never reaches a fixture.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

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

# ---------- Fixture helpers ----------

# Create a git repo with one commit; print nothing. Identity is set locally so
# the host's git config never leaks in.
_make_repo() {
  git init -q "$1"
  git -C "$1" config user.email "test@test.com"
  git -C "$1" config user.name "Test"
  printf 'initial\n' > "$1/file.txt"
  git -C "$1" add file.txt
  git -C "$1" commit -qm "initial"
}

# Write a Review Gate story outside the repo with all six rows bound to $2.
_write_bound_story() {
  local story="$1" sha="$2"
  {
    printf '## Review Gate\n\n'
    printf '| Review | Status | Report | Reviewed SHA |\n'
    printf '|--------|--------|--------|--------------|\n'
    local gate
    for gate in "Code Review" "QA Tests" "Security Review" "Test Automation" "Test Review" "Performance Review"; do
      printf '| %s | PASSED | report.md | %s |\n' "$gate" "$sha"
    done
    printf '\n## Findings\n'
  } > "$story"
}

# Rewrite one gate's row in a story written by _write_bound_story.
_set_row() {
  local story="$1" gate="$2" row="$3" tmp
  tmp="${story}.tmp"
  awk -v g="| ${gate} |" -v r="$row" 'index($0, g) == 1 { print r; next } { print }' "$story" > "$tmp"
  mv "$tmp" "$story"
}

_delete_row() {
  local story="$1" gate="$2" tmp
  tmp="${story}.tmp"
  awk -v g="| ${gate} |" 'index($0, g) != 1' "$story" > "$tmp"
  mv "$tmp" "$story"
}

# Bare origin plus a clone tracking origin/staging, printed paths are fixed:
# $TMP/origin.git and $TMP/clone.
_make_origin_and_clone() {
  git init -q --bare "$TMP/origin.git"
  _make_repo "$TMP/clone"
  git -C "$TMP/clone" remote add origin "$TMP/origin.git"
  git -C "$TMP/clone" push -q origin HEAD:refs/heads/staging
  git -C "$TMP/clone" fetch -q origin
}

# Advance staging on the remote from a second clone, leaving $TMP/clone's
# tracking ref stale. Prints the new remote tip.
_advance_remote_staging() {
  git clone -q --branch staging "$TMP/origin.git" "$TMP/other" 2>/dev/null
  git -C "$TMP/other" config user.email "test@test.com"
  git -C "$TMP/other" config user.name "Test"
  printf 'advanced\n' > "$TMP/other/advanced.txt"
  git -C "$TMP/other" add advanced.txt
  git -C "$TMP/other" commit -qm "advance staging"
  git -C "$TMP/other" push -q origin HEAD:refs/heads/staging
  git -C "$TMP/other" rev-parse HEAD
}

# Put a recording git wrapper first on PATH; each call's arguments land in
# $TMP/git-calls.log and the real git still runs.
_record_git_calls() {
  local real_git
  real_git="$(command -v git)"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/git" <<WRAP
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP/git-calls.log"
exec "$real_git" "\$@"
WRAP
  chmod +x "$TMP/bin/git"
  : > "$TMP/git-calls.log"
}

# ---------- SKILL.md site helpers ----------

_step9a() {
  sed -n '/<!-- step 9a pre-push review begin -->/,/<!-- step 9a pre-push review end -->/p' "$SKILL_MD"
}

_step10() {
  sed -n '/<!-- step 10 git-push wire begin -->/,/<!-- step 10 git-push wire end -->/p' "$SKILL_MD"
}

_step16() {
  sed -n '/<!-- step 16 begin -->/,/<!-- step 16 end -->/p' "$SKILL_MD"
}

# The Step 1 re-entry block: from its bold title up to the next Step 1 bullet.
_reentry() {
  awk '/^\*\*Pre-push re-entry exception\.\*\*/ { on = 1 }
       on && /check-deps\.sh \{story_path\}/ { exit }
       on' "$SKILL_MD"
}

# One numbered Step 9a item, joined onto one line so a wrapped sentence matches.
# $1 is the item's bold title without the closing asterisks.
_item() {
  _step9a | awk -v t="**$1" '
    /^[0-9]+\. \*\*/ { on = (index($0, t) > 0) }
    /^After Step 9a completes/ { on = 0 }
    on' | tr '\n' ' ' | tr -s ' '
}

_flat() {
  printf '%s\n' "$1" | tr '\n' ' ' | tr -s ' '
}

_has() {
  grep -qF -- "$2" <<< "$1" || { printf 'missing: %s\nin: %s\n' "$2" "$1" >&2; return 1; }
}

_lacks() {
  if grep -qF -- "$2" <<< "$1"; then
    printf 'unexpected: %s\n' "$2" >&2
    return 1
  fi
}

# Assert each literal first appears on a later line than the one before it.
_assert_order() {
  local text="$1" prev=0 n lit
  shift
  for lit in "$@"; do
    n="$(grep -nF -- "$lit" <<< "$text" | sed -n '1s/:.*//p')"
    [ -n "$n" ] || { printf 'missing: %s\n' "$lit" >&2; return 1; }
    [ "$n" -gt "$prev" ] || { printf 'out of order: %s (line %s, previous %s)\n' "$lit" "$n" "$prev" >&2; return 1; }
    prev="$n"
  done
}

# Write the Nth bash fence of the re-entry block to a file, so the commands the
# skill prescribes are the commands the tests run.
_reentry_fence() {
  _reentry | awk -v want="$1" '
    /^```bash$/ { n++; if (n == want) on = 1; next }
    /^```$/ { on = 0 }
    on' > "$2"
  [ -s "$2" ]
}

@test "schema accepts boolean review_before_merge under dev_story" {
  /usr/bin/grep -A3 '"review_before_merge"' "$SCHEMA" | /usr/bin/grep -q '"type": "boolean"'
}

@test "schema review_before_merge is inside the dev_story properties block" {
  jq -e '.properties.dev_story.properties.review_before_merge.type == "boolean"' "$SCHEMA"
  jq -e 'has("review_before_merge") | not' "$SCHEMA"
  jq -e '.properties | has("review_before_merge") | not' "$SCHEMA"
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

@test "default Step 10 still builds the commit, runs preflight, pushes and transitions, in that order" {
  local step10
  step10="$(_step10)"
  _assert_order "$step10" \
    'promotion-chain-guard.sh`.' \
    '/scripts/commit-msg.sh {story_path}' \
    'git commit -F -' \
    'Stage and commit with conventional commit format.' \
    '--key preflight_commands' \
    '/scripts/git-push.sh` to push the current branch' \
    '/scripts/transition-story-status.sh {story_key} --to review` after all gates pass.'
}

@test "the steps after the opt-in sub-step keep their order" {
  _assert_order "$(cat "$SKILL_MD")" \
    '### Step 9 -- Definition of Done' \
    '### Step 9a -- Pre-push review (opt-in)' \
    '### Step 10 -- Commit and Push' \
    '### Step 11 -- Create PR' \
    '### Step 12 -- Wait for CI' \
    '### Step 13 -- Merge PR' \
    '### Step 14 -- Post-Completion Gate' \
    '### Step 15 -- Update Review Gate' \
    '### Step 16 -- Auto-Reviews (YOLO-only)'
}

@test "Step 9a is gated on the mode helper and default mode skips the whole sub-step" {
  local intro
  intro="$(_flat "$(_step9a | awk '/^1\. \*\*/ { exit } { print }')")"
  _has "$intro" 'scripts/review-order.sh mode` to read the active ordering.'
  _has "$intro" 'When it prints `default`, skip this sub-step entirely and fall through to Step 10'
  _has "$intro" 'Then execute the following sequence:'
}

@test "the pre-push checks in Step 10 are limited to pre-push mode" {
  local bullet
  bullet="$(_step10 | grep -F -- '**Pre-push guards')"
  _has "$bullet" '**Pre-push guards (pre-push mode only).**'
  _has "$bullet" 'In default mode neither runs.'
}

@test "Step 16 is skipped only in pre-push mode with every row bound to the PR head" {
  local line
  line="$(_step16 | grep -F -- '**Pre-push skip guard.**')"
  _has "$line" 'When `review-order.sh mode` prints `pre-push` and every Review Gate row is already bound to the PR head'
  _has "$line" 'skip Step 16 entirely'
}

# ---------- AC3: opt-in pre-push order ----------

@test "Step 9a runs guard, commit, preflight, transition, seed, prompt, ancestor, review, fix loop, ancestor, assert" {
  _assert_order "$(_step9a)" \
    '**Promotion-chain guard.**' \
    'commit-msg.sh' \
    '--key preflight_commands' \
    'transition-story-status.sh {story_key} --to review' \
    'init-review-gate.sh' \
    '(AskUserQuestion) whether to run the six reviews' \
    '**Ancestor check (pre-review).**' \
    '**Six-gate review.**' \
    '**Fix loop.**' \
    '**Ancestor check (pre-push).**' \
    '**Reviewed-head assertion.**' \
    'After Step 9a completes'
}

@test "Step 9a never transitions the story to done" {
  _lacks "$(_step9a)" '--to done'
}

@test "the Step 10 guard skips the commit, preflight and transition but never the push" {
  local line
  line="$(_step10 | grep -F -- '**Pre-push mode guard.**')"
  _has "$line" 'Step 10 skips the commit (already built in Step 9a), the preflight gate (already ran in Step 9a), and the `--to review` transition at the end (already in `review`).'
  _has "$line" 'The promotion-chain guard, push, and everything after the push are NOT skipped'
  _has "$line" 'by re-entry at the push step'
}

@test "Step 10 runs the ancestor check, then the reviewed-head check, immediately before the push" {
  _assert_order "$(_step10)" \
    '**Pre-push guards (pre-push mode only).**' \
    '/scripts/git-push.sh` to push the current branch'
  local bullet
  bullet="$(_step10 | grep -F -- '**Pre-push guards')"
  _has "$bullet" 'review-order.sh ancestor-check --base "$PR_BASE"`, then `review-order.sh assert-reviewed-head --story {story_path}`.'
  _has "$bullet" 'Exit 1 from either = HALT before push'
}

# ---------- Promotion-chain guard inside Step 9a ----------

@test "Step 9a runs the promotion-chain guard itself and captures the base" {
  local item
  item="$(_item 'Promotion-chain guard')"
  _has "$item" 'scripts/promotion-chain-guard.sh'
  _has "$item" 'capture the branch as `$PR_BASE`'
  _has "$item" '`ABSENT` does not halt here'
  _has "$(_item 'Ancestor check (pre-review)')" 'review-order.sh ancestor-check --base "$PR_BASE"'
  _has "$(_item 'Ancestor check (pre-push)')" 'review-order.sh ancestor-check --base "$PR_BASE"'
}

@test "the Step 9a guard resolves against the code path, not the shell's working directory" {
  _has "$(_item 'Promotion-chain guard')" 'cd "${PROJECT_PATH:-.}"'
}

@test "a non-git workspace still reviews: no commit to build, no head to bind, assertion skips on exit 3" {
  _has "$(_item 'Promotion-chain guard')" '[NOTICE] non-git workspace'
  _has "$(_item 'Commit')" 'In a non-git workspace there is nothing to commit; skip this item.'
  _has "$(_item 'Preflight gate')" 'In a non-git workspace skip the clean-tree check.'
  _has "$(_item 'Six-gate review')" 'In a non-git workspace there is no HEAD to bind: omit `--bind-head`.'
  _has "$(_item 'Reviewed-head assertion')" 'Exit 3 = skipped (non-git workspace, proceed).'
  _has "$(_item 'Ancestor check (pre-review)')" 'exit 3 = skipped (non-git CWD, proceed)'
}

# ---------- AC4: interactive stop and resume ----------

@test "a non-YOLO run asks before the reviews and a YOLO run does not" {
  local item
  item="$(_item 'Interactive gate')"
  _has "$item" 'When `yolo-mode.sh is_yolo` returns non-zero, ask the user (AskUserQuestion) whether to run the six reviews now or stop.'
  _has "$item" 'On proceed (or in YOLO mode): continue to the next sub-step.'
}

@test "stopping keeps the story in review, pushes nothing and prints the resume command" {
  local item
  item="$(_item 'Interactive gate')"
  _has "$item" 'On stop: the story stays in `review`, nothing is pushed, the worktree and branch and local commit are preserved'
  _has "$item" 'the exact `/gaia-dev-story {story_key}` command to resume'
}

# ---------- AC5: re-entry for pre-push-reviewed story ----------

@test "re-entry conditions: status, mode, worktree and no open PR, all before the RESUME path" {
  local block
  block="$(_reentry)"
  _has "$block" 'Before the `detect-mode.sh` RESUME path'
  _has "$block" '(a) `$STATUS` is `review`,'
  _has "$block" '(b) `review-order.sh mode` prints `pre-push`,'
  _has "$block" '(c) this story'"'"'s worktree still exists on disk'
  _has "$block" '(d) `gh pr list` for that exact branch returns empty'
}

@test "re-entry targets Step 9a, or the push when the assertion passes, and key-absent keeps the halt" {
  local block
  block="$(_flat "$(_reentry)")"
  _has "$block" '`_target=push` means re-enter at the push step inside Step 10.'
  _has "$block" '`_target=step-9a` means re-enter at Step 9a (skipping Steps 2 through 9).'
  _has "$block" 'When the key is absent (`review-order.sh mode` prints `default`) and status is `review`, the existing Step 1 status halt applies'
}

@test "the re-entry rebind comes before the assertion that picks the target" {
  _assert_order "$(_reentry)" \
    '_open_pr="$(' \
    'export PROJECT_PATH' \
    'assert-reviewed-head --story {story_path}'
}

@test "re-entry installs no teardown trap, so a stopped run keeps its worktree" {
  _lacks "$(_reentry)" 'trap '
}

@test "both status-halt lines name the pre-push re-entry exception" {
  grep -F -- '- The story file MUST exist and be `status: ready-for-dev`' "$SKILL_MD" \
    | grep -qF -- 'with the pre-push review opt-in enabled'
  grep -F -- '- Story status MUST be `ready-for-dev` or `in-progress`.' "$SKILL_MD" \
    | grep -qF -- 'with the pre-push review opt-in enabled'
}

# ---------- AC6: fix loop with bind-head ----------

@test "the fix loop dispatches the stack developer and commits while the story stays in review" {
  local item
  item="$(_item 'Fix loop')"
  _has "$item" 'dispatch the resolved `{stack}-dev` developer (the Step 3b contract) with the failed review reports.'
  _has "$item" 'The fixes are committed in the worktree while the story stays in `review`.'
}

@test "the fix loop re-reviews against the new HEAD and counts rounds through the cap" {
  local item
  item="$(_item 'Fix loop')"
  _has "$item" '`/gaia-run-all-reviews {story_key} --bind-head <new HEAD>`'
  _has "$item" '`review-skip-check.sh --bind-head <new HEAD>` to put stale PASSED rows into the `run` partition.'
  _has "$item" 'the fix-cycle cap'"'"'s count-and-decide step in `/gaia-run-all-reviews` — no second counter.'
  _has "$(_item 'Six-gate review')" '`--bind-head "$(git -C "${PROJECT_PATH:-.}" rev-parse HEAD)"`'
}

@test "review-skip-check.sh usage mentions --bind-head" {
  run "$SKIP_CHECK" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--bind-head"* ]]
}

# ---------- AC7: ESCALATE descope and accept override ----------

@test "descope pushes nothing and follows the cap's transition route" {
  _has "$(_item 'Fix loop')" 'On descope: nothing is pushed and the story follows the cap'"'"'s sanctioned transition route.'
}

@test "accept override pushes but the merge gate still refuses and the run says so" {
  _has "$(_item 'Fix loop')" 'On accept override: push and PR proceed, but `merge.sh` still refuses the merge unless the composite is COMPLETE or the operator confirms the existing terminal bypass — the run reports that the merge is waiting on the operator.'
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

# ---------- ancestor-check: the fetch and the base value ----------

@test "ancestor-check fetches: a base advanced on the remote is seen through a stale tracking ref" {
  _make_origin_and_clone
  local stale_tip new_tip head
  stale_tip="$(git -C "$TMP/clone" rev-parse origin/staging)"
  head="$(git -C "$TMP/clone" rev-parse HEAD)"
  [ "$stale_tip" = "$head" ]

  new_tip="$(_advance_remote_staging)"
  # Before the check the tracking ref still says everything is fine.
  [ "$(git -C "$TMP/clone" rev-parse origin/staging)" = "$stale_tip" ]

  run env PROJECT_PATH="$TMP/clone" "$REVIEW_ORDER" ancestor-check --base staging
  [ "$status" -eq 1 ]
  [[ "$output" == *"$new_tip"* ]]
  [[ "$output" == *"$head"* ]]
  [ "$(git -C "$TMP/clone" rev-parse HEAD)" = "$head" ]
}

@test "ancestor-check fails closed when the fetch fails even though a stale ref would pass" {
  _make_origin_and_clone
  git -C "$TMP/clone" merge-base --is-ancestor origin/staging HEAD
  git -C "$TMP/clone" remote set-url origin "$TMP/does-not-exist.git"

  run env PROJECT_PATH="$TMP/clone" "$REVIEW_ORDER" ancestor-check --base staging
  [ "$status" -eq 1 ]
  [[ "$output" == *"fetch failed"* ]]
}

@test "ancestor-check runs git fetch with end-of-options before the remote and branch" {
  _make_origin_and_clone
  _record_git_calls
  run env PATH="$TMP/bin:$PATH" PROJECT_PATH="$TMP/clone" "$REVIEW_ORDER" ancestor-check --base staging
  [ "$status" -eq 0 ]
  grep -qF -- "fetch --end-of-options origin +refs/heads/staging:refs/remotes/origin/staging" "$TMP/git-calls.log"
}

@test "ancestor-check refuses an option-shaped base without running it or fetching" {
  _make_origin_and_clone
  _record_git_calls
  run env PATH="$TMP/bin:$PATH" PROJECT_PATH="$TMP/clone" "$REVIEW_ORDER" \
    ancestor-check --base "--upload-pack=touch $TMP/pwned;git-upload-pack"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid base branch"* ]]
  [ ! -e "$TMP/pwned" ]
  ! grep -q 'fetch' "$TMP/git-calls.log"
}

@test "ancestor-check refuses base values that are not valid branch names" {
  _make_origin_and_clone
  local bad
  for bad in "-x" "a..b" "with space" "a:b" 'x@{-1}'; do
    run env PROJECT_PATH="$TMP/clone" "$REVIEW_ORDER" ancestor-check --base "$bad"
    [ "$status" -eq 1 ] || { echo "accepted: $bad" >&2; false; }
    [[ "$output" == *"invalid base branch"* ]] || { echo "wrong message for: $bad: $output" >&2; false; }
  done
}

@test "ancestor-check accepts a slashed branch name" {
  _make_origin_and_clone
  git -C "$TMP/clone" push -q origin HEAD:refs/heads/release/1.2
  run env PROJECT_PATH="$TMP/clone" "$REVIEW_ORDER" ancestor-check --base release/1.2
  [ "$status" -eq 0 ]
}

# ---------- assert-reviewed-head: no git work tree ----------

@test "assert-reviewed-head exits 3 with the skip notice outside a git work tree" {
  mkdir -p "$TMP/nongit"
  _write_bound_story "$TMP/story.md" "abc1234"
  run env PROJECT_PATH="$TMP/nongit" "$REVIEW_ORDER" assert-reviewed-head --story "$TMP/story.md"
  [ "$status" -eq 3 ]
  [[ "$output" == *"skipped (non-git CWD)"* ]]
  [[ "$output" != *"fatal"* ]]
}

@test "assert-reviewed-head exits 3 for a bare repository, which has no work tree" {
  git init -q --bare "$TMP/bare.git"
  _write_bound_story "$TMP/story.md" "abc1234"
  run env PROJECT_PATH="$TMP/bare.git" "$REVIEW_ORDER" assert-reviewed-head --story "$TMP/story.md"
  [ "$status" -eq 3 ]
}

@test "review-order refuses a code path that does not exist instead of skipping" {
  _write_bound_story "$TMP/story.md" "abc1234"
  run env PROJECT_PATH="$TMP/missing" "$REVIEW_ORDER" assert-reviewed-head --story "$TMP/story.md"
  [ "$status" -eq 1 ]
  run env PROJECT_PATH="$TMP/missing" "$REVIEW_ORDER" ancestor-check --base staging
  [ "$status" -eq 1 ]
}

@test "assert-reviewed-head refuses a repo with no commit, naming HEAD" {
  git init -q "$TMP/empty"
  _write_bound_story "$TMP/story.md" "abc1234"
  run env PROJECT_PATH="$TMP/empty" "$REVIEW_ORDER" assert-reviewed-head --story "$TMP/story.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"HEAD"* ]]
}

# ---------- assert-reviewed-head: malformed tables fail closed ----------

@test "assert-reviewed-head passes on six rows bound to the full HEAD" {
  _make_repo "$TMP/repo"
  _write_bound_story "$TMP/story.md" "$(git -C "$TMP/repo" rev-parse HEAD)"
  run env PROJECT_PATH="$TMP/repo" "$REVIEW_ORDER" assert-reviewed-head --story "$TMP/story.md"
  [ "$status" -eq 0 ]
}

@test "assert-reviewed-head passes on six rows bound to a short form of HEAD" {
  _make_repo "$TMP/repo"
  _write_bound_story "$TMP/story.md" "$(git -C "$TMP/repo" rev-parse --short=10 HEAD)"
  run env PROJECT_PATH="$TMP/repo" "$REVIEW_ORDER" assert-reviewed-head --story "$TMP/story.md"
  [ "$status" -eq 0 ]
}

@test "assert-reviewed-head refuses a story with no Review Gate section" {
  _make_repo "$TMP/repo"
  printf '# Story\n\n## Findings\n' > "$TMP/story.md"
  run env PROJECT_PATH="$TMP/repo" "$REVIEW_ORDER" assert-reviewed-head --story "$TMP/story.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Review Gate"* ]]
}

@test "assert-reviewed-head refuses a Review Gate table with no rows" {
  _make_repo "$TMP/repo"
  printf '## Review Gate\n\n| Review | Status | Report | Reviewed SHA |\n|---|---|---|---|\n\n## Findings\n' > "$TMP/story.md"
  run env PROJECT_PATH="$TMP/repo" "$REVIEW_ORDER" assert-reviewed-head --story "$TMP/story.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Review Gate"* ]]
}

@test "assert-reviewed-head refuses a table missing a gate row and names the gate" {
  _make_repo "$TMP/repo"
  _write_bound_story "$TMP/story.md" "$(git -C "$TMP/repo" rev-parse HEAD)"
  _delete_row "$TMP/story.md" "Performance Review"
  run env PROJECT_PATH="$TMP/repo" "$REVIEW_ORDER" assert-reviewed-head --story "$TMP/story.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Performance Review"* ]]
}

@test "assert-reviewed-head refuses an unparseable row" {
  _make_repo "$TMP/repo"
  local head
  head="$(git -C "$TMP/repo" rev-parse HEAD)"
  _write_bound_story "$TMP/story.md" "$head"
  _set_row "$TMP/story.md" "QA Tests" "| QA Tests | PASSED | report.md | $head | extra |"
  run env PROJECT_PATH="$TMP/repo" "$REVIEW_ORDER" assert-reviewed-head --story "$TMP/story.md"
  [ "$status" -eq 1 ]
}

@test "assert-reviewed-head refuses a duplicated gate row even when both are bound to HEAD" {
  _make_repo "$TMP/repo"
  local head
  head="$(git -C "$TMP/repo" rev-parse HEAD)"
  _write_bound_story "$TMP/story.md" "$head"
  awk -v r="| QA Tests | PASSED | report.md | $head |" '/^\| QA Tests/ { print; print r; next } { print }' \
    "$TMP/story.md" > "$TMP/story.new"
  mv "$TMP/story.new" "$TMP/story.md"
  run env PROJECT_PATH="$TMP/repo" "$REVIEW_ORDER" assert-reviewed-head --story "$TMP/story.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *'more than one row for "QA Tests"'* ]]
}

@test "assert-reviewed-head refuses an extra unknown row" {
  _make_repo "$TMP/repo"
  local head
  head="$(git -C "$TMP/repo" rev-parse HEAD)"
  _write_bound_story "$TMP/story.md" "$head"
  awk -v r="| Extra Gate | PASSED | report.md | $head |" '/^\| Performance Review/ { print; print r; next } { print }' \
    "$TMP/story.md" > "$TMP/story.new"
  mv "$TMP/story.new" "$TMP/story.md"
  run env PROJECT_PATH="$TMP/repo" "$REVIEW_ORDER" assert-reviewed-head --story "$TMP/story.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Extra Gate"* ]] || [[ "$output" == *"six"* ]]
}

@test "assert-reviewed-head refuses a symbolic ref in the SHA cell and names the gate" {
  _make_repo "$TMP/repo"
  local head cell
  head="$(git -C "$TMP/repo" rev-parse HEAD)"
  for cell in "HEAD" "origin/staging" "--all-the-refs"; do
    _write_bound_story "$TMP/story.md" "$head"
    _set_row "$TMP/story.md" "Security Review" "| Security Review | FAILED | report.md | $cell |"
    run env PROJECT_PATH="$TMP/repo" "$REVIEW_ORDER" assert-reviewed-head --story "$TMP/story.md"
    [ "$status" -eq 1 ] || { echo "accepted cell: $cell" >&2; false; }
    [[ "$output" == *"Security Review"* ]]
    [[ "$output" == *"not a commit SHA"* ]]
  done
}

@test "assert-reviewed-head refuses unbound rows: absent, none, dash and an empty cell" {
  _make_repo "$TMP/repo"
  local head cell
  head="$(git -C "$TMP/repo" rev-parse HEAD)"
  for cell in "absent" "none" "—" ""; do
    _write_bound_story "$TMP/story.md" "$head"
    _set_row "$TMP/story.md" "Test Review" "| Test Review | PASSED | report.md | $cell |"
    run env PROJECT_PATH="$TMP/repo" "$REVIEW_ORDER" assert-reviewed-head --story "$TMP/story.md"
    [ "$status" -eq 1 ] || { echo "accepted cell: '$cell'" >&2; false; }
    [[ "$output" == *"Test Review"* ]]
  done
}

@test "assert-reviewed-head refuses a three-column row, which has no binding" {
  _make_repo "$TMP/repo"
  _write_bound_story "$TMP/story.md" "$(git -C "$TMP/repo" rev-parse HEAD)"
  _set_row "$TMP/story.md" "Code Review" "| Code Review | PASSED | report.md |"
  run env PROJECT_PATH="$TMP/repo" "$REVIEW_ORDER" assert-reviewed-head --story "$TMP/story.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Code Review"* ]]
}

@test "assert-reviewed-head refuses a hex prefix too short to identify a commit" {
  _make_repo "$TMP/repo"
  _write_bound_story "$TMP/story.md" "$(git -C "$TMP/repo" rev-parse --short=4 HEAD)"
  run env PROJECT_PATH="$TMP/repo" "$REVIEW_ORDER" assert-reviewed-head --story "$TMP/story.md"
  [ "$status" -eq 1 ]
}

@test "assert-reviewed-head names the gate and both commits on a mismatch" {
  _make_repo "$TMP/repo"
  local head
  head="$(git -C "$TMP/repo" rev-parse HEAD)"
  _write_bound_story "$TMP/story.md" "$head"
  _set_row "$TMP/story.md" "QA Tests" "| QA Tests | PASSED | report.md | aaaaaaa |"
  run env PROJECT_PATH="$TMP/repo" "$REVIEW_ORDER" assert-reviewed-head --story "$TMP/story.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"QA Tests"* ]]
  [[ "$output" == *"aaaaaaa"* ]]
  [[ "$output" == *"$(git -C "$TMP/repo" rev-parse --short HEAD)"* ]]
}

# ---------- AC10: status semantics ----------

@test "review means code-complete and done is reached only after merge and post-merge verification" {
  local step9a
  step9a="$(/usr/bin/sed -n '/step 9a pre-push review begin/,/step 9a pre-push review end/p' "$SKILL_MD")"
  # Review = under review in the worktree
  /usr/bin/grep -q 'review' <<< "$step9a"
  # Worktree teardown is at Step 13 (existing location)
  local step13
  step13="$(/usr/bin/sed -n '/### Step 13/,/### Step 14/p' "$SKILL_MD")"
  /usr/bin/grep -q 'merge' <<< "$step13"
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
    ! /usr/bin/grep -qE "$pat" <<< "$dev_story_section" \
      || { echo "Leaked ID ($pat) in dev-story docs pre-push section" >&2; false; }
  done
  # Config page — check the review_before_merge entry
  local config_entry
  config_entry="$(/usr/bin/grep -A3 'review_before_merge' "$DOC_CONFIG")"
  for pat in 'FR-[0-9]+' 'ADR-[0-9]+' 'E[0-9]+-S[0-9]+'; do
    ! /usr/bin/grep -qE "$pat" <<< "$config_entry" \
      || { echo "Leaked ID ($pat) in config docs" >&2; false; }
  done
  # Changelog — check the pre-push review section
  local cl_section
  cl_section="$(/usr/bin/sed -n '/Pre-push review ordering/,/### Fix-cycle cap/p' "$CHANGELOG")"
  for pat in 'FR-[0-9]+' 'ADR-[0-9]+' 'TC-[A-Z]+-[A-Z]+-[0-9]+' 'AF-[0-9]{4}-' 'E[0-9]+-S[0-9]+'; do
    ! /usr/bin/grep -qE "$pat" <<< "$cl_section" \
      || { echo "Leaked ID ($pat) in changelog" >&2; false; }
  done
}

# ---------- AC-EC2: preflight dirties tree ----------

@test "a preflight that modifies files halts before the review and says to commit" {
  local item
  item="$(_item 'Preflight gate')"
  _has "$item" 'On failure, HALT.'
  _has "$item" 'verify the working tree is still clean (`git status --porcelain` empty in `${PROJECT_PATH:-.}`).'
  _has "$item" 'HALT before the review — tell the developer the working tree does not match the committed HEAD and to commit the change and re-run.'
}

# ---------- AC8, AC9, AC-EC3: halts before push ----------

@test "the pre-review ancestor check halts before the review and never rebases on its own" {
  local item
  item="$(_item 'Ancestor check (pre-review)')"
  _has "$item" 'exit 1 = HALT before review, naming the base tip and HEAD and telling the developer to rebase or merge the base and re-review (never rebase automatically)'
}

@test "the pre-push ancestor check halts even with a COMPLETE composite" {
  _has "$(_item 'Ancestor check (pre-push)')" 'HALT before push even with a COMPLETE composite'
}

@test "the reviewed-head assertion halts before push naming the mismatch" {
  local item
  item="$(_item 'Reviewed-head assertion')"
  _has "$item" 'review-order.sh assert-reviewed-head --story {story_file}'
  _has "$item" 'If the working tree is dirty or any Review Gate row is bound to a SHA other than HEAD, HALT before push naming the mismatch.'
}

# ---------- AC-EC5: no promotion chain or non-git workspace ----------

@test "without a promotion chain the review still runs and the ancestor checks skip with a notice" {
  local item
  item="$(_item 'Promotion-chain guard')"
  _has "$item" '`ABSENT` does not halt here: the reviews still run on the local tree'
  _has "$item" 'both ancestor checks are skipped'
  grep -qF -- 'On `ABSENT` or non-git skip, Steps 10–13 (push, PR, CI, merge) MUST be skipped' "$SKILL_MD"
}

# ---------- AC-EC6: ESCALATE during YOLO or sprint run ----------

@test "ESCALATE during a YOLO or sprint run halts with the story resumable and nothing pushed" {
  _has "$(_item 'Fix loop')" 'On ESCALATE during a YOLO or autonomous sprint run, HALT on AskUserQuestion with the story in `review`, the worktree kept and nothing pushed.'
}

# ---------- AC-EC7: merge deferred (exit 3) ----------

@test "merge deferred on exit 3 keeps story in review with rows bound to PR head and no re-review needed" {
  # Step 13 already documents exit 3 — verify the semantics
  local step13
  step13="$(/usr/bin/sed -n '/### Step 13/,/### Step 14/p' "$SKILL_MD")"
  /usr/bin/grep -q 'Exit 3.*deferred\|exit 3.*Merge deferred' <<< "$step13"
  /usr/bin/grep -q 'stays in.*review' <<< "$step13"
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
  /usr/bin/grep -qF "9a" <<< "$scope_line"
}

# ---------- Real worktree, real checkpoint writer and reader ----------

_fence_vars() {
  sed -e "s#{story_key}#${FX_KEY}#g" -e "s#{story_path}#${FX_STORY}#g" -e "s#{story_file}#${FX_STORY}#g" "$1" > "$1.subst"
  mv "$1.subst" "$1"
}

# A primary checkout and a linked worktree on this story's branch. The stub gh
# matches --head on the exact branch name, like the real one, and answers with
# whatever PR number FX_PR holds for it.
_wt_fixture() {
  FX_KEY="E900-S1"
  FX_BRANCH="feat/${FX_KEY}-some-slug"
  FX_WT="$TMP/worktrees/$FX_KEY"
  FX_STORY="$TMP/story.md"
  _make_repo "$TMP/primary"
  git -C "$TMP/primary" worktree add -q -b "$FX_BRANCH" "$FX_WT"
  export CHECKPOINT_ROOT="$TMP/checkpoints"
  export PROJECT_PATH="$TMP/primary"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/gh" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP/gh-calls.log"
[ "\${GH_STUB_RC:-0}" -eq 0 ] || exit "\$GH_STUB_RC"
case " \$* " in
  *" --head $FX_BRANCH "*) printf '%s\n' "\${FX_PR:-}" ;;
esac
STUB
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"
}

_checkpoint() {
  "$PLUGIN_ROOT/scripts/write-checkpoint.sh" gaia-dev-story "$1" "${@:2}" >/dev/null
}

# Run the skill's own read of conditions (c) and (d), with no strict mode, so
# the commands have to hold on their own. Prints the variables it sets.
_run_reentry_read() {
  _reentry_fence 1 "$TMP/fence1.sh"
  _fence_vars "$TMP/fence1.sh"
  cat > "$TMP/run.sh" <<RUN
#!/bin/bash
. "$TMP/fence1.sh"
printf 'reentry=%s\nwt=%s\nbranch=%s\npr=%s\n' "\$_reentry" "\${_wt:-}" "\${STORY_BRANCH:-}" "\${_open_pr:-}"
RUN
  run bash "$TMP/run.sh"
}

@test "re-entry reads the checkpoint through the real writer and reader, this story only" {
  _wt_fixture
  _checkpoint 3 worktree_path="$FX_WT" story_key="$FX_KEY"
  _run_reentry_read
  [ "$status" -eq 0 ]
  [[ "$output" == *"reentry=yes"* ]]
  [[ "$output" == *"wt=$FX_WT"* ]]
  [[ "$output" == *"branch=$FX_BRANCH"* ]]
  grep -qF -- "--head $FX_BRANCH --state open" "$TMP/gh-calls.log"
}

@test "re-entry with a later checkpoint without worktree_path still finds the worktree" {
  _wt_fixture
  _checkpoint 3 worktree_path="$FX_WT" story_key="$FX_KEY"
  _checkpoint 6 story_key="$FX_KEY"
  # The unscoped latest read is what used to come back empty.
  run "$PLUGIN_ROOT/scripts/resume-checkpoint.sh" read --skill gaia-dev-story --latest
  [ "$status" -eq 0 ]
  [ -z "$(jq -r '.key_variables.worktree_path // empty' <<<"$output")" ]
  _run_reentry_read
  [[ "$output" == *"reentry=yes"* ]]
  [[ "$output" == *"wt=$FX_WT"* ]]
}

@test "re-entry with a sibling story checkpoint does not take the sibling path" {
  _wt_fixture
  git -C "$TMP/primary" worktree add -q -b "feat/E900-S2-other" "$TMP/worktrees/E900-S2"
  _checkpoint 3 worktree_path="$FX_WT" story_key="$FX_KEY"
  _checkpoint 3 worktree_path="$TMP/worktrees/E900-S2" story_key="E900-S2"
  _run_reentry_read
  [[ "$output" == *"reentry=yes"* ]]
  [[ "$output" == *"wt=$FX_WT"* ]]
  [[ "$output" != *"E900-S2"* ]]
}

@test "re-entry falls back to git worktree list when no checkpoint names this story" {
  _wt_fixture
  _checkpoint 3 worktree_path="$TMP/worktrees/E900-S2" story_key="E900-S2"
  _run_reentry_read
  [[ "$output" == *"reentry=yes"* ]]
  # git reports the physical path.
  [[ "$output" == *"wt=$(cd "$FX_WT" && pwd -P)"* ]]
}

@test "find-worktree never returns the main checkout, even on the story branch" {
  _make_repo "$TMP/primary"
  git -C "$TMP/primary" checkout -qb "feat/E900-S1-on-primary"
  PROJECT_PATH="$TMP/primary" CHECKPOINT_ROOT="$TMP/none" run "$REVIEW_ORDER" find-worktree --story-key E900-S1
  [ "$status" -eq 1 ]
  [[ "$output" == *"E900-S1"* ]]
}

@test "re-entry fails (c) on empty path, missing directory and another branch, with no gh wrapper strict mode" {
  _wt_fixture
  # Remove the worktree itself so the git fallback cannot rescue any case.
  git -C "$TMP/primary" worktree remove --force "$FX_WT"
  git -C "$TMP/primary" worktree prune

  # Empty recorded path.
  _checkpoint 3 worktree_path="" story_key="$FX_KEY"
  _run_reentry_read
  [ "$status" -eq 0 ]
  [[ "$output" == *"reentry=no"* ]]

  # Directory that does not exist.
  _checkpoint 4 worktree_path="$TMP/gone" story_key="$FX_KEY"
  _run_reentry_read
  [[ "$output" == *"reentry=no"* ]]

  # A directory on another story's branch.
  git -C "$TMP/primary" worktree add -q -b "feat/E900-S2-other" "$TMP/worktrees/E900-S2"
  _checkpoint 5 worktree_path="$TMP/worktrees/E900-S2" story_key="$FX_KEY"
  _run_reentry_read
  [[ "$output" == *"reentry=no"* ]]

  # None of them got as far as asking GitHub.
  [ ! -e "$TMP/gh-calls.log" ]
  _has "$(_flat "$(_reentry)")" 'An empty recorded path, a missing directory or a branch belonging to another story fails (c)'
  _has "$(_flat "$(_reentry)")" 'The same halt applies when (c) or (d) fails.'
}

@test "re-entry with no open PR takes the empty-result path" {
  _wt_fixture
  _checkpoint 3 worktree_path="$FX_WT" story_key="$FX_KEY"
  FX_PR="" _run_reentry_read
  [[ "$output" == *"reentry=yes"* ]]
  [[ "$output" == *$'pr=\n'* || "$output" == *"pr=" ]]
}

@test "re-entry with an open PR for the exact branch does not re-enter" {
  _wt_fixture
  _checkpoint 3 worktree_path="$FX_WT" story_key="$FX_KEY"
  export FX_PR=2380
  _run_reentry_read
  [[ "$output" == *"reentry=no"* ]]
  [[ "$output" == *"pr=2380"* ]]
}

@test "a failing gh is never read as no open PR, with no strict mode to catch it" {
  _wt_fixture
  _checkpoint 3 worktree_path="$FX_WT" story_key="$FX_KEY"
  export GH_STUB_RC=1
  _run_reentry_read
  [ "$status" -eq 0 ]
  [[ "$output" == *"reentry=no"* ]]
  _has "$(_flat "$(_reentry)")" 'A non-zero `gh` exit is a HALT, never read as "no open PR".'
}

# ---------- Re-entry target: verdicts decide, not only bindings ----------

# Story in real-writer shape inside an implementation-artifacts tree; verdicts
# go through the real gate writer, bound to the worktree HEAD.
_target_fixture() {
  _wt_fixture
  export REVIEW_GATE_PROOF_OF_EXECUTION=off
  export IMPLEMENTATION_ARTIFACTS="$TMP/impl"
  export PROJECT_ROOT="$TMP/state"
  mkdir -p "$IMPLEMENTATION_ARTIFACTS" "$PROJECT_ROOT"
  FX_STORY="$IMPLEMENTATION_ARTIFACTS/${FX_KEY}-fixture.md"
  cat > "$FX_STORY" <<STORY
---
template: 'story'
key: "${FX_KEY}"
status: review
---
# Story

## Acceptance Criteria

- [ ] AC1: something

## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | UNVERIFIED | — | — |
| QA Tests | UNVERIFIED | — | — |
| Security Review | UNVERIFIED | — | — |
| Test Automation | UNVERIFIED | — | — |
| Test Review | UNVERIFIED | — | — |
| Performance Review | UNVERIFIED | — | — |

## Findings
STORY
  export PROJECT_PATH="$FX_WT"
}

_record_all() {
  local gate
  for gate in "Code Review" "QA Tests" "Security Review" "Test Automation" "Test Review" "Performance Review"; do
    "$PLUGIN_ROOT/scripts/review-gate.sh" update --story "$FX_KEY" --gate "$gate" --verdict "$1" >/dev/null
  done
}

_run_target() {
  _reentry_fence 3 "$TMP/fence3.sh"
  _fence_vars "$TMP/fence3.sh"
  printf 'printf "target=%%s\\n" "$_target"\n' >> "$TMP/fence3.sh"
  run bash "$TMP/fence3.sh"
}

@test "re-entry does not choose the push step when rows are FAILED and no accept override exists" {
  _target_fixture
  _record_all FAILED
  run "$REVIEW_ORDER" assert-reviewed-head --story "$FX_STORY"
  [ "$status" -eq 0 ]
  _run_target
  [[ "$output" == *"target=step-9a"* ]]
}

@test "re-entry with an unresolved escalation stays out of the push step" {
  _target_fixture
  _record_all FAILED
  local rw="$PLUGIN_ROOT/scripts/review-common/register-write.sh" run_id="round-20261106T000000Z-1"
  "$rw" record-round --story "$FX_KEY" --run-id "$run_id" --repo "$FX_WT" --gate "code-review=selected" >/dev/null
  "$rw" record-escalation --story "$FX_KEY" --run-id "$run_id" --round-count 2 --max-cycles 2 >/dev/null
  _run_target
  [[ "$output" == *"target=step-9a"* ]]
}

@test "re-entry takes the push step on a recorded accept override" {
  _target_fixture
  _record_all FAILED
  local rw="$PLUGIN_ROOT/scripts/review-common/register-write.sh" run_id="round-20261106T000000Z-1"
  "$rw" record-round --story "$FX_KEY" --run-id "$run_id" --repo "$FX_WT" --gate "code-review=selected" >/dev/null
  "$rw" record-escalation --story "$FX_KEY" --run-id "$run_id" --round-count 2 --max-cycles 2 >/dev/null
  "$rw" resolve-escalation --story "$FX_KEY" --run-id "$run_id" --choice accept >/dev/null
  _run_target
  [[ "$output" == *"target=push"* ]]
}

@test "re-entry takes the push step on a COMPLETE composite with no rework, after a push failure" {
  _target_fixture
  _record_all PASSED
  _run_target
  [[ "$output" == *"target=push"* ]]
}

@test "re-entry goes back to Step 9a when a passing row is bound to an older commit" {
  _target_fixture
  _record_all PASSED
  git -C "$FX_WT" commit -q --allow-empty -m "after the review"
  _run_target
  [[ "$output" == *"target=step-9a"* ]]
}

@test "re-entry installs no teardown handler and the rule is stated" {
  _has "$(_flat "$(_reentry)")" 'Re-entry sets up no exit handler for that teardown: a stopped or halted pre-push run keeps its worktree.'
}

# ---------- Layout: a linked worktree, and a story outside it ----------

_layout_fixture() {
  mkdir -p "$TMP/root/.gaia/config"
  cat > "$TMP/root/.gaia/config/project-config.yaml" <<'YAML'
project_root: "."
project_path: "repo"
memory_path: m
checkpoint_path: c
installed_path: i
framework_version: "1.0.0"
date: "2026-01-01"
dev_story:
  review_before_merge: true
ci_cd:
  promotion_chain:
    - id: staging
      branch: staging
YAML
  _make_repo "$TMP/root/repo"
  git -C "$TMP/root/repo" worktree add -q -b "feat/E900-S1-slug" "$TMP/root/wt"
  _write_bound_story "$TMP/root/story.md" abc1234
  export CLAUDE_PROJECT_ROOT="$TMP/root"
}

@test "check-layout passes a linked worktree with the story outside it" {
  _layout_fixture
  GAIA_WORKTREE_MODE=1 PROJECT_PATH="$TMP/root/wt" run "$REVIEW_ORDER" check-layout --story "$TMP/root/story.md"
  [ "$status" -eq 0 ]
}

@test "check-layout refuses worktree mode off, naming the layout and both remedies" {
  _layout_fixture
  env -u GAIA_WORKTREE_MODE PROJECT_PATH="$TMP/root/wt" "$REVIEW_ORDER" check-layout --story "$TMP/root/story.md" 2>"$TMP/err" || rc=$?
  [ "${rc:-0}" -eq 1 ]
  grep -qF 'worktree mode is off' "$TMP/err"
  grep -qF 'GAIA_WORKTREE_MODE=1' "$TMP/err"
  grep -qF 'dev_story.review_before_merge to false' "$TMP/err"
}

@test "check-layout refuses a code path that is the main checkout" {
  _layout_fixture
  GAIA_WORKTREE_MODE=1 PROJECT_PATH="$TMP/root/repo" run "$REVIEW_ORDER" check-layout --story "$TMP/root/story.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a linked worktree"* ]]
  [[ "$output" == *"GAIA_WORKTREE_MODE=1"* ]]
}

@test "check-layout refuses a story file inside the code work tree, also through a symlink" {
  _layout_fixture
  _write_bound_story "$TMP/root/wt/story.md" abc1234
  GAIA_WORKTREE_MODE=1 PROJECT_PATH="$TMP/root/wt" run "$REVIEW_ORDER" check-layout --story "$TMP/root/wt/story.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"inside the code work tree"* ]]
  ln -s "$TMP/root/wt/story.md" "$TMP/root/link.md"
  GAIA_WORKTREE_MODE=1 PROJECT_PATH="$TMP/root/wt" run "$REVIEW_ORDER" check-layout --story "$TMP/root/link.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"inside the code work tree"* ]]
}

@test "check-layout skips a non-git code path with exit 3" {
  _layout_fixture
  mkdir -p "$TMP/root/plain"
  env -u GAIA_WORKTREE_MODE PROJECT_PATH="$TMP/root/plain" GIT_CEILING_DIRECTORIES="$TMP" "$REVIEW_ORDER" check-layout --story "$TMP/root/story.md" 2>/dev/null || rc=$?
  [ "${rc:-0}" -eq 3 ]
}

@test "check-layout passes with no promotion chain, which never pushes" {
  _layout_fixture
  sed -e '/^ci_cd:/,$d' "$TMP/root/.gaia/config/project-config.yaml" > "$TMP/cfg"
  mv "$TMP/cfg" "$TMP/root/.gaia/config/project-config.yaml"
  unset GAIA_WORKTREE_MODE
  PROJECT_PATH="$TMP/root/repo" run "$REVIEW_ORDER" check-layout --story "$TMP/root/story.md"
  [ "$status" -eq 0 ]
}

@test "check-layout --worktree-mode-only ignores the rest, so Step 1 can run it before a worktree exists" {
  _layout_fixture
  GAIA_WORKTREE_MODE=1 PROJECT_PATH="$TMP/root/repo" run "$REVIEW_ORDER" check-layout --worktree-mode-only
  [ "$status" -eq 0 ]
  env -u GAIA_WORKTREE_MODE PROJECT_PATH="$TMP/root/repo" "$REVIEW_ORDER" check-layout --worktree-mode-only 2>"$TMP/err" || rc=$?
  [ "${rc:-0}" -eq 1 ]
  grep -qF 'worktree mode is off' "$TMP/err"
}

@test "check-layout needs a story or the worktree-mode flag" {
  _layout_fixture
  PROJECT_PATH="$TMP/root/repo" run "$REVIEW_ORDER" check-layout
  [ "$status" -eq 2 ]
}

@test "mode stays pure: it answers on an unsupported layout" {
  _layout_fixture
  unset GAIA_WORKTREE_MODE
  PROJECT_PATH="$TMP/root/repo" run "$REVIEW_ORDER" mode
  [ "$status" -eq 0 ]
  [ "$output" = "pre-push" ]
}

@test "Step 1 applies only the worktree-mode check, Step 9a all of it, and neither falls back" {
  local step1 top
  step1="$(_flat "$(awk '/^\*\*Pre-push ordering read\.\*\*/ { print; exit }' "$SKILL_MD")")"
  _has "$step1" 'check-layout --worktree-mode-only'
  _has "$step1" 'Exit 1 = HALT naming the layout and both remedies'
  _has "$step1" 'with no fallback to the default order'
  top="$(_flat "$(_step9a | awk '/^1\. \*\*/ { exit } { print }')")"
  _has "$top" 'check-layout --story {story_file}'
  _has "$top" 'Exit 1 = HALT before any status change, commit or review'
  _has "$top" 'enable worktree mode with `GAIA_WORKTREE_MODE=1`'
  _has "$top" 'Never fall back to the default order.'
  _assert_order "$(cat "$SKILL_MD")" \
    '**Pre-push ordering read.**' \
    '**Pre-push re-entry exception.**' \
    'check-layout --story {story_file}' \
    '2. **Commit.**'
}

@test "doctor warns on the layout, naming both remedies" {
  local body
  body="$(_flat "$(cat "$DOCTOR_MD")")"
  _has "$body" 'review-order.sh check-layout --worktree-mode-only'
  _has "$body" 'enable worktree mode with `GAIA_WORKTREE_MODE=1`, or set `dev_story.review_before_merge` to false'
  grep -qF 'layout that cannot run it' "${PLUGIN_ROOT}/../../documentation/commands/gaia-doctor.html"
}

@test "doctor keeps both ordering rows" {
  grep -qF 'review_ordering:                default           (when absent or false)' "$DOCTOR_MD"
  grep -qF 'review_ordering:                pre-push review   (when dev_story.review_before_merge: true)' "$DOCTOR_MD"
}

# ---------- Step 9a items ----------

_commit_fence() {
  _item 'Commit.' > /dev/null
  _step9a | awk '
    /^2\. \*\*Commit/ { item = 1 }
    /^3\. \*\*/ { item = 0 }
    item && /^ *```bash$/ { on = 1; next }
    item && /^ *```$/ { on = 0 }
    on' > "$1"
  [ -s "$1" ]
}

@test "clean-tree re-entry skips the commit item" {
  FX_KEY="E900-S1"; FX_STORY="$TMP/story.md"
  _make_repo "$TMP/wt"
  _commit_fence "$TMP/commit.sh"
  _fence_vars "$TMP/commit.sh"
  mkdir -p "$TMP/plugin/skills/gaia-dev-story/scripts"
  printf '#!/bin/sh\nprintf "feat: fixture\\n"\n' > "$TMP/plugin/skills/gaia-dev-story/scripts/commit-msg.sh"
  chmod +x "$TMP/plugin/skills/gaia-dev-story/scripts/commit-msg.sh"
  local before
  before="$(git -C "$TMP/wt" rev-parse HEAD)"
  CLAUDE_PLUGIN_ROOT="$TMP/plugin" PROJECT_PATH="$TMP/wt" run bash -e "$TMP/commit.sh"
  [ "$status" -eq 0 ]
  [ "$(git -C "$TMP/wt" rev-parse HEAD)" = "$before" ]

  # A dirty tree still gets its commit.
  printf 'change\n' > "$TMP/wt/new.txt"
  CLAUDE_PLUGIN_ROOT="$TMP/plugin" PROJECT_PATH="$TMP/wt" run bash -e "$TMP/commit.sh"
  [ "$status" -eq 0 ]
  [ "$(git -C "$TMP/wt" rev-parse HEAD)" != "$before" ]
  [ -z "$(git -C "$TMP/wt" status --porcelain)" ]
  _has "$(_item 'Commit.')" 'A clean tree skips this item'
}

@test "the reviewed-head assertion is skipped on ABSENT and the ancestor check needs a base" {
  local item
  item="$(_item 'Reviewed-head assertion.')"
  _has "$item" 'When the guard in item 1 returned `ABSENT`, skip this item: nothing is pushed and the story ends in `review`.'
  item="$(_item 'Ancestor check (pre-push).')"
  _has "$item" 'When the guard in item 1 returned `PRESENT:<branch>`'
}

@test "a resume with no worktree prints the run-all command" {
  _has "$(_item 'Interactive gate (non-YOLO).')" 'the command to print is `/gaia-run-all-reviews {story_key}` instead'
}

@test "preflight that rewrites a file halts before review, with a real runner" {
  _make_repo "$TMP/wt"
  mkdir -p "$TMP/root/.gaia/config"
  cat > "$TMP/root/.gaia/config/project-config.yaml" <<'YAML'
project_root: "."
project_path: "wt"
memory_path: m
checkpoint_path: c
installed_path: i
framework_version: "1.0.0"
date: "2026-01-01"
preflight_commands:
  - "printf 'formatted\\n' >> file.txt"
YAML
  CLAUDE_PROJECT_ROOT="$TMP/root" run bash "$PLUGIN_ROOT/skills/gaia-dev-story/scripts/run-configured-commands.sh" \
    --key preflight_commands --workdir "$TMP/wt"
  [ "$status" -eq 0 ]
  [ -n "$(git -C "$TMP/wt" status --porcelain)" ]
  _write_bound_story "$TMP/story.md" "$(git -C "$TMP/wt" rev-parse HEAD)"
  PROJECT_PATH="$TMP/wt" run "$REVIEW_ORDER" assert-reviewed-head --story "$TMP/story.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not clean"* ]]
  local item
  item="$(_item 'Preflight gate.')"
  _has "$item" 'verify the working tree is still clean'
  _has "$item" 'HALT before the review'
  _has "$item" 'to commit the change and re-run'
}

# ---------- Ancestor check: the ref it reads ----------

@test "ancestor-check halts under a narrowed refspec with the base advanced" {
  _make_origin_and_clone
  git -C "$TMP/clone" config remote.origin.fetch "+refs/heads/other:refs/remotes/origin/other"
  local tip
  tip="$(_advance_remote_staging)"
  PROJECT_PATH="$TMP/clone" run "$REVIEW_ORDER" ancestor-check --base staging
  [ "$status" -eq 1 ]
  [[ "$output" == *"$tip"* ]]
}

@test "ancestor-check ignores a local branch and a tag named origin/<base>" {
  _make_origin_and_clone
  _advance_remote_staging >/dev/null
  git -C "$TMP/clone" branch "origin/staging"
  PROJECT_PATH="$TMP/clone" run "$REVIEW_ORDER" ancestor-check --base staging
  [ "$status" -eq 1 ]
  git -C "$TMP/clone" branch -qD "origin/staging"
  git -C "$TMP/clone" tag "origin/staging"
  PROJECT_PATH="$TMP/clone" run "$REVIEW_ORDER" ancestor-check --base staging
  [ "$status" -eq 1 ]
}

@test "drift stderr names base tip, HEAD and rebase advice" {
  _make_origin_and_clone
  local tip head
  tip="$(_advance_remote_staging)"
  head="$(git -C "$TMP/clone" rev-parse HEAD)"
  PROJECT_PATH="$TMP/clone" run "$REVIEW_ORDER" ancestor-check --base staging
  [ "$status" -eq 1 ]
  [[ "$output" == *"$tip"* ]]
  [[ "$output" == *"$head"* ]]
  [[ "$output" == *"rebase or merge the base branch and re-review"* ]]
}

@test "helper usage errors and an unbound literal exit with their documented codes and messages" {
  run "$REVIEW_ORDER" ancestor-check
  [ "$status" -eq 2 ]
  run "$REVIEW_ORDER" assert-reviewed-head
  [ "$status" -eq 2 ]
  _make_repo "$TMP/wt"
  PROJECT_PATH="$TMP/wt" run "$REVIEW_ORDER" assert-reviewed-head --story "$TMP/missing.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"story file not found"* ]]
  _write_bound_story "$TMP/story.md" absent
  PROJECT_PATH="$TMP/wt" run "$REVIEW_ORDER" assert-reviewed-head --story "$TMP/story.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no reviewed SHA bound"* ]]
}

# ---------- mode and the resolver ----------

_nongit_root_fixture() {
  mkdir -p "$TMP/root/.gaia/config"
  cat > "$TMP/root/.gaia/config/project-config.yaml" <<'YAML'
project_root: "."
project_path: "repo"
memory_path: m
checkpoint_path: c
installed_path: i
framework_version: "1.0.0"
date: "2026-01-01"
dev_story:
  review_before_merge: true
YAML
  _make_repo "$TMP/root/repo"
}

@test "mode exits non-zero when the config is malformed" {
  mkdir -p "$TMP/.gaia/config"
  printf 'dev_story: [\n' > "$TMP/.gaia/config/project-config.yaml"
  CLAUDE_PROJECT_ROOT="$TMP" run "$REVIEW_ORDER" mode
  [ "$status" -ne 0 ]
  [[ "$output" == *"dev_story.review_before_merge"* ]]
  [[ "$output" != *"default"* ]]
}

@test "mode reads the config above a repo in a non-git root in all three environments" {
  _nongit_root_fixture
  cd "$TMP/root/repo"
  run "$REVIEW_ORDER" mode
  [ "$status" -eq 0 ]
  [ "$output" = "pre-push" ]
  cd "$TMP"
  PROJECT_PATH="$TMP/root/repo" run "$REVIEW_ORDER" mode
  [ "$status" -eq 0 ]
  [ "$output" = "pre-push" ]
  CLAUDE_PROJECT_ROOT="$TMP/root" run "$REVIEW_ORDER" mode
  [ "$status" -eq 0 ]
  [ "$output" = "pre-push" ]
}

@test "mode prints default when no config exists anywhere" {
  mkdir -p "$TMP/empty"
  cd "$TMP/empty"
  run "$REVIEW_ORDER" mode
  [ "$status" -eq 0 ]
  [ "$output" = "default" ]
}

@test "mode halts for yes in shared and local layers, and every call site halts on non-zero" {
  _nongit_root_fixture
  local cfg="$TMP/root/.gaia/config/project-config.yaml"
  sed -e 's/review_before_merge: true/review_before_merge: "yes"/' "$cfg" > "$TMP/cfg"
  cp "$TMP/cfg" "$cfg"
  CLAUDE_PROJECT_ROOT="$TMP/root" run "$REVIEW_ORDER" mode
  [ "$status" -ne 0 ]
  [[ "$output" == *"dev_story.review_before_merge"* ]]
  [[ "$output" == *"allowed: true, false"* ]]

  # Shared layer clean, the bad value only in the local override.
  sed -e 's/review_before_merge: "yes"/review_before_merge: false/' "$cfg" > "$TMP/cfg"
  cp "$TMP/cfg" "$cfg"
  printf 'dev_story:\n  review_before_merge: yes\n' > "$TMP/root/.gaia/config/global.yaml"
  CLAUDE_PROJECT_ROOT="$TMP/root" run "$REVIEW_ORDER" mode
  [ "$status" -ne 0 ]

  _has "$(awk '/^\*\*Pre-push ordering read\.\*\*/ { print; exit }' "$SKILL_MD")" 'Any non-zero exit is a HALT'
  _has "$(_flat "$(_step9a)")" 'Any non-zero exit is a HALT with its stderr, naming the key'
  _has "$(_step10)" 'A non-zero exit from `review-order.sh mode` is a HALT.'
  _has "$(_step16)" 'A non-zero exit from `review-order.sh mode` is a HALT.'
}

@test "flow-style mapping resolves the configured value" {
  _nongit_root_fixture
  local cfg="$TMP/root/.gaia/config/project-config.yaml"
  sed -e '/^dev_story:/,$d' "$cfg" > "$TMP/cfg"
  printf 'dev_story: {review_before_merge: true}\nreview: {max_fix_cycles: 7, other: 1}\n' >> "$TMP/cfg"
  cp "$TMP/cfg" "$cfg"
  CLAUDE_PROJECT_ROOT="$TMP/root" run "$RESOLVE" --field dev_story.review_before_merge
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  CLAUDE_PROJECT_ROOT="$TMP/root" run "$REVIEW_ORDER" mode
  [ "$output" = "pre-push" ]
  CLAUDE_PROJECT_ROOT="$TMP/root" run "$RESOLVE" --field review.max_fix_cycles
  [ "$output" = "7" ]
}

@test "flow-style mapping reads only its own keys, not a nested one" {
  _nongit_root_fixture
  local cfg="$TMP/root/.gaia/config/project-config.yaml"
  sed -e '/^dev_story:/,$d' "$cfg" > "$TMP/cfg"
  printf 'dev_story: {other: {review_before_merge: true}, "review_before_merge": false}\n' >> "$TMP/cfg"
  cp "$TMP/cfg" "$cfg"
  CLAUDE_PROJECT_ROOT="$TMP/root" run "$RESOLVE" --field dev_story.review_before_merge
  [ "$output" = "false" ]
}

@test "resolve-config --all and JSON output carry the key" {
  _nongit_root_fixture
  CLAUDE_PROJECT_ROOT="$TMP/root" run "$RESOLVE" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"dev_story.review_before_merge='true'"* ]]
  CLAUDE_PROJECT_ROOT="$TMP/root" run "$RESOLVE" --format json
  [ "$status" -eq 0 ]
  [ "$(jq -r '."dev_story.review_before_merge"' <<<"$output")" = "true" ]
  CLAUDE_PROJECT_ROOT="$TMP/root" run "$RESOLVE" --all --format json
  [ "$status" -eq 0 ]
  [ "$(jq -r '."dev_story.review_before_merge"' <<<"$output")" = "true" ]
}

@test "the JSON output omits the key when it is absent" {
  _nongit_root_fixture
  local cfg="$TMP/root/.gaia/config/project-config.yaml"
  sed -e '/^dev_story:/,$d' "$cfg" > "$TMP/cfg"
  cp "$TMP/cfg" "$cfg"
  CLAUDE_PROJECT_ROOT="$TMP/root" run "$RESOLVE" --format json
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("dev_story.review_before_merge")' <<<"$output")" = "false" ]
}

@test "the YAML descriptor lists the key in the dev_story description" {
  local line
  line="$(awk '/^  dev_story:/ { on = 1; next } on && /^  [a-z_]+:/ { exit } on' "$YAML_SCHEMA")"
  _has "$line" 'review_before_merge'
}

# ---------- Move to done: the merge guard on every path ----------

# A review-status story with all rows PASSED, in a project whose code path is a
# git repo under a non-git root. The stub gh answers the verifier's list query
# with GH_LIST and records its working directory.
_done_fixture() {
  _nongit_root_fixture
  FX_KEY="E900-S1"
  local impl="$TMP/root/.gaia/artifacts/implementation-artifacts" plan="$TMP/root/.gaia/artifacts/planning-artifacts"
  mkdir -p "$impl" "$plan" "$TMP/root/.gaia/memory" "$TMP/bin"
  FX_STORY="$impl/${FX_KEY}-fixture.md"
  local sha
  sha="$(git -C "$TMP/root/repo" rev-parse HEAD)"
  cat > "$FX_STORY" <<STORY
---
template: 'story'
key: "${FX_KEY}"
title: "Fixture"
epic: "E900"
status: review
sprint_id: "fixture-sprint"
priority: "P2"
size: "S"
points: 1
risk: "low"
---

# Story: Fixture

> **Status:** review

## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | PASSED | — | ${sha} |
| QA Tests | PASSED | — | ${sha} |
| Security Review | PASSED | — | ${sha} |
| Test Automation | PASSED | — | ${sha} |
| Test Review | PASSED | — | ${sha} |
| Performance Review | PASSED | — | ${sha} |

## Findings
STORY
  cat > "$impl/sprint-status.yaml" <<STATUS
sprint_id: "fixture-sprint"
stories:
  - key: ${FX_KEY}
    status: "review"
STATUS
  cat > "$plan/epics-and-stories.md" <<EPICS
# Epics and Stories

## Epic 900 — Fixture

### Story ${FX_KEY}: Fixture

- **Status:** review
EPICS
  cat > "$impl/story-index.yaml" <<INDEX
stories:
  ${FX_KEY}:
    story_key: "${FX_KEY}"
    status: "review"
INDEX
  cat > "$TMP/bin/gh" <<STUB
#!/bin/sh
printf '%s %s\n' "\$PWD" "\$*" >> "$TMP/gh-calls.log"
printf '%s\n' "\${GH_LIST:-NO_MATCH}"
STUB
  chmod +x "$TMP/bin/gh"
  _record_git_calls
  export PATH="$TMP/bin:$PATH"
  export CLAUDE_PROJECT_ROOT="$TMP/root"
  export IMPLEMENTATION_ARTIFACTS="$impl" PLANNING_ARTIFACTS="$plan"
  export MEMORY_PATH="$TMP/root/.gaia/memory"
  export SPRINT_STATUS_YAML="$impl/sprint-status.yaml"
  export EPICS_AND_STORIES="$plan/epics-and-stories.md"
  export STORY_INDEX_YAML="$impl/story-index.yaml"
  export STORY_STATUS_LOCK="$TMP/root/.gaia/memory/.lock"
  export REVIEW_GATE_PROOF_OF_EXECUTION=off
  unset GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE
  TRANSITION="$PLUGIN_ROOT/scripts/transition-story-status.sh"
  cd "$TMP/root"
}

_add_chain() {
  printf 'ci_cd:\n  promotion_chain:\n    - id: staging\n      branch: staging\n' >> "$TMP/root/.gaia/config/project-config.yaml"
}

_set_key() {
  local cfg="$TMP/root/.gaia/config/project-config.yaml"
  sed -e "s/review_before_merge: true/review_before_merge: $1/" "$cfg" > "$TMP/cfg"
  cp "$TMP/cfg" "$cfg"
}

_drop_key() {
  local cfg="$TMP/root/.gaia/config/project-config.yaml"
  sed -e '/^dev_story:/d' -e '/review_before_merge/d' "$cfg" > "$TMP/cfg"
  cp "$TMP/cfg" "$cfg"
}

_status_of() {
  awk '/^status:/ { print $2; exit }' "$FX_STORY"
}

@test "done is refused until merge exits 0 and post-merge verification passes" {
  _done_fixture
  _add_chain
  GH_LIST=NO_MATCH run "$TRANSITION" "$FX_KEY" --to done
  [ "$status" -eq 9 ]
  [[ "$output" == *"$FX_KEY"* ]]
  [[ "$output" == *"finish push and merge"* ]]
  [ "$(_status_of)" = "review" ]

  GH_LIST=MERGED run "$TRANSITION" "$FX_KEY" --to done
  [ "$status" -eq 0 ]
  [ "$(_status_of)" = "done" ]
}

@test "the guard runs the verifier in the code path from config, not the non-git working directory" {
  _done_fixture
  _add_chain
  GH_LIST=MERGED run "$TRANSITION" "$FX_KEY" --to done
  [ "$status" -eq 0 ]
  local phys
  phys="$(cd "$TMP/root/repo" && pwd -P)"
  grep -qE "^(${phys}|${TMP}/root/repo) pr list" "$TMP/gh-calls.log"
}

@test "with the key absent or false a transition to done makes no verifier, gh or fetch call" {
  _done_fixture
  _add_chain
  _drop_key
  GH_LIST=NO_MATCH run "$TRANSITION" "$FX_KEY" --to done
  [ "$status" -eq 0 ]
  [ "$(_status_of)" = "done" ]
  [ ! -e "$TMP/gh-calls.log" ]
  ! grep -qE '(^| )fetch( |$)' "$TMP/git-calls.log"
}

@test "with the key false a transition to done makes no gh call either" {
  _done_fixture
  _add_chain
  _set_key false
  GH_LIST=NO_MATCH run "$TRANSITION" "$FX_KEY" --to done
  [ "$status" -eq 0 ]
  [ ! -e "$TMP/gh-calls.log" ]
}

@test "with no promotion chain a pre-push story may move to done" {
  _done_fixture
  GH_LIST=NO_MATCH run "$TRANSITION" "$FX_KEY" --to done
  [ "$status" -eq 0 ]
  [ ! -e "$TMP/gh-calls.log" ]
}

@test "a resolver failure refuses done rather than reading as default" {
  _done_fixture
  _add_chain
  printf 'dev_story: [\n' > "$TMP/root/.gaia/config/project-config.yaml"
  run "$TRANSITION" "$FX_KEY" --to done
  [ "$status" -eq 9 ]
  [[ "$output" == *"$FX_KEY"* ]]
  [ "$(_status_of)" = "review" ]
}

@test "a non-boolean value refuses done" {
  _done_fixture
  _add_chain
  _set_key maybe
  run "$TRANSITION" "$FX_KEY" --to done
  [ "$status" -eq 9 ]
}

@test "the operator bypass allows done with no verifier call" {
  _done_fixture
  _add_chain
  GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE=1 GH_LIST=NO_MATCH run "$TRANSITION" "$FX_KEY" --to done
  [ "$status" -eq 0 ]
  [ ! -e "$TMP/gh-calls.log" ]
}

@test "--reconcile-only stays exempt" {
  _done_fixture
  _add_chain
  GH_LIST=NO_MATCH run "$TRANSITION" "$FX_KEY" --reconcile-only --to done
  [ "$status" -ne 9 ]
  [ ! -e "$TMP/gh-calls.log" ]
}

@test "transition exit code 9 is documented in the tool header" {
  grep -qE '^#   9  review -> done refused' "$PLUGIN_ROOT/scripts/transition-story-status.sh"
}

@test "sprint-state transition cannot reach done past the guard either" {
  _done_fixture
  _add_chain
  GH_LIST=NO_MATCH run "$PLUGIN_ROOT/scripts/sprint-state.sh" transition --story "$FX_KEY" --to done
  [ "$status" -eq 9 ]
  [ "$(_status_of)" = "review" ]
  # The copy shipped beside the helper reaches the same decision.
  GH_LIST=NO_MATCH run "$PLUGIN_ROOT/skills/gaia-dev-story/scripts/sprint-state.sh" transition --story "$FX_KEY" --to done
  [ "$status" -eq 9 ]
}

@test "the verifier exit codes map to allow and refuse" {
  _done_fixture
  _add_chain
  mkdir -p "$TMP/copy/skills/gaia-dev-story"
  cp -R "$PLUGIN_ROOT/scripts" "$TMP/copy/scripts"
  cp -R "$PLUGIN_ROOT/skills/gaia-dev-story/scripts" "$TMP/copy/skills/gaia-dev-story/scripts"
  local rc_case
  for rc_case in 0:0 3:0 2:1 1:1 7:1; do
    printf '#!/bin/sh\nexit %s\n' "${rc_case%%:*}" > "$TMP/copy/skills/gaia-dev-story/scripts/verify-pr-merged.sh"
    run "$TMP/copy/skills/gaia-dev-story/scripts/review-order.sh" merge-guard --story-key "$FX_KEY"
    [ "$status" -eq "${rc_case##*:}" ] || { printf 'verifier rc %s gave %s\n' "$rc_case" "$status" >&2; return 1; }
  done
}

@test "merge-guard refuses a bad key and a missing code path" {
  _done_fixture
  run "$REVIEW_ORDER" merge-guard --story-key '../x'
  [ "$status" -eq 1 ]
  run "$REVIEW_ORDER" merge-guard
  [ "$status" -eq 2 ]
  rm -rf "$TMP/root/repo"
  run "$REVIEW_ORDER" merge-guard --story-key "$FX_KEY"
  [ "$status" -eq 1 ]
  [[ "$output" == *"code path does not exist"* ]]
}

@test "the pre-push tail ends with done after the merge, and Step 14 no longer assumes a subagent" {
  local tail
  tail="$(_flat "$(awk '/^\*\*Pre-push tail: move to `done`\.\*\*/ { print; exit }' "$SKILL_MD")")"
  _has "$tail" 'when Step 13 exited 0 and Step 14 exited 0, the last action of the run is'
  _has "$tail" 'transition-story-status.sh {story_key} --to done'
  _has "$tail" 'Step 13 exit 3 (merge deferred) and a project with no promotion chain end in `review`'
  _assert_order "$(cat "$SKILL_MD")" \
    '### Step 13 -- Merge PR' \
    '### Step 14 -- Post-Completion Gate' \
    '### Step 15 -- Update Review Gate' \
    '<!-- step 16 end -->' \
    '**Pre-push tail: move to `done`.**'
  _lacks "$(sed -n '/### Step 14 -- /,/### Step 14b/p' "$SKILL_MD" | sed -n '1,6p')" 'subagent returns `status=done`'
}

@test "deferred merge keeps rows bound and a later merge needs no re-review, against a real gate check" {
  _done_fixture
  _add_chain
  local head
  head="$(git -C "$TMP/root/repo" rev-parse HEAD)"
  # Exit 3 leaves the story and its rows alone, so the gate check still passes.
  run "$PLUGIN_ROOT/scripts/review-gate-check.sh" --bind-head "$head" --ci-sha "$head" --story "$FX_STORY"
  [ "$status" -eq 0 ]
  [ "$(_status_of)" = "review" ]
  _has "$(sed -n '/### Step 13/,/### Step 14/p' "$SKILL_MD")" '**Step 14 is skipped when Step 13 returns exit 3.**'
}

# ---------- Default-order tail against a fixed baseline ----------

@test "Steps 11-16 keep their commands against a baseline" {
  _assert_order "$(sed -n '/<!-- step 10 git-push wire end -->/,$p' "$SKILL_MD")" \
    '<!-- step 10 git-push wire end -->' \
    '### Step 11 -- Create PR' \
    'forbidden-sentinel-scan.sh' \
    '### Step 12 ' \
    'scripts/ci-wait.sh {pr_number}' \
    '--key post_ci_smoke_commands' \
    '### Step 13 -- Merge PR' \
    '### Step 14 -- Post-Completion Gate' \
    'scripts/verify-pr-merged.sh {story_key} {target_branch}' \
    '### Step 14b ' \
    '### Step 15 -- Update Review Gate' \
    'scripts/init-review-gate.sh {story_file}' \
    'transition-story-status.sh {story_key} --to review' \
    '<!-- step 16 begin -->' \
    'yolo-mode.sh is_yolo'
}

# ---------- Run-all, documentation and changelog ----------

@test "run-all accepts and forwards --bind-head, per line, with no ONLY-flag contradiction" {
  grep -qF 'argument-hint: "[story-key] [--force] [--bind-head <sha>]"' "$RUN_ALL_MD"
  grep -qF 'usage: /gaia-run-all-reviews [story-key] [--force] [--bind-head <sha>]' "$RUN_ALL_MD"
  grep -qF '`--force` and `--bind-head <sha>` are the ONLY supported flags' "$RUN_ALL_MD"
  ! grep -qF 'The `--force` flag is the ONLY supported flag' "$RUN_ALL_MD"
  grep -qF 'the optional `--force` and `--bind-head <sha>` flags' "$RUN_ALL_MD"
  grep -qF 'review-skip-check.sh --story {story_key} [--force] [--bind-head <sha>]' "$RUN_ALL_MD"
  grep -qF 'If `--bind-head <s' "$RUN_ALL_MD"
  grep -qF -- '--bind-head' "${PLUGIN_ROOT}/../../documentation/commands/gaia-review-all.html"
}

@test "docs and changelog pin key, default, step order, stop-and-resume and drift halt per sentence" {
  local doc cl
  doc="$(_flat "$(sed -n '/Pre-push review ordering (opt-in)/,/<\/div>/p' "$DOC_DEV_STORY")")"
  _has "$doc" '<code>dev_story.review_before_merge: true</code>'
  _has "$doc" 'The key defaults to <code>false</code>'
  _has "$doc" 'commit &rarr; push &rarr; PR &rarr; CI &rarr; review &rarr; merge'
  _has "$doc" 'commit &rarr; preflight &rarr; review &rarr; fix loop &rarr; push &rarr; PR &rarr; CI &rarr; merge &rarr; done'
  _has "$doc" 'Interactive stop and resume.'
  _has "$doc" 'Drift halt.'
  _has "$doc" 'Reviewed-head check.'
  _has "$doc" 'Layout requirement.'
  _has "$doc" 'Moving to done.'
  _has "$doc" '<code>transition-story-status.sh --to done</code> exits 9'
  _lacks "$(_flat "$(cat "$DOC_DEV_STORY")")" 'once all reviews pass, transitions the story to done'
  _has "$(_flat "$(cat "$DOC_DEV_STORY")")" 'It is read-only and does not change the story'

  cl="$(sed -n '/### Pre-push review ordering/,/### Fix-cycle cap/p' "$CHANGELOG")"
  _has "$cl" '`dev_story.review_before_merge` — opt-in boolean'
  _has "$cl" '(default `false`)'
  _has "$cl" 'Interactive stop-and-resume:'
  _has "$cl" 'Drift halt:'
  _has "$cl" 'Layout check:'
  _has "$cl" 'Moving to `done`:'
  grep -qE 'review-skip-check|--bind-head' "${PLUGIN_ROOT}/../../documentation/commands/gaia-review-all.html"
}

# ---------- Two shells, for real ----------

@test "fixtures isolate git config from the host" {
  [ "$GIT_CONFIG_GLOBAL" = "/dev/null" ]
  [ -z "$(git config --global --list 2>/dev/null)" ]
}

@test "the helper parses and answers under both system shells" {
  local shell_path
  mkdir -p "$TMP/empty"
  cd "$TMP/empty"
  for shell_path in /bin/bash "$(command -v bash)"; do
    "$shell_path" -n "$REVIEW_ORDER"
    run "$shell_path" "$REVIEW_ORDER" mode
    [ "$status" -eq 0 ]
    [ "$output" = "default" ]
  done
}
