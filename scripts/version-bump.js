#!/usr/bin/env node
"use strict";

/**
 * version-bump.js — Bump the version in plugin.json for gaia-public releases.
 *
 * Usage:
 *   node scripts/version-bump.js <patch|minor|major> [--dry-run]
 *
 * Targets: plugins/gaia/.claude-plugin/plugin.json ONLY.
 * Prints the touched file path to stdout so release.yml can parse and stage it.
 *
 * Zero runtime dependencies (ADR-005). Ported from Gaia-framework/scripts/version-bump.js.
 * Adapted for gaia-public context per E40-S1 / ADR-056.
 */

const fs = require("node:fs");
const path = require("node:path");

// ── Configuration ───────────────────────────────────────────────────────────

const BUMP_TYPES = ["patch", "minor", "major"];

const PLUGIN_JSON_REL = path.join("plugins", "gaia", ".claude-plugin", "plugin.json");
const PLUGIN_VERSION_REL = path.join("plugins", "gaia", ".plugin-version");

// ── Semver helpers (inline, no deps — ADR-005) ─────────────────────────────

/**
 * Parse a version string into components.
 * @param {string} ver  Version string like "1.127.2"
 * @returns {{ major: number, minor: number, patch: number }} or null
 */
function parseSemver(ver) {
  const m = ver.match(/^(\d+)\.(\d+)\.(\d+)$/);
  if (!m) return null;
  return { major: +m[1], minor: +m[2], patch: +m[3] };
}

/**
 * Format a parsed version object back into a version string.
 * @param {{ major: number, minor: number, patch: number }} v
 * @returns {string}
 */
function formatVersion(v) {
  return `${v.major}.${v.minor}.${v.patch}`;
}

/**
 * Compute the new version based on bump type.
 * @param {string} currentVersion  Current version string
 * @param {string} bumpType        "patch" | "minor" | "major"
 * @returns {string} New version string
 */
function computeNewVersion(currentVersion, bumpType) {
  const parsed = parseSemver(currentVersion);
  if (!parsed) throw new Error(`Cannot parse version: ${currentVersion}`);

  if (bumpType === "major") {
    return formatVersion({ major: parsed.major + 1, minor: 0, patch: 0 });
  }
  if (bumpType === "minor") {
    return formatVersion({ major: parsed.major, minor: parsed.minor + 1, patch: 0 });
  }
  // patch
  return formatVersion({
    major: parsed.major,
    minor: parsed.minor,
    patch: parsed.patch + 1,
  });
}

// ── CLI argument parsing ────────────────────────────────────────────────────

function parseArgs(argv) {
  let bumpType = null;
  let dryRun = false;

  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--dry-run") {
      dryRun = true;
    } else if (BUMP_TYPES.includes(argv[i])) {
      bumpType = argv[i];
    } else {
      console.error(`Unknown argument: ${argv[i]}`);
      process.exit(1);
    }
  }

  if (!bumpType) {
    console.error(
      "Usage: node scripts/version-bump.js <patch|minor|major> [--dry-run]"
    );
    process.exit(1);
  }

  return { bumpType, dryRun };
}

// ── Main ────────────────────────────────────────────────────────────────────

function main() {
  const { bumpType, dryRun } = parseArgs(process.argv.slice(2));
  const root = process.env.GAIA_PROJECT_ROOT || process.cwd();
  const pluginJsonPath = path.join(root, PLUGIN_JSON_REL);

  // Validate plugin.json exists
  if (!fs.existsSync(pluginJsonPath)) {
    console.error(`Missing: plugin.json (${pluginJsonPath})`);
    process.exit(1);
  }

  // Read and parse
  let content;
  try {
    content = fs.readFileSync(pluginJsonPath, "utf8");
  } catch (err) {
    console.error(`Unreadable: plugin.json — ${err.message}`);
    process.exit(1);
  }

  let data;
  try {
    data = JSON.parse(content);
  } catch (err) {
    console.error(`Invalid JSON in plugin.json — ${err.message}`);
    process.exit(1);
  }

  const currentVersion = data.version;
  if (!currentVersion || !parseSemver(currentVersion)) {
    console.error(
      `No valid version pattern found in plugin.json (got: ${currentVersion || "undefined"})`
    );
    process.exit(1);
  }

  // Compute new version
  const newVersion = computeNewVersion(currentVersion, bumpType);

  // Dry-run: print and exit
  if (dryRun) {
    console.log(`Dry run: ${currentVersion} -> ${newVersion}`);
    console.log(`\nWould update:`);
    console.log(`  plugin.json: ${currentVersion} -> ${newVersion}`);
    console.log(`  .plugin-version: ${currentVersion} -> ${newVersion}`);
    console.log(`\nNo files written.`);
    process.exit(0);
  }

  // Write updated version
  data.version = newVersion;
  fs.writeFileSync(pluginJsonPath, JSON.stringify(data, null, 2) + "\n", "utf8");

  // E89-S4: write .plugin-version alongside plugin.json so the Val
  // persona_sig is emitted as `val-<semver>-<digest>` (released-tag form)
  // rather than `val-dev-<digest>` (in-tree default).
  const pluginVersionPath = path.join(process.cwd(), PLUGIN_VERSION_REL);
  fs.writeFileSync(pluginVersionPath, newVersion, "utf8");

  console.log(`Version bumped: ${currentVersion} -> ${newVersion}`);
  console.log(`\nUpdated files:`);
  console.log(`  ${PLUGIN_JSON_REL}`);
  console.log(`  ${PLUGIN_VERSION_REL}`);
}

main();
