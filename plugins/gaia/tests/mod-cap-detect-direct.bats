#!/usr/bin/env bats
# mod-cap-detect-direct.bats -- Direct ESM tests of the hooks module, calling
# its handlers with a hand-built $ whose members follow the runtime's API
# shapes ($.clock.every hands back an object with cancel()).

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  HOOKS_DIR="$REPO_ROOT/plugins/gaia/hooks"
  INDEX_JS="$HOOKS_DIR/index.js"
}

# Writes the harness module to $1: it imports the hooks module named by the
# MOD_INDEX environment variable, captures the handlers, and builds $ stubs.
_write_preamble() {
  cat > "$1" << 'PREAMBLE'
// The hooks module uses the global h (JSX factory) in ui.render handlers.
globalThis.h = function () { return {} };

const { pathToFileURL } = await import('node:url');
const mod = await import(pathToFileURL(process.env.MOD_INDEX).href);
export const { register, getPaneOpen, getCacheView } = mod;

export const handlers = {};
function fakeOn(event, matcherOrFn, handlerOrUndef) {
  const handler = handlerOrUndef || matcherOrFn;
  const key = typeof matcherOrFn === 'object' ? event + ':' + JSON.stringify(matcherOrFn) : event;
  handlers[key] = handler;
  return { catch: function (fn) { handlers[key + ':catch'] = fn; } };
}
register(fakeOn);

export const ACTIVE_CACHE = JSON.stringify({
  schema_version: '1.0', generated_at: '',
  sprint: { id: 's1', goal: null, start_date: null, end_date: null, status: 'active', total_days: 14, capacity_utilization: null, epic_focus: null },
  totals: { done_points: 0, total_points: 5, done_stories: 0, total_stories: 1, progress_pct: 0 },
  by_status: {}, day: { current: 1, total: 14, pace: 'on-pace' }, active_phase: 1, phases: [], unphased_stories: [],
  stories: [{ key: 'E900-S1', status: 'in-progress', points: 5, title: 'Story', slug: 's', phase: 1, blocked_by: null,
    gates: { passed: 0, total: 6, rows: [] }, tasks: { done: 0, total: 0, items: [] } }],
  action_needed: [], drift: [], readiness: { sprint_review: false, sprint_close: false }, user_aliases: [],
  waiting_agent_threshold_seconds: 900
});

export const OK_RUN = { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false };
export const NOW = 1000000;

// Builds a $ stub. Overrides are merged one level deep.
export function make$(overrides) {
  const base = {
    plugin: { root: '/fake' },
    command: { register: async () => ({}) },
    clock: { every: () => ({ cancel: () => {} }), now: async () => NOW },
    session: { root: async () => '/project' },
    env: { get: async () => undefined },
    fs: {
      exists: async (p) => p === '/project/.gaia',
      stat: async () => ({ kind: 'file', size: 100, mtimeMs: NOW, isLink: false }),
      read: async () => ACTIVE_CACHE
    },
    process: { run: async () => OK_RUN },
    ui: {
      log: () => {},
      panes: async () => [],
      invalidate: () => {},
      resolve: () => ({ Box: {}, Text: {} }),
      open: async () => ({ isPlaced: false })
    }
  };
  for (const [k, v] of Object.entries(overrides || {})) {
    if (typeof v === 'object' && v !== null && !Array.isArray(v) && typeof base[k] === 'object') {
      base[k] = { ...base[k], ...v };
    } else {
      base[k] = v;
    }
  }
  return base;
}

export const sessionStart = handlers['session.start'];
export const sprintCmd = handlers['command.run:{"command":"sprint"}'];
export const closeHandler = handlers['ui.close:{"id":"sprint-status"}'];
export function fail(msg) { process.stderr.write('SCENARIO FAILED: ' + msg + '\n'); process.exit(1); }
PREAMBLE
}

# Runs scenario $2 (node ESM) against hooks module $1. The scenario imports
# from ./preamble.mjs.
_run_scenario() {
  local index="$1" scenario="$2" dir
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/scn.XXXXXX")"
  _write_preamble "$dir/preamble.mjs"
  printf '%s\n' "import { register, getPaneOpen, getCacheView, handlers, make\$, sessionStart, sprintCmd, closeHandler, fail, OK_RUN, NOW } from './preamble.mjs';" "$scenario" > "$dir/scenario.mjs"
  run env MOD_INDEX="$index" node "$dir/scenario.mjs"
}

