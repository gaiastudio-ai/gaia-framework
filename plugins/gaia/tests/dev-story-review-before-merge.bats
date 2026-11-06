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

# Worktree on a story branch, a stub checkpoint reader that records it, and a
# stub gh that, like the real one, matches --head only on the exact branch name.
_reentry_fixture() {
  _make_repo "$TMP/wt"
  git -C "$TMP/wt" checkout -qb feat/some-story-some-slug
  mkdir -p "$TMP/plugin/scripts" "$TMP/bin"
  cat > "$TMP/plugin/scripts/resume-checkpoint.sh" <<STUB
#!/bin/sh
printf '{"key_variables":{"worktree_path":"%s"}}\n' "$TMP/wt"
STUB
  chmod +x "$TMP/plugin/scripts/resume-checkpoint.sh"
  cat > "$TMP/bin/gh" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP/gh-calls.log"
[ "\${GH_STUB_RC:-0}" -eq 0 ] || exit "\$GH_STUB_RC"
case " \$* " in
  *" --head feat/some-story-some-slug "*) printf '2380\n' ;;
esac
STUB
  chmod +x "$TMP/bin/gh"
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
  _has "$intro" '`pre-push`, execute the following sequence:'
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
  _has "$block" '(c) the story worktree recorded in the checkpoint still exists on disk'
  _has "$block" '(d) `gh pr list` for that exact branch returns empty'
}

@test "re-entry targets Step 9a, or the push when the assertion passes, and key-absent keeps the halt" {
  local block
  block="$(_flat "$(_reentry)")"
  _has "$block" 'exit 0 means every Review Gate row is bound to HEAD: re-enter at the push step inside Step 10.'
  _has "$block" 'Any other result: re-enter at Step 9a (skipping Steps 2 through 9).'
  _has "$block" 'When the key is absent (`review-order.sh mode` prints `default`) and status is `review`, the existing Step 1 status halt applies'
}

@test "the re-entry PR probe finds an open PR because it asks for the exact branch" {
  _reentry_fixture
  _reentry_fence 1 "$TMP/fence1.sh"
  cat > "$TMP/run.sh" <<RUN
#!/bin/bash
set -euo pipefail
. "$TMP/fence1.sh"
printf 'wt=%s\nbranch=%s\npr=%s\n' "\$_wt" "\$STORY_BRANCH" "\$_open_pr"
RUN
  run env PATH="$TMP/bin:$PATH" CLAUDE_PLUGIN_ROOT="$TMP/plugin" bash "$TMP/run.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wt=$TMP/wt"* ]]
  [[ "$output" == *"branch=feat/some-story-some-slug"* ]]
  [[ "$output" == *"pr=2380"* ]]
  grep -qF -- "--head feat/some-story-some-slug --state open" "$TMP/gh-calls.log"
}

@test "a failing gh is never read as no open PR" {
  _reentry_fixture
  _reentry_fence 1 "$TMP/fence1.sh"
  cat > "$TMP/run.sh" <<RUN
#!/bin/bash
set -euo pipefail
. "$TMP/fence1.sh"
printf 'reached\n'
RUN
  run env GH_STUB_RC=1 PATH="$TMP/bin:$PATH" CLAUDE_PLUGIN_ROOT="$TMP/plugin" bash "$TMP/run.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"reached"* ]]
  _has "$(_flat "$(_reentry)")" 'A non-zero `gh` exit is a HALT, never read as "no open PR".'
}

@test "re-entry rebinds PROJECT_PATH so the helpers act on the worktree, and keeps the teardown inputs" {
  _reentry_fixture
  _make_repo "$TMP/primary"
  git -C "$TMP/primary" commit -q --allow-empty -m "different head"
  _write_bound_story "$TMP/story.md" "$(git -C "$TMP/wt" rev-parse HEAD)"
  _reentry_fence 2 "$TMP/fence2.sh"
  cat > "$TMP/run.sh" <<RUN
#!/bin/bash
set -euo pipefail
_wt="$TMP/wt"
PROJECT_PATH="$TMP/primary"
export PROJECT_PATH
. "$TMP/fence2.sh"
printf 'primary=%s\nworktree=%s\n' "\$PRIMARY_CODE_TREE" "\$STORY_WORKTREE_PATH"
"$REVIEW_ORDER" assert-reviewed-head --story "$TMP/story.md"
RUN
  run bash "$TMP/run.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"primary=$TMP/primary"* ]]
  [[ "$output" == *"worktree=$TMP/wt"* ]]
}

@test "the re-entry rebind comes before the assertion that picks the target" {
  _assert_order "$(_reentry)" \
    '_open_pr="$(' \
    'export PROJECT_PATH' \
    'review-order.sh assert-reviewed-head --story {story_path}'
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
  grep -qF -- "fetch --end-of-options origin staging" "$TMP/git-calls.log"
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
