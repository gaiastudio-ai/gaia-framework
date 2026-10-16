import { test, expect, mock, describe } from 'claude-code/testing'
import { WRITER_CACHE, GAIA_ROOT, OK_RUN } from './sprint-status-fixture.js'

const SPRINT_CMD = { command: 'sprint', args: '', origin: { kind: 'plugin' as const, name: 'test' }, presentation: { isFullscreen: false, columns: 80 } }

function world(on: any) {
  const cache = { content: JSON.stringify(WRITER_CACHE), mtimeMs: 100000 }
  const clock = mock.clock(on, { now: 100000 })
  const w: any = { clock, cache, opens: 0, closes: 0, paneList: [] as any[], lastOpenArgs: null as any }
  on('session.start', (_$: unknown, e: any) => ({ cwd: e.cwd }))
  on('session.root', () => ({ value: GAIA_ROOT }))
  on('fs.exists', (_$: unknown, e: any) => ({ value: e.path === GAIA_ROOT + '/.gaia' }))
  on('command.register', () => ({ value: { command: 'sprint' } }))
  on('process.run', () => ({ value: OK_RUN }))
  on('fs.stat', () => ({ value: { kind: 'file' as const, size: cache.content.length, mtimeMs: cache.mtimeMs, isLink: false } }))
  on('fs.read', () => ({ value: cache.content }))
  on('ui.panes', () => ({ value: w.paneList }))
  on('ui.open', (_$: unknown, e: any) => {
    w.opens++
    w.lastOpenArgs = e
    w.paneList = [{ id: 'sprint-status', isPlaced: true }]
    return { value: { isPlaced: true, reason: 'placed' } }
  })
  on('ui.close', () => {
    w.closes++
    w.paneList = []
    return { value: undefined }
  })
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

describe('/sprint toggles sidebar', () => {
  test('/sprint toggles: when pane is placed (auto-opened), /sprint closes it', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    // Auto-open placed the pane; /sprint should close it.
    const closesBefore = w.closes
    await $.command.run(SPRINT_CMD)
    expect(w.closes).toBeGreaterThan(closesBefore)
  })

  test('/sprint opens with focus after the pane was closed', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    // First /sprint closes the auto-opened pane.
    await $.command.run(SPRINT_CMD)
    const opensBefore = w.opens
    // Second /sprint opens with focus.
    await $.command.run(SPRINT_CMD)
    expect(w.opens).toBeGreaterThan(opensBefore)
    expect(w.lastOpenArgs.focus).toBe(true)
  })
})

describe('toggle cycle after close', () => {
  // Esc close is verified in the live check; this test confirms the
  // toggle cycle (close then reopen) works after the pane is dismissed.
  test('after pane close, /sprint reopens the pane with focus', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    // Auto-open placed the pane.
    expect(w.opens).toBeGreaterThanOrEqual(1)
    // /sprint closes the auto-opened pane (toggle when placed).
    await $.command.run(SPRINT_CMD)
    expect(w.closes).toBeGreaterThanOrEqual(1)
    // A subsequent /sprint reopens with focus.
    const opensBefore = w.opens
    await $.command.run(SPRINT_CMD)
    expect(w.opens).toBeGreaterThan(opensBefore)
    expect(w.lastOpenArgs.focus).toBe(true)
  })
})
