import { test, expect, mock, describe } from 'claude-code/testing'

const ACTIVE_CACHE = {
  schema_version: '1.0', generated_at: '2026-10-01T00:00:00Z',
  sprint: { id: 'sprint-test-1', goal: 'Ship it', start_date: '2026-10-01', end_date: '2026-10-14', status: 'active', total_days: 14, capacity_utilization: null, epic_focus: null },
  totals: { done_points: 3, total_points: 8, done_stories: 1, total_stories: 2, progress_pct: 37 },
  by_status: {}, day: { current: 1, total: 14, pace: 'on-pace' }, active_phase: 1,
  phases: [{ phase: 1, status: 'active', stories: ['E900-S1', 'E900-S2'], done_count: 0, total_count: 2 }],
  unphased_stories: [],
  stories: [
    { key: 'E900-S1', title: 'Story one', slug: 'story-one', status: 'in-progress', points: 5, phase: 1, risk_level: 'low', blocked_by: null, blocked_since: null,
      gates: { passed: 2, total: 6, rows: [{ name: 'Code Review', status: 'PASSED' }, { name: 'QA Tests', status: 'UNVERIFIED' }] },
      tasks: { done: 1, total: 3, items: [{ text: 'Implement feature', done: true }, { text: 'Write tests', done: false }, { text: 'Document', done: false }] },
      manual_test: { required: true, verdict: null } },
    { key: 'E900-S2', title: 'Story two', slug: 'story-two', status: 'review', points: 3, phase: 1, risk_level: 'low', blocked_by: null, blocked_since: null,
      gates: { passed: 6, total: 6, rows: [{ name: 'Code Review', status: 'PASSED' }] },
      tasks: { done: 2, total: 2, items: [{ text: 'Task A', done: true }, { text: 'Task B', done: true }] },
      manual_test: { required: false, verdict: null } }
  ],
  action_needed: [], drift: [], readiness: { sprint_review: false, sprint_close: false },
  user_aliases: [], waiting_agent_threshold_seconds: 900
}

const GAIA_ROOT = '/project'
const OK_RUN = { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }

function world(on: any) {
  const cache = { content: JSON.stringify(ACTIVE_CACHE), mtimeMs: 100000 }
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

async function mountPane($: any) {
  return $.ui.mount({ plugin: 'gaia', surface: 'terminal', component: 'Pane', requestId: 'sprint-status',
    props: { bodyColumns: 40 } })
}

describe('story row buttons and selection', () => {
  test('story rows render as buttons in NOW block and phase matrix', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    // Stories should appear in NOW block (in-progress and review)
    expect(await ui.find({ text: /E900-S1/ })).toBeDefined()
    expect(await ui.find({ text: /E900-S2/ })).toBeDefined()
    await ui.unmount()
  })

  test('NOW block shows task and gate counts for each story', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    // NOW rows should show task and gate counts.
    expect(await ui.find({ text: /tasks 1\/3/ })).toBeDefined()
    expect(await ui.find({ text: /gates 2\/6/ })).toBeDefined()
    await ui.unmount()
  })
})

describe('empty NOW block keyboard safety', () => {
  test('no crash when NOW block has no active stories', async ($, on) => {
    const backlogCache = JSON.parse(JSON.stringify(ACTIVE_CACHE))
    backlogCache.stories = backlogCache.stories.map((s: any) => ({ ...s, status: 'backlog' }))
    const cache = { content: JSON.stringify(backlogCache), mtimeMs: 100000 }
    const clock = mock.clock(on, { now: 100000 })
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
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /No active work/ })).toBeDefined()
    // No buttons should be in the empty NOW block
    await ui.unmount()
  })
})
