---
name: gaia-git-workflow
description: Trunk-based development, Conventional Commits, PR template and review checklist, merge strategies, and conflict resolution. Shared dev skill JIT-loaded by dev-story and stack dev agents.
allowed-tools: [Read, Grep, Bash]
orchestration_class: light-procedural
---

## About

Native Claude Code conversion of the legacy `_gaia/dev/skills/git-workflow.md` skill. Preserves the four original sectioned-loading IDs (`branching`, `commits`, `pull-requests`, `conflict-resolution`) verbatim so JIT-loaders can request a single section, and adds a fifth (`worktrees`).

- Native execution model via Claude Code Skills + Subagents + Plugins + Hooks. This skill no longer runs through `workflow.xml`; it is loaded directly by the native skill/subagent runtime.
- Scripts-over-LLM for deterministic operations. This skill is prose-only; any concrete `git` invocation lives in the calling agent or in a skill-local script, not inline here.
- Hybrid memory. This is a shared content skill and does NOT load agent memory sidecars.

> **Applicable to:** all 9 stack dev agents (typescript, angular, flutter, java, python, mobile, go, bash, embedded). The legacy `applicable_agents` frontmatter field does not map to the Claude Code SKILL schema, so it lives here as a prose note.

<!-- SECTION: branching -->
## Branching Strategy

### Trunk-Based Development
- `main` is always deployable
- Short-lived feature branches (max 2-3 days)
- Use feature flags for incomplete features in production

### Branch Naming Convention
```
{type}/{ticket-key}-{short-description}
```
Types: `feat/`, `feature/`, `fix/`, `hotfix/`, `refactor/`, `chore/`, `test/`

`feat/` and `feature/` are both listed on purpose. `feature/` is the generic
type above; `feat/` is the GAIA convention for a **story branch** — the branch a
story is implemented on, named after the story it belongs to. It is a project
convention, not a git universal, so a project that does not work in stories has
no reason to use it.

Examples:
```
feat/{story_key}-{slug}
feature/PROJ-123-user-auth
fix/PROJ-456-login-redirect
hotfix/PROJ-789-payment-null
refactor/PROJ-101-extract-service
```

### Branch Rules
- Never commit directly to `main`
- Delete branches after merge
- Rebase feature branches on `main` before PR
- One branch per story/ticket

### Release Branches
- Create `release/v{major}.{minor}.{patch}` for release candidates
- Cherry-pick fixes to release branch if needed
- Tag release commits: `v{major}.{minor}.{patch}`

<!-- SECTION: commits -->
## Conventional Commits

### Format
```
type(scope): description

[optional body]

[optional footer(s)]
```

### Types
| Type | Use When |
|------|----------|
| `feat` | New feature or capability |
| `fix` | Bug fix |
| `refactor` | Code restructuring, no behavior change |
| `test` | Adding or updating tests |
| `docs` | Documentation only |
| `chore` | Build, tooling, dependencies |
| `style` | Formatting, whitespace, semicolons |
| `perf` | Performance improvement |
| `ci` | CI/CD configuration |

### Scope
- Use the component or module name: `feat(auth): add JWT refresh`
- Use the file or layer: `fix(api): handle null response`
- Omit scope for broad changes: `chore: update dependencies`

### Examples
```
feat(auth): add password reset flow
fix(cart): prevent negative quantities
refactor(user-service): extract validation logic
test(payment): add integration tests for Stripe webhook
docs(api): update endpoint documentation
perf(search): add database index for full-text queries
```

### Breaking Changes
- Add `!` after type/scope: `feat(api)!: change response format`
- Add `BREAKING CHANGE:` footer with migration instructions

<!-- SECTION: pull-requests -->
## Pull Requests

### PR Template
```markdown
## Summary
Brief description of changes and motivation.

## Changes
- List of specific changes made

## Testing
- [ ] Unit tests added/updated
- [ ] Integration tests pass
- [ ] Manual testing completed

## Checklist
- [ ] Code follows project conventions
- [ ] No console.log/print statements left
- [ ] Documentation updated if needed
- [ ] No secrets or credentials committed
```

### Review Checklist
- Correctness: Does the code do what it claims?
- Tests: Are changes covered by tests?
- Security: Any new attack vectors introduced?
- Performance: Any N+1 queries, unnecessary re-renders?
- Readability: Can a new team member understand this?

### Merge Strategies
- **Squash merge** for feature branches (clean history)
- **Merge commit** for release branches (preserve history)
- **Rebase** for keeping branch up to date with main
- Never force push to shared branches

### Recovering from a failed commitlint / lint-pr-title check

When `lint-pr-title` (or any commitlint-based check) fails on a PR,
editing the PR title or body and running `gh run rerun --failed` does
**NOT** pick up the new content — the rerun replays the same payload
the failed job saw. Recipes that actually work:

1. **Push an empty commit** to the feature branch. The new push triggers
   a fresh check-suite that reads the current PR title/body:
   ```bash
   git commit --allow-empty -m "chore: trigger fresh PR lint"
   git push
   ```
2. **Close + reopen** the PR. The reopen event re-triggers the check-suite:
   ```bash
   gh pr close <pr-number>
   gh pr reopen <pr-number>
   ```

The empty-commit approach is preferred when you want an audit trail of
the fix; close+reopen leaves no git footprint. (Documented after the
recipe was rediscovered during sprint dogfooding.)

