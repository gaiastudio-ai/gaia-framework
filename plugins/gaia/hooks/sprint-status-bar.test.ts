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

describe('segmented bar', () => {
  test('three stories render proportional colour blocks and glyph legend', async ($, on) => {
    const data = makeCache([
      story('E900-S1', 'done', 10),
      story('E900-S2', 'in-progress', 5),
      story('E900-S3', 'ready-for-dev', 5)
    ])
    const w = world(on, data)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /done/ })).toBeDefined()
    expect(await ui.find({ text: /in-progress/ })).toBeDefined()
    expect(await ui.find({ text: /ready-for-dev/ })).toBeDefined()
    // Assert bar segments carry the correct colour props (not just text presence).
    // Each segment is a leaf Text with filled-block chars and a colour from the status map.
    const all = await ui.findAll({ text: /█/ })
    const segments = (all || []).filter((e: any) => e.type === 'Text')
    expect(segments.length).toBe(3)
    expect(segments[0].props.color).toBe('green')       // done
    expect(segments[1].props.color).toBe('yellow')       // in-progress
    expect(segments[2].props.color).toBe('gray')         // ready-for-dev
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

  test('ASCII glyph switch uses ASCII fallbacks', async ($, on) => {
    const data = makeCache([
      story('E900-S1', 'done', 5),
      story('E900-S2', 'in-progress', 5)
    ])
    const w = world(on, data, { ascii: '1' })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /\[x\]/ })).toBeDefined()
    expect(await ui.find({ text: /\[~\]/ })).toBeDefined()
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
