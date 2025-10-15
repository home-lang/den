import { beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

describe('Bun CLI completions', () => {
  let shell: KrustyShell

  beforeEach(() => {
    shell = new KrustyShell({
      ...defaultConfig,
      completion: {
        enabled: true,
        caseSensitive: false,
        maxSuggestions: 50,
      },
    })
  })

  it('suggests bun subcommands and global flags as first arg', () => {
    const input = 'bun '
    const out = shell.getCompletions(input, input.length)
    expect(out.length).toBeGreaterThan(0)
    expect(out).toContain('run')
    expect(out).toContain('test')
    expect(out).toContain('--version')
  })

  it('filters subcommands by prefix', () => {
    const input = 'bun r'
    const out = shell.getCompletions(input, input.length)
    expect(out).toContain('run')
    // Should not include unrelated subcommands like 'test' for prefix 'r'
    // @ts-expect-error testing
    expect(out.includes('test')).toBe(false)
  })

  it('suggests flags for bun run when last token starts with -', () => {
    const input = 'bun run -'
    const out = shell.getCompletions(input, input.length)
    expect(out.length).toBeGreaterThan(0)
    expect(out).toContain('--watch')
    expect(out).toContain('--inspect')
  })

  it('suggests values for value-bearing flags (e.g., --jsx-runtime)', () => {
    const input = 'bun run --jsx-runtime '
    const out = shell.getCompletions(input, input.length)
    expect(out).toContain('classic')
    expect(out).toContain('automatic')
  })

  it('suggests build flags for bun build', () => {
    const input = 'bun build -'
    const out = shell.getCompletions(input, input.length)
    expect(out).toContain('--outdir')
    expect(out).toContain('--sourcemap')
  })

  it('suggests install flags for add/install', () => {
    const input = 'bun add -'
    const out = shell.getCompletions(input, input.length)
    expect(out).toContain('--dev')
    expect(out).toContain('--exact')
  })

  it('suggests global flags by prefix', () => {
    const input = 'bun --v'
    const out = shell.getCompletions(input, input.length)
    expect(out).toContain('--version')
  })

  it('suggests package.json scripts for bun run', () => {
    const input = 'bun run '
    const out: any = shell.getCompletions(input, input.length)
    // Accept grouped or flat results
    if (Array.isArray(out) && out.length && typeof out[0] === 'object' && 'title' in out[0]) {
      const scriptsGroup = out.find((g: any) => g && g.title === 'scripts')
      expect(scriptsGroup).toBeTruthy()
      expect(scriptsGroup.items).toContain('build')
      expect(scriptsGroup.items).toContain('test')
    }
    else {
      // Back-compat: flat results
      expect(out).toContain('build')
      expect(out).toContain('test')
    }
  })

  it('suggests loader values for --loader', () => {
    const input = 'bun run --loader '
    const out = shell.getCompletions(input, input.length)
    expect(out).toContain('js')
    expect(out).toContain('tsx')
  })

  it('suggests loader pair with extension like .js:jsx', () => {
    const input = 'bun run --loader .js:'
    const out = shell.getCompletions(input, input.length)
    expect(out).toContain('.js:jsx')
    expect(out).toContain('.js:ts')
  })

  it('suggests backend values for --backend', () => {
    const input = 'bun run --backend '
    const out = shell.getCompletions(input, input.length)
    expect(out).toContain('clonefile')
    expect(out).toContain('symlink')
  })

  it('suggests pm subcommands after bun pm', () => {
    const input = 'bun pm '
    const out = shell.getCompletions(input, input.length)
    expect(out).toContain('bin')
    expect(out).toContain('ls')
  })

  it('suggests flags for bun init', () => {
    const input = 'bun init -'
    const out = shell.getCompletions(input, input.length)
    expect(out).toContain('-y')
    expect(out).toContain('--yes')
  })

  it('suggests flags and templates for bun create', () => {
    const input = 'bun create '
    const out = shell.getCompletions(input, input.length)
    expect(out).toContain('next')
    expect(out).toContain('--no-install')
  })

  it('completes directories for --cwd', () => {
    const input = 'bun run --cwd '
    const out = shell.getCompletions(input, input.length)
    // repo directories
    // @ts-expect-error testing
    expect(out.find(x => x.endsWith('/'))).toBeTruthy()
    expect(out).toContain('docs/')
  })
  it('completes directories for --public-dir', () => {
    const input = 'bun build --public-dir '
    const out = shell.getCompletions(input, input.length)
    // @ts-expect-error testing
    expect(out.find(x => x.endsWith('/'))).toBeTruthy()
  })
})
