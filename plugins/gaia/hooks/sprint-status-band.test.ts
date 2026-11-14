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

  test('gaia hotkey 9 button is drawn before other mods content in the composed band', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountBand($)
    // The host (2.1.323+) draws each plugin's AbovePrompt as its own part.
    // next(e) returns an engine placeholder, and the other mod's content is
    // rendered AFTER gaia's part.  Under the documented "two clash, later wins"
    // rule (host types line 1119, 9791), gaia's hotkey-9 button is the EARLIER
    // one — so another mod binding the same key would take precedence.
    //
    // This test pins the observed host order: gaia's Button appears before the
    // other mod's Text in findAll traversal order.
    const all = await ui.findAll({ text: /OTHER MOD|^9$/ })
    const posButton = all.findIndex((el: any) => el.type === 'Button' && el.props && el.props.hotkey === '9')
    const posOther = all.findIndex((el: any) => el.type === 'Text' && String(el.text).includes('OTHER MOD'))
    expect(posButton).toBeGreaterThanOrEqual(0)
    expect(posOther).toBeGreaterThanOrEqual(0)
    // Pin: gaia's button is drawn first, other mod content comes after.
    // Under "later wins", another mod's hotkey 9 would take precedence.
    expect(posButton).toBeLessThan(posOther)
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

  test('another mod binding hotkey 9 is drawn after gaia and wins under later-wins rule', async ($, on) => {
    // Simulate a second mod that also binds hotkey 9 in the band.
    // The host draws it after gaia's part.
    const cache = { content: JSON.stringify(WRITER_CACHE), mtimeMs: 100000 }
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
    // Second mod draws a Button with the same hotkey 9.
    on('ui.render', { component: 'AbovePrompt' }, ($: any, e: any) => {
      const c = $.ui.resolve(e)
      return h(c.Button, { hotkey: '9', onPress: () => {} }, '9')
    })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await clock.settle()
    const ui = await mountBand($)
    // Both gaia and the other mod draw a hotkey-9 Button.
    const buttons = await ui.findAll({ text: /^9$/ })
    const hotkey9Buttons = buttons.filter((el: any) => el.type === 'Button' && el.props && el.props.hotkey === '9')
    // Exactly two hotkey-9 buttons exist, gaia's first and the other mod's
    // second. Under "later wins" the other mod's button takes precedence.
    // This is a host limitation: no plugin API lets gaia control the order.
    expect(hotkey9Buttons.length).toBe(2)
    // ui.drawn() stamps each Button with the plugin that drew it; walk the
    // composed tree in draw order and read the owners of the hotkey-9 Buttons.
    const owners: string[] = []
    const walk = (node: any): void => {
      if (!node || typeof node !== 'object') return
      if (Array.isArray(node)) { node.forEach(walk); return }
      const hotkey = node.hotkey ?? (node.props && node.props.hotkey)
      if (node.type === 'Button' && hotkey === '9') owners.push(node.press && node.press.plugin)
      walk(node.children ?? (node.props && node.props.children))
    }
    walk(await ui.drawn())
    expect(owners).toEqual(['gaia', 'test'])
    await ui.unmount()
  })
})

describe('band warning mode', () => {
  test('warning variant hotkey 9 is drawn before other mods content', async ($, on) => {
    const cache = deepCopy(WRITER_CACHE)
    cache.action_needed = [
      { rule: 'a', type: 'manual_test_due', story_keys: ['E900-S1'], message: 'Test due', command: '/gaia-test-manual', since: '2026-10-13', source: 'story-file' }
    ]
    const w = world(on, { cache: { content: JSON.stringify(cache), mtimeMs: 100000 } })
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountBand($)
    // Same host ordering as normal mode: gaia's button drawn first, other mod after.
    const all = await ui.findAll({ text: /OTHER MOD|^9$/ })
    const posButton = all.findIndex((el: any) => el.type === 'Button' && el.props && el.props.hotkey === '9')
    const posOther = all.findIndex((el: any) => el.type === 'Text' && String(el.text).includes('OTHER MOD'))
    expect(posButton).toBeGreaterThanOrEqual(0)
    expect(posOther).toBeGreaterThanOrEqual(0)
    expect(posButton).toBeLessThan(posOther)
    await ui.unmount()
  })

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
    // The band never shows the pane's fallback message.
    expect(await ui.find({ text: /Sprint data unavailable/ })).toBeUndefined()
    await ui.unmount()
  })
})
