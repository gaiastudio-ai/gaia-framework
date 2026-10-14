import { test, expect, mock, describe } from 'claude-code/testing'

const ACTIVE_CACHE = {
  schema_version: '1.0', generated_at: '2026-10-01T00:00:00Z',
  sprint: { id: 'sprint-test-1', goal: 'Ship it', start_date: '2026-10-01', end_date: '2026-10-14', status: 'active', total_days: 14, capacity_utilization: null, epic_focus: null },
  totals: { done_points: 5, total_points: 20, done_stories: 2, total_stories: 8, progress_pct: 25 },
  by_status: {}, day: { current: 4, total: 14, pace: 'on-pace' }, active_phase: 1,
  phases: [], unphased_stories: [],
  stories: [
    { key: 'E900-S1', title: 'A', slug: 'a', status: 'done', points: 3, phase: 1, risk_level: 'low', blocked_by: null, blocked_since: null, gates: { passed: 6, total: 6, rows: [] }, tasks: { done: 0, total: 0, items: [] }, manual_test: { required: false, verdict: null } },
    { key: 'E900-S2', title: 'B', slug: 'b', status: 'done', points: 2, phase: 1, risk_level: 'low', blocked_by: null, blocked_since: null, gates: { passed: 6, total: 6, rows: [] }, tasks: { done: 0, total: 0, items: [] }, manual_test: { required: false, verdict: null } }
  ],
  action_needed: [], drift: [], readiness: { sprint_review: false, sprint_close: false },
  user_aliases: [], waiting_agent_threshold_seconds: 900
}

const GAIA_ROOT = '/project'
const OK_RUN = { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }

function world(on: any, opts: any = {}) {
  const cache = opts.cache ?? { content: JSON.stringify(ACTIVE_CACHE), mtimeMs: 100000 }
  const clock = mock.clock(on, { now: 100000 })
  const w: any = { clock, cache, runs: [] as any[] }
  on('session.start', (_$: unknown, e: any) => ({ cwd: e.cwd }))
  on('session.root', () => ({ value: GAIA_ROOT }))
  on('fs.exists', (_$: unknown, e: any) => ({ value: e.path === GAIA_ROOT + '/.gaia' }))
  on('command.register', () => ({ value: { command: 'sprint' } }))
  on('process.run', () => { w.runs.push(1); return { value: OK_RUN } })
  on('fs.stat', () => {
    if (cache.content === null) throw new Error('ENOENT')
    return { value: { kind: 'file' as const, size: cache.content.length, mtimeMs: cache.mtimeMs, isLink: false } }
  })
  on('fs.read', () => {
    if (cache.content === null) throw new Error('ENOENT')
    return { value: cache.content }
  })
  on('ui.panes', () => ({ value: [] }))
  on('ui.open', () => ({ value: { isPlaced: true, reason: 'placed' } }))
  on('ui.close', () => ({ value: undefined }))
  on('ui.log', () => ({ value: undefined }))
  on('ui.invalidate', () => ({ value: undefined }))
  on('env.get', (_$: unknown, e: any) => {
    if (e.name === 'HOME') return { value: '/home/u' }
    return { value: '' }
  })
  on('ui.render', { component: 'Pane' }, ($: any, e: any) => h($.ui.resolve(e).Text, null, 'BOTTOM'))
  on('ui.render', { component: 'AbovePrompt' }, ($: any, e: any) => h($.ui.resolve(e).Text, null, 'OTHER MOD'))
  return w
}

async function mountBand($: any) {
  return $.ui.mount({ plugin: 'gaia', surface: 'terminal', component: 'AbovePrompt', props: {} })
}

describe('band normal mode', () => {
  test('shows toggle button and summary with middot separators', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountBand($)
    expect(await ui.find({ text: /sprint-test-1/ })).toBeDefined()
    expect(await ui.find({ text: /5\/20 pts/ })).toBeDefined()
    expect(await ui.find({ text: /2\/8 done/ })).toBeDefined()
    expect(await ui.find({ text: /0 blocked/ })).toBeDefined()
    await ui.unmount()
  })

  test('band preserves other mods content', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountBand($)
    expect(await ui.find({ text: 'OTHER MOD' })).toBeDefined()
    await ui.unmount()
  })
})

describe('band warning mode', () => {
  test('shows warning variant when action list is non-empty', async ($, on) => {
    const warnCache = JSON.parse(JSON.stringify(ACTIVE_CACHE))
    warnCache.action_needed = [
      { rule: 'a', type: 'manual_test_due', story_keys: ['E900-S1'], message: 'Test due', command: '/gaia-test-manual', since: '2026-10-05', source: 'story-file' },
      { rule: 'c', type: 'action_item', story_keys: [], message: 'Open item', command: null, since: '2026-10-07', source: 'action-items' }
    ]
    const w = world(on, { cache: { content: JSON.stringify(warnCache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountBand($)
    expect(await ui.find({ text: /ACTION NEEDED/ })).toBeDefined()
    expect(await ui.find({ text: /2 items/ })).toBeDefined()
    expect(await ui.find({ text: /since 2026-10-05/ })).toBeDefined()
    expect(await ui.find({ text: /press 9/ })).toBeDefined()
    await ui.unmount()
  })
})

describe('band absent states', () => {
  test('no active sprint returns next(e) only', async ($, on) => {
    const closedCache = { ...ACTIVE_CACHE, sprint: { ...ACTIVE_CACHE.sprint, status: 'closed' } }
    const w = world(on, { cache: { content: JSON.stringify(closedCache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountBand($)
    expect(await ui.find({ text: 'OTHER MOD' })).toBeDefined()
    expect(await ui.find({ text: /sprint-test-1/ })).toBeUndefined()
    expect(await ui.find({ text: /ACTION NEEDED/ })).toBeUndefined()
    await ui.unmount()
  })

  test('null sprint returns next(e) only', async ($, on) => {
    const nullCache = JSON.parse(JSON.stringify(ACTIVE_CACHE))
    nullCache.sprint = null
    const w = world(on, { cache: { content: JSON.stringify(nullCache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountBand($)
    expect(await ui.find({ text: 'OTHER MOD' })).toBeDefined()
    expect(await ui.find({ text: /sprint/ })).toBeUndefined()
    await ui.unmount()
  })

  test('null cache returns next(e) only', async ($, on) => {
    const w = world(on, { cache: { content: null, mtimeMs: 0 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountBand($)
    expect(await ui.find({ text: 'OTHER MOD' })).toBeDefined()
    expect(await ui.find({ text: /ACTION NEEDED/ })).toBeUndefined()
    await ui.unmount()
  })
})
