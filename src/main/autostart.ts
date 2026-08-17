import { app } from 'electron'
import { execFile } from 'node:child_process'
import { mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'

const LABEL = 'app.sticky.drop'
const isMac = process.platform === 'darwin'
const isWin = process.platform === 'win32'

function prefPath(): string {
  return join(app.getPath('userData'), 'autostart.json')
}

export function autostartEnabled(): boolean {
  try {
    const raw = JSON.parse(readFileSync(prefPath(), 'utf8')) as { enabled?: unknown }
    if (typeof raw.enabled === 'boolean') return raw.enabled
  } catch {
    /* first run: on */
  }
  return true
}

function savePref(enabled: boolean): void {
  mkdirSync(dirname(prefPath()), { recursive: true })
  writeFileSync(prefPath(), JSON.stringify({ enabled }))
}

function macPlistPath(): string {
  return join(homedir(), 'Library/LaunchAgents', `${LABEL}.plist`)
}

function winStartupPath(): string {
  return join(
    app.getPath('appData'),
    'Microsoft',
    'Windows',
    'Start Menu',
    'Programs',
    'Startup',
    'Sticky.cmd'
  )
}

function uid(): number {
  return process.getuid?.() ?? 501
}

function xml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

function launchctl(args: string[]): void {
  execFile('launchctl', args, { timeout: 4000 }, () => undefined)
}

function shQuote(s: string): string {
  return `'${s.replace(/'/g, `'\\''`)}'`
}

function writeMacAgent(): void {
  const cwd = app.getAppPath()
  const args = app.isPackaged
    ? `    <string>${xml(process.execPath)}</string>`
    : `    <string>/bin/zsh</string>
    <string>-lc</string>
    <string>${xml(`cd ${shQuote(cwd)} && exec npm run start`)}</string>`
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
${args}
  </array>
  <key>WorkingDirectory</key>
  <string>${xml(cwd)}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>Crashed</key>
    <true/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>15</integer>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>LowPriorityIO</key>
  <true/>
  <key>Nice</key>
  <integer>5</integer>
</dict>
</plist>
`
  const dest = macPlistPath()
  mkdirSync(dirname(dest), { recursive: true })
  writeFileSync(dest, plist)
  const domain = `gui/${uid()}`
  launchctl(['bootout', domain, LABEL])
  launchctl(['bootstrap', domain, dest])
  launchctl(['enable', `${domain}/${LABEL}`])
}

function removeMacAgent(): void {
  const dest = macPlistPath()
  launchctl(['bootout', `gui/${uid()}`, LABEL])
  launchctl(['unload', '-w', dest])
  try {
    unlinkSync(dest)
  } catch {
    /* gone */
  }
}

function writeWinStartup(): void {
  const dest = winStartupPath()
  mkdirSync(dirname(dest), { recursive: true })
  const exe = process.execPath
  const body = app.isPackaged
    ? `@echo off\r\nstart "" "${exe}"\r\n`
    : `@echo off\r\ncd /d "${app.getAppPath()}"\r\nnpm run start\r\n`
  writeFileSync(dest, body)
}

function removeWinStartup(): void {
  try {
    unlinkSync(winStartupPath())
  } catch {
    /* gone */
  }
}

function electronLogin(enabled: boolean): void {
  try {
    app.setLoginItemSettings({
      openAtLogin: enabled,
      openAsHidden: true,
      name: 'Sticky',
      path: process.execPath,
      args: app.isPackaged ? [] : [app.getAppPath()]
    })
  } catch {
    try {
      app.setLoginItemSettings({ openAtLogin: enabled, openAsHidden: true })
    } catch {
      /* older electron */
    }
  }
}

export function applyAutostart(enabled: boolean): void {
  savePref(enabled)
  if (isMac) {
    if (enabled) writeMacAgent()
    else removeMacAgent()
    return
  }
  electronLogin(enabled)
  if (!isWin) return
  if (enabled && !app.isPackaged) writeWinStartup()
  else if (!enabled) removeWinStartup()
  else if (enabled && app.isPackaged) writeWinStartup()
}

export function ensureAutostart(): void {
  applyAutostart(autostartEnabled())
}
