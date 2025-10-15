import type { CompletionGroup, CompletionItem, CompletionResults, Shell } from '../types'
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { basename, dirname, join, resolve } from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

export class CompletionProvider {
  private commandCache = new Map<string, string[]>()
  private cacheTimeout = 30000 // 30 seconds
  private lastCacheUpdate = 0

  constructor(private shell: Shell) {}

  /**
   * Find the nearest directory (from cwd walking up) that contains a package.json
   */
  private findNearestPackageDir(cwd: string): string | null {
    try {
      let dir = cwd
      if (!dir || typeof dir !== 'string')
        return null
      while (true) {
        const pkgPath = resolve(dir, 'package.json')
        if (existsSync(pkgPath))
          return dir
        const parent = dirname(dir)
        if (!parent || parent === dir)
          break
        dir = parent
      }
    }
    catch {}
    // Fallback to project root if it contains a package.json
    try {
      const root = this.getProjectRoot()
      if (existsSync(resolve(root, 'package.json')))
        return root
    }
    catch {}
    return null
  }

  /**
   * Get command completions for a given prefix
   */
  private getCommandCompletions(prefix: string): string[] {
    const builtins = Array.from(this.shell.builtins.keys())
    const aliases = Object.keys(this.shell.aliases || {})
    const pathCommands = this.getPathCommands()
    const caseSensitive = this.shell.config.completion?.caseSensitive ?? false

    const match = (s: string) =>
      caseSensitive ? s.startsWith(prefix) : s.toLowerCase().startsWith(prefix.toLowerCase())

    const b = builtins.filter(match)
    const a = aliases.filter(match)
    const p = pathCommands.filter(match)

    // Keep order: builtins, aliases, then PATH commands; dedupe while preserving order
    const ordered = [...b, ...a, ...p]
    const seen = new Set<string>()
    const result: string[] = []
    for (const cmd of ordered) {
      if (!seen.has(cmd)) {
        seen.add(cmd)
        result.push(cmd)
      }
    }

    // Do not apply maxSuggestions here; allow plugins to merge first and let the shell enforce limits
    return result
  }

  /**
   * Collect commands available on PATH. Optimized to avoid per-file stat calls.
   * Uses a simple time-based cache keyed by the PATH string.
   */
  private getPathCommands(): string[] {
    try {
      const now = Date.now()
      const pathStr = process.env.PATH || ''
      // Use a stable cache key so changes to PATH don't invalidate cache within the window
      const cacheKey = 'PATH_COMMANDS_CACHE'

      if ((now - this.lastCacheUpdate) < this.cacheTimeout) {
        const cached = this.commandCache.get(cacheKey)
        if (cached)
          return cached
      }

      const names = new Set<string>()
      for (const dir of pathStr.split(':')) {
        if (!dir)
          continue
        try {
          const entries = readdirSync(dir, { withFileTypes: true })
          for (const e of entries) {
            const n = e.name
            if (!n || n.startsWith('.'))
              continue
            // Keep regular files and symlinks; skip directories and others.
            if (e.isDirectory())
              continue
            names.add(n)
          }
        }
        catch {
          // ignore unreadable PATH entries
        }
      }

      const list = Array.from(names)
      this.commandCache.set(cacheKey, list)
      this.lastCacheUpdate = now
      return list
    }
    catch {
      return []
    }
  }

  /**
   * Read nearest package.json and return bin names (object keys or package name if bin is string)
   */
  private getPackageJsonBinNames(cwd: string): string[] {
    const tryRead = (pkgDir: string): string[] => {
      try {
        const pkgPath = resolve(pkgDir, 'package.json')
        const raw = readFileSync(pkgPath, 'utf8')
        const json = JSON.parse(raw)
        const bin = (json as any).bin
        if (!bin)
          return []
        if (typeof bin === 'string') {
          const name = typeof (json as any).name === 'string' && (json as any).name ? (json as any).name : undefined
          return name ? [name] : []
        }
        if (typeof bin === 'object' && bin)
          return Object.keys(bin)
        return []
      }
      catch {
        return []
      }
    }

    try {
      let dir = cwd
      if (!dir || typeof dir !== 'string')
        return []
      while (true) {
        const names = tryRead(dir)
        if (names.length)
          return names
        const parent = dirname(dir)
        if (!parent || parent === dir)
          break
        dir = parent
      }
    }
    catch {}

    try {
      return tryRead(this.getProjectRoot())
    }
    catch {
      return []
    }
  }

