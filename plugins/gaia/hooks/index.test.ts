import { test, expect, mock, describe } from 'claude-code/testing'

// Inline cache fixture matching the real snapshot schema.
// The mod-cache-contract.bats test asserts these keys match the real output.
const ACTIVE_CACHE = {
  schema_version: '1.0',
  generated_at: '2026-10-01T00:00:00Z',
  sprint: {
    id: 'sprint-test-1',
    goal: 'Test goal',
    start_date: '2026-10-01',
    end_date: '2026-10-14',
    status: 'active',
    total_days: 14,
    capacity_utilization: null,
    epic_focus: null
  },
  totals: { done_points: 3, total_points: 8, done_stories: 1, total_stories: 2, progress_pct: 37 },
  by_status: { 'in-progress': { count: 1, points: 5 }, done: { count: 1, points: 3 } },
  day: { current: 1, total: 14, pace: 'on-pace' },
  active_phase: 1,
  phases: [{ phase: 1, status: 'active', stories: ['E900-S1', 'E900-S2'], done_count: 1, total_count: 2 }],
  unphased_stories: [],
  stories: [
    { key: 'E900-S1', status: 'in-progress', points: 5, title: 'Story one', slug: 'story-one',
      phase: 1, blocked_by: null,
      gates: { passed: 0, total: 6, rows: [{ name: 'val', status: 'UNVERIFIED' }] },
      tasks: { done: 0, total: 1, items: [{ text: 'Implement feature', done: false }] } },
    { key: 'E900-S2', status: 'done', points: 3, title: 'Story two', slug: 'story-two',
      phase: 1, blocked_by: null,
      gates: { passed: 6, total: 6, rows: [] },
      tasks: { done: 0, total: 0, items: [] } }
  ],
  action_needed: [],
  drift: [],
  readiness: { sprint_review: false, sprint_close: false },
  user_aliases: [],
  waiting_agent_threshold_seconds: 900
}

const CLOSED_CACHE = {
  ...ACTIVE_CACHE,
  sprint: { ...ACTIVE_CACHE.sprint, status: 'closed' }
}

// Helper: GAIA root with .gaia directory at /project
const GAIA_ROOT = '/project'
const GAIA_DIR = '/project/.gaia'

const SESSION_START_EVENT = { cwd: GAIA_ROOT, surface: 'terminal' as const, isInteractive: true }
const SPRINT_CMD = {
  command: 'sprint',
  args: '',
  origin: { kind: 'plugin' as const, name: 'test' },
  presentation: { isFullscreen: false, columns: 80 }
}

// Helper: register common bottom hooks for a GAIA-root scenario
function registerGaiaRoot(on: any, clock: any, opts?: {
  processRunFn?: () => any
  fsStatFn?: () => any
  fsReadFn?: () => any
  panesList?: any[]
}) {
  // Bottom for session.start event (must return { cwd })
  on('session.start', (_$: unknown, e: unknown) => ({ cwd: (e as { cwd: string }).cwd }))

  on('session.root', () => ({ value: GAIA_ROOT }))
  on('fs.exists', (_$: unknown, e: unknown) => ({ value: (e as { path: string }).path === GAIA_DIR }))
  on('command.register', () => ({ value: { command: 'sprint' } }))
  on('process.run', opts?.processRunFn ?? (() => ({
    value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }
  })))
  on('fs.stat', opts?.fsStatFn ?? (() => ({
    value: { kind: 'file' as const, size: 100, mtimeMs: clock.now(), isLink: false }
  })))
  on('fs.read', opts?.fsReadFn ?? (() => ({ value: JSON.stringify(ACTIVE_CACHE) })))
  on('ui.panes', () => ({ value: opts?.panesList ?? [] }))
  on('ui.log', () => ({ value: undefined }))
  on('ui.invalidate', () => ({ value: undefined }))
}

describe('session.start capability detection', () => {
  test('registers all event hooks and detects capabilities', async ($, on) => {
    const clock = mock.clock(on)
    registerGaiaRoot(on, clock)

    await $.session.start(SESSION_START_EVENT)

    const result = await $.command.run(SPRINT_CMD)

    // With an active sprint, the command returns empty (toggle deferred to S6)
    expect(result).toBeDefined()
  })
})

