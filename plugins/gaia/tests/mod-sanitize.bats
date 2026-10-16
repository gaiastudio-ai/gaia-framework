#!/usr/bin/env bats
# mod-sanitize.bats -- Sanitize function test vectors via node ESM.
# One test per mandatory vector, plus edge cases.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SANITIZE="$REPO_ROOT/plugins/gaia/hooks/sanitize.js"
}

# Helper: run a node ESM snippet that imports sanitize and all constants.
run_sanitize() {
  run node --input-type=module -e "
import { sanitize, TITLE_MAX, SLUG_MAX, MESSAGE_MAX, COMMAND_MAX,
  DESCRIPTION_MAX, DETAIL_MAX, GOAL_MAX, TASK_TEXT_MAX,
  GATE_NAME_MAX, BLOCKED_BY_MAX, DRIFT_DETAIL_MAX, DEFAULT_MAX } from '$SANITIZE';
$1
"
}

# -- one test per mandatory vector --

@test "strip screen-clear CSI ESC[2J" {
  run_sanitize '
const out = sanitize("before\x1b[2Jafter", 200);
if (out !== "beforeafter") { process.stderr.write("got: " + JSON.stringify(out)); process.exit(1); }
'
  [ "$status" -eq 0 ]
}

@test "strip title-set OSC ESC]0;title BEL" {
  run_sanitize '
const out = sanitize("before\x1b]0;title\x07after", 200);
if (out !== "beforeafter") { process.stderr.write("got: " + JSON.stringify(out)); process.exit(1); }
'
  [ "$status" -eq 0 ]
}

@test "strip backspace 0x08" {
  run_sanitize '
const out = sanitize("ab\x08c", 200);
if (out !== "abc") { process.stderr.write("got: " + JSON.stringify(out)); process.exit(1); }
'
  [ "$status" -eq 0 ]
}

@test "strip C1 CSI U+009B followed by 2J" {
  run_sanitize '
const out = sanitize("before\u009b2Jafter", 200);
if (out !== "beforeafter") { process.stderr.write("got: " + JSON.stringify(out)); process.exit(1); }
'
  [ "$status" -eq 0 ]
}

@test "strip C1 OSC U+009D followed by title BEL" {
  run_sanitize '
const out = sanitize("before\u009dtitle\x07after", 200);
if (out !== "beforeafter") { process.stderr.write("got: " + JSON.stringify(out)); process.exit(1); }
'
  [ "$status" -eq 0 ]
}

@test "strip lone 0x80 C1 control char" {
  run_sanitize '
const out = sanitize("ab\u0080cd", 200);
if (out !== "abcd") { process.stderr.write("got: " + JSON.stringify(out)); process.exit(1); }
'
  [ "$status" -eq 0 ]
}

@test "strip private-mode CSI ESC[?47h" {
  run_sanitize '
const out = sanitize("before\x1b[?47hafter", 200);
if (out !== "beforeafter") { process.stderr.write("got: " + JSON.stringify(out)); process.exit(1); }
'
  [ "$status" -eq 0 ]
}

@test "strip color ESC[31mRED ESC[0m to RED" {
  run_sanitize '
const out = sanitize("\x1b[31mRED\x1b[0m", 200);
if (out !== "RED") { process.stderr.write("got: " + JSON.stringify(out)); process.exit(1); }
'
  [ "$status" -eq 0 ]
}

@test "strip bold color ESC[31;1mRED ESC[0m trail to RED trail" {
  run_sanitize '
const out = sanitize("\x1b[31;1mRED\x1b[0m trail", 200);
if (out !== "RED trail") { process.stderr.write("got: " + JSON.stringify(out)); process.exit(1); }
'
  [ "$status" -eq 0 ]
}

@test "strip incomplete trailing CSI ab ESC[31 to ab" {
  run_sanitize '
const out = sanitize("ab\x1b[31", 200);
if (out !== "ab") { process.stderr.write("got: " + JSON.stringify(out)); process.exit(1); }
'
  [ "$status" -eq 0 ]
}

