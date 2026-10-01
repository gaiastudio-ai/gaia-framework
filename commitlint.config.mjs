/**
 * commitlint configuration for gaia-framework.
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
  //   (e.g., "release: sprint-37 + sprint-38 ...") and are part of the
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
    // Older commits whose subject started with a bare story-key prefix
    // (e.g. "EXX-SY: description ..."). commit-msg.sh now emits a
    // scope-free or product-scope subject with a Story: body line, but
    // these historical subjects remain on main and are re-linted when a
    // staging→main promotion PR walks into the range. Exempting the
    // story-key prefix avoids blocking release PRs on legacy subjects.
    (commit) => /^E\d+-S\d+:\s/.test(commit),
    // Already-merged squash commits carry GitHub's `(#NNNN)` PR-number suffix
    // that the squash UI appends to the subject. On a staging→main promotion
    // PR the action walks into the range and re-lints these subjects — and
    // the appended ` (#NNNN)` can push an otherwise-valid, already-linted
    // subject past the 100-char limit (e.g. a 95-char `fix(...)` subject
    // becomes 103 after ` (#NNNN)`). They were already linted when their own
    // PR merged, so skip any subject ending in a GitHub PR-number suffix.
    // The promotion PR's OWN head commit (`chore: promote …`) has no such
    // suffix and is still linted normally.
    //
    // NOTE: the `ignores` predicate receives the FULL raw commit message
    // (header + body), so test the FIRST LINE (the subject/header) rather
    // than the end of the whole message — a `$` anchor on the raw commit
    // would test the end of the body and never match.
    (commit) => /\(#\d+\)$/.test((commit.split("\n")[0] || "").trim()),
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
