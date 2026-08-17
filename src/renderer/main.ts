const bar = document.querySelector('#bar') as HTMLElement
const box = document.querySelector('#box') as HTMLInputElement
const send = document.querySelector('#send') as HTMLButtonElement
const peer = document.querySelector('#peer') as HTMLElement | null
const api = window.sticky
const DROP_PLACEHOLDER = 'Drop'

function paint(s?: { platform?: string; peer?: unknown } | null): void {
  const mac = s?.platform === 'darwin'
  document.documentElement.classList.toggle('mac', mac)
  document.documentElement.classList.toggle('win', !mac)
  if (peer) peer.hidden = !s?.peer
  if (mac) through(false)
}

void api?.getStatus?.().then(paint)
api?.onStatus?.(paint)

let handoffTimer = 0
api?.onHandoff?.((e) => {
  bar.classList.remove('hand-send', 'hand-recv', 'fly-up', 'fly-down')
  bar.classList.add(e.kind === 'recv' ? 'hand-recv' : 'hand-send', e.fly === 'down' ? 'fly-down' : 'fly-up')
  window.clearTimeout(handoffTimer)
  handoffTimer = window.setTimeout(() => {
    bar.classList.remove('hand-send', 'hand-recv', 'fly-up', 'fly-down')
  }, 1600)
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
      const entry = item.webkitGetAsEntry?.()
      const file = item.getAsFile()
      if (!entry && !file) continue
      add(pathFor(file))
    }
  }

  if (out.length) return out

  if (files?.length) {
    for (const file of files) add(pathFor(file))
  }

  return out
}

let errTimer = 0
function flashErr(message: string): void {
  const msg = message.trim()
  if (!msg) return
  window.clearTimeout(errTimer)
  box.placeholder = msg
  errTimer = window.setTimeout(() => {
    box.placeholder = DROP_PLACEHOLDER
  }, 2200)
}

async function dropText(text: string): Promise<void> {
  box.value = ''
  if (!text || !api?.dropText) return
  const r = await api.dropText(text)
  if (r && r.ok === false && r.message) flashErr(r.message)
}

async function dropFiles(list?: FileList | File[] | null, items?: DataTransferItemList | null): Promise<void> {
  box.value = ''
  const files = pathsFromDataTransfer(list, items)
  if (!files.length || !api?.dropFiles) return
  const r = await api.dropFiles(files)
  if (r && r.ok === false && r.message) flashErr(r.message)
}

box.addEventListener('paste', (e) => {
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
    void dropText(box.value)
  } else if (e.key === 'Escape') {
    e.preventDefault()
    box.value = ''
  }
})

send?.addEventListener('click', () => void dropText(box.value))

let focused = false
let over = false
let pass = true
let dragging = false
let dragDepth = 0

function through(on: boolean): void {
  if (document.documentElement.classList.contains('mac')) {
    if (pass) {
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
  through(!(focused || over || dragging))
}

function dragHot(): void {
  bar.classList.add('hot')
  dragging = true
  through(false)
}

function dragClear(): void {
  dragDepth = 0
  dragging = false
  bar.classList.remove('hot')
  apply()
}

document.addEventListener('dragenter', (e) => {
  e.preventDefault()
  dragDepth++
  dragHot()
})

document.addEventListener('dragover', (e) => {
  e.preventDefault()
  if (e.dataTransfer) e.dataTransfer.dropEffect = 'copy'
  dragHot()
})

document.addEventListener('dragleave', (e) => {
  dragDepth = Math.max(0, dragDepth - 1)
  const next = e.relatedTarget as Node | null
  const left = !next || !document.documentElement.contains(next)
  if (left || dragDepth === 0) dragClear()
})

document.addEventListener('dragend', () => {
  dragClear()
})

document.addEventListener('drop', (e) => {
  e.preventDefault()
  dragClear()
  void dropFiles(e.dataTransfer?.files, e.dataTransfer?.items)
})

box.addEventListener('focus', () => {
  focused = true
  through(false)
})

box.addEventListener('blur', () => {
  focused = false
  apply()
})

document.addEventListener('mousemove', (e) => {
  over = !!(e.target as HTMLElement | null)?.closest?.('#bar')
  apply()
})

through(false)
