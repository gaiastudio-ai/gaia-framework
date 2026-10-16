import { test, expect, mock, describe } from 'claude-code/testing'

// Cache fixture in the snapshot script's schema. mod-cache-contract.bats
// checks every field path used here against the script's real output.
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

const CLOSED_CACHE = { ...ACTIVE_CACHE, sprint: { ...ACTIVE_CACHE.sprint, status: 'closed' } }

const GAIA_ROOT = '/project'
const NO_SPRINT = { text: 'No active sprint' }
const SCRIPT_SUFFIX = '/scripts/sprint-progress-snapshot.sh'
// The plugin folder: this file lives in <plugin>/hooks/.
const PLUGIN_ROOT = decodeURIComponent(new URL('..', import.meta.url).pathname).replace(/\/$/, '')
const SPRINT_CMD = {
  command: 'sprint',
  args: '',
  origin: { kind: 'plugin' as const, name: 'test' },
  presentation: { isFullscreen: false, columns: 80 }
}

const OK_RUN = { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }

type Run = { argv: string[]; init: { cwd?: string; env?: Record<string, string>; timeoutMs?: number } }
type Cache = { content: string | null; mtimeMs: number }
type WorldOptions = {
  now?: number
  sessionRoot?: string
  home?: string
  gaiaDirs?: string[]
  cache?: Cache
  // Answers one process.run call: a result, a promise of one, or a throw.
  run?: (n: number, world: World) => unknown
  panes?: unknown[]
  // Replaces the fs.read answer.
  read?: () => unknown
  commandThrows?: boolean
}
type World = {
  clock: ReturnType<typeof mock.clock>
  cache: Cache
  runs: Run[]
  logs: { text: string; to?: string }[]
  invalidates: number
  stats: number
  reads: number
  sessionRoot: string
}

// Stands in for the engine beneath the plugin. Counts every call the plugin
// makes so tests can assert on exact numbers.
function world(on: any, opts: WorldOptions = {}): World {
  const clock = mock.clock(on, { now: opts.now ?? 100000 })
  const w: World = {
    clock,
    cache: opts.cache ?? { content: JSON.stringify(ACTIVE_CACHE), mtimeMs: opts.now ?? 100000 },
    runs: [], logs: [], invalidates: 0, stats: 0, reads: 0,
    sessionRoot: opts.sessionRoot ?? GAIA_ROOT
  }
  const gaiaDirs = opts.gaiaDirs ?? [GAIA_ROOT + '/.gaia']
  if (opts.home !== undefined) mock.env(on, { HOME: opts.home })
  on('session.start', (_$: unknown, e: any) => ({ cwd: e.cwd }))
  on('session.root', () => ({ value: w.sessionRoot }))
  on('fs.exists', (_$: unknown, e: any) => ({ value: gaiaDirs.includes(e.path) }))
  on('command.register', () => {
    if (opts.commandThrows) throw new Error('not available')
    return { value: { command: 'sprint' } }
  })
  on('process.run', (_$: unknown, e: any) => {
    w.runs.push({ argv: e.argv, init: e.init })
    if (opts.run) return opts.run(w.runs.length, w)
    return { value: OK_RUN }
  })
  on('fs.stat', () => {
    w.stats++
    if (w.cache.content === null) throw new Error('ENOENT')
    return { value: { kind: 'file' as const, size: w.cache.content.length, mtimeMs: w.cache.mtimeMs, isLink: false } }
  })
  on('fs.read', () => {
    w.reads++
    if (opts.read) return opts.read()
    if (w.cache.content === null) throw new Error('ENOENT')
    return { value: w.cache.content }
  })
  on('ui.panes', () => ({ value: opts.panes ?? [] }))
  on('ui.log', (_$: unknown, e: any) => {
    w.logs.push({ text: String(e.text), to: e.to })
    return { value: undefined }
  })
  on('ui.invalidate', () => { w.invalidates++; return { value: undefined } })
  on('ui.render', { component: 'Pane' }, ($: any, e: any) => h($.ui.resolve(e).Text, null, 'BOTTOM PANE'))
  on('ui.render', { component: 'AbovePrompt' }, ($: any, e: any) => h($.ui.resolve(e).Text, null, 'OTHER MOD BAND'))
  return w
}

