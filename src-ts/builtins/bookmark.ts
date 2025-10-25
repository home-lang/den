import type { BuiltinCommand, Shell } from './types'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, resolve } from 'node:path'

const BK_FILE = `${homedir()}/.krusty/bookmarks.json`

function ensureDir(path: string) {
  const dir = dirname(path)
  if (!existsSync(dir))
    mkdirSync(dir, { recursive: true })
}

function loadBookmarksFromDisk(): Record<string, string> {
  try {
    if (!existsSync(BK_FILE))
      return {}
    const raw = readFileSync(BK_FILE, 'utf8')
    const data = JSON.parse(raw)
    return (data && typeof data === 'object') ? (data as Record<string, string>) : {}
  }
  catch {
    return {}
  }
}

function saveBookmarksToDisk(bookmarks: Record<string, string>) {
  try {
    ensureDir(BK_FILE)
    writeFileSync(BK_FILE, `${JSON.stringify(bookmarks, null, 2)}\n`, 'utf8')
  }
  catch {
    // best-effort; ignore write errors
  }
}

function getBookmarks(shell: Shell): Record<string, string> {
  const host = shell as any
  if (!host._bookmarks)
    host._bookmarks = loadBookmarksFromDisk()
  return host._bookmarks as Record<string, string>
}

export const bookmarkCommand: BuiltinCommand = {
  name: 'bookmark',
  description: 'Manage directory bookmarks and navigate quickly',
  usage: 'bookmark [add <name> [dir]|del <name>|ls|<name>]',
  examples: [
    'bookmark ls',
    'bookmark add proj ~/Code/project',
    'bookmark add here',
    'bookmark del proj',
    'bookmark proj',
  ],
  async execute(args: string[], shell: Shell): Promise<{ exitCode: number, stdout: string, stderr: string, duration: number }> {
    const start = performance.now()
    const bookmarks = getBookmarks(shell)

    const sub = args[0]

    // List
    if (!sub || sub === 'ls' || sub === 'list') {
      const lines = Object.entries(bookmarks)
        .sort((a, b) => a[0].localeCompare(b[0]))
        .map(([k, v]) => `${k}\t${v}`)
      return { exitCode: 0, stdout: `${lines.join('\n')}${lines.length ? '\n' : ''}`, stderr: '', duration: performance.now() - start }
    }

    if (sub === 'add') {
      const name = args[1]
      if (!name)
        return { exitCode: 2, stdout: '', stderr: 'bookmark: add: name required\n', duration: performance.now() - start }
      const dirArg = args[2] || shell.cwd
      const dir = dirArg.startsWith('/') ? dirArg : resolve(shell.cwd, dirArg)
      bookmarks[name] = dir
      saveBookmarksToDisk(bookmarks)
      return { exitCode: 0, stdout: `:${name} -> ${dir}\n`, stderr: '', duration: performance.now() - start }
    }

    if (sub === 'del' || sub === 'rm' || sub === 'remove') {
      const name = args[1]
      if (!name)
        return { exitCode: 2, stdout: '', stderr: 'bookmark: del: name required\n', duration: performance.now() - start }
      if (!bookmarks[name])
        return { exitCode: 1, stdout: '', stderr: `bookmark: :${name} not found\n`, duration: performance.now() - start }
      delete bookmarks[name]
      saveBookmarksToDisk(bookmarks)
      return { exitCode: 0, stdout: '', stderr: '', duration: performance.now() - start }
    }

    // If the first arg is a name, jump to it
    const name = sub
    const dir = bookmarks[name]
    if (!dir)
      return { exitCode: 1, stdout: '', stderr: `bookmark: :${name} not found\n`, duration: performance.now() - start }

    const ok = shell.changeDirectory(dir)
    if (!ok)
      return { exitCode: 1, stdout: '', stderr: `bookmark: ${dir}: no such directory\n`, duration: performance.now() - start }

    // Echo new cwd similar to cd - behaviour for feedback
    return { exitCode: 0, stdout: `${shell.cwd}\n`, stderr: '', duration: performance.now() - start }
  },
}