@test "strip OSC hyperlink to plain text Click" {
  run_sanitize '
const input = "\x1b]8;;https://example.com\x1b\\Click\x1b]8;;\x1b\\";
const out = sanitize(input, 200);
if (out !== "Click") { process.stderr.write("got: " + JSON.stringify(out)); process.exit(1); }
'
  [ "$status" -eq 0 ]
}

@test "truncate 200-char title to 79 chars plus ellipsis total 80" {
  run_sanitize '
const long = "A".repeat(200);
const out = sanitize(long, 80);
if (out.length !== 80) { process.stderr.write("length: " + out.length); process.exit(1); }
if (out[79] !== "…") { process.stderr.write("last char: " + JSON.stringify(out[79])); process.exit(1); }
if (out.slice(0, 79) !== "A".repeat(79)) { process.stderr.write("prefix wrong"); process.exit(1); }
'
  [ "$status" -eq 0 ]
}

# -- Additional edge-case vectors --

@test "strip OSC terminated by ESC backslash" {
  run_sanitize '
const out = sanitize("\x1b]2;window title\x1b\\rest", 200);
if (out !== "rest") { process.stderr.write("got: " + JSON.stringify(out)); process.exit(1); }
'
  [ "$status" -eq 0 ]
}

@test "strip U+FFFD replacement character" {
  run_sanitize '
const out = sanitize("good�bad", 200);
if (out !== "goodbad") { process.stderr.write("got: " + JSON.stringify(out)); process.exit(1); }
'
  [ "$status" -eq 0 ]
}

@test "strip lone surrogate" {
  run_sanitize '
const out = sanitize("x\uD800y", 200);
if (out !== "xy") { process.stderr.write("got: " + JSON.stringify(out)); process.exit(1); }
'
  [ "$status" -eq 0 ]
}

@test "strip DEL character 0x7F" {
  run_sanitize '
const out = sanitize("ab\x7Fcd", 200);
if (out !== "abcd") { process.stderr.write("got: " + JSON.stringify(out)); process.exit(1); }
'
  [ "$status" -eq 0 ]
}

@test "newline preserved" {
  run_sanitize '
const out = sanitize("line1\nline2", 200);
if (out !== "line1\nline2") { process.stderr.write("got: " + JSON.stringify(out)); process.exit(1); }
'
  [ "$status" -eq 0 ]
}

@test "null and undefined coerced to empty string" {
  run_sanitize '
if (sanitize(null, 200) !== "") process.exit(1);
if (sanitize(undefined, 200) !== "") process.exit(1);
'
  [ "$status" -eq 0 ]
}

# -- assert all 11 per-field constants with exact values --

@test "per-field constants have correct values" {
  run_sanitize '
const expected = {
  TITLE_MAX: 80, SLUG_MAX: 60, MESSAGE_MAX: 200, COMMAND_MAX: 120,
  DESCRIPTION_MAX: 120, DETAIL_MAX: 200, GOAL_MAX: 200,
  TASK_TEXT_MAX: 200, GATE_NAME_MAX: 60, BLOCKED_BY_MAX: 80,
  DRIFT_DETAIL_MAX: 200
};
const actual = {
  TITLE_MAX, SLUG_MAX, MESSAGE_MAX, COMMAND_MAX,
  DESCRIPTION_MAX, DETAIL_MAX, GOAL_MAX,
  TASK_TEXT_MAX, GATE_NAME_MAX, BLOCKED_BY_MAX,
  DRIFT_DETAIL_MAX
};
for (const [k, v] of Object.entries(expected)) {
  if (actual[k] !== v) {
    process.stderr.write(k + ": expected " + v + " got " + actual[k]);
    process.exit(1);
  }
}
'
  [ "$status" -eq 0 ]
}

@test "nested CSI with params and incomplete trailing CSI" {
  run_sanitize '
const input = "\x1b[38;2;255;0;0mred\x1b[0m then \x1b[31";
const out = sanitize(input, 200);
if (out !== "red then ") { process.stderr.write("got: " + JSON.stringify(out)); process.exit(1); }
'
  [ "$status" -eq 0 ]
}

