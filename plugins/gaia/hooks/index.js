import { sanitize, sanitizeCache, TITLE_MAX, MESSAGE_MAX, COMMAND_MAX, GOAL_MAX,
  BLOCKED_BY_MAX, DRIFT_DETAIL_MAX, TASK_TEXT_MAX, GATE_NAME_MAX } from './sanitize.js'
import { computeAgentActivity } from './agent-activity.js'

// -- tuning --
var TICK_MS = 30000          // interval timer period
var STALE_MS = 60000         // a cache older than this is rebuilt
var BACKOFF_MAX_MS = 300000  // longest wait after runs that left the cache untouched
var NO_SPRINT = 'No active sprint'

// -- module-level state (reset on reload) --
var caps = { command: false, clock: false, process: false, agent: false, gaiaRoot: null }
var cachedData = null
var cacheState = 'init' // 'init' | 'absent' | 'error' | 'loaded'
var cacheMtimeMs = 0
var cacheStatKey = ''   // mtime + size of the file behind cachedData / cacheState
var inFlight = null     // { root, promise } of the one snapshot that may run
var paneOpen = false
var timerHandle = null
var unchangedRuns = 0   // consecutive snapshot runs that did not move the cache
var backoffUntil = 0
var selectedStoryKey = null
var envNoColor = false
var envAscii = false

// -- exports for the agent-activity module to populate --
export var activityByStory = new Map()
export var unlinkedActivity = { items: [], overflow: 0 }

// -- status rendering constants --
var STATUS_COLORS = {
  done: 'green', review: 'blue', 'in-progress': 'yellow',
  blocked: 'red', 'ready-for-dev': 'gray', ready: 'gray', backlog: 'dim', validating: 'dim'
}
var STATUS_GLYPHS = {
  done: '✓', review: '☉', 'in-progress': '◑',
  blocked: '✕', 'ready-for-dev': '·', ready: '·', backlog: '–', validating: '–'
}
var STATUS_GLYPHS_ASCII = {
  done: '[x]', review: '[o]', 'in-progress': '[~]',
  blocked: '[!]', 'ready-for-dev': '[-]', ready: '[-]', backlog: '[ ]', validating: '[ ]'
}
var STAGE_GLYPHS = { done: '✓', current: '◌', 'not-yet': '○' }
var STAGE_GLYPHS_ASCII = { done: '[x]', current: '[.]', 'not-yet': '[ ]' }
var FILLED_BLOCK = '█'
var PACE_LABELS = {
  'on-pace': 'on pace', 'behind-pace': 'behind pace',
  overdue: 'overdue', starting: 'starting'
}

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

// -- concurrent sprint state --
var concurrentPlusN = 0       // count of other non-closed sprints
var concurrentBoundId = null   // bound sprint ID (null = unbound)
var concurrentClosedLabel = false  // true when the bound sprint is closed

