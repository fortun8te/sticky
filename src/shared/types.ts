export type ClipType = 'text' | 'files'
export type IslandMode = 'idle' | 'open' | 'hot' | 'busy'
export type ExpandReason = 'drag' | 'focus' | 'hotkey' | 'hover'

export interface ClipItem {
  id: string
  type: ClipType
  text?: string
  files?: string[]
  createdAt: number
  pinned: boolean
  device: 'windows' | 'macos' | 'linux' | 'unknown'
}

export interface StickyStatus {
  lastApp: string
  syncPath: string | null
  syncOk: boolean
  platform: NodeJS.Platform
  canInject: boolean
  peer: { name: string; role: 'above' | 'below' } | null
  fly: 'up' | 'down'
  island: IslandMode
  label: string
}

export interface StickyApi {
  dropText: (text: string) => Promise<{ ok: boolean; message: string }>
  dropFiles: (paths: string[]) => Promise<{ ok: boolean; message: string }>
  getHistory: () => Promise<ClipItem[]>
  pasteItem: (id: string) => Promise<{ ok: boolean; message: string }>
  pinItem: (id: string) => Promise<void>
  deleteItem: (id: string) => Promise<void>
  clearHistory: () => Promise<void>
  getStatus: () => Promise<StickyStatus>
  expand: (reason?: ExpandReason) => void
  collapse: () => void
  haptic: (kind: 'tick' | 'drop' | 'catch') => void
  fileIcons: (paths: string[]) => Promise<string[]>
  onHistory: (cb: (items: ClipItem[]) => void) => () => void
  onStatus: (cb: (status: StickyStatus) => void) => () => void
  onHandoff: (cb: (e: { kind: 'send' | 'recv'; fly: 'up' | 'down'; label: string }) => void) => () => void
  onIsland: (cb: (e: { mode: IslandMode; label: string; reason?: ExpandReason }) => void) => () => void
}

export const HISTORY_LIMIT = 80
export const TEXT_LIMIT = 200_000

export function clipKey(item: Pick<ClipItem, 'type' | 'text' | 'files'>): string {
  if (item.type === 'files') return `files:${(item.files ?? []).join('|')}`
  return `text:${item.text ?? ''}`
}

export function mergeHistory(local: ClipItem[], incoming: ClipItem[]): ClipItem[] {
  const map = new Map<string, ClipItem>()
  for (const item of [...local, ...incoming]) {
    const key = item.id || clipKey(item)
    const prev = map.get(key)
    if (!prev || item.createdAt > prev.createdAt || (item.pinned && !prev.pinned)) {
      map.set(key, { ...prev, ...item, pinned: Boolean(prev?.pinned || item.pinned) })
    }
  }
  const items = [...map.values()]
  items.sort((a, b) => Number(b.pinned) - Number(a.pinned) || b.createdAt - a.createdAt)
  const pins = items.filter((i) => i.pinned)
  const rest = items.filter((i) => !i.pinned).slice(0, HISTORY_LIMIT)
  return [...pins, ...rest]
}

export function previewText(item: ClipItem, max = 72): string {
  if (item.type === 'files') {
    const names = (item.files ?? []).map((f) => f.replace(/^.*[/\\]/, ''))
    if (names.length === 1) return names[0]
    return `${names[0]} +${names.length - 1}`
  }
  const t = (item.text ?? '').replace(/\s+/g, ' ').trim()
  return t.length > max ? `${t.slice(0, max)}…` : t
}
