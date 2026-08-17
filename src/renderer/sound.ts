let ctx: AudioContext | null = null

function ac(): AudioContext | null {
  try {
    if (!ctx) ctx = new AudioContext()
    if (ctx.state === 'suspended') void ctx.resume()
    return ctx
  } catch {
    return null
  }
}

function tone(
  c: AudioContext,
  freq: number,
  start: number,
  dur: number,
  peak: number,
  type: OscillatorType = 'sine'
): void {
  const o = c.createOscillator()
  const g = c.createGain()
  o.type = type
  o.frequency.setValueAtTime(freq, start)
  g.gain.setValueAtTime(0.0001, start)
  g.gain.exponentialRampToValueAtTime(peak, start + 0.008)
  g.gain.exponentialRampToValueAtTime(0.0001, start + dur)
  o.connect(g)
  g.connect(c.destination)
  o.start(start)
  o.stop(start + dur + 0.02)
}

function dust(c: AudioContext, start: number, dur: number, peak: number): void {
  const n = Math.floor(c.sampleRate * dur)
  const buf = c.createBuffer(1, n, c.sampleRate)
  const data = buf.getChannelData(0)
  for (let i = 0; i < n; i++) data[i] = (Math.random() * 2 - 1) * (1 - i / n)
  const src = c.createBufferSource()
  const bp = c.createBiquadFilter()
  const g = c.createGain()
  src.buffer = buf
  bp.type = 'bandpass'
  bp.frequency.value = 2400
  bp.Q.value = 2.2
  g.gain.setValueAtTime(peak, start)
  g.gain.exponentialRampToValueAtTime(0.0001, start + dur)
  src.connect(bp)
  bp.connect(g)
  g.connect(c.destination)
  src.start(start)
}

export function playUi(kind: 'tick' | 'drop' | 'catch'): void {
  const c = ac()
  if (!c) return
  const t = c.currentTime + 0.001
  try {
    if (kind === 'tick') {
      dust(c, t, 0.018, 0.028)
      tone(c, 1860, t, 0.032, 0.018)
      return
    }
    if (kind === 'drop') {
      tone(c, 640, t, 0.07, 0.03, 'triangle')
      tone(c, 1280, t + 0.022, 0.055, 0.016)
      return
    }
    tone(c, 1480, t, 0.05, 0.022)
    tone(c, 740, t + 0.028, 0.09, 0.028, 'triangle')
  } catch {
    /* audio locked */
  }
}
