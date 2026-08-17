import { homedir } from 'node:os'
import { join } from 'node:path'
import { existsSync, mkdirSync } from 'node:fs'

function stickyUnder(root: string): string {
  return join(root, 'Sticky')
}

function syncCandidates(): string[] {
  const cloudDocs = join(homedir(), 'Library', 'Mobile Documents', 'com~apple~CloudDocs')
  const iCloudDrive = join(homedir(), 'iCloudDrive')
  const iCloudDriveSpaced = join(homedir(), 'iCloud Drive')
  const appleMobile = join(homedir(), 'Apple', 'Mobile Documents', 'com~apple~CloudDocs')

  if (process.platform === 'darwin') {
    return [stickyUnder(cloudDocs), stickyUnder(iCloudDriveSpaced), stickyUnder(iCloudDrive), stickyUnder(appleMobile)]
  }

  return [stickyUnder(iCloudDrive), stickyUnder(iCloudDriveSpaced), stickyUnder(appleMobile), stickyUnder(cloudDocs)]
}

export function resolveSyncDir(): string | null {
  for (const dir of syncCandidates()) {
    const parent = join(dir, '..')
    if (existsSync(parent) || existsSync(dir)) {
      mkdirSync(dir, { recursive: true })
      return dir
    }
  }
  return null
}

export function syncHistoryFile(syncDir: string | null, fallback: string): string {
  if (syncDir) return join(syncDir, 'history.json')
  return fallback
}