# Copies the hooks module into a fresh directory and applies a sed
# expression; fails the test when the expression changed nothing.
_mutant() {
  local expr="$1" dir
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/mutant.XXXXXX")"
  cp "$HOOKS_DIR/index.js" "$HOOKS_DIR/sanitize.js" "$dir/"
  sed "$expr" "$HOOKS_DIR/index.js" > "$dir/index.js"
  if cmp -s "$HOOKS_DIR/index.js" "$dir/index.js"; then
    echo "mutation '$expr' changed nothing" >&2
    return 1
  fi
  MUTANT_INDEX="$dir/index.js"
}

ALL_THROW_SCENARIO='
const logCalls = [];
const thrower = () => { throw new Error("not available"); };
const $ = make$({
  command: { register: thrower },
  clock: { every: thrower, now: thrower },
  session: { root: thrower },
  env: { get: thrower },
  fs: { exists: thrower, stat: thrower, read: thrower },
  process: { run: thrower },
  ui: { log: (msg, opts) => { logCalls.push({ msg, to: opts && opts.to }); }, panes: thrower, invalidate: () => {}, resolve: () => ({ Box: {}, Text: {} }) }
});
let result;
try { result = await sessionStart($, { cwd: "/nowhere" }, (e) => ({ cwd: e.cwd })); }
catch (err) { fail("session.start rejected: " + err.message); }
if (!result || result.cwd !== "/nowhere") fail("handler did not return next(e)");
const nonDebug = logCalls.filter(c => c.to !== "debug");
if (nonDebug.length > 0) fail("non-debug log: " + JSON.stringify(nonDebug));
const sprint = await sprintCmd($);
if (JSON.stringify(sprint) !== JSON.stringify({ text: "No active sprint" })) fail("sprint: " + JSON.stringify(sprint));
console.log("ALL_THROW_OK");
'

@test "all members throw: handler resolves with next(e) and logs only to debug" {
  _run_scenario "$INDEX_JS" "$ALL_THROW_SCENARIO"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *ALL_THROW_OK* ]] || false
}

@test "removing the command.register guard makes the all-throw scenario reject" {
  _mutant '/MARKER:CAP_DETECT_CMD$/d;/MARKER:CAP_DETECT_CMD_END$/d'
  _run_scenario "$MUTANT_INDEX" "$ALL_THROW_SCENARIO"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SCENARIO FAILED: session.start rejected: not available"* ]] || false
}

@test "removing the clock.every guard makes the all-throw scenario reject" {
  _mutant '/MARKER:CAP_DETECT_CLK$/d;/MARKER:CAP_DETECT_CLK_END$/d'
  _run_scenario "$MUTANT_INDEX" "$ALL_THROW_SCENARIO"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SCENARIO FAILED: session.start rejected: not available"* ]] || false
}

@test "command.register throws but clock and probe work: sprint returns active" {
  _run_scenario "$INDEX_JS" '
const $ = make$({ command: { register: async () => { throw new Error("not available"); } } });
await sessionStart($, { cwd: "/project" }, (e) => ({ cwd: e.cwd }));
const r = await sprintCmd($);
if (JSON.stringify(r) !== "{}") fail("expected active sprint, got " + JSON.stringify(r));
console.log("PARTIAL_OK");
'
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *PARTIAL_OK* ]] || false
}

@test "clock.every throws but command and probe work: sprint returns active" {
  _run_scenario "$INDEX_JS" '
const $ = make$({ clock: { every: () => { throw new Error("not available"); }, now: async () => NOW } });
await sessionStart($, { cwd: "/project" }, (e) => ({ cwd: e.cwd }));
const r = await sprintCmd($);
if (JSON.stringify(r) !== "{}") fail("expected active sprint, got " + JSON.stringify(r));
console.log("PARTIAL_OK");
'
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *PARTIAL_OK* ]] || false
}

