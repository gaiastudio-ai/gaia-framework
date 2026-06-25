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
 *   --config <path>         Path to project-config.yaml
 *   --project-root <path>   Project root directory (version files resolved relative to this)
 *   --scope <prefixes>      Comma-separated path prefixes; only version_files whose
 *                           relative path starts with a listed prefix are bumped.
 *                           Prefix matching is directory-boundary-safe: a prefix
 *                           "packages/front" will NOT match "packages/frontend/".
 *   --scope-map <json>      JSON object mapping path prefix to bump type, e.g.
 *                           '{"packages/frontend":"minor","packages/shared":"patch"}'.
 *                           Each component group bumps from its own current version
 *                           by its own bump type. The positional bump-spec argument
 *                           is not required when --scope-map is used (the map
 *                           supplies per-component bump types).
 *   --dry-run               Print planned changes without writing
 *   --help                  Show usage information
 *
 * Per-component scoping contract:
 *   When --scope or --scope-map is given, only the version_files whose relative
 *   path starts with one of the scope prefixes participate in the bump. Each
 *   participating file bumps from its OWN current version (not a shared
 *   reference version). Files outside the scope are left untouched.
 *
 * Monotonic guard:
 *   Before writing a bumped version, the tool compares the computed target to
 *   the file's current version using numeric semver comparison. If the target
 *   is less than or equal to the current version, the write is skipped and a
 *   warning is emitted to stderr. This prevents accidental downgrades when
 *   components have divergent versions. If every scoped file is a monotonic
 *   no-op, the tool exits with code 4.
 *
 * Affected-set hand-off:
 *   The release skill passes the affected-component list to this tool via the
 *   --scope or --scope-map flags. Components whose versions are driven by an
 *   independent release process (e.g. a separately-versioned library) should
 *   either be excluded from release.version_files[] entirely or omitted from
 *   the --scope list to prevent unintended bumps.
 *
 * Output (on success):
 *   Machine-readable JSON summary on stdout:
 *   {
 *     "bump_type": "patch",
 *     "bumped": [
 *       { "file": "plugin.json", "format": "json", "old": "1.2.3", "new": "1.2.4" }
 *     ],
 *     "skipped": [
 *       { "file": "other.json", "reason": "monotonic-guard", "current": "2.0.0", "target": "1.2.4" }
 *     ]
 *   }
 *
 * Exit codes:
 *   0 — success (at least one file bumped)
 *   1 — usage / argument error
 *   2 — config error (missing key, missing file)
 *   3 — file processing error (unsupported format, corrupt file)
 *   4 — all scoped files were monotonic no-ops (nothing to bump)
 */

const fs = require('fs');
const path = require('path');

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  var args = {
    bumpSpec: null,
    configPath: null,
    projectRoot: null,
    dryRun: false,
    help: false,
    scope: null,      // string[] | null — path prefixes
    scopeMap: null,    // { prefix: bumpType } | null
  };

  var i = 0;
  while (i < argv.length) {
    var arg = argv[i];
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
      case '--scope':
        args.scope = argv[++i].split(',').map(function (s) { return s.trim(); }).filter(function (s) { return s.length > 0; });
        break;
      case '--scope-map': {
        var raw = argv[++i];
        try {
          args.scopeMap = JSON.parse(raw);
        } catch (e) {
          process.stderr.write('version-bump: --scope-map value is not valid JSON: ' + raw + '\n');
          process.exit(1);
        }
        if (typeof args.scopeMap !== 'object' || args.scopeMap === null || Array.isArray(args.scopeMap)) {
          process.stderr.write('version-bump: --scope-map must be a JSON object mapping prefix to bump type\n');
          process.exit(1);
        }
        // Derive scope prefixes from the map keys.
        args.scope = Object.keys(args.scopeMap);
        break;
      }
      default:
        if (!arg.startsWith('--') && !args.bumpSpec) {
          args.bumpSpec = arg;
        } else {
          process.stderr.write('version-bump: unknown argument: ' + arg + '\n');
          process.exit(1);
        }
    }
    i++;
  }

  return args;
}

