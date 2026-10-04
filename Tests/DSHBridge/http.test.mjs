import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { apply } from '../../Integrations/DSHDesktop/lib/index.js'

test('real HTTP bridge authenticates, exposes capability and controls only pinned sessions', async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-bridge-test-'))
  await fs.mkdir(path.join(directory, 'Library', 'Application Support'), { recursive: true })
  const original = os.homedir
  let dispose
  const calls = []
  let pushPins
  const ctx = {
    sessionController: {
      list: async () => ({ items: [{ sessionId: 'session-test', title: 'Test', running: true }] }),
      page: async () => ({ events: [] }),
      prompt: async request => { calls.push(['prompt', request]); return { accepted: true } },
      cancel: request => { calls.push(['cancel', request]); return { accepted: true } },
    },
    workspaceController: {
      async *follow(signal) {
        yield { type: 'baseline', value: { pinnedSessionIds: ['session-test'] } }
        const frame = await new Promise(resolve => {
          pushPins = ids => resolve({ type: 'pinned', pinnedSessionIds: ids })
          signal.addEventListener('abort', () => resolve(null), { once: true })
        })
        if (frame) yield frame
        await new Promise(resolve => signal.addEventListener('abort', resolve, { once: true }))
      },
    },
    effect(factory) { dispose = factory() },
  }
  try {
    os.homedir = () => directory
    apply(ctx)
    let config
    for (let i = 0; i < 100; i++) {
      try { config = JSON.parse(await fs.readFile(path.join(directory, 'Library/Application Support/Boring Notch/DSH/bridge-config.json'))); break }
      catch { await new Promise(resolve => setTimeout(resolve, 10)) }
    }
    assert.ok(config)
    const base = `http://127.0.0.1:${config.port}`
    const headers = { Authorization: `Bearer ${config.token}`, 'Content-Type': 'application/json' }
    assert.equal((await fetch(base + '/v1/health')).status, 401)
    assert.equal((await fetch(base + '/v1/health', { headers: { ...headers, Origin: 'https://example.com' } })).status, 401)
    const health = await (await fetch(base + '/v1/health', { headers })).json()
    assert.equal(health.version, '0.3.0')
    assert.deepEqual(health.capabilities, { send: true, stop: true })
    const send = { session_id: 'session-test', request_id: 'request-1', prompt: 'fixture only' }
    const post = async (route, body) => (await fetch(base + route, { method: 'POST', headers, body: JSON.stringify(body) })).json()
    assert.equal((await post('/v1/send', send)).result, 'queued')
    assert.equal((await post('/v1/send', send)).result, 'queued')
    assert.equal(calls.length, 1)
    assert.equal((await post('/v1/stop', { session_id: 'session-test', request_id: 'stop-1' })).result, 'submitted')
    assert.equal(calls[1][0], 'cancel')
    pushPins([])
    await new Promise(resolve => setTimeout(resolve, 10))
    assert.equal((await post('/v1/send', { ...send, request_id: 'request-2' })).result, 'notPinned')
    assert.equal(calls.length, 2)
    assert.deepEqual(await (await fetch(base + '/v1/tasks', { headers })).json(), [])
    assert.equal((await fetch(base + '/v1/send', { method: 'POST', headers, body: '{broken' })).status, 400)
    assert.equal((await fetch(base + '/v1/send', { method: 'POST', headers, body: 'x'.repeat(17000) })).status, 413)
  } finally {
    dispose?.()
    os.homedir = original
    await fs.rm(directory, { recursive: true, force: true })
  }
})
