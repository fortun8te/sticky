import {
  app,
  BrowserWindow,
  Tray,
  Menu,
  globalShortcut,
  ipcMain,
  nativeImage,
  powerMonitor,
  screen,
  systemPreferences
} from 'electron'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { watch } from 'chokidar'
import { HistoryStore, makeFileClip, makeTextClip } from './history'
import { resolveSyncDir, syncHistoryFile } from './sync'
import { writeFiles, writePlainText } from './clipboard'
import { injectPaste, pollLastTarget, refreshMacTarget, type LastTarget } from './inject'
import { StickyPeer, flyFor, type IncomingDrop } from './peer'
import { applyAutostart, autostartEnabled, ensureAutostart } from './autostart'
import {
  MAC_HIT_W,
  MAC_IDLE_HIT_H,
  MAC_OPEN_DROP_H,
  macNotchPad,
  placeNotchWindow
} from './notch'
import { haptic } from './haptic'
import { filePreviews } from './icons'
import type { ExpandReason, IslandMode, StickyStatus } from '../shared/types'

const WIN_IDLE_W = 180
const WIN_IDLE_H = 48
const WIN_OPEN_W = 352
const WIN_OPEN_H = 76
const BAR_GAP = 26
const FX_MS = 1600
const SEND_COLLAPSE_MS = 1600
const RECV_COLLAPSE_MS = 1700
const BLUR_COLLAPSE_MS = 900
const HOVER_COLLAPSE_MS = 240

const isMac = process.platform === 'darwin'
const isWin = process.platform === 'win32'
const device = isWin ? 'windows' : isMac ? 'macos' : 'linux'

const TRAY_PNG_32 =
  'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAWklEQVR42u3WwQkAIAxDUVfo/mMKetQJFFstFfoDPeedNKUQchgRGZp7XtpbVd01xlK6w4SVmxC5AR7lKgQAAABu3/3VAQDg+h88X0kAtAi3hRo6Sr+Y6SRFJnD6+eYovGQAAAAAElFTkSuQmCC'
const TRAY_PNG_16 =
  'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAOklEQVR42mNgGJRAUFDwPzZMtMbv3z5jxQQNwqcZ2RCyNeM1ZPAagB4Tg9gAXIaQlKAoTkgUJ+UBAQBdnVTwrtMF8wAAAABJRU5ErkJggg=='

let win: BrowserWindow | null = null
let fx: BrowserWindow | null = null
let tray: Tray | null = null
let lastTarget: LastTarget | null = null
let store: HistoryStore
let peer: StickyPeer | null = null
let fxTimer: ReturnType<typeof setTimeout> | null = null
let collapseTimer: ReturnType<typeof setTimeout> | null = null
let quitting = false
let island: IslandMode = 'idle'
let islandLabel = ''
let islandReason: ExpandReason | 'busy' | '' = ''

function historyPath(): string {
  const syncDir = resolveSyncDir()
  const fallback = join(app.getPath('userData'), 'history.json')
  return syncHistoryFile(syncDir, fallback)
}

function posPath(): string {
  return join(app.getPath('userData'), 'pos.json')
}

function macLaptopDisplay(): Electron.Display {
  return screen.getAllDisplays().find((d) => d.internal) ?? screen.getPrimaryDisplay()
}

function islandExpanded(mode: IslandMode = island): boolean {
  return mode !== 'idle'
}

function macIslandSize(mode: IslandMode = island): { width: number; dropH: number } {
  return islandExpanded(mode)
    ? { width: MAC_HIT_W, dropH: MAC_OPEN_DROP_H }
    : { width: MAC_HIT_W, dropH: MAC_IDLE_HIT_H }
}

function winIslandSize(mode: IslandMode = island): { width: number; height: number } {
  return islandExpanded(mode)
    ? { width: WIN_OPEN_W, height: WIN_OPEN_H }
    : { width: WIN_IDLE_W, height: WIN_IDLE_H }
}

function defaultBarPos(display = isMac ? macLaptopDisplay() : screen.getPrimaryDisplay()): {
  x: number
  y: number
} {
  if (isMac) {
    const b = display.bounds
    return {
      x: Math.round(b.x + (b.width - MAC_HIT_W) / 2),
      y: b.y
    }
  }
  const wa = display.workArea
  return {
    x: Math.round(wa.x + (wa.width - WIN_IDLE_W) / 2),
    y: Math.round(wa.y + wa.height - WIN_IDLE_H - BAR_GAP)
  }
}

