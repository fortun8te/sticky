import { playUi } from './sound'
import { previewText, type ClipItem, type ExpandReason, type IslandMode } from '../shared/types'

const bar = document.querySelector('#bar') as HTMLElement
const box = document.querySelector('#box') as HTMLInputElement
const hint = document.querySelector('#hint') as HTMLElement
const stack = document.querySelector('#stack') as HTMLElement | null
const hist = document.querySelector('#hist') as HTMLElement | null
const peer = document.querySelector('#peer') as HTMLElement | null
const api = window.sticky
const MODES: IslandMode[] = ['idle', 'open', 'hot', 'busy']

let mode: IslandMode = 'idle'
let lastIsland: IslandMode = 'idle'
let lastLabel = ''
let focused = false
let over = false
let pass: boolean | null = null
let dragging = false
let dragDepth = 0
let errTimer = 0
let leaveTimer = 0
let handoffTimer = 0

function paint(s?: { platform?: string; peer?: unknown } | null): void {
  const mac = s?.platform === 'darwin'
  document.documentElement.classList.toggle('mac', mac)
  document.documentElement.classList.toggle('win', !mac)
  if (peer) peer.hidden = !s?.peer
  apply()
}

function setMode(next: IslandMode, reason?: ExpandReason): void {
  mode = next
  const root = document.documentElement
  for (const m of MODES) {
    root.classList.toggle(m, m === next)
    document.body.classList.toggle(m, m === next)
  }
  root.classList.remove('in')
  void root.offsetWidth
  root.classList.add('in')
  bar.classList.toggle('hot', next === 'hot')
  bar.classList.toggle('busy', next === 'busy')
  box.tabIndex = next === 'idle' ? -1 : 0
  box.placeholder = next === 'hot' && !lastLabel ? 'Drop' : ''
  if (next === 'idle') {
    focused = false
    if (document.activeElement === box) box.blur()
  } else if (reason === 'focus' || reason === 'hotkey') {
    box.focus({ preventScroll: true })
  }
  if (lastIsland === 'idle' && next !== 'idle' && next !== 'busy' && reason !== 'hover') playUi('tick')
  lastIsland = next
  apply()
}

function setHint(label: string): void {
  lastLabel = label
  if (errTimer) return
  hint.textContent = label
}

void api?.getStatus?.().then((s) => {
  paint(s)
  if (s?.island) setMode(s.island)
  if (typeof s?.label === 'string') setHint(s.label)
})
api?.onStatus?.(paint)
api?.onIsland?.((e) => {
  setMode(e.mode, e.reason)
  setHint(e.label)
})

api?.onHandoff?.((e) => {
  playUi(e.kind === 'recv' ? 'catch' : 'drop')
  bar.classList.remove('hand-send', 'hand-recv', 'fly-up', 'fly-down')
  bar.classList.add(e.kind === 'recv' ? 'hand-recv' : 'hand-send', e.fly === 'down' ? 'fly-down' : 'fly-up')
  setMode('busy')
  setHint(e.label)
  window.clearTimeout(handoffTimer)
  handoffTimer = window.setTimeout(() => {
    bar.classList.remove('hand-send', 'hand-recv', 'fly-up', 'fly-down')
  }, 1200)
})

function pathFor(file?: File | null): string {
  if (!file || !api?.pathForFile) return ''
  try {
    return api.pathForFile(file) || ''
  } catch {
    return ''
  }
}

function pathsFromDataTransfer(
  files: FileList | File[] | null,
  items?: DataTransferItemList | null
): string[] {
  const seen = new Set<string>()
  const out: string[] = []
  const add = (p: string): void => {
    if (!p || seen.has(p)) return
    seen.add(p)
    out.push(p)
  }
  if (items?.length) {
    for (const item of items) {
      if (item.kind !== 'file') continue
      const file = item.getAsFile()
      add(pathFor(file))
    }
  }
  if (!out.length && files?.length) {
    for (const file of files) add(pathFor(file))
  }
  out.sort((a, b) => a.length - b.length)
  return out.filter((p, i) => {
    const n = p.replace(/\\/g, '/').replace(/\/$/, '')
    return !out.slice(0, i).some((r) => {
      const root = r.replace(/\\/g, '/').replace(/\/$/, '')
      return n === root || n.startsWith(`${root}/`)
    })
  })
}

async function showStack(paths: string[]): Promise<void> {
  if (!stack || !api?.fileIcons) return
  const urls = paths.length ? await api.fileIcons(paths) : []
  stack.replaceChildren()
  for (const url of urls.filter(Boolean).slice(0, 3)) {
    const img = document.createElement('img')
    img.src = url
    img.alt = ''
    stack.append(img)
  }
  stack.hidden = !stack.childElementCount
}

async function paintHist(items: ClipItem[]): Promise<void> {
  if (!hist) return
  hist.replaceChildren()
  for (const item of items.slice(0, 4)) {
    const b = document.createElement('button')
    b.type = 'button'
    b.className = 'chip'
    b.title = previewText(item, 48)
    if (item.type === 'files' && item.files?.[0] && api?.fileIcons) {
      const urls = await api.fileIcons(item.files)
      if (urls[0]) {
        const img = document.createElement('img')
        img.src = urls[0]
        img.alt = ''
        b.append(img)
      } else b.textContent = '•'
    } else {
      const ch = (item.text ?? '').trim().slice(0, 1)
      b.textContent = ch ? ch.toUpperCase() : 'Aa'
    }
    b.addEventListener('click', (e) => {
      e.preventDefault()
      e.stopPropagation()
      void api?.pasteItem?.(item.id)
    })
    hist.append(b)
  }
}

