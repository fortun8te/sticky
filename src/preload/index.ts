import { contextBridge, ipcRenderer, webUtils } from 'electron'
import type { ClipItem, StickyApi, StickyStatus } from '../shared/types'

const api: StickyApi & { pathForFile: (file: File) => string; hide: () => void } = {
  dropText: (text) => ipcRenderer.invoke('sticky:dropText', text),
  dropFiles: (paths) => ipcRenderer.invoke('sticky:dropFiles', paths),
  getHistory: () => ipcRenderer.invoke('sticky:getHistory'),
  pasteItem: (id) => ipcRenderer.invoke('sticky:pasteItem', id),
  pinItem: (id) => ipcRenderer.invoke('sticky:pinItem', id),
  deleteItem: (id) => ipcRenderer.invoke('sticky:deleteItem', id),
  clearHistory: () => ipcRenderer.invoke('sticky:clearHistory'),
  getStatus: () => ipcRenderer.invoke('sticky:getStatus'),
  pathForFile: (file) => webUtils.getPathForFile(file),
  hide: () => ipcRenderer.send('sticky:hide'),
  onHistory: (cb) => {
    const fn = (_: unknown, items: ClipItem[]) => cb(items)
    ipcRenderer.on('sticky:history', fn)
    return () => ipcRenderer.removeListener('sticky:history', fn)
  },
  onStatus: (cb) => {
    const fn = (_: unknown, status: StickyStatus) => cb(status)
    ipcRenderer.on('sticky:status', fn)
    return () => ipcRenderer.removeListener('sticky:status', fn)
  }
}

contextBridge.exposeInMainWorld('sticky', api)

declare global {
  interface Window {
    sticky: StickyApi & { pathForFile: (file: File) => string; hide: () => void }
  }
}
