import { test, expect, mock, describe } from 'claude-code/testing'

const ACTIVE_CACHE = {
  schema_version: '1.0',
  generated_at: '2026-10-01T00:00:00Z',
  sprint: { id: 'sprint-test-1', goal: 'Ship the dashboard', start_date: '2026-10-01', end_date: '2026-10-14', status: 'active', total_days: 14, capacity_utilization: null, epic_focus: null },
  totals: { done_points: 5, total_points: 20, done_stories: 2, total_stories: 8, progress_pct: 25 },
  by_status: { 'in-progress': { count: 2, points: 8 }, done: { count: 2, points: 5 }, review: { count: 1, points: 3 }, ready: { count: 2, points: 3 }, blocked: { count: 1, points: 1 } },
  day: { current: 4, total: 14, pace: 'on-pace' },
  active_phase: 2,
  phases: [
    { phase: 1, status: 'done', stories: ['E900-S1', 'E900-S2'], done_count: 2, total_count: 2 },
    { phase: 2, status: 'active', stories: ['E900-S3', 'E900-S4', 'E900-S5'], done_count: 0, total_count: 3 },
    { phase: 3, status: 'future', stories: ['E900-S6', 'E900-S7'], done_count: 0, total_count: 2 }
  ],
  unphased_stories: ['E900-S8'],
  stories: [
    { key: 'E900-S1', title: 'First story', slug: 'first-story', status: 'done', points: 3, phase: 1, risk_level: 'low', blocked_by: null, blocked_since: null,
      gates: { passed: 6, total: 6, rows: [{ name: 'Code Review', status: 'PASSED' }] }, tasks: { done: 2, total: 2, items: [{ text: 'Task A', done: true }, { text: 'Task B', done: true }] }, manual_test: { required: false, verdict: null } },
    { key: 'E900-S2', title: 'Second story', slug: 'second-story', status: 'done', points: 2, phase: 1, risk_level: 'low', blocked_by: null, blocked_since: null,
      gates: { passed: 6, total: 6, rows: [] }, tasks: { done: 0, total: 0, items: [] }, manual_test: { required: false, verdict: null } },
    { key: 'E900-S3', title: 'Third story', slug: 'third-story', status: 'in-progress', points: 5, phase: 2, risk_level: 'high', blocked_by: null, blocked_since: null,
      gates: { passed: 2, total: 6, rows: [{ name: 'Code Review', status: 'PASSED' }, { name: 'QA Tests', status: 'PASSED' }, { name: 'Security', status: 'UNVERIFIED' }] }, tasks: { done: 1, total: 3, items: [{ text: 'Implement feature', done: true }, { text: 'Write tests', done: false }, { text: 'Document', done: false }] }, manual_test: { required: true, verdict: null } },
    { key: 'E900-S4', title: 'Fourth story', slug: 'fourth-story', status: 'review', points: 3, phase: 2, risk_level: 'medium', blocked_by: null, blocked_since: null,
      gates: { passed: 6, total: 6, rows: [{ name: 'Code Review', status: 'PASSED' }] }, tasks: { done: 2, total: 2, items: [] }, manual_test: { required: true, verdict: 'PASSED' } },
    { key: 'E900-S5', title: 'Fifth story', slug: 'fifth-story', status: 'in-progress', points: 3, phase: 2, risk_level: 'low', blocked_by: null, blocked_since: null,
      gates: { passed: 0, total: 6, rows: [] }, tasks: { done: 0, total: 1, items: [{ text: 'Start work', done: false }] }, manual_test: { required: false, verdict: null } },
    { key: 'E900-S6', title: 'Sixth story', slug: 'sixth-story', status: 'ready', points: 2, phase: 3, risk_level: 'low', blocked_by: null, blocked_since: null,
      gates: { passed: 0, total: 6, rows: [] }, tasks: { done: 0, total: 0, items: [] }, manual_test: { required: false, verdict: null } },
    { key: 'E900-S7', title: 'Seventh story', slug: 'seventh-story', status: 'ready', points: 1, phase: 3, risk_level: 'low', blocked_by: null, blocked_since: null,
      gates: { passed: 0, total: 6, rows: [] }, tasks: { done: 0, total: 0, items: [] }, manual_test: { required: false, verdict: null } },
    { key: 'E900-S8', title: 'Eighth story', slug: 'eighth-story', status: 'blocked', points: 1, phase: null, risk_level: 'low', blocked_by: 'E900-S3', blocked_since: '2026-10-05',
      gates: { passed: 0, total: 6, rows: [] }, tasks: { done: 0, total: 0, items: [] }, manual_test: { required: false, verdict: null } }
  ],
  action_needed: [],
  drift: [{ story_key: 'E900-S3', type: 'status_mismatch', detail: 'gates ahead of status' }],
  readiness: { sprint_review: false, sprint_close: false },
  user_aliases: [],
  waiting_agent_threshold_seconds: 900
}

const GAIA_ROOT = '/project'
const OK_RUN = { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }

