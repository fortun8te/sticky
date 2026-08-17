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
import { StickyPeer, flyFor, packFiles, unpackFiles, type DropPayload } from './peer'
import { applyAutostart, autostartEnabled, ensureAutostart } from './autostart'
import type { StickyStatus } from '../shared/types'

const BAR_W = 312
const BAR_H_MAC = 36
const BAR_H_WIN = 52
const BAR_GAP = 14
const FX_MS = 1600

const isMac = process.platform === 'darwin'
const isWin = process.platform === 'win32'
const device = isWin ? 'windows' : isMac ? 'macos' : 'linux'

function barH(): number {
  return isMac ? BAR_H_MAC : BAR_H_WIN
}

const TRAY_PNG_32 =
  'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAWklEQVR42u3WwQkAIAxDUVfo/mMKetQJFFstFfoDPeedNKUQchgRGZp7XtpbVd01xlK6w4SVmxC5AR7lKgQAAABu3/3VAQDg+h88X0kAtAi3kRo6Sr+Y5SRFJnD6O+eYovGQAAAAAElFTkSuQmCC'
const TRAY_PNG_16 =
  'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAOklEQVR42mNgGJRAUFDwPzZMtMbv3z5jxQQNwqcZ2RCyNeM1ZPAagB4Tg9gAXIaQlKAoTkgUJ+UBAQBdnVTwrtMF8wAAAABJRU5ErkJggg=='

let win: BrowserWindow | null = null
let fx: BrowserWindow | null = null
let tray: Tray | null = null
let lastTarget: LastTarget | null = null
let store: HistoryStore
let peer: StickyPeer | null = null
let fxTimer: ReturnType<typeof setTimeout> | null = null
let quitting = false

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

function defaultBarPos(display = isMac ? macLaptopDisplay() : screen.getPrimaryDisplay()): {
  x: number
  y: number
} {
  if (isMac) {
    const b = display.bounds
    return {
      x: Math.round(b.x + (b.width - BAR_W) / 2),
      y: b.y
    }
  }
  const wa = display.workArea
  return {
    x: Math.round(wa.x + (wa.width - BAR_W) / 2),
    y: Math.round(wa.y + wa.height - barH() - BAR_GAP)
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
      width: BAR_W,
      height: barH()
    })
    const b = display.workArea
    const onScreen =
      saved.x + BAR_W > b.x &&
      saved.x < b.x + b.width &&
      saved.y + barH() > b.y &&
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
    fly: flyFor('send')
  }
}

function emit(): void {
  if (!win || win.isDestroyed()) return
  win.webContents.send('sticky:history', store.read())
  win.webContents.send('sticky:status', status())
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

function fireHandoff(kind: 'send' | 'recv', label: string): void {
  const fly = flyFor(kind)
  if (win && !win.isDestroyed()) {
    win.webContents.send('sticky:handoff', { kind, fly, label })
  }
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

function snapMacNotch(): void {
  if (!isMac || !win || win.isDestroyed()) return
  floatBar()
  const pos = defaultBarPos()
  win.setBounds({ x: pos.x, y: pos.y, width: BAR_W, height: barH() })
}

async function sendPeer(kind: 'text' | 'files', text?: string, paths?: string[]): Promise<boolean> {
  if (!peer?.other()) return false
  try {
    const files = paths?.length ? packFiles(paths) : []
    return (await peer.send({ kind, text, files })) === true
  } catch {
    return false
  }
}

async function dropText(text: string): Promise<{ ok: boolean; message: string }> {
  const clip = makeTextClip(text, device)
  if (!clip) return { ok: false, message: 'Nothing to drop' }
  try {
    await writePlainText(clip.text ?? '')
    store.upsert(clip)
    const injected = await injectPaste(win, lastTarget)
    floatBar()
    snapMacNotch()
    const label = dropLabel('text', clip.text)
    void sendPeer('text', clip.text)
    fireHandoff('send', label)
    emit()
    return {
      ok: true,
      message: injected ? `Dropped into ${lastTarget?.title}` : 'Copied — click a field, paste again'
    }
  } catch (err) {
    return { ok: false, message: err instanceof Error ? err.message : 'Drop failed' }
  }
}

async function dropFiles(paths: string[]): Promise<{ ok: boolean; message: string }> {
  const clip = makeFileClip(paths, device)
  if (!clip) return { ok: false, message: 'No files' }
  try {
    await writeFiles(clip.files ?? [])
    store.upsert(clip)
    const injected = await injectPaste(win, lastTarget)
    floatBar()
    snapMacNotch()
    const label = dropLabel('files', undefined, clip.files)
    void sendPeer('files', undefined, clip.files)
    fireHandoff('send', label)
    emit()
    return {
      ok: true,
      message: injected ? `Files dropped into ${lastTarget?.title}` : 'Files copied — click a field, paste again'
    }
  } catch (err) {
    return { ok: false, message: err instanceof Error ? err.message : 'File drop failed' }
  }
}

async function receiveDrop(payload: DropPayload): Promise<void> {
  try {
    if (payload.kind === 'files' && payload.files?.length) {
      const files = unpackFiles(payload.files)
      await writeFiles(files)
      await injectPaste(win, lastTarget)
      floatBar()
      snapMacNotch()
      const clip = makeFileClip(files, device)
      if (clip) store.upsert(clip)
      fireHandoff('recv', dropLabel('files', undefined, files))
    } else {
      const text = payload.text ?? ''
      if (!text) return
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
}

function createWindow(): void {
  const pos = loadBarPos()
  win = new BrowserWindow({
    width: BAR_W,
    height: barH(),
    x: pos.x,
    y: pos.y,
    frame: false,
    transparent: true,
    resizable: false,
    movable: !isMac,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    show: true,
    hasShadow: false,
    roundedCorners: isMac,
    backgroundColor: '#00000000',
    title: 'Sticky',
    webPreferences: {
      preload: existsSync(join(__dirname, '../preload/index.mjs'))
        ? join(__dirname, '../preload/index.mjs')
        : join(__dirname, '../preload/index.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      backgroundThrottling: true
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

  snapMacNotch()
  win.once('ready-to-show', () => {
    snapMacNotch()
    win?.showInactive()
  })
  win.webContents.once('did-finish-load', () => snapMacNotch())

  win.on('moved', () => {
    if (isMac) {
      const pos = defaultBarPos()
      win?.setPosition(pos.x, pos.y)
      return
    }
    saveBarPos()
  })

  win.on('blur', () => {
    lastTarget = pollLastTarget(win, lastTarget)
    emit()
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
    return
  }
  win.show()
  win.focus()
}

function hideSticky(): void {
  win?.hide()
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
  ipcMain.on('sticky:hide', () => hideSticky())
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

  globalShortcut.register(isMac ? 'Command+Shift+V' : 'Control+Shift+V', () => {
    showSticky()
  })

  screen.on('display-metrics-changed', () => {
    snapMacNotch()
  })

  powerMonitor.on('suspend', () => peer?.sleep())
  powerMonitor.on('resume', () => {
    peer?.wake()
    snapMacNotch()
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
  peer?.stop()
})
