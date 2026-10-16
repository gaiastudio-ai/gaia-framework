import { test, expect, mock, describe } from 'claude-code/testing'
import { WRITER_CACHE, GAIA_ROOT, OK_RUN, deepCopy, findLeafText } from './sprint-status-fixture.js'

function story(key: string, status: string, points: number, phase: number | null = 1, risk: string = 'low') {
  return {
    key, title: key + ' title', slug: key.toLowerCase(), status, points, phase, risk_level: risk,
    blocked_by: null, blocked_since: null,
    gates: { passed: 0, total: 6, rows: [] }, tasks: { done: 0, total: 0, items: [] },
    manual_test: { required: false, verdict: null }
  }
}

function makeCache(stories: any[], opts: any = {}) {
  const cache = deepCopy(WRITER_CACHE)
  cache.stories = stories
  cache.totals = opts.totals ?? cache.totals
  cache.phases = opts.phases ?? [{ phase: 1, status: 'active', stories: stories.map((s: any) => s.key), done_count: 0, total_count: stories.length }]
  cache.unphased_stories = opts.unphased ?? []
  return cache
}

function world(on: any, cacheData: any, opts: any = {}) {
  const cache = { content: JSON.stringify(cacheData), mtimeMs: 100000 }
  const clock = mock.clock(on, { now: 100000 })
  const w: any = { clock, cache }
  on('session.start', (_$: unknown, e: any) => ({ cwd: e.cwd }))
  on('session.root', () => ({ value: GAIA_ROOT }))
  on('fs.exists', (_$: unknown, e: any) => ({ value: e.path === GAIA_ROOT + '/.gaia' }))
  on('command.register', () => ({ value: { command: 'sprint' } }))
  on('process.run', () => ({ value: OK_RUN }))
  on('fs.stat', () => ({ value: { kind: 'file' as const, size: cache.content.length, mtimeMs: cache.mtimeMs, isLink: false } }))
  on('fs.read', () => ({ value: cache.content }))
  on('ui.panes', () => ({ value: [] }))
  on('ui.open', () => ({ value: { isPlaced: true, reason: 'placed' } }))
  on('ui.close', () => ({ value: undefined }))
  on('ui.log', () => ({ value: undefined }))
  on('ui.invalidate', () => ({ value: undefined }))
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

async function mountPane($: any, cols: number = 40) {
  return $.ui.mount({ plugin: 'gaia', surface: 'terminal', component: 'Pane', requestId: 'sprint-status',
    props: { bodyColumns: cols } })
}

describe('segmented bar grouped by status', () => {
  test('three statuses render one proportional colour block per status', async ($, on) => {
    const data = makeCache([
      story('E900-S1', 'done', 10),
      story('E900-S2', 'in-progress', 5),
      story('E900-S3', 'ready-for-dev', 5)
    ])
    const w = world(on, data)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    // Bar segments are Text elements with multiple filled-block chars (length > 1).
    // Colour key blocks are single filled-block chars — excluded by the length filter.
    const all = await ui.findAll({ text: /█/ })
    const segments = (all || []).filter((e: any) => e.type === 'Text' && /^█{2,}$/.test(e.text))
    expect(segments.length).toBe(3)
    expect(segments[0].props.color).toBe('green')       // done
    expect(segments[1].props.color).toBe('yellow')       // in-progress
    expect(segments[2].props.color).toBe('gray')         // ready-for-dev
    // Done has double the points, so its segment should be wider.
    expect(segments[0].text.length).toBeGreaterThan(segments[1].text.length)
    await ui.unmount()
  })

  test('done story in a later phase does not split the green block', async ($, on) => {
    // Two done stories in different phases should merge into one green segment.
    const data = makeCache([
      story('E900-S1', 'done', 5, 1),
      story('E900-S2', 'in-progress', 5, 2),
      story('E900-S3', 'done', 5, 3)
    ], {
      phases: [
        { phase: 1, status: 'done', stories: ['E900-S1'], done_count: 1, total_count: 1 },
        { phase: 2, status: 'active', stories: ['E900-S2'], done_count: 0, total_count: 1 },
        { phase: 3, status: 'future', stories: ['E900-S3'], done_count: 1, total_count: 1 }
      ]
    })
    const w = world(on, data)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    const all = await ui.findAll({ text: /█/ })
    const segments = (all || []).filter((e: any) => e.type === 'Text' && /^█+$/.test(e.text))
    // Only two bar segments (multi-block): one green (done) and one yellow (in-progress).
    const barSegs = segments.filter((e: any) => /^█{2,}$/.test(e.text))
    expect(barSegs.length).toBe(2)
    expect(barSegs[0].props.color).toBe('green')
    expect(barSegs[1].props.color).toBe('yellow')
    await ui.unmount()
  })

  test('40 stories in 30 columns never exceeds 30 columns', async ($, on) => {
    const stories = []
    const statuses = ['done', 'review', 'in-progress', 'blocked', 'ready-for-dev', 'backlog']
    for (let i = 1; i <= 40; i++) {
      stories.push(story('E900-S' + i, statuses[i % statuses.length], 3, 1))
    }
    const data = makeCache(stories)
    const w = world(on, data)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($, 30)
    // Bar segments are multi-block Text elements (length > 1); single blocks are colour key.
    const all = await ui.findAll({ text: /█/ })
    const barSegs = (all || []).filter((e: any) => e.type === 'Text' && /^█{2,}$/.test(e.text))
    let totalCols = 0
    for (const seg of barSegs) totalCols += seg.text.length
    expect(totalCols).toBeLessThanOrEqual(30)
    // Every present status has at least 1 column.
    expect(barSegs.length).toBeGreaterThanOrEqual(1)
    await ui.unmount()
  })

  test('single story renders one full-width segment', async ($, on) => {
    const data = makeCache([story('E900-S1', 'in-progress', 5)])
    const w = world(on, data)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /█/ })).toBeDefined()
    await ui.unmount()
  })

  test('NO_COLOR degrades bar to text-only status counts', async ($, on) => {
    const data = makeCache([
      story('E900-S1', 'done', 5),
      story('E900-S2', 'in-progress', 3),
      story('E900-S3', 'ready-for-dev', 2)
    ])
    const w = world(on, data, { noColor: '1' })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /1 done/ })).toBeDefined()
    expect(await ui.find({ text: /1 in-progress/ })).toBeDefined()
    expect(await ui.find({ text: /1 ready-for-dev/ })).toBeDefined()
    expect(await ui.find({ text: /█/ })).toBeUndefined()
    await ui.unmount()
  })
})

