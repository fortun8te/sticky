import { contextBridge, ipcRenderer, webUtils } from 'electron'
import type { ClipItem, ExpandReason, IslandMode, StickyApi, StickyStatus } from '../shared/types'

type Handoff = { kind: 'send' | 'recv'; fly: 'up' | 'down'; label: string }
type Island = { mode: IslandMode; label: string; reason?: ExpandReason }

const api: StickyApi & {
  pathForFile: (file: File) => string
  hide: () => void
  setClickThrough: (on: boolean) => void
} = {
  dropText: (text) => ipcRenderer.invoke('sticky:dropText', text),
  dropFiles: (paths) => ipcRenderer.invoke('sticky:dropFiles', paths),
  getHistory: () => ipcRenderer.invoke('sticky:getHistory'),
  pasteItem: (id) => ipcRenderer.invoke('sticky:pasteItem', id),
  pinItem: (id) => ipcRenderer.invoke('sticky:pinItem', id),
  deleteItem: (id) => ipcRenderer.invoke('sticky:deleteItem', id),
  clearHistory: () => ipcRenderer.invoke('sticky:clearHistory'),
  getStatus: () => ipcRenderer.invoke('sticky:getStatus'),
  expand: (reason) => ipcRenderer.send('sticky:expand', reason ?? 'focus'),
  collapse: () => ipcRenderer.send('sticky:collapse'),
  haptic: (kind) => ipcRenderer.send('sticky:haptic', kind),
  fileIcons: (paths) => ipcRenderer.invoke('sticky:fileIcons', paths),
  pathForFile: (file) => webUtils.getPathForFile(file),
  hide: () => ipcRenderer.send('sticky:hide'),
  setClickThrough: (on: boolean) => ipcRenderer.send('sticky:clickThrough', on),
  onHistory: (cb) => {
    const fn = (_: unknown, items: ClipItem[]) => cb(items)
    ipcRenderer.on('sticky:history', fn)
    return () => ipcRenderer.removeListener('sticky:history', fn)
  },
  onStatus: (cb) => {
    const fn = (_: unknown, status: StickyStatus) => cb(status)
    ipcRenderer.on('sticky:status', fn)
    return () => ipcRenderer.removeListener('sticky:status', fn)
  },
  onHandoff: (cb) => {
    const fn = (_: unknown, e: Handoff) => cb(e)
    ipcRenderer.on('sticky:handoff', fn)
    return () => ipcRenderer.removeListener('sticky:handoff', fn)
  },
  onIsland: (cb) => {
    const fn = (_: unknown, e: Island) => cb(e)
    ipcRenderer.on('sticky:island', fn)
    return () => ipcRenderer.removeListener('sticky:island', fn)
  }
}

contextBridge.exposeInMainWorld('sticky', api)

declare global {
  interface Window {
    sticky: StickyApi & {
      pathForFile: (file: File) => string
      hide: () => void
      setClickThrough: (on: boolean) => void
    }
  }
}
