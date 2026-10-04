'use strict';
const crypto = require('node:crypto');
function validID(value) {
  return typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}
function createDispatcher(invoke, isPinned, store = new Map(), save = () => {}) {
  const pending = new Map();
  return async function dispatch(command) {
    const reply = status => ({ version: 1, requestID: command?.requestID, status });
    if (!command || command.version !== 1 || !validID(command.sessionID) || !validID(command.requestID)
        || !['send', 'probe'].includes(command.action)) return reply('invalid');
    if (!isPinned(command.sessionID)) return reply('notPinned');
    if (command.action === 'probe') {
      try {
        const result = await invoke('wb:conversations:get', command.sessionID);
        return reply(result && !result.errorCode && !result.__wbError
          && result.info?.id === command.sessionID && result.info?.transport === 'local' ? 'ready' : 'unavailable');
      } catch { return reply('unavailable'); }
    }
    const prompt = typeof command.prompt === 'string' ? command.prompt.trim() : '';
    if (!prompt || prompt.length > 12000) return reply('invalid');
    const hash = crypto.createHash('sha256').update(command.sessionID + '\n' + prompt).digest('hex');
    const prior = store.get(command.requestID);
    if (prior) {
      if (prior.hash !== hash) return reply('invalid');
      return pending.get(command.requestID) ?? reply(prior.status);
    }
    // Bound the ledger and refuse new sends rather than evict an uncertain delivery.
    if (store.size >= 4096) return reply('busy');
    const entry = { hash, status: 'unknown' };
    store.set(command.requestID, entry);
    try { save(store); } catch { store.delete(command.requestID); return reply('failed'); }
    const operation = (async () => {
      try {
        const result = await invoke('wb:conversations:sendPrompt', command.sessionID,
          [{ type: 'text', text: prompt }], { clientRequestId: command.requestID, _expectQueueReceipt: true });
        entry.status = result?.errorCode || result?.__wbError ? 'failed'
          : result?.disposition === 'queued' ? 'queued' : 'submitted';
      } catch { entry.status = 'unknown'; }
      try { save(store); } catch { entry.status = 'unknown'; }
      return reply(entry.status);
    })();
    pending.set(command.requestID, operation);
    try { return await operation; } finally { pending.delete(command.requestID); }
  };
}
module.exports = { createDispatcher, validID };
