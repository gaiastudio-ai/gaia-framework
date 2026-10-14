import { test, expect, mock, describe } from 'claude-code/testing'

const GAIA_ROOT = '/project'
const OK_RUN = { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }

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
  const statuses = ['done', 'in-progress', 'review', 'ready', 'blocked', 'backlog']
  for (let i = 1; i <= storyCount; i++) {
    stories.push(makeStory(i, statuses[i % statuses.length]))
  }
  const phases = []
  for (let p = 1; p <= Math.ceil(storyCount / 5); p++) {
    const phStories = stories.filter(s => s.phase === p).map(s => s.key)
    phases.push({ phase: p, status: p === 1 ? 'done' : (p === 2 ? 'active' : 'future'), stories: phStories, done_count: 0, total_count: phStories.length })
  }
  return {
    schema_version: '1.0', generated_at: '2026-10-01T00:00:00Z',
    sprint: { id: 'sprint-test-1', goal: 'Ship it', start_date: '2026-10-01', end_date: '2026-10-14', status: 'active', total_days: 14, capacity_utilization: null, epic_focus: null },
    totals: { done_points: 30, total_points: storyCount * 3, done_stories: Math.floor(storyCount / 6), total_stories: storyCount, progress_pct: Math.floor(100 / 6) },
    by_status: {}, day: { current: 3, total: 14, pace: 'on-pace' }, active_phase: 2,
    phases, unphased_stories: [],
    stories,
    action_needed: [{ rule: 'a', type: 'manual_test_due', story_keys: ['E900-S1'], message: 'Test due', command: '/gaia-test-manual', since: '2026-10-05', source: 'story-file' }],
    drift: [{ story_key: 'E900-S1', type: 'status_mismatch', detail: 'stale' }],
    readiness: { sprint_review: false, sprint_close: false },
    user_aliases: [], waiting_agent_threshold_seconds: 900
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
  test('pane render under 50ms p95 with representative cache (20 stories)', async ($, on) => {
    const w = world(on, 20)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const times: number[] = []
    for (let i = 0; i < 50; i++) {
      const start = performance.now()
      const ui = await $.ui.mount({
        plugin: 'gaia', surface: 'terminal', component: 'Pane', requestId: 'sprint-status',
        props: { bodyColumns: 60 }
      })
      const elapsed = performance.now() - start
      times.push(elapsed)
      await ui.unmount()
    }
    times.sort((a, b) => a - b)
    const p95 = times[Math.floor(times.length * 0.95)]
    expect(p95).toBeLessThan(50)
  })

  test('band render under 50ms p95 with representative cache', async ($, on) => {
    const w = world(on, 20)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const times: number[] = []
    for (let i = 0; i < 50; i++) {
      const start = performance.now()
      const ui = await $.ui.mount({ plugin: 'gaia', surface: 'terminal', component: 'AbovePrompt', props: {} })
      const elapsed = performance.now() - start
      times.push(elapsed)
      await ui.unmount()
    }
    times.sort((a, b) => a - b)
    const p95 = times[Math.floor(times.length * 0.95)]
    expect(p95).toBeLessThan(50)
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
