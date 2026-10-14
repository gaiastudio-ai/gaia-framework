import { sanitizeCache } from './sanitize.js'

// -- tuning --
var TICK_MS = 30000          // interval timer period
var STALE_MS = 60000         // a cache older than this is rebuilt
var BACKOFF_MAX_MS = 300000  // longest wait after runs that left the cache untouched
var NO_SPRINT = 'No active sprint'

// -- module-level state (reset on reload) --
var caps = { command: false, clock: false, process: false, gaiaRoot: null }
var cachedData = null
var cacheState = 'init' // 'init' | 'absent' | 'error' | 'loaded'
var cacheMtimeMs = 0
var cacheStatKey = ''   // mtime + size of the file behind cachedData / cacheState
var inFlight = null     // { root, promise } of the one snapshot that may run
var paneOpen = false
var timerHandle = null
var unchangedRuns = 0   // consecutive snapshot runs that did not move the cache
var backoffUntil = 0

// -- helpers --

function joinPath(root, ...segments) {
  return [root, ...segments].join('/')
}

function errText(err) {
  return String(err && err.message ? err.message : err)
}

function log($, msg) {
  try { $.ui.log(msg, { to: 'debug' }) } catch (_) { /* stripped build */ }
}

// Stops a timer from $.clock.every. The runtime hands back an object with a
// cancel() method; a bare function is accepted too, for older builds.
function stopTimer(handle) {
  if (!handle) return
  try {
    if (typeof handle.cancel === 'function') handle.cancel()
    else if (typeof handle === 'function') handle()
  } catch (_) { /* already stopped */ }
}

function trimSlash(p) {
  var s = String(p)
  while (s.length > 1 && s.charAt(s.length - 1) === '/') s = s.slice(0, -1)
  return s
}

function parentOf(dir) {
  var parent = dir.replace(/\/[^/]+$/, '')
  return parent === '' ? '/' : parent
}

// Finds the GAIA project root: the nearest directory holding .gaia, starting
// at the session root. The walk only climbs inside the user's home directory
// (home itself included), so a .gaia in a shared ancestor such as /tmp,
// /Users/Shared or the filesystem root is never taken as the project. Outside
// home (or with HOME unknown) only the session root itself is checked.
async function findGaiaRoot($) {
  var root = trimSlash(await $.session.root())
  if (root.charAt(0) !== '/') return null
  var home = null
  try { home = await $.env.get("HOME") } catch (_) { home = null }
  home = home ? trimSlash(home) : null
  var underHome = home !== null && home !== '/' && (root === home || root.indexOf(home + '/') === 0)
  var dir = root
  while (dir !== '/') {
    if (await $.fs.exists(joinPath(dir, '.gaia'))) return dir
    if (!underHome || dir === home) return null
    dir = parentOf(dir)
  }
  return null
}

async function readCache($, root) {
  try {
    var cachePath = joinPath(root, '.gaia', 'state', '.sprint-progress-cache.json')
    var stat
    try {
      stat = await $.fs.stat(cachePath)
    } catch (_) {
      return { status: 'absent', mtimeMs: 0, key: '' }
    }
    var key = String(stat.mtimeMs) + ':' + String(stat.size)
    // Unchanged file: keep what was parsed and sanitised last time.
    if (key === cacheStatKey && (cacheState === 'loaded' || cacheState === 'error')) {
      return { status: 'same', mtimeMs: stat.mtimeMs, key: key }
    }
    var raw = await $.fs.read(cachePath)
    var data = JSON.parse(raw)
    if (!data || typeof data !== 'object') throw new Error('cache is not an object')
    // Every string in the cache is untrusted repository text: sanitise it once,
    // here, so the render path only ever sees clean values.
    sanitizeCache(data)
    return { status: 'ok', data: data, mtimeMs: stat.mtimeMs, key: key }
  } catch (err) {
    log($, 'cache read failed: ' + errText(err))
    return { status: 'error', mtimeMs: stat ? stat.mtimeMs : 0, key: key || '' }
  }
}

async function refresh($) {
  // Callers check caps.gaiaRoot first.
  var root = caps.gaiaRoot
  var r = await readCache($, root)
  if (root !== caps.gaiaRoot) return // the session moved on while reading
  if (r.status === 'same') return
  cacheStatKey = r.key
  cacheMtimeMs = r.mtimeMs
  if (r.status === 'ok') {
    cachedData = r.data
    cacheState = 'loaded'
  } else if (r.status === 'absent') {
    cachedData = null
    cacheState = 'absent'
  } else {
    // Unparseable: drop any earlier good value.
    cachedData = null
    cacheState = 'error'
  }
}

// Runs the snapshot script once. Resolves true when the process ran (whatever
// its exit code), false when it could not start or timed out.
async function runSnapshot($, root) {
  var result
  try {
    result = await $.process.run([joinPath($.plugin.root, 'scripts', 'sprint-progress-snapshot.sh')], {
      cwd: root, env: { PROJECT_ROOT: root }, timeoutMs: 30000
    })
  } catch (err) {
    log($, 'snapshot did not run: ' + errText(err))
    return false
  }
  if (result.exitCode !== 0) {
    log($, 'snapshot exited ' + result.exitCode)
  }
  return true
}

async function nowMs($) {
  try { return await $.clock.now() } catch (_) { return 0 }
}

