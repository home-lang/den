import type { KrustyConfig } from '../src/types'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'
import { CommandParser } from '../src/parser'

function randInt(n: number) {
  return Math.floor(Math.random() * n)
}
function pick<T>(arr: T[]): T {
  return arr[randInt(arr.length)]
}

// Generate a random token with optional quotes/escapes, avoiding unterminated quotes
function genToken(): string {
  const atoms = ['foo', 'bar', 'baz', 'qux', '42', 'hello', 'world', 'a_b', 'A-B', 'x.y']
  const base = pick(atoms)
  const deco = randInt(5)
  if (deco === 0)
    return base
  if (deco === 1)
    return `"${base}"`
  if (deco === 2)
    return `'${base}'`
  if (deco === 3)
    return base.replace(/o/g, '\\o') // add escapes
  return base
}

// Generate a simple command line with optional pipes and operators but keep it valid
function genCommandLine(): string {
  const parts: string[] = []
  const words = 1 + randInt(4)
  for (let i = 0; i < words; i++) parts.push(genToken())
  let cmd = parts.join(' ')
  // optionally add a pipe segment with safe words
  if (Math.random() < 0.5) {
    const rhsWords = 1 + randInt(3)
    const rhs: string[] = []
    for (let i = 0; i < rhsWords; i++) rhs.push(genToken())
    cmd = `${cmd} | ${rhs.join(' ')}`
  }
  // optionally chain with ;, &&, ||
  if (Math.random() < 0.5) {
    const op = pick([';', '&&', '||'])
    const tailWords = 1 + randInt(3)
    const tail: string[] = []
    for (let i = 0; i < tailWords; i++) tail.push(genToken())
    cmd = `${cmd} ${op} ${tail.join(' ')}`
  }
  return cmd
}

describe('parser fuzz round-trips', () => {
  let shell: KrustyShell
  let cfg: KrustyConfig
  let parser: CommandParser

  beforeEach(() => {
    cfg = { ...defaultConfig, verbose: false, history: { ...defaultConfig.history, file: `/tmp/test_history_pf_${Math.random().toString(36).slice(2)}` } }
    shell = new KrustyShell(cfg)
    parser = new CommandParser()
  })

  afterEach(() => shell.stop())

  it('tokenize is idempotent over join-space reconstruction', () => {
    for (let i = 0; i < 200; i++) {
      const cmd = genCommandLine()
      const toks1 = parser.tokenize(cmd)
      const reconstructed = toks1.join(' ')
      const toks2 = parser.tokenize(reconstructed)
      expect(toks2).toEqual(toks1)
    }
  })

  it('splitByOperatorsDetailed is idempotent for segment+op rejoin', () => {
    for (let i = 0; i < 200; i++) {
      const cmd = genCommandLine()
      const parts = parser.splitByOperatorsDetailed(cmd)
      // Rejoin using recorded ops
      let rejoined = ''
      for (let j = 0; j < parts.length; j++) {
        const p = parts[j]
        rejoined += p.segment
        if (p.op)
          rejoined += ` ${p.op} `
      }
      const parts2 = parser.splitByOperatorsDetailed(rejoined)
      expect(parts2).toEqual(parts)
    }
  })
})
