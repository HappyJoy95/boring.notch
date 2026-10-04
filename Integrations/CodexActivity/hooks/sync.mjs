import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { filterPinnedThreads, latestAssistantReply, latestConversationMessages, statusFromCodexThread, statusFromHook } from '../protocol.mjs';

async function main() {
  const endpoint = process.env.BORING_NOTCH_ENDPOINT ?? 'http://127.0.0.1:57321/v1/snapshot';
  const token = process.env.BORING_NOTCH_TOKEN;
  const hookInput = await readStdin();
  const eventName = hookInput?.hook_event_name;
  const codexStatus = statusFromHook(eventName);

  if (token && codexStatus) {
    try {
      const snapshot = await readPinnedSnapshot(hookInput, codexStatus);
      await fetch(endpoint, {
        method: 'POST',
        headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
        body: JSON.stringify(snapshot),
        signal: AbortSignal.timeout(1800),
      });
    } catch {
      // The bridge is optional and must never block or affect a Codex turn.
    }
  }
}

async function readStdin() {
  let input = '';
  for await (const chunk of process.stdin) input += chunk;
  try { return JSON.parse(input); } catch { return null; }
}

async function readPinnedSnapshot(hook, eventStatus) {
  const child = spawn(resolveCodexExecutable(), ['app-server'], {
    stdio: ['pipe', 'pipe', 'ignore'],
    env: process.env,
  });
  const client = new AppServerClient(child);
  try {
    await client.initialize();
    const listed = await client.request('thread/list', {
      limit: 200,
      archived: false,
      isPinned: true,
      useStateDbOnly: true,
    });
    const pinned = filterPinnedThreads(listed?.data ?? []);
    const tasks = await Promise.all(pinned.map(async (thread) => {
      let latestReply = '';
      let messages = [];
      let newestTurn;
      try {
        const turns = await client.request('thread/turns/list', {
          threadId: thread.id,
          limit: 1,
          sortDirection: 'desc',
          itemsView: 'full',
        });
        newestTurn = turns?.data?.[0];
        const items = newestTurn?.items ?? newestTurn?.turn?.items ?? [];
        latestReply = latestAssistantReply(items);
        messages = latestConversationMessages(items);
      } catch {
        // Older Codex builds may not support the experimental turns endpoint.
      }
      return {
        id: thread.id,
        title: thread.name ?? thread.title ?? 'Codex task',
        status: statusFromCodexThread(thread, newestTurn),
        latestReply,
        messages,
        updatedAt: isoTimestamp(),
      };
    }));
    const eventTask = tasks.find((task) => task.id === hook?.session_id);
    const transientEvent = eventTask
      && !(['completed', 'interrupted'].includes(eventStatus) && eventTask.status === 'running') ? {
      taskID: eventTask.id,
      title: eventTask.title,
      status: eventStatus,
      occurredAt: isoTimestamp(),
    } : null;
    return { tasks, event: transientEvent };
  } finally {
    client.close();
  }
}

function isoTimestamp() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function resolveCodexExecutable() {
  if (process.env.CODEX_APP_SERVER_EXECUTABLE) return process.env.CODEX_APP_SERVER_EXECUTABLE;
  const appBundled = [
    '/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex',
    join(homedir(), 'Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex'),
  ].find(existsSync);
  if (appBundled) return appBundled;
  return 'codex';
}

class AppServerClient {
  constructor(child) {
    this.child = child;
    this.nextID = 1;
    this.pending = new Map();
    this.buffer = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => this.consume(chunk));
  }

  async initialize() {
    await this.request('initialize', {
      clientInfo: { name: 'boring-notch-codex-activity', title: 'Boring Notch', version: '0.1.0' },
      capabilities: {},
    });
    this.notify('initialized', {});
  }

  request(method, params) {
    const id = this.nextID++;
    const response = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error('Codex App Server request timed out'));
      }, 3500);
      this.pending.set(id, { resolve, reject, timer });
    });
    this.write({ method, id, params });
    return response;
  }

  notify(method, params) {
    this.write({ method, params });
  }

  write(message) {
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  consume(chunk) {
    this.buffer += chunk;
    let newline;
    while ((newline = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, newline);
      this.buffer = this.buffer.slice(newline + 1);
      let message;
      try { message = JSON.parse(line); } catch { continue; }
      if (!Number.isInteger(message.id)) continue;
      const pending = this.pending.get(message.id);
      if (!pending) continue;
      clearTimeout(pending.timer);
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(message.error.message ?? 'App Server error'));
      else pending.resolve(message.result);
    }
  }

  close() {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error('Codex App Server disconnected'));
    }
    this.pending.clear();
    this.child.kill();
  }
}

main();
