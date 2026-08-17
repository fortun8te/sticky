const bar = document.querySelector('#bar') as HTMLElement
const box = document.querySelector('#box') as HTMLInputElement
const send = document.querySelector('#send') as HTMLButtonElement
const peer = document.querySelector('#peer') as HTMLElement | null
const api = window.sticky

function paint(s?: { platform?: string; peer?: unknown } | null): void {
  const mac = s?.platform === 'darwin'
  document.documentElement.classList.toggle('mac', mac)
  document.documentElement.classList.toggle('win', !mac)
  if (peer) peer.hidden = !s?.peer
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
  }, 1000)
})

function paths(list?: FileList | File[] | null): string[] {
  if (!list?.length || !api?.pathForFile) return []
  return [...list].map((f) => api.pathForFile(f)).filter(Boolean)
}

async function dropText(text: string): Promise<void> {
  box.value = ''
  if (!text || !api?.dropText) return
  await api.dropText(text)
}

async function dropFiles(list?: FileList | File[] | null): Promise<void> {
  box.value = ''
  const files = paths(list)
  if (!files.length || !api?.dropFiles) return
  await api.dropFiles(files)
}

box.addEventListener('paste', (e) => {
  const files = e.clipboardData?.files
  if (files?.length && paths(files).length) {
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

document.addEventListener('dragover', (e) => {
  e.preventDefault()
  bar.classList.add('hot')
})

document.addEventListener('dragleave', (e) => {
  if (!e.relatedTarget) bar.classList.remove('hot')
})

document.addEventListener('drop', (e) => {
  e.preventDefault()
  bar.classList.remove('hot')
  void dropFiles(e.dataTransfer?.files)
})

let focused = false
let over = false
let pass = true

function through(on: boolean): void {
  if (!api?.setClickThrough || on === pass) return
  pass = on
  api.setClickThrough(on)
}

function apply(): void {
  through(!(focused || over))
}

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

through(true)