  /**
   * Read nearest package.json and return files array entries (strings only)
   */
  private getPackageJsonFiles(cwd: string): string[] {
    const tryRead = (pkgDir: string): string[] => {
      try {
        const pkgPath = resolve(pkgDir, 'package.json')
        const raw = readFileSync(pkgPath, 'utf8')
        const json = JSON.parse(raw)
        const files = Array.isArray((json as any).files) ? (json as any).files.filter((v: any) => typeof v === 'string') : []
        return files
      }
      catch {
        return []
      }
    }

    try {
      let dir = cwd
      if (!dir || typeof dir !== 'string')
        return []
      while (true) {
        const list = tryRead(dir)
        if (list.length)
          return list
        const parent = dirname(dir)
        if (!parent || parent === dir)
          break
        dir = parent
      }
    }
    catch {}

    try {
      return tryRead(this.getProjectRoot())
    }
    catch {
      return []
    }
  }

  /**
   * Get full-path executable suggestions from PATH directories for a given prefix
   */
  private getBinPathCompletions(prefix: string): string[] {
    try {
      const path = process.env.PATH || ''
      const max = this.shell.config.completion?.binPathMaxSuggestions ?? 20
      const results: string[] = []
      const seen = new Set<string>()
      for (const dir of path.split(':')) {
        try {
          const files = readdirSync(dir, { withFileTypes: true })
          for (const file of files) {
            if (results.length >= max)
              return results
            if (!file.isFile())
              continue
            if (!file.name.startsWith(prefix))
              continue
            try {
              const fullPath = join(dir, file.name)
              const stat = statSync(fullPath)
              const isExecutable = Boolean(stat.mode & 0o111)
              if (isExecutable && !seen.has(fullPath)) {
                seen.add(fullPath)
                results.push(fullPath)
                if (results.length >= max)
                  return results
              }
            }
            catch {
              // ignore stat errors
            }
          }
        }
        catch {
          // ignore unreadable dirs
        }
      }
      return results
    }
    catch {
      return []
    }
  }

  private getProjectRoot(): string {
    try {
      const here = fileURLToPath(new URL('.', import.meta.url))
      // Module lives in src/completion/, project root is two levels up
      return resolve(here, '../..')
    }
    catch {
      return this.shell.cwd
    }
  }

  private listDirectories(dir: string): string[] {
    try {
      const entries = readdirSync(dir, { withFileTypes: true })
      const out: string[] = []
      for (const e of entries) {
        if (e.isDirectory())
          out.push(`${e.name}/`)
      }
      return out
    }
    catch {
      return []
    }
  }

  /**
   * List locally installed binaries in node_modules/.bin relative to current cwd and project root
   */
  private getLocalNodeBinCommands(): string[] {
    try {
      const names = new Set<string>()
      const seenDirs = new Set<string>()

      // Walk up from cwd to root, collecting node_modules/.bin
      try {
        let dir = this.shell.cwd
        if (dir && typeof dir === 'string') {
          while (true) {
            const binDir = resolve(dir, 'node_modules/.bin')
            if (!seenDirs.has(binDir)) {
              seenDirs.add(binDir)
              try {
                const entries = readdirSync(binDir, { withFileTypes: true })
                for (const e of entries) {
                  if (e.isDirectory())
                    continue
                  const n = e.name
                  if (!n || n.startsWith('.'))
                    continue
                  names.add(n)
                }
              }
              catch {
                // ignore
              }
            }
            const parent = dirname(dir)
            if (!parent || parent === dir)
              break
            dir = parent
          }
        }
      }
      catch {
        // ignore
      }

      // Also include project root node_modules/.bin for repo-root scripts
      try {
        const repoBin = resolve(this.getProjectRoot(), 'node_modules/.bin')
        if (!seenDirs.has(repoBin)) {
          seenDirs.add(repoBin)
          const entries = readdirSync(repoBin, { withFileTypes: true })
          for (const e of entries) {
            if (e.isDirectory())
              continue
            const n = e.name
            if (!n || n.startsWith('.'))
              continue
            names.add(n)
          }
        }
      }
      catch {
        // ignore
      }

      return Array.from(names)
    }
    catch {
      return []
    }
  }

