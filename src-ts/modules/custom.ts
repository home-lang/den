import type { ModuleContext, ModuleResult } from '../types'
import { BaseModule, ModuleUtils } from './index'

// Custom module for user-defined modules
export class CustomModule extends BaseModule {
  name: string
  enabled: boolean
  config: Record<string, any>

  constructor(name: string, config: Record<string, any>) {
    super()
    this.name = name
    this.enabled = config.enabled !== false
    this.config = config
  }

  detect(context: ModuleContext): boolean {
    const { when, files, extensions, directories } = this.config

    // Check custom condition
    if (typeof when === 'string') {
      try {
        // Create a safe evaluator function
        const evaluateCondition = (conditionStr: string, _ctx: ModuleContext): boolean => {
          // Check if the condition contains only allowed characters/patterns
          // Using a more restrictive pattern to prevent potential issues
          // Allow alphanumeric, whitespace, and common operators
          const allowedChars = /^[\w\s.()&|!='"[\]]+$/
          if (!allowedChars.test(conditionStr)) {
            return false
          }

          // Check for disallowed patterns
          const disallowedPatterns = [
            /\bfunction\s+(?:\w+\s*)?\(/i, // Match function declarations
            /=>/,
            /new\s+\w+\s*\(/i,
            /\.\s*\w+\s*\(/,
            /\beval\s*\(/i,
            /\brequire\s*\(/i,
            /[`${}]/,
          ]

          if (disallowedPatterns.some(pattern => pattern.test(conditionStr))) {
            return false
          }

          // Use a simple object-based evaluator instead of Function constructor
          try {
            // Create a safe context with a limited set of allowed operations
            const safeEval = (expr: string, context: Record<string, unknown>): boolean => {
              // Only allow simple property access and basic comparisons
              // Match simple comparisons with literals or identifiers
              const validExpr = /^\s*([\w.]+)\s*([=!]=|[<>]=?|&&|\|\|)\s*(?:(['"]).*?\3|true|false|null|undefined|\d+)\s*$/
              const match = expr.match(validExpr)

              if (!match)
                return false

              const [, left, operator, right] = match

              // Safely get nested properties
              const getValue = (path: string, obj: Record<string, unknown>): unknown => {
                return path.split('.').reduce<unknown>((o, p) =>
                  (o && typeof o === 'object' && p in o) ? (o as Record<string, unknown>)[p] : undefined, obj)
              }

              const leftVal = getValue(left, context)
              let rightVal: unknown = right

              // Handle string literals and other primitive types
              if (typeof right === 'string') {
                if ((right.startsWith('"') && right.endsWith('"'))
                  || (right.startsWith('\'') && right.endsWith('\''))) {
                  rightVal = right.slice(1, -1)
                }
                else if (right === 'true') {
                  rightVal = true
                }
                else if (right === 'false') {
                  rightVal = false
                }
                else if (right === 'null') {
                  rightVal = null
                }
                else if (right === 'undefined') {
                  rightVal = undefined
                }
                else if (/^\d+$/.test(right)) {
                  rightVal = Number(right)
                }
              }

              // Evaluate the comparison
              switch (operator) {
                case '==': return leftVal == rightVal // eslint-disable-line eqeqeq
                case '!=': return leftVal != rightVal // eslint-disable-line eqeqeq
                case '===': return leftVal === rightVal
                case '!==': return leftVal !== rightVal
                case '>': return Number(leftVal) > Number(rightVal)
                case '<': return Number(leftVal) < Number(rightVal)
                case '>=': return Number(leftVal) >= Number(rightVal)
                case '<=': return Number(leftVal) <= Number(rightVal)
                case '&&': return Boolean(leftVal) && Boolean(rightVal)
                case '||': return Boolean(leftVal) || Boolean(rightVal)
                default: return false
              }
            }

            // Create a safe context with only the allowed properties
            const safeContext = {
              environment: _ctx.environment || {},
              cwd: _ctx.cwd || '',
            }

            // Split on logical operators and evaluate each part
            const parts = conditionStr.split(/(&&|\|\|)/)
            let result = true
            let currentOp = '&&' // Default to AND

            for (const part of parts) {
              if (part === '&&' || part === '||') {
                currentOp = part
              }
              else {
                const partResult = safeEval(part.trim(), safeContext)
                if (currentOp === '&&') {
                  result = result && partResult
                }
                else {
                  result = result || partResult
                }
              }
            }

            return result
          }
          catch {
            return false
          }
        }

        if (!evaluateCondition(when, context)) {
          return false
        }
      }
      catch {
        return false
      }
    }
    else if (when === false) {
      return false
    }

    // Check for specific files
    if (Array.isArray(files) && files.length > 0) {
      if (!ModuleUtils.hasFiles(context, files))
        return false
    }

    // Check for file extensions
    if (Array.isArray(extensions) && extensions.length > 0) {
      if (!ModuleUtils.hasExtensions(context, extensions))
        return false
    }

    // Check for directories
    if (Array.isArray(directories) && directories.length > 0) {
      if (!ModuleUtils.hasDirectories(context, directories))
        return false
    }

    return true
  }

  async render(_context: ModuleContext): Promise<ModuleResult | null> {
    const { format, symbol, command } = this.config

    // If command is provided, execute it and use output
    if (command) {
      try {
        const output = await ModuleUtils.getCommandOutput(command)
        if (!output)
          return null

        const content = format
          ? ModuleUtils.formatTemplate(format, { symbol: symbol || '', output })
          : output

        return this.formatResult(content, {
          color: this.config.color || '#6b7280',
          bold: this.config.bold,
          italic: this.config.italic,
        })
      }
      catch {
        return null
      }
    }

    // Otherwise use static content
    const content = format
      ? ModuleUtils.formatTemplate(format, { symbol: symbol || '' })
      : symbol || this.name

    return this.formatResult(content, {
      color: this.config.color || '#6b7280',
      bold: this.config.bold,
      italic: this.config.italic,
    })
  }
}

// Environment variable module
export class EnvVarModule extends BaseModule {
  name: string
  enabled: boolean
  config: Record<string, any>

  constructor(name: string, config: Record<string, any>) {
    super()
    this.name = name
    this.enabled = config.enabled !== false
    this.config = config
  }

  detect(context: ModuleContext): boolean {
    const varName = this.config.variable || this.name.replace('env_var.', '')
    return !!context.environment[varName]
  }

  async render(_context: ModuleContext): Promise<ModuleResult | null> {
    const varName = this.config.variable || this.name.replace('env_var.', '')
    const value = _context.environment[varName] || this.config.default

    if (!value)
      return null

    const symbol = this.config.symbol || ''
    const format = this.config.format || '{symbol}{value}'

    const content = ModuleUtils.formatTemplate(format, {
      symbol,
      value,
      name: varName,
    })

    return this.formatResult(content, {
      color: this.config.color || '#6b7280',
      bold: this.config.bold,
      italic: this.config.italic,
    })
  }
}

// Factory function to create custom modules from config
export function createCustomModules(config: Record<string, any>): BaseModule[] {
  const modules: BaseModule[] = []

  // Create custom modules
  if (config.custom) {
    for (const [name, moduleConfig] of Object.entries(config.custom)) {
      modules.push(new CustomModule(`custom.${name}`, moduleConfig as Record<string, any>))
    }
  }

  // Create environment variable modules
  if (config.env_var) {
    for (const [name, moduleConfig] of Object.entries(config.env_var)) {
      modules.push(new EnvVarModule(`env_var.${name}`, moduleConfig as Record<string, any>))
    }
  }

  return modules
}
