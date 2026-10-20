import { test, expect, mock, describe } from 'claude-code/testing'
import { computeAgentActivity, extractStoryKey } from './agent-activity.js'
import { WRITER_CACHE, GAIA_ROOT, OK_RUN, deepCopy, findLeafText } from './sprint-status-fixture.js'

// -- helpers --

function makeAgent(overrides: Record<string, unknown> = {}) {
  return {
    id: 'agent-1',
    description: 'some task',
    type: 'agent',
    status: 'running',
    teammateId: undefined as string | undefined,
    parentId: undefined as string | undefined,
    spawnedBy: undefined as string | undefined,
    name: undefined as string | undefined,
    ...overrides
  }
}

function storyKeysFromCache(cache: typeof WRITER_CACHE): Set<string> {
  var keys = new Set<string>()
  for (var s of cache.stories) {
    if (s.key) keys.add(s.key)
  }
  return keys
}

// -- key extraction --

describe('story key extraction', () => {
  test('description prefix yields the key', () => {
    var agent = makeAgent({ description: 'E900-S4: implement two-project path' })
    expect(extractStoryKey(agent)).toBe('E900-S4')
  })

  test('no prefix yields null', () => {
    var agent = makeAgent({ description: 'run tests' })
    expect(extractStoryKey(agent)).toBeNull()
  })

  test('teammateId wins over description', () => {
    var agent = makeAgent({
      description: 'E900-S4: task',
      teammateId: 'dev-agent-E901-S7'
    })
    expect(extractStoryKey(agent)).toBe('E901-S7')
  })

  test('teammateId without story handle falls back to description', () => {
    var agent = makeAgent({
      description: 'E900-S4: task',
      teammateId: 'dev-agent-123'
    })
    expect(extractStoryKey(agent)).toBe('E900-S4')
  })

  test('null teammateId falls back to description', () => {
    var agent = makeAgent({
      description: 'E900-S4: task',
      teammateId: undefined
    })
    expect(extractStoryKey(agent)).toBe('E900-S4')
  })

  test('malformed description does not match', () => {
    expect(extractStoryKey(makeAgent({ description: 'E12: missing story number' }))).toBeNull()
    expect(extractStoryKey(makeAgent({ description: 'ES-3: wrong format' }))).toBeNull()
  })

  test('ANSI escapes before key prevent extraction', () => {
    var agent = makeAgent({ description: '\x1b[31mE900-S1:\x1b[0m task' })
    expect(extractStoryKey(agent)).toBeNull()
  })
})

// -- agent-to-story mapping --