  /**
   * Provide simple argument completions for selected builtins
   */
  private getBuiltinArgCompletions(command: string, tokens: string[], last: string): string[] {
    const getStack = (): string[] => ((this.shell as any)._dirStack ?? ((this.shell as any)._dirStack = [])) as string[]
    const loadBookmarks = (): Record<string, string> => {
      try {
        const host = this.shell as any
        if (host._bookmarks)
          return host._bookmarks as Record<string, string>
        const file = `${homedir()}/.krusty/bookmarks.json`
        if (!existsSync(file))
          return {}
        const raw = readFileSync(file, 'utf8')
        const data = JSON.parse(raw)
        host._bookmarks = (data && typeof data === 'object') ? (data as Record<string, string>) : {}
        return host._bookmarks
      }
      catch {
        return {}
      }
    }
    switch (command) {
      case 'command': {
        // Complete the command name (arg1) using the global command list
        if (tokens.length === 2) {
          return this.getCommandCompletions(last)
        }
        return []
      }
      case 'cd': {
        // Get directories from current working directory ONLY (not repo root)
        const files = this.getCdDirectoryCompletions(last)
        // Stack indices: -N (1-based)
        const stack = getStack()
        const stackIdx: string[] = []
        for (let i = 1; i <= Math.min(9, stack.length); i++) stackIdx.push(`-${i}`)
        const idxMatches = stackIdx.filter(s => s.startsWith(last) || last === '')

        // Semantic completions: -, ~, ..
        const semanticOptions: string[] = []
        if (process.env.OLDPWD && ('-'.startsWith(last) || last === '')) {
          semanticOptions.push('-')
        }
        if ('~'.startsWith(last) || last === '') {
          semanticOptions.push('~')
        }
        if ('..'.startsWith(last) || last === '') {
          semanticOptions.push('..')
        }

        // Bookmarks when prefix looks like ':name'
        const out: string[] = [...semanticOptions, ...idxMatches, ...files]
        if (last.startsWith(':') || last === ':') {
          const bm = loadBookmarks()
          const names = Object.keys(bm).map(k => `:${k}`)
          const matches = names.filter(n => n.startsWith(last))
          out.unshift(...matches)
        }
        return this.sortAndLimit(Array.from(new Set(out)), last)
      }
      case 'echo': {
        // Common echo flags
        const flags = ['-n', '-e', '-E']
        if (last.startsWith('-'))
          return flags.filter(f => f.startsWith(last))
        return []
      }
      case 'history': {
        // Common history flags
        const flags = ['-c', '-d', '-a', '-n', '-r', '-w', '-p', '-s']
        if (last.startsWith('-'))
          return flags.filter(f => f.startsWith(last))
        return []
      }
      case 'test':
      case '[': {
        // File, string, and integer operators
        const ops = [
          // file
          '-e',
          '-f',
          '-d',
          '-s',
          '-r',
          '-w',
          '-x',
          '-L',
          '-h',
          '-b',
          '-c',
          '-p',
          '-S',
          // string
          '-n',
          '-z',
          '=',
          '!=',
          // int (POSIX)
          '-eq',
          '-ne',
          '-gt',
          '-ge',
          '-lt',
          '-le',
        ]
        return ops.filter(o => o.startsWith(last) || last === '')
      }
      case 'printf': {
        // Suggest common format strings for the first arg
        if (tokens.length === 2) {
          const suggestions = ['"%s"', '"%d"', '"%s %d"', '%q', '"%%s"']
          return suggestions.filter(s => s.startsWith(last) || last === '')
        }
        return []
      }
      case 'getopts': {
        // getopts optstring name [args...]
        if (tokens.length === 2) {
          // If user typed a space after optstring (last===""), suggest var names
          if (last === '') {
            const names = ['opt', 'flag']
            return names
          }
          const optstrings = ['"ab:"', '"f:"', '"hv"', '"o:"']
          return optstrings.filter(s => s.startsWith(last) || last === '')
        }
        if (tokens.length >= 3) {
          const names = ['opt', 'flag']
          return names.filter(s => s.startsWith(last) || last === '')
        }
        return []
      }
      case 'export': {
        // Complete environment variable names; include '=' if first assignment
        const keys = Object.keys(this.shell.environment || {})
        const base = keys.map(k => (tokens.length <= 2 ? `${k}=` : k))
        return base.filter(k => k.startsWith(last) || last === '')
      }
      case 'unset': {
        const keys = Object.keys(this.shell.environment || {})
        return keys.filter(k => k.startsWith(last) || last === '')
      }
      case 'help': {
        // Suggest builtin names for help
        const names = Array.from(this.shell.builtins.keys())
        return names.filter(n => n.startsWith(last) || last === '')
      }
      case 'alias': {
        // Suggest existing alias names
        const names = Object.keys(this.shell.aliases || {})
        return names.filter(n => n.startsWith(last) || last === '')
      }
      case 'bookmark': {
        const sub = tokens[1]
        const bm = loadBookmarks()
        const names = Object.keys(bm)
        // bookmark del <name>
        if ((sub === 'del' || sub === 'rm' || sub === 'remove') && tokens.length >= 3)
          return names.filter(n => n.startsWith(last) || last === '')
        // bookmark <name>
        if (!sub || (tokens.length === 2 && !sub.startsWith('-')))
          return names.filter(n => n.startsWith(last) || last === '')
        return []
      }
      case 'unalias': {
        const names = Object.keys(this.shell.aliases || {})
        const flags = ['-a']
        const pool = last.startsWith('-') ? flags : names
        return pool.filter(n => n.startsWith(last) || last === '')
      }
      case 'set': {
        // Common flags and -o options
        const flags = ['-e', '-u', '-x', '-v', '+e', '+u', '+x', '+v']
        const oOpts = ['-o', 'vi', 'emacs', 'noclobber', 'pipefail', 'noglob']
        if (last === '-o' || (tokens.includes('-o') && tokens[tokens.length - 2] === '-o'))
          return oOpts.filter(o => o.startsWith(last) || last === '')
        const pool = last.startsWith('-') || last.startsWith('+') ? flags : [...flags, '-o']
        return pool.filter(f => f.startsWith(last) || last === '')
      }
      case 'read': {
        // Suggest flags first, then variable names
        const flags = ['-r', '-p', '-n', '-t', '-a', '-d', '-s', '-u']
        if (last.startsWith('-'))
          return flags.filter(f => f.startsWith(last))
        const envKeys = Object.keys(this.shell.environment || {})
        const names = ['var', 'name', 'line', ...envKeys]
        return names.filter(n => n.startsWith(last) || last === '')
      }
      case 'type':
      case 'hash': {
        // Complete command names for these utilities
        return this.getCommandCompletions(last)
      }
      case 'which': {
        // Suggest flags for which, else command names and full PATH entries
        const flags = ['-a', '-s', '--all', '--help', '--version', '--read-alias', '--read-functions', '--skip-alias', '--skip-functions']
        if (last.startsWith('-'))
          return flags.filter(f => f.startsWith(last))

        // If user is typing a path, use filesystem completions
        if (last.includes('/'))
          return this.getFileCompletions(last)

        // Otherwise combine command names and full PATH executable paths
        const names = this.getCommandCompletions(last)
        const bins = this.getBinPathCompletions(last)
        const combined = Array.from(new Set([...names, ...bins]))
        return this.sortAndLimit(combined, last)
      }
      case 'exec': {
        // First arg is a command to exec
        if (tokens.length >= 2)
          return this.getCommandCompletions(last)
        return []
      }
      case 'bg':
      case 'fg': {
        // Suggest job specs like %1 from current jobs
        const jobs = this.shell.getJobs ? this.shell.getJobs() : (this.shell.jobs || [])
        const specs = jobs.map(j => `%${j.id}`)
        return specs.filter(s => s.startsWith(last) || last === '')
      }
      case 'jobs': {
        // Common flags for jobs
        const flags = ['-l', '-p', '-r', '-s']
        return flags.filter(f => f.startsWith(last) || last === '')
      }
      case 'pushd':
      case 'popd': {
        // Suggest +N/-N and directories
        const stackIdx: string[] = []
        for (let i = 0; i <= 9; i++) {
          stackIdx.push(`+${i}`)
          stackIdx.push(`-${i}`)
        }
        const idxMatches = stackIdx.filter(s => s.startsWith(last) || last === '')
        const dirs = this.getFileCompletions(last).filter(f => f.endsWith('/'))
        return [...idxMatches, ...dirs]
      }
      case 'umask': {
        // Suggest common umask values and -S flag
        const masks = ['-S', '000', '002', '022', '027', '077']
        return masks.filter(m => m.startsWith(last) || last === '')
      }
      case 'kill':
      case 'trap': {
        // Common POSIX signals
        const signals = [
          '-SIGINT',
          '-SIGTERM',
          '-SIGKILL',
          '-SIGHUP',
          '-SIGQUIT',
          '-SIGSTOP',
          'SIGINT',
          'SIGTERM',
          'SIGKILL',
          'SIGHUP',
          'SIGQUIT',
          'SIGSTOP',
        ]
        if (last.startsWith('-'))
          return signals.filter(s => s.startsWith(last))
        return signals.filter(s => s.startsWith(last) || last === '')
      }
      // Builtins without args: no special completions
      case 'times':
      case 'dirs':
        return []
      default:
        return []
    }

    // Fallback
    return []
  }

