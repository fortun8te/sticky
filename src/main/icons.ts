import { app, nativeImage } from 'electron'
import { existsSync, statSync } from 'node:fs'
import { extname } from 'node:path'

const cache = new Map<string, string>()
const IMAGES = new Set(['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.tif', '.tiff'])

async function render(path: string): Promise<string> {
  const hit = cache.get(path)
  if (hit) return hit
  if (!path || !existsSync(path)) return ''
  let img = nativeImage.createEmpty()
  try {
    const st = statSync(path)
    const ext = extname(path).toLowerCase()
    if (!st.isDirectory() && IMAGES.has(ext)) {
      img = nativeImage.createFromPath(path)
    }
  } catch {
    img = nativeImage.createEmpty()
  }
  if (img.isEmpty()) {
    try {
      img = await app.getFileIcon(path, { size: 'small' })
    } catch {
      return ''
    }
  }
  if (img.isEmpty()) return ''
  const sized = img.resize({ width: 32, height: 32, quality: 'better' })
  const url = sized.toDataURL()
  cache.set(path, url)
  if (cache.size > 96) {
    const first = cache.keys().next().value
    if (first) cache.delete(first)
  }
  return url
}

export async function filePreviews(paths: string[]): Promise<string[]> {
  const unique = [...new Set(paths.filter(Boolean))].slice(0, 4)
  return Promise.all(unique.map(render))
}
