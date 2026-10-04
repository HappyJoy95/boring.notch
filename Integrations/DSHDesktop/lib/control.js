import crypto from 'node:crypto'
const ID = /^[A-Za-z0-9._:-]{1,256}$/

export function createControls(controller, currentPins) {
  const receipts = new Map()
  const busy = new Set()
  return async (action, body) => {
    if (!body || !['send', 'stop'].includes(action) || !ID.test(body.session_id ?? '')
        || !ID.test(body.request_id ?? '') || (action === 'send' && (typeof body.prompt !== 'string'
          || !body.prompt.trim() || Buffer.byteLength(body.prompt) > 8192))) return { result: 'invalid' }
    const method = action === 'send' ? 'prompt' : 'cancel'
    if (typeof controller[method] !== 'function') return { result: 'unavailable' }
    const hash = crypto.createHash('sha256').update(JSON.stringify([action, body.session_id, body.prompt ?? ''])).digest('hex')
    const cached = receipts.get(body.request_id)
    if (cached) return cached.hash === hash ? cached.promise : { result: 'invalid' }
    if (busy.has(body.session_id)) return { result: 'busy' }
    if (receipts.size >= 256) {
      const completed = [...receipts].find(([, entry]) => entry.confirmed)
      if (!completed) return { result: 'busy' }
      receipts.delete(completed[0])
    }
    busy.add(body.session_id)
    const entry = { hash, confirmed: false }
    entry.promise = (async () => {
      try {
        let items
        try { items = (await controller.list({}, AbortSignal.timeout(4000)))?.items }
        catch { return { result: 'unavailable' } }
        const pins = currentPins()
        if (!pins?.has(body.session_id) || !Array.isArray(items)
            || !items.some(item => item?.sessionId === body.session_id && item.blank !== true && item.origin !== 'subagent')) {
          return { result: 'notPinned' }
        }
        const request = action === 'send'
          ? { sessionId: body.session_id, requestId: body.request_id, mode: 'queue', content: [{ type: 'text', text: body.prompt }] }
          : { sessionId: body.session_id }
        try {
          const result = await controller[method](request, AbortSignal.timeout(8000))
          if (result?.accepted !== true) return { result: 'unknown' }
          entry.confirmed = true
          return { result: action === 'send' ? 'queued' : 'submitted' }
        } catch { return { result: 'unknown' } }
      } finally { busy.delete(body.session_id) }
    })()
    receipts.set(body.request_id, entry)
    return entry.promise
  }
}