  // Bun CLI completions inspired by official Bun shell completion scripts
  private getBunArgCompletions(tokens: string[], last: string): CompletionResults {
    // tokens[0] === 'bun'
    const subcommands = [
      'run',
      'test',
      'x',
      'repl',
      'init',
      'create',
      'install',
      'i',
      'add',
      'a',
      'remove',
      'rm',
      'update',
      'outdated',
      'link',
      'unlink',
      'pm',
      'build',
      'upgrade',
      'help',
      'bun',
    ]
    const globalFlags = ['--version', '-V', '--cwd', '--help', '-h', '--use']

    // If only 'bun' or completing first arg
    if (tokens.length === 1 || (tokens.length === 2 && !tokens[1].startsWith('-'))) {
      const pool = [...subcommands, ...globalFlags]
      return pool.filter(s => s.startsWith(last) || last === '')
    }

    const sub = tokens[1]
    const prev = tokens[tokens.length - 2] || ''
    const suggest = (...vals: string[]) => vals.filter(v => v.startsWith(last) || last === '')

    // Common value lists
    const jsxRuntime = ['classic', 'automatic']
    const targetVals = ['browser', 'bun', 'node']
    const sourcemapVals = ['none', 'external', 'inline']
    const formatVals = ['esm', 'cjs', 'iife']
    const installVals = ['auto', 'force', 'fallback']

    // Directory-only values
    if (prev === '--cwd' || prev === '--public-dir') {
      // For empty prefix, suggest directories from the project root to be deterministic in tests
      if (!last)
        return this.listDirectories(this.getProjectRoot())
      // If a path prefix is provided, fall back to path-based directory filtering
      return this.getFileCompletions(last).filter(x => x.endsWith('/'))
    }

    // Value-bearing flags
    if (prev === '--jsx-runtime')
      return suggest(...jsxRuntime)
    if (prev === '--target')
      return suggest(...targetVals)
    if (prev === '--sourcemap')
      return suggest(...sourcemapVals)
    if (prev === '--format')
      return suggest(...formatVals)
    if (prev === '--install' || prev === '-i')
      return suggest(...installVals)
    if (prev === '--backend')
      return suggest('clonefile', 'copyfile', 'hardlink', 'symlink')
    if (prev === '--loader' || prev === '-l') {
      const loaders = ['js', 'jsx', 'ts', 'tsx', 'json', 'toml', 'text', 'file', 'wasm', 'napi', 'css']
      // Support either bare loader names or .ext:loader format
      if (last.includes(':')) {
        const [ext, suf] = last.split(':')
        return loaders
          .map(l => `${ext}:${l}`)
          .filter(v => v.startsWith(`${ext}:${suf}`) || suf === '')
      }
      return loaders.filter(l => l.startsWith(last) || last === '')
    }

    // Subcommand-specific flags and fallbacks
    switch (sub) {
      case 'run': {
        // If completing flags for `bun run -...`, return flag list flat
        if (last.startsWith('-')) {
          const flags = [
            '--watch',
            '--hot',
            '--smol',
            '--bun',
            '--inspect',
            '--inspect-wait',
            '--inspect-brk',
            '--loader',
            '-l',
            '--jsx-runtime',
            '--backend',
            '--target',
            '--sourcemap',
            '--format',
            '--define',
            '-d',
            '--external',
            '-e',
          ]
          return flags.filter(f => f.startsWith(last))
        }

        // Otherwise, return grouped results: scripts, binaries, files
        const scripts = this.getPackageJsonScripts(this.shell.cwd)
        const caseSensitive = this.shell.config.completion?.caseSensitive ?? false
        const match = (s: string) => (last === '')
          || (caseSensitive ? s.startsWith(last) : s.toLowerCase().startsWith(last.toLowerCase()))
        let scriptMatches = scripts.filter(match)
        // For empty prefix, prioritize common scripts first, then alphabetical
        if (last === '') {
          const preferred = ['dev', 'start', 'build', 'test', 'lint']
          const prefSet = new Set(preferred)
          const pref = scriptMatches.filter(s => prefSet.has(s))
          const rest = scriptMatches.filter(s => !prefSet.has(s)).sort((a, b) => a.localeCompare(b))
          scriptMatches = [...pref, ...rest]
        }

        // Binaries: include package.json bin names and local node binaries from node_modules/.bin
        const pkgBins = this.getPackageJsonBinNames(this.shell.cwd)
        const localBins = this.getLocalNodeBinCommands()
        const binSet = new Set<string>([...pkgBins, ...localBins])
        // Apply prefix filtering with case-sensitivity and remove any that duplicate script names
        const scriptSet = new Set<string>(scripts)
        const binMatches = Array.from(binSet)
          .filter(n => match(n))
          .filter(n => !scriptSet.has(n))
          .sort((a, b) => a.localeCompare(b))

        // Files: show when empty prefix (list CWD) or when prefix is path-like; hide for non-empty non-path
        const isPathLike = last.includes('/')
          || last.startsWith('./')
          || last.startsWith('../')
          || last.startsWith('/')
          || last.startsWith('~')
        let files: string[] = []
        if (isPathLike) {
          files = this.getFileCompletions(last)
        }
        else if (last === '') {
          try {
            const entries = readdirSync(this.shell.cwd, { withFileTypes: true })
            files = entries
              .filter(e => !e.name.startsWith('.'))
              .map(e => (e.isDirectory() ? `${e.name}/` : e.name))
              .sort((a, b) => a.localeCompare(b))
          }
          catch {
            files = []
          }
        }

        const groups: CompletionGroup[] = []
        if (scriptMatches.length)
          groups.push({ title: 'scripts', items: scriptMatches })
        if (binMatches.length)
          groups.push({ title: 'binaries', items: binMatches })
        if (files.length)
          groups.push({ title: 'files', items: files })

        return groups.length ? groups : []
      }
      case 'build': {
        const flags = [
          '--outfile',
          '--outdir',
          '--minify',
          '--minify-whitespace',
          '--minify-syntax',
          '--minify-identifiers',
          '--sourcemap',
          '--target',
          '--splitting',
          '--compile',
          '--format',
        ]
        if (last.startsWith('-'))
          return flags.filter(f => f.startsWith(last))
        return this.getFileCompletions(last)
      }
      case 'pm': {
        const flags = [
          '--config',
          '-c',
          '--yarn',
          '-y',
          '--production',
          '-p',
          '--no-save',
          '--dry-run',
          '--frozen-lockfile',
          '--latest',
          '--force',
          '-f',
          '--cache-dir',
          '--no-cache',
          '--silent',
          '--verbose',
          '--no-progress',
          '--no-summary',
          '--no-verify',
          '--ignore-scripts',
          '--global',
          '-g',
          '--cwd',
          '--backend',
          '--link-native-bins',
          '--help',
        ]
        const subSubs = ['bin', 'ls', 'cache', 'hash', 'hash-print', 'hash-string', 'version']
        if (last.startsWith('-'))
          return flags.filter(f => f.startsWith(last))
        // If completing the first arg after 'pm', suggest sub-commands
        if (tokens.length <= 3)
          return subSubs.filter(s => s.startsWith(last) || last === '')
        return []
      }
      case 'test': {
        const flags = [
          '-h',
          '--help',
          '-b',
          '--bun',
          '--cwd',
          '-c',
          '--config',
          '--env-file',
          '--extension-order',
          '--jsx-factory',
          '--jsx-fragment',
          '--jsx-import-source',
          '--jsx-runtime',
          '--preload',
          '-r',
          '--main-fields',
          '--no-summary',
          '--version',
          '-v',
          '--revision',
          '--tsconfig-override',
          '--define',
          '-d',
          '--external',
          '-e',
          '--loader',
          '-l',
          '--origin',
          '-u',
          '--port',
          '-p',
          '--smol',
          '--minify',
          '--minify-syntax',
          '--minify-identifiers',
          '--no-macros',
          '--target',
          '--inspect',
          '--inspect-wait',
          '--inspect-brk',
          '--watch',
          '--timeout',
          '--update-snapshots',
          '--rerun-each',
          '--only',
          '--todo',
          '--coverage',
          '--bail',
          '--test-name-pattern',
          '-t',
        ]
        return flags.filter(f => f.startsWith(last) || last === '')
      }
      case 'add':
      case 'a':
      case 'install':
      case 'i': {
        const flags = [
          '--config',
          '-c',
          '--yarn',
          '-y',
          '--production',
          '-p',
          '--no-save',
          '--dry-run',
          '--frozen-lockfile',
          '--force',
          '-f',
          '--cache-dir',
          '--no-cache',
          '--silent',
          '--verbose',
          '--no-progress',
          '--no-summary',
          '--no-verify',
          '--ignore-scripts',
          '--global',
          '-g',
          '--cwd',
          '--backend',
          '--link-native-bins',
          '--help',
          '--dev',
          '-d',
          '--development',
          '--optional',
          '--peer',
          '--exact',
        ]
        return flags.filter(f => f.startsWith(last) || last === '')
      }
      case 'remove':
      case 'rm':
      case 'link':
      case 'unlink':
      case 'update':
      case 'outdated': {
        const flags = [
          '--config',
          '-c',
          '--yarn',
          '-y',
          '--production',
          '-p',
          '--no-save',
          '--dry-run',
          '--frozen-lockfile',
          '--latest',
          '--force',
          '-f',
          '--cache-dir',
          '--no-cache',
          '--silent',
          '--verbose',
          '--no-progress',
          '--no-summary',
          '--no-verify',
          '--ignore-scripts',
          '--global',
          '-g',
          '--cwd',
          '--backend',
          '--link-native-bins',
          '--help',
        ]
        return flags.filter(f => f.startsWith(last) || last === '')
      }
      case 'upgrade': {
        const flags = ['--canary']
        return flags.filter(f => f.startsWith(last) || last === '')
      }
      case 'init': {
        const flags = ['-y', '--yes']
        return flags.filter(f => f.startsWith(last) || last === '')
      }
      case 'create': {
        const flags = ['--force', '--no-install', '--help', '--no-git', '--verbose', '--no-package-json', '--open']
        const templates = ['next', 'react']
        const pool = last.startsWith('-') ? flags : [...templates, ...flags]
        return pool.filter(x => x.startsWith(last) || last === '')
      }
      case 'bun': {
        const flags = ['--version', '-V', '--cwd', '--help', '-h', '--use']
        if (last.startsWith('-'))
          return flags.filter(f => f.startsWith(last))
        return this.getFileCompletions(last)
      }
      default: {
        const gen = last.startsWith('-') ? globalFlags.filter(f => f.startsWith(last)) : []
        return gen.length ? gen : this.getFileCompletions(last)
      }
    }
  }

