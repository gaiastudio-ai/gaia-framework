import { test, expect, mock, describe } from 'claude-code/testing'
import { WRITER_CACHE, GAIA_ROOT, OK_RUN, deepCopy } from './sprint-status-fixture.js'

function world(on: any, opts: any = {}) {
  const cache = opts.cache ?? { content: JSON.stringify(WRITER_CACHE), mtimeMs: 100000 }
  const clock = mock.clock(on, { now: 100000 })
  const w: any = { clock, cache, runs: [] as any[] }
  on('session.start', (_$: unknown, e: any) => ({ cwd: e.cwd }))
  on('session.root', () => ({ value: GAIA_ROOT }))
  on('fs.exists', (_$: unknown, e: any) => ({ value: e.path === GAIA_ROOT + '/.gaia' }))
  on('command.register', () => ({ value: { command: 'sprint' } }))
  on('process.run', () => { w.runs.push(1); return { value: OK_RUN } })
  on('fs.stat', () => {
    if (cache.content === null) throw new Error('ENOENT')
    return { value: { kind: 'file' as const, size: cache.content.length, mtimeMs: cache.mtimeMs, isLink: false } }
  })
  on('fs.read', () => {
    if (cache.content === null) throw new Error('ENOENT')
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
  on('ui.render', { component: 'AbovePrompt' }, ($: any, e: any) => h($.ui.resolve(e).Text, null, 'OTHER MOD'))
  return w
}

async function mountBand($: any) {
  return $.ui.mount({ plugin: 'gaia', surface: 'terminal', component: 'AbovePrompt', props: {} })
}

describe('band normal mode', () => {
  test('shows sprint id without double prefix', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountBand($)
    // Must show "sprint-84", never "sprint-sprint-84"
    expect(await ui.find({ text: /sprint-84/ })).toBeDefined()
    expect(await ui.find({ text: /sprint-sprint/ })).toBeUndefined()
    await ui.unmount()
  })

  test('shows toggle button and summary with middot separators', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountBand($)
    expect(await ui.find({ text: /8\/40 pts/ })).toBeDefined()
    expect(await ui.find({ text: /2\/9 done/ })).toBeDefined()
    expect(await ui.find({ text: /1 blocked/ })).toBeDefined()
    await ui.unmount()
  })

  test('band preserves other mods content', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountBand($)
    expect(await ui.find({ text: 'OTHER MOD' })).toBeDefined()
    await ui.unmount()
  })
})

describe('band warning mode', () => {
  test('shows warning variant when action list is non-empty', async ($, on) => {
    const cache = deepCopy(WRITER_CACHE)
    cache.action_needed = [
      { rule: 'a', type: 'manual_test_due', story_keys: ['E900-S1'], message: 'Test due', command: '/gaia-test-manual', since: '2026-10-13', source: 'story-file' },
      { rule: 'c', type: 'action_item', story_keys: [], message: 'Open item', command: null, since: '2026-10-14', source: 'action-items' }
    ]
    const w = world(on, { cache: { content: JSON.stringify(cache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountBand($)
    expect(await ui.find({ text: /ACTION NEEDED/ })).toBeDefined()
    expect(await ui.find({ text: /2 items/ })).toBeDefined()
    expect(await ui.find({ text: /since 2026-10-13/ })).toBeDefined()
    expect(await ui.find({ text: /press 9/ })).toBeDefined()
    await ui.unmount()
  })
})

describe('band absent states', () => {
  test('no active sprint returns next(e) only', async ($, on) => {
    const cache = deepCopy(WRITER_CACHE)
    cache.sprint.status = 'closed'
    const w = world(on, { cache: { content: JSON.stringify(cache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountBand($)
    expect(await ui.find({ text: 'OTHER MOD' })).toBeDefined()
    expect(await ui.find({ text: /sprint-84/ })).toBeUndefined()
    expect(await ui.find({ text: /ACTION NEEDED/ })).toBeUndefined()
    await ui.unmount()
  })

  test('null sprint returns next(e) only', async ($, on) => {
    const cache = deepCopy(WRITER_CACHE)
    ;(cache as any).sprint = null
    const w = world(on, { cache: { content: JSON.stringify(cache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountBand($)
    expect(await ui.find({ text: 'OTHER MOD' })).toBeDefined()
    expect(await ui.find({ text: /sprint/ })).toBeUndefined()
    await ui.unmount()
  })

  test('null cache returns next(e) only', async ($, on) => {
    const w = world(on, { cache: { content: null, mtimeMs: 0 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountBand($)
    expect(await ui.find({ text: 'OTHER MOD' })).toBeDefined()
    expect(await ui.find({ text: /ACTION NEEDED/ })).toBeUndefined()
    await ui.unmount()
  })
})