async function start($: any, w: World) {
  await $.session.start({ cwd: w.sessionRoot, surface: 'terminal', isInteractive: true })
  await w.clock.settle()
}

function writer(w: World) {
  return () => { w.cache.mtimeMs = w.clock.now(); return { value: OK_RUN } }
}

function deferred() {
  const pending: Array<() => void> = []
  const run = () => new Promise(resolve => { pending.push(() => resolve({ value: OK_RUN })) })
  const release = () => { while (pending.length) pending.shift()!() }
  return { run, release, pending }
}

async function mountPane($: any) {
  return $.ui.mount({ plugin: 'gaia', surface: 'terminal', component: 'Pane', requestId: 'sprint-status',
    props: { bodyColumns: 40 } })
}

describe('registration and the snapshot call', () => {
  test('active sprint: sprint returns an empty result', async ($, on) => {
    const w = world(on, { run: (_n, wl) => writer(wl)() })
    await start($, w)
    expect(await $.command.run(SPRINT_CMD)).toEqual({})
  })

  test('the plugin script runs from the plugin folder with fixed options', async ($, on) => {
    const w = world(on)
    await start($, w)
    expect(w.runs.length).toBe(1)
    expect(w.runs[0].argv).toEqual([PLUGIN_ROOT + SCRIPT_SUFFIX])
    expect(w.runs[0].init).toEqual({ cwd: GAIA_ROOT, env: { PROJECT_ROOT: GAIA_ROOT }, timeoutMs: 30000 })
  })

  test('a snapshot script planted in the project is never run', async ($, on) => {
    const w = world(on, { gaiaDirs: [GAIA_ROOT + '/.gaia', GAIA_ROOT + SCRIPT_SUFFIX] })
    await start($, w)
    await $.command.run(SPRINT_CMD)
    await w.clock.advance(90000)
    expect(w.runs.length).toBeGreaterThan(0)
    for (const r of w.runs) {
      expect(r.argv[0]).toBe(PLUGIN_ROOT + SCRIPT_SUFFIX)
      expect(r.argv[0].startsWith(GAIA_ROOT + '/')).toBe(false)
    }
  })
})

describe('graceful degradation', () => {
  test('all members throw: no user-visible output and no process run', async ($, on) => {
    let notices = 0
    let toasts = 0
    let nonDebugLogs = 0
    let runs = 0
    on('session.start', (_$: unknown, e: any) => ({ cwd: e.cwd }))
    on('session.root', () => { throw new Error('not available') })
    on('fs.exists', () => { throw new Error('not available') })
    on('command.register', () => { throw new Error('not available') })
    on('process.run', () => { runs++; throw new Error('not available') })
    on('ui.panes', () => { throw new Error('not available') })
    on('ui.log', (_$: unknown, e: any) => {
      if (e.to !== 'debug') nonDebugLogs++
      return { value: undefined }
    })
    on('ui.notice', () => { notices++; return { value: undefined } })
    on('ui.toast', () => { toasts++; return { value: undefined } })
    on('ui.invalidate', () => ({ value: undefined }))

    const result = await $.session.start({ cwd: '/nowhere', surface: 'terminal', isInteractive: true })
    expect(result).toEqual({ cwd: '/nowhere' })
    expect(notices).toBe(0)
    expect(toasts).toBe(0)
    expect(nonDebugLogs).toBe(0)
    expect(runs).toBe(0)
  })

  test('a process run that throws is logged and switches snapshots off', async ($, on) => {
    const w = world(on, { run: () => { throw new Error('cannot start') } })
    await start($, w)
    expect(w.logs.some(l => l.text.startsWith('snapshot did not run') && l.to === 'debug')).toBe(true)
    // The cache on disk is still read: the sprint is active.
    expect(await $.command.run(SPRINT_CMD)).toEqual({})
    // With the process capability off, /sprint re-reads instead of running again.
    expect(w.runs.length).toBe(1)
  })

  test('pane passes through when the process capability is off', async ($, on) => {
    const w = world(on, { run: () => { throw new Error('cannot start') }, cache: { content: '{"sprint":', mtimeMs: 100000 } })
    await start($, w)
    const ui = await mountPane($)
    expect(await ui.find({ text: 'BOTTOM PANE' })).toBeDefined()
    expect(await ui.find({ text: 'Sprint data unavailable' })).toBeUndefined()
    await ui.unmount()
  })
})