function loadBarPos(): { x: number; y: number } {
  if (isMac) return defaultBarPos()
  const fallback = defaultBarPos()
  try {
    const file = posPath()
    if (!existsSync(file)) return fallback
    const parsed = JSON.parse(readFileSync(file, 'utf8')) as { x?: unknown; y?: unknown }
    if (typeof parsed.x !== 'number' || typeof parsed.y !== 'number') return fallback
    const saved = { x: Math.round(parsed.x), y: Math.round(parsed.y) }
    const display = screen.getDisplayMatching({
      x: saved.x,
      y: saved.y,
      width: WIN_OPEN_W,
      height: WIN_OPEN_H
    })
    const b = display.workArea
    const onScreen =
      saved.x + WIN_IDLE_W > b.x &&
      saved.x < b.x + b.width &&
      saved.y + WIN_IDLE_H > b.y &&
      saved.y < b.y + b.height
    if (!onScreen) return defaultBarPos(display)
    return saved
  } catch {
    return fallback
  }
}

function saveBarPos(): void {
  if (!win || win.isDestroyed()) return
  const [x, y] = win.getPosition()
  try {
    writeFileSync(posPath(), JSON.stringify({ x, y }))
  } catch {
    /* ignore */
  }
}

function status(): StickyStatus {
  const syncDir = resolveSyncDir()
  const other = peer?.other() ?? null
  return {
    lastApp: lastTarget?.title ?? 'Click a field first',
    syncPath: syncDir,
    syncOk: Boolean(syncDir),
    platform: process.platform,
    canInject: Boolean(lastTarget),
    peer: other ? { name: other.name, role: other.role } : null,
    fly: flyFor('send'),
    island,
    label: islandLabel
  }
}

function emit(): void {
  if (!win || win.isDestroyed()) return
  win.webContents.send('sticky:history', store.read())
  win.webContents.send('sticky:status', status())
}

function emitIsland(): void {
  if (!win || win.isDestroyed()) return
  win.webContents.send('sticky:island', {
    mode: island,
    label: islandLabel,
    reason: islandReason === 'busy' ? undefined : islandReason || undefined
  })
}

function dropLabel(kind: 'text' | 'files', text?: string, files?: string[]): string {
  if (kind === 'files') {
    const names = (files ?? []).map((f) => f.replace(/^.*[/\\]/, ''))
    if (!names.length) return 'Files'
    const first = names[0] ?? 'Files'
    return names.length === 1 ? first : `${first} +${names.length - 1}`
  }
  const t = (text ?? '').replace(/\s+/g, ' ').trim()
  if (!t) return 'Text'
  return t.length > 72 ? `${t.slice(0, 72)}…` : t
}

function inboundLabel(payload: IncomingDrop): string {
  if (payload.kind === 'files' && payload.files?.length) {
    return `${dropLabel('files', undefined, payload.files)} · Downloads/Sticky`
  }
  return dropLabel('text', payload.text)
}

function fireHandoff(kind: 'send' | 'recv', label: string): void {
  const fly = flyFor(kind)
  if (win && !win.isDestroyed()) {
    win.webContents.send('sticky:handoff', { kind, fly, label })
  }
  haptic(kind === 'recv' ? 'catch' : 'drop')
  playFx(kind)
}

function barDisplay(): Electron.Display {
  if (!win || win.isDestroyed()) return screen.getPrimaryDisplay()
  return screen.getDisplayMatching(win.getBounds())
}

function fxSrc(): { dev: string; file: string } {
  const file = join(__dirname, '../renderer/fx.html')
  const base = (process.env.ELECTRON_RENDERER_URL ?? '').replace(/\/$/, '')
  return { dev: base ? `${base}/fx.html` : '', file }
}

function loadFx(): Promise<void> {
  if (!fx || fx.isDestroyed()) return Promise.resolve()
  const src = fxSrc()
  if (src.dev) return fx.loadURL(src.dev).then(() => undefined)
  return fx.loadFile(src.file).then(() => undefined)
}

function keepFxClickThrough(): void {
  if (!fx || fx.isDestroyed()) return
  fx.setIgnoreMouseEvents(true)
  try {
    fx.setAlwaysOnTop(true, 'screen-saver')
  } catch {
    fx.setAlwaysOnTop(true, 'floating')
  }
}

