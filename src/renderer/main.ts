import type { ClipItem, StickyStatus } from '../shared/types'
import { previewText } from '../shared/types'

const box = document.querySelector('#box') as HTMLTextAreaElement
const list = document.querySelector('#list') as HTMLUListElement
const statusLine = document.querySelector('#statusLine') as HTMLElement
const statusApp = document.querySelector('#statusApp') as HTMLElement
const statusSync = document.querySelector('#statusSync') as HTMLElement
const dropZone = document.querySelector('#dropZone') as HTMLElement
const sendBtn = document.querySelector('#sendBtn') as HTMLButtonElement
const clearBtn = document.querySelector('#clearBtn') as HTMLButtonElement
const minBtn = document.querySelector('#minBtn') as HTMLButtonElement
const closeBtn = document.querySelector('#closeBtn') as HTMLButtonElement

let lastItems: ClipItem[] = []
let dragDepth = 0

function deviceLabel(device: ClipItem['device']): string {
  if (device === 'macos') return 'Mac'
  if (device === 'windows') return 'Windows'
  if (device === 'linux') return 'Linux'
  return ''
}

function syncSend(): void {
  sendBtn.disabled = !box.value.trim()
}

function setHot(on: boolean): void {
  dropZone.classList.toggle('hot', on)
}

function setStatus(text: string, kind: 'ok' | 'err' | '' = ''): void {
  statusApp.textContent = text
  statusLine.classList.remove('ok', 'err')
  if (kind) statusLine.classList.add(kind)
}

function fromStatus(s: StickyStatus): void {
  const target = s.canInject ? s.lastApp : 'Click a field'
  statusApp.textContent = target
  statusSync.textContent = s.syncOk ? 'iCloud' : 'This device'
  statusSync.classList.toggle('on', s.syncOk)
  statusLine.classList.toggle('live', s.canInject)
  statusLine.classList.remove('ok', 'err')
}

function render(items: ClipItem[]): void {
  lastItems = items
  clearBtn.hidden = items.length === 0
  if (!items.length) {
    list.innerHTML = `<li class="empty"><p>Nothing here yet</p><small>Paste or drop a file. Later, 1–9 sends a clip.</small></li>`
    return
  }
  list.innerHTML = items
    .map((item, i) => {
      const kind = item.type === 'files' ? 'File' : 'Text'
      const device = deviceLabel(item.device)
      const when = new Date(item.createdAt).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })
      const preview = escapeHtml(previewText(item, 64) || 'Empty')
      const idx = i < 9 ? String(i + 1) : ''
      return `<li class="row ${item.pinned ? 'pinned' : ''} ${item.type}" data-id="${item.id}" tabindex="0" title="${preview}">
        <b class="idx">${idx}</b>
        <div>
          <p>${preview}</p>
          <div class="meta">
            <span class="tag ${item.type === 'files' ? 'file' : 'text'}">${kind}</span>
            ${device ? `<span class="tag">${device}</span>` : ''}
            <time>${when}</time>
          </div>
        </div>
        <div class="row-actions">
          <button class="row-btn pin" title="Pin" type="button" aria-label="${item.pinned ? 'Unpin' : 'Pin'}">${item.pinned ? '★' : '☆'}</button>
          <button class="row-btn del" title="Remove" type="button" aria-label="Remove">✕</button>
        </div>
      </li>`
    })
    .join('')
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c] as string)
}

async function sendText(text: string): Promise<void> {
  const body = text.trimEnd()
  if (!body) return
  const res = await window.sticky.dropText(body)
  box.value = ''
  syncSend()
  setStatus(res.message, res.ok ? 'ok' : 'err')
}

async function sendFiles(paths: string[]): Promise<void> {
  if (!paths.length) return
  const res = await window.sticky.dropFiles(paths)
  setStatus(res.message, res.ok ? 'ok' : 'err')
}

function filesFromList(files: FileList | File[]): string[] {
  return [...files].map((f) => window.sticky.pathForFile(f)).filter(Boolean)
}

box.addEventListener('paste', (e) => {
  e.preventDefault()
  const files = filesFromList(e.clipboardData?.files ?? [])
  if (files.length) {
    void sendFiles(files)
    return
  }
  const text = e.clipboardData?.getData('text/plain') ?? ''
  void sendText(text)
})

box.addEventListener('input', syncSend)
box.addEventListener('focus', () => dropZone.classList.add('focus'))
box.addEventListener('blur', () => dropZone.classList.remove('focus'))

box.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault()
    void sendText(box.value)
  }
})

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    box.value = ''
    syncSend()
    return
  }
  if (e.metaKey || e.ctrlKey || e.altKey) return
  if (e.key < '1' || e.key > '9') return
  if (document.activeElement === box && box.value.length > 0) return
  const item = lastItems[Number(e.key) - 1]
  if (!item) return
  e.preventDefault()
  void window.sticky.pasteItem(item.id)
})

sendBtn.addEventListener('click', () => void sendText(box.value))
clearBtn.addEventListener('click', () => void window.sticky.clearHistory())
minBtn.addEventListener('click', () => window.sticky.hide())
closeBtn.addEventListener('click', () => window.sticky.hide())

list.addEventListener('click', (e) => {
  const t = e.target as HTMLElement
  const row = t.closest('.row') as HTMLElement | null
  if (!row) return
  const id = row.dataset.id
  if (!id) return
  if (t.closest('.pin')) {
    void window.sticky.pinItem(id)
    return
  }
  if (t.closest('.del')) {
    void window.sticky.deleteItem(id)
    return
  }
  void window.sticky.pasteItem(id)
})

list.addEventListener('keydown', (e) => {
  if (e.key !== 'Enter' && e.key !== ' ') return
  const t = e.target as HTMLElement
  if (t.closest('.row-btn')) return
  const row = t.closest('.row') as HTMLElement | null
  if (!row?.dataset.id) return
  e.preventDefault()
  void window.sticky.pasteItem(row.dataset.id)
})

document.addEventListener('dragenter', (e) => {
  e.preventDefault()
  dragDepth += 1
  setHot(true)
})
document.addEventListener('dragover', (e) => e.preventDefault())
document.addEventListener('dragleave', (e) => {
  e.preventDefault()
  dragDepth = Math.max(0, dragDepth - 1)
  if (dragDepth === 0) setHot(false)
})
document.addEventListener('drop', (e) => {
  e.preventDefault()
  dragDepth = 0
  setHot(false)
  const files = filesFromList((e as DragEvent).dataTransfer?.files ?? [])
  void sendFiles(files)
})

window.sticky.onHistory(render)
window.sticky.onStatus(fromStatus)
void window.sticky.getHistory().then(render)
void window.sticky.getStatus().then(fromStatus)
syncSend()
box.focus()
