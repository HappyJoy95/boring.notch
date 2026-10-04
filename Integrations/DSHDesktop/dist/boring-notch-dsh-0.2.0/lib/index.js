import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import crypto from 'node:crypto'
import http from 'node:http'

export const name = 'boring-notch-dsh'
const VERSION = '0.2.0'
export const inject = ['sessionController', 'workspaceController']

const MAX_SESSIONS = 32
const MAX_RESPONSE_BYTES = 262144
const MAX_HISTORY_MESSAGES = 40
const SESSION_ID = /^[A-Za-z0-9._:-]{1,256}$/

export function apply(ctx) {
  const controller = ctx.sessionController
  const workspaceController = ctx.workspaceController
  if (!controller || typeof controller.list !== 'function' || typeof controller.page !== 'function'
      || !workspaceController || typeof workspaceController.follow !== 'function') return

  const lifecycle = new AbortController()
  let pinnedSessionIDs = null
  const diagnostics = { pinStream: 'starting', lastFrameType: null, lastPinCount: null, lastTaskError: null }
  let resolvePinBaseline
  let rejectPinBaseline
  const pinBaseline = new Promise((resolve, reject) => {
    resolvePinBaseline = resolve
    rejectPinBaseline = reject
  })
  void followPinnedSessions(workspaceController, lifecycle.signal, frame => {
    diagnostics.lastFrameType = typeof frame?.type === 'string' ? frame.type : 'unknown'
    if (frame?.type === 'baseline' && Array.isArray(frame.value?.pinnedSessionIds)) {
      pinnedSessionIDs = new Set(frame.value.pinnedSessionIds.filter(id => typeof id === 'string' && SESSION_ID.test(id)))
      diagnostics.pinStream = 'ready'
      diagnostics.lastPinCount = pinnedSessionIDs.size
      resolvePinBaseline(pinnedSessionIDs)
    } else if (frame?.type === 'pinned' && Array.isArray(frame.pinnedSessionIds)) {
      pinnedSessionIDs = new Set(frame.pinnedSessionIds.filter(id => typeof id === 'string' && SESSION_ID.test(id)))
      diagnostics.lastPinCount = pinnedSessionIDs.size
    }
  }).catch(error => {
    diagnostics.pinStream = 'failed'
    diagnostics.lastTaskError = safeErrorName(error)
    rejectPinBaseline(error)
  })

  const directory = path.join(os.homedir(), 'Library', 'Application Support', 'Boring Notch', 'DSH')
  const configFile = path.join(directory, 'bridge-config.json')
  let token
  try {
    secureDirectory(directory)
    token = crypto.randomBytes(32).toString('hex')
  } catch (error) {
    console.error('[boring-notch-dsh] bridge setup unavailable')
    return
  }

  const server = http.createServer(async (req, res) => {
    const json = (status, value) => {
      const body = Buffer.from(JSON.stringify(value))
      if (body.length > MAX_RESPONSE_BYTES) {
        res.writeHead(413).end()
        return
      }
      res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' })
      res.end(body)
    }
    if (req.method !== 'GET' || req.headers.authorization !== `Bearer ${token}` || req.headers.origin) {
      json(401, { error_code: 'unauthorized' })
      return
    }
    try {
      const url = new URL(req.url || '/', 'http://127.0.0.1')
      if (url.pathname === '/v1/health') {
        json(200, { schema_version: 1, extension_id: 'boring-notch-dsh', version: VERSION, diagnostics })
      } else if (url.pathname === '/v1/tasks') {
        try {
          json(200, await listTasks(controller, await pinBaseline))
        } catch (error) {
          diagnostics.lastTaskError = safeErrorName(error)
          throw error
        }
      } else if (url.pathname === '/v1/history') {
        const sessionID = url.searchParams.get('session_id') || ''
        const cursor = url.searchParams.get('cursor')
        json(200, await readHistory(controller, sessionID, cursor, await pinBaseline))
      } else {
        json(404, { error_code: 'not_found' })
      }
    } catch {
      json(503, { error_code: 'unavailable' })
    }
  })
  server.maxConnections = 8
  server.requestTimeout = 5000
  server.headersTimeout = 3000
  server.on('clientError', (_error, socket) => socket.destroy())

  server.listen(0, '127.0.0.1', () => {
    try {
      const address = server.address()
      if (!address || typeof address === 'string') throw new Error('listener unavailable')
      const temporary = configFile + '.tmp-' + process.pid
      fs.writeFileSync(temporary, JSON.stringify({ port: address.port, token }), { mode: 0o600, flag: 'wx' })
      fs.renameSync(temporary, configFile)
      fs.chmodSync(configFile, 0o600)
    } catch {
      server.close()
      console.error('[boring-notch-dsh] bridge config unavailable')
    }
  })

  let disposed = false
  ctx.effect(() => () => {
    if (disposed) return
    disposed = true
    lifecycle.abort()
    server.close()
    try {
      const current = JSON.parse(fs.readFileSync(configFile, 'utf8'))
      if (current.token === token) fs.unlinkSync(configFile)
    } catch {}
  }, 'boring-notch-dsh: read-only bridge')
}