  private getPackageJsonScripts(cwd: string): string[] {
    const tryRead = (pkgDir: string): string[] => {
      try {
        const pkgPath = resolve(pkgDir, 'package.json')
        const raw = readFileSync(pkgPath, 'utf8')
        const json = JSON.parse(raw)
        const scripts = json && typeof json === 'object' && json.scripts && typeof json.scripts === 'object'
          ? Object.keys(json.scripts as Record<string, string>)
          : []
        return scripts
      }
      catch {
        return []
      }
    }

    // Walk up from cwd to filesystem root and return the first package.json scripts found
    try {
      let dir = cwd
      // Protect against empty cwd
      if (!dir || typeof dir !== 'string')
        return []
      while (true) {
        const scripts = tryRead(dir)
        if (scripts.length)
          return scripts
        const parent = dirname(dir)
        if (!parent || parent === dir)
          break
        dir = parent
      }
    }
    catch {
      // ignore
    }
    // Fallback: try the project root (repo root) as a last resort for tests and monorepos
    try {
      const fallback = this.getProjectRoot()
      const scripts = tryRead(fallback)
      if (scripts.length)
        return scripts
    }
    catch {
      // ignore
    }
    return []
  }

  /**
   * Public API used by the shell to get completions at a cursor position
   */
  public getCompletions(input: string, cursor: number): CompletionResults {
    try {
      // Default to enabled unless explicitly set to false
      if (this.shell.config.completion?.enabled === false)
        return [] as string[]
      const before = input.slice(0, Math.max(0, cursor))
      const tokens = this.tokenize(before)
      if (tokens.length === 0)
        return []
      const last = tokens[tokens.length - 1]
      const isFirst = tokens.length === 1
      if (isFirst)
        return this.getCommandCompletions(last)

      // If the first token is a builtin, attempt builtin-specific arg completions
      const cmd = tokens[0]
      if (this.shell.builtins.has(cmd)) {
        const builtinComps = this.getBuiltinArgCompletions(cmd, tokens, last)
        if (builtinComps.length)
          return builtinComps
      }

      // Special-case: provide rich completions for popular external tools
      if (cmd === 'bun') {
        const bunComps = this.getBunArgCompletions(tokens, last)
        if (Array.isArray(bunComps) && bunComps.length)
          return bunComps
      }

      // Fallback: file path completions (but not for cd command)
      if (cmd === 'cd') {
        return [] // cd should only use builtin completions, no file fallback
      }
      return this.getFileCompletions(last)
    }
    catch {
      return [] as string[]
    }
  }

