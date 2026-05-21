---
name: gaia-git-workflow
description: Trunk-based development, Conventional Commits, PR template and review checklist, merge strategies, and conflict resolution. Shared dev skill JIT-loaded by dev-story and stack dev agents.
allowed-tools: [Read, Grep, Bash]
orchestration_class: light-procedural
---

## About

Native Claude Code conversion of the legacy `_gaia/dev/skills/git-workflow.md` skill. Preserves the four sectioned-loading IDs (`branching`, `commits`, `pull-requests`, `conflict-resolution`) verbatim so JIT-loaders can request a single section.

- ADR-041 — Native execution model via Claude Code Skills + Subagents + Plugins + Hooks. This skill no longer runs through `workflow.xml`; it is loaded directly by the native skill/subagent runtime.
- ADR-042 — Scripts-over-LLM for deterministic operations. This skill is prose-only; any concrete `git` invocation lives in the calling agent or in a skill-local script, not inline here.
- ADR-046 — Hybrid memory. This is a shared content skill and does NOT load agent memory sidecars.

> **Applicable to:** all 6 stack dev agents (typescript, angular, flutter, java, python, mobile). The legacy `applicable_agents` frontmatter field does not map to the Claude Code SKILL schema, so it lives here as a prose note (per E28-S19 schema).

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
Types: `feature/`, `fix/`, `hotfix/`, `refactor/`, `chore/`, `test/`

Examples:
```
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
the fix; close+reopen leaves no git footprint. (AF-2026-05-21-4 Finding 3
— documented after the recipe was rediscovered during sprint-50
dogfooding.)

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

## Test Scenarios

Migrated from the legacy `test_scenarios` frontmatter array (per E28-S19 schema; legacy field is not retained in active frontmatter).

| Scenario | Expected |
|----------|----------|
| Feature branch creation and naming | Branch name follows convention `{type}/{ticket}-{description}` |
| Conventional commit message | Message follows `type(scope): description` format |
| PR creation with template | PR body includes all required sections |