function createFxWindow(): void {
  if (fx && !fx.isDestroyed()) return
  const bounds = barDisplay().bounds
  fx = new BrowserWindow({
    x: bounds.x,
    y: bounds.y,
    width: bounds.width,
    height: bounds.height,
    frame: false,
    transparent: true,
    resizable: false,
    movable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: true,
    alwaysOnTop: true,
    skipTaskbar: true,
    show: false,
    focusable: false,
    hasShadow: false,
    roundedCorners: false,
    backgroundColor: '#00000000',
    title: 'Sticky FX',
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      backgroundThrottling: true
    }
  })
  keepFxClickThrough()
  fx.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true })
  fx.on('closed', () => {
    fx = null
  })
  void loadFx()
}

function playFx(kind: 'send' | 'recv'): void {
  createFxWindow()
  if (!fx || fx.isDestroyed()) return
  const bounds = barDisplay().bounds
  fx.setBounds(bounds)
  keepFxClickThrough()
  const fly = flyFor(kind)
  const run = () => {
    if (!fx || fx.isDestroyed()) return
    keepFxClickThrough()
    fx.showInactive()
    keepFxClickThrough()
    void fx.webContents.executeJavaScript(`play(${JSON.stringify(fly)}, ${JSON.stringify(kind)})`)
    if (fxTimer) clearTimeout(fxTimer)
    fxTimer = setTimeout(() => {
      fxTimer = null
      if (!fx || fx.isDestroyed()) return
      fx.hide()
      fx.destroy()
      fx = null
    }, FX_MS)
  }
  if (fx.webContents.isLoading()) {
    fx.webContents.once('did-finish-load', run)
  } else {
    run()
  }
}

function floatBar(): void {
  if (!win || win.isDestroyed()) return
  try {
    win.setAlwaysOnTop(true, isMac ? 'screen-saver' : 'floating')
  } catch {
    try {
      win.setAlwaysOnTop(true, isMac ? 'pop-up-menu' : 'floating')
    } catch {
      win.setAlwaysOnTop(true)
    }
  }
}

function cancelCollapse(): void {
  if (!collapseTimer) return
  clearTimeout(collapseTimer)
  collapseTimer = null
}

function scheduleCollapse(ms: number): void {
  cancelCollapse()
  collapseTimer = setTimeout(() => {
    collapseTimer = null
    layoutIsland('idle', { animate: true, label: '' })
  }, ms)
}

function cursorOverWin(slop = 0): boolean {
  if (!win || win.isDestroyed() || !win.isVisible()) return false
  const p = screen.getCursorScreenPoint()
  const b = win.getBounds()
  return (
    p.x >= b.x - slop &&
    p.x < b.x + b.width + slop &&
    p.y >= b.y - slop &&
    p.y < b.y + b.height + slop
  )
}

function tickHover(): void {
  if (!isMac || !win || win.isDestroyed()) return
  if (island === 'busy' || island === 'hot') return
  if (cursorOverWin(island === 'idle' ? 0 : 8)) {
    cancelCollapse()
    if (island === 'idle') layoutIsland('open', { animate: true, reason: 'hover', silent: true })
    return
  }
  if (island === 'open' && islandReason === 'hover' && !win.isFocused()) {
    if (!collapseTimer) scheduleCollapse(HOVER_COLLAPSE_MS)
  }
}

let snapping = false

function layoutIsland(
  mode: IslandMode,
  opts?: { animate?: boolean; label?: string; reason?: ExpandReason | 'busy'; silent?: boolean }
): void {
  if (!win || win.isDestroyed()) return
  const prev = island
  island = mode
  if (mode === 'idle') {
    islandLabel = opts?.label ?? ''
    islandReason = ''
  } else if (opts?.label !== undefined) {
    islandLabel = opts.label
  }
  if (mode === 'busy') islandReason = 'busy'
  else if (opts?.reason) islandReason = opts.reason
  const silent = Boolean(opts?.silent) || opts?.reason === 'hover'
  if (prev === 'idle' && mode !== 'idle' && mode !== 'busy' && !silent) haptic('tick')
  const animate = Boolean(opts?.animate) && isMac
  floatBar()
  if (isMac) {
    const display = macLaptopDisplay()
    const { width, dropH } = macIslandSize(mode)
    snapping = true
    try {
      const pad = placeNotchWindow(win, display, width, dropH, animate)
      try {
        win.webContents.insertCSS(`:root { --notch-pad: ${pad}px; }`)
      } catch {
        /* not loaded yet */
      }
    } finally {
      snapping = false
    }
  } else {
    const { width, height } = winIslandSize(mode)
    const display = screen.getDisplayMatching(win.getBounds())
    const wa = display.workArea
    const x = Math.round(wa.x + (wa.width - width) / 2)
    const y = Math.round(wa.y + wa.height - height - BAR_GAP)
    try {
      win.setMinimumSize(WIN_IDLE_W, WIN_IDLE_H)
      win.setMaximumSize(WIN_OPEN_W, WIN_OPEN_H)
    } catch {
      /* ignore */
    }
    win.setMovable(mode !== 'idle')
    win.setBounds({ x, y, width, height })
  }
  emitIsland()
  emit()
}