  /**
   * Get directory completions for cd command (current directory only)
   */
  private getCdDirectoryCompletions(prefix: string): string[] {
    try {
      const hadQuote = prefix.startsWith('"') || prefix.startsWith('\'')
      const rawPrefix = hadQuote ? prefix.slice(1) : prefix

      // Handle home directory shortcut
      const basePath = rawPrefix.startsWith('~')
        ? rawPrefix.replace('~', homedir())
        : rawPrefix

      // Only check current working directory for cd completions
      const candidate = resolve(this.shell.cwd, basePath)

      const listInside = rawPrefix.endsWith('/') || rawPrefix === ''
      const attempt = {
        dir: listInside ? candidate : dirname(candidate),
        base: listInside ? '' : basename(candidate),
        rawBaseDir: dirname(rawPrefix),
      }

      let files
      try {
        files = readdirSync(attempt.dir, { withFileTypes: true })
      }
      catch {
        return []
      }

      const completions: string[] = []
      for (const file of files) {
        // Only include directories
        if (!file.isDirectory())
          continue

        // Hide dotfiles unless explicitly requested
        const dotPrefixed = attempt.base.startsWith('.') && attempt.base !== '.'
        if (!dotPrefixed && file.name.startsWith('.'))
          continue

        if (file.name.startsWith(attempt.base)) {
          const displayBase = rawPrefix.endsWith('/')
            ? file.name
            : join(attempt.rawBaseDir, file.name)

          let displayPath = `${displayBase}/`
          if (hadQuote) {
            displayPath = `"${displayPath}"`
          }
          completions.push(displayPath)
        }
      }

      return completions
    }
    catch {
      return []
    }
  }

