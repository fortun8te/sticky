import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)

export type HapticKind = 'tick' | 'drop' | 'catch'

const Pattern = {
  generic: 0,
  alignment: 1,
  levelChange: 2
} as const

const TimeNow = 1

let perform: ((pattern: number) => void) | null = null
let failed = false
let lastAt = 0
let lastKind: HapticKind | null = null

function load(): ((pattern: number) => void) | null {
  if (failed) return null
  if (perform) return perform
  if (process.platform !== 'darwin') {
    failed = true
    return null
  }
  try {
    const koffi = require('koffi') as typeof import('koffi')
    const objc = koffi.load('/usr/lib/libobjc.A.dylib')
    const getClass = objc.func('objc_getClass', 'void *', ['str'])
    const sel = objc.func('sel_registerName', 'void *', ['str'])
    const msg0 = objc.func('objc_msgSend', 'void *', ['void *', 'void *'])
    const msg2 = objc.func('objc_msgSend', 'void *', ['void *', 'void *', 'long', 'long'])
    const Manager = getClass('NSHapticFeedbackManager')
    if (!Manager) {
      failed = true
      return null
    }
    const performer = msg0(Manager, sel('defaultPerformer'))
    if (!performer) {
      failed = true
      return null
    }
    const run = sel('performFeedbackPattern:performanceTime:')
    perform = (pattern: number) => {
      msg2(performer, run, pattern, TimeNow)
    }
    return perform
  } catch {
    failed = true
    return null
  }
}

function patternFor(kind: HapticKind): number {
  if (kind === 'tick') return Pattern.alignment
  if (kind === 'catch') return Pattern.levelChange
  return Pattern.generic
}

export function haptic(kind: HapticKind): void {
  const now = Date.now()
  if (kind === 'tick' && lastKind === 'tick' && now - lastAt < 480) return
  if (now - lastAt < 90) return
  const run = load()
  if (!run) return
  lastAt = now
  lastKind = kind
  try {
    run(patternFor(kind))
  } catch {
    /* Magic Mouse / no Taptic Engine */
  }
}