function snapMacNotch(): void {
  if (!isMac || !win || win.isDestroyed()) return
  layoutIsland(island)
}

async function sendPeer(kind: 'text' | 'files', text?: string, paths?: string[]): Promise<boolean> {
  if (!peer?.other()) return false
  try {
    return (await peer.send({ kind, text, paths })) === true
  } catch {
    return false
  }
}

function sendMiss(kind: 'text' | 'files'): string {
  if (peer?.other()) return 'PC missed the drop — try again'
  return kind === 'files' ? 'Copied here. PC is offline' : 'Copied here. PC is offline'
}

async function dropText(text: string): Promise<{ ok: boolean; message: string }> {
  const clip = makeTextClip(text, device)
  if (!clip) return { ok: false, message: 'Nothing to drop' }
  const label = dropLabel('text', clip.text)
  try {
    layoutIsland('busy', { animate: true, label })
    await writePlainText(clip.text ?? '')
    store.upsert(clip)
    const injected = await injectPaste(win, lastTarget)
    floatBar()
    snapMacNotch()
    fireHandoff('send', label)
    const sent = await sendPeer('text', clip.text)
    emit()
    scheduleCollapse(SEND_COLLAPSE_MS)
    if (!sent) return { ok: true, message: sendMiss('text') }
    return {
      ok: true,
      message: injected ? `Dropped into ${lastTarget?.title}` : 'Copied — click a field, paste again'
    }
  } catch (err) {
    layoutIsland('idle', { animate: true, label: '' })
    return { ok: false, message: err instanceof Error ? err.message : 'Drop failed' }
  }
}

async function dropFiles(paths: string[]): Promise<{ ok: boolean; message: string }> {
  const clip = makeFileClip(paths, device)
  if (!clip) return { ok: false, message: 'No files' }
  const label = dropLabel('files', undefined, clip.files)
  try {
    layoutIsland('busy', { animate: true, label })
    await writeFiles(clip.files ?? [])
    store.upsert(clip)
    const injected = await injectPaste(win, lastTarget)
    floatBar()
    snapMacNotch()
    fireHandoff('send', label)
    const sent = await sendPeer('files', undefined, clip.files)
    emit()
    scheduleCollapse(SEND_COLLAPSE_MS)
    if (!sent) return { ok: true, message: sendMiss('files') }
    return {
      ok: true,
      message: injected
        ? `Files dropped into ${lastTarget?.title}`
        : 'On the PC · Downloads/Sticky'
    }
  } catch (err) {
    layoutIsland('idle', { animate: true, label: '' })
    return { ok: false, message: err instanceof Error ? err.message : 'File drop failed' }
  }
}

async function receiveDrop(payload: IncomingDrop): Promise<void> {
  const files = payload.kind === 'files' ? (payload.files ?? []) : []
  const text = payload.text ?? ''
  if (!files.length && !text) return
  const label = inboundLabel(payload)
  layoutIsland('busy', { animate: true, label })
  try {
    if (files.length) {
      await writeFiles(files)
      await injectPaste(win, lastTarget)
      floatBar()
      snapMacNotch()
      const clip = makeFileClip(files, device)
      if (clip) store.upsert(clip)
      fireHandoff('recv', dropLabel('files', undefined, files))
    } else {
      await writePlainText(text)
      await injectPaste(win, lastTarget)
      floatBar()
      snapMacNotch()
      const clip = makeTextClip(text, device)
      if (clip) store.upsert(clip)
      fireHandoff('recv', dropLabel('text', text))
    }
    emit()
  } catch {
    /* inbound drop failed */
  }
  scheduleCollapse(RECV_COLLAPSE_MS)
}

