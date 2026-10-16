#!/usr/bin/env bats
# mod-shell-static-audit.bats -- Per-call-site static audit of hooks/index.js.
# The audit strips comments, then checks every $.process.run call, every
# $.ui.log call and every ui.render handler on its own. Seeded bad copies
# prove each rule can fail.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  INDEX_JS="$REPO_ROOT/plugins/gaia/hooks/index.js"
  SNAPSHOT_SH="$REPO_ROOT/plugins/gaia/scripts/sprint-progress-snapshot.sh"
  AUDIT="$BATS_TEST_TMPDIR/audit.cjs"
  _write_audit "$AUDIT"
}

_write_audit() {
  cat > "$1" << 'AUDIT'
'use strict';
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
const problems = [];

// Blanks comments (keeping offsets); strings and template literals are kept.
function stripComments(s) {
  let out = '';
  let i = 0;
  while (i < s.length) {
    const c = s[i], d = s[i + 1];
    if (c === '/' && d === '/') { while (i < s.length && s[i] !== '\n') { out += ' '; i++; } continue; }
    if (c === '/' && d === '*') {
      while (i < s.length && !(s[i] === '*' && s[i + 1] === '/')) { out += s[i] === '\n' ? '\n' : ' '; i++; }
      out += '  '; i += 2; continue;
    }
    if (c === '"' || c === "'" || c === '`') {
      const q = c; out += c; i++;
      while (i < s.length && s[i] !== q) { if (s[i] === '\\') { out += s[i]; i++; } out += s[i]; i++; }
      out += s[i] || ''; i++; continue;
    }
    out += c; i++;
  }
  return out;
}

// Index of the bracket closing the one opened at `open`.
function matchClose(s, open) {
  const pairs = { '(': ')', '[': ']', '{': '}' };
  const stack = [];
  for (let i = open; i < s.length; i++) {
    const c = s[i];
    if (c === '"' || c === "'" || c === '`') {
      const q = c; i++;
      while (i < s.length && s[i] !== q) { if (s[i] === '\\') i++; i++; }
      continue;
    }
    if (pairs[c]) stack.push(pairs[c]);
    else if (c === ')' || c === ']' || c === '}') {
      if (stack.pop() !== c) return -1;
      if (stack.length === 0) return i;
    }
  }
  return -1;
}

// Splits an argument list on top-level commas.
function splitArgs(s) {
  const args = [];
  let depth = 0, cur = '';
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === '"' || c === "'" || c === '`') {
      const q = c; cur += c; i++;
      while (i < s.length && s[i] !== q) { if (s[i] === '\\') { cur += s[i]; i++; } cur += s[i]; i++; }
      cur += s[i] || ''; continue;
    }
    if ('([{'.includes(c)) depth++;
    if (')]}'.includes(c)) depth--;
    if (c === ',' && depth === 0) { args.push(cur.trim()); cur = ''; continue; }
    cur += c;
  }
  if (cur.trim() !== '') args.push(cur.trim());
  return args;
}