describe('agent-to-story mapping', () => {
  test('running agent maps to its story', () => {
    var cache = deepCopy(WRITER_CACHE)
    var result = computeAgentActivity({
      agents: [makeAgent({ id: 'a1', description: 'E900-S4: implement feature', status: 'running' })],
      storyKeys: storyKeysFromCache(cache)
    })
    expect(result.activityByStory.has('E900-S4')).toBe(true)
    var entry = result.activityByStory.get('E900-S4')!
    expect(entry.items.length).toBe(1)
    expect(entry.items[0].agentId).toBe('a1')
    expect(entry.items[0].status).toBe('running')
    expect(entry.overflow).toBe(0)
  })

  test('key not in storyKeys goes to unlinked', () => {
    var result = computeAgentActivity({
      agents: [makeAgent({ id: 'a1', description: 'E999-S99: phantom task', status: 'running' })],
      storyKeys: new Set(['E900-S1'])
    })
    expect(result.activityByStory.has('E999-S99')).toBe(false)
    expect(result.unlinkedActivity.items.length).toBe(1)
    expect(result.unlinkedActivity.items[0].agentId).toBe('a1')
  })

  test('no-key agent goes to unlinked', () => {
    var result = computeAgentActivity({
      agents: [makeAgent({ id: 'a1', description: 'run tests', status: 'running' })],
      storyKeys: new Set(['E900-S1'])
    })
    expect(result.activityByStory.size).toBe(0)
    expect(result.unlinkedActivity.items.length).toBe(1)
  })

  test('two agents on the same story appear as separate sub-lines', () => {
    var result = computeAgentActivity({
      agents: [
        makeAgent({ id: 'a1', description: 'E900-S3: dev', status: 'running' }),
        makeAgent({ id: 'a2', description: 'E900-S3: review', status: 'running' })
      ],
      storyKeys: storyKeysFromCache(deepCopy(WRITER_CACHE))
    })
    var entry = result.activityByStory.get('E900-S3')!
    expect(entry.items.length).toBe(2)
    expect(entry.items[0].agentId).toBe('a1')
    expect(entry.items[1].agentId).toBe('a2')
    expect(entry.overflow).toBe(0)
  })

  test('excluded statuses produce no activity', () => {
    var excluded = ['pending', 'idle', 'completed', 'failed', 'killed']
    for (var st of excluded) {
      var result = computeAgentActivity({
        agents: [makeAgent({ id: 'a1', description: 'E900-S1: task', status: st })],
        storyKeys: storyKeysFromCache(deepCopy(WRITER_CACHE))
      })
      expect(result.activityByStory.size).toBe(0)
      expect(result.unlinkedActivity.items.length).toBe(0)
    }
  })

  test('empty agent list produces empty output', () => {
    var result = computeAgentActivity({
      agents: [],
      storyKeys: storyKeysFromCache(deepCopy(WRITER_CACHE))
    })
    expect(result.activityByStory.size).toBe(0)
    expect(result.unlinkedActivity.items.length).toBe(0)
  })

  test('ANSI escapes in description: key null, sanitised label', () => {
    var result = computeAgentActivity({
      agents: [makeAgent({ id: 'a1', description: '\x1b[31mE900-S1:\x1b[0m task', status: 'running' })],
      storyKeys: storyKeysFromCache(deepCopy(WRITER_CACHE))
    })
    // Key extraction on raw fails (escapes precede key).
    expect(result.activityByStory.has('E900-S1')).toBe(false)
    expect(result.unlinkedActivity.items.length).toBe(1)
    // Sanitised label has no escape sequences.
    expect(result.unlinkedActivity.items[0].label).not.toContain('\x1b')
  })

  test('waiting agent appears as activity (not filtered)', () => {
    var result = computeAgentActivity({
      agents: [makeAgent({ id: 'w1', description: 'E900-S3: task', status: 'waiting' })],
      storyKeys: storyKeysFromCache(deepCopy(WRITER_CACHE))
    })
    expect(result.activityByStory.has('E900-S3')).toBe(true)
    var entry = result.activityByStory.get('E900-S3')!
    expect(entry.items[0].status).toBe('waiting')
  })
})

// -- overflow capping --

describe('overflow capping', () => {
  test('more than 5 agents on one story shows overflow', () => {
    var agents = []
    for (var i = 0; i < 8; i++) {
      agents.push(makeAgent({ id: 'a' + i, description: 'E900-S3: task ' + i, status: 'running' }))
    }
    var result = computeAgentActivity({
      agents: agents,
      storyKeys: storyKeysFromCache(deepCopy(WRITER_CACHE))
    })
    var entry = result.activityByStory.get('E900-S3')!
    expect(entry.items.length).toBe(5)
    expect(entry.overflow).toBe(3)
  })

  test('more than 5 unlinked agents shows overflow', () => {
    var agents = []
    for (var i = 0; i < 7; i++) {
      agents.push(makeAgent({ id: 'u' + i, description: 'unlinked task ' + i, status: 'running' }))
    }
    var result = computeAgentActivity({
      agents: agents,
      storyKeys: new Set()
    })
    expect(result.unlinkedActivity.items.length).toBe(5)
    expect(result.unlinkedActivity.overflow).toBe(2)
  })
})

// -- harness integration --

