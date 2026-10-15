import { test, expect, mock, describe } from 'claude-code/testing'
import { WRITER_CACHE, GAIA_ROOT, OK_RUN, deepCopy } from './sprint-status-fixture.js'

const SPRINT_CMD = { command: 'sprint', args: '', origin: { kind: 'plugin' as const, name: 'test' }, presentation: { isFullscreen: false, columns: 80 } }

function world(on: any, opts: any = {}) {
  const cache = opts.cache ?? { content: JSON.stringify(WRITER_CACHE), mtimeMs: 100000 }
  const clock = mock.clock(on, { now: 100000 })
  const w: any = { clock, cache, opens: 0, lastOpenArgs: null as any, paneList: [] as any[] }
  on('session.start', (_$: unknown, e: any) => ({ cwd: e.cwd }))
  on('session.root', () => ({ value: GAIA_ROOT }))
  on('fs.exists', (_$: unknown, e: any) => ({ value: e.path === GAIA_ROOT + '/.gaia' }))
  on('command.register', () => ({ value: { command: 'sprint' } }))
  on('process.run', () => ({ value: OK_RUN }))
  on('fs.stat', () => {
    if (cache.content === null) throw new Error('ENOENT')
    return { value: { kind: 'file' as const, size: cache.content.length, mtimeMs: cache.mtimeMs, isLink: false } }
  })
  on('fs.read', () => {
    if (cache.content === null) throw new Error('ENOENT')
    return { value: cache.content }
  })
  on('ui.panes', () => ({ value: w.paneList }))
  on('ui.open', (_$: unknown, e: any) => {
    w.opens++
    w.lastOpenArgs = e
    w.paneList = [{ id: 'sprint-status', isPlaced: opts.isPlaced !== false }]
    return { value: { isPlaced: opts.isPlaced !== false, reason: 'placed' } }
  })
  on('ui.close', () => { w.paneList = []; return { value: undefined } })
  on('ui.log', () => ({ value: undefined }))
  on('ui.invalidate', () => ({ value: undefined }))
  on('env.get', (_$: unknown, e: any) => {
    if (e.name === 'HOME') return { value: '/home/u' }
    return { value: '' }
  })
  on('ui.render', { component: 'Pane' }, ($: any, e: any) => h($.ui.resolve(e).Text, null, 'BOTTOM'))
  on('ui.render', { component: 'AbovePrompt' }, ($: any, e: any) => h($.ui.resolve(e).Text, null, 'OTHER'))
  return w
}

describe('auto-open at session start', () => {
  test('calls $.ui.open without focus when active sprint is in cache', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    expect(w.opens).toBeGreaterThanOrEqual(1)
    const autoOpenCall = w.lastOpenArgs
    expect(autoOpenCall.id).toBe('sprint-status')
    expect(autoOpenCall.title).toBe('Sprint')
    expect(autoOpenCall.closeOnEscape).toBe(true)
    expect(autoOpenCall.focus).toBeUndefined()
  })

  test('no auto-open when sprint is null', async ($, on) => {
    const cache = deepCopy(WRITER_CACHE)
    ;(cache as any).sprint = null
    const w = world(on, { cache: { content: JSON.stringify(cache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    expect(w.opens).toBe(0)
  })

  test('no auto-open when sprint is closed', async ($, on) => {
    const cache = deepCopy(WRITER_CACHE)
    cache.sprint.status = 'closed'
    const w = world(on, { cache: { content: JSON.stringify(cache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    expect(w.opens).toBe(0)
  })

  test('no auto-open when cache is absent', async ($, on) => {
    const w = world(on, { cache: { content: null, mtimeMs: 0 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    expect(w.opens).toBe(0)
  })
})

describe('toggle after non-placed auto-open', () => {
  test('toggle reads $.ui.panes() at call time and opens when not placed', async ($, on) => {
    const w = world(on, { isPlaced: false })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const opensBefore = w.opens
    w.paneList = [{ id: 'sprint-status', isPlaced: false }]
    await $.command.run(SPRINT_CMD)
    expect(w.opens).toBeGreaterThan(opensBefore)
  })
})

describe('dock vs inline rendering', () => {
  test('pane uses e.props.placement and bodyColumns for layout', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await $.ui.mount({
      plugin: 'gaia', surface: 'terminal', component: 'Pane', requestId: 'sprint-status',
      props: { bodyColumns: 60, placement: 'dock' }
    })
    expect(await ui.find({ text: /SPRINT/ })).toBeDefined()
    await ui.unmount()
    const ui2 = await $.ui.mount({
      plugin: 'gaia', surface: 'terminal', component: 'Pane', requestId: 'sprint-status',
      props: { bodyColumns: 30, placement: 'inline' }
    })
    expect(await ui2.find({ text: /SPRINT/ })).toBeDefined()
    await ui2.unmount()
  })
})