describe('session start does not wait for the snapshot', () => {
  test('session start returns while the first snapshot is still running', async ($, on) => {
    const slow = deferred()
    const w = world(on, { run: n => (n === 1 ? slow.run() : { value: OK_RUN }) })
    let started = false
    const p = $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true }).then(() => { started = true })
    await w.clock.settle()
    expect(started).toBe(true)
    expect(w.runs.length).toBe(1)
    expect(slow.pending.length).toBe(1)
    slow.release()
    await p
    await w.clock.settle()
    // Probe resolved: /sprint now runs a snapshot of its own.
    await $.command.run(SPRINT_CMD)
    expect(w.runs.length).toBe(2)
  })
})

describe('/sprint command', () => {
  test('non-GAIA directory: no active sprint and no file or process call', async ($, on) => {
    const w = world(on, { sessionRoot: '/tmp/notgaia', gaiaDirs: [] })
    let opens = 0
    on('ui.open', () => { opens++; return { value: { isPlaced: false, reason: 'none' } } })
    await start($, w)
    w.stats = 0
    w.reads = 0
    expect(await $.command.run(SPRINT_CMD)).toEqual(NO_SPRINT)
    expect(w.stats).toBe(0)
    expect(w.reads).toBe(0)
    expect(w.runs.length).toBe(0)
    expect(opens).toBe(0)
  })

  test('process failed and no cache: no active sprint', async ($, on) => {
    const w = world(on, { run: () => { throw new Error('process start failed') }, cache: { content: null, mtimeMs: 0 } })
    await start($, w)
    expect(await $.command.run(SPRINT_CMD)).toEqual(NO_SPRINT)
  })

  test('cache still missing after the snapshot: no active sprint', async ($, on) => {
    const w = world(on, { cache: { content: null, mtimeMs: 0 } })
    await start($, w)
    expect(await $.command.run(SPRINT_CMD)).toEqual(NO_SPRINT)
  })

  test('refresh runs first: a snapshot that creates the cache gives an active sprint', async ($, on) => {
    const w = world(on, {
      cache: { content: null, mtimeMs: 0 },
      run: (n, wl) => {
        // The probe leaves no cache; the run /sprint starts writes one.
        if (n >= 2) { wl.cache.content = JSON.stringify(ACTIVE_CACHE); wl.cache.mtimeMs = wl.clock.now() }
        return { value: OK_RUN }
      }
    })
    await start($, w)
    expect(w.runs.length).toBe(1)
    expect(await $.command.run(SPRINT_CMD)).toEqual({})
    expect(w.runs.length).toBe(2)
  })

  test('error text never reaches the user', async ($, on) => {
    const w = world(on, {
      run: () => { throw new Error('EACCES /secret/path') },
      read: () => { throw new Error('EACCES /secret/cache') }
    })
    await start($, w)
    const result = await $.command.run(SPRINT_CMD)
    expect(result).toEqual(NO_SPRINT)
    expect(JSON.stringify(result).includes('secret')).toBe(false)
  })

  test('a snapshot run that fails during /sprint shows no error text', async ($, on) => {
    const w = world(on, {
      run: n => { if (n >= 2) throw new Error('timed out in /secret/dir'); return { value: OK_RUN } }
    })
    await start($, w)
    w.cache.content = null
    const result = await $.command.run(SPRINT_CMD)
    expect(w.runs.length).toBe(2)
    expect(result).toEqual(NO_SPRINT)
  })

  test('sprint transition to closed: no active sprint', async ($, on) => {
    const w = world(on)
    await start($, w)
    expect(await $.command.run(SPRINT_CMD)).toEqual({})
    w.cache.content = JSON.stringify(CLOSED_CACHE)
    w.cache.mtimeMs = w.clock.now() + 1
    await w.clock.advance(30000)
    expect(await $.command.run(SPRINT_CMD)).toEqual(NO_SPRINT)
  })
})

