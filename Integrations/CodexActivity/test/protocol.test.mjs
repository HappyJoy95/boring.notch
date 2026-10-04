import test from 'node:test';
import assert from 'node:assert/strict';
import { filterPinnedThreads, latestAssistantReply, statusFromCodexThread, statusFromHook } from '../protocol.mjs';

test('only native pinned, active threads are mirrored', () => {
  const threads = [
    { id: 'pinned', title: 'Pinned', section: { name: 'Pinned' } },
    { id: 'other', title: 'Other', section: { name: 'Projects' } },
    { id: 'archived', title: 'Archived', section: { name: 'Pinned' }, archived: true },
  ];
  assert.deepEqual(filterPinnedThreads(threads).map(({ id }) => id), ['pinned']);
});

test('latest reply only includes final assistant text', () => {
  const items = [
    { type: 'userMessage', text: 'secret prompt' },
    { type: 'reasoning', text: 'private reasoning' },
    { type: 'commandExecution', command: 'secret command' },
    { type: 'agentMessage', phase: 'commentary', text: 'working' },
    { type: 'agentMessage', phase: 'final_answer', text: 'Finished safely.' },
  ];
  assert.equal(latestAssistantReply(items), 'Finished safely.');
});

test('hook events map to display-only states', () => {
  assert.equal(statusFromHook('UserPromptSubmit'), 'running');
  assert.equal(statusFromHook('PermissionRequest'), 'waiting');
  assert.equal(statusFromHook('Stop'), 'completed');
  assert.equal(statusFromHook('Interrupt'), 'interrupted');
  assert.equal(statusFromHook('SessionEnd'), 'idle');
  assert.equal(statusFromHook('unknown'), null);
});

test('a Desktop-owned active turn reported as interrupted without completion metadata is still running', () => {
  assert.equal(statusFromCodexThread(
    { status: { type: 'idle', activeFlags: [] } },
    { status: 'interrupted', completedAt: null, durationMs: null },
  ), 'running');
});

test('current Codex task state wins over stale lifecycle hook state', () => {
  assert.equal(statusFromCodexThread(
    { status: { type: 'active', activeFlags: [] } },
    { status: 'inProgress', completedAt: null, durationMs: null },
  ), 'running');
  assert.equal(statusFromCodexThread(
    { status: { type: 'idle', activeFlags: [] } },
    { status: 'interrupted', completedAt: 1710000000, durationMs: 5000 },
  ), 'interrupted');
});