void api?.getHistory?.().then((items) => void paintHist(items ?? []))
api?.onHistory?.((items) => void paintHist(items))

function flashErr(message: string): void {
  const msg = message.trim()
  if (!msg) return
  window.clearTimeout(errTimer)
  hint.textContent = msg
  hint.classList.add('err')
  errTimer = window.setTimeout(() => {
    hint.classList.remove('err')
    hint.textContent = lastLabel
    errTimer = 0
  }, 2200)
}

async function dropText(text: string): Promise<void> {
  if (!text || !api?.dropText) return
  box.value = ''
  const r = await api.dropText(text)
  if (r?.message && (r.ok === false || /missed|offline/i.test(r.message))) flashErr(r.message)
}

async function dropFiles(list?: FileList | File[] | null, items?: DataTransferItemList | null): Promise<void> {
  box.value = ''
  const files = pathsFromDataTransfer(list, items)
  if (!files.length || !api?.dropFiles) return
  void showStack(files)
  const r = await api.dropFiles(files)
  if (r?.message && (r.ok === false || /missed|offline/i.test(r.message))) flashErr(r.message)
}

box.addEventListener('paste', (e) => {
  api?.expand?.('focus')
  const files = e.clipboardData?.files
  if (files?.length && pathsFromDataTransfer(files).length) {
    e.preventDefault()
    void dropFiles(files)
    return
  }
  const text = e.clipboardData?.getData('text/plain') ?? ''
  if (!text) return
  e.preventDefault()
  void dropText(text)
})

box.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') {
    e.preventDefault()
    if (!box.value) return
    void dropText(box.value)
  }
})

document.addEventListener('keydown', (e) => {
  if (e.key !== 'Escape') return
  e.preventDefault()
  box.value = ''
  hint.classList.remove('err')
  window.clearTimeout(errTimer)
  errTimer = 0
  void showStack([])
  api?.collapse?.()
})

function through(on: boolean): void {
  if (document.documentElement.classList.contains('mac')) {
    if (pass !== false) {
      pass = false
      api?.setClickThrough?.(false)
    }
    return
  }
  if (!api?.setClickThrough || on === pass) return
  pass = on
  api.setClickThrough(on)
}

function apply(): void {
  if (document.documentElement.classList.contains('mac')) {
    through(false)
    return
  }
  through(mode === 'idle' && !over && !dragging && !focused)
}

function dragHot(): void {
  const first = !dragging
  dragging = true
  through(false)
  if (mode !== 'hot') setMode('hot')
  if (!lastLabel) box.placeholder = 'Drop'
  if (first) api?.expand?.('drag')
}

function dragEnded(shouldCollapse: boolean): void {
  dragDepth = 0
  dragging = false
  if (shouldCollapse && !focused) api?.collapse?.()
  apply()
}

document.addEventListener('dragenter', (e) => {
  e.preventDefault()
  window.clearTimeout(leaveTimer)
  dragDepth++
  dragHot()
  const paths = pathsFromDataTransfer(e.dataTransfer?.files ?? null, e.dataTransfer?.items)
  if (paths.length) void showStack(paths)
})

document.addEventListener('dragover', (e) => {
  e.preventDefault()
  if (e.dataTransfer) e.dataTransfer.dropEffect = 'copy'
  window.clearTimeout(leaveTimer)
  dragHot()
})

document.addEventListener('dragleave', (e) => {
  dragDepth = Math.max(0, dragDepth - 1)
  const next = e.relatedTarget as Node | null
  const left = !next || !document.documentElement.contains(next)
  if (!left && dragDepth > 0) return
  window.clearTimeout(leaveTimer)
  leaveTimer = window.setTimeout(() => {
    if (dragging && !focused) {
      void showStack([])
      dragEnded(true)
    } else {
      dragging = false
      apply()
    }
  }, 40)
})

document.addEventListener('dragend', () => {
  window.clearTimeout(leaveTimer)
  void showStack([])
  dragEnded(!focused)
})

document.addEventListener('drop', (e) => {
  e.preventDefault()
  window.clearTimeout(leaveTimer)
  dragDepth = 0
  dragging = false
  through(false)
  const files = e.dataTransfer?.files
  const items = e.dataTransfer?.items
  if (pathsFromDataTransfer(files, items).length) {
    void dropFiles(files, items)
    return
  }
  if (!focused) api?.collapse?.()
  else apply()
})

bar.addEventListener('click', () => {
  api?.expand?.('focus')
  box.focus({ preventScroll: true })
})

box.addEventListener('focus', () => {
  focused = true
  through(false)
  if (mode === 'idle') api?.expand?.('focus')
})

box.addEventListener('blur', () => {
  focused = false
  if (!dragging && !over) api?.collapse?.()
  apply()
})

function armHover(): void {
  over = true
  window.clearTimeout(leaveTimer)
  if (mode === 'idle') api?.expand?.('hover')
  apply()
}

function disarmHover(): void {
  over = false
  apply()
  if (focused || dragging || mode === 'busy' || mode === 'hot') return
  window.clearTimeout(leaveTimer)
  leaveTimer = window.setTimeout(() => {
    if (!over && !focused && !dragging && mode !== 'busy') api?.collapse?.()
  }, 240)
}

document.documentElement.addEventListener('pointerenter', armHover)
document.documentElement.addEventListener('pointerleave', disarmHover)
document.addEventListener('pointermove', armHover)
document.addEventListener('pointerdown', (e) => {
  const t = e.target as HTMLElement | null
  if (t?.closest?.('.chip')) return
  over = true
  api?.expand?.('focus')
  box.focus({ preventScroll: true })
})

apply()
