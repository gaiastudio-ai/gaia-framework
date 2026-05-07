/**
 * commitlint configuration for gaia-public.
 *
 * Enforces Conventional Commits on PR titles targeting staging and main.
 * Used by .github/workflows/commitlint.yml via wagoid/commitlint-github-action.
 *
 * AC4: Non-conforming PR titles (e.g., "fix stuff") fail the check.
 *      Conforming titles (e.g., "fix(skill): repair broken reference") pass.
 */
export default {
  extends: ["@commitlint/config-conventional"],
  // Ignore historical commits that predate this commitlint config or that
  // legitimately use a non-conforming subject by convention.
  //
  // - "release:" subjects are produced by the staging→main release PRs
  //   (e.g., #495 "release: sprint-37 + sprint-38 ...") and are part of the
  //   sprint-cadence release flow; they predate this config and live on main.
  //   When a fixup or hotfix PR merges main into staging, the action walks
  //   past the merge commit into main's history and re-lints these subjects.
  //   Returning true from `ignores` skips them without affecting current PR
  //   linting.
  // - Merge commits ("Merge branch ...") are git-generated and not authored
  //   subjects.
  ignores: [
    (commit) => /^release: /.test(commit),
    (commit) => /^Merge (branch|pull request|remote-tracking) /.test(commit),
  ],
  rules: {
    "type-enum": [
      2,
      "always",
      [
        "feat",
        "fix",
        "chore",
        "docs",
        "refactor",
        "test",
        "build",
        "ci",
        "perf",
        "style",
      ],
    ],
    "subject-empty": [2, "never"],
    "subject-max-length": [2, "always", 100],
    "type-empty": [2, "never"],
  },
};