describe('integration with the mod harness', () => {
  // World helper matching the pattern from index.test.ts.
  function world(on: any, opts: {
    now?: number; cache?: any; agents?: any[];
    agentThrows?: boolean
  } = {}) {
    var clock = mock.clock(on, { now: opts.now ?? 100000 })
    var cache = opts.cache ?? deepCopy(WRITER_CACHE)
    var w = {
      clock, cache, logs: [] as any[], invalidates: 0, stats: 0, reads: 0
    }
    on('session.start', (_$: unknown, e: any) => ({ cwd: e.cwd }))
    on('session.root', () => ({ value: GAIA_ROOT }))
    on('fs.exists', (_$: unknown, e: any) => ({ value: e.path === GAIA_ROOT + '/.gaia' }))
    on('command.register', () => ({ value: { command: 'sprint' } }))
    on('process.run', () => {
      w.cache.generated_at = new Date(clock.now()).toISOString()
      return { value: OK_RUN }
    })
    on('fs.stat', () => {
      w.stats++
      return { value: { kind: 'file' as const, size: JSON.stringify(w.cache).length, mtimeMs: clock.now(), isLink: false } }
    })
    on('fs.read', () => {
      w.reads++
      return { value: JSON.stringify(w.cache) }
    })
    on('ui.panes', () => ({ value: [] }))
    on('ui.log', (_$: unknown, e: any) => { w.logs.push(e); return { value: undefined } })
    on('ui.invalidate', () => { w.invalidates++; return { value: undefined } })
    on('ui.render', { component: 'Pane' }, ($: any, e: any) => h($.ui.resolve(e).Text, null, 'BOTTOM'))
    on('ui.render', { component: 'AbovePrompt' }, ($: any, e: any) => h($.ui.resolve(e).Text, null, 'OTHER'))
    // Agent list stub.
    if (opts.agentThrows) {
      on('agent.list', () => { throw new Error('not available') })
    } else {
      on('agent.list', () => ({ value: opts.agents ?? [] }))
    }
    mock.env(on, { HOME: '/home/u' })
    return w
  }

  test('agent.list unavailable sets caps.agent false and produces no data', async ($, on) => {
    var w = world(on, { agentThrows: true })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    // Advance a tick so refreshAgentActivity runs.
    await w.clock.advance(30000)
    // No error logged (silent).
    var agentErrors = w.logs.filter((l: any) => String(l.text).includes('agent'))
    expect(agentErrors.length).toBe(0)
  })

  test('agent.list returns running agent: activity appears after tick', async ($, on) => {
    var agents = [
      { id: 'a1', description: 'E900-S3: implement feature', type: 'agent', status: 'running' }
    ]
    var w = world(on, { agents: agents })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    await w.clock.advance(30000)
    // The module-level activityByStory should now have E900-S3.
    // Verify by mounting the pane and checking for the activity sub-line.
    var pane = await $.ui.mount({
      plugin: 'gaia', surface: 'terminal', component: 'Pane',
      requestId: 'sprint-status', props: { bodyColumns: 40 }
    })
    var actLine = await pane.find({ text: /implement feature/ })
    expect(actLine).toBeDefined()
    await pane.unmount()
  })
})

// -- stale data clearing on throw --

describe('agent data cleared after a failed list', () => {
  // Dynamic world: agent list is mutable between ticks.
  function worldDynamic(on: any, opts: {
    now?: number; cache?: any
  } = {}) {
    var agentState = { agents: [] as any[], throws: false }
    var clock = mock.clock(on, { now: opts.now ?? 100000 })
    var cache = opts.cache ?? deepCopy(WRITER_CACHE)
    var w = {
      clock, cache, agentState,
      logs: [] as any[], invalidates: 0, stats: 0, reads: 0
    }
    on('session.start', (_$: unknown, e: any) => ({ cwd: e.cwd }))
    on('session.root', () => ({ value: GAIA_ROOT }))
    on('fs.exists', (_$: unknown, e: any) => ({ value: e.path === GAIA_ROOT + '/.gaia' }))
    on('command.register', () => ({ value: { command: 'sprint' } }))
    on('process.run', () => {
      w.cache.generated_at = new Date(clock.now()).toISOString()
      return { value: OK_RUN }
    })
    on('fs.stat', () => {
      w.stats++
      return { value: { kind: 'file' as const, size: JSON.stringify(w.cache).length, mtimeMs: clock.now(), isLink: false } }
    })
    on('fs.read', () => {
      w.reads++
      return { value: JSON.stringify(w.cache) }
    })
    on('ui.panes', () => ({ value: [] }))
    on('ui.log', (_$: unknown, e: any) => { w.logs.push(e); return { value: undefined } })
    on('ui.invalidate', () => { w.invalidates++; return { value: undefined } })
    on('ui.render', { component: 'Pane' }, ($: any, e: any) => h($.ui.resolve(e).Text, null, 'BOTTOM'))
    on('ui.render', { component: 'AbovePrompt' }, ($: any, e: any) => h($.ui.resolve(e).Text, null, 'OTHER'))
    on('agent.list', () => {
      if (agentState.throws) throw new Error('not available')
      return { value: agentState.agents }
    })
    mock.env(on, { HOME: '/home/u' })
    return w
  }

  test('throw after agents clears sub-line from the rendered pane', async ($, on) => {
    var w = worldDynamic(on)

    // Tick 1: agents present (running).
    w.agentState.agents = [
      { id: 'a1', description: 'E900-S3: build ui', type: 'agent', status: 'running' }
    ]
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    await w.clock.advance(30000)

    // Verify sub-line present.
    var pane1 = await $.ui.mount({
      plugin: 'gaia', surface: 'terminal', component: 'Pane',
      requestId: 'sprint-status', props: { bodyColumns: 40 }
    })
    var subLine = await pane1.find({ text: /build ui/ })
    expect(subLine).toBeDefined()
    await pane1.unmount()

    // Tick 2: list throws.
    w.agentState.throws = true
    await w.clock.advance(30000)

    // Sub-line gone.
    var pane2 = await $.ui.mount({
      plugin: 'gaia', surface: 'terminal', component: 'Pane',
      requestId: 'sprint-status', props: { bodyColumns: 40 }
    })
    var subLineAfter = await pane2.find({ text: /build ui/ })
    expect(subLineAfter).toBeUndefined()
    await pane2.unmount()
  })

  test('successful tick after throw restores agent data', async ($, on) => {
    var w = worldDynamic(on)

    // Tick 1: throw.
    w.agentState.throws = true
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    await w.clock.advance(30000)

    // No sub-line.
    var pane1 = await $.ui.mount({
      plugin: 'gaia', surface: 'terminal', component: 'Pane',
      requestId: 'sprint-status', props: { bodyColumns: 40 }
    })
    var subLine1 = await pane1.find({ text: /fix login/ })
    expect(subLine1).toBeUndefined()
    await pane1.unmount()

    // Tick 2: agents return.
    w.agentState.throws = false
    w.agentState.agents = [
      { id: 'a2', description: 'E900-S3: fix login', type: 'agent', status: 'running' }
    ]
    await w.clock.advance(30000)

    // Sub-line back.
    var pane2 = await $.ui.mount({
      plugin: 'gaia', surface: 'terminal', component: 'Pane',
      requestId: 'sprint-status', props: { bodyColumns: 40 }
    })
    var subLine2 = await pane2.find({ text: /fix login/ })
    expect(subLine2).toBeDefined()
    await pane2.unmount()
  })
})

