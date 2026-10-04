import test from 'node:test'
import assert from 'node:assert/strict'
import { createControls } from '../../Integrations/DSHDesktop/lib/control.js'

function fixture() {
  const calls = []
  const pins = new Set(['session-test'])
  const controller = {
    list: async () => ({ items: [{ sessionId: 'session-test', running: true }] }),
    prompt: async request => { calls.push(['prompt', request]); return { accepted: true } },
    cancel: async request => { calls.push(['cancel', request]); return { accepted: true } },
  }
  return { calls, pins, controller, controls: createControls(controller, () => pins) }
}
const body = { session_id: 'session-test', request_id: 'req-1', prompt: '测试文字' }
test('sends exact text to the addressed pinned session using the public queue API', async () => {
  const f = fixture()
  assert.equal((await f.controls('send', body)).result, 'queued')
  assert.deepEqual(f.calls[0], ['prompt', { sessionId: 'session-test', requestId: 'req-1', mode: 'queue', content: [{ type: 'text', text: '测试文字' }] }])
})
test('duplicate request executes only once, including concurrent submissions', async () => {
  const f = fixture()
  await Promise.all([f.controls('send', body), f.controls('send', body)])
  assert.equal(f.calls.length, 1)
  assert.equal((await f.controls('send', { ...body, prompt: 'different' })).result, 'invalid')
})
test('unpinning rejects later sends without calling the controller', async () => {
  const f = fixture(); f.pins.clear()
  assert.equal((await f.controls('send', body)).result, 'notPinned')
  assert.equal(f.calls.length, 0)
})
test('stop cancels only the specified pinned session', async () => {
  const f = fixture()
  assert.equal((await f.controls('stop', { session_id: 'session-test', request_id: 'stop-1' })).result, 'submitted')
  assert.deepEqual(f.calls, [['cancel', { sessionId: 'session-test' }]])
})
test('invalid text, subagents and unavailable APIs cannot mutate sessions', async () => {
  const f = fixture()
  assert.equal((await f.controls('send', { ...body, prompt: ' ' })).result, 'invalid')
  f.controller.list = async () => ({ items: [{ sessionId: 'session-test', origin: 'subagent' }] })
  assert.equal((await f.controls('send', body)).result, 'notPinned')
  assert.equal(f.calls.length, 0)
  delete f.controller.prompt
  assert.equal((await f.controls('send', body)).result, 'unavailable')
})
test('an unconfirmed controller response is unknown and is never retried', async () => {
  const f = fixture(); f.controller.prompt = async () => { f.calls.push('attempt'); throw new Error('lost acknowledgement') }
  assert.equal((await f.controls('send', body)).result, 'unknown')
  assert.equal((await f.controls('send', body)).result, 'unknown')
  assert.equal(f.calls.length, 1)
})
