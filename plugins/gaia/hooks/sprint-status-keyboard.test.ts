import { test, expect, mock, describe } from 'claude-code/testing'
import { WRITER_CACHE, GAIA_ROOT, OK_RUN, deepCopy } from './sprint-status-fixture.js'

function world(on: any) {
  const cache = { content: JSON.stringify(WRITER_CACHE), mtimeMs: 100000 }
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
    // E900-S3 (in-progress), E900-S4 (review), E900-S8 (blocked) in NOW
    expect(await ui.find({ text: /E900-S3/ })).toBeDefined()
    expect(await ui.find({ text: /E900-S4/ })).toBeDefined()
    expect(await ui.find({ text: /E900-S8/ })).toBeDefined()
    await ui.unmount()
  })

  test('NOW block shows task and gate counts for each story', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: GAIA_ROOT, surface: 'terminal', isInteractive: true })
    await w.clock.settle()
    const ui = await mountPane($)
    expect(await ui.find({ text: /tasks 1\/3/ })).toBeDefined()
    expect(await ui.find({ text: /gates 2\/6/ })).toBeDefined()
    await ui.unmount()
  })
})

describe('empty NOW block keyboard safety', () => {
  test('no crash when NOW block has no active stories', async ($, on) => {
    const cache = deepCopy(WRITER_CACHE)
    cache.stories = cache.stories.map((s: any) => ({ ...s, status: 'backlog' }))
    const cacheObj = { content: JSON.stringify(cache), mtimeMs: 100000 }
    const clock = mock.clock(on, { now: 100000 })
    on('session.start', (_$: unknown, e: any) => ({ cwd: e.cwd }))
    on('session.root', () => ({ value: GAIA_ROOT }))
    on('fs.exists', (_$: unknown, e: any) => ({ value: e.path === GAIA_ROOT + '/.gaia' }))
    on('command.register', () => ({ value: { command: 'sprint' } }))
    on('process.run', () => ({ value: OK_RUN }))
    on('fs.stat', () => ({ value: { kind: 'file' as const, size: cacheObj.content.length, mtimeMs: cacheObj.mtimeMs, isLink: false } }))
    on('fs.read', () => ({ value: cacheObj.content }))
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
    await ui.unmount()
  })
})