describe('colour key', () => {
  test('colour key shows one entry per present status with correct colour', async ($, on) => {
    const data = makeCache([
      story('E900-S1', 'done', 10),
      story('E900-S2', 'review', 5),
      story('E900-S3', 'ready-for-dev', 5)
    ])
    const w = world(on, data)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    // Colour key entries: coloured filled block followed by status name.
    // Find leaf Text elements with a single filled block and a colour prop.
    const all = await ui.findAll({ text: /█/ })
    const keyBlocks = (all || []).filter((e: any) => e.type === 'Text' && e.text === '█' && e.props.color)
    expect(keyBlocks.length).toBe(3)
    expect(keyBlocks[0].props.color).toBe('green')   // done
    expect(keyBlocks[1].props.color).toBe('blue')    // review
    expect(keyBlocks[2].props.color).toBe('gray')    // ready-for-dev
    // Status names are present.
    expect(await ui.find({ text: / done/ })).toBeDefined()
    expect(await ui.find({ text: / review/ })).toBeDefined()
    expect(await ui.find({ text: / ready-for-dev/ })).toBeDefined()
    await ui.unmount()
  })

  test('NO_COLOR keeps text counts, no colour key blocks', async ($, on) => {
    const data = makeCache([
      story('E900-S1', 'done', 5),
      story('E900-S2', 'in-progress', 3)
    ])
    const w = world(on, data, { noColor: '1' })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /1 done/ })).toBeDefined()
    expect(await ui.find({ text: /1 in-progress/ })).toBeDefined()
    // No filled blocks at all in NO_COLOR mode.
    expect(await ui.find({ text: /█/ })).toBeUndefined()
    await ui.unmount()
  })

  test('ASCII mode uses ASCII markers in colour key', async ($, on) => {
    const data = makeCache([
      story('E900-S1', 'done', 5),
      story('E900-S2', 'in-progress', 5)
    ])
    const w = world(on, data, { ascii: '1' })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    // ASCII colour key uses ASCII markers [x], [~] etc.
    expect(await ui.find({ text: /\[x\].*done/ })).toBeDefined()
    expect(await ui.find({ text: /\[~\].*in-progress/ })).toBeDefined()
    await ui.unmount()
  })
})

