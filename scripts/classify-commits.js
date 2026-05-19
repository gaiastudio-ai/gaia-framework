#!/usr/bin/env node
"use strict";

/**
 * classify-commits.js — Classify Conventional Commits and compute SemVer bump.
 *
 * Used by .github/workflows/release.yml to determine the bump type from a
 * commit range. Also generates Keep-a-Changelog formatted changelog entries.
 *
 * Exports: classifyCommitType, computeBumpFromCommits, generateChangelog
 * CLI: node scripts/classify-commits.js "commit1\ncommit2\n..."
 *   Prints: bump_size=<major|minor|patch|none>
 *
 * Zero runtime dependencies (ADR-005).
 */

// Conventional Commit type → bump mapping (AC1)
const TYPE_MAP = {
  feat: "minor",
  fix: "patch",
  chore: "patch",
  docs: "patch",
  refactor: "patch",
  test: "patch",
  build: "patch",
  ci: "patch",
  perf: "patch",
  style: "patch",
};

// Keep-a-Changelog category mapping (AC5)
const CHANGELOG_MAP = {
  feat: "Added",
  fix: "Fixed",
  refactor: "Changed",
  perf: "Changed",
  chore: "Changed",
  docs: "Changed",
  test: "Changed",
  build: "Changed",
  ci: "Changed",
  style: "Changed",
};

/**
 * Classify a single commit message into a bump type.
 * @param {string} message  Full commit message (subject + optional body)
 * @returns {"major"|"minor"|"patch"|null}  null if not a qualifying commit
 */
function classifyCommitType(message) {
  if (!message || typeof message !== "string") return null;

  // Skip [skip ci] commits (AC3 — bot release commits)
  if (message.includes("[skip ci]")) return null;

  // Check for BREAKING CHANGE in body
  if (/BREAKING CHANGE[:\s]/i.test(message)) return "major";

  // Parse Conventional Commit subject line
  const subjectLine = message.split("\n")[0];
  const match = subjectLine.match(
    /^(feat|fix|chore|docs|refactor|test|build|ci|perf|style)(\(.+?\))?(!)?:\s/
  );
  if (match) {
    const type = match[1];
    const breaking = match[3] === "!";
    if (breaking) return "major";
    return TYPE_MAP[type] || null;
  }

  // E40-S4: subject regex did not match a Conventional Commit type. GitHub's
  // squash-merge collapses N commits into a single commit whose body
  // preserves the original subjects as bullet lines (e.g. "* feat(scope): ...").
  // Fall back to scanning the message body for those bullet-prefixed CC
  // type markers. The body-scan recognizes only the BUMP-class types
  // (feat → minor, fix → patch) plus the breaking-change marker (`!` suffix
  // → major). Non-bump types (chore, docs, refactor, test, build, ci, perf,
  // style) in body bullets do NOT escalate the bump — they're informational
  // for a non-CC-subject commit. This is intentional per E40-S4 AC2: a
  // squashed `promote:` PR whose body contains only chore/docs bullets MUST
  // NOT trigger a release. For subject-typed commits, the existing TYPE_MAP
  // (lines 18-29) is honored as-is — this body-scan branch only fires when
  // the subject did NOT match the CC regex above.
  // BREAKING CHANGE detection above runs BEFORE this fallback, so a
  // `BREAKING CHANGE:` line in the body already returned "major" earlier.
  const bodyLines = message.split("\n").slice(1);
  const bodyRegex = /^\s*\*?\s*(feat|fix)(\(.+?\))?(!)?:\s/;
  const precedence = { major: 3, minor: 2, patch: 1 };
  let highest = null;
  for (const line of bodyLines) {
    const m = line.match(bodyRegex);
    if (!m) continue;
    const bump = m[3] === "!" ? "major" : TYPE_MAP[m[1]];
    if (!bump) continue;
    if (!highest || precedence[bump] > precedence[highest]) {
      highest = bump;
    }
  }
  return highest;
}

