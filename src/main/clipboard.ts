import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { clipboard, nativeImage } from 'electron'
import { existsSync } from 'node:fs'
import { basename } from 'node:path'

const execFileAsync = promisify(execFile)

export async function writePlainText(text: string): Promise<void> {
  clipboard.clear()
  clipboard.writeText(text, 'clipboard')
}

export async function writeFiles(paths: string[]): Promise<void> {
  const existing = paths.filter((p) => existsSync(p))
  if (!existing.length) throw new Error('No files to copy')

  if (process.platform === 'win32') {
    const list = existing.map((p) => `'${p.replace(/'/g, "''")}'`).join(',')
    await execFileAsync(
      'powershell.exe',
      ['-NoProfile', '-STA', '-NonInteractive', '-Command', `Set-Clipboard -Path ${list}`],
      { timeout: 10_000, windowsHide: true }
    )
    return
  }

  if (process.platform === 'darwin') {
    const posix = existing.map((p) => p.replace(/\\/g, '/'))
    try {
      await writeMacFileUrls(posix)
    } catch {
      await writeMacFileUrlsFallback(posix)
    }
    return
  }

  clipboard.write({
    text: existing.map((p) => basename(p)).join('\n'),
    bookmark: existing[0],
    image: nativeImage.createEmpty()
  })
}

export function readPlainText(): string {
  return clipboard.readText('clipboard') ?? ''
}

async function writeMacFileUrls(posix: string[]): Promise<void> {
  const script = [
    'use framework "Foundation"',
    'use framework "AppKit"',
    'use scripting additions',
    'on run argv',
    '  set urlArray to current application\'s NSMutableArray\'s array()',
    '  repeat with p in argv',
    '    set theUrl to (current application\'s NSURL\'s fileURLWithPath:(p as text))',
    '    urlArray\'s addObject:theUrl',
    '  end repeat',
    '  set pb to current application\'s NSPasteboard\'s generalPasteboard()',
    '  pb\'s clearContents()',
    '  pb\'s writeObjects:urlArray',
    'end run'
  ].join('\n')
  await execFileAsync('osascript', ['-e', script, ...posix], { encoding: 'utf8', timeout: 8000 })
}

async function writeMacFileUrlsFallback(posix: string[]): Promise<void> {
  const script = [
    'on run argv',
    '  set furlList to {}',
    '  repeat with p in argv',
    '    set end of furlList to ((POSIX file (p as text)) as «class furl»)',
    '  end repeat',
    '  set the clipboard to furlList',
    'end run'
  ].join('\n')
  await execFileAsync('osascript', ['-e', script, ...posix], { encoding: 'utf8', timeout: 8000 })
}