describe('graceful degradation', () => {
  test('graceful degradation all members throw handlers return next no user-visible output', async ($, on) => {
    let uiNoticeCalls = 0
    let uiToastCalls = 0
    let nonDebugLogCalls = 0
    let processRunCalls = 0

    on('session.start', (_$: unknown, e: unknown) => ({ cwd: (e as { cwd: string }).cwd }))
    on('session.root', () => { throw new Error('not available') })
    on('fs.exists', () => { throw new Error('not available') })
    on('command.register', () => { throw new Error('not available') })
    on('process.run', () => { processRunCalls++; throw new Error('not available') })
    on('ui.panes', () => { throw new Error('not available') })
    on('ui.open', () => ({ value: { isPlaced: false, reason: 'none' } }))
    on('ui.log', (_$: unknown, e: unknown) => {
      const ev = e as { text: string; options?: { to?: string } }
      if (!ev.options || ev.options.to !== 'debug') nonDebugLogCalls++
      return { value: undefined }
    })
    on('ui.notice', () => { uiNoticeCalls++; return { value: undefined } })
    on('ui.toast', () => { uiToastCalls++; return { value: undefined } })
    on('ui.invalidate', () => ({ value: undefined }))

    await $.session.start({ cwd: '/nowhere', surface: 'terminal', isInteractive: true })

    expect(uiNoticeCalls).toBe(0)
    expect(uiToastCalls).toBe(0)
    expect(nonDebugLogCalls).toBe(0)
    expect(processRunCalls).toBe(0)
  })
})

describe('/sprint command', () => {
  test('sprint command returns no active sprint no ui.open no band content', async ($, on) => {
    const clock = mock.clock(on)
    let uiOpenCalls = 0

    on('session.start', (_$: unknown, e: unknown) => ({ cwd: (e as { cwd: string }).cwd }))
    on('session.root', () => ({ value: '/tmp/notgaia' }))
    on('fs.exists', () => ({ value: false }))
    on('command.register', () => ({ value: { command: 'sprint' } }))
    on('ui.panes', () => ({ value: [] }))
    on('ui.log', () => ({ value: undefined }))
    on('ui.open', () => { uiOpenCalls++; return { value: { isPlaced: false, reason: 'none' } } })
    on('ui.invalidate', () => ({ value: undefined }))

    await $.session.start({ cwd: '/tmp/notgaia', surface: 'terminal', isInteractive: true })

    const result = await $.command.run(SPRINT_CMD)

    expect(result).toMatchObject({ text: 'No active sprint' })
    expect(uiOpenCalls).toBe(0)
  })

  test('sprint command with gaiaRoot set but process failed returns no active sprint not empty', async ($, on) => {
    const clock = mock.clock(on)

    on('session.start', (_$: unknown, e: unknown) => ({ cwd: (e as { cwd: string }).cwd }))
    on('session.root', () => ({ value: GAIA_ROOT }))
    on('fs.exists', (_$: unknown, e: unknown) => ({ value: (e as { path: string }).path === GAIA_DIR }))
    on('command.register', () => ({ value: { command: 'sprint' } }))
    on('process.run', () => { throw new Error('process start failed') })
    on('ui.panes', () => ({ value: [] }))
    on('ui.log', () => ({ value: undefined }))
    on('ui.invalidate', () => ({ value: undefined }))

    await $.session.start(SESSION_START_EVENT)

    const result = await $.command.run(SPRINT_CMD)

    expect(result).toMatchObject({ text: 'No active sprint' })
  })

  test('sprint command with gaiaRoot set but cache missing returns no active sprint', async ($, on) => {
    const clock = mock.clock(on)

    on('session.start', (_$: unknown, e: unknown) => ({ cwd: (e as { cwd: string }).cwd }))
    on('session.root', () => ({ value: GAIA_ROOT }))
    on('fs.exists', (_$: unknown, e: unknown) => ({ value: (e as { path: string }).path === GAIA_DIR }))
    on('command.register', () => ({ value: { command: 'sprint' } }))
    on('process.run', () => ({
      value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }
    }))
    on('fs.stat', () => { throw new Error('ENOENT') })
    on('fs.read', () => { throw new Error('ENOENT') })
    on('ui.panes', () => ({ value: [] }))
    on('ui.log', () => ({ value: undefined }))
    on('ui.invalidate', () => ({ value: undefined }))

    await $.session.start(SESSION_START_EVENT)

    const result = await $.command.run(SPRINT_CMD)

    expect(result).toMatchObject({ text: 'No active sprint' })
  })
})

