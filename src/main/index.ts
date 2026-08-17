import { app, BrowserWindow, Tray, Menu, globalShortcut, ipcMain, nativeImage, screen } from 'electron'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { watch } from 'chokidar'
import { HistoryStore, makeFileClip, makeTextClip } from './history'
import { resolveSyncDir, syncHistoryFile } from './sync'
import { writeFiles, writePlainText, readPlainText } from './clipboard'
import { injectPaste, pollLastTarget, refreshMacTarget, type LastTarget } from './inject'
import type { StickyStatus } from '../shared/types'

const isMac = process.platform === 'darwin'
const isWin = process.platform === 'win32'
const device = isWin ? 'windows' : isMac ? 'macos' : 'linux'

const TRAY_PNG_32 =
  'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAWklEQVR42u3WwQkAIAxDUVfo/mMKetQJFFstFfoDPeedNKUQchgRGZp7XtpbVd01xlK6w4SVmxC5AR7lKgQAAABu3/3VAQDg+h88X0kAtAi3kRo6Sr+Y5SRFJnD6O+eYovGQAAAAAElFTkSuQmCC'
const TRAY_PNG_16 =
  'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAOklEQVR42mNgGJRAUFDwPzZMtMbv3z5jxQQNwqcZ2RCyNeM1ZPAagB4Tg9gAXIaQlKAoTkgUJ+UBAQBdnVTwrtMF8wAAAABJRU5ErkJggg=='

let win: BrowserWindow | null = null
let tray: Tray | null = null
let lastTarget: LastTarget | null = null
let lastClipboard = ''
let store: HistoryStore
let quitting = false

function historyPath(): string {
  const syncDir = resolveSyncDir()
  const fallback = join(app.getPath('userData'), 'history.json')
  return syncHistoryFile(syncDir, fallback)
}

function status(): StickyStatus {
  const syncDir = resolveSyncDir()
  return {
    lastApp: lastTarget?.title ?? 'Click a field first',
    syncPath: syncDir,
    syncOk: Boolean(syncDir),
    platform: process.platform,
    canInject: Boolean(lastTarget)
  }
}

function emit(): void {
  if (!win || win.isDestroyed()) return
  win.webContents.send('sticky:history', store.read())
  win.webContents.send('sticky:status', status())
}

async function dropText(text: string): Promise<{ ok: boolean; message: string }> {
  const clip = makeTextClip(text, device)
  if (!clip) return { ok: false, message: 'Nothing to drop' }
  try {
    await writePlainText(clip.text ?? '')
    store.upsert(clip)
    const injected = await injectPaste(win, lastTarget)
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
    emit()
    return {
      ok: true,
      message: injected ? `Files dropped into ${lastTarget?.title}` : 'Files copied — click a field, paste again'
    }
  } catch (err) {
    return { ok: false, message: err instanceof Error ? err.message : 'File drop failed' }
  }
}

function createWindow(): void {
  const wa = screen.getPrimaryDisplay().workArea
  win = new BrowserWindow({
    width: 392,
    height: 560,
    x: wa.x + wa.width - 392 - 24,
    y: wa.y + wa.height - 560 - 24,
    frame: false,
    transparent: true,
    resizable: true,
    minWidth: 340,
    minHeight: 420,
    alwaysOnTop: true,
    skipTaskbar: false,
    hasShadow: true,
    roundedCorners: true,
    backgroundColor: '#00000000',
    title: 'Sticky',
    webPreferences: {
      preload: existsSync(join(__dirname, '../preload/index.mjs'))
        ? join(__dirname, '../preload/index.mjs')
        : join(__dirname, '../preload/index.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false
    }
  })

  win.setAlwaysOnTop(true, 'floating')
  win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true })
  if (isMac) win.setVibrancy('under-window')

  if (process.env.ELECTRON_RENDERER_URL) {
    win.loadURL(process.env.ELECTRON_RENDERER_URL)
  } else {
    win.loadFile(join(__dirname, '../renderer/index.html'))
  }

  win.on('blur', () => {
    lastTarget = pollLastTarget(win, lastTarget)
    emit()
  })

  win.on('close', (e) => {
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

function createTray(): void {
  try {
    const img = trayIcon()
    const icon = img.isEmpty() ? nativeImage.createFromBuffer(Buffer.from(TRAY_PNG_32, 'base64')) : img
    tray = new Tray(icon)
    if (isMac) tray.setTitle('S')
    tray.setToolTip('Sticky')
    tray.setContextMenu(
      Menu.buildFromTemplate([
        { label: 'Show Sticky', click: () => showSticky() },
        { type: 'separator' },
        {
          label: 'Quit',
          click: () => {
            quitting = true
            app.quit()
          }
        }
      ])
    )
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
}

if (isWin) app.setAppUserModelId('app.sticky.drop')
app.setName('Sticky')

app.whenReady().then(() => {
  store = new HistoryStore(historyPath())
  createWindow()
  createTray()
  wireIpc()
  if (app.isPackaged) {
    app.setLoginItemSettings({ openAtLogin: true, openAsHidden: false })
  }

  globalShortcut.register(isMac ? 'Command+Shift+V' : 'Control+Shift+V', () => {
    showSticky()
  })

  let lastEmit = ''
  setInterval(async () => {
    try {
      lastTarget = pollLastTarget(win, lastTarget)
      if (isMac) lastTarget = await refreshMacTarget(lastTarget)
      const text = readPlainText()
      if (text && text !== lastClipboard && text.length < 200_000) {
        lastClipboard = text
        const clip = makeTextClip(text, device)
        if (clip) store.upsert(clip)
      } else if (text) {
        lastClipboard = text
      }
      const sig = JSON.stringify({ last: lastTarget, hist: store.read().map((i) => i.id + String(i.pinned)) })
      if (sig !== lastEmit) {
        lastEmit = sig
        emit()
      }
    } catch {
      /* keep polling */
    }
  }, 400)

  const file = historyPath()
  watch(file, { ignoreInitial: true }).on('change', () => emit())

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
    else showSticky()
  })
})

app.on('before-quit', () => {
  quitting = true
})

app.on('window-all-closed', () => {
  if (isMac) return
  if (quitting || !tray) app.quit()
})

app.on('will-quit', () => {
  globalShortcut.unregisterAll()
})
