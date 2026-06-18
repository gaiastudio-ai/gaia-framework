#!/usr/bin/env node
'use strict';
/**
 * version-bump.js — Project-generic version-bump orchestrator.
 *
 * Reads `release.version_files[]` from project-config.yaml and bumps the
 * version in each listed file. Supports JSON files (package.json, plugin.json)
 * and plain-text files (VERSION). Zero external dependencies — uses only
 * Node.js built-in modules (fs, path).
 *
 * Usage:
 *   node version-bump.js <patch|minor|major|X.Y.Z> [options]
 *
 * Options:
 *   --config <path>        Path to project-config.yaml
 *   --project-root <path>  Project root directory (version files resolved relative to this)
 *   --dry-run              Print planned changes without writing
 *   --help                 Show usage information
 *
 * Output (on success):
 *   Machine-readable JSON summary on stdout:
 *   {
 *     "old_version": "1.2.3",
 *     "new_version": "1.2.4",
 *     "bump_type": "patch",
 *     "bumped": [
 *       { "file": "plugin.json", "format": "json", "old": "1.2.3", "new": "1.2.4" },
 *       { "file": "VERSION", "format": "text", "old": "1.2.3", "new": "1.2.4" }
 *     ]
 *   }
 *
 * Exit codes:
 *   0 — success
 *   1 — usage / argument error
 *   2 — config error (missing key, missing file)
 *   3 — file processing error (unsupported format, corrupt file)
 */

const fs = require('fs');
const path = require('path');

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const args = {
    bumpSpec: null,
    configPath: null,
    projectRoot: null,
    dryRun: false,
    help: false,
  };

  let i = 0;
  while (i < argv.length) {
    const arg = argv[i];
    switch (arg) {
      case '--config':
        args.configPath = argv[++i];
        break;
      case '--project-root':
        args.projectRoot = argv[++i];
        break;
      case '--dry-run':
        args.dryRun = true;
        break;
      case '--help':
      case '-h':
        args.help = true;
        break;
      default:
        if (!arg.startsWith('--') && !args.bumpSpec) {
          args.bumpSpec = arg;
        } else {
          process.stderr.write(`version-bump: unknown argument: ${arg}\n`);
          process.exit(1);
        }
    }
    i++;
  }

  return args;
}

function printHelp() {
  const help = `version-bump.js — project-generic version-bump orchestrator

Usage:
  node version-bump.js <patch|minor|major|X.Y.Z> [options]

Options:
  --config <path>        Path to project-config.yaml
  --project-root <path>  Project root directory
  --dry-run              Print planned changes without writing
  --help                 Show this help message

Bump types:
  patch    Increment the patch version (1.2.3 -> 1.2.4)
  minor    Increment the minor version (1.2.3 -> 1.3.0)
  major    Increment the major version (1.2.3 -> 2.0.0)
  X.Y.Z    Set an explicit version

Exit codes:
  0  Success
  1  Usage / argument error
  2  Config error (missing release.version_files, missing config file)
  3  File processing error (unsupported format, corrupt file)
`;
  process.stdout.write(help);
}

// ---------------------------------------------------------------------------
// Config parsing (YAML subset — reads release.version_files[] only)
// ---------------------------------------------------------------------------

/**
 * Parse the release.version_files list from a project-config.yaml file.
 * This is a minimal YAML parser that handles the specific nested list format:
 *
 *   release:
 *     version_files:
 *       - file1.json
 *       - file2
 *
 * Also handles inline list: version_files: [file1.json, file2]
 */
