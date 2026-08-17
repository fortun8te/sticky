import { execFile } from 'node:child_process'
import { createRequire } from 'node:module'
import { promisify } from 'node:util'
import { BrowserWindow } from 'electron'

const require = createRequire(import.meta.url)

const execFileAsync = promisify(execFile)

const VK_CONTROL = 0x11
const VK_MENU = 0x12
const VK_V = 0x56
const KEYEVENTF_KEYUP = 0x0002
const SW_RESTORE = 9

export interface LastTarget {
  id: string
  title: string
}

function ourHandles(win: BrowserWindow | null): Set<string> {
  const set = new Set<string>()
  if (!win || win.isDestroyed()) return set
  try {
    const buf = win.getNativeWindowHandle()
    if (buf.length >= 8) set.add(buf.readBigUInt64LE(0).toString())
    else if (buf.length >= 4) set.add(buf.readUInt32LE(0).toString())
  } catch {
    /* ignore */
  }
  return set
}

type WinUser32 = {
  GetForegroundWindow: () => unknown
  SetForegroundWindow: (h: bigint) => boolean
  GetWindowTextW: (h: bigint, buf: Buffer, len: number) => number
  IsWindow: (h: bigint) => boolean
  ShowWindow: (h: bigint, n: number) => boolean
  BringWindowToTop: (h: bigint) => boolean
  keybd_event: (vk: number, scan: number, flags: number, extra: number | bigint) => void
}

let winUser32: WinUser32 | null = null
let winApiFailed = false

function loadWin(): WinUser32 | null {
  if (process.platform !== 'win32') return null
  if (winApiFailed) return null
  if (winUser32) return winUser32
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const koffi = require('koffi') as typeof import('koffi')
    const user32 = koffi.load('user32.dll')
    winUser32 = {
      GetForegroundWindow: user32.func('uintptr __stdcall GetForegroundWindow()'),
      SetForegroundWindow: user32.func('bool __stdcall SetForegroundWindow(uintptr h)'),
      GetWindowTextW: user32.func('int __stdcall GetWindowTextW(uintptr h, void *buf, int n)'),
      IsWindow: user32.func('bool __stdcall IsWindow(uintptr h)'),
      ShowWindow: user32.func('bool __stdcall ShowWindow(uintptr h, int n)'),
      BringWindowToTop: user32.func('bool __stdcall BringWindowToTop(uintptr h)'),
      keybd_event: user32.func('void __stdcall keybd_event(uint8_t vk, uint8_t scan, uint32_t flags, uintptr extra)')
    }
    winUser32.GetForegroundWindow()
    return winUser32
  } catch {
    winApiFailed = true
    winUser32 = null
    return null
  }
}

function asHwnd(value: unknown): bigint {
  try {
    if (typeof value === 'bigint') return value
    if (typeof value === 'number' && Number.isFinite(value)) return BigInt(Math.trunc(value))
    if (typeof value === 'string' && value) return BigInt(value)
  } catch {
    /* ignore */
  }
  return 0n
}

function winTitle(api: WinUser32, h: bigint): string {
  try {
    const buf = Buffer.alloc(1024)
    const n = api.GetWindowTextW(h, buf, 512)
    if (n <= 0) return ''
    return buf.toString('utf16le').replace(/\0/g, '').trim()
  } catch {
    return ''
  }
}

function sendCtrlVNative(api: WinUser32): boolean {
  try {
    api.keybd_event(VK_CONTROL, 0, 0, 0)
    api.keybd_event(VK_V, 0, 0, 0)
    api.keybd_event(VK_V, 0, KEYEVENTF_KEYUP, 0)
    api.keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, 0)
    return true
  } catch {
    return false
  }
}

async function sendCtrlVPowershell(): Promise<boolean> {
  try {
    await execFileAsync(
      'powershell.exe',
      [
        '-NoProfile',
        '-STA',
        '-NonInteractive',
        '-Command',
        'Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.SendKeys]::SendWait("^v")'
      ],
      { timeout: 8000, windowsHide: true }
    )
    return true
  } catch {
    return false
  }
}

