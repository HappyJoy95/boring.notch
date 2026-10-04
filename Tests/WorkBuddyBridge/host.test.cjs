'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { fork } = require('node:child_process');
const { once } = require('node:events');
const crypto = require('node:crypto');

test('standalone host authenticates HTTP, invokes WorkBuddy IPC and restores receipts', async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'notch-bridge-host-'));
  const root = path.join(home, 'extension');
  fs.cpSync(path.resolve(__dirname, '../../Integrations/workbuddy'), root, { recursive: true });
  const socket = net.createServer();
  socket.listen(0, '127.0.0.1');
  await once(socket, 'listening');
  const port = socket.address().port;
  await new Promise(resolve => socket.close(resolve));
  const token = crypto.randomBytes(32).toString('hex');
  fs.writeFileSync(path.join(root, 'bridge-config.json'), JSON.stringify({ port, token }), { mode: 0o600 });
  const storage = path.join(home, '.workbuddy/storage');
  fs.mkdirSync(path.join(storage, 'skeleton'), { recursive: true });
  fs.mkdirSync(path.join(storage, 'user-test/global'), { recursive: true });
  fs.writeFileSync(path.join(storage, 'skeleton/account-snapshot.json'), JSON.stringify({ primary: { uid: 'test' } }));
  const id = crypto.randomUUID();
  fs.writeFileSync(path.join(storage, 'user-test/global/conversations.json'), JSON.stringify({ pinned: [{ id }] }));
  let child, calls = 0;
  async function start() {
    child = fork(path.join(root, 'server/index.cjs'), [], {
      env: { ...process.env, HOME: home, WB_EXTENSION_ID: 'boring-notch-bridge' }, silent: true,
    });
    child.on('message', message => {
      if (message.type !== 'invoke:request') return;
      assert.equal(message.args[0], null);
      assert.equal(message.args[1], id);
      if (message.channel === 'wb:conversations:sendPrompt') {
        calls++;
        assert.deepEqual(message.args[2], [{ type: 'text', text: '中文测试\n第二行' }]);
        assert.equal(message.args[3]._expectQueueReceipt, true);
      }
      child.send({ type: 'invoke:response', requestId: message.requestId,
        result: message.channel === 'wb:conversations:get' ? { info: { id, transport: 'local' } } : { disposition: 'queued' } });
    });
    await Promise.race([
      new Promise(resolve => child.on('message', message => { if (message.type === 'wb-extension-ready') resolve(); })),
      new Promise((_, reject) => child.once('exit', code => reject(Error('host exited: ' + code)))),
    ]);
  }
  async function stop() { const exited = once(child, 'exit'); child.disconnect(); await exited; }
  async function request(route, options = {}) {
    const response = await fetch(`http://127.0.0.1:${port}${route}`, {
      ...options, headers: { Authorization: 'Bearer ' + token, ...options.headers },
    });
    return { code: response.status, body: await response.json() };
  }
  try {
    await start();
    assert.equal((await request('/v1/health', { headers: { Authorization: 'invalid' } })).code, 401);
    assert.equal((await request('/v1/health', { headers: { Origin: 'https://example.com' } })).code, 401);
    assert.equal((await request('/v1/health')).body.extension_id, 'boring-notch-bridge');
    assert.equal((await request('/v1/probe?session_id=' + id)).body.status, 'ready');
    const command = { schema_version: 1, command_id: crypto.randomUUID(), session_id: id, prompt: '中文测试\n第二行' };
    const send = value => request('/v1/instructions/send', { method: 'POST', body: JSON.stringify(value) });
    assert.equal((await send({ ...command, session_id: crypto.randomUUID() })).body.status, 'notPinned');
    assert.equal((await send(command)).body.status, 'queued');
    assert.equal((await send(command)).body.accepted, true);
    assert.equal(calls, 1);
    await stop();
    await start();
    assert.equal((await send(command)).body.status, 'queued');
    assert.equal(calls, 1);
    await stop();
  } finally {
    if (child?.exitCode === null) child.kill();
    fs.rmSync(home, { recursive: true, force: true });
  }
});
