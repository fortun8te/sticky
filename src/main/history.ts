import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs'
import { dirname } from 'node:path'
import { clipKey, mergeHistory, TEXT_LIMIT, type ClipItem } from '../shared/types'

export class HistoryStore {
  constructor(private file: string) {
    mkdirSync(dirname(file), { recursive: true })
  }

  read(): ClipItem[] {
    if (!existsSync(this.file)) return []
    try {
      const parsed = JSON.parse(readFileSync(this.file, 'utf8')) as ClipItem[]
      return Array.isArray(parsed) ? parsed : []
    } catch {
      return []
    }
  }

  write(items: ClipItem[]): void {
    mkdirSync(dirname(this.file), { recursive: true })
    writeFileSync(this.file, JSON.stringify(items, null, 2), 'utf8')
  }

  upsert(item: ClipItem): ClipItem[] {
    const items = this.read().filter((i) => clipKey(i) !== clipKey(item))
    const next = mergeHistory([item, ...items], [])
    this.write(next)
    return next
  }

  pin(id: string): ClipItem[] {
    const next = this.read().map((i) => (i.id === id ? { ...i, pinned: !i.pinned } : i))
    this.write(next)
    return next
  }

  remove(id: string): ClipItem[] {
    const next = this.read().filter((i) => i.id !== id)
    this.write(next)
    return next
  }

  clear(): ClipItem[] {
    const pins = this.read().filter((i) => i.pinned)
    this.write(pins)
    return pins
  }
}

export function makeTextClip(text: string, device: ClipItem['device']): ClipItem | null {
  const trimmed = text.replace(/\u0000/g, '')
  if (!trimmed) return null
  const body = trimmed.length > TEXT_LIMIT ? trimmed.slice(0, TEXT_LIMIT) : trimmed
  return {
    id: crypto.randomUUID(),
    type: 'text',
    text: body,
    createdAt: Date.now(),
    pinned: false,
    device
  }
}

export function makeFileClip(files: string[], device: ClipItem['device']): ClipItem | null {
  const unique = [...new Set(files.filter(Boolean))]
  if (!unique.length) return null
  return {
    id: crypto.randomUUID(),
    type: 'files',
    files: unique,
    createdAt: Date.now(),
    pinned: false,
    device
  }
}