  /**
   * Get file and directory completions for a given path prefix
   */
  private getFileCompletions(prefix: string): string[] {
    try {
      // Handle leading quotes for in-progress quoted paths
      const hadQuote = prefix.startsWith('"') || prefix.startsWith('\'')
      const rawPrefix = hadQuote ? prefix.slice(1) : prefix

      // Handle home directory shortcut first
      const basePath = rawPrefix.startsWith('~')
        ? rawPrefix.replace('~', homedir())
        : rawPrefix

      // Build candidate base directories: shell.cwd only for test consistency
      const candidates = [resolve(this.shell.cwd, basePath)]

      const completions: string[] = []
      const seen = new Set<string>()

      for (const candidate of candidates) {
        // Determine which directory to list and the base filename prefix:
        // - If rawPrefix ends with '/', list entries inside that directory (base='').
        // - If rawPrefix is empty, list entries in cwd (base='').
        // - Otherwise, list entries in dirname(candidate) and match basename(candidate).
        const listInside = rawPrefix.endsWith('/') || rawPrefix === ''
        const attempt = {
          dir: listInside ? candidate : dirname(candidate),
          base: listInside ? '' : basename(candidate),
          rawBaseDir: dirname(rawPrefix),
        }
        let files
        try {
          files = readdirSync(attempt.dir, { withFileTypes: true })
        }
        catch {
          continue
        }
        for (const file of files) {
          // Hide dotfiles unless the user explicitly started with a '.' prefix (not just './')
          const dotPrefixed = attempt.base.startsWith('.') && attempt.base !== '.' && attempt.base !== './'
          if (!dotPrefixed && file.name.startsWith('.'))
            continue
          if (file.name.startsWith(attempt.base)) {
            const displayBase = rawPrefix.endsWith('/')
              ? file.name
              : join(attempt.rawBaseDir, file.name)

            let displayPath = file.isDirectory() ? `${displayBase}/` : displayBase
            if (hadQuote) {
              const quote = prefix[0]
              displayPath = `${quote}${displayPath}`
            }
            if (!seen.has(displayPath)) {
              seen.add(displayPath)
              completions.push(displayPath)
            }
          }
        }
      }

      return completions
    }
    catch {
      return []
    }
  }

