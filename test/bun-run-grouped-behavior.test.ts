import { beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

function asGroups(out: any): { title: string, items: string[] }[] | null {
  if (Array.isArray(out) && out.length && typeof out[0] === 'object' && 'title' in out[0])
    return out as any
  return null
}

describe('bun run grouped completion behavior', () => {
  let shell: KrustyShell

  beforeEach(() => {
    shell = new KrustyShell({
      ...defaultConfig,
      completion: { enabled: true, caseSensitive: false, maxSuggestions: 50 },
    })
  })

  it('empty prefix shows scripts, binaries, and files groups', () => {
    const input = 'bun run '
    const out: any = shell.getCompletions(input, input.length)
    const groups = asGroups(out)
    expect(groups).toBeTruthy()
    expect(groups!.length).toBeGreaterThanOrEqual(1)
    // Expect all three groups to be present when prefix is empty
    expect(groups!.find(g => g.title === 'scripts')).toBeTruthy()
    expect(groups!.find(g => g.title === 'binaries')).toBeTruthy()
    expect(groups!.find(g => g.title === 'files')).toBeTruthy()
  })

  it('scripts group is prioritized by common names when empty prefix', () => {
    const input = 'bun run '
    const out: any = shell.getCompletions(input, input.length)
    const groups = asGroups(out)
    expect(groups).toBeTruthy()
    const scripts = groups!.find(g => g.title === 'scripts')!
    expect(scripts.items.length).toBeGreaterThan(0)
    const preferred = new Set(['dev', 'start', 'build', 'test', 'lint'])
    const hasPreferred = scripts.items.some(s => preferred.has(s))
    if (hasPreferred) {
      expect(preferred.has(scripts.items[0])).toBe(true)
    }
  })

  it('non-empty non-path prefix does not show files group', () => {
    const input = 'bun run s'
    const out: any = shell.getCompletions(input, input.length)
    const groups = asGroups(out)
    if (groups) {
      // Files group should be omitted for non-path prefixes
      expect(groups.find(g => g.title === 'files')).toBeFalsy()
      // At least one of scripts or binaries should be present if available in the environment
      const hasScripts = Boolean(groups.find(g => g.title === 'scripts'))
      const hasBins = Boolean(groups.find(g => g.title === 'binaries'))
      expect(hasScripts || hasBins).toBe(true)
    }
  })

  it('path-like prefix shows files group with entries', () => {
    const input = 'bun run ./'
    const out: any = shell.getCompletions(input, input.length)
    const groups = asGroups(out)
    expect(groups).toBeTruthy()
    const files = groups!.find(g => g.title === 'files')
    expect(files).toBeTruthy()
    expect(Array.isArray(files!.items)).toBe(true)
    expect(files!.items.length).toBeGreaterThan(0)
  })

  it('does not duplicate \'binaries\' group (normalized by trim/lower)', () => {
    const input = 'bun run '
    const out: any = shell.getCompletions(input, input.length)
    const groups = asGroups(out)
    expect(groups).toBeTruthy()
    const bins = groups!.filter(g => g.title.trim().toLowerCase() === 'binaries')
    expect(bins.length).toBeLessThanOrEqual(1)
    // Also ensure normalized titles are unique overall
    const seen = new Set<string>()
    for (const g of groups!) {
      const key = g.title.trim().toLowerCase()
      expect(seen.has(key)).toBe(false)
      seen.add(key)
    }
  })
})
