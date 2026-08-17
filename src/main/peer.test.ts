import assert from 'node:assert/strict'
import test from 'node:test'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { collectFiles, planInbox, sanitizeRel, uniqueJoin } from './peer.ts'

test('sanitizeRel blocks traversal and Windows-illegal names', () => {
  assert.equal(sanitizeRel('../etc/passwd'), null)
  assert.equal(sanitizeRel('foo/../../x'), null)
  assert.equal(sanitizeRel('C:'), null)
  assert.equal(sanitizeRel('a/b'), 'a/b')
  assert.equal(sanitizeRel('a\\b\\c'), 'a/b/c')
  assert.equal(sanitizeRel('foo:bar'), 'foo_bar')
  assert.equal(sanitizeRel('shot<>.png'), 'shot__.png')
  assert.equal(sanitizeRel('con.txt'), '_con.txt')
  assert.equal(sanitizeRel('nul'), '_nul')
  assert.equal(sanitizeRel('photo.'), 'photo_')
})

test('planInbox keeps a folder root and a single file as a file', () => {
  const root = mkdtempSync(join(tmpdir(), 'sticky-inbox-'))
  try {
    const folder = planInbox(['Album/a.jpg', 'Album/sub/b.png'], root)
    assert.equal(folder.clipboard.length, 1)
    assert.equal(folder.clipboard[0], join(root, 'Album'))
    assert.equal(folder.destFor('Album/a.jpg'), join(root, 'Album', 'a.jpg'))
    assert.equal(folder.destFor('Album/sub/b.png'), join(root, 'Album', 'sub', 'b.png'))

    const file = planInbox(['shot.jpg'], root)
    assert.equal(file.clipboard[0], join(root, 'shot.jpg'))
    assert.equal(file.destFor('shot.jpg'), join(root, 'shot.jpg'))

    mkdirSync(join(root, 'shot.jpg'))
    const again = uniqueJoin(root, 'shot.jpg')
    assert.equal(again, join(root, 'shot-2.jpg'))
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('collectFiles walks folders, skips junk, keeps nested rels', () => {
  const root = mkdtempSync(join(tmpdir(), 'sticky-src-'))
  try {
    mkdirSync(join(root, 'Album', 'sub'), { recursive: true })
    writeFileSync(join(root, 'Album', 'a.jpg'), 'a')
    writeFileSync(join(root, 'Album', 'sub', 'b.png'), 'b')
    writeFileSync(join(root, 'Album', '.DS_Store'), 'x')
    writeFileSync(join(root, 'Album', 'Thumbs.db'), 'x')
    const files = collectFiles([join(root, 'Album')])
    assert.deepEqual(
      files.map((f) => f.rel).sort(),
      ['Album/a.jpg', 'Album/sub/b.png']
    )
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('collectFiles reconstructs a nested drop without the folder root', () => {
  const root = mkdtempSync(join(tmpdir(), 'sticky-flat-'))
  try {
    mkdirSync(join(root, 'Album', 'sub'), { recursive: true })
    const a = join(root, 'Album', 'a.jpg')
    const b = join(root, 'Album', 'sub', 'b.png')
    writeFileSync(a, 'a')
    writeFileSync(b, 'b')
    const nested = collectFiles([a, b])
    assert.deepEqual(
      nested.map((f) => f.rel).sort(),
      ['Album/a.jpg', 'Album/sub/b.png']
    )

    const c = join(root, 'Album', 'c.txt')
    const d = join(root, 'Album', 'd.txt')
    writeFileSync(c, 'c')
    writeFileSync(d, 'd')
    const siblings = collectFiles([c, d])
    assert.deepEqual(
      siblings.map((f) => f.rel).sort(),
      ['c.txt', 'd.txt']
    )
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})