// Single flight: at most one snapshot runs at a time. Callers for the same
// root join the running one; a caller for another root waits for it to end
// and then starts its own.
function runSnapshotAndRefresh($) {
  var root = caps.gaiaRoot
  if (!root) return Promise.resolve()
  if (inFlight) {
    if (inFlight.root === root) return inFlight.promise
    return inFlight.promise.then(function () { return runSnapshotAndRefresh($) },
      function () { return runSnapshotAndRefresh($) })
  }
  var slot = { root: root, promise: null }
  inFlight = slot
  slot.promise = (async function () {
    try {
      var before = cacheStatKey
      var ran = await runSnapshot($, root)
      if (root !== caps.gaiaRoot) return
      caps.process = ran // MARKER:PROCESS_CAP
      await refresh($)
      noteRunOutcome(before !== cacheStatKey, await nowMs($))
      try { $.ui.invalidate('ui.render') } catch (_) { /* stripped build */ }
    } finally {
      if (inFlight === slot) inFlight = null
    }
  })()
  return slot.promise
}

// Backoff for a writer that exits without touching the cache (lock held
// elsewhere, refused state directory, failed assembly): the timer waits
// 30 s, 60 s, 120 s ... up to 5 minutes between such runs, and goes back to
// normal as soon as a run moves the cache.
function noteRunOutcome(cacheMoved, now) {
  if (cacheMoved) {
    unchangedRuns = 0
    backoffUntil = 0
    return
  }
  unchangedRuns++
  var wait = TICK_MS
  for (var i = 1; i < unchangedRuns && wait < BACKOFF_MAX_MS; i++) wait = wait * 2
  if (wait > BACKOFF_MAX_MS) wait = BACKOFF_MAX_MS
  backoffUntil = now + wait
}

function maybeRebuild($, now) {
  if (caps.gaiaRoot === null) return
  if (inFlight) return
  if (cacheMtimeMs > now || now - cacheMtimeMs <= STALE_MS) return // MARKER:STALENESS_GUARD
  if (now < backoffUntil) return
  // Fire and forget: errors are logged, not propagated.
  runSnapshotAndRefresh($).catch(function (err) {
    log($, 'rebuild failed: ' + errText(err))
  })
}

// Read-only accessors for the sidebar rendering and the tests.
export function getPaneOpen() { return paneOpen }
export function getCacheView() { return cachedData }

// -- registration --

export function register(on) {
  on('session.start', async ($, e, next) => {
    // Re-entry: stop the previous timer and start from a clean state. A
    // snapshot still running is kept: the single flight lets it finish.
    stopTimer(timerHandle)
    timerHandle = null
    caps = { command: false, clock: false, process: false, gaiaRoot: null }
    cachedData = null
    cacheState = 'init'
    cacheMtimeMs = 0
    cacheStatKey = ''
    paneOpen = false
    unchangedRuns = 0
    backoffUntil = 0

    // Capability detection.
    try { // MARKER:CAP_DETECT_CMD
      await $.command.register({ name: 'sprint', description: 'Toggle sprint dashboard' })
      caps.command = true
    } catch (_) { caps.command = false } // MARKER:CAP_DETECT_CMD_END

    try { // MARKER:CAP_DETECT_CLK
      timerHandle = $.clock.every(TICK_MS, async () => {
        if (caps.gaiaRoot === null) return
        try {
          await refresh($)
          var now = await $.clock.now()
          maybeRebuild($, now)
        } catch (err) { log($, 'timer tick failed: ' + errText(err)) }
      })
      caps.clock = true
    } catch (_) { caps.clock = false } // MARKER:CAP_DETECT_CLK_END

    try {
      caps.gaiaRoot = await findGaiaRoot($)
    } catch (_) { caps.gaiaRoot = null }

    if (caps.gaiaRoot) {
      // What is on disk now, so the first render has data.
      try { await refresh($) } catch (err) { log($, 'initial read failed: ' + errText(err)) }
      // The first snapshot run is the process probe. It is not awaited, so a
      // slow build never delays the first prompt; caps.process is set when it
      // settles.
      runSnapshotAndRefresh($).catch(function (err) {
        caps.process = false
        log($, 'snapshot probe failed: ' + errText(err))
      })
    }

    // Reconcile paneOpen with the runtime after a module reload.
    try {
      var panes = await $.ui.panes()
      paneOpen = panes.some(function (p) { return p.id === 'sprint-status' })
    } catch (_) { /* panes unavailable */ }

    return next(e)
  })

  on('command.run', { command: 'sprint' }, async ($) => {
    try {
      if (!caps.gaiaRoot) return { text: NO_SPRINT }
      // Refresh first: a snapshot when one can run (or is already running),
      // else a plain re-read of the cache.
      if (caps.process || inFlight) {
        await runSnapshotAndRefresh($)
      } else {
        await refresh($)
      }
      if (!cachedData || !cachedData.sprint || cachedData.sprint.status === 'closed') {
        return { text: NO_SPRINT }
      }
      return {}
    } catch (err) {
      // Never show error text to the user.
      log($, 'sprint command failed: ' + errText(err))
      return { text: NO_SPRINT }
    }
  })

  on('ui.render', { component: 'Pane', requestId: 'sprint-status' }, async ($, e, next) => {
    if (!caps.process || !caps.gaiaRoot) return next(e)
    // Cache absent or not read yet: no sprint, nothing to draw.
    if (cacheState === 'init' || cacheState === 'absent') return next(e)
    // Cache present but unparseable.
    if (cacheState === 'error' || cachedData === null) {
      var components = $.ui.resolve(e)
      return h(components.Box, { flexDirection: 'column' },
        h(components.Text, null, 'Sprint data unavailable'))
    }
    if (!cachedData.sprint || cachedData.sprint.status === 'closed') return next(e)
    // The active sprint view is drawn by the sidebar rendering.
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    // Keeps what other mods draw in the band.
    return await next(e)
  })

  on('ui.close', { id: 'sprint-status' }, async ($, e, next) => {
    paneOpen = false
    return next(e)
  }).catch(($, e, next) => {
    paneOpen = false
    return next(e)
  })
}
