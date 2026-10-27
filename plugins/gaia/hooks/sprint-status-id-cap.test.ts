import { test, expect, mock, describe } from 'claude-code/testing'
import { WRITER_CACHE, GAIA_ROOT, OK_RUN, deepCopy } from './sprint-status-fixture.js'

// Reuse concurrentWorld pattern from sprint-status-concurrent.test.ts but with
// configurable session and bound IDs to exercise the 64-character length cap.
function capWorld(on: any, opts: { sessionId: string; boundId: string }) {
  var boundId = opts.boundId
  var sessionId = opts.sessionId
  var otherIds = ['sprint-901']

  var allIds = [boundId, ...otherIds].filter(Boolean)
  var dirEntries = allIds.map(function (id: string) { return '.sprint-progress-cache-' + id + '.json' })
  dirEntries.push('.sprint-progress-cache.json')

  var perCaches: Record<string, any> = {}
  for (var i = 0; i < allIds.length; i++) {
    var id = allIds[i]
    var c = deepCopy(WRITER_CACHE)
    c.sprint.id = id
    c.sprint.status = 'active'
    c.totals.progress_pct = id === boundId ? 65 : 37
    perCaches['.sprint-progress-cache-' + id + '.json'] = JSON.stringify(c)
  }
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
    if (p.includes('sessions/') && p.endsWith('bound_sprint_id')) {
      return { value: boundId }
    }
    for (var name in perCaches) {
      if (p.endsWith(name)) return { value: perCaches[name] }
    }
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

describe('hook id length caps', () => {
  test('64-char session id accepted: band shows +1', async ($, on) => {
    var sid = 'a'.repeat(64)
    var w = capWorld(on, { sessionId: sid, boundId: 'sprint-900' })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    var ui = await mountBand($)
    expect(await ui.find({ text: /\+1/ })).toBeDefined()
    await ui.unmount()
  })

  test('200-char session id rejected: band shows no +1', async ($, on) => {
    var sid = 'a'.repeat(200)
    var w = capWorld(on, { sessionId: sid, boundId: 'sprint-900' })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    var ui = await mountBand($)
    expect(await ui.find({ text: /\+1/ })).toBeUndefined()
    await ui.unmount()
  })

  test('65-char bound id rejected: band shows no +1', async ($, on) => {
    var bid = 'b'.repeat(65)
    var w = capWorld(on, { sessionId: 'session-ok', boundId: bid })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    var ui = await mountBand($)
    expect(await ui.find({ text: /\+1/ })).toBeUndefined()
    await ui.unmount()
  })

  test('64-char bound id accepted: band shows +1', async ($, on) => {
    var bid = 'b'.repeat(64)
    var w = capWorld(on, { sessionId: 'session-ok', boundId: bid })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    var ui = await mountBand($)
    expect(await ui.find({ text: /\+1/ })).toBeDefined()
    await ui.unmount()
  })
})
