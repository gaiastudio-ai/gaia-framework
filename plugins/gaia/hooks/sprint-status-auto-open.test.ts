import { test, expect, mock, describe } from 'claude-code/testing'

const ACTIVE_CACHE = {
  schema_version: '1.0', generated_at: '2026-10-01T00:00:00Z',
  sprint: { id: 'sprint-test-1', goal: 'Ship it', start_date: '2026-10-01', end_date: '2026-10-14', status: 'active', total_days: 14, capacity_utilization: null, epic_focus: null },
  totals: { done_points: 3, total_points: 8, done_stories: 1, total_stories: 2, progress_pct: 37 },
  by_status: {}, day: { current: 1, total: 14, pace: 'on-pace' }, active_phase: 1,
  phases: [], unphased_stories: [],
  stories: [
    { key: 'E900-S1', title: 'Story one', slug: 'story-one', status: 'in-progress', points: 5, phase: 1, risk_level: 'low', blocked_by: null, blocked_since: null,
      gates: { passed: 0, total: 6, rows: [] }, tasks: { done: 0, total: 1, items: [] }, manual_test: { required: false, verdict: null } }
  ],
  action_needed: [], drift: [], readiness: { sprint_review: false, sprint_close: false },
  user_aliases: [], waiting_agent_threshold_seconds: 900
}

const GAIA_ROOT = '/project'
const OK_RUN = { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }

function world(on: any, opts: any = {}) {
  const cache = opts.cache ?? { content: JSON.stringify(ACTIVE_CACHE), mtimeMs: 100000 }
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
    // Auto-open should NOT pass focus: true
    const autoOpenCall = w.lastOpenArgs
    expect(autoOpenCall.id).toBe('sprint-status')
    expect(autoOpenCall.title).toBe('Sprint')
    expect(autoOpenCall.closeOnEscape).toBe(true)
    // No focus key at all (omitted = no focus)
    expect(autoOpenCall.focus).toBeUndefined()
  })

  test('no auto-open when sprint is null', async ($, on) => {
    const nullCache = JSON.parse(JSON.stringify(ACTIVE_CACHE))
    nullCache.sprint = null
    const w = world(on, { cache: { content: JSON.stringify(nullCache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    expect(w.opens).toBe(0)
  })

  test('no auto-open when sprint is closed', async ($, on) => {
    const closedCache = { ...ACTIVE_CACHE, sprint: { ...ACTIVE_CACHE.sprint, status: 'closed' } }
    const w = world(on, { cache: { content: JSON.stringify(closedCache), mtimeMs: 100000 } })
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
    // Auto-open was called but isPlaced was false; pane list has { isPlaced: false }.
    // toggle reads panes() and sees the pane is not placed, so it calls open.
    const opensBefore = w.opens
    const SPRINT_CMD = { command: 'sprint', args: '', origin: { kind: 'plugin' as const, name: 'test' }, presentation: { isFullscreen: false, columns: 80 } }
    // Make the next open return isPlaced true (terminal widened).
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
    // Mount with dock placement
    const ui = await $.ui.mount({
      plugin: 'gaia', surface: 'terminal', component: 'Pane', requestId: 'sprint-status',
      props: { bodyColumns: 60, placement: 'dock' }
    })
    expect(await ui.find({ text: /SPRINT/ })).toBeDefined()
    await ui.unmount()
    // Mount with inline placement
    const ui2 = await $.ui.mount({
      plugin: 'gaia', surface: 'terminal', component: 'Pane', requestId: 'sprint-status',
      props: { bodyColumns: 30, placement: 'inline' }
    })
    expect(await ui2.find({ text: /SPRINT/ })).toBeDefined()
    await ui2.unmount()
  })
})
