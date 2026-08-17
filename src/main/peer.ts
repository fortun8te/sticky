import dgram from 'node:dgram'
import http from 'node:http'
import { hostname, networkInterfaces, tmpdir } from 'node:os'
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  statSync,
  writeFileSync
} from 'node:fs'
import { basename, join, dirname } from 'node:path'
import { randomUUID } from 'node:crypto'

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

export interface DropPayload {
  id: string
  kind: 'text' | 'files'
  text?: string
  files?: Array<{ rel: string; data: string }>
  from: Role
}

export const UDP_PORT = 47831
export const HTTP_PORT = 47832
const MAX_BYTES = 48 * 1024 * 1024
const LIVE_MS = 14000
const BEAT_FAST_MS = 2000
const BEAT_SLOW_MS = 5000

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

function collectFiles(paths: string[]): { rel: string; abs: string; size: number }[] {
  const out: { rel: string; abs: string; size: number }[] = []
  const walk = (abs: string, rel: string) => {
    if (!existsSync(abs)) return
    const st = statSync(abs)
    if (st.isDirectory()) {
      for (const name of readdirSync(abs)) walk(join(abs, name), join(rel, name))
      return
    }
    if (st.isFile()) out.push({ rel: rel.replace(/\\/g, '/'), abs, size: st.size })
  }
  for (const p of paths) walk(p, basename(p))
  return out
}

export function packFiles(paths: string[]): DropPayload['files'] {
  const files = collectFiles(paths)
  const total = files.reduce((n, f) => n + f.size, 0)
  if (!files.length) return []
  if (total > MAX_BYTES) throw new Error('Too big for pill-to-pill (48MB max)')
  return files.map((f) => ({
    rel: f.rel,
    data: readFileSync(f.abs).toString('base64')
  }))
}

export function unpackFiles(files: NonNullable<DropPayload['files']>): string[] {
  const root = join(tmpdir(), 'sticky-inbox', randomUUID())
  const written: string[] = []
  for (const file of files) {
    const dest = join(root, file.rel)
    mkdirSync(dirname(dest), { recursive: true })
    writeFileSync(dest, Buffer.from(file.data, 'base64'))
    written.push(dest)
  }
  return written
}

export class StickyPeer {
  readonly id = randomUUID()
  readonly role = ourRole()
  peers = new Map<string, PeerInfo>()
  private udp = dgram.createSocket({ type: 'udp4', reuseAddr: true })
  private server: http.Server | null = null
  private beat: NodeJS.Timeout | null = null
  private beatMs = BEAT_FAST_MS
  private asleep = false

  constructor(private onDrop: (payload: DropPayload, host: string) => void) {}

  start(): void {
    this.server = http.createServer((req, res) => {
      if (req.method === 'GET' && req.url === '/health') {
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ ok: true, id: this.id, role: this.role }))
        return
      }
      if (req.method === 'POST' && req.url === '/drop') {
        const chunks: Buffer[] = []
        let size = 0
        req.on('data', (c) => {
          size += c.length
          if (size > MAX_BYTES * 1.2) {
            req.destroy()
            return
          }
          chunks.push(c)
        })
        req.on('end', () => {
          try {
            const payload = JSON.parse(Buffer.concat(chunks).toString('utf8')) as DropPayload
            if (payload?.id === this.id) {
              res.writeHead(204)
              res.end()
              return
            }
            this.onDrop(payload, ipv4(req.socket.remoteAddress || ''))
            res.writeHead(204)
            res.end()
          } catch {
            res.writeHead(400)
            res.end('bad')
          }
        })
        return
      }
      res.writeHead(404)
      res.end()
    })
    this.server.listen(HTTP_PORT, '0.0.0.0')
    this.server.on('error', () => {
      /* port busy — existing instance owns LAN */
    })

    this.udp.on('error', () => {
      /* bind failed — existing instance owns LAN */
    })

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

  async send(payload: Omit<DropPayload, 'id' | 'from'>): Promise<boolean> {
    const peer = this.other()
    if (!peer) return false
    const body = JSON.stringify({ ...payload, id: this.id, from: this.role } satisfies DropPayload)
    const host = ipv4(peer.host)
    const url = `http://${host}:${peer.port || HTTP_PORT}/drop`
    for (let i = 0; i < 3; i++) {
      try {
        const res = await fetch(url, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body,
          signal: AbortSignal.timeout(8000)
        })
        if (res.ok || res.status === 204) return true
      } catch {
        await new Promise((r) => setTimeout(r, 120 * (i + 1)))
      }
    }
    return false
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
    if (known?.host) {
      targets.add(ipv4(known.host))
    } else {
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
