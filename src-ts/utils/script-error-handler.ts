import type { Shell } from '../types'

import { stripAnsi } from './ansi'
import { findSimilarScript, formatScriptNotFoundError, getPackageScripts } from './script-suggestions'

export class ScriptErrorHandler {
  private shell: Shell

  constructor(shell: Shell) {
    this.shell = shell
  }

  handleBunRunError(stderr: string, scriptName: string): { stderr: string, suggestion?: string } {
    // Clean up the error message by removing any ANSI escape codes and extra whitespace
    const cleanStderr = stripAnsi(stderr).trim()
    
    // Check if this is a "Script not found" error from bun
    const isScriptNotFound = cleanStderr.includes('Script not found') || 
                           cleanStderr.includes('error: Script not found') ||
                           cleanStderr.includes('Script not found:')
    
    // If it's not a script not found error, clean up the error message and return
    if (!isScriptNotFound) {
      return { 
        stderr: cleanStderr.replace(/\s+/g, ' ').trim() 
      }
    }
    
    // Extract the actual script name from the error message if not provided
    const match = cleanStderr.match(/Script not found[\s:]+["']?([^\s"']+)/i) || 
                 cleanStderr.match(/error: Script not found[\s:]+["']?([^\s"']+)/i)
    const actualScriptName = match ? match[1] : scriptName
    
    // Get available scripts and find a suggestion
    const availableScripts = getPackageScripts(this.shell.cwd)
    const suggestion = findSimilarScript(actualScriptName, availableScripts)
    
    if (suggestion) {
      return {
        stderr: formatScriptNotFoundError(actualScriptName, suggestion),
        // Store only the script name; callers can decide how to execute it
        suggestion: suggestion.suggestion
      }
    }
    
    // If no similar script found but it's a script not found error, return a clean error
    return {
      stderr: `error: Script not found "${actualScriptName}"`
    }
  }
}
