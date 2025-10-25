/**
 * Environment detection utilities
 */

import process from 'node:process'

// Use a dynamic import for process to avoid issues in browser
const nodeProcess = typeof process !== 'undefined' ? process : undefined

export const isBrowser: boolean = typeof window !== 'undefined' && typeof document !== 'undefined'
export const isNode: boolean = !!nodeProcess?.versions?.node

export function getEnvironment(): 'browser' | 'node' | 'unknown' {
  if (isBrowser)
    return 'browser'
  if (isNode)
    return 'node'
  return 'unknown'
}
