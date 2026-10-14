#!/usr/bin/env bats
# mod-cap-detect-direct.bats -- Direct ESM unit tests for capability-detection
# guards, bypassing the mod harness engine. This tests the actual try/catch
# behavior by calling the handlers directly with a hand-built $ object.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  HOOKS_DIR="$REPO_ROOT/plugins/gaia/hooks"
  INDEX_JS="$HOOKS_DIR/index.js"
  PLUGIN_DIR="$REPO_ROOT/plugins/gaia"
}

# Helper: build the common preamble that imports register, captures handlers,
# and defines the stub $ builder. Each test appends its scenario.
_preamble() {
  cat << 'PREAMBLE'
// The hooks module uses the global h (JSX factory) in ui.render handlers.
// We never call ui.render here, but the import needs to succeed.
globalThis.h = function() { return {} };

const indexUrl = new URL('PLACEHOLDER', import.meta.url).href;
const { register, getPaneOpen } = await import(indexUrl);

// Capture handlers registered by the module
const handlers = {};
function fakeOn(event, matcherOrFn, handlerOrUndef) {
  let handler = handlerOrUndef || matcherOrFn;
  let key = typeof matcherOrFn === 'object'
    ? event + ':' + JSON.stringify(matcherOrFn)
    : event;
  handlers[key] = handler;
  // Return an object with .catch for the ui.close handler
  return { catch: function(fn) { handlers[key + ':catch'] = fn; } };
}
register(fakeOn);

const ACTIVE_CACHE = JSON.stringify({
  schema_version:'1.0', generated_at:'', sprint:{id:'s1',goal:null,start_date:null,end_date:null,status:'active',total_days:14,capacity_utilization:null,epic_focus:null},
  totals:{done_points:0,total_points:5,done_stories:0,total_stories:1,progress_pct:0},
  by_status:{},day:{current:1,total:14,pace:'on-pace'},active_phase:1,phases:[],unphased_stories:[],
  stories:[{key:'E900-S1',status:'in-progress',points:5,title:'Story',slug:'s',phase:1,blocked_by:null,gates:{passed:0,total:6,rows:[]},tasks:{done:0,total:0,items:[]}}],
  action_needed:[],drift:[],readiness:{sprint_review:false,sprint_close:false},user_aliases:[],waiting_agent_threshold_seconds:900
});

// Build a $ stub with configurable throwing members
function make$(overrides) {
  const base = {
    plugin: { root: '/fake' },
    command: { register: async () => ({}) },
    clock: { every: (ms, fn) => (() => {}), now: async () => Date.now() },
    session: { root: async () => '/project' },
    fs: {
      exists: async (p) => p === '/project/.gaia',
      stat: async () => ({ kind:'file', size:100, mtimeMs:Date.now(), isLink:false }),
      read: async () => ACTIVE_CACHE
    },
    process: { run: async () => ({ exitCode:0, stdout:'', stderr:'', isStdoutTruncated:false, isStderrTruncated:false }) },
    ui: {
      log: () => {},
      panes: async () => [],
      invalidate: () => {},
      resolve: () => ({Box:{},Text:{}}),
      open: async () => ({isPlaced:false})
    }
  };
  // Apply overrides (deep-merge one level)
  for (const [k, v] of Object.entries(overrides || {})) {
    if (typeof v === 'object' && v !== null && !Array.isArray(v) && typeof base[k] === 'object') {
      base[k] = { ...base[k], ...v };
    } else {
      base[k] = v;
    }
  }
  return base;
}

// Session.start handler is captured at key 'session.start'
const sessionStart = handlers['session.start'];
const sprintCmd = handlers['command.run:{"command":"sprint"}'];
PREAMBLE
}

@test "all members throw: handler resolves no rejection no non-debug log" {
  run node --input-type=module -e "$(_preamble | sed "s|PLACEHOLDER|${INDEX_JS}|")
const logCalls = [];
const thrower = () => { throw new Error('not available'); };
const \$ = make\$({
  command: { register: thrower },
  clock: { every: thrower, now: thrower },
  session: { root: thrower },
  fs: { exists: thrower, stat: thrower, read: thrower },
  process: { run: thrower },
  ui: {
    log: (msg, opts) => { logCalls.push({msg, to: opts && opts.to}); },
    panes: thrower,
    invalidate: () => {},
    resolve: () => ({Box:{},Text:{}})
  }
});
const next = (e) => ({ cwd: e.cwd });
// Must not reject
const result = await sessionStart(\$, {cwd:'/nowhere'}, next);
// Must return next(e) value
if (!result || result.cwd !== '/nowhere') { process.stderr.write('handler did not return next(e)'); process.exit(1); }
// No non-debug log calls
const nonDebug = logCalls.filter(c => c.to !== 'debug');
if (nonDebug.length > 0) { process.stderr.write('non-debug log: ' + JSON.stringify(nonDebug)); process.exit(1); }
"
  echo "output: $output"
  [ "$status" -eq 0 ]
}