function focusHwnd(api: WinUser32, h: bigint): boolean {
  try {
    if (!api.IsWindow(h)) return false
    api.ShowWindow(h, SW_RESTORE)
    api.BringWindowToTop(h)
    try {
      api.keybd_event(VK_MENU, 0, 0, 0)
      api.SetForegroundWindow(h)
      api.keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, 0)
    } catch {
      api.SetForegroundWindow(h)
    }
    return true
  } catch {
    return false
  }
}

function isStickyMacProcess(name: string): boolean {
  const n = name.trim()
  if (!n) return true
  if (n === 'Sticky' || n === 'Electron') return true
  if (n.startsWith('Electron Helper') || n.startsWith('Sticky Helper')) return true
  return false
}

let macCached: LastTarget | null = null
let macRefresh: Promise<LastTarget | null> | null = null

export function pollLastTarget(win: BrowserWindow | null, current: LastTarget | null): LastTarget | null {
  try {
    if (process.platform === 'win32') {
      const api = loadWin()
      if (!api) return current
      const h = asHwnd(api.GetForegroundWindow())
      if (!h) return current
      if (ourHandles(win).has(h.toString())) return current
      if (!api.IsWindow(h)) return current
      const title = winTitle(api, h)
      if (title === 'Sticky') return current
      return { id: h.toString(), title: title || 'Last app' }
    }
    if (process.platform === 'darwin') {
      void refreshMacTarget(macCached ?? current)
      return macCached ?? current
    }
  } catch {
    return current
  }
  return current
}

export async function refreshMacTarget(current: LastTarget | null): Promise<LastTarget | null> {
  if (process.platform !== 'darwin') return current
  if (macRefresh) return macRefresh
  macRefresh = queryMacFrontmost(current).finally(() => {
    macRefresh = null
  })
  return macRefresh
}

async function queryMacFrontmost(current: LastTarget | null): Promise<LastTarget | null> {
  try {
    const { stdout } = await execFileAsync(
      'osascript',
      [
        '-e',
        'tell application "System Events"',
        '-e',
        'set p to first application process whose frontmost is true',
        '-e',
        'return (unix id of p as text) & linefeed & (name of p)',
        '-e',
        'end tell'
      ],
      { encoding: 'utf8', timeout: 2500 }
    )
    const trimmed = stdout.replace(/\r/g, '').trim()
    const nl = trimmed.indexOf('\n')
    if (nl <= 0) return current
    const pid = trimmed.slice(0, nl).trim()
    const name = trimmed.slice(nl + 1).trim()
    if (!pid || isStickyMacProcess(name)) return current
    const next = { id: pid, title: name || 'Last app' }
    macCached = next
    return next
  } catch {
    return current
  }
}

export async function injectPaste(win: BrowserWindow | null, target: LastTarget | null): Promise<boolean> {
  if (!target) return false

  if (process.platform === 'win32') {
    try {
      const api = loadWin()
      if (!api) return false
      const h = asHwnd(target.id)
      if (!h) return false
      if (!focusHwnd(api, h)) return false
      await delay(50)
      const injected = sendCtrlVNative(api) || (await sendCtrlVPowershell())
      try {
        win?.setAlwaysOnTop(true, 'floating')
      } catch {
        /* ignore */
      }
      return injected
    } catch {
      return false
    }
  }

  if (process.platform === 'darwin') {
    try {
      // pid + name are argv — never interpolated into the script
      await execFileAsync(
        'osascript',
        [
          '-e',
          'on run argv',
          '-e',
          'set procId to item 1 of argv',
          '-e',
          'set procName to item 2 of argv',
          '-e',
          'tell application "System Events"',
          '-e',
          'try',
          '-e',
          'set frontmost of first process whose unix id is (procId as integer) to true',
          '-e',
          'on error',
          '-e',
          'set frontmost of first process whose name is procName to true',
          '-e',
          'end try',
          '-e',
          'end tell',
          '-e',
          'delay 0.12',
          '-e',
          'tell application "System Events" to keystroke "v" using command down',
          '-e',
          'end run',
          target.id,
          target.title
        ],
        { encoding: 'utf8', timeout: 5000 }
      )
      try {
        win?.setAlwaysOnTop(true, 'floating')
      } catch {
        /* ignore */
      }
      return true
    } catch {
      return false
    }
  }

  return false
}

function delay(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms))
}