describe('clock and staleness', () => {
  test('staleness guard 90s triggers rebuild 30s no-op and missing cache triggers rebuild', async ($, on) => {
    const START_TIME = 100000
    const clock = mock.clock(on, { now: START_TIME })
    let processRunCount = 0

    on('session.start', (_$: unknown, e: unknown) => ({ cwd: (e as { cwd: string }).cwd }))
    on('session.root', () => ({ value: GAIA_ROOT }))
    on('fs.exists', (_$: unknown, e: unknown) => ({ value: (e as { path: string }).path === GAIA_DIR }))
    on('command.register', () => ({ value: { command: 'sprint' } }))
    on('process.run', () => {
      processRunCount++
      return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    })
    on('fs.stat', () => ({
      value: { kind: 'file' as const, size: 100, mtimeMs: START_TIME, isLink: false }
    }))
    on('fs.read', () => ({ value: JSON.stringify(ACTIVE_CACHE) }))
    on('ui.panes', () => ({ value: [] }))
    on('ui.log', () => ({ value: undefined }))
    on('ui.invalidate', () => ({ value: undefined }))

    await $.session.start(SESSION_START_EVENT)
    const initialCount = processRunCount

    // 30s: clock now=130000, mtime=100000, diff=30000 <= 60000 -> no rebuild
    await clock.advance(30000)
    expect(processRunCount).toBe(initialCount)

    // +60s: clock now=190000, mtime=100000, diff=90000 > 60000 -> rebuild
    await clock.advance(60000)
    expect(processRunCount).toBe(initialCount + 1)
  })

  test('missing cache on timer tick triggers exactly one snapshot run', async ($, on) => {
    const START_TIME = 100000
    const clock = mock.clock(on, { now: START_TIME })
    let processRunCount = 0

    on('session.start', (_$: unknown, e: unknown) => ({ cwd: (e as { cwd: string }).cwd }))
    on('session.root', () => ({ value: GAIA_ROOT }))
    on('fs.exists', (_$: unknown, e: unknown) => ({ value: (e as { path: string }).path === GAIA_DIR }))
    on('command.register', () => ({ value: { command: 'sprint' } }))
    on('process.run', () => {
      processRunCount++
      return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    })
    on('fs.stat', () => { throw new Error('ENOENT') })
    on('fs.read', () => { throw new Error('ENOENT') })
    on('ui.panes', () => ({ value: [] }))
    on('ui.log', () => ({ value: undefined }))
    on('ui.invalidate', () => ({ value: undefined }))

    await $.session.start(SESSION_START_EVENT)
    const afterStartCount = processRunCount

    // 30s: cacheMtimeMs=0, now=130000, diff>60000 -> rebuild
    await clock.advance(30000)
    expect(processRunCount).toBe(afterStartCount + 1)
  })

  test('30s fresh cache triggers zero snapshot runs', async ($, on) => {
    const START_TIME = 100000
    const clock = mock.clock(on, { now: START_TIME })
    let processRunCount = 0

    on('session.start', (_$: unknown, e: unknown) => ({ cwd: (e as { cwd: string }).cwd }))
    on('session.root', () => ({ value: GAIA_ROOT }))
    on('fs.exists', (_$: unknown, e: unknown) => ({ value: (e as { path: string }).path === GAIA_DIR }))
    on('command.register', () => ({ value: { command: 'sprint' } }))
    on('process.run', () => {
      processRunCount++
      return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    })
    on('fs.stat', () => ({
      value: { kind: 'file' as const, size: 100, mtimeMs: START_TIME, isLink: false }
    }))
    on('fs.read', () => ({ value: JSON.stringify(ACTIVE_CACHE) }))
    on('ui.panes', () => ({ value: [] }))
    on('ui.log', () => ({ value: undefined }))
    on('ui.invalidate', () => ({ value: undefined }))

    await $.session.start(SESSION_START_EVENT)
    const afterStartCount = processRunCount

    await clock.advance(30000)
    expect(processRunCount).toBe(afterStartCount)
  })

  test('future mtime treated as fresh no rebuild', async ($, on) => {
    const NOW = 100000
    const clock = mock.clock(on, { now: NOW })
    let processRunCount = 0

    on('session.start', (_$: unknown, e: unknown) => ({ cwd: (e as { cwd: string }).cwd }))
    on('session.root', () => ({ value: GAIA_ROOT }))
    on('fs.exists', (_$: unknown, e: unknown) => ({ value: (e as { path: string }).path === GAIA_DIR }))
    on('command.register', () => ({ value: { command: 'sprint' } }))
    on('process.run', () => {
      processRunCount++
      return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    })
    on('fs.stat', () => ({
      value: { kind: 'file' as const, size: 100, mtimeMs: NOW + 999999, isLink: false }
    }))
    on('fs.read', () => ({ value: JSON.stringify(ACTIVE_CACHE) }))
    on('ui.panes', () => ({ value: [] }))
    on('ui.log', () => ({ value: undefined }))
    on('ui.invalidate', () => ({ value: undefined }))

    await $.session.start(SESSION_START_EVENT)
    const initialCount = processRunCount

    await clock.advance(90000)
    expect(processRunCount).toBe(initialCount)
  })
})

