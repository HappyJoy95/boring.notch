'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { createDispatcher, validID } = require('./bridge.cjs');
const root = path.resolve(__dirname, '..');
const configPath = path.join(root, 'bridge-config.json');
const ledgerPath = path.join(root, 'receipts.json');
const configuration = JSON.parse(fs.readFileSync(configPath, 'utf8'));
if (!Number.isInteger(configuration.port) || configuration.port < 1024 || configuration.port > 65535
    || !/^[a-f0-9]{64}$/.test(configuration.token)) throw Error('Invalid bridge configuration');
const pending = new Map();
let seq = 0;
function invoke(channel, ...args) {
  return new Promise((resolve, reject) => {
    if (!process.send || !process.connected) return reject(Error('unavailable'));
    const requestId = 'boring-notch-' + ++seq;
    const timer = setTimeout(() => { pending.delete(requestId); reject(Error('timeout')); }, 20000);
    pending.set(requestId, { resolve, reject, timer });
    process.send({ type: 'invoke:request', requestId, channel, args: [null, ...args] }, error => {
      if (error) { clearTimeout(timer); pending.delete(requestId); reject(Error('unavailable')); }
    });
  });
}
process.on('message', message => {
  if (message?.type !== 'invoke:response') return;
  const entry = pending.get(message.requestId);
  if (!entry) return;
  clearTimeout(entry.timer); pending.delete(message.requestId);
  if (message.error !== undefined) entry.reject(Error('host rejected'));
  else entry.resolve(message.result);
});
function isPinned(id) {
  try {
    const home = path.join(os.homedir(), '.workbuddy');
    const storage = path.join(home, 'storage');
    const uid = JSON.parse(fs.readFileSync(path.join(storage, 'skeleton/account-snapshot.json'), 'utf8')).primary?.uid;
    if (typeof uid !== 'string' || !uid || uid.includes('/')) return false;
    for (const name of fs.readdirSync(storage)) {
      if (name !== 'user-' + uid && !name.startsWith('user-' + uid + '-')) continue;
      const file = path.join(storage, name, 'global/conversations.json');
      if (!fs.existsSync(file)) continue;
      if (JSON.parse(fs.readFileSync(file, 'utf8')).pinned?.some(item => item.id === id && validID(item.id))) return true;
    }
  } catch {}
  return false;
}
let ledger = new Map();
if (fs.existsSync(ledgerPath)) {
  // Fail closed if the ledger cannot be read: losing it could cause duplicate delivery.
  const entries = JSON.parse(fs.readFileSync(ledgerPath, 'utf8'));
  if (!Array.isArray(entries) || entries.length > 4096) throw Error('Invalid receipt ledger');
  ledger = new Map(entries);
}
function save(entries) {
  const temp = ledgerPath + '.tmp';
  fs.writeFileSync(temp, JSON.stringify([...entries]), { mode: 0o600 });
  fs.renameSync(temp, ledgerPath);
}
const dispatch = createDispatcher(invoke, isPinned, ledger, save);
const http = require('node:http');
const server = http.createServer(async (request, response) => {
  const json = (status, body) => {
    response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    response.end(JSON.stringify(body));
  };
  // Independent local protocol; no other application or extension is involved.
  if (request.headers.authorization !== 'Bearer ' + configuration.token || request.headers.origin) {
    json(401, { error_code: 'unauthorized' }); return;
  }
  if (request.method === 'GET' && request.url === '/v1/health') {
    json(200, { schema_version: 1, extension_id: 'boring-notch-bridge', version: '0.1.0' }); return;
  }
  const url = new URL(request.url, 'http://127.0.0.1');
  if (request.method === 'GET' && url.pathname === '/v1/probe') {
    const result = await dispatch({ version: 1, action: 'probe',
      sessionID: url.searchParams.get('session_id'), requestID: require('node:crypto').randomUUID() });
    json(200, { schema_version: 1, status: result.status }); return;
  }
  if (request.method !== 'POST' || request.url !== '/v1/instructions/send') {
    json(404, { error_code: 'not_found' }); return;
  }
  let buffer = Buffer.alloc(0), rejected = false;
  request.on('error', () => {});
  request.on('data', chunk => {
    buffer = Buffer.concat([buffer, chunk]);
    if (buffer.length > 65536) { rejected = true; request.destroy(); }
  });
  request.on('end', async () => {
    if (rejected) return;
    try {
      const command = JSON.parse(buffer.toString('utf8'));
      if (command.schema_version !== 1) { json(400, { error_code: 'invalid_payload' }); return; }
      const result = await dispatch({ version: 1, action: 'send', sessionID: command.session_id,
        requestID: command.command_id, prompt: command.prompt });
      json(200, { schema_version: 1, command_id: result.requestID,
        accepted: ['submitted', 'queued'].includes(result.status), status: result.status });
    } catch { json(400, { error_code: 'invalid_payload' }); }
  });
});
server.requestTimeout = 30000;
server.headersTimeout = 10000;
server.maxConnections = 16;
server.on('error', () => { console.error('Boring Notch bridge unavailable'); shutdown(); });
let closing = false;
function shutdown() {
  if (closing) return; closing = true;
  for (const entry of pending.values()) { clearTimeout(entry.timer); entry.reject(Error('stopped')); }
  pending.clear();
  server.close(() => process.exit(0));
  server.closeAllConnections();
  setTimeout(() => process.exit(0), 1000).unref();
}
process.once('disconnect', shutdown);
process.once('SIGTERM', shutdown);
if (!process.send) throw Error('Must be loaded by WorkBuddy');
server.listen(configuration.port, '127.0.0.1', () => {
  process.send({ type: 'wb-extension-ready', extensionId: process.env.WB_EXTENSION_ID, pid: process.pid });
});
