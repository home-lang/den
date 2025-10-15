import { afterAll, beforeAll, describe, expect, it } from 'bun:test'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

function asGroups(out: any): { title: string, items: string[] }[] | null {
  if (Array.isArray(out) && out.length && typeof out[0] === 'object' && 'title' in out[0])
    return out as any
  return null
}

describe('bun run TDD repro: three groups shown with expected local content', () => {
  let tmp: string
  let shell: KrustyShell
  let originalCwd: string

  beforeAll(() => {
    tmp = mkdtempSync(join(tmpdir(), 'krusty-bunrun-'))
    // minimal package.json with scripts
    const pkg = {
      name: 'tmp-proj',
      type: 'module',
      version: '0.0.0',
      bin: {
        foo: './dist/foo.js',
        bar: './dist/bar.js',
      },
      files: ['README.md', 'dist'],
      scripts: {
        build: 'echo build',
        lint: 'echo lint',
        test: 'echo test',
        bench: 'echo bench',
      },
    }
    writeFileSync(join(tmp, 'package.json'), JSON.stringify(pkg, null, 2))
    // create files listed in package.json files for realism
    mkdirSync(join(tmp, 'dist'), { recursive: true })
    writeFileSync(join(tmp, 'README.md'), 'tmp')

    shell = new KrustyShell({
      ...defaultConfig,
      completion: { enabled: true, caseSensitive: false, maxSuggestions: 50 },
    })
    // Store original cwd for restoration
    originalCwd = (shell as any).cwd || process.cwd()
    ;(shell as any).cwd = tmp
  })

  afterAll(() => {
    // Restore original cwd to prevent test isolation issues
    ;(shell as any).cwd = originalCwd
    rmSync(tmp, { recursive: true, force: true })
  })

  it('bun run shows scripts, binaries, and files groups with expected items', () => {
    const input = 'bun run '
    const out: any = shell.getCompletions(input, input.length)
    const groups = asGroups(out)
    expect(groups).toBeTruthy()
    const scripts = groups!.find(g => g.title === 'scripts')
    const bins = groups!.find(g => g.title === 'binaries')
    const files = groups!.find(g => g.title === 'files')

    expect(scripts).toBeTruthy()
    expect(bins).toBeTruthy()
    expect(files).toBeTruthy()

    // scripts include our package.json scripts
    expect(scripts!.items).toEqual(expect.arrayContaining(['build', 'lint', 'test', 'bench']))
    // binaries include bin names from package.json
    expect(bins!.items).toEqual(expect.arrayContaining(['foo', 'bar']))
    // files group includes only file entries from package.json files array (directories excluded)
    expect(files!.items).toEqual(expect.arrayContaining(['README.md']))

    // Ensure there is only one normalized 'binaries' group
    const binGroups = groups!.filter(g => g.title.trim().toLowerCase() === 'binaries')
    expect(binGroups.length).toBeLessThanOrEqual(1)
    // Ensure normalized titles are unique overall
    const seen = new Set<string>()
    for (const g of groups!) {
      const key = g.title.trim().toLowerCase()
      expect(seen.has(key)).toBe(false)
      seen.add(key)
    }
  })
})