const norm = (s) => s.replace(/\s+/g, ' ').replace(/"/g, "'").trim();

// Start of the innermost block enclosing position `pos`.
function enclosingBlock(s, pos) {
  let depth = 0;
  for (let i = pos - 1; i >= 0; i--) {
    if (s[i] === '}') depth++;
    else if (s[i] === '{') { if (depth === 0) return i; depth--; }
  }
  return -1;
}

const code = stripComments(src);
const SCRIPT = "joinPath($.plugin.root, 'scripts', 'sprint-progress-snapshot.sh')";

// -- every $.process.run call --
let runSites = 0;
const runRe = /process\.run\s*\(/g;
let m;
while ((m = runRe.exec(code)) !== null) {
  runSites++;
  const open = m.index + m[0].length - 1;
  const close = matchClose(code, open);
  if (close < 0) { problems.push('process.run: unbalanced call'); continue; }
  const inner = code.slice(open + 1, close);
  const line = code.slice(0, m.index).split('\n').length;
  const where = 'process.run at line ' + line + ': ';
  if (inner.includes('`')) problems.push(where + 'template literal in the call');
  const args = splitArgs(inner);
  if (args.length !== 2) problems.push(where + 'expected 2 arguments, got ' + args.length);
  const argv = args[0] || '';
  if (!argv.startsWith('[') || matchClose(argv, 0) !== argv.length - 1) {
    problems.push(where + 'argv is not an array literal');
  } else {
    const elems = splitArgs(argv.slice(1, -1));
    if (elems.length !== 1) problems.push(where + 'argv has ' + elems.length + ' elements, expected 1');
    if (norm(elems[0] || '') !== SCRIPT) problems.push(where + 'argv[0] is not the plugin-root script path: ' + norm(elems[0] || ''));
  }
  const opts = norm(args[1] || '');
  if (!/^\{.*\}$/.test(opts)) problems.push(where + 'options are not an object literal');
  if (!/\btimeoutMs: \d+/.test(opts)) problems.push(where + 'no numeric timeoutMs');
  if (!/\bcwd: /.test(opts)) problems.push(where + 'no cwd');
  if (!/\benv: \{ PROJECT_ROOT: [A-Za-z_$][\w$.]* \}/.test(opts)) problems.push(where + 'env is not exactly { PROJECT_ROOT }');
  // The call must sit directly inside a try block that has a catch.
  const blk = enclosingBlock(code, m.index);
  const blkEnd = blk < 0 ? -1 : matchClose(code, blk);
  if (blk < 0 || !/\btry\s*$/.test(code.slice(0, blk)) || !/^\s*catch\b/.test(code.slice(blkEnd + 1))) {
    problems.push(where + 'not wrapped in try/catch');
  } else {
    // The awaited result must be checked with exitCode !== 0 before the
    // enclosing function ends.
    const assigned = /([A-Za-z_$][\w$]*)\s*=\s*await\s+\$\.\s*$/.exec(code.slice(0, m.index)) ||
      /([A-Za-z_$][\w$]*)\s*=\s*await\s+\$\.$/.exec(code.slice(0, m.index));
    const fnEnd = code.indexOf('\n}', blkEnd);
    const rest = code.slice(blkEnd, fnEnd < 0 ? code.length : fnEnd);
    if (!assigned) problems.push(where + 'result is not assigned');
    else {
      const v = assigned[1].replace(/[$]/g, '\\$');
      if (!new RegExp('\\bif\\s*\\(\\s*' + v + '\\.exitCode\\s*!==\\s*0\\s*\\)').test(rest)) {
        problems.push(where + 'no "' + assigned[1] + '.exitCode !== 0" check after the call');
      }
    }
  }
}
if (runSites === 0) problems.push('no process.run call found');

// -- every $.ui.log call --
let logSites = 0;
const logRe = /\.ui\.log\s*\(/g;
while ((m = logRe.exec(code)) !== null) {
  logSites++;
  const open = m.index + m[0].length - 1;
  const close = matchClose(code, open);
  const args = splitArgs(code.slice(open + 1, close));
  const line = code.slice(0, m.index).split('\n').length;
  if (args.length !== 2 || norm(args[1]) !== "{ to: 'debug' }") {
    problems.push('ui.log at line ' + line + ': second argument is not { to: \'debug\' }');
  }
}
if (logSites === 0) problems.push('no ui.log call found');

// -- every ui.render handler: in-memory only --
let renderSites = 0;
const renderRe = /\bon\s*\(\s*'ui\.render'/g;
const FORBIDDEN = ['$.fs', '$.process', '$.store', '$.http', 'sanitize', 'refresh(', 'readCache(', 'runSnapshot'];
while ((m = renderRe.exec(code)) !== null) {
  renderSites++;
  const open = code.indexOf('(', m.index);
  const close = matchClose(code, open);
  const body = code.slice(open, close);
  const line = code.slice(0, m.index).split('\n').length;
  for (const f of FORBIDDEN) {
    if (body.includes(f)) problems.push('ui.render at line ' + line + ': uses ' + f);
  }
}
if (renderSites === 0) problems.push('no ui.render handler found');

// -- joinPath: literal segments only --
const joinRe = /\bjoinPath\s*\(/g;
while ((m = joinRe.exec(code)) !== null) {
  const open = m.index + m[0].length - 1;
  const close = matchClose(code, open);
  const inner = code.slice(open + 1, close);
  if (/`|\+/.test(inner)) problems.push('joinPath at line ' + code.slice(0, m.index).split('\n').length + ': concatenation or template literal');
}

if (problems.length) {
  for (const p of problems) process.stdout.write('AUDIT FAIL: ' + p + '\n');
  process.exit(1);
}
process.stdout.write('AUDIT OK process.run sites: ' + runSites + ', ui.log sites: ' + logSites + ', ui.render handlers: ' + renderSites + '\n');
AUDIT
}

# Copies index.js with one exact text replacement ($1 -> $2); fails when the
# text to replace is not found exactly once.
_seed() {
  SEEDED="$BATS_TEST_TMPDIR/seeded.js"
  run node -e '
const fs = require("fs");
const [src, out, from, to] = process.argv.slice(1);
const s = fs.readFileSync(src, "utf8");
const n = s.split(from).length - 1;
if (n !== 1) { console.log("seed text found " + n + " times: " + from); process.exit(1); }
fs.writeFileSync(out, s.replace(from, to));
' "$INDEX_JS" "$SEEDED" "$1" "$2"
  echo "$output"
  [ "$status" -eq 0 ]
}

# Runs the audit on the seeded copy and expects a failure whose text
# contains $1.
_expect_audit_failure() {
  run node "$AUDIT" "$SEEDED"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"AUDIT FAIL: $1"* ]] || false
}

SCRIPT_ARG="joinPath(\$.plugin.root, 'scripts', 'sprint-progress-snapshot.sh')"

@test "static audit passes on the hooks module, site by site" {
  run node "$AUDIT" "$INDEX_JS"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == "AUDIT OK process.run sites: 1, ui.log sites: "* ]] || false
  [[ "$output" == *"ui.render handlers: 2"* ]] || false
}

@test "audit rejects a template literal in the process.run call" {
  _seed "[$SCRIPT_ARG]" "[\`\${\$.plugin.root}/scripts/sprint-progress-snapshot.sh\`]"
  _expect_audit_failure "process.run at line"
  [[ "$output" == *"template literal in the call"* ]] || false
}

@test "audit rejects an extra argv element" {
  _seed "[$SCRIPT_ARG]" "[$SCRIPT_ARG, root]"
  _expect_audit_failure "process.run at line"
  [[ "$output" == *"argv has 2 elements, expected 1"* ]] || false
}

@test "audit rejects a shell wrapper around the script" {
  _seed "[$SCRIPT_ARG]" "['sh', '-c', $SCRIPT_ARG]"
  _expect_audit_failure "process.run at line"
  [[ "$output" == *"argv has 3 elements, expected 1"* ]] || false
}

@test "audit rejects a script path resolved from the project root" {
  _seed "[$SCRIPT_ARG]" "[joinPath(root, 'scripts', 'sprint-progress-snapshot.sh')]"
  _expect_audit_failure "process.run at line"
  [[ "$output" == *"argv[0] is not the plugin-root script path"* ]] || false
}

@test "audit rejects a timeoutMs that only appears in a comment" {
  _seed ", timeoutMs: 30000" " /* timeoutMs: 30000 */"
  _expect_audit_failure "process.run at line"
  [[ "$output" == *"no numeric timeoutMs"* ]] || false
}

@test "audit rejects a process.run call outside try/catch" {
  _seed "  var result
  try {
    result = await \$.process.run(" "  var result
  {
    result = await \$.process.run("
  _expect_audit_failure "process.run at line"
  [[ "$output" == *"not wrapped in try/catch"* ]] || false
}

@test "audit rejects an inverted exit code check" {
  _seed "if (result.exitCode !== 0)" "if (result.exitCode === 0)"
  _expect_audit_failure "process.run at line"
  [[ "$output" == *'no "result.exitCode !== 0" check after the call'* ]] || false
}

@test "audit rejects an exit code check that only survives in a comment" {
  _seed "if (result.exitCode !== 0) {" "if (false) { // result.exitCode !== 0"
  _expect_audit_failure "process.run at line"
  [[ "$output" == *'no "result.exitCode !== 0" check after the call'* ]] || false
}

@test "audit rejects a ui.log call that does not go to debug" {
  _seed "\$.ui.log(msg, { to: 'debug' })" "\$.ui.log(msg, { to: 'user' })"
  _expect_audit_failure "ui.log at line"
}

@test "audit rejects file reads in a render handler" {
  _seed "    // Keeps what other mods draw in the band." "    await \$.fs.read('x')"
  _expect_audit_failure "ui.render at line"
  [[ "$output" == *'uses $.fs'* ]] || false
}

@test "audit rejects sanitising in a render handler" {
  _seed "    // Keeps what other mods draw in the band." "    sanitizeCache(cachedData)"
  _expect_audit_failure "ui.render at line"
  [[ "$output" == *"uses sanitize"* ]] || false
}

@test "snapshot script has git index mode 100755" {
  [ -f "$SNAPSHOT_SH" ] || false
  cd "$REPO_ROOT"
  run git ls-files -s "$SNAPSHOT_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == 100755* ]] || false
}
