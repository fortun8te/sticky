import { execFile, spawn } from 'node:child_process'
import { promisify } from 'node:util'
import { clipboard, nativeImage } from 'electron'
import { existsSync } from 'node:fs'
import { basename, join } from 'node:path'

const execFileAsync = promisify(execFile)

const FILE_FORMATS = new Set([
  'text/uri-list',
  'FileNameW',
  'FileName',
  'public.file-url',
  'NSFilenamesPboardType'
])

function windowsPowershell(): string {
  const root = process.env.SystemRoot || 'C:\\Windows'
  return join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
}

function quotePs(value: string): string {
  return `'${value.replace(/'/g, "''")}'`
}

function hasFileClipboard(): boolean {
  try {
    return clipboard.availableFormats('clipboard').some((f) => FILE_FORMATS.has(f) || /file/i.test(f))
  } catch {
    return false
  }
}

function hasRichClipboard(): boolean {
  try {
    return clipboard.availableFormats('clipboard').some((f) => /html|rtf/i.test(f))
  } catch {
    return false
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

async function runWindowsPowershell(command: string, input?: string): Promise<void> {
  const args = ['-NoProfile', '-STA', '-NonInteractive', '-Command', command]
  let last: unknown
  for (let attempt = 0; attempt < 4; attempt++) {
    try {
      if (input === undefined) {
        await execFileAsync(windowsPowershell(), args, {
          timeout: 10_000,
          windowsHide: true,
          encoding: 'utf8'
        })
        return
      }
      await spawnWindowsPowershell(args, input)
      return
    } catch (err) {
      last = err
      await sleep(40 * (attempt + 1))
    }
  }
  throw last instanceof Error ? last : new Error('Clipboard write failed')
}

function spawnWindowsPowershell(args: string[], input: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(windowsPowershell(), args, {
      windowsHide: true,
      stdio: ['pipe', 'pipe', 'pipe']
    })
    let stderr = ''
    const timer = setTimeout(() => {
      child.kill()
      reject(new Error('Clipboard write timed out'))
    }, 10_000)
    child.stderr.on('data', (chunk) => {
      stderr += String(chunk)
    })
    child.on('error', (err) => {
      clearTimeout(timer)
      reject(err)
    })
    child.on('close', (code) => {
      clearTimeout(timer)
      if (code === 0) resolve()
      else reject(new Error(stderr.trim() || `powershell exited ${code}`))
    })
    child.stdin.write(input, 'utf8')
    child.stdin.end()
  })
}

async function writeWinUnicodeText(text: string): Promise<void> {
  await runWindowsPowershell(
    [
      'Add-Type -AssemblyName System.Windows.Forms',
      '$r = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [Text.Encoding]::UTF8)',
      '$val = $r.ReadToEnd()',
      '[Windows.Forms.Clipboard]::Clear()',
      '$d = New-Object Windows.Forms.DataObject',
      '[void]$d.SetText($val, [Windows.Forms.TextDataFormat]::UnicodeText)',
      '[Windows.Forms.Clipboard]::SetDataObject($d, $true)'
    ].join('; '),
    text
  )
}

export async function writePlainText(text: string): Promise<void> {
  clipboard.clear()
  clipboard.writeText(text, 'clipboard')
  if (process.platform === 'win32' && hasRichClipboard()) {
    await writeWinUnicodeText(text)
  }
}

export async function writeFiles(paths: string[]): Promise<void> {
  const existing = paths.filter((p) => existsSync(p))
  if (!existing.length) throw new Error('No files to copy')

  if (process.platform === 'win32') {
    const list = existing.map(quotePs).join(',')
    await runWindowsPowershell(
      `Set-Clipboard -Path ${list}; if (@(Get-Clipboard -Format FileDropList).Count -lt 1) { throw 'Set-Clipboard -Path failed' }`
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
  if (hasFileClipboard()) return ''
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
