import dgram from 'node:dgram'
import http from 'node:http'
import {
  closeSync,
  createReadStream,
  existsSync,
  lstatSync,
  mkdirSync,
  openSync,
  readdirSync,
  rmSync,
  writeSync
} from 'node:fs'
import { basename, dirname, join, relative, resolve, sep } from 'node:path'
import { homedir, hostname, networkInterfaces } from 'node:os'
import { randomUUID } from 'node:crypto'
import { pipeline } from 'node:stream/promises'

export type Role = 'above' | 'below'
export type Fly = 'up' | 'down'

export interface PeerInfo {
  id: string
  host: string
  port: number
  platform: string
  role: Role
  name: string
  seen: number
}

export interface IncomingDrop {
  kind: 'text' | 'files'
  text?: string
  files?: string[]
  from: Role
}

export const UDP_PORT = 47831
export const HTTP_PORT = 47832
export const MAX_BYTES = 8 * 1024 * 1024 * 1024
const MAX_JSON = 48 * 1024 * 1024
const MAX_FILES = 8000
const LIVE_MS = 14000
const BEAT_FAST_MS = 2000
const BEAT_SLOW_MS = 5000
const SKIP = new Set(['.ds_store', 'thumbs.db', 'desktop.ini', '.localized'])
const RESERVED = /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)/i
const MAGIC = Buffer.from('STICKY1\n')

export function ourRole(): Role {
  return process.platform === 'win32' ? 'above' : 'below'
}

export function flyFor(kind: 'send' | 'recv'): Fly {
  const role = ourRole()
  if (role === 'above') return kind === 'send' ? 'down' : 'up'
  return kind === 'send' ? 'up' : 'down'
}

function ipv4(host: string): string {
  return host.replace(/^::ffff:/i, '')
}

function broadcastTargets(): string[] {
  const out = new Set<string>(['255.255.255.255'])
  for (const addrs of Object.values(networkInterfaces())) {
    for (const a of addrs ?? []) {
      const family = String(a.family)
      if (a.internal || (family !== 'IPv4' && family !== '4')) continue
      const ip = a.address.split('.').map(Number)
      const mask = (a.netmask || '255.255.255.0').split('.').map(Number)
      if (ip.length !== 4 || mask.length !== 4) continue
      out.add(ip.map((octet, i) => octet | (~mask[i] & 255)).join('.'))
    }
  }
  return [...out]
}

function skipName(name: string): boolean {
  const n = name.toLowerCase()
  return SKIP.has(n) || n.startsWith('._')
}