  /**
   * Tokenize input string into command line arguments
   */

  private tokenize(input: string): string[] {
    // Improved tokenizer that handles quoted strings and escaped characters
    const tokens: string[] = []
    let current = ''
    let inQuotes = false
    let quoteChar = ''
    let escapeNext = false

    for (let i = 0; i < input.length; i++) {
      const char = input[i]

      if (escapeNext) {
        current += char
        escapeNext = false
        continue
      }

      // Allow escapes outside quotes and inside double quotes
      if (char === '\\' && (!inQuotes || (inQuotes && quoteChar === '"'))) {
        escapeNext = true
        continue
      }

      if ((char === '"' || char === '\'') && !escapeNext) {
        if (inQuotes && char === quoteChar) {
          // Include the closing quote in the token for completeness
          current += char
          inQuotes = false
          quoteChar = ''
        }
        else if (!inQuotes) {
          // Preserve opening quote in token so downstream completion can detect it
          inQuotes = true
          quoteChar = char
          current += char
        }
        else {
          current += char
        }
      }
      else if (char === ' ' && !inQuotes) {
        if (current.trim()) {
          tokens.push(current)
          current = ''
        }
      }
      else {
        current += char
      }
    }

    // If input ends with a space (and we're not in quotes), append an empty token
    if (!inQuotes && input.endsWith(' ')) {
      if (current.trim())
        tokens.push(current)
      tokens.push('')
    }
    else if (current.trim()) {
      tokens.push(current)
    }

    return tokens
  }

  private escapeForCompletion(input: string): string {
    // Escape special characters in filenames for completion
    return input.replace(/([\s[\]{}()<>|;&*?$`'"\\])/g, '\\$1')
  }

  private sortAndLimit(completions: string[], partial: string): string[] {
    const maxSuggestions = this.shell.config.completion?.maxSuggestions || 10

    // Sort by relevance: exact matches first, then alphabetical
    const sorted = completions.sort((a, b) => {
      const aExact = a === partial
      const bExact = b === partial

      if (aExact && !bExact)
        return -1
      if (!aExact && bExact)
        return 1

      return a.localeCompare(b)
    })

    return sorted.slice(0, maxSuggestions)
  }

  // Get detailed completion items (for future use with rich completions)
  getDetailedCompletions(input: string, cursor: number): CompletionItem[] {
    const results = this.getCompletions(input, cursor)
    const isGroupArray = (v: any): v is CompletionGroup[] => Array.isArray(v) && v.every(g => g && typeof g.title === 'string' && Array.isArray(g.items))
    let flat: string[]
    if (isGroupArray(results)) {
      flat = results.flatMap(g => g.items).map(v => (typeof v === 'string' ? v : (v as CompletionItem).text)).filter((s): s is string => typeof s === 'string')
    }
    else {
      flat = (results as any[]).map(v => (typeof v === 'string' ? v : (v as CompletionItem).text)).filter((s): s is string => typeof s === 'string')
    }
    return flat.map(text => ({
      text,
      type: this.getCompletionType(text),
      description: this.getCompletionDescription(text),
    }))
  }

  private getCompletionType(text: string): CompletionItem['type'] {
    if (this.shell.builtins.has(text))
      return 'builtin'
    if (this.shell.aliases[text])
      return 'alias'
    if (text.endsWith('/'))
      return 'directory'
    if (text.includes('.'))
      return 'file'
    if (text.startsWith('$'))
      return 'variable'
    return 'command'
  }

  private getCompletionDescription(text: string): string | undefined {
    if (this.shell.builtins.has(text)) {
      return this.shell.builtins.get(text)?.description
    }

    if (this.shell.aliases[text]) {
      return `alias for: ${this.shell.aliases[text]}`
    }

    return undefined
  }
}