describe('exit codes', () => {
  test('exit 0 logs nothing about the exit code', async ($, on) => {
    const w = world(on)
    await start($, w)
    expect(w.logs.filter(l => l.text.startsWith('snapshot exited')).length).toBe(0)
  })

  test('non-zero exit is logged to debug and the last good value is kept', async ($, on) => {
    const w = world(on, { run: () => ({ value: { ...OK_RUN, exitCode: 1, stderr: 'boom' } }) })
    await start($, w)
    const exits = w.logs.filter(l => l.text.startsWith('snapshot exited'))
    expect(exits).toEqual([{ text: 'snapshot exited 1', to: 'debug' }])
    // The cache read before the failed run still answers /sprint.
    expect(await $.command.run(SPRINT_CMD)).toEqual({})
  })
})

describe('clock and staleness', () => {
  test('90 s old cache triggers one snapshot then one invalidate; 30 s triggers none', async ($, on) => {
    const w = world(on, { now: 100000, cache: { content: JSON.stringify(ACTIVE_CACHE), mtimeMs: 100000 } })
    await start($, w)
    const runs0 = w.runs.length
    const inv0 = w.invalidates
    await w.clock.advance(30000) // 30 s old: fresh
    expect(w.runs.length).toBe(runs0)
    expect(w.invalidates).toBe(inv0)
    await w.clock.advance(30000) // 60 s old: still fresh
    expect(w.runs.length).toBe(runs0)
    await w.clock.advance(30000) // 90 s old: stale
    expect(w.runs.length).toBe(runs0 + 1)
    expect(w.invalidates).toBe(inv0 + 1)
  })

  test('missing cache on a timer tick triggers exactly one snapshot run', async ($, on) => {
    const w = world(on, { cache: { content: null, mtimeMs: 0 } })
    await start($, w)
    const runs0 = w.runs.length
    await w.clock.advance(30000)
    expect(w.runs.length).toBe(runs0 + 1)
  })

  test('future mtime is treated as fresh', async ($, on) => {
    const w = world(on, { now: 100000, cache: { content: JSON.stringify(ACTIVE_CACHE), mtimeMs: 100000 + 999999 } })
    await start($, w)
    const runs0 = w.runs.length
    await w.clock.advance(90000)
    expect(w.runs.length).toBe(runs0)
  })

  test('each tick stats the cache and re-reads it only when it changed', async ($, on) => {
    const w = world(on)
    await start($, w)
    const stats0 = w.stats
    const reads0 = w.reads
    await w.clock.advance(30000)
    expect(w.stats).toBe(stats0 + 1)
    expect(w.reads).toBe(reads0)
    w.cache.mtimeMs = w.clock.now()
    await w.clock.advance(30000)
    expect(w.stats).toBe(stats0 + 2)
    expect(w.reads).toBe(reads0 + 1)
  })
})