@test "command.register throws but clock and probe work: sprint returns active" {
  run node --input-type=module -e "$(_preamble | sed "s|PLACEHOLDER|${INDEX_JS}|")
const \$ = make\$({
  command: { register: async () => { throw new Error('not available'); } }
});
const next = (e) => ({ cwd: e.cwd });
await sessionStart(\$, {cwd:'/project'}, next);
// Sprint command should see active cache
const sprintResult = await sprintCmd(\$);
if (sprintResult.text === 'No active sprint') { process.stderr.write('expected active sprint but got No active sprint'); process.exit(1); }
"
  echo "output: $output"
  [ "$status" -eq 0 ]
}

@test "clock.every throws but command and probe work: sprint returns active" {
  run node --input-type=module -e "$(_preamble | sed "s|PLACEHOLDER|${INDEX_JS}|")
const \$ = make\$({
  clock: { every: () => { throw new Error('not available'); }, now: async () => Date.now() }
});
const next = (e) => ({ cwd: e.cwd });
await sessionStart(\$, {cwd:'/project'}, next);
const sprintResult = await sprintCmd(\$);
if (sprintResult.text === 'No active sprint') { process.stderr.write('expected active sprint but got No active sprint'); process.exit(1); }
"
  echo "output: $output"
  [ "$status" -eq 0 ]
}

# -- Mutant kills: removing the try/catch guard causes the direct test to fail --

@test "removing command.register guard makes direct degradation test reject" {
  [ -f "$INDEX_JS" ] || false

  MUTANT_DIR="${BATS_TMPDIR}/mutant-direct-cmd-$$"
  mkdir -p "$MUTANT_DIR"
  cp "$INDEX_JS" "$MUTANT_DIR/index.js"
  cp "$HOOKS_DIR/sanitize.js" "$MUTANT_DIR/sanitize.js"

  # Remove the try/catch around command.register
  sed '/MARKER:CAP_DETECT_CMD$/d' "$MUTANT_DIR/index.js" > "$MUTANT_DIR/_t.js"
  mv "$MUTANT_DIR/_t.js" "$MUTANT_DIR/index.js"
  sed '/MARKER:CAP_DETECT_CMD_END$/d' "$MUTANT_DIR/index.js" > "$MUTANT_DIR/_t.js"
  mv "$MUTANT_DIR/_t.js" "$MUTANT_DIR/index.js"

  # Verify ESM parse
  cp "$MUTANT_DIR/index.js" "$MUTANT_DIR/index.mjs"
  run node --check "$MUTANT_DIR/index.mjs"
  rm -f "$MUTANT_DIR/index.mjs"
  [ "$status" -eq 0 ]

  # Run the direct test -- should fail (unguarded throw aborts handler)
  run node --input-type=module -e "$(_preamble | sed "s|PLACEHOLDER|${MUTANT_DIR}/index.js|")
const \$ = make\$({
  command: { register: async () => { throw new Error('not available'); } }
});
const next = (e) => ({ cwd: e.cwd });
await sessionStart(\$, {cwd:'/project'}, next);
const sprintResult = await sprintCmd(\$);
if (sprintResult.text === 'No active sprint') { process.stderr.write('expected active sprint but got No active sprint'); process.exit(1); }
"
  echo "mutant output: $output"
  [ "$status" -ne 0 ]

  rm -rf "$MUTANT_DIR"
}

@test "removing clock.every guard makes direct partial-caps test reject" {
  [ -f "$INDEX_JS" ] || false

  MUTANT_DIR="${BATS_TMPDIR}/mutant-direct-clk-$$"
  mkdir -p "$MUTANT_DIR"
  cp "$INDEX_JS" "$MUTANT_DIR/index.js"
  cp "$HOOKS_DIR/sanitize.js" "$MUTANT_DIR/sanitize.js"

  # Remove the try/catch around clock.every
  sed '/MARKER:CAP_DETECT_CLK$/d' "$MUTANT_DIR/index.js" > "$MUTANT_DIR/_t.js"
  mv "$MUTANT_DIR/_t.js" "$MUTANT_DIR/index.js"
  sed '/MARKER:CAP_DETECT_CLK_END$/d' "$MUTANT_DIR/index.js" > "$MUTANT_DIR/_t.js"
  mv "$MUTANT_DIR/_t.js" "$MUTANT_DIR/index.js"

  cp "$MUTANT_DIR/index.js" "$MUTANT_DIR/index.mjs"
  run node --check "$MUTANT_DIR/index.mjs"
  rm -f "$MUTANT_DIR/index.mjs"
  [ "$status" -eq 0 ]

  run node --input-type=module -e "$(_preamble | sed "s|PLACEHOLDER|${MUTANT_DIR}/index.js|")
const \$ = make\$({
  clock: { every: () => { throw new Error('not available'); }, now: async () => Date.now() }
});
const next = (e) => ({ cwd: e.cwd });
await sessionStart(\$, {cwd:'/project'}, next);
const sprintResult = await sprintCmd(\$);
if (sprintResult.text === 'No active sprint') { process.stderr.write('expected active sprint but got No active sprint'); process.exit(1); }
"
  echo "mutant output: $output"
  [ "$status" -ne 0 ]

  rm -rf "$MUTANT_DIR"
}