<!-- SECTION: conflict-resolution -->
## Conflict Resolution

### Merge vs Rebase
- **Rebase** for local feature branches before PR
- **Merge** when integrating shared branches
- Never rebase public/shared branches

### Conflict Markers
```
<<<<<<< HEAD (your changes)
  current code
=======
  incoming code
>>>>>>> feature/branch-name
```

### Resolution Steps
1. Identify all conflicts: `git diff --name-only --diff-filter=U`
2. Open each file, understand both sides of the conflict
3. Choose the correct resolution (not always "ours" or "theirs")
4. Remove all conflict markers
5. Run tests after resolution
6. Stage resolved files: `git add {file}`
7. Complete the merge/rebase: `git rebase --continue` or `git merge --continue`

### Prevention
- Rebase frequently on main (daily)
- Communicate with team about shared file changes
- Keep PRs small to reduce conflict surface
- Use CODEOWNERS to assign clear file ownership

<!-- SECTION: worktrees -->
## Story Worktrees

Developing two stories in one working tree lets their edits bleed together: the
checkout is shared, and tools that scan the tree read whatever is on disk
regardless of which branch is current. A linked git worktree gives each story
its own working directory and index while sharing one object store.

**Opt-in, and off by default.** Worktree mode is active only when
`GAIA_WORKTREE_MODE=1`. The value is compared literally, so `GAIA_WORKTREE_MODE=true`
leaves the mode **off** — set it to `1` or not at all. With the mode off,
everything below is skipped and a story is developed in place exactly as before.

### Creating the worktree

Each story worktree is a directory named after the story key, inside a
`.gaia-worktrees` directory that is a **sibling of the repository's top level**:

```
<repo>/                     the primary checkout
.gaia-worktrees/{story_key} the story's worktree
```

The parent is placed beside the code tree so it shares the same filesystem as
the object store it borrows from, and creation is refused up front if that is
not true, if the parent is not writable, or if the sibling directory cannot
exist. A new worktree starts from `HEAD`: uncommitted work in the primary tree
stays in the primary tree, and is reported rather than moved.

### Branch resolution

The story branch is `feat/{story_key}-{slug}`, the same prefix the branch-type
list above describes. A branch ref outlives every worktree, so creation
resolves the branch's current state first: an absent branch is created, an
existing branch nothing holds is attached, and a branch already checked out in
another worktree is refused rather than duplicated. Re-entering a story that is
already in its worktree returns the same path and changes nothing.

Because a ref becomes a path under `.git/refs`, an over-long slug is trimmed
when the worktree builds the branch name. The story key is never trimmed, so
branch names stay unique per story.

### The working-directory contract

Every chain script resolves its working directory from `PROJECT_PATH`. In
worktree mode that variable points at the story's worktree, so branch creation,
commits, pushes and PR creation all act on the story's own checkout. After the
worktree is removed, `PROJECT_PATH` is restored to the primary checkout — and
**only** if the removal actually succeeded, so a failed removal never leaves the
variable aimed at a directory that is still in use.

### Teardown and prune

Teardown removes the worktree and prunes the administrative record. It is
idempotent, and it never forces.

A worktree that holds **modified, untracked, or ignored** files is **kept**,
with a warning naming the path. That includes gitignored content such as a
build or dependency directory, which is why teardown is not something to rely
on as unconditional cleanup: a story whose tooling writes ignored files into
its worktree leaves one behind on an ordinary, successful run. Deleting work
that was never committed anywhere is the worse outcome, so the refusal is
deliberate. A kept worktree is also still locked, so reclaiming it takes both
steps:

```bash
git worktree unlock <path> && git worktree remove --force <path>
```

Removal cannot run on a signal that cannot be trapped, so the next story start
prunes what an interrupted run left behind. That prune is conservative: it
clears a record only when the owning process is gone, the worktree is one of
its own, the checkout is clean, and the branch has no commits that exist
nowhere else. Anything else — a live owner, another tool's lock, unpushed work —
is left alone.

### When there is no git work tree

A project root that is not a git work tree has nothing to isolate. That is
treated as a **degradation, not a failure**: the story runs in place, the
working directory is left untouched, and the run continues with a warning. It
is reported distinctly from a real error so the two are never confused.

### Test Scenarios

| Scenario | Expected |
|----------|----------|
| Worktree mode unset or set to any value other than `1` | No worktree is created; the story runs in the primary checkout |
| Story started with the mode on | Worktree created at the sibling `.gaia-worktrees/{story_key}`, on branch `feat/{story_key}-{slug}` |
| Story re-entered while its worktree exists | The same path is returned; no second worktree is opened |
| Branch already checked out in another worktree | Creation is refused |
| Teardown of a clean worktree | Worktree removed, record pruned, working directory restored to the primary checkout |
| Teardown of a worktree holding untracked or ignored files | Worktree kept and reported; working directory not restored |
| Story start after an interrupted run | The stale record is pruned; a worktree with uncommitted work is kept |
| Project root that is not a git work tree | Skipped with a warning; the story runs in place |

## Test Scenarios

Migrated from the legacy `test_scenarios` frontmatter array (legacy field is not retained in active frontmatter).

| Scenario | Expected |
|----------|----------|
| Feature branch creation and naming | Branch name follows convention `{type}/{ticket}-{description}` |
| Conventional commit message | Message follows `type(scope): description` format |
| PR creation with template | PR body includes all required sections |
