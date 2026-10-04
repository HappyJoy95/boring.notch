const MAX_TASKS = 64;
const MAX_REPLY_LENGTH = 4000;

export function filterPinnedThreads(threads) {
  if (!Array.isArray(threads)) return [];
  return threads
    .filter((thread) => thread && typeof thread.id === 'string' && thread.id.length > 0)
    .filter((thread) => thread.archived !== true && thread.isArchived !== true)
    .filter((thread) => thread.section?.name === 'Pinned')
    .slice(0, MAX_TASKS);
}

export function latestAssistantReply(items) {
  if (!Array.isArray(items)) return '';
  const finalItem = [...items].reverse().find((item) =>
    item?.type === 'agentMessage'
    && item.phase === 'final_answer'
    && typeof item.text === 'string'
    && item.text.trim().length > 0,
  );
  return finalItem ? Array.from(finalItem.text.trim()).slice(0, MAX_REPLY_LENGTH).join('') : '';
}

export function latestConversationMessages(items) {
  if (!Array.isArray(items)) return [];
  return items.flatMap((item, index) => {
    const role = item?.type === 'userMessage' ? 'user'
      : item?.type === 'agentMessage' ? 'assistant' : null;
    if (!role) return []; // Exclude reasoning and tool payloads.
    if (role === 'assistant' && !['commentary', 'final_answer'].includes(item.phase)) return [];
    const text = typeof item.text === 'string' ? item.text
      : Array.isArray(item.content) ? item.content.map((part) => part?.text ?? part?.value ?? '').join('\n')
        : typeof item.content === 'string' ? item.content : '';
    const cleanText = text.trim();
    if (!cleanText) return [];
    return [{
      id: String(item.id ?? `${index}-${role}`).slice(0, 256),
      role,
      text: Array.from(cleanText).slice(0, 2000).join(''),
      phase: typeof item.phase === 'string' ? item.phase : '',
    }];
  }).slice(-12);
}

export function statusFromHook(eventName) {
  switch (eventName) {
    case 'UserPromptSubmit': return 'running';
    case 'PermissionRequest': return 'waiting';
    case 'Stop': return 'completed';
    case 'Interrupt': return 'interrupted';
    case 'SessionStart': return 'running';
    case 'SessionEnd': return 'idle';
    default: return null;
  }
}

export function statusFromCodexThread(thread, latestTurn) {
  const activeFlags = thread?.status?.activeFlags ?? [];
  if (activeFlags.includes('waitingOnApproval')) return 'waiting';

  const turnStatus = latestTurn?.status;
  if (turnStatus === 'inProgress') return 'running';
  if (turnStatus === 'interrupted'
      && latestTurn?.completedAt == null
      && latestTurn?.durationMs == null) {
    // A separate app-server can report a Desktop-owned live turn this way.
    return 'running';
  }
  if (turnStatus === 'completed') return 'completed';
  if (turnStatus === 'interrupted' || turnStatus === 'failed') return 'interrupted';
  if (thread?.status?.type === 'active') return 'running';
  return 'idle';
}