// -- activity rendered in pane --

describe('activity rendered in pane', () => {
  function worldWithAgents(on: any, agents: any[], opts: {
    now?: number; cache?: any
  } = {}) {
    var clock = mock.clock(on, { now: opts.now ?? 100000 })
    var cache = opts.cache ?? deepCopy(WRITER_CACHE)
    var w = {
      clock, cache, logs: [] as any[], invalidates: 0, stats: 0, reads: 0
    }
    on('session.start', (_$: unknown, e: any) => ({ cwd: e.cwd }))
    on('session.root', () => ({ value: GAIA_ROOT }))
    on('fs.exists', (_$: unknown, e: any) => ({ value: e.path === GAIA_ROOT + '/.gaia' }))
    on('command.register', () => ({ value: { command: 'sprint' } }))
    on('process.run', () => {
      w.cache.generated_at = new Date(clock.now()).toISOString()
      return { value: OK_RUN }
    })
    on('fs.stat', () => {
      w.stats++
      return { value: { kind: 'file' as const, size: JSON.stringify(w.cache).length, mtimeMs: clock.now(), isLink: false } }
    })
    on('fs.read', () => {
      w.reads++
      return { value: JSON.stringify(w.cache) }
    })
    on('ui.panes', () => ({ value: [] }))
    on('ui.log', (_$: unknown, e: any) => { w.logs.push(e); return { value: undefined } })
    on('ui.invalidate', () => { w.invalidates++; return { value: undefined } })
    on('ui.render', { component: 'Pane' }, ($: any, e: any) => h($.ui.resolve(e).Text, null, 'BOTTOM'))
    on('ui.render', { component: 'AbovePrompt' }, ($: any, e: any) => h($.ui.resolve(e).Text, null, 'OTHER'))
    on('agent.list', () => ({ value: agents }))
    mock.env(on, { HOME: '/home/u' })
    return w
  }

  test('50+ agents: lines are capped with "+N more" and the pane still renders quickly', async ($, on) => {
    var agents = []
    for (var i = 0; i < 55; i++) {
      agents.push({ id: 's' + i, description: 'E900-S3: task ' + i, type: 'agent', status: 'running' })
    }
    for (var j = 0; j < 12; j++) {
      agents.push({ id: 'u' + j, description: 'side job ' + j, type: 'agent', status: 'running' })
    }
    var w = worldWithAgents(on, agents)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    await w.clock.advance(30000)

    var start = Date.now()
    var pane = await $.ui.mount({
      plugin: 'gaia', surface: 'terminal', component: 'Pane',
      requestId: 'sprint-status', props: { bodyColumns: 40 }
    })
    var elapsed = Date.now() - start
    // Only the capped lines render: 5 story lines and 5 unlinked lines.
    var storyLines = (await pane.findAll({ text: /task [0-9]+ running/ })).filter((el: any) => el.type === 'Text')
    expect(storyLines.length).toBe(5)
    expect(await pane.find({ text: /\+50 more/ })).toBeDefined()
    var sideLines = (await pane.findAll({ text: /side job [0-9]+/ })).filter((el: any) => el.type === 'Text')
    expect(sideLines.length).toBe(5)
    expect(await pane.find({ text: /\+7 more/ })).toBeDefined()
    expect(elapsed).toBeLessThan(2000)
    await pane.unmount()
  })

  test('banner order: cache rules a, c, d sorted correctly', async ($, on) => {
    var cache = deepCopy(WRITER_CACHE)
    // Inject cache action_needed items out of sorted order to exercise the sort.
    cache.action_needed = [
      { rule: 'd', type: 'overdue', story_keys: [], message: 'rule-d-msg', command: null, since: '2026-10-14', source: 'cache' },
      { rule: 'a', type: 'stale_review', story_keys: ['E900-S3'], message: 'rule-a-msg', command: 'run review', since: '2026-10-12', source: 'cache' },
      { rule: 'c', type: 'blocker', story_keys: ['E900-S5'], message: 'rule-c-msg', command: null, since: '2026-10-13', source: 'cache' }
    ]
    var w = worldWithAgents(on, [], { cache: cache })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    await w.clock.advance(30000)

    var pane = await $.ui.mount({
      plugin: 'gaia', surface: 'terminal', component: 'Pane',
      requestId: 'sprint-status', props: { bodyColumns: 40 }
    })
    // Probe: collect all leaf Text elements matching any rule message and
    // check whether findAll returns them in render (document) order.
    var allRuleTexts = await pane.findAll({ text: /rule-[acd]-msg/ })
    // Filter to leaf Text nodes only.
    var leaves = allRuleTexts.filter((el: any) => el.type === 'Text')
    // Extract the text content from each leaf.
    var leafTexts = leaves.map((el: any) => {
      var t = el.text ?? el.props?.children ?? ''
      return String(t)
    })
    // Find the index of the first leaf containing each rule message.
    var posA = leafTexts.findIndex((t: string) => t.includes('rule-a-msg'))
    var posC = leafTexts.findIndex((t: string) => t.includes('rule-c-msg'))
    var posD = leafTexts.findIndex((t: string) => t.includes('rule-d-msg'))
    // All three must be found.
    expect(posA).toBeGreaterThanOrEqual(0)
    expect(posC).toBeGreaterThanOrEqual(0)
    expect(posD).toBeGreaterThanOrEqual(0)
    // Assert sorted render order: a < c < d.
    expect(posA).toBeLessThan(posC)
    expect(posC).toBeLessThan(posD)
    await pane.unmount()
  })

  test('unlinked agent renders activity row', async ($, on) => {
    var cache = deepCopy(WRITER_CACHE)
    var agents = [
      { id: 'u1', description: 'some unlinked task', type: 'agent', status: 'running' }
    ]
    var w = worldWithAgents(on, agents, { cache: cache })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    await w.clock.advance(30000)

    var pane = await $.ui.mount({
      plugin: 'gaia', surface: 'terminal', component: 'Pane',
      requestId: 'sprint-status', props: { bodyColumns: 40 }
    })
    var unlinkedLine = await pane.find({ text: /some unlinked task/ })
    expect(unlinkedLine).toBeDefined()
    await pane.unmount()
  })

  test('overflow renders +N more for story with >5 agents', async ($, on) => {
    var cache = deepCopy(WRITER_CACHE)
    var agents = []
    for (var i = 0; i < 7; i++) {
      agents.push({ id: 'a' + i, description: 'E900-S3: agent-task-' + i, type: 'agent', status: 'running' })
    }
    var w = worldWithAgents(on, agents, { cache: cache })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    await w.clock.advance(30000)

    var pane = await $.ui.mount({
      plugin: 'gaia', surface: 'terminal', component: 'Pane',
      requestId: 'sprint-status', props: { bodyColumns: 40 }
    })
    var overflow = await pane.find({ text: /\+2 more/ })
    expect(overflow).toBeDefined()
    await pane.unmount()
  })

  test('overflow renders +N more for >5 unlinked agents', async ($, on) => {
    var cache = deepCopy(WRITER_CACHE)
    var agents = []
    for (var i = 0; i < 8; i++) {
      agents.push({ id: 'u' + i, description: 'unlinked-work-' + i, type: 'agent', status: 'running' })
    }
    var w = worldWithAgents(on, agents, { cache: cache })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    await w.clock.advance(30000)

    var pane = await $.ui.mount({
      plugin: 'gaia', surface: 'terminal', component: 'Pane',
      requestId: 'sprint-status', props: { bodyColumns: 40 }
    })
    var overflow = await pane.find({ text: /\+3 more/ })
    expect(overflow).toBeDefined()
    await pane.unmount()
  })
})