RE_ENTRY_SCENARIO='
const timers = [];
const $ = make$({ clock: { every: (ms, fn) => { const t = { ms, cancels: 0 }; t.cancel = () => { t.cancels++; }; timers.push(t); return t; }, now: async () => NOW } });
await sessionStart($, { cwd: "/project" }, (e) => ({ cwd: e.cwd }));
await sessionStart($, { cwd: "/project" }, (e) => ({ cwd: e.cwd }));
if (timers.length !== 2) fail("expected 2 timers, got " + timers.length);
if (timers[0].ms !== 30000) fail("timer period " + timers[0].ms);
if (timers[0].cancels !== 1) fail("first timer cancelled " + timers[0].cancels + " times, expected 1");
if (timers[1].cancels !== 0) fail("live timer was cancelled");
console.log("RE_ENTRY_OK");
'

@test "re-entry cancels the previous timer through its cancel method" {
  _run_scenario "$INDEX_JS" "$RE_ENTRY_SCENARIO"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *RE_ENTRY_OK* ]] || false
}

@test "calling the timer handle as a function leaves the old timer running" {
  _mutant 's/if (typeof handle.cancel === .function.) handle.cancel()/if (false) handle.cancel()/'
  _run_scenario "$MUTANT_INDEX" "$RE_ENTRY_SCENARIO"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SCENARIO FAILED: first timer cancelled 0 times, expected 1"* ]] || false
}

@test "a timer handle that is a bare function is still stopped on re-entry" {
  _run_scenario "$INDEX_JS" '
let stops = 0;
const $ = make$({ clock: { every: () => () => { stops++; }, now: async () => NOW } });
await sessionStart($, { cwd: "/project" }, (e) => ({ cwd: e.cwd }));
await sessionStart($, { cwd: "/project" }, (e) => ({ cwd: e.cwd }));
if (stops !== 1) fail("stops " + stops);
console.log("FN_HANDLE_OK");
'
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *FN_HANDLE_OK* ]] || false
}

SANITIZE_WIRING_SCENARIO='
const dirty = JSON.parse(ACTIVE_CACHE_DIRTY);
const $ = make$({ fs: { read: async () => JSON.stringify(dirty) } });
await sessionStart($, { cwd: "/project" }, (e) => ({ cwd: e.cwd }));
await sprintCmd($);
const view = getCacheView();
if (!view) fail("no cache in memory");
const bad = [];
(function walk(v, path) {
  if (typeof v === "string") {
    if (/[\x00-\x09\x0b-\x1f\x7f-\x9f‪-‮⁦-⁩]/.test(v)) bad.push(path + "=" + JSON.stringify(v));
    return;
  }
  if (v && typeof v === "object") for (const k of Object.keys(v)) walk(v[k], path + "." + k);
})(view, "$");
if (bad.length) fail("unsanitised: " + bad.join(", "));
if (view.stories[0].title !== "Title") fail("title " + JSON.stringify(view.stories[0].title));
if (view.stories[0].status !== "review") fail("status " + JSON.stringify(view.stories[0].status));
console.log("WIRING_OK");
'

_dirty_cache() {
  node -e '
const c = {
  sprint: { id: "s1", status: "active", goal: "g\u009d0;t\u0007" },
  stories: [{ key: "E900-S1", title: "\u009b2JTitle", status: "\u009b31mreview", risk_level: "high‮",
    gates: { rows: [{ name: "val", status: "PASSED\u009b0m" }] }, tasks: { items: [{ text: "t\u0085" }] } }],
  drift: [{ story_key: "E900-S1", type: "status‮mismatch", detail: "d" }],
  action_needed: [], phases: [{ stories: ["E900-S1\u009b"] }], user_aliases: ["me⁦"]
};
process.stdout.write(JSON.stringify(JSON.stringify(c)));'
}

@test "the module sanitises every cache string before keeping it in memory" {
  _run_scenario "$INDEX_JS" "const ACTIVE_CACHE_DIRTY = $(_dirty_cache);
$SANITIZE_WIRING_SCENARIO"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *WIRING_OK* ]] || false
}

@test "removing the sanitizeCache call in the read path leaves dirty text in memory" {
  _mutant 's/^    sanitizeCache(data)$/    void 0/'
  _run_scenario "$MUTANT_INDEX" "const ACTIVE_CACHE_DIRTY = $(_dirty_cache);
$SANITIZE_WIRING_SCENARIO"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SCENARIO FAILED: unsanitised:"* ]] || false
}