function safeErrorName(error) {
  if (!error || typeof error.name !== 'string') return 'Error'
  const message = typeof error.message === 'string' ? error.message.replace(/\s+/g, ' ').slice(0, 100) : ''
  return message ? `${error.name.slice(0, 40)}: ${message}` : error.name.slice(0, 40)
}

function secureDirectory(directory) {
  const appSupport = path.join(os.homedir(), 'Library', 'Application Support')
  for (const candidate of [path.join(appSupport, 'Boring Notch'), directory]) {
    try { fs.mkdirSync(candidate, { mode: 0o700 }) } catch (error) { if (error.code !== 'EEXIST') throw error }
    const info = fs.lstatSync(candidate)
    if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid()) throw new Error('unsafe bridge directory')
    fs.chmodSync(candidate, 0o700)
  }
}

async function followPinnedSessions(controller, signal, onFrame) {
  for await (const frame of controller.follow(signal)) {
    signal.throwIfAborted()
    onFrame(frame)
  }
  if (!signal.aborted) throw new Error('workspace pin stream closed')
}

async function visibleSessions(controller, pinnedIDs, signal) {
  const result = await controller.list({}, signal)
  if (!result || !Array.isArray(result.items)) throw new Error('invalid session list')
  return result.items.filter(item => item && typeof item.sessionId === 'string'
    && SESSION_ID.test(item.sessionId) && pinnedIDs.has(item.sessionId)
    && item.blank !== true && item.origin !== 'subagent')
}

async function listTasks(controller, pinnedIDs) {
  const items = await visibleSessions(controller, pinnedIDs, new AbortController().signal)
  return items.slice(0, MAX_SESSIONS).map(item => toTask(item))
}

function toTask(item) {
  const projections = item.projections?.values || {}
  const cwdName = typeof item.cwd === 'string' ? path.basename(item.cwd) : ''
  const title = typeof projections.title === 'string' && projections.title.trim()
    ? projections.title.trim().slice(0, 300) : (cwdName || 'DSH 会话').slice(0, 300)
  let updatedAt
  try {
    updatedAt = item.updatedAt instanceof Date ? item.updatedAt : new Date(item.updatedAt)
  } catch {
    updatedAt = new Date(0)
  }
  if (Number.isNaN(updatedAt.getTime())) updatedAt = new Date(0)
  return {
    id: 'dsh:' + item.sessionId,
    provider: 'dsh',
    title,
    status: item.running === true ? 'running' : 'completed',
    latestReply: '',
    messages: [],
    updatedAt: updatedAt.toISOString().replace(/\.\d{3}Z$/, 'Z')
  }
}

async function readHistory(controller, sessionID, rawCursor, pinnedIDs) {
  if (!SESSION_ID.test(sessionID)) throw new Error('invalid session id')
  const items = await visibleSessions(controller, pinnedIDs, new AbortController().signal)
  const item = items.find(candidate => candidate.sessionId === sessionID)
  if (!item) throw new Error('session unavailable')
  const throughSeq = item.projections?.asOfSeq
  if (!Number.isSafeInteger(throughSeq) || throughSeq < 0) return { messages: [], nextCursor: null }

  let beforeSeq
  if (rawCursor !== null) {
    const match = /^(\d{1,12}):(\d{1,12})$/.exec(rawCursor)
    if (!match || Number(match[1]) !== throughSeq) throw new Error('invalid cursor')
    beforeSeq = Number(match[2])
    if (!Number.isSafeInteger(beforeSeq) || beforeSeq < 0 || beforeSeq > throughSeq + 1) throw new Error('invalid cursor')
  }

  const request = { address: { kind: 'session', sessionId: sessionID }, throughSeq, maxMessages: MAX_HISTORY_MESSAGES }
  if (beforeSeq !== undefined) request.beforeSeq = beforeSeq
  const page = await controller.page(request, new AbortController().signal)
  const messages = []
  for (const record of page.records || []) {
    const event = record?.event
    if (!event || !['user/message', 'assistant/message'].includes(event.type)) continue
    const message = event.type === 'user/message' ? event.data : event.data?.message
    const role = event.type === 'user/message' ? 'user' : 'assistant'
    const text = messageText(message)
    if (!text) continue
    messages.push({ id: sessionID + ':' + event.seq, role, text, timelineTime: event.time / 1000, timelineIndex: event.seq })
  }
  const firstSequence = (page.records || []).find(record => record?.event && Number.isSafeInteger(record.event.seq))?.event.seq
  const nextCursor = page.hasMore && Number.isSafeInteger(firstSequence) && firstSequence > 0
    ? `${throughSeq}:${firstSequence}` : null
  return { messages, nextCursor }
}

function messageText(message) {
  if (!message || !Array.isArray(message.content)) return ''
  const text = message.content.filter(block => block && block.type === 'text' && typeof block.text === 'string')
    .map(block => block.text).join('\n').trim()
  return [...text].slice(0, 2000).join('')
}
