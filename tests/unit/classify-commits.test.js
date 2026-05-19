#!/usr/bin/env node
"use strict";

/**
 * Unit tests for scripts/classify-commits.js
 * Tests the commit classification logic used by release.yml to determine bump type.
 *
 * Covers: AC1 (bump classification from Conventional Commits),
 *         AC3 (clean skip on zero qualifying commits),
 *         AC-EC1 (mixed range — highest precedence wins).
 */

const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");

// The classify function will be exported from the module
const SCRIPT_PATH = path.resolve(__dirname, "../../scripts/classify-commits.js");

function loadClassify() {
  // Clear require cache to get fresh module
  delete require.cache[require.resolve(SCRIPT_PATH)];
  return require(SCRIPT_PATH);
}

describe("classify-commits", () => {
  describe("classifyCommitType", () => {
    it("should classify feat: as minor", () => {
      const { classifyCommitType } = loadClassify();
      assert.equal(classifyCommitType("feat: add new workflow"), "minor");
    });

    it("should classify fix: as patch", () => {
      const { classifyCommitType } = loadClassify();
      assert.equal(classifyCommitType("fix: repair broken reference"), "patch");
    });

    it("should classify feat!: as major (breaking)", () => {
      const { classifyCommitType } = loadClassify();
      assert.equal(classifyCommitType("feat!: drop legacy API"), "major");
    });

    it("should classify fix!: as major (breaking)", () => {
      const { classifyCommitType } = loadClassify();
      assert.equal(classifyCommitType("fix!: remove deprecated config"), "major");
    });

    it("should classify chore: as patch", () => {
      const { classifyCommitType } = loadClassify();
      assert.equal(classifyCommitType("chore: update dependencies"), "patch");
    });

    it("should classify docs: as patch", () => {
      const { classifyCommitType } = loadClassify();
      assert.equal(classifyCommitType("docs: update README"), "patch");
    });

    it("should classify refactor: as patch", () => {
      const { classifyCommitType } = loadClassify();
      assert.equal(classifyCommitType("refactor: simplify version logic"), "patch");
    });

    it("should classify BREAKING CHANGE in body as major", () => {
      const { classifyCommitType } = loadClassify();
      assert.equal(
        classifyCommitType("feat: new API\n\nBREAKING CHANGE: removes old endpoint"),
        "major"
      );
    });

    it("should return null for non-conventional commit", () => {
      const { classifyCommitType } = loadClassify();
      assert.equal(classifyCommitType("random commit message"), null);
    });

    it("should return null for [skip ci] commits", () => {
      const { classifyCommitType } = loadClassify();
      assert.equal(
        classifyCommitType("chore(release): v1.128.0 [skip ci]"),
        null
      );
    });
  });

  describe("body-scan fallback for non-CC subjects (E40-S4)", () => {
    // AC1 + AC6(a): squash-merge promote: subject with mixed feat/fix bullets
    // returns minor (max of feat=minor and fix=patch per TYPE_MAP precedence)
    it("should body-scan a squash-merge promote: commit and return minor (mixed feat/fix bullets)", () => {
      const { classifyCommitType } = loadClassify();
      const message = [
        "promote: staging → main (post-sprint-48 + E17-S30..S36 + E95-S1 + E40-S2..S3 batch) (#774)",
        "",
        "* feat(E17-S30): wire test-environment.yaml.example installation",
        "* feat(E40-S2): wire Anchor release.yml commit-classification range",
        "* fix(E55-S11): registry dual-write",
      ].join("\n");
      assert.equal(classifyCommitType(message), "minor");
    });

    // AC2 + AC6(b): squash-merge with only non-bump bullets returns null
    it("should body-scan a squash-merge with only chore/docs bullets and return null", () => {
      const { classifyCommitType } = loadClassify();
      const message = [
        "Merge pull request #999 from foo/bar",
        "",
        "* chore(deps): bump foo",
        "* docs: update README",
        "* test: add coverage",
      ].join("\n");
      assert.equal(classifyCommitType(message), null);
    });

    // AC3 + AC6(c): subject-typed commit ignores body content (regression guard)
    it("should NOT body-scan when subject regex matches; subject wins", () => {
      const { classifyCommitType } = loadClassify();
      const message = [
        "feat(E40-S4): wire body scan",
        "",
        "* fix: this fix bullet is irrelevant — subject already wins",
      ].join("\n");
      assert.equal(classifyCommitType(message), "minor");
    });

    // AC4 + AC6(d): BREAKING CHANGE still fires regardless of body bullets
    it("should return major when BREAKING CHANGE appears in body, even with non-CC subject", () => {
      const { classifyCommitType } = loadClassify();
      const message = [
        "promote: staging → main (#999)",
        "",
        "* feat(api): redesign endpoint",
        "",
        "BREAKING CHANGE: endpoint shape changed",
      ].join("\n");
      assert.equal(classifyCommitType(message), "major");
    });

    // AC6(e) + TYPE_MAP precedence: feat dominates fix in mixed body
    it("should return minor when body has both feat and fix bullets (feat dominates)", () => {
      const { classifyCommitType } = loadClassify();
      const message = [
        "promote: staging → main",
        "",
        "* fix(a): patch one",
        "* fix(b): patch two",
        "* fix(c): patch three",
        "* feat(x): minor one",
        "* feat(y): minor two",
        "* feat(z): minor three",
        "* chore(deps): bump dep",
        "* chore(lint): cleanup",
      ].join("\n");
      assert.equal(classifyCommitType(message), "minor");
    });
  });

  describe("computeBumpFromCommits", () => {
    it("should return major when breaking change is present", () => {
      const { computeBumpFromCommits } = loadClassify();
      const commits = [
        "fix: small fix",
        "feat!: drop legacy API",
        "feat: add feature",
      ];
      assert.equal(computeBumpFromCommits(commits), "major");
    });

    it("should return minor when feat is highest", () => {
      const { computeBumpFromCommits } = loadClassify();
      const commits = [
        "fix: small fix",
        "feat: add feature",
        "chore: update deps",
      ];
      assert.equal(computeBumpFromCommits(commits), "minor");
    });

    it("should return patch when only fix/chore/docs present", () => {
      const { computeBumpFromCommits } = loadClassify();
      const commits = [
        "fix: small fix",
        "docs: update readme",
        "chore: cleanup",
      ];
      assert.equal(computeBumpFromCommits(commits), "patch");
    });

    it("should return null when no qualifying commits", () => {
      const { computeBumpFromCommits } = loadClassify();
      const commits = [
        "chore(release): v1.128.0 [skip ci]",
        "random non-conventional message",
      ];
      assert.equal(computeBumpFromCommits(commits), null);
    });

    it("should return null for empty commit list", () => {
      const { computeBumpFromCommits } = loadClassify();
      assert.equal(computeBumpFromCommits([]), null);
    });
  });

  describe("generateChangelog", () => {
    it("should group commits by Keep-a-Changelog categories", () => {
      const { generateChangelog } = loadClassify();
      const commits = [
        "feat: add new workflow",
        "fix: repair broken reference",
        "refactor: simplify version logic",
      ];
      const changelog = generateChangelog(commits, "1.128.0");
      assert.ok(changelog.includes("### Added"), "Should have Added section");
      assert.ok(changelog.includes("### Fixed"), "Should have Fixed section");
      assert.ok(changelog.includes("### Changed"), "Should have Changed section");
      assert.ok(changelog.includes("1.128.0"), "Should include version");
    });

    it("should note breaking changes", () => {
      const { generateChangelog } = loadClassify();
      const commits = ["feat!: drop legacy API"];
      const changelog = generateChangelog(commits, "2.0.0");
      assert.ok(
        changelog.includes("BREAKING"),
        "Should note breaking changes"
      );
    });
  });
});