describe('single flight', () => {
  test('timer tick and /sprint during a slow probe start no second snapshot', async ($, on) => {
    const slow = deferred()
    const w = world(on, { run: () => slow.run(), cache: { content: JSON.stringify(ACTIVE_CACHE), mtimeMs: 0 } })
    await start($, w)
    expect(w.runs.length).toBe(1)
    let sprintResult: unknown = 'pending'
    const sprint = $.command.run(SPRINT_CMD).then((r: unknown) => { sprintResult = r })
    await w.clock.advance(30000)
    await w.clock.advance(30000)
    expect(w.runs.length).toBe(1)
    // /sprint joined the running snapshot: it has not answered yet.
    expect(sprintResult).toBe('pending')
    slow.release()
    await sprint
    expect(sprintResult).toEqual({})
    expect(w.runs.length).toBe(1)
  })

  test('re-entry keeps a running snapshot and joins it', async ($, on) => {
    const slow = deferred()
    const w = world(on, { run: () => slow.run() })
    await start($, w)
    await start($, w)
    expect(w.runs.length).toBe(1)
    slow.release()
    await w.clock.settle()
    expect(w.runs.length).toBe(1)
  })
})

describe('session re-entry', () => {
  test('GAIA to GAIA re-entry: exactly one snapshot run per tick', async ($, on) => {
    // The writer moves the mtime on every run but leaves it old, so every
    // tick sees a stale cache and every live timer would start a run.
    const w = world(on, {
      now: 1000000,
      cache: { content: JSON.stringify(ACTIVE_CACHE), mtimeMs: 1 },
      run: (_n, wl) => { wl.cache.mtimeMs += 1; return { value: OK_RUN } }
    })
    await start($, w)
    await start($, w)
    await start($, w)
    const runs0 = w.runs.length
    await w.clock.advance(30000)
    expect(w.runs.length).toBe(runs0 + 1)
    await w.clock.advance(30000)
    expect(w.runs.length).toBe(runs0 + 2)
  })

  test('re-entry in a non-GAIA directory silences the old timer', async ($, on) => {
    const w = world(on, { cache: { content: JSON.stringify(ACTIVE_CACHE), mtimeMs: 0 } })
    await start($, w)
    expect(w.runs.length).toBe(1)
    w.sessionRoot = '/tmp/notgaia'
    await start($, w)
    await w.clock.advance(90000)
    expect(w.runs.length).toBe(1)
  })
})

describe('backoff', () => {
  test('a writer that never moves the cache is retried less and less often', async ($, on) => {
    const w = world(on, { now: 1000000, cache: { content: JSON.stringify(ACTIVE_CACHE), mtimeMs: 1 } })
    await start($, w)
    await w.clock.advance(600000)
    // Probe at 0 s, then 30 s, 90 s, 210 s and 450 s: 5 runs, not 21.
    expect(w.runs.length).toBe(5)
  })

  test('a run that moves the cache ends the backoff', async ($, on) => {
    let moving = false
    const w = world(on, {
      now: 1000000,
      cache: { content: JSON.stringify(ACTIVE_CACHE), mtimeMs: 1 },
      run: (_n, wl) => { if (moving) wl.cache.mtimeMs += 1; return { value: OK_RUN } }
    })
    await start($, w)
    await w.clock.advance(210000) // runs at 0, 30, 90, 210 s
    expect(w.runs.length).toBe(4)
    moving = true
    await w.clock.advance(240000) // run at 450 s moves the cache
    expect(w.runs.length).toBe(5)
    await w.clock.advance(30000) // back to one run per stale tick
    expect(w.runs.length).toBe(6)
    await w.clock.advance(30000)
    expect(w.runs.length).toBe(7)
  })
})

describe('cache state', () => {
  test('truncated cache shows sprint data unavailable in the pane', async ($, on) => {
    const w = world(on, { cache: { content: '{"sprint":', mtimeMs: 100000 } })
    await start($, w)
    const ui = await mountPane($)
    expect(await ui.find({ text: 'Sprint data unavailable' })).toBeDefined()
    await ui.unmount()
  })

  test('absent cache: pane shows fallback', async ($, on) => {
    const w = world(on, { cache: { content: null, mtimeMs: 0 } })
    await start($, w)
    const ui = await mountPane($)
    expect(await ui.find({ text: 'Sprint data unavailable' })).toBeDefined()
    await ui.unmount()
  })

  test('unparseable cache wipes the previous good value', async ($, on) => {
    const w = world(on)
    await start($, w)
    expect(await $.command.run(SPRINT_CMD)).toEqual({})
    w.cache.content = '{broken'
    w.cache.mtimeMs = w.clock.now() + 1
    await w.clock.advance(30000)
    const ui = await mountPane($)
    expect(await ui.find({ text: 'Sprint data unavailable' })).toBeDefined()
    await ui.unmount()
  })
})