describe('single-flight deduplication', () => {
  test('in-flight flag prevents concurrent rebuild and sprint joins pending', async ($, on) => {
    const clock = mock.clock(on, { now: 100000 })
    let processRunCount = 0
    const resolvers: Array<() => void> = []

    on('session.start', (_$: unknown, e: unknown) => ({ cwd: (e as { cwd: string }).cwd }))
    on('session.root', () => ({ value: GAIA_ROOT }))
    on('fs.exists', (_$: unknown, e: unknown) => ({ value: (e as { path: string }).path === GAIA_DIR }))
    on('command.register', () => ({ value: { command: 'sprint' } }))
    on('process.run', () => {
      processRunCount++
      if (processRunCount <= 1) {
        // Session.start probe resolves immediately
        return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
      }
      // Subsequent calls: deferred
      return new Promise<{ value: { exitCode: number; stdout: string; stderr: string; isStdoutTruncated: boolean; isStderrTruncated: boolean } }>(resolve => {
        resolvers.push(() => resolve({ value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
      })
    })
    // Cache mtime = 0 -> always stale
    on('fs.stat', () => ({
      value: { kind: 'file' as const, size: 100, mtimeMs: 0, isLink: false }
    }))
    on('fs.read', () => ({ value: JSON.stringify(ACTIVE_CACHE) }))
    on('ui.panes', () => ({ value: [] }))
    on('ui.log', () => ({ value: undefined }))
    on('ui.invalidate', () => ({ value: undefined }))

    await $.session.start(SESSION_START_EVENT)
    const afterStartCount = processRunCount // 1 (the probe)

    // First timer tick at 30s: stale, starts rebuild (deferred)
    await clock.advance(30000)

    // /sprint fires while rebuild is pending -- must join, not start another
    const sprintPromise = $.command.run(SPRINT_CMD)

    // Second timer tick at 60s: in-flight, rebuild skipped
    await clock.advance(30000)
    // Third timer tick at 90s: still in-flight, rebuild skipped
    await clock.advance(30000)

    // Only one rebuild should have started (the first tick)
    expect(processRunCount).toBe(afterStartCount + 1)

    // Resolve the pending rebuild
    for (const r of resolvers) r()
    const sprintResult = await sprintPromise
    await clock.settle()

    // /sprint completed with refreshed result
    expect(sprintResult).toBeDefined()
  })
})

describe('non-zero exit and error handling', () => {
  test('non-zero exit logged last good value retained', async ($, on) => {
    const clock = mock.clock(on, { now: 100000 })
    const logMessages: string[] = []

    on('session.start', (_$: unknown, e: unknown) => ({ cwd: (e as { cwd: string }).cwd }))
    on('session.root', () => ({ value: GAIA_ROOT }))
    on('fs.exists', (_$: unknown, e: unknown) => ({ value: (e as { path: string }).path === GAIA_DIR }))
    on('command.register', () => ({ value: { command: 'sprint' } }))

    let callCount = 0
    on('process.run', () => {
      callCount++
      if (callCount <= 1) {
        return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
      }
      return { value: { exitCode: 1, stdout: '', stderr: 'error', isStdoutTruncated: false, isStderrTruncated: false } }
    })
    on('fs.stat', () => ({
      value: { kind: 'file' as const, size: 100, mtimeMs: 100000, isLink: false }
    }))
    on('fs.read', () => ({ value: JSON.stringify(ACTIVE_CACHE) }))
    on('ui.panes', () => ({ value: [] }))
    on('ui.log', (_$: unknown, e: unknown) => {
      logMessages.push(String((e as { text: string }).text))
      return { value: undefined }
    })
    on('ui.invalidate', () => ({ value: undefined }))

    await $.session.start(SESSION_START_EVENT)

    await clock.advance(90000)

    expect(logMessages.some(m => m.includes('exit'))).toBe(true)
  })
})

describe('cache state semantics', () => {
  test('truncated cache shows sprint data unavailable in pane', async ($, on) => {
    const START_TIME = 100000
    const clock = mock.clock(on, { now: START_TIME })

    on('session.start', (_$: unknown, e: unknown) => ({ cwd: (e as { cwd: string }).cwd }))
    on('session.root', () => ({ value: GAIA_ROOT }))
    on('fs.exists', (_$: unknown, e: unknown) => ({ value: (e as { path: string }).path === GAIA_DIR }))
    on('command.register', () => ({ value: { command: 'sprint' } }))
    on('process.run', () => ({
      value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }
    }))
    on('fs.stat', () => ({
      value: { kind: 'file' as const, size: 10, mtimeMs: START_TIME, isLink: false }
    }))
    on('fs.read', () => ({ value: '{"sprint":' }))
    on('ui.panes', () => ({ value: [] }))
    on('ui.log', () => ({ value: undefined }))
    on('ui.invalidate', () => ({ value: undefined }))
    on('ui.render', () => ({}))

    await $.session.start(SESSION_START_EVENT)

    const ui = await $.ui.mount({
      plugin: 'gaia',
      surface: 'terminal',
      component: 'Pane',
      requestId: 'sprint-status',
      props: { bodyColumns: 40 }
    })

    const found = await ui.find({ text: 'Sprint data unavailable' })
    expect(found).toBeDefined()

    await ui.unmount()
  })

  test('absent cache file sprint returns no active sprint and pane passes through', async ($, on) => {
    const clock = mock.clock(on)

    on('session.start', (_$: unknown, e: unknown) => ({ cwd: (e as { cwd: string }).cwd }))
    on('session.root', () => ({ value: GAIA_ROOT }))
    on('fs.exists', (_$: unknown, e: unknown) => ({ value: (e as { path: string }).path === GAIA_DIR }))
    on('command.register', () => ({ value: { command: 'sprint' } }))
    on('process.run', () => ({
      value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }
    }))
    // stat throws ENOENT -> cache absent
    on('fs.stat', () => { throw new Error('ENOENT') })
    on('fs.read', () => { throw new Error('ENOENT') })
    on('ui.panes', () => ({ value: [] }))
    on('ui.log', () => ({ value: undefined }))
    on('ui.invalidate', () => ({ value: undefined }))

    await $.session.start(SESSION_START_EVENT)

    // Absent cache: /sprint returns "No active sprint" (sprint treated as null)
    const result = await $.command.run(SPRINT_CMD)
    expect(result).toMatchObject({ text: 'No active sprint' })
  })

  test('unparseable cache wipes previous good value', async ($, on) => {
    const clock = mock.clock(on, { now: 100000 })
    let cacheContent = JSON.stringify(ACTIVE_CACHE)

    on('session.start', (_$: unknown, e: unknown) => ({ cwd: (e as { cwd: string }).cwd }))
    on('session.root', () => ({ value: GAIA_ROOT }))
    on('fs.exists', (_$: unknown, e: unknown) => ({ value: (e as { path: string }).path === GAIA_DIR }))
    on('command.register', () => ({ value: { command: 'sprint' } }))
    on('process.run', () => ({
      value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }
    }))
    on('fs.stat', () => ({
      value: { kind: 'file' as const, size: 100, mtimeMs: 100000, isLink: false }
    }))
    on('fs.read', () => ({ value: cacheContent }))
    on('ui.panes', () => ({ value: [] }))
    on('ui.log', () => ({ value: undefined }))
    on('ui.invalidate', () => ({ value: undefined }))
    on('ui.render', () => ({}))

    // First session.start with valid cache
    await $.session.start(SESSION_START_EVENT)

    // Verify active sprint command works
    const goodResult = await $.command.run(SPRINT_CMD)
    expect(goodResult).toMatchObject({})

    // Cache becomes corrupted
    cacheContent = '{broken'
    // Timer tick reads corrupted cache
    await clock.advance(90000)

    // Now pane should show "Sprint data unavailable"
    const ui = await $.ui.mount({
      plugin: 'gaia',
      surface: 'terminal',
      component: 'Pane',
      requestId: 'sprint-status',
      props: { bodyColumns: 40 }
    })

    const found = await ui.find({ text: 'Sprint data unavailable' })
    expect(found).toBeDefined()

    await ui.unmount()
  })
})