/**
 * Compute the highest-precedence bump from a list of commit messages.
 * Precedence: major > minor > patch > null (AC-EC1)
 * @param {string[]} commits  Array of commit message strings
 * @returns {"major"|"minor"|"patch"|null}  null if no qualifying commits
 */
function computeBumpFromCommits(commits) {
  if (!commits || commits.length === 0) return null;

  let highest = null;
  const precedence = { major: 3, minor: 2, patch: 1 };

  for (const msg of commits) {
    const bump = classifyCommitType(msg);
    if (!bump) continue;
    if (!highest || precedence[bump] > precedence[highest]) {
      highest = bump;
    }
    // Short-circuit: can't go higher than major
    if (highest === "major") break;
  }

  return highest;
}

/**
 * Generate a Keep-a-Changelog formatted section from commits.
 * @param {string[]} commits  Array of commit message strings
 * @param {string} version    Version string (e.g., "1.128.0")
 * @returns {string}  Markdown changelog section
 */
function generateChangelog(commits, version) {
  const today = new Date().toISOString().split("T")[0];
  const groups = {};
  const breaking = [];

  for (const msg of commits) {
    const subjectLine = msg.split("\n")[0];
    const match = subjectLine.match(
      /^(feat|fix|chore|docs|refactor|test|build|ci|perf|style)(\(.+?\))?(!)?:\s(.+)$/
    );
    if (!match) continue;
    if (msg.includes("[skip ci]")) continue;

    const type = match[1];
    const scope = match[2] || "";
    const isBreaking = match[3] === "!" || /BREAKING CHANGE[:\s]/i.test(msg);
    const description = match[4];

    const category = CHANGELOG_MAP[type] || "Changed";
    if (!groups[category]) groups[category] = [];
    groups[category].push(`${scope ? scope + " " : ""}${description}`);

    if (isBreaking) {
      breaking.push(description);
    }
  }

  let output = `## [${version}] — ${today}\n`;

  if (breaking.length > 0) {
    output += `\n### BREAKING CHANGES\n\n`;
    for (const b of breaking) {
      output += `- ${b}\n`;
    }
  }

  // Output in canonical order: Added, Changed, Fixed
  for (const category of ["Added", "Changed", "Fixed"]) {
    if (!groups[category]) continue;
    output += `\n### ${category}\n\n`;
    for (const item of groups[category]) {
      output += `- ${item}\n`;
    }
  }

  return output;
}

// CLI mode
if (require.main === module) {
  const input = process.argv[2];
  if (!input) {
    console.error("Usage: node scripts/classify-commits.js <commits-encoded>");
    process.exit(1);
  }

  // E40-S4: input encoding contract.
  // The workflow (release.yml) feeds commits as a single string where each
  // commit message (subject + body) is followed by the literal delimiter
  // `---COMMIT---` on its own line, and all newlines are escape-encoded as
  // literal `\n` text by the shell. So the input string looks like:
  //   "feat(x): one\nbody line\n---COMMIT---\nfix(y): two\n---COMMIT---\n"
  // Split on `\n---COMMIT---\n` first to get per-commit blocks, then convert
  // each block's `\n` escapes back to real newlines so classifyCommitType
  // can read the body. Backward-compat: if the input has no `---COMMIT---`
  // delimiter (legacy %s-only format from a stale workflow), fall back to
  // the old subject-per-line split.
  let commits;
  if (input.includes("---COMMIT---")) {
    commits = input
      .split("\\n---COMMIT---\\n")
      .map((block) => block.replace(/\\n/g, "\n").trim())
      .filter(Boolean);
  } else {
    commits = input.split("\\n").filter(Boolean);
  }
  const bump = computeBumpFromCommits(commits);

  if (!bump) {
    console.log("bump_size=none");
    console.log("has_commits=false");
  } else {
    console.log(`bump_size=${bump}`);
    console.log("has_commits=true");
  }
}

module.exports = { classifyCommitType, computeBumpFromCommits, generateChangelog };