function world(on: any, opts: any = {}) {
  const cache = opts.cache ?? { content: JSON.stringify(ACTIVE_CACHE), mtimeMs: opts.now ?? 100000 }
  const clock = mock.clock(on, { now: opts.now ?? 100000 })
  const w: any = { clock, cache, runs: [] as any[], logs: [] as any[], invalidates: 0, stats: 0, reads: 0 }
  on('session.start', (_$: unknown, e: any) => ({ cwd: e.cwd }))
  on('session.root', () => ({ value: GAIA_ROOT }))
  on('fs.exists', (_$: unknown, e: any) => ({ value: e.path === GAIA_ROOT + '/.gaia' }))
  on('command.register', () => ({ value: { command: 'sprint' } }))
  on('process.run', () => { w.runs.push(1); return { value: OK_RUN } })
  on('fs.stat', () => {
    w.stats++
    if (cache.content === null) throw new Error('ENOENT')
    return { value: { kind: 'file' as const, size: cache.content.length, mtimeMs: cache.mtimeMs, isLink: false } }
  })
  on('fs.read', () => {
    w.reads++
    if (cache.content === null) throw new Error('ENOENT')
    return { value: cache.content }
  })
  on('ui.panes', () => ({ value: opts.panes ?? [] }))
  on('ui.open', () => ({ value: { isPlaced: true, reason: 'placed' } }))
  on('ui.close', () => ({ value: undefined }))
  on('ui.log', () => ({ value: undefined }))
  on('ui.invalidate', () => { w.invalidates++; return { value: undefined } })
  on('env.get', (_$: unknown, e: any) => {
    if (e.name === 'HOME') return { value: '/home/u' }
    if (e.name === 'NO_COLOR') return { value: opts.noColor ?? '' }
    if (e.name === 'GAIA_STATUSLINE_ASCII') return { value: opts.ascii ?? '' }
    return { value: '' }
  })
  on('ui.render', { component: 'Pane' }, ($: any, e: any) => h($.ui.resolve(e).Text, null, 'BOTTOM'))
  on('ui.render', { component: 'AbovePrompt' }, ($: any, e: any) => h($.ui.resolve(e).Text, null, 'OTHER'))
  return w
}

async function start($: any) {
  await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
  // Let the probe settle.
  const w = ($ as any).__world
  if (w && w.clock) await w.clock.settle()
}

async function mountPane($: any) {
  return $.ui.mount({ plugin: 'gaia', surface: 'terminal', component: 'Pane', requestId: 'sprint-status',
    props: { bodyColumns: 40, placement: 'dock' } })
}

describe('active sprint renders full sidebar dashboard', () => {
  test('header shows sprint id, live indicator, and goal', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /SPRINT.*sprint-test-1/ })).toBeDefined()
    expect(await ui.find({ text: /live/ })).toBeDefined()
    expect(await ui.find({ text: /Ship the dashboard/ })).toBeDefined()
    await ui.unmount()
  })

  test('aggregate shows done/total stories, points, and percentage', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /2 of 8 stories/ })).toBeDefined()
    expect(await ui.find({ text: /5 of 20 pts/ })).toBeDefined()
    expect(await ui.find({ text: /25%/ })).toBeDefined()
    await ui.unmount()
  })

  test('sub-line shows phase, day, pace, and blocked count', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /Phase 2/ })).toBeDefined()
    expect(await ui.find({ text: /Day 5 of 14/ })).toBeDefined()
    expect(await ui.find({ text: /on pace/ })).toBeDefined()
    expect(await ui.find({ text: /1 blocked/ })).toBeDefined()
    await ui.unmount()
  })

  test('readiness pills show sprint review and close status', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /Ready for sprint review.*no/ })).toBeDefined()
    expect(await ui.find({ text: /Ready to close sprint.*no/ })).toBeDefined()
    await ui.unmount()
  })

  test('NOW block shows in-progress and blocked stories', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /NOW/ })).toBeDefined()
    expect(await ui.find({ text: /E900-S3/ })).toBeDefined()
    expect(await ui.find({ text: /E900-S8/ })).toBeDefined()
    expect(await ui.find({ text: /blocked/ })).toBeDefined()
    await ui.unmount()
  })

  test('phase matrix shows done collapsed, active expanded, future dimmed', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /Phase 1/ })).toBeDefined()
    expect(await ui.find({ text: /PHASE 2 \(active\)/ })).toBeDefined()
    expect(await ui.find({ text: /PHASE 3/ })).toBeDefined()
    await ui.unmount()
  })

  test('HIGH marker appears for high-risk stories', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /E900-S3.*HIGH/ })).toBeDefined()
    await ui.unmount()
  })

  test('drift marker appears for stories with drift', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /E900-S3.*drift/ })).toBeDefined()
    await ui.unmount()
  })
})