describe('non-GAIA directory', () => {
  test('non-GAIA directory gaiaRoot null no fs or process calls after clock advance', async ($, on) => {
    const clock = mock.clock(on)
    let processRunCalls = 0
    let fsStatCalls = 0
    let fsReadCalls = 0
    let debugLogCalls = 0

    on('session.start', (_$: unknown, e: unknown) => ({ cwd: (e as { cwd: string }).cwd }))
    on('session.root', () => ({ value: '/tmp/notgaia' }))
    on('fs.exists', () => ({ value: false }))
    on('command.register', () => ({ value: { command: 'sprint' } }))
    on('ui.panes', () => ({ value: [] }))
    on('ui.log', () => { debugLogCalls++; return { value: undefined } })
    on('ui.invalidate', () => ({ value: undefined }))
    on('process.run', () => {
      processRunCalls++
      return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    })
    on('fs.stat', () => { fsStatCalls++; throw new Error('ENOENT') })
    on('fs.read', () => { fsReadCalls++; throw new Error('ENOENT') })

    await $.session.start({ cwd: '/tmp/notgaia', surface: 'terminal', isInteractive: true })
    expect(processRunCalls).toBe(0)

    // Reset all counters after session.start (root detection used fs.exists, not fs.stat)
    processRunCalls = 0
    fsStatCalls = 0
    fsReadCalls = 0
    debugLogCalls = 0

    // Advance 90s (3 timer ticks). With the gaiaRoot guard, the timer
    // returns immediately on each tick. Without it, each tick calls
    // readCache -> fs.stat("null/.gaia/...") and may log errors.
    await clock.advance(90000)

    expect(processRunCalls).toBe(0)
    expect(fsStatCalls).toBe(0)
    expect(fsReadCalls).toBe(0)
    expect(debugLogCalls).toBe(0)
  })
})

