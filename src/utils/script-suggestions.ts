import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

export interface ScriptSuggestion {
  suggestion: string
  confidence: number
}

export function getPackageScripts(cwd: string): string[] {
  const packageJsonPath = join(cwd, 'package.json')

  if (!existsSync(packageJsonPath)) {
    return []
  }

  try {
    const packageJson = JSON.parse(readFileSync(packageJsonPath, 'utf-8'))
    return Object.keys(packageJson.scripts || {})
  }
  catch {
    return []
  }
}

export function findSimilarScript(scriptName: string, availableScripts: string[]): ScriptSuggestion | null {
  if (availableScripts.length === 0) {
    return null
  }

  // Calculate Levenshtein distance for similarity
  function levenshteinDistance(a: string, b: string): number {
    const matrix = Array.from({ length: b.length + 1 }, () =>
      Array.from({ length: a.length + 1 }, () => 0))

    for (let i = 0; i <= a.length; i++) matrix[0][i] = i
    for (let j = 0; j <= b.length; j++) matrix[j][0] = j

    for (let j = 1; j <= b.length; j++) {
      for (let i = 1; i <= a.length; i++) {
        const cost = a[i - 1] === b[j - 1] ? 0 : 1
        matrix[j][i] = Math.min(
          matrix[j - 1][i] + 1, // deletion
          matrix[j][i - 1] + 1, // insertion
          matrix[j - 1][i - 1] + cost, // substitution
        )
      }
    }

    return matrix[b.length][a.length]
  }

  let bestMatch: ScriptSuggestion | null = null
  let bestDistance = Infinity

  for (const script of availableScripts) {
    const distance = levenshteinDistance(scriptName.toLowerCase(), script.toLowerCase())
    const maxLength = Math.max(scriptName.length, script.length)
    const similarity = 1 - (distance / maxLength)

    // Consider it a good match if similarity is > 0.5 and better than previous matches
    if (similarity > 0.5 && distance < bestDistance) {
      bestDistance = distance
      bestMatch = {
        suggestion: script,
        confidence: similarity,
      }
    }
  }

  return bestMatch
}

export function formatScriptNotFoundError(scriptName: string, suggestion: ScriptSuggestion | null): string {
  let message = `error: Script not found "${scriptName}"`

  if (suggestion) {
    message += `
Did you mean "${suggestion.suggestion}"?`
  }

  return message
}