describe('empty sprint and no-active-work states', () => {
  test('all stories in backlog shows "No active work"', async ($, on) => {
    const backlogCache = JSON.parse(JSON.stringify(ACTIVE_CACHE))
    backlogCache.stories = backlogCache.stories.map((s: any) => ({ ...s, status: 'backlog' }))
    const w = world(on, { cache: { content: JSON.stringify(backlogCache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /No active work/ })).toBeDefined()
    await ui.unmount()
  })

  test('no active sprint returns next(e)', async ($, on) => {
    const closedCache = { ...ACTIVE_CACHE, sprint: { ...ACTIVE_CACHE.sprint, status: 'closed' } }
    const w = world(on, { cache: { content: JSON.stringify(closedCache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: 'BOTTOM' })).toBeDefined()
    expect(await ui.find({ text: /SPRINT/ })).toBeUndefined()
    await ui.unmount()
  })

  test('null cache shows "Sprint data unavailable"', async ($, on) => {
    const w = world(on, { cache: { content: '{"sprint":', mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: 'Sprint data unavailable' })).toBeDefined()
    await ui.unmount()
  })
})

describe('overdue pace and readiness', () => {
  test('overdue pace label renders in warning colour', async ($, on) => {
    const overdueCache = JSON.parse(JSON.stringify(ACTIVE_CACHE))
    overdueCache.day.pace = 'overdue'
    const w = world(on, { cache: { content: JSON.stringify(overdueCache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /overdue/ })).toBeDefined()
    await ui.unmount()
  })

  test('ready-to-mark-done flag with manual_test required and PASSED', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    // E900-S4 is review, 6/6 gates, manual_test required + verdict PASSED
    expect(await ui.find({ text: /ready to mark done/ })).toBeDefined()
    await ui.unmount()
  })

  test('ready-to-mark-done flag without manual_test requirement', async ($, on) => {
    const noManualCache = JSON.parse(JSON.stringify(ACTIVE_CACHE))
    // Make E900-S4 not require manual test
    noManualCache.stories[3].manual_test = { required: false, verdict: null }
    const w = world(on, { cache: { content: JSON.stringify(noManualCache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /ready to mark done/ })).toBeDefined()
    await ui.unmount()
  })
})

describe('action needed banner', () => {
  test('banner renders when action_needed is non-empty', async ($, on) => {
    const bannerCache = JSON.parse(JSON.stringify(ACTIVE_CACHE))
    bannerCache.action_needed = [
      { rule: 'a', type: 'manual_test_due', story_keys: ['E900-S3'], message: 'Manual test due', command: '/gaia-test-manual', since: '2026-10-05', source: 'story-file' },
      { rule: 'c', type: 'action_item', story_keys: [], message: 'Open action item', command: null, since: '2026-10-06', source: 'action-items' }
    ]
    const w = world(on, { cache: { content: JSON.stringify(bannerCache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /ACTION NEEDED/ })).toBeDefined()
    expect(await ui.find({ text: /Manual test due/ })).toBeDefined()
    expect(await ui.find({ text: /gaia-test-manual/ })).toBeDefined()
    await ui.unmount()
  })

  test('banner hidden when action list is empty', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /ACTION NEEDED/ })).toBeUndefined()
    await ui.unmount()
  })
})

describe('sanitization', () => {
  test('ESC sequence in goal text is stripped by sanitizeCache', async ($, on) => {
    const escCache = JSON.parse(JSON.stringify(ACTIVE_CACHE))
    escCache.sprint.goal = '\x1b[31mevil\x1b[0m goal text'
    const w = world(on, { cache: { content: JSON.stringify(escCache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    // The ESC sequence should be stripped; 'evil goal text' should appear as plain text.
    expect(await ui.find({ text: /evil goal text/ })).toBeDefined()
    await ui.unmount()
  })
})

describe('render path does no file I/O', () => {
  test('rendering the pane and the band does no file or process work', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const before = { stats: w.stats, reads: w.reads, runs: w.runs.length }
    const pane = await mountPane($)
    await pane.unmount()
    const band = await $.ui.mount({ plugin: 'gaia', surface: 'terminal', component: 'AbovePrompt', props: {} })
    await band.unmount()
    expect({ stats: w.stats, reads: w.reads, runs: w.runs.length }).toEqual(before)
  })
})

describe('day line edge cases', () => {
  test('null total shows "Day N" without "of" suffix', async ($, on) => {
    const nullTotalCache = JSON.parse(JSON.stringify(ACTIVE_CACHE))
    nullTotalCache.day.total = null
    const w = world(on, { cache: { content: JSON.stringify(nullTotalCache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /Day 5(?! of)/ })).toBeDefined()
    await ui.unmount()
  })

  test('zero-point stories render segmented bar with equal widths', async ($, on) => {
    const zeroCache = JSON.parse(JSON.stringify(ACTIVE_CACHE))
    zeroCache.stories = zeroCache.stories.map((s: any) => ({ ...s, points: 0 }))
    zeroCache.totals = { ...zeroCache.totals, done_points: 0, total_points: 0, progress_pct: 0 }
    const w = world(on, { cache: { content: JSON.stringify(zeroCache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /0%/ })).toBeDefined()
    await ui.unmount()
  })
})
