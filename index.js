/**
 * DSH desktop notifier — Host plugin.
 *
 * Watches two host seams and asks a resident PowerShell helper to draw a
 * bottom-right, always-on-top card:
 *
 * - the Agent-scoped `approval/request` and `user-questions/request` waterfalls
 *   (a pending prompt needs a human),
 * - the root `session/event` feed, for `session/title` (title cache) and
 *   `turn/end` (turn finished, aborted, blocked, or failed).
 *
 * The helper is a separate process because DSH gives plugins no OS-notification
 * or always-on-top seam: the Desktop shell spawns this process with
 * ELECTRON_RUN_AS_NODE=1, so no Electron API is reachable from here.
 *
 * @module @local/dsh-desktop-notifier
 */
import { appendFileSync, statSync, writeFileSync } from 'node:fs'
import { spawn } from 'node:child_process'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const HELPER = join(HERE, 'helper', 'notify.ps1')
const DEBUG_LOG = join(HERE, 'notifier-debug.log')
const SYSTEM_ROOT = process.env.SystemRoot || 'C:\\Windows'
const POWERSHELL = join(SYSTEM_ROOT, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')

/**
 * mtime of this file, printed on activation: after an update it tells a freshly imported
 * module apart from a stale one the host still has cached (the bundled copy is a link).
 */
const CODE_MTIME = (() => {
  try {
    return statSync(join(HERE, 'index.js')).mtime.toISOString()
  } catch {
    return 'unknown'
  }
})()

/**
 * Palette and label per notification kind. `accentInterrupted` follows the user's
 * green-for-interrupted request; `accentFailed` covers every ending DSH paints as a
 * failure row ("本轮运行失败").
 */
const DEFAULTS = {
  // How long a toast stays on screen when nobody clicks it (30 s).
  durationMs: 30000,
  suppressWhenFocused: true,
  mergeWindowMs: 150,
  notifyApprovals: true,
  notifyQuestions: true,
  notifyTurnEnd: true,
  skipSubagentTurns: true,
  maxPopupItems: 4,
  debug: false,
  accentPending: '#F0B429',
  accentDone: '#2FBF71',
  accentInterrupted: '#2FBF71',
  accentBlocked: '#FF8A3D',
  accentFailed: '#E5484D',
  accentUnknown: '#8B8F98',
}

/**
 * Map one `TurnEndReason` to a notification descriptor.
 *
 * Kept in step with the Desktop client's own failure rows
 * (`dsh-client-ui-chat/src/client/conversation-nodes/turn-error.ts`): DSH draws a
 * failure row for `error`, for an `interrupted` turn (process exited mid-turn), and
 * for an `aborted` turn cancelled by the `deepseek-account/signed-out` hook — so all
 * three are treated as failures here. User/parent cancellations stay green.
 *
 * @param {unknown} reason - the `turn/end` payload.
 * @param {object} o - resolved options.
 * @returns {{kind: string, label: string, accent: string} | undefined}
 */
function reasonToItem(reason, o) {
  const kind = reason && typeof reason === 'object' ? reason.kind : undefined
  switch (kind) {
    case 'completed':
      return { kind: 'done', label: '已完成', accent: o.accentDone }
    case 'aborted':
    case 'interrupted': {
      const cause = reason && reason.reason
      const signedOut = Boolean(cause) && cause.kind === 'hook' && cause.reason === 'deepseek-account/signed-out'
      if (kind === 'interrupted' || signedOut) {
        return { kind: 'failed', label: '运行失败', accent: o.accentFailed }
      }
      return { kind: 'interrupted', label: '已中断', accent: o.accentInterrupted }
    }
    case 'blocked':
      return { kind: 'blocked', label: '已阻断', accent: o.accentBlocked }
    case 'error':
      return { kind: 'failed', label: '运行失败', accent: o.accentFailed }
    case 'max-tokens':
      return { kind: 'warn', label: '已达输出上限', accent: o.accentPending }
    case 'forked':
      return undefined
    default:
      // An unknown ending must not masquerade as a success.
      return { kind: 'unknown', label: '已结束', accent: o.accentUnknown }
  }
}

/**
 * Apply the desktop notifier.
 * @param {object} ctx - the host plugin context.
 * @param {object} [config] - row config.
 */
export function apply(ctx, config) {
  const o = { ...DEFAULTS, ...(config && typeof config === 'object' ? config : {}) }
  // `accentError` is the pre-0.2.2 name of `accentFailed`; keep honouring a config that still sets it.
  if (config && typeof config === 'object' && config.accentError !== undefined && config.accentFailed === undefined) {
    o.accentFailed = config.accentError
  }

  /** sessionId -> latest accepted title, from `session/title` events. */
  const titles = new Map()
  /** Pending items inside the merge window. */
  let queue = []
  let mergeTimer = null
  let child = null

  const info = (message) => {
    try {
      const logger = ctx.logger
      if (logger && typeof logger.info === 'function') logger.info(`desktop-notifier: ${message}`)
    } catch {
      /* logging is best-effort */
    }
  }

  /** Append one diagnostic line to notifier-debug.log when `debug` is on (trims at 256 KiB). */
  const dlog = (message) => {
    if (!o.debug) return
    try {
      if (statSync(DEBUG_LOG).size > 262144) writeFileSync(DEBUG_LOG, '')
    } catch {
      /* no log yet */
    }
    try {
      appendFileSync(DEBUG_LOG, `${new Date().toISOString()} ${message}\n`)
    } catch {
      /* diagnostics are best-effort */
    }
  }

  dlog(`activated code=${CODE_MTIME} helper=${HELPER} suppressWhenFocused=${o.suppressWhenFocused}`)

  const ensureHelper = () => {
    if (child && child.exitCode === null && !child.killed) return child
    try {
      child = spawn(POWERSHELL, [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', HELPER,
      ], { stdio: ['pipe', 'ignore', 'ignore'], windowsHide: true })
    } catch (error) {
      info(`helper spawn failed: ${error && error.message}`)
      child = null
      return null
    }
    child.on('error', () => { child = null })
    child.on('exit', () => { child = null })
    return child
  }

  const send = (payload) => {
    const helper = ensureHelper()
    if (!helper || !helper.stdin || !helper.stdin.writable) return
    try {
      helper.stdin.write(`${JSON.stringify(payload)}\n`)
    } catch (error) {
      info(`helper write failed: ${error && error.message}`)
      child = null
    }
  }

  const flush = () => {
    const items = queue
    queue = []
    if (items.length === 0) return
    const merged = []
    for (const item of items) {
      const hit = merged.find((entry) => entry.kind === item.kind && entry.title === item.title)
      if (hit) hit.count += 1
      else merged.push({ ...item, count: 1 })
    }
    const payload = {
      items: merged,
      durationMs: o.durationMs,
      suppressWhenFocused: o.suppressWhenFocused,
      maxItems: o.maxPopupItems,
      shellPid: typeof process.ppid === 'number' ? process.ppid : 0,
    }
    dlog(`flush ${JSON.stringify(payload)}`)
    send(payload)
  }

  const enqueue = (item, title) => {
    if (!item) return
    queue.push({
      kind: item.kind,
      label: item.label,
      accent: item.accent,
      title: title || '当前会话',
    })
    if (mergeTimer !== null) return
    const wait = Number.isFinite(o.mergeWindowMs) ? Math.max(0, o.mergeWindowMs) : 150
    mergeTimer = setTimeout(() => { mergeTimer = null; flush() }, wait)
  }

  /** Resolve a host service by name; undeclared or missing services yield undefined. */
  const service = (name) => {
    try {
      return typeof ctx.get === 'function' ? ctx.get(name) : undefined
    } catch {
      return undefined
    }
  }

  /** Resolve the Session behind an approval/question payload or a session id. */
  const sessionOf = (payload) => {
    if (!payload || typeof payload !== 'object') return undefined
    if (typeof payload.snapshotEvents === 'function' || typeof payload.append === 'function') return payload
    const agent = payload.agent
    if (agent && agent.session && typeof agent.session === 'object') return agent.session
    const id = sessionIdOf(payload)
    if (typeof id !== 'string') return undefined
    try {
      return service('sessions')?.get?.(id)
    } catch {
      return undefined
    }
  }

  /** Fold the last logged `session/title` event — the title source of truth, no service needed. */
  const foldTitle = (events) => {
    if (!Array.isArray(events)) return undefined
    for (let index = events.length - 1; index >= 0; index -= 1) {
      const event = events[index]
      if (
        event &&
        event.type === 'session/title' &&
        event.data &&
        typeof event.data.title === 'string' &&
        event.data.title.length > 0
      ) {
        return event.data.title
      }
    }
    return undefined
  }

  /** Latest title for a session: title service, then the log fold, then the cached event feed. */
  const titleOf = (session, id) => {
    const key = session && typeof session.id === 'string' ? session.id : id
    let title
    if (session) {
      try {
        const snapshot = service('sessionTitle')?.get?.(session)
        if (snapshot && typeof snapshot.title === 'string' && snapshot.title.length > 0) title = snapshot.title
      } catch (error) {
        dlog(`title service unavailable: ${error && error.message}`)
      }
      if (title === undefined) {
        try {
          title = foldTitle(typeof session.snapshotEvents === 'function' ? session.snapshotEvents() : undefined)
        } catch (error) {
          dlog(`title fold failed: ${error && error.message}`)
        }
      }
    }
    if (title === undefined && typeof key === 'string' && titles.has(key)) title = titles.get(key)
    if (typeof title === 'string' && title.length > 0) {
      if (typeof key === 'string') titles.set(key, title)
      return title
    }
    return undefined
  }

  const sessionIdOf = (payload) => {
    if (!payload || typeof payload !== 'object') return undefined
    const agent = payload.agent
    if (agent && typeof agent.sessionId === 'string') return agent.sessionId
    if (typeof payload.sessionId === 'string') return payload.sessionId
    const session = payload.session
    if (session && typeof session.id === 'string') return session.id
    return undefined
  }

  const onApproval = (request, next) => {
    try {
      if (o.notifyApprovals) {
        const session = sessionOf(request)
        const title = titleOf(session, sessionIdOf(request))
        dlog(`approval request session=${session && session.id} tool=${request && request.toolName} title=${title}`)
        enqueue(
          { kind: 'pending', label: '待确认', accent: o.accentPending },
          title,
        )
      }
    } catch (error) {
      info(`approval handler failed: ${error && error.message}`)
    }
    return typeof next === 'function' ? next() : undefined
  }

  const onQuestion = (request, next) => {
    try {
      if (o.notifyQuestions) {
        const session = sessionOf(request)
        const title = titleOf(session, sessionIdOf(request))
        dlog(`question request session=${session && session.id} title=${title}`)
        enqueue(
          { kind: 'question', label: '待回答', accent: o.accentPending },
          title,
        )
      }
    } catch (error) {
      info(`question handler failed: ${error && error.message}`)
    }
    return typeof next === 'function' ? next() : undefined
  }

  const onSessionEvent = (session, event) => {
    try {
      if (!event || typeof event.type !== 'string') return
      const id = session && typeof session.id === 'string' ? session.id : undefined
      if (event.type === 'session/title') {
        const text = event.data && typeof event.data.title === 'string' ? event.data.title : ''
        if (id !== undefined && text.length > 0) titles.set(id, text)
        return
      }
      if (event.type === 'turn/start') {
        dlog(`turn start session=${id}`)
        return
      }
      if (event.type !== 'turn/end' || !o.notifyTurnEnd) return
      const reason = event.data && event.data.reason
      const title = titleOf(session, id)
      dlog(`turn end session=${id} origin=${session?.header?.origin} reason=${JSON.stringify(reason)} title=${title}`)
      if (o.skipSubagentTurns && session?.header?.origin === 'subagent') {
        dlog(`turn end skipped (subagent) session=${id}`)
        return
      }
      enqueue(reasonToItem(reason, o), title)
    } catch (error) {
      info(`session handler failed: ${error && error.message}`)
    }
  }

  ctx.effect(() => {
    ensureHelper()
    const disposers = []
    const listen = (name, handler) => {
      try {
        disposers.push(ctx.on(name, handler))
      } catch (error) {
        info(`cannot listen for ${name}: ${error && error.message}`)
      }
    }
    listen('approval/request', onApproval)
    listen('user-questions/request', onQuestion)
    listen('session/event', onSessionEvent)
    return () => {
      for (const dispose of disposers) {
        try {
          dispose?.()
        } catch {
          /* ignore */
        }
      }
      if (mergeTimer !== null) {
        clearTimeout(mergeTimer)
        mergeTimer = null
      }
      queue = []
      titles.clear()
      if (child) {
        try {
          child.stdin?.end()
          child.kill()
        } catch {
          /* ignore */
        }
        child = null
      }
    }
  }, 'desktop-notifier listeners')
}