function createWindow(): void {
  const pos = loadBarPos()
  const macDisplay = isMac ? macLaptopDisplay() : null
  const idleW = isMac ? MAC_HIT_W : WIN_IDLE_W
  const idleH = isMac && macDisplay ? macNotchPad(macDisplay) + MAC_IDLE_HIT_H : WIN_IDLE_H
  win = new BrowserWindow({
    width: idleW,
    height: idleH,
    x: pos.x,
    y: isMac && macDisplay ? macDisplay.bounds.y : pos.y,
    frame: false,
    transparent: true,
    resizable: false,
    movable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    show: true,
    hasShadow: false,
    roundedCorners: false,
    enableLargerThanScreen: isMac,
    type: isMac ? 'panel' : 'normal',
    acceptFirstMouse: true,
    backgroundColor: '#00000000',
    title: 'Sticky',
    webPreferences: {
      preload: existsSync(join(__dirname, '../preload/index.mjs'))
        ? join(__dirname, '../preload/index.mjs')
        : join(__dirname, '../preload/index.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      backgroundThrottling: false
    }
  })

  floatBar()
  win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true })
  if (isMac) {
    win.setWindowButtonVisibility(false)
    win.setIgnoreMouseEvents(false)
    try {
      win.setHiddenInMissionControl(true)
    } catch {
      /* older electron */
    }
  } else {
    win.setIgnoreMouseEvents(false, { forward: true })
  }

  if (process.env.ELECTRON_RENDERER_URL) {
    win.loadURL(process.env.ELECTRON_RENDERER_URL)
  } else {
    win.loadFile(join(__dirname, '../renderer/index.html'))
  }

  layoutIsland('idle')
  win.once('ready-to-show', () => {
    layoutIsland(island)
    win?.showInactive()
  })
  win.webContents.once('did-finish-load', () => layoutIsland(island))

  win.on('moved', () => {
    if (isMac) {
      if (!snapping) snapMacNotch()
      return
    }
    saveBarPos()
  })

  win.on('blur', () => {
    lastTarget = pollLastTarget(win, lastTarget)
    emit()
    if (island === 'open' && !cursorOverWin()) scheduleCollapse(BLUR_COLLAPSE_MS)
  })

  win.on('close', (e) => {
    saveBarPos()
    if (quitting || !tray) return
    e.preventDefault()
    hideSticky()
  })
}

function trayIcon(): Electron.NativeImage {
  const files = [
    join(__dirname, '../../resources/tray.png'),
    join(process.resourcesPath, 'resources', 'tray.png')
  ]
  for (const file of files) {
    try {
      if (!existsSync(file)) continue
      const img = nativeImage.createFromPath(file)
      if (img.isEmpty()) continue
      const small = file.replace(/tray\.png$/i, 'tray-16.png')
      if (existsSync(small)) {
        img.addRepresentation({ width: 16, height: 16, buffer: readFileSync(small) })
      }
      return img
    } catch {
      /* next */
    }
  }
  const img = nativeImage.createFromBuffer(Buffer.from(TRAY_PNG_32, 'base64'))
  img.addRepresentation({ width: 16, height: 16, buffer: Buffer.from(TRAY_PNG_16, 'base64') })
  return img
}

function showSticky(): void {
  if (!win || win.isDestroyed()) {
    createWindow()
  }
  if (!win || win.isDestroyed()) return
  cancelCollapse()
  layoutIsland('open', { animate: true, reason: 'hotkey' })
  win.show()
  win.focus()
}

function hideSticky(): void {
  cancelCollapse()
  layoutIsland('idle', { animate: true, label: '' })
}

function paintTray(): void {
  if (!tray) return
  tray.setContextMenu(
    Menu.buildFromTemplate([
      { label: 'Show Sticky', click: () => showSticky() },
      {
        label: 'Open at login',
        type: 'checkbox',
        checked: autostartEnabled(),
        click: (item) => {
          applyAutostart(item.checked)
          paintTray()
        }
      },
      { type: 'separator' },
      {
        label: 'Quit Sticky',
        click: () => {
          quitting = true
          app.quit()
        }
      }
    ])
  )
}

function createTray(): void {
  try {
    const img = trayIcon()
    const icon = img.isEmpty() ? nativeImage.createFromBuffer(Buffer.from(TRAY_PNG_32, 'base64')) : img
    tray = new Tray(icon)
    if (isMac) tray.setTitle('S')
    tray.setToolTip('Sticky')
    paintTray()
    tray.on('click', () => showSticky())
  } catch {
    tray = null
  }
}

