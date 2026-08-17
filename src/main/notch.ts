import { createRequire } from 'node:module'
import type { BrowserWindow, Display } from 'electron'

const require = createRequire(import.meta.url)

export const MAC_IDLE_W = 188
export const MAC_IDLE_DROP_H = 7
export const MAC_IDLE_HIT_H = 16
export const MAC_OPEN_W = 308
export const MAC_OPEN_DROP_H = 38
export const MAC_HIT_W = 370

type Api = {
  msg: (obj: unknown, sel: unknown) => unknown
  msgBool: (obj: unknown, sel: unknown, v: number) => unknown
  msgPoint: (obj: unknown, sel: unknown, pt: { x: number; y: number }) => unknown
  msgSize: (obj: unknown, sel: unknown, sz: { width: number; height: number }) => unknown
  sel: (name: string) => unknown
}

let api: Api | null = null
let apiFailed = false

function loadApi(): Api | null {
  if (apiFailed) return null
  if (api) return api
  if (process.platform !== 'darwin') {
    apiFailed = true
    return null
  }
  try {
    const koffi = require('koffi') as typeof import('koffi')
    const lib = koffi.load('/usr/lib/libobjc.A.dylib')
    const NSPoint = koffi.struct('NSPoint', { x: 'double', y: 'double' })
    const NSSize = koffi.struct('NSSize', { width: 'double', height: 'double' })
    api = {
      sel: lib.func('sel_registerName', 'void *', ['str']),
      msg: lib.func('objc_msgSend', 'void *', ['void *', 'void *']),
      msgBool: lib.func('objc_msgSend', 'void *', ['void *', 'void *', 'uint8']),
      msgPoint: lib.func('objc_msgSend', 'void *', ['void *', 'void *', NSPoint]),
      msgSize: lib.func('objc_msgSend', 'void *', ['void *', 'void *', NSSize])
    }
    return api
  } catch {
    apiFailed = true
    return null
  }
}

function viewPtr(win: BrowserWindow): bigint | null {
  const buf = win.getNativeWindowHandle()
  if (buf.length >= 8) return buf.readBigUInt64LE(0)
  if (buf.length >= 4) return BigInt(buf.readUInt32LE(0))
  return null
}

export function macNotchPad(display: Display): number {
  return Math.max(0, Math.round(display.workArea.y - display.bounds.y))
}

function nativePin(win: BrowserWindow, x: number, y: number, w: number, h: number, display: Display): void {
  const objc = loadApi()
  if (!objc) return
  const view = viewPtr(win)
  if (view == null) return
  const nsWin = objc.msg(view, objc.sel('window'))
  if (!nsWin) return
  try {
    objc.msgBool(nsWin, objc.sel('_setCanExcessOverlap:'), 1)
  } catch {
    /* private API may vanish */
  }
  const topY = display.bounds.y + display.bounds.height - (y - display.bounds.y)
  objc.msgPoint(nsWin, objc.sel('setFrameTopLeftPoint:'), { x, y: topY })
  objc.msgSize(nsWin, objc.sel('setContentSize:'), { width: w, height: h })
}

export function placeNotchWindow(
  win: BrowserWindow,
  display: Display,
  width: number,
  dropH: number,
  animate = false
): number {
  const pad = macNotchPad(display)
  const idleH = pad + MAC_IDLE_HIT_H
  const openH = pad + MAC_OPEN_DROP_H
  const x = Math.round(display.bounds.x + (display.bounds.width - width) / 2)
  const y = display.bounds.y
  const h = Math.max(dropH, pad + dropH)
  try {
    win.setMinimumSize(MAC_HIT_W, idleH)
    win.setMaximumSize(MAC_HIT_W, openH)
  } catch {
    /* ignore */
  }
  const bounds = { x, y, width, height: h }
  if (animate) {
    try {
      win.setBounds(bounds, true)
    } catch {
      win.setBounds(bounds)
    }
  } else {
    win.setBounds(bounds)
  }
  const got = win.getBounds()
  const yWrong = Math.abs(got.y - y) > 1
  const sizeWrong = Math.abs(got.height - h) > 1 || Math.abs(got.width - width) > 1
  if (win.isVisible() && (yWrong || (!animate && sizeWrong))) {
    nativePin(win, x, y, width, h, display)
  }
  return pad
}