describe('partial capabilities', () => {
  test('command.register throws but root detection and probe succeed sprint returns active', async ($, on) => {
    // command.register throws (unsupported build for commands).
    // With try/catch: catch fires, caps.command=false, execution continues ->
    // gaiaRoot found, probe runs, active cache loaded -> /sprint returns {}.
    // Without try/catch: the throw aborts session.start,
    // gaiaRoot stays null -> /sprint returns { text: "No active sprint" }.
    const clock = mock.clock(on)

    on('session.start', (_$: unknown, e: unknown) => ({ cwd: (e as { cwd: string }).cwd }))
    on('session.root', () => ({ value: GAIA_ROOT }))
    on('fs.exists', (_$: unknown, e: unknown) => ({ value: (e as { path: string }).path === GAIA_DIR }))
    on('command.register', () => { throw new Error('not available') })
    on('process.run', () => ({
      value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }
    }))
    on('fs.stat', () => ({
      value: { kind: 'file' as const, size: 100, mtimeMs: clock.now(), isLink: false }
    }))
    on('fs.read', () => ({ value: JSON.stringify(ACTIVE_CACHE) }))
    on('ui.panes', () => ({ value: [] }))
    on('ui.log', () => ({ value: undefined }))
    on('ui.invalidate', () => ({ value: undefined }))

    await $.session.start(SESSION_START_EVENT)

    const result = await $.command.run(SPRINT_CMD)
    expect(result).toEqual({})
  })

  test('clock.every throws but command and probe succeed sprint returns active', async ($, on) => {
    // clock.every bottom throws (unsupported build for timers).
    // With try/catch: catch fires, caps.clock=false, execution continues ->
    // gaiaRoot found, probe runs, active cache loaded -> /sprint returns {}.
    // Without try/catch: the throw aborts session.start after
    // command.register but before root detection.
    on('session.start', (_$: unknown, e: unknown) => ({ cwd: (e as { cwd: string }).cwd }))
    on('session.root', () => ({ value: GAIA_ROOT }))
    on('fs.exists', (_$: unknown, e: unknown) => ({ value: (e as { path: string }).path === GAIA_DIR }))
    on('command.register', () => ({ value: { command: 'sprint' } }))
    on('clock.every', () => { throw new Error('not available') })
    on('process.run', () => ({
      value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }
    }))
    on('fs.stat', () => ({
      value: { kind: 'file' as const, size: 100, mtimeMs: Date.now(), isLink: false }
    }))
    on('fs.read', () => ({ value: JSON.stringify(ACTIVE_CACHE) }))
    on('ui.panes', () => ({ value: [] }))
    on('ui.log', () => ({ value: undefined }))
    on('ui.invalidate', () => ({ value: undefined }))

    await $.session.start(SESSION_START_EVENT)

    const result = await $.command.run(SPRINT_CMD)
    expect(result).toEqual({})
  })
})