describe('render path', () => {
  test('rendering the pane and the band does no file or process work', async ($, on) => {
    const w = world(on)
    await start($, w)
    const before = { stats: w.stats, reads: w.reads, runs: w.runs.length }
    const pane = await mountPane($)
    await pane.unmount()
    const band = await $.ui.mount({ plugin: 'gaia', surface: 'terminal', component: 'AbovePrompt', props: {} })
    await band.unmount()
    expect({ stats: w.stats, reads: w.reads, runs: w.runs.length }).toEqual(before)
  })

  test('the band keeps what other mods draw', async ($, on) => {
    const w = world(on)
    await start($, w)
    const band = await $.ui.mount({ plugin: 'gaia', surface: 'terminal', component: 'AbovePrompt', props: {} })
    expect(await band.find({ text: 'OTHER MOD BAND' })).toBeDefined()
    await band.unmount()
  })
})

describe('GAIA root detection', () => {
  test('a subdirectory session finds the project root above it', async ($, on) => {
    const w = world(on, { home: '/home/u', sessionRoot: '/home/u/project/pkg/sub', gaiaDirs: ['/home/u/project/.gaia'] })
    await start($, w)
    expect(w.runs.length).toBe(1)
    expect(w.runs[0].init.cwd).toBe('/home/u/project')
  })

  test('the walk stops at the home directory', async ($, on) => {
    const w = world(on, { home: '/home/u', sessionRoot: '/home/u/a/b', gaiaDirs: ['/home/.gaia', '/.gaia'] })
    await start($, w)
    expect(w.runs.length).toBe(0)
    expect(await $.command.run(SPRINT_CMD)).toEqual(NO_SPRINT)
  })

  test('outside home only the session root itself is checked', async ($, on) => {
    const shared = world(on, { home: '/home/u', sessionRoot: '/tmp/x/y', gaiaDirs: ['/tmp/.gaia', '/tmp/x/.gaia'] })
    await start($, shared)
    expect(shared.runs.length).toBe(0)
  })

  test('outside home a .gaia in the session root itself is found', async ($, on) => {
    const w = world(on, { home: '/home/u', sessionRoot: '/srv/proj/', gaiaDirs: ['/srv/proj/.gaia'] })
    await start($, w)
    expect(w.runs.length).toBe(1)
    expect(w.runs[0].init.cwd).toBe('/srv/proj')
  })
})

describe('partial capabilities', () => {
  test('command.register throws but root detection and probe succeed: sprint is active', async ($, on) => {
    world(on, { commandThrows: true })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    expect(await $.command.run(SPRINT_CMD)).toEqual({})
  })

  test('clock.every throws but command and probe succeed: sprint is active', async ($, on) => {
    on('session.start', (_$: unknown, e: any) => ({ cwd: e.cwd }))
    on('session.root', () => ({ value: GAIA_ROOT }))
    on('fs.exists', (_$: unknown, e: any) => ({ value: e.path === GAIA_ROOT + '/.gaia' }))
    on('command.register', () => ({ value: { command: 'sprint' } }))
    on('clock.every', () => { throw new Error('not available') })
    on('clock.now', () => ({ value: 100000 }))
    on('process.run', () => ({ value: OK_RUN }))
    on('fs.stat', () => ({ value: { kind: 'file' as const, size: 10, mtimeMs: 100000, isLink: false } }))
    on('fs.read', () => ({ value: JSON.stringify(ACTIVE_CACHE) }))
    on('ui.panes', () => ({ value: [] }))
    on('ui.log', () => ({ value: undefined }))
    on('ui.invalidate', () => ({ value: undefined }))
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    expect(await $.command.run(SPRINT_CMD)).toEqual({})
  })
})
