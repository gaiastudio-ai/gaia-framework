import { test, expect, mock, describe } from 'claude-code/testing'
import { WRITER_CACHE, GAIA_ROOT, OK_RUN, deepCopy } from './sprint-status-fixture.js'

function makeStory(i: number, status: string) {
  return {
    key: 'E900-S' + i, title: 'Story ' + i, slug: 'story-' + i, status, points: 3,
    phase: Math.ceil(i / 5), risk_level: i % 7 === 0 ? 'high' : 'low',
    blocked_by: null, blocked_since: null,
    gates: { passed: status === 'done' ? 6 : 2, total: 6, rows: [{ name: 'Code Review', status: 'PASSED' }] },
    tasks: { done: status === 'done' ? 2 : 1, total: 2, items: [{ text: 'Task A', done: true }, { text: 'Task B', done: status === 'done' }] },
    manual_test: { required: false, verdict: null }
  }
}

function makeCache(storyCount: number) {
  const stories = []
  const statuses = ['done', 'in-progress', 'review', 'ready-for-dev', 'blocked', 'backlog']
  for (let i = 1; i <= storyCount; i++) {
    stories.push(makeStory(i, statuses[i % statuses.length]))
  }
  const phases = []
  for (let p = 1; p <= Math.ceil(storyCount / 5); p++) {
    const phStories = stories.filter(s => s.phase === p).map(s => s.key)
    phases.push({ phase: p, status: p === 1 ? 'done' : (p === 2 ? 'active' : 'future'), stories: phStories, done_count: 0, total_count: phStories.length })
  }
  const base = deepCopy(WRITER_CACHE)
  return {
    ...base,
    totals: { done_points: 30, total_points: storyCount * 3, done_stories: Math.floor(storyCount / 6), total_stories: storyCount, progress_pct: Math.floor(100 / 6) },
    phases, stories,
    action_needed: [{ rule: 'a', type: 'manual_test_due', story_keys: ['E900-S1'], message: 'Test due', command: '/gaia-test-manual', since: '2026-10-13', source: 'story-file' }],
    drift: [{ story_key: 'E900-S1', type: 'status_mismatch', detail: 'stale' }]
  }
}

function world(on: any, storyCount: number) {
  const data = makeCache(storyCount)
  const cache = { content: JSON.stringify(data), mtimeMs: 100000 }
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
    return { value: '' }
  })
  on('ui.render', { component: 'Pane' }, ($: any, e: any) => h($.ui.resolve(e).Text, null, 'BOTTOM'))
  on('ui.render', { component: 'AbovePrompt' }, ($: any, e: any) => h($.ui.resolve(e).Text, null, 'OTHER'))
  return w
}

describe('render performance', () => {
  // Structural assertion: render does no file or process work, so render time
  // is bounded by in-memory tree construction regardless of CPU load.
  test('pane render does no file or process work with 20 stories', async ($, on) => {
    const data = makeCache(20)
    const cache = { content: JSON.stringify(data), mtimeMs: 100000 }
    const clock = mock.clock(on, { now: 100000 })
    let statsAfterStart = 0
    let readsAfterStart = 0
    let runsAfterStart = 0
    let started = false
    on('session.start', (_$: unknown, e: any) => ({ cwd: e.cwd }))
    on('session.root', () => ({ value: GAIA_ROOT }))
    on('fs.exists', (_$: unknown, e: any) => ({ value: e.path === GAIA_ROOT + '/.gaia' }))
    on('command.register', () => ({ value: { command: 'sprint' } }))
    on('process.run', () => {
      if (started) runsAfterStart++
      return { value: OK_RUN }
    })
    on('fs.stat', () => {
      if (started) statsAfterStart++
      return { value: { kind: 'file' as const, size: cache.content.length, mtimeMs: cache.mtimeMs, isLink: false } }
    })
    on('fs.read', () => {
      if (started) readsAfterStart++
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
    on('ui.render', { component: 'AbovePrompt' }, ($: any, e: any) => h($.ui.resolve(e).Text, null, 'OTHER'))
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await clock.settle()
    started = true
    // Render the pane multiple times
    for (let i = 0; i < 10; i++) {
      const ui = await $.ui.mount({
        plugin: 'gaia', surface: 'terminal', component: 'Pane', requestId: 'sprint-status',
        props: { bodyColumns: 60 }
      })
      await ui.unmount()
    }
    expect(statsAfterStart).toBe(0)
    expect(readsAfterStart).toBe(0)
    expect(runsAfterStart).toBe(0)
  })

  test('100+ stories render from in-memory cache without file I/O', async ($, on) => {
    const data = makeCache(100)
    const cache = { content: JSON.stringify(data), mtimeMs: 100000 }
    const clock = mock.clock(on, { now: 100000 })
    let statsAfterStart = 0
    let readsAfterStart = 0
    let started = false
    on('session.start', (_$: unknown, e: any) => ({ cwd: e.cwd }))
    on('session.root', () => ({ value: GAIA_ROOT }))
    on('fs.exists', (_$: unknown, e: any) => ({ value: e.path === GAIA_ROOT + '/.gaia' }))
    on('command.register', () => ({ value: { command: 'sprint' } }))
    on('process.run', () => ({ value: OK_RUN }))
    on('fs.stat', () => {
      if (started) statsAfterStart++
      return { value: { kind: 'file' as const, size: cache.content.length, mtimeMs: cache.mtimeMs, isLink: false } }
    })
    on('fs.read', () => {
      if (started) readsAfterStart++
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
    on('ui.render', { component: 'AbovePrompt' }, ($: any, e: any) => h($.ui.resolve(e).Text, null, 'OTHER'))
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await clock.settle()
    started = true
    const ui = await $.ui.mount({
      plugin: 'gaia', surface: 'terminal', component: 'Pane', requestId: 'sprint-status',
      props: { bodyColumns: 80 }
    })
    expect(statsAfterStart).toBe(0)
    expect(readsAfterStart).toBe(0)
    await ui.unmount()
  })
})