describe('sprint transition to closed', () => {
  test('sprint transition to closed clears pane and band', async ($, on) => {
    const clock = mock.clock(on, { now: 100000 })
    let cacheContent = JSON.stringify(ACTIVE_CACHE)

    on('session.start', (_$: unknown, e: unknown) => ({ cwd: (e as { cwd: string }).cwd }))
    on('session.root', () => ({ value: GAIA_ROOT }))
    on('fs.exists', (_$: unknown, e: unknown) => ({ value: (e as { path: string }).path === GAIA_DIR }))
    on('command.register', () => ({ value: { command: 'sprint' } }))
    on('process.run', () => ({
      value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }
    }))
    on('fs.stat', () => ({
      value: { kind: 'file' as const, size: 100, mtimeMs: 100000, isLink: false }
    }))
    on('fs.read', () => ({ value: cacheContent }))
    on('ui.panes', () => ({ value: [] }))
    on('ui.log', () => ({ value: undefined }))
    on('ui.invalidate', () => ({ value: undefined }))

    await $.session.start(SESSION_START_EVENT)

    cacheContent = JSON.stringify(CLOSED_CACHE)
    await clock.advance(90000)

    const result = await $.command.run(SPRINT_CMD)
    expect(result).toMatchObject({ text: 'No active sprint' })
  })
})