function parseVersionFiles(configPath) {
  if (!fs.existsSync(configPath)) {
    process.stderr.write(`version-bump: config file not found: ${configPath}\n`);
    process.exit(2);
  }

  const content = fs.readFileSync(configPath, 'utf8');
  const lines = content.split('\n');

  let inRelease = false;
  let inVersionFiles = false;
  let releaseIndent = -1;
  let vfIndent = -1;
  const files = [];

  for (let li = 0; li < lines.length; li++) {
    const line = lines[li];
    const trimmed = line.trimStart();

    // Skip empty lines and comments.
    if (trimmed === '' || trimmed.startsWith('#')) continue;

    // Measure indentation.
    const indent = line.length - trimmed.length;

    // Detect top-level `release:` block.
    if (indent === 0 && trimmed.match(/^release\s*:/)) {
      inRelease = true;
      releaseIndent = 0;
      inVersionFiles = false;

      // Check for inline: release: { version_files: [...] }
      // (unlikely but defensive)
      continue;
    }

    // If we were in the release block but hit another top-level key, leave.
    if (inRelease && indent === 0 && trimmed.match(/^[a-zA-Z_]/)) {
      inRelease = false;
      inVersionFiles = false;
      continue;
    }

    if (!inRelease) continue;

    // Inside release block: look for version_files.
    if (!inVersionFiles && trimmed.match(/^version_files\s*:/)) {
      // Check for inline list: version_files: [a, b, c]
      const inlineMatch = trimmed.match(/^version_files\s*:\s*\[([^\]]*)\]/);
      if (inlineMatch) {
        const items = inlineMatch[1].split(',').map(s => s.trim().replace(/^["']|["']$/g, ''));
        return items.filter(s => s.length > 0);
      }

      // Check for empty inline list.
      if (trimmed.match(/^version_files\s*:\s*\[\s*\]/)) {
        return [];
      }

      inVersionFiles = true;
      vfIndent = indent;
      continue;
    }

    // If we are inside version_files and hit a sibling key at the same or lesser indent, leave.
    if (inVersionFiles && indent <= vfIndent && !trimmed.startsWith('-')) {
      inVersionFiles = false;
      continue;
    }

    // Collect list items.
    if (inVersionFiles && trimmed.startsWith('- ')) {
      const item = trimmed.slice(2).trim().replace(/^["']|["']$/g, '');
      if (item.length > 0) {
        files.push(item);
      }
    }
  }

  return files.length > 0 ? files : null;
}

// ---------------------------------------------------------------------------
// Semver operations
// ---------------------------------------------------------------------------

const SEMVER_RE = /^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$/;

function parseSemver(version) {
  const m = version.match(SEMVER_RE);
  if (!m) return null;
  return {
    major: parseInt(m[1], 10),
    minor: parseInt(m[2], 10),
    patch: parseInt(m[3], 10),
    prerelease: m[4] || null,
  };
}

function formatSemver(sv) {
  let s = `${sv.major}.${sv.minor}.${sv.patch}`;
  if (sv.prerelease) s += `-${sv.prerelease}`;
  return s;
}

function bumpVersion(current, bumpType) {
  // Explicit version: validate and return as-is.
  if (bumpType.match(SEMVER_RE)) {
    return bumpType;
  }

  const sv = parseSemver(current);
  if (!sv) {
    process.stderr.write(`version-bump: cannot parse current version '${current}' as semver\n`);
    process.exit(3);
  }

  switch (bumpType) {
    case 'patch':
      sv.patch++;
      sv.prerelease = null;
      break;
    case 'minor':
      sv.minor++;
      sv.patch = 0;
      sv.prerelease = null;
      break;
    case 'major':
      sv.major++;
      sv.minor = 0;
      sv.patch = 0;
      sv.prerelease = null;
      break;
    default:
      process.stderr.write(`version-bump: unknown bump type '${bumpType}'. Expected: patch, minor, major, or X.Y.Z\n`);
      process.exit(1);
  }

  return formatSemver(sv);
}

// ---------------------------------------------------------------------------
// File format detection and processing
// ---------------------------------------------------------------------------

/**
 * Detect format of a version file. Returns 'json' or 'text'.
 * JSON files must parse as valid JSON with a "version" key.
 * Everything else is treated as plain-text.
 */
function detectFormat(filePath) {
  const content = fs.readFileSync(filePath, 'utf8');

  // Check for null bytes (binary file indicator).
  if (content.includes('\0')) {
    return 'binary';
  }

  // Try JSON parse.
  try {
    const parsed = JSON.parse(content);
    if (typeof parsed === 'object' && parsed !== null && 'version' in parsed) {
      return 'json';
    }
    // Valid JSON but no "version" key — treat as unsupported.
    return 'json-no-version';
  } catch {
    // Not JSON — check if it looks like a plain-text version string.
    const trimmed = content.trim();
    if (trimmed.match(SEMVER_RE)) {
      return 'text';
    }
    // Does not match semver — unsupported.
    return 'unknown';
  }
}

function readVersion(filePath, format) {
  const content = fs.readFileSync(filePath, 'utf8');

  if (format === 'json') {
    const parsed = JSON.parse(content);
    return parsed.version;
  }

  if (format === 'text') {
    return content.trim();
  }

  return null;
}

function writeVersion(filePath, newVersion, format) {
  if (format === 'json') {
    const content = fs.readFileSync(filePath, 'utf8');
    const parsed = JSON.parse(content);
    parsed.version = newVersion;
    // Detect indentation from the original file to preserve formatting.
    const indentMatch = content.match(/^(\s+)"/m);
    const indent = indentMatch ? indentMatch[1].length : 2;
    // Preserve trailing newline if original had one.
    const trailingNewline = content.endsWith('\n');
    let output = JSON.stringify(parsed, null, indent);
    if (trailingNewline) output += '\n';
    fs.writeFileSync(filePath, output, 'utf8');
    return;
  }

  if (format === 'text') {
    // Write the version string with a trailing newline.
    fs.writeFileSync(filePath, newVersion + '\n', 'utf8');
    return;
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function main() {
  const args = parseArgs(process.argv.slice(2));

  if (args.help) {
    printHelp();
    process.exit(0);
  }

  if (!args.bumpSpec) {
    process.stderr.write('version-bump: missing bump specifier. Run with --help for usage.\n');
    process.exit(1);
  }

  if (!args.configPath) {
    process.stderr.write('version-bump: --config <path> is required\n');
    process.exit(1);
  }

  if (!args.projectRoot) {
    process.stderr.write('version-bump: --project-root <path> is required\n');
    process.exit(1);
  }

  // Read release.version_files from config.
  const versionFiles = parseVersionFiles(args.configPath);

  if (!versionFiles || versionFiles.length === 0) {
    process.stderr.write(
      'version-bump: missing or empty config key `release.version_files` in ' +
      args.configPath + '\n' +
      'Add a `release.version_files` list to your project-config.yaml, e.g.:\n' +
      '  release:\n' +
      '    version_files:\n' +
      '      - package.json\n' +
      '      - VERSION\n'
    );
    process.exit(2);
  }

  // Resolve file paths relative to project root.
  const resolvedFiles = versionFiles.map(f => ({
    relative: f,
    absolute: path.resolve(args.projectRoot, f),
  }));

  // Validate all files exist before making any changes.
  for (const entry of resolvedFiles) {
    if (!fs.existsSync(entry.absolute)) {
      process.stderr.write(
        `version-bump: version file not found: ${entry.relative} (resolved to ${entry.absolute})\n`
      );
      process.exit(2);
    }
  }

  // Detect formats and read current versions.
  const fileInfos = [];
  let referenceVersion = null;

  for (const entry of resolvedFiles) {
    const format = detectFormat(entry.absolute);

    if (format === 'binary') {
      process.stderr.write(
        `version-bump: unsupported file format (binary): ${entry.relative}\n`
      );
      process.exit(3);
    }

    if (format === 'json-no-version') {
      process.stderr.write(
        `version-bump: JSON file has no "version" key: ${entry.relative}\n`
      );
      process.exit(3);
    }

    if (format === 'unknown') {
      process.stderr.write(
        `version-bump: unsupported file format — cannot extract version: ${entry.relative}\n`
      );
      process.exit(3);
    }

    const currentVersion = readVersion(entry.absolute, format);
    if (!currentVersion) {
      process.stderr.write(
        `version-bump: could not read version from ${entry.relative}\n`
      );
      process.exit(3);
    }

    if (!referenceVersion) {
      referenceVersion = currentVersion;
    }

    fileInfos.push({
      relative: entry.relative,
      absolute: entry.absolute,
      format,
      oldVersion: currentVersion,
    });
  }

  // Compute the new version.
  const newVersion = bumpVersion(referenceVersion, args.bumpSpec);

  if (args.dryRun) {
    const summary = {
      dry_run: true,
      old_version: referenceVersion,
      new_version: newVersion,
      bump_type: args.bumpSpec,
      bumped: fileInfos.map(fi => ({
        file: fi.relative,
        format: fi.format,
        old: fi.oldVersion,
        new: newVersion,
      })),
    };
    process.stdout.write(JSON.stringify(summary, null, 2) + '\n');
    process.exit(0);
  }

  // Write the new version to each file.
  for (const fi of fileInfos) {
    writeVersion(fi.absolute, newVersion, fi.format);
  }

  // Emit machine-readable summary.
  const summary = {
    old_version: referenceVersion,
    new_version: newVersion,
    bump_type: args.bumpSpec,
    bumped: fileInfos.map(fi => ({
      file: fi.relative,
      format: fi.format,
      old: fi.oldVersion,
      new: newVersion,
    })),
  };

  process.stdout.write(JSON.stringify(summary) + '\n');
  process.exit(0);
}

main();