function printHelp() {
  var help = 'version-bump.js — project-generic version-bump orchestrator\n' +
    '\n' +
    'Usage:\n' +
    '  node version-bump.js <patch|minor|major|X.Y.Z> [options]\n' +
    '\n' +
    'Options:\n' +
    '  --config <path>         Path to project-config.yaml\n' +
    '  --project-root <path>   Project root directory\n' +
    '  --scope <prefixes>      Comma-separated path prefixes to limit the bump\n' +
    '  --scope-map <json>      JSON object mapping prefix to bump type\n' +
    '  --dry-run               Print planned changes without writing\n' +
    '  --help                  Show this help message\n' +
    '\n' +
    'Bump types:\n' +
    '  patch    Increment the patch version (1.2.3 -> 1.2.4)\n' +
    '  minor    Increment the minor version (1.2.3 -> 1.3.0)\n' +
    '  major    Increment the major version (1.2.3 -> 2.0.0)\n' +
    '  X.Y.Z    Set an explicit version\n' +
    '\n' +
    'Exit codes:\n' +
    '  0  Success (at least one file bumped)\n' +
    '  1  Usage / argument error\n' +
    '  2  Config error (missing release.version_files, missing config file)\n' +
    '  3  File processing error (unsupported format, corrupt file)\n' +
    '  4  All scoped files were monotonic no-ops\n';
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
    process.stderr.write('version-bump: config file not found: ' + configPath + '\n');
    process.exit(2);
  }

  var content = fs.readFileSync(configPath, 'utf8');
  var lines = content.split('\n');

  var inRelease = false;
  var inVersionFiles = false;
  var releaseIndent = -1;
  var vfIndent = -1;
  var files = [];

  for (var li = 0; li < lines.length; li++) {
    var line = lines[li];
    var trimmed = line.trimStart();

    // Skip empty lines and comments.
    if (trimmed === '' || trimmed.startsWith('#')) continue;

    // Measure indentation.
    var indent = line.length - trimmed.length;

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
      var inlineMatch = trimmed.match(/^version_files\s*:\s*\[([^\]]*)\]/);
      if (inlineMatch) {
        var items = inlineMatch[1].split(',').map(function (s) { return s.trim().replace(/^["']|["']$/g, ''); });
        return items.filter(function (s) { return s.length > 0; });
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
      var item = trimmed.slice(2).trim().replace(/^["']|["']$/g, '');
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

var SEMVER_RE = /^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$/;

function parseSemver(version) {
  var m = version.match(SEMVER_RE);
  if (!m) return null;
  return {
    major: parseInt(m[1], 10),
    minor: parseInt(m[2], 10),
    patch: parseInt(m[3], 10),
    prerelease: m[4] || null,
  };
}

function formatSemver(sv) {
  var s = sv.major + '.' + sv.minor + '.' + sv.patch;
  if (sv.prerelease) s += '-' + sv.prerelease;
  return s;
}

/**
 * Compare two semver version strings numerically.
 * Returns -1 if a < b, 0 if a === b, 1 if a > b.
 * Pre-release versions are not compared — only major.minor.patch.
 */
function compareSemver(a, b) {
  var sa = parseSemver(a);
  var sb = parseSemver(b);
  if (!sa || !sb) return 0; // unparseable → treat as equal (no guard)

  if (sa.major !== sb.major) return sa.major < sb.major ? -1 : 1;
  if (sa.minor !== sb.minor) return sa.minor < sb.minor ? -1 : 1;
  if (sa.patch !== sb.patch) return sa.patch < sb.patch ? -1 : 1;
  return 0;
}

function bumpVersion(current, bumpType) {
  // Explicit version: validate and return as-is.
  if (bumpType.match(SEMVER_RE)) {
    return bumpType;
  }

  var sv = parseSemver(current);
  if (!sv) {
    process.stderr.write('version-bump: cannot parse current version \'' + current + '\' as semver\n');
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
      process.stderr.write('version-bump: unknown bump type \'' + bumpType + '\'. Expected: patch, minor, major, or X.Y.Z\n');
      process.exit(1);
  }

  return formatSemver(sv);
}

// ---------------------------------------------------------------------------
// Scope matching
// ---------------------------------------------------------------------------

/**
 * Normalize a scope prefix to ensure directory-boundary-safe matching.
 * A prefix "packages/front" must NOT match "packages/frontend/file.json".
 * We ensure the prefix ends with "/" so startsWith is boundary-safe.
 */
function normalizePrefix(prefix) {
  if (prefix.endsWith('/')) return prefix;
  return prefix + '/';
}

/**
 * Check whether a relative file path matches any of the scope prefixes.
 * Returns the matching prefix, or null if none match.
 */
function matchScope(relativePath, scopePrefixes) {
  for (var i = 0; i < scopePrefixes.length; i++) {
    var normalized = normalizePrefix(scopePrefixes[i]);
    if (relativePath.startsWith(normalized)) {
      return scopePrefixes[i];
    }
  }
  return null;
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
  var content = fs.readFileSync(filePath, 'utf8');

  // Check for null bytes (binary file indicator).
  if (content.indexOf('\0') !== -1) {
    return 'binary';
  }

  // Try JSON parse.
  try {
    var parsed = JSON.parse(content);
    if (typeof parsed === 'object' && parsed !== null && 'version' in parsed) {
      return 'json';
    }
    // Valid JSON but no "version" key — treat as unsupported.
    return 'json-no-version';
  } catch (e) {
    // Not JSON — check if it looks like a plain-text version string.
    var trimmed = content.trim();
    if (trimmed.match(SEMVER_RE)) {
      return 'text';
    }
    // Does not match semver — unsupported.
    return 'unknown';
  }
}

function readVersion(filePath, format) {
  var content = fs.readFileSync(filePath, 'utf8');

  if (format === 'json') {
    var parsed = JSON.parse(content);
    return parsed.version;
  }

  if (format === 'text') {
    return content.trim();
  }

  return null;
}

function writeVersion(filePath, newVersion, format) {
  if (format === 'json') {
    var content = fs.readFileSync(filePath, 'utf8');
    var parsed = JSON.parse(content);
    parsed.version = newVersion;
    // Detect indentation from the original file to preserve formatting.
    var indentMatch = content.match(/^(\s+)"/m);
    var indent = indentMatch ? indentMatch[1].length : 2;
    // Preserve trailing newline if original had one.
    var trailingNewline = content.endsWith('\n');
    var output = JSON.stringify(parsed, null, indent);
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
// Per-component bump logic
// ---------------------------------------------------------------------------

/**
 * Compute the target version for a file, respecting scope-map overrides.
 * When a scope-map is present, each file's bump type comes from the map
 * entry whose prefix matches the file's relative path, and the bump is
 * computed from the file's own current version.
 * When only --scope + a global bumpSpec is present, the global bumpSpec
 * is applied to each file's own current version.
 */
function computeTargetVersion(fileInfo, bumpSpec, scopeMap) {
  var effectiveBump = bumpSpec;

  if (scopeMap) {
    // Find the scope-map entry whose prefix matches this file.
    var prefixes = Object.keys(scopeMap);
    for (var i = 0; i < prefixes.length; i++) {
      var normalized = normalizePrefix(prefixes[i]);
      if (fileInfo.relative.startsWith(normalized)) {
        effectiveBump = scopeMap[prefixes[i]];
        break;
      }
    }
  }

  return bumpVersion(fileInfo.oldVersion, effectiveBump);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function main() {
  var args = parseArgs(process.argv.slice(2));

  if (args.help) {
    printHelp();
    process.exit(0);
  }

  // bumpSpec is required unless --scope-map provides per-component types.
  if (!args.bumpSpec && !args.scopeMap) {
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
  var versionFiles = parseVersionFiles(args.configPath);

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
  var normalizedRoot = path.resolve(args.projectRoot);
  var resolvedFiles = versionFiles.map(function (f) {
    return {
      relative: f,
      absolute: path.resolve(args.projectRoot, f),
    };
  });

  // Path-traversal guard: every resolved path must be inside the project root.
  for (var ri = 0; ri < resolvedFiles.length; ri++) {
    var entry = resolvedFiles[ri];
    if (entry.absolute !== normalizedRoot &&
        !entry.absolute.startsWith(normalizedRoot + path.sep)) {
      process.stderr.write(
        'version-bump: path-traversal rejected — ' + entry.relative + ' resolves to ' +
        entry.absolute + ' which is outside the repository root ' + normalizedRoot + '\n'
      );
      process.exit(2);
    }
  }

  // When scope is active, filter to only matching files.
  if (args.scope) {
    resolvedFiles = resolvedFiles.filter(function (entry) {
      return matchScope(entry.relative, args.scope) !== null;
    });
  }

  // If scope filtering left no files, exit 4 (nothing to do).
  if (args.scope && resolvedFiles.length === 0) {
    process.stderr.write('version-bump: no version_files matched the given scope\n');
    process.exit(4);
  }

  // Validate all (remaining) files exist before making any changes.
  for (var vi = 0; vi < resolvedFiles.length; vi++) {
    var vEntry = resolvedFiles[vi];
    if (!fs.existsSync(vEntry.absolute)) {
      process.stderr.write(
        'version-bump: version file not found: ' + vEntry.relative + ' (resolved to ' + vEntry.absolute + ')\n'
      );
      process.exit(2);
    }
  }

  // Detect formats and read current versions.
  var fileInfos = [];
  var referenceVersion = null;

  for (var fi = 0; fi < resolvedFiles.length; fi++) {
    var fEntry = resolvedFiles[fi];
    var format = detectFormat(fEntry.absolute);

    if (format === 'binary') {
      process.stderr.write(
        'version-bump: unsupported file format (binary): ' + fEntry.relative + '\n'
      );
      process.exit(3);
    }

    if (format === 'json-no-version') {
      process.stderr.write(
        'version-bump: JSON file has no "version" key: ' + fEntry.relative + '\n'
      );
      process.exit(3);
    }

    if (format === 'unknown') {
      process.stderr.write(
        'version-bump: unsupported file format — cannot extract version: ' + fEntry.relative + '\n'
      );
      process.exit(3);
    }

    var currentVersion = readVersion(fEntry.absolute, format);
    if (!currentVersion) {
      process.stderr.write(
        'version-bump: could not read version from ' + fEntry.relative + '\n'
      );
      process.exit(3);
    }

    if (!referenceVersion) {
      referenceVersion = currentVersion;
    }

    fileInfos.push({
      relative: fEntry.relative,
      absolute: fEntry.absolute,
      format: format,
      oldVersion: currentVersion,
    });
  }

  // Compute per-file target versions.
  // When scoped: each file bumps from its own current version.
  // When unscoped (backward compat): all files share the first file's
  // reference version, matching the original lockstep behavior.
  var isScoped = args.scope !== null;

  var bumped = [];
  var skipped = [];

  for (var bi = 0; bi < fileInfos.length; bi++) {
    var info = fileInfos[bi];
    var targetVersion;

    if (isScoped) {
      // Per-component: bump from this file's own version.
      targetVersion = computeTargetVersion(info, args.bumpSpec, args.scopeMap);
    } else {
      // Lockstep (backward compat): single reference version.
      targetVersion = bumpVersion(referenceVersion, args.bumpSpec);
    }

    // Monotonic guard: refuse to write a version <= current.
    var cmp = compareSemver(targetVersion, info.oldVersion);
    if (cmp <= 0) {
      process.stderr.write(
        'version-bump: monotonic guard — skipping ' + info.relative +
        ' (current ' + info.oldVersion + ' >= target ' + targetVersion + ')\n'
      );
      skipped.push({
        file: info.relative,
        reason: 'monotonic-guard',
        current: info.oldVersion,
        target: targetVersion,
      });
      continue;
    }

    if (!args.dryRun) {
      writeVersion(info.absolute, targetVersion, info.format);
    }

    bumped.push({
      file: info.relative,
      format: info.format,
      old: info.oldVersion,
      'new': targetVersion,
    });
  }

  // Exit 4 if every file was a monotonic no-op.
  if (bumped.length === 0) {
    var noopSummary = {
      bumped: [],
      skipped: skipped,
    };
    process.stderr.write(
      'version-bump: all candidate files were monotonic no-ops — nothing to bump\n'
    );
    process.stdout.write(JSON.stringify(noopSummary) + '\n');
    process.exit(4);
  }

  // Emit machine-readable summary.
  var summary = {
    bumped: bumped,
    skipped: skipped,
  };

  // For backward compat, include top-level old_version/new_version/bump_type
  // when all files share the same target (unscoped or single-target scoped).
  if (!isScoped) {
    summary.old_version = referenceVersion;
    summary.new_version = bumped[0]['new'];
    summary.bump_type = args.bumpSpec;
  }

  if (args.dryRun) {
    summary.dry_run = true;
    process.stdout.write(JSON.stringify(summary, null, 2) + '\n');
  } else {
    process.stdout.write(JSON.stringify(summary) + '\n');
  }

  process.exit(0);
}

main();