SCRIPT_ROOT_SCENARIO='
const runs = [];
const $ = make$({
  fs: { exists: async (p) => p === "/project/.gaia" || p === "/project/scripts/sprint-progress-snapshot.sh" },
  process: { run: async (argv, init) => { runs.push({ argv, init }); return OK_RUN; } }
});
await sessionStart($, { cwd: "/project" }, (e) => ({ cwd: e.cwd }));
await sprintCmd($); // joins the probe
await sprintCmd($); // runs a snapshot of its own
if (runs.length !== 2) fail("expected 2 runs, got " + runs.length);
for (const r of runs) {
  if (JSON.stringify(r.argv) !== JSON.stringify(["/fake/scripts/sprint-progress-snapshot.sh"])) fail("argv " + JSON.stringify(r.argv));
  if (JSON.stringify(r.init) !== JSON.stringify({ cwd: "/project", env: { PROJECT_ROOT: "/project" }, timeoutMs: 30000 })) fail("init " + JSON.stringify(r.init));
}
console.log("SCRIPT_ROOT_OK");
'

@test "the snapshot script is resolved from the plugin root, never the project" {
  _run_scenario "$INDEX_JS" "$SCRIPT_ROOT_SCENARIO"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *SCRIPT_ROOT_OK* ]] || false
}

@test "resolving the script from the project root runs a planted script and goes red" {
  _mutant 's/joinPath(\$\.plugin\.root, .scripts., .sprint-progress-snapshot\.sh.)/joinPath(root, "scripts", "sprint-progress-snapshot.sh")/'
  _run_scenario "$MUTANT_INDEX" "$SCRIPT_ROOT_SCENARIO"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *'SCENARIO FAILED: argv ["/project/scripts/sprint-progress-snapshot.sh"]'* ]] || false
}

CLOSE_SCENARIO='
const $ = make$({ ui: { log: () => {}, panes: async () => [{ id: "sprint-status", title: "Sprint", isShown: true, isFocused: false, isPlaced: true }], invalidate: () => {}, resolve: () => ({ Box: {}, Text: {} }) } });
await sessionStart($, { cwd: "/project" }, (e) => ({ cwd: e.cwd }));
if (!getPaneOpen()) fail("paneOpen should be true after reconciliation");
if (!closeHandler) fail("no ui.close handler captured");
const closeResult = await closeHandler($, { id: "sprint-status", origin: { kind: "plugin" } }, () => "close-chain-value");
if (getPaneOpen()) fail("paneOpen should be false after close");
if (closeResult !== "close-chain-value") fail("handler did not return next(e)");
console.log("CLOSE_OK");
'

@test "ui.close handler sets paneOpen false and returns next" {
  _run_scenario "$INDEX_JS" "$CLOSE_SCENARIO"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *CLOSE_OK* ]] || false
}

@test "removing the paneOpen assignment from the close handler makes the close test red" {
  _mutant '/^    paneOpen = false$/d'
  _run_scenario "$MUTANT_INDEX" "$CLOSE_SCENARIO"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SCENARIO FAILED: paneOpen should be false after close"* ]] || false
}

@test "removing the panes reconciliation makes the close test red" {
  _mutant 's/paneOpen = panes.some(/paneOpen = false \&\& panes.some(/'
  _run_scenario "$MUTANT_INDEX" "$CLOSE_SCENARIO"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SCENARIO FAILED: paneOpen should be true after reconciliation"* ]] || false
}

BAND_SCENARIO='
const band = handlers["ui.render:" + JSON.stringify({ component: "AbovePrompt" })];
if (!band) fail("no AbovePrompt handler captured");
const $ = make$({});
await sessionStart($, { cwd: "/project" }, (e) => ({ cwd: e.cwd }));
await sprintCmd($);
const r = await band($, { component: "AbovePrompt" }, () => "band-chain-value");
if (r !== "band-chain-value") fail("band handler returned " + JSON.stringify(r) + " instead of next(e)");
console.log("BAND_OK");
'

@test "the band handler returns exactly what the rest of the chain draws" {
  _run_scenario "$INDEX_JS" "$BAND_SCENARIO"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *BAND_OK* ]] || false
}
