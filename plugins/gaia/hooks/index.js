import { sanitizeCache } from './sanitize.js'

// -- module-level state (reset on reload) --
let caps = { command: false, clock: false, process: false, gaiaRoot: null }
let cachedData = null
let cacheState = 'init' // 'init' | 'absent' | 'error' | 'loaded'
let cacheMtimeMs = 0
let inFlightPromise = null
let paneOpen = false
let cancelTimer = null

// -- helpers --

function joinPath(root, ...segments) {
  return [root, ...segments].join('/')
}

function log($, msg) {
  try { $.ui.log(msg, { to: 'debug' }) } catch (_) { /* stripped build */ }
}

async function readCache($) {
  try {
    var cachePath = joinPath(caps.gaiaRoot, '.gaia', 'state', '.sprint-progress-cache.json')
    var stat
    try {
      stat = await $.fs.stat(cachePath)
    } catch (_) {
      // File does not exist
      return { data: null, mtimeMs: 0, status: 'absent' }
    }
    var raw = await $.fs.read(cachePath)
    var data = JSON.parse(raw)

    // Sanitize all dynamic text fields via the exported pure function
    sanitizeCache(data)

    return { data: data, mtimeMs: stat.mtimeMs, status: 'ok' }
  } catch (err) {
    log($, 'cache read failed: ' + String(err && err.message ? err.message : err))
    return { data: null, mtimeMs: 0, status: 'error' }
  }
}

async function runSnapshot($) {
  // MARKER:SNAPSHOT_TRY -- do not remove (mutant-kill anchor for process probe)
  var result = await $.process.run([joinPath($.plugin.root, 'scripts', 'sprint-progress-snapshot.sh')], {
    cwd: caps.gaiaRoot, env: { PROJECT_ROOT: caps.gaiaRoot }, timeoutMs: 30000
  })
  if (result.exitCode !== 0) {
    log($, 'snapshot exited ' + result.exitCode)
  }
}

async function refresh($) {
  var r = await readCache($)
  if (r.status === 'ok') {
    cachedData = r.data
    cacheMtimeMs = r.mtimeMs
    cacheState = 'loaded'
  } else if (r.status === 'absent') {
    cachedData = null
    cacheState = 'absent'
  } else {
    // Parse error -- wipe cached data even if a previous good value existed
    cachedData = null
    cacheState = 'error'
  }
}

// Single-flight snapshot + refresh. All callers join the same promise.
function runSnapshotAndRefresh($) {
  if (inFlightPromise) return inFlightPromise
  inFlightPromise = (async () => {
    try {
      await runSnapshot($)
      await refresh($)
      try { $.ui.invalidate('ui.render') } catch (_) { /* stripped build */ }
    } finally {
      inFlightPromise = null
    }
  })()
  return inFlightPromise
}

function maybeRebuild($, now) {
  if (caps.gaiaRoot === null) return
  if (inFlightPromise) return // MARKER:INFLIGHT_GUARD
  if (cacheMtimeMs > now || now - cacheMtimeMs <= 60000) return // MARKER:STALENESS_GUARD
  // Fire and forget -- errors are logged, not propagated
  runSnapshotAndRefresh($).catch(function (err) {
    log($, 'rebuild failed: ' + String(err && err.message ? err.message : err))
  })
}

// Read-only accessor for pane-open state (consumed by S6 rendering and tests).
export function getPaneOpen() { return paneOpen }

// -- registration --

export function register(on) {
  on('session.start', async ($, e, next) => {
    // Session re-entry: reset state and cancel previous timer
    if (cancelTimer) {
      try { cancelTimer() } catch (_) { /* ignore */ }
      cancelTimer = null
    }
    caps = { command: false, clock: false, process: false, gaiaRoot: null }
    cachedData = null
    cacheState = 'init'
    cacheMtimeMs = 0
    inFlightPromise = null
    paneOpen = false

    // Capability detection via try/catch
    try { // MARKER:CAP_DETECT_CMD
      await $.command.register({ name: 'sprint', description: 'Toggle sprint dashboard' })
      caps.command = true
    } catch (_) { caps.command = false } // MARKER:CAP_DETECT_CMD_END

    try { // MARKER:CAP_DETECT_CLK
      cancelTimer = $.clock.every(30000, async () => {
        if (caps.gaiaRoot === null) return // MARKER:TIMER_GAIA_GUARD
        try {
          await refresh($)
          var now = await $.clock.now()
          maybeRebuild($, now)
        } catch (_) { /* timer error */ }
      })
      caps.clock = true
    } catch (_) { caps.clock = false } // MARKER:CAP_DETECT_CLK_END

    // GAIA root detection
    try {
      var root = await $.session.root()
      var dir = root
      while (dir && dir !== '/') {
        try {
          var exists = await $.fs.exists(joinPath(dir, '.gaia'))
          if (exists) {
            caps.gaiaRoot = dir
            break
          }
        } catch (_) { break }
        var parent = dir.replace(/\/[^/]+$/, '') || '/'
        if (parent === dir) break
        dir = parent
      }
      if (!caps.gaiaRoot && dir === '/') {
        try {
          var rootExists = await $.fs.exists(joinPath('/', '.gaia'))
          if (rootExists) caps.gaiaRoot = '/'
        } catch (_) { /* skip */ }
      }
    } catch (_) { /* session.root failed */ }

    // Snapshot invocation is the process probe (only when gaiaRoot is set)
    if (caps.gaiaRoot) {
      try { // MARKER:PROCESS_PROBE
        await runSnapshot($)
        caps.process = true
      } catch (_) { caps.process = false } // MARKER:PROCESS_PROBE_END

      // Initial cache read
      await refresh($)
    }

    // Reconcile paneOpen
    try {
      var panes = await $.ui.panes()
      paneOpen = panes.some(function (p) { return p.id === 'sprint-status' })
    } catch (_) { /* panes unavailable */ }

    return next(e)
  })

  on('command.run', { command: 'sprint' }, async ($) => {
    if (!caps.gaiaRoot) return { text: 'No active sprint' }

    if (caps.process) {
      try {
        await runSnapshotAndRefresh($)
      } catch (err) {
        log($, 'sprint command snapshot failed: ' + String(err && err.message ? err.message : err))
      }
    } else {
      try { await refresh($) } catch (_) { /* ignore */ }
    }

    if (!cachedData || !cachedData.sprint || cachedData.sprint.status === 'closed') {
      return { text: 'No active sprint' }
    }

    return {}
  })

  on('ui.render', { component: 'Pane', requestId: 'sprint-status' }, async ($, e, next) => {
    if (!caps.process || !caps.gaiaRoot) return next(e)
    // Cache file absent or never checked -- sprint not present, pane not rendered
    if (cacheState === 'init' || cacheState === 'absent') return next(e)
    // Cache exists but unparseable -- show unavailable even if a prior good value existed
    if (cacheState === 'error' || cachedData === null) {
      var components = $.ui.resolve(e)
      return h(components.Box, { flexDirection: 'column' },
        h(components.Text, null, 'Sprint data unavailable'))
    }
    if (!cachedData.sprint || cachedData.sprint.status === 'closed') return next(e)
    // Placeholder for S6: active sprint view
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
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
