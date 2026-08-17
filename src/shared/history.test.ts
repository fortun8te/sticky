import assert from 'node:assert/strict'
import test from 'node:test'
import { clipKey, mergeHistory, type ClipItem } from './types.ts'

const item = (over: Partial<ClipItem>): ClipItem => ({
  id: 'a',
  type: 'text',
  text: 'hello',
  createdAt: 1,
  pinned: false,
  device: 'windows',
  ...over
})

test('merge keeps newest text and preserves pins', () => {
  const a = item({ id: '1', text: 'old', createdAt: 1 })
  const b = item({ id: '1', text: 'new', createdAt: 2 })
  const pin = item({ id: '2', text: 'pin', pinned: true, createdAt: 0 })
  const merged = mergeHistory([a, pin], [b])
  assert.equal(merged[0].id, '2')
  assert.equal(merged.find((i) => i.id === '1')?.text, 'new')
})

test('clipKey distinguishes files', () => {
  assert.notEqual(
    clipKey({ type: 'text', text: 'a' }),
    clipKey({ type: 'files', files: ['a'] })
  )
})