@test "strip NUL 0x00" {
  run_sanitize '
const out = sanitize("a\x00b", 200);
if (out !== "ab") { process.stderr.write("got: " + JSON.stringify(out)); process.exit(1); }
'
  [ "$status" -eq 0 ]
}

@test "bare ESC is stripped: reset, save cursor, DCS, APC, PM and SOS leave no ESC" {
  run_sanitize '
const cases = [
  ["\x1bcX", "cX"],
  ["\x1b7X\x1b8", "7X8"],
  ["\x1bPq#0;1\x1b\\X", "Pq#0;1\\X"],
  ["\x1b_payload\x1b\\X", "_payload\\X"],
  ["\x1b^pm\x1b\\X", "^pm\\X"],
  ["\x1bXsos\x1b\\Y", "Xsos\\Y"]
];
for (const [input, want] of cases) {
  const out = sanitize(input, 200);
  if (out.includes("\x1b")) { process.stderr.write("ESC left in " + JSON.stringify(out)); process.exit(1); }
  if (out !== want) { process.stderr.write(JSON.stringify(input) + " got " + JSON.stringify(out)); process.exit(1); }
}
'
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "OSC hyperlink terminated by BEL becomes plain text Click" {
  run_sanitize '
const out = sanitize("\x1b]8;;https://evil.com\x07Click\x1b]8;;\x07", 200);
if (out !== "Click") { process.stderr.write("got: " + JSON.stringify(out)); process.exit(1); }
'
  [ "$status" -eq 0 ]
}

@test "C1 OSC terminated by C1 string terminator keeps the text after it" {
  run_sanitize '
const out = sanitize("\u009d0;title\u009cVISIBLE", 200);
if (out !== "VISIBLE") { process.stderr.write("got: " + JSON.stringify(out)); process.exit(1); }
'
  [ "$status" -eq 0 ]
}

@test "valid surrogate pairs are kept and lone ones of either half are stripped" {
  run_sanitize '
const checks = [
  ["\u{1F600}ok", "\u{1F600}ok"],
  ["日本\u{1F680}", "日本\u{1F680}"],
  ["x\ud800y", "xy"],
  ["x\udc00y", "xy"],
  ["\udc00😀\ud800", "😀"]
];
for (const [input, want] of checks) {
  const out = sanitize(input, 80);
  if (out !== want) { process.stderr.write(JSON.stringify(input) + " got " + JSON.stringify(out)); process.exit(1); }
}
'
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "truncation never splits a surrogate pair" {
  run_sanitize '
const input = "A".repeat(78) + "\u{1F600}\u{1F600}";
const out = sanitize(input, 80);
if (out !== "A".repeat(78) + "…") { process.stderr.write("got: " + JSON.stringify(out)); process.exit(1); }
const out2 = sanitize("A".repeat(77) + "\u{1F600}\u{1F600}", 80);
if (out2 !== "A".repeat(77) + "\u{1F600}…") { process.stderr.write("got2: " + JSON.stringify(out2)); process.exit(1); }
if (/[\ud800-\udbff](?![\udc00-\udfff])/.test(out) || /[\ud800-\udbff](?![\udc00-\udfff])/.test(out2)) { process.stderr.write("lone surrogate"); process.exit(1); }
'
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "maxLen of zero, negative, NaN or undefined never gives longer output" {
  run_sanitize '
const long = "x".repeat(500);
const want = { "0": "", "-1": "", "-5": "", "1": "…", "2": "x…" };
for (const [m, w] of Object.entries(want)) {
  const out = sanitize(long, Number(m));
  if (out !== w) { process.stderr.write("maxLen " + m + " got " + JSON.stringify(out)); process.exit(1); }
}
for (const m of [NaN, undefined, Infinity, "80"]) {
  const out = sanitize(long, m);
  if (out.length !== 200) { process.stderr.write("maxLen " + String(m) + " length " + out.length); process.exit(1); }
}
'
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "bidi controls and zero-width characters are stripped, joiners kept" {
  run_sanitize '
const out = sanitize("a‮b⁦c⁩d​e⁠f﻿g‎h‏i؜j", 200);
if (out !== "abcdefghij") { process.stderr.write("got: " + JSON.stringify(out)); process.exit(1); }
const fam = "\u{1F468}‍\u{1F469}‍\u{1F467}";
if (sanitize(fam, 200) !== fam) { process.stderr.write("joiner sequence broken"); process.exit(1); }
'
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "hostile 100k-character fields are sanitised quickly" {
  run_sanitize '
const shapes = {
  osc: "\x1b]".repeat(50000),
  c1osc: "\u009d".repeat(100000),
  csi: "\x1b[" + " ".repeat(100000),
  csiParams: "\x1b[        ".repeat(10000),
  mixed: "\x1b]\x1bx".repeat(33000)
};
const t0 = process.hrtime.bigint();
for (const [name, s] of Object.entries(shapes)) {
  for (const m of [200, Infinity]) {
    const out = sanitize(s, m);
    if (/[\x00-\x09\x0b-\x1f\x7f-\x9f]/.test(out)) { process.stderr.write(name + " left a control"); process.exit(1); }
  }
}
const ms = Number(process.hrtime.bigint() - t0) / 1e6;
console.log("total ms: " + ms.toFixed(1));
if (ms > 1000) { process.stderr.write("too slow: " + ms + " ms"); process.exit(1); }
'
  echo "$output"
  [ "$status" -eq 0 ]
}

# -- sanitizeCache integration tests --

# Helper: run a node ESM snippet that imports sanitizeCache.
run_sanitize_cache() {
  run node --input-type=module -e "
import { sanitize, sanitizeCache, TITLE_MAX, SLUG_MAX, MESSAGE_MAX, COMMAND_MAX,
  DESCRIPTION_MAX, DETAIL_MAX, GOAL_MAX, TASK_TEXT_MAX,
  GATE_NAME_MAX, BLOCKED_BY_MAX, DRIFT_DETAIL_MAX, DEFAULT_MAX } from '$SANITIZE';
$1
"
}

@test "sanitizeCache cleans all dynamic text fields" {
  run_sanitize_cache '
const esc = "\x1b[2J";
const long = "x".repeat(500);
const data = {
  sprint: { id: esc + "sid", goal: esc + long, status: esc + "active",
            capacity_utilization: esc + "80%", epic_focus: esc + "Focus" },
  stories: [{
    key: esc + "E900-S1", title: esc + long, slug: esc + "slug-one",
    blocked_by: esc + long,
    tasks: { items: [{ text: esc + long, done: false }] },
    gates: { rows: [{ name: esc + long, status: "PASSED" }] }
  }],
  drift: [{ detail: esc + long }],
  action_needed: [{ message: esc + long, command: esc + "/gaia-sprint-close" }]
};
const out = sanitizeCache(data);

// Verify no field contains ESC
function checkNoEsc(val, path) {
  if (typeof val === "string" && val.includes("\x1b")) {
    process.stderr.write("ESC found at " + path + ": " + JSON.stringify(val));
    process.exit(1);
  }
}
checkNoEsc(out.sprint.id, "sprint.id");
checkNoEsc(out.sprint.goal, "sprint.goal");
checkNoEsc(out.sprint.status, "sprint.status");
checkNoEsc(out.sprint.capacity_utilization, "sprint.capacity_utilization");
checkNoEsc(out.sprint.epic_focus, "sprint.epic_focus");
checkNoEsc(out.stories[0].key, "stories[0].key");
checkNoEsc(out.stories[0].title, "stories[0].title");
checkNoEsc(out.stories[0].slug, "stories[0].slug");
checkNoEsc(out.stories[0].blocked_by, "stories[0].blocked_by");
checkNoEsc(out.stories[0].tasks.items[0].text, "stories[0].tasks.items[0].text");
checkNoEsc(out.stories[0].gates.rows[0].name, "stories[0].gates.rows[0].name");
checkNoEsc(out.drift[0].detail, "drift[0].detail");
checkNoEsc(out.action_needed[0].message, "action_needed[0].message");
checkNoEsc(out.action_needed[0].command, "action_needed[0].command");

// Verify length limits
if (out.stories[0].title.length > TITLE_MAX) { process.stderr.write("title too long: " + out.stories[0].title.length); process.exit(1); }
if (out.stories[0].slug.length > SLUG_MAX) { process.stderr.write("slug too long: " + out.stories[0].slug.length); process.exit(1); }
if (out.stories[0].blocked_by.length > BLOCKED_BY_MAX) { process.stderr.write("blocked_by too long"); process.exit(1); }
if (out.stories[0].tasks.items[0].text.length > TASK_TEXT_MAX) { process.stderr.write("task_text too long"); process.exit(1); }
if (out.stories[0].gates.rows[0].name.length > GATE_NAME_MAX) { process.stderr.write("gate_name too long"); process.exit(1); }
if (out.sprint.goal.length > GOAL_MAX) { process.stderr.write("goal too long"); process.exit(1); }
if (out.action_needed[0].message.length > MESSAGE_MAX) { process.stderr.write("message too long"); process.exit(1); }
if (out.action_needed[0].command.length > COMMAND_MAX) { process.stderr.write("command too long"); process.exit(1); }
if (out.drift[0].detail.length > DRIFT_DETAIL_MAX) { process.stderr.write("drift_detail too long"); process.exit(1); }
'
  [ "$status" -eq 0 ]
}

@test "sanitizeCache handles C1 introducers U+009B and U+009D" {
  run_sanitize_cache '
const data = {
  sprint: { id: "s1", goal: "goal\u009b2Jhidden", status: "active" },
  stories: [{ key: "E900-S1", title: "title\u009dtest\x07hidden", slug: "s",
              tasks: { items: [] }, gates: { rows: [] } }],
  drift: [], action_needed: []
};
sanitizeCache(data);
if (data.sprint.goal !== "goalhidden") { process.stderr.write("goal: " + JSON.stringify(data.sprint.goal)); process.exit(1); }
if (data.stories[0].title !== "titlehidden") { process.stderr.write("title: " + JSON.stringify(data.stories[0].title)); process.exit(1); }
'
  [ "$status" -eq 0 ]
}

@test "sanitizeCache sanitises every string, not only a fixed field list" {
  run_sanitize_cache '
const c1 = "\u009b31m", bidi = "‮";
const data = {
  sprint: { id: "s1", status: c1 + "active", start_date: bidi + "2026-10-01" },
  stories: [{ key: "E900-S1", status: c1 + "review", risk_level: "high" + bidi,
    gates: { rows: [{ name: "val", status: "PASSED" + c1 }] },
    tasks: { items: [{ text: "t\u0085" }] } }],
  drift: [{ story_key: "E900-S1" + bidi, type: "status" + c1 + "_mismatch", detail: "d" }],
  phases: [{ stories: ["E900-S1" + c1] }],
  user_aliases: ["me⁦"],
  by_status: { ["in" + bidi + "-progress"]: { count: 1 } }
};
sanitizeCache(data);
let visited = 0;
(function walk(v, path) {
  if (typeof v === "string") {
    visited++;
    if (/[\x00-\x09\x0b-\x1f\x7f-\x9f‪-‮⁦-⁩]/.test(v)) { process.stderr.write("dirty " + path + "=" + JSON.stringify(v)); process.exit(1); }
    return;
  }
  if (v && typeof v === "object") for (const k of Object.keys(v)) {
    if (/[\x00-\x1f\x7f-\x9f‪-‮⁦-⁩]/.test(k)) { process.stderr.write("dirty key " + JSON.stringify(k)); process.exit(1); }
    walk(v[k], path + "." + k);
  }
})(data, "$");
if (visited !== 14) { process.stderr.write("visited " + visited); process.exit(1); }
const want = [[data.stories[0].status, "review"], [data.stories[0].risk_level, "high"], [data.stories[0].gates.rows[0].status, "PASSED"], [data.drift[0].type, "status_mismatch"], [data.sprint.status, "active"]];
for (const [got, w] of want) if (got !== w) { process.stderr.write("got " + JSON.stringify(got) + " want " + w); process.exit(1); }
if (!data.by_status["in-progress"]) { process.stderr.write("key not cleaned"); process.exit(1); }
'
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "sanitizeCache keeps per-field limits and gives other strings the default" {
  run_sanitize_cache '
const long = "x".repeat(500);
const data = { sprint: { goal: long, other: long }, stories: [{ title: long, slug: long, status: long, risk_level: long }],
  action_needed: [{ message: long, command: long }], drift: [{ detail: long, type: long }] };
sanitizeCache(data);
const want = [
  [data.sprint.goal, GOAL_MAX], [data.sprint.other, DEFAULT_MAX], [data.stories[0].title, TITLE_MAX],
  [data.stories[0].slug, SLUG_MAX], [data.stories[0].status, SLUG_MAX], [data.stories[0].risk_level, DEFAULT_MAX],
  [data.action_needed[0].message, MESSAGE_MAX], [data.action_needed[0].command, COMMAND_MAX],
  [data.drift[0].detail, DRIFT_DETAIL_MAX], [data.drift[0].type, DEFAULT_MAX]
];
for (const [v, n] of want) if (v.length !== n) { process.stderr.write("length " + v.length + " want " + n); process.exit(1); }
'
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "sanitizeCache does not let a __proto__ key change the prototype and caps depth" {
  run_sanitize_cache '
const data = JSON.parse("{\"__proto__\":{\"polluted\":1},\"a\":1}");
sanitizeCache(data);
if (Object.getPrototypeOf(data) !== Object.prototype) { process.stderr.write("prototype changed"); process.exit(1); }
if (({}).polluted !== undefined || data.polluted !== undefined) { process.stderr.write("polluted"); process.exit(1); }
let deep = "\x1b[2Jbottom";
for (let i = 0; i < 100; i++) deep = [deep];
const d = { deep };
sanitizeCache(d);
if (JSON.stringify(d).includes("\\u001b")) { process.stderr.write("deep escape kept"); process.exit(1); }
'
  echo "$output"
  [ "$status" -eq 0 ]
}

# Builds a fixture project whose sprint yaml and story file carry C1 and
# bidi characters (which the snapshot script does not strip) in fields the
# script copies into the cache, then runs the real script on it.
_dirty_fixture() {
  FIXTURE="$BATS_TEST_TMPDIR/sanitize-fixture"
  local story="$FIXTURE/.gaia/artifacts/implementation-artifacts/epic-e900/E900-S1-dirty-story"
  mkdir -p "$FIXTURE/.gaia/config" "$FIXTURE/.gaia/state" "$story"
  cat > "$FIXTURE/.gaia/config/project-config.yaml" << 'YAML'
project_name: sanitize-fixture
stacks:
  - name: shell
    path: "."
YAML
  local CSI1 OSC1 ST1 RLO LONG
  CSI1="$(printf '\302\233')"
  OSC1="$(printf '\302\235')"
  ST1="$(printf '\302\234')"
  RLO="$(printf '\342\200\256')"
  LONG="$(printf '%0.sx' $(seq 1 250))"
  cat > "$FIXTURE/.gaia/state/sprint-status.yaml" << YAML
sprint_id: "sprint-dirty-1"
status: active
start_date: "2026-10-01"
end_date: "2026-10-14"
total_points: 5
goals:
  - "${CSI1}2JDirty goal${RLO} text${LONG}"
stories:
  - key: "E900-S1"
    title: "Dirty title"
    status: "review"
    points: 5
    phase: 1
    risk_level: "high${RLO}"
    blocked_by: "${CSI1}31mBlocked${LONG}"
YAML
  cat > "$story/story.md" << STORY
---
id: E900-S1
title: "${CSI1}31mDirty title${RLO}${LONG}"
status: in-progress
points: 5
phase: 1
epic_id: E900
priority: medium
created_at: "2026-10-01"
---
# Dirty story

## Tasks / Subtasks

- [ ] ${OSC1}0;x${ST1}Dirty task${LONG}

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED${RLO} | - |
STORY
  run env PROJECT_ROOT="$FIXTURE" bash "$REPO_ROOT/plugins/gaia/scripts/sprint-progress-snapshot.sh"
  echo "snapshot: status=$status output=$output"
  [ "$status" -eq 0 ]
  CACHE_FILE="$FIXTURE/.gaia/state/.sprint-progress-cache.json"
  [ -f "$CACHE_FILE" ] || false
}

# Checks a cache file with the sanitize module at $1: the raw cache must
# carry dirty strings, and after sanitizeCache none may remain; the expected
# paths must all be visited.
_check_real_cache() {
  run node --input-type=module -e "
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const { sanitizeCache, TITLE_MAX, GOAL_MAX, BLOCKED_BY_MAX, TASK_TEXT_MAX, GATE_NAME_MAX } = await import(pathToFileURL(process.argv[1]).href);
const raw = readFileSync(process.argv[2], 'utf8');
const DIRTY = /[\x00-\x09\x0b-\x1f\x7f-\x9f‪-‮⁦-⁩]/;
const before = JSON.parse(raw);
let dirtyBefore = 0;
(function walk(v) { if (typeof v === 'string') { if (DIRTY.test(v)) dirtyBefore++; } else if (v && typeof v === 'object') for (const k of Object.keys(v)) walk(v[k]); })(before);
if (dirtyBefore < 5) { process.stderr.write('fixture too clean: ' + dirtyBefore); process.exit(1); }
const data = sanitizeCache(JSON.parse(raw));
let visited = 0;
const bad = [];
(function walk(v, path) {
  if (typeof v === 'string') { visited++; if (DIRTY.test(v)) bad.push(path); return; }
  if (v && typeof v === 'object') for (const k of Object.keys(v)) walk(v[k], path + '.' + k);
})(data, '\$');
if (bad.length) { process.stderr.write('dirty after sanitizeCache: ' + bad.join(', ')); process.exit(1); }
const s = data.stories[0];
const checks = [
  [data.sprint.goal, GOAL_MAX], [s.title, TITLE_MAX], [s.blocked_by, BLOCKED_BY_MAX],
  [s.tasks.items[0].text, TASK_TEXT_MAX], [s.gates.rows[0].name, GATE_NAME_MAX]
];
for (const [v, n] of checks) {
  if (typeof v !== 'string' || v.length === 0 || v.length > n) { process.stderr.write('field ' + JSON.stringify(v) + ' limit ' + n); process.exit(1); }
}
if (s.risk_level !== 'high') { process.stderr.write('risk_level ' + JSON.stringify(s.risk_level)); process.exit(1); }
if (s.gates.rows[0].status !== 'PASSED') { process.stderr.write('gate status ' + JSON.stringify(s.gates.rows[0].status)); process.exit(1); }
console.log('visited ' + visited + ' strings, ' + dirtyBefore + ' dirty before');
" "$1" "$CACHE_FILE"
}

@test "sanitizeCache cleans every string of real snapshot output" {
  _dirty_fixture
  _check_real_cache "$REPO_ROOT/plugins/gaia/hooks/sanitize.js"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == "visited "* ]] || false
}

@test "a sanitizeCache that skips strings fails the real-output check" {
  _dirty_fixture
  local mutant="$BATS_TEST_TMPDIR/mutant-sanitize.js"
  sed "s/if (typeof value === 'string') return sanitize(value, limitFor(prop));/if (typeof value === 'string') return value;/" \
    "$REPO_ROOT/plugins/gaia/hooks/sanitize.js" > "$mutant"
  run cmp -s "$REPO_ROOT/plugins/gaia/hooks/sanitize.js" "$mutant"
  [ "$status" -ne 0 ]
  _check_real_cache "$mutant"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dirty after sanitizeCache:"* ]] || false
}