# -- ui.close handler test --

@test "ui.close handler sets paneOpen false and returns next" {
  run node --input-type=module -e "$(_preamble | sed "s|PLACEHOLDER|${INDEX_JS}|")
// Session.start with panes listing sprint-status so paneOpen reconciles to true
const \$ = make\$({
  ui: {
    log: () => {},
    panes: async () => [{ id: 'sprint-status', title: 'Sprint', isShown: true, isFocused: false, isPlaced: true }],
    invalidate: () => {},
    resolve: () => ({Box:{},Text:{}}),
    open: async () => ({isPlaced:false})
  }
});
const next = (e) => ({ cwd: e.cwd });
await sessionStart(\$, {cwd:'/project'}, next);

// After reconciliation, paneOpen should be true
if (!getPaneOpen()) { process.stderr.write('paneOpen should be true after reconciliation'); process.exit(1); }

// Fire the close handler directly
const closeHandler = handlers['ui.close:{\"id\":\"sprint-status\"}'];
if (!closeHandler) { process.stderr.write('no ui.close handler captured'); process.exit(1); }
const closeNext = (e) => 'close-chain-value';
const closeResult = await closeHandler(\$, { id: 'sprint-status', origin: { kind: 'plugin' } }, closeNext);

// paneOpen should now be false
if (getPaneOpen()) { process.stderr.write('paneOpen should be false after close'); process.exit(1); }

// Handler must have returned next(e)
if (closeResult !== 'close-chain-value') { process.stderr.write('handler did not return next(e), got: ' + JSON.stringify(closeResult)); process.exit(1); }
"
  echo "output: $output"
  [ "$status" -eq 0 ]
}

@test "removing paneOpen assignment from close handler makes close test red" {
  [ -f "$INDEX_JS" ] || false

  MUTANT_DIR="${BATS_TMPDIR}/mutant-pane-close-$$"
  mkdir -p "$MUTANT_DIR"
  cp "$INDEX_JS" "$MUTANT_DIR/index.js"
  cp "$HOOKS_DIR/sanitize.js" "$MUTANT_DIR/sanitize.js"

  # Remove every paneOpen = false line (handler + catch)
  sed '/paneOpen = false/d' "$MUTANT_DIR/index.js" > "$MUTANT_DIR/_t.js"
  mv "$MUTANT_DIR/_t.js" "$MUTANT_DIR/index.js"

  run diff "$INDEX_JS" "$MUTANT_DIR/index.js"
  [ "$status" -ne 0 ]

  cp "$MUTANT_DIR/index.js" "$MUTANT_DIR/index.mjs"
  run node --check "$MUTANT_DIR/index.mjs"
  rm -f "$MUTANT_DIR/index.mjs"
  [ "$status" -eq 0 ]

  # Direct test should fail: paneOpen stays true after close
  run node --input-type=module -e "$(_preamble | sed "s|PLACEHOLDER|${MUTANT_DIR}/index.js|")
const \$ = make\$({
  ui: {
    log: () => {},
    panes: async () => [{ id: 'sprint-status', title: 'Sprint', isShown: true, isFocused: false, isPlaced: true }],
    invalidate: () => {},
    resolve: () => ({Box:{},Text:{}}),
    open: async () => ({isPlaced:false})
  }
});
const next = (e) => ({ cwd: e.cwd });
await sessionStart(\$, {cwd:'/project'}, next);
if (!getPaneOpen()) { process.stderr.write('paneOpen should be true after reconciliation'); process.exit(1); }
const closeHandler = handlers['ui.close:{\"id\":\"sprint-status\"}'];
await closeHandler(\$, { id: 'sprint-status', origin: { kind: 'plugin' } }, (e) => 'ok');
if (getPaneOpen()) { process.stderr.write('paneOpen should be false after close'); process.exit(1); }
"
  echo "mutant output: $output"
  [ "$status" -ne 0 ]

  rm -rf "$MUTANT_DIR"
}