function wireIpc(): void {
  ipcMain.handle('sticky:dropText', (_e, text: string) => dropText(String(text ?? '')))
  ipcMain.handle('sticky:dropFiles', (_e, paths: string[]) => dropFiles(Array.isArray(paths) ? paths : []))
  ipcMain.handle('sticky:getHistory', () => store.read())
  ipcMain.handle('sticky:getStatus', () => status())
  ipcMain.handle('sticky:pasteItem', async (_e, id: string) => {
    const item = store.read().find((i) => i.id === id)
    if (!item) return { ok: false, message: 'Gone' }
    if (item.type === 'files') return dropFiles(item.files ?? [])
    return dropText(item.text ?? '')
  })
  ipcMain.handle('sticky:pinItem', (_e, id: string) => {
    store.pin(id)
    emit()
  })
  ipcMain.handle('sticky:deleteItem', (_e, id: string) => {
    store.remove(id)
    emit()
  })
  ipcMain.handle('sticky:clearHistory', () => {
    store.clear()
    emit()
  })
  ipcMain.handle('sticky:fileIcons', (_e, paths: string[]) =>
    filePreviews(Array.isArray(paths) ? paths : [])
  )
  ipcMain.on('sticky:hide', () => hideSticky())
  ipcMain.on('sticky:haptic', (_e, kind: string) => {
    if (kind === 'tick' || kind === 'drop' || kind === 'catch') haptic(kind)
  })
  ipcMain.on('sticky:expand', (_e, reason?: ExpandReason) => {
    const why: ExpandReason = reason ?? 'focus'
    cancelCollapse()
    layoutIsland(why === 'drag' ? 'hot' : 'open', { animate: true, reason: why })
    if (why === 'focus' || why === 'hotkey') win?.focus()
  })
  ipcMain.on('sticky:collapse', () => {
    if (island === 'busy') return
    cancelCollapse()
    layoutIsland('idle', { animate: true, label: '' })
  })
  ipcMain.on('sticky:clickThrough', (_e, on: boolean) => {
    if (!win || win.isDestroyed() || isMac) return
    win.setIgnoreMouseEvents(Boolean(on), { forward: true })
  })
}

if (isWin) app.setAppUserModelId('app.sticky.drop')
app.setName('Sticky')

const locked = app.requestSingleInstanceLock()
if (!locked) {
  app.quit()
} else {
  app.on('second-instance', () => showSticky())
}

app.whenReady().then(() => {
  if (!locked) return
  if (isMac) {
    app.dock?.hide()
    try {
      app.setActivationPolicy('accessory')
    } catch {
      /* older electron */
    }
    try {
      systemPreferences.isTrustedAccessibilityClient(true)
    } catch {
      /* prompt if we can */
    }
  }
  store = new HistoryStore(historyPath())
  peer = new StickyPeer((payload) => {
    void receiveDrop(payload)
  })
  peer.start()
  createWindow()
  createTray()
  wireIpc()
  ensureAutostart()
  paintTray()
  setInterval(tickHover, 40)

  globalShortcut.register(isMac ? 'Command+Shift+V' : 'Control+Shift+V', () => {
    showSticky()
  })

  screen.on('display-metrics-changed', () => {
    layoutIsland(island)
  })

  powerMonitor.on('suspend', () => peer?.sleep())
  powerMonitor.on('resume', () => {
    peer?.wake()
    layoutIsland(island)
  })

  let lastEmit = ''
  setInterval(async () => {
    try {
      lastTarget = pollLastTarget(win, lastTarget)
      if (isMac) lastTarget = await refreshMacTarget(lastTarget)
      const sig = JSON.stringify({
        last: lastTarget,
        hist: store.read().map((i) => i.id + String(i.pinned)),
        peer: peer?.other()?.id ?? null
      })
      if (sig !== lastEmit) {
        lastEmit = sig
        emit()
      }
    } catch {
      /* keep polling */
    }
  }, 2000)

  const file = historyPath()
  watch(file, { ignoreInitial: true, usePolling: false }).on('change', () => emit())

  app.on('activate', () => {
    if (!win || win.isDestroyed()) createWindow()
    else showSticky()
  })
})

app.on('before-quit', () => {
  quitting = true
  peer?.stop()
  peer = null
})

app.on('window-all-closed', () => {
  if (quitting) app.quit()
})

app.on('will-quit', () => {
  globalShortcut.unregisterAll()
  if (fxTimer) clearTimeout(fxTimer)
  cancelCollapse()
  peer?.stop()
})