async function readCache($, root) {
  try {
    // In concurrent mode, prefer the per-sprint cache for the bound sprint.
    var cachePath = joinPath(root, '.gaia', 'state', '.sprint-progress-cache.json')
    var stateDir = joinPath(root, '.gaia', 'state')

    // Reset concurrent state.
    concurrentPlusN = 0
    concurrentBoundId = null
    concurrentClosedLabel = false

    // Check for per-sprint cache files (concurrent mode indicator).
    var hasPerSprint = false
    try {
      var dirEntries = await $.fs.list(stateDir)
      for (var i = 0; i < dirEntries.length; i++) {
        var entry = dirEntries[i]
        var name = typeof entry === 'string' ? entry : (entry.name || '')
        if (/^\.sprint-progress-cache-[A-Za-z0-9][A-Za-z0-9._-]*\.json$/.test(name)) {
          hasPerSprint = true
          break
        }
      }
    } catch (_) { /* fs.list may not be available */ }

    if (hasPerSprint) {
      // Resolve bound sprint by reading the binding file directly (no
      // subprocess -- the static audit allows only the snapshot script
      // in process.run).  The binding file lives at
      // .gaia/state/sessions/{session_id}/bound_sprint_id.
      try {
        var sessionId = null
        try { sessionId = await $.env.get('GAIA_SESSION_ID') } catch (_) { sessionId = null }
        if (!sessionId) {
          try { sessionId = await $.session.id() } catch (_) { sessionId = null }
        }

        if (sessionId && /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(sessionId)) {
          var bindingPath = joinPath(stateDir, 'sessions', sessionId, 'bound_sprint_id')
          var boundId = null
          try {
            boundId = (await $.fs.read(bindingPath)).trim()
          } catch (_) { boundId = null }

          if (boundId && /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(boundId)) {
            // Check sprint status from per-sprint cache.
            var perCacheName = '.sprint-progress-cache-' + boundId + '.json'
            var perCache = stateDir + '/' + perCacheName
            var boundStatus = null
            try {
              var pcRaw = await $.fs.read(perCache)
              var pcObj = JSON.parse(pcRaw)
              boundStatus = pcObj && pcObj.sprint ? pcObj.sprint.status : null
            } catch (_) { /* per-sprint cache missing */ }

            if (boundStatus === 'closed') {
              // Bound sprint closed: render read-only labelled closed, no +N.
              concurrentBoundId = boundId
              concurrentClosedLabel = true
            } else if (boundStatus) {
              // Bound sprint active/review/correction.
              concurrentBoundId = boundId
              try {
                await $.fs.stat(perCache)
                cachePath = perCache
              } catch (_) { /* use proxy */ }

              // Count other non-closed per-sprint caches for +N.
              try {
                var entries = await $.fs.list(stateDir)
                for (var j = 0; j < entries.length; j++) {
                  var ename = typeof entries[j] === 'string' ? entries[j] : (entries[j].name || '')
                  var em = ename.match(/^\.sprint-progress-cache-([A-Za-z0-9][A-Za-z0-9._-]*)\.json$/)
                  if (!em) continue
                  if (em[1] === boundId) continue
                  try {
                    var eRaw = await $.fs.read(stateDir + '/' + ename)
                    var eData = JSON.parse(eRaw)
                    if (eData && eData.sprint && eData.sprint.status === 'closed') continue
                  } catch (_) { continue }
                  concurrentPlusN++
                }
              } catch (_) { /* count failed */ }
            }
            // else: no per-sprint cache, use proxy (unbound-like).
          }
          // else: no valid binding, single-sprint rendering.
        }
      } catch (err) {
        log($, 'binding resolution failed: ' + errText(err))
      }
    }

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
      // Close the pane when the sprint becomes inactive during the session.
      if (paneOpen && (!cachedData || !cachedData.sprint || cachedData.sprint.status === 'closed')) {
        try { await $.ui.close({ id: 'sprint-status' }) } catch (_) { /* already closed */ }
        paneOpen = false
      }
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

// Refresh agent activity from $.agent.list(). Called on every timer tick.
// Fills the module-level exports that S6's render code reads.
async function refreshAgentActivity($) {
  var agents
  try {
    agents = await $.agent.list()
    caps.agent = true
  } catch (_) {
    caps.agent = false
    activityByStory = new Map()
    unlinkedActivity = { items: [], overflow: 0 }
    return
  }

  // Collect story keys from the cache for linked-vs-unlinked classification.
  var storyKeys = new Set()
  if (cachedData && cachedData.stories) {
    for (var i = 0; i < cachedData.stories.length; i++) {
      if (cachedData.stories[i].key) storyKeys.add(cachedData.stories[i].key)
    }
  }

  var result = computeAgentActivity({
    agents: agents,
    storyKeys: storyKeys
  })

  activityByStory = result.activityByStory
  unlinkedActivity = result.unlinkedActivity
}

// Read-only accessors for the sidebar rendering and the tests.
export function getPaneOpen() { return paneOpen }
export function getCacheView() { return cachedData }

// -- toggle --

async function toggle($, withFocus) {
  try {
    var panes = await $.ui.panes()
    var placed = panes.some(function (p) { return p.id === 'sprint-status' && p.isPlaced !== false })
    if (placed) {
      await $.ui.close({ id: 'sprint-status' })
      paneOpen = false
    } else {
      var result = await $.ui.open({ id: 'sprint-status', title: 'Sprint', closeOnEscape: true, focus: withFocus })
      if (result && typeof result === 'object' && 'isPlaced' in result) {
        paneOpen = result.isPlaced
      } else {
        // Older builds return void; check panes() to determine placement.
        var p2 = await $.ui.panes()
        paneOpen = p2.some(function (p) { return p.id === 'sprint-status' })
      }
    }
    try { $.ui.invalidate('ui.render') } catch (_) { /* stripped build */ }
  } catch (_) { /* toggle failed silently */ }
}

// -- rendering helpers --

function statusGlyph(status) {
  if (envAscii) return STATUS_GLYPHS_ASCII[status] || STATUS_GLYPHS_ASCII.backlog
  return STATUS_GLYPHS[status] || STATUS_GLYPHS.backlog
}

function stageGlyph(stage) {
  if (envAscii) return STAGE_GLYPHS_ASCII[stage] || STAGE_GLYPHS_ASCII['not-yet']
  return STAGE_GLYPHS[stage] || STAGE_GLYPHS['not-yet']
}

function statusColor(status) {
  if (envNoColor) return undefined
  return STATUS_COLORS[status] || STATUS_COLORS.backlog
}

function warnColor() { return envNoColor ? undefined : 'red' }
function dimColor() { return envNoColor ? undefined : 'dim' }
function greenColor() { return envNoColor ? undefined : 'green' }

function sortByPhase(stories) {
  return stories.slice().sort(function (a, b) {
    var pa = a.phase != null ? a.phase : 999999
    var pb = b.phase != null ? b.phase : 999999
    return pa - pb
  })
}

function mergedActionList(data) {
  var actions = (data.action_needed || []).slice()
  actions.sort(function (a, b) { return (a.rule || '').localeCompare(b.rule || '') })
  return actions
}

function driftForStory(data, key) {
  if (!data.drift || !data.drift.length) return null
  for (var i = 0; i < data.drift.length; i++) {
    if (data.drift[i].story_key === key) return data.drift[i]
  }
  return null
}

function isHighRisk(story) { return story.risk_level === 'high' }

function readyToMarkDone(story) {
  if (story.status !== 'review') return false
  if (!story.gates || story.gates.passed !== story.gates.total || story.gates.total !== 6) return false
  if (story.manual_test && story.manual_test.required) {
    return story.manual_test.verdict === 'PASSED'
  }
  return true
}

function sepLine(c) {
  return h(c.Text, { color: dimColor() }, '─'.repeat(40))
}

function computeStages(story) {
  var status = story.status || 'backlog'
  if (status === 'done') return ['done', 'done', 'done', 'done']
  if (status === 'review') return ['done', 'done', 'current', 'not-yet']
  if (status === 'in-progress' || status === 'blocked') return ['done', 'current', 'not-yet', 'not-yet']
  if (status === 'ready-for-dev' || status === 'ready') return ['current', 'not-yet', 'not-yet', 'not-yet']
  return ['not-yet', 'not-yet', 'not-yet', 'not-yet']
}

// -- sidebar section renderers --
// Each returns an h() element tree. All read only from in-memory data.

function renderBanner(c, data) {
  var actions = mergedActionList(data)
  if (!actions.length) return null
  var items = []
  for (var i = 0; i < actions.length; i++) {
    var a = actions[i]
    var msg = sanitize(a.message || '', MESSAGE_MAX)
    var cmd = sanitize(a.command || '', COMMAND_MAX)
    var since = a.since ? sanitize(String(a.since), TITLE_MAX) : null
    var children = [h(c.Text, { key: 'am-' + i, color: warnColor(), bold: true }, ' ' + msg)]
    if (cmd) children.push(h(c.Text, { key: 'ac-' + i, color: dimColor() }, '  → ' + cmd))
    if (since) children.push(h(c.Text, { key: 'as-' + i, color: dimColor() }, '  since ' + since))
    items.push(h(c.Box, { key: 'an-' + i, flexDirection: 'column' }, ...children))
  }
  return h(c.Box, { flexDirection: 'column' },
    h(c.Text, { color: warnColor(), bold: true }, '⚠ ACTION NEEDED'),
    ...items
  )
}

function renderHeader(c, data) {
  var sprint = data.sprint
  var id = sanitize(sprint.id || '', TITLE_MAX)
  var goal = sanitize(sprint.goal || '', GOAL_MAX)
  // Append +N indicator in concurrent mode.
  var plusNSuffix = concurrentPlusN > 0 ? '  +' + concurrentPlusN : ''
  var liveLabel = concurrentClosedLabel ? 'closed' : '● live'
  var liveColor = concurrentClosedLabel ? dimColor() : greenColor()
  return h(c.Box, { flexDirection: 'column' },
    h(c.Box, { flexDirection: 'row' },
      h(c.Text, { bold: true }, 'SPRINT  ' + id + plusNSuffix + '  '),
      h(c.Text, { color: liveColor }, liveLabel)
    ),
    goal ? h(c.Text, { wrap: 'wrap' }, goal) : null
  )
}

function renderAggregate(c, data) {
  var t = data.totals || {}
  var done = t.done_stories || 0
  var total = t.total_stories || 0
  var donePts = t.done_points || 0
  var totalPts = t.total_points || 0
  var pct = t.progress_pct != null ? t.progress_pct : 0
  return h(c.Text, null,
    done + ' of ' + total + ' stories · ' +
    donePts + ' of ' + totalPts + ' pts · ' + pct + '%')
}

function safePoints(v) {
  if (typeof v !== 'number' || !isFinite(v) || v < 0) return 0
  return v
}

var BAR_STATUS_ORDER = ['done', 'review', 'in-progress', 'blocked', 'ready-for-dev', 'ready', 'backlog', 'validating']

function buildBarSegments(stories, availCols) {
  if (!stories || !stories.length || availCols < 1) return []
  var cols = Math.min(availCols, 500)
  // Sum points per status, in the canonical display order.
  var pointsByStatus = {}
  var totalPts = 0
  for (var i = 0; i < stories.length; i++) {
    var st = stories[i].status || 'backlog'
    var pts = safePoints(stories[i].points)
    // Map unknown statuses into backlog/dim.
    if (!STATUS_COLORS[st]) st = 'backlog'
    pointsByStatus[st] = (pointsByStatus[st] || 0) + pts
    totalPts += pts
  }
  // Build one segment per present status, in canonical order.
  var segs = []
  for (var o = 0; o < BAR_STATUS_ORDER.length; o++) {
    var status = BAR_STATUS_ORDER[o]
    if (pointsByStatus[status] == null) continue
    var w = totalPts > 0
      ? Math.max(1, Math.floor(pointsByStatus[status] / totalPts * cols))
      : 1
    segs.push({ status: status, width: Math.min(w, cols) })
  }
  if (!segs.length) return []
  // Fit to available columns.
  var usedCols = 0
  for (var n = 0; n < segs.length; n++) usedCols += segs[n].width
  var idx = 0
  while (usedCols < cols && segs.length > 0) {
    segs[idx % segs.length].width++
    usedCols++
    idx++
  }
  while (usedCols > cols) {
    var wide = -1
    for (var k = segs.length - 1; k >= 0; k--) {
      if (segs[k].width > 1 && (wide === -1 || segs[k].width > segs[wide].width)) wide = k
    }
    if (wide === -1) break
    segs[wide].width--
    usedCols--
  }
  return segs
}

function presentStatuses(stories) {
  var present = {}
  for (var i = 0; i < stories.length; i++) {
    var st = stories[i].status || 'backlog'
    if (!STATUS_COLORS[st]) st = 'backlog'
    present[st] = true
  }
  return present
}

function renderBar(c, data, bodyColumns) {
  var stories = data.stories || []
  if (!stories.length) return null
  var cols = bodyColumns || 40
  var present = presentStatuses(stories)

  if (envNoColor) {
    // Text-only fallback: show counts per status.
    var counts = {}
    for (var j = 0; j < stories.length; j++) {
      var st = stories[j].status || 'backlog'
      if (!STATUS_COLORS[st]) st = 'backlog'
      counts[st] = (counts[st] || 0) + 1
    }
    var parts = []
    for (var k = 0; k < BAR_STATUS_ORDER.length; k++) {
      if (counts[BAR_STATUS_ORDER[k]]) parts.push(counts[BAR_STATUS_ORDER[k]] + ' ' + BAR_STATUS_ORDER[k])
    }
    return h(c.Text, null, parts.join(' · '))
  }

  var segs = buildBarSegments(stories, cols)
  if (!segs.length) return null
  var barChildren = []
  for (var s = 0; s < segs.length; s++) {
    barChildren.push(
      h(c.Text, { key: 'bar-' + s, color: statusColor(segs[s].status) },
        FILLED_BLOCK.repeat(segs[s].width))
    )
  }
  // Colour key: one entry per present status with a coloured filled block + name.
  // ASCII mode uses ASCII markers instead of the filled block glyph.
  var keyChildren = []
  for (var l = 0; l < BAR_STATUS_ORDER.length; l++) {
    if (present[BAR_STATUS_ORDER[l]]) {
      if (keyChildren.length > 0) keyChildren.push(h(c.Text, { key: 'ksep-' + l }, '  '))
      if (envAscii) {
        keyChildren.push(
          h(c.Text, { key: 'kb-' + l }, STATUS_GLYPHS_ASCII[BAR_STATUS_ORDER[l]] + ' ' + BAR_STATUS_ORDER[l])
        )
      } else {
        keyChildren.push(
          h(c.Text, { key: 'kb-' + l, color: statusColor(BAR_STATUS_ORDER[l]) }, FILLED_BLOCK)
        )
        keyChildren.push(h(c.Text, { key: 'kn-' + l }, ' ' + BAR_STATUS_ORDER[l]))
      }
    }
  }
  return h(c.Box, { flexDirection: 'column' },
    h(c.Box, { flexDirection: 'row' }, ...barChildren),
    h(c.Box, { flexDirection: 'row' }, ...keyChildren)
  )
}

function renderSubLine(c, data) {
  var parts = []
  if (data.active_phase != null) {
    var totalPhases = (data.phases || []).length
    parts.push('Phase ' + data.active_phase + (totalPhases ? ' of ' + totalPhases : ''))
  }
  var d = data.day || {}
  if (d.current != null) {
    var dayStr = 'Day ' + (d.current + 1)
    if (d.total != null) dayStr += ' of ' + d.total
    parts.push(dayStr)
  }
  if (d.pace) parts.push(PACE_LABELS[d.pace] || d.pace)
  // Count blocked stories.
  var blocked = 0
  var stories = data.stories || []
  for (var i = 0; i < stories.length; i++) {
    if (stories[i].status === 'blocked') blocked++
  }
  parts.push(blocked + ' blocked')
  var children = []
  for (var j = 0; j < parts.length; j++) {
    if (j > 0) children.push(h(c.Text, { key: 'ssep-' + j }, ' · '))
    var isOverdue = d.pace === 'overdue' && parts[j] === 'overdue'
    var isBlocked = j === parts.length - 1 && blocked > 0
    children.push(
      h(c.Text, { key: 'sub-' + j, color: (isOverdue || isBlocked) ? warnColor() : undefined }, parts[j])
    )
  }
  return h(c.Box, { flexDirection: 'row' }, ...children)
}

function renderReadiness(c, data) {
  var r = data.readiness || {}
  var children = []
  children.push(h(c.Text, null,
    'Ready for sprint review  ' + (r.sprint_review ? '( yes )' : '( no )')))
  children.push(h(c.Text, null,
    'Ready to close sprint   ' + (r.sprint_close ? '( yes )' : '( no )')))
  // Ready-to-mark-done flag.
  var readyCount = 0
  var waitingManual = 0
  var stories = data.stories || []
  for (var i = 0; i < stories.length; i++) {
    if (readyToMarkDone(stories[i])) readyCount++
    if (stories[i].status === 'review' && stories[i].gates &&
        stories[i].gates.passed === 6 && stories[i].gates.total === 6 &&
        stories[i].manual_test && stories[i].manual_test.required &&
        stories[i].manual_test.verdict !== 'PASSED') {
      waitingManual++
    }
  }
  if (readyCount > 0) {
    children.push(h(c.Text, { color: greenColor() },
      readyCount + ' stor' + (readyCount === 1 ? 'y' : 'ies') + ' ready to mark done'))
  }
  if (waitingManual > 0) {
    children.push(h(c.Text, { color: warnColor() },
      '⚠ ' + waitingManual + ' stor' + (waitingManual === 1 ? 'y' : 'ies') +
      ' gates 6/6 — waiting on manual test'))
  }
  // Drift/waiting line under pills — shown only when drift entries exist.
  var driftArr = data.drift || []
  if (driftArr.length > 0) {
    var dLine = '⚠ ' + driftArr.length + ' drift'
    var firstDetail = sanitize(String(driftArr[0].detail || ''), DRIFT_DETAIL_MAX)
    if (firstDetail) dLine += ': ' + firstDetail
    if (driftArr.length > 1) dLine += ' +' + (driftArr.length - 1) + ' more'
    children.push(h(c.Text, { color: warnColor() }, dLine))
  }
  return h(c.Box, { flexDirection: 'column' }, ...children)
}

function renderNowRow(c, story, data, onPress) {
  var glyph = statusGlyph(story.status)
  var key = story.key || ''
  var slug = story.slug || ''
  var tasks = story.tasks || {}
  var gates = story.gates || {}
  var line = glyph + ' ' + key + ' ' + slug
  line += '  tasks ' + (tasks.done || 0) + '/' + (tasks.total || 0)
  line += '  gates ' + (gates.passed || 0) + '/' + (gates.total || 6)
  if (story.blocked_by) {
    var bb = sanitize(story.blocked_by, BLOCKED_BY_MAX)
    line += '  blocked → ' + bb + (story.blocked_since ? ' since ' + story.blocked_since : '')
  }
  var drift = driftForStory(data, key)
  if (drift) line += ' ⚠ drift'
  if (isHighRisk(story)) line += ' HIGH'
  var rowChildren = [
    h(c.Button, { key: 'now-' + key, plain: true, onPress: onPress },
      h(c.Text, { color: statusColor(story.status), wrap: 'truncate-end' }, ' ' + line))
  ]
  // Agent activity sub-lines from the agent-activity module.
  var activity = activityByStory.get(key)
  if (activity && activity.items && activity.items.length > 0) {
    for (var a = 0; a < activity.items.length; a++) {
      rowChildren.push(h(c.Text, { key: 'act-' + key + '-' + a, color: dimColor() },
        '   → ' + (activity.items[a].label || 'agent') + ' ' + (activity.items[a].status || '')))
    }
    if (activity.overflow > 0) {
      rowChildren.push(h(c.Text, { key: 'act-' + key + '-more', color: dimColor() },
        '   +' + activity.overflow + ' more'))
    }
  }
  return h(c.Box, { key: 'nowr-' + key, flexDirection: 'column' }, ...rowChildren)
}

function renderNow(c, data, $) {
  var stories = data.stories || []
  var active = []
  for (var i = 0; i < stories.length; i++) {
    var st = stories[i].status
    if (st === 'in-progress' || st === 'review' || st === 'blocked') active.push(stories[i])
  }
  var children = [h(c.Text, { bold: true }, 'NOW')]
  if (active.length === 0) {
    children.push(h(c.Text, { color: dimColor() }, ' No active work'))
    // Unlinked agent activity.
    if (unlinkedActivity.items && unlinkedActivity.items.length > 0) {
      for (var u = 0; u < unlinkedActivity.items.length; u++) {
        children.push(h(c.Text, { key: 'uact-' + u, color: dimColor() },
          '  → ' + (unlinkedActivity.items[u].label || 'agent') + ' ' +
          (unlinkedActivity.items[u].status || '')))
      }
      if (unlinkedActivity.overflow > 0) {
        children.push(h(c.Text, { key: 'uact-more', color: dimColor() },
          '  +' + unlinkedActivity.overflow + ' more'))
      }
    }
    return h(c.Box, { flexDirection: 'column' }, ...children)
  }
  for (var j = 0; j < active.length; j++) {
    var story = active[j]
    children.push(renderNowRow(c, story, data, (function (k) {
      return function () {
        selectedStoryKey = selectedStoryKey === k ? null : k
        try { $.ui.invalidate('ui.render') } catch (_) { /* stripped build */ }
      }
    })(story.key)))
  }
  // Unlinked agent activity.
  if (unlinkedActivity.items && unlinkedActivity.items.length > 0) {
    for (var v = 0; v < unlinkedActivity.items.length; v++) {
      children.push(h(c.Text, { key: 'uact-' + v, color: dimColor() },
        '  → ' + (unlinkedActivity.items[v].label || 'agent') + ' ' +
        (unlinkedActivity.items[v].status || '')))
    }
    if (unlinkedActivity.overflow > 0) {
      children.push(h(c.Text, { key: 'uact-more', color: dimColor() },
        '  +' + unlinkedActivity.overflow + ' more'))
    }
  }
  return h(c.Box, { flexDirection: 'column' }, ...children)
}

function renderGlyphLegend(c, data) {
  var stories = data.stories || []
  var present = presentStatuses(stories)
  if (envAscii) {
    var asciiParts = []
    for (var i = 0; i < BAR_STATUS_ORDER.length; i++) {
      if (present[BAR_STATUS_ORDER[i]]) {
        asciiParts.push(STATUS_GLYPHS_ASCII[BAR_STATUS_ORDER[i]] + ' ' + BAR_STATUS_ORDER[i])
      }
    }
    return h(c.Text, { color: dimColor() }, asciiParts.join('  '))
  }
  var parts = []
  for (var j = 0; j < BAR_STATUS_ORDER.length; j++) {
    if (present[BAR_STATUS_ORDER[j]]) {
      parts.push(statusGlyph(BAR_STATUS_ORDER[j]) + ' ' + BAR_STATUS_ORDER[j])
    }
  }
  return h(c.Text, { color: dimColor() }, parts.join('  '))
}

function renderPhaseMatrix(c, data, $) {
  var phases = data.phases || []
  var stories = data.stories || []
  var storyMap = {}
  for (var i = 0; i < stories.length; i++) storyMap[stories[i].key] = stories[i]
  var header = h(c.Text, { color: dimColor() },
    '                         READY  DEV  REVIEW DONE')
  var children = [header]
  // Collapse done phases into a summary line.
  var donePhases = []
  for (var p = 0; p < phases.length; p++) {
    if (phases[p].status === 'done') donePhases.push(phases[p])
  }
  if (donePhases.length > 0) {
    var doneStories = 0
    var donePts = 0
    var minP = donePhases[0].phase
    var maxP = donePhases[donePhases.length - 1].phase
    for (var d = 0; d < donePhases.length; d++) {
      doneStories += (donePhases[d].total_count || 0)
      var dsKeys = donePhases[d].stories || []
      for (var ds = 0; ds < dsKeys.length; ds++) {
        var dStory = storyMap[dsKeys[ds]]
        if (dStory) donePts += (dStory.points || 0)
      }
    }
    var rangeStr = donePhases.length === 1 ? 'Phase ' + minP : 'Phases ' + minP + '–' + maxP
    children.push(h(c.Text, { color: greenColor() },
      stageGlyph('done') + ' ' + rangeStr + ' · ' + doneStories + ' stories · ' + donePts + ' pts'))
  }
  // Active and future phases.
  for (var q = 0; q < phases.length; q++) {
    var phase = phases[q]
    if (phase.status === 'done') continue
    var isActive = phase.status === 'active'
    var phColor = isActive ? undefined : dimColor()
    var phLabel = 'PHASE ' + phase.phase + (isActive ? ' (active)' : '')
    if (!isActive) {
      var phStories = phase.stories || []
      var slugs = []
      for (var fs = 0; fs < phStories.length && fs < 5; fs++) slugs.push(phStories[fs])
      if (phStories.length > 5) slugs.push('...')
      children.push(h(c.Text, { color: phColor }, phLabel + '  ' + slugs.join(' · ')))
      continue
    }
    children.push(h(c.Text, { bold: true }, phLabel))
    var phaseStories = phase.stories || []
    for (var as = 0; as < phaseStories.length; as++) {
      var aStory = storyMap[phaseStories[as]]
      if (!aStory) continue
      var stages = computeStages(aStory)
      var stageStr = stages.map(function (sg) { return stageGlyph(sg) }).join('    ')
      var highMark = isHighRisk(aStory) ? ' HIGH' : ''
      var title = sanitize(aStory.title || '', TITLE_MAX)
      children.push(
        h(c.Button, {
          key: 'mx-' + (aStory.key || as),
          plain: true,
          onPress: (function (k) {
            return function () {
              selectedStoryKey = selectedStoryKey === k ? null : k
              try { $.ui.invalidate('ui.render') } catch (_) { /* stripped build */ }
            }
          })(aStory.key)
        }, h(c.Text, { wrap: 'truncate-end' },
          ' ' + (aStory.key || '') + ' ' + title + '   ' + stageStr + highMark))
      )
    }
  }
  // Unphased stories.
  var unphased = data.unphased_stories || []
  if (unphased.length > 0) {
    var upPts = 0
    var upStories = []
    for (var u = 0; u < unphased.length; u++) {
      var uKey = typeof unphased[u] === 'string' ? unphased[u] : (unphased[u].key || '')
      var uStory = storyMap[uKey]
      if (uStory) { upStories.push(uStory); upPts += (uStory.points || 0) }
    }
    var allDone = upStories.length > 0 && upStories.every(function (s) { return s.status === 'done' })
    if (allDone) {
      children.push(h(c.Text, { color: greenColor() },
        stageGlyph('done') + ' Unphased · ' + upStories.length + ' stories · ' + upPts + ' pts'))
    } else if (upStories.length > 0) {
      children.push(h(c.Text, { color: dimColor() },
        'Unphased · ' + upStories.length + ' stories · ' + upPts + ' pts'))
      for (var up = 0; up < upStories.length; up++) {
        var us = upStories[up]
        var uStages = computeStages(us)
        var uStageStr = uStages.map(function (sg) { return stageGlyph(sg) }).join('    ')
        var uHighMark = isHighRisk(us) ? ' HIGH' : ''
        children.push(
          h(c.Button, {
            key: 'mx-up-' + (us.key || up),
            plain: true,
            onPress: (function (k) {
              return function () {
                selectedStoryKey = selectedStoryKey === k ? null : k
                try { $.ui.invalidate('ui.render') } catch (_) { /* stripped build */ }
              }
            })(us.key)
          }, h(c.Text, { wrap: 'truncate-end' },
            ' ' + (us.key || '') + ' ' + sanitize(us.title || '', TITLE_MAX) +
            '   ' + uStageStr + uHighMark))
        )
      }
    }
  }
  return h(c.Box, { flexDirection: 'column' }, ...children)
}

function renderDetail(c, data) {
  if (!selectedStoryKey) return null
  var stories = data.stories || []
  var story = null
  for (var i = 0; i < stories.length; i++) {
    if (stories[i].key === selectedStoryKey) { story = stories[i]; break }
  }
  if (!story) return null
  var children = []
  var title = sanitize(story.title || '', TITLE_MAX)
  var gates = story.gates || {}
  var tasks = story.tasks || {}
  var manual = story.manual_test || {}
  var manualStr = ''
  if (manual.required) {
    manualStr = ' · manual ' + (manual.verdict === 'PASSED' ? stageGlyph('done') : stageGlyph('not-yet'))
  }
  children.push(h(c.Text, { bold: true },
    '▾ ' + (story.key || '') + ' · ' + title +
    ' · gates ' + (gates.passed || 0) + '/' + (gates.total || 6) + manualStr))
  var items = tasks.items || []
  for (var t = 0; t < items.length; t++) {
    var check = items[t].done ? '[x]' : '[ ]'
    var text = sanitize(items[t].text || '', TASK_TEXT_MAX)
    children.push(h(c.Text, { key: 'task-' + t }, '  ' + check + ' ' + text))
  }
  var rows = gates.rows || []
  for (var g = 0; g < rows.length; g++) {
    var gName = sanitize(rows[g].name || '', GATE_NAME_MAX)
    var gStatus = rows[g].status || 'UNVERIFIED'
    var gColor = gStatus === 'PASSED' ? greenColor() : (gStatus === 'FAILED' ? warnColor() : dimColor())
    children.push(h(c.Text, { key: 'gate-' + g, color: gColor }, '  ' + gName + ': ' + gStatus))
  }
  if (manual.required) {
    var mVerdict = manual.verdict || 'pending'
    var mColor = mVerdict === 'PASSED' ? greenColor() : (mVerdict === 'FAILED' ? warnColor() : dimColor())
    children.push(h(c.Text, { color: mColor }, '  Manual test: ' + mVerdict))
  }
  return h(c.Box, { flexDirection: 'column' }, ...children)
}

// -- registration --

export function register(on) {
  on('session.start', async ($, e, next) => {
    // Re-entry: stop the previous timer and start from a clean state. A
    // snapshot still running is kept: the single flight lets it finish.
    stopTimer(timerHandle)
    timerHandle = null
    caps = { command: false, clock: false, process: false, agent: false, gaiaRoot: null }
    activityByStory = new Map()
    unlinkedActivity = { items: [], overflow: 0 }
    cachedData = null
    cacheState = 'init'
    cacheMtimeMs = 0
    cacheStatKey = ''
    paneOpen = false
    selectedStoryKey = null
    unchangedRuns = 0
    backoffUntil = 0

    // Cache environment flags for colour and glyph switches.
    try {
      var ncVal = await $.env.get('NO_COLOR')
      envNoColor = !!(ncVal && ncVal !== '0')
    } catch (_) { envNoColor = false }
    try {
      envAscii = (await $.env.get('GAIA_STATUSLINE_ASCII')) === '1'
    } catch (_) { envAscii = false }

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
          await refreshAgentActivity($)
          var now = await $.clock.now()
          maybeRebuild($, now)
          // Close the pane when the sprint becomes inactive.
          if (paneOpen && (!cachedData || !cachedData.sprint || cachedData.sprint.status === 'closed')) {
            try { await $.ui.close({ id: 'sprint-status' }) } catch (_) { /* already closed */ }
            paneOpen = false
          }
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

      // Auto-open the sidebar when an active sprint is in cache.
      if (cachedData && cachedData.sprint && cachedData.sprint.status !== 'closed') {
        try {
          var openResult = await $.ui.open({ id: 'sprint-status', title: 'Sprint', closeOnEscape: true })
          if (openResult && typeof openResult === 'object' && 'isPlaced' in openResult) {
            paneOpen = openResult.isPlaced
          } else {
            var panesCheck = await $.ui.panes()
            paneOpen = panesCheck.some(function (p) { return p.id === 'sprint-status' })
          }
        } catch (_) { /* auto-open not available */ }
      }
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
      // Toggle the sidebar with focus.
      await toggle($, true)
      return {}
    } catch (err) {
      // Never show error text to the user.
      log($, 'sprint command failed: ' + errText(err))
      return { text: NO_SPRINT }
    }
  })

  on('ui.render', { component: 'Pane', requestId: 'sprint-status' }, async ($, e, next) => {
    if (!caps.process || !caps.gaiaRoot) return next(e)
    // Cache absent or not read yet: show fallback.
    if (cacheState === 'init' || cacheState === 'absent') {
      var ec2 = $.ui.resolve(e)
      return h(ec2.Box, { flexDirection: 'column' },
        h(ec2.Text, null, 'Sprint data unavailable'))
    }
    // Cache present but unparseable.
    if (cacheState === 'error' || cachedData === null) {
      var ec = $.ui.resolve(e)
      return h(ec.Box, { flexDirection: 'column' },
        h(ec.Text, null, 'Sprint data unavailable'))
    }
    if (!cachedData.sprint || cachedData.sprint.status === 'closed') return next(e)

    // Full sidebar dashboard. All data comes from the in-memory cache.
    var c = $.ui.resolve(e)
    var data = cachedData
    var bodyColumns = (e.props && e.props.bodyColumns) || 40
    var sections = []

    // Banner (conditional on non-empty merged action list).
    var banner = renderBanner(c, data)
    if (banner) { sections.push(banner); sections.push(sepLine(c)) }

    // Header and aggregate.
    sections.push(renderHeader(c, data))
    sections.push(renderAggregate(c, data))

    // Segmented bar with legend.
    var bar = renderBar(c, data, bodyColumns)
    if (bar) sections.push(bar)

    // Sub-line: phase, day, pace, blocked.
    sections.push(renderSubLine(c, data))
    sections.push(sepLine(c))

    // Readiness pills.
    sections.push(renderReadiness(c, data))
    sections.push(sepLine(c))

    // NOW block.
    sections.push(renderNow(c, data, $))
    sections.push(sepLine(c))

    // Glyph legend directly above the phase matrix.
    sections.push(renderGlyphLegend(c, data))

    // Phase matrix.
    sections.push(renderPhaseMatrix(c, data, $))

    // Selected story detail.
    var detail = renderDetail(c, data)
    if (detail) { sections.push(sepLine(c)); sections.push(detail) }

    // Pane-level close button: digit 9 closes the pane when it has focus.
    sections.push(h(c.Button, { hotkey: '9', plain: true, onPress: function () { toggle($, false) } }, '9 close'))

    return h(c.Box, { flexDirection: 'column' }, ...sections)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    // Keeps what other mods draw in the band.
    var other = await next(e)
    // No active sprint or null cache: band absent, keep other mods' content.
    if (!cachedData || !cachedData.sprint || cachedData.sprint.status === 'closed') {
      return other
    }
    if (!caps.process || !caps.gaiaRoot) return other

    var c = $.ui.resolve(e)
    var data = cachedData
    var actions = mergedActionList(data)

    if (actions.length > 0) {
      // Warning variant.
      var earliest = actions.reduce(function (m, a) {
        if (!a.since) return m
        return (!m || a.since < m) ? a.since : m
      }, null)
      return h(c.Box, { flexDirection: 'row' },
        other,
        h(c.Button, { hotkey: '9', plain: true, onPress: function () { toggle($, true) } }, '9'),
        h(c.Text, { color: warnColor(), bold: true, wrap: 'truncate-end' },
          ' ⚠ ACTION NEEDED · ' + actions.length + ' item' +
          (actions.length === 1 ? '' : 's') +
          (earliest ? ' since ' + earliest : '') + ' → press 9')
      )
    }

    // Normal summary.
    var t = data.totals || {}
    var donePts = t.done_points || 0
    var totalPts = t.total_points || 0
    var done = t.done_stories || 0
    var total = t.total_stories || 0
    var blocked = 0
    var stories = data.stories || []
    for (var i = 0; i < stories.length; i++) {
      if (stories[i].status === 'blocked') blocked++
    }
    var id = data.sprint.id || ''
    // Append +N indicator in concurrent mode.
    var plusNText = concurrentPlusN > 0 ? ' +' + concurrentPlusN : ''
    return h(c.Box, { flexDirection: 'row' },
      other,
      h(c.Button, { hotkey: '9', plain: true, onPress: function () { toggle($, true) } }, '9'),
      h(c.Text, { wrap: 'truncate-end' },
        ' 9: ' + id + plusNText + ' · ' + donePts + '/' + totalPts + ' pts · ' +
        done + '/' + total + ' done · ' + blocked + ' blocked')
    )
  })

  on('ui.close', { id: 'sprint-status' }, async ($, e, next) => {
    paneOpen = false
    return next(e)
  }).catch(($, e, next) => {
    paneOpen = false
    return next(e)
  })
}