export function sanitizeRel(rel: string): string | null {
  const parts = rel.replace(/\\/g, '/').split('/').filter(Boolean)
  const out: string[] = []
  for (let part of parts) {
    if (part === '.' || part === '..') return null
    if (/^[a-zA-Z]:$/.test(part)) return null
    part = part.replace(/[<>:"|?*\u0000-\u001f]/g, '_')
    part = part.replace(/[.\s]+$/g, '_')
    if (RESERVED.test(part)) part = `_${part}`
    if (!part || part === '.' || part === '..') return null
    if (part.length > 180) part = part.slice(0, 180)
    out.push(part)
  }
  return out.length ? out.join('/') : null
}

type LocalFile = { rel: string; abs: string; size: number }

function isInside(root: string, p: string): boolean {
  const r = resolve(root)
  const x = resolve(p)
  return x === r || x.startsWith(r + sep)
}

function pruneNested(paths: string[]): string[] {
  const abs = [...new Set(paths.filter((p) => existsSync(p)))]
  const dirs = abs.filter((p) => {
    try {
      return lstatSync(p).isDirectory()
    } catch {
      return false
    }
  })
  return abs.filter((p) => !dirs.some((d) => p !== d && isInside(d, p)))
}

function commonDir(absFiles: string[]): string | null {
  if (!absFiles.length) return null
  let dir = dirname(absFiles[0])
  for (const file of absFiles.slice(1)) {
    while (dir !== dirname(dir) && !isInside(dir, file)) dir = dirname(dir)
    if (!isInside(dir, file)) return null
  }
  return dir
}

function addFile(abs: string, rel: string, out: LocalFile[], seen: Set<string>): void {
  if (out.length >= MAX_FILES) return
  const clean = sanitizeRel(rel.replace(/\\/g, '/'))
  if (!clean || seen.has(clean) || skipName(basename(clean))) return
  let st
  try {
    st = lstatSync(abs)
  } catch {
    return
  }
  if (!st.isFile() || st.isSymbolicLink()) return
  seen.add(clean)
  out.push({ rel: clean, abs, size: st.size })
}

function walkDir(abs: string, rel: string, out: LocalFile[], seen: Set<string>): void {
  if (out.length >= MAX_FILES) return
  let st
  try {
    st = lstatSync(abs)
  } catch {
    return
  }
  if (st.isSymbolicLink()) return
  if (st.isDirectory()) {
    let names: string[] = []
    try {
      names = readdirSync(abs)
    } catch {
      return
    }
    for (const name of names) {
      if (skipName(name)) continue
      walkDir(join(abs, name), `${rel}/${name}`, out, seen)
    }
    return
  }
  if (st.isFile()) addFile(abs, rel, out, seen)
}

export function collectFiles(paths: string[]): LocalFile[] {
  const roots = pruneNested(paths)
  const dirs: string[] = []
  const files: string[] = []
  for (const p of roots) {
    let st
    try {
      st = lstatSync(p)
    } catch {
      continue
    }
    if (st.isSymbolicLink()) continue
    if (st.isDirectory()) dirs.push(p)
    else if (st.isFile()) files.push(p)
  }
  const out: LocalFile[] = []
  const seen = new Set<string>()
  for (const dir of dirs) walkDir(dir, basename(dir), out, seen)
  if (!files.length) return out
  const resolved = files.map((f) => resolve(f))
  const parent = commonDir(resolved)
  const nested = Boolean(parent && resolved.some((f) => dirname(f) !== parent))
  for (const file of files) {
    const abs = resolve(file)
    const rel =
      nested && parent
        ? join(basename(parent), relative(parent, abs)).replace(/\\/g, '/')
        : basename(file)
    addFile(abs, rel, out, seen)
  }
  return out
}

export function inboxDir(): string {
  const dir = join(homedir(), 'Downloads', 'Sticky')
  mkdirSync(dir, { recursive: true })
  return dir
}

export function uniqueJoin(root: string, name: string): string {
  const safe = sanitizeRel(name) || 'Drop'
  const dest = join(root, safe)
  if (!existsSync(dest)) return dest
  const dot = safe.lastIndexOf('.')
  const stem = dot > 0 ? safe.slice(0, dot) : safe
  const ext = dot > 0 ? safe.slice(dot) : ''
  for (let i = 2; i < 200; i++) {
    const next = join(root, `${stem}-${i}${ext}`)
    if (!existsSync(next)) return next
  }
  return join(root, `${stem}-${Date.now()}${ext}`)
}

export function planInbox(rels: string[], root = inboxDir()): {
  destFor: (rel: string) => string
  clipboard: string[]
} {
  const inbox = root
  const clean = rels.map((r) => sanitizeRel(r)).filter((x): x is string => Boolean(x))
  const tops = [...new Set(clean.map((r) => r.split('/')[0] ?? r))]
  const singleFile = tops.length === 1 && clean.every((r) => r === tops[0])
  if (singleFile) {
    const dest = uniqueJoin(inbox, tops[0] ?? 'Drop')
    return { destFor: () => dest, clipboard: [dest] }
  }
  const session = uniqueJoin(inbox, tops.length === 1 ? (tops[0] ?? 'Drop') : 'Drop')
  return {
    destFor: (rel) => {
      const c = sanitizeRel(rel)
      if (!c) throw new Error('bad path')
      const parts = c.split('/')
      const dest = tops.length === 1 ? join(session, parts.slice(1).join('/')) : join(session, c)
      const resolved = resolve(dest || session)
      const root = resolve(session)
      if (resolved !== root && !resolved.startsWith(root + sep)) throw new Error('path')
      return dest || session
    },
    clipboard: [session]
  }
}

type WireHeader = {
  id: string
  kind: 'text' | 'files'
  from: Role
  text?: string
  files?: Array<{ rel: string; size: number }>
}

export class StickyPeer {
  readonly id = randomUUID()
  readonly role = ourRole()
  peers = new Map<string, PeerInfo>()
  private onDrop: (payload: IncomingDrop, host: string) => void
  private udp = dgram.createSocket({ type: 'udp4', reuseAddr: true })
  private server: http.Server | null = null
  private beat: NodeJS.Timeout | null = null
  private beatMs = BEAT_FAST_MS
  private asleep = false

  constructor(onDrop: (payload: IncomingDrop, host: string) => void) {
    this.onDrop = onDrop
  }

  start(): void {
    this.server = http.createServer((req, res) => {
      if (req.method === 'GET' && req.url === '/health') {
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ ok: true, id: this.id, role: this.role }))
        return
      }
      if (req.method === 'POST' && req.url === '/drop') {
        void this.ingest(req)
          .then((drop) => {
            if (drop) this.onDrop(drop, ipv4(req.socket.remoteAddress || ''))
            res.writeHead(204)
            res.end()
          })
          .catch(() => {
            if (!res.headersSent) {
              res.writeHead(400)
              res.end('bad')
            }
          })
        return
      }
      res.writeHead(404)
      res.end()
    })
    this.server.timeout = 0
    this.server.headersTimeout = 0
    this.server.requestTimeout = 0
    this.server.listen(HTTP_PORT, '0.0.0.0')
    this.server.on('error', () => undefined)

    this.udp.on('error', () => undefined)
    this.udp.on('message', (msg, rinfo) => {
      try {
        const info = JSON.parse(msg.toString('utf8')) as PeerInfo
        if (!info?.id || info.id === this.id) return
        this.peers.set(info.id, {
          ...info,
          host: ipv4(rinfo.address),
          port: info.port || HTTP_PORT,
          seen: Date.now()
        })
      } catch {
        /* ignore */
      }
    })
    this.udp.bind(UDP_PORT, '0.0.0.0', () => {
      try {
        this.udp.setBroadcast(true)
      } catch {
        /* ignore */
      }
      this.announce()
      this.armBeat()
    })
  }

  sleep(): void {
    this.asleep = true
    if (this.beat) clearInterval(this.beat)
    this.beat = null
  }

  wake(): void {
    this.asleep = false
    this.announce()
    this.armBeat()
  }

  stop(): void {
    this.sleep()
    this.asleep = false
    try {
      this.udp.close()
    } catch {
      /* ignore */
    }
    this.server?.close()
    this.server = null
  }

  other(): PeerInfo | null {
    const now = Date.now()
    const live = [...this.peers.values()].filter((p) => now - p.seen < LIVE_MS)
    return live.find((p) => p.role !== this.role) || null
  }

  async send(input: { kind: 'text' | 'files'; text?: string; paths?: string[] }): Promise<boolean> {
    const peer = this.other()
    if (!peer) return false
    const files = input.kind === 'files' && input.paths?.length ? collectFiles(input.paths) : []
    const total = files.reduce((n, f) => n + f.size, 0)
    if (input.kind === 'files' && !files.length) return false
    if (total > MAX_BYTES) throw new Error('Too big (8GB max)')
    const header: WireHeader = {
      id: this.id,
      kind: input.kind,
      from: this.role,
      text: input.text,
      files: files.map((f) => ({ rel: f.rel, size: f.size }))
    }
    const head = Buffer.concat([MAGIC, Buffer.from(`${JSON.stringify(header)}\n`)])
    const host = ipv4(peer.host)
    const port = peer.port || HTTP_PORT
    for (let i = 0; i < 3; i++) {
      try {
        if (await this.push(host, port, head, files, total)) return true
      } catch {
        await new Promise((r) => setTimeout(r, 200 * (i + 1)))
      }
    }
    return false
  }

  private push(
    host: string,
    port: number,
    head: Buffer,
    files: LocalFile[],
    total: number
  ): Promise<boolean> {
    return new Promise((resolveOk, reject) => {
      const req = http.request(
        {
          hostname: host,
          port,
          path: '/drop',
          method: 'POST',
          headers: {
            'content-type': 'application/x-sticky',
            'content-length': String(head.length + total)
          }
        },
        (res) => {
          res.resume()
          res.on('end', () => resolveOk(res.statusCode === 204 || (res.statusCode ?? 500) < 300))
        }
      )
      req.on('error', reject)
      req.setTimeout(files.length ? 600_000 : 12_000, () => {
        req.destroy()
        reject(new Error('timeout'))
      })
      req.write(head)
      void (async () => {
        try {
          for (const file of files) {
            await pipeline(createReadStream(file.abs), req, { end: false })
          }
          req.end()
        } catch (err) {
          req.destroy()
          reject(err)
        }
      })()
    })
  }

  private ingest(req: http.IncomingMessage): Promise<IncomingDrop | null> {
    return new Promise((resolveOk, reject) => {
      let buf = Buffer.alloc(0)
      let mode: 'head' | 'json' | 'bin' = 'head'
      let header: WireHeader | null = null
      let layout: ReturnType<typeof planInbox> | null = null
      let idx = 0
      let filled = 0
      let fd = -1
      let total = 0
      const rels: string[] = []
      let settled = false

      const closeFd = (): void => {
        if (fd < 0) return
        try {
          closeSync(fd)
        } catch {
          /* ignore */
        }
        fd = -1
      }

      const wipePartial = (): void => {
        const junk = layout?.clipboard ?? []
        for (const p of junk) {
          try {
            rmSync(p, { recursive: true, force: true })
          } catch {
            /* ignore */
          }
        }
      }

      const fail = (err: unknown): void => {
        if (settled) return
        settled = true
        closeFd()
        wipePartial()
        reject(err instanceof Error ? err : new Error('bad drop'))
      }

      const ok = (drop: IncomingDrop | null): void => {
        if (settled) return
        settled = true
        closeFd()
        resolveOk(drop)
      }

      const openFile = (rel: string): void => {
        closeFd()
        if (!layout) layout = planInbox(header?.files?.map((f) => f.rel) ?? [rel])
        const dest = layout.destFor(rel)
        mkdirSync(dirname(dest), { recursive: true })
        fd = openSync(dest, 'w')
        const clean = sanitizeRel(rel)
        if (clean) rels.push(clean)
      }

      const drain = (): void => {
        if (!header || header.id === this.id) {
          buf = Buffer.alloc(0)
          return
        }
        const list = header.files ?? []
        while (idx < list.length) {
          const meta = list[idx]
          if (fd < 0) openFile(meta.rel)
          if (meta.size <= 0) {
            closeFd()
            idx += 1
            filled = 0
            continue
          }
          const need = meta.size - filled
          if (!buf.length) break
          const take = Math.min(need, buf.length)
          writeSync(fd, buf.subarray(0, take))
          filled += take
          buf = buf.subarray(take)
          if (filled >= meta.size) {
            closeFd()
            idx += 1
            filled = 0
          }
        }
      }

      const finishBin = (): IncomingDrop | null => {
        closeFd()
        if (!header || header.id === this.id) return null
        if (header.kind === 'files') {
          const clip = layout?.clipboard?.length ? layout.clipboard : planInbox(rels).clipboard
          return { kind: 'files', from: header.from, files: clip }
        }
        return { kind: 'text', from: header.from, text: header.text ?? '' }
      }

      req.on('error', (err) => fail(err))
      req.on('data', (chunk: Buffer) => {
        try {
          total += chunk.length
          if (mode !== 'json' && total > MAX_BYTES * 1.05) {
            req.destroy()
            throw new Error('too big')
          }
          buf = buf.length ? Buffer.concat([buf, chunk]) : chunk
          if (mode === 'head') {
            if (buf.length < 8) return
            if (buf.subarray(0, MAGIC.length).equals(MAGIC)) mode = 'bin'
            else if (buf.subarray(0, 1).toString('utf8').trimStart().startsWith('{')) mode = 'json'
            else throw new Error('bad magic')
          }
          if (mode === 'json') {
            if (buf.length > MAX_JSON) throw new Error('too big')
            return
          }
          if (!header) {
            if (!buf.subarray(0, MAGIC.length).equals(MAGIC)) throw new Error('bad magic')
            const rest = buf.subarray(MAGIC.length)
            const nl = rest.indexOf(10)
            if (nl < 0) {
              if (buf.length > 2_000_000) throw new Error('header')
              return
            }
            header = JSON.parse(rest.subarray(0, nl).toString('utf8')) as WireHeader
            buf = rest.subarray(nl + 1)
            if (header.kind === 'files') layout = planInbox((header.files ?? []).map((f) => f.rel))
          }
          drain()
        } catch (err) {
          fail(err)
        }
      })
      req.on('end', () => {
        try {
          if (mode === 'json') {
            const payload = JSON.parse(buf.toString('utf8')) as {
              id?: string
              kind?: 'text' | 'files'
              from?: Role
              text?: string
              files?: Array<{ rel: string; data: string }>
            }
            if (!payload?.kind || payload.id === this.id) {
              ok(null)
              return
            }
            if (payload.kind === 'files' && payload.files?.length) {
              const planned = planInbox(payload.files.map((f) => f.rel))
              layout = planned
              for (const file of payload.files) {
                const clean = sanitizeRel(file.rel)
                if (!clean) continue
                const dest = planned.destFor(clean)
                mkdirSync(dirname(dest), { recursive: true })
                const handle = openSync(dest, 'w')
                try {
                  writeSync(handle, Buffer.from(file.data, 'base64'))
                } finally {
                  closeSync(handle)
                }
              }
              ok({
                kind: 'files',
                from: payload.from ?? 'above',
                files: planned.clipboard
              })
              return
            }
            ok({ kind: 'text', from: payload.from ?? 'above', text: payload.text ?? '' })
            return
          }
          drain()
          if (!header || header.id === this.id) {
            ok(null)
            return
          }
          if (header.kind === 'files') {
            const list = header.files ?? []
            if (idx < list.length || filled !== 0) throw new Error('truncated')
          }
          ok(finishBin())
        } catch (err) {
          fail(err)
        }
      })
    })
  }

  private armBeat(): void {
    if (this.asleep) return
    const ms = this.other() ? BEAT_SLOW_MS : BEAT_FAST_MS
    if (this.beat && this.beatMs === ms) return
    if (this.beat) clearInterval(this.beat)
    this.beatMs = ms
    this.beat = setInterval(() => {
      if (this.asleep) return
      this.announce()
      this.armBeat()
    }, ms)
  }

  private announce(): void {
    if (this.asleep) return
    const info: PeerInfo = {
      id: this.id,
      host: '',
      port: HTTP_PORT,
      platform: process.platform,
      role: this.role,
      name: hostname(),
      seen: Date.now()
    }
    const buf = Buffer.from(JSON.stringify(info))
    const known = this.other()
    const targets = new Set<string>()
    if (known?.host) targets.add(ipv4(known.host))
    else {
      for (const ip of broadcastTargets()) targets.add(ip)
      for (const p of this.peers.values()) {
        if (p.host) targets.add(ipv4(p.host))
      }
    }
    for (const ip of targets) {
      try {
        this.udp.send(buf, UDP_PORT, ip)
      } catch {
        /* ignore */
      }
    }
  }
}