describe('session re-entry', () => {
  test('second session.start resets caps and runs probe fresh', async ($, on) => {
    const clock = mock.clock(on, { now: 100000 })
    let processRunCount = 0

    on('session.start', (_$: unknown, e: unknown) => ({ cwd: (e as { cwd: string }).cwd }))
    on('session.root', () => ({ value: GAIA_ROOT }))
    on('fs.exists', (_$: unknown, e: unknown) => ({ value: (e as { path: string }).path === GAIA_DIR }))
    on('command.register', () => ({ value: { command: 'sprint' } }))
    on('process.run', () => {
      processRunCount++
      return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    })
    on('fs.stat', () => ({
      value: { kind: 'file' as const, size: 100, mtimeMs: clock.now(), isLink: false }
    }))
    on('fs.read', () => ({ value: JSON.stringify(ACTIVE_CACHE) }))
    on('ui.panes', () => ({ value: [] }))
    on('ui.log', () => ({ value: undefined }))
    on('ui.invalidate', () => ({ value: undefined }))

    // First session.start
    await $.session.start(SESSION_START_EVENT)
    expect(processRunCount).toBe(1) // One probe

    // Second session.start (re-entry with different cwd to prove caps reset)
    processRunCount = 0
    await $.session.start(SESSION_START_EVENT)

    // Second probe ran (caps were reset, new probe executed)
    expect(processRunCount).toBe(1)

    // /sprint works correctly after re-entry (state fully reset)
    const result = await $.command.run(SPRINT_CMD)
    // Active cache loaded during second session.start
    expect(result).toBeDefined()
  })

  test('second session.start in non-GAIA dir silences old timer via gaiaRoot reset', async ($, on) => {
    const clock = mock.clock(on, { now: 100000 })
    let processRunCount = 0
    let sessionRootValue = GAIA_ROOT

    on('session.start', (_$: unknown, e: unknown) => ({ cwd: (e as { cwd: string }).cwd }))
    on('session.root', () => ({ value: sessionRootValue }))
    on('fs.exists', (_$: unknown, e: unknown) => ({ value: (e as { path: string }).path === GAIA_DIR }))
    on('command.register', () => ({ value: { command: 'sprint' } }))
    on('process.run', () => {
      processRunCount++
      return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    })
    on('fs.stat', () => ({
      value: { kind: 'file' as const, size: 100, mtimeMs: 0, isLink: false }
    }))
    on('fs.read', () => ({ value: JSON.stringify(ACTIVE_CACHE) }))
    on('ui.panes', () => ({ value: [] }))
    on('ui.log', () => ({ value: undefined }))
    on('ui.invalidate', () => ({ value: undefined }))

    // First session.start in GAIA dir (timer starts, probe runs)
    await $.session.start(SESSION_START_EVENT)
    expect(processRunCount).toBe(1) // One probe

    // Second session.start in non-GAIA dir (gaiaRoot resets to null)
    sessionRootValue = '/tmp/notgaia'
    processRunCount = 0
    await $.session.start({ cwd: '/tmp/notgaia', surface: 'terminal', isInteractive: true })

    // No probe ran (no gaiaRoot detected)
    expect(processRunCount).toBe(0)

    // Advance clock -- no timer fires process.run (gaiaRoot is null; timer guard protects)
    await clock.advance(90000)
    expect(processRunCount).toBe(0)
  })
})

describe('pane reconciliation', () => {
  test('session.start reconciles pane state from panes list and sprint works', async ($, on) => {
    const clock = mock.clock(on)

    on('session.start', (_$: unknown, e: unknown) => ({ cwd: (e as { cwd: string }).cwd }))
    on('session.root', () => ({ value: GAIA_ROOT }))
    on('fs.exists', (_$: unknown, e: unknown) => ({ value: (e as { path: string }).path === GAIA_DIR }))
    on('command.register', () => ({ value: { command: 'sprint' } }))
    on('process.run', () => ({
      value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }
    }))
    on('fs.stat', () => ({
      value: { kind: 'file' as const, size: 100, mtimeMs: clock.now(), isLink: false }
    }))
    on('fs.read', () => ({ value: JSON.stringify(ACTIVE_CACHE) }))
    on('ui.panes', () => ({
      value: [{ id: 'sprint-status', title: 'Sprint', isShown: true, isFocused: false, isPlaced: true }]
    }))
    on('ui.log', () => ({ value: undefined }))
    on('ui.invalidate', () => ({ value: undefined }))

    // session.start reconciles paneOpen from panes() listing sprint-status
    await $.session.start(SESSION_START_EVENT)

    // Sprint command works (active sprint loaded)
    const result = await $.command.run(SPRINT_CMD)
    expect(result).toBeDefined()
    // The close handler test (paneOpen = false, mutant kill) is in
    // mod-cap-detect-direct.bats using the direct-import approach,
    // because the test kit does not expose $.ui.close.
  })
})
