import { test, expect, mock, describe } from 'claude-code/testing'
import { WRITER_CACHE, GAIA_ROOT, OK_RUN, deepCopy } from './sprint-status-fixture.js'

// Build per-sprint cache content with a given sprint ID and percentage.
function makePerSprintCache(sprintId: string, pct: number) {
  var c = deepCopy(WRITER_CACHE)
  c.sprint.id = sprintId
  c.sprint.status = 'active'
  c.totals.progress_pct = pct
  c.totals.done_points = Math.round(c.totals.total_points * pct / 100)
  c.totals.done_stories = Math.round(c.totals.total_stories * pct / 100)
  return c
}

function concurrentWorld(on: any, opts: any = {}) {
  var boundId = opts.boundId ?? 'sprint-900'
  var otherIds: string[] = opts.otherIds ?? ['sprint-901']
  var closedIds: string[] = opts.closedIds ?? []
  var sessionId = opts.sessionId ?? 'session-abc-123'
  var hasBinding = opts.hasBinding !== false
  var invalidBinding = opts.invalidBinding ?? false

  var allIds = [boundId, ...otherIds].filter(Boolean)
  var dirEntries = allIds.map(function (id: string) { return '.sprint-progress-cache-' + id + '.json' })
  dirEntries.push('.sprint-progress-cache.json')

  var perCaches: Record<string, any> = {}
  for (var i = 0; i < allIds.length; i++) {
    var id = allIds[i]
    var pct = id === boundId ? 65 : 37
    var status = closedIds.indexOf(id) >= 0 ? 'closed' : 'active'
    var cacheObj = makePerSprintCache(id, pct)
    if (status === 'closed') cacheObj.sprint.status = 'closed'
    perCaches['.sprint-progress-cache-' + id + '.json'] = JSON.stringify(cacheObj)
  }
  // Proxy mirrors last-activated (first id).
  var proxyContent = perCaches['.sprint-progress-cache-' + allIds[0] + '.json'] || JSON.stringify(WRITER_CACHE)

  var clock = mock.clock(on, { now: 100000 })
  var w: any = { clock, runs: [] as any[] }

  on('session.start', function (_$: unknown, e: any) { return { cwd: e.cwd } })
  on('session.root', function () { return { value: GAIA_ROOT } })
  on('fs.exists', function (_$: unknown, e: any) { return { value: e.path === GAIA_ROOT + '/.gaia' } })
  on('command.register', function () { return { value: { command: 'sprint' } } })
  on('process.run', function () { w.runs.push(1); return { value: OK_RUN } })

  on('fs.stat', function () {
    return { value: { kind: 'file' as const, size: 1000, mtimeMs: 100000, isLink: false } }
  })

  on('fs.read', function (_$: unknown, e: any) {
    var p: string = e.path || ''
    // Binding file.
    if (p.includes('sessions/') && p.endsWith('bound_sprint_id')) {
      if (!hasBinding) throw new Error('ENOENT')
      if (invalidBinding) return { value: '../../rogue' }
      return { value: boundId }
    }
    // Per-sprint cache files.
    for (var name in perCaches) {
      if (p.endsWith(name)) return { value: perCaches[name] }
    }
    // Proxy.
    if (p.endsWith('.sprint-progress-cache.json')) return { value: proxyContent }
    return { value: proxyContent }
  })

  on('fs.list', function () { return { value: dirEntries } })
  on('ui.panes', function () { return { value: [] } })
  on('ui.open', function () { return { value: { isPlaced: true, reason: 'placed' } } })
  on('ui.close', function () { return { value: undefined } })
  on('ui.log', function () { return { value: undefined } })
  on('ui.invalidate', function () { return { value: undefined } })
  on('env.get', function (_$: unknown, e: any) {
    if (e.name === 'HOME') return { value: '/home/u' }
    if (e.name === 'GAIA_SESSION_ID') return { value: sessionId }
    return { value: '' }
  })
  on('ui.render', { component: 'Pane' }, function ($: any, e: any) {
    return h($.ui.resolve(e).Text, null, 'BOTTOM')
  })
  on('ui.render', { component: 'AbovePrompt' }, function ($: any, e: any) {
    return h($.ui.resolve(e).Text, null, 'OTHER MOD')
  })

  return w
}

async function mountBand($: any) {
  return $.ui.mount({ plugin: 'gaia', surface: 'terminal', component: 'AbovePrompt', props: {} })
}

async function mountPane($: any) {
  return $.ui.mount({ plugin: 'gaia', surface: 'terminal', component: 'Pane', requestId: 'sprint-status',
    props: { bodyColumns: 40, placement: 'dock' } })
}

describe('concurrent sprint band content', () => {
  test('bound sprint shows sprint id and +N in band', async ($, on) => {
    var w = concurrentWorld(on, { boundId: 'sprint-900', otherIds: ['sprint-901'] })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    var ui = await mountBand($)
    // Band must show the bound sprint's id.
    expect(await ui.find({ text: /sprint-900/ })).toBeDefined()
    // Band must show +1 indicator (one other non-closed sprint).
    expect(await ui.find({ text: /\+1/ })).toBeDefined()
    await ui.unmount()
  })

  test('unbound session renders single-sprint without +N', async ($, on) => {
    var w = concurrentWorld(on, { boundId: 'sprint-900', otherIds: ['sprint-901'], hasBinding: false })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    var ui = await mountBand($)
    // Band renders with proxy data (single-sprint).
    expect(await ui.find({ text: /sprint-900/ })).toBeDefined()
    // No +N indicator.
    expect(await ui.find({ text: /\+1/ })).toBeUndefined()
    await ui.unmount()
  })

  test('closed bound sprint renders no pane content (closed filter)', async ($, on) => {
    var w = concurrentWorld(on, { boundId: 'sprint-900', otherIds: [], closedIds: ['sprint-900'] })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    var ui = await mountPane($)
    // A closed sprint renders no sidebar — the render handler returns next(e),
    // so the BOTTOM text from the fallback handler is what appears.
    expect(await ui.find({ text: /SPRINT/ })).toBeUndefined()
    // No +N indicator.
    expect(await ui.find({ text: /\+1/ })).toBeUndefined()
    await ui.unmount()
  })

  test('invalid binding falls back to single-sprint', async ($, on) => {
    var w = concurrentWorld(on, { boundId: 'sprint-900', otherIds: ['sprint-901'], invalidBinding: true })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    var ui = await mountBand($)
    // Falls back to proxy data; no +N.
    expect(await ui.find({ text: /\+1/ })).toBeUndefined()
    await ui.unmount()
  })
})

describe('concurrent sprint sidebar content', () => {
  test('sidebar header shows sprint id with +N suffix', async ($, on) => {
    var w = concurrentWorld(on, { boundId: 'sprint-900', otherIds: ['sprint-901'] })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    var ui = await mountPane($)
    // Header must show the sprint id.
    expect(await ui.find({ text: /SPRINT.*sprint-900/ })).toBeDefined()
    // Header must show +1 suffix.
    expect(await ui.find({ text: /\+1/ })).toBeDefined()
    // Must show "live" (not closed).
    expect(await ui.find({ text: /live/ })).toBeDefined()
    await ui.unmount()
  })

  test('single non-closed sprint shows no +N in sidebar', async ($, on) => {
    // Only one sprint, no others.
    var w = concurrentWorld(on, { boundId: 'sprint-900', otherIds: [] })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    var ui = await mountPane($)
    expect(await ui.find({ text: /SPRINT.*sprint-900/ })).toBeDefined()
    expect(await ui.find({ text: /\+1/ })).toBeUndefined()
    await ui.unmount()
  })
})
