import { test, expect, mock, describe } from 'claude-code/testing'
import { WRITER_CACHE, GAIA_ROOT, OK_RUN, deepCopy } from './sprint-status-fixture.js'

function world(on: any, opts: any = {}) {
  const cache = opts.cache ?? { content: JSON.stringify(WRITER_CACHE), mtimeMs: opts.now ?? 100000 }
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
    expect(await ui.find({ text: /SPRINT.*sprint-84/ })).toBeDefined()
    expect(await ui.find({ text: /live/ })).toBeDefined()
    expect(await ui.find({ text: /Ship the dashboard/ })).toBeDefined()
    await ui.unmount()
  })

  test('aggregate shows done/total stories, points, and percentage', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /2 of 9 stories/ })).toBeDefined()
    expect(await ui.find({ text: /8 of 40 pts/ })).toBeDefined()
    expect(await ui.find({ text: /20%/ })).toBeDefined()
    await ui.unmount()
  })

  test('sub-line shows phase, day, pace, and blocked count', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /Phase 2/ })).toBeDefined()
    expect(await ui.find({ text: /Day 4 of 7/ })).toBeDefined()
    expect(await ui.find({ text: /behind pace/ })).toBeDefined()
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

  test('NOW block shows in-progress, review, and blocked stories', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /NOW/ })).toBeDefined()
    expect(await ui.find({ text: /E900-S3/ })).toBeDefined()
    expect(await ui.find({ text: /E900-S4/ })).toBeDefined()
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
})

describe('ready-for-dev status rendering', () => {
  test('legend shows ready-for-dev when stories use that status', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /ready-for-dev/ })).toBeDefined()
    await ui.unmount()
  })

  test('NO_COLOR counts include ready-for-dev stories', async ($, on) => {
    const w = world(on, { noColor: '1' })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /2 ready-for-dev/ })).toBeDefined()
    await ui.unmount()
  })
})

