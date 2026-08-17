import dgram from 'node:dgram'
import http from 'node:http'
import { hostname, tmpdir } from 'node:os'
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

const UDP_PORT = 47831
const HTTP_PORT = 47832
const MAX_BYTES = 48 * 1024 * 1024

export function ourRole(): Role {
  return process.platform === 'win32' ? 'above' : 'below'
}

export function flyFor(kind: 'send' | 'recv'): Fly {
  const role = ourRole()
  if (role === 'above') return kind === 'send' ? 'down' : 'up'
  return kind === 'send' ? 'up' : 'down'
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
            this.onDrop(payload, req.socket.remoteAddress || '')
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

    this.udp.on('message', (msg, rinfo) => {
      try {
        const info = JSON.parse(msg.toString('utf8')) as PeerInfo
        if (!info?.id || info.id === this.id) return
        this.peers.set(info.id, { ...info, host: rinfo.address, seen: Date.now() })
      } catch {
        /* ignore */
      }
    })
    this.udp.bind(UDP_PORT, () => {
      try {
        this.udp.setBroadcast(true)
      } catch {
        /* ignore */
      }
    })

    this.beat = setInterval(() => this.announce(), 1200)
    this.announce()
  }

  stop(): void {
    if (this.beat) clearInterval(this.beat)
    this.udp.close()
    this.server?.close()
  }

  other(): PeerInfo | null {
    const now = Date.now()
    const live = [...this.peers.values()].filter((p) => now - p.seen < 4000)
    const opposite = live.find((p) => p.role !== this.role)
    return opposite || live[0] || null
  }

  async send(payload: Omit<DropPayload, 'id' | 'from'>): Promise<boolean> {
    const peer = this.other()
    if (!peer) return false
    const body = JSON.stringify({ ...payload, id: this.id, from: this.role } satisfies DropPayload)
    const url = `http://${peer.host}:${peer.port || HTTP_PORT}/drop`
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body
    })
    return res.ok || res.status === 204
  }

  private announce(): void {
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
    for (const ip of ['255.255.255.255', '10.255.255.255', '192.168.255.255']) {
      try {
        this.udp.send(buf, UDP_PORT, ip)
      } catch {
        /* ignore */
      }
    }
  }
}

export { relative }