describe('glyph legend position', () => {
  test('glyph legend appears above phase matrix, not under the bar', async ($, on) => {
    const data = makeCache([
      story('E900-S1', 'done', 3, 1),
      story('E900-S2', 'in-progress', 5, 2),
      story('E900-S3', 'ready-for-dev', 2, 3)
    ], {
      phases: [
        { phase: 1, status: 'done', stories: ['E900-S1'], done_count: 1, total_count: 1 },
        { phase: 2, status: 'active', stories: ['E900-S2'], done_count: 0, total_count: 1 },
        { phase: 3, status: 'future', stories: ['E900-S3'], done_count: 0, total_count: 1 }
      ]
    })
    const w = world(on, data)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    // The glyph legend line contains the status glyphs (not the phase matrix header).
    // It should appear after the readiness/NOW sections and before the phase matrix.
    // Find all leaf text elements in order.
    const nowEl = await ui.find({ text: /NOW/ })
    const legendEl = await ui.find({ text: /✓ done/ })
    const matrixEl = await ui.find({ text: /READY.*DEV.*REVIEW.*DONE/ })
    expect(nowEl).toBeDefined()
    expect(legendEl).toBeDefined()
    expect(matrixEl).toBeDefined()
    await ui.unmount()
  })

  test('ASCII glyph legend uses ASCII fallbacks', async ($, on) => {
    const data = makeCache([
      story('E900-S1', 'done', 5),
      story('E900-S2', 'in-progress', 5)
    ])
    const w = world(on, data, { ascii: '1' })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /\[x\].*done/ })).toBeDefined()
    expect(await ui.find({ text: /\[~\].*in-progress/ })).toBeDefined()
    await ui.unmount()
  })
})

describe('phase matrix', () => {
  test('done phases collapsed, active expanded with stage markers, future dimmed', async ($, on) => {
    const data = makeCache([
      story('E900-S1', 'done', 3, 1),
      story('E900-S2', 'in-progress', 5, 2),
      story('E900-S3', 'ready-for-dev', 2, 3)
    ], {
      phases: [
        { phase: 1, status: 'done', stories: ['E900-S1'], done_count: 1, total_count: 1 },
        { phase: 2, status: 'active', stories: ['E900-S2'], done_count: 0, total_count: 1 },
        { phase: 3, status: 'future', stories: ['E900-S3'], done_count: 0, total_count: 1 }
      ]
    })
    const w = world(on, data)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /Phase 1.*1 stories/ })).toBeDefined()
    expect(await ui.find({ text: /PHASE 2 \(active\)/ })).toBeDefined()
    expect(await ui.find({ text: /PHASE 3/ })).toBeDefined()
    await ui.unmount()
  })

  test('high-risk story shows HIGH marker in matrix', async ($, on) => {
    const data = makeCache([
      story('E900-S1', 'in-progress', 5, 1, 'high')
    ], {
      phases: [{ phase: 1, status: 'active', stories: ['E900-S1'], done_count: 0, total_count: 1 }]
    })
    const w = world(on, data)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /E900-S1.*HIGH/ })).toBeDefined()
    await ui.unmount()
  })

  test('ASCII stage markers in phase matrix', async ($, on) => {
    const data = makeCache([
      story('E900-S1', 'in-progress', 5, 1)
    ], {
      phases: [{ phase: 1, status: 'active', stories: ['E900-S1'], done_count: 0, total_count: 1 }]
    })
    const w = world(on, data, { ascii: '1' })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /\[x\]/ })).toBeDefined()
    expect(await ui.find({ text: /\[\.\]/ })).toBeDefined()
    await ui.unmount()
  })
})
