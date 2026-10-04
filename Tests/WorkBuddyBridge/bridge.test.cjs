const test = require('node:test');
const assert = require('node:assert/strict');
const { createDispatcher } = require('../../integrations/workbuddy/server/bridge.cjs');
const id = '12345678-1234-4234-9234-123456789abc';
const command = { version: 1, action: 'send', sessionID: id, requestID: '32345678-1234-4234-9234-123456789abc', prompt: '你好' };
test('routes text to the pinned session, deduplicates, distinguishes queued', async () => {
  let calls = 0;
  const dispatch = createDispatcher(async (channel, session, blocks, options) => {
    calls++;
    assert.equal(channel, 'wb:conversations:sendPrompt');
    assert.equal(session, id);
    assert.deepEqual(blocks, [{ type: 'text', text: '你好' }]);
    assert.equal(options.clientRequestId, command.requestID);
    return { disposition: 'queued', item: { id: 'queue-1' } };
  }, () => true);
  const [a, b] = await Promise.all([dispatch(command), dispatch(command)]);
  assert.equal(calls, 1);
  assert.equal(a.status, 'queued');
  assert.deepEqual(a, b);
  assert.equal((await dispatch({ ...command, prompt: 'different' })).status, 'invalid');
});
test('rejects unpinned sessions and malformed requests without invoking host', async () => {
  const dispatch = createDispatcher(() => { throw Error('must not call'); }, () => false);
  assert.equal((await dispatch(command)).status, 'notPinned');
  assert.equal((await dispatch({ ...command, version: 2 })).status, 'invalid');
  assert.equal((await dispatch({ ...command, action: 'delete' })).status, 'invalid');
});
test('propagates returned errors and uncertain delivery, never auto retries', async () => {
  let calls = 0;
  const dispatch = createDispatcher(async () => { calls++; throw Error('timeout'); }, () => true);
  assert.equal((await dispatch(command)).status, 'unknown');
  await dispatch(command);
  assert.equal(calls, 1);
  const denied = createDispatcher(async () => ({ errorCode: 'DENIED', message: 'no' }), () => true);
  assert.equal((await denied(command)).status, 'failed');
  const serialized = createDispatcher(async () => ({ __wbError: true, message: 'denied' }), () => true);
  assert.equal((await serialized(command)).status, 'failed');
});
test('probe calls get, returns only capability data', async () => {
  const dispatch = createDispatcher(async (channel, session) => {
    assert.equal(channel, 'wb:conversations:get'); assert.equal(session, id);
    return { info: { id, transport: 'local' }, private: 'not exposed' };
  }, () => true);
  const result = await dispatch({ version: 1, action: 'probe', sessionID: id, requestID: command.requestID });
  assert.equal(result.status, 'ready');
  assert.equal(JSON.stringify(result).includes('not exposed'), false);
});
test('durable receipt survives reload; failure saving ledger never sends', async () => {
  const store = new Map();
  let calls = 0, writes = 0;
  const dispatch = createDispatcher(async () => { calls++; return {}; }, () => true, store, () => { writes++; });
  assert.equal((await dispatch(command)).status, 'submitted');
  assert.equal(writes, 2);
  const restored = createDispatcher(async () => { calls++; }, () => true, new Map(JSON.parse(JSON.stringify([...store]))));
  assert.equal((await restored(command)).status, 'submitted');
  assert.equal(calls, 1);
  const broken = createDispatcher(async () => { calls++; }, () => true, new Map(), () => { throw Error('disk'); });
  assert.equal((await broken(command)).status, 'failed');
  assert.equal(calls, 1);
});
test('preserves normal Unicode text; rejects overly long and empty messages', async () => {
  let received;
  const dispatch = createDispatcher(async (_channel, _id, blocks) => { received = blocks[0].text; }, () => true);
  assert.equal((await dispatch({ ...command, prompt: '  中文\n第二行  ' })).status, 'submitted');
  assert.equal(received, '中文\n第二行');
  assert.equal((await dispatch({ ...command, prompt: ' '.repeat(3) })).status, 'invalid');
  assert.equal((await dispatch({ ...command, prompt: 'x'.repeat(12001) })).status, 'invalid');
});