describe('empty sprint and no-active-work states', () => {
  test('all stories in backlog shows "No active work"', async ($, on) => {
    const cache = deepCopy(WRITER_CACHE)
    cache.stories = cache.stories.map((s: any) => ({ ...s, status: 'backlog' }))
    const w = world(on, { cache: { content: JSON.stringify(cache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /No active work/ })).toBeDefined()
    await ui.unmount()
  })

  test('no active sprint returns next(e)', async ($, on) => {
    const cache = deepCopy(WRITER_CACHE)
    cache.sprint.status = 'closed'
    const w = world(on, { cache: { content: JSON.stringify(cache), mtimeMs: 100000 } })
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
    const cache = deepCopy(WRITER_CACHE)
    cache.day.pace = 'overdue'
    const w = world(on, { cache: { content: JSON.stringify(cache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    const el = await ui.find({ text: /overdue/, color: 'red' })
    expect(el).toBeDefined()
    await ui.unmount()
  })

  test('blocked count > 0 renders in warning colour', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    const el = await ui.find({ text: /1 blocked/, color: 'red' })
    expect(el).toBeDefined()
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
    const cache = deepCopy(WRITER_CACHE)
    // Make E900-S4 not require manual test
    cache.stories[3].manual_test = { required: false, verdict: null }
    const w = world(on, { cache: { content: JSON.stringify(cache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /ready to mark done/ })).toBeDefined()
    await ui.unmount()
  })

  test('no ready-to-mark-done when manual test required but verdict not PASSED', async ($, on) => {
    const cache = deepCopy(WRITER_CACHE)
    // E900-S4 is review+6/6 but manual verdict null
    cache.stories[3].manual_test = { required: true, verdict: null }
    const w = world(on, { cache: { content: JSON.stringify(cache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /ready to mark done/ })).toBeUndefined()
    await ui.unmount()
  })

  test('no ready-to-mark-done when gates are not 6/6', async ($, on) => {
    const cache = deepCopy(WRITER_CACHE)
    // E900-S4 is review but only 5/6 gates
    cache.stories[3].gates.passed = 5
    const w = world(on, { cache: { content: JSON.stringify(cache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /ready to mark done/ })).toBeUndefined()
    await ui.unmount()
  })

  test('no ready-to-mark-done when status is not review', async ($, on) => {
    const cache = deepCopy(WRITER_CACHE)
    // Change E900-S4 to in-progress (still 6/6 gates)
    cache.stories[3].status = 'in-progress'
    const w = world(on, { cache: { content: JSON.stringify(cache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /ready to mark done/ })).toBeUndefined()
    await ui.unmount()
  })
})

describe('action needed banner', () => {
  test('banner renders with per-entry since date', async ($, on) => {
    const cache = deepCopy(WRITER_CACHE)
    cache.action_needed = [
      { rule: 'a', type: 'manual_test_due', story_keys: ['E900-S3'], message: 'Manual test due', command: '/gaia-test-manual', since: '2026-10-13', source: 'story-file' },
      { rule: 'c', type: 'action_item', story_keys: [], message: 'Open action item', command: null, since: '2026-10-14', source: 'action-items' }
    ]
    const w = world(on, { cache: { content: JSON.stringify(cache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /ACTION NEEDED/ })).toBeDefined()
    expect(await ui.find({ text: /Manual test due/ })).toBeDefined()
    expect(await ui.find({ text: /gaia-test-manual/ })).toBeDefined()
    // Per-entry since date
    expect(await ui.find({ text: /since 2026-10-13/ })).toBeDefined()
    expect(await ui.find({ text: /since 2026-10-14/ })).toBeDefined()
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

describe('story detail panel', () => {
  test('press a row shows detail with tasks, gates, and manual test', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    let ui = await mountPane($)
    // Press E900-S3 row (in NOW block) using the button key
    await ui.press({ key: 'now-E900-S3' })
    await ui.unmount()
    // Remount to see the updated state
    ui = await mountPane($)
    // Detail shows task items
    expect(await ui.find({ text: /Implement feature/ })).toBeDefined()
    expect(await ui.find({ text: /Write tests/ })).toBeDefined()
    // Detail shows gate rows with canonical names
    expect(await ui.find({ text: /Code Review.*PASSED/ })).toBeDefined()
    expect(await ui.find({ text: /Security Review.*UNVERIFIED/ })).toBeDefined()
    // Detail shows manual test
    expect(await ui.find({ text: /Manual test/ })).toBeDefined()
    await ui.unmount()
  })

  test('press same row again collapses detail', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    let ui = await mountPane($)
    // Open detail for E900-S3
    await ui.press({ key: 'now-E900-S3' })
    await ui.unmount()
    ui = await mountPane($)
    expect(await ui.find({ text: /Implement feature/ })).toBeDefined()
    // Press again to collapse
    await ui.press({ key: 'now-E900-S3' })
    await ui.unmount()
    ui = await mountPane($)
    expect(await ui.find({ text: /Implement feature/ })).toBeUndefined()
    await ui.unmount()
  })

  test('press another row swaps detail', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    let ui = await mountPane($)
    // Open detail for E900-S3
    await ui.press({ key: 'now-E900-S3' })
    await ui.unmount()
    ui = await mountPane($)
    expect(await ui.find({ text: /Implement feature/ })).toBeDefined()
    // Press E900-S4 (also in NOW as review)
    await ui.press({ key: 'now-E900-S4' })
    await ui.unmount()
    ui = await mountPane($)
    // E900-S3 detail gone
    expect(await ui.find({ text: /Implement feature/ })).toBeUndefined()
    // E900-S4 detail shown
    expect(await ui.find({ text: /▾ E900-S4/ })).toBeDefined()
    await ui.unmount()
  })
})

describe('sanitization', () => {
  test('ESC sequence in goal text is stripped by sanitizeCache', async ($, on) => {
    const cache = deepCopy(WRITER_CACHE)
    cache.sprint.goal = '\x1b[31mevil\x1b[0m goal text'
    const w = world(on, { cache: { content: JSON.stringify(cache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
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
    const cache = deepCopy(WRITER_CACHE)
    cache.day.total = null
    const w = world(on, { cache: { content: JSON.stringify(cache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /Day 4(?! of)/ })).toBeDefined()
    await ui.unmount()
  })

  test('zero-point stories render segmented bar with equal widths', async ($, on) => {
    const cache = deepCopy(WRITER_CACHE)
    cache.stories = cache.stories.map((s: any) => ({ ...s, points: 0 }))
    cache.totals = { ...cache.totals, done_points: 0, total_points: 0, progress_pct: 0 }
    const w = world(on, { cache: { content: JSON.stringify(cache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /0%/ })).toBeDefined()
    await ui.unmount()
  })
})

describe('bar handles extreme points', () => {
  test('huge points (1e9) render without hanging', async ($, on) => {
    const cache = deepCopy(WRITER_CACHE)
    cache.stories[0].points = 1e9
    const w = world(on, { cache: { content: JSON.stringify(cache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const start = Date.now()
    const ui = await mountPane($)
    const elapsed = Date.now() - start
    expect(elapsed).toBeLessThan(2000)
    await ui.unmount()
  })

  test('negative points treated as zero', async ($, on) => {
    const cache = deepCopy(WRITER_CACHE)
    cache.stories[0].points = -999999999
    const w = world(on, { cache: { content: JSON.stringify(cache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const start = Date.now()
    const ui = await mountPane($)
    const elapsed = Date.now() - start
    expect(elapsed).toBeLessThan(2000)
    await ui.unmount()
  })
})
